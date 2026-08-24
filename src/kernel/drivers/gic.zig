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

// HVF only exposes a GICv3, whose CPU interface lives in ICC_* system
// registers rather than the GICv2 GICC MMIO window; driving the wrong one
// leaves every interrupt (including the periodic timer) undelivered, which
// silently hangs any timed wait. We therefore keep both drivers and select
// at runtime based on what devicetree discovery matched.
var is_v3: bool = false;
var gic2: conduit.driver.gicv2.Gicv2 = undefined;
var gic3: conduit.driver.gicv3.Gicv3 = undefined;

/// Called once (by the primary core, from devicetree.zig) after real
/// discovery, before any secondary core's own init() call - see the
/// module doc comment. `v3` selects the GICv3 (system-register CPU
/// interface + redistributor) path; `cpu` is then the GICR RD_base rather
/// than the GICv2 GICC base.
pub fn setBases(dist: u64, cpu: u64, v3: bool) void {
    dist_base = dist;
    cpu_base = cpu;
    is_v3 = v3;
}

// GICv3 redistributor SGI-frame register offsets (RD_base + 0x10000).
const GICR_SGI_BASE: u64 = 0x10000;
const GICR_IGROUPR0: u64 = GICR_SGI_BASE + 0x0080;
const GICR_IGRPMODR0: u64 = GICR_SGI_BASE + 0x0D00;

pub fn init() void {
    if (is_v3) {
        // conduit's gicv3 driver enables the Group1 CPU interface but never
        // classifies the SGIs/PPIs as Group1 non-secure. Under HVF the
        // redistributor's PPIs default to Group0, so a Group1-only CPU
        // interface (ICC_IGRPEN1) never sees the timer PPI and no interrupt
        // is ever delivered. Force every SGI/PPI into Group1NS here.
        const rd = conduit.Mmio.direct(cpu_base);
        rd.write(u32, GICR_IGROUPR0, 0xffff_ffff); // Group1
        rd.write(u32, GICR_IGRPMODR0, 0x0000_0000); // NS (not Group1-secure)
        gic3 = conduit.driver.gicv3.bind(
            conduit.Mmio.direct(dist_base),
            conduit.Mmio.direct(cpu_base),
        );
    } else {
        gic2 = conduit.driver.gicv2.bind(
            conduit.Mmio.direct(dist_base),
            conduit.Mmio.direct(cpu_base),
        );
    }
}

pub fn enable(irq: u32) void {
    if (is_v3) gic3.enable(irq) else gic2.enable(irq);
}

/// Acknowledges the pending interrupt and returns its ID, or null if
/// spurious (nothing actually pending - can happen with shared/level IRQs).
pub fn claim() ?u32 {
    return if (is_v3) gic3.claim() else gic2.claim();
}

pub fn complete(irq: u32) void {
    if (is_v3) gic3.complete(irq) else gic2.complete(irq);
}
