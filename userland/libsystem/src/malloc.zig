//! Memory allocation: malloc, calloc, realloc, free, malloc_size,
//! posix_memalign, bzero, arc4random_buf.

const common = @import("common.zig");
const mach = @import("mach.zig");
const C = common;

const MallocHeader = extern struct {
    magic: usize,
    requested: usize,
    total: usize,
    kind: usize, // 0 = heap chunk, 1 = dedicated mmap
};

const MALLOC_MAGIC: usize = 0x4f44574d414c4c4f; // ODW MALLO
const MALLOC_ALIGN: usize = 16;
const PAGE_SIZE: usize = 4096;
const HEAP_CHUNK_SIZE: usize = 2 * 1024 * 1024;
const MMAP_THRESHOLD: usize = HEAP_CHUNK_SIZE / 2;

const HeapChunk = struct {
    next: ?*HeapChunk,
    base: [*]u8,
    size: usize,
    used: usize,
};

var heap_head: ?*HeapChunk = null;

fn pageRound(len: usize) usize {
    return (len + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
}

fn mallocHeader(ptr: ?*anyopaque) ?*MallocHeader {
    const p = ptr orelse return null;
    const addr = @intFromPtr(p);
    if (addr < @sizeOf(MallocHeader)) return null;
    const header: *MallocHeader = @ptrFromInt(addr - @sizeOf(MallocHeader));
    if (header.magic != MALLOC_MAGIC) return null;
    return header;
}

fn mapHeapChunk() ?*HeapChunk {
    const mapped = mach.mmap(null, HEAP_CHUNK_SIZE, C.VM_PROT_READ_WRITE, C.MAP_PRIVATE_ANON, -1, 0);
    if (mapped == null or @intFromPtr(mapped.?) == C.usize_max) return null;

    const chunk: *HeapChunk = @ptrCast(@alignCast(mapped.?));
    const data_start = @intFromPtr(mapped.?) + @sizeOf(HeapChunk);
    const data_aligned = (data_start + MALLOC_ALIGN - 1) & ~(MALLOC_ALIGN - 1);
    chunk.* = .{
        .next = heap_head,
        .base = @ptrFromInt(data_aligned),
        .size = HEAP_CHUNK_SIZE - (data_aligned - @intFromPtr(mapped.?)),
        .used = 0,
    };
    heap_head = chunk;
    return chunk;
}

fn allocFromHeap(total: usize) ?[*]u8 {
    var chunk = heap_head;
    while (chunk) |c| {
        const aligned_used = (c.used + MALLOC_ALIGN - 1) & ~(MALLOC_ALIGN - 1);
        if (aligned_used + total <= c.size) {
            const ptr = c.base + aligned_used;
            c.used = aligned_used + total;
            return ptr;
        }
        chunk = c.next;
    }

    const new_chunk = mapHeapChunk() orelse return null;
    const aligned_used = (new_chunk.used + MALLOC_ALIGN - 1) & ~(MALLOC_ALIGN - 1);
    const ptr = new_chunk.base + aligned_used;
    new_chunk.used = aligned_used + total;
    return ptr;
}

pub export fn malloc(size: usize) ?*anyopaque {
    const requested = if (size == 0) 1 else size;
    const payload_off = (@sizeOf(MallocHeader) + MALLOC_ALIGN - 1) & ~(MALLOC_ALIGN - 1);
    const total = payload_off + requested;

    const base: [*]u8 = if (total > MMAP_THRESHOLD) blk: {
        const mapped = mach.mmap(null, pageRound(total), C.VM_PROT_READ_WRITE, C.MAP_PRIVATE_ANON, -1, 0);
        if (mapped == null or @intFromPtr(mapped.?) == C.usize_max) return null;
        break :blk @ptrCast(mapped.?);
    } else blk: {
        break :blk allocFromHeap(total) orelse return null;
    };

    const header: *MallocHeader = @ptrCast(@alignCast(base));
    header.* = .{
        .magic = MALLOC_MAGIC,
        .requested = requested,
        .total = if (total > MMAP_THRESHOLD) pageRound(total) else total,
        .kind = if (total > MMAP_THRESHOLD) 1 else 0,
    };
    return @ptrFromInt(@intFromPtr(base) + payload_off);
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
    if (header.kind == 1) {
        _ = mach.munmap(header, header.total);
    }
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
    const ptr = mach.mmap(null, @as(usize, @intCast(size)), 3, 0x4002, -1, 0);
    if (@intFromPtr(ptr) == C.usize_max) return 3; // KERN_FAILURE
    addr.* = @intFromPtr(ptr);
    return 0;
}

pub export fn mach_vm_deallocate(_: c_uint, addr: u64, size: u64) c_int {
    const ret = mach.munmap(@ptrFromInt(addr), @as(usize, @intCast(size)));
    return if (ret == 0) 0 else 3; // KERN_FAILURE
}

pub export fn mach_vm_region(_: c_uint, _: *u64, _: *u64, _: c_int, _: ?*c_int, _: ?*c_int) c_int {
    // Stub: report a single large region
    return 1; // KERN_FAILURE
}
