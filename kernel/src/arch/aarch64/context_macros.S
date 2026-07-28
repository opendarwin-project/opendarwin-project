// Shared save/restore-context macros for context.Frame (see context.zig).
// Included (via .include) by both vectors.S (exception entry/exit) and
// task_entry.S (first entry into a fresh task, and later context switches).
//
// Frame is 800 bytes: 288 bytes of GPRs/sysregs (offsets unchanged from the
// original layout) followed by 512 bytes of q0..q31. SP must stay 16-byte
// aligned for `stp qN, qM`.

.macro SAVE_CONTEXT
    sub sp, sp, #800
    stp x0, x1, [sp, #0]
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp x8, x9, [sp, #64]
    stp x10, x11, [sp, #80]
    stp x12, x13, [sp, #96]
    stp x14, x15, [sp, #112]
    stp x16, x17, [sp, #128]
    stp x18, x19, [sp, #144]
    stp x20, x21, [sp, #160]
    stp x22, x23, [sp, #176]
    stp x24, x25, [sp, #192]
    stp x26, x27, [sp, #208]
    stp x28, x29, [sp, #224]
    str x30, [sp, #240]
    mrs x1, sp_el0
    mrs x2, elr_el1
    stp x1, x2, [sp, #248]
    mrs x1, spsr_el1
    mrs x2, esr_el1
    stp x1, x2, [sp, #264]
    mrs x1, far_el1
    str x1, [sp, #280]
    // FPSIMD — kernel handlers may clobber the entire bank.
    stp q0, q1, [sp, #288]
    stp q2, q3, [sp, #320]
    stp q4, q5, [sp, #352]
    stp q6, q7, [sp, #384]
    stp q8, q9, [sp, #416]
    stp q10, q11, [sp, #448]
    stp q12, q13, [sp, #480]
    stp q14, q15, [sp, #512]
    stp q16, q17, [sp, #544]
    stp q18, q19, [sp, #576]
    stp q20, q21, [sp, #608]
    stp q22, q23, [sp, #640]
    stp q24, q25, [sp, #672]
    stp q26, q27, [sp, #704]
    stp q28, q29, [sp, #736]
    stp q30, q31, [sp, #768]
.endm

.macro RESTORE_CONTEXT
    ldp q30, q31, [sp, #768]
    ldp q28, q29, [sp, #736]
    ldp q26, q27, [sp, #704]
    ldp q24, q25, [sp, #672]
    ldp q22, q23, [sp, #640]
    ldp q20, q21, [sp, #608]
    ldp q18, q19, [sp, #576]
    ldp q16, q17, [sp, #544]
    ldp q14, q15, [sp, #512]
    ldp q12, q13, [sp, #480]
    ldp q10, q11, [sp, #448]
    ldp q8, q9, [sp, #416]
    ldp q6, q7, [sp, #384]
    ldp q4, q5, [sp, #352]
    ldp q2, q3, [sp, #320]
    ldp q0, q1, [sp, #288]
    ldp x1, x2, [sp, #248]
    msr sp_el0, x1
    msr elr_el1, x2
    ldr x1, [sp, #264]
    msr spsr_el1, x1
    ldr x30, [sp, #240]
    ldp x28, x29, [sp, #224]
    ldp x26, x27, [sp, #208]
    ldp x24, x25, [sp, #192]
    ldp x22, x23, [sp, #176]
    ldp x20, x21, [sp, #160]
    ldp x18, x19, [sp, #144]
    ldp x16, x17, [sp, #128]
    ldp x14, x15, [sp, #112]
    ldp x12, x13, [sp, #96]
    ldp x10, x11, [sp, #80]
    ldp x8, x9, [sp, #64]
    ldp x6, x7, [sp, #48]
    ldp x4, x5, [sp, #32]
    ldp x2, x3, [sp, #16]
    ldp x0, x1, [sp, #0]
    add sp, sp, #800
.endm
