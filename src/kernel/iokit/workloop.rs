//! IOWorkLoop representation matching Darwin IOKit/IOWorkLoop.h.

pub struct IOWorkLoop {
    pub is_enabled: bool,
}

impl Default for IOWorkLoop {
    fn default() -> Self {
        Self::new()
    }
}

impl IOWorkLoop {
    pub const fn new() -> Self {
        Self { is_enabled: true }
    }
}
