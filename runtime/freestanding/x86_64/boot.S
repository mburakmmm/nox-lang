/*
 * Faz F.4 (bkz. plan dosyası "Gerçek bare-metal boot zinciri (x86_64)"):
 * Multiboot1 uyumlu bootloader-özgür boot stub'ı — `kernel.ld` tarafından
 * fiziksel 1MiB'e (0x100000) yerleştirilir, `qemu -kernel` (VEYA GRUB gibi
 * herhangi bir Multiboot1 yükleyicisi) tarafından 32-bit korumalı modda,
 * paging KAPALIYKEN çağrılır.
 *
 * `runtime/async_rt/swap_x86_64.S`nin AKSİNE `SYM()` makrosu KULLANILMAZ —
 * bu dosya SADECE `x86_64-freestanding-none` hedefi İçİn derlenir, HER
 * ZAMAN öneksiz (Apple-olmayan) ELF sembolleri üretir.
 *
 * Akış: 32-bit `_start` → `.bss`i sıfırla → identity-map sayfa tabloları
 * kur (0..32MiB, 2MiB huge page'lerle) → CR4.PAE/EFER.LME/CR0.PG sırayla
 * AÇILIR → 32-bit `lgdt` (6 baytlık pseudo-descriptor) → uzun-mod GDT'sine
 * `ljmp` → 64-bit `long_mode_start` → segment yazmaçları/RSP/RBP kurulur →
 * `nox_freestanding_early_init()` (Zig: seri port + diag_sink + PIC + IDT)
 * → `main(argc=0, argv=NULL)` (genMain'in ÜRETTİĞİ C-ABI) → `nox_freestanding_
 * halt()` (QEMU isa-debug-exit) → sonsuz `hlt` döngüsü (savunmacı, ASLA
 * ulaşılmamalı).
 */

/* ---------------------------------------------------------------------
 * Multiboot1 başlığı — dosyanın İLK 8192 baytı İçİnde OLMAK ZORUNDA
 * (Multiboot1 spec §3.1.1) — `kernel.ld`nin `KEEP()`i BUNU garanti eder.
 * EAX(magic)/EBX(mbi pointer) BİLİNÇLİ olarak YOK SAYILIR (bellek-haritası
 * ayrıştırma Kapsam Dışı — bkz. plan dosyası).
 * --------------------------------------------------------------------- */
.section .multiboot, "a", @progbits
.align 4
.long 0x1BADB002                       /* magic */
.long 0x00000003                       /* flags: ALIGN (bit0) | MEMINFO (bit1) */
.long -(0x1BADB002 + 0x00000003)       /* checksum: magic+flags+checksum == 0 */

/* ---------------------------------------------------------------------
 * 32-bit giriş noktası
 * --------------------------------------------------------------------- */
.section .text
.code32
.globl _start
_start:
    cli

    /* `.bss`i sıfırla (ESP AYARLANMADAN ÖNCE — yığının KENDİSİ .bss
     * İçİnde yaşıyor, bu YÜZDEN henüz kullanılamaz; bu döngü SADECE
     * genel-amaçlı yazmaçlar kullanır, yığın GEREKMEZ). */
    mov $_bss_start, %edi
    mov $_bss_end, %ecx
    sub %edi, %ecx
    shr $2, %ecx
    xor %eax, %eax
    rep stosl

    /* Identity-map sayfa tabloları kur: pml4[0] -> pdpt, pdpt[0] -> pd,
     * pd[0..15] her biri (i<<21)|0x83 (P|RW|PS, 2MiB huge page) —
     * 0..32MiB'i identity-map eder (boot.S'in KENDİ fiziksel adresini
     * VE madde 6'nın fiziksel sayfa allocator aralığını KAPSAR). */
    mov $pdpt, %eax
    or $0x03, %eax
    mov %eax, pml4

    mov $pd, %eax
    or $0x03, %eax
    mov %eax, pdpt

    mov $pd, %edi
    xor %ecx, %ecx
.fill_pd:
    mov %ecx, %eax
    shl $21, %eax
    or $0x83, %eax
    mov %eax, (%edi)
    movl $0, 4(%edi)
    add $8, %edi
    inc %ecx
    cmp $16, %ecx
    jl .fill_pd

    /* CR3 = pml4 */
    mov $pml4, %eax
    mov %eax, %cr3

    /* CR4.PAE (bit 5) | CR4.OSFXSR (bit 9) | CR4.OSXMMEXCPT (bit 10) —
     * GERÇEK bir QEMU çalıştırmasıyla KEŞFEDİLDİ: OSFXSR AYARLANMADAN
     * derleyicinin ürettiği HERHANGİ bir SSE talimatı (`movups` GİBİ,
     * Zig'in struct-kopyalama İçİn SERBESTÇE ÜRETTİĞİ) #UD (Invalid
     * Opcode, vektör 6) İLE ÇÖKER — OSFXSR bit9 BUNU önler, OSXMMEXCPT
     * bit10 (SIMD FP istisnalarının #UD YERİNE #XM OLARAK raporlanmasını
     * sağlar) İLE BİRLİKTE standart "SSE'yi etkinleştir" ÇİFTİDİR. */
    mov %cr4, %eax
    or $0x620, %eax
    mov %eax, %cr4

    /* IA32_EFER.LME (MSR 0xC0000080, bit 8) */
    mov $0xC0000080, %ecx
    rdmsr
    or $0x100, %eax
    wrmsr

    /* CR0.PG (bit 31) — paging'i AÇAR (long mode'a GİRMEK İçİn son adım) */
    mov %cr0, %eax
    or $0x80000000, %eax
    mov %eax, %cr0

    /* 32-bit modda `lgdt` — 6 baytlık pseudo-descriptor (word limit +
     * long base), 64-bit `lgdt`nin 10 baytlık formatından FARKLI. */
    lgdt gdt_ptr

    /* Uzun-mod kod segmentine (selector 0x08) uzak atlama — CS'i
     * gerçekten günceller (long mode'un GEREKTİRDİĞİ TEK yol). */
    ljmp $0x08, $long_mode_start

/* ---------------------------------------------------------------------
 * GDT — null / 64-bit kod / veri (3 girdi)
 * --------------------------------------------------------------------- */
.section .rodata
.align 8
gdt_start:
    .quad 0x0000000000000000   /* null descriptor */
    .quad 0x00AF9A000000FFFF   /* 64-bit kod: access=0x9A, flags/limit_hi=0xAF (G=1,L=1) */
    .quad 0x00CF92000000FFFF   /* veri: access=0x92, flags/limit_hi=0xCF (G=1,D=1) */
gdt_end:

gdt_ptr:
    .word gdt_end - gdt_start - 1
    .long gdt_start

/* ---------------------------------------------------------------------
 * 64-bit devam
 * --------------------------------------------------------------------- */
.section .text
.code64
long_mode_start:
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    mov %ax, %ss

    mov $boot_stack_top, %rsp
    xor %rbp, %rbp

    call nox_freestanding_early_init

    xor %edi, %edi          /* argc = 0 (w) */
    xor %esi, %esi           /* argv = NULL (l) — genMain'in $main(w %argc, l %argv) C-ABI'siyle eşleşir */
    call main

    call nox_freestanding_halt

.hang:
    cli
    hlt
    jmp .hang

/* ---------------------------------------------------------------------
 * ISR trambolinleri — 0-31'in TAMAMI İçİn stub. Hata-kodu İTEN vektörler
 * (CPU'nun KENDİSİ bir error code push ettiği KESİN liste): 8, 10, 11,
 * 12, 13, 14, 17, 21, 29, 30 — DİĞERLERİ İçİn sahte $0 push edilir
 * (çerçeveyi NORMALLEŞTİRİR, ortak gövdenin TEK bir düzen VARSAYMASINI
 * sağlar).
 * --------------------------------------------------------------------- */
.macro ISR_NOERR num
.globl isr_stub_\num
isr_stub_\num:
    pushq $0
    pushq $\num
    jmp nox_isr_common
.endm

.macro ISR_ERR num
.globl isr_stub_\num
isr_stub_\num:
    pushq $\num
    jmp nox_isr_common
.endm

ISR_NOERR 0
ISR_NOERR 1
ISR_NOERR 2
ISR_NOERR 3
ISR_NOERR 4
ISR_NOERR 5
ISR_NOERR 6
ISR_NOERR 7
ISR_ERR   8
ISR_NOERR 9
ISR_ERR   10
ISR_ERR   11
ISR_ERR   12
ISR_ERR   13
ISR_ERR   14
ISR_NOERR 15
ISR_NOERR 16
ISR_ERR   17
ISR_NOERR 18
ISR_NOERR 19
ISR_NOERR 20
ISR_ERR   21
ISR_NOERR 22
ISR_NOERR 23
ISR_NOERR 24
ISR_NOERR 25
ISR_NOERR 26
ISR_NOERR 27
ISR_NOERR 28
ISR_ERR   29
ISR_ERR   30
ISR_NOERR 31

/* Ortak gövde: 15 GPR `pushq` → `nox_isr_dispatch(vec, err, rip)` çağır →
 * 15 GPR `popq` → `addq $16,%rsp` (vektör+hata-kodu) → `iretq`.
 *
 * Hizalama (bkz. plan dosyasının "Kritik dosyalar" bölümü): hardware
 * çerçevesi (RIP,CS,RFLAGS,RSP,SS = 5 qword + normallenmiş err/vec = 2
 * qword => 7 qword = 56 bayt, RSP≡8 mod 16 ÇAĞRI ANINDA) + 15×8=120 bayt
 * GPR push → `call` anında RSP≡0 mod 16 → SysV'ye UYGUN. Bu hesap Intel
 * SDM'in "long mode'da CPU kesme çerçevesini 16-baytlık hizaya oturtur"
 * davranışına DAYANIR — KESİN doğrulama GERÇEK QEMU çalıştırmasıyla
 * yapılır (bkz. plan dosyası, "ölç, varsayma" disiplini).
 */
nox_isr_common:
    push %r15
    push %r14
    push %r13
    push %r12
    push %r11
    push %r10
    push %r9
    push %r8
    push %rbp
    push %rdi
    push %rsi
    push %rdx
    push %rcx
    push %rbx
    push %rax

    mov 120(%rsp), %rdi     /* vec */
    mov 128(%rsp), %rsi     /* err */
    mov 136(%rsp), %rdx     /* rip */
    call nox_isr_dispatch

    pop %rax
    pop %rbx
    pop %rcx
    pop %rdx
    pop %rsi
    pop %rdi
    pop %rbp
    pop %r8
    pop %r9
    pop %r10
    pop %r11
    pop %r12
    pop %r13
    pop %r14
    pop %r15

    add $16, %rsp
    iretq

/* `nox_isr_table` — kernel.zig'in `idtInstall()`ı BUNU okuyup HER vektörün
 * IDT girdisine (`.selector=0x08` İLE) yerleştirir. */
.section .rodata
.align 8
.globl nox_isr_table
nox_isr_table:
    .quad isr_stub_0
    .quad isr_stub_1
    .quad isr_stub_2
    .quad isr_stub_3
    .quad isr_stub_4
    .quad isr_stub_5
    .quad isr_stub_6
    .quad isr_stub_7
    .quad isr_stub_8
    .quad isr_stub_9
    .quad isr_stub_10
    .quad isr_stub_11
    .quad isr_stub_12
    .quad isr_stub_13
    .quad isr_stub_14
    .quad isr_stub_15
    .quad isr_stub_16
    .quad isr_stub_17
    .quad isr_stub_18
    .quad isr_stub_19
    .quad isr_stub_20
    .quad isr_stub_21
    .quad isr_stub_22
    .quad isr_stub_23
    .quad isr_stub_24
    .quad isr_stub_25
    .quad isr_stub_26
    .quad isr_stub_27
    .quad isr_stub_28
    .quad isr_stub_29
    .quad isr_stub_30
    .quad isr_stub_31

/* ---------------------------------------------------------------------
 * `.bss` rezervasyonları — sayfa tabloları (4096-hizalı, 4096 bayt) +
 * boot yığını (16-hizalı, 64KiB).
 * --------------------------------------------------------------------- */
.section .bss
.align 4096
pml4:
    .skip 4096
pdpt:
    .skip 4096
pd:
    .skip 4096

.align 16
boot_stack_bottom:
    .skip 65536
boot_stack_top:
