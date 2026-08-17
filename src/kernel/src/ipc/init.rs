//! Mach IPC subsystem initialization.

use crate::ipc::host;
use crate::ipc::space::IpcSpace;
use spin::Mutex;

static KERNEL_SPACE: Mutex<IpcSpace> = Mutex::new(IpcSpace::new());

pub fn init() {
    let mut space = KERNEL_SPACE.lock();
    space.init();
    _ = host::bootstrap(&mut space);
}

pub fn get_kernel_space() -> &'static mut IpcSpace {
    let mut space = KERNEL_SPACE.lock();
    unsafe { &mut *(&mut *space as *mut IpcSpace) }
}
