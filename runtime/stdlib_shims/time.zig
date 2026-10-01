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

/// v4 Faz B devamı (bkz. nox-teknik-spesifikasyon.md §3.2xx): `nox.time`
/// ARTIK `lib_freestanding.zig`e de KABLOLANIYOR (SAF takvim aritmetiği
/// — `to_epoch_ms_raw`/`year_raw`/`month_raw`/vb. — freestanding'de de
/// KULLANILABİLİR OLSUN diye), AMA `now_ms_raw`/`monotonic_ms_raw`/
/// `sleep_ms_raw`nin KENDİSİ `std.c.clock_gettime`/`nanosleep`e bağlıdır
/// (libc, freestanding'de YOK). `str.zig`/`arc.zig`nin AYNI `is_
/// freestanding` deseni — bu üç fonksiyonun gövdesi `std.c.*`ye HİÇ
/// ERİŞMEDEN SIFIR döner (`diag_sink.zig`nin `defaultStderrSink`iyle AYNI
/// gerekçe: Zig yalnızca ALINAN `if` dalını analiz eder, bu YÜZDEN
/// `std.c.clock_gettime`nin freestanding'de DERLENEMEZ OLMASI sorun
/// DEĞİLDİR). BU ASLA GERÇEKTEN ÇAĞRILMAZ — Nox tarafı `nox.time.now_ms`/
/// `sleep_ms`/`instant_now`yu `@capability.requires("clock")` İLE
/// sembol-seviyesinde işaretler (`stdlib/nox/time.nox`nin belge notu),
/// freestanding profili BUNU asla GRANT ETMEZ — SADECE Nox'un "HER
/// üst-düzey fonksiyon KOŞULSUZ derlenir" kuralı YÜZÜNDEN, linker'ın BU
/// sembolleri ÇÖZEBİLMESİ GEREKİR (çağrılmasalar bile).
const is_freestanding = builtin.os.tag == .freestanding or builtin.os.tag == .other;

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
    if (comptime is_freestanding) return 0;
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
    if (comptime is_freestanding) return 0;
    if (builtin.os.tag == .windows) return WinTime.monotonicMs();
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ms_per_s + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
}

export fn nox_time_sleep_ms_raw(ms: i64) callconv(.c) void {
    if (comptime is_freestanding) return;
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
/// **v3 sertleştirme yol haritası, madde 10 (bkz. nox-teknik-
/// spesifikasyon.md ilgili bölüm, stdlib/API denetimi):** "yalnızca
/// AYRIŞTIRMA, ters yön YOK" v1 sınırlaması BURADA kapatıldı —
/// `days_from_civil`, Howard Hinnant'ın KAMU malı/savaş-test edilmiş
/// "civil-den-epoch-güne" algoritmasıdır (bkz. http://howardhinnant.
/// github.io/date_algorithms.html, `chrono`nun KENDİ referans uygulaması)
/// — `nox.crypto`/`nox.json`nin "sıfırdan YAZMA, savaş-test edilmiş bir
/// algoritma KULLAN" ilkesiyle AYNI, SADECE bu SEFER Zig'in `std.time.
/// epoch`unda HAZIR OLMADIĞINDAN (bkz. AŞAĞIDAKİ `breakdownSeconds`in
/// AYNI notu) doğrudan bu KAYNAKTAN taşındı, sıfırdan İCAT EDİLMEDİ.
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y: i64 = if (m <= 2) y_in - 1 else y_in;
    const era: i64 = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe: i64 = y - era * 400; // [0, 399]
    const mp: i64 = if (m > 2) m - 3 else m + 9; // [0, 11]
    const doy: i64 = @divFloor(153 * mp + 2, 5) + d - 1; // [0, 365]
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

/// `DateTime`nin altı bileşenini (yıl/ay/gün/saat/dakika/saniye — `nox.
/// time.now()`nin ÜRETTİĞİ AYNI şekil) epoch-ms'e ÇEVİRİR — `daysFromCivil`
/// artı gün-İçİ saat/dakika/saniyenin milisaniyeye çevrilmesi. `breakdown
/// Seconds`nin AYNI "yalnızca 1970 VE SONRASI" sınırlamasıyla TUTARLI
/// (negatif epoch-ms üretilebilir AMA `nox.time`nin GERİ KALANI BUNU
/// zaten DESTEKLEMEZ).
export fn nox_time_to_epoch_ms_raw(year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64) callconv(.c) i64 {
    const days = daysFromCivil(year, month, day);
    return days * std.time.ms_per_day + hour * std.time.ms_per_hour + minute * std.time.ms_per_min + second * std.time.ms_per_s;
}

/// **Bilinçli v1 sınırlaması (KISMEN kapatıldı — bkz. `nox_time_to_epoch_
/// ms_raw`):** Zig'in KENDİ `std.time.epoch`u ters yönü (bileşenler ->
/// epoch-ms) SAĞLAMADIĞINDAN bu yön ÖNCEDEN v1 kapsamı DIŞINDA
/// bırakılmıştı — `daysFromCivil` (Hinnant'ın algoritması) İLE
/// KAPATILDI. Yalnızca 1970 VE SONRASI (negatif OLMAYAN epoch-ms)
/// desteklenir — `std.time.epoch.EpochSeconds`in KENDİSİ `u64` alır.
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

test "v3 madde 10: nox_time_to_epoch_ms_raw bilinen sabit epoch degerleriyle esler" {
    // 1970-01-01 00:00:00 UTC == epoch 0 (Unix epoch'un KENDİ tanımı).
    try std.testing.expectEqual(@as(i64, 0), nox_time_to_epoch_ms_raw(1970, 1, 1, 0, 0, 0));
    // 2000-03-01 00:00:00 UTC == 951868800000 (harici olarak DOĞRULANMIŞ
    // bilinen bir sabit — 2000 bir artık yıl OLDUĞUNDAN, Şubat'ı GEÇEN
    // bir tarih artık-yıl HESABINI da EGZERSİZ eder).
    try std.testing.expectEqual(@as(i64, 951868800000), nox_time_to_epoch_ms_raw(2000, 3, 1, 0, 0, 0));
    // 2024-02-29 12:34:56 UTC (artık gün) == 1709210096000.
    try std.testing.expectEqual(@as(i64, 1709210096000), nox_time_to_epoch_ms_raw(2024, 2, 29, 12, 34, 56));
}

test "v3 madde 10: nox_time_to_epoch_ms_raw <-> breakdownSeconds round-trip (rastgele denenmiş, gerçek yıl araligi)" {
    // `now_ms`nin KENDİ ayrıştırdığı bileşenleri (`nox_time_year_raw`/vb.)
    // GERİYE epoch-ms'e çevirip AYNI değeri GERİ VERDİĞİNİ doğrular — bu,
    // `daysFromCivil`in `breakdownSeconds`in KULLANDIĞI `std.time.epoch`
    // İLE TUTARLI (birbirinin TAM TERSİ) olduğunun KANITIDIR.
    const now = nox_time_now_ms_raw();
    const yd = breakdownSeconds(now).getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const day_secs = breakdownSeconds(now).getDaySeconds();
    const back = nox_time_to_epoch_ms_raw(
        yd.year,
        md.month.numeric(),
        @as(i64, md.day_index) + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    );
    // Milisaniye-altı kısım `now_ms`te olabilir ama `breakdownSeconds`
    // SANİYE çözünürlüğüne YUVARLADIĞINDAN, en fazla 999 ms'lik bir fark
    // BEKLENİR (KESİN eşitlik DEĞİL).
    try std.testing.expect(@abs(now - back) < 1000);
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
