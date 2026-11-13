//! HTTP/2 (RFC 9113) protokol katmanı: çerçeve (frame) kodlama ve HPACK (RFC 7541) başlık sıkıştırma. Soket, fiber ya da Nox türü bilmez; bağlantı motoru `http2_server.zig`dedir.
//!
//! HPACK kod çözücü tam özellikli (statik + dinamik tablo, tablo boyutu güncellemeleri, Huffman); kodlayıcı bilinçli olarak basittir (dinamik tablo ve Huffman kullanmaz): yanıt başlıkları
//! küçüktür, durumsuz kodlayıcı iş parçacığı güvenlidir ve karşı tarafın tablo boyutu ayarına bağımlılığı yoktur. Hata sınıfları: `CompressionError` (bağlantı hatası, COMPRESSION_ERROR) ve `OutOfMemory`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Header = struct { name: []const u8, value: []const u8 };

/// İstemci bağlantı ön eki (RFC 9113 §3.4).
pub const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

pub const frame_data: u8 = 0x0;
pub const frame_headers: u8 = 0x1;
pub const frame_priority: u8 = 0x2;
pub const frame_rst_stream: u8 = 0x3;
pub const frame_settings: u8 = 0x4;
pub const frame_push_promise: u8 = 0x5;
pub const frame_ping: u8 = 0x6;
pub const frame_goaway: u8 = 0x7;
pub const frame_window_update: u8 = 0x8;
pub const frame_continuation: u8 = 0x9;

pub const flag_end_stream: u8 = 0x1;
pub const flag_ack: u8 = 0x1;
pub const flag_end_headers: u8 = 0x4;
pub const flag_padded: u8 = 0x8;
pub const flag_priority: u8 = 0x20;

pub const ErrorCode = enum(u32) {
    no_error = 0x0,
    protocol_error = 0x1,
    internal_error = 0x2,
    flow_control_error = 0x3,
    settings_timeout = 0x4,
    stream_closed = 0x5,
    frame_size_error = 0x6,
    refused_stream = 0x7,
    cancel = 0x8,
    compression_error = 0x9,
    connect_error = 0xa,
    enhance_your_calm = 0xb,
    inadequate_security = 0xc,
    http_1_1_required = 0xd,
    _,
};

pub const setting_header_table_size: u16 = 0x1;
pub const setting_enable_push: u16 = 0x2;
pub const setting_max_concurrent_streams: u16 = 0x3;
pub const setting_initial_window_size: u16 = 0x4;
pub const setting_max_frame_size: u16 = 0x5;
pub const setting_max_header_list_size: u16 = 0x6;
/// RFC 8441: genişletilmiş CONNECT (`:protocol`) desteği.
pub const setting_enable_connect_protocol: u16 = 0x8;

pub const default_window: i64 = 65535;
pub const max_window: i64 = 2147483647;
pub const default_max_frame: u32 = 16384;
pub const max_allowed_frame: u32 = 16777215;

pub const FrameHeader = struct {
    length: u32,
    kind: u8,
    flags: u8,
    stream_id: u32,
};

pub fn parseFrameHeader(b: *const [9]u8) FrameHeader {
    return .{
        .length = (@as(u32, b[0]) << 16) | (@as(u32, b[1]) << 8) | b[2],
        .kind = b[3],
        .flags = b[4],
        .stream_id = std.mem.readInt(u32, b[5..9], .big) & 0x7fffffff,
    };
}

pub fn appendFrameHeader(list: *std.ArrayListUnmanaged(u8), gpa: Allocator, length: u32, kind: u8, flags: u8, stream_id: u32) Allocator.Error!void {
    std.debug.assert(length <= max_allowed_frame);
    var b: [9]u8 = undefined;
    b[0] = @intCast((length >> 16) & 0xff);
    b[1] = @intCast((length >> 8) & 0xff);
    b[2] = @intCast(length & 0xff);
    b[3] = kind;
    b[4] = flags;
    std.mem.writeInt(u32, b[5..9], stream_id & 0x7fffffff, .big);
    try list.appendSlice(gpa, &b);
}

pub fn appendU32(list: *std.ArrayListUnmanaged(u8), gpa: Allocator, v: u32) Allocator.Error!void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    try list.appendSlice(gpa, &b);
}

// ---- HPACK tabloları (üretilmiş) ----------------------------------------------------------------------------------------------------------------------

// RFC 7541 Ek A: statik tablo (1 tabanlı dizin = dizi indeksi + 1). Go'nun x/net/http2/hpack kaynağından üretildi.
pub const static_table = [61]Header{
    .{ .name = ":authority", .value = "" },
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":path", .value = "/" },
    .{ .name = ":path", .value = "/index.html" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":status", .value = "200" },
    .{ .name = ":status", .value = "204" },
    .{ .name = ":status", .value = "206" },
    .{ .name = ":status", .value = "304" },
    .{ .name = ":status", .value = "400" },
    .{ .name = ":status", .value = "404" },
    .{ .name = ":status", .value = "500" },
    .{ .name = "accept-charset", .value = "" },
    .{ .name = "accept-encoding", .value = "gzip, deflate" },
    .{ .name = "accept-language", .value = "" },
    .{ .name = "accept-ranges", .value = "" },
    .{ .name = "accept", .value = "" },
    .{ .name = "access-control-allow-origin", .value = "" },
    .{ .name = "age", .value = "" },
    .{ .name = "allow", .value = "" },
    .{ .name = "authorization", .value = "" },
    .{ .name = "cache-control", .value = "" },
    .{ .name = "content-disposition", .value = "" },
    .{ .name = "content-encoding", .value = "" },
    .{ .name = "content-language", .value = "" },
    .{ .name = "content-length", .value = "" },
    .{ .name = "content-location", .value = "" },
    .{ .name = "content-range", .value = "" },
    .{ .name = "content-type", .value = "" },
    .{ .name = "cookie", .value = "" },
    .{ .name = "date", .value = "" },
    .{ .name = "etag", .value = "" },
    .{ .name = "expect", .value = "" },
    .{ .name = "expires", .value = "" },
    .{ .name = "from", .value = "" },
    .{ .name = "host", .value = "" },
    .{ .name = "if-match", .value = "" },
    .{ .name = "if-modified-since", .value = "" },
    .{ .name = "if-none-match", .value = "" },
    .{ .name = "if-range", .value = "" },
    .{ .name = "if-unmodified-since", .value = "" },
    .{ .name = "last-modified", .value = "" },
    .{ .name = "link", .value = "" },
    .{ .name = "location", .value = "" },
    .{ .name = "max-forwards", .value = "" },
    .{ .name = "proxy-authenticate", .value = "" },
    .{ .name = "proxy-authorization", .value = "" },
    .{ .name = "range", .value = "" },
    .{ .name = "referer", .value = "" },
    .{ .name = "refresh", .value = "" },
    .{ .name = "retry-after", .value = "" },
    .{ .name = "server", .value = "" },
    .{ .name = "set-cookie", .value = "" },
    .{ .name = "strict-transport-security", .value = "" },
    .{ .name = "transfer-encoding", .value = "" },
    .{ .name = "user-agent", .value = "" },
    .{ .name = "vary", .value = "" },
    .{ .name = "via", .value = "" },
    .{ .name = "www-authenticate", .value = "" },
};

// RFC 7541 Ek B: Huffman kodları (257. sembol EOS). Kaynak: Go x/net/http2/hpack (EOS elle eklendi).
const huff_codes = [257]u32{
    0x1ff8,     0x7fffd8,  0xfffffe2,  0xfffffe3, 0xfffffe4, 0xfffffe5,  0xfffffe6,  0xfffffe7,
    0xfffffe8,  0xffffea,  0x3ffffffc, 0xfffffe9, 0xfffffea, 0x3ffffffd, 0xfffffeb,  0xfffffec,
    0xfffffed,  0xfffffee, 0xfffffef,  0xffffff0, 0xffffff1, 0xffffff2,  0x3ffffffe, 0xffffff3,
    0xffffff4,  0xffffff5, 0xffffff6,  0xffffff7, 0xffffff8, 0xffffff9,  0xffffffa,  0xffffffb,
    0x14,       0x3f8,     0x3f9,      0xffa,     0x1ff9,    0x15,       0xf8,       0x7fa,
    0x3fa,      0x3fb,     0xf9,       0x7fb,     0xfa,      0x16,       0x17,       0x18,
    0x0,        0x1,       0x2,        0x19,      0x1a,      0x1b,       0x1c,       0x1d,
    0x1e,       0x1f,      0x5c,       0xfb,      0x7ffc,    0x20,       0xffb,      0x3fc,
    0x1ffa,     0x21,      0x5d,       0x5e,      0x5f,      0x60,       0x61,       0x62,
    0x63,       0x64,      0x65,       0x66,      0x67,      0x68,       0x69,       0x6a,
    0x6b,       0x6c,      0x6d,       0x6e,      0x6f,      0x70,       0x71,       0x72,
    0xfc,       0x73,      0xfd,       0x1ffb,    0x7fff0,   0x1ffc,     0x3ffc,     0x22,
    0x7ffd,     0x3,       0x23,       0x4,       0x24,      0x5,        0x25,       0x26,
    0x27,       0x6,       0x74,       0x75,      0x28,      0x29,       0x2a,       0x7,
    0x2b,       0x76,      0x2c,       0x8,       0x9,       0x2d,       0x77,       0x78,
    0x79,       0x7a,      0x7b,       0x7ffe,    0x7fc,     0x3ffd,     0x1ffd,     0xffffffc,
    0xfffe6,    0x3fffd2,  0xfffe7,    0xfffe8,   0x3fffd3,  0x3fffd4,   0x3fffd5,   0x7fffd9,
    0x3fffd6,   0x7fffda,  0x7fffdb,   0x7fffdc,  0x7fffdd,  0x7fffde,   0xffffeb,   0x7fffdf,
    0xffffec,   0xffffed,  0x3fffd7,   0x7fffe0,  0xffffee,  0x7fffe1,   0x7fffe2,   0x7fffe3,
    0x7fffe4,   0x1fffdc,  0x3fffd8,   0x7fffe5,  0x3fffd9,  0x7fffe6,   0x7fffe7,   0xffffef,
    0x3fffda,   0x1fffdd,  0xfffe9,    0x3fffdb,  0x3fffdc,  0x7fffe8,   0x7fffe9,   0x1fffde,
    0x7fffea,   0x3fffdd,  0x3fffde,   0xfffff0,  0x1fffdf,  0x3fffdf,   0x7fffeb,   0x7fffec,
    0x1fffe0,   0x1fffe1,  0x3fffe0,   0x1fffe2,  0x7fffed,  0x3fffe1,   0x7fffee,   0x7fffef,
    0xfffea,    0x3fffe2,  0x3fffe3,   0x3fffe4,  0x7ffff0,  0x3fffe5,   0x3fffe6,   0x7ffff1,
    0x3ffffe0,  0x3ffffe1, 0xfffeb,    0x7fff1,   0x3fffe7,  0x7ffff2,   0x3fffe8,   0x1ffffec,
    0x3ffffe2,  0x3ffffe3, 0x3ffffe4,  0x7ffffde, 0x7ffffdf, 0x3ffffe5,  0xfffff1,   0x1ffffed,
    0x7fff2,    0x1fffe3,  0x3ffffe6,  0x7ffffe0, 0x7ffffe1, 0x3ffffe7,  0x7ffffe2,  0xfffff2,
    0x1fffe4,   0x1fffe5,  0x3ffffe8,  0x3ffffe9, 0xffffffd, 0x7ffffe3,  0x7ffffe4,  0x7ffffe5,
    0xfffec,    0xfffff3,  0xfffed,    0x1fffe6,  0x3fffe9,  0x1fffe7,   0x1fffe8,   0x7ffff3,
    0x3fffea,   0x3fffeb,  0x1ffffee,  0x1ffffef, 0xfffff4,  0xfffff5,   0x3ffffea,  0x7ffff4,
    0x3ffffeb,  0x7ffffe6, 0x3ffffec,  0x3ffffed, 0x7ffffe7, 0x7ffffe8,  0x7ffffe9,  0x7ffffea,
    0x7ffffeb,  0xffffffe, 0x7ffffec,  0x7ffffed, 0x7ffffee, 0x7ffffef,  0x7fffff0,  0x3ffffee,
    0x3fffffff,
};
const huff_lens = [257]u8{
    13, 23, 28, 28, 28, 28, 28, 28, 28, 24, 30, 28, 28, 30, 28, 28,
    28, 28, 28, 28, 28, 28, 30, 28, 28, 28, 28, 28, 28, 28, 28, 28,
    6,  10, 10, 12, 13, 6,  8,  11, 10, 10, 8,  11, 8,  6,  6,  6,
    5,  5,  5,  6,  6,  6,  6,  6,  6,  6,  7,  8,  15, 6,  12, 10,
    13, 6,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,
    7,  7,  7,  7,  7,  7,  7,  7,  8,  7,  8,  13, 19, 13, 14, 6,
    15, 5,  6,  5,  6,  5,  6,  6,  6,  5,  7,  7,  6,  6,  6,  5,
    6,  7,  6,  5,  5,  6,  7,  7,  7,  7,  7,  15, 11, 14, 13, 28,
    20, 22, 20, 20, 22, 22, 22, 23, 22, 23, 23, 23, 23, 23, 24, 23,
    24, 24, 22, 23, 24, 23, 23, 23, 23, 21, 22, 23, 22, 23, 23, 24,
    22, 21, 20, 22, 22, 23, 23, 21, 23, 22, 22, 24, 21, 22, 23, 23,
    21, 21, 22, 21, 23, 22, 23, 23, 20, 22, 22, 22, 23, 22, 22, 23,
    26, 26, 20, 19, 22, 23, 22, 25, 26, 26, 26, 27, 27, 26, 24, 25,
    19, 21, 26, 27, 27, 26, 27, 24, 21, 21, 26, 26, 28, 27, 27, 27,
    20, 24, 20, 21, 22, 21, 21, 23, 22, 22, 25, 25, 24, 24, 26, 23,
    26, 27, 26, 26, 27, 27, 27, 27, 27, 28, 27, 27, 27, 27, 27, 26,
    30,
};

// ---- Huffman ------------------------------------------------------------------------------------------------------------------------------------------

const HuffNode = struct {
    next: [2]u16 = .{ 0, 0 },
    sym: i16 = -1,
};

/// Kod ağacı derleme zamanında kurulur (257 yaprak, 256 iç düğüm; 0. düğüm kök, çocuk indeksi 0 = "yok").
const huff_tree: [520]HuffNode = blk: {
    @setEvalBranchQuota(200000);
    var nodes: [520]HuffNode = @splat(.{});
    var count: u16 = 1;
    for (0..257) |sym| {
        var node: u16 = 0;
        var i: u6 = @intCast(huff_lens[sym]);
        while (i > 0) {
            i -= 1;
            const bit: usize = @intCast((huff_codes[sym] >> @as(u5, @intCast(i))) & 1);
            if (nodes[node].next[bit] == 0) {
                nodes[node].next[bit] = count;
                count += 1;
            }
            node = nodes[node].next[bit];
        }
        nodes[node].sym = @intCast(sym);
    }
    break :blk nodes;
};

/// RFC 7541 §5.2: Huffman çözme. Dolgu 7 bitten kısa ve hep 1 olmalı, EOS sembolü veri içinde görünmemeli.
pub fn huffmanDecode(gpa: Allocator, input: []const u8, out: *std.ArrayListUnmanaged(u8)) error{ CompressionError, OutOfMemory }!void {
    var node: u16 = 0;
    var pending_bits: u32 = 0;
    var all_ones = true;
    for (input) |byte| {
        var i: u4 = 8;
        while (i > 0) {
            i -= 1;
            const bit: usize = (byte >> @as(u3, @intCast(i))) & 1;
            node = huff_tree[node].next[bit];
            if (node == 0) return error.CompressionError;
            pending_bits += 1;
            if (bit == 0) all_ones = false;
            const sym = huff_tree[node].sym;
            if (sym >= 0) {
                if (sym == 256) return error.CompressionError;
                try out.append(gpa, @intCast(sym));
                node = 0;
                pending_bits = 0;
                all_ones = true;
            }
        }
    }
    if (pending_bits > 7 or !all_ones) return error.CompressionError;
}

/// RFC 7541 §5.2: Huffman ile kodlanmış uzunluk (bayt). HTTP/3 QPACK da AYNI tabloyu kullanır (RFC 9204 §4.1.2).
pub fn huffmanEncodedLen(s: []const u8) usize {
    var bits: usize = 0;
    for (s) |b| bits += huff_lens[b];
    return (bits + 7) / 8;
}

/// RFC 7541 §5.2: Huffman kodlama (son bayt EOS önekinin 1 bitleriyle doldurulur).
pub fn huffmanEncode(list: *std.ArrayListUnmanaged(u8), gpa: Allocator, s: []const u8) Allocator.Error!void {
    var acc: u64 = 0;
    var nbits: u6 = 0;
    for (s) |b| {
        const len: u6 = @intCast(huff_lens[b]);
        acc = (acc << len) | huff_codes[b];
        nbits += len;
        while (nbits >= 8) {
            nbits -= 8;
            try list.append(gpa, @intCast((acc >> nbits) & 0xff));
        }
    }
    if (nbits > 0) {
        const pad: u6 = 8 - nbits;
        try list.append(gpa, @intCast(((acc << pad) | ((@as(u64, 1) << pad) - 1)) & 0xff));
    }
}

// ---- HPACK kod çözücü ---------------------------------------------------------------------------------------------------------------------------------

const DynEntry = struct { name: []u8, value: []u8 };

/// Bağlantı başına BİR kod çözücü: her başlık bloğu (reddedilen akışlarınki dahil) sırayla çözülmelidir, aksi halde dinamik tablo ayrışır.
pub const Decoder = struct {
    gpa: Allocator,
    /// 0 = en yeni giriş (RFC 7541 §2.3.3: dinamik dizin 62 = en yeni).
    entries: std.ArrayListUnmanaged(DynEntry) = .empty,
    size: usize = 0,
    /// Karşı tarafın ayarlayabileceği üst sınır (bizim SETTINGS_HEADER_TABLE_SIZE değerimiz).
    limit: usize,
    /// Geçerli tablo üst sınırı (güncelleme ile `limit`e kadar değişebilir).
    cur_max: usize,

    pub fn init(gpa: Allocator, limit: usize) Decoder {
        return .{ .gpa = gpa, .limit = limit, .cur_max = limit };
    }

    pub fn deinit(self: *Decoder) void {
        for (self.entries.items) |e| {
            self.gpa.free(e.name);
            self.gpa.free(e.value);
        }
        self.entries.deinit(self.gpa);
    }

    fn evictTo(self: *Decoder, target: usize) void {
        while (self.size > target and self.entries.items.len > 0) {
            const e = self.entries.pop().?;
            self.size -= e.name.len + e.value.len + 32;
            self.gpa.free(e.name);
            self.gpa.free(e.value);
        }
    }

    fn insert(self: *Decoder, name: []const u8, value: []const u8) Allocator.Error!void {
        const entry_size = name.len + value.len + 32;
        if (entry_size > self.cur_max) {
            // RFC 7541 §4.4: tablodan büyük giriş tabloyu boşaltır, eklenmez.
            self.evictTo(0);
            return;
        }
        self.evictTo(self.cur_max - entry_size);
        const n = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(n);
        const v = try self.gpa.dupe(u8, value);
        errdefer self.gpa.free(v);
        try self.entries.insert(self.gpa, 0, .{ .name = n, .value = v });
        self.size += entry_size;
    }

    fn lookup(self: *const Decoder, index: usize) ?Header {
        if (index == 0) return null;
        if (index <= static_table.len) return static_table[index - 1];
        const di = index - static_table.len - 1;
        if (di >= self.entries.items.len) return null;
        const e = self.entries.items[di];
        return .{ .name = e.name, .value = e.value };
    }

    /// `block`u çözer; her alan `out_alloc` ile kopyalanarak `out`a eklenir (çağıran genelde bir arena verir). Toplam liste boyutu (ad + değer + 32) `max_list_bytes`ı aşarsa kalan alanlar
    /// atılır ama blok sonuna kadar çözülür (dinamik tablo eşzamanlı kalsın); dönüş değeri `true` = aşıldı.
    pub fn decode(self: *Decoder, block: []const u8, out_alloc: Allocator, out: *std.ArrayListUnmanaged(Header), max_list_bytes: usize) error{ CompressionError, OutOfMemory }!bool {
        var pos: usize = 0;
        var exceeded = false;
        var total: usize = 0;
        var seen_field = false;
        while (pos < block.len) {
            const b = block[pos];
            if (b & 0x80 != 0) {
                // Indexed Header Field
                const idx = try readInt(block, &pos, 7);
                const h = self.lookup(idx) orelse return error.CompressionError;
                seen_field = true;
                try self.emit(out_alloc, out, h.name, h.value, max_list_bytes, &total, &exceeded);
            } else if (b & 0xc0 == 0x40) {
                // Literal with Incremental Indexing
                const name_idx = try readInt(block, &pos, 6);
                const field = try self.readLiteral(block, &pos, name_idx, out_alloc);
                try self.insert(field.name, field.value);
                seen_field = true;
                try self.emit(out_alloc, out, field.name, field.value, max_list_bytes, &total, &exceeded);
            } else if (b & 0xe0 == 0x20) {
                // Dynamic Table Size Update: yalnızca blok başında.
                if (seen_field) return error.CompressionError;
                const new_max = try readInt(block, &pos, 5);
                if (new_max > self.limit) return error.CompressionError;
                self.cur_max = new_max;
                self.evictTo(new_max);
            } else {
                // Literal without Indexing (0000) / Never Indexed (0001)
                const name_idx = try readInt(block, &pos, 4);
                const field = try self.readLiteral(block, &pos, name_idx, out_alloc);
                seen_field = true;
                try self.emit(out_alloc, out, field.name, field.value, max_list_bytes, &total, &exceeded);
            }
        }
        return exceeded;
    }

    fn emit(self: *Decoder, out_alloc: Allocator, out: *std.ArrayListUnmanaged(Header), name: []const u8, value: []const u8, max_list_bytes: usize, total: *usize, exceeded: *bool) error{OutOfMemory}!void {
        _ = self;
        if (exceeded.*) return;
        total.* += name.len + value.len + 32;
        if (total.* > max_list_bytes) {
            exceeded.* = true;
            return;
        }
        const n = try out_alloc.dupe(u8, name);
        const v = try out_alloc.dupe(u8, value);
        try out.append(out_alloc, .{ .name = n, .value = v });
    }

    /// Ad (dizinden ya da değişmez dizeden) ve değeri okur; dizeler `out_alloc` içinde yaşar.
    fn readLiteral(self: *Decoder, block: []const u8, pos: *usize, name_idx: usize, out_alloc: Allocator) error{ CompressionError, OutOfMemory }!Header {
        const name: []const u8 = if (name_idx == 0)
            try readString(block, pos, out_alloc)
        else
            (self.lookup(name_idx) orelse return error.CompressionError).name;
        const value = try readString(block, pos, out_alloc);
        return .{ .name = name, .value = value };
    }
};

/// RFC 7541 §5.1: `prefix_bits` bitlik önekli tamsayı. Taşmaya karşı korumalı (2^31 üstü reddedilir).
pub fn readInt(block: []const u8, pos: *usize, prefix_bits: u4) error{CompressionError}!usize {
    if (pos.* >= block.len) return error.CompressionError;
    const mask: usize = (@as(usize, 1) << prefix_bits) - 1;
    var v: usize = block[pos.*] & mask;
    pos.* += 1;
    if (v < mask) return v;
    var shift: u32 = 0;
    while (true) {
        if (pos.* >= block.len) return error.CompressionError;
        const b = block[pos.*];
        pos.* += 1;
        if (shift > 28) return error.CompressionError;
        v += (@as(usize, b & 0x7f)) << @as(std.math.Log2Int(usize), @intCast(shift));
        if (v > 0x7fffffff) return error.CompressionError;
        if (b & 0x80 == 0) return v;
        shift += 7;
    }
}

fn readString(block: []const u8, pos: *usize, out_alloc: Allocator) error{ CompressionError, OutOfMemory }![]const u8 {
    if (pos.* >= block.len) return error.CompressionError;
    const huffman = block[pos.*] & 0x80 != 0;
    const len = try readInt(block, pos, 7);
    if (len > block.len - pos.*) return error.CompressionError;
    const raw = block[pos.*..][0..len];
    pos.* += len;
    if (!huffman) return out_alloc.dupe(u8, raw);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(out_alloc);
    try huffmanDecode(out_alloc, raw, &buf);
    return buf.toOwnedSlice(out_alloc);
}

// ---- HPACK kodlayıcı (durumsuz, Huffman'sız) -------------------------------------------------------------------------------------------------------------------------

pub fn appendInt(list: *std.ArrayListUnmanaged(u8), gpa: Allocator, first_bits: u8, prefix_bits: u4, value: usize) Allocator.Error!void {
    const mask: usize = (@as(usize, 1) << prefix_bits) - 1;
    if (value < mask) {
        try list.append(gpa, first_bits | @as(u8, @intCast(value)));
        return;
    }
    try list.append(gpa, first_bits | @as(u8, @intCast(mask)));
    var rest = value - mask;
    while (rest >= 128) {
        try list.append(gpa, @as(u8, @intCast(rest & 0x7f)) | 0x80);
        rest >>= 7;
    }
    try list.append(gpa, @intCast(rest));
}

fn appendString(list: *std.ArrayListUnmanaged(u8), gpa: Allocator, s: []const u8) Allocator.Error!void {
    try appendInt(list, gpa, 0, 7, s.len);
    try list.appendSlice(gpa, s);
}

fn isSensitive(name: []const u8) bool {
    return std.mem.eql(u8, name, "set-cookie") or std.mem.eql(u8, name, "authorization") or std.mem.eql(u8, name, "cookie") or std.mem.eql(u8, name, "proxy-authorization");
}

/// Tek bir alanı kodlar. `name` küçük harf olmalıdır. Statik tabloda tam eşleşme → dizinli; ad eşleşmesi → adı dizinle atıfla, değeri değişmez; yoksa ikisi de değişmez dize.
/// Dinamik tabloya EKLEME YAPILMAZ ("without indexing"); çerez/yetki başlıkları "never indexed" işaretlenir.
pub fn encodeField(list: *std.ArrayListUnmanaged(u8), gpa: Allocator, name: []const u8, value: []const u8) Allocator.Error!void {
    var name_idx: usize = 0;
    for (static_table, 0..) |e, i| {
        if (!std.mem.eql(u8, e.name, name)) continue;
        if (name_idx == 0) name_idx = i + 1;
        if (std.mem.eql(u8, e.value, value) and value.len > 0) {
            try appendInt(list, gpa, 0x80, 7, i + 1);
            return;
        }
    }
    const first: u8 = if (isSensitive(name)) 0x10 else 0x00;
    if (name_idx != 0) {
        try appendInt(list, gpa, first, 4, name_idx);
    } else {
        try list.append(gpa, first);
        try appendString(list, gpa, name);
    }
    try appendString(list, gpa, value);
}

/// Yanıt başlık bloğu: `:status` ve ardından `headers` (adları küçük harfe çevrilir, bağlantıya özgü alanlar atlanır).
pub fn encodeResponseBlock(list: *std.ArrayListUnmanaged(u8), gpa: Allocator, status: u16, headers: []const std.http.Header) Allocator.Error!void {
    var status_buf: [3]u8 = undefined;
    const code: u16 = if (status < 100 or status > 999) 500 else status;
    _ = std.fmt.bufPrint(&status_buf, "{d}", .{code}) catch unreachable;
    try encodeField(list, gpa, ":status", &status_buf);
    for (headers) |h| {
        if (isConnectionSpecific(h.name)) continue;
        var lower: [128]u8 = undefined;
        if (h.name.len == 0 or h.name.len > lower.len) continue;
        for (h.name, 0..) |c, i| lower[i] = std.ascii.toLower(c);
        try encodeField(list, gpa, lower[0..h.name.len], h.value);
    }
}

/// RFC 9113 §8.2.2: bu alanlar HTTP/2 mesajında bulunamaz.
pub fn isConnectionSpecific(name: []const u8) bool {
    const names = [_][]const u8{ "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade" };
    for (names) |n| if (std.ascii.eqlIgnoreCase(n, name)) return true;
    return false;
}

// ---- Testler -------------------------------------------------------------------------------------------------------------------------------------------

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

test "huffman: RFC 7541 Ek C.4 örnek dizeleri çözülür" {
    const a = std.testing.allocator;
    const cases = .{
        .{ hex("f1e3c2e5f23a6ba0ab90f4ff"), "www.example.com" },
        .{ hex("a8eb10649cbf"), "no-cache" },
        .{ hex("25a849e95ba97d7f"), "custom-key" },
        .{ hex("25a849e95bb8e8b4bf"), "custom-value" },
    };
    inline for (cases) |c| {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(a);
        try huffmanDecode(a, &c[0], &out);
        try std.testing.expectEqualStrings(c[1], out.items);
    }
}

test "huffman: geçersiz dolgu (0 bitli) ve EOS reddedilir" {
    const a = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    // 'a' (00011) + dolgu 000: dolgu hep 1 olmalı.
    try std.testing.expectError(error.CompressionError, huffmanDecode(a, &[_]u8{0x18}, &out));
    // 30 bitlik EOS kodu (hepsi 1) + sonrası.
    try std.testing.expectError(error.CompressionError, huffmanDecode(a, &[_]u8{ 0xff, 0xff, 0xff, 0xff }, &out));
}

test "hpack: RFC 7541 Ek C.4 (Huffman'lı) istek dizisi dinamik tabloyla çözülür" {
    const a = std.testing.allocator;
    var d = Decoder.init(a, 4096);
    defer d.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var h1: std.ArrayListUnmanaged(Header) = .empty;
    const b1 = hex("828684418cf1e3c2e5f23a6ba0ab90f4ff");
    try std.testing.expect(!try d.decode(&b1, arena.allocator(), &h1, 8192));
    try std.testing.expectEqual(@as(usize, 4), h1.items.len);
    try std.testing.expectEqualStrings(":method", h1.items[0].name);
    try std.testing.expectEqualStrings("GET", h1.items[0].value);
    try std.testing.expectEqualStrings(":authority", h1.items[3].name);
    try std.testing.expectEqualStrings("www.example.com", h1.items[3].value);
    try std.testing.expectEqual(@as(usize, 57), d.size);

    var h2: std.ArrayListUnmanaged(Header) = .empty;
    const b2 = hex("828684be5886a8eb10649cbf");
    try std.testing.expect(!try d.decode(&b2, arena.allocator(), &h2, 8192));
    try std.testing.expectEqual(@as(usize, 5), h2.items.len);
    try std.testing.expectEqualStrings("www.example.com", h2.items[3].value); // dinamik dizin 62
    try std.testing.expectEqualStrings("cache-control", h2.items[4].name);
    try std.testing.expectEqualStrings("no-cache", h2.items[4].value);
    try std.testing.expectEqual(@as(usize, 110), d.size);

    var h3: std.ArrayListUnmanaged(Header) = .empty;
    const b3 = hex("828785bf408825a849e95ba97d7f8925a849e95bb8e8b4bf");
    try std.testing.expect(!try d.decode(&b3, arena.allocator(), &h3, 8192));
    try std.testing.expectEqual(@as(usize, 5), h3.items.len);
    try std.testing.expectEqualStrings("/index.html", h3.items[2].value);
    try std.testing.expectEqualStrings("custom-key", h3.items[4].name);
    try std.testing.expectEqualStrings("custom-value", h3.items[4].value);
    try std.testing.expectEqual(@as(usize, 164), d.size);
}

test "hpack: tablo boyutu güncellemesi blok başında olmalı ve sınırı aşamaz; dizin 0 ve tablo dışı dizin hatadır" {
    const a = std.testing.allocator;
    var d = Decoder.init(a, 4096);
    defer d.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var h: std.ArrayListUnmanaged(Header) = .empty;
    // Alandan SONRA güncelleme: hata.
    try std.testing.expectError(error.CompressionError, d.decode(&[_]u8{ 0x82, 0x3f, 0xe1, 0x1f }, arena.allocator(), &h, 8192));
    // Sınırın (4096) üstüne güncelleme: hata.
    try std.testing.expectError(error.CompressionError, d.decode(&[_]u8{ 0x3f, 0xe2, 0x1f }, arena.allocator(), &h, 8192));
    // Dizin 0.
    try std.testing.expectError(error.CompressionError, d.decode(&[_]u8{0x80}, arena.allocator(), &h, 8192));
    // Boş dinamik tabloda dizin 62.
    try std.testing.expectError(error.CompressionError, d.decode(&[_]u8{0xbe}, arena.allocator(), &h, 8192));
    // Kesik tamsayı ve kesik dize.
    try std.testing.expectError(error.CompressionError, d.decode(&[_]u8{ 0xff, 0x80 }, arena.allocator(), &h, 8192));
    try std.testing.expectError(error.CompressionError, d.decode(&[_]u8{ 0x40, 0x05, 'a' }, arena.allocator(), &h, 8192));
}

test "hpack: dinamik tablo taşınca en eskiler atılır; küçük sınır büyük girişi tabloya almaz" {
    const a = std.testing.allocator;
    var d = Decoder.init(a, 100);
    defer d.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var h: std.ArrayListUnmanaged(Header) = .empty;
    // Her giriş: "x"(1) + 20 bayt değer + 32 = 53 bayt. İkincisi birincisini atar (sınır 100).
    var blk: std.ArrayListUnmanaged(u8) = .empty;
    defer blk.deinit(a);
    for ([_][]const u8{ "aaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbb" }) |v| {
        try blk.append(a, 0x40);
        try appendString(&blk, a, "x");
        try appendString(&blk, a, v);
    }
    _ = try d.decode(blk.items, arena.allocator(), &h, 8192);
    try std.testing.expectEqual(@as(usize, 1), d.entries.items.len);
    try std.testing.expectEqualStrings("bbbbbbbbbbbbbbbbbbbb", d.entries.items[0].value);
    // 100 bayttan büyük giriş tabloyu boşaltır.
    var big: std.ArrayListUnmanaged(u8) = .empty;
    defer big.deinit(a);
    try big.append(a, 0x40);
    try appendString(&big, a, "y");
    try appendString(&big, a, "c" ** 90);
    _ = try d.decode(big.items, arena.allocator(), &h, 8192);
    try std.testing.expectEqual(@as(usize, 0), d.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), d.size);
}

test "hpack: liste boyutu sınırı aşılınca kalan alanlar atılır ama blok tamamen çözülür (tablo eşzamanlı kalır)" {
    const a = std.testing.allocator;
    var d = Decoder.init(a, 4096);
    defer d.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var blk: std.ArrayListUnmanaged(u8) = .empty;
    defer blk.deinit(a);
    try encodeField(&blk, a, "x-a", "1");
    try blk.append(a, 0x40);
    try appendString(&blk, a, "x-big");
    try appendString(&blk, a, "v" ** 300);
    try blk.append(a, 0x40);
    try appendString(&blk, a, "x-after");
    try appendString(&blk, a, "z");
    var h: std.ArrayListUnmanaged(Header) = .empty;
    try std.testing.expect(try d.decode(blk.items, arena.allocator(), &h, 200));
    try std.testing.expectEqual(@as(usize, 1), h.items.len); // yalnızca x-a sığdı
    try std.testing.expectEqual(@as(usize, 2), d.entries.items.len); // iki indekslenen alan da tabloda
}

test "hpack: kodlayıcı → kod çözücü gidiş-dönüş (statik dizin, ad dizini, değişmez ad, gizli alan)" {
    const a = std.testing.allocator;
    var d = Decoder.init(a, 4096);
    defer d.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var blk: std.ArrayListUnmanaged(u8) = .empty;
    defer blk.deinit(a);
    const hdrs = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "text/plain" },
        .{ .name = "X-Custom-Thing", .value = "değer" },
        .{ .name = "Set-Cookie", .value = "a=1" },
        .{ .name = "Connection", .value = "close" }, // atlanmalı
        .{ .name = "Content-Length", .value = "5" },
    };
    try encodeResponseBlock(&blk, a, 200, &hdrs);
    try std.testing.expectEqual(@as(u8, 0x88), blk.items[0]); // :status 200 = statik 8
    var out: std.ArrayListUnmanaged(Header) = .empty;
    try std.testing.expect(!try d.decode(blk.items, arena.allocator(), &out, 8192));
    try std.testing.expectEqual(@as(usize, 5), out.items.len);
    try std.testing.expectEqualStrings("content-type", out.items[1].name);
    try std.testing.expectEqualStrings("text/plain", out.items[1].value);
    try std.testing.expectEqualStrings("x-custom-thing", out.items[2].name);
    try std.testing.expectEqualStrings("değer", out.items[2].value);
    try std.testing.expectEqualStrings("set-cookie", out.items[3].name);
    try std.testing.expectEqualStrings("content-length", out.items[4].name);
    try std.testing.expectEqual(@as(usize, 0), d.entries.items.len); // kodlayıcı tabloya eklemez
    // Bilinmeyen durum kodu: ad dizini + değişmez değer.
    blk.clearRetainingCapacity();
    try encodeResponseBlock(&blk, a, 418, &.{});
    out.clearRetainingCapacity();
    _ = try d.decode(blk.items, arena.allocator(), &out, 8192);
    try std.testing.expectEqualStrings("418", out.items[0].value);
}

test "çerçeve başlığı: gidiş-dönüş, ayrılmış bit maskelenir" {
    const a = std.testing.allocator;
    var l: std.ArrayListUnmanaged(u8) = .empty;
    defer l.deinit(a);
    try appendFrameHeader(&l, a, 0x010203, frame_headers, flag_end_headers | flag_end_stream, 0x7fffffff);
    const fh = parseFrameHeader(l.items[0..9]);
    try std.testing.expectEqual(@as(u32, 0x010203), fh.length);
    try std.testing.expectEqual(frame_headers, fh.kind);
    try std.testing.expectEqual(@as(u8, 5), fh.flags);
    try std.testing.expectEqual(@as(u32, 0x7fffffff), fh.stream_id);
    var raw = [9]u8{ 0, 0, 1, 0, 0, 0xff, 0xff, 0xff, 0xff };
    try std.testing.expectEqual(@as(u32, 0x7fffffff), parseFrameHeader(&raw).stream_id);
}
