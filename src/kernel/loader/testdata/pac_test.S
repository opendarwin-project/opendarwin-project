// PAC groundwork test binary. paciasp/autiasp are HINT-space instructions
// (NOPs on non-PAC hardware), so this assembles and links fine via the
// same plain `clang -target arm64-apple-macos13` toolchain as the other
// test binaries - no arm64e target needed just to emit them.
//
// Calls a signed-return-address subroutine (the standard ARM64E function
// idiom: paciasp at entry, autiasp before ret), then writes a message
// proving the call/return round-tripped correctly under our kernel's PAC
// key programming, and exits.

.section __TEXT,__text
.global _start
.align 4

_start:
    paciasp
    stp fp, lr, [sp, #-16]!
    mov fp, sp

    bl signed_subroutine

    ldp fp, lr, [sp], #16
    autiasp

    mov x0, #1
    adrp x1, msg@PAGE
    add x1, x1, msg@PAGEOFF
    mov x2, #44 // strlen(msg)
    mov x16, #4 // SYS_write
    svc #0x80

    mov x0, #0
    mov x16, #1 // SYS_exit
    svc #0x80

1:
    b 1b

signed_subroutine:
    paciasp
    stp fp, lr, [sp, #-16]!
    mov fp, sp

    // Body deliberately trivial - the point is the signed call/return
    // itself, not what happens inside it.
    mov x9, #42

    ldp fp, lr, [sp], #16
    autiasp
    ret

.section __TEXT,__cstring
msg:
    .ascii "pac roundtrip ok, nested call signed+authed\n"
