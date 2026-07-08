const uart = @import("drivers/uart.zig");
const exceptions = @import("arch/aarch64/exceptions.zig");
const mmu = @import("mm/mmu.zig");

const KERNEL_LOAD_ADDR: u64 = 0x4008_0000;
// Generous fixed upper bound on the kernel image + boot stack's size (actual
// size is currently under 1MB). A compile-time constant here - rather than
// computing the true size from the __kernel_end linker symbol at runtime -
// means `kernel_regions` below is placed in .rodata with no runtime struct
// construction at all, which matters because that construction would
// otherwise happen pre-MMU-enable (see mmu.zig's module doc comment on why
// that's dangerous).
const KERNEL_IMAGE_MAX_LEN: u64 = 8 * 1024 * 1024;

const kernel_regions = [_]mmu.Region{
    .{
        .pa = KERNEL_LOAD_ADDR,
        .len = KERNEL_IMAGE_MAX_LEN,
        .prot = .{ .writable = true, .executable = true, .user = false },
    },
    .{
        // PL011 UART MMIO.
        .pa = 0x0900_0000,
        .len = mmu.PAGE_SIZE,
        .prot = .{ .writable = true, .executable = false, .user = false, .device = true },
    },
};

export fn kmain() callconv(.c) noreturn {
    // MMU is enabled first, before anything else, deliberately. While the
    // stage-1 MMU is disabled the architecture forces every access to be
    // treated as strongly-ordered Device memory, which unconditionally
    // faults on any unaligned multi-byte load/store - and the compiler is
    // free to lower ordinary struct copies (e.g. a driver's bind() return
    // value landing in a global) to wide/vector stores whenever it likes.
    // Chasing each occurrence individually isn't tenable; getting to Normal
    // memory semantics before running any "normal" code is.
    mmu.enable(&kernel_regions);

    uart.init();
    uart.print("opendarwin: boot ok\n");
    uart.print("opendarwin: MMU enabled\n");

    exceptions.init();
    uart.print("opendarwin: exception vectors installed\n");

    while (true) {
        asm volatile ("wfe");
    }
}
