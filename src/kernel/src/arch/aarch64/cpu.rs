//! Low-level CPU register and identity operations.

use aarch64_cpu::registers::{MPIDR_EL1, Readable};

#[inline(always)]
pub fn core_id() -> u64 {
    MPIDR_EL1.get() & 0xff
}

#[inline(always)]
pub fn unmask_irq() {
    unsafe {
        core::arch::asm!("msr daifclr, #2", options(nomem, nostack));
    }
}

#[inline(always)]
pub fn mask_irq() {
    unsafe {
        core::arch::asm!("msr daifset, #2", options(nomem, nostack));
    }
}

#[inline(always)]
pub fn wfe() {
    unsafe {
        core::arch::asm!("wfe", options(nomem, nostack));
    }
}

#[inline(always)]
pub fn sev() {
    unsafe {
        core::arch::asm!("sev", options(nomem, nostack));
    }
}

#[inline(always)]
pub fn dsb_ish() {
    unsafe {
        core::arch::asm!("dsb ish", options(nomem, nostack));
    }
}

#[inline(always)]
pub fn isb() {
    unsafe {
        core::arch::asm!("isb", options(nomem, nostack));
    }
}
