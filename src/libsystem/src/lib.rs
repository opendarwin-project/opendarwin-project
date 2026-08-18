//! Minimal FOSS libSystem/libsystem_c replacement for OpenDarwin userland,
//! rewritten in pure Rust.
//!
//! This is intentionally tiny: enough symbols for Darwin Mach-O smoke binaries
//! while the kernel grows real dylib loading support.
//! It does not depend on Apple's libSystem.
//!
//! Modules:
//!   common   — internal helpers (syscall wrappers, errno, stubErr)
//!   basics   — compiler-rt, _exit, exit, abort, __stack_chk_fail
//!   mach     — mach_task_self, mach_vm_map, mmap, munmap
//!   malloc   — malloc, calloc, realloc, free, malloc_size, bzero
//!   string   — strlen, strcmp, memcpy, memmove, memset, qsort, bsearch, strtod
//!   stdio    — write, read, open, close, fprintf, snprintf, etc.
//!   time     — clock_gettime, nanosleep, mach_absolute_time, gettimeofday
//!   pthread  — pthread_create, pthread_mutex_*, pthread_key_*, __ulock_*
//!   locking  — os_unfair_lock, OSSpinLock, OSAtomic
//!   signal   — sigaction, sigprocmask, sigaltstack, __sigtramp
//!   process  — getpid, kill, fork, execve, wait4
//!   dyld     — _dyld_image_count, dlopen, dlsym, getsectbynamefromheader_64
//!   tlv      — __tlv_bootstrap, sys_icache_invalidate
//!   socket   — socket, socketpair, connect, getaddrinfo
//!   dispatch — dispatch_queue, dispatch_async, dispatch_source
//!   sysctl   — sysctlbyname, confstr, sysconf
//!   misc     — getenv, environ, uuid_generate, pow, fmod, atexit, etc.
//!   blocks   — _Block_copy, _Block_release, _NSConcrete*Block

#![allow(non_snake_case, non_camel_case_types, non_upper_case_globals)]
#![allow(unsafe_op_in_unsafe_fn)]
#![no_std]

#[cfg(test)]
extern crate std;

pub mod basics;
pub mod blocks;
pub mod common;
pub mod dispatch;
pub mod dyld;
pub mod locking;
pub mod mach;
pub mod malloc;
pub mod misc;
pub mod process;
pub mod pthread;
pub mod signal;
pub mod socket;
pub mod stdio;
pub mod string;
pub mod sysctl;
pub mod time;
pub mod tlv;

// Re-export errno at top level
pub use common::errno;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_divti3() {
        assert_eq!(basics::__divti3(100, 5), 20);
        assert_eq!(basics::__divti3(-100, 5), -20);
        assert_eq!(basics::__divti3(100, -5), -20);
        assert_eq!(basics::__divti3(-100, -5), 20);
        assert_eq!(basics::__divti3(0, 5), 0);
        assert_eq!(basics::__divti3(100, 0), 0);
    }

    #[test]
    fn test_string_ops() {
        unsafe {
            let s = c"hello world";
            assert_eq!(string::strlen(s.as_ptr()), 11);
            assert_eq!(string::strcmp(s.as_ptr(), c"hello world".as_ptr()), 0);
            assert!(string::strcmp(s.as_ptr(), c"hello z".as_ptr()) < 0);
            assert!(string::strcasecmp(c"HELLO".as_ptr(), c"hello".as_ptr()) == 0);

            let mut buf = [0u8; 32];
            string::strlcpy(buf.as_mut_ptr() as *mut _, s.as_ptr(), buf.len());
            assert_eq!(string::strlen(buf.as_ptr() as *const _), 11);

            let mut endp = core::ptr::null();
            let val = string::strtol(c"  -12345abc".as_ptr(), &mut endp, 10);
            assert_eq!(val, -12345);

            let fval = string::strtod(c"  3.14159".as_ptr(), core::ptr::null_mut());
            assert!((fval - 3.14159).abs() < 1e-5);
        }
    }

    #[test]
    fn test_math_functions() {
        assert_eq!(misc::pow(2.0, 3.0), 8.0);
        assert_eq!(misc::pow(5.0, 0.0), 1.0);
        assert_eq!(misc::fmod(5.5, 2.0), 1.5);
        assert!((misc::sqrt(16.0) - 4.0).abs() < 1e-5);
        assert_eq!(misc::fabs(-42.5), 42.5);
        assert_eq!(misc::floor(3.7), 3.0);
        assert_eq!(misc::ceil(3.2), 4.0);
        assert_eq!(misc::round(3.5), 4.0);
    }

    #[test]
    fn test_uuid_ops() {
        unsafe {
            let mut u1 = [0u8; 16];
            let mut u2 = [0u8; 16];
            misc::uuid_generate(u1.as_mut_ptr());
            assert!(misc::uuid_is_null(&u1));
            u2[0] = 1;
            assert!(!misc::uuid_is_null(&u2));
            assert_eq!(misc::uuid_compare(&u1, &u2), -1);
        }
    }

    #[test]
    fn test_atomics() {
        unsafe {
            let mut val: i32 = 10;
            assert_eq!(locking::OSAtomicIncrement32(&mut val), 11);
            assert_eq!(locking::OSAtomicDecrement32(&mut val), 10);
            assert_eq!(locking::OSAtomicAdd32(5, &mut val), 15);
            assert!(locking::OSAtomicCompareAndSwap32(15, 20, &mut val));
            assert_eq!(val, 20);
        }
    }

    #[test]
    fn test_sysctl_by_name() {
        unsafe {
            let mut val: u32 = 0;
            let mut size: usize = core::mem::size_of::<u32>();
            let ret = sysctl::sysctlbyname(
                c"hw.ncpu".as_ptr(),
                &mut val as *mut _ as *mut _,
                &mut size,
                core::ptr::null_mut(),
                0,
            );
            assert_eq!(ret, 0);
            assert_eq!(val, 4);
            assert_eq!(size, 4);
        }
    }
}

#[cfg(not(test))]
#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    unsafe { basics::abort() }
}

#[cfg(not(test))]
#[unsafe(no_mangle)]
extern "C" fn rust_eh_personality() {}

// `-Cpanic=abort` still leaves a handful of unwind-path references baked
// into precompiled `liballoc` (e.g. alloc-error handling code that's
// unreachable in practice but not eliminated at the IR level before
// linking). We never actually unwind, so this only needs to exist to
// satisfy the linker - abort like the panic handler above if it's ever
// somehow reached.
#[cfg(not(test))]
#[unsafe(no_mangle)]
extern "C" fn _Unwind_Resume() -> ! {
    unsafe { basics::abort() }
}
