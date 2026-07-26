//! Abstract IOFramebuffer — display mode + VRAM aperture.

const types = @import("types.zig");
const service = @import("service.zig");

pub const CLASS_NAME = "IOFramebuffer";

pub const DisplayMode = struct {
    width: u32 = 0,
    height: u32 = 0,
    depth: u32 = 32,
};

pub const PixelInformation = struct {
    bytes_per_row: u32 = 0,
    bytes_per_pixel: u32 = 4,
    pixel_type: u32 = 0, // 0 = B8G8R8X8
};

pub const IOFramebufferVtable = struct {
    service: service.IOServiceVtable,
    getDisplayMode: *const fn (*IOFramebuffer, *DisplayMode) types.IOReturn,
    setDisplayMode: *const fn (*IOFramebuffer, DisplayMode) types.IOReturn,
    getAperture: *const fn (*IOFramebuffer, *u64, *u64) types.IOReturn,
    getPixelInformation: *const fn (*IOFramebuffer, *PixelInformation) types.IOReturn,
};

pub const IOFramebuffer = struct {
    service: service.IOService = .{},
    fb_vtable: *const IOFramebufferVtable,
    mode: DisplayMode = .{},
    aperture_base: u64 = 0,
    aperture_length: u64 = 0,
    pixels: PixelInformation = .{},

    pub fn init(self: *IOFramebuffer, vtable: *const IOFramebufferVtable, name: []const u8) void {
        self.* = .{
            .fb_vtable = vtable,
        };
        self.service.init(CLASS_NAME, name, "");
        self.service.vtable = &vtable.service;
    }

    pub fn asService(self: *IOFramebuffer) *service.IOService {
        return &self.service;
    }

    pub fn fromService(svc: *service.IOService) *IOFramebuffer {
        return @fieldParentPtr("service", svc);
    }

    pub fn getDisplayMode(self: *IOFramebuffer, out: *DisplayMode) types.IOReturn {
        return self.fb_vtable.getDisplayMode(self, out);
    }

    pub fn setDisplayMode(self: *IOFramebuffer, mode: DisplayMode) types.IOReturn {
        return self.fb_vtable.setDisplayMode(self, mode);
    }

    pub fn getAperture(self: *IOFramebuffer, base: *u64, len: *u64) types.IOReturn {
        return self.fb_vtable.getAperture(self, base, len);
    }

    pub fn getPixelInformation(self: *IOFramebuffer, out: *PixelInformation) types.IOReturn {
        return self.fb_vtable.getPixelInformation(self, out);
    }
};
