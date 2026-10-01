//! Base IOService class matching Darwin IOKit/IOService.h.

use alloc::string::String;

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
    pub class_name: String,
    pub provider: Option<*mut IOService>,
    pub vtable: Option<&'static IOServiceVtable>,
}

unsafe impl Send for IOService {}
unsafe impl Sync for IOService {}

impl Default for IOService {
    fn default() -> Self {
        Self::new()
    }
}

impl IOService {
    pub const fn new() -> Self {
        Self {
            entry: IORegistryEntry::new(),
            class_name: String::new(),
            provider: None,
            vtable: None,
        }
    }

    pub fn init(&mut self, class_name: &str, name: &str, location: &str) {
        self.entry.init(name);
        self.entry.set_location(location);
        self.set_class_name(class_name);
        self.entry.set_property_str("IOClass", class_name);
        self.provider = None;
    }

    pub fn get_class_name(&self) -> &str {
        &self.class_name
    }

    pub fn set_class_name(&mut self, class_name: &str) {
        self.class_name = String::from(class_name);
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
