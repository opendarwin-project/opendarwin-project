// Scheduling test binary: prints a message a few times with a busy-wait
// spin between each, then exits. Built identically to hello.S; see that
// file's header comment for the build command (just swap the source name).

.section __TEXT,__text
.global _start
.align 4

_start:
    mov x19, #5              // iterations left

loop:
    mov x0, #1
    adrp x1, msg@PAGE
    add x1, x1, msg@PAGEOFF
    mov x2, #7                 // strlen("task B\n")
    mov x16, #4                // SYS_write
    svc #0x80

    mov x20, #0xffff
    lsl x20, x20, #5            // ~2M, busy-wait spin count
spin:
    subs x20, x20, #1
    b.ne spin

    subs x19, x19, #1
    b.ne loop

    mov x0, #0
    mov x16, #1                // SYS_exit
    svc #0x80

1:
    b 1b

.section __TEXT,__cstring
msg:
    .ascii "task B\n"
