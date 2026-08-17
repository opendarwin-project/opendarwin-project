//! PSCI (Power State Coordination Interface) CPU_ON via HVC.

const PSCI_CPU_ON: u64 = 0xC400_0003;

pub fn cpu_on(target_cpu: u64, entry_point: u64, context_id: u64) -> i64 {
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
