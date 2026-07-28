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

const std = @import("std");
const conduit = @import("conduit");
const dtree = @import("dtree");
const mmu = @import("mm/mmu.zig");
const uart = @import("drivers/uart.zig");
const provider = @import("device/provider.zig");

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
    /// Physical RAM base and size discovered from the /memory node.
    memory_base: ?u64 = null,
    memory_size: ?u64 = null,
    /// Compact projections of Conduit `.block` matches. QEMU virt's DTB lists
    /// one node per virtio-mmio transport slot whether or not a device is
    /// actually plugged into it, so callers must probe each candidate
    /// (virtio_blk.init() does, via Virtio.start()'s magic/device-id check)
    /// rather than assuming the first one is real.
    virtio_blk_matches: [MAX_VIRTIO_CANDIDATES]provider.Info = undefined,
    virtio_blk_count: usize = 0,
    /// Same for Conduit `.display` matches (virtio-gpu devices).
    virtio_gpu_matches: [MAX_VIRTIO_CANDIDATES]provider.Info = undefined,
    virtio_gpu_count: usize = 0,
    /// ECAM base from the PCI host bridge, when present.
    pci_ecam_base: ?u64 = null,
};

/// QEMU virt's DTB always lists every virtio-mmio transport slot (32 by
/// default) regardless of how many are actually populated by `-device`.
/// Extra slots leave room for PCI display devices discovered via ECAM.
pub const MAX_VIRTIO_CANDIDATES: usize = 40;

/// Reads a big-endian u64 from the first `n` bytes of a slice
/// (where n is 4 or 8, depending on address/size cells).
fn readBigU64(buf: []const u8) u64 {
    if (buf.len >= 8) return std.mem.readInt(u64, buf[0..8], .big);
    // 4-byte cell: zero-extend to 64 bits
    return std.mem.readInt(u32, buf[0..4], .big);
}

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

    var virtio_it = reg.iter(.block);
    while (virtio_it.next() catch null) |m| {
        if (found.virtio_blk_count >= MAX_VIRTIO_CANDIDATES) break;
        if (m.mmio()) |r| {
            mmu.mapExtra(r.base, r.size, .{ .writable = true, .executable = false, .user = false, .device = true });
            found.virtio_blk_matches[found.virtio_blk_count] = provider.fromConduitMatch(&m);
            found.virtio_blk_count += 1;
        }
    }
    if (found.virtio_blk_count > 0) {
        uart.print("devicetree: virtio-mmio candidates found\n");
    }

    // PCI enumeration via ECAM before MMIO display candidates: QEMU virt lists
    // every empty virtio,mmio slot as `.display`, which would otherwise fill
    // the candidate array and crowd out the real virtio-gpu-pci device.
    if (findEcam(&reader)) |ecam| {
        // Map only enough ECAM for the buses we scan (freestanding MAX_BUSES=16).
        // A full 256 MiB window is unnecessary and expensive in boot page tables.
        const map_size = @min(ecam.size, @as(u64, 16) << 20);
        mmu.mapExtra(ecam.base, map_size, .{ .writable = true, .executable = false, .user = false, .device = true });
        found.pci_ecam_base = ecam.base;
        uart.print("devicetree: PCI ECAM base ");
        uart.printHex(ecam.base);
        uart.print("\n");

        var pci_be = conduit.backend.pci.PciBackend.init(ecam.base);
        const pci_matchers = [_]conduit.Matcher{conduit.pci_matcher};
        var pci_reg = conduit.Registry.init(pci_be.any(), &pci_matchers);
        var pci_it = pci_reg.iter(.pci);
        var saw_pci_gpu = false;
        while (pci_it.next() catch null) |m| {
            if (m.pci) |p| {
                uart.print("devicetree: PCI device ");
                uart.printHex(@as(u64, p.vendor_id) | (@as(u64, p.device_id) << 16));
                uart.print(" class=");
                uart.printHex(p.class_code);
                uart.print("\n");

                const is_virtio_gpu = p.vendor_id == 0x1AF4 and p.device_id == 0x1050;
                const is_display = p.class_code == 0x03;
                if ((is_virtio_gpu or is_display) and found.virtio_gpu_count < MAX_VIRTIO_CANDIDATES) {
                    // Map every memory BAR before the driver binds.
                    var bar_i: usize = 0;
                    while (m.mmioAt(bar_i)) |r| : (bar_i += 1) {
                        if (r.size > 0) {
                            mmu.mapExtra(r.base, r.size, .{ .writable = true, .executable = false, .user = false, .device = true });
                        }
                    }
                    var info = provider.fromConduitMatch(&m);
                    info.class = .display;
                    info.name = if (is_virtio_gpu) "virtio-gpu-pci" else "pci-display";
                    // Prefer the first MMIO BAR as a hint; PCI bind re-reads BARs from ECAM.
                    if (m.mmio()) |r| {
                        info.mmio_base = r.base;
                        info.mmio_len = r.size;
                    }
                    found.virtio_gpu_matches[found.virtio_gpu_count] = info;
                    found.virtio_gpu_count += 1;
                    saw_pci_gpu = true;
                }
            }
        }
        if (saw_pci_gpu) {
            uart.print("devicetree: PCI GPU candidates found\n");
        }
    }

    var gpu_it = reg.iter(.display);
    while (gpu_it.next() catch null) |m| {
        if (found.virtio_gpu_count >= MAX_VIRTIO_CANDIDATES) break;
        if (m.mmio()) |r| {
            mmu.mapExtra(r.base, r.size, .{ .writable = true, .executable = false, .user = false, .device = true });
            found.virtio_gpu_matches[found.virtio_gpu_count] = provider.fromConduitMatch(&m);
            found.virtio_gpu_count += 1;
        }
    }
    if (found.virtio_gpu_count > 0) {
        uart.print("devicetree: virtio-gpu candidates found\n");
    }

    // Parse /memory node for physical RAM layout.
    // The 'reg' property encodes (address, size) pairs using
    // #address-cells and #size-cells from the root node.
    if (reader.find(&.{ "", "memory", "reg" })) |reg_bytes| {
        const addr_cells_raw = reader.findAs(u32, &.{ "", "#address-cells" }) catch @as(u32, 2);
        const size_cells_raw = reader.findAs(u32, &.{ "", "#size-cells" }) catch @as(u32, 1);
        const addr_cells = addr_cells_raw;
        const size_cells = size_cells_raw;
        const addr_stride: usize = @as(usize, addr_cells) * 4;
        const size_stride: usize = @as(usize, size_cells) * 4;
        const entry_len = addr_stride + size_stride;

        // Take the first memory region (most DTBs have only one).
        if (reg_bytes.len >= entry_len) {
            const base = readBigU64(reg_bytes[0..addr_stride]);
            const size = readBigU64(reg_bytes[addr_stride..][0..size_stride]);
            if (size > 0) {
                found.memory_base = base;
                found.memory_size = size;
            }
        }
    } else |_| {
        // No /memory node; caller will use a default.
    }

    return found;
}

/// Scan the DTB for a PCI host bridge node (`pcie@*` / `pci@*`, or compatible
/// containing `pci-host-ecam`) and return its ECAM `reg` window.
fn findEcam(reader: *const dtree.Reader) ?EcamWindow {
    const Frame = struct {
        name: []const u8 = "",
        reg: ?[]const u8 = null,
        compatible: ?[]const u8 = null,
    };

    var stack: [32]Frame = [_]Frame{.{}} ** 32;
    var sp: usize = 0;
    var it = reader.nodeIterator();

    while (it.next() catch null) |n| {
        switch (n) {
            .begin => |b| {
                if (sp >= stack.len) return null;
                stack[sp] = .{ .name = b.name };
                sp += 1;
            },
            .end => {
                if (sp == 0) continue;
                sp -= 1;
                const frame = stack[sp];
                const name_ok = std.mem.startsWith(u8, frame.name, "pcie") or
                    std.mem.startsWith(u8, frame.name, "pci");
                const compat_ok = if (frame.compatible) |c|
                    std.mem.indexOf(u8, c, "pci-host-ecam") != null
                else
                    false;
                if (!(name_ok or compat_ok)) continue;
                if (frame.reg) |rb| {
                    if (rb.len >= 8) {
                        const base = readBigU64(rb[0..8]);
                        const size = if (rb.len >= 16) readBigU64(rb[8..16]) else 0x1000_0000;
                        uart.print("devicetree: found pci node '");
                        uart.print(frame.name);
                        uart.print("'\n");
                        return .{
                            .base = base,
                            .size = if (size == 0) 0x1000_0000 else size,
                        };
                    }
                }
            },
            .prop => |p| {
                if (sp == 0) continue;
                if (std.mem.eql(u8, p.name, "reg")) {
                    stack[sp - 1].reg = p.value;
                } else if (std.mem.eql(u8, p.name, "compatible")) {
                    stack[sp - 1].compatible = p.value;
                }
            },
        }
    }
    return null;
}

const EcamWindow = struct { base: u64, size: u64 };
