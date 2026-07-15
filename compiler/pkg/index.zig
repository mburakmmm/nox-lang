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
