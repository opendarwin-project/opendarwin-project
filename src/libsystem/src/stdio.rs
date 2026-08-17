//! POSIX file I/O: open, openat, close, read, write, readv, writev,
//! pread, pwrite, lseek, fcntl, ioctl, fstat, fstatat, fsync, ftruncate,
//! isatty, getcwd, chdir, fchdir, mkdirat, unlinkat, renameat, linkat,
//! symlinkat, readlinkat, faccessat, __getdirentries64, dup, dup2, pipe,
//! flock, fchmod, fchmodat, fchown, fcopyfile, futimens, utimensat, poll,
//! stat, lstat, realpath.

use core::ffi::{c_char, c_int, c_uint, c_void};

use crate::common;

#[repr(C)]
pub struct Iovec {
    pub base: *const u8,
    pub len: usize,
}

#[repr(C)]
#[derive(Default, Copy, Clone)]
pub struct Timespec {
    pub tv_sec: i64,
    pub tv_nsec: i64,
}

/// Darwin `struct stat` with 64-bit inodes (arm64).
#[repr(C)]
#[derive(Default, Copy, Clone)]
pub struct Stat {
    pub st_dev: i32,
    pub st_mode: u16,
    pub st_nlink: u16,
    pub st_ino: u64,
    pub st_uid: u32,
    pub st_gid: u32,
    pub st_rdev: i32,
    pub st_atimespec: Timespec,
    pub st_mtimespec: Timespec,
    pub st_ctimespec: Timespec,
    pub st_birthtimespec: Timespec,
    pub st_size: i64,
    pub st_blocks: i64,
    pub st_blksize: i32,
    pub st_flags: u32,
    pub st_gen: u32,
    pub st_lspare: i32,
    pub st_qspare: [i64; 2],
}

// ── basic I/O ──────────────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn open(path: *const c_char, flags: c_int, mode: c_int) -> c_int {
    let ret = common::darwinSyscall3(
        common::SYS_open,
        path as usize,
        flags as usize,
        mode as usize,
    );
    common::setErrnoFromNegative(ret)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn openat(
    fd: c_int,
    path: *const c_char,
    flags: c_int,
    mode: c_int,
) -> c_int {
    let _ = fd;
    if !path.is_null() && *path as u8 == b'/' {
        return open(path, flags, mode);
    }
    common::stubErr("openat")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn close(fd: c_int) -> c_int {
    let ret = common::darwinSyscall3(common::SYS_close, fd as usize, 0, 0);
    common::setErrnoFromNegative(ret)
}

#[unsafe(export_name = "close$NOCANCEL")]
pub unsafe extern "C" fn close_nocancel(fd: c_int) -> c_int {
    close(fd)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn read(fd: c_int, buf: *mut c_void, len: usize) -> isize {
    let ret = common::darwinSyscall3(common::SYS_read, fd as usize, buf as usize, len);
    common::setErrnoFromNegative(ret) as isize
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn write(fd: c_int, buf: *const c_void, len: usize) -> isize {
    let ret = common::darwinSyscall3(common::SYS_write, fd as usize, buf as usize, len);
    common::setErrnoFromNegative(ret) as isize
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn readv(_fd: c_int, _iov: *const c_void, _iovcnt: c_int) -> isize {
    common::stubErr("readv") as isize
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn writev(fd: c_int, iov: *const Iovec, iovcnt: c_int) -> isize {
    if iov.is_null() || iovcnt < 0 {
        common::errno = common::EINVAL;
        return -1;
    }
    let mut total: isize = 0;
    for i in 0..(iovcnt as usize) {
        let vec = &*iov.add(i);
        let len = vec.len;
        if len == 0 {
            continue;
        }
        let n = write(fd, vec.base as *const c_void, len);
        if n < 0 {
            return if total != 0 { total } else { -1 };
        }
        total += n;
        if n as usize != len {
            break;
        }
    }
    total
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pread(fd: c_int, buf: *mut c_void, len: usize, offset: i64) -> isize {
    let cur = lseek(fd, 0, 1); // SEEK_CUR
    if cur < 0 {
        return -1;
    }
    if lseek(fd, offset, 0) < 0 {
        return -1; // SEEK_SET
    }
    let n = read(fd, buf, len);
    let _ = lseek(fd, cur, 0);
    n
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn preadv(
    _fd: c_int,
    _iov: *const c_void,
    _iovcnt: c_int,
    _offset: i64,
) -> isize {
    common::stubErr("preadv") as isize
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pwrite(
    _fd: c_int,
    _buf: *const c_void,
    _len: usize,
    _offset: i64,
) -> isize {
    common::stubErr("pwrite") as isize
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pwritev(
    _fd: c_int,
    _iov: *const c_void,
    _iovcnt: c_int,
    _offset: i64,
) -> isize {
    common::stubErr("pwritev") as isize
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn lseek(fd: c_int, offset: i64, whence: c_int) -> i64 {
    let ret = common::darwinSyscall3(
        common::SYS_lseek,
        fd as usize,
        offset as usize,
        whence as usize,
    );
    if ret > common::usize_max - 4096 {
        common::errno = (0usize.wrapping_sub(ret)) as c_int;
        -1
    } else {
        ret as i64
    }
}

// ── file control ───────────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fcntl(_fd: c_int, cmd: c_int, _arg: usize) -> c_int {
    common::reportStub("fcntl");
    match cmd {
        1 => 0, // F_GETFD
        2 => 0, // F_SETFD
        3 => 0, // F_GETFL
        4 => 0, // F_SETFL
        _ => {
            common::errno = common::EINVAL;
            -1
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ioctl(_fd: c_int, _req: usize, _arg: usize) -> c_int {
    common::stubErr("ioctl")
}

// ── stat ───────────────────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fstat(fd: c_int, sb: *mut c_void) -> c_int {
    if sb.is_null() {
        common::errno = common::EINVAL;
        return -1;
    }
    let ret = common::darwinSyscall3(common::SYS_fstat64, fd as usize, sb as usize, 0);
    common::setErrnoFromNegative(ret)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fstatat(
    _fd: c_int,
    path: *const c_char,
    sb: *mut c_void,
    _flag: c_int,
) -> c_int {
    stat(path, sb)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stat(path: *const c_char, sb: *mut c_void) -> c_int {
    if sb.is_null() {
        common::errno = common::EINVAL;
        return -1;
    }
    let ret = common::darwinSyscall3(common::SYS_stat64, path as usize, sb as usize, 0);
    common::setErrnoFromNegative(ret)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn lstat(path: *const c_char, sb: *mut c_void) -> c_int {
    if sb.is_null() {
        common::errno = common::EINVAL;
        return -1;
    }
    let ret = common::darwinSyscall3(common::SYS_lstat64, path as usize, sb as usize, 0);
    common::setErrnoFromNegative(ret)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fsync(_fd: c_int) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ftruncate(_fd: c_int, _length: i64) -> c_int {
    common::stubErr("ftruncate")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn isatty(fd: c_int) -> c_int {
    if (0..=2).contains(&fd) {
        return 1;
    }
    common::errno = common::ENOTTY;
    0
}

// ── directory operations ───────────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getcwd(buf: *mut u8, size: usize) -> *mut u8 {
    let root = b"/";
    if size < root.len() + 1 {
        common::errno = common::EINVAL;
        return core::ptr::null_mut();
    }
    core::ptr::copy_nonoverlapping(root.as_ptr(), buf, root.len());
    *buf.add(root.len()) = 0;
    buf
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn chdir(_path: *const c_char) -> c_int {
    common::stubErr("chdir")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fchdir(_fd: c_int) -> c_int {
    common::stubErr("fchdir")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mkdirat(_fd: c_int, _path: *const c_char, _mode: c_int) -> c_int {
    common::stubErr("mkdirat")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn unlinkat(_fd: c_int, _path: *const c_char, _flags: c_int) -> c_int {
    common::stubErr("unlinkat")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn renameat(
    _fromfd: c_int,
    _from: *const c_char,
    _tofd: c_int,
    _to: *const c_char,
) -> c_int {
    common::stubErr("renameat")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn linkat(
    _fromfd: c_int,
    _from: *const c_char,
    _tofd: c_int,
    _to: *const c_char,
    _flags: c_int,
) -> c_int {
    common::stubErr("linkat")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn symlinkat(
    _from: *const c_char,
    _tofd: c_int,
    _to: *const c_char,
) -> c_int {
    common::stubErr("symlinkat")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn readlinkat(
    _fd: c_int,
    _path: *const c_char,
    _buf: *mut u8,
    _bufsize: usize,
) -> isize {
    common::stubErr("readlinkat") as isize
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn faccessat(
    _fd: c_int,
    path: *const c_char,
    _amode: c_int,
    _flag: c_int,
) -> c_int {
    let mut sb: Stat = Stat::default();
    stat(path, &mut sb as *mut Stat as *mut c_void)
}

#[unsafe(export_name = "realpath$DARWIN_EXTSN")]
pub unsafe extern "C" fn realpath_darwin_extsn(
    _path: *const c_char,
    _resolved: *mut u8,
) -> *mut u8 {
    common::stubErr("realpath$DARWIN_EXTSN");
    core::ptr::null_mut()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn __getdirentries64(
    _fd: c_int,
    _buf: *mut u8,
    _nbytes: usize,
    _basep: *mut i64,
) -> isize {
    common::stubErr("__getdirentries64") as isize
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn opendir(_name: *const c_char) -> *mut c_void {
    common::stubNull("opendir")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn readdir(_dirp: *mut c_void) -> *mut c_void {
    common::stubNull("readdir")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn closedir(_dirp: *mut c_void) -> c_int {
    common::stubErr("closedir")
}

// ── file descriptors ───────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dup(_fd: c_int) -> c_int {
    common::stubErr("dup")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dup2(_oldfd: c_int, _newfd: c_int) -> c_int {
    common::stubErr("dup2")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pipe(_fildes: *mut [c_int; 2]) -> c_int {
    common::stubErr("pipe")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn flock(_fd: c_int, _operation: c_int) -> c_int {
    common::stubErr("flock")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fchmod(_fd: c_int, _mode: c_int) -> c_int {
    common::stubErr("fchmod")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fchmodat(
    _fd: c_int,
    _path: *const c_char,
    _mode: c_int,
    _flag: c_int,
) -> c_int {
    common::stubErr("fchmodat")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fchown(_fd: c_int, _owner: c_int, _group: c_int) -> c_int {
    common::stubErr("fchown")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fcopyfile(
    _from: c_int,
    _to: c_int,
    _state: *mut c_void,
    _flags: u32,
) -> c_int {
    common::stubErr("fcopyfile")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn futimens(_fd: c_int, _times: *const c_void) -> c_int {
    common::stubErr("futimens")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn utimensat(
    _fd: c_int,
    _path: *const c_char,
    _times: *const c_void,
    _flag: c_int,
) -> c_int {
    common::stubErr("utimensat")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn poll(_fds: *mut c_void, _nfds: u32, _timeout: c_int) -> c_int {
    common::stubErr("poll")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ftruncate64(fd: c_int, offset: i64) -> c_int {
    ftruncate(fd, offset)
}

// ── fprintf / snprintf / asprintf ─────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fprintf(_stream: *mut c_void, format: *const c_char) -> c_int {
    let _ = write(2, format as *const c_void, common::cstrLen(format));
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fputs(s: *const c_char, _stream: *mut c_void) -> c_int {
    let n = common::cstrLen(s);
    write(2, s as *const c_void, n) as c_int
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fflush(_stream: *mut c_void) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sprintf(buf: *mut u8, format: *const c_char) -> c_int {
    let len = common::cstrLen(format);
    core::ptr::copy_nonoverlapping(format as *const u8, buf, len);
    *buf.add(len) = 0;
    len as c_int
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn snprintf(buf: *mut u8, size: usize, format: *const c_char) -> c_int {
    let len = common::cstrLen(format);
    if size > 0 {
        let n = core::cmp::min(len, size - 1);
        core::ptr::copy_nonoverlapping(format as *const u8, buf, n);
        *buf.add(n) = 0;
    }
    len as c_int
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn vsnprintf(buf: *mut u8, size: usize, format: *const c_char) -> c_int {
    snprintf(buf, size, format)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn asprintf(buf: *mut *mut u8, format: *const c_char) -> c_int {
    let len = common::cstrLen(format);
    let new_buf = crate::malloc::malloc(len + 1);
    if new_buf.is_null() {
        return -1;
    }
    core::ptr::copy_nonoverlapping(format as *const u8, new_buf as *mut u8, len);
    *(new_buf as *mut u8).add(len) = 0;
    *buf = new_buf as *mut u8;
    len as c_int
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fprintf_l(
    _stream: *mut c_void,
    _loc: *mut c_void,
    _format: *const c_char,
) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn snprintf_l(
    buf: *mut u8,
    size: usize,
    _loc: *mut c_void,
    format: *const c_char,
) -> c_int {
    snprintf(buf, size, format)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn readdir_r(
    _dirp: *mut c_void,
    _entry: *mut c_void,
    _result: *mut *mut c_void,
) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn unlink(_path: *const c_char) -> c_int {
    0
}

#[repr(C)]
pub struct FILE {
    pub fd: c_int,
}

static mut STDOUT_FILE: FILE = FILE { fd: 1 };
static mut STDERR_FILE: FILE = FILE { fd: 2 };

#[unsafe(no_mangle)]
pub static mut __stdoutp: *mut FILE = &raw mut STDOUT_FILE;

#[unsafe(no_mangle)]
pub static mut __stderrp: *mut FILE = &raw mut STDERR_FILE;

#[unsafe(no_mangle)]
pub unsafe extern "C" fn printf(format: *const c_char) -> c_int {
    fprintf(core::ptr::null_mut(), format)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn __snprintf_chk(
    buf: *mut u8,
    size: usize,
    _flags: c_int,
    _dstlen: usize,
    format: *const c_char,
) -> c_int {
    snprintf(buf, size, format)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn __vsnprintf_chk(
    buf: *mut u8,
    size: usize,
    _flags: c_int,
    _dstlen: usize,
    format: *const c_char,
) -> c_int {
    vsnprintf(buf, size, format)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mkdir(_path: *const c_char, _mode: c_uint) -> c_int {
    common::stubErr("mkdir")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn chmod(_path: *const c_char, _mode: c_uint) -> c_int {
    common::ENOSYS
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rmdir(_path: *const c_char) -> c_int {
    common::stubErr("rmdir")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gethostname(name: *mut u8, len: usize) -> c_int {
    let host = b"opendarwin";
    if len == 0 {
        return 0;
    }
    let n = core::cmp::min(host.len(), len - 1);
    core::ptr::copy_nonoverlapping(host.as_ptr(), name, n);
    *name.add(n) = 0;
    0
}
