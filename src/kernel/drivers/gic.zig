const conduit = @import("conduit");

/// QEMU virt's well-known default GICv2 MMIO windows, used only as a
/// bootstrap fallback before the DTB can be parsed - see devicetree.zig's
/// doc comment. `init()` is called once per core (each core has its own
/// banked CPU-interface registers), including every secondary via
/// smp.zig's secondaryMain, so the *discovered* bases (once known) live
/// here as module state rather than being passed as arguments - that way
/// every later init() call (from any core) picks them up automatically
/// with no change needed at those call sites.
pub const BOOTSTRAP_DIST_BASE: u64 = 0x0800_0000;
pub const BOOTSTRAP_CPU_BASE: u64 = 0x0801_0000;
pub const MMIO_LEN: u64 = 0x0002_0000; // covers both windows in one region

var dist_base: u64 = BOOTSTRAP_DIST_BASE;
var cpu_base: u64 = BOOTSTRAP_CPU_BASE;

var gic: conduit.driver.gicv2.Gicv2 = undefined;

/// Called once (by the primary core, from devicetree.zig) after real
/// discovery, before any secondary core's own init() call - see the
/// module doc comment.
pub fn setBases(dist: u64, cpu: u64) void {
    dist_base = dist;
    cpu_base = cpu;
}

pub fn init() void {
    gic = conduit.driver.gicv2.bind(
        conduit.Mmio.direct(dist_base),
        conduit.Mmio.direct(cpu_base),
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
