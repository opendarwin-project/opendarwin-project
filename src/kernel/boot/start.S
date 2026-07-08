.section .text.boot
.global _start

_start:
    // Park all secondary cores; only boot on core 0 for milestone 1.
    mrs x0, mpidr_el1
    and x0, x0, #0xff
    cbz x0, primary_core
park:
    wfe
    b park

primary_core:
    // Figure out current exception level.
    mrs x0, CurrentEL
    lsr x0, x0, #2
    cmp x0, #2
    b.eq from_el2
    cmp x0, #1
    b.eq from_el1
    // Unexpected EL (e.g. EL3) - not handled in milestone 1, just spin.
    b park

from_el2:
    // Minimal EL2 setup then drop to EL1.
    // HCR_EL2.RW = 1 -> EL1 is AArch64.
    mov x0, #(1 << 31)
    msr hcr_el2, x0

    // Route all interrupts to their own EL, no traps we care about yet.
    msr cptr_el2, xzr
    msr hstr_el2, xzr

    // Disable EL1 MMU/caches for now (we set it up ourselves later).
    msr sctlr_el1, xzr

    // Set up SPSR_EL2 to return into EL1h with interrupts masked.
    mov x0, #0x3c5 // EL1h, DAIF masked
    msr spsr_el2, x0

    adr x0, from_el1
    msr elr_el2, x0
    eret

from_el1:
    // Clear SCTLR_EL1.A (strict alignment fault checking): its reset value
    // is not guaranteed zero on this CPU model, and general-purpose code
    // (e.g. the standard library's formatting routines) freely performs
    // unaligned loads/stores that AArch64 otherwise tolerates.
    mrs x0, sctlr_el1
    bic x0, x0, #(1 << 1)
    msr sctlr_el1, x0

    // Enable FP/SIMD access at EL1 (FPEN=0b11 in CPACR_EL1); the compiler
    // is free to use NEON registers (e.g. to copy small structs) even in
    // code that never explicitly touches floating point.
    mrs x0, cpacr_el1
    orr x0, x0, #(3 << 20)
    msr cpacr_el1, x0
    isb

    // Set up the boot stack.
    adrp x0, __boot_stack_top
    add x0, x0, :lo12:__boot_stack_top
    mov sp, x0

    // Zero .bss
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

    bl kmain

hang:
    wfe
    b hang
