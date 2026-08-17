//! Abstract IOFramebuffer matching Darwin IOKit/graphics/IOFramebuffer.h.

use crate::iokit::service::{IOService, IOServiceVtable};
use crate::iokit::types::IOReturn;

pub const CLASS_NAME: &str = "IOFramebuffer";

#[derive(Clone, Copy, Debug, Default)]
pub struct DisplayMode {
    pub width: u32,
    pub height: u32,
    pub depth: u32,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct PixelInformation {
    pub bytes_per_row: u32,
    pub bytes_per_pixel: u32,
    pub pixel_type: u32, // 0 = B8G8R8X8
}

pub struct IOFramebufferVtable {
    pub service: IOServiceVtable,
    pub get_display_mode: fn(*mut IOFramebuffer, &mut DisplayMode) -> IOReturn,
    pub set_display_mode: fn(*mut IOFramebuffer, DisplayMode) -> IOReturn,
    pub get_aperture: fn(*mut IOFramebuffer, &mut u64, &mut u64) -> IOReturn,
    pub get_pixel_information: fn(*mut IOFramebuffer, &mut PixelInformation) -> IOReturn,
}

pub struct IOFramebuffer {
    pub service: IOService,
    pub fb_vtable: Option<&'static IOFramebufferVtable>,
    pub mode: DisplayMode,
    pub aperture_base: u64,
    pub aperture_length: u64,
    pub pixels: PixelInformation,
}

impl Default for IOFramebuffer {
    fn default() -> Self {
        Self::new()
    }
}

impl IOFramebuffer {
    pub const fn new() -> Self {
        Self {
            service: IOService::new(),
            fb_vtable: None,
            mode: DisplayMode {
                width: 0,
                height: 0,
                depth: 32,
            },
            aperture_base: 0,
            aperture_length: 0,
            pixels: PixelInformation {
                bytes_per_row: 0,
                bytes_per_pixel: 4,
                pixel_type: 0,
            },
        }
    }

    pub fn init(&mut self, vtable: &'static IOFramebufferVtable, name: &str) {
        self.fb_vtable = Some(vtable);
        self.service.init(CLASS_NAME, name, "");
        self.service.vtable = Some(&vtable.service);
    }

    pub fn as_service(&mut self) -> *mut IOService {
        &mut self.service
    }

    pub fn from_service(svc: *mut IOService) -> &'static mut IOFramebuffer {
        unsafe { &mut *(svc as *mut IOFramebuffer) }
    }

    pub fn get_display_mode(&mut self, out: &mut DisplayMode) -> IOReturn {
        if let Some(vt) = self.fb_vtable {
            (vt.get_display_mode)(self as *mut IOFramebuffer, out)
        } else {
            0
        }
    }

    pub fn set_display_mode(&mut self, mode: DisplayMode) -> IOReturn {
        if let Some(vt) = self.fb_vtable {
            (vt.set_display_mode)(self as *mut IOFramebuffer, mode)
        } else {
            0
        }
    }

    pub fn get_aperture(&mut self, base: &mut u64, len: &mut u64) -> IOReturn {
        if let Some(vt) = self.fb_vtable {
            (vt.get_aperture)(self as *mut IOFramebuffer, base, len)
        } else {
            0
        }
    }

    pub fn get_pixel_information(&mut self, out: &mut PixelInformation) -> IOReturn {
        if let Some(vt) = self.fb_vtable {
            (vt.get_pixel_information)(self as *mut IOFramebuffer, out)
        } else {
            0
        }
    }
}
