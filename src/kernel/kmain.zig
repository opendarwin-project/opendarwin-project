const uart = @import("drivers/uart.zig");
const exceptions = @import("arch/aarch64/exceptions.zig");
const mmu = @import("mm/mmu.zig");
const macho = @import("loader/macho.zig");
const Task = @import("proc/task.zig").Task;
const thread = @import("proc/thread.zig");

const hello_macho = @embedFile("loader/testdata/hello");

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

    // Milestone 1's deliverable: load a real static arm64 Mach-O (built
    // from loader/testdata/hello.S - plain `clang -target
    // arm64-apple-macos13 -static -nostdlib`) and run it at EL0 in its own
    // address space. It calls write(1, "hello from EL0\n", 15) then
    // exit(0) via the BSD syscall convention (svc #0x80, x16 = number,
    // ref/syscalls.master's numbering), proving the full boot -> paging ->
    // exceptions -> userspace -> syscall round trip works end to end.
    //
    // There's no scheduler yet (proc/thread.zig is one-shot, one task),
    // so this is the kernel's entire "workload" for now; a real init
    // process / multiple tasks is future work past this milestone.
    var regions: [4]mmu.Region = undefined;
    var regions_used: usize = 0;
    const result = macho.load(hello_macho, &regions, &regions_used) catch {
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

    var task = Task.create(task_regions[0 .. regions_used + 1], result.entry, stack_pa + mmu.PAGE_SIZE);

    uart.print("opendarwin: entering userspace (mach-o)...\n");
    thread.enter(&task);
}
