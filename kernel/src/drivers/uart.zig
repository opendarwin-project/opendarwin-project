const conduit = @import("conduit");
const SpinLock = @import("../sync/spinlock.zig");

/// QEMU virt's well-known PL011 UART MMIO base, used only as a bootstrap
/// console before the DTB can be parsed (devicetree.zig then re-inits with
/// the discovered address) - see that module's doc comment.
pub const BOOTSTRAP_BASE: u64 = 0x0900_0000;

var uart: conduit.driver.pl011.Pl011 = undefined;
var lock: SpinLock = .{};

pub fn init(base: u64) void {
    lock.lock();
    defer lock.unlock();
    uart = conduit.driver.pl011.bind(conduit.Mmio.direct(base));
}

/// Multiple cores may print concurrently once SMP is up; the PL011 itself
/// has no notion of atomic multi-byte writes, so without this lock two
/// cores' output would interleave byte-by-byte.
pub fn print(s: []const u8) void {
    lock.lock();
    defer lock.unlock();
    uart.write(s);
}

pub fn printHex(value: u64) void {
    const digits = "0123456789abcdef";
    var buf: [18]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';
    for (0..16) |i| {
        const shift: u6 = @intCast((15 - i) * 4);
        const digit: u4 = @truncate(value >> shift);
        buf[2 + i] = digits[digit];
    }
    print(&buf);
}
