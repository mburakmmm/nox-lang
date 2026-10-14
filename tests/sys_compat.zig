//! Test istemcilerinin soket ve saat çağrıları. macOS/Linux'ta `std.c`
//! ile aynıdır. Windows'ta Winsock (`ws2_32`) ve `kernel32.Sleep`
//! kullanılır; CRT `read`/`write` bir `SOCKET` üzerinde geçersizdir.
const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

pub const fd_t = if (is_windows) usize else i32;
pub const bad_fd: fd_t = if (is_windows) ~@as(usize, 0) else -1;

pub fn badFd(fd: fd_t) bool {
    if (is_windows) return fd == bad_fd;
    return fd < 0;
}

const Impl = if (is_windows) Win else Posix;
pub const socket = Impl.socket;
pub const bind = Impl.bind;
pub const listen = Impl.listen;
pub const accept = Impl.accept;
pub const connect = Impl.connect;
pub const close = Impl.close;
pub const read = Impl.read;
pub const write = Impl.write;
pub const setsockopt = Impl.setsockopt;
pub const getsockname = Impl.getsockname;
pub const poll = Impl.poll;
pub const nanosleep = Impl.nanosleep;
pub const clock_gettime = Impl.clock_gettime;
pub const AF = Impl.AF;
pub const SOCK = Impl.SOCK;
pub const SOL = Impl.SOL;
pub const SO = Impl.SO;
pub const POLL = Impl.POLL;
pub const CLOCK = if (is_windows) Win.ClockId else Posix.CLOCK;
pub const sockaddr = Impl.sockaddr;
pub const socklen_t = if (is_windows) Win.SockLen else Posix.socklen_t;
pub const pollfd = if (is_windows) Win.PollFd else Posix.pollfd;
pub const timespec = if (is_windows) Win.TimeSpec else Posix.timespec;

const Posix = struct {
    pub const socket = std.c.socket;
    pub const bind = std.c.bind;
    pub const listen = std.c.listen;
    pub const accept = std.c.accept;
    pub const connect = std.c.connect;
    pub const close = std.c.close;
    pub const read = std.c.read;
    pub const write = std.c.write;
    pub const setsockopt = std.c.setsockopt;
    pub const getsockname = std.c.getsockname;
    pub const poll = std.c.poll;
    pub const nanosleep = std.c.nanosleep;
    pub const clock_gettime = std.c.clock_gettime;
    pub const AF = std.c.AF;
    pub const SOCK = std.c.SOCK;
    pub const SOL = std.c.SOL;
    pub const SO = std.c.SO;
    pub const POLL = std.c.POLL;
    pub const CLOCK = std.c.CLOCK;
    pub const sockaddr = std.c.sockaddr;
    pub const socklen_t = std.c.socklen_t;
    pub const pollfd = std.c.pollfd;
    pub const timespec = std.c.timespec;
};

const Win = struct {
    const ws2 = std.os.windows.ws2_32;
    const SOCKET = usize;
    const INVALID_SOCKET: SOCKET = ~@as(SOCKET, 0);

    const api = struct {
        extern "ws2_32" fn WSAStartup(version_requested: u16, data: *[512]u8) callconv(.c) i32;
        extern "ws2_32" fn socket(af: i32, socket_type: i32, protocol: i32) callconv(.c) SOCKET;
        extern "ws2_32" fn bind(s: SOCKET, addr: *const ws2.sockaddr.in, namelen: i32) callconv(.c) i32;
        extern "ws2_32" fn listen(s: SOCKET, backlog: i32) callconv(.c) i32;
        extern "ws2_32" fn accept(s: SOCKET, addr: ?*anyopaque, addrlen: ?*i32) callconv(.c) SOCKET;
        extern "ws2_32" fn connect(s: SOCKET, addr: *const ws2.sockaddr.in, namelen: i32) callconv(.c) i32;
        extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: i32, flags: i32) callconv(.c) i32;
        extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: i32, flags: i32) callconv(.c) i32;
        extern "ws2_32" fn closesocket(s: SOCKET) callconv(.c) i32;
        extern "ws2_32" fn setsockopt(s: SOCKET, level: i32, optname: i32, optval: ?*const anyopaque, optlen: i32) callconv(.c) i32;
        extern "ws2_32" fn getsockopt(s: SOCKET, level: i32, optname: i32, optval: *anyopaque, optlen: *i32) callconv(.c) i32;
        extern "ws2_32" fn getsockname(s: SOCKET, addr: *ws2.sockaddr.in, namelen: *i32) callconv(.c) i32;
        extern "ws2_32" fn WSAPoll(fds: [*]PollFd, nfds: u32, timeout_ms: i32) callconv(.c) i32;
        extern "ws2_32" fn ioctlsocket(s: SOCKET, cmd: i32, argp: *u32) callconv(.c) i32;
        extern "ws2_32" fn WSAGetLastError() callconv(.c) i32;
        extern "kernel32" fn Sleep(ms: u32) callconv(.c) void;
        extern "kernel32" fn GetSystemTimePreciseFileTime(out: *i64) callconv(.c) void;
        extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.c) i32;
        extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.c) i32;
    };

    pub const AF = struct {
        pub const INET: i32 = 2;
        pub const INET6: i32 = 23;
    };
    pub const SOCK = struct {
        pub const STREAM: i32 = 1;
    };
    pub const SOL = struct {
        pub const SOCKET: i32 = 0xffff;
    };
    pub const SO = struct {
        pub const REUSEADDR: i32 = 0x0004;
        pub const SNDTIMEO: i32 = 0x1005;
        pub const RCVTIMEO: i32 = 0x1006;
        pub const ERROR: i32 = 0x1007;
    };
    pub const POLL = struct {
        pub const IN: i16 = 0x0100;
        pub const OUT: i16 = 0x0010;
    };
    /// `ioctlsocket` FIONBIO. Tek bir `connect` TCP yeniden denemesinde
    /// onlarca saniye bekleyemesin diye bağlantı bu sürede kesilir.
    const fionbio: i32 = @bitCast(@as(u32, 0x8004667e));
    const io_timeout_ms: u32 = 15_000;
    pub const ClockId = enum { REALTIME, MONOTONIC };
    pub const sockaddr = struct {
        pub const in = ws2.sockaddr.in;
    };
    pub const SockLen = i32;
    pub const PollFd = extern struct {
        fd: SOCKET,
        events: i16,
        revents: i16,
    };
    pub const TimeSpec = struct {
        sec: i64 = 0,
        nsec: i64 = 0,
    };

    fn startup() void {
        var data: [512]u8 = undefined;
        _ = api.WSAStartup(0x0202, &data);
    }

    pub fn socket(af: i32, socket_type: i32, protocol: i32) fd_t {
        startup();
        const fd = api.socket(af, socket_type, protocol);
        if (fd == INVALID_SOCKET) return bad_fd;
        // Bloklayan `recv`/`send` sunucu kapanmazsa testi sonsuza kadar
        // tutar. Süre dolunca çağrı hata döner, test düşer.
        var ms: u32 = io_timeout_ms;
        _ = api.setsockopt(fd, @This().SOL.SOCKET, @This().SO.RCVTIMEO, &ms, @sizeOf(u32));
        _ = api.setsockopt(fd, @This().SOL.SOCKET, @This().SO.SNDTIMEO, &ms, @sizeOf(u32));
        return fd;
    }

    pub fn bind(sock: fd_t, address: ?*const anyopaque, address_len: usize) i32 {
        _ = address_len;
        const addr: *const ws2.sockaddr.in = @ptrCast(@alignCast(address));
        return api.bind(sock, addr, @sizeOf(ws2.sockaddr.in));
    }

    pub fn listen(sock: fd_t, backlog: i32) i32 {
        return api.listen(sock, backlog);
    }

    pub fn accept(sock: fd_t, addr: ?*anyopaque, addrlen: ?*anyopaque) fd_t {
        _ = addr;
        _ = addrlen;
        const fd = api.accept(sock, null, null);
        if (fd == INVALID_SOCKET) return bad_fd;
        return fd;
    }

    pub fn connect(sock: fd_t, address: ?*const anyopaque, address_len: usize) i32 {
        _ = address_len;
        const addr: *const ws2.sockaddr.in = @ptrCast(@alignCast(address));
        var nonblock: u32 = 1;
        if (api.ioctlsocket(sock, fionbio, &nonblock) != 0) return -1;
        const rc = api.connect(sock, addr, @sizeOf(ws2.sockaddr.in));
        if (rc != 0) {
            const err = api.WSAGetLastError();
            const pending = err == 10035 or err == 10036 or err == 10037;
            if (!pending) {
                nonblock = 0;
                _ = api.ioctlsocket(sock, fionbio, &nonblock);
                return -1;
            }
            var pfd = [_]PollFd{.{ .fd = sock, .events = @This().POLL.IN | @This().POLL.OUT, .revents = 0 }};
            if (api.WSAPoll(&pfd, 1, 200) <= 0) {
                nonblock = 0;
                _ = api.ioctlsocket(sock, fionbio, &nonblock);
                return -1;
            }
            var so_error: i32 = 0;
            var so_len: i32 = @sizeOf(i32);
            if (api.getsockopt(sock, @This().SOL.SOCKET, @This().SO.ERROR, &so_error, &so_len) != 0 or so_error != 0) {
                nonblock = 0;
                _ = api.ioctlsocket(sock, fionbio, &nonblock);
                return -1;
            }
        }
        nonblock = 0;
        if (api.ioctlsocket(sock, fionbio, &nonblock) != 0) return -1;
        return 0;
    }

    pub fn close(sock: fd_t) i32 {
        return api.closesocket(sock);
    }

    pub fn read(sock: fd_t, buf: [*]u8, nbyte: usize) isize {
        return api.recv(sock, buf, @intCast(nbyte), 0);
    }

    pub fn write(sock: fd_t, buf: [*]const u8, nbyte: usize) isize {
        return api.send(sock, buf, @intCast(nbyte), 0);
    }

    pub fn setsockopt(sock: fd_t, level: i32, optname: i32, optval: ?*const anyopaque, optlen: usize) i32 {
        return api.setsockopt(sock, level, optname, optval, @intCast(optlen));
    }

    pub fn getsockname(sock: fd_t, addr: *anyopaque, addrlen: *SockLen) i32 {
        const got: *ws2.sockaddr.in = @ptrCast(@alignCast(addr));
        return api.getsockname(sock, got, addrlen);
    }

    pub fn poll(fds: [*]PollFd, nfds: usize, timeout: i32) i32 {
        startup();
        return api.WSAPoll(fds, @intCast(nfds), timeout);
    }

    pub fn nanosleep(req: *const TimeSpec, rem: ?*TimeSpec) i32 {
        _ = rem;
        var ms: u64 = 0;
        if (req.sec > 0) ms += @as(u64, @intCast(req.sec)) * 1000;
        if (req.nsec > 0) ms += @as(u64, @intCast(@divTrunc(req.nsec, std.time.ns_per_ms)));
        if (ms == 0 and (req.sec > 0 or req.nsec > 0)) ms = 1;
        if (ms > 0) api.Sleep(@intCast(@min(ms, std.math.maxInt(u32))));
        return 0;
    }

    pub fn clock_gettime(clk: ClockId, ts: *TimeSpec) i32 {
        switch (clk) {
            .MONOTONIC => {
                var freq: i64 = 0;
                var counter: i64 = 0;
                _ = api.QueryPerformanceFrequency(&freq);
                _ = api.QueryPerformanceCounter(&counter);
                if (freq <= 0) freq = 1;
                const ns = @divTrunc(counter * std.time.ns_per_s, freq);
                ts.sec = @divTrunc(ns, std.time.ns_per_s);
                ts.nsec = @mod(ns, std.time.ns_per_s);
            },
            .REALTIME => {
                var ft: i64 = 0;
                api.GetSystemTimePreciseFileTime(&ft);
                const unix_100ns = ft - 116444736000000000;
                const ns = unix_100ns * 100;
                ts.sec = @divTrunc(ns, std.time.ns_per_s);
                ts.nsec = @mod(ns, std.time.ns_per_s);
            },
        }
        return 0;
    }
};
