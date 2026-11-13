//! HTTP/3 sunucu motoru (RFC 9114) — `quic.zig` (OpenSSL QUIC) üstünde, `h3.zig` (çerçeveleme + QPACK) ile (TODO 5.4, aşama H3.3/H3.5).
//!
//! Eşzamanlılık modeli: TEK "motor" fiber'ı (`run`) dinleyicinin TÜM OpenSSL çağrılarını yürütür (bağlantı/akış kabulü, çerçeve ayrıştırma, yazma); OpenSSL nesneleri eşzamanlı
//! kullanılmaz. Uygulama handler'ı her tamamlanan istek için AYRI bir fiber'da (`Hooks.spawn`) çalışır. Yanıt iki biçimde dönebilir: (1) arabellekli — handler `Response` döndürür, motor
//! kuyruğu boşaltıp yazar; (2) akışlı — handler çalışırken `StreamCtl` işlevleriyle (`ctlBegin`/`ctlSend`/`ctlTrailers`/`ctlEnd`) kilitli bir çıkış tamponuna çerçeve ekler, motor tamponu
//! her turda akışa yazar (geri basınç: tampon yüksek su çizgisini aşarsa handler kooperatif bekler). Uyandırma: işi süren handler varken motor 1 ms'lik kısa beklemeyle döner,
//! boştayken `SSL_get_event_timeout`/100 ms ile uyur.
//!
//! QPACK: dinamik tablo çözücüsü (engellemesiz kip, `SETTINGS_QPACK_BLOCKED_STREAMS=0`); kodlayıcımız yalnızca statik tabloyu kullanır. Protokol ihlalinde bağlantı uygun HTTP/3 hata koduyla
//! kapatılır (CONNECTION_CLOSE); kapanışta önce GOAWAY gönderilir, uçuştaki istekler bitirilir.

const std = @import("std");
const Allocator = std.mem.Allocator;
const quic = @import("quic.zig");
const h3 = @import("h3.zig");
const SpinLock = @import("../async_rt/spinlock.zig").SpinLock;

pub const Header = h3.Header;

/// Motorun sahip olduğu (gpa ile ayrılmış) istek; handler hook'u KOPYALAR, motor bellek sahibidir.
pub const Request = struct {
    method: []const u8,
    path: []const u8,
    authority: []const u8,
    headers: []const Header,
    body: []const u8,
    /// Gövdeden sonra gelen istek trailer'ları (yoksa boş).
    trailers: []const Header = &.{},
    /// Akışlı yanıt / trailer erişimi için bu isteğin akış denetimi (motor sahibi; handler dönene dek geçerli).
    ctl: *StreamCtl,
};

/// Handler hook'unun doldurduğu yanıt: `headers`/`body` `gpa` ile ayrılmış olmalı (motor serbest bırakır). `streamed`: yanıt `StreamCtl` ile yazıldı (başlık/gövde yok sayılır).
pub const Response = struct {
    status: u16 = 500,
    headers: []Header = &.{},
    body: []u8 = &.{},
    streamed: bool = false,
};

pub const Hooks = struct {
    user: *anyopaque,
    /// Handler fiber'ında çalışır. `false` ya da `out.status == 500` hata yanıtıdır.
    serve: *const fn (user: *anyopaque, gpa: Allocator, req: *const Request, out: *Response) bool,
    /// Bağlı bir fiber başlatır (`pinned`: çalınamaz). `false`: başlatılamadı.
    spawn: *const fn (user: *anyopaque, entry: *const fn (*anyopaque) void, arg: *anyopaque, pinned: bool) bool,
    shuttingDown: *const fn () bool,
    /// Geri basınçta handler'ın kooperatif kısa beklemesi (~1 ms).
    pause: *const fn () void,
};

pub const Config = struct {
    max_body_bytes: usize = 10 * 1024 * 1024,
    max_header_bytes: usize = 64 * 1024,
    /// Aynı anda işlenen istek (handler) üst sınırı; aşılınca yeni istekler 503 alır.
    max_inflight: usize = 1024,
    /// Bildirilen SETTINGS_QPACK_MAX_TABLE_CAPACITY (0: dinamik tablo kapalı).
    qpack_capacity: usize = 4096,
    /// Zarif kapanışta uçuştaki isteklerin bitmesi için en çok bekleme.
    drain_ms: u32 = 5000,
};

fn dbg(comptime fmt: []const u8, args: anytype) void {
    if (std.c.getenv("NOX_QUIC_DEBUG") != null) std.debug.print("h3srv: " ++ fmt ++ "\n", args);
}

const max_frame_header_extra = 16;
const stream_high_water: usize = 256 * 1024;
const data_chunk: usize = 64 * 1024;

// ---- Akış denetimi (handler <-> motor) ---------------------------------------------------------------------------------------------------------------------------------

/// Bir isteğin yanıt tarafı: handler fiber'ı ile motor arasında kilitli köprü. Motor sahibidir; `ReqStream.deinit` serbest bırakır.
pub const StreamCtl = struct {
    gpa: Allocator,
    lock: SpinLock = .{},
    /// Motorun yazacağı kodlanmış çerçeveler.
    out: std.ArrayListUnmanaged(u8) = .empty,
    started: bool = false,
    ended: bool = false,
    /// Motor: akış/bağlantı kapandı; yazmalar başarısız olur.
    closed: bool = false,
    /// `ctlTrailers` ile kaydedilen yanıt trailer'ları (gpa sahipli, `ctlEnd` kodlar).
    resp_trailers: []Header = &.{},
    req_trailers: []const Header = &.{},
    pause: *const fn () void,

    fn deinit(self: *StreamCtl) void {
        self.out.deinit(self.gpa);
        freeHeaders(self.gpa, self.resp_trailers);
    }
};

fn freeHeaders(gpa: Allocator, hs: []Header) void {
    for (hs) |h| {
        gpa.free(h.name);
        gpa.free(h.value);
    }
    if (hs.len > 0) gpa.free(hs);
}

fn isConnectionSpecific(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "connection") or std.ascii.eqlIgnoreCase(name, "keep-alive") or std.ascii.eqlIgnoreCase(name, "proxy-connection") or std.ascii.eqlIgnoreCase(name, "transfer-encoding") or std.ascii.eqlIgnoreCase(name, "upgrade");
}

/// HEADERS çerçevesini (":status" + normalize başlıklar) `out`a ekler. `content_len` doluysa ve başlıklarda yoksa `content-length` eklenir.
fn appendHeadersFrame(gpa: Allocator, out: *std.ArrayListUnmanaged(u8), status: u16, headers: []const Header, content_len: ?usize) Allocator.Error!void {
    var hs: std.ArrayListUnmanaged(Header) = .empty;
    defer hs.deinit(gpa);
    var status_buf: [8]u8 = undefined;
    const status_text = std.fmt.bufPrint(&status_buf, "{d}", .{status}) catch "500";
    if (status != 0) try hs.append(gpa, .{ .name = ":status", .value = status_text });
    var have_len = false;
    var lowered: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (lowered.items) |l| gpa.free(l);
        lowered.deinit(gpa);
    }
    for (headers) |h| {
        if (isConnectionSpecific(h.name)) continue;
        const name = try gpa.dupe(u8, h.name);
        try lowered.append(gpa, name);
        for (name) |*c| c.* = std.ascii.toLower(c.*);
        if (std.mem.eql(u8, name, "content-length")) have_len = true;
        try hs.append(gpa, .{ .name = name, .value = h.value });
    }
    var len_buf: [24]u8 = undefined;
    if (content_len) |n| if (!have_len) {
        const lt = std.fmt.bufPrint(&len_buf, "{d}", .{n}) catch "0";
        try hs.append(gpa, .{ .name = "content-length", .value = lt });
    };
    var block: std.ArrayListUnmanaged(u8) = .empty;
    defer block.deinit(gpa);
    try h3.encodeFieldSection(&block, gpa, hs.items);
    try h3.appendFrame(out, gpa, h3.frame_headers, block.items);
}

/// Akışlı yanıtı başlatır (başlıklar hemen kuyruğa girer). `false`: zaten başlamış/kapanmış ya da geçersiz durum.
pub fn ctlBegin(ctl: *StreamCtl, status: u16, headers: []const Header) bool {
    if (status < 200 or status > 599 or status == 204 or status == 304) return false;
    ctl.lock.lock();
    defer ctl.lock.unlock();
    if (ctl.started or ctl.closed) return false;
    appendHeadersFrame(ctl.gpa, &ctl.out, status, headers, null) catch return false;
    ctl.started = true;
    return true;
}

/// Bir parça yazar. Tampon yüksek su çizgisini aşarsa (yavaş istemci) kooperatif bekler. `false`: akış yok/bitmiş ya da istemci gitti.
pub fn ctlSend(ctl: *StreamCtl, bytes: []const u8) bool {
    var off: usize = 0;
    while (true) {
        ctl.lock.lock();
        if (!ctl.started or ctl.ended or ctl.closed) {
            ctl.lock.unlock();
            return false;
        }
        if (ctl.out.items.len > stream_high_water) {
            ctl.lock.unlock();
            ctl.pause();
            continue;
        }
        if (off >= bytes.len) {
            ctl.lock.unlock();
            return true;
        }
        const n = @min(bytes.len - off, data_chunk);
        const ok = h3.appendFrame(&ctl.out, ctl.gpa, h3.frame_data, bytes[off .. off + n]);
        ctl.lock.unlock();
        ok catch return false;
        off += n;
        if (off >= bytes.len) return true;
    }
}

/// Yanıt trailer'larını kaydeder (`ctlEnd` HEADERS olarak yollar). `false`: akış yok/bitmiş ya da zaten kaydedilmiş.
pub fn ctlTrailers(ctl: *StreamCtl, headers: []const Header) bool {
    ctl.lock.lock();
    defer ctl.lock.unlock();
    if (!ctl.started or ctl.ended or ctl.closed or ctl.resp_trailers.len > 0) return false;
    const copy = ctl.gpa.alloc(Header, headers.len) catch return false;
    var n: usize = 0;
    for (headers) |h| {
        const nm = ctl.gpa.dupe(u8, h.name) catch break;
        const vl = ctl.gpa.dupe(u8, h.value) catch {
            ctl.gpa.free(nm);
            break;
        };
        copy[n] = .{ .name = nm, .value = vl };
        n += 1;
    }
    if (n != headers.len) {
        freeHeaders(ctl.gpa, copy[0..n]);
        ctl.gpa.free(copy);
        return false;
    }
    ctl.resp_trailers = copy;
    return true;
}

/// Akışı bitirir (varsa trailer'larla). Tekrar çağrı zararsızdır.
pub fn ctlEnd(ctl: *StreamCtl) void {
    ctl.lock.lock();
    defer ctl.lock.unlock();
    if (!ctl.started or ctl.ended) return;
    if (ctl.resp_trailers.len > 0) appendHeadersFrame(ctl.gpa, &ctl.out, 0, ctl.resp_trailers, null) catch {};
    ctl.ended = true;
}

pub fn ctlStarted(ctl: *StreamCtl) bool {
    ctl.lock.lock();
    defer ctl.lock.unlock();
    return ctl.started;
}

pub fn ctlOpen(ctl: *StreamCtl) bool {
    ctl.lock.lock();
    defer ctl.lock.unlock();
    return ctl.started and !ctl.ended and !ctl.closed;
}

/// `req.trailer(ad)`: gövdeden sonra gelen istek trailer'ının değerleri (", " ile birleşik) `out`a eklenir.
pub fn ctlRequestTrailer(ctl: *StreamCtl, name: []const u8, out: *std.ArrayListUnmanaged(u8), gpa: Allocator) bool {
    var found = false;
    for (ctl.req_trailers) |t| {
        if (!std.ascii.eqlIgnoreCase(t.name, name)) continue;
        if (found) out.appendSlice(gpa, ", ") catch return found;
        out.appendSlice(gpa, std.mem.trim(u8, t.value, " \t")) catch return found;
        found = true;
    }
    return found;
}

// ---- Motor durumu ------------------------------------------------------------------------------------------------------------------------------------------------------

const ReqStream = struct {
    stream: quic.Stream,
    stream_id: u64,
    inbuf: std.ArrayListUnmanaged(u8) = .empty,
    pos: usize = 0,
    have_headers: bool = false,
    fin: bool = false,
    /// Ayrıştırılmış istek parçaları.
    hdr_list: std.ArrayListUnmanaged(Header) = .empty,
    trailer_list: std.ArrayListUnmanaged(Header) = .empty,
    body: std.ArrayListUnmanaged(u8) = .empty,
    arena: std.heap.ArenaAllocator,
    dispatched: bool = false,
    /// Bu akış için çalışan bir handler işi var (iş kuyruğundan dönene dek akış serbest bırakılmaz).
    job_pending: bool = false,
    ctl: ?*StreamCtl = null,
    out: std.ArrayListUnmanaged(u8) = .empty,
    out_off: usize = 0,
    /// Yanıtın tamamı kuyruğa girdi (arabellekli: kodlandı; akışlı: handler döndü ve `ended`).
    response_complete: bool = false,
    concluded: bool = false,
    done: bool = false,

    fn deinit(self: *ReqStream, gpa: Allocator) void {
        self.stream.deinit();
        self.inbuf.deinit(gpa);
        self.hdr_list.deinit(gpa);
        self.trailer_list.deinit(gpa);
        self.body.deinit(gpa);
        self.out.deinit(gpa);
        self.arena.deinit();
        if (self.ctl) |c| {
            c.deinit();
            gpa.destroy(c);
        }
    }
};

const UniStream = struct {
    stream: quic.Stream,
    /// Akış türü (ilk varint) okundu mu?
    typed: bool = false,
    kind: u64 = 0,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    settings_seen: bool = false,

    fn deinit(self: *UniStream, gpa: Allocator) void {
        self.stream.deinit();
        self.buf.deinit(gpa);
    }
};

const ConnState = struct {
    conn: quic.Conn,
    reqs: std.ArrayListUnmanaged(*ReqStream) = .empty,
    unis: std.ArrayListUnmanaged(*UniStream) = .empty,
    /// Bizim açtığımız tek yönlü akışlar: 0 kontrol, 1 QPACK kodlayıcı, 2 QPACK çözücü.
    ours: [3]?quic.Stream = .{ null, null, null },
    ours_buf: [3]std.ArrayListUnmanaged(u8) = .{ .empty, .empty, .empty },
    ours_off: [3]usize = .{ 0, 0, 0 },
    qdec: h3.QpackDecoder,
    inflight: usize = 0,
    dead: bool = false,
    /// Üç tek yönlü akışımız (kontrol + QPACK) açıldı mı?
    opened: bool = false,
    /// Kabul edilen en büyük istek akış kimliği + 4 (GOAWAY değeri).
    next_req_id: u64 = 0,
    /// GOAWAY gönderildi: bu kimlik ve üstü işlenmez.
    goaway_id: ?u64 = null,

    fn deinit(self: *ConnState, gpa: Allocator) void {
        for (self.reqs.items) |r| {
            r.deinit(gpa);
            gpa.destroy(r);
        }
        self.reqs.deinit(gpa);
        for (self.unis.items) |u| {
            u.deinit(gpa);
            gpa.destroy(u);
        }
        self.unis.deinit(gpa);
        for (&self.ours) |*o| if (o.*) |*st| st.deinit();
        for (&self.ours_buf) |*b| b.deinit(gpa);
        self.qdec.deinit();
        self.conn.deinit();
    }

    fn close(self: *ConnState, code: h3.ErrorCode) void {
        if (self.dead) return;
        self.conn.closeWithError(@intFromEnum(code), "");
        self.dead = true;
    }
};

const Job = struct {
    engine: *Engine,
    cs: *ConnState,
    rs: *ReqStream,
    req: Request,
    resp: Response = .{},
    ok: bool = false,
};

const Engine = struct {
    gpa: Allocator,
    cfg: Config,
    hooks: Hooks,
    listener: *quic.Listener,
    conns: std.ArrayListUnmanaged(*ConnState) = .empty,
    done_lock: SpinLock = .{},
    done: std.ArrayListUnmanaged(*Job) = .empty,
    inflight: std.atomic.Value(usize) = .init(0),
    draining: bool = false,
};

fn statusText(status: u16) []const u8 {
    return switch (status) {
        400 => "Bad Request",
        413 => "Payload Too Large",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        else => "",
    };
}

/// Arabellekli yanıtı (HEADERS + DATA) `rs.out`a kodlar. `head_only`: HEAD isteği, gövde gönderilmez (content-length korunur).
fn encodeResponse(gpa: Allocator, rs: *ReqStream, resp: *const Response, head_only: bool) Allocator.Error!void {
    try appendHeadersFrame(gpa, &rs.out, resp.status, resp.headers, resp.body.len);
    if (resp.body.len > 0 and !head_only) try h3.appendFrame(&rs.out, gpa, h3.frame_data, resp.body);
}

fn queueError(gpa: Allocator, rs: *ReqStream, status: u16) void {
    const resp: Response = .{ .status = status, .body = @constCast(statusText(status)) };
    encodeResponse(gpa, rs, &resp, false) catch {};
    rs.dispatched = true;
    rs.response_complete = true;
}

// ---- İstek ayrıştırma -------------------------------------------------------------------------------------------------------------------------------------------

const ParseResult = enum { need_more, complete, bad_request, too_large, header_too_large, protocol_error, qpack_error };

/// `rs.inbuf`taki tam çerçeveleri tüketir. FIN görüldüyse ve tampon bittiyse `complete` (alanlar `rs.hdr_list`/`rs.body`/`rs.trailer_list`).
fn parseRequest(e: *Engine, cs: *ConnState, rs: *ReqStream) ParseResult {
    const gpa = e.gpa;
    while (rs.pos < rs.inbuf.items.len) {
        const buf = rs.inbuf.items[rs.pos..];
        const fh = h3.parseFrameHeader(buf) orelse return .need_more;
        const total = fh.header_len + fh.len;
        const limit = @max(e.cfg.max_body_bytes, e.cfg.max_header_bytes) + max_frame_header_extra;
        if (fh.len > limit) return if (fh.kind == h3.frame_data) .too_large else .header_too_large;
        if (buf.len < total) return .need_more;
        const payload = buf[fh.header_len..][0..@intCast(fh.len)];
        switch (fh.kind) {
            h3.frame_headers => {
                if (payload.len > e.cfg.max_header_bytes) return .header_too_large;
                const d = cs.qdec.decode(rs.arena.allocator(), payload, e.cfg.max_header_bytes, rs.stream_id) catch |err| switch (err) {
                    error.FieldSectionTooLarge => return .header_too_large,
                    else => return .qpack_error,
                };
                if (!rs.have_headers) {
                    rs.hdr_list.appendSlice(gpa, d.headers) catch return .protocol_error;
                    rs.have_headers = true;
                } else {
                    // Gövdeden sonraki HEADERS = trailer.
                    rs.trailer_list.appendSlice(gpa, d.headers) catch return .protocol_error;
                }
            },
            h3.frame_data => {
                if (!rs.have_headers or rs.trailer_list.items.len > 0) return .protocol_error;
                if (rs.body.items.len + payload.len > e.cfg.max_body_bytes) return .too_large;
                rs.body.appendSlice(gpa, payload) catch return .protocol_error;
            },
            h3.frame_settings, h3.frame_goaway, h3.frame_cancel_push, h3.frame_max_push_id, h3.frame_push_promise => return .protocol_error,
            else => {}, // bilinmeyen/ayrılmış çerçeve: yok say (RFC 9114 §9)
        }
        rs.pos += total;
    }
    if (rs.fin) return if (rs.have_headers) .complete else .bad_request;
    return .need_more;
}

/// Ayrıştırılmış alanlardan `Request` kurar (motor `gpa`sıyla sahipli). `null`: geçersiz istek (400) ya da bellek yok.
fn buildRequest(e: *Engine, rs: *ReqStream, ctl: *StreamCtl) ?Request {
    return buildRequestE(e, rs, ctl) catch null;
}

fn dupeHeaders(gpa: Allocator, src: []const Header) Allocator.Error![]Header {
    var out: std.ArrayListUnmanaged(Header) = .empty;
    errdefer {
        for (out.items) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        out.deinit(gpa);
    }
    for (src) |h| {
        const n = try gpa.dupe(u8, h.name);
        errdefer gpa.free(n);
        const v = try gpa.dupe(u8, h.value);
        errdefer gpa.free(v);
        try out.append(gpa, .{ .name = n, .value = v });
    }
    return out.toOwnedSlice(gpa);
}

fn buildRequestE(e: *Engine, rs: *ReqStream, ctl: *StreamCtl) error{ Invalid, OutOfMemory }!Request {
    const gpa = e.gpa;
    var method: ?[]const u8 = null;
    var scheme: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var authority: ?[]const u8 = null;
    var out: std.ArrayListUnmanaged(Header) = .empty;
    errdefer {
        for (out.items) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        out.deinit(gpa);
    }
    var have_host = false;
    var seen_regular = false;
    for (rs.hdr_list.items) |h| {
        if (h.name.len == 0) return error.Invalid;
        if (h.name[0] == ':') {
            if (seen_regular) return error.Invalid; // sözde başlıklar normal başlıklardan önce olmalı
            if (std.mem.eql(u8, h.name, ":method")) {
                if (method != null) return error.Invalid;
                method = h.value;
            } else if (std.mem.eql(u8, h.name, ":scheme")) {
                scheme = h.value;
            } else if (std.mem.eql(u8, h.name, ":path")) {
                if (path != null) return error.Invalid;
                path = h.value;
            } else if (std.mem.eql(u8, h.name, ":authority")) {
                authority = h.value;
            } else return error.Invalid;
            continue;
        }
        seen_regular = true;
        for (h.name) |c| if (std.ascii.isUpper(c)) return error.Invalid;
        if (isConnectionSpecific(h.name)) return error.Invalid;
        if (std.mem.eql(u8, h.name, "te") and !std.mem.eql(u8, h.value, "trailers")) return error.Invalid;
        if (std.mem.eql(u8, h.name, "host")) have_host = true;
        const n = try gpa.dupe(u8, h.name);
        errdefer gpa.free(n);
        const v = try gpa.dupe(u8, h.value);
        errdefer gpa.free(v);
        try out.append(gpa, .{ .name = n, .value = v });
    }
    const m = method orelse return error.Invalid;
    const p = path orelse return error.Invalid;
    if (scheme == null or p.len == 0) return error.Invalid;
    if (!have_host) if (authority) |a| {
        const n = try gpa.dupe(u8, "host");
        errdefer gpa.free(n);
        const v = try gpa.dupe(u8, a);
        errdefer gpa.free(v);
        try out.append(gpa, .{ .name = n, .value = v });
    };
    const method_c = try gpa.dupe(u8, m);
    errdefer gpa.free(method_c);
    const path_c = try gpa.dupe(u8, p);
    errdefer gpa.free(path_c);
    const auth_c = try gpa.dupe(u8, authority orelse "");
    errdefer gpa.free(auth_c);
    const body_c = try gpa.dupe(u8, rs.body.items);
    errdefer gpa.free(body_c);
    const trailers = try dupeHeaders(gpa, rs.trailer_list.items);
    errdefer freeHeaders(gpa, trailers);
    const headers = try out.toOwnedSlice(gpa);
    ctl.req_trailers = trailers;
    return .{ .method = method_c, .path = path_c, .authority = auth_c, .headers = headers, .body = body_c, .trailers = trailers, .ctl = ctl };
}

fn freeRequest(gpa: Allocator, r: *const Request) void {
    gpa.free(r.method);
    gpa.free(r.path);
    gpa.free(r.authority);
    freeHeaders(gpa, @constCast(r.headers));
    freeHeaders(gpa, @constCast(r.trailers));
    gpa.free(r.body);
}

fn freeResponse(gpa: Allocator, r: *const Response) void {
    freeHeaders(gpa, r.headers);
    if (r.body.len > 0) gpa.free(r.body);
}

// ---- Handler fiber'ı ----------------------------------------------------------------------------------------------------------------------------------------------

fn jobEntry(arg: *anyopaque) void {
    const job: *Job = @ptrCast(@alignCast(arg));
    const e = job.engine;
    var resp: Response = .{};
    job.ok = e.hooks.serve(e.hooks.user, e.gpa, &job.req, &resp);
    job.resp = resp;
    e.done_lock.lock();
    e.done.append(e.gpa, job) catch {
        // Kuyruğa eklenemedi (bellek yok): akışı sonlandır, işi serbest bırak; akış motor tarafından zaman aşımı/bağlantı kapanışıyla temizlenir.
        e.done_lock.unlock();
        freeRequest(e.gpa, &job.req);
        freeResponse(e.gpa, &job.resp);
        e.gpa.destroy(job);
        return;
    };
    e.done_lock.unlock();
}

fn dispatch(e: *Engine, cs: *ConnState, rs: *ReqStream) void {
    rs.dispatched = true;
    if (e.inflight.load(.monotonic) >= e.cfg.max_inflight) return queueError(e.gpa, rs, 503);
    const ctl = e.gpa.create(StreamCtl) catch return queueError(e.gpa, rs, 500);
    ctl.* = .{ .gpa = e.gpa, .pause = e.hooks.pause };
    rs.ctl = ctl;
    const req = buildRequest(e, rs, ctl) orelse return queueError(e.gpa, rs, 400);
    const job = e.gpa.create(Job) catch {
        freeRequest(e.gpa, &req);
        return queueError(e.gpa, rs, 500);
    };
    job.* = .{ .engine = e, .cs = cs, .rs = rs, .req = req };
    if (!e.hooks.spawn(e.hooks.user, jobEntry, job, false)) {
        freeRequest(e.gpa, &job.req);
        e.gpa.destroy(job);
        return queueError(e.gpa, rs, 503);
    }
    cs.inflight += 1;
    rs.job_pending = true;
    _ = e.inflight.fetchAdd(1, .monotonic);
}

// ---- Motor döngüsü -------------------------------------------------------------------------------------------------------------------------------------------------

/// Kontrol (tür 0x00 + SETTINGS) ve QPACK (0x02, 0x03) tek yönlü akışlarını açar ve baştaki baytlarını yazar. El sıkışma/akış kontrolü yüzünden `openStream` ya da yazma hemen
/// başarılı olmayabilir: akışlar açılınca tutulur, bekleyen baytlar sonraki turlarda yazılır. `false`: bağlantı kullanılamaz (yazma hatası).
fn openOurStreams(e: *Engine, cs: *ConnState) bool {
    const types = [3]u64{ h3.stream_control, h3.stream_qpack_encoder, h3.stream_qpack_decoder };
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        if (cs.ours[i] == null) {
            const st = cs.conn.openStream(true) catch return true; // henüz hazır değil: yeniden dene
            h3.appendStreamType(&cs.ours_buf[i], e.gpa, types[i]) catch return false;
            if (i == 0) h3.appendSettings(&cs.ours_buf[i], e.gpa, .{
                .max_field_section_size = e.cfg.max_header_bytes,
                .qpack_max_table_capacity = e.cfg.qpack_capacity,
            }) catch return false;
            cs.ours[i] = st;
        }
        if (!flushOurs(cs, i)) return false;
    }
    return true;
}

/// `ours_buf[i]`deki bekleyen baytları yazar.
fn flushOurs(cs: *ConnState, i: usize) bool {
    if (cs.ours[i] == null) return true;
    if (cs.ours_off[i] < cs.ours_buf[i].items.len) {
        const n = cs.ours[i].?.tryWrite(cs.ours_buf[i].items[cs.ours_off[i]..]) catch return false;
        cs.ours_off[i] += n;
        if (cs.ours_off[i] == cs.ours_buf[i].items.len) {
            cs.ours_buf[i].clearRetainingCapacity();
            cs.ours_off[i] = 0;
        }
    }
    return true;
}

fn ourStreamsReady(cs: *const ConnState) bool {
    for (0..3) |i| {
        if (cs.ours[i] == null) return false;
    }
    return true;
}

fn readChunk(st: *quic.Stream, list: *std.ArrayListUnmanaged(u8), gpa: Allocator, fin: *bool, closed: *bool) bool {
    var progressed = false;
    var tmp: [8192]u8 = undefined;
    while (true) {
        switch (st.tryRead(&tmp)) {
            .data => |n| {
                list.appendSlice(gpa, tmp[0..n]) catch {
                    closed.* = true;
                    return progressed;
                };
                progressed = true;
            },
            .eof => {
                fin.* = true;
                return progressed;
            },
            .timeout => return progressed,
            .closed => {
                closed.* = true;
                return progressed;
            },
        }
    }
}

/// İstemcinin tek yönlü akışını işler. Dönüş: `null` tamam, aksi halde bağlantıyı kapatacak HTTP/3 hata kodu.
fn serviceUni(e: *Engine, cs: *ConnState, u: *UniStream) ?h3.ErrorCode {
    var fin = false;
    var closed = false;
    _ = readChunk(&u.stream, &u.buf, e.gpa, &fin, &closed);
    if (!u.typed) {
        var l: usize = 0;
        const t = h3.readVarint(u.buf.items, &l) orelse return null;
        u.kind = t;
        u.typed = true;
        u.buf.replaceRange(e.gpa, 0, l, &.{}) catch return .internal_error;
    }
    if (u.kind == h3.stream_control) {
        if (fin or closed) return .closed_critical_stream;
        while (true) {
            const fh = h3.parseFrameHeader(u.buf.items) orelse break;
            const total = fh.header_len + fh.len;
            if (fh.len > 64 * 1024) return .excessive_load;
            if (u.buf.items.len < total) break;
            const payload = u.buf.items[fh.header_len..][0..@intCast(fh.len)];
            if (!u.settings_seen) {
                if (fh.kind != h3.frame_settings) return .missing_settings;
                _ = h3.parseSettings(payload) catch return .settings_error;
                u.settings_seen = true;
            } else switch (fh.kind) {
                h3.frame_settings, h3.frame_data, h3.frame_headers => return .frame_unexpected,
                else => {},
            }
            u.buf.replaceRange(e.gpa, 0, total, &.{}) catch return .internal_error;
        }
    } else if (u.kind == h3.stream_qpack_encoder) {
        if (closed) return .closed_critical_stream;
        if (u.buf.items.len > 0) {
            cs.qdec.processEncoderBytes(u.buf.items) catch |err| switch (err) {
                error.QpackEncoderStreamError => return .qpack_encoder_stream_error,
                error.OutOfMemory => return .internal_error,
            };
            u.buf.clearRetainingCapacity();
        }
    } else if (u.kind == h3.stream_qpack_decoder) {
        // Kodlayıcımız dinamik tablo kullanmadığından karşı tarafın çözücü akışı anlamlı bir şey taşımaz; yok say.
        u.buf.clearRetainingCapacity();
        if (closed) return .closed_critical_stream;
    } else {
        u.buf.clearRetainingCapacity(); // bilinmeyen akış türü: veriyi at
    }
    return null;
}

/// Akış başına yanıt yazma/tamamlama. Dönüş: `null` tamam, aksi halde bağlantıyı kapatacak hata kodu.
fn serviceReq(e: *Engine, cs: *ConnState, rs: *ReqStream) ?h3.ErrorCode {
    if (!rs.dispatched) {
        var closed = false;
        _ = readChunk(&rs.stream, &rs.inbuf, e.gpa, &rs.fin, &closed);
        if (closed) {
            rs.done = true;
            return null;
        }
        if (cs.goaway_id) |g| if (rs.stream_id >= g) {
            // GOAWAY sonrası gelen istek işlenmez (RFC 9114 §5.2): akışı bırak.
            rs.done = true;
            return null;
        };
        const pr = parseRequest(e, cs, rs);
        if (pr != .need_more) dbg("parse -> {s} inbuf={d}", .{ @tagName(pr), rs.inbuf.items.len });
        switch (pr) {
            .need_more => {},
            .complete => dispatch(e, cs, rs),
            .bad_request => queueError(e.gpa, rs, 400),
            .too_large => queueError(e.gpa, rs, 413),
            .header_too_large => queueError(e.gpa, rs, 431),
            .protocol_error => return .general_protocol_error,
            .qpack_error => return .qpack_decompression_failed,
        }
    }
    // Akışlı yanıt: handler'ın kuyruğa eklediği çerçeveleri motorun yazma tamponuna al.
    if (rs.ctl) |ctl| if (rs.out_off >= rs.out.items.len) {
        ctl.lock.lock();
        if (ctl.out.items.len > 0) {
            rs.out.clearRetainingCapacity();
            rs.out_off = 0;
            std.mem.swap(std.ArrayListUnmanaged(u8), &rs.out, &ctl.out);
        }
        ctl.lock.unlock();
    };
    if (rs.out.items.len > rs.out_off) {
        const n = rs.stream.tryWrite(rs.out.items[rs.out_off..]) catch {
            if (rs.ctl) |ctl| {
                ctl.lock.lock();
                ctl.closed = true;
                ctl.lock.unlock();
            }
            rs.done = true;
            return null;
        };
        rs.out_off += n;
    }
    if (rs.response_complete and !rs.concluded and rs.out_off >= rs.out.items.len) {
        var ctl_empty = true;
        if (rs.ctl) |ctl| {
            ctl.lock.lock();
            ctl_empty = ctl.out.items.len == 0;
            ctl.lock.unlock();
        }
        if (ctl_empty) {
            rs.stream.conclude();
            rs.concluded = true;
            rs.done = true;
        }
    }
    return null;
}

fn drainDone(e: *Engine) void {
    e.done_lock.lock();
    const jobs = e.done.toOwnedSlice(e.gpa) catch {
        e.done_lock.unlock();
        return;
    };
    e.done_lock.unlock();
    defer e.gpa.free(jobs);
    for (jobs) |job| {
        job.cs.inflight -= 1;
        job.rs.job_pending = false;
        _ = e.inflight.fetchSub(1, .monotonic);
        const rs = job.rs;
        const ctl = rs.ctl.?;
        if (job.resp.streamed or ctlStarted(ctl)) {
            // Akışlı yanıt: handler döndü; akışı bitir (zaten bitmediyse) ve kalan çerçeveleri yazdır.
            ctlEnd(ctl);
            rs.response_complete = true;
        } else if (!job.ok or job.resp.status < 100) {
            queueErrorReplace(e, rs, 500);
        } else {
            const head = std.ascii.eqlIgnoreCase(job.req.method, "HEAD");
            encodeResponse(e.gpa, rs, &job.resp, head) catch queueErrorReplace(e, rs, 500);
            rs.response_complete = true;
        }
        freeRequest(e.gpa, &job.req);
        freeResponse(e.gpa, &job.resp);
        e.gpa.destroy(job);
    }
}

fn queueErrorReplace(e: *Engine, rs: *ReqStream, status: u16) void {
    rs.out.clearRetainingCapacity();
    rs.out_off = 0;
    queueError(e.gpa, rs, status);
}

fn serviceConn(e: *Engine, cs: *ConnState) void {
    if (cs.dead) return;
    cs.conn.handleEvents();
    if (cs.conn.isClosed()) {
        dbg("conn closed (peer/idle)", .{});
        cs.dead = true;
        return;
    }
    if (!cs.opened) {
        if (!openOurStreams(e, cs)) {
            dbg("openOurStreams failed", .{});
            cs.dead = true;
            return;
        }
        cs.opened = ourStreamsReady(cs) and cs.ours_buf[0].items.len == 0;
        if (cs.opened) dbg("our uni streams opened", .{});
    }
    // Yeni akışlar.
    while (cs.conn.tryAcceptStream()) |st| {
        dbg("stream accepted kind={s}", .{@tagName(st.kind())});
        switch (st.kind()) {
            .bidi => {
                const rs = e.gpa.create(ReqStream) catch break;
                const sid = st.id();
                rs.* = .{ .stream = st, .stream_id = sid, .arena = std.heap.ArenaAllocator.init(e.gpa) };
                if (sid + 4 > cs.next_req_id) cs.next_req_id = sid + 4;
                cs.reqs.append(e.gpa, rs) catch {
                    rs.deinit(e.gpa);
                    e.gpa.destroy(rs);
                    break;
                };
            },
            .uni_read => {
                const u = e.gpa.create(UniStream) catch break;
                u.* = .{ .stream = st };
                cs.unis.append(e.gpa, u) catch {
                    u.deinit(e.gpa);
                    e.gpa.destroy(u);
                    break;
                };
            },
            else => {
                var s2 = st;
                s2.deinit();
            },
        }
    }
    var i: usize = 0;
    while (i < cs.unis.items.len) {
        if (serviceUni(e, cs, cs.unis.items[i])) |code| {
            dbg("closing connection: {s}", .{@tagName(code)});
            cs.close(code);
            return;
        }
        i += 1;
    }
    // QPACK çözücü akışı (Section Acknowledgment / Insert Count Increment) ve bekleyen kontrol baytları.
    if (cs.qdec.out.items.len > 0 and cs.ours[2] != null) {
        cs.ours_buf[2].appendSlice(e.gpa, cs.qdec.out.items) catch {};
        cs.qdec.out.clearRetainingCapacity();
    }
    for (0..3) |k| if (!flushOurs(cs, k)) {
        cs.dead = true;
        return;
    };
    i = 0;
    while (i < cs.reqs.items.len) {
        const rs = cs.reqs.items[i];
        if (serviceReq(e, cs, rs)) |code| {
            dbg("closing connection: {s}", .{@tagName(code)});
            cs.close(code);
            return;
        }
        if (rs.done and !rs.job_pending) {
            rs.deinit(e.gpa);
            e.gpa.destroy(rs);
            _ = cs.reqs.swapRemove(i);
            continue;
        }
        i += 1;
    }
}

/// Bağlantıların kapanma durumunu `StreamCtl`e yansıtır: ölü bağlantıdaki akışlı yanıtlar hata alsın.
fn markDeadCtls(cs: *ConnState) void {
    for (cs.reqs.items) |rs| if (rs.ctl) |ctl| {
        ctl.lock.lock();
        ctl.closed = true;
        ctl.lock.unlock();
    };
}

fn sendGoaway(e: *Engine, cs: *ConnState) void {
    if (cs.goaway_id != null or cs.dead) return;
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(e.gpa);
    h3.appendVarint(&payload, e.gpa, cs.next_req_id) catch return;
    h3.appendFrame(&cs.ours_buf[0], e.gpa, h3.frame_goaway, payload.items) catch return;
    cs.goaway_id = cs.next_req_id;
}

fn allQuiet(e: *Engine) bool {
    if (e.inflight.load(.acquire) > 0) return false;
    for (e.conns.items) |cs| {
        if (cs.dead) continue;
        for (cs.reqs.items) |rs| {
            if (rs.dispatched and !rs.done) return false;
        }
    }
    return true;
}

/// Motoru çalıştırır; `hooks.shuttingDown()` ya da `stop` true olunca GOAWAY gönderir, uçuştaki istekleri bitirir (en çok `drain_ms`), bağlantıları H3_NO_ERROR ile kapatıp döner.
pub fn run(gpa: Allocator, listener: *quic.Listener, cfg: Config, hooks: Hooks, stop: *std.atomic.Value(bool)) void {
    var e: Engine = .{ .gpa = gpa, .cfg = cfg, .hooks = hooks, .listener = listener };
    defer {
        e.done.deinit(gpa);
        e.conns.deinit(gpa);
    }
    while (!stop.load(.acquire) and !hooks.shuttingDown()) loopOnce(&e);

    // Zarif kapanış: GOAWAY, uçuştaki istekleri bitir.
    e.draining = true;
    for (e.conns.items) |cs| sendGoaway(&e, cs);
    // GOAWAY'ın kontrol akışına yazılması ve yolda iken biten isteklerin yanıtlarının çıkması için en az birkaç tur.
    var flush_rounds: usize = 0;
    while (flush_rounds < 4) : (flush_rounds += 1) loopOnce(&e);
    var waited_ms: u32 = 0;
    while (!allQuiet(&e) and waited_ms < cfg.drain_ms) : (waited_ms += 2) loopOnce(&e);
    // Handler fiber'ları `e`yi (bu yığın çerçevesini) kullanır: hepsi dönene dek kuyruğu boşaltarak bekle.
    for (e.conns.items) |cs| markDeadCtls(cs);
    while (e.inflight.load(.acquire) > 0) {
        drainDone(&e);
        listener.pumpOnce(2);
    }
    drainDone(&e);
    for (e.conns.items) |cs| {
        cs.close(.no_error);
    }
    // CONNECTION_CLOSE'un çıkması için motoru kısa süre döndür.
    var k: usize = 0;
    while (k < 5) : (k += 1) listener.pumpOnce(5);
    for (e.conns.items) |c| {
        c.deinit(gpa);
        gpa.destroy(c);
    }
}

fn loopOnce(e: *Engine) void {
    const gpa = e.gpa;
    const listener = e.listener;
    while (listener.tryAccept()) |c| {
        dbg("conn accepted", .{});
        const cs = gpa.create(ConnState) catch break;
        cs.* = .{ .conn = c, .qdec = h3.QpackDecoder.init(gpa, e.cfg.qpack_capacity) };
        if (e.draining) {
            cs.close(.no_error);
        }
        e.conns.append(gpa, cs) catch {
            cs.deinit(gpa);
            gpa.destroy(cs);
        };
    }
    drainDone(e);
    var any_out = false;
    var i: usize = 0;
    while (i < e.conns.items.len) {
        const cs = e.conns.items[i];
        serviceConn(e, cs);
        if (cs.dead) markDeadCtls(cs);
        if (cs.dead and cs.inflight == 0) {
            cs.deinit(gpa);
            gpa.destroy(cs);
            _ = e.conns.swapRemove(i);
            continue;
        }
        for (cs.reqs.items) |rs| {
            if (rs.out.items.len > rs.out_off) any_out = true;
            if (rs.ctl) |ctl| if (!rs.done) {
                ctl.lock.lock();
                if (ctl.out.items.len > 0) any_out = true;
                ctl.lock.unlock();
            };
        }
        i += 1;
    }
    const busy = e.inflight.load(.monotonic) > 0 or any_out;
    listener.pumpOnce(if (busy) 1 else if (e.draining) 5 else 100);
}

// ---- Birim testleri -------------------------------------------------------------------------------------------------------------------------------------------------

const testing = std.testing;
const test_cert: [:0]const u8 = "runtime/stdlib_shims/testdata/quic_test_cert.pem";
const test_key: [:0]const u8 = "runtime/stdlib_shims/testdata/quic_test_key.pem";

const TestHooks = struct {
    shutting: std.atomic.Value(bool) = .init(false),
    served: std.atomic.Value(usize) = .init(0),
    threads: [16]?std.Thread = @splat(null),
    nthreads: usize = 0,

    fn serve(user: *anyopaque, gpa: Allocator, req: *const Request, out: *Response) bool {
        const self: *TestHooks = @ptrCast(@alignCast(user));
        _ = self.served.fetchAdd(1, .monotonic);
        if (std.mem.eql(u8, req.path, "/stream")) {
            // Akışlı yanıt: 3 küçük parça + 600 KiB (geri basıncı egzersiz eder) + trailer.
            if (!ctlBegin(req.ctl, 200, &.{.{ .name = "X-Stream", .value = "yes" }})) return false;
            if (!ctlSend(req.ctl, "part-1;")) return false;
            if (!ctlSend(req.ctl, "part-2;")) return false;
            const big = gpa.alloc(u8, 600 * 1024) catch return false;
            defer gpa.free(big);
            @memset(big, 'z');
            if (!ctlSend(req.ctl, big)) return false;
            if (!ctlTrailers(req.ctl, &.{.{ .name = "X-Trailer", .value = "tr-value" }})) return false;
            ctlEnd(req.ctl);
            out.streamed = true;
            return true;
        }
        var text: []u8 = undefined;
        if (std.mem.eql(u8, req.path, "/rt")) {
            var tmp: std.ArrayListUnmanaged(u8) = .empty;
            defer tmp.deinit(gpa);
            _ = ctlRequestTrailer(req.ctl, "x-rt", &tmp, gpa);
            text = std.fmt.allocPrint(gpa, "rt={s} body={s}", .{ tmp.items, req.body }) catch return false;
        } else if (std.mem.eql(u8, req.path, "/dyn")) {
            var dv: []const u8 = "";
            for (req.headers) |h| if (std.mem.eql(u8, h.name, "x-dyn")) {
                dv = h.value;
            };
            text = std.fmt.allocPrint(gpa, "dyn={s}", .{dv}) catch return false;
        } else {
            text = std.fmt.allocPrint(gpa, "{s} {s} len={d} host={s}", .{ req.method, req.path, req.body.len, req.authority }) catch return false;
        }
        const hs = gpa.alloc(Header, 1) catch return false;
        hs[0] = .{ .name = gpa.dupe(u8, "X-Test") catch return false, .value = gpa.dupe(u8, "ok") catch return false };
        out.* = .{ .status = 200, .headers = hs, .body = text };
        return true;
    }
    fn spawn(user: *anyopaque, entry: *const fn (*anyopaque) void, arg: *anyopaque, pinned: bool) bool {
        _ = pinned;
        const self: *TestHooks = @ptrCast(@alignCast(user));
        if (self.nthreads >= self.threads.len) return false;
        self.threads[self.nthreads] = std.Thread.spawn(.{}, struct {
            fn go(f: *const fn (*anyopaque) void, a: *anyopaque) void {
                f(a);
            }
        }.go, .{ entry, arg }) catch return false;
        self.nthreads += 1;
        return true;
    }
    fn shuttingDown() bool {
        return false;
    }
    fn pause() void {
        std.Thread.yield() catch {};
    }
};

const TestEngine = struct {
    listener: *quic.Listener,
    hooks: *TestHooks,
    stop: std.atomic.Value(bool) = .init(false),
    fn go(self: *TestEngine) void {
        run(testing.allocator, self.listener, .{ .max_body_bytes = 1024 }, .{
            .user = self.hooks,
            .serve = TestHooks.serve,
            .spawn = TestHooks.spawn,
            .shuttingDown = TestHooks.shuttingDown,
            .pause = TestHooks.pause,
        }, &self.stop);
    }
};

const TestReply = struct { status: []const u8, xtest: []const u8, body: []const u8, trailer: []const u8 = "", has_len: bool = false };

/// Test istemcisi: bir istek gönderir. `extra`: gövdeden sonra gönderilecek istek trailer'ları. `prebuilt`: hazır alan bloğu (boşsa sözde başlıklardan kurulur).
pub fn testRequestFull(arena: Allocator, conn: *quic.Conn, method: []const u8, path: []const u8, body: []const u8, trailers: []const Header, prebuilt: ?[]const u8) !TestReply {
    var st = try conn.openStream(false);
    defer st.deinit();
    var req: std.ArrayListUnmanaged(u8) = .empty;
    var block: std.ArrayListUnmanaged(u8) = .empty;
    if (prebuilt) |pb| {
        try block.appendSlice(arena, pb);
    } else {
        try h3.encodeFieldSection(&block, arena, &.{
            .{ .name = ":method", .value = method },
            .{ .name = ":scheme", .value = "https" },
            .{ .name = ":authority", .value = "localhost" },
            .{ .name = ":path", .value = path },
        });
    }
    try h3.appendFrame(&req, arena, h3.frame_headers, block.items);
    if (body.len > 0) try h3.appendFrame(&req, arena, h3.frame_data, body);
    if (trailers.len > 0) {
        var tb: std.ArrayListUnmanaged(u8) = .empty;
        try h3.encodeFieldSection(&tb, arena, trailers);
        try h3.appendFrame(&req, arena, h3.frame_headers, tb.items);
    }
    try st.writeAll(req.items, 5000);
    st.conclude();
    var resp: std.ArrayListUnmanaged(u8) = .empty;
    var buf: [16384]u8 = undefined;
    while (true) {
        switch (st.read(&buf, 15_000)) {
            .data => |n| try resp.appendSlice(arena, buf[0..n]),
            .eof => break,
            else => return error.TestUnexpectedResult,
        }
    }
    var pos: usize = 0;
    var r: TestReply = .{ .status = "", .xtest = "", .body = "" };
    var rbody: std.ArrayListUnmanaged(u8) = .empty;
    var seen_headers = false;
    while (pos < resp.items.len) {
        const fh = h3.parseFrameHeader(resp.items[pos..]) orelse return error.TestUnexpectedResult;
        const payload = resp.items[pos + fh.header_len ..][0..@intCast(fh.len)];
        if (fh.kind == h3.frame_headers) {
            const d = try h3.decodeFieldSection(arena, payload, 1 << 20);
            for (d.headers) |h| {
                if (!seen_headers) {
                    if (std.mem.eql(u8, h.name, ":status")) r.status = h.value;
                    if (std.mem.eql(u8, h.name, "x-test")) r.xtest = h.value;
                    if (std.mem.eql(u8, h.name, "content-length")) r.has_len = true;
                } else if (std.mem.eql(u8, h.name, "x-trailer")) r.trailer = h.value;
            }
            seen_headers = true;
        } else if (fh.kind == h3.frame_data) {
            try rbody.appendSlice(arena, payload);
        }
        pos += fh.header_len + fh.len;
    }
    r.body = rbody.items;
    return r;
}

/// Test istemcisi (`http_server.zig` testleri de kullanır): yalın istek.
pub fn testRequest(arena: Allocator, conn: *quic.Conn, method: []const u8, path: []const u8, body: []const u8) !struct { status: []const u8, xtest: []const u8, body: []const u8 } {
    const r = try testRequestFull(arena, conn, method, path, body, &.{}, null);
    return .{ .status = r.status, .xtest = r.xtest, .body = r.body };
}

const TestRig = struct {
    sctx: quic.Ctx,
    cctx: quic.Ctx,
    l: quic.Listener,
    hooks: TestHooks = .{},
    eng: TestEngine = undefined,
    thread: std.Thread = undefined,

    fn start(self: *TestRig) !void {
        self.hooks = .{};
        self.sctx = try quic.newServerCtx(test_cert, test_key);
        errdefer self.sctx.deinit();
        self.cctx = try quic.newClientCtx(test_cert, true);
        errdefer self.cctx.deinit();
        self.l = try quic.Listener.open(&self.sctx, .{ .v4 = .{ 127, 0, 0, 1 } }, 0);
        self.eng = .{ .listener = &self.l, .hooks = &self.hooks };
        self.thread = try std.Thread.spawn(.{}, TestEngine.go, .{&self.eng});
    }
    fn connect(self: *TestRig) !quic.Conn {
        return quic.Conn.connect(&self.cctx, .{ .v4 = .{ 127, 0, 0, 1 } }, self.l.port, "localhost", 10_000);
    }
    fn finish(self: *TestRig) void {
        self.eng.stop.store(true, .release);
        self.thread.join();
        for (self.hooks.threads[0..self.hooks.nthreads]) |th| th.?.join();
        self.l.deinit();
        self.cctx.deinit();
        self.sctx.deinit();
    }
};

test "h3_server: GET/POST gidiş-dönüşü, 413, HEAD ve çoklanmış istekler (yerel QUIC istemcisiyle)" {
    if (!quic.supported) return error.SkipZigTest;
    if (!quic.available()) return error.SkipZigTest;
    var rig: TestRig = undefined;
    try rig.start();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    {
        var conn = try rig.connect();
        defer conn.deinit();
        const r1 = try testRequest(a, &conn, "GET", "/hello?x=1", "");
        try testing.expectEqualStrings("200", r1.status);
        try testing.expectEqualStrings("ok", r1.xtest);
        try testing.expectEqualStrings("GET /hello?x=1 len=0 host=localhost", r1.body);
        const r2 = try testRequest(a, &conn, "POST", "/p", "merhaba");
        try testing.expectEqualStrings("200", r2.status);
        try testing.expectEqualStrings("POST /p len=7 host=localhost", r2.body);
        const big = try a.alloc(u8, 2000);
        @memset(big, 'x');
        const r3 = try testRequest(a, &conn, "POST", "/big", big);
        try testing.expectEqualStrings("413", r3.status);
        // HEAD: content-length var, gövde yok.
        const r4 = try testRequestFull(a, &conn, "HEAD", "/h", "", &.{}, null);
        try testing.expectEqualStrings("200", r4.status);
        try testing.expect(r4.has_len);
        try testing.expectEqual(@as(usize, 0), r4.body.len);
    }
    rig.finish();
    try testing.expectEqual(@as(usize, 3), rig.hooks.served.load(.monotonic));
}

test "h3_server: akışlı yanıt (geri basınç dahil) + yanıt trailer'ı ve istek trailer'ı" {
    if (!quic.supported) return error.SkipZigTest;
    if (!quic.available()) return error.SkipZigTest;
    var rig: TestRig = undefined;
    try rig.start();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    {
        var conn = try rig.connect();
        defer conn.deinit();
        const r = try testRequestFull(a, &conn, "GET", "/stream", "", &.{}, null);
        try testing.expectEqualStrings("200", r.status);
        try testing.expectEqual(@as(usize, 7 + 7 + 600 * 1024), r.body.len);
        try testing.expect(std.mem.startsWith(u8, r.body, "part-1;part-2;zzz"));
        try testing.expectEqualStrings("tr-value", r.trailer);
        try testing.expect(!r.has_len); // akışlı yanıtta content-length yok
        // İstek trailer'ı: gövde + trailer'ları handler görür.
        const r2 = try testRequestFull(a, &conn, "POST", "/rt", "abc", &.{.{ .name = "x-rt", .value = "tv" }}, null);
        try testing.expectEqualStrings("rt=tv body=abc", r2.body);
    }
    rig.finish();
}

/// Sunucunun açtığı tek yönlü akışları (kontrol, QPACK kodlayıcı/çözücü) bulur; `want` türündeki akışı döner.
fn findServerUni(conn: *quic.Conn, want: u64, buf: []u8, len_out: *usize) !quic.Stream {
    var deadline: usize = 0;
    while (deadline < 400) : (deadline += 1) {
        if (conn.acceptStream(50)) |st0| {
            var st = st0;
            var tmp: [64]u8 = undefined;
            switch (st.read(&tmp, 2000)) {
                .data => |n| {
                    var l: usize = 0;
                    const t = h3.readVarint(tmp[0..n], &l) orelse return error.TestUnexpectedResult;
                    if (t == want) {
                        @memcpy(buf[0 .. n - l], tmp[l..n]);
                        len_out.* = n - l;
                        return st;
                    }
                    st.deinit();
                },
                else => st.deinit(),
            }
        }
    }
    return error.TestUnexpectedResult;
}

test "h3_server: QPACK dinamik tablo — istemci kodlayıcı akışıyla ekleme yapar, onaydan sonra atıf eder" {
    if (!quic.supported) return error.SkipZigTest;
    if (!quic.available()) return error.SkipZigTest;
    var rig: TestRig = undefined;
    try rig.start();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    {
        var conn = try rig.connect();
        defer conn.deinit();
        // Kodlayıcı akışı: tür 0x02, kapasite 100, "x-dyn"="dv" (literal ad).
        var enc = try conn.openStream(true);
        defer enc.deinit();
        try enc.writeAll(&.{ 0x02, 0x20 | 0x1f, 0x45, 0x45, 'x', '-', 'd', 'y', 'n', 0x02, 'd', 'v' }, 5000);
        // 0x20|0x1f + 0x45 -> kapasite 31+69=100; 0x45 = literal ad (01, H=0, len 5); değer len 2.
        var dec_buf: [64]u8 = undefined;
        var dec_len: usize = 0;
        var dec_stream = try findServerUni(&conn, h3.stream_qpack_decoder, &dec_buf, &dec_len);
        defer dec_stream.deinit();
        // Insert Count Increment(1) = 0x01 gelene dek bekle.
        var got: [8]u8 = undefined;
        var got_len: usize = dec_len;
        @memcpy(got[0..dec_len], dec_buf[0..dec_len]);
        var tries: usize = 0;
        while (got_len == 0 and tries < 100) : (tries += 1) {
            switch (dec_stream.read(got[got_len..], 100)) {
                .data => |n| got_len += n,
                else => {},
            }
        }
        try testing.expect(got_len >= 1);
        try testing.expectEqual(@as(u8, 0x01), got[0]);
        // İstek bloğu: RIC=1 (kodlanmış 2), taban=1 (delta 0); statik satırlar + dinamik göreli 0 (0x80).
        var base_block: std.ArrayListUnmanaged(u8) = .empty;
        try h3.encodeFieldSection(&base_block, a, &.{
            .{ .name = ":method", .value = "GET" },
            .{ .name = ":scheme", .value = "https" },
            .{ .name = ":authority", .value = "localhost" },
            .{ .name = ":path", .value = "/dyn" },
        });
        base_block.items[0] = 0x02;
        base_block.items[1] = 0x00;
        try base_block.append(a, 0x80);
        const r = try testRequestFull(a, &conn, "GET", "/dyn", "", &.{}, base_block.items);
        try testing.expectEqualStrings("200", r.status);
        try testing.expectEqualStrings("dyn=dv", r.body);
        // Section Acknowledgment (akış kimliği) çözücü akışına yazılır: 0x80 | id.
        var ack: [8]u8 = undefined;
        var ack_len: usize = 0;
        tries = 0;
        while (ack_len == 0 and tries < 100) : (tries += 1) {
            switch (dec_stream.read(&ack, 100)) {
                .data => |n| ack_len = n,
                else => {},
            }
        }
        try testing.expect(ack_len >= 1);
        try testing.expect(ack[0] & 0x80 != 0);
    }
    rig.finish();
}

test "h3_server: protokol ihlalinde bağlantı hata koduyla kapanır; kapanışta GOAWAY gönderilir" {
    if (!quic.supported) return error.SkipZigTest;
    if (!quic.available()) return error.SkipZigTest;
    var rig: TestRig = undefined;
    try rig.start();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    {
        // (1) SETTINGS yerine DATA ile başlayan kontrol akışı -> H3_MISSING_SETTINGS ile kapanır.
        var bad = try rig.connect();
        defer bad.deinit();
        var ctl = try bad.openStream(true);
        defer ctl.deinit();
        var bytes: std.ArrayListUnmanaged(u8) = .empty;
        try h3.appendStreamType(&bytes, a, h3.stream_control);
        try h3.appendFrame(&bytes, a, h3.frame_data, "x");
        try ctl.writeAll(bytes.items, 5000);
        var closed = false;
        var i: usize = 0;
        while (i < 100 and !closed) : (i += 1) {
            _ = bad.acceptStream(50);
            closed = bad.isClosed();
        }
        try testing.expect(closed);
    }
    {
        // (2) Normal bağlantı: sunucu durdurulunca kontrol akışında GOAWAY görülür.
        var conn = try rig.connect();
        defer conn.deinit();
        const r = try testRequest(a, &conn, "GET", "/x", "");
        try testing.expectEqualStrings("200", r.status);
        var cbuf: [128]u8 = undefined;
        var clen: usize = 0;
        var ctl = try findServerUni(&conn, h3.stream_control, &cbuf, &clen);
        defer ctl.deinit();
        rig.eng.stop.store(true, .release);
        var all: std.ArrayListUnmanaged(u8) = .empty;
        try all.appendSlice(a, cbuf[0..clen]);
        var i: usize = 0;
        var saw_goaway = false;
        while (i < 100 and !saw_goaway) : (i += 1) {
            var tmp: [64]u8 = undefined;
            switch (ctl.read(&tmp, 100)) {
                .data => |n| try all.appendSlice(a, tmp[0..n]),
                else => {},
            }
            var pos: usize = 0;
            while (h3.parseFrameHeader(all.items[pos..])) |fh| {
                if (all.items.len - pos < fh.header_len + fh.len) break;
                if (fh.kind == h3.frame_goaway) saw_goaway = true;
                pos += fh.header_len + fh.len;
            }
        }
        try testing.expect(saw_goaway);
    }
    rig.finish();
}
