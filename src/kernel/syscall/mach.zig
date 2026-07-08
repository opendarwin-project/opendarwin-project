const context = @import("../arch/aarch64/context.zig");
const numbers = @import("numbers.zig");

const handler_type = *const fn (frame: *context.Frame) void;

pub const table: [64]?handler_type = init: {
    var t: [64]?handler_type = [_]?handler_type{null} ** 64;
    t[numbers.MACH_thread_self_trap] = machThreadSelf;
    t[numbers.MACH_task_self_trap] = machTaskSelf;
    t[numbers.MACH_host_self_trap] = machHostSelf;
    t[numbers.MACH_mach_reply_port] = machReplyPort;
    break :init t;
};

pub fn handle(frame: *context.Frame) void {
    const num = frame.x[16];
    if (num >= 64) return;
    const handler = table[num] orelse return;
    handler(frame);
}

fn machThreadSelf(frame: *context.Frame) void {
    _ = frame;
}

fn machTaskSelf(frame: *context.Frame) void {
    _ = frame;
}

fn machHostSelf(frame: *context.Frame) void {
    _ = frame;
}

fn machReplyPort(frame: *context.Frame) void {
    _ = frame;
}
