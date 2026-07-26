const uart = @import("../drivers/uart.zig");
const context = @import("../arch/aarch64/context.zig");
const sched = @import("../proc/sched.zig");
const signal = @import("../proc/signal.zig");
const cpu = @import("../arch/aarch64/cpu.zig");
const numbers = @import("numbers.zig");
const Vmm = @import("../mm/vmm.zig").Vmm;
const usercopy = @import("usercopy.zig");
const timer = @import("../drivers/timer.zig");
const fdtable = @import("fd.zig");
const task_mod = @import("../proc/task.zig");
const SIGCANTMASK = task_mod.SIGCANTMASK;

const handler_type = *const fn (frame: *context.Frame) void;

pub const table: [1024]?handler_type = init: {
    var t: [1024]?handler_type = [_]?handler_type{null} ** 1024;
    t[numbers.SYS_exit] = sysExit;
    t[numbers.SYS_write] = sysWrite;
    t[numbers.SYS_read] = sysRead;
    t[numbers.SYS_open] = sysOpen;
    t[numbers.SYS_close] = sysClose;
    t[numbers.SYS_getpid] = sysGetpid;
    t[numbers.SYS_kill] = sysKill;
    t[numbers.SYS_sigaction] = sysSigaction;
    t[numbers.SYS_sigprocmask] = sysSigprocmask;
    t[numbers.SYS_sigreturn] = sysSigreturn;
    t[numbers.SYS_pthread_kill] = sysPthreadKill;
    t[numbers.SYS_fstat] = sysFstat;
    t[numbers.SYS_mmap] = sysMmap;
    t[numbers.SYS_munmap] = sysMunmap;
    t[numbers.SYS_mprotect] = sysMprotect;
    t[numbers.SYS___semwait_signal] = sysSemwaitSignal;
    t[numbers.SYS___semwait_signal_nocancel] = sysSemwaitSignal;
    t[numbers.SYS_socket] = sysSocket;
    t[numbers.SYS_socketpair] = sysSocketpair;
    t[numbers.SYS_getsockname] = sysGetsockname;
    t[numbers.SYS_bsdthread_create] = sysBsdthreadCreate;
    t[numbers.SYS_bsdthread_terminate] = sysBsdthreadTerminate;
    t[numbers.SYS_bsdthread_register] = sysBsdthreadRegister;
    t[numbers.SYS_thread_selfid] = sysThreadSelfId;
    t[numbers.SYS_ulock_wait2] = sysUlockWait2;
    t[numbers.SYS_ulock_wake] = sysUlockWake;
    break :init t;
};

pub fn handle(frame: *context.Frame) void {
    const num = frame.x[16];
    if (num >= table.len) return;
    const handler = table[num] orelse {
        uart.print("syscall: unimplemented BSD syscall ");
        printDec(num);
        uart.print("\n");
        frame.x[0] = 0;
        return;
    };
    handler(frame);
}

fn sysWrite(frame: *context.Frame) void {
    const fd = frame.x[0];
    const buf: [*]const u8 = @ptrFromInt(frame.x[1]);
    const len = frame.x[2];
    if (fd == 1 or fd == 2) {
        uart.print(buf[0..len]);
        frame.x[0] = len;
    } else if (fdtable.write(fd, frame.x[1], len)) |ret| {
        frame.x[0] = ret;
    } else {
        frame.x[0] = @bitCast(@as(i64, -1));
    }
}

fn sysRead(frame: *context.Frame) void {
    const fd = frame.x[0];
    while (true) {
        const ret = fdtable.read(fd, frame.x[1], frame.x[2]) orelse {
            frame.x[0] = 0;
            return;
        };
        if (fdtable.wouldBlock(ret) and fdtable.isSocket(fd)) {
            _ = sched.blockCurrentOnFd(cpu.coreId(), frame, fd);
            continue;
        }
        frame.x[0] = ret;
        return;
    }
}

fn sysOpen(frame: *context.Frame) void {
    frame.x[0] = @bitCast(@as(i64, -1));
}

fn sysClose(frame: *context.Frame) void {
    frame.x[0] = fdtable.close(frame.x[0]) orelse 0;
}

fn sysFstat(frame: *context.Frame) void {
    frame.x[0] = @bitCast(@as(i64, -1));
}

fn sysMmap(frame: *context.Frame) void {
    const addr = frame.x[0];
    const len = frame.x[1];
    const prot = frame.x[2];
    const flags = frame.x[3];
    const fd = frame.x[4];
    _ = fd;
    const vmm = sched.currentVmm(cpu.coreId());
    const result = vmm.mmap(addr, len, @intCast(prot), @intCast(flags));
    frame.x[0] = result;
}

fn sysMunmap(frame: *context.Frame) void {
    const addr = frame.x[0];
    const len = frame.x[1];
    const vmm = sched.currentVmm(cpu.coreId());
    frame.x[0] = @as(u64, @bitCast(@as(i64, vmm.munmap(addr, len))));
}

fn sysMprotect(frame: *context.Frame) void {
    const addr = frame.x[0];
    const len = frame.x[1];
    const prot = frame.x[2];
    const vmm = sched.currentVmm(cpu.coreId());
    frame.x[0] = @as(u64, @bitCast(@as(i64, vmm.mprotect(addr, len, @intCast(prot)))));
}

const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};
const NSEC_PER_SEC: i64 = 1_000_000_000;

/// XNU syscall 334/423: __semwait_signal(cond_sem, mutex_sem, timeout,
/// relative, tv_sec, tv_nsec). Darwin's libc nanosleep()/usleep() are
/// implemented on top of this rather than a dedicated nanosleep syscall
/// (which does not exist in XNU). This minimal kernel has no Mach
/// semaphore wait/signal wired to cond_sem/mutex_sem yet, so only the
/// deadline/timeout portion is honored, which is sufficient for the
/// libc sleep primitives that drive it.
fn sysSemwaitSignal(frame: *context.Frame) void {
    const has_timeout = frame.x[2] != 0;
    if (!has_timeout) {
        frame.x[0] = 0;
        return;
    }
    const relative = frame.x[3] != 0;
    const tv_sec: i64 = @bitCast(frame.x[4]);
    const tv_nsec: i64 = @bitCast(frame.x[5] & 0xffffffff);
    if (tv_sec < 0 or tv_nsec < 0 or tv_nsec >= NSEC_PER_SEC) {
        frame.x[0] = @bitCast(-EINVAL);
        return;
    }
    const sec_ms: u64 = @as(u64, @intCast(tv_sec)) *| 1000;
    const nsec_ms: u64 = @as(u64, @intCast(tv_nsec + 999_999)) / 1_000_000;
    const duration_ms = sec_ms +| nsec_ms;
    const deadline = if (relative) timer.nowMs() +| duration_ms else duration_ms;
    if (deadline <= timer.nowMs()) {
        frame.x[0] = 0;
        return;
    }
    // blockCurrentUntil always leaves frame.x[0] correctly set for whichever
    // task ends up resuming into `frame` (self, or a switched-in peer), so
    // it must not be touched again here.
    _ = sched.blockCurrentUntil(cpu.coreId(), frame, deadline);
}

fn sysSocket(frame: *context.Frame) void {
    frame.x[0] = fdtable.socket(frame.x[0], frame.x[1], frame.x[2]);
}

fn sysSocketpair(frame: *context.Frame) void {
    frame.x[0] = fdtable.socketpair(frame.x[3]);
}

fn sysGetsockname(frame: *context.Frame) void {
    frame.x[0] = fdtable.getsockname(frame.x[0], frame.x[1], frame.x[2]);
}

fn sysGetpid(frame: *context.Frame) void {
    frame.x[0] = 1;
}

fn sysKill(frame: *context.Frame) void {
    const pid: i64 = @bitCast(frame.x[0]);
    const sig: u32 = @truncate(frame.x[1]);
    // Milestone: only the single init-style process (pid 0/1/-1/self).
    if (pid != 0 and pid != 1 and pid != -1) {
        frame.x[0] = @bitCast(@as(i64, -3)); // ESRCH
        return;
    }
    const proc = sched.currentProcess(cpu.coreId());
    frame.x[0] = @bitCast(signal.postProcess(proc, sig));
}

fn sysPthreadKill(frame: *context.Frame) void {
    const thread_id = frame.x[0];
    const sig: u32 = @truncate(frame.x[1]);
    const task = sched.taskByThreadId(thread_id) orelse {
        frame.x[0] = @bitCast(@as(i64, -ESRCH));
        return;
    };
    frame.x[0] = @bitCast(signal.postThread(task, sig));
}

/// XNU syscall 46: sigaction(signum, nsa, osa).
/// nsa is `__user64_sigaction` (24 bytes); osa is `user64_sigaction` (16 bytes).
fn sysSigaction(frame: *context.Frame) void {
    const sig: u32 = @truncate(frame.x[0]);
    const nsa_ptr = frame.x[1];
    const osa_ptr = frame.x[2];

    if (!signal.validateSignum(sig) or sig == task_mod.SIGKILL or sig == task_mod.SIGSTOP) {
        frame.x[0] = @bitCast(@as(i64, -EINVAL));
        return;
    }

    const proc = sched.currentProcess(cpu.coreId());

    if (osa_ptr != 0) {
        const old = signal.actionToUser(signal.getAction(proc, sig));
        if (!usercopy.copyOut(signal.User64SigactionOut, osa_ptr, old)) {
            frame.x[0] = @bitCast(@as(i64, -EFAULT));
            return;
        }
    }

    if (nsa_ptr != 0) {
        const nsa = usercopy.copyIn(signal.User64SigactionIn, nsa_ptr) orelse {
            frame.x[0] = @bitCast(@as(i64, -EFAULT));
            return;
        };
        const err = signal.setAction(proc, sig, nsa);
        if (err < 0) {
            frame.x[0] = @bitCast(err);
            return;
        }
    }

    frame.x[0] = 0;
}

/// XNU syscall 184: sigreturn(uctx, infostyle, token).
fn sysSigreturn(frame: *context.Frame) void {
    const uctx = frame.x[0];
    const style: i32 = @truncate(@as(i64, @bitCast(frame.x[1])));
    const token = frame.x[2];
    const task = sched.currentTask(cpu.coreId());
    const err = signal.sigreturn(frame, task, uctx, style, token);
    // On success the restored mcontext owns all GPRs (including x0).
    if (err < 0) frame.x[0] = @bitCast(err);
}

fn sysExit(frame: *context.Frame) void {
    uart.print("opendarwin: task called exit(");
    printDec(frame.x[0]);
    uart.print(")\n");
    sched.exitCurrent(cpu.coreId(), frame);
}

/// XNU syscall 360: bsdthread_create(func, func_arg, stack, pthread, flags).
/// The registered pthread trampoline receives the new thread's arguments.
fn sysBsdthreadCreate(frame: *context.Frame) void {
    const func = frame.x[0];
    const arg = frame.x[1];
    const stack = frame.x[2];
    const pthread = frame.x[3];
    if (func == 0 or pthread == 0 or stack == 0 or (stack & 0xf) != 0) {
        frame.x[0] = @bitCast(@as(i64, -1));
        return;
    }
    frame.x[0] = sched.createBsdThread(cpu.coreId(), func, arg, stack, pthread) orelse @bitCast(@as(i64, -1));
}

/// XNU syscall 366: bsdthread_register(threadstart, wqthread, flags, ...).
fn sysBsdthreadRegister(frame: *context.Frame) void {
    if (frame.x[0] == 0 or !sched.registerBsdThread(cpu.coreId(), frame.x[0], frame.x[1])) {
        frame.x[0] = @bitCast(@as(i64, -1));
        return;
    }
    frame.x[0] = 0;
}

/// XNU syscall 372: stable kernel-assigned ID for the current pthread.
fn sysThreadSelfId(frame: *context.Frame) void {
    frame.x[0] = sched.currentThreadId(cpu.coreId());
}

const EAGAIN: i64 = 35;
const EINVAL: i64 = 22;
const EFAULT: i64 = 14;
const ESRCH: i64 = 3;

/// __ulock_wait2(op, addr, value, timeout, value2). The operation bits are
/// intentionally opaque here: Zig uses the compare-and-wait forms, all of
/// which share the same address/value blocking semantics.
fn sysUlockWait2(frame: *context.Frame) void {
    const addr = frame.x[1];
    const expected: u32 = @truncate(frame.x[2]);
    const actual = usercopy.copyIn(u32, addr) orelse {
        frame.x[0] = @bitCast(-EINVAL);
        return;
    };
    // A changed word means the caller must retry in userspace, matching the
    // Darwin EAGAIN contract and avoiding a missed wake.
    if (actual != expected) {
        frame.x[0] = @bitCast(-EAGAIN);
        return;
    }
    const timeout_ns = frame.x[3];
    const blocked = if (timeout_ns == 0)
        sched.blockCurrentOnUlock(cpu.coreId(), frame, addr)
    else blk: {
        const timeout_ms = (timeout_ns +| 999_999) / 1_000_000;
        break :blk sched.blockCurrentOnUlockUntil(cpu.coreId(), frame, addr, timer.nowMs() +| timeout_ms);
    };
    if (!blocked) frame.x[0] = @bitCast(-EAGAIN);
}

/// __ulock_wake(op, addr, wake_value). Return the number of awakened tasks.
fn sysUlockWake(frame: *context.Frame) void {
    const addr = frame.x[1];
    if (addr == 0) {
        frame.x[0] = @bitCast(-EINVAL);
        return;
    }
    // Darwin's ULF_WAKE_ALL uses bit 0x100; otherwise wake one waiter.
    const wake_all = (frame.x[0] & 0x100) != 0;
    frame.x[0] = sched.wakeUlock(addr, if (wake_all) 0 else 1);
}

/// XNU syscall 361. Stack reclamation/join wakeup need ulock support, so
/// this initial implementation terminates the current thread only.
fn sysBsdthreadTerminate(frame: *context.Frame) void {
    sched.exitCurrent(cpu.coreId(), frame);
}

/// XNU syscall 48: sigprocmask(how, set, oset).
/// how: SIG_BLOCK(1), SIG_UNBLOCK(2), SIG_SETMASK(3)
fn sysSigprocmask(frame: *context.Frame) void {
    const how: u32 = @intCast(frame.x[0]);
    const set_ptr: u64 = frame.x[1];
    const oset_ptr: u64 = frame.x[2];

    const task = sched.currentTask(cpu.coreId());

    if (oset_ptr != 0) {
        if (!usercopy.copyOut(u32, oset_ptr, task.sig_mask)) {
            frame.x[0] = @bitCast(@as(i64, -EFAULT));
            return;
        }
    }

    if (set_ptr != 0) {
        const new_mask = usercopy.copyIn(u32, set_ptr) orelse {
            frame.x[0] = @bitCast(@as(i64, -EFAULT));
            return;
        };
        switch (how) {
            1 => task.sig_mask |= new_mask, // SIG_BLOCK
            2 => task.sig_mask &= ~new_mask, // SIG_UNBLOCK
            3 => task.sig_mask = new_mask, // SIG_SETMASK
            else => {
                frame.x[0] = @bitCast(@as(i64, -EINVAL));
                return;
            },
        }
        task.sig_mask &= ~SIGCANTMASK;
    }

    frame.x[0] = 0;
}

fn printDec(v: u64) void {
    if (v == 0) {
        uart.print("0");
        return;
    }
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var n = v;
    while (n > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
    uart.print(buf[i..]);
}
