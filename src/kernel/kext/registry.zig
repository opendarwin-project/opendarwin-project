const api = @import("api.zig");
const uart = @import("../drivers/uart.zig");
const conduit = @import("conduit");
const provider_info = @import("../device/provider.zig");

const MAX_DRIVERS: usize = 16;
const MAX_PROVIDERS: usize = 16;

var drivers: [MAX_DRIVERS]*const api.DriverDescriptor = undefined;
var driver_count: usize = 0;
var providers: [MAX_PROVIDERS]api.Provider = undefined;
var provider_count: usize = 0;
var started: [MAX_DRIVERS][MAX_PROVIDERS]bool = [_][MAX_PROVIDERS]bool{[_]bool{false} ** MAX_PROVIDERS} ** MAX_DRIVERS;

const smoke_provider_name = "kext-smoke-provider";

pub const kernel_api = api.KernelApi{
    .abi_version = api.ABI_VERSION,
    .log = log,
    .register_driver = registerDriver,
};

pub fn log(ptr: [*]const u8, len: usize) callconv(.c) void {
    uart.print(ptr[0..len]);
}

pub fn registerDriver(driver: *const api.DriverDescriptor) callconv(.c) i32 {
    if (driver.abi_version != api.ABI_VERSION) return api.KEXT_BAD_ABI;
    if (@intFromPtr(driver.name_ptr) == 0 or driver.name_len == 0 or driver.name_len > 64) return api.KEXT_INVALID;
    if (driver_count >= MAX_DRIVERS) return api.KEXT_NO_SPACE;

    const idx = driver_count;
    drivers[idx] = driver;
    driver_count += 1;

    uart.print("opendarwin: driver registered: ");
    printDriverName(driver);
    uart.print("\n");

    for (0..provider_count) |provider_idx| startIfMatched(idx, provider_idx);
    return api.KEXT_SUCCESS;
}

pub fn publishProvider(provider: api.Provider) bool {
    if (provider.name_len == 0 or @intFromPtr(provider.name_ptr) == 0 or provider.name_len > 64) return false;
    if (provider_count >= MAX_PROVIDERS) return false;

    const idx = provider_count;
    providers[idx] = provider;
    provider_count += 1;

    uart.print("opendarwin: provider published: ");
    uart.print(provider.name_ptr[0..provider.name_len]);
    uart.print("\n");

    for (0..driver_count) |driver_idx| startIfMatched(driver_idx, idx);
    return true;
}

pub fn publishSmokeProvider() bool {
    return publishProvider(.{
        .id = 1,
        .class = api.DRIVER_CLASS_TEST,
        .name_ptr = smoke_provider_name.ptr,
        .name_len = smoke_provider_name.len,
        .mmio_base = 0,
        .mmio_len = 0,
        .irq = 0,
    });
}

pub fn publishConduitProvider(id: u64, class_value: conduit.Class, name: []const u8, mmio_base: u64, mmio_len: u64, irq: u64) bool {
    const class = driverClassFromConduit(class_value) orelse return false;
    return publishProvider(.{
        .id = id,
        .class = class,
        .name_ptr = name.ptr,
        .name_len = name.len,
        .mmio_base = mmio_base,
        .mmio_len = mmio_len,
        .irq = irq,
    });
}

pub fn publishProviderInfo(id: u64, info: provider_info.Info) bool {
    return publishConduitProvider(id, info.class, info.name, info.mmio_base, info.mmio_len, info.irq);
}

pub fn count() usize {
    return driver_count;
}

pub fn providerCount() usize {
    return provider_count;
}

fn startIfMatched(driver_idx: usize, provider_idx: usize) void {
    if (started[driver_idx][provider_idx]) return;
    const driver = drivers[driver_idx];
    const provider = &providers[provider_idx];
    if (driver.class != provider.class) return;
    if (driver.probe) |probe| {
        if (probe(provider) != api.KEXT_SUCCESS) return;
    }
    const start = driver.start orelse return;
    if (start(provider, &kernel_api) != api.KEXT_SUCCESS) return;

    started[driver_idx][provider_idx] = true;
    uart.print("opendarwin: driver started: ");
    printDriverName(driver);
    uart.print(" on ");
    uart.print(provider.name_ptr[0..provider.name_len]);
    uart.print("\n");
}

fn driverClassFromConduit(class: conduit.Class) ?u64 {
    return switch (class) {
        .block => api.DRIVER_CLASS_BLOCK,
        else => null,
    };
}

fn printDriverName(driver: *const api.DriverDescriptor) void {
    uart.print(driver.name_ptr[0..driver.name_len]);
}
