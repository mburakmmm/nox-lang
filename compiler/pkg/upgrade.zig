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
const progress = @import("progress.zig");
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
    /// Windows: çalışan/kilitli bir dosya kenara alınamadı (bkz. `moveAside`).
    UpgradeFileLocked,
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

/// Kararlı bir sürüm etiketi: `vMAJOR.MINOR.PATCH` (ön ek/`-rc.1` gibi soneklere izin YOK).
pub const SemVer = struct { major: u64, minor: u64, patch: u64 };

pub fn parseStableTag(tag: []const u8) ?SemVer {
    if (tag.len < 6 or tag[0] != 'v') return null;
    var it = std.mem.splitScalar(u8, tag[1..], '.');
    var parts: [3]u64 = undefined;
    var n: usize = 0;
    while (it.next()) |p| : (n += 1) {
        if (n >= 3 or p.len == 0) return null;
        parts[n] = std.fmt.parseInt(u64, p, 10) catch return null;
    }
    if (n != 3) return null;
    return .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
}

pub fn compareSemVer(x: SemVer, y: SemVer) std.math.Order {
    if (x.major != y.major) return std.math.order(x.major, y.major);
    if (x.minor != y.minor) return std.math.order(x.minor, y.minor);
    return std.math.order(x.patch, y.patch);
}

/// GitHub'ın `releases` listesinden (JSON dizi) EN YÜKSEK kararlı sürümü seçer: taslak (`draft`) ve ön sürüm (`prerelease`) ile `vX.Y.Z` biçiminde olmayan etiketler atlanır.
/// `releases/latest` KULLANILMAZ: GitHub onu semver'e göre değil en son OLUŞTURULAN release'e göre seçer; CI sırası karışınca (eski bir sürümün release'i sonradan oluşunca) eski sürüm
/// "latest" olur ve `noxc upgrade` bir DÜŞÜRME yapardı.
pub fn pickLatestStable(a: Allocator, body: []const u8) ![]const u8 {
    const Rel = struct { tag_name: []const u8, draft: bool = false, prerelease: bool = false };
    const parsed = std.json.parseFromSlice([]const Rel, a, body, .{ .ignore_unknown_fields = true }) catch return error.UpgradeVersionResolutionFailed;
    defer parsed.deinit();
    var best: ?SemVer = null;
    var best_tag: []const u8 = "";
    for (parsed.value) |r| {
        if (r.draft or r.prerelease) continue;
        const v = parseStableTag(r.tag_name) orelse continue;
        if (best == null or compareSemVer(v, best.?) == .gt) {
            best = v;
            best_tag = r.tag_name;
        }
    }
    if (best == null) return error.UpgradeVersionResolutionFailed;
    return a.dupe(u8, best_tag);
}

/// `explicit` VERİLİRSE (ör. `noxc upgrade v1.3.0`) OLDUĞU GİBİ kullanılır
/// (ağ çağrısı YOK — düşürme DAHİL herhangi bir sürüme sabitlemeyi
/// destekler). AKSİ HALDE GitHub'ın release LİSTESİNDEN (`pickLatestStable`)
/// en yüksek kararlı sürüm çözülür.
pub fn resolveTargetVersion(a: Allocator, io: Io, explicit: ?[]const u8, policy: UpgradePolicy, fetch_policy: fetch_mod.FetchPolicy) ![]const u8 {
    if (explicit) |v| return a.dupe(u8, v);

    const url = try std.fmt.allocPrint(a, "{s}/repos/{s}/releases?per_page=100", .{ policy.api_base, REPO });
    try validateUpgradeUrlScheme(url, fetch_policy.allow_insecure_transport);
    const body = try httpGetToMemory(a, io, url);
    return pickLatestStable(a, body);
}

/// `target_tag`, ŞU AN çalışan ikilinin sürümünden KESİN OLARAK eski mi? (Açık sürüm verilmediğinde bir DÜŞÜRMEYİ engellemek için.) Biri ayrıştırılamazsa `false`.
pub fn isOlderThanCurrent(a: Allocator, target_tag: []const u8) bool {
    const current = currentVersionTag(a) catch return false;
    defer a.free(current);
    const c = parseStableTag(current) orelse return false;
    const t = parseStableTag(target_tag) orelse return false;
    return compareSemVer(t, c) == .lt;
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

/// En çok `DOWNLOAD_ATTEMPTS` kez dener (geçici ağ kopması/GitHub CDN hatası tek denemede bütün yükseltmeyi düşürmesin) ve HER başarısız denemenin NEDENİNİ (HTTP durumu ya da
/// düşük seviye hata) stderr'e yazar: eskiden yalnızca "UpgradeDownloadFailed" görünüyor, ne olduğu anlaşılmıyordu.
const DOWNLOAD_ATTEMPTS = 3;

fn downloadToFile(a: Allocator, io: Io, r: progress.Reporter, url: []const u8, dest_dir: Io.Dir, dest_name: []const u8) !void {
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        if (downloadOnce(a, io, r, url, dest_dir, dest_name)) |_| return else |err| {
            std.debug.print("upgrade: download attempt {d}/{d} failed ({t}): {s}\n", .{ attempt, DOWNLOAD_ATTEMPTS, err, url });
            if (attempt >= DOWNLOAD_ATTEMPTS) return error.UpgradeDownloadFailed;
            io.sleep(.fromSeconds(@intCast(attempt)), .awake) catch {};
        }
    }
}

fn downloadOnce(a: Allocator, io: Io, r: progress.Reporter, url: []const u8, dest_dir: Io.Dir, dest_name: []const u8) !void {
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{ .redirect_behavior = .init(5) });
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    if (response.head.status != .ok) {
        std.debug.print("upgrade: HTTP {d} {s}\n", .{ @intFromEnum(response.head.status), response.head.status.phrase() orelse "" });
        // Eski sürümlerde (v2.0.173 öncesi) bir release, tüm platform arşivleri yüklenmeden "Latest" olabiliyordu; 404'ün olağan nedeni budur.
        if (response.head.status == .not_found) std.debug.print("upgrade: the archive for this platform is not published (yet); if this release is brand new, try again in a few minutes\n", .{});
        return error.UpgradeDownloadFailed;
    }

    // GERÇEK bir GitHub Release varlığı HTTP-katmanında (Content-Encoding)
    // SIKIŞTIRILMAZ (opak bir ikili blob) — bu, `.tar.gz`nin KENDİ İÇ gzip
    // katmanından TAMAMEN AYRI (bkz. modül üstü not) — düz `reader` YETERLİ.
    var transfer_buffer: [1024 * 8]u8 = undefined;
    const reader = response.reader(&transfer_buffer);

    const file = try dest_dir.createFile(io, dest_name, .{});
    defer file.close(io);
    var file_buf: [1024 * 64]u8 = undefined;
    var file_writer = file.writer(io, &file_buf);

    // v2.0.135: parça parça aktarım (ilerleme çubuğu için); toplam, yönlendirme sonrası YANITIN `Content-Length`idir.
    var dl = progress.Download.start(r, dest_name, response.head.content_length);
    while (true) {
        const n = reader.stream(&file_writer.interface, .limited(64 * 1024)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => {
                dl.abort();
                std.debug.print("upgrade: download interrupted ({t}; reader: {?t})\n", .{ err, response.bodyErr() });
                return error.UpgradeDownloadFailed;
            },
        };
        dl.advance(n);
    }
    try file_writer.flush();
    dl.finish();
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

/// Windows'ta `src`yi `dst`nin üstüne taşır (`MOVEFILE_REPLACE_EXISTING`).
/// **Neden `Dir.rename` DEĞİL:** Zig'in Windows `rename`i kaynağı
/// `GENERIC_WRITE | DELETE` erişimiyle AÇAR; ÇALIŞAN bir `.exe`
/// (veya yüklü bir DLL) yazma için AÇILAMAZ → `AccessDenied`. `MoveFileExW`
/// yalnızca `DELETE` erişimi ister, bu yüzden çalışan imaj YENİDEN
/// ADLANDIRILABİLİR (standart öz-güncelleyici hilesi). Eski kod bu hatayı
/// `catch {}` ile yutuyor, ardından ÇALIŞAN `noxc.exe`nin üstüne kopyalamaya
/// çalışıp `noxc upgrade`i "access denied" ile düşürüyordu.
const win_move = if (builtin.os.tag == .windows) struct {
    const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
    extern "kernel32" fn MoveFileExW(existing: [*:0]const u16, new: ?[*:0]const u16, flags: u32) callconv(.winapi) i32;

    fn move(a: Allocator, src: []const u8, dst: []const u8) !void {
        const src_w = try std.unicode.utf8ToUtf16LeAllocZ(a, src);
        defer a.free(src_w);
        const dst_w = try std.unicode.utf8ToUtf16LeAllocZ(a, dst);
        defer a.free(dst_w);
        if (MoveFileExW(src_w.ptr, dst_w.ptr, MOVEFILE_REPLACE_EXISTING) == 0) {
            return switch (std.os.windows.GetLastError()) {
                .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
                else => error.UpgradeFileLocked,
            };
        }
    }
} else struct {};

/// Bir önceki yükseltmeden kalan kenara-alınmış kopya adları: `<yol>.old`,
/// `<yol>.old1` ... `<yol>.old{ASIDE_SLOTS-1}`. Eski kopya HÂLÂ çalışıyorsa
/// (ör. editörde açık `noxlsp.exe`) silinemez ve ADI dolu kalır; sonraki
/// boş ad kullanılır, böylece kilitli bir artık yükseltmeyi ENGELLEMEZ.
const ASIDE_SLOTS = 8;

fn asideName(buf: []u8, rel: []const u8, slot: usize) []const u8 {
    if (slot == 0) return std.fmt.bufPrint(buf, "{s}.old", .{rel}) catch rel;
    return std.fmt.bufPrint(buf, "{s}.old{d}", .{ rel, slot }) catch rel;
}

/// Windows: `install_root\rel` dosyasını kenara alır (var olmayan dosya
/// başarıdır). Döndürdüğü yol geri alma (rollback) içindir.
fn moveAside(a: Allocator, install_root: []const u8, rel: []const u8) !?[]const u8 {
    var slot: usize = 0;
    while (slot < ASIDE_SLOTS) : (slot += 1) {
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        const aside_rel = asideName(&name_buf, rel, slot);
        const src = try std.fs.path.join(a, &.{ install_root, rel });
        defer a.free(src);
        const dst = try std.fs.path.join(a, &.{ install_root, aside_rel });
        win_move.move(a, src, dst) catch |err| switch (err) {
            error.FileNotFound => return null,
            error.UpgradeFileLocked => continue,
            else => |e| return e,
        };
        return try a.dupe(u8, dst);
    }
    return error.UpgradeFileLocked;
}

/// `final_dir/rel` -> `install_dir/rel`. Windows'ta `must_aside` (çalışan
/// yürütülebilirler) için önce eski dosya kenara alınır; diğer dosyalarda
/// düz kopya `AccessDenied` verirse AYNI yol bir kez denenir. Kopya
/// başarısız olursa kenara alınan dosya GERİ KONUR (kurulum yarım kalmaz).
fn replaceFile(a: Allocator, io: Io, final_dir: Io.Dir, install_dir: Io.Dir, install_root: []const u8, rel: []const u8, must_aside: bool) !void {
    const opts: Io.Dir.CopyFileOptions = .{ .replace = true, .make_path = true };
    if (builtin.os.tag != .windows) return final_dir.copyFile(rel, install_dir, rel, io, opts);

    var aside: ?[]const u8 = null;
    defer if (aside) |p| a.free(p);
    if (must_aside) aside = try moveAside(a, install_root, rel);
    final_dir.copyFile(rel, install_dir, rel, io, opts) catch |err| {
        if (err == error.AccessDenied and aside == null) {
            aside = try moveAside(a, install_root, rel);
            if (final_dir.copyFile(rel, install_dir, rel, io, opts)) |_| return else |err2| return restoreAside(a, install_root, rel, aside, err2);
        }
        return restoreAside(a, install_root, rel, aside, err);
    };
}

fn restoreAside(a: Allocator, install_root: []const u8, rel: []const u8, aside: ?[]const u8, err: anyerror) anyerror {
    if (aside) |p| {
        const dst = std.fs.path.join(a, &.{ install_root, rel }) catch return err;
        defer a.free(dst);
        win_move.move(a, p, dst) catch {};
    }
    return err;
}

/// Windows: `final_dir` içindeki her dosya için önceki yükseltmelerden kalan
/// `.old*` artıklarını (best-effort) siler. Yalnızca YENİ ağaçta KARŞILIĞI
/// olan yolların artıkları silinir; kullanıcıya ait `notlar.old` gibi
/// dosyalara dokunulmaz.
fn cleanStaleAside(a: Allocator, io: Io, final_dir: Io.Dir, install_dir: Io.Dir) void {
    var walker = final_dir.walk(a) catch return;
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        var slot: usize = 0;
        while (slot < ASIDE_SLOTS) : (slot += 1) {
            var name_buf: [std.fs.max_path_bytes]u8 = undefined;
            install_dir.deleteFile(io, asideName(&name_buf, entry.path, slot)) catch {};
        }
    }
}

/// `final_dir` (tam çıkarılmış, TEMİZ bir arşiv ağacı) İÇERİĞİNİ GERÇEK
/// kurulum köküne (`install_dir`, mutlak yolu `install_root`) GÜVENLE
/// aktarır — bkz. modül üstü notun "Güvenli değiştirme modeli" bölümü.
///
/// Sıra: ÖNCE `bin/<exe>` (kilitlenme riski burada; başarısız olursa kurulum
/// DOKUNULMADAN kalır), SONRA lib/**, kök belgeler.
fn installFromScratch(a: Allocator, io: Io, final_dir: Io.Dir, install_dir: Io.Dir, install_root: []const u8) !void {
    if (builtin.os.tag == .windows) cleanStaleAside(a, io, final_dir, install_dir);

    try install_dir.createDirPath(io, "bin");
    for (BIN_EXE_NAMES) |name| {
        const rel = try std.fmt.allocPrint(a, "bin{c}{s}", .{ std.fs.path.sep, name });
        defer a.free(rel);
        replaceFile(a, io, final_dir, install_dir, install_root, rel, true) catch |err| {
            if (err == error.FileNotFound) continue;
            std.debug.print("upgrade: cannot replace {s} ({t}); close running noxc/noxlsp processes (editors with the Nox extension) and retry\n", .{ rel, err });
            return err;
        };
    }

    var walker = try final_dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (isBinExeEntry(entry)) continue;
        switch (entry.kind) {
            .directory => try install_dir.createDirPath(io, entry.path),
            .file => replaceFile(a, io, final_dir, install_dir, install_root, entry.path, false) catch |err| {
                std.debug.print("upgrade: cannot replace {s} ({t})\n", .{ entry.path, err });
                return err;
            },
            else => {},
        }
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
pub fn performUpgrade(a: Allocator, io: Io, r: progress.Reporter, target_tag: []const u8, asset: PlatformAsset, install_root: []const u8, policy: UpgradePolicy, fetch_policy: fetch_mod.FetchPolicy) !void {
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
    try downloadToFile(a, io, r, download_url, scratch_dir, archive_name);

    // Sağlamlık kontrolü (isteğe bağlı ama ucuz) — bkz. `verifyChecksum`nin
    // belge notu. `.sha256` getirilemezse (ör. ÇOK ESKİ bir sürüm/manuel
    // bir test fixture'ı) BAŞARISIZ OLMAK yerine sessizce ATLANIR — bu,
    // bütünlük kontrolünün KENDİSİNİN, olmayan bir dosya YÜZÜNDEN TÜM
    // upgrade'i engellememesi İçindir.
    if (httpGetToMemory(a, io, checksum_url)) |sha_body| {
        const verify_step = r.begin("Verifying checksum", .{});
        verifyChecksum(a, io, scratch_dir, archive_name, sha_body) catch |err| {
            verify_step.fail();
            return err;
        };
        verify_step.done();
    } else |_| {}

    try scratch_dir.createDirPath(io, "final");
    var final_dir = try scratch_dir.openDir(io, "final", .{ .iterate = true });
    defer final_dir.close(io);

    const extract_step = r.begin("Extracting", .{});
    const extracted = if (asset.is_zip) extractZip(a, io, scratch_dir, archive_name, final_dir) else extractTarGz(io, scratch_dir, archive_name, final_dir);
    extracted catch |err| {
        extract_step.fail();
        return err;
    };
    extract_step.done();

    const install_step = r.begin("Installing into {s}", .{install_root});
    installFromScratch(a, io, final_dir, install_dir, install_root) catch |err| {
        install_step.fail();
        return err;
    };
    install_step.done();
}

/// Kurulumu bir paket yöneticisi ya da paket biçimi yönetiyorsa onun adı ve güncelleme yönergesi. `noxc upgrade` bu dosyaları kendisi
/// ezerse yöneticinin kaydı ile gerçek içerik ayrışır (`brew` Cellar'daki sürüm dizinini, `snap` salt-okunur imajı sahiplenir; bir AppImage
/// ise kendi geçici bağlama noktasında çalışır ve zaten değiştirilemez). Kök, çalışan ikilinin GERÇEK yolundan türetilir (symlink çözülmüş).
pub const ManagedBy = struct { name: []const u8, update_hint: []const u8 };

pub fn managedBy(install_root: []const u8) ?ManagedBy {
    // Homebrew: `.../Cellar/noxc/<sürüm>/libexec`.
    if (std.mem.indexOf(u8, install_root, "/Cellar/") != null) return .{ .name = "Homebrew", .update_hint = "update it with 'brew upgrade noxc'" };
    // AUR `noxc-bin` paketi (packaging/aur): ağaç /usr/lib/noxc altındadır, /usr/bin'dekiler sarmalayıcıdır.
    if (std.mem.eql(u8, install_root, "/usr/lib/noxc") or std.mem.startsWith(u8, install_root, "/usr/lib/noxc/")) return .{ .name = "pacman (AUR package noxc-bin)", .update_hint = "update it with your AUR helper, for example 'yay -Syu noxc-bin'" };
    // Snap (classic): `/snap/noxc/<revizyon>` ya da (Fedora/Arch'ta) `/var/lib/snapd/snap/noxc/<revizyon>`.
    if (std.mem.indexOf(u8, install_root, "/snap/noxc/") != null) return .{ .name = "snap", .update_hint = "update it with 'sudo snap refresh noxc'" };
    // AppImage: çalışma zamanı kendini `/tmp/.mount_*` altına bağlar (ya da `--appimage-extract-and-run` ile `/tmp/appimage_extracted_*` altına açar).
    if (std.mem.indexOf(u8, install_root, "/.mount_") != null or std.mem.indexOf(u8, install_root, "/appimage_extracted_") != null)
        return .{ .name = "AppImage", .update_hint = "download a newer .AppImage from https://github.com/mburakmmm/nox-lang/releases" };
    return null;
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

fn tmpRoot(io: Io, tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    const n = try tmp.dir.realPath(io, buf);
    return buf[0..n];
}

test "asideName: .old, .old1, .old2 ... sirasiyla uretilir" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("bin/noxc.old", asideName(&buf, "bin/noxc", 0));
    try std.testing.expectEqualStrings("bin/noxc.old1", asideName(&buf, "bin/noxc", 1));
    try std.testing.expectEqualStrings("bin/noxc.old7", asideName(&buf, "bin/noxc", 7));
}

test "installFromScratch: bin ve lib dosyalarini degistirir, kullanici dosyasina dokunmaz" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    var new_tree = std.testing.tmpDir(.{ .iterate = true });
    defer new_tree.cleanup();
    var install = std.testing.tmpDir(.{ .iterate = true });
    defer install.cleanup();

    const exe = BIN_EXE_NAMES[0];
    const exe_rel = try std.fmt.allocPrint(a, "bin/{s}", .{exe});
    const stale_rel = try std.fmt.allocPrint(a, "bin/{s}.old", .{exe});
    try new_tree.dir.createDirPath(io, "bin");
    try new_tree.dir.createDirPath(io, "lib/nox");
    try new_tree.dir.writeFile(io, .{ .sub_path = exe_rel, .data = "NEW-BIN" });
    try new_tree.dir.writeFile(io, .{ .sub_path = "lib/nox/x.nox", .data = "NEW-LIB" });

    try install.dir.createDirPath(io, "bin");
    try install.dir.createDirPath(io, "lib/nox");
    try install.dir.writeFile(io, .{ .sub_path = exe_rel, .data = "OLD-BIN" });
    try install.dir.writeFile(io, .{ .sub_path = "lib/nox/x.nox", .data = "OLD-LIB" });
    try install.dir.writeFile(io, .{ .sub_path = stale_rel, .data = "STALE" });
    try install.dir.writeFile(io, .{ .sub_path = "notes.old", .data = "KEEP" });

    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, &install, &root_buf);
    try installFromScratch(a, io, new_tree.dir, install.dir, root);

    try std.testing.expectEqualStrings("NEW-BIN", try install.dir.readFileAlloc(io, exe_rel, a, .limited(1024)));
    try std.testing.expectEqualStrings("NEW-LIB", try install.dir.readFileAlloc(io, "lib/nox/x.nox", a, .limited(1024)));
    try std.testing.expectEqualStrings("KEEP", try install.dir.readFileAlloc(io, "notes.old", a, .limited(1024)));
    // Windows: önceki yükseltmeden kalan "STALE" silinir, yerine ESKİ ikili kenara alınmış olarak durur (geri alma kopyası).
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("OLD-BIN", try install.dir.readFileAlloc(io, stale_rel, a, .limited(1024)));
    }
}

test "replaceFile (Windows): yuklu bir imaj kilitliyken de degistirir" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const win = struct {
        extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
        extern "kernel32" fn FreeLibrary(h: *anyopaque) callconv(.winapi) i32;
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    var new_tree = std.testing.tmpDir(.{ .iterate = true });
    defer new_tree.cleanup();
    var install = std.testing.tmpDir(.{ .iterate = true });
    defer install.cleanup();

    const system_dll = "C:\\Windows\\System32\\winmm.dll";
    try install.dir.createDirPath(io, "bin");
    try new_tree.dir.createDirPath(io, "bin");
    try new_tree.dir.writeFile(io, .{ .sub_path = "bin\\locked.dll", .data = "NEW-BIN" });
    try std.Io.Dir.copyFileAbsolute(system_dll, try std.fs.path.join(a, &.{ try tmpRootAlloc(a, io, &install), "bin", "locked.dll" }), io, .{});

    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, &install, &root_buf);
    const loaded_path = try std.fs.path.join(a, &.{ root, "bin", "locked.dll" });
    const loaded_w = try std.unicode.utf8ToUtf16LeAllocZ(a, loaded_path);
    // Yüklü imaj (çalışan .exe ile AYNI kilit): yazma için açılamaz.
    const handle = win.LoadLibraryW(loaded_w.ptr) orelse return error.LoadLibraryFailed;
    defer _ = win.FreeLibrary(handle);

    // Önceki yükseltmeden kalan (kilitsiz) `.old` üzerine yazılır.
    try install.dir.writeFile(io, .{ .sub_path = "bin\\locked.dll.old", .data = "BLOCKER" });

    try replaceFile(a, io, new_tree.dir, install.dir, root, "bin\\locked.dll", true);
    try std.testing.expectEqualStrings("NEW-BIN", try install.dir.readFileAlloc(io, "bin\\locked.dll", a, .limited(1024)));
}

fn tmpRootAlloc(a: Allocator, io: Io, tmp: *std.testing.TmpDir) ![]const u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    return try a.dupe(u8, try tmpRoot(io, tmp, &buf));
}

test "managedBy: Homebrew, pacman, snap ve AppImage taninir, diger yollar serbesttir" {
    const brew = managedBy("/opt/homebrew/Cellar/noxc/2.0.136/libexec") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Homebrew", brew.name);
    try std.testing.expect(std.mem.indexOf(u8, brew.update_hint, "brew upgrade noxc") != null);
    try std.testing.expect(managedBy("/home/u/linuxbrew/.linuxbrew/Cellar/noxc/1/libexec") != null);

    const aur = managedBy("/usr/lib/noxc") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, aur.name, "pacman") != null);
    try std.testing.expect(std.mem.indexOf(u8, aur.update_hint, "yay -Syu noxc-bin") != null);
    try std.testing.expect(managedBy("/usr/lib/noxcfoo") == null);

    const snap = managedBy("/snap/noxc/123") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("snap", snap.name);
    try std.testing.expect(std.mem.indexOf(u8, snap.update_hint, "snap refresh noxc") != null);
    try std.testing.expect(managedBy("/var/lib/snapd/snap/noxc/123") != null);
    try std.testing.expect(managedBy("/snap/other/1") == null);

    const appimage = managedBy("/tmp/.mount_noxc-2AbCdE/usr") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("AppImage", appimage.name);
    try std.testing.expect(managedBy("/tmp/appimage_extracted_0123abcd/usr") != null);

    try std.testing.expect(managedBy("/Users/u/.nox-lang") == null);
    try std.testing.expect(managedBy("/usr/local") == null);
}

test "pickLatestStable: en yuksek kararli surumu secer; taslak/on surum/duzensiz etiketleri atlar; siralama karisik olabilir" {
    const a = std.testing.allocator;
    const body =
        \\[{"tag_name":"v2.1.43"},{"tag_name":"v2.1.46","draft":true},{"tag_name":"v2.2.0-rc.1"},{"tag_name":"v2.1.45"},{"tag_name":"v2.1.9"},{"tag_name":"nightly"},{"tag_name":"v3.0.0","prerelease":true},{"tag_name":"v2.1.44"}]
    ;
    const got = try pickLatestStable(a, body);
    defer a.free(got);
    try std.testing.expectEqualStrings("v2.1.45", got);
}

test "pickLatestStable: yalnizca uygun olmayanlar varsa hata" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UpgradeVersionResolutionFailed, pickLatestStable(a, "[{\"tag_name\":\"v1.0.0\",\"draft\":true}]"));
    try std.testing.expectError(error.UpgradeVersionResolutionFailed, pickLatestStable(a, "{ bozuk json"));
}

test "parseStableTag / compareSemVer: 10 > 9 sayisal karsilastirma" {
    try std.testing.expect(parseStableTag("v2.1.x") == null);
    try std.testing.expect(parseStableTag("2.1.3") == null);
    try std.testing.expect(compareSemVer(parseStableTag("v2.1.10").?, parseStableTag("v2.1.9").?) == .gt);
}
