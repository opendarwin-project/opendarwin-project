//! Clang blocks runtime: minimal implementation for CoreFoundation and other
//! C code compiled with -fblocks.

use core::ffi::{c_int, c_void};
use core::sync::atomic::{AtomicI32, Ordering};

// Block descriptor flags (ABI).
pub const BLOCK_HAS_COPY_DISPOSE: c_int = 1 << 25;
pub const BLOCK_HAS_SIGNATURE: c_int = 1 << 30;
pub const BLOCK_IS_GLOBAL: c_int = 1 << 28;

#[repr(C)]
pub struct BlockDescriptor {
    pub reserved: usize,
    pub size: usize,
    pub copy: Option<unsafe extern "C" fn(*mut c_void, *mut c_void)>,
    pub dispose: Option<unsafe extern "C" fn(*mut c_void)>,
}

#[repr(C)]
pub struct BlockLayout {
    pub isa: *mut c_void,
    pub flags: c_int,
    pub reserved: c_int,
    pub invoke: Option<unsafe extern "C" fn()>,
    pub descriptor: *const BlockDescriptor,
}

unsafe fn blockFlags(block: *const BlockLayout) -> c_int {
    let flags_atomic = &*(&raw const (*block).flags as *const AtomicI32);
    flags_atomic.load(Ordering::Acquire)
}

unsafe fn blockIsGlobal(block: *const BlockLayout) -> bool {
    (blockFlags(block) & BLOCK_IS_GLOBAL) != 0
}

unsafe fn blockHasCopyDispose(block: *const BlockLayout) -> bool {
    (blockFlags(block) & BLOCK_HAS_COPY_DISPOSE) != 0
}

unsafe fn blockSize(block: *const BlockLayout) -> usize {
    (*(*block).descriptor).size
}

unsafe extern "C" fn copyBlock(dst: *mut c_void, src: *mut c_void) {
    let layout = src as *const BlockLayout;
    let size = blockSize(layout);
    crate::string::memcpy(dst, src as *const c_void, size);
    let dst_block = dst as *mut BlockLayout;
    (*dst_block).isa = mallocBlockIsa();
}

unsafe fn mallocBlockIsa() -> *mut c_void {
    &raw mut _NSConcreteMallocBlock as *mut c_void
}

unsafe extern "C" fn disposeBlock(block: *mut c_void) {
    crate::malloc::free(block);
}

static MALLOC_BLOCK_DESCRIPTOR: BlockDescriptor = BlockDescriptor {
    reserved: 0,
    size: 0,
    copy: Some(copyBlock),
    dispose: Some(disposeBlock),
};

/// Stack block class marker (isa for blocks on the stack).
#[unsafe(no_mangle)]
pub static mut _NSConcreteStackBlock: BlockLayout = BlockLayout {
    isa: core::ptr::null_mut(),
    flags: 0,
    reserved: 0,
    invoke: None,
    descriptor: &MALLOC_BLOCK_DESCRIPTOR,
};

/// Global block class marker (isa for global/static blocks).
#[unsafe(no_mangle)]
pub static mut _NSConcreteGlobalBlock: BlockLayout = BlockLayout {
    isa: core::ptr::null_mut(),
    flags: BLOCK_IS_GLOBAL,
    reserved: 0,
    invoke: None,
    descriptor: &MALLOC_BLOCK_DESCRIPTOR,
};

/// Heap block class marker assigned by _Block_copy.
#[unsafe(no_mangle)]
pub static mut _NSConcreteMallocBlock: BlockLayout = BlockLayout {
    isa: core::ptr::null_mut(),
    flags: BLOCK_HAS_COPY_DISPOSE,
    reserved: 0,
    invoke: None,
    descriptor: &MALLOC_BLOCK_DESCRIPTOR,
};

#[unsafe(no_mangle)]
pub unsafe extern "C" fn _Block_copy(block: *const c_void) -> *mut c_void {
    if block.is_null() {
        return core::ptr::null_mut();
    }
    let layout = block as *const BlockLayout;
    if blockIsGlobal(layout) {
        return block as *mut c_void;
    }
    if (*layout).isa == mallocBlockIsa() {
        return block as *mut c_void;
    }

    let size = blockSize(layout);
    let dst = crate::malloc::malloc(size);
    if dst.is_null() {
        return core::ptr::null_mut();
    }
    if blockHasCopyDispose(layout) {
        if let Some(copy_fn) = (*(*layout).descriptor).copy {
            copy_fn(dst, block as *mut c_void);
        }
    } else {
        copyBlock(dst, block as *mut c_void);
    }
    dst
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn _Block_release(block: *const c_void) {
    if block.is_null() {
        return;
    }
    let layout = block as *const BlockLayout;
    if blockIsGlobal(layout) {
        return;
    }
    if (*layout).isa != mallocBlockIsa() {
        return;
    }
    if blockHasCopyDispose(layout) {
        if let Some(dispose_fn) = (*(*layout).descriptor).dispose {
            dispose_fn(block as *mut c_void);
        }
    } else {
        disposeBlock(block as *mut c_void);
    }
}
