//! Resource limits and usage: getrlimit, setrlimit, getrusage, alarm.

const std = @import("std");

const common = @import("common.zig");
const C = common;

pub const RLIMIT_CPU: c_int = 0;
pub const RLIMIT_FSIZE: c_int = 1;
pub const RLIMIT_DATA: c_int = 2;
pub const RLIMIT_STACK: c_int = 3;
pub const RLIMIT_CORE: c_int = 4;
pub const RLIMIT_AS: c_int = 5;
pub const RLIMIT_NOFILE: c_int = 8;

pub const RLIM_INFINITY: u64 = std.math.maxInt(u64) >> 1;

pub const Rlimit = extern struct {
    rlim_cur: u64 = RLIM_INFINITY,
    rlim_max: u64 = RLIM_INFINITY,
};

const Timeval = extern struct {
    tv_sec: isize = 0,
    tv_usec: isize = 0,
};

pub const Rusage = extern struct {
    ru_utime: Timeval = .{},
    ru_stime: Timeval = .{},
    ru_opaque: [14]i64 = .{0} ** 14,
};

var current_limits: [16]Rlimit = [_]Rlimit{.{}} ** 16;

fn initLimits() void {
    current_limits[RLIMIT_CPU] = .{ .rlim_cur = RLIM_INFINITY, .rlim_max = RLIM_INFINITY };
    current_limits[RLIMIT_FSIZE] = .{ .rlim_cur = RLIM_INFINITY, .rlim_max = RLIM_INFINITY };
    current_limits[RLIMIT_DATA] = .{ .rlim_cur = RLIM_INFINITY, .rlim_max = RLIM_INFINITY };
    current_limits[RLIMIT_STACK] = .{ .rlim_cur = 8 * 1024 * 1024, .rlim_max = 64 * 1024 * 1024 };
    current_limits[RLIMIT_CORE] = .{ .rlim_cur = 0, .rlim_max = RLIM_INFINITY };
    current_limits[RLIMIT_AS] = .{ .rlim_cur = RLIM_INFINITY, .rlim_max = RLIM_INFINITY };
    current_limits[RLIMIT_NOFILE] = .{ .rlim_cur = 256, .rlim_max = 10240 };
}

pub export fn getrlimit(resource: c_int, rlp: ?*Rlimit) c_int {
    const out = rlp orelse {
        common.errno = C.EINVAL;
        return -1;
    };
    if (resource < 0 or resource >= current_limits.len) {
        common.errno = C.EINVAL;
        return -1;
    }
    if (current_limits[0].rlim_max == 0) initLimits();
    out.* = current_limits[@intCast(resource)];
    return 0;
}

pub export fn setrlimit(resource: c_int, rlp: ?*const Rlimit) c_int {
    const inp = rlp orelse {
        common.errno = C.EINVAL;
        return -1;
    };
    if (resource < 0 or resource >= current_limits.len) {
        common.errno = C.EINVAL;
        return -1;
    }
    if (current_limits[0].rlim_max == 0) initLimits();
    if (inp.rlim_cur > inp.rlim_max) {
        common.errno = C.EINVAL;
        return -1;
    }
    current_limits[@intCast(resource)] = inp.*;
    return 0;
}

pub export fn getrusage(_: c_int, rusage: ?*Rusage) c_int {
    if (rusage) |out| out.* = .{};
    return 0;
}

pub export fn alarm(seconds: c_uint) c_uint {
    _ = seconds;
    return 0;
}
