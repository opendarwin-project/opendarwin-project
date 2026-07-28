//! sysctl / sysctlbyname implementations.

const common = @import("common.zig");
const C = common;

pub export fn sysctlbyname(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*anyopaque, newlen: usize) c_int {
    _ = newp;
    _ = newlen;
    if (C.cstrEq(name, "hw.ncpu") or C.cstrEq(name, "hw.activecpu") or C.cstrEq(name, "hw.logicalcpu") or C.cstrEq(name, "hw.physicalcpu")) {
        return C.sysctlCopyValue(u32, oldp, oldlenp, 4);
    }
    if (C.cstrEq(name, "hw.pagesize")) {
        return C.sysctlCopyValue(u32, oldp, oldlenp, 4096);
    }
    if (C.cstrEq(name, "hw.memsize")) {
        return C.sysctlCopyValue(u64, oldp, oldlenp, 128 * 1024 * 1024);
    }
    if (C.cstrEq(name, "kern.osrelease")) {
        return C.sysctlCopyOut(oldp, oldlenp, "24.0.0\x00".ptr, 7);
    }
    if (C.cstrEq(name, "kern.ostype")) {
        return C.sysctlCopyOut(oldp, oldlenp, "Darwin\x00".ptr, 7);
    }
    if (C.cstrEq(name, "kern.osversion")) {
        return C.sysctlCopyOut(oldp, oldlenp, "24.0.0\x00".ptr, 7);
    }
    if (C.cstrEq(name, "hw.cachelinesize")) {
        return C.sysctlCopyValue(u32, oldp, oldlenp, 64);
    }
    if (C.cstrEq(name, "hw.l1icachesize")) {
        return C.sysctlCopyValue(u32, oldp, oldlenp, 16384);
    }
    if (C.cstrEq(name, "hw.l1dcachesize")) {
        return C.sysctlCopyValue(u32, oldp, oldlenp, 16384);
    }
    if (C.cstrEq(name, "hw.l2cachesize")) {
        return C.sysctlCopyValue(u32, oldp, oldlenp, 2097152);
    }
    return C.stubErr("sysctlbyname");
}

pub export fn sysctl(mib: ?*c_int, miblen: c_uint, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*anyopaque, newlen: usize) c_int {
    _ = mib;
    _ = miblen;
    _ = oldp;
    _ = newp;
    _ = newlen;
    if (oldlenp) |lenp| {
        lenp.* = 0;
    }
    return C.stubErr("sysctl");
}

pub export fn confstr(_: c_int, _: [*]u8, _: usize) usize {
    return 0;
}

pub export fn sysconf(_: c_int) c_long {
    return -1;
}

pub export fn uname(_: ?*anyopaque) c_int {
    return C.stubErr("uname");
}
