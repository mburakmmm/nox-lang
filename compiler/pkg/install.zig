//! `noxc install`/`uninstall`/`list` — GLOBAL paket kurulumu (bkz. proje
//! belleği/plan dosyası "GLOBAL paket kurulumu" bölümü). `pip`/`npm -g`/
//! `cargo install`/`pipx` benzeri bir mekanizma: bir paket, KENDİ
//! `nox.json`sinde bir `bin` girdi noktası bildirirse, PATH'e eklenmiş
//! bir native ikili olarak kurulabilir.
//!
//! **`pkg/upgrade.zig` İLE İLİŞKİSİ:** `upgrade.zig`nin "İNDİRİLMİŞ bir
//! ARŞİVİ güvenle YERİNE koyma" deseninden ESİNLENİLDİ ama bu dosya ÇOK
//! DAHA KÜÇÜK bir sorunu çözer — TEK bir (TAZE DERLENMİŞ, indirilmiş
//! DEĞİL) ikiliyi güvenle yerleştirmek. Asıl orkestrasyon (`fetchToCache`/
//! `buildOne`/registry lookup GEREKTİRDİĞİNDEN, `buildOne` `main.zig`nin
//! ÖZEL bir fonksiyonu olduğundan) `main.zig`de yaşar — `cmdAdd`/
//! `cmdUpgrade`nin AYNI "orkestrasyon main.zig'de, paylaşılan/saf mantık
//! pkg/*.zig'de" ayrım deseni.
//!
//! **Global bin dizini KASITLI olarak `noxc`nin KENDİ kurulum kökünden
//! (`resolveInstallRoot`, `upgrade.zig` tarafından YÖNETİLİR) AYRIDIR** —
//! `project.resolveGlobalBinDir`nin belge notuna bkz.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// GLOBAL kurulu ikililerin platforma göre uzantısı — `pkg/upgrade.zig`nin
/// `BIN_EXE_NAMES`iyle AYNI `.exe`-yalnizca-Windows kuralı.
pub fn exeSuffix() []const u8 {
    return if (builtin.os.tag == .windows) ".exe" else "";
}

/// `command_name`e platforma uygun uzantıyı ekler (ör. `"nyx"` →
/// Windows'ta `"nyx.exe"`, aksi halde DEĞİŞMEDEN).
pub fn exeFileName(a: Allocator, command_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}{s}", .{ command_name, exeSuffix() });
}

/// `source_path`teki (TAZE derlenmiş, SCRATCH bir konumdaki, MUTLAK yol)
/// ikiliyi `bin_dir`nin İÇİNDEKİ `dest_name`e GÜVENLE taşır.
///
/// **Windows'ta ÖNCE yeniden adlandır, SONRA kopyala:** ÇALIŞAN bir
/// `.exe` SİLİNEMEZ/ÜZERİNE YAZILAMAZ ama YENİDEN ADLANDIRILABİLİR —
/// `upgrade.zig`nin `installFromScratch`ının AYNI numarası, burada TEK
/// bir dosya İçin (sabit 3-isimlik tüm-ağaç kopyalamaya GEREK YOK).
/// macOS/Linux'ta `Dir.copyFile`nin KENDİSİ (rename-tabanlı atomik
/// değiştirme) YETERLİ.
pub fn placeBinary(a: Allocator, io: Io, source_path: []const u8, bin_dir: Io.Dir, dest_name: []const u8) !void {
    if (builtin.os.tag == .windows) {
        const old_name = try std.fmt.allocPrint(a, "{s}.old", .{dest_name});
        bin_dir.rename(dest_name, bin_dir, old_name, io) catch {};
    }
    try std.Io.Dir.cwd().copyFile(source_path, bin_dir, dest_name, io, .{ .replace = true, .make_path = true });
}

/// `bin_dir_path`in `PATH` ortam değişkeninde GÖRÜNÜP GÖRÜNMEDİĞİNİ
/// (basit alt-dizge/segment KARŞILAŞTIRMASI — `PATH`in KENDİSİ platforma
/// göre `:`/`;` İLE ayrılır) kontrol eder. **Sadece bir SEZGİ** —
/// sembolik link/normalize-edilmemiş yol farklılıkları YANLIŞ-NEGATİF
/// üretebilir (zararsız: kullanıcı SADECE gereksiz bir ipucu GÖRÜR,
/// HİÇBİR ŞEY otomatik DEĞİŞTİRİLMEZ).
pub fn isDirOnPath(path_env: []const u8, bin_dir_path: []const u8) bool {
    const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
    var it = std.mem.splitScalar(u8, path_env, sep);
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry, bin_dir_path)) return true;
    }
    return false;
}

/// `noxc install`in İLK global kurulumdan SONRA (VE `bin_dir` PATH'te
/// GÖRÜNMÜYORSA) yazdırdığı TEK SATIRLIK talimat — shell rc dosyalarını
/// OTOMATİK DÜZENLEMEZ (bkz. modül üstü not, "kalıcı yapılandırma
/// değişikliği" — rustup/`go install`in varsayılan davranışıyla TUTARLI,
/// pipx'in `ensurepath`ının AKSİNE).
pub fn printPathHint(bin_dir_path: []const u8, is_tr: bool) void {
    if (builtin.os.tag == .windows) {
        if (is_tr) {
            std.debug.print("not: '{s}' PATH'inizde gorunmuyor — kalici olarak eklemek icin: setx PATH \"{s};%PATH%\"\n", .{ bin_dir_path, bin_dir_path });
        } else {
            std.debug.print("note: '{s}' is not on your PATH — to add it permanently: setx PATH \"{s};%PATH%\"\n", .{ bin_dir_path, bin_dir_path });
        }
    } else {
        if (is_tr) {
            std.debug.print("not: '{s}' PATH'inizde gorunmuyor — shell profilinize ekleyin:\n  export PATH=\"{s}:$PATH\"\n", .{ bin_dir_path, bin_dir_path });
        } else {
            std.debug.print("note: '{s}' is not on your PATH — add this to your shell profile:\n  export PATH=\"{s}:$PATH\"\n", .{ bin_dir_path, bin_dir_path });
        }
    }
}

/// Şu ANKİ zamanı, `project.InstalledPackage.installed_at`de saklanacak
/// insan-okunur bir Unix-epoch-saniye dizgesi olarak üretir (`noxc list`
/// çıktısı İçin YETERLİ hassasiyet — tam bir takvim/ISO8601 biçimlendirici
/// bu KÜÇÜK bilgi-amaçlı alan İçin GEREKSİZ karmaşıklık olurdu).
pub fn nowAsEpochSecondsString(a: Allocator, io: Io) ![]const u8 {
    const ts = std.Io.Timestamp.now(io, .real);
    const seconds = @divTrunc(ts.nanoseconds, 1_000_000_000);
    return std.fmt.allocPrint(a, "{d}", .{seconds});
}

test "isDirOnPath: tam segment eslesmesi, alt-dizge DEGIL" {
    const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
    const path_env = if (builtin.os.tag == .windows)
        "C\x3a\\a;C\x3a\\home\\.nox\\bin;C\x3a\\b"
    else
        "/usr/bin:/home/x/.nox/bin:/bin";
    _ = sep;
    const target = if (builtin.os.tag == .windows) "C\x3a\\home\\.nox\\bin" else "/home/x/.nox/bin";
    try std.testing.expect(isDirOnPath(path_env, target));
    try std.testing.expect(!isDirOnPath(path_env, "/home/x/.nox"));
}

// **GERÇEK, GitHub Actions'ın native `windows-latest` çalıştırıcısında
// BULUNAN bir hata (bu değişiklikle İLİŞKİSİZ, ÖNCEDEN VAR OLAN bir
// Windows CI kırılması — v1.21.3 dahil ÖNCEKİ sürümlerin CI koşularında
// da AYNI ŞEKİLDE başarısız oluyordu):** ÖNCEDEN bu test `std.heap.
// FixedBufferAllocator` (64 baytlık SABİT bir yığın tamponu) kullanıyordu
// — `exeFileName`nin İÇİNDEKİ `std.fmt.allocPrint` (`Writer.Allocating.
// initCapacity(gpa, fmt.len)`, YALNIZCA 6 bayt İLE başlar, SONRA 7 bayta
// BÜYÜMESİ GEREKİR) Windows'ta bu KÜÇÜK, TEK-tahsisli büyüme senaryosuyla
// `error.OutOfMemory` İLE BAŞARISIZ oluyordu (macOS/Linux'ta AYNI kod
// SORUNSUZ çalışıyordu — Windows'a ÖZGÜ bir `FixedBufferAllocator.resize`/
// `Writer.Allocating` etkileşimi GİBİ görünüyor). Düzeltme: GERÇEK bir
// yığın (heap) ayırıcısına (`std.testing.allocator`, sızıntı TESPİTLİ)
// geçildi — `FixedBufferAllocator`nin KENDİSİ `exeFileName`nin GERÇEK
// davranışının bir PARÇASI DEĞİLDİ, yalnızca testin KENDİ (gereksiz)
// tercihiydi.
test "exeFileName: platforma gore uzanti eklenir" {
    const name = try exeFileName(std.testing.allocator, "nyx");
    defer std.testing.allocator.free(name);
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("nyx.exe", name);
    } else {
        try std.testing.expectEqualStrings("nyx", name);
    }
}
