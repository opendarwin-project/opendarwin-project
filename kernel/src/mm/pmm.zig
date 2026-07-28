const std = @import("std");
const mmu = @import("mmu.zig");

const PAGE_SIZE = mmu.PAGE_SIZE;

// ---------------------------------------------------------------------------
// Lock — single global spinlock for now.  Replace with per-CPU freelists
// once the scheduler is fully operational.
// ---------------------------------------------------------------------------

var lock: u32 = 0; // 0 = free, 1 = held

fn acquire() void {
    while (@cmpxchgStrong(u32, &lock, 0, 1, .acquire, .monotonic) != null) {
        // spin — on real hardware you'd issue WFE here to save power
    }
}

fn release() void {
    // Release fence is implicit on AArch64 (strongly-ordered memory model)
    lock = 0;
}

// ---------------------------------------------------------------------------
// Page states and reference counting
// ---------------------------------------------------------------------------

pub const PageState = enum(u8) {
    free = 0,
    allocated = 1,
    shared = 2, // refcount > 1, used for COW/shared memory
};

/// Per-page metadata stored in a dedicated region.
/// Indexed by PFN (Page Frame Number): meta[pfn] gives metadata for page at pa = pfn * PAGE_SIZE.
const PageMeta = packed struct {
    state: PageState,
    refcount: u8, // 0-255, clamped at 255 (saturating)
};

// We support up to 256 MB of physical memory with this design (32K pages * 4KB).
// Increase MAX_PAGES if you need more.
const MAX_PAGES: u64 = 32 * 1024; // 128 MB max tracked
var page_meta: [MAX_PAGES]PageMeta = undefined;
var max_pfn: u64 = 0; // highest PFN we've seen + 1

/// Convert physical address to page frame number.
inline fn paToPfn(pa: u64) u64 {
    return pa / PAGE_SIZE;
}

/// Convert page frame number to physical address.
inline fn pfnToPa(pfn: u64) u64 {
    return pfn * PAGE_SIZE;
}

/// Get metadata for a page. Caller must ensure pfn < max_pfn.
inline fn metaFor(pfn: u64) *PageMeta {
    return &page_meta[pfn];
}

// ---------------------------------------------------------------------------
// Free list
// ---------------------------------------------------------------------------

var free_head: ?u64 = null;
var total_free_pages: u64 = 0;
var total_alloced_pages: u64 = 0;

/// Describes a contiguous range of physical memory.
pub const MemoryRegion = struct {
    base: u64,
    size: u64,
};

/// Initializes the PMM with the given free memory region(s).
/// Maps the free region into the kernel's identity-mapped page table and
/// builds an intrusive singly-linked free list from every page inside it.
pub fn init(regions: []const MemoryRegion) void {
    // First pass: find the highest address to size our metadata array
    for (regions) |r| {
        const end = r.base + r.size;
        const aligned_end = end & ~(PAGE_SIZE - 1);
        const end_pfn = paToPfn(aligned_end);
        if (end_pfn > max_pfn) max_pfn = end_pfn;
    }

    // Ensure we don't overflow our metadata array
    if (max_pfn > MAX_PAGES) {
        // Clamp to MAX_PAGES - all pages beyond this are unusable
        max_pfn = MAX_PAGES;
    }

    // Initialize all page metadata to free
    for (0..max_pfn) |i| {
        page_meta[i] = .{ .state = .free, .refcount = 0 };
    }

    // Second pass: build the free list
    for (regions) |r| {
        const start = r.base;
        const end = r.base + r.size;
        // Align to page boundaries
        const aligned_start = (start + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
        const aligned_end = end & ~(PAGE_SIZE - 1);
        if (aligned_start >= aligned_end) continue;

        // Map the free range into kernel_root so we can write to it.
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
        var page = aligned_end - PAGE_SIZE;
        while (page >= aligned_start) : (page -= PAGE_SIZE) {
            const ptr: *?u64 = @ptrFromInt(page);
            ptr.* = free_head;
            free_head = page;
            total_free_pages += 1;
        }
    }
}

// ---------------------------------------------------------------------------
// Single-page allocation
// ---------------------------------------------------------------------------

/// Allocates a single zeroed 4KB page. Returns the physical address
/// (which under the identity mapping is also the kernel-virtual address).
pub fn allocPage() u64 {
    return allocPageInternal(true);
}

/// Allocates a single 4KB page without zeroing. Faster when the caller
/// will overwrite the page entirely (e.g., slab allocator, page tables).
pub fn allocPageUninit() u64 {
    return allocPageInternal(false);
}

fn allocPageInternal(zero: bool) u64 {
    acquire();
    defer release();

    const page = free_head orelse @panic("pmm: out of memory");
    const next_ptr: *u64 = @ptrFromInt(page);
    free_head = next_ptr.*;
    total_free_pages -= 1;
    total_alloced_pages += 1;

    // Initialize page metadata
    const pfn = paToPfn(page);
    if (pfn < max_pfn) {
        const m = metaFor(pfn);
        m.state = .allocated;
        m.refcount = 1;
    }

    if (zero) {
        const ptr: [*]u8 = @ptrFromInt(page);
        @memset(ptr[0..PAGE_SIZE], 0);
    }
    return page;
}

// ---------------------------------------------------------------------------
// Multi-page (non-contiguous) allocation
// ---------------------------------------------------------------------------

/// Allocates `count` pages (not necessarily contiguous). Each is zeroed.
pub const PageSlice = struct {
    base: u64,
    count: u64,
};

pub fn allocPages(count: u64) PageSlice {
    if (count == 0) @panic("pmm: zero-page allocation");

    acquire();
    defer release();

    const first = free_head orelse @panic("pmm: out of memory");

    // Walk to find the count-th page
    var last = first;
    var i: u64 = 1;
    while (i < count) : (i += 1) {
        const last_ptr: *u64 = @ptrFromInt(last);
        last = last_ptr.*;
    }

    const last_ptr: *u64 = @ptrFromInt(last);
    free_head = last_ptr.*;
    total_free_pages -= count;
    total_alloced_pages += count;

    // Initialize metadata and zero all pages
    var page = first;
    var j: u64 = 0;
    while (j < count) : (j += 1) {
        const pfn = paToPfn(page);
        if (pfn < max_pfn) {
            const m = metaFor(pfn);
            m.state = .allocated;
            m.refcount = 1;
        }
        const ptr: [*]u8 = @ptrFromInt(page);
        @memset(ptr[0..PAGE_SIZE], 0);
        page += PAGE_SIZE;
    }

    return .{ .base = first, .count = count };
}

// ---------------------------------------------------------------------------
// Contiguous allocation (best-effort, may fail if fragmented)
// ---------------------------------------------------------------------------

/// Allocates `count` physically-contiguous zeroed pages.
/// Returns 0 if no contiguous range is available (does NOT panic).
pub fn allocPagesContig(count: u64) u64 {
    if (count == 0) @panic("pmm: zero-page allocation");
    if (count == 1) return allocPage();

    acquire();
    defer release();

    // Walk the free list looking for `count` contiguous pages.
    var candidate: u64 = 0;
    var run: u64 = 0;
    var cur = free_head;

    while (cur) |page| {
        if (candidate != 0 and page == candidate + run * PAGE_SIZE) {
            run += 1;
            if (run == count) break;
        } else {
            candidate = page;
            run = 1;
        }
        const next_ptr: *u64 = @ptrFromInt(page);
        cur = next_ptr.*;
    }

    if (run < count) return 0;

    // Unlink the `count` pages from the free list
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        const target = candidate + i * PAGE_SIZE;
        removePageFromList(target);
        total_free_pages -= 1;
        total_alloced_pages += 1;

        // Initialize metadata
        const pfn = paToPfn(target);
        if (pfn < max_pfn) {
            const m = metaFor(pfn);
            m.state = .allocated;
            m.refcount = 1;
        }
    }

    // Zero the contiguous range
    const ptr: [*]u8 = @ptrFromInt(candidate);
    @memset(ptr[0 .. count * PAGE_SIZE], 0);

    return candidate;
}

/// Remove a specific page from the free list. Caller must hold the lock.
fn removePageFromList(target: u64) void {
    if (free_head == target) {
        const next_ptr: *u64 = @ptrFromInt(target);
        free_head = next_ptr.*;
        return;
    }

    var prev: u64 = free_head.?;
    while (true) {
        const prev_next: *u64 = @ptrFromInt(prev);
        if (prev_next.* == target) {
            prev_next.* = @as(*u64, @ptrFromInt(target)).*;
            return;
        }
        prev = prev_next.*;
    }
}

// ---------------------------------------------------------------------------
// Reference counting — core primitives for page sharing
// ---------------------------------------------------------------------------

/// Increment the reference count for a page. Returns the new refcount.
/// Used when another process or mapping wants to share this page.
pub fn refPage(pa: u64) u8 {
    acquire();
    defer release();

    const pfn = paToPfn(pa);
    if (pfn >= max_pfn) return 0;

    const m = metaFor(pfn);
    if (m.refcount < 255) {
        m.refcount += 1;
    }
    if (m.refcount > 1) {
        m.state = .shared;
    }
    return m.refcount;
}

/// Decrement the reference count for a page. If refcount reaches 0, frees the page.
/// Returns the new refcount. Caller should check if page was freed (refcount == 0).
pub fn unrefPage(pa: u64) u8 {
    acquire();
    defer release();

    const pfn = paToPfn(pa);
    if (pfn >= max_pfn) return 0;

    const m = metaFor(pfn);
    if (m.refcount > 0) {
        m.refcount -= 1;
    }

    if (m.refcount == 0) {
        // Actually free the page
        const ptr: *?u64 = @ptrFromInt(pa);
        ptr.* = free_head;
        free_head = pa;
        total_free_pages += 1;
        total_alloced_pages -|= 1;
        m.state = .free;
    } else if (m.refcount == 1) {
        m.state = .allocated; // no longer shared
    }

    return m.refcount;
}

/// Get the current reference count for a page.
pub fn refCount(pa: u64) u8 {
    const pfn = paToPfn(pa);
    if (pfn >= max_pfn) return 0;
    return metaFor(pfn).refcount;
}

/// Get the current state of a page.
pub fn pageState(pa: u64) PageState {
    const pfn = paToPfn(pa);
    if (pfn >= max_pfn) return .free;
    return metaFor(pfn).state;
}

// ---------------------------------------------------------------------------
// Page cloning — for COW (Copy-on-Write) support
// ---------------------------------------------------------------------------

/// Clone a page for COW purposes. Increments refcount and returns the same
/// physical address. The caller is responsible for marking the page table
/// entries as read-only in both processes.
///
/// Returns: physical address of the shared page (same as input).
pub fn clonePageForCOW(pa: u64) u64 {
    _ = refPage(pa);
    return pa;
}

/// Split a COW page: allocate a new page, copy contents, decrement old refcount.
/// Returns the new physical address with refcount=1.
///
/// This is called when a process tries to write to a COW page.
pub fn splitCOWPage(old_pa: u64) u64 {
    // Allocate a new page (uninitialized, we'll copy into it)
    const new_pa = allocPageUninit();

    // Copy the old page contents
    const src: [*]const u8 = @ptrFromInt(old_pa);
    const dst: [*]u8 = @ptrFromInt(new_pa);
    @memcpy(dst[0..PAGE_SIZE], src[0..PAGE_SIZE]);

    // Release the old page's reference (may free it if refcount was 1)
    _ = unrefPage(old_pa);

    return new_pa;
}

// ---------------------------------------------------------------------------
// Free
// ---------------------------------------------------------------------------

/// Returns a page to the free pool. `pa` must be page-aligned and must
/// have been previously returned by an alloc function.
/// NOTE: Prefer using unrefPage() for pages that may be shared.
pub fn freePage(pa: u64) void {
    acquire();
    defer release();

    // Update metadata
    const pfn = paToPfn(pa);
    if (pfn < max_pfn) {
        const m = metaFor(pfn);
        m.state = .free;
        m.refcount = 0;
    }

    const ptr: *?u64 = @ptrFromInt(pa);
    ptr.* = free_head;
    free_head = pa;
    total_free_pages += 1;
    total_alloced_pages -|= 1;
}

/// Frees `count` pages starting at `pa`.
pub fn freePages(pa: u64, count: u64) void {
    acquire();
    defer release();

    var i: u64 = 0;
    while (i < count) : (i += 1) {
        const page = pa + i * PAGE_SIZE;
        const pfn = paToPfn(page);
        if (pfn < max_pfn) {
            const m = metaFor(pfn);
            m.state = .free;
            m.refcount = 0;
        }
        const ptr: *?u64 = @ptrFromInt(page);
        ptr.* = free_head;
        free_head = page;
        total_free_pages += 1;
        total_alloced_pages -|= 1;
    }
}

// ---------------------------------------------------------------------------
// Stats
// ---------------------------------------------------------------------------

/// Returns the number of free pages remaining.
pub fn freePagesCount() u64 {
    return total_free_pages;
}

/// Returns the number of allocated pages.
pub fn allocedPages() u64 {
    return total_alloced_pages;
}

/// Returns total memory tracked by the PMM (free + allocated) in bytes.
pub fn totalBytes() u64 {
    return (total_free_pages + total_alloced_pages) * PAGE_SIZE;
}

/// Returns the number of shared pages (refcount > 1).
pub fn sharedPagesCount() u64 {
    var count: u64 = 0;
    for (0..max_pfn) |i| {
        if (page_meta[i].state == .shared) {
            count += 1;
        }
    }
    return count;
}
