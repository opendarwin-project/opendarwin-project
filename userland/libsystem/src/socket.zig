//! Socket operations: socket, socketpair, connect, bind, listen, accept,
//! shutdown, setsockopt, getsockname, recvmsg, sendmsg, getaddrinfo, etc.

const common = @import("common.zig");
const C = common;

pub export fn socket(domain: c_int, typ: c_int, protocol: c_int) c_int {
    const ret = C.darwinSyscall3(C.SYS_socket, @intCast(domain), @intCast(typ), @intCast(protocol));
    return @intCast(C.setErrnoFromNegative(ret));
}

pub export fn socketpair(domain: c_int, typ: c_int, protocol: c_int, sv: *[2]c_int) c_int {
    const ret = C.darwinSyscall5(C.SYS_socketpair, @intCast(domain), @intCast(typ), @intCast(protocol), @intFromPtr(sv), 0);
    return @intCast(C.setErrnoFromNegative(ret));
}

pub export fn connect(_: c_int, _: ?*const anyopaque, _: u32) c_int {
    return C.stubErr("connect");
}

pub export fn bind(_: c_int, _: ?*const anyopaque, _: u32) c_int {
    return C.stubErr("bind");
}

pub export fn listen(_: c_int, _: c_int) c_int {
    return C.stubErr("listen");
}

pub export fn accept(_: c_int, _: ?*anyopaque, _: ?*u32) c_int {
    return C.stubErr("accept");
}

pub export fn shutdown(_: c_int, _: c_int) c_int {
    return C.stubErr("shutdown");
}

pub export fn setsockopt(_: c_int, _: c_int, _: c_int, _: ?*const anyopaque, _: u32) c_int {
    return C.stubErr("setsockopt");
}

pub export fn getsockopt(_: c_int, _: c_int, _: c_int, _: ?*anyopaque, _: ?*u32) c_int {
    return C.stubErr("getsockopt");
}

pub export fn getsockname(fd: c_int, addr: ?*anyopaque, len: ?*u32) c_int {
    const ret = C.darwinSyscall3(C.SYS_getsockname, @intCast(fd), @intFromPtr(addr orelse null), @intFromPtr(len orelse null));
    return @intCast(C.setErrnoFromNegative(ret));
}

pub export fn getpeername(_: c_int, _: ?*anyopaque, _: ?*u32) c_int {
    return C.stubErr("getpeername");
}

pub export fn recvmsg(_: c_int, _: ?*anyopaque, _: c_int) isize {
    return @intCast(C.stubErr("recvmsg"));
}

pub export fn sendmsg(_: c_int, _: ?*const anyopaque, _: c_int) isize {
    return @intCast(C.stubErr("sendmsg"));
}

pub export fn sendfile(_: c_int, _: c_int, _: i64, _: *i64, _: ?*anyopaque, _: c_int) c_int {
    return C.stubErr("sendfile");
}

pub export fn recv(_: c_int, _: ?*anyopaque, _: usize, _: c_int) isize {
    return @intCast(C.stubErr("recv"));
}

pub export fn send(_: c_int, _: ?*const anyopaque, _: usize, _: c_int) isize {
    return @intCast(C.stubErr("send"));
}

pub export fn recvfrom(_: c_int, _: ?*anyopaque, _: usize, _: c_int, _: ?*anyopaque, _: ?*u32) isize {
    return @intCast(C.stubErr("recvfrom"));
}

pub export fn sendto(_: c_int, _: ?*const anyopaque, _: usize, _: c_int, _: ?*const anyopaque, _: u32) isize {
    return @intCast(C.stubErr("sendto"));
}

// ── DNS resolution stubs ───────────────────────────────────────────────

pub export fn getaddrinfo(_: ?[*:0]const u8, _: ?[*:0]const u8, _: ?*const anyopaque, _: ?*?*anyopaque) c_int {
    return C.stubErr("getaddrinfo");
}

pub export fn freeaddrinfo(_: ?*anyopaque) void {
    C.reportStub("freeaddrinfo");
}

pub export fn getnameinfo(_: ?*const anyopaque, _: u32, _: [*]u8, _: u32, _: [*]u8, _: u32, _: c_int) c_int {
    return C.stubErr("getnameinfo");
}

pub export fn if_nametoindex(_: [*:0]const u8) u32 {
    _ = C.stubErr("if_nametoindex");
    return 0;
}

pub export fn if_indextoname(_: u32, _: [*]u8) ?[*:0]const u8 {
    _ = C.stubErr("if_indextoname");
    return null;
}

pub export fn inet_ntop(_: c_int, _: ?*const anyopaque, _: [*]u8, _: u32) ?[*:0]const u8 {
    _ = C.stubErr("inet_ntop");
    return null;
}

pub export fn inet_pton(_: c_int, _: [*:0]const u8, _: ?*anyopaque) c_int {
    return C.stubErr("inet_pton");
}

pub export fn inet_addr(_: [*:0]const u8) u32 {
    return 0;
}
