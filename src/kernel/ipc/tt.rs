//! Task and Thread self Mach port bootstrap.

use crate::ipc::port::IpcPort;
use crate::ipc::right;
use crate::ipc::space::IpcSpace;
use crate::ipc::types::{IE_BITS_TYPE_SEND, MachPortNameT};

pub fn task_self(space: &mut IpcSpace, task: *mut u8, name_out: &mut MachPortNameT) {
    let port = IpcPort::alloc();
    unsafe {
        (*port).ip_kobject = task;
    }
    let res = right::alloc(space, port, IE_BITS_TYPE_SEND);
    *name_out = res.name;
}

pub fn thread_self(space: &mut IpcSpace, thread: *mut u8, name_out: &mut MachPortNameT) {
    let port = IpcPort::alloc();
    unsafe {
        (*port).ip_kobject = thread;
    }
    let res = right::alloc(space, port, IE_BITS_TYPE_SEND);
    *name_out = res.name;
}
