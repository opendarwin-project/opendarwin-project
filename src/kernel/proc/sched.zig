//! Round-robin scheduler, SMP-aware via static per-core ownership: each
//! spawned task is assigned to exactly one core (at spawn time, before any
//! core besides the primary is even running), and a core's tick()/
//! exitCurrent()/runCore() only ever look at slots *it* owns. That sidesteps
//! needing a lock for the scheduler's own state entirely - no core ever
//! reads or writes another core's slots, so there is no data race despite
//! multiple cores running this same code concurrently. (Dynamic
//! load-balancing / task migration across cores is future work; this
//! milestone is about proving cores can safely run independent work at
//! all.)
//!
//! The context-switch trick (overwriting an exception frame in place) is
//! unchanged from the single-core version - see the frame-liveness comment
//! on switchTo() below.

const mmu = @import("../mm/mmu.zig");
const context = @import("../arch/aarch64/context.zig");
const Task = @import("task.zig").Task;
const Vmm = @import("../mm/vmm.zig").Vmm;
const smp = @import("../smp.zig");
const pac = @import("../arch/aarch64/pac.zig");

const MAX_TASKS = 8;

const Slot = struct {
    task: Task,
    alive: bool,
    owner_core: u64,
};

var slots: [MAX_TASKS]Slot = undefined;
var count: usize = 0;

/// Which slot (if any) each core is currently running. Written only by the
/// core it indexes (core N only ever writes running[N]), so - like the rest
/// of this file's per-core split - no lock is needed.
var running: [smp.MAX_CPUS]?usize = [_]?usize{null} ** smp.MAX_CPUS;

/// Registers a new task, statically assigned to core `count % MAX_CPUS`
/// (i.e. the Nth spawned task goes to core N, wrapping if there are more
/// tasks than cores). Must be called before any core (primary or
/// secondary) starts running tasks - single-threaded at this point, so no
/// locking is needed here either.
pub fn spawn(user_regions: []const mmu.Region, entry: u64, stack_top: u64) usize {
    if (count >= MAX_TASKS) @panic("sched: out of task slots");
    const idx = count;
    slots[idx] = .{
        .task = Task.create(user_regions, entry, stack_top),
        .alive = true,
        .owner_core = idx % smp.MAX_CPUS,
    };
    slots[idx].task.initMachPorts();
    count += 1;
    return idx;
}

/// The page table backing a spawned task, for mapping extra non-identity
/// ranges into it after spawn() (e.g. loader/dyld.zig's shared-cache blobs,
/// which live at their real dyld addresses rather than wherever their
/// physical backing was allocated - see mmu.zig's mapPages).
pub fn taskTable(idx: usize) *mmu.Table {
    return slots[idx].task.ttbr0;
}

/// Opts a spawned task out of PAC enforcement - see pac.zig's
/// `setEnforcement` doc comment on why loader/dyld.zig's dynamic binaries
/// need this.
pub fn setPacEnforcement(idx: usize, enforce: bool) void {
    slots[idx].task.pac_enforce = enforce;
}

pub fn setInitialRegister(idx: usize, reg: usize, value: u64) void {
    if (idx >= count or reg >= slots[idx].task.frame.x.len) return;
    slots[idx].task.frame.x[reg] = value;
}

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

fn firstAliveForCore(core_id: u64) ?usize {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (slots[i].alive and slots[i].owner_core == core_id) return i;
    }
    return null;
}

fn haltForever() noreturn {
    while (true) asm volatile ("wfe");
}

/// A context switch is overwriting `frame` (which lives on the kernel
/// exception stack, at exactly the address vectors.S's RESTORE_CONTEXT
/// will read back from before ERETing) with the next task's saved
/// registers, plus swapping TTBR0. RESTORE_CONTEXT + eret, unmodified,
/// does the rest.
fn switchTo(frame: *context.Frame, core_id: u64, idx: usize) void {
    running[core_id] = idx;
    frame.* = slots[idx].task.frame;
    mmu.switchTtbr0(slots[idx].task.ttbr0);
    pac.loadKeys(&slots[idx].task.pac_keys);
    pac.setEnforcement(slots[idx].task.pac_enforce);
}

/// Defined in arch/aarch64/task_entry.S.
extern fn enterUserspace(frame: *context.Frame, ttbr0_phys: u64) noreturn;

/// Runs this core's first owned task, or idles forever if it has none.
/// Called once by each core (primary and secondary alike) after its own
/// MMU/GIC/timer bring-up is done. Never returns.
pub fn runCore(core_id: u64) noreturn {
    const idx = firstAliveForCore(core_id) orelse haltForever();
    running[core_id] = idx;
    pac.loadKeys(&slots[idx].task.pac_keys);
    pac.setEnforcement(slots[idx].task.pac_enforce);
    enterUserspace(&slots[idx].task.frame, @intFromPtr(slots[idx].task.ttbr0));
}

/// Timer-tick entry point (called from the IRQ handler): preempts whatever
/// this core is running and hands off to the next alive task *this core
/// owns*, round-robin. No-op if this core has only one task (or none).
pub fn tick(core_id: u64, frame: *context.Frame) void {
    const cur = running[core_id] orelse return;
    slots[cur].task.frame = frame.*;
    const next = nextAliveForCore(core_id, cur) orelse return;
    switchTo(frame, core_id, next);
}

/// Voluntary exit (called from the `exit` syscall): marks the current task
/// dead and hands off to this core's next alive task. Halts this core if
/// none remain - there's no cross-core work-stealing yet (see the module
/// doc comment).
pub fn exitCurrent(core_id: u64, frame: *context.Frame) void {
    const cur = running[core_id] orelse haltForever();
    slots[cur].alive = false;
    // TODO: ipc_cleanup(&slots[cur].task.ipc_space);
    const next = nextAliveForCore(core_id, cur) orelse haltForever();
    switchTo(frame, core_id, next);
}

pub fn currentTask(core_id: u64) *Task {
    const cur = running[core_id] orelse @panic("sched: no current task");
    return &slots[cur].task;
}

pub fn currentVmm(core_id: u64) *Vmm {
    return &currentTask(core_id).vmm;
}
