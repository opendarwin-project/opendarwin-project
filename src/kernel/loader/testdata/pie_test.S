// PIE test binary: has an absolute pointer in __DATA that needs rebasing
// when loaded at a different address than the vmaddr. Built as a non-PIE
// static binary, then post-processed by make_pie.py to add MH_PIE flag and
// LC_DYLD_INFO_ONLY with rebase opcodes.

.section __TEXT,__text
.global _start
.align 4
_start:
    mov x0, #1             // fd = stdout
    adrp x1, _msg_ptr@PAGE
    add x1, x1, _msg_ptr@PAGEOFF
    ldr x1, [x1]           // x1 = *msg_ptr (absolute address of msg, rebased)
    mov x2, #17            // len
    mov x16, #4            // SYS_write
    svc #0x80

    mov x0, #0             // exit code = 0
    mov x16, #1            // SYS_exit
    svc #0x80

1:  b 1b

.section __DATA,__data
.align 3
_msg_ptr:
    .quad _msg              // Absolute pointer to msg — REBASE TARGET

.section __TEXT,__cstring
_msg:
    .ascii "hello from PIE\n"
