//! Base IPC object header.

use crate::ipc::types::{IoBitsT, IoReferencesT, Iot, io_makebits, io_refs, io_type};

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct IpcObject {
    pub io_bits: IoBitsT,
    pub io_references: IoReferencesT,
}

impl IpcObject {
    pub fn init(&mut self, typ: Iot) {
        self.io_references = 1;
        self.io_bits = io_makebits(typ, 1);
    }

    pub fn object_type(&self) -> Iot {
        io_type(self.io_bits)
    }

    pub fn references(&self) -> IoReferencesT {
        io_refs(self.io_bits)
    }
}
