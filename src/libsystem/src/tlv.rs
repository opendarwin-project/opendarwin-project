//! Thread-local storage (TLV) bootstrap: __tlv_bootstrap.

use core::ffi::c_void;

use crate::common;

#[repr(C)]
pub struct TlvDescriptor {
    pub thunk: usize,
    pub key: usize,
    pub offset: usize,
}

const MAX_TLV_RECORDS: usize = 16;
const MAX_TLV_THREADS: usize = 64;
const TLV_BLOCK_SIZE: usize = 1024 * 1024;

#[derive(Copy, Clone)]
struct TlvRecord {
    template_base: usize,
    storage: [*mut u8; MAX_TLV_THREADS],
}

static mut TLV_RECORDS: [TlvRecord; MAX_TLV_RECORDS] = [TlvRecord {
    template_base: 0,
    storage: [core::ptr::null_mut(); MAX_TLV_THREADS],
}; MAX_TLV_RECORDS];

static mut TLV_RECORD_COUNT: usize = 0;

unsafe fn currentTlvThreadIndex() -> usize {
    let tid = common::darwinSyscall3(common::SYS_thread_selfid, 0, 0, 0);
    if tid == 0 {
        return 0;
    }
    core::cmp::min((tid - 1) as usize, MAX_TLV_THREADS - 1)
}

unsafe fn findOrCreateTlvRecord(template_base: usize) -> *mut TlvRecord {
    let mut i = 0;
    while i < TLV_RECORD_COUNT {
        if TLV_RECORDS[i].template_base == template_base {
            return &raw mut TLV_RECORDS[i];
        }
        i += 1;
    }
    if TLV_RECORD_COUNT >= MAX_TLV_RECORDS {
        return &raw mut TLV_RECORDS[MAX_TLV_RECORDS - 1];
    }
    let rec = &raw mut TLV_RECORDS[TLV_RECORD_COUNT];
    *rec = TlvRecord {
        template_base,
        storage: [core::ptr::null_mut(); MAX_TLV_THREADS],
    };
    TLV_RECORD_COUNT += 1;
    rec
}

unsafe fn tlvStorageFor(record: *mut TlvRecord) -> *mut u8 {
    let idx = currentTlvThreadIndex();
    let storage = (*record).storage[idx];
    if !storage.is_null() {
        return storage;
    }
    let mapped = crate::mach::mmap(
        core::ptr::null_mut(),
        TLV_BLOCK_SIZE,
        common::VM_PROT_READ_WRITE,
        common::MAP_PRIVATE_ANON,
        -1,
        0,
    );
    if mapped.is_null() || mapped as usize == common::usize_max {
        common::reportStub("tlv mmap failed");
        return core::ptr::null_mut();
    }
    let storage = mapped as *mut u8;
    (*record).storage[idx] = storage;
    storage
}

unsafe fn isTlvRecordKey(key: usize) -> bool {
    let start = &raw const TLV_RECORDS as usize;
    let end = start + core::mem::size_of::<[TlvRecord; MAX_TLV_RECORDS]>();
    key >= start && key < end && ((key - start) % core::mem::size_of::<TlvRecord>()) == 0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tlv_bootstrap_impl(desc: *mut TlvDescriptor) -> *mut c_void {
    if (*desc).key == 0 || !isTlvRecordKey((*desc).key) {
        let this_addr = desc as usize;
        let thunk = (*desc).thunk;
        let mut start = this_addr;
        while start >= 24 {
            let prev = (start - 24) as *const TlvDescriptor;
            if (*prev).thunk != thunk || (*prev).offset >= (*(start as *const TlvDescriptor)).offset
            {
                break;
            }
            start -= 24;
        }
        let mut end = start;
        let mut last_offset = 0;
        loop {
            let cur = end as *const TlvDescriptor;
            if (*cur).thunk != thunk || (*cur).offset < last_offset {
                break;
            }
            last_offset = (*cur).offset;
            end += 24;
            if end - start > 4096 {
                break;
            }
        }
        (*desc).key = findOrCreateTlvRecord(end) as usize;
    }
    let record = (*desc).key as *mut TlvRecord;
    let storage = tlvStorageFor(record);
    if storage.is_null() {
        return core::ptr::null_mut();
    }
    (storage as usize + (*desc).offset) as *mut c_void
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn _tlv_bootstrap_impl(desc: *mut TlvDescriptor) -> *mut c_void {
    tlv_bootstrap_impl(desc)
}

#[cfg(all(target_arch = "aarch64", target_os = "macos"))]
core::arch::global_asm!(
    r#"
    .global ___tlv_bootstrap
    .global __tlv_bootstrap
    .global _tlv_bootstrap
    ___tlv_bootstrap:
    __tlv_bootstrap:
    _tlv_bootstrap:
        stp x29, x30, [sp, #-16]!
        mov x29, sp
        stp x1, x2, [sp, #-16]!
        stp x3, x4, [sp, #-16]!
        stp x5, x6, [sp, #-16]!
        stp x7, x8, [sp, #-16]!
        stp x9, x10, [sp, #-16]!
        stp x11, x12, [sp, #-16]!
        stp x13, x14, [sp, #-16]!
        stp x15, x16, [sp, #-16]!
        stp x17, x18, [sp, #-16]!
        stp x19, x20, [sp, #-16]!
        stp x21, x22, [sp, #-16]!
        stp x23, x24, [sp, #-16]!
        stp x25, x26, [sp, #-16]!
        stp x27, x28, [sp, #-16]!
        stp q0, q1, [sp, #-32]!
        stp q2, q3, [sp, #-32]!
        stp q4, q5, [sp, #-32]!
        stp q6, q7, [sp, #-32]!
        stp q8, q9, [sp, #-32]!
        stp q10, q11, [sp, #-32]!
        stp q12, q13, [sp, #-32]!
        stp q14, q15, [sp, #-32]!
        stp q16, q17, [sp, #-32]!
        stp q18, q19, [sp, #-32]!
        stp q20, q21, [sp, #-32]!
        stp q22, q23, [sp, #-32]!
        stp q24, q25, [sp, #-32]!
        stp q26, q27, [sp, #-32]!
        stp q28, q29, [sp, #-32]!
        stp q30, q31, [sp, #-32]!
        bl _tlv_bootstrap_impl
        ldp q30, q31, [sp], #32
        ldp q28, q29, [sp], #32
        ldp q26, q27, [sp], #32
        ldp q24, q25, [sp], #32
        ldp q22, q23, [sp], #32
        ldp q20, q21, [sp], #32
        ldp q18, q19, [sp], #32
        ldp q16, q17, [sp], #32
        ldp q14, q15, [sp], #32
        ldp q12, q13, [sp], #32
        ldp q10, q11, [sp], #32
        ldp q8, q9, [sp], #32
        ldp q6, q7, [sp], #32
        ldp q4, q5, [sp], #32
        ldp q2, q3, [sp], #32
        ldp q0, q1, [sp], #32
        ldp x27, x28, [sp], #16
        ldp x25, x26, [sp], #16
        ldp x23, x24, [sp], #16
        ldp x21, x22, [sp], #16
        ldp x19, x20, [sp], #16
        ldp x17, x18, [sp], #16
        ldp x15, x16, [sp], #16
        ldp x13, x14, [sp], #16
        ldp x11, x12, [sp], #16
        ldp x9, x10, [sp], #16
        ldp x7, x8, [sp], #16
        ldp x5, x6, [sp], #16
        ldp x3, x4, [sp], #16
        ldp x1, x2, [sp], #16
        ldp x29, x30, [sp], #16
        ret
    "#
);

#[cfg(all(target_arch = "aarch64", not(target_os = "macos")))]
core::arch::global_asm!(
    r#"
    .global __tlv_bootstrap
    .global _tlv_bootstrap
    __tlv_bootstrap:
    _tlv_bootstrap:
        stp x29, x30, [sp, #-16]!
        mov x29, sp
        stp x1, x2, [sp, #-16]!
        stp x3, x4, [sp, #-16]!
        stp x5, x6, [sp, #-16]!
        stp x7, x8, [sp, #-16]!
        stp x9, x10, [sp, #-16]!
        stp x11, x12, [sp, #-16]!
        stp x13, x14, [sp, #-16]!
        stp x15, x16, [sp, #-16]!
        stp x17, x18, [sp, #-16]!
        stp x19, x20, [sp, #-16]!
        stp x21, x22, [sp, #-16]!
        stp x23, x24, [sp, #-16]!
        stp x25, x26, [sp, #-16]!
        stp x27, x28, [sp, #-16]!
        stp q0, q1, [sp, #-32]!
        stp q2, q3, [sp, #-32]!
        stp q4, q5, [sp, #-32]!
        stp q6, q7, [sp, #-32]!
        stp q8, q9, [sp, #-32]!
        stp q10, q11, [sp, #-32]!
        stp q12, q13, [sp, #-32]!
        stp q14, q15, [sp, #-32]!
        stp q16, q17, [sp, #-32]!
        stp q18, q19, [sp, #-32]!
        stp q20, q21, [sp, #-32]!
        stp q22, q23, [sp, #-32]!
        stp q24, q25, [sp, #-32]!
        stp q26, q27, [sp, #-32]!
        stp q28, q29, [sp, #-32]!
        stp q30, q31, [sp, #-32]!
        bl tlv_bootstrap_impl
        ldp q30, q31, [sp], #32
        ldp q28, q29, [sp], #32
        ldp q26, q27, [sp], #32
        ldp q24, q25, [sp], #32
        ldp q22, q23, [sp], #32
        ldp q20, q21, [sp], #32
        ldp q18, q19, [sp], #32
        ldp q16, q17, [sp], #32
        ldp q14, q15, [sp], #32
        ldp q12, q13, [sp], #32
        ldp q10, q11, [sp], #32
        ldp q8, q9, [sp], #32
        ldp q6, q7, [sp], #32
        ldp q4, q5, [sp], #32
        ldp q2, q3, [sp], #32
        ldp q0, q1, [sp], #32
        ldp x27, x28, [sp], #16
        ldp x25, x26, [sp], #16
        ldp x23, x24, [sp], #16
        ldp x21, x22, [sp], #16
        ldp x19, x20, [sp], #16
        ldp x17, x18, [sp], #16
        ldp x15, x16, [sp], #16
        ldp x13, x14, [sp], #16
        ldp x11, x12, [sp], #16
        ldp x9, x10, [sp], #16
        ldp x7, x8, [sp], #16
        ldp x5, x6, [sp], #16
        ldp x3, x4, [sp], #16
        ldp x1, x2, [sp], #16
        ldp x29, x30, [sp], #16
        ret
    "#
);

#[cfg(not(target_arch = "aarch64"))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn __tlv_bootstrap(desc: *mut TlvDescriptor) -> *mut c_void {
    tlv_bootstrap_impl(desc)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sys_icache_invalidate(_addr: *mut c_void, _size: usize) {
    common::reportStub("sys_icache_invalidate");
}
