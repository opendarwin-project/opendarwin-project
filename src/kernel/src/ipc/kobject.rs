//! Port kobject abstractions.

pub type IpcKobjectT = *mut u8;

#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KobjectType {
    None = 0,
    Task = 1,
    Thread = 2,
    Host = 3,
    HostPriv = 4,
    Pset = 5,
}
