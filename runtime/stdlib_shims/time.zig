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
const builtin = @import("builtin");

/// Faz LL.4 (bkz. nox-teknik-spesifikasyon.md §3.71): bu Zig sürümünde
/// `std.c.clockid_t` Windows İçin `void`dir (`.windows` dalı HİÇ
/// case'lenmemiş, `else => void`) — `clock_gettime`/`nanosleep` BU YÜZDEN
/// (imzaları BU tipe bağlı olduğundan) Windows'ta KULLANILAMAZ. Yerine:
/// duvar-saati İçin `GetSystemTimePreciseAsFileTime` (`fs.zig`nin AYNI
/// FILETIME→Unix çevirisini kullanır), monotonik saat İçin
/// `QueryPerformanceCounter`/`Frequency` (`io_reactor.zig`nin
/// `WindowsReactor.monotonicMs`iYLE AYNI desen), uyku İçin `Sleep` (Win32
/// kernel32, milisaniye çözünürlüklü — `nanosleep`in nanosaniye
/// çözünürlüğünden daha KABA, ama `nox.time.sleep_ms`in KENDİ arayüzü
/// zaten milisaniye TABANLI olduğundan KAYIP YOK).
const WinTime = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn GetSystemTimePreciseAsFileTime(t: *std.os.windows.FILETIME) callconv(.c) void;
    extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.c) i32;
    extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.c) i32;
    extern "kernel32" fn Sleep(ms: u32) callconv(.c) void;

    fn nowMs() i64 {
        var ft: std.os.windows.FILETIME = undefined;
        GetSystemTimePreciseAsFileTime(&ft);
        const ticks: u64 = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
        const unix_100ns: i64 = @as(i64, @intCast(ticks)) - 116444736000000000;
        return @divFloor(unix_100ns, 10_000);
    }

    var freq: i64 = 0;
    fn monotonicMs() i64 {
        if (freq == 0) _ = QueryPerformanceFrequency(&freq);
        var counter: i64 = 0;
        _ = QueryPerformanceCounter(&counter);
        return @divTrunc(counter * 1000, freq);
    }
} else struct {};

export fn nox_time_now_ms_raw() callconv(.c) i64 {
    if (builtin.os.tag == .windows) return WinTime.nowMs();
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * std.time.ms_per_s + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
}

/// Faz III.7 (bkz. nox-teknik-spesifikasyon.md §3.69) — `nox_time_now_ms_
/// raw`in AYNI deseni, YALNIZCA `.REALTIME` YERİNE `.MONOTONIC` (sistem
/// saati GERİYE/İLERİYE ayarlansa BİLE ASLA geri sıçramaz — `Instant.
/// elapsed_ms`in DOĞRULUĞU İÇİN ZORUNLU, `now_ms`nin duvar-saati AKSİNE).
export fn nox_time_monotonic_ms_raw() callconv(.c) i64 {
    if (builtin.os.tag == .windows) return WinTime.monotonicMs();
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ms_per_s + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
}

export fn nox_time_sleep_ms_raw(ms: i64) callconv(.c) void {
    if (ms <= 0) return;
    if (builtin.os.tag == .windows) {
        WinTime.Sleep(@intCast(ms));
        return;
    }
    const ts: std.c.timespec = .{
        .sec = @divTrunc(ms, std.time.ms_per_s),
        .nsec = @mod(ms, std.time.ms_per_s) * std.time.ns_per_ms,
    };
    _ = std.c.nanosleep(&ts, null);
}

/// Stdlib fazı V.4 — `nox.time.DateTime`: bir epoch-ms değerini takvim
/// bileşenlerine (yıl/ay/gün/saat/dakika/saniye) AYIRIR. Zig'in KENDİ
/// `std.time.epoch`u (`nox.crypto`nun `std.crypto`yu KULLANMA kararıyla
/// AYNI ilke — sıfırdan takvim ARİTMETİĞİ YAZILMAZ) kullanılır. Her
/// bileşen AYRI bir `extern def`e (Nox'un `extern def`i TEK bir skaler
/// DÖNDÜREBİLDİĞİNDEN, struct/tuple YOK) karşılık gelir — HER çağrı AYNI
/// ayrıştırmayı yeniden YAPAR (v1 için BİLİNÇLİ basitleştirme, altı ayrı
/// alan İÇİN altı ayrı `extern def` çağrısı — bir "tek çağrıda TÜM alanları
/// hesapla" optimizasyonu YOK).
///
/// **Bilinçli v1 sınırlaması:** yalnızca AYRIŞTIRMA (epoch-ms -> bileşenler)
/// desteklenir — TERS yön (bileşenler -> epoch-ms, ör. `to_epoch_ms(...)`)
/// `std.time.epoch`un SAĞLAMADIĞI bir "civil-den-epoch-güne" dönüşüm
/// algoritması (ör. Howard Hinnant'ın `days_from_civil`i) GEREKTİRİRDİ —
/// v1 kapsamı DIŞINDA bırakıldı (birincil kullanım durumu, `nox.time.now()`
/// İLE ŞU ANKİ tarihi/saati GÖRÜNTÜLEMEK, yalnızca AYRIŞTIRMA gerektirir).
/// Yalnızca 1970 VE SONRASI (negatif OLMAYAN epoch-ms) desteklenir —
/// `std.time.epoch.EpochSeconds`in KENDİSİ `u64` alır.
fn breakdownSeconds(ms: i64) std.time.epoch.EpochSeconds {
    const secs: u64 = @intCast(@divFloor(ms, std.time.ms_per_s));
    return .{ .secs = secs };
}

export fn nox_time_year_raw(ms: i64) callconv(.c) i64 {
    const yd = breakdownSeconds(ms).getEpochDay().calculateYearDay();
    return @intCast(yd.year);
}

export fn nox_time_month_raw(ms: i64) callconv(.c) i64 {
    const yd = breakdownSeconds(ms).getEpochDay().calculateYearDay();
    return @intCast(yd.calculateMonthDay().month.numeric());
}

export fn nox_time_day_raw(ms: i64) callconv(.c) i64 {
    const yd = breakdownSeconds(ms).getEpochDay().calculateYearDay();
    // `day_index` 0-TABANLIDIR (0-30) — kullanıcı yüzeyinde 1-TABANLI
    // (Python'un `datetime.day`siyle TUTARLI) bir gün numarası VERMEK
    // İÇİN +1.
    return @as(i64, yd.calculateMonthDay().day_index) + 1;
}

export fn nox_time_hour_raw(ms: i64) callconv(.c) i64 {
    return breakdownSeconds(ms).getDaySeconds().getHoursIntoDay();
}

export fn nox_time_minute_raw(ms: i64) callconv(.c) i64 {
    return breakdownSeconds(ms).getDaySeconds().getMinutesIntoHour();
}

export fn nox_time_second_raw(ms: i64) callconv(.c) i64 {
    return breakdownSeconds(ms).getDaySeconds().getSecondsIntoMinute();
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

test "Faz III.7: nox_time_monotonic_ms_raw pozitif, monoton artan bir değer döner" {
    const before = nox_time_monotonic_ms_raw();
    try std.testing.expect(before > 0);
    nox_time_sleep_ms_raw(20);
    const after = nox_time_monotonic_ms_raw();
    try std.testing.expect(after - before >= 15);
}
