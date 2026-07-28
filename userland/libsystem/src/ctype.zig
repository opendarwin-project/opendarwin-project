//! Character classification and case mapping (ctype.h).

const std = @import("std");

fn toU8(c: c_int) u8 {
    return @intCast(c);
}

pub export fn isalnum(c: c_int) c_int {
    const ch = toU8(c);
    return if (std.ascii.isAlphanumeric(ch)) 1 else 0;
}

pub export fn isalpha(c: c_int) c_int {
    const ch = toU8(c);
    return if (std.ascii.isAlphabetic(ch)) 1 else 0;
}

pub export fn isascii(c: c_int) c_int {
    return if (c >= 0 and c <= 0x7f) 1 else 0;
}

pub export fn isblank(c: c_int) c_int {
    const ch = toU8(c);
    return if (ch == ' ' or ch == '\t') 1 else 0;
}

pub export fn iscntrl(c: c_int) c_int {
    const ch = toU8(c);
    return if ((ch < 0x20) or ch == 0x7f) 1 else 0;
}

pub export fn isgraph(c: c_int) c_int {
    const ch = toU8(c);
    return if (ch >= 0x21 and ch <= 0x7e) 1 else 0;
}

pub export fn islower(c: c_int) c_int {
    const ch = toU8(c);
    return if (std.ascii.isLower(ch)) 1 else 0;
}

pub export fn isprint(c: c_int) c_int {
    const ch = toU8(c);
    return if (ch >= 0x20 and ch <= 0x7e) 1 else 0;
}

pub export fn ispunct(c: c_int) c_int {
    const ch = toU8(c);
    return if (isgraph(c) != 0 and !std.ascii.isAlphanumeric(ch)) 1 else 0;
}

pub export fn isupper(c: c_int) c_int {
    const ch = toU8(c);
    return if (std.ascii.isUpper(ch)) 1 else 0;
}

pub export fn tolower(c: c_int) c_int {
    return @intCast(std.ascii.toLower(toU8(c)));
}

pub export fn toupper(c: c_int) c_int {
    return @intCast(std.ascii.toUpper(toU8(c)));
}
