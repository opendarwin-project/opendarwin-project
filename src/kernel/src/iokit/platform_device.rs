//! IOPlatformDevice and IOPlatformExpert matching Darwin IOKit/platform/IOPlatformExpert.h
//! and IOKit/platform/IOPlatformDevice.h.
//!
//! On ARM64 SoCs (e.g. Apple Silicon, Amlogic Meson G12A), the device tree is walked by
//! `IOPlatformExpert`, which constructs `IOPlatformDevice` nubs for all SoC peripherals,
//! populating both `gIODTPlane` and `gIOServicePlane`.

use alloc::string::String;
use alloc::vec::Vec;

use crate::drivers::gic;
use crate::iokit::memory::{IODeviceMemory, IOMemoryMap};
use crate::iokit::registry_entry::{OSObject, gIODTPlane, gIOServicePlane};
use crate::iokit::service::IOService;
use crate::iokit::types::{IO_RETURN_BAD_ARGUMENT, IO_RETURN_SUCCESS, IOReturn};
pub const PLATFORM_DEVICE_CLASS_NAME: &str = "IOPlatformDevice";
pub const PLATFORM_EXPERT_CLASS_NAME: &str = "IOPlatformExpert";

/// Nub representing an MMIO device from the Device Tree hierarchy.
pub struct IOPlatformDevice {
    pub service: IOService,
    pub device_memory: Vec<IODeviceMemory>,
    pub interrupts: Vec<u32>,
    pub compatible: Vec<String>,
}

unsafe impl Send for IOPlatformDevice {}
unsafe impl Sync for IOPlatformDevice {}

impl Default for IOPlatformDevice {
    fn default() -> Self {
        Self::new()
    }
}

impl IOPlatformDevice {
    pub const fn new() -> Self {
        Self {
            service: IOService::new(),
            device_memory: Vec::new(),
            interrupts: Vec::new(),
            compatible: Vec::new(),
        }
    }

    pub fn init(&mut self, name: &str, location: &str) {
        self.service
            .init(PLATFORM_DEVICE_CLASS_NAME, name, location);
        self.service
            .entry
            .set_property_str("IOClass", PLATFORM_DEVICE_CLASS_NAME);
        self.service.entry.set_property_str("IOName", name);
        if !location.is_empty() {
            self.service.entry.set_property_str("IOLocation", location);
        }
        self.device_memory.clear();
        self.interrupts.clear();
        self.compatible.clear();
    }

    pub fn add_compatible(&mut self, comp: &str) {
        self.compatible.push(String::from(comp));
        let arr: Vec<OSObject> = self
            .compatible
            .iter()
            .map(|s| OSObject::String(s.clone()))
            .collect();
        self.service.entry.set_property_array("compatible", arr);
    }

    pub fn add_device_memory(&mut self, mem: IODeviceMemory) {
        self.device_memory.push(mem);
    }

    pub fn get_device_memory_with_index(&self, index: usize) -> Option<&IODeviceMemory> {
        self.device_memory.get(index)
    }

    pub fn map_device_memory_with_index(&self, index: usize) -> Option<IOMemoryMap> {
        self.device_memory.get(index).map(|mem| mem.map())
    }

    pub fn add_interrupt(&mut self, irq: u32) {
        self.interrupts.push(irq);
    }

    pub fn get_interrupt(&self, index: usize) -> Option<u32> {
        self.interrupts.get(index).copied()
    }

    pub fn register_interrupt(
        &mut self,
        index: usize,
        _target: *mut IOService,
        _handler: fn(target: *mut IOService, refcon: usize),
        _refcon: usize,
    ) -> IOReturn {
        if let Some(&irq) = self.interrupts.get(index) {
            gic::enable(irq);
            IO_RETURN_SUCCESS
        } else {
            IO_RETURN_BAD_ARGUMENT
        }
    }

    pub fn as_service(&mut self) -> *mut IOService {
        &mut self.service
    }

    pub fn from_service(svc: *mut IOService) -> &'static mut IOPlatformDevice {
        unsafe { &mut *(svc as *mut IOPlatformDevice) }
    }
}

/// Root SoC Platform Expert managing the Device Tree plane (`gIODTPlane`).
pub struct IOPlatformExpert {
    pub service: IOService,
}

unsafe impl Send for IOPlatformExpert {}
unsafe impl Sync for IOPlatformExpert {}

impl Default for IOPlatformExpert {
    fn default() -> Self {
        Self::new()
    }
}

impl IOPlatformExpert {
    pub const fn new() -> Self {
        Self {
            service: IOService::new(),
        }
    }

    pub fn init(&mut self, model: &str) {
        self.service
            .init(PLATFORM_EXPERT_CLASS_NAME, "IODeviceTree", "");
        self.service
            .entry
            .set_property_str("IOClass", PLATFORM_EXPERT_CLASS_NAME);
        self.service.entry.set_property_str("model", model);
    }

    pub fn as_service(&mut self) -> *mut IOService {
        &mut self.service
    }

    pub fn attach_device_tree_nub(&mut self, nub: &mut IOPlatformDevice) {
        // Attach to Device Tree plane hierarchy
        nub.service
            .entry
            .attach_to_parent(&mut self.service.entry, gIODTPlane);
        // Also attach to Service plane for driver matching
        nub.service
            .entry
            .attach_to_parent(&mut self.service.entry, gIOServicePlane);
    }
}
