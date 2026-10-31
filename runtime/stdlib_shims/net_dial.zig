//! TODO 3.8 (v2.0.91): sınırlı DNS + TCP bağlanması. `nox.http` zaman aşımı yalnızca bağlantı kurulduktan SONRA işliyordu; çözülemeyen bir ad (macOS'ta 30 sn) ya da
//! cevap vermeyen bir adres (75 sn) isteği o kadar bloke ederdi ve mobil ağlarda bu "takıldı" demektir. Ayrıca Android yalnızca IPv4 çözümlüyordu (IPv6-only/DNS64 ağlar
//! çalışmazdı) ve `[::1]` gibi IPv6 literal URL'leri her platformda hata veriyordu.
//!
//! Çözüm `std.Io` vtable'ının iki girişini değiştirir (bkz. `install`): `netLookup` sistem `getaddrinfo`sunu (AF_UNSPEC: IPv4 + IPv6, işletim sisteminin RFC 6724 sırası) bir yardımcı
//! iş parçacığında çalıştırır ve son tarihte vazgeçer; `netConnectIp` bloklamasız `connect` + `poll` ile son tarihe kadar bekler. Son tarih iş parçacığı-yerel bir değerdir
//! (`begin`/`end`); ayarlı değilse çağrı std'nin özgün uygulamasına gider (davranış değişmez). Windows/wasm/freestanding'de hiçbir şey yapılmaz.

const std = @import("std");
const builtin = @import("builtin");

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

threadlocal var tl_deadline_ns: i64 = 0;
threadlocal var tl_timed_out: bool = false;

/// `install`a verilen (yamalı) vtable; `Queue.close/putOne` için `Io` değeri kurarken kullanılır.
var g_vtable: ?*const Io.VTable = null;
var g_base_lookup: ?@TypeOf(@as(Io.VTable, undefined).netLookup) = null;
var g_base_connect_ip: ?@TypeOf(@as(Io.VTable, undefined).netConnectIp) = null;

fn nowNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Bu iş parçacığındaki sonraki DNS/bağlanma çağrıları için `timeout_ms` süre tanır (0 = sınırsız). `end` ile temizlenir.
pub fn begin(timeout_ms: u64) void {
    if (comptime !enabled) return;
    tl_timed_out = false;
    tl_deadline_ns = if (timeout_ms == 0) 0 else nowNs() + @as(i64, @intCast(@min(timeout_ms, std.math.maxInt(i32)))) * std.time.ns_per_ms;
}

pub fn end() void {
    if (comptime !enabled) return;
    tl_deadline_ns = 0;
}

/// Son `begin`den beri bir DNS/bağlanma son tarihi aşıldı mı? (çağıran bunu "zaman aşımı" hata türüne çevirir)
pub fn timedOut() bool {
    if (comptime !enabled) return false;
    return tl_timed_out;
}

fn remainingMs() ?i64 {
    if (tl_deadline_ns == 0) return null;
    const left = @divFloor(tl_deadline_ns - nowNs(), std.time.ns_per_ms);
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

const LookupJob = struct {
    refs: std.atomic.Value(u32) = .init(2),
    done: std.atomic.Value(bool) = .init(false),
    ok: bool = false,
    host_z: [HostName.max_len + 1]u8 = undefined,
    port: u16,
    family: ?IpAddress.Family,
    count: usize = 0,
    addrs: [MAX_ADDRS]IpAddress = undefined,

    fn release(self: *LookupJob) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) std.heap.page_allocator.destroy(self);
    }
};

fn lookupThread(job: *LookupJob) void {
    defer job.release();
    resolveInto(job);
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

fn boundedLookup(
    userdata: ?*anyopaque,
    host_name: HostName,
    resolved: *Io.Queue(HostName.LookupResult),
    options: HostName.LookupOptions,
) HostName.LookupError!void {
    const rem = remainingMs();
    const t_io: Io = .{ .userdata = userdata, .vtable = g_vtable.? };
    defer resolved.close(t_io);
    var name = host_name.bytes;
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
    if (rem) |r| {
        // Son tarihli çözümleme: yardımcı iş parçacığı; vazgeçilirse iş parçacığı kendi payını bırakır.
        job = std.heap.page_allocator.create(LookupJob) catch return error.NameServerFailure;
        job.* = .{ .port = options.port, .family = options.family };
        heap_job = true;
        @memcpy(job.host_z[0..name.len], name);
        job.host_z[name.len] = 0;
        const th = std.Thread.spawn(.{}, lookupThread, .{job}) catch {
            std.heap.page_allocator.destroy(job);
            return error.NameServerFailure;
        };
        th.detach();
        const deadline = nowNs() + r * std.time.ns_per_ms;
        while (!job.done.load(.acquire)) {
            if (nowNs() >= deadline) {
                tl_timed_out = true;
                job.release();
                return error.NameServerFailure;
            }
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
        }
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

fn boundedConnectIp(userdata: ?*anyopaque, address: *const IpAddress, options: IpAddress.ConnectOptions) IpAddress.ConnectError!net.Socket {
    const rem = remainingMs() orelse return g_base_connect_ip.?(userdata, address, options);
    if (options.mode != .stream or options.protocol != null) return g_base_connect_ip.?(userdata, address, options);
    if (rem == 0) {
        tl_timed_out = true;
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
        var pfd = [1]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.OUT, .revents = 0 }};
        const pr = std.c.poll(&pfd, 1, @intCast(budget));
        if (pr == 0) {
            if (budget >= rem) tl_timed_out = true;
            return error.Timeout;
        }
        if (pr < 0) return error.NetworkUnreachable;
        var so_err: c_int = 0;
        var so_len: std.c.socklen_t = @sizeOf(c_int);
        _ = std.c.getsockopt(fd, std.c.SOL.SOCKET, std.c.SO.ERROR, &so_err, &so_len);
        if (so_err != 0) return errnoToConnectError(so_err);
    }
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
