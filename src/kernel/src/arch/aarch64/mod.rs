pub mod context;
pub mod cpu;
pub mod exceptions;
pub mod pac;

core::arch::global_asm!(
    r#"
.section .text.boot
.global _start
.global enterUserspace
.global vector_table

_start:
    nop                     // code0
    b real_start            // code1
    .quad 0x80000           // text_offset
    .quad __image_size      // image_size
    .quad 0                 // flags
    .quad 0                 // reserved
    .quad 0                 // reserved
    .quad 0                 // reserved
    .ascii "ARM\x64"        // magic
    .word 0                 // res5

real_start:
    mov x20, x0

    mrs x0, mpidr_el1
    and x0, x0, #0xff
    cbz x0, primary_core

secondary_park:
    adrp x1, smp_wake_flag
    add x1, x1, :lo12:smp_wake_flag
    ldr x2, [x1]
    cbnz x2, secondary_core
    wfe
    b secondary_park

secondary_core:
    mov x9, x0
    bl secondary_el1_setup

    adrp x10, __secondary_stacks_bottom
    add x10, x10, :lo12:__secondary_stacks_bottom
    mov x1, #0x10000
    madd x10, x9, x1, x10
    add x10, x10, x1
    mov sp, x10

    mov x0, x9
    bl secondary_main

secondary_hang:
    wfe
    b secondary_hang

secondary_el1_setup:
    mrs x1, sctlr_el1
    bic x1, x1, #(1 << 1)
    msr sctlr_el1, x1
    mrs x1, cpacr_el1
    orr x1, x1, #(3 << 20)
    msr cpacr_el1, x1
    isb
    ret

primary_core:
    mrs x0, CurrentEL
    lsr x0, x0, #2
    cmp x0, #2
    b.eq from_el2
    cmp x0, #1
    b.eq from_el1
    b secondary_park

from_el2:
    mov x0, #(1 << 31)
    msr hcr_el2, x0
    msr cptr_el2, xzr
    msr hstr_el2, xzr
    msr sctlr_el1, xzr
    mov x0, #0x3c5
    msr spsr_el2, x0
    adr x0, from_el1
    msr elr_el2, x0
    eret

from_el1:
    mrs x0, sctlr_el1
    bic x0, x0, #(1 << 1)
    msr sctlr_el1, x0
    mrs x0, cpacr_el1
    orr x0, x0, #(3 << 20)
    msr cpacr_el1, x0
    isb

    adrp x0, __boot_stack_top
    add x0, x0, :lo12:__boot_stack_top
    mov sp, x0

    adrp x1, __bss_start
    add x1, x1, :lo12:__bss_start
    adrp x2, __bss_end
    add x2, x2, :lo12:__bss_end
zero_bss:
    cmp x1, x2
    b.ge zero_bss_done
    str xzr, [x1], #8
    b zero_bss
zero_bss_done:

    adrp x1, dtb_phys_addr
    add x1, x1, :lo12:dtb_phys_addr
    str x20, [x1]

    bl kmain

hang:
    wfe
    b hang

.section .text.exceptions
.balign 0x800
vector_table:
    // Current EL, SP0
    b sync_trampoline; .balign 0x80
    b irq_trampoline; .balign 0x80
    b fiq_trampoline; .balign 0x80
    b serror_trampoline; .balign 0x80
    // Current EL, SPx
    b sync_trampoline; .balign 0x80
    b irq_trampoline; .balign 0x80
    b fiq_trampoline; .balign 0x80
    b serror_trampoline; .balign 0x80
    // Lower EL, AArch64
    b sync_trampoline; .balign 0x80
    b irq_trampoline; .balign 0x80
    b fiq_trampoline; .balign 0x80
    b serror_trampoline; .balign 0x80
    // Lower EL, AArch32
    b unexpected_trampoline; .balign 0x80
    b unexpected_trampoline; .balign 0x80
    b unexpected_trampoline; .balign 0x80
    b unexpected_trampoline; .balign 0x80

sync_trampoline:
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
    mov x0, sp
    bl handleSyncException
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
    eret

irq_trampoline:
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
    mov x0, sp
    bl handleIrqException
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
    eret

fiq_trampoline:
    sub sp, sp, #800
    stp x0, x1, [sp, #0]
    str x30, [sp, #240]
    mov x0, sp
    bl handleFiqException
    add sp, sp, #800
    eret

serror_trampoline:
    sub sp, sp, #800
    stp x0, x1, [sp, #0]
    str x30, [sp, #240]
    mov x0, sp
    bl handleSErrorException
    add sp, sp, #800
    eret

unexpected_trampoline:
    sub sp, sp, #800
    stp x0, x1, [sp, #0]
    str x30, [sp, #240]
    mov x0, sp
    bl handleUnexpectedException
    add sp, sp, #800
    eret

enterUserspace:
    msr ttbr0_el1, x1
    isb
    tlbi vmalle1
    dsb ish
    isb

    ldp q0, q1, [x0, #288]
    ldp q2, q3, [x0, #320]
    ldp q4, q5, [x0, #352]
    ldp q6, q7, [x0, #384]
    ldp q8, q9, [x0, #416]
    ldp q10, q11, [x0, #448]
    ldp q12, q13, [x0, #480]
    ldp q14, q15, [x0, #512]
    ldp q16, q17, [x0, #544]
    ldp q18, q19, [x0, #576]
    ldp q20, q21, [x0, #608]
    ldp q22, q23, [x0, #640]
    ldp q24, q25, [x0, #672]
    ldp q26, q27, [x0, #704]
    ldp q28, q29, [x0, #736]
    ldp q30, q31, [x0, #768]

    ldp x2, x3, [x0, #248]
    msr sp_el0, x2
    msr elr_el1, x3
    ldr x2, [x0, #264]
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
    ldr x1, [x0, #8]
    ldr x0, [x0, #0]
    eret
"#
);

unsafe extern "C" {
    pub fn enterUserspace(frame: *const context::Frame, ttbr0_phys: u64) -> !;
}
