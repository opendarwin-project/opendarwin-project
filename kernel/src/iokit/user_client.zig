//! IOUserClient — userspace connection to an IOService (Darwin-shaped).

const types = @import("types.zig");
const service = @import("service.zig");
const framebuffer = @import("framebuffer.zig");
const virtio_gpu = @import("../drivers/virtio_gpu.zig");
const IpcPort = @import("../ipc/port.zig").IpcPort;

pub const KObjectTag = enum(u32) {
    none = 0,
    master = 1,
    service = 2,
    connect = 3,
};

/// Kernel object stamped on IOKit Mach ports (stored via ip_kobject).
pub const PortObject = struct {
    tag: KObjectTag,
    service: ?*service.IOService = null,
    connect: ?*IOUserClient = null,
};

pub const IOUserClient = struct {
    service: *service.IOService,
    port: ?*IpcPort = null,
    /// True when this UC is an IOFramebuffer connection.
    is_framebuffer: bool = false,
};

const MAX_CONNECTS: usize = 8;
var connect_pool: [MAX_CONNECTS]IOUserClient = undefined;
var connect_port_objs: [MAX_CONNECTS]PortObject = undefined;
var connect_count: usize = 0;

var master_port_obj: PortObject = .{ .tag = .master };
var service_port_objs: [types.MAX_SERVICES]PortObject = undefined;

pub fn masterPortObject() *PortObject {
    return &master_port_obj;
}

pub fn bindServicePort(svc: *service.IOService, port: *IpcPort) *PortObject {
    // Reuse slot by service pointer when possible.
    for (&service_port_objs) |*obj| {
        if (obj.tag == .service and obj.service == svc) {
            port.ip_kobject = obj;
            return obj;
        }
    }
    for (&service_port_objs) |*obj| {
        if (obj.tag == .none) {
            obj.* = .{ .tag = .service, .service = svc };
            port.ip_kobject = obj;
            return obj;
        }
    }
    // Overwrite slot 0 as last resort (smoke has few services).
    service_port_objs[0] = .{ .tag = .service, .service = svc };
    port.ip_kobject = &service_port_objs[0];
    return &service_port_objs[0];
}

pub fn open(svc: *service.IOService) ?*IOUserClient {
    if (connect_count >= MAX_CONNECTS) return null;
    const uc = &connect_pool[connect_count];
    const po = &connect_port_objs[connect_count];
    connect_count += 1;
    uc.* = .{
        .service = svc,
        .is_framebuffer = isFramebufferService(svc),
    };
    po.* = .{ .tag = .connect, .service = svc, .connect = uc };
    return uc;
}

pub fn bindConnectPort(uc: *IOUserClient, port: *IpcPort) void {
    for (&connect_port_objs) |*obj| {
        if (obj.connect == uc) {
            port.ip_kobject = obj;
            uc.port = port;
            return;
        }
    }
}

fn isFramebufferService(svc: *service.IOService) bool {
    const name = svc.getClassName();
    if (classEql(name, framebuffer.CLASS_NAME)) return true;
    if (classEql(name, "VirtioGpuFramebuffer")) return true;
    return false;
}

fn classEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

pub fn asPortObject(ptr: ?*anyopaque) ?*PortObject {
    return @ptrCast(@alignCast(ptr));
}

/// IOConnectCallMethod selectors for IOFramebuffer connections.
pub const kIOFBSelectGetInfo: u32 = 0;
pub const kIOFBSelectPresent: u32 = 1;

pub const FbInfo = virtio_gpu.FbInfo;

pub fn framebufferGetInfo(uc: *IOUserClient, out: *FbInfo) types.IOReturn {
    if (!uc.is_framebuffer) return types.kIOReturnUnsupported;
    const info = virtio_gpu.scanoutInfo() orelse return types.kIOReturnNotReady;
    out.* = info;
    return types.kIOReturnSuccess;
}

pub fn framebufferPresent(uc: *IOUserClient) types.IOReturn {
    if (!uc.is_framebuffer) return types.kIOReturnUnsupported;
    if (!virtio_gpu.present()) return types.kIOReturnError;
    return types.kIOReturnSuccess;
}

pub fn framebufferMapAperture(uc: *IOUserClient) ?struct { pa: u64, len: u64 } {
    if (!uc.is_framebuffer) return null;
    const phys = virtio_gpu.scanoutPhysical() orelse return null;
    return .{ .pa = phys.pa, .len = phys.len };
}

/// Darwin `iokit_user_client_trap` / IOConnectTrap index dispatch.
/// Index 0: getInfo — p1 = user pointer to FbInfo
/// Index 1: present
pub fn trap(uc: *IOUserClient, index: u32, p1: u64, p2: u64, p3: u64, p4: u64, p5: u64, p6: u64) types.IOReturn {
    _ = p2;
    _ = p3;
    _ = p4;
    _ = p5;
    _ = p6;
    switch (index) {
        kIOFBSelectGetInfo => {
            if (p1 == 0) return types.kIOReturnBadArgument;
            var info: FbInfo = .{};
            const rc = framebufferGetInfo(uc, &info);
            if (rc != types.kIOReturnSuccess) return rc;
            if (!@import("../syscall/usercopy.zig").copyOut(FbInfo, p1, info)) return types.kIOReturnBadArgument;
            return types.kIOReturnSuccess;
        },
        kIOFBSelectPresent => return framebufferPresent(uc),
        else => return types.kIOReturnUnsupported,
    }
}
