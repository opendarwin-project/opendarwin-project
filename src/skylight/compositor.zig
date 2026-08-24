//! Freestanding window compositor — the "WindowServer" half of our SkyLight
//! reimplementation.
//!
//! This module is deliberately dependency-free (no libc, no allocator, no
//! Mach): it owns nothing but a fixed table of windows and knows how to
//! flatten them into a linear framebuffer.  `src/skylight/skylight.zig` wraps
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

    /// Title bar rectangle in screen space (if decorated).
    pub fn titleBarRect(self: *const Window) Rect {
        if (!self.decorated) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        const f = self.frame();
        return .{
            .x = f.x,
            .y = f.y,
            .width = f.width,
            .height = title_bar_height,
        };
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

    /// Topmost window whose *title bar* contains the point — used for window
    /// dragging and title bar interactions.
    pub fn hitTestTitleBar(self: *Compositor, x: i32, y: i32) ?*Window {
        var hit: ?*Window = null;
        for (&self.windows) |*w| {
            if (!w.in_use or !w.ordered_in or !w.decorated) continue;
            if (!w.titleBarRect().contains(x, y)) continue;
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

    /// Composite all windows and overlay the arrow cursor at `(cursor_x, cursor_y)`.
    pub fn compositeWithCursor(self: *Compositor, target: Surface, cursor_x: i32, cursor_y: i32) u32 {
        const n = self.composite(target);
        drawCursor(target, cursor_x, cursor_y);
        return n;
    }

    fn paintWindow(self: *Compositor, target: Surface, w: *const Window) void {
        if (w.decorated) {
            const f = w.frame();
            // Window border outline
            fill(target, f, self.frame_color);
            // Title bar background
            fill(target, .{
                .x = f.x + border,
                .y = f.y + border,
                .width = f.width - 2 * border,
                .height = title_bar_height - border,
            }, self.title_active);

            // macOS Aqua-style traffic lights: Red (close), Yellow (minimize), Green (zoom)
            // Center y = f.y + 11, radius = 4 (diameter 9)
            const cy = f.y + 11;
            drawTrafficLight(target, f.x + 13, cy, 4, .{ .r = 0xff, .g = 0x5f, .b = 0x56 }, .{ .r = 0xdf, .g = 0x48, .b = 0x40 });
            drawTrafficLight(target, f.x + 27, cy, 4, .{ .r = 0xff, .g = 0xbd, .b = 0x2e }, .{ .r = 0xde, .g = 0x9f, .b = 0x1a });
            drawTrafficLight(target, f.x + 41, cy, 4, .{ .r = 0x27, .g = 0xc9, .b = 0x3f }, .{ .r = 0x1d, .g = 0xaa, .b = 0x31 });

            // Title text with subtle drop shadow
            const title = w.titleSlice();
            if (title.len > 0) {
                const text_w = @as(i32, @intCast(title.len)) * 6;
                const center_x = f.x + @divTrunc(f.width - text_w, 2);
                const draw_x = @max(f.x + 55, center_x);
                const draw_y = f.y + 7;
                if (draw_x + text_w <= f.x + f.width - 4) {
                    drawText(target, title, draw_x, draw_y + 1, .{ .r = 0x10, .g = 0x10, .b = 0x10, .a = 0xaa });
                    drawText(target, title, draw_x, draw_y, .{ .r = 0xf0, .g = 0xf0, .b = 0xf0, .a = 0xff });
                }
            }

            // Title bar bottom shadow line
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

fn drawTrafficLight(target: Surface, cx: i32, cy: i32, r: i32, fill_col: Color, border_col: Color) void {
    var y = -r;
    while (y <= r) : (y += 1) {
        var x = -r;
        while (x <= r) : (x += 1) {
            const dist_sq = x * x + y * y;
            if (dist_sq <= r * r) {
                const px = cx + x;
                const py = cy + y;
                if (px >= 0 and py >= 0 and px < @as(i32, @intCast(target.width)) and py < @as(i32, @intCast(target.height))) {
                    const off = @as(usize, @intCast(py)) * target.stride + @as(usize, @intCast(px)) * 4;
                    const c = if (dist_sq >= (r - 1) * (r - 1)) border_col else fill_col;
                    store(target, off, c);
                }
            }
        }
    }
}

// 5x7 ASCII bitmap font (characters 32..126). 5 columns per glyph.
const font5x7 = [95][5]u8{
    .{ 0x00, 0x00, 0x00, 0x00, 0x00 }, // 32 ' '
    .{ 0x00, 0x00, 0x5f, 0x00, 0x00 }, // 33 '!'
    .{ 0x00, 0x07, 0x00, 0x07, 0x00 }, // 34 '"'
    .{ 0x14, 0x7f, 0x14, 0x7f, 0x14 }, // 35 '#'
    .{ 0x24, 0x2a, 0x7f, 0x2a, 0x12 }, // 36 '$'
    .{ 0x23, 0x13, 0x08, 0x64, 0x62 }, // 37 '%'
    .{ 0x36, 0x49, 0x55, 0x22, 0x50 }, // 38 '&'
    .{ 0x00, 0x05, 0x03, 0x00, 0x00 }, // 39 '\''
    .{ 0x00, 0x1c, 0x22, 0x41, 0x00 }, // 40 '('
    .{ 0x00, 0x41, 0x22, 0x1c, 0x00 }, // 41 ')'
    .{ 0x14, 0x08, 0x3e, 0x08, 0x14 }, // 42 '*'
    .{ 0x08, 0x08, 0x3e, 0x08, 0x08 }, // 43 '+'
    .{ 0x00, 0x00, 0xa0, 0x60, 0x00 }, // 44 ','
    .{ 0x08, 0x08, 0x08, 0x08, 0x08 }, // 45 '-'
    .{ 0x00, 0x60, 0x60, 0x00, 0x00 }, // 46 '.'
    .{ 0x20, 0x10, 0x08, 0x04, 0x02 }, // 47 '/'
    .{ 0x3e, 0x51, 0x49, 0x45, 0x3e }, // 48 '0'
    .{ 0x00, 0x42, 0x7f, 0x40, 0x00 }, // 49 '1'
    .{ 0x42, 0x61, 0x51, 0x49, 0x46 }, // 50 '2'
    .{ 0x21, 0x41, 0x45, 0x4b, 0x31 }, // 51 '3'
    .{ 0x18, 0x14, 0x12, 0x7f, 0x10 }, // 52 '4'
    .{ 0x27, 0x45, 0x45, 0x45, 0x39 }, // 53 '5'
    .{ 0x3c, 0x4a, 0x49, 0x49, 0x30 }, // 54 '6'
    .{ 0x01, 0x71, 0x09, 0x05, 0x03 }, // 55 '7'
    .{ 0x36, 0x49, 0x49, 0x49, 0x36 }, // 56 '8'
    .{ 0x06, 0x49, 0x49, 0x29, 0x1e }, // 57 '9'
    .{ 0x00, 0x36, 0x36, 0x00, 0x00 }, // 58 ':'
    .{ 0x00, 0x56, 0x36, 0x00, 0x00 }, // 59 ';'
    .{ 0x08, 0x14, 0x22, 0x41, 0x00 }, // 60 '<'
    .{ 0x14, 0x14, 0x14, 0x14, 0x14 }, // 61 '='
    .{ 0x00, 0x41, 0x22, 0x14, 0x08 }, // 62 '>'
    .{ 0x02, 0x01, 0x51, 0x09, 0x06 }, // 63 '?'
    .{ 0x32, 0x49, 0x59, 0x51, 0x3e }, // 64 '@'
    .{ 0x7e, 0x11, 0x11, 0x11, 0x7e }, // 65 'A'
    .{ 0x7f, 0x49, 0x49, 0x49, 0x36 }, // 66 'B'
    .{ 0x3e, 0x41, 0x41, 0x41, 0x22 }, // 67 'C'
    .{ 0x7f, 0x41, 0x41, 0x22, 0x1c }, // 68 'D'
    .{ 0x7f, 0x49, 0x49, 0x49, 0x41 }, // 69 'E'
    .{ 0x7f, 0x09, 0x09, 0x09, 0x01 }, // 70 'F'
    .{ 0x3e, 0x41, 0x49, 0x49, 0x7a }, // 71 'G'
    .{ 0x7f, 0x08, 0x08, 0x08, 0x7f }, // 72 'H'
    .{ 0x00, 0x41, 0x7f, 0x41, 0x00 }, // 73 'I'
    .{ 0x20, 0x40, 0x41, 0x3f, 0x01 }, // 74 'J'
    .{ 0x7f, 0x08, 0x14, 0x22, 0x41 }, // 75 'K'
    .{ 0x7f, 0x40, 0x40, 0x40, 0x40 }, // 76 'L'
    .{ 0x7f, 0x02, 0x0c, 0x02, 0x7f }, // 77 'M'
    .{ 0x7f, 0x04, 0x08, 0x10, 0x7f }, // 78 'N'
    .{ 0x3e, 0x41, 0x41, 0x41, 0x3e }, // 79 'O'
    .{ 0x7f, 0x09, 0x09, 0x09, 0x06 }, // 80 'P'
    .{ 0x3e, 0x41, 0x51, 0x21, 0x5e }, // 81 'Q'
    .{ 0x7f, 0x09, 0x19, 0x29, 0x46 }, // 82 'R'
    .{ 0x46, 0x49, 0x49, 0x49, 0x31 }, // 83 'S'
    .{ 0x01, 0x01, 0x7f, 0x01, 0x01 }, // 84 'T'
    .{ 0x3f, 0x40, 0x40, 0x40, 0x3f }, // 85 'U'
    .{ 0x1f, 0x20, 0x40, 0x20, 0x1f }, // 86 'V'
    .{ 0x3f, 0x40, 0x38, 0x40, 0x3f }, // 87 'W'
    .{ 0x63, 0x14, 0x08, 0x14, 0x63 }, // 88 'X'
    .{ 0x07, 0x08, 0x70, 0x08, 0x07 }, // 89 'Y'
    .{ 0x61, 0x51, 0x49, 0x45, 0x43 }, // 90 'Z'
    .{ 0x00, 0x7f, 0x41, 0x41, 0x00 }, // 91 '['
    .{ 0x55, 0x2a, 0x55, 0x2a, 0x55 }, // 92 '\'
    .{ 0x00, 0x41, 0x41, 0x7f, 0x00 }, // 93 ']'
    .{ 0x04, 0x02, 0x01, 0x02, 0x04 }, // 94 '^'
    .{ 0x40, 0x40, 0x40, 0x40, 0x40 }, // 95 '_'
    .{ 0x00, 0x01, 0x02, 0x04, 0x00 }, // 96 '`'
    .{ 0x20, 0x54, 0x54, 0x54, 0x78 }, // 97 'a'
    .{ 0x7f, 0x48, 0x44, 0x44, 0x38 }, // 98 'b'
    .{ 0x38, 0x44, 0x44, 0x44, 0x20 }, // 99 'c'
    .{ 0x38, 0x44, 0x44, 0x48, 0x7f }, // 100 'd'
    .{ 0x38, 0x54, 0x54, 0x54, 0x18 }, // 101 'e'
    .{ 0x08, 0x7e, 0x09, 0x01, 0x02 }, // 102 'f'
    .{ 0x0c, 0x52, 0x52, 0x52, 0x3e }, // 103 'g'
    .{ 0x7f, 0x08, 0x04, 0x04, 0x78 }, // 104 'h'
    .{ 0x00, 0x44, 0x7d, 0x40, 0x00 }, // 105 'i'
    .{ 0x20, 0x40, 0x44, 0x3d, 0x00 }, // 106 'j'
    .{ 0x7f, 0x10, 0x28, 0x44, 0x00 }, // 107 'k'
    .{ 0x00, 0x41, 0x7f, 0x40, 0x00 }, // 108 'l'
    .{ 0x7c, 0x04, 0x18, 0x04, 0x78 }, // 109 'm'
    .{ 0x7c, 0x08, 0x04, 0x04, 0x78 }, // 110 'n'
    .{ 0x38, 0x44, 0x44, 0x44, 0x38 }, // 111 'o'
    .{ 0x7c, 0x14, 0x14, 0x14, 0x08 }, // 112 'p'
    .{ 0x08, 0x14, 0x14, 0x18, 0x7c }, // 113 'q'
    .{ 0x7c, 0x08, 0x04, 0x04, 0x08 }, // 114 'r'
    .{ 0x48, 0x54, 0x54, 0x54, 0x20 }, // 115 's'
    .{ 0x04, 0x3f, 0x44, 0x40, 0x20 }, // 116 't'
    .{ 0x3c, 0x40, 0x40, 0x20, 0x7c }, // 117 'u'
    .{ 0x1c, 0x20, 0x40, 0x20, 0x1c }, // 118 'v'
    .{ 0x3c, 0x40, 0x30, 0x40, 0x3c }, // 119 'w'
    .{ 0x44, 0x28, 0x10, 0x28, 0x44 }, // 120 'x'
    .{ 0x0c, 0x50, 0x50, 0x50, 0x3c }, // 121 'y'
    .{ 0x44, 0x64, 0x54, 0x4c, 0x44 }, // 122 'z'
    .{ 0x00, 0x08, 0x36, 0x41, 0x00 }, // 123 '{'
    .{ 0x00, 0x00, 0x77, 0x00, 0x00 }, // 124 '|'
    .{ 0x00, 0x41, 0x36, 0x08, 0x00 }, // 125 '}'
    .{ 0x10, 0x08, 0x08, 0x10, 0x08 }, // 126 '~'
};

fn drawChar(target: Surface, ch: u8, x: i32, y: i32, color: Color) void {
    if (ch < 32 or ch > 126) return;
    const glyph = font5x7[ch - 32];
    for (0..5) |col| {
        const cx = x + @as(i32, @intCast(col));
        const bits = glyph[col];
        for (0..7) |row| {
            if ((bits & (@as(u8, 1) << @truncate(row))) != 0) {
                const cy = y + @as(i32, @intCast(row));
                if (cx >= 0 and cy >= 0 and cx < @as(i32, @intCast(target.width)) and cy < @as(i32, @intCast(target.height))) {
                    const off = @as(usize, @intCast(cy)) * target.stride + @as(usize, @intCast(cx)) * 4;
                    if (color.a == 255) {
                        store(target, off, color);
                    } else {
                        const d = target.bytes[off..][0..4];
                        const dc = switch (target.order) {
                            .bgra => Color{ .b = d[0], .g = d[1], .r = d[2] },
                            .rgba => Color{ .r = d[0], .g = d[1], .b = d[2] },
                        };
                        store(target, off, .{
                            .b = mix(color.b, dc.b, color.a),
                            .g = mix(color.g, dc.g, color.a),
                            .r = mix(color.r, dc.r, color.a),
                        });
                    }
                }
            }
        }
    }
}

pub fn drawText(target: Surface, text: []const u8, x: i32, y: i32, color: Color) void {
    var cur_x = x;
    for (text) |ch| {
        drawChar(target, ch, cur_x, y, color);
        cur_x += 6; // 5px glyph width + 1px spacing
    }
}

pub const cursor_width = 12;
pub const cursor_height = 18;

// Classic macOS arrow pointer: 0 = transparent, 1 = black border, 2 = white interior, 3 = shadow
pub const default_cursor_pixels = [cursor_height][cursor_width]u8{
    [_]u8{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    [_]u8{ 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    [_]u8{ 1, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    [_]u8{ 1, 2, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0 },
    [_]u8{ 1, 2, 2, 2, 1, 0, 0, 0, 0, 0, 0, 0 },
    [_]u8{ 1, 2, 2, 2, 2, 1, 0, 0, 0, 0, 0, 0 },
    [_]u8{ 1, 2, 2, 2, 2, 2, 1, 0, 0, 0, 0, 0 },
    [_]u8{ 1, 2, 2, 2, 2, 2, 2, 1, 0, 0, 0, 0 },
    [_]u8{ 1, 2, 2, 2, 2, 2, 2, 2, 1, 0, 0, 0 },
    [_]u8{ 1, 2, 2, 2, 2, 2, 2, 2, 2, 1, 0, 0 },
    [_]u8{ 1, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 0 },
    [_]u8{ 1, 2, 2, 1, 2, 2, 1, 0, 0, 0, 0, 0 },
    [_]u8{ 1, 2, 1, 0, 1, 2, 2, 1, 0, 0, 0, 0 },
    [_]u8{ 1, 1, 0, 0, 1, 2, 2, 1, 0, 0, 0, 0 },
    [_]u8{ 1, 0, 0, 0, 0, 1, 2, 2, 1, 0, 0, 0 },
    [_]u8{ 0, 0, 0, 0, 0, 1, 2, 2, 1, 0, 0, 0 },
    [_]u8{ 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0 },
    [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
};

pub fn drawCursor(target: Surface, cursor_x: i32, cursor_y: i32) void {
    const black = Color{ .b = 0x00, .g = 0x00, .r = 0x00, .a = 0xff };
    const white = Color{ .b = 0xff, .g = 0xff, .r = 0xff, .a = 0xff };
    const shadow = Color{ .b = 0x00, .g = 0x00, .r = 0x00, .a = 0x60 };

    for (0..cursor_height) |cy| {
        const y = cursor_y + @as(i32, @intCast(cy));
        if (y < 0 or y >= target.height) continue;
        const dst_base = @as(usize, @intCast(y)) * target.stride;

        for (0..cursor_width) |cx| {
            const x = cursor_x + @as(i32, @intCast(cx));
            if (x < 0 or x >= target.width) continue;
            const code = default_cursor_pixels[cy][cx];
            if (code == 0) continue;

            const c = switch (code) {
                1 => black,
                2 => white,
                3 => shadow,
                else => continue,
            };

            const dst_off = dst_base + @as(usize, @intCast(x)) * 4;
            if (c.a == 255) {
                store(target, dst_off, c);
            } else {
                const d = target.bytes[dst_off..][0..4];
                const dc = switch (target.order) {
                    .bgra => Color{ .b = d[0], .g = d[1], .r = d[2] },
                    .rgba => Color{ .r = d[0], .g = d[1], .b = d[2] },
                };
                store(target, dst_off, .{
                    .b = mix(c.b, dc.b, c.a),
                    .g = mix(c.g, dc.g, c.a),
                    .r = mix(c.r, dc.r, c.a),
                });
            }
        }
    }
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

test "cursor draws black border and white fill over desktop" {
    var buf: [16 * 16 * 4]u8 = undefined;
    var cg = Compositor{};
    const t = testSurface(&buf, 16, 16);
    _ = cg.compositeWithCursor(t, 2, 2);
    // (2, 2) is top-left tip of arrow -> black border (0, 0, 0)
    const tip_off = (2 * 16 + 2) * 4;
    try std.testing.expectEqual(@as(u8, 0), buf[tip_off + 0]);
    try std.testing.expectEqual(@as(u8, 0), buf[tip_off + 1]);
    try std.testing.expectEqual(@as(u8, 0), buf[tip_off + 2]);
    // (3, 4) is inside arrow -> white interior (255, 255, 255)
    const inner_off = (4 * 16 + 3) * 4;
    try std.testing.expectEqual(@as(u8, 255), buf[inner_off + 0]);
    try std.testing.expectEqual(@as(u8, 255), buf[inner_off + 1]);
    try std.testing.expectEqual(@as(u8, 255), buf[inner_off + 2]);
}

test "title bar hit test and window dragging" {
    var cg = Compositor{};
    const cid = cg.newConnection();
    // Window content at (100, 100), size 200x150.
    // Title bar is at (100 - border, 100 - title_bar_height) = (99, 78) with width 202, height 22.
    const w = cg.newWindow(cid, .{ .x = 100, .y = 100, .width = 200, .height = 150 }).?;
    _ = cg.setTitle(w.wid, "Test Window");
    _ = cg.orderWindow(w.wid, 1);

    // Hit test inside title bar: (150, 85)
    const hit_tb = cg.hitTestTitleBar(150, 85);
    try std.testing.expect(hit_tb != null);
    try std.testing.expectEqual(w.wid, hit_tb.?.wid);

    // Hit test outside title bar (in content): (150, 120) -> hitTest finds it, hitTestTitleBar does not
    try std.testing.expect(cg.hitTestTitleBar(150, 120) == null);
    try std.testing.expect(cg.hitTest(150, 120) != null);

    // Move window
    _ = cg.moveWindow(w.wid, 150, 130);
    try std.testing.expectEqual(@as(i32, 150), w.bounds.x);
    try std.testing.expectEqual(@as(i32, 130), w.bounds.y);
    try std.testing.expect(cg.hitTestTitleBar(160, 115) != null);
}
