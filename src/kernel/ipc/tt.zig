const types = @import("types.zig");
const IpcPort = @import("port.zig").IpcPort;
const IpcSpace = @import("space.zig").IpcSpace;
const ipc_right = @import("right.zig");
const ipc_kobject = @import("kobject.zig");

/// Create a self port for a task, bound to the task kernel object.
pub fn taskSelf(space: *IpcSpace, task_ptr: *anyopaque, name: *types.mach_port_name_t) void {
    const port = IpcPort.alloc();
    port.ip_receiver = space;
    port.ip_kobject = @ptrCast(task_ptr);

    const result = ipc_right.alloc(space, port, types.IE_BITS_TYPE_RECEIVE);
    name.* = result.name;
}

/// Create a self port for a thread, bound to the thread kernel object.
pub fn threadSelf(space: *IpcSpace, thread_ptr: *anyopaque, name: *types.mach_port_name_t) void {
    const port = IpcPort.alloc();
    port.ip_receiver = space;
    port.ip_kobject = @ptrCast(thread_ptr);

    const result = ipc_right.alloc(space, port, types.IE_BITS_TYPE_RECEIVE);
    name.* = result.name;
}
