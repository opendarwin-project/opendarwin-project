pub const ABI_VERSION: u64 = 3;

pub const KEXT_SUCCESS: i32 = 0;
pub const KEXT_BAD_ABI: i32 = -1;
pub const KEXT_NO_SPACE: i32 = -2;
pub const KEXT_INVALID: i32 = -3;

pub const DRIVER_CLASS_TEST: u64 = 0;
pub const DRIVER_CLASS_BLOCK: u64 = 1;
pub const DRIVER_CLASS_DISPLAY: u64 = 2;

pub const KextEntry = *const fn (api: *const KernelApi) callconv(.c) i32;

/// Kernel exports available to loaded kexts. ABI 3 drops `start_display`;
/// display bind is owned by the Zig IOKit path (VirtioGpuFramebuffer).
pub const KernelApi = extern struct {
    abi_version: u64,
    log: *const fn (ptr: [*]const u8, len: usize) callconv(.c) void,
    register_driver: *const fn (driver: *const DriverDescriptor) callconv(.c) i32,
};

/// Device node published by the kernel for driver matching. Wider integer
/// fields keep the layout simple for assembly kexts.
pub const Provider = extern struct {
    id: u64,
    class: u64,
    name_ptr: [*]const u8,
    name_len: usize,
    mmio_base: u64,
    mmio_len: u64,
    irq: u64,
    ecam_base: u64 = 0,
    pci_bus: u64 = 0,
    pci_device: u64 = 0,
    pci_function: u64 = 0,
    pci_vendor_id: u64 = 0,
    pci_device_id: u64 = 0,
};

pub const DriverDescriptor = extern struct {
    abi_version: u64,
    name_ptr: [*]const u8,
    name_len: usize,
    class: u64,
    probe: ?*const fn (provider: ?*const Provider) callconv(.c) i32,
    start: ?*const fn (provider: ?*const Provider, api: *const KernelApi) callconv(.c) i32,
    stop: ?*const fn (instance: ?*anyopaque) callconv(.c) void,
};
