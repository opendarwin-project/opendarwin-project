const conduit = @import("conduit");

/// QEMU virt's PL011 UART MMIO base.
const PL011_BASE: u64 = 0x0900_0000;

var uart: conduit.driver.pl011.Pl011 = undefined;

pub fn init() void {
    uart = conduit.driver.pl011.bind(conduit.Mmio.direct(PL011_BASE));
}

pub fn print(s: []const u8) void {
    uart.write(s);
}
