//! Mach-O loader supporting PIE (position-independent executables). Parses
//! mach_header_64 + LC_SEGMENT_64/LC_UNIXTHREAD/LC_MAIN/LC_DYLD_INFO_ONLY
//! from a static or PIE arm64 binary, maps all loadable segments into a
//! single physically-contiguous block (preserving their vmaddr-relative
//! layout), applies dyld rebase fixups if LC_DYLD_INFO_ONLY is present, and
//! returns the entry point.

const std = @import("std");
const mmu = @import("../mm/mmu.zig");

const MH_MAGIC_64: u32 = 0xfeedfacf;
const CPU_TYPE_ARM64: u32 = 0x0100000c;
const CPU_TYPE_ARM64_MASK: u32 = 0xff00_ffff;

const LC_SEGMENT_64: u32 = 0x19;
const LC_UNIXTHREAD: u32 = 0x5;
const LC_MAIN: u32 = 0x1e | 0x80000000;
const LC_DYLD_INFO_ONLY: u32 = 0x0b | 0x80000000;

const VM_PROT_READ: u32 = 1;
const VM_PROT_WRITE: u32 = 2;
const VM_PROT_EXECUTE: u32 = 4;

const MachHeader64 = extern struct {
    magic: u32,
    cputype: u32,
    cpusubtype: u32,
    filetype: u32,
    ncmds: u32,
    sizeofcmds: u32,
    flags: u32,
    reserved: u32,
};

const LoadCommand = extern struct {
    cmd: u32,
    cmdsize: u32,
};

const SegmentCommand64 = extern struct {
    cmd: u32,
    cmdsize: u32,
    segname: [16]u8,
    vmaddr: u64,
    vmsize: u64,
    fileoff: u64,
    filesize: u64,
    maxprot: u32,
    initprot: u32,
    nsects: u32,
    flags: u32,
};

const ARM_THREAD_STATE64: u32 = 6;
const ThreadCommand = extern struct {
    cmd: u32,
    cmdsize: u32,
    flavor: u32,
    count: u32,
};

// dyld rebase opcodes (mach-o/loader.h)
const REBASE_TYPE_POINTER = 1;

const REBASE_OPCODE_MASK: u8 = 0xF0;
const REBASE_IMM_MASK: u8 = 0x0F;
const REBASE_OPCODE_SET_TYPE_IMM: u8 = 0x10;
const REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB: u8 = 0x20;
const REBASE_OPCODE_ADD_ADDR_ULEB: u8 = 0x30;
const REBASE_OPCODE_DO_REBASE_ULEB_TIMES: u8 = 0x40;
const REBASE_OPCODE_DO_REBASE_IMM_TIMES: u8 = 0x50;
const REBASE_OPCODE_DO_REBASE_ADD_ADDR_ULEB: u8 = 0x60;
const REBASE_OPCODE_DO_REBASE_ULEB_TIMES_SKIPPING_ULEB: u8 = 0x70;
const REBASE_OPCODE_DONE: u8 = 0x00;

const MAX_SEGMENTS = 8;

pub const LoadError = error{
    BadMagic,
    WrongArch,
    NoEntryPoint,
    Truncated,
};

pub const LoadResult = struct {
    entry: u64,
};

/// Maps every LC_SEGMENT_64 in `image` into a single contiguous physical
/// block, preserving their vmaddr-relative layout, then applies any rebase
/// fixups from LC_DYLD_INFO_ONLY. Returns the entry point (physical address).
pub fn load(image: []const u8, regions_out: []mmu.Region, regions_used: *usize) LoadError!LoadResult {
    if (image.len < @sizeOf(MachHeader64)) return LoadError.Truncated;
    const header: *const MachHeader64 = @ptrCast(@alignCast(image.ptr));
    if (header.magic != MH_MAGIC_64) return LoadError.BadMagic;
    if ((header.cputype & CPU_TYPE_ARM64_MASK) != CPU_TYPE_ARM64) return LoadError.WrongArch;

    var entry_vmaddr: ?u64 = null;
    var entry_fileoff: ?u64 = null;
    var dyldinfo: ?DyldInfo = null;

    var seg_headers: [MAX_SEGMENTS]SegInfo = undefined;
    var seg_count: usize = 0;

    var off: usize = @sizeOf(MachHeader64);
    var i: u32 = 0;
    while (i < header.ncmds) : (i += 1) {
        if (off + @sizeOf(LoadCommand) > image.len) return LoadError.Truncated;
        const lc: *const LoadCommand = @ptrCast(@alignCast(image.ptr + off));
        if (off + lc.cmdsize > image.len) return LoadError.Truncated;

        switch (lc.cmd) {
            LC_SEGMENT_64 => {
                const seg: *const SegmentCommand64 = @ptrCast(@alignCast(image.ptr + off));
                // Keep every segment (including zero-size like __PAGEZERO) so
                // that seg_headers indices match the file-level segment order
                // used by dyld rebase opcodes.
                if (seg_count >= MAX_SEGMENTS) return LoadError.Truncated;
                seg_headers[seg_count] = .{
                    .vmaddr = seg.vmaddr,
                    .vmsize = seg.vmsize,
                    .fileoff = seg.fileoff,
                    .filesize = seg.filesize,
                    .initprot = seg.initprot,
                    .maxprot = seg.maxprot,
                };
                seg_count += 1;
            },
            LC_UNIXTHREAD => {
                const tc: *const ThreadCommand = @ptrCast(@alignCast(image.ptr + off));
                if (tc.flavor == ARM_THREAD_STATE64) {
                    const regs_base = image.ptr + off + @sizeOf(ThreadCommand);
                    const pc_ptr: *align(1) const u64 = @ptrCast(regs_base + 32 * 8);
                    entry_vmaddr = pc_ptr.*;
                }
            },
            LC_MAIN => {
                entry_fileoff = readU64(image[off + 8 ..]);
            },
            LC_DYLD_INFO_ONLY => {
                dyldinfo = .{
                    .rebase_off = readU32(image[off + 8 ..]),
                    .rebase_size = readU32(image[off + 12 ..]),
                };
            },
            else => {},
        }
        off += lc.cmdsize;
    }

    // Count loadable segments (vmsize>0, maxprot!=0 skips __PAGEZERO).
    var loadable_count: usize = 0;
    const min_vmaddr = blk: {
        var m: u64 = std.math.maxInt(u64);
        for (seg_headers[0..seg_count]) |s| {
            if (s.vmsize == 0 or s.maxprot == 0) continue;
            loadable_count += 1;
            if (s.vmaddr < m) m = s.vmaddr;
        }
        break :blk m;
    };

    regions_used.* = loadable_count;
    if (loadable_count == 0) return LoadError.NoEntryPoint;

    // Convert LC_MAIN file offset to vmaddr
    if (entry_vmaddr == null) {
        const foff = entry_fileoff orelse return LoadError.NoEntryPoint;
        entry_vmaddr = null;
        for (seg_headers[0..seg_count]) |s| {
            if (foff >= s.fileoff and foff < s.fileoff + s.filesize) {
                entry_vmaddr = s.vmaddr + (foff - s.fileoff);
                break;
            }
        }
        if (entry_vmaddr == null) return LoadError.NoEntryPoint;
    }

    const raw_entry = entry_vmaddr.?;

    // Find the end of the vmaddr range from loadable segments.
    const max_end = blk: {
        var m: u64 = 0;
        for (seg_headers[0..seg_count]) |s| {
            if (s.vmsize == 0 or s.maxprot == 0) continue;
            const end = s.vmaddr + s.vmsize;
            if (end > m) m = end;
        }
        break :blk m;
    };

    // Allocate a single contiguous block of pages covering the entire
    // vmaddr range of loadable segments, preserving their vmaddr-relative
    // offsets.  This is required by the rebase engine: the slide
    // (base_pa - min_vmaddr) is a single value applied to every pointer,
    // and each pointer is at (base_pa + seg.vmaddr - min_vmaddr + off).
    const total_pages = (max_end - min_vmaddr + mmu.PAGE_SIZE - 1) / mmu.PAGE_SIZE;
    const base_pa = mmu.allocPage();
    var pi: u64 = 1;
    while (pi < total_pages) : (pi += 1) _ = mmu.allocPage();

    // Copy each loadable segment at its vmaddr-relative offset.
    var region_idx: usize = 0;
    for (seg_headers[0..seg_count]) |s| {
        if (s.vmsize == 0 or s.maxprot == 0) continue;

        const seg_pa = base_pa + (s.vmaddr - min_vmaddr);

        const copy_len = @min(s.filesize, s.vmsize);
        if (copy_len > 0 and s.fileoff + copy_len <= image.len) {
            const dst: [*]u8 = @ptrFromInt(seg_pa);
            @memcpy(dst[0..copy_len], image[s.fileoff..][0..copy_len]);
        }

        regions_out[region_idx] = .{
            .pa = seg_pa,
            .len = pageAlign(s.vmsize),
            .prot = segProt(s.initprot),
        };
        region_idx += 1;
    }

    // Apply rebase fixups if present.  slide = base_pa - min_vmaddr because
    // the binary's absolute pointers were written for the preferred vmaddr
    // space but we load at a physical address.
    if (dyldinfo) |info| {
        if (info.rebase_size > 0) {
            const slide = base_pa -% min_vmaddr;
            applyRebase(image[info.rebase_off..][0..info.rebase_size], seg_headers[0..seg_count], base_pa, slide, min_vmaddr);
        }
    }

    return .{ .entry = base_pa + (raw_entry - min_vmaddr) };
}

// ── Helpers ────────────────────────────────────────────────────────

const SegInfo = struct {
    vmaddr: u64,
    vmsize: u64,
    fileoff: u64,
    filesize: u64,
    initprot: u32,
    maxprot: u32,
};

const DyldInfo = struct {
    rebase_off: u32,
    rebase_size: u32,
};

fn readU32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24);
}

fn readU64(bytes: []const u8) u64 {
    return @as(u64, bytes[0]) | (@as(u64, bytes[1]) << 8) | (@as(u64, bytes[2]) << 16) | (@as(u64, bytes[3]) << 24) |
        (@as(u64, bytes[4]) << 32) | (@as(u64, bytes[5]) << 40) | (@as(u64, bytes[6]) << 48) | (@as(u64, bytes[7]) << 56);
}

fn segProt(initprot: u32) mmu.Prot {
    return .{
        .writable = (initprot & VM_PROT_WRITE) != 0,
        .executable = (initprot & VM_PROT_EXECUTE) != 0,
        .user = true,
    };
}

fn pageAlign(n: u64) u64 {
    return (n + mmu.PAGE_SIZE - 1) & ~@as(u64, mmu.PAGE_SIZE - 1);
}

/// Reads a ULEB128 value from `data` starting at `idx`, advancing `idx`
/// past the consumed bytes.
fn readUleb(data: []const u8, idx: *usize) u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        const byte = data[idx.*];
        idx.* += 1;
        result |= (@as(u64, byte & 0x7F)) << shift;
        if ((byte & 0x80) == 0) return result;
        shift += 7;
    }
}

/// Walks the dyld rebase opcode stream and applies fixups: for each
/// REBASE_TYPE_POINTER entry, reads a 64-bit value at (seg_base + offset),
/// adds `slide`, and writes it back.
fn applyRebase(opcodes: []const u8, segs: []const SegInfo, base_pa: u64, slide: u64, min_vmaddr: u64) void {
    var seg_idx: usize = 0;
    var offset: u64 = 0;
    var rebase_type: u8 = 0;
    var idx: usize = 0;

    while (idx < opcodes.len) {
        const op = opcodes[idx];
        idx += 1;
        switch (op & REBASE_OPCODE_MASK) {
            REBASE_OPCODE_SET_TYPE_IMM => {
                rebase_type = op & REBASE_IMM_MASK;
            },
            REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB => {
                seg_idx = op & REBASE_IMM_MASK;
                offset = readUleb(opcodes, &idx);
            },
            REBASE_OPCODE_ADD_ADDR_ULEB => {
                offset += readUleb(opcodes, &idx);
            },
            REBASE_OPCODE_DO_REBASE_ULEB_TIMES => {
                const count = readUleb(opcodes, &idx);
                rebaseAt(segs, base_pa, slide, min_vmaddr, seg_idx, &offset, count);
            },
            REBASE_OPCODE_DO_REBASE_IMM_TIMES => {
                const count = op & REBASE_IMM_MASK;
                rebaseAt(segs, base_pa, slide, min_vmaddr, seg_idx, &offset, count);
            },
            REBASE_OPCODE_DO_REBASE_ADD_ADDR_ULEB => {
                rebaseOne(segs, base_pa, slide, min_vmaddr, seg_idx, offset, rebase_type);
                offset += readUleb(opcodes, &idx);
            },
            REBASE_OPCODE_DO_REBASE_ULEB_TIMES_SKIPPING_ULEB => {
                const count = readUleb(opcodes, &idx);
                const skip = readUleb(opcodes, &idx);
                var j: u64 = 0;
                while (j < count) : (j += 1) {
                    rebaseOne(segs, base_pa, slide, min_vmaddr, seg_idx, offset, rebase_type);
                    offset += skip;
                }
            },
            REBASE_OPCODE_DONE => return,
            else => return,
        }
    }
}

fn rebaseOne(segs: []const SegInfo, base_pa: u64, slide: u64, min_vmaddr: u64, seg_idx: usize, off: u64, rebase_type: u8) void {
    _ = rebase_type;
    const seg = segs[seg_idx];
    const pa = base_pa + (seg.vmaddr - min_vmaddr) + off;
    const ptr: *u64 = @ptrFromInt(pa);
    ptr.* +%= slide;
}

fn rebaseAt(segs: []const SegInfo, base_pa: u64, slide: u64, min_vmaddr: u64, seg_idx: usize, off: *u64, count: u64) void {
    var j: u64 = 0;
    while (j < count) : (j += 1) {
        const seg = segs[seg_idx];
        const pa = base_pa + (seg.vmaddr - min_vmaddr) + off.*;
        const ptr: *u64 = @ptrFromInt(pa);
        ptr.* +%= slide;
        off.* += 8;
    }
}
