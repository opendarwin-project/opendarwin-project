//! BSD/XNU-shaped signal registration, posting, and delivery.
//!
//! Delivery uses a compact GPR-only sigframe (not full XNU UC_FLAVOR NEON
//! state). Userspace `__sigtramp` receives the XNU arm64 register ABI and
//! returns via `sigreturn`.

const context = @import("../arch/aarch64/context.zig");
const usercopy = @import("../syscall/usercopy.zig");
const task_mod = @import("task.zig");
const sched = @import("sched.zig");

const Process = task_mod.Process;
const Task = task_mod.Task;
const SigAction = task_mod.SigAction;
const NSIG = task_mod.NSIG;
const SIG_DFL = task_mod.SIG_DFL;
const SIG_IGN = task_mod.SIG_IGN;
const SIGKILL = task_mod.SIGKILL;
const SIGSTOP = task_mod.SIGSTOP;
const SIGCANTMASK = task_mod.SIGCANTMASK;
const sigBit = task_mod.sigBit;

pub const SA_ONSTACK: i32 = 0x0001;
pub const SA_RESTART: i32 = 0x0002;
pub const SA_RESETHAND: i32 = 0x0004;
pub const SA_NODEFER: i32 = 0x0010;
pub const SA_SIGINFO: i32 = 0x0040;
pub const SA_USERSPACE_MASK: i32 = SA_ONSTACK | SA_RESTART | SA_RESETHAND | SA_NODEFER | SA_SIGINFO;

/// XNU `__user64_sigaction` — what syscall 46 copies in as `nsa`.
pub const User64SigactionIn = extern struct {
    handler: u64,
    sa_tramp: u64,
    sa_mask: u32,
    sa_flags: i32,
};

/// XNU `user64_sigaction` — what syscall 46 copies out as `osa`.
pub const User64SigactionOut = extern struct {
    handler: u64,
    sa_mask: u32,
    sa_flags: i32,
};

/// Compact siginfo for the milestone trampoline (si_signo / si_code enough).
pub const UserSiginfo = extern struct {
    si_signo: i32 = 0,
    si_errno: i32 = 0,
    si_code: i32 = 0,
    si_pid: i32 = 0,
    si_uid: u32 = 0,
    si_status: i32 = 0,
    si_addr: u64 = 0,
    si_value: u64 = 0,
    si_band: i64 = 0,
    pad: [7]u64 = [_]u64{0} ** 7,
};

/// Stack descriptor embedded in ucontext.
pub const UserStack = extern struct {
    ss_sp: u64 = 0,
    ss_size: u64 = 0,
    ss_flags: i32 = 0,
    __pad: i32 = 0,
};

/// GPR mcontext sufficient to restore `context.Frame` (no NEON).
pub const UserMcontext = extern struct {
    x: [31]u64 = [_]u64{0} ** 31,
    sp: u64 = 0,
    pc: u64 = 0,
    cpsr: u64 = 0,
    esr: u64 = 0,
    far: u64 = 0,
};

pub const UserUcontext = extern struct {
    uc_onstack: i32 = 0,
    uc_sigmask: u32 = 0,
    uc_stack: UserStack = .{},
    uc_link: u64 = 0,
    uc_mcsize: u64 = @sizeOf(UserMcontext),
    uc_mcontext: u64 = 0,
};

/// Layout pushed on the user stack for delivery. Pointers in registers point
/// into this frame; mcontext sits after ucontext.
pub const UserSigframe = extern struct {
    sinfo: UserSiginfo = .{},
    uctx: UserUcontext = .{},
    mctx: UserMcontext = .{},
};

/// Style flag: SA_SIGINFO handlers get UC_FLAVOR-like style 30.
pub const UC_TRAD: i32 = 1;
pub const UC_FLAVOR: i32 = 30;

const EFAULT: i64 = 14;
const EINVAL: i64 = 22;

pub fn validateSignum(sig: u32) bool {
    return sig > 0 and sig < NSIG;
}

pub fn getAction(proc: *const Process, sig: u32) SigAction {
    return proc.sig_actions[sig];
}

pub fn setAction(proc: *Process, sig: u32, nsa: ?User64SigactionIn) i64 {
    if (!validateSignum(sig) or sig == SIGKILL or sig == SIGSTOP) return -EINVAL;

    if (nsa) |act| {
        const flags = act.sa_flags & SA_USERSPACE_MASK;
        const bit = sigBit(sig);
        proc.sig_actions[sig] = .{
            .handler = act.handler,
            .sa_tramp = act.sa_tramp,
            .sa_mask = act.sa_mask & ~SIGCANTMASK,
            .sa_flags = flags,
        };

        if (act.handler == SIG_IGN) {
            proc.sig_ignore |= bit;
            proc.sig_catch &= ~bit;
            proc.sig_pending &= ~bit;
        } else if (act.handler == SIG_DFL) {
            proc.sig_ignore &= ~bit;
            proc.sig_catch &= ~bit;
        } else {
            proc.sig_ignore &= ~bit;
            proc.sig_catch |= bit;
        }
    }
    return 0;
}

pub fn actionToUser(act: SigAction) User64SigactionOut {
    return .{
        .handler = act.handler,
        .sa_mask = act.sa_mask,
        .sa_flags = act.sa_flags,
    };
}

/// Post `sig` to a process (kill). Pending is process-wide; delivery picks it
/// up on any thread that does not block it.
pub fn postProcess(proc: *Process, sig: u32) i64 {
    if (sig == 0) return 0; // existence check only
    if (!validateSignum(sig)) return -EINVAL;
    const bit = sigBit(sig);
    if ((proc.sig_ignore & bit) != 0 and sig != SIGKILL and sig != SIGSTOP) {
        return 0;
    }
    proc.sig_pending |= bit;
    sched.wakeProcessForSignal(proc);
    return 0;
}

/// Post `sig` to a specific thread (pthread_kill).
pub fn postThread(task: *Task, sig: u32) i64 {
    if (sig == 0) return 0;
    if (!validateSignum(sig)) return -EINVAL;
    const bit = sigBit(sig);
    if ((task.process.sig_ignore & bit) != 0 and sig != SIGKILL and sig != SIGSTOP) {
        return 0;
    }
    task.sig_pending |= bit;
    sched.wakeTaskForSignal(task);
    return 0;
}

fn nextPending(task: *Task) ?u32 {
    const combined = (task.sig_pending | task.process.sig_pending) & ~task.sig_mask;
    if (combined == 0) return null;
    var sig: u32 = 1;
    while (sig < NSIG) : (sig += 1) {
        if ((combined & sigBit(sig)) != 0) return sig;
    }
    return null;
}

fn clearPending(task: *Task, sig: u32) void {
    const bit = sigBit(sig);
    task.sig_pending &= ~bit;
    task.process.sig_pending &= ~bit;
}

fn fillMcontext(mctx: *UserMcontext, frame: *const context.Frame) void {
    mctx.x = frame.x;
    mctx.sp = frame.sp_el0;
    mctx.pc = frame.elr_el1;
    mctx.cpsr = frame.spsr_el1;
    mctx.esr = frame.esr_el1;
    mctx.far = frame.far_el1;
}

fn applyMcontext(frame: *context.Frame, mctx: *const UserMcontext) void {
    frame.x = mctx.x;
    frame.sp_el0 = mctx.sp;
    frame.elr_el1 = mctx.pc;
    frame.spsr_el1 = mctx.cpsr;
}

/// Deliver at most one pending signal by rewriting `frame` for `__sigtramp`.
/// Returns true if the frame was redirected (or the task exited).
pub fn deliver(core_id: u64, frame: *context.Frame, task: *Task) bool {
    while (nextPending(task)) |sig| {
        clearPending(task, sig);

        const act = task.process.sig_actions[sig];
        if (act.handler == SIG_IGN) continue;

        if (act.handler == SIG_DFL) {
            // Milestone default: terminate on any uncaught signal (including
            // SIGKILL). Job-control stop/continue is out of scope.
            sched.exitCurrentTask(core_id, frame);
            return true;
        }

        const tramp = act.sa_tramp;
        if (tramp == 0) {
            sched.exitCurrentTask(core_id, frame);
            return true;
        }

        // Build sigframe below the current SP (16-byte aligned, red zone).
        const redzone: u64 = 128;
        var sp = frame.sp_el0;
        if (sp > redzone) sp -= redzone;
        sp &= ~@as(u64, 0xf);
        const frame_size = @sizeOf(UserSigframe);
        if (sp < frame_size) {
            sched.exitCurrentTask(core_id, frame);
            return true;
        }
        sp -= frame_size;
        sp &= ~@as(u64, 0xf);

        var sigframe: UserSigframe = .{};
        sigframe.sinfo.si_signo = @intCast(sig);
        sigframe.sinfo.si_code = 0;
        fillMcontext(&sigframe.mctx, frame);

        const mctx_addr = sp + @offsetOf(UserSigframe, "mctx");
        const sinfo_addr = sp + @offsetOf(UserSigframe, "sinfo");
        const uctx_addr = sp + @offsetOf(UserSigframe, "uctx");

        sigframe.uctx = .{
            .uc_onstack = 0,
            .uc_sigmask = task.sig_mask,
            .uc_stack = .{ .ss_sp = frame.sp_el0, .ss_size = 0, .ss_flags = 0 },
            .uc_link = 0,
            .uc_mcsize = @sizeOf(UserMcontext),
            .uc_mcontext = mctx_addr,
        };

        if (!usercopy.copyOut(UserSigframe, sp, sigframe)) {
            sched.exitCurrentTask(core_id, frame);
            return true;
        }

        task.sig_oldmask = task.sig_mask;
        var new_mask = task.sig_mask | act.sa_mask;
        if ((act.sa_flags & SA_NODEFER) == 0) new_mask |= sigBit(sig);
        task.sig_mask = new_mask & ~SIGCANTMASK;

        if ((act.sa_flags & SA_RESETHAND) != 0 and sig != SIGILL and sig != SIGTRAP) {
            _ = setAction(task.process, sig, .{
                .handler = SIG_DFL,
                .sa_tramp = 0,
                .sa_mask = 0,
                .sa_flags = 0,
            });
        }

        const style: i32 = if ((act.sa_flags & SA_SIGINFO) != 0) UC_FLAVOR else UC_TRAD;
        const token: u64 = uctx_addr;

        @memset(&frame.x, 0);
        frame.x[0] = act.handler;
        frame.x[1] = @bitCast(@as(i64, style));
        frame.x[2] = sig;
        frame.x[3] = sinfo_addr;
        frame.x[4] = uctx_addr;
        frame.x[5] = token;
        frame.sp_el0 = sp;
        frame.elr_el1 = tramp;
        frame.spsr_el1 = 0; // EL0t
        return true;
    }
    return false;
}

/// Deliver for the currently running task on `core_id`.
pub fn deliverCurrent(core_id: u64, frame: *context.Frame) void {
    const task = sched.tryCurrentTask(core_id) orelse return;
    task.frame = frame.*;
    _ = deliver(core_id, frame, task);
    // Keep the slot's saved frame aligned with any trampoline rewrite.
    if (sched.tryCurrentTask(core_id)) |cur| {
        if (cur == task) cur.frame = frame.*;
    }
}

const SIGILL: u32 = 4;
const SIGTRAP: u32 = 5;

/// Restore context from a user ucontext written at delivery time.
pub fn sigreturn(frame: *context.Frame, task: *Task, uctx_addr: u64, infostyle: i32, token: u64) i64 {
    _ = infostyle;
    if (uctx_addr == 0) return -EINVAL;
    // Soft token check: we stamped token == uctx_addr at delivery.
    if (token != 0 and token != uctx_addr) return -EINVAL;

    const uctx = usercopy.copyIn(UserUcontext, uctx_addr) orelse return -EFAULT;
    if (uctx.uc_mcontext == 0) return -EINVAL;
    const mctx = usercopy.copyIn(UserMcontext, uctx.uc_mcontext) orelse return -EFAULT;

    applyMcontext(frame, &mctx);
    task.sig_mask = uctx.uc_sigmask & ~SIGCANTMASK;
    return 0;
}
