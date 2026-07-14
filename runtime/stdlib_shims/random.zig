//! `nox.random` Zig kabuğu — stdlib fazı V.2 (bkz. nox-teknik-spesifikasyon.md).
//!
//! PRNG durumu (`g_prng`), `nox.os`nin argc/argv'si İLE AYNI "süreç ömrü
//! boyunca yaşayan statik değişken" deseniyle TUTULUR — Nox'ta fonksiyonlar
//! arası PAYLAŞILAN mutable modül-düzeyi durum OLMADIĞINDAN (bkz. `nox.log`nin
//! AYNI notu), rastgelelik durumunun BARINABİLECEĞİ TEK yer budur. İLK
//! kullanımda (`seed` HİÇ çağrılmadıysa) `clock_gettime` tabanlı bir zaman
//! damgasıyla OTOMATİK tohumlanır (Python'un `random` modülünün KENDİ
//! varsayılan davranışıyla TUTARLI). Kriptografik GÜVENLİK İDDİASI YOK (Xoshiro256,
//! `std.Random.DefaultPrng`) — yalnızca genel amaçlı/test/oyun senaryoları
//! İÇİN.
const std = @import("std");

var g_prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0);
var g_seeded: bool = false;

fn ensureSeeded() void {
    if (!g_seeded) {
        // `nox.time`in AYNI `clock_gettime` deseni (bkz. `time.zig`'in
        // `nox_time_now_ms_raw`ı) — bu Zig sürümünde `std.time.milliTimestamp`
        // KULLANILAMADIĞINDAN (kaldırılmış/taşınmış).
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        const seed: u64 = @bitCast(@as(i64, ts.sec) *% 1_000_000_000 +% ts.nsec);
        g_prng = std.Random.DefaultPrng.init(seed);
        g_seeded = true;
    }
}

export fn nox_random_seed_raw(s: i64) callconv(.c) void {
    g_prng = std.Random.DefaultPrng.init(@bitCast(s));
    g_seeded = true;
}

/// `lo`/`hi` İKİSİ de DAHİLDİR (Python'un `random.randint`iyle TUTARLI).
/// `hi <= lo` İSE (bilinçli basitleştirme — YENİ bir checker/codegen
/// istisna türü GEREKTİRMEMEK İÇİN) sessizce `lo` döner.
export fn nox_random_randint_raw(lo: i64, hi: i64) callconv(.c) i64 {
    ensureSeeded();
    if (hi <= lo) return lo;
    return g_prng.random().intRangeLessThan(i64, lo, hi + 1);
}

/// `[0.0, 1.0)` aralığında.
export fn nox_random_random_raw() callconv(.c) f64 {
    ensureSeeded();
    return g_prng.random().float(f64);
}
