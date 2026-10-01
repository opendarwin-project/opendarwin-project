//! Abstract IOAccelerator matching Darwin IOKit/graphics/IOAccelerator.h.

use crate::iokit::service::IOService;

pub const CLASS_NAME: &str = "IOAccelerator";

pub struct IOAccelerator {
    pub service: IOService,
}

impl Default for IOAccelerator {
    fn default() -> Self {
        Self::new()
    }
}

impl IOAccelerator {
    pub const fn new() -> Self {
        Self {
            service: IOService::new(),
        }
    }

    pub fn init(&mut self, name: &str) {
        self.service.init(CLASS_NAME, name, "");
    }
}
