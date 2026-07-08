const types = @import("types.zig");
const IpcEntry = @import("entry.zig").IpcEntry;
const IpcSpace = @import("space.zig").IpcSpace;
const IpcPort = @import("port.zig").IpcPort;

/// Result of a right lookup.
pub const RightResult = struct {
    entry: *IpcEntry,
    name: types.mach_port_name_t,
    port: ?*IpcPort,
};

/// Allocate a free entry in `space` for `port` with the given right type.
/// Returns the allocated entry and the name assigned to it.
pub fn alloc(space: *IpcSpace, port: *IpcPort, typ: u32) RightResult {
    const entry = space.allocEntry() orelse @panic("ipc_right: space full");
    const gen = entry.gen();
    const name = gen << 16 | entry.ie_index;
    entry.ie_object = @ptrCast(port);
    entry.ie_bits = types.ie_bits_make(typ, gen, 1);
    return .{ .entry = entry, .name = name, .port = port };
}

/// Deallocate an entry in `space` at `name`. Returns the port if any.
pub fn dealloc(space: *IpcSpace, name: types.mach_port_name_t) ?*IpcPort {
    const entry = space.lookupEntry(name) orelse return null;
    const port = if (entry.ie_object) |obj|
        @as(*IpcPort, @ptrCast(obj))
    else
        null;
    entry.ie_object = null;
    entry.ie_bits = 0;
    space.freeEntry(entry);
    return port;
}

/// Look up an entry in `space` by `name`. Returns the entry and port.
pub fn lookup(space: *IpcSpace, name: types.mach_port_name_t) ?RightResult {
    const entry = space.lookupEntry(name) orelse return null;
    if (entry.isFree()) return null;
    const port = if (entry.ie_object) |obj|
        @as(*IpcPort, @ptrCast(obj))
    else
        null;
    return .{ .entry = entry, .name = name, .port = port };
}
