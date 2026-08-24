//! IOPCIDevice — PCI config space + BAR mapping over ECAM.

const types = @import("types.zig");
const service = @import("service.zig");
const memory = @import("memory.zig");
const provider_info = @import("../device/provider.zig");

pub const CLASS_NAME = "IOPCIDevice";

pub const IOPCIDevice = struct {
    service: service.IOService = .{},
    ecam_base: u64 = 0,
    bus: u8 = 0,
    device: u8 = 0,
    function: u8 = 0,
    vendor_id: u16 = 0,
    device_id: u16 = 0,
    class_code: u8 = 0,
    subclass: u8 = 0,
    prog_if: u8 = 0,
    mmio_base: u64 = 0,
    mmio_len: u64 = 0,
    irq: u64 = 0,
    bar_maps: [6]memory.IOMemoryDescriptor = [_]memory.IOMemoryDescriptor{.{}} ** 6,
    bars_assigned: bool = false,

    pub fn initFromProviderInfo(self: *IOPCIDevice, info: provider_info.Info, ecam_base: u64) void {
        var loc_buf: [32]u8 = undefined;
        const loc = formatBdf(&loc_buf, info.pci_bus, info.pci_device, info.pci_function);

        self.* = .{
            .ecam_base = ecam_base,
            .bus = info.pci_bus,
            .device = info.pci_device,
            .function = info.pci_function,
            .vendor_id = info.pci_vendor_id,
            .device_id = info.pci_device_id,
            .class_code = info.pci_class_code,
            .subclass = info.pci_subclass,
            .prog_if = info.pci_prog_if,
            .mmio_base = info.mmio_base,
            .mmio_len = info.mmio_len,
            .irq = info.irq,
        };
        self.service.init(CLASS_NAME, info.name, loc);
        _ = self.service.entry.setPropertyU64("vendor-id", info.pci_vendor_id);
        _ = self.service.entry.setPropertyU64("device-id", info.pci_device_id);
        _ = self.service.entry.setPropertyU64("class-code", info.pci_class_code);
        _ = self.service.entry.setPropertyStr("IOProviderClass", CLASS_NAME);
        self.service.state.registered = true;
    }

    /// MMIO-only display/placeholder nub (no PCI BDF).
    pub fn initMmioNub(self: *IOPCIDevice, info: provider_info.Info) void {
        self.* = .{
            .mmio_base = info.mmio_base,
            .mmio_len = info.mmio_len,
            .irq = info.irq,
        };
        self.service.init("IODisplayNub", info.name, "mmio");
        _ = self.service.entry.setPropertyU64("mmio-base", info.mmio_base);
        _ = self.service.entry.setPropertyU64("mmio-len", info.mmio_len);
        _ = self.service.entry.setPropertyStr("IOProviderClass", "IODisplayNub");
        self.service.state.registered = true;
    }

    pub fn asService(self: *IOPCIDevice) *service.IOService {
        return &self.service;
    }

    pub fn fromService(svc: *service.IOService) *IOPCIDevice {
        return @fieldParentPtr("service", svc);
    }

    pub fn configRead8(self: *const IOPCIDevice, offset: u16) u8 {
        return pciConfigRead8(self.ecam_base, self.bus, self.device, self.function, offset);
    }

    pub fn configRead16(self: *const IOPCIDevice, offset: u16) u16 {
        return pciConfigRead16(self.ecam_base, self.bus, self.device, self.function, offset);
    }

    pub fn configRead32(self: *const IOPCIDevice, offset: u16) u32 {
        return pciConfigRead32(self.ecam_base, self.bus, self.device, self.function, offset);
    }

    pub fn configWrite16(self: *IOPCIDevice, offset: u16, value: u16) void {
        pciConfigWrite16(self.ecam_base, self.bus, self.device, self.function, offset, value);
    }

    pub fn assignAndMapBars(self: *IOPCIDevice) types.IOReturn {
        if (self.mmio_base == 0 or self.mmio_len == 0) return types.kIOReturnNoDevice;
        self.bar_maps[0].initWithPhysicalRange(self.mmio_base, self.mmio_len);
        const rc = self.bar_maps[0].map();
        if (rc != types.kIOReturnSuccess) return rc;
        self.bars_assigned = true;
        return types.kIOReturnSuccess;
    }

    pub fn mapDeviceMemoryWithRegister(self: *IOPCIDevice, bar_index: u8) ?*memory.IOMemoryDescriptor {
        if (bar_index >= 6) return null;
        if (!self.bars_assigned) {
            if (self.assignAndMapBars() != types.kIOReturnSuccess) return null;
        }
        const desc = &self.bar_maps[bar_index];
        if (desc.length == 0) return null;
        return desc;
    }

    pub fn looksLikeVirtioGpu(self: *const IOPCIDevice) bool {
        return (self.vendor_id == 0x1AF4 and self.device_id == 0x1050) or self.class_code == 0x03;
    }
};

fn formatBdf(buf: *[32]u8, bus: u8, device: u8, function: u8) []const u8 {
    const hex = "0123456789abcdef";
    buf[0] = hex[(bus >> 4) & 0xf];
    buf[1] = hex[bus & 0xf];
    buf[2] = ':';
    buf[3] = hex[(device >> 4) & 0xf];
    buf[4] = hex[device & 0xf];
    buf[5] = '.';
    buf[6] = hex[function & 0xf];
    return buf[0..7];
}

fn pciConfigRead8(ecam: u64, bus: u8, device: u8, function: u8, offset: u16) u8 {
    const ptr: *volatile u8 = @ptrFromInt(ecamAddr(ecam, bus, device, function, offset));
    return ptr.*;
}

fn pciConfigRead16(ecam: u64, bus: u8, device: u8, function: u8, offset: u16) u16 {
    const ptr: *volatile u16 = @ptrFromInt(ecamAddr(ecam, bus, device, function, offset));
    return ptr.*;
}

fn pciConfigRead32(ecam: u64, bus: u8, device: u8, function: u8, offset: u16) u32 {
    const ptr: *volatile u32 = @ptrFromInt(ecamAddr(ecam, bus, device, function, offset));
    return ptr.*;
}

fn pciConfigWrite16(ecam: u64, bus: u8, device: u8, function: u8, offset: u16, value: u16) void {
    const ptr: *volatile u16 = @ptrFromInt(ecamAddr(ecam, bus, device, function, offset));
    ptr.* = value;
}

fn ecamAddr(ecam: u64, bus: u8, device: u8, function: u8, offset: u16) u64 {
    return ecam + (@as(u64, bus) << 20) + (@as(u64, device) << 15) + (@as(u64, function) << 12) + offset;
}
