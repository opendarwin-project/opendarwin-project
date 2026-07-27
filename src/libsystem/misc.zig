//! Miscellaneous exports: environ, getenv, setenv, unsetenv, uuid_generate,
//! localeconv, setlocale, atexit, atfork, __cxa_atexit, pow, fmod, modf, etc.

const common = @import("common.zig");
const C = common;
const std = @import("std");

// ── environment ────────────────────────────────────────────────────────

pub export var environ: [*:0]const u8 = undefined;

pub export fn getenv(name: [*:0]const u8) ?[*:0]const u8 {
    _ = name;
    return null;
}

pub export fn setenv(_: [*:0]const u8, _: [*:0]const u8, _: c_int) c_int {
    return C.stubErr("setenv");
}

pub export fn unsetenv(_: [*:0]const u8) c_int {
    return C.stubErr("unsetenv");
}

// ── locale ─────────────────────────────────────────────────────────────

pub const LcCategory = enum(c_int) {
    all = 0,
    collate = 1,
    ctype = 2,
    messages = 3,
    monetary = 4,
    numeric = 5,
    time = 6,
    _,
};

const Lconv = extern struct {
    decimal_point: [*:0]const u8 = ".",
    thousands_sep: [*:0]const u8 = "",
    grouping: [*:0]const u8 = "",
    int_curr_symbol: [*:0]const u8 = "",
    currency_symbol: [*:0]const u8 = "",
    mon_decimal_point: [*:0]const u8 = "",
    mon_thousands_sep: [*:0]const u8 = "",
    mon_grouping: [*:0]const u8 = "",
    positive_sign: [*:0]const u8 = "",
    negative_sign: [*:0]const u8 = "",
    int_frac_digits: i8 = 2,
    frac_digits: i8 = 2,
    p_cs_precedes: i8 = 1,
    p_sep_by_space: i8 = 0,
    n_cs_precedes: i8 = 1,
    n_sep_by_space: i8 = 0,
    p_sign_posn: i8 = 1,
    n_sign_posn: i8 = 1,
};

var default_lconv: Lconv = .{};

pub export fn localeconv() ?*Lconv {
    return &default_lconv;
}

pub export fn setlocale(_: LcCategory, _: [*:0]const u8) ?[*:0]const u8 {
    return "C\x00";
}

// ── atexit / __cxa_atexit ─────────────────────────────────────────────

const MAX_ATEXIT = 32;
var atexit_fns: [MAX_ATEXIT]?*const fn () callconv(.c) void = [_]?*const fn () callconv(.c) void{null} ** MAX_ATEXIT;
var atexit_count: usize = 0;

pub export fn atexit(fn_ptr: *const fn () callconv(.c) void) c_int {
    if (atexit_count >= MAX_ATEXIT) return -1;
    atexit_fns[atexit_count] = fn_ptr;
    atexit_count += 1;
    return 0;
}

pub export fn __cxa_atexit(_: *const fn (?*anyopaque) callconv(.c) void, _: ?*anyopaque, _: ?*anyopaque) c_int {
    // Simplified: just accept and ignore.
    return 0;
}

pub export fn __cxa_finalize(_: ?*anyopaque) void {}

// QoS class constants (Darwin).
pub const QOS_CLASS_DEFAULT: c_int = 0x15;
pub const QOS_CLASS_UNSPECIFIED: c_int = 0x00;

pub export fn qos_class_self() c_int {
    return QOS_CLASS_DEFAULT;
}

// passwd stubs — enough for CFUtilities getpwuid paths.
const Passwd = extern struct {
    pw_name: ?[*:0]const u8 = "root",
    pw_passwd: ?[*:0]const u8 = "*",
    pw_uid: u32 = 0,
    pw_gid: u32 = 0,
    pw_change: ?[*:0]const u8 = "",
    pw_class: ?[*:0]const u8 = "",
    pw_gecos: ?[*:0]const u8 = "root",
    pw_dir: ?[*:0]const u8 = "/var/root",
    pw_shell: ?[*:0]const u8 = "/bin/sh",
};

var root_passwd: Passwd = .{};

pub export fn getpwuid(uid: u32) ?*Passwd {
    if (uid != 0) return null;
    return &root_passwd;
}

pub export fn getpwnam(name: [*:0]const u8) ?*Passwd {
    if (name[0] != 'r' or name[1] != 'o' or name[2] != 'o' or name[3] != 't' or name[4] != 0) return null;
    return &root_passwd;
}

pub export fn getpwuid_r(uid: u32, pwd: ?*Passwd, buf: ?[*]u8, buflen: usize, result: ?*?*Passwd) c_int {
    if (uid != 0) {
        if (result) |r| r.* = null;
        return C.EINVAL;
    }
    if (pwd) |p| p.* = root_passwd;
    if (result) |r| r.* = pwd;
    _ = buf;
    _ = buflen;
    return 0;
}

// ── math stubs (CF uses these) ─────────────────────────────────────────

pub export fn pow(x: f64, y: f64) f64 {
    // Minimal: if y is 0, result is 1. If x is 0, result is 0.
    if (y == 0) return 1;
    if (x == 0) return 0;
    // Very rough approximation for integer powers
    if (y == @floor(y) and y > 0 and y < 64) {
        var result: f64 = 1;
        var exp = @as(i64, @intFromFloat(y));
        var base = x;
        while (exp > 0) {
            if (exp & 1 == 1) result *= base;
            base *= base;
            exp >>= 1;
        }
        return result;
    }
    return 1.0;
}

pub export fn powf(x: f32, y: f32) f32 {
    return @floatCast(pow(x, y));
}

pub export fn fmod(x: f64, y: f64) f64 {
    if (y == 0) return 0;
    return x - @floor(x / y) * y;
}

pub export fn fmodf(x: f32, y: f32) f32 {
    return @floatCast(fmod(x, y));
}

pub export fn modf(x: f64, iptr: ?*f64) f64 {
    const i = @floor(x);
    if (iptr) |p| p.* = i;
    return x - i;
}

pub export fn modff(x: f32, iptr: ?*f32) f32 {
    const i = @floor(x);
    if (iptr) |p| p.* = i;
    return x - i;
}

pub export fn sqrt(x: f64) f64 {
    // Newton's method
    if (x < 0) return 0;
    if (x == 0) return 0;
    var guess = x / 2;
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        guess = (guess + x / guess) / 2;
    }
    return guess;
}

pub export fn sqrtf(x: f32) f32 {
    return @floatCast(sqrt(x));
}

pub export fn fabs(x: f64) f64 {
    return if (x < 0) -x else x;
}

pub export fn fabsf(x: f32) f32 {
    return if (x < 0) -x else x;
}

pub export fn ceil(x: f64) f64 {
    return @ceil(x);
}

pub export fn ceilf(x: f32) f32 {
    return @ceil(x);
}

pub export fn floor(x: f64) f64 {
    return @floor(x);
}

pub export fn floorf(x: f32) f32 {
    return @floor(x);
}

pub export fn round(x: f64) f64 {
    return @round(x);
}

pub export fn roundf(x: f32) f32 {
    return @round(x);
}

pub export fn trunc(x: f64) f64 {
    return @trunc(x);
}

pub export fn truncf(x: f32) f32 {
    return @trunc(x);
}

pub export fn copysign(x: f64, y: f64) f64 {
    return std.math.copysign(x, y);
}

pub export fn copysignf(x: f32, y: f32) f32 {
    return std.math.copysign(x, y);
}

pub export fn ldexp(x: f64, exp: c_int) f64 {
    var result = x;
    var e = exp;
    if (e < 0) {
        while (e < 0) : (e += 1) result /= 2;
    } else {
        while (e > 0) : (e -= 1) result *= 2;
    }
    return result;
}

pub export fn frexp(x: f64, exp: ?*c_int) f64 {
    var e: c_int = 0;
    var val = x;
    while (val >= 2.0) {
        val /= 2.0;
        e += 1;
    }
    while (val < 1.0) {
        val *= 2.0;
        e -= 1;
    }
    if (exp) |p| p.* = e;
    return val;
}

// ── uuid stubs ─────────────────────────────────────────────────────────

pub export fn uuid_generate(out: ?[*]u8) void {
    if (out) |p| @memset(p[0..16], 0);
}

pub export fn uuid_generate_random(out: ?[*]u8) void {
    uuid_generate(out);
}

pub export fn uuid_clear(uu: ?[*]u8) void {
    if (uu) |p| @memset(p[0..16], 0);
}

pub export fn uuid_is_null(uu: ?*const [16]u8) bool {
    if (uu) |p| {
        for (p) |b| {
            if (b != 0) return false;
        }
        return true;
    }
    return true;
}

pub export fn uuid_compare(a: ?*const [16]u8, b: ?*const [16]u8) c_int {
    if (a == null or b == null) return 0;
    const aa = a.?;
    const bb = b.?;
    for (0..16) |i| {
        if (aa[i] < bb[i]) return -1;
        if (aa[i] > bb[i]) return 1;
    }
    return 0;
}

pub export fn uuid_copy(dst: ?[*]u8, src: ?*const [16]u8) void {
    if (dst != null and src != null) {
        _ = @memcpy(dst.?[0..16], src.?[0..16]);
    }
}

pub export fn uuid_to_string(uu: ?*const [16]u8, out: ?*[*]u8) void {
    _ = uu;
    if (out) |p| {
        p.* = @constCast("00000000-0000-0000-0000-000000000000");
    }
}

pub export fn uuid_string_to_uuid(str: [*:0]const u8, uu: ?[*]u8) void {
    _ = str;
    if (uu) |p| @memset(p[0..16], 0);
}
