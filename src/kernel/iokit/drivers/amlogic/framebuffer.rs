//! Amlogic Meson G12A IOFramebuffer driver matching Darwin IOKit/graphics/IOFramebuffer.h.
//!
//! Subclasses `IOFramebuffer`, matches against `IOPlatformDevice` nubs with
//! `compatible = ["amlogic,meson-g12a-vpu", "amlogic,meson-vpu"]` or name `"vpu"`.
//!
//! Supports both:
//! - **Warm Mode**: Adopts the existing active U-Boot display pipeline (OSD1 canvas RGB565).
//! - **Cold Mode**: Performs full hardware power-on, GP0_PLL locking, DPHY/DSI host
//!   initialization, ST7701 DCS sequencing, VENC/ENCL timing, and backlight PWM.

use spin::Mutex;

use super::dphy::Dphy;
use super::dsi::{DEFAULT_PHY_TIMING, Dsi};
use super::hhi::Hhi;
use super::panel_st7701;
use super::pinctrl::Pinctrl;
use super::pwm::Pwm;
use super::pwrc::Pwrc;
use super::reset::Reset;
use super::venc::{SUPERBIRD_MODE, Venc};
use super::vpu::{Canvas, OsdFormat, Vpu};
use crate::iokit::framebuffer::{
    DisplayMode, IOFramebuffer, IOFramebufferVtable, PixelInformation,
};
use crate::iokit::platform_device::IOPlatformDevice;
use crate::iokit::registry;
use crate::iokit::service::{IOService, IOServiceVtable};
use crate::iokit::types::{
    IO_RETURN_NO_DEVICE, IO_RETURN_NO_MEMORY, IO_RETURN_NOT_READY, IO_RETURN_SUCCESS, IOReturn,
};

pub const CLASS_NAME: &str = "AmlogicFramebuffer";
pub const PROVIDER_CLASS: &str = "IOPlatformDevice";

const HHI_BASE: usize = 0xff63_c000;
const VPU_BASE: usize = 0xff90_0000;
const CANVAS_BASE: usize = 0xff63_8048;
const AO_SYSCTRL_BASE: usize = 0xff80_0000;
const RESET_BASE: usize = 0xffd0_1004;
const DPHY_BASE: usize = 0xff64_4000;
const DSI_BASE: usize = 0xffd0_7000;
const PERIPHS_PINCTRL_BASE: usize = 0xff63_4400;
const PWM_EF_BASE: usize = 0xffd1_9000;

const HS_CLK_RATE_HZ: u64 = (SUPERBIRD_MODE.clock_khz as u64) * 1000 * 24 / 2;
const LANE_MBPS: u32 = HS_CLK_RATE_HZ.div_ceil(1_000_000) as u32;
const LANES: u32 = 2;
const FB_ADDR: usize = 0x1000_0000;

struct FbState {
    instance: AmlogicFramebuffer,
    attached: bool,
}

pub struct AmlogicFramebuffer {
    pub fb: IOFramebuffer,
    pub canvas: Canvas,
    pub format: OsdFormat,
}

unsafe impl Send for AmlogicFramebuffer {}
unsafe impl Sync for AmlogicFramebuffer {}
unsafe impl Send for FbState {}
unsafe impl Sync for FbState {}

static FB: Mutex<FbState> = Mutex::new(FbState {
    instance: AmlogicFramebuffer {
        fb: IOFramebuffer::new(),
        canvas: Canvas {
            addr: 0,
            stride: 0,
            height: 0,
        },
        format: OsdFormat::Rgb565,
    },
    attached: false,
});

fn match_provider(provider: *mut IOService) -> bool {
    unsafe {
        let name = (*provider).get_class_name();
        if name == PROVIDER_CLASS {
            let plat = IOPlatformDevice::from_service(provider);
            for comp in &plat.compatible {
                if comp.contains("meson-g12a-vpu") || comp.contains("meson-vpu") {
                    return true;
                }
            }
            if plat.service.entry.get_name() == "vpu" {
                return true;
            }
        }
        false
    }
}

fn attach_and_start(provider: *mut IOService) -> IOReturn {
    let mut fb = FB.lock();
    if fb.attached {
        return IO_RETURN_SUCCESS;
    }

    fb.instance.fb.init(&VTABLE, "amlogic-fb");
    fb.instance.fb.service.set_class_name(CLASS_NAME);
    fb.instance
        .fb
        .service
        .entry
        .set_property_str("IOClass", CLASS_NAME);
    unsafe {
        fb.instance
            .fb
            .service
            .entry
            .set_property_str("IOProviderClass", (*provider).get_class_name());
    }

    if !unsafe {
        fb.instance
            .fb
            .as_service()
            .as_mut()
            .unwrap()
            .attach_to_provider(provider)
    } {
        return IO_RETURN_NO_MEMORY;
    }

    let svc_ptr = fb.instance.fb.as_service();
    let rc = fb.instance.fb.service.start(provider);
    if rc != IO_RETURN_SUCCESS {
        return rc;
    }

    fb.attached = true;
    registry::publish(svc_ptr);
    IO_RETURN_SUCCESS
}

fn probe(_svc: *mut IOService, provider: *mut IOService) -> IOReturn {
    if !match_provider(provider) {
        IO_RETURN_NO_DEVICE
    } else {
        IO_RETURN_SUCCESS
    }
}

fn start(svc: *mut IOService, provider: *mut IOService) -> IOReturn {
    let plat = IOPlatformDevice::from_service(provider);

    // Resolve register apertures
    let vpu_base = if let Some(mem) = plat.get_device_memory_with_index(0) {
        mem.get_physical_address() as usize
    } else {
        VPU_BASE
    };

    let canvas_base = if let Some(mem) = plat.get_device_memory_with_index(1) {
        mem.get_physical_address() as usize
    } else {
        CANVAS_BASE
    };

    let vpu = unsafe { Vpu::new(vpu_base, canvas_base) };
    let osd = vpu.osd1_read_state();

    let mut adopted = false;
    let mut fb_addr = FB_ADDR;
    let mut fb_stride = (SUPERBIRD_MODE.hdisplay * 2) as u32;
    let mut fb_w = SUPERBIRD_MODE.hdisplay;
    let mut fb_h = SUPERBIRD_MODE.vdisplay;
    let mut fb_format = OsdFormat::Rgb565;

    // Check if U-Boot left the pipeline running (Warm Adoption)
    if osd.enabled && osd.width > 0 && osd.height > 0 {
        let canvas = vpu.canvas_read(osd.canvas_index);
        if canvas.addr != 0 && canvas.stride != 0 {
            adopted = true;
            fb_addr = canvas.addr;
            fb_stride = canvas.stride;
            fb_w = osd.width;
            fb_h = osd.height;
            fb_format = osd.format;
        }
    }

    if !adopted {
        // Cold Bring-up path
        let (hhi, reset, pwrc, dphy, dsi, pinctrl, venc, pwm) = unsafe {
            (
                Hhi::new(HHI_BASE),
                Reset::new(RESET_BASE),
                Pwrc::new(AO_SYSCTRL_BASE),
                Dphy::new(DPHY_BASE),
                Dsi::new(DSI_BASE),
                Pinctrl::new(PERIPHS_PINCTRL_BASE),
                Venc::new(vpu_base),
                Pwm::new(PWM_EF_BASE),
            )
        };

        pwrc.vpu_power_on(&hhi, &reset);
        let pll = hhi.gp0_pll_set(HS_CLK_RATE_HZ);
        if !pll.locked {
            return IO_RETURN_NOT_READY;
        }
        hhi.mipi_analog_dphy_init();

        dphy.init(&reset);
        dphy.power_on(HS_CLK_RATE_HZ, LANES);

        dsi.top_hw_init();
        dsi.init(
            &reset,
            LANE_MBPS,
            LANES,
            &SUPERBIRD_MODE,
            &DEFAULT_PHY_TIMING,
        );

        panel_st7701::prepare(&dsi, &pinctrl);

        venc.mode_set(&SUPERBIRD_MODE, &vpu);
        hhi.vclk2_encl_chain(12);

        dsi.switch_to_video_mode();
        panel_st7701::enable(&dsi);

        // Fill initial black frame
        vpu.fill_solid(
            FB_ADDR,
            SUPERBIRD_MODE.hdisplay,
            SUPERBIRD_MODE.vdisplay,
            0xff00_0000,
        );
        vpu.canvas_config(
            0,
            FB_ADDR,
            SUPERBIRD_MODE.hdisplay * 2,
            SUPERBIRD_MODE.vdisplay,
        );
        vpu.osd1_show(0, SUPERBIRD_MODE.hdisplay, SUPERBIRD_MODE.vdisplay);

        pwm.backlight_enable(&pinctrl);

        fb_addr = FB_ADDR;
        fb_stride = SUPERBIRD_MODE.hdisplay * 2;
        fb_w = SUPERBIRD_MODE.hdisplay;
        fb_h = SUPERBIRD_MODE.vdisplay;
        fb_format = OsdFormat::Rgb565;
    }

    let fb_inst = IOFramebuffer::from_service(svc);
    fb_inst.aperture_base = fb_addr as u64;
    fb_inst.aperture_length = (fb_stride as u64) * (fb_h as u64);
    fb_inst.mode = DisplayMode {
        width: fb_w,
        height: fb_h,
        depth: (fb_format.bytes_per_pixel() * 8) as u32,
    };
    fb_inst.pixels = PixelInformation {
        bytes_per_row: fb_stride,
        bytes_per_pixel: fb_format.bytes_per_pixel() as u32,
        pixel_type: if fb_format == OsdFormat::Rgb565 { 1 } else { 0 },
    };

    // Register with display console
    let disp_fmt = if fb_format == OsdFormat::Rgb565 {
        crate::drivers::display::PixelFormat::Rgb565
    } else {
        crate::drivers::display::PixelFormat::Xrgb8888
    };
    crate::drivers::display::configure_manual(
        fb_addr,
        fb_stride as usize,
        fb_w as usize,
        fb_h as usize,
        disp_fmt,
    );

    IO_RETURN_SUCCESS
}

fn stop(_svc: *mut IOService, _provider: *mut IOService) {}

fn get_display_mode(fb_ptr: *mut IOFramebuffer, out: &mut DisplayMode) -> IOReturn {
    unsafe {
        *out = (*fb_ptr).mode;
    }
    IO_RETURN_SUCCESS
}

fn set_display_mode(fb_ptr: *mut IOFramebuffer, mode: DisplayMode) -> IOReturn {
    unsafe {
        (*fb_ptr).mode = mode;
    }
    IO_RETURN_SUCCESS
}

fn get_aperture(fb_ptr: *mut IOFramebuffer, base: &mut u64, len: &mut u64) -> IOReturn {
    unsafe {
        *base = (*fb_ptr).aperture_base;
        *len = (*fb_ptr).aperture_length;
    }
    IO_RETURN_SUCCESS
}

fn get_pixel_information(fb_ptr: *mut IOFramebuffer, out: &mut PixelInformation) -> IOReturn {
    unsafe {
        *out = (*fb_ptr).pixels;
    }
    IO_RETURN_SUCCESS
}

static VTABLE: IOFramebufferVtable = IOFramebufferVtable {
    service: IOServiceVtable {
        probe,
        start,
        stop,
        match_property_table: None,
    },
    get_display_mode,
    set_display_mode,
    get_aperture,
    get_pixel_information,
};

pub fn register() {
    registry::register_driver(registry::DriverMatcher {
        class_name: CLASS_NAME,
        provider_class: PROVIDER_CLASS,
        name_match: Some(&["vpu", "display"]),
        compatible_match: Some(&[
            "amlogic,meson-g12a-vpu",
            "amlogic,meson-vpu",
            "amlogic,meson-gx-vpu",
            "amlogic,meson-g12a-fb",
        ]),
        probe_score: 200,
        match_fn: Some(match_provider),
        probe_fn: None,
        attach_and_start,
    });
}
