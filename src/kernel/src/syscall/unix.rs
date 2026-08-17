//! BSD / Unix syscall handlers for Darwin userland.

use crate::arch::aarch64::context::Frame;
use crate::arch::aarch64::cpu;
use crate::drivers::{timer, uart};
use crate::proc::{sched, signal, task::SIGCANTMASK};
use crate::syscall::fd;
use crate::syscall::numbers::*;
use crate::syscall::usercopy;

pub const EFAULT: i64 = 14;
pub const EINVAL: i64 = 22;
pub const ESRCH: i64 = 3;

pub fn handle(frame: &mut Frame) {
    let num = frame.arg_u32(16) as u16;
    match num {
        SYS_EXIT => sys_exit(frame),
        SYS_WRITE => sys_write(frame),
        SYS_READ => sys_read(frame),
        SYS_OPEN => sys_open(frame),
        SYS_CLOSE => sys_close(frame),
        SYS_GETPID => sys_getpid(frame),
        SYS_KILL => sys_kill(frame),
        SYS_SIGACTION => sys_sigaction(frame),
        SYS_SIGPROCMASK => sys_sigprocmask(frame),
        SYS_SIGRETURN => sys_sigreturn(frame),
        SYS_PTHREAD_KILL => sys_pthread_kill(frame),
        SYS_STAT | SYS_STAT64 | SYS_LSTAT64 => sys_stat(frame),
        SYS_FSTAT | SYS_FSTAT64 => sys_fstat(frame),
        SYS_LSEEK => sys_lseek(frame),
        SYS_MMAP => sys_mmap(frame),
        SYS_MUNMAP => sys_munmap(frame),
        SYS_MPROTECT => sys_mprotect(frame),
        SYS___SEMWAIT_SIGNAL | SYS___SEMWAIT_SIGNAL_NOCANCEL => sys_semwait_signal(frame),
        SYS_SOCKET => sys_socket(frame),
        SYS_SOCKETPAIR => sys_socketpair(frame),
        SYS_GETSOCKNAME => sys_getsockname(frame),
        SYS_BSDTHREAD_CREATE => sys_bsdthread_create(frame),
        SYS_BSDTHREAD_TERMINATE => sys_bsdthread_terminate(frame),
        SYS_BSDTHREAD_REGISTER => sys_bsdthread_register(frame),
        SYS_THREAD_SELFID => sys_thread_selfid(frame),
        SYS_ULOCK_WAIT2 => sys_ulock_wait2(frame),
        SYS_ULOCK_WAKE => sys_ulock_wake(frame),
        _ => {
            uart::print("syscall: unimplemented BSD syscall ");
            uart::print_dec(num as u64);
            uart::print("\n");
            frame.set_return_u64(0);
        }
    }
}

fn copy_from_user(dst: &mut [u8], user_addr: usize) -> bool {
    if dst.is_empty() {
        return true;
    }
    let task = sched::current_task(cpu::core_id());
    let mut i = 0;
    while i < dst.len() {
        let va = user_addr + i;
        let Some(pa) = crate::mm::mmu::get_physical_address(unsafe { &*task.ttbr0 }, va as u64)
        else {
            return false;
        };
        let page_left = (0x1000 - (va & 0xfff)) as usize;
        let n = (dst.len() - i).min(page_left);
        unsafe {
            let src = core::slice::from_raw_parts(pa as *const u8, n);
            dst[i..i + n].copy_from_slice(src);
        }
        i += n;
    }
    true
}

fn sys_write(frame: &mut Frame) {
    let fd = frame.arg_u64(0);
    let buf_addr = frame.arg(1);
    let len = frame.arg(2);
    if fd == 1 || fd == 2 {
        let mut tmp = [0u8; 256];
        let mut done = 0usize;
        while done < len {
            let chunk = (len - done).min(tmp.len());
            if !copy_from_user(&mut tmp[..chunk], buf_addr + done) {
                frame.set_return_i64(-EFAULT);
                return;
            }
            if let Ok(s) = core::str::from_utf8(&tmp[..chunk]) {
                uart::print(s);
            } else {
                uart::print_bytes(&tmp[..chunk]);
            }
            done += chunk;
        }
        frame.set_return_usize(len);
    } else if let Some(ret) = fd::write(fd, buf_addr, len) {
        frame.set_return_u64(ret);
    } else {
        frame.set_return_i64(-1);
    }
}

fn sys_read(frame: &mut Frame) {
    let fd = frame.arg_u64(0);
    let buf_addr = frame.arg(1);
    let len = frame.arg(2);
    loop {
        let Some(ret) = fd::read(fd, buf_addr, len) else {
            frame.set_return_u64(0);
            return;
        };
        if fd::would_block(ret) && fd::is_socket(fd) {
            _ = sched::block_current_on_fd(cpu::core_id(), frame, fd);
            continue;
        }
        frame.set_return_u64(ret);
        return;
    }
}

fn sys_open(frame: &mut Frame) {
    frame.set_return_u64(fd::open(frame.arg(0), frame.arg_u64(1), frame.arg_u64(2)));
}

fn sys_close(frame: &mut Frame) {
    frame.set_return_u64(fd::close(frame.arg_u64(0)).unwrap_or(0));
}

fn sys_fstat(frame: &mut Frame) {
    frame.set_return_u64(fd::fstat(frame.arg_u64(0), frame.arg(1)));
}

fn sys_stat(frame: &mut Frame) {
    frame.set_return_u64(fd::stat(frame.arg(0), frame.arg(1)));
}

fn sys_lseek(frame: &mut Frame) {
    let whence = frame.arg_i32(2);
    frame.set_return_u64(fd::lseek(frame.arg_u64(0), frame.arg_i64(1), whence));
}

fn sys_mmap(frame: &mut Frame) {
    let addr = frame.arg_u64(0);
    let len = frame.arg_u64(1);
    let prot = frame.arg_i32(2);
    let flags = frame.arg_i32(3);
    let vmm = sched::current_vmm(cpu::core_id());
    frame.set_return_u64(vmm.mmap(addr, len, prot, flags));
}

fn sys_munmap(frame: &mut Frame) {
    let addr = frame.arg_u64(0);
    let len = frame.arg_u64(1);
    let vmm = sched::current_vmm(cpu::core_id());
    frame.set_return_i64(vmm.munmap(addr, len) as i64);
}

fn sys_mprotect(frame: &mut Frame) {
    let addr = frame.arg_u64(0);
    let len = frame.arg_u64(1);
    let prot = frame.arg_i32(2);
    let vmm = sched::current_vmm(cpu::core_id());
    frame.set_return_i64(vmm.mprotect(addr, len, prot) as i64);
}

fn sys_semwait_signal(frame: &mut Frame) {
    let has_timeout = frame.arg_u64(2) != 0;
    if !has_timeout {
        frame.set_return_u64(0);
        return;
    }
    let relative = frame.arg_u64(3) != 0;
    let tv_sec = frame.arg_i64(4);
    let tv_nsec = (frame.arg_u64(5) & 0xffff_ffff) as i64;
    const NSEC_PER_SEC: i64 = 1_000_000_000;
    if tv_sec < 0 || tv_nsec < 0 || tv_nsec >= NSEC_PER_SEC {
        frame.set_return_i64(-EINVAL);
        return;
    }
    let sec_ms = (tv_sec as u64).saturating_mul(1000);
    let nsec_ms = ((tv_nsec + 999_999) as u64) / 1_000_000;
    let duration_ms = sec_ms.saturating_add(nsec_ms);
    let deadline = if relative {
        timer::now_ms().saturating_add(duration_ms)
    } else {
        duration_ms
    };
    if deadline <= timer::now_ms() {
        frame.set_return_u64(0);
        return;
    }
    _ = sched::block_current_until(cpu::core_id(), frame, deadline);
}

fn sys_socket(frame: &mut Frame) {
    frame.set_return_u64(fd::socket(
        frame.arg_u64(0),
        frame.arg_u64(1),
        frame.arg_u64(2),
    ));
}

fn sys_socketpair(frame: &mut Frame) {
    frame.set_return_u64(fd::socketpair(frame.arg(3)));
}

fn sys_getsockname(frame: &mut Frame) {
    frame.set_return_u64(fd::getsockname(
        frame.arg_u64(0),
        frame.arg(1),
        frame.arg(2),
    ));
}

fn sys_getpid(frame: &mut Frame) {
    frame.set_return_u64(1);
}

fn sys_kill(frame: &mut Frame) {
    let pid = frame.arg_i64(0);
    let sig = frame.arg_u32(1);
    if pid != 0 && pid != 1 && pid != -1 {
        frame.set_return_i64(-ESRCH);
        return;
    }
    let proc = sched::current_process(cpu::core_id());
    frame.set_return_i64(signal::post_process(proc, sig) as i64);
}

fn sys_pthread_kill(frame: &mut Frame) {
    let thread_id = frame.arg_u64(0);
    let sig = frame.arg_u32(1);
    let Some(task_ptr) = sched::task_by_thread_id(thread_id) else {
        frame.set_return_i64(-ESRCH);
        return;
    };
    unsafe {
        frame.set_return_i64(signal::post_thread(&mut *task_ptr, sig) as i64);
    }
}

fn sys_sigaction(frame: &mut Frame) {
    let sig = frame.arg_u32(0);
    let nsa_ptr = frame.arg(1);
    let osa_ptr = frame.arg(2);

    if !signal::validate_signum(sig) || sig == crate::proc::SIGKILL || sig == crate::proc::SIGSTOP {
        frame.set_return_i64(-EINVAL);
        return;
    }

    let proc = sched::current_process(cpu::core_id());

    if osa_ptr != 0 {
        let old = signal::action_to_user(signal::get_action(proc, sig));
        if !usercopy::copy_out(osa_ptr, &old) {
            frame.set_return_i64(-EFAULT);
            return;
        }
    }

    if nsa_ptr != 0 {
        let Some(nsa) = usercopy::copy_in::<signal::User64SigactionIn>(nsa_ptr) else {
            frame.set_return_i64(-EFAULT);
            return;
        };
        let err = signal::set_action(proc, sig, Some(nsa));
        if err < 0 {
            frame.set_return_i64(err as i64);
            return;
        }
    }

    frame.set_return_u64(0);
}

fn sys_sigprocmask(frame: &mut Frame) {
    let how = frame.arg_i32(0);
    let set_ptr = frame.arg(1);
    let oset_ptr = frame.arg(2);
    let task = sched::current_task(cpu::core_id());

    if oset_ptr != 0 {
        if !usercopy::copy_out(oset_ptr, &task.sig_mask) {
            frame.set_return_i64(-EFAULT);
            return;
        }
    }

    if set_ptr != 0 {
        let Some(set) = usercopy::copy_in::<u32>(set_ptr) else {
            frame.set_return_i64(-EFAULT);
            return;
        };
        match how {
            1 => task.sig_mask |= set & !SIGCANTMASK,    // SIG_BLOCK
            2 => task.sig_mask &= !(set & !SIGCANTMASK), // SIG_UNBLOCK
            3 => task.sig_mask = set & !SIGCANTMASK,     // SIG_SETMASK
            _ => {
                frame.set_return_i64(-EINVAL);
                return;
            }
        }
    }

    frame.set_return_u64(0);
}

fn sys_sigreturn(frame: &mut Frame) {
    let uctx = frame.arg(0);
    let style = frame.arg_i32(1);
    let token = frame.arg_u64(2);
    let task = sched::current_task(cpu::core_id());
    let err = signal::sigreturn(frame, task, uctx, style, token);
    if err < 0 {
        frame.set_return_i64(err);
    }
}

fn sys_exit(frame: &mut Frame) {
    uart::print("opendarwin: task called exit(");
    uart::print_dec(frame.arg_u64(0));
    uart::print(")\n");
    sched::exit_current_task(cpu::core_id(), frame);
}

fn sys_bsdthread_register(frame: &mut Frame) {
    let thread_start = frame.arg_u64(0);
    let wqstart = frame.arg_u64(1);
    if sched::register_bsd_thread(cpu::core_id(), thread_start, wqstart) {
        frame.set_return_u64(0);
    } else {
        frame.set_return_i64(-EINVAL);
    }
}

fn sys_bsdthread_create(frame: &mut Frame) {
    let start_routine = frame.arg_u64(0);
    let arg = frame.arg_u64(1);
    let stack_top = frame.arg_u64(2);
    let pthread = frame.arg_u64(3);
    if let Some(id) =
        sched::create_bsd_thread(cpu::core_id(), start_routine, arg, stack_top, pthread)
    {
        frame.set_return_u64(id);
    } else {
        frame.set_return_i64(-EINVAL);
    }
}

fn sys_bsdthread_terminate(frame: &mut Frame) {
    sched::exit_current_task(cpu::core_id(), frame);
}

fn sys_thread_selfid(frame: &mut Frame) {
    frame.set_return_u64(sched::current_thread_id(cpu::core_id()));
}

fn sys_ulock_wait2(frame: &mut Frame) {
    let op = frame.arg_u32(0);
    let addr = frame.arg_u64(1);
    let timeout_ns = frame.arg_u64(3);
    let ulf_no_errno = 0x0100_0000;
    if (op & 0x0f) != 1 {
        if (op & ulf_no_errno) != 0 {
            frame.set_return_i64(-EINVAL);
        } else {
            frame.set_return_u64(0);
        }
        return;
    }

    if timeout_ns != 0 {
        let timeout_ms = (timeout_ns + 999_999) / 1_000_000;
        let deadline = timer::now_ms().saturating_add(timeout_ms);
        _ = sched::block_current_on_ulock_until(cpu::core_id(), frame, addr, deadline);
    } else {
        _ = sched::block_current_on_ulock(cpu::core_id(), frame, addr);
    }
}

fn sys_ulock_wake(frame: &mut Frame) {
    let op = frame.arg_u32(0);
    let addr = frame.arg_u64(1);
    let wake_all = (op & 0x0000_0100) != 0;
    let max_count = if wake_all { 0 } else { 1 };
    frame.set_return_u64(sched::wake_ulock(addr, max_count));
}
