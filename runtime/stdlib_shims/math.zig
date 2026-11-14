//! `nox.math` Zig kabuğu — v4 Faz B, madde 1 (bkz. nox-teknik-
//! spesifikasyon.md §3.2xx). ÖNCEDEN `stdlib/nox/math.nox` DOĞRUDAN
//! libm'e (`extern def ... from "m"`) BAĞLIYORDU — bu dosya, Zig'in
//! KENDİ `std.math`ının (libc'DEN TAMAMEN BAĞIMSIZ — `@sin`/`@cos`/
//! `@tan`/`@exp`/`@sqrt`/`@floor`/`@ceil` Zig DİL düzeyinde birer
//! BUILTIN'dir, LLVM intrinsic'lerine/donanım komutlarına İNDİRİLİR;
//! `pow`/`atan2`/doğal `log` İSE `std.math`nin musl'DAN PORTLANMIŞ, SAF
//! Zig algoritmalarıdır) üzerine kurulu bir sarmalayıcı sağlayarak
//! `nox.math`yi freestanding-güvenli YAPAR — `nox.sqlite`nin parola
//! hash'lemesinin (bkz. proje belleği "Parola hash'leme") `std.crypto.
//! pwhash`ı KULLANMASIYLA AYNI "harici bağımlılık YOK" ilkesi.
//!
//! **`_raw` SONEKİ (bkz. `time.zig`/`os.zig`nin AYNI çakışma notu):**
//! `stdlib/nox/math.nox`nin KISA Nox sarmalayıcıları (`sqrt`/`pow`/vb.)
//! `nox_math_sqrt`/`nox_math_pow`e MANGLE OLDUĞUNDAN, buradaki extern
//! def'ler `_raw` SONEKİYLE tanımlanır (çakışmayı önler).
//!
//! HİÇBİRİ ARC/`rt` GEREKTİRMEZ (salt `float`<->`float`, ESKİ bare
//! `extern def ... from "m"` İLE AYNI ARC-dışı kategori).

const std = @import("std");

export fn nox_math_sqrt_raw(x: f64) callconv(.c) f64 {
    return @sqrt(x);
}

export fn nox_math_pow_raw(x: f64, y: f64) callconv(.c) f64 {
    return std.math.pow(f64, x, y);
}

export fn nox_math_floor_raw(x: f64) callconv(.c) f64 {
    return @floor(x);
}

export fn nox_math_ceil_raw(x: f64) callconv(.c) f64 {
    return @ceil(x);
}

export fn nox_math_sin_raw(x: f64) callconv(.c) f64 {
    return @sin(x);
}

export fn nox_math_cos_raw(x: f64) callconv(.c) f64 {
    return @cos(x);
}

export fn nox_math_tan_raw(x: f64) callconv(.c) f64 {
    return @tan(x);
}

/// Doğal logaritma — `std.math.log(T, base, x)`nin `base == std.math.e`
/// dalı (`@log(x)` builtin'ine düşer, bkz. `std.math.log`nin KENDİ
/// belge notu).
export fn nox_math_log_raw(x: f64) callconv(.c) f64 {
    return std.math.log(f64, std.math.e, x);
}

export fn nox_math_exp_raw(x: f64) callconv(.c) f64 {
    // v2.1.59: çıplak çekirdekte compiler-rt `exp`i 1 ULP sapabilir; f128 tabanlı doğru yuvarlamalı sürüm (bkz. exp_accurate.zig).
    if (comptime @import("shim_util.zig").bare_kernel) return @import("exp_accurate.zig").expAccurate(x);
    return @exp(x);
}

/// Bit düzeyinde yeniden yorumlama (IEEE 754): `nox.protobuf` `double`/`float` alanları için. `f64` ↔ 64 bit; `f32` için değer önce `f32`ye yuvarlanır (alt 32 bit döner).
export fn nox_float_bits_raw(x: f64) callconv(.c) i64 {
    return @bitCast(x);
}

export fn nox_float_from_bits_raw(b: i64) callconv(.c) f64 {
    return @bitCast(b);
}

export fn nox_float32_bits_raw(x: f64) callconv(.c) i64 {
    const f: f32 = @floatCast(x);
    const u: u32 = @bitCast(f);
    return @intCast(u);
}

export fn nox_float32_from_bits_raw(b: i64) callconv(.c) f64 {
    const u: u32 = @truncate(@as(u64, @bitCast(b)));
    const f: f32 = @bitCast(u);
    return f;
}

export fn nox_math_atan2_raw(y: f64, x: f64) callconv(.c) f64 {
    return std.math.atan2(y, x);
}

/// v2.1.159: `pow(b, e, m)` — modüler üs alma (`e >= 0`, `m != 0` çağıranca doğrulanır). Sonuç Python gibi `m`in işaretini taşır
/// (`m > 0` için `[0, m)`, `m < 0` için `(m, 0]`); ara çarpımlar 128 bittir, taşma yok.
export fn nox_int_pow_mod_raw(b: i64, e: i64, m: i64) callconv(.c) i64 {
    if (m == 0 or e < 0) return 0;
    const am: u128 = @abs(@as(i128, m));
    var base: u128 = @intCast(@mod(@as(i128, b), @as(i128, @intCast(am))));
    var exp: u64 = @intCast(e);
    var r: u128 = 1 % am;
    while (exp != 0) : (exp >>= 1) {
        if (exp & 1 == 1) r = (r * base) % am;
        base = (base * base) % am;
    }
    const pos: i128 = @intCast(r);
    return @intCast(if (m < 0 and pos != 0) pos - @as(i128, @intCast(am)) else pos);
}

test "nox_int_pow_mod_raw Python pow(b, e, m) ile birebir" {
    try std.testing.expectEqual(@as(i64, 24), nox_int_pow_mod_raw(2, 10, 1000));
    try std.testing.expectEqual(@as(i64, 4), nox_int_pow_mod_raw(2, 10, 5));
    try std.testing.expectEqual(@as(i64, 1), nox_int_pow_mod_raw(7, 0, 13));
    try std.testing.expectEqual(@as(i64, 0), nox_int_pow_mod_raw(5, 3, 1));
    try std.testing.expectEqual(@as(i64, 5), nox_int_pow_mod_raw(-2, 3, 13));
    try std.testing.expectEqual(@as(i64, -3), nox_int_pow_mod_raw(5, 2, -7));
    try std.testing.expectEqual(@as(i64, 136318165), nox_int_pow_mod_raw(3, 200, 1_000_000_007));
    // büyük modül: 128 bit ara çarpım taşmaz
    try std.testing.expectEqual(@as(i64, 7304489514424542795), nox_int_pow_mod_raw(123456789, 987654321, 9223372036854775783));
    try std.testing.expectEqual(@as(i64, -16807), nox_int_pow_mod_raw(-7, 5, -9223372036854775807));
}

/// v1.162.0: Python `round(x, ndigits)` — `x`in TAM ikili değeri üzerinde ondalık yuvarlama (yarım → çifte), böylece
/// `round(2.675, 2) == 2.67` ve `round(0.5) == 0.0`. `nd < 0` onlar/yüzler basamağına yuvarlar. Büyük tamsayı aritmetiği
/// (`std.math.big.int`) sabit bir yığın tamponunda çalışır (gizli global durum/allocator YOK).
export fn nox_float_round_digits_raw(x: f64, nd: i64) callconv(.c) f64 {
    if (!std.math.isFinite(x) or x == 0) return x;
    if (roundFast(x, nd)) |r| return r;
    return roundDigitsExact(x, nd);
}

/// v2.1.159: sıcak yol. `nd == 0` için yarım→çifte yuvarlama doğrudan (IEEE `roundeven`); `1 <= nd <= 22` için `x * 10^nd` (10^nd tam temsil
/// edilir) tek yuvarlamayla hesaplanır ve KESİN tamsayı sonuç yalnızca kesirli kısım yarım noktadan güvenli uzaktaysa kullanılır
/// (`|frac - 0.5| > |y| * 2^-50`: çarpmanın <= 1/2 ulp hatasından çok büyük); sonuç `r / 10^nd` (tek, doğru yuvarlanmış bölme — büyük
/// tamsayı yolunun `"{r}e-nd"` ayrıştırmasıyla aynı değer). Belirsiz/aralık dışı girdiler `null` döner ve tam yola düşer.
fn roundFast(x: f64, nd: i64) ?f64 {
    const ax = @abs(x);
    if (nd == 0) {
        if (ax >= 4503599627370496.0) return x; // 2^52: zaten tamsayı
        const t = @trunc(x);
        const frac = ax - @abs(t);
        var r = @round(x);
        if (frac == 0.5) r = 2.0 * @round(x * 0.5);
        return if (r == 0) std.math.copysign(@as(f64, 0), x) else r;
    }
    if (nd < 1 or nd > 22) return null;
    const p10_table = [_]f64{ 1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22 };
    const p10 = p10_table[@intCast(nd)];
    const y = x * p10;
    const ay = @abs(y);
    if (!(ay < 4503599627370496.0)) return null;
    const t = @trunc(y);
    const frac = ay - @abs(t);
    if (@abs(frac - 0.5) <= ay * 8.881784197001252e-16) return null; // 2^-50
    const r = @round(y);
    const q = r / p10;
    return if (q == 0) std.math.copysign(@as(f64, 0), x) else q;
}

fn roundDigitsExact(x: f64, nd: i64) f64 {
    if (nd > 340) return x;
    if (nd < -340) return std.math.copysign(@as(f64, 0), x);
    const big = std.math.big.int;
    var fba_buf: [32768]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const a = fba.allocator();
    const bits: u64 = @bitCast(x);
    const neg = (bits >> 63) != 0;
    const exp_bits: i32 = @intCast((bits >> 52) & 0x7FF);
    var m: u64 = bits & ((@as(u64, 1) << 52) - 1);
    var e: i32 = undefined;
    if (exp_bits == 0) {
        e = -1074;
    } else {
        m |= (@as(u64, 1) << 52);
        e = exp_bits - 1075;
    }
    var n = big.Managed.initSet(a, m) catch return x;
    var d = big.Managed.initSet(a, 1) catch return x;
    var ten = big.Managed.initSet(a, 10) catch return x;
    var p10 = big.Managed.initSet(a, 1) catch return x;
    const k: usize = @intCast(if (nd >= 0) nd else -nd);
    var i: usize = 0;
    while (i < k) : (i += 1) p10.mul(&p10, &ten) catch return x;
    if (nd >= 0) n.mul(&n, &p10) catch return x else d.mul(&d, &p10) catch return x;
    if (e >= 0) n.shiftLeft(&n, @intCast(e)) catch return x else d.shiftLeft(&d, @intCast(-e)) catch return x;
    var q = big.Managed.init(a) catch return x;
    var r = big.Managed.init(a) catch return x;
    q.divTrunc(&r, &n, &d) catch return x;
    var r2 = big.Managed.init(a) catch return x;
    r2.shiftLeft(&r, 1) catch return x;
    const ord = r2.toConst().order(d.toConst());
    if (ord == .gt or (ord == .eq and q.toConst().isOdd())) {
        var one = big.Managed.initSet(a, 1) catch return x;
        q.add(&q, &one) catch return x;
    }
    const qs = q.toString(a, 10, .lower) catch return x;
    var out: [1024]u8 = undefined;
    const exp10: i64 = -nd;
    const txt = std.fmt.bufPrint(&out, "{s}{s}e{d}", .{ if (neg) "-" else "", qs, exp10 }) catch return x;
    return std.fmt.parseFloat(f64, txt) catch x;
}

test "float bit dönüşümleri: gidiş-dönüş ve f32 yuvarlama" {
    try std.testing.expectEqual(@as(i64, 0x3FF0000000000000), nox_float_bits_raw(1.0));
    try std.testing.expectEqual(@as(f64, -2.5), nox_float_from_bits_raw(nox_float_bits_raw(-2.5)));
    try std.testing.expectEqual(@as(i64, 0x3F800000), nox_float32_bits_raw(1.0));
    try std.testing.expectEqual(@as(f64, 0.5), nox_float32_from_bits_raw(nox_float32_bits_raw(0.5)));
}

test "nox_float_round_digits_raw Python round() ile birebir" {
    const cases = [_]struct { x: f64, nd: i64, want: f64 }{
        .{ .x = 2.675, .nd = 2, .want = 2.67 },
        .{ .x = 0.5, .nd = 0, .want = 0.0 },
        .{ .x = 1.5, .nd = 0, .want = 2.0 },
        .{ .x = 2.5, .nd = 0, .want = 2.0 },
        .{ .x = -1.5, .nd = 0, .want = -2.0 },
        .{ .x = 1.005, .nd = 2, .want = 1.0 },
        .{ .x = 3.14159, .nd = 2, .want = 3.14 },
        .{ .x = 0.125, .nd = 2, .want = 0.12 },
        .{ .x = 0.375, .nd = 2, .want = 0.38 },
        .{ .x = 1234.5, .nd = -2, .want = 1200.0 },
        .{ .x = 1350.0, .nd = -2, .want = 1400.0 },
        .{ .x = 1e22, .nd = 2, .want = 1e22 },
    };
    for (cases) |c| try std.testing.expectEqual(c.want, nox_float_round_digits_raw(c.x, c.nd));
}

test "round hızlı yol: tam (büyük tamsayı) yolla rastgele girdilerde birebir aynı" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 20000) : (i += 1) {
        const mag = rnd.float(f64) * std.math.pow(f64, 10.0, @floatFromInt(rnd.intRangeAtMost(i32, -3, 9)));
        const x: f64 = if (rnd.boolean()) mag else -mag;
        const nd: i64 = rnd.intRangeAtMost(i64, 0, 8);
        if (x == 0) continue;
        const fast = nox_float_round_digits_raw(x, nd);
        const exact = roundDigitsExact(x, nd);
        try std.testing.expectEqual(@as(u64, @bitCast(exact)), @as(u64, @bitCast(fast)));
    }
    // yarım noktalar ve çifte yuvarlama
    const halves = [_]f64{ 0.5, 1.5, 2.5, 3.5, -0.5, -2.5, 0.125, 0.375, 2.675, 1.005, 4503599627370495.5, 1e15 + 0.5 };
    for (halves) |h| {
        var nd: i64 = 0;
        while (nd <= 3) : (nd += 1) {
            try std.testing.expectEqual(@as(u64, @bitCast(roundDigitsExact(h, nd))), @as(u64, @bitCast(nox_float_round_digits_raw(h, nd))));
        }
    }
}
