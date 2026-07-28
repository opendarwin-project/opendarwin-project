//! PSCI (Power State Coordination Interface) CPU_ON, via HVC.
//!
//! Turns out necessary despite the flag+wfe/sev scheme in smp.zig/start.S:
//! QEMU virt's secondary vCPUs are NOT simply running-and-parked at reset
//! for a direct `-kernel` boot - they're genuinely powered off by QEMU, and
//! only PSCI CPU_ON actually starts them executing at all. The flag/wfe
//! mechanism is kept anyway: once a core is released via CPU_ON back into
//! `_start`, it still goes through the same wake-flag check, which by
//! construction is already true by then (see smp.zig's wakeSecondaries()),
//! so it just falls through immediately.
//!
//! SMC vs HVC: confirmed by dumping QEMU's generated DTB
//! (`-machine dumpdtb=...`) and checking the `/psci` node's `method`
//! property, rather than assuming - it's "hvc" for this machine/CPU
//! combination (SMC traps as an undefined instruction here: this CPU
//! config has no usable EL3 for our EL1-resident kernel to reach).

const PSCI_CPU_ON: u64 = 0xC400_0003; // matches the DTB's cpu_on function-id

/// `target_cpu` is an MPIDR affinity value (matches cpu.coreId()'s `& 0xff`
/// scheme on QEMU virt's default, thread/core-less topology).
/// `entry_point` is the physical address the new core starts executing at.
pub fn cpuOn(target_cpu: u64, entry_point: u64, context_id: u64) i64 {
    return asm volatile ("hvc #0"
        : [ret] "={x0}" (-> i64),
        : [fid] "{x0}" (PSCI_CPU_ON),
          [cpu] "{x1}" (target_cpu),
          [entry] "{x2}" (entry_point),
          [ctx] "{x3}" (context_id),
        : .{ .x0 = true, .x1 = true, .x2 = true, .x3 = true });
}
