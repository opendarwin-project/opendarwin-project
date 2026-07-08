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
const MAX_BOOT_TABLES = 64;
var table_pool: [MAX_BOOT_TABLES]Table align(PAGE_SIZE) = undefined;
var table_pool_used: usize = 0;

fn allocTable() *Table {
    if (table_pool_used >= MAX_BOOT_TABLES) @panic("mmu: out of boot page tables");
    const t = &table_pool[table_pool_used];
    table_pool_used += 1;
    // Deliberately not re-zeroed here: `table_pool` lives in .bss, which
    // start.S already zeroed with a scalar (safe pre-MMU) store loop, and
    // each slot is handed out exactly once. A runtime `t.* = Table.zeroed()`
    // here would be a 4KB struct-copy that the compiler is free to lower to
    // wide/vector stores - which unconditionally fault on Device memory
    // (the type the architecture forces on every access while the MMU we're
    // in the middle of building is still disabled).
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
        } else {
            table = @ptrFromInt(entry & 0x0000_ffff_ffff_f000);
        }
    }
    return table;
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

var kernel_root: Table align(PAGE_SIZE) = Table.zeroed();

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
    // SH0[13:12] TG0[15:14] T1SZ[21:16] A1[22] EPD1[23].
    const t0sz: u64 = 16;
    const EPD1: u64 = 1 << 23;
    const tcr: u64 =
        t0sz | // T0SZ
        (0b01 << 8) | // IRGN0 = WBWA
        (0b01 << 10) | // ORGN0 = WBWA
        (0b11 << 12) | // SH0 = inner shareable
        (0b00 << 14) | // TG0 = 4KB
        EPD1;
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
