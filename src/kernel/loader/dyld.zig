//! Chained-fixups (LC_DYLD_CHAINED_FIXUPS) support for regular userland
//! Mach-O binaries - the counterpart to loader/macho.zig's classic
//! LC_DYLD_INFO_ONLY rebase-opcode path, needed for any binary built by a
//! modern toolchain (verified against a real `/bin/sh`'s arm64e slice: it
//! carries no LC_DYLD_INFO_ONLY at all, only chained fixups).
//!
//! This is a different pointer format from loader/shared_cache.zig's
//! `applySlide` even though both are "arm64e chained pointers": cache-
//! resident images use DYLD_CHAINED_PTR_ARM64E_SHARED_CACHE (rebase-only,
//! pre-resolved at cache-build time - see that module's doc comment), while
//! a regular on-disk binary like `/bin/sh` uses
//! DYLD_CHAINED_PTR_ARM64E_USERLAND24 (verified: pointer_format=12 in its
//! own `dyld_chained_starts_in_segment`), which mixes plain rebases *and*
//! binds-by-symbol-name in the same per-page chain, distinguished by a
//! `bind` bit absent from the shared-cache format entirely. See
//! apple-oss-distributions/dyld's include/mach-o/fixup-chains.h for the
//! four `dyld_chained_ptr_arm64e_*` bit layouts this mirrors.
//!
//! Binding a symbol here means searching one or more already-mapped
//! loader/shared_cache.zig images' export tries (see `Resolver`) - real
//! dyld's equivalent of walking a bind ordinal's re-export chain, except
//! the *set* of images to search per ordinal is precomputed on the host
//! (tools/prepare_shared_cache.zig) rather than re-derived at boot, the
//! same shortcut a real prebuilt closure takes.

const std = @import("std");

const LC_DYLD_CHAINED_FIXUPS: u32 = 0x34 | 0x80000000;

const ChainedFixupsHeader = extern struct {
    fixups_version: u32,
    starts_offset: u32,
    imports_offset: u32,
    symbols_offset: u32,
    imports_count: u32,
    imports_format: u32,
    symbols_format: u32,
};

const DYLD_CHAINED_IMPORT: u32 = 1;

/// One resolved import: which of this image's LC_LOAD_DYLIB ordinals it
/// came from, and its name (for the caller's `Resolver` to look up).
pub const Import = struct {
    ordinal: u8,
    name: []const u8,
};

/// A segment's chain-start info, as needed to walk it (mirrors
/// dyld_chained_starts_in_segment, minus fields this kernel doesn't need).
const SegStarts = struct {
    page_size: u16,
    pointer_format: u16,
    segment_offset: u64,
    page_starts: []align(1) const u16,
};

pub const PTR_ARM64E_USERLAND24: u16 = 12;
const CHAIN_START_NONE: u16 = 0xFFFF;

/// Resolves one bind by (ordinal, name) to an absolute address, or null if
/// unresolvable. The caller supplies this (see loader/dyld.zig's module doc
/// comment: search order per ordinal is precomputed host-side).
pub const Resolver = *const fn (ctx: ?*anyopaque, ordinal: u8, name: []const u8) ?u64;

/// Applies every fixup in `fixups_bytes` (the LC_DYLD_CHAINED_FIXUPS content)
/// to the already-copied segments at `base_pa` (same physically-contiguous,
/// vmaddr-relative-preserving layout loader/macho.zig's `load()` produces).
/// `slide` and `min_vmaddr` match `load()`'s own values exactly (rebase
/// entries need `base_pa + target`, i.e. `min_vmaddr + target + slide`).
pub fn applyChainedFixups(
    fixups_bytes: []const u8,
    base_pa: u64,
    resolver: Resolver,
    resolver_ctx: ?*anyopaque,
) !void {
    if (fixups_bytes.len < @sizeOf(ChainedFixupsHeader)) return error.Truncated;
    const hdr: *align(1) const ChainedFixupsHeader = @ptrCast(fixups_bytes.ptr);
    if (hdr.imports_format != DYLD_CHAINED_IMPORT) return error.UnsupportedImportFormat;

    const starts_bytes = fixups_bytes[hdr.starts_offset..];
    if (starts_bytes.len < 4) return error.Truncated;
    const seg_count = std.mem.readInt(u32, starts_bytes[0..4], .little);

    var seg_idx: u32 = 0;
    while (seg_idx < seg_count) : (seg_idx += 1) {
        const off_pos = 4 + seg_idx * 4;
        if (off_pos + 4 > starts_bytes.len) break;
        const seg_info_off = std.mem.readInt(u32, starts_bytes[off_pos..][0..4], .little);
        if (seg_info_off == 0) continue; // segment has no fixups

        const s = try readSegStarts(starts_bytes[seg_info_off..]);
        if (s.pointer_format != PTR_ARM64E_USERLAND24) return error.UnsupportedPointerFormat;

        for (s.page_starts, 0..) |start, page| {
            if (start == CHAIN_START_NONE) continue;
            var slot_pa = base_pa + s.segment_offset + @as(u64, page) * s.page_size + start;
            while (true) {
                const ptr: *u64 = @ptrFromInt(slot_pa);
                const raw = ptr.*;
                const auth: u1 = @truncate(raw >> 63);
                const bind: u1 = @truncate(raw >> 62);
                const next: u64 = (raw >> 51) & 0x7FF;

                if (bind == 1) {
                    const ordinal: u8 = @truncate(raw & 0xFF_FFFF); // low 24 bits
                    const addend_field: u64 = (raw >> 32) & 0x7FFFF; // 19 bits, non-auth only
                    const import = try readImport(fixups_bytes, hdr, ordinal);
                    const resolved = resolver(resolver_ctx, import.ordinal, import.name) orelse
                        return error.UnresolvedSymbol;
                    const addend: u64 = if (auth == 0) addend_field else 0;
                    ptr.* = resolved +% addend;
                } else {
                    // Rebase: low bits are `target`, a vmaddr-relative-to-
                    // this-image delta (43 bits plain, 32 bits if auth) -
                    // same meaning as macho.zig's classic rebase, just
                    // packed differently.
                    const target: u64 = if (auth == 0) raw & 0x7FFF_FFFF_FFF else raw & 0xFFFF_FFFF;
                    ptr.* = base_pa +% target;
                }

                if (next == 0) break;
                slot_pa += next * 8; // 8-byte stride (arm64e is always 8-byte aligned)
            }
        }
    }
}

fn readSegStarts(bytes: []const u8) !SegStarts {
    // dyld_chained_starts_in_segment: size(u32) page_size(u16)
    // pointer_format(u16) segment_offset(u64) max_valid_pointer(u32)
    // page_count(u16) page_start[page_count](u16).
    if (bytes.len < 22) return error.Truncated;
    const page_size = std.mem.readInt(u16, bytes[4..6], .little);
    const pointer_format = std.mem.readInt(u16, bytes[6..8], .little);
    const segment_offset = std.mem.readInt(u64, bytes[8..16], .little);
    const page_count = std.mem.readInt(u16, bytes[20..22], .little);
    const starts_bytes = bytes[22..];
    if (starts_bytes.len < @as(usize, page_count) * 2) return error.Truncated;
    const page_starts: []align(1) const u16 = @as([*]align(1) const u16, @ptrCast(starts_bytes.ptr))[0..page_count];
    return .{ .page_size = page_size, .pointer_format = pointer_format, .segment_offset = segment_offset, .page_starts = page_starts };
}

fn readImport(fixups_bytes: []const u8, hdr: *align(1) const ChainedFixupsHeader, index: u8) !Import {
    // dyld_chained_import: one packed u32 (lib_ordinal:8, weak_import:1, name_offset:23).
    const imports_bytes = fixups_bytes[hdr.imports_offset..];
    const off = @as(usize, index) * 4;
    if (off + 4 > imports_bytes.len) return error.Truncated;
    const entry = std.mem.readInt(u32, imports_bytes[off..][0..4], .little);
    const lib_ordinal: u8 = @truncate(entry & 0xFF);
    const name_offset = entry >> 9;

    const strings = fixups_bytes[hdr.symbols_offset..];
    if (name_offset >= strings.len) return error.Truncated;
    const name_bytes = strings[name_offset..];
    const end = std.mem.indexOfScalar(u8, name_bytes, 0) orelse name_bytes.len;
    return .{ .ordinal = lib_ordinal, .name = name_bytes[0..end] };
}

/// Returns the LC_DYLD_CHAINED_FIXUPS content slice from a mach-o image, or
/// null if it has none (i.e. it uses the older LC_DYLD_INFO_ONLY rebase-
/// opcode path instead - see loader/macho.zig).
pub fn findChainedFixups(image: []const u8, ncmds: u32, load_commands_off: usize) ?[]const u8 {
    var off = load_commands_off;
    var i: u32 = 0;
    while (i < ncmds) : (i += 1) {
        if (off + 8 > image.len) return null;
        const cmd = std.mem.readInt(u32, image[off..][0..4], .little);
        const cmdsize = std.mem.readInt(u32, image[off + 4 ..][0..4], .little);
        if (cmd == LC_DYLD_CHAINED_FIXUPS) {
            const dataoff = std.mem.readInt(u32, image[off + 8 ..][0..4], .little);
            const datasize = std.mem.readInt(u32, image[off + 12 ..][0..4], .little);
            if (dataoff + datasize > image.len) return null;
            return image[dataoff..][0..datasize];
        }
        off += cmdsize;
    }
    return null;
}
