//! MMIO register access and hardware timer delays for Amlogic Meson G12A.

/// Reads a 32-bit MMIO register.
#[inline]
pub unsafe fn read32(addr: usize) -> u32 {
    unsafe { core::ptr::read_volatile(addr as *const u32) }
}

/// Writes a 32-bit MMIO register.
#[inline]
pub unsafe fn write32(addr: usize, value: u32) {
    unsafe { core::ptr::write_volatile(addr as *mut u32, value) };
}

/// Read-modify-write: clears `clear_mask` then sets `set_mask`.
#[inline]
pub unsafe fn modify32(addr: usize, clear_mask: u32, set_mask: u32) {
    let value = unsafe { read32(addr) };
    unsafe { write32(addr, (value & !clear_mask) | set_mask) };
}

/// Busy-waits for approximately `us` microseconds using the ARM generic timer.
pub fn udelay(us: u64) {
    let freq: u64;
    let start: u64;
    unsafe {
        core::arch::asm!("mrs {0}, cntfrq_el0", out(reg) freq, options(nomem, nostack));
        core::arch::asm!("mrs {0}, cntpct_el0", out(reg) start, options(nomem, nostack));
    }
    if freq == 0 {
        return;
    }
    let ticks = (freq / 1_000_000).max(1) * us;
    loop {
        let now: u64;
        unsafe {
            core::arch::asm!("mrs {0}, cntpct_el0", out(reg) now, options(nomem, nostack));
        }
        if now.wrapping_sub(start) >= ticks {
            break;
        }
        core::hint::spin_loop();
    }
}

/// Busy-waits for approximately `ms` milliseconds.
pub fn mdelay(ms: u64) {
    udelay(ms * 1000);
}
