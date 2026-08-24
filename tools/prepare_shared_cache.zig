//! Host tool: prepares a FAT32 rootfs image containing a target Mach-O
//! binary (e.g. /bin/sh) plus the small sparse slices of the real macOS
//! dyld shared cache it needs, for src/kernel/loader/{macho,dyld,
//! shared_cache}.zig to load and dynamically link at boot - see those
//! modules' doc comments for the format background this mirrors.
//!
//! Unlike dyld_shared_cache_util -extract, this does not synthesize a
//! standalone dylib: it copies real cache bytes (TEXT/DATA/AUTH segments,
//! export tries, slide-info) at their genuine cache addresses, verified
//! against Apple's actual dyld_cache_format.h/fixup-chains.h structs by
//! cross-checking against a live cache (see the chat history / shared_cache
//! .zig's doc comment for what was verified and how).
//!
//! Usage:
//!   prepare_shared_cache <cache_dir> <binary_path> <out_image.img>
//!
//! `cache_dir` is the directory holding dyld_shared_cache_arm64e and its
//! subCache files (on modern macOS:
//! /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/).

const std = @import("std");
const sc = @import("shared_cache");
const manifest_mod = @import("rootfs_manifest");

const LC_SEGMENT_64: u32 = 0x19;
const LC_LOAD_DYLIB: u32 = 0xc;
const LC_REEXPORT_DYLIB: u32 = 0x8000001f;
const LC_DYLD_EXPORTS_TRIE: u32 = 0x80000033;
const LC_DYLD_CHAINED_FIXUPS: u32 = 0x80000034;

const MachSeg = struct { name: [16]u8, vmaddr: u64, vmsize: u64, fileoff: u64, filesize: u64 };

const ParsedImage = struct {
    segs: std.ArrayList(MachSeg),
    reexports: std.ArrayList([]const u8),
    loads: std.ArrayList([]const u8),
    trie: ?struct { dataoff: u64, datasize: u64 } = null,
    fixups: ?struct { dataoff: u64, datasize: u64 } = null,
};

fn segName(s: *const MachSeg) []const u8 {
    const end = std.mem.indexOfScalar(u8, &s.name, 0) orelse s.name.len;
    return s.name[0..end];
}

fn findSeg(image: *const ParsedImage, name: []const u8) ?MachSeg {
    for (image.segs.items) |s| {
        if (std.mem.eql(u8, segName(&s), name)) return s;
    }
    return null;
}

/// Parses Mach-O load commands starting at `header_off` within `bytes`
/// (works for both a cache-resident image and a plain on-disk binary - the
/// load command shapes are identical either way).
fn parseImage(gpa: std.mem.Allocator, bytes: []const u8, header_off: usize) !ParsedImage {
    const ncmds = std.mem.readInt(u32, bytes[header_off + 16 ..][0..4], .little);
    var result = ParsedImage{
        .segs = .empty,
        .reexports = .empty,
        .loads = .empty,
    };
    var off = header_off + 32;
    var i: u32 = 0;
    while (i < ncmds) : (i += 1) {
        const cmd = std.mem.readInt(u32, bytes[off..][0..4], .little);
        const cmdsize = std.mem.readInt(u32, bytes[off + 4 ..][0..4], .little);
        switch (cmd) {
            LC_SEGMENT_64 => {
                var name: [16]u8 = undefined;
                @memcpy(&name, bytes[off + 8 ..][0..16]);
                try result.segs.append(gpa, .{
                    .name = name,
                    .vmaddr = std.mem.readInt(u64, bytes[off + 24 ..][0..8], .little),
                    .vmsize = std.mem.readInt(u64, bytes[off + 32 ..][0..8], .little),
                    .fileoff = std.mem.readInt(u64, bytes[off + 40 ..][0..8], .little),
                    .filesize = std.mem.readInt(u64, bytes[off + 48 ..][0..8], .little),
                });
            },
            LC_LOAD_DYLIB, LC_REEXPORT_DYLIB => {
                const name_off = std.mem.readInt(u32, bytes[off + 8 ..][0..4], .little);
                const name_bytes = bytes[off + name_off .. off + cmdsize];
                const end = std.mem.indexOfScalar(u8, name_bytes, 0) orelse name_bytes.len;
                const name = try gpa.dupe(u8, name_bytes[0..end]);
                if (cmd == LC_REEXPORT_DYLIB) try result.reexports.append(gpa, name) else try result.loads.append(gpa, name);
            },
            LC_DYLD_EXPORTS_TRIE => {
                result.trie = .{
                    .dataoff = std.mem.readInt(u32, bytes[off + 8 ..][0..4], .little),
                    .datasize = std.mem.readInt(u32, bytes[off + 12 ..][0..4], .little),
                };
            },
            LC_DYLD_CHAINED_FIXUPS => {
                result.fixups = .{
                    .dataoff = std.mem.readInt(u32, bytes[off + 8 ..][0..4], .little),
                    .datasize = std.mem.readInt(u32, bytes[off + 12 ..][0..4], .little),
                };
            },
            else => {},
        }
        off += cmdsize;
    }
    return result;
}

/// Index over every dyld_shared_cache_arm64e* file in `cache_dir`, each
/// file's small (4KB) header kept resident so `resolve()` can find which
/// file backs a given cache address without re-reading anything.
const CacheIndex = struct {
    const Entry = struct { path: []const u8, header: []u8 };
    entries: std.ArrayList(Entry),
    io: std.Io,
    gpa: std.mem.Allocator,

    fn build(gpa: std.mem.Allocator, io: std.Io, cache_dir: []const u8) !CacheIndex {
        var self = CacheIndex{ .entries = .empty, .io = io, .gpa = gpa };
        var dir = try std.Io.Dir.cwd().openDir(io, cache_dir, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "dyld_shared_cache_arm64e")) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ cache_dir, entry.name });
            const header = try readAt(io, gpa, path, 0, 4096);
            if (sc.readHeader(header) == null) {
                gpa.free(header);
                gpa.free(path);
                continue;
            }
            try self.entries.append(gpa, .{ .path = path, .header = header });
        }
        return self;
    }

    fn resolve(self: *const CacheIndex, addr: u64) !?struct { path: []const u8, file_off: u64 } {
        for (self.entries.items) |e| {
            const header = sc.readHeader(e.header).?;
            if (sc.addressToFileOffset(e.header, header, addr)) |file_off| {
                return .{ .path = e.path, .file_off = file_off };
            }
        }
        return null;
    }

    fn resolveWithMapping(self: *const CacheIndex, addr: u64) !?struct { path: []const u8, mapping: sc.MappingAndSlideInfo } {
        for (self.entries.items) |e| {
            const header = sc.readHeader(e.header).?;
            if (sc.findMappingWithSlide(e.header, header, addr)) |m| {
                return .{ .path = e.path, .mapping = m };
            }
        }
        return null;
    }

    fn readImageAt(self: *const CacheIndex, gpa: std.mem.Allocator, addr: u64, len: usize) ![]u8 {
        const loc = (try self.resolve(addr)) orelse return error.AddressNotInCache;
        return readAt(self.io, gpa, loc.path, loc.file_off, len);
    }
};

fn readAt(io: std.Io, gpa: std.mem.Allocator, path: []const u8, offset: u64, len: usize) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const buf = try gpa.alloc(u8, len);
    var reader = file.reader(io, &.{});
    try reader.seekTo(offset);
    const n = try reader.interface.readSliceShort(buf);
    return buf[0..n];
}

const main_cache_name = "dyld_shared_cache_arm64e";

fn findImageAddr(main_bytes: []const u8, header: *const sc.CacheHeader, path: []const u8) ?u64 {
    return sc.findImage(main_bytes, header, path);
}

fn getTrieBytes(gpa: std.mem.Allocator, index: *const CacheIndex, mach_addr: u64) !?[]u8 {
    const loc = (try index.resolve(mach_addr)) orelse return null;
    const hdr_bytes = try readAt(index.io, gpa, loc.path, loc.file_off, 16384);
    defer gpa.free(hdr_bytes);
    var image = try parseImage(gpa, hdr_bytes, 0);
    defer freeImage(gpa, &image);
    const linkedit = findSeg(&image, "__LINKEDIT") orelse return null;
    const trie_cmd = image.trie orelse return null;
    const trie_addr = sc.linkeditDataoffToAddress(linkedit.vmaddr, linkedit.fileoff, trie_cmd.dataoff);
    return try index.readImageAt(gpa, trie_addr, trie_cmd.datasize);
}

fn freeImage(gpa: std.mem.Allocator, image: *ParsedImage) void {
    for (image.reexports.items) |r| gpa.free(r);
    for (image.loads.items) |l| gpa.free(l);
    image.segs.deinit(gpa);
    image.reexports.deinit(gpa);
    image.loads.deinit(gpa);
}

const Resolved = struct { dylib_path: []const u8, mach_addr: u64 };

/// Resolves one symbol starting from `start_dylib_path`'s own export trie,
/// then (one level, matching this tool's validated /bin/sh scope - see this
/// file's doc comment) each of its LC_REEXPORT_DYLIB entries in order.
fn resolveSymbol(
    gpa: std.mem.Allocator,
    index: *const CacheIndex,
    main_bytes: []const u8,
    main_header: *const sc.CacheHeader,
    start_dylib_path: []const u8,
    symbol: []const u8,
) !?Resolved {
    const start_addr = findImageAddr(main_bytes, main_header, start_dylib_path) orelse return null;

    if (try getTrieBytes(gpa, index, start_addr)) |trie| {
        defer gpa.free(trie);
        if (sc.lookupExport(trie, symbol) != null) {
            return .{ .dylib_path = start_dylib_path, .mach_addr = start_addr };
        }
    }

    const loc = (try index.resolve(start_addr)) orelse return null;
    const hdr_bytes = try readAt(index.io, gpa, loc.path, loc.file_off, 16384);
    defer gpa.free(hdr_bytes);
    var image = try parseImage(gpa, hdr_bytes, 0);
    defer freeImage(gpa, &image);

    for (image.reexports.items) |reexport_path| {
        const addr = findImageAddr(main_bytes, main_header, reexport_path) orelse continue;
        const trie = (try getTrieBytes(gpa, index, addr)) orelse continue;
        defer gpa.free(trie);
        if (sc.lookupExport(trie, symbol) != null) {
            // `reexport_path` is a slice into `image`, freed by the `defer`
            // above when this function returns - must outlive that.
            return .{ .dylib_path = try gpa.dupe(u8, reexport_path), .mach_addr = addr };
        }
    }
    return null;
}

/// One blob to be written into the FAT image, tagged with its 8.3 name.
const Blob = struct { name: [12]u8, data: []const u8 };

/// Produces a plain, null-terminated, extension-less ASCII name (<=8 chars,
/// all callers below stay within that) - this is what's stored in the
/// manifest and what the kernel will pass to fs/fat.zig's `readFile`.
/// `rawFatName` derives the actual FAT directory-entry bytes from this at
/// image-write time.
fn blobName(comptime fmt: []const u8, args: anytype) [12]u8 {
    var buf: [12]u8 = [_]u8{0} ** 12;
    _ = std.fmt.bufPrint(&buf, fmt, args) catch unreachable;
    return buf;
}

/// Converts a plain name (as `blobName` produces) to a raw FAT 8.3
/// directory-entry name+ext field (11 bytes, space-padded, no dot).
fn rawFatName(name: [12]u8) [11]u8 {
    var raw: [11]u8 = [_]u8{' '} ** 11;
    const end = std.mem.indexOfScalar(u8, &name, 0) orelse name.len;
    const len = @min(end, 8);
    @memcpy(raw[0..len], name[0..len]);
    return raw;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = arg_it.next(); // argv[0]
    const cache_dir = arg_it.next() orelse {
        std.debug.print("usage: prepare_shared_cache <cache_dir> <binary_path> <out_image.img>\n", .{});
        return error.BadArgs;
    };
    const binary_path = arg_it.next() orelse return error.BadArgs;
    const out_image = arg_it.next() orelse return error.BadArgs;

    std.debug.print("indexing cache files in {s}...\n", .{cache_dir});
    var index = try CacheIndex.build(gpa, io, cache_dir);
    std.debug.print("indexed {d} cache files\n", .{index.entries.items.len});

    var main_cache_path_buf: [1024]u8 = undefined;
    const main_cache_path = try std.fmt.bufPrint(&main_cache_path_buf, "{s}/{s}", .{ cache_dir, main_cache_name });
    const main_bytes = try readAt(io, gpa, main_cache_path, 0, 4 * 1024 * 1024);
    const main_header = sc.readHeader(main_bytes) orelse return error.BadMainCacheHeader;

    // --- Parse the target binary (handle a fat/universal Mach-O). ---
    const bin_bytes = try readAt(io, gpa, binary_path, 0, 64 * 1024 * 1024);
    const bin_header_off = try findArm64eSlice(bin_bytes);
    const bin_image = try parseImage(gpa, bin_bytes, bin_header_off);
    const fixups = bin_image.fixups orelse return error.NoChainedFixups;
    const fixups_bytes = bin_bytes[bin_header_off + fixups.dataoff ..][0..fixups.datasize];

    const imports = try enumerateImports(gpa, fixups_bytes);
    std.debug.print("binary imports {d} symbols\n", .{imports.len});

    // --- Resolve every import to its real owning dylib. ---
    var needed = std.ArrayList([]const u8).empty; // unique dylib paths, first-use order
    var resolved = try gpa.alloc(Resolved, imports.len);
    for (imports, 0..) |imp, i| {
        if (imp.ordinal == 0 or imp.ordinal > bin_image.loads.items.len) return error.BadOrdinal;
        const start_path = bin_image.loads.items[imp.ordinal - 1];
        const r = (try resolveSymbol(gpa, &index, main_bytes, main_header, start_path, imp.name)) orelse {
            std.debug.print("  UNRESOLVED: {s}\n", .{imp.name});
            return error.UnresolvedSymbol;
        };
        std.debug.print("  {s} -> {s} @ 0x{x}\n", .{ imp.name, r.dylib_path, r.mach_addr });
        resolved[i] = r;
        var already = false;
        for (needed.items) |n| {
            if (std.mem.eql(u8, n, r.dylib_path)) {
                already = true;
                break;
            }
        }
        if (!already) try needed.append(gpa, r.dylib_path);
    }

    if (needed.items.len > manifest_mod.MAX_DYLIBS) return error.TooManyDylibs;

    // --- Extract each needed dylib's TEXT + any DATA/AUTH segments (with
    // slide info, page-aligned to the owning mapping) + export trie. ---
    var manifest = manifest_mod.Manifest{};
    manifest.shared_region_start = main_header.shared_region_start;
    manifest.dylib_count = @intCast(needed.items.len);

    var blobs = std.ArrayList(Blob).empty;

    for (needed.items, 0..) |dylib_path, dylib_idx| {
        const mach_addr = findImageAddr(main_bytes, main_header, dylib_path) orelse return error.NotFound;
        const loc = (try index.resolve(mach_addr)) orelse return error.NotFound;
        const hdr_bytes = try readAt(io, gpa, loc.path, loc.file_off, 16384);
        var image = try parseImage(gpa, hdr_bytes, 0);

        var db = manifest_mod.DylibBlob{ .mach_header_va = mach_addr };
        var seg_idx: usize = 0;

        for (image.segs.items) |s| {
            if (s.vmsize == 0) continue;
            const name = segName(&s);
            if (std.mem.eql(u8, name, "__LINKEDIT")) continue;
            if (seg_idx >= manifest_mod.MAX_SEGMENTS_PER_DYLIB) return error.TooManySegments;

            var seg = manifest_mod.Segment{ .va = s.vmaddr };
            seg.blob = blobName("D{d}S{d}", .{ dylib_idx, seg_idx });

            if (std.mem.eql(u8, name, "__TEXT")) {
                // TEXT never carries slide-able data pointers in practice
                // (verified: every TEXT mapping inspected had no slide
                // info at all) - copy exactly the segment's own bytes.
                // `fileoff` on a cache-resident LC_SEGMENT_64 is already an
                // absolute offset within whichever cache file holds it
                // (verified: matched `loc.file_off` exactly for a segment
                // starting at the mach_header) - unlike LC_DYLD_EXPORTS_TRIE's
                // `dataoff`, which needs the linkedit-relative translation
                // (see `linkeditDataoffToAddress`'s doc comment).
                const data = try readAt(io, gpa, loc.path, s.fileoff, s.filesize);
                seg.len = @intCast(data.len);
                try blobs.append(gpa, .{ .name = seg.blob, .data = data });
            } else {
                // DATA/AUTH: page-align to the owning mapping's slide-info
                // page grid (see applySlide's doc comment on why) and copy
                // the whole slide-info blob too.
                const map_loc = (try index.resolveWithMapping(s.vmaddr)) orelse return error.NotFound;
                const mapping = map_loc.mapping;

                var slide_hdr_buf: [12]u8 = undefined;
                var page_size: u64 = 16384;
                if (mapping.slide_info_file_size > 0) {
                    const peek = try readAt(io, gpa, map_loc.path, mapping.slide_info_file_offset, 12);
                    @memcpy(&slide_hdr_buf, peek[0..12]);
                    gpa.free(peek);
                    page_size = std.mem.readInt(u32, slide_hdr_buf[4..8], .little);
                }

                const seg_start_page = (s.vmaddr - mapping.address) / page_size;
                const seg_end_page = ((s.vmaddr + s.vmsize - mapping.address) + page_size - 1) / page_size;
                const extract_va = mapping.address + seg_start_page * page_size;
                const extract_len = (seg_end_page - seg_start_page) * page_size;
                const extract_file_off = mapping.file_offset + seg_start_page * page_size;

                const data = try readAt(io, gpa, map_loc.path, extract_file_off, extract_len);
                seg.va = extract_va;
                seg.len = @intCast(data.len);
                try blobs.append(gpa, .{ .name = seg.blob, .data = data });

                if (mapping.slide_info_file_size > 0) {
                    const slide_data = try readAt(io, gpa, map_loc.path, mapping.slide_info_file_offset, mapping.slide_info_file_size);
                    seg.slide_len = @intCast(slide_data.len);
                    seg.slide_mapping_va = mapping.address;
                    seg.slide_blob = blobName("D{d}L{d}", .{ dylib_idx, seg_idx });
                    try blobs.append(gpa, .{ .name = seg.slide_blob, .data = slide_data });
                }
            }

            db.segments[seg_idx] = seg;
            seg_idx += 1;
        }
        db.segment_count = @intCast(seg_idx);

        if (try getTrieBytes(gpa, &index, mach_addr)) |trie| {
            db.trie_len = @intCast(trie.len);
            db.trie_blob = blobName("D{d}TRIE", .{dylib_idx});
            try blobs.append(gpa, .{ .name = db.trie_blob, .data = trie });
        }

        manifest.dylibs[dylib_idx] = db;
        freeImage(gpa, &image);
        gpa.free(hdr_bytes);

        std.debug.print("dylib {d}: {s} - {d} segments\n", .{ dylib_idx, dylib_path, seg_idx });
    }

    manifest.main_blob = blobName("MAIN", .{});
    const main_slice = bin_bytes[bin_header_off..];
    manifest.main_len = @intCast(main_slice.len);
    try blobs.append(gpa, .{ .name = manifest.main_blob, .data = main_slice });

    const manifest_name: [12]u8 = blobName("MANIFEST", .{});
    try blobs.append(gpa, .{ .name = manifest_name, .data = std.mem.asBytes(&manifest) });

    std.log.debug("writing {d} blobs to {s}...\n", .{ blobs.items.len, out_image });
    try writeFatImage(io, gpa, out_image, blobs.items);
    std.log.debug("done\n", .{});
}

const Import = struct { ordinal: u8, name: []const u8 };

fn enumerateImports(gpa: std.mem.Allocator, fixups_bytes: []const u8) ![]Import {
    const fixups_version = std.mem.readInt(u32, fixups_bytes[0..4], .little);
    _ = fixups_version;
    const imports_offset = std.mem.readInt(u32, fixups_bytes[8..12], .little);
    const symbols_offset = std.mem.readInt(u32, fixups_bytes[12..16], .little);
    const imports_count = std.mem.readInt(u32, fixups_bytes[16..20], .little);
    const imports_format = std.mem.readInt(u32, fixups_bytes[20..24], .little);
    if (imports_format != 1) return error.UnsupportedImportFormat; // DYLD_CHAINED_IMPORT

    var out = try gpa.alloc(Import, imports_count);
    const strings = fixups_bytes[symbols_offset..];
    var i: u32 = 0;
    while (i < imports_count) : (i += 1) {
        const entry = std.mem.readInt(u32, fixups_bytes[imports_offset + i * 4 ..][0..4], .little);
        const lib_ordinal: u8 = @truncate(entry & 0xFF);
        const name_offset = entry >> 9;
        const name_bytes = strings[name_offset..];
        const end = std.mem.indexOfScalar(u8, name_bytes, 0) orelse name_bytes.len;
        out[i] = .{ .ordinal = lib_ordinal, .name = name_bytes[0..end] };
    }
    return out;
}

/// Finds the arm64e slice's mach_header offset in `bytes`: either a fat
/// (universal) binary's matching architecture, or offset 0 if it's already
/// a thin arm64e Mach-O.
fn findArm64eSlice(bytes: []const u8) !usize {
    const CPU_TYPE_ARM64: u32 = 0x0100000c;
    const CPU_SUBTYPE_ARM64E: u32 = 2;
    const FAT_MAGIC: u32 = 0xcafebabe;
    const MH_MAGIC_64: u32 = 0xfeedfacf;

    const magic_be = std.mem.readInt(u32, bytes[0..4], .big);
    if (magic_be == FAT_MAGIC) {
        const nfat = std.mem.readInt(u32, bytes[4..8], .big);
        var off: usize = 8;
        var i: u32 = 0;
        while (i < nfat) : (i += 1) {
            const cputype = std.mem.readInt(u32, bytes[off..][0..4], .big);
            const cpusubtype = std.mem.readInt(u32, bytes[off + 4 ..][0..4], .big);
            const slice_offset = std.mem.readInt(u32, bytes[off + 8 ..][0..4], .big);
            if (cputype == CPU_TYPE_ARM64 and (cpusubtype & 0xFF) == CPU_SUBTYPE_ARM64E) {
                return slice_offset;
            }
            off += 20;
        }
        return error.NoArm64eSlice;
    }
    const magic_le = std.mem.readInt(u32, bytes[0..4], .little);
    if (magic_le == MH_MAGIC_64) return 0;
    return error.BadMagic;
}

// ── Minimal FAT32 writer (multi-cluster capable) ────────────────────────

const SECTOR = 512;
const SECTORS_PER_CLUSTER = 8; // 4KB clusters
const CLUSTER_BYTES = SECTOR * SECTORS_PER_CLUSTER;
const RESERVED_SECTORS = 32;
const NUM_FATS = 2;

fn writeFatImage(io: std.Io, gpa: std.mem.Allocator, out_path: []const u8, blobs: []const Blob) !void {
    var total_clusters_needed: u64 = 1; // root dir
    for (blobs) |b| total_clusters_needed += (b.data.len + CLUSTER_BYTES - 1) / CLUSTER_BYTES;
    // Comfortable slack for FAT bookkeeping + headroom.
    const fat_size_sectors: u64 = @max(64, (total_clusters_needed * 4 + SECTOR - 1) / SECTOR + 8);
    const first_data_sector = RESERVED_SECTORS + NUM_FATS * fat_size_sectors;
    const total_sectors = first_data_sector + total_clusters_needed * SECTORS_PER_CLUSTER + 64;

    const img = try gpa.alloc(u8, total_sectors * SECTOR);
    defer gpa.free(img);
    @memset(img, 0);

    var bs: [SECTOR]u8 = [_]u8{0} ** SECTOR;
    bs[0..3].* = .{ 0xeb, 0x58, 0x90 };
    bs[3..11].* = "MSWIN4.1".*;
    std.mem.writeInt(u16, bs[11..13], SECTOR, .little);
    bs[13] = SECTORS_PER_CLUSTER;
    std.mem.writeInt(u16, bs[14..16], RESERVED_SECTORS, .little);
    bs[16] = NUM_FATS;
    bs[21] = 0xF8;
    std.mem.writeInt(u32, bs[32..36], @intCast(total_sectors), .little);
    std.mem.writeInt(u32, bs[36..40], @intCast(fat_size_sectors), .little);
    std.mem.writeInt(u32, bs[44..48], 2, .little); // root cluster
    std.mem.writeInt(u16, bs[48..50], 1, .little);
    std.mem.writeInt(u16, bs[50..52], 6, .little);
    bs[66] = 0x29;
    std.mem.writeInt(u32, bs[67..71], 0x12345678, .little);
    bs[71..82].* = "ROOTFS     ".*;
    bs[82..90].* = "FAT32   ".*;
    bs[510] = 0x55;
    bs[511] = 0xAA;
    @memcpy(img[0..SECTOR], &bs);

    const fat0 = img[RESERVED_SECTORS * SECTOR ..][0 .. fat_size_sectors * SECTOR];
    const fat1 = img[(RESERVED_SECTORS + fat_size_sectors) * SECTOR ..][0 .. fat_size_sectors * SECTOR];
    std.mem.writeInt(u32, fat0[0..4], 0x0FFFFFF8, .little);
    std.mem.writeInt(u32, fat0[4..8], 0x0FFFFFFF, .little);
    std.mem.writeInt(u32, fat0[8..12], 0x0FFFFFFF, .little); // cluster 2 = root dir, EOC

    var next_cluster: u32 = 3;
    const root_dir_off = first_data_sector * SECTOR;
    var dirent_idx: usize = 0;

    for (blobs) |b| {
        const cluster_count: u32 = @intCast((b.data.len + CLUSTER_BYTES - 1) / CLUSTER_BYTES);
        const start_cluster = next_cluster;
        var c: u32 = 0;
        while (c < cluster_count) : (c += 1) {
            const cluster = start_cluster + c;
            const is_last = c == cluster_count - 1;
            const val: u32 = if (is_last) 0x0FFFFFFF else cluster + 1;
            std.mem.writeInt(u32, fat0[cluster * 4 ..][0..4], val, .little);
            const cluster_file_off = first_data_sector * SECTOR + (@as(u64, cluster) - 2) * CLUSTER_BYTES;
            const chunk_len = @min(CLUSTER_BYTES, b.data.len - c * CLUSTER_BYTES);
            @memcpy(img[cluster_file_off..][0..chunk_len], b.data[c * CLUSTER_BYTES ..][0..chunk_len]);
        }
        next_cluster += cluster_count;

        var entry: [32]u8 = [_]u8{0x20} ** 32; // space-padded 8.3 name area
        const raw_name = rawFatName(b.name);
        @memcpy(entry[0..11], &raw_name);
        entry[11] = 0x20; // archive attribute
        std.mem.writeInt(u16, entry[20..22], @intCast((start_cluster >> 16) & 0xFFFF), .little);
        std.mem.writeInt(u16, entry[26..28], @intCast(start_cluster & 0xFFFF), .little);
        std.mem.writeInt(u32, entry[28..32], @intCast(b.data.len), .little);
        @memcpy(img[root_dir_off + dirent_idx * 32 ..][0..32], &entry);
        dirent_idx += 1;
    }
    @memcpy(fat1, fat0);

    var file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer file.close(io);
    var writer = file.writer(io, &.{});
    try writer.interface.writeAll(img);
    try writer.interface.flush();
}
