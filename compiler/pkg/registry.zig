//! `noxc add`/`noxc delete`/`noxc publish`in "merkezi indeks/sunucu
//! istemcisi" katmanı — `pkg/fetch.zig`/`pkg/index.zig`/`pkg/upgrade.zig`
//! İLE AYNI ayrım deseninde (`main.zig` İNCE bir CLI-ayrıştırma katmanı
//! olarak KALIR).
//!
//! **Bulundu, BİLİNÇLİ bir mimari not:** `pkg/index.zig`nin KENDİ belge
//! notu, merkezi bir registry/sunucunun Faz O/Y.1'de KASITLI olarak
//! kapsam DIŞI bırakıldığını açıklar — bu dosya, kullanıcının AÇIK
//! talebiyle (bkz. proje belleği "noxc add/delete/publish + noxpkg
//! sunucusu" planı) TAM OLARAK O bileşeni EKLİYOR. `pkg/index.zig`nin
//! `Index`/`PackageEntry` ŞEMASI DEĞİŞMEDEN kalır (`findByAlias` onun
//! ÜZERİNE, salt-okunur bir sorgu olarak inşa edilir) — `noxc search`in
//! ZATEN çalışan `loadIndexFromUrl`/`loadIndexFromFile` yolu BURADAN
//! HİÇ etkilenmez.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const pkg_index = @import("index.zig");

/// `noxpkg` sunucusu KURULDUKTAN SONRA GEÇERLİ olacak varsayılanlar —
/// sunucu HENÜZ yayında OLMASA BİLE `noxc add`/`publish`in KENDİSİ
/// (env değişkeni override'larıyla) test EDİLEBİLİR olmalı, bu YÜZDEN
/// varsayılan değerler burada SABİT TUTULUR (main.zig'de `NOX_UPGRADE_
/// API_BASE` İLE AYNI desende, main() İÇİNDE BİR KEZ env'den override
/// edilir).
pub const default_index_url: []const u8 = "https://noxpkg.2mtechnology.org/index.json";
pub const default_publish_api_base: []const u8 = "https://noxpkg.2mtechnology.org";

pub const RegistryPolicy = struct {
    index_url: []const u8 = default_index_url,
    publish_api_base: []const u8 = default_publish_api_base,
};

/// `idx` İçinde `alias`e (TAM eşleşme, `PackageEntry.name` üzerinden)
/// karşılık gelen girdiyi arar — `noxc add <alias>`in (açık bir `repo`
/// argümanı VERİLMEDİĞİNDE) ÇÖZÜMLEME adımı. `pkg_index.matches`in
/// (alt-dizge/etiket eşleşmesi, `noxc search` İçin) AKSİNE burada TAM
/// isim eşleşmesi GEREKİR — `add` BELİRSİZLİK KALDIRMAZ, tek bir paket
/// SEÇMEK ZORUNDADIR.
pub fn findByAlias(idx: pkg_index.Index, alias: []const u8) ?pkg_index.PackageEntry {
    for (idx.packages) |entry| {
        if (std.mem.eql(u8, entry.name, alias)) return entry;
    }
    return null;
}

pub const PublishPayload = struct {
    name: []const u8,
    repo: []const u8,
    ref: []const u8 = "main",
    description: []const u8 = "",
    tags: []const []const u8 = &.{},
};

pub const PublishResult = struct {
    ok: bool,
    id: []const u8 = "",
    @"error": []const u8 = "",
};

pub const PublishError = error{PublishFailed};

/// `payload`i JSON olarak `<api_base>/api/publish`e POST'lar VE sunucunun
/// `PublishResult` şeklindeki yanıtını ayrıştırıp döner (HTTP düzeyinde
/// başarısız olsa BİLE — ör. sunucu 400 İLE `{"ok":false,"error":"..."}`
/// dönerse — bu bir Zig hatası DEĞİLDİR, `PublishResult.ok == false`
/// olarak ÇAĞIRANA YANSITILIR; yalnızca AĞ/protokol düzeyinde GERÇEKTEN
/// BAŞARISIZ olunursa `error.PublishFailed` fırlatılır). `pkg_index.
/// loadIndexFromUrl` İLE AYNI şema-doğrulama (yalnızca `https://`,
/// `http://` SADECE `allow_insecure_transport` İLE) VE AYNI gzip/deflate
/// çözme deseni (Cloudflare Tunnel yanıtları sıkıştırabilir) — GÖVDE
/// gönderme kısmı İSE `runtime/stdlib_shims/http_client.zig`nin KENDİ
/// POST deseninden (`transfer_encoding = .content_length`,
/// `sendBodyUnflushed` + yaz + `.end()` + `conn.flush()`) alınmıştır.
pub fn submitPublish(a: Allocator, io: Io, api_base: []const u8, payload: PublishPayload, allow_insecure_transport: bool) !PublishResult {
    if (std.mem.startsWith(u8, api_base, "https://")) {} else if (std.mem.startsWith(u8, api_base, "http://") and allow_insecure_transport) {} else {
        return error.PublishFailed;
    }

    const url = try std.fmt.allocPrint(a, "{s}/api/publish", .{api_base});
    const body = try std.json.Stringify.valueAlloc(a, payload, .{});

    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = client.request(.POST, uri, .{
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .redirect_behavior = .unhandled,
    }) catch return error.PublishFailed;
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    var body_writer = req.sendBodyUnflushed(&.{}) catch return error.PublishFailed;
    body_writer.writer.writeAll(body) catch return error.PublishFailed;
    body_writer.end() catch return error.PublishFailed;
    const conn = req.connection orelse return error.PublishFailed;
    conn.flush() catch return error.PublishFailed;

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buffer) catch return error.PublishFailed;

    var transfer_buffer: [1024]u8 = undefined;
    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .deflate, .gzip => a.alloc(u8, std.compress.flate.max_window_len) catch return error.PublishFailed,
        .zstd, .compress => return error.PublishFailed,
    };
    defer if (decompress_buffer.len > 0) a.free(decompress_buffer);
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    var resp_body_out: std.Io.Writer.Allocating = .init(a);
    _ = reader.streamRemaining(&resp_body_out.writer) catch return error.PublishFailed;
    const resp_body = resp_body_out.toOwnedSlice() catch return error.PublishFailed;

    const parsed = std.json.parseFromSlice(PublishResult, a, resp_body, .{ .ignore_unknown_fields = true }) catch {
        return error.PublishFailed;
    };
    return parsed.value;
}

test "RegistryPolicy varsayilanlari belgelenen noxpkg URL'lerine esittir" {
    const policy: RegistryPolicy = .{};
    try std.testing.expectEqualStrings(default_index_url, policy.index_url);
    try std.testing.expectEqualStrings(default_publish_api_base, policy.publish_api_base);
    try std.testing.expectEqualStrings("https://noxpkg.2mtechnology.org/index.json", default_index_url);
    try std.testing.expectEqualStrings("https://noxpkg.2mtechnology.org", default_publish_api_base);
}

test "findByAlias: tam isim eslesmesi, alt-dizge eslesmez" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const idx = try pkg_index.parseIndexJson(arena.allocator(),
        \\{"packages": [
        \\  {"name": "nyx", "repo": "github.com/example/nyx", "description": "web framework"},
        \\  {"name": "nyx-extras", "repo": "github.com/example/nyx-extras"}
        \\]}
    );
    const found = findByAlias(idx, "nyx") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("github.com/example/nyx", found.repo);
    try std.testing.expect(findByAlias(idx, "ny") == null);
    try std.testing.expect(findByAlias(idx, "yok") == null);
}
