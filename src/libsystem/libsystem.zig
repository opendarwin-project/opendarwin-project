//! Minimal FOSS libSystem/libsystem_c replacement for OpenDarwin userland.
//!
//! This is intentionally tiny: enough symbols for the first simple Darwin
//! Mach-O smoke binaries while the kernel grows real dylib loading support.
//! It must not depend on Apple's libSystem.

const usize_max = ~@as(usize, 0);

pub export var errno: c_int = 0;
pub export var __dyld_private: usize = 0;

const SYS_exit: usize = 1;
const SYS_write: usize = 4;

fn darwinSyscall3(number: usize, arg0: usize, arg1: usize, arg2: usize) usize {
    return asm volatile (
        \\mov x16, %[number]
        \\svc #0x80
        : [ret] "={x0}" (-> usize),
        : [number] "r" (number),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
          [arg2] "{x2}" (arg2),
    );
}

fn setErrnoFromNegative(ret: usize) c_int {
    // OpenDarwin's early syscall layer currently returns simple integer
    // results. Treat small negative values as errno-style failures so callers
    // see the libc convention once the kernel starts returning them.
    if (ret > usize_max - 4096) {
        errno = @intCast(0 -% ret);
        return -1;
    }
    return @intCast(ret);
}

pub export fn syscall(number: c_long, arg0: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) c_long {
    _ = arg3;
    _ = arg4;
    _ = arg5;
    return @intCast(darwinSyscall3(@intCast(number), arg0, arg1, arg2));
}

pub export fn write(fd: c_int, buf: [*]const u8, len: usize) isize {
    const ret = darwinSyscall3(SYS_write, @intCast(fd), @intFromPtr(buf), len);
    return @intCast(setErrnoFromNegative(ret));
}

pub export fn __error() *c_int {
    return &errno;
}

pub export fn _exit(status: c_int) noreturn {
    _ = darwinSyscall3(SYS_exit, @intCast(status), 0, 0);
    while (true) asm volatile ("wfe");
}

pub export fn exit(status: c_int) noreturn {
    _exit(status);
}

pub export fn dyld_stub_binder() void {
    // Placeholder for binaries that still carry a lazy-bind helper reference.
    // The kernel loader should eagerly bind for the first milestone, so reaching
    // this function means a lazy symbol escaped resolution.
    _exit(127);
}

fn cstrLen(s: [*:0]const u8) usize {
    var n: usize = 0;
    while (s[n] != 0) : (n += 1) {}
    return n;
}

fn reportStub(comptime name: []const u8) void {
    const prefix = "libSystem stub: ";
    const suffix = "\n";
    _ = darwinSyscall3(SYS_write, 2, @intFromPtr(prefix.ptr), prefix.len);
    _ = darwinSyscall3(SYS_write, 2, @intFromPtr(name.ptr), name.len);
    _ = darwinSyscall3(SYS_write, 2, @intFromPtr(suffix.ptr), suffix.len);
}

fn stubErr(comptime name: []const u8) c_int {
    reportStub(name);
    errno = 78; // ENOSYS on Darwin
    return -1;
}

fn stubUsize(comptime name: []const u8) usize {
    _ = stubErr(name);
    return usize_max;
}

fn stubNull(comptime name: []const u8) ?*anyopaque {
    _ = stubErr(name);
    return null;
}

pub export fn abort() noreturn {
    reportStub("abort");
    _exit(134);
}
pub export fn malloc(_: usize) ?*anyopaque {
    return stubNull("malloc");
}
pub export fn realloc(_: ?*anyopaque, _: usize) ?*anyopaque {
    return stubNull("realloc");
}
pub export fn free(_: ?*anyopaque) void {
    reportStub("free");
}
pub export fn malloc_size(_: ?*anyopaque) usize {
    reportStub("malloc_size");
    return 0;
}
pub export fn posix_memalign(_: *?*anyopaque, _: usize, _: usize) c_int {
    return stubErr("posix_memalign");
}
pub export fn bzero(ptr: [*]u8, len: usize) void {
    @memset(ptr[0..len], 0);
}
pub export fn arc4random_buf(ptr: [*]u8, len: usize) void {
    @memset(ptr[0..len], 0);
    reportStub("arc4random_buf");
}
pub export fn _NSGetExecutablePath(_: [*]u8, _: *u32) c_int {
    return stubErr("_NSGetExecutablePath");
}
pub export fn __availability_version_check(_: u32, _: ?*const anyopaque) c_int {
    reportStub("__availability_version_check");
    return 1;
}
pub export fn __dyld_get_image_header_containing_address(_: ?*const anyopaque) ?*anyopaque {
    return stubNull("__dyld_get_image_header_containing_address");
}
pub export fn _dyld_get_image_header_containing_address(_: ?*const anyopaque) ?*anyopaque {
    return stubNull("_dyld_get_image_header_containing_address");
}
pub export fn _dyld_image_path_containing_address(_: ?*const anyopaque) ?[*:0]const u8 {
    _ = stubErr("_dyld_image_path_containing_address");
    return null;
}
pub export fn __tlv_bootstrap() ?*anyopaque {
    return stubNull("__tlv_bootstrap");
}
pub export fn sys_icache_invalidate(_: ?*anyopaque, _: usize) void {
    reportStub("sys_icache_invalidate");
}

pub export fn open(_: [*:0]const u8, _: c_int, _: c_int) c_int {
    return stubErr("open");
}
pub export fn openat(_: c_int, _: [*:0]const u8, _: c_int, _: c_int) c_int {
    return stubErr("openat");
}
pub export fn close(_: c_int) c_int {
    return stubErr("close");
}
pub export fn @"close$NOCANCEL"(_: c_int) c_int {
    return stubErr("close$NOCANCEL");
}
pub export fn read(_: c_int, _: [*]u8, _: usize) isize {
    return @intCast(stubErr("read"));
}
pub export fn readv(_: c_int, _: ?*const anyopaque, _: c_int) isize {
    return @intCast(stubErr("readv"));
}
pub export fn writev(_: c_int, _: ?*const anyopaque, _: c_int) isize {
    return @intCast(stubErr("writev"));
}
pub export fn pread(_: c_int, _: [*]u8, _: usize, _: i64) isize {
    return @intCast(stubErr("pread"));
}
pub export fn preadv(_: c_int, _: ?*const anyopaque, _: c_int, _: i64) isize {
    return @intCast(stubErr("preadv"));
}
pub export fn pwrite(_: c_int, _: [*]const u8, _: usize, _: i64) isize {
    return @intCast(stubErr("pwrite"));
}
pub export fn pwritev(_: c_int, _: ?*const anyopaque, _: c_int, _: i64) isize {
    return @intCast(stubErr("pwritev"));
}
pub export fn lseek(_: c_int, _: i64, _: c_int) i64 {
    return @intCast(stubErr("lseek"));
}
pub export fn fcntl(_: c_int, _: c_int, _: usize) c_int {
    return stubErr("fcntl");
}
pub export fn ioctl(_: c_int, _: usize, _: usize) c_int {
    return stubErr("ioctl");
}
pub export fn fstat(_: c_int, _: ?*anyopaque) c_int {
    return stubErr("fstat");
}
pub export fn fstatat(_: c_int, _: [*:0]const u8, _: ?*anyopaque, _: c_int) c_int {
    return stubErr("fstatat");
}
pub export fn fsync(_: c_int) c_int {
    return stubErr("fsync");
}
pub export fn ftruncate(_: c_int, _: i64) c_int {
    return stubErr("ftruncate");
}
pub export fn isatty(_: c_int) c_int {
    return stubErr("isatty");
}
pub export fn getcwd(_: [*]u8, _: usize) ?[*]u8 {
    _ = stubErr("getcwd");
    return null;
}
pub export fn chdir(_: [*:0]const u8) c_int {
    return stubErr("chdir");
}
pub export fn fchdir(_: c_int) c_int {
    return stubErr("fchdir");
}
pub export fn mkdirat(_: c_int, _: [*:0]const u8, _: c_int) c_int {
    return stubErr("mkdirat");
}
pub export fn unlinkat(_: c_int, _: [*:0]const u8, _: c_int) c_int {
    return stubErr("unlinkat");
}
pub export fn renameat(_: c_int, _: [*:0]const u8, _: c_int, _: [*:0]const u8) c_int {
    return stubErr("renameat");
}
pub export fn linkat(_: c_int, _: [*:0]const u8, _: c_int, _: [*:0]const u8, _: c_int) c_int {
    return stubErr("linkat");
}
pub export fn symlinkat(_: [*:0]const u8, _: c_int, _: [*:0]const u8) c_int {
    return stubErr("symlinkat");
}
pub export fn readlinkat(_: c_int, _: [*:0]const u8, _: [*]u8, _: usize) isize {
    return @intCast(stubErr("readlinkat"));
}
pub export fn faccessat(_: c_int, _: [*:0]const u8, _: c_int, _: c_int) c_int {
    return stubErr("faccessat");
}
pub export fn @"realpath$DARWIN_EXTSN"(_: [*:0]const u8, _: [*]u8) ?[*]u8 {
    _ = stubErr("realpath$DARWIN_EXTSN");
    return null;
}
pub export fn __getdirentries64(_: c_int, _: [*]u8, _: usize, _: *i64) isize {
    return @intCast(stubErr("__getdirentries64"));
}

pub export fn mmap(_: ?*anyopaque, _: usize, _: c_int, _: c_int, _: c_int, _: i64) ?*anyopaque {
    return stubNull("mmap");
}
pub export fn munmap(_: ?*anyopaque, _: usize) c_int {
    return stubErr("munmap");
}
pub export fn clock_gettime(_: c_int, _: ?*anyopaque) c_int {
    return stubErr("clock_gettime");
}
pub export fn clock_getres(_: c_int, _: ?*anyopaque) c_int {
    return stubErr("clock_getres");
}
pub export fn nanosleep(_: ?*const anyopaque, _: ?*anyopaque) c_int {
    return stubErr("nanosleep");
}
pub export fn getpid() c_int {
    return stubErr("getpid");
}
pub export fn kill(_: c_int, _: c_int) c_int {
    return stubErr("kill");
}
pub export fn fork() c_int {
    return stubErr("fork");
}
pub export fn execve(_: [*:0]const u8, _: ?*const anyopaque, _: ?*const anyopaque) c_int {
    return stubErr("execve");
}
pub export fn wait4(_: c_int, _: *c_int, _: c_int, _: ?*anyopaque) c_int {
    return stubErr("wait4");
}
pub export fn setpgid(_: c_int, _: c_int) c_int {
    return stubErr("setpgid");
}
pub export fn setregid(_: c_int, _: c_int) c_int {
    return stubErr("setregid");
}
pub export fn setreuid(_: c_int, _: c_int) c_int {
    return stubErr("setreuid");
}
pub export fn sigemptyset(_: ?*anyopaque) c_int {
    return stubErr("sigemptyset");
}
pub export fn sigaction(_: c_int, _: ?*const anyopaque, _: ?*anyopaque) c_int {
    return stubErr("sigaction");
}
pub export fn sigaltstack(_: ?*const anyopaque, _: ?*anyopaque) c_int {
    return stubErr("sigaltstack");
}

pub export fn socket(_: c_int, _: c_int, _: c_int) c_int {
    return stubErr("socket");
}
pub export fn socketpair(_: c_int, _: c_int, _: c_int, _: *[2]c_int) c_int {
    return stubErr("socketpair");
}
pub export fn connect(_: c_int, _: ?*const anyopaque, _: u32) c_int {
    return stubErr("connect");
}
pub export fn bind(_: c_int, _: ?*const anyopaque, _: u32) c_int {
    return stubErr("bind");
}
pub export fn listen(_: c_int, _: c_int) c_int {
    return stubErr("listen");
}
pub export fn accept(_: c_int, _: ?*anyopaque, _: ?*u32) c_int {
    return stubErr("accept");
}
pub export fn shutdown(_: c_int, _: c_int) c_int {
    return stubErr("shutdown");
}
pub export fn setsockopt(_: c_int, _: c_int, _: c_int, _: ?*const anyopaque, _: u32) c_int {
    return stubErr("setsockopt");
}
pub export fn getsockname(_: c_int, _: ?*anyopaque, _: ?*u32) c_int {
    return stubErr("getsockname");
}
pub export fn recvmsg(_: c_int, _: ?*anyopaque, _: c_int) isize {
    return @intCast(stubErr("recvmsg"));
}
pub export fn sendmsg(_: c_int, _: ?*const anyopaque, _: c_int) isize {
    return @intCast(stubErr("sendmsg"));
}
pub export fn sendfile(_: c_int, _: c_int, _: i64, _: *i64, _: ?*anyopaque, _: c_int) c_int {
    return stubErr("sendfile");
}
pub export fn getaddrinfo(_: ?[*:0]const u8, _: ?[*:0]const u8, _: ?*const anyopaque, _: ?*?*anyopaque) c_int {
    return stubErr("getaddrinfo");
}
pub export fn freeaddrinfo(_: ?*anyopaque) void {
    reportStub("freeaddrinfo");
}
pub export fn if_nametoindex(_: [*:0]const u8) u32 {
    _ = stubErr("if_nametoindex");
    return 0;
}

pub export fn pthread_self() usize {
    return stubUsize("pthread_self");
}
pub export fn pthread_threadid_np(_: ?*anyopaque, _: *u64) c_int {
    return stubErr("pthread_threadid_np");
}
pub export fn pthread_kill(_: ?*anyopaque, _: c_int) c_int {
    return stubErr("pthread_kill");
}
pub export fn pthread_create(_: ?*anyopaque, _: ?*const anyopaque, _: ?*const anyopaque, _: ?*anyopaque) c_int {
    return stubErr("pthread_create");
}
pub export fn pthread_detach(_: ?*anyopaque) c_int {
    return stubErr("pthread_detach");
}
pub export fn pthread_attr_init(_: ?*anyopaque) c_int {
    return stubErr("pthread_attr_init");
}
pub export fn pthread_attr_destroy(_: ?*anyopaque) c_int {
    return stubErr("pthread_attr_destroy");
}
pub export fn pthread_attr_setstacksize(_: ?*anyopaque, _: usize) c_int {
    return stubErr("pthread_attr_setstacksize");
}
pub export fn pthread_attr_setguardsize(_: ?*anyopaque, _: usize) c_int {
    return stubErr("pthread_attr_setguardsize");
}
pub export fn __ulock_wait2(_: u32, _: ?*anyopaque, _: u64, _: u64, _: u64) c_int {
    return stubErr("__ulock_wait2");
}
pub export fn __ulock_wake(_: u32, _: ?*anyopaque, _: u64) c_int {
    return stubErr("__ulock_wake");
}
pub export fn fchmod(_: c_int, _: c_int) c_int {
    return stubErr("fchmod");
}
pub export fn fchmodat(_: c_int, _: [*:0]const u8, _: c_int, _: c_int) c_int {
    return stubErr("fchmodat");
}
pub export fn fchown(_: c_int, _: c_int, _: c_int) c_int {
    return stubErr("fchown");
}
pub export fn flock(_: c_int, _: c_int) c_int {
    return stubErr("flock");
}
pub export fn fcopyfile(_: c_int, _: c_int, _: ?*anyopaque, _: u32) c_int {
    return stubErr("fcopyfile");
}
pub export fn futimens(_: c_int, _: ?*const anyopaque) c_int {
    return stubErr("futimens");
}
pub export fn utimensat(_: c_int, _: [*:0]const u8, _: ?*const anyopaque, _: c_int) c_int {
    return stubErr("utimensat");
}
pub export fn pipe(_: *[2]c_int) c_int {
    return stubErr("pipe");
}
pub export fn poll(_: ?*anyopaque, _: u32, _: c_int) c_int {
    return stubErr("poll");
}
pub export fn dup2(_: c_int, _: c_int) c_int {
    return stubErr("dup2");
}
