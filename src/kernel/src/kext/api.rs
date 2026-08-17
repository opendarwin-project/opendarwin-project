//! Kernel extension (Kext) C ABI interface.

pub const ABI_VERSION: u64 = 3;

pub const KEXT_SUCCESS: i32 = 0;
pub const KEXT_BAD_ABI: i32 = -1;
pub const KEXT_NO_SPACE: i32 = -2;
pub const KEXT_INVALID: i32 = -3;

pub const DRIVER_CLASS_TEST: u64 = 0;
pub const DRIVER_CLASS_BLOCK: u64 = 1;
pub const DRIVER_CLASS_DISPLAY: u64 = 2;

pub type KextEntry = extern "C" fn(api: *const KernelApi) -> i32;

#[repr(C)]
pub struct KernelApi {
    pub abi_version: u64,
    pub log: extern "C" fn(ptr: *const u8, len: usize),
    pub register_driver: extern "C" fn(driver: *const DriverDescriptor) -> i32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct Provider {
    pub id: u64,
    pub class: u64,
    pub name_ptr: *const u8,
    pub name_len: usize,
    pub mmio_base: u64,
    pub mmio_len: u64,
    pub irq: u64,
    pub ecam_base: u64,
    pub pci_bus: u64,
    pub pci_device: u64,
    pub pci_function: u64,
    pub pci_vendor_id: u64,
    pub pci_device_id: u64,
}

#[repr(C)]
pub struct DriverDescriptor {
    pub abi_version: u64,
    pub name_ptr: *const u8,
    pub name_len: usize,
    pub class: u64,
    pub probe: Option<extern "C" fn(provider: *const Provider) -> i32>,
    pub start: Option<extern "C" fn(provider: *const Provider, api: *const KernelApi) -> i32>,
    pub stop: Option<extern "C" fn(instance: *mut u8)>,
}
