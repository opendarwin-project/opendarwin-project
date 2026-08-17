//! sysctl / sysctlbyname implementations.

use core::ffi::{c_char, c_int, c_long, c_uint, c_void};

use crate::common;

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sysctlbyname(
    name: *const c_char,
    oldp: *mut c_void,
    oldlenp: *mut usize,
    _newp: *mut c_void,
    _newlen: usize,
) -> c_int {
    if common::cstrEq(name, "hw.ncpu")
        || common::cstrEq(name, "hw.activecpu")
        || common::cstrEq(name, "hw.logicalcpu")
        || common::cstrEq(name, "hw.physicalcpu")
    {
        return common::sysctlCopyValue(oldp, oldlenp, 4u32);
    }
    if common::cstrEq(name, "hw.pagesize") {
        return common::sysctlCopyValue(oldp, oldlenp, 4096u32);
    }
    if common::cstrEq(name, "hw.memsize") {
        return common::sysctlCopyValue(oldp, oldlenp, (128 * 1024 * 1024) as u64);
    }
    if common::cstrEq(name, "kern.osrelease") {
        return common::sysctlCopyOut(oldp, oldlenp, b"24.0.0\0".as_ptr(), 7);
    }
    if common::cstrEq(name, "kern.ostype") {
        return common::sysctlCopyOut(oldp, oldlenp, b"Darwin\0".as_ptr(), 7);
    }
    if common::cstrEq(name, "kern.osversion") {
        return common::sysctlCopyOut(oldp, oldlenp, b"24.0.0\0".as_ptr(), 7);
    }
    if common::cstrEq(name, "hw.cachelinesize") {
        return common::sysctlCopyValue(oldp, oldlenp, 64u32);
    }
    if common::cstrEq(name, "hw.l1icachesize") {
        return common::sysctlCopyValue(oldp, oldlenp, 16384u32);
    }
    if common::cstrEq(name, "hw.l1dcachesize") {
        return common::sysctlCopyValue(oldp, oldlenp, 16384u32);
    }
    if common::cstrEq(name, "hw.l2cachesize") {
        return common::sysctlCopyValue(oldp, oldlenp, 2097152u32);
    }
    common::stubErr("sysctlbyname")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sysctl(
    _mib: *mut c_int,
    _miblen: c_uint,
    _oldp: *mut c_void,
    oldlenp: *mut usize,
    _newp: *mut c_void,
    _newlen: usize,
) -> c_int {
    if !oldlenp.is_null() {
        *oldlenp = 0;
    }
    common::stubErr("sysctl")
}

#[unsafe(no_mangle)]
pub extern "C" fn confstr(_name: c_int, _buf: *mut u8, _len: usize) -> usize {
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn sysconf(_name: c_int) -> c_long {
    -1
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn uname(_name: *mut c_void) -> c_int {
    common::stubErr("uname")
}
