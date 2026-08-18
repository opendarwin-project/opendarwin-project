//! VPP mux, DMC canvas LUT, and VIU OSD1 for Amlogic Meson G12A.
//!
//! Ported from `drivers/soc/amlogic/meson-canvas.c`, `drivers/gpu/drm/meson/meson_plane.c`,
//! and `drivers/gpu/drm/meson/meson_vpp.c`.

use super::regs::{read32, write32};

const VPU_VIU_VENC_MUX_CTRL: usize = 0x271a;
const VIU_VPP_MUX_ENCL: u32 = 0x0;

const DMC_CAV_LUT_DATAL: usize = 0x00;
const DMC_CAV_LUT_DATAH: usize = 0x04;
const DMC_CAV_LUT_ADDR: usize = 0x08;
const CANVAS_LUT_WR_EN: u32 = 1 << 9;
const CANVAS_LUT_RD_EN: u32 = 1 << 8;

const VIU_OSD1_CTRL_STAT: usize = 0x1a10;
const VIU_OSD1_BLK0_CFG_W0: usize = 0x1a1b;
const VIU_OSD1_BLK0_CFG_W1: usize = 0x1a1c;
const VIU_OSD1_BLK0_CFG_W2: usize = 0x1a1d;
const VIU_OSD1_BLK0_CFG_W3: usize = 0x1a1e;
const VIU_OSD1_BLK0_CFG_W4: usize = 0x1a13;

const OSD_ENABLE: u32 = 1 << 21;
const OSD_BLK0_ENABLE: u32 = 1 << 0;
const OSD_GLOBAL_ALPHA_SHIFT: u32 = 12;
const OSD_CANVAS_SEL: u32 = 16;
const OSD_ENDIANNESS_LE: u32 = 1 << 15;
const OSD_BLK_MODE_32: u32 = 0x05 << 8;
const OSD_COLOR_MATRIX_32_ARGB: u32 = 0x01 << 2;

/// A canvas LUT entry: where a scanout buffer lives and how it is strided.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Canvas {
    pub addr: usize,
    pub stride: u32,
    pub height: u32,
}

/// The pixel format OSD1 is scanning out.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OsdFormat {
    Rgb565,
    Xrgb8888,
    Rgb888,
    Unknown(u32),
}

impl OsdFormat {
    pub fn bytes_per_pixel(&self) -> usize {
        match self {
            OsdFormat::Rgb565 => 2,
            OsdFormat::Xrgb8888 => 4,
            OsdFormat::Rgb888 => 3,
            OsdFormat::Unknown(_) => 4,
        }
    }
}

/// The live OSD1 scanout configuration left behind by the bootloader.
#[derive(Debug, Clone, Copy)]
pub struct Osd1State {
    pub canvas_index: u32,
    pub format: OsdFormat,
    pub width: u32,
    pub height: u32,
    pub enabled: bool,
}

/// Handle to the VPU/VCBUS register block plus DMC/canvas LUT.
pub struct Vpu {
    base: usize,
    canvas_base: usize,
}

impl Vpu {
    pub const unsafe fn new(base: usize, canvas_base: usize) -> Self {
        Self { base, canvas_base }
    }

    pub fn base(&self) -> usize {
        self.base
    }

    fn reg(&self, word: usize) -> usize {
        self.base + word * 4
    }

    pub fn vpp_mux_encl(&self) {
        unsafe { write32(self.reg(VPU_VIU_VENC_MUX_CTRL), VIU_VPP_MUX_ENCL) };
    }

    pub fn canvas_read(&self, index: u32) -> Canvas {
        unsafe {
            write32(
                self.canvas_base + DMC_CAV_LUT_ADDR,
                CANVAS_LUT_RD_EN | index,
            );
            let datal = read32(self.canvas_base + DMC_CAV_LUT_DATAL);
            let datah = read32(self.canvas_base + DMC_CAV_LUT_DATAH);
            let addr = ((datal & 0x1fff_ffff) as usize) << 3;
            let stride8 = ((datal >> 29) & 0x7) | ((datah & 0x1ff) << 3);
            Canvas {
                addr,
                stride: stride8 * 8,
                height: (datah >> 9) & 0x1fff,
            }
        }
    }

    pub fn osd1_read_state(&self) -> Osd1State {
        unsafe {
            let w0 = read32(self.reg(VIU_OSD1_BLK0_CFG_W0));
            let w1 = read32(self.reg(VIU_OSD1_BLK0_CFG_W1));
            let w2 = read32(self.reg(VIU_OSD1_BLK0_CFG_W2));
            let stat = read32(self.reg(VIU_OSD1_CTRL_STAT));
            let format = match (w0 >> 8) & 0xf {
                0x4 => OsdFormat::Rgb565,
                0x5 => OsdFormat::Xrgb8888,
                0x7 => OsdFormat::Rgb888,
                other => OsdFormat::Unknown(other),
            };
            Osd1State {
                canvas_index: (w0 >> OSD_CANVAS_SEL) & 0xff,
                format,
                width: ((w1 >> 16) & 0x1fff) + 1,
                height: ((w2 >> 16) & 0x1fff) + 1,
                enabled: stat & OSD_ENABLE != 0,
            }
        }
    }

    pub fn canvas_config(&self, index: u32, addr: usize, stride_bytes: u32, height: u32) {
        let stride8 = (stride_bytes + 7) >> 3;
        unsafe {
            write32(
                self.canvas_base + DMC_CAV_LUT_DATAL,
                (((addr as u32) + 7) >> 3) | (stride8 << 29),
            );
            write32(
                self.canvas_base + DMC_CAV_LUT_DATAH,
                (stride8 >> 3) | (height << 9),
            );
            write32(
                self.canvas_base + DMC_CAV_LUT_ADDR,
                CANVAS_LUT_WR_EN | index,
            );
            let _ = read32(self.canvas_base + DMC_CAV_LUT_DATAH);
        }
    }

    pub fn osd1_show(&self, canvas_index: u32, width: u32, height: u32) {
        let cfg_w0 = (canvas_index << OSD_CANVAS_SEL)
            | OSD_ENDIANNESS_LE
            | OSD_BLK_MODE_32
            | OSD_COLOR_MATRIX_32_ARGB;
        let span_w = (width - 1) << 16;
        let span_h = (height - 1) << 16;

        unsafe {
            write32(self.reg(VIU_OSD1_BLK0_CFG_W0), cfg_w0);
            write32(self.reg(VIU_OSD1_BLK0_CFG_W1), span_w);
            write32(self.reg(VIU_OSD1_BLK0_CFG_W2), span_h);
            write32(self.reg(VIU_OSD1_BLK0_CFG_W3), span_w);
            write32(self.reg(VIU_OSD1_BLK0_CFG_W4), span_h);
            write32(
                self.reg(VIU_OSD1_CTRL_STAT),
                OSD_ENABLE | OSD_BLK0_ENABLE | (0x100 << OSD_GLOBAL_ALPHA_SHIFT),
            );
        }
    }

    pub fn fill_solid(&self, fb_addr: usize, width: u32, height: u32, argb: u32) {
        let pixels = (width as usize) * (height as usize);
        let bytes = pixels * 4;
        unsafe {
            let ptr = fb_addr as *mut u32;
            for i in 0..pixels {
                core::ptr::write_volatile(ptr.add(i), argb);
            }
        }
        clean_dcache_range(fb_addr, bytes);
    }

    pub fn fill_rows_rgb565(&self, fb: &Canvas, y0: u32, y1: u32, width: u32, color: u16) {
        let stride = fb.stride as usize;
        for y in y0..y1 {
            let row = fb.addr + (y as usize) * stride;
            unsafe {
                let ptr = row as *mut u16;
                for x in 0..width as usize {
                    core::ptr::write_volatile(ptr.add(x), color);
                }
            }
        }
        let start = fb.addr + (y0 as usize) * stride;
        clean_dcache_range(start, ((y1 - y0) as usize) * stride);
    }
}

pub const fn rgb565(r: u8, g: u8, b: u8) -> u16 {
    (((r as u16) >> 3) << 11) | (((g as u16) >> 2) << 5) | ((b as u16) >> 3)
}

pub fn clean_dcache_range(addr: usize, len: usize) {
    const LINE: usize = 64;
    let start = addr & !(LINE - 1);
    let end = (addr + len + LINE - 1) & !(LINE - 1);
    let mut line = start;
    while line < end {
        unsafe {
            core::arch::asm!("dc cvac, {0}", in(reg) line, options(nostack));
        }
        line += LINE;
    }
    unsafe {
        core::arch::asm!("dsb sy", options(nomem, nostack));
    }
}
