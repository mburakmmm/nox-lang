//! Faz Y.1 (bkz. docs/uretim-hazirlik-analizi.md — "Hafif bir 'paket
//! dizini' [yalnızca statik bir JSON indeksi — gerçek bir sunucu/registry
//! DEĞİL] — plan dosyasının kendi 'gelecekte eklenebilir' tasarımını
//! KULLAN"): üçüncü-taraf Nox paketlerini KEŞFETMEK için hafif, salt-okunur
//! bir katalog.
//!
//! **Neden gerçek bir sunucu/API DEĞİL:** Faz O'nun kendi planlama turu
//! (bkz. nox-teknik-spesifikasyon.md §3.6, "Açık Sorular / Bilinçli Kapsam
//! Dışı") merkezi bir registry/proxy'yi (Go'nun `GOPROXY`si benzeri)
//! KASITLI olarak kapsam DIŞI bıraktı — `compiler/pkg/fetch.zig`nin TEK
//! bir dispatch noktası (`resolveCloneUrl`) olması, GELECEKTEKİ bir fazın
//! bir "mirror'dan HTTP üzerinden tarball getir" dalı EKLEMESİNİ manifest/
//! lockfile şemasına DOKUNMADAN sağlar. Y.1 AYNI ilkeyi izler: bu dosya bir
//! JSON metnini AYRIŞTIRIR/ARAR — nereden GELDİĞİ (yerel dosya, `noxc
//! search`e verilen bir yol) TAMAMEN ÇAĞIRANIN sorumluluğundadır. Gelecekte
//! bir HTTP indirme adımı EKLENİRSE (statik bir dosya sunucusundan/GitHub
//! Pages'ten), bu YALNIZCA `loadIndexFromFile`nin YANINA yeni bir
//! `loadIndexFromUrl` EKLEMEK anlamına gelir — `parseIndexJson`/`matches`
//! DEĞİŞMEDEN kalır.
//!
//! **Şema:** `{"packages": [{"name", "repo", "description"?, "tags"?}]}` —
//! `Requirement`in (bkz. `compiler/project.zig`) `repo` alanıYLA AYNI
//! kavram/format (`"github.com/user/repo"`) — bilinçli olarak `ref`
//! TAŞIMAZ (paket dizini bir KEŞİF katalogudur, sürüm PİNLEME `nox.json`nin
//! `requires[]`inin işidir — kullanıcı bulduğu paketi KENDİ `ref`iyle
//! manifestine EKLER).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fetch_mod = @import("fetch.zig");

pub const PackageEntry = struct {
    name: []const u8,
    repo: []const u8,
    description: []const u8 = "",
    tags: []const []const u8 = &.{},
};

pub const Index = struct {
    packages: []const PackageEntry = &.{},
};

pub const IndexError = error{InvalidIndex} || std.Io.Dir.ReadFileAllocError || Allocator.Error;

/// Bir paket dizini JSON metnini (dosya sistemine HİÇ dokunmadan, saf
/// bellek-içi) ayrıştırır — `project.parseLockfile`yle AYNI desen, birim
/// testlerinin GERÇEK dosya sistemi olmadan fixture string'lerle
/// çalışabilmesi İÇİN.
pub fn parseIndexJson(a: Allocator, source: []const u8) IndexError!Index {
    const parsed = std.json.parseFromSlice(Index, a, source, .{ .ignore_unknown_fields = true }) catch {
        return error.InvalidIndex;
    };
    return parsed.value;
}

/// `path`teki bir dosyadan okuyup ayrıştırır (`noxc search`in gerçek
/// kullanım yolu).
pub fn loadIndexFromFile(a: Allocator, io: Io, path: []const u8) IndexError!Index {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
    return parseIndexJson(a, source);
}

/// Bulundu (bkz. proje belleği "f-string + augmented atama" ve "nox.http
/// gzip düzeltmesi" görevleri): bu modülün belge notu ("gelecekte bir HTTP
/// indirme adımı EKLENİRSE, bu YALNIZCA loadIndexFromFile'nin YANINA yeni
/// bir loadIndexFromUrl EKLEMEK anlamına gelir") burada gerçekleşiyor.
/// `fetch.zig`nin AYNI güvenli-taşıma disiplini: `url` yalnızca `https://`
/// İLE başlarsa KABUL edilir, `http://` YALNIZCA `policy.allow_insecure_
/// transport` AÇIKSA (bkz. `fetch.FetchPolicy`, `NOX_ALLOW_INSECURE_
/// TRANSPORT`). `std.http.Client`ın `Response.readerDecompressing`sini
/// KULLANIR (DÜZ `Response.reader` DEĞİL) — `runtime/stdlib_shims/
/// http_client.zig`de GERÇEK bir heap-bozulması çökmesine yol açtığı
/// KEŞFEDİLEN/DÜZELTİLEN AYNI hatanın burada TEKRARLANMAMASI İçin (GitHub
/// Pages/raw.githubusercontent.com DAHİL neredeyse HER modern statik dosya
/// sunucusu gzip sıkıştırır).
fn validateIndexUrlScheme(url: []const u8, allow_insecure_transport: bool) error{InsecureIndexUrlRejected}!void {
    if (std.mem.startsWith(u8, url, "https://")) return;
    if (std.mem.startsWith(u8, url, "http://") and allow_insecure_transport) return;
    return error.InsecureIndexUrlRejected;
}

// Bulundu (bkz. `fetch.zig`nin `GitError`sinin AYNI belge notu — elle
// tüketici bir hata kümesi çıkarmaya karşı argüman): dönüş tipi BİLİNÇLİ
// olarak ÇIKARIMLI (`!Index`) — `std.http.Client`in tam hata kümesini elle
// numaralandırmak KIRILGAN (Zig std sürümleri arasında isim DEĞİŞEBİLİR,
// tam olarak bu YÜZDEN `error.IndexFetchFailed`e KATLANIR).
pub fn loadIndexFromUrl(a: Allocator, io: Io, url: []const u8, policy: fetch_mod.FetchPolicy) !Index {
    try validateIndexUrlScheme(url, policy.allow_insecure_transport);

    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{ .redirect_behavior = .unhandled });
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    if (response.head.status != .ok) return error.IndexFetchFailed;

    var transfer_buffer: [1024]u8 = undefined;
    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .deflate, .gzip => a.alloc(u8, std.compress.flate.max_window_len) catch return error.IndexFetchFailed,
        .zstd, .compress => return error.IndexFetchFailed,
    };
    defer if (decompress_buffer.len > 0) a.free(decompress_buffer);
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    var body_out: std.Io.Writer.Allocating = .init(a);
    _ = reader.streamRemaining(&body_out.writer) catch return error.IndexFetchFailed;
    const body = body_out.toOwnedSlice() catch return error.IndexFetchFailed;

    return parseIndexJson(a, body);
}

/// `entry`, `query`yle EŞLEŞİR mi? Büyük/küçük harfe DUYARLI, düz alt-dizge
/// eşleşmesi (ad/açıklama İÇİNDE) VEYA TAM bir etiket eşleşmesi — v1
/// kapsamı BİLİNÇLİ olarak basit tutuldu (bulanık arama/unicode-casefold
/// YOK). `query` BOŞSA (`noxc search <indeks>` — sorgu OLMADAN) HER
/// zaman `true` döner (TÜM katalogu listelemek İÇİN).
pub fn matches(entry: PackageEntry, query: []const u8) bool {
    if (query.len == 0) return true;
    if (std.mem.indexOf(u8, entry.name, query) != null) return true;
    if (std.mem.indexOf(u8, entry.description, query) != null) return true;
    for (entry.tags) |t| {
        if (std.mem.eql(u8, t, query)) return true;
    }
    return false;
}

test "parseIndexJson: gecerli bir dizini dogru ayristirir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\{"packages": [
        \\  {"name": "noxhttp-extras", "repo": "github.com/example/noxhttp-extras",
        \\   "description": "nox.http icin yardimci fonksiyonlar", "tags": ["http", "web"]},
        \\  {"name": "noxcolor", "repo": "github.com/example/noxcolor"}
        \\]}
    ;
    const idx = try parseIndexJson(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 2), idx.packages.len);
    try std.testing.expectEqualStrings("noxhttp-extras", idx.packages[0].name);
    try std.testing.expectEqualStrings("github.com/example/noxhttp-extras", idx.packages[0].repo);
    try std.testing.expectEqual(@as(usize, 2), idx.packages[0].tags.len);
    // Eksik alanlar (`description`/`tags`) varsayilanlarina duser.
    try std.testing.expectEqualStrings("", idx.packages[1].description);
    try std.testing.expectEqual(@as(usize, 0), idx.packages[1].tags.len);
}

test "parseIndexJson: bozuk JSON error.InvalidIndex doner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidIndex, parseIndexJson(arena.allocator(), "{ bozuk"));
}

test "parseIndexJson: bos bir dizin ({}) gecerlidir, sifir paket doner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const idx = try parseIndexJson(arena.allocator(), "{}");
    try std.testing.expectEqual(@as(usize, 0), idx.packages.len);
}

test "matches: ad/aciklama/etiket uzerinden dogru eslesir" {
    const entry = PackageEntry{
        .name = "noxhttp-extras",
        .repo = "github.com/example/noxhttp-extras",
        .description = "nox.http icin yardimci fonksiyonlar",
        .tags = &.{ "http", "web" },
    };
    try std.testing.expect(matches(entry, "")); // bos sorgu -> hep eslesir
    try std.testing.expect(matches(entry, "http")); // ad ICINDE
    try std.testing.expect(matches(entry, "yardimci")); // aciklama ICINDE
    try std.testing.expect(matches(entry, "web")); // TAM etiket
    try std.testing.expect(!matches(entry, "hicbiryerde"));
    try std.testing.expect(!matches(entry, "we")); // etiket eslesmesi TAM olmali, alt-dizge DEGIL
}

test "validateIndexUrlScheme: https her zaman kabul, http yalnizca allow_insecure_transport ile" {
    try validateIndexUrlScheme("https://example.com/index.json", false);
    try validateIndexUrlScheme("https://example.com/index.json", true);
    try std.testing.expectError(error.InsecureIndexUrlRejected, validateIndexUrlScheme("http://example.com/index.json", false));
    try validateIndexUrlScheme("http://example.com/index.json", true);
}

test "validateIndexUrlScheme: bilinmeyen/dosya semasi her zaman reddedilir" {
    try std.testing.expectError(error.InsecureIndexUrlRejected, validateIndexUrlScheme("ftp://example.com/index.json", true));
    try std.testing.expectError(error.InsecureIndexUrlRejected, validateIndexUrlScheme("/yerel/yol/index.json", true));
}
