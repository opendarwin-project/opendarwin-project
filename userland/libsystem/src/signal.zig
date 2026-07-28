//! Signal handling: sigaction, sigprocmask, sigaltstack, sigemptyset,
//! sigfillset, sigaddset, sigdelset, sigismember, __sigtramp.

const common = @import("common.zig");
const C = common;

const SIGKILL: c_int = 9;
const SIGSTOP: c_int = 17;
const NSIG: c_int = 32;
const SA_SIGINFO: i32 = 0x0040;
const SA_ONSTACK: i32 = 0x0001;
const SA_RESTART: i32 = 0x0002;
const SA_RESETHAND: i32 = 0x0004;
const SA_NOCLDSTOP: i32 = 0x0008;
const SA_NODEFER: i32 = 0x0010;
const SA_NOCLDWAIT: i32 = 0x0020;
const SIG_BLOCK: c_int = 1;
const SIG_UNBLOCK: c_int = 2;
const SIG_SETMASK: c_int = 3;
const UC_FLAVOR: c_int = 30;

const SaHandler = *const fn (c_int) callconv(.c) void;
const SaSigaction = *const fn (c_int, ?*anyopaque, ?*anyopaque) callconv(.c) void;

const SignalAltStack = extern struct {
    sp: ?*anyopaque,
    size: usize,
    flags: c_int,
};

var installed_alt_stack: SignalAltStack = .{ .sp = null, .size = 0, .flags = 0 };

/// User-facing sigaction struct (no trampoline) — what Zig's std.start passes.
/// Layout: handler(8) + mask(4) + flags(4) = 16 bytes on aarch64.
const UserSigaction = extern struct {
    handler: usize,
    sa_mask: u32,
    sa_flags: i32,
};

/// Kernel-facing __sigaction struct (with trampoline) — what syscall 46 expects.
/// Layout: handler(8) + tramp(8) + mask(4) + flags(4) = 24 bytes on aarch64.
const KernelSigaction = extern struct {
    handler: usize,
    sa_tramp: usize,
    sa_mask: u32,
    sa_flags: i32,
};

/// XNU arm64 signal trampoline. The kernel enters here with:
///   x0=handler, x1=infostyle, x2=sig, x3=siginfo*, x4=ucontext*, x5=token
/// After the user handler returns, we restore via sigreturn(2).
pub export fn __sigtramp(
    handler: usize,
    style: c_int,
    sig: c_int,
    sinfo: ?*anyopaque,
    uctx: ?*anyopaque,
    token: usize,
) callconv(.c) void {
    if (style == UC_FLAVOR) {
        const fn_ptr: SaSigaction = @ptrFromInt(handler);
        fn_ptr(sig, sinfo, uctx);
    } else {
        const fn_ptr: SaHandler = @ptrFromInt(handler);
        fn_ptr(sig);
    }
    _ = C.darwinSyscall3(C.SYS_sigreturn, @intFromPtr(uctx), @intCast(style), token);
    // sigreturn restores the interrupted context and does not return.
    while (true) {}
}

/// Forward sigaction to the kernel (syscall 46), matching XNU's ABI.
pub export fn sigaction(sig: c_int, act: ?*const anyopaque, oldact: ?*anyopaque) c_int {
    if (sig <= 0 or sig >= NSIG) {
        common.errno = C.EINVAL;
        return -1;
    }
    if (sig == SIGKILL or sig == SIGSTOP) {
        common.errno = C.EINVAL;
        return -1;
    }

    var kern_act: KernelSigaction = undefined;
    if (act) |input| {
        const user_sa: *const UserSigaction = @ptrCast(@alignCast(input));
        kern_act = .{
            .handler = user_sa.handler,
            .sa_tramp = @intFromPtr(&__sigtramp),
            .sa_mask = user_sa.sa_mask,
            .sa_flags = user_sa.sa_flags,
        };
    }

    var kernel_oldact: UserSigaction = undefined;
    const nsa_ptr: usize = if (act != null) @intFromPtr(&kern_act) else 0;
    const osa_ptr: usize = if (oldact != null) @intFromPtr(&kernel_oldact) else 0;

    const ret = C.darwinSyscall3(C.SYS_sigaction, @intCast(sig), nsa_ptr, osa_ptr);
    const err = C.setErrnoFromNegative(ret);
    if (err != 0) return -1;

    if (oldact) |out| {
        @as([*]u8, @ptrCast(out))[0..@sizeOf(UserSigaction)].* = @as([*]const u8, @ptrCast(&kernel_oldact))[0..@sizeOf(UserSigaction)].*;
    }

    return 0;
}

pub export fn sigprocmask(how: c_int, set: ?*const anyopaque, oldset: ?*anyopaque) c_int {
    if (how != SIG_BLOCK and how != SIG_UNBLOCK and how != SIG_SETMASK) {
        common.errno = C.EINVAL;
        return -1;
    }
    const ret = C.darwinSyscall3(
        C.SYS_sigprocmask,
        @intCast(how),
        if (set) |p| @intFromPtr(p) else 0,
        if (oldset) |p| @intFromPtr(p) else 0,
    );
    return @intCast(C.setErrnoFromNegative(ret));
}

pub export fn sigaltstack(ss: ?*const anyopaque, old_ss: ?*anyopaque) c_int {
    if (old_ss) |out| @as(*SignalAltStack, @ptrCast(@alignCast(out))).* = installed_alt_stack;
    if (ss) |input| {
        const next = @as(*const SignalAltStack, @ptrCast(@alignCast(input))).*;
        installed_alt_stack = next;
    }
    return 0;
}

/// Darwin arm64's `sigset_t` used by Zig is a 32-bit mask.
pub export fn sigemptyset(set: ?*anyopaque) c_int {
    if (set) |p| @as(*u32, @ptrCast(@alignCast(p))).* = 0;
    return 0;
}

pub export fn sigfillset(set: ?*anyopaque) c_int {
    if (set) |p| @as(*u32, @ptrCast(@alignCast(p))).* = 0xFFFFFFFF;
    return 0;
}

pub export fn sigaddset(set: ?*anyopaque, signum: c_int) c_int {
    if (set) |p| {
        if (signum < 1 or signum >= NSIG) return C.EINVAL;
        @as(*u32, @ptrCast(@alignCast(p))).* |= @as(u32, 1) << @intCast(signum - 1);
    }
    return 0;
}

pub export fn sigdelset(set: ?*anyopaque, signum: c_int) c_int {
    if (set) |p| {
        if (signum < 1 or signum >= NSIG) return C.EINVAL;
        @as(*u32, @ptrCast(@alignCast(p))).* &= ~(@as(u32, 1) << @intCast(signum - 1));
    }
    return 0;
}

pub export fn sigismember(set: ?*const anyopaque, signum: c_int) c_int {
    if (set) |p| {
        if (signum < 1 or signum >= NSIG) return C.EINVAL;
        return if (@as(*const u32, @ptrCast(@alignCast(p))).* & (@as(u32, 1) << @intCast(signum - 1)) != 0) 1 else 0;
    }
    return 0;
}

pub export fn sigpending(set: ?*anyopaque) c_int {
    if (set) |p| @as(*u32, @ptrCast(@alignCast(p))).* = 0;
    return 0;
}

pub export fn sigsuspend(_: ?*const anyopaque) c_int {
    return C.stubErr("sigsuspend");
}

pub export fn signal(sig: c_int, handler: usize) usize {
    // Minimal: just return the old handler (0).
    _ = sig;
    _ = handler;
    return 0;
}

pub export fn raise(sig: c_int) c_int {
    const ret = C.darwinSyscall3(C.SYS_kill, @intCast(C.darwinSyscall3(C.SYS_getpid, 0, 0, 0)), @intCast(sig), 0);
    return @intCast(C.setErrnoFromNegative(ret));
}
