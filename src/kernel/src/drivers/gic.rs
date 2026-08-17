//! ARM Generic Interrupt Controller (GICv2) driver.

use core::sync::atomic::{AtomicU64, Ordering};

pub const BOOTSTRAP_DIST_BASE: u64 = 0x0800_0000;
pub const BOOTSTRAP_CPU_BASE: u64 = 0x0801_0000;
pub const MMIO_LEN: u64 = 0x0002_0000;

// GICD register offsets
const GICD_CTLR: usize = 0x000;
const GICD_ISENABLER: usize = 0x100;
const GICD_ITARGETSR: usize = 0x800;

// GICC register offsets
const GICC_CTLR: usize = 0x000;
const GICC_PMR: usize = 0x004;
const GICC_IAR: usize = 0x00C;
const GICC_EOIR: usize = 0x010;

static DIST_BASE: AtomicU64 = AtomicU64::new(BOOTSTRAP_DIST_BASE);
static CPU_BASE: AtomicU64 = AtomicU64::new(BOOTSTRAP_CPU_BASE);

pub fn set_bases(dist: u64, cpu: u64) {
    DIST_BASE.store(dist, Ordering::Release);
    CPU_BASE.store(cpu, Ordering::Release);
}

pub fn init() {
    let dist = DIST_BASE.load(Ordering::Acquire);
    let cpu = CPU_BASE.load(Ordering::Acquire);

    unsafe {
        // Enable distributor (Group 0 & Group 1)
        let gicd_ctlr = (dist + GICD_CTLR as u64) as *mut u32;
        core::ptr::write_volatile(gicd_ctlr, 3);

        // Set CPU interface Priority Mask Register to allow all priorities
        let gicc_pmr = (cpu + GICC_PMR as u64) as *mut u32;
        core::ptr::write_volatile(gicc_pmr, 0xff);

        // Enable CPU interface (Group 0 & Group 1)
        let gicc_ctlr = (cpu + GICC_CTLR as u64) as *mut u32;
        core::ptr::write_volatile(gicc_ctlr, 3);
    }
}

pub fn enable(irq: u32) {
    let dist = DIST_BASE.load(Ordering::Acquire);
    let reg_idx = (irq / 32) as usize;
    let bit_idx = (irq % 32) as u32;

    unsafe {
        let gicd_isenabler = (dist + (GICD_ISENABLER + reg_idx * 4) as u64) as *mut u32;
        core::ptr::write_volatile(gicd_isenabler, 1 << bit_idx);

        // Set target CPU for SPIs (IRQs >= 32)
        if irq >= 32 {
            let target_reg = (dist + (GICD_ITARGETSR + (irq as usize & !3)) as u64) as *mut u32;
            let shift = (irq % 4) * 8;
            let mut val = core::ptr::read_volatile(target_reg);
            val |= 0x01 << shift; // Route to CPU 0
            core::ptr::write_volatile(target_reg, val);
        }
    }
}

pub fn claim() -> Option<u32> {
    let cpu = CPU_BASE.load(Ordering::Acquire);
    unsafe {
        let gicc_iar = (cpu + GICC_IAR as u64) as *const u32;
        let iar = core::ptr::read_volatile(gicc_iar);
        let irq = iar & 0x3ff;
        if irq >= 1020 {
            None // Spurious
        } else {
            Some(irq)
        }
    }
}

pub fn complete(irq: u32) {
    let cpu = CPU_BASE.load(Ordering::Acquire);
    unsafe {
        let gicc_eoir = (cpu + GICC_EOIR as u64) as *mut u32;
        core::ptr::write_volatile(gicc_eoir, irq);
    }
}
