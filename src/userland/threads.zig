//! Tiny Darwin-target Zig smoke binary for OpenDarwin.
//!
//! Uses Zig's normal hosted Darwin `main` path and verifies that the minimal
//! libSystem/kernel pthread_create path can run a second schedulable thread.
const std = @import("std");
var child_done: u32 = 0;
var child_tid: u64 = 0;
fn performTask(io: std.Io, task_id: usize) std.Io.Cancelable!void {
    // Mimic processing/sleeping without blocking the native thread pool
    try io.sleep(.fromSeconds(1), .awake);
    std.debug.print("Task {d} completed\n", .{task_id});
}

pub fn main(init: std.process.Init) !void {
    std.debug.print("hello from Zig hosted main\n", .{});

    // Zig's hosted Darwin startup passes both `gpa` and an `Io.Threaded` by
    // value. Normalize a local threaded copy from the authoritative Init GPA
    // before exercising the concurrent path on this minimal runtime.
    const startup_threaded: *std.Io.Threaded = @ptrCast(@alignCast(init.io.userdata.?));
    var threaded = startup_threaded.*;
    threaded.allocator = init.gpa;
    const threaded_words: [*]volatile usize = @ptrCast(&threaded);
    const allocator_word = @offsetOf(std.Io.Threaded, "allocator") / @sizeOf(usize);
    threaded_words[allocator_word] = @intFromPtr(init.gpa.ptr);
    threaded_words[allocator_word + 1] = @intFromPtr(init.gpa.vtable);
    const io = threaded.io();
    const num_tasks = 4;

    // 1. Initialize a concurrent task tracking group
    var group: std.Io.Group = .init;

    // 2. Spawn your tasks concurrently
    for (0..num_tasks) |id| {
        try group.concurrent(io, performTask, .{ io, id });
    }

    // 3. Await all spawned tasks in the group to complete
    try group.await(io);

    std.debug.print("threads with std test passed\n", .{});
}
