//! Secondary-core bring-up.
//!
//! Boot model: QEMU virt's `-kernel` boot starts every vCPU executing at
//! the same entry point simultaneously (no firmware, no PSCI CPU_ON
//! needed) - which is exactly why start.S already parks non-primary cores
//! in a wfe loop. So instead of PSCI, secondary cores are released by the
//! primary setting a flag and issuing `sev`; each parked core wakes,
//! rechecks the flag, and if set, proceeds through its own (per-core: FP
//! enable, SCTLR.A clear, stack, MMU) bring-up before calling into
//! secondaryMain below. See start.S's secondary-core path.

const mmu = @import("mm/mmu.zig");
const exceptions = @import("arch/aarch64/exceptions.zig");
const gic = @import("drivers/gic.zig");
const timer = @import("drivers/timer.zig");
const uart = @import("drivers/uart.zig");
const sched = @import("proc/sched.zig");
const cpu = @import("arch/aarch64/cpu.zig");
const psci = @import("drivers/psci.zig");

extern const _start: u8;

pub const MAX_CPUS: u64 = 4;

/// Read from start.S's park loop (a plain scalar 8-byte load - safe even
/// pre-MMU, see mmu.zig's module doc comment on why only *wide* pre-MMU
/// accesses are the hazard) and written once by wakeSecondaries() below.
export var smp_wake_flag: u64 = 0;

pub const coreId = cpu.coreId;

/// Called by the primary core once kernel_root, the GIC/timer, and all
/// tasks are ready. Sets the wake flag first (so any core PSCI actually
/// releases lands straight past start.S's flag check with no race), then
/// PSCI CPU_ON's every other possible core ID - QEMU virt's secondary
/// vCPUs are genuinely powered off at reset for a direct `-kernel` boot,
/// not just running-and-parked, so this (not wfe/sev alone) is what
/// actually starts them. IDs beyond what `-smp` was given just get a
/// harmless PSCI error back, which is ignored: there's no DTB/CPU-count
/// discovery yet to know the real count ahead of time.
pub fn wakeSecondaries() void {
    @atomicStore(u64, &smp_wake_flag, 1, .release);
    asm volatile ("dsb ish");
    asm volatile ("sev");

    const entry: u64 = @intFromPtr(&_start);
    var id: u64 = 1;
    while (id < MAX_CPUS) : (id += 1) {
        _ = psci.cpuOn(id, entry, 0);
    }
}

/// Called from start.S once a secondary core has its own stack set up
/// (x0 = this core's ID, from MPIDR_EL1). Never returns.
export fn secondaryMain(core_id: u64) callconv(.c) noreturn {
    // Per-core system registers (TTBR0/TCR/MAIR/SCTLR): kernel_root itself
    // was already built once by the primary, just reused here.
    mmu.enableForThisCore();

    exceptions.init();
    gic.init(); // per-core CPU-interface enable; distributor re-enable is idempotent
    // PPI enable bits (IDs 0-31, including the timer's) are banked per-CPU
    // in the distributor, unlike SPIs - kmain.zig's gic.enable(timer.IRQ)
    // only took effect for core 0, so every secondary core repeats it here
    // for itself.
    gic.enable(timer.IRQ);
    timer.init(5);

    uart.print("opendarwin: secondary core online\n");

    // Unmask IRQ at EL1 (see kmain.zig's matching call for the primary -
    // PSTATE.I's reset value on a core starting directly at EL1 isn't
    // architecturally guaranteed clear).
    asm volatile ("msr daifclr, #2");

    sched.runCore(core_id);
}
