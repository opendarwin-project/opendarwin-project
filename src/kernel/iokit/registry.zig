//! IORegistry singleton — root tree, driver candidates, match/start.
//! Published services and catalogue personalities are unbounded lists.

const types = @import("types.zig");
const service = @import("service.zig");
const uart = @import("../drivers/uart.zig");
const slab = @import("../mm/slab.zig");

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

const PublishedNode = struct {
    next: ?*PublishedNode = null,
    svc: *service.IOService,
};

const DriverNode = struct {
    next: ?*DriverNode = null,
    candidate: DriverCandidate,
};

var root_service: service.IOService = .{};
var initialized: bool = false;

var published_head: ?*PublishedNode = null;
var published_tail: ?*PublishedNode = null;
var published_count: usize = 0;

var driver_head: ?*DriverNode = null;
var driver_tail: ?*DriverNode = null;

pub fn init() void {
    if (initialized) return;
    root_service.init("IORegistryRoot", "Root", "");
    root_service.state.registered = true;
    root_service.state.started = true;
    published_head = null;
    published_tail = null;
    published_count = 0;
    driver_head = null;
    driver_tail = null;
    initialized = true;
}

pub fn root() *service.IOService {
    return &root_service;
}

pub fn registerDriver(candidate: DriverCandidate) bool {
    const node = slab.allocObj(DriverNode);
    node.* = .{ .candidate = candidate };
    if (driver_tail) |tail| {
        tail.next = node;
        driver_tail = node;
    } else {
        driver_head = node;
        driver_tail = node;
    }
    return true;
}

pub fn publish(svc: *service.IOService) bool {
    if (!initialized) return false;
    if (!root_service.entry.attachChild(svc.asEntry())) return false;
    const node = slab.allocObj(PublishedNode);
    node.* = .{ .svc = svc };
    if (published_tail) |tail| {
        tail.next = node;
        published_tail = node;
    } else {
        published_head = node;
        published_tail = node;
    }
    published_count += 1;
    svc.state.registered = true;

    uart.print("opendarwin: iokit published: ");
    uart.print(svc.getClassName());
    uart.print(" ");
    uart.print(svc.entry.getName());
    if (svc.entry.getLocation().len > 0) {
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
    var i: usize = 0;
    var node = published_head;
    while (node) |n| : (node = n.next) {
        if (i == index) return n.svc;
        i += 1;
    }
    return null;
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
    var pnode = published_head;
    while (pnode) |pn| : (pnode = pn.next) {
        const provider = pn.svc;
        var dnode = driver_head;
        while (dnode) |dn| : (dnode = dn.next) {
            const drv = dn.candidate;
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
