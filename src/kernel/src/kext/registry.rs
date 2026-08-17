//! Kernel extension driver and provider registry.

use crate::device::provider::{DeviceClass, Info};
use crate::drivers::uart;
use crate::kext::api::{
    ABI_VERSION, DRIVER_CLASS_BLOCK, DRIVER_CLASS_DISPLAY, DRIVER_CLASS_TEST, DriverDescriptor,
    KEXT_BAD_ABI, KEXT_INVALID, KEXT_NO_SPACE, KEXT_SUCCESS, KernelApi, Provider,
};
use spin::Mutex;

const MAX_DRIVERS: usize = 16;
const MAX_PROVIDERS: usize = 16;

struct KextRegistryState {
    drivers: [Option<*const DriverDescriptor>; MAX_DRIVERS],
    driver_count: usize,
    providers: [Option<Provider>; MAX_PROVIDERS],
    provider_count: usize,
    started: [[bool; MAX_PROVIDERS]; MAX_DRIVERS],
}

unsafe impl Send for KextRegistryState {}
unsafe impl Sync for KextRegistryState {}

static REGISTRY: Mutex<KextRegistryState> = Mutex::new(KextRegistryState {
    drivers: [None; MAX_DRIVERS],
    driver_count: 0,
    providers: [None; MAX_PROVIDERS],
    provider_count: 0,
    started: [[false; MAX_PROVIDERS]; MAX_DRIVERS],
});

const SMOKE_PROVIDER_NAME: &str = "kext-smoke-provider";

pub static KERNEL_API: KernelApi = KernelApi {
    abi_version: ABI_VERSION,
    log: kext_log,
    register_driver: kext_register_driver,
};

pub extern "C" fn kext_log(ptr: *const u8, len: usize) {
    if !ptr.is_null() && len > 0 {
        let slice = unsafe { core::slice::from_raw_parts(ptr, len) };
        if let Ok(s) = core::str::from_utf8(slice) {
            uart::print(s);
        }
    }
}

pub extern "C" fn kext_register_driver(driver: *const DriverDescriptor) -> i32 {
    if driver.is_null() {
        return KEXT_INVALID;
    }
    unsafe {
        if (*driver).abi_version != ABI_VERSION {
            return KEXT_BAD_ABI;
        }
        if (*driver).name_ptr.is_null() || (*driver).name_len == 0 || (*driver).name_len > 64 {
            return KEXT_INVALID;
        }

        let mut reg = REGISTRY.lock();
        if reg.driver_count >= MAX_DRIVERS {
            return KEXT_NO_SPACE;
        }

        let idx = reg.driver_count;
        reg.drivers[idx] = Some(driver);
        reg.driver_count += 1;

        uart::print("opendarwin: driver registered: ");
        let name_bytes = core::slice::from_raw_parts((*driver).name_ptr, (*driver).name_len);
        if let Ok(name) = core::str::from_utf8(name_bytes) {
            uart::print(name);
        }
        uart::print("\n");

        let p_count = reg.provider_count;
        for provider_idx in 0..p_count {
            start_if_matched_locked(&mut reg, idx, provider_idx);
        }

        KEXT_SUCCESS
    }
}

pub fn publish_provider(provider: Provider) -> bool {
    if provider.name_len == 0 || provider.name_ptr.is_null() || provider.name_len > 64 {
        return false;
    }
    let mut reg = REGISTRY.lock();
    if reg.provider_count >= MAX_PROVIDERS {
        return false;
    }
    let idx = reg.provider_count;
    reg.providers[idx] = Some(provider);
    reg.provider_count += 1;

    uart::print("opendarwin: provider published: ");
    let name_bytes = unsafe { core::slice::from_raw_parts(provider.name_ptr, provider.name_len) };
    if let Ok(name) = core::str::from_utf8(name_bytes) {
        uart::print(name);
    }
    uart::print("\n");

    let d_count = reg.driver_count;
    for driver_idx in 0..d_count {
        start_if_matched_locked(&mut reg, driver_idx, idx);
    }

    true
}

pub fn publish_smoke_provider() -> bool {
    publish_provider(Provider {
        id: 1,
        class: DRIVER_CLASS_TEST,
        name_ptr: SMOKE_PROVIDER_NAME.as_ptr(),
        name_len: SMOKE_PROVIDER_NAME.len(),
        mmio_base: 0,
        mmio_len: 0,
        irq: 0,
        ecam_base: 0,
        pci_bus: 0,
        pci_device: 0,
        pci_function: 0,
        pci_vendor_id: 0,
        pci_device_id: 0,
    })
}

pub fn publish_provider_info(id: u64, info: Info, ecam_base: u64) -> bool {
    let class = match info.class {
        DeviceClass::Block => DRIVER_CLASS_BLOCK,
        DeviceClass::Display => DRIVER_CLASS_DISPLAY,
        _ => return false,
    };
    publish_provider(Provider {
        id,
        class,
        name_ptr: info.name.as_ptr(),
        name_len: info.name.len(),
        mmio_base: info.mmio_base,
        mmio_len: info.mmio_len,
        irq: info.irq,
        ecam_base,
        pci_bus: info.pci_bus as u64,
        pci_device: info.pci_device as u64,
        pci_function: info.pci_function as u64,
        pci_vendor_id: info.pci_vendor_id as u64,
        pci_device_id: info.pci_device_id as u64,
    })
}

fn start_if_matched_locked(reg: &mut KextRegistryState, driver_idx: usize, provider_idx: usize) {
    if reg.started[driver_idx][provider_idx] {
        return;
    }
    let Some(driver_ptr) = reg.drivers[driver_idx] else {
        return;
    };
    let Some(provider) = &reg.providers[provider_idx] else {
        return;
    };

    unsafe {
        if (*driver_ptr).class != provider.class {
            return;
        }

        let prov_ptr = provider as *const Provider;
        if let Some(probe_fn) = (*driver_ptr).probe {
            if probe_fn(prov_ptr) != KEXT_SUCCESS {
                return;
            }
        }

        let Some(start_fn) = (*driver_ptr).start else {
            return;
        };
        if start_fn(prov_ptr, &KERNEL_API) != KEXT_SUCCESS {
            return;
        }

        reg.started[driver_idx][provider_idx] = true;
        uart::print("opendarwin: driver started on provider\n");
    }
}
