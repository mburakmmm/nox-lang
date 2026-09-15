const std = @import("std");

/// Faz F.0.1 (bkz. proje planı "Freestanding Nox — dlopen/dlsym-tabanlı
/// dispatch'i statik, 'push' modeli bir kayıt mekanizmasına çevirme"):
/// ÖNCEDEN `runtime/alloc/arc.zig`/`runtime/alloc/cycle_detector.zig`/
/// `runtime/collections/dict.zig`/`runtime/errors/handle.zig`/`runtime/
/// stdlib_shims/json.zig`'in HER BİRİ, codegen'in ürettiği bir sembolü
/// (`nox_class_release_dispatch`/`nox_trace_dispatch`/`nox_gc_free_
/// dispatch`/`nox_class_name_dispatch`/`nox_json_make_json_value`)
/// `dlopen(null,...)+dlsym` İLE ÇALIŞMA ZAMANINDA ARIYORDU — freestanding'de
/// (dinamik yükleyici YOK) bu KAVRAMSAL olarak İMKANSIZ. BU dosya, "pull"
/// (isimle ara) modelini "push" (codegen'in KENDİSİ, program BAŞLARKEN,
/// sembol ADRESLERİNİ TEK SEFER kaydeder) modeline çevirir.
///
/// `noxrt_test` (HİÇBİR Nox programı OLMADAN derlenen, `zig build test`in
/// parçası) BAĞLAMINDA `nox_register_dispatch_table` HİÇ ÇAĞRILMAZ — TÜM
/// alanlar `null` KALIR, HER tüketici BUNU ESKİ dlsym'in "bulunamadı"
/// durumuyla BİREBİR AYNI şekilde (sessiz no-op/güvenli varsayılan) ele
/// alır — SIFIR davranış değişikliği.
pub const TraceFn = *const fn (?*anyopaque, i64, ?*anyopaque) callconv(.c) ?*anyopaque;
pub const GcFreeFn = *const fn (?*anyopaque, i64, ?*anyopaque) callconv(.c) void;
pub const ClassReleaseFn = *const fn (?*anyopaque, i64, ?*anyopaque) callconv(.c) void;
pub const ClassNameFn = *const fn (?*anyopaque, i64, ?*anyopaque) callconv(.c) [*:0]const u8;
pub const MakeJsonValueFn = *const fn (rt: ?*anyopaque, kind: i64, b: i32, n: f64, s: ?[*:0]const u8, arr: ?*anyopaque, keys: ?*anyopaque, vals: ?*anyopaque) callconv(.c) ?*anyopaque;

// Faz F.0.1: `pool_ever_active`/`fiber_ever_active`nin (bkz. `asap.zig`)
// AYNI, ZATEN kanıtlanmış "TEK yazma, HERHANGİ bir fiber/iş parçacığı
// spawn EDİLMEDEN ÖNCE + program-sırası happens-before + `.monotonic`
// YETERLİ" gerekçesi — kayıt HER ZAMAN `$main`'ın EN BAŞINDA (bkz.
// `genMain`/`genMainAsync`'ın `$nox_runtime_init`/`$nox_pool_main_init`
// çağrısının HEMEN ARDINDAN) olur, HERHANGİ bir spawn'DAN ÖNCE.
var g_trace_fn: std.atomic.Value(?TraceFn) = .init(null);
var g_gc_free_fn: std.atomic.Value(?GcFreeFn) = .init(null);
var g_class_release_fn: std.atomic.Value(?ClassReleaseFn) = .init(null);
var g_class_name_fn: std.atomic.Value(?ClassNameFn) = .init(null);
var g_make_json_value_fn: std.atomic.Value(?MakeJsonValueFn) = .init(null);

pub fn traceFn() ?TraceFn {
    return g_trace_fn.load(.monotonic);
}
pub fn gcFreeFn() ?GcFreeFn {
    return g_gc_free_fn.load(.monotonic);
}
pub fn classReleaseFn() ?ClassReleaseFn {
    return g_class_release_fn.load(.monotonic);
}
pub fn classNameFn() ?ClassNameFn {
    return g_class_name_fn.load(.monotonic);
}
pub fn makeJsonValueFn() ?MakeJsonValueFn {
    return g_make_json_value_fn.load(.monotonic);
}

/// Codegen tarafından `genMain`/`genMainAsync`'ın `$nox_runtime_init`
/// (veya `$nox_pool_main_init`) ÇAĞRISININ HEMEN ARDINDAN, KOŞULSUZ, HER
/// programda TEK SEFER çağrılır — `nox_rc_release_enqueue_fixed`'in
/// `$ClassName_release` sembol-adını `l`-tipi bir ARGÜMAN olarak geçen
/// AYNI, ZATEN kanıtlanmış mekanizma (bkz. `compiler/codegen_qbe/
/// ownership.zig:329,436,440`) — sembol adları (`$nox_trace_dispatch`
/// vb.) doğrudan `l`-tipi değerler OLARAK geçirilir, YENİ bir QBE/LLVM
/// emisyon ilkeli GEREKMEZ.
///
/// Testler (ör. `cycle_detector.zig`'ın `fakeTraceDispatch`/
/// `fakeTraceDispatchDiamond`'ı) bu fonksiyonu DOĞRUDAN, GERÇEK bir Nox
/// programı OLMADAN çağırarak sahte dispatch'ler ENJEKTE edebilir.
pub export fn nox_register_dispatch_table(
    trace_fn: ?TraceFn,
    gc_free_fn: ?GcFreeFn,
    class_release_fn: ?ClassReleaseFn,
    class_name_fn: ?ClassNameFn,
    make_json_value_fn: ?MakeJsonValueFn,
) void {
    g_trace_fn.store(trace_fn, .monotonic);
    g_gc_free_fn.store(gc_free_fn, .monotonic);
    g_class_release_fn.store(class_release_fn, .monotonic);
    g_class_name_fn.store(class_name_fn, .monotonic);
    g_make_json_value_fn.store(make_json_value_fn, .monotonic);
}
