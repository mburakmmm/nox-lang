/*
 * Nox freestanding riscv64 önyükleme (QEMU `virt`, `-bios none`, v2.1.151, TODO 1.11).
 *
 * QEMU `-bios none -kernel kernel.elf` ELF'in giriş noktasına (0x80000000) M-modunda, MMU kapalı atlar; a0 = hartid. Yapılanlar:
 *   1. hartid != 0 ise park et (tek çekirdek kullanılır).
 *   2. mstatus.FS = Initial (FPU kapalı gelirse `fadd.d` yasadışı komut verir).
 *   3. Yığın + .bss sıfırlama, `nox_freestanding_early_init`, `main`, `nox_freestanding_halt`.
 * M-modunda sayfalama yoktur; QEMU TCG hizasız erişimi destekler.
 */
    .section .text.boot, "ax"
    .global _start
_start:
    csrr    t0, mhartid
    bnez    t0, park
    li      t0, 0x2000                  /* mstatus.FS = 01 (Initial) */
    csrs    mstatus, t0
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    la      sp, __stack_top
    la      t0, __bss_start
    la      t1, __bss_end
1:  bgeu    t0, t1, 2f
    sd      zero, 0(t0)
    addi    t0, t0, 8
    j       1b
2:
    call    nox_freestanding_early_init
    call    main
    call    nox_freestanding_halt
park:
    wfi
    j       park
