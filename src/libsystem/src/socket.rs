//! Socket operations: socket, socketpair, connect, bind, listen, accept,
//! shutdown, setsockopt, getsockname, recvmsg, sendmsg, getaddrinfo, etc.

use core::ffi::{c_char, c_int, c_void};

use crate::common;

#[unsafe(no_mangle)]
pub unsafe extern "C" fn socket(domain: c_int, typ: c_int, protocol: c_int) -> c_int {
    let ret = common::darwinSyscall3(
        common::SYS_socket,
        domain as usize,
        typ as usize,
        protocol as usize,
    );
    common::setErrnoFromNegative(ret)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn socketpair(
    domain: c_int,
    typ: c_int,
    protocol: c_int,
    sv: *mut [c_int; 2],
) -> c_int {
    let ret = common::darwinSyscall5(
        common::SYS_socketpair,
        domain as usize,
        typ as usize,
        protocol as usize,
        sv as usize,
        0,
    );
    common::setErrnoFromNegative(ret)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn connect(_fd: c_int, _addr: *const c_void, _len: u32) -> c_int {
    common::stubErr("connect")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn bind(_fd: c_int, _addr: *const c_void, _len: u32) -> c_int {
    common::stubErr("bind")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn listen(_fd: c_int, _backlog: c_int) -> c_int {
    common::stubErr("listen")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn accept(_fd: c_int, _addr: *mut c_void, _len: *mut u32) -> c_int {
    common::stubErr("accept")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn shutdown(_fd: c_int, _how: c_int) -> c_int {
    common::stubErr("shutdown")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn setsockopt(
    _fd: c_int,
    _level: c_int,
    _optname: c_int,
    _optval: *const c_void,
    _optlen: u32,
) -> c_int {
    common::stubErr("setsockopt")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getsockopt(
    _fd: c_int,
    _level: c_int,
    _optname: c_int,
    _optval: *mut c_void,
    _optlen: *mut u32,
) -> c_int {
    common::stubErr("getsockopt")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getsockname(fd: c_int, addr: *mut c_void, len: *mut u32) -> c_int {
    let ret = common::darwinSyscall3(
        common::SYS_getsockname,
        fd as usize,
        addr as usize,
        len as usize,
    );
    common::setErrnoFromNegative(ret)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getpeername(_fd: c_int, _addr: *mut c_void, _len: *mut u32) -> c_int {
    common::stubErr("getpeername")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn recvmsg(_fd: c_int, _msg: *mut c_void, _flags: c_int) -> isize {
    common::stubErr("recvmsg") as isize
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sendmsg(_fd: c_int, _msg: *const c_void, _flags: c_int) -> isize {
    common::stubErr("sendmsg") as isize
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sendfile(
    _fd: c_int,
    _s: c_int,
    _offset: i64,
    _len: *mut i64,
    _hdtr: *mut c_void,
    _flags: c_int,
) -> c_int {
    common::stubErr("sendfile")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn recv(_fd: c_int, _buf: *mut c_void, _len: usize, _flags: c_int) -> isize {
    common::stubErr("recv") as isize
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn send(
    _fd: c_int,
    _buf: *const c_void,
    _len: usize,
    _flags: c_int,
) -> isize {
    common::stubErr("send") as isize
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn recvfrom(
    _fd: c_int,
    _buf: *mut c_void,
    _len: usize,
    _flags: c_int,
    _from: *mut c_void,
    _fromlen: *mut u32,
) -> isize {
    common::stubErr("recvfrom") as isize
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sendto(
    _fd: c_int,
    _buf: *const c_void,
    _len: usize,
    _flags: c_int,
    _to: *const c_void,
    _tolen: u32,
) -> isize {
    common::stubErr("sendto") as isize
}

// ── DNS resolution stubs ───────────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getaddrinfo(
    _hostname: *const c_char,
    _servname: *const c_char,
    _hints: *const c_void,
    _res: *mut *mut c_void,
) -> c_int {
    common::stubErr("getaddrinfo")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn freeaddrinfo(_ai: *mut c_void) {
    common::reportStub("freeaddrinfo");
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getnameinfo(
    _sa: *const c_void,
    _salen: u32,
    _host: *mut u8,
    _hostlen: u32,
    _serv: *mut u8,
    _servlen: u32,
    _flags: c_int,
) -> c_int {
    common::stubErr("getnameinfo")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn if_nametoindex(_ifname: *const c_char) -> u32 {
    let _ = common::stubErr("if_nametoindex");
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn if_indextoname(_ifindex: u32, _ifname: *mut u8) -> *const c_char {
    let _ = common::stubErr("if_indextoname");
    core::ptr::null()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn inet_ntop(
    _af: c_int,
    _src: *const c_void,
    _dst: *mut u8,
    _size: u32,
) -> *const c_char {
    let _ = common::stubErr("inet_ntop");
    core::ptr::null()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn inet_pton(_af: c_int, _src: *const c_char, _dst: *mut c_void) -> c_int {
    common::stubErr("inet_pton")
}

#[unsafe(no_mangle)]
pub extern "C" fn inet_addr(_cp: *const c_char) -> u32 {
    0
}
