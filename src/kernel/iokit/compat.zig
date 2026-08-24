//! C ABI exports for IOKit C++ shim headers (compat/IOKit/*.h).

const types = @import("types.zig");
const registry = @import("registry.zig");
const service = @import("service.zig");
const pci_device = @import("pci_device.zig");
const framebuffer = @import("framebuffer.zig");
const memory = @import("memory.zig");
const root = @import("root.zig");

/// Force the linker to keep these exports when referenced from kmain.
pub fn linkForce() void {
    _ = &IOKit_RegistryRoot;
    _ = &IOKit_ServiceGetName;
    _ = &IOKit_ServiceGetClassName;
    _ = &IOKit_ServiceGetProvider;
    _ = &IOKit_ServiceGetPropertyU64;
    _ = &IOKit_ServiceStart;
    _ = &IOKit_PCI_ConfigRead16;
    _ = &IOKit_PCI_ConfigRead32;
    _ = &IOKit_PCI_MapBAR;
    _ = &IOKit_Memory_GetVirtualAddress;
    _ = &IOKit_Memory_GetLength;
    _ = &IOKit_Framebuffer_GetDisplayMode;
    _ = &IOKit_Framebuffer_GetAperture;
    _ = &root.init;
}

export fn IOKit_RegistryRoot() callconv(.c) ?*service.IOService {
    return registry.root();
}

export fn IOKit_ServiceGetName(svc: ?*service.IOService, out_len: ?*usize) callconv(.c) ?[*]const u8 {
    const s = svc orelse return null;
    const name = s.entry.getName();
    if (out_len) |p| p.* = name.len;
    if (name.len == 0) return null;
    return name.ptr;
}

export fn IOKit_ServiceGetClassName(svc: ?*service.IOService, out_len: ?*usize) callconv(.c) ?[*]const u8 {
    const s = svc orelse return null;
    const class_name = s.getClassName();
    if (out_len) |p| p.* = class_name.len;
    if (class_name.len == 0) return null;
    return class_name.ptr;
}

export fn IOKit_ServiceGetProvider(svc: ?*service.IOService) callconv(.c) ?*service.IOService {
    const s = svc orelse return null;
    return s.provider;
}

export fn IOKit_ServiceGetPropertyU64(svc: ?*service.IOService, key_ptr: ?[*]const u8, key_len: usize, out: ?*u64) callconv(.c) i32 {
    const s = svc orelse return types.kIOReturnBadArgument;
    const key = if (key_ptr) |p| p[0..key_len] else return types.kIOReturnBadArgument;
    const val = s.entry.getPropertyU64(key) orelse return types.kIOReturnError;
    if (out) |o| o.* = val;
    return types.kIOReturnSuccess;
}

export fn IOKit_ServiceStart(svc: ?*service.IOService, provider: ?*service.IOService) callconv(.c) i32 {
    const s = svc orelse return types.kIOReturnBadArgument;
    const p = provider orelse return types.kIOReturnBadArgument;
    return s.start(p);
}

export fn IOKit_PCI_ConfigRead16(svc: ?*service.IOService, offset: u16) callconv(.c) u16 {
    const s = svc orelse return 0xffff;
    if (!classIs(s, pci_device.CLASS_NAME)) return 0xffff;
    return pci_device.IOPCIDevice.fromService(s).configRead16(offset);
}

export fn IOKit_PCI_ConfigRead32(svc: ?*service.IOService, offset: u16) callconv(.c) u32 {
    const s = svc orelse return 0xffff_ffff;
    if (!classIs(s, pci_device.CLASS_NAME)) return 0xffff_ffff;
    return pci_device.IOPCIDevice.fromService(s).configRead32(offset);
}

export fn IOKit_PCI_MapBAR(svc: ?*service.IOService, bar_index: u8) callconv(.c) ?*memory.IOMemoryDescriptor {
    const s = svc orelse return null;
    if (!classIs(s, pci_device.CLASS_NAME)) return null;
    return pci_device.IOPCIDevice.fromService(s).mapDeviceMemoryWithRegister(bar_index);
}

export fn IOKit_Memory_GetVirtualAddress(desc: ?*memory.IOMemoryDescriptor) callconv(.c) u64 {
    const d = desc orelse return 0;
    return d.getVirtualAddress();
}

export fn IOKit_Memory_GetLength(desc: ?*memory.IOMemoryDescriptor) callconv(.c) u64 {
    const d = desc orelse return 0;
    return d.getLength();
}

export fn IOKit_Framebuffer_GetDisplayMode(svc: ?*service.IOService, width: ?*u32, height: ?*u32, depth: ?*u32) callconv(.c) i32 {
    const s = svc orelse return types.kIOReturnBadArgument;
    const fb = framebuffer.IOFramebuffer.fromService(s);
    var mode: framebuffer.DisplayMode = .{};
    const rc = fb.getDisplayMode(&mode);
    if (rc != types.kIOReturnSuccess) return rc;
    if (width) |w| w.* = mode.width;
    if (height) |h| h.* = mode.height;
    if (depth) |d| d.* = mode.depth;
    return types.kIOReturnSuccess;
}

export fn IOKit_Framebuffer_GetAperture(svc: ?*service.IOService, base: ?*u64, len: ?*u64) callconv(.c) i32 {
    const s = svc orelse return types.kIOReturnBadArgument;
    const fb = framebuffer.IOFramebuffer.fromService(s);
    var b: u64 = 0;
    var l: u64 = 0;
    const rc = fb.getAperture(&b, &l);
    if (base) |p| p.* = b;
    if (len) |p| p.* = l;
    return rc;
}

fn classIs(svc: *service.IOService, name: []const u8) bool {
    const c = svc.getClassName();
    if (c.len != name.len) return false;
    for (c, name) |a, b| {
        if (a != b) return false;
    }
    return true;
}
