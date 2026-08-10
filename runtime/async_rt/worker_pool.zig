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
/// Faz MN.4/5.8: SADECE aşağıdaki GERÇEK spawn/await/çalma testi İçİn —
/// `scheduler.zig` ZATEN BU dosyayı (`Scheduler.worker: ?*Worker` alan
/// tipi İçİn) İMPORT EDİYOR, bu YÜZDEN BU YÖNDEKİ import DÖNGÜSEL (Zig'de
/// dosyalar ARASI karşılıklı `@import` TEKNİK olarak DESTEKLENİR — HİÇBİR
/// tip SONSUZ boyutlu OLMADIĞINDAN, HEPSİ İŞARETÇİ ÜZERİNDEN referans
/// verildiğinden, sorunsuz derlenir).
const scheduler_mod = @import("scheduler.zig");

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
    /// Faz MN.4/5.8: `state.pool_live_count`/`pool_waiting_on_io`/
    /// `pool_idle_workers`e (bkz. `asap.zig`) DOĞRUDAN İŞARETÇİLER —
    /// `bridge.zig`nin `nox_async_init`i BUNLARI `Scheduler.attachToPool`e
    /// GEÇİRİR (bkz. `scheduler.zig`nin belge notu, "runtime/alloc/den
    /// bağımsız kalma" sınırı — `scheduler.zig` `asap.RuntimeState`nin
    /// TAM TİPİNİ ASLA GÖRMEZ, SADECE bu üç `*std.atomic.Value(usize)`
    /// işaretçisiyle KONUŞUR).
    pool_live_count: *std.atomic.Value(usize),
    pool_waiting_on_io: *std.atomic.Value(usize),
    pool_idle_workers: *std.atomic.Value(usize),
    /// Faz MN.4/5.8: HER worker'ın `deque`ine (KENDİSİ DAHİL) İşaretçilerin
    /// ÖNCEDEN HESAPLANMIŞ dizisi — `Scheduler.attachToPool`e `sibling_
    /// deques` OLARAK GEÇİRİLİR (bkz. `scheduler.zig`nin belge notu,
    /// "worker_pool.Worker'ın TAM TİPİNE ASLA REFERANS VERİLMEZ" — SADECE
    /// `*ChaseLevDeque(...)` işaretçileri paylaşılır).
    deque_list: []*chase_lev_deque.ChaseLevDeque(*fiber_mod.Fiber, 256),
    /// Faz MN.6: `state.pool_stw_requested`/`pool_stw_arrived`/
    /// `pool_stw_sense`e (bkz. `asap.zig`) DOĞRUDAN İşaretçiler VE
    /// `state.pool_wake_fds`in TAM dilimi — `Scheduler.attachToPool`e
    /// `PoolLink` OLARAK GEÇİRİLİR (bkz. `scheduler.zig`nin belge notu,
    /// AYNI "runtime/alloc/den bağımsız kalma" sınırı).
    pool_stw_requested: *std.atomic.Value(bool),
    pool_stw_arrived: *std.atomic.Value(usize),
    pool_stw_sense: *std.atomic.Value(bool),
    wake_fds: []std.atomic.Value(i32),

    /// TEK paylaşılan `RuntimeState`yi kurar, `arc_owner_pool` kapasitesini
    /// `n_workers`e YÜKSELTİR (Debug-only etki — bkz. `asap.
    /// setArcOwnerPoolCapacity`), ÇAĞIRAN iş parçacığını slot 0'a BAĞLAR.
    /// `spawnWorkers` ÇAĞRILMADAN ÖNCE BUNUN dönmüş OLMASI GEREKİR.
    ///
    /// Faz MN.4/5: ARTIK `WorkerPool`u (`nox_runtime_init`in `RuntimeState`yi
    /// heap'e ayırıp `*anyopaque` DÖNDÜRDÜĞÜ AYNI "çalışma-zamanı tutamacı"
    /// deseniyle) HEAP'E AYIRIP `*WorkerPool` DÖNDÜRÜR — DEĞER-tabanlı bir
    /// dönüş (`WorkerPool` BY VALUE) çağıranın YEREL değişkenine kopyalanır,
    /// bu da `state.worker_pool`un (aşağıda ayarlanan) İŞARET ETTİĞİ adresin
    /// `create()` DÖNDÜKTEN SONRA GEÇERSİZLEŞMESİNE (sallanan işaretçi) yol
    /// AÇARDI — heap tahsisi bu SORUNU YAPISAL olarak ORTADAN KALDIRIR.
    pub fn create(allocator: std.mem.Allocator, n_workers: usize) !*WorkerPool {
        std.debug.assert(n_workers >= 1 and n_workers <= asap.MAX_POOL_WORKERS);
        const rt = asap.nox_runtime_init() orelse return error.RuntimeInitFailed;
        const state: *asap.RuntimeState = @ptrCast(@alignCast(rt));
        asap.setArcOwnerPoolCapacity(state, n_workers);

        const self = try allocator.create(WorkerPool);
        errdefer allocator.destroy(self);

        const workers = try allocator.alloc(Worker, n_workers);
        errdefer allocator.free(workers);
        for (workers, 0..) |*w, i| w.* = .{ .slot = i };

        const deque_list = try allocator.alloc(*chase_lev_deque.ChaseLevDeque(*fiber_mod.Fiber, 256), n_workers);
        errdefer allocator.free(deque_list);
        for (workers, 0..) |*w, i| deque_list[i] = &w.deque;

        const threads = try allocator.alloc(std.Thread, n_workers - 1);
        errdefer allocator.free(threads);

        // Çağıran iş parçacığı HER ZAMAN slot 0'dır.
        asap.setWorkerSlot(0);

        self.* = .{
            .rt = rt,
            .workers = workers,
            .threads = threads,
            .allocator = allocator,
            .pool_live_count = &state.pool_live_count,
            .pool_waiting_on_io = &state.pool_waiting_on_io,
            .pool_idle_workers = &state.pool_idle_workers,
            .deque_list = deque_list,
            .pool_stw_requested = &state.pool_stw_requested,
            .pool_stw_arrived = &state.pool_stw_arrived,
            .pool_stw_sense = &state.pool_stw_sense,
            .wake_fds = state.pool_wake_fds[0..],
        };
        // `bridge.zig`nin `nox_async_init`i BUNU görüp `Scheduler.
        // attachToPool`ı OTOMATİK çağırır (bkz. onun belge notu).
        state.worker_pool = self;
        return self;
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
        // `state.worker_pool`u `nox_runtime_deinit`DEN ÖNCE temizle —
        // AKSİ HALDE (deinit `state`yi SERBEST BIRAKTIKTAN SONRA) bu bir
        // kullanım-sonrası-serbest-bırakma YAZIMI olurdu.
        const state: *asap.RuntimeState = @ptrCast(@alignCast(self.rt));
        state.worker_pool = null;
        self.allocator.free(self.deque_list);
        self.allocator.free(self.workers);
        self.allocator.free(self.threads);
        asap.nox_runtime_deinit(self.rt);
        self.allocator.destroy(self);
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

// ---- Faz MN.4/5.8: GERÇEK spawn/await + KANITLANMIŞ çapraz-worker çalma ----

const STEAL_TEST_N_TASKS = 200;

const StealTestChildArg = struct {
    index: usize,
    executed_by: *[STEAL_TEST_N_TASKS]std.atomic.Value(usize),
};

/// `999`: "HENÜZ ÇALIŞTIRILMADI" duyarga (sentinel) değeri — GERÇEK bir
/// worker slotu (0..3) İLE ASLA ÇAKIŞMAZ (bkz. `asap.MAX_POOL_WORKERS`,
/// 64 — 999 KESİNLİKLE bunun ÜZERİNDE).
const STEAL_TEST_NOT_RUN: usize = 999;

fn stealTestChildFn(arg: *anyopaque) callconv(.c) i64 {
    const a: *StealTestChildArg = @ptrCast(@alignCast(arg));
    // `asap.currentWorkerSlot()` — BU fiber'ı O ANDA HANGİ OS iş
    // parçacığının (`scheduler.run()`nün KENDİ döngüsü) ÇALIŞTIRDIĞINI
    // (`threadlocal`, bkz. `asap.zig`) doğrudan okur — TÜM görevler
    // SADECE worker 0'ın deque'ine PUSH edildiğinden (bkz. aşağıdaki
    // test), BAŞKA bir slotta ÇALIŞMIŞ olması GERÇEK bir çalmayı kanıtlar.
    a.executed_by[a.index].store(asap.currentWorkerSlot(), .seq_cst);
    return @intCast(a.index * 2);
}

const StealTestCtx = struct {
    pool: *WorkerPool,
    /// Slot 0 TÜM görevleri spawn EDENE kadar diğer worker'ların
    /// `run()`a BAŞLAMASINI erteler — AKSİ HALDE bir thief, worker 0
    /// HENÜZ HİÇ spawn ETMEDEN `pool_live_count == 0` GÖRÜP HEMEN
    /// (YANLIŞLIKLA "iş yok") DÖNEBİLİRDİ.
    ready: std.atomic.Value(bool) = .init(false),
    tasks: [STEAL_TEST_N_TASKS]*scheduler_mod.Task(i64) = undefined,
    child_args: [STEAL_TEST_N_TASKS]StealTestChildArg = undefined,
    executed_by: [STEAL_TEST_N_TASKS]std.atomic.Value(usize) = @splat(std.atomic.Value(usize).init(STEAL_TEST_NOT_RUN)),
};

fn stealTestWorkerEntry(rt: *anyopaque, slot: usize, ctx: *StealTestCtx) void {
    var sched = scheduler_mod.Scheduler.init(ctx.pool.allocator) catch @panic("zamanlayici baslatilamadi");
    // Faz MN.6: bu test cycle-gc baskısı KURMAZ — `collect_fn` yine de
    // GERÇEK `nox_cycle_collect`e bağlanır (zararsız, HİÇ TETİKLENMEZ)
    // çünkü `PoolLink` artık ZORUNLU bir alan (bkz. `scheduler.zig`).
    sched.attachToPool(.{
        .own_slot = slot,
        .sibling_deques = ctx.pool.deque_list,
        .live_count = ctx.pool.pool_live_count,
        .waiting_on_io = ctx.pool.pool_waiting_on_io,
        .idle_workers = ctx.pool.pool_idle_workers,
        .stw_requested = ctx.pool.pool_stw_requested,
        .stw_arrived = ctx.pool.pool_stw_arrived,
        .stw_sense = ctx.pool.pool_stw_sense,
        .wake_fds = ctx.pool.wake_fds,
        .collect_fn = &cycle_detector.nox_cycle_collect,
        .rt = rt,
    }) catch {};

    if (slot == 0) {
        var i: usize = 0;
        while (i < STEAL_TEST_N_TASKS) : (i += 1) {
            ctx.child_args[i] = .{ .index = i, .executed_by = &ctx.executed_by };
            ctx.tasks[i] = scheduler_mod.spawn(&sched, i64, stealTestChildFn, &ctx.child_args[i]) catch @panic("spawn basarisiz");
        }
        ctx.ready.store(true, .release);
        // Faz MN.4/5.8: 200 önemsiz (I/O'suz, hemen dönen) görev worker
        // 0'ın KENDİ deque'inde `run()` BAŞLAMADAN ÖNCE bile ÇOK HIZLI
        // tüketilebilir — kardeşlerin `std.Thread.spawn`ı HENÜZ
        // ZAMANLANMAMIŞSA HİÇBİR ŞEY çalamadan test yanlışlıkla
        // BAŞARISIZ olabilir (GERÇEKTEN gözlemlendi, ender bir zamanlama
        // yarışı — çalma mantığının KENDİSİNDE bir hata DEĞİL). Birkaç
        // `yield`, OS zamanlayıcısına kardeşleri ÇALIŞTIRMASI İçİn adil
        // bir fırsat tanır.
        var y: usize = 0;
        while (y < 8) : (y += 1) std.Thread.yield() catch {};
    } else {
        while (!ctx.ready.load(.acquire)) std.Thread.yield() catch {};
    }

    sched.run() catch |e| switch (e) {
        error.Deadlock => @panic("MN.4/5.8 testinde beklenmedik deadlock"),
    };
    sched.deinit();
}

test "WorkerPool: GERÇEK spawn/await, TÜM sonuçlar doğru VE kanıtlanmış çapraz-worker çalma" {
    const testing = std.testing;
    const pool = try WorkerPool.create(testing.allocator, 4);
    defer pool.destroy();

    var ctx = StealTestCtx{ .pool = pool };

    try pool.spawnWorkers(*StealTestCtx, stealTestWorkerEntry, &ctx);
    // Çağıran iş parçacığı (slot 0) KENDİSİ de bir worker OLUR — TÜM
    // görevleri BU slot spawn eder (bkz. `stealTestWorkerEntry`).
    stealTestWorkerEntry(pool.rt, 0, &ctx);
    pool.joinAll();

    var stolen_count: usize = 0;
    var i: usize = 0;
    while (i < STEAL_TEST_N_TASKS) : (i += 1) {
        const by = ctx.executed_by[i].load(.seq_cst);
        try testing.expect(by != STEAL_TEST_NOT_RUN); // HER görev GERÇEKTEN çalıştı
        if (by != 0) stolen_count += 1;
        try testing.expect(ctx.tasks[i].completed);
        try testing.expectEqual(@as(i64, @intCast(i * 2)), ctx.tasks[i].result);
        testing.allocator.destroy(ctx.tasks[i]);
    }
    // Kanıt: EN AZ bir görev worker 0 DIŞINDA bir worker TARAFINDAN
    // ÇALIŞTIRILDI — bkz. `stealTestChildFn`nin belge notu.
    try testing.expect(stolen_count > 0);
}

// ---- Faz MN.6: eşzamanlı otomatik-collect (STW bariyeri) stres testi ----

const CYCLE_STRESS_N_WORKERS = 4;
/// `chase_lev_deque.ChaseLevDeque`nin SABİT kapasitesi 256'dır (bkz. onun
/// belge notu) — HER worker KENDİ 200 görevini `sched.run()` BAŞLAMADAN
/// ÖNCE TEK BAŞINA push ettiğinden (bkz. `cycleStressWorkerEntry`), bu
/// SINIRIN altında GÜVENLE kalır (`STEAL_TEST_N_TASKS`İLE AYNI, KANITLANMIŞ
/// değer). 4 worker × 200 görev × HER görevde 2 `nox_cycle_possible_root`
/// çağrısı = 1600 — `DEFAULT_COLLECT_THRESHOLD`i (700) run SIRASINDA
/// BİRDEN FAZLA KEZ aşar.
const CYCLE_STRESS_TASKS_PER_WORKER = 200;

/// Faz MN.6: bu testin KENDİ `collect_fn`i — GERÇEK `nox_cycle_collect`e
/// delege ETMEDEN ÖNCE bir GÖZLEM sayacını artırır. Bariyerin STRES
/// SIRASINDA GERÇEKTEN ateşlediğini (sadece `joinAll` SONRASI bir mop-up
/// çağrısı DEĞİL) KANITLAMANIN TEK yolu — `PoolLink.collect_fn` düz bir
/// fonksiyon İŞARETÇİSİ olduğundan (yakalama YAPAMAZ), sayaç modül-seviyesi
/// bir global OLMAK ZORUNDADIR.
var g_cycle_stress_collect_rounds: std.atomic.Value(usize) = .init(0);

fn countingCollectFn(rt: ?*anyopaque) callconv(.c) void {
    _ = g_cycle_stress_collect_rounds.fetchAdd(1, .seq_cst);
    cycle_detector.nox_cycle_collect(rt);
}

const CycleStressArg = struct { rt: *anyopaque };

/// HER görev: GERÇEK bir A<->B döngü çifti KURAR (`cycle_detector.zig`nin
/// KENDİ `newFakeObject`/`wireField` yardımcılarıyla — BİREBİR "Faz S.3"
/// testinin `simulateRelease`iyle AYNI mantık, BURADA doğrudan İNLİNE
/// edilir çünkü `simulateRelease` `pub` DEĞİL), SONRA HER İKİSİNİ de
/// `nox_cycle_possible_root`e YÖNLENDİRİR (mutual retain SAYESİNDE İKİSİ
/// de sıfıra DÜŞMEZ — GERÇEK bir döngü sızıntısı, TAM OLARAK `nox_cycle_
/// collect`in ÇÖZMESİ GEREKEN durum).
fn cycleStressChildFn(arg: *anyopaque) callconv(.c) i64 {
    const a: *CycleStressArg = @ptrCast(@alignCast(arg));
    const obj_a = cycle_detector.newFakeObject(a.rt);
    const obj_b = cycle_detector.newFakeObject(a.rt);
    cycle_detector.wireField(obj_a, obj_b); // a.next = b (RC(b)=2)
    cycle_detector.wireField(obj_b, obj_a); // b.next = a (RC(a)=2)
    if (arc.nox_rc_predecrement(obj_a) == 0) cycle_detector.nox_cycle_possible_root(a.rt, obj_a);
    if (arc.nox_rc_predecrement(obj_b) == 0) cycle_detector.nox_cycle_possible_root(a.rt, obj_b);
    return 0;
}

const CycleStressCtx = struct {
    pool: *WorkerPool,
    /// `spawn`nin döndürdüğü `*Task(i64)` HEAP tahsislidir (bkz. `scheduler.
    /// zig`nin `spawn`ı) VE hiçbir `await` OTOMATİK olarak SERBEST
    /// BIRAKMAZ — `stealTestWorkerEntry`nin AYNI deseni: HER worker KENDİ
    /// görev İşaretçilerini BURAYA yazar, test SONUNDA (`joinAll` SONRASI)
    /// TEK TEK `destroy` edilirler.
    tasks: [CYCLE_STRESS_N_WORKERS][CYCLE_STRESS_TASKS_PER_WORKER]*scheduler_mod.Task(i64) = undefined,
};

fn cycleStressWorkerEntry(rt: *anyopaque, slot: usize, ctx: *CycleStressCtx) void {
    // `g_trace_dispatch_fn`/`g_gc_free_dispatch_fn` THREADLOCAL'DIR — HER
    // worker KENDİ enjeksiyonunu YAPMALIDIR (bkz. `stressWorkerBody`nin
    // AYNI notu). Bir görev BAŞKA bir worker TARAFINDAN ÇALINSA BİLE, O
    // worker de KENDİ enjeksiyonunu YAPMIŞ OLACAĞINDAN sorun OLMAZ.
    cycle_detector.injectFakeDispatch();

    var sched = scheduler_mod.Scheduler.init(ctx.pool.allocator) catch @panic("zamanlayici baslatilamadi");
    sched.attachToPool(.{
        .own_slot = slot,
        .sibling_deques = ctx.pool.deque_list,
        .live_count = ctx.pool.pool_live_count,
        .waiting_on_io = ctx.pool.pool_waiting_on_io,
        .idle_workers = ctx.pool.pool_idle_workers,
        .stw_requested = ctx.pool.pool_stw_requested,
        .stw_arrived = ctx.pool.pool_stw_arrived,
        .stw_sense = ctx.pool.pool_stw_sense,
        .wake_fds = ctx.pool.wake_fds,
        .collect_fn = &countingCollectFn,
        .rt = rt,
    }) catch {};

    // `arg`, BU fonksiyonun YIĞIN çerçevesinde yaşar — `sched.run()`
    // TÜM havuz genelinde HİÇBİR canlı görev KALMAYANA KADAR DÖNMEZ (bkz.
    // pool-çapında deadlock kontrolü), bu YÜZDEN spawn edilen (VE
    // muhtemelen BAŞKA bir worker'a ÇALINAN) görevler `arg`i OKURKEN bu
    // çerçeve HER ZAMAN GEÇERLİDİR.
    var arg = CycleStressArg{ .rt = rt };
    var i: usize = 0;
    while (i < CYCLE_STRESS_TASKS_PER_WORKER) : (i += 1) {
        ctx.tasks[slot][i] = scheduler_mod.spawn(&sched, i64, cycleStressChildFn, &arg) catch @panic("spawn basarisiz");
    }

    sched.run() catch |e| switch (e) {
        error.Deadlock => @panic("MN.6 cycle-stres testinde beklenmedik deadlock"),
    };
    sched.deinit();
}

test "WorkerPool: GERÇEK eş zamanlı otomatik-collect (STW bariyeri) ÇÖKMEDEN/SIZMADAN çalışır" {
    const testing = std.testing;
    g_cycle_stress_collect_rounds.store(0, .seq_cst);

    const pool = try WorkerPool.create(testing.allocator, CYCLE_STRESS_N_WORKERS);
    defer pool.destroy();

    var ctx = CycleStressCtx{ .pool = pool };
    try pool.spawnWorkers(*CycleStressCtx, cycleStressWorkerEntry, &ctx);
    // Çağıran iş parçacığı (slot 0) KENDİSİ de bir worker OLUR.
    cycleStressWorkerEntry(pool.rt, 0, &ctx);
    pool.joinAll();

    for (ctx.tasks) |worker_tasks| {
        for (worker_tasks) |t| testing.allocator.destroy(t);
    }

    // Bariyer GERÇEKTEN, stres SIRASINDA (`joinAll` ÖNCESİ, worker'lar HÂLÂ
    // eş zamanlı ÇALIŞIRKEN) EN AZ bir KEZ ateşledi — SADECE bir son mop-up
    // ÇAĞRISI DEĞİL. `WorkerPool.destroy()`nün OTOMATİK `debug_gpa` sızıntı
    // denetimi (Debug modunda) ANA doğruluk kanıtıdır: HERHANGİ bir bariyer
    // hatası (yarış/çift-serbest-bırakma/SIGBUS) BURADA ÇÖKME ya da sızıntı
    // OLARAK ortaya çıkardı.
    try testing.expect(g_cycle_stress_collect_rounds.load(.seq_cst) >= 1);
}
