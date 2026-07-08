.section .text
.global enterUserspace

// enterUserspace(frame: *context.Frame, ttbr0_phys: u64) noreturn
//   x0 = pointer to a saved Frame (x0..x30, sp_el0, elr_el1, spsr_el1, ...)
//   x1 = physical address of the task's TTBR0 table
//
// Installs the task's address space, then restores its register frame and
// ERETs into it. Never returns.
//
// Deliberately does NOT use context_macros.S's RESTORE_CONTEXT (sp-relative
// loads): `frame` here is an arbitrary kernel global (a Task's saved
// state), not a location on the real kernel stack, and RESTORE_CONTEXT's
// trailing `add sp, sp, #288` would permanently leave SP_EL1 (the shared
// kernel exception stack every future exception saves into) pointing into
// scheduler state instead of a real stack - silent corruption the moment
// the next exception fires. Every load below is relative to x0 (the frame
// pointer) instead, so SP_EL1 is never touched.
enterUserspace:
    msr ttbr0_el1, x1
    isb
    tlbi vmalle1
    dsb ish
    isb

    ldp x2, x3, [x0, #248]    // sp_el0, elr_el1
    msr sp_el0, x2
    msr elr_el1, x3
    ldr x2, [x0, #264]        // spsr_el1
    msr spsr_el1, x2

    ldp x2, x3, [x0, #16]
    ldp x4, x5, [x0, #32]
    ldp x6, x7, [x0, #48]
    ldp x8, x9, [x0, #64]
    ldp x10, x11, [x0, #80]
    ldp x12, x13, [x0, #96]
    ldp x14, x15, [x0, #112]
    ldp x16, x17, [x0, #128]
    ldp x18, x19, [x0, #144]
    ldp x20, x21, [x0, #160]
    ldp x22, x23, [x0, #176]
    ldp x24, x25, [x0, #192]
    ldp x26, x27, [x0, #208]
    ldp x28, x29, [x0, #224]
    ldr x30, [x0, #240]
    ldr x1, [x0, #8]          // task's real x1
    ldr x0, [x0, #0]          // task's real x0 - loaded last, base register
    eret
