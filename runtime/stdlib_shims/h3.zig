//! HTTP/3 (RFC 9114) çerçeveleme + QPACK (RFC 9204) — saf, G/Ç'siz, allocator'ı açık parametre alan katman (TODO 5.4, aşama H3.2). QUIC taşıması `quic.zig`de;
//! bu dosya yalnızca bayt dizileri üretir/çözer, bu yüzden her platformda birim-test edilir.
//!
//! QPACK kapsamı: yalnızca STATİK tablo (SETTINGS_QPACK_MAX_TABLE_CAPACITY = 0, SETTINGS_QPACK_BLOCKED_STREAMS = 0). Bu RFC 9204'e uygundur: dinamik tabloya hiç
//! giriş eklenmediği için kodlayıcı/çözücü akışları boş kalır ve hiçbir alan bloğu "bloklanmaz". Karşı taraf dinamik tabloya atıf yaparsa (Required Insert Count > 0 ya da
//! dinamik/post-base dizin) `error.QpackDecompressionFailed` döner. Huffman tablosu HPACK ile aynıdır (`http2.zig` yeniden kullanılır).

const std = @import("std");
const Allocator = std.mem.Allocator;
const h2 = @import("http2.zig");

pub const Header = h2.Header;

// ---- QUIC değişken uzunluklu tamsayı (RFC 9000 §16) -----------------------------------------------------------------------------------------------------------------

pub const max_varint: u64 = (1 << 62) - 1;

/// `buf`un başındaki varint'i okur; tamamı yoksa `null`. `len_out` tüketilen bayt sayısıdır.
pub fn readVarint(buf: []const u8, len_out: *usize) ?u64 {
    if (buf.len == 0) return null;
    const n: usize = @as(usize, 1) << @intCast(buf[0] >> 6);
    if (buf.len < n) return null;
    var v: u64 = buf[0] & 0x3f;
    for (buf[1..n]) |b| v = (v << 8) | b;
    len_out.* = n;
    return v;
}

pub fn appendVarint(list: *std.ArrayListUnmanaged(u8), gpa: Allocator, v: u64) Allocator.Error!void {
    std.debug.assert(v <= max_varint);
    if (v < (1 << 6)) {
        try list.append(gpa, @intCast(v));
    } else if (v < (1 << 14)) {
        try list.append(gpa, @intCast(0x40 | (v >> 8)));
        try list.append(gpa, @intCast(v & 0xff));
    } else if (v < (1 << 30)) {
        try list.append(gpa, @intCast(0x80 | (v >> 24)));
        inline for ([_]u6{ 16, 8, 0 }) |sh| try list.append(gpa, @intCast((v >> sh) & 0xff));
    } else {
        try list.append(gpa, @intCast(0xc0 | (v >> 56)));
        inline for ([_]u6{ 48, 40, 32, 24, 16, 8, 0 }) |sh| try list.append(gpa, @intCast((v >> sh) & 0xff));
    }
}

// ---- Çerçeveler ---------------------------------------------------------------------------------------------------------------------------------------------------

pub const frame_data: u64 = 0x0;
pub const frame_headers: u64 = 0x1;
pub const frame_cancel_push: u64 = 0x3;
pub const frame_settings: u64 = 0x4;
pub const frame_push_promise: u64 = 0x5;
pub const frame_goaway: u64 = 0x7;
pub const frame_max_push_id: u64 = 0xd;

pub const stream_control: u64 = 0x00;
pub const stream_push: u64 = 0x01;
pub const stream_qpack_encoder: u64 = 0x02;
pub const stream_qpack_decoder: u64 = 0x03;

pub const setting_qpack_max_table_capacity: u64 = 0x01;
pub const setting_max_field_section_size: u64 = 0x06;
pub const setting_qpack_blocked_streams: u64 = 0x07;
pub const setting_enable_connect_protocol: u64 = 0x08;

pub const ErrorCode = enum(u64) {
    no_error = 0x100,
    general_protocol_error = 0x101,
    internal_error = 0x102,
    stream_creation_error = 0x103,
    closed_critical_stream = 0x104,
    frame_unexpected = 0x105,
    frame_error = 0x106,
    excessive_load = 0x107,
    id_error = 0x108,
    settings_error = 0x109,
    missing_settings = 0x10a,
    request_rejected = 0x10b,
    request_cancelled = 0x10c,
    request_incomplete = 0x10d,
    message_error = 0x10e,
    connect_error = 0x10f,
    version_fallback = 0x110,
    qpack_decompression_failed = 0x200,
    qpack_encoder_stream_error = 0x201,
    qpack_decoder_stream_error = 0x202,
    _,
};

pub const FrameHeader = struct {
    kind: u64,
    /// Yük uzunluğu (bayt).
    len: u64,
    /// Çerçeve başlığının (tür + uzunluk varint'leri) bayt sayısı.
    header_len: usize,
};

/// `buf`un başındaki çerçeve başlığını çözer; tam başlık yoksa `null` (daha fazla bayt gerekir).
pub fn parseFrameHeader(buf: []const u8) ?FrameHeader {
    var l1: usize = 0;
    const kind = readVarint(buf, &l1) orelse return null;
    var l2: usize = 0;
    const len = readVarint(buf[l1..], &l2) orelse return null;
    return .{ .kind = kind, .len = len, .header_len = l1 + l2 };
}

pub fn appendFrame(list: *std.ArrayListUnmanaged(u8), gpa: Allocator, kind: u64, payload: []const u8) Allocator.Error!void {
    try appendVarint(list, gpa, kind);
    try appendVarint(list, gpa, payload.len);
    try list.appendSlice(gpa, payload);
}

pub const Settings = struct {
    max_field_section_size: u64 = std.math.maxInt(u62),
    qpack_max_table_capacity: u64 = 0,
    qpack_blocked_streams: u64 = 0,
    enable_connect_protocol: bool = false,
};

/// Kontrol akışının ilk çerçevesi olan SETTINGS yükünü üretir (akış türü baytı ayrıca `appendControlStreamPreface`).
pub fn appendSettings(list: *std.ArrayListUnmanaged(u8), gpa: Allocator, s: Settings) Allocator.Error!void {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(gpa);
    try appendVarint(&payload, gpa, setting_qpack_max_table_capacity);
    try appendVarint(&payload, gpa, s.qpack_max_table_capacity);
    try appendVarint(&payload, gpa, setting_qpack_blocked_streams);
    try appendVarint(&payload, gpa, s.qpack_blocked_streams);
    if (s.max_field_section_size != std.math.maxInt(u62)) {
        try appendVarint(&payload, gpa, setting_max_field_section_size);
        try appendVarint(&payload, gpa, s.max_field_section_size);
    }
    if (s.enable_connect_protocol) {
        try appendVarint(&payload, gpa, setting_enable_connect_protocol);
        try appendVarint(&payload, gpa, 1);
    }
    try appendFrame(list, gpa, frame_settings, payload.items);
}

/// Tek yönlü akışın ilk baytı(ları): akış türü.
pub fn appendStreamType(list: *std.ArrayListUnmanaged(u8), gpa: Allocator, t: u64) Allocator.Error!void {
    try appendVarint(list, gpa, t);
}

pub const SettingsError = error{SettingsError};

/// SETTINGS yükünü çözer. HTTP/2'den kalan ayrılmış kimlikler (0x0, 0x2–0x5) ve yinelenen kimlikler `error.SettingsError`; bilinmeyen kimlikler yok sayılır (RFC 9114 §7.2.4).
pub fn parseSettings(payload: []const u8) SettingsError!Settings {
    var out: Settings = .{};
    var seen: [4]u64 = undefined;
    var nseen: usize = 0;
    var pos: usize = 0;
    while (pos < payload.len) {
        var l: usize = 0;
        const id = readVarint(payload[pos..], &l) orelse return error.SettingsError;
        pos += l;
        const val = readVarint(payload[pos..], &l) orelse return error.SettingsError;
        pos += l;
        if (id == 0x0 or (id >= 0x2 and id <= 0x5)) return error.SettingsError;
        const known = id == setting_qpack_max_table_capacity or id == setting_max_field_section_size or id == setting_qpack_blocked_streams or id == setting_enable_connect_protocol;
        if (known) {
            for (seen[0..nseen]) |s| if (s == id) return error.SettingsError;
            if (nseen < seen.len) {
                seen[nseen] = id;
                nseen += 1;
            }
        }
        switch (id) {
            setting_qpack_max_table_capacity => out.qpack_max_table_capacity = val,
            setting_max_field_section_size => out.max_field_section_size = val,
            setting_qpack_blocked_streams => out.qpack_blocked_streams = val,
            setting_enable_connect_protocol => {
                if (val > 1) return error.SettingsError;
                out.enable_connect_protocol = val == 1;
            },
            else => {},
        }
    }
    return out;
}

// ---- QPACK statik tablo (RFC 9204 Ek A) --------------------------------------------------------------------------------------------------------------------------

pub const static_table = [99]Header{
    .{ .name = ":authority", .value = "" },
    .{ .name = ":path", .value = "/" },
    .{ .name = "age", .value = "0" },
    .{ .name = "content-disposition", .value = "" },
    .{ .name = "content-length", .value = "0" },
    .{ .name = "cookie", .value = "" },
    .{ .name = "date", .value = "" },
    .{ .name = "etag", .value = "" },
    .{ .name = "if-modified-since", .value = "" },
    .{ .name = "if-none-match", .value = "" },
    .{ .name = "last-modified", .value = "" },
    .{ .name = "link", .value = "" },
    .{ .name = "location", .value = "" },
    .{ .name = "referer", .value = "" },
    .{ .name = "set-cookie", .value = "" },
    .{ .name = ":method", .value = "CONNECT" },
    .{ .name = ":method", .value = "DELETE" },
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":method", .value = "HEAD" },
    .{ .name = ":method", .value = "OPTIONS" },
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":method", .value = "PUT" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":status", .value = "103" },
    .{ .name = ":status", .value = "200" },
    .{ .name = ":status", .value = "304" },
    .{ .name = ":status", .value = "404" },
    .{ .name = ":status", .value = "503" },
    .{ .name = "accept", .value = "*/*" },
    .{ .name = "accept", .value = "application/dns-message" },
    .{ .name = "accept-encoding", .value = "gzip, deflate, br" },
    .{ .name = "accept-ranges", .value = "bytes" },
    .{ .name = "access-control-allow-headers", .value = "cache-control" },
    .{ .name = "access-control-allow-headers", .value = "content-type" },
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "cache-control", .value = "max-age=0" },
    .{ .name = "cache-control", .value = "max-age=2592000" },
    .{ .name = "cache-control", .value = "max-age=604800" },
    .{ .name = "cache-control", .value = "no-cache" },
    .{ .name = "cache-control", .value = "no-store" },
    .{ .name = "cache-control", .value = "public, max-age=31536000" },
    .{ .name = "content-encoding", .value = "br" },
    .{ .name = "content-encoding", .value = "gzip" },
    .{ .name = "content-type", .value = "application/dns-message" },
    .{ .name = "content-type", .value = "application/javascript" },
    .{ .name = "content-type", .value = "application/json" },
    .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
    .{ .name = "content-type", .value = "image/gif" },
    .{ .name = "content-type", .value = "image/jpeg" },
    .{ .name = "content-type", .value = "image/png" },
    .{ .name = "content-type", .value = "text/css" },
    .{ .name = "content-type", .value = "text/html; charset=utf-8" },
    .{ .name = "content-type", .value = "text/plain" },
    .{ .name = "content-type", .value = "text/plain;charset=utf-8" },
    .{ .name = "range", .value = "bytes=0-" },
    .{ .name = "strict-transport-security", .value = "max-age=31536000" },
    .{ .name = "strict-transport-security", .value = "max-age=31536000; includesubdomains" },
    .{ .name = "strict-transport-security", .value = "max-age=31536000; includesubdomains; preload" },
    .{ .name = "vary", .value = "accept-encoding" },
    .{ .name = "vary", .value = "origin" },
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "x-xss-protection", .value = "1; mode=block" },
    .{ .name = ":status", .value = "100" },
    .{ .name = ":status", .value = "204" },
    .{ .name = ":status", .value = "206" },
    .{ .name = ":status", .value = "302" },
    .{ .name = ":status", .value = "400" },
    .{ .name = ":status", .value = "403" },
    .{ .name = ":status", .value = "421" },
    .{ .name = ":status", .value = "425" },
    .{ .name = ":status", .value = "500" },
    .{ .name = "accept-language", .value = "" },
    .{ .name = "access-control-allow-credentials", .value = "FALSE" },
    .{ .name = "access-control-allow-credentials", .value = "TRUE" },
    .{ .name = "access-control-allow-headers", .value = "*" },
    .{ .name = "access-control-allow-methods", .value = "get" },
    .{ .name = "access-control-allow-methods", .value = "get, post, options" },
    .{ .name = "access-control-allow-methods", .value = "options" },
    .{ .name = "access-control-expose-headers", .value = "content-length" },
    .{ .name = "access-control-request-headers", .value = "content-type" },
    .{ .name = "access-control-request-method", .value = "get" },
    .{ .name = "access-control-request-method", .value = "post" },
    .{ .name = "alt-svc", .value = "clear" },
    .{ .name = "authorization", .value = "" },
    .{ .name = "content-security-policy", .value = "script-src 'none'; object-src 'none'; base-uri 'none'" },
    .{ .name = "early-data", .value = "1" },
    .{ .name = "expect-ct", .value = "" },
    .{ .name = "forwarded", .value = "" },
    .{ .name = "if-range", .value = "" },
    .{ .name = "origin", .value = "" },
    .{ .name = "purpose", .value = "prefetch" },
    .{ .name = "server", .value = "" },
    .{ .name = "timing-allow-origin", .value = "*" },
    .{ .name = "upgrade-insecure-requests", .value = "1" },
    .{ .name = "user-agent", .value = "" },
    .{ .name = "x-forwarded-for", .value = "" },
    .{ .name = "x-frame-options", .value = "deny" },
    .{ .name = "x-frame-options", .value = "sameorigin" },
};

// ---- QPACK kodlayıcı (yalnızca statik tablo) -----------------------------------------------------------------------------------------------------------------------

/// Başlık adı/değeri için dize: Huffman daha kısaysa onu kullanır. `prefix_bits`: uzunluk önekinin bit sayısı (H bayrağı önekin hemen üstündeki bittir).
fn appendQString(list: *std.ArrayListUnmanaged(u8), gpa: Allocator, first_bits: u8, prefix_bits: u4, s: []const u8) Allocator.Error!void {
    const hlen = h2.huffmanEncodedLen(s);
    const h_flag: u8 = @as(u8, 1) << @as(u3, @intCast(prefix_bits));
    if (hlen < s.len) {
        try h2.appendInt(list, gpa, first_bits | h_flag, prefix_bits, hlen);
        try h2.huffmanEncode(list, gpa, s);
    } else {
        try h2.appendInt(list, gpa, first_bits, prefix_bits, s.len);
        try list.appendSlice(gpa, s);
    }
}

fn isSensitive(name: []const u8) bool {
    return std.mem.eql(u8, name, "set-cookie") or std.mem.eql(u8, name, "authorization") or std.mem.eql(u8, name, "cookie") or std.mem.eql(u8, name, "proxy-authorization");
}

/// Bir alan bloğu (field section) kodlar: önek (RIC=0, Base=0) + alan satırları. `name`ler küçük harf olmalıdır. Dinamik tabloya hiç dokunulmaz;
/// çerez/yetki başlıkları "never indexed" (N=1) işaretlenir.
pub fn encodeFieldSection(list: *std.ArrayListUnmanaged(u8), gpa: Allocator, headers: []const Header) Allocator.Error!void {
    try list.appendSlice(gpa, &.{ 0x00, 0x00 });
    for (headers) |hd| {
        var name_idx: ?usize = null;
        var full_idx: ?usize = null;
        for (static_table, 0..) |e, i| {
            if (!std.mem.eql(u8, e.name, hd.name)) continue;
            if (name_idx == null) name_idx = i;
            if (std.mem.eql(u8, e.value, hd.value) and !isSensitive(hd.name)) {
                full_idx = i;
                break;
            }
        }
        if (full_idx) |i| {
            // Indexed Field Line: 1 T=1 index(6)
            try h2.appendInt(list, gpa, 0xc0, 6, i);
            continue;
        }
        const never: u8 = if (isSensitive(hd.name)) 0x20 else 0x00;
        if (name_idx) |i| {
            // Literal Field Line With Name Reference: 01 N T=1 index(4)
            try h2.appendInt(list, gpa, 0x50 | never, 4, i);
            try appendQString(list, gpa, 0, 7, hd.value);
        } else {
            // Literal Field Line With Literal Name: 001 N H namelen(3)
            try appendQString(list, gpa, 0x20 | (never >> 1), 3, hd.name);
            try appendQString(list, gpa, 0, 7, hd.value);
        }
    }
}

// ---- QPACK çözücü ---------------------------------------------------------------------------------------------------------------------------------------------------

pub const QpackError = error{ QpackDecompressionFailed, FieldSectionTooLarge, OutOfMemory };

/// Çözülmüş alan listesi; `arena` içindeki dizeler listeyle birlikte serbest bırakılır.
pub const Decoded = struct {
    headers: []Header,
};

fn readQString(arena: Allocator, block: []const u8, pos: *usize, prefix_bits: u4) QpackError![]const u8 {
    if (pos.* >= block.len) return error.QpackDecompressionFailed;
    const h_flag: u8 = @as(u8, 1) << @as(u3, @intCast(prefix_bits));
    const huffman = block[pos.*] & h_flag != 0;
    const len = h2.readInt(block, pos, prefix_bits) catch return error.QpackDecompressionFailed;
    if (len > block.len - pos.*) return error.QpackDecompressionFailed;
    const raw = block[pos.*..][0..len];
    pos.* += len;
    if (!huffman) return try arena.dupe(u8, raw);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    h2.huffmanDecode(arena, raw, &buf) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CompressionError => return error.QpackDecompressionFailed,
    };
    return buf.items;
}

/// Bir alan bloğunu çözer. `max_field_section_size`: RFC 9114 §4.2.2 boyutu (ad + değer + 32 bayt/alan toplamı) bu sınırı aşarsa `error.FieldSectionTooLarge`.
/// Dinamik tabloya atıf (RIC > 0, T=0 dizin, post-base) `error.QpackDecompressionFailed`. Tüm bellek `arena`dan gelir.
pub fn decodeFieldSection(arena: Allocator, block: []const u8, max_field_section_size: usize) QpackError!Decoded {
    var pos: usize = 0;
    const ric = h2.readInt(block, &pos, 8) catch return error.QpackDecompressionFailed;
    if (ric != 0) return error.QpackDecompressionFailed; // dinamik tablo kapasitesi 0: hiçbir blok ona atıf edemez
    if (pos >= block.len) return error.QpackDecompressionFailed;
    _ = h2.readInt(block, &pos, 7) catch return error.QpackDecompressionFailed; // Delta Base (işaret biti dahil, yok sayılır)

    var out: std.ArrayListUnmanaged(Header) = .empty;
    var total: usize = 0;
    while (pos < block.len) {
        const b = block[pos];
        var hd: Header = undefined;
        if (b & 0x80 != 0) {
            // Indexed Field Line
            if (b & 0x40 == 0) return error.QpackDecompressionFailed; // T=0: dinamik
            const idx = h2.readInt(block, &pos, 6) catch return error.QpackDecompressionFailed;
            if (idx >= static_table.len) return error.QpackDecompressionFailed;
            hd = static_table[idx];
        } else if (b & 0x40 != 0) {
            // Literal With Name Reference: 01 N T index(4)
            if (b & 0x10 == 0) return error.QpackDecompressionFailed; // T=0: dinamik
            const idx = h2.readInt(block, &pos, 4) catch return error.QpackDecompressionFailed;
            if (idx >= static_table.len) return error.QpackDecompressionFailed;
            const value = try readQString(arena, block, &pos, 7);
            hd = .{ .name = static_table[idx].name, .value = value };
        } else if (b & 0x20 != 0) {
            // Literal With Literal Name: 001 N H namelen(3)
            const name = try readQString(arena, block, &pos, 3);
            const value = try readQString(arena, block, &pos, 7);
            hd = .{ .name = name, .value = value };
        } else {
            return error.QpackDecompressionFailed; // 0001 / 0000: post-base (dinamik)
        }
        total += hd.name.len + hd.value.len + 32;
        if (total > max_field_section_size) return error.FieldSectionTooLarge;
        try out.append(arena, hd);
    }
    return .{ .headers = out.items };
}

// ---- QPACK dinamik tablo çözücüsü (RFC 9204 §3.2, §4.3, §4.4) ----------------------------------------------------------------------------------------------------
//
// SETTINGS_QPACK_BLOCKED_STREAMS = 0 bildirilir: karşı taraf kodlayıcısı, henüz onaylanmamış (bizce alınmamış) bir girişe atıf yapan blok göndermez; yine de alan satırlarında dinamik tabloya
// atıf (Required Insert Count > 0) çözülür. RIC > bizim toplam ekleme sayımız olan bir blok bloklanacaktı: `QpackDecompressionFailed`. Kodlayıcımız yalnızca statik tabloyu kullanır
// (yanıtlar/istekler için dinamik giriş eklemez).

pub const QpackEncoderStreamError = error{ QpackEncoderStreamError, OutOfMemory };

fn tryInt(buf: []const u8, pos: *usize, prefix_bits: u4) error{Invalid}!?usize {
    // `h2.readInt` ile aynı; veri bitince hata değil `null` (daha fazla bayt gerekir).
    if (pos.* >= buf.len) return null;
    const mask: usize = (@as(usize, 1) << prefix_bits) - 1;
    var v: usize = buf[pos.*] & mask;
    var p = pos.* + 1;
    if (v >= mask) {
        var shift: u32 = 0;
        while (true) {
            if (p >= buf.len) return null;
            const b = buf[p];
            p += 1;
            if (shift > 28) return error.Invalid;
            v += (@as(usize, b & 0x7f)) << @as(std.math.Log2Int(usize), @intCast(shift));
            if (v > 0x7fffffff) return error.Invalid;
            if (b & 0x80 == 0) break;
            shift += 7;
        }
    }
    pos.* = p;
    return v;
}

fn tryString(gpa: Allocator, buf: []const u8, pos: *usize, prefix_bits: u4) error{ Invalid, OutOfMemory }!?[]u8 {
    var p = pos.*;
    if (p >= buf.len) return null;
    const h_flag: u8 = @as(u8, 1) << @as(u3, @intCast(prefix_bits));
    const huffman = buf[p] & h_flag != 0;
    const len = (try tryInt(buf, &p, prefix_bits)) orelse return null;
    if (len > 1 << 20) return error.Invalid;
    if (buf.len - p < len) return null;
    const raw = buf[p..][0..len];
    p += len;
    var out: []u8 = undefined;
    if (!huffman) {
        out = try gpa.dupe(u8, raw);
    } else {
        var list: std.ArrayListUnmanaged(u8) = .empty;
        errdefer list.deinit(gpa);
        h2.huffmanDecode(gpa, raw, &list) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CompressionError => return error.Invalid,
        };
        out = try list.toOwnedSlice(gpa);
    }
    pos.* = p;
    return out;
}

pub const QpackDecoder = struct {
    const Entry = struct { name: []u8, value: []u8 };

    gpa: Allocator,
    /// Bizim bildirdiğimiz SETTINGS_QPACK_MAX_TABLE_CAPACITY (üst sınır).
    max_capacity: usize,
    capacity: usize = 0,
    size: usize = 0,
    /// En eskisi önce.
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    /// `entries[0]`ın mutlak dizini.
    dropped: u64 = 0,
    /// Toplam eklenen giriş sayısı.
    inserted: u64 = 0,
    /// Henüz tam gelmemiş kodlayıcı-akışı baytları.
    pending: std.ArrayListUnmanaged(u8) = .empty,
    /// Gönderilecek kod çözücü-akışı baytları (Section Acknowledgment / Insert Count Increment).
    out: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(gpa: Allocator, max_capacity: usize) QpackDecoder {
        return .{ .gpa = gpa, .max_capacity = max_capacity };
    }

    pub fn deinit(self: *QpackDecoder) void {
        for (self.entries.items) |e| {
            self.gpa.free(e.name);
            self.gpa.free(e.value);
        }
        self.entries.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        self.out.deinit(self.gpa);
    }

    fn evictOne(self: *QpackDecoder) void {
        const e = self.entries.orderedRemove(0);
        self.size -= e.name.len + e.value.len + 32;
        self.gpa.free(e.name);
        self.gpa.free(e.value);
        self.dropped += 1;
    }

    /// `name`/`value` sahipliği devralınır (hata durumunda serbest bırakılır).
    fn insert(self: *QpackDecoder, name: []u8, value: []u8) QpackEncoderStreamError!void {
        const need = name.len + value.len + 32;
        if (need > self.capacity) {
            self.gpa.free(name);
            self.gpa.free(value);
            return error.QpackEncoderStreamError;
        }
        while (self.size + need > self.capacity) self.evictOne();
        self.entries.append(self.gpa, .{ .name = name, .value = value }) catch {
            self.gpa.free(name);
            self.gpa.free(value);
            return error.OutOfMemory;
        };
        self.size += need;
        self.inserted += 1;
    }

    fn dynEntry(self: *const QpackDecoder, abs: u64) ?*const Entry {
        if (abs < self.dropped or abs >= self.inserted) return null;
        return &self.entries.items[@intCast(abs - self.dropped)];
    }

    /// Kodlayıcı akışından gelen baytları işler (kısmi talimatlar sonraki çağrıya kalır). Geçersiz talimat `QpackEncoderStreamError` (bağlantı hatası).
    pub fn processEncoderBytes(self: *QpackDecoder, bytes: []const u8) QpackEncoderStreamError!void {
        self.pending.appendSlice(self.gpa, bytes) catch return error.OutOfMemory;
        const before = self.inserted;
        var pos: usize = 0;
        while (pos < self.pending.items.len) {
            const buf = self.pending.items;
            const b = buf[pos];
            var p = pos;
            if (b & 0x80 != 0) {
                // Insert With Name Reference
                const static = b & 0x40 != 0;
                const idx = (tryInt(buf, &p, 6) catch return error.QpackEncoderStreamError) orelse break;
                const value = (tryString(self.gpa, buf, &p, 7) catch |e| return mapEs(e)) orelse break;
                var name_src: []const u8 = undefined;
                if (static) {
                    if (idx >= static_table.len) {
                        self.gpa.free(value);
                        return error.QpackEncoderStreamError;
                    }
                    name_src = static_table[idx].name;
                } else {
                    if (idx >= self.inserted) {
                        self.gpa.free(value);
                        return error.QpackEncoderStreamError;
                    }
                    const e = self.dynEntry(self.inserted - 1 - idx) orelse {
                        self.gpa.free(value);
                        return error.QpackEncoderStreamError;
                    };
                    name_src = e.name;
                }
                const name = self.gpa.dupe(u8, name_src) catch {
                    self.gpa.free(value);
                    return error.OutOfMemory;
                };
                try self.insert(name, value);
            } else if (b & 0x40 != 0) {
                // Insert With Literal Name
                const name = (tryString(self.gpa, buf, &p, 5) catch |e| return mapEs(e)) orelse break;
                const value = (tryString(self.gpa, buf, &p, 7) catch |e| {
                    self.gpa.free(name);
                    return mapEs(e);
                }) orelse {
                    self.gpa.free(name);
                    break;
                };
                try self.insert(name, value);
            } else if (b & 0x20 != 0) {
                // Set Dynamic Table Capacity
                const c = (tryInt(buf, &p, 5) catch return error.QpackEncoderStreamError) orelse break;
                if (c > self.max_capacity) return error.QpackEncoderStreamError;
                self.capacity = c;
                while (self.size > self.capacity) self.evictOne();
            } else {
                // Duplicate
                const idx = (tryInt(buf, &p, 5) catch return error.QpackEncoderStreamError) orelse break;
                if (idx >= self.inserted) return error.QpackEncoderStreamError;
                const e = self.dynEntry(self.inserted - 1 - idx) orelse return error.QpackEncoderStreamError;
                const name = self.gpa.dupe(u8, e.name) catch return error.OutOfMemory;
                const value = self.gpa.dupe(u8, e.value) catch {
                    self.gpa.free(name);
                    return error.OutOfMemory;
                };
                try self.insert(name, value);
            }
            pos = p;
        }
        if (pos > 0) self.pending.replaceRange(self.gpa, 0, pos, &.{}) catch return error.OutOfMemory;
        if (self.pending.items.len > 1 << 20) return error.QpackEncoderStreamError;
        if (self.inserted > before) {
            // Insert Count Increment: 00 + 6 bit önekli artış.
            h2.appendInt(&self.out, self.gpa, 0x00, 6, @intCast(self.inserted - before)) catch return error.OutOfMemory;
        }
    }

    /// Bir alan bloğunu çözer (statik + dinamik tablo). `stream_id`: RIC > 0 ise Section Acknowledgment için. Dizeler `arena`ya kopyalanır (tablo girişleri sonradan atılabilir).
    pub fn decode(self: *QpackDecoder, arena: Allocator, block: []const u8, max_field_section_size: usize, stream_id: u64) QpackError!Decoded {
        var pos: usize = 0;
        const enc_ric = h2.readInt(block, &pos, 8) catch return error.QpackDecompressionFailed;
        var ric: u64 = 0;
        if (enc_ric != 0) {
            const max_entries: u64 = self.max_capacity / 32;
            if (max_entries == 0) return error.QpackDecompressionFailed;
            const full_range = 2 * max_entries;
            if (enc_ric > full_range) return error.QpackDecompressionFailed;
            const max_value = self.inserted + max_entries;
            const max_wrapped = (max_value / full_range) * full_range;
            ric = max_wrapped + enc_ric - 1;
            if (ric > max_value) {
                if (ric <= full_range) return error.QpackDecompressionFailed;
                ric -= full_range;
            }
            if (ric == 0) return error.QpackDecompressionFailed;
        }
        // Bloklanması gereken blok: bildirdiğimiz BLOCKED_STREAMS = 0 olduğundan protokol ihlali.
        if (ric > self.inserted) return error.QpackDecompressionFailed;
        if (pos >= block.len) return error.QpackDecompressionFailed;
        const sign = block[pos] & 0x80 != 0;
        const delta = h2.readInt(block, &pos, 7) catch return error.QpackDecompressionFailed;
        var base: u64 = undefined;
        if (sign) {
            if (@as(u64, delta) + 1 > ric) return error.QpackDecompressionFailed;
            base = ric - delta - 1;
        } else base = ric + delta;

        var out: std.ArrayListUnmanaged(Header) = .empty;
        var total: usize = 0;
        while (pos < block.len) {
            const b = block[pos];
            var hd: Header = undefined;
            if (b & 0x80 != 0) {
                const t_static = b & 0x40 != 0;
                const idx = h2.readInt(block, &pos, 6) catch return error.QpackDecompressionFailed;
                if (t_static) {
                    if (idx >= static_table.len) return error.QpackDecompressionFailed;
                    hd = static_table[idx];
                } else {
                    if (@as(u64, idx) + 1 > base) return error.QpackDecompressionFailed;
                    const abs = base - 1 - idx;
                    if (abs >= ric) return error.QpackDecompressionFailed;
                    const e = self.dynEntry(abs) orelse return error.QpackDecompressionFailed;
                    hd = .{ .name = try arena.dupe(u8, e.name), .value = try arena.dupe(u8, e.value) };
                }
            } else if (b & 0x40 != 0) {
                const t_static = b & 0x10 != 0;
                const idx = h2.readInt(block, &pos, 4) catch return error.QpackDecompressionFailed;
                var name: []const u8 = undefined;
                if (t_static) {
                    if (idx >= static_table.len) return error.QpackDecompressionFailed;
                    name = static_table[idx].name;
                } else {
                    if (@as(u64, idx) + 1 > base) return error.QpackDecompressionFailed;
                    const abs = base - 1 - idx;
                    if (abs >= ric) return error.QpackDecompressionFailed;
                    const e = self.dynEntry(abs) orelse return error.QpackDecompressionFailed;
                    name = try arena.dupe(u8, e.name);
                }
                hd = .{ .name = name, .value = try readQString(arena, block, &pos, 7) };
            } else if (b & 0x20 != 0) {
                const name = try readQString(arena, block, &pos, 3);
                hd = .{ .name = name, .value = try readQString(arena, block, &pos, 7) };
            } else if (b & 0x10 != 0) {
                // Indexed Field Line With Post-Base Index
                const idx = h2.readInt(block, &pos, 4) catch return error.QpackDecompressionFailed;
                const abs = base + idx;
                if (abs >= ric) return error.QpackDecompressionFailed;
                const e = self.dynEntry(abs) orelse return error.QpackDecompressionFailed;
                hd = .{ .name = try arena.dupe(u8, e.name), .value = try arena.dupe(u8, e.value) };
            } else {
                // Literal Field Line With Post-Base Name Reference
                const idx = h2.readInt(block, &pos, 3) catch return error.QpackDecompressionFailed;
                const abs = base + idx;
                if (abs >= ric) return error.QpackDecompressionFailed;
                const e = self.dynEntry(abs) orelse return error.QpackDecompressionFailed;
                hd = .{ .name = try arena.dupe(u8, e.name), .value = try readQString(arena, block, &pos, 7) };
            }
            total += hd.name.len + hd.value.len + 32;
            if (total > max_field_section_size) return error.FieldSectionTooLarge;
            try out.append(arena, hd);
        }
        if (ric > 0) {
            // Section Acknowledgment: 1 + 7 bit önekli akış kimliği.
            h2.appendInt(&self.out, self.gpa, 0x80, 7, @intCast(stream_id)) catch return error.OutOfMemory;
        }
        return .{ .headers = out.items };
    }
};

fn mapEs(e: error{ Invalid, OutOfMemory }) QpackEncoderStreamError {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Invalid => error.QpackEncoderStreamError,
    };
}

// ---- Birim testleri -------------------------------------------------------------------------------------------------------------------------------------------------

const testing = std.testing;

test "h3: QUIC varint — RFC 9000 Ek A.1 örnekleri ve gidiş-dönüş" {
    const cases = [_]struct { v: u64, enc: []const u8 }{
        .{ .v = 37, .enc = &.{0x25} },
        .{ .v = 15293, .enc = &.{ 0x7b, 0xbd } },
        .{ .v = 494878333, .enc = &.{ 0x9d, 0x7f, 0x3e, 0x7d } },
        .{ .v = 151288809941952652, .enc = &.{ 0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c } },
    };
    for (cases) |c| {
        var l: usize = 0;
        try testing.expectEqual(@as(?u64, c.v), readVarint(c.enc, &l));
        try testing.expectEqual(c.enc.len, l);
        var list: std.ArrayListUnmanaged(u8) = .empty;
        defer list.deinit(testing.allocator);
        try appendVarint(&list, testing.allocator, c.v);
        try testing.expectEqualSlices(u8, c.enc, list.items);
    }
    var l: usize = 0;
    try testing.expectEqual(@as(?u64, null), readVarint(&.{0x7b}, &l)); // eksik
    try testing.expectEqual(@as(?u64, null), readVarint(&.{}, &l));
}

test "h3: çerçeve başlığı ve SETTINGS gidiş-dönüşü" {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(testing.allocator);
    try appendSettings(&list, testing.allocator, .{ .max_field_section_size = 16384, .enable_connect_protocol = true });
    const fh = parseFrameHeader(list.items).?;
    try testing.expectEqual(frame_settings, fh.kind);
    try testing.expectEqual(list.items.len - fh.header_len, @as(usize, @intCast(fh.len)));
    const s = try parseSettings(list.items[fh.header_len..]);
    try testing.expectEqual(@as(u64, 16384), s.max_field_section_size);
    try testing.expectEqual(@as(u64, 0), s.qpack_max_table_capacity);
    try testing.expect(s.enable_connect_protocol);
    // Eksik başlık: null
    try testing.expectEqual(@as(?FrameHeader, null), parseFrameHeader(&.{0x40}));
}

test "h3: SETTINGS — ayrılmış/yinelenen kimlik reddedilir, bilinmeyen yok sayılır" {
    try testing.expectError(error.SettingsError, parseSettings(&.{ 0x02, 0x01 })); // HTTP/2 ENABLE_PUSH
    try testing.expectError(error.SettingsError, parseSettings(&.{ 0x01, 0x00, 0x01, 0x00 })); // yinelenen
    const s = try parseSettings(&.{ 0x40, 0x99, 0x07 }); // bilinmeyen kimlik 0x99
    try testing.expectEqual(@as(u64, 0), s.qpack_blocked_streams);
}

test "h3: Huffman kodlayıcı — RFC 7541 C.4.1 ve gidiş-dönüş" {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(testing.allocator);
    try h2.huffmanEncode(&list, testing.allocator, "www.example.com");
    try testing.expectEqualSlices(u8, &.{ 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff }, list.items);
    try testing.expectEqual(list.items.len, h2.huffmanEncodedLen("www.example.com"));
    var back: std.ArrayListUnmanaged(u8) = .empty;
    defer back.deinit(testing.allocator);
    try h2.huffmanDecode(testing.allocator, list.items, &back);
    try testing.expectEqualStrings("www.example.com", back.items);
}

test "h3: QPACK statik tablo — kilit girişler ve RFC 9204 Ek B.1 vektörü" {
    try testing.expectEqualStrings(":path", static_table[1].name);
    try testing.expectEqualStrings("GET", static_table[17].value);
    try testing.expectEqualStrings("200", static_table[25].value);
    try testing.expectEqualStrings("x-frame-options", static_table[98].name);
    try testing.expectEqualStrings("sameorigin", static_table[98].value);
    // B.1: "0000 510b 2f69 6e64 6578 2e68 746d 6c" => :path: /index.html
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try decodeFieldSection(arena_state.allocator(), &.{ 0x00, 0x00, 0x51, 0x0b, 0x2f, 0x69, 0x6e, 0x64, 0x65, 0x78, 0x2e, 0x68, 0x74, 0x6d, 0x6c }, 1 << 20);
    try testing.expectEqual(@as(usize, 1), d.headers.len);
    try testing.expectEqualStrings(":path", d.headers[0].name);
    try testing.expectEqualStrings("/index.html", d.headers[0].value);
}

test "h3: QPACK gidiş-dönüş — tam eşleşme, ad atfı, literal ad, hassas başlık" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const hs = [_]Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/a/b?c=d" },
        .{ .name = "accept", .value = "text/html,application/xhtml+xml" },
        .{ .name = "x-nox-custom", .value = "değer-ü-ş-ı" },
        .{ .name = "cookie", .value = "sid=abc123" },
        .{ .name = "content-length", .value = "0" },
    };
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(testing.allocator);
    try encodeFieldSection(&list, testing.allocator, &hs);
    // İlk iki alan tam eşleşme: 0xd1 (GET=17), 0xd7 (https=23)
    try testing.expectEqual(@as(u8, 0xd1), list.items[2]);
    try testing.expectEqual(@as(u8, 0xd7), list.items[3]);
    const d = try decodeFieldSection(a, list.items, 1 << 20);
    try testing.expectEqual(hs.len, d.headers.len);
    for (hs, d.headers) |want, got| {
        try testing.expectEqualStrings(want.name, got.name);
        try testing.expectEqualStrings(want.value, got.value);
    }
}

test "h3: QPACK çözücü — dinamik tablo atfı ve bozuk giriş reddedilir" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectError(error.QpackDecompressionFailed, decodeFieldSection(a, &.{ 0x01, 0x00 }, 1 << 20)); // RIC=1
    try testing.expectError(error.QpackDecompressionFailed, decodeFieldSection(a, &.{ 0x00, 0x00, 0x80 }, 1 << 20)); // T=0 dinamik
    try testing.expectError(error.QpackDecompressionFailed, decodeFieldSection(a, &.{ 0x00, 0x00, 0x10 }, 1 << 20)); // post-base
    try testing.expectError(error.QpackDecompressionFailed, decodeFieldSection(a, &.{ 0x00, 0x00, 0xff, 0x7f }, 1 << 20)); // dizin >= 99
    try testing.expectError(error.QpackDecompressionFailed, decodeFieldSection(a, &.{ 0x00, 0x00, 0x51, 0x05, 0x61 }, 1 << 20)); // kesik değer
    try testing.expectError(error.QpackDecompressionFailed, decodeFieldSection(a, &.{0x00}, 1 << 20)); // kesik önek
    // Boyut sınırı
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(testing.allocator);
    try encodeFieldSection(&list, testing.allocator, &.{.{ .name = "x-big", .value = "0123456789" }});
    try testing.expectError(error.FieldSectionTooLarge, decodeFieldSection(a, list.items, 40));
}

test "h3: QPACK rastgele gidiş-dönüş (sabit tohum)" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var round: usize = 0;
    while (round < 200) : (round += 1) {
        const n = rnd.intRangeAtMost(usize, 0, 6);
        var hs: [6]Header = undefined;
        for (0..n) |i| {
            const nl = rnd.intRangeAtMost(usize, 1, 20);
            const vl = rnd.intRangeAtMost(usize, 0, 300);
            const name = try a.alloc(u8, nl);
            for (name) |*c| c.* = 'a' + rnd.uintLessThan(u8, 26);
            const value = try a.alloc(u8, vl);
            rnd.bytes(value);
            hs[i] = .{ .name = name, .value = value };
        }
        var list: std.ArrayListUnmanaged(u8) = .empty;
        defer list.deinit(testing.allocator);
        try encodeFieldSection(&list, testing.allocator, hs[0..n]);
        const d = try decodeFieldSection(a, list.items, 1 << 24);
        try testing.expectEqual(n, d.headers.len);
        for (hs[0..n], d.headers) |want, got| {
            try testing.expectEqualStrings(want.name, got.name);
            try testing.expectEqualSlices(u8, want.value, got.value);
        }
    }
}

test "h3: QPACK dinamik tablo — RFC 9204 Ek B.2 (ekleme + post-base atıf) ve Insert Count Increment" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var dec = QpackDecoder.init(testing.allocator, 220);
    defer dec.deinit();
    // Kodlayıcı akışı: kapasite 220; :authority=www.example.com (statik ad atfı); :path=/sample/path
    const enc_stream = [_]u8{ 0x3f, 0xbd, 0x01, 0xc0, 0x0f, 0x77, 0x77, 0x77, 0x2e, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x2e, 0x63, 0x6f, 0x6d, 0xc1, 0x0c, 0x2f, 0x73, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x2f, 0x70, 0x61, 0x74, 0x68 };
    // Parçalı gelişi de dene: ilk 7 bayt, sonra kalanı.
    try dec.processEncoderBytes(enc_stream[0..7]);
    try dec.processEncoderBytes(enc_stream[7..]);
    try testing.expectEqual(@as(u64, 2), dec.inserted);
    try testing.expectEqual(@as(usize, 220), dec.capacity);
    try testing.expectEqualSlices(u8, &.{0x02}, dec.out.items); // Insert Count Increment(2)
    // Alan bloğu: 03 81 10 11
    const d = try dec.decode(a, &.{ 0x03, 0x81, 0x10, 0x11 }, 1 << 20, 4);
    try testing.expectEqual(@as(usize, 2), d.headers.len);
    try testing.expectEqualStrings(":authority", d.headers[0].name);
    try testing.expectEqualStrings("www.example.com", d.headers[0].value);
    try testing.expectEqualStrings(":path", d.headers[1].name);
    try testing.expectEqualStrings("/sample/path", d.headers[1].value);
    // Section Acknowledgment(akış 4): 0x84
    try testing.expectEqualSlices(u8, &.{ 0x02, 0x84 }, dec.out.items);
}

test "h3: QPACK dinamik tablo — göreli atıf, çoğaltma, çıkarma ve geçersiz talimatlar" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var dec = QpackDecoder.init(testing.allocator, 256);
    defer dec.deinit();
    // Kapasite 128; literal ad "x-a"="1" (35 bayt) ; "x-b"="22" (36) ; çoğalt (göreli 1 = x-a) ; "x-c"="3" daha eklenince en eskiler çıkar.
    try dec.processEncoderBytes(&.{ 0x20 | 0x1f, 0x61 }); // capacity: 5 bit önek 31 + devam 0x61=97 -> 128
    try testing.expectEqual(@as(usize, 128), dec.capacity);
    try dec.processEncoderBytes(&.{ 0x43, 'x', '-', 'a', 0x01, '1' }); // literal ad (uzunluk 3), değer "1"
    try dec.processEncoderBytes(&.{ 0x43, 'x', '-', 'b', 0x02, '2', '2' });
    try dec.processEncoderBytes(&.{0x01}); // Duplicate göreli 1 -> x-a
    try testing.expectEqual(@as(u64, 3), dec.inserted);
    try testing.expectEqual(@as(usize, 36 + 37 + 36), dec.size);
    try dec.processEncoderBytes(&.{ 0x43, 'x', '-', 'c', 0x01, '3' }); // 106 + 35 > 128: en eski çıkarılır
    try testing.expectEqual(@as(u64, 1), dec.dropped);
    try testing.expect(dec.dynEntry(0) == null); // çıkarılmış
    try testing.expectEqualStrings("x-b", dec.dynEntry(1).?.name);
    // RIC kodlaması: max_entries=8, full_range=16; inserted=4 -> RIC=4 için enc = 4 % 16 + 1 = 5; Base=4 (delta 0). Göreli 0 = abs 3 (x-c), göreli 1 = abs 2 (x-a kopyası).
    const d = try dec.decode(a, &.{ 0x05, 0x00, 0x80, 0x81 }, 1 << 20, 8);
    try testing.expectEqualStrings("x-c", d.headers[0].name);
    try testing.expectEqualStrings("3", d.headers[0].value);
    try testing.expectEqualStrings("x-a", d.headers[1].name);
    // Çıkarılmış girişe atıf: abs 0
    try testing.expectError(error.QpackDecompressionFailed, dec.decode(a, &.{ 0x05, 0x00, 0x83 }, 1 << 20, 12)); // göreli 3 = abs 0 (çıkarılmış)
    // Bloklanacak blok (RIC > eklenen): enc 7 -> RIC 6 > 4
    try testing.expectError(error.QpackDecompressionFailed, dec.decode(a, &.{ 0x07, 0x00, 0x80 }, 1 << 20, 16));
    // Geçersiz kodlayıcı talimatları
    try testing.expectError(error.QpackEncoderStreamError, dec.processEncoderBytes(&.{ 0x20 | 0x1f, 0xff, 0x7f })); // kapasite > azami
    var dec2 = QpackDecoder.init(testing.allocator, 64);
    defer dec2.deinit();
    try testing.expectError(error.QpackEncoderStreamError, dec2.processEncoderBytes(&.{ 0x43, 'x', '-', 'a', 0x01, '1' })); // kapasite 0: sığmaz
    try testing.expectError(error.QpackEncoderStreamError, dec2.processEncoderBytes(&.{0x03})); // Duplicate: boş tablo
}
