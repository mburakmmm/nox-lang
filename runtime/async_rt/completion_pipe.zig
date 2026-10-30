//! Faz F.0.6 (bkz. plan dosyası "gizli http_client.zig bağımlılığının
//! KESİLMESİ"): `thread_channel.zig`/`thread_bridge.zig`/`pool_bridge.
//! zig`nin (VE `stdlib_shims/http_client.zig`nin KENDİSİNİN) bir arka-
//! plan OS iş parçacığının "işim BİTTİ" TEK-SEFERLİK tamamlanma sinyalini
//! bekleme deseni. Bu dosya `self_pipe.zig`den (F.0.5, Scheduler'ın
//! çapraz-worker "poll()de bloke olanı uyandır" deseni, POSIX-ONLY)
//! KASITLI olarak AYRI — BURADAKİ `makeSelfPipe` GERÇEK bir Windows
//! implementasyonu (BAĞLANMIŞ UDP-loopback soket ÇİFTİ, `io_reactor.zig`
//! nin `WindowsReactor.makeLoopbackPair`ıyla AYNI teknik) TAŞIR, `self_
//! pipe.zig` İSE Windows'ta `error.Unsupported` döner — İKİ dosya FARKLI
//! YETENEK/AMAÇ taşıdığından BİRLEŞTİRİLMEDİ.
//!
//! ÖNCEDEN `runtime/stdlib_shims/http_client.zig`de tanımlıydı — `async_
//! rt/thread_channel.zig`/`thread_bridge.zig`/`pool_bridge.zig` (ÜÇÜ de
//! ÇEKİRDEK `async_rt` dosyası) SADECE BU dört fonksiyonu ödünç almak
//! İçİn `stdlib_shims/http_client.zig`yi İTHAL EDİYORDU — `runtime/
//! async_rt/`nin AYNI "runtime/alloc/'den [dolayısıyla runtime/stdlib_
//! shims'den] bağımsız kalma" sınırını (bkz. `scheduler.zig`nin modül
//! üstü notu, "İlke #6") BOZAN, gizli bir çekirdek-katman bağımlılığıydı.
//! BURAYA taşınarak (davranış SIFIR değişmeden) o bağımlılık KESİLDİ —
//! `http_client.zig` ARTIK BU dosyayı İTHAL EDİP KENDİ fonksiyonlarını
//! re-export EDİYOR (bkz. onun belge notu).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const io_mod = @import("io.zig");

/// Tamamlanma borusunun uç tanıtıcı tipi: yerelde `Fd`; wasm32-freestanding'de (`Fd == void`) sahte fd olarak `i32`.
pub const Fd = if (builtin.cpu.arch.isWasm() and builtin.os.tag == .freestanding) i32 else posix.fd_t;

/// Faz LL.5 (bkz. nox-teknik-spesifikasyon.md §3.71): `workerThreadFn`nin
/// "tamamlanma sinyali" self-pipe'ı `std.c.pipe`ye dayanır — Windows'ta
/// `pipe()` YOKTUR. Yerine, BAĞLANMIŞ (connected) bir UDP-loopback ÇİFTİ
/// kullanılır (`io_reactor.zig`nin `WindowsReactor.makeLoopbackPair`iYLE
/// AYNI teknik) — bir tarafa `send` edilen TEK bayt, diğer taraftan
/// `recv` edilerek OKUNUR, `nonBlockingRead`in (D.0'ın reaktörü) BEKLEDİĞİ
/// "hazır-olma bildirimi alınabilen bir fd" sözleşmesini AYNEN karşılar.
/// wasm32 (ADR-015): `pipe`/`read`/`write` yok. Tamamlanma sinyali, iki "uç"un (aynı sahte fd) paylaştığı bir futex bayrağıdır: `signalSelfPipe` bayrağı kurup uyandırır,
/// `readSelfPipe` bayrak kurulana dek iş parçacığını BLOKE eder (gerçek `read()` gibi), son `closeFd` bayrağı serbest bırakır. fd = bayrağın adresi.
const WasmFlag = struct {
    signaled: std.atomic.Value(u32) = .init(0),
    refs: std.atomic.Value(u32) = .init(2),
};

const is_wasm = builtin.cpu.arch.isWasm();

fn wasmFlag(fd: Fd) *WasmFlag {
    return @ptrFromInt(@as(usize, @intCast(@as(u32, @bitCast(fd)))));
}

inline fn wasmWait(ptr: *const u32, expected: u32) void {
    const exp: i32 = @bitCast(expected);
    _ = asm volatile ("local.get %[ptr]\nlocal.get %[exp]\ni64.const -1\nmemory.atomic.wait32 0\nlocal.set %[ret]"
        : [ret] "=r" (-> u32),
        : [ptr] "r" (ptr),
          [exp] "r" (exp),
        : .{ .memory = true });
}

inline fn wasmWake(ptr: *const u32) void {
    _ = asm volatile ("local.get %[ptr]\ni32.const 1\nmemory.atomic.notify 0\nlocal.set %[ret]"
        : [ret] "=r" (-> u32),
        : [ptr] "r" (ptr),
        : .{ .memory = true });
}

pub fn makeSelfPipe() ?[2]Fd {
    if (comptime is_wasm) {
        const flag = std.heap.page_allocator.create(WasmFlag) catch return null;
        flag.* = .{};
        const fd: Fd = @bitCast(@as(u32, @intCast(@intFromPtr(flag))));
        return .{ fd, fd };
    }
    if (builtin.os.tag == .windows) {
        io_mod.ensureWinsock();
        const ws = io_mod.WinSock;
        const a = ws.socket(ws.AF_INET, 2, 17); // SOCK_DGRAM=2, IPPROTO_UDP=17
        if (a == ws.INVALID_SOCKET) return null;
        const b = ws.socket(ws.AF_INET, 2, 17);
        if (b == ws.INVALID_SOCKET) {
            _ = ws.closesocket(a);
            return null;
        }
        var addr_a: std.os.windows.ws2_32.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        var addr_b: std.os.windows.ws2_32.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (ws.bind(a, &addr_a, @sizeOf(std.os.windows.ws2_32.sockaddr.in)) != 0 or
            ws.bind(b, &addr_b, @sizeOf(std.os.windows.ws2_32.sockaddr.in)) != 0)
        {
            _ = ws.closesocket(a);
            _ = ws.closesocket(b);
            return null;
        }
        var len_a: i32 = @sizeOf(std.os.windows.ws2_32.sockaddr.in);
        var len_b: i32 = @sizeOf(std.os.windows.ws2_32.sockaddr.in);
        _ = ws.getsockname(a, &addr_a, &len_a);
        _ = ws.getsockname(b, &addr_b, &len_b);
        if (ws.connect(a, &addr_b, @sizeOf(std.os.windows.ws2_32.sockaddr.in)) != 0 or
            ws.connect(b, &addr_a, @sizeOf(std.os.windows.ws2_32.sockaddr.in)) != 0)
        {
            _ = ws.closesocket(a);
            _ = ws.closesocket(b);
            return null;
        }
        // `read_fd` = a (okunur), `write_fd` = b (yazılır) — `pipe()`in
        // `fds[0]`=oku/`fds[1]`=yaz sözleşmesiyle AYNI.
        return .{ @ptrFromInt(a), @ptrFromInt(b) };
    }
    var fds: [2]Fd = undefined;
    if (std.c.pipe(&fds) != 0) return null;
    return fds;
}

pub fn closeFd(fd: Fd) void {
    if (comptime is_wasm) {
        const flag = wasmFlag(fd);
        if (flag.refs.fetchSub(1, .acq_rel) == 1) std.heap.page_allocator.destroy(flag);
        return;
    }
    if (builtin.os.tag == .windows) {
        _ = io_mod.WinSock.closesocket(@intFromPtr(fd));
    } else {
        _ = std.c.close(fd);
    }
}

pub fn signalSelfPipe(fd: Fd) void {
    if (comptime is_wasm) {
        const flag = wasmFlag(fd);
        flag.signaled.store(1, .seq_cst);
        wasmWake(&flag.signaled.raw);
        return;
    }
    if (builtin.os.tag == .windows) {
        var b: [1]u8 = .{1};
        _ = io_mod.WinSock.send(@intFromPtr(fd), &b, 1, 0);
    } else {
        var signal_byte = [_]u8{1};
        _ = std.c.write(fd, &signal_byte, 1);
    }
}

pub fn readSelfPipe(fd: Fd, buf: []u8) void {
    if (comptime is_wasm) {
        const flag = wasmFlag(fd);
        while (flag.signaled.load(.seq_cst) == 0) wasmWait(&flag.signaled.raw, 0);
        if (buf.len > 0) buf[0] = 1;
        return;
    }
    if (builtin.os.tag == .windows) {
        _ = io_mod.WinSock.recv(@intFromPtr(fd), buf.ptr, @intCast(buf.len), 0);
    } else {
        _ = std.c.read(fd, buf.ptr, buf.len);
    }
}

test "Faz F.0.6: makeSelfPipe/signalSelfPipe/readSelfPipe/closeFd tam bir tur GERÇEKTEN çalışır" {
    const fds = makeSelfPipe() orelse return error.SkipZigTest;
    defer closeFd(fds[0]);
    defer closeFd(fds[1]);

    signalSelfPipe(fds[1]);
    var buf: [1]u8 = .{0};
    readSelfPipe(fds[0], &buf);
    try std.testing.expectEqual(@as(u8, 1), buf[0]);
}
