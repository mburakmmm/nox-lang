//! Nox Katman 4 (`lowlevel`) çalışma zamanı — AGENTS.md §8.
//!
//! `lowlevel` bloğu yalnızca tahsis STRATEJİSİNİ gevşetir (İlke #2): bu blok
//! içinde inşa edilen `list[T]`/sınıf örnekleri, Katman 1/2'nin refcount'lu
//! `nox_rc_alloc`/`nox_rc_retain`/`nox_rc_release`'i yerine burada bir arena
//! üzerinden tahsis edilir ve arena bloktan çıkışta TEK SEFERDE (tek bir
//! `nox_arena_destroy` ile) serbest bırakılır — hiçbir bireysel retain/release
//! gerekmez (bkz. compiler/codegen_qbe/codegen.zig, `arena_stack`).
//!
//! Zig'in `std.heap.ArenaAllocator`'ı üzerine ince bir sarmalayıcıdır; arka
//! (child) allocator olarak çalışma zamanı bağlamının (`rt`) kendi
//! `DebugAllocator`'ını kullanır — bu yüzden `nox_arena_destroy` hiç
//! çağrılmazsa (derleyicinin bir hatası olurdu) bu, normal sızıntı
//! denetimiyle (bkz. `asap.zig`) yakalanır.
//!
//! **Dil stabilizasyonu fazı §M.7 — tutamaç havuzlaması (ARC havuzuyla AYNI
//! prensip, bkz. `arc.zig`nin modül üstü notu):** `lowlevel_arena` benchmark'ı
//! (performans fazı, §3.25) DÖNGÜ İÇİNDE her `lowlevel` blok girişi/çıkışının
//! HEM `ArenaHandle` struct'ının KENDİSİNİ HEM arenanın kendi (child
//! allocator'a giden) İLK arabellek parçasını tazeden tahsis edip TAMAMEN
//! serbest bıraktığını, bu yüzden diğer benchmark'ların 20-30x'e ulaştığı
//! yerde 9.9x'te SABİT kaldığını gösterdi. **Düzeltme:** Release modlarında
//! (`use_pool`, ARC havuzuyla AYNI `builtin.mode != .Debug` koşulu — Debug'da
//! `DebugAllocator`ın TAM güvenlik ağı KORUNUR) `nox_arena_destroy`,
//! `handle.arena.deinit()` YERİNE `handle.arena.reset(.retain_capacity)`
//! çağırır (Zig'in KENDİ `ArenaAllocator.reset`i — arabelleği SERBEST
//! BIRAKMAZ, yalnızca "bump" işaretçisini BAŞA sarar) VE `handle`in KENDİSİNİ
//! (yok etmek YERİNE) `state.arena_pool`a (basit tek-boyutlu bir LIFO
//! serbest liste — ARC'ın `pool_free_lists`inin AKSİNE TEK sınıf YETERLİ,
//! `ArenaHandle` HER ZAMAN AYNI boyutta) GERİ KOYAR; `nox_arena_create` bu
//! havuzdan ÖNCE ÇEKMEYİ DENER, YALNIZCA boşsa taze tahsis eder.

const std = @import("std");
const builtin = @import("builtin");
const asap = @import("asap.zig");

const use_pool = builtin.mode != .Debug;

const ArenaHandle = struct {
    arena: std.heap.ArenaAllocator,
    /// Yalnızca HAVUZDA (arena aktif KULLANILMIYORKEN) anlamlı — bkz. modül
    /// üstü not.
    next: ?*ArenaHandle = null,
};

/// Yeni bir arena oluşturur (varsa havuzdan geri dönüştürülür). Başarısızlıkta
/// `null` döner.
export fn nox_arena_create(rt: ?*anyopaque) ?*anyopaque {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    if (use_pool) {
        if (state.arena_pool) |raw| {
            const handle: *ArenaHandle = @ptrCast(@alignCast(raw));
            state.arena_pool = @ptrCast(handle.next);
            handle.next = null;
            return @ptrCast(handle);
        }
    }
    const handle = state.allocator().create(ArenaHandle) catch return null;
    handle.* = .{ .arena = std.heap.ArenaAllocator.init(state.allocator()) };
    return @ptrCast(handle);
}

/// Arenadan `size` bayt tahsis eder. Başarısızlıkta `null` döner. Bireysel
/// olarak serbest bırakılmaz — yalnızca `nox_arena_destroy` ile toplu olarak.
export fn nox_arena_alloc(arena_ptr: ?*anyopaque, size: usize) ?*anyopaque {
    const handle: *ArenaHandle = @ptrCast(@alignCast(arena_ptr orelse return null));
    const mem = handle.arena.allocator().alloc(u8, size) catch return null;
    return mem.ptr;
}

/// Arenanın tahsis ettiği HER ŞEYİ tek seferde serbest bırakır (Release
/// modlarında GERÇEKTEN serbest BIRAKMAZ — bkz. modül üstü not, `reset`
/// edip havuza GERİ koyar) ve arenanın kendisini (mantıksal olarak) yok eder.
export fn nox_arena_destroy(rt: ?*anyopaque, arena_ptr: ?*anyopaque) void {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return));
    const handle: *ArenaHandle = @ptrCast(@alignCast(arena_ptr orelse return));
    if (use_pool) {
        _ = handle.arena.reset(.retain_capacity);
        handle.next = @ptrCast(@alignCast(state.arena_pool));
        state.arena_pool = @ptrCast(handle);
        return;
    }
    handle.arena.deinit();
    state.allocator().destroy(handle);
}

test "arena tahsisi yazılabilir/okunabilir; destroy sonrası sızıntı yok" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const arena = nox_arena_create(rt) orelse return error.ArenaCreateFailed;
    const a = nox_arena_alloc(arena, 16) orelse return error.AllocFailed;
    const b = nox_arena_alloc(arena, 32) orelse return error.AllocFailed;
    const a_bytes: [*]u8 = @ptrCast(a);
    const b_bytes: [*]u8 = @ptrCast(b);
    a_bytes[0] = 1;
    b_bytes[0] = 2;
    try std.testing.expectEqual(@as(u8, 1), a_bytes[0]);
    try std.testing.expectEqual(@as(u8, 2), b_bytes[0]);

    nox_arena_destroy(rt, arena);
}
