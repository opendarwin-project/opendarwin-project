//! Virtual Memory Manager (VMM) and per-process address spaces.

use crate::mm::mmu;
use crate::mm::pmm;
use spin::Mutex;

pub const PAGE_SIZE: u64 = mmu::PAGE_SIZE;
pub const MAX_REGIONS: usize = 128;
pub const MMAP_BASE: u64 = 0x2_0000_0000;

pub const KERN_SUCCESS: u32 = 0;
pub const KERN_INVALID_ADDRESS: u32 = 1;
pub const KERN_NO_SPACE: u32 = 3;
pub const KERN_INVALID_ARGUMENT: u32 = 4;
pub const KERN_NOT_SUPPORTED: u32 = 46;

pub const VM_PROT_NONE: u32 = 0;
pub const VM_PROT_READ: u32 = 1;
pub const VM_PROT_WRITE: u32 = 2;
pub const VM_PROT_EXECUTE: u32 = 4;
pub const VM_PROT_ALL: u32 = 7;

pub const VM_FLAGS_ANYWHERE: u32 = 1;
pub const VM_FLAGS_OVERWRITE: u32 = 0x4000;

pub const VM_FLAG_COW: u32 = 0x100;
pub const VM_FLAG_SHARED: u32 = 0x200;

const MAX_SHARED_REGIONS: usize = 64;
const MAX_NAME_LEN: usize = 64;

#[derive(Clone, Copy)]
pub struct SharedRegion {
    pub name: [u8; MAX_NAME_LEN],
    pub name_len: usize,
    pub physical_pages: Option<u64>,
    pub page_count: u64,
    pub ref_count: u32,
    pub in_use: bool,
}

impl SharedRegion {
    pub const fn empty() -> Self {
        Self {
            name: [0; MAX_NAME_LEN],
            name_len: 0,
            physical_pages: None,
            page_count: 0,
            ref_count: 0,
            in_use: false,
        }
    }
}

static SHARED_REGIONS: Mutex<[SharedRegion; MAX_SHARED_REGIONS]> =
    Mutex::new([const { SharedRegion::empty() }; MAX_SHARED_REGIONS]);

pub fn shm_open(name: &str, page_count: u64) -> Option<(u64, u64)> {
    if name.len() >= MAX_NAME_LEN || name.is_empty() {
        return None;
    }

    let mut regions = SHARED_REGIONS.lock();
    for sr in regions.iter_mut() {
        if sr.in_use && sr.name_len == name.len() && &sr.name[..sr.name_len] == name.as_bytes() {
            sr.ref_count += 1;
            return Some((sr.physical_pages.unwrap(), sr.page_count));
        }
    }

    for sr in regions.iter_mut() {
        if !sr.in_use {
            let pages = pmm::alloc_pages(page_count);
            sr.name[..name.len()].copy_from_slice(name.as_bytes());
            sr.name_len = name.len();
            sr.physical_pages = Some(pages.base);
            sr.page_count = page_count;
            sr.ref_count = 1;
            sr.in_use = true;
            return Some((pages.base, page_count));
        }
    }
    None
}

pub fn shm_close(name: &str) {
    let mut regions = SHARED_REGIONS.lock();
    for sr in regions.iter_mut() {
        if sr.in_use && sr.name_len == name.len() && &sr.name[..sr.name_len] == name.as_bytes() {
            sr.ref_count -= 1;
            if sr.ref_count == 0 {
                if let Some(pa) = sr.physical_pages {
                    pmm::free_pages(pa, sr.page_count);
                }
                sr.in_use = false;
                sr.physical_pages = None;
                sr.page_count = 0;
            }
            return;
        }
    }
}

pub fn shm_info(name: &str) -> Option<(u64, u64, u32)> {
    let regions = SHARED_REGIONS.lock();
    for sr in regions.iter() {
        if sr.in_use && sr.name_len == name.len() && &sr.name[..sr.name_len] == name.as_bytes() {
            return Some((sr.physical_pages.unwrap(), sr.page_count, sr.ref_count));
        }
    }
    None
}

#[derive(Clone, Copy)]
pub struct Vma {
    pub start: u64,
    pub end: u64,
    pub prot: mmu::Prot,
    pub flags: u32,
    pub shared_name_len: u16,
    pub shared_name: [u8; MAX_NAME_LEN],
}

impl Default for Vma {
    fn default() -> Self {
        Self {
            start: 0,
            end: 0,
            prot: mmu::Prot::default(),
            flags: 0,
            shared_name_len: 0,
            shared_name: [0; MAX_NAME_LEN],
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct MachMapResult {
    pub kr: u32,
    pub addr: u64,
}

pub struct Vmm {
    pub ttbr0: *mut mmu::Table,
    pub regions: [Vma; MAX_REGIONS],
    pub region_count: usize,
    pub brk_start: u64,
    pub brk_current: u64,
    pub next_mmap_hint: u64,
}

impl Vmm {
    pub const fn init(ttbr0: *mut mmu::Table) -> Self {
        Self {
            ttbr0,
            regions: [Vma {
                start: 0,
                end: 0,
                prot: mmu::Prot {
                    writable: false,
                    executable: false,
                    user: false,
                    device: false,
                },
                flags: 0,
                shared_name_len: 0,
                shared_name: [0; MAX_NAME_LEN],
            }; MAX_REGIONS],
            region_count: 0,
            brk_start: 0,
            brk_current: 0,
            next_mmap_hint: MMAP_BASE,
        }
    }

    pub fn add_region(&mut self, start: u64, end: u64, prot: mmu::Prot, flags: u32) {
        if self.region_count >= MAX_REGIONS {
            panic!("vmm: too many regions");
        }
        self.regions[self.region_count] = Vma {
            start,
            end,
            prot,
            flags,
            shared_name_len: 0,
            shared_name: [0; MAX_NAME_LEN],
        };
        self.region_count += 1;
    }

    fn add_region_checked(&mut self, start: u64, end: u64, prot: mmu::Prot, flags: u32) -> bool {
        if self.region_count >= MAX_REGIONS {
            return false;
        }
        self.regions[self.region_count] = Vma {
            start,
            end,
            prot,
            flags,
            shared_name_len: 0,
            shared_name: [0; MAX_NAME_LEN],
        };
        self.region_count += 1;
        true
    }

    fn page_round(len: u64) -> Option<u64> {
        let with_slop = len.checked_add(PAGE_SIZE - 1)?;
        Some(with_slop & !(PAGE_SIZE - 1))
    }

    fn range_overlaps(&self, start: u64, len: u64) -> bool {
        let Some(end) = start.checked_add(len) else {
            return true;
        };
        for r in &self.regions[..self.region_count] {
            if start < r.end && end > r.start {
                return true;
            }
        }
        false
    }

    fn find_free_range(&mut self, len: u64) -> u64 {
        let Some(aligned_len) = Self::page_round(len) else {
            return 0;
        };
        let mut candidate = self.next_mmap_hint;
        for _ in 0..1024 {
            let mut ok = true;
            for r in &self.regions[..self.region_count] {
                let Some(end) = candidate.checked_add(aligned_len) else {
                    return 0;
                };
                if candidate < r.end && end > r.start {
                    candidate = r.end;
                    ok = false;
                    break;
                }
            }
            if ok {
                self.next_mmap_hint = candidate.wrapping_add(aligned_len);
                return candidate;
            }
        }
        0
    }

    fn map_anonymous(&mut self, addr: u64, len: u64, prot: mmu::Prot, flags: u32) -> u32 {
        if self.region_count >= MAX_REGIONS {
            return KERN_NO_SPACE;
        }
        let mut mapped = 0;
        while mapped < len {
            let pa = pmm::alloc_page();
            unsafe {
                mmu::map_pages(&mut *self.ttbr0, addr + mapped, pa, PAGE_SIZE, prot);
            }
            mapped += PAGE_SIZE;
        }
        if !self.add_region_checked(addr, addr + len, prot, flags) {
            return KERN_NO_SPACE;
        }
        KERN_SUCCESS
    }

    pub fn mach_allocate(&mut self, requested_addr: u64, size: u64, flags: u32) -> MachMapResult {
        if size == 0 {
            return MachMapResult {
                kr: KERN_SUCCESS,
                addr: 0,
            };
        }
        let user_flags = flags & 0x00ff_ffff;
        if (user_flags & !VM_FLAGS_ANYWHERE) != 0 {
            return MachMapResult {
                kr: KERN_INVALID_ARGUMENT,
                addr: requested_addr,
            };
        }
        let Some(aligned_len) = Self::page_round(size) else {
            return MachMapResult {
                kr: KERN_INVALID_ARGUMENT,
                addr: requested_addr,
            };
        };

        let va = if (flags & VM_FLAGS_ANYWHERE) != 0 {
            let found = self.find_free_range(aligned_len);
            if found == 0 {
                return MachMapResult {
                    kr: KERN_NO_SPACE,
                    addr: requested_addr,
                };
            }
            found
        } else {
            let fixed = requested_addr & !(PAGE_SIZE - 1);
            if fixed == 0 || self.range_overlaps(fixed, aligned_len) {
                return MachMapResult {
                    kr: KERN_NO_SPACE,
                    addr: requested_addr,
                };
            }
            fixed
        };

        let prot = mmu::Prot {
            writable: true,
            executable: false,
            user: true,
            device: false,
        };
        MachMapResult {
            kr: self.map_anonymous(va, aligned_len, prot, flags),
            addr: va,
        }
    }

    pub fn mach_map(
        &mut self,
        requested_addr: u64,
        size: u64,
        mask: u64,
        flags: u32,
        cur_protection: u32,
    ) -> MachMapResult {
        if size == 0 {
            return MachMapResult {
                kr: KERN_INVALID_ARGUMENT,
                addr: requested_addr,
            };
        }
        if mask != 0 {
            return MachMapResult {
                kr: KERN_NOT_SUPPORTED,
                addr: requested_addr,
            };
        }
        if (cur_protection & !VM_PROT_ALL) != 0 {
            return MachMapResult {
                kr: KERN_INVALID_ARGUMENT,
                addr: requested_addr,
            };
        }
        let user_flags = flags & 0x00ff_ffff;
        if (user_flags & !(VM_FLAGS_ANYWHERE | VM_FLAGS_OVERWRITE)) != 0 {
            return MachMapResult {
                kr: KERN_INVALID_ARGUMENT,
                addr: requested_addr,
            };
        }
        if (user_flags & VM_FLAGS_OVERWRITE) != 0 {
            return MachMapResult {
                kr: KERN_NOT_SUPPORTED,
                addr: requested_addr,
            };
        }
        let Some(aligned_len) = Self::page_round(size) else {
            return MachMapResult {
                kr: KERN_INVALID_ARGUMENT,
                addr: requested_addr,
            };
        };

        let va = if (flags & VM_FLAGS_ANYWHERE) != 0 {
            let found = self.find_free_range(aligned_len);
            if found == 0 {
                return MachMapResult {
                    kr: KERN_NO_SPACE,
                    addr: requested_addr,
                };
            }
            found
        } else {
            let fixed = requested_addr & !(PAGE_SIZE - 1);
            if fixed == 0 || self.range_overlaps(fixed, aligned_len) {
                return MachMapResult {
                    kr: KERN_NO_SPACE,
                    addr: requested_addr,
                };
            }
            fixed
        };

        let prot = mmu::Prot {
            writable: (cur_protection & VM_PROT_WRITE) != 0,
            executable: (cur_protection & VM_PROT_EXECUTE) != 0,
            user: true,
            device: false,
        };
        MachMapResult {
            kr: self.map_anonymous(va, aligned_len, prot, flags),
            addr: va,
        }
    }

    pub fn map_physical(&mut self, pa: u64, len: u64) -> u64 {
        let Some(aligned_len) = Self::page_round(len) else {
            return 0;
        };
        let page_count = aligned_len / PAGE_SIZE;
        let va = self.find_free_range(aligned_len);
        if va == 0 {
            return 0;
        }
        let prot = mmu::Prot {
            writable: true,
            executable: false,
            user: true,
            device: false,
        };
        if self.map_shared(va, pa, page_count, prot, "od-fb") != KERN_SUCCESS {
            return 0;
        }
        va
    }

    pub fn mmap(&mut self, hint: u64, len: u64, prot_val: i32, flags: i32) -> u64 {
        let Some(aligned_len) = Self::page_round(len) else {
            return !0u64;
        };
        let mut va = if hint != 0 && hint % PAGE_SIZE == 0 {
            hint
        } else {
            0
        };
        if va != 0 && self.range_overlaps(va, aligned_len) {
            return !0u64;
        }
        if va == 0 {
            va = self.find_free_range(aligned_len);
            if va == 0 {
                return !0u64;
            }
        }
        let map_prot = mmu::Prot {
            writable: (prot_val & 2) != 0,
            executable: (prot_val & 4) != 0,
            user: true,
            device: false,
        };
        if self.map_anonymous(va, aligned_len, map_prot, flags as u32) == KERN_SUCCESS {
            va
        } else {
            !0u64
        }
    }

    pub fn munmap(&mut self, addr: u64, len: u64) -> i32 {
        let Some(aligned_len) = Self::page_round(len) else {
            return -22;
        };
        if addr % PAGE_SIZE != 0 {
            return -22;
        }

        let mut i = 0;
        while i < self.region_count {
            let r = &self.regions[i];
            if addr >= r.start && addr + aligned_len <= r.end {
                let mut page_va = addr;
                while page_va < addr + aligned_len {
                    unsafe {
                        if let Some(pa) = mmu::get_physical_address(&*self.ttbr0, page_va) {
                            mmu::unmap_page_no_free(&mut *self.ttbr0, page_va);
                            pmm::release_page(pa);
                        }
                    }
                    page_va += PAGE_SIZE;
                }
                return 0;
            }
            i += 1;
        }
        0
    }

    pub fn mprotect(&mut self, addr: u64, len: u64, prot_val: i32) -> i32 {
        let Some(aligned_len) = Self::page_round(len) else {
            return -22;
        };
        if addr % PAGE_SIZE != 0 {
            return -22;
        }

        let new_prot = mmu::Prot {
            writable: (prot_val & 2) != 0,
            executable: (prot_val & 4) != 0,
            user: true,
            device: false,
        };

        for r in &mut self.regions[..self.region_count] {
            if addr >= r.start && addr + aligned_len <= r.end {
                r.prot = new_prot;
                let mut page_va = addr;
                while page_va < addr + aligned_len {
                    unsafe {
                        if let Some(pa) = mmu::get_physical_address(&*self.ttbr0, page_va) {
                            mmu::map_pages(&mut *self.ttbr0, page_va, pa, PAGE_SIZE, new_prot);
                        }
                    }
                    page_va += PAGE_SIZE;
                }
                return 0;
            }
        }
        -22
    }

    pub fn map_shared(
        &mut self,
        va: u64,
        pa: u64,
        page_count: u64,
        prot: mmu::Prot,
        name: &str,
    ) -> u32 {
        if self.region_count >= MAX_REGIONS {
            return KERN_NO_SPACE;
        }

        for i in 0..page_count {
            unsafe {
                mmu::map_pages(
                    &mut *self.ttbr0,
                    va + i * PAGE_SIZE,
                    pa + i * PAGE_SIZE,
                    PAGE_SIZE,
                    prot,
                );
            }
        }

        let mut region = Vma {
            start: va,
            end: va + page_count * PAGE_SIZE,
            prot,
            flags: VM_FLAG_SHARED,
            shared_name_len: 0,
            shared_name: [0; MAX_NAME_LEN],
        };
        if name.len() < MAX_NAME_LEN {
            region.shared_name[..name.len()].copy_from_slice(name.as_bytes());
            region.shared_name_len = name.len() as u16;
        }
        self.regions[self.region_count] = region;
        self.region_count += 1;

        KERN_SUCCESS
    }

    pub fn unmap_shared(&mut self, name: &str) {
        let mut i = 0;
        while i < self.region_count {
            let r = &self.regions[i];
            if (r.flags & VM_FLAG_SHARED) != 0
                && r.shared_name_len as usize == name.len()
                && &r.shared_name[..name.len()] == name.as_bytes()
            {
                let mut va = r.start;
                while va < r.end {
                    unsafe {
                        mmu::unmap_page_no_free(&mut *self.ttbr0, va);
                    }
                    va += PAGE_SIZE;
                }
                self.regions.copy_within(i + 1..self.region_count, i);
                self.region_count -= 1;
            } else {
                i += 1;
            }
        }
    }

    pub fn handle_cow_fault(&mut self, far: u64) -> bool {
        let fault_va = far & !(PAGE_SIZE - 1);
        let mut is_cow = false;
        let mut prot = mmu::Prot::default();

        for r in &self.regions[..self.region_count] {
            if fault_va >= r.start && fault_va < r.end && (r.flags & VM_FLAG_COW) != 0 {
                is_cow = true;
                prot = r.prot;
                break;
            }
        }

        if !is_cow {
            return false;
        }

        unsafe {
            let Some(old_pa) = mmu::get_physical_address(&*self.ttbr0, fault_va) else {
                return false;
            };
            if pmm::get_refcount(old_pa) <= 1 {
                let mut writable_prot = prot;
                writable_prot.writable = true;
                mmu::map_pages(&mut *self.ttbr0, fault_va, old_pa, PAGE_SIZE, writable_prot);
                return true;
            }

            let new_pa = pmm::alloc_page();
            let src = old_pa as *const u8;
            let dst = new_pa as *mut u8;
            core::ptr::copy_nonoverlapping(src, dst, PAGE_SIZE as usize);

            pmm::release_page(old_pa);

            let mut writable_prot = prot;
            writable_prot.writable = true;
            mmu::map_pages(&mut *self.ttbr0, fault_va, new_pa, PAGE_SIZE, writable_prot);
            true
        }
    }
}
