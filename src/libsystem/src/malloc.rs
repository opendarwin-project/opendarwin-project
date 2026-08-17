//! Memory allocation: malloc, calloc, realloc, free, malloc_size,
//! posix_memalign, bzero, arc4random_buf.

use core::ffi::{c_int, c_uint, c_void};

use crate::common;

#[repr(C)]
struct MallocHeader {
    magic: usize,
    requested: usize,
    total: usize,
}

const MALLOC_MAGIC: usize = 0x4f44574d414c4c4f; // ODW MALLO
const MALLOC_ALIGN: usize = 16;

unsafe fn mallocHeader(ptr: *mut c_void) -> Option<*mut MallocHeader> {
    if ptr.is_null() {
        return None;
    }
    let addr = ptr as usize;
    if addr < core::mem::size_of::<MallocHeader>() {
        return None;
    }
    let header = (addr - core::mem::size_of::<MallocHeader>()) as *mut MallocHeader;
    if (*header).magic != MALLOC_MAGIC {
        return None;
    }
    Some(header)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn malloc(size: usize) -> *mut c_void {
    let requested = if size == 0 { 1 } else { size };
    let header_size = core::mem::size_of::<MallocHeader>();
    let payload_off = (header_size + (MALLOC_ALIGN - 1)) & !(MALLOC_ALIGN - 1);
    let total = (payload_off + requested + 4095) & !4095;
    let base = crate::mach::mmap(
        core::ptr::null_mut(),
        total,
        common::VM_PROT_READ_WRITE,
        common::MAP_PRIVATE_ANON,
        -1,
        0,
    );
    if base.is_null() || base as usize == common::usize_max {
        return core::ptr::null_mut();
    }
    let header = base as *mut MallocHeader;
    *header = MallocHeader {
        magic: MALLOC_MAGIC,
        requested,
        total,
    };
    (base as usize + payload_off) as *mut c_void
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn realloc(ptr: *mut c_void, size: usize) -> *mut c_void {
    if ptr.is_null() {
        return malloc(size);
    }
    if size == 0 {
        free(ptr);
        return core::ptr::null_mut();
    }
    let old_size = malloc_size(ptr);
    let next = malloc(size);
    if next.is_null() {
        return core::ptr::null_mut();
    }
    let n = if old_size < size { old_size } else { size };
    core::ptr::copy_nonoverlapping(ptr as *const u8, next as *mut u8, n);
    free(ptr);
    next
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn free(ptr: *mut c_void) {
    if let Some(header) = mallocHeader(ptr) {
        let _ = crate::mach::munmap(header as *mut c_void, (*header).total);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn malloc_size(ptr: *mut c_void) -> usize {
    if let Some(header) = mallocHeader(ptr) {
        (*header).requested
    } else {
        0
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn calloc(nmemb: usize, size: usize) -> *mut c_void {
    if nmemb == 0 || size == 0 {
        return core::ptr::null_mut();
    }
    let total = match nmemb.checked_mul(size) {
        Some(t) => t,
        None => {
            common::errno = common::ENOMEM;
            return core::ptr::null_mut();
        }
    };
    let ptr = malloc(total);
    if ptr.is_null() {
        return core::ptr::null_mut();
    }
    core::ptr::write_bytes(ptr as *mut u8, 0, total);
    ptr
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn posix_memalign(
    _memptr: *mut *mut c_void,
    _alignment: usize,
    _size: usize,
) -> c_int {
    common::stubErr("posix_memalign")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn bzero(ptr: *mut u8, len: usize) {
    let out = ptr as *mut core::ffi::c_uchar;
    for i in 0..len {
        core::ptr::write_volatile(out.add(i), 0);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn arc4random_buf(ptr: *mut u8, len: usize) {
    // Deterministic milestone entropy until the kernel exposes a CSPRNG.
    let out = ptr as *mut core::ffi::c_uchar;
    for i in 0..len {
        core::ptr::write_volatile(out.add(i), 0);
    }
}

// ── malloc_zone API ────────────────────────────────────────────────────

#[repr(C)]
pub struct MallocZone {
    pub reserved: *mut c_void,
    pub size: unsafe extern "C" fn(*mut MallocZone, *const c_void) -> usize,
    pub malloc: unsafe extern "C" fn(*mut MallocZone, usize) -> *mut c_void,
    pub calloc: unsafe extern "C" fn(*mut MallocZone, usize, usize) -> *mut c_void,
    pub valloc: unsafe extern "C" fn(*mut MallocZone, usize) -> *mut c_void,
    pub free: unsafe extern "C" fn(*mut MallocZone, *mut c_void),
    pub realloc: unsafe extern "C" fn(*mut MallocZone, *mut c_void, usize) -> *mut c_void,
    pub memalign: unsafe extern "C" fn(*mut MallocZone, usize, usize) -> *mut c_void,
}

unsafe extern "C" fn zone_size_wrapper(_zone: *mut MallocZone, ptr: *const c_void) -> usize {
    malloc_size(ptr as *mut c_void)
}

unsafe extern "C" fn zone_malloc_wrapper(_zone: *mut MallocZone, size: usize) -> *mut c_void {
    malloc(size)
}

unsafe extern "C" fn zone_calloc_wrapper(
    _zone: *mut MallocZone,
    count: usize,
    size: usize,
) -> *mut c_void {
    calloc(count, size)
}

unsafe extern "C" fn zone_valloc_wrapper(_zone: *mut MallocZone, _size: usize) -> *mut c_void {
    core::ptr::null_mut()
}

unsafe extern "C" fn zone_free_wrapper(_zone: *mut MallocZone, ptr: *mut c_void) {
    free(ptr);
}

unsafe extern "C" fn zone_realloc_wrapper(
    _zone: *mut MallocZone,
    ptr: *mut c_void,
    size: usize,
) -> *mut c_void {
    realloc(ptr, size)
}

unsafe extern "C" fn zone_memalign_wrapper(
    _zone: *mut MallocZone,
    _alignment: usize,
    _size: usize,
) -> *mut c_void {
    core::ptr::null_mut()
}

static mut DEFAULT_MALLOC_ZONE: MallocZone = MallocZone {
    reserved: core::ptr::null_mut(),
    size: zone_size_wrapper,
    malloc: zone_malloc_wrapper,
    calloc: zone_calloc_wrapper,
    valloc: zone_valloc_wrapper,
    free: zone_free_wrapper,
    realloc: zone_realloc_wrapper,
    memalign: zone_memalign_wrapper,
};

#[unsafe(no_mangle)]
pub unsafe extern "C" fn malloc_default_zone() -> *mut MallocZone {
    &raw mut DEFAULT_MALLOC_ZONE
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn malloc_good_size(size: usize) -> usize {
    (size + 15) & !15
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn malloc_zone_free(_zone: *mut MallocZone, ptr: *mut c_void) {
    free(ptr);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn malloc_zone_malloc(_zone: *mut MallocZone, size: usize) -> *mut c_void {
    malloc(size)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn malloc_zone_memalign(
    _zone: *mut MallocZone,
    _alignment: usize,
    _size: usize,
) -> *mut c_void {
    core::ptr::null_mut()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn malloc_zone_realloc(
    _zone: *mut MallocZone,
    ptr: *mut c_void,
    size: usize,
) -> *mut c_void {
    realloc(ptr, size)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn vm_page_size() -> usize {
    4096
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn vm_purgable_control(
    _target: c_uint,
    _control: c_int,
    _state: *mut c_int,
) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mach_vm_allocate(
    _target: c_uint,
    addr: *mut u64,
    size: u64,
    _flags: c_int,
) -> c_int {
    let ptr = crate::mach::mmap(core::ptr::null_mut(), size as usize, 3, 0x4002, -1, 0);
    if ptr as usize == common::usize_max {
        return 3; // KERN_FAILURE
    }
    *addr = ptr as u64;
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mach_vm_deallocate(_target: c_uint, _addr: u64, _size: u64) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mach_vm_region(
    _target: c_uint,
    _address: *mut u64,
    _size: *mut u64,
    _flavor: c_int,
    _info: *mut c_int,
    _count: *mut c_int,
) -> c_int {
    1 // KERN_FAILURE
}
