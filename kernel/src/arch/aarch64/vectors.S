// AArch64 exception vector table (VBAR_EL1).
//
// The table has 16 slots, 0x80 bytes apart, grouped by (SP0 / SPx / lower-EL
// AArch64 / lower-EL AArch32) x (sync / IRQ / FIQ / SError). For milestone 1
// we don't distinguish *which group* fired (all of SP0/SPx/lower-EL64 route
// to the same four Zig handlers, keyed only by exception class); lower-EL
// AArch32 is unused (aarch64-only kernel/userspace) and just panics.
//
// Each 0x80-byte slot only has room for ~32 instructions, so slots just
// branch to one of four shared trampolines that live outside the aligned
// table and do the real save-context / dispatch / restore-context work.

.include "context_macros.S"

.macro VECTOR_SLOT trampoline
    b \trampoline
    .balign 0x80
.endm

.section .text.exceptions
.balign 0x800
.global vector_table
vector_table:
    // Current EL, SP0
    VECTOR_SLOT sync_trampoline
    VECTOR_SLOT irq_trampoline
    VECTOR_SLOT fiq_trampoline
    VECTOR_SLOT serror_trampoline
    // Current EL, SPx
    VECTOR_SLOT sync_trampoline
    VECTOR_SLOT irq_trampoline
    VECTOR_SLOT fiq_trampoline
    VECTOR_SLOT serror_trampoline
    // Lower EL, AArch64
    VECTOR_SLOT sync_trampoline
    VECTOR_SLOT irq_trampoline
    VECTOR_SLOT fiq_trampoline
    VECTOR_SLOT serror_trampoline
    // Lower EL, AArch32 (unused - aarch64-only kernel/userspace)
    VECTOR_SLOT unexpected_trampoline
    VECTOR_SLOT unexpected_trampoline
    VECTOR_SLOT unexpected_trampoline
    VECTOR_SLOT unexpected_trampoline

sync_trampoline:
    SAVE_CONTEXT
    mov x0, sp
    bl handleSyncException
    RESTORE_CONTEXT
    eret

irq_trampoline:
    SAVE_CONTEXT
    mov x0, sp
    bl handleIrqException
    RESTORE_CONTEXT
    eret

fiq_trampoline:
    SAVE_CONTEXT
    mov x0, sp
    bl handleFiqException
    RESTORE_CONTEXT
    eret

serror_trampoline:
    SAVE_CONTEXT
    mov x0, sp
    bl handleSErrorException
    RESTORE_CONTEXT
    eret

unexpected_trampoline:
    SAVE_CONTEXT
    mov x0, sp
    bl handleUnexpectedException
    RESTORE_CONTEXT
    eret
