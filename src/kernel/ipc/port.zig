const types = @import("types.zig");
const IpcObject = @import("object.zig").IpcObject;
const IpcMqueue = @import("mqueue.zig").IpcMqueue;
const IpcSpace = @import("space.zig").IpcSpace;
const slab = @import("../mm/slab.zig");

pub const IpcPort = struct {
    ip_object: IpcObject,
    ip_receiver: ?*IpcSpace,
    ip_receiver_name: types.mach_port_name_t,
    ip_messages: IpcMqueue,
    ip_kobject: ?*anyopaque,
    ip_nsrequest: ?*IpcPort,
    ip_pdrequest: ?*IpcPort,
    ip_srights: u32,
    ip_sorights: u32,
    ip_tempowner: bool,

    pub fn alloc() *IpcPort {
        const port = slab.allocObj(IpcPort);
        port.ip_object.init(.PORT);
        port.ip_receiver = null;
        port.ip_receiver_name = types.MACH_PORT_NULL;
        port.ip_messages.init();
        port.ip_kobject = null;
        port.ip_nsrequest = null;
        port.ip_pdrequest = null;
        port.ip_srights = 0;
        port.ip_sorights = 0;
        port.ip_tempowner = false;
        return port;
    }

    pub fn dealloc(port: *IpcPort) void {
        slab.free(port);
    }
};
