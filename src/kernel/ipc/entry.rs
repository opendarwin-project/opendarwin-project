//! Mach IPC space entry (`ipc_entry`).

use crate::ipc::object::IpcObject;
use crate::ipc::types::{
    IpcEntryBitsT, IpcTableIndexT, ie_bits_gen, ie_bits_make, ie_bits_type, ie_bits_urefs,
};

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct IpcEntry {
    pub ie_object: *mut IpcObject,
    pub ie_bits: IpcEntryBitsT,
    pub ie_index: IpcTableIndexT,
}

impl Default for IpcEntry {
    fn default() -> Self {
        Self {
            ie_object: core::ptr::null_mut(),
            ie_bits: 0,
            ie_index: 0,
        }
    }
}

impl IpcEntry {
    pub fn init(&mut self, object: *mut IpcObject, typ: u32, generation: u32, urefs: u32) {
        self.ie_object = object;
        self.ie_bits = ie_bits_make(typ, generation, urefs);
        self.ie_index = 0;
    }

    pub fn type_of(&self) -> u32 {
        ie_bits_type(self.ie_bits)
    }

    pub fn urefs(&self) -> u32 {
        ie_bits_urefs(self.ie_bits)
    }

    pub fn generation(&self) -> u32 {
        ie_bits_gen(self.ie_bits)
    }
}
