//! Faz F.0.3 (bkz. plan dosyası "Panik/tanı çıktısı enjeksiyonu") —
//! runtime'ın TÜM tanı/hata çıktısını (yakalanmamış istisna mesajı,
//! bellek-sızıntısı raporu, deadlock tanısı, beklenmeyen errno uyarıları,
//! vb.) `std.debug.print`in HEP stderr'e yazan DOĞRUDAN çağrılarından
//! ENJEKTE EDİLEBİLİR bir "diag sink"e yönlendirir. `dispatch_registry.
//! zig`nin (Faz F.0.1) AYNI "program-genelinde, atomik, `.monotonic`"
//! deseni — AMA codegen tarafından KAYIT EDİLMEZ, `asap.zig`nin
//! `nox_runtime_init_with_allocator`i (Faz F.0.2) GİBİ SAF bir
//! Zig-seviyesi/opsiyonel host-override API'si. VARSAYILAN (kayıt
//! yapılmazsa) BUGÜNKÜ stderr davranışıyla BİREBİR AYNI, SIFIR davranış
//! değişikliği.

const std = @import("std");
const builtin = @import("builtin");

/// Faz F.0.7 (bkz. plan dosyası "Kritik düzeltme #3"in çözümü):
/// `defaultStderrSink`in `std.debug.print` bağımlılığını gate'lemek İçİn
/// — `std.debug.print`in KENDİSİ (`std.Io.Threaded` ÜZERİNDEN) freestanding'de
/// DERLENEMEYEN bir I/O katmanına dayanır.
const is_freestanding = builtin.os.tag == .freestanding or builtin.os.tag == .other;

/// `rt` (VARSA — bazı siteler `null` geçer, ör. reactor/erken-bootstrap
/// bağlamları), ÖNCEDEN biçimlendirilmiş `bytes[0..len]` bir tanı
/// mesajıdır (satır sonu DAHİL, HER ZAMAN `\n` İLE biter — MEVCUT TÜM
/// `std.debug.print` çağrılarının kendi formatlarıyla TUTARLI).
pub const DiagSinkFn = *const fn (rt: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void;

var g_diag_sink: std.atomic.Value(?DiagSinkFn) = .init(null);

fn defaultStderrSink(rt: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void {
    _ = rt;
    if (comptime is_freestanding) {
        // Freestanding'de GERÇEK bir stderr/`std.debug.print` I/O katmanı
        // YOK — GERÇEK bir freestanding host HER ZAMAN `nox_register_diag_
        // sink` İLE KENDİ (ör. seri port yazan) bir sink KAYDETMELİDİR;
        // bu VARSAYILAN, kayıt YOKSA sessizce hiçbir şey YAPMAZ.
        return;
    }
    std.debug.print("{s}", .{bytes[0..len]});
}

/// HER ZAMAN GEÇERLİ bir fonksiyon döner — `null` DÖNMEZ (kayıt YOKSA
/// `defaultStderrSink`).
pub fn diagSink() DiagSinkFn {
    return g_diag_sink.load(.monotonic) orelse defaultStderrSink;
}

/// GERÇEK bir freestanding host (VEYA bir test, sahte bir sink İLE
/// çıktıyı YAKALAMAK İçİn) TARAFINDAN çağrılır. `pub fn` (export DEĞİL —
/// HENÜZ codegen'DEN ÇAĞRILMIYOR, F.0.2'nin `nox_runtime_init_with_
/// allocator`iyle AYNI gerekçe).
pub fn nox_register_diag_sink(sink: ?DiagSinkFn) void {
    g_diag_sink.store(sink, .monotonic);
}

/// TÜM çağrı sitelerinin KULLANDIĞI, PAYLAŞILAN kolaylık sarmalayıcısı —
/// `comptime fmt`i 512-baytlık bir YIĞIN arabelleğine biçimlendirir
/// (`hpy_bridge/context.zig`nin `ctxErrSetFromErrnoWithFilename`ının
/// AYNI, ZATEN kanıtlanmış boyutu) SONRA `diagSink()`i ÇAĞIRIR. Taşma
/// DURUMUNDA (mevcut HİÇBİR mesaj buna YAKLAŞMIYOR) SESSİZCE düşer —
/// bir tanı mesajının KENDİSİNİN BAŞARISIZ olması PROGRAM davranışını
/// ETKİLEMEMELİDİR.
pub fn report(rt: ?*anyopaque, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    diagSink()(rt, msg.ptr, msg.len);
}

// Not: bu dosyanın KENDİ `test` blokları OLMAZ — `build.zig`nin `diag_sink`
// modülü HİÇBİR `b.addTest` hedefine bağlı DEĞİL (SADECE `noxrt_mod`/
// `fiber_test_mod`/`scheduler_test_mod`/`channel_test_mod`/`io_test_mod`a
// bir named-import olarak VERİLİYOR), bu YÜZDEN BURAYA yazılan bir `test`
// bloğu ASLA çalıştırılmazdı (`abi_layout.zig`nin AYNI, sıfır-test
// konvansiyonuyla TUTARLI). Gerçek doğrulama `runtime/errors/handle.zig`nin
// KENDİ (noxrt_mod'un PARÇASI, test-keşfi ÇALIŞAN) test bloklarında yapılır.
