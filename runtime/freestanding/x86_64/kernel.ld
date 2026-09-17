/* Faz F.4 (bkz. plan dosyası "Gerçek bare-metal boot zinciri (x86_64)"):
 * Multiboot1-yüklenebilir bir x86_64 kernel imajı için linker script.
 *
 * Fiziksel yükleme adresi 1MiB (0x100000) — BIOS/legacy-ISA deliğinin
 * (0xA0000-0xFFFFF) ÜSTÜNDE, Multiboot1 yükleyicilerinin GELENEKSEL
 * hedefi. `.multiboot` bölümü (Multiboot1 spec §3.1.1 gereği dosyanın
 * İLK 8192 baytı İçİnde OLMAK ZORUNDA) `KEEP()` İLE (linker'ın "kullanılmıyor
 * gibi görünen" bölümleri budamasına karşı) korunur.
 *
 * Yığın (64KiB) VE sayfa-tablosu (`pml4`/`pdpt`/`pd`) rezervasyonları
 * `boot.S`nin KENDİ `.bss` bölümünde (`.skip` direktifleriyle) tanımlanır
 * (bu script SADECE `*(.bss*)` İLE onları TOPLAR) — AYRI bir `.stack`
 * bölümü YARATILMAZ, bu YÜZDEN `_kernel_end` (madde 6'nın fiziksel sayfa
 * allocator'ının TABANI) HER ZAMAN yığının/sayfa-tablolarının ÜSTÜNDE
 * kalır, allocator aralığıyla ÇAKIŞMA YAPISAL olarak İMKANSIZDIR.
 */

/* QEMU'nun/GRUB'un dahili Multiboot1 yükleyicisi ELF64 kabul ETMİYOR
 * ("Cannot load x86-64 image, give a 32bit one" — GERÇEK bir QEMU
 * çalıştırmasıyla KEŞFEDİLDİ). Klasik çözüm (`OUTPUT_FORMAT(elf32-i386)`
 * BURADA, linker script'te) BİLİNÇLİ olarak KULLANILMIYOR — GERÇEK bir
 * denemeyle KANITLANDI ki bu, `zig cc`nin gömülü LLD'sinde ELF64
 * girdiyi TAMAMEN REDDETTİRİYOR ("incompatible with elf32-i386"), VE
 * GNU `ld` ile denendiğinde de `R_X86_64_REX_GOTPCRELX` relokasyonlarının
 * linker-taraflı "relax" (GOT-indirect `mov`u DOĞRUDAN `lea`ya ÇEVİRME)
 * adımını YARIM bırakıyor — extern veri referansları (ör. `kernel.zig`nin
 * `nox_isr_table[i]`si) ÇALIŞMA ZAMANINDA GARBAGE bir işaretçi okuyup
 * ÇÖKÜYORDU. Bu YÜZDEN linkleme NORMAL (elf64-x86-64, LLD'nin KENDİ
 * relax mantığı DOĞRU çalıştığı) OLARAK yapılır; ELF32/EM_386 KONTEYNERİ
 * (QEMU İçİn) linkTEN SONRA, `objcopy -O elf32-i386 -S` İLE — TÜM
 * relokasyonlar ZATEN çözülmüş/somut adreslere gömülmüş OLDUĞUNDAN
 * relax'a hiç GEREK KALMADAN — POST-PROCESS OLARAK üretilir (bkz.
 * `tests/golden/kernel_boot_x86_64_test.zig`nin link/convert adımları).
 */

ENTRY(_start)

SECTIONS
{
    . = 0x100000;
    _kernel_start = .;

    .multiboot : ALIGN(4)
    {
        KEEP(*(.multiboot))
    }

    .text : ALIGN(4096)
    {
        *(.text*)
    }

    .rodata : ALIGN(4096)
    {
        *(.rodata*)
    }

    .data : ALIGN(4096)
    {
        *(.data*)
    }

    .bss : ALIGN(4096)
    {
        _bss_start = .;
        *(COMMON)
        *(.bss*)
        _bss_end = .;
    }

    _kernel_end = .;

    /DISCARD/ :
    {
        *(.eh_frame)
        *(.eh_frame_hdr)
        *(.comment)
        *(.note.*)
    }
}
