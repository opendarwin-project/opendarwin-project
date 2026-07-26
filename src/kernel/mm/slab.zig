const pmm = @import("pmm.zig");

const PAGE_SIZE: usize = 4096;
const HEADER_SIZE: usize = 16; // zone_index + next_page

const Zone = struct {
    obj_size: usize,
    free_list: ?*anyopaque,
    page_list: ?u64,
};

const zone_sizes = [_]usize{ 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096 };
var zones: [zone_sizes.len]Zone = undefined;

fn zoneIndex(size: usize) ?usize {
    for (zone_sizes, 0..) |zs, i| {
        if (size <= zs) return i;
    }
    return null;
}

/// Initialises the slab allocator. Must be called after pmm.init().
pub fn init() void {
    for (zone_sizes, 0..) |zs, i| {
        zones[i] = .{
            .obj_size = zs,
            .free_list = null,
            .page_list = null,
        };
    }
}

fn addPage(zone_idx: usize) void {
    const zone = &zones[zone_idx];
    const pa = pmm.allocPage();
    const hdr: [*]u64 = @ptrFromInt(pa);
    hdr[0] = zone_idx;
    hdr[1] = zone.page_list orelse 0;
    zone.page_list = pa;

    // Carve the page into objects, chain them into the free list.
    // Objects start after the header.
    const obj_start = pa + HEADER_SIZE;
    const obj_size = zone.obj_size;
    var off: usize = 0;
    while (off + obj_size <= PAGE_SIZE - HEADER_SIZE) : (off += obj_size) {
        const obj_ptr: *?*anyopaque = @ptrFromInt(obj_start + off);
        obj_ptr.* = zone.free_list;
        zone.free_list = @as(*anyopaque, @ptrCast(obj_ptr));
    }
}

/// Allocates `size` bytes from the slab allocator. Returns a pointer or
/// panics on OOM.
pub fn alloc(size: usize) *anyopaque {
    const idx = zoneIndex(size) orelse @panic("slab: allocation too large");
    const zone = &zones[idx];
    if (zone.free_list == null) addPage(idx);
    const ptr = zone.free_list.?;
    zone.free_list = @as(*?*anyopaque, @ptrCast(@alignCast(ptr))).*;
    return ptr;
}

/// Allocates a zero-initialized block of `size` bytes.
pub fn allocz(size: usize) *anyopaque {
    const ptr = alloc(size);
    @memset(@as([*]u8, @ptrCast(ptr))[0..size], 0);
    return ptr;
}

/// Typed allocation: returns a pointer to `T`, zero-initialized.
pub fn allocObj(comptime T: type) *T {
    return @ptrCast(@alignCast(allocz(@sizeOf(T))));
}

/// Frees a pointer previously returned by `alloc()` or `allocObj()`.
/// The pointer must have been allocated from this slab allocator.
pub fn free(ptr: *anyopaque) void {
    const addr = @intFromPtr(ptr);
    const page_base = addr & ~(PAGE_SIZE - 1);
    const hdr: [*]u64 = @ptrFromInt(page_base);
    const zone_idx = hdr[0];
    const zone = &zones[zone_idx];
    const free_ptr: *?*anyopaque = @ptrCast(@alignCast(ptr));
    free_ptr.* = zone.free_list;
    zone.free_list = ptr;
}
