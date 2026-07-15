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
//!
//! **`threadlocal` (Faz BB.1, bkz. nox-teknik-spesifikasyon.md §3.47):**
//! `g_prng`/`g_seeded` İDEMPOTENT bir önbellek DEĞİLDİR — HER çağrıda
//! GERÇEKTEN mutasyona UĞRAR (`intRangeLessThan`/`float` PRNG durumunu
//! İLERLETİR). `nox.thread.spawn`in paylaşımsız (shared-nothing) modeli
//! ÖNCESİ bu düz `var` GÜVENLİYDİ (M:1, TEK OS iş parçacığı) — ŞİMDİ İKİ
//! GERÇEK OS iş parçacığı AYNI ANDA `nox.random.*` ÇAĞIRABİLDİĞİNDEN,
//! senkronize OLMAYAN bir PAYLAŞILAN PRNG durumu SESSİZ veri bozulması
//! (data race) olurdu — `threadlocal` HER iş parçacığına KENDİ BAĞIMSIZ
//! PRNG durumunu VERİR, SIFIR ek senkronizasyon MALİYETİYLE.
const std = @import("std");

threadlocal var g_prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0);
threadlocal var g_seeded: bool = false;

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

// Faz BB.1: `g_prng`/`g_seeded`nin `threadlocal` OLMASININ, İKİ GERÇEK OS
// iş parçacığının AYNI ANDA `nox.random` ÇAĞIRDIĞINDA birbirini ETKİLEMEDİĞİNİ
// kanıtlar — HER iş parçacığı KENDİ tohumuyla ÜRETTİĞİ diziyi, DİĞER iş
// parçacığı AYNI ANDA ÇALIŞIRKEN BİLE, o tohumun TEK-İŞ-PARÇACIKLI (sıralı)
// üretimiyle BİREBİR AYNI verir — paylaşılan bir PRNG durumu OLSAYDI bu
// İMKANSIZ olurdu (iki iş parçacığının İÇ İÇE geçmiş çağrıları diziyi
// BOZARDI).
test "g_prng threadlocal: iki gerçek OS iş parçacığı bağımsız/tekrarlanabilir diziler üretir" {
    const N = 50;

    const Worker = struct {
        fn run(seed: i64, out: *[N]i64) void {
            nox_random_seed_raw(seed);
            for (out) |*slot| slot.* = nox_random_randint_raw(0, 1_000_000);
        }
    };

    var result_a: [N]i64 = undefined;
    var result_b: [N]i64 = undefined;
    const thread_a = try std.Thread.spawn(.{}, Worker.run, .{ 111, &result_a });
    const thread_b = try std.Thread.spawn(.{}, Worker.run, .{ 222, &result_b });
    thread_a.join();
    thread_b.join();

    // Aynı tohumlarla, SIRALI (tek iş parçacıklı) olarak tekrar üret —
    // yukarıdaki eşzamanlı sonuçlarla BİREBİR eşleşmeli.
    var expected_a: [N]i64 = undefined;
    nox_random_seed_raw(111);
    for (&expected_a) |*slot| slot.* = nox_random_randint_raw(0, 1_000_000);

    var expected_b: [N]i64 = undefined;
    nox_random_seed_raw(222);
    for (&expected_b) |*slot| slot.* = nox_random_randint_raw(0, 1_000_000);

    try std.testing.expectEqualSlices(i64, &expected_a, &result_a);
    try std.testing.expectEqualSlices(i64, &expected_b, &result_b);
    // İki farklı tohumun AYNI diziyi üretmediğini de doğrula (sağlamlık).
    try std.testing.expect(!std.mem.eql(i64, &result_a, &result_b));
}
