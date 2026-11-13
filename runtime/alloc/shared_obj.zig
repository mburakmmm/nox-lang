//! Faz 9.0 F1 (v2.1.130): paylaşılan nesne ilkelleri — bkz. `project/faz9-kontrol-debug-analizi-2026-11.md` D.3 (tip-yönlendirmeli dinamik paylaşım).
//!
//! Her ARC yığın nesnesinin başlık sözcüğünde (`payload - 8`) iki bit: `SHARED` (nesne ≥ 2 görevden erişilebilir; yayımlama ile yapışkan olarak kurulur) ve `LOCK` (nesne başına döndürme kilidi).
//! Refcount artır/azalt (`fetchAdd/fetchSub`) aynı sözcüğü atomik değiştirdiğinden kilit bitleri refcount işlemleriyle çakışmaz. Kilit YALNIZ kısa, kullanıcı kodu çağırmayan bölümler içindir
//! (alan/eleman okuma-retain, yazma-değiştirme): kilit altında asla yeniden giriş ya da askıya alma olmaz → kilitlenme yok.

const std = @import("std");
const builtin = @import("builtin");
const abi_layout = @import("abi_layout");
const atomic64 = @import("../async_rt/atomic_compat.zig");

const SHARED: u64 = abi_layout.HDR_SHARED_BIT;
const LOCK: u64 = abi_layout.HDR_LOCK_BIT;
const ARC_HEADER_SIZE = abi_layout.ARC_HEADER_SIZE;
const wasm_hdr = builtin.cpu.arch.isWasm();

fn hdrWord(p: *anyopaque) *u64 {
    const bytes: [*]u8 = @ptrCast(p);
    return @ptrCast(@alignCast(bytes - ARC_HEADER_SIZE));
}

fn orBits(h: *u64, m: u64) u64 {
    return if (comptime wasm_hdr) atomic64.rmw(u64, .@"or", h, m) else @atomicRmw(u64, h, .Or, m, .acq_rel);
}

fn andBits(h: *u64, m: u64) u64 {
    return if (comptime wasm_hdr) atomic64.rmw(u64, .@"and", h, m) else @atomicRmw(u64, h, .And, m, .release);
}

fn loadWord(h: *u64) u64 {
    return if (comptime wasm_hdr) atomic64.load(u64, h) else @atomicLoad(u64, h, .acquire);
}

/// Nesne yayımlandı mı? (sıcak yol: tek yükleme)
pub inline fn isShared(p: *anyopaque) bool {
    return loadWord(hdrWord(p)) & SHARED != 0;
}

/// `SHARED` bitini kurar; bu çağrı bitin ilk kurulması ise `true` (çağıran grafiği gezip çocukları da yayımlamalıdır).
pub fn setShared(p: *anyopaque) bool {
    return orBits(hdrWord(p), SHARED) & SHARED == 0;
}

/// Nesne kilidini alır (döndürme + üstel geri çekilme; uzun çekişmede CPU'yu bırakır).
pub fn lock(p: *anyopaque) void {
    const h = hdrWord(p);
    var backoff: u32 = 4;
    var rounds: u32 = 0;
    while (orBits(h, LOCK) & LOCK != 0) {
        var i: u32 = 0;
        while (i < backoff) : (i += 1) std.atomic.spinLoopHint();
        if (backoff < 512) backoff *= 2;
        rounds += 1;
        if (rounds > 64) {
            if (comptime builtin.os.tag != .freestanding) @import("../async_rt/thread_spawn.zig").yield();
            rounds = 32;
        }
    }
}

pub fn unlock(p: *anyopaque) void {
    _ = andBits(hdrWord(p), ~LOCK);
}

// ---- C ABI (codegen yavaş yolları) --------------------------------------------------------------------------------------------------------------------------

pub export fn nox_obj_is_shared(p: ?*anyopaque) callconv(.c) i32 {
    const q = p orelse return 0;
    return if (isShared(q)) 1 else 0;
}

pub export fn nox_obj_lock(p: ?*anyopaque) callconv(.c) void {
    if (p) |q| lock(q);
}

pub export fn nox_obj_unlock(p: ?*anyopaque) callconv(.c) void {
    if (p) |q| unlock(q);
}

// ---- Birim testleri -----------------------------------------------------------------------------------------------------------------------------------------

const arc = @import("arc.zig");
const asap = @import("asap.zig");

test "shared_obj: SHARED yapışkan ve tek kez 'ilk' döner; refcount bitleri bozulmaz" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    const p = arc.nox_rc_alloc(rt, 32) orelse return error.AllocFailed;
    try std.testing.expect(!isShared(p));
    try std.testing.expect(setShared(p));
    try std.testing.expect(isShared(p));
    try std.testing.expect(!setShared(p));
    arc.nox_rc_retain(p);
    try std.testing.expect(isShared(p));
    try std.testing.expectEqual(@as(i32, 0), arc.nox_rc_predecrement(p)); // rc 2 → 1: hâlâ canlı, bayrak kalır
    try std.testing.expect(isShared(p));
    try std.testing.expectEqual(@as(i32, 1), arc.nox_rc_predecrement(p)); // rc 1 → 0 (yüksek bitler sıfır testini bozmaz)
    arc.nox_rc_free_payload(rt, p, 32);
}

const Hammer = struct {
    p: *anyopaque,
    counter: u64 = 0,
    rounds: usize,

    fn worker(self: *Hammer) void {
        var i: usize = 0;
        while (i < self.rounds) : (i += 1) {
            lock(self.p);
            self.counter += 1; // kilit altında atomik olmayan artış
            unlock(self.p);
            arc.nox_rc_retain(self.p); // aynı sözcükte eşzamanlı refcount trafiği
            _ = arc.nox_rc_predecrement(self.p);
        }
    }
};

test "shared_obj: nesne kilidi 4 iş parçacığında karşılıklı dışlama sağlar (refcount trafiğiyle birlikte)" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    const p = arc.nox_rc_alloc(rt, 32) orelse return error.AllocFailed;
    _ = setShared(p);
    var h: Hammer = .{ .p = p, .rounds = 20000 };
    var ts: [4]std.Thread = undefined;
    for (&ts) |*t| t.* = try std.Thread.spawn(.{}, Hammer.worker, .{&h});
    for (ts) |t| t.join();
    try std.testing.expectEqual(@as(u64, 4 * 20000), h.counter);
    try std.testing.expectEqual(@as(i32, 1), arc.nox_rc_predecrement(p));
    arc.nox_rc_free_payload(rt, p, 32);
}
