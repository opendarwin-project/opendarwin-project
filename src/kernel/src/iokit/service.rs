//! Base IOService class matching Darwin IOKit/IOService.h.

use crate::iokit::registry_entry::IORegistryEntry;
use crate::iokit::types::{IO_RETURN_SUCCESS, IOReturn};

pub struct IOServiceVtable {
    pub probe: fn(svc: *mut IOService, provider: *mut IOService) -> IOReturn,
    pub start: fn(svc: *mut IOService, provider: *mut IOService) -> IOReturn,
    pub stop: fn(svc: *mut IOService, provider: *mut IOService),
    pub match_property_table: Option<fn(svc: *mut IOService, table: *const u8) -> bool>,
}

pub struct IOService {
    pub entry: IORegistryEntry,
    pub class_name: [u8; 32],
    pub class_name_len: usize,
    pub provider: Option<*mut IOService>,
    pub vtable: Option<&'static IOServiceVtable>,
}

impl Default for IOService {
    fn default() -> Self {
        Self::new()
    }
}

impl IOService {
    pub const fn new() -> Self {
        Self {
            entry: IORegistryEntry::new(),
            class_name: [0; 32],
            class_name_len: 0,
            provider: None,
            vtable: None,
        }
    }

    pub fn init(&mut self, class_name: &str, name: &str, _location: &str) {
        self.entry.init(name);
        self.set_class_name(class_name);
        self.provider = None;
    }

    pub fn get_class_name(&self) -> &str {
        core::str::from_utf8(&self.class_name[..self.class_name_len]).unwrap_or("")
    }

    pub fn set_class_name(&mut self, class_name: &str) {
        let n = class_name.len().min(self.class_name.len());
        self.class_name[..n].copy_from_slice(&class_name.as_bytes()[..n]);
        self.class_name_len = n;
    }

    pub fn attach_to_provider(&mut self, provider: *mut IOService) -> bool {
        self.provider = Some(provider);
        unsafe { (*provider).entry.add_child(&mut self.entry) }
    }

    pub fn probe(&mut self, provider: *mut IOService) -> IOReturn {
        if let Some(vtable) = self.vtable {
            (vtable.probe)(self as *mut IOService, provider)
        } else {
            IO_RETURN_SUCCESS
        }
    }

    pub fn start(&mut self, provider: *mut IOService) -> IOReturn {
        if let Some(vtable) = self.vtable {
            (vtable.start)(self as *mut IOService, provider)
        } else {
            IO_RETURN_SUCCESS
        }
    }

    pub fn stop(&mut self, provider: *mut IOService) {
        if let Some(vtable) = self.vtable {
            (vtable.stop)(self as *mut IOService, provider);
        }
    }

    pub fn from_entry(entry: *mut IORegistryEntry) -> *mut IOService {
        entry as *mut IOService
    }
}
