//! `nox.grpc` — saf Zig gRPC istemcisi (pulse NOX-CAP-GRPC-001, v2.1.33). `tcp_native.zig` / `tcp_host.zig` taşıması üzerinde HTTP/2 (`h2c`, düz TCP, önceden bilinen) konuşur.
//!
//! Her çağrı tek bir akış kullanır: `HEADERS` (`:method POST`, `content-type: application/grpc`, `te: trailers`, isteğe bağlı `grpc-timeout` ve kullanıcı üst verisi),
//! ardından uzunluk önekli (1 bayt sıkıştırma bayrağı + 4 bayt BE uzunluk) mesajlar `DATA` olarak gider, sonuncusu `END_STREAM` taşır. Yanıt: `HEADERS`, `DATA` (mesajlar),
//! kapanış `HEADERS` (trailer: `grpc-status`, `grpc-message`). Tek çağrı unary, sunucu-akışlı ve istemci-akışlı RPC'leri kapsar (mesajlar toplanır; çift yönlü
//! araya girme yoktur). Bir bağlantıda çağrılar sırayla yapılır (akış kimlikleri 1, 3, 5, ...).
//!
//! Akış denetimi: gönderirken karşının bağlantı ve akış pencereleri izlenir (`WINDOW_UPDATE`, `SETTINGS_INITIAL_WINDOW_SIZE`); alırken her `DATA` için pencere yenilenir.
//! Sıkıştırma (v2.1.39): istek `grpc-accept-encoding: gzip,identity` bildirir ve `grpc-encoding: gzip` yanıtları çözülür; `nox_grpc_set_compress_raw` ile istekler de gzip'lenir.
//!
//! **TLS** (v2.1.35): `nox_grpc_open_tls_raw` ALPN `h2` bildiren yamalı vendor TLS istemcisiyle (`runtime/vendor/tls_client.zig`, `alpn_h2`) bağlanır; sistem CA deposu ya da `ca_file`.
//! **v1 sınırları:** okuma zaman aşımı YOKTUR (`nox_tcp` taşımasının sınırı; süreyi sunucuya `grpc-timeout` ile bildirin, sunucu `DEADLINE_EXCEEDED` döner).

const std = @import("std");
const builtin = @import("builtin");
const str_mod = @import("../str.zig");
const shim_util = @import("shim_util.zig");
const h2 = @import("http2.zig");
const gzip_shim = @import("gzip.zig");
const tcp = if (builtin.cpu.arch.isWasm()) @import("tcp_host.zig") else @import("tcp_native.zig");
const abi_layout = @import("abi_layout");

const gpa = std.heap.page_allocator;
const LIST_HEADER_SIZE = abi_layout.LIST_HEADER_SIZE;
const FIELD_SLOT_SIZE = abi_layout.FIELD_SLOT_SIZE;

const PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
const MAX_FRAME_IN: usize = 16 * 1024 * 1024;
const MAX_MESSAGE: usize = 256 * 1024 * 1024;
/// gRPC durum kodu: taşıma/protokol hatalarında Nox tarafına bildirilir (`GrpcError`).
const STATUS_TRANSPORT: i64 = -1;

const GConn = struct {
    c: *tcp.Conn,
    rbuf: std.ArrayListUnmanaged(u8) = .empty,
    rpos: usize = 0,
    ok: bool = false,
    errmsg: []const u8 = "",
    errmsg_owned: bool = false,
    next_stream: u32 = 1,
    decoder: h2.Decoder,
    authority: []u8 = &.{},
    /// Karşının bağlantı penceresi (bizim gönderebileceğimiz) ve akış başına başlangıç penceresi.
    conn_window: i64 = h2.default_window,
    peer_stream_window: i64 = h2.default_window,
    peer_max_frame: u32 = h2.default_max_frame,
    goaway: bool = false,
    tls: bool = false,
    /// Elle sürülen bir `Stream` açıkken başka çağrı/akış başlatılamaz.
    stream_active: bool = false,
    /// `true` ise istek mesajları gzip ile sıkıştırılır (`grpc-encoding: gzip`); yanıt sıkıştırması her zaman kabul edilir.
    compress: bool = false,

    fn setErr(self: *GConn, msg: []const u8) void {
        if (self.errmsg_owned) gpa.free(self.errmsg);
        if (gpa.dupe(u8, msg)) |d| {
            self.errmsg = d;
            self.errmsg_owned = true;
        } else |_| {
            self.errmsg = "out of memory";
            self.errmsg_owned = false;
        }
    }

    fn fail(self: *GConn, msg: []const u8) void {
        self.setErr(msg);
        self.ok = false;
    }

    fn fill(self: *GConn) bool {
        var chunk = tcp.readSome(self.c, 64 * 1024);
        // TLS 1.3'te oturum bileti gibi uygulama verisi taşımayan kayıtlar boş bir okuma döndürebilir (hata/EOF değildir): yeniden dene.
        var retries: usize = 0;
        while (chunk.len == 0 and self.c.ok and !self.c.eof and retries < 64) : (retries += 1) {
            chunk = tcp.readSome(self.c, 64 * 1024);
        }
        if (chunk.len == 0) {
            self.fail(if (self.c.eof) "connection closed by the server" else (if (self.c.errmsg.len > 0) self.c.errmsg else "read failed"));
            return false;
        }
        if (self.rpos > 0) {
            const remaining = self.rbuf.items.len - self.rpos;
            std.mem.copyForwards(u8, self.rbuf.items[0..remaining], self.rbuf.items[self.rpos..]);
            self.rbuf.shrinkRetainingCapacity(remaining);
            self.rpos = 0;
        }
        self.rbuf.appendSlice(gpa, chunk) catch {
            self.fail("out of memory");
            return false;
        };
        return true;
    }

    fn need(self: *GConn, n: usize) bool {
        while (self.rbuf.items.len - self.rpos < n) {
            if (!self.fill()) return false;
        }
        return true;
    }

    fn send(self: *GConn, data: []const u8) bool {
        if (!tcp.write(self.c, data)) {
            self.fail(if (self.c.errmsg.len > 0) self.c.errmsg else "write failed");
            return false;
        }
        return true;
    }

    fn sendFrame(self: *GConn, kind: u8, flags: u8, stream: u32, payload: []const u8) bool {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(gpa);
        h2.appendFrameHeader(&out, gpa, @intCast(payload.len), kind, flags, stream) catch {
            self.fail("out of memory");
            return false;
        };
        out.appendSlice(gpa, payload) catch {
            self.fail("out of memory");
            return false;
        };
        return self.send(out.items);
    }

    fn windowUpdate(self: *GConn, stream: u32, inc: u32) bool {
        var p: [4]u8 = undefined;
        std.mem.writeInt(u32, &p, inc, .big);
        return self.sendFrame(h2.frame_window_update, 0, stream, &p);
    }
};

const Header = struct { name: []u8, value: []u8 };

/// Bir çağrının sonucu: gRPC durumu, iletisi, toplanan yanıt mesajları ve yanıt üst verisi (başlık + trailer, adlar küçük harf).
const Result = struct {
    status: i64 = STATUS_TRANSPORT,
    message: []u8 = &.{},
    msgs: std.ArrayListUnmanaged([]u8) = .empty,
    headers: std.ArrayListUnmanaged(Header) = .empty,

    fn deinit(self: *Result) void {
        if (self.message.len > 0) gpa.free(self.message);
        for (self.msgs.items) |m| gpa.free(m);
        self.msgs.deinit(gpa);
        for (self.headers.items) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        self.headers.deinit(gpa);
    }
};

const Pending = struct {
    /// Gelen mesaj akışı: DATA gövdesi (uzunluk önekleriyle) buraya eklenir, tam mesajlar çıkarılır.
    data: std.ArrayListUnmanaged(u8) = .empty,
    header_block: std.ArrayListUnmanaged(u8) = .empty,
    got_headers: bool = false,
    stream_window: i64,
    done: bool = false,
    rst: ?u32 = null,
};

fn listItem(list: *anyopaque, i: usize) []const u8 {
    const bytes: [*]u8 = @ptrCast(list);
    const addr: usize = @intCast(@as(u64, @bitCast(@as(*align(1) i64, @ptrCast(bytes + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i)).*)));
    const p: [*:0]const u8 = @ptrFromInt(addr);
    return str_mod.nox_str_slice(p);
}

fn listLen(list: *anyopaque) usize {
    const bytes: [*]u8 = @ptrCast(list);
    return @intCast(@as(*align(1) i64, @ptrCast(bytes)).*);
}

/// `grpc-message` değeri yüzde-kodludur (RFC / gRPC HTTP/2 şartnamesi): `%XX` çözülür.
fn percentDecode(s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                try out.append(gpa, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(gpa, s[i]);
    }
    return out.toOwnedSlice(gpa);
}

fn lowerDupe(s: []const u8) ![]u8 {
    const d = try gpa.dupe(u8, s);
    for (d) |*ch| ch.* = std.ascii.toLower(ch.*);
    return d;
}

/// Bir sonuca (başlık ya da trailer) yanıt üst verisi ekler.
fn addHeader(r: *Result, name: []const u8, value: []const u8) !void {
    const n = try lowerDupe(name);
    errdefer gpa.free(n);
    const v = try gpa.dupe(u8, value);
    errdefer gpa.free(v);
    try r.headers.append(gpa, .{ .name = n, .value = v });
}

fn headerValue(r: *const Result, name: []const u8) ?[]const u8 {
    for (r.headers.items) |h| if (std.mem.eql(u8, h.name, name)) return h.value;
    return null;
}

/// Bir HEADERS(+CONTINUATION) bloğunu çözer ve sonuca ekler; `grpc-status`/`grpc-message` yakalanır. Dönüş: ``true`` = geçerli.
fn applyHeaderBlock(c: *GConn, r: *Result, block: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var list: std.ArrayListUnmanaged(h2.Header) = .empty;
    const exceeded = c.decoder.decode(block, a, &list, 1024 * 1024) catch {
        c.fail("HPACK decoding error");
        return false;
    };
    if (exceeded) {
        c.fail("response header list too large");
        return false;
    }
    for (list.items) |h| {
        addHeader(r, h.name, h.value) catch {
            c.fail("out of memory");
            return false;
        };
    }
    return true;
}

fn finishStatus(r: *Result) void {
    if (headerValue(r, "grpc-status")) |s| {
        r.status = std.fmt.parseInt(i64, s, 10) catch STATUS_TRANSPORT;
    }
    if (headerValue(r, "grpc-message")) |m| {
        if (percentDecode(m)) |d| {
            if (r.message.len > 0) gpa.free(r.message);
            r.message = d;
        } else |_| {}
    }
}

/// `p.data` içindeki tam mesajları `r.msgs`e taşır. Hata: sıkıştırılmış mesaj / aşırı büyük mesaj.
fn drainMessages(c: *GConn, r: *Result, p: *Pending) bool {
    while (p.data.items.len >= 5) {
        const flag = p.data.items[0];
        const len = std.mem.readInt(u32, p.data.items[1..5], .big);
        if (flag > 1) {
            c.fail("malformed gRPC message prefix");
            return false;
        }
        if (len > MAX_MESSAGE) {
            c.fail("gRPC message too large");
            return false;
        }
        if (p.data.items.len < 5 + @as(usize, len)) return true;
        const raw = p.data.items[5 .. 5 + @as(usize, len)];
        const m: []u8 = if (flag == 1) blk: {
            // Sıkıştırılmış mesaj: yalnızca `grpc-encoding: gzip` desteklenir.
            const enc = headerValue(r, "grpc-encoding") orelse "";
            if (!std.mem.eql(u8, enc, "gzip")) {
                c.fail("unsupported grpc-encoding (only gzip and identity are supported)");
                return false;
            }
            break :blk gzip_shim.gzipDecompress(gpa, raw) catch {
                c.fail("could not decompress a gzip-encoded gRPC message");
                return false;
            };
        } else gpa.dupe(u8, raw) catch {
            c.fail("out of memory");
            return false;
        };
        r.msgs.append(gpa, m) catch {
            gpa.free(m);
            c.fail("out of memory");
            return false;
        };
        const rest = p.data.items.len - 5 - @as(usize, len);
        std.mem.copyForwards(u8, p.data.items[0..rest], p.data.items[5 + @as(usize, len) ..]);
        p.data.shrinkRetainingCapacity(rest);
    }
    return true;
}

/// Bir kareyi okur ve işler. `stream`: bu çağrının akış kimliği, `p` onun durumu. Başarıda `true`.
fn pumpFrame(c: *GConn, stream: u32, p: *Pending, r: *Result) bool {
    if (!c.need(9)) return false;
    var hdr9: [9]u8 = undefined;
    @memcpy(&hdr9, c.rbuf.items[c.rpos .. c.rpos + 9]);
    const fh = h2.parseFrameHeader(&hdr9);
    if (fh.length > MAX_FRAME_IN) {
        c.fail("frame too large");
        return false;
    }
    if (!c.need(9 + fh.length)) return false;
    const payload = c.rbuf.items[c.rpos + 9 .. c.rpos + 9 + fh.length];
    // `payload`, bir sonraki `fill`e kadar geçerlidir; tüketimi (rpos) işlemeden sonra yaparız ama işleme sırasında `send` kullanılır (okuma tamponuna dokunmaz).
    defer c.rpos += 9 + fh.length;
    switch (fh.kind) {
        h2.frame_settings => {
            if (fh.flags & h2.flag_ack != 0) return true;
            var i: usize = 0;
            while (i + 6 <= payload.len) : (i += 6) {
                const id = std.mem.readInt(u16, payload[i..][0..2], .big);
                const val = std.mem.readInt(u32, payload[i + 2 ..][0..4], .big);
                if (id == h2.setting_initial_window_size) {
                    const delta: i64 = @as(i64, val) - c.peer_stream_window;
                    c.peer_stream_window = val;
                    p.stream_window += delta;
                } else if (id == h2.setting_max_frame_size) {
                    c.peer_max_frame = @min(@max(val, h2.default_max_frame), h2.max_allowed_frame);
                }
            }
            return c.sendFrame(h2.frame_settings, h2.flag_ack, 0, &.{});
        },
        h2.frame_ping => {
            if (fh.flags & h2.flag_ack != 0) return true;
            return c.sendFrame(h2.frame_ping, h2.flag_ack, 0, payload);
        },
        h2.frame_window_update => {
            if (payload.len != 4) {
                c.fail("malformed WINDOW_UPDATE");
                return false;
            }
            const inc: i64 = std.mem.readInt(u32, payload[0..4], .big) & 0x7fffffff;
            if (fh.stream_id == 0) {
                c.conn_window += inc;
            } else if (fh.stream_id == stream) {
                p.stream_window += inc;
            }
            return true;
        },
        h2.frame_goaway => {
            c.goaway = true;
            if (!p.done) {
                var buf: [96]u8 = undefined;
                const code: u32 = if (payload.len >= 8) std.mem.readInt(u32, payload[4..8], .big) else 0;
                c.fail(std.fmt.bufPrint(&buf, "server sent GOAWAY (error code {d})", .{code}) catch "server sent GOAWAY");
                return false;
            }
            return true;
        },
        h2.frame_rst_stream => {
            if (fh.stream_id == stream) {
                p.rst = if (payload.len >= 4) std.mem.readInt(u32, payload[0..4], .big) else 0;
                p.done = true;
            }
            return true;
        },
        h2.frame_headers, h2.frame_continuation => {
            // Başlık blokları her akış için (bizimki olmasa da) sıralı çözülmelidir: dinamik tablo bağlantı geneli.
            var block = payload;
            if (fh.kind == h2.frame_headers) {
                var off: usize = 0;
                var end: usize = block.len;
                if (fh.flags & h2.flag_padded != 0) {
                    if (block.len < 1) return false;
                    const pad = block[0];
                    off = 1;
                    if (pad > block.len - 1) return false;
                    end = block.len - pad;
                }
                if (fh.flags & h2.flag_priority != 0) off += 5;
                if (off > end) return false;
                block = block[off..end];
            }
            if (fh.stream_id != stream) {
                // Başka akışın bloğu: dinamik tabloyu güncel tutmak için çözüp atarız (yalnızca END_HEADERS'lı).
                if (fh.flags & h2.flag_end_headers != 0) {
                    var scratch: Result = .{};
                    defer scratch.deinit();
                    return applyHeaderBlock(c, &scratch, block);
                }
                return true;
            }
            p.header_block.appendSlice(gpa, block) catch {
                c.fail("out of memory");
                return false;
            };
            if (fh.flags & h2.flag_end_headers != 0) {
                const ok = applyHeaderBlock(c, r, p.header_block.items);
                p.header_block.clearRetainingCapacity();
                if (!ok) return false;
                p.got_headers = true;
            }
            if (fh.flags & h2.flag_end_stream != 0) p.done = true;
            return true;
        },
        h2.frame_data => {
            var body = payload;
            if (fh.flags & h2.flag_padded != 0) {
                if (body.len < 1) return false;
                const pad = body[0];
                if (pad > body.len - 1) return false;
                body = body[1 .. body.len - pad];
            }
            if (fh.length > 0) {
                // Pencereyi (bağlantı ve akış) yenile.
                if (!c.windowUpdate(0, fh.length)) return false;
                if (fh.stream_id == stream and fh.flags & h2.flag_end_stream == 0) {
                    if (!c.windowUpdate(stream, fh.length)) return false;
                }
            }
            if (fh.stream_id != stream) return true;
            p.data.appendSlice(gpa, body) catch {
                c.fail("out of memory");
                return false;
            };
            if (!drainMessages(c, r, p)) return false;
            if (fh.flags & h2.flag_end_stream != 0) p.done = true;
            return true;
        },
        else => return true, // PRIORITY, PUSH_PROMISE (kapalı), bilinmeyen: yok sayılır
    }
}

/// Bir istek akışının DATA gövdesini pencere kurallarına uyarak gönderir.
fn sendBody(c: *GConn, stream: u32, p: *Pending, r: *Result, body: []const u8, end_stream: bool) bool {
    var off: usize = 0;
    while (off < body.len) {
        const avail = @min(c.conn_window, p.stream_window);
        if (avail <= 0) {
            if (!pumpFrame(c, stream, p, r)) return false;
            if (p.done) return true;
            continue;
        }
        const n: usize = @min(@min(body.len - off, @as(usize, @intCast(avail))), @as(usize, c.peer_max_frame));
        const last = end_stream and off + n == body.len;
        if (!c.sendFrame(h2.frame_data, if (last) h2.flag_end_stream else 0, stream, body[off .. off + n])) return false;
        c.conn_window -= @intCast(n);
        p.stream_window -= @intCast(n);
        off += n;
    }
    return true;
}

/// İstek başlıklarını kurup (`HEADERS` + gerekirse `CONTINUATION`) `stream` akışında gönderir. `end_stream` başlıkla birlikte gönderilmez (gövde DATA ile gelir).
fn sendRequestHeaders(c: *GConn, stream: u32, path: []const u8, meta: []const u8, timeout_ms: i64) bool {
    var hb: std.ArrayListUnmanaged(u8) = .empty;
    defer hb.deinit(gpa);
    const ok_hdr = blk: {
        h2.encodeField(&hb, gpa, ":method", "POST") catch break :blk false;
        h2.encodeField(&hb, gpa, ":scheme", if (c.tls) "https" else "http") catch break :blk false;
        h2.encodeField(&hb, gpa, ":path", path) catch break :blk false;
        h2.encodeField(&hb, gpa, ":authority", c.authority) catch break :blk false;
        h2.encodeField(&hb, gpa, "content-type", "application/grpc") catch break :blk false;
        h2.encodeField(&hb, gpa, "te", "trailers") catch break :blk false;
        h2.encodeField(&hb, gpa, "grpc-accept-encoding", "gzip,identity") catch break :blk false;
        if (c.compress) h2.encodeField(&hb, gpa, "grpc-encoding", "gzip") catch break :blk false;
        h2.encodeField(&hb, gpa, "user-agent", "grpc-nox/2.1") catch break :blk false;
        if (timeout_ms > 0) {
            var tb: [24]u8 = undefined;
            const t = std.fmt.bufPrint(&tb, "{d}m", .{timeout_ms}) catch break :blk false;
            h2.encodeField(&hb, gpa, "grpc-timeout", t) catch break :blk false;
        }
        // Kullanıcı üst verisi: "ad: değer" satırları (`\n` ayracı); ad küçük harfe çevrilir.
        var it = std.mem.splitScalar(u8, meta, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            var name_buf: [128]u8 = undefined;
            const nm = std.mem.trim(u8, line[0..colon], " ");
            if (nm.len == 0 or nm.len > name_buf.len) continue;
            for (nm, 0..) |ch, i| name_buf[i] = std.ascii.toLower(ch);
            const val = std.mem.trim(u8, line[colon + 1 ..], " ");
            h2.encodeField(&hb, gpa, name_buf[0..nm.len], val) catch break :blk false;
        }
        break :blk true;
    };
    if (!ok_hdr) {
        c.fail("out of memory");
        return false;
    }
    const max = @as(usize, c.peer_max_frame);
    var off: usize = 0;
    var first = true;
    while (off < hb.items.len or first) {
        const n = @min(max, hb.items.len - off);
        const end = off + n == hb.items.len;
        const kind: u8 = if (first) h2.frame_headers else h2.frame_continuation;
        const flags: u8 = if (end) h2.flag_end_headers else 0;
        if (!c.sendFrame(kind, flags, stream, hb.items[off .. off + n])) return false;
        off += n;
        first = false;
        if (end) break;
    }
    return true;
}

/// Akış bittikten sonra durumu kesinleştirir (RST_STREAM ya da trailer'daki `grpc-status`). `r` döner.
fn finalizeResult(c: *GConn, p: *Pending, r: *Result) *Result {
    _ = c;
    if (p.rst) |code| {
        var buf: [96]u8 = undefined;
        r.status = STATUS_TRANSPORT;
        const msg = std.fmt.bufPrint(&buf, "stream reset by the server (error code {d})", .{code}) catch "stream reset by the server";
        if (r.message.len > 0) gpa.free(r.message);
        r.message = gpa.dupe(u8, msg) catch &.{};
        return r;
    }
    finishStatus(r);
    if (r.status == STATUS_TRANSPORT) {
        const http_status = headerValue(r, ":status") orelse "";
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "missing grpc-status (HTTP status {s})", .{http_status}) catch "missing grpc-status";
        if (r.message.len > 0) gpa.free(r.message);
        r.message = gpa.dupe(u8, msg) catch &.{};
    }
    return r;
}

/// Bir istek mesajını uzunluk önekli (1 bayt bayrak + 4 bayt BE uzunluk) olarak `body`ye ekler; `c.compress` ise gzip ile sıkıştırır (bayrak 1).
fn appendFramed(c: *GConn, body: *std.ArrayListUnmanaged(u8), msg: []const u8) bool {
    var payload: []const u8 = msg;
    var owned: ?[]u8 = null;
    defer if (owned) |o| gpa.free(o);
    var flag: u8 = 0;
    if (c.compress) {
        if (gzip_shim.gzipCompress(gpa, msg)) |z| {
            owned = z;
            payload = z;
            flag = 1;
        } else |_| {
            c.fail("could not compress a gRPC message");
            return false;
        }
    }
    var pre: [5]u8 = undefined;
    pre[0] = flag;
    std.mem.writeInt(u32, pre[1..5], @intCast(payload.len), .big);
    body.appendSlice(gpa, &pre) catch {
        c.fail("out of memory");
        return false;
    };
    body.appendSlice(gpa, payload) catch {
        c.fail("out of memory");
        return false;
    };
    return true;
}

fn call(c: *GConn, path: []const u8, meta: []const u8, reqs: []const []const u8, timeout_ms: i64) ?*Result {
    if (!c.ok) return null;
    if (c.goaway) {
        c.fail("connection is closing (GOAWAY received)");
        return null;
    }
    if (c.stream_active) {
        c.fail("another stream is still open on this connection (finish it first)");
        return null;
    }
    const r = gpa.create(Result) catch {
        c.fail("out of memory");
        return null;
    };
    r.* = .{};
    var p: Pending = .{ .stream_window = c.peer_stream_window };
    defer {
        p.data.deinit(gpa);
        p.header_block.deinit(gpa);
    }
    const stream = c.next_stream;
    c.next_stream += 2;

    if (!sendRequestHeaders(c, stream, path, meta, timeout_ms)) {
        r.deinit();
        gpa.destroy(r);
        return null;
    }

    // İstek gövdesi: uzunluk önekli mesajlar; hiç mesaj yoksa boş DATA + END_STREAM.
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(gpa);
    for (reqs) |m| {
        if (!appendFramed(c, &body, m)) {
            r.deinit();
            gpa.destroy(r);
            return null;
        }
    }
    if (body.items.len == 0) {
        if (!c.sendFrame(h2.frame_data, h2.flag_end_stream, stream, &.{})) {
            r.deinit();
            gpa.destroy(r);
            return null;
        }
    } else if (!sendBody(c, stream, &p, r, body.items, true)) {
        r.deinit();
        gpa.destroy(r);
        return null;
    }

    while (!p.done) {
        if (!pumpFrame(c, stream, &p, r)) {
            r.deinit();
            gpa.destroy(r);
            return null;
        }
    }
    return finalizeResult(c, &p, r);
}

// ---- Çift yönlü / elle sürülen akış (v2.1.38) ----

/// Açık bir RPC akışı: istekler `send` ile tek tek gider, yanıtlar `recv` ile tek tek gelir; araya girebilirler. Bağlantıda aynı anda tek akış açık olabilir.
const Stream = struct {
    c: *GConn,
    id: u32,
    p: Pending,
    r: Result = .{},
    taken: usize = 0,
    send_closed: bool = false,
    finalized: bool = false,
};

fn streamOpen(c: *GConn, path: []const u8, meta: []const u8, timeout_ms: i64) ?*Stream {
    if (!c.ok) return null;
    if (c.goaway) {
        c.fail("connection is closing (GOAWAY received)");
        return null;
    }
    if (c.stream_active) {
        c.fail("another stream is still open on this connection (finish it first)");
        return null;
    }
    const st = gpa.create(Stream) catch {
        c.fail("out of memory");
        return null;
    };
    st.* = .{ .c = c, .id = c.next_stream, .p = .{ .stream_window = c.peer_stream_window } };
    c.next_stream += 2;
    if (!sendRequestHeaders(c, st.id, path, meta, timeout_ms)) {
        gpa.destroy(st);
        return null;
    }
    c.stream_active = true;
    return st;
}

fn streamSend(st: *Stream, msg: []const u8) bool {
    const c = st.c;
    if (!c.ok or st.send_closed or st.p.done) {
        if (c.ok) c.setErr("the stream cannot send any more messages");
        return false;
    }
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(gpa);
    if (!appendFramed(c, &body, msg)) return false;
    return sendBody(c, st.id, &st.p, &st.r, body.items, false);
}

fn streamCloseSend(st: *Stream) bool {
    const c = st.c;
    if (!c.ok) return false;
    if (st.send_closed) return true;
    st.send_closed = true;
    if (st.p.done) return true;
    return c.sendFrame(h2.frame_data, h2.flag_end_stream, st.id, &.{});
}

/// Sıradaki yanıt mesajı; yoksa akış bitene kadar kare okur. Dönüş: `1` mesaj hazır (`out`), `0` akış bitti (durum kesinleşti), `-1` taşıma hatası.
fn streamRecv(st: *Stream) i32 {
    const c = st.c;
    while (st.taken >= st.r.msgs.items.len) {
        if (st.p.done) {
            if (!st.finalized) {
                _ = finalizeResult(c, &st.p, &st.r);
                st.finalized = true;
                c.stream_active = false;
            }
            return 0;
        }
        if (!pumpFrame(c, st.id, &st.p, &st.r)) return -1;
    }
    return 1;
}

/// Düz TCP (h2c, önceden bilinen) bağlantı açar: ön ek + boş SETTINGS gönderir. Başarısız olsa da geçerli bir tutamak döner (`status == 0`, `errmsg` dolu); yalnızca bellek
/// yetersizliğinde `null`.
pub export fn nox_grpc_open_raw(host: ?[*:0]const u8, port: i64) callconv(.c) ?*anyopaque {
    return openImpl(host, port, false, null);
}

/// TLS üzerinden (ALPN `h2`) bağlanır. `ca_file` doluysa (PEM) sistem deposu YERİNE yalnızca o dosyadaki CA'lara güvenilir; boşsa sistem CA deposu kullanılır. Sunucu adı (`host`)
/// sertifikaya karşı doğrulanır.
pub export fn nox_grpc_open_tls_raw(host: ?[*:0]const u8, port: i64, ca_file: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    return openImpl(host, port, true, ca_file);
}

fn openImpl(host: ?[*:0]const u8, port: i64, use_tls: bool, ca_file: ?[*:0]const u8) ?*anyopaque {
    const c = gpa.create(GConn) catch return null;
    const h = str_mod.nox_str_slice(host orelse "");
    const tc = tcp.connect(h, port, false) orelse {
        gpa.destroy(c);
        return null;
    };
    c.* = .{ .c = tc, .ok = tc.ok, .decoder = h2.Decoder.init(gpa, 4096), .tls = use_tls };
    if (!tc.ok) {
        c.setErr(if (tc.errmsg.len > 0) tc.errmsg else "could not connect");
        return c;
    }
    if (use_tls) {
        if (!tcp.startTlsEx(tc, h, true, if (ca_file) |p| str_mod.nox_str_slice(p) else "")) {
            c.fail(if (tc.errmsg.len > 0) tc.errmsg else "TLS handshake failed");
            return c;
        }
    }
    var buf: [64]u8 = undefined;
    c.authority = gpa.dupe(u8, std.fmt.bufPrint(&buf, "{s}:{d}", .{ h, port }) catch h) catch &.{};
    // Ön ek + SETTINGS (push kapalı, başlangıç penceremiz 1 MiB'a çıkar: büyük yanıtlarda WINDOW_UPDATE sayısı azalır).
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, PREFACE) catch {
        c.fail("out of memory");
        return c;
    };
    var settings: [12]u8 = undefined;
    std.mem.writeInt(u16, settings[0..2], h2.setting_enable_push, .big);
    std.mem.writeInt(u32, settings[2..6], 0, .big);
    std.mem.writeInt(u16, settings[6..8], h2.setting_initial_window_size, .big);
    std.mem.writeInt(u32, settings[8..12], 1 << 20, .big);
    h2.appendFrameHeader(&out, gpa, settings.len, h2.frame_settings, 0, 0) catch {
        c.fail("out of memory");
        return c;
    };
    out.appendSlice(gpa, &settings) catch {
        c.fail("out of memory");
        return c;
    };
    // Bağlantı penceresini de 1 MiB'a çıkar (varsayılan 65535 + artış).
    h2.appendFrameHeader(&out, gpa, 4, h2.frame_window_update, 0, 0) catch {
        c.fail("out of memory");
        return c;
    };
    var inc: [4]u8 = undefined;
    std.mem.writeInt(u32, &inc, (1 << 20) - h2.default_window, .big);
    out.appendSlice(gpa, &inc) catch {
        c.fail("out of memory");
        return c;
    };
    _ = c.send(out.items);
    return c;
}

/// Sonraki istek mesajlarını gzip ile sıkıştırmayı açar/kapatır (`grpc-encoding: gzip`). Yanıt sıkıştırması her zaman çözülür.
pub export fn nox_grpc_set_compress_raw(conn: ?*anyopaque, on: i64) callconv(.c) void {
    const c: *GConn = @ptrCast(@alignCast(conn orelse return));
    c.compress = on != 0;
}

pub export fn nox_grpc_status_raw(conn: ?*anyopaque) callconv(.c) i64 {
    const c: *GConn = @ptrCast(@alignCast(conn orelse return 0));
    return if (c.ok) 1 else 0;
}

pub export fn nox_grpc_errmsg_raw(rt: ?*anyopaque, conn: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const c: *GConn = @ptrCast(@alignCast(conn orelse return shim_util.dupeToNoxStr(rt, "")));
    return shim_util.dupeToNoxStr(rt, c.errmsg);
}

pub export fn nox_grpc_close_raw(conn: ?*anyopaque) callconv(.c) void {
    const c: *GConn = @ptrCast(@alignCast(conn orelse return));
    tcp.close(c.c);
    c.rbuf.deinit(gpa);
    c.decoder.deinit();
    if (c.authority.len > 0) gpa.free(c.authority);
    if (c.errmsg_owned) gpa.free(c.errmsg);
    gpa.destroy(c);
}

/// `path` (`/paket.Servis/Metot`), `meta` (`ad: değer` satırları, `\n` ayraçlı), `reqs` (list[str], her biri bir protobuf mesajı) ile çağrı yapar. `timeout_ms > 0` ise
/// `grpc-timeout` olarak sunucuya bildirilir. Taşıma/protokol hatasında `null` (bağlantı kullanılamaz olur, `errmsg` dolu).
pub export fn nox_grpc_call_raw(conn: ?*anyopaque, path: ?[*:0]const u8, meta: ?[*:0]const u8, reqs: ?*anyopaque, timeout_ms: i64) callconv(.c) ?*anyopaque {
    const c: *GConn = @ptrCast(@alignCast(conn orelse return null));
    const list = reqs orelse return null;
    const n = listLen(list);
    const msgs = gpa.alloc([]const u8, n) catch {
        c.fail("out of memory");
        return null;
    };
    defer gpa.free(msgs);
    for (msgs, 0..) |*m, i| m.* = listItem(list, i);
    return call(c, str_mod.nox_str_slice(path orelse ""), str_mod.nox_str_slice(meta orelse ""), msgs, timeout_ms);
}

fn asResult(r: ?*anyopaque) ?*Result {
    return @ptrCast(@alignCast(r orelse return null));
}

pub export fn nox_grpc_result_status_raw(r: ?*anyopaque) callconv(.c) i64 {
    return (asResult(r) orelse return STATUS_TRANSPORT).status;
}

pub export fn nox_grpc_result_message_raw(rt: ?*anyopaque, r: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const res = asResult(r) orelse return shim_util.dupeToNoxStr(rt, "");
    return shim_util.dupeToNoxStr(rt, res.message);
}

pub export fn nox_grpc_result_count_raw(r: ?*anyopaque) callconv(.c) i64 {
    return @intCast((asResult(r) orelse return 0).msgs.items.len);
}

pub export fn nox_grpc_result_at_raw(rt: ?*anyopaque, r: ?*anyopaque, i: i64) callconv(.c) ?[*:0]u8 {
    const res = asResult(r) orelse return shim_util.dupeToNoxStr(rt, "");
    if (i < 0 or @as(usize, @intCast(i)) >= res.msgs.items.len) return shim_util.dupeToNoxStr(rt, "");
    return shim_util.dupeToNoxStr(rt, res.msgs.items[@intCast(i)]);
}

/// Yanıt üst verisi (başlık ve trailer); `name` küçük harfle aranır, ilk eşleşme döner, yoksa boş dize.
pub export fn nox_grpc_result_header_raw(rt: ?*anyopaque, r: ?*anyopaque, name: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const res = asResult(r) orelse return shim_util.dupeToNoxStr(rt, "");
    var buf: [128]u8 = undefined;
    const nm = str_mod.nox_str_slice(name orelse "");
    if (nm.len == 0 or nm.len > buf.len) return shim_util.dupeToNoxStr(rt, "");
    for (nm, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return shim_util.dupeToNoxStr(rt, headerValue(res, buf[0..nm.len]) orelse "");
}

pub export fn nox_grpc_result_free_raw(r: ?*anyopaque) callconv(.c) void {
    const res = asResult(r) orelse return;
    res.deinit();
    gpa.destroy(res);
}

pub export fn nox_grpc_is_null_raw(p: ?*anyopaque) callconv(.c) i64 {
    return if (p == null) 1 else 0;
}

pub export fn nox_grpc_stream_open_raw(conn: ?*anyopaque, path: ?[*:0]const u8, meta: ?[*:0]const u8, timeout_ms: i64) callconv(.c) ?*anyopaque {
    const c: *GConn = @ptrCast(@alignCast(conn orelse return null));
    return streamOpen(c, str_mod.nox_str_slice(path orelse ""), str_mod.nox_str_slice(meta orelse ""), timeout_ms);
}

fn asStream(p: ?*anyopaque) ?*Stream {
    return @ptrCast(@alignCast(p orelse return null));
}

/// `1` başarılı, `0` hata (bağlantı kullanılamaz olabilir; `nox_grpc_errmsg_raw`).
pub export fn nox_grpc_stream_send_raw(st: ?*anyopaque, msg: ?[*:0]const u8) callconv(.c) i64 {
    const s = asStream(st) orelse return 0;
    return if (streamSend(s, str_mod.nox_str_slice(msg orelse ""))) 1 else 0;
}

pub export fn nox_grpc_stream_close_send_raw(st: ?*anyopaque) callconv(.c) i64 {
    const s = asStream(st) orelse return 0;
    return if (streamCloseSend(s)) 1 else 0;
}

/// Sıradaki yanıt mesajına bekler: `1` hazır (`nox_grpc_stream_take_raw` ile alınır), `0` akış bitti, `-1` taşıma hatası.
pub export fn nox_grpc_stream_wait_raw(st: ?*anyopaque) callconv(.c) i64 {
    const s = asStream(st) orelse return -1;
    return streamRecv(s);
}

pub export fn nox_grpc_stream_take_raw(rt: ?*anyopaque, st: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const s = asStream(st) orelse return shim_util.dupeToNoxStr(rt, "");
    if (s.taken >= s.r.msgs.items.len) return shim_util.dupeToNoxStr(rt, "");
    const m = s.r.msgs.items[s.taken];
    s.taken += 1;
    return shim_util.dupeToNoxStr(rt, m);
}

pub export fn nox_grpc_stream_status_raw(st: ?*anyopaque) callconv(.c) i64 {
    return (asStream(st) orelse return STATUS_TRANSPORT).r.status;
}

pub export fn nox_grpc_stream_message_raw(rt: ?*anyopaque, st: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const s = asStream(st) orelse return shim_util.dupeToNoxStr(rt, "");
    return shim_util.dupeToNoxStr(rt, s.r.message);
}

pub export fn nox_grpc_stream_header_raw(rt: ?*anyopaque, st: ?*anyopaque, name: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const s = asStream(st) orelse return shim_util.dupeToNoxStr(rt, "");
    var buf: [128]u8 = undefined;
    const nm = str_mod.nox_str_slice(name orelse "");
    if (nm.len == 0 or nm.len > buf.len) return shim_util.dupeToNoxStr(rt, "");
    for (nm, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return shim_util.dupeToNoxStr(rt, headerValue(&s.r, buf[0..nm.len]) orelse "");
}

/// Akışı bırakır. Hâlâ açıksa (bitmeden) iptal için `RST_STREAM` (CANCEL) gönderir ve bağlantıyı yeni çağrılara açar; sunucu akışın geç kareleri `pumpFrame`de yok sayılır.
pub export fn nox_grpc_stream_free_raw(st: ?*anyopaque) callconv(.c) void {
    const s = asStream(st) orelse return;
    const c = s.c;
    if (!s.p.done and c.ok) {
        var code: [4]u8 = undefined;
        std.mem.writeInt(u32, &code, @intFromEnum(h2.ErrorCode.cancel), .big);
        _ = c.sendFrame(h2.frame_rst_stream, 0, s.id, &code);
    }
    c.stream_active = false;
    s.r.deinit();
    s.p.data.deinit(gpa);
    s.p.header_block.deinit(gpa);
    gpa.destroy(s);
}

test "percentDecode çözer ve bozuk dizileri olduğu gibi bırakır" {
    const a = try percentDecode("hello%20world%0A%zz%");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("hello world\n%zz%", a);
}
