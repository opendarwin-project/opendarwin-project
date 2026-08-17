//! Mach message buffer and header representations.

use crate::ipc::types::MachPortNameT;
use crate::mm::slab;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MachMsgHeader {
    pub msgh_bits: u32,
    pub msgh_size: u32,
    pub msgh_remote_port: MachPortNameT,
    pub msgh_local_port: MachPortNameT,
    pub msgh_voucher_port: MachPortNameT,
    pub msgh_id: u32,
}

#[repr(C)]
pub struct IpcKmsg {
    pub next: *mut IpcKmsg,
    pub ikm_size: u32,
    pub ikm_header: MachMsgHeader,
}

impl IpcKmsg {
    pub fn alloc(header: MachMsgHeader) -> Option<*mut IpcKmsg> {
        let hdr_size = core::mem::size_of::<MachMsgHeader>() as u32;
        if header.msgh_size < hdr_size {
            return None;
        }
        let body_len = header.msgh_size - hdr_size;
        let total = core::mem::size_of::<IpcKmsg>() + body_len as usize;
        let ptr = slab::alloc(total) as *mut IpcKmsg;
        unsafe {
            (*ptr).next = core::ptr::null_mut();
            (*ptr).ikm_size = header.msgh_size;
            (*ptr).ikm_header = header;
        }
        Some(ptr)
    }

    pub fn free(kmsg: *mut IpcKmsg) {
        slab::free(kmsg as *mut u8);
    }

    pub fn body(kmsg: *mut IpcKmsg) -> &'static mut [u8] {
        unsafe {
            let body_start = (kmsg as usize) + core::mem::size_of::<IpcKmsg>();
            let hdr_size = core::mem::size_of::<MachMsgHeader>() as u32;
            let body_len = (*kmsg).ikm_header.msgh_size - hdr_size;
            core::slice::from_raw_parts_mut(body_start as *mut u8, body_len as usize)
        }
    }
}
