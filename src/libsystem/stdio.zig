//! POSIX file I/O: open, openat, close, read, write, readv, writev,
//! pread, pwrite, lseek, fcntl, ioctl, fstat, fstatat, fsync, ftruncate,
//! isatty, getcwd, chdir, fchdir, mkdirat, unlinkat, renameat, linkat,
//! symlinkat, readlinkat, faccessat, __getdirentries64, dup, dup2, pipe,
//! flock, fchmod, fchmodat, fchown, fcopyfile, futimens, utimensat, poll,
//! stat, lstat, realpath.

const common = @import("common.zig");
const C = common;

const Iovec = extern struct {
    base: [*]const u8,
    len: usize,
};

/// Darwin `struct stat` with 64-bit inodes (arm64).
pub const Stat = extern struct {
    st_dev: i32 = 0,
    st_mode: u16 = 0,
    st_nlink: u16 = 0,
    st_ino: u64 = 0,
    st_uid: u32 = 0,
    st_gid: u32 = 0,
    st_rdev: i32 = 0,
    st_atimespec: Timespec = .{},
    st_mtimespec: Timespec = .{},
    st_ctimespec: Timespec = .{},
    st_birthtimespec: Timespec = .{},
    st_size: i64 = 0,
    st_blocks: i64 = 0,
    st_blksize: i32 = 0,
    st_flags: u32 = 0,
    st_gen: u32 = 0,
    st_lspare: i32 = 0,
    st_qspare: [2]i64 = .{ 0, 0 },
};

const Timespec = extern struct {
    tv_sec: i64 = 0,
    tv_nsec: i64 = 0,
};

// ── basic I/O ──────────────────────────────────────────────────────────

pub export fn open(path: [*:0]const u8, flags: c_int, mode: c_int) c_int {
    const ret = C.darwinSyscall3(C.SYS_open, @intFromPtr(path), @intCast(flags), @intCast(mode));
    return @intCast(C.setErrnoFromNegative(ret));
}

pub export fn openat(fd: c_int, path: [*:0]const u8, flags: c_int, mode: c_int) c_int {
    _ = fd;
    if (path[0] == '/') return open(path, flags, mode);
    return C.stubErr("openat");
}

pub export fn close(fd: c_int) c_int {
    const ret = C.darwinSyscall3(C.SYS_close, @intCast(fd), 0, 0);
    return @intCast(C.setErrnoFromNegative(ret));
}

pub export fn @"close$NOCANCEL"(fd: c_int) c_int {
    return close(fd);
}

pub export fn read(fd: c_int, buf: [*]u8, len: usize) isize {
    const ret = C.darwinSyscall3(C.SYS_read, @intCast(fd), @intFromPtr(buf), len);
    return @intCast(C.setErrnoFromNegative(ret));
}

pub export fn write(fd: c_int, buf: [*]const u8, len: usize) isize {
    const ret = C.darwinSyscall3(C.SYS_write, @intCast(fd), @intFromPtr(buf), len);
    return @intCast(C.setErrnoFromNegative(ret));
}

pub export fn readv(_: c_int, _: ?*const anyopaque, _: c_int) isize {
    return @intCast(C.stubErr("readv"));
}

pub export fn writev(fd: c_int, iov: ?[*]const Iovec, iovcnt: c_int) isize {
    const vecs = iov orelse {
        common.errno = C.EINVAL;
        return -1;
    };
    if (iovcnt < 0) {
        common.errno = C.EINVAL;
        return -1;
    }
    var total: isize = 0;
    var i: usize = 0;
    while (i < @as(usize, @intCast(iovcnt))) : (i += 1) {
        const len = vecs[i].len;
        if (len == 0) continue;
        const n = write(fd, vecs[i].base, len);
        if (n < 0) return if (total != 0) total else -1;
        total += n;
        if (@as(usize, @intCast(n)) != len) break;
    }
    return total;
}

pub export fn pread(fd: c_int, buf: [*]u8, len: usize, offset: i64) isize {
    const cur = lseek(fd, 0, 1); // SEEK_CUR
    if (cur < 0) return -1;
    if (lseek(fd, offset, 0) < 0) return -1; // SEEK_SET
    const n = read(fd, buf, len);
    _ = lseek(fd, cur, 0);
    return n;
}

pub export fn preadv(_: c_int, _: ?*const anyopaque, _: c_int, _: i64) isize {
    return @intCast(C.stubErr("preadv"));
}

pub export fn pwrite(_: c_int, _: [*]const u8, _: usize, _: i64) isize {
    return @intCast(C.stubErr("pwrite"));
}

pub export fn pwritev(_: c_int, _: ?*const anyopaque, _: c_int, _: i64) isize {
    return @intCast(C.stubErr("pwritev"));
}

pub export fn lseek(fd: c_int, offset: i64, whence: c_int) i64 {
    const ret = C.darwinSyscall3(C.SYS_lseek, @intCast(fd), @as(usize, @bitCast(offset)), @intCast(whence));
    if (ret > C.usize_max - 4096) {
        common.errno = @intCast(0 -% ret);
        return -1;
    }
    return @bitCast(ret);
}

// ── file control ───────────────────────────────────────────────────────

pub export fn fcntl(_: c_int, cmd: c_int, _: usize) c_int {
    C.reportStub("fcntl");
    return switch (cmd) {
        1 => 0, // F_GETFD
        2 => 0, // F_SETFD
        3 => 0, // F_GETFL
        4 => 0, // F_SETFL
        else => blk: {
            common.errno = C.EINVAL;
            break :blk -1;
        },
    };
}

pub export fn ioctl(_: c_int, _: usize, _: usize) c_int {
    return C.stubErr("ioctl");
}

// ── stat ───────────────────────────────────────────────────────────────

pub export fn fstat(fd: c_int, sb: ?*anyopaque) c_int {
    const ptr = sb orelse {
        common.errno = C.EINVAL;
        return -1;
    };
    const ret = C.darwinSyscall3(C.SYS_fstat64, @intCast(fd), @intFromPtr(ptr), 0);
    return @intCast(C.setErrnoFromNegative(ret));
}

pub export fn fstatat(_: c_int, path: [*:0]const u8, sb: ?*anyopaque, _: c_int) c_int {
    return stat(path, sb);
}

pub export fn stat(path: [*:0]const u8, sb: ?*anyopaque) c_int {
    const ptr = sb orelse {
        common.errno = C.EINVAL;
        return -1;
    };
    const ret = C.darwinSyscall3(C.SYS_stat64, @intFromPtr(path), @intFromPtr(ptr), 0);
    return @intCast(C.setErrnoFromNegative(ret));
}

pub export fn lstat(path: [*:0]const u8, sb: ?*anyopaque) c_int {
    const ptr = sb orelse {
        common.errno = C.EINVAL;
        return -1;
    };
    const ret = C.darwinSyscall3(C.SYS_lstat64, @intFromPtr(path), @intFromPtr(ptr), 0);
    return @intCast(C.setErrnoFromNegative(ret));
}

pub export fn fsync(_: c_int) c_int {
    return 0;
}

pub export fn ftruncate(_: c_int, _: i64) c_int {
    return C.stubErr("ftruncate");
}

pub export fn isatty(fd: c_int) c_int {
    if (fd >= 0 and fd <= 2) return 1;
    common.errno = 25; // ENOTTY
    return 0;
}

// ── directory operations ───────────────────────────────────────────────

pub export fn getcwd(buf: [*]u8, size: usize) ?[*]u8 {
    const root = "/";
    if (size < root.len + 1) {
        common.errno = C.EINVAL;
        return null;
    }
    @memcpy(buf[0..root.len], root);
    buf[root.len] = 0;
    return buf;
}

pub export fn chdir(_: [*:0]const u8) c_int {
    return C.stubErr("chdir");
}

pub export fn fchdir(_: c_int) c_int {
    return C.stubErr("fchdir");
}

pub export fn mkdirat(_: c_int, _: [*:0]const u8, _: c_int) c_int {
    return C.stubErr("mkdirat");
}

pub export fn unlinkat(_: c_int, _: [*:0]const u8, _: c_int) c_int {
    return C.stubErr("unlinkat");
}

pub export fn renameat(_: c_int, _: [*:0]const u8, _: c_int, _: [*:0]const u8) c_int {
    return C.stubErr("renameat");
}

pub export fn linkat(_: c_int, _: [*:0]const u8, _: c_int, _: [*:0]const u8, _: c_int) c_int {
    return C.stubErr("linkat");
}

pub export fn symlinkat(_: [*:0]const u8, _: c_int, _: [*:0]const u8) c_int {
    return C.stubErr("symlinkat");
}

pub export fn readlinkat(_: c_int, _: [*:0]const u8, _: [*]u8, _: usize) isize {
    return @intCast(C.stubErr("readlinkat"));
}

pub export fn faccessat(_: c_int, path: [*:0]const u8, _: c_int, _: c_int) c_int {
    var sb: Stat = .{};
    return stat(path, &sb);
}

pub export fn @"realpath$DARWIN_EXTSN"(_: [*:0]const u8, _: [*]u8) ?[*]u8 {
    _ = C.stubErr("realpath$DARWIN_EXTSN");
    return null;
}

pub export fn __getdirentries64(_: c_int, _: [*]u8, _: usize, _: *i64) isize {
    return @intCast(C.stubErr("__getdirentries64"));
}

pub export fn opendir(_: [*:0]const u8) ?*anyopaque {
    _ = C.stubErr("opendir");
    return null;
}

pub export fn readdir(_: ?*anyopaque) ?*anyopaque {
    _ = C.stubErr("readdir");
    return null;
}

pub export fn closedir(_: ?*anyopaque) c_int {
    return C.stubErr("closedir");
}

// ── file descriptors ───────────────────────────────────────────────────

pub export fn dup(_: c_int) c_int {
    return C.stubErr("dup");
}

pub export fn dup2(_: c_int, _: c_int) c_int {
    return C.stubErr("dup2");
}

pub export fn pipe(_: *[2]c_int) c_int {
    return C.stubErr("pipe");
}

pub export fn flock(_: c_int, _: c_int) c_int {
    return C.stubErr("flock");
}

pub export fn fchmod(_: c_int, _: c_int) c_int {
    return C.stubErr("fchmod");
}

pub export fn fchmodat(_: c_int, _: [*:0]const u8, _: c_int, _: c_int) c_int {
    return C.stubErr("fchmodat");
}

pub export fn fchown(_: c_int, _: c_int, _: c_int) c_int {
    return C.stubErr("fchown");
}

pub export fn fcopyfile(_: c_int, _: c_int, _: ?*anyopaque, _: u32) c_int {
    return C.stubErr("fcopyfile");
}

pub export fn futimens(_: c_int, _: ?*const anyopaque) c_int {
    return C.stubErr("futimens");
}

pub export fn utimensat(_: c_int, _: [*:0]const u8, _: ?*const anyopaque, _: c_int) c_int {
    return C.stubErr("utimensat");
}

pub export fn poll(_: ?*anyopaque, _: u32, _: c_int) c_int {
    return C.stubErr("poll");
}

pub export fn ftruncate64(fd: c_int, offset: i64) c_int {
    return ftruncate(fd, offset);
}

// ── fprintf / snprintf / asprintf (minimal stub → write(2) for now) ───

pub export fn fprintf(_: ?*anyopaque, format: [*:0]const u8) c_int {
    _ = write(2, format, C.cstrLen(format));
    return 0;
}

pub export fn fputs(s: [*:0]const u8, _: ?*anyopaque) c_int {
    const n: isize = @intCast(C.cstrLen(s));
    return @intCast(write(2, s, @intCast(n)));
}

pub export fn fflush(_: ?*anyopaque) c_int {
    return 0;
}

pub export fn sprintf(buf: [*]u8, format: [*:0]const u8) c_int {
    const len = C.cstrLen(format);
    _ = @memcpy(buf[0..len], format[0..len]);
    buf[len] = 0;
    return @intCast(len);
}

pub export fn snprintf(buf: [*]u8, size: usize, format: [*:0]const u8) c_int {
    const len = C.cstrLen(format);
    const n = @min(len, size - 1);
    _ = @memcpy(buf[0..n], format[0..n]);
    if (size > 0) buf[n] = 0;
    return @intCast(len);
}

pub export fn vsnprintf(buf: [*]u8, size: usize, format: [*:0]const u8) c_int {
    return snprintf(buf, size, format);
}

pub export fn asprintf(buf: *?[*]u8, format: [*:0]const u8) c_int {
    const len = C.cstrLen(format);
    const new_buf = @import("malloc.zig").malloc(len + 1) orelse return -1;
    _ = @memcpy(@as([*]u8, @ptrCast(new_buf))[0..len], format[0..len]);
    @as([*]u8, @ptrCast(new_buf))[len] = 0;
    buf.* = @ptrCast(new_buf);
    return @intCast(len);
}

pub export fn fprintf_l(_: ?*anyopaque, _: ?*anyopaque, format: [*:0]const u8) c_int {
    _ = format;
    return 0;
}

pub export fn snprintf_l(buf: [*]u8, size: usize, _: ?*anyopaque, format: [*:0]const u8) c_int {
    return snprintf(buf, size, format);
}

pub export fn readdir_r(_: ?*anyopaque, _: ?*anyopaque, _: ?*?*anyopaque) c_int {
    return 0;
}

pub export fn unlink(_: [*:0]const u8) c_int {
    return 0;
}

pub const FILE = extern struct { fd: c_int = 2 };
var stdout_file: FILE = .{ .fd = 1 };
var stderr_file: FILE = .{ .fd = 2 };
pub export var __stdoutp: *FILE = &stdout_file;
pub export var __stderrp: *FILE = &stderr_file;

pub export fn printf(format: [*:0]const u8) c_int {
    return fprintf(null, format);
}

pub export fn __snprintf_chk(buf: [*]u8, size: usize, _: c_int, dstlen: usize, format: [*:0]const u8) c_int {
    _ = dstlen;
    return snprintf(buf, size, format);
}

pub export fn __vsnprintf_chk(buf: [*]u8, size: usize, _: c_int, dstlen: usize, format: [*:0]const u8) c_int {
    _ = dstlen;
    return vsnprintf(buf, size, format);
}

pub export fn mkdir(_: [*:0]const u8, _: c_uint) c_int {
    return C.stubErr("mkdir");
}

pub export fn chmod(_: [*:0]const u8, _: c_uint) c_int {
    return C.ENOSYS;
}

pub export fn rmdir(_: [*:0]const u8) c_int {
    return C.stubErr("rmdir");
}

pub export fn gethostname(name: [*]u8, len: usize) c_int {
    const host = "opendarwin";
    const n = @min(host.len, if (len == 0) 0 else len - 1);
    var i: usize = 0;
    while (i < n) : (i += 1) name[i] = host[i];
    if (len > 0) name[n] = 0;
    return 0;
}
