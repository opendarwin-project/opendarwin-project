const std = @import("std");
const uart = @import("drivers/uart.zig");
const exceptions = @import("arch/aarch64/exceptions.zig");
const mmu = @import("mm/mmu.zig");
const pmm = @import("mm/pmm.zig");
const slab = @import("mm/slab.zig");
const ipc = @import("ipc/init.zig");
const macho = @import("loader/macho.zig");
const gic = @import("drivers/gic.zig");
const virtio_blk = @import("drivers/virtio_blk.zig");
const virtio_gpu = @import("drivers/virtio_gpu.zig");
const timer = @import("drivers/timer.zig");
const sched = @import("proc/sched.zig");
const smp = @import("smp.zig");
const pac = @import("arch/aarch64/pac.zig");
const devicetree = @import("devicetree.zig");
const fat = @import("fs/fat.zig");
const shared_cache = @import("loader/shared_cache.zig");
const dyld = @import("loader/dyld.zig");
const rootfs_manifest = @import("loader/rootfs_manifest.zig");
const kext_loader = @import("kext/loader.zig");
const kext_registry = @import("kext/registry.zig");
const iokit_root = @import("iokit/root.zig");
const iokit_compat = @import("iokit/compat.zig");

extern var __userpages_end: u8;
var static_smoke_scratch: [256 * 1024]u8 align(16) = undefined;

/// Loads a static arm64 Mach-O (see loader/testdata/*.S for how these are
/// built) and registers it with the scheduler as a new task with its own
/// freshly allocated user stack.
fn spawnFromMachO(image: []const u8) void {
    var regions: [4]mmu.Region = undefined;
    var regions_used: usize = 0;
    const result = macho.load(image, &regions, &regions_used, null, null) catch {
        uart.print("opendarwin: mach-o load failed\n");
        while (true) asm volatile ("wfe");
    };

    const stack_pa = mmu.allocPage();
    var task_regions: [5]mmu.Region = undefined;
    for (regions[0..regions_used], 0..) |r, idx| task_regions[idx] = r;
    task_regions[regions_used] = .{
        .pa = stack_pa,
        .len = mmu.PAGE_SIZE,
        .prot = .{ .writable = true, .executable = false, .user = true },
    };

    _ = sched.spawn(task_regions[0 .. regions_used + 1], result.entry, stack_pa + mmu.PAGE_SIZE);
}

fn pageAlign(n: u64) u64 {
    return (n + mmu.PAGE_SIZE - 1) & ~@as(u64, mmu.PAGE_SIZE - 1);
}

fn blobNameSlice(name: *const [12]u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, name, 0) orelse name.len;
    return name[0..end];
}

/// Reads a FAT rootfs blob into `pages = ceil(len/PAGE_SIZE)` freshly
/// allocated contiguous physical pages (see mm/pmm.zig's
/// `allocPagesContig` doc comment on why contiguity is safe to assume at
/// this point in boot). Returns the backing physical address and the
/// page-rounded total length (the mapping mmu.mapPages needs), not just
/// the logical blob length.
fn readBlobIntoPages(name: []const u8, len: u32) struct { pa: u64, mapped_len: u64 } {
    const mapped_len = pageAlign(len);
    const pages = mapped_len / mmu.PAGE_SIZE;
    const pa = if (pages == 0) mmu.allocPage() else pmm.allocPagesContig(pages);
    const buf: [*]u8 = @ptrFromInt(pa);
    _ = fat.readFile(name, buf[0..len]) orelse {
        uart.print("opendarwin: rootfs: failed to read blob\n");
        while (true) asm volatile ("wfe");
    };
    return .{ .pa = pa, .mapped_len = @max(mapped_len, mmu.PAGE_SIZE) };
}

const LoadedDylib = struct {
    mach_header_va: u64,
    trie: []const u8,
};

const ResolverCtx = struct {
    dylibs: []const LoadedDylib,
};

/// The search order for *any* bind ordinal is precomputed host-side (see
/// tools/prepare_shared_cache.zig and loader/dyld.zig's module doc comment
/// on why that's an honest shortcut, not a hack) - so resolution here
/// ignores `ordinal` entirely and just tries every mapped dylib's real
/// export trie in the order the manifest listed them.
fn resolveSymbol(ctx: ?*anyopaque, ordinal: u8, name: []const u8) ?u64 {
    _ = ordinal;
    const rc: *const ResolverCtx = @ptrCast(@alignCast(ctx.?));
    for (rc.dylibs) |d| {
        if (shared_cache.lookupExport(d.trie, name)) |off| return d.mach_header_va + off;
    }
    return null;
}

const MAX_MAPPED_SEGMENTS = 32;
const MAX_FOSS_DYLIB_SYMBOLS = 256;
const MAX_FOSS_BLOB = 2 * 1024 * 1024;
const ExtraMap = struct { va: u64, pa: u64, len: u64, prot: mmu.Prot };
const FossResolverCtx = struct { symbols: []const macho.Symbol };

fn resolveFossSymbol(ctx: ?*anyopaque, ordinal: u8, name: []const u8) ?u64 {
    _ = ordinal;
    const rc: *const FossResolverCtx = @ptrCast(@alignCast(ctx.?));
    for (rc.symbols) |sym| {
        if (sym.kind != .external) continue;
        if (std.mem.eql(u8, sym.name, name) or
            (sym.name.len == name.len + 1 and sym.name[0] == '_' and std.mem.eql(u8, sym.name[1..], name))) return sym.value;
    }
    uart.print("opendarwin: unresolved FOSS dylib symbol: ");
    uart.print(name);
    uart.print("\n");
    return null;
}

fn readFatFileIntoPages(name: []const u8, max_len: u64) ?[]const u8 {
    const mapped_len = pageAlign(max_len);
    const pages = mapped_len / mmu.PAGE_SIZE;
    const pa = pmm.allocPagesContig(pages);
    const buf: [*]u8 = @ptrFromInt(pa);
    const n = fat.readFile(name, buf[0..max_len]) orelse return null;
    return buf[0..n];
}

fn spawnZigSmokeFromFat() bool {
    uart.print("opendarwin: zig-smoke: reading libSystem\n");
    const dylib_bytes = readFatFileIntoPages("usr/lib/libSystem.B.dylib", MAX_FOSS_BLOB) orelse return false;
    uart.print("opendarwin: zig-smoke: reading MAIN\n");
    const main_bytes = readFatFileIntoPages("MAIN", MAX_FOSS_BLOB) orelse return false;
    uart.print("opendarwin: zig-smoke: loading libSystem\n");

    var dylib_regions: [8]mmu.Region = undefined;
    var dylib_regions_used: usize = 0;
    const dylib_result = macho.load(dylib_bytes, &dylib_regions, &dylib_regions_used, null, null) catch |err| {
        uart.print("opendarwin: FOSS libSystem load failed: ");
        uart.print(@errorName(err));
        const unresolved = macho.lastUnresolvedSymbol();
        if (unresolved.len != 0) {
            uart.print(" (");
            uart.print(unresolved);
            uart.print(")");
        }
        uart.print("\n");
        return false;
    };
    uart.print("opendarwin: zig-smoke: loading MAIN\n");

    var symbol_storage: [MAX_FOSS_DYLIB_SYMBOLS]macho.Symbol = undefined;
    const symbol_count = @min(dylib_result.external_symbols.len, symbol_storage.len);
    for (dylib_result.external_symbols[0..symbol_count], 0..) |sym, i| symbol_storage[i] = sym;
    var resolver_ctx = FossResolverCtx{ .symbols = symbol_storage[0..symbol_count] };
    const return_entry = resolveFossSymbol(&resolver_ctx, 0, "opendarwin_user_return") orelse {
        uart.print("opendarwin: FOSS libSystem lacks return trampoline\n");
        return false;
    };

    var main_regions: [8]mmu.Region = undefined;
    var main_regions_used: usize = 0;
    const main_result = macho.load(main_bytes, &main_regions, &main_regions_used, resolveFossSymbol, &resolver_ctx) catch |err| {
        uart.print("opendarwin: zig-smoke load failed: ");
        uart.print(@errorName(err));
        const unresolved = macho.lastUnresolvedSymbol();
        if (unresolved.len != 0) {
            uart.print(" (");
            uart.print(unresolved);
            uart.print(")");
        }
        uart.print("\n");
        return false;
    };
    uart.print("opendarwin: libSystem slide=");
    uart.printHex(dylib_result.slide);
    uart.print(" MAIN slide=");
    uart.printHex(main_result.slide);
    uart.print("\n");
    uart.print("opendarwin: zig-smoke: spawning task\n");

    // The Zig Mach-O requests a 16 MiB stack. Stacks are fixed-size until
    // demand-backed stack growth is implemented, so provide the full request.
    const stack_pages = 4096; // 16 MiB
    const stack_len = stack_pages * mmu.PAGE_SIZE;
    const stack_pa = mmu.allocPage();
    var extra_stack_page: usize = 1;
    while (extra_stack_page < stack_pages) : (extra_stack_page += 1) _ = mmu.allocPage();
    var task_regions: [9]mmu.Region = undefined;
    if (main_regions_used + 1 > task_regions.len) {
        uart.print("opendarwin: zig-smoke: too many main regions\n");
        return false;
    }
    for (main_regions[0..main_regions_used], 0..) |r, idx| task_regions[idx] = r;
    task_regions[main_regions_used] = .{
        .pa = stack_pa,
        .len = stack_len,
        .prot = .{ .writable = true, .executable = false, .user = true },
    };

    const idx = sched.spawn(task_regions[0 .. main_regions_used + 1], main_result.entry, stack_pa + stack_len);
    sched.setPacEnforcement(idx, false);
    // The Zig-generated LC_MAIN entry is C main(argc, argv, envp), rather
    // than a raw stack-entry crt1 routine.  Give it properly terminated
    // argv and envp vectors in the mapped initial stack page.
    const startup: [*]u64 = @ptrFromInt(stack_pa);
    const argv0 = stack_pa + 32;
    startup[0] = argv0; // argv[0]
    startup[1] = 0; // argv terminator
    startup[2] = 0; // envp terminator
    const argv0_bytes: [*]u8 = @ptrFromInt(argv0);
    @memcpy(argv0_bytes[0..10], "zig-smoke\x00");
    sched.setInitialRegister(idx, 0, 1);
    sched.setInitialRegister(idx, 1, stack_pa);
    sched.setInitialRegister(idx, 2, stack_pa + 16);
    sched.setInitialRegister(idx, 3, stack_pa + 16);
    sched.setInitialRegister(idx, 30, return_entry);
    const table = sched.taskTable(idx);
    for (dylib_regions[0..dylib_regions_used]) |r| {
        mmu.mapPages(table, r.pa, r.pa, r.len, r.prot);
        mmu.mapPages(table, r.pa -% dylib_result.slide, r.pa, r.len, r.prot);
    }
    for (main_regions[0..main_regions_used]) |r| {
        mmu.mapPages(table, r.pa -% main_result.slide, r.pa, r.len, r.prot);
    }

    uart.print("opendarwin: zig-smoke + FOSS libSystem loaded and spawned\n");
    return true;
}

/// Loads a dynamically-linked binary (e.g. /bin/sh) plus the sparse real
/// shared-cache dylib slices it needs off the FAT rootfs - see
/// loader/{shared_cache,dyld,rootfs_manifest}.zig and
/// tools/prepare_shared_cache.zig for the full pipeline this drives.
fn spawnDynamicFromFat() void {
    var manifest_buf: [@sizeOf(rootfs_manifest.Manifest)]u8 align(8) = undefined;
    const n = fat.readFile("MANIFEST", &manifest_buf) orelse {
        uart.print("opendarwin: no rootfs manifest found\n");
        return;
    };
    if (n < @sizeOf(rootfs_manifest.Manifest)) {
        uart.print("opendarwin: rootfs manifest truncated\n");
        return;
    }
    const manifest: *const rootfs_manifest.Manifest = @ptrCast(&manifest_buf);
    if (!std.mem.eql(u8, &manifest.magic, &rootfs_manifest.MAGIC)) {
        uart.print("opendarwin: bad rootfs manifest magic\n");
        return;
    }
    var loaded: [rootfs_manifest.MAX_DYLIBS]LoadedDylib = undefined;
    var extra_maps: [MAX_MAPPED_SEGMENTS]ExtraMap = undefined;
    var extra_count: usize = 0;

    for (manifest.dylibs[0..manifest.dylib_count], 0..) |dylib, dylib_idx| {
        for (dylib.segments[0..dylib.segment_count], 0..) |seg, seg_idx| {
            const blob = readBlobIntoPages(blobNameSlice(&seg.blob), seg.len);
            const data: [*]u8 = @ptrFromInt(blob.pa);

            if (seg.slide_len > 0) {
                const slide = readBlobIntoPages(blobNameSlice(&seg.slide_blob), seg.slide_len);
                const slide_bytes: [*]const u8 = @ptrFromInt(slide.pa);
                shared_cache.applySlide(data[0..seg.len], seg.va, seg.slide_mapping_va, manifest.shared_region_start, slide_bytes[0..seg.slide_len]);
            }

            if (extra_count >= MAX_MAPPED_SEGMENTS) @panic("kmain: too many shared-cache segments");
            // First segment of each dylib is always __TEXT (see
            // tools/prepare_shared_cache.zig - it walks LC_SEGMENT_64 in the
            // image's own declared order, and __TEXT is always first).
            const is_text = seg_idx == 0;
            extra_maps[extra_count] = .{
                .va = seg.va,
                .pa = blob.pa,
                .len = blob.mapped_len,
                .prot = .{ .writable = !is_text, .executable = is_text, .user = true },
            };
            extra_count += 1;
        }

        var trie: []const u8 = &.{};
        if (dylib.trie_len > 0) {
            const blob = readBlobIntoPages(blobNameSlice(&dylib.trie_blob), dylib.trie_len);
            const data: [*]const u8 = @ptrFromInt(blob.pa);
            trie = data[0..dylib.trie_len];
        }
        loaded[dylib_idx] = .{ .mach_header_va = dylib.mach_header_va, .trie = trie };
    }

    const main_blob = readBlobIntoPages(blobNameSlice(&manifest.main_blob), manifest.main_len);
    const main_data: [*]const u8 = @ptrFromInt(main_blob.pa);
    const main_bytes = main_data[0..manifest.main_len];

    var resolver_ctx = ResolverCtx{ .dylibs = loaded[0..manifest.dylib_count] };

    var regions: [4]mmu.Region = undefined;
    var regions_used: usize = 0;
    const result = macho.load(main_bytes, &regions, &regions_used, resolveSymbol, &resolver_ctx) catch |err| {
        uart.print("opendarwin: dynamic mach-o load failed\n");
        uart.print(@errorName(err));
        uart.print("\n");
        return;
    };

    const stack_pa = mmu.allocPage();
    var task_regions: [5]mmu.Region = undefined;
    for (regions[0..regions_used], 0..) |r, idx| task_regions[idx] = r;
    task_regions[regions_used] = .{
        .pa = stack_pa,
        .len = mmu.PAGE_SIZE,
        .prot = .{ .writable = true, .executable = false, .user = true },
    };

    const idx = sched.spawn(task_regions[0 .. regions_used + 1], result.entry, stack_pa + mmu.PAGE_SIZE);
    sched.setPacEnforcement(idx, false);
    const table = sched.taskTable(idx);
    for (extra_maps[0..extra_count]) |m| {
        mmu.mapPages(table, m.va, m.pa, m.len, m.prot);
    }

    uart.print("opendarwin: dynamic binary loaded and spawned\n");
}

fn spawnStaticSmokeFromFat(name: []const u8) bool {
    const n = fat.readFile(name, &static_smoke_scratch) orelse return false;
    spawnFromMachO(static_smoke_scratch[0..n]);
    uart.print("opendarwin: static smoke loaded: ");
    uart.print(name);
    uart.print("\n");
    return true;
}

export fn kmain() callconv(.c) noreturn {
    // MMU is enabled first, before anything else, deliberately. While the
    // stage-1 MMU is disabled the architecture forces every access to be
    // treated as strongly-ordered Device memory, which unconditionally
    // faults on any unaligned multi-byte load/store - and the compiler is
    // free to lower ordinary struct copies (e.g. a driver's bind() return
    // value landing in a global) to wide/vector stores whenever it likes.
    // Chasing each occurrence individually isn't tenable; getting to Normal
    // memory semantics before running any "normal" code is.
    mmu.enable(&mmu.kernel_regions);

    // Bootstrap console at QEMU virt's well-known fixed PL011 address:
    // there's no way to report DTB-discovery progress/errors without some
    // UART already working (see devicetree.zig's module doc comment).
    uart.init(uart.BOOTSTRAP_BASE);
    uart.print("opendarwin: boot ok\n");
    uart.print("opendarwin: MMU enabled\n");

    exceptions.init();
    uart.print("opendarwin: exception vectors installed\n");

    // Real device discovery via conduit's Registry + dtree backend, over
    // the DTB QEMU handed us at boot - replaces the bootstrap UART/GIC
    // addresses with genuinely discovered ones where possible.
    const dtb_found = devicetree.discover();
    if (dtb_found) |found| {
        if (found.uart_base) |base| uart.init(base);
        if (found.gic_dist_base != null and found.gic_cpu_base != null) {
            gic.setBases(found.gic_dist_base.?, found.gic_cpu_base.?);
        }
        uart.print("opendarwin: devicetree discovery ok\n");
    } else {
        uart.print("opendarwin: devicetree discovery unavailable, using bootstrap addresses\n");
    }

    var rootfs_mounted: u8 = 0;
    if (dtb_found) |found| {
        if (virtio_blk.init(found.virtio_blk_matches[0..found.virtio_blk_count])) {
            uart.print("opendarwin: virtio-blk device ready\n");
            if (fat.mount(virtio_blk.block())) {
                uart.print("opendarwin: rootfs mounted (FAT)\n");
                rootfs_mounted = 1;
            } else {
                uart.print("opendarwin: rootfs mount failed\n");
            }
        } else {
            uart.print("opendarwin: no virtio-blk device found\n");
        }

        // GPU candidates are published into the IOKit registry after rootfs
        // is up; VirtioGpuFramebuffer binds them (no DISPLAY kext).
        virtio_gpu.stashCandidates(
            found.virtio_gpu_matches[0..found.virtio_gpu_count],
            found.pci_ecam_base,
        );
        if (found.virtio_gpu_count > 0) {
            uart.print("opendarwin: virtio-gpu candidates stashed for IOKit\n");
        } else {
            uart.print("opendarwin: no virtio-gpu candidates\n");
        }
    }
    gic.init();
    gic.enable(timer.IRQ);
    timer.init(5); // 5ms tick - short enough to preempt mid busy-wait
    uart.print("opendarwin: timer + GIC ready\n");

    // --- Physical Memory Manager ---
    // Determine free RAM from DTB or fallback, subtract kernel reserved range.
    const mem_base = if (dtb_found) |f| f.memory_base else null;
    const mem_size = if (dtb_found) |f| f.memory_size else null;
    const ram_base = mem_base orelse 0x4000_0000;
    const ram_size = mem_size orelse 0x4800_0000 - ram_base; // 128MB QEMU virt default

    const kernel_reserved_end: u64 = @intFromPtr(&__userpages_end);
    const kernel_reserved_base: u64 = ram_base;
    const kernel_reserved_size = kernel_reserved_end - kernel_reserved_base;

    if (ram_size > kernel_reserved_size) {
        const free_base = kernel_reserved_end;
        const free_size = (ram_base + ram_size) - kernel_reserved_end;
        pmm.init(&.{.{ .base = free_base, .size = free_size }});
        uart.print("opendarwin: PMM initialized (");
        var mb = free_size / 0x100000;
        var mb_buf: [12]u8 = undefined;
        var mb_i: usize = mb_buf.len;
        while (mb > 0) {
            mb_i -= 1;
            mb_buf[mb_i] = '0' + @as(u8, @intCast(mb % 10));
            mb /= 10;
        }
        if (mb_i == mb_buf.len) {
            mb_buf[mb_buf.len - 1] = '0';
            mb_i = mb_buf.len - 1;
        }
        uart.print(mb_buf[mb_i..]);
        uart.print(" MB free)\n");
    } else {
        uart.print("opendarwin: PMM: no free memory available\n");
    }
    var user_spawned = false;

    slab.init();
    uart.print("opendarwin: slab allocator ready\n");

    ipc.init();
    uart.print("opendarwin: IPC subsystem initialized\n");

    // PAC groundwork: SCTLR_EL1 is per-core, so every core enables this for
    // itself (smp.zig's secondaryMain does the same for secondaries).
    if (pac.available()) {
        pac.enable();
        uart.print("opendarwin: PAC available and enabled (core 0)\n");
    } else {
        uart.print("opendarwin: PAC not available on this CPU\n");
    }

    // Display bind via IOKit (VirtioGpuFramebuffer on IOPCIDevice nubs).
    // No longer depends on a FAT-loaded DISPLAY kext.
    iokit_compat.linkForce();
    iokit_root.init();
    const ecam = virtio_gpu.stashedEcam();
    _ = iokit_root.publishDisplayCandidates(virtio_gpu.stashedCandidates(), ecam);
    _ = iokit_root.matchAndStartDrivers();
    if (virtio_gpu.stashedCandidates().len > 0 and !virtio_gpu.ready()) {
        uart.print("opendarwin: no virtio-gpu device found\n");
    }

    if (rootfs_mounted == 1) {
        // Optional block smoke kext (does not own storage).
        if (kext_loader.loadBundleFromFat("KEXTSMOK") or kext_loader.loadFromFat("KEXTSMOK")) {
            if (virtio_blk.matchedDevice()) |m| _ = kext_registry.publishProviderInfo(2, m, 0);
        }
        user_spawned = spawnZigSmokeFromFat();
        if (!user_spawned and !spawnStaticSmokeFromFat("MACHSMOK")) spawnDynamicFromFat();
    }

    // Unmask IRQ at EL1 now that the GIC/timer/scheduler are all ready;
    // PSTATE.I has been set since the EL2->EL1 drop in start.S; nothing
    // before this point should have been relying on interrupts anyway.
    asm volatile ("msr daifclr, #2");

    uart.print("opendarwin: waking secondary cores...\n");
    smp.wakeSecondaries();

    uart.print("opendarwin: starting scheduler on core 0...\n");
    sched.runCore(0);
}
