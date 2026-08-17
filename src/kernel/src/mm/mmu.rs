//! AArch64 4KB-granule, 4-level translation table setup.

use spin::Mutex;

pub const PAGE_SIZE: u64 = 0x1000;
pub const PAGE_SHIFT: u32 = 12;

// --- Descriptor bits (4KB granule, stage 1) ---
const DESC_VALID: u64 = 1 << 0;
const DESC_TABLE: u64 = 1 << 1; // at levels 0-2: table vs block
const DESC_PAGE: u64 = 1 << 1; // at level 3: must be 1 (page descriptor)

const AF: u64 = 1 << 10; // access flag
const SH_INNER: u64 = 0b11 << 8;
const AP_RW_EL1: u64 = 0b00 << 6;
const AP_RW_ALL: u64 = 0b01 << 6;
const AP_RO_EL1: u64 = 0b10 << 6;
const AP_RO_ALL: u64 = 0b11 << 6;
const UXN: u64 = 1 << 54;
const PXN: u64 = 1 << 53;

// MAIR_EL1 attribute indices
const ATTR_NORMAL_IDX: u64 = 0;
const ATTR_DEVICE_IDX: u64 = 1;

#[inline(always)]
const fn attr_index(idx: u64) -> u64 {
    idx << 2
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Prot {
    pub writable: bool,
    pub executable: bool,
    pub user: bool,
    pub device: bool,
}

fn block_or_page_attrs(prot: Prot) -> u64 {
    let mut d: u64 = DESC_VALID | AF | SH_INNER;
    d |= attr_index(if prot.device {
        ATTR_DEVICE_IDX
    } else {
        ATTR_NORMAL_IDX
    });
    d |= if prot.writable {
        if prot.user { AP_RW_ALL } else { AP_RW_EL1 }
    } else {
        if prot.user { AP_RO_ALL } else { AP_RO_EL1 }
    };
    if !prot.executable {
        d |= UXN | PXN;
    } else if !prot.user {
        d |= UXN;
    }
    d
}

#[repr(C, align(4096))]
#[derive(Clone, Copy)]
pub struct Table {
    pub entries: [u64; 512],
}

unsafe impl Send for Table {}
unsafe impl Sync for Table {}

impl Table {
    pub const fn zeroed() -> Self {
        Self { entries: [0; 512] }
    }
}

#[inline(always)]
fn level_index(va: u64, level: u8) -> usize {
    let shift = match level {
        0 => 39,
        1 => 30,
        2 => 21,
        3 => 12,
        _ => unreachable!(),
    };
    ((va >> shift) & 0x1ff) as usize
}

const MAX_BOOT_TABLES: usize = 512;

struct TablePoolState {
    tables: [Table; MAX_BOOT_TABLES],
    used: usize,
    dynamic_allocator: Option<fn() -> u64>,
}

unsafe impl Send for TablePoolState {}
unsafe impl Sync for TablePoolState {}

static TABLE_POOL: Mutex<TablePoolState> = Mutex::new(TablePoolState {
    tables: [const { Table::zeroed() }; MAX_BOOT_TABLES],
    used: 0,
    dynamic_allocator: None,
});

pub fn set_page_allocator(alloc: fn() -> u64) {
    let mut pool = TABLE_POOL.lock();
    pool.dynamic_allocator = Some(alloc);
}

fn alloc_table() -> *mut Table {
    let mut pool = TABLE_POOL.lock();
    if let Some(alloc_fn) = pool.dynamic_allocator {
        drop(pool);
        let pa = alloc_fn();
        return pa as *mut Table;
    }

    if pool.used >= MAX_BOOT_TABLES {
        panic!("mmu: out of boot page tables");
    }
    let idx = pool.used;
    pool.used += 1;
    let ptr = &mut pool.tables[idx] as *mut Table;
    drop(pool);
    ptr
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct Region {
    pub pa: u64,
    pub len: u64,
    pub prot: Prot,
    pub _pad: u64,
}

pub const KERNEL_LOAD_ADDR: u64 = 0x4008_0000;
pub const KERNEL_IMAGE_MAX_LEN: u64 = 0x0060_0000;
pub const UART_BASE: u64 = 0x0900_0000;
pub const GIC_DIST_BASE: u64 = 0x0800_0000;
pub const GIC_MMIO_LEN: u64 = 0x0002_0000;

pub const KERNEL_REGIONS: [Region; 3] = [
    Region {
        pa: KERNEL_LOAD_ADDR,
        len: KERNEL_IMAGE_MAX_LEN,
        prot: Prot {
            writable: true,
            executable: true,
            user: false,
            device: false,
        },
        _pad: 0,
    },
    Region {
        pa: UART_BASE,
        len: PAGE_SIZE,
        prot: Prot {
            writable: true,
            executable: false,
            user: false,
            device: true,
        },
        _pad: 0,
    },
    Region {
        pa: GIC_DIST_BASE,
        len: GIC_MMIO_LEN,
        prot: Prot {
            writable: true,
            executable: false,
            user: false,
            device: true,
        },
        _pad: 0,
    },
];

unsafe extern "C" {
    static __userpages_start: u8;
    static __userpages_end: u8;
}

static KERNEL_ROOT: Mutex<Table> = Mutex::new(Table::zeroed());

const MAX_EXTRA_KERNEL_REGIONS: usize = 64;
struct ExtraKernelRegions {
    regions: [Region; MAX_EXTRA_KERNEL_REGIONS],
    count: usize,
}

unsafe impl Send for ExtraKernelRegions {}
unsafe impl Sync for ExtraKernelRegions {}

static EXTRA_KERNEL_REGIONS: Mutex<ExtraKernelRegions> = Mutex::new(ExtraKernelRegions {
    regions: [Region {
        pa: 0,
        len: 0,
        prot: Prot {
            writable: false,
            executable: false,
            user: false,
            device: false,
        },
        _pad: 0,
    }; MAX_EXTRA_KERNEL_REGIONS],
    count: 0,
});

const MAX_LIVE_TASK_TABLES: usize = 32;

struct LiveTaskTables {
    tables: [*mut Table; MAX_LIVE_TASK_TABLES],
    count: usize,
}

unsafe impl Send for LiveTaskTables {}
unsafe impl Sync for LiveTaskTables {}

static LIVE_TASK_TABLES: Mutex<LiveTaskTables> = Mutex::new(LiveTaskTables {
    tables: [core::ptr::null_mut(); MAX_LIVE_TASK_TABLES],
    count: 0,
});

fn split_block_to_table(parent: &mut Table, idx: usize, level: u8, entry: u64) -> *mut Table {
    let child = alloc_table();
    let child_ref = unsafe { &mut *child };
    const TWO_MB: u64 = 0x20_0000;
    if level == 2 {
        let block_pa = entry & 0x0000_ffff_ffe0_0000;
        let attrs = (entry & !0x0000_ffff_ffe0_0000) | DESC_PAGE;
        for i in 0..512 {
            child_ref.entries[i] = (block_pa + (i as u64) * PAGE_SIZE) | attrs;
        }
    } else if level == 1 {
        let block_pa = entry & 0x0000_ffff_c000_0000;
        let attrs = entry & !0x0000_ffff_c000_0000;
        for i in 0..512 {
            child_ref.entries[i] = (block_pa + (i as u64) * TWO_MB) | attrs;
        }
    } else {
        panic!("mmu: cannot split block at level 0");
    }
    parent.entries[idx] = (child as u64) | DESC_TABLE | DESC_VALID;
    child
}

fn descend_or_create<'a>(root: &'a mut Table, va: u64, target_level: u8) -> &'a mut Table {
    let mut current = root as *mut Table;
    for level in 0..target_level {
        let idx = level_index(va, level);
        unsafe {
            let entry = (*current).entries[idx];
            if (entry & DESC_VALID) == 0 {
                let child = alloc_table();
                (*current).entries[idx] = (child as u64) | DESC_TABLE | DESC_VALID;
                current = child;
            } else if (entry & DESC_TABLE) == 0 {
                current = split_block_to_table(&mut *current, idx, level, entry);
            } else {
                let child_pa = entry & 0x0000_ffff_ffff_f000;
                current = child_pa as *mut Table;
            }
        }
    }
    unsafe { &mut *current }
}

fn map_block_2m(root: &mut Table, va: u64, pa: u64, prot: Prot) {
    let l2 = descend_or_create(root, va, 2);
    let idx = level_index(va, 2);
    l2.entries[idx] = (pa & 0x0000_ffff_ffe0_0000) | block_or_page_attrs(prot);
}

fn map_page_4k(root: &mut Table, va: u64, pa: u64, prot: Prot) {
    let l3 = descend_or_create(root, va, 3);
    let idx = level_index(va, 3);
    l3.entries[idx] = (pa & 0x0000_ffff_ffff_f000) | DESC_PAGE | block_or_page_attrs(prot);
}

pub fn map_range(root: &mut Table, va_start: u64, pa_start: u64, len: u64, prot: Prot) {
    debug_assert!(va_start % PAGE_SIZE == 0);
    debug_assert!(pa_start % PAGE_SIZE == 0);
    debug_assert!(len % PAGE_SIZE == 0);

    const TWO_MB: u64 = 0x20_0000;
    let mut off: u64 = 0;
    while off < len {
        let va = va_start + off;
        let pa = pa_start + off;
        let remaining = len - off;

        if va % TWO_MB == 0 && pa % TWO_MB == 0 && remaining >= TWO_MB {
            map_block_2m(root, va, pa, prot);
            off += TWO_MB;
        } else {
            map_page_4k(root, va, pa, prot);
            off += PAGE_SIZE;
        }
    }
}

pub fn map_pages(root: &mut Table, va: u64, pa: u64, len: u64, prot: Prot) {
    map_range(root, va, pa, len, prot);
}

pub fn unmap_page_no_free(root: &mut Table, va: u64) {
    let mut current = root as *mut Table;
    for level in 0..3 {
        let idx = level_index(va, level);
        unsafe {
            let entry = (*current).entries[idx];
            if (entry & DESC_VALID) == 0 || (entry & DESC_TABLE) == 0 {
                return;
            }
            current = (entry & 0x0000_ffff_ffff_f000) as *mut Table;
        }
    }
    let idx = level_index(va, 3);
    unsafe {
        (*current).entries[idx] = 0;
    }
}

pub fn unmap_pages(root: &mut Table, va: u64, len: u64) {
    let mut off = 0;
    while off < len {
        unmap_page_no_free(root, va + off);
        off += PAGE_SIZE;
    }
}

pub fn get_physical_address(root: &Table, va: u64) -> Option<u64> {
    let mut current = root as *const Table;
    for level in 0..3 {
        let idx = level_index(va, level);
        unsafe {
            let entry = (*current).entries[idx];
            if (entry & DESC_VALID) == 0 {
                return None;
            }
            if level < 3 && (entry & DESC_TABLE) == 0 {
                if level == 2 {
                    let block_pa = entry & 0x0000_ffff_ffe0_0000;
                    return Some(block_pa + (va & 0x1f_ffff));
                } else if level == 1 {
                    let block_pa = entry & 0x0000_ffff_c000_0000;
                    return Some(block_pa + (va & 0x3fff_ffff));
                }
                return None;
            }
            current = (entry & 0x0000_ffff_ffff_f000) as *const Table;
        }
    }
    let idx = level_index(va, 3);
    unsafe {
        let entry = (*current).entries[idx];
        if (entry & DESC_VALID) == 0 {
            None
        } else {
            Some((entry & 0x0000_ffff_ffff_f000) | (va & (PAGE_SIZE - 1)))
        }
    }
}

pub fn is_mapped(root: &Table, va: u64) -> bool {
    get_physical_address(root, va).is_some()
}

pub fn enable(regions: &[Region]) {
    {
        let mut root = KERNEL_ROOT.lock();
        for r in regions {
            map_range(&mut root, r.pa, r.pa, r.len, r.prot);
        }

        let userpages_start = core::ptr::addr_of!(__userpages_start) as u64;
        let userpages_end = core::ptr::addr_of!(__userpages_end) as u64;
        if userpages_end > userpages_start {
            map_range(
                &mut root,
                userpages_start,
                userpages_start,
                userpages_end - userpages_start,
                Prot {
                    writable: true,
                    executable: false,
                    user: false,
                    device: false,
                },
            );
        }
    }

    enable_for_this_core();
}

pub fn enable_for_this_core() {
    let mair: u64 = (0xff << (ATTR_NORMAL_IDX * 8)) | (0x00 << (ATTR_DEVICE_IDX * 8));
    // TCR_EL1 field layout (ARM ARM): T0SZ[5:0] EPD0[7] IRGN0[9:8]
    // ORGN0[11:10] SH0[13:12] TG0[15:14] T1SZ[21:16] A1[22] EPD1[23]
    // IPS[34:32] TBI0[37]. T0SZ=16 -> 48-bit VA, 4-level (L0..L3) walk on
    // TTBR0, matching level_index()'s L0 shift of 39 below; EPD0 MUST stay
    // clear (TTBR0 is the only root in use - setting it disables TTBR0
    // walks and faults on the very first access after MMU-enable).
    // EPD1=1 disables TTBR1 entirely (unused, see module doc comment).
    // IPS=0b101 (48-bit) is required to cover QEMU virt's high PCI ECAM
    // (e.g. 0x4010000000); the reset default IPS=0 is 32-bit-only and
    // address-size-faults there. TBI0 matches Darwin/XNU: ignore VA[63:56]
    // on TTBR0 walks, since aarch64-macos userspace parks PAC/tag bits in
    // the top byte.
    let t0sz: u64 = 16;
    let epd1: u64 = 1 << 23;
    let ips_48: u64 = 0b101 << 32;
    let tbi0: u64 = 1 << 37;
    let tcr: u64 = t0sz
        | (0b01 << 8) // IRGN0 = WBWA
        | (0b01 << 10) // ORGN0 = WBWA
        | (0b11 << 12) // SH0 = inner shareable
        | (0b00 << 14) // TG0 = 4KB
        | epd1
        | ips_48
        | tbi0;
    let ttbr0 = {
        let root = KERNEL_ROOT.lock();
        &*root as *const Table as u64
    };

    unsafe {
        core::arch::asm!(
            "msr mair_el1, {mair}",
            "msr tcr_el1, {tcr}",
            "msr ttbr0_el1, {ttbr0}",
            "isb",
            "tlbi vmalle1",
            "dsb ish",
            "isb",
            mair = in(reg) mair,
            tcr = in(reg) tcr,
            ttbr0 = in(reg) ttbr0,
            options(nomem, nostack)
        );

        let mut sctlr: u64;
        core::arch::asm!("mrs {v}, sctlr_el1", v = out(reg) sctlr, options(nomem, nostack));
        sctlr |= (1 << 0) | (1 << 2) | (1 << 12);
        core::arch::asm!(
            "msr sctlr_el1, {v}",
            "isb",
            v = in(reg) sctlr,
            options(nomem, nostack)
        );
    }
}

/// Splits [pa, pa+len) into the sub-ranges NOT already covered by
/// KERNEL_REGIONS, writing them into `out` and returning the count.
/// KERNEL_REGIONS entries are mutually disjoint, so each successive region
/// can split a fragment into at most two pieces - `MAX_CLIP_FRAGMENTS`
/// covers the worst case of every region clipping the same fragment once.
const MAX_CLIP_FRAGMENTS: usize = KERNEL_REGIONS.len() + 1;

fn clip_against_kernel_regions(
    pa: u64,
    len: u64,
    out: &mut [(u64, u64); MAX_CLIP_FRAGMENTS],
) -> usize {
    let mut frags = *out;
    frags[0] = (pa, pa + len);
    let mut count = 1;
    for r in &KERNEL_REGIONS {
        let r_start = r.pa;
        let r_end = r.pa + r.len;
        let mut new_frags = [(0u64, 0u64); MAX_CLIP_FRAGMENTS];
        let mut new_count = 0;
        for &(s, e) in &frags[..count] {
            if e <= r_start || s >= r_end {
                new_frags[new_count] = (s, e);
                new_count += 1;
                continue;
            }
            if s < r_start {
                new_frags[new_count] = (s, r_start);
                new_count += 1;
            }
            if e > r_end {
                new_frags[new_count] = (r_end, e);
                new_count += 1;
            }
        }
        frags = new_frags;
        count = new_count;
    }
    *out = frags;
    count
}

/// Maps [pa, pa+len) as extra kernel memory, clipping out any sub-range
/// already covered by KERNEL_REGIONS first: KERNEL_REGIONS entries are set
/// up once (with their own correct protections) before the MMU is even
/// enabled, and blindly re-mapping over them here - e.g. the DTB window
/// overlapping the start of the kernel's own .text - would silently
/// downgrade live, in-use page-table entries (observed: stripped the
/// execute bit off part of .text, causing a permission fault on the very
/// next fetch from that range).
pub fn map_extra(pa: u64, len: u64, prot: Prot) {
    // Callers pass raw hardware register bases straight from a DTB "reg"
    // property - e.g. QEMU virt's virtio-mmio slots are only 0x200 apart,
    // far below PAGE_SIZE granularity. Round out to whole pages up front
    // so map_range's alignment invariants hold; mapping a whole page for a
    // sub-page device region is harmless (same page, re-mapped identically
    // if another device in it triggers its own map_extra call later).
    let aligned_pa = pa & !(PAGE_SIZE - 1);
    let aligned_end = (pa + len + PAGE_SIZE - 1) & !(PAGE_SIZE - 1);
    let pa = aligned_pa;
    let len = aligned_end - aligned_pa;
    let mut frags = [(0u64, 0u64); MAX_CLIP_FRAGMENTS];
    let n = clip_against_kernel_regions(pa, len, &mut frags);

    {
        let mut root = KERNEL_ROOT.lock();
        for &(s, e) in &frags[..n] {
            map_range(&mut root, s, s, e - s, prot);
        }
    }
    {
        let mut extra = EXTRA_KERNEL_REGIONS.lock();
        for &(s, e) in &frags[..n] {
            let mut covered = false;
            for i in 0..extra.count {
                let r = &extra.regions[i];
                if r.prot == prot && s >= r.pa && e <= r.pa + r.len {
                    covered = true;
                    break;
                }
            }
            if covered {
                continue;
            }
            if extra.count >= MAX_EXTRA_KERNEL_REGIONS {
                panic!("mmu: out of extra kernel regions");
            }
            let idx = extra.count;
            extra.regions[idx] = Region {
                pa: s,
                len: e - s,
                prot,
                _pad: 0,
            };
            extra.count += 1;
        }
    }
    for &(s, e) in &frags[..n] {
        inherit_extra_in_task_tables(s, e - s, prot);
    }
}

pub fn inherit_extra_in_task_tables(pa: u64, len: u64, prot: Prot) {
    let live = LIVE_TASK_TABLES.lock();
    for i in 0..live.count {
        let t = live.tables[i];
        if !t.is_null() {
            map_range(unsafe { &mut *t }, pa, pa, len, prot);
        }
    }
}

pub fn new_task_table(user_regions: &[Region]) -> &'static mut Table {
    let t_ptr = alloc_table();
    let t = unsafe { &mut *t_ptr };
    for r in &KERNEL_REGIONS {
        map_range(t, r.pa, r.pa, r.len, r.prot);
    }
    {
        let extra = EXTRA_KERNEL_REGIONS.lock();
        for i in 0..extra.count {
            let r = extra.regions[i];
            map_range(t, r.pa, r.pa, r.len, r.prot);
        }
    }
    for r in user_regions {
        map_range(t, r.pa, r.pa, r.len, r.prot);
    }
    {
        let mut live = LIVE_TASK_TABLES.lock();
        if live.count < MAX_LIVE_TASK_TABLES {
            let idx = live.count;
            live.tables[idx] = t_ptr;
            live.count += 1;
        }
    }
    t
}
