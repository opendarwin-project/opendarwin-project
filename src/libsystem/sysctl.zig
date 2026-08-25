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

pub export fn getpagesize() c_int {
    return 4096;
}

const CTL_HW: c_int = 6;
const HW_MEMSIZE: c_int = 24;
const HW_PAGESIZE: c_int = 7;
const HW_NCPU: c_int = 3;
const CTL_VM: c_int = 2;
const VM_SWAPUSAGE: c_int = 5;

const xsw_usage = extern struct {
    xsu_total: u64 = 0,
    xsu_avail: u64 = 0,
    xsu_used: u64 = 0,
    xsu_pagesize: u32 = 4096,
    xsu_encrypted: bool = false,
};

pub export fn sysctl(mib: ?[*]const c_int, miblen: c_uint, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*anyopaque, newlen: usize) c_int {
    _ = newp;
    _ = newlen;
    const mib_ptr = mib orelse return C.stubErr("sysctl");
    if (miblen >= 2) {
        const top = mib_ptr[0];
        const sub = mib_ptr[1];
        if (top == CTL_HW) {
            if (sub == HW_MEMSIZE) {
                return C.sysctlCopyValue(u64, oldp, oldlenp, 128 * 1024 * 1024);
            }
            if (sub == HW_PAGESIZE) {
                return C.sysctlCopyValue(u32, oldp, oldlenp, 4096);
            }
            if (sub == HW_NCPU) {
                return C.sysctlCopyValue(u32, oldp, oldlenp, 4);
            }
        } else if (top == CTL_VM) {
            if (sub == VM_SWAPUSAGE) {
                const swap = xsw_usage{};
                return C.sysctlCopyValue(xsw_usage, oldp, oldlenp, swap);
            }
        }
    }
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
