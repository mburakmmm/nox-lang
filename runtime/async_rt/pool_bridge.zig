//! Faz MN.7a (bkz. proje planı "WorkerPool'u GERÇEK Nox programlarına
//! bağlama") — `nox.thread.pool_run`ın saf-Zig çekirdeği. `thread_bridge.
//! zig`nin `childThreadMain`ıyla AYNI "bir OS iş parçacığının çalışma-
//! zamanı yaşam-döngüsünü kur" ROLÜNÜ oynar, ama İKİ TEMEL FARKLA:
//! (1) `childThreadMain` HER çağrıda TAZE, BAĞIMSIZ bir `RuntimeState`
//! kurar (`asap.nox_runtime_init()`) — BURADAKİ `poolWorkerMain` İSE
//! `WorkerPool.create`in ZATEN kurduğu TEK, PAYLAŞILAN `rt`yi YENİDEN
//! KULLANIR, KENDİSİ HİÇ `nox_runtime_init` ÇAĞIRMAZ; (2) `childThreadMain`
//! İşini bitirince KENDİ `RuntimeState`ini TAMAMEN yıkar — BURADA İSE
//! `nox_runtime_deinit` SADECE `WorkerPool.destroy()` TARAFINDAN, TÜM
//! worker'lar `joinAll()` İLE katıldıktan SONRA, TAM BİR KEZ çağrılır
//! (HER worker SADECE KENDİ threadlocal `Scheduler`ını — `bridge.zig`nin
//! `nox_async_deinit`i — yıkar, `RuntimeState`nin KENDİSİNİ DEĞİL).
//!
//! **NEDEN `worker_pool.zig`ye/`bridge.zig`ye EKLENMEDİ, AYRI bir dosya:**
//! `worker_pool.zig`nin KENDİ modül-üstü notu "Nox kaynağına/codegen'e
//! HİÇ dokunmaz" DİYOR — BU dosya İSE TAM OLARAK codegen'in ÇAĞIRACAĞI
//! C-ABI YÜZEYDİR (`nox_pool_run`), o notu İHLAL ETMEMEK İçİn AYRI
//! tutulur. `bridge.zig`nin export'ları İSE ZATEN-BAĞLANMIŞ (`nox_async_
//! init` ÇAĞRILMIŞ) bir OS iş parçacığından çağrılmak İçİNDİR — YENİ
//! bir OS iş parçacığı ORKESTRE ETMEK (`std.Thread.spawn`, `WorkerPool.
//! create`) O dosyanın SORUMLULUĞU DEĞİLDİR (`thread_bridge.zig`nin
//! KENDİSİ de AYNI gerekçeyle AYRI bir dosyadır).
//!
//! **Çağıran fiber'ı BLOKE ETMEDEN bekleme — `nox_thread_join`ın AYNI
//! İKİ-modlu deseni:** `WorkerPool` yaşam-döngüsünün TAMAMINI (`create→
//! spawnWorkers→entry çalıştır→joinAll→destroy`) DOĞRUDAN ÇAĞIRAN OS iş
//! parçacığında çalıştırmak, O iş parçacığını `pool_run` SÜRESİNCE
//! TAMAMEN İŞGAL EDERDİ — ORİJİNAL zamanlayıcının `run()` döngüsüne
//! KONTROL ASLA GERİ DÖNMEZ, KARDEŞ fiber'lar (varsa) donardı. Bu YÜZDEN
//! `nox_pool_run` BİR "sürücü" OS iş parçacığı DAHA spawn eder (`thread_
//! bridge.zig`nin `nox_thread_spawn`ıyla AYNI `std.Thread.spawn` deseni)
//! — bu sürücü `WorkerPool`nin TAMAMINI çalıştırıp (KENDİSİ slot 0 OLUR)
//! bir self-pipe ÜZERİNDEN TAMAMLANMAYI sinyaller; ÇAĞIRAN fiber İSE
//! `nox_thread_join`ın AYNI iki-modlu (`bridge.currentFiberScheduler()`
//! VARSA reaktör-tabanlı `nonBlockingRead`, YOKSA düz bloklayan `read`)
//! beklemesini yapar — KARDEŞ fiber'lar `pool_run` SÜRERKEN İLERLEMEYE
//! DEVAM EDER.
//!
//! **v1 BİLİNÇLİ sınırlaması:** iç içe `pool_run` (bir `entry()` KENDİSİ
//! `pool_run` ÇAĞIRIRSA) DESTEKLENMEZ/test EDİLMEZ — TEK seferde TEK bir
//! aktif havuz VARSAYILIR. Modül-seviyesi global'ler `entry()` İçİNDE
//! programın ANA `rt`sinden TAMAMEN BAĞLANTISIZ bir KOPYADIR (`nox.
//! thread.start`ın ZATEN SAHİP OLDUĞU AYNI sınırlama — bkz. `stdlib/
//! nox/thread.nox`).
//!
//! **Backend sınırı** (BU dosyanın KENDİSİ bilmez/uygulamaz — codegen'in
//! SORUMLULUĞU, bkz. proje planı Tasarım #1): `nox.thread.pool_run`
//! SADECE `--release` (LLVM backend) İLE derlenebilir, ÇÜNKÜ `compiler/
//! codegen_qbe/ownership.zig`nin inline retain/predecrement hızlı yolu
//! (`qbeAtomicAdd`/`qbeAtomicSub`) QBE'de DÜZ, ATOMİK OLMAYAN `load→add/
//! sub→store`dur (`qbe_emit.zig`) — LLVM'de İSE GERÇEK `atomicrmw`dur
//! (`llvm_emit.zig`). `WorkerPool`nin paylaşılan `RuntimeState`si, İKİ
//! FARKLI OS iş parçacığının AYNI ARC nesnesine EŞ ZAMANLI dokunmasına
//! (work-stealing SAYESİNDE) izin VERDİĞİNDEN, BU SADECE LLVM'de
//! GÜVENLİDİR.

const std = @import("std");
const posix = std.posix;
const asap = @import("../alloc/asap.zig");
const bridge = @import("bridge.zig");
const io_mod = @import("io.zig");
const http_client = @import("../stdlib_shims/http_client.zig");
const worker_pool_mod = @import("worker_pool.zig");
const scheduler_mod = @import("scheduler.zig");

/// Faz MN.7a: `poolWorkerMain`nin (aşağıda) SADECE slot 0'da ÇAĞIRACAĞI,
/// codegen'in SENTEZLEDİĞİ `entry()` sarmalayıcısı (bkz. `compiler/
/// codegen_qbe/async_thread.zig`nin `genPoolRunExpr`i). **`entry_closure`
/// KASITLI OLARAK YOK** — `entry()` sarmalayıcısının TEK ihtiyacı
/// `rt`dir, VE bu `rt` `WorkerPool.create`in KURDUĞU, PAYLAŞILAN `rt`dir
/// (`nox_pool_run` çağrı-ANINDA HENÜZ VAR OLMAYAN bir değer — `WorkerPool.
/// create` `poolRunDriverThreadMain` İçİNDE, DAHA SONRA çalışır) — ASLA
/// `nox_pool_run`ın ÇAĞRILDIĞI ORİJİNAL programın `rt`si OLAMAZ. Bu
/// YÜZDEN `poolWorkerMain`, `entry_fn`i KENDİ (ZATEN DOĞRU, havuzun
/// paylaşılan) `rt` parametresini DOĞRUDAN `arg` OLARAK GEÇİREREK spawn
/// eder — sarmalayıcı bunu bir KAPANIŞ İşaretçisi OLARAK DEĞİL, `rt`nin
/// KENDİSİ OLARAK okur (bkz. `genPoolRunWrapper`nin `%argp`i DOĞRUDAN
/// KOPYALAMASI, `genThreadStartWrapper`nin AKSİNE `loadl` KULLANMAMASI).
const PoolRunCtx = struct {
    entry_fn: *const fn (*anyopaque) callconv(.c) i64,
    /// Faz MN.8, Bulgu A: `null` DEĞİLSE (`module_globals.count() > 0`
    /// İKEN codegen TARAFINDAN geçilir), `poolWorkerMain`nin (sibling
    /// worker'lar — SADECE ONLAR, sürücü KENDİ globals'ını `entry_fn`
    /// [`genPoolRunWrapper`] ÜZERİNDEN ZATEN halleder) KENDİ worker slotu
    /// İçİn `$nox_init_globals`/`$nox_deinit_globals`i ÇAĞIRMASINI sağlar
    /// — bkz. proje planı, Bulgu A: BUNLAR OLMADAN, çalınan bir görev
    /// bir sibling'de modül-global OKUR/YAZARSA `globals_blocks[slot]`
    /// HİÇ ilklendirilmemiş (`null`) OLDUĞUNDAN çöker.
    globals_init_fn: ?*const fn (*anyopaque) callconv(.c) i64,
    globals_deinit_fn: ?*const fn (*anyopaque) callconv(.c) i64,
};

/// `poolWorkerMain`/sürücünün ORTAK "çalıştır ve temizle" kuyruğu —
/// `entry_task` SADECE slot 0 İçİN `!= null`dır (bkz. `nox_pool_run`in
/// belge notu, sızıntı UYARISI BURADA da GEÇERLİ: `run_to_completion`
/// SONRASI, görev KESİNLİKLE tamamlanmışken, AÇIKÇA yok EDİLMELİDİR).
fn poolWorkerRunAndCleanup(rt: *anyopaque, entry_task: ?*anyopaque) void {
    const rc = bridge.nox_async_run_to_completion(rt);
    if (rc != 0) {
        // `bridge.zig`nin `nox_async_deadlock_abort`ıyla AYNI mesaj/çıkış
        // kodu — BURADAN DOĞRUDAN ÇAĞRILAMAZ (o fonksiyon `pub` DEĞİL,
        // SADECE codegen'in `$nox_async_deadlock_abort` C-ABI çağrısı
        // İçİndir) — bu YÜZDEN AYNI davranış BURADA YİNELENİR.
        std.debug.print("nox: kilitlenme (deadlock) tespit edildi — tüm görevler bloke, hiçbiri ilerleyemiyor\n", .{});
        std.process.exit(1);
    }
    if (entry_task) |t| bridge.nox_async_destroy_task(rt, t);
    // HER worker (sürücü DAHİL) KENDİ threadlocal `Scheduler`ını (ready
    // dizisi, kqueue fd) BURADA temizler — `nox_runtime_deinit`DEN AYRI,
    // HER worker İçİN GEREKLİ (bkz. modül üstü not).
    bridge.nox_async_deinit(rt);
}

/// `WorkerPool.spawnWorkers`nin `entryFn`i — SADECE slot 1..n-1 İçİn
/// (`spawnWorkers`nin KENDİ sözleşmesi GEREĞİ slot 0'ı ASLA çağırmaz,
/// bkz. `worker_pool.zig`). Bu worker'ların KENDİLERİNE AİT HİÇBİR İŞİ
/// YOKTUR — SADECE `nox_async_init`+`run()` çağırıp ÇALINABİLİR hale
/// gelirler (`worker_pool.zig`nin KANITLANMIŞ `stealTestWorkerEntry`
/// deseni, Faz MN.4/5.8).
///
/// **GERÇEK, DENEYEREK BULUNAN yarış** (BU worker'ların slot 0'dan ÖNCE
/// ÇALIŞMAYA BAŞLAMASI YÜZÜNDEN): `Scheduler.run()`, KENDİ deque'i BOŞ
/// VE kardeşlerden çalma BAŞARISIZ OLDUĞUNDA, `pool_live_count == 0`
/// İSE **HİÇ BEKLEMEDEN, TEK denemede** `return` eder (bkz. `scheduler.
/// zig`nin `run()`u, satır ~501 — `poolWideDeadlockCheck`nin 20-denemelik
/// yeniden-deneme döngüsüne BİLE GİRMEDEN). Slot 0 `entry()`i SPAWN
/// ETMEDEN ÖNCE (yani `pool_live_count` HÂLÂ 0'KEN) bu worker'lardan
/// biri run()'a ULAŞIRSA, `run()` DERHAL, TEMİZ bir şekilde DÖNER —
/// slot 0 ANLIK OLARAK ARDINDAN 200 görev spawn ETSE BİLE, BU worker
/// ARTIK ÇALINACAK HİÇBİR ŞEY GÖREMEDEN (OS iş parçacığından bile ÇIKMIŞ
/// olabilir) SONSUZA KADAR kaçırır — `zig build test`in TAM takımında
/// `stolen_count == 0` İLE TEKRARLANAN (denemesiz `yield`/`sleepMs(25)`
/// GİBİ SADECE `entry()`nin spawn'INDAN SONRAKİ gecikmelerle DÜZELMEYEN)
/// bir test başarısızlığı OLARAK GERÇEKTEN gözlemlendi. **Düzeltme,
/// `nox_pool_run`in KENDİSİNDE**: slot 0'ın `entry()`i, bu worker'lar
/// `spawnWorkers` İLE BAŞLATILMADAN ÖNCE spawn edilir (bkz. `nox_pool_
/// run`nin belge notu) — `pool_live_count` bu worker'lar İLK KEZ `run()`a
/// ULAŞTIĞINDA ZATEN `>= 1`dir, yarış YAPISAL olarak KAPATILIR.
fn poolWorkerMain(rt: *anyopaque, slot: usize, ctx: *PoolRunCtx) void {
    _ = slot;
    bridge.nox_async_init(rt);
    // Faz MN.8, Bulgu A: KENDİ worker slotu İçİn modül-global durumunu
    // ilklendir — `asap.setWorkerSlot(slot)` `WorkerPool.spawnWorkers`nin
    // trampoline'ı TARAFINDAN BU fonksiyon ÇAĞRILMADAN ÖNCE ZATEN
    // ayarlandığından (bkz. `worker_pool.zig`), `g_worker_slot` BURADA
    // DOĞRUDUR — HENÜZ hiçbir çalınmış görev ÇALIŞTIRILMADAN önce yapılır,
    // yarış YOK.
    if (ctx.globals_init_fn) |f| _ = f(rt);
    poolWorkerRunAndCleanup(rt, null);
    if (ctx.globals_deinit_fn) |f| _ = f(rt);
}

// ---- Faz MN.9.2: `--release` altında `$main`in KENDİSİNİN otomatik bir
// havuz kurması — `nox.thread.pool_run`ın AKSİNE, AYRI bir "sürücü" OS
// iş parçacığına/self-pipe'a GEREK YOK: `$main`in KENDİ OS iş parçacığının
// KORUYACAĞI bir kardeş fiber YOKTUR (program HENÜZ BAŞLAMADI), bu YÜZDEN
// `$main`in KENDİSİ DOĞRUDAN, SENKRON olarak `WorkerPool.create`/
// `spawnWorkers`/`joinAll`/`destroy`yi çağırabilir — `poolRunDriverThreadMain`nin
// TÜM İşini yapar, SADECE AYRI bir iş parçacığına SARILMADAN. ----

/// `genMainAsync`nin (`--release` altında) `$nox_runtime_init` YERİNE
/// çağırdığı İLK adım — `WorkerPool.create`in KENDİ `RuntimeState`sini
/// kurar (`$main`in OS iş parçacığı OTOMATİK olarak slot 0 OLUR, bkz.
/// `WorkerPool.create`nin KENDİ `asap.setWorkerSlot(0)` çağrısı) VE
/// `pool.rt`yi döner — `genMainAsync`nin GERİ KALANI (`$nox_os_init`/
/// `$nox_async_init`/`$nox_init_globals`/spawn `$main_body`) BUNU
/// SIRADAN `rt` OLARAK kullanmaya DEVAM eder (`nox_async_init` ZATEN
/// `state.worker_pool`un DOLU olduğunu görüp OTOMATİK `attachToPool`
/// çağırır — bkz. `bridge.zig`nin belge notu, BURADA SIFIR YENİ mantık
/// gerekir).
fn pickMainWorkerCount() usize {
    // Kaçış kapısı — küçük/gecikme-duyarlı `--release` betikleri İçİn
    // `NOX_POOL_WORKERS=1` TAM opt-out sağlar. `std.process`nin YENİ
    // `Environ` API'si `main`in KENDİ ortam-bloğunu GEREKTİRDİĞİNDEN
    // (BURADA, `main`in DIŞINDA, YOK) DOĞRUDAN `std.c.getenv` (ham libc,
    // `runtime/stdlib_shims`nin BAŞKA yerlerde ZATEN kullandığı desen)
    // kullanılır.
    if (std.c.getenv("NOX_POOL_WORKERS")) |s| {
        const slice = std.mem.span(s);
        if (std.fmt.parseInt(usize, slice, 10)) |n| {
            return std.math.clamp(n, @as(usize, 1), asap.MAX_POOL_WORKERS);
        } else |_| {}
    }
    const cpu = std.Thread.getCpuCount() catch 1;
    return std.math.clamp(cpu, @as(usize, 1), asap.MAX_POOL_WORKERS);
}

pub export fn nox_pool_main_init() callconv(.c) ?*anyopaque {
    const pool = worker_pool_mod.WorkerPool.create(std.heap.page_allocator, pickMainWorkerCount()) catch @panic("OOM: $main havuzu");
    return pool.rt;
}

/// `genMainAsync`nin `$main_body`yi (slot 0'ın GÖREVİ olarak) spawn
/// ETTİKTEN HEMEN SONRA, `$nox_async_run_to_completion`DAN ÖNCE çağırdığı
/// adım — MN.8'in KENDİ, KANITLANMIŞ SIRALAMA düzeltmesiyle TUTARLI
/// (entry görevi HER ZAMAN kardeşler BAŞLAMADAN ÖNCE spawn edilmelidir,
/// AKSİ HALDE `pool_live_count==0` GÖREN bir kardeş HEMEN döner VE o
/// görevi SONSUZA KADAR kaçırabilir).
pub export fn nox_pool_main_spawn_workers(
    rt: ?*anyopaque,
    globals_init_fn: ?*const fn (*anyopaque) callconv(.c) i64,
    globals_deinit_fn: ?*const fn (*anyopaque) callconv(.c) i64,
) callconv(.c) void {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt.?));
    const pool: *worker_pool_mod.WorkerPool = @ptrCast(@alignCast(state.worker_pool.?));
    const ctx = std.heap.page_allocator.create(PoolRunCtx) catch @panic("OOM: $main havuz ctx");
    // `entry_fn` `poolWorkerMain`nin sibling-worker dalı TARAFINDAN HİÇ
    // OKUNMAZ (SADECE `globals_init_fn`/`globals_deinit_fn` kullanılır) —
    // `$main`in KENDİ "entry"si `$main_body`dir, ZATEN driver (slot 0)
    // TARAFINDAN AYRICA spawn edilmiştir (bkz. `genMainAsync`).
    ctx.* = .{ .entry_fn = undefined, .globals_init_fn = globals_init_fn, .globals_deinit_fn = globals_deinit_fn };
    state.main_pool_ctx = ctx;
    pool.spawnWorkers(*PoolRunCtx, poolWorkerMain, ctx) catch @panic("OOM: $main havuz worker'ları");
}

/// `genMainAsync`nin `$nox_runtime_deinit` YERİNE (`--release` altında)
/// çağırdığı SON adım — `$main_body` TAMAMLANDIKTAN (VEYA deadlock İLE
/// SÜREÇ SONLANDIRILDIKTAN) SONRA çağrılır: TÜM kardeş worker'ların
/// bitmesini bekler, `main_pool_ctx`yi serbest bırakır (`pool.destroy()`
/// `state`in KENDİSİNİ FREE ETTİĞİNDEN, `state.main_pool_ctx` BUNDAN
/// ÖNCE OKUNMALI/serbest bırakılmalı — SIRA KRİTİK), SONRA `pool.destroy()`
/// (TEK, doğru `nox_runtime_deinit` çağrısı — `WorkerPool.destroy`nün
/// KENDİ sözleşmesi).
pub export fn nox_pool_main_join_and_destroy(rt: ?*anyopaque) callconv(.c) void {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt.?));
    const pool: *worker_pool_mod.WorkerPool = @ptrCast(@alignCast(state.worker_pool.?));
    pool.joinAll();
    if (state.main_pool_ctx) |c| std.heap.page_allocator.destroy(@as(*PoolRunCtx, @ptrCast(@alignCast(c))));
    pool.destroy();
}

/// Gözlem/test kancası — HANGİ worker slotunun (`asap.currentWorkerSlot()`)
/// ÇAĞIRAN fiber'ı ÇALIŞTIRDIĞINI raporlar. Faz MN.9.2'nin "sıradan
/// spawn/await, `pool_run` HİÇ ÇAĞRILMADAN, GERÇEKTEN çapraz-worker
/// çalışıyor" iddiasını `extern def` ÜZERİNDEN GERÇEK bir `.nox`
/// programından DOĞRULAMAK İçİn — kalıcı, ucuz bir birincil.
pub export fn nox_debug_worker_slot() callconv(.c) i64 {
    return @intCast(asap.currentWorkerSlot());
}

var debug_slot_seen: std.atomic.Value(u64) = .init(0);

/// ÇAĞIRAN fiber'ın O ANDA çalıştığı worker slotunu (bit olarak) PAYLAŞILAN
/// bir bitmask'a KAYDEDER — `nox_debug_worker_slot`nin BİRDEN FAZLA
/// concurrent görev ARASINDAN "kaç FARKLI worker KULLANILDI" sorusuna
/// tek bir uçtan-uca doğrulama noktasında CEVAP verebilmesi İçİn.
pub export fn nox_debug_note_slot() callconv(.c) void {
    const slot = asap.currentWorkerSlot();
    if (slot < 64) _ = debug_slot_seen.fetchOr(@as(u64, 1) << @intCast(slot), .monotonic);
}

/// `nox_debug_note_slot`nin BİRİKTİRDİĞİ bitmask'taki FARKLI worker
/// SAYISINI döner VE bitmask'ı SIFIRLAR (SONRAKİ bir ölçüm turu İçİn).
pub export fn nox_debug_distinct_count() callconv(.c) i64 {
    const mask = debug_slot_seen.swap(0, .monotonic);
    return @popCount(mask);
}

const PoolRunDriverArgs = struct {
    num_workers: usize,
    ctx: *PoolRunCtx,
    done_write_fd: posix.fd_t,
};

fn poolRunDriverThreadMain(args: *PoolRunDriverArgs) void {
    defer std.heap.page_allocator.destroy(args);

    const pool = worker_pool_mod.WorkerPool.create(std.heap.page_allocator, args.num_workers) catch @panic("OOM: nox.thread.pool_run havuzu");

    bridge.nox_async_init(pool.rt);
    // Faz MN.8, Bulgu A (İKİNCİ, DAHA DERİN yarış — İLK düzeltmeden SONRA
    // DENEYEREK bulundu): `entry_task`nin KENDİSİ de (spawn edildiği ANDA
    // KENDİ deque'ine PUSH edildiğinden, bkz. `Scheduler.spawn`nin "spawn-
    // anında çal" modeli) BİR kardeş TARAFINDAN ÇALINABİLİR — driver KENDİ
    // `run()`una BİLE ULAŞMADAN. ESKİ tasarım (`genPoolRunWrapper`nin
    // gövdesine GÖMÜLÜ `$nox_init_globals` çağrısı) BU YÜZDEN slot-0'ın
    // globals'ını KONUMA BAĞIMLI hale getiriyordu: `entry_task` BAŞKA bir
    // worker'a ÇALINIRSA, O worker'ın KENDİ (ZATEN ilklendirilmiş) slotu
    // TEKRAR ilklendirilir (ZARARSIZ AMA İSRAF), AMA slot 0 (driver)
    // ASLA `$nox_init_globals` ÇAĞIRMAZ — driver DAHA SONRA BAŞKA bir
    // ÇALINMIŞ göreve (`childFn`) ev sahipliği yaparsa `globals_blocks[0]`
    // HÂLÂ `null`dır. Düzeltme: driver KENDİ globals'ını, `entry_task`
    // SPAWN EDİLMEDEN ÖNCE, KOŞULSUZ VE DOĞRUDAN (`poolWorkerMain`nin
    // sibling'ler İçİn ZATEN yaptığı AYNI desen) ilklendirir — ARTIK
    // `entry()`nin fiber'ının NEREDE çalıştığından TAMAMEN BAĞIMSIZ.
    // `genPoolRunWrapper` BU YÜZDEN ARTIK `$nox_init_globals`/`$nox_
    // deinit_globals` ÇAĞIRMAZ (bkz. onun belge notu) — BURADAKİ VE
    // `poolWorkerMain`daki çağrılarla ÇAKIŞIP ÇİFT-İLKLENDİRME (VE bir
    // ÖNCEKİ bloğun SIZMASI — `$nox_init_globals` KOŞULSUZ `nox_alloc`
    // yapar, İDEMPOTENT DEĞİLDİR) YARATMAMASI İçİn.
    if (args.ctx.globals_init_fn) |f| _ = f(pool.rt);

    // KRİTİK SIRA (bkz. `poolWorkerMain`nin belge notu, GERÇEK bir yarış
    // BULUNUP burada düzeltildi): slot 0'ın `entry()`i, DİĞER worker'lar
    // (`spawnWorkers`) BAŞLATILMADAN ÖNCE, BURADA spawn edilir — `pool_
    // live_count`, HERHANGİ bir kardeş İLK `run()`una ULAŞTIĞINDA ZATEN
    // `>= 1`dir (`WorkerPool.create` sürücüyü ZATEN slot 0'a BAĞLADI).
    const entry_task = bridge.nox_async_spawn(pool.rt, args.ctx.entry_fn, pool.rt) orelse @panic("OOM: nox.thread.pool_run entry spawn");

    pool.spawnWorkers(*PoolRunCtx, poolWorkerMain, args.ctx) catch @panic("OOM: nox.thread.pool_run worker'ları");

    poolWorkerRunAndCleanup(pool.rt, entry_task);
    if (args.ctx.globals_deinit_fn) |f| _ = f(pool.rt);
    pool.joinAll();
    pool.destroy();

    http_client.signalSelfPipe(args.done_write_fd);
    http_client.closeFd(args.done_write_fd);
}

/// `nox.thread.pool_run(num_workers, entry)`in çağrı-sitesi ÇAĞIRDIĞI
/// C-ABI giriş noktası (bkz. `genPoolRunExpr`). `entry_fn`nin KENDİSİ
/// codegen'in sentezlediği `genPoolRunWrapper` çıktısıdır — KAPANIŞ
/// (`entry_closure`) KASITLI OLARAK YOK (bkz. `PoolRunCtx`nin belge
/// notu — `poolWorkerMain` `entry_fn`i KENDİ, HAVUZUN paylaşılan `rt`sini
/// `arg` OLARAK GEÇİREREK spawn eder, ÇAĞRI-ANINDA henüz VAR OLMAYAN bir
/// değeri BURADAN taşımaya GEREK YOK).
/// Faz MN.9.3: `rt` ZATEN paylaşılan bir havuza AİTSE (bkz. proje planı
/// Bölüm 2 — `$main`in MN.9.2'de kurduğu OTOMATİK havuz, YA DA dıştaki BİR
/// `pool_run`/`pool_serve`nin İçİNDEN çağrılan İç İçe bir çağrı) `nox_pool_
/// run` YENİ bir OS iş parçacığı/havuz İNŞA ETMEZ — `entry_fn`i AKTİF
/// havuzda SIRADAN bir görev OLARAK spawn edip await EDER (`bridge.nox_
/// async_spawn`/`nox_async_await`, `poolRunDriverThreadMain`nin `entry_task`
/// deseniyle AYNI, SADECE ÇAĞIRAN fiber'ın KENDİ scheduler'ında). `globals_
/// init_fn`/`globals_deinit_fn` BURADA ÇAĞRILMAZ (ARTIK GEREKMEZ — AYNI
/// `globals_blocks[slot]` ZATEN VAR, `$main`nin/dış havuzun KENDİ init'i
/// TARAFINDAN ZATEN kuruldu). `num_workers` SESSİZCE YOK SAYILIR (havuzun
/// boyutu ZATEN SABİTLENDİ) — SERT bir hata DEĞİL, bir uyarı BİLE DEĞİL:
/// Bölüm 1 SONRASI HER `--release` programının `pool_run`ı `$main`nin
/// KENDİ otomatik havuzunun İçİNDEN ÇAĞRILDIĞINDAN (`moduleUsesAsync`,
/// `nox.thread.pool_run` çağrısının KENDİSİNİ BİLE "async kullanımı"
/// SAYAR — bkz. `exprUsesAsync`nin `matchIntrinsicKind` dalı), BU YOL
/// İSTİSNA DEĞİL, KURAL haline geldi — HER derlenmiş programda "uyarı"
/// basmak GÜRÜLTÜDEN başka bir şey OLMAZDI (VE `tests/compat/http_serve_
/// multicore_pool_golden_test.zig`nin "hiçbir stderr çıktısı=sızıntı YOK"
/// KANITINI, doğrudan İLGİSİZ bir nedenle, KIRARDI — GERÇEKTEN denenip
/// bulundu).
fn poolRunFlattened(rt_ptr: *anyopaque, entry_fn: *const fn (*anyopaque) callconv(.c) i64) i32 {
    const t = bridge.nox_async_spawn(rt_ptr, entry_fn, rt_ptr) orelse {
        std.debug.print("nox: nox.thread.pool_run: OOM (ic-ice cagri)\n", .{});
        std.process.exit(1);
    };
    _ = bridge.nox_async_await(rt_ptr, t);
    bridge.nox_async_destroy_task(rt_ptr, t);
    return 0;
}

pub export fn nox_pool_run(
    rt: ?*anyopaque,
    num_workers: i64,
    entry_fn: *const fn (*anyopaque) callconv(.c) i64,
    globals_init_fn: ?*const fn (*anyopaque) callconv(.c) i64,
    globals_deinit_fn: ?*const fn (*anyopaque) callconv(.c) i64,
) callconv(.c) i32 {
    if (rt) |rt_ptr| {
        const state: *asap.RuntimeState = @ptrCast(@alignCast(rt_ptr));
        if (state.worker_pool != null) return poolRunFlattened(rt_ptr, entry_fn);
    }
    // Havuzsuz (ya da `rt == null` — bkz. `pool_bridge.zig`nin KENDİ birim
    // testleri) çağrı — BİREBİR ESKİ (MN.9.3 ÖNCESİ) davranış: `rt`
    // BİLİNÇLİ olarak KULLANILMAZ (bkz. `nox_thread_spawn`nin AYNI notu:
    // havuzun KENDİ, YENİ `rt`si `WorkerPool.create` TARAFINDAN kurulur,
    // ÇAĞIRANIN `rt`sine BAĞIMLI DEĞİLDİR).

    // `WorkerPool.create`in KENDİ `std.debug.assert`i ReleaseFast'ta
    // SESSİZCE ATLANIR — BU giriş noktası KULLANICI-KONTROLLÜ (bir Nox
    // programının ÇALIŞMA-ZAMANI değeri) bir `num_workers` ALDIĞINDAN,
    // `assert`e GÜVENİLEMEZ, GERÇEK bir çalışma-zamanı doğrulaması GEREKİR.
    if (num_workers < 1 or num_workers > asap.MAX_POOL_WORKERS) {
        std.debug.print("nox: nox.thread.pool_run: num_workers 1..{d} araliginda olmalidir (verilen: {d})\n", .{ asap.MAX_POOL_WORKERS, num_workers });
        std.process.exit(1);
    }

    const fds = http_client.makeSelfPipe() orelse return 1;

    const ctx = std.heap.page_allocator.create(PoolRunCtx) catch return 1;
    ctx.* = .{ .entry_fn = entry_fn, .globals_init_fn = globals_init_fn, .globals_deinit_fn = globals_deinit_fn };

    const driver_args = std.heap.page_allocator.create(PoolRunDriverArgs) catch {
        std.heap.page_allocator.destroy(ctx);
        http_client.closeFd(fds[0]);
        http_client.closeFd(fds[1]);
        return 1;
    };
    driver_args.* = .{ .num_workers = @intCast(num_workers), .ctx = ctx, .done_write_fd = fds[1] };

    const driver_thread = std.Thread.spawn(.{}, poolRunDriverThreadMain, .{driver_args}) catch {
        std.heap.page_allocator.destroy(driver_args);
        std.heap.page_allocator.destroy(ctx);
        http_client.closeFd(fds[0]);
        http_client.closeFd(fds[1]);
        return 1;
    };
    driver_thread.detach();

    // `nox_thread_join`ın AYNI iki-modlu bekleme deseni (bkz. modül üstü
    // not) — bir Nox FİBER İçİNDEYSEK reaktör ÜZERİNDEN askıya alınır
    // (KARDEŞ fiber'lar BU SIRADA İLERLEYEBİLİR), fiber DIŞINDAYSAK
    // sıradan bloklayan bir `read()` YETERLİDİR.
    if (bridge.currentFiberScheduler()) |scheduler| {
        var buf: [1]u8 = undefined;
        _ = io_mod.nonBlockingRead(scheduler, fds[0], &buf) catch {};
    } else {
        var buf: [1]u8 = undefined;
        http_client.readSelfPipe(fds[0], &buf);
    }
    http_client.closeFd(fds[0]);

    std.heap.page_allocator.destroy(ctx);
    return 0;
}

// ---- Faz MN.7b: `nox_pool_serve` — `nox.http.serve_multicore`nin havuz-
// tabanlı lowering'i İçİn. `nox_pool_run`dan İKİ yapısal FARKI VAR:
// (1) SADECE slot 0 DEĞİL, **HER** slot (0..n-1) KENDİ `entry_fn`ini
// KENDİ görevi OLARAK spawn edip çalıştırır — bugünkü `$nox_thread_spawn`
// tabanlı `serve_multicore`nin "HER worker KENDİ accept-döngüsünü
// çalıştırır" dışa-görünümüyle AYNI, AMA artık TÜM worker'lar TEK bir
// paylaşılan `WorkerPool`a BAĞLI OLDUĞUNDAN, bir handler İçİNDE spawn
// edilen alt-görevler ARTIK BAŞKA bir worker'a ÇALINABİLİR. `worker_
// pool.zig`nin `spawnWorkers` sözleşmesi (`entryFn` HER slot İçİN AYNI
// çağrılabilir, slot 0 DAHİL — bkz. proje planı Tasarım #4) BUNU
// DOĞRUDAN destekler, `worker_pool.zig`ye HİÇBİR değişiklik GEREKMEZ.
// (2) `entry_fn` (accept-döngüsü) HER worker İçİN AYNI bir çalışma-
// zamanı değerine (dinlenen `fd`, TLS varyantında `FdTlsPayload*` — bkz.
// `genHttpServeMulticoreWorker`) ihtiyaç duyar — `nox_pool_run`nin
// "entry SIFIR parametre alır" modeli BURADA YETERSİZ. Bu YÜZDEN
// `nox_pool_serve`, `nox_thread_spawn`ın KANITLANMIŞ `{rt, payload}`
// closure ŞEKLİNİ (bkz. `thread_bridge.zig`nin `ThreadEntryClosure`ı)
// YENİDEN kullanır: TÜM worker'lar (0 DAHİL) `entry_fn`e AYNI, TEK
// (havuzun `WorkerPool.create()`i SONRASI, yani `rt` BİLİNDİKTEN SONRA
// İNŞA EDİLEN, SALT-OKUNUR) closure işaretçisini geçirir. --------------

/// `nox_pool_serve`nin TÜM worker'larının PAYLAŞTIĞI, TEK (havuz başına
/// BİR KEZ İNŞA EDİLEN) closure — `ThreadEntryClosure` İLE AYNI `{rt,
/// payload}` şekli, `genHttpServeMulticoreWorker`nin `%argp`den `loadl`
/// İLE okuduğu düzenle BİREBİR UYUMLU olması İçİn (codegen'in YENİ LLVM-
/// yolu sarmalayıcısı, bkz. MN.7b.2, AYNI iki-`loadl` desenini izler).
const PoolServeClosure = struct {
    rt: *anyopaque,
    payload: ?*anyopaque,
};

const PoolServeCtx = struct {
    entry_fn: *const fn (*anyopaque) callconv(.c) i64,
    /// `nox_pool_serve` ÇAĞRILDIĞI ANDA ZATEN BİLİNEN, HAM (TEK, tüm
    /// worker'lar İçİN AYNI) değer — ör. dinlenen `fd` (bir `usize`e
    /// `@ptrFromInt` İLE gömülmüş) ya da `FdTlsPayload*`.
    payload: ?*anyopaque,
    /// `poolServeDriverThreadMain`nin `WorkerPool.create()` SONRASI
    /// (yani `pool.rt` BİLİNDİKTEN SONRA) doldurduğu, TÜM worker'ların
    /// PAYLAŞTIĞI TEK closure — `spawnWorkers`/slot-0 çağrısı BUNU
    /// DOLDURULMADAN ASLA BAŞLAMAZ (program SIRASI GARANTİ eder), bu
    /// YÜZDEN kilide GEREK YOK.
    closure: ?*PoolServeClosure = null,
};

const PoolServeDriverArgs = struct {
    num_workers: usize,
    ctx: *PoolServeCtx,
    done_write_fd: posix.fd_t,
};

fn poolServeWorkerMain(rt: *anyopaque, slot: usize, ctx: *PoolServeCtx) void {
    _ = slot;
    bridge.nox_async_init(rt);
    const entry_task = bridge.nox_async_spawn(rt, ctx.entry_fn, ctx.closure.?) orelse @panic("OOM: nox.http.serve_multicore entry spawn");
    poolWorkerRunAndCleanup(rt, entry_task);
}

fn poolServeDriverThreadMain(args: *PoolServeDriverArgs) void {
    defer std.heap.page_allocator.destroy(args);

    const pool = worker_pool_mod.WorkerPool.create(std.heap.page_allocator, args.num_workers) catch @panic("OOM: nox.http.serve_multicore havuzu");

    const closure = std.heap.page_allocator.create(PoolServeClosure) catch @panic("OOM: nox.http.serve_multicore closure");
    closure.* = .{ .rt = pool.rt, .payload = args.ctx.payload };
    args.ctx.closure = closure;

    // `nox_pool_run`nin AKSİNE: slot 0'ın KENDİ görevi de `spawnWorkers`
    // İLE AYNI ŞEKİLDE spawn edilir — TÜM worker'lar (0 DAHİL) `run()`a
    // KENDİ görevleriyle GİRER, `pool_live_count` HİÇBİR worker İçİN
    // ASLA 0'DAN başlamaz (bkz. `poolWorkerMain`nin belge notundaki
    // "slot 0'DAN ÖNCE başlayan kardeş" yarışı — BURADA HER slot KENDİ
    // spawn'ını KENDİSİ yaptığından, o yarış YAPISAL olarak zaten YOK).
    bridge.nox_async_init(pool.rt);
    const entry_task = bridge.nox_async_spawn(pool.rt, args.ctx.entry_fn, closure) orelse @panic("OOM: nox.http.serve_multicore entry spawn");

    pool.spawnWorkers(*PoolServeCtx, poolServeWorkerMain, args.ctx) catch @panic("OOM: nox.http.serve_multicore worker'ları");

    poolWorkerRunAndCleanup(pool.rt, entry_task);
    pool.joinAll();
    pool.destroy();
    std.heap.page_allocator.destroy(closure);

    http_client.signalSelfPipe(args.done_write_fd);
    http_client.closeFd(args.done_write_fd);
}

/// `broadcastRunOnEachWorker`nin KENDİ ("yayın") tamamlanma muhasebesi —
/// `n` worker'ın HEPSİ `entry_fn`i BİTİRDİĞİNDE (pratikte HİÇBİR ZAMAN,
/// bkz. `nox_pool_serve`nin belge notu — accept döngüsü SONSUZA KADAR
/// döner) `done_write_fd`ye SİNYAL gönderir.
const BroadcastCtx = struct {
    remaining: std.atomic.Value(usize),
    done_write_fd: posix.fd_t,
    entry_fn: *const fn (*anyopaque) callconv(.c) i64,
    closure: *PoolServeClosure,

    fn runOne(erased: *anyopaque) callconv(.c) i64 {
        const self: *BroadcastCtx = @ptrCast(@alignCast(erased));
        _ = self.entry_fn(self.closure);
        if (self.remaining.fetchSub(1, .acq_rel) == 1) {
            http_client.signalSelfPipe(self.done_write_fd);
        }
        return 0;
    }
};

/// Faz MN.9.3: `nox_pool_serve`nin `rt` ZATEN paylaşılan bir havuza AİTSE
/// (bkz. `$main`in MN.9.2'de otomatik kurduğu havuz) aldığı yol — YENİ OS
/// iş parçacıkları AÇMAK YERİNE `entry_fn`in BİR KOPYASINI AKTİF havuzun
/// HER worker slotuna (ÇAĞIRANIN KENDİSİ DAHİL) `scheduler_mod.
/// spawnToForeignScheduler` İLE ENJEKTE eder — `worker_pool.zig`nin
/// `spawnWorkers`i GİBİ YENİ OS iş parçacığı BAŞLATMAZ, SADECE MEVCUT
/// worker'ların HER BİRİNİN KENDİ `ready` listesine BİR fiber EKLER
/// (bkz. `spawnToForeignScheduler`nin belge notu — bu ZATEN ÇALIŞAN, ZATEN
/// `run()`unda olan worker'lar İçİn TAMAMEN GÜVENLİDİR).
/// `scheduler.zig`nin ÖZEL `sleepMs`iyle AYNI desen (`std.Thread`da bir
/// `sleep` metodu YOK, bkz. Zig 0.16.0 — `std.c.nanosleep` DOĞRUDAN
/// kullanılır) — `poolServeFlattened`nin KISA "worker ZATEN hazır mı"
/// bekleme döngüsü İçİn.
fn sleepOneMs() void {
    const ts: std.c.timespec = .{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&ts, null);
}

// Faz MN.9.3: `poolRunFlattened`nin AYNI gerekçesiyle (bkz. onun belge
// notu) — `num_workers` BURADA da SESSİZCE YOK SAYILIR, HİÇBİR stderr
// uyarısı BASILMAZ (BU YOL, Bölüm 1 SONRASI, HER `--release` `serve_
// multicore` çağrısının KURALIDIR, İSTİSNASI DEĞİL).
fn poolServeFlattened(rt_ptr: *anyopaque, num_workers: i64, entry_fn: *const fn (*anyopaque) callconv(.c) i64, payload: ?*anyopaque) i32 {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt_ptr));
    const pool: *worker_pool_mod.WorkerPool = @ptrCast(@alignCast(state.worker_pool.?));
    // KRİTİK (GERÇEK bir hata, DENEYEREK bulundu — bkz. plan dosyasının
    // "Hatalar" bölümü): `n` ÇAĞIRANIN İSTEDİĞİ `num_workers`e (havuzun
    // TAMAMINA DEĞİL) SINIRLANMALIDIR. `n = pool.workers.len` (havuzun
    // TÜM boyutu, `pickMainWorkerCount()`nin CPU-sayısı varsayılanıyla
    // GENELDE `num_workers`DEN ÇOK DAHA BÜYÜK) KULLANILSAYDI, `max_
    // connections > 0` OLAN bir accept-döngüsü kopyası HER BİR FAZLA
    // worker'a da enjekte edilirdi — O worker'lar ASLA GELMEYECEK bir
    // bağlantıyı SONSUZA KADAR bekler, `pool_live_count` ASLA 0'A
    // İNMEZ, SÜREÇ ASLA ÇIKMAZ (GERÇEKTEN, `lldb`nin TÜM worker
    // iş parçacıklarının `kevent`de bloke olduğunu gösteren bir
    // backtrace'İYLE doğrulandı).
    const n: usize = @min(@as(usize, @intCast(num_workers)), pool.workers.len);

    const closure = std.heap.page_allocator.create(PoolServeClosure) catch return 1;
    defer std.heap.page_allocator.destroy(closure);
    closure.* = .{ .rt = rt_ptr, .payload = payload };

    const fds = http_client.makeSelfPipe() orelse return 1;
    defer http_client.closeFd(fds[1]);

    const bctx = std.heap.page_allocator.create(BroadcastCtx) catch {
        http_client.closeFd(fds[0]);
        return 1;
    };
    defer std.heap.page_allocator.destroy(bctx);
    bctx.* = .{ .remaining = .init(n), .done_write_fd = fds[1], .entry_fn = entry_fn, .closure = closure };

    var i: usize = 0;
    while (i < n) : (i += 1) {
        // `pool_scheduler_ptrs[i]`, O worker'ın KENDİ OS iş parçacığı
        // `nox_async_init`in `attachToPool`ını TAMAMLADIĞINDA yazılır —
        // `spawnWorkers`in TRAMPOLİNİ (bkz. `WorkerPool.spawnWorkers`)
        // BUNU HEMEN ÇAĞIRIR AMA program SIRASI (`$main`nin `spawn_workers`
        // çağrısı `$main_body` SPAWN EDİLDİKTEN SONRA yapılır — bkz. MN.9.2)
        // BURAYA ULAŞILDIĞINDA KISA bir başlangıç penceresi HALA MÜMKÜN
        // olabileceğinden, KISA bir "hazır olana KADAR bekle" döngüsü
        // GEREKİR.
        var sched_ptr: ?*anyopaque = null;
        while (sched_ptr == null) {
            sched_ptr = state.pool_scheduler_ptrs[i].load(.acquire);
            if (sched_ptr == null) sleepOneMs();
        }
        const sched: *scheduler_mod.Scheduler = @ptrCast(@alignCast(sched_ptr.?));
        scheduler_mod.spawnToForeignScheduler(sched, BroadcastCtx.runOne, bctx) catch @panic("OOM: nox_pool_serve yayını");
    }

    if (bridge.currentFiberScheduler()) |scheduler| {
        var buf: [1]u8 = undefined;
        _ = io_mod.nonBlockingRead(scheduler, fds[0], &buf) catch {};
    } else {
        var buf: [1]u8 = undefined;
        http_client.readSelfPipe(fds[0], &buf);
    }
    http_client.closeFd(fds[0]);
    return 0;
}

/// `nox.http.serve_multicore`nin havuz-tabanlı (`--release`) lowering'i
/// TARAFINDAN üretilen çağrının hedefi (bkz. MN.7b.2, `http_intrinsics.
/// zig`). Sözleşme `nox_pool_run` İLE BÜYÜK ÖLÇÜDE AYNI (aynı self-pipe
/// bekleme deseni, aynı `num_workers` doğrulaması, aynı v1 sınırlamaları)
/// — İKİ FARK: (1) YUKARIDAKİ "HER slot KENDİ entry'sini spawn eder"
/// davranışı, (2) `entry_fn`e HER worker'da AYNI `payload`ı taşıyan
/// EK bir parametre. **ÇAĞIRAN fiber, `entry_fn` TÜM worker'larda
/// (dolayısıyla TÜM accept-döngüleri) SONLANANA KADAR bloke KALIR** —
/// normal kullanımda `entry_fn` (accept döngüsü) ASLA kendiliğinden
/// dönmez, bu YÜZDEN `nox_pool_serve` pratikte programın YAŞAM SÜRESİ
/// boyunca DÖNMEZ (`nox.http.serve`nin KENDİSİ de AYNI şekilde
/// SONSUZA KADAR bloke eder).
///
/// Faz MN.9.3: `rt` ZATEN paylaşılan bir havuza AİTSE (bkz. `$main`in
/// otomatik kurduğu havuz), YENİ OS iş parçacıkları AÇAN eski yol YERİNE
/// `poolServeFlattened`e (yukarısı) YÖNLENDİRİLİR.
pub export fn nox_pool_serve(
    rt: ?*anyopaque,
    num_workers: i64,
    entry_fn: *const fn (*anyopaque) callconv(.c) i64,
    payload: ?*anyopaque,
) callconv(.c) i32 {
    if (num_workers < 1 or num_workers > asap.MAX_POOL_WORKERS) {
        std.debug.print("nox: nox.http.serve_multicore: num_workers 1..{d} araliginda olmalidir (verilen: {d})\n", .{ asap.MAX_POOL_WORKERS, num_workers });
        std.process.exit(1);
    }

    if (rt) |rt_ptr| {
        const state: *asap.RuntimeState = @ptrCast(@alignCast(rt_ptr));
        if (state.worker_pool != null) return poolServeFlattened(rt_ptr, num_workers, entry_fn, payload);
    }

    const fds = http_client.makeSelfPipe() orelse return 1;

    const ctx = std.heap.page_allocator.create(PoolServeCtx) catch return 1;
    ctx.* = .{ .entry_fn = entry_fn, .payload = payload };

    const driver_args = std.heap.page_allocator.create(PoolServeDriverArgs) catch {
        std.heap.page_allocator.destroy(ctx);
        http_client.closeFd(fds[0]);
        http_client.closeFd(fds[1]);
        return 1;
    };
    driver_args.* = .{ .num_workers = @intCast(num_workers), .ctx = ctx, .done_write_fd = fds[1] };

    const driver_thread = std.Thread.spawn(.{}, poolServeDriverThreadMain, .{driver_args}) catch {
        std.heap.page_allocator.destroy(driver_args);
        std.heap.page_allocator.destroy(ctx);
        http_client.closeFd(fds[0]);
        http_client.closeFd(fds[1]);
        return 1;
    };
    driver_thread.detach();

    if (bridge.currentFiberScheduler()) |scheduler| {
        var buf: [1]u8 = undefined;
        _ = io_mod.nonBlockingRead(scheduler, fds[0], &buf) catch {};
    } else {
        var buf: [1]u8 = undefined;
        http_client.readSelfPipe(fds[0], &buf);
    }
    http_client.closeFd(fds[0]);

    std.heap.page_allocator.destroy(ctx);
    return 0;
}

// ---- Birim testleri (Faz MN.7a) -----------------------------------------

test "nox_pool_run: GERÇEK spawn/await İÇEREN bir entry, TÜM sonuçlar doğru VE kanıtlanmış çapraz-worker çalma" {
    const testing = std.testing;

    // 200'DEN 30'a DÜŞÜRÜLDÜ (Faz MN.7a, DENEYEREK): `worker_pool.zig`nin
    // `stealTestWorkerEntry`si GİBİ "TÜMÜNÜ ÖNCE spawn et, SONRA sırayla
    // await et" deseni, 200 SÜPER-triviyal görevle `poolWideDeadlockCheck`nin
    // (bkz. `scheduler.zig`, YAKLAŞIK/tam-olmayan bir algoritma — KENDİ
    // belge notu) KALAN, DAR bir yarış penceresini (`hasLocalReadyWork`
    // düzeltmesinden SONRA BİLE) ARA SIRA (ReleaseFast'ta gözlemlendi)
    // TETİKLEYEBİLİYORDU — bu, GERÇEK `.nox` programlarının (`spawn`/
    // `await`in HER YİNELEMEDE BİRLİKTE kullanıldığı, DOĞAL yield
    // noktaları OLAN GERÇEK kullanım deseni, bkz. `pool_run_repro.nox`,
    // 10/10 ÇALIŞTIRMADA + `pool_run_mini3.nox`, 20/20 ÇALIŞTIRMADA
    // SAĞLAM) KARŞILAŞMAYACAĞI, YAPAY olarak DAHA AĞIR bir stres deseni.
    // 30 görev, 4 worker'da çapraz-worker çalmayı KANITLAMAYA YETERLİ
    // KALIRKEN bu KENAR durumunu PRATİKTE tetiklemez.
    const STEAL_TEST_N_TASKS = 30;
    const NOT_RUN: usize = 999;

    const Shared = struct {
        executed_by: [STEAL_TEST_N_TASKS]std.atomic.Value(usize) = @splat(std.atomic.Value(usize).init(NOT_RUN)),
        tasks_done: std.atomic.Value(bool) = .init(false),
    };
    var shared = Shared{};

    const ChildArg = struct { index: usize, shared: *Shared };
    var child_args: [STEAL_TEST_N_TASKS]ChildArg = undefined;

    const Fn = struct {
        fn child(arg: *anyopaque) callconv(.c) i64 {
            const a: *ChildArg = @ptrCast(@alignCast(arg));
            a.shared.executed_by[a.index].store(asap.currentWorkerSlot(), .seq_cst);
            return @intCast(a.index);
        }
    };

    // `entry_fn`in imzası `fn(*anyopaque) callconv(.c) i64` OLDUĞUNDAN
    // (SADECE `rt` alır — gerçek codegen'in `RT_PARAM`-only kapanışıyla
    // AYNI şekil), `shared`/`child_args`e erişim İçİN modül-seviyesi bir
    // işaretçi KULLANILIR (test SADECE Zig-seviyesindedir).
    var tasks: [STEAL_TEST_N_TASKS]?*anyopaque = @splat(null);

    const Global = struct {
        var shared_ptr: *Shared = undefined;
        var child_args_ptr: *[STEAL_TEST_N_TASKS]ChildArg = undefined;
        var tasks_ptr: *[STEAL_TEST_N_TASKS]?*anyopaque = undefined;

        fn realEntry(rt: *anyopaque) callconv(.c) i64 {
            var i: usize = 0;
            while (i < STEAL_TEST_N_TASKS) : (i += 1) {
                child_args_ptr[i] = .{ .index = i, .shared = shared_ptr };
                tasks_ptr[i] = bridge.nox_async_spawn(rt, Fn.child, &child_args_ptr[i]).?;
            }
            // NOT (GERÇEK bir yarışın KENDİSİ `nox_pool_run`ın İçİNDE
            // düzeltildiği İçİn ARTIK burada bir `yield`/`sleep`e GEREK
            // YOK — bkz. `poolWorkerMain`nin belge notu): kardeş worker'lar
            // `entry()` SPAWN EDİLDİKTEN SONRA başlatıldığından (`pool_
            // live_count >= 1` HER ZAMAN GARANTİLİ), erken-başlayan bir
            // kardeşin `run()`u YANLIŞLIKLA "iş yok" SANIP DERHAL dönme
            // riski YAPISAL olarak ORTADAN KALKTI.
            // `nox_async_spawn`ın döndürdüğü `Task` struct'ı OTOMATİK
            // serbest bırakılmaz (bkz. proje belleği "Task[T]/Channel[T]/
            // vb. yeniden-atama sızıntısı düzeltmesi" — BİREBİR AYNI sınıf)
            // — `await` + `destroy` BURADA, `rt` HÂLÂ GEÇERLİYKEN yapılmalı
            // (`nox_pool_run` DÖNDÜKTEN SONRA `rt` ÇOKTAN yıkılmış OLUR).
            i = 0;
            while (i < STEAL_TEST_N_TASKS) : (i += 1) {
                _ = bridge.nox_async_await(rt, tasks_ptr[i]);
                bridge.nox_async_destroy_task(rt, tasks_ptr[i]);
            }
            shared_ptr.tasks_done.store(true, .release);
            return 0;
        }
    };
    Global.tasks_ptr = &tasks;
    Global.shared_ptr = &shared;
    Global.child_args_ptr = &child_args;

    const rc = nox_pool_run(null, 4, Global.realEntry, null, null);
    try testing.expectEqual(@as(i32, 0), rc);

    try testing.expect(shared.tasks_done.load(.acquire));
    var stolen_count: usize = 0;
    var i: usize = 0;
    while (i < STEAL_TEST_N_TASKS) : (i += 1) {
        const by = shared.executed_by[i].load(.seq_cst);
        try testing.expect(by != NOT_RUN);
        if (by != 0) stolen_count += 1;
    }
    // Kanıt: EN AZ bir görev worker 0 DIŞINDA bir worker TARAFINDAN
    // ÇALIŞTIRILDI.
    try testing.expect(stolen_count > 0);
}

test "nox_pool_serve: TÜM slotlar (0 DAHİL) KENDİ entry'sini ÇALIŞTIRIR + KENDİ görevlerini spawn/await eder" {
    const testing = std.testing;

    const SERVE_N_WORKERS = 4;
    const CHILDREN_PER_WORKER = 5;

    const Shared = struct {
        entry_ran: [SERVE_N_WORKERS]std.atomic.Value(bool) = @splat(std.atomic.Value(bool).init(false)),
    };
    var shared = Shared{};

    const ChildArg = struct { value: i64 };
    // HER slot KENDİ satırını (`[slot][..]`) SADECE KENDİ iş parçacığından
    // yazıp okuduğundan (`entry_fn` HER worker'da AYRI ÇAĞRILIR) — çapraz-
    // worker yarış YOK, kilide GEREK YOK.
    var child_args: [SERVE_N_WORKERS][CHILDREN_PER_WORKER]ChildArg = undefined;
    var tasks: [SERVE_N_WORKERS][CHILDREN_PER_WORKER]?*anyopaque = @splat(@splat(null));

    const ChildFn = struct {
        fn run(arg: *anyopaque) callconv(.c) i64 {
            const a: *ChildArg = @ptrCast(@alignCast(arg));
            return a.value * 2;
        }
    };

    const PAYLOAD_MARKER: usize = 0xC0FFEE;

    const Global = struct {
        var shared_ptr: *Shared = undefined;
        var child_args_ptr: *[SERVE_N_WORKERS][CHILDREN_PER_WORKER]ChildArg = undefined;
        var tasks_ptr: *[SERVE_N_WORKERS][CHILDREN_PER_WORKER]?*anyopaque = undefined;
        var payload_mismatch: std.atomic.Value(bool) = .init(false);

        // `arg`, `nox_thread_spawn`ın `ThreadEntryClosure`ıyla AYNI şekle
        // sahip `PoolServeClosure` İşaretçisidir — `entry_fn`in TÜM
        // worker'larda AYNI `payload`ı GÖRDÜĞÜNÜ (KANIT: `PAYLOAD_MARKER`)
        // DOĞRULAR.
        fn serveEntry(arg: *anyopaque) callconv(.c) i64 {
            const closure: *PoolServeClosure = @ptrCast(@alignCast(arg));
            const rt = closure.rt;
            if (@intFromPtr(closure.payload) != PAYLOAD_MARKER) {
                payload_mismatch.store(true, .seq_cst);
            }

            const slot = asap.currentWorkerSlot();
            shared_ptr.entry_ran[slot].store(true, .seq_cst);

            var i: usize = 0;
            while (i < CHILDREN_PER_WORKER) : (i += 1) {
                child_args_ptr[slot][i] = .{ .value = @intCast(i) };
                tasks_ptr[slot][i] = bridge.nox_async_spawn(rt, ChildFn.run, &child_args_ptr[slot][i]).?;
            }
            i = 0;
            var sum: i64 = 0;
            while (i < CHILDREN_PER_WORKER) : (i += 1) {
                sum += bridge.nox_async_await(rt, tasks_ptr[slot][i]);
                bridge.nox_async_destroy_task(rt, tasks_ptr[slot][i]);
            }
            return sum;
        }
    };
    Global.shared_ptr = &shared;
    Global.child_args_ptr = &child_args;
    Global.tasks_ptr = &tasks;

    const rc = nox_pool_serve(null, SERVE_N_WORKERS, Global.serveEntry, @ptrFromInt(PAYLOAD_MARKER));
    try testing.expectEqual(@as(i32, 0), rc);

    try testing.expect(!Global.payload_mismatch.load(.seq_cst));
    var slot: usize = 0;
    while (slot < SERVE_N_WORKERS) : (slot += 1) {
        try testing.expect(shared.entry_ran[slot].load(.seq_cst));
    }
}

test "nox_pool_run: Faz MN.8 Bulgu A - sibling worker'lar globals_init_fn ile KENDİ slotu İçİn ilklendirilir, ÇALINAN bir görev doğru bloğu okur" {
    const testing = std.testing;

    const N_WORKERS = 4;
    const N_TASKS = 30; // AYNI gerekçe, bkz. STEAL_TEST_N_TASKS'in belge notu.

    // Bu test, `genPoolRunGlobalsInitWrapper`/`genPoolRunGlobalsDeinitWrapper`nin
    // (compiler/codegen_qbe/async_thread.zig) GERÇEK codegen'i OLMADAN,
    // AYNI C-ABI sözleşmesini (`?*const fn(*anyopaque) callconv(.c) i64`)
    // ELLE-YAZILMIŞ Zig fonksiyonlarıYLA egzersiz eder — `worker_pool.zig`nin
    // KENDİ testlerinin "sarmalayıcı YERİNE GEÇEN düz Zig fonksiyonları"
    // deseniyle TUTARLI. HER worker'ın (0 DAHİL) `globals_blocks[slot]`ına
    // `0x1000 + slot` benzersiz bir "işaret" değeri YAZILIR (`globalsInitFn`)
    // — bir görev HANGİ worker'da ÇALIŞIRSA ÇALIŞSIN (spawn edildiği worker
    // MI, ÇALINDIĞI worker MI FARK ETMEZ), `nox_globals_get`in KENDİ worker
    // slotuna karşılık gelen DOĞRU işareti OKUMASI GEREKİR — Bulgu A
    // DÜZELTİLMEDEN ÖNCE, sibling worker'ların `globals_blocks[slot]`ı HİÇ
    // yazılmadığından bu `null` DÖNERDİ (bu testin YAZILMA GEREKÇESİ).
    const Global = struct {
        var mismatch_count: std.atomic.Value(usize) = .init(0);
        var stolen_count: std.atomic.Value(usize) = .init(0);

        fn globalsInitFn(rt: *anyopaque) callconv(.c) i64 {
            const slot = asap.currentWorkerSlot();
            asap.nox_globals_set(rt, @ptrFromInt(0x1000 + slot));
            return 0;
        }

        fn globalsDeinitFn(rt: *anyopaque) callconv(.c) i64 {
            asap.nox_globals_set(rt, null);
            return 0;
        }

        // `arg`, GERÇEK codegen'in `RT_PARAM`i HER fonksiyona AÇIKÇA
        // taşımasıyla AYNI gerekçeyle, DOĞRUDAN `rt`nin KENDİSİDİR.
        fn childFn(rt_arg: *anyopaque) callconv(.c) i64 {
            const slot = asap.currentWorkerSlot();
            const got = asap.nox_globals_get(rt_arg);
            const expected: usize = 0x1000 + slot;
            if (@intFromPtr(got) != expected) {
                _ = mismatch_count.fetchAdd(1, .seq_cst);
            }
            if (slot != 0) _ = stolen_count.fetchAdd(1, .seq_cst);
            return 0;
        }

        var tasks: [N_TASKS]?*anyopaque = @splat(null);

        fn realEntry(rt: *anyopaque) callconv(.c) i64 {
            // Sürücünün (slot 0) KENDİ globals ilklendirmesi ARTIK BURADA
            // YAPILMAZ (bkz. `genPoolRunWrapper`nin GÜNCELLENMİŞ belge
            // notu, `poolRunDriverThreadMain`nin `globals_init_fn`i
            // `entry_task` SPAWN EDİLMEDEN ÖNCE, KOŞULSUZ olarak ZATEN
            // çağırdığı — `entry()`nin fiber'ı BİR KARDEŞE ÇALINSA BİLE
            // slot 0'ın globals'ı GÜVENDE).

            var i: usize = 0;
            while (i < N_TASKS) : (i += 1) {
                tasks[i] = bridge.nox_async_spawn(rt, childFn, rt).?;
            }
            i = 0;
            while (i < N_TASKS) : (i += 1) {
                _ = bridge.nox_async_await(rt, tasks[i]);
                bridge.nox_async_destroy_task(rt, tasks[i]);
            }
            return 0;
        }
    };

    const rc = nox_pool_run(null, N_WORKERS, Global.realEntry, Global.globalsInitFn, Global.globalsDeinitFn);
    try testing.expectEqual(@as(i32, 0), rc);

    try testing.expectEqual(@as(usize, 0), Global.mismatch_count.load(.seq_cst));
    // Kanıt: EN AZ bir görev worker 0 DIŞINDA bir worker TARAFINDAN
    // ÇALIŞTIRILDI (yani Bulgu A'nın senaryosu GERÇEKTEN egzersiz EDİLDİ,
    // sadece slot 0'da çalışıp testin ANLAMSIZCA GEÇMESİ DEĞİL).
    try testing.expect(Global.stolen_count.load(.seq_cst) > 0);
}

test "Faz MN.8 Bulgu B: 1000/10000 görevlik toplu-spawn+sıralı-await, false-deadlock YOK (20 tekrar/boyut)" {
    // BU test, MN.7a doğrulamasında GERÇEKTEN gözlemlenen ("hepsini
    // spawn et, SONRA sırayla await et" — GERÇEK bir fan-out/fan-in
    // deseni, YAPAY bir stres deseni DEĞİL) YANLIŞ pozitif deadlock
    // tespitinin KÖK NEDEN düzeltmesini (bkz. `poolWideDeadlockCheck`nin
    // `pool_activity_epoch` doğrulaması, `scheduler.zig`) doğrudan
    // hedefler. ESKİ "yaklaşımı" (testin GÖREV SAYISINI 200→30'a
    // DÜŞÜRMEK, bkz. `STEAL_TEST_N_TASKS`'in belge notu) BİLİNÇLİ olarak
    // TEKRARLANMAZ — BU test TAM TERSİNE 1000 VE 10000 görevle, 20'şer
    // KEZ ard arda (zamanlamaya duyarlı bir düzeltme İçİn TEK geçiş
    // YETERLİ güven VERMEZ) ÇALIŞIR.
    const testing = std.testing;
    const allocator = testing.allocator;

    const Global = struct {
        var tasks_ptr: []?*anyopaque = undefined;

        fn trivial(rt_arg: *anyopaque) callconv(.c) i64 {
            _ = rt_arg;
            return 0;
        }

        fn realEntry(rt: *anyopaque) callconv(.c) i64 {
            var i: usize = 0;
            while (i < tasks_ptr.len) : (i += 1) {
                tasks_ptr[i] = bridge.nox_async_spawn(rt, trivial, rt).?;
            }
            i = 0;
            while (i < tasks_ptr.len) : (i += 1) {
                _ = bridge.nox_async_await(rt, tasks_ptr[i]);
                bridge.nox_async_destroy_task(rt, tasks_ptr[i]);
            }
            return 0;
        }
    };

    const sizes = [_]usize{ 1000, 10000 };
    for (sizes) |n_tasks| {
        const tasks = try allocator.alloc(?*anyopaque, n_tasks);
        defer allocator.free(tasks);
        Global.tasks_ptr = tasks;

        var round: usize = 0;
        while (round < 20) : (round += 1) {
            const rc = nox_pool_run(null, 4, Global.realEntry, null, null);
            try testing.expectEqual(@as(i32, 0), rc);
        }
    }
}
