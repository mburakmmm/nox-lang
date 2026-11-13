//! QUIC taşıma katmanı (HTTP/3'ün altı) — OpenSSL >= 3.5'in QUIC API'sine ÇALIŞMA ZAMANINDA (`std.DynLib`, TEMBEL) bağlanarak (TODO 5.4, kullanıcı
//! kararı 2026-11-13: "OpenSSL QUIC (dlopen) + kendi h3/QPACK"). `tls_server.zig` ve `sqlite.zig` ile AYNI desen: harici derleme-zamanı bağımlılığı yok; kütüphane
//! yoksa ya da QUIC sembolleri yoksa (OpenSSL < 3.5) `available()` false döner ve h3 temiz bir hatayla "desteklenmiyor" der.
//!
//! Soket G/Ç'sini OpenSSL KENDİ yapar (`BIO_new_dgram`, bloklamayan kip); biz yalnızca beklemeyi fiber reaktörüne devrederiz: `wait` UDP fd'sinin okunabilirliğini
//! VEYA `SSL_get_event_timeout`un bildirdiği süreyi bekler ve `SSL_handle_events` ile QUIC makinesini ilerletir. Bir QUIC bağlantısının (ve ondan türeyen akışların)
//! TÜM OpenSSL çağrıları TEK bir sahibin (çağıran fiber'ın) elindedir: OpenSSL nesneleri bu katmanda eşzamanlı kullanılmaz (sunucu motoru bunu `h3_server`de
//! sahip-fiber + kuyruk ile sağlar).
//!
//! Kapsam: yalnızca POSIX (macOS/Linux). Windows/wasm/freestanding'de `supported` false. Tüm tutamaklar opaktır (`?*anyopaque`); İlke 4 (opak tutamaç) korunur.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const fiber_net = @import("fiber_net.zig");

/// QUIC yalnızca POSIX masaüstünde derlenir/çalışır.
pub const supported = switch (builtin.os.tag) {
    .macos, .linux => !builtin.cpu.arch.isWasm(),
    else => false,
};

pub const Error = error{ Unsupported, LibraryUnavailable, CtxFailed, CertFailed, KeyFailed, SocketFailed, ListenFailed, ConnectFailed, StreamFailed, Timeout, Closed, Failed };

const Opaque = ?*anyopaque;

// ---- OpenSSL C ABI (tamamen opak işaretçiler + sabit manifest değerleri) -------------------------------------------------------------------------------------

const PollDesc = extern struct {
    type: u32,
    value: extern union { fd: c_int, custom: ?*anyopaque, custom_ex: usize },
};
const POLL_SOCK_FD: u32 = 1;

const ShutdownArgs = extern struct { quic_error_code: u64, quic_reason: ?[*:0]const u8 };

const AlpnSelectCb = *const fn (ssl: Opaque, out: *?[*]const u8, outlen: *u8, in: [*]const u8, inlen: c_uint, arg: ?*anyopaque) callconv(.c) c_int;

/// Alan adları C sembol adlarıyla BİREBİR aynıdır (`loadAll` alan alan `lookup` yapar).
const Funcs = struct {
    OSSL_QUIC_server_method: *const fn () callconv(.c) Opaque,
    OSSL_QUIC_client_method: *const fn () callconv(.c) Opaque,
    SSL_CTX_new: *const fn (m: Opaque) callconv(.c) Opaque,
    SSL_CTX_free: *const fn (c: Opaque) callconv(.c) void,
    SSL_CTX_use_certificate_chain_file: *const fn (c: Opaque, p: [*:0]const u8) callconv(.c) c_int,
    SSL_CTX_use_PrivateKey_file: *const fn (c: Opaque, p: [*:0]const u8, t: c_int) callconv(.c) c_int,
    SSL_CTX_check_private_key: *const fn (c: Opaque) callconv(.c) c_int,
    SSL_CTX_set_alpn_select_cb: *const fn (c: Opaque, cb: AlpnSelectCb, arg: ?*anyopaque) callconv(.c) void,
    SSL_CTX_set_verify: *const fn (c: Opaque, mode: c_int, cb: ?*anyopaque) callconv(.c) void,
    SSL_CTX_load_verify_locations: *const fn (c: Opaque, file: ?[*:0]const u8, dir: ?[*:0]const u8) callconv(.c) c_int,
    SSL_CTX_set_default_verify_paths: *const fn (c: Opaque) callconv(.c) c_int,
    SSL_new: *const fn (c: Opaque) callconv(.c) Opaque,
    SSL_new_listener: *const fn (c: Opaque, flags: u64) callconv(.c) Opaque,
    SSL_free: *const fn (s: Opaque) callconv(.c) void,
    SSL_set_bio: *const fn (s: Opaque, r: Opaque, w: Opaque) callconv(.c) void,
    SSL_listen: *const fn (s: Opaque) callconv(.c) c_int,
    SSL_accept_connection: *const fn (s: Opaque, flags: u64) callconv(.c) Opaque,
    SSL_accept_stream: *const fn (s: Opaque, flags: u64) callconv(.c) Opaque,
    SSL_new_stream: *const fn (s: Opaque, flags: u64) callconv(.c) Opaque,
    SSL_set_blocking_mode: *const fn (s: Opaque, blocking: c_int) callconv(.c) c_int,
    SSL_set_default_stream_mode: *const fn (s: Opaque, mode: u32) callconv(.c) c_int,
    SSL_set1_initial_peer_addr: *const fn (s: Opaque, a: Opaque) callconv(.c) c_int,
    SSL_set_alpn_protos: *const fn (s: Opaque, p: [*]const u8, n: c_uint) callconv(.c) c_int,
    SSL_set1_host: *const fn (s: Opaque, name: [*:0]const u8) callconv(.c) c_int,
    SSL_ctrl: *const fn (s: Opaque, cmd: c_int, larg: c_long, parg: ?*anyopaque) callconv(.c) c_long,
    SSL_connect: *const fn (s: Opaque) callconv(.c) c_int,
    SSL_get_error: *const fn (s: Opaque, ret: c_int) callconv(.c) c_int,
    SSL_get_rpoll_descriptor: *const fn (s: Opaque, d: *PollDesc) callconv(.c) c_int,
    SSL_get_event_timeout: *const fn (s: Opaque, tv: *std.c.timeval, inf: *c_int) callconv(.c) c_int,
    SSL_handle_events: *const fn (s: Opaque) callconv(.c) c_int,
    SSL_read_ex: *const fn (s: Opaque, buf: [*]u8, n: usize, got: *usize) callconv(.c) c_int,
    SSL_write_ex: *const fn (s: Opaque, buf: [*]const u8, n: usize, wrote: *usize) callconv(.c) c_int,
    SSL_stream_conclude: *const fn (s: Opaque, flags: u64) callconv(.c) c_int,
    SSL_shutdown: *const fn (s: Opaque) callconv(.c) c_int,
    SSL_get0_alpn_selected: *const fn (s: Opaque, data: *?[*]const u8, len: *c_uint) callconv(.c) void,
    SSL_get_verify_result: *const fn (s: Opaque) callconv(.c) c_long,
    SSL_get_stream_type: *const fn (s: Opaque) callconv(.c) c_int,
    SSL_get_stream_id: *const fn (s: Opaque) callconv(.c) u64,
    SSL_shutdown_ex: *const fn (s: Opaque, flags: u64, args: *const ShutdownArgs, len: usize) callconv(.c) c_int,
    SSL_get_conn_close_info: *const fn (s: Opaque, info: [*]u8, len: usize) callconv(.c) c_int,
    BIO_new_dgram: *const fn (fd: c_int, close_flag: c_int) callconv(.c) Opaque,
    BIO_ADDR_new: *const fn () callconv(.c) Opaque,
    BIO_ADDR_free: *const fn (a: Opaque) callconv(.c) void,
    BIO_ADDR_rawmake: *const fn (a: Opaque, family: c_int, addr: ?*const anyopaque, len: usize, port: u16) callconv(.c) c_int,
    ERR_get_error: *const fn () callconv(.c) c_ulong,
    ERR_error_string_n: *const fn (e: c_ulong, buf: [*]u8, len: usize) callconv(.c) void,
    OpenSSL_version_num: *const fn () callconv(.c) c_ulong,
};

const SSL_FILETYPE_PEM: c_int = 1;
const SSL_VERIFY_PEER: c_int = 1;
const SSL_ERROR_WANT_READ: c_int = 2;
const SSL_ERROR_WANT_WRITE: c_int = 3;
const SSL_ERROR_ZERO_RETURN: c_int = 6;
const SSL_CTRL_SET_TLSEXT_HOSTNAME: c_int = 55;
const TLSEXT_NAMETYPE_host_name: c_long = 0;
const ACCEPT_NO_BLOCK: u64 = 1;
const STREAM_FLAG_UNI: u64 = 1;
const SHUTDOWN_RAPID: u64 = 1;
const SHUTDOWN_NO_BLOCK: u64 = 4;
const OPENSSL_NPN_NEGOTIATED: c_int = 1;
const SSL_TLSEXT_ERR_OK: c_int = 0;
const SSL_TLSEXT_ERR_ALERT_FATAL: c_int = 2;

const LoadState = enum(u8) { uninit, initializing, ready, failed };
var g_state: std.atomic.Value(LoadState) = .init(.uninit);
var g_lib: std.DynLib = undefined;
var g_funcs: Funcs = undefined;

fn libraryCandidates() []const [:0]const u8 {
    return switch (builtin.os.tag) {
        .macos => &.{
            "/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib",
            "/usr/local/opt/openssl@3/lib/libssl.3.dylib",
            "/opt/homebrew/opt/openssl@4/lib/libssl.4.dylib",
            "/opt/local/lib/libssl.dylib",
        },
        else => &.{ "libssl.so.3", "libssl.so.4", "libssl.so" },
    };
}

fn loadAll() bool {
    if (comptime !supported) return false;
    var lib: std.DynLib = blk: {
        if (std.c.getenv("NOX_OPENSSL_LIB")) |p| {
            if (std.DynLib.open(std.mem.span(p))) |l| break :blk l else |_| {}
        }
        for (libraryCandidates()) |name| {
            if (std.DynLib.open(name)) |l| break :blk l else |_| {}
        }
        return false;
    };
    var f: Funcs = undefined;
    inline for (@typeInfo(Funcs).@"struct".fields) |fld| {
        // Sembol yoksa (OpenSSL < 3.5) sessizce başarısız: h3 yalnızca "kullanılamıyor" der.
        @field(f, fld.name) = lib.lookup(fld.type, fld.name) orelse {
            lib.close();
            return false;
        };
    }
    g_lib = lib;
    g_funcs = f;
    return true;
}

fn ensureLoaded() bool {
    if (comptime !supported) return false;
    if (g_state.cmpxchgStrong(.uninit, .initializing, .acquire, .monotonic) == null) {
        g_state.store(if (loadAll()) .ready else .failed, .release);
    } else {
        while (true) {
            const s = g_state.load(.acquire);
            if (s == .ready or s == .failed) break;
            std.Thread.yield() catch {};
        }
    }
    return g_state.load(.acquire) == .ready;
}

/// Hata kuyruğundaki son OpenSSL hatasını (varsa) `buf`a yazar; yoksa boş dilim.
pub fn lastError(buf: []u8) []const u8 {
    if (!ensureLoaded()) return "";
    const code = g_funcs.ERR_get_error();
    if (code == 0) return "";
    g_funcs.ERR_error_string_n(code, buf.ptr, buf.len);
    return std.mem.sliceTo(buf, 0);
}

/// OpenSSL >= 3.5 (QUIC sunucu + istemci) bu makinede yüklenebiliyor mu?
pub fn available() bool {
    return ensureLoaded();
}

// ---- Beklemeyi fiber reaktörüne devreden yardımcılar ---------------------------------------------------------------------------------------------------------

/// `root` (bağlantı ya da dinleyici) için UDP fd'sinin okunabilmesini ya da QUIC olay süresinin dolmasını (en çok `max_ms`) bekler, sonra QUIC makinesini ilerletir.
fn pump(root: Opaque, max_ms: u32) void {
    var ms: u32 = max_ms;
    var tv: std.c.timeval = undefined;
    var infinite: c_int = 0;
    if (g_funcs.SSL_get_event_timeout(root, &tv, &infinite) == 1 and infinite == 0) {
        const t: i64 = @as(i64, tv.sec) * 1000 + @divTrunc(@as(i64, tv.usec), 1000);
        ms = @intCast(@min(@as(i64, ms), @max(t, 0)));
    }
    var pd: PollDesc = undefined;
    if (g_funcs.SSL_get_rpoll_descriptor(root, &pd) == 1 and pd.type == POLL_SOCK_FD) {
        const fd: posix.fd_t = pd.value.fd;
        if (fiber_net.inFiber()) {
            _ = fiber_net.waitFd(fd, false, ms);
        } else {
            var p = [1]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
            _ = posix.poll(&p, @intCast(@min(ms, 1 << 30))) catch 0;
        }
    }
    _ = g_funcs.SSL_handle_events(root);
}

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

// ---- Bağlam (SSL_CTX) -----------------------------------------------------------------------------------------------------------------------------------------

pub const Ctx = struct {
    ctx: Opaque,
    is_server: bool,

    pub fn deinit(self: *Ctx) void {
        if (self.ctx) |c| g_funcs.SSL_CTX_free(c);
        self.ctx = null;
    }
};

/// ALPN seçimi: sunucunun tek protokolü (`h3`); istemci listesinde yoksa el sıkışma reddedilir.
const server_alpn = [_]u8{ 2, 'h', '3' };
fn alpnSelect(_: Opaque, out: *?[*]const u8, outlen: *u8, in: [*]const u8, inlen: c_uint, _: ?*anyopaque) callconv(.c) c_int {
    // Elle tarama (SSL_select_next_proto'ya bağımlılık yok): istemcinin listesinde "h3" ara.
    var i: usize = 0;
    while (i < inlen) {
        const l: usize = in[i];
        if (i + 1 + l > inlen) break;
        if (l == 2 and in[i + 1] == 'h' and in[i + 2] == '3') {
            out.* = in + i + 1;
            outlen.* = 2;
            return SSL_TLSEXT_ERR_OK;
        }
        i += 1 + l;
    }
    return SSL_TLSEXT_ERR_ALERT_FATAL;
}

pub fn newServerCtx(cert_path: [*:0]const u8, key_path: [*:0]const u8) Error!Ctx {
    if (!ensureLoaded()) return error.LibraryUnavailable;
    const c = g_funcs.OSSL_QUIC_server_method();
    const ctx = g_funcs.SSL_CTX_new(c) orelse return error.CtxFailed;
    errdefer g_funcs.SSL_CTX_free(ctx);
    if (g_funcs.SSL_CTX_use_certificate_chain_file(ctx, cert_path) != 1) return error.CertFailed;
    if (g_funcs.SSL_CTX_use_PrivateKey_file(ctx, key_path, SSL_FILETYPE_PEM) != 1) return error.KeyFailed;
    if (g_funcs.SSL_CTX_check_private_key(ctx) != 1) return error.KeyFailed;
    g_funcs.SSL_CTX_set_alpn_select_cb(ctx, alpnSelect, null);
    return .{ .ctx = ctx, .is_server = true };
}

/// `ca_file` verilirse yalnız o PEM'e güvenilir (test/özel CA); yoksa sistem kök deposu. `verify=false` sertifika doğrulamasını kapatır (yalnız geliştirme).
pub fn newClientCtx(ca_file: ?[*:0]const u8, verify: bool) Error!Ctx {
    if (!ensureLoaded()) return error.LibraryUnavailable;
    const ctx = g_funcs.SSL_CTX_new(g_funcs.OSSL_QUIC_client_method()) orelse return error.CtxFailed;
    errdefer g_funcs.SSL_CTX_free(ctx);
    if (verify) {
        g_funcs.SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, null);
        if (ca_file) |f| {
            if (g_funcs.SSL_CTX_load_verify_locations(ctx, f, null) != 1) return error.CertFailed;
        } else if (g_funcs.SSL_CTX_set_default_verify_paths(ctx) != 1) return error.CertFailed;
    }
    return .{ .ctx = ctx, .is_server = false };
}

/// Eş adresi: IPv4 ya da IPv6 (ham bayt dizisi, ağ sırası).
pub const Addr = union(enum) {
    v4: [4]u8,
    v6: [16]u8,
};

// ---- UDP soketi -----------------------------------------------------------------------------------------------------------------------------------------------

fn setNonBlocking(fd: posix.fd_t) void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
    if (flags >= 0) _ = std.c.fcntl(fd, std.c.F.SETFL, flags | @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true })));
}

fn udpSocket(family: c_int) Error!posix.fd_t {
    const fd = std.c.socket(@intCast(family), std.c.SOCK.DGRAM, 0);
    if (fd < 0) return error.SocketFailed;
    setNonBlocking(fd);
    return fd;
}

// ---- Dinleyici (sunucu) ---------------------------------------------------------------------------------------------------------------------------------------

pub const Listener = struct {
    ssl: Opaque,
    port: u16,

    /// `bind_addr` üzerinde UDP `port`u dinler. `port == 0` ise çekirdek bir port seçer (`self.port` gerçek değeri tutar).
    pub fn open(ctx: *const Ctx, bind_addr: Addr, port: u16) Error!Listener {
        if (!ensureLoaded()) return error.LibraryUnavailable;
        const family: c_int = switch (bind_addr) {
            .v4 => std.c.AF.INET,
            .v6 => std.c.AF.INET6,
        };
        const fd = try udpSocket(family);
        errdefer _ = std.c.close(fd);
        var real_port: u16 = 0;
        switch (bind_addr) {
            .v4 => |a| {
                var sa: std.c.sockaddr.in = std.mem.zeroes(std.c.sockaddr.in);
                sa.family = std.c.AF.INET;
                sa.port = std.mem.nativeToBig(u16, port);
                @memcpy(std.mem.asBytes(&sa.addr), &a);
                if (std.c.bind(fd, @ptrCast(&sa), @sizeOf(std.c.sockaddr.in)) != 0) return error.ListenFailed;
                var real = sa;
                var rl: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
                _ = std.c.getsockname(fd, @ptrCast(&real), &rl);
                real_port = std.mem.bigToNative(u16, real.port);
            },
            .v6 => |a| {
                // Çift yığın: IPv4 istemciler IPv4-eşlemeli adreslerle de bağlanabilsin.
                var off: c_int = 0;
                // `std.c`de IPV6_V6ONLY yok: Darwin 27, Linux 26; IPPROTO_IPV6 = 41.
                const v6only_opt: u32 = if (builtin.os.tag == .linux) 26 else 27;
                _ = std.c.setsockopt(fd, 41, v6only_opt, &off, @sizeOf(c_int));
                var sa: std.c.sockaddr.in6 = std.mem.zeroes(std.c.sockaddr.in6);
                sa.family = std.c.AF.INET6;
                sa.port = std.mem.nativeToBig(u16, port);
                @memcpy(&sa.addr, &a);
                if (std.c.bind(fd, @ptrCast(&sa), @sizeOf(std.c.sockaddr.in6)) != 0) return error.ListenFailed;
                var real = sa;
                var rl: std.c.socklen_t = @sizeOf(std.c.sockaddr.in6);
                _ = std.c.getsockname(fd, @ptrCast(&real), &rl);
                real_port = std.mem.bigToNative(u16, real.port);
            },
        }
        const l = g_funcs.SSL_new_listener(ctx.ctx, 0) orelse return error.ListenFailed;
        errdefer g_funcs.SSL_free(l);
        const bio = g_funcs.BIO_new_dgram(fd, 1) orelse return error.ListenFailed; // BIO_CLOSE: fd'yi BIO sahiplenir
        g_funcs.SSL_set_bio(l, bio, bio);
        _ = g_funcs.SSL_set_blocking_mode(l, 0);
        if (g_funcs.SSL_listen(l) != 1) return error.ListenFailed;
        return .{ .ssl = l, .port = real_port };
    }

    /// Önce çift yığınlı (`::`) dinler; IPv6 yoksa IPv4 `0.0.0.0`a düşer.
    pub fn openAnyAddr(ctx: *const Ctx, port: u16) Error!Listener {
        return open(ctx, .{ .v6 = [_]u8{0} ** 16 }, port) catch open(ctx, .{ .v4 = .{ 0, 0, 0, 0 } }, port);
    }

    pub fn deinit(self: *Listener) void {
        if (self.ssl) |s| g_funcs.SSL_free(s);
        self.ssl = null;
    }

    /// Bekleme olmadan: hazır bir bağlantı varsa döner (olay motorunu ilerletmez; önce `pumpOnce`).
    pub fn tryAccept(self: *Listener) ?Conn {
        const c = g_funcs.SSL_accept_connection(self.ssl, ACCEPT_NO_BLOCK) orelse return null;
        _ = g_funcs.SSL_set_blocking_mode(c, 0);
        _ = g_funcs.SSL_set_default_stream_mode(c, 0);
        return .{ .ssl = c };
    }

    /// UDP fd'sinin okunabilmesini ya da QUIC olay süresinin dolmasını (en çok `max_ms`) bekler ve TÜM motoru (dinleyici + bağlantılar + akışlar) ilerletir.
    pub fn pumpOnce(self: *Listener, max_ms: u32) void {
        pump(self.ssl, max_ms);
    }

    /// Bir bağlantı kabul edene dek (en çok `timeout_ms`) bekler; süre dolarsa `null`.
    pub fn accept(self: *Listener, timeout_ms: u32) ?Conn {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            if (g_funcs.SSL_accept_connection(self.ssl, ACCEPT_NO_BLOCK)) |c| {
                _ = g_funcs.SSL_set_blocking_mode(c, 0);
                _ = g_funcs.SSL_set_default_stream_mode(c, 0); // SSL_DEFAULT_STREAM_MODE_NONE: yalnızca açık akış nesneleri
                return .{ .ssl = c };
            }
            const left = deadline - nowMs();
            if (left <= 0) return null;
            pump(self.ssl, @intCast(@min(left, 1000)));
        }
    }
};

// ---- Bağlantı + akış ------------------------------------------------------------------------------------------------------------------------------------------

pub const Conn = struct {
    ssl: Opaque,

    /// `addr:port`a QUIC istemci bağlantısı kurar (ALPN `h3`), el sıkışma bitene dek (en çok `timeout_ms`) bekler. `sni`: sunucu adı (TLS SNI + sertifika konak adı doğrulaması).
    pub fn connect(ctx: *const Ctx, addr: Addr, port: u16, sni: [:0]const u8, timeout_ms: u32) Error!Conn {
        if (!ensureLoaded()) return error.LibraryUnavailable;
        const family: c_int = switch (addr) {
            .v4 => std.c.AF.INET,
            .v6 => std.c.AF.INET6,
        };
        const fd = try udpSocket(family);
        var own_fd = true;
        defer if (own_fd) {
            _ = std.c.close(fd);
        };
        const ba = g_funcs.BIO_ADDR_new() orelse return error.ConnectFailed;
        defer g_funcs.BIO_ADDR_free(ba);
        const net_port = std.mem.nativeToBig(u16, port);
        switch (addr) {
            .v4 => |a| {
                var sa: std.c.sockaddr.in = std.mem.zeroes(std.c.sockaddr.in);
                sa.family = std.c.AF.INET;
                sa.port = net_port;
                @memcpy(std.mem.asBytes(&sa.addr), &a);
                if (std.c.connect(fd, @ptrCast(&sa), @sizeOf(std.c.sockaddr.in)) != 0) return error.ConnectFailed;
                if (g_funcs.BIO_ADDR_rawmake(ba, std.c.AF.INET, &a, 4, net_port) != 1) return error.ConnectFailed;
            },
            .v6 => |a| {
                var sa: std.c.sockaddr.in6 = std.mem.zeroes(std.c.sockaddr.in6);
                sa.family = std.c.AF.INET6;
                sa.port = net_port;
                @memcpy(&sa.addr, &a);
                if (std.c.connect(fd, @ptrCast(&sa), @sizeOf(std.c.sockaddr.in6)) != 0) return error.ConnectFailed;
                if (g_funcs.BIO_ADDR_rawmake(ba, std.c.AF.INET6, &a, 16, net_port) != 1) return error.ConnectFailed;
            },
        }
        const s = g_funcs.SSL_new(ctx.ctx) orelse return error.ConnectFailed;
        errdefer g_funcs.SSL_free(s);
        const bio = g_funcs.BIO_new_dgram(fd, 1) orelse return error.ConnectFailed;
        own_fd = false;
        g_funcs.SSL_set_bio(s, bio, bio);
        if (g_funcs.SSL_set1_initial_peer_addr(s, ba) != 1) return error.ConnectFailed;
        if (g_funcs.SSL_set_alpn_protos(s, &server_alpn, server_alpn.len) != 0) return error.ConnectFailed;
        // Sertifika ana makine doğrulaması ve SNI kurulamazsa bağlantı BAŞLAMADAN reddedilir (sessizce doğrulamasız bağlanılmaz).
        if (g_funcs.SSL_set1_host(s, sni.ptr) != 1) return error.ConnectFailed;
        if (g_funcs.SSL_ctrl(s, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, @ptrCast(@constCast(sni.ptr))) != 1) return error.ConnectFailed;
        _ = g_funcs.SSL_set_blocking_mode(s, 0);
        _ = g_funcs.SSL_set_default_stream_mode(s, 0);

        const deadline = nowMs() + timeout_ms;
        while (true) {
            const r = g_funcs.SSL_connect(s);
            if (r == 1) {
                const conn: Conn = .{ .ssl = s };
                // ALPN `h3` zorunludur: sunucu başka bir protokol seçtiyse (ya da hiçbir şey) bağlantı kurulmuş sayılmaz.
                if (!conn.alpnIsH3()) return error.ConnectFailed;
                return conn;
            }
            const e = g_funcs.SSL_get_error(s, r);
            if (e != SSL_ERROR_WANT_READ and e != SSL_ERROR_WANT_WRITE) {
                if (std.c.getenv("NOX_QUIC_DEBUG") != null) {
                    var eb: [256]u8 = undefined;
                    const code = g_funcs.ERR_get_error();
                    g_funcs.ERR_error_string_n(code, &eb, eb.len);
                    std.debug.print("quic connect failed: ssl_error={d} {s}\n", .{ e, std.mem.sliceTo(&eb, 0) });
                }
                return error.ConnectFailed;
            }
            const left = deadline - nowMs();
            if (left <= 0) return error.Timeout;
            pump(s, @intCast(@min(left, 1000)));
        }
    }

    /// Bağlantıyı uygulama hata koduyla (`h3.ErrorCode`) hemen kapatır (CONNECTION_CLOSE gönderilir); sonra `deinit` çağrılabilir.
    pub fn closeWithError(self: *Conn, code: u64, reason: [:0]const u8) void {
        const args: ShutdownArgs = .{ .quic_error_code = code, .quic_reason = reason.ptr };
        _ = g_funcs.SSL_shutdown_ex(self.ssl, SHUTDOWN_RAPID | SHUTDOWN_NO_BLOCK, &args, @sizeOf(ShutdownArgs));
    }

    pub fn deinit(self: *Conn) void {
        if (self.ssl) |s| {
            _ = g_funcs.SSL_shutdown(s);
            g_funcs.SSL_free(s);
        }
        self.ssl = null;
    }

    /// Eş tarafın açtığı bir akışı kabul eder (en çok `timeout_ms` bekler); yoksa `null`.
    pub fn acceptStream(self: *Conn, timeout_ms: u32) ?Stream {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            if (g_funcs.SSL_accept_stream(self.ssl, ACCEPT_NO_BLOCK)) |st| {
                return .{ .ssl = st, .conn = self.ssl };
            }
            const left = deadline - nowMs();
            if (left <= 0) return null;
            pump(self.ssl, @intCast(@min(left, 1000)));
        }
    }

    /// Beklemeden QUIC olay motorunu bir adım ilerletir.
    pub fn handleEvents(self: *Conn) void {
        _ = g_funcs.SSL_handle_events(self.ssl);
    }

    /// Bekleme olmadan: eş tarafın açtığı hazır bir akış varsa döner.
    pub fn tryAcceptStream(self: *Conn) ?Stream {
        const st = g_funcs.SSL_accept_stream(self.ssl, ACCEPT_NO_BLOCK) orelse return null;
        return .{ .ssl = st, .conn = self.ssl };
    }

    /// Bağlantı kapandı/kapanıyor mu (eş taraf kapattı, kimlik/zaman aşımı hatası, uygulama kapatması)?
    pub fn isClosed(self: *const Conn) bool {
        var info: [64]u8 align(8) = undefined;
        return g_funcs.SSL_get_conn_close_info(self.ssl, &info, info.len) == 1;
    }

    /// Yeni bir çift yönlü (`uni=false`) ya da tek yönlü akış açar.
    pub fn openStream(self: *Conn, uni: bool) Error!Stream {
        const st = g_funcs.SSL_new_stream(self.ssl, if (uni) STREAM_FLAG_UNI else 0) orelse return error.StreamFailed;
        return .{ .ssl = st, .conn = self.ssl };
    }

    /// Seçilen ALPN protokolü (`h3`) mü?
    pub fn alpnIsH3(self: *const Conn) bool {
        var data: ?[*]const u8 = null;
        var len: c_uint = 0;
        g_funcs.SSL_get0_alpn_selected(self.ssl, &data, &len);
        return len == 2 and data != null and data.?[0] == 'h' and data.?[1] == '3';
    }
};

pub const ReadResult = union(enum) { data: usize, eof, timeout, closed };

pub const Stream = struct {
    ssl: Opaque,
    /// Ait olduğu bağlantının SSL'i (olay motorunu ilerletmek için).
    conn: Opaque,

    pub fn deinit(self: *Stream) void {
        if (self.ssl) |s| g_funcs.SSL_free(s);
        self.ssl = null;
    }

    pub fn id(self: *const Stream) u64 {
        return g_funcs.SSL_get_stream_id(self.ssl);
    }

    pub const Kind = enum { none, uni_read, uni_write, bidi };

    pub fn kind(self: *const Stream) Kind {
        return switch (g_funcs.SSL_get_stream_type(self.ssl)) {
            1 => .uni_read,
            2 => .uni_write,
            3 => .bidi,
            else => .none,
        };
    }

    /// Tek deneme, beklemez: `.data`, `.eof` (FIN), `.timeout` (şu an veri yok) ya da `.closed` (sıfırlandı/bağlantı koptu).
    pub fn tryRead(self: *Stream, buf: []u8) ReadResult {
        var n: usize = 0;
        if (g_funcs.SSL_read_ex(self.ssl, buf.ptr, buf.len, &n) == 1) return .{ .data = n };
        const e = g_funcs.SSL_get_error(self.ssl, 0);
        if (e == SSL_ERROR_ZERO_RETURN) return .eof;
        if (e == SSL_ERROR_WANT_READ) return .timeout;
        return .closed;
    }

    /// Tek deneme, beklemez: yazılan bayt sayısı (akış kontrolü doluysa 0); akış/bağlantı kapalıysa `error.Closed`.
    pub fn tryWrite(self: *Stream, bytes: []const u8) Error!usize {
        if (bytes.len == 0) return 0;
        var w: usize = 0;
        if (g_funcs.SSL_write_ex(self.ssl, bytes.ptr, bytes.len, &w) == 1) return w;
        const e = g_funcs.SSL_get_error(self.ssl, 0);
        if (e == SSL_ERROR_WANT_WRITE or e == SSL_ERROR_WANT_READ) return 0;
        return error.Closed;
    }

    /// En az 1 bayt gelene, akış kapanana ya da `timeout_ms` dolana dek bekler.
    pub fn read(self: *Stream, buf: []u8, timeout_ms: u32) ReadResult {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            var n: usize = 0;
            if (g_funcs.SSL_read_ex(self.ssl, buf.ptr, buf.len, &n) == 1) return .{ .data = n };
            const e = g_funcs.SSL_get_error(self.ssl, 0);
            if (e == SSL_ERROR_ZERO_RETURN) return .eof;
            if (e != SSL_ERROR_WANT_READ) return .closed;
            const left = deadline - nowMs();
            if (left <= 0) return .timeout;
            pump(self.conn, @intCast(@min(left, 1000)));
        }
    }

    /// Tüm baytları yazar (akış kontrolü dolarsa bekler); eş taraf akışı kapattıysa `error.Closed`.
    pub fn writeAll(self: *Stream, bytes: []const u8, timeout_ms: u32) Error!void {
        var sent: usize = 0;
        return self.writeAllProgress(bytes, timeout_ms, &sent);
    }

    /// `writeAll` + ilerleme: hata/zaman aşımında bile `sent.*` o ana kadar KABUL EDİLEN bayt sayısını tutar (istemci: sıfır bayt gönderildiyse isteği güvenle başka taşıyıcıda tekrarlayabilir, kısmi gönderimde tekrarlamamalı).
    pub fn writeAllProgress(self: *Stream, bytes: []const u8, timeout_ms: u32, sent: *usize) Error!void {
        const deadline = nowMs() + timeout_ms;
        var off: usize = 0;
        sent.* = 0;
        while (off < bytes.len) {
            var w: usize = 0;
            if (g_funcs.SSL_write_ex(self.ssl, bytes.ptr + off, bytes.len - off, &w) == 1) {
                off += w;
                sent.* = off;
                continue;
            }
            const e = g_funcs.SSL_get_error(self.ssl, 0);
            if (e != SSL_ERROR_WANT_WRITE and e != SSL_ERROR_WANT_READ) return error.Closed;
            const left = deadline - nowMs();
            if (left <= 0) return error.Timeout;
            pump(self.conn, @intCast(@min(left, 1000)));
        }
    }

    /// Yazma yönünü temiz kapatır (FIN).
    pub fn conclude(self: *Stream) void {
        _ = g_funcs.SSL_stream_conclude(self.ssl, 0);
    }
};

// ---- Birim testleri -------------------------------------------------------------------------------------------------------------------------------------------

const testing = std.testing;

const test_cert: [:0]const u8 = "runtime/stdlib_shims/testdata/quic_test_cert.pem";
const test_key: [:0]const u8 = "runtime/stdlib_shims/testdata/quic_test_key.pem";

const EchoSrv = struct {
    listener: *Listener,
    ok: bool = false,
    fn run(self: *EchoSrv) void {
        var conn = self.listener.accept(10_000) orelse return;
        defer conn.deinit();
        var st = conn.acceptStream(10_000) orelse return;
        defer st.deinit();
        var buf: [256]u8 = undefined;
        var total: usize = 0;
        while (true) {
            switch (st.read(buf[total..], 10_000)) {
                .data => |n| total += n,
                .eof => break,
                else => return,
            }
        }
        st.writeAll("echo:", 5_000) catch return;
        st.writeAll(buf[0..total], 5_000) catch return;
        st.conclude();
        // Yanıtın istemciye ulaşması için olay motorunu bir süre döndür.
        var i: usize = 0;
        while (i < 20) : (i += 1) pump(conn.ssl, 50);
        self.ok = true;
    }
};

test "quic: sembol tablosu ya yüklenir ya da temiz biçimde reddedilir" {
    // OpenSSL < 3.5 olan makinede `available()` false'tur ve hiçbir şey çökmez; >= 3.5'te true ve sürüm numarası okunabilir.
    if (!supported) return error.SkipZigTest;
    if (!available()) return error.SkipZigTest;
    const v = g_funcs.OpenSSL_version_num();
    try testing.expect(v >= 0x30500000);
}

test "quic: istemci-sunucu el sıkışması (ALPN h3) ve çift yönlü akış yankısı" {
    if (!supported) return error.SkipZigTest;
    if (!available()) return error.SkipZigTest;
    var sctx = try newServerCtx(test_cert, test_key);
    defer sctx.deinit();
    var cctx = try newClientCtx(test_cert, true);
    defer cctx.deinit();
    var l = try Listener.open(&sctx, .{ .v4 = .{ 127, 0, 0, 1 } }, 0);
    defer l.deinit();
    var srv: EchoSrv = .{ .listener = &l };
    const t = try std.Thread.spawn(.{}, EchoSrv.run, .{&srv});
    var conn = try Conn.connect(&cctx, .{ .v4 = .{ 127, 0, 0, 1 } }, l.port, "localhost", 10_000);
    defer conn.deinit();
    try testing.expect(conn.alpnIsH3());
    var st = try conn.openStream(false);
    defer st.deinit();
    try st.writeAll("hello-quic", 5_000);
    st.conclude();
    var buf: [64]u8 = undefined;
    var total: usize = 0;
    while (true) {
        switch (st.read(buf[total..], 10_000)) {
            .data => |n| total += n,
            .eof => break,
            else => return error.TestUnexpectedResult,
        }
    }
    t.join();
    try testing.expect(srv.ok);
    try testing.expectEqualStrings("echo:hello-quic", buf[0..total]);
}

test "quic: sertifika doğrulaması yanlış CA ile başarısız olur" {
    if (!supported) return error.SkipZigTest;
    if (!available()) return error.SkipZigTest;
    var sctx = try newServerCtx(test_cert, test_key);
    defer sctx.deinit();
    // Sistem kök deposu bu kendinden imzalı sertifikaya güvenmez.
    var cctx = try newClientCtx(null, true);
    defer cctx.deinit();
    var l = try Listener.open(&sctx, .{ .v4 = .{ 127, 0, 0, 1 } }, 0);
    defer l.deinit();
    // Sunucu tarafı el sıkışmayı yürütmek için dinleyiciyi döndürmelidir.
    const t = try std.Thread.spawn(.{}, struct {
        fn run(lp: *Listener) void {
            if (lp.accept(3_000)) |c| {
                var cc = c;
                var i: usize = 0;
                while (i < 10) : (i += 1) pump(cc.ssl, 50);
                cc.deinit();
            }
        }
    }.run, .{&l});
    defer t.join();
    try testing.expectError(error.ConnectFailed, Conn.connect(&cctx, .{ .v4 = .{ 127, 0, 0, 1 } }, l.port, "localhost", 5_000));
}
