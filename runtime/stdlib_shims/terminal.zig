//! `nox.terminal` — terminal G/Ç denetimi (Rune): TTY algılama, boyut, ham mod, echo, bloklamayan ham girdi, ham çıktı.
//!
//! POSIX'te (`termios`, `ioctl(TIOCGWINSZ)`, `poll`). Windows/wasm/freestanding'de TTY denetimi yoktur: `is_tty` 0, `enable_raw_mode` -1, boyut
//! 0 döner (Nox tarafı varsayılanlara düşer). `poll_input` bir fiber içindeyken fiber'ı askıya alır (iş parçacığını bloke etmez).
//! Terminal durumu süreç-geneli bir OS kaynağıdır; ham mod iç içe çağrılara karşı sayaçlıdır (`enable`/`disable` eşleşir) ve
//! `restore_state` sayaç ne olursa olsun özgün ayarları geri yükler (panik/`finally` kurtarması).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const str_mod = @import("../str.zig");
const stdout_flush = @import("../stdout_flush.zig");

const supported = switch (builtin.os.tag) {
    .windows, .freestanding, .wasi, .other => false,
    else => !builtin.cpu.arch.isWasm(),
};

const fiber_net = if (!supported) struct {
    fn inFiber() bool {
        return false;
    }
    fn waitFd(_: c_int, _: bool, _: ?u32) enum { ready, timed_out } {
        return .timed_out;
    }
} else @import("fiber_net.zig");

var g_orig: ?posix.termios = null;
var g_raw_depth: u32 = 0;

fn fdOk(fd: i64) ?posix.fd_t {
    if (fd < 0 or fd > 2) return null;
    return @intCast(fd);
}

/// `fd` (0 stdin, 1 stdout, 2 stderr) bir terminale mi bağlı?
pub export fn nox_terminal_is_tty_raw(fd: i64) i32 {
    if (comptime !supported) return 0;
    const f = fdOk(fd) orelse return 0;
    return if (std.c.isatty(f) != 0) 1 else 0;
}

/// Terminal boyutu: `which` 0 = sütun, 1 = satır. stdout (sonra stderr, stdin) bir terminal değilse ya da desteklenmiyorsa 0.
pub export fn nox_terminal_size_raw(which: i64) i64 {
    if (comptime !supported) return 0;
    for ([_]posix.fd_t{ 1, 2, 0 }) |fd| {
        var ws: posix.winsize = undefined;
        if (std.c.ioctl(fd, std.c.T.IOCGWINSZ, @intFromPtr(&ws)) == 0 and ws.col > 0 and ws.row > 0) {
            return if (which == 0) ws.col else ws.row;
        }
    }
    return 0;
}

/// stdin'i ham moda alır (kanonik mod, echo, sinyal tuşları, çıktı işleme kapalı; okuma bloklamaz). İç içe çağrılar sayılır. Başarılıysa 0, değilse -1.
pub export fn nox_terminal_enable_raw_raw() i32 {
    if (comptime !supported) return -1;
    if (g_raw_depth > 0) {
        g_raw_depth += 1;
        return 0;
    }
    const orig = posix.tcgetattr(0) catch return -1;
    var raw = orig;
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.cflag.CSIZE = .CS8;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    posix.tcsetattr(0, .FLUSH, raw) catch return -1;
    g_orig = orig;
    g_raw_depth = 1;
    return 0;
}

/// `enable_raw`ın eşi: son eşleşen çağrıda özgün ayarlar geri yüklenir.
pub export fn nox_terminal_disable_raw_raw() i32 {
    if (comptime !supported) return -1;
    if (g_raw_depth == 0) return 0;
    g_raw_depth -= 1;
    if (g_raw_depth > 0) return 0;
    const orig = g_orig orelse return 0;
    posix.tcsetattr(0, .FLUSH, orig) catch return -1;
    g_orig = null;
    return 0;
}

pub export fn nox_terminal_is_raw_raw() i32 {
    return if (g_raw_depth > 0) 1 else 0;
}

/// Sayaçtan bağımsız: özgün terminal ayarlarını (varsa) geri yükler ve ham mod sayacını sıfırlar.
pub export fn nox_terminal_restore_raw() i32 {
    if (comptime !supported) return -1;
    g_raw_depth = 0;
    const orig = g_orig orelse return 0;
    posix.tcsetattr(0, .FLUSH, orig) catch return -1;
    g_orig = null;
    return 0;
}

/// stdin echo'sunu açar/kapatır (parola girişi). Başarılıysa 0, değilse -1. Ham moddayken ECHO zaten kapalıdır; `restore` ile geri gelir.
pub export fn nox_terminal_set_echo_raw(enabled: i32) i32 {
    if (comptime !supported) return -1;
    var t = posix.tcgetattr(0) catch return -1;
    t.lflag.ECHO = enabled != 0;
    posix.tcsetattr(0, .FLUSH, t) catch return -1;
    return 0;
}

/// stdin'de okunabilir veri var mı? En çok `timeout_ms` bekler (`< 0`: süresiz). Fiber içinde yalnızca çağıran fiber askıya alınır.
pub export fn nox_terminal_poll_raw(timeout_ms: i64) i32 {
    if (comptime !supported) return 0;
    if (fiber_net.inFiber()) {
        if (timeout_ms == 0) return pollNow(0);
        if (pollNow(0) == 1) return 1;
        const t: ?u32 = if (timeout_ms < 0) null else @intCast(@min(timeout_ms, std.math.maxInt(u32)));
        return switch (fiber_net.waitFd(0, false, t)) {
            .ready => 1,
            .timed_out => 0,
        };
    }
    return pollNow(@intCast(@min(timeout_ms, std.math.maxInt(i32))));
}

fn pollNow(timeout_ms: i32) i32 {
    var pfd = [1]posix.pollfd{.{ .fd = 0, .events = posix.POLL.IN, .revents = 0 }};
    const n = posix.poll(&pfd, timeout_ms) catch return -1;
    return if (n > 0 and (pfd[0].revents & (posix.POLL.IN | posix.POLL.HUP)) != 0) 1 else 0;
}

/// stdin'den en çok `max_bytes` bayt okur (hazır olanı; beklemez). Ham baytlar `str` içinde aynen korunur (çok baytlı UTF-8 parça parça gelebilir).
pub export fn nox_terminal_stdin_read_raw(rt: ?*anyopaque, max_bytes: i64) ?*anyopaque {
    var buf: [4096]u8 = undefined;
    const cap: usize = @intCast(@max(1, @min(max_bytes, buf.len)));
    var n: usize = 0;
    if (comptime supported) {
        const r = std.c.read(0, &buf, cap);
        if (r > 0) n = @intCast(r);
    }
    return @ptrCast(str_mod.nox_str_from_bytes(rt, buf[0..n]));
}

/// `s`yi satır sonu eklemeden stdout'a yazar (kısmi yazmalara karşı döngülü). Başarılıysa 0.
pub export fn nox_terminal_stdout_write_raw(s: ?[*:0]const u8) i32 {
    const p = s orelse return 0;
    var bytes: []const u8 = str_mod.nox_str_slice(p);
    if (comptime !supported) return -1;
    // `print` tamponlu stdout'a yazar; sırayı korumak için önce o boşaltılır.
    stdout_flush.flushStdout();
    while (bytes.len > 0) {
        const w = std.c.write(1, bytes.ptr, bytes.len);
        if (w < 0) {
            if (posix.errno(w) == .INTR) continue;
            return -1;
        }
        bytes = bytes[@intCast(w)..];
    }
    return 0;
}

/// `print` tamponunu boşaltır (ham yazma zaten tamponsuzdur).
pub export fn nox_terminal_flush_raw() void {
    stdout_flush.flushStdout();
}

test "terminal: desteklenmeyen/terminal olmayan ortamda güvenli varsayılanlar" {
    // Test koşucusu çoğunlukla bir terminale bağlı değildir; yalnızca çökmeme ve tutarlılık denetlenir.
    _ = nox_terminal_is_tty_raw(0);
    _ = nox_terminal_size_raw(0);
    try std.testing.expectEqual(@as(i32, 0), nox_terminal_is_raw_raw());
    try std.testing.expectEqual(@as(i32, 0), nox_terminal_is_tty_raw(7)); // geçersiz fd
    try std.testing.expectEqual(@as(i32, 0), nox_terminal_disable_raw_raw()); // eşleşmemiş disable zararsız
}
