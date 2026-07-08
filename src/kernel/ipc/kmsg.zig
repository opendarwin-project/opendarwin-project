const types = @import("types.zig");
const slab = @import("../mm/slab.zig");

/// A kernel message buffer. This is a simplified version of XNU's ipc_kmsg.
/// The message body follows the header in the same allocation.
pub const IpcKmsg = struct {
    next: ?*IpcKmsg,
    ikm_size: u32,
    ikm_header: mach_msg_header,

    pub fn alloc(msg_size: u32) *IpcKmsg {
        const total = @sizeOf(IpcKmsg) + msg_size;
        const ptr = @as(*IpcKmsg, @ptrCast(slab.alloc(total)));
        ptr.next = null;
        ptr.ikm_size = @sizeOf(IpcKmsg) + msg_size;
        ptr.ikm_header = .{
            .msgh_bits = 0,
            .msgh_size = msg_size,
            .msgh_remote_port = types.MACH_PORT_NULL,
            .msgh_local_port = types.MACH_PORT_NULL,
            .msgh_voucher_port = types.MACH_PORT_NULL,
            .msgh_id = 0,
        };
        return ptr;
    }

    pub fn free(kmsg: *IpcKmsg) void {
        slab.free(kmsg);
    }

    pub fn data(kmsg: *IpcKmsg) []u8 {
        const body_start = @intFromPtr(kmsg) + @sizeOf(IpcKmsg);
        return @as([*]u8, @ptrFromInt(body_start))[0 .. kmsg.ikm_size - @sizeOf(IpcKmsg)];
    }
};

/// Minimal Mach message header (see XNU osfmk/mach/message.h).
const mach_msg_header = extern struct {
    msgh_bits: u32,
    msgh_size: u32,
    msgh_remote_port: types.mach_port_name_t,
    msgh_local_port: types.mach_port_name_t,
    msgh_voucher_port: types.mach_port_name_t,
    msgh_id: u32,
};
