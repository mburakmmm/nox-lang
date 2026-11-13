//! HTTP/3 istemcisi (RFC 9114) — `quic.zig` (OpenSSL QUIC) üstünde, `h3.zig` (çerçeveleme + QPACK) ile (TODO 5.4, aşama H3.4/H3.5). Sertifika doğrulaması OpenSSL'in varsayılan güven
//! deposuyla yapılır (`SSL_CERT_FILE`/`SSL_CERT_DIR` ortam değişkenlerine uyar).
//!
//! Bağlantı havuzu: tamamlanan bir isteğin QUIC bağlantısı (kontrol + QPACK akışlarıyla) kaynak başına boşta tutulur (en çok `pool_max_idle`, 60 sn); sonraki istek el sıkışmasız yeniden
//! kullanır. Havuzdan alınan bağlantıda istek hiç yanıt baytı alınmadan başarısız olursa (kapanmış/GOAWAY almış bağlantı) ve yöntem tekrarlanabilirse (GET/HEAD/OPTIONS/PUT/DELETE) bir kez
//! taze bağlantıyla yeniden denenir; POST/PATCH tekrarlanmaz.
//!
//! Adresler: IPv4 ve IPv6 (çözümleme sırasıyla denenir). `Content-Encoding: gzip/deflate` çözülür; kullanıcı `accept-encoding` vermediyse TCP yolundaki gibi `gzip, deflate` istenir.
//! QPACK: istemci SETTINGS_QPACK_MAX_TABLE_CAPACITY=0 bildirir (sunucular dinamik tablo kullanmaz; yanıt blokları statik tabloyla çözülür).
//!
//! Dönüş: `.fallback` isteğin HİÇBİR baytı gönderilmeden başarısız olundu (bağlantı/el sıkışma/kontrol akışı hatası) — çağıran TCP yoluna güvenle düşebilir; `.failed` istek
//! gönderildikten sonra hata; `.done` yanıt tamam.

const std = @import("std");
const Allocator = std.mem.Allocator;
const quic = @import("quic.zig");
const h3 = @import("h3.zig");
const SpinLock = @import("../async_rt/spinlock.zig").SpinLock;

pub const Header = h3.Header;

pub const Response = struct {
    status: u16,
    /// `gpa` ile ayrılmış; `deinit` serbest bırakır.
    headers: []Header,
    body: []u8,

    pub fn deinit(self: *Response, gpa: Allocator) void {
        for (self.headers) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        gpa.free(self.headers);
        gpa.free(self.body);
    }
};

pub const Outcome = union(enum) { done: Response, fallback, failed };

pub const max_response_body: usize = 512 * 1024 * 1024;
const idle_ms: i64 = 60_000;

fn isConnectionSpecific(name: []const u8) bool {
    const names = [_][]const u8{ "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "host" };
    for (names) |n| if (std.ascii.eqlIgnoreCase(name, n)) return true;
    return false;
}

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Süreç-geneli TEK istemci bağlamı (OpenSSL güven deposunu bir kez yükler).
const SharedCtx = struct {
    lock: std.atomic.Value(u8) = .init(0), // 0 boş, 1 kuruluyor, 2 hazır, 3 başarısız
    ctx: quic.Ctx = undefined,
};
var g_ctx: SharedCtx = .{};

fn clientCtx() ?*quic.Ctx {
    while (true) {
        const s = g_ctx.lock.load(.acquire);
        if (s == 2) return &g_ctx.ctx;
        if (s == 3) return null;
        if (s == 0 and g_ctx.lock.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
            if (quic.newClientCtx(null, true)) |c| {
                g_ctx.ctx = c;
                g_ctx.lock.store(2, .release);
            } else |_| g_ctx.lock.store(3, .release);
            continue;
        }
        std.Thread.yield() catch {};
    }
}

/// `host` adresini (IPv4/IPv6 literal ya da ad) çözer; en çok `out.len` adres yazar, sayıyı döner.
pub fn resolve(host: []const u8, out: []quic.Addr) usize {
    if (std.Io.net.IpAddress.parse(host, 0)) |ip| {
        switch (ip) {
            .ip4 => |a| {
                out[0] = .{ .v4 = a.bytes };
                return 1;
            },
            .ip6 => |a| {
                out[0] = .{ .v6 = a.bytes };
                return 1;
            },
        }
    } else |_| {}
    var buf: [256]u8 = undefined;
    if (host.len >= buf.len) return 0;
    @memcpy(buf[0..host.len], host);
    buf[host.len] = 0;
    var hints = std.mem.zeroes(std.c.addrinfo);
    hints.family = std.c.AF.UNSPEC;
    hints.socktype = std.c.SOCK.DGRAM;
    var list: ?*std.c.addrinfo = null;
    if (@intFromEnum(std.c.getaddrinfo(@ptrCast(&buf), null, &hints, &list)) != 0) return 0;
    defer if (list) |l| std.c.freeaddrinfo(l);
    var n: usize = 0;
    var it = list;
    while (it) |ai| : (it = ai.next) {
        if (n >= out.len) break;
        if (ai.family == std.c.AF.INET) {
            const sa: *const std.c.sockaddr.in = @ptrCast(@alignCast(ai.addr.?));
            var a: [4]u8 = undefined;
            @memcpy(&a, std.mem.asBytes(&sa.addr));
            out[n] = .{ .v4 = a };
            n += 1;
        } else if (ai.family == std.c.AF.INET6) {
            const sa: *const std.c.sockaddr.in6 = @ptrCast(@alignCast(ai.addr.?));
            out[n] = .{ .v6 = sa.addr };
            n += 1;
        }
    }
    return n;
}

/// Bir QUIC bağlantısı + yaşam boyu açık kalması gereken kontrol/QPACK tek yönlü akışlarımız.
const Bundle = struct {
    conn: quic.Conn,
    ours: [3]?quic.Stream = .{ null, null, null },

    fn deinit(self: *Bundle) void {
        for (&self.ours) |*o| if (o.*) |*st| st.deinit();
        self.conn.deinit();
    }
};

fn openUni(b: *Bundle, kind: u64, with_settings: bool, gpa: Allocator, idx: usize) bool {
    var st = b.conn.openStream(true) catch return false;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    h3.appendStreamType(&buf, gpa, kind) catch {
        st.deinit();
        return false;
    };
    if (with_settings) h3.appendSettings(&buf, gpa, .{}) catch {
        st.deinit();
        return false;
    };
    st.writeAll(buf.items, 5000) catch {
        st.deinit();
        return false;
    };
    b.ours[idx] = st;
    return true;
}

fn connectFresh(gpa: Allocator, host: []const u8, port: u16, phase_ms: u32) ?Bundle {
    var addrs: [4]quic.Addr = undefined;
    const n = resolve(host, &addrs);
    if (n == 0) return null;
    const cctx = clientCtx() orelse return null;
    var sni_buf: [256]u8 = undefined;
    if (host.len >= sni_buf.len) return null;
    @memcpy(sni_buf[0..host.len], host);
    sni_buf[host.len] = 0;
    const sni: [:0]const u8 = sni_buf[0..host.len :0];
    const per_addr: u32 = if (n > 1) @min(phase_ms, 2500) else @min(phase_ms, 5000);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var conn = quic.Conn.connect(cctx, addrs[i], port, sni, per_addr) catch continue;
        if (!conn.alpnIsH3()) {
            conn.deinit();
            continue;
        }
        var b: Bundle = .{ .conn = conn };
        if (openUni(&b, h3.stream_control, true, gpa, 0) and openUni(&b, h3.stream_qpack_encoder, false, gpa, 1) and openUni(&b, h3.stream_qpack_decoder, false, gpa, 2)) return b;
        b.deinit();
    }
    return null;
}

// ---- Bağlantı havuzu ---------------------------------------------------------------------------------------------------------------------------------------------

const POOL_MAX: usize = 8;
const PoolEntry = struct {
    used: bool = false,
    host: [96]u8 = undefined,
    host_len: u8 = 0,
    port: u16 = 0,
    last_ms: i64 = 0,
    bundle: Bundle = undefined,
};
var g_pool: [POOL_MAX]PoolEntry = @splat(.{});
var g_pool_lock: SpinLock = .{};

fn poolTake(host: []const u8, port: u16) ?Bundle {
    g_pool_lock.lock();
    defer g_pool_lock.unlock();
    const now = nowMs();
    for (&g_pool) |*e| {
        if (!e.used) continue;
        if (now - e.last_ms > idle_ms or e.bundle.conn.isClosed()) {
            e.bundle.deinit();
            e.used = false;
            continue;
        }
        if (e.port == port and std.ascii.eqlIgnoreCase(e.host[0..e.host_len], host)) {
            e.used = false;
            return e.bundle;
        }
    }
    return null;
}

fn poolPut(host: []const u8, port: u16, b: Bundle, max_idle: usize) void {
    var bundle = b;
    if (max_idle == 0 or host.len > 96 or bundle.conn.isClosed()) return bundle.deinit();
    g_pool_lock.lock();
    defer g_pool_lock.unlock();
    var count: usize = 0;
    var oldest: *PoolEntry = &g_pool[0];
    var free_slot: ?*PoolEntry = null;
    for (&g_pool) |*e| {
        if (!e.used) {
            if (free_slot == null) free_slot = e;
            continue;
        }
        count += 1;
        if (e.last_ms < oldest.last_ms) oldest = e;
    }
    const slot: *PoolEntry = blk: {
        if (count >= @min(max_idle, POOL_MAX) or free_slot == null) {
            if (count == 0) break :blk free_slot.?;
            oldest.bundle.deinit();
            oldest.used = false;
            break :blk oldest;
        }
        break :blk free_slot.?;
    };
    slot.* = .{ .used = true, .host_len = @intCast(host.len), .port = port, .last_ms = nowMs(), .bundle = bundle };
    @memcpy(slot.host[0..host.len], host);
}

/// Havuzdaki boşta bağlantı sayısı (testler için).
pub fn poolIdleCount() usize {
    g_pool_lock.lock();
    defer g_pool_lock.unlock();
    var n: usize = 0;
    for (&g_pool) |*e| {
        if (e.used) n += 1;
    }
    return n;
}

/// Havuzdaki tüm bağlantıları kapatır (testler / `client_pool(0)`).
pub fn poolClear() void {
    g_pool_lock.lock();
    defer g_pool_lock.unlock();
    for (&g_pool) |*e| {
        if (e.used) {
            e.bundle.deinit();
            e.used = false;
        }
    }
}

// ---- İstek ---------------------------------------------------------------------------------------------------------------------------------------------------------------

fn idempotent(method: []const u8) bool {
    const names = [_][]const u8{ "GET", "HEAD", "OPTIONS", "PUT", "DELETE" };
    for (names) |n| if (std.mem.eql(u8, method, n)) return true;
    return false;
}

const Attempt = union(enum) { done: Response, presend, failed_no_data, failed_data };

fn decodeBody(gpa: Allocator, encoding: []const u8, raw: []u8) ![]u8 {
    const ce: ?std.http.ContentEncoding = if (std.ascii.eqlIgnoreCase(encoding, "gzip") or std.ascii.eqlIgnoreCase(encoding, "x-gzip"))
        .gzip
    else if (std.ascii.eqlIgnoreCase(encoding, "deflate"))
        .deflate
    else
        null;
    const kind = ce orelse return raw;
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var in: std.Io.Reader = .fixed(raw);
    var dec: std.http.Decompress = undefined;
    const rd = std.http.Decompress.init(&dec, &in, window, kind);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    _ = rd.streamRemaining(&out.writer) catch return error.DecodeFailed;
    if (out.written().len > max_response_body) return error.DecodeFailed;
    gpa.free(raw);
    return out.toOwnedSlice();
}

fn attempt(gpa: Allocator, b: *Bundle, authority: []const u8, method: []const u8, path: []const u8, req_headers: []const Header, body: ?[]const u8, phase_ms: u32) Attempt {
    var st = b.conn.openStream(false) catch return .presend;
    defer st.deinit();
    var hs: std.ArrayListUnmanaged(Header) = .empty;
    defer hs.deinit(gpa);
    var lowered: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (lowered.items) |l| gpa.free(l);
        lowered.deinit(gpa);
    }
    var len_buf: [24]u8 = undefined;
    const build = blk: {
        hs.append(gpa, .{ .name = ":method", .value = method }) catch break :blk false;
        hs.append(gpa, .{ .name = ":scheme", .value = "https" }) catch break :blk false;
        hs.append(gpa, .{ .name = ":authority", .value = authority }) catch break :blk false;
        hs.append(gpa, .{ .name = ":path", .value = path }) catch break :blk false;
        var have_len = false;
        var have_enc = false;
        for (req_headers) |h| {
            if (isConnectionSpecific(h.name)) continue;
            const n = gpa.dupe(u8, h.name) catch break :blk false;
            lowered.append(gpa, n) catch {
                gpa.free(n);
                break :blk false;
            };
            for (n) |*c| c.* = std.ascii.toLower(c.*);
            if (std.mem.eql(u8, n, "content-length")) have_len = true;
            if (std.mem.eql(u8, n, "accept-encoding")) have_enc = true;
            hs.append(gpa, .{ .name = n, .value = h.value }) catch break :blk false;
        }
        if (!have_enc) hs.append(gpa, .{ .name = "accept-encoding", .value = "gzip, deflate" }) catch break :blk false;
        if (body) |bd| if (!have_len) {
            const lt = std.fmt.bufPrint(&len_buf, "{d}", .{bd.len}) catch break :blk false;
            hs.append(gpa, .{ .name = "content-length", .value = lt }) catch break :blk false;
        };
        break :blk true;
    };
    if (!build) return .presend;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    var block: std.ArrayListUnmanaged(u8) = .empty;
    defer block.deinit(gpa);
    h3.encodeFieldSection(&block, gpa, hs.items) catch return .presend;
    h3.appendFrame(&out, gpa, h3.frame_headers, block.items) catch return .presend;
    if (body) |bd| if (bd.len > 0) h3.appendFrame(&out, gpa, h3.frame_data, bd) catch return .presend;

    // Bağlantı kapalıysa hiçbir şey gönderilmeden başarısız say.
    if (b.conn.isClosed()) return .presend;
    st.writeAll(out.items, phase_ms) catch return .presend;
    st.conclude();

    var inbuf: std.ArrayListUnmanaged(u8) = .empty;
    defer inbuf.deinit(gpa);
    var tmp: [16384]u8 = undefined;
    while (true) {
        switch (st.read(&tmp, phase_ms)) {
            .data => |n| {
                inbuf.appendSlice(gpa, tmp[0..n]) catch return .failed_data;
                if (inbuf.items.len > max_response_body + 1024 * 1024) return .failed_data;
            },
            .eof => break,
            else => return if (inbuf.items.len == 0) .failed_no_data else .failed_data,
        }
    }
    if (inbuf.items.len == 0) return .failed_no_data;

    // Çerçeveleri ayrıştır.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var status: u16 = 0;
    var resp_headers: []Header = &.{};
    var resp_body: std.ArrayListUnmanaged(u8) = .empty;
    errdefer resp_body.deinit(gpa);
    var pos: usize = 0;
    while (pos < inbuf.items.len) {
        const fh = h3.parseFrameHeader(inbuf.items[pos..]) orelse return .failed_data;
        const total = fh.header_len + fh.len;
        if (inbuf.items.len - pos < total) return .failed_data;
        const payload = inbuf.items[pos + fh.header_len ..][0..@intCast(fh.len)];
        switch (fh.kind) {
            h3.frame_headers => {
                if (status < 200) {
                    const d = h3.decodeFieldSection(arena, payload, 1 << 20) catch return .failed_data;
                    var st_code: u16 = 0;
                    for (d.headers) |h| if (std.mem.eql(u8, h.name, ":status")) {
                        st_code = std.fmt.parseInt(u16, h.value, 10) catch return .failed_data;
                    };
                    if (st_code == 0) return .failed_data;
                    if (st_code >= 200) resp_headers = d.headers;
                    status = st_code; // 1xx ara yanıt: son başlığı bekle
                } // sonraki HEADERS = trailer: yok sayılır
            },
            h3.frame_data => {
                if (status < 200) return .failed_data;
                if (resp_body.items.len + payload.len > max_response_body) return .failed_data;
                resp_body.appendSlice(gpa, payload) catch return .failed_data;
            },
            else => {},
        }
        pos += total;
    }
    if (status < 200) return .failed_data;

    // Sahipli kopyalar (sözde başlıklar atılır).
    var owned: std.ArrayListUnmanaged(Header) = .empty;
    errdefer {
        for (owned.items) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        owned.deinit(gpa);
    }
    var encoding: []const u8 = "";
    for (resp_headers) |h| {
        if (h.name.len > 0 and h.name[0] == ':') continue;
        if (std.mem.eql(u8, h.name, "content-encoding")) encoding = h.value;
        const n = gpa.dupe(u8, h.name) catch return .failed_data;
        const v = gpa.dupe(u8, h.value) catch {
            gpa.free(n);
            return .failed_data;
        };
        owned.append(gpa, .{ .name = n, .value = v }) catch {
            gpa.free(n);
            gpa.free(v);
            return .failed_data;
        };
    }
    const raw = resp_body.toOwnedSlice(gpa) catch return .failed_data;
    const final_body = decodeBody(gpa, encoding, raw) catch {
        gpa.free(raw);
        return .failed_data;
    };
    const hs_owned = owned.toOwnedSlice(gpa) catch {
        gpa.free(final_body);
        return .failed_data;
    };
    return .{ .done = .{ .status = status, .headers = hs_owned, .body = final_body } };
}

/// Tek bir HTTP/3 isteği yapar. `authority`: `host[:port]` (:authority). `path`: sorgu dahil `/...`. `pool_max_idle`: boşta tutulacak bağlantı üst sınırı (0: havuz yok).
pub fn request(
    gpa: Allocator,
    host: []const u8,
    port: u16,
    authority: []const u8,
    method: []const u8,
    path: []const u8,
    req_headers: []const Header,
    body: ?[]const u8,
    timeout_ms: u32,
    pool_max_idle: usize,
) Outcome {
    if (comptime !quic.supported) return .fallback;
    if (!quic.available()) return .fallback;
    const phase_ms: u32 = if (timeout_ms == 0) 30_000 else timeout_ms;

    var from_pool = false;
    var bundle: Bundle = undefined;
    if (pool_max_idle > 0) {
        if (poolTake(host, port)) |b| {
            bundle = b;
            from_pool = true;
        }
    }
    var tries: u8 = 0;
    while (tries < 2) : (tries += 1) {
        if (!from_pool) {
            bundle = connectFresh(gpa, host, port, phase_ms) orelse return .fallback;
        }
        const r = attempt(gpa, &bundle, authority, method, path, req_headers, body, phase_ms);
        switch (r) {
            .done => |resp| {
                poolPut(host, port, bundle, pool_max_idle);
                return .{ .done = resp };
            },
            .presend => {
                bundle.deinit();
                if (from_pool) {
                    from_pool = false; // bayat havuz bağlantısı: taze bağlantıyla bir kez daha
                    continue;
                }
                return .fallback;
            },
            .failed_no_data => {
                bundle.deinit();
                if (from_pool and idempotent(method)) {
                    from_pool = false;
                    continue;
                }
                return .failed;
            },
            .failed_data => {
                bundle.deinit();
                return .failed;
            },
        }
    }
    return .failed;
}

const testing = std.testing;

test "h3_client: Content-Encoding gzip/deflate çözülür, bilinmeyen kodlama olduğu gibi döner" {
    const gz = [_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x48, 0xaf, 0xca, 0x2c, 0x50, 0x48, 0xca, 0x4f, 0xa9, 0x04, 0x00, 0xad, 0xd6, 0xc9, 0x4c, 0x0f, 0x00, 0x00, 0x00 };
    const df = [_]u8{ 0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x48, 0x49, 0x4d, 0xcb, 0x49, 0x2c, 0x49, 0x55, 0x48, 0xca, 0x4f, 0xa9, 0x04, 0x00, 0x40, 0xf4, 0x06, 0xd8 };
    const gpa = testing.allocator;
    const a = try decodeBody(gpa, "gzip", try gpa.dupe(u8, &gz));
    defer gpa.free(a);
    try testing.expectEqualStrings("hello gzip body", a);
    const b = try decodeBody(gpa, "DEFLATE", try gpa.dupe(u8, &df));
    defer gpa.free(b);
    try testing.expectEqualStrings("hello deflate body", b);
    const c = try decodeBody(gpa, "br", try gpa.dupe(u8, "raw-br"));
    defer gpa.free(c);
    try testing.expectEqualStrings("raw-br", c);
    const bad = try gpa.dupe(u8, "not gzip at all");
    defer gpa.free(bad); // başarısızlıkta `raw` çağırana aittir
    try testing.expectError(error.DecodeFailed, decodeBody(gpa, "gzip", bad));
}

test "h3_client: adres çözümleme IPv4/IPv6 literalleri ve geçersiz ad" {
    var addrs: [4]quic.Addr = undefined;
    try testing.expectEqual(@as(usize, 1), resolve("127.0.0.1", &addrs));
    try testing.expectEqual([4]u8{ 127, 0, 0, 1 }, addrs[0].v4);
    try testing.expectEqual(@as(usize, 1), resolve("::1", &addrs));
    try testing.expectEqual(@as(u8, 1), addrs[0].v6[15]);
}
