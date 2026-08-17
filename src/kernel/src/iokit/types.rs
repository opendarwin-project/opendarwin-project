//! IOKit error codes and type definitions matching Darwin IOKit/IOReturn.h.

pub type IOReturn = i32;

pub const IO_RETURN_SUCCESS: IOReturn = 0;
pub const IO_RETURN_ERROR: IOReturn = -536870212; // 0xe00002bc
pub const IO_RETURN_NO_MEMORY: IOReturn = -536870211; // 0xe00002bd
pub const IO_RETURN_NO_DEVICE: IOReturn = -536870210; // 0xe00002be
pub const IO_RETURN_NOT_READY: IOReturn = -536870196; // 0xe00002cc
pub const IO_RETURN_BAD_ARGUMENT: IOReturn = -536870183; // 0xe00002d9
pub const IO_RETURN_UNSUPPORTED: IOReturn = -536870099; // 0xe000032d

pub const MAX_SERVICES: usize = 32;
pub const MAX_PROPERTIES: usize = 16;
pub const MAX_CHILDREN: usize = 8;
pub const MAX_CLIENTS: usize = 16;
