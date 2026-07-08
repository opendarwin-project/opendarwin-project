//! Minimal Mach-O loader for milestone 1: parses just enough of a static,
//! non-PIE arm64 mach_header_64 + LC_SEGMENT_64/LC_UNIXTHREAD binary to map
//! it into a task's address space and find its entry point. No dyld, no
//! LC_MAIN, no relocations - see loader/hello.S (the test binary this is
//! built against) for exactly what's assumed to be true.

const mmu = @import("../mm/mmu.zig");

const MH_MAGIC_64: u32 = 0xfeedfacf;
const CPU_TYPE_ARM64: u32 = 0x0100000c;
const CPU_TYPE_ARM64_MASK: u32 = 0xff00_ffff; // strips the ptrauth-ABI bits some arm64e producers set

const LC_SEGMENT_64: u32 = 0x19;
const LC_UNIXTHREAD: u32 = 0x5;

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

// AArch64 LC_UNIXTHREAD payload: flavor ARM_THREAD_STATE64 (6), then a
// count, then 68 x u64/u32 registers where index 32 is `pc`.
const ARM_THREAD_STATE64: u32 = 6;
const ThreadCommand = extern struct {
    cmd: u32,
    cmdsize: u32,
    flavor: u32,
    count: u32,
    // followed by `count` u32s of arm_thread_state64_t; we only need pc.
};

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

/// Maps every LC_SEGMENT_64 in `image` (the raw file bytes, already resident
/// in kernel memory) into `regions_out`, using one freshly allocated
/// physical page per page of segment content (copied from the file, zero
/// filled past filesize up to vmsize), and returns the entry point taken
/// from LC_UNIXTHREAD.
///
/// `regions_out` must be at least as large as the number of segments; the
/// slice actually used is returned via `regions_used`.
pub fn load(image: []const u8, regions_out: []mmu.Region, regions_used: *usize) LoadError!LoadResult {
    if (image.len < @sizeOf(MachHeader64)) return LoadError.Truncated;
    const header: *const MachHeader64 = @ptrCast(@alignCast(image.ptr));
    if (header.magic != MH_MAGIC_64) return LoadError.BadMagic;
    if ((header.cputype & CPU_TYPE_ARM64_MASK) != CPU_TYPE_ARM64) return LoadError.WrongArch;

    var raw_entry: ?u64 = null;
    var count: usize = 0;

    // Parallel to regions_out: each segment's *linked* vmaddr, needed to
    // translate `raw_entry` (also a linked vmaddr) into the address it was
    // actually loaded at, since mapSegment() ignores vmaddr and places
    // segment content wherever allocPage() has room (see mapSegment's doc
    // comment for why that's safe for a single-segment PC-relative binary).
    var seg_vmaddrs: [MAX_SEGMENTS]u64 = undefined;

    var off: usize = @sizeOf(MachHeader64);
    var i: u32 = 0;
    while (i < header.ncmds) : (i += 1) {
        if (off + @sizeOf(LoadCommand) > image.len) return LoadError.Truncated;
        const lc: *const LoadCommand = @ptrCast(@alignCast(image.ptr + off));
        if (off + lc.cmdsize > image.len) return LoadError.Truncated;

        switch (lc.cmd) {
            LC_SEGMENT_64 => {
                const seg: *const SegmentCommand64 = @ptrCast(@alignCast(image.ptr + off));
                // __PAGEZERO (maxprot 0, vmsize typically 4GB) is a
                // deliberate unmapped guard region, not real content.
                if (seg.vmsize > 0 and seg.maxprot != 0) {
                    if (count >= regions_out.len or count >= MAX_SEGMENTS) return LoadError.Truncated;
                    regions_out[count] = mapSegment(image, seg);
                    seg_vmaddrs[count] = seg.vmaddr;
                    count += 1;
                }
            },
            LC_UNIXTHREAD => {
                const tc: *const ThreadCommand = @ptrCast(@alignCast(image.ptr + off));
                if (tc.flavor == ARM_THREAD_STATE64) {
                    // arm_thread_state64_t: x[0..28] (29), fp, lr, sp, pc,
                    // cpsr (u32) + pad. pc is the 33rd u64 -> byte offset
                    // 32*8 from the start of the register payload.
                    const regs_base = image.ptr + off + @sizeOf(ThreadCommand);
                    const pc_ptr: *align(1) const u64 = @ptrCast(regs_base + 32 * 8);
                    raw_entry = pc_ptr.*;
                }
            },
            else => {},
        }

        off += lc.cmdsize;
    }

    regions_used.* = count;

    const entry_vmaddr = raw_entry orelse return LoadError.NoEntryPoint;
    var j: usize = 0;
    while (j < count) : (j += 1) {
        const seg_len = regions_out[j].len;
        if (entry_vmaddr >= seg_vmaddrs[j] and entry_vmaddr - seg_vmaddrs[j] < seg_len) {
            return .{ .entry = regions_out[j].pa + (entry_vmaddr - seg_vmaddrs[j]) };
        }
    }
    return LoadError.NoEntryPoint;
}

fn segProt(initprot: u32) mmu.Prot {
    return .{
        .writable = (initprot & VM_PROT_WRITE) != 0,
        .executable = (initprot & VM_PROT_EXECUTE) != 0,
        .user = true,
    };
}

/// Copies one segment's file content into freshly allocated physical pages
/// (zero-filled for the vmsize-filesize tail, e.g. bss) and returns the
/// mmu.Region describing it. Segments are assumed page-aligned and backed
/// by physically-contiguous freshly bump-allocated pages, which holds here
/// because allocPage() hands out consecutive pool slots and we allocate a
/// segment's pages in one run.
fn mapSegment(image: []const u8, seg: *const SegmentCommand64) mmu.Region {
    const page_count = (seg.vmsize + mmu.PAGE_SIZE - 1) / mmu.PAGE_SIZE;
    const base_pa = mmu.allocPage();
    var p: u64 = 1;
    while (p < page_count) : (p += 1) _ = mmu.allocPage();

    const dst: [*]u8 = @ptrFromInt(base_pa);
    const copy_len = @min(seg.filesize, seg.vmsize);
    if (seg.fileoff + copy_len <= image.len) {
        @memcpy(dst[0..copy_len], image[seg.fileoff..][0..copy_len]);
    }
    // Bytes past filesize up to vmsize are already zero: allocPage() zeroes
    // every page it hands out.

    return .{ .pa = base_pa, .len = page_count * mmu.PAGE_SIZE, .prot = segProt(seg.initprot) };
}
