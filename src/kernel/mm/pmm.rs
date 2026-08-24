//! Physical Memory Manager (PMM).
//! Manages page frames, intrusive free list, and per-page reference counts.

use crate::mm::mmu;
use spin::Mutex;

const PAGE_SIZE: u64 = mmu::PAGE_SIZE;

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum PageState {
    #[default]
    Free = 0,
    Allocated = 1,
    Shared = 2,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct PageMeta {
    pub state: PageState,
    pub refcount: u8,
}

const MAX_PAGES: usize = 128 * 1024; // 512 MB

struct PmmState {
    page_meta: [PageMeta; MAX_PAGES],
    base_pfn: u64,
    max_pfn: u64,
    free_head: Option<u64>,
    total_free_pages: u64,
    total_alloced_pages: u64,
}

static PMM: Mutex<PmmState> = Mutex::new(PmmState {
    page_meta: [PageMeta {
        state: PageState::Free,
        refcount: 0,
    }; MAX_PAGES],
    base_pfn: 0,
    max_pfn: 0,
    free_head: None,
    total_free_pages: 0,
    total_alloced_pages: 0,
});

#[inline(always)]
fn pa_to_meta_index(base_pfn: u64, max_pfn: u64, pa: u64) -> Option<usize> {
    let pfn = pa_to_pfn(pa);
    if pfn >= base_pfn {
        let idx = (pfn - base_pfn) as usize;
        if idx < (max_pfn as usize) && idx < MAX_PAGES {
            return Some(idx);
        }
    }
    None
}

#[inline(always)]
fn pa_to_pfn(pa: u64) -> u64 {
    pa / PAGE_SIZE
}

#[derive(Clone, Copy, Debug)]
pub struct MemoryRegion {
    pub base: u64,
    pub size: u64,
}

#[derive(Clone, Copy, Debug)]
pub struct PageSlice {
    pub base: u64,
    pub count: u64,
}

pub fn init(regions: &[MemoryRegion]) {
    let mut pmm = PMM.lock();
    let mut min_pfn = u64::MAX;
    let mut max_pfn = 0u64;
    for r in regions {
        let start = r.base;
        let end = r.base + r.size;
        let aligned_start = (start + PAGE_SIZE - 1) & !(PAGE_SIZE - 1);
        let aligned_end = end & !(PAGE_SIZE - 1);
        if aligned_start >= aligned_end {
            continue;
        }
        let start_pfn = pa_to_pfn(aligned_start);
        let end_pfn = pa_to_pfn(aligned_end);
        if start_pfn < min_pfn {
            min_pfn = start_pfn;
        }
        if end_pfn > max_pfn {
            max_pfn = end_pfn;
        }
    }

    if min_pfn != u64::MAX {
        pmm.base_pfn = min_pfn;
        let count = (max_pfn - min_pfn).min(MAX_PAGES as u64);
        pmm.max_pfn = count;
    }

    for i in 0..pmm.max_pfn as usize {
        pmm.page_meta[i] = PageMeta {
            state: PageState::Free,
            refcount: 0,
        };
    }
    for r in regions {
        let start = r.base;
        let end = r.base + r.size;
        let aligned_start = (start + PAGE_SIZE - 1) & !(PAGE_SIZE - 1);
        let aligned_end = end & !(PAGE_SIZE - 1);
        if aligned_start >= aligned_end {
            continue;
        }

        mmu::map_extra(
            aligned_start,
            aligned_end - aligned_start,
            mmu::Prot {
                writable: true,
                executable: false,
                user: false,
                device: false,
            },
        );

        let mut page = aligned_end - PAGE_SIZE;
        while page >= aligned_start {
            let ptr = page as *mut Option<u64>;
            unsafe {
                *ptr = pmm.free_head;
            }
            pmm.free_head = Some(page);
            pmm.total_free_pages += 1;
            if page < PAGE_SIZE {
                break;
            }
            page -= PAGE_SIZE;
        }
    }
}

pub fn alloc_page() -> u64 {
    alloc_page_internal(true)
}

pub fn alloc_page_uninit() -> u64 {
    alloc_page_internal(false)
}

fn alloc_page_internal(zero: bool) -> u64 {
    let mut pmm = PMM.lock();
    let page = pmm.free_head.expect("pmm: out of memory");
    let next_ptr = page as *const Option<u64>;
    pmm.free_head = unsafe { *next_ptr };
    pmm.total_free_pages -= 1;
    pmm.total_alloced_pages += 1;

    if let Some(idx) = pa_to_meta_index(pmm.base_pfn, pmm.max_pfn, page) {
        pmm.page_meta[idx].state = PageState::Allocated;
        pmm.page_meta[idx].refcount = 1;
    }

    if zero {
        let ptr = page as *mut u8;
        unsafe {
            core::ptr::write_bytes(ptr, 0, PAGE_SIZE as usize);
        }
    }
    page
}

pub fn alloc_pages(count: u64) -> PageSlice {
    assert!(count > 0, "pmm: zero-page allocation");
    let base = alloc_pages_contig(count);
    if base == 0 {
        panic!("pmm: out of memory");
    }
    PageSlice { base, count }
}

pub fn alloc_pages_contig(count: u64) -> u64 {
    if count == 0 {
        panic!("pmm: zero-page allocation");
    }
    if count == 1 {
        return alloc_page();
    }

    let mut pmm = PMM.lock();
    let mut candidate = 0u64;
    let mut candidate_prev = None;
    let mut current_prev = None;
    let mut run = 0u64;
    let mut cur = pmm.free_head;
    while let Some(page) = cur {
        if candidate != 0 && page == candidate + run * PAGE_SIZE {
            run += 1;
            if run == count {
                break;
            }
        } else {
            candidate = page;
            candidate_prev = current_prev;
            run = 1;
        }
        let next_ptr = page as *const Option<u64>;
        current_prev = Some(page);
        cur = unsafe { *next_ptr };
    }

    if run < count {
        return 0;
    }

    let last_page = candidate + (count - 1) * PAGE_SIZE;
    let after_run = unsafe { *(last_page as *const Option<u64>) };
    if let Some(prev) = candidate_prev {
        unsafe {
            *(prev as *mut Option<u64>) = after_run;
        }
    } else {
        pmm.free_head = after_run;
    }

    pmm.total_free_pages -= count;
    pmm.total_alloced_pages += count;

    for i in 0..count {
        let target = candidate + i * PAGE_SIZE;
        if let Some(idx) = pa_to_meta_index(pmm.base_pfn, pmm.max_pfn, target) {
            pmm.page_meta[idx].state = PageState::Allocated;
            pmm.page_meta[idx].refcount = 1;
        }
    }

    let ptr = candidate as *mut u8;
    unsafe {
        core::ptr::write_bytes(ptr, 0, (count * PAGE_SIZE) as usize);
    }

    candidate
}

fn remove_page_from_list(pmm: &mut PmmState, target: u64) {
    if pmm.free_head == Some(target) {
        let next_ptr = target as *const Option<u64>;
        pmm.free_head = unsafe { *next_ptr };
        return;
    }

    let mut prev = pmm.free_head.expect("pmm: corrupted free list");
    loop {
        let prev_next_ptr = prev as *mut Option<u64>;
        if unsafe { *prev_next_ptr } == Some(target) {
            let target_next = unsafe { *(target as *const Option<u64>) };
            unsafe {
                *prev_next_ptr = target_next;
            }
            return;
        }
        prev = unsafe { (*prev_next_ptr).expect("pmm: target not found in free list") };
    }
}

pub fn free_page(pa: u64) {
    let mut pmm = PMM.lock();
    if let Some(idx) = pa_to_meta_index(pmm.base_pfn, pmm.max_pfn, pa) {
        pmm.page_meta[idx].state = PageState::Free;
        pmm.page_meta[idx].refcount = 0;
    }

    let ptr = pa as *mut Option<u64>;
    unsafe {
        *ptr = pmm.free_head;
    }
    pmm.free_head = Some(pa);
    pmm.total_free_pages += 1;
    if pmm.total_alloced_pages > 0 {
        pmm.total_alloced_pages -= 1;
    }
}

pub fn free_pages(base: u64, count: u64) {
    for i in 0..count {
        free_page(base + i * PAGE_SIZE);
    }
}

pub fn retain_page(pa: u64) -> u8 {
    let mut pmm = PMM.lock();
    if let Some(idx) = pa_to_meta_index(pmm.base_pfn, pmm.max_pfn, pa) {
        let next = pmm.page_meta[idx].refcount.saturating_add(1);
        pmm.page_meta[idx].refcount = next;
        if next > 1 {
            pmm.page_meta[idx].state = PageState::Shared;
        }
        next
    } else {
        1
    }
}

pub fn release_page(pa: u64) -> bool {
    let mut pmm = PMM.lock();
    if let Some(idx) = pa_to_meta_index(pmm.base_pfn, pmm.max_pfn, pa) {
        if pmm.page_meta[idx].refcount > 1 {
            pmm.page_meta[idx].refcount -= 1;
            if pmm.page_meta[idx].refcount == 1 {
                pmm.page_meta[idx].state = PageState::Allocated;
            }
            false
        } else {
            pmm.page_meta[idx].state = PageState::Free;
            pmm.page_meta[idx].refcount = 0;
            let ptr = pa as *mut Option<u64>;
            unsafe {
                *ptr = pmm.free_head;
            }
            pmm.free_head = Some(pa);
            pmm.total_free_pages += 1;
            if pmm.total_alloced_pages > 0 {
                pmm.total_alloced_pages -= 1;
            }
            true
        }
    } else {
        false
    }
}

pub fn get_refcount(pa: u64) -> u8 {
    let pmm = PMM.lock();
    if let Some(idx) = pa_to_meta_index(pmm.base_pfn, pmm.max_pfn, pa) {
        pmm.page_meta[idx].refcount
    } else {
        0
    }
}

pub fn is_shared(pa: u64) -> bool {
    get_refcount(pa) > 1
}

pub fn total_free() -> u64 {
    PMM.lock().total_free_pages
}

pub fn total_allocated() -> u64 {
    PMM.lock().total_alloced_pages
}
