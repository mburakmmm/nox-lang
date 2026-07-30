//! `nox.websocket` Zig kabuğu — Faz NN.5 (bkz. proje belleği "nyx v2
//! limitasyon listesi doğrulaması"): RFC 6455 WebSocket — el sıkışma
//! (handshake) + frame kodlama/çözme (maskeleme DAHİL). SAF Zig kodudur
//! (SHA1/base64 Zig'in KENDİ std kütüphanesi) — HİÇBİR harici bağımlılık
//! YOK.
//!
//! **Bilinçli v1 kapsamı**: SADECE İSTEMCİ (`nox_ws_connect_raw`) —
//! `nox.http.serve`nin (`runtime/stdlib_shims/http_server.zig`, ~1400
//! satır, fiber-zamanlayıcısına/reaktöre ENTEGRE karmaşık bir async
//! sunucu) İÇİNE bir Upgrade-algıla-VE-soketi-çal (hijack) yolu EKLEMEK,
//! bu fazın kapsamı İçin ORANSIZ bir RİSK/karmaşıklık taşırdı — bu YÜZDEN
//! `nox.websocket` sunucu tarafı bu fazın kapsamı DIŞINDA bırakıldı,
//! AÇIKÇA belgelendi (AYRI bir takip görevi olarak flaglenmelidir).
//!
//! **Senkron/bloklayan**: `nox.tls`nin AYNI v1 basitleştirmesi — `connect`/
//! `send`/`recv` ÇAĞIRAN iş parçacığını DOĞRUDAN BLOKLAR.

const std = @import("std");
const arc = @import("../alloc/arc.zig");
const str_mod = @import("../str.zig");
const http_client = @import("http_client.zig");

fn dupeToNoxStr(rt: ?*anyopaque, bytes: []const u8) ?[*:0]u8 {
    return str_mod.nox_str_from_bytes(rt, bytes);
}

fn dupeEmpty(rt: ?*anyopaque) ?[*:0]u8 {
    return dupeToNoxStr(rt, "");
}

const LoadState = enum(u8) { uninit, initializing, ready, failed };
var g_ca_state: std.atomic.Value(LoadState) = .init(.uninit);
var g_ca_bundle: std.crypto.Certificate.Bundle = .empty;
var g_ca_lock: std.Io.RwLock = .init;

fn ensureCaBundle(io: std.Io) bool {
    if (g_ca_state.cmpxchgStrong(.uninit, .initializing, .acquire, .monotonic) == null) {
        const now = std.Io.Timestamp.now(io, .real);
        const ok = if (g_ca_bundle.rescan(std.heap.page_allocator, io, now)) |_| true else |_| false;
        g_ca_state.store(if (ok) .ready else .failed, .release);
    } else {
        while (true) {
            const s = g_ca_state.load(.acquire);
            if (s == .ready or s == .failed) break;
            std.Thread.yield() catch {};
        }
    }
    return g_ca_state.load(.acquire) == .ready;
}

const BUF: usize = std.crypto.tls.Client.min_buffer_len;
const websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// RFC 6455 `Sec-WebSocket-Accept` hesaplaması (`SHA1(key_b64 ++ GUID)`
/// base64) — İSTEMCİ (BURADA, sunucunun döndürdüğü değeri DOĞRULAMAK
/// İçİn) VE `websocket_server.zig`nin sunucu tarafı (AYNI değeri
/// ÜRETMEK İçİn) TARAFINDAN PAYLAŞILIR — Faz "sunucu-tarafı TLS + WS
/// Upgrade" İLE (bkz. plan dosyası) `connectInner`nin İÇİNE GÖMÜLÜ
/// hesaplamadan BURAYA ÇIKARILDI (davranış DEĞİŞMEDİ, saf sadeleştirme).
pub fn computeAcceptValue(key_b64: []const u8, out: *[28]u8) void {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key_b64);
    sha1.update(websocket_guid);
    var digest: [20]u8 = undefined;
    sha1.final(&digest);
    _ = std.base64.standard.Encoder.encode(out, &digest);
}

/// `net.Stream.Reader.interface`/`Writer.interface`i DOĞRUDAN kullanır
/// (plaintext yol), TLS İSE `tls_client` ARACILIĞIYLA (bkz. `nox.tls`nin
/// AYNI `@fieldParentPtr` güvenlik gerekçesi — TEK bir heap-tahsisi,
/// adresi ASLA değişmez).
const WsConn = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    sock_read_buf: [BUF]u8 = undefined,
    sock_write_buf: [BUF]u8 = undefined,
    tls_read_buf: [BUF]u8 = undefined,
    tls_write_buf: [BUF]u8 = undefined,
    stream_reader: std.Io.net.Stream.Reader = undefined,
    stream_writer: std.Io.net.Stream.Writer = undefined,
    tls_client: std.crypto.tls.Client = undefined,
    use_tls: bool = false,
    connected: bool = false,
    errmsg: []const u8 = "",

    fn reader(self: *WsConn) *std.Io.Reader {
        return if (self.use_tls) &self.tls_client.reader else &self.stream_reader.interface;
    }
    fn writer(self: *WsConn) *std.Io.Writer {
        return if (self.use_tls) &self.tls_client.writer else &self.stream_writer.interface;
    }
    fn flushAll(self: *WsConn) !void {
        if (self.use_tls) try self.tls_client.writer.flush();
        try self.stream_writer.interface.flush();
    }
};


fn connectInner(conn: *WsConn, host: []const u8, port: i64, path: []const u8, use_tls: bool) !void {
    const io = conn.io;
    var host_name = try std.Io.net.HostName.init(host);
    conn.stream = try host_name.connect(io, @intCast(port), .{ .mode = .stream });
    conn.stream_reader = conn.stream.reader(io, &conn.sock_read_buf);
    conn.stream_writer = conn.stream.writer(io, &conn.sock_write_buf);
    conn.use_tls = use_tls;

    if (use_tls) {
        if (!ensureCaBundle(io)) return error.CaBundleLoadFailed;
        var random_buffer: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&random_buffer);
        const now = std.Io.Timestamp.now(io, .real);
        conn.tls_client = try std.crypto.tls.Client.init(&conn.stream_reader.interface, &conn.stream_writer.interface, .{
            .host = .{ .explicit = host },
            .ca = .{ .bundle = .{
                .gpa = std.heap.page_allocator,
                .io = io,
                .lock = &g_ca_lock,
                .bundle = &g_ca_bundle,
            } },
            .ssl_key_log = null,
            .read_buffer = &conn.tls_read_buf,
            .write_buffer = &conn.tls_write_buf,
            .entropy = &random_buffer,
            .realtime_now = now,
            .allow_truncation_attacks = false,
        });
    }

    // --- RFC 6455 el sıkışması ---
    var key_raw: [16]u8 = undefined;
    io.random(&key_raw);
    var key_b64_buf: [24]u8 = undefined;
    const key_b64 = std.base64.standard.Encoder.encode(&key_b64_buf, &key_raw);

    var req_buf: [1024]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf,
        \\GET {s} HTTP/1.1
        \\Host: {s}
        \\Upgrade: websocket
        \\Connection: Upgrade
        \\Sec-WebSocket-Key: {s}
        \\Sec-WebSocket-Version: 13
        \\
        \\
    , .{ path, host, key_b64 });
    // `\r\n` HTTP satır sonlandırıcısı ZORUNLUDUR (yukarıdaki multiline
    // dize LİTERALİ yalnızca `\n` üretir) — SATIR SONLARINI `\r\n`e çevir.
    var crlf_buf: [1200]u8 = undefined;
    var crlf_len: usize = 0;
    for (req) |c| {
        if (c == '\n') {
            crlf_buf[crlf_len] = '\r';
            crlf_len += 1;
        }
        crlf_buf[crlf_len] = c;
        crlf_len += 1;
    }

    try conn.writer().writeAll(crlf_buf[0..crlf_len]);
    try conn.flushAll();

    // Yanıt başlıklarını satır satır oku (`\r\n\r\n` bitene kadar) —
    // `101` durum koduyla başladığını VE `Sec-WebSocket-Accept`in beklenen
    // değerle eşleştiğini doğrula.
    var status_line_buf: [512]u8 = undefined;
    const status_line = try conn.reader().takeDelimiterInclusive('\n');
    _ = std.mem.copyForwards(u8, &status_line_buf, status_line);
    if (std.mem.indexOf(u8, status_line, "101") == null) return error.HandshakeRejected;

    var accept_ok = false;
    while (true) {
        const line = try conn.reader().takeDelimiterInclusive('\n');
        const trimmed = std.mem.trim(u8, line, "\r\n ");
        if (trimmed.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(trimmed, "sec-websocket-accept:")) {
            const value = std.mem.trim(u8, trimmed["sec-websocket-accept:".len..], " ");
            var expected_buf: [28]u8 = undefined;
            computeAcceptValue(key_b64, &expected_buf);
            if (std.mem.eql(u8, value, &expected_buf)) accept_ok = true;
        }
    }
    if (!accept_ok) return error.HandshakeAcceptMismatch;
}

pub export fn nox_ws_connect_raw(host: ?[*:0]const u8, port: i64, path: ?[*:0]const u8, use_tls: i64) callconv(.c) ?*anyopaque {
    const gpa = std.heap.page_allocator;
    const conn = gpa.create(WsConn) catch return null;
    conn.* = .{ .gpa = gpa, .io = http_client.sharedClientIo(), .stream = undefined };
    const h = host orelse {
        conn.errmsg = "host bos olamaz";
        return conn;
    };
    const p = path orelse {
        conn.errmsg = "path bos olamaz";
        return conn;
    };
    connectInner(conn, str_mod.nox_str_slice(h), port, str_mod.nox_str_slice(p), use_tls != 0) catch |err| {
        conn.errmsg = @errorName(err);
        conn.connected = false;
        return conn;
    };
    conn.connected = true;
    return conn;
}

pub export fn nox_ws_ok_raw(handle: ?*anyopaque) callconv(.c) i64 {
    const conn: *WsConn = @ptrCast(@alignCast(handle orelse return 0));
    return if (conn.connected) 1 else 0;
}

pub export fn nox_ws_errmsg_raw(rt: ?*anyopaque, handle: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const conn: *WsConn = @ptrCast(@alignCast(handle orelse return dupeEmpty(rt)));
    return dupeToNoxStr(rt, conn.errmsg);
}

/// TEK bir TEXT frame (opcode `0x1`) gönderir — istemci çerçeveleri RFC
/// 6455'e göre ZORUNLU olarak MASKELENİR (rastgele 4 baytlık bir anahtarla
/// payload XOR'lanır).
pub export fn nox_ws_send_text_raw(handle: ?*anyopaque, data: ?[*]const u8, len: i64) callconv(.c) i64 {
    const conn: *WsConn = @ptrCast(@alignCast(handle orelse return -1));
    if (!conn.connected) return -1;
    const d = data orelse return -1;
    const payload = d[0..@intCast(len)];
    sendFrame(conn, 0x1, payload) catch |err| {
        conn.errmsg = @errorName(err);
        return -1;
    };
    return @intCast(payload.len);
}

fn sendFrame(conn: *WsConn, opcode: u8, payload: []const u8) !void {
    const w = conn.writer();
    var header: [14]u8 = undefined;
    var hlen: usize = 0;
    header[0] = 0x80 | opcode; // FIN=1
    hlen += 1;
    if (payload.len < 126) {
        header[1] = 0x80 | @as(u8, @intCast(payload.len)); // MASK=1
        hlen += 1;
    } else if (payload.len <= 0xFFFF) {
        header[1] = 0x80 | 126;
        std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
        hlen += 3;
    } else {
        header[1] = 0x80 | 127;
        std.mem.writeInt(u64, header[2..10], @intCast(payload.len), .big);
        hlen += 9;
    }
    var mask_key: [4]u8 = undefined;
    conn.io.random(&mask_key);
    @memcpy(header[hlen..][0..4], &mask_key);
    hlen += 4;
    try w.writeAll(header[0..hlen]);

    const gpa = std.heap.page_allocator;
    const masked = try gpa.alloc(u8, payload.len);
    defer gpa.free(masked);
    for (payload, 0..) |b, i| masked[i] = b ^ mask_key[i % 4];
    try w.writeAll(masked);
    if (conn.use_tls) try conn.tls_client.writer.flush();
    try conn.stream_writer.interface.flush();
}

/// Bir sonraki frame'i OKUR (sunucu çerçeveleri MASKELENMEZ, RFC 6455) —
/// `PING` otomatik olarak `PONG` İLE yanıtlanır (kullanıcıya HİÇ
/// gösterilmez), `CLOSE` alınırsa BOŞ dize döner (`nox_ws_ok_raw` ARTIK
/// `0` döner). Metin/ikili payload'ı DÖNER.
const RecvResult = union(enum) {
    /// Metin/ikili payload GELDİ — çağıran BUNU kullanıcıya döndürür.
    data: []const u8,
    /// `CLOSE` frame ALINDI — bağlantı ARTIK kapalı sayılmalı.
    closed,
    /// PING'e otomatik PONG İLE yanıt VERİLDİ (ya da bir PONG ALINDI) —
    /// kullanıcıya GÖSTERİLECEK bir şey YOK, çağıran BİR SONRAKİ frame'i
    /// beklemeye DEVAM etmeli.
    skip,
};

pub export fn nox_ws_recv_raw(rt: ?*anyopaque, handle: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const conn: *WsConn = @ptrCast(@alignCast(handle orelse return dupeEmpty(rt)));
    if (!conn.connected) return dupeEmpty(rt);
    while (true) {
        const result = recvFrameInner(conn) catch |err| {
            conn.errmsg = @errorName(err);
            conn.connected = false;
            return dupeEmpty(rt);
        };
        switch (result) {
            .data => |p| {
                const gpa = std.heap.page_allocator;
                defer gpa.free(p);
                return dupeToNoxStr(rt, p);
            },
            .closed => {
                conn.connected = false;
                return dupeEmpty(rt);
            },
            .skip => continue,
        }
    }
}

fn recvFrameInner(conn: *WsConn) !RecvResult {
    const r = conn.reader();
    var header: [2]u8 = undefined;
    try r.readSliceAll(&header);
    const opcode = header[0] & 0x0F;
    const masked = (header[1] & 0x80) != 0;
    var payload_len: u64 = header[1] & 0x7F;
    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        try r.readSliceAll(&ext);
        payload_len = std.mem.readInt(u16, &ext, .big);
    } else if (payload_len == 127) {
        var ext: [8]u8 = undefined;
        try r.readSliceAll(&ext);
        payload_len = std.mem.readInt(u64, &ext, .big);
    }
    var mask_key: [4]u8 = undefined;
    if (masked) try r.readSliceAll(&mask_key);

    const gpa = std.heap.page_allocator;
    const buf = try gpa.alloc(u8, @intCast(payload_len));
    errdefer gpa.free(buf);
    try r.readSliceAll(buf);
    if (masked) for (buf, 0..) |*b, i| {
        b.* ^= mask_key[i % 4];
    };

    switch (opcode) {
        // `.data` durumunda `buf`nin sahipliği ÇAĞIRANA (`nox_ws_recv_raw`)
        // GEÇER — O serbest bırakır (bkz. onun belge notu). DİĞER TÜM
        // dallar BURADA KENDİLERİ serbest bırakır.
        0x1, 0x2 => return .{ .data = buf }, // text/binary
        0x8 => {
            gpa.free(buf);
            return .closed;
        },
        0x9 => { // ping -> pong (aynı payload ile)
            defer gpa.free(buf);
            try sendFrame(conn, 0xA, buf);
            return .skip;
        },
        0xA => {
            gpa.free(buf);
            return .skip; // pong: yok say
        },
        else => {
            gpa.free(buf);
            return .skip;
        },
    }
}

pub export fn nox_ws_close_raw(handle: ?*anyopaque) callconv(.c) void {
    const conn: *WsConn = @ptrCast(@alignCast(handle orelse return));
    if (conn.connected) {
        sendFrame(conn, 0x8, &.{}) catch {};
        if (conn.use_tls) conn.tls_client.end() catch {};
        conn.stream.close(conn.io);
    }
    conn.gpa.destroy(conn);
}

pub export fn nox_ws_is_null_ptr(p: ?*anyopaque) callconv(.c) i64 {
    return if (p == null) 1 else 0;
}
