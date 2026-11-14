/*
 * Nox freestanding aarch64 önyükleme (QEMU `virt`, v2.1.151, TODO 1.11).
 *
 * `qemu-system-aarch64 -machine virt -cpu cortex-a57 -kernel kernel.elf` ELF'in giriş noktasına EL1'de, MMU kapalı, FP/SIMD tuzaklı olarak atlar. Yapılanlar:
 *   1. FP/SIMD'i aç (CPACR_EL1.FPEN = 0b11): derleyici bellek kopyalamada q-yazmaçlarını kullanır.
 *   2. MMU'yu aç: MMU kapalıyken TÜM veri erişimleri "Device-nGnRnE"dir ve hizasız erişim hizalama hatası verir (Nox/QBE kodu hizasız yükleme yapar, ör. dize kopyalama).
 *      4 KiB granül, T0SZ=25 (39-bit VA), tek seviye-1 tablosu, 1 GiB bloklar, kimlik eşlemesi: [0, 1 GiB) Device-nGnRE (UART/GIC), [1 GiB, 2 GiB) Normal WB (RAM).
 *   3. Yığını kur, .bss'i sıfırla, Zig önyükleme noktasını (`nox_freestanding_early_init`: UART sink + halt/fiber sağlayıcıları) çağır, `main`i çağır, `nox_freestanding_halt`.
 */
    .section .text.boot, "ax"
    .global _start
_start:
    /* Önce yalnızca EL1'de olduğumuzu varsay (QEMU `virt`, -kernel ELF). Çekirdek dışı EL'de (EL2) CPACR_EL1 yine yazılabilir. */
    mov     x0, #(3 << 20)
    msr     cpacr_el1, x0
    isb

    /* MAIR_EL1: attr0 = Device-nGnRE (0x04), attr1 = Normal WB RW-alloc (0xff). */
    mov     x0, #0xff04
    msr     mair_el1, x0

    /* TCR_EL1: T0SZ=25, IRGN0/ORGN0 = WB WA, SH0 = Inner, TG0 = 4 KiB, IPS = 36-bit (0b001 << 32), TTBR1 devre dışı (EPD1). */
    ldr     x0, =((25) | (1 << 8) | (1 << 10) | (3 << 12) | (0 << 14) | (1 << 23) | (1 << 32))
    msr     tcr_el1, x0

    /* Seviye-1 tablosu: [0] Device blok, [1] Normal blok. Blok tanımlayıcısı: adres | AF(10) | SH(8:9) | AttrIdx(2:4) | 0b01. */
    adrp    x1, l1_table
    add     x1, x1, :lo12:l1_table
    mov     x2, #0x0000000000000401         /* 0x0 | AF | blok(01) | attr0 */
    str     x2, [x1]
    ldr     x2, =(0x40000000 | (1 << 10) | (3 << 8) | (1 << 2) | 1)
    str     x2, [x1, #8]
    msr     ttbr0_el1, x1
    dsb     sy
    isb
    tlbi    vmalle1
    dsb     sy
    isb

    /* SCTLR_EL1: M(0)=1, C(2)=1, I(12)=1; A(1)=0, SA(3)=0, SA0(4)=0 (hizalama denetimi KAPALI). Kalanı bilinen RES1 bitleriyle. */
    mov     x0, #(1 << 0)
    orr     x0, x0, #(1 << 2)
    orr     x0, x0, #(1 << 12)
    orr     x0, x0, #(1 << 29)              /* LSMAOE (RES1) */
    orr     x0, x0, #(1 << 28)              /* nTLSMD (RES1) */
    orr     x0, x0, #(1 << 23)              /* SPAN (RES1) */
    orr     x0, x0, #(1 << 22)              /* EIS (RES1) */
    orr     x0, x0, #(1 << 20)              /* TSCXT (RES1) */
    orr     x0, x0, #(1 << 11)              /* EOS (RES1) */
    msr     sctlr_el1, x0
    isb

    /* Yığın + .bss sıfırlama. */
    adrp    x0, __stack_top
    add     x0, x0, :lo12:__stack_top
    mov     sp, x0
    adrp    x0, __bss_start
    add     x0, x0, :lo12:__bss_start
    adrp    x1, __bss_end
    add     x1, x1, :lo12:__bss_end
1:  cmp     x0, x1
    b.hs    2f
    stp     xzr, xzr, [x0], #16
    b       1b
2:
    bl      nox_freestanding_early_init

    bl      main
    bl      nox_freestanding_halt
3:  wfe
    b       3b

    .section .bss.pt, "aw", %nobits
    .balign 4096
l1_table:
    .skip 4096
