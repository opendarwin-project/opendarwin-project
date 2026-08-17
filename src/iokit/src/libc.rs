//! Minimal raw bindings to **libSystem**, kept separate so the machine traps
//! (and any other syscalls) can be split out into their own submodule later.
//!
//! The crate is `#![no_std]` — no Rust std runtime, no TLS, no libSystem
//! init — so a framework dylib built here is a thin shim over the raw kernel
//! ABI. Everything in this module is an `unsafe extern "C"` declaration that
//! is resolved by dyld at load time (libSystem is always present on macOS).

use core::alloc::{GlobalAlloc, Layout};
use core::ffi::c_void;

// libSystem heap functions, resolved via dyld at load.
#[link(name = "System")]
unsafe extern "C" {
    pub fn malloc(size: usize) -> *mut c_void;
    pub fn realloc(ptr: *mut c_void, size: usize) -> *mut c_void;
    pub fn free(ptr: *mut c_void);
    /// Unwinds the whole process, aborting without flushing.
    #[allow(dead_code)] // only reached via the panic handler, cfg'd out for tests
    pub fn abort() -> !;
    pub fn mach_host_self() -> u32;
    pub fn mach_reply_port() -> u32;
    pub fn mach_msg2_trap(
        msg: *mut u8,
        option: u64,
        send_size_and_bits: u64,
        ports: u64,
        id_and_voucher: u64,
        desc_and_rcv_name: u64,
        priority_and_rcv_size: u64,
        timeout: u32,
    ) -> u32;
    pub fn iokit_user_client_trap(
        connect: u32,
        index: u32,
        p1: usize,
        p2: usize,
        p3: usize,
        p4: usize,
        p5: usize,
        p6: usize,
    ) -> i32;
}

/// Global allocator that redirects `Box`/`alloc` to libSystem's heap.
///
/// This is the same heap the kernel user-client code and CF use, so memory
/// handed to/from the kernel stays in one allocator.
pub struct System;

unsafe impl GlobalAlloc for System {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        // SAFETY: may return null; alloc callers handle OOM. Size passed through.
        unsafe { malloc(layout.size()) as *mut u8 }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, _layout: Layout) {
        // SAFETY: ptr came from this allocator (or is null); free is safe.
        unsafe { free(ptr as *mut c_void) };
    }
    unsafe fn realloc(&self, ptr: *mut u8, _layout: Layout, new_size: usize) -> *mut u8 {
        // SAFETY: ptr was allocated by this allocator; new_size passed through.
        unsafe { realloc(ptr as *mut c_void, new_size) as *mut u8 }
    }
}
