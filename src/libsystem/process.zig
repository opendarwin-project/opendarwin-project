//! Process management: getpid, kill, fork, execve, wait4, setpgid, etc.

const common = @import("common.zig");
const C = common;

pub export fn getpid() c_int {
    const ret = C.darwinSyscall3(C.SYS_getpid, 0, 0, 0);
    return @intCast(C.setErrnoFromNegative(ret));
}

pub export fn getppid() c_int {
    // Stub: return 1 (kernel)
    return 1;
}

pub export fn getuid() c_int {
    return 0;
}

pub export fn geteuid() c_int {
    return 0;
}

pub export fn getgid() c_int {
    return 0;
}

pub export fn getegid() c_int {
    return 0;
}

// proc_pidinfo constants (subset).
pub const PROC_PIDPATHINFO: c_int = 11;
pub const PROC_PIDPATHINFO_SIZE: c_int = 1024;

pub export fn proc_pidinfo(
    pid: c_int,
    flavor: c_int,
    arg: u64,
    buffer: ?*anyopaque,
    buffersize: c_int,
) c_int {
    _ = pid;
    _ = arg;
    if (buffersize <= 0) return 0;
    if (buffer) |p| {
        const bytes: [*]u8 = @ptrCast(p);
        var i: usize = 0;
        const limit: usize = @intCast(buffersize);
        while (i < limit) : (i += 1) bytes[i] = 0;
        if (flavor == PROC_PIDPATHINFO and buffersize > 1) {
            const path = "/usr/lib/libSystem.B.dylib";
            const n = @min(path.len, @as(usize, @intCast(buffersize - 1)));
            @memcpy(bytes[0..n], path[0..n]);
            bytes[n] = 0;
            return @intCast(n + 1);
        }
    }
    return 0;
}

pub export fn kill(pid: c_int, sig: c_int) c_int {
    const ret = C.darwinSyscall3(C.SYS_kill, @intCast(pid), @intCast(sig), 0);
    return @intCast(C.setErrnoFromNegative(ret));
}

pub export fn fork() c_int {
    return C.stubErr("fork");
}

pub export fn vfork() c_int {
    return C.stubErr("vfork");
}

pub export fn execve(_: [*:0]const u8, _: ?*const anyopaque, _: ?*const anyopaque) c_int {
    return C.stubErr("execve");
}

pub export fn execvp(_: [*:0]const u8, _: ?*const anyopaque) c_int {
    return C.stubErr("execvp");
}

pub export fn execvpe(_: [*:0]const u8, _: ?*const anyopaque, _: ?*const anyopaque) c_int {
    return C.stubErr("execvpe");
}

pub export fn wait4(_: c_int, _: *c_int, _: c_int, _: ?*anyopaque) c_int {
    return C.stubErr("wait4");
}

pub export fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int {
    _ = pid;
    _ = options;
    if (status) |s| s.* = 0;
    return C.stubErr("waitpid");
}

pub export fn setpgid(_: c_int, _: c_int) c_int {
    return C.stubErr("setpgid");
}

pub export fn getpgid(_: c_int) c_int {
    return 1;
}

pub export fn setpgrp() c_int {
    return 0;
}

pub export fn setsid() c_int {
    return C.stubErr("setsid");
}

pub export fn setregid(_: c_int, _: c_int) c_int {
    return C.stubErr("setregid");
}

pub export fn setreuid(_: c_int, _: c_int) c_int {
    return C.stubErr("setreuid");
}

pub export fn setuid(_: c_int) c_int {
    return C.stubErr("setuid");
}

pub export fn setgid(_: c_int) c_int {
    return C.stubErr("setgid");
}

pub export fn getgroups(_: c_int, _: ?*c_int) c_int {
    return 0;
}

pub export fn issetugid() c_int {
    return 0;
}

pub export fn syscall(num: c_long, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize) c_long {
    _ = a3;
    _ = a4;
    _ = a5;
    return @intCast(C.darwinSyscall3(@intCast(num), a0, a1, a2));
}
