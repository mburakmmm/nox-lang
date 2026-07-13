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
const asap = @import("../alloc/asap.zig");

/// `obj`'yi (bir Nox sınıf örneği işaretçisini) bekleyen istisna olarak işaretler.
export fn nox_raise(rt: ?*anyopaque, obj: ?*anyopaque) void {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return));
    state.pending_exception = obj;
}

/// Şu an bekleyen bir istisna olup olmadığını bildirir (0/1 — QBE `w` ile
/// çağrılır; ABI belirsizliğinden kaçınmak için `bool` yerine `i32` kullanılır).
export fn nox_exception_pending(rt: ?*anyopaque) i32 {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return 0));
    return if (state.pending_exception != null) 1 else 0;
}

/// Bekleyen istisnayı döndürür ve durumu temizler (bir `except` onu yakaladığında
/// ya da yeniden fırlatmadan önce çağrılır).
export fn nox_exception_take(rt: ?*anyopaque) ?*anyopaque {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    const obj = state.pending_exception;
    state.pending_exception = null;
    return obj;
}

/// `main`'in kendi gövdesinden hiçbir `except` tarafından yakalanmamış bir
/// istisna sızarsa çağrılır (codegen bunu yalnızca `main` bağlamında,
/// `current_catch_label` boşken kullanır — bkz. codegen_qbe/codegen.zig).
/// Python'daki yakalanmamış istisna davranışına benzer şekilde: bir hata
/// mesajı basar ve sıfırdan farklı bir çıkış koduyla sonlanır — sessizce
/// başarıyla bitmiş gibi davranmaz.
export fn nox_unhandled_exception(rt: ?*anyopaque) noreturn {
    _ = rt;
    std.debug.print("nox: yakalanmamış istisna — program sonlandırılıyor\n", .{});
    std.process.exit(1);
}

test "raise sonrası pending true olur, take alır ve temizler" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    try std.testing.expectEqual(@as(i32, 0), nox_exception_pending(rt));

    var dummy: u8 = 0;
    nox_raise(rt, &dummy);
    try std.testing.expectEqual(@as(i32, 1), nox_exception_pending(rt));

    const taken = nox_exception_take(rt);
    try std.testing.expectEqual(@as(?*anyopaque, &dummy), taken);
    try std.testing.expectEqual(@as(i32, 0), nox_exception_pending(rt));
}
