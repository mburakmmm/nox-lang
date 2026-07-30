//! `nox.http.serve_ws*` — sunucu-tarafı WebSocket Upgrade. Bkz. plan
//! dosyası "Sunucu-tarafı TLS terminasyonu (OpenSSL FFI) + WebSocket
//! Upgrade — nox.http.serve". `nox.websocket`nin (istemci, `websocket.zig`)
//! KENDİ modül üstü notu bunun "bu fazın kapsamı dışında" olduğunu
//! belgeliyordu — bu dosya TAM OLARAK o takip görevidir.
//!
//! **Kritik doğruluk kısıtı (bkz. plan dosyası):** `std.http.Server.
//! receiveHead()`nin İÇ arabelleğinde headers SONRASI fazla baytlar
//! (erken bir WS frame'i) OLABİLİR — bu YÜZDEN Upgrade SONRASI TÜM WS
//! G/Ç'si, `connectionEntry`nin `std.http.Server.init`e VERDİĞİ AYNI
//! `*std.Io.Reader`/`*std.Io.Writer` işaretçilerini KULLANMALIDIR
//! (`tryHandleUpgrade`nin BUNLARI PARAMETRE olarak ALMASININ nedeni) —
//! ASLA fd'den yeniden okunmaz.
//!
//! **Maskeleme yönü**: istemci→sunucu frame'leri RFC 6455 gereği
//! MASKELENMİŞ OLMALIDIR (`recvServerFrameInner` unmasked bir frame'i
//! REDDEDER); sunucu→istemci frame'leri HİÇBİR ZAMAN maskelenmez
//! (`sendServerFrame`, `websocket.zig`nin İSTEMCİYE-ÖZGÜ `sendFrame`ının
//! AKSİNE — yön karışıklığı riskini ORTADAN KALDIRMAK İçİn KASITLI
//! olarak AYRI bir fonksiyon, parametrik bir "belki maskele" bayrağı
//! DEĞİL).

const std = @import("std");
const str_mod = @import("../str.zig");
const websocket = @import("websocket.zig");

fn dupeToNoxStr(rt: ?*anyopaque, bytes: []const u8) ?[*:0]u8 {
    return str_mod.nox_str_from_bytes(rt, bytes);
}

fn dupeEmpty(rt: ?*anyopaque) ?[*:0]u8 {
    return dupeToNoxStr(rt, "");
}

pub const WsServerConn = struct {
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    connected: bool = true,
    errmsg: []const u8 = "",
};

pub const UpgradeResult = enum { upgraded, not_upgrade, rejected };

/// `WsHandlerFn` — HTTP handler'ın AKSİNE DÖNÜŞ DEĞERİ YOK (bir WS
/// oturumunun "yanıt nesnesi" YOKTUR) — `handler_ctx` (`rt`) İLK, ham
/// `WsServerConn*` İKİNCİ argümandır (`HandlerFn`in AYNI (ctx, tutamaç)
/// sırası).
pub const WsHandlerFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;

fn eqlIgnoreCaseTrim(value: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t"), expected);
}

/// `request`nin bir WebSocket Upgrade isteği OLUP OLMADIĞINI kontrol eder;
/// öyleyse el sıkışma yanıtını (`101 Switching Protocols`) DOĞRUDAN
/// `reader`/`writer` ÜZERİNE yazıp `ws_handler`ı ÇAĞIRIR (bu, bağlantının
/// TÜM ömrü boyunca BU fiber'ı BLOKE eder — HTTP handler'la AYNI "handler
/// bağlantıyı sahiplenir" sözleşmesi).
pub fn tryHandleUpgrade(
    rt: ?*anyopaque,
    request: *std.http.Server.Request,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    ws_handler: WsHandlerFn,
    handler_ctx: ?*anyopaque,
) !UpgradeResult {
    _ = rt;
    if (request.head.method != .GET) return .not_upgrade;

    var has_upgrade_ws = false;
    var has_connection_upgrade = false;
    var key_buf: [64]u8 = undefined;
    var key_len: usize = 0;
    var version_ok = false;

    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "upgrade") and eqlIgnoreCaseTrim(h.value, "websocket")) has_upgrade_ws = true;
        if (std.ascii.eqlIgnoreCase(h.name, "connection") and std.ascii.indexOfIgnoreCase(h.value, "upgrade") != null) has_connection_upgrade = true;
        if (std.ascii.eqlIgnoreCase(h.name, "sec-websocket-key") and h.value.len <= key_buf.len) {
            @memcpy(key_buf[0..h.value.len], h.value);
            key_len = h.value.len;
        }
        if (std.ascii.eqlIgnoreCase(h.name, "sec-websocket-version") and std.mem.eql(u8, std.mem.trim(u8, h.value, " \t"), "13")) version_ok = true;
    }

    if (!has_upgrade_ws) return .not_upgrade;
    if (!has_connection_upgrade or key_len == 0 or !version_ok) return .rejected;

    var accept_buf: [28]u8 = undefined;
    websocket.computeAcceptValue(key_buf[0..key_len], &accept_buf);

    var resp_buf: [256]u8 = undefined;
    const resp = try std.fmt.bufPrint(&resp_buf, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept_buf});
    try writer.writeAll(resp);
    try writer.flush();

    var conn: WsServerConn = .{ .reader = reader, .writer = writer };
    ws_handler(handler_ctx, &conn);
    return .upgraded;
}

/// HİÇBİR ZAMAN maskelemez (RFC 6455: sunucu→istemci frame'leri unmasked
/// OLMALIDIR) — `websocket.zig`nin İSTEMCİYE-ÖZGÜ `sendFrame`ının (HER
/// ZAMAN maskeler) BİLİNÇLİ olarak AYRI bir kardeşi.
fn sendServerFrame(conn: *WsServerConn, opcode: u8, payload: []const u8) !void {
    var header: [10]u8 = undefined;
    var hlen: usize = 0;
    header[0] = 0x80 | opcode; // FIN=1
    hlen += 1;
    if (payload.len < 126) {
        header[1] = @intCast(payload.len); // MASK=0
        hlen += 1;
    } else if (payload.len <= 0xFFFF) {
        header[1] = 126;
        std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
        hlen += 3;
    } else {
        header[1] = 127;
        std.mem.writeInt(u64, header[2..10], @intCast(payload.len), .big);
        hlen += 9;
    }
    try conn.writer.writeAll(header[0..hlen]);
    if (payload.len > 0) try conn.writer.writeAll(payload);
    try conn.writer.flush();
}

const RecvResult = union(enum) {
    data: []const u8,
    closed,
    skip,
};

/// `websocket.zig`nin `recvFrameInner`ının sunucu kardeşi — TEK gerçek
/// fark: unmasked bir gelen frame'i RFC 6455 §5.1 gereği REDDEDER (Close
/// 1002 "protocol error" gönderip bağlantıyı kapatılmış SAYAR — istemci
/// çerçeveleri ZORUNLU olarak maskelenmiş OLMALIDIR).
fn recvServerFrameInner(conn: *WsServerConn) !RecvResult {
    const r = conn.reader;
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

    if (!masked) {
        sendServerFrame(conn, 0x8, &[_]u8{ 0x03, 0xEA }) catch {}; // 1002 protocol error
        return .closed;
    }

    var mask_key: [4]u8 = undefined;
    try r.readSliceAll(&mask_key);

    const gpa = std.heap.page_allocator;
    const buf = try gpa.alloc(u8, @intCast(payload_len));
    errdefer gpa.free(buf);
    try r.readSliceAll(buf);
    for (buf, 0..) |*b, i| b.* ^= mask_key[i % 4];

    switch (opcode) {
        0x1, 0x2 => return .{ .data = buf },
        0x8 => {
            gpa.free(buf);
            return .closed;
        },
        0x9 => {
            defer gpa.free(buf);
            try sendServerFrame(conn, 0xA, buf);
            return .skip;
        },
        0xA => {
            gpa.free(buf);
            return .skip;
        },
        else => {
            gpa.free(buf);
            return .skip;
        },
    }
}

pub export fn nox_ws_server_recv_raw(rt: ?*anyopaque, handle: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const conn: *WsServerConn = @ptrCast(@alignCast(handle orelse return dupeEmpty(rt)));
    if (!conn.connected) return dupeEmpty(rt);
    while (true) {
        const result = recvServerFrameInner(conn) catch |err| {
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

pub export fn nox_ws_server_send_text_raw(handle: ?*anyopaque, data: ?[*]const u8, len: i64) callconv(.c) i64 {
    const conn: *WsServerConn = @ptrCast(@alignCast(handle orelse return -1));
    if (!conn.connected) return -1;
    const d = data orelse return -1;
    const payload = d[0..@intCast(len)];
    sendServerFrame(conn, 0x1, payload) catch |err| {
        conn.errmsg = @errorName(err);
        return -1;
    };
    return @intCast(payload.len);
}

pub export fn nox_ws_server_errmsg_raw(rt: ?*anyopaque, handle: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const conn: *WsServerConn = @ptrCast(@alignCast(handle orelse return dupeEmpty(rt)));
    return dupeToNoxStr(rt, conn.errmsg);
}

pub export fn nox_ws_server_ok_raw(handle: ?*anyopaque) callconv(.c) i64 {
    const conn: *WsServerConn = @ptrCast(@alignCast(handle orelse return 0));
    return if (conn.connected) 1 else 0;
}

pub export fn nox_ws_server_close_raw(handle: ?*anyopaque) callconv(.c) void {
    const conn: *WsServerConn = @ptrCast(@alignCast(handle orelse return));
    if (conn.connected) {
        sendServerFrame(conn, 0x8, &.{}) catch {};
        conn.connected = false;
    }
}

pub export fn nox_ws_server_is_null_ptr(p: ?*anyopaque) callconv(.c) i64 {
    return if (p == null) 1 else 0;
}
