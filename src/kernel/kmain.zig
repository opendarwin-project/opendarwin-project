const uart = @import("drivers/uart.zig");
const exceptions = @import("arch/aarch64/exceptions.zig");
const mmu = @import("mm/mmu.zig");
const pmm = @import("mm/pmm.zig");
const slab = @import("mm/slab.zig");
const ipc = @import("ipc/init.zig");
const macho = @import("loader/macho.zig");
const gic = @import("drivers/gic.zig");
const virtio_blk = @import("drivers/virtio_blk.zig");
const timer = @import("drivers/timer.zig");
const sched = @import("proc/sched.zig");
const smp = @import("smp.zig");
const pac = @import("arch/aarch64/pac.zig");
const devicetree = @import("devicetree.zig");
const fat = @import("fs/fat.zig");

const loop_a_macho = @embedFile("loader/testdata/loop_a");
const loop_b_macho = @embedFile("loader/testdata/loop_b");
const pac_test_macho = @embedFile("loader/testdata/pac_test");
const hello_c_macho = @embedFile("loader/testdata/hello_c");
const pie_test_macho = @embedFile("loader/testdata/pie_test");

extern var __userpages_end: u8;

/// Loads a static arm64 Mach-O (see loader/testdata/*.S for how these are
/// built) and registers it with the scheduler as a new task with its own
/// freshly allocated user stack.
fn spawnFromMachO(image: []const u8) void {
    var regions: [4]mmu.Region = undefined;
    var regions_used: usize = 0;
    const result = macho.load(image, &regions, &regions_used) catch {
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

    sched.spawn(task_regions[0 .. regions_used + 1], result.entry, stack_pa + mmu.PAGE_SIZE);
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

    if (dtb_found) |found| {
        if (virtio_blk.init(found.virtio_blk_bases[0..found.virtio_blk_count])) {
            uart.print("opendarwin: virtio-blk device ready\n");
            if (fat.mount(virtio_blk.block())) {
                uart.print("opendarwin: rootfs mounted (FAT)\n");
            } else {
                uart.print("opendarwin: rootfs mount failed\n");
            }
        } else {
            uart.print("opendarwin: no virtio-blk device found\n");
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

    // Spawned before any secondary core is released: sched.spawn()'s
    // static core-assignment (task N -> core N) needs to finish while only
    // the primary is running, since it's otherwise unsynchronized (see
    // sched.zig's module doc comment).
    spawnFromMachO(hello_c_macho);
    spawnFromMachO(pie_test_macho);
    spawnFromMachO(loop_a_macho);
    spawnFromMachO(loop_b_macho);
    spawnFromMachO(pac_test_macho);

    // Unmask IRQ at EL1 now that the GIC/timer/scheduler are all ready;
    // PSTATE.I has been set since the EL2->EL1 drop in start.S; nothing
    // before this point should have been relying on interrupts anyway.
    asm volatile ("msr daifclr, #2");

    uart.print("opendarwin: waking secondary cores...\n");
    smp.wakeSecondaries();

    uart.print("opendarwin: starting scheduler on core 0...\n");
    sched.runCore(0);
}
