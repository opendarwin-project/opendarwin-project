//! Tiny Darwin-target Zig smoke binary for OpenDarwin.
//!
//! This intentionally avoids std so its first dependencies are limited to the
//! minimal FOSS libSystem dylib.

extern fn write(fd: c_int, buf: [*]const u8, len: usize) isize;
extern fn exit(status: c_int) noreturn;

/// Minimal crt entry selected directly by LC_MAIN. It intentionally bypasses
/// Zig's hosted Darwin start wrapper, which currently expects dyld-provided
/// process/runtime state that OpenDarwin does not implement yet.
pub export fn zig_smoke_entry() callconv(.c) noreturn {
    exit(@intCast(main()));
}

pub fn main() u8 {
    const msg = "hello from Zig main via minimal libSystem\n";
    _ = write(1, msg.ptr, msg.len);
    return 0;
}
