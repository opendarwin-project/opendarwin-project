//! Mach host port bootstrap.

use crate::ipc::port::IpcPort;
use crate::ipc::right;
use crate::ipc::space::IpcSpace;
use crate::ipc::types::IE_BITS_TYPE_RECEIVE;
use core::sync::atomic::{AtomicPtr, Ordering};

static HOST_PORT: AtomicPtr<IpcPort> = AtomicPtr::new(core::ptr::null_mut());

pub fn bootstrap(space: &mut IpcSpace) -> *mut IpcPort {
    let port = IpcPort::alloc();
    HOST_PORT.store(port, Ordering::Release);
    _ = right::alloc(space, port, IE_BITS_TYPE_RECEIVE);
    port
}

pub fn get_host_port() -> &'static mut IpcPort {
    let ptr = HOST_PORT.load(Ordering::Acquire);
    unsafe { &mut *ptr }
}
