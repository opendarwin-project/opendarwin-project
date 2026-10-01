//! BSD/XNU-shaped signal registration, posting, and delivery.

use crate::arch::aarch64::context::Frame;
use crate::proc::sched;
use crate::proc::task::{
    NSIG, Process, SIG_DFL, SIG_IGN, SIGCANTMASK, SIGKILL, SIGSTOP, SigAction, Task, sig_bit,
};
use crate::syscall::usercopy;

pub const SA_ONSTACK: i32 = 0x0001;
pub const SA_RESTART: i32 = 0x0002;
pub const SA_RESETHAND: i32 = 0x0004;
pub const SA_NODEFER: i32 = 0x0010;
pub const SA_SIGINFO: i32 = 0x0040;
pub const SA_USERSPACE_MASK: i32 = SA_ONSTACK | SA_RESTART | SA_RESETHAND | SA_NODEFER | SA_SIGINFO;

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct User64SigactionIn {
    pub handler: u64,
    pub sa_tramp: u64,
    pub sa_mask: u32,
    pub sa_flags: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct User64SigactionOut {
    pub handler: u64,
    pub sa_mask: u32,
    pub sa_flags: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct UserSiginfo {
    pub si_signo: i32,
    pub si_errno: i32,
    pub si_code: i32,
    pub si_pid: i32,
    pub si_uid: u32,
    pub si_status: i32,
    pub si_addr: u64,
    pub si_value: u64,
    pub si_band: i64,
    pub pad: [u64; 7],
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct UserStack {
    pub ss_sp: u64,
    pub ss_size: u64,
    pub ss_flags: i32,
    pub __pad: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct UserMcontext {
    pub x: [u64; 31],
    pub sp: u64,
    pub pc: u64,
    pub cpsr: u64,
    pub esr: u64,
    pub far: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct UserUcontext {
    pub uc_onstack: i32,
    pub uc_sigmask: u32,
    pub uc_stack: UserStack,
    pub uc_link: u64,
    pub uc_mcsize: u64,
    pub uc_mcontext: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct UserSigframe {
    pub sinfo: UserSiginfo,
    pub uctx: UserUcontext,
    pub mctx: UserMcontext,
}

pub const UC_TRAD: i32 = 1;
pub const UC_FLAVOR: i32 = 30;

pub const EFAULT: i64 = 14;
pub const EINVAL: i64 = 22;

#[inline(always)]
pub fn validate_signum(sig: u32) -> bool {
    sig > 0 && (sig as usize) < NSIG
}

pub fn get_action(proc: &Process, sig: u32) -> SigAction {
    proc.sig_actions[sig as usize]
}

pub fn set_action(proc: &mut Process, sig: u32, nsa: Option<User64SigactionIn>) -> i64 {
    if !validate_signum(sig) || sig == SIGKILL || sig == SIGSTOP {
        return -EINVAL;
    }

    if let Some(act) = nsa {
        let flags = act.sa_flags & SA_USERSPACE_MASK;
        let bit = sig_bit(sig);
        proc.sig_actions[sig as usize] = SigAction {
            handler: act.handler,
            sa_tramp: act.sa_tramp,
            sa_mask: act.sa_mask & !SIGCANTMASK,
            sa_flags: flags,
        };

        if act.handler == SIG_IGN {
            proc.sig_ignore |= bit;
            proc.sig_catch &= !bit;
            proc.sig_pending &= !bit;
        } else if act.handler == SIG_DFL {
            proc.sig_ignore &= !bit;
            proc.sig_catch &= !bit;
        } else {
            proc.sig_ignore &= !bit;
            proc.sig_catch |= bit;
        }
    }
    0
}

pub fn action_to_user(act: SigAction) -> User64SigactionOut {
    User64SigactionOut {
        handler: act.handler,
        sa_mask: act.sa_mask,
        sa_flags: act.sa_flags,
    }
}

pub fn post_process(proc: &mut Process, sig: u32) -> i64 {
    if sig == 0 {
        return 0;
    }
    if !validate_signum(sig) {
        return -EINVAL;
    }
    let bit = sig_bit(sig);
    if (proc.sig_ignore & bit) != 0 && sig != SIGKILL && sig != SIGSTOP {
        return 0;
    }
    proc.sig_pending |= bit;
    sched::wake_process_for_signal(proc);
    0
}

pub fn post_thread(task: &mut Task, sig: u32) -> i64 {
    if sig == 0 {
        return 0;
    }
    if !validate_signum(sig) {
        return -EINVAL;
    }
    let bit = sig_bit(sig);
    unsafe {
        if ((*task.process).sig_ignore & bit) != 0 && sig != SIGKILL && sig != SIGSTOP {
            return 0;
        }
    }
    task.sig_pending |= bit;
    sched::wake_task_for_signal(task);
    0
}

fn next_pending(task: &Task) -> Option<u32> {
    let combined = unsafe { (task.sig_pending | (*task.process).sig_pending) & !task.sig_mask };
    if combined == 0 {
        return None;
    }
    for sig in 1..NSIG as u32 {
        if (combined & sig_bit(sig)) != 0 {
            return Some(sig);
        }
    }
    None
}

fn clear_pending(task: &mut Task, sig: u32) {
    let bit = sig_bit(sig);
    task.sig_pending &= !bit;
    unsafe {
        (*task.process).sig_pending &= !bit;
    }
}

fn fill_mcontext(mctx: &mut UserMcontext, frame: &Frame) {
    mctx.x = frame.x;
    mctx.sp = frame.sp_el0;
    mctx.pc = frame.elr_el1;
    mctx.cpsr = frame.spsr_el1;
    mctx.esr = frame.esr_el1;
    mctx.far = frame.far_el1;
}

fn apply_mcontext(frame: &mut Frame, mctx: &UserMcontext) {
    frame.x = mctx.x;
    frame.sp_el0 = mctx.sp;
    frame.elr_el1 = mctx.pc;
    frame.spsr_el1 = mctx.cpsr;
}

pub fn deliver(core_id: u64, frame: &mut Frame, task: &mut Task) -> bool {
    while let Some(sig) = next_pending(task) {
        clear_pending(task, sig);

        let act = unsafe { (*task.process).sig_actions[sig as usize] };
        if act.handler == SIG_IGN {
            continue;
        }

        if act.handler == SIG_DFL {
            sched::exit_current_task(core_id, frame);
            return true;
        }

        let tramp = act.sa_tramp;
        if tramp == 0 {
            sched::exit_current_task(core_id, frame);
            return true;
        }

        let redzone: u64 = 128;
        let mut sp = frame.sp_el0;
        if sp > redzone {
            sp -= redzone;
        }
        sp &= !0xf;
        let frame_size = core::mem::size_of::<UserSigframe>() as u64;
        if sp < frame_size {
            sched::exit_current_task(core_id, frame);
            return true;
        }
        sp -= frame_size;
        sp &= !0xf;

        let mut sigframe = UserSigframe::default();
        sigframe.sinfo.si_signo = sig as i32;
        sigframe.sinfo.si_code = 0;
        fill_mcontext(&mut sigframe.mctx, frame);

        let mctx_addr = sp + core::mem::offset_of!(UserSigframe, mctx) as u64;
        let sinfo_addr = sp + core::mem::offset_of!(UserSigframe, sinfo) as u64;
        let uctx_addr = sp + core::mem::offset_of!(UserSigframe, uctx) as u64;

        sigframe.uctx = UserUcontext {
            uc_onstack: 0,
            uc_sigmask: task.sig_mask,
            uc_stack: UserStack {
                ss_sp: frame.sp_el0,
                ss_size: 0,
                ss_flags: 0,
                __pad: 0,
            },
            uc_link: 0,
            uc_mcsize: core::mem::size_of::<UserMcontext>() as u64,
            uc_mcontext: mctx_addr,
        };

        if !usercopy::copy_out(sp as usize, &sigframe) {
            sched::exit_current_task(core_id, frame);
            return true;
        }

        task.sig_oldmask = task.sig_mask;
        let mut new_mask = task.sig_mask | act.sa_mask;
        if (act.sa_flags & SA_NODEFER) == 0 {
            new_mask |= sig_bit(sig);
        }
        task.sig_mask = new_mask & !SIGCANTMASK;

        if (act.sa_flags & SA_RESETHAND) != 0 && sig != 4 && sig != 5 {
            unsafe {
                set_action(
                    &mut *task.process,
                    sig,
                    Some(User64SigactionIn {
                        handler: SIG_DFL,
                        sa_tramp: 0,
                        sa_mask: 0,
                        sa_flags: 0,
                    }),
                );
            }
        }

        let style = if (act.sa_flags & SA_SIGINFO) != 0 {
            UC_FLAVOR
        } else {
            UC_TRAD
        };
        let token = uctx_addr;

        frame.x = [0; 31];
        frame.x[0] = act.handler;
        frame.x[1] = style as i64 as u64;
        frame.x[2] = sig as u64;
        frame.x[3] = sinfo_addr;
        frame.x[4] = uctx_addr;
        frame.x[5] = token;
        frame.sp_el0 = sp;
        frame.elr_el1 = tramp;
        frame.spsr_el1 = 0; // EL0t
        return true;
    }
    false
}

pub fn deliver_current(core_id: u64, frame: &mut Frame) {
    let Some(task) = sched::try_current_task(core_id) else {
        return;
    };
    task.frame = *frame;
    deliver(core_id, frame, task);
}

pub fn sigreturn(
    frame: &mut Frame,
    task: &mut Task,
    uctx_addr: usize,
    style: i32,
    _token: u64,
) -> i64 {
    if style != UC_TRAD && style != UC_FLAVOR {
        return -EINVAL;
    }
    let Some(uctx) = usercopy::copy_in::<UserUcontext>(uctx_addr) else {
        return -EFAULT;
    };
    let Some(mctx) = usercopy::copy_in::<UserMcontext>(uctx.uc_mcontext as usize) else {
        return -EFAULT;
    };

    apply_mcontext(frame, &mctx);
    task.sig_mask = uctx.uc_sigmask & !SIGCANTMASK;
    0
}
