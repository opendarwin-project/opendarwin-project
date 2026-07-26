const mmu = @import("mmu.zig");

const PAGE_SIZE = mmu.PAGE_SIZE;

var free_head: ?u64 = null;
var total_free_pages: u64 = 0;

/// Describes a contiguous range of physical memory.
pub const MemoryRegion = struct {
    base: u64,
    size: u64,
};

/// Initializes the PMM with the given free memory region(s).
/// Maps the free region into the kernel's identity-mapped page table and
/// builds an intrusive singly-linked free list from every page inside it.
pub fn init(regions: []const MemoryRegion) void {
    for (regions) |r| {
        const start = r.base;
        const end = r.base + r.size;
        // Align to page boundaries
        const aligned_start = (start + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
        const aligned_end = end & ~(PAGE_SIZE - 1);
        if (aligned_start >= aligned_end) continue;

        // Map the free range into kernel_root so we can write to it.
        // Use 2MB-block mappings where possible for efficiency.
        mmu.mapExtra(aligned_start, aligned_end - aligned_start, .{
            .writable = true,
            .executable = false,
            .user = false,
        });
        mmu.inheritExtraInTaskTables(aligned_start, aligned_end - aligned_start, .{
            .writable = true,
            .executable = false,
            .user = false,
        });

        // Walk backwards through pages, chaining them into the free list.
        // Walking backwards means allocPage() returns low addresses first,
        // which is friendlier to page-table and other early allocations.
        var page = aligned_end - PAGE_SIZE;
        while (page >= aligned_start) : (page -= PAGE_SIZE) {
            const ptr: *?u64 = @ptrFromInt(page);
            ptr.* = free_head;
            free_head = page;
            total_free_pages += 1;
        }
    }
}

/// Allocates a single zeroed 4KB page. Returns the physical address
/// (which under the identity mapping is also the kernel-virtual address).
pub fn allocPage() u64 {
    const page = free_head orelse @panic("pmm: out of memory");
    const next_ptr: *u64 = @ptrFromInt(page);
    free_head = next_ptr.*;
    total_free_pages -= 1;
    const ptr: [*]u8 = @ptrFromInt(page);
    @memset(ptr[0..PAGE_SIZE], 0);
    return page;
}

/// Allocates `count` physically-contiguous zeroed pages. Only safe to call
/// before the free list has been fragmented by interleaved alloc/free
/// traffic - `init()` builds it in strictly increasing address order (see
/// that function's comment), so at this milestone (nothing else allocates
/// from `pmm` before loader/dyld.zig's shared-cache blobs, which is the
/// only caller needing more than one page) the first `count` free-list
/// entries are guaranteed contiguous. Panics rather than silently
/// fragmenting-and-retrying if that invariant is ever violated - a design
/// that would need revisiting (e.g. a real buddy allocator) the moment a
/// second multi-page caller shows up.
pub fn allocPagesContig(count: u64) u64 {
    if (count == 0) @panic("pmm: zero-page allocation");
    if (count > 256) @panic("pmm: allocPagesContig count exceeds this milestone's bound");

    var pages: [256]u64 = undefined;
    pages[0] = free_head orelse @panic("pmm: out of memory");
    var i: u64 = 1;
    while (i < count) : (i += 1) {
        const prev_ptr: *u64 = @ptrFromInt(pages[i - 1]);
        const next = prev_ptr.*;
        if (next != pages[i - 1] + PAGE_SIZE) {
            @panic("pmm: allocPagesContig found a fragmented free list - see this function's doc comment");
        }
        pages[i] = next;
    }

    const last_ptr: *u64 = @ptrFromInt(pages[count - 1]);
    free_head = last_ptr.*;
    total_free_pages -= count;

    for (pages[0..count]) |p| {
        const ptr: [*]u8 = @ptrFromInt(p);
        @memset(ptr[0..PAGE_SIZE], 0);
    }
    return pages[0];
}

/// Returns a page to the free pool. `pa` must be page-aligned and must
/// have been previously returned by `allocPage()`.
pub fn freePage(pa: u64) void {
    const ptr: *?u64 = @ptrFromInt(pa);
    ptr.* = free_head;
    free_head = pa;
    total_free_pages += 1;
}

/// Returns the number of free pages remaining.
pub fn freePages() u64 {
    return total_free_pages;
}
