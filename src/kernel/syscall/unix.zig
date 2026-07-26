const uart = @import("../drivers/uart.zig");
const context = @import("../arch/aarch64/context.zig");
const sched = @import("../proc/sched.zig");
const cpu = @import("../arch/aarch64/cpu.zig");
const numbers = @import("numbers.zig");
const Vmm = @import("../mm/vmm.zig").Vmm;
const usercopy = @import("usercopy.zig");
const timer = @import("../drivers/timer.zig");

const handler_type = *const fn (frame: *context.Frame) void;

pub const table: [1024]?handler_type = init: {
    var t: [1024]?handler_type = [_]?handler_type{null} ** 1024;
    t[numbers.SYS_exit] = sysExit;
    t[numbers.SYS_write] = sysWrite;
    t[numbers.SYS_read] = sysRead;
    t[numbers.SYS_open] = sysOpen;
    t[numbers.SYS_close] = sysClose;
    t[numbers.SYS_fstat] = sysFstat;
    t[numbers.SYS_mmap] = sysMmap;
    t[numbers.SYS_munmap] = sysMunmap;
    t[numbers.SYS_mprotect] = sysMprotect;
    t[numbers.SYS_nanosleep] = sysNanosleep;
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
    } else {
        frame.x[0] = @bitCast(@as(i64, -1));
    }
}

fn sysRead(frame: *context.Frame) void {
    frame.x[0] = 0;
}

fn sysOpen(frame: *context.Frame) void {
    frame.x[0] = @bitCast(@as(i64, -1));
}

fn sysClose(frame: *context.Frame) void {
    frame.x[0] = 0;
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

/// XNU syscall 240: nanosleep(requested_time, remaining_time).
fn sysNanosleep(frame: *context.Frame) void {
    const req_addr = frame.x[0];
    if (req_addr == 0) {
        frame.x[0] = @bitCast(-EINVAL);
        return;
    }
    const req = usercopy.copyIn(Timespec, req_addr) orelse {
        frame.x[0] = @bitCast(-EINVAL);
        return;
    };
    if (req.tv_sec < 0 or req.tv_nsec < 0 or req.tv_nsec >= NSEC_PER_SEC) {
        frame.x[0] = @bitCast(-EINVAL);
        return;
    }
    const sec_ms: u64 = @as(u64, @intCast(req.tv_sec)) *| 1000;
    const nsec_ms: u64 = @as(u64, @intCast(req.tv_nsec + 999_999)) / 1_000_000;
    const duration_ms = sec_ms +| nsec_ms;
    if (duration_ms == 0) {
        frame.x[0] = 0;
        return;
    }
    const deadline = timer.nowMs() +| duration_ms;
    if (!sched.blockCurrentUntil(cpu.coreId(), frame, deadline)) {
        // No runnable peer exists on this core. The periodic timer will still
        // preempt soon; report success rather than spinning in userspace.
        frame.x[0] = 0;
    }
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
    if (!sched.blockCurrentOnUlock(cpu.coreId(), frame, addr)) {
        frame.x[0] = @bitCast(-EAGAIN);
    }
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
