//! Nox async çalışma zamanı — C ABI köprüsü (bkz. nox-teknik-spesifikasyon.md
//! §3.21, aşama 4). `scheduler.zig`/`channel.zig`in comptime-generic
//! `Task(T)`/`Channel(T)`i QBE'nin ürettiği DÜZ, generic OLMAYAN makine
//! kodundan DOĞRUDAN çağrılamaz (QBE bir generic ÖRNEKLEYEMEZ) — bu yüzden
//! burada TEK, somut `T = i64` örneklemesi kullanılır. Nox'un TÜM değerleri
//! (int/float/bool/str işaretçisi/sınıf işaretçisi/liste işaretçisi) zaten
//! QBE'de 8 baytlık tekdüze bir gösterime sahip olduğundan (`l` ya da
//! bit-yeniden-yorumlanmış `w`/`d`), bu HİÇBİR bilgi kaybına yol açmaz —
//! gerçek tip dönüşümü (int/float/bool/str/sınıf/liste) codegen tarafında
//! (bkz. `codegen_qbe/codegen.zig`, `toPayload`/`fromPayload`) yapılır.
//!
//! **Her OS iş parçacığının KENDİ zamanlayıcısı — `threadlocal` durum
//! (Faz BB.1, bkz. nox-teknik-spesifikasyon.md §3.47):** Faz AA.1'in
//! araştırmasının (§3.46) tespit ettiği TEK gerçek "süreç geneli tek
//! zamanlayıcı" varsayımı BUYDU — `Scheduler.init`/`IoReactor.init`
//! ZATEN allocator-only/sıfır-argümanlı, tamamen örnek-tabanlıydı, TEK
//! engel bu `var`ın modül-seviyesi (süreç geneli) OLMASIYDI.
//! `threadlocal`a çevrilerek `nox.thread.spawn`in (Faz BB.2+)
//! paylaşımsız (shared-nothing) modeli MÜMKÜN oldu: her OS iş parçacığı
//! KENDİ `nox_async_init`ini ÇAĞIRIR, KENDİ bağımsız `Scheduler`/
//! `IoReactor`ünü (KENDİ kqueue/epoll fd'si) kurar — `rt` bağlamına
//! (İlke #6) BİLİNÇLİ olarak EKLENMEDİ (RuntimeState katmanı async'ten
//! BAĞIMSIZ kalmalı), YERİNE Zig'in KENDİ `threadlocal` ilkeli
//! desteği KULLANILDI — HİÇBİR ek senkronizasyon/kilit GEREKMEDİ.
//!
//! **Deadlock:** `nox_async_run_to_completion`, zamanlayıcı `error.Deadlock`
//! döndürürse süreci `nox_unhandled_exception` ile AYNI desende
//! (`runtime/errors/handle.zig`) sonlandırır — Nox'un TAM istisna
//! mekanizmasına (raise/try/except) entegre etmek bu fazın kapsamı DIŞI
//! bırakıldı (bkz. spec, "kalan" notu).

const std = @import("std");
const asap = @import("../alloc/asap.zig");
const fiber_mod = @import("fiber.zig");
const scheduler_mod = @import("scheduler.zig");
const channel_mod = @import("channel.zig");
const worker_pool_mod = @import("worker_pool.zig");
/// Faz MN.6: `nox_async_init`in havuzlu dalının `PoolLink.collect_fn`e
/// GERÇEK `nox_cycle_collect`i BAĞLAYABİLMESİ İçİn — `scheduler.zig`nin
/// KENDİSİ BUNU YAPAMAZ (bkz. onun belge notu, "runtime/alloc/den
/// bağımsız kalma" sınırı), `bridge.zig` İSE SINIRSIZ bir bağlamdır.
const cycle_detector = @import("../alloc/cycle_detector.zig");

const TaskI64 = scheduler_mod.Task(i64);
const ChannelI64 = channel_mod.Channel(i64);

threadlocal var g_scheduler: ?scheduler_mod.Scheduler = null;

/// Stdlib fazı §D.1.3 (bkz. nox-teknik-spesifikasyon.md) — `nox.http`in
/// Zig kabuğu (giden istekler İÇİN arka plan iş parçacığı + tamamlanma
/// pipe'ı beklerken) GERÇEKTEN bir fiber İÇİNDE mi çalıştığımızı bilmek
/// zorundadır: `Scheduler.suspendForIo`, `self.current.?` UNWRAP ettiğinden
/// (bkz. onun belge notu, "ÇAĞIRAN fiber" varsayımı), fiber DIŞINDA (ör.
/// `async` HİÇ KULLANMAYAN senkron bir üst-düzey Nox betiği, ki BU DURUMDA
/// `g_scheduler` HİÇ İLKLENMEMİŞTİR — bkz. `nox_async_init`in belge notu,
/// "yalnızca modül gerçekten async KULLANIYORSA" çağrılır) çağrılması
/// GÜVENSİZDİR. Bu fonksiyon yalnızca GÜVENLE `suspendForIo` çağrılabilecek
/// durumda (zamanlayıcı VAR VE şu an bir fiber ÇALIŞIYOR) `*Scheduler`
/// döner; aksi halde `null` — çağıran taraf `null` durumunda sıradan
/// (bloklayan) bir bekleyişe düşer (senkron kod için tamamen GÜVENLİDİR,
/// çünkü zaten korunacak BAŞKA bir fiber YOKTUR).
pub fn currentFiberScheduler() ?*scheduler_mod.Scheduler {
    if (g_scheduler) |*s| {
        if (s.current != null) return s;
    }
    return null;
}

/// Faz OO.2 (bkz. nox-teknik-spesifikasyon.md §3.83, `TaskLocal[T]`):
/// `currentFiberScheduler`in AYNI "sadece GERÇEKTEN bir fiber çalışıyorsa"
/// koruması, ama doğrudan `*Fiber`i döner — `runtime/async_rt/task_local.
/// zig`nin `nox_tasklocal_get/set/clear`i BUNU kullanır. Bir fiber DIŞINDA
/// (senkron üst-düzey kod) çağrılırsa `null` döner — çağıran taraf BUNU
/// "hiçbir değer YOK" olarak ele almalıdır (`suspendForIo`nun AKSİNE
/// burada panik ATILMAZ, ÇÜNKÜ TaskLocal fiber DIŞINDA da SÖZDİZİMSEL
/// olarak ÇAĞRILABİLİR bir metod çağrısıdır — checker BUNU kısıtlamaz).
pub fn currentFiber() ?*fiber_mod.Fiber {
    if (g_scheduler) |*s| return s.current;
    return null;
}

fn allocatorFromRt(rt: ?*anyopaque) std.mem.Allocator {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt.?));
    return state.allocator();
}

/// Modülün TEK zamanlayıcısını başlatır — codegen, `main`in başında (yalnızca
/// modül gerçekten async bir yapı KULLANIYORSA) bir kez çağırır. `pub` —
/// stdlib fazı §D.1.3: `nox.http`in Zig kabuğunun birim testleri (bkz.
/// `stdlib_shims/http_client.zig`) gerçek eşzamanlılığı kanıtlamak için
/// KENDİ fiber senaryolarını kurar, bu yüzden bunu DOĞRUDAN Zig seviyesinde
/// çağırabilmelidir (`str.zig`/`dict.zig`nin AYNI gerekçeyle ZATEN yaptığı
/// `pub` düzeltmesiyle TUTARLI).
pub export fn nox_async_init(rt: ?*anyopaque) void {
    // D.0 (bkz. nox-teknik-spesifikasyon.md §3.29): `Scheduler.init` artık
    // reaktörün `kqueue()`sini açtığından fallible — bu, `nox_rc_alloc`ın
    // `null` dönmesi kadar SON DERECE nadir bir kaynak tükenmesi senaryosudur
    // (bkz. `markReady`in AYNI gerekçeyle kullandığı `@panic`).
    g_scheduler = scheduler_mod.Scheduler.init(allocatorFromRt(rt)) catch @panic("async zamanlayici baslatilamadi (kqueue)");
    // Faz MN.9.1: `scheduler.zig`nin standalone `currentScheduler()`ıyla
    // eşitlenir — bkz. onun belge notu (`Channel[T]`nin çapraz-worker
    // düzeltmesi BUNA dayanır).
    scheduler_mod.setCurrentScheduler(&g_scheduler.?);

    // Faz MN.4/5: `rt`nin `RuntimeState.worker_pool`u SET İSE (bkz.
    // `worker_pool.zig`nin `WorkerPool.create`ı) bu OS iş parçacığı bir
    // havuzun parçasıdır — `g_scheduler`ı `asap.currentWorkerSlot()` İLE
    // belirlenen KENDİ slotuna BAĞLAR. `worker_pool == null` İKEN
    // (BUGÜNKÜ, paylaşımsız kullanım) BU BLOK HİÇ ÇALIŞMAZ, davranış
    // BİREBİR AYNI kalır. Faz MN.4/5.8: `scheduler.zig`nin `attachToPool`ı
    // ARTIK `worker_pool.Worker`nin TAM TİPİNİ ALMAZ (bkz. onun belge
    // notu, "runtime/alloc/den bağımsız kalma" sınırı) — SADECE İLKEL
    // (`WorkerPool`den ÇIKARILAN) değerlerle çağrılır; BU çıkarma İŞİ
    // BURADA (HEM `scheduler_mod` HEM `worker_pool_mod`u SERBESTÇE
    // ithal edebilen `bridge.zig`de) yapılır.
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt.?));
    if (state.worker_pool) |wp_ptr| {
        const pool: *worker_pool_mod.WorkerPool = @ptrCast(@alignCast(wp_ptr));
        const slot = asap.currentWorkerSlot();
        g_scheduler.?.attachToPool(.{
            .own_slot = slot,
            .sibling_deques = pool.deque_list,
            .live_count = pool.pool_live_count,
            .waiting_on_io = pool.pool_waiting_on_io,
            .idle_workers = pool.pool_idle_workers,
            .activity_epoch = pool.pool_activity_epoch,
            .stw_requested = pool.pool_stw_requested,
            .stw_arrived = pool.pool_stw_arrived,
            .stw_sense = pool.pool_stw_sense,
            .wake_fds = pool.wake_fds,
            .collect_fn = &cycle_detector.nox_cycle_collect,
            .rt = rt,
        }) catch {};
        // Faz MN.9.3: `pool_bridge.zig`nin `broadcastRunOnEachWorker`ının
        // (bkz. `nox_pool_serve`) BU worker'ı `scheduler.spawnToForeignScheduler`
        // İLE HEDEFLEYEBİLMESİ İçİn KENDİ `*Scheduler`ını (`attachToPool`
        // BAŞARILI OLDUKTAN SONRA, ARTIK GÜVENLE ÇALINABİLİR/uyandırılabilir
        // OLDUĞUNDA) yayınlar.
        state.pool_scheduler_ptrs[slot].store(&g_scheduler.?, .release);
    }
}

/// `Scheduler`in KENDİ iç durumunu (hazır kuyruğu) serbest bırakır — codegen,
/// `nox_runtime_deinit`den HEMEN ÖNCE `main`in sonunda bir kez çağırır.
/// **Bulunan gerçek hata:** bu çağrı UNUTULURSA, `Scheduler.ready`nin
/// (`ArrayListUnmanaged`) arka plan dizisi HER async programda sızar
/// (DebugAllocator tarafından yakalanır) — yalnızca bu köprünün KENDİ
/// testlerinde elle çağrılıyordu, gerçek derlenmiş programların yolunda
/// EKSİKTİ.
pub export fn nox_async_deinit(rt: ?*anyopaque) void {
    _ = rt;
    if (g_scheduler) |*s| s.deinit();
    g_scheduler = null;
    scheduler_mod.setCurrentScheduler(null);
}

/// `func(arg)`i hemen bir yeşil iş parçacığında başlatır, bir `Task`
/// tutamacı (opak işaretçi) döner. `func`, codegen'in HER `spawn` çağrı
/// sitesi için ürettiği, argümanları paketten çıkarıp gerçek `async def`
/// fonksiyonunu çağıran bir sarmalayıcıdır (bkz. codegen.zig, `genSpawnExpr`).
pub export fn nox_async_spawn(rt: ?*anyopaque, func: *const fn (*anyopaque) callconv(.c) i64, arg: ?*anyopaque) ?*anyopaque {
    // Faz MN.4/5.7: `rt` BURADA KULLANILMIYOR — havuzlu/çalma-farkındalı
    // yönlendirme (yeni fiber'ı `markReady` YERİNE `Worker.deque`ye PUSH
    // etmek) `scheduler_mod.spawn`ın KENDİSİNDE, `scheduler.worker`
    // ÜZERİNDEN yapılıyor (bkz. onun belge notu) — `g_scheduler` `nox_
    // async_init`de ZATEN `attachToPool` İLE bağlandığından BURADA AYRICA
    // `rt`ye bakmaya GEREK YOK.
    _ = rt;
    const task = scheduler_mod.spawn(&g_scheduler.?, i64, func, arg.?) catch @panic("OOM: spawn");
    return task;
}

/// Bir `Task`ı bekler — tamamlanmışsa sonucu hemen, değilse çağıran fiber'ı
/// askıya alıp döner (bkz. `Task.await_`).
pub export fn nox_async_await(rt: ?*anyopaque, task: ?*anyopaque) i64 {
    _ = rt;
    const t: *TaskI64 = @ptrCast(@alignCast(task.?));
    return t.await_();
}

/// Bir `Task` tutamacını yok eder (yalnızca `Task` struct'ının kendisini —
/// fiber'ı DEĞİL, o zaten `Scheduler.run()` tarafından bitince serbest
/// bırakılır). Codegen bunu HEM modülün üst düzey kodunu sarmalayan
/// `$main_body` görevi İÇİN (hiç `await`lenmediğinden, bkz. `genMain`) `main`in
/// sonunda, HEM de bir `Task`/`Channel`/`dict` tipli değişken yeniden
/// atandığında/kapsam dışına çıktığında ESKİ değer İÇİN çağırır (bkz. Faz S.1,
/// `codegen.zig`nin `destroyNonArcValue`si).
///
/// Görev HENÜZ tamamlanMAMIŞSA struct'ı HEMEN serbest bırakmak GÜVENSİZDİR
/// (bkz. `Task.detached`in belge notu, `scheduler.zig`) — bu durumda yalnızca
/// `detached` bayrağı işaretlenir, GERÇEK serbest bırakma görev kendi kendine
/// tamamlanınca `entryTrampoline` tarafından yapılır. Bu, "fire-and-forget"
/// (hiç `await` edilmeden bırakılan) görevlerin de sızmadan VE bellek
/// güvenliği ihlal edilmeden temizlenmesini sağlar.
pub export fn nox_async_destroy_task(rt: ?*anyopaque, task: ?*anyopaque) void {
    // `nox_tasklocal_destroy`/`nox_threadchannel_destroy`/`nox_thread_destroy`
    // İLE AYNI `orelse return` null-koruması — codegen'in `.var_decl` dalı
    // (bkz. `stmt.zig`) ARTIK bir slotun İLK yazımında (henüz `null` İKEN)
    // BİLE "üzerine yazmadan ÖNCE eskiyi yok et" çağrısı yapıyor.
    const t: *TaskI64 = @ptrCast(@alignCast(task orelse return));
    if (t.state.load(.acquire) == TaskI64.COMPLETED) {
        allocatorFromRt(rt).destroy(t);
    } else {
        t.detached = true;
    }
}

/// Zamanlayıcıyı hazır kuyruk boşalana kadar çalıştırır — codegen, `main`in
/// SONUNDA (yalnızca async kullanan modüllerde) bir kez çağırır. `0`: normal
/// tamamlandı. `1`: `error.Deadlock` (bkz. `nox_async_deadlock_abort`).
pub export fn nox_async_run_to_completion(rt: ?*anyopaque) i32 {
    _ = rt;
    g_scheduler.?.run() catch |e| switch (e) {
        error.Deadlock => return 1,
    };
    return 0;
}

/// `nox_async_run_to_completion` `.deadlock` döndürdüğünde çağrılır —
/// `nox_unhandled_exception` (bkz. `runtime/errors/handle.zig`) ile AYNI
/// desen: net bir mesaj basıp sıfırdan farklı bir kodla sonlandırır (Nox'un
/// TAM istisna mekanizmasına entegrasyon bu fazın kapsamı DIŞI, bkz. spec).
export fn nox_async_deadlock_abort(rt: ?*anyopaque) noreturn {
    _ = rt;
    std.debug.print("nox: kilitlenme (deadlock) tespit edildi — tüm görevler bloke, hiçbiri ilerleyemiyor\n", .{});
    std.process.exit(1);
}

export fn nox_channel_new(rt: ?*anyopaque, capacity: i64) ?*anyopaque {
    const ch = allocatorFromRt(rt).create(ChannelI64) catch @panic("OOM: channel");
    ch.* = ChannelI64.init(&g_scheduler.?, @intCast(capacity));
    return ch;
}

/// Bir `Channel`i (iç tampon/bekleyen kuyrukları + kendisi) serbest bırakır —
/// codegen, `Channel[T]` tipli bir yerel değişkenin kapsam sonunda çağırır
/// (bkz. `HeapKind.channel`, `releaseAllLocalsExcept`).
export fn nox_channel_destroy(rt: ?*anyopaque, ch: ?*anyopaque) void {
    // `nox_tasklocal_destroy`/`nox_threadchannel_destroy`/`nox_thread_destroy`
    // İLE AYNI `orelse return` null-koruması — codegen'in `.var_decl` dalı
    // (bkz. `stmt.zig`) ARTIK bir slotun İLK yazımında (henüz `null` İKEN)
    // BİLE "üzerine yazmadan ÖNCE eskiyi yok et" çağrısı yapıyor.
    const c: *ChannelI64 = @ptrCast(@alignCast(ch orelse return));
    c.deinit();
    allocatorFromRt(rt).destroy(c);
}

export fn nox_channel_send(rt: ?*anyopaque, ch: ?*anyopaque, value: i64) void {
    _ = rt;
    const c: *ChannelI64 = @ptrCast(@alignCast(ch.?));
    c.send(value);
}

export fn nox_channel_recv(rt: ?*anyopaque, ch: ?*anyopaque) i64 {
    _ = rt;
    const c: *ChannelI64 = @ptrCast(@alignCast(ch.?));
    return c.recv();
}

test "nox_async_spawn + nox_async_await, i64 payload uçtan uca" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    nox_async_init(rt);

    const Fn = struct {
        fn double(arg: *anyopaque) callconv(.c) i64 {
            const x: *i64 = @ptrCast(@alignCast(arg));
            return x.* * 2;
        }
    };
    var input: i64 = 21;
    const task = nox_async_spawn(rt, Fn.double, &input).?;
    try std.testing.expectEqual(@as(i32, 0), nox_async_run_to_completion(rt));
    try std.testing.expectEqual(@as(i64, 42), nox_async_await(rt, task));

    const t: *TaskI64 = @ptrCast(@alignCast(task));
    allocatorFromRt(rt).destroy(t);
    g_scheduler.?.deinit();
    g_scheduler = null;
}

test "nox_channel_new/send/recv, i64 payload uçtan uca" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    nox_async_init(rt);

    const ch = nox_channel_new(rt, 1).?;
    nox_channel_send(rt, ch, 7);
    try std.testing.expectEqual(@as(i64, 7), nox_channel_recv(rt, ch));

    const c: *ChannelI64 = @ptrCast(@alignCast(ch));
    c.deinit();
    allocatorFromRt(rt).destroy(c);
    g_scheduler.?.deinit();
    g_scheduler = null;
}

// Faz BB.1: `g_scheduler`nin `threadlocal`a çevrilmesinin GERÇEKTEN iki
// bağımsız OS iş parçacığının KENDİ bağımsız zamanlayıcısını GÜVENLE
// çalıştırabildiğini kanıtlar — `asap.zig`nin `arcOwnerThreadOk` testinin
// AYNI deseni (GERÇEK `std.Thread.spawn`, simüle EDİLMEMİŞ). Her iş
// parçacığı KENDİ `RuntimeState`ini/`Scheduler`ini kurup FARKLI bir görev
// çalıştırır — sonuçların birbirini ETKİLEMEDİĞİ (çapraz-iş-parçacığı
// veri yarışı OLMADIĞI) doğrulanır.
test "g_scheduler threadlocal: iki gerçek OS iş parçacığı bağımsız çalışır" {
    const Worker = struct {
        fn run(multiplier: i64, out: *i64) void {
            const rt = asap.nox_runtime_init() orelse @panic("init failed");
            defer asap.nox_runtime_deinit(rt);
            nox_async_init(rt);
            defer nox_async_deinit(rt);

            const Fn = struct {
                fn mul(arg: *anyopaque) callconv(.c) i64 {
                    const m: *i64 = @ptrCast(@alignCast(arg));
                    return 10 * m.*;
                }
            };
            var m_copy: i64 = multiplier;
            const task = nox_async_spawn(rt, Fn.mul, &m_copy).?;
            _ = nox_async_run_to_completion(rt);
            out.* = nox_async_await(rt, task);
            const t: *TaskI64 = @ptrCast(@alignCast(task));
            allocatorFromRt(rt).destroy(t);
        }
    };

    var result_a: i64 = 0;
    var result_b: i64 = 0;
    const thread_a = try std.Thread.spawn(.{}, Worker.run, .{ 2, &result_a });
    const thread_b = try std.Thread.spawn(.{}, Worker.run, .{ 3, &result_b });
    thread_a.join();
    thread_b.join();

    try std.testing.expectEqual(@as(i64, 20), result_a);
    try std.testing.expectEqual(@as(i64, 30), result_b);
}
