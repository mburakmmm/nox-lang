//! Faz F.4 (bkz. plan dosyası "Gerçek bare-metal boot zinciri (x86_64)"):
//! `noxrt_kernel_mod`nin (build.zig'in ÜÇÜNCÜ, SABİT x86_64-ÖZEL zincirinin)
//! KÖK dosyası. `lib_freestanding.zig`nin (arch-nötr, İKİNCİ zincir
//! TARAFINDAN da paylaşılan) TÜM force-ref'lenmiş içeriğini + `freestanding/
//! x86_64/kernel.zig`yi (x86_64-özel boot/ISR/UART kodu) TEK bir yerde
//! birleştirir. AYNI dizinde (`lib_freestanding.zig`nin YANINDA) yaşar —
//! Zig 0.16'nın modül-yolu kısıtlaması (`@import`in modül kökünün DIŞINA
//! `..` İLE ÇIKAMAMASI) YÜZÜNDEN, bu dosya `runtime/freestanding/x86_64/`
//! altında OLSAYDI `lib_freestanding.zig`ye YUKARI-DOĞRU bir `@import`
//! YAPAMAZDI — bu YÜZDEN BİLİNÇLİ olarak `runtime/` kökünde tutulur (HER
//! İKİ hedefine de SADECE AŞAĞI-DOĞRU `@import` gerekir).
//!
//! **GERÇEK bir x86_64 Linux CI çalıştırmasıyla BULUNAN bug'ın düzeltmesi**:
//! `kernel.zig`nin force-ref'i ÖNCEDEN `lib_freestanding.zig`nin KENDİSİNDE,
//! `if (builtin.cpu.arch == .x86_64)` KOŞULUYLA yaşıyordu — bu koşul
//! "SADECE ÜÇÜNCÜ (kernel-özel) zincir x86_64 hedefler" VARSAYIMINA
//! DAYANIYORDU, AMA İKİNCİ (host-arch, GENEL AMAÇLI freestanding) zincir
//! de HOST mimarisi TESADÜFEN x86_64 OLDUĞUNDA (ör. bir x86_64 Linux CI
//! runner'ında) AYNI koşulu SAĞLAR — İKİNCİ zincir `kernel.zig`yi YANLIŞLIKLA
//! force-ref eder, boot.S'e bağımlı `_kernel_end`/`nox_isr_table` extern'leri
//! O zincirin LİNK adımında TANIMSIZ kalıp "undefined symbol" hatası verir.
//! Bu YÜZDEN `kernel.zig`nin force-ref'i `lib_freestanding.zig`nin KENDİSİNDEN
//! TAMAMEN ÇIKARILIP, SADECE BU dosyaya (noxrt_kernel_mod'un KÖKÜNE, HİÇBİR
//! ZAMAN İKİNCİ zincir TARAFINDAN KULLANILMAYAN) taşındı — `builtin.cpu.arch`
//! TEK BAŞINA "hangi build.zig zincirinin çalıştığını" AYIRT EDEMEZ, AMA
//! "hangi KÖK DOSYADAN derlendiği" HER ZAMAN AYIRT EDER.
//!
//! (`_ = lib_freestanding;` GİBİ, İMPORT EDİLEN BİR DOSYANIN TAMAMINI
//! discard İLE force-ref etmenin, o dosyanın KENDİ üst-düzey `comptime`
//! bloklarını GERÇEKTEN tetiklediği — SADECE tekil bir üyesini değil —
//! bu turda GERÇEK bir `zig build-obj`+`nm` deneyiyle DOĞRULANDI.)

const lib_freestanding = @import("lib_freestanding.zig");
const kernel_x86_64 = @import("freestanding/x86_64/kernel.zig");

comptime {
    _ = lib_freestanding;
    _ = kernel_x86_64;
}
