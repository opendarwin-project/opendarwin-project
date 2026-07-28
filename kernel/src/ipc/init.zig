const IpcSpace = @import("space.zig").IpcSpace;
const ipc_host = @import("host.zig");

var kernel_space: IpcSpace = undefined;

/// Initializes the core IPC subsystem. Called once during boot, after the
/// slab allocator is ready. Creates the kernel's own IPC space and
/// bootstraps the host port into it.
pub fn init() void {
    kernel_space.init();
    _ = ipc_host.bootstrap(&kernel_space);
}

pub fn getKernelSpace() *IpcSpace {
    return &kernel_space;
}
