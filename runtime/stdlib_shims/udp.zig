//! `nox.udp` — UDP datagram soketleri (Pulse NOX-CAP-UDP-001): telemetri (statsd/syslog/OTLP-UDP), keşif ve basit RPC için.
//!
//! Yalnızca POSIX (macOS/Linux/Android/iOS) ham libc soketleri; Windows, wasm ve freestanding'de `nox_udp_supported_raw` 0 döner ve `open` hata durumlu bir tutamak verir.
//! Soket her zaman bloklamayan modda açılır: `recv` bir fiber içinde zamanlayıcıyı BLOKE ETMEZ (fiber reaktörde askıya alınır), fiber dışında `poll` ile bekler.
//! `send_to` adı `getaddrinfo` ile çözer (bloklayıcı DNS); IP sabitleri ve `localhost` anında çözülür. Adres ailesi `open` anında seçilir (IPv4 ya da IPv6); farklı ailedeki hedef hata verir.
//! Veri bayt-tamdır (`nox_str_from_bytes`: uzunluk başlıklı, NUL içerebilir). Durum tutamak başına tutulur (global/threadlocal yok).

const std = @import("std");
const builtin = @import("builtin");
const str_mod = @import("../str.zig");
const shim_util = @import("shim_util.zig");
const fiber_net = @import("fiber_net.zig");

const supported = switch (builtin.os.tag) {
    .windows, .freestanding, .wasi, .other => false,
    else => !builtin.cpu.arch.isWasm(),
};

const gpa = std.heap.page_allocator;

/// Windows'ta `fd_t` bir tutamaktır; orada hiçbir soket açılmaz, yalnızca `-1` saklanır.
const Fd = if (supported) std.c.fd_t else i32;

const MAX_DATAGRAM: usize = 65507;

const Sock = struct {
    fd: Fd = -1,
    family: c_uint = 0,
    err: [160]u8 = undefined,
    err_len: usize = 0,
    peer_host: [64]u8 = undefined,
    peer_host_len: usize = 0,
    peer_port: i64 = 0,
    /// Son `recv`: 0 tamam, 1 zaman aşımı, 2 hata.
    recv_status: i64 = 0,

    fn setErr(self: *Sock, msg: []const u8) void {
        const n = @min(msg.len, self.err.len);
        @memcpy(self.err[0..n], msg[0..n]);
        self.err_len = n;
    }

    fn setErrno(self: *Sock, what: []const u8, e: std.c.E) void {
        var buf: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s}: {s}", .{ what, @tagName(e) }) catch what;
        self.setErr(msg);
    }
};

const Resolved = struct { storage: std.c.sockaddr.storage = undefined, len: std.c.socklen_t = 0 };

fn resolve(host: ?[*:0]const u8, port: u16, family: c_uint, passive: bool) ?Resolved {
    var service_buf: [8]u8 = undefined;
    const service = std.fmt.bufPrintZ(&service_buf, "{d}", .{port}) catch return null;
    var hints = std.mem.zeroes(std.c.addrinfo);
    hints.family = @intCast(family);
    hints.socktype = std.c.SOCK.DGRAM;
    if (passive) hints.flags.PASSIVE = true;
    var list: ?*std.c.addrinfo = null;
    if (@intFromEnum(std.c.getaddrinfo(host, service.ptr, &hints, &list)) != 0) return null;
    defer if (list) |l| std.c.freeaddrinfo(l);
    var it = list;
    while (it) |ai| : (it = ai.next) {
        const sa = ai.addr orelse continue;
        if (@as(c_uint, @intCast(ai.family)) != family) continue;
        if (ai.addrlen > @sizeOf(std.c.sockaddr.storage)) continue;
        var r: Resolved = .{};
        const src: [*]const u8 = @ptrCast(sa);
        const dst: [*]u8 = @ptrCast(&r.storage);
        @memcpy(dst[0..ai.addrlen], src[0..ai.addrlen]);
        r.len = ai.addrlen;
        return r;
    }
    return null;
}

fn setNonBlocking(fd: std.c.fd_t) void {
    const current = std.c.fcntl(fd, std.c.F.GETFL);
    if (current < 0) return;
    var flags: std.c.O = @bitCast(@as(u32, @intCast(current)));
    flags.NONBLOCK = true;
    _ = std.c.fcntl(fd, std.c.F.SETFL, @as(u32, @bitCast(flags)));
}

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Soket okunabilir olana ya da `timeout_ms` dolana dek bekler (`< 0`: sınırsız). `false`: zaman aşımı.
fn waitReadable(fd: std.c.fd_t, timeout_ms: i64) bool {
    if (fiber_net.inFiber()) {
        const t: ?u32 = if (timeout_ms < 0) null else @intCast(@min(@max(timeout_ms, 1), std.math.maxInt(i32)));
        return fiber_net.waitFd(fd, false, t) == .ready;
    }
    var pfd = [1]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
    const ms: c_int = if (timeout_ms < 0) -1 else @intCast(@min(timeout_ms, std.math.maxInt(i32)));
    return std.c.poll(&pfd, 1, ms) > 0;
}

fn peerToText(s: *Sock, sa: *const std.c.sockaddr.storage, len: std.c.socklen_t) void {
    s.peer_host_len = 0;
    s.peer_port = 0;
    var host: [64]u8 = undefined;
    var serv: [16]u8 = undefined;
    const rc = std.c.getnameinfo(@ptrCast(sa), len, &host, host.len, &serv, serv.len, .{ .NUMERICHOST = true, .NUMERICSERV = true });
    if (@intFromEnum(rc) != 0) return;
    const hl = std.mem.indexOfScalar(u8, &host, 0) orelse host.len;
    @memcpy(s.peer_host[0..hl], host[0..hl]);
    s.peer_host_len = hl;
    const sl = std.mem.indexOfScalar(u8, &serv, 0) orelse serv.len;
    s.peer_port = std.fmt.parseInt(i64, serv[0..sl], 10) catch 0;
}

/// 1 = nox.udp bu makinede kullanılabilir.
pub export fn nox_udp_supported_raw() callconv(.c) i64 {
    return if (supported) 1 else 0;
}

/// `host:port`a bağlı (bind) bir UDP soketi açar. `host` boş/null: tüm arayüzler. `port` 0: işletim sistemi seçer. `flags`: bit0 = IPv6, bit1 = SO_REUSEADDR(+REUSEPORT), bit2 = SO_BROADCAST.
/// Başarısız olsa da GEÇERLİ bir tutamak döner (`nox_udp_errmsg_raw` boş değil); yalnızca bellek yetersizliğinde `null`.
pub export fn nox_udp_open_raw(host: ?[*:0]const u8, port: i64, flags: i64) callconv(.c) ?*anyopaque {
    const s = gpa.create(Sock) catch return null;
    s.* = .{};
    if (comptime !supported) {
        s.setErr("nox.udp is not supported on this target");
        return s;
    }
    if (port < 0 or port > 65535) {
        s.setErr("invalid port");
        return s;
    }
    const family: c_uint = if (flags & 1 != 0) std.c.AF.INET6 else std.c.AF.INET;
    s.family = family;
    var node: ?[*:0]const u8 = null;
    if (host) |h| {
        if (str_mod.nox_str_slice(h).len > 0) node = h;
    }
    const addr = resolve(node, @intCast(port), family, true) orelse {
        s.setErr("could not resolve the bind address");
        return s;
    };
    const fd = std.c.socket(family, std.c.SOCK.DGRAM, 0);
    if (fd < 0) {
        s.setErrno("socket", std.posix.errno(fd));
        return s;
    }
    _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, 1)); // FD_CLOEXEC
    setNonBlocking(fd);
    var one: c_int = 1;
    if (flags & 2 != 0) {
        _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &one, @sizeOf(c_int));
        if (@hasDecl(std.c.SO, "REUSEPORT")) _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEPORT, &one, @sizeOf(c_int));
    }
    if (flags & 4 != 0) _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.BROADCAST, &one, @sizeOf(c_int));
    if (family == std.c.AF.INET6) {
        var zero: c_int = 0; // çift yığın: IPv4-eşlemeli adresler de gelsin
        _ = std.c.setsockopt(fd, 41, 26, &zero, @sizeOf(c_int)); // IPPROTO_IPV6 / IPV6_V6ONLY
    }
    if (std.c.bind(fd, @ptrCast(&addr.storage), addr.len) != 0) {
        s.setErrno("bind", std.posix.errno(@as(c_int, -1)));
        _ = std.c.close(fd);
        return s;
    }
    s.fd = fd;
    return s;
}

/// Tutamak durumu: -1 `null` (bellek yetersiz), 0 hata durumlu (soket yok), 1 hazır.
pub export fn nox_udp_ok_raw(h: ?*anyopaque) callconv(.c) i64 {
    const s: *Sock = @ptrCast(@alignCast(h orelse return -1));
    return if (s.fd >= 0) 1 else 0;
}

/// Hata iletisi (başarılıysa boş dize).
pub export fn nox_udp_errmsg_raw(rt: ?*anyopaque, h: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const s: *Sock = @ptrCast(@alignCast(h orelse return shim_util.dupeToNoxStr(rt, "")));
    return shim_util.dupeToNoxStr(rt, s.err[0..s.err_len]);
}

/// Soketin yerel portu (`bind` portu 0 ise işletim sisteminin seçtiği); hata: 0.
pub export fn nox_udp_local_port_raw(h: ?*anyopaque) callconv(.c) i64 {
    if (comptime !supported) return 0;
    const s: *Sock = @ptrCast(@alignCast(h orelse return 0));
    if (s.fd < 0) return 0;
    var st: std.c.sockaddr.storage = undefined;
    var len: std.c.socklen_t = @sizeOf(std.c.sockaddr.storage);
    if (std.c.getsockname(s.fd, @ptrCast(&st), &len) != 0) return 0;
    var serv: [16]u8 = undefined;
    if (@intFromEnum(std.c.getnameinfo(@ptrCast(&st), len, null, 0, &serv, serv.len, .{ .NUMERICHOST = true, .NUMERICSERV = true })) != 0) return 0;
    const sl = std.mem.indexOfScalar(u8, &serv, 0) orelse serv.len;
    return std.fmt.parseInt(i64, serv[0..sl], 10) catch 0;
}

/// `data` baytlarını `host:port`a tek bir datagram olarak gönderir. Başarıda gönderilen bayt sayısı, hatada -1 (`nox_udp_errmsg_raw`).
pub export fn nox_udp_send_raw(h: ?*anyopaque, host: ?[*:0]const u8, port: i64, data: ?[*:0]const u8) callconv(.c) i64 {
    if (comptime !supported) return -1;
    const s: *Sock = @ptrCast(@alignCast(h orelse return -1));
    s.err_len = 0;
    if (s.fd < 0) {
        s.setErr("socket is closed");
        return -1;
    }
    if (port <= 0 or port > 65535) {
        s.setErr("invalid port");
        return -1;
    }
    const bytes = str_mod.nox_str_slice(data orelse {
        s.setErr("data is null");
        return -1;
    });
    if (bytes.len > MAX_DATAGRAM) {
        s.setErr("datagram too large (limit 65507 bytes)");
        return -1;
    }
    const dst = resolve(host, @intCast(port), s.family, false) orelse {
        s.setErr("could not resolve the destination (or its address family differs from the socket's)");
        return -1;
    };
    while (true) {
        const n = std.c.sendto(s.fd, bytes.ptr, bytes.len, 0, @ptrCast(&dst.storage), dst.len);
        if (n >= 0) return @intCast(n);
        const e = std.posix.errno(n);
        if (e == .INTR) continue;
        if (e == .AGAIN) {
            // Gönderme arabelleği dolu: yazılabilir olana dek kısa bekle (UDP'de nadir).
            if (fiber_net.inFiber()) {
                _ = fiber_net.waitFd(s.fd, true, 1000);
            } else {
                var pfd = [1]std.c.pollfd{.{ .fd = s.fd, .events = std.c.POLL.OUT, .revents = 0 }};
                _ = std.c.poll(&pfd, 1, 1000);
            }
            continue;
        }
        s.setErrno("sendto", e);
        return -1;
    }
}

/// Bir datagram alır (en çok `max_len` bayt; fazlası atılır). `timeout_ms`: < 0 sınırsız, 0 yoklama. Zaman aşımı/hata: `null` ve `nox_udp_recv_status_raw` 1/2.
pub export fn nox_udp_recv_raw(rt: ?*anyopaque, h: ?*anyopaque, max_len: i64, timeout_ms: i64) callconv(.c) ?[*:0]u8 {
    if (comptime !supported) return null;
    const s: *Sock = @ptrCast(@alignCast(h orelse return null));
    s.err_len = 0;
    s.recv_status = 2;
    if (s.fd < 0) {
        s.setErr("socket is closed");
        return null;
    }
    const cap: usize = @intCast(@min(@max(max_len, 1), @as(i64, MAX_DATAGRAM)));
    const buf = gpa.alloc(u8, cap) catch {
        s.setErr("out of memory");
        return null;
    };
    defer gpa.free(buf);
    const deadline: i64 = if (timeout_ms < 0) -1 else nowMs() + timeout_ms;
    while (true) {
        var st: std.c.sockaddr.storage = undefined;
        var len: std.c.socklen_t = @sizeOf(std.c.sockaddr.storage);
        const n = std.c.recvfrom(s.fd, buf.ptr, buf.len, 0, @ptrCast(&st), &len);
        if (n >= 0) {
            peerToText(s, &st, len);
            s.recv_status = 0;
            return shim_util.dupeToNoxStr(rt, buf[0..@intCast(n)]);
        }
        const e = std.posix.errno(n);
        if (e == .INTR) continue;
        if (e == .AGAIN) {
            const remaining: i64 = if (deadline < 0) -1 else deadline - nowMs();
            if (deadline >= 0 and remaining <= 0) {
                s.recv_status = 1;
                return null;
            }
            if (!waitReadable(s.fd, remaining)) {
                s.recv_status = 1;
                return null;
            }
            continue;
        }
        s.setErrno("recvfrom", e);
        return null;
    }
}

/// Son `nox_udp_recv_raw`: 0 tamam, 1 zaman aşımı, 2 hata.
pub export fn nox_udp_recv_status_raw(h: ?*anyopaque) callconv(.c) i64 {
    const s: *Sock = @ptrCast(@alignCast(h orelse return 2));
    return s.recv_status;
}

/// Son alınan datagramın gönderici adresi (sayısal metin).
pub export fn nox_udp_peer_host_raw(rt: ?*anyopaque, h: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const s: *Sock = @ptrCast(@alignCast(h orelse return shim_util.dupeToNoxStr(rt, "")));
    return shim_util.dupeToNoxStr(rt, s.peer_host[0..s.peer_host_len]);
}

pub export fn nox_udp_peer_port_raw(h: ?*anyopaque) callconv(.c) i64 {
    const s: *Sock = @ptrCast(@alignCast(h orelse return 0));
    return s.peer_port;
}

/// Soketi kapatır ve tutamağı serbest bırakır (çift çağrı güvenli değildir: Nox tarafı tutamağı sıfırlar).
pub export fn nox_udp_close_raw(h: ?*anyopaque) callconv(.c) void {
    const s: *Sock = @ptrCast(@alignCast(h orelse return));
    if (comptime supported) {
        if (s.fd >= 0) _ = std.c.close(s.fd);
    }
    gpa.destroy(s);
}
