//! Thin wrapper around conduit's virtio GPU driver
//! (conduit/driver/virtio_gpu.zig). Discovery stashes candidates; the IOKit
//! VirtioGpuFramebuffer binds them via `init`. Scanout aperture is allocated
//! here and exposed to userspace via Darwin IOKitLib (mach_msg + trap 100).

const conduit = @import("conduit");
const provider = @import("../device/provider.zig");
const mmu = @import("../mm/mmu.zig");
const pmm = @import("../mm/pmm.zig");
const uart = @import("uart.zig");

const VIRTIO_MAGIC: u32 = 0x74726976; // 'virt'
const VIRTIO_REG_MAGIC: usize = 0x000;
const VIRTIO_REG_VERSION: usize = 0x004;
const VIRTIO_REG_DEVICE_ID: usize = 0x008;
const VIRTIO_DEVICE_ID_GPU: u32 = 16;

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

/// True if `base` is a virtio-mmio transport with virtio-gpu's device id.
/// Does not run the feature handshake (empty slots have magic but id 0).
pub fn probe(base: u64) bool {
    if (base == 0) return false;
    const mmio = conduit.Mmio.direct(base);
    if (mmio.read(u32, VIRTIO_REG_MAGIC) != VIRTIO_MAGIC) return false;
    return mmio.read(u32, VIRTIO_REG_DEVICE_ID) == VIRTIO_DEVICE_ID_GPU;
}

/// Record discovery results for later IOKit publish + bind. Keeps only
/// slots that probe as virtio-gpu so empty virtio-mmio transports are not
/// published as display nubs.
pub fn stashCandidates(matches: []const provider.Info, ecam_base: ?u64) void {
    var n: usize = 0;
    for (matches) |m| {
        if (n >= candidate_buf.len) break;
        if (m.pci_vendor_id != 0) continue;
        if (!probe(m.mmio_base)) continue;
        candidate_buf[n] = m;
        n += 1;
    }
    candidate_count = n;
    stored_ecam = ecam_base;
}

pub fn stashedCandidates() []const provider.Info {
    return candidate_buf[0..candidate_count];
}

pub fn stashedEcam() ?u64 {
    return stored_ecam;
}

/// Try each virtio-mmio candidate until one probes as a real virtio-gpu.
/// PCI candidates are ignored. Returns true and leaves `device` and
/// `matched` populated on success.
pub fn init(candidate_matches: []const provider.Info) bool {
    for (candidate_matches) |m| {
        if (m.pci_vendor_id != 0) continue;
        if (m.mmio_base == 0) continue;
        device = conduit.driver.virtio_gpu.bind(conduit.Mmio.direct(m.mmio_base));
        if (device.?.start()) {
            matched = m;
            return true;
        }
        const mmio = conduit.Mmio.direct(m.mmio_base);
        uart.print("opendarwin: virtio-gpu at ");
        uart.printHex(m.mmio_base);
        uart.print(" start failed (version=");
        uart.printHex(mmio.read(u32, VIRTIO_REG_VERSION));
        uart.print(")\n");
    }
    device = null;
    matched = null;
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
