/* Meson G12A (Superbird) link layout.
 *
 * DRAM is 0x0..0x2000_0000 (512 MiB, `memory@0`), so QEMU virt's
 * 0x4008_0000 base in linker.ld is out of range here. We link at
 * 0x0200_0000: 2 MiB aligned (so U-Boot's `booti` leaves the image where
 * it was loaded rather than relocating a non-PIC binary), clear of
 * U-Boot's own relocated copy near ~0x1700_0000, and well below the
 * `secmon` reserved region at 0x0500_0000..0x0730_0000.
 */

ENTRY(_start)

SECTIONS
{
    . = 0x02000000;
    __image_start = .;

    .text : {
        KEEP(*(.text.boot))
        KEEP(*(.text._start))
        *(.text .text.*)
    }

    .rodata : {
        *(.rodata .rodata.*)
    }

    .data : {
        *(.data .data.*)
    }

    .got : {
        *(.got .got.*)
    }

    . = ALIGN(16);
    __bss_start = .;
    .bss (NOLOAD) : {
        *(.bss .bss.*)
        *(COMMON)
    }
    . = ALIGN(16);
    __bss_end = .;

    . = ALIGN(4096);
    __boot_stack_bottom = .;
    . += 0x10000; /* 64KiB boot stack - core 0 (primary) only */
    __boot_stack_top = .;
    __stack_top = __boot_stack_top;

    /* One 64KiB stack per secondary core */
    . = ALIGN(4096);
    __secondary_stacks_bottom = .;
    . += 0x10000 * 4;
    __secondary_stacks_top = .;

    .userpages : ALIGN(4096) {
        __userpages_start = .;
        *(.userpages)
        __userpages_end = .;
    }

    . = ALIGN(4096);
    __kernel_end = .;
    __image_end = .;
    __image_size = __image_end - __image_start;
    __kernel_reserved_end = .;

    /DISCARD/ : {
        *(.comment)
        *(.eh_frame .eh_frame_hdr)
        *(.note .note.*)
        *(.debug_*)
    }
}
