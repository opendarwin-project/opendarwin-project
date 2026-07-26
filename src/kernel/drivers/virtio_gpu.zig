//! Thin wrapper around conduit's virtio GPU driver
//! (conduit/driver/virtio_gpu.zig). Discovery stashes candidates; the IOKit
//! VirtioGpuFramebuffer binds them via `init` rather than a DISPLAY kext.

const conduit = @import("conduit");
const provider = @import("../device/provider.zig");
const mmu = @import("../mm/mmu.zig");

/// Module-level (not stack-local) so the struct has a stable address before
/// `start()` programs the virtqueue into the device - the device DMAs
/// directly into this struct's embedded descriptor/avail/used rings, and
/// conduit's driver contract requires the value not move after that point.
pub var device: ?conduit.driver.virtio_gpu.Virtio = null;
var matched: ?provider.Info = null;

var candidate_buf: [40]provider.Info = undefined;
var candidate_count: usize = 0;
var stored_ecam: ?u64 = null;

/// Record discovery results for later IOKit publish + bind. Does not
/// touch the device.
pub fn stashCandidates(matches: []const provider.Info, ecam_base: ?u64) void {
    const n = @min(matches.len, candidate_buf.len);
    @memcpy(candidate_buf[0..n], matches[0..n]);
    candidate_count = n;
    stored_ecam = ecam_base;
}

pub fn stashedCandidates() []const provider.Info {
    return candidate_buf[0..candidate_count];
}

pub fn stashedEcam() ?u64 {
    return stored_ecam;
}

/// Try each candidate match until one probes as a real virtio-gpu device.
/// `ecam_base` is required for PCI candidates (from the DTB host bridge).
/// Returns true and leaves `device` and `matched` populated on success.
pub fn init(candidate_matches: []const provider.Info, ecam_base: ?u64) bool {
    // Prefer PCI candidates: QEMU attaches virtio-gpu-pci, while MMIO slots are
    // usually empty placeholders that fail the magic/device-id probe.
    for (candidate_matches) |m| {
        if (m.pci_vendor_id == 0) continue;
        if (ecam_base) |ecam| {
            if (tryPci(m, ecam)) {
                matched = m;
                return true;
            }
        }
    }
    for (candidate_matches) |m| {
        if (m.pci_vendor_id != 0) continue;
        if (m.mmio_base == 0) continue;
        device = conduit.driver.virtio_gpu.bind(conduit.Mmio.direct(m.mmio_base));
        if (device.?.start()) {
            matched = m;
            return true;
        }
    }
    device = null;
    matched = null;
    return false;
}

fn tryPci(m: provider.Info, ecam_base: u64) bool {
    // Prefer modern virtio-gpu; also accept any Red Hat virtio display class.
    const looks_gpu = (m.pci_vendor_id == 0x1AF4 and m.pci_device_id == 0x1050) or
        m.pci_class_code == 0x03;
    if (!looks_gpu) return false;

    // Assign BARs (direct -kernel boot leaves them at 0) and map each window.
    const bars = conduit.driver.virtio_pci.assignBars(
        ecam_base,
        m.pci_bus,
        m.pci_device,
        m.pci_function,
    );
    for (bars) |bar| {
        if (bar.is_high_half or bar.is_io or bar.base == 0 or bar.size == 0) continue;
        mmu.mapExtra(bar.base, bar.size, .{ .writable = true, .executable = false, .user = false, .device = true });
    }

    const transport = conduit.driver.virtio_pci.bind(
        ecam_base,
        m.pci_bus,
        m.pci_device,
        m.pci_function,
    ) orelse return false;

    device = conduit.driver.virtio_gpu.bindPci(transport);
    if (device.?.start()) return true;
    device = null;
    return false;
}

/// The discovered GPU's display mode (width x height), once `init` has succeeded.
pub fn displayInfo() conduit.driver.virtio_gpu.Display {
    return device.?.displayInfo();
}

/// Bind a guest framebuffer (B8G8R8X8, stride w*4) as the scanout 0 surface.
pub fn setup(fb: [*]u8, w: u32, h: u32) bool {
    return device.?.setup(fb, w, h);
}

/// Push the current framebuffer contents to the host and flush to display.
pub fn present() bool {
    return device.?.present();
}

pub fn matchedDevice() ?provider.Info {
    return matched;
}

pub fn ready() bool {
    return device != null;
}
