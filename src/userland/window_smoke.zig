//! Guest window smoke: the userland counterpart of tools/darwin_window_smoke.zig.
//!
//! The host tool drives AppKit (NSApplication/NSWindow/NSImageView), which on
//! macOS bottoms out in SkyLight's CGS* RPCs to WindowServer.  Here we call
//! that same CGS layer directly — our own reimplementation in
//! src/skylight/{skylight,compositor}.zig — which composites onto the
//! IOFramebuffer aperture the kernel publishes (see src/userland/fb_smoke.zig
//! for the raw-framebuffer version of the same present path).
//!
//! Two windows are created so the run also exercises z-order, alpha blending
//! and hit testing, then the triangle from the host smoke is rasterized by
//! hand (no Prism in the guest yet) into the front window's backing store.

const CGError = i32;
const CGSConnectionID = u32;
const CGSWindowID = u32;
const CGSRegionRef = ?*anyopaque;

const CGPoint = extern struct { x: f64 = 0, y: f64 = 0 };
const CGSize = extern struct { width: f64 = 0, height: f64 = 0 };
const CGRect = extern struct { origin: CGPoint = .{}, size: CGSize = .{} };

const kCGSBackingBuffered: i32 = 2;
const kCGSWindowLevelFloating: i32 = 3;

extern fn write(fd: c_int, buf: [*]const u8, len: usize) isize;
extern fn usleep(usec: c_uint) c_int;

extern fn CGSNewConnection(callback: ?*const anyopaque, connection: *CGSConnectionID) CGError;
extern fn CGSReleaseConnection(connection: CGSConnectionID) CGError;
extern fn CGSNewRegionWithRect(rect: *const CGRect, region: *CGSRegionRef) CGError;
extern fn CGSReleaseRegion(region: CGSRegionRef) CGError;
extern fn CGSNewWindow(connection: CGSConnectionID, window_type: i32, x: f32, y: f32, region: CGSRegionRef, window: *CGSWindowID) CGError;
extern fn CGSReleaseWindow(connection: CGSConnectionID, window: CGSWindowID) CGError;
extern fn CGSSetWindowTitle(connection: CGSConnectionID, window: CGSWindowID, title: [*:0]const u8) CGError;
extern fn CGSSetWindowLevel(connection: CGSConnectionID, window: CGSWindowID, level: i32) CGError;
extern fn CGSSetWindowAlpha(connection: CGSConnectionID, window: CGSWindowID, alpha: f32) CGError;
extern fn CGSOrderWindow(connection: CGSConnectionID, window: CGSWindowID, mode: i32, relative_to: CGSWindowID) CGError;
extern fn CGSLockWindowBits(connection: CGSConnectionID, window: CGSWindowID, bounds_out: ?*CGRect, token_out: ?*i32, base_out: *[2]?[*]u8, rowBytes_out: *[2]i32) CGError;
extern fn CGSUnlockWindowBits(connection: CGSConnectionID, window: CGSWindowID, damage_region: CGSRegionRef) CGError;
extern fn CGSFlushWindow(connection: CGSConnectionID, window: CGSWindowID, region: CGSRegionRef) CGError;
extern fn CGSFlushConnection(connection: CGSConnectionID) CGError;
extern fn CGSGetDisplayBounds(display: u32, rect: *CGRect) CGError;
extern fn CGSGetCurrentCursorLocation(cid: CGSConnectionID, out: *CGPoint) CGError;
extern fn CGSHideCursor(cid: CGSConnectionID) CGError;
extern fn CGSShowCursor(cid: CGSConnectionID) CGError;
extern fn CGSWarpCursorPosition(cid: CGSConnectionID, x: f64, y: f64) CGError;
extern fn CGSFindWindowByGeometry(
    cid: CGSConnectionID,
    zero1: i32,
    zero2: i32,
    zero3: i32,
    screen_point: *const CGPoint,
    local_point_out: ?*CGPoint,
    window_out: *CGSWindowID,
    connection_out: ?*CGSConnectionID,
) CGError;

fn log(msg: []const u8) void {
    _ = write(1, msg.ptr, msg.len);
}

fn printInt(v: i64) void {
    if (v == 0) {
        log("0");
        return;
    }
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var n: u64 = if (v < 0) @intCast(-v) else @intCast(v);
    while (n > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
    if (v < 0) {
        i -= 1;
        buf[i] = '-';
    }
    log(buf[i..]);
}

const Backing = struct {
    base: [*]u8,
    stride: u32,
    width: u32,
    height: u32,

    fn put(self: Backing, x: u32, y: u32, b: u8, g: u8, r: u8) void {
        const p = self.base + y * self.stride + x * 4;
        p[0] = b;
        p[1] = g;
        p[2] = r;
        p[3] = 0xff;
    }
};

fn fill(dst: Backing, b: u8, g: u8, r: u8) void {
    var y: u32 = 0;
    while (y < dst.height) : (y += 1) {
        var x: u32 = 0;
        while (x < dst.width) : (x += 1) dst.put(x, y, b, g, r);
    }
}

const Vtx = struct { x: f32, y: f32, r: f32, g: f32, b: f32 };

/// Same triangle as tools/darwin_window_smoke.zig, in NDC.
const tri = [3]Vtx{
    .{ .x = -0.8, .y = -0.75, .r = 1, .g = 0, .b = 0 },
    .{ .x = 0.8, .y = -0.75, .r = 0, .g = 1, .b = 0 },
    .{ .x = 0.0, .y = 0.8, .r = 0, .g = 0, .b = 1 },
};

fn edge(ax: f32, ay: f32, bx: f32, by: f32, px: f32, py: f32) f32 {
    return (px - ax) * (by - ay) - (py - ay) * (bx - ax);
}

/// Barycentric rasterizer — the guest stand-in for Prism's software HAL until
/// the VK/EGL ICD lands (TODO.md).
fn drawTriangle(dst: Backing) void {
    const w: f32 = @floatFromInt(dst.width);
    const h: f32 = @floatFromInt(dst.height);
    var sx: [3]f32 = undefined;
    var sy: [3]f32 = undefined;
    for (tri, 0..) |v, i| {
        sx[i] = (v.x * 0.5 + 0.5) * w;
        sy[i] = (1.0 - (v.y * 0.5 + 0.5)) * h; // NDC y-up → raster y-down
    }
    const area = edge(sx[0], sy[0], sx[1], sy[1], sx[2], sy[2]);
    if (area == 0) return;

    var y: u32 = 0;
    while (y < dst.height) : (y += 1) {
        const py: f32 = @as(f32, @floatFromInt(y)) + 0.5;
        var x: u32 = 0;
        while (x < dst.width) : (x += 1) {
            const px: f32 = @as(f32, @floatFromInt(x)) + 0.5;
            var w0 = edge(sx[1], sy[1], sx[2], sy[2], px, py) / area;
            var w1 = edge(sx[2], sy[2], sx[0], sy[0], px, py) / area;
            var w2 = edge(sx[0], sy[0], sx[1], sy[1], px, py) / area;
            if (w0 < 0 or w1 < 0 or w2 < 0) continue;
            w0 = @max(w0, 0);
            w1 = @max(w1, 0);
            w2 = @max(w2, 0);
            const r = tri[0].r * w0 + tri[1].r * w1 + tri[2].r * w2;
            const g = tri[0].g * w0 + tri[1].g * w1 + tri[2].g * w2;
            const b = tri[0].b * w0 + tri[1].b * w1 + tri[2].b * w2;
            dst.put(x, y, chan(b), chan(g), chan(r));
        }
    }
}

fn chan(v: f32) u8 {
    return @intFromFloat(@max(0.0, @min(1.0, v)) * 255.0 + 0.5);
}

fn backingOf(cid: CGSConnectionID, wid: CGSWindowID, width: u32, height: u32) ?Backing {
    var bounds: CGRect = .{};
    var base: [2]?[*]u8 = .{ null, null };
    var row_bytes: [2]i32 = .{ 0, 0 };
    if (CGSLockWindowBits(cid, wid, &bounds, null, &base, &row_bytes) != 0) return null;
    if (row_bytes[0] <= 0) return null;
    return .{ .base = base[0] orelse return null, .stride = @intCast(row_bytes[0]), .width = width, .height = height };
}

fn makeWindow(cid: CGSConnectionID, x: f32, y: f32, width: u32, height: u32, title: ?[*:0]const u8) ?CGSWindowID {
    _ = title;
    var region: CGSRegionRef = null;
    const rect = CGRect{ .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) } };
    if (CGSNewRegionWithRect(&rect, &region) != 0) return null;
    defer _ = CGSReleaseRegion(region);

    var wid: CGSWindowID = 0;
    if (CGSNewWindow(cid, kCGSBackingBuffered, x, y, region, &wid) != 0) return null;
    _ = CGSOrderWindow(cid, wid, 1, 0);
    return wid;
}

pub fn main() u8 {
    var cid: CGSConnectionID = 0;
    if (CGSNewConnection(null, &cid) != 0 or cid == 0) {
        log("CGSNewConnection failed\n");
        return 10;
    }
    defer _ = CGSReleaseConnection(cid);

    var screen: CGRect = .{};
    if (CGSGetDisplayBounds(1, &screen) != 0 or screen.size.width == 0) {
        log("CGSGetDisplayBounds failed (no IOFramebuffer?)\n");
        return 11;
    }

    // Background window: a flat panel, half transparent, normal level.
    const bg_w: u32 = 240;
    const bg_h: u32 = 160;
    const bg = makeWindow(cid, 60, 90, bg_w, bg_h, "background") orelse {
        log("CGSNewWindow(background) failed\n");
        return 20;
    };
    _ = CGSSetWindowAlpha(cid, bg, 0.6);
    if (backingOf(cid, bg, bg_w, bg_h)) |b| {
        fill(b, 0xc0, 0x60, 0x20);
        _ = CGSUnlockWindowBits(cid, bg, null);
    } else {
        log("CGSLockWindowBits(background) failed\n");
        return 21;
    }

    // Foreground window: floating level, carries the triangle.
    const fg_w: u32 = 320;
    const fg_h: u32 = 200;
    const fg = makeWindow(cid, 160, 150, fg_w, fg_h, "Prism triangle") orelse {
        log("CGSNewWindow(triangle) failed\n");
        return 22;
    };
    _ = CGSSetWindowLevel(cid, fg, kCGSWindowLevelFloating);
    const fb = backingOf(cid, fg, fg_w, fg_h) orelse {
        log("CGSLockWindowBits(triangle) failed\n");
        return 23;
    };
    fill(fb, 0x0f, 0x0a, 0x0a);
    drawTriangle(fb);
    _ = CGSUnlockWindowBits(cid, fg, null);

    // Verify cursor APIs
    var cur_loc: CGPoint = .{};
    if (CGSGetCurrentCursorLocation(cid, &cur_loc) != 0) {
        log("CGSGetCurrentCursorLocation failed\n");
        return 28;
    }
    _ = CGSHideCursor(cid);
    _ = CGSShowCursor(cid);
    _ = CGSWarpCursorPosition(cid, 200.0, 200.0);

    // The floating window must win the hit test where the two overlap.
    var hit: CGSWindowID = 0;
    const pt = CGPoint{ .x = 200, .y = 200 };
    var local_pt: CGPoint = .{};
    var hit_cid: CGSConnectionID = 0;
    if (CGSFindWindowByGeometry(cid, 0, 0, 0, &pt, &local_pt, &hit, &hit_cid) != 0 or hit != fg) {
        log("CGSFindWindowByGeometry picked the wrong window\n");
        return 30;
    }

    if (CGSFlushWindow(cid, fg, null) != 0) {
        log("CGSFlushWindow failed\n");
        return 31;
    }

    log("SkyLight window composite passed — entering interactive cursor loop\n");
    var last_x: f64 = -1;
    var last_y: f64 = -1;
    var loop_count: usize = 0;
    while (true) {
        _ = CGSFlushConnection(cid);
        var cur: CGPoint = .{};
        if (CGSGetCurrentCursorLocation(cid, &cur) == 0) {
            if (cur.x != last_x or cur.y != last_y) {
                last_x = cur.x;
                last_y = cur.y;
            }
        }
        loop_count += 1;
        _ = usleep(2000);
    }
    return 0;
}
