//! Thread dispatch into EL0 userspace.

use crate::arch::aarch64::enterUserspace;
use crate::proc::task::Task;

pub fn enter(task: &Task) -> ! {
    unsafe {
        enterUserspace(&task.frame, task.ttbr0 as u64);
    }
}
