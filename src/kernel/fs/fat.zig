//! Read-only FAT12/16/32 reader over a conduit `device.Block`, ported from
//! Midstall/weir's src/fs/fat.zig (a UEFI-firmware FAT driver) - the
//! cluster-chain/directory-scan logic is unchanged, only the block-device
//! type and the exposed entry points differ: no `fs.Fs` vtable here, just
//! `mount()` + `readFile()` directly, since this kernel has exactly one
//! rootfs.

const std = @import("std");
const conduit = @import("conduit");
const Block = conduit.device.Block;

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
            // A 12-bit entry can straddle a sector boundary; read two bytes safely.
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

/// Mount the partition. Returns an Fs handle or null.
pub fn mount(dev: Block) bool {
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
    // A zero 16-bit FAT size means FAT32 (it uses the 32-bit field); reliable
    // even for small volumes that the cluster-count rule would misjudge.
    s.kind = if (fat16_size == 0) .fat32 else if (clusters < 4085) .fat12 else .fat16;

    state = s;
    fat_cache_rel = 0xffffffff; // invalidate for the new volume
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

/// Build "NAME.EXT" (uppercased, trimmed) from an 8.3 entry.
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

// Directory location: fixed FAT12/16 root region, or a cluster chain.
const Dir = union(enum) { root16, chain: u32 };

/// Scan a directory for `name` (case-insensitive, matches LFN or short name).
fn findInDir(s: *State, dir: Dir, name: []const u8) ?Entry {
    var lfn: [260]u8 = undefined; // reconstructed long name (ASCII subset)
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
                if (ent[0] == 0x00) return null; // end of directory
                if (ent[0] == 0xe5) {
                    have_lfn = false;
                    continue;
                }
                const attr = ent[11];
                if (attr == 0x0f) {
                    // LFN fragment: 13 UTF-16 chars at fixed offsets, reversed order.
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
                        if (ent[0] & 0x40 != 0) lfn_len = base + tn; // last (first physically) entry sets length
                    }
                    have_lfn = true;
                    continue;
                }
                if (attr & 0x08 != 0) { // volume label
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

/// Read a file's cluster chain into `buf`, up to its size. Returns bytes read.
fn readChain(s: *State, start_cluster: u32, size: u32, buf: []u8) ?usize {
    if (size > buf.len) return null;
    const cluster_bytes = s.sectors_per_cluster * 512;
    var cluster = start_cluster;
    var written: usize = 0;
    while (written < size) {
        if (eoc(s, cluster) or cluster < 2) break;
        const sector = clusterToSector(s, cluster);
        var ss: u32 = 0;
        while (ss < s.sectors_per_cluster and written < size) : (ss += 1) {
            const chunk = @min(@as(usize, 512), size - written);
            if (chunk == 512) {
                if (!s.dev.readBlocks(sector + ss, 1, buf[written..][0..512])) return null;
            } else {
                if (!s.dev.readBlocks(sector + ss, 1, &sector_buf)) return null;
                @memcpy(buf[written..][0..chunk], sector_buf[0..chunk]);
            }
            written += chunk;
        }
        _ = cluster_bytes;
        cluster = nextCluster(s, cluster);
    }
    return written;
}

/// Read a file by path (components separated by '/' or '\\') into `buf`.
/// Returns bytes read, or null if any path component doesn't resolve.
pub fn readFile(path: []const u8, buf: []u8) ?usize {
    const s: *State = &state;

    var dir: Dir = if (s.kind == .fat32) .{ .chain = s.root_cluster } else .root16;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    var entry: ?Entry = null;
    while (it.next()) |comp| {
        const found = findInDir(s, dir, comp) orelse return null;
        if (it.peek() != null) {
            if (!found.is_dir) return null;
            dir = .{ .chain = found.cluster };
        } else {
            if (found.is_dir) return null;
            entry = found;
        }
    }
    const f = entry orelse return null;
    return readChain(s, f.cluster, f.size, buf);
}
