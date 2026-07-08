//! BSD syscall dispatch (`svc #0x80`, x16 = syscall number, args in x0-x2,
//! per ref/syscalls.master's numbering). Only the two syscalls needed to
//! prove the round trip are implemented; everything else is a deliberate,
//! visible stopping point rather than an attempt at the full syscall
//! surface - see the plan's step 8.

const uart = @import("../drivers/uart.zig");
const context = @import("../arch/aarch64/context.zig");
const sched = @import("../proc/sched.zig");

const SYS_exit: u64 = 1;
const SYS_write: u64 = 4;

/// Handles a caught SVC (AArch64) exception whose frame's x16 holds a BSD
/// syscall number. Returns normally (caller ERETs back to x30... no -
/// back to elr_el1) for syscalls that don't terminate the task; halts for
/// exit and for anything unimplemented.
pub fn handle(frame: *context.Frame) void {
    const num = frame.x[16];
    switch (num) {
        SYS_write => sysWrite(frame),
        SYS_exit => sysExit(frame),
        else => {
            uart.print("syscall: unimplemented number ");
            printDec(num);
            uart.print(", halting\n");
            haltForever();
        },
    }
}

fn sysWrite(frame: *context.Frame) void {
    const fd = frame.x[0];
    const buf: [*]const u8 = @ptrFromInt(frame.x[1]);
    const len = frame.x[2];

    if (fd == 1 or fd == 2) {
        uart.print(buf[0..len]);
        frame.x[0] = len; // return value: bytes written
    } else {
        frame.x[0] = @bitCast(@as(i64, -1)); // EBADF-ish; no errno plumbing yet
    }
}

fn sysExit(frame: *context.Frame) void {
    uart.print("opendarwin: task called exit(");
    printDec(frame.x[0]);
    uart.print(")\n");
    // Hands off to the next alive task by overwriting `frame` in place
    // (see sched.zig's module doc comment); halts only if none remain.
    sched.exitCurrent(frame);
}

fn haltForever() noreturn {
    while (true) asm volatile ("wfe");
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
