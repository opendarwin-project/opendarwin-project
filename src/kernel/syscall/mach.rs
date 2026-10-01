//! Mach syscall (trap) handlers.

use crate::arch::aarch64::context::Frame;
use crate::arch::aarch64::cpu;
use crate::iokit::mach_server;
use crate::iokit::types::IO_RETURN_BAD_ARGUMENT;
use crate::iokit::user_client::{self, PortObjectTag};
use crate::ipc::kmsg::{IpcKmsg, MachMsgHeader};
use crate::ipc::right;
use crate::ipc::types::{
    IE_BITS_TYPE_RECEIVE, IE_BITS_TYPE_SEND, IE_BITS_TYPE_SEND_ONCE, MachPortNameT,
};
use crate::proc::sched;
use crate::syscall::numbers::*;
use crate::syscall::usercopy;

pub const KERN_SUCCESS: u32 = 0;
pub const KERN_INVALID_ADDRESS: u32 = 1;

pub const MACH_SEND_MSG: u32 = 0x1;
pub const MACH_RCV_MSG: u32 = 0x2;
pub const MACH_RCV_LARGE: u32 = 0x4;
pub const MACH_RCV_LARGE_IDENTITY: u32 = 0x8;
pub const MACH_SEND_TIMEOUT: u32 = 0x10;
pub const MACH_RCV_TIMEOUT: u32 = 0x100;
pub const MACH_SUPPORTED_OPTIONS: u32 = MACH_SEND_MSG
    | MACH_RCV_MSG
    | MACH_SEND_TIMEOUT
    | MACH_RCV_TIMEOUT
    | MACH_RCV_LARGE
    | MACH_RCV_LARGE_IDENTITY;

pub const MACH_MSG_SUCCESS: u32 = 0;
pub const MACH_SEND_INVALID_DEST: u32 = 0x10000003;
pub const MACH_SEND_TIMED_OUT: u32 = 0x10000004;
pub const MACH_SEND_MSG_TOO_SMALL: u32 = 0x10000008;
pub const MACH_SEND_NO_BUFFER: u32 = 0x1000000d;
pub const MACH_SEND_INVALID_HEADER: u32 = 0x10000010;
pub const MACH_SEND_INVALID_OPTIONS: u32 = 0x10000013;
pub const MACH_RCV_INVALID_NAME: u32 = 0x10004002;
pub const MACH_RCV_TIMED_OUT: u32 = 0x10004003;
pub const MACH_RCV_TOO_LARGE: u32 = 0x10004004;
pub const MACH_RCV_INVALID_DATA: u32 = 0x10004008;
pub const MACH_RCV_INVALID_ARGUMENTS: u32 = 0x10004013;
pub const MACH_MSGH_BITS_COMPLEX: u32 = 0x80000000;

pub fn handle(frame: &mut Frame) {
    let raw = frame.arg_u32(16) as i32;
    let num = if raw < 0 { (-raw) as u16 } else { raw as u16 };
    match num {
        MACH_THREAD_SELF_TRAP => mach_thread_self(frame),
        MACH_TASK_SELF_TRAP => mach_task_self(frame),
        MACH_HOST_SELF_TRAP => mach_host_self(frame),
        MACH_MACH_REPLY_PORT => mach_reply_port(frame),
        MACH__KERNELRPC_MACH_VM_ALLOCATE_TRAP => mach_vm_allocate_trap(frame),
        MACH__KERNELRPC_MACH_VM_MAP_TRAP => mach_vm_map_trap(frame),
        MACH_MACH_MSG_TRAP => mach_msg_trap(frame),
        MACH_MACH_MSG_OVERWRITE_TRAP => mach_msg_overwrite_trap(frame),
        MACH_IOKIT_USER_CLIENT_TRAP => mach_iokit_user_client_trap(frame),
        _ => {
            crate::drivers::uart::print("mach: unimplemented Mach trap ");
            crate::drivers::uart::print_dec(num as u64);
            crate::drivers::uart::print("\n");
            frame.set_return_u64(0);
        }
    }
}

fn mach_thread_self(frame: &mut Frame) {
    frame.set_return_u64(sched::current_task(cpu::core_id()).thread_self_name as u64);
}

fn mach_task_self(frame: &mut Frame) {
    frame.set_return_u64(sched::current_task(cpu::core_id()).task_self_name as u64);
}

fn mach_host_self(frame: &mut Frame) {
    let task = sched::current_task(cpu::core_id());
    frame.set_return_u64(mach_server::ensure_master_send_right(task) as u64);
}

fn mach_reply_port(frame: &mut Frame) {
    frame.set_return_u64(sched::current_task(cpu::core_id()).reply_port_name as u64);
}

fn mach_iokit_user_client_trap(frame: &mut Frame) {
    let connect_name = frame.arg_u32(0) as MachPortNameT;
    let index = frame.arg_u32(1);
    let p1 = frame.arg_u64(2);
    let p2 = frame.arg_u64(3);
    let p3 = frame.arg_u64(4);
    let p4 = frame.arg_u64(5);
    let p5 = frame.arg_u64(6);
    let p6 = frame.arg_u64(7);

    let task = sched::current_task(cpu::core_id());
    let Some(looked) = right::lookup(&mut task.ipc_space, connect_name) else {
        frame.set_return_i64(IO_RETURN_BAD_ARGUMENT as i64);
        return;
    };
    let Some(port) = looked.port else {
        frame.set_return_i64(IO_RETURN_BAD_ARGUMENT as i64);
        return;
    };
    let Some(po) = user_client::as_port_object(unsafe { (*port).ip_kobject }) else {
        frame.set_return_i64(IO_RETURN_BAD_ARGUMENT as i64);
        return;
    };
    if po.tag != PortObjectTag::Connect {
        frame.set_return_i64(IO_RETURN_BAD_ARGUMENT as i64);
        return;
    }
    let Some(uc) = po.connect else {
        frame.set_return_i64(IO_RETURN_BAD_ARGUMENT as i64);
        return;
    };
    frame.set_return_i64(user_client::trap(uc, index, p1, p2, p3, p4, p5, p6) as i64);
}

fn target_is_current_task(target: MachPortNameT) -> bool {
    target == sched::current_task(cpu::core_id()).task_self_name
}

fn mach_vm_allocate_trap(frame: &mut Frame) {
    let target = frame.arg_u32(0) as MachPortNameT;
    if !target_is_current_task(target) {
        frame.set_return_u32(MACH_SEND_INVALID_DEST);
        return;
    }
    let addr_ptr = frame.arg(1);
    let Some(addr) = usercopy::copy_in::<u64>(addr_ptr) else {
        frame.set_return_u32(KERN_INVALID_ADDRESS);
        return;
    };
    let result =
        sched::current_vmm(cpu::core_id()).mach_allocate(addr, frame.arg_u64(2), frame.arg_u32(3));
    if result.kr == KERN_SUCCESS && !usercopy::copy_out(addr_ptr, &result.addr) {
        frame.set_return_u32(KERN_INVALID_ADDRESS);
        return;
    }
    frame.set_return_u32(result.kr);
}

fn mach_vm_map_trap(frame: &mut Frame) {
    let target = frame.arg_u32(0) as MachPortNameT;
    if !target_is_current_task(target) {
        frame.set_return_u32(MACH_SEND_INVALID_DEST);
        return;
    }
    let addr_ptr = frame.arg(1);
    let Some(addr) = usercopy::copy_in::<u64>(addr_ptr) else {
        frame.set_return_u32(KERN_INVALID_ADDRESS);
        return;
    };
    let result = sched::current_vmm(cpu::core_id()).mach_map(
        addr,
        frame.arg_u64(2),
        frame.arg_u64(3),
        frame.arg_u32(4),
        frame.arg_u32(5),
    );
    if result.kr == KERN_SUCCESS && !usercopy::copy_out(addr_ptr, &result.addr) {
        frame.set_return_u32(KERN_INVALID_ADDRESS);
        return;
    }
    frame.set_return_u32(result.kr);
}

fn mach_msg_trap(frame: &mut Frame) {
    frame.set_return_u32(mach_msg_overwrite(
        frame.arg(0),
        frame.arg_u32(1),
        frame.arg_u32(2),
        frame.arg_u32(3),
        frame.arg_u32(4) as MachPortNameT,
        frame.arg_u32(5),
        frame.arg_u32(6),
        0,
    ));
}

fn mach_msg_overwrite_trap(frame: &mut Frame) {
    frame.set_return_u32(mach_msg_overwrite(
        frame.arg(0),
        frame.arg_u32(1),
        frame.arg_u32(2),
        frame.arg_u32(3),
        frame.arg_u32(4) as MachPortNameT,
        frame.arg_u32(5),
        frame.arg_u32(6),
        frame.arg(7),
    ));
}

fn mach_msg_overwrite(
    msg: usize,
    option: u32,
    send_size: u32,
    rcv_size: u32,
    rcv_name: MachPortNameT,
    _timeout: u32,
    _priority: u32,
    rcv_msg: usize,
) -> u32 {
    if (option & !MACH_SUPPORTED_OPTIONS) != 0 {
        return if (option & MACH_SEND_MSG) != 0 {
            MACH_SEND_INVALID_OPTIONS
        } else {
            MACH_RCV_INVALID_ARGUMENTS
        };
    }

    if (option & MACH_SEND_MSG) != 0 {
        let send_result = mach_msg_send(msg, send_size);
        if send_result != MACH_MSG_SUCCESS {
            return send_result;
        }
    }

    if (option & MACH_RCV_MSG) == 0 {
        return MACH_MSG_SUCCESS;
    }

    let dest_addr = if rcv_msg != 0 { rcv_msg } else { msg };
    mach_msg_receive(dest_addr, rcv_size, rcv_name, option)
}

fn mach_msg_send(msg: usize, send_size: u32) -> u32 {
    let hdr_size = core::mem::size_of::<MachMsgHeader>() as u32;
    if send_size < hdr_size {
        return MACH_SEND_MSG_TOO_SMALL;
    }
    let Some(header) = usercopy::copy_in::<MachMsgHeader>(msg) else {
        return MACH_SEND_INVALID_HEADER;
    };
    if header.msgh_size < hdr_size || header.msgh_size > send_size {
        return MACH_SEND_MSG_TOO_SMALL;
    }
    if (header.msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0 {
        return MACH_SEND_INVALID_OPTIONS;
    }

    let task = sched::current_task(cpu::core_id());
    let Some(dest) = right::lookup(&mut task.ipc_space, header.msgh_remote_port) else {
        return MACH_SEND_INVALID_DEST;
    };
    let Some(dest_port) = dest.port else {
        return MACH_SEND_INVALID_DEST;
    };
    let right_type = dest.entry.type_of();
    if right_type != IE_BITS_TYPE_SEND
        && right_type != IE_BITS_TYPE_SEND_ONCE
        && right_type != IE_BITS_TYPE_RECEIVE
    {
        return MACH_SEND_INVALID_DEST;
    }

    if mach_server::handle_send(dest_port, msg, send_size, header) {
        if right_type == IE_BITS_TYPE_SEND_ONCE {
            _ = right::dealloc(&mut task.ipc_space, dest.name);
        }
        return MACH_MSG_SUCCESS;
    }

    let Some(kmsg) = IpcKmsg::alloc(header) else {
        return MACH_SEND_NO_BUFFER;
    };
    let body_addr = msg + hdr_size as usize;
    let dst_body = IpcKmsg::body(kmsg);
    if !usercopy::copy_bytes_in(dst_body, body_addr) {
        IpcKmsg::free(kmsg);
        return MACH_SEND_INVALID_HEADER;
    }

    unsafe {
        if !(*dest_port).ip_messages.enqueue(kmsg) {
            IpcKmsg::free(kmsg);
            return MACH_SEND_TIMED_OUT;
        }
    }

    if right_type == IE_BITS_TYPE_SEND_ONCE {
        _ = right::dealloc(&mut task.ipc_space, dest.name);
    }
    MACH_MSG_SUCCESS
}

fn mach_msg_receive(dest_addr: usize, rcv_size: u32, rcv_name: MachPortNameT, option: u32) -> u32 {
    let hdr_size = core::mem::size_of::<MachMsgHeader>() as u32;
    if rcv_size < hdr_size {
        return MACH_RCV_TOO_LARGE;
    }
    let task = sched::current_task(cpu::core_id());
    let Some(rcv) = right::lookup(&mut task.ipc_space, rcv_name) else {
        return MACH_RCV_INVALID_NAME;
    };
    let Some(rcv_port) = rcv.port else {
        return MACH_RCV_INVALID_NAME;
    };
    if rcv.entry.type_of() != IE_BITS_TYPE_RECEIVE {
        return MACH_RCV_INVALID_NAME;
    }

    let Some(kmsg) = (unsafe { (*rcv_port).ip_messages.dequeue() }) else {
        return MACH_RCV_TIMED_OUT;
    };

    unsafe {
        if (*kmsg).ikm_header.msgh_size > rcv_size {
            if !(*rcv_port).ip_messages.enqueue(kmsg) {
                IpcKmsg::free(kmsg);
            }
            if (option & (MACH_RCV_LARGE | MACH_RCV_LARGE_IDENTITY)) != 0 {
                let large_header = (*kmsg).ikm_header;
                if !usercopy::copy_out(dest_addr, &large_header) {
                    return MACH_RCV_INVALID_DATA;
                }
            }
            return MACH_RCV_TOO_LARGE;
        }

        if !usercopy::copy_out(dest_addr, &(*kmsg).ikm_header) {
            IpcKmsg::free(kmsg);
            return MACH_RCV_INVALID_DATA;
        }
        let body = IpcKmsg::body(kmsg);
        if !usercopy::copy_bytes_out(dest_addr + hdr_size as usize, body) {
            IpcKmsg::free(kmsg);
            return MACH_RCV_INVALID_DATA;
        }
        IpcKmsg::free(kmsg);
    }
    MACH_MSG_SUCCESS
}
