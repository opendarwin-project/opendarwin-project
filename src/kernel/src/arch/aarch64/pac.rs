//! Pointer Authentication (FEAT_PAuth) groundwork: feature detection, EL1
//! enable, and per-task key management.

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Keys {
    pub ia_lo: u64,
    pub ia_hi: u64,
    pub ib_lo: u64,
    pub ib_hi: u64,
    pub da_lo: u64,
    pub da_hi: u64,
    pub db_lo: u64,
    pub db_hi: u64,
}

pub fn available() -> bool {
    let isar1: u64;
    unsafe {
        core::arch::asm!("mrs {v}, id_aa64isar1_el1", v = out(reg) isar1, options(nomem, nostack));
    }
    let apa = (isar1 >> 4) & 0xf;
    let api = (isar1 >> 8) & 0xf;
    apa != 0 || api != 0
}

pub fn enable() {
    let mut sctlr: u64;
    unsafe {
        core::arch::asm!("mrs {v}, sctlr_el1", v = out(reg) sctlr, options(nomem, nostack));
    }
    const EN_DB: u64 = 1 << 13;
    const EN_DA: u64 = 1 << 27;
    const EN_IB: u64 = 1 << 30;
    const EN_IA: u64 = 1 << 31;
    sctlr |= EN_IA | EN_IB | EN_DA | EN_DB;
    unsafe {
        core::arch::asm!(
            "msr sctlr_el1, {v}",
            "isb",
            v = in(reg) sctlr,
            options(nomem, nostack)
        );
    }
}

pub fn set_enforcement(enable_it: bool) {
    let mut sctlr: u64;
    unsafe {
        core::arch::asm!("mrs {v}, sctlr_el1", v = out(reg) sctlr, options(nomem, nostack));
    }
    const EN_DB: u64 = 1 << 13;
    const EN_DA: u64 = 1 << 27;
    const EN_IB: u64 = 1 << 30;
    const EN_IA: u64 = 1 << 31;
    let mask = EN_IA | EN_IB | EN_DA | EN_DB;
    if enable_it {
        sctlr |= mask;
    } else {
        sctlr &= !mask;
    }
    unsafe {
        core::arch::asm!(
            "msr sctlr_el1, {v}",
            "isb",
            v = in(reg) sctlr,
            options(nomem, nostack)
        );
    }
}

pub fn derive_keys(seed: u64) -> Keys {
    let mut s = seed;
    let mut next = || {
        s = s.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = s;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    };
    Keys {
        ia_lo: next(),
        ia_hi: next(),
        ib_lo: next(),
        ib_hi: next(),
        da_lo: next(),
        da_hi: next(),
        db_lo: next(),
        db_hi: next(),
    }
}

pub fn load_keys(keys: &Keys) {
    unsafe {
        core::arch::asm!(
            "msr S3_0_c2_c1_0, {ia_lo}",
            "msr S3_0_c2_c1_1, {ia_hi}",
            "msr S3_0_c2_c1_2, {ib_lo}",
            "msr S3_0_c2_c1_3, {ib_hi}",
            "msr S3_0_c2_c2_0, {da_lo}",
            "msr S3_0_c2_c2_1, {da_hi}",
            "msr S3_0_c2_c2_2, {db_lo}",
            "msr S3_0_c2_c2_3, {db_hi}",
            "isb",
            ia_lo = in(reg) keys.ia_lo,
            ia_hi = in(reg) keys.ia_hi,
            ib_lo = in(reg) keys.ib_lo,
            ib_hi = in(reg) keys.ib_hi,
            da_lo = in(reg) keys.da_lo,
            da_hi = in(reg) keys.da_hi,
            db_lo = in(reg) keys.db_lo,
            db_hi = in(reg) keys.db_hi,
            options(nomem, nostack)
        );
    }
}
