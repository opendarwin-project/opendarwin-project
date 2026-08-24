//! ENCL (Video Encoder timing generator for MIPI DSI / LCD panels) on Amlogic Meson G12A.
//!
//! Ported from `drivers/gpu/drm/meson/meson_venc.c`.

use super::regs::write32;
use super::vpu::Vpu;

const ENCL_TST_EN: usize = 0x1c98;
const ENCL_TST_MDSEL: usize = 0x1c99;
const ENCL_TST_Y: usize = 0x1c9a;
const ENCL_TST_CB: usize = 0x1c9b;
const ENCL_TST_CR: usize = 0x1c9c;
const ENCL_VIDEO_EN: usize = 0x1ca0;
const ENCL_VIDEO_MODE: usize = 0x1ca7;
const ENCL_VIDEO_MODE_ADV: usize = 0x1ca8;
const ENCL_VIDEO_MAX_PXCNT: usize = 0x1cb0;
const ENCL_VIDEO_HAVON_END: usize = 0x1cb1;
const ENCL_VIDEO_HAVON_BEGIN: usize = 0x1cb2;
const ENCL_VIDEO_VAVON_ELINE: usize = 0x1cb3;
const ENCL_VIDEO_VAVON_BLINE: usize = 0x1cb4;
const ENCL_VIDEO_HSO_BEGIN: usize = 0x1cb5;
const ENCL_VIDEO_HSO_END: usize = 0x1cb6;
const ENCL_VIDEO_VSO_BEGIN: usize = 0x1cb7;
const ENCL_VIDEO_VSO_END: usize = 0x1cb8;
const ENCL_VIDEO_VSO_BLINE: usize = 0x1cb9;
const ENCL_VIDEO_VSO_ELINE: usize = 0x1cba;
const ENCL_VIDEO_MAX_LNCNT: usize = 0x1cbb;
const ENCL_VIDEO_FILT_CTRL: usize = 0x1cc2;
const ENCL_VIDEO_RGBIN_CTRL: usize = 0x1cc7;

const ENCL_PX_LN_CNT_SHADOW_EN: u32 = 1 << 15;
const ENCL_VIDEO_MODE_ADV_VFIFO_EN: u32 = 1 << 3;
const ENCL_VIDEO_MODE_ADV_GAIN_HDTV: u32 = 1 << 4;
const ENCL_SEL_GAMMA_RGB_IN: u32 = 1 << 10;
const ENCL_VIDEO_FILT_CTRL_BYPASS_FILTER: u32 = 1 << 12;
const ENCL_VIDEO_RGBIN_RGB: u32 = 1 << 0;
const ENCL_VIDEO_RGBIN_ZBLK: u32 = 1 << 1;

const L_OEH_HS_ADDR: usize = 0x1418;
const L_OEH_HE_ADDR: usize = 0x1419;
const L_OEH_VS_ADDR: usize = 0x141a;
const L_OEH_VE_ADDR: usize = 0x141b;
const L_OEV1_HS_ADDR: usize = 0x142f;
const L_OEV1_HE_ADDR: usize = 0x1430;
const L_OEV1_VS_ADDR: usize = 0x1431;
const L_OEV1_VE_ADDR: usize = 0x1432;
const L_STH1_HS_ADDR: usize = 0x1410;
const L_STH1_HE_ADDR: usize = 0x1411;
const L_STH1_VS_ADDR: usize = 0x1412;
const L_STH1_VE_ADDR: usize = 0x1413;
const L_STV1_HS_ADDR: usize = 0x1427;
const L_STV1_HE_ADDR: usize = 0x1428;
const L_STV1_VS_ADDR: usize = 0x1429;
const L_STV1_VE_ADDR: usize = 0x142a;
const L_DE_HS_ADDR: usize = 0x1451;
const L_DE_HE_ADDR: usize = 0x1452;
const L_DE_VS_ADDR: usize = 0x1453;
const L_DE_VE_ADDR: usize = 0x1454;
const L_HSYNC_HS_ADDR: usize = 0x1455;
const L_HSYNC_HE_ADDR: usize = 0x1456;
const L_HSYNC_VS_ADDR: usize = 0x1457;
const L_HSYNC_VE_ADDR: usize = 0x1458;
const L_VSYNC_HS_ADDR: usize = 0x1459;
const L_VSYNC_HE_ADDR: usize = 0x145a;
const L_VSYNC_VS_ADDR: usize = 0x145b;
const L_VSYNC_VE_ADDR: usize = 0x145c;
const L_RGB_BASE_ADDR: usize = 0x1405;
const L_RGB_COEFF_ADDR: usize = 0x1406;
const L_DITH_CNTL_ADDR: usize = 0x1408;
const L_DITH_CNTL_DITH10_EN: u32 = 1 << 10;
const L_INV_CNT_ADDR: usize = 0x1440;
const L_TCON_MISC_SEL_ADDR: usize = 0x1441;
const L_TCON_MISC_SEL_STV1: u32 = 1 << 4;
const L_TCON_MISC_SEL_STV2: u32 = 1 << 5;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Mode {
    pub clock_khz: u32,
    pub hdisplay: u32,
    pub hsync_start: u32,
    pub hsync_end: u32,
    pub htotal: u32,
    pub vdisplay: u32,
    pub vsync_start: u32,
    pub vsync_end: u32,
    pub vtotal: u32,
}

pub const SUPERBIRD_MODE: Mode = Mode {
    clock_khz: 31979,
    hdisplay: 480,
    hsync_start: 480 + 90,
    hsync_end: 480 + 90 + 10,
    htotal: 480 + 90 + 10 + 50,
    vdisplay: 800,
    vsync_start: 800 + 20,
    vsync_end: 800 + 20 + 20,
    vtotal: 800 + 20 + 20 + 6,
};

pub struct Venc {
    base: usize,
}

impl Venc {
    pub const unsafe fn new(base: usize) -> Self {
        Self { base }
    }

    fn reg(&self, word: usize) -> usize {
        self.base + word * 4
    }

    pub fn mode_set(&self, mode: &Mode, vpu: &Vpu) {
        let max_pxcnt = mode.htotal - 1;
        let max_lncnt = mode.vtotal - 1;
        let havon_begin = mode.htotal - mode.hsync_start;
        let havon_end = havon_begin + mode.hdisplay - 1;
        let vavon_bline = mode.vtotal - mode.vsync_start;
        let vavon_eline = vavon_bline + mode.vdisplay - 1;
        let hso_begin = 0u32;
        let hso_end = mode.hsync_end - mode.hsync_start;
        let vso_begin = 0u32;
        let vso_end = 0u32;
        let vso_bline = 0u32;
        let vso_eline = mode.vsync_end - mode.vsync_start;

        vpu.vpp_mux_encl();

        unsafe {
            write32(self.reg(ENCL_VIDEO_EN), 0);

            write32(self.reg(ENCL_VIDEO_MODE), ENCL_PX_LN_CNT_SHADOW_EN);
            write32(
                self.reg(ENCL_VIDEO_MODE_ADV),
                ENCL_VIDEO_MODE_ADV_VFIFO_EN
                    | ENCL_VIDEO_MODE_ADV_GAIN_HDTV
                    | ENCL_SEL_GAMMA_RGB_IN,
            );

            write32(
                self.reg(ENCL_VIDEO_FILT_CTRL),
                ENCL_VIDEO_FILT_CTRL_BYPASS_FILTER,
            );
            write32(self.reg(ENCL_VIDEO_MAX_PXCNT), max_pxcnt);
            write32(self.reg(ENCL_VIDEO_MAX_LNCNT), max_lncnt);
            write32(self.reg(ENCL_VIDEO_HAVON_BEGIN), havon_begin);
            write32(self.reg(ENCL_VIDEO_HAVON_END), havon_end);
            write32(self.reg(ENCL_VIDEO_VAVON_BLINE), vavon_bline);
            write32(self.reg(ENCL_VIDEO_VAVON_ELINE), vavon_eline);

            write32(self.reg(ENCL_VIDEO_HSO_BEGIN), hso_begin);
            write32(self.reg(ENCL_VIDEO_HSO_END), hso_end);
            write32(self.reg(ENCL_VIDEO_VSO_BEGIN), vso_begin);
            write32(self.reg(ENCL_VIDEO_VSO_END), vso_end);
            write32(self.reg(ENCL_VIDEO_VSO_BLINE), vso_bline);
            write32(self.reg(ENCL_VIDEO_VSO_ELINE), vso_eline);
            write32(
                self.reg(ENCL_VIDEO_RGBIN_CTRL),
                ENCL_VIDEO_RGBIN_RGB | ENCL_VIDEO_RGBIN_ZBLK,
            );

            write32(self.reg(ENCL_TST_MDSEL), 0);
            write32(self.reg(ENCL_TST_Y), 0);
            write32(self.reg(ENCL_TST_CB), 0);
            write32(self.reg(ENCL_TST_CR), 0);
            write32(self.reg(ENCL_TST_EN), 1);
            write32(
                self.reg(ENCL_VIDEO_MODE_ADV),
                ENCL_VIDEO_MODE_ADV_GAIN_HDTV | ENCL_SEL_GAMMA_RGB_IN,
            );

            write32(self.reg(ENCL_VIDEO_EN), 1);

            write32(self.reg(L_RGB_BASE_ADDR), 0);
            write32(self.reg(L_RGB_COEFF_ADDR), 0x400);
            write32(self.reg(L_DITH_CNTL_ADDR), L_DITH_CNTL_DITH10_EN);

            write32(self.reg(L_OEH_HS_ADDR), havon_begin);
            write32(self.reg(L_OEH_HE_ADDR), havon_end + 1);
            write32(self.reg(L_OEH_VS_ADDR), vavon_bline);
            write32(self.reg(L_OEH_VE_ADDR), vavon_eline);

            write32(self.reg(L_OEV1_HS_ADDR), havon_begin);
            write32(self.reg(L_OEV1_HE_ADDR), havon_end + 1);
            write32(self.reg(L_OEV1_VS_ADDR), vavon_bline);
            write32(self.reg(L_OEV1_VE_ADDR), vavon_eline);

            write32(self.reg(L_STH1_HS_ADDR), hso_end);
            write32(self.reg(L_STH1_HE_ADDR), hso_begin);
            write32(self.reg(L_STH1_VS_ADDR), 0);
            write32(self.reg(L_STH1_VE_ADDR), max_lncnt);

            write32(self.reg(L_STV1_HS_ADDR), vso_begin);
            write32(self.reg(L_STV1_HE_ADDR), vso_end);
            write32(self.reg(L_STV1_VS_ADDR), vso_eline);
            write32(self.reg(L_STV1_VE_ADDR), vso_bline);

            write32(self.reg(L_DE_HS_ADDR), havon_begin);
            write32(self.reg(L_DE_HE_ADDR), havon_end + 1);
            write32(self.reg(L_DE_VS_ADDR), vavon_bline);
            write32(self.reg(L_DE_VE_ADDR), vavon_eline);

            write32(self.reg(L_HSYNC_HS_ADDR), hso_begin);
            write32(self.reg(L_HSYNC_HE_ADDR), hso_end);
            write32(self.reg(L_HSYNC_VS_ADDR), 0);
            write32(self.reg(L_HSYNC_VE_ADDR), max_lncnt);

            write32(self.reg(L_VSYNC_HS_ADDR), vso_begin);
            write32(self.reg(L_VSYNC_HE_ADDR), vso_end);
            write32(self.reg(L_VSYNC_VS_ADDR), vso_bline);
            write32(self.reg(L_VSYNC_VE_ADDR), vso_eline);

            write32(self.reg(L_INV_CNT_ADDR), 0);
            write32(
                self.reg(L_TCON_MISC_SEL_ADDR),
                L_TCON_MISC_SEL_STV1 | L_TCON_MISC_SEL_STV2,
            );
        }
    }
}
