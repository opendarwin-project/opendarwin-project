//! Clang blocks runtime: minimal implementation for CoreFoundation and other
//! C code compiled with -fblocks.

const malloc = @import("malloc.zig");

// Block descriptor flags (ABI).
const BLOCK_HAS_COPY_DISPOSE: c_int = 1 << 25;
const BLOCK_HAS_SIGNATURE: c_int = 1 << 30;
const BLOCK_IS_GLOBAL: c_int = 1 << 28;

const BlockDescriptor = extern struct {
    reserved: usize = 0,
    size: usize = 0,
    copy: ?*const fn (*anyopaque, *anyopaque) callconv(.c) void = null,
    dispose: ?*const fn (*anyopaque) callconv(.c) void = null,
};

const BlockLayout = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: ?*const fn () callconv(.c) void,
    descriptor: *const BlockDescriptor,
};

fn blockFlags(block: *const BlockLayout) c_int {
    return @atomicLoad(c_int, &@as(*const BlockLayout, block).flags, .acquire);
}

fn blockIsGlobal(block: *const BlockLayout) bool {
    return (blockFlags(block) & BLOCK_IS_GLOBAL) != 0;
}

fn blockHasCopyDispose(block: *const BlockLayout) bool {
    return (blockFlags(block) & BLOCK_HAS_COPY_DISPOSE) != 0;
}

fn blockSize(block: *const BlockLayout) usize {
    return block.descriptor.size;
}

fn copyBlock(dst: *anyopaque, src: *anyopaque) callconv(.c) void {
    const layout: *const BlockLayout = @ptrCast(@alignCast(src));
    const size = blockSize(layout);
    _ = @import("string.zig").memcpy(dst, src, size);
    const dst_block: *BlockLayout = @ptrCast(@alignCast(dst));
    dst_block.isa = mallocBlockIsa();
}

fn mallocBlockIsa() *anyopaque {
    return @ptrCast(&_NSConcreteMallocBlock);
}

fn disposeBlock(block: *anyopaque) callconv(.c) void {
    malloc.free(block);
}

var malloc_block_descriptor: BlockDescriptor = .{
    .reserved = 0,
    .size = 0,
    .copy = copyBlock,
    .dispose = disposeBlock,
};

/// Stack block class marker (isa for blocks on the stack).
pub export var _NSConcreteStackBlock: BlockLayout = .{
    .isa = null,
    .flags = 0,
    .reserved = 0,
    .invoke = null,
    .descriptor = &malloc_block_descriptor,
};

/// Global block class marker (isa for global/static blocks).
pub export var _NSConcreteGlobalBlock: BlockLayout = .{
    .isa = null,
    .flags = BLOCK_IS_GLOBAL,
    .reserved = 0,
    .invoke = null,
    .descriptor = &malloc_block_descriptor,
};

/// Heap block class marker assigned by _Block_copy.
pub export var _NSConcreteMallocBlock: BlockLayout = .{
    .isa = null,
    .flags = BLOCK_HAS_COPY_DISPOSE,
    .reserved = 0,
    .invoke = null,
    .descriptor = &malloc_block_descriptor,
};

pub export fn _Block_copy(block: ?*const anyopaque) ?*anyopaque {
    const src = block orelse return null;
    const layout: *const BlockLayout = @ptrCast(@alignCast(src));
    if (blockIsGlobal(layout)) return @ptrCast(@constCast(src));
    if (layout.isa == mallocBlockIsa()) return @ptrCast(@constCast(src));

    const size = blockSize(layout);
    const dst = malloc.malloc(size) orelse return null;
    if (blockHasCopyDispose(layout)) {
        if (layout.descriptor.copy) |copy_fn| copy_fn(dst, @ptrCast(@constCast(src)));
    } else {
        copyBlock(dst, @ptrCast(@constCast(layout)));
    }
    return dst;
}

pub export fn _Block_release(block: ?*const anyopaque) void {
    const src = block orelse return;
    const layout: *const BlockLayout = @ptrCast(@alignCast(src));
    if (blockIsGlobal(layout)) return;
    if (layout.isa != mallocBlockIsa()) return;
    if (blockHasCopyDispose(layout)) {
        if (layout.descriptor.dispose) |dispose_fn| dispose_fn(@ptrCast(@constCast(src)));
    } else {
        disposeBlock(@ptrCast(@constCast(src)));
    }
}
