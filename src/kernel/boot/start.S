.section .text.boot
.global _start

_start:
    // QEMU's -kernel boot protocol passes a pointer to the flattened
    // device tree in x0 (x1-x3 reserved as 0). Stash it in x20 (callee/
    // cross-call preserved throughout this file - nothing below touches
    // it) before x0 gets immediately overwritten by the mpidr check; only
    // the primary core's path actually uses it (from_el1 stores it to
    // dtb_phys_addr for kmain.zig).
    mov x20, x0

    // Core 0 boots immediately; all others park until released by
    // smp.wakeSecondaries() (see smp.zig's module doc comment for why this
    // flag+wfe/sev scheme is used instead of PSCI CPU_ON).
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
    // x0 still holds this core's ID (0-255) from the mpidr check above;
    // secondary_el1_setup only touches x1/x30, so it's preserved across
    // the call below with no need to stash it.
    mov x9, x0
    bl secondary_el1_setup

    // Each secondary core gets its own fixed-size stack slot, indexed
    // directly by core ID (see linker.ld's __secondary_stacks_bottom).
    adrp x10, __secondary_stacks_bottom
    add x10, x10, :lo12:__secondary_stacks_bottom
    mov x1, #0x10000
    madd x10, x9, x1, x10
    add x10, x10, x1 // top of THIS core's slot (stacks grow down)
    mov sp, x10

    mov x0, x9 // core id -> secondaryMain's argument
    bl secondaryMain

secondary_hang:
    wfe
    b secondary_hang

// Shared EL1-entry per-core setup (SCTLR.A clear, FP/SIMD enable) factored
// out so both the primary and secondary paths use identical settings.
// Only touches x1/x30 (and flags); x0 is left untouched.
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
    // Figure out current exception level.
    mrs x0, CurrentEL
    lsr x0, x0, #2
    cmp x0, #2
    b.eq from_el2
    cmp x0, #1
    b.eq from_el1
    // Unexpected EL (e.g. EL3) - not handled in milestone 1, just spin.
    b secondary_park

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
    // Clear SCTLR_EL1.A + enable FP/SIMD (see secondary_el1_setup above -
    // this is the primary core's copy of the same setup; kept inline here
    // rather than calling the shared routine so the boot stack isn't
    // needed yet at this point).
    mrs x0, sctlr_el1
    bic x0, x0, #(1 << 1)
    msr sctlr_el1, x0
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

    // Hand the saved DTB pointer to Zig (a single aligned scalar store -
    // safe pre-MMU, see mmu.zig's module doc comment on why only *wide*
    // pre-MMU accesses are the hazard).
    adrp x1, dtb_phys_addr
    add x1, x1, :lo12:dtb_phys_addr
    str x20, [x1]

    bl kmain

hang:
    wfe
    b hang
