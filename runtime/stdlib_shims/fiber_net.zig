//! Fiber-uyumlu (thread'siz) ağ G/Ç'si: `std.http.Client` (ve altındaki TLS) bir fiber'ın içinde çalıştırıldığında soket okuma/yazma/bağlanma ve DNS beklemeleri işletim sistemi
//! iş parçacığını BLOKE ETMEZ, fiber'ı reaktörde askıya alır (bkz. spec §3.321.5). Eskiden her `nox.http` isteği için bir işçi iş parçacığı açılıyordu.
//!
//! Nasıl çalışır: `install` paylaşılan istemci `Io` vtable'ının `netRead`/`netWrite` girişlerini yamalar. Çağıran bir zamanlayıcı iş parçacığındaki fiber ise
//! (`bridge.currentFiberScheduler() != null`) işlem `MSG_DONTWAIT` ile denenir, `EAGAIN`de fiber reaktörde (`suspendForIo`) askıya alınır; değilse (sıradan iş parçacığı)
//! std'nin özgün bloklayan uygulaması çağrılır. Böylece AYNI vtable hem eski iş parçacığı yolunu hem fiber yolunu destekler. Windows/wasm/freestanding'de (`enabled == false`) hiçbir şey yapılmaz.

const std = @import("std");
const builtin = @import("builtin");
const bridge = @import("../async_rt/bridge.zig");
const io_reactor = @import("../async_rt/io_reactor.zig");
const net_dial = @import("net_dial.zig");

const Io = std.Io;
const net = std.Io.net;
const posix = std.posix;

pub const enabled = net_dial.enabled;

var g_base_read: ?@TypeOf(@as(Io.VTable, undefined).netRead) = null;
var g_base_write: ?@TypeOf(@as(Io.VTable, undefined).netWrite) = null;
var g_base_close: ?@TypeOf(@as(Io.VTable, undefined).netClose) = null;
const is_win = builtin.os.tag == .windows;
const win = @import("win_udp.zig");

/// Çağıran bir zamanlayıcıdaki fiber mi? (Bloklamayan yolun kapısı.)
pub fn inFiber() bool {
    if (comptime !enabled) return false;
    return bridge.currentFiberScheduler() != null;
}

/// Fiber'ı `fd`'nin `filter` yönünde hazır olmasına ya da `timeout_ms`'ye kadar askıya alır. Yalnızca fiber içinde çağrılır.
pub const WaitResult = enum { ready, timed_out };

pub fn waitFd(fd: posix.fd_t, write: bool, timeout_ms: ?u32) WaitResult {
    const sched = bridge.currentFiberScheduler().?;
    const filter: io_reactor.Filter = if (write) .write else .read;
    if (timeout_ms) |t| {
        return switch (sched.suspendForIoOrTimeout(fd, filter, t)) {
            .ready => .ready,
            .timed_out => .timed_out,
        };
    }
    sched.suspendForIo(fd, filter);
    return .ready;
}

/// Kooperatif uyku için hiç yazılmayan borular: reaktör bir fd'yi (ident, filtre) çiftiyle tanır, bu yüzden AYNI fd'yi bekleyen ikinci fiber birincinin kaydını ezip onu sonsuza dek
/// uyutur. Her eşzamanlı uyuyan fiber kendi boru çiftini kullanır (yazma ucu açık kalır: kapanırsa okuma ucu EOF ile hemen "hazır" olurdu); boş çiftler iş parçacığı başına küçük bir
/// yığında geri dönüştürülür, üst sınır aşılırsa kapatılır.
const MAX_IDLE_SLEEP_PIPES = 32;
threadlocal var tl_idle_pipes: [MAX_IDLE_SLEEP_PIPES][2]c_int = undefined;
threadlocal var tl_idle_pipe_count: usize = 0;

fn takeSleepPipe() ?[2]c_int {
    if (tl_idle_pipe_count > 0) {
        tl_idle_pipe_count -= 1;
        return tl_idle_pipes[tl_idle_pipe_count];
    }
    var fds: [2]c_int = undefined;
    if (std.c.pipe(&fds) != 0) return null;
    return fds;
}

fn giveSleepPipe(fds: [2]c_int) void {
    if (tl_idle_pipe_count < MAX_IDLE_SLEEP_PIPES) {
        tl_idle_pipes[tl_idle_pipe_count] = fds;
        tl_idle_pipe_count += 1;
    } else {
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
    }
}

/// Fiber içindeysek `ms` milisaniye KOOPERATİF uyur (zamanlayıcı iş parçacığı başka fiber çalıştırır) ve `true` döner; fiber değilsek `false` (çağıran kendi bloklayan beklemesini yapar).
/// Windows (v2.1.39): ağ G/Ç'si fiber-uyumlu DEĞİL (`enabled == false`), ama reaktör (`WSAPoll`) zaman aşımlı beklemeyi destekler: `sleep_ms` yalnızca çağıran fiber'ı askıya alsın diye
/// hiç yazılmayan bir loopback soket çifti zaman aşımıyla beklenir (POSIX'teki `pipe` hilesinin karşılığı). `Task.wait`, `Channel.wait`, `signal.wait`, `TaskGroup` buna dayanır.
const WIN_IDLE_POOL = 8;
threadlocal var tl_win_pairs: [WIN_IDLE_POOL][2]posix.fd_t = undefined;
threadlocal var tl_win_count: usize = 0;

fn sleepCooperativeWindows(ms: u32) bool {
    if (bridge.currentFiberScheduler() == null) return false;
    const pair: [2]posix.fd_t = if (tl_win_count > 0) blk: {
        tl_win_count -= 1;
        break :blk tl_win_pairs[tl_win_count];
    } else (io_reactor.makeIdlePair() catch return false);
    _ = waitFd(pair[0], false, @max(ms, 1));
    if (tl_win_count < WIN_IDLE_POOL) {
        tl_win_pairs[tl_win_count] = pair;
        tl_win_count += 1;
    } else {
        io_reactor.closeIdleFd(pair[0]);
        io_reactor.closeIdleFd(pair[1]);
    }
    return true;
}

pub fn sleepCooperative(ms: u32) bool {
    if (comptime builtin.os.tag == .windows) return sleepCooperativeWindows(ms);
    if (comptime !enabled) return false;
    if (!inFiber()) return false;
    const fds = takeSleepPipe() orelse return false;
    _ = waitFd(fds[0], false, @max(ms, 1));
    giveSleepPipe(fds);
    return true;
}

fn fiberRead(userdata: ?*anyopaque, fd: net.Socket.Handle, data: [][]u8) net.Stream.Reader.Error!usize {
    if (comptime is_win) unreachable; // Windows `winRead` kullanır
    if (!inFiber()) return g_base_read.?(userdata, fd, data);
    var iovecs: [16]posix.iovec = undefined;
    var n: usize = 0;
    for (data) |buf| {
        if (n == iovecs.len) break;
        if (buf.len != 0) {
            iovecs[n] = .{ .base = buf.ptr, .len = buf.len };
            n += 1;
        }
    }
    std.debug.assert(n > 0);
    var msg: posix.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = &iovecs,
        .iovlen = @intCast(n),
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    while (true) {
        const rc = posix.system.recvmsg(fd, &msg, posix.MSG.DONTWAIT);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => {
                _ = waitFd(fd, false, null);
                continue;
            },
            .NOBUFS, .NOMEM => return error.SystemResources,
            .NOTCONN => return error.SocketUnconnected,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.Timeout,
            .NETDOWN => return error.NetworkDown,
            else => |e| return posix.unexpectedErrno(e),
        }
    }
}

fn addBuf(iovecs: []posix.iovec_const, len: *usize, bytes: []const u8) void {
    if (bytes.len == 0 or len.* == iovecs.len) return;
    iovecs[len.*] = .{ .base = bytes.ptr, .len = bytes.len };
    len.* += 1;
}

fn fiberWrite(userdata: ?*anyopaque, fd: net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) net.Stream.Writer.Error!usize {
    if (comptime is_win) unreachable; // Windows `winWrite` kullanır
    if (!inFiber()) return g_base_write.?(userdata, fd, header, data, splat);
    var iovecs: [16]posix.iovec_const = undefined;
    var n: usize = 0;
    addBuf(&iovecs, &n, header);
    for (data[0 .. data.len - 1]) |bytes| addBuf(&iovecs, &n, bytes);
    const pattern = data[data.len - 1];
    var splat_buf: [256]u8 = undefined;
    switch (splat) {
        0 => {},
        1 => addBuf(&iovecs, &n, pattern),
        else => switch (pattern.len) {
            0 => {},
            1 => {
                // Tek baytlık desen: bir kısmı yeter (kısmi yazma serbesttir, yazıcı kalanı için yeniden çağırır).
                const len = @min(splat_buf.len, splat);
                @memset(splat_buf[0..len], pattern[0]);
                addBuf(&iovecs, &n, splat_buf[0..len]);
            },
            else => {
                var i: usize = 0;
                while (i < splat and n < iovecs.len) : (i += 1) addBuf(&iovecs, &n, pattern);
            },
        },
    }
    var msg: posix.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iovecs,
        .iovlen = @intCast(n),
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    while (true) {
        const rc = posix.system.sendmsg(fd, &msg, posix.MSG.NOSIGNAL | posix.MSG.DONTWAIT);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => {
                _ = waitFd(fd, true, null);
                continue;
            },
            .CONNRESET => return error.ConnectionResetByPeer,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .PIPE, .NOTCONN => return error.SocketUnconnected,
            .HOSTUNREACH => return error.HostUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .NETDOWN => return error.NetworkDown,
            else => |e| return posix.unexpectedErrno(e),
        }
    }
}

// ---- Windows (v2.1.147) ---------------------------------------------------------------------------------------------------------
// Soketler `net_dial.zig`de Winsock ile açılır ve HEP bloklamasızdır; okuma/yazma `WSARecv`/`WSASend` + `WindowsReactor` (fiber içinde) ya da `WSAPoll` (fiber dışında) ile bekler.
// POSIX'teki gibi iki durumda da aynı kod yolu çalışır (std'nin AFD tabanlı `netReadWindows` kullanılmaz).

fn waitSock(handle: net.Socket.Handle, write: bool) void {
    if (inFiber()) {
        _ = waitFd(handle, write, null);
    } else {
        _ = win.pollReady(@intFromPtr(handle), write, null);
    }
}

fn winRead(userdata: ?*anyopaque, handle: net.Socket.Handle, data: [][]u8) net.Stream.Reader.Error!usize {
    _ = userdata;
    var bufs: [16]win.WsaBuf = undefined;
    var n: usize = 0;
    for (data) |buf| {
        if (n == bufs.len) break;
        if (buf.len != 0) {
            bufs[n] = .{ .len = @intCast(@min(buf.len, std.math.maxInt(u32))), .buf = buf.ptr };
            n += 1;
        }
    }
    std.debug.assert(n > 0);
    const s: usize = @intFromPtr(handle);
    while (true) {
        switch (win.recvVec(s, bufs[0..n])) {
            .n => |got| return got,
            .err => |e| switch (e) {
                win.WSAEINTR => continue,
                win.WSAEWOULDBLOCK => {
                    waitSock(handle, false);
                    continue;
                },
                win.WSAENOBUFS => return error.SystemResources,
                win.WSAENOTCONN => return error.SocketUnconnected,
                win.WSAECONNRESET, win.WSAECONNABORTED => return error.ConnectionResetByPeer,
                win.WSAETIMEDOUT => return error.Timeout,
                win.WSAENETDOWN => return error.NetworkDown,
                win.WSAESHUTDOWN => return 0,
                else => return error.Unexpected,
            },
        }
    }
}

fn addWsaBuf(bufs: []win.WsaBuf, len: *usize, bytes: []const u8) void {
    if (bytes.len == 0 or len.* == bufs.len) return;
    bufs[len.*] = .{ .len = @intCast(@min(bytes.len, std.math.maxInt(u32))), .buf = @constCast(bytes.ptr) };
    len.* += 1;
}

fn winWrite(userdata: ?*anyopaque, handle: net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) net.Stream.Writer.Error!usize {
    _ = userdata;
    var bufs: [16]win.WsaBuf = undefined;
    var n: usize = 0;
    addWsaBuf(&bufs, &n, header);
    for (data[0 .. data.len - 1]) |bytes| addWsaBuf(&bufs, &n, bytes);
    const pattern = data[data.len - 1];
    var splat_buf: [256]u8 = undefined;
    switch (splat) {
        0 => {},
        1 => addWsaBuf(&bufs, &n, pattern),
        else => switch (pattern.len) {
            0 => {},
            1 => {
                const len = @min(splat_buf.len, splat);
                @memset(splat_buf[0..len], pattern[0]);
                addWsaBuf(&bufs, &n, splat_buf[0..len]);
            },
            else => {
                var i: usize = 0;
                while (i < splat and n < bufs.len) : (i += 1) addWsaBuf(&bufs, &n, pattern);
            },
        },
    }
    const s: usize = @intFromPtr(handle);
    while (true) {
        switch (win.sendVec(s, bufs[0..n])) {
            .n => |sent| return sent,
            .err => |e| switch (e) {
                win.WSAEINTR => continue,
                win.WSAEWOULDBLOCK => {
                    waitSock(handle, true);
                    continue;
                },
                win.WSAECONNRESET, win.WSAECONNABORTED => return error.ConnectionResetByPeer,
                win.WSAENOBUFS => return error.SystemResources,
                win.WSAESHUTDOWN, win.WSAENOTCONN => return error.SocketUnconnected,
                win.WSAEHOSTUNREACH => return error.HostUnreachable,
                win.WSAENETUNREACH => return error.NetworkUnreachable,
                win.WSAENETDOWN => return error.NetworkDown,
                else => return error.Unexpected,
            },
        }
    }
}

fn winClose(userdata: ?*anyopaque, handles: []const net.Socket.Handle) void {
    for (handles) |h| {
        if (!win.closeChecked(@intFromPtr(h))) g_base_close.?(userdata, &.{h});
    }
}

/// Paylaşılan istemci `Io` vtable'ına bağlanır (`net_dial.install`dan SONRA, bir kez).
pub fn install(vtable: *Io.VTable) void {
    if (comptime !enabled) return;
    g_base_read = vtable.netRead;
    g_base_write = vtable.netWrite;
    if (comptime is_win) {
        g_base_close = vtable.netClose;
        vtable.netRead = winRead;
        vtable.netWrite = winWrite;
        vtable.netClose = winClose;
        return;
    }
    vtable.netRead = fiberRead;
    vtable.netWrite = fiberWrite;
}
