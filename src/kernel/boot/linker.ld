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

    /DISCARD/ : {
        *(.comment)
        *(.note.*)
        *(.eh_frame)
    }
}
