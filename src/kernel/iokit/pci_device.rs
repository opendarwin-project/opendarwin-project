//! IOPCIDevice representation for PCI hardware nubs.

use crate::device::provider::Info;
use crate::iokit::memory::IOMemoryDescriptor;
use crate::iokit::service::IOService;

pub const CLASS_NAME: &str = "IOPCIDevice";

pub struct IOPCIDevice {
    pub service: IOService,
    pub ecam_base: u64,
    pub mmio_base: u64,
    pub mmio_len: u64,
    pub irq: u64,
    pub bus: u8,
    pub device: u8,
    pub function: u8,
    pub vendor_id: u16,
    pub device_id: u16,
    pub class_code: u8,
    pub subclass: u8,
    pub prog_if: u8,
    pub bar_descriptors: [Option<IOMemoryDescriptor>; 6],
}

impl Default for IOPCIDevice {
    fn default() -> Self {
        Self::new()
    }
}

impl IOPCIDevice {
    pub const fn new() -> Self {
        Self {
            service: IOService::new(),
            ecam_base: 0,
            mmio_base: 0,
            mmio_len: 0,
            irq: 0,
            bus: 0,
            device: 0,
            function: 0,
            vendor_id: 0,
            device_id: 0,
            class_code: 0,
            subclass: 0,
            prog_if: 0,
            bar_descriptors: [None; 6],
        }
    }

    pub fn init_from_provider_info(&mut self, m: Info, ecam: u64) {
        self.service.init(CLASS_NAME, m.name, "");
        self.ecam_base = ecam;
        self.mmio_base = m.mmio_base;
        self.mmio_len = m.mmio_len;
        self.irq = m.irq;
        self.bus = m.pci_bus;
        self.device = m.pci_device;
        self.function = m.pci_function;
        self.vendor_id = m.pci_vendor_id;
        self.device_id = m.pci_device_id;
        self.class_code = m.pci_class_code;
        self.subclass = m.pci_subclass;
        self.prog_if = m.pci_prog_if;

        self.service
            .entry
            .set_property_u64("vendor-id", m.pci_vendor_id as u64);
        self.service
            .entry
            .set_property_u64("device-id", m.pci_device_id as u64);
        self.service
            .entry
            .set_property_u64("class-code", m.pci_class_code as u64);
    }

    pub fn init_mmio_nub(&mut self, m: Info) {
        self.service.init("IODisplayNub", m.name, "");
        self.ecam_base = 0;
        self.mmio_base = m.mmio_base;
        self.mmio_len = m.mmio_len;
        self.irq = m.irq;
        self.vendor_id = 0x1af4;
        self.device_id = 0x1050;
    }

    pub fn looks_like_virtio_gpu(&self) -> bool {
        (self.vendor_id == 0x1af4 && (self.device_id == 0x1050 || self.device_id == 0x1010))
            || self.class_code == 0x03
    }

    pub fn config_read16(&self, offset: u16) -> u16 {
        if self.ecam_base == 0 {
            return 0xffff;
        }
        let dev_off = ((self.bus as u64) << 20)
            | ((self.device as u64) << 15)
            | ((self.function as u64) << 12);
        let ptr = (self.ecam_base + dev_off + offset as u64) as *const u16;
        unsafe { core::ptr::read_volatile(ptr) }
    }

    pub fn config_read32(&self, offset: u16) -> u32 {
        if self.ecam_base == 0 {
            return 0xffff_ffff;
        }
        let dev_off = ((self.bus as u64) << 20)
            | ((self.device as u64) << 15)
            | ((self.function as u64) << 12);
        let ptr = (self.ecam_base + dev_off + offset as u64) as *const u32;
        unsafe { core::ptr::read_volatile(ptr) }
    }

    pub fn map_device_memory_with_register(
        &mut self,
        bar_index: u8,
    ) -> Option<*mut IOMemoryDescriptor> {
        if (bar_index as usize) >= self.bar_descriptors.len() {
            return None;
        }
        if self.bar_descriptors[bar_index as usize].is_none() {
            let offset = 0x10 + (bar_index as u16) * 4;
            let bar_val = self.config_read32(offset) as u64;
            if bar_val != 0 && (bar_val & 1) == 0 {
                let bar_base = bar_val & !0xf;
                self.bar_descriptors[bar_index as usize] =
                    Some(IOMemoryDescriptor::with_physical_range(bar_base, 0x1_0000));
            }
        }
        self.bar_descriptors[bar_index as usize]
            .as_mut()
            .map(|d| d as *mut IOMemoryDescriptor)
    }

    pub fn as_service(&mut self) -> *mut IOService {
        &mut self.service
    }

    pub fn from_service(svc: *mut IOService) -> &'static mut IOPCIDevice {
        unsafe { &mut *(svc as *mut IOPCIDevice) }
    }
}
