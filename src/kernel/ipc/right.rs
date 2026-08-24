//! Mach port right operations (`ipc_right`).

use crate::ipc::entry::IpcEntry;
use crate::ipc::object::IpcObject;
use crate::ipc::port::IpcPort;
use crate::ipc::space::IpcSpace;
use crate::ipc::types::{
    IE_BITS_TYPE_DEAD_NAME, IE_BITS_TYPE_RECEIVE, IE_BITS_TYPE_SEND, IE_BITS_TYPE_SEND_ONCE,
    MachPortNameT,
};

#[derive(Clone, Copy)]
pub struct RightLookupResult {
    pub name: MachPortNameT,
    pub port: Option<*mut IpcPort>,
    pub entry: IpcEntry,
}

#[derive(Clone, Copy)]
pub struct RightAllocResult {
    pub name: MachPortNameT,
    pub port: *mut IpcPort,
}

pub fn lookup(space: &mut IpcSpace, name: MachPortNameT) -> Option<RightLookupResult> {
    let entry = *space.lookup(name)?;
    let port = if entry.type_of() == IE_BITS_TYPE_DEAD_NAME || entry.ie_object.is_null() {
        None
    } else {
        Some(entry.ie_object as *mut IpcPort)
    };
    Some(RightLookupResult { name, port, entry })
}

pub fn alloc(space: &mut IpcSpace, port: *mut IpcPort, right_type: u32) -> RightAllocResult {
    // If port already has a receiver in this space, reuse name
    unsafe {
        if right_type == IE_BITS_TYPE_RECEIVE
            && (*port).ip_receiver == space
            && (*port).ip_receiver_name != 0
        {
            return RightAllocResult {
                name: (*port).ip_receiver_name,
                port,
            };
        }
    }

    let name = space.allocate_name().expect("ipc_right: space table full");
    let generation = (name & 0x3f) as u32;

    let mut entry = IpcEntry::default();
    entry.init(port as *mut IpcObject, right_type, generation, 1);
    space.insert(name, entry);
    unsafe {
        match right_type {
            IE_BITS_TYPE_RECEIVE => {
                (*port).ip_receiver = space;
                (*port).ip_receiver_name = name;
            }
            IE_BITS_TYPE_SEND => {
                (*port).ip_srights += 1;
            }
            IE_BITS_TYPE_SEND_ONCE => {
                (*port).ip_sorights += 1;
            }
            _ => {}
        }
    }

    RightAllocResult { name, port }
}

pub fn dealloc(space: &mut IpcSpace, name: MachPortNameT) -> bool {
    let Some(looked) = lookup(space, name) else {
        return false;
    };

    if let Some(port) = looked.port {
        unsafe {
            match looked.entry.type_of() {
                IE_BITS_TYPE_SEND => {
                    if (*port).ip_srights > 0 {
                        (*port).ip_srights -= 1;
                    }
                }
                IE_BITS_TYPE_SEND_ONCE => {
                    if (*port).ip_sorights > 0 {
                        (*port).ip_sorights -= 1;
                    }
                }
                IE_BITS_TYPE_RECEIVE => {
                    (*port).ip_receiver = core::ptr::null_mut();
                    (*port).ip_receiver_name = 0;
                }
                _ => {}
            }
        }
    }

    space.remove(name)
}
