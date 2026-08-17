//! dyld introspection: _dyld_image_count, _dyld_get_image_header, etc.

use core::ffi::{c_char, c_int, c_void};

use crate::common;

const MAIN_IMAGE_BASE: usize = 0x1_0000_0000;
const MAIN_IMAGE_LIMIT: usize = 0x2_0000_0000;

fn findMachHeader(_addr: *const c_void) -> *mut c_void {
    core::ptr::null_mut()
}

// ── NSGetExecutablePath ────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn _NSGetExecutablePath(_buf: *mut u8, _bufsize: *mut u32) -> c_int {
    common::stubErr("_NSGetExecutablePath")
}

static mut ARGC: c_int = 1;
static mut ARGV: *const c_char = c"zig-smoke".as_ptr();
static mut ENVIRON_STR: *const c_char = c"".as_ptr();

#[unsafe(no_mangle)]
pub unsafe extern "C" fn _NSGetArgc() -> *mut c_int {
    &raw mut ARGC
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn _NSGetArgv() -> *mut *const c_char {
    &raw mut ARGV
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn _NSGetEnviron() -> *mut *const c_char {
    &raw mut ENVIRON_STR
}

// ── availability ───────────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn __availability_version_check(
    _count: u32,
    _versions: *const c_void,
) -> c_int {
    common::reportStub("__availability_version_check");
    1
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn _availability_version_check(count: u32, versions: *const c_void) -> c_int {
    __availability_version_check(count, versions)
}

// ── dyld image walking ─────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub extern "C" fn _dyld_image_count() -> u32 {
    1 // We have exactly one image (the main one).
}

#[unsafe(no_mangle)]
pub extern "C" fn _dyld_get_image_header(_index: u32) -> *const c_void {
    core::ptr::null()
}

#[unsafe(no_mangle)]
pub extern "C" fn _dyld_get_image_name(index: u32) -> *const c_char {
    if index == 0 {
        c"/MAIN".as_ptr()
    } else {
        core::ptr::null()
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn _dyld_get_image_vmaddr_slide(_index: u32) -> i64 {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn __dyld_get_image_header_containing_address(
    addr: *const c_void,
) -> *mut c_void {
    findMachHeader(addr)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn _dyld_get_image_header_containing_address(
    addr: *const c_void,
) -> *mut c_void {
    findMachHeader(addr)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dyld_get_image_header_containing_address(
    addr: *const c_void,
) -> *mut c_void {
    findMachHeader(addr)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn _dyld_image_path_containing_address(addr: *const c_void) -> *const c_char {
    if addr.is_null() {
        return core::ptr::null();
    }
    let p = addr as usize;
    if (MAIN_IMAGE_BASE..MAIN_IMAGE_LIMIT).contains(&p) {
        c"/MAIN".as_ptr()
    } else {
        c"/usr/lib/libSystem.B.dylib".as_ptr()
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dyld_image_path_containing_address(addr: *const c_void) -> *const c_char {
    _dyld_image_path_containing_address(addr)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn _dyld_get_image_uuid(_index: u32, uuid_out: *mut [u8; 16]) -> c_int {
    if !uuid_out.is_null() {
        core::ptr::write_bytes(uuid_out as *mut u8, 0, 16);
    }
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn _dyld_get_sdk_version_info() -> *const c_char {
    c"15.0".as_ptr()
}

#[unsafe(no_mangle)]
pub extern "C" fn _dyld_get_active_platform() -> u32 {
    1 // PLATFORM_MACOS
}

#[unsafe(no_mangle)]
pub extern "C" fn _dyld_program_sdk_at_least(_major: u32, _minor: u32, _subminor: u32) -> bool {
    true
}

// ── getsectbynamefromheader_64 ─────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getsectbynamefromheader_64(
    _header: *const c_void,
    _segname: *const c_char,
    _sectname: *const c_char,
) -> *mut c_void {
    core::ptr::null_mut()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getsectdatafromheader_64(
    _header: *const c_void,
    _segname: *const c_char,
    _sectname: *const c_char,
    _size: *mut u64,
) -> *mut c_void {
    core::ptr::null_mut()
}

// ── dlopen / dlsym / dladdr ────────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dlopen(_path: *const c_char, _mode: c_int) -> *mut c_void {
    core::ptr::null_mut()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dlsym(_handle: *mut c_void, _symbol: *const c_char) -> *mut c_void {
    core::ptr::null_mut()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dlclose(_handle: *mut c_void) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dladdr(_addr: *const c_void, _info: *mut c_void) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn dlerror() -> *const c_char {
    core::ptr::null()
}
