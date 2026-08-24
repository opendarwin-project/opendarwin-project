ENTRY(_start)

KERNEL_LOAD_ADDR = 0x40080000;

SECTIONS
{
    . = 0x40080000; /* KERNEL_LOAD_ADDR */

    .text : ALIGN(4096) {
        KEEP(*(.text.boot))
        *(.text .text.*)
    }

    .rodata : ALIGN(4096) {
        *(.rodata .rodata.*)
    }

    .data : ALIGN(4096) {
        *(.data .data.*)
    }

    .bss : ALIGN(4096) {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        __bss_end = .;
    }

    . = ALIGN(4096);
    __boot_stack_bottom = .;
    . += 0x10000; /* 64KiB boot stack - core 0 (primary) only */
    __boot_stack_top = .;

    /* One 64KiB stack per secondary core (cores 1..MAX_CPUS-1; core 0 uses
     * the boot stack above), indexed directly by MPIDR_EL1's low byte -
     * see start.S's secondary-core path and mm/mmu.zig's MAX_CPUS. */
    . = ALIGN(4096);
    __secondary_stacks_bottom = .;
    . += 0x10000 * 4;
    __secondary_stacks_top = .;

    __kernel_end = .;
    __image_size = __kernel_end - KERNEL_LOAD_ADDR;
    __kernel_reserved_end = .;

    /* Deliberately separate from .bss and placed after __kernel_end: pages
     * handed out by mm/mmu.zig's allocPage() (backing task code/data/stack
     * content) must NOT fall inside the range mmu.kernel_regions maps as
     * kernel-only, or a per-task page table's later user-accessible mapping
     * for the same physical page collides with the pre-existing kernel-only
     * block/page descriptor there - see mmu.zig's module doc comment. */
    .userpages : ALIGN(4096) {
        __userpages_start = .;
        *(.userpages)
        __userpages_end = .;
    }

    /DISCARD/ : {
        *(.debug_*)
        *(.comment)
        *(.note.*)
        *(.eh_frame)
    }
}
