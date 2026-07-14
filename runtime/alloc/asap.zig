//! Nox Katman 1 (ASAP) çalışma zamanı ayırıcısı — AGENTS.md §8.
//!
//! İlke #6 (Değişmez): "Global/gizli mutable state yasak. Runtime,
//! allocator'ları her zaman açıkça parametre olarak alır." Derlenmiş bir Nox
//! programı, `nox_runtime_init` ile başlangıçta oluşturulan opak bir bağlamı
//! (`rt`) her fonksiyon çağrısına AÇIKÇA taşır (bkz. compiler/codegen_qbe).
//! Bu bir "gizli global" değildir — QBE IR'da her çağrıda görünür bir
//! parametre olarak geçirilir; runtime'ın kendisi hiçbir statik/global
//! değişken tutmaz.
//!
//! v0.1 kapsamı: yalnızca Katman 1 (ASAP) — tahsis + doğrudan serbest bırakma.
//! Katman 2 (ARC retain/release) ve Katman 3 (döngü çözücü) sonraki bir fazda
//! eklenecektir (bkz. nox-teknik-spesifikasyon.md §3.5).
//!
//! **Backing allocator, build moduna göre KOŞULLU (bkz. Faz 16 — benchmark
//! suite'e Python karşılaştırması eklenirken bulundu):** Debug modunda
//! `std.heap.DebugAllocator` kullanılır (sızıntı tespiti + `zig build test`in
//! dayandığı güvenlik ağı — bkz. tests/golden, 4 gerçek hata bu sayede
//! yakalanmıştı). Ama `DebugAllocator`, `safety` bayrağından BAĞIMSIZ olarak,
//! yüksek hacimli tahsis/serbest-bırakma döngülerinde (ör. bir döngüde
//! tekrar tekrar `list[T]` inşa etmek) `mmap`/`munmap` ağırlıklı, TAMAMEN
//! yapay bir yavaşlığa yol açıyor — ölçüldü: 5 milyon liste tahsisi/serbest
//! bırakması DebugAllocator ile ~12s (çoğu system time), Zig'in üretim
//! kalitesindeki `std.heap.smp_allocator`ıyla ~0.1s. Bu, gerçek dil/codegen
//! performansını YANSITMAYAN, salt ayırıcı seçimine ait bir farktır. Bu
//! yüzden Release modlarında (`ReleaseFast`/`ReleaseSafe`/`ReleaseSmall`)
//! `smp_allocator`a geçilir — sızıntı tespiti o modlarda YAPILMAZ (hız
//! ölçümü/karşılaştırma içindir; doğruluk/sızıntı güvenliği Debug modundaki
//! `zig build test`in kendisiyle zaten sürekli doğrulanır).

const std = @import("std");
const builtin = @import("builtin");

const use_debug_allocator = builtin.mode == .Debug;

/// Faz S.3: `runtime/alloc/cycle_detector.zig`de TANIMLI/`export`lu —
/// `asap.zig`nin O dosyayı IMPORT ETMEDEN (döngüsel bağımlılık kurmadan)
/// çağırabilmesi İÇİN düz bir `extern fn` bildirimi (bkz. `cycle_gc`in
/// belge notu). Her ikisi de `runtime/lib.zig` aracılığıyla AYNI `noxrt`
/// nesnesine derlendiğinden, LİNKER bu referansı normal şekilde çözer.
extern fn nox_cycle_deinit(rt: ?*anyopaque) callconv(.c) void;
/// AYNI gerekçe — `nox_runtime_deinit`, PROGRAM SONUNDA HENÜZ tahsis-baskısı
/// eşiğini AŞMAMIŞ (bkz. `nox_cycle_possible_root`in belge notu) "olası
/// kök" durumundaki döngüleri KAÇIRMAMAK için `nox_cycle_deinit`DEN ÖNCE
/// SON bir kez `nox_cycle_collect` çağırır — aksi halde KÜÇÜK, kısa ömürlü
/// programlardaki (ör. testler) döngüler eşiğe HİÇ ULAŞMADAN sessizce
/// sızardı.
extern fn nox_cycle_collect(rt: ?*anyopaque) callconv(.c) void;

/// ARC nesneleri (bkz. `runtime/alloc/arc.zig`) için sabit büyüklük-sınıflı
/// serbest liste havuzunun sınıf sayısı — performans fazında (benchmark
/// darboğaz denetimi, `oop_arc_churn`in profillenmesiyle bulundu: örneklerin
/// ~%45'i `smp_allocator`ın kendi tahsis/serbest bırakma overhead'indeydi)
/// eklendi. Havuz yalnızca `arc.zig`'in kendi `use_pool` sabitiyle Release
/// modlarında AKTİFTİR — bu alanlar Debug modunda da (basitlik için KOŞULSUZ
/// tip) var olsa da hiç DOKUNULMAZ: her tahsis/serbest bırakma DOĞRUDAN
/// `DebugAllocator`a gider, tam güvenlik ağı (bkz. modül üstü not) KORUNUR.
pub const POOL_NUM_CLASSES = 10;
pub const PoolNode = struct { next: ?*PoolNode };

pub const RuntimeState = struct {
    debug_gpa: if (use_debug_allocator) std.heap.DebugAllocator(.{}) else void,
    pending_exception: ?*anyopaque = null,
    pool_free_lists: [POOL_NUM_CLASSES]?*PoolNode = @splat(null),
    /// Dil stabilizasyonu fazı §M.7: `lowlevel` arena TUTAMAÇLARININ (bkz.
    /// `runtime/alloc/lowlevel.zig`, `ArenaHandle`) LIFO serbest liste BAŞI
    /// — `pool_free_lists`in AYNI Release-only prensibi (`lowlevel.zig`nin
    /// KENDİ `use_pool`u), ama TEK bir boyut sınıfı YETERLİ olduğundan
    /// (`ArenaHandle` HER ZAMAN AYNI boyutta) `pool_free_lists`in çok-
    /// sınıflı dizisi YERİNE tek bir OPAK işaretçi — `lowlevel.zig`
    /// `ArenaHandle`nin KENDİSİNE `next: ?*ArenaHandle` alanı ekleyip BU
    /// alanı `@ptrCast` ile güçlü tipe çevirir (asap.zig↔lowlevel.zig
    /// arasında DAİRESEL import GEREKMEZ, tıpkı `PoolNode`nin arc.zig
    /// tarafından KULLANILMASI gibi).
    arena_pool: ?*anyopaque = null,
    /// Faz S.3 (Katman 3, döngü çözücü) — `runtime/alloc/cycle_detector.zig`nin
    /// KENDİ `CycleGc` durumuna opak bir işaretçi (tembel/lazy oluşturulur,
    /// bkz. onun `getGc`si). `arena_pool` İLE AYNI gerekçeyle opak: `asap.zig`
    /// `cycle_detector.zig`yi IMPORT ETMEDEN (döngüsel bağımlılık kurmadan)
    /// bu alanı taşıyabilir — gerçek serbest bırakma `nox_cycle_deinit`e
    /// (aşağıdaki `extern fn` bildirimi, DÜZ bağlama — bkz. `runtime/lib.zig`nin
    /// İKİSİNİ de AYNI `noxrt` nesnesine derlediği) DELEGE edilir.
    cycle_gc: ?*anyopaque = null,

    pub fn allocator(self: *RuntimeState) std.mem.Allocator {
        if (use_debug_allocator) return self.debug_gpa.allocator();
        return std.heap.smp_allocator;
    }
};

/// Yeni bir çalışma zamanı bağlamı oluşturur. Başarısızlıkta `null` döner.
pub export fn nox_runtime_init() ?*anyopaque {
    const state = std.heap.page_allocator.create(RuntimeState) catch return null;
    state.* = .{ .debug_gpa = if (use_debug_allocator) .init else {} };
    return @ptrCast(state);
}

/// Çalışma zamanı bağlamını kapatır. Debug modunda `DebugAllocator` bir
/// sızıntı tespit ederse (AGENTS.md §13'ün "leak testi ... yeşil"
/// gereksinimi doğrultusunda) bunu stderr'e açıkça bildirir — programın
/// çıkış kodunu değiştirmez, ama golden testler bu çıktıyı gözlemleyebilir.
/// Release modlarında (bkz. modül üstü not) sızıntı tespiti yapılmaz.
pub export fn nox_runtime_deinit(rt: ?*anyopaque) void {
    const state: *RuntimeState = @ptrCast(@alignCast(rt orelse return));
    // Faz S.3: SON bir kez döngü topla (bkz. `nox_cycle_collect`in belge
    // notu, eşiğe ulaşmamış kısa ömürlü programlar İÇİN), SONRA döngü
    // çözücünün KENDİ yan tablosunu (bkz. `cycle_gc`in belge notu) yok et —
    // o da AYNI `state.allocator()`ı kullanır, `debug_gpa.deinit()`DEN
    // ÖNCE yapılmalı (aksi halde deinit SONRASI bir kullanım-sonrası-
    // serbest-bırakma yazımı olurdu).
    nox_cycle_collect(rt);
    nox_cycle_deinit(rt);
    if (use_debug_allocator) {
        if (state.debug_gpa.deinit() == .leak) {
            std.debug.print("nox runtime: bellek sızıntısı tespit edildi\n", .{});
        }
    }
    std.heap.page_allocator.destroy(state);
}

/// `size` bayt tahsis eder. Başarısızlıkta `null` döner.
pub export fn nox_alloc(rt: ?*anyopaque, size: usize) ?*anyopaque {
    const state: *RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    const mem = state.allocator().alloc(u8, size) catch return null;
    return mem.ptr;
}

/// Daha önce `nox_alloc(rt, size)` ile tahsis edilmiş belleği serbest bırakır.
/// `size`, tahsis anındaki ile birebir aynı olmalıdır (Zig allocator sözleşmesi).
pub export fn nox_free(rt: ?*anyopaque, ptr: ?*anyopaque, size: usize) void {
    const p = ptr orelse return;
    const state: *RuntimeState = @ptrCast(@alignCast(rt orelse return));
    const bytes: [*]u8 = @ptrCast(p);
    state.allocator().free(bytes[0..size]);
}

test "tahsis edilen bellek yazılabilir/okunabilir ve serbest bırakılabilir" {
    const rt = nox_runtime_init() orelse return error.InitFailed;
    defer nox_runtime_deinit(rt);

    const ptr = nox_alloc(rt, 16) orelse return error.AllocFailed;
    const bytes: [*]u8 = @ptrCast(ptr);
    bytes[0] = 42;
    try std.testing.expectEqual(@as(u8, 42), bytes[0]);
    nox_free(rt, ptr, 16);
}

test "nox_free(null) güvenli bir hiçbir şey yapmama işlemidir" {
    const rt = nox_runtime_init() orelse return error.InitFailed;
    defer nox_runtime_deinit(rt);
    nox_free(rt, null, 0);
}
