//! Process management: getpid, kill, fork, execve, wait4, setpgid, etc.

use core::ffi::{c_char, c_int, c_long, c_void};

use crate::common;

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getpid() -> c_int {
    let ret = common::darwinSyscall3(common::SYS_getpid, 0, 0, 0);
    common::setErrnoFromNegative(ret)
}

#[unsafe(no_mangle)]
pub extern "C" fn getppid() -> c_int {
    1
}

#[unsafe(no_mangle)]
pub extern "C" fn getuid() -> c_int {
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn geteuid() -> c_int {
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn getgid() -> c_int {
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn getegid() -> c_int {
    0
}

// proc_pidinfo constants (subset).
pub const PROC_PIDPATHINFO: c_int = 11;
pub const PROC_PIDPATHINFO_SIZE: c_int = 1024;

#[unsafe(no_mangle)]
pub unsafe extern "C" fn proc_pidinfo(
    _pid: c_int,
    flavor: c_int,
    _arg: u64,
    buffer: *mut c_void,
    buffersize: c_int,
) -> c_int {
    if buffersize <= 0 {
        return 0;
    }
    if !buffer.is_null() {
        let bytes = buffer as *mut u8;
        let limit = buffersize as usize;
        core::ptr::write_bytes(bytes, 0, limit);
        if flavor == PROC_PIDPATHINFO && buffersize > 1 {
            let path = b"/usr/lib/libSystem.B.dylib";
            let n = core::cmp::min(path.len(), (buffersize - 1) as usize);
            core::ptr::copy_nonoverlapping(path.as_ptr(), bytes, n);
            *bytes.add(n) = 0;
            return (n + 1) as c_int;
        }
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn kill(pid: c_int, sig: c_int) -> c_int {
    let ret = common::darwinSyscall3(common::SYS_kill, pid as usize, sig as usize, 0);
    common::setErrnoFromNegative(ret)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fork() -> c_int {
    common::stubErr("fork")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn vfork() -> c_int {
    common::stubErr("vfork")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn execve(
    _path: *const c_char,
    _argv: *const c_void,
    _envp: *const c_void,
) -> c_int {
    common::stubErr("execve")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn execvp(_file: *const c_char, _argv: *const c_void) -> c_int {
    common::stubErr("execvp")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn execvpe(
    _file: *const c_char,
    _argv: *const c_void,
    _envp: *const c_void,
) -> c_int {
    common::stubErr("execvpe")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn wait4(
    _pid: c_int,
    _stat_loc: *mut c_int,
    _options: c_int,
    _rusage: *mut c_void,
) -> c_int {
    common::stubErr("wait4")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn waitpid(pid: c_int, status: *mut c_int, _options: c_int) -> c_int {
    let _ = pid;
    if !status.is_null() {
        *status = 0;
    }
    common::stubErr("waitpid")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn setpgid(_pid: c_int, _pgid: c_int) -> c_int {
    common::stubErr("setpgid")
}

#[unsafe(no_mangle)]
pub extern "C" fn getpgid(_pid: c_int) -> c_int {
    1
}

#[unsafe(no_mangle)]
pub extern "C" fn setpgrp() -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn setsid() -> c_int {
    common::stubErr("setsid")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn setregid(_rgid: c_int, _egid: c_int) -> c_int {
    common::stubErr("setregid")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn setreuid(_ruid: c_int, _euid: c_int) -> c_int {
    common::stubErr("setreuid")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn setuid(_uid: c_int) -> c_int {
    common::stubErr("setuid")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn setgid(_gid: c_int) -> c_int {
    common::stubErr("setgid")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getgroups(_gidsetsize: c_int, _grouplist: *mut c_int) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn issetugid() -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn syscall(
    num: c_long,
    a0: usize,
    a1: usize,
    a2: usize,
    _a3: usize,
    _a4: usize,
    _a5: usize,
) -> c_long {
    common::darwinSyscall3(num as usize, a0, a1, a2) as c_long
}
