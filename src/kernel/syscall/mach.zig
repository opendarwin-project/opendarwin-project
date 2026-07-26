const context = @import("../arch/aarch64/context.zig");
const numbers = @import("numbers.zig");
const cpu = @import("../arch/aarch64/cpu.zig");
const sched = @import("../proc/sched.zig");
const types = @import("../ipc/types.zig");
const ipc_right = @import("../ipc/right.zig");
const IpcKmsg = @import("../ipc/kmsg.zig").IpcKmsg;
const MachMsgHeader = @import("../ipc/kmsg.zig").MachMsgHeader;
const usercopy = @import("usercopy.zig");

const KERN_SUCCESS: u32 = 0;
const KERN_INVALID_ADDRESS: u32 = 1;

const MACH_SEND_MSG: u32 = 0x1;
const MACH_RCV_MSG: u32 = 0x2;
const MACH_RCV_LARGE: u32 = 0x4;
const MACH_RCV_LARGE_IDENTITY: u32 = 0x8;
const MACH_SEND_TIMEOUT: u32 = 0x10;
const MACH_RCV_TIMEOUT: u32 = 0x100;
const MACH_SUPPORTED_OPTIONS: u32 = MACH_SEND_MSG | MACH_RCV_MSG | MACH_SEND_TIMEOUT | MACH_RCV_TIMEOUT | MACH_RCV_LARGE | MACH_RCV_LARGE_IDENTITY;

const MACH_MSG_SUCCESS: u32 = 0;
const MACH_SEND_INVALID_DEST: u32 = 0x10000003;
const MACH_SEND_TIMED_OUT: u32 = 0x10000004;
const MACH_SEND_MSG_TOO_SMALL: u32 = 0x10000008;
const MACH_SEND_NO_BUFFER: u32 = 0x1000000d;
const MACH_SEND_INVALID_HEADER: u32 = 0x10000010;
const MACH_SEND_INVALID_OPTIONS: u32 = 0x10000013;
const MACH_RCV_INVALID_NAME: u32 = 0x10004002;
const MACH_RCV_TIMED_OUT: u32 = 0x10004003;
const MACH_RCV_TOO_LARGE: u32 = 0x10004004;
const MACH_RCV_INVALID_DATA: u32 = 0x10004008;
const MACH_RCV_INVALID_ARGUMENTS: u32 = 0x10004013;
const MACH_MSGH_BITS_COMPLEX: u32 = 0x80000000;

const handler_type = *const fn (frame: *context.Frame) void;

pub const table: [64]?handler_type = init: {
    var t: [64]?handler_type = [_]?handler_type{null} ** 64;
    t[numbers.MACH_thread_self_trap] = machThreadSelf;
    t[numbers.MACH_task_self_trap] = machTaskSelf;
    t[numbers.MACH_host_self_trap] = machHostSelf;
    t[numbers.MACH_mach_reply_port] = machReplyPort;
    t[numbers.MACH__kernelrpc_mach_vm_allocate_trap] = machVmAllocateTrap;
    t[numbers.MACH__kernelrpc_mach_vm_map_trap] = machVmMapTrap;
    t[numbers.MACH_mach_msg_trap] = machMsgTrap;
    t[numbers.MACH_mach_msg_overwrite_trap] = machMsgOverwriteTrap;
    break :init t;
};

pub fn handle(frame: *context.Frame) void {
    const num = frame.x[16];
    if (num >= 64) return;
    const handler = table[num] orelse return;
    handler(frame);
}

fn machThreadSelf(frame: *context.Frame) void {
    frame.x[0] = sched.currentTask(cpu.coreId()).thread_self_name;
}

fn machTaskSelf(frame: *context.Frame) void {
    frame.x[0] = sched.currentTask(cpu.coreId()).task_self_name;
}

fn machHostSelf(frame: *context.Frame) void {
    frame.x[0] = types.MACH_PORT_NULL;
}

fn machReplyPort(frame: *context.Frame) void {
    frame.x[0] = sched.currentTask(cpu.coreId()).reply_port_name;
}

fn targetIsCurrentTask(target: types.mach_port_name_t) bool {
    return target == sched.currentTask(cpu.coreId()).task_self_name;
}

fn machVmAllocateTrap(frame: *context.Frame) void {
    const target: types.mach_port_name_t = @truncate(frame.x[0]);
    if (!targetIsCurrentTask(target)) {
        frame.x[0] = MACH_SEND_INVALID_DEST;
        return;
    }
    const addr_ptr = frame.x[1];
    const addr = usercopy.copyIn(u64, addr_ptr) orelse {
        frame.x[0] = KERN_INVALID_ADDRESS;
        return;
    };
    const result = sched.currentVmm(cpu.coreId()).machAllocate(addr, frame.x[2], @truncate(frame.x[3]));
    if (result.kr == KERN_SUCCESS and !usercopy.copyOut(u64, addr_ptr, result.addr)) {
        frame.x[0] = KERN_INVALID_ADDRESS;
        return;
    }
    frame.x[0] = result.kr;
}

fn machVmMapTrap(frame: *context.Frame) void {
    const target: types.mach_port_name_t = @truncate(frame.x[0]);
    if (!targetIsCurrentTask(target)) {
        frame.x[0] = MACH_SEND_INVALID_DEST;
        return;
    }
    const addr_ptr = frame.x[1];
    const addr = usercopy.copyIn(u64, addr_ptr) orelse {
        frame.x[0] = KERN_INVALID_ADDRESS;
        return;
    };
    const result = sched.currentVmm(cpu.coreId()).machMap(addr, frame.x[2], frame.x[3], @truncate(frame.x[4]), @truncate(frame.x[5]));
    if (result.kr == KERN_SUCCESS and !usercopy.copyOut(u64, addr_ptr, result.addr)) {
        frame.x[0] = KERN_INVALID_ADDRESS;
        return;
    }
    frame.x[0] = result.kr;
}

fn machMsgTrap(frame: *context.Frame) void {
    frame.x[0] = machMsgOverwrite(frame.x[0], @truncate(frame.x[1]), @truncate(frame.x[2]), @truncate(frame.x[3]), @truncate(frame.x[4]), @truncate(frame.x[5]), @truncate(frame.x[6]), 0);
}

fn machMsgOverwriteTrap(frame: *context.Frame) void {
    frame.x[0] = machMsgOverwrite(frame.x[0], @truncate(frame.x[1]), @truncate(frame.x[2]), @truncate(frame.x[3]), @truncate(frame.x[4]), @truncate(frame.x[5]), @truncate(frame.x[6]), frame.x[7]);
}

fn machMsgOverwrite(msg: u64, option: u32, send_size: u32, rcv_size: u32, rcv_name: types.mach_port_name_t, timeout: u32, priority: u32, rcv_msg: u64) u32 {
    _ = timeout;
    _ = priority;
    if ((option & ~MACH_SUPPORTED_OPTIONS) != 0) {
        return if ((option & MACH_SEND_MSG) != 0) MACH_SEND_INVALID_OPTIONS else MACH_RCV_INVALID_ARGUMENTS;
    }

    if ((option & MACH_SEND_MSG) != 0) {
        const send_result = machMsgSend(msg, send_size);
        if (send_result != MACH_MSG_SUCCESS) return send_result;
    }

    if ((option & MACH_RCV_MSG) == 0) return MACH_MSG_SUCCESS;
    const dest_addr = if (rcv_msg != 0) rcv_msg else msg;
    return machMsgReceive(dest_addr, rcv_size, rcv_name, option);
}

fn machMsgSend(msg: u64, send_size: u32) u32 {
    if (send_size < @sizeOf(MachMsgHeader)) return MACH_SEND_MSG_TOO_SMALL;
    const header = usercopy.copyIn(MachMsgHeader, msg) orelse return MACH_SEND_INVALID_HEADER;
    if (header.msgh_size < @sizeOf(MachMsgHeader) or header.msgh_size > send_size) return MACH_SEND_MSG_TOO_SMALL;
    if ((header.msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0) return MACH_SEND_INVALID_OPTIONS;

    const task = sched.currentTask(cpu.coreId());
    const dest = ipc_right.lookup(&task.ipc_space, header.msgh_remote_port) orelse return MACH_SEND_INVALID_DEST;
    const dest_port = dest.port orelse return MACH_SEND_INVALID_DEST;
    const right_type = dest.entry.typeOf();
    if (right_type != types.IE_BITS_TYPE_SEND and right_type != types.IE_BITS_TYPE_SEND_ONCE and right_type != types.IE_BITS_TYPE_RECEIVE) return MACH_SEND_INVALID_DEST;

    const kmsg = IpcKmsg.alloc(header) orelse return MACH_SEND_NO_BUFFER;
    const body_addr = msg + @sizeOf(MachMsgHeader);
    if (!usercopy.copyBytesIn(kmsg.body(), body_addr)) {
        IpcKmsg.free(kmsg);
        return MACH_SEND_INVALID_HEADER;
    }
    if (!dest_port.ip_messages.enqueue(kmsg)) {
        IpcKmsg.free(kmsg);
        return MACH_SEND_TIMED_OUT;
    }
    if (right_type == types.IE_BITS_TYPE_SEND_ONCE) _ = ipc_right.dealloc(&task.ipc_space, dest.name);
    return MACH_MSG_SUCCESS;
}

fn machMsgReceive(dest_addr: u64, rcv_size: u32, rcv_name: types.mach_port_name_t, option: u32) u32 {
    if (rcv_size < @sizeOf(MachMsgHeader)) return MACH_RCV_TOO_LARGE;
    const task = sched.currentTask(cpu.coreId());
    const rcv = ipc_right.lookup(&task.ipc_space, rcv_name) orelse return MACH_RCV_INVALID_NAME;
    const rcv_port = rcv.port orelse return MACH_RCV_INVALID_NAME;
    if (rcv.entry.typeOf() != types.IE_BITS_TYPE_RECEIVE) return MACH_RCV_INVALID_NAME;

    const kmsg = rcv_port.ip_messages.dequeue() orelse return MACH_RCV_TIMED_OUT;
    if (kmsg.ikm_header.msgh_size > rcv_size) {
        if (!rcv_port.ip_messages.enqueue(kmsg)) IpcKmsg.free(kmsg);
        if ((option & (MACH_RCV_LARGE | MACH_RCV_LARGE_IDENTITY)) != 0) {
            var large_header = kmsg.ikm_header;
            large_header.msgh_size = kmsg.ikm_header.msgh_size;
            if (!usercopy.copyOut(MachMsgHeader, dest_addr, large_header)) return MACH_RCV_INVALID_DATA;
        }
        return MACH_RCV_TOO_LARGE;
    }

    if (!usercopy.copyOut(MachMsgHeader, dest_addr, kmsg.ikm_header)) {
        IpcKmsg.free(kmsg);
        return MACH_RCV_INVALID_DATA;
    }
    if (!usercopy.copyBytesOut(dest_addr + @sizeOf(MachMsgHeader), kmsg.body())) {
        IpcKmsg.free(kmsg);
        return MACH_RCV_INVALID_DATA;
    }
    IpcKmsg.free(kmsg);
    return MACH_MSG_SUCCESS;
}
