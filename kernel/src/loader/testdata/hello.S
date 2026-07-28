// Milestone-1 userspace test binary. Static, no dyld, no libc: uses the BSD
// syscall convention directly (x16 = syscall number, args in x0-x2,
// `svc #0x80`), matching ref/syscalls.master's numbering.
//
// write(1, msg, msg_len); exit(0);
//
// Built as a standalone Mach-O via:
//   clang -target arm64-apple-macos13 -static -nostdlib -e _start \
//         -o hello hello.S

.section __TEXT,__text
.global _start
.align 4

_start:
    mov x0, #1              // fd = stdout
    adrp x1, msg@PAGE
    add x1, x1, msg@PAGEOFF // buf = &msg
    mov x2, #15              // nbyte = strlen("hello from EL0\n")
    mov x16, #4              // SYS_write
    svc #0x80

    mov x0, #0               // rval = 0
    mov x16, #1              // SYS_exit
    svc #0x80

    // Should be unreachable; spin if exit somehow returns.
1:
    b 1b

.section __TEXT,__cstring
msg:
    .ascii "hello from EL0\n"
