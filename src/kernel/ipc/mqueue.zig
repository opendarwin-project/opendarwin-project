const SpinLock = @import("../sync/spinlock.zig");

pub const IpcMqueue = struct {
    lock: SpinLock = .{},
    first: ?*anyopaque,
    last: ?*anyopaque,
    msgcount: u32,
    qlimit: u16,
    seqno: u32,

    pub fn init(self: *IpcMqueue) void {
        self.* = .{
            .lock = .{},
            .first = null,
            .last = null,
            .msgcount = 0,
            .qlimit = 5,
            .seqno = 0,
        };
    }
};
