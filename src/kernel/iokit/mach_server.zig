//! IOKit Mach message server — Darwin-shaped io_* RPCs over simple mach_msg.
//!
//! Userspace talks IOKitLib (IOMasterPort / IOServiceOpen / IOConnectMapMemory /
//! IOConnectCallMethod). Those build MIG-like requests; the kernel demuxes them
//! when the destination port carries an IOKit kobject instead of enqueueing.

const std = @import("std");
const types = @import("types.zig");
const registry = @import("registry.zig");
const user_client = @import("user_client.zig");
const service = @import("service.zig");
const framebuffer = @import("framebuffer.zig");
const MachMsgHeader = @import("../ipc/kmsg.zig").MachMsgHeader;
const IpcKmsg = @import("../ipc/kmsg.zig").IpcKmsg;
const IpcPort = @import("../ipc/port.zig").IpcPort;
const ipc_types = @import("../ipc/types.zig");
const ipc_right = @import("../ipc/right.zig");
const ipc_host = @import("../ipc/host.zig");
const sched = @import("../proc/sched.zig");
const cpu = @import("../arch/aarch64/cpu.zig");
const usercopy = @import("../syscall/usercopy.zig");
const task_mod = @import("../proc/task.zig");

/// Message IDs for OpenDarwin IOKit RPCs (io_* MIG equivalents).
pub const MSG_GET_MATCHING_SERVICE: u32 = 2900;
pub const MSG_SERVICE_OPEN: u32 = 2901;
pub const MSG_CONNECT_MAP_MEMORY: u32 = 2902;
pub const MSG_OBJECT_RELEASE: u32 = 2904;

pub const KERN_SUCCESS: i32 = 0;
pub const KERN_FAILURE: i32 = 5;
pub const KERN_INVALID_ARGUMENT: i32 = 4;
pub const KERN_NO_SPACE: i32 = 3;

const CLASS_NAME_MAX: usize = 64;

pub const MatchingBody = extern struct {
    class_len: u32 = 0,
    class_name: [CLASS_NAME_MAX]u8 = [_]u8{0} ** CLASS_NAME_MAX,
};

pub const OpenBody = extern struct {
    type: u32 = 0,
};

pub const MapMemoryBody = extern struct {
    memory_type: u32 = 0,
    flags: u32 = 0,
};

pub const ReplyBody = extern struct {
    ret: i32 = KERN_FAILURE,
    pad: u32 = 0,
    val0: u64 = 0,
    val1: u64 = 0,
    val2: u64 = 0,
    val3: u64 = 0,
    /// Optional struct payload (FbInfo etc.), sized by caller expectation.
    bytes: [64]u8 = [_]u8{0} ** 64,
};

fn classEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn matchesClass(svc: *service.IOService, want: []const u8) bool {
    if (classEql(svc.getClassName(), want)) return true;
    // Darwin inheritance: matching "IOFramebuffer" finds concrete subclasses.
    if (classEql(want, framebuffer.CLASS_NAME) and classEql(svc.getClassName(), "VirtioGpuFramebuffer")) {
        return true;
    }
    return false;
}

pub fn findMatchingService(class_name: []const u8) ?*service.IOService {
    var i: usize = 0;
    while (i < registry.publishedCount()) : (i += 1) {
        const svc = registry.publishedAt(i) orelse continue;
        if (matchesClass(svc, class_name)) return svc;
    }
    // Also walk children of published nubs (framebuffer attaches under PCI).
    i = 0;
    while (i < registry.publishedCount()) : (i += 1) {
        const parent = registry.publishedAt(i) orelse continue;
        var ci: usize = 0;
        while (ci < parent.entry.childCount()) : (ci += 1) {
            const child_entry = parent.entry.childAt(ci) orelse continue;
            const child = service.IOService.fromEntry(child_entry);
            if (matchesClass(child, class_name)) return child;
        }
    }
    return null;
}

/// Ensure the current task has a send right to the IOKit master (host) port.
pub fn ensureMasterSendRight(task: *task_mod.Task) ipc_types.mach_port_name_t {
    if (task.iokit_master_name != ipc_types.MACH_PORT_NULL) return task.iokit_master_name;

    const host = ipc_host.getHostPort();
    host.ip_kobject = user_client.masterPortObject();
    const result = ipc_right.alloc(&task.ipc_space, host, ipc_types.IE_BITS_TYPE_SEND);
    task.iokit_master_name = result.name;
    return result.name;
}

fn insertServiceSendRight(task: *task_mod.Task, svc: *service.IOService) ?ipc_types.mach_port_name_t {
    const port = IpcPort.alloc();
    port.ip_receiver = ipc_host.getHostPort().ip_receiver;
    _ = user_client.bindServicePort(svc, port);
    const result = ipc_right.alloc(&task.ipc_space, port, ipc_types.IE_BITS_TYPE_SEND);
    return result.name;
}

fn insertConnectSendRight(task: *task_mod.Task, uc: *user_client.IOUserClient) ?ipc_types.mach_port_name_t {
    const port = IpcPort.alloc();
    port.ip_receiver = ipc_host.getHostPort().ip_receiver;
    user_client.bindConnectPort(uc, port);
    const result = ipc_right.alloc(&task.ipc_space, port, ipc_types.IE_BITS_TYPE_SEND);
    return result.name;
}

fn enqueueReply(reply_port: *IpcPort, req_id: u32, body: ReplyBody, body_len: u32) bool {
    const header = MachMsgHeader{
        .msgh_bits = 0,
        .msgh_size = @sizeOf(MachMsgHeader) + body_len,
        .msgh_remote_port = ipc_types.MACH_PORT_NULL,
        .msgh_local_port = ipc_types.MACH_PORT_NULL,
        .msgh_voucher_port = ipc_types.MACH_PORT_NULL,
        .msgh_id = req_id + 100,
    };
    const kmsg = IpcKmsg.alloc(header) orelse return false;
    const dst = kmsg.body();
    const src = std.mem.asBytes(&body);
    const n = @min(dst.len, @min(src.len, body_len));
    @memcpy(dst[0..n], src[0..n]);
    if (!reply_port.ip_messages.enqueue(kmsg)) {
        IpcKmsg.free(kmsg);
        return false;
    }
    return true;
}

fn copyBody(comptime T: type, msg_addr: u64, send_size: u32) ?T {
    if (send_size < @sizeOf(MachMsgHeader) + @sizeOf(T)) return null;
    return usercopy.copyIn(T, msg_addr + @sizeOf(MachMsgHeader));
}

/// Handle an IOKit request destined for a kobject port. Returns true if handled
/// (reply enqueued); false means fall through to normal enqueue.
pub fn handleSend(dest_port: *IpcPort, msg_addr: u64, send_size: u32, header: MachMsgHeader) bool {
    const po = user_client.asPortObject(dest_port.ip_kobject) orelse return false;
    if (po.tag == .none) return false;

    const task = sched.currentTask(cpu.coreId());
    const reply_lookup = ipc_right.lookup(&task.ipc_space, header.msgh_local_port) orelse return false;
    const reply_port = reply_lookup.port orelse return false;
    if (reply_lookup.entry.typeOf() != ipc_types.IE_BITS_TYPE_RECEIVE) return false;

    var reply: ReplyBody = .{};
    const reply_len: u32 = @sizeOf(ReplyBody) - 64; // scalars only

    switch (header.msgh_id) {
        MSG_GET_MATCHING_SERVICE => {
            if (po.tag != .master) {
                reply.ret = KERN_INVALID_ARGUMENT;
            } else if (copyBody(MatchingBody, msg_addr, send_size)) |body| {
                const len = @min(body.class_len, CLASS_NAME_MAX);
                const name = body.class_name[0..len];
                if (findMatchingService(name)) |svc| {
                    if (insertServiceSendRight(task, svc)) |pname| {
                        reply.ret = KERN_SUCCESS;
                        reply.val0 = pname;
                    } else {
                        reply.ret = KERN_NO_SPACE;
                    }
                } else {
                    reply.ret = KERN_FAILURE;
                }
            } else {
                reply.ret = KERN_INVALID_ARGUMENT;
            }
        },
        MSG_SERVICE_OPEN => {
            if (po.tag != .service) {
                reply.ret = KERN_INVALID_ARGUMENT;
            } else {
                const svc = po.service orelse {
                    reply.ret = KERN_FAILURE;
                    _ = enqueueReply(reply_port, header.msgh_id, reply, reply_len);
                    return true;
                };
                if (user_client.open(svc)) |uc| {
                    if (insertConnectSendRight(task, uc)) |pname| {
                        reply.ret = KERN_SUCCESS;
                        reply.val0 = pname;
                    } else {
                        reply.ret = KERN_NO_SPACE;
                    }
                } else {
                    reply.ret = KERN_NO_SPACE;
                }
            }
        },
        MSG_CONNECT_MAP_MEMORY => {
            if (po.tag != .connect) {
                reply.ret = KERN_INVALID_ARGUMENT;
            } else {
                const uc = po.connect orelse {
                    reply.ret = KERN_FAILURE;
                    _ = enqueueReply(reply_port, header.msgh_id, reply, reply_len);
                    return true;
                };
                const body = copyBody(MapMemoryBody, msg_addr, send_size) orelse {
                    reply.ret = KERN_INVALID_ARGUMENT;
                    _ = enqueueReply(reply_port, header.msgh_id, reply, reply_len);
                    return true;
                };
                _ = body;
                if (user_client.framebufferMapAperture(uc)) |phys| {
                    const vmm = sched.currentVmm(cpu.coreId());
                    const va = vmm.mapPhysical(phys.pa, phys.len);
                    if (va == 0) {
                        reply.ret = KERN_NO_SPACE;
                    } else {
                        reply.ret = KERN_SUCCESS;
                        reply.val0 = va;
                        reply.val1 = phys.len;
                    }
                } else {
                    reply.ret = KERN_FAILURE;
                }
            }
        },
        // Method dispatch uses XNU trap 100 (iokit_user_client_trap), not mach_msg.
        MSG_OBJECT_RELEASE => {
            reply.ret = KERN_SUCCESS;
        },
        else => return false,
    }

    return enqueueReply(reply_port, header.msgh_id, reply, reply_len);
}
