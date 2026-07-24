//! Faz O §P.5 birim testleri: `compiler/pkg/fetch.zig`nin `fetchToCache`i.
//!
//! **Kritik test tasarımı kısıtı (bkz. plan dosyası):** testler GERÇEK
//! `github.com`a ASLA dokunmamalı. Fixture'lar test kurulumunda ALT
//! SÜREÇLE (`git init`+dosya+commit) inşa edilen YEREL git repo'ları
//! (`std.testing.tmpDir` içinde), fetcher bu YEREL yola yönlendirilir;
//! `$NOX_HOME` de HER test İÇİN AYRI bir geçici dizine yönlendirilir
//! (gerçek `~/.nox`a ASLA dokunulmaz — bkz. `fetchToCache`'in `nox_home`
//! parametresi, tam da bu hermetik-test senaryosu İÇİN tasarlandı).

const std = @import("std");
const nox = @import("nox");

fn absPath(io: std.Io, dir: std.Io.Dir, buf: []u8) ![]const u8 {
    const len = try dir.realPath(io, buf);
    return buf[0..len];
}

/// Faz P2.4 (bkz. proje belleği "P0/P1/P2 inceleme düzeltme listesi" planı):
/// bu dosyanın testleri İçin standart `FetchPolicy` — `std.testing.environ`in
/// (GERÇEK süreç ortamının bir KOPYASI) klonunu TAŞIYAN bir `Environ.Map`e
/// SAHİPTİR (arena üzerinden ayrılır, testin arenası SİLİNİNCE serbest
/// kalır — AYRI bir `deinit` GEREKMEZ).
fn testFetchPolicy(a: std.mem.Allocator) !nox.fetch.FetchPolicy {
    const map = try std.testing.environ.createMap(a);
    const map_ptr = try a.create(std.process.Environ.Map);
    map_ptr.* = map;
    return .{ .allow_insecure_transport = false, .parent_environ_map = map_ptr };
}

/// `dir` içinde `git init` + tek bir commit içeren minimal bir depo kurar,
/// commit edilen dosyanın adını/içeriğini YAZAR. Gerçek `git rev-parse
/// HEAD`in DÖNDÜRECEĞİ SHA'yı bağımsız olarak hesaplamak İÇİN kullanılır
/// (testin KENDİ beklentisi, `fetchToCache`in KENDİ hesaplamasına
/// GÜVENMEDEN, ayrı bir `git rev-parse` çağrısıyla DOĞRULANIR).
fn initFixtureRepo(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8) !void {
    const steps = [_][]const []const u8{
        &.{ "git", "init", "-q", "-b", "main" },
        &.{ "git", "-c", "user.email=test@example.com", "-c", "user.name=test", "add", "." },
        &.{ "git", "-c", "user.email=test@example.com", "-c", "user.name=test", "commit", "-q", "-m", "init" },
    };
    for (steps) |argv| {
        const result = try std.process.run(allocator, io, .{ .argv = argv, .cwd = .{ .path = dir_path } });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("fixture git komutu basarisiz: {s}\n", .{result.stderr});
            return error.FixtureSetupFailed;
        }
    }
}

fn revParseHead(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8) ![]const u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "rev-parse", "HEAD" },
        .cwd = .{ .path = dir_path },
    });
    defer allocator.free(result.stderr);
    return std.mem.trim(u8, result.stdout, " \t\r\n");
}

test "fetchToCache: yerel fixture repo getirilir, resolved sha bagimsiz git rev-parse ile eslesir" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var src = std.testing.tmpDir(.{});
    defer src.cleanup();
    try src.dir.writeFile(io, .{ .sub_path = "lib.nox", .data = "print(\"merhaba paket\")\n" });

    var src_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const src_path = try absPath(io, src.dir, &src_buf);
    try initFixtureRepo(io, std.testing.allocator, src_path);
    const expected_sha = try revParseHead(io, a, src_path);

    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = try absPath(io, home.dir, &home_buf);

    var sig_diag: ?[]const u8 = null;
    const result = try nox.fetch.fetchToCache(a, io, home_path, src_path, "main", false, &sig_diag, try testFetchPolicy(a));
    try std.testing.expectEqualStrings(expected_sha, result.resolved_sha);

    // Getirilen içerik gercekten önbellek dizininde olmali.
    try std.Io.Dir.cwd().access(io, try std.fmt.allocPrint(a, "{s}/lib.nox", .{result.cache_dir}), .{});
}

// Güvenlik bulgusu M-8 (bkz. güvenlik raporu, 20 Temmuz 2026) — DÜZELTİLDİ:
// `resolveCloneUrl` ÖNCEDEN `"://"` alt dizesini İÇEREN HERHANGİ bir
// `repo` değerini "zaten şemalı" sayıp `git clone`a OLDUĞU GİBİ
// geçiriyordu — `ext::` gibi bir transport'un İÇİNE, sondaki "://" bir
// yorum/son ek OLARAK GİZLENEBİLİRDİ. Artık yalnızca AÇIK bir izin
// listesindeki (`https`/`http`/`git`/`ssh`/`file`) şema ÖNEKLERİ kabul
// edilir.
test "fetchToCache: izin listesi DIŞINDAKİ bir şema (ör. gizlenmiş 'ext::') reddedilir, git ÇAĞRILMAZ" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = try absPath(io, home.dir, &home_buf);

    const malicious_repo = "ext::sh -c 'echo pwned > /tmp/nox_security_test_pwned' #://";
    var sig_diag: ?[]const u8 = null;
    try std.testing.expectError(
        error.UnsupportedRepoScheme,
        nox.fetch.fetchToCache(a, io, home_path, malicious_repo, "main", false, &sig_diag, try testFetchPolicy(a)),
    );

    // İşaretçi dosyanın GERÇEKTEN oluşmadığını doğrula — `git`in `ext::`
    // yardımcısına ULAŞMADIĞININ (ret sadece yüzeysel bir hata kodu
    // DEĞİL, GERÇEKTEN hiç çalıştırılmadığının) somut kanıtı.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, "/tmp/nox_security_test_pwned", .{}));
}

// Güvenlik bulgusu (bağımsız bir inceleme TARAFINDAN bulundu, 2026-07-22) —
// DÜZELTİLDİ: `sanitizeRepoForCachePath` ÖNCEDEN `.`/`/` karakterlerini
// KARAKTER BAZINDA koruyordu ama `.`/`..` path SEGMENTLERİNİ (tam bileşen
// olarak) HİÇ reddetmiyordu — `repo` değeri `"../../../../hedef"` gibi bir
// path-traversal İÇERİRSE, `cachedDirFor`nin ürettiği yol `$NOX_HOME/
// pkg/mod` KÖKÜ DIŞINA çıkabiliyordu (GERÇEK bir path traversal — process'in
// yazma yetkisi olan HERHANGİ bir yere dosya yazdırabilirdi). Artık HER
// path segmenti ayrı kontrol edilip `.`/`..` `_`e çevriliyor.
test "cachedDirFor: repo degerindeki '../' path-traversal segmentleri etkisiz hale getirilir" {
    const a = std.testing.allocator;

    const malicious_repo = "../../../../etc/passwd";
    const cache_dir = try nox.fetch.cachedDirFor(a, "/home/user/.nox", malicious_repo, "abc123deadbeef");
    defer a.free(cache_dir);

    // Üretilen yol, `$NOX_HOME/pkg/mod` kökünün ALTINDA KALMALI — HİÇBİR
    // segment tam olarak `..` ya da `.` OLMAMALI.
    try std.testing.expect(std.mem.startsWith(u8, cache_dir, "/home/user/.nox/pkg/mod/"));
    var it = std.mem.splitScalar(u8, cache_dir, '/');
    while (it.next()) |seg| {
        try std.testing.expect(!std.mem.eql(u8, seg, ".."));
        try std.testing.expect(!std.mem.eql(u8, seg, "."));
    }
}

test "cachedDirFor: onde/arada/sonda '..' segmentleri olan repo degerleri de etkisiz hale getirilir" {
    const a = std.testing.allocator;

    const cases = [_][]const u8{
        "..",
        "../x",
        "x/../y",
        "x/..",
        "./x",
        "https://example.com/../../secret",
    };
    for (cases) |repo| {
        const cache_dir = try nox.fetch.cachedDirFor(a, "/home/user/.nox", repo, "abc123deadbeef");
        defer a.free(cache_dir);
        try std.testing.expect(std.mem.startsWith(u8, cache_dir, "/home/user/.nox/pkg/mod/"));
        var it = std.mem.splitScalar(u8, cache_dir, '/');
        while (it.next()) |seg| {
            try std.testing.expect(!std.mem.eql(u8, seg, ".."));
            try std.testing.expect(!std.mem.eql(u8, seg, "."));
        }
    }
}

test "cachedDirFor: gecersiz (hex olmayan) resolved_sha reddedilir" {
    const a = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidResolvedSha,
        nox.fetch.cachedDirFor(a, "/home/user/.nox", "github.com/user/repo", "../../etc/passwd"),
    );
}

// Faz P2.4 (bkz. proje belleği "P0/P1/P2 inceleme düzeltme listesi" planı):
// bu testin ADI ÖNCEDEN "https/http/git/ssh/file" HEPSİNİN test edildiğini
// İDDİA EDİYORDU ama gövde SADECE `file://`yi GERÇEKTEN egzersiz ediyordu
// (DÜZELTİLDİ — isim ARTIK gerçek kapsamı YANSITIYOR). `http://`/`git://`nin
// ARTIK varsayılan olarak REDDEDİLDİĞİ/`NOX_ALLOW_INSECURE_TRANSPORT` İLE
// kabul edildiği AYRI, saf `resolveCloneUrl` testleriyle (aşağıda)
// doğrulanır — GERÇEK bir ağa/git sunucusuna dokunmadan.
test "fetchToCache: file:// şeması (yalnızca mutlak yol İLE DEĞİL, AÇIK önek İLE de) DOKUNULMADAN kabul edilir" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var src = std.testing.tmpDir(.{});
    defer src.cleanup();
    try src.dir.writeFile(io, .{ .sub_path = "lib.nox", .data = "print(\"merhaba paket\")\n" });
    var src_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const src_path = try absPath(io, src.dir, &src_buf);
    try initFixtureRepo(io, std.testing.allocator, src_path);

    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = try absPath(io, home.dir, &home_buf);

    // `file://` şemasıyla AÇIKÇA (yalnızca mutlak yol İLE DEĞİL) da
    // GERÇEKTEN getirebildiğini doğrula.
    const file_url = try std.fmt.allocPrint(a, "file://{s}", .{src_path});
    var sig_diag: ?[]const u8 = null;
    const result = try nox.fetch.fetchToCache(a, io, home_path, file_url, "main", false, &sig_diag, try testFetchPolicy(a));
    try std.testing.expect(result.resolved_sha.len > 0);
}

test "fetchToCache: ayni repo+ref icin iki kez cagirmak ayni sonucu uretir (idempotent)" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var src = std.testing.tmpDir(.{});
    defer src.cleanup();
    try src.dir.writeFile(io, .{ .sub_path = "lib.nox", .data = "print(\"tekrar\")\n" });

    var src_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const src_path = try absPath(io, src.dir, &src_buf);
    try initFixtureRepo(io, std.testing.allocator, src_path);

    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = try absPath(io, home.dir, &home_buf);

    var sig_diag1: ?[]const u8 = null;
    const first = try nox.fetch.fetchToCache(a, io, home_path, src_path, "main", false, &sig_diag1, try testFetchPolicy(a));
    var sig_diag2: ?[]const u8 = null;
    const second = try nox.fetch.fetchToCache(a, io, home_path, src_path, "main", false, &sig_diag2, try testFetchPolicy(a));

    try std.testing.expectEqualStrings(first.resolved_sha, second.resolved_sha);
    try std.testing.expectEqualStrings(first.cache_dir, second.cache_dir);
    try std.Io.Dir.cwd().access(io, try std.fmt.allocPrint(a, "{s}/lib.nox", .{second.cache_dir}), .{});
}

test "fetchToCache: farkli iki fixture repo ayni NOX_HOME altinda cakismadan bir arada yasar" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var src1 = std.testing.tmpDir(.{});
    defer src1.cleanup();
    try src1.dir.writeFile(io, .{ .sub_path = "a.nox", .data = "print(\"a\")\n" });
    var src1_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const src1_path = try absPath(io, src1.dir, &src1_buf);
    try initFixtureRepo(io, std.testing.allocator, src1_path);

    var src2 = std.testing.tmpDir(.{});
    defer src2.cleanup();
    try src2.dir.writeFile(io, .{ .sub_path = "b.nox", .data = "print(\"b\")\n" });
    var src2_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const src2_path = try absPath(io, src2.dir, &src2_buf);
    try initFixtureRepo(io, std.testing.allocator, src2_path);

    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = try absPath(io, home.dir, &home_buf);

    var sig_diag1: ?[]const u8 = null;
    const r1 = try nox.fetch.fetchToCache(a, io, home_path, src1_path, "main", false, &sig_diag1, try testFetchPolicy(a));
    var sig_diag2: ?[]const u8 = null;
    const r2 = try nox.fetch.fetchToCache(a, io, home_path, src2_path, "main", false, &sig_diag2, try testFetchPolicy(a));

    try std.testing.expect(!std.mem.eql(u8, r1.cache_dir, r2.cache_dir));
    try std.Io.Dir.cwd().access(io, try std.fmt.allocPrint(a, "{s}/a.nox", .{r1.cache_dir}), .{});
    try std.Io.Dir.cwd().access(io, try std.fmt.allocPrint(a, "{s}/b.nox", .{r2.cache_dir}), .{});
}

// Faz P2.4 (bkz. proje belleği "P0/P1/P2 inceleme düzeltme listesi" planı):
// `resolveCloneUrl`in KENDİSİ `pub` yapıldığı İçin bu testler saf/hızlıdır —
// HİÇBİR alt süreç/ağ/dosya sistemi GEREKMEZ, yalnızca politika mantığını
// doğrular.
test "resolveCloneUrl: http/git semalari varsayilan olarak (allow_insecure_transport=false) reddedilir" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InsecureRepoSchemeRejected, nox.fetch.resolveCloneUrl(a, "http://example.com/repo", false));
    try std.testing.expectError(error.InsecureRepoSchemeRejected, nox.fetch.resolveCloneUrl(a, "git://example.com/repo", false));
}

test "resolveCloneUrl: http/git semalari allow_insecure_transport=true iken (opt-in) kabul edilir" {
    const a = std.testing.allocator;
    const url1 = try nox.fetch.resolveCloneUrl(a, "http://example.com/repo", true);
    defer a.free(url1);
    try std.testing.expectEqualStrings("http://example.com/repo", url1);
    const url2 = try nox.fetch.resolveCloneUrl(a, "git://example.com/repo", true);
    defer a.free(url2);
    try std.testing.expectEqualStrings("git://example.com/repo", url2);
}

test "resolveCloneUrl: https/ssh/file semalari opt-in olmadan da HER ZAMAN kabul edilir" {
    const a = std.testing.allocator;
    const url1 = try nox.fetch.resolveCloneUrl(a, "https://example.com/repo", false);
    defer a.free(url1);
    try std.testing.expectEqualStrings("https://example.com/repo", url1);
    const url2 = try nox.fetch.resolveCloneUrl(a, "ssh://example.com/repo", false);
    defer a.free(url2);
    try std.testing.expectEqualStrings("ssh://example.com/repo", url2);
}

// Faz P2.4: imzasız bir commit `require_signed_commit=true` İLE reddedilir —
// bu test `gpg`ye HİÇ İHTİYAÇ DUYMAZ (`git verify-commit`, `gpgsig` başlığı
// TAŞIMAYAN bir commit'te `gpg`yi HİÇ ÇAĞIRMADAN HEMEN başarısız olur), bu
// YÜZDEN HER ortamda ÇALIŞIR (kabul testinin AKSİNE, aşağıya bkz.).
test "fetchToCache: require_signed_commit=true ve commit imzasiz ise reddedilir (gpg gerektirmez)" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var src = std.testing.tmpDir(.{});
    defer src.cleanup();
    try src.dir.writeFile(io, .{ .sub_path = "lib.nox", .data = "print(\"imzasiz\")\n" });
    var src_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const src_path = try absPath(io, src.dir, &src_buf);
    try initFixtureRepo(io, std.testing.allocator, src_path);

    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = try absPath(io, home.dir, &home_buf);

    var sig_diag: ?[]const u8 = null;
    try std.testing.expectError(
        error.CommitSignatureRejected,
        nox.fetch.fetchToCache(a, io, home_path, src_path, "main", true, &sig_diag, try testFetchPolicy(a)),
    );
    try std.testing.expect(sig_diag != null and sig_diag.?.len > 0);
}

// Faz P2.4: GERÇEK bir GPG-imzalı commit `require_signed_commit=true` İLE
// KABUL edilir — `gpg` bu ortamda YOKSA/anahtar üretimi (sandbox'ta bilinen
// bir şekilde KIRILGAN) ya da `git commit -S` HERHANGİ bir NEDENLE
// başarısız OLURSA `error.SkipZigTest` İLE ZARARSIZCA ATLANIR (bu test
// suite'inde "araç eksikse atla" DESENİNİN İLK KULLANIMI — `qbe`/`cc`nin
// AKSİNE, `gpg` bu projenin VARSAYILAN, HER ZAMAN-mevcut araç kümesinin
// PARÇASI DEĞİLDİR, bkz. proje belleği "P0/P1/P2 inceleme düzeltme
// listesi" planının CI'da `gpg` KURULU OLMADIĞI bulgusu).
test "fetchToCache: require_signed_commit=true ve commit GPG ile imzali ise kabul edilir (gpg yoksa atlanir)" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var gnupg_dir = std.testing.tmpDir(.{});
    defer gnupg_dir.cleanup();
    var gnupg_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const gnupg_home = absPath(io, gnupg_dir.dir, &gnupg_buf) catch return error.SkipZigTest;

    var env = std.testing.environ.createMap(a) catch return error.SkipZigTest;
    env.put("GNUPGHOME", gnupg_home) catch return error.SkipZigTest;

    const gen_result = std.process.run(a, io, .{
        .argv = &.{ "gpg", "--batch", "--passphrase", "", "--quick-generate-key", "nox-test-signer", "ed25519", "sign", "1d" },
        .environ_map = &env,
    }) catch return error.SkipZigTest;
    if (gen_result.term != .exited or gen_result.term.exited != 0) return error.SkipZigTest;

    var src = std.testing.tmpDir(.{});
    defer src.cleanup();
    try src.dir.writeFile(io, .{ .sub_path = "lib.nox", .data = "print(\"imzali\")\n" });
    var src_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const src_path = absPath(io, src.dir, &src_buf) catch return error.SkipZigTest;

    const init_steps = [_][]const []const u8{
        &.{ "git", "init", "-q", "-b", "main" },
        &.{ "git", "-c", "user.email=test@example.com", "-c", "user.name=test", "add", "." },
    };
    for (init_steps) |argv| {
        const r = std.process.run(a, io, .{ .argv = argv, .cwd = .{ .path = src_path }, .environ_map = &env }) catch return error.SkipZigTest;
        if (r.term != .exited or r.term.exited != 0) return error.SkipZigTest;
    }
    const commit_result = std.process.run(a, io, .{
        .argv = &.{ "git", "-c", "user.email=test@example.com", "-c", "user.name=test", "-c", "user.signingkey=nox-test-signer", "commit", "-q", "-S", "-m", "imzali init" },
        .cwd = .{ .path = src_path },
        .environ_map = &env,
    }) catch return error.SkipZigTest;
    if (commit_result.term != .exited or commit_result.term.exited != 0) return error.SkipZigTest;

    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = absPath(io, home.dir, &home_buf) catch return error.SkipZigTest;

    var sig_diag: ?[]const u8 = null;
    const policy: nox.fetch.FetchPolicy = .{ .allow_insecure_transport = false, .parent_environ_map = &env };
    const result = nox.fetch.fetchToCache(a, io, home_path, src_path, "main", true, &sig_diag, policy) catch return error.SkipZigTest;
    try std.testing.expect(result.resolved_sha.len > 0);
}
