//! C ABI exports for IOKit C++ shims.

use crate::iokit::framebuffer::{DisplayMode, IOFramebuffer};
use crate::iokit::memory::IOMemoryDescriptor;
use crate::iokit::pci_device::IOPCIDevice;
use crate::iokit::registry;
use crate::iokit::service::IOService;
use crate::iokit::types::{IO_RETURN_BAD_ARGUMENT, IO_RETURN_ERROR, IO_RETURN_SUCCESS};

#[unsafe(no_mangle)]
pub extern "C" fn IOKit_RegistryRoot() -> *mut IOService {
    registry::root()
}

#[unsafe(no_mangle)]
pub extern "C" fn IOKit_ServiceGetName(svc: *mut IOService, out_len: *mut usize) -> *const u8 {
    if svc.is_null() {
        return core::ptr::null();
    }
    unsafe {
        let name = (*svc).entry.get_name();
        if !out_len.is_null() {
            *out_len = name.len();
        }
        name.as_ptr()
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn IOKit_ServiceGetClassName(svc: *mut IOService, out_len: *mut usize) -> *const u8 {
    if svc.is_null() {
        return core::ptr::null();
    }
    unsafe {
        let name = (*svc).get_class_name();
        if !out_len.is_null() {
            *out_len = name.len();
        }
        name.as_ptr()
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn IOKit_ServiceGetProvider(svc: *mut IOService) -> *mut IOService {
    if svc.is_null() {
        return core::ptr::null_mut();
    }
    unsafe { (*svc).provider.unwrap_or(core::ptr::null_mut()) }
}

#[unsafe(no_mangle)]
pub extern "C" fn IOKit_ServiceGetPropertyU64(
    svc: *mut IOService,
    key_ptr: *const u8,
    key_len: usize,
    out: *mut u64,
) -> i32 {
    if svc.is_null() || key_ptr.is_null() {
        return IO_RETURN_BAD_ARGUMENT;
    }
    unsafe {
        let key_bytes = core::slice::from_raw_parts(key_ptr, key_len);
        let Ok(key) = core::str::from_utf8(key_bytes) else {
            return IO_RETURN_BAD_ARGUMENT;
        };
        if let Some(val) = (*svc).entry.get_property_u64(key) {
            if !out.is_null() {
                *out = val;
            }
            IO_RETURN_SUCCESS
        } else {
            IO_RETURN_ERROR
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn IOKit_ServiceStart(svc: *mut IOService, provider: *mut IOService) -> i32 {
    if svc.is_null() || provider.is_null() {
        return IO_RETURN_BAD_ARGUMENT;
    }
    unsafe { (*svc).start(provider) }
}

#[unsafe(no_mangle)]
pub extern "C" fn IOKit_PCI_ConfigRead16(svc: *mut IOService, offset: u16) -> u16 {
    if svc.is_null() {
        return 0xffff;
    }
    let pci = IOPCIDevice::from_service(svc);
    pci.config_read16(offset)
}

#[unsafe(no_mangle)]
pub extern "C" fn IOKit_PCI_ConfigRead32(svc: *mut IOService, offset: u16) -> u32 {
    if svc.is_null() {
        return 0xffff_ffff;
    }
    let pci = IOPCIDevice::from_service(svc);
    pci.config_read32(offset)
}

#[unsafe(no_mangle)]
pub extern "C" fn IOKit_PCI_MapBAR(svc: *mut IOService, bar_index: u8) -> *mut IOMemoryDescriptor {
    if svc.is_null() {
        return core::ptr::null_mut();
    }
    let pci = IOPCIDevice::from_service(svc);
    pci.map_device_memory_with_register(bar_index)
        .unwrap_or(core::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub extern "C" fn IOKit_Memory_GetVirtualAddress(desc: *mut IOMemoryDescriptor) -> u64 {
    if desc.is_null() {
        return 0;
    }
    unsafe { (*desc).get_virtual_address() }
}

#[unsafe(no_mangle)]
pub extern "C" fn IOKit_Memory_GetLength(desc: *mut IOMemoryDescriptor) -> u64 {
    if desc.is_null() {
        return 0;
    }
    unsafe { (*desc).get_length() }
}

#[unsafe(no_mangle)]
pub extern "C" fn IOKit_Framebuffer_GetDisplayMode(
    svc: *mut IOService,
    width: *mut u32,
    height: *mut u32,
    depth: *mut u32,
) -> i32 {
    if svc.is_null() {
        return IO_RETURN_BAD_ARGUMENT;
    }
    let fb = IOFramebuffer::from_service(svc);
    let mut mode = DisplayMode::default();
    let rc = fb.get_display_mode(&mut mode);
    if rc != IO_RETURN_SUCCESS {
        return rc;
    }
    unsafe {
        if !width.is_null() {
            *width = mode.width;
        }
        if !height.is_null() {
            *height = mode.height;
        }
        if !depth.is_null() {
            *depth = mode.depth;
        }
    }
    IO_RETURN_SUCCESS
}

#[unsafe(no_mangle)]
pub extern "C" fn IOKit_Framebuffer_GetAperture(
    svc: *mut IOService,
    base: *mut u64,
    len: *mut u64,
) -> i32 {
    if svc.is_null() {
        return IO_RETURN_BAD_ARGUMENT;
    }
    let fb = IOFramebuffer::from_service(svc);
    let mut b = 0u64;
    let mut l = 0u64;
    let rc = fb.get_aperture(&mut b, &mut l);
    unsafe {
        if !base.is_null() {
            *base = b;
        }
        if !len.is_null() {
            *len = l;
        }
    }
    rc
}

pub fn link_force() {
    _ = IOKit_RegistryRoot as *const () as usize;
    _ = IOKit_ServiceGetName as *const () as usize;
}
