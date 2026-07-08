//! Minimal round-robin scheduler. Single core for now (proc/task.zig
//! predates SMP); `current` is a plain global rather than per-CPU state.
//!
//! The key trick: an exception frame (context.Frame) lives on the kernel
//! stack at exactly the address vectors.S's RESTORE_CONTEXT will read back
//! from before ERETing. So "context switch" is just: save the interrupted
//! task's registers into its slot, overwrite the *same* stack frame with
//! the next task's saved registers, and swap TTBR0 - the trampoline's
//! existing RESTORE_CONTEXT + eret does the rest, unmodified. (The very
//! first launch, sched.start(), is different: see task_entry.S's comment
//! on why it can't reuse that same sp-relative macro.)

const mmu = @import("../mm/mmu.zig");
const context = @import("../arch/aarch64/context.zig");
const Task = @import("task.zig").Task;

const MAX_TASKS = 8;

const Slot = struct {
    task: Task,
    alive: bool,
};

var slots: [MAX_TASKS]Slot = undefined;
var count: usize = 0;
var current: usize = 0;

/// Registers a new task with the scheduler. Must be called before start();
/// there's no way to add tasks after the scheduler is running yet (no
/// locking - single core, no reentrancy).
pub fn spawn(user_regions: []const mmu.Region, entry: u64, stack_top: u64) void {
    if (count >= MAX_TASKS) @panic("sched: out of task slots");
    slots[count] = .{ .task = Task.create(user_regions, entry, stack_top), .alive = true };
    count += 1;
}

fn nextAlive(from: usize) ?usize {
    if (count == 0) return null;
    var i = from;
    var checked: usize = 0;
    while (checked < count) : (checked += 1) {
        i = (i + 1) % count;
        if (slots[i].alive) return i;
    }
    return null;
}

fn haltForever() noreturn {
    while (true) asm volatile ("wfe");
}

fn switchTo(frame: *context.Frame, idx: usize) void {
    current = idx;
    frame.* = slots[idx].task.frame;
    mmu.switchTtbr0(slots[idx].task.ttbr0);
}

/// Defined in arch/aarch64/task_entry.S.
extern fn enterUserspace(frame: *context.Frame, ttbr0_phys: u64) noreturn;

/// Starts the first registered task. Never returns.
pub fn start() noreturn {
    if (count == 0) @panic("sched: start() with no tasks");
    current = 0;
    enterUserspace(&slots[0].task.frame, @intFromPtr(slots[0].task.ttbr0));
}

/// Timer-tick entry point (called from the IRQ handler): preempts whatever
/// is running and hands off to the next alive task round-robin. If nothing
/// else is alive, the current task just keeps running (no-op).
pub fn tick(frame: *context.Frame) void {
    if (count == 0) return;
    slots[current].task.frame = frame.*;
    const next = nextAlive(current) orelse return;
    switchTo(frame, next);
}

/// Voluntary exit (called from the `exit` syscall): marks the current task
/// dead and hands off to the next alive one. If none remain, halts - there
/// is nothing left to schedule and no real init/idle process yet.
pub fn exitCurrent(frame: *context.Frame) void {
    slots[current].alive = false;
    const next = nextAlive(current) orelse haltForever();
    switchTo(frame, next);
}
