//! Freestanding window compositor — the "WindowServer" half of our SkyLight
//! reimplementation.
//!
//! This module is deliberately dependency-free (no libc, no allocator, no
//! Mach): it owns nothing but a fixed table of windows and knows how to
//! flatten them into a linear framebuffer.  `skylight/src/skylight.zig` wraps
//! it with the CGS* entry points that clients (AppKit-shaped code, Prism's
//! platform/darwin.zig backend) actually call, and feeds it an IOFramebuffer
//! aperture obtained through IOKitLib.
//!
//! Keeping the pixel math here means it can be unit tested on the host
//! (`zig build test-skylight`) without a guest kernel.

const std = @import("std");

pub const max_windows = 32;

pub const Rect = extern struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and py >= self.y and
            px < self.x + self.width and py < self.y + self.height;
    }
};

/// Byte order of a 32bpp surface.  Real IOFramebuffer scanout on Apple silicon
/// is BGRA/XRGB little-endian; Prism's software rasterizer emits RGBA.
pub const PixelOrder = enum(u8) {
    bgra,
    rgba,

    fn swizzled(self: PixelOrder, other: PixelOrder) bool {
        return self != other;
    }
};

pub const Surface = struct {
    bytes: []u8,
    width: u32,
    height: u32,
    stride: u32,
    order: PixelOrder = .bgra,

    pub fn row(self: Surface, y: u32) []u8 {
        return self.bytes[y * self.stride ..][0 .. self.width * 4];
    }
};

pub const Color = struct {
    b: u8,
    g: u8,
    r: u8,
    a: u8 = 0xff,
};

/// Mirrors CGSWindowLevel / kCGWindowLevelKey ordering: bigger is closer to
/// the user.  Values match the well-known CoreGraphics window levels.
pub const level_normal: i32 = 0;
pub const level_floating: i32 = 3;
pub const level_modal: i32 = 8;
pub const level_popup: i32 = 101;

pub const title_bar_height: i32 = 22;
pub const border: i32 = 1;

pub const Window = struct {
    wid: u32 = 0,
    cid: u32 = 0,
    in_use: bool = false,
    ordered_in: bool = false,
    /// Monotonic counter used as the intra-level z tiebreaker (CGSOrderWindow).
    order_seq: u64 = 0,
    level: i32 = level_normal,
    alpha: f32 = 1.0,
    /// Content bounds in screen space (title bar is drawn *above* this).
    bounds: Rect = .{},
    decorated: bool = true,
    /// Client backing store: `bounds.height` rows of `stride` bytes.
    backing: ?[]u8 = null,
    backing_stride: u32 = 0,
    backing_order: PixelOrder = .bgra,
    title_len: u8 = 0,
    title: [64]u8 = [_]u8{0} ** 64,

    pub fn titleSlice(self: *const Window) []const u8 {
        return self.title[0..self.title_len];
    }

    /// Full outer frame including decoration, i.e. what CGSGetWindowBounds
    /// reports for a decorated window.
    pub fn frame(self: *const Window) Rect {
        if (!self.decorated) return self.bounds;
        return .{
            .x = self.bounds.x - border,
            .y = self.bounds.y - title_bar_height,
            .width = self.bounds.width + 2 * border,
            .height = self.bounds.height + title_bar_height + border,
        };
    }
};

pub const Compositor = struct {
    windows: [max_windows]Window = [_]Window{.{}} ** max_windows,
    next_wid: u32 = 1,
    next_cid: u32 = 1,
    order_clock: u64 = 1,
    desktop: Color = .{ .b = 0x35, .g = 0x27, .r = 0x1e },
    title_active: Color = .{ .b = 0x60, .g = 0x60, .r = 0x60 },
    title_shadow: Color = .{ .b = 0x2a, .g = 0x2a, .r = 0x2a },
    frame_color: Color = .{ .b = 0x18, .g = 0x18, .r = 0x18 },

    pub fn newConnection(self: *Compositor) u32 {
        const cid = self.next_cid;
        self.next_cid += 1;
        return cid;
    }

    /// Tears down every window owned by `cid` (CGSReleaseConnection).
    pub fn releaseConnection(self: *Compositor, cid: u32) void {
        for (&self.windows) |*w| {
            if (w.in_use and w.cid == cid) w.* = .{};
        }
    }

    pub fn newWindow(self: *Compositor, cid: u32, bounds: Rect) ?*Window {
        for (&self.windows) |*w| {
            if (w.in_use) continue;
            const wid = self.next_wid;
            self.next_wid += 1;
            w.* = .{
                .wid = wid,
                .cid = cid,
                .in_use = true,
                .bounds = bounds,
                .order_seq = self.order_clock,
            };
            self.order_clock += 1;
            return w;
        }
        return null;
    }

    pub fn find(self: *Compositor, wid: u32) ?*Window {
        for (&self.windows) |*w| {
            if (w.in_use and w.wid == wid) return w;
        }
        return null;
    }

    pub fn releaseWindow(self: *Compositor, wid: u32) bool {
        const w = self.find(wid) orelse return false;
        w.* = .{};
        return true;
    }

    /// CGSOrderWindow: mode > 0 = above (front), 0 = out.
    pub fn orderWindow(self: *Compositor, wid: u32, mode: i32) bool {
        const w = self.find(wid) orelse return false;
        if (mode == 0) {
            w.ordered_in = false;
        } else {
            w.ordered_in = true;
            w.order_seq = self.order_clock;
            self.order_clock += 1;
        }
        return true;
    }

    pub fn setTitle(self: *Compositor, wid: u32, text: []const u8) bool {
        const w = self.find(wid) orelse return false;
        const n = @min(text.len, w.title.len);
        @memcpy(w.title[0..n], text[0..n]);
        w.title_len = @intCast(n);
        return true;
    }

    pub fn moveWindow(self: *Compositor, wid: u32, x: i32, y: i32) bool {
        const w = self.find(wid) orelse return false;
        w.bounds.x = x;
        w.bounds.y = y;
        return true;
    }

    /// Painter's-algorithm walk: (level, order_seq) ascending.
    fn nextInZOrder(self: *Compositor, after_level: i32, after_seq: u64) ?*Window {
        var best: ?*Window = null;
        for (&self.windows) |*w| {
            if (!w.in_use or !w.ordered_in or w.backing == null) continue;
            const after = w.level > after_level or (w.level == after_level and w.order_seq > after_seq);
            if (!after) continue;
            if (best) |b| {
                if (w.level < b.level or (w.level == b.level and w.order_seq < b.order_seq)) best = w;
            } else best = w;
        }
        return best;
    }

    /// Topmost window whose *frame* contains the point — the hit test
    /// WindowServer performs before routing an event (CGSFindWindowByGeometry).
    pub fn hitTest(self: *Compositor, x: i32, y: i32) ?*Window {
        var hit: ?*Window = null;
        for (&self.windows) |*w| {
            if (!w.in_use or !w.ordered_in) continue;
            if (!w.frame().contains(x, y)) continue;
            if (hit) |h| {
                if (w.level > h.level or (w.level == h.level and w.order_seq > h.order_seq)) hit = w;
            } else hit = w;
        }
        return hit;
    }

    /// Flatten every ordered-in window into `target` (CGSFlushWindow's server
    /// side).  Returns the number of windows composited.
    pub fn composite(self: *Compositor, target: Surface) u32 {
        fill(target, .{ .x = 0, .y = 0, .width = @intCast(target.width), .height = @intCast(target.height) }, self.desktop);

        var painted: u32 = 0;
        var level: i32 = -2147483648;
        var seq: u64 = 0;
        while (self.nextInZOrder(level, seq)) |w| {
            level = w.level;
            seq = w.order_seq;
            self.paintWindow(target, w);
            painted += 1;
        }
        return painted;
    }

    fn paintWindow(self: *Compositor, target: Surface, w: *const Window) void {
        if (w.decorated) {
            const f = w.frame();
            fill(target, f, self.frame_color);
            fill(target, .{
                .x = f.x + border,
                .y = f.y + border,
                .width = f.width - 2 * border,
                .height = title_bar_height - border,
            }, self.title_active);
            // Traffic-light stand-in; real WindowServer asks AppKit for the
            // decoration bitmap, we synthesize a marker instead.
            fill(target, .{ .x = f.x + 7, .y = f.y + 7, .width = 9, .height = 9 }, .{ .b = 0x4b, .g = 0x57, .r = 0xff });
            fill(target, .{
                .x = f.x + border,
                .y = f.y + title_bar_height - 1,
                .width = f.width - 2 * border,
                .height = 1,
            }, self.title_shadow);
        }
        blit(target, w);
    }
};

fn store(target: Surface, off: usize, c: Color) void {
    const p = target.bytes[off..][0..4];
    switch (target.order) {
        .bgra => {
            p[0] = c.b;
            p[1] = c.g;
            p[2] = c.r;
        },
        .rgba => {
            p[0] = c.r;
            p[1] = c.g;
            p[2] = c.b;
        },
    }
    p[3] = c.a;
}

pub fn fill(target: Surface, r: Rect, c: Color) void {
    const x0 = @max(r.x, 0);
    const y0 = @max(r.y, 0);
    const x1 = @min(r.x + r.width, @as(i32, @intCast(target.width)));
    const y1 = @min(r.y + r.height, @as(i32, @intCast(target.height)));
    if (x1 <= x0 or y1 <= y0) return;

    var y = y0;
    while (y < y1) : (y += 1) {
        const base = @as(usize, @intCast(y)) * target.stride;
        var x = x0;
        while (x < x1) : (x += 1) {
            store(target, base + @as(usize, @intCast(x)) * 4, c);
        }
    }
}

/// Source-over composite of a window's backing store, honouring both the
/// per-pixel alpha and the CGSSetWindowAlpha value.
fn blit(target: Surface, w: *const Window) void {
    const src = w.backing orelse return;
    const swap = w.backing_order != target.order;
    const wa: u32 = @intFromFloat(@max(0.0, @min(1.0, w.alpha)) * 255.0 + 0.5);
    if (wa == 0) return;

    const x0 = @max(w.bounds.x, 0);
    const y0 = @max(w.bounds.y, 0);
    const x1 = @min(w.bounds.x + w.bounds.width, @as(i32, @intCast(target.width)));
    const y1 = @min(w.bounds.y + w.bounds.height, @as(i32, @intCast(target.height)));
    if (x1 <= x0 or y1 <= y0) return;

    var y = y0;
    while (y < y1) : (y += 1) {
        const sy: usize = @intCast(y - w.bounds.y);
        const src_row_off = sy * w.backing_stride;
        if (src_row_off + @as(usize, @intCast(w.bounds.width)) * 4 > src.len) return;
        const dst_base = @as(usize, @intCast(y)) * target.stride;

        var x = x0;
        while (x < x1) : (x += 1) {
            const sx: usize = @intCast(x - w.bounds.x);
            const s = src[src_row_off + sx * 4 ..][0..4];
            const c0 = s[0];
            const c1 = s[1];
            const c2 = s[2];
            const sa = (@as(u32, s[3]) * wa) / 255;
            // A zero alpha channel is overwhelmingly "client forgot to fill
            // it" rather than "fully transparent window"; treat an opaque
            // window (alpha == 1) as opaque scanout, like IOFramebuffer's
            // XRGB skip-alpha formats do.
            const a: u32 = if (s[3] == 0 and w.alpha >= 1.0) 255 else sa;
            const dst_off = dst_base + @as(usize, @intCast(x)) * 4;
            const c = Color{
                .b = if (swap) c2 else c0,
                .g = c1,
                .r = if (swap) c0 else c2,
                .a = 0xff,
            };
            if (a == 255) {
                store(target, dst_off, c);
                continue;
            }
            const d = target.bytes[dst_off..][0..4];
            const dc = switch (target.order) {
                .bgra => Color{ .b = d[0], .g = d[1], .r = d[2] },
                .rgba => Color{ .r = d[0], .g = d[1], .b = d[2] },
            };
            store(target, dst_off, .{
                .b = mix(c.b, dc.b, a),
                .g = mix(c.g, dc.g, a),
                .r = mix(c.r, dc.r, a),
            });
        }
    }
}

fn mix(s: u8, d: u8, a: u32) u8 {
    return @intCast((@as(u32, s) * a + @as(u32, d) * (255 - a)) / 255);
}

// ---------------------------------------------------------------------------
// Tests (host)
// ---------------------------------------------------------------------------

fn testSurface(buf: []u8, w: u32, h: u32) Surface {
    return .{ .bytes = buf, .width = w, .height = h, .stride = w * 4 };
}

test "composite paints desktop when no windows are ordered in" {
    var buf: [8 * 8 * 4]u8 = undefined;
    var cg = Compositor{};
    const t = testSurface(&buf, 8, 8);
    try std.testing.expectEqual(@as(u32, 0), cg.composite(t));
    try std.testing.expectEqual(cg.desktop.b, buf[0]);
    try std.testing.expectEqual(cg.desktop.r, buf[2]);
}

test "window backing store lands at its bounds" {
    var buf: [16 * 16 * 4]u8 = undefined;
    var back: [4 * 4 * 4]u8 = [_]u8{0} ** 64;
    for (0..16) |i| {
        back[i * 4 + 0] = 0x10;
        back[i * 4 + 1] = 0x20;
        back[i * 4 + 2] = 0x30;
        back[i * 4 + 3] = 0xff;
    }

    var cg = Compositor{};
    const cid = cg.newConnection();
    const w = cg.newWindow(cid, .{ .x = 5, .y = 6, .width = 4, .height = 4 }).?;
    w.decorated = false;
    w.backing = &back;
    w.backing_stride = 16;
    _ = cg.orderWindow(w.wid, 1);

    const t = testSurface(&buf, 16, 16);
    try std.testing.expectEqual(@as(u32, 1), cg.composite(t));
    const off = (6 * 16 + 5) * 4;
    try std.testing.expectEqual(@as(u8, 0x10), buf[off]);
    try std.testing.expectEqual(@as(u8, 0x30), buf[off + 2]);
    // Outside the window we still see the desktop.
    try std.testing.expectEqual(cg.desktop.b, buf[0]);
}

test "z-order follows level then order sequence" {
    var buf: [8 * 8 * 4]u8 = undefined;
    var lo: [8 * 8 * 4]u8 = [_]u8{0} ** 256;
    var hi: [8 * 8 * 4]u8 = [_]u8{0} ** 256;
    for (0..64) |i| {
        lo[i * 4 + 0] = 0x11;
        lo[i * 4 + 3] = 0xff;
        hi[i * 4 + 0] = 0x99;
        hi[i * 4 + 3] = 0xff;
    }

    var cg = Compositor{};
    const cid = cg.newConnection();
    const a = cg.newWindow(cid, .{ .width = 8, .height = 8 }).?;
    a.decorated = false;
    a.backing = &hi;
    a.backing_stride = 32;
    a.level = level_floating;
    const b = cg.newWindow(cid, .{ .width = 8, .height = 8 }).?;
    b.decorated = false;
    b.backing = &lo;
    b.backing_stride = 32;
    _ = cg.orderWindow(a.wid, 1);
    _ = cg.orderWindow(b.wid, 1);

    _ = cg.composite(testSurface(&buf, 8, 8));
    // b was ordered last but sits at a lower level, so a wins.
    try std.testing.expectEqual(@as(u8, 0x99), buf[0]);
    try std.testing.expectEqual(a.wid, cg.hitTest(1, 1).?.wid);
}

test "alpha blends against what is already on screen" {
    var buf: [4 * 4 * 4]u8 = undefined;
    var back: [4 * 4 * 4]u8 = [_]u8{0} ** 64;
    for (0..16) |i| {
        back[i * 4 + 0] = 0xff;
        back[i * 4 + 3] = 0xff;
    }
    var cg = Compositor{};
    cg.desktop = .{ .b = 0, .g = 0, .r = 0 };
    const cid = cg.newConnection();
    const w = cg.newWindow(cid, .{ .width = 4, .height = 4 }).?;
    w.decorated = false;
    w.backing = &back;
    w.backing_stride = 16;
    w.alpha = 0.5;
    _ = cg.orderWindow(w.wid, 1);
    _ = cg.composite(testSurface(&buf, 4, 4));
    try std.testing.expect(buf[0] > 0x70 and buf[0] < 0x90);
}

test "releasing a connection drops its windows" {
    var cg = Compositor{};
    const cid = cg.newConnection();
    const w = cg.newWindow(cid, .{ .width = 2, .height = 2 }).?;
    const wid = w.wid;
    cg.releaseConnection(cid);
    try std.testing.expect(cg.find(wid) == null);
}

test "rgba clients are swizzled into a bgra scanout" {
    var buf: [2 * 2 * 4]u8 = undefined;
    var back: [2 * 2 * 4]u8 = [_]u8{0} ** 16;
    for (0..4) |i| {
        back[i * 4 + 0] = 0xaa; // R
        back[i * 4 + 1] = 0xbb;
        back[i * 4 + 2] = 0xcc; // B
        back[i * 4 + 3] = 0xff;
    }
    var cg = Compositor{};
    const cid = cg.newConnection();
    const w = cg.newWindow(cid, .{ .width = 2, .height = 2 }).?;
    w.decorated = false;
    w.backing = &back;
    w.backing_stride = 8;
    w.backing_order = .rgba;
    _ = cg.orderWindow(w.wid, 1);
    _ = cg.composite(testSurface(&buf, 2, 2));
    try std.testing.expectEqual(@as(u8, 0xcc), buf[0]); // B first on scanout
    try std.testing.expectEqual(@as(u8, 0xaa), buf[2]);
}
