//! OpenDarwin userland smoke test: a fully self-contained Mach-O executable
//! statically linking `libsystem` (raw XNU syscall wrappers) and `iokit`
//! (IOKit.framework replacement, raw mach traps) directly - no dylibs, no
//! dyld. `libsystem` supplies this binary's single `#[panic_handler]`;
//! `iokit` is built with `default-features = false` to drop its own (see
//! iokit/Cargo.toml) since only one is allowed per linked binary.
//!
//! The kernel jumps to `main` directly per the Mach-O `LC_MAIN` entryoff
//! with x0..x3 = argc, argv, envp, apple and x30 (LR) = 0 (no dylib "exit"
//! trampoline to return into - see kmain.rs's `return_entry`), so this
//! never returns: it must call `exit` itself.
#![no_std]
#![no_main]

// buck2's rust_library `crate = "..."` override (src/libsystem/BUCK,
// src/iokit/BUCK) makes these the real extern crate names.
extern crate IOKit as iokit;
extern crate System as libsystem;

use core::ffi::c_char;

#[unsafe(no_mangle)]
pub extern "C" fn main(
    _argc: i32,
    _argv: *const *const c_char,
    _envp: *const *const c_char,
    _apple: *const *const c_char,
) -> ! {
    let msg = b"hello from Rust userland (libsystem + iokit, statically linked)\n";
    unsafe {
        libsystem::stdio::write(1, msg.as_ptr().cast(), msg.len());
    }

    let mut master_port: iokit::mach_port_t = 0;
    let kr = iokit::IOMasterPort(iokit::MACH_PORT_NULL, &raw mut master_port);
    let ok = kr == iokit::KERN_SUCCESS;
    let result_msg: &[u8] = if ok {
        b"IOMasterPort: KERN_SUCCESS\n"
    } else {
        b"IOMasterPort: failed\n"
    };
    unsafe {
        libsystem::stdio::write(1, result_msg.as_ptr().cast(), result_msg.len());
    }

    unsafe { libsystem::basics::exit(if ok { 0 } else { 1 }) }
}
