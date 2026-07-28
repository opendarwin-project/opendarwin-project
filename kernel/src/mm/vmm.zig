const std = @import("std");
const mmu = @import("mmu.zig");
const pmm = @import("pmm.zig");

const PAGE_SIZE = mmu.PAGE_SIZE;
const MAX_REGIONS = 128;
// The main PIE executable is linked at 0x1_0000_0000. Keep anonymous
// Mach VM mappings above it until the process VMM imports loader regions.
const MMAP_BASE: u64 = 0x2_0000_0000;

const KERN_SUCCESS: u32 = 0;
const KERN_NO_SPACE: u32 = 3;
const KERN_INVALID_ARGUMENT: u32 = 4;
const KERN_NOT_SUPPORTED: u32 = 46;

const VM_PROT_WRITE: u32 = 2;
const VM_PROT_EXECUTE: u32 = 4;
const VM_PROT_ALL: u32 = 7;

const VM_FLAGS_ANYWHERE: u32 = 1;
const VM_FLAGS_OVERWRITE: u32 = 0x4000;

/// VM region flags
pub const VM_FLAG_COW: u32 = 0x100; // Region uses copy-on-write semantics
pub const VM_FLAG_SHARED: u32 = 0x200; // Region is shared (MAP_SHARED)

// ---------------------------------------------------------------------------
// Shared memory registry — global named shared memory objects
// ---------------------------------------------------------------------------

const MAX_SHARED_REGIONS = 64;
const MAX_NAME_LEN = 64;

pub const SharedRegion = struct {
    name: [MAX_NAME_LEN]u8 = undefined,
    name_len: usize = 0,
    physical_pages: ?u64 = null, // base PA of the shared pages
    page_count: u64 = 0,
    ref_count: u32 = 0, // number of processes mapping this region
    in_use: bool = false,
};

var shared_regions: [MAX_SHARED_REGIONS]SharedRegion = undefined;

/// Create or open a shared memory region by name.
/// Returns the physical base address and page count of the shared region.
/// If the region already exists, increments ref_count and returns existing pages.
pub fn shmOpen(name: []const u8, page_count: u64) ?struct { pa: u64, pages: u64 } {
    if (name.len >= MAX_NAME_LEN or name.len == 0) return null;

    // Search for existing region
    for (&shared_regions) |*sr| {
        if (sr.in_use and sr.name_len == name.len and std.mem.eql(u8, sr.name[0..sr.name_len], name)) {
            sr.ref_count += 1;
            return .{ .pa = sr.physical_pages.?, .pages = sr.page_count };
        }
    }

    // Create new region
    for (&shared_regions) |*sr| {
        if (!sr.in_use) {
            // Allocate physical pages for the shared region
            const pages = pmm.allocPages(page_count);
            @memcpy(sr.name[0..name.len], name);
            sr.name_len = name.len;
            sr.physical_pages = pages.base;
            sr.page_count = page_count;
            sr.ref_count = 1;
            sr.in_use = true;
            return .{ .pa = pages.base, .pages = page_count };
        }
    }

    return null; // no free slots
}

/// Close a shared memory region. If ref_count reaches 0, frees the pages.
pub fn shmClose(name: []const u8) void {
    for (&shared_regions) |*sr| {
        if (sr.in_use and sr.name_len == name.len and std.mem.eql(u8, sr.name[0..sr.name_len], name)) {
            sr.ref_count -= 1;
            if (sr.ref_count == 0) {
                // Free all pages
                pmm.freePages(sr.physical_pages.?, sr.page_count);
                sr.in_use = false;
                sr.physical_pages = null;
                sr.page_count = 0;
            }
            return;
        }
    }
}

/// Get info about a shared memory region.
pub fn shmInfo(name: []const u8) ?struct { pa: u64, pages: u64, ref_count: u32 } {
    for (shared_regions) |sr| {
        if (sr.in_use and sr.name_len == name.len and std.mem.eql(u8, sr.name[0..sr.name_len], name)) {
            return .{ .pa = sr.physical_pages.?, .pages = sr.page_count, .ref_count = sr.ref_count };
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// VMA and VMM
// ---------------------------------------------------------------------------

pub const Vma = struct {
    start: u64,
    end: u64,
    prot: mmu.Prot,
    flags: u32,
    shared_name_len: u16 = 0, // length of shared name if VM_FLAG_SHARED is set
    shared_name: [MAX_NAME_LEN]u8 = undefined,
};

pub const MachMapResult = struct { kr: u32, addr: u64 };

pub const Vmm = struct {
    ttbr0: *mmu.Table,
    regions: [MAX_REGIONS]Vma = undefined,
    region_count: usize = 0,
    brk_start: u64 = 0,
    brk_current: u64 = 0,
    next_mmap_hint: u64 = MMAP_BASE,

    pub fn init(ttbr0: *mmu.Table) Vmm {
        return .{ .ttbr0 = ttbr0 };
    }

    pub fn addRegion(self: *Vmm, start: u64, end: u64, prot: mmu.Prot, flags: u32) void {
        if (self.region_count >= MAX_REGIONS) @panic("vmm: too many regions");
        self.regions[self.region_count] = .{ .start = start, .end = end, .prot = prot, .flags = flags };
        self.region_count += 1;
    }

    fn addRegionChecked(self: *Vmm, start: u64, end: u64, prot: mmu.Prot, flags: u32) bool {
        if (self.region_count >= MAX_REGIONS) return false;
        self.regions[self.region_count] = .{ .start = start, .end = end, .prot = prot, .flags = flags };
        self.region_count += 1;
        return true;
    }

    fn pageRound(len: u64) ?u64 {
        const with_slop = @addWithOverflow(len, PAGE_SIZE - 1);
        if (with_slop[1] != 0) return null;
        return with_slop[0] & ~(PAGE_SIZE - 1);
    }

    fn rangeOverlaps(self: *const Vmm, start: u64, len: u64) bool {
        const end_overflow = @addWithOverflow(start, len);
        if (end_overflow[1] != 0) return true;
        const end = end_overflow[0];
        for (self.regions[0..self.region_count]) |r| {
            if (start < r.end and end > r.start) return true;
        }
        return false;
    }

    fn findFreeRange(self: *Vmm, len: u64) u64 {
        const aligned_len = pageRound(len) orelse return 0;
        var candidate = self.next_mmap_hint;
        for (0..1024) |_| {
            var ok = true;
            for (self.regions[0..self.region_count]) |r| {
                const end_overflow = @addWithOverflow(candidate, aligned_len);
                if (end_overflow[1] != 0) return 0;
                if (candidate < r.end and end_overflow[0] > r.start) {
                    candidate = r.end;
                    ok = false;
                    break;
                }
            }
            if (ok) {
                self.next_mmap_hint = candidate + aligned_len;
                return candidate;
            }
        }
        return 0;
    }

    fn mapAnonymous(self: *Vmm, addr: u64, len: u64, prot: mmu.Prot, flags: u32) u32 {
        if (self.region_count >= MAX_REGIONS) return KERN_NO_SPACE;
        var mapped: u64 = 0;
        while (mapped < len) : (mapped += PAGE_SIZE) {
            const pa = pmm.allocPage();
            mmu.mapPages(self.ttbr0, addr + mapped, pa, PAGE_SIZE, prot);
        }
        if (!self.addRegionChecked(addr, addr + len, prot, flags)) return KERN_NO_SPACE;
        return KERN_SUCCESS;
    }

    pub fn machAllocate(self: *Vmm, requested_addr: u64, size: u64, flags: u32) MachMapResult {
        if (size == 0) return .{ .kr = KERN_SUCCESS, .addr = 0 };
        const user_flags = flags & 0x00ff_ffff;
        if ((user_flags & ~VM_FLAGS_ANYWHERE) != 0) return .{ .kr = KERN_INVALID_ARGUMENT, .addr = requested_addr };
        const aligned_len = pageRound(size) orelse return .{ .kr = KERN_INVALID_ARGUMENT, .addr = requested_addr };
        var va: u64 = undefined;
        if ((flags & VM_FLAGS_ANYWHERE) != 0) {
            va = self.findFreeRange(aligned_len);
            if (va == 0) return .{ .kr = KERN_NO_SPACE, .addr = requested_addr };
        } else {
            va = requested_addr & ~(PAGE_SIZE - 1);
            if (va == 0 or self.rangeOverlaps(va, aligned_len)) return .{ .kr = KERN_NO_SPACE, .addr = requested_addr };
        }
        const prot = mmu.Prot{ .writable = true, .executable = false, .user = true };
        return .{ .kr = self.mapAnonymous(va, aligned_len, prot, flags), .addr = va };
    }

    pub fn machMap(self: *Vmm, requested_addr: u64, size: u64, mask: u64, flags: u32, cur_protection: u32) MachMapResult {
        if (size == 0) return .{ .kr = KERN_INVALID_ARGUMENT, .addr = requested_addr };
        if (mask != 0) return .{ .kr = KERN_NOT_SUPPORTED, .addr = requested_addr };
        if ((cur_protection & ~VM_PROT_ALL) != 0) return .{ .kr = KERN_INVALID_ARGUMENT, .addr = requested_addr };
        const user_flags = flags & 0x00ff_ffff;
        if ((user_flags & ~(VM_FLAGS_ANYWHERE | VM_FLAGS_OVERWRITE)) != 0) return .{ .kr = KERN_INVALID_ARGUMENT, .addr = requested_addr };
        if ((user_flags & VM_FLAGS_OVERWRITE) != 0) return .{ .kr = KERN_NOT_SUPPORTED, .addr = requested_addr };
        const aligned_len = pageRound(size) orelse return .{ .kr = KERN_INVALID_ARGUMENT, .addr = requested_addr };
        var va: u64 = undefined;
        if ((flags & VM_FLAGS_ANYWHERE) != 0) {
            va = self.findFreeRange(aligned_len);
            if (va == 0) return .{ .kr = KERN_NO_SPACE, .addr = requested_addr };
        } else {
            va = requested_addr & ~(PAGE_SIZE - 1);
            if (va == 0 or self.rangeOverlaps(va, aligned_len)) return .{ .kr = KERN_NO_SPACE, .addr = requested_addr };
        }
        const prot = mmu.Prot{
            .writable = (cur_protection & VM_PROT_WRITE) != 0,
            .executable = (cur_protection & VM_PROT_EXECUTE) != 0,
            .user = true,
        };
        return .{ .kr = self.mapAnonymous(va, aligned_len, prot, flags), .addr = va };
    }

    /// Map a contiguous physical range into this address space (no page ownership).
    /// Used for the virtio-gpu scanout aperture shared with userspace.
    pub fn mapPhysical(self: *Vmm, pa: u64, len: u64) u64 {
        const aligned_len = pageRound(len) orelse return 0;
        const page_count = aligned_len / PAGE_SIZE;
        const va = self.findFreeRange(aligned_len);
        if (va == 0) return 0;
        const prot = mmu.Prot{ .writable = true, .executable = false, .user = true };
        if (self.mapShared(va, pa, page_count, prot, "od-fb") != KERN_SUCCESS) return 0;
        return va;
    }

    pub fn mmap(self: *Vmm, hint: u64, len: u64, prot_val: i32, flags: i32) u64 {
        const aligned_len = pageRound(len) orelse return 0xffffffffffffffff;
        var va = if (hint != 0 and hint % PAGE_SIZE == 0) hint else 0;
        if (va != 0 and self.rangeOverlaps(va, aligned_len)) return 0xffffffffffffffff;
        if (va == 0) {
            va = self.findFreeRange(aligned_len);
            if (va == 0) return 0xffffffffffffffff;
        }
        const map_prot = mmu.Prot{
            .writable = (prot_val & 2) != 0,
            .executable = (prot_val & 4) != 0,
            .user = true,
        };
        return if (self.mapAnonymous(va, aligned_len, map_prot, @intCast(flags)) == KERN_SUCCESS) va else 0xffffffffffffffff;
    }

    /// Map a shared memory region into this address space.
    /// `pa` is the physical base of the shared pages, `page_count` is the number of pages.
    pub fn mapShared(self: *Vmm, va: u64, pa: u64, page_count: u64, prot: mmu.Prot, name: []const u8) u32 {
        if (self.region_count >= MAX_REGIONS) return KERN_NO_SPACE;

        // Map each page
        var i: u64 = 0;
        while (i < page_count) : (i += 1) {
            mmu.mapPages(self.ttbr0, va + i * PAGE_SIZE, pa + i * PAGE_SIZE, PAGE_SIZE, prot);
        }

        // Add region with shared flag
        if (self.region_count >= MAX_REGIONS) return KERN_NO_SPACE;
        var region = Vma{
            .start = va,
            .end = va + page_count * PAGE_SIZE,
            .prot = prot,
            .flags = VM_FLAG_SHARED,
        };
        if (name.len < MAX_NAME_LEN) {
            @memcpy(region.shared_name[0..name.len], name);
            region.shared_name_len = @intCast(name.len);
        }
        self.regions[self.region_count] = region;
        self.region_count += 1;

        return KERN_SUCCESS;
    }

    /// Unmap a shared region and release our reference to the shared memory.
    pub fn unmapShared(self: *Vmm, name: []const u8) void {
        var i: usize = 0;
        while (i < self.region_count) {
            const r = &self.regions[i];
            if ((r.flags & VM_FLAG_SHARED) != 0 and r.shared_name_len == name.len and std.mem.eql(u8, r.shared_name[0..r.shared_name_len], name)) {
                // Unmap the pages (but don't free physical - that's handled by shmClose)
                var va = r.start;
                while (va < r.end) : (va += PAGE_SIZE) {
                    unmapPageNoFree(self.ttbr0, va);
                }
                mmu.switchTtbr0(self.ttbr0);

                // Remove region
                if (i < self.region_count - 1) self.regions[i] = self.regions[self.region_count - 1];
                self.region_count -= 1;
                continue;
            }
            i += 1;
        }
    }

    pub fn munmap(self: *Vmm, addr: u64, len: u64) i32 {
        const aligned_len = pageRound(len) orelse return -1;
        const end_overflow = @addWithOverflow(addr, aligned_len);
        if (end_overflow[1] != 0) return -1;
        const end = end_overflow[0];
        var i: usize = 0;
        while (i < self.region_count) {
            const r = &self.regions[i];
            if (addr < r.end and end > r.start) {
                if (addr <= r.start and end >= r.end) {
                    if ((r.flags & VM_FLAG_SHARED) != 0) {
                        // For shared regions, just unmap without freeing physical pages
                        unmapRangeNoFree(self.ttbr0, r.start, r.end - r.start);
                        // Release reference to shared memory
                        shmClose(r.shared_name[0..r.shared_name_len]);
                    } else {
                        unmapRange(self.ttbr0, r.start, r.end - r.start, (r.flags & VM_FLAG_COW) != 0);
                    }
                    if (i < self.region_count - 1) self.regions[i] = self.regions[self.region_count - 1];
                    self.region_count -= 1;
                    continue;
                }
                return -1;
            }
            i += 1;
        }
        return 0;
    }

    pub fn mprotect(self: *Vmm, addr: u64, len: u64, prot_val: i32) i32 {
        const aligned_len = pageRound(len) orelse return -1;
        const end_overflow = @addWithOverflow(addr, aligned_len);
        if (end_overflow[1] != 0) return -1;
        const new_prot = mmu.Prot{
            .writable = (prot_val & 2) != 0,
            .executable = (prot_val & 4) != 0,
            .user = true,
        };
        for (self.regions[0..self.region_count]) |*r| {
            if (addr >= r.start and end_overflow[0] <= r.end) {
                remapRange(self.ttbr0, addr, aligned_len, new_prot);
                r.prot = new_prot;
                return 0;
            }
        }
        return -1;
    }

    pub fn brk(self: *Vmm, addr: u64) u64 {
        if (addr == 0) return self.brk_current;
        const aligned = pageRound(addr) orelse return self.brk_current;
        const cur_aligned = pageRound(self.brk_current) orelse return self.brk_current;
        if (aligned > cur_aligned) {
            const prot = mmu.Prot{ .writable = true, .executable = false, .user = true };
            var va = cur_aligned;
            while (va < aligned) : (va += PAGE_SIZE) {
                const pa = pmm.allocPage();
                mmu.mapPages(self.ttbr0, va, pa, PAGE_SIZE, prot);
            }
            self.addRegion(cur_aligned, aligned, prot, 0);
        } else if (aligned < cur_aligned) {
            unmapRange(self.ttbr0, aligned, cur_aligned - aligned, false);
        }
        self.brk_current = addr;
        return self.brk_current;
    }

    // -----------------------------------------------------------------------
    // COW (Copy-on-Write) support
    // -----------------------------------------------------------------------

    /// Fork this address space: clone all page table entries with COW semantics.
    /// Both parent and child share all pages (refcount incremented).
    /// All writable pages are marked read-only to catch writes (COW fault).
    /// Returns a new Vmm with the cloned page tables.
    pub fn fork(self: *const Vmm) Vmm {
        // Create a new page table (inheriting kernel mappings)
        var child_ttbr0 = mmu.cloneKernelMappings();

        // For each region, clone the pages with COW
        for (self.regions[0..self.region_count]) |r| {
            // Map the region in the child's address space
            var va = r.start;
            while (va < r.end) : (va += PAGE_SIZE) {
                // Get the physical page from parent
                const parent_pa = mmu.getPhysicalAddress(self.ttbr0, va) orelse {
                    va += PAGE_SIZE;
                    continue;
                };

                // Increment refcount (sharing the page)
                _ = pmm.refPage(parent_pa);

                // Map in child with read-only to enable COW
                var cow_prot = r.prot;
                cow_prot.writable = false; // Force read-only for COW

                // Map the same physical page in child's page table
                mmu.mapPages(&child_ttbr0, va, parent_pa, PAGE_SIZE, cow_prot);
            }

            // Also mark parent's pages as read-only for COW
            // (if they were writable)
            if (r.prot.writable and (r.flags & VM_FLAG_SHARED) == 0) {
                var ro_prot = r.prot;
                ro_prot.writable = false;
                remapRange(self.ttbr0, r.start, r.end - r.start, ro_prot);
            }
        }

        // Create child VMM with cloned regions (mark all as COW)
        var child = Vmm{
            .ttbr0 = &child_ttbr0,
            .brk_start = self.brk_start,
            .brk_current = self.brk_current,
            .next_mmap_hint = self.next_mmap_hint,
        };

        // Copy regions, adding COW flag to writable non-shared ones
        for (self.regions[0..self.region_count]) |r| {
            var flags = r.flags;
            if (r.prot.writable and (flags & VM_FLAG_SHARED) == 0) {
                flags |= VM_FLAG_COW;
            }
            child.addRegionWithShared(r.start, r.end, r.prot, flags, r.shared_name[0..r.shared_name_len]);
        }

        return child;
    }

    /// Helper: add region preserving shared name
    fn addRegionWithShared(self: *Vmm, start: u64, end: u64, prot: mmu.Prot, flags: u32, name: []const u8) void {
        if (self.region_count >= MAX_REGIONS) @panic("vmm: too many regions");
        var region = Vma{ .start = start, .end = end, .prot = prot, .flags = flags };
        if (name.len > 0 and name.len < MAX_NAME_LEN) {
            @memcpy(region.shared_name[0..name.len], name);
            region.shared_name_len = @intCast(name.len);
        }
        self.regions[self.region_count] = region;
        self.region_count += 1;
    }

    /// Handle a COW (Copy-on-Write) fault at the given virtual address.
    pub fn handleCowFault(self: *Vmm, fault_va: u64) bool {
        const page_aligned_va = fault_va & ~(PAGE_SIZE - 1);

        for (self.regions[0..self.region_count]) |*r| {
            if (page_aligned_va >= r.start and page_aligned_va < r.end) {
                // Check if this region is COW
                if ((r.flags & VM_FLAG_COW) == 0) return false;

                // Get the physical address of the faulting page
                const old_pa = mmu.getPhysicalAddress(self.ttbr0, page_aligned_va) orelse return false;

                // Split the COW page: allocate new, copy contents, unref old
                const new_pa = pmm.splitCOWPage(old_pa);

                // Remap in this process's page table with write permission
                mmu.mapPages(self.ttbr0, page_aligned_va, new_pa, PAGE_SIZE, r.prot);

                return true;
            }
        }

        return false;
    }

    /// Check if a virtual address belongs to a COW region in this VMM.
    pub fn isCowAddress(self: *const Vmm, va: u64) bool {
        for (self.regions[0..self.region_count]) |r| {
            if (va >= r.start and va < r.end) {
                return (r.flags & VM_FLAG_COW) != 0;
            }
        }
        return false;
    }

    /// Get the region containing a virtual address, if any.
    pub fn getRegion(self: *const Vmm, va: u64) ?Vma {
        for (self.regions[0..self.region_count]) |r| {
            if (va >= r.start and va < r.end) return r;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Page table helpers
// ---------------------------------------------------------------------------

fn unmapRange(table: *mmu.Table, va: u64, len: u64, is_cow: bool) void {
    var off: u64 = 0;
    while (off < len) : (off += PAGE_SIZE) {
        unmapPage(table, va + off, is_cow);
    }
    mmu.switchTtbr0(table);
}

/// Unmap range without freeing physical pages (for shared memory).
fn unmapRangeNoFree(table: *mmu.Table, va: u64, len: u64) void {
    var off: u64 = 0;
    while (off < len) : (off += PAGE_SIZE) {
        unmapPageNoFree(table, va + off);
    }
    mmu.switchTtbr0(table);
}

fn unmapPage(table: *mmu.Table, va: u64, is_cow: bool) void {
    var t = table;
    const shifts = [_]u6{ 39, 30, 21 };
    for (shifts) |shift| {
        const idx = (va >> shift) & 0x1ff;
        const entry = t.entries[idx];
        if (entry & 1 == 0) return;
        t = @ptrFromInt(entry & 0x0000fffffffff000);
    }
    const idx = (va >> 12) & 0x1ff;
    const pa = t.entries[idx] & 0x0000fffffffff000;
    if (pa != 0) {
        if (is_cow) {
            // Use refcount-aware free (may not actually free if shared)
            _ = pmm.unrefPage(pa);
        } else {
            pmm.freePage(pa);
        }
    }
    t.entries[idx] = 0;
}

/// Unmap page without freeing physical (for shared memory).
fn unmapPageNoFree(table: *mmu.Table, va: u64) void {
    var t = table;
    const shifts = [_]u6{ 39, 30, 21 };
    for (shifts) |shift| {
        const idx = (va >> shift) & 0x1ff;
        const entry = t.entries[idx];
        if (entry & 1 == 0) return;
        t = @ptrFromInt(entry & 0x0000fffffffff000);
    }
    const idx = (va >> 12) & 0x1ff;
    t.entries[idx] = 0;
}

fn remapRange(table: *mmu.Table, va: u64, len: u64, prot: mmu.Prot) void {
    var off: u64 = 0;
    while (off < len) : (off += PAGE_SIZE) {
        const page_va = va + off;
        var t = table;
        const shifts = [_]u6{ 39, 30, 21 };
        for (shifts) |shift| {
            const idx = (page_va >> shift) & 0x1ff;
            const entry = t.entries[idx];
            if (entry & 1 == 0) return;
            t = @ptrFromInt(entry & 0x0000fffffffff000);
        }
        const idx = (page_va >> 12) & 0x1ff;
        const pa = t.entries[idx] & 0x0000fffffffff000;
        if (pa != 0) {
            t.entries[idx] = (pa & 0x0000fffffffff000) | (1 << 0) | (1 << 1) | (1 << 10) | (0b11 << 8);
            if (prot.writable) t.entries[idx] |= (0b01 << 6) else t.entries[idx] |= (0b11 << 6);
            if (!prot.executable) t.entries[idx] |= (1 << 54) | (1 << 53);
        }
    }
    mmu.switchTtbr0(table);
}
