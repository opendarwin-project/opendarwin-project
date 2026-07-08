.include "context_macros.S"

.section .text
.global enterUserspace

// enterUserspace(frame: *context.Frame, ttbr0_phys: u64) noreturn
//   x0 = pointer to a saved Frame (x0..x30, sp_el0, elr_el1, spsr_el1, ...)
//   x1 = physical address of the task's TTBR0 table
//
// Installs the task's address space, then restores its register frame and
// ERETs into it. Never returns.
enterUserspace:
    msr ttbr0_el1, x1
    isb
    tlbi vmalle1
    dsb ish
    isb

    mov sp, x0
    RESTORE_CONTEXT
    eret
