//! Faz O §P.5 (bkz. plan dosyası "Faz O" bölümü, nox-teknik-spesifikasyon.md
//! §3.6): `git` alt sürecine dayanan üçüncü-taraf paket getirme + yerel
//! (SHA ile anahtarlanmış, içerik-adresli) modül önbelleği.
//!
//! **Neden `git` alt süreci (gömülü bir Zig HTTP istemcisi/tarball+extract
//! DEĞİL):** projenin ZATEN `qbe`/`cc`yi alt süreç olarak çağırma
//! hassasiyetiyle TUTARLI; `git` ÖZEL repo/SSH/HTTPS kimlik doğrulamasını
//! BEDAVA halleder; `git rev-parse HEAD` çözülmüş SHA'yı BEDAVA verir (bir
//! tarball yaklaşımı AYRI bir `api.github.com` çağrısı gerektirirdi).
//! `runtime/stdlib_shims/http_client.zig`nin `std.http.Client`ı BAŞKA bir
//! katman (derlenmiş Nox PROGRAMLARI çalışma zamanı İÇİN) — bununla
//! KARIŞTIRILMAZ.
//!
//! **Bilinçli olarak SALT GETİRME + ÖNBELLEKLEME:** bu dosya `nox.lock`a
//! HİÇ dokunmaz (P.4'ün `project.saveLockfile`i BURADAN çağrılmaz) — bu,
//! ÇAĞIRANIN (Faz O §P.6) sorumluluğunda: `fetchToCache` yalnızca
//! ÇÖZÜLMÜŞ SHA'yı VE önbellek dizinini döner, lockfile güncellemesi
//! kararı (ne zaman yazılacağı, hangi alias'a karşılık geldiği) resolver
//! katmanına BIRAKILIR.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const FetchResult = struct {
    resolved_sha: []const u8,
    cache_dir: []const u8,
};

/// `runGit`in en sık BEKLENEN başarısızlığı — DİĞER (dosya sistemi/
/// bellek) hatalar `!FetchResult`in ÇIKARSANAN hata kümesine bırakılır
/// (bkz. `fetchToCache`'in imzası — sabit bir `FetchError` yerine `!`
/// kullanılması, her bir alt-çağrının (`createDirPath`/`renameAbsolute`/
/// `std.process.run` vb.) TAM hata kümesini elle SENKRONİZE tutma
/// kırılganlığından KAÇINIR, bu proje genelinde `project.zig`nin
/// `resolveResourceDirs`i GİBİ diğer fonksiyonların da izlediği desen).
pub const GitError = error{GitCommandFailed};

/// `repo`yu (`nox.json`'ın `requires[].repo`si — ör. `"github.com/user/repo"`,
/// AMA testlerde GERÇEK ağa dokunmamak İÇİN yerel bir dosya yolu/`file://`
/// URL'si DE olabilir) ve `ref`i (tag/branch/commit SHA'sı) alıp, `$nox_home/
/// pkg/mod/<sanitize edilmiş repo>/<çözülmüş sha>/` altına GETİRİR
/// (ZATEN önbellekteyse yeniden İNDİRMEZ). Döndürülen `cache_dir`, o
/// dizinin İÇİNDEKİ (repo'nun KENDİ kök dizini gibi davranan) tam yoldur.
pub fn fetchToCache(a: Allocator, io: Io, nox_home: []const u8, repo: []const u8, ref: []const u8) !FetchResult {
    const clone_url = try resolveCloneUrl(a, repo);

    var suffix_bytes: [8]u8 = undefined;
    io.random(&suffix_bytes);
    const suffix = std.mem.readInt(u64, &suffix_bytes, .little);
    const staging_dir = try std.fmt.allocPrint(a, "{s}/pkg/tmp/stage-{x}", .{ nox_home, suffix });
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(staging_dir).?);

    // `ref` bir commit SHA'sı GİBİ mi görünüyor (yalnızca hex karakterler,
    // >= 7 uzunlukta — kısaltılmış SHA'lar da geçerlidir) yoksa bir
    // tag/branch mı? SHA'YSA sığ (shallow) klon çoğu git sunucusunda
    // DESTEKLENMEZ (`uploadpack.allowReachableSHA1InWant` GEREKİR) — TAM
    // klon + `checkout` gerekir. **Bilinçli sınırlama:** bu, tamamen
    // hex karakterlerden oluşan bir BRANCH/TAG adını (ör. `"abc123"`)
    // YANLIŞLIKLA SHA sanabilir — nadir ama olası bir isimlendirme
    // çakışması, v1 kapsamında kabul edildi.
    const looks_like_sha = ref.len >= 7 and isAllHex(ref);

    if (looks_like_sha) {
        _ = try runGit(a, io, &.{ "clone", clone_url, staging_dir }, null);
        _ = try runGit(a, io, &.{ "checkout", ref }, staging_dir);
    } else {
        _ = try runGit(a, io, &.{ "clone", "--depth", "1", "--branch", ref, clone_url, staging_dir }, null);
    }

    const rev_parse_out = try runGit(a, io, &.{ "rev-parse", "HEAD" }, staging_dir);
    const resolved_sha = try a.dupe(u8, std.mem.trim(u8, rev_parse_out, " \t\r\n"));

    const cache_dir = try cachedDirFor(a, nox_home, repo, resolved_sha);

    if (std.Io.Dir.accessAbsolute(io, cache_dir, .{})) |_| {
        // Önbellekte ZATEN var — staging klonu GEREKSİZ, at.
        std.Io.Dir.cwd().deleteTree(io, staging_dir) catch {};
    } else |_| {
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(cache_dir).?);
        try std.Io.Dir.renameAbsolute(staging_dir, cache_dir, io);
    }

    return .{ .resolved_sha = resolved_sha, .cache_dir = cache_dir };
}

/// Güvenlik bulgusu M-8 (bkz. güvenlik raporu, 20 Temmuz 2026) — bkz.
/// `resolveCloneUrl`nin ARTIK güncellenmiş belge notu.
const allowed_repo_schemes = [_][]const u8{ "https://", "http://", "git://", "ssh://", "file://" };

/// `repo` zaten BİR ÖNEK olarak (bkz. `allowed_repo_schemes`) bilinen/
/// güvenli bir şemayla BAŞLIYORSA DOKUNULMADAN döner (testlerin yerel
/// `file://` fixture repo'ları DAHİL); mutlak bir yerel yol İSE de
/// DOKUNULMADAN döner; aksi halde (ör. `"github.com/user/repo"`)
/// `https://` öneki eklenir.
///
/// **Güvenlik bulgusu M-8 (bkz. güvenlik raporu) — DÜZELTİLDİ:** ÖNCEKİ
/// sürüm `"://"` alt dizesini İÇEREN HERHANGİ bir `repo` değerini (yalnızca
/// `startsWith` DEĞİL, `indexOf` İLE — dizenin HERHANGİ bir YERİNDE)
/// "zaten şemalı" sayıp `git clone`a OLDUĞU GİBİ geçiriyordu. Bir manifest
/// alanı (`nox.json`nin `requires[].repo`si) saldırgan etkisindeyse, ör.
/// `"ext::sh -c 'kötücül komut' #://"` gibi bir değer "://" İÇERDİĞİNDEN
/// (sondaki YORUM-benzeri son ek İÇİNDE) DOKUNULMADAN `git clone`a
/// geçirilir, git'in `ext::` transport yardımcısı (ETKİNLEŞTİRİLMİŞSE —
/// bugün varsayılan DEĞİL ama `protocol.ext.allow` İLE değişebilir/eski
/// git sürümlerinde farklı olabilir) KEYFİ komut YÜRÜTEBİLİRDİ. Şimdi
/// yalnızca AÇIK bir İZİN LİSTESİNDEKİ (`https`/`http`/`git`/`ssh`/`file`)
/// şema ÖNEKLERİ kabul edilir — `ext::` DAHİL başka HİÇBİR transport
/// KABUL EDİLMEZ, git'in KENDİ (dış, güvenilemez) varsayılanlarına
/// GÜVENİLMEZ.
fn resolveCloneUrl(a: Allocator, repo: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, repo, "://") != null) {
        for (allowed_repo_schemes) |scheme| {
            if (std.mem.startsWith(u8, repo, scheme)) return a.dupe(u8, repo);
        }
        return error.UnsupportedRepoScheme;
    }
    if (std.fs.path.isAbsolute(repo)) return a.dupe(u8, repo);
    return std.fmt.allocPrint(a, "https://{s}", .{repo});
}

/// `repo`yu önbellek dizini İÇİN güvenli bir GÖRELİ yola dönüştürür — şema
/// öneki (`"https://"`/`"file://"`) VE baştaki `/` (mutlak yerel yollar
/// İÇİN) atılır, yalnızca alfasayısal/`.`/`-`/`_`/`/` karakterleri
/// KORUNUR (geri kalanı `_`e çevrilir) — böylece HEM okunabilir bir
/// `github.com/user/repo` yapısı KORUNUR HEM de rastgele bir yerel test
/// yolu/URL asla geçersiz/tehlikeli bir dizin bileşeni ÜRETEMEZ.
fn sanitizeRepoForCachePath(a: Allocator, repo: []const u8) ![]const u8 {
    var s = repo;
    if (std.mem.indexOf(u8, s, "://")) |idx| s = s[idx + 3 ..];
    while (s.len > 0 and s[0] == '/') s = s[1..];

    const buf = try a.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        buf[i] = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_', '/' => c,
            else => '_',
        };
    }
    return buf;
}

/// `fetchToCache`in İÇİNDE hesapladığı `cache_dir` yolunu, GİT'E hiç
/// dokunmadan (SALT string birleştirme) yeniden hesaplar — Faz O §P.6'nın
/// resolver'ının "bu bağımlılık ZATEN `nox.lock`ta kilitli VE önbellek
/// dizini HÂLÂ diskte mi?" sorusunu, `fetchToCache`i (dolayısıyla `git`i)
/// HİÇ ÇAĞIRMADAN yanıtlayabilmesi İÇİN dışa açılır.
pub fn cachedDirFor(a: Allocator, nox_home: []const u8, repo: []const u8, resolved_sha: []const u8) ![]const u8 {
    const cache_subpath = try sanitizeRepoForCachePath(a, repo);
    return std.fmt.allocPrint(a, "{s}/pkg/mod/{s}/{s}", .{ nox_home, cache_subpath, resolved_sha });
}

fn isAllHex(s: []const u8) bool {
    for (s) |c| {
        switch (c) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => return false,
        }
    }
    return true;
}

/// `git <argv_tail>`i çalıştırır (`cwd_path` VERİLMİŞSE O dizinde) —
/// başarısızsa `error.GitCommandFailed`, başarılıysa stdout'u döner.
fn runGit(a: Allocator, io: Io, argv_tail: []const []const u8, cwd_path: ?[]const u8) ![]const u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.append(a, "git");
    try argv.appendSlice(a, argv_tail);

    const result = try std.process.run(a, io, .{
        .argv = argv.items,
        .cwd = if (cwd_path) |c| .{ .path = c } else .inherit,
    });
    if (result.term != .exited or result.term.exited != 0) {
        return error.GitCommandFailed;
    }
    return result.stdout;
}
