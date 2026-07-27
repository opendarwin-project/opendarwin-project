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
    const pa = if (pages == 0) mmu.allocPage() else blk: {
        const p = pmm.allocPagesContig(pages);
        if (p == 0) @panic("readBlobIntoPages: allocPagesContig failed");
        break :blk p;
    };
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
const ExtraMap = struct { va: u64, pa: u64, len: u64, prot: mmu.Prot };

const FossResolverCtx = struct { tables: []const []const macho.Symbol };

fn fossSymbolValue(symbols: []const macho.Symbol, name: []const u8) ?u64 {
    for (symbols) |sym| {
        if (sym.kind != .external) continue;
        if (std.mem.eql(u8, sym.name, name) or
            (sym.name.len == name.len + 1 and sym.name[0] == '_' and std.mem.eql(u8, sym.name[1..], name))) return sym.value;
    }
    return null;
}

fn findFossSymbol(ctx: *const FossResolverCtx, name: []const u8) ?u64 {
    for (ctx.tables) |symbols| {
        if (fossSymbolValue(symbols, name)) |v| return v;
    }
    return null;
}

fn resolveFossSymbol(ctx: ?*anyopaque, ordinal: u8, name: []const u8) ?u64 {
    _ = ordinal;
    const rc: *const FossResolverCtx = @ptrCast(@alignCast(ctx.?));
    if (findFossSymbol(rc, name)) |v| return v;
    uart.print("opendarwin: unresolved FOSS dylib symbol: ");
    uart.print(name);
    uart.print("\n");
    return null;
}

fn printLoadErr(prefix: []const u8, err: anyerror) void {
    uart.print(prefix);
    uart.print(@errorName(err));
    const unresolved = macho.lastUnresolvedSymbol();
    if (unresolved.len != 0) {
        uart.print(" (");
        uart.print(unresolved);
        uart.print(")");
    }
    uart.print("\n");
}

fn installNameQueuedOrLoaded(names: []const []const u8, count: usize, name: []const u8) bool {
    for (names[0..count]) |existing| {
        if (std.mem.eql(u8, existing, name)) return true;
    }
    return false;
}

fn spawnZigSmokeFromFat() bool {
    const max_dylibs = 8;
    var queue_install: [max_dylibs][]const u8 = undefined;
    var queue_path: [max_dylibs][]const u8 = undefined;
    var queue_len: usize = 0;

    uart.print("opendarwin: zig-smoke: reading MAIN LC_LOAD_DYLIB\n");
    var main_deps: [max_dylibs][]const u8 = undefined;
    const main_dep_count = macho.listNeededDylibs("MAIN", &main_deps) catch |err| {
        printLoadErr("opendarwin: MAIN dylib list failed: ", err);
        return false;
    };
    if (main_dep_count == 0) {
        uart.print("opendarwin: MAIN has no LC_LOAD_DYLIB entries\n");
        return false;
    }
    for (main_deps[0..main_dep_count]) |install| {
        if (installNameQueuedOrLoaded(queue_install[0..], queue_len, install)) continue;
        if (queue_len >= max_dylibs) {
            uart.print("opendarwin: too many MAIN dylib deps\n");
            return false;
        }
        queue_install[queue_len] = install;
        queue_path[queue_len] = macho.rootfsPathForInstallName(install);
        queue_len += 1;
    }

    var all_regions: [32]mmu.Region = undefined;
    var all_regions_used: usize = 0;
    var loaded_install: [max_dylibs][]const u8 = undefined;
    var loaded_slide: [max_dylibs]u64 = undefined;
    var loaded_region_start: [max_dylibs]usize = undefined;
    var loaded_region_count: [max_dylibs]usize = undefined;
    var symbol_tables: [max_dylibs][]const macho.Symbol = undefined;
    var pending_binds: [max_dylibs]macho.PendingBind = undefined;
    var loaded_count: usize = 0;

    var qi: usize = 0;
    while (qi < queue_len) : (qi += 1) {
        const install = queue_install[qi];
        const path = queue_path[qi];
        if (installNameQueuedOrLoaded(loaded_install[0..], loaded_count, install)) continue;

        uart.print("opendarwin: zig-smoke: loading ");
        uart.print(path);
        uart.print("\n");

        var dylib_regions: [8]mmu.Region = undefined;
        var dylib_regions_used: usize = 0;
        const dylib_result = macho.loadPath(path, &dylib_regions, &dylib_regions_used, .{ .defer_binding = true }) catch |err| {
            printLoadErr("opendarwin: FOSS dylib load failed: ", err);
            return false;
        };
        if (all_regions_used + dylib_regions_used > all_regions.len or loaded_count >= max_dylibs) {
            uart.print("opendarwin: zig-smoke: too many dylib regions\n");
            return false;
        }

        loaded_install[loaded_count] = install;
        loaded_slide[loaded_count] = dylib_result.slide;
        loaded_region_start[loaded_count] = all_regions_used;
        loaded_region_count[loaded_count] = dylib_regions_used;
        symbol_tables[loaded_count] = dylib_result.external_symbols;
        pending_binds[loaded_count] = dylib_result.pending_bind orelse {
            uart.print("opendarwin: zig-smoke: missing pending_bind\n");
            return false;
        };
        for (dylib_regions[0..dylib_regions_used]) |r| {
            all_regions[all_regions_used] = r;
            all_regions_used += 1;
        }
        loaded_count += 1;

        var nested: [max_dylibs][]const u8 = undefined;
        const nested_count = macho.listNeededDylibs(path, &nested) catch |err| {
            printLoadErr("opendarwin: nested dylib list failed: ", err);
            return false;
        };
        for (nested[0..nested_count]) |dep| {
            if (std.mem.eql(u8, dep, install)) continue;
            if (installNameQueuedOrLoaded(loaded_install[0..], loaded_count, dep)) continue;
            if (installNameQueuedOrLoaded(queue_install[0..], queue_len, dep)) continue;
            if (queue_len >= max_dylibs) {
                uart.print("opendarwin: too many nested dylib deps\n");
                return false;
            }
            queue_install[queue_len] = dep;
            queue_path[queue_len] = macho.rootfsPathForInstallName(dep);
            queue_len += 1;
        }
    }

    if (loaded_count == 0) {
        uart.print("opendarwin: zig-smoke: no dylibs loaded\n");
        return false;
    }

    var resolver_ctx = FossResolverCtx{ .tables = symbol_tables[0..loaded_count] };

    for (0..loaded_count) |di| {
        macho.applyPendingBind(pending_binds[di], resolveFossSymbol, &resolver_ctx) catch |err| {
            uart.print("opendarwin: bind failed for ");
            uart.print(loaded_install[di]);
            uart.print(": ");
            printLoadErr("", err);
            return false;
        };
    }

    const return_entry = findFossSymbol(&resolver_ctx, "exit") orelse {
        uart.print("opendarwin: FOSS libSystem lacks exit\n");
        return false;
    };

    uart.print("opendarwin: zig-smoke: loading MAIN\n");
    var main_regions: [8]mmu.Region = undefined;
    var main_regions_used: usize = 0;
    const main_result = macho.loadPath("MAIN", &main_regions, &main_regions_used, .{
        .resolver = resolveFossSymbol,
        .resolver_ctx = &resolver_ctx,
        .user_accessible = true,
        // PIE linked at 0x1_0000_0000: run at preferred VAs (see LoadOptions).
        .link_at_preferred_va = true,
    }) catch |err| {
        printLoadErr("opendarwin: zig-smoke load failed: ", err);
        return false;
    };
    uart.print("opendarwin: loaded ");
    uart.printHex(@as(u64, @intCast(loaded_count)));
    uart.print(" dylibs; MAIN slide=");
    uart.printHex(main_result.slide);
    uart.print("\n");
    uart.print("opendarwin: zig-smoke: spawning task\n");

    // The Zig Mach-O requests a 16 MiB stack. Stacks are fixed-size until
    // demand-backed stack growth is implemented, so provide the full request.
    // Contiguous PMM pages — freelist order is not bump-contiguous.
    const stack_pages = 4096; // 16 MiB
    const stack_len = stack_pages * mmu.PAGE_SIZE;
    const stack_pa = pmm.allocPagesContig(stack_pages);
    if (stack_pa == 0) @panic("zig-smoke: stack allocPagesContig failed");
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
    for (0..loaded_count) |di| {
        const slide = loaded_slide[di];
        const start = loaded_region_start[di];
        const count = loaded_region_count[di];
        for (all_regions[start .. start + count]) |r| {
            mmu.mapPages(table, r.pa, r.pa, r.len, r.prot);
            mmu.mapPages(table, r.pa -% slide, r.pa, r.len, r.prot);
        }
    }
    for (main_regions[0..main_regions_used]) |r| {
        mmu.mapPages(table, r.pa -% main_result.slide, r.pa, r.len, r.prot);
    }

    uart.print("opendarwin: zig-smoke + FOSS dylibs loaded and spawned\n");
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

    var rootfs_mounted: bool = false;
    if (dtb_found) |found| {
        if (virtio_blk.init(found.virtio_blk_matches[0..found.virtio_blk_count])) {
            uart.print("opendarwin: virtio-blk device ready\n");
            if (fat.mount(virtio_blk.block())) {
                uart.print("opendarwin: rootfs mounted (VFS/FAT)\n");
                rootfs_mounted = true;
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
        mmu.setPageAllocator(pmm.allocPage);
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

    if (rootfs_mounted == true) {
        user_spawned = spawnZigSmokeFromFat();
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
