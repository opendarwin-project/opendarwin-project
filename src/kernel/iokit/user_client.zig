//! IOUserClient — userspace connection to an IOService (Darwin-shaped).

const types = @import("types.zig");
const service = @import("service.zig");
const framebuffer = @import("framebuffer.zig");
const iohid_system = @import("drivers/iohid_system.zig");
const virtio_gpu = @import("../drivers/virtio_gpu.zig");
const IpcPort = @import("../ipc/port.zig").IpcPort;
const slab = @import("../mm/slab.zig");

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
    next: ?*PortObject = null,
};

pub const IOUserClient = struct {
    service: *service.IOService,
    port: ?*IpcPort = null,
    /// True when this UC is an IOFramebuffer connection.
    is_framebuffer: bool = false,
    /// True when this UC is an IOHIDSystem connection.
    is_hid: bool = false,
};

var master_port_obj: PortObject = .{ .tag = .master };
var service_port_head: ?*PortObject = null;
var connect_port_head: ?*PortObject = null;

pub fn masterPortObject() *PortObject {
    return &master_port_obj;
}

pub fn bindServicePort(svc: *service.IOService, port: *IpcPort) *PortObject {
    var node = service_port_head;
    while (node) |obj| : (node = obj.next) {
        if (obj.tag == .service and obj.service == svc) {
            port.ip_kobject = obj;
            return obj;
        }
    }
    const obj = slab.allocObj(PortObject);
    obj.* = .{ .tag = .service, .service = svc, .next = service_port_head };
    service_port_head = obj;
    port.ip_kobject = obj;
    return obj;
}

pub fn open(svc: *service.IOService) ?*IOUserClient {
    const uc = slab.allocObj(IOUserClient);
    uc.* = .{
        .service = svc,
        .is_framebuffer = isFramebufferService(svc),
        .is_hid = isHidService(svc),
    };
    const po = slab.allocObj(PortObject);
    po.* = .{ .tag = .connect, .service = svc, .connect = uc, .next = connect_port_head };
    connect_port_head = po;
    return uc;
}

pub fn bindConnectPort(uc: *IOUserClient, port: *IpcPort) void {
    var node = connect_port_head;
    while (node) |obj| : (node = obj.next) {
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

fn isHidService(svc: *service.IOService) bool {
    const name = svc.getClassName();
    if (classEql(name, iohid_system.CLASS_NAME)) return true;
    if (classEql(name, "iohid-system")) return true;
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

/// IOConnectCallMethod selectors for IOHIDSystem connections.
pub const kIOHIDSelectGetPointState: u32 = 0;
pub const kIOHIDSelectPollEvents: u32 = 1;

pub const FbInfo = virtio_gpu.FbInfo;
pub const IOHIDPointState = iohid_system.IOHIDPointState;

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
/// Framebuffer:
///   Index 0: getInfo — p1 = user pointer to FbInfo
///   Index 1: present
/// HID:
///   Index 0: getPointState — p1 = user pointer to IOHIDPointState
///   Index 1: pollEvents
pub fn trap(uc: *IOUserClient, index: u32, p1: u64, p2: u64, p3: u64, p4: u64, p5: u64, p6: u64) types.IOReturn {
    _ = p2;
    _ = p3;
    _ = p4;
    _ = p5;
    _ = p6;
    if (uc.is_framebuffer) {
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
    } else if (uc.is_hid) {
        switch (index) {
            kIOHIDSelectGetPointState => {
                if (p1 == 0) return types.kIOReturnBadArgument;
                var state: IOHIDPointState = .{};
                const rc = iohid_system.getPointState(&state);
                if (rc != types.kIOReturnSuccess) return rc;
                if (!@import("../syscall/usercopy.zig").copyOut(IOHIDPointState, p1, state)) return types.kIOReturnBadArgument;
                return types.kIOReturnSuccess;
            },
            kIOHIDSelectPollEvents => return iohid_system.pollEvents(),
            else => return types.kIOReturnUnsupported,
        }
    }
    return types.kIOReturnUnsupported;
}
