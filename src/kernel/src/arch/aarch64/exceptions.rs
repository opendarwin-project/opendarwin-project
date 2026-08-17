//! Exception vectors (VBAR_EL1) and exception handling.

use crate::arch::aarch64::context::Frame;
use crate::arch::aarch64::cpu;
use crate::drivers::uart;

unsafe extern "C" {
    static vector_table: u8;
}

pub fn init() {
    let addr = core::ptr::addr_of!(vector_table) as u64;
    unsafe {
        core::arch::asm!(
            "msr vbar_el1, {addr}",
            "isb",
            addr = in(reg) addr,
            options(nomem, nostack)
        );
    }
}

fn halt_forever() -> ! {
    loop {
        cpu::wfe();
    }
}

fn ec_name(ec: u32) -> &'static str {
    match ec {
        0b000000 => "unknown",
        0b000001 => "trapped WFI/WFE",
        0b001110 => "illegal execution state",
        0b010001 => "SVC (AArch32)",
        0b010101 => "SVC (AArch64)",
        0b100000 => "instruction abort (lower EL)",
        0b100001 => "instruction abort (same EL)",
        0b100010 => "PC alignment fault",
        0b100100 => "data abort (lower EL)",
        0b100101 => "data abort (same EL)",
        0b100110 => "SP alignment fault",
        0b101100 => "trapped FP exception (AArch64)",
        _ => "unhandled",
    }
}

fn dump_frame(kind: &str, frame: &Frame) {
    let ec = (frame.esr_el1 >> 26) as u32;

    uart::print("\n--- unhandled ");
    uart::print(kind);
    uart::print(" exception (");
    uart::print(ec_name(ec));
    uart::print(") ---\n");
    print_labeled("  esr_el1  = ", frame.esr_el1);
    print_labeled("  elr_el1  = ", frame.elr_el1);
    print_labeled("  far_el1  = ", frame.far_el1);
    print_labeled("  spsr_el1 = ", frame.spsr_el1);
    print_labeled("  sp_el0   = ", frame.sp_el0);
    print_labeled("  x30 (lr) = ", frame.x[30]);
    print_labeled("  x0       = ", frame.x[0]);
    print_labeled("  x1       = ", frame.x[1]);
    print_labeled("  x2       = ", frame.x[2]);
    print_labeled("  x3       = ", frame.x[3]);
    print_labeled("  x4       = ", frame.x[4]);
    print_labeled("  x5       = ", frame.x[5]);
}

fn print_labeled(label: &str, v: u64) {
    uart::print(label);
    uart::print_hex(v);
    uart::print("\n");
}

#[unsafe(no_mangle)]
pub extern "C" fn handleSyncException(frame: &mut Frame) {
    let ec = ((frame.esr_el1 >> 26) & 0x3f) as u32;
    match ec {
        0b010101 => {
            // SVC (AArch64).
            crate::syscall::dispatch::handle(frame);
            crate::proc::signal::deliver_current(cpu::core_id(), frame);
        }
        0b100100 => {
            // Data abort (lower EL) - could be a COW fault.
            let far = frame.far_el1;
            let current_vmm = crate::proc::sched::current_vmm(cpu::core_id());
            if current_vmm.handle_cow_fault(far) {
                return;
            }
            dump_frame("synchronous", frame);
            halt_forever();
        }
        _ => {
            dump_frame("synchronous", frame);
            halt_forever();
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn handleIrqException(frame: &mut Frame) {
    let Some(irq) = crate::drivers::gic::claim() else {
        return; // spurious
    };

    match irq {
        crate::drivers::timer::IRQ => {
            crate::drivers::timer::rearm();
            crate::drivers::timer::account_tick();
            crate::proc::sched::tick(cpu::core_id(), frame);
        }
        _ => {
            uart::print("unexpected IRQ ");
            uart::print_hex(irq as u64);
            uart::print("\n");
        }
    }

    crate::drivers::gic::complete(irq);
    crate::proc::signal::deliver_current(cpu::core_id(), frame);
}

#[unsafe(no_mangle)]
pub extern "C" fn handleFiqException(frame: &Frame) {
    dump_frame("FIQ", frame);
    halt_forever();
}

#[unsafe(no_mangle)]
pub extern "C" fn handleSErrorException(frame: &Frame) {
    dump_frame("SError", frame);
    halt_forever();
}

#[unsafe(no_mangle)]
pub extern "C" fn handleUnexpectedException(frame: &Frame) {
    dump_frame("unexpected (AArch32 lower-EL)", frame);
    halt_forever();
}
