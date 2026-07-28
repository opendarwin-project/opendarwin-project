//! Saved register frame pushed by vectors.S's SAVE_CONTEXT macro. Field
//! order/types must match that macro's stack offsets exactly.
//!
//! Layout:
//!   0x000..0x11f  x0..x30          (248 bytes)
//!   0x0f8..0x11f  sp_el0..far_el1  (40 bytes; ends at 288)
//!   0x120..0x31f  q0..q31          (512 bytes)
//! Total 800. GPR offsets are unchanged from the pre-NEON frame so existing
//! `task_entry.S` / signal paths keep working; FPSIMD was appended.
//!
//! NEON must be saved across EL0→EL1: the kernel is free to use q0–q31, and
//! AAPCS64 callee-saved d8–d15 (plus IRQ-interrupted q0–q7) would otherwise
//! be silently clobbered. That showed up as `Io.Threaded.allocator.vtable`
//! corruption under `-Doptimize=ReleaseFast` after `sigaction` in
//! `Threaded.init`.

pub const Frame = extern struct {
    x: [31]u64, // x0..x30 (x30 is LR)
    sp_el0: u64,
    elr_el1: u64,
    spsr_el1: u64,
    esr_el1: u64,
    far_el1: u64,
    /// Full FPSIMD bank. Kept zero for freshly created tasks.
    q: [32]u128 = [_]u128{0} ** 32,
};

comptime {
    if (@offsetOf(Frame, "sp_el0") != 248) @compileError("Frame GPR layout drifted");
    if (@offsetOf(Frame, "q") != 288) @compileError("Frame NEON layout drifted");
    if (@sizeOf(Frame) != 800) @compileError("Frame layout drifted from vectors.S SAVE_CONTEXT");
}
