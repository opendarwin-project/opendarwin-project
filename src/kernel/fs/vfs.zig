//! Minimal XNU/BSD-shaped VFS: mounts, vnodes, and VOP/VFS ops tables.
//!
//! One root mount for now (the FAT rootfs). Path lookup lives in namei.zig;
//! open-file state lives in syscall/fd.zig. Filesystem drivers (fat.zig)
//! supply `VfsOps` / `VnodeOps` and private per-vnode data via `Vnode.data`.

const std = @import("std");
const conduit = @import("conduit");
const Block = conduit.device.Block;

pub const ENOENT: i32 = 2;
pub const EIO: i32 = 5;
pub const EBADF: i32 = 9;
pub const ENOMEM: i32 = 12;
pub const EFAULT: i32 = 14;
pub const EBUSY: i32 = 16;
pub const EEXIST: i32 = 17;
pub const ENODEV: i32 = 19;
pub const EINVAL: i32 = 22;
pub const ENFILE: i32 = 23;
pub const ENOTDIR: i32 = 20;
pub const EISDIR: i32 = 21;
pub const ENOSYS: i32 = 78;
pub const EROFS: i32 = 30;

pub const Vtype = enum(u8) {
    none = 0,
    reg = 1,
    dir = 2,
};

pub const Vattr = struct {
    typ: Vtype = .none,
    mode: u16 = 0,
    nlink: u16 = 1,
    size: u64 = 0,
    ino: u64 = 0,
    blksize: u32 = 512,
};

pub const VnodeOps = struct {
    /// Lookup `name` in directory `dvp`. On success stores a referenced vnode.
    lookup: *const fn (dvp: *Vnode, name: []const u8, vpp: *?*Vnode) i32,
    getattr: *const fn (vp: *Vnode, vap: *Vattr) i32,
    /// Read up to `buf.len` bytes at `offset`. Returns bytes read (>=0) or -errno.
    read: *const fn (vp: *Vnode, offset: u64, buf: []u8) i64,
    /// Called when usecount drops to zero; FS may reclaim private data.
    inactive: *const fn (vp: *Vnode) void,
};

pub const VfsOps = struct {
    /// Attach `dev` as this mount. Returns 0 or -errno.
    mount: *const fn (mp: *Mount, dev: Block) i32,
    /// Return the referenced root directory vnode.
    root: *const fn (mp: *Mount, vpp: *?*Vnode) i32,
};

pub const Vnode = struct {
    ops: ?*const VnodeOps = null,
    typ: Vtype = .none,
    mount: ?*Mount = null,
    /// Filesystem-private cookie (e.g. FAT cluster/size).
    data: ?*anyopaque = null,
    usecount: u32 = 0,
    /// Identity key for the vnode cache (FS-defined; FAT uses cluster).
    key: u64 = 0,
};

pub const Mount = struct {
    ops: ?*const VfsOps = null,
    data: ?*anyopaque = null,
    rootvnode: ?*Vnode = null,
    flags: u32 = 0,
};

const MAX_MOUNTS = 4;
const MAX_VNODES = 128;

var mounts: [MAX_MOUNTS]Mount = [_]Mount{.{}} ** MAX_MOUNTS;
var vnodes: [MAX_VNODES]Vnode = [_]Vnode{.{}} ** MAX_VNODES;
var root_mp: ?*Mount = null;

pub fn rootMount() ?*Mount {
    return root_mp;
}

pub fn rootVnode() ?*Vnode {
    const mp = root_mp orelse return null;
    return mp.rootvnode;
}

fn allocMount() ?*Mount {
    for (&mounts) |*mp| {
        if (mp.ops == null) return mp;
    }
    return null;
}

/// Allocate a free vnode slot. Caller fills fields and takes the first ref.
pub fn valloc() ?*Vnode {
    for (&vnodes) |*vp| {
        if (vp.typ == .none and vp.usecount == 0) {
            vp.* = .{};
            return vp;
        }
    }
    return null;
}

pub fn vref(vp: *Vnode) void {
    vp.usecount += 1;
}

pub fn vrele(vp: *Vnode) void {
    if (vp.usecount == 0) return;
    vp.usecount -= 1;
    if (vp.usecount == 0) {
        if (vp.ops) |ops| ops.inactive(vp);
        vp.* = .{};
    }
}

/// Find a cached vnode for `(mp, key)` with usecount > 0 or reclaimable, and
/// take a reference. Returns null if not present.
pub fn vcacheLookup(mp: *Mount, key: u64) ?*Vnode {
    for (&vnodes) |*vp| {
        if (vp.typ != .none and vp.mount == mp and vp.key == key) {
            vref(vp);
            return vp;
        }
    }
    return null;
}

/// Mount `ops` on `dev` as the system root. Returns true on success.
pub fn mountRoot(ops: *const VfsOps, dev: Block) bool {
    if (root_mp != null) return false;
    const mp = allocMount() orelse return false;
    mp.* = .{ .ops = ops };
    const err = ops.mount(mp, dev);
    if (err != 0) {
        mp.* = .{};
        return false;
    }
    var root: ?*Vnode = null;
    const rerr = ops.root(mp, &root);
    if (rerr != 0 or root == null) {
        mp.* = .{};
        return false;
    }
    mp.rootvnode = root;
    root_mp = mp;
    return true;
}

fn vnodeOps(vp: *Vnode) *const VnodeOps {
    return vp.ops.?;
}

/// Kernel helper: look up a regular file and return a referenced vnode + size.
/// Caller must `vrele` the vnode. Used by streaming loaders that read by offset.
pub fn openFile(path: []const u8) ?struct { vp: *Vnode, size: u64 } {
    const namei = @import("namei.zig");
    const vp = namei.lookup(path) orelse return null;
    if (vp.typ != .reg) {
        vrele(vp);
        return null;
    }
    var attr: Vattr = .{};
    if (vnodeOps(vp).getattr(vp, &attr) != 0) {
        vrele(vp);
        return null;
    }
    return .{ .vp = vp, .size = attr.size };
}

/// Size of a regular file by path, or null if missing / not a regular file.
pub fn fileSize(path: []const u8) ?u64 {
    const opened = openFile(path) orelse return null;
    defer vrele(opened.vp);
    return opened.size;
}

/// Kernel helper: read an entire file by absolute or relative-from-root path.
/// Same contract as the old `fat.readFile` — used by the early loader paths.
pub fn readFile(path: []const u8, buf: []u8) ?usize {
    const opened = openFile(path) orelse return null;
    defer vrele(opened.vp);
    if (opened.size > buf.len) return null;
    if (opened.size == 0) return 0;
    const n = vnodeOps(opened.vp).read(opened.vp, 0, buf[0..opened.size]);
    if (n < 0) return null;
    return @intCast(n);
}

/// Read exactly `buf.len` bytes at `offset`, or null on short / I/O error.
pub fn readExact(vp: *Vnode, offset: u64, buf: []u8) bool {
    var done: usize = 0;
    while (done < buf.len) {
        const n = vopRead(vp, offset + done, buf[done..]);
        if (n <= 0) return false;
        done += @intCast(n);
    }
    return true;
}

pub fn vopLookup(dvp: *Vnode, name: []const u8, vpp: *?*Vnode) i32 {
    if (dvp.typ != .dir) return -ENOTDIR;
    return vnodeOps(dvp).lookup(dvp, name, vpp);
}

pub fn vopGetattr(vp: *Vnode, vap: *Vattr) i32 {
    return vnodeOps(vp).getattr(vp, vap);
}

pub fn vopRead(vp: *Vnode, offset: u64, buf: []u8) i64 {
    if (vp.typ == .dir) return -EISDIR;
    if (vp.typ != .reg) return -EINVAL;
    return vnodeOps(vp).read(vp, offset, buf);
}

// Darwin `struct stat` with `_DARWIN_FEATURE_64_BIT_INODE` (arm64 userspace).
pub const Stat64 = extern struct {
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
    st_blksize: i32 = 512,
    st_flags: u32 = 0,
    st_gen: u32 = 0,
    st_lspare: i32 = 0,
    st_qspare: [2]i64 = .{ 0, 0 },
};

pub const Timespec = extern struct {
    tv_sec: i64 = 0,
    tv_nsec: i64 = 0,
};

pub const S_IFMT: u16 = 0o170000;
pub const S_IFREG: u16 = 0o100000;
pub const S_IFDIR: u16 = 0o040000;
pub const S_IRUSR: u16 = 0o400;
pub const S_IRGRP: u16 = 0o040;
pub const S_IROTH: u16 = 0o004;
pub const S_IXUSR: u16 = 0o100;
pub const S_IXGRP: u16 = 0o010;
pub const S_IXOTH: u16 = 0o001;

pub fn attrToStat(vap: *const Vattr) Stat64 {
    const mode: u16 = switch (vap.typ) {
        .dir => S_IFDIR | S_IRUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH,
        .reg => S_IFREG | S_IRUSR | S_IRGRP | S_IROTH,
        .none => 0,
    } | (vap.mode & 0o777);
    const blocks: i64 = @intCast((vap.size + 511) / 512);
    return .{
        .st_dev = 1,
        .st_mode = mode,
        .st_nlink = vap.nlink,
        .st_ino = vap.ino,
        .st_size = @intCast(vap.size),
        .st_blocks = blocks,
        .st_blksize = @intCast(vap.blksize),
    };
}
