//! Guest smoke test running vibeutils `free -h` in OpenDarwin userspace.

const std = @import("std");
const free = @import("vibeutils_free");

pub fn main(init: std.process.Init) !void {
    _ = std.debug.print("--- free -h smoke start ---\n", .{});

    const io = init.io;
    const allocator = init.arena.allocator();

    const stdout_file = std.Io.File.stdout();
    const stderr_file = std.Io.File.stderr();

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = stdout_file.writerStreaming(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [0]u8 = .{};
    var stderr_writer = stderr_file.writerStreaming(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const args = [_][]const u8{"-h"};
    const rc = try free.runFree(allocator, io, &args, stdout, stderr);

    try stdout.flush();
    try stderr.flush();

    _ = std.debug.print("--- free -h smoke finished (rc={d}) ---\n", .{rc});
}
