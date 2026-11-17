//! `zig build pg-mobile-test`: iOS/Android'de kullanılan saf Zig PostgreSQL istemcisinin (`stdlib_shims/pg_wasm.zig`) masaüstünde, gerçek PostgreSQL'e karşı testi. Masaüstü `lib.zig` bu dosyayı
//! derlemez (`nox_pg_*` sembolleri `postgres.zig` ile çakışırdı), bu yüzden ayrı bir test kökü gerekir.
test {
    _ = @import("stdlib_shims/pg_wasm.zig");
    _ = @import("errors/handle.zig"); // `nox_raise` (zamanlayıcı bağımlılığı)
}
