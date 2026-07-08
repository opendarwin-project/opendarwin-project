/// Mach IPC type definitions, based on XNU osfmk/mach/port.h,
/// osfmk/ipc/ipc_types.h, and related headers.
pub const ipc_port_t = u64;
pub const ipc_entry_t = u64;
pub const ipc_object_t = u64;

pub const mach_port_name_t = u32;
pub const mach_port_right_t = enum(u32) {
    SEND = 0,
    RECEIVE = 1,
    SEND_ONCE = 2,
    PORT_SET = 3,
    DEAD_NAME = 4,
    NUMBER = 5,
    _,
};
pub const mach_port_type_t = u16;
pub const mach_port_urefs_t = u32;
pub const mach_port_mscount_t = u32;
pub const mach_port_seqno_t = u32;

pub const MACH_PORT_NULL: mach_port_name_t = 0;
pub const MACH_PORT_DEAD: mach_port_name_t = ~@as(u32, 0);
pub inline fn MACH_PORT_VALID(name: mach_port_name_t) bool {
    return name != MACH_PORT_NULL;
}

pub const IP_NULL: ipc_port_t = 0;
pub inline fn IP_VALID(port: ipc_port_t) bool {
    return port != IP_NULL;
}

pub const io_bits_t = u32;
pub const io_references_t = u32;

pub const IOT = enum(u32) {
    PORT = 1,
    PORT_SET = 2,
    DEAD_NAME = 3,
    TASK = 4,
    THREAD = 5,
    HOST = 6,
    HOST_PRIV = 7,
    PSET = 8,
};

pub const IO_BITS_REF_MASK: io_bits_t = 0x0000ffff;
pub const IO_BITS_TYPE_MASK: io_bits_t = 0x000f0000;
pub const IO_BITS_TYPE_SHIFT: u32 = 16;

pub inline fn io_makebits(typ: IOT, refs: io_references_t) io_bits_t {
    return (@intFromEnum(typ) << IO_BITS_TYPE_SHIFT) | (refs & IO_BITS_REF_MASK);
}
pub inline fn io_type(bits: io_bits_t) IOT {
    return @enumFromInt((bits & IO_BITS_TYPE_MASK) >> IO_BITS_TYPE_SHIFT);
}
pub inline fn io_refs(bits: io_bits_t) io_references_t {
    return bits & IO_BITS_REF_MASK;
}

pub const ipc_entry_bits_t = u32;

pub const IE_BITS_TYPE_MASK: ipc_entry_bits_t = 0x000f;
pub const IE_BITS_TYPE_SEND: ipc_entry_bits_t = 1;
pub const IE_BITS_TYPE_RECEIVE: ipc_entry_bits_t = 2;
pub const IE_BITS_TYPE_SEND_ONCE: ipc_entry_bits_t = 3;
pub const IE_BITS_TYPE_PORT_SET: ipc_entry_bits_t = 4;
pub const IE_BITS_TYPE_DEAD_NAME: ipc_entry_bits_t = 5;

pub const IE_BITS_GEN_MASK: ipc_entry_bits_t = 0x03f0;
pub const IE_BITS_GEN_SHIFT: u32 = 4;

pub const IE_BITS_UREFS_MASK: ipc_entry_bits_t = 0xffff0000;
pub const IE_BITS_UREFS_SHIFT: u32 = 16;

pub inline fn ie_bits_make(typ: u32, gen: u32, urefs: u32) ipc_entry_bits_t {
    return (typ & IE_BITS_TYPE_MASK) |
        ((gen << IE_BITS_GEN_SHIFT) & IE_BITS_GEN_MASK) |
        ((urefs << IE_BITS_UREFS_SHIFT) & IE_BITS_UREFS_MASK);
}
pub inline fn ie_bits_type(bits: ipc_entry_bits_t) u32 {
    return bits & IE_BITS_TYPE_MASK;
}
pub inline fn ie_bits_gen(bits: ipc_entry_bits_t) u32 {
    return (bits & IE_BITS_GEN_MASK) >> IE_BITS_GEN_SHIFT;
}
pub inline fn ie_bits_urefs(bits: ipc_entry_bits_t) u32 {
    return (bits & IE_BITS_UREFS_MASK) >> IE_BITS_UREFS_SHIFT;
}

pub const ipc_table_index_t = u32;
pub const ipc_table_size_t = u32;

pub const IPC_TABLE_SIZE_MIN: ipc_table_size_t = 2;
pub const IPC_TABLE_SIZE_MAX: ipc_table_size_t = 65536;
pub const IPC_TABLE_SIZE_NONE: ipc_table_size_t = 0;
pub const IPC_TABLE_SIZE_ALL: ipc_table_size_t = 65536;

pub inline fn ipc_table_size_entries(count: ipc_table_size_t) ipc_table_size_t {
    return if (count < 1) IPC_TABLE_SIZE_MIN else count;
}
