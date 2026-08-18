//! Digital MIPI D-PHY wrapper (`amlogic,axg-mipi-dphy`).
//!
//! Ported from `drivers/phy/amlogic/phy-meson-axg-mipi-dphy.c`.

use super::regs::{modify32, write32};
use super::reset::{RESET_MIPI_DSI_PHY, Reset};

const PHY_CTRL: usize = 0x00;
const CHAN_CTRL: usize = 0x04;
const CLK_TIM: usize = 0x0c;
const HS_TIM: usize = 0x10;
const LP_TIM: usize = 0x14;
const ANA_UP_TIM: usize = 0x18;
const INIT_TIM: usize = 0x1c;
const WAKEUP_TIM: usize = 0x20;
const LPOK_TIM: usize = 0x24;
const LP_WCHDOG: usize = 0x28;
const CLK_TIM1: usize = 0x30;
const TURN_WCHDOG: usize = 0x34;
const ULPS_CHECK: usize = 0x38;

fn div_round_up(a: u64, b: u64) -> u64 {
    a.div_ceil(b)
}

pub struct Dphy {
    base: usize,
}

impl Dphy {
    pub const unsafe fn new(base: usize) -> Self {
        Self { base }
    }

    fn reg(&self, offset: usize) -> usize {
        self.base + offset
    }

    pub fn init(&self, reset: &Reset) {
        reset.pulse(RESET_MIPI_DSI_PHY);
    }

    pub fn power_on(&self, hs_clk_rate_hz: u64, lanes: u32) {
        let ui = div_round_up(1_000_000_000_000, hs_clk_rate_hz);

        let clk_post = 60_000 + 52 * ui;
        let clk_prepare = 38_000u64;
        let clk_zero = 262_000u64;
        let clk_trail = 60_000u64;
        let clk_pre = 8u64;
        let hs_exit = 100_000u64;
        let hs_prepare = 40_000 + 4 * ui;
        let hs_zero = 105_000 + 6 * ui;
        let hs_trail = core::cmp::max(4 * 8 * ui, 60_000 + 4 * 4 * ui);
        let lpx = 50_000u64;
        let ta_sure = lpx;
        let ta_go = 4 * lpx;
        let ta_get = 5 * lpx;
        let init_us = 100u64;
        let wakeup_us = 1000u64;

        let temp = (100_000_000 / (hs_clk_rate_hz / 1000)) * 8 * 10;

        unsafe {
            write32(self.reg(PHY_CTRL), 0x1);
            write32(self.reg(PHY_CTRL), (1 << 0) | (1 << 7) | (1 << 8));
            modify32(self.reg(PHY_CTRL), 0, 1 << 9);
            modify32(self.reg(PHY_CTRL), 0, 1 << 12);
            modify32(self.reg(PHY_CTRL), 0, 1 << 31);
            modify32(self.reg(PHY_CTRL), 1 << 31, 0);

            write32(
                self.reg(CLK_TIM),
                div_round_up(clk_trail, temp) as u32
                    | (div_round_up(clk_post + hs_trail, temp) as u32) << 8
                    | (div_round_up(clk_zero, temp) as u32) << 16
                    | (div_round_up(clk_prepare, temp) as u32) << 24,
            );
            write32(self.reg(CLK_TIM1), div_round_up(clk_pre, 8) as u32);

            write32(
                self.reg(HS_TIM),
                div_round_up(hs_exit, temp) as u32
                    | (div_round_up(hs_trail, temp) as u32) << 8
                    | (div_round_up(hs_zero, temp) as u32) << 16
                    | (div_round_up(hs_prepare, temp) as u32) << 24,
            );

            write32(
                self.reg(LP_TIM),
                div_round_up(lpx, temp) as u32
                    | (div_round_up(ta_sure, temp) as u32) << 8
                    | (div_round_up(ta_go, temp) as u32) << 16
                    | (div_round_up(ta_get, temp) as u32) << 24,
            );

            write32(self.reg(ANA_UP_TIM), 0x0100);
            write32(
                self.reg(INIT_TIM),
                div_round_up(init_us * 1_000_000, temp) as u32,
            );
            write32(
                self.reg(WAKEUP_TIM),
                div_round_up(wakeup_us * 1_000_000, temp) as u32,
            );
            write32(self.reg(LPOK_TIM), 0x7c);
            write32(self.reg(ULPS_CHECK), 0x927c);
            write32(self.reg(LP_WCHDOG), 0x1000);
            write32(self.reg(TURN_WCHDOG), 0x1000);

            let chan_ctrl = match lanes {
                1 => 0xe,
                2 => 0xc,
                3 => 0x8,
                _ => 0x0,
            };
            write32(self.reg(CHAN_CTRL), chan_ctrl);

            modify32(self.reg(PHY_CTRL), 0, 1 << 1);
        }
    }
}
