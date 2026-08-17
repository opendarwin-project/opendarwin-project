//! File descriptor table supporting Unix sockets, VFS vnodes, and standard I/O.

use crate::fs::namei;
use crate::fs::vfs::{self, Vnode};
use crate::proc::sched;
use crate::syscall::usercopy;
use spin::Mutex;

pub const MAX_FDS: usize = 64;
pub const BUF_SIZE: usize = 4096;

pub const EBADF: i64 = 9;
pub const EAGAIN: i64 = 35;
pub const EINVAL: i64 = 22;
pub const EAFNOSUPPORT: i64 = 47;
pub const ENFILE: i64 = 23;
pub const ENOENT: i64 = 2;
pub const EISDIR: i64 = 21;
pub const EFAULT: i64 = 14;
pub const EROFS: i64 = 30;

pub const O_ACCMODE: u32 = 0x3;
pub const O_RDONLY: u32 = 0;
pub const O_WRONLY: u32 = 1;
pub const O_RDWR: u32 = 2;
pub const O_DIRECTORY: u32 = 0x100000;

pub const SEEK_SET: i32 = 0;
pub const SEEK_CUR: i32 = 1;
pub const SEEK_END: i32 = 2;

#[derive(Clone, Copy, PartialEq, Eq, Default)]
pub enum FileKind {
    #[default]
    Free,
    Socket,
    Vnode,
}

#[derive(Clone, Copy)]
pub struct Socket {
    pub peer: u32,
    pub buf: [u8; BUF_SIZE],
    pub head: usize,
    pub len: usize,
}

impl Default for Socket {
    fn default() -> Self {
        Self {
            peer: 0,
            buf: [0; BUF_SIZE],
            head: 0,
            len: 0,
        }
    }
}

#[derive(Clone, Copy, Default)]
pub struct VnodeFile {
    pub vp: Option<*mut Vnode>,
    pub offset: u64,
    pub flags: u32,
}

#[derive(Clone, Copy, Default)]
pub struct File {
    pub kind: FileKind,
    pub socket: Socket,
    pub vnode: VnodeFile,
}

unsafe impl Send for File {}
unsafe impl Sync for File {}

static FILES: Mutex<[File; MAX_FDS]> = Mutex::new(
    [const {
        File {
            kind: FileKind::Free,
            socket: Socket {
                peer: 0,
                buf: [0; BUF_SIZE],
                head: 0,
                len: 0,
            },
            vnode: VnodeFile {
                vp: None,
                offset: 0,
                flags: 0,
            },
        }
    }; MAX_FDS],
);

#[inline(always)]
fn neg(errno: i64) -> u64 {
    (-errno) as u64
}

fn alloc_fd_slot(files: &[File; MAX_FDS]) -> Option<u32> {
    for i in 3..MAX_FDS {
        if files[i].kind == FileKind::Free {
            return Some(i as u32);
        }
    }
    None
}

fn alloc_fd(files: &mut [File; MAX_FDS]) -> Option<u32> {
    let i = alloc_fd_slot(files)?;
    files[i as usize] = File {
        kind: FileKind::Socket,
        socket: Socket::default(),
        vnode: VnodeFile::default(),
    };
    Some(i)
}

fn valid_socket(files: &[File; MAX_FDS], fd: u64) -> Option<usize> {
    if fd >= MAX_FDS as u64 {
        return None;
    }
    let idx = fd as usize;
    if files[idx].kind == FileKind::Socket {
        Some(idx)
    } else {
        None
    }
}

fn valid_vnode(files: &[File; MAX_FDS], fd: u64) -> Option<usize> {
    if fd >= MAX_FDS as u64 {
        return None;
    }
    let idx = fd as usize;
    if files[idx].kind == FileKind::Vnode {
        Some(idx)
    } else {
        None
    }
}

pub fn is_socket(fd: u64) -> bool {
    let files = FILES.lock();
    valid_socket(&files, fd).is_some()
}

pub fn would_block(ret: u64) -> bool {
    ret == neg(EAGAIN)
}

pub fn socketpair(sv_addr: u64) -> u64 {
    if sv_addr == 0 {
        return neg(EINVAL);
    }
    let mut files = FILES.lock();
    let Some(a) = alloc_fd(&mut files) else {
        return neg(ENFILE);
    };
    let Some(b) = alloc_fd(&mut files) else {
        files[a as usize] = File::default();
        return neg(ENFILE);
    };
    files[a as usize].socket.peer = b;
    files[b as usize].socket.peer = a;
    drop(files);

    let sv = [a as i32, b as i32];
    if !usercopy::copy_out(sv_addr, &sv) {
        let mut files = FILES.lock();
        files[a as usize] = File::default();
        files[b as usize] = File::default();
        return neg(EINVAL);
    }
    0
}

pub fn socket(domain: u64, _typ: u64, _proto: u64) -> u64 {
    if domain != 1 {
        return neg(EAFNOSUPPORT);
    }
    let mut files = FILES.lock();
    let Some(fd) = alloc_fd(&mut files) else {
        return neg(ENFILE);
    };
    files[fd as usize].socket.peer = fd;
    fd as u64
}

pub fn open(path_addr: u64, flags: u64, _mode: u64) -> u64 {
    let mut path_buf = [0u8; namei::MAX_PATH];
    let Some(path) = namei::copyin_path(path_addr, &mut path_buf) else {
        return neg(EFAULT);
    };

    let fl = flags as u32;
    let acc = fl & O_ACCMODE;
    if acc == O_WRONLY || acc == O_RDWR {
        return neg(EROFS);
    }

    let Some(vp) = namei::lookup(path) else {
        return neg(ENOENT);
    };

    unsafe {
        if (fl & O_DIRECTORY) != 0 && (*vp).typ != vfs::Vtype::Dir {
            vfs::vrele(vp);
            return neg(ENOENT);
        }
        if (*vp).typ != vfs::Vtype::Reg && (*vp).typ != vfs::Vtype::Dir {
            vfs::vrele(vp);
            return neg(ENOENT);
        }

        let mut files = FILES.lock();
        let Some(fd) = alloc_fd_slot(&files) else {
            drop(files);
            vfs::vrele(vp);
            return neg(ENFILE);
        };

        files[fd as usize] = File {
            kind: FileKind::Vnode,
            socket: Socket::default(),
            vnode: VnodeFile {
                vp: Some(vp),
                offset: 0,
                flags: fl,
            },
        };
        fd as u64
    }
}

pub fn close(fd: u64) -> Option<u64> {
    let mut files = FILES.lock();
    if let Some(idx) = valid_socket(&files, fd) {
        let peer = files[idx].socket.peer as usize;
        files[idx] = File::default();
        if peer < MAX_FDS
            && files[peer].kind == FileKind::Socket
            && files[peer].socket.peer == idx as u32
        {
            files[peer].socket.peer = peer as u32;
        }
        return Some(0);
    }
    if let Some(idx) = valid_vnode(&files, fd) {
        let vp = files[idx].vnode.vp;
        files[idx] = File::default();
        drop(files);
        if let Some(vp) = vp {
            vfs::vrele(vp);
        }
        return Some(0);
    }
    if fd <= 2 {
        return Some(0);
    }
    Some(neg(EBADF))
}

pub fn write(fd: u64, buf_addr: u64, len: u64) -> Option<u64> {
    let mut files = FILES.lock();
    if let Some(idx) = valid_socket(&files, fd) {
        if buf_addr == 0 && len != 0 {
            return Some(neg(EINVAL));
        }
        let peer = files[idx].socket.peer as usize;
        if peer >= MAX_FDS || files[peer].kind != FileKind::Socket {
            return Some(neg(EBADF));
        }
        let s = &mut files[peer].socket;
        let available = BUF_SIZE - s.len;
        let n = (len as usize).min(available);
        if n == 0 && len != 0 {
            return Some(neg(EAGAIN));
        }
        let mut tmp = [0u8; BUF_SIZE];
        if n != 0 && !usercopy::copy_bytes_in(&mut tmp[..n], buf_addr) {
            return Some(neg(EINVAL));
        }
        for i in 0..n {
            let pos = (s.head + s.len) % BUF_SIZE;
            s.buf[pos] = tmp[i];
            s.len += 1;
        }
        drop(files);
        if n != 0 {
            sched::wake_fd(peer as u64);
        }
        return Some(n as u64);
    }
    if valid_vnode(&files, fd).is_some() {
        return Some(neg(EROFS));
    }
    None
}

pub fn read(fd: u64, buf_addr: u64, len: u64) -> Option<u64> {
    let mut files = FILES.lock();
    if let Some(idx) = valid_socket(&files, fd) {
        if buf_addr == 0 && len != 0 {
            return Some(neg(EINVAL));
        }
        let s = &mut files[idx].socket;
        if s.len == 0 {
            return Some(neg(EAGAIN));
        }
        let n = (len as usize).min(s.len);
        let mut tmp = [0u8; BUF_SIZE];
        for i in 0..n {
            tmp[i] = s.buf[s.head];
            s.head = (s.head + 1) % BUF_SIZE;
            s.len -= 1;
        }
        drop(files);
        if n != 0 && !usercopy::copy_bytes_out(buf_addr, &tmp[..n]) {
            return Some(neg(EINVAL));
        }
        return Some(n as u64);
    }
    if let Some(idx) = valid_vnode(&files, fd) {
        let vf = &mut files[idx].vnode;
        let Some(vp) = vf.vp else {
            return Some(neg(EBADF));
        };
        let is_dir = unsafe { (*vp).typ == vfs::Vtype::Dir };
        if is_dir {
            return Some(neg(EISDIR));
        }
        if buf_addr == 0 && len != 0 {
            return Some(neg(EINVAL));
        }
        if len == 0 {
            return Some(0);
        }

        let mut total = 0u64;
        let mut remaining = len;
        while remaining > 0 {
            let mut tmp = [0u8; BUF_SIZE];
            let chunk = (remaining as usize).min(BUF_SIZE);
            let n = vfs::vop_read(vp, vf.offset, &mut tmp[..chunk]);
            if n < 0 {
                return Some(neg(-n));
            }
            if n == 0 {
                break;
            }
            let got = n as usize;
            if !usercopy::copy_bytes_out(buf_addr + total, &tmp[..got]) {
                return Some(neg(EFAULT));
            }
            vf.offset += got as u64;
            total += got as u64;
            remaining -= got as u64;
            if got < chunk {
                break;
            }
        }
        return Some(total);
    }
    None
}

pub fn lseek(fd: u64, offset: i64, whence: i32) -> u64 {
    let mut files = FILES.lock();
    let Some(idx) = valid_vnode(&files, fd) else {
        return neg(EBADF);
    };
    let vf = &mut files[idx].vnode;
    let Some(vp) = vf.vp else {
        return neg(EBADF);
    };
    let mut attr = vfs::Vattr::default();
    if vfs::vop_getattr(vp, &mut attr) != 0 {
        return neg(EINVAL);
    }

    let base: i64 = match whence {
        SEEK_SET => 0,
        SEEK_CUR => vf.offset as i64,
        SEEK_END => attr.size as i64,
        _ => return neg(EINVAL),
    };
    let next = base.wrapping_add(offset);
    if next < 0 {
        return neg(EINVAL);
    }
    vf.offset = next as u64;
    vf.offset
}

pub fn fstat(fd: u64, ub: u64) -> u64 {
    let files = FILES.lock();
    let Some(idx) = valid_vnode(&files, fd) else {
        return neg(EBADF);
    };
    let vp = files[idx].vnode.vp.unwrap();
    let mut attr = vfs::Vattr::default();
    if vfs::vop_getattr(vp, &mut attr) != 0 {
        return neg(EINVAL);
    }
    let st = vfs::attr_to_stat(&attr);
    if !usercopy::copy_out(ub, &st) {
        return neg(EFAULT);
    }
    0
}

pub fn stat(path_addr: u64, ub: u64) -> u64 {
    let mut path_buf = [0u8; namei::MAX_PATH];
    let Some(path) = namei::copyin_path(path_addr, &mut path_buf) else {
        return neg(EFAULT);
    };
    let Some(vp) = namei::lookup(path) else {
        return neg(ENOENT);
    };
    vfs::vrele(vp);

    let mut attr = vfs::Vattr::default();
    if vfs::vop_getattr(vp, &mut attr) != 0 {
        return neg(EINVAL);
    }
    let st = vfs::attr_to_stat(&attr);
    if !usercopy::copy_out(ub, &st) {
        return neg(EFAULT);
    }
    0
}

pub fn getsockname(fd: u64, addr: u64, len_addr: u64) -> u64 {
    let files = FILES.lock();
    if valid_socket(&files, fd).is_none() {
        return neg(EBADF);
    }
    if addr != 0 {
        let n = if len_addr != 0 {
            usercopy::copy_in::<u32>(len_addr).unwrap_or(16)
        } else {
            16
        };
        let zeroes = [0u8; 16];
        let out_len = (n as usize).min(16);
        if !usercopy::copy_bytes_out(addr, &zeroes[..out_len]) {
            return neg(EINVAL);
        }
        if len_addr != 0 && !usercopy::copy_out(len_addr, &(out_len as u32)) {
            return neg(EINVAL);
        }
    }
    0
}
