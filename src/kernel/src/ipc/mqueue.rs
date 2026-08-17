//! Mach message queue attached to ports.

use crate::ipc::kmsg::IpcKmsg;

pub const MACH_PORT_QLIMIT_DEFAULT: u32 = 16;

#[derive(Clone, Copy)]
pub struct IpcMqueue {
    pub head: *mut IpcKmsg,
    pub tail: *mut IpcKmsg,
    pub count: u32,
    pub qlimit: u32,
}

impl Default for IpcMqueue {
    fn default() -> Self {
        Self::new()
    }
}

impl IpcMqueue {
    pub const fn new() -> Self {
        Self {
            head: core::ptr::null_mut(),
            tail: core::ptr::null_mut(),
            count: 0,
            qlimit: MACH_PORT_QLIMIT_DEFAULT,
        }
    }

    pub fn init(&mut self) {
        self.head = core::ptr::null_mut();
        self.tail = core::ptr::null_mut();
        self.count = 0;
        self.qlimit = MACH_PORT_QLIMIT_DEFAULT;
    }

    pub fn enqueue(&mut self, kmsg: *mut IpcKmsg) -> bool {
        if self.count >= self.qlimit {
            return false;
        }
        unsafe {
            (*kmsg).next = core::ptr::null_mut();
            if self.tail.is_null() {
                self.head = kmsg;
                self.tail = kmsg;
            } else {
                (*self.tail).next = kmsg;
                self.tail = kmsg;
            }
            self.count += 1;
        }
        true
    }

    pub fn dequeue(&mut self) -> Option<*mut IpcKmsg> {
        if self.head.is_null() {
            return None;
        }
        unsafe {
            let kmsg = self.head;
            self.head = (*kmsg).next;
            if self.head.is_null() {
                self.tail = core::ptr::null_mut();
            }
            (*kmsg).next = core::ptr::null_mut();
            self.count -= 1;
            Some(kmsg)
        }
    }

    pub fn is_empty(&self) -> bool {
        self.count == 0
    }
}
