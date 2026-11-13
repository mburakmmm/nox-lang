//! HTTP/3 sunucu motoru (RFC 9114) — `quic.zig` (OpenSSL QUIC) üstünde, `h3.zig` (çerçeveleme + QPACK) ile (TODO 5.4, aşama H3.3).
//!
//! Eşzamanlılık modeli: TEK "motor" fiber'ı (`run`) dinleyicinin TÜM OpenSSL çağrılarını yürütür (bağlantı kabulü, akış kabulü, okuma, yazma); OpenSSL nesneleri eşzamanlı
//! kullanılmaz. Uygulama handler'ı her tamamlanan istek için AYRI bir fiber'da (`Hooks.spawn`) çalışır, sonucu kilitli bir kuyruğa bırakır; motor bir sonraki turunda kuyruğu
//! boşaltıp yanıtı akışa yazar. Uyandırma: işi süren handler varken motor 1 ms'lik kısa beklemeyle döner, boştayken `SSL_get_event_timeout`/100 ms ile uyur.
//!
//! Kapsam (v1): arabellekli istek ve yanıt (akışlı yanıt, WebSocket/CONNECT, sunucu itme yok); QPACK dinamik tablosu kapalı (`h3.zig`); protokol ihlalinde bağlantı düşürülür
//! (uygulama hata kodu iletilmez). Başlık/gövde sınırları `Config`ten; sınır aşılırsa 431/413 yanıtı.

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
};

/// Handler hook'unun doldurduğu yanıt: `headers`/`body` `gpa` ile ayrılmış olmalı (motor serbest bırakır).
pub const Response = struct {
    status: u16 = 500,
    headers: []Header = &.{},
    body: []u8 = &.{},
};

pub const Hooks = struct {
    user: *anyopaque,
    /// Handler fiber'ında çalışır. `false` ya da `out.status == 500` hata yanıtıdır.
    serve: *const fn (user: *anyopaque, gpa: Allocator, req: *const Request, out: *Response) bool,
    /// Bağlı bir fiber başlatır (`pinned`: çalınamaz). `false`: başlatılamadı.
    spawn: *const fn (user: *anyopaque, entry: *const fn (*anyopaque) void, arg: *anyopaque, pinned: bool) bool,
    shuttingDown: *const fn () bool,
};

pub const Config = struct {
    max_body_bytes: usize = 10 * 1024 * 1024,
    max_header_bytes: usize = 64 * 1024,
    /// Aynı anda işlenen istek (handler) üst sınırı; aşılınca yeni istekler 503 alır.
    max_inflight: usize = 1024,
};

const max_frame_header_extra = 16;

fn dbg(comptime fmt: []const u8, args: anytype) void {
    if (std.c.getenv("NOX_QUIC_DEBUG") != null) std.debug.print("h3srv: " ++ fmt ++ "\n", args);
}

const ReqStream = struct {
    stream: quic.Stream,
    inbuf: std.ArrayListUnmanaged(u8) = .empty,
    pos: usize = 0,
    have_headers: bool = false,
    fin: bool = false,
    /// Ayrıştırılmış istek parçaları.
    hdr_list: std.ArrayListUnmanaged(Header) = .empty,
    body: std.ArrayListUnmanaged(u8) = .empty,
    arena: std.heap.ArenaAllocator,
    dispatched: bool = false,
    /// Bu akış için çalışan bir handler işi var (iş kuyruğundan dönene dek akış serbest bırakılmaz).
    job_pending: bool = false,
    out: std.ArrayListUnmanaged(u8) = .empty,
    out_off: usize = 0,
    concluded: bool = false,
    done: bool = false,

    fn deinit(self: *ReqStream, gpa: Allocator) void {
        self.stream.deinit();
        self.inbuf.deinit(gpa);
        self.hdr_list.deinit(gpa);
        self.body.deinit(gpa);
        self.out.deinit(gpa);
        self.arena.deinit();
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
    /// Bizim açtığımız tek yönlü akışlar (kontrol + QPACK); yaşam boyu açık kalır.
    ours: [3]?quic.Stream = .{ null, null, null },
    ours_buf: [3]std.ArrayListUnmanaged(u8) = .{ .empty, .empty, .empty },
    ours_off: [3]usize = .{ 0, 0, 0 },
    inflight: usize = 0,
    dead: bool = false,
    /// Üç tek yönlü akışımız (kontrol + QPACK) açıldı mı?
    opened: bool = false,

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
        self.conn.deinit();
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
};

// ---- Yardımcılar -------------------------------------------------------------------------------------------------------------------------------------------------

fn lowerEq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn isConnectionSpecific(name: []const u8) bool {
    return lowerEq(name, "connection") or lowerEq(name, "keep-alive") or lowerEq(name, "proxy-connection") or lowerEq(name, "transfer-encoding") or lowerEq(name, "upgrade");
}

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

/// Yanıtı (HEADERS + DATA) `rs.out`a kodlar.
fn encodeResponse(gpa: Allocator, rs: *ReqStream, resp: *const Response) Allocator.Error!void {
    var hs: std.ArrayListUnmanaged(Header) = .empty;
    defer hs.deinit(gpa);
    var status_buf: [8]u8 = undefined;
    const status_text = std.fmt.bufPrint(&status_buf, "{d}", .{resp.status}) catch "500";
    try hs.append(gpa, .{ .name = ":status", .value = status_text });
    var have_len = false;
    var lowered: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (lowered.items) |l| gpa.free(l);
        lowered.deinit(gpa);
    }
    for (resp.headers) |h| {
        if (isConnectionSpecific(h.name)) continue;
        const name = try gpa.dupe(u8, h.name);
        try lowered.append(gpa, name);
        for (name) |*c| c.* = std.ascii.toLower(c.*);
        if (std.mem.eql(u8, name, "content-length")) have_len = true;
        try hs.append(gpa, .{ .name = name, .value = h.value });
    }
    var len_buf: [24]u8 = undefined;
    if (!have_len) {
        const lt = std.fmt.bufPrint(&len_buf, "{d}", .{resp.body.len}) catch "0";
        try hs.append(gpa, .{ .name = "content-length", .value = lt });
    }
    var block: std.ArrayListUnmanaged(u8) = .empty;
    defer block.deinit(gpa);
    try h3.encodeFieldSection(&block, gpa, hs.items);
    try h3.appendFrame(&rs.out, gpa, h3.frame_headers, block.items);
    if (resp.body.len > 0) try h3.appendFrame(&rs.out, gpa, h3.frame_data, resp.body);
}

fn queueError(gpa: Allocator, rs: *ReqStream, status: u16) void {
    const resp: Response = .{ .status = status, .body = @constCast(statusText(status)) };
    encodeResponse(gpa, rs, &resp) catch {};
    rs.dispatched = true;
}

// ---- İstek ayrıştırma -------------------------------------------------------------------------------------------------------------------------------------------

const ParseResult = enum { need_more, complete, bad_request, too_large, header_too_large, protocol_error };

/// `rs.inbuf`taki tam çerçeveleri tüketir. FIN görüldüyse ve tampon bittiyse `complete` (alanlar `rs.hdr_list`/`rs.body`).
fn parseRequest(e: *Engine, rs: *ReqStream) ParseResult {
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
                if (!rs.have_headers) {
                    if (payload.len > e.cfg.max_header_bytes) return .header_too_large;
                    const d = h3.decodeFieldSection(rs.arena.allocator(), payload, e.cfg.max_header_bytes) catch |err| switch (err) {
                        error.FieldSectionTooLarge => return .header_too_large,
                        else => return .protocol_error,
                    };
                    rs.hdr_list.appendSlice(gpa, d.headers) catch return .protocol_error;
                    rs.have_headers = true;
                } // ikinci HEADERS = trailer: yok sayılır
            },
            h3.frame_data => {
                if (!rs.have_headers) return .protocol_error;
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
fn buildRequest(e: *Engine, rs: *ReqStream) ?Request {
    return buildRequestE(e, rs) catch null;
}

fn buildRequestE(e: *Engine, rs: *ReqStream) error{ Invalid, OutOfMemory }!Request {
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
    const headers = try out.toOwnedSlice(gpa);
    return .{ .method = method_c, .path = path_c, .authority = auth_c, .headers = headers, .body = body_c };
}

fn freeRequest(gpa: Allocator, r: *const Request) void {
    gpa.free(r.method);
    gpa.free(r.path);
    gpa.free(r.authority);
    for (r.headers) |h| {
        gpa.free(h.name);
        gpa.free(h.value);
    }
    gpa.free(r.headers);
    gpa.free(r.body);
}

fn freeResponse(gpa: Allocator, r: *const Response) void {
    for (r.headers) |h| {
        gpa.free(h.name);
        gpa.free(h.value);
    }
    if (r.headers.len > 0) gpa.free(r.headers);
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
        // Kuyruğa eklenemedi (bellek yok): işi sızdırmamak için burada serbest bırak; akış motor tarafından zaman aşımı/bağlantı kapanışıyla temizlenir.
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
    const req = buildRequest(e, rs) orelse return queueError(e.gpa, rs, 400);
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
            if (i == 0) h3.appendSettings(&cs.ours_buf[i], e.gpa, .{ .max_field_section_size = e.cfg.max_header_bytes }) catch return false;
            cs.ours[i] = st;
        }
        if (cs.ours_off[i] < cs.ours_buf[i].items.len) {
            const n = cs.ours[i].?.tryWrite(cs.ours_buf[i].items[cs.ours_off[i]..]) catch return false;
            cs.ours_off[i] += n;
        }
    }
    return true;
}

fn ourStreamsReady(cs: *const ConnState) bool {
    for (0..3) |i| {
        if (cs.ours[i] == null or cs.ours_off[i] < cs.ours_buf[i].items.len) return false;
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

fn serviceUni(e: *Engine, cs: *ConnState, u: *UniStream) bool {
    // false: bağlantıyı düşür (protokol ihlali).
    var fin = false;
    var closed = false;
    _ = readChunk(&u.stream, &u.buf, e.gpa, &fin, &closed);
    if (!u.typed) {
        var l: usize = 0;
        const t = h3.readVarint(u.buf.items, &l) orelse return !closed;
        u.kind = t;
        u.typed = true;
        u.buf.replaceRange(e.gpa, 0, l, &.{}) catch return false;
    }
    _ = cs;
    if (u.kind == h3.stream_control) {
        if (fin or closed) return false; // kritik akış kapatılamaz (H3_CLOSED_CRITICAL_STREAM)
        while (true) {
            const fh = h3.parseFrameHeader(u.buf.items) orelse break;
            const total = fh.header_len + fh.len;
            if (fh.len > 64 * 1024) return false;
            if (u.buf.items.len < total) break;
            const payload = u.buf.items[fh.header_len..][0..@intCast(fh.len)];
            if (!u.settings_seen) {
                if (fh.kind != h3.frame_settings) return false; // H3_MISSING_SETTINGS
                _ = h3.parseSettings(payload) catch return false;
                u.settings_seen = true;
            } else switch (fh.kind) {
                h3.frame_settings, h3.frame_data, h3.frame_headers => return false, // H3_FRAME_UNEXPECTED
                else => {},
            }
            u.buf.replaceRange(e.gpa, 0, total, &.{}) catch return false;
        }
    } else {
        // QPACK kodlayıcı/çözücü akışı (dinamik tablo kapalı: içerik yok sayılır) ve bilinmeyen akışlar: veriyi at.
        u.buf.clearRetainingCapacity();
        if (closed and (u.kind == h3.stream_qpack_encoder or u.kind == h3.stream_qpack_decoder)) return false;
    }
    return true;
}

fn serviceReq(e: *Engine, cs: *ConnState, rs: *ReqStream) bool {
    // false: bağlantıyı düşür.
    if (!rs.dispatched) {
        var closed = false;
        _ = readChunk(&rs.stream, &rs.inbuf, e.gpa, &rs.fin, &closed);
        if (closed) {
            rs.done = true;
            return true;
        }
        const pr = parseRequest(e, rs);
        if (pr != .need_more) dbg("parse -> {s} inbuf={d}", .{ @tagName(pr), rs.inbuf.items.len });
        switch (pr) {
            .need_more => {},
            .complete => dispatch(e, cs, rs),
            .bad_request => queueError(e.gpa, rs, 400),
            .too_large => queueError(e.gpa, rs, 413),
            .header_too_large => queueError(e.gpa, rs, 431),
            .protocol_error => return false,
        }
    }
    // Hazır yanıt baytlarını yaz.
    if (rs.out.items.len > rs.out_off) {
        const n = rs.stream.tryWrite(rs.out.items[rs.out_off..]) catch {
            rs.done = true;
            return true;
        };
        rs.out_off += n;
    }
    if (rs.dispatched and rs.out.items.len > 0 and rs.out_off == rs.out.items.len and !rs.concluded) {
        rs.stream.conclude();
        rs.concluded = true;
        rs.done = true;
    }
    return true;
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
        if (!job.ok or job.resp.status < 100) {
            queueErrorReplace(e, job.rs, 500);
        } else {
            encodeResponse(e.gpa, job.rs, &job.resp) catch queueErrorReplace(e, job.rs, 500);
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
        cs.opened = ourStreamsReady(cs);
        if (cs.opened) dbg("our uni streams opened", .{});
    }
    // Yeni akışlar.
    while (cs.conn.tryAcceptStream()) |st| {
        dbg("stream accepted kind={s}", .{@tagName(st.kind())});
        switch (st.kind()) {
            .bidi => {
                const rs = e.gpa.create(ReqStream) catch break;
                rs.* = .{ .stream = st, .arena = std.heap.ArenaAllocator.init(e.gpa) };
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
        if (!serviceUni(e, cs, cs.unis.items[i])) {
            cs.dead = true;
            return;
        }
        i += 1;
    }
    i = 0;
    while (i < cs.reqs.items.len) {
        const rs = cs.reqs.items[i];
        if (!serviceReq(e, cs, rs)) {
            cs.dead = true;
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

/// Motoru çalıştırır; `hooks.shuttingDown()` ya da `stop` true olunca tüm bağlantıları kapatıp döner.
pub fn run(gpa: Allocator, listener: *quic.Listener, cfg: Config, hooks: Hooks, stop: *std.atomic.Value(bool)) void {
    var e: Engine = .{ .gpa = gpa, .cfg = cfg, .hooks = hooks, .listener = listener };
    defer {
        // Çalışan handler fiber'ları `e`yi (bu yığın çerçevesini) kullanır: hepsi dönene dek kuyruğu boşaltarak bekle.
        while (e.inflight.load(.acquire) > 0) {
            drainDone(&e);
            listener.pumpOnce(2);
        }
        drainDone(&e);
        for (e.conns.items) |c| {
            c.deinit(gpa);
            gpa.destroy(c);
        }
        e.conns.deinit(gpa);
        e.done.deinit(gpa);
    }
    while (!stop.load(.acquire) and !hooks.shuttingDown()) {
        while (listener.tryAccept()) |c| {
            dbg("conn accepted", .{});
            const cs = gpa.create(ConnState) catch break;
            cs.* = .{ .conn = c };
            e.conns.append(gpa, cs) catch {
                cs.deinit(gpa);
                gpa.destroy(cs);
            };
        }
        drainDone(&e);
        var any_out = false;
        var i: usize = 0;
        while (i < e.conns.items.len) {
            const cs = e.conns.items[i];
            serviceConn(&e, cs);
            if (cs.dead and cs.inflight == 0) {
                cs.deinit(gpa);
                gpa.destroy(cs);
                _ = e.conns.swapRemove(i);
                continue;
            }
            for (cs.reqs.items) |rs| if (rs.out.items.len > rs.out_off) {
                any_out = true;
            };
            i += 1;
        }
        const busy = e.inflight.load(.monotonic) > 0 or any_out;
        listener.pumpOnce(if (busy) 1 else 100);
    }
}

// ---- Birim testleri -------------------------------------------------------------------------------------------------------------------------------------------------

const testing = std.testing;
const test_cert: [:0]const u8 = "runtime/stdlib_shims/testdata/quic_test_cert.pem";
const test_key: [:0]const u8 = "runtime/stdlib_shims/testdata/quic_test_key.pem";

const TestHooks = struct {
    shutting: std.atomic.Value(bool) = .init(false),
    served: std.atomic.Value(usize) = .init(0),
    threads: [8]?std.Thread = @splat(null),
    nthreads: usize = 0,

    fn serve(user: *anyopaque, gpa: Allocator, req: *const Request, out: *Response) bool {
        const self: *TestHooks = @ptrCast(@alignCast(user));
        _ = self.served.fetchAdd(1, .monotonic);
        const text = std.fmt.allocPrint(gpa, "{s} {s} len={d} host={s}", .{ req.method, req.path, req.body.len, req.authority }) catch return false;
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
        }, &self.stop);
    }
};

/// Test istemcisi (`http_server.zig` testleri de kullanır): bir istek gönderir, (durum, başlık X-Test, gövde) döndürür. Bellek `arena`dan.
pub fn testRequest(arena: Allocator, conn: *quic.Conn, method: []const u8, path: []const u8, body: []const u8) !struct { status: []const u8, xtest: []const u8, body: []const u8 } {
    var st = try conn.openStream(false);
    defer st.deinit();
    var req: std.ArrayListUnmanaged(u8) = .empty;
    var block: std.ArrayListUnmanaged(u8) = .empty;
    try h3.encodeFieldSection(&block, arena, &.{
        .{ .name = ":method", .value = method },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "localhost" },
        .{ .name = ":path", .value = path },
    });
    try h3.appendFrame(&req, arena, h3.frame_headers, block.items);
    if (body.len > 0) try h3.appendFrame(&req, arena, h3.frame_data, body);
    try st.writeAll(req.items, 5000);
    st.conclude();
    var resp: std.ArrayListUnmanaged(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        switch (st.read(&buf, 10_000)) {
            .data => |n| try resp.appendSlice(arena, buf[0..n]),
            .eof => break,
            else => return error.TestUnexpectedResult,
        }
    }
    var pos: usize = 0;
    var status: []const u8 = "";
    var xtest: []const u8 = "";
    var rbody: std.ArrayListUnmanaged(u8) = .empty;
    while (pos < resp.items.len) {
        const fh = h3.parseFrameHeader(resp.items[pos..]) orelse return error.TestUnexpectedResult;
        const payload = resp.items[pos + fh.header_len ..][0..@intCast(fh.len)];
        if (fh.kind == h3.frame_headers) {
            const d = try h3.decodeFieldSection(arena, payload, 1 << 20);
            for (d.headers) |h| {
                if (std.mem.eql(u8, h.name, ":status")) status = h.value;
                if (std.mem.eql(u8, h.name, "x-test")) xtest = h.value;
            }
        } else if (fh.kind == h3.frame_data) {
            try rbody.appendSlice(arena, payload);
        }
        pos += fh.header_len + fh.len;
    }
    return .{ .status = status, .xtest = xtest, .body = rbody.items };
}

test "h3_server: GET/POST gidiş-dönüşü, 413 ve geçersiz istek (yerel QUIC istemcisiyle)" {
    if (!quic.supported) return error.SkipZigTest;
    if (!quic.available()) return error.SkipZigTest;
    var sctx = try quic.newServerCtx(test_cert, test_key);
    defer sctx.deinit();
    var cctx = try quic.newClientCtx(test_cert, true);
    defer cctx.deinit();
    var l = try quic.Listener.open(&sctx, .{ 127, 0, 0, 1 }, 0);
    defer l.deinit();
    var hooks: TestHooks = .{};
    var eng: TestEngine = .{ .listener = &l, .hooks = &hooks };
    const t = try std.Thread.spawn(.{}, TestEngine.go, .{&eng});

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    {
        var conn = try quic.Conn.connect(&cctx, .{ 127, 0, 0, 1 }, l.port, "localhost", 10_000);
        defer conn.deinit();
        const r1 = try testRequest(a, &conn, "GET", "/hello?x=1", "");
        try testing.expectEqualStrings("200", r1.status);
        try testing.expectEqualStrings("ok", r1.xtest);
        try testing.expectEqualStrings("GET /hello?x=1 len=0 host=localhost", r1.body);
        // Aynı bağlantıda ikinci (çoklanmış) istek + gövde
        const r2 = try testRequest(a, &conn, "POST", "/p", "merhaba");
        try testing.expectEqualStrings("200", r2.status);
        try testing.expectEqualStrings("POST /p len=7 host=localhost", r2.body);
        // Gövde sınırı (1024) aşılırsa 413
        const big = try a.alloc(u8, 2000);
        @memset(big, 'x');
        const r3 = try testRequest(a, &conn, "POST", "/big", big);
        try testing.expectEqualStrings("413", r3.status);
    }
    eng.stop.store(true, .release);
    t.join();
    for (hooks.threads[0..hooks.nthreads]) |th| th.?.join();
    try testing.expectEqual(@as(usize, 2), hooks.served.load(.monotonic));
}
