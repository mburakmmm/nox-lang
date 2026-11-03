//! HTTP/2 sunucu bağlantı motoru (RFC 9113). `http_server.zig`nin `connectionEntry`si ALPN `h2` ya da düz TCP'de istemci ön eki (`PRI * HTTP/2.0`, "h2c önceden bilinen") görünce bağlantıyı
//! `run`a devreder; HTTP/1.1 yolu hiç değişmez.
//!
//! Fiber modeli (bağlantı başına): (1) OKUYUCU = bağlantının kendi fiber'ı (`run`): çerçeveleri okur/doğrular, HPACK çözer, akışları açar; (2) YAZICI fiber'ı: sokete tek yazan
//! taraftır (çerçeveleme + akış kontrolü + denetim çerçeveleri), bir kendi-kendine-boru (`wake_*`) ile uyanır; (3) her tamamlanan istek için bir HANDLER fiber'ı (`streamEntry`) —
//! handler'lar işçi iş parçacıkları arasında çalınabilir (M:N). Üçü ortak durumu `Conn.lock` (kısa, bloklamayan kritik bölümler için SpinLock) ile paylaşır; hiçbiri kilit tutarken
//! askıya almaz ya da soket G/Ç'si yapmaz. Handler'lar yanıtı kuyruğa koyar (`respond`/`streamSend`), yazıcı pencere elverdiğince gönderir (akış kontrolü yazıcıda).
//!
//! Savunmalar: eşzamanlı akış sınırı (reddedilen/sıfırlanan akış, handler bitene dek yuvasını tutar: "rapid reset" etkisiz), CONTINUATION toplam boyutu, HPACK dinamik tablo ve liste boyutu,
//! denetim çerçevesi sel sınırları (SETTINGS/PING/PRIORITY/RST_STREAM/boş DATA), yazma kuyruğu üst sınırı, eksik istek zaman aşımı, boşta bağlantı zaman aşımı.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const h2 = @import("http2.zig");
const fiber_net = @import("fiber_net.zig");
const http_client = @import("http_client.zig");
const asap = @import("../alloc/asap.zig");
const io_mod = @import("../async_rt/io.zig");

/// Windows ve wasm'da (kendi-kendine-boru/fiber ağı yok) HTTP/2 sunulmaz; bağlantılar HTTP/1.1 kalır.
pub const supported = fiber_net.enabled;

pub const FiberFn = *const fn (*anyopaque) void;

pub const Config = struct {
    max_body_bytes: usize,
    /// Çözülmüş başlık listesi üst sınırı (ad + değer + 32 baytlık girişler toplamı); SETTINGS_MAX_HEADER_LIST_SIZE olarak da bildirilir.
    max_header_bytes: usize,
    /// Tamamlanmamış bir isteğin (başlık bloğu / gövde) en çok bekleyeceği süre.
    read_timeout_ms: u32,
    /// Hiç açık akışı olmayan bağlantının ömrü.
    idle_timeout_ms: u32 = 120_000,
    max_concurrent_streams: u32 = 100,
    /// WebSocket sunucusu var: SETTINGS_ENABLE_CONNECT_PROTOCOL bildirilir ve `:protocol` içeren genişletilmiş CONNECT (RFC 8441) kabul edilir.
    ws_enabled: bool = false,
};

pub const Hooks = struct {
    user: *anyopaque,
    /// Handler fiber'ında çalışır: isteği `stream`den kurar, uygulama handler'ını çağırır, `respond`/akış işlevleriyle yanıtlar.
    serveStream: *const fn (user: *anyopaque, stream: *Stream) void,
    /// Bağlı bir fiber başlatır (`false`: başlatılamadı). `pinned`: fiber çalınamaz, çağıranın işçisinde (zamanlayıcısında) çalışır — bağlantının `FiberReader`/`FiberWriter`/TLS
    /// nesneleri o işçinin zamanlayıcısına bağlı olduğundan yazıcı fiber'ı buna ihtiyaç duyar; handler fiber'ları çalınabilir.
    spawn: *const fn (user: *anyopaque, entry: FiberFn, arg: *anyopaque, pinned: bool) bool,
    /// Bağlantı ön eki doğrulandı: okuma zaman aşımları kalkar (boşta/eksik istek zaman aşımlarını motor yönetir); TLS ise okuyucu/yazıcı ayrımına (paylaşımlı kip) geçer.
    /// `wake`/`wake_arg`: okuyucu taşıma katmanında çıktı ürettiğinde (TLS alert vb.) yazıcıyı uyandırmak için.
    afterPreface: *const fn (user: *anyopaque, wake: *const fn (*anyopaque) void, wake_arg: *anyopaque) void,
    /// Yazıcı fiber'ı döngü başında çağrılır: taşıma katmanında bekleyen çıktıyı (TLS) soketle boşaltır.
    flushTransport: *const fn (user: *anyopaque) void,
    shuttingDown: *const fn () bool,
    /// Bloklanmış okuyucunun EOF görmesini sağlar (soketin okuma ucunu kapatır).
    closeRead: *const fn (user: *anyopaque) void,
};

const our_stream_window: u32 = 1 << 20;
const our_conn_window: u32 = 1 << 22;
const window_update_threshold: u32 = 32 * 1024;
const our_max_frame: u32 = 16384;
const max_outq_bytes: usize = 8 * 1024 * 1024;
const stream_queue_high_water: usize = 256 * 1024;
const round_bytes_per_stream: usize = 64 * 1024;
const round_bytes_total: usize = 512 * 1024;
const flood_window_ms: u64 = 10_000;
const flood_limit_control: u32 = 4000;
const flood_limit_rst: u32 = 400;
const flood_limit_empty_data: u32 = 2000;

const Chunk = struct { data: []u8, off: usize = 0 };

const HandlerState = enum { none, running, done };

pub const Stream = struct {
    conn: *Conn,
    id: u32,
    arena: std.heap.ArenaAllocator,

    // --- istek (okuyucu doldurur, handler başlayınca salt okunur) ---
    method: []const u8 = "",
    path: []const u8 = "",
    authority: []const u8 = "",
    headers: std.ArrayListUnmanaged(h2.Header) = .empty,
    body: std.ArrayListUnmanaged(u8) = .empty,
    content_length: ?u64 = null,
    is_head: bool = false,
    /// Handler çağrılmadan verilecek yanıt durumu (0 = yok): 400/413/431/501.
    early_status: u16 = 0,
    /// 413 sonrası gelen DATA atılır (yanıt iptal edilmesin).
    discard_body: bool = false,
    /// İstek trailer'ları (HEADERS + END_STREAM, gövdeden sonra); handler `req.trailer(ad)` ile okur.
    trailers: std.ArrayListUnmanaged(h2.Header) = .empty,
    /// `Expect: 100-continue` taşıyan istek (ara yanıt gönderildi).
    expect_continue: bool = false,
    /// Genişletilmiş CONNECT (`:protocol`), RFC 8441: yalnızca "websocket" desteklenir.
    protocol: []const u8 = "",
    ws_connect: bool = false,
    /// WebSocket kipi: istek gövdesi akış olarak `inbound`a girer (handler kendi hızında tüketir), handler istek bitmeden başlar.
    ws_mode: bool = false,
    inbound: std.ArrayListUnmanaged(u8) = .empty,
    inbound_off: usize = 0,

    // --- durum (Conn.lock altında) ---
    in_map: bool = true,
    recv_ended: bool = false,
    canceled: bool = false,
    handler_state: HandlerState = .none,
    recv_window: i64 = our_stream_window,
    recv_pending: u32 = 0,
    send_window: i64,
    activity_ms: u64,

    // --- çıkış (Conn.lock altında) ---
    out_head: ?[]u8 = null,
    head_queued: bool = false,
    head_sent: bool = false,
    out_end: bool = false,
    /// Yanıt trailer'ları (HPACK bloğu): akış bitişinde son HEADERS(END_STREAM) olarak gider.
    out_trailers: ?[]u8 = null,
    end_sent: bool = false,
    rst_after: bool = false,
    chunks: std.ArrayListUnmanaged(Chunk) = .empty,
    chunk_head: usize = 0,
    queued_bytes: usize = 0,

    fn destroy(self: *Stream) void {
        const c = self.conn;
        const gpa = c.gpa;
        if (self.out_head) |h| gpa.free(h);
        if (self.out_trailers) |t| gpa.free(t);
        self.inbound.deinit(gpa);
        for (self.chunks.items[self.chunk_head..]) |ch| gpa.free(ch.data);
        self.chunks.deinit(gpa);
        self.body.deinit(gpa);
        self.arena.deinit();
        _ = c.live_streams.fetchSub(1, .acq_rel);
        gpa.destroy(self);
    }
};

const Flood = struct {
    window_start_ms: u64 = 0,
    control: u32 = 0,
    rst: u32 = 0,
    empty_data: u32 = 0,

    const Kind = enum { control, rst, empty_data };

    /// `true` = sınır aşıldı.
    fn charge(self: *Flood, now_ms: u64, kind: Kind) bool {
        if (now_ms -| self.window_start_ms >= flood_window_ms) self.* = .{ .window_start_ms = now_ms };
        switch (kind) {
            .control => {
                self.control += 1;
                return self.control > flood_limit_control;
            },
            .rst => {
                self.rst += 1;
                return self.rst > flood_limit_rst;
            },
            .empty_data => {
                self.empty_data += 1;
                return self.empty_data > flood_limit_empty_data;
            },
        }
    }
};

pub const Conn = struct {
    gpa: Allocator,
    cfg: Config,
    hooks: Hooks,
    lock: asap.SpinLock = .{},

    // --- Conn.lock altında ---
    streams: std.AutoHashMapUnmanaged(u32, *Stream) = .empty,
    outq: std.ArrayListUnmanaged(u8) = .empty,
    conn_send_window: i64 = h2.default_window,
    peer_initial_window: i64 = h2.default_window,
    peer_max_frame: u32 = h2.default_max_frame,
    closing: bool = false,
    /// Yazıcı artık akış verisi göndermez (bağlantı hatası): yalnızca `outq` boşaltılır.
    fatal: bool = false,
    goaway_sent: bool = false,
    draining: bool = false,
    last_peer_stream_id: u32 = 0,
    conn_recv_pending: u32 = 0,
    /// Yazıcının yeniden kullandığı yardımcı listeler.
    retire: std.ArrayListUnmanaged(*Stream) = .empty,

    // --- atomik ---
    live_streams: std.atomic.Value(u32) = .init(0),
    active_fibers: std.atomic.Value(u32) = .init(0),
    writer_done: std.atomic.Value(bool) = .init(false),
    wake_pending: std.atomic.Value(bool) = .init(false),
    last_activity_ms: std.atomic.Value(u64),
    /// CONTINUATION beklerken başlık bloğunun başladığı an (0 = beklemiyor).
    header_block_since_ms: std.atomic.Value(u64) = .init(0),
    wake_r: posix.fd_t,
    wake_w: posix.fd_t,
};

// ---- Yardımcılar ------------------------------------------------------------------------------------------------------------------------------------

fn nowMs() u64 {
    return http_client.monotonicMs();
}

fn sleepCoop(ms: u32) void {
    if (fiber_net.sleepCooperative(ms)) return;
    http_client.sleepMs(ms);
}

fn wake(c: *Conn) void {
    if (!c.wake_pending.swap(true, .acq_rel)) {
        const b = [1]u8{1};
        _ = std.c.write(c.wake_w, &b, 1);
    }
}

/// `outq`ya bir çerçeve ekler (kilit TUTULUYOR olmalı). Kuyruk sınırı aşılırsa `false` (bağlantı ölü sayılır).
fn appendCtrlLocked(c: *Conn, kind: u8, flags: u8, stream_id: u32, payload: []const u8) bool {
    if (c.outq.items.len > max_outq_bytes) return false;
    h2.appendFrameHeader(&c.outq, c.gpa, @intCast(payload.len), kind, flags, stream_id) catch return false;
    c.outq.appendSlice(c.gpa, payload) catch return false;
    return true;
}

fn queueRstLocked(c: *Conn, id: u32, code: h2.ErrorCode) void {
    var p: [4]u8 = undefined;
    std.mem.writeInt(u32, &p, @intFromEnum(code), .big);
    _ = appendCtrlLocked(c, h2.frame_rst_stream, 0, id, &p);
}

fn queueWindowUpdateLocked(c: *Conn, id: u32, inc: u32) void {
    var p: [4]u8 = undefined;
    std.mem.writeInt(u32, &p, inc, .big);
    _ = appendCtrlLocked(c, h2.frame_window_update, 0, id, &p);
}

/// Bağlantı hatası: GOAWAY kuyruğa, yazıcı yalnızca bunu boşaltıp çıkar, akışlar iptal.
fn connError(c: *Conn, code: h2.ErrorCode) void {
    c.lock.lock();
    if (!c.goaway_sent) {
        var p: [8]u8 = undefined;
        std.mem.writeInt(u32, p[0..4], c.last_peer_stream_id, .big);
        std.mem.writeInt(u32, p[4..8], @intFromEnum(code), .big);
        _ = appendCtrlLocked(c, h2.frame_goaway, 0, 0, &p);
        c.goaway_sent = true;
    }
    c.fatal = true;
    c.closing = true;
    cancelAllLocked(c);
    c.lock.unlock();
    wake(c);
}

fn cancelAllLocked(c: *Conn) void {
    var it = c.streams.valueIterator();
    while (it.next()) |sp| sp.*.canceled = true;
}

/// Kilit altında: akış harita dışına alınır; handler çalışmıyorsa bellek hemen serbest.
fn removeStreamLocked(c: *Conn, s: *Stream) void {
    if (!s.in_map) return;
    _ = c.streams.remove(s.id);
    s.in_map = false;
    if (s.handler_state != .running) s.destroy();
}

// ---- Handler tarafı API (handler fiber'larından çağrılır) ---------------------------------------------------------------------------------------

fn statusHasNoBody(status: u16) bool {
    return status < 200 or status == 204 or status == 304;
}

fn hasHeader(headers: []const std.http.Header, name: []const u8) bool {
    for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
    return false;
}

/// Tam yanıt: başlıklar + gövde tek seferde kuyruğa konur (gövde kopyalanır; gönderim akış kontrolüne göre yazıcıdadır). HEAD'de gövde gönderilmez.
pub fn respond(s: *Stream, status: u16, headers: []const std.http.Header, body: []const u8) void {
    const c = s.conn;
    const gpa = c.gpa;
    var head: std.ArrayListUnmanaged(u8) = .empty;
    defer head.deinit(gpa);
    h2.encodeResponseBlock(&head, gpa, status, headers) catch return;
    if (!statusHasNoBody(status) and !hasHeader(headers, "content-length")) {
        var nb: [20]u8 = undefined;
        const n = std.fmt.bufPrint(&nb, "{d}", .{body.len}) catch unreachable;
        h2.encodeField(&head, gpa, "content-length", n) catch return;
    }
    const send_body = body.len > 0 and !s.is_head and !statusHasNoBody(status);
    const copy: ?[]u8 = if (send_body) (gpa.dupe(u8, body) catch return) else null;
    const head_owned = head.toOwnedSlice(gpa) catch {
        if (copy) |cp| gpa.free(cp);
        return;
    };

    c.lock.lock();
    if (s.canceled or c.closing or s.head_queued) {
        c.lock.unlock();
        gpa.free(head_owned);
        if (copy) |cp| gpa.free(cp);
        return;
    }
    s.out_head = head_owned;
    s.head_queued = true;
    if (copy) |cp| {
        if (s.chunks.append(gpa, .{ .data = cp })) |_| {
            s.queued_bytes += cp.len;
        } else |_| {
            gpa.free(cp); // bellek yok: gövdesiz biter
        }
    }
    s.out_end = true;
    c.lock.unlock();
    wake(c);
}

/// Akışlı yanıt: başlıkları kuyruğa koyar (gövde `streamSend` ile). `false`: zaten başladı / iptal / bellek yok.
pub fn streamBegin(s: *Stream, status: u16, headers: []const std.http.Header) bool {
    const c = s.conn;
    const gpa = c.gpa;
    var head: std.ArrayListUnmanaged(u8) = .empty;
    defer head.deinit(gpa);
    h2.encodeResponseBlock(&head, gpa, status, headers) catch return false;
    const head_owned = head.toOwnedSlice(gpa) catch return false;
    c.lock.lock();
    if (s.head_queued) {
        // Gerçek yanlış kullanım: akış zaten başlamış.
        c.lock.unlock();
        gpa.free(head_owned);
        return false;
    }
    if (s.canceled or c.closing) {
        // İstemci akışı handler başlamadan sıfırladı / bağlantı kapanıyor: yaygın ve zararsız. "Başladı" sayılır, ardından `streamSend`/`streamOpen` yanıtı kapalı bildirir; handler istisna görmez.
        s.head_queued = true;
        s.out_end = true;
        c.lock.unlock();
        gpa.free(head_owned);
        return true;
    }
    s.out_head = head_owned;
    s.head_queued = true;
    c.lock.unlock();
    wake(c);
    return true;
}

pub fn streamOpen(s: *Stream) bool {
    const c = s.conn;
    c.lock.lock();
    defer c.lock.unlock();
    return s.head_queued and !s.out_end and !s.canceled and !c.closing and !c.hooks.shuttingDown();
}

/// Bir parça kuyruğa koyar; kuyruk çok büyürse (yavaş istemci) kooperatif bekler. `false`: istemci gitti / akış bitti.
pub fn streamSend(s: *Stream, bytes: []const u8) bool {
    const c = s.conn;
    const gpa = c.gpa;
    if (bytes.len == 0) return streamOpen(s);
    const copy = gpa.dupe(u8, bytes) catch return false;
    c.lock.lock();
    if (!s.head_queued or s.out_end or s.canceled or c.closing) {
        c.lock.unlock();
        gpa.free(copy);
        return false;
    }
    if (s.is_head) {
        c.lock.unlock();
        gpa.free(copy);
        return true;
    }
    s.chunks.append(gpa, .{ .data = copy }) catch {
        c.lock.unlock();
        gpa.free(copy);
        return false;
    };
    s.queued_bytes += copy.len;
    c.lock.unlock();
    wake(c);
    // Geri basınç.
    while (true) {
        c.lock.lock();
        const over = s.queued_bytes > stream_queue_high_water and !s.canceled and !c.closing;
        c.lock.unlock();
        if (!over or c.hooks.shuttingDown()) break;
        sleepCoop(2);
    }
    c.lock.lock();
    const ok = !s.canceled and !c.closing;
    c.lock.unlock();
    return ok;
}

/// Akışı bitirir (tekrar çağrı zararsız).
pub fn streamEnd(s: *Stream) void {
    const c = s.conn;
    c.lock.lock();
    if (s.head_queued and !s.out_end) s.out_end = true;
    c.lock.unlock();
    wake(c);
}

/// Handler bu akışta yanıt başlatmış mı (tam yanıt ya da `streamBegin`)?
pub fn responseStarted(s: *Stream) bool {
    const c = s.conn;
    c.lock.lock();
    defer c.lock.unlock();
    return s.head_queued;
}

/// Yanıt trailer'ları (akış bitmeden, `streamEnd`'den ÖNCE): gövdeden sonra son HEADERS olarak gider. `false`: akış başlamamış/bitmiş/iptal ya da bellek yok.
pub fn streamTrailers(s: *Stream, headers: []const std.http.Header) bool {
    const c = s.conn;
    const gpa = c.gpa;
    var blk: std.ArrayListUnmanaged(u8) = .empty;
    defer blk.deinit(gpa);
    for (headers) |h| {
        if (h.name.len == 0 or h.name[0] == ':' or h2.isConnectionSpecific(h.name) or h.name.len > 128) continue;
        var lower: [128]u8 = undefined;
        for (h.name, 0..) |ch, i| lower[i] = std.ascii.toLower(ch);
        h2.encodeField(&blk, gpa, lower[0..h.name.len], h.value) catch return false;
    }
    if (blk.items.len == 0) return true; // boş trailer = trailer yok
    const owned = blk.toOwnedSlice(gpa) catch return false;
    c.lock.lock();
    if (!s.head_queued or s.out_end or s.out_trailers != null) {
        c.lock.unlock();
        gpa.free(owned);
        return false;
    }
    if (s.canceled or c.closing) {
        c.lock.unlock();
        gpa.free(owned);
        return true; // istemci gitti: sessizce kabul
    }
    s.out_trailers = owned;
    c.lock.unlock();
    return true;
}

/// Gelen trailer'lardan `name` (büyük/küçük harf duyarsız) değeri; çoklu değerler ", " ile birleşir. `buf`a yazılır, yoksa `null`.
pub fn requestTrailer(s: *Stream, name: []const u8, out: *std.ArrayListUnmanaged(u8), gpa: Allocator) bool {
    var found = false;
    for (s.trailers.items) |t| {
        if (!std.ascii.eqlIgnoreCase(t.name, name)) continue;
        if (found) out.appendSlice(gpa, ", ") catch return found;
        out.appendSlice(gpa, t.value) catch return found;
        found = true;
    }
    return found;
}

/// WebSocket (RFC 8441) kipinde gelen veriyi okur: veri gelene, istemci END_STREAM/RST yollayana ya da bağlantı kapanana dek KOOPERATİF bekler. `null` = akış sonu.
/// Tüketilen baytlar akış penceresine geri verilir (yavaş tüketici istemciyi yavaşlatır, bellek sınırlı kalır).
pub fn inboundRead(s: *Stream, dst: []u8) ?usize {
    const c = s.conn;
    while (true) {
        c.lock.lock();
        const avail = s.inbound.items.len - s.inbound_off;
        if (avail > 0) {
            const n = @min(avail, dst.len);
            @memcpy(dst[0..n], s.inbound.items[s.inbound_off..][0..n]);
            s.inbound_off += n;
            if (s.inbound_off == s.inbound.items.len) {
                s.inbound.clearRetainingCapacity();
                s.inbound_off = 0;
            }
            s.recv_pending += @intCast(n);
            if (s.recv_pending >= window_update_threshold and !s.recv_ended and !s.canceled) {
                queueWindowUpdateLocked(c, s.id, s.recv_pending);
                s.recv_window += s.recv_pending;
                s.recv_pending = 0;
            }
            c.lock.unlock();
            wake(c);
            return n;
        }
        const done = s.recv_ended or s.canceled or c.closing;
        c.lock.unlock();
        if (done) return null;
        sleepCoop(1);
    }
}

/// Handler yanıt göndermeden döndüyse 500, akış açık kaldıysa bitir.
fn ensureFinished(s: *Stream) void {
    const c = s.conn;
    c.lock.lock();
    const queued = s.head_queued;
    const ended = s.out_end;
    c.lock.unlock();
    if (!queued) {
        respond(s, 500, &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }}, "Internal Server Error");
    } else if (!ended) {
        streamEnd(s);
    }
}

fn streamEntry(arg: *anyopaque) void {
    const s: *Stream = @ptrCast(@alignCast(arg));
    const c = s.conn;
    if (s.early_status != 0) {
        respond(s, s.early_status, &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }}, statusText(s.early_status));
    } else {
        c.hooks.serveStream(c.hooks.user, s);
        ensureFinished(s);
    }
    c.lock.lock();
    s.handler_state = .done;
    if (!s.in_map) s.destroy();
    c.lock.unlock();
    wake(c);
    _ = c.active_fibers.fetchSub(1, .acq_rel);
}

fn statusText(status: u16) []const u8 {
    return switch (status) {
        400 => "Bad Request",
        413 => "Payload Too Large",
        431 => "Request Header Fields Too Large",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        else => "Error",
    };
}

// ---- Yazıcı fiber'ı ----------------------------------------------------------------------------------------------------------------------------------

const WriterCtx = struct {
    conn: *Conn,
    writer: *std.Io.Writer,
};

fn writerEntry(arg: *anyopaque) void {
    const wc: *WriterCtx = @ptrCast(@alignCast(arg));
    const c = wc.conn;
    writerLoop(c, wc.writer);
    c.writer_done.store(true, .release);
}

fn drainWakePipe(c: *Conn) void {
    var buf: [64]u8 = undefined;
    while (true) {
        const n = std.c.read(c.wake_r, &buf, buf.len);
        if (n <= 0) break;
    }
}

fn writerLoop(c: *Conn, writer: *std.Io.Writer) void {
    const gpa = c.gpa;
    var wbuf: std.ArrayListUnmanaged(u8) = .empty;
    defer wbuf.deinit(gpa);
    var last_tick: u64 = nowMs();
    while (true) {
        // Ticker, yazıcı yoğun olsa bile en geç 100 ms'de bir çalışır (zaman aşımları aç kalmasın).
        const now = nowMs();
        if (now -| last_tick >= 100) {
            last_tick = now;
            tick(c, now);
        }
        c.wake_pending.store(false, .release);
        wbuf.clearRetainingCapacity();
        c.lock.lock();
        // Denetim çerçeveleri önce.
        wbuf.appendSlice(gpa, c.outq.items) catch {
            c.lock.unlock();
            breakConn(c);
            return;
        };
        c.outq.clearRetainingCapacity();
        if (!c.fatal) buildStreamFramesLocked(c, &wbuf);
        const closing = c.closing;
        c.lock.unlock();

        if (wbuf.items.len > 0) {
            writer.writeAll(wbuf.items) catch {
                breakConn(c);
                return;
            };
            writer.flush() catch {
                breakConn(c);
                return;
            };
            continue; // pencere/bütçe elverdiyse daha fazlası vardır
        }
        c.hooks.flushTransport(c.hooks.user);
        if (closing) return;
        _ = fiber_net.waitFd(c.wake_r, false, 100);
        drainWakePipe(c);
    }
}

/// Yazma başarısız: bağlantı bitti; okuyucu EOF görsün.
fn breakConn(c: *Conn) void {
    c.lock.lock();
    c.fatal = true;
    c.closing = true;
    cancelAllLocked(c);
    c.lock.unlock();
    c.hooks.closeRead(c.hooks.user);
}

/// Kilit altında: bekleyen akış çıktısını pencerelerin elverdiği kadar `wbuf`a çerçeveler.
fn buildStreamFramesLocked(c: *Conn, wbuf: *std.ArrayListUnmanaged(u8)) void {
    const gpa = c.gpa;
    c.retire.clearRetainingCapacity();
    var round_total: usize = 0;
    var it = c.streams.valueIterator();
    while (it.next()) |sp| {
        const s = sp.*;
        if (s.canceled) {
            if (s.out_head) |h| {
                gpa.free(h);
                s.out_head = null;
            }
            for (s.chunks.items[s.chunk_head..]) |ch| gpa.free(ch.data);
            s.chunks.clearRetainingCapacity();
            s.chunk_head = 0;
            s.queued_bytes = 0;
            c.retire.append(gpa, s) catch {};
            continue;
        }
        if (s.out_head != null and !s.head_sent) {
            const head = s.out_head.?;
            const end_on_headers = s.out_end and s.chunk_head >= s.chunks.items.len and s.out_trailers == null;
            appendHeaderBlock(wbuf, gpa, s.id, head, end_on_headers, c.peer_max_frame) catch return;
            gpa.free(head);
            s.out_head = null;
            s.head_sent = true;
            if (end_on_headers) s.end_sent = true;
        }
        if (s.head_sent and !s.end_sent) {
            var stream_round: usize = 0;
            while (stream_round < round_bytes_per_stream and round_total < round_bytes_total) {
                if (s.chunk_head >= s.chunks.items.len) {
                    if (s.out_end) {
                        if (s.out_trailers) |tr| {
                            // Trailer'lar: son HEADERS(END_HEADERS|END_STREAM) bloğu (gerekirse CONTINUATION).
                            appendHeaderBlockFlags(wbuf, gpa, s.id, tr, h2.flag_end_stream, c.peer_max_frame) catch return;
                            gpa.free(tr);
                            s.out_trailers = null;
                        } else {
                            h2.appendFrameHeader(wbuf, gpa, 0, h2.frame_data, h2.flag_end_stream, s.id) catch return;
                        }
                        s.end_sent = true;
                    }
                    break;
                }
                const ch = &s.chunks.items[s.chunk_head];
                const remaining = ch.data.len - ch.off;
                var avail: i64 = @intCast(remaining);
                avail = @min(avail, c.conn_send_window, s.send_window, @as(i64, c.peer_max_frame));
                if (avail <= 0) break;
                const n: usize = @intCast(avail);
                const last_chunk = s.chunk_head + 1 == s.chunks.items.len;
                const is_last = last_chunk and n == remaining and s.out_end and s.out_trailers == null;
                h2.appendFrameHeader(wbuf, gpa, @intCast(n), h2.frame_data, if (is_last) h2.flag_end_stream else 0, s.id) catch return;
                wbuf.appendSlice(gpa, ch.data[ch.off..][0..n]) catch return;
                ch.off += n;
                c.conn_send_window -= avail;
                s.send_window -= avail;
                s.queued_bytes -= n;
                stream_round += n;
                round_total += n;
                if (ch.off == ch.data.len) {
                    gpa.free(ch.data);
                    s.chunk_head += 1;
                    if (s.chunk_head == s.chunks.items.len) {
                        s.chunks.clearRetainingCapacity();
                        s.chunk_head = 0;
                    }
                }
                if (is_last) {
                    s.end_sent = true;
                    break;
                }
            }
        }
        if (s.end_sent) {
            if (s.rst_after) {
                var p: [4]u8 = undefined;
                std.mem.writeInt(u32, &p, @intFromEnum(h2.ErrorCode.no_error), .big);
                h2.appendFrameHeader(wbuf, gpa, 4, h2.frame_rst_stream, 0, s.id) catch return;
                wbuf.appendSlice(gpa, &p) catch return;
            }
            c.retire.append(gpa, s) catch {};
        }
    }
    for (c.retire.items) |s| removeStreamLocked(c, s);
    c.retire.clearRetainingCapacity();
}

fn appendHeaderBlock(wbuf: *std.ArrayListUnmanaged(u8), gpa: Allocator, id: u32, block: []const u8, end_stream: bool, max_frame: u32) Allocator.Error!void {
    return appendHeaderBlockFlags(wbuf, gpa, id, block, if (end_stream) h2.flag_end_stream else 0, max_frame);
}

fn appendHeaderBlockFlags(wbuf: *std.ArrayListUnmanaged(u8), gpa: Allocator, id: u32, block: []const u8, extra_flags: u8, max_frame: u32) Allocator.Error!void {
    var off: usize = 0;
    var first = true;
    while (true) {
        const take = @min(block.len - off, max_frame);
        const last = off + take == block.len;
        var flags: u8 = 0;
        if (last) flags |= h2.flag_end_headers;
        if (first) flags |= extra_flags;
        try h2.appendFrameHeader(wbuf, gpa, @intCast(take), if (first) h2.frame_headers else h2.frame_continuation, flags, id);
        try wbuf.appendSlice(gpa, block[off..][0..take]);
        off += take;
        first = false;
        if (last) break;
    }
}

/// Yazıcının 100 ms'lik ticker'ı: kapanış (GOAWAY), eksik istek ve boşta zaman aşımları.
fn tick(c: *Conn, now: u64) void {
    var close_now = false;
    c.lock.lock();
    if (c.hooks.shuttingDown() and !c.goaway_sent) {
        var p: [8]u8 = undefined;
        std.mem.writeInt(u32, p[0..4], c.last_peer_stream_id, .big);
        std.mem.writeInt(u32, p[4..8], @intFromEnum(h2.ErrorCode.no_error), .big);
        _ = appendCtrlLocked(c, h2.frame_goaway, 0, 0, &p);
        c.goaway_sent = true;
        c.draining = true;
    }
    if (c.draining and c.live_streams.load(.acquire) == 0 and c.outq.items.len == 0) {
        c.closing = true;
        close_now = true;
    }
    // Eksik istek zaman aşımı.
    var it = c.streams.valueIterator();
    while (it.next()) |sp| {
        const s = sp.*;
        if (!s.recv_ended and !s.canceled and !s.ws_mode and now -| s.activity_ms >= c.cfg.read_timeout_ms) {
            s.canceled = true;
            queueRstLocked(c, s.id, .cancel);
        }
    }
    // Başlık bloğu (CONTINUATION) yarım kaldı.
    const hb = c.header_block_since_ms.load(.acquire);
    if (hb != 0 and now -| hb >= c.cfg.read_timeout_ms) {
        var p: [8]u8 = undefined;
        std.mem.writeInt(u32, p[0..4], c.last_peer_stream_id, .big);
        std.mem.writeInt(u32, p[4..8], @intFromEnum(h2.ErrorCode.protocol_error), .big);
        if (!c.goaway_sent) _ = appendCtrlLocked(c, h2.frame_goaway, 0, 0, &p);
        c.goaway_sent = true;
        c.fatal = true;
        c.closing = true;
        cancelAllLocked(c);
        close_now = true;
    }
    // Boşta bağlantı.
    if (!close_now and c.live_streams.load(.acquire) == 0 and now -| c.last_activity_ms.load(.acquire) >= c.cfg.idle_timeout_ms) {
        var p: [8]u8 = undefined;
        std.mem.writeInt(u32, p[0..4], c.last_peer_stream_id, .big);
        std.mem.writeInt(u32, p[4..8], @intFromEnum(h2.ErrorCode.no_error), .big);
        if (!c.goaway_sent) _ = appendCtrlLocked(c, h2.frame_goaway, 0, 0, &p);
        c.goaway_sent = true;
        c.closing = true;
        close_now = true;
    }
    c.lock.unlock();
    if (close_now) c.hooks.closeRead(c.hooks.user);
}

// ---- Okuyucu (bağlantı fiber'ı) ----------------------------------------------------------------------------------------------------------------

const ContState = struct {
    stream_id: u32,
    end_stream: bool,
    trailers: bool,
    block: std.ArrayListUnmanaged(u8) = .empty,
};

fn wakeFromTransport(arg: *anyopaque) void {
    wake(@ptrCast(@alignCast(arg)));
}

fn spawnAndTrack(c: *Conn, entry: FiberFn, arg: *anyopaque, pinned: bool) bool {
    _ = c.active_fibers.fetchAdd(1, .acq_rel);
    if (c.hooks.spawn(c.hooks.user, entry, arg, pinned)) return true;
    _ = c.active_fibers.fetchSub(1, .acq_rel);
    return false;
}

/// Bağlantıyı yürütür (bağlantı fiber'ında). `reader`/`writer` TLS olsun olmasın bağlantının Reader/Writer çiftidir. `false` dönerse bağlantı HTTP/2 başlatamadı (çağıran kapatır).
pub fn run(gpa: Allocator, reader: *std.Io.Reader, writer: *std.Io.Writer, cfg: Config, hooks: Hooks) void {
    if (comptime !supported) return;
    // Bağlantı ön eki.
    var pre: [h2.preface.len]u8 = undefined;
    reader.readSliceAll(&pre) catch return;
    if (!std.mem.eql(u8, &pre, h2.preface)) return;
    // (Zaman aşımları `afterPreface` ile kalkar; Conn oluşturulduktan sonra çağrılır.)

    var fds: [2]c_int = undefined;
    if (std.c.pipe(&fds) != 0) return;
    io_mod.setNonBlocking(fds[0]);
    io_mod.setNonBlocking(fds[1]);
    const c = gpa.create(Conn) catch {
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
        return;
    };
    c.* = .{ .gpa = gpa, .cfg = cfg, .hooks = hooks, .last_activity_ms = .init(nowMs()), .wake_r = fds[0], .wake_w = fds[1] };
    var wc: WriterCtx = .{ .conn = c, .writer = writer };
    defer {
        c.lock.lock();
        var it = c.streams.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            s.in_map = false;
            s.destroy();
        }
        c.streams.deinit(gpa);
        c.lock.unlock();
        c.outq.deinit(gpa);
        c.retire.deinit(gpa);
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
        gpa.destroy(c);
    }

    // Sunucu SETTINGS + bağlantı penceresini yükselt.
    {
        var st: [6 * 5]u8 = undefined;
        var n: usize = 0;
        const all_entries = [_][2]u32{
            .{ h2.setting_max_concurrent_streams, cfg.max_concurrent_streams },
            .{ h2.setting_initial_window_size, our_stream_window },
            .{ h2.setting_max_header_list_size, @intCast(@min(cfg.max_header_bytes, 0x7fffffff)) },
            .{ h2.setting_enable_push, 0 },
            .{ h2.setting_enable_connect_protocol, 1 },
        };
        const entries = all_entries[0..if (cfg.ws_enabled) all_entries.len else all_entries.len - 1];
        for (entries) |e| {
            std.mem.writeInt(u16, st[n..][0..2], @intCast(e[0]), .big);
            std.mem.writeInt(u32, st[n + 2 ..][0..4], e[1], .big);
            n += 6;
        }
        c.lock.lock();
        _ = appendCtrlLocked(c, h2.frame_settings, 0, 0, st[0..n]);
        queueWindowUpdateLocked(c, 0, our_conn_window - @as(u32, @intCast(h2.default_window)));
        c.lock.unlock();
    }

    hooks.afterPreface(hooks.user, wakeFromTransport, c);
    if (!spawnAndTrack(c, writerEntry, &wc, true)) return;
    // Yazıcı fiber'ı sayacı `active_fibers`ta sayıldı; bitişi `writer_done` ile izlenir.
    readerLoop(c, reader);

    // Kapanış: akışlar iptal, yazıcı boşaltıp çıkar, handler'lar biter.
    c.lock.lock();
    c.closing = true;
    cancelAllLocked(c);
    c.lock.unlock();
    wake(c);
    while (!c.writer_done.load(.acquire)) sleepCoop(1);
    while (c.active_fibers.load(.acquire) > 1) sleepCoop(2); // 1 = yazıcı fiber'ının kendisi (aşağıda düşülür)
    _ = c.active_fibers.fetchSub(1, .acq_rel);
}

fn readerLoop(c: *Conn, r: *std.Io.Reader) void {
    const gpa = c.gpa;
    var decoder = h2.Decoder.init(gpa, 4096);
    defer decoder.deinit();
    const buf = gpa.alloc(u8, our_max_frame) catch return;
    defer gpa.free(buf);
    var cont: ?ContState = null;
    defer if (cont) |*cs| cs.block.deinit(gpa);
    var flood: Flood = .{ .window_start_ms = nowMs() };
    var hdr: [9]u8 = undefined;
    var conn_recv_window: i64 = our_conn_window;
    const max_block: usize = @max(c.cfg.max_header_bytes * 2, 64 * 1024);

    while (true) {
        r.readSliceAll(&hdr) catch return;
        const fh = h2.parseFrameHeader(&hdr);
        if (fh.length > our_max_frame) return connError(c, .frame_size_error);
        const payload = buf[0..fh.length];
        r.readSliceAll(payload) catch return;
        const now = nowMs();
        c.last_activity_ms.store(now, .release);

        if (cont != null and fh.kind != h2.frame_continuation) return connError(c, .protocol_error);

        switch (fh.kind) {
            h2.frame_settings => {
                if (fh.stream_id != 0) return connError(c, .protocol_error);
                if (fh.flags & h2.flag_ack != 0) {
                    if (fh.length != 0) return connError(c, .frame_size_error);
                    continue;
                }
                if (fh.length % 6 != 0) return connError(c, .frame_size_error);
                if (flood.charge(now, .control)) return connError(c, .enhance_your_calm);
                var off: usize = 0;
                c.lock.lock();
                while (off < payload.len) : (off += 6) {
                    const id = std.mem.readInt(u16, payload[off..][0..2], .big);
                    const val = std.mem.readInt(u32, payload[off + 2 ..][0..4], .big);
                    switch (id) {
                        h2.setting_enable_push => if (val > 1) {
                            c.lock.unlock();
                            return connError(c, .protocol_error);
                        },
                        h2.setting_initial_window_size => {
                            if (val > h2.max_window) {
                                c.lock.unlock();
                                return connError(c, .flow_control_error);
                            }
                            const delta: i64 = @as(i64, val) - c.peer_initial_window;
                            c.peer_initial_window = val;
                            var it = c.streams.valueIterator();
                            while (it.next()) |sp| {
                                sp.*.send_window += delta;
                                if (sp.*.send_window > h2.max_window) {
                                    c.lock.unlock();
                                    return connError(c, .flow_control_error);
                                }
                            }
                        },
                        h2.setting_max_frame_size => {
                            if (val < h2.default_max_frame or val > h2.max_allowed_frame) {
                                c.lock.unlock();
                                return connError(c, .protocol_error);
                            }
                            c.peer_max_frame = val;
                        },
                        else => {},
                    }
                }
                _ = appendCtrlLocked(c, h2.frame_settings, h2.flag_ack, 0, &.{});
                c.lock.unlock();
                wake(c);
            },
            h2.frame_ping => {
                if (fh.stream_id != 0) return connError(c, .protocol_error);
                if (fh.length != 8) return connError(c, .frame_size_error);
                if (fh.flags & h2.flag_ack != 0) continue;
                if (flood.charge(now, .control)) return connError(c, .enhance_your_calm);
                c.lock.lock();
                _ = appendCtrlLocked(c, h2.frame_ping, h2.flag_ack, 0, payload);
                c.lock.unlock();
                wake(c);
            },
            h2.frame_window_update => {
                if (fh.length != 4) return connError(c, .frame_size_error);
                const inc = std.mem.readInt(u32, payload[0..4], .big) & 0x7fffffff;
                if (fh.stream_id == 0) {
                    if (inc == 0) return connError(c, .protocol_error);
                    c.lock.lock();
                    c.conn_send_window += inc;
                    const over = c.conn_send_window > h2.max_window;
                    c.lock.unlock();
                    if (over) return connError(c, .flow_control_error);
                } else {
                    c.lock.lock();
                    if (c.streams.get(fh.stream_id)) |s| {
                        if (inc == 0) {
                            queueRstLocked(c, s.id, .protocol_error);
                            s.canceled = true;
                        } else {
                            s.send_window += inc;
                            if (s.send_window > h2.max_window) {
                                queueRstLocked(c, s.id, .flow_control_error);
                                s.canceled = true;
                            }
                        }
                    } else if (fh.stream_id > c.last_peer_stream_id) {
                        c.lock.unlock();
                        return connError(c, .protocol_error);
                    }
                    c.lock.unlock();
                }
                wake(c);
            },
            h2.frame_rst_stream => {
                if (fh.stream_id == 0) return connError(c, .protocol_error);
                if (fh.length != 4) return connError(c, .frame_size_error);
                if (flood.charge(now, .rst)) return connError(c, .enhance_your_calm);
                c.lock.lock();
                if (c.streams.get(fh.stream_id)) |s| {
                    s.canceled = true;
                } else if (fh.stream_id > c.last_peer_stream_id) {
                    c.lock.unlock();
                    return connError(c, .protocol_error);
                }
                c.lock.unlock();
                wake(c);
            },
            h2.frame_priority => {
                if (fh.stream_id == 0) return connError(c, .protocol_error);
                if (flood.charge(now, .control)) return connError(c, .enhance_your_calm);
                // Öncelik yok sayılır (RFC 9113 §5.3 kullanımdan kalktı); boyut geçersizse akış hatası yerine yok sayıyoruz.
            },
            h2.frame_goaway => {
                if (fh.stream_id != 0) return connError(c, .protocol_error);
                if (fh.length < 8) return connError(c, .frame_size_error);
                // İstemci yeni akış açmayacak: mevcutlar bitince kapanırız.
                c.lock.lock();
                c.draining = true;
                c.lock.unlock();
                wake(c);
            },
            h2.frame_push_promise => return connError(c, .protocol_error),
            h2.frame_data => {
                if (fh.stream_id == 0) return connError(c, .protocol_error);
                var data = payload;
                if (fh.flags & h2.flag_padded != 0) {
                    if (data.len < 1) return connError(c, .frame_size_error);
                    const pad = data[0];
                    if (pad >= data.len) return connError(c, .protocol_error);
                    data = data[1 .. data.len - pad];
                }
                if (data.len == 0 and fh.flags & h2.flag_end_stream == 0 and flood.charge(now, .empty_data)) return connError(c, .enhance_your_calm);
                conn_recv_window -= fh.length;
                if (conn_recv_window < 0) return connError(c, .flow_control_error);
                c.lock.lock();
                c.conn_recv_pending += fh.length;
                if (c.conn_recv_pending >= window_update_threshold * 2) {
                    queueWindowUpdateLocked(c, 0, c.conn_recv_pending);
                    conn_recv_window += c.conn_recv_pending;
                    c.conn_recv_pending = 0;
                }
                const found = c.streams.get(fh.stream_id);
                var dispatch_stream: ?*Stream = null;
                if (found) |s| {
                    s.activity_ms = now;
                    s.recv_window -= fh.length;
                    if (s.discard_body) {
                        // 413 verildi: veri atılır, yanıt (ve ardından NO_ERROR sıfırlaması) bozulmaz.
                    } else if (s.recv_ended) {
                        queueRstLocked(c, s.id, .stream_closed);
                        s.canceled = true;
                    } else if (s.recv_window < 0) {
                        queueRstLocked(c, s.id, .flow_control_error);
                        s.canceled = true;
                    } else if (s.ws_mode) {
                        // WebSocket: veri akış olarak sıraya girer; stream-seviyesi pencere tüketildikçe (`inboundRead`) açılır.
                        s.inbound.appendSlice(gpa, data) catch {
                            queueRstLocked(c, s.id, .internal_error);
                            s.canceled = true;
                        };
                        if (fh.flags & h2.flag_end_stream != 0) s.recv_ended = true;
                    } else {
                        if (s.early_status == 0) {
                            if (s.body.items.len + data.len > c.cfg.max_body_bytes) {
                                s.early_status = 413;
                                s.discard_body = true;
                                s.body.clearAndFree(gpa);
                                s.rst_after = true; // yanıttan sonra NO_ERROR ile sıfırla: istemci göndermeyi bıraksın
                            } else if (data.len > 0) {
                                s.body.appendSlice(gpa, data) catch {
                                    s.early_status = 413;
                                    s.discard_body = true;
                                    s.body.clearAndFree(gpa);
                                };
                            }
                        }
                        s.recv_pending += fh.length;
                        if (fh.flags & h2.flag_end_stream != 0) {
                            s.recv_ended = true;
                            s.handler_state = .running;
                            dispatch_stream = s;
                        } else if (s.recv_pending >= window_update_threshold) {
                            queueWindowUpdateLocked(c, s.id, s.recv_pending);
                            s.recv_window += s.recv_pending;
                            s.recv_pending = 0;
                        }
                        // Erken yanıt (413): hemen yanıtla, kalan veri atılır.
                        if (s.early_status != 0 and dispatch_stream == null and !s.recv_ended) {
                            s.recv_ended = true;
                            s.handler_state = .running;
                            dispatch_stream = s;
                        }
                    }
                } else if (fh.stream_id > c.last_peer_stream_id) {
                    c.lock.unlock();
                    return connError(c, .protocol_error);
                }
                c.lock.unlock();
                if (dispatch_stream) |s| dispatchStream(c, s);
                wake(c);
            },
            h2.frame_headers => {
                if (fh.stream_id == 0 or fh.stream_id % 2 == 0) return connError(c, .protocol_error);
                var p = payload;
                var pad: usize = 0;
                if (fh.flags & h2.flag_padded != 0) {
                    if (p.len < 1) return connError(c, .frame_size_error);
                    pad = p[0];
                    p = p[1..];
                }
                if (fh.flags & h2.flag_priority != 0) {
                    if (p.len < 5) return connError(c, .frame_size_error);
                    const dep = std.mem.readInt(u32, p[0..4], .big) & 0x7fffffff;
                    if (dep == fh.stream_id) return connError(c, .protocol_error);
                    p = p[5..];
                }
                if (pad > p.len) return connError(c, .protocol_error);
                p = p[0 .. p.len - pad];

                c.lock.lock();
                const existing = c.streams.get(fh.stream_id) != null;
                const last = c.last_peer_stream_id;
                c.lock.unlock();
                var trailers = false;
                if (existing) {
                    if (fh.flags & h2.flag_end_stream == 0) return connError(c, .protocol_error);
                    trailers = true;
                } else {
                    if (fh.stream_id <= last) return connError(c, .protocol_error);
                    c.lock.lock();
                    c.last_peer_stream_id = fh.stream_id;
                    c.lock.unlock();
                }
                cont = .{ .stream_id = fh.stream_id, .end_stream = fh.flags & h2.flag_end_stream != 0, .trailers = trailers };
                cont.?.block.appendSlice(gpa, p) catch return connError(c, .internal_error);
                if (fh.flags & h2.flag_end_headers != 0) {
                    const cs = cont.?;
                    cont = null;
                    var owned = cs;
                    defer owned.block.deinit(gpa);
                    if (!finishHeaderBlock(c, &decoder, &owned)) return;
                } else {
                    c.header_block_since_ms.store(now, .release);
                }
            },
            h2.frame_continuation => {
                const cs = &(cont orelse return connError(c, .protocol_error));
                if (fh.stream_id != cs.stream_id) return connError(c, .protocol_error);
                if (cs.block.items.len + payload.len > max_block) return connError(c, .enhance_your_calm);
                cs.block.appendSlice(gpa, payload) catch return connError(c, .internal_error);
                if (fh.flags & h2.flag_end_headers != 0) {
                    var owned = cs.*;
                    cont = null;
                    c.header_block_since_ms.store(0, .release);
                    defer owned.block.deinit(gpa);
                    if (!finishHeaderBlock(c, &decoder, &owned)) return;
                }
            },
            else => {}, // bilinmeyen tür: yok say (RFC 9113 §4.1)
        }
    }
}

/// Tam bir başlık bloğunu çözer ve akışı açar. `false` = bağlantı hatası (GOAWAY kuyruğa alındı).
fn finishHeaderBlock(c: *Conn, decoder: *h2.Decoder, cs: *ContState) bool {
    const gpa = c.gpa;
    c.header_block_since_ms.store(0, .release);
    if (cs.trailers) {
        // Fragman tablo eşzamanı için çözülür, sonuç yok sayılır.
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var tmp: std.ArrayListUnmanaged(h2.Header) = .empty;
        _ = decoder.decode(cs.block.items, arena.allocator(), &tmp, c.cfg.max_header_bytes) catch {
            connError(c, .compression_error);
            return false;
        };
        // Trailer HEADERS isteğin SONUDUR (END_STREAM zorunlu): gövde tamam, handler başlasın.
        c.lock.lock();
        var go_trailer: ?*Stream = null;
        if (c.streams.get(cs.stream_id)) |ts| {
            if (!ts.recv_ended and !ts.canceled) {
                const ta = ts.arena.allocator();
                for (tmp.items) |th| {
                    if (th.name.len == 0 or th.name[0] == ':') continue; // trailer'da pseudo-header yok
                    const cname = canonicalName(ta, th.name) catch continue;
                    const cval = ta.dupe(u8, th.value) catch continue;
                    ts.trailers.append(ta, .{ .name = cname, .value = cval }) catch {};
                }
                ts.recv_ended = true;
                ts.handler_state = .running;
                go_trailer = ts;
            }
        }
        c.lock.unlock();
        if (go_trailer) |ts| dispatchStream(c, ts);
        return true;
    }
    const s = gpa.create(Stream) catch {
        connError(c, .internal_error);
        return false;
    };
    s.* = .{
        .conn = c,
        .id = cs.stream_id,
        .arena = std.heap.ArenaAllocator.init(gpa),
        .send_window = c.peer_initial_window,
        .activity_ms = nowMs(),
    };
    _ = c.live_streams.fetchAdd(1, .acq_rel);
    var exceeded = false;
    var tmp_headers: std.ArrayListUnmanaged(h2.Header) = .empty;
    exceeded = decoder.decode(cs.block.items, s.arena.allocator(), &tmp_headers, c.cfg.max_header_bytes) catch {
        s.in_map = false;
        s.destroy();
        connError(c, .compression_error);
        return false;
    };

    // Akış sınırı / kapanış: reddet (blok yine de çözüldü).
    c.lock.lock();
    const too_many = c.live_streams.load(.acquire) > c.cfg.max_concurrent_streams;
    const refuse = too_many or c.draining or c.closing;
    if (refuse) queueRstLocked(c, s.id, .refused_stream);
    c.lock.unlock();
    if (refuse) {
        s.in_map = false;
        s.destroy();
        wake(c);
        return true;
    }

    const malformed = !buildRequest(s, tmp_headers.items, c.cfg.ws_enabled) or (s.ws_connect and cs.end_stream);
    if (malformed) {
        c.lock.lock();
        queueRstLocked(c, s.id, .protocol_error);
        c.lock.unlock();
        s.in_map = false;
        s.destroy();
        wake(c);
        return true;
    }
    if (exceeded) s.early_status = 431;
    // Düz CONNECT ve "websocket" dışı genişletilmiş CONNECT desteklenmez.
    if (std.mem.eql(u8, s.method, "CONNECT") and !s.ws_connect) s.early_status = 501;

    c.lock.lock();
    c.streams.put(gpa, s.id, s) catch {
        c.lock.unlock();
        s.in_map = false;
        s.destroy();
        connError(c, .internal_error);
        return false;
    };
    var go = false;
    if (cs.end_stream) {
        s.recv_ended = true;
        s.handler_state = .running;
        go = true;
    } else if (s.ws_connect) {
        // WebSocket: istek gövdesi (WS çerçeveleri) sürerken handler HEMEN başlar.
        s.ws_mode = true;
        s.handler_state = .running;
        go = true;
    } else if (s.expect_continue) {
        // `Expect: 100-continue`: istemci gövdeyi göndermeden önce ara yanıtı bekleyebilir.
        var blk: std.ArrayListUnmanaged(u8) = .empty;
        defer blk.deinit(gpa);
        if (h2.encodeField(&blk, gpa, ":status", "100")) |_| {
            _ = appendCtrlLocked(c, h2.frame_headers, h2.flag_end_headers, s.id, blk.items);
        } else |_| {}
    }
    c.lock.unlock();
    if (go) dispatchStream(c, s);
    wake(c);
    return true;
}

/// İstek tamamlandı (başlıklar + gövde): content-length doğrula, handler fiber'ını başlat.
fn dispatchStream(c: *Conn, s: *Stream) void {
    if (s.early_status == 0) {
        if (s.content_length) |cl| {
            if (cl != s.body.items.len) s.early_status = 400;
        }
    }
    // `handler_state` çağıran tarafından kilit altında zaten `.running` yapıldı (akışın başka yerden yok edilmesini önler).
    if (!spawnAndTrack(c, streamEntry, s, false)) {
        c.lock.lock();
        s.handler_state = .done;
        queueRstLocked(c, s.id, .refused_stream);
        s.canceled = true;
        if (!s.in_map) s.destroy();
        c.lock.unlock();
        wake(c);
    }
}

fn canonicalName(a: Allocator, name: []const u8) Allocator.Error![]u8 {
    const out = try a.alloc(u8, name.len);
    var upper = true;
    for (name, 0..) |ch, i| {
        out[i] = if (upper) std.ascii.toUpper(ch) else ch;
        upper = ch == '-';
    }
    return out;
}

/// Çözülmüş başlık listesinden isteği kurar ve RFC 9113 §8.2/§8.3 doğrulamasını yapar (`false` = hatalı biçimli istek).
fn buildRequest(s: *Stream, decoded: []const h2.Header, ws_enabled: bool) bool {
    const a = s.arena.allocator();
    var seen_regular = false;
    var have_method = false;
    var have_path = false;
    var have_scheme = false;
    var have_host = false;
    for (decoded) |h| {
        if (h.name.len == 0) return false;
        if (std.mem.indexOfAny(u8, h.value, "\r\n\x00") != null) return false;
        if (h.name[0] == ':') {
            if (seen_regular) return false;
            if (std.mem.eql(u8, h.name, ":method")) {
                if (have_method) return false;
                have_method = true;
                s.method = h.value;
            } else if (std.mem.eql(u8, h.name, ":path")) {
                if (have_path) return false;
                have_path = true;
                s.path = h.value;
            } else if (std.mem.eql(u8, h.name, ":scheme")) {
                if (have_scheme) return false;
                have_scheme = true;
            } else if (std.mem.eql(u8, h.name, ":authority")) {
                s.authority = h.value;
            } else if (std.mem.eql(u8, h.name, ":protocol")) {
                // RFC 8441: yalnızca SETTINGS_ENABLE_CONNECT_PROTOCOL bildirildiyse (WebSocket sunucusu varsa) geçerli.
                if (!ws_enabled or s.protocol.len != 0) return false;
                s.protocol = h.value;
            } else return false;
            continue;
        }
        seen_regular = true;
        for (h.name) |ch| {
            if (ch >= 'A' and ch <= 'Z') return false;
            if (ch <= 0x20 or ch >= 0x7f or ch == ':') return false;
        }
        if (h2.isConnectionSpecific(h.name)) return false;
        if (std.mem.eql(u8, h.name, "te") and !std.mem.eql(u8, h.value, "trailers")) return false;
        if (std.mem.eql(u8, h.name, "content-length")) {
            const v = std.fmt.parseInt(u64, h.value, 10) catch return false;
            if (s.content_length != null and s.content_length.? != v) return false;
            s.content_length = v;
        }
        if (std.mem.eql(u8, h.name, "host")) have_host = true;
        if (std.mem.eql(u8, h.name, "expect") and std.ascii.eqlIgnoreCase(h.value, "100-continue")) s.expect_continue = true;
        const cname = canonicalName(a, h.name) catch return false;
        s.headers.append(a, .{ .name = cname, .value = h.value }) catch return false;
    }
    if (!have_method or s.method.len == 0) return false;
    const is_connect = std.mem.eql(u8, s.method, "CONNECT");
    if (s.protocol.len != 0 and !is_connect) return false; // `:protocol` yalnızca CONNECT ile
    if (is_connect and s.protocol.len != 0) s.ws_connect = std.ascii.eqlIgnoreCase(s.protocol, "websocket");
    if (!is_connect or s.protocol.len != 0) {
        if (!have_scheme or !have_path or s.path.len == 0) return false;
        if (s.path[0] != '/' and !std.mem.eql(u8, s.path, "*")) return false;
    }
    if (!have_host and s.authority.len > 0) {
        s.headers.append(a, .{ .name = "Host", .value = s.authority }) catch return false;
    }
    s.is_head = std.mem.eql(u8, s.method, "HEAD");
    return true;
}
