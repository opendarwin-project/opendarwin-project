.section __TEXT,__text
.global _start
.align 4

_start:
    mov x16, #28
    svc #0x81
    cbz x0, fail_task_self
    adrp x19, task_port@PAGE
    add x19, x19, task_port@PAGEOFF
    str w0, [x19]

    adrp x1, alloc_addr@PAGE
    add x1, x1, alloc_addr@PAGEOFF
    mov x2, #0x1000
    mov x3, #1
    ldr w0, [x19]
    mov x16, #10
    svc #0x81
    cbnz x0, fail_vm_allocate
    adrp x20, alloc_addr@PAGE
    add x20, x20, alloc_addr@PAGEOFF
    ldr x20, [x20]
    cbz x20, fail_vm_allocate
    movz x21, #0x7788
    movk x21, #0x5566, lsl #16
    movk x21, #0x3344, lsl #32
    movk x21, #0x1122, lsl #48
    str x21, [x20]
    ldr x22, [x20]
    cmp x21, x22
    b.ne fail_vm_allocate
    adrp x0, msg_vm_allocate_ok@PAGE
    add x0, x0, msg_vm_allocate_ok@PAGEOFF
    mov x1, #27
    bl write_line

    adrp x1, map_addr@PAGE
    add x1, x1, map_addr@PAGEOFF
    mov x2, #0x1000
    mov x3, #0
    mov x4, #1
    mov x5, #3
    ldr w0, [x19]
    mov x16, #15
    svc #0x81
    cbnz x0, fail_vm_map
    adrp x20, map_addr@PAGE
    add x20, x20, map_addr@PAGEOFF
    ldr x20, [x20]
    cbz x20, fail_vm_map
    movz x21, #0xff00
    movk x21, #0xddcc, lsl #16
    movk x21, #0xbbaa, lsl #32
    movk x21, #0x9988, lsl #48
    str x21, [x20]
    ldr x22, [x20]
    cmp x21, x22
    b.ne fail_vm_map
    adrp x0, msg_vm_map_ok@PAGE
    add x0, x0, msg_vm_map_ok@PAGEOFF
    mov x1, #22
    bl write_line

    mov x16, #37
    svc #0x81
    cbz x0, fail_reply_port
    adrp x20, reply_port@PAGE
    add x20, x20, reply_port@PAGEOFF
    str w0, [x20]
    adrp x21, send_msg@PAGE
    add x21, x21, send_msg@PAGEOFF
    str w0, [x21, #8]

    mov x0, x21
    mov x1, #1
    mov x2, #32
    mov x3, #0
    mov x4, #0
    mov x5, #0
    mov x6, #0
    mov x16, #31
    svc #0x81
    cbnz x0, fail_mach_send
    adrp x0, msg_send_ok@PAGE
    add x0, x0, msg_send_ok@PAGEOFF
    mov x1, #29
    bl write_line

    adrp x0, send_msg@PAGE
    add x0, x0, send_msg@PAGEOFF
    mov x1, #0x102
    mov x2, #0
    mov x3, #64
    ldr w4, [x20]
    mov x5, #0
    mov x6, #0
    adrp x7, recv_msg@PAGE
    add x7, x7, recv_msg@PAGEOFF
    mov x16, #32
    svc #0x81
    cbnz x0, fail_mach_recv
    adrp x20, recv_msg@PAGE
    add x20, x20, recv_msg@PAGEOFF
    ldr w21, [x20, #20]
    movz w22, #0x4731
    movk w22, #0x4d53, lsl #16
    cmp w21, w22
    b.ne fail_mach_recv
    ldr x21, [x20, #24]
    adrp x22, send_payload@PAGE
    add x22, x22, send_payload@PAGEOFF
    ldr x22, [x22]
    cmp x21, x22
    b.ne fail_mach_recv
    adrp x0, msg_recv_ok@PAGE
    add x0, x0, msg_recv_ok@PAGEOFF
    mov x1, #32
    bl write_line

    adrp x0, msg_all_ok@PAGE
    add x0, x0, msg_all_ok@PAGEOFF
    mov x1, #19
    bl write_line
    mov x0, #0
    mov x16, #1
    svc #0x80

fail_task_self:
    adrp x0, msg_task_self_failed@PAGE
    add x0, x0, msg_task_self_failed@PAGEOFF
    mov x1, #29
    b fail_print
fail_vm_allocate:
    adrp x0, msg_vm_allocate_failed@PAGE
    add x0, x0, msg_vm_allocate_failed@PAGEOFF
    mov x1, #32
    b fail_print
fail_vm_map:
    adrp x0, msg_vm_map_failed@PAGE
    add x0, x0, msg_vm_map_failed@PAGEOFF
    mov x1, #27
    b fail_print
fail_reply_port:
    adrp x0, msg_reply_port_failed@PAGE
    add x0, x0, msg_reply_port_failed@PAGEOFF
    mov x1, #30
    b fail_print
fail_mach_send:
    adrp x0, msg_send_failed@PAGE
    add x0, x0, msg_send_failed@PAGEOFF
    mov x1, #34
    b fail_print
fail_mach_recv:
    adrp x0, msg_recv_failed@PAGE
    add x0, x0, msg_recv_failed@PAGEOFF
    mov x1, #37
    b fail_print

fail_print:
    bl write_line
    mov x0, #1
    mov x16, #1
    svc #0x80
1:  b 1b

write_line:
    mov x2, x1
    mov x1, x0
    mov x0, #1
    mov x16, #4
    svc #0x80
    ret

.section __DATA,__data
.align 3
task_port: .word 0
reply_port: .word 0
alloc_addr: .quad 0
map_addr: .quad 0
send_msg:
    .word 0
    .word 32
    .word 0
    .word 0
    .word 0
    .word 0x4d534731
send_payload:
    .quad 0x1122334455667788
recv_msg:
    .space 64

.section __TEXT,__const
msg_task_self_failed: .ascii "mach smoke: task_self failed\n"
msg_vm_allocate_failed: .ascii "mach smoke: vm_allocate failed\n"
msg_vm_map_failed: .ascii "mach smoke: vm_map failed\n"
msg_reply_port_failed: .ascii "mach smoke: reply_port failed\n"
msg_send_failed: .ascii "mach smoke: mach_msg send failed\n"
msg_recv_failed: .ascii "mach smoke: mach_msg receive failed\n"
msg_vm_allocate_ok: .ascii "mach smoke: vm_allocate ok\n"
msg_vm_map_ok: .ascii "mach smoke: vm_map ok\n"
msg_send_ok: .ascii "mach smoke: mach_msg send ok\n"
msg_recv_ok: .ascii "mach smoke: mach_msg receive ok\n"
msg_all_ok: .ascii "mach smoke: all ok\n"
