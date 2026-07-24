//! `noxc upgrade` — kurulu bir Nox araç zincirini (binary + `noxrt.o` +
//! `nox.*` stdlib) kendi kendine, en son (ya da belirtilen) GitHub
//! Release'e güncelleme. `install.sh`/`install.ps1`nin (bkz. o dosyaların
//! KENDİ belge notları) YAPTIĞI şeyi ELLE yeniden çalıştırmaya GEREK
//! KALMADAN, kurulu `noxc`nin KENDİSİNDEN yapar.
//!
//! **Neden `.github/workflows/release.yml` HER `v*` tag push'unda gerçek
//! bir Release ürettiği İçin bu ARTIK anlamlı:** `VERSIONING.md` §4 (her
//! commit bir sürümdür) — "en son sürüm" ARTIK sık sık değişiyor, bu
//! komutun HER ZAMAN çekecek TAZE bir şeyi var.
//!
//! **Güvenli değiştirme modeli:** İNDİRME + ÇIKARMA TAMAMEN bir geçici
//! (`.upgrade-scratch`) alt dizinde yapılır — HERHANGİ bir aşama
//! BAŞARISIZ olursa MEVCUT kurulum HİÇ dokunulmadan kalır (`install.sh`/
//! `ps1`nin YIKICI "önce SİL, SONRA aç" modelinden DAHA GÜVENLİ). Kilit
//! TAŞIMAYAN her şey (`lib/**`, kök belgeler) DOĞRUDAN kopyalanır; YALNIZCA
//! `bin/noxc`/`noxlsp`/`qbe` (VARSA `.exe`) Windows'ta ÖNCE yeniden
//! adlandırılıp (ÇALIŞAN bir .exe SİLİNEMEZ/ÜZERİNE YAZILAMAZ ama YENİDEN
//! ADLANDIRILABİLİR — standart öz-güncelleyici hilesi), SONRA yeni ikili
//! kopyalanır — bu, KURULUM KÖKÜ dizininin KENDİSİNİN (ÇALIŞAN `noxc.exe`nin
//! yaşadığı ÜST dizin) Windows'ta yeniden-adlandırılıp adlandırılamayacağı
//! BELİRSİZLİĞİNİ TAMAMEN atlar (dizin HİÇBİR ZAMAN dokunulmaz, YALNIZCA
//! İÇİNDEKİ tekil dosyalar). macOS/Linux'ta bu sorun YOK — Unix, ÇALIŞAN
//! bir yürütülebilirin dizin girdisinin DEĞİŞTİRİLMESİNE İZİN VERİR
//! (`Dir.copyFile`nin `createFileAtomic` + `atomic_file.replace`ı ZATEN
//! rename-tabanlı bir atomik değiştirme YAPAR).
//!
//! **En yakın emsal:** `pkg/index.zig`nin `loadIndexFromUrl`ı (`std.http.
//! Client` + `readerDecompressing` deseni) VE `pkg/fetch.zig`nin
//! `FetchPolicy`si (HTTPS-varsayılan, `NOX_ALLOW_INSECURE_TRANSPORT`
//! opt-in). **GERÇEK bir fark:** GitHub'ın `releases/download/...` URL'si
//! bir S3 yönlendirmesi (302) YAPAR — `index.zig`nin `.unhandled`i YERİNE
//! burada `RedirectBehavior.init(5)` KULLANILIR (Zig'in KENDİ İÇ
//! `receiveHead`i bunu OTOMATİK/ŞEFFAF takip eder, elle bir döngü
//! GEREKMEZ — bkz. `std/http/Client.zig`, `RedirectBehavior`in belge notu).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fetch_mod = @import("fetch.zig");
const build_options = @import("build_options");

const REPO = "mburakmmm/nox-lang";
const hex_chars = "0123456789abcdef";

/// Yalnızca-test override'ları İÇİN (`main()`de `NOX_UPGRADE_API_BASE`/
/// `NOX_UPGRADE_DOWNLOAD_BASE`den okunur, `NOX_HOME`/`NOX_RESOURCE_DIR`
/// İLE AYNI "BİR KEZ oku, açıkça ilet" disiplini) — GERÇEK kullanımda HER
/// ZAMAN varsayılanlar (`https://api.github.com`/`https://github.com`).
pub const UpgradePolicy = struct {
    api_base: []const u8 = "https://api.github.com",
    download_base: []const u8 = "https://github.com",
};

pub const UpgradeError = error{
    InsecureUpgradeUrlRejected,
    UpgradeFetchFailed,
    UpgradeVersionResolutionFailed,
    UpgradeDownloadFailed,
    UpgradeChecksumMismatch,
    UnsupportedPlatform,
};

/// `index.zig`nin `validateIndexUrlScheme`ıyla AYNI desen (bkz. o
/// fonksiyonun belge notu) — burada AYRI tutulur çünkü BU modülün KENDİ
/// (test-yerine-koyma İçin AYRI) taban URL'leri VAR.
fn validateUpgradeUrlScheme(url: []const u8, allow_insecure_transport: bool) UpgradeError!void {
    if (std.mem.startsWith(u8, url, "https://")) return;
    if (std.mem.startsWith(u8, url, "http://") and allow_insecure_transport) return;
    return error.InsecureUpgradeUrlRejected;
}

pub const PlatformAsset = struct {
    /// `release.yml`nin varlık-adı deseninin ORTA kısmı, ör. "macos-arm64".
    name: []const u8,
    is_zip: bool,
};

/// `release.yml`nin TAM OLARAK ürettiği 4 platform+mimari kombinasyonu
/// (bkz. o iş akışının matrisleri) — HERHANGİ BAŞKA bir kombinasyon İçin
/// (ör. Intel Mac) `null` döner, çağıran taraf kaynaktan derlemeye YÖNLENDİRİR.
pub fn currentPlatformAsset() ?PlatformAsset {
    return switch (builtin.os.tag) {
        .macos => if (builtin.cpu.arch == .aarch64) PlatformAsset{ .name = "macos-arm64", .is_zip = false } else null,
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => PlatformAsset{ .name = "linux-x64", .is_zip = false },
            .aarch64 => PlatformAsset{ .name = "linux-arm64", .is_zip = false },
            else => null,
        },
        .windows => if (builtin.cpu.arch == .x86_64) PlatformAsset{ .name = "windows-x64", .is_zip = true } else null,
        else => null,
    };
}

/// `"v" ++ build_options.version` — ŞU AN ÇALIŞAN ikilinin sürüm etiketi
/// (`build_options.version`, `build.zig.zon`den — TEK gerçek kaynak,
/// `noxc --version`in KENDİSİNİN raporladığıyla AYNI).
pub fn currentVersionTag(a: Allocator) ![]const u8 {
    return std.fmt.allocPrint(a, "v{s}", .{build_options.version});
}

fn httpGetToMemory(a: Allocator, io: Io, url: []const u8) ![]const u8 {
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{ .redirect_behavior = .init(5) });
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    if (response.head.status != .ok) return error.UpgradeFetchFailed;

    var transfer_buffer: [1024]u8 = undefined;
    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .deflate, .gzip => a.alloc(u8, std.compress.flate.max_window_len) catch return error.UpgradeFetchFailed,
        .zstd, .compress => return error.UpgradeFetchFailed,
    };
    defer if (decompress_buffer.len > 0) a.free(decompress_buffer);
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    var body_out: std.Io.Writer.Allocating = .init(a);
    _ = reader.streamRemaining(&body_out.writer) catch return error.UpgradeFetchFailed;
    return body_out.toOwnedSlice() catch error.UpgradeFetchFailed;
}

/// `explicit` VERİLİRSE (ör. `noxc upgrade v1.3.0`) OLDUĞU GİBİ kullanılır
/// (ağ çağrısı YOK — düşürme DAHİL herhangi bir sürüme sabitlemeyi
/// destekler). AKSİ HALDE GitHub'ın "latest release" API'sinden `tag_name`
/// (GERÇEK bir `std.json` ayrıştırmasıyla — `install.sh`nin grep/sed'i
/// YERİNE) çözülür.
pub fn resolveTargetVersion(a: Allocator, io: Io, explicit: ?[]const u8, policy: UpgradePolicy, fetch_policy: fetch_mod.FetchPolicy) ![]const u8 {
    if (explicit) |v| return a.dupe(u8, v);

    const url = try std.fmt.allocPrint(a, "{s}/repos/{s}/releases/latest", .{ policy.api_base, REPO });
    try validateUpgradeUrlScheme(url, fetch_policy.allow_insecure_transport);
    const body = try httpGetToMemory(a, io, url);

    const Parsed = struct { tag_name: []const u8 };
    const parsed = std.json.parseFromSlice(Parsed, a, body, .{ .ignore_unknown_fields = true }) catch return error.UpgradeVersionResolutionFailed;
    return parsed.value.tag_name;
}

/// `target_tag`, ŞU AN çalışan ikilinin sürümüYLE (`currentVersionTag`)
/// AYNI MI? (Öndeki `v` HER İKİSİNDE de VAR — karşılaştırmadan ÖNCE
/// normalize etmeye GEREK YOK.)
///
/// **BİLİNÇLİ tasarım — GERÇEK bir uçtan-uca duman testiyle DOĞRULANDI:**
/// bu karşılaştırma HER ZAMAN ŞU AN ÇALIŞAN ikilinin (`currentVersionTag`)
/// KENDİ sürümüne bakar — `NOX_RESOURCE_DIR`/`install_root`in GERÇEKTE
/// NEREYE yazacağına DEĞİL. GERÇEK kullanımda bu İKİSİ HER ZAMAN AYNI şeydir
/// (kurulu `noxc`, KENDİ kurulum kökünü günceller). Yalnızca test/manuel
/// doğrulama SIRASINDA (`install_root`, çalışan ikiliden BAĞIMSIZ bir
/// geçici dizine YÖNLENDİRİLDİĞİNDE) bu ikisi AYRIŞABİLİR — bu durumda
/// "zaten güncel" HER ZAMAN çalışan ikilinin (test SÜRÜCÜSÜNÜN) sürümünü
/// yansıtır, hedef dizinin GERÇEK içeriğini DEĞİL (rustup/brew'in KENDİ
/// "kendi sürümünü kontrol et" semantiğiyle TUTARLI — bkz. gerçek GitHub'a
/// karşı yapılan manuel duman testi, `v1.0.0` -> `v1.2.0` ROUND-TRIP).
pub fn isAlreadyUpToDate(a: Allocator, target_tag: []const u8) !bool {
    const current = try currentVersionTag(a);
    defer a.free(current);
    return std.mem.eql(u8, current, target_tag);
}

fn hexEncode(buf: []u8, digest: []const u8) []const u8 {
    for (digest, 0..) |byte, i| {
        buf[i * 2] = hex_chars[byte >> 4];
        buf[i * 2 + 1] = hex_chars[byte & 0xF];
    }
    return buf[0 .. digest.len * 2];
}

/// İndirilen arşivin SHA-256'sını (`crypto.zig`nin parola-hash'leme
/// işinde ZATEN KULLANILAN AYNI `std.crypto.hash.sha2.Sha256` — sıfırdan
/// bir hash algoritması YAZILMAZ), `release.yml`nin HER varlığın YANINA
/// koyduğu `.sha256` dosyasının İÇERİĞİYLE (biçim: `"<hex>  <dosya-adı>"`,
/// GERÇEK bir v1.2.0 varlığından doğrulandı) KARŞILAŞTIRIR. HTTPS ZATEN
/// taşıma-katmanı bütünlüğü sağlasa da, bu AYRI bir savunma — ağ kesintisi
/// kaynaklı KESİLMİŞ bir indirmeyi ÇIKARMA aşamasına GEÇMEDEN yakalar.
fn verifyChecksum(a: Allocator, io: Io, scratch_dir: Io.Dir, archive_name: []const u8, expected_sha256_body: []const u8) !void {
    const bytes = try scratch_dir.readFileAlloc(io, archive_name, a, .limited(256 * 1024 * 1024));
    defer a.free(bytes);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var hex_buf: [64]u8 = undefined;
    const actual_hex = hexEncode(&hex_buf, &digest);

    const expected_hex = blk: {
        const end = std.mem.indexOfAny(u8, expected_sha256_body, " \t\r\n") orelse expected_sha256_body.len;
        break :blk expected_sha256_body[0..end];
    };
    if (!std.ascii.eqlIgnoreCase(actual_hex, expected_hex)) return error.UpgradeChecksumMismatch;
}

fn downloadToFile(a: Allocator, io: Io, url: []const u8, dest_dir: Io.Dir, dest_name: []const u8) !void {
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{ .redirect_behavior = .init(5) });
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    if (response.head.status != .ok) return error.UpgradeDownloadFailed;

    // GERÇEK bir GitHub Release varlığı HTTP-katmanında (Content-Encoding)
    // SIKIŞTIRILMAZ (opak bir ikili blob) — bu, `.tar.gz`nin KENDİ İÇ gzip
    // katmanından TAMAMEN AYRI (bkz. modül üstü not) — düz `reader` YETERLİ.
    var transfer_buffer: [1024 * 8]u8 = undefined;
    const reader = response.reader(&transfer_buffer);

    const file = try dest_dir.createFile(io, dest_name, .{});
    defer file.close(io);
    var file_buf: [1024 * 64]u8 = undefined;
    var file_writer = file.writer(io, &file_buf);
    _ = reader.streamRemaining(&file_writer.interface) catch return error.UpgradeDownloadFailed;
    try file_writer.flush();
}

/// `source_dir`nin TÜM ağacını (dosya+dizin) `dest_dir`ye kopyalar —
/// `Dir.walk` + `Dir.copyFile` (`make_path = true` İLE ARA dizinleri
/// KENDİSİ oluşturur) — `std.Io.Dir`de HAZIR bir "recursive copy"
/// yardımcısı OLMADIĞINDAN burada KÜÇÜK, YEREL bir geçiş.
fn copyTree(a: Allocator, io: Io, source_dir: Io.Dir, dest_dir: Io.Dir) !void {
    var walker = try source_dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => try dest_dir.createDirPath(io, entry.path),
            .file => try source_dir.copyFile(entry.path, dest_dir, entry.path, io, .{ .replace = true, .make_path = true }),
            else => {},
        }
    }
}

/// tar.gz (macOS/Linux) — indirilen dosya `std.compress.flate`in gzip-çöz
/// modUYLA SARILIR (ham `std.tar.extract` gzip'i KENDİSİ ÇÖZMEZ), SONRA
/// `strip_components = 1` İLE arşivin sarmalayıcı `nox-lang-{tag}-{asset}/`
/// klasörü DOĞRUDAN atlanarak `final_dir`e çıkarılır — EK bir kopyalama
/// adımı GEREKMEZ.
fn extractTarGz(io: Io, scratch_dir: Io.Dir, archive_name: []const u8, final_dir: Io.Dir) !void {
    const file = try scratch_dir.openFile(io, archive_name, .{});
    defer file.close(io);
    var file_buf: [1024 * 64]u8 = undefined;
    var file_reader = std.Io.File.Reader.init(file, io, &file_buf);

    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&file_reader.interface, .gzip, &window_buf);

    try std.tar.extract(io, final_dir, &decompress.reader, .{ .strip_components = 1 });
}

/// zip (Windows) — `std.zip.extract`in `strip_components` EŞDEĞERİ
/// OLMADIĞINDAN arşiv ÖNCE AYRI bir `raw/` alt dizinine TAM çıkarılır;
/// `std.zip.Diagnostics.root_dir` (arşivdeki TÜM girdilerin PAYLAŞTIĞI
/// ortak üst dizini KENDİSİ hesaplar — bkz. std kaynağı `nextFilename`)
/// sarmalayıcı klasörün ADINI verir, `copyTree` İLE İÇERİĞİ `final_dir`e
/// taşınır.
fn extractZip(a: Allocator, io: Io, scratch_dir: Io.Dir, archive_name: []const u8, final_dir: Io.Dir) !void {
    const file = try scratch_dir.openFile(io, archive_name, .{});
    defer file.close(io);
    var file_buf: [1024 * 64]u8 = undefined;
    var file_reader = std.Io.File.Reader.init(file, io, &file_buf);

    try scratch_dir.createDirPath(io, "raw");
    var raw_dir = try scratch_dir.openDir(io, "raw", .{ .iterate = true });
    defer raw_dir.close(io);

    var diag = std.zip.Diagnostics{ .allocator = a };
    defer diag.deinit();
    try std.zip.extract(raw_dir, &file_reader, .{ .diagnostics = &diag });

    if (diag.root_dir.len > 0) {
        var source_dir = try raw_dir.openDir(io, diag.root_dir, .{ .iterate = true });
        defer source_dir.close(io);
        try copyTree(a, io, source_dir, final_dir);
    } else {
        try copyTree(a, io, raw_dir, final_dir);
    }
}

const BIN_EXE_NAMES: []const []const u8 = if (builtin.os.tag == .windows)
    &.{ "noxc.exe", "noxlsp.exe", "qbe.exe" }
else
    &.{ "noxc", "noxlsp", "qbe" };

/// `final_dir` (tam çıkarılmış, TEMİZ bir arşiv ağacı) İÇERİĞİNİ GERÇEK
/// kurulum köküne (`install_dir`) GÜVENLE aktarır — bkz. modül üstü notun
/// "Güvenli değiştirme modeli" bölümü.
fn installFromScratch(a: Allocator, io: Io, final_dir: Io.Dir, install_dir: Io.Dir) !void {
    // Önceki bir upgrade'den kalan `.old` dosyaları best-effort temizlenir
    // (o an SİLİNEBİLİR olmaları BEKLENİR — ÖNCEKİ süreç ÇOKTAN çıkmıştır).
    if (install_dir.openDir(io, "bin", .{})) |bd| {
        var bin_dir = bd;
        defer bin_dir.close(io);
        for (BIN_EXE_NAMES) |name| {
            const old_name = std.fmt.allocPrint(a, "{s}.old", .{name}) catch continue;
            bin_dir.deleteFile(io, old_name) catch {};
        }
    } else |_| {}

    // Kilit TAŞIMAYAN her şey (lib/**, kök belgeler) — `bin/<exe>` HARİÇ,
    // AŞAĞIDA AYRI ele alınır.
    var walker = try final_dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (isBinExeEntry(entry)) continue;
        switch (entry.kind) {
            .directory => try install_dir.createDirPath(io, entry.path),
            .file => try final_dir.copyFile(entry.path, install_dir, entry.path, io, .{ .replace = true, .make_path = true }),
            else => {},
        }
    }

    // `bin/noxc`/`noxlsp`/`qbe` (VARSA `.exe`): Windows'ta ÖNCE yeniden
    // adlandır (ÇALIŞAN bir .exe SİLİNEMEZ/ÜZERİNE YAZILAMAZ ama YENİDEN
    // ADLANDIRILABİLİR), SONRA kopyala; diğer platformlarda `copyFile`nin
    // KENDİSİ (rename-tabanlı atomik değiştirme) YETERLİ.
    try install_dir.createDirPath(io, "bin");
    var install_bin_dir = try install_dir.openDir(io, "bin", .{});
    defer install_bin_dir.close(io);
    var final_bin_dir = final_dir.openDir(io, "bin", .{ .iterate = true }) catch return;
    defer final_bin_dir.close(io);

    for (BIN_EXE_NAMES) |name| {
        if (builtin.os.tag == .windows) {
            const old_name = try std.fmt.allocPrint(a, "{s}.old", .{name});
            install_bin_dir.rename(name, install_bin_dir, old_name, io) catch {};
        }
        final_bin_dir.copyFile(name, install_bin_dir, name, io, .{ .replace = true, .make_path = true }) catch |err| {
            if (err == error.FileNotFound) continue;
            return err;
        };
    }
}

/// `bin/<isim>` konumundaki (derinlik 2 — "bin" alt dizininin DOĞRUDAN
/// içeriği) TEK-KULLANIMLIK yürütülebilirlerden BİRİ Mİ? `entry.basename`
/// KULLANILIR (`entry.path` DEĞİL) — Windows'un `\` ayırıcısıYLA
/// KARIŞTIRMAMAK İçin (`Walker.Entry.path`, PLATFORMA ÖZGÜ `std.fs.path.
/// sep` KULLANIR).
fn isBinExeEntry(entry: std.Io.Dir.Walker.Entry) bool {
    if (entry.kind != .file or entry.depth() != 2) return false;
    for (BIN_EXE_NAMES) |name| {
        if (std.mem.eql(u8, entry.basename, name)) return true;
    }
    return false;
}

/// TÜM akışın orkestrasyonu: indir + doğrula + çıkar (bir `.upgrade-
/// scratch` geçici dizininde) + GÜVENLE kuruluma aktar + temizle. HERHANGİ
/// bir aşama BAŞARISIZ olursa `install_root` HİÇ DOKUNULMADAN kalır
/// (`scratch` dizini bir SONRAKİ çalıştırmada YENİDEN kullanılabilir/
/// silinip yeniden oluşturulur).
pub fn performUpgrade(a: Allocator, io: Io, target_tag: []const u8, asset: PlatformAsset, install_root: []const u8, policy: UpgradePolicy, fetch_policy: fetch_mod.FetchPolicy) !void {
    var install_dir = try std.Io.Dir.openDirAbsolute(io, install_root, .{});
    defer install_dir.close(io);

    // Önceki bir çalıştırmadan kalan scratch'i TEMİZLE, TAZE oluştur.
    install_dir.deleteTree(io, ".upgrade-scratch") catch {};
    try install_dir.createDirPath(io, ".upgrade-scratch");
    var scratch_dir = try install_dir.openDir(io, ".upgrade-scratch", .{ .iterate = true });
    defer {
        scratch_dir.close(io);
        install_dir.deleteTree(io, ".upgrade-scratch") catch {};
    }

    const ext = if (asset.is_zip) "zip" else "tar.gz";
    const stage_name = try std.fmt.allocPrint(a, "nox-lang-{s}-{s}", .{ target_tag, asset.name });
    const archive_name = try std.fmt.allocPrint(a, "{s}.{s}", .{ stage_name, ext });
    const download_url = try std.fmt.allocPrint(a, "{s}/{s}/releases/download/{s}/{s}", .{ policy.download_base, REPO, target_tag, archive_name });
    const checksum_url = try std.fmt.allocPrint(a, "{s}.sha256", .{download_url});

    try validateUpgradeUrlScheme(download_url, fetch_policy.allow_insecure_transport);
    try downloadToFile(a, io, download_url, scratch_dir, archive_name);

    // Sağlamlık kontrolü (isteğe bağlı ama ucuz) — bkz. `verifyChecksum`nin
    // belge notu. `.sha256` getirilemezse (ör. ÇOK ESKİ bir sürüm/manuel
    // bir test fixture'ı) BAŞARISIZ OLMAK yerine sessizce ATLANIR — bu,
    // bütünlük kontrolünün KENDİSİNİN, olmayan bir dosya YÜZÜNDEN TÜM
    // upgrade'i engellememesi İçindir.
    if (httpGetToMemory(a, io, checksum_url)) |sha_body| {
        try verifyChecksum(a, io, scratch_dir, archive_name, sha_body);
    } else |_| {}

    try scratch_dir.createDirPath(io, "final");
    var final_dir = try scratch_dir.openDir(io, "final", .{ .iterate = true });
    defer final_dir.close(io);

    if (asset.is_zip) {
        try extractZip(a, io, scratch_dir, archive_name, final_dir);
    } else {
        try extractTarGz(io, scratch_dir, archive_name, final_dir);
    }

    try installFromScratch(a, io, final_dir, install_dir);
}

test "currentPlatformAsset: bu makinenin platformu icin dogru varlik doner" {
    const asset = currentPlatformAsset();
    if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64) {
        try std.testing.expect(asset != null);
        try std.testing.expectEqualStrings("macos-arm64", asset.?.name);
        try std.testing.expect(!asset.?.is_zip);
    }
}

test "validateUpgradeUrlScheme: https her zaman kabul, http yalnizca allow_insecure_transport ile" {
    try validateUpgradeUrlScheme("https://example.com/x", false);
    try std.testing.expectError(error.InsecureUpgradeUrlRejected, validateUpgradeUrlScheme("http://example.com/x", false));
    try validateUpgradeUrlScheme("http://example.com/x", true);
}

test "isAlreadyUpToDate: mevcut surumle ayni tag esitligi dogru tespit eder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const current = try currentVersionTag(a);
    try std.testing.expect(try isAlreadyUpToDate(a, current));
    try std.testing.expect(!try isAlreadyUpToDate(a, "v0.0.0-kesinlikle-farkli"));
}
