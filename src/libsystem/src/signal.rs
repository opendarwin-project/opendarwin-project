//! Signal handling: sigaction, sigprocmask, sigaltstack, sigemptyset,
//! sigfillset, sigaddset, sigdelset, sigismember, __sigtramp.

use core::ffi::{c_int, c_void};

use crate::common;

pub const SIGKILL: c_int = 9;
pub const SIGSTOP: c_int = 17;
pub const NSIG: c_int = 32;
pub const SA_SIGINFO: i32 = 0x0040;
pub const SA_ONSTACK: i32 = 0x0001;
pub const SA_RESTART: i32 = 0x0002;
pub const SA_RESETHAND: i32 = 0x0004;
pub const SA_NOCLDSTOP: i32 = 0x0008;
pub const SA_NODEFER: i32 = 0x0010;
pub const SA_NOCLDWAIT: i32 = 0x0020;
pub const SIG_BLOCK: c_int = 1;
pub const SIG_UNBLOCK: c_int = 2;
pub const SIG_SETMASK: c_int = 3;
pub const UC_FLAVOR: c_int = 30;

#[repr(C)]
#[derive(Copy, Clone)]
pub struct SignalAltStack {
    pub sp: *mut c_void,
    pub size: usize,
    pub flags: c_int,
}

static mut INSTALLED_ALT_STACK: SignalAltStack = SignalAltStack {
    sp: core::ptr::null_mut(),
    size: 0,
    flags: 0,
};

/// User-facing sigaction struct (no trampoline) — what Zig/Rust std.start passes.
/// Layout: handler(8) + mask(4) + flags(4) = 16 bytes on aarch64.
#[repr(C)]
#[derive(Copy, Clone)]
pub struct UserSigaction {
    pub handler: usize,
    pub sa_mask: u32,
    pub sa_flags: i32,
}

/// Kernel-facing __sigaction struct (with trampoline) — what syscall 46 expects.
/// Layout: handler(8) + tramp(8) + mask(4) + flags(4) = 24 bytes on aarch64.
#[repr(C)]
#[derive(Copy, Clone)]
pub struct KernelSigaction {
    pub handler: usize,
    pub sa_tramp: usize,
    pub sa_mask: u32,
    pub sa_flags: i32,
}

/// XNU arm64 signal trampoline. The kernel enters here with:
///   x0=handler, x1=infostyle, x2=sig, x3=siginfo*, x4=ucontext*, x5=token
/// After the user handler returns, we restore via sigreturn(2).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn __sigtramp(
    handler: usize,
    style: c_int,
    sig: c_int,
    sinfo: *mut c_void,
    uctx: *mut c_void,
    token: usize,
) {
    if style == UC_FLAVOR {
        let fn_ptr: unsafe extern "C" fn(c_int, *mut c_void, *mut c_void) =
            core::mem::transmute(handler);
        fn_ptr(sig, sinfo, uctx);
    } else {
        let fn_ptr: unsafe extern "C" fn(c_int) = core::mem::transmute(handler);
        fn_ptr(sig);
    }
    let _ = common::darwinSyscall3(common::SYS_sigreturn, uctx as usize, style as usize, token);
    // sigreturn restores the interrupted context and does not return.
    loop {}
}

/// Forward sigaction to the kernel (syscall 46), matching XNU's ABI.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sigaction(sig: c_int, act: *const c_void, oldact: *mut c_void) -> c_int {
    if sig <= 0 || sig >= NSIG {
        common::errno = common::EINVAL;
        return -1;
    }
    if sig == SIGKILL || sig == SIGSTOP {
        common::errno = common::EINVAL;
        return -1;
    }

    let mut kern_act = KernelSigaction {
        handler: 0,
        sa_tramp: 0,
        sa_mask: 0,
        sa_flags: 0,
    };
    if !act.is_null() {
        let user_sa = &*(act as *const UserSigaction);
        kern_act = KernelSigaction {
            handler: user_sa.handler,
            sa_tramp: __sigtramp as *const () as usize,
            sa_mask: user_sa.sa_mask,
            sa_flags: user_sa.sa_flags,
        };
    }

    let mut kernel_oldact = UserSigaction {
        handler: 0,
        sa_mask: 0,
        sa_flags: 0,
    };
    let nsa_ptr = if !act.is_null() {
        &raw const kern_act as usize
    } else {
        0
    };
    let osa_ptr = if !oldact.is_null() {
        &raw mut kernel_oldact as usize
    } else {
        0
    };

    let ret = common::darwinSyscall3(common::SYS_sigaction, sig as usize, nsa_ptr, osa_ptr);
    let err = common::setErrnoFromNegative(ret);
    if err != 0 {
        return -1;
    }

    if !oldact.is_null() {
        *(oldact as *mut UserSigaction) = kernel_oldact;
    }

    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sigprocmask(how: c_int, set: *const c_void, oldset: *mut c_void) -> c_int {
    if how != SIG_BLOCK && how != SIG_UNBLOCK && how != SIG_SETMASK {
        common::errno = common::EINVAL;
        return -1;
    }
    let ret = common::darwinSyscall3(
        common::SYS_sigprocmask,
        how as usize,
        set as usize,
        oldset as usize,
    );
    common::setErrnoFromNegative(ret)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sigaltstack(ss: *const c_void, old_ss: *mut c_void) -> c_int {
    if !old_ss.is_null() {
        *(old_ss as *mut SignalAltStack) = INSTALLED_ALT_STACK;
    }
    if !ss.is_null() {
        INSTALLED_ALT_STACK = *(ss as *const SignalAltStack);
    }
    0
}

/// Darwin arm64's `sigset_t` used by Zig/std is a 32-bit mask.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sigemptyset(set: *mut c_void) -> c_int {
    if !set.is_null() {
        *(set as *mut u32) = 0;
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sigfillset(set: *mut c_void) -> c_int {
    if !set.is_null() {
        *(set as *mut u32) = 0xFFFFFFFF;
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sigaddset(set: *mut c_void, signum: c_int) -> c_int {
    if !set.is_null() {
        if signum < 1 || signum >= NSIG {
            return common::EINVAL;
        }
        *(set as *mut u32) |= 1u32 << (signum - 1);
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sigdelset(set: *mut c_void, signum: c_int) -> c_int {
    if !set.is_null() {
        if signum < 1 || signum >= NSIG {
            return common::EINVAL;
        }
        *(set as *mut u32) &= !(1u32 << (signum - 1));
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sigismember(set: *const c_void, signum: c_int) -> c_int {
    if !set.is_null() {
        if signum < 1 || signum >= NSIG {
            return common::EINVAL;
        }
        if (*(set as *const u32) & (1u32 << (signum - 1))) != 0 {
            1
        } else {
            0
        }
    } else {
        0
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sigpending(set: *mut c_void) -> c_int {
    if !set.is_null() {
        *(set as *mut u32) = 0;
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sigsuspend(_sigmask: *const c_void) -> c_int {
    common::stubErr("sigsuspend")
}

#[unsafe(no_mangle)]
pub extern "C" fn signal(_sig: c_int, _handler: usize) -> usize {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn raise(sig: c_int) -> c_int {
    let pid = common::darwinSyscall3(common::SYS_getpid, 0, 0, 0);
    let ret = common::darwinSyscall3(common::SYS_kill, pid, sig as usize, 0);
    common::setErrnoFromNegative(ret)
}
