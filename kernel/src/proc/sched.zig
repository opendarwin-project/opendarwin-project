//! SMP-safe round-robin scheduler. Slots are permanently owned by a core,
//! but can now be added after secondary cores start. `slots_lock` serializes
//! publication and scanning of the slot table; a new user thread is placed on
//! the calling core, so no cross-core migration is required for pthreads.

const mmu = @import("../mm/mmu.zig");
const context = @import("../arch/aarch64/context.zig");
const task_mod = @import("task.zig");
const Task = task_mod.Task;
const Process = task_mod.Process;
const Vmm = @import("../mm/vmm.zig").Vmm;
const smp = @import("../smp.zig");
const pac = @import("../arch/aarch64/pac.zig");
const SpinLock = @import("../sync/spinlock.zig");
const timer = @import("../drivers/timer.zig");

const MAX_TASKS = 32;

const Slot = struct {
    task: Task,
    alive: bool,
    owner_core: u64,
    ulock_addr: u64 = NO_ULOCK_WAIT,
    sleep_until_ms: u64 = NO_SLEEP_WAIT,
    fd_wait: u64 = NO_FD_WAIT,
};

// Non-zero only while a task is blocked in __ulock_wait{,2}. This compact
// milestone wait queue is sufficient for user-space mutexes/futexes; all
// threads of a process share the same address space, so the user VA is a
// stable wait key.
const NO_ULOCK_WAIT: u64 = 0;
const NO_SLEEP_WAIT: u64 = 0;
const NO_FD_WAIT: u64 = ~@as(u64, 0);

var slots: [MAX_TASKS]Slot = undefined;
var count: usize = 0;
var slots_lock: SpinLock = .{};
var running: [smp.MAX_CPUS]?usize = [_]?usize{null} ** smp.MAX_CPUS;

pub fn spawn(user_regions: []const mmu.Region, entry: u64, stack_top: u64) usize {
    slots_lock.lock();
    defer slots_lock.unlock();
    if (count >= MAX_TASKS) @panic("sched: out of task slots");
    const idx = count;
    slots[idx] = .{
        .task = Task.create(user_regions, entry, stack_top),
        .alive = true,
        .owner_core = idx % smp.MAX_CPUS,
    };
    slots[idx].task.initProcess();
    slots[idx].task.initMachPorts();
    count += 1;
    return idx;
}

/// Record XNU bsdthread_register's per-process user entry points.
pub fn registerBsdThread(core_id: u64, thread_start: u64, workqueue_start: u64) bool {
    slots_lock.lock();
    defer slots_lock.unlock();
    const cur = running[core_id] orelse return false;
    slots[cur].task.process.bsdthread_start = thread_start;
    slots[cur].task.process.bsdthread_wqstart = workqueue_start;
    return true;
}

/// Implement XNU bsdthread_create (syscall 360). XNU's registered pthread
/// trampoline is entered with x0=pthread, x1=start_routine, and x2=arg.
pub fn createBsdThread(core_id: u64, start_routine: u64, arg: u64, stack_top: u64, pthread: u64) ?u64 {
    slots_lock.lock();
    defer slots_lock.unlock();
    const parent_idx = running[core_id] orelse return null;
    const thread_start = slots[parent_idx].task.process.bsdthread_start;
    if (thread_start == 0 or count >= MAX_TASKS) return null;
    const idx = count;
    slots[idx] = .{
        .task = Task.createThreadLike(&slots[parent_idx].task, thread_start, stack_top, pthread),
        .alive = true,
        .owner_core = core_id,
    };
    slots[idx].task.frame.x[1] = start_routine;
    slots[idx].task.frame.x[2] = arg;
    slots[idx].task.initMachPorts();
    count += 1;
    return idx + 1;
}

/// Park the current task on `addr` and restore another runnable task on the
/// same core when one exists. If this core has no other runnable peer, the
/// task instead self-parks by spinning in the kernel (woken by IRQs) until
/// another core clears `ulock_addr` via `wakeUlock`. This always blocks
/// properly instead of bouncing an EAGAIN spin back into userspace.
pub fn blockCurrentOnUlock(core_id: u64, frame: *context.Frame, addr: u64) bool {
    slots_lock.lock();
    const cur = running[core_id] orelse {
        slots_lock.unlock();
        return false;
    };
    if (nextAliveForCore(core_id, cur)) |next| {
        frame.x[0] = 0;
        slots[cur].task.frame = frame.*;
        slots[cur].task.frame.x[0] = 0;
        slots[cur].ulock_addr = addr;
        slots[cur].alive = false;
        restore(frame, core_id, next);
        slots_lock.unlock();
        return true;
    }
    slots[cur].ulock_addr = addr;
    slots_lock.unlock();
    while (true) {
        asm volatile ("wfe");
        slots_lock.lock();
        if (slots[cur].ulock_addr == NO_ULOCK_WAIT) {
            slots_lock.unlock();
            frame.x[0] = 0;
            return true;
        }
        slots_lock.unlock();
    }
}

/// Park the current task on `addr`, but also wake it when `deadline_ms` expires.
pub fn blockCurrentOnUlockUntil(core_id: u64, frame: *context.Frame, addr: u64, deadline_ms: u64) bool {
    slots_lock.lock();
    const cur = running[core_id] orelse {
        slots_lock.unlock();
        return false;
    };
    wakeExpiredSleepersLocked();
    if (deadline_ms <= timer.nowMs()) {
        slots_lock.unlock();
        frame.x[0] = 0;
        return true;
    }
    if (nextAliveForCore(core_id, cur)) |next| {
        frame.x[0] = 0;
        slots[cur].task.frame = frame.*;
        slots[cur].task.frame.x[0] = 0;
        slots[cur].ulock_addr = addr;
        slots[cur].sleep_until_ms = deadline_ms;
        slots[cur].alive = false;
        restore(frame, core_id, next);
        slots_lock.unlock();
        return true;
    }
    slots[cur].ulock_addr = addr;
    slots_lock.unlock();
    while (true) {
        asm volatile ("wfe");
        slots_lock.lock();
        if (slots[cur].ulock_addr == NO_ULOCK_WAIT) {
            slots_lock.unlock();
            frame.x[0] = 0;
            return true;
        }
        if (timer.nowMs() >= deadline_ms) {
            slots[cur].ulock_addr = NO_ULOCK_WAIT;
            slots_lock.unlock();
            frame.x[0] = 0;
            return true;
        }
        slots_lock.unlock();
    }
}

/// Park the current task until the monotonic millisecond deadline has passed.
/// Self-parks via a wfe spin when there is no other runnable peer on this
/// core, so the deadline is always honored rather than returning early.
pub fn blockCurrentUntil(core_id: u64, frame: *context.Frame, deadline_ms: u64) bool {
    slots_lock.lock();
    const cur = running[core_id] orelse {
        slots_lock.unlock();
        return false;
    };
    wakeExpiredSleepersLocked();
    if (deadline_ms <= timer.nowMs()) {
        slots_lock.unlock();
        frame.x[0] = 0;
        return true;
    }
    if (nextAliveForCore(core_id, cur)) |next| {
        frame.x[0] = 0;
        slots[cur].task.frame = frame.*;
        slots[cur].task.frame.x[0] = 0;
        slots[cur].sleep_until_ms = deadline_ms;
        slots[cur].alive = false;
        restore(frame, core_id, next);
        slots_lock.unlock();
        return true;
    }
    slots_lock.unlock();
    while (true) {
        asm volatile ("wfe");
        if (timer.nowMs() >= deadline_ms) {
            frame.x[0] = 0;
            return true;
        }
    }
}

/// Wake up to `max_count` tasks waiting on the given user address.
pub fn wakeUlock(addr: u64, max_count: u64) u64 {
    slots_lock.lock();
    defer slots_lock.unlock();
    var woken: u64 = 0;
    for (slots[0..count]) |*slot| {
        if (slot.ulock_addr != addr or (max_count != 0 and woken >= max_count)) continue;
        slot.ulock_addr = NO_ULOCK_WAIT;
        slot.sleep_until_ms = NO_SLEEP_WAIT;
        slot.alive = true;
        woken += 1;
    }
    return woken;
}

/// Fd reads cannot resume mid-syscall after a real context switch (the
/// resumed task would just return to userspace with a stale result), so
/// this always self-parks the calling core via a wfe spin instead of
/// switching to a peer task; callers should retry their read attempt after
/// this returns.
pub fn blockCurrentOnFd(core_id: u64, frame: *context.Frame, fd: u64) bool {
    _ = core_id;
    _ = frame;
    _ = fd;
    asm volatile ("wfe");
    return true;
}

pub fn wakeFd(fd: u64) u64 {
    slots_lock.lock();
    defer slots_lock.unlock();
    var woken: u64 = 0;
    for (slots[0..count]) |*slot| {
        if (slot.fd_wait != fd) continue;
        slot.fd_wait = NO_FD_WAIT;
        slot.alive = true;
        woken += 1;
    }
    return woken;
}

pub fn signalThread(thread_id: u64) bool {
    if (thread_id == 0) return false;
    slots_lock.lock();
    defer slots_lock.unlock();
    const idx: usize = @intCast(thread_id - 1);
    if (idx >= count) return false;
    wakeSlotLocked(idx);
    return true;
}

fn wakeSlotLocked(idx: usize) void {
    slots[idx].ulock_addr = NO_ULOCK_WAIT;
    slots[idx].sleep_until_ms = NO_SLEEP_WAIT;
    slots[idx].fd_wait = NO_FD_WAIT;
    // Interrupted blocking syscalls resume with EINTR.
    slots[idx].task.frame.x[0] = @bitCast(@as(i64, -4));
    slots[idx].alive = true;
}

/// Wake every thread that shares `proc` so a pending process signal can run.
pub fn wakeProcessForSignal(proc: *Process) void {
    slots_lock.lock();
    defer slots_lock.unlock();
    for (slots[0..count], 0..) |*slot, idx| {
        if (slot.task.process != proc) continue;
        wakeSlotLocked(idx);
    }
}

/// Wake a specific thread for a pending per-thread signal.
pub fn wakeTaskForSignal(task: *Task) void {
    slots_lock.lock();
    defer slots_lock.unlock();
    for (slots[0..count], 0..) |*slot, idx| {
        if (&slot.task != task) continue;
        wakeSlotLocked(idx);
        return;
    }
}

pub fn taskByThreadId(thread_id: u64) ?*Task {
    if (thread_id == 0) return null;
    slots_lock.lock();
    defer slots_lock.unlock();
    const idx: usize = @intCast(thread_id - 1);
    if (idx >= count) return null;
    return &slots[idx].task;
}

pub fn currentThreadId(core_id: u64) u64 {
    return (running[core_id] orelse return 0) + 1;
}

pub fn taskTable(idx: usize) *mmu.Table {
    return slots[idx].task.ttbr0;
}

pub fn setPacEnforcement(idx: usize, enforce: bool) void {
    slots[idx].task.pac_enforce = enforce;
}

pub fn setInitialRegister(idx: usize, reg: usize, value: u64) void {
    if (idx >= count or reg >= slots[idx].task.frame.x.len) return;
    slots[idx].task.frame.x[reg] = value;
}

/// Caller holds slots_lock.
fn nextAliveForCore(core_id: u64, from: usize) ?usize {
    if (count == 0) return null;
    var i = from;
    var checked: usize = 0;
    while (checked < count) : (checked += 1) {
        i = (i + 1) % count;
        if (slots[i].alive and slots[i].owner_core == core_id) return i;
    }
    return null;
}

/// Caller holds slots_lock.
fn firstAliveForCore(core_id: u64) ?usize {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (slots[i].alive and slots[i].owner_core == core_id) return i;
    }
    return null;
}

/// Caller holds slots_lock.
fn wakeExpiredSleepersLocked() void {
    const now = timer.nowMs();
    for (slots[0..count]) |*slot| {
        if (slot.sleep_until_ms != NO_SLEEP_WAIT and slot.sleep_until_ms <= now) {
            slot.sleep_until_ms = NO_SLEEP_WAIT;
            slot.ulock_addr = NO_ULOCK_WAIT;
            slot.alive = true;
            slot.fd_wait = NO_FD_WAIT;
        }
    }
}

fn haltForever() noreturn {
    while (true) asm volatile ("wfe");
}

fn restore(frame: *context.Frame, core_id: u64, idx: usize) void {
    running[core_id] = idx;
    frame.* = slots[idx].task.frame;
    mmu.switchTtbr0(slots[idx].task.ttbr0);
    pac.loadKeys(&slots[idx].task.pac_keys);
    pac.setEnforcement(slots[idx].task.pac_enforce);
}

extern fn enterUserspace(frame: *context.Frame, ttbr0_phys: u64) noreturn;

pub fn runCore(core_id: u64) noreturn {
    slots_lock.lock();
    const idx = firstAliveForCore(core_id) orelse {
        slots_lock.unlock();
        haltForever();
    };
    running[core_id] = idx;
    const task = &slots[idx].task;
    slots_lock.unlock();
    pac.loadKeys(&task.pac_keys);
    pac.setEnforcement(task.pac_enforce);
    enterUserspace(&task.frame, @intFromPtr(task.ttbr0));
}

pub fn tick(core_id: u64, frame: *context.Frame) void {
    slots_lock.lock();
    wakeExpiredSleepersLocked();
    const cur = running[core_id] orelse {
        slots_lock.unlock();
        return;
    };
    slots[cur].task.frame = frame.*;
    const next = nextAliveForCore(core_id, cur) orelse {
        slots_lock.unlock();
        return;
    };
    restore(frame, core_id, next);
    slots_lock.unlock();
}

pub fn exitCurrent(core_id: u64, frame: *context.Frame) void {
    slots_lock.lock();
    const cur = running[core_id] orelse {
        slots_lock.unlock();
        haltForever();
    };
    slots[cur].alive = false;
    const next = nextAliveForCore(core_id, cur) orelse {
        slots_lock.unlock();
        haltForever();
    };
    restore(frame, core_id, next);
    slots_lock.unlock();
}

/// Terminate the task associated with `frame` when delivery already holds the
/// current task pointer (same as exitCurrent for the running core).
pub fn exitCurrentTask(core_id: u64, frame: *context.Frame) void {
    exitCurrent(core_id, frame);
}

pub fn currentTask(core_id: u64) *Task {
    const cur = running[core_id] orelse @panic("sched: no current task");
    return &slots[cur].task;
}

pub fn tryCurrentTask(core_id: u64) ?*Task {
    const cur = running[core_id] orelse return null;
    return &slots[cur].task;
}

pub fn currentProcess(core_id: u64) *Process {
    return currentTask(core_id).process;
}

pub fn currentVmm(core_id: u64) *Vmm {
    return &currentTask(core_id).process.vmm;
}
