//! `nox.tls` Zig kabuğu — Faz NN.5 (bkz. proje belleği "nyx v2 limitasyon
//! listesi doğrulaması"): ham bir TLS akışı ilkeli. `nox.http` istemcisinin
//! `https://` desteği ZATEN Zig'in KENDİ `std.http.Client`/`std.crypto.tls`
//! yığınına DELEGE EDİLİYOR (bkz. `http_client.zig`) — bu dosya AYNI
//! `std.crypto.tls.Client`i, `std.http.Client`in İÇİNDE gizli kalan
//! seviyeden DAHA DÜŞÜK bir seviyede (ham bir soket üzerinde, HTTP
//! protokolü olmadan) DOĞRUDAN sürerek genel-amaçlı bir "TLS akışı" ilkeli
//! açar. sqlite/postgres/mysql'in dlopen desenlerinin AKSİNE, bu SAF Zig
//! kodudur — `std.crypto.tls` Zig'in KENDİ standart kütüphanesinin bir
//! parçasıdır, HİÇBİR harici sistem kütüphanesine (OpenSSL/vb.) bağımlılık
//! YOKTUR, `noxrt.o`ya ZATEN statik olarak bağlıdır (`nox.http` KULLANAN
//! HER programda).
//!
//! **Bilinçli v1 kapsamı**: SADECE İSTEMCİ (`nox_tls_connect_raw`) — bir
//! TLS SUNUCUSU (`std.crypto.tls.Server`) Zig'in std kütüphanesinde HENÜZ
//! YOK (bkz. bu oturumun araştırması: `std/crypto/tls/` altında yalnızca
//! `Client.zig` var, `Server.zig` YOK) — bu YÜZDEN `nox.tls` sunucu tarafı
//! bu fazın kapsamı DIŞINDA bırakıldı, AÇIKÇA belgelendi.
//!
//! **Senkron/bloklayan**: `nox.sqlite`/`nox.postgres`/`nox.mysql`nin AYNI
//! deseni — `nox.http`/`nox.process`nin arka-plan-iş-parçacığı+self-pipe
//! deseninin AKSİNE, `connect`/`read`/`write` ÇAĞIRAN iş parçacığını
//! DOĞRUDAN BLOKLAR (fiber zamanlayıcısına ENTEGRE DEĞİLDİR) — bu, v1 İçin
//! BİLİNÇLİ bir basitleştirmedir (arka-plan çalıştırma İSTENİYORSA `nox.
//! thread` KULLANILABİLİR).

const std = @import("std");
const arc = @import("../alloc/arc.zig");
const http_client = @import("http_client.zig");

fn dupeToNoxStr(rt: ?*anyopaque, bytes: []const u8) ?[*:0]u8 {
    const raw = arc.nox_rc_alloc(rt, bytes.len + 1) orelse return null;
    const out: [*]u8 = @ptrCast(raw);
    @memcpy(out[0..bytes.len], bytes);
    out[bytes.len] = 0;
    return @ptrCast(out);
}

fn dupeEmpty(rt: ?*anyopaque) ?[*:0]u8 {
    return dupeToNoxStr(rt, "");
}

/// Sistemin CA sertifika deposu — `std.crypto.Certificate.Bundle.rescan`
/// (platform bağımsız: macOS/Linux/Windows KENDİ sistem depolarını BULUR)
/// İLE BİR KEZ, TEMBEL yüklenir (sqlite/postgres/mysql'in `ensureLoaded`
/// deseniyle AYNI atomik durum makinesi) — HER `nox_tls_connect_raw`
/// çağrısı bunu YENİDEN taramaz.
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

// Bulundu: `tls.Client.init`in `input: *Reader` VE `output: *Writer`
// (`&conn.stream_reader.interface`/`&conn.stream_writer.interface` OLARAK
// GEÇİRİLEN) parametrelerinin KENDİ tampon boyutu `min_buffer_len`den KÜÇÜK
// OLAMAZ (`assert(input.buffer.len >= min_buffer_len)` — GERÇEK bir
// tekrar-üretimle, 4096 baytlık bir soket tamponuyla, `unreachable` PANİĞİYLE
// DOĞRULANDI: TLS şifreli kayıtlar `min_buffer_len`e kadar büyüyebilir, bu
// YÜZDEN HEM soket-seviyesi (`sock_*_buf`, `stream_reader`/`stream_writer`in
// KENDİ tamponu) HEM tls-seviyesi (`tls_*_buf`, `Options.read_buffer`/
// `write_buffer`) tamponların İKİSİ de EN AZ `min_buffer_len` OLMALIDIR —
// `std.http.Client`nin `Connection.Tls.create`ının AYNI (ama HTTP başlık
// ayrıştırması İçin fazladan yer AYIRAN, BİZİM İçin GEREKSİZ) desenine bkz.
const TLS_READ_BUF: usize = std.crypto.tls.Client.min_buffer_len;
const TLS_WRITE_BUF: usize = std.crypto.tls.Client.min_buffer_len;
const SOCK_BUF: usize = std.crypto.tls.Client.min_buffer_len;

/// TEK bir heap-tahsisi olarak (`gpa.create`) tutulur — `stream_reader`/
/// `stream_writer`/`client` alanlarının İÇ arayüzleri (`std.Io.Reader`/
/// `Writer`) `@fieldParentPtr` İLE KENDİ dış struct'larının adresini
/// ÇAĞRI ANINDA hesaplar (bkz. Zig std kaynağının `net.Stream.Reader.
/// readVec`i) — bu struct'ın adresi HİÇBİR ZAMAN değişmediği (heap'te
/// SABİT) sürece bu GÜVENLİDİR.
const TlsConn = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    sock_read_buf: [SOCK_BUF]u8 = undefined,
    sock_write_buf: [SOCK_BUF]u8 = undefined,
    tls_read_buf: [TLS_READ_BUF]u8 = undefined,
    tls_write_buf: [TLS_WRITE_BUF]u8 = undefined,
    stream_reader: std.Io.net.Stream.Reader = undefined,
    stream_writer: std.Io.net.Stream.Writer = undefined,
    client: std.crypto.tls.Client = undefined,
    connected: bool = false,
    errmsg: []const u8 = "",
};

fn connectInner(conn: *TlsConn, host: []const u8, port: i64) !void {
    const io = conn.io;
    if (!ensureCaBundle(io)) return error.CaBundleLoadFailed;
    // Bulundu: `std.Io.net.IpAddress.resolve` GERÇEK bir DNS/hostname
    // çözümleyicisi DEĞİLDİR — SADECE IP LİTERALLERİNİ (`"1.2.3.4"`/IPv6
    // metni) ayrıştırır, gerçek bir hostname'de (`"example.com"`) HER ZAMAN
    // `error.ParseFailed` verir (GERÇEK bir tekrar-üretimle, example.com'a
    // karşı, DOĞRULANDI — `std.http.Client`nin KENDİSİ `HostName.connect`i
    // kullanır, `IpAddress.resolve`i DEĞİL). Gerçek DNS çözümlemesi İçin
    // `HostName.connect` GEREKİR.
    const host_name = try std.Io.net.HostName.init(host);
    conn.stream = try host_name.connect(io, @intCast(port), .{ .mode = .stream });
    conn.stream_reader = conn.stream.reader(io, &conn.sock_read_buf);
    conn.stream_writer = conn.stream.writer(io, &conn.sock_write_buf);
    var random_buffer: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    io.random(&random_buffer);
    const now = std.Io.Timestamp.now(io, .real);
    conn.client = try std.crypto.tls.Client.init(&conn.stream_reader.interface, &conn.stream_writer.interface, .{
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

/// `host`/`port`e TCP+TLS bağlantısı kurar — BAŞARISIZLIK durumunda BİLE
/// (sqlite/postgres/mysql'in AYNI "başarısız handle'ı yine de döndür"
/// deseni) GEÇERLİ bir handle DÖNER (`conn.connected == false`, `.nox`
/// tarafı `nox_tls_ok_raw`/`nox_tls_errmsg_raw` İLE kontrol eder) — yalnızca
/// BELLEK YETERSİZLİĞİNDE `null` döner.
pub export fn nox_tls_connect_raw(host: ?[*:0]const u8, port: i64) callconv(.c) ?*anyopaque {
    const gpa = std.heap.page_allocator;
    const conn = gpa.create(TlsConn) catch return null;
    conn.* = .{ .gpa = gpa, .io = http_client.sharedClientIo(), .stream = undefined };
    const h = host orelse {
        conn.errmsg = "host bos olamaz";
        return conn;
    };
    connectInner(conn, std.mem.span(h), port) catch |err| {
        conn.errmsg = @errorName(err);
        conn.connected = false;
        return conn;
    };
    conn.connected = true;
    return conn;
}

pub export fn nox_tls_ok_raw(handle: ?*anyopaque) callconv(.c) i64 {
    const conn: *TlsConn = @ptrCast(@alignCast(handle orelse return 0));
    return if (conn.connected) 1 else 0;
}

pub export fn nox_tls_errmsg_raw(rt: ?*anyopaque, handle: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const conn: *TlsConn = @ptrCast(@alignCast(handle orelse return dupeEmpty(rt)));
    return dupeToNoxStr(rt, conn.errmsg);
}

/// `data`nin İLK `len` baytını YAZAR (şifreleyip GERÇEK soket üzerinden
/// gönderir) — başarılıysa yazılan bayt sayısını, hatada `-1` döner.
///
/// Bulundu (GERÇEK bir tekrar-üretimle, example.com'a karşı DOĞRULANDI):
/// `conn.client.writer.flush()` TEK BAŞINA YETERSİZDİR — bu SADECE TLS
/// Client'ın KENDİ şifreli veriyi `output`a (BİZİM `stream_writer.interface`imiz)
/// YAZMASINI sağlar, AMA `stream_writer`in KENDİ arabelleğini GERÇEK sokete
/// BOŞALTMAZ. Bu SATIR OLMADAN yazma "başarılı" görünür (hata YOK) AMA
/// karşı taraf HİÇBİR ŞEY ALMAZ (`read` SONSUZA kadar/timeout'a kadar `0`
/// bayt döner) — bu YÜZDEN `stream_writer.interface.flush()` de AYRICA
/// GEREKLİDİR.
pub export fn nox_tls_write_raw(handle: ?*anyopaque, data: ?[*]const u8, len: i64) callconv(.c) i64 {
    const conn: *TlsConn = @ptrCast(@alignCast(handle orelse return -1));
    if (!conn.connected) return -1;
    const d = data orelse return -1;
    if (len <= 0) return 0;
    const slice = d[0..@intCast(len)];
    conn.client.writer.writeAll(slice) catch |err| {
        conn.errmsg = @errorName(err);
        return -1;
    };
    conn.client.writer.flush() catch |err| {
        conn.errmsg = @errorName(err);
        return -1;
    };
    conn.stream_writer.interface.flush() catch |err| {
        conn.errmsg = @errorName(err);
        return -1;
    };
    return @intCast(slice.len);
}

/// En fazla `max_len` bayt OKUR (soketten okuyup ÇÖZER) — bağlantı temiz
/// kapandıysa (`error.EndOfStream`) BOŞ dize döner (hata DEĞİL, `.nox`
/// tarafı BUNU "artık okunacak veri yok" olarak yorumlar).
pub export fn nox_tls_read_raw(rt: ?*anyopaque, handle: ?*anyopaque, max_len: i64) callconv(.c) ?[*:0]u8 {
    const conn: *TlsConn = @ptrCast(@alignCast(handle orelse return dupeEmpty(rt)));
    if (!conn.connected or max_len <= 0) return dupeEmpty(rt);
    const gpa = std.heap.page_allocator;
    const buf = gpa.alloc(u8, @intCast(max_len)) catch return dupeEmpty(rt);
    defer gpa.free(buf);
    const n = conn.client.reader.readSliceShort(buf) catch |err| {
        if (err == error.EndOfStream) return dupeEmpty(rt);
        conn.errmsg = @errorName(err);
        return dupeEmpty(rt);
    };
    return dupeToNoxStr(rt, buf[0..n]);
}

pub export fn nox_tls_close_raw(handle: ?*anyopaque) callconv(.c) void {
    const conn: *TlsConn = @ptrCast(@alignCast(handle orelse return));
    if (conn.connected) {
        conn.client.end() catch {};
        conn.stream.close(conn.io);
    }
    conn.gpa.destroy(conn);
}

pub export fn nox_tls_is_null_ptr(p: ?*anyopaque) callconv(.c) i64 {
    return if (p == null) 1 else 0;
}
