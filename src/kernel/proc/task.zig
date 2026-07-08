const mmu = @import("../mm/mmu.zig");
const context = @import("../arch/aarch64/context.zig");

/// One EL0 task: its own address space (a superset table containing the
/// shared kernel mappings + this task's user segments - see mmu.zig's
/// module doc comment for why there's no separate TTBR1 kernel range yet)
/// plus its saved register frame. Milestone 1 is one thread per task, so
/// this struct doubles as that thread's state; a real thread/task split
/// comes later once more than one thread-per-task is needed.
pub const Task = struct {
    ttbr0: *mmu.Table,
    frame: context.Frame,

    /// Builds a task whose user address space maps `user_regions`, ready to
    /// start executing at `entry` (VA, == PA under this milestone's
    /// identity mapping) with `sp_el0` initially at `stack_top`.
    pub fn create(user_regions: []const mmu.Region, entry: u64, stack_top: u64) Task {
        var frame = context.Frame{
            .x = [_]u64{0} ** 31,
            .sp_el0 = stack_top,
            .elr_el1 = entry,
            .spsr_el1 = 0, // EL0t, all exception masks clear
            .esr_el1 = 0,
            .far_el1 = 0,
        };
        _ = &frame;
        return .{
            .ttbr0 = mmu.newTaskTable(user_regions),
            .frame = frame,
        };
    }
};
