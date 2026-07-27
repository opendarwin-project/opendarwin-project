//! Time functions: clock_gettime, clock_getres, nanosleep, gettimeofday,
//! mach_absolute_time, mach_timebase_info, usleep, sleep.

const common = @import("common.zig");
const C = common;

const LibcTimespec = extern struct {
    tv_sec: isize,
    tv_nsec: isize,
};

const LibcTimeval = extern struct {
    tv_sec: isize,
    tv_usec: isize,
};

var clock_ms: usize = 0;

pub export fn clock_gettime(_: c_int, tp: ?*anyopaque) c_int {
    const out = tp orelse {
        common.errno = C.EINVAL;
        return -1;
    };
    // Until wall-clock syscalls are exposed, provide a monotonic coarse clock
    // that advances on observation. `nanosleep` itself is kernel-timer backed.
    clock_ms +%= 5;
    const ts = @as(*LibcTimespec, @ptrCast(@alignCast(out)));
    ts.tv_sec = @intCast(clock_ms / 1000);
    ts.tv_nsec = @intCast((clock_ms % 1000) * 1_000_000);
    return 0;
}

pub export fn clock_getres(_: c_int, tp: ?*anyopaque) c_int {
    if (tp) |out| {
        const ts = @as(*LibcTimespec, @ptrCast(@alignCast(out)));
        ts.tv_sec = 0;
        ts.tv_nsec = 5_000_000;
    }
    return 0;
}

/// Darwin has no dedicated nanosleep syscall; libc's nanosleep() is built
/// on top of __semwait_signal(cond_sem=0, mutex_sem=0, timeout=1,
/// relative=1, tv_sec, tv_nsec).
pub export fn nanosleep(req: ?*const anyopaque, rem: ?*anyopaque) c_int {
    _ = rem;
    const p = req orelse {
        common.errno = C.EINVAL;
        return -1;
    };
    const ts = @as(*const LibcTimespec, @ptrCast(@alignCast(p))).*;
    const ret = C.darwinSyscall6(
        C.SYS___semwait_signal,
        0,
        0,
        1,
        1,
        @bitCast(@as(i64, @intCast(ts.tv_sec))),
        @bitCast(@as(i64, @intCast(ts.tv_nsec))),
    );
    return @intCast(C.setErrnoFromNegative(ret));
}

pub export fn usleep(usec: c_uint) c_int {
    const ts = LibcTimespec{
        .tv_sec = @intCast(@as(u64, usec) / 1_000_000),
        .tv_nsec = @intCast((@as(u64, usec) % 1_000_000) * 1000),
    };
    return nanosleep(@ptrCast(&ts), null);
}

pub export fn sleep(seconds: c_uint) c_uint {
    const ts = LibcTimespec{
        .tv_sec = @intCast(seconds),
        .tv_nsec = 0,
    };
    _ = nanosleep(@ptrCast(&ts), null);
    return 0;
}

pub export fn gettimeofday(tp: ?*anyopaque, tzp: ?*anyopaque) c_int {
    _ = tzp;
    if (tp) |out| {
        const tv = @as(*LibcTimeval, @ptrCast(@alignCast(out)));
        clock_ms +%= 1;
        tv.tv_sec = @intCast(clock_ms / 1000);
        tv.tv_usec = @intCast((clock_ms % 1000) * 1000);
    }
    return 0;
}

pub export fn mach_absolute_time() u64 {
    // Return a coarse tick count — sufficient for CF's relative time measurements.
    clock_ms +%= 1;
    return @intCast(clock_ms);
}

const MachTimebaseInfo = extern struct {
    numer: u32 = 1,
    denom: u32 = 1,
};

pub export fn mach_timebase_info(info: ?*MachTimebaseInfo) c_int {
    if (info) |p| {
        p.numer = 1;
        p.denom = 1;
    }
    return 0;
}

pub export fn mach_timebase_info_trap(info: ?*MachTimebaseInfo) c_int {
    return mach_timebase_info(info);
}

pub export fn time(t: ?*i64) i64 {
    clock_ms +%= 1;
    const seconds: i64 = @intCast(clock_ms / 1000);
    if (t) |out| out.* = seconds;
    return seconds;
}

pub export fn mktime(_: ?*anyopaque) i64 {
    return 0;
}

const LibcTm = extern struct {
    tm_sec: c_int = 0,
    tm_min: c_int = 0,
    tm_hour: c_int = 0,
    tm_mday: c_int = 1,
    tm_mon: c_int = 0,
    tm_year: c_int = 70, // 1970
    tm_wday: c_int = 4, // Thursday
    tm_yday: c_int = 0,
    tm_isdst: c_int = 0,
};

var static_tm: LibcTm = .{};

pub export fn localtime_r(timer: ?*const i64, result: ?*anyopaque) ?*anyopaque {
    _ = timer;
    if (result) |out| {
        const dest: *LibcTm = @ptrCast(@alignCast(out));
        dest.* = static_tm;
        return result;
    }
    return null;
}
