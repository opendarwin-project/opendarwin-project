//! Parses the real macOS dyld shared cache format (struct layouts verified
//! against a live macOS 26 host's
//! /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e{,.NN}
//! - see apple-oss-distributions/dyld's include/mach-o/dyld_cache_format.h
//! and fixup-chains.h for the canonical struct definitions this mirrors).
//!
//! Unlike a standalone extracted dylib, images still resident *in* the cache
//! carry no per-image LC_DYLD_CHAINED_FIXUPS: the cache builder pre-resolves
//! every rebase and bind at cache-build time (both intra- and inter-image),
//! collapsing them all into plain direct pointers. The only fixup work left
//! at map time is applying the cache-wide ASLR slide, described once per
//! DATA/AUTH mapping by a `dyld_cache_slide_info5` page-chain (see
//! `applySlide`) - there is no bind/export-trie work needed for pointers
//! *inside* the cache, only for an external binary importing a symbol *from*
//! a cache image (that binary's own LC_DYLD_CHAINED_FIXUPS bind entries still
//! need resolving against a cache image's LC_DYLD_EXPORTS_TRIE - see
//! loader/dyld.zig).
//!
//! This kernel maps at most a handful of small byte ranges actually needed
//! by one target dylib (its own TEXT/DATA/AUTH segments plus the export-trie
//! slice of the shared LINKEDIT region) rather than the whole multi-gigabyte
//! cache - see tools/prepare_shared_cache.py, which computes exactly which
//! ranges those are from a real cache on the host and packages them (plus a
//! manifest recording each blob's real cache virtual address) into the FAT
//! rootfs. The kernel then maps each blob at its literal real address via
//! mm/mmu.zig's `mapPages(va, pa, ...)` - VA independent of where the
//! backing physical page actually lives - so pointers already resolved by
//! the cache builder (LC_DYLD_EXPORTS_TRIE offsets, slide-info targets,
//! cross-segment references within the dylib) keep working unmodified.

const std = @import("std");

/// dyld_cache_header, fields through subCacheArrayOffset/Count (everything
/// this kernel needs); later fields are read positionally, not via this
/// struct, since their exact tail layout doesn't matter here.
pub const CacheHeader = extern struct {
    magic: [16]u8,
    mapping_offset: u32,
    mapping_count: u32,
    images_offset_old: u32,
    images_count_old: u32,
    dyld_base_address: u64,
    code_signature_offset: u64,
    code_signature_size: u64,
    slide_info_offset_unused: u64,
    slide_info_size_unused: u64,
    local_symbols_offset: u64,
    local_symbols_size: u64,
    uuid: [16]u8,
    cache_type: u64,
    branch_pools_offset: u32,
    branch_pools_count: u32,
    dyld_in_cache_mh: u64,
    dyld_in_cache_entry: u64,
    images_text_offset: u64,
    images_text_count: u64,
    patch_info_addr: u64,
    patch_info_size: u64,
    other_image_group_addr_unused: u64,
    other_image_group_size_unused: u64,
    prog_closures_addr: u64,
    prog_closures_size: u64,
    prog_closures_trie_addr: u64,
    prog_closures_trie_size: u64,
    platform: u32,
    format_version_bits: u32,
    shared_region_start: u64,
    shared_region_size: u64,
    max_slide: u64,
    dylibs_image_array_addr: u64,
    dylibs_image_array_size: u64,
    dylibs_trie_addr: u64,
    dylibs_trie_size: u64,
    other_image_array_addr: u64,
    other_image_array_size: u64,
    other_trie_addr: u64,
    other_trie_size: u64,
    mapping_with_slide_offset: u32,
    mapping_with_slide_count: u32,
    dylibs_pbl_state_array_addr_unused: u64,
    dylibs_pbl_set_addr: u64,
    programs_pbl_set_pool_addr: u64,
    programs_pbl_set_pool_size: u64,
    program_trie_addr: u64,
    program_trie_size: u32,
    os_version: u32,
    alt_platform: u32,
    alt_os_version: u32,
    swift_opts_offset: u64,
    swift_opts_size: u64,
    sub_cache_array_offset: u32,
    sub_cache_array_count: u32,
    symbol_file_uuid: [16]u8,
    rosetta_read_only_addr: u64,
    rosetta_read_only_size: u64,
    rosetta_read_write_addr: u64,
    rosetta_read_write_size: u64,
    images_offset: u32,
    images_count: u32,
    // Fields past this point (cacheSubType onward) aren't needed here.
};

/// dyld_cache_mapping_and_slide_info.
pub const MappingAndSlideInfo = extern struct {
    address: u64,
    size: u64,
    file_offset: u64,
    slide_info_file_offset: u64,
    slide_info_file_size: u64,
    flags: u64,
    max_prot: u32,
    init_prot: u32,
};

/// dyld_cache_mapping_info (legacy, no slide info - some subcache files only
/// carry this simpler form since they have nothing to slide).
pub const MappingInfo = extern struct {
    address: u64,
    size: u64,
    file_offset: u64,
    max_prot: u32,
    init_prot: u32,
};

/// dyld_cache_image_info.
pub const ImageInfo = extern struct {
    address: u64,
    mod_time: u64,
    inode: u64,
    path_file_offset: u32,
    pad: u32,
};

/// dyld_subcache_entry.
pub const SubcacheEntry = extern struct {
    uuid: [16]u8,
    cache_vm_offset: u64,
    file_suffix: [32]u8,
};

/// dyld_cache_slide_info5 (arm64e caches only - the only version this
/// kernel implements, matching what a real host's dyld_shared_cache_arm64e
/// uses).
pub const SlideInfo5Header = extern struct {
    version: u32,
    page_size: u32,
    page_starts_count: u32,
    value_add: u64,
    // page_starts: [page_starts_count]u16 follows
};

pub const SLIDE_V5_PAGE_ATTR_NO_REBASE: u16 = 0xFFFF;

/// Read a `CacheHeader` from a cache file's first bytes (works for both the
/// main cache file and any subcache file, which each carry the same header
/// shape - only the fields that matter to that particular file are
/// populated by the cache builder).
pub fn readHeader(bytes: []const u8) ?*const CacheHeader {
    if (bytes.len < @sizeOf(CacheHeader)) return null;
    if (!std.mem.eql(u8, bytes[0..7], "dyld_v1")) return null;
    return @ptrCast(@alignCast(bytes.ptr));
}

/// One (address, size, fileOffset) mapping window, as read from either the
/// old or new-style mapping array - whichever a given cache file carries.
pub const Mapping = struct { address: u64, size: u64, file_offset: u64 };

/// Read a cache file's own mapping list (new mapping-with-slide-info form if
/// present, else the legacy form).
pub fn mappings(bytes: []const u8, header: *const CacheHeader, buf: []Mapping) []Mapping {
    var n: usize = 0;
    if (header.mapping_with_slide_count > 0) {
        var i: usize = 0;
        while (i < header.mapping_with_slide_count and n < buf.len) : (i += 1) {
            const off = header.mapping_with_slide_offset + i * @sizeOf(MappingAndSlideInfo);
            if (off + @sizeOf(MappingAndSlideInfo) > bytes.len) break;
            const m: *const MappingAndSlideInfo = @ptrCast(@alignCast(bytes.ptr + off));
            buf[n] = .{ .address = m.address, .size = m.size, .file_offset = m.file_offset };
            n += 1;
        }
    } else {
        var i: usize = 0;
        while (i < header.mapping_count and n < buf.len) : (i += 1) {
            const off = header.mapping_offset + i * @sizeOf(MappingInfo);
            if (off + @sizeOf(MappingInfo) > bytes.len) break;
            const m: *const MappingInfo = @ptrCast(@alignCast(bytes.ptr + off));
            buf[n] = .{ .address = m.address, .size = m.size, .file_offset = m.file_offset };
            n += 1;
        }
    }
    return buf[0..n];
}

/// Find the full mapping-with-slide-info entry covering `addr` in this cache
/// file, if this file uses the new-style mapping array at all (i.e. has
/// slide info available - the legacy `MappingInfo` form never does). Used
/// by tools/prepare_shared_cache.zig, which needs the slide-info file
/// offset/size, not just a plain file offset.
pub fn findMappingWithSlide(bytes: []const u8, header: *const CacheHeader, addr: u64) ?MappingAndSlideInfo {
    var i: usize = 0;
    while (i < header.mapping_with_slide_count) : (i += 1) {
        const off = header.mapping_with_slide_offset + i * @sizeOf(MappingAndSlideInfo);
        if (off + @sizeOf(MappingAndSlideInfo) > bytes.len) break;
        const m: *const MappingAndSlideInfo = @ptrCast(@alignCast(bytes.ptr + off));
        if (addr >= m.address and addr < m.address + m.size) return m.*;
    }
    return null;
}

/// Translate a real (unslid) cache virtual address to a file offset within
/// this same cache file's own byte content, or null if `bytes` doesn't cover
/// that address (i.e. it belongs to a different subcache file).
pub fn addressToFileOffset(bytes: []const u8, header: *const CacheHeader, addr: u64) ?u64 {
    var buf: [4]Mapping = undefined;
    for (mappings(bytes, header, &buf)) |m| {
        if (addr >= m.address and addr < m.address + m.size) {
            return m.file_offset + (addr - m.address);
        }
    }
    return null;
}

/// Find a dylib's mach_header address by install path, scanning the main
/// cache's image list (`header.images_offset`/`images_count`, each entry's
/// `path_file_offset` a plain file offset into these same main-cache bytes).
pub fn findImage(main_cache_bytes: []const u8, header: *const CacheHeader, want_path: []const u8) ?u64 {
    var i: usize = 0;
    while (i < header.images_count) : (i += 1) {
        const off = header.images_offset + i * @sizeOf(ImageInfo);
        if (off + @sizeOf(ImageInfo) > main_cache_bytes.len) break;
        const img: *const ImageInfo = @ptrCast(@alignCast(main_cache_bytes.ptr + off));
        if (img.path_file_offset >= main_cache_bytes.len) continue;
        const path_bytes = main_cache_bytes[img.path_file_offset..];
        const end = std.mem.indexOfScalar(u8, path_bytes, 0) orelse path_bytes.len;
        if (std.mem.eql(u8, path_bytes[0..end], want_path)) return img.address;
    }
    return null;
}

/// Translate a `dataoff`-style field from one of a cache image's own
/// linkedit-data load commands (LC_DYLD_EXPORTS_TRIE, LC_SYMTAB, etc.) to a
/// real cache virtual address, per dyld's own `MachOAnalyzer::
/// getLinkeditLayout`: "in VM layout all linkedit offsets are adjusted from
/// file offsets" - `dataoff` is relative to *this image's own* `__LINKEDIT`
/// LC_SEGMENT_64 command's `fileoff` field, NOT to any single cache file's
/// raw bytes (the cache's __LINKEDIT is one giant segment shared by every
/// image, usually living in its own dedicated "*.dyldlinkedit"-suffixed
/// subcache file). Concretely: `actualVmaddr = linkeditSeg.vmaddr +
/// (dataoff - linkeditSeg.fileoff)` - then resolve that address the same
/// way as any other vmaddr, via `addressToFileOffset` against whichever
/// cache file's mapping actually covers it.
///
/// (An earlier version of this function assumed `dataoff` was simply an
/// offset from the whole cache's `sharedRegionStart`; that produced
/// plausible-looking-but-wrong results for some fields - verified wrong by
/// cross-checking against LC_SYMTAB's `symoff`/`stroff` on a real cache,
/// which decoded as garbage nlist/string data under that theory. This
/// formula was verified correct by parsing a real, valid export trie under
/// it.)
pub fn linkeditDataoffToAddress(linkedit_seg_vmaddr: u64, linkedit_seg_fileoff: u64, dataoff: u64) u64 {
    return linkedit_seg_vmaddr + (dataoff -% linkedit_seg_fileoff);
}

/// Apply a cache-wide slide-info v5 rebase pass over one already-mapped
/// DATA/AUTH region. `region` is the mapped bytes at their real cache
/// virtual addresses (i.e. `region[0]` corresponds to cache address
/// `mapping.address`); `slide_info_bytes` is that mapping's own
/// `slideInfoFileOffset`/`slideInfoFileSize` slice from its cache file.
///
/// Each rebase slot (auth or plain) encodes `runtimeOffset`: an offset from
/// the whole cache's `sharedRegionStart`, not from this mapping - already
/// fully resolved by the cache builder (pointing anywhere in the cache, not
/// just within this dylib), matching real dyld's behavior of never doing
/// per-image binds for cache content (see this module's doc comment).
/// PAC `auth` bits (diversity/addrDiv/keyIsData) are read but not
/// re-signed - same simplification as loader/dyld.zig's chained-fixups path,
/// for the same reason (pointer-auth enforcement is left off for tasks
/// using cache content).
/// `region_va` is the real cache VA of `region[0]` - not necessarily the
/// full mapping's own base address, since callers may only have sparse-
/// copied a page-aligned slice of a mapping shared by many dylibs (the norm
/// for cache DATA/AUTH regions - see tools/prepare_shared_cache.zig, which
/// extracts whole slide-info pages, not just a segment's exact byte range,
/// specifically so this function's page/chain arithmetic - inherently
/// mapping-relative, since `dyld_cache_slide_info5.page_starts` indexes
/// pages of the *whole* mapping - stays valid over the slice). Pages (and
/// chain entries within them) outside `region`'s bounds are silently
/// skipped rather than walked, since this kernel has no reason to touch
/// pointers belonging to a dylib it isn't loading.
pub fn applySlide(region: []u8, region_va: u64, mapping_address: u64, shared_region_start: u64, slide_info_bytes: []const u8) void {
    if (slide_info_bytes.len < @sizeOf(SlideInfo5Header)) return;
    const hdr: *const SlideInfo5Header = @ptrCast(@alignCast(slide_info_bytes.ptr));
    if (hdr.version != 5) return; // only version this kernel implements

    const region_page_offset = (region_va - mapping_address) / hdr.page_size;
    const region_page_count = region.len / hdr.page_size;

    const page_starts_bytes = slide_info_bytes[@sizeOf(SlideInfo5Header)..];
    var local_page: usize = 0;
    while (local_page < region_page_count) : (local_page += 1) {
        const page = region_page_offset + local_page;
        const ps_off = page * 2;
        if (ps_off + 2 > page_starts_bytes.len) continue;
        const start = std.mem.readInt(u16, page_starts_bytes[ps_off..][0..2], .little);
        if (start == SLIDE_V5_PAGE_ATTR_NO_REBASE) continue;

        var slot_off: usize = local_page * hdr.page_size + @as(usize, start);
        while (slot_off + 8 <= region.len) {
            const raw = std.mem.readInt(u64, region[slot_off..][0..8], .little);
            // Bit layout (both the plain and auth variants agree on these
            // three fields; only the middle 18 bits - high8+unused vs.
            // diversity+addrDiv+keyIsData - differ, and this pass ignores
            // that middle span entirely):
            //   [0:33]  runtimeOffset (34 bits)
            //   [34:51] variant-specific (18 bits, unused here)
            //   [52:62] next          (11 bits, 8-byte stride)
            //   [63]    auth
            const auth_bit: u1 = @truncate(raw >> 63);
            const runtime_offset: u64 = raw & 0x3_FFFF_FFFF; // low 34 bits
            const next: u64 = (raw >> 52) & 0x7FF; // bits [62:52]

            const target = shared_region_start + runtime_offset;
            std.mem.writeInt(u64, region[slot_off..][0..8], target, .little);
            _ = auth_bit; // both variants resolve to the same target address

            if (next == 0) break;
            slot_off += @as(usize, next) * 8; // 8-byte stride
        }
    }
}

/// Walk a dyld export trie (LC_DYLD_EXPORTS_TRIE content - a compact ULEB128
/// prefix trie, see dyld's mach_o/ExportsTrie.cpp) looking for `symbol`.
/// Returns the symbol's offset from the image's mach_header, or null if not
/// exported. Only handles plain "regular symbol" export info (no re-exports
/// or stub-resolvers - see this module's doc comment on scope).
pub fn lookupExport(trie: []const u8, symbol: []const u8) ?u64 {
    var node_offset: usize = 0;
    var remaining = symbol;
    while (true) {
        if (node_offset >= trie.len) return null;
        var p = node_offset;
        const terminal_size = readUleb(trie, &p) orelse return null;
        const children_start = p + terminal_size;

        if (remaining.len == 0) {
            if (terminal_size == 0) return null;
            const flags = readUleb(trie, &p) orelse return null;
            _ = flags;
            return readUleb(trie, &p);
        }

        if (children_start >= trie.len) return null;
        var cp = children_start;
        const child_count = trie[cp];
        cp += 1;

        var matched = false;
        var i: u8 = 0;
        while (i < child_count) : (i += 1) {
            if (cp >= trie.len) return null;
            const label_start = cp;
            const label_end = std.mem.indexOfScalarPos(u8, trie, label_start, 0) orelse return null;
            const label = trie[label_start..label_end];
            cp = label_end + 1;
            const child_offset = readUleb(trie, &cp) orelse return null;

            if (std.mem.startsWith(u8, remaining, label)) {
                remaining = remaining[label.len..];
                node_offset = child_offset;
                matched = true;
                break;
            }
        }
        if (!matched) return null;
    }
}

fn readUleb(data: []const u8, pos: *usize) ?u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (pos.* >= data.len) return null;
        const b = data[pos.*];
        pos.* += 1;
        result |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) break;
        shift += 7;
    }
    return result;
}
