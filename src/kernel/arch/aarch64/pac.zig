//! Pointer Authentication (FEAT_PAuth) groundwork: feature detection, EL1
//! enable, and per-task key management. This does NOT make the kernel's
//! own code use return-address signing (that needs the kernel's build
//! target to have the `pauth` CPU feature, which cortex_a72 - our current
//! -mcpu - doesn't; a deliberate scope cut, see kmain.zig). It's aimed at
//! letting *userspace* (a future arm64e loader/binaries) use PAC.
//!
//! Every system register touched here (SCTLR_EL1 excepted, which is
//! ordinary/always-present) is accessed via its raw "S<op0>_<op1>_c<CRn>_
//! c<CRm>_<op2>" encoding rather than its symbolic name (e.g. apiakeylo_el1)
//! - the assembler gates symbolic pauth-register names on the target CPU
//! having the `pauth` feature, same as it would pacia/autia *instructions*,
//! but raw encoded MSR/MRS bypasses that check entirely since it's just
//! opaque bits to the assembler. This is the standard workaround (Linux's
//! arch/arm64 does the same for exactly this reason).

/// Reads ID_AA64ISAR1_EL1 and checks the APA/API fields (bits [7:4] and
/// [11:8]): nonzero in either means the CPU implements address
/// authentication (QARMA5 via APA, or an impdef algorithm via API - QEMU's
/// `-cpu max` reports API=0x5, APA=0x0, confirmed empirically since it's
/// easy to get these field positions swapped with the *generic*-auth GPA/
/// GPI fields at [27:24]/[31:28], which is exactly the bug this comment is
/// here to prevent re-introducing).
pub fn available() bool {
    const isar1: u64 = asm volatile ("mrs %[v], id_aa64isar1_el1"
        : [v] "=r" (-> u64),
    );
    const apa: u64 = (isar1 >> 4) & 0xf;
    const api: u64 = (isar1 >> 8) & 0xf;
    return apa != 0 or api != 0;
}

/// Sets SCTLR_EL1.{EnIA,EnIB,EnDA,EnDB}, permitting EL0 (and EL1) to
/// execute PAC*/AUT*/XPAC* instructions using all four key pairs without
/// trapping. Only meaningful if available() is true.
pub fn enable() void {
    var sctlr: u64 = asm volatile ("mrs %[v], sctlr_el1"
        : [v] "=r" (-> u64),
    );
    const EnDB: u64 = 1 << 13;
    const EnDA: u64 = 1 << 27;
    const EnIB: u64 = 1 << 30;
    const EnIA: u64 = 1 << 31;
    sctlr |= EnIA | EnIB | EnDA | EnDB;
    asm volatile ("msr sctlr_el1, %[v]"
        :
        : [v] "r" (sctlr),
    );
    asm volatile ("isb");
}

/// One task's worth of PAC key material: APIAKey/APIBKey (instruction
/// pointers - return addresses, function pointers) and APDAKey/APDBKey
/// (data pointers). APGAKey (generic authentication, used by PACGA for
/// CFI-style hashing rather than pointer signing) isn't needed yet.
pub const Keys = extern struct {
    ia_lo: u64,
    ia_hi: u64,
    ib_lo: u64,
    ib_hi: u64,
    da_lo: u64,
    da_hi: u64,
    db_lo: u64,
    db_hi: u64,
};

/// Deterministic, distinct-per-task key material via splitmix64. Not
/// cryptographically random - real per-process PAC keys should come from a
/// hardware RNG - but sufficient to prove keys are genuinely per-task
/// rather than shared, which is the actual groundwork question here.
pub fn deriveKeys(seed: u64) Keys {
    var s = seed;
    const next = struct {
        fn call(state: *u64) u64 {
            state.* +%= 0x9E3779B97F4A7C15;
            var z = state.*;
            z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
            z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
            return z ^ (z >> 31);
        }
    }.call;
    return .{
        .ia_lo = next(&s),
        .ia_hi = next(&s),
        .ib_lo = next(&s),
        .ib_hi = next(&s),
        .da_lo = next(&s),
        .da_hi = next(&s),
        .db_lo = next(&s),
        .db_hi = next(&s),
    };
}

/// Installs `keys` into this core's PAC key registers - must be called on
/// every switch to a different task, same as swapping TTBR0, since these
/// registers aren't banked per-task in hardware.
pub fn loadKeys(keys: *const Keys) void {
    asm volatile ("msr S3_0_c2_c1_0, %[v]"
        :
        : [v] "r" (keys.ia_lo),
    ); // APIAKeyLo_EL1
    asm volatile ("msr S3_0_c2_c1_1, %[v]"
        :
        : [v] "r" (keys.ia_hi),
    ); // APIAKeyHi_EL1
    asm volatile ("msr S3_0_c2_c1_2, %[v]"
        :
        : [v] "r" (keys.ib_lo),
    ); // APIBKeyLo_EL1
    asm volatile ("msr S3_0_c2_c1_3, %[v]"
        :
        : [v] "r" (keys.ib_hi),
    ); // APIBKeyHi_EL1
    asm volatile ("msr S3_0_c2_c2_0, %[v]"
        :
        : [v] "r" (keys.da_lo),
    ); // APDAKeyLo_EL1
    asm volatile ("msr S3_0_c2_c2_1, %[v]"
        :
        : [v] "r" (keys.da_hi),
    ); // APDAKeyHi_EL1
    asm volatile ("msr S3_0_c2_c2_2, %[v]"
        :
        : [v] "r" (keys.db_lo),
    ); // APDBKeyLo_EL1
    asm volatile ("msr S3_0_c2_c2_3, %[v]"
        :
        : [v] "r" (keys.db_hi),
    ); // APDBKeyHi_EL1
    asm volatile ("isb");
}
