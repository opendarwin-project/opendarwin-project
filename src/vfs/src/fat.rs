//! Read-only FAT12/16/32 driver exposed as VFS ops.

use crate::vfs::{self, EIO, ENOENT, ENOMEM, Mount, Vattr, VfsOps, Vnode, VnodeOps, Vtype};
use spin::Mutex;

pub type BlockReader = fn(sector: u64, count: u32, buf: &mut [u8]) -> bool;

static BLOCK_READER: Mutex<Option<BlockReader>> = Mutex::new(None);

pub fn set_block_reader(reader: BlockReader) {
    *BLOCK_READER.lock() = Some(reader);
}

fn read_disk_blocks(sector: u64, count: u32, buf: &mut [u8]) -> bool {
    let guard = BLOCK_READER.lock();
    if let Some(reader) = *guard {
        reader(sector, count, buf)
    } else {
        false
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
enum FatType {
    Fat12,
    Fat16,
    #[default]
    Fat32,
}

#[derive(Clone, Copy, Default)]
struct FatState {
    bytes_per_sector: u32,
    sectors_per_cluster: u32,
    reserved: u32,
    num_fats: u32,
    fat_sectors: u32,
    first_data_sector: u32,
    first_fat_sector: u32,
    root_cluster: u32,
    root_dir_sectors: u32,
    root_dir_start: u32,
    kind: FatType,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct FatNode {
    cluster: u32,
    size: u32,
    is_dir: bool,
    parent: u32,
}

const MAX_FAT_NODES: usize = 128;

struct FatDriverState {
    state: FatState,
    sector_buf: [u8; 512],
    fat_cache_buf: [u8; 512],
    fat_cache_rel: u32,
    fat_node_pool: [FatNode; MAX_FAT_NODES],
    fat_node_used: [bool; MAX_FAT_NODES],
}

static FAT: Mutex<FatDriverState> = Mutex::new(FatDriverState {
    state: FatState {
        bytes_per_sector: 0,
        sectors_per_cluster: 0,
        reserved: 0,
        num_fats: 0,
        fat_sectors: 0,
        first_data_sector: 0,
        first_fat_sector: 0,
        root_cluster: 0,
        root_dir_sectors: 0,
        root_dir_start: 0,
        kind: FatType::Fat32,
    },
    sector_buf: [0; 512],
    fat_cache_buf: [0; 512],
    fat_cache_rel: 0xffff_ffff,
    fat_node_pool: [FatNode {
        cluster: 0,
        size: 0,
        is_dir: false,
        parent: 0,
    }; MAX_FAT_NODES],
    fat_node_used: [false; MAX_FAT_NODES],
});

fn alloc_fat_node(fat: &mut FatDriverState) -> Option<*mut FatNode> {
    for (i, used) in fat.fat_node_used.iter_mut().enumerate() {
        if !*used {
            *used = true;
            return Some(&mut fat.fat_node_pool[i] as *mut FatNode);
        }
    }
    None
}

fn read_fat_sector(fat: &mut FatDriverState, rel: u32) -> Option<*const u8> {
    if fat.fat_cache_rel != rel {
        let sector = fat.state.first_fat_sector + rel;
        if !read_disk_blocks(sector as u64, 1, &mut fat.fat_cache_buf) {
            return None;
        }
        fat.fat_cache_rel = rel;
    }
    Some(fat.fat_cache_buf.as_ptr())
}

fn cluster_to_sector(state: &FatState, cluster: u32) -> u32 {
    state.first_data_sector + (cluster - 2) * state.sectors_per_cluster
}

fn is_eoc(state: &FatState, cluster: u32) -> bool {
    match state.kind {
        FatType::Fat12 => cluster >= 0xff8,
        FatType::Fat16 => cluster >= 0xfff8,
        FatType::Fat32 => cluster >= 0x0fff_fff8,
    }
}

fn next_cluster(fat: &mut FatDriverState, cluster: u32) -> u32 {
    match fat.state.kind {
        FatType::Fat32 => {
            let off = cluster * 4;
            let Some(buf) = read_fat_sector(fat, off / 512) else {
                return 0x0fff_ffff;
            };
            let slice = unsafe { core::slice::from_raw_parts(buf.add((off % 512) as usize), 4) };
            u32::from_le_bytes([slice[0], slice[1], slice[2], slice[3]]) & 0x0fff_ffff
        }
        FatType::Fat16 => {
            let off = cluster * 2;
            let Some(buf) = read_fat_sector(fat, off / 512) else {
                return 0xffff;
            };
            let slice = unsafe { core::slice::from_raw_parts(buf.add((off % 512) as usize), 2) };
            u16::from_le_bytes([slice[0], slice[1]]) as u32
        }
        FatType::Fat12 => {
            let off = cluster + cluster / 2;
            let Some(buf) = read_fat_sector(fat, off / 512) else {
                return 0xfff;
            };
            let lo = unsafe { *buf.add((off % 512) as usize) };
            let hi = if off % 512 == 511 {
                let mut nb = [0u8; 512];
                let _ = read_disk_blocks(
                    (fat.state.first_fat_sector + off / 512 + 1) as u64,
                    1,
                    &mut nb,
                );
                nb[0]
            } else {
                unsafe { *buf.add((off % 512 + 1) as usize) }
            };
            let v = (lo as u16) | ((hi as u16) << 8);
            if (cluster & 1) == 0 {
                (v & 0xfff) as u32
            } else {
                (v >> 4) as u32
            }
        }
    }
}

fn upper(c: u8) -> u8 {
    if (b'a'..=b'z').contains(&c) {
        c - 32
    } else {
        c
    }
}

fn ieq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    for (&x, &y) in a.iter().zip(b.iter()) {
        if upper(x) != upper(y) {
            return false;
        }
    }
    true
}

fn short_name(raw: &[u8], out: &mut [u8]) -> usize {
    let mut n = 0;
    let mut i = 0;
    while i < 8 && raw[i] != b' ' {
        out[n] = upper(raw[i]);
        n += 1;
        i += 1;
    }
    if raw[8] != b' ' {
        out[n] = b'.';
        n += 1;
        i = 8;
        while i < 11 && raw[i] != b' ' {
            out[n] = upper(raw[i]);
            n += 1;
            i += 1;
        }
    }
    n
}

#[derive(Clone, Copy)]
struct DirEntry {
    cluster: u32,
    size: u32,
    is_dir: bool,
}

enum DirMode {
    Root16,
    Chain(u32),
}

fn find_in_dir(fat: &mut FatDriverState, dir: DirMode, name: &str) -> Option<DirEntry> {
    let mut lfn = [0u8; 260];
    let mut lfn_len = 0;
    let mut have_lfn = false;

    let mut cluster = match dir {
        DirMode::Root16 => 0,
        DirMode::Chain(c) => c,
    };
    let mut sector_in_root = 0;

    loop {
        let (sector, sectors_this) = match dir {
            DirMode::Root16 => {
                if sector_in_root >= fat.state.root_dir_sectors {
                    return None;
                }
                (fat.state.root_dir_start + sector_in_root, 1)
            }
            DirMode::Chain(_) => {
                if is_eoc(&fat.state, cluster) || cluster < 2 {
                    return None;
                }
                (
                    cluster_to_sector(&fat.state, cluster),
                    fat.state.sectors_per_cluster,
                )
            }
        };

        for ss in 0..sectors_this {
            if !read_disk_blocks((sector + ss) as u64, 1, &mut fat.sector_buf) {
                return None;
            }

            let mut e = 0;
            while e < 512 {
                let ent = &fat.sector_buf[e..e + 32];
                if ent[0] == 0x00 {
                    return None;
                }
                if ent[0] == 0xe5 {
                    have_lfn = false;
                    e += 32;
                    continue;
                }

                let attr = ent[11];
                if attr == 0x0f {
                    let seq = (ent[0] & 0x1f) as usize;
                    let idx_positions = [1usize, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30];
                    let mut tmp = [0u8; 13];
                    let mut tn = 0;
                    for &p in &idx_positions {
                        let ch = (ent[p] as u16) | ((ent[p + 1] as u16) << 8);
                        if ch == 0 || ch == 0xffff {
                            break;
                        }
                        tmp[tn] = if ch < 0x80 { ch as u8 } else { b'?' };
                        tn += 1;
                    }
                    if seq > 0 {
                        let base = (seq - 1) * 13;
                        if base + tn <= lfn.len() {
                            lfn[base..base + tn].copy_from_slice(&tmp[..tn]);
                            if (ent[0] & 0x40) != 0 {
                                lfn_len = base + tn;
                            }
                        }
                    }
                    have_lfn = true;
                    e += 32;
                    continue;
                }

                if (attr & 0x08) != 0 {
                    have_lfn = false;
                    e += 32;
                    continue;
                }

                let cl_hi = u16::from_le_bytes([ent[20], ent[21]]) as u32;
                let cl_lo = u16::from_le_bytes([ent[26], ent[27]]) as u32;
                let cl = (cl_hi << 16) | cl_lo;
                let sz = u32::from_le_bytes([ent[28], ent[29], ent[30], ent[31]]);

                let entry = DirEntry {
                    cluster: cl,
                    size: sz,
                    is_dir: (attr & 0x10) != 0,
                };

                if have_lfn && ieq(&lfn[..lfn_len], name.as_bytes()) {
                    return Some(entry);
                }

                let mut sn = [0u8; 13];
                let snl = short_name(&ent[0..11], &mut sn);
                if ieq(&sn[..snl], name.as_bytes()) {
                    return Some(entry);
                }

                have_lfn = false;
                e += 32;
            }
        }

        match dir {
            DirMode::Root16 => sector_in_root += 1,
            DirMode::Chain(_) => cluster = next_cluster(fat, cluster),
        }
    }
}

fn read_chain_at(
    fat: &mut FatDriverState,
    start_cluster: u32,
    size: u32,
    offset: u64,
    buf: &mut [u8],
) -> usize {
    if offset >= size as u64 || buf.is_empty() {
        return 0;
    }
    let want = buf.len().min((size as u64 - offset) as usize);
    let cluster_bytes = (fat.state.sectors_per_cluster * 512) as u64;

    let mut cluster = start_cluster;
    let mut pos = 0u64;
    while pos + cluster_bytes <= offset {
        if is_eoc(&fat.state, cluster) || cluster < 2 {
            return 0;
        }
        cluster = next_cluster(fat, cluster);
        pos += cluster_bytes;
    }

    let mut written = 0;
    while written < want {
        if is_eoc(&fat.state, cluster) || cluster < 2 {
            break;
        }
        let sector_base = cluster_to_sector(&fat.state, cluster);
        for ss in 0..fat.state.sectors_per_cluster {
            let sector_off = pos + (ss as u64) * 512;
            if sector_off + 512 <= offset {
                continue;
            }
            if sector_off >= offset + (want as u64) {
                return written;
            }

            if !read_disk_blocks((sector_base + ss) as u64, 1, &mut fat.sector_buf) {
                return written;
            }

            let from = if sector_off < offset {
                (offset - sector_off) as usize
            } else {
                0
            };
            let to = ((offset + (want as u64) - sector_off) as usize).min(512);
            let chunk = to - from;
            buf[written..written + chunk].copy_from_slice(&fat.sector_buf[from..to]);
            written += chunk;
        }
        cluster = next_cluster(fat, cluster);
        pos += cluster_bytes;
    }
    written
}

fn fat_lookup(dvp: *mut Vnode, name: &str, vpp: &mut Option<*mut Vnode>) -> i32 {
    let mut fat = FAT.lock();
    let node = unsafe { (*dvp).data.expect("fat: missing node data") as *mut FatNode };
    let dir = if fat.state.kind != FatType::Fat32 && unsafe { (*node).cluster == 0 } {
        DirMode::Root16
    } else {
        DirMode::Chain(unsafe { (*node).cluster })
    };

    let Some(ent) = find_in_dir(&mut fat, dir, name) else {
        return -ENOENT;
    };

    let key = ent.cluster as u64;
    if let Some(cached) = vfs::vcache_lookup(unsafe { (*dvp).mount.unwrap() }, key) {
        *vpp = Some(cached);
        return 0;
    }

    let Some(vp) = vfs::valloc() else {
        return -ENOMEM;
    };
    let Some(fn_ptr) = alloc_fat_node(&mut fat) else {
        vfs::vrele(vp);
        return -ENOMEM;
    };

    unsafe {
        *fn_ptr = FatNode {
            cluster: ent.cluster,
            size: ent.size,
            is_dir: ent.is_dir,
            parent: (*node).cluster,
        };

        (*vp).ops = Some(&FAT_VNODE_OPS);
        (*vp).typ = if ent.is_dir { Vtype::Dir } else { Vtype::Reg };
        (*vp).mount = (*dvp).mount;
        (*vp).data = Some(fn_ptr as *mut u8);
        (*vp).key = key;
        vfs::vref(vp);

        *vpp = Some(vp);
        0
    }
}

fn fat_getattr(vp: *mut Vnode, vap: &mut Vattr) -> i32 {
    unsafe {
        let node = (*vp).data.expect("fat: missing node data") as *mut FatNode;
        vap.typ = (*vp).typ;
        vap.mode = if (*node).is_dir { 0o755 } else { 0o644 };
        vap.nlink = 1;
        vap.size = (*node).size as u64;
        vap.ino = (*node).cluster as u64;
        vap.blksize = 512;
        0
    }
}

fn fat_read(vp: *mut Vnode, offset: u64, buf: &mut [u8]) -> i64 {
    let mut fat = FAT.lock();
    let node = unsafe { (*vp).data.expect("fat: missing node data") as *mut FatNode };
    let n = read_chain_at(
        &mut fat,
        unsafe { (*node).cluster },
        unsafe { (*node).size },
        offset,
        buf,
    );
    n as i64
}

fn fat_inactive(vp: *mut Vnode) {
    let mut fat = FAT.lock();
    unsafe {
        if let Some(data_ptr) = (*vp).data {
            let node_ptr = data_ptr as *mut FatNode;
            let start = fat.fat_node_pool.as_ptr() as usize;
            let idx = (node_ptr as usize - start) / core::mem::size_of::<FatNode>();
            if idx < MAX_FAT_NODES {
                fat.fat_node_used[idx] = false;
            }
        }
    }
}

pub static FAT_VNODE_OPS: VnodeOps = VnodeOps {
    lookup: fat_lookup,
    getattr: fat_getattr,
    read: fat_read,
    inactive: fat_inactive,
};

fn fat_vfs_mount(mp: *mut Mount) -> i32 {
    let mut bpb = [0u8; 512];
    if !read_disk_blocks(0, 1, &mut bpb) {
        return -EIO;
    }

    let mut fat = FAT.lock();
    fat.state.bytes_per_sector = u16::from_le_bytes([bpb[11], bpb[12]]) as u32;
    fat.state.sectors_per_cluster = bpb[13] as u32;
    fat.state.reserved = u16::from_le_bytes([bpb[14], bpb[15]]) as u32;
    fat.state.num_fats = bpb[16] as u32;
    let root_entries = u16::from_le_bytes([bpb[17], bpb[18]]) as u32;
    let total16 = u16::from_le_bytes([bpb[19], bpb[20]]) as u32;
    let fat16_size = u16::from_le_bytes([bpb[22], bpb[23]]) as u32;
    let total32 = u32::from_le_bytes([bpb[32], bpb[33], bpb[34], bpb[35]]);

    if fat.state.bytes_per_sector != 512 || fat.state.sectors_per_cluster == 0 {
        return -EIO;
    }

    fat.state.fat_sectors = if fat16_size != 0 {
        fat16_size
    } else {
        u32::from_le_bytes([bpb[36], bpb[37], bpb[38], bpb[39]])
    };
    let total = if total16 != 0 { total16 } else { total32 };
    fat.state.root_dir_sectors = (root_entries * 32 + 511) / 512;
    fat.state.first_fat_sector = fat.state.reserved;
    fat.state.first_data_sector = fat.state.reserved
        + fat.state.num_fats * fat.state.fat_sectors
        + fat.state.root_dir_sectors;
    fat.state.root_dir_start = fat.state.reserved + fat.state.num_fats * fat.state.fat_sectors;
    fat.state.root_cluster = u32::from_le_bytes([bpb[44], bpb[45], bpb[46], bpb[47]]);

    let data_sectors = total.saturating_sub(fat.state.first_data_sector);
    let clusters = data_sectors / fat.state.sectors_per_cluster;
    fat.state.kind = if fat16_size == 0 {
        FatType::Fat32
    } else if clusters < 4085 {
        FatType::Fat12
    } else {
        FatType::Fat16
    };

    fat.fat_cache_rel = 0xffff_ffff;
    unsafe {
        (*mp).flags = 1; // Read-only
    }
    0
}

fn fat_vfs_root(mp: *mut Mount, vpp: &mut Option<*mut Vnode>) -> i32 {
    let Some(vp) = vfs::valloc() else {
        return -ENOMEM;
    };

    let mut fat = FAT.lock();
    let Some(node) = alloc_fat_node(&mut fat) else {
        vfs::vrele(vp);
        return -ENOMEM;
    };

    let root_cl = if fat.state.kind == FatType::Fat32 {
        fat.state.root_cluster
    } else {
        0
    };
    unsafe {
        *node = FatNode {
            cluster: root_cl,
            size: 0,
            is_dir: true,
            parent: root_cl,
        };

        (*vp).ops = Some(&FAT_VNODE_OPS);
        (*vp).typ = Vtype::Dir;
        (*vp).mount = Some(mp);
        (*vp).data = Some(node as *mut u8);
        (*vp).key = root_cl as u64;
        vfs::vref(vp);

        *vpp = Some(vp);
        0
    }
}

pub static FAT_VFS_OPS: VfsOps = VfsOps {
    mount: fat_vfs_mount,
    root: fat_vfs_root,
};

pub fn mount() -> bool {
    vfs::mount_root(&FAT_VFS_OPS)
}

pub fn read_file(path: &str, buf: &mut [u8]) -> Option<usize> {
    vfs::read_file(path, buf)
}
