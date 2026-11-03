//! TODO 3.8 (v2.0.91): sınırlı DNS + TCP bağlanması. `nox.http` zaman aşımı yalnızca bağlantı kurulduktan SONRA işliyordu; çözülemeyen bir ad (macOS'ta 30 sn) ya da
//! cevap vermeyen bir adres (75 sn) isteği o kadar bloke ederdi ve mobil ağlarda bu "takıldı" demektir. Ayrıca Android yalnızca IPv4 çözümlüyordu (IPv6-only/DNS64 ağlar
//! çalışmazdı) ve `[::1]` gibi IPv6 literal URL'leri her platformda hata veriyordu.
//!
//! Çözüm `std.Io` vtable'ının iki girişini değiştirir (bkz. `install`): `netLookup` sistem `getaddrinfo`sunu (AF_UNSPEC: IPv4 + IPv6, işletim sisteminin RFC 6724 sırası) bir yardımcı
//! iş parçacığında çalıştırır ve son tarihte vazgeçer; `netConnectIp` bloklamasız `connect` + `poll` ile son tarihe kadar bekler. Son tarih iş parçacığı-yerel bir değerdir
//! (`begin`/`end`); ayarlı değilse çağrı std'nin özgün uygulamasına gider (davranış değişmez). Windows/wasm/freestanding'de hiçbir şey yapılmaz.
//!
//! **Kaynak sınırı (v2.0.103/v2.0.109):** `getaddrinfo` iptal edilemez; son tarihi geçen arama beklemeyi bırakır ama iş parçacığı çözümleyici dönene kadar yaşar. Bu yüzden (1) aynı anda
//! en fazla `MAX_LOOKUP_THREADS` yardımcı iş parçacığı vardır, sınıra gelen arama kendi son tarihine kadar yuva bekler; (2) singleflight: aynı (ad, port, aile) için uçuşta bir arama
//! varsa yeni iş parçacığı açılmaz, çağıran mevcut aramaya katılır (yavaş bir ada N eşzamanlı istek = 1 `getaddrinfo`). Her katılımcı kendi son tarihini kullanır.

const std = @import("std");
const builtin = @import("builtin");
const SpinLock = @import("../async_rt/spinlock.zig").SpinLock;
const bridge = @import("../async_rt/bridge.zig");
const fiber_net = @import("fiber_net.zig");

const Io = std.Io;
const net = std.Io.net;
const IpAddress = net.IpAddress;
const HostName = net.HostName;

pub const enabled = switch (builtin.os.tag) {
    .windows, .freestanding, .wasi, .other => false,
    else => !builtin.cpu.arch.isWasm(),
};

/// Tek bir deneme için üst sınır: son tarih uzaksa ilk adresin kara delik olması sonraki adresleri (IPv4 yedeği) aç bırakmasın.
const ATTEMPT_CAP_MS: i64 = 4000;

/// Fiber içinde süresiz (`timeout_ms == 0`) DNS aramasının kooperatif bekleme üst sınırı.
const LOOKUP_FIBER_CAP_MS: i64 = 120_000;

threadlocal var tl_deadline_ns: i64 = 0;
threadlocal var tl_timed_out: bool = false;
threadlocal var tl_tunnel: ?*const Tunnel = null;

/// HTTP CONNECT tüneli isteği (v2.0.129): `setTunnel` ile işaretlenen fiber/iş parçacığının sıradaki `connect`i hedefe değil VEKİLE yapılır (arama da vekilin adı için), bağlanınca `CONNECT target:port`
/// el sıkışması gerçekleşir; başarısızlık bağlantı hatasıdır (düz metin geri düşüşü YOK). std sonra aynı soket üzerinde TLS'i hedef adına kurar (SNI + sertifika doğrulaması).
pub const Tunnel = struct {
    proxy_host: []const u8,
    proxy_port: u16,
    target_host: []const u8,
    target_port: u16,
    /// `Proxy-Authorization` değeri (ör. "Basic ...") ya da null.
    authorization: ?[]const u8 = null,
};

pub fn setTunnel(t: ?*const Tunnel) void {
    if (comptime !enabled) return;
    if (comptime enabled) {
        if (bridge.currentFiber()) |f| {
            f.net_tunnel = if (t) |x| @ptrCast(x) else null;
            return;
        }
    }
    tl_tunnel = t;
}

fn activeTunnel() ?*const Tunnel {
    if (comptime !enabled) return null;
    if (bridge.currentFiber()) |f| return if (f.net_tunnel) |x| @ptrCast(@alignCast(x)) else null;
    return tl_tunnel;
}

/// Son tarih durumu: bir zamanlayıcıdaki fiber içindeysek fiber'ın KENDİSİNDE (fiber'lar askıya alınınca aynı iş parçacığını paylaşır), değilse iş parçacığı-yerel.
const Deadline = struct { ns: *i64, timed_out: *bool };

fn deadlineState() Deadline {
    if (comptime enabled) {
        if (bridge.currentFiber()) |f| return .{ .ns = &f.net_deadline_ns, .timed_out = &f.net_timed_out };
    }
    return .{ .ns = &tl_deadline_ns, .timed_out = &tl_timed_out };
}

/// `install`a verilen (yamalı) vtable; `Queue.close/putOne` için `Io` değeri kurarken kullanılır.
var g_vtable: ?*const Io.VTable = null;
var g_base_lookup: ?@TypeOf(@as(Io.VTable, undefined).netLookup) = null;
var g_base_connect_ip: ?@TypeOf(@as(Io.VTable, undefined).netConnectIp) = null;

/// 1 ms bekleme: bir zamanlayıcıdaki fiber içindeysek KOOPERATİF (zamanlayıcı iş parçacığı başka fiber çalıştırır), değilse iş parçacığını uyutur.
fn pause() void {
    if (fiber_net.sleepCooperative(1)) return;
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&ts, null);
}

fn nowNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Bu iş parçacığındaki sonraki DNS/bağlanma çağrıları için `timeout_ms` süre tanır (0 = sınırsız). `end` ile temizlenir.
pub fn begin(timeout_ms: u64) void {
    if (comptime !enabled) return;
    const st = deadlineState();
    st.timed_out.* = false;
    st.ns.* = if (timeout_ms == 0) 0 else nowNs() + @as(i64, @intCast(@min(timeout_ms, std.math.maxInt(i32)))) * std.time.ns_per_ms;
}

pub fn end() void {
    if (comptime !enabled) return;
    deadlineState().ns.* = 0;
}

/// Son `begin`den beri bir DNS/bağlanma son tarihi aşıldı mı? (çağıran bunu "zaman aşımı" hata türüne çevirir)
pub fn timedOut() bool {
    if (comptime !enabled) return false;
    return deadlineState().timed_out.*;
}

fn remainingMs() ?i64 {
    const deadline_ns = deadlineState().ns.*;
    if (deadline_ns == 0) return null;
    const left = @divFloor(deadline_ns - nowNs(), std.time.ns_per_ms);
    return if (left < 0) 0 else left;
}

/// `std.Io.VTable`ı sınırlı sürümlerle yamalar. Paylaşılan istemci `Io`su kurulurken BİR KEZ çağrılır.
pub fn install(vtable: *Io.VTable) void {
    if (comptime !enabled) return;
    g_vtable = vtable;
    g_base_lookup = vtable.netLookup;
    g_base_connect_ip = vtable.netConnectIp;
    vtable.netLookup = boundedLookup;
    vtable.netConnectIp = boundedConnectIp;
}

// ---- DNS --------------------------------------------------------------------------------------------------------------------------

const MAX_ADDRS = 16;

/// Aynı anda yaşayan DNS yardımcı iş parçacığı sayısı. `getaddrinfo` iptal edilemez: son tarihi geçen bir istek beklemeyi bırakır ama iş parçacığı sistem çözümleyicisi
/// (macOS ~30 sn) dönene kadar yaşar. Sınır olmasaydı yavaş bir DNS altında N eşzamanlı istek N iş parçacığı ve N yığın bırakırdı. Sınıra gelince yeni arama, kendi son
/// tarihine kadar boş yuva bekler; bulamazsa zaman aşımı olur (yeni iş parçacığı AÇILMAZ).
const MAX_LOOKUP_THREADS: u32 = 32;

const Slots = struct {
    inflight: std.atomic.Value(u32) = .init(0),

    fn tryAcquire(self: *Slots, limit: u32) bool {
        var cur = self.inflight.load(.acquire);
        while (cur < limit) {
            cur = self.inflight.cmpxchgWeak(cur, cur + 1, .acq_rel, .acquire) orelse return true;
        }
        return false;
    }

    fn release(self: *Slots) void {
        _ = self.inflight.fetchSub(1, .acq_rel);
    }

    /// Boş yuva bulunana ya da `deadline_ns` (monoton) dolana kadar bekler; `deadline_ns == 0` ise beklemeden dener.
    fn acquireUntil(self: *Slots, limit: u32, deadline_ns: i64) bool {
        while (true) {
            if (self.tryAcquire(limit)) return true;
            if (deadline_ns == 0 or nowNs() >= deadline_ns) return false;
            pause();
        }
    }
};

var g_lookup_slots: Slots = .{};

/// Singleflight: aynı (ad, port, aile) için uçuştaki bir arama varsa yeni iş parçacığı AÇILMAZ, çağıran mevcut aramaya katılır. Yavaş/ölü bir ada N eşzamanlı istek
/// N yerine TEK `getaddrinfo` ve TEK iş parçacığı demektir. Her katılımcı kendi son tarihini kullanır (birinin zaman aşımı diğerlerini iptal etmez).
const Flights = struct {
    lock: SpinLock = .{},
    jobs: [MAX_LOOKUP_THREADS]?*LookupJob = @splat(null),

    fn matches(job: *const LookupJob, name: []const u8, port: u16, family: ?IpAddress.Family) bool {
        if (job.port != port or job.family != family) return false;
        const stored: [*:0]const u8 = @ptrCast(&job.host_z);
        return std.ascii.eqlIgnoreCase(std.mem.span(stored), name);
    }

    /// Eşleşen uçuştaki işi bulursa ona bir referans ekleyip döndürür.
    fn join(self: *Flights, name: []const u8, port: u16, family: ?IpAddress.Family) ?*LookupJob {
        self.lock.lock();
        defer self.lock.unlock();
        return self.joinLocked(name, port, family);
    }

    fn joinLocked(self: *Flights, name: []const u8, port: u16, family: ?IpAddress.Family) ?*LookupJob {
        for (self.jobs) |maybe| {
            const j = maybe orelse continue;
            if (matches(j, name, port, family)) {
                _ = j.refs.fetchAdd(1, .acq_rel);
                return j;
            }
        }
        return null;
    }

    /// `job`u kaydeder; aynı anahtarla başka bir iş araya girdiyse onu (referansı artırılmış) döndürür ve `job` kaydedilmez.
    fn insertOrJoin(self: *Flights, job: *LookupJob, name: []const u8) ?*LookupJob {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.joinLocked(name, job.port, job.family)) |other| return other;
        for (&self.jobs) |*slot| {
            if (slot.* == null) {
                slot.* = job;
                return null;
            }
        }
        unreachable; // her iş bir yuva tutar (MAX_LOOKUP_THREADS) ve kayıt dizisi aynı boyuttadır
    }

    fn remove(self: *Flights, job: *LookupJob) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (&self.jobs) |*slot| {
            if (slot.* == job) slot.* = null;
        }
    }
};

var g_flights: Flights = .{};

const LookupJob = struct {
    refs: std.atomic.Value(u32) = .init(2),
    done: std.atomic.Value(bool) = .init(false),
    ok: bool = false,
    host_z: [HostName.max_len + 1]u8 = undefined,
    port: u16,
    family: ?IpAddress.Family,
    count: usize = 0,
    addrs: [MAX_ADDRS]IpAddress = undefined,
    /// Çözümleyici (üretimde `resolveInto`); testler yavaş/sayan bir sahte verir. `ctx` ona geçen opak durumdur.
    resolve: *const fn (*LookupJob) void = &resolveInto,
    ctx: ?*anyopaque = null,

    fn release(self: *LookupJob) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) std.heap.page_allocator.destroy(self);
    }
};

fn lookupThread(job: *LookupJob) void {
    defer job.release();
    // Yuva, iş parçacığı GERÇEKTEN bitince (çağıran vazgeçmiş olsa bile) boşalır.
    defer g_lookup_slots.release();
    job.resolve(job);
    // Önce kayıttan çıkar: bu andan sonra gelenler eski sonucu paylaşmaz, yeni arama başlatır.
    g_flights.remove(job);
    job.done.store(true, .release);
}

/// `getaddrinfo` (AF_UNSPEC) ile `job.addrs`ı doldurur.
fn resolveInto(job: *LookupJob) void {
    var service_buf: [8]u8 = undefined;
    const service = std.fmt.bufPrintZ(&service_buf, "{d}", .{job.port}) catch return;
    var hints = std.mem.zeroes(std.c.addrinfo);
    hints.family = if (job.family) |f| switch (f) {
        .ip4 => std.c.AF.INET,
        .ip6 => std.c.AF.INET6,
    } else std.c.AF.UNSPEC;
    hints.socktype = std.c.SOCK.STREAM;
    var list: ?*std.c.addrinfo = null;
    const host: [*:0]const u8 = @ptrCast(&job.host_z);
    if (@intFromEnum(std.c.getaddrinfo(host, service.ptr, &hints, &list)) == 0) {
        defer if (list) |l| std.c.freeaddrinfo(l);
        var it = list;
        while (it) |ai| : (it = ai.next) {
            if (job.count >= MAX_ADDRS) break;
            const sa = ai.addr orelse continue;
            const raw: [*]const u8 = @ptrCast(sa);
            if (ai.family == std.c.AF.INET) {
                job.addrs[job.count] = .{ .ip4 = .{ .bytes = raw[4..8].*, .port = job.port } };
                job.count += 1;
            } else if (ai.family == std.c.AF.INET6) {
                job.addrs[job.count] = .{ .ip6 = .{ .bytes = raw[8..24].*, .port = job.port } };
                job.count += 1;
            }
        }
        job.ok = job.count > 0;
    }
}

/// `Queue.putOne`: std `netLookup` sözleşmesi gereği kuyruk bu çağrı dönene kadar kapatılmaz (`Closed` olamaz).
fn put(q: *Io.Queue(HostName.LookupResult), t_io: Io, item: HostName.LookupResult) error{Canceled}!void {
    q.putOne(t_io, item) catch |e| switch (e) {
        error.Closed => unreachable,
        error.Canceled => return error.Canceled,
    };
}

const AwaitError = error{ TimedOut, Failed };

/// Son tarihli çözümleme (singleflight + iş parçacığı sınırı): bitmiş bir `LookupJob` döndürür; çağıran `release` eder. Süre dolarsa kendi payını bırakıp `TimedOut` verir
/// (iş parçacığı çözümleyici dönene kadar yaşar ve kendi yuvasını sonra bırakır).
fn awaitLookup(name: []const u8, port: u16, family: ?IpAddress.Family, deadline_ns: i64, resolve: *const fn (*LookupJob) void, ctx: ?*anyopaque) AwaitError!*LookupJob {
    var job: *LookupJob = undefined;
    if (g_flights.join(name, port, family)) |shared| {
        job = shared; // uçuştaki aynı aramaya katıl (yeni iş parçacığı yok)
    } else {
        if (!g_lookup_slots.acquireUntil(MAX_LOOKUP_THREADS, deadline_ns)) return error.TimedOut;
        const fresh = std.heap.page_allocator.create(LookupJob) catch {
            g_lookup_slots.release();
            return error.Failed;
        };
        fresh.* = .{ .port = port, .family = family, .resolve = resolve, .ctx = ctx };
        @memcpy(fresh.host_z[0..name.len], name);
        fresh.host_z[name.len] = 0;
        if (g_flights.insertOrJoin(fresh, name)) |other| {
            // Slot beklerken başka biri aynı aramayı başlattı: kendi işimizi at, onunkine katıl.
            g_lookup_slots.release();
            std.heap.page_allocator.destroy(fresh);
            job = other;
        } else if (std.Thread.spawn(.{}, lookupThread, .{fresh})) |th| {
            th.detach();
            job = fresh;
        } else |_| {
            // İş parçacığı açılamadı: kayıttan çıkar; araya katılanlara başarısız (ok == false) sonuç ver.
            g_flights.remove(fresh);
            g_lookup_slots.release();
            fresh.done.store(true, .release);
            fresh.release(); // iş parçacığının payı
            job = fresh;
        }
    }
    while (!job.done.load(.acquire)) {
        if (nowNs() >= deadline_ns) {
            job.release();
            return error.TimedOut;
        }
        pause();
    }
    return job;
}

fn boundedLookup(
    userdata: ?*anyopaque,
    host_name: HostName,
    resolved: *Io.Queue(HostName.LookupResult),
    options_in: HostName.LookupOptions,
) HostName.LookupError!void {
    const rem = remainingMs();
    const t_io: Io = .{ .userdata = userdata, .vtable = g_vtable.? };
    defer resolved.close(t_io);
    var name = host_name.bytes;
    var options = options_in;
    // Tünel: hedef adı yerel çözülmez; vekilin adı/portu çözülür (vekil hedefi kendisi çözer).
    if (activeTunnel()) |tn| {
        name = tn.proxy_host;
        options.port = tn.proxy_port;
    }
    // `[::1]` biçimi: köşeli parantezleri at.
    if (name.len >= 2 and name[0] == '[' and name[name.len - 1] == ']') name = name[1 .. name.len - 1];

    // IP literal'leri çözümleme gerektirmez.
    const literal: ?IpAddress = if (IpAddress.parseIp6(name, options.port)) |a| a else |_| if (IpAddress.parseIp4(name, options.port)) |a| a else |_| null;
    if (literal) |a| {
        if (options.family) |f| if (std.meta.activeTag(a) != f) return error.UnknownHostName;
        try put(resolved, t_io, .{ .address = a });
        return;
    }
    if (std.ascii.eqlIgnoreCase(name, "localhost") or std.ascii.endsWithIgnoreCase(name, ".localhost")) {
        // RFC 6761: localhost her zaman loopback'tir; ağ çözümlemesine gerek yok.
        if (options.family == null or options.family.? == .ip6) try put(resolved, t_io, .{ .address = .{ .ip6 = .{ .bytes = [_]u8{0} ** 15 ++ [_]u8{1}, .port = options.port } } });
        if (options.family == null or options.family.? == .ip4) try put(resolved, t_io, .{ .address = .{ .ip4 = .loopback(options.port) } });
        return;
    }

    var inline_job: LookupJob = .{ .port = options.port, .family = options.family };
    var job: *LookupJob = &inline_job;
    var heap_job = false;
    // Fiber içinde süresiz arama bile yardımcı iş parçacığında yapılır ve kooperatif beklenir (aksi halde `getaddrinfo` zamanlayıcı iş parçacığını bloke ederdi).
    const rem_eff: ?i64 = rem orelse if (fiber_net.inFiber()) @as(?i64, LOOKUP_FIBER_CAP_MS) else null;
    if (rem_eff) |r| {
        const deadline = nowNs() + r * std.time.ns_per_ms;
        job = awaitLookup(name, options.port, options.family, deadline, &resolveInto, null) catch |e| switch (e) {
            error.TimedOut => {
                deadlineState().timed_out.* = true;
                return error.NameServerFailure;
            },
            error.Failed => return error.NameServerFailure,
        };
        heap_job = true;
    } else {
        @memcpy(inline_job.host_z[0..name.len], name);
        inline_job.host_z[name.len] = 0;
        resolveInto(&inline_job);
    }
    defer if (heap_job) job.release();
    if (!job.ok) return error.UnknownHostName;
    if (options.canonical_name_buffer) |buf| {
        const n = @min(name.len, buf.len);
        @memcpy(buf[0..n], name[0..n]);
        try put(resolved, t_io, .{ .canonical_name = .{ .bytes = buf[0..n] } });
    }
    for (job.addrs[0..job.count]) |a| try put(resolved, t_io, .{ .address = a });
}

// ---- TCP --------------------------------------------------------------------------------------------------------------------------

fn setNonBlocking(fd: std.c.fd_t, on: bool) void {
    const current = std.c.fcntl(fd, std.c.F.GETFL);
    if (current < 0) return;
    var flags: std.c.O = @bitCast(@as(u32, @intCast(current)));
    flags.NONBLOCK = on;
    _ = std.c.fcntl(fd, std.c.F.SETFL, @as(u32, @bitCast(flags)));
}

fn errnoToConnectError(e: c_int) IpAddress.ConnectError {
    return switch (e) {
        @intFromEnum(std.c.E.CONNREFUSED) => error.ConnectionRefused,
        @intFromEnum(std.c.E.CONNRESET) => error.ConnectionResetByPeer,
        @intFromEnum(std.c.E.TIMEDOUT) => error.Timeout,
        @intFromEnum(std.c.E.NETUNREACH) => error.NetworkUnreachable,
        @intFromEnum(std.c.E.HOSTUNREACH) => error.HostUnreachable,
        @intFromEnum(std.c.E.ACCES), @intFromEnum(std.c.E.PERM) => error.AccessDenied,
        @intFromEnum(std.c.E.ADDRNOTAVAIL) => error.AddressUnavailable,
        @intFromEnum(std.c.E.AFNOSUPPORT) => error.AddressFamilyUnsupported,
        @intFromEnum(std.c.E.MFILE) => error.ProcessFdQuotaExceeded,
        @intFromEnum(std.c.E.NFILE) => error.SystemFdQuotaExceeded,
        else => error.NetworkUnreachable,
    };
}

/// Soket hazır (okunabilir/yazılabilir) olana ya da `budget_ms` dolana dek bekler (fiber içinde kooperatif). `false`: zaman aşımı.
fn waitReady(fd: std.c.fd_t, write: bool, budget_ms: i64) bool {
    const ms: u32 = @intCast(@min(@max(budget_ms, 1), std.math.maxInt(i32)));
    if (fiber_net.inFiber()) return fiber_net.waitFd(fd, write, ms) == .ready;
    var pfd = [1]std.c.pollfd{.{ .fd = fd, .events = if (write) std.c.POLL.OUT else std.c.POLL.IN, .revents = 0 }};
    return std.c.poll(&pfd, 1, @intCast(ms)) > 0;
}

/// Vekile `CONNECT host:port` gönderir ve `2xx` yanıt bekler. Yanıt başlığı dışında hiçbir bayt tüketilmez (TLS el sıkışması sonraki baytlardan başlar): vekil `200`den sonra sunucunun
/// ilk baytlarını göndermez, yanıtı başlık sonunda (CRLFCRLF) bırakır. Başarısızlıkta soket kapatılır.
fn connectHandshake(fd: std.c.fd_t, tn: *const Tunnel, rem_ms: i64) IpAddress.ConnectError!void {
    errdefer _ = std.c.close(fd);
    var req_buf: [768]u8 = undefined;
    const host_is_v6 = std.mem.indexOfScalar(u8, tn.target_host, ':') != null;
    const req = (if (tn.authorization) |auth|
        std.fmt.bufPrint(&req_buf, "CONNECT {s}{s}{s}:{d} HTTP/1.1\r\nHost: {s}{s}{s}:{d}\r\nProxy-Authorization: {s}\r\n\r\n", .{
            if (host_is_v6) "[" else "", tn.target_host, if (host_is_v6) "]" else "", tn.target_port,
            if (host_is_v6) "[" else "", tn.target_host, if (host_is_v6) "]" else "", tn.target_port,
            auth,
        })
    else
        std.fmt.bufPrint(&req_buf, "CONNECT {s}{s}{s}:{d} HTTP/1.1\r\nHost: {s}{s}{s}:{d}\r\n\r\n", .{
            if (host_is_v6) "[" else "", tn.target_host, if (host_is_v6) "]" else "", tn.target_port,
            if (host_is_v6) "[" else "", tn.target_host, if (host_is_v6) "]" else "", tn.target_port,
        })) catch return error.ConnectionRefused;
    const deadline = nowNs() + @min(rem_ms, 30_000) * std.time.ns_per_ms;
    var off: usize = 0;
    while (off < req.len) {
        const n = std.c.write(fd, req[off..].ptr, req.len - off);
        if (n > 0) {
            off += @intCast(n);
            continue;
        }
        if (n < 0 and std.posix.errno(n) == .AGAIN) {
            const left = @divFloor(deadline - nowNs(), std.time.ns_per_ms);
            if (left <= 0 or !waitReady(fd, true, left)) {
                deadlineState().timed_out.* = true;
                return error.Timeout;
            }
            continue;
        }
        return error.ConnectionResetByPeer;
    }
    // Yanıt başlığını BAYT BAYT oku: CRLFCRLF'ten sonrasını (TLS verisi) tüketmemek için.
    var head: [1024]u8 = undefined;
    var len: usize = 0;
    while (true) {
        var byte: [1]u8 = undefined;
        const n = std.c.read(fd, &byte, 1);
        if (n == 1) {
            if (len == head.len) return error.ConnectionRefused;
            head[len] = byte[0];
            len += 1;
            if (len >= 4 and std.mem.eql(u8, head[len - 4 .. len], "\r\n\r\n")) break;
            continue;
        }
        if (n == 0) return error.ConnectionResetByPeer;
        if (std.posix.errno(n) == .AGAIN) {
            const left = @divFloor(deadline - nowNs(), std.time.ns_per_ms);
            if (left <= 0 or !waitReady(fd, false, left)) {
                deadlineState().timed_out.* = true;
                return error.Timeout;
            }
            continue;
        }
        return error.ConnectionResetByPeer;
    }
    // "HTTP/1.x 2xx ..."
    if (len < 12 or !std.mem.startsWith(u8, head[0..len], "HTTP/1.") or head[9] != '2') return error.ConnectionRefused;
}

fn boundedConnectIp(userdata: ?*anyopaque, address: *const IpAddress, options: IpAddress.ConnectOptions) IpAddress.ConnectError!net.Socket {
    // Fiber içinde süresiz bağlanma bile bloklamayan yolla yapılır (kooperatif); fiber dışında süresiz çağrı std'nin özgün uygulamasına gider.
    const tunnel = activeTunnel();
    const rem = remainingMs() orelse (if (fiber_net.inFiber() or tunnel != null) @as(i64, std.math.maxInt(i32)) else return g_base_connect_ip.?(userdata, address, options));
    if (options.mode != .stream or options.protocol != null) return g_base_connect_ip.?(userdata, address, options);
    if (rem == 0) {
        deadlineState().timed_out.* = true;
        return error.Timeout;
    }

    var storage: std.c.sockaddr.storage = std.mem.zeroes(std.c.sockaddr.storage);
    var addr_len: std.c.socklen_t = undefined;
    const family: c_uint = switch (address.*) {
        .ip4 => |a| blk: {
            const sin: *std.c.sockaddr.in = @ptrCast(&storage);
            sin.* = .{ .port = std.mem.nativeToBig(u16, a.port), .addr = @bitCast(a.bytes) };
            addr_len = @sizeOf(std.c.sockaddr.in);
            break :blk std.c.AF.INET;
        },
        .ip6 => |a| blk: {
            const sin6: *std.c.sockaddr.in6 = @ptrCast(&storage);
            sin6.* = .{ .port = std.mem.nativeToBig(u16, a.port), .flowinfo = a.flow, .addr = a.bytes, .scope_id = 0 };
            addr_len = @sizeOf(std.c.sockaddr.in6);
            break :blk std.c.AF.INET6;
        },
    };
    const sa: *const std.c.sockaddr = @ptrCast(&storage);
    // sockaddr'ın ilk baytları (Darwin'de `len`, Linux'ta `family`) std'nin yapılarıyla doldurulur; Darwin için ailesini açıkça yaz.
    @as(*std.c.sockaddr, @constCast(sa)).family = @intCast(family);
    if (comptime builtin.os.tag.isDarwin()) {
        const raw: [*]u8 = @ptrCast(&storage);
        raw[0] = @intCast(addr_len);
    }

    const fd = std.c.socket(family, std.c.SOCK.STREAM, 0);
    if (fd < 0) return errnoToConnectError(@intFromEnum(std.posix.errno(fd)));
    errdefer _ = std.c.close(fd);
    _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, 1)); // FD_CLOEXEC
    if (comptime builtin.os.tag.isDarwin()) {
        const one: c_int = 1;
        _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, &one, @sizeOf(c_int));
    }
    setNonBlocking(fd, true);

    const rc = std.c.connect(fd, sa, addr_len);
    if (rc != 0) {
        const e = std.posix.errno(rc);
        if (e != .INPROGRESS) return errnoToConnectError(@intFromEnum(e));
        const budget = @min(rem, ATTEMPT_CAP_MS);
        var pr: c_int = undefined;
        if (fiber_net.inFiber()) {
            // Kooperatif bekleme: fiber reaktörde askıya alınır, iş parçacığı bloke olmaz.
            pr = switch (fiber_net.waitFd(fd, true, @intCast(budget))) {
                .ready => 1,
                .timed_out => 0,
            };
        } else {
            var pfd = [1]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.OUT, .revents = 0 }};
            pr = std.c.poll(&pfd, 1, @intCast(budget));
        }
        if (pr == 0) {
            if (budget >= rem) deadlineState().timed_out.* = true;
            return error.Timeout;
        }
        if (pr < 0) return error.NetworkUnreachable;
        var so_err: c_int = 0;
        var so_len: std.c.socklen_t = @sizeOf(c_int);
        _ = std.c.getsockopt(fd, std.c.SOL.SOCKET, std.c.SO.ERROR, &so_err, &so_len);
        if (so_err != 0) return errnoToConnectError(so_err);
    }
    if (tunnel) |tn| try connectHandshake(fd, tn, rem);
    setNonBlocking(fd, false);
    return .{ .handle = fd, .address = address.* };
}

// ---- Birim testleri ---------------------------------------------------------------------------------------------------------------

fn testIo(threaded: *Io.Threaded, vtable: *Io.VTable) Io {
    vtable.* = threaded.io().vtable.*;
    install(vtable);
    return .{ .userdata = threaded, .vtable = vtable };
}

test "sınırlı bağlanma: kapalı yerel port hızla reddedilir" {
    if (comptime !enabled) return error.SkipZigTest;
    var threaded = Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
    defer threaded.deinit();
    var vt: Io.VTable = undefined;
    const io = testIo(&threaded, &vt);
    begin(2000);
    defer end();
    const host = try HostName.init("127.0.0.1");
    const t0 = nowNs();
    try std.testing.expectError(error.ConnectionRefused, host.connect(io, 1, .{ .mode = .stream }));
    try std.testing.expect(nowNs() - t0 < 1500 * std.time.ns_per_ms);
}

test "sınırlı bağlanma: cevap vermeyen adres son tarihte bırakılır" {
    if (comptime !enabled) return error.SkipZigTest;
    var threaded = Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
    defer threaded.deinit();
    var vt: Io.VTable = undefined;
    const io = testIo(&threaded, &vt);
    begin(400);
    defer end();
    // 192.0.2.1: TEST-NET-1 (RFC 5737), yönlendirilmez. Rotası olmayan ortamlar hemen "ulaşılamaz" döner; ikisi de kabul, ama 75 sn beklenmez.
    const host = try HostName.init("192.0.2.1");
    const t0 = nowNs();
    if (host.connect(io, 81, .{ .mode = .stream })) |s| {
        s.close(io);
        return error.UnexpectedConnect;
    } else |_| {}
    try std.testing.expect(nowNs() - t0 < 3000 * std.time.ns_per_ms);
}

test "çözümleme: IPv6 literal (köşeli parantezli) ve localhost ağ çözümlemesi olmadan adres verir" {
    if (comptime !enabled) return error.SkipZigTest;
    var threaded = Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
    defer threaded.deinit();
    var vt: Io.VTable = undefined;
    const io = testIo(&threaded, &vt);
    begin(2000);
    defer end();

    var buf: [8]HostName.LookupResult = undefined;
    var q: Io.Queue(HostName.LookupResult) = .init(&buf);
    // std.Uri köşeli parantezli konağı doğrulamadan HostName olarak verir; test de aynı yolu (doğrulamasız) izler.
    try boundedLookup(&threaded, .{ .bytes = "[::1]" }, &q, .{ .port = 80 });
    const first = try q.getOne(io);
    try std.testing.expect(first == .address and first.address == .ip6);
    try std.testing.expectEqual(@as(u16, 80), first.address.ip6.port);

    var buf2: [8]HostName.LookupResult = undefined;
    var q2: Io.Queue(HostName.LookupResult) = .init(&buf2);
    try boundedLookup(&threaded, try HostName.init("localhost"), &q2, .{ .port = 8080 });
    var v4 = false;
    var v6 = false;
    while (q2.getOne(io)) |r| {
        if (r == .address) switch (r.address) {
            .ip4 => v4 = true,
            .ip6 => v6 = true,
        };
    } else |_| {}
    try std.testing.expect(v4 and v6);
}

test "DNS yuvaları: sınıra gelince bekler, süre dolarsa vazgeçer, boşalınca yeniden verir" {
    if (comptime !enabled) return error.SkipZigTest;
    var slots: Slots = .{};
    try std.testing.expect(slots.acquireUntil(2, 0));
    try std.testing.expect(slots.acquireUntil(2, 0));
    // Dolu: son tarihsiz ve kısa son tarihli denemeler başarısız olur.
    try std.testing.expect(!slots.acquireUntil(2, 0));
    const t0 = nowNs();
    try std.testing.expect(!slots.acquireUntil(2, t0 + 20 * std.time.ns_per_ms));
    try std.testing.expect(nowNs() - t0 >= 20 * std.time.ns_per_ms);
    slots.release();
    try std.testing.expect(slots.acquireUntil(2, 0));
    try std.testing.expectEqual(@as(u32, 2), slots.inflight.load(.acquire));
}

test "DNS yuvaları: bekleyen, başka bir iş parçacığı yuva bırakınca devam eder" {
    if (comptime !enabled) return error.SkipZigTest;
    var slots: Slots = .{};
    try std.testing.expect(slots.acquireUntil(1, 0));
    const releaser = try std.Thread.spawn(.{}, struct {
        fn run(sl: *Slots) void {
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 30 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
            sl.release();
        }
    }.run, .{&slots});
    defer releaser.join();
    try std.testing.expect(slots.acquireUntil(1, nowNs() + 2 * std.time.ns_per_s));
}

test "Flights: aynı anahtara katılır, farklı anahtara katılmaz, çıkarılınca yeniden başlar" {
    if (comptime !enabled) return error.SkipZigTest;
    var flights: Flights = .{};
    var a: LookupJob = .{ .port = 443, .family = null };
    @memcpy(a.host_z[0..11], "Example.COM");
    a.host_z[11] = 0;
    try std.testing.expect(flights.insertOrJoin(&a, "Example.COM") == null);

    // Aynı ad (büyük/küçük harf duyarsız), port ve aile: katılır, referans artar.
    try std.testing.expectEqual(@as(?*LookupJob, &a), flights.join("example.com", 443, null));
    try std.testing.expectEqual(@as(u32, 3), a.refs.load(.acquire));
    // Farklı port ya da aile: katılmaz.
    try std.testing.expect(flights.join("example.com", 80, null) == null);
    try std.testing.expect(flights.join("example.com", 443, .ip4) == null);
    try std.testing.expect(flights.join("other.test", 443, null) == null);

    // İkinci bir iş aynı anahtarla eklenmek istenirse mevcut olana katılır, kendisi kaydedilmez.
    var b: LookupJob = .{ .port = 443, .family = null };
    @memcpy(b.host_z[0..11], "example.com");
    b.host_z[11] = 0;
    try std.testing.expectEqual(@as(?*LookupJob, &a), flights.insertOrJoin(&b, "example.com"));

    // Çıkarılınca artık katılınamaz; yeni iş kaydedilebilir.
    flights.remove(&a);
    try std.testing.expect(flights.join("example.com", 443, null) == null);
    try std.testing.expect(flights.insertOrJoin(&b, "example.com") == null);
    flights.remove(&b);
}

const FakeResolver = struct {
    calls: std.atomic.Value(u32) = .init(0),
    gate: std.atomic.Value(bool) = .init(false),

    fn resolve(job: *LookupJob) void {
        const self: *FakeResolver = @ptrCast(@alignCast(job.ctx.?));
        _ = self.calls.fetchAdd(1, .acq_rel);
        while (!self.gate.load(.acquire)) {
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
        }
        job.addrs[0] = .{ .ip4 = .loopback(job.port) };
        job.count = 1;
        job.ok = true;
    }
};

fn sleepMsTest(ms: i64) void {
    var ts: std.c.timespec = .{ .sec = @intCast(@divTrunc(ms, 1000)), .nsec = @intCast(@mod(ms, 1000) * std.time.ns_per_ms) };
    _ = std.c.nanosleep(&ts, null);
}

fn waitSlotsDrained() !void {
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        if (g_lookup_slots.inflight.load(.acquire) == 0) return;
        sleepMsTest(2);
    }
    return error.SlotsNotReleased;
}

test "awaitLookup: 20 eşzamanlı istek aynı ada TEK çözümleme ve TEK iş parçacığı kullanır" {
    if (comptime !enabled) return error.SkipZigTest;
    var fake: FakeResolver = .{};
    const Worker = struct {
        fn run(f: *FakeResolver, ok_count: *std.atomic.Value(u32)) void {
            const job = awaitLookup("singleflight-a.test", 80, null, nowNs() + 5 * std.time.ns_per_s, &FakeResolver.resolve, f) catch return;
            defer job.release();
            if (job.ok and job.count == 1) _ = ok_count.fetchAdd(1, .acq_rel);
        }
    };
    var ok_count: std.atomic.Value(u32) = .init(0);
    var threads: [20]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &fake, &ok_count });
    sleepMsTest(100); // hepsi uçuştaki aramaya katılsın
    try std.testing.expectEqual(@as(u32, 1), g_lookup_slots.inflight.load(.acquire));
    fake.gate.store(true, .release);
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(u32, 20), ok_count.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), fake.calls.load(.acquire));
    try waitSlotsDrained();
}

test "awaitLookup: bir katılımcının zaman aşımı diğerlerini iptal etmez; yuva iş parçacığı bitince boşalır" {
    if (comptime !enabled) return error.SkipZigTest;
    var fake: FakeResolver = .{};
    const Waiter = struct {
        fn run(f: *FakeResolver, ok: *std.atomic.Value(bool)) void {
            const job = awaitLookup("singleflight-b.test", 80, null, nowNs() + 5 * std.time.ns_per_s, &FakeResolver.resolve, f) catch return;
            defer job.release();
            ok.store(job.ok, .release);
        }
    };
    var long_ok: std.atomic.Value(bool) = .init(false);
    const long_waiter = try std.Thread.spawn(.{}, Waiter.run, .{ &fake, &long_ok });
    sleepMs50();
    // Kısa son tarihli katılımcı: çözümleyici kapıda bekliyor, süre dolar.
    try std.testing.expectError(error.TimedOut, awaitLookup("singleflight-b.test", 80, null, nowNs() + 30 * std.time.ns_per_ms, &FakeResolver.resolve, &fake));
    // Çözümleyici hâlâ çalışıyor: yuva dolu, iş parçacığı yaşıyor.
    try std.testing.expectEqual(@as(u32, 1), g_lookup_slots.inflight.load(.acquire));
    fake.gate.store(true, .release);
    long_waiter.join();
    try std.testing.expect(long_ok.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), fake.calls.load(.acquire));
    try waitSlotsDrained();
}

fn sleepMs50() void {
    sleepMsTest(50);
}
