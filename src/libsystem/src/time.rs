//! Time functions: clock_gettime, clock_getres, nanosleep, gettimeofday,
//! mach_absolute_time, mach_timebase_info, usleep, sleep.

use core::ffi::{c_int, c_uint, c_void};
use core::sync::atomic::{AtomicUsize, Ordering};

use crate::common;

#[repr(C)]
#[derive(Copy, Clone)]
pub struct LibcTimespec {
    pub tv_sec: isize,
    pub tv_nsec: isize,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct LibcTimeval {
    pub tv_sec: isize,
    pub tv_usec: isize,
}

static CLOCK_MS: AtomicUsize = AtomicUsize::new(0);

#[unsafe(no_mangle)]
pub unsafe extern "C" fn clock_gettime(_clk_id: c_int, tp: *mut c_void) -> c_int {
    if tp.is_null() {
        common::errno = common::EINVAL;
        return -1;
    }
    // Monotonic coarse clock that advances on observation.
    let ms = CLOCK_MS.fetch_add(5, Ordering::Relaxed).wrapping_add(5);
    let ts = tp as *mut LibcTimespec;
    (*ts).tv_sec = (ms / 1000) as isize;
    (*ts).tv_nsec = ((ms % 1000) * 1_000_000) as isize;
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn clock_getres(_clk_id: c_int, tp: *mut c_void) -> c_int {
    if !tp.is_null() {
        let ts = tp as *mut LibcTimespec;
        (*ts).tv_sec = 0;
        (*ts).tv_nsec = 5_000_000;
    }
    0
}

/// Darwin has no dedicated nanosleep syscall; libc's nanosleep() is built
/// on top of __semwait_signal(cond_sem=0, mutex_sem=0, timeout=1,
/// relative=1, tv_sec, tv_nsec).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nanosleep(req: *const c_void, _rem: *mut c_void) -> c_int {
    if req.is_null() {
        common::errno = common::EINVAL;
        return -1;
    }
    let ts = *(req as *const LibcTimespec);
    let ret = common::darwinSyscall6(
        common::SYS___semwait_signal,
        0,
        0,
        1,
        1,
        ts.tv_sec as usize,
        ts.tv_nsec as usize,
    );
    common::setErrnoFromNegative(ret)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn usleep(usec: c_uint) -> c_int {
    let ts = LibcTimespec {
        tv_sec: (usec as usize / 1_000_000) as isize,
        tv_nsec: ((usec as usize % 1_000_000) * 1000) as isize,
    };
    nanosleep(
        &ts as *const LibcTimespec as *const c_void,
        core::ptr::null_mut(),
    )
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sleep(seconds: c_uint) -> c_uint {
    let ts = LibcTimespec {
        tv_sec: seconds as isize,
        tv_nsec: 0,
    };
    let _ = nanosleep(
        &ts as *const LibcTimespec as *const c_void,
        core::ptr::null_mut(),
    );
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gettimeofday(tp: *mut c_void, _tzp: *mut c_void) -> c_int {
    if !tp.is_null() {
        let ms = CLOCK_MS.fetch_add(1, Ordering::Relaxed).wrapping_add(1);
        let tv = tp as *mut LibcTimeval;
        (*tv).tv_sec = (ms / 1000) as isize;
        (*tv).tv_usec = ((ms % 1000) * 1000) as isize;
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mach_absolute_time() -> u64 {
    let ms = CLOCK_MS.fetch_add(1, Ordering::Relaxed).wrapping_add(1);
    ms as u64
}

#[repr(C)]
pub struct MachTimebaseInfo {
    pub numer: u32,
    pub denom: u32,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mach_timebase_info(info: *mut MachTimebaseInfo) -> c_int {
    if !info.is_null() {
        (*info).numer = 1;
        (*info).denom = 1;
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mach_timebase_info_trap(info: *mut MachTimebaseInfo) -> c_int {
    mach_timebase_info(info)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn time(t: *mut i64) -> i64 {
    let ms = CLOCK_MS.fetch_add(1, Ordering::Relaxed).wrapping_add(1);
    let seconds = (ms / 1000) as i64;
    if !t.is_null() {
        *t = seconds;
    }
    seconds
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mktime(_tm: *mut c_void) -> i64 {
    0
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct LibcTm {
    pub tm_sec: c_int,
    pub tm_min: c_int,
    pub tm_hour: c_int,
    pub tm_mday: c_int,
    pub tm_mon: c_int,
    pub tm_year: c_int,
    pub tm_wday: c_int,
    pub tm_yday: c_int,
    pub tm_isdst: c_int,
}

static STATIC_TM: LibcTm = LibcTm {
    tm_sec: 0,
    tm_min: 0,
    tm_hour: 0,
    tm_mday: 1,
    tm_mon: 0,
    tm_year: 70, // 1970
    tm_wday: 4,  // Thursday
    tm_yday: 0,
    tm_isdst: 0,
};

#[unsafe(no_mangle)]
pub unsafe extern "C" fn localtime_r(_timer: *const i64, result: *mut c_void) -> *mut c_void {
    if !result.is_null() {
        *(result as *mut LibcTm) = STATIC_TM;
        result
    } else {
        core::ptr::null_mut()
    }
}
