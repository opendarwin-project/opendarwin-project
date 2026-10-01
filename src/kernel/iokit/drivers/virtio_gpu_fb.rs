//! VirtioGpuFramebuffer driver implementing IOFramebuffer on VirtIO GPU.

use crate::device::provider::{DeviceClass, Info};
use crate::drivers::{uart, virtio_gpu};
use crate::iokit::framebuffer::{
    DisplayMode, IOFramebuffer, IOFramebufferVtable, PixelInformation,
};
use crate::iokit::pci_device::{CLASS_NAME as PCI_CLASS_NAME, IOPCIDevice};
use crate::iokit::registry;
use crate::iokit::service::{IOService, IOServiceVtable};
use crate::iokit::types::{
    IO_RETURN_NO_DEVICE, IO_RETURN_NO_MEMORY, IO_RETURN_NOT_READY, IO_RETURN_SUCCESS, IOReturn,
};
use spin::Mutex;

pub const CLASS_NAME: &str = "VirtioGpuFramebuffer";

struct FbState {
    instance: VirtioGpuFramebuffer,
    attached: bool,
}

static FB: Mutex<FbState> = Mutex::new(FbState {
    instance: VirtioGpuFramebuffer {
        fb: IOFramebuffer::new(),
        pci: None,
    },
    attached: false,
});

pub struct VirtioGpuFramebuffer {
    pub fb: IOFramebuffer,
    pub pci: Option<*mut IOPCIDevice>,
}

unsafe impl Send for VirtioGpuFramebuffer {}
unsafe impl Sync for VirtioGpuFramebuffer {}
unsafe impl Send for FbState {}
unsafe impl Sync for FbState {}
fn match_provider(provider: *mut IOService) -> bool {
    unsafe {
        let name = (*provider).get_class_name();
        if name == PCI_CLASS_NAME {
            let pci = IOPCIDevice::from_service(provider);
            return pci.looks_like_virtio_gpu();
        }
        if name == "IODisplayNub" {
            let pci = IOPCIDevice::from_service(provider);
            return pci.mmio_base != 0;
        }
        false
    }
}

fn attach_and_start(provider: *mut IOService) -> IOReturn {
    let mut fb = FB.lock();
    if fb.attached && virtio_gpu::ready() {
        return IO_RETURN_SUCCESS;
    }
    if fb.attached {
        return IO_RETURN_NOT_READY;
    }

    fb.instance.fb.init(&VTABLE, "virtio-gpu-fb");
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
    fb.instance.pci = Some(IOPCIDevice::from_service(provider));
    fb.attached = true;

    let svc_ptr = fb.instance.fb.as_service();
    let rc = fb.instance.fb.service.start(provider);
    if rc != IO_RETURN_SUCCESS {
        fb.attached = false;
        return rc;
    }

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

fn start(_svc: *mut IOService, provider: *mut IOService) -> IOReturn {
    let pci = IOPCIDevice::from_service(provider);

    let info = Info {
        class: DeviceClass::Display,
        name: pci.service.entry.get_name(),
        mmio_base: pci.mmio_base,
        mmio_len: pci.mmio_len,
        irq: pci.irq,
        pci_bus: pci.bus,
        pci_device: pci.device,
        pci_function: pci.function,
        pci_vendor_id: pci.vendor_id,
        pci_device_id: pci.device_id,
        pci_class_code: pci.class_code,
        pci_subclass: pci.subclass,
        pci_prog_if: pci.prog_if,
        ..Default::default()
    };

    let ecam = if pci.ecam_base != 0 {
        Some(pci.ecam_base)
    } else {
        None
    };
    if !virtio_gpu::init(&[info], ecam) {
        uart::print("opendarwin: VirtioGpuFramebuffer: bind failed\n");
        return IO_RETURN_NO_DEVICE;
    }

    if !virtio_gpu::setup_scanout() {
        uart::print("opendarwin: VirtioGpuFramebuffer: scanout setup failed\n");
        return IO_RETURN_NO_MEMORY;
    }

    let Some(scan) = virtio_gpu::scanout_info() else {
        return IO_RETURN_NOT_READY;
    };

    let mut fb = FB.lock();
    fb.instance.fb.mode = DisplayMode {
        width: scan.width,
        height: scan.height,
        depth: 32,
    };
    fb.instance.fb.aperture_base = virtio_gpu::aperture_base();
    fb.instance.fb.aperture_length = virtio_gpu::aperture_length();
    fb.instance.fb.pixels = PixelInformation {
        bytes_per_row: scan.stride,
        bytes_per_pixel: 4,
        pixel_type: 0,
    };

    uart::print("opendarwin: virtio-gpu device ready (IOKit)\n");
    IO_RETURN_SUCCESS
}

fn stop(_svc: *mut IOService, _provider: *mut IOService) {}

fn get_display_mode(_fb_ptr: *mut IOFramebuffer, out: &mut DisplayMode) -> IOReturn {
    if !virtio_gpu::ready() {
        return IO_RETURN_NOT_READY;
    }
    let fb = FB.lock();
    *out = fb.instance.fb.mode;
    if out.width == 0 {
        let display = virtio_gpu::display_info();
        out.width = display.width;
        out.height = display.height;
        out.depth = 32;
    }
    IO_RETURN_SUCCESS
}

fn set_display_mode(_fb_ptr: *mut IOFramebuffer, mode: DisplayMode) -> IOReturn {
    let mut fb = FB.lock();
    fb.instance.fb.mode = mode;
    fb.instance.fb.pixels.bytes_per_row = mode.width * 4;
    IO_RETURN_SUCCESS
}

fn get_aperture(_fb_ptr: *mut IOFramebuffer, base: &mut u64, len: &mut u64) -> IOReturn {
    let fb = FB.lock();
    *base = fb.instance.fb.aperture_base;
    *len = fb.instance.fb.aperture_length;
    if fb.instance.fb.aperture_length == 0 {
        return IO_RETURN_NOT_READY;
    }
    IO_RETURN_SUCCESS
}

fn get_pixel_information(_fb_ptr: *mut IOFramebuffer, out: &mut PixelInformation) -> IOReturn {
    let fb = FB.lock();
    *out = fb.instance.fb.pixels;
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
        provider_class: PCI_CLASS_NAME,
        name_match: None,
        compatible_match: None,
        probe_score: 100,
        match_fn: Some(match_provider),
        probe_fn: None,
        attach_and_start,
    });
    registry::register_driver(registry::DriverMatcher {
        class_name: CLASS_NAME,
        provider_class: "IODisplayNub",
        name_match: None,
        compatible_match: None,
        probe_score: 50,
        match_fn: Some(match_provider),
        probe_fn: None,
        attach_and_start,
    });
}
