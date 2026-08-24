//! HHI/HIU syscon: clocks, PLLs, and analog MIPI D-PHY on Amlogic Meson G12A.
//!
//! Ported from `drivers/clk/meson/g12a.c`, `drivers/clk/meson/clk-pll.c`,
//! and `drivers/phy/amlogic/phy-meson-g12a-mipi-dphy-analog.c`.

use super::regs::{mdelay, modify32, read32, udelay, write32};

const XTAL_HZ: u64 = 24_000_000;

const GP0_PLL_CNTL0: usize = 0x40;
const GP0_PLL_CNTL1: usize = 0x44;
const GP0_PLL_CNTL2: usize = 0x48;
const GP0_PLL_CNTL3: usize = 0x4c;
const GP0_PLL_CNTL4: usize = 0x50;
const GP0_PLL_CNTL5: usize = 0x54;
const GP0_PLL_CNTL6: usize = 0x58;

const GP0_PLL_M_MASK: u32 = 0xff;
const GP0_PLL_N_SHIFT: u32 = 10;
const GP0_PLL_N_MASK: u32 = 0x1f << GP0_PLL_N_SHIFT;
const GP0_PLL_OD_SHIFT: u32 = 16;
const GP0_PLL_OD_MASK: u32 = 0x7 << GP0_PLL_OD_SHIFT;
const GP0_PLL_EN: u32 = 1 << 28;
const GP0_PLL_RST: u32 = 1 << 29;
const GP0_PLL_LOCK: u32 = 1 << 31;
const GP0_PLL_FRAC_MASK: u32 = 0x1_ffff;
const GP0_PLL_FRAC_MAX: u64 = 1 << 17;
const GP0_PLL_M_MIN: u64 = 125;
const GP0_PLL_M_MAX: u64 = 255;

struct PllSolution {
    m: u32,
    od: u32,
    frac: u32,
}

#[derive(Debug, Clone, Copy)]
pub struct Gp0PllResult {
    pub target_hz: u64,
    pub m: u32,
    pub od: u32,
    pub frac: u32,
    pub locked: bool,
}

fn gp0_pll_solve(target_hz: u64) -> Option<PllSolution> {
    for od in 0..8 {
        let dco = target_hz * (1 << od);
        let m = dco / XTAL_HZ;
        if m < GP0_PLL_M_MIN || m > GP0_PLL_M_MAX {
            continue;
        }
        let rem = dco - m * XTAL_HZ;
        let frac = (rem * GP0_PLL_FRAC_MAX + XTAL_HZ / 2) / XTAL_HZ;
        return Some(PllSolution {
            m: m as u32,
            od: od as u32,
            frac: (frac as u32) & (GP0_PLL_FRAC_MASK as u32),
        });
    }
    None
}

const VPU_0_SEL_FCLK_DIV3: u32 = 0;
const VAPB_0_SEL_FCLK_DIV4: u32 = 0;

const VPU_CLK_CNTL: usize = 0x1bc;
const VAPBCLK_CNTL: usize = 0x1f4;

const VIID_CLK_DIV: usize = 0x128;
const VIID_CLK_CNTL: usize = 0x12c;
const VID_CLK_CNTL2: usize = 0x194;

const VCLK2_SEL_GP0_PLL: u32 = 1;
const CTS_ENCL_SEL_VCLK2_DIV1: u32 = 8;

const MIPI_CNTL0: usize = 0x00;
const MIPI_CNTL1: usize = 0x04;
const MIPI_CNTL2: usize = 0x08;

const DPHY_CH_EN_2LANE: u32 = (1 << 2) | (1 << 4) | (1 << 3);

pub struct Hhi {
    base: usize,
}

impl Hhi {
    pub const unsafe fn new(base: usize) -> Self {
        Self { base }
    }

    pub fn base(&self) -> usize {
        self.base
    }

    fn reg(&self, offset: usize) -> usize {
        self.base + offset
    }

    pub fn gp0_pll_set(&self, target_hz: u64) -> Gp0PllResult {
        let sol = gp0_pll_solve(target_hz).expect("no GP0_PLL solution for target rate");

        unsafe {
            modify32(self.reg(GP0_PLL_CNTL0), 0, GP0_PLL_RST);
            write32(self.reg(GP0_PLL_CNTL1), 0x0000_0000);
            write32(self.reg(GP0_PLL_CNTL2), 0x0000_0000);
            write32(self.reg(GP0_PLL_CNTL3), 0x4868_1c00);
            write32(self.reg(GP0_PLL_CNTL4), 0x3377_1290);
            write32(self.reg(GP0_PLL_CNTL5), 0x3927_2000);
            write32(self.reg(GP0_PLL_CNTL6), 0x5654_0000);
            modify32(self.reg(GP0_PLL_CNTL0), GP0_PLL_RST, 0);

            modify32(
                self.reg(GP0_PLL_CNTL0),
                GP0_PLL_M_MASK | GP0_PLL_N_MASK | GP0_PLL_OD_MASK,
                sol.m | (1 << GP0_PLL_N_SHIFT) | (sol.od << GP0_PLL_OD_SHIFT),
            );
            modify32(self.reg(GP0_PLL_CNTL1), GP0_PLL_FRAC_MASK, sol.frac);

            modify32(self.reg(GP0_PLL_CNTL0), 0, GP0_PLL_RST);
            modify32(self.reg(GP0_PLL_CNTL0), 0, GP0_PLL_EN);
            modify32(self.reg(GP0_PLL_CNTL0), GP0_PLL_RST, 0);

            let mut locked = false;
            for _ in 0..5000 {
                if read32(self.reg(GP0_PLL_CNTL0)) & GP0_PLL_LOCK != 0 {
                    locked = true;
                    break;
                }
                udelay(20);
            }
            Gp0PllResult {
                target_hz,
                m: sol.m,
                od: sol.od,
                frac: sol.frac,
                locked,
            }
        }
    }

    pub fn vpu_clk_init(&self) {
        unsafe {
            modify32(
                self.reg(VPU_CLK_CNTL),
                (0x7 << 9) | 0x7f | (1 << 8) | (1 << 31),
                (VPU_0_SEL_FCLK_DIV3 << 9) | (1 << 8),
            );

            modify32(
                self.reg(VAPBCLK_CNTL),
                (0x3 << 9) | 0x7f | (1 << 8) | (1 << 31) | (1 << 30),
                (VAPB_0_SEL_FCLK_DIV4 << 9) | (1 << 0) | (1 << 8) | (1 << 30),
            );
        }
        mdelay(1);
    }

    pub fn vclk2_encl_chain(&self, div: u32) {
        unsafe {
            modify32(self.reg(VIID_CLK_CNTL), 0x7 << 16, VCLK2_SEL_GP0_PLL << 16);

            modify32(
                self.reg(VIID_CLK_DIV),
                0xff | (1 << 16) | (1 << 17),
                1 << 17,
            );
            modify32(self.reg(VIID_CLK_DIV), 0xff, div - 1);
            modify32(self.reg(VIID_CLK_DIV), 1 << 17, 0);
            modify32(self.reg(VIID_CLK_DIV), 0, 1 << 16);

            modify32(self.reg(VIID_CLK_CNTL), 1 << 15, 1 << 19);
            modify32(self.reg(VIID_CLK_CNTL), 0, 1 << 0);

            modify32(
                self.reg(VIID_CLK_DIV),
                0xf << 12,
                CTS_ENCL_SEL_VCLK2_DIV1 << 12,
            );
            modify32(self.reg(VID_CLK_CNTL2), 0, 1 << 3);
        }
    }

    pub fn mipi_analog_dphy_init(&self) {
        unsafe {
            write32(self.reg(MIPI_CNTL0), 0x8 | (0xa487 << 16));
            write32(self.reg(MIPI_CNTL1), 0x2e | (1 << 16));
            write32(self.reg(MIPI_CNTL2), 0x45a | (0x2680 << 16));
            modify32(self.reg(MIPI_CNTL2), 0x1f << 11, DPHY_CH_EN_2LANE << 11);
        }
    }
}
