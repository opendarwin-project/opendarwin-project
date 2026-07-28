//! BSD-style pathname lookup (`namei`).
//!
//! Resolves an absolute path (or a path relative to the root mount) to a
//! referenced vnode. Components `.` and empty segments are skipped; `..`
//! walks via `lookup("..")`. No credentials / symlink following yet.

const vfs = @import("vfs.zig");
const usercopy = @import("../syscall/usercopy.zig");

const MAX_PATH = 1024;

/// Look up `path` starting at the root vnode. Returns a referenced vnode, or
/// null on failure.
pub fn lookup(path: []const u8) ?*vfs.Vnode {
    const root = vfs.rootVnode() orelse return null;
    return lookupat(root, path);
}

/// Look up `path` relative to directory `dvp`.
pub fn lookupat(dvp: *vfs.Vnode, path: []const u8) ?*vfs.Vnode {
    if (path.len == 0) {
        vfs.vref(dvp);
        return dvp;
    }

    var start = dvp;
    var rest = path;
    if (path[0] == '/' or path[0] == '\\') {
        start = vfs.rootVnode() orelse return null;
        rest = trimLeftSep(path);
    }

    vfs.vref(start);
    var cur: *vfs.Vnode = start;

    var i: usize = 0;
    while (i < rest.len) {
        while (i < rest.len and isSep(rest[i])) : (i += 1) {}
        if (i >= rest.len) break;

        const begin = i;
        while (i < rest.len and !isSep(rest[i])) : (i += 1) {}
        const name = rest[begin..i];
        if (name.len == 0 or (name.len == 1 and name[0] == '.')) continue;

        var next: ?*vfs.Vnode = null;
        const err = vfs.vopLookup(cur, name, &next);
        vfs.vrele(cur);
        if (err != 0 or next == null) return null;
        cur = next.?;
    }

    return cur;
}

fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

fn trimLeftSep(path: []const u8) []const u8 {
    var i: usize = 0;
    while (i < path.len and isSep(path[i])) : (i += 1) {}
    return path[i..];
}

/// Copy a NUL-terminated user path into `buf`. Returns the slice, or null.
pub fn copyinPath(user_addr: u64, buf: *[MAX_PATH]u8) ?[]const u8 {
    if (user_addr == 0) return null;
    var n: usize = 0;
    while (n < MAX_PATH) : (n += 1) {
        var byte: [1]u8 = undefined;
        if (!usercopy.copyBytesIn(byte[0..], user_addr + n)) return null;
        if (byte[0] == 0) break;
        buf[n] = byte[0];
    }
    if (n == MAX_PATH) return null;
    return buf[0..n];
}

pub const max_path = MAX_PATH;
