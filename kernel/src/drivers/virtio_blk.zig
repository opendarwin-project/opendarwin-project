//! Thin wrapper around conduit's virtio-mmio block driver
//! (conduit/driver/virtio_blk.zig). QEMU virt exposes several virtio-mmio
//! transport slots whether or not a device is actually attached to each, so
//! `init` is handed every candidate MMIO base devicetree.zig discovered and
//! probes each in turn - `Virtio.start()` itself checks the magic/device-id/
//! version registers and returns false for an empty slot.

const conduit = @import("conduit");
const provider = @import("../device/provider.zig");

/// Module-level (not stack-local) so the struct has a stable address before
/// `start()` programs the virtqueue into the device - the device DMAs
/// directly into this struct's embedded descriptor/avail/used rings, and
/// conduit's driver contract requires the value not move after that point.
pub var device: ?conduit.driver.virtio_blk.Virtio = null;
var matched: ?provider.Info = null;

/// Try each candidate match until one probes as a real virtio-blk device.
/// Returns true and leaves `device` and `matched` populated on success.
pub fn init(candidate_matches: []const provider.Info) bool {
    for (candidate_matches) |m| {
        device = conduit.driver.virtio_blk.bind(conduit.Mmio.direct(m.mmio_base));
        if (device.?.start()) {
            matched = m;
            return true;
        }
    }
    device = null;
    matched = null;
    return false;
}

/// The discovered disk as a generic block device, once `init` has succeeded.
pub fn block() conduit.device.Block {
    return device.?.block();
}

pub fn matchedDevice() ?provider.Info {
    return matched;
}
