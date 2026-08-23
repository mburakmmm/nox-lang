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
//! **Senkronizasyon:** `RuntimeState`nin `arena_pool`/`cycle_gc`si (bkz.
//! `asap.zig`) Faz MN.3b'DEN İTİBAREN KENDİ `SpinLock` alanlarıyla
//! korunur — BU dosya SADECE havuzu KURAR, senkronizasyonun KENDİSİ
//! `lowlevel.zig`/`cycle_detector.zig`dedir. `pool_free_lists` (`arc.
//! zig`nin ARC küçük-nesne havuzu) Faz MN.10'DAN İTİBAREN `globals_
//! blocks`İLE AYNI worker-slotlu, KİLİTSİZ desendedir (bkz. AŞAĞIDAKİ
//! not) — SpinLock DEĞİL.
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
const channel_mod = @import("channel.zig");

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
    /// Faz MN.8, Bulgu B: `state.pool_activity_epoch`e (bkz. `asap.zig`)
    /// DOĞRUDAN İŞARETÇİ — AYNI desen, `Scheduler.attachToPool`e `PoolLink.
    /// activity_epoch` OLARAK GEÇİRİLİR.
    pool_activity_epoch: *std.atomic.Value(u64),
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
            .pool_activity_epoch = &state.pool_activity_epoch,
            .deque_list = deque_list,
            .pool_stw_requested = &state.pool_stw_requested,
            .pool_stw_arrived = &state.pool_stw_arrived,
            .pool_stw_sense = &state.pool_stw_sense,
            .wake_fds = state.pool_wake_fds[0..],
        };
        // `bridge.zig`nin `nox_async_init`i BUNU görüp `Scheduler.
        // attachToPool`ı OTOMATİK çağırır (bkz. onun belge notu).
        state.worker_pool = self;
        // Faz [YENİ] (bkz. plan dosyası "İki gerçek performans regresyonunu
        // düzeltme"): `asap.RuntimeState.pool_ever_active`nin belge notu —
        // TAM OLARAK BURADA işaretlenir (`nox_async_init`in İÇİNDE DEĞİL),
        // ÇÜNKÜ bir havuz `main`in BAŞINDAN SONRA, program ÇALIŞIRKEN de
        // yaratılabilir (`pool_run`/`serve_multicore`).
        state.pool_ever_active.store(true, .monotonic);
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
/// (Faz MN.10'DAN İTİBAREN `pool_free_lists` KİLİTSİZ/worker-slotlu —
/// BU test ARTIK "kilit çekişmesi altında doğruluk" YERİNE "kilitsiz,
/// worker-slotlu izolasyon altında doğruluk"u kanıtlıyor), (b) arena
/// oluştur/tahsis-et/
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
        .activity_epoch = ctx.pool.pool_activity_epoch,
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
        try testing.expect(ctx.tasks[i].state.load(.acquire) == scheduler_mod.Task(i64).COMPLETED);
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
        .activity_epoch = ctx.pool.pool_activity_epoch,
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

// ---- Faz MN.9.1: Channel[T]nin çapraz-worker senkronizasyon stres testi ----

const ChanStress = channel_mod.Channel(i64);
const CHAN_STRESS_N_PRODUCERS = 64;
const CHAN_STRESS_ROUNDS = 20;

/// v1.31.0 (bkz. plan dosyası "Eşzamanlılık stres-test altyapısı"): tur
/// sayısını `NOX_STRESS_ROUNDS` ortam değişkeninden OKUR (varsayılan,
/// AYARLANMAMIŞSA/ayrıştırılamıyorsa, `default_rounds`e DÜŞER — BÖYLECE
/// bu değişiklik `zig build test`in KENDİ, ZATEN geçen davranışını SIFIR
/// ETKİLER: env değişkeni YOKSA bu fonksiyonu kullanan HER İKİ test de
/// ÖNCEKİ GİBİ TAM 20 tur çalışır). `zig build stress-test`in YENİ
/// `RunArtifact` adımı BU değişkeni ÇOK DAHA BÜYÜK bir değere AYARLAR
/// (bkz. `build.zig`nin `stress-test` adımı).
fn stressRoundsFromEnv(default_rounds: usize) usize {
    const v = std.c.getenv("NOX_STRESS_ROUNDS") orelse return default_rounds;
    return std.fmt.parseInt(usize, std.mem.span(v), 10) catch default_rounds;
}

const ChanStressProducerArg = struct {
    chan: *ChanStress,
    value: i64,
};

fn chanStressProducerFn(arg: *anyopaque) callconv(.c) void {
    const a: *ChanStressProducerArg = @ptrCast(@alignCast(arg));
    a.chan.send(a.value);
}

const ChanStressCtx = struct {
    pool: *WorkerPool,
    chan: ChanStress = undefined,
    ready: std.atomic.Value(bool) = .init(false),
    producer_args: [CHAN_STRESS_N_PRODUCERS]ChanStressProducerArg = undefined,
    producer_tasks: [CHAN_STRESS_N_PRODUCERS]*scheduler_mod.Task(void) = undefined,
    consumer_task: *scheduler_mod.Task(void) = undefined,
    /// Tüketicinin HER değeri EN FAZLA BİR KEZ gördüğünü kanıtlar —
    /// GERÇEK bir yarış (kilitsiz tampon/bekleyen listesi MUTASYONU)
    /// DEĞER kaybına/YİNELENMESİNE yol AÇARDI.
    seen: [CHAN_STRESS_N_PRODUCERS]std.atomic.Value(bool) = @splat(std.atomic.Value(bool).init(false)),
};

fn chanStressConsumerFn(arg: *anyopaque) callconv(.c) void {
    const ctx: *ChanStressCtx = @ptrCast(@alignCast(arg));
    var i: usize = 0;
    while (i < CHAN_STRESS_N_PRODUCERS) : (i += 1) {
        const v = ctx.chan.recv();
        ctx.seen[@intCast(v)].store(true, .seq_cst);
    }
}

fn chanStressWorkerEntry(rt: *anyopaque, slot: usize, ctx: *ChanStressCtx) void {
    var sched = scheduler_mod.Scheduler.init(ctx.pool.allocator) catch @panic("zamanlayici baslatilamadi");
    // Faz MN.9.1: `bridge.zig`nin `nox_async_init`inin GERÇEK programlarda
    // OTOMATİK yaptığı eşitleme — BURADA (bridge.zig'i İTHAL ETMEYEN,
    // standalone bir test yardımcısı OLDUĞUNDAN) ELLE yapılır.
    scheduler_mod.setCurrentScheduler(&sched);
    defer scheduler_mod.setCurrentScheduler(null);
    sched.attachToPool(.{
        .own_slot = slot,
        .sibling_deques = ctx.pool.deque_list,
        .live_count = ctx.pool.pool_live_count,
        .waiting_on_io = ctx.pool.pool_waiting_on_io,
        .idle_workers = ctx.pool.pool_idle_workers,
        .activity_epoch = ctx.pool.pool_activity_epoch,
        .stw_requested = ctx.pool.pool_stw_requested,
        .stw_arrived = ctx.pool.pool_stw_arrived,
        .stw_sense = ctx.pool.pool_stw_sense,
        .wake_fds = ctx.pool.wake_fds,
        .collect_fn = &cycle_detector.nox_cycle_collect,
        .rt = rt,
    }) catch {};

    if (slot == 0) {
        ctx.chan = ChanStress.init(&sched, 4); // küçük kapasite — GERÇEK çekişme/bloklama zorlar
        var i: usize = 0;
        while (i < CHAN_STRESS_N_PRODUCERS) : (i += 1) {
            ctx.producer_args[i] = .{ .chan = &ctx.chan, .value = @intCast(i) };
            ctx.producer_tasks[i] = scheduler_mod.spawn(&sched, void, chanStressProducerFn, &ctx.producer_args[i]) catch @panic("spawn basarisiz");
        }
        // Tüketici de BİR GÖREV olarak spawn edilir (senkron, doğrudan
        // `recv()` ÇAĞRILAMAZ — `sched.current` BURADA `null` OLDUĞUNDAN
        // askıya alma GEÇERSİZ olurdu) — `sched.run()` AŞAĞIDA HEPSİNİ
        // (üreticiler+tüketici) çalıştırır.
        ctx.consumer_task = scheduler_mod.spawn(&sched, void, chanStressConsumerFn, ctx) catch @panic("spawn basarisiz");
        ctx.ready.store(true, .release);
        var y: usize = 0;
        while (y < 8) : (y += 1) std.Thread.yield() catch {};
    } else {
        while (!ctx.ready.load(.acquire)) std.Thread.yield() catch {};
    }

    sched.run() catch |e| switch (e) {
        error.Deadlock => @panic("MN.9.1 Channel stres testinde beklenmedik deadlock"),
    };
    // `ctx.chan.scheduler` BU `sched`e (YEREL DEĞİŞKEN) İşaret ETTİĞİNDEN —
    // `deinit()` BURADA, `sched` HÂLÂ CANLIYKEN çağrılmalıdır (test
    // fonksiyonunun KENDİSİNDEN, `chanStressWorkerEntry` DÖNDÜKTEN SONRA
    // çağrılsaydı SARKAN bir işaretçi olurdu — GERÇEKTEN SIGSEGV İLE
    // yakalandı).
    if (slot == 0) ctx.chan.deinit();
    sched.deinit();
}

test "WorkerPool: Channel[T] çapraz-worker paylaşımı — GERÇEK çalma altında SIFIR kayıp/yinelenme (20 tekrar)" {
    const testing = std.testing;
    // Faz MN.9.1: `testing.allocator` (DebugAllocator, sızıntı-izleme İçİn
    // HER `alloc`de bir yığın izi YAKALAR) YERİNE `page_allocator` —
    // `fiber.zig`nin KENDİ, ÖNCEDEN belgelenmiş "Fiber yığını + DebugAllocator
    // tuzağı" notu: bir fiber'ın SAHTE önyükleme çerçevesinin fp/lr'si
    // GERÇEK bir çağrı zincirini TEMSİL ETMEZ — bu YÜZDEN bir fiber
    // GÖVDESİ İçİNDEN (BURADA: `Channel.send`in `buffer.append`i, ÜRETİCİ/
    // TÜKETİCİ görevlerin KENDİ fiber'ları İçİNDEN) yapılan bir tahsis,
    // DebugAllocator'ın çerçeve-yürüme izlemesini GEÇERSİZ belleğe
    // düşürüp `-Doptimize=ReleaseFast`da GERÇEKTEN SIGSEGV İLE çöktü
    // (`lldb` İLE doğrulandı: `DebugAllocator.alloc` → `captureCurrentStackTrace`
    // → `SelfUnwinder.nextInner`, `channel.zig`nin `send`i İçİNDEN).
    // `channel.zig`/`fiber.zig`nin KENDİ testleri ZATEN AYNI gerekçeyle
    // `page_allocator` kullanıyor — BURADA da AYNI, KANITLANMIŞ desen.
    const allocator = std.heap.page_allocator;

    const rounds = stressRoundsFromEnv(CHAN_STRESS_ROUNDS);
    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        const pool = try WorkerPool.create(allocator, 4);
        defer pool.destroy();

        var ctx = ChanStressCtx{ .pool = pool };
        try pool.spawnWorkers(*ChanStressCtx, chanStressWorkerEntry, &ctx);
        chanStressWorkerEntry(pool.rt, 0, &ctx);
        pool.joinAll();

        var i: usize = 0;
        while (i < CHAN_STRESS_N_PRODUCERS) : (i += 1) {
            try testing.expectEqual(scheduler_mod.Task(void).COMPLETED, ctx.producer_tasks[i].state.load(.acquire));
            allocator.destroy(ctx.producer_tasks[i]);
        }
        try testing.expectEqual(scheduler_mod.Task(void).COMPLETED, ctx.consumer_task.state.load(.acquire));
        allocator.destroy(ctx.consumer_task);
        i = 0;
        while (i < CHAN_STRESS_N_PRODUCERS) : (i += 1) {
            try testing.expect(ctx.seen[i].load(.seq_cst));
        }
    }
}

// ---- v1.29.1: Task[T] çapraz-worker `await_()` — GERÇEK, dışarıdan bulunup
// doğrulanan bir hatanın DOĞRUDAN regresyon testi ----
//
// `checker.zig`nin `isSpawnParamSafeType`si `Task[T]`yi BİR `spawn`e argüman
// OLARAK ZATEN İZİN VERİYORDU (MN.9'DAN ÖNCE de) — bir fiber KENDİ oluşturduğu
// bir `Task`ı BAŞKA bir spawn edilmiş fonksiyona (BURADA: `taskAwaitStressWaiterFn`)
// geçirebilir, O fonksiyonun fiber'ı BAŞKA bir worker'a ÇALINABİLİR (Chase-Lev
// deque'nin standart davranışı), VE `.await_()` O ÇALINMIŞ fiber'DAN çağrılırsa
// ESKİDEN `self.scheduler`i (görev OLUŞTURULDUĞUNDA sabitlenen, yani worker 0'ın
// scheduler'ı) kullanıyordu — `Channel[T]`nin MN.9.1'de düzeltilen AYNI hatası,
// SADECE `Task[T]` İçİn HİÇ düzeltilmemişti (`entryTrampoline`/`await_`nin YENİ
// `Waiter{fiber,scheduler}` deseni İçİN bkz. `scheduler.zig`). Bu test TÜM
// `waiter_i`leri worker 0'ın deque'ine PUSH EDER (`StealTestCtx`İLE AYNI desen)
// — kardeşler ÇALDIĞINDA (KANITLANMIŞ, `waiter_ran_on`) AYNI ANDA `original_i.
// await_()`i (`original_i`nin scheduler'ı HER ZAMAN worker 0) BAŞKA bir worker'DAN
// çağırmış olurlar — TAM OLARAK bulunan hatanın senaryosu.

const TASK_AWAIT_STRESS_N = 200;

const TaskAwaitStressCtx = struct {
    pool: *WorkerPool,
    ready: std.atomic.Value(bool) = .init(false),
    original_args: [TASK_AWAIT_STRESS_N]usize = undefined,
    waiter_args: [TASK_AWAIT_STRESS_N]TaskAwaitStressWaiterArg = undefined,
    originals: [TASK_AWAIT_STRESS_N]*scheduler_mod.Task(i64) = undefined,
    waiters: [TASK_AWAIT_STRESS_N]*scheduler_mod.Task(i64) = undefined,
    /// Waiter'ın GERÇEKTEN HANGİ worker'da ÇALIŞTIĞI — TÜM waiter'lar SADECE
    /// worker 0'ın deque'ine PUSH edildiğinden, sıfır-DIŞI bir değer GERÇEK
    /// bir çalmayı (dolayısıyla çapraz-worker `await_()`i) KANITLAR.
    waiter_ran_on: [TASK_AWAIT_STRESS_N]std.atomic.Value(usize) = @splat(std.atomic.Value(usize).init(STEAL_TEST_NOT_RUN)),
};

const TaskAwaitStressWaiterArg = struct {
    idx: usize,
    ctx: *TaskAwaitStressCtx,
    original: *scheduler_mod.Task(i64),
};

fn taskAwaitStressOriginalFn(arg: *anyopaque) callconv(.c) i64 {
    const idx: *usize = @ptrCast(@alignCast(arg));
    return @intCast(idx.* * 2);
}

fn taskAwaitStressWaiterFn(arg: *anyopaque) callconv(.c) i64 {
    const a: *TaskAwaitStressWaiterArg = @ptrCast(@alignCast(arg));
    // BULUNAN hatanın TAM kalbi: `a.original` BAŞKA bir worker'da
    // OLUŞTURULDU (`a.original.scheduler` == worker 0'ın scheduler'ı) — BU
    // fiber ÇALINDIYSA (bkz. `waiter_ran_on`), `await_()` ARTIK (düzeltme
    // SONRASI) `currentScheduler()` İLE KENDİ, GERÇEKTEN ÇALIŞAN worker'ını
    // kullanmalı, `a.original.scheduler`i DEĞİL.
    const result = a.original.await_();
    a.ctx.waiter_ran_on[a.idx].store(asap.currentWorkerSlot(), .seq_cst);
    return result + 1;
}

fn taskAwaitStressWorkerEntry(rt: *anyopaque, slot: usize, ctx: *TaskAwaitStressCtx) void {
    var sched = scheduler_mod.Scheduler.init(ctx.pool.allocator) catch @panic("zamanlayici baslatilamadi");
    // v1.29.1: `bridge.zig`nin `nox_async_init`inin GERÇEK programlarda
    // OTOMATİK yaptığı eşitleme — `Task.await_()` ARTIK BUNA dayandığından
    // (bkz. `scheduler.zig`nin `Waiter`i) standalone test yardımcısı BUNU
    // ELLE yapmalıdır (`chanStressWorkerEntry`İLE AYNI desen).
    scheduler_mod.setCurrentScheduler(&sched);
    defer scheduler_mod.setCurrentScheduler(null);
    sched.attachToPool(.{
        .own_slot = slot,
        .sibling_deques = ctx.pool.deque_list,
        .live_count = ctx.pool.pool_live_count,
        .waiting_on_io = ctx.pool.pool_waiting_on_io,
        .idle_workers = ctx.pool.pool_idle_workers,
        .activity_epoch = ctx.pool.pool_activity_epoch,
        .stw_requested = ctx.pool.pool_stw_requested,
        .stw_arrived = ctx.pool.pool_stw_arrived,
        .stw_sense = ctx.pool.pool_stw_sense,
        .wake_fds = ctx.pool.wake_fds,
        .collect_fn = &cycle_detector.nox_cycle_collect,
        .rt = rt,
    }) catch {};

    if (slot == 0) {
        var i: usize = 0;
        while (i < TASK_AWAIT_STRESS_N) : (i += 1) {
            ctx.original_args[i] = i;
            ctx.originals[i] = scheduler_mod.spawn(&sched, i64, taskAwaitStressOriginalFn, &ctx.original_args[i]) catch @panic("spawn basarisiz (original)");
            ctx.waiter_args[i] = .{ .idx = i, .ctx = ctx, .original = ctx.originals[i] };
            ctx.waiters[i] = scheduler_mod.spawn(&sched, i64, taskAwaitStressWaiterFn, &ctx.waiter_args[i]) catch @panic("spawn basarisiz (waiter)");
        }
        ctx.ready.store(true, .release);
        var y: usize = 0;
        while (y < 8) : (y += 1) std.Thread.yield() catch {};
    } else {
        while (!ctx.ready.load(.acquire)) std.Thread.yield() catch {};
    }

    sched.run() catch |e| switch (e) {
        error.Deadlock => @panic("v1.29.1 Task await-stres testinde beklenmedik deadlock"),
    };
    sched.deinit();
}

test "WorkerPool: Task[T] çapraz-worker await_() — GERÇEK çalma altında sonuçlar doğru VE kanıtlanmış çapraz-worker await (20 tekrar)" {
    const testing = std.testing;
    // v1.29.1: `testing.allocator` (DebugAllocator) YERİNE `page_allocator` —
    // `Channel[T]`nin AYNI, ÖNCEDEN belgelenmiş "Fiber yığını + DebugAllocator
    // tuzağı" notuyla BİREBİR AYNI (bkz. yukarıdaki Channel stres testinin
    // belge notu): `taskAwaitStressWaiterFn`nin fiber GÖVDESİNDEN çağırdığı
    // `original.await_()` → `sched.suspendCurrent()` YOLU, uyandırma anında
    // `Scheduler.markReady`nin `self.ready.append`ini (GERÇEK bir tahsis)
    // TETİKLER — bu, `DebugAllocator`ın HER `alloc`de yaptığı çerçeve-yürüme
    // İz yakalamasını, fiber'ın SAHTE önyükleme çerçevesi ÜZERİNDEN GEÇERSİZ
    // belleğe düşürüp `-Doptimize=ReleaseFast`ta GERÇEKTEN SIGSEGV İLE
    // çökertir (`lldb` İLE doğrulandı: `DebugAllocator.alloc` →
    // `captureCurrentStackTrace` → `SelfUnwinder.nextInner`, `Scheduler.
    // markReady`nin İçİNDEN, `fiber.trampoline`den ÇAĞRILAN bir fiber
    // GÖVDESİ İçİNDE).
    const allocator = std.heap.page_allocator;
    const rounds = stressRoundsFromEnv(CHAN_STRESS_ROUNDS);
    // v1.35.0 (bkz. plan dosyası "Bilinen iki test flake'ini kalıcı olarak
    // düzeltme"): ESKİDEN bu sayaç HER turun İÇİNDE yerel değişkendi VE
    // `stolen_waiter_count > 0` iddiası HER turdan BAĞIMSIZ olarak (20 KEZ)
    // kontrol ediliyordu — zorlama mekanizması (satır ~800 civarı, SABİT 8
    // `std.Thread.yield()`) İYİ NİYETLİ AMA GARANTİSİZ olduğundan (kardeş
    // worker'ların `std.Thread.spawn` SONRASI GERÇEKTEN OS TARAFINDAN
    // zamanlandığını doğrulayan bir bariyer YOK), KÜÇÜK bir tur-başına
    // başarısızlık olasılığı 20 KEZ bileşip ARALIKLI GERÇEK test
    // başarısızlıklarına yol AÇIYORDU (`stolen_waiter_count == 0` bazı
    // turlarda). Testin KENDİ belgelenmiş amacı ("await_()'in çapraz-worker
    // DOĞRULUĞUNU kanıtlamak") HER turun KENDİ başına BUNU YENİDEN
    // kanıtlamasını GEREKTİRMEZ — TÜM 20 tur BOYUNCA EN AZ BİR çalma
    // yeterlidir (KARDEŞ `ChanStressCtx` testinin HİÇ çalma İDDİA
    // ETMEMESİYLE AYNI ilke — bkz. onun belge notu). Sayaç ARTIK döngü
    // DIŞINDA BİRİKİR, iddia döngü BİTTİKTEN SONRA TEK SEFER kontrol edilir.
    var total_stolen: usize = 0;
    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        const pool = try WorkerPool.create(allocator, 4);
        defer pool.destroy();

        var ctx = TaskAwaitStressCtx{ .pool = pool };
        try pool.spawnWorkers(*TaskAwaitStressCtx, taskAwaitStressWorkerEntry, &ctx);
        taskAwaitStressWorkerEntry(pool.rt, 0, &ctx);
        pool.joinAll();

        var i: usize = 0;
        while (i < TASK_AWAIT_STRESS_N) : (i += 1) {
            try testing.expectEqual(scheduler_mod.Task(i64).COMPLETED, ctx.originals[i].state.load(.acquire));
            try testing.expectEqual(scheduler_mod.Task(i64).COMPLETED, ctx.waiters[i].state.load(.acquire));
            try testing.expectEqual(@as(i64, @intCast(i * 2 + 1)), ctx.waiters[i].result);
            const by = ctx.waiter_ran_on[i].load(.seq_cst);
            try testing.expect(by != STEAL_TEST_NOT_RUN);
            if (by != 0) total_stolen += 1;
            allocator.destroy(ctx.originals[i]);
            allocator.destroy(ctx.waiters[i]);
        }
    }
    // Kanıt: 20 tur BOYUNCA EN AZ bir waiter worker 0 DIŞINDA ÇALIŞTI —
    // o waiter'ın `original.await_()` çağrısı BU YÜZDEN GERÇEKTEN
    // çapraz-worker'dı.
    try testing.expect(total_stolen > 0);
}
