//! Tiny Darwin-target Zig smoke binary for OpenDarwin.
//!
//! Uses Zig's normal hosted Darwin `main` path and verifies that the minimal
//! libSystem/kernel pthread_create path can run Zig `std.Io` concurrent tasks.
const std = @import("std");

fn performTask(io: std.Io, task_id: usize) std.Io.Cancelable!void {
    try io.sleep(.fromSeconds(1), .awake);
    const messages = [_][]const u8{ "Task 0 completed\n", "Task 1 completed\n", "Task 2 completed\n", "Task 3 completed\n" };
    if (task_id < messages.len) _ = std.debug.print("{s}", .{messages[task_id]});
}

pub fn main(init: std.process.Init) !void {
    _ = std.debug.print("hello from Zig hosted main\n", .{});

    const io = init.io;
    const num_tasks = 4;

    var group: std.Io.Group = .init;
    for (0..num_tasks) |id| {
        try group.concurrent(io, performTask, .{ io, id });
    }
    try group.await(io);

    _ = std.debug.print("threads with std test passed\n", .{});
}
