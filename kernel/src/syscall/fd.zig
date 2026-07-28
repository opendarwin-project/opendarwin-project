const usercopy = @import("usercopy.zig");
const sched = @import("../proc/sched.zig");
const vfs = @import("../fs/vfs.zig");
const namei = @import("../fs/namei.zig");

const MAX_FDS = 64;
const BUF_SIZE = 4096;
const EBADF: i64 = 9;
const EAGAIN: i64 = 35;
const EINVAL: i64 = 22;
const EAFNOSUPPORT: i64 = 47;
const ENFILE: i64 = 23;
const ENOENT: i64 = 2;
const EISDIR: i64 = 21;
const EFAULT: i64 = 14;
const EROFS: i64 = 30;

const O_ACCMODE: u32 = 0x3;
const O_RDONLY: u32 = 0;
const O_WRONLY: u32 = 1;
const O_RDWR: u32 = 2;
const O_DIRECTORY: u32 = 0x100000;

const SEEK_SET: i32 = 0;
const SEEK_CUR: i32 = 1;
const SEEK_END: i32 = 2;

const Kind = enum { free, socket, vnode };

const Socket = struct {
    peer: u32 = 0,
    buf: [BUF_SIZE]u8 = undefined,
    head: usize = 0,
    len: usize = 0,
};

const VnodeFile = struct {
    vp: ?*vfs.Vnode = null,
    offset: u64 = 0,
    flags: u32 = 0,
};

const File = struct {
    kind: Kind = .free,
    socket: Socket = .{},
    vnode: VnodeFile = .{},
};

var files: [MAX_FDS]File = [_]File{.{}} ** MAX_FDS;

fn neg(errno: i64) u64 {
    return @bitCast(-errno);
}

fn allocFdSlot() ?u32 {
    var i: u32 = 3;
    while (i < MAX_FDS) : (i += 1) {
        if (files[i].kind == .free) return i;
    }
    return null;
}

fn allocFd() ?u32 {
    const i = allocFdSlot() orelse return null;
    files[i] = .{ .kind = .socket, .socket = .{} };
    return i;
}

fn validSocket(fd: u64) ?u32 {
    if (fd >= MAX_FDS) return null;
    const idx: u32 = @intCast(fd);
    if (files[idx].kind != .socket) return null;
    return idx;
}

fn validVnode(fd: u64) ?u32 {
    if (fd >= MAX_FDS) return null;
    const idx: u32 = @intCast(fd);
    if (files[idx].kind != .vnode) return null;
    return idx;
}

pub fn isSocket(fd: u64) bool {
    return validSocket(fd) != null;
}

pub fn wouldBlock(ret: u64) bool {
    return ret == neg(EAGAIN);
}

pub fn socketpair(sv_addr: u64) u64 {
    if (sv_addr == 0) return neg(EINVAL);
    const a = allocFd() orelse return neg(ENFILE);
    const b = allocFd() orelse {
        files[a] = .{};
        return neg(ENFILE);
    };
    files[a].socket.peer = b;
    files[b].socket.peer = a;
    const sv = [2]i32{ @intCast(a), @intCast(b) };
    if (!usercopy.copyOut([2]i32, sv_addr, sv)) {
        files[a] = .{};
        files[b] = .{};
        return neg(EINVAL);
    }
    return 0;
}

pub fn socket(domain: u64, _: u64, _: u64) u64 {
    if (domain != 1) return neg(EAFNOSUPPORT);
    const fd = allocFd() orelse return neg(ENFILE);
    files[fd].socket.peer = fd;
    return fd;
}

pub fn open(path_addr: u64, flags: u64, _: u64) u64 {
    var path_buf: [namei.max_path]u8 = undefined;
    const path = namei.copyinPath(path_addr, &path_buf) orelse return neg(EFAULT);
    const fl: u32 = @truncate(flags);
    const acc = fl & O_ACCMODE;
    if (acc == O_WRONLY or acc == O_RDWR) return neg(EROFS);

    const vp = namei.lookup(path) orelse return neg(ENOENT);
    if ((fl & O_DIRECTORY) != 0 and vp.typ != .dir) {
        vfs.vrele(vp);
        return neg(ENOENT); // Darwin uses ENOTDIR; ENOENT is fine for now
    }
    if (vp.typ == .dir and acc != O_RDONLY) {
        // Opening a directory for read is allowed (getdirentries later);
        // write modes already rejected above.
    }
    if (vp.typ != .reg and vp.typ != .dir) {
        vfs.vrele(vp);
        return neg(ENOENT);
    }

    const fd = allocFdSlot() orelse {
        vfs.vrele(vp);
        return neg(ENFILE);
    };
    files[fd] = .{
        .kind = .vnode,
        .vnode = .{ .vp = vp, .offset = 0, .flags = fl },
    };
    return fd;
}

pub fn close(fd: u64) ?u64 {
    if (validSocket(fd)) |idx| {
        const peer = files[idx].socket.peer;
        files[idx] = .{};
        if (peer < MAX_FDS and files[peer].kind == .socket and files[peer].socket.peer == idx) {
            files[peer].socket.peer = peer;
        }
        return 0;
    }
    if (validVnode(fd)) |idx| {
        if (files[idx].vnode.vp) |vp| vfs.vrele(vp);
        files[idx] = .{};
        return 0;
    }
    // stdin/out/err and unknown: success for close of stdio, EBADF otherwise
    if (fd <= 2) return 0;
    return neg(EBADF);
}

pub fn write(fd: u64, buf_addr: u64, len: u64) ?u64 {
    if (validSocket(fd)) |idx| {
        if (buf_addr == 0 and len != 0) return neg(EINVAL);
        const peer = files[idx].socket.peer;
        if (peer >= MAX_FDS or files[peer].kind != .socket) return neg(EBADF);
        var s = &files[peer].socket;
        const available = BUF_SIZE - s.len;
        const n: usize = @intCast(@min(len, available));
        if (n == 0 and len != 0) return neg(EAGAIN);
        var tmp: [BUF_SIZE]u8 = undefined;
        if (n != 0 and !usercopy.copyBytesIn(tmp[0..n], buf_addr)) return neg(EINVAL);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const pos = (s.head + s.len) % BUF_SIZE;
            s.buf[pos] = tmp[i];
            s.len += 1;
        }
        if (n != 0) _ = sched.wakeFd(peer);
        return n;
    }
    if (validVnode(fd) != null) return neg(EROFS);
    return null;
}

pub fn read(fd: u64, buf_addr: u64, len: u64) ?u64 {
    if (validSocket(fd)) |idx| {
        if (buf_addr == 0 and len != 0) return neg(EINVAL);
        var s = &files[idx].socket;
        if (s.len == 0) return neg(EAGAIN);
        const n: usize = @intCast(@min(len, s.len));
        var tmp: [BUF_SIZE]u8 = undefined;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            tmp[i] = s.buf[s.head];
            s.head = (s.head + 1) % BUF_SIZE;
            s.len -= 1;
        }
        if (n != 0 and !usercopy.copyBytesOut(buf_addr, tmp[0..n])) return neg(EINVAL);
        return n;
    }
    if (validVnode(fd)) |idx| {
        const vf = &files[idx].vnode;
        const vp = vf.vp orelse return neg(EBADF);
        if (vp.typ == .dir) return neg(EISDIR);
        if (buf_addr == 0 and len != 0) return neg(EINVAL);
        if (len == 0) return 0;

        // Read in BUF_SIZE chunks to bound kernel stack.
        var total: u64 = 0;
        var remaining = len;
        while (remaining > 0) {
            var tmp: [BUF_SIZE]u8 = undefined;
            const chunk: usize = @intCast(@min(remaining, BUF_SIZE));
            const n = vfs.vopRead(vp, vf.offset, tmp[0..chunk]);
            if (n < 0) return neg(-n);
            if (n == 0) break;
            const got: usize = @intCast(n);
            if (!usercopy.copyBytesOut(buf_addr + total, tmp[0..got])) return neg(EFAULT);
            vf.offset += @intCast(got);
            total += @intCast(got);
            remaining -= @intCast(got);
            if (got < chunk) break;
        }
        return total;
    }
    return null;
}

pub fn lseek(fd: u64, offset: i64, whence: i32) u64 {
    const idx = validVnode(fd) orelse return neg(EBADF);
    const vf = &files[idx].vnode;
    const vp = vf.vp orelse return neg(EBADF);
    var attr: vfs.Vattr = .{};
    if (vfs.vopGetattr(vp, &attr) != 0) return neg(EINVAL);

    const base: i64 = switch (whence) {
        SEEK_SET => 0,
        SEEK_CUR => @intCast(vf.offset),
        SEEK_END => @intCast(attr.size),
        else => return neg(EINVAL),
    };
    const next = base + offset;
    if (next < 0) return neg(EINVAL);
    vf.offset = @intCast(next);
    return vf.offset;
}

pub fn fstat(fd: u64, ub: u64) u64 {
    const idx = validVnode(fd) orelse return neg(EBADF);
    const vp = files[idx].vnode.vp orelse return neg(EBADF);
    var attr: vfs.Vattr = .{};
    if (vfs.vopGetattr(vp, &attr) != 0) return neg(EINVAL);
    const st = vfs.attrToStat(&attr);
    if (!usercopy.copyOut(vfs.Stat64, ub, st)) return neg(EFAULT);
    return 0;
}

pub fn stat(path_addr: u64, ub: u64) u64 {
    var path_buf: [namei.max_path]u8 = undefined;
    const path = namei.copyinPath(path_addr, &path_buf) orelse return neg(EFAULT);
    const vp = namei.lookup(path) orelse return neg(ENOENT);
    defer vfs.vrele(vp);
    var attr: vfs.Vattr = .{};
    if (vfs.vopGetattr(vp, &attr) != 0) return neg(EINVAL);
    const st = vfs.attrToStat(&attr);
    if (!usercopy.copyOut(vfs.Stat64, ub, st)) return neg(EFAULT);
    return 0;
}

pub fn getsockname(fd: u64, addr: u64, len_addr: u64) u64 {
    _ = validSocket(fd) orelse return neg(EBADF);
    if (addr != 0) {
        const n: u32 = if (len_addr != 0) usercopy.copyIn(u32, len_addr) orelse 0 else 16;
        var zeroes = [_]u8{0} ** 16;
        const out_len: usize = @intCast(@min(n, 16));
        if (!usercopy.copyBytesOut(addr, zeroes[0..out_len])) return neg(EINVAL);
        if (len_addr != 0 and !usercopy.copyOut(u32, len_addr, @intCast(out_len))) return neg(EINVAL);
    }
    return 0;
}
