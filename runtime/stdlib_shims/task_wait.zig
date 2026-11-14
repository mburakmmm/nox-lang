//! `Task[T].wait(ms)` / `Task[T].wait_any(other, ms)` — zaman aşımlı, kooperatif görev beklemesi (Ember NL-003).
//!
//! Görevi İPTAL ETMEZ ve sonucunu TÜKETMEZ (`await` yine alır). Bekleme `nox_time_sleep_ms_raw` ile yapılır: fiber içinde yalnızca çağıran
//! fiber askıya alınır (bkz. `time.zig`, `fiber_net.sleepCooperative`), wasm'da host uykusu kullanılır. Yoklama aralığı 1 ms'den 10 ms'ye katlanır.

const std = @import("std");
const bridge = @import("../async_rt/bridge.zig");

extern fn nox_time_monotonic_ms_raw() callconv(.c) i64;
extern fn nox_time_sleep_ms_raw(ms: i64) callconv(.c) void;

/// `a` biterse 0, `b` (varsa) biterse 1, süre dolarsa -1. İkisi birden bitmişse 0. `ms <= 0` yalnızca sorgular.
fn poll(a: ?*anyopaque, b: ?*anyopaque, ms: i64) i32 {
    const start = nox_time_monotonic_ms_raw();
    var step: i64 = 1;
    while (true) {
        if (bridge.nox_task_is_done(a) != 0) return 0;
        if (b != null and bridge.nox_task_is_done(b) != 0) return 1;
        const remaining = ms - (nox_time_monotonic_ms_raw() - start);
        if (remaining <= 0) return -1;
        nox_time_sleep_ms_raw(@min(step, remaining));
        step = @min(step * 2, 10);
    }
}

pub export fn nox_task_wait(rt: ?*anyopaque, task: ?*anyopaque, ms: i64) i32 {
    _ = rt;
    return if (poll(task, null, ms) == 0) 1 else 0;
}

pub export fn nox_task_wait_any(rt: ?*anyopaque, a: ?*anyopaque, b: ?*anyopaque, ms: i64) i32 {
    _ = rt;
    return poll(a, b, ms);
}

/// `Channel[T].wait_any(b[, c[, d]], ms)` (v2.1.142): kanallardan HERHANGİ BİRİNDE bir `recv` bloklamadan dönebileceği an ilk hazır kanalın indeksini (0 = alıcı, 1.. = argümanlar; birden çok hazırsa
/// EN KÜÇÜK indeks), süre dolarsa -1 döner. Değeri TÜKETMEZ (`await <kanal>.recv()` sonra alır); başka bir alıcı araya girebilir (`wait` ile aynı). Go'nun `select`inden farkı: yoklama tabanlıdır
/// (1 ms'den 4 ms'ye katlanan aralıkla kooperatif uyku; bekleyen fiber hiçbir işçiyi tutmaz) ve yalnız ALMA durumlarını bekler. `ms <= 0` yalnızca sorgular.
pub export fn nox_channel_wait_any(rt: ?*anyopaque, a: ?*anyopaque, b: ?*anyopaque, c: ?*anyopaque, d: ?*anyopaque, ms: i64) i32 {
    _ = rt;
    const chans = [4]?*anyopaque{ a, b, c, d };
    const start = nox_time_monotonic_ms_raw();
    var step: i64 = 1;
    while (true) {
        for (chans, 0..) |ch, i| {
            if (ch != null and bridge.nox_channel_ready(ch) != 0) return @intCast(i);
        }
        const remaining = ms - (nox_time_monotonic_ms_raw() - start);
        if (remaining <= 0) return -1;
        nox_time_sleep_ms_raw(@min(step, remaining));
        step = @min(step * 2, 4);
    }
}

/// `Channel[T].wait(ms)` (v2.1.34): `ms` içinde bir `recv`in bloklamadan dönebileceği an `1`, süre dolarsa `0`. Değeri TÜKETMEZ (`await ch.recv()` sonra alır); birden çok alıcı
/// aynı kanalda yarışırsa `wait` doğru döndükten sonra diğeri değeri almış olabilir. Yoklama aralığı 1 ms'den 10 ms'ye katlanır; `ms <= 0` yalnızca sorgular.
pub export fn nox_channel_wait(rt: ?*anyopaque, ch: ?*anyopaque, ms: i64) i32 {
    _ = rt;
    const start = nox_time_monotonic_ms_raw();
    var step: i64 = 1;
    while (true) {
        if (bridge.nox_channel_ready(ch) != 0) return 1;
        const remaining = ms - (nox_time_monotonic_ms_raw() - start);
        if (remaining <= 0) return 0;
        nox_time_sleep_ms_raw(@min(step, remaining));
        step = @min(step * 2, 10);
    }
}
