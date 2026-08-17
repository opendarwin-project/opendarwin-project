//! Slab allocator for fixed-size small kernel allocations.

use crate::mm::pmm;
use spin::Mutex;

const PAGE_SIZE: usize = 4096;
const HEADER_SIZE: usize = 16; // [0] = zone_index, [1] = next_page

#[derive(Clone, Copy)]
struct Zone {
    obj_size: usize,
    free_list: *mut u8,
    page_list: u64,
}

unsafe impl Send for Zone {}
unsafe impl Sync for Zone {}

impl Zone {
    const fn new(size: usize) -> Self {
        Self {
            obj_size: size,
            free_list: core::ptr::null_mut(),
            page_list: 0,
        }
    }
}

const ZONE_SIZES: [usize; 10] = [8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096];
static ZONES: Mutex<[Zone; 10]> = Mutex::new([
    Zone::new(8),
    Zone::new(16),
    Zone::new(32),
    Zone::new(64),
    Zone::new(128),
    Zone::new(256),
    Zone::new(512),
    Zone::new(1024),
    Zone::new(2048),
    Zone::new(4096),
]);

fn zone_index(size: usize) -> Option<usize> {
    for (i, &zs) in ZONE_SIZES.iter().enumerate() {
        if size <= zs {
            return Some(i);
        }
    }
    None
}

pub fn init() {
    let mut zones = ZONES.lock();
    for (i, &zs) in ZONE_SIZES.iter().enumerate() {
        zones[i] = Zone::new(zs);
    }
}

fn add_page(zones: &mut [Zone; 10], zone_idx: usize) {
    let zone = &mut zones[zone_idx];
    let pa = pmm::alloc_page_uninit();
    let hdr = pa as *mut u64;
    unsafe {
        *hdr = zone_idx as u64;
        *hdr.add(1) = zone.page_list;
    }
    zone.page_list = pa;

    let obj_start = pa as usize + HEADER_SIZE;
    let obj_size = zone.obj_size;
    let mut off = 0;
    while off + obj_size <= PAGE_SIZE - HEADER_SIZE {
        let obj_ptr = (obj_start + off) as *mut *mut u8;
        unsafe {
            *obj_ptr = zone.free_list;
        }
        zone.free_list = (obj_start + off) as *mut u8;
        off += obj_size;
    }
}

pub fn alloc(size: usize) -> *mut u8 {
    let idx = zone_index(size).expect("slab: allocation too large");
    let mut zones = ZONES.lock();
    if zones[idx].free_list.is_null() {
        add_page(&mut zones, idx);
    }
    let ptr = zones[idx].free_list;
    let next = unsafe { *(ptr as *const *mut u8) };
    zones[idx].free_list = next;
    ptr
}

pub fn allocz(size: usize) -> *mut u8 {
    let ptr = alloc(size);
    unsafe {
        core::ptr::write_bytes(ptr, 0, size);
    }
    ptr
}

pub fn alloc_obj<T>() -> *mut T {
    allocz(core::mem::size_of::<T>()) as *mut T
}

pub fn free(ptr: *mut u8) {
    if ptr.is_null() {
        return;
    }
    let addr = ptr as usize;
    let page_base = addr & !(PAGE_SIZE - 1);
    let hdr = page_base as *const u64;
    let zone_idx = unsafe { *hdr } as usize;

    let mut zones = ZONES.lock();
    let free_ptr = ptr as *mut *mut u8;
    unsafe {
        *free_ptr = zones[zone_idx].free_list;
    }
    zones[zone_idx].free_list = ptr;
}
