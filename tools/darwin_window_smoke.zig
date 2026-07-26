//! Dynamic AppKit window smoke test.  This intentionally uses std.DynLib and
//! Objective-C runtime symbols instead of linkSystemLibrary/framework linkage.
//!
//! Run from the repository root with:
//!   zig build run-darwin-window

const std = @import("std");
const prism = @import("prism");

const Id = *anyopaque;
const Class = *anyopaque;
const SEL = *anyopaque;

const CGPoint = extern struct { x: f64, y: f64 };
const CGSize = extern struct { width: f64, height: f64 };
const CGRect = extern struct { origin: CGPoint, size: CGSize };

const NSApplicationActivationPolicyRegular: isize = 0;
const NSBackingStoreBuffered: isize = 2;
const NSWindowStyleMaskTitled: usize = 1 << 0;
const NSWindowStyleMaskClosable: usize = 1 << 1;
const NSWindowStyleMaskMiniaturizable: usize = 1 << 2;
const NSWindowStyleMaskResizable: usize = 1 << 3;
const NSBitmapFormatAlphaNonpremultiplied: usize = 1 << 1;

fn flipRows(pixels: []u8, width: usize, height: usize) void {
    const stride = width * 4;
    var scratch: [4096 * 4]u8 = undefined;
    std.debug.assert(stride <= scratch.len);
    for (0..height / 2) |top| {
        const bottom = height - 1 - top;
        const a = pixels[top * stride ..][0..stride];
        const b = pixels[bottom * stride ..][0..stride];
        @memcpy(scratch[0..stride], a);
        @memcpy(a, b);
        @memcpy(b, scratch[0..stride]);
    }
}

const Vtx = extern struct { x: f32, y: f32, r: f32, g: f32, b: f32 };

const tri = [3]Vtx{
    .{ .x = -0.8, .y = -0.75, .r = 1, .g = 0, .b = 0 },
    .{ .x = 0.8, .y = -0.75, .r = 0, .g = 1, .b = 0 },
    .{ .x = 0.0, .y = 0.8, .r = 0, .g = 0, .b = 1 },
};

const vs_src =
    \\attribute vec2 aPos;
    \\attribute vec3 aColor;
    \\varying vec3 vColor;
    \\void main() { gl_Position = vec4(aPos, 0.0, 1.0); vColor = aColor; }
;
const fs_src =
    \\precision mediump float;
    \\varying vec3 vColor;
    \\void main() { gl_FragColor = vec4(vColor, 1.0); }
;

fn attrFormat(n: u8) prism.hal.Format {
    return switch (n) {
        2 => .r32g32_float,
        3 => .r32g32b32_float,
        else => .r32g32b32a32_float,
    };
}

fn attrOffset(name: []const u8) u32 {
    return if (std.mem.eql(u8, name, "aPos")) 0 else 8;
}

const PixelSurface = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    stride: u32,

    fn currentBuffer(ptr: *anyopaque) prism.hal.Error!prism.platform.Buffer {
        const self: *PixelSurface = @ptrCast(@alignCast(ptr));
        return .{
            .bytes = self.pixels,
            .width = self.width,
            .height = self.height,
            .stride = self.stride,
            .format = .rgba8_unorm,
        };
    }

    fn commit(ptr: *anyopaque) prism.hal.Error!void {
        _ = ptr;
    }

    fn processEvents(ptr: *anyopaque) prism.hal.Error!prism.platform.WindowEvent {
        _ = ptr;
        return .none;
    }

    fn size(ptr: *anyopaque) [2]u32 {
        const self: *PixelSurface = @ptrCast(@alignCast(ptr));
        return .{ self.width, self.height };
    }

    fn deinit(ptr: *anyopaque) void {
        _ = ptr;
    }

    const vtable = prism.platform.Surface.VTable{
        .currentBuffer = &currentBuffer,
        .commit = &commit,
        .processEvents = &processEvents,
        .size = &size,
        .deinit = &deinit,
    };
};

fn renderPrismTriangle(gpa: std.mem.Allocator, pixels: []u8, width: u32, height: u32, stride: u32) !void {
    var cvs = try prism.glsl.compileForStageWithLayout(gpa, vs_src, .vertex);
    defer cvs.deinit(gpa);
    const fs_spirv = try prism.glsl.compileForStage(gpa, fs_src, .fragment);
    defer gpa.free(fs_spirv);

    const device = try prism.drivers.software.driver.createDevice(gpa);
    defer device.deinit();

    const vbuf = try device.createResource(.{ .buffer = .{ .size = @sizeOf(@TypeOf(tri)), .usage = .{ .vertex = true } } });
    defer device.destroyResource(vbuf);
    @memcpy(try device.mapResource(vbuf), std.mem.asBytes(&tri));

    const vs = try device.createShaderModule(.{ .stage = .vertex, .code = cvs.spirv });
    defer device.destroyShaderModule(vs);
    const fs = try device.createShaderModule(.{ .stage = .fragment, .code = fs_spirv });
    defer device.destroyShaderModule(fs);

    var attrs: [4]prism.hal.VertexAttribute = undefined;
    for (cvs.attributes, 0..) |a, i| {
        attrs[i] = .{ .location = a.location, .format = attrFormat(a.components), .offset = attrOffset(a.name) };
    }

    const pipeline = try device.createPipeline(.{
        .vertex = vs,
        .fragment = fs,
        .vertex_layout = .{ .stride = @sizeOf(Vtx), .attributes = attrs[0..cvs.attributes.len] },
        .color_format = .rgba8_unorm,
    });
    defer device.destroyPipeline(pipeline);

    const ctx = try device.createContext();
    defer ctx.deinit();

    const target = try device.createResource(.{ .image = .{
        .width = width,
        .height = height,
        .format = .rgba8_unorm,
        .usage = .{ .render_target = true },
    } });
    defer device.destroyResource(target);

    const cb = try ctx.beginCommands();
    defer cb.deinit();
    try cb.setRenderTarget(target);
    try cb.clear(.{ .r = 0.04, .g = 0.04, .b = 0.06, .a = 1 });
    try cb.bindPipeline(pipeline);
    try cb.bindVertexBuffer(vbuf);
    try cb.draw(3, 0);
    try ctx.submit(cb);

    var pixel_surface = PixelSurface{
        .pixels = pixels,
        .width = width,
        .height = height,
        .stride = stride,
    };
    var plat_surface = prism.platform.Surface{ .ptr = &pixel_surface, .vtable = &PixelSurface.vtable };
    const hal_surface = try device.createSurface(@ptrCast(&plat_surface));
    defer device.destroySurface(hal_surface);
    try ctx.present(hal_surface, target);
}

const Objc = struct {
    libobjc: std.DynLib,
    appkit: std.DynLib,
    objc_getClass: *const fn ([*:0]const u8) callconv(.c) ?Class,
    sel_registerName: *const fn ([*:0]const u8) callconv(.c) SEL,
    msgSend: *const anyopaque,

    fn load() !Objc {
        var libobjc = try std.DynLib.openZ("/usr/lib/libobjc.A.dylib");
        errdefer libobjc.close();
        var appkit = try std.DynLib.openZ("/System/Library/Frameworks/AppKit.framework/AppKit");
        errdefer appkit.close();

        return .{
            .libobjc = libobjc,
            .appkit = appkit,
            .objc_getClass = libobjc.lookup(*const fn ([*:0]const u8) callconv(.c) ?Class, "objc_getClass") orelse return error.MissingObjcSymbol,
            .sel_registerName = libobjc.lookup(*const fn ([*:0]const u8) callconv(.c) SEL, "sel_registerName") orelse return error.MissingObjcSymbol,
            .msgSend = libobjc.lookup(*const anyopaque, "objc_msgSend") orelse return error.MissingObjcSymbol,
        };
    }

    fn close(self: *Objc) void {
        self.appkit.close();
        self.libobjc.close();
    }

    fn cls(self: *const Objc, name: [*:0]const u8) !Class {
        return self.objc_getClass(name) orelse error.MissingObjcClass;
    }

    fn sel(self: *const Objc, name: [*:0]const u8) SEL {
        return self.sel_registerName(name);
    }

    fn send0(self: *const Objc, receiver: anytype, selector: SEL) Id {
        const Fn = *const fn (@TypeOf(receiver), SEL) callconv(.c) Id;
        return (@as(Fn, @ptrCast(@alignCast(self.msgSend))))(receiver, selector);
    }

    fn sendBool(self: *const Objc, receiver: anytype, selector: SEL, value: bool) void {
        const Fn = *const fn (@TypeOf(receiver), SEL, bool) callconv(.c) void;
        return (@as(Fn, @ptrCast(@alignCast(self.msgSend))))(receiver, selector, value);
    }

    fn sendIsize(self: *const Objc, receiver: anytype, selector: SEL, value: isize) void {
        const Fn = *const fn (@TypeOf(receiver), SEL, isize) callconv(.c) void;
        return (@as(Fn, @ptrCast(@alignCast(self.msgSend))))(receiver, selector, value);
    }

    fn sendPtr(self: *const Objc, receiver: anytype, selector: SEL, value: Id) void {
        const Fn = *const fn (@TypeOf(receiver), SEL, Id) callconv(.c) void;
        return (@as(Fn, @ptrCast(@alignCast(self.msgSend))))(receiver, selector, value);
    }

    fn sendCString(self: *const Objc, receiver: anytype, selector: SEL, value: [*:0]const u8) Id {
        const Fn = *const fn (@TypeOf(receiver), SEL, [*:0]const u8) callconv(.c) Id;
        return (@as(Fn, @ptrCast(@alignCast(self.msgSend))))(receiver, selector, value);
    }

    fn sendInitImageView(self: *const Objc, receiver: Id, selector: SEL, rect: CGRect) Id {
        const Fn = *const fn (Id, SEL, CGRect) callconv(.c) Id;
        return (@as(Fn, @ptrCast(@alignCast(self.msgSend))))(receiver, selector, rect);
    }

    fn sendInitImage(self: *const Objc, receiver: Id, selector: SEL, size: CGSize) Id {
        const Fn = *const fn (Id, SEL, CGSize) callconv(.c) Id;
        return (@as(Fn, @ptrCast(@alignCast(self.msgSend))))(receiver, selector, size);
    }

    fn sendBitmapRep(
        self: *const Objc,
        receiver: Id,
        selector: SEL,
        planes: *[5]?[*]u8,
        width: isize,
        height: isize,
        bits_per_sample: isize,
        samples_per_pixel: isize,
        has_alpha: bool,
        is_planar: bool,
        color_space: Id,
        bitmap_format: usize,
        bytes_per_row: isize,
        bits_per_pixel: isize,
    ) Id {
        const Fn = *const fn (Id, SEL, *[5]?[*]u8, isize, isize, isize, isize, bool, bool, Id, usize, isize, isize) callconv(.c) Id;
        return (@as(Fn, @ptrCast(@alignCast(self.msgSend))))(
            receiver,
            selector,
            planes,
            width,
            height,
            bits_per_sample,
            samples_per_pixel,
            has_alpha,
            is_planar,
            color_space,
            bitmap_format,
            bytes_per_row,
            bits_per_pixel,
        );
    }

    fn sendInitWindow(
        self: *const Objc,
        receiver: Id,
        selector: SEL,
        rect: CGRect,
        style: usize,
        backing: isize,
        defer_flag: bool,
    ) Id {
        const Fn = *const fn (Id, SEL, CGRect, usize, isize, bool) callconv(.c) Id;
        return (@as(Fn, @ptrCast(@alignCast(self.msgSend))))(receiver, selector, rect, style, backing, defer_flag);
    }
};

fn nsString(objc: *const Objc, bytes: [*:0]const u8) !Id {
    const NSString = try objc.cls("NSString");
    return objc.sendCString(NSString, objc.sel("stringWithUTF8String:"), bytes);
}

pub fn main() !void {
    if (@import("builtin").target.os.tag != .macos) return error.UnsupportedOS;

    var objc = try Objc.load();
    defer objc.close();

    const Pool = try objc.cls("NSAutoreleasePool");
    const pool = objc.send0(objc.send0(Pool, objc.sel("alloc")), objc.sel("init"));
    defer _ = objc.send0(pool, objc.sel("drain"));

    const NSApplication = try objc.cls("NSApplication");
    const app = objc.send0(NSApplication, objc.sel("sharedApplication"));
    objc.sendIsize(app, objc.sel("setActivationPolicy:"), NSApplicationActivationPolicyRegular);

    const NSWindow = try objc.cls("NSWindow");
    const style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    const rect = CGRect{ .origin = .{ .x = 200, .y = 200 }, .size = .{ .width = 640, .height = 360 } };
    const window = objc.sendInitWindow(
        objc.send0(NSWindow, objc.sel("alloc")),
        objc.sel("initWithContentRect:styleMask:backing:defer:"),
        rect,
        style,
        NSBackingStoreBuffered,
        false,
    );

    const title = try nsString(&objc, "Prism Darwin DynLib smoke");
    objc.sendPtr(window, objc.sel("setTitle:"), title);

    const image_w: usize = 640;
    const image_h: usize = 360;
    const stride = image_w * 4;
    const pixels = try std.heap.page_allocator.alloc(u8, stride * image_h);
    defer std.heap.page_allocator.free(pixels);
    try renderPrismTriangle(std.heap.page_allocator, pixels, @intCast(image_w), @intCast(image_h), @intCast(stride));
    flipRows(pixels, image_w, image_h);

    var planes = [_]?[*]u8{ pixels.ptr, null, null, null, null };
    const NSBitmapImageRep = try objc.cls("NSBitmapImageRep");
    const color_space = try nsString(&objc, "NSDeviceRGBColorSpace");
    const rep = objc.sendBitmapRep(
        objc.send0(NSBitmapImageRep, objc.sel("alloc")),
        objc.sel("initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bitmapFormat:bytesPerRow:bitsPerPixel:"),
        &planes,
        @intCast(image_w),
        @intCast(image_h),
        8,
        4,
        true,
        false,
        color_space,
        NSBitmapFormatAlphaNonpremultiplied,
        @intCast(stride),
        32,
    );

    const NSImage = try objc.cls("NSImage");
    const image = objc.sendInitImage(objc.send0(NSImage, objc.sel("alloc")), objc.sel("initWithSize:"), rect.size);
    objc.sendPtr(image, objc.sel("addRepresentation:"), rep);

    const NSImageView = try objc.cls("NSImageView");
    const view = objc.sendInitImageView(objc.send0(NSImageView, objc.sel("alloc")), objc.sel("initWithFrame:"), CGRect{ .origin = .{ .x = 0, .y = 0 }, .size = rect.size });
    objc.sendPtr(view, objc.sel("setImage:"), image);
    objc.sendPtr(window, objc.sel("setContentView:"), view);

    objc.sendPtr(window, objc.sel("makeKeyAndOrderFront:"), app);
    objc.sendBool(app, objc.sel("activateIgnoringOtherApps:"), true);

    std.debug.print("darwin-window-smoke: opened AppKit via std.DynLib with a Prism software-rendered triangle; close the window or Ctrl-C to exit\n", .{});
    _ = objc.send0(app, objc.sel("run"));
}
