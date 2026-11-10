//! `nox.signal` — işlem sinyallerine (SIGINT/SIGTERM/SIGHUP/SIGUSR1/SIGUSR2) abonelik (Ember NL-008).
//!
//! Sinyal işleyicisi YALNIZCA async-signal-safe tek bir iş yapar: sinyale ait atomik bayrağı kurar. Nox kodu bayrağı kendi iş parçacığında/fiber'ında `take`/`pending`/`wait`
//! ile okur; işleyicide hiçbir Nox kodu çalışmaz (durum değişikliği zamanlayıcıya olay olarak taşınır, işleyicide DEĞİL). `nox.http`in kendi SIGTERM/SIGINT işleyicisi varsa
//! (`serve*` başlarken kurulur) son kuran kazanır; ikisini birlikte kullanmayın.
//! Windows, wasm ve freestanding'de `install` 0 döner (sinyal yok); `take`/`pending` hep 0 verir.

const std = @import("std");
const builtin = @import("builtin");

const supported = switch (builtin.os.tag) {
    .windows, .freestanding, .wasi, .other => false,
    else => !builtin.cpu.arch.isWasm(),
};

const MAX_SIG = 32;
var g_flags: [MAX_SIG]std.atomic.Value(bool) = [_]std.atomic.Value(bool){.init(false)} ** MAX_SIG;

fn onSignal(sig: std.posix.SIG) callconv(.c) void {
    const n: usize = @intCast(@intFromEnum(sig));
    if (n < MAX_SIG) g_flags[n].store(true, .release);
}

fn validSig(sig: i64) ?usize {
    if (sig <= 0 or sig >= MAX_SIG) return null;
    return @intCast(sig);
}

/// `which`: 0 = SIGINT, 1 = SIGTERM, 2 = SIGHUP, 3 = SIGUSR1, 4 = SIGUSR2 → platformun sinyal numarası; desteklenmiyorsa 0.
pub export fn nox_signal_number_raw(which: i64) i64 {
    if (comptime !supported) return 0;
    return switch (which) {
        0 => @intFromEnum(std.posix.SIG.INT),
        1 => @intFromEnum(std.posix.SIG.TERM),
        2 => @intFromEnum(std.posix.SIG.HUP),
        3 => @intFromEnum(std.posix.SIG.USR1),
        4 => @intFromEnum(std.posix.SIG.USR2),
        else => 0,
    };
}

/// Sinyali bayrak-kuran işleyiciye bağlar. Başarılıysa 1.
pub export fn nox_signal_install_raw(sig: i64) i32 {
    if (comptime !supported) return 0;
    const n = validSig(sig) orelse return 0;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(@enumFromInt(n), &act, null);
    return 1;
}

/// Bayrak kurulu mu? (Tüketmez.)
pub export fn nox_signal_pending_raw(sig: i64) i32 {
    const n = validSig(sig) orelse return 0;
    return if (g_flags[n].load(.acquire)) 1 else 0;
}

/// Bayrağı oku ve temizle: sinyal gelmişse 1 (bir sonraki çağrı yeni bir sinyale kadar 0).
pub export fn nox_signal_take_raw(sig: i64) i32 {
    const n = validSig(sig) orelse return 0;
    return if (g_flags[n].swap(false, .acq_rel)) 1 else 0;
}

/// Bu sürece `sig` sinyalini gönderir (testler ve kendi kendini durdurma için). Başarılıysa 1.
pub export fn nox_signal_raise_raw(sig: i64) i32 {
    if (comptime !supported) return 0;
    const n = validSig(sig) orelse return 0;
    return if (std.c.raise(@enumFromInt(n)) == 0) 1 else 0;
}

test "nox_signal: install + raise bayrağı kurar, take temizler" {
    if (comptime !supported) return error.SkipZigTest;
    const usr1 = nox_signal_number_raw(3);
    try std.testing.expect(usr1 > 0);
    try std.testing.expectEqual(@as(i32, 0), nox_signal_take_raw(usr1));
    try std.testing.expectEqual(@as(i32, 1), nox_signal_install_raw(usr1));
    try std.testing.expectEqual(@as(i32, 1), nox_signal_raise_raw(usr1));
    try std.testing.expectEqual(@as(i32, 1), nox_signal_pending_raw(usr1));
    try std.testing.expectEqual(@as(i32, 1), nox_signal_take_raw(usr1));
    try std.testing.expectEqual(@as(i32, 0), nox_signal_pending_raw(usr1));
    try std.testing.expectEqual(@as(i32, 0), nox_signal_install_raw(0));
}
