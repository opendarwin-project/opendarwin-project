.section __TEXT,__text,regular,pure_instructions
.globl _kext_start
.p2align 2
_kext_start:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0

    ldr x8, [x19, #0]
    mov x9, #3
    cmp x8, x9
    b.ne 1f

    ldr x8, [x19, #8]
    adrp x0, L_entry_msg@PAGE
    add x0, x0, L_entry_msg@PAGEOFF
    mov x1, #21
    blr x8

    adrp x20, _driver_descriptor@PAGE
    add x20, x20, _driver_descriptor@PAGEOFF
    mov x8, #3
    str x8, [x20, #0]
    adrp x8, L_driver_name@PAGE
    add x8, x8, L_driver_name@PAGEOFF
    str x8, [x20, #8]
    mov x8, #16
    str x8, [x20, #16]
    mov x8, #1
    str x8, [x20, #24]
    str xzr, [x20, #32]
    adrp x8, _driver_start@PAGE
    add x8, x8, _driver_start@PAGEOFF
    str x8, [x20, #40]
    str xzr, [x20, #48]

    ldr x8, [x19, #16]
    mov x0, x20
    blr x8
    b 2f

1:
    mov w0, #-1

2:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

.p2align 2
_driver_start:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ldr x8, [x1, #8]
    adrp x0, L_start_msg@PAGE
    add x0, x0, L_start_msg@PAGEOFF
    mov x1, #27
    blr x8
    mov w0, #0
    ldp x29, x30, [sp], #16
    ret

.section __TEXT,__const
L_entry_msg:
    .ascii "kext smoke: entry ok\n"
L_start_msg:
    .ascii "kext smoke: block start ok\n"
L_driver_name:
    .ascii "virtio-blk-smoke"

.section __DATA,__data
.p2align 3
_driver_descriptor:
    .quad 0
    .quad 0
    .quad 0
    .quad 0
    .quad 0
    .quad 0
    .quad 0
