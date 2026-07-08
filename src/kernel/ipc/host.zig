const types = @import("types.zig");
const IpcPort = @import("port.zig").IpcPort;
const IpcSpace = @import("space.zig").IpcSpace;
const ipc_right = @import("right.zig");

var host_port: ?*IpcPort = null;

pub fn bootstrap(space: *IpcSpace) types.mach_port_name_t {
    const port = IpcPort.alloc();
    port.ip_receiver = space;
    host_port = port;

    const result = ipc_right.alloc(space, port, types.IE_BITS_TYPE_RECEIVE);
    return result.name;
}

pub fn getHostPort() *IpcPort {
    return host_port orelse @panic("host port not initialized");
}
