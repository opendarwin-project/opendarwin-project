//! Amlogic CBUS reset controller (`amlogic,meson-axg-reset`).

use super::regs::{modify32, write32};

const PULSE_OFFSET: usize = 0x0;
const LEVEL_OFFSET: usize = 0x7c;

pub const RESET_VIU: u32 = 5;
pub const RESET_VENC: u32 = 10;
pub const RESET_VCBUS: u32 = 13;
pub const RESET_BT656: u32 = 37;
pub const RESET_RDMA: u32 = 133;
pub const RESET_VENCI: u32 = 134;
pub const RESET_VENCP: u32 = 135;
pub const RESET_VDAC: u32 = 137;
pub const RESET_VDI6: u32 = 140;
pub const RESET_VENCL: u32 = 141;
pub const RESET_VID_LOCK: u32 = 231;
pub const RESET_MIPI_DSI_HOST: u32 = 68;
pub const RESET_MIPI_DSI_PHY: u32 = 130;

pub const VPU_RESETS: &[u32] = &[
    RESET_VIU,
    RESET_VENC,
    RESET_VCBUS,
    RESET_BT656,
    RESET_RDMA,
    RESET_VENCI,
    RESET_VENCP,
    RESET_VDAC,
    RESET_VDI6,
    RESET_VENCL,
    RESET_VID_LOCK,
];

pub struct Reset {
    base: usize,
}

impl Reset {
    pub const unsafe fn new(base: usize) -> Self {
        Self { base }
    }

    fn addr_bit(&self, bank_offset: usize, id: u32) -> (usize, u32) {
        let offset = (id / 32) as usize * 4;
        let bit = id % 32;
        (self.base + bank_offset + offset, bit)
    }

    pub fn assert(&self, id: u32) {
        let (addr, bit) = self.addr_bit(LEVEL_OFFSET, id);
        unsafe { modify32(addr, 1 << bit, 0) };
    }

    pub fn deassert(&self, id: u32) {
        let (addr, bit) = self.addr_bit(LEVEL_OFFSET, id);
        unsafe { modify32(addr, 0, 1 << bit) };
    }

    pub fn pulse(&self, id: u32) {
        let (addr, bit) = self.addr_bit(PULSE_OFFSET, id);
        unsafe { write32(addr, 1 << bit) };
    }
}
