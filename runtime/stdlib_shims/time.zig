//! `nox.time` Zig kabuğu — stdlib fazı §K (bkz. nox-teknik-spesifikasyon.md).
//!
//! İkisi de ARC/`rt` GEREKTİRMEZ (salt `int` alıp/döndürür) — `with_rt`
//! İŞARETİ TAŞIMAZLAR, `nox.math`nin `sqrt`/`pow` gibi ARC-dışı extern
//! def'leriyle AYNI kategori.
//!
//! **Bilinçli v1 sınırlaması (bkz. `stdlib/nox/time.nox`nin belge notu):**
//! `sleep_ms` bir fiber İÇİNDEYKEN bile GERÇEKTEN BLOKE OLUR — D.0'ın kqueue
//! reaktörü YALNIZCA soket G/Ç'si İÇİN, bir ZAMANLAYICI olayı İÇİN DEĞİL.
//!
//! **İSİM ÇAKIŞMASI notu (Alt-Faz J'nin dersi):** `now_ms`/`sleep_ms` adlı
//! KISA Nox sarmalayıcıları `nox_time_now_ms`/`nox_time_sleep_ms`e mangle
//! OLDUĞUNDAN, extern def'lerin KENDİSİ `_raw` SONEKİYLE (`nox_time_now_ms_raw`/
//! `nox_time_sleep_ms_raw`) tanımlanır — `nox.os`nin AYNI çakışmayı çözdüğü
//! deseni.

const std = @import("std");

export fn nox_time_now_ms_raw() callconv(.c) i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * std.time.ms_per_s + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
}

export fn nox_time_sleep_ms_raw(ms: i64) callconv(.c) void {
    if (ms <= 0) return;
    const ts: std.c.timespec = .{
        .sec = @divTrunc(ms, std.time.ms_per_s),
        .nsec = @mod(ms, std.time.ms_per_s) * std.time.ns_per_ms,
    };
    _ = std.c.nanosleep(&ts, null);
}

test "nox_time_now_ms_raw pozitif ve makul bir epoch değeri döner" {
    const now = nox_time_now_ms_raw();
    try std.testing.expect(now > 0);
}

test "nox_time_sleep_ms_raw en az istenen süre kadar bekler" {
    const before = nox_time_now_ms_raw();
    nox_time_sleep_ms_raw(20);
    const after = nox_time_now_ms_raw();
    try std.testing.expect(after - before >= 15);
}
