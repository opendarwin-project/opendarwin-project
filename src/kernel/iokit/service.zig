//! IOService — lifecycle + matching on top of IORegistryEntry.

const types = @import("types.zig");
const registry_entry = @import("registry_entry.zig");
const slab = @import("../mm/slab.zig");

pub const State = packed struct(u32) {
    registered: bool = false,
    matched: bool = false,
    started: bool = false,
    _pad: u29 = 0,
};

pub const IOServiceVtable = struct {
    probe: *const fn (*IOService, *IOService) types.IOReturn,
    start: *const fn (*IOService, *IOService) types.IOReturn,
    stop: *const fn (*IOService, *IOService) void,
    /// Optional; return true if this driver matches the provider.
    matchPropertyTable: ?*const fn (*IOService, *IOService) bool = null,
};

fn defaultProbe(_: *IOService, _: *IOService) types.IOReturn {
    return types.kIOReturnSuccess;
}

fn defaultStart(_: *IOService, _: *IOService) types.IOReturn {
    return types.kIOReturnSuccess;
}

fn defaultStop(_: *IOService, _: *IOService) void {}

pub const default_vtable = IOServiceVtable{
    .probe = defaultProbe,
    .start = defaultStart,
    .stop = defaultStop,
    .matchPropertyTable = null,
};

pub const IOService = struct {
    entry: registry_entry.IORegistryEntry = .{},
    vtable: *const IOServiceVtable = &default_vtable,
    provider: ?*IOService = null,
    state: State = .{},
    class_name: []const u8 = &.{},

    pub fn init(self: *IOService, class_name: []const u8, name: []const u8, location: []const u8) void {
        self.* = .{
            .vtable = &default_vtable,
        };
        self.entry.init(name, location);
        self.setClassName(class_name);
        _ = self.entry.setPropertyStr("IOClass", class_name);
    }

    pub fn setClassName(self: *IOService, class_name: []const u8) void {
        self.class_name = dupSlice(class_name);
    }

    pub fn getClassName(self: *const IOService) []const u8 {
        return self.class_name;
    }

    pub fn asEntry(self: *IOService) *registry_entry.IORegistryEntry {
        return &self.entry;
    }

    pub fn fromEntry(entry: *registry_entry.IORegistryEntry) *IOService {
        return @fieldParentPtr("entry", entry);
    }

    pub fn attachToProvider(self: *IOService, provider: *IOService) bool {
        if (!provider.entry.attachChild(&self.entry)) return false;
        self.provider = provider;
        return true;
    }

    pub fn probe(self: *IOService, provider: *IOService) types.IOReturn {
        return self.vtable.probe(self, provider);
    }

    pub fn start(self: *IOService, provider: *IOService) types.IOReturn {
        const rc = self.vtable.start(self, provider);
        if (rc == types.kIOReturnSuccess) self.state.started = true;
        return rc;
    }

    pub fn stop(self: *IOService, provider: *IOService) void {
        self.vtable.stop(self, provider);
        self.state.started = false;
    }

    pub fn matchesProvider(self: *IOService, provider: *IOService) bool {
        if (self.vtable.matchPropertyTable) |matchFn| {
            return matchFn(self, provider);
        }
        return true;
    }
};

fn dupSlice(s: []const u8) []const u8 {
    if (s.len == 0) return &.{};
    const buf: [*]u8 = @ptrCast(slab.alloc(s.len));
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}
