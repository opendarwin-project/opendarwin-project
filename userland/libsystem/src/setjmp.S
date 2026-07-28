// aarch64 Darwin setjmp/longjmp (musl-derived, Apple jmp_buf layout compatible).
// oksh only calls sigsetjmp(..., 0), so signal-mask handling is omitted.

.global _setjmp
.global setjmp
.global _sigsetjmp
.global sigsetjmp
.global _longjmp
.global longjmp
.global _siglongjmp
.global siglongjmp

_setjmp:
setjmp:
_sigsetjmp:
sigsetjmp:
    stp x19, x20, [x0, #0]
    stp x21, x22, [x0, #16]
    stp x23, x24, [x0, #32]
    stp x25, x26, [x0, #48]
    stp x27, x28, [x0, #64]
    stp x29, x30, [x0, #80]
    mov x2, sp
    str x2, [x0, #104]
    stp d8, d9, [x0, #112]
    stp d10, d11, [x0, #128]
    stp d12, d13, [x0, #144]
    stp d14, d15, [x0, #160]
    mov w0, #0
    ret

_longjmp:
longjmp:
_siglongjmp:
siglongjmp:
    mov x2, x0
    mov x0, x1
    ldp x19, x20, [x2, #0]
    ldp x21, x22, [x2, #16]
    ldp x23, x24, [x2, #32]
    ldp x25, x26, [x2, #48]
    ldp x27, x28, [x2, #64]
    ldp x29, x30, [x2, #80]
    ldr x3, [x2, #104]
    mov sp, x3
    ldp d8, d9, [x2, #112]
    ldp d10, d11, [x2, #128]
    ldp d12, d13, [x2, #144]
    ldp d14, d15, [x2, #160]
    cmp w0, #0
    csinc w0, w0, wzr, ne
    ret
