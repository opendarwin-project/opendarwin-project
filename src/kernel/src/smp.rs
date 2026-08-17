//! Secondary-core bring-up and SMP management.

use crate::arch::aarch64::{cpu, exceptions, pac};
use crate::drivers::{gic, psci, timer, uart};
use crate::mm::mmu;
use crate::proc::sched;
use core::sync::atomic::{AtomicU64, Ordering};

pub const MAX_CPUS: u64 = 4;

#[unsafe(no_mangle)]
pub static smp_wake_flag: AtomicU64 = AtomicU64::new(0);

unsafe extern "C" {
    static _start: u8;
}

pub fn wake_secondaries() {
    smp_wake_flag.store(1, Ordering::Release);
    cpu::dsb_ish();
    cpu::sev();

    let entry = core::ptr::addr_of!(_start) as u64;
    for id in 1..MAX_CPUS {
        _ = psci::cpu_on(id, entry, 0);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn secondary_main(core_id: u64) -> ! {
    mmu::enable_for_this_core();
    exceptions::init();
    gic::init();
    gic::enable(timer::IRQ);
    timer::init(5);

    if pac::available() {
        pac::enable();
    }

    uart::print("opendarwin: secondary core online\n");
    cpu::unmask_irq();
    sched::run_core(core_id);
}
