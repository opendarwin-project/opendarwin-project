//! Read-only FAT12/16/32 over a conduit `device.Block`, exposed as an
//! XNU/BSD-style VFS filesystem (`vfsops` / vnode ops). Cluster-chain and
//! directory-scan logic is unchanged from the earlier direct reader; the
//! public surface is now mount-via-VFS plus `readFile` for early boot.

const std = @import("std");
const conduit = @import("conduit");
const Block = conduit.device.Block;
const vfs = @import("vfs.zig");

const Type = enum { fat12, fat16, fat32 };

const State = struct {
    dev: Block = undefined,
    bytes_per_sector: u32 = 0,
    sectors_per_cluster: u32 = 0,
    reserved: u32 = 0,
    num_fats: u32 = 0,
    fat_sectors: u32 = 0,
    first_data_sector: u32 = 0,
    first_fat_sector: u32 = 0,
    root_cluster: u32 = 0, // FAT32
    root_dir_sectors: u32 = 0, // FAT12/16
    root_dir_start: u32 = 0, // FAT12/16 first sector
    kind: Type = .fat32,
};

/// Per-vnode FAT cookie.
const FatNode = struct {
    cluster: u32 = 0,
    size: u32 = 0,
    is_dir: bool = false,
    /// Parent directory cluster (root's parent is itself).
    parent: u32 = 0,
};

var state: State = .{};
var sector_buf: [512]u8 = undefined;

// One-sector FAT cache: chain-walk touches consecutive entries sharing a sector,
// so caching the last one turns a per-cluster read into a hit. `fat_cache_rel`
// is the FAT-relative sector, 0xffffffff means invalid.
var fat_cache_buf: [512]u8 = undefined;
var fat_cache_rel: u32 = 0xffffffff;

fn readFatSector(s: *const State, rel: u32) ?*[512]u8 {
    if (fat_cache_rel != rel) {
        if (!s.dev.readBlocks(s.first_fat_sector + rel, 1, &fat_cache_buf)) return null;
        fat_cache_rel = rel;
    }
    return &fat_cache_buf;
}

fn clusterToSector(s: *const State, cluster: u32) u32 {
    return s.first_data_sector + (cluster - 2) * s.sectors_per_cluster;
}

fn eoc(s: *const State, cluster: u32) bool {
    return switch (s.kind) {
        .fat12 => cluster >= 0xff8,
        .fat16 => cluster >= 0xfff8,
        .fat32 => cluster >= 0x0ffffff8,
    };
}

/// Next cluster in a chain from the FAT.
fn nextCluster(s: *const State, cluster: u32) u32 {
    switch (s.kind) {
        .fat32 => {
            const off = cluster * 4;
            const buf = readFatSector(s, off / 512) orelse return 0x0fffffff;
            return std.mem.readInt(u32, buf[off % 512 ..][0..4], .little) & 0x0fffffff;
        },
        .fat16 => {
            const off = cluster * 2;
            const buf = readFatSector(s, off / 512) orelse return 0xffff;
            return std.mem.readInt(u16, buf[off % 512 ..][0..2], .little);
        },
        .fat12 => {
            const off = cluster + cluster / 2;
            const buf = readFatSector(s, off / 512) orelse return 0xfff;
            const lo = buf[off % 512];
            const hi = if (off % 512 == 511) blk: {
                var nb: [512]u8 = undefined;
                _ = s.dev.readBlocks(s.first_fat_sector + off / 512 + 1, 1, &nb);
                break :blk nb[0];
            } else buf[off % 512 + 1];
            const v = @as(u16, lo) | (@as(u16, hi) << 8);
            return if (cluster & 1 == 0) v & 0xfff else v >> 4;
        },
    }
}

fn mountVolume(dev: Block) bool {
    var bpb: [512]u8 = undefined;
    if (!dev.readBlocks(0, 1, &bpb)) return false;

    var s = State{ .dev = dev };
    s.bytes_per_sector = std.mem.readInt(u16, bpb[11..13], .little);
    s.sectors_per_cluster = bpb[13];
    s.reserved = std.mem.readInt(u16, bpb[14..16], .little);
    s.num_fats = bpb[16];
    const root_entries = std.mem.readInt(u16, bpb[17..19], .little);
    const total16 = std.mem.readInt(u16, bpb[19..21], .little);
    const fat16_size = std.mem.readInt(u16, bpb[22..24], .little);
    const total32 = std.mem.readInt(u32, bpb[32..36], .little);
    if (s.bytes_per_sector != 512 or s.sectors_per_cluster == 0) return false;

    s.fat_sectors = if (fat16_size != 0) fat16_size else std.mem.readInt(u32, bpb[36..40], .little);
    const total = if (total16 != 0) @as(u32, total16) else total32;
    s.root_dir_sectors = (@as(u32, root_entries) * 32 + 511) / 512;
    s.first_fat_sector = s.reserved;
    s.first_data_sector = s.reserved + s.num_fats * s.fat_sectors + s.root_dir_sectors;
    s.root_dir_start = s.reserved + s.num_fats * s.fat_sectors;
    s.root_cluster = std.mem.readInt(u32, bpb[44..48], .little);

    const data_sectors = total - s.first_data_sector;
    const clusters = data_sectors / s.sectors_per_cluster;
    s.kind = if (fat16_size == 0) .fat32 else if (clusters < 4085) .fat12 else .fat16;

    state = s;
    fat_cache_rel = 0xffffffff;
    return true;
}

fn upper(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

fn ieq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (upper(x) != upper(y)) return false;
    return true;
}

fn shortName(raw: []const u8, out: []u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < 8 and raw[i] != ' ') : (i += 1) {
        out[n] = upper(raw[i]);
        n += 1;
    }
    if (raw[8] != ' ') {
        out[n] = '.';
        n += 1;
        i = 8;
        while (i < 11 and raw[i] != ' ') : (i += 1) {
            out[n] = upper(raw[i]);
            n += 1;
        }
    }
    return n;
}

const Entry = struct { cluster: u32, size: u32, is_dir: bool };
const Dir = union(enum) { root16, chain: u32 };

fn rootClusterKey() u32 {
    return if (state.kind == .fat32) state.root_cluster else 0;
}

fn dirFromCluster(cluster: u32) Dir {
    if (state.kind != .fat32 and cluster == 0) return .root16;
    return .{ .chain = cluster };
}

fn findInDir(s: *State, dir: Dir, name: []const u8) ?Entry {
    var lfn: [260]u8 = undefined;
    var lfn_len: usize = 0;
    var have_lfn = false;

    var cluster: u32 = switch (dir) {
        .root16 => 0,
        .chain => |c| c,
    };
    var sector_in_root: u32 = 0;

    while (true) {
        var sector: u32 = undefined;
        var sectors_this: u32 = undefined;
        switch (dir) {
            .root16 => {
                if (sector_in_root >= s.root_dir_sectors) return null;
                sector = s.root_dir_start + sector_in_root;
                sectors_this = 1;
            },
            .chain => {
                if (eoc(s, cluster) or cluster < 2) return null;
                sector = clusterToSector(s, cluster);
                sectors_this = s.sectors_per_cluster;
            },
        }

        var ss: u32 = 0;
        while (ss < sectors_this) : (ss += 1) {
            if (!s.dev.readBlocks(sector + ss, 1, &sector_buf)) return null;
            var e: usize = 0;
            while (e < 512) : (e += 32) {
                const ent = sector_buf[e .. e + 32];
                if (ent[0] == 0x00) return null;
                if (ent[0] == 0xe5) {
                    have_lfn = false;
                    continue;
                }
                const attr = ent[11];
                if (attr == 0x0f) {
                    const seq = ent[0] & 0x1f;
                    const idx_positions = [13]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
                    var tmp: [13]u8 = undefined;
                    var tn: usize = 0;
                    for (idx_positions) |p| {
                        const ch = @as(u16, ent[p]) | (@as(u16, ent[p + 1]) << 8);
                        if (ch == 0 or ch == 0xffff) break;
                        tmp[tn] = if (ch < 0x80) @intCast(ch) else '?';
                        tn += 1;
                    }
                    const base = (seq - 1) * 13;
                    if (base + tn <= lfn.len) {
                        @memcpy(lfn[base .. base + tn], tmp[0..tn]);
                        if (ent[0] & 0x40 != 0) lfn_len = base + tn;
                    }
                    have_lfn = true;
                    continue;
                }
                if (attr & 0x08 != 0) {
                    have_lfn = false;
                    continue;
                }

                const cl = (@as(u32, std.mem.readInt(u16, ent[20..22], .little)) << 16) |
                    std.mem.readInt(u16, ent[26..28], .little);
                const entry = Entry{
                    .cluster = cl,
                    .size = std.mem.readInt(u32, ent[28..32], .little),
                    .is_dir = attr & 0x10 != 0,
                };

                if (have_lfn and ieq(lfn[0..lfn_len], name)) return entry;
                var sn: [13]u8 = undefined;
                const snl = shortName(ent[0..11], &sn);
                if (ieq(sn[0..snl], name)) return entry;
                have_lfn = false;
            }
        }

        switch (dir) {
            .root16 => sector_in_root += 1,
            .chain => cluster = nextCluster(s, cluster),
        }
    }
}

fn readChainAt(s: *State, start_cluster: u32, size: u32, offset: u64, buf: []u8) ?usize {
    if (offset >= size or buf.len == 0) return 0;
    const want: usize = @intCast(@min(@as(u64, buf.len), @as(u64, size) - offset));
    const cluster_bytes: u64 = s.sectors_per_cluster * 512;

    var cluster = start_cluster;
    var pos: u64 = 0;
    while (pos + cluster_bytes <= offset) {
        if (eoc(s, cluster) or cluster < 2) return 0;
        cluster = nextCluster(s, cluster);
        pos += cluster_bytes;
    }

    var written: usize = 0;
    while (written < want) {
        if (eoc(s, cluster) or cluster < 2) break;
        const sector_base = clusterToSector(s, cluster);
        var ss: u32 = 0;
        while (ss < s.sectors_per_cluster and written < want) : (ss += 1) {
            const sector_off: u64 = pos + @as(u64, ss) * 512;
            if (sector_off + 512 <= offset) continue;
            if (sector_off >= offset + want) return written;

            if (!s.dev.readBlocks(sector_base + ss, 1, &sector_buf)) return null;
            const from: usize = if (sector_off < offset) @intCast(offset - sector_off) else 0;
            const to: usize = @intCast(@min(@as(u64, 512), offset + want - sector_off));
            const chunk = to - from;
            @memcpy(buf[written..][0..chunk], sector_buf[from..to]);
            written += chunk;
        }
        cluster = nextCluster(s, cluster);
        pos += cluster_bytes;
    }
    return written;
}

fn fatNode(vp: *vfs.Vnode) *FatNode {
    return @ptrCast(@alignCast(vp.data.?));
}

const MAX_FAT_NODES = 128;
var fat_node_pool: [MAX_FAT_NODES]FatNode = [_]FatNode{.{}} ** MAX_FAT_NODES;
var fat_node_used: [MAX_FAT_NODES]bool = [_]bool{false} ** MAX_FAT_NODES;

fn allocFatNode() ?*FatNode {
    for (&fat_node_pool, 0..) |*n, i| {
        if (!fat_node_used[i]) {
            fat_node_used[i] = true;
            n.* = .{};
            return n;
        }
    }
    return null;
}

fn freeFatNode(n: *FatNode) void {
    const base = @intFromPtr(&fat_node_pool);
    const addr = @intFromPtr(n);
    if (addr < base) return;
    const idx = (addr - base) / @sizeOf(FatNode);
    if (idx < MAX_FAT_NODES) fat_node_used[idx] = false;
}

fn getOrMakeVnode(mp: *vfs.Mount, cluster: u32, size: u32, is_dir: bool, parent: u32) ?*vfs.Vnode {
    const key: u64 = cluster;
    if (vfs.vcacheLookup(mp, key)) |vp| return vp;

    const vp = vfs.valloc() orelse return null;
    const node = allocFatNode() orelse {
        vp.* = .{};
        return null;
    };
    node.* = .{ .cluster = cluster, .size = size, .is_dir = is_dir, .parent = parent };
    vp.* = .{
        .ops = &vnode_ops,
        .typ = if (is_dir) .dir else .reg,
        .mount = mp,
        .data = node,
        .usecount = 1,
        .key = key,
    };
    return vp;
}

fn fatLookup(dvp: *vfs.Vnode, name: []const u8, vpp: *?*vfs.Vnode) i32 {
    const mp = dvp.mount orelse return -vfs.EINVAL;
    const dn = fatNode(dvp);

    if (name.len == 2 and name[0] == '.' and name[1] == '.') {
        const parent = dn.parent;
        const vp = getOrMakeVnode(mp, parent, 0, true, parent) orelse return -vfs.ENOMEM;
        vpp.* = vp;
        return 0;
    }

    const dir = dirFromCluster(dn.cluster);
    const found = findInDir(&state, dir, name) orelse return -vfs.ENOENT;
    const vp = getOrMakeVnode(mp, found.cluster, found.size, found.is_dir, dn.cluster) orelse return -vfs.ENOMEM;
    vpp.* = vp;
    return 0;
}

fn fatGetattr(vp: *vfs.Vnode, vap: *vfs.Vattr) i32 {
    const n = fatNode(vp);
    vap.* = .{
        .typ = vp.typ,
        .mode = 0,
        .nlink = 1,
        .size = if (n.is_dir) 0 else n.size,
        .ino = n.cluster,
        .blksize = state.sectors_per_cluster * 512,
    };
    return 0;
}

fn fatRead(vp: *vfs.Vnode, offset: u64, buf: []u8) i64 {
    const n = fatNode(vp);
    if (n.is_dir) return -vfs.EISDIR;
    const got = readChainAt(&state, n.cluster, n.size, offset, buf) orelse return -vfs.EIO;
    return @intCast(got);
}

fn fatInactive(vp: *vfs.Vnode) void {
    if (vp.data) |d| freeFatNode(@ptrCast(@alignCast(d)));
}

const vnode_ops: vfs.VnodeOps = .{
    .lookup = fatLookup,
    .getattr = fatGetattr,
    .read = fatRead,
    .inactive = fatInactive,
};

fn fatVfsMount(mp: *vfs.Mount, dev: Block) i32 {
    if (!mountVolume(dev)) return -vfs.ENODEV;
    mp.data = &state;
    return 0;
}

fn fatVfsRoot(mp: *vfs.Mount, vpp: *?*vfs.Vnode) i32 {
    const key = rootClusterKey();
    const vp = getOrMakeVnode(mp, key, 0, true, key) orelse return -vfs.ENOMEM;
    vpp.* = vp;
    return 0;
}

pub const vfsops: vfs.VfsOps = .{
    .mount = fatVfsMount,
    .root = fatVfsRoot,
};

/// Mount as the system root via VFS.
pub fn mount(dev: Block) bool {
    return vfs.mountRoot(&vfsops, dev);
}

/// Read a file by path into `buf`. Routes through VFS once root is mounted.
pub fn readFile(path: []const u8, buf: []u8) ?usize {
    return vfs.readFile(path, buf);
}
