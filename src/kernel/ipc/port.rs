//! Mach port object (`ipc_port`).

use crate::ipc::mqueue::IpcMqueue;
use crate::ipc::object::IpcObject;
use crate::ipc::space::IpcSpace;
use crate::ipc::types::{Iot, MACH_PORT_NULL, MachPortNameT};
use crate::mm::slab;

#[repr(C)]
pub struct IpcPort {
    pub ip_object: IpcObject,
    pub ip_receiver: *mut IpcSpace,
    pub ip_receiver_name: MachPortNameT,
    pub ip_messages: IpcMqueue,
    pub ip_kobject: *mut u8,
    pub ip_nsrequest: *mut IpcPort,
    pub ip_pdrequest: *mut IpcPort,
    pub ip_srights: u32,
    pub ip_sorights: u32,
    pub ip_tempowner: bool,
}

impl IpcPort {
    pub fn alloc() -> *mut IpcPort {
        let port = slab::alloc_obj::<IpcPort>();
        unsafe {
            (*port).ip_object.init(Iot::Port);
            (*port).ip_receiver = core::ptr::null_mut();
            (*port).ip_receiver_name = MACH_PORT_NULL;
            (*port).ip_messages.init();
            (*port).ip_kobject = core::ptr::null_mut();
            (*port).ip_nsrequest = core::ptr::null_mut();
            (*port).ip_pdrequest = core::ptr::null_mut();
            (*port).ip_srights = 0;
            (*port).ip_sorights = 0;
            (*port).ip_tempowner = false;
        }
        port
    }

    pub fn dealloc(port: *mut IpcPort) {
        slab::free(port as *mut u8);
    }
}
