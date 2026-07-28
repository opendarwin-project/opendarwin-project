//! Tiny leaf module (no kernel-internal imports) so both smp.zig and
//! exceptions.zig can call coreId() without a circular import between them.

pub fn coreId() u64 {
    const mpidr: u64 = asm volatile ("mrs %[v], mpidr_el1"
        : [v] "=r" (-> u64),
    );
    return mpidr & 0xff;
}
