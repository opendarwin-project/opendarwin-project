const types = @import("types.zig");
const slab = @import("../mm/slab.zig");

/// Minimal Mach message header (see XNU osfmk/mach/message.h).
pub const MachMsgHeader = extern struct {
    msgh_bits: u32,
    msgh_size: u32,
    msgh_remote_port: types.mach_port_name_t,
    msgh_local_port: types.mach_port_name_t,
    msgh_voucher_port: types.mach_port_name_t,
    msgh_id: u32,
};

/// A kernel message buffer. This is a simplified version of XNU's ipc_kmsg.
/// The message body follows the header in the same allocation.
pub const IpcKmsg = struct {
    next: ?*IpcKmsg,
    ikm_size: u32,
    ikm_header: MachMsgHeader,

    pub fn alloc(header: MachMsgHeader) ?*IpcKmsg {
        if (header.msgh_size < @sizeOf(MachMsgHeader)) return null;
        const total = @sizeOf(IpcKmsg) + (header.msgh_size - @sizeOf(MachMsgHeader));
        const ptr = @as(*IpcKmsg, @ptrCast(@alignCast(slab.alloc(total))));
        ptr.next = null;
        ptr.ikm_size = header.msgh_size;
        ptr.ikm_header = header;
        return ptr;
    }

    pub fn free(kmsg: *IpcKmsg) void {
        slab.free(kmsg);
    }

    pub fn body(kmsg: *IpcKmsg) []u8 {
        const body_start = @intFromPtr(kmsg) + @sizeOf(IpcKmsg);
        return @as([*]u8, @ptrFromInt(body_start))[0 .. kmsg.ikm_header.msgh_size - @sizeOf(MachMsgHeader)];
    }
};
