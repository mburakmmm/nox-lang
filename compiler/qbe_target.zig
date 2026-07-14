//! Faz R.3 (bkz. docs/uretim-hazirlik-analizi.md): `qbe`nin `-t <target>`i
//! ŞİMDİYE KADAR HİÇ geçilmiyordu — HEM `compiler/main.zig` HEM (bağımsız
//! `qbe`/`cc` çağrıları yapan) BİRDEN ÇOK test dosyası, `qbe`nin KENDİ
//! BUILD-TIME varsayılan hedefine (bkz. `config.h`, `Deftgt`) GÜVENİYORDU.
//! Bu, GERÇEK bir PORTABİLİTE hatasıydı: Homebrew'un macOS İÇİN derlediği
//! `qbe` `arm64_apple`ı varsayılan yapar (Apple'ın SysV'den FARKLI ABI'si),
//! ama KAYNAKTAN (`make`, `config.h`: `Deftgt T_arm64`) Linux'ta derlenen
//! bir `qbe` SESSİZCE `arm64`e (Linux/genel AAPCS64) düşer — AYNI
//! derleyicinin İKİ FARKLI makinede SESSİZCE FARKLI ABI'ler ÜRETMESİ demektir
//! (Faz R.1/R.2/R.3'ün Docker doğrulaması SIRASINDA GERÇEKTEN bulunan ve
//! birden fazla codegen golden testinin — özellikle `nox.json` gibi
//! `with_rt extern def` DÖNÜŞ TİPİ olarak sınıf örneği kullanan test
//! senaryolarının — Linux'ta BAŞARISIZ olmasına/BELLEK SIZDIRMASINA yol
//! açan somut hata). Bu dosya, `noxc`nin KENDİSİ (main.zig) VE `qbe`yi
//! BAĞIMSIZ ÇAĞIRAN her test dosyasının AYNI mantığı TEK bir yerden
//! paylaşması İÇİN vardır — `compiler/lib.zig` üzerinden dışa açılır.

const builtin = @import("builtin");

/// `noxc`nin KENDİ çalıştığı platforma göre `qbe -t` İÇİN doğru hedef adını
/// döner.
pub fn name() []const u8 {
    return switch (builtin.os.tag) {
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => "arm64_apple",
            .x86_64 => "amd64_apple",
            else => @compileError("qbe: desteklenmeyen macOS mimarisi"),
        },
        .windows => "amd64_win",
        else => switch (builtin.cpu.arch) {
            .aarch64 => "arm64",
            .x86_64 => "amd64_sysv",
            .riscv64 => "rv64",
            else => @compileError("qbe: desteklenmeyen mimari"),
        },
    };
}
