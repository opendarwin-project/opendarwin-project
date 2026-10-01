//! ARM generic physical timer (EL1 non-secure physical timer, CNTP_*).

use core::sync::atomic::{AtomicU64, Ordering};

pub const IRQ: u32 = 30;

static TICKS_PER_PERIOD: AtomicU64 = AtomicU64::new(0);
static PERIOD_MS_CURRENT: AtomicU64 = AtomicU64::new(0);
static MONOTONIC_MS: AtomicU64 = AtomicU64::new(0);

pub fn init(period_ms: u64) {
    let freq: u64;
    unsafe {
        core::arch::asm!("mrs {v}, cntfrq_el0", v = out(reg) freq, options(nomem, nostack));
    }
    let ticks = (freq * period_ms) / 1000;
    TICKS_PER_PERIOD.store(ticks, Ordering::Relaxed);
    PERIOD_MS_CURRENT.store(period_ms, Ordering::Relaxed);

    rearm();

    unsafe {
        core::arch::asm!("msr cntp_ctl_el0, {v}", v = in(reg) 1u64, options(nomem, nostack));
    }
}

pub fn rearm() {
    let ticks = TICKS_PER_PERIOD.load(Ordering::Relaxed);
    unsafe {
        core::arch::asm!("msr cntp_tval_el0, {v}", v = in(reg) ticks, options(nomem, nostack));
    }
}

pub fn account_tick() {
    let period = PERIOD_MS_CURRENT.load(Ordering::Relaxed);
    MONOTONIC_MS.fetch_add(period, Ordering::Relaxed);
}

pub fn now_ms() -> u64 {
    MONOTONIC_MS.load(Ordering::Relaxed)
}
