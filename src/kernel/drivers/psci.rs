//! PSCI (Power State Coordination Interface) CPU_ON.
//!
//! Conduit differs by platform: QEMU `virt` emulates PSCI as EL2 firmware
//! reachable via `hvc` from the EL1 guest kernel it boots. Real hardware
//! (e.g. the Superbird's Amlogic G12A, `meson-g12a.dtsi`'s `psci { method =
//! "smc"; }`) implements PSCI in ARM Trusted Firmware BL31 at EL3, reachable
//! via `smc` - there is no resident EL2 firmware to field an `hvc` once
//! [`crate::arch::aarch64::cpu::drop_to_el1`] has landed at EL1.

const PSCI_CPU_ON: u64 = 0xC400_0003;

pub fn cpu_on_hvc(target_cpu: u64, entry_point: u64, context_id: u64) -> i64 {
    let ret: i64;
    unsafe {
        core::arch::asm!(
            "hvc #0",
            inout("x0") PSCI_CPU_ON => ret,
            in("x1") target_cpu,
            in("x2") entry_point,
            in("x3") context_id,
            options(nomem, nostack)
        );
    }
    ret
}

pub fn cpu_on_smc(target_cpu: u64, entry_point: u64, context_id: u64) -> i64 {
    let ret: i64;
    unsafe {
        core::arch::asm!(
            "smc #0",
            inout("x0") PSCI_CPU_ON => ret,
            in("x1") target_cpu,
            in("x2") entry_point,
            in("x3") context_id,
            options(nomem, nostack)
        );
    }
    ret
}

pub fn cpu_on(target_cpu: u64, entry_point: u64, context_id: u64) -> i64 {
    if crate::mm::mmu::kernel_load_addr() == 0x0200_0000 {
        cpu_on_smc(target_cpu, entry_point, context_id)
    } else {
        cpu_on_hvc(target_cpu, entry_point, context_id)
    }
}
