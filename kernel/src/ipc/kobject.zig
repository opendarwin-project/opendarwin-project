const types = @import("types.zig");
const IpcPort = @import("port.zig").IpcPort;

pub const KObjectType = enum(u32) {
    NONE,
    TASK,
    THREAD,
    HOST,
    HOST_PRIV,
    PROCESSOR_SET,
};

pub const IpcKobject = struct {
    kotype: KObjectType,
    ptr: ?*anyopaque,

    pub fn none() IpcKobject {
        return .{ .kotype = .NONE, .ptr = null };
    }

    pub fn make(comptime T: type, ptr: *T, kotype: KObjectType) IpcKobject {
        return .{ .kotype = kotype, .ptr = @ptrCast(ptr) };
    }

    pub fn get(comptime T: type, ko: *const IpcKobject) ?*T {
        return @ptrCast(@alignCast(ko.ptr));
    }
};
