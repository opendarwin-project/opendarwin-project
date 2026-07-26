const mmu = @import("../mm/mmu.zig");
const context = @import("../arch/aarch64/context.zig");
const pac = @import("../arch/aarch64/pac.zig");
const IpcSpace = @import("../ipc/space.zig").IpcSpace;
const Vmm = @import("../mm/vmm.zig").Vmm;
const types = @import("../ipc/types.zig");
const tt = @import("../ipc/tt.zig");
const IpcPort = @import("../ipc/port.zig").IpcPort;
const ipc_right = @import("../ipc/right.zig");

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
    task_self_name: types.mach_port_name_t = types.MACH_PORT_NULL,
    thread_self_name: types.mach_port_name_t = types.MACH_PORT_NULL,
    reply_port_name: types.mach_port_name_t = types.MACH_PORT_NULL,
    vmm: Vmm,
    /// Whether SCTLR_EL1's PAC-enable bits should be on while this task
    /// runs - see pac.zig's `setEnforcement` doc comment. Defaults to true
    /// (existing behavior for every task except loader/dyld.zig's dynamic
    /// binaries, which opt out via sched.setPacEnforcement after spawning).
    pac_enforce: bool = true,

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
            .vmm = undefined,
        };
        task.ipc_space.init();
        task.vmm = Vmm.init(task.ttbr0);
        return task;
    }

    pub fn initMachPorts(self: *Task) void {
        tt.taskSelf(&self.ipc_space, @ptrCast(self), &self.task_self_name);
        tt.threadSelf(&self.ipc_space, @ptrCast(self), &self.thread_self_name);

        const port = IpcPort.alloc();
        port.ip_receiver = &self.ipc_space;
        const result = ipc_right.alloc(&self.ipc_space, port, types.IE_BITS_TYPE_RECEIVE);
        self.reply_port_name = result.name;
        port.ip_receiver_name = self.reply_port_name;
    }
};
