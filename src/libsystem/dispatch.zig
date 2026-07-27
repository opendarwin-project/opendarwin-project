//! libdispatch (GCD) stubs: dispatch_queue, dispatch_async, dispatch_sync,
//! dispatch_source, dispatch_once, etc.

const common = @import("common.zig");
const C = common;

const DispatchFunction = *const fn (?*anyopaque) callconv(.c) void;
const DispatchObject = *DispatchObjectStorage;
const DispatchQueue = *DispatchObjectStorage;
const DispatchSource = *DispatchSourceStorage;
const DispatchSourceType = *const DispatchSourceTypeStorage;

const DispatchObjectStorage = extern struct {
    context: ?*anyopaque = null,
};

const DispatchSourceTypeStorage = extern struct {
    tag: usize = 0,
};

const DispatchSourceStorage = extern struct {
    object: DispatchObjectStorage = .{},
    kind: usize = 0,
    queue: ?DispatchQueue = null,
    event_handler: ?DispatchFunction = null,
    cancel_handler: ?DispatchFunction = null,
};

pub export var _dispatch_main_q: DispatchObjectStorage = .{};
pub export var _dispatch_queue_attr_concurrent: DispatchObjectStorage = .{};
pub export const _dispatch_source_type_timer: DispatchSourceTypeStorage = .{ .tag = 1 };
pub export const _dispatch_source_type_read: DispatchSourceTypeStorage = .{ .tag = 2 };
pub export const _dispatch_source_type_write: DispatchSourceTypeStorage = .{ .tag = 3 };
pub export const _dispatch_source_type_proc: DispatchSourceTypeStorage = .{ .tag = 4 };
pub export const _dispatch_source_type_signal: DispatchSourceTypeStorage = .{ .tag = 5 };
pub export const _dispatch_source_type_vnode: DispatchSourceTypeStorage = .{ .tag = 6 };
pub export const _dispatch_source_type_interval: DispatchSourceTypeStorage = .{ .tag = 7 };
pub export const _dispatch_source_type_mach_send: DispatchSourceTypeStorage = .{ .tag = 8 };
pub export const _dispatch_source_type_mach_receive: DispatchSourceTypeStorage = .{ .tag = 9 };

var global_dispatch_queue: DispatchObjectStorage = .{};
var dispatch_queues: [8]DispatchObjectStorage = [_]DispatchObjectStorage{.{}} ** 8;
var dispatch_sources: [16]DispatchSourceStorage = [_]DispatchSourceStorage{.{}} ** 16;
var next_dispatch_queue: usize = 0;
var next_dispatch_source: usize = 0;

pub export fn dispatch_retain(_: DispatchObject) void {}
pub export fn dispatch_release(_: DispatchObject) void {}

pub export fn dispatch_get_context(object: DispatchObject) ?*anyopaque {
    return object.context;
}

pub export fn dispatch_set_context(object: DispatchObject, context: ?*anyopaque) void {
    object.context = context;
}

pub export fn dispatch_set_finalizer_f(_: DispatchObject, _: ?DispatchFunction) void {}

fn dispatchSourceRun(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const source: DispatchSource = @ptrCast(@alignCast(arg orelse return null));
    if (source.event_handler) |handler| handler(source.object.context);
    return null;
}

pub export fn dispatch_activate(object: DispatchObject) void {
    const source: DispatchSource = @ptrCast(@alignCast(object));
    if (source.kind != 1 or source.event_handler == null) return;
    _ = @import("pthread.zig").pthread_create(null, null, @ptrCast(&dispatchSourceRun), @ptrCast(source));
}

pub export fn dispatch_suspend(_: DispatchObject) void {}
pub export fn dispatch_resume(_: DispatchObject) void {}

pub export fn dispatch_once_f(predicate: *isize, context: ?*anyopaque, function: DispatchFunction) void {
    if (predicate.* == -1) return;
    function(context);
    predicate.* = -1;
}

pub export fn dispatch_get_global_queue(_: isize, _: usize) DispatchQueue {
    return &global_dispatch_queue;
}

pub export fn dispatch_queue_attr_make_initially_inactive(attr: ?DispatchObject) ?DispatchObject {
    return attr;
}

pub export fn dispatch_queue_create_with_target(_: ?[*:0]const u8, _: ?DispatchObject, target: ?DispatchQueue) ?DispatchQueue {
    if (target) |q| return q;
    const slot = @atomicRmw(usize, &next_dispatch_queue, .Add, 1, .monotonic);
    if (slot >= dispatch_queues.len) return null;
    dispatch_queues[slot] = .{};
    return &dispatch_queues[slot];
}

pub export fn dispatch_queue_create(label: ?[*:0]const u8, attr: ?DispatchObject) ?DispatchQueue {
    return dispatch_queue_create_with_target(label, attr, null);
}

pub export fn dispatch_queue_get_label(_: ?DispatchQueue) [*:0]const u8 {
    return "opendarwin\x00";
}

pub export fn dispatch_set_target_queue(_: DispatchObject, _: ?DispatchQueue) void {}
pub export fn dispatch_async_f(queue: DispatchQueue, context: ?*anyopaque, work: DispatchFunction) void {
    _ = queue;
    work(context);
}

pub export fn dispatch_sync_f(queue: DispatchQueue, context: ?*anyopaque, work: DispatchFunction) void {
    dispatch_async_f(queue, context, work);
}

pub export fn dispatch_async_and_wait_f(queue: DispatchQueue, context: ?*anyopaque, work: DispatchFunction) void {
    dispatch_async_f(queue, context, work);
}

pub export fn dispatch_async(queue: DispatchQueue, block: ?*anyopaque) void {
    _ = queue;
    _ = block;
}

pub export fn dispatch_sync(queue: DispatchQueue, block: ?*anyopaque) void {
    _ = queue;
    _ = block;
}

pub export fn dispatch_async_and_wait(queue: DispatchQueue, block: ?*anyopaque) void {
    _ = queue;
    _ = block;
}

pub export fn dispatch_source_create(source_type: DispatchSourceType, handle: usize, mask: usize, queue: ?DispatchQueue) ?DispatchSource {
    _ = handle;
    _ = mask;
    const slot = @atomicRmw(usize, &next_dispatch_source, .Add, 1, .monotonic);
    if (slot >= dispatch_sources.len) return null;
    dispatch_sources[slot] = .{ .kind = source_type.tag, .queue = queue };
    return &dispatch_sources[slot];
}

pub export fn dispatch_source_set_event_handler_f(source: DispatchSource, handler: ?DispatchFunction) void {
    source.event_handler = handler;
}

pub export fn dispatch_source_set_cancel_handler_f(source: DispatchSource, handler: ?DispatchFunction) void {
    source.cancel_handler = handler;
}

pub export fn dispatch_source_cancel(source: DispatchSource) void {
    if (source.cancel_handler) |handler| handler(source.object.context);
}

pub export fn dispatch_source_testcancel(_: DispatchSource) isize {
    return 0;
}

pub export fn dispatch_source_get_handle(_: DispatchSource) usize {
    return 0;
}

pub export fn dispatch_source_get_mask(_: DispatchSource) usize {
    return 0;
}

pub export fn dispatch_source_get_data(_: DispatchSource) usize {
    return 0;
}

pub export fn dispatch_source_merge_data(_: DispatchSource, _: usize) void {}
pub export fn dispatch_source_set_timer(_: DispatchSource, _: u64, _: u64, _: u64) void {}
pub export fn dispatch_source_set_registration_handler_f(_: DispatchSource, _: ?DispatchFunction) void {}
pub export fn dispatch_time(_: u64, delta: i64) u64 {
    return @bitCast(delta);
}

pub export fn dispatch_walltime(_: ?*const anyopaque, delta: i64) u64 {
    return @bitCast(delta);
}

pub export fn dispatch_block_notify(_: ?*anyopaque, _: DispatchQueue, _: ?*anyopaque) void {}
pub export fn dispatch_block_cancel(_: ?*anyopaque) void {}
pub export fn dispatch_block_testcancel(_: ?*anyopaque) c_int {
    return 0;
}

pub export fn dispatch_group_create() ?*anyopaque {
    return null;
}

pub export fn dispatch_group_enter(_: ?*anyopaque) void {}
pub export fn dispatch_group_leave(_: ?*anyopaque) void {}
pub export fn dispatch_group_wait(_: ?*anyopaque, _: u64) c_int {
    return 0;
}

pub export fn dispatch_semaphore_create(_: isize) ?*anyopaque {
    return null;
}

pub export fn dispatch_semaphore_wait(_: ?*anyopaque, _: u64) c_int {
    return 0;
}

pub export fn dispatch_semaphore_signal(_: ?*anyopaque) c_int {
    return 0;
}

pub export fn dispatch_once(predicate: *isize, block: ?*anyopaque) void {
    if (block) |b| {
        // A block is a pointer to a struct with an `invoke` function pointer at offset 0
        const BlockStruct = extern struct {
            invoke: *const fn (?*anyopaque) callconv(.c) void,
        };
        const bs: *const BlockStruct = @ptrCast(@alignCast(b));
        dispatch_once_f(predicate, b, bs.invoke);
    } else {
        // Just check and set the predicate without running anything
        if (@atomicLoad(isize, predicate, .acquire) != ~@as(isize, 0)) {
            @atomicStore(isize, predicate, ~@as(isize, 0), .release);
        }
    }
}

pub export fn dispatch_apply(iterations: usize, queue: ?*anyopaque, block: ?*anyopaque) void {
    _ = queue;
    const Block = *const fn (usize) callconv(.c) void;
    const block_fn: Block = @ptrCast(@alignCast(block));
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        block_fn(i);
    }
}
