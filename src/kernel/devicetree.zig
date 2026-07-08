//! Real device discovery via conduit's Registry + dtree backend, over the
//! flattened device tree QEMU hands the kernel at boot (x0, captured by
//! start.S into dtb_phys_addr - see that file's comment).
//!
//! Bootstrap ordering: UART/GIC need to be *usable* before this can run
//! (to report discovery progress/errors at all), so drivers/uart.zig and
//! drivers/gic.zig still stand up a minimal console/interrupt controller
//! at QEMU virt's well-known fixed addresses first - see kmain.zig. This
//! module's job is to then discover the *real* addresses from the DTB and
//! re-point those drivers at them, replacing the bootstrap assumption with
//! genuine runtime discovery for steady-state use, rather than hardcoding
//! it permanently. On QEMU virt these values happen to match, which is
//! exactly what lets discovery be verified against a known-good answer.

const conduit = @import("conduit");
const dtree = @import("dtree");
const mmu = @import("mm/mmu.zig");
const uart = @import("drivers/uart.zig");

export var dtb_phys_addr: u64 = 0;

/// Conservative fixed window mapped around the DTB before reading it: real
/// QEMU-virt DTBs are a few KB to a few tens of KB; this just needs to be
/// safely larger than hdr.totalsize, which dtree.Reader.initBuffer checks
/// against the slice length itself (see mmu.zig's mapExtra godoc for why
/// mapping "too much" identity-mapped physical RAM is harmless here).
const DTB_MAP_WINDOW: u64 = 0x10_0000; // 1MB

pub const Found = struct {
    uart_base: ?u64 = null,
    gic_dist_base: ?u64 = null,
    gic_cpu_base: ?u64 = null,
};

/// Returns null if there's no DTB pointer (dtb_phys_addr is 0) or parsing
/// fails; callers keep using the bootstrap addresses in that case.
pub fn discover() ?Found {
    if (dtb_phys_addr == 0) return null;

    mmu.mapExtra(dtb_phys_addr, DTB_MAP_WINDOW, .{ .writable = false, .executable = false, .user = false });

    const blob: [*]const u8 = @ptrFromInt(dtb_phys_addr);
    const reader = dtree.Reader.initBuffer(blob[0..DTB_MAP_WINDOW]) catch |err| {
        uart.print("devicetree: failed to parse DTB: ");
        uart.print(@errorName(err));
        uart.print("\n");
        return null;
    };

    var be = conduit.backend.dtree.DtBackend.init(&reader);
    const reg = conduit.Registry.init(be.any(), &conduit.all_matchers);

    var found = Found{};

    // Discovered addresses are mapped explicitly here rather than assumed
    // to already be covered by mmu.kernel_regions' bootstrap mapping: on
    // QEMU virt they happen to match, but nothing guarantees that on a
    // different board/machine, and the point of doing real discovery is to
    // not depend on that coincidence.
    if (reg.find(.uart) catch null) |m| {
        if (m.mmio()) |r| {
            mmu.mapExtra(r.base, r.size, .{ .writable = true, .executable = false, .user = false, .device = true });
            found.uart_base = r.base;
            uart.print("devicetree: uart '");
            uart.print(m.name);
            uart.print("'\n");
        }
    }

    if (reg.find(.intc) catch null) |m| {
        if (m.mmioAt(0)) |dist| {
            mmu.mapExtra(dist.base, dist.size, .{ .writable = true, .executable = false, .user = false, .device = true });
            found.gic_dist_base = dist.base;
        }
        if (m.mmioAt(1)) |cpui| {
            mmu.mapExtra(cpui.base, cpui.size, .{ .writable = true, .executable = false, .user = false, .device = true });
            found.gic_cpu_base = cpui.base;
        }
        uart.print("devicetree: intc '");
        uart.print(m.name);
        uart.print("'\n");
    }

    return found;
}
