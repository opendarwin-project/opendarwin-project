const mmu = @import("mmu.zig");
const pmm = @import("pmm.zig");

const PAGE_SIZE = mmu.PAGE_SIZE;
const MAX_REGIONS = 32;
const MMAP_BASE: u64 = 0x1_0000_0000;

const Vma = struct {
    start: u64,
    end: u64,
    prot: mmu.Prot,
    flags: u32,
};

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

    fn findFreeRange(self: *Vmm, len: u64) u64 {
        const aligned_len = (len + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
        var candidate = self.next_mmap_hint;
        for (0..1024) |_| {
            var ok = true;
            for (self.regions[0..self.region_count]) |r| {
                if (candidate < r.end and candidate + aligned_len > r.start) {
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

    pub fn mmap(self: *Vmm, hint: u64, len: u64, prot_val: i32, flags: i32) u64 {
        const aligned_len = (len + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
        var va = if (hint != 0 and hint % PAGE_SIZE == 0) hint else 0;
        if (va == 0) {
            va = self.findFreeRange(aligned_len);
            if (va == 0) return 0xffffffffffffffff;
        }
        const map_prot = mmu.Prot{
            .writable = (prot_val & 2) != 0,
            .executable = (prot_val & 4) != 0,
            .user = true,
        };
        var mapped: u64 = 0;
        while (mapped < aligned_len) {
            const pa = pmm.allocPage();
            mmu.mapPages(self.ttbr0, va + mapped, pa, PAGE_SIZE, map_prot);
            mapped += PAGE_SIZE;
        }
        self.addRegion(va, va + aligned_len, map_prot, @intCast(flags));
        return va;
    }

    pub fn munmap(self: *Vmm, addr: u64, len: u64) i32 {
        const end = addr + ((len + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1));
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
        const aligned_len = (len + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
        const new_prot = mmu.Prot{
            .writable = (prot_val & 2) != 0,
            .executable = (prot_val & 4) != 0,
            .user = true,
        };
        for (self.regions[0..self.region_count]) |*r| {
            if (addr >= r.start and addr + aligned_len <= r.end) {
                remapRange(self.ttbr0, addr, aligned_len, new_prot);
                r.prot = new_prot;
                return 0;
            }
        }
        return -1;
    }

    pub fn brk(self: *Vmm, addr: u64) u64 {
        if (addr == 0) return self.brk_current;
        const aligned = (addr + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
        const cur_aligned = (self.brk_current + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
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
