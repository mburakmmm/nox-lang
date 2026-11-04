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
//
/// v2.0: alan adı `noxpkg.2mtechnology.org`dan `noxpkg.noxlang.com`a taşındı. ESKİ ad, eski `noxc`
/// sürümleri çalışmaya devam etsin diye sunucu tarafında (Cloudflare Tunnel girişi) AYNI hizmete
/// yönlendirilmeye devam eder; yeni sürümler yalnızca yeni adı kullanır.
pub const default_index_url: []const u8 = "https://noxpkg.noxlang.com/index.json";
pub const default_publish_api_base: []const u8 = "https://noxpkg.noxlang.com";

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
    /// `pending` (onay bekliyor) ya da `published` (onaylı paketin aynı sahibi aynı repoyu güncelledi, onay gerekmedi). Eski sunucular alanı göndermez.
    status: []const u8 = "",
    @"error": []const u8 = "",
};

pub const PublishError = error{PublishFailed};

/// `jsonRequest`in yanıtı: HTTP durumu + (gerekirse gzip/deflate çözülmüş) gövde.
pub const HttpReply = struct {
    status: u16,
    body: []const u8,
};

/// `noxpkg` sunucusuna JSON isteği (v2.0.136: `submitPublish`in HTTP gövdesi genelleştirildi; giriş/çıkış/whoami uç noktaları da
/// kullanır). `bearer` doluysa `Authorization: Bearer <jeton>` eklenir. `body` null ise gövdesiz istek. Yanıt HTTP durumu ne olursa olsun
/// DÖNER (4xx JSON hata gövdesi çağıranın işidir); yalnızca ağ/protokol düzeyinde başarısızlık `error.PublishFailed`dir.
/// `loadIndexFromUrl` ile AYNI şema doğrulaması (yalnızca `https://`, `http://` SADECE `allow_insecure_transport` ile) ve AYNI
/// gzip/deflate çözme (Cloudflare Tunnel yanıtları sıkıştırabilir); POST gövdesi `runtime/stdlib_shims/http_client.zig`nin kendi deseniyle
/// (`transfer_encoding = .content_length`, `sendBodyUnflushed` + yaz + `.end()` + `conn.flush()`) gönderilir.
pub fn jsonRequest(a: Allocator, io: Io, method: std.http.Method, url: []const u8, body: ?[]const u8, bearer: ?[]const u8, allow_insecure_transport: bool) !HttpReply {
    if (std.mem.startsWith(u8, url, "https://")) {} else if (std.mem.startsWith(u8, url, "http://") and allow_insecure_transport) {} else {
        return error.PublishFailed;
    }

    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();

    const uri = std.Uri.parse(url) catch return error.PublishFailed;
    var header_buf: [2]std.http.Header = undefined;
    var header_count: usize = 0;
    if (body != null) {
        header_buf[header_count] = .{ .name = "content-type", .value = "application/json" };
        header_count += 1;
    }
    var auth_value: []const u8 = "";
    if (bearer) |token| {
        auth_value = std.fmt.allocPrint(a, "Bearer {s}", .{token}) catch return error.PublishFailed;
        header_buf[header_count] = .{ .name = "authorization", .value = auth_value };
        header_count += 1;
    }
    var req = client.request(method, uri, .{
        .extra_headers = header_buf[0..header_count],
        .redirect_behavior = .unhandled,
    }) catch return error.PublishFailed;
    defer req.deinit();

    if (body) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        var body_writer = req.sendBodyUnflushed(&.{}) catch return error.PublishFailed;
        body_writer.writer.writeAll(payload) catch return error.PublishFailed;
        body_writer.end() catch return error.PublishFailed;
        const conn = req.connection orelse return error.PublishFailed;
        conn.flush() catch return error.PublishFailed;
    } else {
        req.sendBodiless() catch return error.PublishFailed;
    }

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
    return .{ .status = @intFromEnum(response.head.status), .body = resp_body };
}

/// `payload`i JSON olarak `<api_base>/api/publish`e POST'lar (`token`: `noxc login` jetonu) VE sunucunun `PublishResult` şeklindeki
/// yanıtını ayrıştırıp döner (HTTP düzeyinde başarısız olsa BİLE, ör. 401/403 ile `{"ok":false,"error":"..."}`, bu bir Zig hatası
/// DEĞİLDİR: `PublishResult.ok == false` olarak çağırana yansıtılır; yalnızca ağ/protokol düzeyinde başarısızlık `error.PublishFailed`).
pub fn submitPublish(a: Allocator, io: Io, api_base: []const u8, payload: PublishPayload, token: []const u8, allow_insecure_transport: bool) !PublishResult {
    const url = try std.fmt.allocPrint(a, "{s}/api/publish", .{api_base});
    const body = try std.json.Stringify.valueAlloc(a, payload, .{});
    const reply = try jsonRequest(a, io, .POST, url, body, token, allow_insecure_transport);
    const parsed = std.json.parseFromSlice(PublishResult, a, reply.body, .{ .ignore_unknown_fields = true }) catch {
        return error.PublishFailed;
    };
    return parsed.value;
}

test "RegistryPolicy varsayilanlari belgelenen noxpkg URL'lerine esittir" {
    const policy: RegistryPolicy = .{};
    try std.testing.expectEqualStrings(default_index_url, policy.index_url);
    try std.testing.expectEqualStrings(default_publish_api_base, policy.publish_api_base);
    try std.testing.expectEqualStrings("https://noxpkg.noxlang.com/index.json", default_index_url);
    try std.testing.expectEqualStrings("https://noxpkg.noxlang.com", default_publish_api_base);
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
