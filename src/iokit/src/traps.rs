//! Raw XNU mach trap invocations.
//!
//! On aarch64 Darwin a mach trap is taken exactly like libsystem_kernel does
//! (this is what a dyld-loaded framework needs on Apple's kernel):
//!
//! ```text
//! mov x16, <negated trap number>
//! svc  #0x80
//! ```
//!
//! The trap number is *negated* in `x16` (`-26` for `mach_reply_port`, `-47`
//! for `mach_msg2_trap`), matching `mov x16, #-0x1a; svc #0x80` in
//! libsystem_kernel on macOS 26. (OpenDarwin's guest kernel instead uses
//! `svc #0x81` with positive numbers; this crate targets real macOS, so only
//! the negative encoding is provided.)
//!
//! Arguments go in `x0..x7`, the result returns in `x0`. The kernel clobbers
//! `x0..x17`, so every invocation lists them as outputs. No libSystem
//! functions are called on this path — it is a pure syscall layer.
//!
//! On non-`macOS`/non-`aarch64` hosts the functions are fallbacks returning
//! `usize::MAX` (i.e. `-1` when viewed as a `kern_return_t`), so the crate
//! still passes `cargo check` on CI machines that cannot take mach traps.

/// Map a logical (positive) trap number to the value placed in `x16`.
#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
#[inline]
fn encode(number: usize) -> usize {
    // Real XNU: mach traps are `svc #0x80` with the number negated.
    number.wrapping_neg()
}

/// Emit a trap invocation and return the value left in `x0`.
///
/// `$ins` / `$outs` are `in("xN") value,` / `out("xN") _,` fragments for
/// register arguments and clobbers.
macro_rules! trap {
    ($svc:literal; $num:expr; [$($ins:tt)*]; [$($outs:tt)*]) => {{
        let mut ret: usize;
        unsafe {
            core::arch::asm!(
                "mov x16, {num}",
                $svc,
                num = in(reg) $num,
                inout("x0") 0usize => ret,
                $($ins)*
                $($outs)*,
                options(nostack),
            );
        }
        ret
    }};
}

/// Trap with no meaningful arguments (`mach_host_self`, `mach_reply_port`, …).
///
/// # Safety
///
/// Only call with a real mach trap number; the kernel reads `x0..x7` as
/// arguments for some traps, so they are zero-initialized here.
#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
#[inline]
pub(crate) unsafe fn trap0(number: usize) -> usize {
    trap!("svc #0x80"; encode(number);
        [];
        [out("x1") _, out("x2") _, out("x3") _, out("x4") _,
         out("x5") _, out("x6") _, out("x7") _, out("x8") _,
         out("x9") _, out("x10") _, out("x11") _, out("x12") _,
         out("x13") _, out("x14") _, out("x15") _, out("x16") _,
         out("x17") _])
}

/// Trap with up to seven arguments (`mach_port_*`, …).
///
/// # Safety
///
/// `number` must be a real mach trap; `a0..a6` are passed verbatim in
/// `x0..x6` and `x7` is zeroed.
#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
#[inline]
#[allow(dead_code)] // kept as a primitive for future mach_port_*/vm_* traps
pub(crate) unsafe fn trap7(
    number: usize,
    a0: usize,
    a1: usize,
    a2: usize,
    a3: usize,
    a4: usize,
    a5: usize,
    a6: usize,
) -> usize {
    let mut ret: usize;
    unsafe {
        core::arch::asm!(
            "mov x16, {num}",
            "svc #0x80",
            num = in(reg) encode(number),
            inout("x0") a0 => ret,
            in("x1") a1, in("x2") a2, in("x3") a3, in("x4") a4,
            in("x5") a5, in("x6") a6, in("x7") 0usize,
            out("x8") _, out("x9") _, out("x10") _, out("x11") _,
            out("x12") _, out("x13") _, out("x14") _, out("x15") _,
            out("x16") _, out("x17") _,
            options(nostack),
        );
    }
    ret
}

/// Trap with eight arguments (`mach_msg2_trap`, `iokit_user_client_trap`).
///
/// # Safety
///
/// `number` must be a real mach trap; `a0..a7` are passed verbatim in
/// `x0..x7`.
#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
#[inline]
pub(crate) unsafe fn trap8(
    number: usize,
    a0: usize,
    a1: usize,
    a2: usize,
    a3: usize,
    a4: usize,
    a5: usize,
    a6: usize,
    a7: usize,
) -> usize {
    let mut ret: usize;
    unsafe {
        core::arch::asm!(
            "mov x16, {num}",
            "svc #0x80",
            num = in(reg) encode(number),
            inout("x0") a0 => ret,
            in("x1") a1, in("x2") a2, in("x3") a3, in("x4") a4,
            in("x5") a5, in("x6") a6, in("x7") a7,
            out("x8") _, out("x9") _, out("x10") _, out("x11") _,
            out("x12") _, out("x13") _, out("x14") _, out("x15") _,
            out("x16") _, out("x17") _,
            options(nostack),
        );
    }
    ret
}

#[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
pub(crate) unsafe fn trap0(_number: usize) -> usize {
    usize::MAX
}

#[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
pub(crate) unsafe fn trap7(
    _number: usize,
    _a0: usize,
    _a1: usize,
    _a2: usize,
    _a3: usize,
    _a4: usize,
    _a5: usize,
    _a6: usize,
) -> usize {
    usize::MAX
}

#[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
pub(crate) unsafe fn trap8(
    _number: usize,
    _a0: usize,
    _a1: usize,
    _a2: usize,
    _a3: usize,
    _a4: usize,
    _a5: usize,
    _a6: usize,
    _a7: usize,
) -> usize {
    usize::MAX
}

#[cfg(all(test, target_os = "macos", target_arch = "aarch64"))]
mod tests {
    use super::*;
    use crate::types::{MACH_host_self_trap, MACH_mach_reply_port};

    /// A real end-to-end trap round trip against the running kernel: the host
    /// port and a fresh reply port must both be non-null.
    #[test]
    fn mach_self_traps_work() {
        let host = unsafe { trap0(MACH_host_self_trap) } as u32;
        let reply = unsafe { trap0(MACH_mach_reply_port) } as u32;
        assert_ne!(host, 0, "mach_host_self returned a null port");
        assert_ne!(reply, 0, "mach_reply_port returned a null port");
    }

    #[test]
    fn encoding_negates_for_real_kernel() {
        // Real XNU (macOS 26+): x16 = -trap_number.
        assert_eq!(encode(26), (-26i64) as usize);
        assert_eq!(encode(47), (-47i64) as usize);
        assert_eq!(encode(100), (-100i64) as usize);
    }
}
