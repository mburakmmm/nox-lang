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

/// Faz P2.4 (bkz. proje belleği "P0/P1/P2 inceleme düzeltme listesi" planı):
/// `main()`in BİR KEZ okuyup (`NOX_HOME`/`NOX_RESOURCE_DIR`YLA AYNI desen)
/// AŞAĞI doğru AÇIK bir parametre olarak geçirdiği, bu dosyanın TÜM `git`
/// alt-süreç çağrılarının PAYLAŞTIĞI politika. `fetch.zig`nin KENDİSİ HİÇBİR
/// ortam değişkenini DOĞRUDAN OKUMAZ (bkz. `resolveCloneUrl`nin AYNI notu).
pub const FetchPolicy = struct {
    allow_insecure_transport: bool,
    parent_environ_map: *const std.process.Environ.Map,
};

/// `runGit`in en sık BEKLENEN başarısızlığı — DİĞER (dosya sistemi/
/// bellek) hatalar `!FetchResult`in ÇIKARSANAN hata kümesine bırakılır
/// (bkz. `fetchToCache`'in imzası — sabit bir `FetchError` yerine `!`
/// kullanılması, her bir alt-çağrının (`createDirPath`/`renameAbsolute`/
/// `std.process.run` vb.) TAM hata kümesini elle SENKRONİZE tutma
/// kırılganlığından KAÇINIR, bu proje genelinde `project.zig`nin
/// `resolveResourceDirs`i GİBİ diğer fonksiyonların da izlediği desen).
pub const GitError = error{GitCommandFailed};

/// Faz P2.4: `git verify-commit`in reddettiği (imzasız/güvenilmeyen
/// imzalayan/`gpg` bulunamadı) durum — `GitError`den AYRI TUTULUR çünkü
/// `fetchToCache`nin ÇAĞIRANI (bkz. `main.zig`) BU durumda git'in KENDİ
/// (insan-okunabilir) tanılama metnini (`signature_diagnostic` çıktı
/// parametresi ile) kullanıcıya GÖSTERMEK İSTER — `GitError.GitCommandFailed`
/// İSE kasıtlı olarak OPAK'tır (bkz. `GitError`in AYNI notu).
pub const SignatureError = error{CommitSignatureRejected};

/// Faz P2.4: `runGit`/`verifyCommitSignature`nin PAYLAŞTIĞI, git alt-sürecine
/// geçirilecek ortam DEĞİŞKENLERİNİ inşa eder — ebeveynin (`policy.
/// parent_environ_map`) TAM bir KOPYASI ÜZERİNE `GIT_TERMINAL_PROMPT=0`
/// EKLENEREK. **Sıfırdan (yalnızca bu tek değişkeni İÇEREN) bir harita
/// İNŞA ETMEK YERİNE TAM kopyalama BİLİNÇLİDİR:** git `PATH` (yardımcı
/// ikili dosyaları bulmak İçin), `HOME`/`XDG_CONFIG_HOME` (`.gitconfig`/
/// kimlik bilgisi yardımcıları), `SSH_AUTH_SOCK` (ajan-tabanlı SSH kimlik
/// doğrulaması), olası `http_proxy`/`https_proxy` GEREKTİRİR — sıfırdan
/// bir harita bunların HEPSİNİ SESSİZCE KIRARDI. `GIT_TERMINAL_PROMPT=0`
/// EKLENMESİNİN gerekçesi: git alt-süreci ASLA interaktif bir kimlik
/// doğrulama İSTEMİ GÖSTERMEMELİDİR — `noxc`nin stdin'i çoğu GERÇEKÇİ
/// çağrıda (CI, editör-tetikli derleme, betik) ZATEN bir terminale
/// BAĞLI DEĞİLDİR, bu YÜZDEN BUGÜN erişilen bir istem SONSUZA KADAR
/// ASILI KALIRDI (hiçbir tanılama OLMADAN) — bu değişiklik "sonsuza kadar
/// asılı kal"ı "git'in KENDİ AÇIK stderr metniyle HEMEN başarısız ol"a
/// çevirir, GERÇEKÇİ hiçbir kullanım İçin bir GERİLEME DEĞİLDİR.
fn buildGitChildEnv(a: Allocator, policy: FetchPolicy) !std.process.Environ.Map {
    var env = try policy.parent_environ_map.clone(a);
    try env.put("GIT_TERMINAL_PROMPT", "0");
    return env;
}

/// `staging_dir`deki (ZATEN klonlanmış, HENÜZ önbelleğe taşınmamış) `sha`
/// commit'inin `git verify-commit` İLE İMZASINI doğrular — başarısızsa
/// (imzasız, güvenilmeyen imzalayan, `gpg` bulunamadı) git'in KENDİ
/// stderr metnini `out_diagnostic`e yazıp `error.CommitSignatureRejected`
/// döner. **`runGit`i YENİDEN KULLANMAZ** (KASITLI): `runGit` stderr'i
/// ATAR ve TEK bir opak hata döner (3 mevcut çağrı sitesi İçin YETERLİ) —
/// doğrulama İSE git'in GERÇEK mesajını kullanıcıya GÖSTERMESİ GEREKEN
/// TEK çağrı sitesidir, bu YÜZDEN `runGit`in sözleşmesini HERKES İÇİN
/// değiştirmek YERİNE kendi küçük, ayrı fonksiyonunu alır.
fn verifyCommitSignature(a: Allocator, io: Io, staging_dir: []const u8, sha: []const u8, out_diagnostic: *?[]const u8, policy: FetchPolicy) !void {
    var child_env = try buildGitChildEnv(a, policy);
    defer child_env.deinit();
    const result = try std.process.run(a, io, .{
        .argv = &.{ "git", "-C", staging_dir, "verify-commit", sha },
        .environ_map = &child_env,
    });
    if (result.term != .exited or result.term.exited != 0) {
        // `git verify-commit`, imzasız bir commit İçin (GERÇEK bir denemeyle
        // DOĞRULANDI, git 2.54.0) stdout/stderr'e HİÇBİR ŞEY YAZMADAN
        // yalnızca sıfırdan farklı bir çıkış koduyla döner — bu YÜZDEN
        // `result.stderr` BOŞSA, kullanıcının BOŞ bir tanılama satırı
        // GÖRMEMESİ İçin AÇIK bir yedek mesaj kullanılır.
        out_diagnostic.* = if (result.stderr.len > 0) result.stderr else "git verify-commit basarisiz oldu (commit imzasiz olabilir, imzalayan guvenilir anahtarlar arasinda olmayabilir, ya da 'gpg' bulunamamis olabilir)";
        return error.CommitSignatureRejected;
    }
}

/// `repo`yu (`nox.json`'ın `requires[].repo`si — ör. `"github.com/user/repo"`,
/// AMA testlerde GERÇEK ağa dokunmamak İÇİN yerel bir dosya yolu/`file://`
/// URL'si DE olabilir) ve `ref`i (tag/branch/commit SHA'sı) alıp, `$nox_home/
/// pkg/mod/<sanitize edilmiş repo>/<çözülmüş sha>/` altına GETİRİR
/// (ZATEN önbellekteyse yeniden İNDİRMEZ). Döndürülen `cache_dir`, o
/// dizinin İÇİNDEKİ (repo'nun KENDİ kök dizini gibi davranan) tam yoldur.
/// Faz P2.4: `require_signed_commit` İSE `resolved_sha` hesaplandıktan
/// SONRA, önbelleğe TAŞINMADAN ÖNCE (böylece BAŞARISIZ bir doğrulama
/// ASLA önbelleği KİRLETMEZ) `verifyCommitSignature` çağrılır;
/// başarısızlığı `signature_diagnostic`e YAZAR.
pub fn fetchToCache(a: Allocator, io: Io, nox_home: []const u8, repo: []const u8, ref: []const u8, require_signed_commit: bool, signature_diagnostic: *?[]const u8, policy: FetchPolicy) !FetchResult {
    const clone_url = try resolveCloneUrl(a, repo, policy.allow_insecure_transport);

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
        _ = try runGit(a, io, &.{ "clone", clone_url, staging_dir }, null, policy);
        _ = try runGit(a, io, &.{ "checkout", ref }, staging_dir, policy);
    } else {
        _ = try runGit(a, io, &.{ "clone", "--depth", "1", "--branch", ref, clone_url, staging_dir }, null, policy);
    }

    const rev_parse_out = try runGit(a, io, &.{ "rev-parse", "HEAD" }, staging_dir, policy);
    const resolved_sha = try a.dupe(u8, std.mem.trim(u8, rev_parse_out, " \t\r\n"));

    if (require_signed_commit) {
        try verifyCommitSignature(a, io, staging_dir, resolved_sha, signature_diagnostic, policy);
    }

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
///
/// Faz P2.4 (bkz. proje belleği "P0/P1/P2 inceleme düzeltme listesi" planı):
/// İKİ AYRI listeye BÖLÜNDÜ — şifreli/güvenilir (`https`/`ssh`/`file`, HER
/// ZAMAN kabul edilir) VE düz-metin/MITM'e açık (`http`/`git`, YALNIZCA
/// AÇIK bir opt-in İLE kabul edilir, bkz. `resolveCloneUrl`nin belge notu).
/// `git://` protokolünün KENDİSİ hiçbir kimlik doğrulama/şifreleme
/// KATMANI TAŞIMAZ; düz `http://` de AYNI şekilde TLS'siz — İKİSİ de
/// bir ağ konumundaki bir saldırganın paket İÇERİĞİNİ SESSİZCE
/// DEĞİŞTİREBİLECEĞİ (klasik MITM) taşıma biçimleridir.
const secure_repo_schemes = [_][]const u8{ "https://", "ssh://", "file://" };
const insecure_repo_schemes = [_][]const u8{ "http://", "git://" };

/// `repo` zaten BİR ÖNEK olarak (bkz. `secure_repo_schemes`/
/// `insecure_repo_schemes`) bilinen bir şemayla BAŞLIYORSA (şifreliyse HER
/// ZAMAN, düz-metinse YALNIZCA `allow_insecure_transport` İLE) DOKUNULMADAN
/// döner (testlerin yerel `file://` fixture repo'ları DAHİL); mutlak bir
/// yerel yol İSE de DOKUNULMADAN döner; aksi halde (ör.
/// `"github.com/user/repo"`) `https://` öneki eklenir (bilinçli güvenli
/// VARSAYILAN — bkz. modül üstü not).
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
///
/// **Faz P2.4 — düz-metin şemalar İçin VARSAYILAN REDDETME:** `NOX_
/// ALLOW_INSECURE_TRANSPORT` ortam değişkeni (bkz. `main.zig`nin AYNI
/// `NOX_HOME`/`NOX_RESOURCE_DIR` deseni — BİR KEZ `main()`de okunur, BURAYA
/// AÇIK bir parametre olarak GEÇİRİLİR, asla doğrudan burada OKUNMAZ)
/// AÇIKÇA VERİLMEDİKÇE `http://`/`git://` `error.InsecureRepoSchemeRejected`
/// İLE reddedilir.
pub fn resolveCloneUrl(a: Allocator, repo: []const u8, allow_insecure_transport: bool) ![]const u8 {
    if (std.mem.indexOf(u8, repo, "://") != null) {
        for (secure_repo_schemes) |scheme| {
            if (std.mem.startsWith(u8, repo, scheme)) return a.dupe(u8, repo);
        }
        for (insecure_repo_schemes) |scheme| {
            if (std.mem.startsWith(u8, repo, scheme)) {
                if (allow_insecure_transport) return a.dupe(u8, repo);
                return error.InsecureRepoSchemeRejected;
            }
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
///
/// **Güvenlik düzeltmesi (bağımsız bir inceleme TARAFINDAN bulundu, 2026-07-22
/// — bkz. `cachedDirFor`nin AYNI belge notu):** ÖNCEKİ sürüm `.` VE `/`yi
/// KARAKTER BAZINDA koruyordu ama `.`/`..` PATH SEGMENTLERİNİ (tam
/// bileşen olarak) HİÇ reddetmiyordu — `nox.json`nin `requires[].repo`si
/// (manifest ÜZERİNDEN saldırgan etkisinde OLABİLİR) `"../../../../hedef"`
/// gibi bir değer TAŞIRSA (şema ÖNEKİ yok, `/` İLE başlamıyor — İKİ üstteki
/// atma adımı da devreye GİRMEZ), SANİTİZE-EDİLMEMİŞ olarak `$NOX_HOME/
/// pkg/mod/../../../../hedef/<sha>` yoluna DÖNÜŞÜR — `createDirPath`/
/// `renameAbsolute` BUNU işletim sisteminin KENDİ path çözümlemesiyle
/// `$NOX_HOME/pkg/mod` KÖKÜ DIŞINA çıkarır (GERÇEK bir path traversal —
/// process'in yazma YETKİSİ olan HERHANGİ bir yere dosya YAZDIRABİLİR).
/// Düzeltme: karakter-bazlı beyaz listeden SONRA, `/` İLE ayrılan HER
/// path SEGMENTİ ayrı ayrı kontrol edilir — segment TAM OLARAK `.` ya da
/// `..`İSE (KARAKTER İÇERİĞİ zaten zararsız olsa BİLE, SEGMENT anlamı
/// tehlikelidir) `_` İLE DEĞİŞTİRİLİR, böylece SONUÇ asla bir "yukarı çık"
/// ya da "aynı dizin" bileşeni İÇEREMEZ.
fn sanitizeRepoForCachePath(a: Allocator, repo: []const u8) ![]const u8 {
    var s = repo;
    if (std.mem.indexOf(u8, s, "://")) |idx| s = s[idx + 3 ..];
    while (s.len > 0 and s[0] == '/') s = s[1..];

    const buf = try a.alloc(u8, s.len);
    defer a.free(buf);
    for (s, 0..) |c, i| {
        buf[i] = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_', '/' => c,
            else => '_',
        };
    }

    var segments: std.ArrayListUnmanaged([]const u8) = .empty;
    defer segments.deinit(a);
    var it = std.mem.splitScalar(u8, buf, '/');
    while (it.next()) |seg| {
        try segments.append(a, if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) "_" else seg);
    }
    return std.mem.join(a, "/", segments.items);
}

/// `fetchToCache`in İÇİNDE hesapladığı `cache_dir` yolunu, GİT'E hiç
/// dokunmadan (SALT string birleştirme) yeniden hesaplar — Faz O §P.6'nın
/// resolver'ının "bu bağımlılık ZATEN `nox.lock`ta kilitli VE önbellek
/// dizini HÂLÂ diskte mi?" sorusunu, `fetchToCache`i (dolayısıyla `git`i)
/// HİÇ ÇAĞIRMADAN yanıtlayabilmesi İÇİN dışa açılır.
pub fn cachedDirFor(a: Allocator, nox_home: []const u8, repo: []const u8, resolved_sha: []const u8) ![]const u8 {
    const cache_subpath = try sanitizeRepoForCachePath(a, repo);
    defer a.free(cache_subpath);
    // Savunmacı derinlik: `resolved_sha` normalde `git rev-parse HEAD`in
    // (`fetchToCache`) çıktısıdır ve GERÇEK git ile HER ZAMAN salt-hex bir
    // dizedir — ama bu fonksiyon `cache_subpath`in AKSİNE `resolved_sha`yı
    // HİÇ SANİTİZE ETMEDEN doğrudan yola YAZAR. `sanitizeRepoForCachePath`nin
    // AYNI path-traversal düzeltmesiyle TUTARLI olarak, beklenmeyen bir
    // (ör. gelecekte git'in çıktı biçimi değişirse) `resolved_sha` değeri
    // İçin de KESİN bir kontrol eklenir — path traversal'a AÇIK bir yola
    // asla İZİN VERİLMEZ.
    if (!isAllHex(resolved_sha)) return error.InvalidResolvedSha;
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
/// başarısızsa `error.GitCommandFailed`, başarılıysa stdout'u döner. Faz
/// P2.4: `policy`den (bkz. `buildGitChildEnv`in belge notu)
/// `GIT_TERMINAL_PROMPT=0` İÇEREN bir ortamla ÇALIŞTIRILIR.
fn runGit(a: Allocator, io: Io, argv_tail: []const []const u8, cwd_path: ?[]const u8, policy: FetchPolicy) ![]const u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.append(a, "git");
    try argv.appendSlice(a, argv_tail);

    var child_env = try buildGitChildEnv(a, policy);
    defer child_env.deinit();

    const result = try std.process.run(a, io, .{
        .argv = argv.items,
        .cwd = if (cwd_path) |c| .{ .path = c } else .inherit,
        .environ_map = &child_env,
    });
    if (result.term != .exited or result.term.exited != 0) {
        return error.GitCommandFailed;
    }
    return result.stdout;
}
