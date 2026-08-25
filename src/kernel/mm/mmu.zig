//! AArch64 4KB-granule, 4-level translation table setup for milestone 1.
//!
//! Deliberately a single flat identity-mapped (VA == PA) address space via
//! TTBR0_EL1 only; TTBR1_EL1 walks are disabled (TCR_EL1.EPD1 = 1). A true
//! higher-half kernel (TTBR1 = shared kernel mappings, TTBR0 = per-task user
//! mappings, unaffected by task switches) needs the kernel to actually be
//! *linked and executing* at a high VA, which means either relocating it at
//! boot or a link-time VMA/LMA split - real, but non-trivial, extra work
//! deferred past milestone 1. For now every per-task page table (proc/task.zig,
//! step 6) is a superset containing both the kernel's identity mappings and
//! that task's own user segments, and a context switch simply swaps TTBR0
//! between them.
//!
//! Note: real XNU on Apple Silicon uses a 16KB granule / 3-level layout.
//! 4KB/4-level is simpler to hand-roll and is what most hobby AArch64
//! kernels + QEMU virt examples use; revisit if ABI fidelity matters later.

const std = @import("std");

pub const PAGE_SIZE: u64 = 0x1000;
pub const PAGE_SHIFT: u6 = 12;

// --- Descriptor bits (4KB granule, stage 1) ---

const DESC_VALID: u64 = 1 << 0;
const DESC_TABLE: u64 = 1 << 1; // at levels 0-2: table vs block
const DESC_PAGE: u64 = 1 << 1; // at level 3: must be 1 (page descriptor)

const AF: u64 = 1 << 10; // access flag - must be set or every access faults
const SH_INNER: u64 = 0b11 << 8;
const AP_RW_EL1: u64 = 0b00 << 6; // read/write, no EL0 access
const AP_RW_ALL: u64 = 0b01 << 6; // read/write, EL0 and EL1
const AP_RO_EL1: u64 = 0b10 << 6;
const AP_RO_ALL: u64 = 0b11 << 6;
const UXN: u64 = 1 << 54; // unprivileged execute-never
const PXN: u64 = 1 << 53; // privileged execute-never

// MAIR_EL1 attribute indices we define below.
const ATTR_NORMAL_IDX: u64 = 0;
const ATTR_DEVICE_IDX: u64 = 1;

fn attrIndex(idx: u64) u64 {
    return idx << 2;
}

pub const Prot = extern struct {
    writable: bool,
    executable: bool,
    user: bool,
    device: bool = false,
};

fn blockOrPageAttrs(prot: Prot) u64 {
    var d: u64 = DESC_VALID | AF | SH_INNER;
    d |= attrIndex(if (prot.device) ATTR_DEVICE_IDX else ATTR_NORMAL_IDX);
    d |= if (prot.writable)
        (if (prot.user) AP_RW_ALL else AP_RW_EL1)
    else
        (if (prot.user) AP_RO_ALL else AP_RO_EL1);
    if (!prot.executable) d |= UXN | PXN else if (!prot.user) d |= UXN; // kernel-exec pages stay non-executable from EL0
    return d;
}

/// A single 512-entry translation table, 4KB, naturally page-aligned.
pub const Table = extern struct {
    entries: [512]u64 align(PAGE_SIZE),

    pub fn zeroed() Table {
        return .{ .entries = [_]u64{0} ** 512 };
    }
};

fn levelIndex(va: u64, level: u2) u9 {
    const shift: u6 = switch (level) {
        0 => 39,
        1 => 30,
        2 => 21,
        3 => 12,
    };
    return @truncate(va >> shift);
}

/// A bump allocator for translation tables themselves, backed by a static
/// pool. Real physical-page allocation (mm/pmm.zig) replaces this once the
/// rest of the memory subsystem exists; for milestone 1's fixed kernel
/// mapping set this is sufficient and avoids a boot-order dependency on pmm.
// Sparse shared-cache mappings (loader/shared_cache.zig) each need fresh
// level0/1/2 radix-tree nodes - their VAs (e.g. 0x180xxxxxxx, 0x1e0xxxxxxx,
// 0x1e8xxxxxxx) are nowhere near each other or the kernel's own narrow
// low-address range, so a handful of dylib segments can burn through many
// tables fast. 64 was fine for the identity-mapped-only milestone; raised
// generously now that per-task extra mappings exist.
const MAX_BOOT_TABLES = 512;
var table_pool: [MAX_BOOT_TABLES]Table align(PAGE_SIZE) = undefined;
var table_pool_used: usize = 0;

fn allocTable() *Table {
    if (page_alloc_fn) |alloc_page| {
        const pa = alloc_page();
        if (pa == 0) @panic("mmu: out of memory allocating page table");
        const t: *Table = @ptrFromInt(pa);
        t.* = Table.zeroed();
        return t;
    }
    if (table_pool_used >= MAX_BOOT_TABLES) @panic("mmu: out of boot page tables");
    const t = &table_pool[table_pool_used];
    table_pool_used += 1;
    return t;
}

/// Maps [va, va+len) to [pa, pa+len) using 2MB blocks where possible,
/// falling back to 4KB pages for anything not 2MB-aligned. `root` is a
/// level-0 table.
pub fn mapRange(root: *Table, va_start: u64, pa_start: u64, len: u64, prot: Prot) void {
    std.debug.assert(va_start % PAGE_SIZE == 0);
    std.debug.assert(pa_start % PAGE_SIZE == 0);
    std.debug.assert(len % PAGE_SIZE == 0);

    const TWO_MB = 0x20_0000;
    var off: u64 = 0;
    while (off < len) {
        const va = va_start + off;
        const pa = pa_start + off;
        const remaining = len - off;

        if (va % TWO_MB == 0 and pa % TWO_MB == 0 and remaining >= TWO_MB) {
            mapBlock2M(root, va, pa, prot);
            off += TWO_MB;
        } else {
            mapPage4K(root, va, pa, prot);
            off += PAGE_SIZE;
        }
    }
}

fn descendOrCreate(root: *Table, va: u64, target_level: u2) *Table {
    var table = root;
    var level: u2 = 0;
    while (level < target_level) : (level += 1) {
        const idx = levelIndex(va, level);
        const entry = table.entries[idx];
        if (entry & DESC_VALID == 0) {
            const child = allocTable();
            table.entries[idx] = @intFromPtr(child) | DESC_TABLE | DESC_VALID;
            table = child;
        } else if (entry & DESC_TABLE == 0) {
            // Valid block descriptor where a finer walk is needed (e.g. PMM
            // free RAM inherited as 2MB kernel-only blocks, then a user
            // segment remaps 4KB pages inside that range). Split the block
            // into an equivalent table of page/block children so the remap
            // can override individual entries.
            table = splitBlockToTable(table, idx, level, entry);
        } else {
            table = @ptrFromInt(entry & 0x0000_ffff_ffff_f000);
        }
    }
    return table;
}

/// Replace a level-1 (1GB) or level-2 (2MB) block descriptor with a table
/// whose entries preserve the block's PA coverage and attribute bits.
fn splitBlockToTable(parent: *Table, idx: u9, level: u2, entry: u64) *Table {
    const child = allocTable();
    const TWO_MB: u64 = 0x20_0000;
    if (level == 2) {
        // 2MB block → 512×4KB page descriptors.
        const block_pa = entry & 0x0000_ffff_ffe0_0000;
        const attrs = (entry & ~@as(u64, 0x0000_ffff_ffe0_0000)) | DESC_PAGE;
        var i: u64 = 0;
        while (i < 512) : (i += 1) {
            child.entries[@intCast(i)] = (block_pa + i * PAGE_SIZE) | attrs;
        }
    } else if (level == 1) {
        // 1GB block → 512×2MB block descriptors (we don't emit 1GB today,
        // but handle it so a future mapBlock1G wouldn't soft-lock remaps).
        const block_pa = entry & 0x0000_ffff_c000_0000;
        const attrs = entry & ~@as(u64, 0x0000_ffff_c000_0000); // type bit stays 0 (block)
        var i: u64 = 0;
        while (i < 512) : (i += 1) {
            child.entries[@intCast(i)] = (block_pa + i * TWO_MB) | attrs;
        }
    } else {
        @panic("mmu: cannot split block at level 0");
    }
    parent.entries[idx] = @intFromPtr(child) | DESC_TABLE | DESC_VALID;
    return child;
}

fn mapBlock2M(root: *Table, va: u64, pa: u64, prot: Prot) void {
    const l2 = descendOrCreate(root, va, 2);
    const idx = levelIndex(va, 2);
    // Level 1/2 block descriptors: bit1 = 0 (block, not table).
    l2.entries[idx] = (pa & 0x0000_ffff_ffe0_0000) | blockOrPageAttrs(prot);
}

fn mapPage4K(root: *Table, va: u64, pa: u64, prot: Prot) void {
    const l3 = descendOrCreate(root, va, 3);
    const idx = levelIndex(va, 3);
    l3.entries[idx] = (pa & 0x0000_ffff_ffff_f000) | DESC_PAGE | blockOrPageAttrs(prot);
}

// Explicitly padded to 32 bytes (a multiple of 16): pre-MMU-enable code
// copying a whole `Region` by value (e.g. `for (regions) |r|`) may do so via
// a 16-byte vector load/store, and every element of an array of a
// non-16-byte-multiple-sized struct isn't 16-aligned even when the array
// itself is - see mmu.zig's module doc comment for why that's fatal here.
pub const Region = extern struct { pa: u64, len: u64, prot: Prot, _pad: u64 = 0 };

// Shared physical layout constants. Duplicated from kmain.zig's boot-time
// values on purpose (kept here too so proc/task.zig can build a per-task
// table without importing kmain, which would be a circular dependency) -
// keep in sync if the kernel's load address or image size bound changes.
pub const KERNEL_LOAD_ADDR: u64 = 0x4008_0000;
// Must match linker.ld's explicit `. = KERNEL_LOAD_ADDR + 0x1000000;` pad
// before .userpages - see that file's comment for why this needs to be a
// hard boundary rather than a generous guess. 16 MiB covers current BSS
// (page tables, sched slots, scratch) with plenty of headroom; the linker
// fails loudly if the image ever grows past this.
pub const KERNEL_IMAGE_MAX_LEN: u64 = 0x0100_0000;
pub const UART_BASE: u64 = 0x0900_0000;
pub const GIC_DIST_BASE: u64 = 0x0800_0000;
pub const GIC_MMIO_LEN: u64 = 0x0002_0000; // covers both GICD and GICC windows

/// Every per-task table (proc/task.zig) maps these in addition to that
/// task's own user segments, since this milestone uses a single flat
/// TTBR0-only address space rather than a TTBR1-backed shared kernel range
/// (see the module doc comment above).
pub const kernel_regions = [_]Region{
    .{
        .pa = KERNEL_LOAD_ADDR,
        .len = KERNEL_IMAGE_MAX_LEN,
        .prot = .{ .writable = true, .executable = true, .user = false },
    },
    .{
        .pa = UART_BASE,
        .len = PAGE_SIZE,
        .prot = .{ .writable = true, .executable = false, .user = false, .device = true },
    },
    .{
        .pa = GIC_DIST_BASE,
        .len = GIC_MMIO_LEN,
        .prot = .{ .writable = true, .executable = false, .user = false, .device = true },
    },
};

extern const __userpages_start: u8;
extern const __userpages_end: u8;

var kernel_root: Table align(PAGE_SIZE) = Table.zeroed();
const MAX_EXTRA_KERNEL_REGIONS = 16;
var extra_kernel_regions: [MAX_EXTRA_KERNEL_REGIONS]Region = undefined;
var extra_kernel_region_count: usize = 0;

/// Builds the kernel's flat identity-mapped TTBR0_EL1 table and enables the
/// stage-1 MMU. Must run with a valid kernel stack, and the caller's own
/// currently-executing code/stack range must be included in `regions` (PC
/// keeps running from the same physical==virtual address across the enable,
/// so there is no post-enable jump required).
pub fn enable(regions: []const Region) void {
    // `kernel_root` is already all-zero: it's a zero-initialized global
    // (lives in .bss, cleared by start.S's scalar zero loop). Re-assigning
    // it here at runtime would risk the same wide-store hazard noted in
    // allocTable() above.

    for (regions) |r| {
        mapRange(&kernel_root, r.pa, r.pa, r.len, r.prot);
    }

    // .userpages (page_pool - see linker.ld and the module doc comment) is
    // deliberately NOT part of `regions`/`kernel_regions`: it must stay out
    // of what every per-task table inherits, but the boot-time kernel
    // (kmain, before any task starts) still needs to write into it while
    // kernel_root is the active TTBR0, so map it here, only into
    // kernel_root specifically.
    const userpages_start: u64 = @intFromPtr(&__userpages_start);
    const userpages_end: u64 = @intFromPtr(&__userpages_end);
    mapRange(&kernel_root, userpages_start, userpages_start, userpages_end - userpages_start, .{
        .writable = true,
        .executable = false,
        .user = false,
    });

    enableForThisCore();
}

/// Every AArch64 core has its own MAIR_EL1/TCR_EL1/TTBR0_EL1/SCTLR_EL1 -
/// these are per-core system registers, not shared state. A secondary core
/// therefore needs this same programming applied again on itself before its
/// own accesses are Normal-memory-safe, even though `kernel_root` (the
/// actual page table contents) was already built once by the primary core
/// and is simply reused here, not rebuilt. Scalar-only, same as enable()'s
/// tail and for the same reason (this runs pre-MMU-enable on whichever core
/// calls it).
pub fn enableForThisCore() void {
    // MAIR_EL1: index 0 = Normal, Inner/Outer write-back cacheable;
    // index 1 = Device-nGnRnE.
    const mair: u64 = (0xff << (ATTR_NORMAL_IDX * 8)) | (0x00 << (ATTR_DEVICE_IDX * 8));
    asm volatile ("msr mair_el1, %[v]"
        :
        : [v] "r" (mair),
    );

    // TCR_EL1: 4KB granule, 48-bit VA (T0SZ=16) on TTBR0; TTBR1 walks
    // disabled entirely (EPD1=1) since this milestone doesn't use it.
    // Field layout (ARM ARM): T0SZ[5:0] EPD0[7] IRGN0[9:8] ORGN0[11:10]
    // SH0[13:12] TG0[15:14] T1SZ[21:16] A1[22] EPD1[23] IPS[34:32] TBI0[37].
    //
    // IPS must cover QEMU virt's high PCI ECAM (e.g. 0x4010000000). The
    // reset default IPS=0 is 32-bit PA only and address-size-faults there.
    //
    // TBI0 matches Darwin/XNU: ignore VA[63:56] on TTBR0 walks. aarch64-macos
    // userspace (Zig/LLVM) freely parks PAC residue / ptrauth / software tags
    // in that top byte; without TBI0 those addresses take a translation-fault
    // L0 (seen under -Doptimize=ReleaseFast on FAR 0xc0…… preferred VAs).
    const t0sz: u64 = 16;
    const EPD1: u64 = 1 << 23;
    const IPS_48: u64 = @as(u64, 0b101) << 32; // 48-bit intermediate physical addresses
    const TBI0: u64 = 1 << 37;
    const tcr: u64 =
        t0sz | // T0SZ
        (0b01 << 8) | // IRGN0 = WBWA
        (0b01 << 10) | // ORGN0 = WBWA
        (0b11 << 12) | // SH0 = inner shareable
        (0b00 << 14) | // TG0 = 4KB
        EPD1 |
        IPS_48 |
        TBI0;
    asm volatile ("msr tcr_el1, %[v]"
        :
        : [v] "r" (tcr),
    );

    asm volatile ("msr ttbr0_el1, %[v]"
        :
        : [v] "r" (@intFromPtr(&kernel_root)),
    );

    asm volatile ("isb");

    // SCTLR_EL1: set M (MMU enable), C (data cache), I (instruction cache).
    var sctlr: u64 = asm volatile ("mrs %[v], sctlr_el1"
        : [v] "=r" (-> u64),
    );
    sctlr |= (1 << 0) | (1 << 2) | (1 << 12);
    asm volatile ("msr sctlr_el1, %[v]"
        :
        : [v] "r" (sctlr),
    );
    asm volatile ("isb");
}

/// Maps an additional identity range into kernel_root and records it for
/// every future task table (`newTaskTable` inherits `extra_kernel_regions`).
/// Required for PCI MMIO BARs: after a user task is running, SVC handlers
/// still execute with that task's TTBR0, so device registers must be present
/// there — not only in `kernel_root`.
pub fn mapExtra(pa: u64, len: u64, prot: Prot) void {
    const aligned_pa = pa & ~(PAGE_SIZE - 1);
    const aligned_len = ((pa + len) - aligned_pa + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
    mapRange(&kernel_root, aligned_pa, aligned_pa, aligned_len, prot);
    // Deduplicate: assignBars/mapExtra may be called more than once for the
    // same window during probe.
    var already = false;
    for (extra_kernel_regions[0..extra_kernel_region_count]) |r| {
        if (r.pa == aligned_pa and r.len == aligned_len) {
            already = true;
            break;
        }
    }
    if (!already) {
        if (extra_kernel_region_count >= MAX_EXTRA_KERNEL_REGIONS) @panic("mmu: too many extra kernel regions");
        extra_kernel_regions[extra_kernel_region_count] = .{ .pa = aligned_pa, .len = aligned_len, .prot = prot };
        extra_kernel_region_count += 1;
    }
    switchTtbr0(&kernel_root); // flush stale TLB entries for the newly-mapped range
}

pub fn inheritExtraInTaskTables(pa: u64, len: u64, prot: Prot) void {
    const aligned_pa = pa & ~(PAGE_SIZE - 1);
    const aligned_len = ((pa + len) - aligned_pa + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
    if (extra_kernel_region_count >= MAX_EXTRA_KERNEL_REGIONS) @panic("mmu: too many extra kernel regions");
    extra_kernel_regions[extra_kernel_region_count] = .{ .pa = aligned_pa, .len = aligned_len, .prot = prot };
    extra_kernel_region_count += 1;
}

// --- Physical page allocation + per-task tables (step 6) ---
//
// Now that the MMU is enabled by the time any of this runs, ordinary struct
// copies are safe again (Normal memory tolerates unaligned/wide accesses),
// so unlike the boot-time code above these don't need the same care.

// Tiny emergency bump for any allocation that must happen before pmm.init.
// Post-init, kmain installs setPageAllocator(pmm.allocPage) so this pool is
// unused in normal boot. Kept in .userpages so pages stay outside
// kernel_regions (user mappings must not collide with kernel-only PTEs).
const MAX_BOOT_PAGES = 64;
var page_pool: [MAX_BOOT_PAGES][PAGE_SIZE]u8 align(PAGE_SIZE) linksection(".userpages") = undefined;
var page_pool_used: usize = 0;

const PageAllocFn = *const fn () u64;
var page_alloc_fn: ?PageAllocFn = null;

/// Install the post-boot page allocator (typically pmm.allocPage). Must be
/// called after pmm.init(). Avoids an mmu↔pmm import cycle.
pub fn setPageAllocator(f: PageAllocFn) void {
    page_alloc_fn = f;
}

/// Hands out a fresh, zeroed 4KB page and returns its physical (== virtual,
/// under this milestone's identity mapping) address. Prefers the installed
/// PMM hook; falls back to the tiny .userpages bump only before PMM is ready.
pub fn allocPage() u64 {
    if (page_alloc_fn) |f| return f();
    if (page_pool_used >= MAX_BOOT_PAGES) @panic("mmu: out of boot pages (PMM not ready)");
    const p = &page_pool[page_pool_used];
    page_pool_used += 1;
    @memset(p, 0);
    return @intFromPtr(p);
}

/// Builds a fresh page table containing the shared kernel mappings plus
/// `user_regions`, suitable for installing into TTBR0_EL1 for one task.
pub fn newTaskTable(user_regions: []const Region) *Table {
    const root = allocTable();
    for (kernel_regions) |r| mapRange(root, r.pa, r.pa, r.len, r.prot);
    for (extra_kernel_regions[0..extra_kernel_region_count]) |r| mapRange(root, r.pa, r.pa, r.len, r.prot);
    for (user_regions) |r| mapRange(root, r.pa, r.pa, r.len, r.prot);
    return root;
}

/// Maps `len` bytes starting at `va` to `pa` into an arbitrary page table.
/// A public wrapper around the file-private `mapRange`.
pub fn mapPages(root: *Table, va: u64, pa: u64, len: u64, prot: Prot) void {
    mapRange(root, va, pa, len, prot);
}

/// Switches TTBR0_EL1 to `table` (physical address) and flushes stale TLB
/// entries. Safe to call from Normal-memory code (i.e. after `enable()`).
pub fn switchTtbr0(table: *Table) void {
    asm volatile ("msr ttbr0_el1, %[v]"
        :
        : [v] "r" (@intFromPtr(table)),
    );
    asm volatile ("isb");
    asm volatile ("tlbi vmalle1");
    asm volatile ("dsb ish");
    asm volatile ("isb");
}

// ---------------------------------------------------------------------------
// COW support helpers
// ---------------------------------------------------------------------------

/// Clones the kernel mappings into a new page table. The new table inherits
/// all kernel regions plus any extra regions, but has no user mappings.
/// This is used by Vmm.fork() to create a child's address space.
pub fn cloneKernelMappings() Table {
    var new_root = Table.zeroed();
    for (kernel_regions) |r| mapRange(&new_root, r.pa, r.pa, r.len, r.prot);
    for (extra_kernel_regions[0..extra_kernel_region_count]) |r| {
        mapRange(&new_root, r.pa, r.pa, r.len, r.prot);
    }
    return new_root;
}

/// Walks the page table to find the physical address mapped at `va`.
/// Returns null if no valid mapping exists at that address.
pub fn getPhysicalAddress(table: *Table, va: u64) ?u64 {
    var t = table;
    const shifts = [_]u6{ 39, 30, 21 };
    for (shifts) |shift| {
        const idx = (va >> shift) & 0x1ff;
        const entry = t.entries[idx];
        if (entry & 1 == 0) return null;
        // Check if this is a block descriptor (level 1 or 2)
        if (entry & DESC_TABLE == 0 and shift > 12) {
            // Block descriptor - extract physical address
            const block_size: u64 = if (shift == 30) 0x40000000 else 0x200000; // 1GB or 2MB
            const offset = va & (block_size - 1);
            return (entry & 0x0000_ffff_ffe0_0000) + offset;
        }
        t = @ptrFromInt(entry & 0x0000_ffff_ffff_f000);
    }
    // Level 3 - page descriptor
    const idx = (va >> 12) & 0x1ff;
    const entry = t.entries[idx];
    if (entry & 1 == 0) return null;
    const page_offset = va & 0xFFF;
    return (entry & 0x0000_ffff_ffff_f000) + page_offset;
}
