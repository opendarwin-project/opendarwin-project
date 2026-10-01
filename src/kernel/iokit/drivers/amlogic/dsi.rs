//! MIPI DSI host: Amlogic TOP wrapper + Synopsys DesignWare DSI core.
//!
//! Ported from `drivers/gpu/drm/meson/meson_dw_mipi_dsi.c` and
//! `drivers/gpu/drm/bridge/synopsys/dw-mipi-dsi.c`.

use super::regs::{modify32, read32, udelay, write32};
use super::reset::{RESET_MIPI_DSI_HOST, Reset};
use super::venc::Mode;

const TOP_SW_RESET: usize = 0x3c0;
const TOP_CLK_CNTL: usize = 0x3c4;
const TOP_CNTL: usize = 0x3c8;
const TOP_MEM_PD: usize = 0x3f4;

const DPI_COLOR_24BIT: u32 = 5;
const VENC_IN_COLOR_24B: u32 = 1;
const TOP_CNTL_SYNC_INVERT: u32 = (1 << 4) | (1 << 5);

const PWR_UP: usize = 0x04;
const CLKMGR_CFG: usize = 0x08;
const DPI_VCID: usize = 0x0c;
const DPI_COLOR_CODING: usize = 0x10;
const DPI_CFG_POL: usize = 0x14;
const DPI_LP_CMD_TIM: usize = 0x18;
const PCKHDL_CFG: usize = 0x2c;
const MODE_CFG: usize = 0x34;
const VID_MODE_CFG: usize = 0x38;
const VID_PKT_SIZE: usize = 0x3c;
const VID_HSA_TIME: usize = 0x48;
const VID_HBP_TIME: usize = 0x4c;
const VID_HLINE_TIME: usize = 0x50;
const VID_VSA_LINES: usize = 0x54;
const VID_VBP_LINES: usize = 0x58;
const VID_VFP_LINES: usize = 0x5c;
const VID_VACTIVE_LINES: usize = 0x60;
const CMD_MODE_CFG: usize = 0x68;
const TO_CNT_CFG: usize = 0x78;
const BTA_TO_CNT: usize = 0x8c;
const LPCLK_CTRL: usize = 0x94;
const PHY_TMR_LPCLK_CFG: usize = 0x98;
const PHY_TMR_CFG: usize = 0x9c;
const PHY_IF_CFG: usize = 0xa4;
const VERSION: usize = 0x00;

const GEN_HDR: usize = 0x6c;
const GEN_PLD_DATA: usize = 0x70;
const CMD_PKT_STATUS: usize = 0x74;

const GEN_CMD_FULL: u32 = 1 << 1;
const GEN_PLD_W_FULL: u32 = 1 << 3;

const DCS_SHORT_WRITE: u8 = 0x05;
const DCS_SHORT_WRITE_PARAM: u8 = 0x15;
const DCS_LONG_WRITE: u8 = 0x39;

const RESET: u32 = 0;
const POWERUP: u32 = 1 << 0;
const ENABLE_CMD_MODE: u32 = 1 << 0;
const ENABLE_VIDEO_MODE: u32 = 0;
const VID_MODE_TYPE_BURST: u32 = 0x2;
const ENABLE_LOW_POWER: u32 = 0x3f << 8;
const DPI_COLOR_CODING_24BIT: u32 = 0x5;
const CMD_MODE_ALL_LP: u32 = (1 << 24)
    | (1 << 19)
    | (1 << 18)
    | (1 << 17)
    | (1 << 16)
    | (1 << 14)
    | (1 << 13)
    | (1 << 12)
    | (1 << 11)
    | (1 << 10)
    | (1 << 9)
    | (1 << 8);
const HWVER_131: u32 = 0x3133_3100;

#[derive(Debug, Clone, Copy)]
pub struct PhyTiming {
    pub data_hs2lp: u32,
    pub data_lp2hs: u32,
    pub clk_hs2lp: u32,
    pub clk_lp2hs: u32,
}

pub const DEFAULT_PHY_TIMING: PhyTiming = PhyTiming {
    data_hs2lp: 0x14,
    data_lp2hs: 0x45,
    clk_hs2lp: 0x3c,
    clk_lp2hs: 0x48,
};

pub struct Dsi {
    base: usize,
}

impl Dsi {
    pub const unsafe fn new(base: usize) -> Self {
        Self { base }
    }

    pub fn base(&self) -> usize {
        self.base
    }

    fn reg(&self, offset: usize) -> usize {
        self.base + offset
    }

    pub fn top_hw_init(&self) {
        unsafe {
            modify32(self.reg(TOP_SW_RESET), 0, 0xf);
            modify32(self.reg(TOP_SW_RESET), 0xf, 0);
            modify32(self.reg(TOP_CLK_CNTL), 0, 0x3);
            write32(self.reg(TOP_MEM_PD), 0);

            write32(
                self.reg(TOP_CNTL),
                (DPI_COLOR_24BIT << 20)
                    | (VENC_IN_COLOR_24B << 16)
                    | (2 << 12)
                    | (1 << 10)
                    | TOP_CNTL_SYNC_INVERT,
            );
        }
    }

    pub fn init(
        &self,
        reset: &Reset,
        lane_mbps: u32,
        lanes: u32,
        mode: &Mode,
        phy_timing: &PhyTiming,
    ) {
        reset.assert(RESET_MIPI_DSI_HOST);
        reset.deassert(RESET_MIPI_DSI_HOST);

        unsafe {
            write32(self.reg(PWR_UP), RESET);

            let esc_div = (lane_mbps >> 3) / 4 + 1;
            write32(self.reg(CLKMGR_CFG), esc_div & 0xff);

            write32(self.reg(DPI_VCID), 0);
            write32(self.reg(DPI_COLOR_CODING), DPI_COLOR_CODING_24BIT);
            write32(self.reg(DPI_CFG_POL), 0);

            write32(
                self.reg(PCKHDL_CFG),
                (1 << 4) | (1 << 3) | (1 << 2) | (1 << 0),
            );

            write32(self.reg(VID_PKT_SIZE), mode.hdisplay & 0x3fff);

            write32(self.reg(TO_CNT_CFG), 0);
            write32(self.reg(BTA_TO_CNT), 0xd00);
            write32(self.reg(MODE_CFG), ENABLE_CMD_MODE);
            write32(self.reg(CMD_MODE_CFG), CMD_MODE_ALL_LP);
            write32(self.reg(DPI_LP_CMD_TIM), (16 << 16) | 4);

            self.horizontal_vertical_timing(mode);

            let hw_version = read32(self.reg(VERSION));
            if hw_version >= HWVER_131 {
                write32(
                    self.reg(PHY_TMR_CFG),
                    ((phy_timing.data_hs2lp & 0x3ff) << 16) | (phy_timing.data_lp2hs & 0x3ff),
                );
            } else {
                write32(
                    self.reg(PHY_TMR_CFG),
                    ((phy_timing.data_hs2lp & 0xff) << 24)
                        | ((phy_timing.data_lp2hs & 0xff) << 16)
                        | 10000,
                );
            }
            write32(
                self.reg(PHY_TMR_LPCLK_CFG),
                ((phy_timing.clk_hs2lp & 0x3ff) << 16) | (phy_timing.clk_lp2hs & 0x3ff),
            );
            write32(self.reg(PHY_IF_CFG), (0x20 << 8) | ((lanes - 1) & 0x3));

            write32(self.reg(LPCLK_CTRL), 1 << 0);
            write32(self.reg(PWR_UP), POWERUP);
        }
    }

    fn hcomponent_lbcc(&self, lane_mbps: u32, mode: &Mode, hcomponent: u32) -> u32 {
        let numerator = (hcomponent as u64) * (lane_mbps as u64) * 1000 / 8;
        let clock = mode.clock_khz as u64;
        numerator.div_ceil(clock) as u32
    }

    fn horizontal_vertical_timing(&self, mode: &Mode) {
        let hsa = mode.hsync_end - mode.hsync_start;
        let hbp = mode.htotal - mode.hsync_end;
        let lane_mbps = ((mode.clock_khz as u64) * 24 / 1000 / 2) as u32;

        unsafe {
            write32(
                self.reg(VID_HLINE_TIME),
                self.hcomponent_lbcc(lane_mbps, mode, mode.htotal),
            );
            write32(
                self.reg(VID_HSA_TIME),
                self.hcomponent_lbcc(lane_mbps, mode, hsa),
            );
            write32(
                self.reg(VID_HBP_TIME),
                self.hcomponent_lbcc(lane_mbps, mode, hbp),
            );

            write32(self.reg(VID_VACTIVE_LINES), mode.vdisplay);
            write32(self.reg(VID_VSA_LINES), mode.vsync_end - mode.vsync_start);
            write32(self.reg(VID_VFP_LINES), mode.vsync_start - mode.vdisplay);
            write32(self.reg(VID_VBP_LINES), mode.vtotal - mode.vsync_end);
        }
    }

    pub fn switch_to_video_mode(&self) {
        unsafe {
            write32(self.reg(PWR_UP), RESET);
            write32(self.reg(MODE_CFG), ENABLE_VIDEO_MODE);
            write32(
                self.reg(VID_MODE_CFG),
                ENABLE_LOW_POWER | VID_MODE_TYPE_BURST,
            );
            write32(self.reg(LPCLK_CTRL), (1 << 0) | (1 << 1));
            write32(self.reg(PWR_UP), POWERUP);
        }
    }

    // --- DCS Command Helpers ---

    fn poll_status(&self, mask: u32, want_set: bool) -> bool {
        for _ in 0..20_000 {
            let val = unsafe { read32(self.reg(CMD_PKT_STATUS)) };
            if (val & mask != 0) == want_set {
                return true;
            }
            udelay(1);
        }
        false
    }

    pub fn dcs_write(&self, cmd: u8, params: &[u8]) {
        match params.len() {
            0 => {
                let hdr = (cmd as u32) << 8 | (DCS_SHORT_WRITE as u32);
                self.gen_pkt_hdr_write(hdr);
            }
            1 => {
                let hdr = ((params[0] as u32) << 16)
                    | ((cmd as u32) << 8)
                    | (DCS_SHORT_WRITE_PARAM as u32);
                self.gen_pkt_hdr_write(hdr);
            }
            _ => {
                let mut data = [0u8; 64];
                data[0] = cmd;
                let n = params.len().min(63);
                data[1..=n].copy_from_slice(&params[..n]);
                let len = n + 1;

                let chunks = (len + 3) / 4;
                for i in 0..chunks {
                    self.poll_status(GEN_PLD_W_FULL, false);
                    let off = i * 4;
                    let mut word = 0u32;
                    for b in 0..4 {
                        if off + b < len {
                            word |= (data[off + b] as u32) << (b * 8);
                        }
                    }
                    unsafe { write32(self.reg(GEN_PLD_DATA), word) };
                }

                let hdr = ((len as u32) << 8) | (DCS_LONG_WRITE as u32);
                self.gen_pkt_hdr_write(hdr);
            }
        }
    }

    fn gen_pkt_hdr_write(&self, hdr: u32) {
        self.poll_status(GEN_CMD_FULL, false);
        unsafe { write32(self.reg(GEN_HDR), hdr) };
    }
}
