//! Go-tarzı `defer` deyiminin ÇALIŞMA ZAMANI tarafı (bkz. nox-teknik-
//! spesifikasyon.md'nin yeni Faz bölümü, VE `compiler/codegen_qbe/
//! codegen.zig`nin `genDeferStmt`i). Bir fonksiyonun (yalnızca KENDİ
//! gövdesinde `defer` İÇEREN fonksiyonlar İçin) bekleyen ertelenmiş çağrı
//! LİSTESİDİR — bir DÖNGÜ İÇİNDE `defer` de dahil (bekleyen çağrı SAYISI
//! ÇALIŞMA ZAMANINDA değişebilir), bu YÜZDEN `finally_stack`/`arena_stack`
//! (derleyicinin KENDİ, TAMAMEN statik Zig `ArrayList`leri) GİBİ derleme-
//! zamanı bir mekanizma İLE karşılanamaz — BURADAKİ liste GERÇEKTEN
//! çalışma zamanında (bu genel amaçlı allocator ÜZERİNDEN) BÜYÜR.
//!
//! **ARC-DIŞI:** bu `DeferStack`in KENDİSİ bir KULLANICI-görünür Nox
//! değeri DEĞİLDİR (`nox_rc_alloc`/refcount başlığı YOK) — `asap.nox_alloc`/
//! `nox_free` (arc.zig'in HAVUZ mekanizmasının ALTINDAKİ AYNI genel
//! allocator) ÜZERİNDEN düz bir çalışma-zamanı yapısı olarak yönetilir.
//!
//! **Ertelenmiş ÇAĞRI mekanizması:** `push`e verilen `closure_ptr`,
//! `codegen.zig`nin `genNestedFuncDef`/`buildClosureValue`sinin İNŞA ETTİĞİ
//! AYNI closure BLOĞUDUR (`{fn_ptr: l @0, release_fn_ptr: l @8, yakalanan
//! değerler @16+}` — bkz. onun belge notu). QBE'nin ürettiği fonksiyonlar
//! standart C ABI'sine UYDUĞUNDAN (Zig↔QBE köprüsünün TAMAMI ZATEN buna
//! dayanır), `run_all`in bu İKİ alanı OKUYUP DOĞRUDAN `fn(?*anyopaque,
//! ?*anyopaque) callconv(.c) void` OLARAK cast edip ÇAĞIRMASI GEÇERLİDİR —
//! `fn_ptr` GERÇEK ertelenmiş çağrıyı yapar, `release_fn_ptr` (codegen'in
//! `genClosureRelease`sinin ÜRETTİĞİ `$<mangled>_release`) closure'ı VE
//! yakaladığı ARC değerlerini serbest bırakır.

const std = @import("std");
const asap = @import("asap.zig");

const PTR_SIZE: usize = @sizeOf(?*anyopaque);
const INITIAL_CAP: usize = 4;

/// Closure çağrı imzası — `genClosureFunc`nin ürettiği GERÇEK fonksiyonlarla
/// (gizli `%env` parametresi, RT_PARAM'dan HEMEN SONRA) VE `genClosureRelease`nin
/// ürettiği `$<mangled>_release(rt, p)` İLE AYNI: `(rt, closure_ptr) -> void`.
const ClosureFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;

pub const DeferStack = extern struct {
    items: ?[*]?*anyopaque = null,
    len: usize = 0,
    cap: usize = 0,
};

/// `genFunction`/`genMethod`/`genClosureFunc`nin girişinde (`fnBodyHasDefer`
/// `true` DÖNDÜĞÜNDE) ÇAĞRILIR — fonksiyon-başına TEK bir yığın.
export fn nox_defer_stack_new(rt: ?*anyopaque) callconv(.c) ?*anyopaque {
    const raw = asap.nox_alloc(rt, @sizeOf(DeferStack)) orelse return null;
    const stack: *DeferStack = @ptrCast(@alignCast(raw));
    stack.* = .{};
    return stack;
}

/// `genDeferStmt`in HER `defer CALL` sitesinde çağırdığı — `closure_ptr`yi
/// (o an İNŞA edilmiş, argümanları ZATEN yakalamış closure bloğu) yığının
/// SONUNA ekler (klasik ArrayList büyüme deseni: dolduğunda 2 katına çıkar).
export fn nox_defer_stack_push(rt: ?*anyopaque, stack_ptr: ?*anyopaque, closure_ptr: ?*anyopaque) callconv(.c) void {
    const stack: *DeferStack = @ptrCast(@alignCast(stack_ptr orelse return));
    if (stack.len == stack.cap) {
        const new_cap: usize = if (stack.cap == 0) INITIAL_CAP else stack.cap * 2;
        const new_raw = asap.nox_alloc(rt, new_cap * PTR_SIZE) orelse return;
        const new_items: [*]?*anyopaque = @ptrCast(@alignCast(new_raw));
        if (stack.items) |old| {
            @memcpy(new_items[0..stack.len], old[0..stack.len]);
            asap.nox_free(rt, @ptrCast(old), stack.cap * PTR_SIZE);
        }
        stack.items = new_items;
        stack.cap = new_cap;
    }
    stack.items.?[stack.len] = closure_ptr;
    stack.len += 1;
}

/// TÜM 5 fonksiyon-çıkış noktasında (bkz. `codegen.zig`nin `drainFinally`/
/// `drainArenas`den HEMEN SONRAKİ çağrı sitesi notu) ÇAĞRILIR — bekleyen
/// TÜM çağrıları LIFO SIRASIYLA (Go'nun AYNI semantiği) çalıştırıp yığının
/// KENDİSİNİ (VE İÇİNDEKİ `items` tamponunu) serbest bırakır. Her closure
/// İçin: ÖNCE GERÇEK ertelenmiş çağrı (`fn_ptr`), SONRA closure'ın KENDİSİNİ
/// (VE yakaladığı ARC değerlerini) serbest bırakan `release_fn_ptr`.
export fn nox_defer_stack_run_all(rt: ?*anyopaque, stack_ptr: ?*anyopaque) callconv(.c) void {
    const stack: *DeferStack = @ptrCast(@alignCast(stack_ptr orelse return));
    var i = stack.len;
    while (i > 0) {
        i -= 1;
        const closure = stack.items.?[i] orelse continue;
        const header: [*]?*anyopaque = @ptrCast(@alignCast(closure));
        const call_fn: ClosureFn = @ptrCast(@alignCast(header[0]));
        call_fn(rt, closure);
        const release_fn: ClosureFn = @ptrCast(@alignCast(header[1]));
        release_fn(rt, closure);
    }
    if (stack.items) |items| asap.nox_free(rt, @ptrCast(items), stack.cap * PTR_SIZE);
    asap.nox_free(rt, stack, @sizeOf(DeferStack));
}

test "defer_stack: push+run_all LIFO sırasıyla çağırır, yığını serbest bırakır" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const S = struct {
        var order: [3]i64 = undefined;
        var count: usize = 0;

        fn call1(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            order[count] = 1;
            count += 1;
        }
        fn call2(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            order[count] = 2;
            count += 1;
        }
        fn call3(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            order[count] = 3;
            count += 1;
        }
        fn freeSelf(r: ?*anyopaque, p: ?*anyopaque) callconv(.c) void {
            asap.nox_free(r, p, 2 * PTR_SIZE);
        }
    };

    // Her "closure" burada yalnızca {fn_ptr, release_fn_ptr} — gerçek
    // yakalama YOK (testin amacı SIRA/bellek yönetimi, capture DEĞİL).
    // `release_fn_ptr`, GERÇEK `genClosureRelease`nin ürettiği `$<mangled>_
    // release` GİBİ, closure'ın KENDİ bloğunu serbest bırakır — bu test
    // çiftinin (test double) bunu ATLAMASI (no-op) belleği SIZDIRIRDI.
    const mkClosure = struct {
        fn make(r: ?*anyopaque, call_fn: ClosureFn) *anyopaque {
            const raw = asap.nox_alloc(r, 2 * PTR_SIZE).?;
            const header: [*]?*anyopaque = @ptrCast(@alignCast(raw));
            header[0] = @constCast(@ptrCast(call_fn));
            header[1] = @constCast(@ptrCast(&S.freeSelf));
            return raw;
        }
    }.make;

    const stack = nox_defer_stack_new(rt).?;
    nox_defer_stack_push(rt, stack, mkClosure(rt, S.call1));
    nox_defer_stack_push(rt, stack, mkClosure(rt, S.call2));
    nox_defer_stack_push(rt, stack, mkClosure(rt, S.call3));
    nox_defer_stack_run_all(rt, stack);

    try std.testing.expectEqual(@as(usize, 3), S.count);
    try std.testing.expectEqualSlices(i64, &.{ 3, 2, 1 }, &S.order);
}

test "defer_stack: boş yığın run_all güvenle no-op'tur" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const stack = nox_defer_stack_new(rt).?;
    nox_defer_stack_run_all(rt, stack);
}

test "defer_stack: INITIAL_CAP'i AŞAN itme büyümeyi doğru test eder" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const S = struct {
        var count: usize = 0;
        fn call(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            count += 1;
        }
        fn freeSelf(r: ?*anyopaque, p: ?*anyopaque) callconv(.c) void {
            asap.nox_free(r, p, 2 * PTR_SIZE);
        }
    };

    const mkClosure = struct {
        fn make(r: ?*anyopaque) *anyopaque {
            const raw = asap.nox_alloc(r, 2 * PTR_SIZE).?;
            const header: [*]?*anyopaque = @ptrCast(@alignCast(raw));
            header[0] = @constCast(@ptrCast(&S.call));
            header[1] = @constCast(@ptrCast(&S.freeSelf));
            return raw;
        }
    }.make;

    const stack = nox_defer_stack_new(rt).?;
    var n: usize = 0;
    while (n < 10) : (n += 1) nox_defer_stack_push(rt, stack, mkClosure(rt));
    nox_defer_stack_run_all(rt, stack);

    try std.testing.expectEqual(@as(usize, 10), S.count);
}
