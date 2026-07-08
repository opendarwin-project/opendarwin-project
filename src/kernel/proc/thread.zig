const Task = @import("task.zig").Task;
const context = @import("../arch/aarch64/context.zig");

/// Defined in arch/aarch64/task_entry.S: installs task.ttbr0, restores
/// task.frame's registers, and ERETs into EL0. Never returns.
extern fn enterUserspace(frame: *context.Frame, ttbr0_phys: u64) noreturn;

/// Milestone 1 has no scheduler - one thread per task, and starting it is a
/// one-way trip into EL0. A real dispatcher (multiple threads, timer-driven
/// preemption) is future work once more than one task exists.
pub fn enter(task: *Task) noreturn {
    enterUserspace(&task.frame, @intFromPtr(task.ttbr0));
}
