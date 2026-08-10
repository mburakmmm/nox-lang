//! Faz MN.3b: `worker_pool.zig`nin KENDİ testlerini, `runtime/lib.zig`nin
//! TAMAMINI (TÜM stdlib_shims'i) derlemeden çalıştırabilmek İçİn DAR bir
//! test kökü — `worker_pool.zig`nin `../alloc/...` GÖRELİ import'ları BU
//! kökün (`runtime/`) ALTINDA kaldığından (Zig'in modül sınırı "kök
//! dosyanın DIZINI DIŞINA `..` İLE ÇIKILAMAZ" kısıtlaması BURADA
//! İHLAL EDİLMEZ). Bkz. `build.zig`nin `worker-pool-test` adımı.
test {
    _ = @import("async_rt/worker_pool.zig");
}
