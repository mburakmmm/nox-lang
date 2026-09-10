//! `nox.smtp` Zig kabuğu — Faz STD.4 (bkz. plan dosyası "nox.smtp — saf
//! Zig ilkelleri + saf Nox protokol mantığıyla SMTP istemcisi"): `nox.tls`
//! (`tls.zig`) VE `nox.websocket` (`websocket.zig`) ZATEN plain-TCP
//! connect + satır-tamponlu CRLF okuma + (websocket.zig'in `use_tls`
//! bayrağı örneğinde) KOŞULLU TLS katmanlamayı içeriyordu — bu dosya
//! AYNI şablonu, SMTP'nin STARTTLS'inin GEREKTİRDİĞİ "önce düz-metin
//! bağlan, SONRADAN (bir .nox-seviyesi protokol alışverişi sonrası) AYNI
//! bağlantıyı TLS'e yükselt" sırasına uyacak şekilde kullanır.
//!
//! **Bilinçli v1 kapsamı**: SADECE İSTEMCİ — `nox.tls`/`nox.websocket`nin
//! AYNI gerekçesi (Zig std'sinde bir TLS SUNUCUSU henüz yok).
//!
//! **Senkron/bloklayan**: `nox.tls`/`nox.websocket`nin AYNI v1
//! basitleştirmesi — `connect`/`read_line`/`write`/`starttls` ÇAĞIRAN iş
//! parçacığını DOĞRUDAN BLOKLAR.
//!
//! **Protokol mantığı BURADA DEĞİL**: EHLO/AUTH/MAIL FROM/RCPT TO/DATA
//! durum makinesi TAMAMEN `stdlib/nox/smtp.nox`da (saf Nox) yaşar — bu
//! dosya SADECE ham bağlantı/satır-okuma/yazma/TLS-yükseltme VE (`str`in
//! NUL-sonlandırmalı olması yüzünden Nox tarafında GÜVENSİZ olan) AUTH
//! PLAIN'in NUL-ayraçlı payload inşası İçİn gereken iki base64 ilkelini
//! sağlar.

const std = @import("std");
const arc = @import("../alloc/arc.zig");
const str_mod = @import("../str.zig");
const http_client = @import("http_client.zig");
/// `std.crypto.tls.Client` DEĞİL — `certificate_request` düzeltmesi İçEREN
/// yamalı kopya (bkz. `runtime/vendor/tls_client.zig`nin başlık yorumu, VE
/// bu dosyanın `starttls()`nin GERÇEKTEN başarısız olduğu asıl repro'su).
const TlsClient = @import("../vendor/tls_client.zig");

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

const BUF: usize = TlsClient.min_buffer_len;

/// `net.Stream.Reader.interface`/`Writer.interface`i DOĞRUDAN kullanır
/// (plaintext yol), TLS İSE `tls_client` ARACILIĞIYLA — `websocket.zig`nin
/// AYNI `@fieldParentPtr` güvenlik gerekçesi (TEK bir heap-tahsisi,
/// adresi ASLA değişmez) VE AYNI `reader()`/`writer()`/`flushAll()`
/// dispatch deseni.
const SmtpConn = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    sock_read_buf: [BUF]u8 = undefined,
    sock_write_buf: [BUF]u8 = undefined,
    tls_read_buf: [BUF]u8 = undefined,
    tls_write_buf: [BUF]u8 = undefined,
    stream_reader: std.Io.net.Stream.Reader = undefined,
    stream_writer: std.Io.net.Stream.Writer = undefined,
    tls_client: TlsClient = undefined,
    use_tls: bool = false,
    connected: bool = false,
    errmsg: []const u8 = "",
    /// `starttls()`in SONRADAN `std.crypto.tls.Client.init`i çağırabilmesi
    /// İçİn (SNI/sertifika-hostname doğrulaması GEREKİR) — connect ANINDA
    /// `gpa.dupe` İLE SAKLANIR.
    host: []const u8 = "",

    fn reader(self: *SmtpConn) *std.Io.Reader {
        return if (self.use_tls) &self.tls_client.reader else &self.stream_reader.interface;
    }
    fn writer(self: *SmtpConn) *std.Io.Writer {
        return if (self.use_tls) &self.tls_client.writer else &self.stream_writer.interface;
    }
    fn flushAll(self: *SmtpConn) !void {
        if (self.use_tls) try self.tls_client.writer.flush();
        try self.stream_writer.interface.flush();
    }
};

fn upgradeToTls(conn: *SmtpConn) !void {
    if (!ensureCaBundle(conn.io)) return error.CaBundleLoadFailed;
    var random_buffer: [TlsClient.Options.entropy_len]u8 = undefined;
    conn.io.random(&random_buffer);
    const now = std.Io.Timestamp.now(conn.io, .real);
    conn.tls_client = try TlsClient.init(&conn.stream_reader.interface, &conn.stream_writer.interface, .{
        .host = .{ .explicit = conn.host },
        .ca = .{ .bundle = .{
            .gpa = std.heap.page_allocator,
            .io = conn.io,
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
    conn.use_tls = true;
}

fn connectInner(conn: *SmtpConn, host: []const u8, port: i64, use_tls: bool) !void {
    const io = conn.io;
    conn.host = try conn.gpa.dupe(u8, host);
    const host_name = try std.Io.net.HostName.init(host);
    conn.stream = try host_name.connect(io, @intCast(port), .{ .mode = .stream });
    conn.stream_reader = conn.stream.reader(io, &conn.sock_read_buf);
    conn.stream_writer = conn.stream.writer(io, &conn.sock_write_buf);
    if (use_tls) try upgradeToTls(conn);
}

/// `host`/`port`e TCP bağlantısı kurar — `use_tls != 0` İSE (SMTPS, port
/// 465 TİPİK) bağlantı ANINDA TLS katmanlar; AKSİ HALDE düz-metin bırakır
/// (port 25/587, `nox_smtp_starttls_raw` İLE SONRADAN yükseltilebilir).
/// BAŞARISIZLIK durumunda BİLE (`nox.tls`nin AYNI deseni) GEÇERLİ bir
/// handle DÖNER — yalnızca BELLEK YETERSİZLİĞİNDE `null` döner.
pub export fn nox_smtp_connect_raw(host: ?[*:0]const u8, port: i64, use_tls: i64) callconv(.c) ?*anyopaque {
    const gpa = std.heap.page_allocator;
    const conn = gpa.create(SmtpConn) catch return null;
    conn.* = .{ .gpa = gpa, .io = http_client.sharedClientIo(), .stream = undefined };
    const h = host orelse {
        conn.errmsg = "host bos olamaz";
        return conn;
    };
    connectInner(conn, str_mod.nox_str_slice(h), port, use_tls != 0) catch |err| {
        conn.errmsg = @errorName(err);
        conn.connected = false;
        return conn;
    };
    conn.connected = true;
    return conn;
}

pub export fn nox_smtp_ok_raw(handle: ?*anyopaque) callconv(.c) i64 {
    const conn: *SmtpConn = @ptrCast(@alignCast(handle orelse return 0));
    return if (conn.connected) 1 else 0;
}

pub export fn nox_smtp_errmsg_raw(rt: ?*anyopaque, handle: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const conn: *SmtpConn = @ptrCast(@alignCast(handle orelse return dupeEmpty(rt)));
    return dupeToNoxStr(rt, conn.errmsg);
}

/// `data`nin İLK `len` baytını YAZAR — başarılıysa yazılan bayt sayısını,
/// hatada `-1` döner. `nox.tls`nin KENDİ, GERÇEK bir tekrar-üretimle
/// bulduğu ÇİFT-flush tuzağı BURADA da GEÇERLİ: `writer()` TLS İSE
/// `tls_client.writer.flush()` ONUN şifreli çıktısını `stream_writer`in
/// tamponuna YAZAR, AMA O tampon GERÇEK sokete BOŞALTILMADAN (`stream_
/// writer.interface.flush()`) karşı taraf HİÇBİR ŞEY ALMAZ — `flushAll()`
/// İKİSİNİ de (plaintext modda SADECE İKİNCİSİNİ) yapar.
pub export fn nox_smtp_write_raw(handle: ?*anyopaque, data: ?[*]const u8, len: i64) callconv(.c) i64 {
    const conn: *SmtpConn = @ptrCast(@alignCast(handle orelse return -1));
    if (!conn.connected) return -1;
    const d = data orelse return -1;
    if (len <= 0) return 0;
    const slice = d[0..@intCast(len)];
    conn.writer().writeAll(slice) catch |err| {
        conn.errmsg = @errorName(err);
        return -1;
    };
    conn.flushAll() catch |err| {
        conn.errmsg = @errorName(err);
        return -1;
    };
    return @intCast(slice.len);
}

/// BİR CRLF-sonlu satırı OKUR (`\r\n`/`\n` KIRPILIR) — SMTP yanıt satırları
/// ASLA meşru olarak BOŞ OLMADIĞINDAN, HATADA (EOF/I-O hatası) BOŞ dize
/// döner VE `.nox` tarafı BUNU "okuma basarisiz" OLARAK GÜVENLE yorumlar
/// (`nox.tls`nin `read()`inden FARKLI — ORADA boş dize "temiz kapandı"
/// anlamına geliyordu, BURADA HER ZAMAN bir hata anlamına gelir).
pub export fn nox_smtp_read_line_raw(rt: ?*anyopaque, handle: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const conn: *SmtpConn = @ptrCast(@alignCast(handle orelse return dupeEmpty(rt)));
    if (!conn.connected) return dupeEmpty(rt);
    const raw_line = conn.reader().takeDelimiterInclusive('\n') catch |err| {
        conn.errmsg = @errorName(err);
        return dupeEmpty(rt);
    };
    const trimmed = std.mem.trimEnd(u8, raw_line, "\r\n");
    return dupeToNoxStr(rt, trimmed);
}

/// MEVCUT (ÖNCEDEN düz-metin olarak bağlanmış) bağlantıyı TLS'e
/// YÜKSELTİR — `.nox` tarafı BUNU `STARTTLS` komutunu GÖNDERİP "220"
/// yanıtını OKUDUKTAN SONRA çağırmalıdır (protokol-seviyesi sıralama
/// burada DENETLENMEZ, `.nox`un sorumluluğundadır). `1` BAŞARI, `0`
/// HATA (`errmsg` AYARLANIR) döner.
pub export fn nox_smtp_starttls_raw(handle: ?*anyopaque) callconv(.c) i64 {
    const conn: *SmtpConn = @ptrCast(@alignCast(handle orelse return 0));
    if (!conn.connected or conn.use_tls) return 0;
    upgradeToTls(conn) catch |err| {
        conn.errmsg = @errorName(err);
        return 0;
    };
    return 1;
}

/// `AUTH LOGIN`nin kullanıcı-adı/şifre satırları İçİn genel base64
/// kodlayıcı (`websocket.zig`nin `Sec-WebSocket-Key` İçİn KULLANDIĞI AYNI
/// `std.base64.standard.Encoder`).
pub export fn nox_smtp_base64_encode_raw(rt: ?*anyopaque, s: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const text = std.mem.span(s orelse return dupeEmpty(rt));
    const out_len = std.base64.standard.Encoder.calcSize(text.len);
    const buf = std.heap.page_allocator.alloc(u8, out_len) catch return dupeEmpty(rt);
    defer std.heap.page_allocator.free(buf);
    const encoded = std.base64.standard.Encoder.encode(buf, text);
    return dupeToNoxStr(rt, encoded);
}

/// `AUTH PLAIN`nin ham payload'u (`"\x00" ++ username ++ "\x00" ++
/// password`) İKİ GÖMÜLÜ NUL bayt İçERİR — Nox'un NUL-sonlandırmalı
/// `str`inde (`sharedmem.nox`/`gzip.zig`nin AYNI, ÖNCEDEN belgelenmiş
/// kısıtı) BU HİÇ İNŞA EDİLEMEZ. Bu YÜZDEN payload Zig'in `[]u8` dilimi
/// İçİNDE (embedded-NUL GÜVENLE taşıyabilir) İNŞA EDİLİP SADECE base64-
/// KODLANMIŞ (DOĞAL olarak NUL-SUZ, saf ASCII) SONUÇ Nox `str`i OLARAK
/// döner.
pub export fn nox_smtp_base64_auth_plain_raw(rt: ?*anyopaque, username: ?[*:0]const u8, password: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const u = std.mem.span(username orelse return dupeEmpty(rt));
    const p = std.mem.span(password orelse return dupeEmpty(rt));
    const gpa = std.heap.page_allocator;
    const payload = std.fmt.allocPrint(gpa, "\x00{s}\x00{s}", .{ u, p }) catch return dupeEmpty(rt);
    defer gpa.free(payload);
    const out_len = std.base64.standard.Encoder.calcSize(payload.len);
    const buf = gpa.alloc(u8, out_len) catch return dupeEmpty(rt);
    defer gpa.free(buf);
    const encoded = std.base64.standard.Encoder.encode(buf, payload);
    return dupeToNoxStr(rt, encoded);
}

pub export fn nox_smtp_close_raw(handle: ?*anyopaque) callconv(.c) void {
    const conn: *SmtpConn = @ptrCast(@alignCast(handle orelse return));
    if (conn.connected) {
        if (conn.use_tls) conn.tls_client.end() catch {};
        conn.stream.close(conn.io);
    }
    if (conn.host.len > 0) conn.gpa.free(conn.host);
    conn.gpa.destroy(conn);
}

pub export fn nox_smtp_is_null_ptr(p: ?*anyopaque) callconv(.c) i64 {
    return if (p == null) 1 else 0;
}
