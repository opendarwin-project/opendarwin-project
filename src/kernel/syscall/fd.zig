const usercopy = @import("usercopy.zig");
const sched = @import("../proc/sched.zig");

const MAX_FDS = 64;
const BUF_SIZE = 4096;
const EBADF: i64 = 9;
const EAGAIN: i64 = 35;
const EINVAL: i64 = 22;
const EAFNOSUPPORT: i64 = 47;
const ENFILE: i64 = 23;

const Kind = enum { free, socket };

const Socket = struct {
    peer: u32 = 0,
    buf: [BUF_SIZE]u8 = undefined,
    head: usize = 0,
    len: usize = 0,
};

const File = struct {
    kind: Kind = .free,
    socket: Socket = .{},
};

var files: [MAX_FDS]File = [_]File{.{}} ** MAX_FDS;

fn neg(errno: i64) u64 {
    return @bitCast(-errno);
}

fn allocFd() ?u32 {
    var i: u32 = 3;
    while (i < MAX_FDS) : (i += 1) {
        if (files[i].kind == .free) {
            files[i] = .{ .kind = .socket, .socket = .{} };
            return i;
        }
    }
    return null;
}

fn validSocket(fd: u64) ?u32 {
    if (fd >= MAX_FDS) return null;
    const idx: u32 = @intCast(fd);
    if (files[idx].kind != .socket) return null;
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
    // AF_UNIX only for now; enough for std.Io's internal wake socketpair style paths.
    if (domain != 1) return neg(EAFNOSUPPORT);
    const fd = allocFd() orelse return neg(ENFILE);
    files[fd].socket.peer = fd;
    return fd;
}

pub fn close(fd: u64) ?u64 {
    const idx = validSocket(fd) orelse return null;
    const peer = files[idx].socket.peer;
    files[idx] = .{};
    if (peer < MAX_FDS and files[peer].kind == .socket and files[peer].socket.peer == idx) {
        files[peer].socket.peer = peer;
    }
    return 0;
}

pub fn write(fd: u64, buf_addr: u64, len: u64) ?u64 {
    const idx = validSocket(fd) orelse return null;
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

pub fn read(fd: u64, buf_addr: u64, len: u64) ?u64 {
    const idx = validSocket(fd) orelse return null;
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
