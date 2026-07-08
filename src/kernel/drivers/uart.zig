const conduit = @import("conduit");
const SpinLock = @import("../sync/spinlock.zig");

/// QEMU virt's PL011 UART MMIO base.
const PL011_BASE: u64 = 0x0900_0000;

var uart: conduit.driver.pl011.Pl011 = undefined;
var lock: SpinLock = .{};

pub fn init() void {
    uart = conduit.driver.pl011.bind(conduit.Mmio.direct(PL011_BASE));
}

/// Multiple cores may print concurrently once SMP is up; the PL011 itself
/// has no notion of atomic multi-byte writes, so without this lock two
/// cores' output would interleave byte-by-byte.
pub fn print(s: []const u8) void {
    lock.lock();
    defer lock.unlock();
    uart.write(s);
}
