//! ARM generic timer (EL1 non-secure physical timer, CNTP_*), wired to
//! GICv2 PPI 30 on QEMU virt. No conduit driver exists for this - it's a
//! system-register interface (CNTP_TVAL_EL0/CNTP_CTL_EL0/CNTFRQ_EL0), not
//! MMIO, so conduit's Mmio-based driver model doesn't apply here.

pub const IRQ: u32 = 30;

var ticks_per_period: u64 = 0;
var period_ms_current: u64 = 0;
var monotonic_ms: u64 = 0;

/// Starts the timer with a period of `period_ms` milliseconds, firing IRQ
/// 30 each time it expires. Must be called after gic.enable(IRQ).
pub fn init(period_ms: u64) void {
    const freq: u64 = asm volatile ("mrs %[v], cntfrq_el0"
        : [v] "=r" (-> u64),
    );
    ticks_per_period = (freq * period_ms) / 1000;
    period_ms_current = period_ms;
    rearm();
    // CNTP_CTL_EL0: bit0 ENABLE=1, bit1 IMASK=0 (don't mask at the timer
    // itself - masking happens via DAIF/GIC as usual), bit2 ISTATUS is
    // read-only.
    asm volatile ("msr cntp_ctl_el0, %[v]"
        :
        : [v] "r" (@as(u64, 1)),
    );
}

/// Reprograms the timer to fire again one period from now. Call after
/// handling each timer IRQ.
pub fn rearm() void {
    asm volatile ("msr cntp_tval_el0, %[v]"
        :
        : [v] "r" (ticks_per_period),
    );
}

/// Account for one delivered periodic tick. Called from the IRQ handler before
/// scheduler wakeups inspect deadlines.
pub fn accountTick() void {
    monotonic_ms +%= period_ms_current;
}

pub fn nowMs() u64 {
    return monotonic_ms;
}
