//! Mach-O loaders for regular arm64 executable/dylib images and relocatable kernel objects.
//!
//! MH_EXECUTE/MH_DYLIB images map LC_SEGMENT_64 commands preserving vmaddr-relative layout.
//! MH_OBJECT images use the KEXT path: allocate kernel-only section storage, resolve nlist_64
//! locals/externals, apply arm64 section relocations, and report constructor pointers.

const std = @import("std");
const mmu = @import("../mm/mmu.zig");
const pmm = @import("../mm/pmm.zig");
const dyld = @import("dyld.zig");

const MH_MAGIC_64: u32 = 0xfeedfacf;
const CPU_TYPE_ARM64: u32 = 0x0100000c;
const CPU_TYPE_ARM64_MASK: u32 = 0xff00_ffff;

const MH_OBJECT: u32 = 0x1;
const MH_EXECUTE: u32 = 0x2;
const MH_DYLIB: u32 = 0x6;

const LC_SEGMENT_64: u32 = 0x19;
const LC_UNIXTHREAD: u32 = 0x5;
const LC_MAIN: u32 = 0x28 | 0x80000000;
// 0x0b is the legacy LC_DYLD_INFO; the modern *_ONLY command is 0x22.
const LC_DYLD_INFO_ONLY: u32 = 0x22 | 0x80000000;
const LC_DYLD_CHAINED_FIXUPS: u32 = 0x34 | 0x80000000;
const LC_SYMTAB: u32 = 0x2;
const LC_DYSYMTAB: u32 = 0xb;

const VM_PROT_WRITE: u32 = 2;
const VM_PROT_EXECUTE: u32 = 4;

const N_TYPE: u8 = 0x0e;
const N_UNDF: u8 = 0x0;
const N_SECT: u8 = 0xe;
const N_EXT: u8 = 0x01;

const R_ABS: u8 = 0;
const ARM64_RELOC_UNSIGNED: u8 = 0;
const ARM64_RELOC_POINTER_TO_GOT: u8 = 2;
const ARM64_RELOC_BRANCH26: u8 = 2;
const ARM64_RELOC_PAGE21: u8 = 3;
const ARM64_RELOC_PAGEOFF12: u8 = 4;
const ARM64_RELOC_SUBTRACTOR: u8 = 5;
const ARM64_RELOC_ADDEND: u8 = 10;

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

const LoadCommand = extern struct { cmd: u32, cmdsize: u32 };

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

const Section64 = extern struct {
    sectname: [16]u8,
    segname: [16]u8,
    addr: u64,
    size: u64,
    offset: u32,
    align_: u32,
    reloff: u32,
    nreloc: u32,
    flags: u32,
    reserved1: u32,
    reserved2: u32,
    reserved3: u32,
};

const SymtabCommand = extern struct {
    cmd: u32,
    cmdsize: u32,
    symoff: u32,
    nsyms: u32,
    stroff: u32,
    strsize: u32,
};

const DysymtabCommand = extern struct {
    cmd: u32,
    cmdsize: u32,
    ilocalsym: u32,
    nlocalsym: u32,
    iextdefsym: u32,
    nextdefsym: u32,
    iundefsym: u32,
    nundefsym: u32,
    tocoff: u32,
    ntoc: u32,
    modtaboff: u32,
    nmodtab: u32,
    extrefsymoff: u32,
    nextrefsyms: u32,
    indirectsymoff: u32,
    nindirectsyms: u32,
    extreloff: u32,
    nextrel: u32,
    locreloff: u32,
    nlocrel: u32,
};

const Nlist64 = extern struct {
    n_strx: u32,
    n_type: u8,
    n_sect: u8,
    n_desc: u16,
    n_value: u64,
};

const RelocationInfo = extern struct { r_address: i32, r_word: u32 };

const ARM_THREAD_STATE64: u32 = 6;
const ThreadCommand = extern struct { cmd: u32, cmdsize: u32, flavor: u32, count: u32 };

// Values must match mach-o/loader.h. A previous revision swapped several of
// these (treating 0x40 as DO_REBASE_ULEB_TIMES, etc.), which desynchronized
// the walker and corrupted DATA pointers such as `c_allocator.vtable`.
const REBASE_OPCODE_MASK: u8 = 0xF0;
const REBASE_IMM_MASK: u8 = 0x0F;
const REBASE_OPCODE_DONE: u8 = 0x00;
const REBASE_OPCODE_SET_TYPE_IMM: u8 = 0x10;
const REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB: u8 = 0x20;
const REBASE_OPCODE_ADD_ADDR_ULEB: u8 = 0x30;
const REBASE_OPCODE_ADD_ADDR_IMM_SCALED: u8 = 0x40;
const REBASE_OPCODE_DO_REBASE_IMM_TIMES: u8 = 0x50;
const REBASE_OPCODE_DO_REBASE_ULEB_TIMES: u8 = 0x60;
const REBASE_OPCODE_DO_REBASE_ADD_ADDR_ULEB: u8 = 0x70;
const REBASE_OPCODE_DO_REBASE_ULEB_TIMES_SKIPPING_ULEB: u8 = 0x80;

const BIND_OPCODE_MASK: u8 = 0xF0;
const BIND_IMM_MASK: u8 = 0x0F;
const BIND_OPCODE_DONE: u8 = 0x00;
const BIND_OPCODE_SET_DYLIB_ORDINAL_IMM: u8 = 0x10;
const BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB: u8 = 0x20;
const BIND_OPCODE_SET_DYLIB_SPECIAL_IMM: u8 = 0x30;
const BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM: u8 = 0x40;
const BIND_OPCODE_SET_TYPE_IMM: u8 = 0x50;
const BIND_OPCODE_SET_ADDEND_SLEB: u8 = 0x60;
const BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB: u8 = 0x70;
const BIND_OPCODE_ADD_ADDR_ULEB: u8 = 0x80;
const BIND_OPCODE_DO_BIND: u8 = 0x90;
const BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB: u8 = 0xA0;
const BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED: u8 = 0xB0;
const BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB: u8 = 0xC0;

const MAX_SEGMENTS = 8;
const MAX_SECTIONS = 32;
const MAX_LOCAL_RELOCS = 64;
const MAX_EXT_RELOCS = 64;

pub const LoadError = error{
    BadMagic,
    WrongArch,
    UnsupportedFileType,
    NoEntryPoint,
    Truncated,
    TooManySegments,
    TooManySections,
    TooManyRelocations,
    OutOfRegions,
    UnsupportedImportFormat,
    UnsupportedPointerFormat,
    UnsupportedRelocation,
    UnresolvedSymbol,
};

// Valid until the next load; the name is backed by the loaded Mach-O image.
var last_unresolved_symbol: []const u8 = "";
pub fn lastUnresolvedSymbol() []const u8 {
    return last_unresolved_symbol;
}

pub const LoadOptions = struct {
    resolver: ?dyld.Resolver = null,
    resolver_ctx: ?*anyopaque = null,
    user_accessible: bool = true,
};

pub const SymbolKind = enum { undefined, local, external };
pub const Symbol = struct { name: []const u8, value: u64, sect: u8, kind: SymbolKind };
pub const Section = struct { sectname: [16]u8, segname: [16]u8, addr: u64, size: u64, flags: u32 };
pub const Relocation = struct { address: u64, symbolnum: u32, pcrel: bool, length: u2, extern_: bool, type_: u4 };
pub const KernelResolver = *const fn (ctx: ?*anyopaque, name: []const u8) ?u64;
pub const KernelObjectOptions = struct { resolver: KernelResolver, resolver_ctx: ?*anyopaque = null };
pub const KernelObjectResult = struct { base: u64, len: u64, sections: []const Section, local_symbols: []const Symbol, external_symbols: []const Symbol, undefined_symbols: []const Symbol, constructors: []const u64 };

var section_storage: [MAX_SECTIONS]Section = undefined;
var local_symbol_storage: [64]Symbol = undefined;
var external_symbol_storage: [256]Symbol = undefined;
var undefined_symbol_storage: [64]Symbol = undefined;
var local_reloc_storage: [MAX_LOCAL_RELOCS]Relocation = undefined;
var external_reloc_storage: [MAX_EXT_RELOCS]Relocation = undefined;
var constructor_storage: [32]u64 = undefined;

pub const LoadResult = struct {
    entry: u64,
    mach_header: u64,
    slide: u64,
    sections: []const Section,
    local_symbols: []const Symbol,
    external_symbols: []const Symbol,
    undefined_symbols: []const Symbol,
    local_relocs: []const Relocation,
    external_relocs: []const Relocation,
};

pub fn loadKernelObject(image: []const u8, options: KernelObjectOptions) LoadError!KernelObjectResult {
    if (image.len < @sizeOf(MachHeader64)) return LoadError.Truncated;
    const header: *const MachHeader64 = @ptrCast(@alignCast(image.ptr));
    if (header.magic != MH_MAGIC_64) return LoadError.BadMagic;
    if ((header.cputype & CPU_TYPE_ARM64_MASK) != CPU_TYPE_ARM64) return LoadError.WrongArch;
    if (header.filetype != MH_OBJECT) return LoadError.UnsupportedFileType;
    if (@sizeOf(MachHeader64) + header.sizeofcmds > image.len) return LoadError.Truncated;

    var object_sections: [MAX_SECTIONS]ObjectSection = undefined;
    var section_count: usize = 0;
    var symtab: ?Symtab = null;

    var off: usize = @sizeOf(MachHeader64);
    var cmd_i: u32 = 0;
    while (cmd_i < header.ncmds) : (cmd_i += 1) {
        if (off + @sizeOf(LoadCommand) > image.len) return LoadError.Truncated;
        const lc: *const LoadCommand = @ptrCast(@alignCast(image.ptr + off));
        if (lc.cmdsize < @sizeOf(LoadCommand) or off + lc.cmdsize > image.len) return LoadError.Truncated;
        switch (lc.cmd) {
            LC_SEGMENT_64 => {
                if (lc.cmdsize < @sizeOf(SegmentCommand64)) return LoadError.Truncated;
                const seg: *const SegmentCommand64 = @ptrCast(@alignCast(image.ptr + off));
                const sections_off = off + @sizeOf(SegmentCommand64);
                if (sections_off + @as(usize, seg.nsects) * @sizeOf(Section64) > off + lc.cmdsize) return LoadError.Truncated;
                var si: u32 = 0;
                while (si < seg.nsects) : (si += 1) {
                    if (section_count >= MAX_SECTIONS) return LoadError.TooManySections;
                    const sec: *const Section64 = @ptrCast(@alignCast(image.ptr + sections_off + @as(usize, si) * @sizeOf(Section64)));
                    object_sections[section_count] = .{ .input = sec.*, .loaded = 0 };
                    section_storage[section_count] = .{ .sectname = sec.sectname, .segname = sec.segname, .addr = 0, .size = sec.size, .flags = sec.flags };
                    section_count += 1;
                }
            },
            LC_SYMTAB => {
                if (lc.cmdsize < @sizeOf(SymtabCommand)) return LoadError.Truncated;
                const sc: *const SymtabCommand = @ptrCast(@alignCast(image.ptr + off));
                symtab = .{ .symoff = sc.symoff, .nsyms = sc.nsyms, .stroff = sc.stroff, .strsize = sc.strsize };
            },
            else => {},
        }
        off += lc.cmdsize;
    }

    const st = symtab orelse return LoadError.UnresolvedSymbol;
    var total_len: u64 = 0;
    for (object_sections[0..section_count]) |*sec| {
        total_len = pageAlign(total_len);
        sec.loaded = total_len;
        total_len += pageAlign(sec.input.size);
    }
    total_len = pageAlign(total_len);
    const base = pmm.allocPagesContig(total_len / mmu.PAGE_SIZE);
    if (base == 0) @panic("macho: allocPagesContig failed (too fragmented)");

    for (object_sections[0..section_count], 0..) |sec, idx| {
        section_storage[idx].addr = base + sec.loaded;
        if (sec.input.size == 0) continue;
        if (@as(u64, sec.input.offset) + sec.input.size > image.len) return LoadError.Truncated;
        const dst: [*]u8 = @ptrFromInt(base + sec.loaded);
        @memcpy(dst[0..sec.input.size], image[sec.input.offset..][0..sec.input.size]);
    }

    var all_symbols: [128]Symbol = undefined;
    try loadObjectSymbols(image, st, base, object_sections[0..section_count], &all_symbols);

    for (object_sections[0..section_count], 0..) |sec, idx| {
        if (sec.input.nreloc == 0) continue;
        try applyObjectRelocations(image, sec.input.reloff, sec.input.nreloc, base + sec.loaded, base, object_sections[0..section_count], &all_symbols, st.nsyms, options);
        section_storage[idx].addr = base + sec.loaded;
    }

    for (object_sections[0..section_count]) |sec| {
        if (sec.input.size == 0) continue;
        const prot = objectSectionProt(&sec.input);
        mmu.mapExtra(base + sec.loaded, pageAlign(sec.input.size), prot);
        mmu.inheritExtraInTaskTables(base + sec.loaded, pageAlign(sec.input.size), prot);
    }

    var local_count: usize = 0;
    var external_count: usize = 0;
    var undef_count: usize = 0;
    for (all_symbols[0..st.nsyms]) |sym| switch (sym.kind) {
        .local => {
            if (local_count < local_symbol_storage.len) {
                local_symbol_storage[local_count] = sym;
                local_count += 1;
            }
        },
        .external => {
            if (external_count < external_symbol_storage.len) {
                external_symbol_storage[external_count] = sym;
                external_count += 1;
            }
        },
        .undefined => {
            if (undef_count < undefined_symbol_storage.len) {
                undefined_symbol_storage[undef_count] = sym;
                undef_count += 1;
            }
        },
    };

    var ctor_count: usize = 0;
    for (object_sections[0..section_count]) |sec| {
        if (!fixedNameEql(&sec.input.sectname, "__mod_init_func")) continue;
        var pos: u64 = 0;
        while (pos + 8 <= sec.input.size and ctor_count < constructor_storage.len) : (pos += 8) {
            const ptr: *const u64 = @ptrFromInt(base + sec.loaded + pos);
            constructor_storage[ctor_count] = ptr.*;
            ctor_count += 1;
        }
    }

    return .{ .base = base, .len = total_len, .sections = section_storage[0..section_count], .local_symbols = local_symbol_storage[0..local_count], .external_symbols = external_symbol_storage[0..external_count], .undefined_symbols = undefined_symbol_storage[0..undef_count], .constructors = constructor_storage[0..ctor_count] };
}

pub fn load(image: []const u8, regions_out: []mmu.Region, regions_used: *usize, resolver: ?dyld.Resolver, resolver_ctx: ?*anyopaque) LoadError!LoadResult {
    return loadWithOptions(image, regions_out, regions_used, .{ .resolver = resolver, .resolver_ctx = resolver_ctx, .user_accessible = true });
}

pub fn loadWithOptions(image: []const u8, regions_out: []mmu.Region, regions_used: *usize, options: LoadOptions) LoadError!LoadResult {
    last_unresolved_symbol = "";
    if (image.len < @sizeOf(MachHeader64)) return LoadError.Truncated;
    const header: *const MachHeader64 = @ptrCast(@alignCast(image.ptr));
    if (header.magic != MH_MAGIC_64) return LoadError.BadMagic;
    if ((header.cputype & CPU_TYPE_ARM64_MASK) != CPU_TYPE_ARM64) return LoadError.WrongArch;
    if (header.filetype != MH_EXECUTE and header.filetype != MH_DYLIB) return LoadError.UnsupportedFileType;
    if (@sizeOf(MachHeader64) + header.sizeofcmds > image.len) return LoadError.Truncated;

    var entry_vmaddr: ?u64 = null;
    var entry_fileoff: ?u64 = null;
    var dyldinfo: ?DyldInfo = null;
    var chained_fixups: ?[]const u8 = null;
    var symtab: ?Symtab = null;
    var dysymtab: ?Dysymtab = null;

    var seg_headers: [MAX_SEGMENTS]SegInfo = undefined;
    var seg_count: usize = 0;
    var section_count: usize = 0;

    var off: usize = @sizeOf(MachHeader64);
    var i: u32 = 0;
    while (i < header.ncmds) : (i += 1) {
        if (off + @sizeOf(LoadCommand) > image.len) return LoadError.Truncated;
        const lc: *const LoadCommand = @ptrCast(@alignCast(image.ptr + off));
        if (lc.cmdsize < @sizeOf(LoadCommand) or off + lc.cmdsize > image.len) return LoadError.Truncated;

        switch (lc.cmd) {
            LC_SEGMENT_64 => {
                if (lc.cmdsize < @sizeOf(SegmentCommand64)) return LoadError.Truncated;
                const seg: *const SegmentCommand64 = @ptrCast(@alignCast(image.ptr + off));
                if (seg_count >= MAX_SEGMENTS) return LoadError.TooManySegments;
                seg_headers[seg_count] = .{ .vmaddr = seg.vmaddr, .vmsize = seg.vmsize, .fileoff = seg.fileoff, .filesize = seg.filesize, .initprot = seg.initprot, .maxprot = seg.maxprot };
                seg_count += 1;

                const sections_off = off + @sizeOf(SegmentCommand64);
                if (sections_off + @as(usize, seg.nsects) * @sizeOf(Section64) > off + lc.cmdsize) return LoadError.Truncated;
                var si: u32 = 0;
                while (si < seg.nsects) : (si += 1) {
                    if (section_count >= MAX_SECTIONS) return LoadError.TooManySections;
                    const sec: *const Section64 = @ptrCast(@alignCast(image.ptr + sections_off + @as(usize, si) * @sizeOf(Section64)));
                    section_storage[section_count] = .{ .sectname = sec.sectname, .segname = sec.segname, .addr = sec.addr, .size = sec.size, .flags = sec.flags };
                    section_count += 1;
                }
            },
            LC_UNIXTHREAD => {
                if (lc.cmdsize < @sizeOf(ThreadCommand) + 33 * 8) return LoadError.Truncated;
                const tc: *const ThreadCommand = @ptrCast(@alignCast(image.ptr + off));
                if (tc.flavor == ARM_THREAD_STATE64) {
                    const regs_base = image.ptr + off + @sizeOf(ThreadCommand);
                    const pc_ptr: *align(1) const u64 = @ptrCast(regs_base + 32 * 8);
                    entry_vmaddr = pc_ptr.*;
                }
            },
            LC_MAIN => {
                if (lc.cmdsize < 24) return LoadError.Truncated;
                entry_fileoff = readU64(image[off + 8 ..]);
            },
            LC_DYLD_INFO_ONLY => {
                if (lc.cmdsize < 48) return LoadError.Truncated;
                dyldinfo = .{
                    .rebase_off = readU32(image[off + 8 ..]),
                    .rebase_size = readU32(image[off + 12 ..]),
                    .bind_off = readU32(image[off + 16 ..]),
                    .bind_size = readU32(image[off + 20 ..]),
                    .lazy_bind_off = readU32(image[off + 32 ..]),
                    .lazy_bind_size = readU32(image[off + 36 ..]),
                };
            },
            LC_DYLD_CHAINED_FIXUPS => {
                if (lc.cmdsize < 16) return LoadError.Truncated;
                const dataoff = readU32(image[off + 8 ..]);
                const datasize = readU32(image[off + 12 ..]);
                if (@as(u64, dataoff) + datasize > image.len) return LoadError.Truncated;
                chained_fixups = image[dataoff..][0..datasize];
            },
            LC_SYMTAB => {
                if (lc.cmdsize < @sizeOf(SymtabCommand)) return LoadError.Truncated;
                const sc: *const SymtabCommand = @ptrCast(@alignCast(image.ptr + off));
                symtab = .{ .symoff = sc.symoff, .nsyms = sc.nsyms, .stroff = sc.stroff, .strsize = sc.strsize };
            },
            LC_DYSYMTAB => {
                if (lc.cmdsize < @sizeOf(DysymtabCommand)) return LoadError.Truncated;
                const dc: *const DysymtabCommand = @ptrCast(@alignCast(image.ptr + off));
                dysymtab = .{ .ilocalsym = dc.ilocalsym, .nlocalsym = dc.nlocalsym, .iextdefsym = dc.iextdefsym, .nextdefsym = dc.nextdefsym, .iundefsym = dc.iundefsym, .nundefsym = dc.nundefsym, .extreloff = dc.extreloff, .nextrel = dc.nextrel, .locreloff = dc.locreloff, .nlocrel = dc.nlocrel };
            },
            else => {},
        }
        off += lc.cmdsize;
    }

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
    if (loadable_count == 0) return LoadError.NoEntryPoint;
    if (loadable_count > regions_out.len) return LoadError.OutOfRegions;
    regions_used.* = loadable_count;

    if (entry_vmaddr == null) {
        if (entry_fileoff) |foff| {
            for (seg_headers[0..seg_count]) |s| {
                if (foff >= s.fileoff and foff < s.fileoff + s.filesize) {
                    entry_vmaddr = s.vmaddr + (foff - s.fileoff);
                    break;
                }
            }
        } else if (header.filetype == MH_DYLIB) {
            entry_vmaddr = min_vmaddr;
        }
        if (entry_vmaddr == null) return LoadError.NoEntryPoint;
    }
    const raw_entry = entry_vmaddr.?;

    const max_end = blk: {
        var m: u64 = 0;
        for (seg_headers[0..seg_count]) |s| {
            if (s.vmsize == 0 or s.maxprot == 0) continue;
            const end = s.vmaddr + s.vmsize;
            if (end > m) m = end;
        }
        break :blk m;
    };

    const total_pages = pageAlign(max_end - min_vmaddr) / mmu.PAGE_SIZE;
    const base_pa = mmu.allocPage();
    var pi: u64 = 1;
    while (pi < total_pages) : (pi += 1) _ = mmu.allocPage();
    const slide = base_pa -% min_vmaddr;

    var region_idx: usize = 0;
    for (seg_headers[0..seg_count]) |s| {
        if (s.vmsize == 0 or s.maxprot == 0) continue;
        if (@as(u64, s.fileoff) + s.filesize > image.len) return LoadError.Truncated;
        const seg_pa = base_pa + (s.vmaddr - min_vmaddr);
        const copy_len = @min(s.filesize, s.vmsize);
        if (copy_len > 0) {
            const dst: [*]u8 = @ptrFromInt(seg_pa);
            @memcpy(dst[0..copy_len], image[s.fileoff..][0..copy_len]);
        }
        regions_out[region_idx] = .{ .pa = seg_pa, .len = pageAlign(s.vmsize), .prot = segProt(s.initprot, options.user_accessible) };
        region_idx += 1;
    }

    var local_symbol_count: usize = 0;
    var external_symbol_count: usize = 0;
    var undefined_symbol_count: usize = 0;
    if (symtab) |st| {
        parseSymbols(image, st, dysymtab, slide, &local_symbol_storage, &local_symbol_count, &external_symbol_storage, &external_symbol_count, &undefined_symbol_storage, &undefined_symbol_count) catch |err| return err;
    }

    var local_reloc_count: usize = 0;
    var external_reloc_count: usize = 0;
    if (dysymtab) |dt| {
        parseRelocs(image, dt.locreloff, dt.nlocrel, &local_reloc_storage, &local_reloc_count) catch |err| return err;
        parseRelocs(image, dt.extreloff, dt.nextrel, &external_reloc_storage, &external_reloc_count) catch |err| return err;
        applyExternalRelocations(base_pa, min_vmaddr, &external_reloc_storage, external_reloc_count, &undefined_symbol_storage, undefined_symbol_count, options.resolver, options.resolver_ctx) catch |err| return err;
    }

    if (dyldinfo) |info| {
        if (@as(u64, info.rebase_off) + info.rebase_size > image.len) return LoadError.Truncated;
        if (info.rebase_size > 0) applyRebase(image[info.rebase_off..][0..info.rebase_size], seg_headers[0..seg_count], base_pa, slide, min_vmaddr);
    }

    if (dyldinfo) |info| {
        if (@as(u64, info.bind_off) + info.bind_size > image.len or @as(u64, info.lazy_bind_off) + info.lazy_bind_size > image.len) return LoadError.Truncated;
        if (info.bind_size > 0) try applyBindings(image[info.bind_off..][0..info.bind_size], seg_headers[0..seg_count], base_pa, min_vmaddr, options.resolver, options.resolver_ctx);
        // A full dyld resolves these on first use through a stub. Eagerly bind
        // them because this kernel loader deliberately has no dyld trampoline.
        if (info.lazy_bind_size > 0) try applyBindings(image[info.lazy_bind_off..][0..info.lazy_bind_size], seg_headers[0..seg_count], base_pa, min_vmaddr, options.resolver, options.resolver_ctx);
    }

    if (chained_fixups) |bytes| {
        const r = options.resolver orelse return LoadError.UnresolvedSymbol;
        dyld.applyChainedFixups(bytes, base_pa, r, options.resolver_ctx) catch |err| return switch (err) {
            error.Truncated => LoadError.Truncated,
            error.UnsupportedImportFormat => LoadError.UnsupportedImportFormat,
            error.UnsupportedPointerFormat => LoadError.UnsupportedPointerFormat,
            error.UnresolvedSymbol => LoadError.UnresolvedSymbol,
        };
    }

    return .{
        .entry = base_pa + (raw_entry - min_vmaddr),
        .mach_header = base_pa,
        .slide = slide,
        .sections = section_storage[0..section_count],
        .local_symbols = local_symbol_storage[0..local_symbol_count],
        .external_symbols = external_symbol_storage[0..external_symbol_count],
        .undefined_symbols = undefined_symbol_storage[0..undefined_symbol_count],
        .local_relocs = local_reloc_storage[0..local_reloc_count],
        .external_relocs = external_reloc_storage[0..external_reloc_count],
    };
}

const SegInfo = struct { vmaddr: u64, vmsize: u64, fileoff: u64, filesize: u64, initprot: u32, maxprot: u32 };
const DyldInfo = struct { rebase_off: u32, rebase_size: u32, bind_off: u32, bind_size: u32, lazy_bind_off: u32, lazy_bind_size: u32 };
const Symtab = struct { symoff: u32, nsyms: u32, stroff: u32, strsize: u32 };
const Dysymtab = struct { ilocalsym: u32, nlocalsym: u32, iextdefsym: u32, nextdefsym: u32, iundefsym: u32, nundefsym: u32, extreloff: u32, nextrel: u32, locreloff: u32, nlocrel: u32 };

fn readU32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24);
}

fn readBindUleb(bytes: []const u8, cursor: *usize) LoadError!u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (cursor.* >= bytes.len or shift > 63) return LoadError.UnsupportedImportFormat;
        const byte = bytes[cursor.*];
        cursor.* += 1;
        result |= @as(u64, byte & 0x7f) << shift;
        if ((byte & 0x80) == 0) return result;
        shift += 7;
    }
}

fn readBindSleb(bytes: []const u8, cursor: *usize) LoadError!i64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    var byte: u8 = 0;
    while (true) {
        if (cursor.* >= bytes.len or shift > 63) return LoadError.UnsupportedImportFormat;
        byte = bytes[cursor.*];
        cursor.* += 1;
        result |= @as(u64, byte & 0x7f) << shift;
        shift += 7;
        if ((byte & 0x80) == 0) break;
    }
    if (shift < 64 and (byte & 0x40) != 0) result |= ~@as(u64, 0) << shift;
    return @bitCast(result);
}

fn applyBindings(bytes: []const u8, segs: []const SegInfo, base_pa: u64, min_vmaddr: u64, resolver: ?dyld.Resolver, resolver_ctx: ?*anyopaque) LoadError!void {
    const r = resolver;
    var cursor: usize = 0;
    var ordinal: u8 = 0;
    var symbol: []const u8 = "";
    var addend: i64 = 0;
    var seg_idx: usize = 0;
    var offset: u64 = 0;
    while (cursor < bytes.len) {
        const opbyte = bytes[cursor];
        cursor += 1;
        const opcode = opbyte & BIND_OPCODE_MASK;
        const imm = opbyte & BIND_IMM_MASK;
        switch (opcode) {
            BIND_OPCODE_DONE => {},
            BIND_OPCODE_SET_DYLIB_ORDINAL_IMM => ordinal = imm,
            BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB => {
                const v = try readBindUleb(bytes, &cursor);
                if (v > 255) return LoadError.UnsupportedImportFormat;
                ordinal = @intCast(v);
            },
            BIND_OPCODE_SET_DYLIB_SPECIAL_IMM => ordinal = @bitCast(if (imm == 0) @as(i8, 0) else @as(i8, @intCast(imm | 0xf0))),
            BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM => {
                const start = cursor;
                while (cursor < bytes.len and bytes[cursor] != 0) : (cursor += 1) {}
                if (cursor == bytes.len) return LoadError.Truncated;
                symbol = bytes[start..cursor];
                cursor += 1;
            },
            BIND_OPCODE_SET_TYPE_IMM => if (imm != 1) return LoadError.UnsupportedImportFormat,
            BIND_OPCODE_SET_ADDEND_SLEB => addend = try readBindSleb(bytes, &cursor),
            BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB => {
                seg_idx = imm;
                offset = try readBindUleb(bytes, &cursor);
            },
            BIND_OPCODE_ADD_ADDR_ULEB => offset += try readBindUleb(bytes, &cursor),
            BIND_OPCODE_DO_BIND => {
                try bindOne(segs, base_pa, min_vmaddr, seg_idx, offset, ordinal, symbol, addend, r, resolver_ctx);
                offset += 8;
            },
            BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB => {
                try bindOne(segs, base_pa, min_vmaddr, seg_idx, offset, ordinal, symbol, addend, r, resolver_ctx);
                offset += 8 + try readBindUleb(bytes, &cursor);
            },
            BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED => {
                try bindOne(segs, base_pa, min_vmaddr, seg_idx, offset, ordinal, symbol, addend, r, resolver_ctx);
                offset += 8 + @as(u64, imm) * 8;
            },
            BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB => {
                const count = try readBindUleb(bytes, &cursor);
                const skip = try readBindUleb(bytes, &cursor);
                var n: u64 = 0;
                while (n < count) : (n += 1) {
                    try bindOne(segs, base_pa, min_vmaddr, seg_idx, offset, ordinal, symbol, addend, r, resolver_ctx);
                    offset += 8 + skip;
                }
            },
            else => return LoadError.UnsupportedImportFormat,
        }
    }
}

fn bindOne(segs: []const SegInfo, base_pa: u64, min_vmaddr: u64, seg_idx: usize, offset: u64, ordinal: u8, symbol: []const u8, addend: i64, resolver: ?dyld.Resolver, resolver_ctx: ?*anyopaque) LoadError!void {
    if (seg_idx >= segs.len or offset + 8 > segs[seg_idx].vmsize or symbol.len == 0) return LoadError.UnsupportedImportFormat;
    const resolve = resolver orelse {
        // When loading the provider dylib itself there is no outside
        // dyld/runtime resolver. This minimal FOSS libSystem is used as a
        // syscall-stub provider; we do not run its hosted startup path, so any
        // unresolved helper/runtime bind slots should remain cold. Executables
        // still pass a resolver and therefore keep strict unresolved-symbol
        // diagnostics.
        const ptr: *align(1) u64 = @ptrFromInt(base_pa + (segs[seg_idx].vmaddr - min_vmaddr) + offset);
        ptr.* = 0;
        return;
    };
    const target = resolve(resolver_ctx, ordinal, symbol) orelse {
        last_unresolved_symbol = symbol;
        return LoadError.UnresolvedSymbol;
    };
    const ptr: *align(1) u64 = @ptrFromInt(base_pa + (segs[seg_idx].vmaddr - min_vmaddr) + offset);
    ptr.* = target +% @as(u64, @bitCast(addend));
}

fn readU64(bytes: []const u8) u64 {
    return @as(u64, bytes[0]) | (@as(u64, bytes[1]) << 8) | (@as(u64, bytes[2]) << 16) | (@as(u64, bytes[3]) << 24) |
        (@as(u64, bytes[4]) << 32) | (@as(u64, bytes[5]) << 40) | (@as(u64, bytes[6]) << 48) | (@as(u64, bytes[7]) << 56);
}

fn segProt(initprot: u32, user_accessible: bool) mmu.Prot {
    return .{ .writable = (initprot & VM_PROT_WRITE) != 0, .executable = (initprot & VM_PROT_EXECUTE) != 0, .user = user_accessible };
}

fn pageAlign(n: u64) u64 {
    return (n + mmu.PAGE_SIZE - 1) & ~@as(u64, mmu.PAGE_SIZE - 1);
}

fn symName(image: []const u8, st: Symtab, strx: u32) LoadError![]const u8 {
    if (strx >= st.strsize or @as(u64, st.stroff) + st.strsize > image.len) return LoadError.Truncated;
    const start = @as(usize, st.stroff + strx);
    const strings_end = @as(usize, st.stroff + st.strsize);
    const end = std.mem.indexOfScalar(u8, image[start..strings_end], 0) orelse return LoadError.Truncated;
    return image[start..][0..end];
}

fn parseSymbols(
    image: []const u8,
    st: Symtab,
    dt_opt: ?Dysymtab,
    slide: u64,
    locals: *[64]Symbol,
    local_count: *usize,
    externals: *[256]Symbol,
    external_count: *usize,
    undefs: *[64]Symbol,
    undef_count: *usize,
) LoadError!void {
    if (@as(u64, st.symoff) + @as(u64, st.nsyms) * @sizeOf(Nlist64) > image.len) return LoadError.Truncated;
    var i: u32 = 0;
    while (i < st.nsyms) : (i += 1) {
        const n: *const Nlist64 = @ptrCast(@alignCast(image.ptr + st.symoff + @as(usize, i) * @sizeOf(Nlist64)));
        const kind: SymbolKind = if ((n.n_type & N_TYPE) == N_UNDF) .undefined else if ((n.n_type & N_EXT) != 0) .external else .local;
        const sym = Symbol{ .name = try symName(image, st, n.n_strx), .value = if ((n.n_type & N_TYPE) == N_SECT) n.n_value +% slide else n.n_value, .sect = n.n_sect, .kind = kind };
        switch (kind) {
            .undefined => {
                if (undef_count.* < undefs.len) {
                    undefs[undef_count.*] = sym;
                    undef_count.* += 1;
                }
            },
            .external => {
                if (external_count.* < externals.len) {
                    externals[external_count.*] = sym;
                    external_count.* += 1;
                }
            },
            .local => {
                if (local_count.* < locals.len) {
                    locals[local_count.*] = sym;
                    local_count.* += 1;
                }
            },
        }
    }
    if (dt_opt) |dt| {
        validateSymRange(st.nsyms, dt.ilocalsym, dt.nlocalsym) catch return LoadError.Truncated;
        validateSymRange(st.nsyms, dt.iextdefsym, dt.nextdefsym) catch return LoadError.Truncated;
        validateSymRange(st.nsyms, dt.iundefsym, dt.nundefsym) catch return LoadError.Truncated;
    }
}

fn validateSymRange(nsyms: u32, start: u32, count: u32) !void {
    if (@as(u64, start) + count > nsyms) return error.BadRange;
}

fn parseRelocs(image: []const u8, reloff: u32, nreloc: u32, out: *[MAX_EXT_RELOCS]Relocation, count: *usize) LoadError!void {
    if (nreloc == 0) return;
    if (nreloc > out.len) return LoadError.TooManyRelocations;
    if (@as(u64, reloff) + @as(u64, nreloc) * @sizeOf(RelocationInfo) > image.len) return LoadError.Truncated;
    var i: u32 = 0;
    while (i < nreloc) : (i += 1) {
        const raw: *const RelocationInfo = @ptrCast(@alignCast(image.ptr + reloff + @as(usize, i) * @sizeOf(RelocationInfo)));
        if (raw.r_address < 0) return LoadError.UnsupportedRelocation;
        const word = raw.r_word;
        out[count.*] = .{ .address = @intCast(raw.r_address), .symbolnum = word & 0x00ff_ffff, .pcrel = ((word >> 24) & 1) != 0, .length = @intCast((word >> 25) & 0x3), .extern_ = ((word >> 27) & 1) != 0, .type_ = @intCast((word >> 28) & 0xf) };
        count.* += 1;
    }
}

fn applyExternalRelocations(base_pa: u64, min_vmaddr: u64, relocs: *[MAX_EXT_RELOCS]Relocation, reloc_count: usize, undefs: *[64]Symbol, undef_count: usize, resolver: ?dyld.Resolver, resolver_ctx: ?*anyopaque) LoadError!void {
    for (relocs[0..reloc_count]) |r| {
        if (!r.extern_) continue;
        if (r.symbolnum >= undef_count) return LoadError.UnresolvedSymbol;
        const resolve = resolver orelse return LoadError.UnresolvedSymbol;
        const sym = undefs[r.symbolnum];
        const target = resolve(resolver_ctx, 0, sym.name) orelse return LoadError.UnresolvedSymbol;
        const pa = base_pa + (r.address - min_vmaddr);
        if (r.type_ == ARM64_RELOC_UNSIGNED or (r.extern_ and r.type_ == ARM64_RELOC_POINTER_TO_GOT)) {
            if (r.length != 3) return LoadError.UnsupportedRelocation;
            const ptr: *align(1) u64 = @ptrFromInt(pa);
            ptr.* = target;
        } else {
            return LoadError.UnsupportedRelocation;
        }
    }
}

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

fn applyRebase(opcodes: []const u8, segs: []const SegInfo, base_pa: u64, slide: u64, min_vmaddr: u64) void {
    var seg_idx: usize = 0;
    var offset: u64 = 0;
    var rebase_type: u8 = 0;
    var idx: usize = 0;
    while (idx < opcodes.len) {
        const op = opcodes[idx];
        idx += 1;
        switch (op & REBASE_OPCODE_MASK) {
            REBASE_OPCODE_DONE => return,
            REBASE_OPCODE_SET_TYPE_IMM => rebase_type = op & REBASE_IMM_MASK,
            REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB => {
                seg_idx = op & REBASE_IMM_MASK;
                offset = readUleb(opcodes, &idx);
            },
            REBASE_OPCODE_ADD_ADDR_ULEB => offset += readUleb(opcodes, &idx),
            REBASE_OPCODE_ADD_ADDR_IMM_SCALED => offset += @as(u64, op & REBASE_IMM_MASK) * 8,
            REBASE_OPCODE_DO_REBASE_IMM_TIMES => rebaseAt(segs, base_pa, slide, min_vmaddr, seg_idx, &offset, op & REBASE_IMM_MASK),
            REBASE_OPCODE_DO_REBASE_ULEB_TIMES => rebaseAt(segs, base_pa, slide, min_vmaddr, seg_idx, &offset, readUleb(opcodes, &idx)),
            REBASE_OPCODE_DO_REBASE_ADD_ADDR_ULEB => {
                rebaseOne(segs, base_pa, slide, min_vmaddr, seg_idx, offset, rebase_type);
                offset += 8 + readUleb(opcodes, &idx);
            },
            REBASE_OPCODE_DO_REBASE_ULEB_TIMES_SKIPPING_ULEB => {
                const count = readUleb(opcodes, &idx);
                const skip = readUleb(opcodes, &idx);
                var j: u64 = 0;
                while (j < count) : (j += 1) {
                    rebaseOne(segs, base_pa, slide, min_vmaddr, seg_idx, offset, rebase_type);
                    offset += 8 + skip;
                }
            },
            else => return,
        }
    }
}

fn rebaseOne(segs: []const SegInfo, base_pa: u64, slide: u64, min_vmaddr: u64, seg_idx: usize, off: u64, rebase_type: u8) void {
    _ = rebase_type;
    if (seg_idx >= segs.len or off + 8 > segs[seg_idx].vmsize) return;
    const seg = segs[seg_idx];
    const ptr: *align(1) u64 = @ptrFromInt(base_pa + (seg.vmaddr - min_vmaddr) + off);
    ptr.* +%= slide;
}

fn rebaseAt(segs: []const SegInfo, base_pa: u64, slide: u64, min_vmaddr: u64, seg_idx: usize, off: *u64, count: u64) void {
    var j: u64 = 0;
    while (j < count) : (j += 1) {
        rebaseOne(segs, base_pa, slide, min_vmaddr, seg_idx, off.*, 0);
        off.* += 8;
    }
}

const ObjectSection = struct { input: Section64, loaded: u64 };

fn fixedNameEql(raw: *const [16]u8, comptime expected: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
    return std.mem.eql(u8, raw[0..end], expected);
}

fn objectSectionProt(sec: *const Section64) mmu.Prot {
    const executable = fixedNameEql(&sec.segname, "__TEXT") or fixedNameEql(&sec.sectname, "__text");
    const writable = !executable and sec.size != 0;
    return .{ .writable = writable, .executable = executable, .user = false };
}

fn alignForward(value: u64, pow2: u6) u64 {
    const a = @as(u64, 1) << pow2;
    return (value + a - 1) & ~(a - 1);
}

fn loadObjectSymbols(image: []const u8, st: Symtab, base: u64, sections: []const ObjectSection, out: *[128]Symbol) LoadError!void {
    if (st.nsyms > out.len) return LoadError.UnresolvedSymbol;
    if (@as(u64, st.symoff) + @as(u64, st.nsyms) * @sizeOf(Nlist64) > image.len) return LoadError.Truncated;
    var i: u32 = 0;
    while (i < st.nsyms) : (i += 1) {
        const n: *const Nlist64 = @ptrCast(@alignCast(image.ptr + st.symoff + @as(usize, i) * @sizeOf(Nlist64)));
        const kind: SymbolKind = if ((n.n_type & N_TYPE) == N_UNDF) .undefined else if ((n.n_type & N_EXT) != 0) .external else .local;
        var value = n.n_value;
        if ((n.n_type & N_TYPE) == N_SECT) {
            if (n.n_sect == 0 or n.n_sect > sections.len) return LoadError.Truncated;
            const sec = sections[n.n_sect - 1];
            value = base + sec.loaded + (n.n_value - sec.input.addr);
        }
        out[i] = .{ .name = try symName(image, st, n.n_strx), .value = value, .sect = n.n_sect, .kind = kind };
    }
}

fn relocTarget(r: Relocation, base: u64, sections: []const ObjectSection, symbols: *[128]Symbol, nsyms: u32, options: KernelObjectOptions) LoadError!u64 {
    if (r.extern_) {
        if (r.symbolnum >= nsyms) return LoadError.UnresolvedSymbol;
        const sym = symbols[r.symbolnum];
        if (sym.kind == .undefined) return options.resolver(options.resolver_ctx, sym.name) orelse LoadError.UnresolvedSymbol;
        return sym.value;
    }
    if (r.symbolnum == 0 or r.symbolnum > sections.len) return LoadError.UnsupportedRelocation;
    return base + sections[r.symbolnum - 1].loaded;
}

fn applyObjectRelocations(image: []const u8, reloff: u32, nreloc: u32, section_addr: u64, base: u64, sections: []const ObjectSection, symbols: *[128]Symbol, nsyms: u32, options: KernelObjectOptions) LoadError!void {
    if (nreloc > MAX_LOCAL_RELOCS) return LoadError.TooManyRelocations;
    if (@as(u64, reloff) + @as(u64, nreloc) * @sizeOf(RelocationInfo) > image.len) return LoadError.Truncated;
    var i: u32 = 0;
    var addend: i64 = 0;
    while (i < nreloc) : (i += 1) {
        const raw: *const RelocationInfo = @ptrCast(@alignCast(image.ptr + reloff + @as(usize, i) * @sizeOf(RelocationInfo)));
        if (raw.r_address < 0) return LoadError.UnsupportedRelocation;
        const word = raw.r_word;
        const r = Relocation{ .address = @intCast(raw.r_address), .symbolnum = word & 0x00ff_ffff, .pcrel = ((word >> 24) & 1) != 0, .length = @intCast((word >> 25) & 0x3), .extern_ = ((word >> 27) & 1) != 0, .type_ = @intCast((word >> 28) & 0xf) };
        if (r.type_ == ARM64_RELOC_ADDEND) {
            addend = @as(i32, @bitCast(r.symbolnum));
            continue;
        }
        const place = section_addr + r.address;
        const target = try relocTarget(r, base, sections, symbols, nsyms, options);
        switch (r.type_) {
            ARM64_RELOC_UNSIGNED, ARM64_RELOC_POINTER_TO_GOT => {
                if (r.length != 3) return LoadError.UnsupportedRelocation;
                const ptr: *u64 = @ptrFromInt(place);
                ptr.* = target +% @as(u64, @bitCast(addend));
            },
            ARM64_RELOC_BRANCH26 => {
                if (r.length != 2 or !r.pcrel) return LoadError.UnsupportedRelocation;
                const instr: *u32 = @ptrFromInt(place);
                const delta: i64 = @as(i64, @intCast(target)) + addend - @as(i64, @intCast(place));
                if ((delta & 0x3) != 0) return LoadError.UnsupportedRelocation;
                const imm26: u32 = @truncate(@as(u64, @bitCast(delta >> 2)));
                instr.* = (instr.* & 0xfc00_0000) | (imm26 & 0x03ff_ffff);
            },
            ARM64_RELOC_PAGE21 => {
                if (r.length != 2 or !r.pcrel) return LoadError.UnsupportedRelocation;
                const instr: *u32 = @ptrFromInt(place);
                const page_delta = (@as(i64, @intCast((target +% @as(u64, @bitCast(addend))) & ~@as(u64, 0xfff))) - @as(i64, @intCast(place & ~@as(u64, 0xfff)))) >> 12;
                const imm = @as(u64, @bitCast(page_delta));
                instr.* = (instr.* & 0x9f00_001f) | (@as(u32, @intCast((imm & 0x3) << 29))) | (@as(u32, @intCast((imm & 0x1ffffc) << 3)));
            },
            ARM64_RELOC_PAGEOFF12 => {
                if (r.length != 2) return LoadError.UnsupportedRelocation;
                const instr: *u32 = @ptrFromInt(place);
                const imm12: u32 = @intCast((target +% @as(u64, @bitCast(addend))) & 0xfff);
                instr.* = (instr.* & 0xffc0_03ff) | (imm12 << 10);
            },
            ARM64_RELOC_SUBTRACTOR, R_ABS => return LoadError.UnsupportedRelocation,
            else => return LoadError.UnsupportedRelocation,
        }
        addend = 0;
    }
}
