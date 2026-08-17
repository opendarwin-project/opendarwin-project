//! Syscall entry dispatch based on SVC instruction immediate.

use crate::arch::aarch64::context::Frame;
use crate::syscall::{mach, unix};

fn svc_imm(elr: u64) -> u16 {
    if elr < 4 {
        return 0;
    }
    unsafe {
        let instr = *((elr - 4) as *const u32);
        ((instr >> 5) & 0xffff) as u16
    }
}

pub fn handle(frame: &mut Frame) {
    let imm = svc_imm(frame.elr_el1);
    if imm == 0x81 {
        mach::handle(frame);
    } else {
        unix::handle(frame);
    }
}
