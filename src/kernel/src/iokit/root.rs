//! IOKit root bring-up: registry initialization, display nub publishing, driver matching.

use crate::device::provider::{DeviceClass, Info};
use crate::drivers::uart;
use crate::iokit::drivers::virtio_gpu_fb;
use crate::iokit::pci_device::IOPCIDevice;
use crate::iokit::registry;
use crate::iokit::types::MAX_SERVICES;
use spin::Mutex;

struct PciPoolState {
    pool: [IOPCIDevice; MAX_SERVICES],
    count: usize,
}

unsafe impl Send for PciPoolState {}
unsafe impl Sync for PciPoolState {}

static PCI_POOL: Mutex<PciPoolState> = Mutex::new(PciPoolState {
    pool: [const { IOPCIDevice::new() }; MAX_SERVICES],
    count: 0,
});

pub fn init() {
    registry::init();
    virtio_gpu_fb::register();
}

pub fn publish_display_candidates(candidates: &[Info], ecam_base: Option<u64>) -> usize {
    let mut published = 0;
    let ecam = ecam_base.unwrap_or(0);

    let mut has_pci = false;
    for m in candidates {
        if m.class != DeviceClass::Display {
            continue;
        }
        if m.pci_vendor_id != 0 {
            has_pci = true;
        }
    }

    let mut pci = PCI_POOL.lock();
    for &m in candidates {
        if m.class != DeviceClass::Display {
            continue;
        }
        if pci.count >= MAX_SERVICES {
            break;
        }

        if m.pci_vendor_id != 0 {
            let idx = pci.count;
            pci.pool[idx].init_from_provider_info(m, ecam);
            if registry::publish(pci.pool[idx].as_service()) {
                pci.count += 1;
                published += 1;
            }
            continue;
        }

        if has_pci || m.mmio_base == 0 {
            continue;
        }

        let idx = pci.count;
        pci.pool[idx].init_mmio_nub(m);
        if registry::publish(pci.pool[idx].as_service()) {
            pci.count += 1;
            published += 1;
        }
    }

    if published == 0 {
        uart::print("opendarwin: iokit: no display nubs published\n");
    }
    published
}

pub fn match_and_start_drivers() -> usize {
    registry::match_and_start_drivers()
}
