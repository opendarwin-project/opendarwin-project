const conduit = @import("conduit");

/// QEMU virt's default GICv2 MMIO windows (`-machine virt` without an
/// explicit `gic-version=`, which defaults to 2 for up to 8 vCPUs).
pub const DIST_BASE: u64 = 0x0800_0000;
pub const CPU_BASE: u64 = 0x0801_0000;
pub const MMIO_LEN: u64 = 0x0002_0000; // covers both windows in one region

var gic: conduit.driver.gicv2.Gicv2 = undefined;

pub fn init() void {
    gic = conduit.driver.gicv2.bind(
        conduit.Mmio.direct(DIST_BASE),
        conduit.Mmio.direct(CPU_BASE),
    );
}

pub fn enable(irq: u32) void {
    gic.enable(irq);
}

/// Acknowledges the pending interrupt and returns its ID, or null if
/// spurious (nothing actually pending - can happen with shared/level IRQs).
pub fn claim() ?u32 {
    return gic.claim();
}

pub fn complete(irq: u32) void {
    gic.complete(irq);
}
