//! IOKit root bring-up: init registry, publish display nubs, match drivers.

const types = @import("types.zig");
const registry = @import("registry.zig");
const pci_device = @import("pci_device.zig");
const virtio_gpu_fb = @import("drivers/virtio_gpu_fb.zig");
const provider_info = @import("../device/provider.zig");
const uart = @import("../drivers/uart.zig");

var pci_pool: [types.MAX_SERVICES]pci_device.IOPCIDevice = undefined;
var pci_pool_count: usize = 0;

pub fn init() void {
    registry.init();
    virtio_gpu_fb.register();
}

/// Publish display candidates discovered via conduit into the IORegistry.
pub fn publishDisplayCandidates(candidates: []const provider_info.Info, ecam_base: ?u64) usize {
    var published: usize = 0;
    const ecam = ecam_base orelse 0;

    var has_pci = false;
    for (candidates) |m| {
        if (m.class != .display) continue;
        if (m.pci_vendor_id != 0) has_pci = true;
    }

    for (candidates) |m| {
        if (m.class != .display) continue;
        if (pci_pool_count >= pci_pool.len) break;

        if (m.pci_vendor_id != 0) {
            const slot = &pci_pool[pci_pool_count];
            slot.initFromProviderInfo(m, ecam);
            if (registry.publish(slot.asService())) {
                pci_pool_count += 1;
                published += 1;
            }
            continue;
        }

        // Skip empty MMIO placeholders when a PCI GPU exists.
        if (has_pci) continue;
        if (m.mmio_base == 0) continue;

        const slot = &pci_pool[pci_pool_count];
        slot.initMmioNub(m);
        if (registry.publish(slot.asService())) {
            pci_pool_count += 1;
            published += 1;
        }
    }

    if (published == 0) {
        uart.print("opendarwin: iokit: no display nubs published\n");
    }
    return published;
}

pub fn matchAndStartDrivers() usize {
    return registry.matchAndStartDrivers();
}

pub const registry_mod = registry;
pub const pci = pci_device;
pub const framebuffer = @import("framebuffer.zig");
pub const accelerator = @import("accelerator.zig");
pub const memory = @import("memory.zig");
pub const service = @import("service.zig");
pub const types_mod = types;
