const SpinLock = @import("../sync/spinlock.zig");
const IpcKmsg = @import("kmsg.zig").IpcKmsg;

pub const IpcMqueue = struct {
    lock: SpinLock = .{},
    first: ?*IpcKmsg,
    last: ?*IpcKmsg,
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

    pub fn enqueue(self: *IpcMqueue, msg: *IpcKmsg) bool {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.msgcount >= self.qlimit) return false;
        msg.next = null;
        if (self.last) |last| {
            last.next = msg;
        } else {
            self.first = msg;
        }
        self.last = msg;
        self.msgcount += 1;
        return true;
    }

    pub fn dequeue(self: *IpcMqueue) ?*IpcKmsg {
        self.lock.lock();
        defer self.lock.unlock();
        const msg = self.first orelse return null;
        self.first = msg.next;
        if (self.first == null) self.last = null;
        msg.next = null;
        self.msgcount -= 1;
        self.seqno += 1;
        return msg;
    }
};
