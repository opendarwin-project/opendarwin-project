ENTRY(_start)

KERNEL_LOAD_ADDR = 0x40080000;

SECTIONS
{
    . = KERNEL_LOAD_ADDR;

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
    . += 0x10000; /* 64KiB boot stack */
    __boot_stack_top = .;

    __kernel_end = .;

    /* Reserve a fixed 2MB for kernel-only content regardless of its actual
     * size, so mm/mmu.zig's KERNEL_IMAGE_MAX_LEN can be a safe compile-time
     * constant that's guaranteed to stop before .userpages below - if the
     * kernel ever actually grows past 2MB, this line makes the linker fail
     * loudly (location counter moving backward) instead of silently
     * reintroducing the page_pool/kernel_regions overlap bug. */
    . = KERNEL_LOAD_ADDR + 0x200000;

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
        *(.comment)
        *(.note.*)
        *(.eh_frame)
    }
}
