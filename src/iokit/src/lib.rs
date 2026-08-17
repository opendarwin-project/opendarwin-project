//! OpenDarwin `IOKit.framework` userspace replacement, written in Rust.
//!
//! This crate is the Rust rewrite of `src/iokit/iokit.zig`. It talks to the
//! kernel exclusively through **raw XNU mach traps** (`svc #0x80` on aarch64,
//! trap number negated in `x16`, exactly like libsystem_kernel)
//! and raw `mach_msg2` request/reply RPCs — no libSystem IOKit code involved.
//!
//! ## Trap surface
//!
//! | Trap | Name                                     |
//! | ---- | ---------------------------------------- |
//! | 26   | `mach_reply_port`                        |
//! | 29   | `host_self_trap`                         |
//! | 47   | `mach_msg2_trap` (`mach_msg` RPC)        |
//! | 100  | `iokit_user_client_trap` (`IOConnectTrap0..6`) |
//!
//! Match / open / mapMemory use a simplified MIG-like `mach_msg2` protocol
//! (message ids 2900/2901/2902/2904) served by the OpenDarwin guest kernel
//! (`src/kernel/iokit/mach_server.zig`). Method dispatch on a user client
//! goes through trap 100.
//!
//! ## Modules
//!
//! - [`types`]      — C-facing IOKitLib types and constants
//! - [`traps`]      — raw `svc #0x80` trap invocations
//! - [`mach`]       — `mach_msg2` plumbing and the simplified RPC
//! - [`matching`]   — `IOServiceMatching` dictionaries
//! - [`service`]    — master port / lookup / open / close / release
//! - [`connect`]    — connection map + method dispatch (`IOConnect*`)
//! - [`framebuffer`]— `IOFramebuffer*` convenience helpers
//!
//! ## Build
//!
//! ```text
//! cargo build -p iokit --release --target aarch64-apple-darwin
//! ```
//!
//! Then install as a framework image (see [`tools/build_iokit_framework.sh`](../../tools/build_iokit_framework.sh)):
//!
//! ```text
//! tools/build_iokit_framework.sh universal
//! DYLD_FRAMEWORK_PATH=$PWD/target/iokit-framework /path/to/consumer
//! ```
//!
//! `arm64e-apple-darwin` slices are built with `-Zbuild-std=core,alloc` —
//! the crate is `#![no_std]` (no TLS, no libSystem std runtime), which avoids
//! the arm64e build-std std runtime faults — see the script.

#![allow(non_snake_case, non_camel_case_types, non_upper_case_globals)]
#![no_std]
extern crate alloc;
#[cfg(test)]
extern crate std;

mod connect;
mod libc;
pub mod types;

// The cdylib is a final artifact: give it a heap (via libSystem malloc) and a
// `#[panic_handler]` (abort). Under `cfg(test)` the test harness links std,
// which supplies both, so these are only compiled for the non-test build.
#[global_allocator]
static GLOBAL_ALLOC: libc::System = libc::System;

#[cfg(not(test))]
#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    unsafe { libc::abort() }
}

// Even with panic = "abort", a cdylib can emit a reference to the DWARF
// unwind personality routine. std normally provides it; in no_std we stub it.
#[cfg(not(test))]
#[unsafe(no_mangle)]
extern "C" fn rust_eh_personality() {}
mod framebuffer;
mod mach;
mod matching;
mod service;
// Re-export the C-facing types so `use iokit::*` mirrors IOKitLib.h.
pub use types::{
    IOFramebufferInfo, IOReturn, KERN_SUCCESS, MACH_PORT_NULL, io_connect_t, io_object_t,
    io_service_t, kern_return_t, mach_port_t,
};
