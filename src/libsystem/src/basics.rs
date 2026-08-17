//! Compiler-rt and basic libc exports: __divti3, _exit, exit, abort,
//! __stack_chk_fail, __error, syscall, opendarwin_user_return, dyld_stub_binder.

use core::ffi::{c_char, c_int};

use crate::common;

pub const usize_max: usize = common::usize_max;

#[unsafe(no_mangle)]
pub static mut __dyld_private: usize = 0;

#[unsafe(no_mangle)]
pub static mut __stack_chk_guard: usize = 0x595a_5b5c_5d5e_5f60;

/// Compiler-rt signed 128-bit division used by Darwin code.
#[unsafe(no_mangle)]
pub extern "C" fn __divti3(a: i128, b: i128) -> i128 {
    if b == 0 {
        return 0;
    }
    let negative = (a < 0) != (b < 0);
    let au: u128 = a.unsigned_abs();
    let bu: u128 = b.unsigned_abs();
    let dividend: u128 = au;
    let divisor: u128 = bu;
    let mut quotient: u128 = 0;
    let mut remainder: u128 = 0;
    let mut bit: u8 = 128;
    while bit != 0 {
        bit -= 1;
        let shift = bit;
        remainder = (remainder << 1) | ((dividend >> shift) & 1);
        if remainder >= divisor {
            remainder = remainder.wrapping_sub(divisor);
            quotient |= 1u128 << shift;
            continue;
        }
    }
    if negative {
        0u128.wrapping_sub(quotient) as i128
    } else {
        quotient as i128
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn __error() -> *mut c_int {
    &raw mut common::errno
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn _exit(status: c_int) -> ! {
    let _ = common::darwinSyscall3(common::SYS_exit, status as usize, 0, 0);
    loop {
        #[cfg(target_arch = "aarch64")]
        core::arch::asm!("wfe", options(nomem, nostack));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn exit(status: c_int) -> ! {
    _exit(status);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn abort() -> ! {
    common::reportStub("abort");
    _exit(134);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn __assert_rtn(
    _file: *const c_char,
    _line_file: *const c_char,
    _line: c_int,
    _msg: *const c_char,
) -> ! {
    _exit(134);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn __stack_chk_fail() -> ! {
    _exit(127);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn opendarwin_user_return(status: u64) -> ! {
    _exit((status & 0xff) as c_int);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dyld_stub_binder() {
    _exit(127);
}
