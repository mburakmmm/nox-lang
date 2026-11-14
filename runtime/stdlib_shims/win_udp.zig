//! Windows'ta UDP/QUIC için ince Winsock yardımcıları (v2.1.146): `quic.zig` ve `h3_client.zig` POSIX'te `std.c`yi kullanır; Windows'ta bu dosya aynı işlevleri ws2_32/kernel32 ile sağlar.
//! Yalnızca Windows'ta derlenir (diğer hedeflerde boş bir yapı).

const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;

pub const AF_INET: c_int = 2;
pub const AF_INET6: c_int = 23;
const SOCK_DGRAM: c_int = 2;
const IPPROTO_IPV6: c_int = 41;
const IPV6_V6ONLY: c_int = 27;
const FIONBIO: i32 = -2147195266;
const POLLRDNORM: i16 = 0x0100;

pub const SockAddrIn = extern struct { family: u16 = AF_INET, port: u16 = 0, addr: [4]u8 = .{ 0, 0, 0, 0 }, zero: [8]u8 = @splat(0) };
pub const SockAddrIn6 = extern struct { family: u16 = AF_INET6, port: u16 = 0, flowinfo: u32 = 0, addr: [16]u8 = @splat(0), scope_id: u32 = 0 };
pub const TimeVal = extern struct { sec: c_long, usec: c_long };
const WsaPollFd = extern struct { fd: usize, events: i16, revents: i16 };
pub const AddrInfo = extern struct {
    flags: i32,
    family: i32,
    socktype: i32,
    protocol: i32,
    addrlen: usize,
    canonname: ?[*:0]u8,
    addr: ?*anyopaque,
    next: ?*AddrInfo,
};

const Ws = if (is_windows) struct {
    extern "ws2_32" fn WSAStartup(version: u16, data: *[512]u8) callconv(.c) i32;
    extern "ws2_32" fn socket(af: c_int, kind: c_int, proto: c_int) callconv(.c) usize;
    extern "ws2_32" fn closesocket(s: usize) callconv(.c) c_int;
    extern "ws2_32" fn bind(s: usize, addr: *const anyopaque, len: c_int) callconv(.c) c_int;
    extern "ws2_32" fn connect(s: usize, addr: *const anyopaque, len: c_int) callconv(.c) c_int;
    extern "ws2_32" fn getsockname(s: usize, addr: *anyopaque, len: *c_int) callconv(.c) c_int;
    extern "ws2_32" fn setsockopt(s: usize, level: c_int, name: c_int, val: *const anyopaque, len: c_int) callconv(.c) c_int;
    extern "ws2_32" fn ioctlsocket(s: usize, cmd: i32, argp: *u32) callconv(.c) c_int;
    extern "ws2_32" fn WSAPoll(fds: [*]WsaPollFd, n: u32, timeout: c_int) callconv(.c) c_int;
    extern "ws2_32" fn getaddrinfo(node: ?[*:0]const u8, service: ?[*:0]const u8, hints: ?*const AddrInfo, res: *?*AddrInfo) callconv(.c) c_int;
    extern "ws2_32" fn freeaddrinfo(res: ?*AddrInfo) callconv(.c) void;
    extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.c) c_int;
    extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.c) c_int;
} else struct {};

var g_wsa_done: std.atomic.Value(bool) = .init(false);
fn ensureWsa() void {
    if (comptime !is_windows) return;
    if (g_wsa_done.load(.acquire)) return;
    var data: [512]u8 = undefined;
    _ = Ws.WSAStartup(0x0202, &data); // tekrar çağrılması zararsız (sayaçlıdır)
    g_wsa_done.store(true, .release);
}

pub fn udpSocket(family: c_int) ?usize {
    ensureWsa();
    const s = Ws.socket(family, SOCK_DGRAM, 0);
    if (s == ~@as(usize, 0)) return null;
    setNonBlocking(s);
    return s;
}

pub fn setNonBlocking(s: usize) void {
    var mode: u32 = 1;
    _ = Ws.ioctlsocket(s, FIONBIO, &mode);
}

pub fn close(s: usize) void {
    _ = Ws.closesocket(s);
}

pub fn bind4(s: usize, addr: [4]u8, port: u16) ?u16 {
    var sa: SockAddrIn = .{ .port = std.mem.nativeToBig(u16, port), .addr = addr };
    if (Ws.bind(s, &sa, @sizeOf(SockAddrIn)) != 0) return null;
    var real: SockAddrIn = .{};
    var rl: c_int = @sizeOf(SockAddrIn);
    _ = Ws.getsockname(s, &real, &rl);
    return std.mem.bigToNative(u16, real.port);
}

pub fn bind6(s: usize, addr: [16]u8, port: u16) ?u16 {
    var off: c_int = 0;
    _ = Ws.setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &off, @sizeOf(c_int)); // çift yığın
    var sa: SockAddrIn6 = .{ .port = std.mem.nativeToBig(u16, port), .addr = addr };
    if (Ws.bind(s, &sa, @sizeOf(SockAddrIn6)) != 0) return null;
    var real: SockAddrIn6 = .{};
    var rl: c_int = @sizeOf(SockAddrIn6);
    _ = Ws.getsockname(s, &real, &rl);
    return std.mem.bigToNative(u16, real.port);
}

pub fn connect4(s: usize, addr: [4]u8, port_be: u16) bool {
    var sa: SockAddrIn = .{ .port = port_be, .addr = addr };
    return Ws.connect(s, &sa, @sizeOf(SockAddrIn)) == 0;
}

pub fn connect6(s: usize, addr: [16]u8, port_be: u16) bool {
    var sa: SockAddrIn6 = .{ .port = port_be, .addr = addr };
    return Ws.connect(s, &sa, @sizeOf(SockAddrIn6)) == 0;
}

/// Fiber dışında bloklayan bekleme: soket okunabilir olana ya da `ms` dolana kadar.
pub fn pollReadable(s: usize, ms: u32) void {
    var p = [1]WsaPollFd{.{ .fd = s, .events = POLLRDNORM, .revents = 0 }};
    _ = Ws.WSAPoll(&p, 1, @intCast(@min(ms, 1 << 30)));
}

var g_qpc_freq: std.atomic.Value(i64) = .init(0);
pub fn nowMs() i64 {
    var f = g_qpc_freq.load(.monotonic);
    if (f == 0) {
        _ = Ws.QueryPerformanceFrequency(&f);
        g_qpc_freq.store(f, .monotonic);
    }
    var c: i64 = 0;
    _ = Ws.QueryPerformanceCounter(&c);
    return @divTrunc(c * 1000, f);
}

pub fn getaddrinfoUdp(host: [*:0]const u8, out: *?*AddrInfo) bool {
    ensureWsa();
    var hints: AddrInfo = std.mem.zeroes(AddrInfo);
    hints.socktype = SOCK_DGRAM;
    return Ws.getaddrinfo(host, null, &hints, out) == 0;
}

pub fn freeaddrinfo(l: ?*AddrInfo) void {
    Ws.freeaddrinfo(l);
}

/// DLL yükleme (QUIC için OpenSSL >= 3.5): `std.DynLib` Windows'ta yok.
const K32 = if (is_windows) struct {
    extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(h: ?*anyopaque, name: [*:0]const u8) callconv(.c) ?*anyopaque;
} else struct {};

pub fn loadLibrary(name: [*:0]const u8) ?*anyopaque {
    return K32.LoadLibraryA(name);
}

pub fn procAddress(h: ?*anyopaque, name: [*:0]const u8) ?*anyopaque {
    return K32.GetProcAddress(h, name);
}
