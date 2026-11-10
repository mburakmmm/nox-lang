//! Faz OO.2 (bkz. nox-teknik-spesifikasyon.md §3.83, `TaskLocal[T]`):
//! nyx'te farkedilen bir Nox eksikliği — task/fiber-local bağlam. `Channel[T]`
//! (bkz. `channel.zig`/`bridge.zig`) İLE AYNI felsefe: runtime TAMAMEN
//! opak, tip-farkında OLMAYAN bir 8-baytlık payload taşıyıcısıdır — HANGİ
//! değerin (int/str/sınıf/liste) taşındığı SADECE codegen tarafında (bkz.
//! `compiler/codegen_qbe/async_thread.zig`, `genTaskLocalOp`) bilinir,
//! `toPayload`/`fromPayload`in AYNI bit-yeniden-yorumlama deseniyle.
//!
//! **Depolama modeli:** `Channel`nin AKSİNE (bir kuyruk) `TaskLocal` TEK
//! bir "handle"tır (`nox_tasklocal_new`nin döndürdüğü OPAK işaretçi) —
//! GERÇEK değer BU handle'IN İÇİNDE DEĞİL, ÇAĞRILDIĞI ANDA çalışan
//! `Fiber`nin KENDİ `task_locals` haritasında (bkz. `fiber.zig`) SAKLANIR,
//! handle işaretçisiyle ANAHTARLANMIŞ olarak. Bu SAYEDE: (1) AYNI
//! `TaskLocal` örneği (ör. modül-seviyesi bir global) TÜM fiber'lar
//! arasında PAYLAŞILABİLİR ama HER fiber KENDİ değerini görür (asıl amaç
//! — nyx'in İSTEK-başına bağlamı), (2) BİRDEN FAZLA BAĞIMSIZ `TaskLocal`
//! örneği AYNI fiber'da (KENDİ AYRI handle anahtarlarıyla) ÇAKIŞMADAN
//! bir arada YAŞAYABİLİR.
//!
//! **ARC (Pulse NOX-TASKLOCAL-001):** `set`/`get`/`clear` hâlâ SAF bir "opak payload DEĞİŞTİR/OKU"
//! işlemidir — retain/release çağrı sitesinde (`genTaskLocalOp`) yapılır. `clear()` çağırmadan biten bir
//! fiber/görevin kalan değerleri ise `task_local_entry.drain` ile, `TaskLocal[T]()` kurulurken codegen'in
//! tutamağa yazdığı türe uygun bırakma işleviyle serbest bırakılır (bkz. o dosyanın üst notu).

const std = @import("std");
const asap = @import("../alloc/asap.zig");
const bridge = @import("bridge.zig");
const tl = @import("task_local_entry.zig");

fn allocatorFromRt(rt: ?*anyopaque) std.mem.Allocator {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt.?));
    return state.allocator();
}

/// `TaskLocal[T]()` — handle'IN KENDİSİ hiçbir durum TAŞIMAZ (yalnızca
/// `task_locals` haritalarında bir anahtar olarak kullanılacak BENZERSİZ
/// bir kimlik/adres GEREKİR) — tek baytlık bir "işaretçi" yeterlidir.
export fn nox_tasklocal_new(rt: ?*anyopaque, release: ?tl.ReleaseFn) callconv(.c) ?*anyopaque {
    const allocator = allocatorFromRt(rt);
    const handle = allocator.create(tl.Handle) catch @panic("OOM: TaskLocal");
    handle.* = .{ .rt = rt, .release = release };
    return handle;
}

export fn nox_tasklocal_destroy(rt: ?*anyopaque, handle: ?*anyopaque) callconv(.c) void {
    const allocator = allocatorFromRt(rt);
    const h: *tl.Handle = @ptrCast(@alignCast(handle orelse return));
    allocator.destroy(h);
}

/// Şu an çalışan fiber'ın BU handle İçİn sakladığı değeri ÖDÜNÇ olarak
/// okur (`nox_dict_get`nin AYNI "ödünç okuma, atama SİTESİNDE retain"
/// KONVANSİYONU — codegen SORUMLUDUR). Fiber DIŞINDA (senkron üst-düzey
/// kod) ÇAĞRILIRSA ya da handle İçİn HİÇ değer AYARLANMAMIŞSA `null`
/// döner (Nox tarafında `None`e karşılık gelir).
export fn nox_tasklocal_get(rt: ?*anyopaque, handle: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = rt;
    const h = handle orelse return null;
    const locals = bridge.currentTaskLocals() orelse return null;
    return if (locals.get(h)) |e| e.value else null;
}

/// Şu an çalışan fiber'ın BU handle İçİn sakladığı değeri YENİ değerle
/// DEĞİŞTİRİR (exchange) VE ESKİ değeri döner — codegen (statik olarak
/// `elem_heap_info`yi BİLDİĞİNDEN) dönen eski değeri KENDİ standart
/// serbest-bırakma mekanizmasıyla serbest BIRAKIR (`Channel.send`in
/// AKSİNE burada bir "eski değer" KAVRAMI VARDIR, bu YÜZDEN bu EXTRA
/// dönüş değeri GEREKİR). `new_value`nin RETAIN'İ (gerekiyorsa) ÇAĞRI
/// SİTESİNDE, bu fonksiyon ÇAĞRILMADAN ÖNCE codegen tarafından YAPILMIŞ
/// olmalıdır. Fiber DIŞINDA ÇAĞRILIRSA (nadiren, senkron üst-düzey kod)
/// SESSİZCE hiçbir şey YAPMAZ VE `null` döner (codegen'in `new_value`yi
/// ZATEN retain ETMİŞ olması durumunda BİR sızıntı — bilinçli, NADİR bir
/// v1 kenar durumu: `TaskLocal.set` normal kullanımda HER ZAMAN bir
/// fiber İÇİNDE çağrılır).
export fn nox_tasklocal_set(rt: ?*anyopaque, handle: ?*anyopaque, new_value: ?*anyopaque) callconv(.c) ?*anyopaque {
    const h = handle orelse return null;
    const locals = bridge.currentTaskLocals() orelse return null;
    const allocator = allocatorFromRt(rt);
    const th: *tl.Handle = @ptrCast(@alignCast(h));
    const old = if (locals.get(h)) |e| e.value else null;
    locals.put(allocator, h, .{ .value = new_value, .rt = th.rt, .release = th.release }) catch @panic("OOM: TaskLocal.set");
    return old;
}

/// `nox_tasklocal_set(rt, handle, null)` İLE AYNI — ESKİ değeri döner
/// (codegen serbest BIRAKIR), haritadan girdiyi TAMAMEN KALDIRIR (bkz.
/// `get`nin "hiç ayarlanmamış" durumuyla TUTARLI kalması İçİn).
export fn nox_tasklocal_clear(rt: ?*anyopaque, handle: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = rt;
    const h = handle orelse return null;
    const locals = bridge.currentTaskLocals() orelse return null;
    if (locals.fetchRemove(h)) |kv| return kv.value.value;
    return null;
}
