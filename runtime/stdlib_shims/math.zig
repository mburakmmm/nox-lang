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
