//! IOKit-style status codes (Zig core).
//!
//! Collection sizes are unbounded: children, properties, published services,
//! and catalogue personalities are slab-allocated lists, matching XNU's
//! OSOrderedSet / OSDictionary / IOCatalogue.

pub const IOReturn = i32;

pub const kIOReturnSuccess: IOReturn = 0;
pub const kIOReturnError: IOReturn = -1;
pub const kIOReturnBadArgument: IOReturn = -2;
pub const kIOReturnNoMemory: IOReturn = -3;
pub const kIOReturnUnsupported: IOReturn = -4;
pub const kIOReturnNotReady: IOReturn = -5;
pub const kIOReturnNoDevice: IOReturn = -6;
pub const kIOReturnAborted: IOReturn = -7;

/// Property value stored in the registry bag (numeric or short string).
pub const PropertyValue = union(enum) {
    u64: u64,
    str: []const u8,
};
