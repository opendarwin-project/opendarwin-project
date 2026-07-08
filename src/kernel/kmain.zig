const uart = @import("drivers/uart.zig");
const exceptions = @import("arch/aarch64/exceptions.zig");
const mmu = @import("mm/mmu.zig");
const macho = @import("loader/macho.zig");
const gic = @import("drivers/gic.zig");
const timer = @import("drivers/timer.zig");
const sched = @import("proc/sched.zig");

const loop_a_macho = @embedFile("loader/testdata/loop_a");
const loop_b_macho = @embedFile("loader/testdata/loop_b");

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

    uart.init();
    uart.print("opendarwin: boot ok\n");
    uart.print("opendarwin: MMU enabled\n");

    exceptions.init();
    uart.print("opendarwin: exception vectors installed\n");

    gic.init();
    gic.enable(timer.IRQ);
    timer.init(5); // 5ms tick - short enough to preempt mid busy-wait
    uart.print("opendarwin: timer + GIC ready\n");

    spawnFromMachO(loop_a_macho);
    spawnFromMachO(loop_b_macho);

    // Unmask IRQ at EL1 now that the GIC/timer/scheduler are all ready;
    // PSTATE.I has been set since the EL2->EL1 drop in start.S; nothing
    // before this point should have been relying on interrupts anyway.
    asm volatile ("msr daifclr, #2");

    uart.print("opendarwin: starting scheduler...\n");
    sched.start();
}
