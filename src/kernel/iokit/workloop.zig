//! Stub IOWorkLoop / IOInterruptEventSource (no real IRQ wiring yet).

const types = @import("types.zig");

pub const Action = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;

pub const IOInterruptEventSource = struct {
    owner: ?*anyopaque = null,
    action: ?Action = null,
    enabled: bool = false,

    pub fn init(self: *IOInterruptEventSource, owner: ?*anyopaque, action: Action) void {
        self.* = .{
            .owner = owner,
            .action = action,
            .enabled = false,
        };
    }

    pub fn enable(self: *IOInterruptEventSource) void {
        self.enabled = true;
    }

    pub fn disable(self: *IOInterruptEventSource) void {
        self.enabled = false;
    }

    pub fn signal(self: *IOInterruptEventSource) void {
        if (!self.enabled) return;
        if (self.action) |action| action(self.owner, self);
    }
};

pub const IOWorkLoop = struct {
    sources: [4]?*IOInterruptEventSource = .{null} ** 4,
    source_count: usize = 0,

    pub fn init(self: *IOWorkLoop) void {
        self.* = .{};
    }

    pub fn addEventSource(self: *IOWorkLoop, source: *IOInterruptEventSource) types.IOReturn {
        if (self.source_count >= self.sources.len) return types.kIOReturnNoMemory;
        self.sources[self.source_count] = source;
        self.source_count += 1;
        return types.kIOReturnSuccess;
    }

    pub fn runAction(self: *IOWorkLoop, action: Action, target: ?*anyopaque, arg: ?*anyopaque) types.IOReturn {
        _ = self;
        action(target, arg);
        return types.kIOReturnSuccess;
    }
};
