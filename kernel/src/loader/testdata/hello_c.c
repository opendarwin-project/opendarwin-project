extern long syscall(long n, long a1, const void *a2, long a3);

__attribute__((noreturn)) void start(void) {
    syscall(4, 1, "hello from C via opendarwin\n", 29);
    syscall(1, 0, (const void *)0, 0);
    __builtin_unreachable();
}
