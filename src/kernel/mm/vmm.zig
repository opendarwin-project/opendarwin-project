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

const Vma = struct {
    start: u64,
    end: u64,
    prot: mmu.Prot,
    flags: u32,
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
                    unmapRange(self.ttbr0, r.start, r.end - r.start);
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
            unmapRange(self.ttbr0, aligned, cur_aligned - aligned);
        }
        self.brk_current = addr;
        return self.brk_current;
    }
};

fn unmapRange(table: *mmu.Table, va: u64, len: u64) void {
    var off: u64 = 0;
    while (off < len) : (off += PAGE_SIZE) {
        unmapPage(table, va + off);
    }
    mmu.switchTtbr0(table);
}

fn unmapPage(table: *mmu.Table, va: u64) void {
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
    if (pa != 0) pmm.freePage(pa);
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
