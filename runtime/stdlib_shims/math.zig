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
    return @exp(x);
}

export fn nox_math_atan2_raw(y: f64, x: f64) callconv(.c) f64 {
    return std.math.atan2(y, x);
}

/// v1.162.0: Python `round(x, ndigits)` — `x`in TAM ikili değeri üzerinde ondalık yuvarlama (yarım → çifte), böylece
/// `round(2.675, 2) == 2.67` ve `round(0.5) == 0.0`. `nd < 0` onlar/yüzler basamağına yuvarlar. Büyük tamsayı aritmetiği
/// (`std.math.big.int`) sabit bir yığın tamponunda çalışır (gizli global durum/allocator YOK).
export fn nox_float_round_digits_raw(x: f64, nd: i64) callconv(.c) f64 {
    if (!std.math.isFinite(x) or x == 0) return x;
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
