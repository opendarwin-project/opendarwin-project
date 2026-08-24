//! SkyLight / CoreGraphics-Services (CGS) reimplementation for OpenDarwin
//! userland.
//!
//! On macOS the CGS* entry points in
//! /System/Library/PrivateFrameworks/SkyLight.framework/SkyLight are thin
//! Mach-RPC stubs onto the WindowServer process, which owns the IOFramebuffer
//! UserClient and does the compositing.  OpenDarwin has no WindowServer yet,
//! so this library *is* both halves:
//!
//!   client  ─ CGS* exports below (same names/ABI the real stubs use, so
//!             std.DynLib-based consumers such as Prism's
//!             platform/darwin.zig or tools/darwin_window_smoke.zig can bind
//!             to us unchanged)
//!   server  ─ src/skylight/compositor.zig, flattening window backing stores
//!             into the IOFramebuffer aperture obtained through IOKitLib
//!             (IOFramebufferOpenDefault + IOConnectMapMemory +
//!             IOFramebufferPresent, i.e. exactly what fb_smoke.zig does by
//!             hand today).
//!
//! Everything runs in the calling process, which is a lie the API cannot
//! observe: connection IDs are still opaque, windows are still server-side
//! objects, and CGSFlushWindow still ends in a scanout present.  Splitting the
//! server into its own task behind Mach RPC is a later step (see TODO.md);
//! the compositor core is already written to make that mechanical.

const compositor = @import("compositor.zig");

pub const CGError = i32;
pub const kCGErrorSuccess: CGError = 0;
pub const kCGErrorFailure: CGError = 1000;
pub const kCGErrorIllegalArgument: CGError = 1001;
pub const kCGErrorInvalidConnection: CGError = 1002;
pub const kCGErrorNoneAvailable: CGError = 1011;

pub const CGSConnectionID = u32;
pub const CGSWindowID = u32;
pub const CGSRegionRef = ?*anyopaque;
pub const CFStringRef = ?*anyopaque;
pub const CFTypeRef = ?*anyopaque;
pub const CGDirectDisplayID = u32;

pub const CGPoint = extern struct { x: f64 = 0, y: f64 = 0 };
pub const CGSize = extern struct { width: f64 = 0, height: f64 = 0 };
pub const CGRect = extern struct { origin: CGPoint = .{}, size: CGSize = .{} };

// CGSWindowType (CGSNewWindow's second argument).
pub const kCGSBackingNonRetained: i32 = 0;
pub const kCGSBackingRetained: i32 = 1;
pub const kCGSBackingBuffered: i32 = 2;

const io_connect_t = u32;
const kern_return_t = i32;

const IOFramebufferInfo = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    format: u32 = 0,
    size: u64 = 0,
};

const IOHIDPointState = extern struct {
    x: u32 = 0,
    y: u32 = 0,
    max_x: u32 = 32767,
    max_y: u32 = 32767,
    rel_dx: i32 = 0,
    rel_dy: i32 = 0,
    buttons: u32 = 0,
    device_type: u32 = 0,
    abs_updated: u32 = 0,
};

extern fn IOFramebufferOpenDefault(connect_out: *io_connect_t, info_out: ?*IOFramebufferInfo) kern_return_t;
extern fn IOConnectMapMemory(connect: io_connect_t, memoryType: u32, intoTask: u32, atAddress: *u64, ofSize: *u64, options: u32) kern_return_t;
extern fn IOFramebufferPresent(connect: io_connect_t) kern_return_t;
extern fn IOHIDSystemOpenDefault(connect_out: *io_connect_t) kern_return_t;
extern fn IOHIDGetPointState(connect: io_connect_t, state: *IOHIDPointState) kern_return_t;
extern fn IOHIDPollEvents(connect: io_connect_t) kern_return_t;
extern fn IOServiceClose(connect: io_connect_t) kern_return_t;
extern fn mach_task_self() u32;
extern fn malloc(size: usize) ?*anyopaque;
extern fn free(ptr: ?*anyopaque) void;

// ---------------------------------------------------------------------------
// Server state
// ---------------------------------------------------------------------------

const Server = struct {
    cg: compositor.Compositor = .{},
    scanout: ?compositor.Surface = null,
    connect: io_connect_t = 0,
    fb_open: bool = false,
    fb_failed: bool = false,
    hid_connect: io_connect_t = 0,
    hid_open: bool = false,
    hid_failed: bool = false,
    cursor_pos: CGPoint = .{ .x = 100, .y = 100 },
    cursor_visible: bool = true,
    buttons: u32 = 0,
    dirty: bool = true,
    /// Headless fallback surface used when no IOFramebuffer is published, so
    /// clients can still render and be composited (mirrors Prism's headless
    /// Darwin display).
    headless: bool = false,
};

var server: Server = .{};

/// Opens the IOFramebuffer UserClient and maps its aperture once, lazily: a
/// process that only creates windows never needs scanout.
fn ensureScanout() bool {
    if (server.scanout != null) return true;
    if (server.fb_failed) return false;

    var connect: io_connect_t = 0;
    var info: IOFramebufferInfo = .{};
    if (IOFramebufferOpenDefault(&connect, &info) != 0 or info.width == 0 or info.stride == 0) {
        server.fb_failed = true;
        return false;
    }
    var addr: u64 = 0;
    var size: u64 = 0;
    if (IOConnectMapMemory(connect, 0, mach_task_self(), &addr, &size, 0) != 0 or addr == 0) {
        _ = IOServiceClose(connect);
        server.fb_failed = true;
        return false;
    }
    const len: usize = if (size != 0) @intCast(size) else @as(usize, info.stride) * info.height;
    server.connect = connect;
    server.fb_open = true;
    server.scanout = .{
        .bytes = @as([*]u8, @ptrFromInt(addr))[0..len],
        .width = info.width,
        .height = info.height,
        .stride = info.stride,
        .order = .bgra,
    };
    return true;
}

fn ensureHid() bool {
    if (server.hid_open) return true;
    if (server.hid_failed) return false;
    var connect: io_connect_t = 0;
    if (IOHIDSystemOpenDefault(&connect) != 0 or connect == 0) {
        server.hid_failed = true;
        return false;
    }
    server.hid_connect = connect;
    server.hid_open = true;
    return true;
}

fn updateCursorFromHid() bool {
    if (!ensureHid()) return false;
    _ = IOHIDPollEvents(server.hid_connect);
    var state: IOHIDPointState = .{};
    if (IOHIDGetPointState(server.hid_connect, &state) != 0) return false;

    var changed = false;
    if (server.scanout) |s| {
        if (state.abs_updated != 0) {
            const max_x = if (state.max_x > 0) state.max_x else 32767;
            const max_y = if (state.max_y > 0) state.max_y else 32767;
            const new_x = (@as(f64, @floatFromInt(state.x)) * @as(f64, @floatFromInt(s.width))) / @as(f64, @floatFromInt(max_x));
            const new_y = (@as(f64, @floatFromInt(state.y)) * @as(f64, @floatFromInt(s.height))) / @as(f64, @floatFromInt(max_y));
            if (new_x != server.cursor_pos.x or new_y != server.cursor_pos.y) {
                server.cursor_pos.x = new_x;
                server.cursor_pos.y = new_y;
                changed = true;
            }
        }
        if (state.rel_dx != 0 or state.rel_dy != 0) {
            const new_x = @max(0.0, @min(@as(f64, @floatFromInt(s.width - 1)), server.cursor_pos.x + @as(f64, @floatFromInt(state.rel_dx))));
            const new_y = @max(0.0, @min(@as(f64, @floatFromInt(s.height - 1)), server.cursor_pos.y + @as(f64, @floatFromInt(state.rel_dy))));
            if (new_x != server.cursor_pos.x or new_y != server.cursor_pos.y) {
                server.cursor_pos.x = new_x;
                server.cursor_pos.y = new_y;
                changed = true;
            }
        }
    }
    if (server.buttons != state.buttons) {
        server.buttons = state.buttons;
        changed = true;
    }
    return changed;
}

fn presentScanout() CGError {
    if (!server.fb_open) return kCGErrorSuccess;
    return if (IOFramebufferPresent(server.connect) == 0) kCGErrorSuccess else kCGErrorFailure;
}

// ---------------------------------------------------------------------------
// Connections
// ---------------------------------------------------------------------------

var main_connection: CGSConnectionID = 0;

pub export fn CGSNewConnection(callback: ?*const anyopaque, connection: *CGSConnectionID) callconv(.c) CGError {
    _ = callback; // Apple's unused first parameter.
    connection.* = server.cg.newConnection();
    if (main_connection == 0) main_connection = connection.*;
    return kCGErrorSuccess;
}

pub export fn CGSMainConnectionID() callconv(.c) CGSConnectionID {
    if (main_connection == 0) {
        var cid: CGSConnectionID = 0;
        _ = CGSNewConnection(null, &cid);
    }
    return main_connection;
}

pub export fn CGSReleaseConnection(connection: CGSConnectionID) callconv(.c) CGError {
    server.cg.releaseConnection(connection);
    if (connection == main_connection) main_connection = 0;
    return kCGErrorSuccess;
}

// ---------------------------------------------------------------------------
// Regions
// ---------------------------------------------------------------------------

const Region = extern struct {
    magic: u32 = 0x5247_4e52, // 'RGNR'
    rect: compositor.Rect = .{},
};

pub export fn CGSNewRegionWithRect(rect: *const CGRect, region: *CGSRegionRef) callconv(.c) CGError {
    const raw = malloc(@sizeOf(Region)) orelse return kCGErrorNoneAvailable;
    const r: *Region = @ptrCast(@alignCast(raw));
    r.* = .{ .rect = .{
        .x = @intFromFloat(rect.origin.x),
        .y = @intFromFloat(rect.origin.y),
        .width = @intFromFloat(rect.size.width),
        .height = @intFromFloat(rect.size.height),
    } };
    region.* = raw;
    return kCGErrorSuccess;
}

pub export fn CGSReleaseRegion(region: CGSRegionRef) callconv(.c) CGError {
    free(region);
    return kCGErrorSuccess;
}

fn regionRect(region: CGSRegionRef) ?compositor.Rect {
    const raw = region orelse return null;
    const r: *const Region = @ptrCast(@alignCast(raw));
    if (r.magic != 0x5247_4e52) return null;
    return r.rect;
}

// ---------------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------------

fn allocBacking(w: *compositor.Window) bool {
    const stride: u32 = @intCast(w.bounds.width * 4);
    const bytes: usize = stride * @as(usize, @intCast(w.bounds.height));
    const raw = malloc(bytes) orelse return false;
    const p: [*]u8 = @ptrCast(raw);
    @memset(p[0..bytes], 0);
    w.backing = p[0..bytes];
    w.backing_stride = stride;
    w.backing_order = .bgra;
    return true;
}

pub export fn CGSNewWindow(
    connection: CGSConnectionID,
    window_type: i32,
    x: f32,
    y: f32,
    region: CGSRegionRef,
    window: *CGSWindowID,
) callconv(.c) CGError {
    _ = window_type;
    const shape = regionRect(region) orelse return kCGErrorIllegalArgument;
    if (shape.width <= 0 or shape.height <= 0) return kCGErrorIllegalArgument;

    const w = server.cg.newWindow(connection, .{
        .x = @intFromFloat(x),
        .y = @intFromFloat(y),
        .width = shape.width,
        .height = shape.height,
    }) orelse return kCGErrorNoneAvailable;
    if (!allocBacking(w)) {
        _ = server.cg.releaseWindow(w.wid);
        return kCGErrorNoneAvailable;
    }
    window.* = w.wid;
    return kCGErrorSuccess;
}

/// Apple's variant taking an extra opaque-shape region; the opaque shape is
/// only an optimisation hint for the compositor, so we ignore it.
pub export fn CGSNewWindowWithOpaqueShape(
    connection: CGSConnectionID,
    window_type: i32,
    x: f32,
    y: f32,
    region: CGSRegionRef,
    opaque_shape: CGSRegionRef,
    unknown1: i32,
    unknown2: ?*anyopaque,
    unknown3: i32,
    window: *CGSWindowID,
) callconv(.c) CGError {
    _ = .{ opaque_shape, unknown1, unknown2, unknown3 };
    return CGSNewWindow(connection, window_type, x, y, region, window);
}

pub export fn CGSReleaseWindow(connection: CGSConnectionID, window: CGSWindowID) callconv(.c) CGError {
    const w = server.cg.find(window) orelse return kCGErrorIllegalArgument;
    if (w.cid != connection) return kCGErrorInvalidConnection;
    if (w.backing) |b| free(b.ptr);
    _ = server.cg.releaseWindow(window);
    return kCGErrorSuccess;
}

pub export fn CGSOrderWindow(
    connection: CGSConnectionID,
    window: CGSWindowID,
    mode: i32,
    relative_to: CGSWindowID,
) callconv(.c) CGError {
    _ = .{ connection, relative_to };
    return if (server.cg.orderWindow(window, mode)) kCGErrorSuccess else kCGErrorIllegalArgument;
}

pub export fn CGSMoveWindow(connection: CGSConnectionID, window: CGSWindowID, point: *const CGPoint) callconv(.c) CGError {
    _ = connection;
    const ok = server.cg.moveWindow(window, @intFromFloat(point.x), @intFromFloat(point.y));
    return if (ok) kCGErrorSuccess else kCGErrorIllegalArgument;
}

pub export fn CGSSetWindowLevel(connection: CGSConnectionID, window: CGSWindowID, level: i32) callconv(.c) CGError {
    _ = connection;
    const w = server.cg.find(window) orelse return kCGErrorIllegalArgument;
    w.level = level;
    return kCGErrorSuccess;
}

pub export fn CGSSetWindowAlpha(connection: CGSConnectionID, window: CGSWindowID, alpha: f32) callconv(.c) CGError {
    _ = connection;
    const w = server.cg.find(window) orelse return kCGErrorIllegalArgument;
    w.alpha = alpha;
    return kCGErrorSuccess;
}

/// Sets the window's title string property (calls through to
/// CGSSetWindowProperty with kCGSWindowTitle).
pub export fn CGSSetWindowTitle(connection: CGSConnectionID, window: CGSWindowID, title: [*:0]const u8) callconv(.c) CGError {
    _ = connection;
    var n: usize = 0;
    while (title[n] != 0) : (n += 1) {}
    return if (server.cg.setTitle(window, title[0..n])) kCGErrorSuccess else kCGErrorIllegalArgument;
}

/// CFString-shaped property setter kept for source compatibility.  Without
/// CoreFoundation we can only accept the values we ourselves hand out, so any
/// property other than a title-shaped C string is accepted and dropped.
pub export fn CGSSetWindowProperty(
    connection: CGSConnectionID,
    window: CGSWindowID,
    key: CFStringRef,
    value: CFTypeRef,
) callconv(.c) CGError {
    _ = key;
    const v = value orelse return kCGErrorIllegalArgument;
    return CGSSetWindowTitle(connection, window, @ptrCast(v));
}

pub export fn CGSGetWindowBounds(connection: CGSConnectionID, window: CGSWindowID, rect: *CGRect) callconv(.c) CGError {
    _ = connection;
    const w = server.cg.find(window) orelse return kCGErrorIllegalArgument;
    const f = w.frame();
    rect.* = .{
        .origin = .{ .x = @floatFromInt(f.x), .y = @floatFromInt(f.y) },
        .size = .{ .width = @floatFromInt(f.width), .height = @floatFromInt(f.height) },
    };
    return kCGErrorSuccess;
}

/// Locks the window's backing store for drawing, providing direct access to the
/// base address and row bytes (stride).
pub export fn CGSLockWindowBits(
    connection: CGSConnectionID,
    window: CGSWindowID,
    bounds_out: ?*CGRect,
    token_out: ?*i32,
    base_out: [*]?[*]u8,
    rowBytes_out: [*]i32,
) callconv(.c) CGError {
    _ = connection;
    const w = server.cg.find(window) orelse return kCGErrorIllegalArgument;
    const b = w.backing orelse return kCGErrorFailure;
    if (bounds_out) |r| {
        const f = w.frame();
        r.* = .{
            .origin = .{ .x = @floatFromInt(f.x), .y = @floatFromInt(f.y) },
            .size = .{ .width = @floatFromInt(f.width), .height = @floatFromInt(f.height) },
        };
    }
    if (token_out) |t| t.* = 0;
    base_out[0] = b.ptr;
    base_out[1] = null;
    rowBytes_out[0] = @intCast(w.backing_stride);
    rowBytes_out[1] = 0;
    return kCGErrorSuccess;
}

pub export fn CGSLockWindowRectBits(
    connection: CGSConnectionID,
    window: CGSWindowID,
    bounds_out: ?*CGRect,
    token_out: ?*i32,
    clip_rect: ?*const CGRect,
    reserved: i32,
    base_out: [*]?[*]u8,
    rowBytes_out: [*]i32,
) callconv(.c) CGError {
    _ = .{ clip_rect, reserved };
    return CGSLockWindowBits(connection, window, bounds_out, token_out, base_out, rowBytes_out);
}

pub export fn CGSUnlockWindowBits(
    connection: CGSConnectionID,
    window: CGSWindowID,
    damage_region: CGSRegionRef,
) callconv(.c) CGError {
    _ = .{ connection, window, damage_region };
    return kCGErrorSuccess;
}

pub export fn CGSUnlockWindowRectBits(
    connection: CGSConnectionID,
    window: CGSWindowID,
    damage_rect: ?*const CGRect,
) callconv(.c) CGError {
    _ = .{ connection, window, damage_rect };
    return kCGErrorSuccess;
}

pub export fn CGSSetWindowTags(
    connection: CGSConnectionID,
    window: CGSWindowID,
    tags: *const [2]u32,
    max_tag_size: usize,
) callconv(.c) CGError {
    _ = .{ connection, max_tag_size };
    const w = server.cg.find(window) orelse return kCGErrorIllegalArgument;
    if (tags[0] & 1 != 0) {
        w.decorated = true;
    }
    return kCGErrorSuccess;
}

pub export fn CGSClearWindowTags(
    connection: CGSConnectionID,
    window: CGSWindowID,
    tags: *const [2]u32,
    max_tag_size: usize,
) callconv(.c) CGError {
    _ = .{ connection, max_tag_size };
    const w = server.cg.find(window) orelse return kCGErrorIllegalArgument;
    if (tags[0] & 1 != 0) {
        w.decorated = false;
    }
    return kCGErrorSuccess;
}

pub export fn CGSGetWindowTags(
    connection: CGSConnectionID,
    window: CGSWindowID,
    tags: *[2]u32,
    max_tag_size: usize,
) callconv(.c) CGError {
    _ = .{ connection, max_tag_size };
    const w = server.cg.find(window) orelse return kCGErrorIllegalArgument;
    tags[0] = if (w.decorated) 1 else 0;
    tags[1] = 0;
    return kCGErrorSuccess;
}

// ---------------------------------------------------------------------------
// Flush / compositing
// ---------------------------------------------------------------------------

pub export fn CGSFlushWindow(connection: CGSConnectionID, window: CGSWindowID, region: CGSRegionRef) callconv(.c) CGError {
    _ = .{ window, region }; // Damage tracking is a later optimisation.
    return CGSFlushConnection(connection);
}

/// Composite every ordered-in window and scan the result out.
pub export fn CGSFlushConnection(connection: CGSConnectionID) callconv(.c) CGError {
    _ = connection;
    if (!ensureScanout()) return kCGErrorNoneAvailable;
    const hid_changed = updateCursorFromHid();
    if (!server.dirty and !hid_changed) return kCGErrorSuccess;
    server.dirty = false;
    _ = server.cg.composite(server.scanout.?);
    if (server.cursor_visible) {
        compositor.drawCursor(
            server.scanout.?,
            @intFromFloat(server.cursor_pos.x),
            @intFromFloat(server.cursor_pos.y),
        );
    }
    return presentScanout();
}

/// Apple's per-transaction batching entry points.  We composite on flush, so
/// these only need to exist for callers that bracket their drawing.
pub export fn CGSDisableUpdate(connection: CGSConnectionID) callconv(.c) CGError {
    _ = connection;
    return kCGErrorSuccess;
}

pub export fn CGSReenableUpdate(connection: CGSConnectionID) callconv(.c) CGError {
    return CGSFlushConnection(connection);
}

// ---------------------------------------------------------------------------
// Displays
// ---------------------------------------------------------------------------

pub export fn CGSMainDisplayID() callconv(.c) CGDirectDisplayID {
    return 1;
}

pub export fn CGSGetDisplayBounds(display: CGDirectDisplayID, rect: *CGRect) callconv(.c) CGError {
    _ = display;
    if (!ensureScanout()) return kCGErrorNoneAvailable;
    const s = server.scanout.?;
    rect.* = .{ .size = .{ .width = @floatFromInt(s.width), .height = @floatFromInt(s.height) } };
    return kCGErrorSuccess;
}

pub export fn CGSGetScreenRectForWindow(connection: CGSConnectionID, window: CGSWindowID, rect: *CGRect) callconv(.c) CGError {
    return CGSGetWindowBounds(connection, window, rect);
}

/// Find the topmost window under a given screen point.
pub export fn CGSFindWindowByGeometry(
    cid: CGSConnectionID,
    zero1: i32,
    zero2: i32,
    zero3: i32,
    screen_point: *const CGPoint,
    local_point_out: ?*CGPoint,
    window_out: *CGSWindowID,
    connection_out: ?*CGSConnectionID,
) callconv(.c) CGError {
    _ = .{ cid, zero1, zero2, zero3 };
    const px: i32 = @intFromFloat(screen_point.x);
    const py: i32 = @intFromFloat(screen_point.y);
    const hit = server.cg.hitTest(px, py) orelse return kCGErrorFailure;
    window_out.* = hit.wid;
    if (connection_out) |c| c.* = hit.cid;
    if (local_point_out) |lp| {
        const f = hit.frame();
        lp.* = .{
            .x = screen_point.x - @as(f64, @floatFromInt(f.x)),
            .y = screen_point.y - @as(f64, @floatFromInt(f.y)),
        };
    }
    return kCGErrorSuccess;
}

pub export fn CGSFindWindow(
    cid: CGSConnectionID,
    zero1: i32,
    zero2: i32,
    screen_point: *const CGPoint,
    local_point_out: ?*CGPoint,
    window_out: *CGSWindowID,
) callconv(.c) CGError {
    return CGSFindWindowByGeometry(cid, 0, zero1, zero2, screen_point, local_point_out, window_out, null);
}

pub export fn CGSFindWindowAndOwner(
    cid: CGSConnectionID,
    zero1: i32,
    zero2: i32,
    screen_point: *const CGPoint,
    local_point_out: ?*CGPoint,
    window_out: *CGSWindowID,
    connection_out: ?*CGSConnectionID,
) callconv(.c) CGError {
    return CGSFindWindowByGeometry(cid, 0, zero1, zero2, screen_point, local_point_out, window_out, connection_out);
}

// ---------------------------------------------------------------------------
// Cursor
// ---------------------------------------------------------------------------

pub export fn CGSGetCurrentCursorLocation(cid: CGSConnectionID, out: *CGPoint) callconv(.c) CGError {
    _ = cid;
    _ = updateCursorFromHid();
    out.* = server.cursor_pos;
    return kCGErrorSuccess;
}

pub export fn CGSHideCursor(cid: CGSConnectionID) callconv(.c) CGError {
    _ = cid;
    server.cursor_visible = false;
    return kCGErrorSuccess;
}

pub export fn CGSShowCursor(cid: CGSConnectionID) callconv(.c) CGError {
    _ = cid;
    server.cursor_visible = true;
    return kCGErrorSuccess;
}

pub export fn CGSObscureCursor(cid: CGSConnectionID) callconv(.c) CGError {
    return CGSHideCursor(cid);
}

pub export fn CGSRevealCursor(cid: CGSConnectionID) callconv(.c) CGError {
    return CGSShowCursor(cid);
}

pub export fn CGSWarpCursorPosition(cid: CGSConnectionID, x: f64, y: f64) callconv(.c) CGError {
    _ = cid;
    server.cursor_pos = .{ .x = x, .y = y };
    return kCGErrorSuccess;
}
