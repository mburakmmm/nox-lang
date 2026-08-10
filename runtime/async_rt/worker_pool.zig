//! Faz MN.3b (bkz. proje planı "LLVM-only atomic ARC + tam work-stealing
//! M:N fiber zamanlayıcı") — `Worker`/`WorkerPool`: N OS iş parçacığının
//! TEK bir PAYLAŞILAN `RuntimeState`yi güvenle kurabilmesi İçİn BAĞIMSIZ,
//! sıfır entegrasyonlu bir birim (MN.3a'nın Chase-Lev deque'inin AYNI
//! "standalone, birim-test edilebilir" disiplini). **Nox kaynağına/
//! codegen'e HİÇ dokunmaz** — bir Nox programından (`nox.thread`/
//! `nox.http.serve_multicore`) BUNA bağlanmak AÇIKÇA Faz MN.7'nin
//! kapsamıdır.
//!
//! **BUGÜNKÜ paylaşımsız model** (`nox.thread.start`/`serve_multicore`
//! — bkz. `runtime/async_rt/thread_bridge.zig`nin `childThreadMain`ı):
//! HER worker KENDİ `nox_runtime_init()`ini çağırır, N OS iş parçacığı =
//! N BAĞIMSIZ `RuntimeState`. `WorkerPool.create`, BUNUN YERİNE TEK bir
//! `RuntimeState` KURAR — `spawnWorkers` TARAFINDAN başlatılan HER
//! worker'ın (VE ÇAĞIRAN iş parçacığının, slot 0) `nox_async_init`i
//! (BUGÜNKÜ gibi) KENDİ BAĞIMSIZ `Scheduler`ını (`threadlocal g_scheduler`,
//! `bridge.zig`) KURMAYA DEVAM ETMESİ BEKLENİR — `Scheduler`in `RuntimeState`
//! FARKINDALIĞI ZATEN SIFIR olduğundan (bkz. proje planının araştırma
//! bölümü) BU, DEĞİŞMEYEN bir davranıştır; DEĞİŞEN TEK ŞEY N worker'ın
//! ARTIK `rt`yi PAYLAŞMASIDIR.
//!
//! **Senkronizasyon:** `RuntimeState`nin `pool_free_lists`/`arena_pool`/
//! `cycle_gc`si (bkz. `asap.zig`) Faz MN.3b'DEN İTİBAREN KENDİ `SpinLock`
//! alanlarıyla korunur — BU dosya SADECE havuzu KURAR, senkronizasyonun
//! KENDİSİ `arc.zig`/`lowlevel.zig`/`cycle_detector.zig`dedir.
//! `globals_block`, worker-slot'lu bir DİZİYE genişletildi (`asap.
//! RuntimeState.globals_blocks`) — HER worker'ın `nox_init_globals`ı
//! (bir GERÇEK Nox programında, MN.7'nin bağlayacağı) KENDİ hücresine
//! yazar, worker'LAR ARASI KARIŞMA OLMAZ.

const std = @import("std");
const asap = @import("../alloc/asap.zig");
const chase_lev_deque = @import("chase_lev_deque.zig");
const fiber_mod = @import("fiber.zig");

/// Bir havuzdaki TEK worker — "bir deque + bir OS iş parçacığı" (bkz.
/// proje planı, MN.3b'nin (a) maddesi). `deque` BU FAZDA hiç KULLANILMAZ
/// (fiber'lar HÂLÂ kendi doğdukları worker'a SABİT — ÇALMA mekanizması
/// YOK, bkz. modül üstü not) — Faz MN.4'ün work-stealing'i
/// BAĞLAYABİLMESİ İçİn ŞİMDİDEN yer TUTAR.
pub const Worker = struct {
    slot: usize,
    deque: chase_lev_deque.ChaseLevDeque(*fiber_mod.Fiber, 256) = .{},
};

pub const WorkerPool = struct {
    rt: *anyopaque,
    workers: []Worker,
    /// `n_workers - 1` uzunluğunda — slot 0 ÇAĞIRAN iş parçacığıdır,
    /// KENDİ `std.Thread`ı YOKTUR (`serve_multicore`nin AYNI "çağıran
    /// KENDİSİ de bir worker OLUR" deseni, bkz. `compiler/codegen_qbe/
    /// http_intrinsics.zig`nin `genHttpServeMulticore`si).
    threads: []std.Thread,
    allocator: std.mem.Allocator,

    /// TEK paylaşılan `RuntimeState`yi kurar, `arc_owner_pool` kapasitesini
    /// `n_workers`e YÜKSELTİR (Debug-only etki — bkz. `asap.
    /// setArcOwnerPoolCapacity`), ÇAĞIRAN iş parçacığını slot 0'a BAĞLAR.
    /// `spawnWorkers` ÇAĞRILMADAN ÖNCE BUNUN dönmüş OLMASI GEREKİR.
    pub fn create(allocator: std.mem.Allocator, n_workers: usize) !WorkerPool {
        std.debug.assert(n_workers >= 1 and n_workers <= asap.MAX_POOL_WORKERS);
        const rt = asap.nox_runtime_init() orelse return error.RuntimeInitFailed;
        const state: *asap.RuntimeState = @ptrCast(@alignCast(rt));
        asap.setArcOwnerPoolCapacity(state, n_workers);

        const workers = try allocator.alloc(Worker, n_workers);
        errdefer allocator.free(workers);
        for (workers, 0..) |*w, i| w.* = .{ .slot = i };

        const threads = try allocator.alloc(std.Thread, n_workers - 1);
        errdefer allocator.free(threads);

        // Çağıran iş parçacığı HER ZAMAN slot 0'dır.
        asap.setWorkerSlot(0);

        return .{ .rt = rt, .workers = workers, .threads = threads, .allocator = allocator };
    }

    /// Slot 1..n-1 İçİn `n_workers - 1` OS iş parçacığı BAŞLATIR — HER BİRİ
    /// ÖNCE KENDİ `asap.setWorkerSlot`ını ÇAĞIRIR, SONRA `entryFn(rt, slot,
    /// ctx)`i çalıştırır. Slot 0 (ÇAĞIRAN iş parçacığı) BURADA SPAWN
    /// EDİLMEZ — çağıran taraf `entryFn(pool.rt, 0, ctx)`i KENDİSİ,
    /// DOĞRUDAN çağırmalıdır (bkz. modül üstü not).
    pub fn spawnWorkers(
        self: *WorkerPool,
        comptime Ctx: type,
        entryFn: *const fn (rt: *anyopaque, slot: usize, ctx: Ctx) void,
        ctx: Ctx,
    ) !void {
        const Args = struct {
            rt: *anyopaque,
            slot: usize,
            ctx: Ctx,
            entry: *const fn (rt: *anyopaque, slot: usize, ctx: Ctx) void,
        };
        const Trampoline = struct {
            fn run(args: Args) void {
                asap.setWorkerSlot(args.slot);
                args.entry(args.rt, args.slot, args.ctx);
            }
        };
        for (self.threads, 0..) |*t, i| {
            const slot = i + 1;
            t.* = try std.Thread.spawn(.{}, Trampoline.run, .{Args{
                .rt = self.rt,
                .slot = slot,
                .ctx = ctx,
                .entry = entryFn,
            }});
        }
    }

    pub fn joinAll(self: *WorkerPool) void {
        for (self.threads) |t| t.join();
    }

    /// `joinAll` SONRASI çağrılmalıdır. `nox_runtime_deinit`i TAM BİR KEZ
    /// çağırır (bkz. `asap.zig`nin belge notu, "paylaşılan bir havuzda
    /// deinit TAM OLARAK BİR KEZ, TÜM worker'lar `join` EDİLDİKTEN SONRA").
    pub fn destroy(self: *WorkerPool) void {
        self.allocator.free(self.workers);
        self.allocator.free(self.threads);
        asap.nox_runtime_deinit(self.rt);
    }
};

// ---- Testler ----

const arc = @import("../alloc/arc.zig");
const cycle_detector = @import("../alloc/cycle_detector.zig");
// `lowlevel.zig`nin `nox_arena_*` fonksiyonları `export fn` (`pub` DEĞİL) —
// AŞAĞIDAKİ `extern fn` bildirimleri BUNLARI ÇAĞIRABİLMEK İçİndir, ama
// GERÇEK GÖVDELER bu dosyanın DERLEME BİRİMİNE dahil OLMALIDIR (`runtime/
// lib.zig` üzerinden GERÇEK `noxc`de OTOMATİK olur — BU dosyanın KENDİ dar
// test kökünde [`worker_pool_test_root.zig`] İSE `lowlevel`i AÇIKÇA
// içe aktarıp ZORLA analiz ETTİRMEK GEREKİR, bkz. `runtime/lib.zig`nin
// AYNI "zorla analiz" deseni).
const lowlevel = @import("../alloc/lowlevel.zig");

extern fn nox_arena_create(rt: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn nox_arena_alloc(arena_ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;
extern fn nox_arena_destroy(rt: ?*anyopaque, arena_ptr: ?*anyopaque) callconv(.c) void;

test {
    _ = lowlevel;
}

const StressShared = struct {
    globals_mismatch: std.atomic.Value(bool) = .init(false),
};

/// **GERÇEK bir eşzamanlılık hatası, BU testin YAZILMASI SIRASINDA
/// bulundu (bkz. `asap.zig`nin `cycle_gc_lock` belge notu) — bu YÜZDEN
/// `nox_cycle_collect`in KENDİSİ burada, worker'lar EŞ ZAMANLI ÇALIŞIRKEN,
/// BİLİNÇLİ OLARAK ÇAĞRILMAZ:** `cycle_gc_lock` SADECE `CycleGc`nin KENDİ
/// defter tutma yapılarını (`gc.meta`/`gc.roots`) korur — `nox_cycle_
/// collect`in GERÇEK mark/scan geçişi (`markGray`/`scanBlack`), taranan
/// nesnenin refcount'unu PLAIN (ATOMİK OLMAYAN) `-=`/`+=` İLE okur/yazar
/// (bkz. `cycle_detector.zig`). Bu, `cycle_gc_lock`UN KAPSAMI DIŞINDA
/// KALAN BAŞKA bir worker'ın AYNI nesneyi O ANDA ATOMİK `nox_rc_retain`/
/// `nox_rc_predecrement` İLE dokunmasıyla YARIŞABİLİR — GERÇEKTEN
/// DENENİP SIGBUS İLE ÇÖKTÜĞÜ DOĞRULANDI (bkz. git geçmişi). Bu, Faz
/// MN.3b'nin BİLİNÇLİ olarak dar bıraktığı bir alan — TAM güvenlik
/// SADECE Faz MN.6'nın kooperatif "dünyayı-durdur" bariyeriyle
/// (TÜM worker'lar fiber-yield noktalarında DURDURULDUKTAN SONRA collect
/// çalışır) mümkündür. `nox_cycle_possible_root`/`nox_cycle_forget`
/// (SADECE `gc.meta`/`gc.roots`e dokunur, HİÇBİR refcount'a DOKUNMAZ)
/// eşzamanlı olarak GÜVENLİDİR VE aşağıda egzersiz edilir; GERÇEK bir
/// collect PASI ise testin SONUNDA (`joinAll` SONRASI, TEK iş
/// parçacıklı bağlamda) AYRICA çalıştırılır.
///
/// HER worker'ın (spawn edilenler VE çağıran/slot-0) çalıştırdığı gövde —
/// (a) `nox_rc_alloc`/`retain`/`predecrement`/`free_payload` döngüsü
/// (`pool_free_lists_lock` çekişmesi), (b) arena oluştur/tahsis-et/
/// yok-et döngüsü (`arena_pool_lock`), (c) `cycle_detector.zig`nin
/// KENDİ sahte-dispatch enjeksiyon deseniyle `nox_cycle_possible_root`/
/// `nox_cycle_forget` (`cycle_gc_lock`, YUKARIDAKİ notla SINIRLI), (d)
/// `nox_globals_set`/`nox_globals_get` İLE KENDİ slotunun İZOLE kaldığını
/// doğrulama.
fn stressWorkerBody(rt: *anyopaque, slot: usize, shared: *StressShared) void {
    // `g_trace_dispatch_fn`/`g_gc_free_dispatch_fn` THREADLOCAL'DIR — HER
    // worker KENDİ enjeksiyonunu YAPMALIDIR (bkz. cycle_detector.zig'nin
    // KENDİ "bir iş parçacığındaki enjeksiyon diğerine SIZMAZ" testi).
    cycle_detector.injectFakeDispatch();

    var i: usize = 0;
    while (i < 300) : (i += 1) {
        // (a) ARC churn.
        if (arc.nox_rc_alloc(rt, 32)) |p| {
            arc.nox_rc_retain(p); // rc=2
            _ = arc.nox_rc_predecrement(p); // rc=1, hâlâ canlı
            if (arc.nox_rc_predecrement(p) != 0) arc.nox_rc_free_payload(rt, p, 32); // rc=0
        }

        // (b) Arena churn.
        if (nox_arena_create(rt)) |arena| {
            _ = nox_arena_alloc(arena, 64);
            _ = nox_arena_alloc(arena, 128);
            nox_arena_destroy(rt, arena);
        }

        // (c) Döngü-çözücü meta/kilit churn — `a`, GERÇEK bir döngü
        // KURMAZ (tek alanı `null`dır) — bu YÜZDEN `possible_root`
        // sonrası HER ZAMAN manuel olarak `forget`+`free_payload` İLE
        // (`genClassRelease`nin GERÇEK ikinci-predecrement dalı GİBİ)
        // serbest bırakılır; sızıntı YOK, `nox_cycle_collect`İN
        // KENDİSİ BURADA ÇAĞRILMAZ (bkz. fonksiyon üstü not).
        // **`i < 100` SINIRI BİLİNÇLİ**: `gc.possible_roots_since_collect`
        // TÜM havuzdaki (4 worker) `nox_cycle_possible_root` ÇAĞRILARI
        // ARASINDA PAYLAŞILAN TEK bir sayaçtır — `DEFAULT_COLLECT_
        // THRESHOLD`i (700) AŞARSA `nox_cycle_possible_root`un KENDİSİ
        // OTOMATİK olarak `collectLocked`i TETİKLER (bkz. onun kodu) —
        // BU DA fonksiyon üstü notta açıklanan AYNI GÜVENSİZ eşzamanlı
        // collect'e yol AÇARDI. 4 worker × 100 = 400 çağrı, 700'ün
        // GÜVENLE ALTINDA kalır.
        if (i < 100) {
            const a = cycle_detector.newFakeObject(rt); // rc=1
            arc.nox_rc_retain(a); // rc=2
            _ = arc.nox_rc_predecrement(a); // rc=1
            cycle_detector.nox_cycle_possible_root(rt, a);
            if (arc.nox_rc_predecrement(a) != 0) { // rc=0
                cycle_detector.nox_cycle_forget(rt, a);
                arc.nox_rc_free_payload(rt, a, cycle_detector.FAKE_PAYLOAD_SIZE);
            }
        }

        // (d) `globals_blocks[slot]` İZOLASYONU — BAŞKA worker'ların
        // ARALARDA yazdığı değerlerle ASLA KARIŞMAMALI.
        const marker: ?*anyopaque = @ptrFromInt(0x1000 + slot * 8 + @mod(i, 4));
        asap.nox_globals_set(rt, marker);
        std.Thread.yield() catch {};
        if (asap.nox_globals_get(rt) != marker) shared.globals_mismatch.store(true, .seq_cst);
    }
}

test "WorkerPool: 4 worker eş zamanlı ARC/arena/cycle-gc/globals izolasyonu" {
    const testing = std.testing;
    var pool = try WorkerPool.create(testing.allocator, 4);
    defer pool.destroy();

    var shared = StressShared{};
    try pool.spawnWorkers(*StressShared, stressWorkerBody, &shared);
    // Çağıran iş parçacığı (slot 0) KENDİSİ de bir worker OLUR (bkz.
    // `spawnWorkers`in belge notu).
    stressWorkerBody(pool.rt, 0, &shared);
    pool.joinAll();

    try testing.expect(!shared.globals_mismatch.load(.seq_cst));

    // `nox_cycle_collect`in KENDİSİ (bkz. `stressWorkerBody`nin üstündeki
    // GÜVENLİK notu) SADECE `joinAll` SONRASI (TÜM worker'lar BİTTİKTEN
    // SONRA, artık HİÇBİR ATOMİK ARC çekişmesi OLAMAYACAĞI İçİn GÜVENLİ)
    // burada ÇALIŞTIRILIR — codepath'in KENDİSİ HÂLÂ egzersiz edilir,
    // sadece EŞ ZAMANLI DEĞİL.
    cycle_detector.nox_cycle_collect(pool.rt);
}

test "WorkerPool: create/destroy tek başına (worker yok) sızmaz" {
    const testing = std.testing;
    var pool = try WorkerPool.create(testing.allocator, 1);
    defer pool.destroy();
    try testing.expectEqual(@as(usize, 0), pool.threads.len);
    try testing.expectEqual(@as(usize, 1), pool.workers.len);
}
