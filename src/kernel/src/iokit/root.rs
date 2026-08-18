//! IOKit root bring-up: registry initialization, platform expert, display nub publishing, driver matching.

use crate::device::provider::{DeviceClass, Info};
use crate::drivers::uart;
use crate::iokit::drivers::virtio_gpu_fb;
use crate::iokit::memory::IODeviceMemory;
use crate::iokit::pci_device::IOPCIDevice;
use crate::iokit::platform_device::{IOPlatformDevice, IOPlatformExpert};
use crate::iokit::registry;
use crate::iokit::types::MAX_SERVICES;
use spin::Mutex;

struct PciPoolState {
    pool: [IOPCIDevice; MAX_SERVICES],
    count: usize,
}

struct PlatformPoolState {
    expert: IOPlatformExpert,
    nubs: [IOPlatformDevice; MAX_SERVICES],
    count: usize,
}

unsafe impl Send for PciPoolState {}
unsafe impl Sync for PciPoolState {}
unsafe impl Send for PlatformPoolState {}
unsafe impl Sync for PlatformPoolState {}

static PCI_POOL: Mutex<PciPoolState> = Mutex::new(PciPoolState {
    pool: [const { IOPCIDevice::new() }; MAX_SERVICES],
    count: 0,
});

static PLATFORM_POOL: Mutex<PlatformPoolState> = Mutex::new(PlatformPoolState {
    expert: IOPlatformExpert::new(),
    nubs: [const { IOPlatformDevice::new() }; MAX_SERVICES],
    count: 0,
});

pub fn init() {
    registry::init();

    let mut platform = PLATFORM_POOL.lock();
    platform.expert.init("OpenDarwin-ARM64");
    registry::publish(platform.expert.as_service());

    virtio_gpu_fb::register();
    crate::iokit::drivers::amlogic::register_amlogic_fb();
}

/// Publishes an IOPlatformDevice nub attached to the platform expert in both gIODTPlane and gIOServicePlane.
pub fn publish_platform_device(
    name: &str,
    location: &str,
    compatible: &[&str],
    memory_regions: &[(u64, u64)],
    interrupts: &[u32],
) -> Option<*mut IOPlatformDevice> {
    let mut pool = PLATFORM_POOL.lock();
    if pool.count >= MAX_SERVICES {
        return None;
    }
    let idx = pool.count;
    let expert_ptr = &mut pool.expert as *mut IOPlatformExpert;
    let nub = &mut pool.nubs[idx];
    nub.init(name, location);
    for comp in compatible {
        nub.add_compatible(comp);
    }
    for &(base, len) in memory_regions {
        nub.add_device_memory(IODeviceMemory::with_range(base, len));
    }
    for &irq in interrupts {
        nub.add_interrupt(irq);
    }

    unsafe {
        (*expert_ptr).attach_device_tree_nub(nub);
    }
    let nub_ptr = nub as *mut IOPlatformDevice;
    let svc_ptr = nub.as_service();
    if registry::publish(svc_ptr) {
        pool.count += 1;
        Some(nub_ptr)
    } else {
        None
    }
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
