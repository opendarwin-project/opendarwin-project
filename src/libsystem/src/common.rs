//! Internal shared helpers for libSystem modules.
//! Not exported directly — modules import this and re-export what they need.

use core::ffi::{c_char, c_int, c_void};

pub const usize_max: usize = usize::MAX;

// ── errno ──────────────────────────────────────────────────────────────
#[unsafe(no_mangle)]
pub static mut errno: c_int = 0;

// ── syscall numbers ────────────────────────────────────────────────────
pub const SYS_exit: usize = 1;
pub const SYS_read: usize = 3;
pub const SYS_write: usize = 4;
pub const SYS_open: usize = 5;
pub const SYS_close: usize = 6;
pub const SYS_getpid: usize = 20;
pub const SYS_stat: usize = 38;
pub const SYS_kill: usize = 37;
pub const SYS_sigaction: usize = 46;
pub const SYS_sigprocmask: usize = 48;
pub const SYS_fstat: usize = 62;
pub const SYS_socket: usize = 97;
pub const SYS_socketpair: usize = 135;
pub const SYS_getsockname: usize = 150;
pub const SYS_sigreturn: usize = 184;
pub const SYS_lseek: usize = 199;
pub const SYS_pthread_kill: usize = 328;
pub const SYS___semwait_signal: usize = 334;
pub const SYS_stat64: usize = 338;
pub const SYS_fstat64: usize = 339;
pub const SYS_lstat64: usize = 340;
pub const SYS_bsdthread_create: usize = 360;
pub const SYS_bsdthread_terminate: usize = 361;
pub const SYS_bsdthread_register: usize = 366;
pub const SYS_thread_selfid: usize = 372;
pub const SYS_ulock_wake: usize = 516;
pub const SYS_ulock_wait2: usize = 544;

// ── Mach trap numbers ──────────────────────────────────────────────────
pub const MACH_mach_vm_map_trap: usize = 15;
pub const MACH_mach_reply_port: usize = 26;
pub const MACH_task_self_trap: usize = 28;
pub const MACH_host_self_trap: usize = 29;
pub const MACH_mach_msg2_trap: usize = 47;
pub const MACH_iokit_user_client_trap: usize = 100;
pub const KERN_SUCCESS: usize = 0;

// ── vm / mmap constants ────────────────────────────────────────────────
pub const MAP_PRIVATE_ANON: c_int = 0x1002;
pub const VM_PROT_READ_WRITE: c_int = 3;
pub const EAGAIN: c_int = 11;
pub const ENOMEM: c_int = 12;
pub const EBUSY: c_int = 16;
pub const EINVAL: c_int = 22;
pub const ENOTTY: c_int = 25;
pub const ENOTSUP: c_int = 45;
pub const ENOSYS: c_int = 78;

// ── BSD syscall wrappers ───────────────────────────────────────────────

#[inline(always)]
pub unsafe fn darwinSyscall3(number: usize, arg0: usize, arg1: usize, arg2: usize) -> usize {
    #[cfg(target_arch = "aarch64")]
    {
        let ret: usize;
        core::arch::asm!(
            "mov x16, {number}",
            "svc #0x80",
            number = in(reg) number,
            inout("x0") arg0 => ret,
            in("x1") arg1,
            in("x2") arg2,
            out("x3") _, out("x4") _, out("x5") _, out("x6") _,
            out("x7") _, out("x8") _, out("x9") _, out("x10") _,
            out("x11") _, out("x12") _, out("x13") _, out("x14") _,
            out("x15") _, out("x16") _, out("x17") _,
            options(nostack),
        );
        ret
    }
    #[cfg(not(target_arch = "aarch64"))]
    {
        let _ = (number, arg0, arg1, arg2);
        0
    }
}

#[inline(always)]
pub unsafe fn darwinSyscall5(
    number: usize,
    arg0: usize,
    arg1: usize,
    arg2: usize,
    arg3: usize,
    arg4: usize,
) -> usize {
    #[cfg(target_arch = "aarch64")]
    {
        let ret: usize;
        core::arch::asm!(
            "mov x16, {number}",
            "svc #0x80",
            number = in(reg) number,
            inout("x0") arg0 => ret,
            in("x1") arg1,
            in("x2") arg2,
            in("x3") arg3,
            in("x4") arg4,
            out("x5") _, out("x6") _, out("x7") _, out("x8") _,
            out("x9") _, out("x10") _, out("x11") _, out("x12") _,
            out("x13") _, out("x14") _, out("x15") _, out("x16") _,
            out("x17") _,
            options(nostack),
        );
        ret
    }
    #[cfg(not(target_arch = "aarch64"))]
    {
        let _ = (number, arg0, arg1, arg2, arg3, arg4);
        0
    }
}

#[inline(always)]
pub unsafe fn darwinSyscall6(
    number: usize,
    arg0: usize,
    arg1: usize,
    arg2: usize,
    arg3: usize,
    arg4: usize,
    arg5: usize,
) -> usize {
    #[cfg(target_arch = "aarch64")]
    {
        let ret: usize;
        core::arch::asm!(
            "mov x16, {number}",
            "svc #0x80",
            number = in(reg) number,
            inout("x0") arg0 => ret,
            in("x1") arg1,
            in("x2") arg2,
            in("x3") arg3,
            in("x4") arg4,
            in("x5") arg5,
            out("x6") _, out("x7") _, out("x8") _, out("x9") _,
            out("x10") _, out("x11") _, out("x12") _, out("x13") _,
            out("x14") _, out("x15") _, out("x16") _, out("x17") _,
            options(nostack),
        );
        ret
    }
    #[cfg(not(target_arch = "aarch64"))]
    {
        let _ = (number, arg0, arg1, arg2, arg3, arg4, arg5);
        0
    }
}

// ── Mach trap wrappers ─────────────────────────────────────────────────
// On aarch64 Darwin a mach trap is taken with the negated trap number in x16 and svc #0x80.

#[inline(always)]
pub unsafe fn machTrap0(number: usize) -> usize {
    #[cfg(target_arch = "aarch64")]
    {
        let mut ret: usize;
        core::arch::asm!(
            "mov x16, {num}",
            "svc #0x80",
            num = in(reg) number.wrapping_neg(),
            inout("x0") 0usize => ret,
            out("x1") _, out("x2") _, out("x3") _, out("x4") _,
            out("x5") _, out("x6") _, out("x7") _, out("x8") _,
            out("x9") _, out("x10") _, out("x11") _, out("x12") _,
            out("x13") _, out("x14") _, out("x15") _, out("x16") _,
            out("x17") _,
            options(nostack),
        );
        ret
    }
    #[cfg(not(target_arch = "aarch64"))]
    {
        let _ = number;
        usize_max
    }
}

#[inline(always)]
pub unsafe fn machTrap5(
    number: usize,
    arg0: usize,
    arg1: usize,
    arg2: usize,
    arg3: usize,
    arg4: usize,
) -> usize {
    #[cfg(target_arch = "aarch64")]
    {
        let mut ret: usize;
        core::arch::asm!(
            "mov x16, {num}",
            "svc #0x80",
            num = in(reg) number.wrapping_neg(),
            inout("x0") arg0 => ret,
            in("x1") arg1,
            in("x2") arg2,
            in("x3") arg3,
            in("x4") arg4,
            out("x5") _, out("x6") _, out("x7") _, out("x8") _,
            out("x9") _, out("x10") _, out("x11") _, out("x12") _,
            out("x13") _, out("x14") _, out("x15") _, out("x16") _,
            out("x17") _,
            options(nostack),
        );
        ret
    }
    #[cfg(not(target_arch = "aarch64"))]
    {
        let _ = (number, arg0, arg1, arg2, arg3, arg4);
        usize_max
    }
}

#[inline(always)]
pub unsafe fn machTrap6(
    number: usize,
    arg0: usize,
    arg1: usize,
    arg2: usize,
    arg3: usize,
    arg4: usize,
    arg5: usize,
) -> usize {
    #[cfg(target_arch = "aarch64")]
    {
        let mut ret: usize;
        core::arch::asm!(
            "mov x16, {num}",
            "svc #0x80",
            num = in(reg) number.wrapping_neg(),
            inout("x0") arg0 => ret,
            in("x1") arg1,
            in("x2") arg2,
            in("x3") arg3,
            in("x4") arg4,
            in("x5") arg5,
            out("x6") _, out("x7") _, out("x8") _, out("x9") _,
            out("x10") _, out("x11") _, out("x12") _, out("x13") _,
            out("x14") _, out("x15") _, out("x16") _, out("x17") _,
            options(nostack),
        );
        ret
    }
    #[cfg(not(target_arch = "aarch64"))]
    {
        let _ = (number, arg0, arg1, arg2, arg3, arg4, arg5);
        usize_max
    }
}

#[inline(always)]
pub unsafe fn machTrap7(
    number: usize,
    a0: usize,
    a1: usize,
    a2: usize,
    a3: usize,
    a4: usize,
    a5: usize,
    a6: usize,
) -> usize {
    #[cfg(target_arch = "aarch64")]
    {
        let mut ret: usize;
        core::arch::asm!(
            "mov x16, {num}",
            "svc #0x80",
            num = in(reg) number.wrapping_neg(),
            inout("x0") a0 => ret,
            in("x1") a1,
            in("x2") a2,
            in("x3") a3,
            in("x4") a4,
            in("x5") a5,
            in("x6") a6,
            in("x7") 0usize,
            out("x8") _, out("x9") _, out("x10") _, out("x11") _,
            out("x12") _, out("x13") _, out("x14") _, out("x15") _,
            out("x16") _, out("x17") _,
            options(nostack),
        );
        ret
    }
    #[cfg(not(target_arch = "aarch64"))]
    {
        let _ = (number, a0, a1, a2, a3, a4, a5, a6);
        usize_max
    }
}

#[inline(always)]
pub unsafe fn machTrap8(
    number: usize,
    a0: usize,
    a1: usize,
    a2: usize,
    a3: usize,
    a4: usize,
    a5: usize,
    a6: usize,
    a7: usize,
) -> usize {
    #[cfg(target_arch = "aarch64")]
    {
        let mut ret: usize;
        core::arch::asm!(
            "mov x16, {num}",
            "svc #0x80",
            num = in(reg) number.wrapping_neg(),
            inout("x0") a0 => ret,
            in("x1") a1,
            in("x2") a2,
            in("x3") a3,
            in("x4") a4,
            in("x5") a5,
            in("x6") a6,
            in("x7") a7,
            out("x8") _, out("x9") _, out("x10") _, out("x11") _,
            out("x12") _, out("x13") _, out("x14") _, out("x15") _,
            out("x16") _, out("x17") _,
            options(nostack),
        );
        ret
    }
    #[cfg(not(target_arch = "aarch64"))]
    {
        let _ = (number, a0, a1, a2, a3, a4, a5, a6, a7);
        usize_max
    }
}

// ── errno helpers ──────────────────────────────────────────────────────

pub unsafe fn setErrnoFromNegative(ret: usize) -> c_int {
    if ret > usize_max - 4096 {
        errno = (0usize.wrapping_sub(ret)) as c_int;
        -1
    } else {
        ret as c_int
    }
}

pub unsafe fn reportStub(name: &str) {
    let prefix = b"libSystem stub: ";
    let suffix = b"\n";
    darwinSyscall3(SYS_write, 2, prefix.as_ptr() as usize, prefix.len());
    darwinSyscall3(SYS_write, 2, name.as_ptr() as usize, name.len());
    darwinSyscall3(SYS_write, 2, suffix.as_ptr() as usize, suffix.len());
}

pub unsafe fn stubErr(name: &str) -> c_int {
    reportStub(name);
    errno = ENOSYS;
    -1
}

pub unsafe fn stubUsize(name: &str) -> usize {
    stubErr(name);
    usize_max
}

pub unsafe fn stubNull(name: &str) -> *mut c_void {
    stubErr(name);
    core::ptr::null_mut()
}

// ── string helpers (internal, for sysctl etc.) ────────────────────────

pub unsafe fn cstrLen(s: *const c_char) -> usize {
    if s.is_null() {
        return 0;
    }
    let mut n = 0;
    while *s.add(n) != 0 {
        n += 1;
    }
    n
}

pub unsafe fn cstrEq(s: *const c_char, want: &str) -> bool {
    if s.is_null() {
        return false;
    }
    let want_bytes = want.as_bytes();
    for (i, &b) in want_bytes.iter().enumerate() {
        if *s.add(i) as u8 != b {
            return false;
        }
    }
    *s.add(want_bytes.len()) == 0
}

pub unsafe fn sysctlCopyOut(
    oldp: *mut c_void,
    oldlenp: *mut usize,
    src: *const u8,
    len: usize,
) -> c_int {
    if !oldlenp.is_null() {
        if !oldp.is_null() {
            let n = core::cmp::min(*oldlenp, len);
            core::ptr::copy_nonoverlapping(src, oldp as *mut u8, n);
        }
        *oldlenp = len;
    }
    0
}

pub unsafe fn sysctlCopyValue<T: Copy>(oldp: *mut c_void, oldlenp: *mut usize, value: T) -> c_int {
    let bytes = &value as *const T as *const u8;
    sysctlCopyOut(oldp, oldlenp, bytes, core::mem::size_of::<T>())
}

// ── debug hex output ──────────────────────────────────────────────────

pub unsafe fn writeHexValue(value_in: usize) {
    let mut hex = [0u8; 18];
    hex[0] = b'0';
    hex[1] = b'x';
    let mut value = value_in;
    let mut i = 18;
    while i > 2 {
        i -= 1;
        let digit = (value & 0xf) as u8;
        hex[i] = if digit < 10 {
            b'0' + digit
        } else {
            b'a' + (digit - 10)
        };
        value >>= 4;
    }
    darwinSyscall3(SYS_write, 2, hex.as_ptr() as usize, hex.len());
}
