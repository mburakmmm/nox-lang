/* Nox freestanding riscv64 (QEMU `virt`, -bios none, v2.1.151): RAM 0x80000000'da başlar, çekirdek tam oraya yüklenir. */
ENTRY(_start)

SECTIONS
{
    . = 0x80000000;
    .text : ALIGN(4096) {
        KEEP(*(.text.boot))
        *(.text .text.*)
    }
    .rodata : ALIGN(4096) { *(.rodata .rodata.*) *(.srodata .srodata.*) }
    .data : ALIGN(4096) {
        *(.data .data.*)
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.*)
    }
    .bss : ALIGN(4096) {
        __bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.* COMMON)
        . = ALIGN(16);
        __bss_end = .;
    }
    . = ALIGN(4096);
    . += 0x10000;
    __stack_top = .;
    _kernel_end = .;
    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.riscv.attributes) }
}
