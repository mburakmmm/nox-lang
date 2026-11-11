//! WASM'da ham TCP (spec §3.357): `wasm32-freestanding --asyncify` + host TCP yeteneği (`nox_host_caps_set(2)`). Host (`wasm_host.mjs`: Node `net`/`tls`; tarayıcıda yok) bağlantıları yönetir;
//! TLS HOST'ta sonlanır (`tls: true` ile açma ya da `starttls` ile yükseltme), yani CA paketi/handshake modülün içinde değildir. Mekanizma `http_fetch.zig` ile aynı istek tablosudur
//! (`kind` 8 açma, 9 yazma (yanıtsız), 10 okuma, 11 STARTTLS, 12 kapatma (yanıtsız)). `smtp` ve `tls` modüllerinin WASM sürümleri (`tcp_modules_wasm.zig`) bunun üstündedir.

const std = @import("std");
const wasm_options = @import("wasm_options");
const str_mod = @import("../str.zig");

pub const enabled = @import("../wasm_host.zig").is_freestanding_wasm and wasm_options.asyncify and !wasm_options.threads;
const fetch = if (enabled) @import("http_fetch.zig") else struct {};

const gpa = std.heap.page_allocator;

pub const no_capability = "the 'tcp' capability is not available on this host (raw TCP needs wasm32-freestanding --asyncify and a host-provided TCP implementation, e.g. Node; browsers cannot open raw sockets; see docs/tools/wasm.md)";

pub const Conn = struct {
    ok: bool = false,
    id: u32 = 0,
    eof: bool = false,
    errmsg: []const u8 = "",
    errmsg_owned: bool = false,
    /// Okunmuş ama henüz verilmemiş baytlar.
    buf: std.ArrayListUnmanaged(u8) = .empty,
    off: usize = 0,
    use_tls: bool = false,

    pub fn setErr(self: *Conn, msg: []const u8) void {
        if (self.errmsg_owned) gpa.free(self.errmsg);
        if (gpa.dupe(u8, msg)) |d| {
            self.errmsg = d;
            self.errmsg_owned = true;
        } else |_| {
            self.errmsg = "out of memory";
            self.errmsg_owned = false;
        }
    }
};

/// Bağlantı kurar. Başarısız olsa da GEÇERLİ bir `Conn` döner (`ok == false`, `errmsg` dolu); yalnızca bellek yetersizliğinde `null`. `tls`: bağlantı anında TLS (host sonlandırır).
pub fn connect(host: []const u8, port: i64, tls: bool) ?*Conn {
    const c = gpa.create(Conn) catch return null;
    c.* = .{};
    if (comptime !enabled) {
        c.errmsg = no_capability;
        return c;
    }
    if (!fetch.tcpAvailable()) {
        c.errmsg = no_capability;
        return c;
    }
    const target = std.fmt.allocPrint(gpa, "{s}:{d}", .{ host, port }) catch {
        c.errmsg = "out of memory";
        return c;
    };
    defer gpa.free(target);
    const req = fetch.submit(.{ .kind = .tcp_open, .url = target, .method = if (tls) "tls" else "" }, false) orelse {
        c.errmsg = "out of memory";
        return c;
    };
    const id = req.id;
    const resp = fetch.waitFor(req) orelse {
        c.errmsg = "out of memory";
        return c;
    };
    defer fetch.responseFree(resp);
    if (!resp.ok) {
        c.setErr(if (resp.body.len > 0) resp.body else "connection failed");
        return c;
    }
    c.id = id;
    c.ok = true;
    c.use_tls = tls;
    return c;
}

/// Yazar (yanıtsız; hata sonraki okumada görünür). Başarıda `true`.
pub fn write(c: *Conn, data: []const u8) bool {
    if (comptime !enabled) return false;
    if (!c.ok or data.len == 0) return c.ok;
    _ = fetch.submit(.{ .kind = .tcp_write, .stream = c.id, .body = data }, true) orelse {
        c.setErr("out of memory");
        return false;
    };
    return true;
}

/// Host'tan bir parça daha çeker (en az 1 bayt, ya da EOF/hata). `true`: tamponda veri var.
fn fill(c: *Conn) bool {
    if (comptime !enabled) return false;
    if (c.eof or !c.ok) return false;
    c.buf.clearRetainingCapacity();
    c.off = 0;
    const req = fetch.submit(.{ .kind = .tcp_read, .stream = c.id, .arg = 64 * 1024 }, false) orelse {
        c.setErr("out of memory");
        c.ok = false;
        return false;
    };
    const resp = fetch.waitFor(req) orelse {
        c.setErr("out of memory");
        c.ok = false;
        return false;
    };
    defer fetch.responseFree(resp);
    if (!resp.ok) {
        c.setErr(if (resp.body.len > 0) resp.body else "read failed");
        c.ok = false;
        return false;
    }
    if (resp.status == 1 or resp.body.len == 0) {
        c.eof = true;
        return false;
    }
    c.buf.appendSlice(gpa, resp.body) catch {
        c.setErr("out of memory");
        c.ok = false;
        return false;
    };
    return true;
}

/// En çok `max` bayt döner (en az bir bayt gelene kadar bekler); EOF'ta boş dilim. Dilim bir sonraki okumaya kadar geçerlidir.
pub fn readSome(c: *Conn, max: usize) []const u8 {
    if (c.off >= c.buf.items.len and !fill(c)) return &.{};
    const take = @min(max, c.buf.items.len - c.off);
    const out = c.buf.items[c.off .. c.off + take];
    c.off += take;
    return out;
}

/// Bir satır okur (`\n` dahil bitişe kadar; sondaki `\r\n` kırpılır). EOF ya da hata'da `null`. Dönen dilim `gpa` ile tahsislidir (çağıran serbest bırakır).
pub fn readLine(c: *Conn) ?[]u8 {
    var line: std.ArrayListUnmanaged(u8) = .empty;
    while (true) {
        if (c.off >= c.buf.items.len and !fill(c)) {
            line.deinit(gpa);
            return null;
        }
        const chunk = c.buf.items[c.off..];
        if (std.mem.indexOfScalar(u8, chunk, '\n')) |nl| {
            line.appendSlice(gpa, chunk[0 .. nl + 1]) catch {
                line.deinit(gpa);
                return null;
            };
            c.off += nl + 1;
            const trimmed = std.mem.trimEnd(u8, line.items, "\r\n");
            const out = gpa.dupe(u8, trimmed) catch {
                line.deinit(gpa);
                return null;
            };
            line.deinit(gpa);
            return out;
        }
        line.appendSlice(gpa, chunk) catch {
            line.deinit(gpa);
            return null;
        };
        c.off = c.buf.items.len;
    }
}

/// Mevcut düz bağlantıyı host'ta TLS'e yükseltir (`servername`: SNI + sertifika doğrulaması). Başarıda `true`.
pub fn startTls(c: *Conn, servername: []const u8) bool {
    if (comptime !enabled) return false;
    if (!c.ok or c.use_tls) return false;
    // Yükseltme öncesi tamponlanmış düz metin kalmamalıdır (STARTTLS el sıkışmasından sonra sunucu yanıt beklemez).
    c.buf.clearRetainingCapacity();
    c.off = 0;
    const req = fetch.submit(.{ .kind = .tcp_starttls, .stream = c.id, .url = servername }, false) orelse {
        c.setErr("out of memory");
        return false;
    };
    const resp = fetch.waitFor(req) orelse {
        c.setErr("out of memory");
        return false;
    };
    defer fetch.responseFree(resp);
    if (!resp.ok) {
        c.setErr(if (resp.body.len > 0) resp.body else "TLS upgrade failed");
        return false;
    }
    c.use_tls = true;
    return true;
}

/// `startTls` + isteğe bağlı ALPN `h2`, özel CA ve istemci sertifikası (v2.1.44). `ca_file`/`cert_file`/`key_file` ana makine (Node) dosya sistemindeki PEM yollarıdır: TLS host'ta
/// sonlandığından dosyaları host okur ve yalnızca host izin verdiyse (`nodeTcp({ tlsFiles: true })`) kabul eder; tarayıcıda ham soket (dolayısıyla TLS) yoktur.
pub fn startTlsEx(c: *Conn, servername: []const u8, alpn_h2: bool, ca_file: []const u8) bool {
    return startTlsMtls(c, servername, alpn_h2, ca_file, "", "");
}

pub fn startTlsMtls(c: *Conn, servername: []const u8, alpn_h2: bool, ca_file: []const u8, cert_file: []const u8, key_file: []const u8) bool {
    if (comptime !enabled) return false;
    if (!c.ok or c.use_tls) return false;
    c.buf.clearRetainingCapacity();
    c.off = 0;
    // Seçenekler `Ad=değer\n` satırlarıdır (`headers` alanı): alpn, ca, cert, key.
    var opts: std.ArrayListUnmanaged(u8) = .empty;
    defer opts.deinit(gpa);
    const parts = [_]struct { k: []const u8, v: []const u8 }{ .{ .k = "alpn", .v = if (alpn_h2) "h2" else "" }, .{ .k = "ca", .v = ca_file }, .{ .k = "cert", .v = cert_file }, .{ .k = "key", .v = key_file } };
    for (parts) |kv| {
        if (kv.v.len == 0) continue;
        if (std.mem.indexOfScalar(u8, kv.v, '\n') != null) {
            c.setErr("invalid TLS option value");
            return false;
        }
        opts.appendSlice(gpa, kv.k) catch return oom(c);
        opts.append(gpa, '=') catch return oom(c);
        opts.appendSlice(gpa, kv.v) catch return oom(c);
        opts.append(gpa, '\n') catch return oom(c);
    }
    const req = fetch.submit(.{ .kind = .tcp_starttls, .stream = c.id, .url = servername, .headers_text = opts.items }, false) orelse return oom(c);
    const resp = fetch.waitFor(req) orelse return oom(c);
    defer fetch.responseFree(resp);
    if (!resp.ok) {
        c.setErr(if (resp.body.len > 0) resp.body else "TLS upgrade failed");
        return false;
    }
    c.use_tls = true;
    return true;
}

fn oom(c: *Conn) bool {
    c.setErr("out of memory");
    return false;
}

pub fn close(c: *Conn) void {
    if (comptime enabled) {
        if (c.ok and c.id != 0) _ = fetch.submit(.{ .kind = .tcp_close, .stream = c.id }, true);
    }
    c.buf.deinit(gpa);
    if (c.errmsg_owned) gpa.free(c.errmsg);
    gpa.destroy(c);
}
