//! Mach IPC type definitions matching XNU osfmk/mach/port.h and osfmk/ipc/ipc_types.h.

pub type IpcPortT = u64;
pub type IpcEntryT = u64;
pub type IpcObjectT = u64;

pub type MachPortNameT = u32;

#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MachPortRight {
    Send = 0,
    Receive = 1,
    SendOnce = 2,
    PortSet = 3,
    DeadName = 4,
    Number = 5,
}

pub type MachPortTypeT = u16;
pub type MachPortUrefsT = u32;
pub type MachPortMscountT = u32;
pub type MachPortSeqnoT = u32;

pub const MACH_PORT_NULL: MachPortNameT = 0;
pub const MACH_PORT_DEAD: MachPortNameT = !0u32;

#[inline(always)]
pub fn mach_port_valid(name: MachPortNameT) -> bool {
    name != MACH_PORT_NULL
}

pub const IP_NULL: IpcPortT = 0;

#[inline(always)]
pub fn ip_valid(port: IpcPortT) -> bool {
    port != IP_NULL
}

pub type IoBitsT = u32;
pub type IoReferencesT = u32;

#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Iot {
    Port = 1,
    PortSet = 2,
    DeadName = 3,
    Task = 4,
    Thread = 5,
    Host = 6,
    HostPriv = 7,
    Pset = 8,
}

pub const IO_BITS_REF_MASK: IoBitsT = 0x0000ffff;
pub const IO_BITS_TYPE_MASK: IoBitsT = 0x000f0000;
pub const IO_BITS_TYPE_SHIFT: u32 = 16;

#[inline(always)]
pub fn io_makebits(typ: Iot, refs: IoReferencesT) -> IoBitsT {
    ((typ as u32) << IO_BITS_TYPE_SHIFT) | (refs & IO_BITS_REF_MASK)
}

#[inline(always)]
pub fn io_type(bits: IoBitsT) -> Iot {
    match (bits & IO_BITS_TYPE_MASK) >> IO_BITS_TYPE_SHIFT {
        1 => Iot::Port,
        2 => Iot::PortSet,
        3 => Iot::DeadName,
        4 => Iot::Task,
        5 => Iot::Thread,
        6 => Iot::Host,
        7 => Iot::HostPriv,
        8 => Iot::Pset,
        _ => Iot::Port,
    }
}

#[inline(always)]
pub fn io_refs(bits: IoBitsT) -> IoReferencesT {
    bits & IO_BITS_REF_MASK
}

pub type IpcEntryBitsT = u32;

pub const IE_BITS_TYPE_MASK: IpcEntryBitsT = 0x000f;
pub const IE_BITS_TYPE_SEND: IpcEntryBitsT = 1;
pub const IE_BITS_TYPE_RECEIVE: IpcEntryBitsT = 2;
pub const IE_BITS_TYPE_SEND_ONCE: IpcEntryBitsT = 3;
pub const IE_BITS_TYPE_PORT_SET: IpcEntryBitsT = 4;
pub const IE_BITS_TYPE_DEAD_NAME: IpcEntryBitsT = 5;

pub const IE_BITS_GEN_MASK: IpcEntryBitsT = 0x03f0;
pub const IE_BITS_GEN_SHIFT: u32 = 4;

pub const IE_BITS_UREFS_MASK: IpcEntryBitsT = 0xffff0000;
pub const IE_BITS_UREFS_SHIFT: u32 = 16;

#[inline(always)]
pub fn ie_bits_make(typ: u32, generation: u32, urefs: u32) -> IpcEntryBitsT {
    (typ & IE_BITS_TYPE_MASK)
        | ((generation << IE_BITS_GEN_SHIFT) & IE_BITS_GEN_MASK)
        | ((urefs << IE_BITS_UREFS_SHIFT) & IE_BITS_UREFS_MASK)
}

#[inline(always)]
pub fn ie_bits_type(bits: IpcEntryBitsT) -> u32 {
    bits & IE_BITS_TYPE_MASK
}

#[inline(always)]
pub fn ie_bits_gen(bits: IpcEntryBitsT) -> u32 {
    (bits & IE_BITS_GEN_MASK) >> IE_BITS_GEN_SHIFT
}

#[inline(always)]
pub fn ie_bits_urefs(bits: IpcEntryBitsT) -> u32 {
    (bits & IE_BITS_UREFS_MASK) >> IE_BITS_UREFS_SHIFT
}

pub type IpcTableIndexT = u32;
pub type IpcTableSizeT = u32;

pub const IPC_TABLE_SIZE_MIN: IpcTableSizeT = 2;
pub const IPC_TABLE_SIZE_MAX: IpcTableSizeT = 65536;
pub const IPC_TABLE_SIZE_NONE: IpcTableSizeT = 0;
pub const IPC_TABLE_SIZE_ALL: IpcTableSizeT = 65536;

#[inline(always)]
pub fn ipc_table_size_entries(count: IpcTableSizeT) -> IpcTableSizeT {
    if count < 1 { IPC_TABLE_SIZE_MIN } else { count }
}
