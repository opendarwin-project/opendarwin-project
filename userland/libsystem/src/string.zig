//! String and memory functions: strlen, strcmp, strncmp, strchr, strrchr,
//! strdup, strndup, strlcpy, strlcat, memcpy, memmove, memset, memcmp,
//! memchr, memrchr.

const common = @import("common.zig");
const C = common;

// ── memcpy / memmove / memset (needed by allocator and others) ─────────

pub export fn memcpy(dst: ?*anyopaque, src: ?*const anyopaque, len: usize) ?*anyopaque {
    const d = dst orelse return null;
    const s = src orelse return d;
    const out: [*]volatile u8 = @ptrCast(d);
    const input: [*]const volatile u8 = @ptrCast(s);
    for (0..len) |i| out[i] = input[i];
    return d;
}

pub export fn memmove(dst: ?*anyopaque, src: ?*const anyopaque, len: usize) ?*anyopaque {
    const d = dst orelse return null;
    const s = src orelse return d;
    const out: [*]volatile u8 = @ptrCast(d);
    const input: [*]const volatile u8 = @ptrCast(s);
    if (@intFromPtr(out) <= @intFromPtr(input)) {
        for (0..len) |i| out[i] = input[i];
    } else {
        var i = len;
        while (i != 0) {
            i -= 1;
            out[i] = input[i];
        }
    }
    return d;
}

pub export fn memset(dst: ?*anyopaque, value: c_int, len: usize) ?*anyopaque {
    const d = dst orelse return null;
    const out: [*]volatile u8 = @ptrCast(d);
    const byte: u8 = @truncate(@as(c_uint, @bitCast(value)));
    var i: usize = 0;
    while (i < len) : (i += 1) out[i] = byte;
    return d;
}

pub export fn memcmp(s1: ?*const anyopaque, s2: ?*const anyopaque, n: usize) c_int {
    const a = s1 orelse return 0;
    const b = s2 orelse return 0;
    const p1: [*]const u8 = @ptrCast(a);
    const p2: [*]const u8 = @ptrCast(b);
    var i: usize = 0;
    while (i < n) {
        if (p1[i] != p2[i]) return if (p1[i] < p2[i]) -1 else 1;
        i += 1;
    }
    return 0;
}

pub export fn memchr(s: ?*const anyopaque, c: c_int, n: usize) ?*anyopaque {
    const p = s orelse return null;
    const bytes: [*]const u8 = @ptrCast(p);
    const target: u8 = @intCast(c);
    var i: usize = 0;
    while (i < n) {
        if (bytes[i] == target) return @ptrCast(@constCast(&bytes[i]));
        i += 1;
    }
    return null;
}

pub export fn memrchr(s: ?*const anyopaque, c: c_int, n: usize) ?*anyopaque {
    const p = s orelse return null;
    const bytes: [*]const u8 = @ptrCast(p);
    const target: u8 = @intCast(c);
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        if (bytes[i] == target) return @ptrCast(@constCast(&bytes[i]));
    }
    return null;
}

// ── strlen ─────────────────────────────────────────────────────────────

pub export fn strlen(s: [*:0]const u8) usize {
    return C.cstrLen(s);
}

// ── strcmp family ──────────────────────────────────────────────────────

pub export fn strcmp(s1: [*:0]const u8, s2: [*:0]const u8) c_int {
    var i: usize = 0;
    while (true) {
        const c1 = s1[i];
        const c2 = s2[i];
        if (c1 != c2) return if (c1 < c2) @as(c_int, -1) else 1;
        if (c1 == 0) return 0;
        i += 1;
    }
}

pub export fn strncmp(s1: [*:0]const u8, s2: [*:0]const u8, n: usize) c_int {
    var i: usize = 0;
    while (i < n) {
        const c1 = s1[i];
        const c2 = s2[i];
        if (c1 != c2) return if (c1 < c2) @as(c_int, -1) else 1;
        if (c1 == 0) return 0;
        i += 1;
    }
    return 0;
}

pub export fn strcasecmp(s1: [*:0]const u8, s2: [*:0]const u8) c_int {
    var i: usize = 0;
    while (true) {
        const c1 = std.ascii.toLower(s1[i]);
        const c2 = std.ascii.toLower(s2[i]);
        if (c1 != c2) return if (c1 < c2) @as(c_int, -1) else 1;
        if (c1 == 0) return 0;
        i += 1;
    }
}

pub export fn strncasecmp(s1: [*:0]const u8, s2: [*:0]const u8, n: usize) c_int {
    var i: usize = 0;
    while (i < n) {
        const c1 = std.ascii.toLower(s1[i]);
        const c2 = std.ascii.toLower(s2[i]);
        if (c1 != c2) return if (c1 < c2) @as(c_int, -1) else 1;
        if (c1 == 0) return 0;
        i += 1;
    }
    return 0;
}

// ── strchr / strrchr / strstr ──────────────────────────────────────────

pub export fn strchr(s: [*:0]const u8, c: c_int) ?[*:0]u8 {
    const target: u8 = @intCast(c);
    var i: usize = 0;
    while (true) {
        if (s[i] == target) return @ptrCast(@constCast(&s[i]));
        if (s[i] == 0) return null;
        i += 1;
    }
}

pub export fn strrchr(s: [*:0]const u8, c: c_int) ?[*:0]u8 {
    var last: ?[*:0]u8 = null;
    const target: u8 = @intCast(c);
    var i: usize = 0;
    while (true) {
        if (s[i] == target) last = @ptrCast(@constCast(&s[i]));
        if (s[i] == 0) return last;
        i += 1;
    }
}

pub export fn strstr(haystack: [*:0]const u8, needle: [*:0]const u8) ?[*:0]u8 {
    const needle_len = C.cstrLen(needle);
    if (needle_len == 0) return @ptrCast(@constCast(haystack));
    var i: usize = 0;
    while (haystack[i] != 0) : (i += 1) {
        var j: usize = 0;
        while (j < needle_len and haystack[i + j] == needle[j]) : (j += 1) {}
        if (j == needle_len) return @ptrCast(@constCast(&haystack[i]));
    }
    return null;
}

// ── strdup / strndup ──────────────────────────────────────────────────

pub export fn strdup(s: [*:0]const u8) ?[*:0]u8 {
    const len = C.cstrLen(s);
    const dst = @import("malloc.zig").malloc(len + 1) orelse return null;
    _ = memcpy(dst, s, len + 1);
    return @ptrCast(dst);
}

pub export fn strndup(s: [*:0]const u8, n: usize) ?[*:0]u8 {
    var len: usize = 0;
    while (len < n and s[len] != 0) : (len += 1) {}
    const dst = @import("malloc.zig").malloc(len + 1) orelse return null;
    _ = memcpy(dst, s, len);
    @as([*]u8, @ptrCast(dst))[len] = 0;
    return @ptrCast(dst);
}

// ── strlcpy / strlcat ─────────────────────────────────────────────────

pub export fn strlcpy(dst: [*]u8, src: [*:0]const u8, dstsize: usize) usize {
    if (dstsize == 0) return C.cstrLen(src);
    var i: usize = 0;
    while (i + 1 < dstsize) {
        const c = src[i];
        if (c == 0) break;
        dst[i] = c;
        i += 1;
    }
    dst[i] = 0;
    return i + C.cstrLen(src[i..]);
}

pub export fn strlcat(dst: [*:0]u8, src: [*:0]const u8, dstsize: usize) usize {
    const dst_len = C.cstrLen(dst);
    if (dst_len >= dstsize) return dst_len + C.cstrLen(src);
    return dst_len + strlcpy(dst[dst_len..], src, dstsize - dst_len);
}

// ── strtol / strtoul / strtoll / strtoull ─────────────────────────────

pub export fn strtol(s: [*:0]const u8, endp: ?*[*:0]const u8, base: c_int) c_long {
    return @intCast(strtoll_internal(s, endp, base));
}

pub export fn strtoul(s: [*:0]const u8, endp: ?*[*:0]const u8, base: c_int) c_ulong {
    return @intCast(strtoull_internal(s, endp, base));
}

pub export fn strtoll(s: [*:0]const u8, endp: ?*[*:0]const u8, base: c_int) i64 {
    return strtoll_internal(s, endp, base);
}

pub export fn strtoull(s: [*:0]const u8, endp: ?*[*:0]const u8, base: c_int) u64 {
    return strtoull_internal(s, endp, base);
}

fn strtoll_internal(s: [*:0]const u8, endp: ?*[*:0]const u8, base: c_int) i64 {
    // Skip leading whitespace
    var p = s;
    while (std.ascii.isWhitespace(p[0])) : (p += 1) {}

    // Handle sign
    var negative = false;
    if (p[0] == '+') {
        p += 1;
    } else if (p[0] == '-') {
        negative = true;
        p += 1;
    }

    // Handle base prefix
    var actual_base: u8 = @intCast(base);
    if (base == 0) {
        if (p[0] == '0') {
            if (p[1] == 'x' or p[1] == 'X') {
                actual_base = 16;
                p += 2;
            } else {
                actual_base = 8;
                p += 1;
            }
        } else {
            actual_base = 10;
        }
    } else if (base == 16 and p[0] == '0' and (p[1] == 'x' or p[1] == 'X')) {
        p += 2;
    }

    // Parse digits
    var result: u64 = 0;
    while (true) {
        const c = p[0];
        const digit = if (c >= '0' and c <= '9') c - '0' else if (c >= 'a' and c <= 'z') c - 'a' + 10 else if (c >= 'A' and c <= 'Z') c - 'A' + 10 else 255;
        if (digit >= actual_base) break;
        result = result *% @as(u64, actual_base) +% @as(u64, digit);
        p += 1;
    }

    if (endp) |ep| ep.* = p;

    return if (negative) @bitCast(-%@as(i64, @bitCast(result))) else @bitCast(result);
}

fn strtoull_internal(s: [*:0]const u8, endp: ?*[*:0]const u8, base: c_int) u64 {
    return @bitCast(strtoll_internal(s, endp, base));
}

// ── strtod (minimal) ──────────────────────────────────────────────────

pub export fn strtod(s: [*:0]const u8, endp: ?*[*:0]const u8) f64 {
    var p = s;
    while (std.ascii.isWhitespace(p[0])) : (p += 1) {}

    var negative = false;
    if (p[0] == '+') {
        p += 1;
    } else if (p[0] == '-') {
        negative = true;
        p += 1;
    }

    // Parse integer part
    var int_part: u64 = 0;
    while (p[0] >= '0' and p[0] <= '9') : (p += 1) {
        int_part = int_part * 10 + (p[0] - '0');
    }

    var result: f64 = @floatFromInt(int_part);

    // Parse fractional part
    if (p[0] == '.') {
        p += 1;
        var frac: f64 = 0;
        var place: f64 = 0.1;
        while (p[0] >= '0' and p[0] <= '9') : (p += 1) {
            frac += @as(f64, @floatFromInt(p[0] - '0')) * place;
            place *= 0.1;
        }
        result += frac;
    }

    // Parse exponent
    if (p[0] == 'e' or p[0] == 'E') {
        p += 1;
        var exp_neg = false;
        if (p[0] == '+') p += 1 else if (p[0] == '-') {
            exp_neg = true;
            p += 1;
        }
        var exp: i32 = 0;
        while (p[0] >= '0' and p[0] <= '9') : (p += 1) {
            exp = exp * 10 + (p[0] - '0');
        }
        if (exp_neg) {
            while (exp > 0) : (exp -= 1) result /= 10;
        } else {
            while (exp > 0) : (exp -= 1) result *= 10;
        }
    }

    if (endp) |ep| ep.* = p;
    return if (negative) -result else result;
}

pub export fn atof(s: [*:0]const u8) f64 {
    return strtod(s, null);
}

// ── qsort / bsearch ───────────────────────────────────────────────────

pub export fn qsort(base: ?*anyopaque, nmemb: usize, size: usize, compar: *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int) void {
    const b = base orelse return;
    if (nmemb < 2) return;

    // Insertion sort — good enough for the small arrays CF uses.
    const arr: [*]u8 = @ptrCast(b);
    var i: usize = 1;
    while (i < nmemb) : (i += 1) {
        const key_off = i * size;
        var j = i;
        while (j > 0) {
            const prev_off = (j - 1) * size;
            if (compar(@ptrCast(&arr[prev_off]), @ptrCast(&arr[key_off])) <= 0) break;
            // swap
            var k: usize = 0;
            while (k < size) : (k += 1) {
                const tmp = arr[prev_off + k];
                arr[prev_off + k] = arr[key_off + k];
                arr[key_off + k] = tmp;
            }
            j -= 1;
        }
    }
}

pub export fn bsearch(key: ?*const anyopaque, base: ?*const anyopaque, nmemb: usize, size: usize, compar: *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int) ?*anyopaque {
    const b = base orelse return null;
    const arr: [*]const u8 = @ptrCast(b);
    var lo: usize = 0;
    var hi: usize = nmemb;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const mid_off = mid * size;
        const cmp = compar(key, @ptrCast(@constCast(&arr[mid_off])));
        if (cmp == 0) return @ptrCast(@constCast(&arr[mid_off]));
        if (cmp < 0) {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }
    return null;
}

// ── abs / labs ─────────────────────────────────────────────────────────

pub export fn abs(x: c_int) c_int {
    return if (x < 0) -x else x;
}

pub export fn labs(x: c_long) c_long {
    return if (x < 0) -x else x;
}

pub export fn flsl(x: c_long) c_int {
    if (x == 0) return 0;
    var v: u64 = @intCast(if (x < 0) -x else x);
    var bit: c_int = 0;
    while (v > 1) : (bit += 1) v >>= 1;
    return bit + 1;
}

// std import for ascii helpers
const std = @import("std");

// ── strnlen / strtok / strerror ────────────────────────────────────────

pub export fn strnlen(s: [*:0]const u8, maxlen: usize) usize {
    var i: usize = 0;
    while (i < maxlen and s[i] != 0) : (i += 1) {}
    return i;
}

var strtok_save: ?[*:0]u8 = null;

pub export fn strtok(s: ?[*:0]u8, delim: [*:0]const u8) ?[*:0]u8 {
    return strtok_r(s, delim, &strtok_save);
}

pub export fn strtok_r(s: ?[*:0]u8, delim: [*:0]const u8, saveptr: ?*?[*:0]u8) ?[*:0]u8 {
    const save = saveptr orelse return null;
    var cursor = s orelse save.* orelse return null;
    save.* = null;

    while (cursor[0] != 0 and isDelim(cursor[0], delim)) cursor += 1;
    if (cursor[0] == 0) return null;

    const start = cursor;
    while (cursor[0] != 0 and !isDelim(cursor[0], delim)) cursor += 1;
    if (cursor[0] != 0) {
        cursor[0] = 0;
        save.* = cursor + 1;
    }
    return start;
}

fn isDelim(ch: u8, delim: [*:0]const u8) bool {
    var i: usize = 0;
    while (delim[i] != 0) : (i += 1) {
        if (delim[i] == ch) return true;
    }
    return false;
}

pub export fn strerror(errnum: c_int) [*:0]u8 {
    return strsignal(errnum);
}

pub export fn strsignal(sig: c_int) [*:0]u8 {
    return switch (sig) {
        1 => @constCast("Hangup"),
        2 => @constCast("Interrupt"),
        9 => @constCast("Killed"),
        15 => @constCast("Terminated"),
        else => @constCast("Unknown signal"),
    };
}

pub export fn basename(path: [*:0]u8) [*:0]u8 {
    var end = C.cstrLen(path);
    while (end > 0 and path[end - 1] == '/') end -= 1;
    if (end == 0) return @constCast("/");
    var start = end;
    while (start > 0 and path[start - 1] != '/') start -= 1;
    path[start] = 0;
    return path + start;
}

pub export fn strtonum(
    numstr: [*:0]const u8,
    minval: i64,
    maxval: i64,
    errstr: ?*?[*:0]const u8,
) i64 {
    var endp: [*]const u8 = numstr;
    const value = strtoll(numstr, @ptrCast(&endp), 10);
    if (endp == numstr) {
        if (errstr) |p| p.* = "invalid";
        return minval;
    }
    if (value < minval) {
        if (errstr) |p| p.* = "too small";
        return minval;
    }
    if (value > maxval) {
        if (errstr) |p| p.* = "too large";
        return maxval;
    }
    if (errstr) |p| p.* = null;
    return value;
}

pub export fn strncasecmp_l(s1: [*:0]const u8, s2: [*:0]const u8, n: usize, _: ?*anyopaque) c_int {
    return strncasecmp(s1, s2, n);
}

pub export fn strtol_l(s: [*:0]const u8, endp: ?*[*:0]const u8, base: c_int, _: ?*anyopaque) c_long {
    return strtol(s, endp, base);
}

pub export fn strtod_l(s: [*:0]const u8, endp: ?*[*:0]const u8, _: ?*anyopaque) f64 {
    return strtod(s, endp);
}

pub export fn isdigit(c: c_int) c_int {
    return if (c >= '0' and c <= '9') 1 else 0;
}

pub export fn isspace(c: c_int) c_int {
    return if (std.ascii.isWhitespace(@intCast(c))) 1 else 0;
}

pub export fn isxdigit(c: c_int) c_int {
    const ch = @as(u8, @intCast(c));
    return if ((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F')) 1 else 0;
}

// ── strncpy / fortified (_chk) variants ────────────────────────────────
// The _chk variants add a destination-buffer-size check on top of the
// normal libc call; since this loader has no real buffer-overflow
// detection infrastructure yet, they just forward to the unchecked
// implementation after a best-effort bounds check.

pub export fn strcat(dst: [*:0]u8, src: [*:0]const u8) [*:0]u8 {
    const dst_len = C.cstrLen(dst);
    _ = strlcpy(dst[dst_len..], src, std.math.maxInt(usize));
    return dst;
}

pub export fn strncat(dst: [*:0]u8, src: [*:0]const u8, n: usize) [*:0]u8 {
    const dst_len = C.cstrLen(dst);
    var i: usize = 0;
    while (i < n and src[i] != 0) : (i += 1) {
        dst[dst_len + i] = src[i];
    }
    dst[dst_len + i] = 0;
    return dst;
}

pub export fn strncpy(dst: [*]u8, src: [*:0]const u8, n: usize) [*]u8 {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = src[i];
        dst[i] = c;
        if (c == 0) break;
    }
    while (i < n) : (i += 1) dst[i] = 0;
    return dst;
}

pub export fn __memcpy_chk(dst: ?*anyopaque, src: ?*const anyopaque, len: usize, dstlen: usize) ?*anyopaque {
    _ = dstlen;
    return memcpy(dst, src, len);
}

pub export fn __memmove_chk(dst: ?*anyopaque, src: ?*const anyopaque, len: usize, dstlen: usize) ?*anyopaque {
    _ = dstlen;
    return memmove(dst, src, len);
}

pub export fn __memset_chk(dst: ?*anyopaque, value: c_int, len: usize, dstlen: usize) ?*anyopaque {
    _ = dstlen;
    return memset(dst, value, len);
}

pub export fn __strlcat_chk(dst: [*:0]u8, src: [*:0]const u8, dstsize: usize, dstlen: usize) usize {
    _ = dstlen;
    return strlcat(dst, src, dstsize);
}

pub export fn __strlcpy_chk(dst: [*]u8, src: [*:0]const u8, dstsize: usize, dstlen: usize) usize {
    _ = dstlen;
    return strlcpy(dst, src, dstsize);
}

pub export fn __strncpy_chk(dst: [*]u8, src: [*:0]const u8, n: usize, dstlen: usize) [*]u8 {
    _ = dstlen;
    return strncpy(dst, src, n);
}
