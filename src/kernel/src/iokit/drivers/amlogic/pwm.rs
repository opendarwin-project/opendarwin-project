//! `pwm_ef` channel B (backlight) driver on Amlogic Meson G12A.
//!
//! Ported from `drivers/pwm/pwm-meson.c`.

use super::pinctrl::Pinctrl;
use super::regs::{modify32, write32};

const REG_PWM_B: usize = 0x04;
const REG_MISC_AB: usize = 0x08;

const MISC_B_CLK_EN: u32 = 1 << 23;
const MISC_B_CLK_SEL_SHIFT: u32 = 6;
const MISC_B_CLK_SEL_MASK: u32 = 0x3 << MISC_B_CLK_SEL_SHIFT;
const CLK_SEL_XTAL: u32 = 0;
const MISC_B_EN: u32 = 1 << 1;

const XTAL_HZ: u64 = 24_000_000;
const PERIOD_NS: u64 = 30_040;
const DUTY_PERCENT: u64 = 50;

pub struct Pwm {
    base: usize,
}

impl Pwm {
    pub const unsafe fn new(base: usize) -> Self {
        Self { base }
    }

    pub fn backlight_enable(&self, pinctrl: &Pinctrl) {
        let period_ticks = (PERIOD_NS * XTAL_HZ).div_ceil(1_000_000_000);
        let hi = (period_ticks * DUTY_PERCENT / 100) as u32;
        let lo = (period_ticks - hi as u64) as u32;

        unsafe {
            write32(self.base + REG_PWM_B, (hi << 16) | (lo & 0xffff));
            modify32(
                self.base + REG_MISC_AB,
                MISC_B_CLK_SEL_MASK,
                (CLK_SEL_XTAL << MISC_B_CLK_SEL_SHIFT) & MISC_B_CLK_SEL_MASK,
            );
            modify32(self.base + REG_MISC_AB, 0, MISC_B_CLK_EN | MISC_B_EN);
        }

        pinctrl.backlight_enable_init();
        pinctrl.backlight_enable_set(true);
    }
}
