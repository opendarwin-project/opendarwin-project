//! IORegistry singleton — root tree, driver candidates, match/start.

const types = @import("types.zig");
const service = @import("service.zig");
const uart = @import("../drivers/uart.zig");

pub const DriverCandidate = struct {
    /// Driver IOClass name (e.g. "VirtioGpuFramebuffer").
    class_name: []const u8,
    /// Required provider class (e.g. "IOPCIDevice" or "IODisplayNub").
    provider_class: []const u8,
    /// Extra match beyond provider class.
    match: *const fn (*service.IOService) bool,
    /// Allocate/attach/start a driver instance under the provider.
    attach_and_start: *const fn (*service.IOService) types.IOReturn,
};

var root_service: service.IOService = .{};
var initialized: bool = false;

var published: [types.MAX_SERVICES]*service.IOService = undefined;
var published_count: usize = 0;

var drivers: [types.MAX_DRIVERS]DriverCandidate = undefined;
var driver_count: usize = 0;

pub fn init() void {
    if (initialized) return;
    root_service.init("IORegistryRoot", "Root", "");
    root_service.state.registered = true;
    root_service.state.started = true;
    published_count = 0;
    driver_count = 0;
    initialized = true;
}

pub fn root() *service.IOService {
    return &root_service;
}

pub fn registerDriver(candidate: DriverCandidate) bool {
    if (driver_count >= types.MAX_DRIVERS) return false;
    drivers[driver_count] = candidate;
    driver_count += 1;
    return true;
}

pub fn publish(svc: *service.IOService) bool {
    if (!initialized) return false;
    if (published_count >= types.MAX_SERVICES) return false;
    if (!root_service.entry.attachChild(svc.asEntry())) return false;
    published[published_count] = svc;
    published_count += 1;
    svc.state.registered = true;

    uart.print("opendarwin: iokit published: ");
    uart.print(svc.getClassName());
    uart.print(" ");
    uart.print(svc.entry.getName());
    if (svc.entry.location_len > 0) {
        uart.print("@");
        uart.print(svc.entry.getLocation());
    }
    uart.print("\n");
    return true;
}

pub fn publishedCount() usize {
    return published_count;
}

pub fn publishedAt(index: usize) ?*service.IOService {
    if (index >= published_count) return null;
    return published[index];
}

fn classEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

pub fn matchAndStartDrivers() usize {
    var started: usize = 0;
    for (0..published_count) |pi| {
        const provider = published[pi];
        for (0..driver_count) |di| {
            const drv = drivers[di];
            if (!classEql(provider.getClassName(), drv.provider_class)) continue;
            if (!drv.match(provider)) continue;
            const rc = drv.attach_and_start(provider);
            if (rc == types.kIOReturnSuccess) {
                started += 1;
                provider.state.matched = true;
                uart.print("opendarwin: iokit started: ");
                uart.print(drv.class_name);
                uart.print(" on ");
                uart.print(provider.entry.getName());
                uart.print("\n");
            }
        }
    }
    return started;
}
