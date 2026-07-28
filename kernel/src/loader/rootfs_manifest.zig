//! On-disk format for the small manifest tools/prepare_shared_cache.zig
//! writes to the FAT rootfs alongside its extracted shared-cache blobs and
//! the target binary, and the kernel reads back at boot
//! (kmain.zig's spawnDynamicFromFat). A fixed-layout binary struct rather
//! than JSON: the freestanding kernel has no JSON parser, and this format
//! is shared by both sides by importing this same file (a plain host
//! executable and the freestanding kernel can both compile it - no
//! target-specific code here).

pub const MAGIC: [4]u8 = .{ 'S', 'C', 'M', '1' };
pub const MAX_DYLIBS = 4;
pub const MAX_SEGMENTS_PER_DYLIB = 8;

/// One mapped byte range at its real cache VA. `slide_len` is 0 if this
/// segment needs no slide-info rebase pass (e.g. __TEXT, or any segment
/// with no pointers - see loader/shared_cache.zig's doc comment on why
/// that's the common case for pure code). When non-zero, `slide_mapping_va`
/// is the *owning mapping's* base VA (not necessarily this segment's own
/// start - see applySlide's `region_va` parameter, since a segment is
/// usually a sub-range of a mapping shared by many dylibs).
pub const Segment = extern struct {
    va: u64 = 0,
    len: u32 = 0,
    blob: [12]u8 = std.mem.zeroes([12]u8),

    slide_len: u32 = 0,
    slide_mapping_va: u64 = 0,
    slide_blob: [12]u8 = std.mem.zeroes([12]u8),
};

pub const DylibBlob = extern struct {
    mach_header_va: u64 = 0,
    segment_count: u32 = 0,
    segments: [MAX_SEGMENTS_PER_DYLIB]Segment = [_]Segment{.{}} ** MAX_SEGMENTS_PER_DYLIB,

    trie_len: u32 = 0,
    trie_blob: [12]u8 = std.mem.zeroes([12]u8),
};

pub const Manifest = extern struct {
    magic: [4]u8 = MAGIC,
    shared_region_start: u64 = 0,
    dylib_count: u32 = 0,
    dylibs: [MAX_DYLIBS]DylibBlob = [_]DylibBlob{.{}} ** MAX_DYLIBS,

    main_blob: [12]u8 = std.mem.zeroes([12]u8),
    main_len: u32 = 0,
};

const std = @import("std");
