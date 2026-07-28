//! VirtioGpuFramebuffer — IOFramebuffer that binds conduit virtio-gpu.

const types = @import("../types.zig");
const service = @import("../service.zig");
const framebuffer = @import("../framebuffer.zig");
const pci_device = @import("../pci_device.zig");
const registry = @import("../registry.zig");
const virtio_gpu = @import("../../drivers/virtio_gpu.zig");
const provider_info = @import("../../device/provider.zig");
const uart = @import("../../drivers/uart.zig");

pub const CLASS_NAME = "VirtioGpuFramebuffer";

var instance: VirtioGpuFramebuffer = .{};
var attached: bool = false;

pub const VirtioGpuFramebuffer = struct {
    fb: framebuffer.IOFramebuffer = undefined,
    pci: ?*pci_device.IOPCIDevice = null,

    pub fn asService(self: *VirtioGpuFramebuffer) *service.IOService {
        return self.fb.asService();
    }
};

fn matchProvider(provider: *service.IOService) bool {
    if (classEql(provider.getClassName(), pci_device.CLASS_NAME)) {
        const pci = pci_device.IOPCIDevice.fromService(provider);
        return pci.looksLikeVirtioGpu();
    }
    if (classEql(provider.getClassName(), "IODisplayNub")) {
        const pci = pci_device.IOPCIDevice.fromService(provider);
        return pci.mmio_base != 0;
    }
    return false;
}

fn attachAndStart(provider: *service.IOService) types.IOReturn {
    if (attached and virtio_gpu.ready()) return types.kIOReturnSuccess;
    if (attached) return types.kIOReturnNotReady;

    instance.fb.init(&vtable, "virtio-gpu-fb");
    instance.fb.service.setClassName(CLASS_NAME);
    _ = instance.fb.service.entry.setPropertyStr("IOClass", CLASS_NAME);
    _ = instance.fb.service.entry.setPropertyStr("IOProviderClass", provider.getClassName());

    if (!instance.fb.asService().attachToProvider(provider)) {
        return types.kIOReturnNoMemory;
    }
    instance.pci = pci_device.IOPCIDevice.fromService(provider);
    attached = true;

    const rc = instance.fb.asService().start(provider);
    if (rc != types.kIOReturnSuccess) {
        attached = false;
        return rc;
    }
    // Publish so IOServiceGetMatchingService("IOFramebuffer") can find us.
    _ = registry.publish(instance.asService());
    return types.kIOReturnSuccess;
}

fn probe(svc: *service.IOService, provider: *service.IOService) types.IOReturn {
    _ = svc;
    if (!matchProvider(provider)) return types.kIOReturnNoDevice;
    return types.kIOReturnSuccess;
}

fn start(svc: *service.IOService, provider: *service.IOService) types.IOReturn {
    _ = svc;
    const pci = pci_device.IOPCIDevice.fromService(provider);

    const info = provider_info.Info{
        .class = .display,
        .name = provider.entry.getName(),
        .mmio_base = pci.mmio_base,
        .mmio_len = pci.mmio_len,
        .irq = pci.irq,
        .pci_bus = pci.bus,
        .pci_device = pci.device,
        .pci_function = pci.function,
        .pci_vendor_id = pci.vendor_id,
        .pci_device_id = pci.device_id,
        .pci_class_code = pci.class_code,
        .pci_subclass = pci.subclass,
        .pci_prog_if = pci.prog_if,
    };

    const ecam: ?u64 = if (pci.ecam_base != 0) pci.ecam_base else null;
    if (!virtio_gpu.init(&.{info}, ecam)) {
        uart.print("opendarwin: VirtioGpuFramebuffer: bind failed\n");
        return types.kIOReturnNoDevice;
    }

    if (!virtio_gpu.setupScanout()) {
        uart.print("opendarwin: VirtioGpuFramebuffer: scanout setup failed\n");
        return types.kIOReturnNoMemory;
    }

    const scan = virtio_gpu.scanoutInfo() orelse return types.kIOReturnNotReady;
    instance.fb.mode = .{
        .width = scan.width,
        .height = scan.height,
        .depth = 32,
    };
    instance.fb.aperture_base = virtio_gpu.apertureBase();
    instance.fb.aperture_length = virtio_gpu.apertureLength();
    instance.fb.pixels = .{
        .bytes_per_row = scan.stride,
        .bytes_per_pixel = 4,
        .pixel_type = 0,
    };

    uart.print("opendarwin: virtio-gpu device ready (IOKit)\n");
    return types.kIOReturnSuccess;
}

fn stop(svc: *service.IOService, provider: *service.IOService) void {
    _ = svc;
    _ = provider;
}

fn getDisplayMode(fb: *framebuffer.IOFramebuffer, out: *framebuffer.DisplayMode) types.IOReturn {
    if (!virtio_gpu.ready()) return types.kIOReturnNotReady;
    out.* = fb.mode;
    if (out.width == 0) {
        const display = virtio_gpu.displayInfo();
        out.width = display.width;
        out.height = display.height;
        out.depth = 32;
    }
    return types.kIOReturnSuccess;
}

fn setDisplayMode(fb: *framebuffer.IOFramebuffer, mode: framebuffer.DisplayMode) types.IOReturn {
    fb.mode = mode;
    fb.pixels.bytes_per_row = mode.width * 4;
    return types.kIOReturnSuccess;
}

fn getAperture(fb: *framebuffer.IOFramebuffer, base: *u64, len: *u64) types.IOReturn {
    base.* = fb.aperture_base;
    len.* = fb.aperture_length;
    if (fb.aperture_length == 0) return types.kIOReturnNotReady;
    return types.kIOReturnSuccess;
}

fn getPixelInformation(fb: *framebuffer.IOFramebuffer, out: *framebuffer.PixelInformation) types.IOReturn {
    out.* = fb.pixels;
    return types.kIOReturnSuccess;
}

const vtable = framebuffer.IOFramebufferVtable{
    .service = .{
        .probe = probe,
        .start = start,
        .stop = stop,
        .matchPropertyTable = null,
    },
    .getDisplayMode = getDisplayMode,
    .setDisplayMode = setDisplayMode,
    .getAperture = getAperture,
    .getPixelInformation = getPixelInformation,
};

pub fn register() void {
    _ = registry.registerDriver(.{
        .class_name = CLASS_NAME,
        .provider_class = pci_device.CLASS_NAME,
        .match = matchProvider,
        .attach_and_start = attachAndStart,
    });
    _ = registry.registerDriver(.{
        .class_name = CLASS_NAME,
        .provider_class = "IODisplayNub",
        .match = matchProvider,
        .attach_and_start = attachAndStart,
    });
}

pub fn getInstance() ?*VirtioGpuFramebuffer {
    if (!attached) return null;
    return &instance;
}

fn classEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
