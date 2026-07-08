const uart = @import("../drivers/uart.zig");
const context = @import("../arch/aarch64/context.zig");
const sched = @import("../proc/sched.zig");
const cpu = @import("../arch/aarch64/cpu.zig");
const numbers = @import("numbers.zig");
const Vmm = @import("../mm/vmm.zig").Vmm;

const handler_type = *const fn (frame: *context.Frame) void;

pub const table: [256]?handler_type = init: {
    var t: [256]?handler_type = [_]?handler_type{null} ** 256;
    t[numbers.SYS_exit] = sysExit;
    t[numbers.SYS_write] = sysWrite;
    t[numbers.SYS_read] = sysRead;
    t[numbers.SYS_open] = sysOpen;
    t[numbers.SYS_close] = sysClose;
    t[numbers.SYS_fstat] = sysFstat;
    t[numbers.SYS_mmap] = sysMmap;
    t[numbers.SYS_munmap] = sysMunmap;
    t[numbers.SYS_mprotect] = sysMprotect;
    break :init t;
};

pub fn handle(frame: *context.Frame) void {
    const num = frame.x[16];
    if (num >= 256) return;
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

fn sysExit(frame: *context.Frame) void {
    uart.print("opendarwin: task called exit(");
    printDec(frame.x[0]);
    uart.print(")\n");
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
