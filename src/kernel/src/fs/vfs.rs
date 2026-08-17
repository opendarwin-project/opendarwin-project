//! Minimal XNU/BSD-shaped Virtual File System (VFS).

use spin::Mutex;

pub const ENOENT: i32 = 2;
pub const EIO: i32 = 5;
pub const EBADF: i32 = 9;
pub const ENOMEM: i32 = 12;
pub const EFAULT: i32 = 14;
pub const EBUSY: i32 = 16;
pub const EEXIST: i32 = 17;
pub const ENODEV: i32 = 19;
pub const ENOTDIR: i32 = 20;
pub const EISDIR: i32 = 21;
pub const EINVAL: i32 = 22;
pub const ENFILE: i32 = 23;
pub const EROFS: i32 = 30;
pub const ENOSYS: i32 = 78;

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Vtype {
    #[default]
    None = 0,
    Reg = 1,
    Dir = 2,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct Vattr {
    pub typ: Vtype,
    pub mode: u16,
    pub nlink: u16,
    pub size: u64,
    pub ino: u64,
    pub blksize: u32,
}

pub struct VnodeOps {
    pub lookup: fn(dvp: *mut Vnode, name: &str, vpp: &mut Option<*mut Vnode>) -> i32,
    pub getattr: fn(vp: *mut Vnode, vap: &mut Vattr) -> i32,
    pub read: fn(vp: *mut Vnode, offset: u64, buf: &mut [u8]) -> i64,
    pub inactive: fn(vp: *mut Vnode),
}

pub struct VfsOps {
    pub mount: fn(mp: *mut Mount) -> i32,
    pub root: fn(mp: *mut Mount, vpp: &mut Option<*mut Vnode>) -> i32,
}

#[derive(Clone, Copy)]
pub struct Vnode {
    pub ops: Option<&'static VnodeOps>,
    pub typ: Vtype,
    pub mount: Option<*mut Mount>,
    pub data: Option<*mut u8>,
    pub usecount: u32,
    pub key: u64,
}

impl Default for Vnode {
    fn default() -> Self {
        Self {
            ops: None,
            typ: Vtype::None,
            mount: None,
            data: None,
            usecount: 0,
            key: 0,
        }
    }
}

#[derive(Clone, Copy)]
pub struct Mount {
    pub ops: Option<&'static VfsOps>,
    pub data: Option<*mut u8>,
    pub rootvnode: Option<*mut Vnode>,
    pub flags: u32,
}

impl Default for Mount {
    fn default() -> Self {
        Self {
            ops: None,
            data: None,
            rootvnode: None,
            flags: 0,
        }
    }
}

const MAX_MOUNTS: usize = 4;
const MAX_VNODES: usize = 128;

struct VfsState {
    mounts: [Mount; MAX_MOUNTS],
    vnodes: [Vnode; MAX_VNODES],
    root_mp: Option<*mut Mount>,
}

unsafe impl Send for VfsState {}
unsafe impl Sync for VfsState {}

static VFS: Mutex<VfsState> = Mutex::new(VfsState {
    mounts: [Mount {
        ops: None,
        data: None,
        rootvnode: None,
        flags: 0,
    }; MAX_MOUNTS],
    vnodes: [Vnode {
        ops: None,
        typ: Vtype::None,
        mount: None,
        data: None,
        usecount: 0,
        key: 0,
    }; MAX_VNODES],
    root_mp: None,
});

pub fn root_mount() -> Option<*mut Mount> {
    VFS.lock().root_mp
}

pub fn root_vnode() -> Option<*mut Vnode> {
    let vfs = VFS.lock();
    let mp = vfs.root_mp?;
    unsafe { (*mp).rootvnode }
}

fn alloc_mount(vfs: &mut VfsState) -> Option<*mut Mount> {
    for mp in vfs.mounts.iter_mut() {
        if mp.ops.is_none() {
            return Some(mp as *mut Mount);
        }
    }
    None
}

pub fn valloc() -> Option<*mut Vnode> {
    let mut vfs = VFS.lock();
    for vp in vfs.vnodes.iter_mut() {
        if vp.typ == Vtype::None && vp.usecount == 0 {
            *vp = Vnode::default();
            return Some(vp as *mut Vnode);
        }
    }
    None
}

pub fn vref(vp: *mut Vnode) {
    if !vp.is_null() {
        let _guard = VFS.lock();
        unsafe {
            (*vp).usecount += 1;
        }
    }
}

pub fn vrele(vp: *mut Vnode) {
    if vp.is_null() {
        return;
    }
    let _guard = VFS.lock();
    unsafe {
        if (*vp).usecount == 0 {
            return;
        }
        (*vp).usecount -= 1;
        if (*vp).usecount == 0 {
            if let Some(ops) = (*vp).ops {
                (ops.inactive)(vp);
            }
            *vp = Vnode::default();
        }
    }
}

pub fn vcache_lookup(mp: *mut Mount, key: u64) -> Option<*mut Vnode> {
    let mut vfs = VFS.lock();
    for vp in vfs.vnodes.iter_mut() {
        if vp.typ != Vtype::None && vp.mount == Some(mp) && vp.key == key {
            vp.usecount += 1;
            return Some(vp as *mut Vnode);
        }
    }
    None
}

pub fn mount_root(ops: &'static VfsOps) -> bool {
    let mut vfs = VFS.lock();
    if vfs.root_mp.is_some() {
        return false;
    }
    let Some(mp) = alloc_mount(&mut vfs) else {
        return false;
    };
    unsafe {
        (*mp).ops = Some(ops);
        let err = (ops.mount)(mp);
        if err != 0 {
            *mp = Mount::default();
            return false;
        }

        let mut root = None;
        let rerr = (ops.root)(mp, &mut root);
        if rerr != 0 || root.is_none() {
            *mp = Mount::default();
            return false;
        }
        (*mp).rootvnode = root;
        vfs.root_mp = Some(mp);
        true
    }
}

pub fn open_file(path: &str) -> Option<(*mut Vnode, u64)> {
    let vp = crate::fs::namei::lookup(path)?;
    unsafe {
        if (*vp).typ != Vtype::Reg {
            vrele(vp);
            return None;
        }
        let mut attr = Vattr::default();
        let ops = (*vp).ops?;
        if (ops.getattr)(vp, &mut attr) != 0 {
            vrele(vp);
            return None;
        }
        Some((vp, attr.size))
    }
}

pub fn file_size(path: &str) -> Option<u64> {
    let (vp, size) = open_file(path)?;
    vrele(vp);
    Some(size)
}

pub fn read_file(path: &str, buf: &mut [u8]) -> Option<usize> {
    let (vp, size) = open_file(path)?;
    if size > buf.len() as u64 {
        vrele(vp);
        return None;
    }
    if size == 0 {
        vrele(vp);
        return Some(0);
    }
    unsafe {
        let ops = (*vp).ops?;
        let n = (ops.read)(vp, 0, &mut buf[..size as usize]);
        vrele(vp);
        if n < 0 { None } else { Some(n as usize) }
    }
}

pub fn read_exact(vp: *mut Vnode, offset: u64, buf: &mut [u8]) -> bool {
    let mut done = 0;
    while done < buf.len() {
        let n = vop_read(vp, offset + done as u64, &mut buf[done..]);
        if n <= 0 {
            return false;
        }
        done += n as usize;
    }
    true
}

pub fn vop_lookup(dvp: *mut Vnode, name: &str, vpp: &mut Option<*mut Vnode>) -> i32 {
    unsafe {
        if (*dvp).typ != Vtype::Dir {
            return -ENOTDIR;
        }
        let Some(ops) = (*dvp).ops else {
            return -EINVAL;
        };
        (ops.lookup)(dvp, name, vpp)
    }
}

pub fn vop_getattr(vp: *mut Vnode, vap: &mut Vattr) -> i32 {
    unsafe {
        let Some(ops) = (*vp).ops else {
            return -EINVAL;
        };
        (ops.getattr)(vp, vap)
    }
}

pub fn vop_read(vp: *mut Vnode, offset: u64, buf: &mut [u8]) -> i64 {
    unsafe {
        if (*vp).typ == Vtype::Dir {
            return -EISDIR as i64;
        }
        if (*vp).typ != Vtype::Reg {
            return -EINVAL as i64;
        }
        let Some(ops) = (*vp).ops else {
            return -EINVAL as i64;
        };
        (ops.read)(vp, offset, buf)
    }
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Timespec {
    pub tv_sec: i64,
    pub tv_nsec: i64,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Stat64 {
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

pub const S_IFMT: u16 = 0o170000;
pub const S_IFREG: u16 = 0o100000;
pub const S_IFDIR: u16 = 0o040000;
pub const S_IRUSR: u16 = 0o400;
pub const S_IRGRP: u16 = 0o040;
pub const S_IROTH: u16 = 0o004;
pub const S_IXUSR: u16 = 0o100;
pub const S_IXGRP: u16 = 0o010;
pub const S_IXOTH: u16 = 0o001;

pub fn attr_to_stat(vap: &Vattr) -> Stat64 {
    let mode: u16 = match vap.typ {
        Vtype::Dir => S_IFDIR | S_IRUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH,
        Vtype::Reg => S_IFREG | S_IRUSR | S_IRGRP | S_IROTH,
        Vtype::None => 0,
    } | (vap.mode & 0o777);
    let blocks = ((vap.size + 511) / 512) as i64;
    Stat64 {
        st_dev: 1,
        st_mode: mode,
        st_nlink: vap.nlink,
        st_ino: vap.ino,
        st_uid: 0,
        st_gid: 0,
        st_rdev: 0,
        st_atimespec: Timespec::default(),
        st_mtimespec: Timespec::default(),
        st_ctimespec: Timespec::default(),
        st_birthtimespec: Timespec::default(),
        st_size: vap.size as i64,
        st_blocks: blocks,
        st_blksize: vap.blksize as i32,
        st_flags: 0,
        st_gen: 0,
        st_lspare: 0,
        st_qspare: [0, 0],
    }
}
