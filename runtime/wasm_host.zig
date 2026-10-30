//! Faz 10 (WASM): `wasm32-freestanding` çalışma zamanının dış dünyayla TEK sözleşmesi — `nox_host` import ad alanı (ADR-013). Modül WASI'ye ya da
//! libc'ye bağlı DEĞİLDİR; host (tarayıcı, Node, Nexus Engine, test çalıştırıcısı) bu fonksiyonları sağlar. Sürüm `nox_host_abi_version` ile sorgulanır:
//! host, modülün `nox_host_abi_version()` dışa aktarımını okuyup desteklemediği bir sürümde yüklemeyi reddedebilir.
//!
//! Her fonksiyon senkrondur ve hata durumunda negatif bir değer döner (`write`/`read`: yazılan/okunan bayt sayısı ya da `-1`).

const builtin = @import("builtin");

pub const ABI_VERSION: u32 = 1;

pub const is_freestanding_wasm = builtin.cpu.arch.isWasm() and builtin.os.tag == .freestanding;

/// `fd`: 1 = stdout, 2 = stderr, 0 = stdin. Yazılan bayt sayısını döner, hata `-1`.
pub extern "nox_host" fn write(fd: i32, ptr: [*]const u8, len: usize) i32;
/// stdin'den (`fd == 0`) en çok `len` bayt okur; dönen `0` dosya sonudur, `-1` hata.
pub extern "nox_host" fn read(fd: i32, ptr: [*]u8, len: usize) i32;
/// `kind == 0`: duvar saati (epoch ms), `kind == 1`: monoton saat (ms).
pub extern "nox_host" fn clock_ms(kind: i32) i64;
/// `ptr[0..len]` aralığını kriptografik rastgele baytlarla doldurur.
pub extern "nox_host" fn random_fill(ptr: [*]u8, len: usize) void;
/// Programı sonlandırır (host `_start`ın döndüğü gibi davranır; bu fonksiyon dönmez).
pub extern "nox_host" fn exit(code: i32) noreturn;
/// Çağıran iş parçacığını `ms` milisaniye bekletir. Tek iş parçacıklı kipte host bekleme yapmayabilir (anında dönebilir).
pub extern "nox_host" fn sleep_ms(ms: i64) void;

/// Hedefe göre süreci sonlandırır: wasm32-freestanding'de host'un `exit`i, aksi halde `std.process.exit`.
pub fn exitProcess(code: u8) noreturn {
    if (comptime is_freestanding_wasm) exit(code);
    @import("std").process.exit(code);
}

/// YALNIZCA iş parçacıklı modüllerin (`wasm32-freestanding-threads`, ADR-015) içe aktardığı: yeni bir iş parçacığı başlatır; host paylaşımlı belleğe bağlı yeni bir örnekte
/// `nox_host_thread_start(tid, arg)`ı çağırır. Dönen `tid > 0`; hata `< 0`.
pub extern "nox_host" fn thread_spawn(arg: usize) i32;
