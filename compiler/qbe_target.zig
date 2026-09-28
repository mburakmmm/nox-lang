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

const std = @import("std");
const builtin = @import("builtin");

/// Faz R.3+F.1 tamamlama (bkz. plan dosyası): `noxc`nin KENDİ çalıştığı
/// platforma göre `qbe -t` İÇİN doğru hedef adını döner — `is_freestanding
/// == true` İKEN HOST OS'tan (`builtin.os.tag`) BAĞIMSIZ olarak HER ZAMAN
/// arch-SADECE (bare-ABI) eşlemeyi kullanır (macOS/Windows'un Apple/kendi
/// özel ABI konvansiyonları freestanding bir hedef İçİn GEÇERSİZDİR) —
/// `is_freestanding == false` İKEN (TEK, DEĞİŞMEYEN çağrı sitesi hariç TÜM
/// mevcut testler) davranış BİREBİR AYNI kalır.
pub fn name(is_freestanding: bool) []const u8 {
    if (is_freestanding) {
        return switch (builtin.cpu.arch) {
            .aarch64 => "arm64",
            .x86_64 => "amd64_sysv",
            .riscv64 => "rv64",
            else => @compileError("qbe: desteklenmeyen mimari"),
        };
    }
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

/// Faz F.4 (bkz. plan dosyası "Gerçek bare-metal boot zinciri"), v2.0 madde
/// 8'de KAMUYA AÇILDI (bkz. nox-teknik-spesifikasyon.md §3.196): `name()`nin
/// (yukarıda, DEĞİŞMEDEN) comptime-bilinen `builtin.cpu.arch`ının AKSİNE,
/// ÇALIŞMA-ZAMANI bir arch-ADI stringinden `qbe -t` hedefini çözer — kamuya
/// açık `--target <isim>` bayrağının (`--profile freestanding` İLE)
/// BACKING İMPLEMENTASYONU (ESKİDEN dâhilî/belgelenmemiş `NOX_FREESTANDING_
/// KERNEL_ARCH` env-değişkeniydi, ARTIK TAMAMEN SİLİNDİ). Bilinmeyen bir
/// arch adı İçİn `null` döner (ÇALIŞMA-ZAMANI girdisi OLDUĞUNDAN `@compileError`
/// KULLANILAMAZ) — çağıran taraf AÇIK bir hatayla `exit(1)` yapar.
pub fn nameForArch(arch_name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, arch_name, "x86_64")) return "amd64_sysv";
    if (std.mem.eql(u8, arch_name, "aarch64")) return "arm64";
    if (std.mem.eql(u8, arch_name, "riscv64")) return "rv64";
    return null;
}

/// v2.0 madde 8 (bkz. nox-teknik-spesifikasyon.md §3.196): kamuya açık
/// `--target <isim>` bayrağının HOSTED (varsayılan profil) tarafı —
/// `.github/workflows/release.yml`nin GERÇEK, sevk edilen 4 platform
/// isminin (`macos-arm64`/`linux-x64`/`linux-arm64`/`windows-x64`)
/// BİREBİR AYNISI (YENİ bir isimlendirme İCAT EDİLMEDİ). `qbe_target`,
/// `runtime_object_name` (`build.zig`nin AYNI isimle kurduğu `noxrt-
/// <isim>.o`) VE `zig_triple` (`zig cc -target`in beklediği, `swap_asm`
/// çapraz-derlemesinde de kullanılan üçlü) döner.
pub const HostedTargetInfo = struct {
    qbe_target: []const u8,
    runtime_object_name: []const u8,
    zig_triple: []const u8,
    is_windows: bool,
};

pub fn hostedTargetInfo(target_name: []const u8) ?HostedTargetInfo {
    if (std.mem.eql(u8, target_name, "macos-arm64")) return .{ .qbe_target = "arm64_apple", .runtime_object_name = "noxrt-macos-arm64", .zig_triple = "aarch64-macos", .is_windows = false };
    if (std.mem.eql(u8, target_name, "linux-x64")) return .{ .qbe_target = "amd64_sysv", .runtime_object_name = "noxrt-linux-x64", .zig_triple = "x86_64-linux-gnu", .is_windows = false };
    if (std.mem.eql(u8, target_name, "linux-arm64")) return .{ .qbe_target = "arm64", .runtime_object_name = "noxrt-linux-arm64", .zig_triple = "aarch64-linux-gnu", .is_windows = false };
    if (std.mem.eql(u8, target_name, "windows-x64")) return .{ .qbe_target = "amd64_win", .runtime_object_name = "noxrt-windows-x64", .zig_triple = "x86_64-windows-gnu", .is_windows = true };
    return null;
}
