const uart = @import("../../drivers/uart.zig");
const context = @import("context.zig");
const dispatch = @import("../../syscall/dispatch.zig");
const gic = @import("../../drivers/gic.zig");
const timer = @import("../../drivers/timer.zig");
const sched = @import("../../proc/sched.zig");
const signal = @import("../../proc/signal.zig");
const cpu = @import("cpu.zig");
const vmm_mod = @import("../../mm/vmm.zig");

const Frame = context.Frame;

extern const vector_table: u8;

pub fn init() void {
    const addr = @intFromPtr(&vector_table);
    asm volatile ("msr vbar_el1, %[addr]"
        :
        : [addr] "r" (addr),
    );
    asm volatile ("isb");
}

fn haltForever() noreturn {
    while (true) asm volatile ("wfe");
}

fn ecName(ec: u6) []const u8 {
    return switch (ec) {
        0b000000 => "unknown",
        0b000001 => "trapped WFI/WFE",
        0b001110 => "illegal execution state",
        0b010001 => "SVC (AArch32)",
        0b010101 => "SVC (AArch64)",
        0b100000 => "instruction abort (lower EL)",
        0b100001 => "instruction abort (same EL)",
        0b100010 => "PC alignment fault",
        0b100100 => "data abort (lower EL)",
        0b100101 => "data abort (same EL)",
        0b100110 => "SP alignment fault",
        0b101100 => "trapped FP exception (AArch64)",
        else => "unhandled",
    };
}

// Hand-rolled, byte-at-a-time diagnostic printing. `std.fmt.bufPrint`'s copy
// routines can emit wide (8/16-byte) unaligned loads/stores, which fault
// unconditionally on strongly-ordered Device memory - the memory type the
// architecture forces on every access while the stage-1 MMU is disabled
// (i.e. before mm/vmm.zig runs, step 5). Every helper below only ever
// touches memory one byte at a time to stay safe pre-MMU.
fn printHex(v: u64) void {
    const digits = "0123456789abcdef";
    var buf: [18]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const shift: u6 = @intCast((15 - i) * 4);
        const nibble: u4 = @truncate(v >> shift);
        buf[2 + i] = digits[nibble];
    }
    uart.print(&buf);
}

fn printLabeled(label: []const u8, v: u64) void {
    uart.print(label);
    printHex(v);
    uart.print("\n");
}

fn dumpFrame(kind: []const u8, frame: *const Frame) void {
    const ec: u6 = @truncate(frame.esr_el1 >> 26);

    uart.print("\n--- unhandled ");
    uart.print(kind);
    uart.print(" exception (");
    uart.print(ecName(ec));
    uart.print(") ---\n");
    printLabeled("  esr_el1  = ", frame.esr_el1);
    printLabeled("  elr_el1  = ", frame.elr_el1);
    printLabeled("  far_el1  = ", frame.far_el1);
    printLabeled("  spsr_el1 = ", frame.spsr_el1);
    printLabeled("  sp_el0   = ", frame.sp_el0);
    printLabeled("  x30 (lr) = ", frame.x[30]);
    printLabeled("  x0        = ", frame.x[0]);
    printLabeled("  x1        = ", frame.x[1]);
    printLabeled("  x2        = ", frame.x[2]);
    printLabeled("  x3        = ", frame.x[3]);
    printLabeled("  x4        = ", frame.x[4]);
    printLabeled("  x5        = ", frame.x[5]);
}

export fn handleSyncException(frame: *Frame) callconv(.c) void {
    const ec: u6 = @truncate(frame.esr_el1 >> 26);
    switch (ec) {
        0b010101 => {
            // SVC (AArch64). elr_el1 already points at the instruction
            // right after the svc, so simply returning here (back to
            // sync_trampoline's RESTORE_CONTEXT + eret) resumes the task
            // exactly where it left off — unless a pending signal redirects
            // the frame to __sigtramp first.
            dispatch.handle(frame);
            signal.deliverCurrent(cpu.coreId(), frame);
        },
        0b100100 => {
            // Data abort (lower EL) - could be a COW fault
            const far = frame.far_el1;
            const current_vmm = sched.currentVmm(cpu.coreId());
            if (current_vmm.handleCowFault(far)) {
                // COW fault handled - return to retry the instruction
                return;
            }
            // Not a COW fault - dump and halt
            dumpFrame("synchronous", frame);
            haltForever();
        },
        else => {
            dumpFrame("synchronous", frame);
            haltForever();
        },
    }
}

export fn handleIrqException(frame: *Frame) callconv(.c) void {
    const irq = gic.claim() orelse return; // spurious

    switch (irq) {
        timer.IRQ => {
            timer.rearm();
            timer.accountTick();
            sched.tick(cpu.coreId(), frame);
        },
        else => {
            uart.print("unexpected IRQ ");
            printHex(@as(u64, irq));
            uart.print("\n");
        },
    }

    gic.complete(irq);
    signal.deliverCurrent(cpu.coreId(), frame);
}

export fn handleFiqException(frame: *Frame) callconv(.c) void {
    dumpFrame("FIQ", frame);
    haltForever();
}

export fn handleSErrorException(frame: *Frame) callconv(.c) void {
    dumpFrame("SError", frame);
    haltForever();
}

export fn handleUnexpectedException(frame: *Frame) callconv(.c) void {
    dumpFrame("unexpected (AArch32 lower-EL)", frame);
    haltForever();
}
