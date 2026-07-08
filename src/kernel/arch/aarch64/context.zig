//! Saved register frame pushed by vectors.S's SAVE_CONTEXT macro. Field
//! order/types must match that macro's stack offsets exactly (all fields are
//! u64, so natural `extern struct` layout lines up 1:1).

pub const Frame = extern struct {
    x: [31]u64, // x0..x30 (x30 is LR)
    sp_el0: u64,
    elr_el1: u64,
    spsr_el1: u64,
    esr_el1: u64,
    far_el1: u64,
};

comptime {
    if (@sizeOf(Frame) != 288) @compileError("Frame layout drifted from vectors.S SAVE_CONTEXT");
}
