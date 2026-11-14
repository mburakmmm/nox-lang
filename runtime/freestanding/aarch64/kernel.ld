/*
 * Nox freestanding aarch64 (QEMU `virt`, v2.1.151): RAM 0x40000000'da başlar; çekirdek 0x40080000'a yüklenir (Linux Image konvansiyonu ile aynı, düşük adresler DTB için serbest).
 */
ENTRY(_start)

SECTIONS
{
    . = 0x40080000;
    .text : ALIGN(4096) {
        KEEP(*(.text.boot))
        *(.text .text.*)
    }
    .rodata : ALIGN(4096) { *(.rodata .rodata.*) }
    .data : ALIGN(4096) { *(.data .data.*) }
    /* Sayfa tablosu .bss sıfırlama aralığının DIŞINDA kalmalı (MMU açıkken sıfırlanırsa eşleme yok olur). */
    .pt (NOLOAD) : ALIGN(4096) { *(.bss.pt) }
    .bss : ALIGN(4096) {
        __bss_start = .;
        *(.bss .bss.* COMMON)
        . = ALIGN(16);
        __bss_end = .;
    }
    /* 64 KiB önyükleme yığını (fiber yığınları Zig tarafında ayrı bir havuzdur). */
    . = ALIGN(4096);
    . += 0x10000;
    __stack_top = .;
    _kernel_end = .;
    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
