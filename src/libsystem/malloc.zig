//! Memory allocation: malloc, calloc, realloc, free, malloc_size,
//! posix_memalign, bzero, arc4random_buf.

const common = @import("common.zig");
const C = common;

const MallocHeader = extern struct {
    magic: usize,
    requested: usize,
    total: usize,
};

const MALLOC_MAGIC: usize = 0x4f44574d414c4c4f; // ODW MALLO
const MALLOC_ALIGN: usize = 16;

fn mallocHeader(ptr: ?*anyopaque) ?*MallocHeader {
    const p = ptr orelse return null;
    const addr = @intFromPtr(p);
    if (addr < @sizeOf(MallocHeader)) return null;
    const header: *MallocHeader = @ptrFromInt(addr - @sizeOf(MallocHeader));
    if (header.magic != MALLOC_MAGIC) return null;
    return header;
}

pub export fn malloc(size: usize) ?*anyopaque {
    const requested = if (size == 0) 1 else size;
    const payload_off = (@sizeOf(MallocHeader) + (MALLOC_ALIGN - 1)) & ~(MALLOC_ALIGN - 1);
    const total = (payload_off + requested + 4095) & ~@as(usize, 4095);
    const base = @import("mach.zig").mmap(null, total, C.VM_PROT_READ_WRITE, C.MAP_PRIVATE_ANON, -1, 0);
    if (base == null or @intFromPtr(base.?) == C.usize_max) return null;
    const header: *MallocHeader = @ptrCast(@alignCast(base.?));
    header.* = .{ .magic = MALLOC_MAGIC, .requested = requested, .total = total };
    return @ptrFromInt(@intFromPtr(base.?) + payload_off);
}

pub export fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque {
    if (ptr == null) return malloc(size);
    if (size == 0) {
        free(ptr);
        return null;
    }
    const old_size = malloc_size(ptr);
    const next = malloc(size) orelse return null;
    const n = if (old_size < size) old_size else size;
    _ = @memcpy(@as([*]u8, @ptrCast(next))[0..n], @as([*]const u8, @ptrCast(ptr))[0..n]);
    free(ptr);
    return next;
}

pub export fn free(ptr: ?*anyopaque) void {
    const header = mallocHeader(ptr) orelse return;
    _ = @import("mach.zig").munmap(header, header.total);
}

pub export fn malloc_size(ptr: ?*anyopaque) usize {
    const header = mallocHeader(ptr) orelse return 0;
    return header.requested;
}

pub export fn calloc(nmemb: usize, size: usize) ?*anyopaque {
    if (nmemb == 0 or size == 0) return null;
    const total = nmemb *% size;
    if (nmemb != 0 and total / nmemb != size) {
        common.errno = C.ENOMEM;
        return null;
    }
    const ptr = malloc(total) orelse return null;
    _ = @memset(@as([*]u8, @ptrCast(ptr))[0..total], 0);
    return ptr;
}

pub export fn posix_memalign(_: *?*anyopaque, _: usize, _: usize) c_int {
    return C.stubErr("posix_memalign");
}

pub export fn bzero(ptr: [*]u8, len: usize) void {
    const out: [*]volatile u8 = @ptrCast(ptr);
    var i: usize = 0;
    while (i < len) : (i += 1) out[i] = 0;
}

pub export fn arc4random_buf(ptr: [*]u8, len: usize) void {
    // Deterministic milestone entropy until the kernel exposes a CSPRNG.
    const out: [*]volatile u8 = @ptrCast(ptr);
    var i: usize = 0;
    while (i < len) : (i += 1) out[i] = 0;
}

// ── malloc_zone API ────────────────────────────────────────────────────

const MallocZone = extern struct {
    reserved: ?*anyopaque,
    size: *const fn (?*anyopaque, ?*const anyopaque) callconv(.c) usize,
    malloc: *const fn (?*anyopaque, usize) callconv(.c) ?*anyopaque,
    calloc: *const fn (?*anyopaque, usize, usize) callconv(.c) ?*anyopaque,
    valloc: *const fn (?*anyopaque, usize) callconv(.c) ?*anyopaque,
    free: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
    realloc: *const fn (?*anyopaque, ?*anyopaque, usize) callconv(.c) ?*anyopaque,
    memalign: *const fn (?*anyopaque, usize, usize) callconv(.c) ?*anyopaque,
};

var default_malloc_zone: MallocZone = .{
    .reserved = null,
    .size = @ptrCast(&malloc_size),
    .malloc = @ptrCast(&zone_malloc_wrapper),
    .calloc = @ptrCast(&zone_calloc_wrapper),
    .valloc = @ptrCast(&zone_valloc_wrapper),
    .free = @ptrCast(&zone_free_wrapper),
    .realloc = @ptrCast(&zone_realloc_wrapper),
    .memalign = @ptrCast(&zone_memalign_wrapper),
};

fn zone_malloc_wrapper(_: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    return malloc(size);
}

fn zone_calloc_wrapper(_: ?*anyopaque, count: usize, size: usize) callconv(.c) ?*anyopaque {
    return calloc(count, size);
}

fn zone_valloc_wrapper(_: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    _ = size;
    return null;
}

fn zone_free_wrapper(_: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
    free(ptr);
}

fn zone_realloc_wrapper(_: ?*anyopaque, ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    return realloc(ptr, size);
}

fn zone_memalign_wrapper(_: ?*anyopaque, alignment: usize, size: usize) callconv(.c) ?*anyopaque {
    _ = alignment;
    _ = size;
    return null;
}

pub export fn malloc_default_zone() ?*MallocZone {
    return &default_malloc_zone;
}

pub export fn malloc_good_size(size: usize) usize {
    // Return size rounded up to alignment
    return (size + 15) & ~@as(usize, 15);
}

pub export fn malloc_zone_free(zone: ?*MallocZone, ptr: ?*anyopaque) void {
    _ = zone;
    free(ptr);
}

pub export fn malloc_zone_malloc(zone: ?*MallocZone, size: usize) ?*anyopaque {
    _ = zone;
    return malloc(size);
}

pub export fn malloc_zone_memalign(zone: ?*MallocZone, alignment: usize, size: usize) ?*anyopaque {
    _ = zone;
    _ = alignment;
    _ = size;
    return null;
}

pub export fn malloc_zone_realloc(zone: ?*MallocZone, ptr: ?*anyopaque, size: usize) ?*anyopaque {
    _ = zone;
    return realloc(ptr, size);
}

pub export fn vm_page_size() usize {
    return 4096;
}

pub export fn vm_purgable_control(_: c_uint, _: c_int, _: ?*c_int) c_int {
    return 0;
}

pub export fn mach_vm_allocate(_: c_uint, addr: *u64, size: u64, flags: c_int) c_int {
    _ = flags;
    // Use mmap via the existing mechanism
    const ptr = @import("mach.zig").mmap(null, @as(usize, @intCast(size)), 3, 0x4002, -1, 0);
    if (@intFromPtr(ptr) == C.usize_max) return 3; // KERN_FAILURE
    addr.* = @intFromPtr(ptr);
    return 0;
}

pub export fn mach_vm_deallocate(_: c_uint, addr: u64, size: u64) c_int {
    _ = addr;
    _ = size;
    return 0;
}

pub export fn mach_vm_region(_: c_uint, _: *u64, _: *u64, _: c_int, _: ?*c_int, _: ?*c_int) c_int {
    // Stub: report a single large region
    return 1; // KERN_FAILURE
}
