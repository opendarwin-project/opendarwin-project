//! Thin wrapper around conduit's virtio GPU driver
//! (conduit/driver/virtio_gpu.zig). Discovery stashes candidates; the IOKit
//! VirtioGpuFramebuffer binds them via `init`. Scanout aperture is allocated
//! here and exposed to userspace via Darwin IOKitLib (mach_msg + trap 100).

const conduit = @import("conduit");
const provider = @import("../device/provider.zig");
const mmu = @import("../mm/mmu.zig");
const pmm = @import("../mm/pmm.zig");

const PAGE_SIZE = mmu.PAGE_SIZE;

/// Module-level (not stack-local) so the struct has a stable address before
/// `start()` programs the virtqueue into the device - the device DMAs
/// directly into this struct's embedded descriptor/avail/used rings, and
/// conduit's driver contract requires the value not move after that point.
pub var device: ?conduit.driver.virtio_gpu.Virtio = null;
var matched: ?provider.Info = null;

var candidate_buf: [40]provider.Info = undefined;
var candidate_count: usize = 0;
var stored_ecam: ?u64 = null;

/// Physically contiguous scanout backing (identity-mapped: kernel VA == PA).
var scanout_pa: u64 = 0;
var scanout_len: u64 = 0;
var scanout_w: u32 = 0;
var scanout_h: u32 = 0;
var scanout_ready: bool = false;

/// Userspace framebuffer info (B8G8R8X8 / BGRA8).
pub const FbInfo = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    format: u32 = 0, // 0 = BGRA8 / B8G8R8X8
    size: u64 = 0,
};

pub const FB_FORMAT_BGRA8: u32 = 0;

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

/// Allocate a contiguous scanout buffer, attach it to the device, and record
/// aperture metadata for IOKit / userspace. Tries preferred mode then smaller
/// fallbacks if contiguous allocation fails.
pub fn setupScanout() bool {
    if (!ready()) return false;
    if (scanout_ready) return true;

    const preferred = displayInfo();
    const modes = [_][2]u32{
        .{ preferred.width, preferred.height },
        .{ 800, 600 },
        .{ 640, 480 },
    };

    for (modes) |mode| {
        const w = mode[0];
        const h = mode[1];
        if (w == 0 or h == 0) continue;
        const bytes: u64 = @as(u64, w) * @as(u64, h) * 4;
        const pages = (bytes + PAGE_SIZE - 1) / PAGE_SIZE;
        const pa = pmm.allocPagesContig(pages);
        if (pa == 0) continue;

        const fb: [*]u8 = @ptrFromInt(pa);
        if (!setup(fb, w, h)) {
            pmm.freePages(pa, pages);
            continue;
        }

        // Dark clear so QEMU shows a live scanout before userspace paints.
        @memset(fb[0..bytes], 0x18);

        scanout_pa = pa;
        scanout_len = pages * PAGE_SIZE;
        scanout_w = w;
        scanout_h = h;
        scanout_ready = true;
        _ = present();
        return true;
    }
    return false;
}

pub fn scanoutInfo() ?FbInfo {
    if (!scanout_ready) return null;
    return .{
        .width = scanout_w,
        .height = scanout_h,
        .stride = scanout_w * 4,
        .format = FB_FORMAT_BGRA8,
        .size = scanout_len,
    };
}

pub fn scanoutPhysical() ?struct { pa: u64, len: u64 } {
    if (!scanout_ready) return null;
    return .{ .pa = scanout_pa, .len = scanout_len };
}

pub fn apertureBase() u64 {
    return scanout_pa;
}

pub fn apertureLength() u64 {
    return scanout_len;
}

/// Push the current framebuffer contents to the host and flush to display.
pub fn present() bool {
    if (!ready()) return false;
    return device.?.present();
}

pub fn matchedDevice() ?provider.Info {
    return matched;
}

pub fn ready() bool {
    return device != null;
}

pub fn scanoutIsReady() bool {
    return scanout_ready;
}
