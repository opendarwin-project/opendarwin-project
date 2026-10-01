//! VPU power domain gating via AO sysctrl ("rti") on Amlogic Meson G12A.
//!
//! Ported from `drivers/pmdomain/amlogic/meson-ee-pwrc.c`.

use super::hhi::Hhi;
use super::regs::{mdelay, modify32, udelay, write32};
use super::reset::{Reset, VPU_RESETS};

const AO_RTI_GEN_PWR_SLEEP0: usize = 0x3a << 2;
const AO_RTI_GEN_PWR_ISO0: usize = 0x3b << 2;
const VPU_SLEEP_BIT: u32 = 1 << 8;
const VPU_ISO_BIT: u32 = 1 << 9;

const HHI_MEM_PD_REG0: usize = 0x40 << 2;
const HHI_VPU_MEM_PD_REG0: usize = 0x41 << 2;
const HHI_VPU_MEM_PD_REG1: usize = 0x42 << 2;
const HHI_VPU_MEM_PD_REG2: usize = 0x4d << 2;
const HHI_MEM_PD_REG0_VPU_MASK: u32 = 0xff00;

pub struct Pwrc {
    ao_sysctrl_base: usize,
}

impl Pwrc {
    pub const unsafe fn new(ao_sysctrl_base: usize) -> Self {
        Self { ao_sysctrl_base }
    }

    pub fn vpu_power_on(&self, hhi: &Hhi, reset: &Reset) {
        unsafe {
            modify32(
                self.ao_sysctrl_base + AO_RTI_GEN_PWR_SLEEP0,
                VPU_SLEEP_BIT,
                0,
            )
        };
        udelay(20);

        unsafe {
            write32(hhi.base() + HHI_VPU_MEM_PD_REG0, 0);
            write32(hhi.base() + HHI_VPU_MEM_PD_REG1, 0);
            write32(hhi.base() + HHI_VPU_MEM_PD_REG2, 0);
            modify32(hhi.base() + HHI_MEM_PD_REG0, HHI_MEM_PD_REG0_VPU_MASK, 0);
        }
        udelay(20);

        for &id in VPU_RESETS {
            reset.assert(id);
        }

        unsafe { modify32(self.ao_sysctrl_base + AO_RTI_GEN_PWR_ISO0, VPU_ISO_BIT, 0) };

        for &id in VPU_RESETS {
            reset.deassert(id);
        }
        mdelay(1);

        hhi.vpu_clk_init();
    }
}
