const mmu = @import("../mm/mmu.zig");
const context = @import("../arch/aarch64/context.zig");
const pac = @import("../arch/aarch64/pac.zig");
const IpcSpace = @import("../ipc/space.zig").IpcSpace;

var next_pac_seed: u64 = 0x5EED_5EED_5EED_5EED;

/// One EL0 task: its own address space (a superset table containing the
/// shared kernel mappings + this task's user segments - see mmu.zig's
/// module doc comment for why there's no separate TTBR1 kernel range yet)
/// plus its saved register frame. Milestone 1 is one thread per task, so
/// this struct doubles as that thread's state; a real thread/task split
/// comes later once more than one thread-per-task is needed.
pub const Task = struct {
    ttbr0: *mmu.Table,
    frame: context.Frame,
    /// Distinct per task (see pac.zig's module doc comment on why these
    /// aren't cryptographically random yet) - installed on every switch to
    /// this task, same as TTBR0, since the key registers aren't banked in
    /// hardware.
    pac_keys: pac.Keys,
    ipc_space: IpcSpace,

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
        next_pac_seed +%= 1;
        var task: Task = .{
            .ttbr0 = mmu.newTaskTable(user_regions),
            .frame = frame,
            .pac_keys = pac.deriveKeys(next_pac_seed),
            .ipc_space = undefined,
        };
        task.ipc_space.init();
        return task;
    }
};
