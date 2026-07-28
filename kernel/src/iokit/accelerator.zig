//! Abstract IOAccelerator — command queues / fences (stubs for Prism later).

const types = @import("types.zig");
const service = @import("service.zig");

pub const CLASS_NAME = "IOAccelerator";

pub const IOAcceleratorVtable = struct {
    service: service.IOServiceVtable,
    submitCommands: *const fn (*IOAccelerator, [*]const u8, usize) types.IOReturn,
    waitFence: *const fn (*IOAccelerator, u64) types.IOReturn,
    signalFence: *const fn (*IOAccelerator, u64) types.IOReturn,
};

fn defaultSubmit(_: *IOAccelerator, _: [*]const u8, _: usize) types.IOReturn {
    return types.kIOReturnUnsupported;
}

fn defaultWaitFence(_: *IOAccelerator, _: u64) types.IOReturn {
    return types.kIOReturnUnsupported;
}

fn defaultSignalFence(_: *IOAccelerator, _: u64) types.IOReturn {
    return types.kIOReturnUnsupported;
}

pub const default_vtable = IOAcceleratorVtable{
    .service = service.default_vtable,
    .submitCommands = defaultSubmit,
    .waitFence = defaultWaitFence,
    .signalFence = defaultSignalFence,
};

pub const IOAccelerator = struct {
    service: service.IOService = .{},
    accel_vtable: *const IOAcceleratorVtable = &default_vtable,
    fence_value: u64 = 0,

    pub fn init(self: *IOAccelerator, vtable: *const IOAcceleratorVtable, name: []const u8) void {
        self.* = .{
            .accel_vtable = vtable,
        };
        self.service.init(CLASS_NAME, name, "");
        self.service.vtable = &vtable.service;
    }

    pub fn asService(self: *IOAccelerator) *service.IOService {
        return &self.service;
    }

    pub fn fromService(svc: *service.IOService) *IOAccelerator {
        return @fieldParentPtr("service", svc);
    }

    pub fn submitCommands(self: *IOAccelerator, cmds: [*]const u8, len: usize) types.IOReturn {
        return self.accel_vtable.submitCommands(self, cmds, len);
    }

    pub fn waitFence(self: *IOAccelerator, fence: u64) types.IOReturn {
        return self.accel_vtable.waitFence(self, fence);
    }

    pub fn signalFence(self: *IOAccelerator, fence: u64) types.IOReturn {
        return self.accel_vtable.signalFence(self, fence);
    }
};
