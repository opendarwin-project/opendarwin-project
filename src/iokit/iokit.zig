//! Darwin IOKit.framework userspace — IOMasterPort / matching / open / map via
//! mach_msg, and IOConnectTrap / method dispatch via XNU trap 100
//! (`iokit_user_client_trap`).
//!
//! Built as its own dylib (not libSystem) with Apple's install name so
//! LC_LOAD_DYLIB consumers (fb-smoke, SkyLight, Prism) match real macOS.

const std = @import("std");

const MACH_host_self_trap: usize = 29;
const MACH_mach_reply_port: usize = 26; // XNU: 26 (not 37)
const MACH_mach_msg_trap: usize = 31;
const MACH_iokit_user_client_trap: usize = 100;

const MACH_MSG_SUCCESS: u32 = 0;
const MACH_SEND_MSG: u32 = 0x1;
const MACH_RCV_MSG: u32 = 0x2;

const KERN_SUCCESS: i32 = 0;

/// Simplified MIG-like msg IDs for match / open / mapMemory (not method calls).
const MSG_GET_MATCHING_SERVICE: u32 = 2900;
const MSG_SERVICE_OPEN: u32 = 2901;
const MSG_CONNECT_MAP_MEMORY: u32 = 2902;
const MSG_OBJECT_RELEASE: u32 = 2904;

const kIOFBSelectGetInfo: u32 = 0;
const kIOFBSelectPresent: u32 = 1;

const kIOHIDSelectGetPointState: u32 = 0;
const kIOHIDSelectPollEvents: u32 = 1;

pub const mach_port_t = u32;
pub const io_object_t = mach_port_t;
pub const io_service_t = io_object_t;
pub const io_connect_t = io_object_t;
pub const kern_return_t = i32;
pub const IOReturn = kern_return_t;

pub const kIOReturnSuccess: IOReturn = 0;
pub const kIOReturnError: IOReturn = -1;

const CLASS_NAME_MAX: usize = 64;

const MachMsgHeader = extern struct {
    msgh_bits: u32,
    msgh_size: u32,
    msgh_remote_port: mach_port_t,
    msgh_local_port: mach_port_t,
    msgh_voucher_port: mach_port_t,
    msgh_id: u32,
};

const MatchingBody = extern struct {
    class_len: u32 = 0,
    class_name: [CLASS_NAME_MAX]u8 = [_]u8{0} ** CLASS_NAME_MAX,
};

const OpenBody = extern struct {
    type: u32 = 0,
};

const MapMemoryBody = extern struct {
    memory_type: u32 = 0,
    flags: u32 = 0,
};

const ReplyBody = extern struct {
    ret: i32 = -1,
    pad: u32 = 0,
    val0: u64 = 0,
    val1: u64 = 0,
    val2: u64 = 0,
    val3: u64 = 0,
    bytes: [64]u8 = [_]u8{0} ** 64,
};

pub const IOFramebufferInfo = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    format: u32 = 0,
    size: u64 = 0,
};

const MatchingDict = struct {
    class_name: [CLASS_NAME_MAX]u8 = [_]u8{0} ** CLASS_NAME_MAX,
    class_len: u32 = 0,
};

fn machTrap0(number: usize) usize {
    return asm volatile (
        \\mov x16, %[number]
        \\svc #0x81
        : [ret] "={x0}" (-> usize),
        : [number] "r" (number),
        : .{ .x1 = true, .x2 = true, .x3 = true, .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .memory = true });
}

fn machTrap7(number: usize, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize) usize {
    return asm volatile (
        \\mov x16, %[number]
        \\svc #0x81
        : [ret] "={x0}" (-> usize),
        : [number] "r" (number),
          [arg0] "{x0}" (a0),
          [arg1] "{x1}" (a1),
          [arg2] "{x2}" (a2),
          [arg3] "{x3}" (a3),
          [arg4] "{x4}" (a4),
          [arg5] "{x5}" (a5),
          [arg6] "{x6}" (a6),
        : .{ .x1 = true, .x2 = true, .x3 = true, .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .memory = true });
}

fn machTrap8(number: usize, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize, a7: usize) usize {
    return asm volatile (
        \\mov x16, %[number]
        \\svc #0x81
        : [ret] "={x0}" (-> usize),
        : [number] "r" (number),
          [arg0] "{x0}" (a0),
          [arg1] "{x1}" (a1),
          [arg2] "{x2}" (a2),
          [arg3] "{x3}" (a3),
          [arg4] "{x4}" (a4),
          [arg5] "{x5}" (a5),
          [arg6] "{x6}" (a6),
          [arg7] "{x7}" (a7),
        : .{ .x1 = true, .x2 = true, .x3 = true, .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .memory = true });
}

fn mach_msg(msg: [*]u8, option: u32, send_size: u32, rcv_size: u32, rcv_name: mach_port_t, timeout: u32, notify: mach_port_t) kern_return_t {
    return @intCast(machTrap7(
        MACH_mach_msg_trap,
        @intFromPtr(msg),
        option,
        send_size,
        rcv_size,
        rcv_name,
        timeout,
        notify,
    ));
}

fn mach_host_self() mach_port_t {
    return @truncate(machTrap0(MACH_host_self_trap));
}

fn mach_reply_port() mach_port_t {
    return @truncate(machTrap0(MACH_mach_reply_port));
}

/// Darwin IOConnectTrap6 → iokit_user_client_trap (mach trap 100).
pub export fn IOConnectTrap6(
    connect: io_connect_t,
    index: u32,
    p1: usize,
    p2: usize,
    p3: usize,
    p4: usize,
    p5: usize,
    p6: usize,
) kern_return_t {
    return @intCast(@as(i64, @bitCast(machTrap8(
        MACH_iokit_user_client_trap,
        connect,
        index,
        p1,
        p2,
        p3,
        p4,
        p5,
        p6,
    ))));
}

pub export fn IOConnectTrap0(connect: io_connect_t, index: u32) kern_return_t {
    return IOConnectTrap6(connect, index, 0, 0, 0, 0, 0, 0);
}

pub export fn IOConnectTrap1(connect: io_connect_t, index: u32, p1: usize) kern_return_t {
    return IOConnectTrap6(connect, index, p1, 0, 0, 0, 0, 0);
}

fn rpc(remote: mach_port_t, msg_id: u32, req_body: []const u8, reply_out: *ReplyBody) kern_return_t {
    const reply = mach_reply_port();
    if (reply == 0) return kIOReturnError;

    var buf: [512]u8 align(8) = undefined;
    const hdr_size = @sizeOf(MachMsgHeader);
    const send_size: u32 = @intCast(hdr_size + req_body.len);
    const rcv_size: u32 = @intCast(hdr_size + @sizeOf(ReplyBody));

    var hdr: MachMsgHeader = .{
        .msgh_bits = 0,
        .msgh_size = send_size,
        .msgh_remote_port = remote,
        .msgh_local_port = reply,
        .msgh_voucher_port = 0,
        .msgh_id = msg_id,
    };
    @memcpy(buf[0..hdr_size], std.mem.asBytes(&hdr));
    if (req_body.len != 0) @memcpy(buf[hdr_size..][0..req_body.len], req_body);

    const kr = mach_msg(&buf, MACH_SEND_MSG | MACH_RCV_MSG, send_size, rcv_size, reply, 0, 0);
    if (kr != MACH_MSG_SUCCESS) return kr;

    const reply_hdr: *const MachMsgHeader = @ptrCast(@alignCast(&buf));
    if (reply_hdr.msgh_size < hdr_size + (@sizeOf(ReplyBody) - 64)) return kIOReturnError;
    const body_len = reply_hdr.msgh_size - hdr_size;
    const src = buf[hdr_size..][0..body_len];
    @memset(std.mem.asBytes(reply_out), 0);
    @memcpy(std.mem.asBytes(reply_out)[0..@min(src.len, @sizeOf(ReplyBody))], src[0..@min(src.len, @sizeOf(ReplyBody))]);
    return reply_out.ret;
}

pub export fn IOMasterPort(bootstrapPort: mach_port_t, masterPort: *mach_port_t) kern_return_t {
    _ = bootstrapPort;
    const host = mach_host_self();
    if (host == 0) return kIOReturnError;
    masterPort.* = host;
    return KERN_SUCCESS;
}

pub export fn IOServiceMatching(name: [*:0]const u8) ?*anyopaque {
    const dict = @as(*MatchingDict, @ptrCast(@alignCast(malloc(@sizeOf(MatchingDict)) orelse return null)));
    dict.* = .{};
    var i: usize = 0;
    while (name[i] != 0 and i < CLASS_NAME_MAX) : (i += 1) {
        dict.class_name[i] = name[i];
    }
    dict.class_len = @intCast(i);
    return dict;
}

pub export fn IOServiceGetMatchingService(masterPort: mach_port_t, matching: ?*anyopaque) io_service_t {
    const dict: *const MatchingDict = @ptrCast(@alignCast(matching orelse return 0));
    var body: MatchingBody = .{ .class_len = dict.class_len };
    @memcpy(body.class_name[0..dict.class_len], dict.class_name[0..dict.class_len]);
    free(matching);

    var reply: ReplyBody = .{};
    const kr = rpc(masterPort, MSG_GET_MATCHING_SERVICE, std.mem.asBytes(&body), &reply);
    if (kr != KERN_SUCCESS) return 0;
    return @truncate(reply.val0);
}

pub export fn IOServiceOpen(service: io_service_t, owningTask: mach_port_t, type_: u32, connect: *io_connect_t) kern_return_t {
    _ = owningTask;
    var body: OpenBody = .{ .type = type_ };
    var reply: ReplyBody = .{};
    const kr = rpc(service, MSG_SERVICE_OPEN, std.mem.asBytes(&body), &reply);
    if (kr != KERN_SUCCESS) return kr;
    connect.* = @truncate(reply.val0);
    return KERN_SUCCESS;
}

pub export fn IOServiceClose(connect: io_connect_t) kern_return_t {
    var reply: ReplyBody = .{};
    return rpc(connect, MSG_OBJECT_RELEASE, &[_]u8{}, &reply);
}

pub export fn IOObjectRelease(object: io_object_t) kern_return_t {
    _ = object;
    return KERN_SUCCESS;
}

pub export fn IOConnectMapMemory(
    connect: io_connect_t,
    memoryType: u32,
    intoTask: mach_port_t,
    atAddress: *u64,
    ofSize: *u64,
    options: u32,
) kern_return_t {
    _ = intoTask;
    var body: MapMemoryBody = .{ .memory_type = memoryType, .flags = options };
    var reply: ReplyBody = .{};
    const kr = rpc(connect, MSG_CONNECT_MAP_MEMORY, std.mem.asBytes(&body), &reply);
    if (kr != KERN_SUCCESS) return kr;
    atAddress.* = reply.val0;
    ofSize.* = reply.val1;
    return KERN_SUCCESS;
}

/// Scalar / simple method path uses Darwin trap 100 (IOConnectTrap).
pub export fn IOConnectCallMethod(
    connect: io_connect_t,
    selector: u32,
    input: ?[*]const u64,
    inputCnt: u32,
    inputStruct: ?*const anyopaque,
    inputStructCnt: usize,
    output: ?[*]u64,
    outputCnt: ?*u32,
    outputStruct: ?*anyopaque,
    outputStructCnt: ?*usize,
) kern_return_t {
    _ = input;
    _ = inputCnt;
    _ = inputStruct;
    _ = inputStructCnt;
    _ = output;
    _ = outputCnt;
    switch (selector) {
        kIOFBSelectGetInfo => {
            const out = outputStruct orelse return kIOReturnError;
            const kr = IOConnectTrap1(connect, selector, @intFromPtr(out));
            if (kr == KERN_SUCCESS) {
                if (outputStructCnt) |osc| osc.* = @sizeOf(IOFramebufferInfo);
            }
            return kr;
        },
        kIOFBSelectPresent => return IOConnectTrap0(connect, selector),
        else => return kIOReturnError,
    }
}

pub export fn IOFramebufferOpenDefault(connect_out: *io_connect_t, info_out: ?*IOFramebufferInfo) kern_return_t {
    var master: mach_port_t = 0;
    if (IOMasterPort(0, &master) != KERN_SUCCESS) return kIOReturnError;
    const matching = IOServiceMatching("IOFramebuffer") orelse return kIOReturnError;
    const service = IOServiceGetMatchingService(master, matching);
    if (service == 0) return kIOReturnError;
    var connect: io_connect_t = 0;
    const okr = IOServiceOpen(service, 0, 0, &connect);
    _ = IOObjectRelease(service);
    if (okr != KERN_SUCCESS) return okr;
    connect_out.* = connect;
    if (info_out) |info| {
        const kr = IOConnectTrap1(connect, kIOFBSelectGetInfo, @intFromPtr(info));
        if (kr != KERN_SUCCESS) return kr;
    }
    return KERN_SUCCESS;
}

pub export fn IOFramebufferPresent(connect: io_connect_t) kern_return_t {
    return IOConnectTrap0(connect, kIOFBSelectPresent);
}

pub const IOHIDPointState = extern struct {
    x: u32 = 0,
    y: u32 = 0,
    max_x: u32 = 32767,
    max_y: u32 = 32767,
    rel_dx: i32 = 0,
    rel_dy: i32 = 0,
    buttons: u32 = 0,
    device_type: u32 = 0,
    abs_updated: u32 = 0,
};

pub export fn IOHIDSystemOpenDefault(connect_out: *io_connect_t) kern_return_t {
    var master: mach_port_t = 0;
    if (IOMasterPort(0, &master) != KERN_SUCCESS) return kIOReturnError;
    const matching = IOServiceMatching("IOHIDSystem") orelse return kIOReturnError;
    const service = IOServiceGetMatchingService(master, matching);
    if (service == 0) return kIOReturnError;
    var connect: io_connect_t = 0;
    const okr = IOServiceOpen(service, 0, 0, &connect);
    _ = IOObjectRelease(service);
    if (okr != KERN_SUCCESS) return okr;
    connect_out.* = connect;
    return KERN_SUCCESS;
}

pub export fn IOHIDGetPointState(connect: io_connect_t, state: *IOHIDPointState) kern_return_t {
    return IOConnectTrap1(connect, kIOHIDSelectGetPointState, @intFromPtr(state));
}

pub export fn IOHIDPollEvents(connect: io_connect_t) kern_return_t {
    return IOConnectTrap0(connect, kIOHIDSelectPollEvents);
}

extern fn malloc(size: usize) ?*anyopaque;
extern fn free(ptr: ?*anyopaque) void;
