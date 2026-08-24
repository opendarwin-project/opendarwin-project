//! IOKit root bring-up: init registry, publish display nubs, match drivers.

const registry = @import("registry.zig");
const pci_device = @import("pci_device.zig");
const virtio_gpu_fb = @import("drivers/virtio_gpu_fb.zig");
const provider_info = @import("../device/provider.zig");
const uart = @import("../drivers/uart.zig");
const slab = @import("../mm/slab.zig");

pub fn init() void {
    registry.init();
    virtio_gpu_fb.register();
}

/// Publish virtio-mmio display nubs for VirtioGpuFramebuffer.
pub fn publishDisplayCandidates(candidates: []const provider_info.Info, ecam_base: ?u64) usize {
    _ = ecam_base;
    var published: usize = 0;

    for (candidates) |m| {
        // PCI virtio-gpu is unused for now; only virtio-mmio slots.
        if (m.pci_vendor_id != 0) continue;
        if (m.mmio_base == 0) continue;

        const slot = slab.allocObj(pci_device.IOPCIDevice);
        slot.initMmioNub(m);
        if (registry.publish(slot.asService())) {
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
pub const types_mod = @import("types.zig");
