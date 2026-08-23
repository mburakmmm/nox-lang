//! Nox hata yayılım mekanizması — AGENTS.md §9.
//!
//! QBE hiçbir zaman unwind tablosu/landing pad üretmez (İlke #3); bu yüzden
//! hata yayılımı, derleyicinin (bkz. compiler/codegen_qbe/codegen.zig) her
//! kullanıcı fonksiyonu/metod çağrısından sonra ürettiği örtük bir "bekleyen
//! istisna var mı?" kontrolüyle yapılır — Zig'in kendi `error union`larına
//! benzer bir örtük hata-döndürme zinciri (implicit error-return threading).
//!
//! Bekleyen istisna durumu, çalışma zamanı bağlamının (`rt`) BİR PARÇASIDIR
//! (bkz. `asap.RuntimeState.pending_exception`) — gizli bir global/statik
//! değişken DEĞİLDİR; her çağrıda açıkça taşınan `rt` işaretçisi üzerinden
//! erişilir (İlke #6).
//!
//! `ExceptionHandle`, şu an için yalnızca fırlatılan Nox sınıf örneğine
//! (refcount'lu, çalışma zamanı tip etiketi taşıyan) bir işaretçidir —
//! `except ClassName:` eşleşmesi codegen tarafında bu etiketin doğrudan
//! karşılaştırılmasıyla yapılır (bkz. nox-teknik-spesifikasyon.md §3.7:
//! v0.1'de sınıf kalıtımı olmadığı için eşleşme tam/isim bazlıdır, hiyerarşik
//! değildir).

const std = @import("std");
const builtin = @import("builtin");
const asap = @import("../alloc/asap.zig");
const abi_layout = @import("abi_layout");
const bridge = @import("../async_rt/bridge.zig");

/// Faz MN.2 (bkz. `fiber.zig`nin `pending_exception` belge notu): fiber
/// İÇİNDE `Fiber.pending_exception`/`pending_exception_line`e, DIŞINDA
/// (senkron üst-düzey kod, `async` HİÇ kullanmayan bir programın `main`i
/// GİBİ) `RuntimeState`in KENDİ alanlarına (BUGÜNKÜ davranışla BİREBİR
/// aynı) düşer.
const PendingException = struct { obj: *?*anyopaque, line: *i64 };

fn pendingException(state: *asap.RuntimeState) PendingException {
    // Faz [YENİ] (bkz. plan dosyası "İki gerçek performans regresyonunu
    // düzeltme"): `bridge.currentFiber()` bir `threadlocal` (`g_scheduler`)
    // okur — macOS'ta bu GERÇEK bir TLV thunk çağrısıdır (`otool -tV` İLE
    // DOĞRULANDI: bir `blr`), SIRADAN bir alan okumasından ÇOK daha pahalı.
    // HİÇ async/spawn KULLANMAYAN (EZİCİ ÇOĞUNLUKTAKİ) programlarda BU
    // TAMAMEN GEREKSİZDİR — `state.fiber_ever_active` (bkz. onun belge
    // notu) `false` İKEN `currentFiber()` zaten HER ZAMAN `null` dönerdi,
    // bu YÜZDEN o çağrıyı TAMAMEN ATLAMAK davranışı DEĞİŞTİRMEZ.
    if (state.fiber_ever_active.load(.monotonic)) {
        if (bridge.currentFiber()) |f| return .{ .obj = &f.pending_exception, .line = &f.pending_exception_line };
    }
    return .{ .obj = &state.pending_exception, .line = &state.pending_exception_line };
}

/// `obj`'yi (bir Nox sınıf örneği işaretçisini) bekleyen istisna olarak
/// işaretler. Faz OO.3: `line` — `raise` deyiminin (ya da örtük IndexError/
/// KeyError/ValueError'ın) KAYNAK satırı — yalnızca `nox_unhandled_
/// exception`ın raporlaması İçİn saklanır, akış kontrolünü ETKİLEMEZ.
export fn nox_raise(rt: ?*anyopaque, obj: ?*anyopaque, line: i64) void {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return));
    const pe = pendingException(state);
    pe.obj.* = obj;
    pe.line.* = line;
}

/// Şu an bekleyen bir istisna olup olmadığını bildirir (0/1 — QBE `w` ile
/// çağrılır; ABI belirsizliğinden kaçınmak için `bool` yerine `i32` kullanılır).
export fn nox_exception_pending(rt: ?*anyopaque) i32 {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return 0));
    return if (pendingException(state).obj.* != null) 1 else 0;
}

/// Bekleyen istisnayı döndürür ve durumu temizler (bir `except` onu yakaladığında
/// ya da yeniden fırlatmadan önce çağrılır).
export fn nox_exception_take(rt: ?*anyopaque) ?*anyopaque {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    const pe = pendingException(state);
    const obj = pe.obj.*;
    pe.obj.* = null;
    return obj;
}

/// Faz OO.3 (bkz. `compiler/codegen_qbe/layout.zig`nin `genClassName
/// Dispatch`ının belge notu): bu sembol yalnızca EN AZ BİR sınıf İÇEREN
/// bir programda üretilir — `runtime/alloc/cycle_detector.zig`nin
/// `resolveTraceDispatch`İYLE BİREBİR AYNI `dlsym`/`GetProcAddress`
/// gerekçesi (sabit bir `extern fn`, sınıfSIZ bir programda YA DA
/// `noxrt_test`te bağlama adımını ÇÖKERTİRDİ).
const WinSelf = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn GetModuleHandleA(name: ?[*:0]const u8) callconv(.c) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.c) ?*anyopaque;
} else struct {};

const ClassNameDispatchFn = fn (?*anyopaque, i64, ?*anyopaque) callconv(.c) [*:0]const u8;
threadlocal var g_class_name_dispatch_resolved = false;
threadlocal var g_class_name_dispatch_fn: ?*const ClassNameDispatchFn = null;

fn resolveClassNameDispatch() ?*const ClassNameDispatchFn {
    if (g_class_name_dispatch_resolved) return g_class_name_dispatch_fn;
    g_class_name_dispatch_resolved = true;
    const name = "nox_class_name_dispatch";
    if (builtin.os.tag == .windows) {
        const module = WinSelf.GetModuleHandleA(null) orelse return null;
        const sym = WinSelf.GetProcAddress(module, name) orelse return null;
        g_class_name_dispatch_fn = @ptrCast(@alignCast(sym));
        return g_class_name_dispatch_fn;
    }
    const handle = std.c.dlopen(null, .{ .NOW = true }) orelse return null;
    const sym = std.c.dlsym(handle, name) orelse return null;
    g_class_name_dispatch_fn = @ptrCast(@alignCast(sym));
    return g_class_name_dispatch_fn;
}

/// `main`'in kendi gövdesinden hiçbir `except` tarafından yakalanmamış bir
/// istisna sızarsa çağrılır (codegen bunu yalnızca `main` bağlamında,
/// `current_catch_label` boşken kullanır — bkz. codegen_qbe/codegen.zig).
/// Python'daki yakalanmamış istisna davranışına benzer şekilde: bir hata
/// mesajı basar ve sıfırdan farklı bir çıkış koduyla sonlanır — sessizce
/// başarıyla bitmiş gibi davranmaz.
///
/// Faz OO.3: ARTIK istisnanın ÇALIŞMA ZAMANI sınıf ADINI (`$nox_class_
/// name_dispatch` ÜZERİNDEN, tag `p`nin İLK `TAG_SIZE` baytından OKUNUR
/// — `genClassReleaseDispatch`in AYNI konvansiyonu) VE `raise` SATIRINI
/// (`state.pending_exception_line`) da RAPORLAR. `.message` alanı (bkz.
/// `Exception` taban sınıfı, `stdlib/nox/core.nox`) HENÜZ BURADA
/// OKUNMUYOR — o BİR SONRAKİ adımda (core.nox migrasyonu TAMAMLANDIKTAN
/// SONRA, TÜM `raise` EDİLEBİLİR sınıfların `message: str` alanını AYNI
/// SABİT OFSETTE taşıdığı GARANTİ edildiğinde) EKLENECEK.
export fn nox_unhandled_exception(rt: ?*anyopaque) noreturn {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse {
        std.debug.print("nox: yakalanmamış istisna — program sonlandırılıyor\n", .{});
        std.process.exit(1);
    }));
    const pe = pendingException(state);
    const line = pe.line.*;
    var class_name: [*:0]const u8 = "bilinmeyen sinif";
    if (pe.obj.*) |obj| {
        const tag: *const i64 = @ptrCast(@alignCast(obj));
        if (resolveClassNameDispatch()) |f| {
            class_name = f(rt, tag.*, obj);
        }
    }
    std.debug.print("nox: yakalanmamış istisna: {s} (satır {d}) — program sonlandırılıyor\n", .{ class_name, line });
    std.process.exit(1);
}

test "raise sonrası pending true olur, take alır ve temizler" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    try std.testing.expectEqual(@as(i32, 0), nox_exception_pending(rt));

    var dummy: u8 = 0;
    nox_raise(rt, &dummy, 42);
    try std.testing.expectEqual(@as(i32, 1), nox_exception_pending(rt));
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt));
    try std.testing.expectEqual(@as(i64, 42), pendingException(state).line.*);

    const taken = nox_exception_take(rt);
    try std.testing.expectEqual(@as(?*anyopaque, &dummy), taken);
    try std.testing.expectEqual(@as(i32, 0), nox_exception_pending(rt));
}
