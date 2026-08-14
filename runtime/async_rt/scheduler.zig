//! Nox async runtime — M:1 zamanlayıcı + `Task[T]` (bkz. nox-teknik-
//! spesifikasyon.md §3.21, aşama 2). `fiber.zig`deki yığınlı fiber
//! ilkeli üzerine kurulu: TEK bir OS iş parçacığı üzerinde kooperatif
//! çoklu görev çalıştırma + deadlock TESPİTİ (yapısal önleme değil).
//!
//! **Deadlock tespiti burada, Task/Channel'dan BAĞIMSIZ olarak yaşar:**
//! zamanlayıcı TÜM görevleri kendi yönettiğinden (M:1), "hazır kuyruk boş
//! AMA hâlâ bitmemiş görev var" durumu HER ZAMAN gözlemlenebilir bir
//! global durumdur — `run()` bunu tespit edip `error.Deadlock` döner
//! (süreç sonsuza dek asılı KALMAZ). Bu, alttaki askıya alma ilkelinin
//! (`suspendCurrent`/`markReady`) kaynağı Task mı Channel mı olduğuna
//! bakmaksızın çalışır — bkz. bu dosyadaki "dairesel await" testi.
//!
//! **Yığın (stack) havuzu (performans fazı):** `oop_arc_churn`e benzer bir
//! senaryonun (çok sayıda kısa ömürlü `spawn`, ör. bir döngüde) profillenmesi,
//! her `spawn`ın `fiber.zig`'in 256 KiB'lik yığınını TAZEDEN tahsis edip her
//! tamamlanmada serbest bıraktığını, bunun da (blok BÜYÜK olduğundan genel
//! amaçlı ayırıcının küçük-nesne hızlı yolunu atlayıp doğrudan işletim
//! sistemine gittiğini) baskın bir maliyet olduğunu gösterdi — 200.000 `spawn`
//! ~0.6s (çoğu "system" süresi). Çözüm: `runtime/alloc/arc.zig`'in ARC
//! nesneleri için kullandığı BENZER "geri dönüştür" fikri — bir görev bitince
//! yığını GERÇEKTEN serbest bırakmak yerine `stack_pool`a (basit bir yığın/
//! `ArrayListUnmanaged`) eklenir; bir sonraki `spawn` önce havuzu dener.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const fiber_mod = @import("fiber.zig");
const Fiber = fiber_mod.Fiber;
const Context = fiber_mod.Context;
const io_reactor = @import("io_reactor.zig");
const IoReactor = io_reactor.IoReactor;
/// Faz MN.4/5.8: `SpinLock`in TEK doğruluk kaynağı `runtime/async_rt/
/// spinlock.zig`ye taşındı (bkz. onun belge notu) — `runtime/alloc/asap.zig`
/// BURADAN KESİNLİKLE İTHAL EDİLEMEZ: `fiber.zig`/`scheduler.zig`/
/// `channel.zig`/`io.zig` BİLİNÇLİ olarak `runtime/alloc/`den (dolayısıyla
/// `runtime/stdlib_shims`den) BAĞIMSIZ kalacak şekilde tasarlanmıştır
/// (bkz. `build.zig`nin `async-rt-test` adımı — Windows CI'ın kullandığı,
/// `noxrt`in TAMAMINI BEKLEMEDEN SADECE bu katmanı doğrulayan standalone
/// hedef, VE `scheduler_test`/`channel_test`in `runtime/async_rt/
/// scheduler.zig`yi KENDİ modül KÖKÜ olarak kullanması).
const SpinLock = @import("spinlock.zig").SpinLock;
/// Faz MN.4/5.8: `chase_lev_deque.zig` (MN.3a) TAMAMEN bağımsız (SADECE
/// std/builtin) — `runtime/async_rt/`nin AYNI "runtime/alloc/den bağımsız"
/// sınırı İçİNDE GÜVENLE İTHAL EDİLEBİLİR. **`worker_pool.zig` İSE ASLA
/// İTHAL EDİLEMEZ** — `asap.zig`ye (dolayısıyla `runtime/alloc/`e)
/// bağımlı OLDUĞUNDAN, `Scheduler`nin havuz-farkındalılığı BURADA
/// `worker_pool.Worker`/`WorkerPool`nin TAM TİPLERİNE DEĞİL, SADECE
/// bu dosyanın (`own_slot`/`sibling_deques`/`pool_*` alanları — aşağıya
/// bkz.) TANIMLADIĞI İLKEL (std-only) tiplere DAYANIR — `bridge.zig`nin
/// `nox_async_init`i (HEM `scheduler.zig`yi HEM `worker_pool.zig`yi
/// SINIRSIZ ithal edebilen TAM `noxrt_mod` bağlamında) `WorkerPool`dan
/// bu İLKEL değerleri ÇIKARIP `attachToPool`e GEÇİRİR (bkz. onun belge
/// notu) — İKİ dosya birbirini HİÇ TANIMAZ.
const chase_lev_deque = @import("chase_lev_deque.zig");
const Deque = chase_lev_deque.ChaseLevDeque(*Fiber, 256);
/// Faz MN.6: self-pipe yardımcıları BURAYA taşındı — bkz. onun modül üstü
/// notu (`cycle_detector.zig`nin STW round'unu `signalWakeFd` İLE
/// UYANDIRABİLMESİ İçİn gereken paylaşım).
const self_pipe = @import("self_pipe.zig");

/// Faz MN.6: `attachToPool`in TEK parametresi — `own_slot`/`sibling_deques`
/// + havuz-çapında YEDİ atomik/fonksiyon işaretçisinin TAMAMINI TEK bir
/// struct'a SARAR (ARTIK ~11 alan, ayrı parametreler OLARAK sürdürülemez).
/// `bridge.zig`nin `nox_async_init`i (HEM `scheduler.zig`yi HEM `worker_
/// pool.zig`yi İTHAL EDEBİLEN, SINIRSIZ bağlam) `WorkerPool`dan bu İLKEL
/// değerleri ÇIKARIP İNŞA EDER.
pub const PoolLink = struct {
    own_slot: usize,
    sibling_deques: []const *Deque,
    live_count: *std.atomic.Value(usize),
    waiting_on_io: *std.atomic.Value(usize),
    idle_workers: *std.atomic.Value(usize),
    /// Faz MN.8, Bulgu B: `poolWideDeadlockCheck`nin epoch-doğrulamalı
    /// kök-neden düzeltmesi İçİn (bkz. `asap.RuntimeState`nin `pool_
    /// activity_epoch`inin AYNI belge notu).
    activity_epoch: *std.atomic.Value(u64),
    /// Faz MN.6: STW bariyerinin ÜÇ paylaşılan atomiği (bkz. `asap.
    /// RuntimeState`nin AYNI-adlı alanlarının belge notu).
    stw_requested: *std.atomic.Value(bool),
    stw_arrived: *std.atomic.Value(usize),
    stw_sense: *std.atomic.Value(bool),
    /// Faz MN.6: HER worker'ın wake-fd YAZMA ucuna işaretçilerin dizisi
    /// (`RuntimeState.pool_wake_fds`e karşılık gelir, AYNI `own_slot`
    /// İNDEKSİYLE) — `attachToPool`, KENDİ `wake_write_fd`sini `wake_fds
    /// [own_slot]`e YAYINLAR (bkz. `cycle_detector.zig`nin BUNU nasıl
    /// KULLANDIĞI İçİn `self_pipe.zig`nin modül üstü notu).
    wake_fds: []std.atomic.Value(i32),
    /// Faz MN.6: `nox_cycle_collect`e (Zig FONKSİYON DEĞERİ olarak,
    /// `extern fn`e BİLE GEREK YOK — bkz. proje planı, tasarım #3)
    /// enjekte edilen işaretçi. `scheduler.zig` `cycle_detector.zig`yi
    /// (dolayısıyla `runtime/alloc/`i) ASLA İTHAL ETMEZ — standalone
    /// `async-rt-test` sınırı BÖYLECE KORUNUR.
    collect_fn: *const fn (rt: ?*anyopaque) callconv(.c) void,
    rt: ?*anyopaque,
};

/// Faz MN.9.1: "BU OS iş parçacığı ŞU AN HANGİ `Scheduler`ı ÇALIŞTIRIYOR"
/// sorusunun standalone (`runtime/alloc/`den BAĞIMSIZ) doğruluk kaynağı.
/// `bridge.zig`nin `g_scheduler`ı (Scheduler struct'ının KENDİSİNİ TLS'te
/// TUTAN, "full" dünyanın threadlocal'ı) `nox_async_init`/`nox_async_deinit`
/// SIRASINDA `setCurrentScheduler`İLE BUNU eşitler (bkz. onun belge notu).
///
/// **BULUNAN, AYRI bir GERÇEK hata İçİn eklendi (Faz MN.9.1):** `Channel(T).
/// send`/`recv` ESKİDEN `self.scheduler`i (OLUŞTURMA-ANINDA SABİTLENEN bir
/// alan) `.current`/`suspendCurrent`/`markReady` İçİn kullanıyordu — checker'ın
/// `isSpawnParamSafeType`si BİR `Channel[T]`nin `spawn`e argüman OLARAK
/// GEÇİRİLMESİNE İZİN VERDİĞİNDEN (M:N iş-çalma ALTINDA, ÇALINABİLİR bir
/// alt göreve), OLUŞTURAN fiber'DAN BAŞKA bir fiber BU Channel'ı KULLANIRSA
/// (VE o fiber BAŞKA bir worker'a ÇALINDIYSA) `self.scheduler` ARTIK GERÇEKTEN
/// ÇALIŞAN worker'ı DEĞİL, OLUŞTURAN worker'ı GÖSTERİYORDU — `.current`/
/// `suspendCurrent`/`markReady` YANLIŞ worker'ın durumuna dokunuyordu.
/// `currentScheduler()` (ÇAĞIRANIN KENDİ, GERÇEKTEN ÇALIŞAN worker'ının
/// scheduler'ı) BU YÜZDEN `self.scheduler` YERİNE kullanılmalıdır.
threadlocal var g_current_scheduler: ?*Scheduler = null;
pub fn currentScheduler() ?*Scheduler {
    return g_current_scheduler;
}
pub fn setCurrentScheduler(s: ?*Scheduler) void {
    g_current_scheduler = s;
}

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    ready: std.ArrayListUnmanaged(*Fiber) = .empty,
    /// Faz MN.4/5: `ready`yi korur — HEM YEREL (worker KENDİ fiber'ını
    /// uyandırır, ÇOK SIK) HEM YABANCI (havuzdaki BAŞKA bir worker `task.
    /// scheduler` ÜZERİNDEN bir waiter'ı uyandırır, NADİR) yol AYNI, TEK
    /// kilidi kullanır — bkz. `markReady`/`run`. Çekişmesiz `cmpxchgWeak`
    /// UCUZ olduğundan havuzsuz/tek-iş-parçacıklı kullanımda da HER ZAMAN
    /// AKTİF (dallanma YOK, TEK kod yolu HER ZAMAN doğru).
    ready_lock: SpinLock = .{},
    /// Zamanlayıcı döngüsünün (fiber DIŞI, "kök") bağlamı — bir fiber'a
    /// `resume_` edildiğinde buraya "geri dönülür".
    root_ctx: Context = .{},
    /// Şu an ÇALIŞAN fiber (zamanlayıcı döngüsünün kendisi çalışırken null).
    current: ?*Fiber = null,
    /// Henüz BİTMEMİŞ (canlı) görev sayısı — hazır kuyruk boşken bu sıfır
    /// değilse TÜM canlı görevler bloke demektir (bkz. `run`).
    live_count: usize = 0,
    /// Tamamlanmış fiber'lardan geri dönüştürülen, henüz yeniden kullanılmamış
    /// yığınların havuzu — bkz. modül üstü not.
    stack_pool: std.ArrayListUnmanaged([]align(fiber_mod.STACK_ALIGN) u8) = .empty,
    /// D.0 (bkz. nox-teknik-spesifikasyon.md §3.29): gerçek G/Ç hazır-olma
    /// bildirimi için kqueue reaktörü.
    reactor: IoReactor,
    /// Şu an bir G/Ç olayı BEKLEYEN (`suspendForIo` ile askıya alınmış)
    /// fiber sayısı — `run`ün deadlock kararını GENİŞLETİR: hazır kuyruk
    /// boş VE `waiting_on_io > 0` İSE bu bir deadlock DEĞİLDİR, `reactor.poll`
    /// çağrılıp beklenir (bkz. `run`).
    waiting_on_io: usize = 0,
    /// Faz MN.4/5: bu zamanlayıcının `init()` SIRASINDA kaydedilen sahibi —
    /// `markReady`nin ÇAĞIRAN iş parçacığının KENDİ zamanlayıcısı MI
    /// (yerel, ÇOK SIK) YOKSA YABANCI (havuzdaki BAŞKA bir worker, NADİR)
    /// MI olduğunu ayırt etmesi İçİn — SADECE `worker != null` İKEN
    /// anlamlıdır (bkz. `markReady`).
    owner_tid: std.Thread.Id = undefined,
    /// Faz MN.4/5.8: havuzdaki KENDİ konumu (`attachToPool`in `own_slot`
    /// parametresi) — SADECE `pool_live_count != null` İKEN anlamlıdır.
    own_slot: usize = 0,
    /// Faz MN.4/5.8: havuzdaki TÜM worker'ların deque'lerine (KENDİSİ
    /// DAHİL, `own_slot` İNDEKSİNDE) İşaretçilerin dizisi — `bridge.zig`
    /// TARAFINDAN `WorkerPool.deque_list`den GEÇİRİLİR (bkz. modül üstü
    /// not). BOŞ dizi (`&.{}`) İSE havuzsuz kullanım.
    sibling_deques: []const *Deque = &.{},
    /// Faz MN.4/5.8: havuz-çapında YAKLAŞIK deadlock tespiti İçİn ÜÇ
    /// PAYLAŞILAN atomik sayaca DOĞRUDAN işaretçiler (bkz. `asap.
    /// RuntimeState`nin `pool_live_count`/`pool_waiting_on_io`/
    /// `pool_idle_workers`ı — `bridge.zig` `WorkerPool` ÜZERİNDEN BUNLARI
    /// ÇIKARIP GEÇİRİR). `null` İSE (BUGÜNKÜ, paylaşımsız kullanım)
    /// `markReady`/`run` DAVRANIŞI BİREBİR DEĞİŞMEZ — bu ÜÇ alan "havuzlu
    /// muyum" sorusunun TEK doğruluk kaynağıdır (`pool_live_count != null`).
    pool_live_count: ?*std.atomic.Value(usize) = null,
    pool_waiting_on_io: ?*std.atomic.Value(usize) = null,
    pool_idle_workers: ?*std.atomic.Value(usize) = null,
    /// Faz MN.8, Bulgu B: bkz. `PoolLink.activity_epoch`in belge notu.
    pool_activity_epoch: ?*std.atomic.Value(u64) = null,
    /// Faz MN.6: STW bariyerinin ÜÇ paylaşılan atomiğine işaretçiler —
    /// `null` İSE (havuzsuz) `stwParticipate` HİÇ ÇALIŞMAZ (bkz. onun
    /// gövdesi, İLK satır).
    stw_requested: ?*std.atomic.Value(bool) = null,
    stw_arrived: ?*std.atomic.Value(usize) = null,
    stw_sense: ?*std.atomic.Value(bool) = null,
    /// Faz MN.6: BU worker'ın KENDİ "sense" biti — PAYLAŞILMAZ, SADECE
    /// bu `Scheduler`ın KENDİ iş parçacığı OKUR/YAZAR (bkz. proje planı,
    /// "sense-reversing barrier" tasarım notu — TEK bir paylaşılan bayrağın
    /// YENİDEN KULLANIMININ ABA-tipi bir bariyer-kilitlenmesi YARATTIĞI
    /// bulundu, düzeltmesi BUDUR).
    stw_local_sense: bool = false,
    /// Faz MN.6: `nox_cycle_collect`e (bkz. `PoolLink`in AYNI-adlı alanının
    /// belge notu) enjekte edilen fonksiyon işaretçisi + onu ÇAĞIRMAK İçİn
    /// gereken `rt`.
    collect_fn: ?*const fn (rt: ?*anyopaque) callconv(.c) void = null,
    rt: ?*anyopaque = null,
    /// Faz MN.4/5: çapraz-worker uyandırma İçİn self-pipe ÇİFTİ — SADECE
    /// `attachToPool` çağrıldığında (havuzlu kullanım) kurulur, AKSİ HALDE
    /// `null` kalır.
    wake_read_fd: ?posix.fd_t = null,
    wake_write_fd: ?posix.fd_t = null,
    /// Wake-fd'nin reaktöre KAYDI İçİn sahte, ASLA GERÇEKTEN resume EDİLMEYEN
    /// bir "fiber" yer tutucusu — `markReady` bunun ADRESİNİ gördüğünde hazır
    /// kuyruğa EKLEMEK yerine SADECE byte'ı tüketip fd'yi YENİDEN kaydeder
    /// (bkz. `armWakeFd`/`markReady`). İÇERİĞİ HİÇBİR ZAMAN okunmaz/yazılmaz
    /// (`undefined` GÜVENLİDİR) — SADECE ADRESİ bir kimlik olarak kullanılır.
    wake_sentinel: Fiber = undefined,
    wake_ctx: io_reactor.WaitCtx = undefined,

    pub fn init(allocator: std.mem.Allocator) !Scheduler {
        return .{ .allocator = allocator, .reactor = try IoReactor.init(), .owner_tid = std.Thread.getCurrentId() };
    }

    pub fn deinit(self: *Scheduler) void {
        self.reactor.deinit();
        self.ready.deinit(self.allocator);
        for (self.stack_pool.items) |stack| fiber_mod.freeGuardedStack(stack);
        self.stack_pool.deinit(self.allocator);
        if (self.wake_read_fd) |fd| self_pipe.closeSelfPipeFd(fd);
        if (self.wake_write_fd) |fd| self_pipe.closeSelfPipeFd(fd);
    }

    /// Faz MN.4/5: bu zamanlayıcıyı bir `WorkerPool`e BAĞLAR — `bridge.zig`nin
    /// `nox_async_init`i, `rt`nin `RuntimeState.worker_pool`u SET İSE bunu
    /// OTOMATİK çağırır (bkz. onun belge notu). Self-pipe kurar VE HEMEN
    /// reaktöre kaydeder (`armWakeFd`) — `run`, İLK `reactor.poll()`
    /// çağrısından İTİBAREN çapraz-worker uyandırmaya HAZIR olur.
    pub fn attachToPool(self: *Scheduler, link: PoolLink) !void {
        self.own_slot = link.own_slot;
        self.sibling_deques = link.sibling_deques;
        self.pool_live_count = link.live_count;
        self.pool_waiting_on_io = link.waiting_on_io;
        self.pool_idle_workers = link.idle_workers;
        self.pool_activity_epoch = link.activity_epoch;
        self.stw_requested = link.stw_requested;
        self.stw_arrived = link.stw_arrived;
        self.stw_sense = link.stw_sense;
        self.collect_fn = link.collect_fn;
        self.rt = link.rt;
        const fds = try self_pipe.makeSelfPipe();
        self.wake_read_fd = fds[0];
        self.wake_write_fd = fds[1];
        self.armWakeFd();
        // Faz MN.6: KENDİ wake-fd'mizin YAZMA ucunu YAYINLA — `cycle_
        // detector.zig`nin YENİ bir STW round'u BAŞLATTIĞINDA (bkz.
        // `nox_cycle_possible_root`) TÜM worker'ları uyandırabilmesi İçİn.
        // Windows'ta `wake_write_fd == null` OLDUĞUNDAN (bkz. `self_pipe.
        // zig`) bu adım SESSİZCE ATLANIR — YENİ bir regresyon DEĞİL,
        // wake-fd mekanizmasının KENDİSİ ZATEN Windows'ta YOK.
        if (builtin.os.tag != .windows) {
            if (self.wake_write_fd) |wfd| {
                link.wake_fds[link.own_slot].store(@intCast(wfd), .release);
            }
        }
    }

    /// Faz MN.4/5.8: `sibling_deques[own_slot]` — BU worker'ın KENDİ
    /// deque'i (spawn/pop İçİn). `sibling_deques.len == 0` (havuzsuz —
    /// QBE'nin bağımsız worker'ları, tek-worker `nox.http.serve()`) İKEN
    /// `null` döner.
    /// Faz MN.12: `pub` — `runtime/stdlib_shims/http_server.zig`nin
    /// `serveImpl`i de (`acquireStack`/`releaseStack` GİBİ, bkz. onların
    /// AYNI gerekçeli belge notu) ARTIK bunu ÇAĞIRIYOR: kabul edilen
    /// bağlantı fiber'larını `spawn()`İLE BİREBİR AYNI "deque'e it, İLK-
    /// çalıştırmadan SONRA sabitlen" desenine taşıyıp `SO_REUSEPORT`nin
    /// (Faz MN.11) worker'lar arası dengesiz bağlantı dağılımını work-
    /// stealing İLE KENDİLİĞİNDEN düzeltilebilir hale getirmek İçİn
    /// (havuzsuz durumda `null` dönmesi SAYESİNDE QBE/tek-worker yolunda
    /// SIFIR davranış değişikliği).
    pub fn ownDeque(self: *Scheduler) ?*Deque {
        if (self.sibling_deques.len == 0) return null;
        return self.sibling_deques[self.own_slot];
    }

    fn armWakeFd(self: *Scheduler) void {
        const fd = self.wake_read_fd orelse return;
        self.wake_ctx = .{ .fiber = &self.wake_sentinel };
        self.reactor.register(fd, .read, &self.wake_ctx) catch {};
    }

    /// Havuzdan bir yığın alır (varsa); yoksa genel ayırıcıdan taze tahsis eder.
    /// Dil stabilizasyonu fazı §M.4: `pub` — `runtime/stdlib_shims/
    /// http_server.zig`nin bağlantı fiber'ları İÇİN de (`spawn`ın KENDİSİ
    /// GİBİ) havuzu KULLANABİLMESİ için (bkz. onun belge notu — ÖNCEDEN
    /// `Fiber.create`yi DOĞRUDAN çağırıp havuzu HİÇ KULLANMIYORDU).
    pub fn acquireStack(self: *Scheduler) ![]align(fiber_mod.STACK_ALIGN) u8 {
        if (self.stack_pool.pop()) |stack| return stack;
        // Faz MN.8, Bulgu C: TAZE yığınlar ARTIK `self.allocator.alignedAlloc`
        // YERİNE koruma-sayfalı `fiber_mod.allocGuardedStack()` İLE tahsis
        // edilir (bkz. onun belge notu) — havuzdan GERİ KAZANILAN yığınlar
        // (yukarıdaki `pop()` dalı) zaten koruma-sayfalı OLARAK kuruldu,
        // BURADA tekrar dokunulmaz.
        return fiber_mod.allocGuardedStack();
    }

    /// Bir yığını (artık kullanılmayan) genel ayırıcıya GERİ VERMEK yerine
    /// havuza ekler. Havuzun kendisi büyütülemezse (OOM — son derece
    /// olası değil ama Zig'in `try` sözleşmesi bunu ele almayı gerektirir),
    /// akışı bozmamak için bloğu doğrudan serbest bırakır. `pub` — bkz.
    /// `acquireStack`in AYNI gerekçesi.
    pub fn releaseStack(self: *Scheduler, stack: []align(fiber_mod.STACK_ALIGN) u8) void {
        self.stack_pool.append(self.allocator, stack) catch {
            fiber_mod.freeGuardedStack(stack);
        };
    }

    /// Bir fiber'ı hazır kuyruğuna ekler — HEM ilk `spawn`da HEM bir görev
    /// tamamlanıp bekleyenini uyandırırken kullanılır. Faz MN.4/5: ARTIK
    /// `ready_lock` İLE korunuyor VE `wake_sentinel`i (bkz. onun belge
    /// notu) ÖZEL olarak ele alıyor; ÇAĞIRAN iş parçacığı bu zamanlayıcının
    /// SAHİBİ DEĞİLSE (havuzdaki YABANCI bir worker — bkz. `owner_tid`)
    /// kilitli `append` SONRASI wake-fd'ye bir bayt yazarak hedef worker'ı
    /// (`reactor.poll()`da BLOKE olmuş olsa BİLE) uyandırır.
    pub fn markReady(self: *Scheduler, fiber: *Fiber) void {
        if (fiber == &self.wake_sentinel) {
            // Wake-fd ateşledi — GERÇEK bir fiber DEĞİL, sadece byte'ı
            // tüket VE reaktöre YENİDEN kaydol (EV_ONESHOT/EPOLLONESHOT
            // her ateşlemeden sonra SÖKÜLÜR/silahsızlanır).
            if (self.wake_read_fd) |fd| self_pipe.drainWakeFd(fd);
            self.armWakeFd();
            return;
        }
        const is_foreign = self.pool_live_count != null and std.Thread.getCurrentId() != self.owner_tid;
        self.ready_lock.lock();
        self.ready.append(self.allocator, fiber) catch @panic("OOM: zamanlayıcı hazır kuyruğu büyütülemedi");
        self.ready_lock.unlock();
        if (is_foreign) {
            // Faz MN.8, Bulgu B: çapraz-worker bir uyandırma — BİR
            // worker'ın `poolWideDeadlockCheck`i TAM O ANDA "boş"
            // GÖRDÜĞÜ kendi ready/deque'sini BU EKLEMEDEN HEMEN ÖNCE
            // kontrol ETMİŞ olabileceğinden, epoch'u İŞARETLE — deadlock
            // İLANI, GÖZLEM PENCERESİ boyunca BU artışın OLMADIĞINI
            // KANITLAMAK ZORUNDA kalacak.
            if (self.pool_activity_epoch) |epoch| _ = epoch.fetchAdd(1, .release);
            if (self.wake_write_fd) |fd| self_pipe.signalWakeFd(fd);
        }
    }

    /// ŞU AN çalışan fiber tarafından çağrılır (yalnızca fiber bağlamında
    /// anlamlıdır): kontrolü zamanlayıcı döngüsüne geri verir. `markReady`
    /// TEKRAR çağrılana kadar hazır kuyruğuna EKLENMEZ — yani bu bir
    /// "bloke ol" ilkelidir (kooperatif "sırayı bırak" değil).
    pub fn suspendCurrent(self: *Scheduler) void {
        const fiber = self.current.?;
        fiber.yield();
    }

    /// `suspendCurrent` ile AYNI çağıran-fiber varsayımıyla, ama Task/Channel
    /// senkronizasyonu YERİNE bir G/Ç olayı (bkz. `io_reactor.zig`) bekler:
    /// ÖNCE reaktöre kaydolur (`fd` `filter` yönünde hazır olunca `waiter`ı
    /// BİR KEZ bildirir — bkz. `IoReactor.register`), `waiting_on_io`yu
    /// artırır, SONRA askıya alır. Fiber TEKRAR çalıştırıldığında (reaktör
    /// `poll` ile hazır kuyruğa koyduktan SONRA `run` sırası geldiğinde)
    /// `waiting_on_io` azaltılır. Çağıran (bkz. `runtime/async_rt/io.zig`)
    /// bu noktadan SONRA işlemi (accept/read/write) TEKRAR DENEMELİDİR —
    /// kqueue yalnızca "hazır" der, işlemin KENDİSİNİ YAPMAZ.
    pub fn suspendForIo(self: *Scheduler, fd: std.posix.fd_t, filter: io_reactor.Filter) void {
        const fiber = self.current.?;
        var ctx: io_reactor.WaitCtx = .{ .fiber = fiber };
        self.reactor.register(fd, filter, &ctx) catch @panic("kqueue register basarisiz");
        self.waiting_on_io += 1;
        if (self.pool_waiting_on_io) |pwio| _ = pwio.fetchAdd(1, .monotonic);
        fiber.yield();
        self.waiting_on_io -= 1;
        if (self.pool_waiting_on_io) |pwio| _ = pwio.fetchSub(1, .monotonic);
    }

    /// Faz HH.7 (bkz. nox-teknik-spesifikasyon.md §3.68): `suspendForIo`
    /// İLE AYNI, ama `fd` `filter` yönünde hazır OLANA KADAR **VEYA**
    /// `timeout_ms` GEÇENE KADAR (HANGİSİ ÖNCE olursa) bekler — bkz.
    /// `io_reactor.zig`nin `registerWithTimeout`i. `ctx`, BU fonksiyonun
    /// KENDİ yığın çerçevesinde (fiber askıya ALINDIĞI SÜRECE CANLI kalan
    /// bellek) yaşar — `reactor.poll()`, fiber TEKRAR ÇALIŞTIRILMADAN ÖNCE
    /// `ctx.result`ı yazar, bu yüzden `fiber.yield()`DEN DÖNÜLDÜĞÜNDE
    /// sonuç ZATEN hazırdır.
    pub fn suspendForIoOrTimeout(self: *Scheduler, fd: std.posix.fd_t, filter: io_reactor.Filter, timeout_ms: u32) io_reactor.WaitResult {
        const fiber = self.current.?;
        var ctx: io_reactor.WaitCtx = .{ .fiber = fiber };
        self.reactor.registerWithTimeout(fd, filter, timeout_ms, &ctx) catch @panic("kqueue register basarisiz");
        self.waiting_on_io += 1;
        if (self.pool_waiting_on_io) |pwio| _ = pwio.fetchAdd(1, .monotonic);
        fiber.yield();
        self.waiting_on_io -= 1;
        if (self.pool_waiting_on_io) |pwio| _ = pwio.fetchSub(1, .monotonic);
        return ctx.result;
    }

    /// Faz MN.6: kooperatif "dünyayı-durdur" (STW) bariyerine KATILIM —
    /// `run()`nün `while (true) { ... }` döngüsünün TAM İLK SATIRI olarak
    /// çağrılır, bu YÜZDEN HER ZAMAN `fiber.resume_()` ÇAĞRILARI ARASINDA
    /// çalışır (bir worker BURADAYKEN HİÇBİR fiber'ın ORTASINDA OLAMAZ) —
    /// `cycle_detector.zig`nin `nox_cycle_collect`i (mark/scan geçişinde
    /// BAŞKA nesnelerin refcount'unu ATOMİK OLMAYAN şekilde okur/yazar,
    /// bkz. onun belge notu) SADECE `collect_fn` BURADAN, TÜM `n` worker
    /// KANITLANMIŞ ŞEKİLDE bariyerdeyken ÇAĞRILDIĞINDAN GÜVENLİDİR.
    ///
    /// **"Sense-reversing barrier" — bkz. proje planı, tasarım #1:** TEK
    /// bir paylaşılan `bool`ün (HEM giriş kapısı HEM bekleme-koşulu
    /// OLARAK) YENİDEN KULLANILMASI, art arda İKİ round HIZLI
    /// tetiklendiğinde bir "straggler" worker'ın YANLIŞLIKLA SONRAKİ
    /// round'u "önceki round HÂLÂ sürüyor" SANIP SONSUZA KADAR BLOKE
    /// KALMASINA (TÜM sonraki toplama round'larının SESSİZCE DURMASINA)
    /// yol açan GERÇEK bir ABA-tipi hata İDİ — HER worker'ın KENDİ
    /// (paylaşılmayan) `stw_local_sense`i + PAYLAŞILAN `stw_sense`in
    /// SADECE round TAMAMLANDIĞINDA lider TARAFINDAN YAZILMASI BUNU
    /// yapısal olarak İMKANSIZ kılar.
    fn stwParticipate(self: *Scheduler) void {
        const reqp = self.stw_requested orelse return;
        if (!reqp.load(.acquire)) return;
        self.stw_local_sense = !self.stw_local_sense;
        const arrived = self.stw_arrived.?;
        const n = self.sibling_deques.len;
        if (arrived.fetchAdd(1, .acq_rel) + 1 == n) {
            // SON varan → lider. TÜM n worker ARTIK KANITLANMIŞ şekilde
            // fiber'ın ORTASINDA DEĞİL — collect'i GÜVENLE çalıştırabiliriz.
            if (self.collect_fn) |f| f(self.rt);
            arrived.store(0, .release);
            // KRİTİK SIRA: ÖNCE `reqp`i temizle, SONRA straggler'ları
            // `stw_sense` ÜZERİNDEN SERBEST BIRAK — TERSİ (sense ÖNCE)
            // GERÇEK bir yarış İçERİR: uyanan bir straggler `stwParticipate`i
            // HEMEN TERK EDİP (bu testte/production `run()`nün döngüsünde)
            // GERİ DÖNÜP `reqp`i TEKRAR OKUYABİLİR — leader HENÜZ `reqp`i
            // TEMİZLEMEMİŞSE, straggler AYNI (ESKİ) round İçİn İKİNCİ KEZ
            // `stwParticipate`e GİRER (`local_sense`ini TEKRAR TERSİNE
            // ÇEVİRİP `arrived`e TEKRAR `fetchAdd` eder) — bu da `local_
            // sense`in kalıcı olarak SENKRONİZASYONUNU BOZAR (GERÇEKTEN
            // GÖZLEMLENDİ: `zig build test`in TAM takımında `Thread.yield()`
            // içinde SONSUZA KADAR dönen bir livelock). `reqp`i ÖNCE
            // temizlemek, `stw_sense`i acquire-load EDEN HER straggler'ın
            // (release-acquire senkronizasyonu SAYESİNDE) `reqp == false`yi
            // ZATEN GÖRMESİNİ GARANTİ eder — geri döndüğünde ya YENİ bir
            // GERÇEK round'u (reqp tekrar true İSE) ya HİÇBİR ŞEYİ (henüz
            // İSE) görür, ASLA ESKİ round'u TEKRAR görmez.
            reqp.store(false, .release);
            self.stw_sense.?.store(self.stw_local_sense, .release);
        } else {
            while (self.stw_sense.?.load(.acquire) != self.stw_local_sense) sleepMs(1);
        }
    }

    /// Faz MN.4: KENDİ deque'i BOŞ İKEN kardeşlerden (round-robin, KENDİ
    /// slotundan HEMEN SONRAKİNDEN başlayarak) TEK bir fiber çalmayı
    /// DENER — Cilk'in klasik "SADECE spawn edilmiş, henüz BAŞLAMAMIŞ
    /// görevler çalınabilir" basitleştirmesi (bkz. proje planı, tasarım
    /// #1): bir fiber BİR KEZ çalınıp ÇALIŞTIRILDIKTAN SONRA KALICI olarak
    /// bu worker'a SABİTLENİR (`markReady`nin `owner_tid` kontrolü bunu
    /// doğal olarak sağlar — bu fonksiyon SADECE İLK, hazır-kuyruğa HİÇ
    /// GİRMEMİŞ fiber'ları çalar).
    fn tryStealFromSiblings(self: *Scheduler) ?*Fiber {
        const siblings = self.sibling_deques;
        var i: usize = 0;
        while (i < siblings.len) : (i += 1) {
            const idx = (self.own_slot + 1 + i) % siblings.len;
            if (idx == self.own_slot) continue;
            if (siblings[idx].steal()) |f| return f;
        }
        return null;
    }

    /// Faz MN.5: havuz-çapında YAKLAŞIK deadlock tespiti — bkz. proje
    /// planı, tasarım #4 ("Go'nun checkdead()'inin BASİTLEŞTİRİLMİŞ hali,
    /// TAM bir dağıtık-sonlanma algoritması DEĞİL"). Bu worker'ın KENDİ
    /// hazır kuyruğu+deque'i BOŞ VE kardeşlerden çalma BAŞARISIZ OLDUĞUNDA
    /// çağrılır. **KRİTİK doğruluk noktası**: `pool_live_count > 0` TEK
    /// BAŞINA deadlock'a İŞARET ETMEZ — BAŞKA bir worker HÂLÂ MEŞGUL
    /// olabilir (TAMAMEN NORMAL, dengesiz bir iş yükü) — bu YÜZDEN ÖNCE
    /// `self`i `pool_idle_workers`e SAYAR, SONRA SABİT KÜÇÜK bir sayıda
    /// KISA bekleme+yeniden-çalma-denemesi+yeniden-kontrol turu (ANLIK
    /// bir yarışı — ör. BAŞKA bir worker'ın TAM O ANDA bir `spawn` yapması
    /// — yanlış-pozitife çevirmemek İçİn) SONUNDA `pool_idle_workers ==
    /// (havuzdaki TOPLAM worker sayısı)` **VE** `pool_live_count > 0`
    /// **VE** `pool_waiting_on_io == 0` İSE deadlock İLAN eder — yani
    /// SADECE TÜM worker'lar AYNI ANDA boştaysa.
    /// **GERÇEK, Faz MN.7a'da DENEYEREK bulunan bir hata İçİn EKLENDİ**:
    /// `poolWideDeadlockCheck`nin (aşağıda) döngüsü SADECE `tryStealFrom
    /// Siblings`e (KARDEŞ DEQUE'LERİNİ kontrol eder) VE pool-çapında
    /// SAYAÇLARA (`live`/`waiting_io`/`idle`) bakıyordu — `self.ready`
    /// (BAŞKA bir worker'ın `markReady` İLE, kilit ALTINDA, ÇAPRAZ-worker
    /// EKLEDİĞİ hazır fiber'lar) HİÇ KONTROL EDİLMİYORDU. Somut senaryo:
    /// worker A `entry()`i askıya alır (`await t`), `t` BAŞKA bir worker
    /// TARAFINDAN ÇALINIP tamamlanır VE `entryTrampoline` `t.scheduler`
    /// (= worker A) ÜZERİNDEN `markReady(entry_fiber)` ÇAĞIRIR — BU,
    /// `entry_fiber`ı worker A'nın `self.ready`SİNE EKLER, AMA worker A
    /// O ANDA `poolWideDeadlockCheck`nin 20-denemelik döngüsü İçİNDEYSE,
    /// BU YENİ hazır fiber'ı ASLA GÖRMEZ (`tryStealFromSiblings` DEQUE'
    /// LERE bakar, `ready` LİSTESİNE DEĞİL) — TÜM worker'lar AYNI ANDA
    /// (BAŞKA hiçbir DEQUE'de İş YOKKEN, AMA worker A'nın `ready`sinde
    /// TAM OLARAK bu fiber VARKEN) "idle" SAYILDIĞINDA, FONKSİYON YANLIŞ
    /// pozitif bir DEADLOCK ilan eder. `noxc build --release` İLE GERÇEK
    /// bir `nox.thread.pool_run` programında (`spawn`/`await`nin AYNI
    /// döngüde TEKRARLANDIĞI, 4 worker'lı) ARALIKLI olarak GERÇEKTEN
    /// gözlemlendi. Düzeltme: `self.ready`nin (kilit ALTINDA) DOLU olup
    /// OLMADIĞINI da kontrol et — DOLUYSA, BU deadlock DEĞİL, SADECE
    /// worker'ın run() döngüsünün BAŞINA DÖNÜP `ready`den POP ETMESİ
    /// GEREKEN bir an.
    fn hasLocalReadyWork(self: *Scheduler) bool {
        self.ready_lock.lock();
        defer self.ready_lock.unlock();
        return self.ready.items.len > 0;
    }

    /// **Faz MN.8, Bulgu B — epoch-doğrulamalı kök-neden düzeltmesi**
    /// (bkz. proje planı): MN.7a/7b doğrulamasında TEKRAR TEKRAR
    /// GERÇEKTEN gözlemlenen ("toplu spawn + sıralı await" deseni —
    /// GERÇEK bir fan-out/fan-in kullanımı, YAPAY bir stres deseni
    /// DEĞİL) YANLIŞ pozitif deadlock tespitinin HEDEFİ. Aşağıdaki
    /// 20-denemelik retry döngüsü (GENUİNE meşgul-ama-henüz-üretmemiş
    /// durumlara ZAMAN TANIMAK İçİn) DEĞİŞMEDEN KALIR — YENİ olan,
    /// deadlock İLAN ETMEDEN HEMEN ÖNCEKİ SON kontroldür: `pool_
    /// activity_epoch`un (bkz. `markReady`nin `is_foreign` dalı VE
    /// `spawn`nin deque-push dalı — BUNLAR HER "çalınabilir YENİ İş
    /// üretimi" olayında `fetchAdd(1, .release)` yapar) GÖZLEM
    /// PENCERESİNİN (bu fonksiyon ÇAĞRILDIĞI ANDAN deadlock kararı
    /// verileceği ANA KADAR) BAŞINDA VE SONUNDA okunan İKİ değerinin
    /// EŞİT OLDUĞU `.acquire` sıralı okumalarla KANITLANMASI — SADECE
    /// "son anlık görüntü boş GÖRÜNDÜ" DEĞİL, TÜM pencerede HİÇBİR
    /// ÜRETİM olayının GERÇEKLEŞMEDİĞİ. Epoch DEĞİŞTİYSE (BİR ŞEY
    /// üretildi — belki TAM O ANDA bir görev BİTİP bir bekleyeni
    /// UYANDIRDI), deadlock İLAN EDİLMEZ — çağıran `run()` döngüsü
    /// BAŞA DÖNÜP YENİDEN dener (bu FONKSİYON YENİDEN çağrılır).
    fn poolWideDeadlockCheck(self: *Scheduler) bool {
        const n_workers = self.sibling_deques.len;
        const live = self.pool_live_count.?;
        const waiting_io = self.pool_waiting_on_io.?;
        const idle = self.pool_idle_workers.?;
        const epoch = self.pool_activity_epoch.?;
        _ = idle.fetchAdd(1, .monotonic);
        defer _ = idle.fetchSub(1, .monotonic);

        const epoch_before = epoch.load(.acquire);

        var attempt: usize = 0;
        while (attempt < 20) : (attempt += 1) {
            sleepMs(1);
            if (self.hasLocalReadyWork()) return false;
            if (self.tryStealFromSiblings()) |f| {
                self.markReady(f);
                return false;
            }
            if (live.load(.monotonic) == 0) return false;
            if (waiting_io.load(.monotonic) > 0) return false;
            if (idle.load(.monotonic) < n_workers) return false;
        }
        if (self.hasLocalReadyWork()) return false;
        if (!(idle.load(.monotonic) >= n_workers and
            live.load(.monotonic) > 0 and
            waiting_io.load(.monotonic) == 0))
        {
            return false;
        }
        return epoch.load(.acquire) == epoch_before;
    }

    pub const RunError = error{Deadlock};

    /// Hazır kuyruk boşalana kadar (ya da TÜM canlı görevler bloke olup
    /// hazır kuyruk boşaldığında `error.Deadlock` ile) çalışır. **D.0
    /// güncellemesi:** hazır kuyruk boşken artık İKİ olası durum var —
    /// TÜM canlı görevler Task/Channel'da tıkanmış (GERÇEK deadlock,
    /// DEĞİŞMEDEN `error.Deadlock`) ya da bir/daha fazla görev bir G/Ç
    /// olayı BEKLİYOR (`waiting_on_io > 0`) — bu durumda YAPACAK BAŞKA İŞ
    /// olmadığından reaktörde BLOKLAYARAK beklemek GÜVENLİDİR (`reactor.poll`),
    /// en az bir fiber'ı hazır kuyruğa geri koyar VE döngü DEVAM eder.
    pub fn run(self: *Scheduler) RunError!void {
        while (true) {
            // Faz MN.6: STW bariyerine katılım — döngünün TAM İLK satırı
            // (bkz. `stwParticipate`nin belge notu, "HER ZAMAN fiber.
            // resume_() ÇAĞRILARI ARASINDA" garantisi). `continue` İLE
            // buraya DÖNEN HER yol (G/Ç-poll SONRASI, çalma/deadlock-
            // kontrolü BAŞARISIZ OLDUĞUNDA) DA kapsanır.
            self.stwParticipate();
            // Faz MN.4/5: `ready` ARTIK BİRDEN FAZLA iş parçacığı TARAFINDAN
            // (yerel `run` döngüsü BURADA pop eder, YABANCI worker'lar
            // `markReady` İLE append eder) dokunulabilir — okuma (uzunluk
            // kontrolü) VE pop (`swapRemove`) AYNI `ready_lock` ALTINDA,
            // TEK bir kritik bölümde yapılır (aksi halde BAŞKA bir iş
            // parçacığının `append`i SIRASINDA `.items` alanını [ptr+len]
            // KİLİTSİZ okumak GERÇEK bir veri yarışı olurdu).
            self.ready_lock.lock();
            // `swapRemove(0)` — bkz. HTTP yüksek-eşzamanlılık araştırması
            // (benchmarks/RESULTS.md "Bölüm 3"): `orderedRemove(0)` HER
            // fiber devralımında hazır kuyruğun TÜM KALAN elemanlarını BİR
            // konum KAYDIRIR (O(n)) — `reactor.poll` TEK bir çağrıda EN
            // FAZLA 64 fiber'ı BİRDEN hazır kuyruğa EKLEYEBİLDİĞİNDEN (bkz.
            // `io_reactor.zig`nin `events: [64]` arabelleği), yoğun G/Ç
            // altında BU PARTİYİ boşaltmak O(n²) TOPLAM kaydırmaya
            // dönüşürdü. Zamanlayıcının hazır kuyruğu YALNIZCA ADALET
            // (her fiber ER YA DA GEÇ çalışır) GARANTİ eder — SIRALAMA
            // (FIFO) davranışsal olarak GEREKMEZ (bkz. `io.zig`nin "reader
            // ÖNCE spawn edilir" testi — 2 elemanlı bir kuyrukta
            // `swapRemove(0)`, `orderedRemove(0)` İLE AYNI sonucu verir,
            // bu yüzden O test DEĞİŞMEDEN geçer); `swapRemove`, kaldırılan
            // elemanın YERİNE kuyruğun SON elemanını taşıyarak O(1) yapar.
            const maybe_fiber: ?*Fiber = if (self.ready.items.len > 0) self.ready.swapRemove(0) else null;
            self.ready_lock.unlock();
            const fiber = maybe_fiber orelse blk: {
                // Faz MN.4: KENDİ hazır kuyruğu BOŞ — havuzluysa (bkz.
                // `pool_live_count`) ÖNCE KENDİ deque'inden pop, SONRA
                // kardeşlerden çal DENE (bkz. tasarım #1 — "spawn-anında
                // çal, İLK-çalıştırmadan SONRA sabitlen").
                if (self.pool_live_count) |plc| {
                    if (self.ownDeque().?.popBottom()) |f| break :blk f;
                    if (self.tryStealFromSiblings()) |f| break :blk f;
                    // **KRİTİK**: BURADAN SONRA YEREL `self.live_count`/
                    // `self.waiting_on_io` ARTIK GÜVENİLMEZ — bir fiber'ı
                    // KİMİN `spawn` ETTİĞİ (o zamanlayıcının `live_count`unu
                    // artırır) İLE KİMİN ÇALIŞTIRIP BİTİRDİĞİ (çalınmış
                    // olabilir, BAŞKA bir worker) FARKLI olabileceğinden,
                    // `self.live_count` BU worker'ın kendi spawn ETTİKLERİNİ
                    // bile TAM YANSITMAZ (bkz. aşağıdaki tamamlanma dalı —
                    // `pool_live_count` KULLANILIR, `self.live_count`e ASLA
                    // dokunulmaz). Bu YÜZDEN pool-çapında karar SADECE
                    // `pool_live_count`/`pool_waiting_on_io`ya bakar.
                    //
                    // **GERÇEK, worker_pool.zig'in KENDİ STW-stres testinde
                    // DENEYEREK bulunan bir hata İçİN EKLENDİ (37+ dakika
                    // ASILI KALAN bir test İLE gözlemlendi, `sample` İLE
                    // teşhis edildi)**: BU worker `plc==0` GÖRÜP run()'DAN
                    // KALICI olarak `return` ettiğinde, EĞER TAM O ANDA
                    // BAŞKA bir worker'ın (henüz TAMAMLANMAMIŞ) fiber'ı bir
                    // STW round'u ZATEN İSTEMİŞSE (`stw_requested=true`,
                    // O fiber HENÜZ BİTMEDİĞİNDEN `plc` HÂLÂ onu SAYIYORDU,
                    // ama SONRA O fiber de BİTİP `plc`yi 0'A İNDİRDİ) — BU
                    // worker O round'a ASLA KATILMAZ (`stwParticipate`,
                    // SADECE `while(true)` döngüsünün BAŞINDA çağrılır, BU
                    // `return` YOLU HİÇ oraya UĞRAMAZ) — bariyerin GEREKTİRDİĞİ
                    // `n = sibling_deques.len` katılımcı SAYISI KALICI olarak
                    // EKSİK KALIR, KALAN worker'lar `stw_sense`i SONSUZA KADAR
                    // BEKLER. Düzeltme: `stw_requested` bekliyorsa ÖNCE
                    // katıl, SONRA (round KAPANDIKTAN SONRA) YENİDEN plc'yi
                    // kontrol et — `plc`nin fetchSub'ı (aşağıda) `.release`,
                    // BU okuma `.acquire` OLDUĞUNDAN (release-sequence
                    // kuralı gereği), BU worker plc==0'ı GÖRDÜĞÜ AN, O 0'ı
                    // ÜRETEN fiber'ın KENDİ ÖNCESİNDE yazdığı `stw_requested`
                    // DEĞERİNİ de GARANTİLİ olarak görür — bu YÜZDEN AŞAĞIDAKİ
                    // kontrol "kaçırma" YAŞAMAZ.
                    if (plc.load(.acquire) == 0) {
                        if (self.stw_requested) |reqp| {
                            if (reqp.load(.acquire)) {
                                self.stwParticipate();
                                continue;
                            }
                        }
                        return;
                    }
                    if (self.waiting_on_io > 0) {
                        // KENDİ fiber'larımızdan biri G/Ç bekliyor —
                        // reaktörümüzde bloklamak TAMAMEN GÜVENLİ (`suspendForIo`
                        // ile AYNI zamanlayıcı KAYDOLUR/uyandırılır, bkz.
                        // onun belge notu — bir fiber PINLENDIKTEN sonra
                        // KENDİ G/Ç uyandırması HİÇ göç ETMEZ).
                        _ = self.reactor.poll(self) catch @panic("kqueue poll basarisiz");
                        continue;
                    }
                    if (self.poolWideDeadlockCheck()) return error.Deadlock;
                    continue;
                }
                // Havuzsuz kullanım — BİREBİR ESKİ (Faz MN.4/5 ÖNCESİ)
                // davranış, SIFIR değişiklik.
                if (self.live_count == 0) return;
                if (self.waiting_on_io > 0) {
                    _ = self.reactor.poll(self) catch @panic("kqueue poll basarisiz");
                    continue;
                }
                return error.Deadlock;
            };
            self.current = fiber;
            fiber.resume_(&self.root_ctx);
            self.current = null;
            if (fiber.finished) {
                // Faz MN.4/5: havuzluysa `pool_live_count` (PAYLAŞILAN,
                // HANGİ worker'ın azalttığından BAĞIMSIZ doğru) azaltılır —
                // YEREL `self.live_count` KESİNLİKLE dokunulmaz (bkz.
                // YUKARIDAKİ "KRİTİK" not — bu fiber BAŞKA bir worker
                // TARAFINDAN spawn EDİLMİŞ olabilir, `self.live_count -= 1`
                // O DURUMDA YANLIŞ worker'ın sayacını azaltır VE (0'dan
                // başladığından) usize TAŞMASIYLA PANİKLER).
                if (self.pool_live_count) |plc| {
                    // `.release` — YUKARIDAKİ (`plc==0` çıkış yolu) `.acquire`
                    // okumasıyla EŞLEŞİR; bir fiber'ın BİTİŞ-ÖNCESİ yazdığı
                    // `stw_requested`in, plc'yi 0'a indiren fetchSub'ı GÖREN
                    // HERHANGİ bir worker'a GARANTİLİ olarak GÖRÜNÜR OLMASI
                    // İçİN (release-sequence kuralı) GEREKLİ.
                    _ = plc.fetchSub(1, .release);
                } else {
                    self.live_count -= 1;
                }
                self.releaseStack(fiber.destroyKeepStack());
            }
        }
    }
};

/// Faz MN.5: `poolWideDeadlockCheck`nin KISA bekleme turları İçİn — `std.
/// Thread`da bir `sleep` metodu YOK (Zig 0.16.0'da doğrulandı) — `runtime/
/// stdlib_shims/time.zig`nin `nox_time_sleep_ms_raw`ı İLE AYNI desen
/// (`std.c.nanosleep`/Windows'ta `kernel32.Sleep`).
const WinSleep = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn Sleep(ms: u32) callconv(.c) void;
} else struct {};
fn sleepMs(ms: i64) void {
    if (builtin.os.tag == .windows) {
        WinSleep.Sleep(@intCast(ms));
        return;
    }
    const ts: std.c.timespec = .{
        .sec = @divTrunc(ms, std.time.ms_per_s),
        .nsec = @mod(ms, std.time.ms_per_s) * std.time.ns_per_ms,
    };
    _ = std.c.nanosleep(&ts, null);
}

/// `T` dönen bir `spawn`dan gelen tutamaç. `await_` çağrıldığında görev
/// tamamlanmışsa sonucu HEMEN döner; değilse ÇAĞIRAN fiber'ı bu görevin
/// "bekleyeni" olarak kaydedip askıya alır (bkz. `Scheduler.suspendCurrent`)
/// — görev tamamlanınca `entryTrampoline` bekleyeni tekrar hazır kuyruğuna
/// ekler.
pub fn Task(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Faz MN.8, Bulgu B (KÖK NEDEN düzeltmesi) — `state`nin özel
        /// değerleri: `PENDING`(0) görev HENÜZ bitmedi, hiçbir bekleyen
        /// KAYITLI DEĞİL; `COMPLETED`(1) görev bitti (`result` GÜVENLE
        /// okunabilir); BAŞKA HERHANGİ bir değer KAYITLI bir bekleyenin
        /// `*Fiber` işaretçisidir (Fiber'lar HER ZAMAN >=8-bayt hizalı
        /// tahsis edildiğinden 0/1 İLE ASLA ÇAKIŞMAZ).
        pub const PENDING: usize = 0;
        pub const COMPLETED: usize = 1;

        /// **v1.29.1 — GERÇEK, DIŞARIDAN bulunup DOĞRULANMIŞ bir hata İçİN
        /// eklendi (Channel[T]'nin MN.9.1'de aldığı AYNI düzeltmenin
        /// Task[T]'ye uygulanmamış hali).** `checker.zig`nin `isSpawnParamSafeType`si
        /// `Task[T]`yi bir `spawn`e argüman OLARAK ZATEN İZİN VERİYORDU — bir
        /// fiber KENDİ oluşturduğu bir `Task`ı BAŞKA bir spawn edilmiş
        /// fonksiyona geçirebilir, O fonksiyonun fiber'ı BAŞKA bir worker'a
        /// ÇALINABİLİR, VE `await_()` O ÇALINMIŞ fiber'DAN çağrılırsa
        /// ESKİDEN `self.scheduler`i (görev OLUŞTURULDUĞUNDA sabitlenen,
        /// yani BAŞKA bir worker'ın scheduler'ı) kullanıyordu — Channel'ın
        /// AYNI hatasıyla BİREBİR (bkz. `currentScheduler()`nin belge notu).
        /// Düzeltme: Channel'ın `RecvSlot`/`SendSlot` deseninin AYNISI —
        /// bekleyenin fiber'I + O fiber'ın PİNLİ OLDUĞU (askıya alma ANINDA
        /// `currentScheduler()` İLE KAYDEDİLEN) scheduler'ı BİRLİKTE
        /// saklanır, `entryTrampoline` uyandırmayı O KAYITLI scheduler
        /// ÜZERİNDEN yapar.
        const Waiter = struct {
            fiber: *Fiber,
            scheduler: *Scheduler,
        };

        scheduler: *Scheduler,
        fiber: *Fiber = undefined,
        /// `callconv(.c)`: bu alan çoğunlukla QBE'nin ÜRETTİĞİ (dolayısıyla
        /// C ABI'siyle derlenmiş) bir sarmalayıcı fonksiyonu tutar (bkz.
        /// `runtime/async_rt/bridge.zig`, `nox_async_spawn`) — çağrı
        /// kuralının AÇIKÇA belirtilmesi (Zig'in imzaya göre değişebilen
        /// varsayılanına GÜVENMEK yerine) bu FFI sınırında zorunludur.
        func: *const fn (*anyopaque) callconv(.c) T,
        arg: *anyopaque,
        result: T = undefined,
        /// Faz MN.8, Bulgu B — `entryTrampoline`/`await_` ARASINDAKİ
        /// "kayıp uyandırma" (lost wakeup) yarışının KÖK NEDEN düzeltmesi:
        /// ESKİDEN `completed: bool`/`waiter: ?*Fiber` İKİ AYRI, PLAIN
        /// (senkronize-OLMAYAN) alandı — `nox.thread.pool_run`ın 1000/
        /// 10000 görevlik toplu-spawn+sıralı-await stres testinde
        /// GERÇEKTEN, TEKRARLANABİLİR şekilde bulundu: `entryTrampoline`
        /// (BİR worker'da) `completed=true` YAZARKEN, `await_` (BAŞKA
        /// bir worker'da, ÇALINAN bir görevin sonucunu bekleyen) `self.
        /// waiter = current_fiber` YAZARKEN ARASINDA HİÇBİR bellek
        /// bariyeri YOKTU — M:1 modelde SORUN DEĞİLDİ (TEK iş parçacığı,
        /// program SIRASI YETERLİYDİ), M:N work-stealing'de GERÇEK bir
        /// veri yarışıydı VE `poolWideDeadlockCheck`nin `pool_activity_
        /// epoch`u BİLE BUNU YAKALAYAMADI (o mekanizma "YANLIŞ pozitif
        /// deadlock tespiti"ni HEDEFLİYORDU — BURADAKİ SORUN "algılama"
        /// DEĞİL, waiter'ın HİÇ KAYDEDİLMEMESİ/HİÇ UYANDIRILMAMASIYDI,
        /// yani GERÇEK bir kayıp-uyandırma). Düzeltme: TEK bir atomik
        /// `state` alanı + CAS tabanlı protokol (klasik "single-shot
        /// future" deseni) — `await_`, `PENDING`DEN KENDİ fiber'ına CAS
        /// yapmayı DENER; BAŞARILIYSA GERÇEKTEN kaydolmuş VE askıya
        /// alınmış olur; BAŞARISIZSA (state ZATEN `COMPLETED`) `result`
        /// (CAS'ın KENDİ `.acquire`si SAYESİNDE) GÜVENLE GÖRÜNÜRDÜR, HİÇ
        /// askıya ALINMADAN döner. `entryTrampoline` KOŞULSUZ `swap
        /// (COMPLETED, .acq_rel)` yapar — ESKİ değer `PENDING` İSE
        /// bekleyen YOK; BAŞKA (bir `*Fiber`) İSE O ANDA doğru bekleyeni
        /// GÜVENLE (kaçırmadan) uyandırır. `result`ın uyandırılan
        /// tarafta GÖRÜNÜRLÜĞÜ AYRICA `markReady`nin KENDİ `ready_lock`
        /// (`asap.SpinLock`, `.acquire`/`.release`) SENKRONİZASYONUNDAN
        /// GELİR (çapraz-worker uyandırmanın ZATEN KANITLANMIŞ mekanizması
        /// — bkz. MN.4/5'in "GERÇEK çapraz-worker fiber çalma" tasarımı).
        state: std.atomic.Value(usize) = .init(PENDING),
        /// Faz S.1: `destroy` (bkz. `bridge.zig`nin `nox_async_destroy_task`ı)
        /// bu görev HENÜZ tamamlanmamışken çağrıldıysa `true` olur — bu
        /// GÜVENLİK için ZORUNLUDUR: `self` (`Task` struct'ının KENDİSİ),
        /// fiber'ın `entryTrampoline`si HENÜZ tamamlanmadığından, fiber
        /// tarafından `self.result`/`self.state`e YAZILACAK bellektir.
        /// `self`i HEMEN serbest bırakmak (görev tamamlanmadan) fiber
        /// sonunda serbest bırakılmış belleğe YAZAN bir use-after-free
        /// olurdu. Bunun yerine yalnızca bu bayrak işaretlenir — GERÇEK
        /// serbest bırakma `entryTrampoline`e ERTELENİR (bkz. orada).
        detached: bool = false,

        fn entryTrampoline(arg_erased: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(arg_erased));
            self.result = self.func(self.arg);
            // Görev tamamlanmadan ÖNCE `destroy` edildiyse (bkz. `detached`in
            // belge notu) — artık HİÇBİR bekleyen OLAMAZ (destroy anında
            // sahip elindeki TEK tutamacı bıraktı), bu yüzden `self`i BURADA,
            // GÜVENLE (fiber KENDİ yazımını BİTİRMİŞKEN) serbest bırakmak
            // doğru "ertelenmiş temizlik" noktasıdır.
            if (self.detached) {
                self.scheduler.allocator.destroy(self);
                return;
            }
            const old = self.state.swap(COMPLETED, .acq_rel);
            if (old != PENDING) {
                const w: *Waiter = @ptrFromInt(old);
                w.scheduler.markReady(w.fiber);
            }
        }

        pub fn await_(self: *Self) T {
            // Hızlı yol: görev ZATEN tamamlanmışsa scheduler'a HİÇ DOKUNMA —
            // `await_` bir fiber BAĞLAMI OLMADAN (ör. üst-düzey test kodu,
            // `scheduler.run()` DIŞINDA) ZATEN tamamlanmış bir görevi
            // beklemek İçİn ÇAĞRILABİLİR — bu ESKİ (`if (!self.completed)`)
            // davranışla BİREBİR AYNIDIR.
            if (self.state.load(.acquire) == COMPLETED) {
                return self.result;
            }
            // ÇAĞIRANIN KENDİ, GERÇEKTEN ÇALIŞAN worker'ının scheduler'ı —
            // `self.scheduler` (görev OLUŞTURULDUĞUNDA sabitlenen) DEĞİL
            // (bkz. `Waiter`in belge notu, BURADA NEDEN). `waiter` BU
            // fiber'ın KENDİ yığınında yaşar — fiber askıdayken yığını
            // CANLI kalır (Channel'ın `RecvSlot`/`SendSlot`ıyla AYNI ilke).
            const sched = currentScheduler().?;
            var waiter = Waiter{ .fiber = sched.current.?, .scheduler = sched };
            if (self.state.cmpxchgStrong(PENDING, @intFromPtr(&waiter), .acq_rel, .acquire) == null) {
                sched.suspendCurrent();
            }
            return self.result;
        }
    };
}

/// `func(arg)`i HEMEN bir yeşil iş parçacığında BAŞLATIR (bloklamaz),
/// sonucu daha sonra `Task(T).await_()` ile alınabilecek bir tutamaç
/// döner (Go'nun `go f()`si + kanal yerine doğrudan Task).
pub fn spawn(scheduler: *Scheduler, comptime T: type, func: *const fn (*anyopaque) callconv(.c) T, arg: *anyopaque) !*Task(T) {
    const task = try scheduler.allocator.create(Task(T));
    task.* = .{ .scheduler = scheduler, .func = func, .arg = arg };
    const stack = try scheduler.acquireStack();
    task.fiber = Fiber.createWithStack(scheduler.allocator, Task(T).entryTrampoline, task, stack) catch |e| {
        scheduler.releaseStack(stack);
        return e;
    };
    // Faz MN.4/5: havuzluysa YEREL `live_count` YERİNE (bkz. `run()`nin
    // tamamlanma dalındaki AYNI "KRİTİK" not) SADECE PAYLAŞILAN `pool_
    // live_count` artırılır — bir fiber BAŞKA bir worker TARAFINDAN
    // ÇALINIP TAMAMLANABİLECEĞİNDEN, YEREL `live_count` HİÇBİR ZAMAN
    // doğru şekilde AZALTILAMAZ (kim spawn etti İLE kim bitirdi FARKLI
    // olabilir) — bu YÜZDEN havuzlu modda BAŞTAN HİÇ artırılmaz.
    if (scheduler.pool_live_count) |plc| {
        _ = plc.fetchAdd(1, .monotonic);
    } else {
        scheduler.live_count += 1;
    }
    // Faz MN.4: havuzluysa (bkz. `scheduler.pool_live_count`) YENİ fiber
    // `markReady` YERİNE KENDİ deque'ine PUSH edilir — "spawn-anında çal,
    // İLK-çalıştırmadan SONRA sabitlen" modeli (bkz. proje planı, tasarım
    // #1) — böylece `bridge.zig`nin `nox_async_spawn`ı (BU fonksiyona
    // DELEGE eder) AYRICA bir değişiklik GEREKTİRMEZ. Deque DOLUYSA (ÇOK
    // nadir, 256 kapasiteli) `markReady`e GERİ DÜŞÜLÜR — davranışsal
    // olarak GÜVENLİ, SADECE çalınamaz hale gelir, YEREL çalışmaya devam
    // eder.
    if (scheduler.ownDeque()) |d| {
        d.pushBottom(task.fiber) catch scheduler.markReady(task.fiber);
        // Faz MN.8, Bulgu B: YENİ bir görev (BAŞKA bir worker TARAFINDAN
        // çalınabilir hale GELDİ) — `markReady`nin `is_foreign` dalının
        // AKSİNE, BU spawn HER ZAMAN YEREL (çağıran KENDİ deque'ine
        // ekliyor) OLDUĞUNDAN `markReady` BUNU işaretlemez — BURADA AYRICA
        // işaretlenmesi GEREKİR (bkz. `poolWideDeadlockCheck`nin epoch-
        // doğrulaması).
        if (scheduler.pool_activity_epoch) |epoch| _ = epoch.fetchAdd(1, .release);
    } else {
        scheduler.markReady(task.fiber);
    }
    return task;
}

/// Faz MN.9.3: `nox.http.serve_multicore`nin havuz-tabanlı `nox_pool_serve`
/// lowering'inin (bkz. `pool_bridge.zig`nin `broadcastRunOnEachWorker`ı)
/// çekirdek ilkeli — `spawn()`nin AKSİNE (TEK-üretici, SADECE ÇAĞIRANIN
/// KENDİ deque'ine `pushBottom`; `target != scheduler.ownDeque()`nin sahibi
/// İSE VERİ YARIŞIDIR), BU fonksiyon `target` ÇAĞIRANDAN FARKLI (YABANCI)
/// bir worker'a AİT OLSA BİLE güvenlidir — `markReady` (`self.owner_tid`ye
/// KARŞI ÇAĞIRAN iş parçacığını kontrol eden, `Task(T).entryTrampoline`nin
/// çapraz-worker uyandırmasında ZATEN KANITLANMIŞ, kilit+wake-fd korumalı
/// ilkel) ÜZERİNDEN enjekte eder. `target.stack_pool`a (SENKRONİZE OLMAYAN,
/// SADECE sahibi tarafından dokunulan) HİÇ DOKUNULMAZ — yığın DOĞRUDAN
/// `target.allocator` (havuzlu bir `target` İçİn HER ZAMAN `page_allocator`,
/// bkz. `WorkerPool.create`) İLE tahsis edilir; `target` KENDİ `run()`u
/// İçİNDE (fiber bittiğinde) KENDİ havuzuna GERİ VERİR (bkz. `run()`nin
/// "fiber.finished" dalı — HANGİ iş parçacığının enjekte ETTİĞİNDEN
/// TAMAMEN BAĞIMSIZ çalışır, `pool_live_count`u SADECE PAYLAŞILAN,
/// atomik sayaç OLARAK görür).
pub fn spawnToForeignScheduler(target: *Scheduler, func: *const fn (*anyopaque) callconv(.c) i64, arg: *anyopaque) !void {
    const Payload = struct {
        func: *const fn (*anyopaque) callconv(.c) i64,
        arg: *anyopaque,
        allocator: std.mem.Allocator,

        fn trampoline(erased: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(erased));
            _ = self.func(self.arg);
            self.allocator.destroy(self);
        }
    };
    const payload = try target.allocator.create(Payload);
    payload.* = .{ .func = func, .arg = arg, .allocator = target.allocator };
    const fiber = Fiber.create(target.allocator, Payload.trampoline, payload) catch |e| {
        target.allocator.destroy(payload);
        return e;
    };
    // `spawn()`ın AYNI muhasebesi (bkz. onun belge notu) — BU fonksiyon
    // SADECE havuzlu bir `target` İçİn çağrılır (`broadcastRunOnEachWorker`
    // DIŞINDA HİÇ ÇAĞRILMAZ), bu YÜZDEN `pool_live_count` HER ZAMAN DOLU
    // VARSAYILIR (havuzsuz bir `target`e enjekte etmenin ANLAMI YOK —
    // "yabancı worker" kavramının KENDİSİ havuz GEREKTİRİR).
    if (target.pool_live_count) |plc| _ = plc.fetchAdd(1, .monotonic);
    target.markReady(fiber);
}

test "tek görev, await olmadan sonucu doğru hesaplar" {
    const Fn = struct {
        fn double(arg: *anyopaque) callconv(.c) i64 {
            const x: *i64 = @ptrCast(@alignCast(arg));
            return x.* * 2;
        }
    };

    var scheduler = try Scheduler.init(std.heap.page_allocator);
    defer scheduler.deinit();

    var input: i64 = 21;
    const task = try spawn(&scheduler, i64, Fn.double, &input);
    defer scheduler.allocator.destroy(task);

    try scheduler.run();

    try std.testing.expect(task.state.load(.acquire) == Task(i64).COMPLETED);
    try std.testing.expectEqual(@as(i64, 42), task.result);
}

test "bir görev başka bir görevi await eder (iç içe askıya alma)" {
    const Fn = struct {
        fn child(arg: *anyopaque) callconv(.c) i64 {
            const x: *i64 = @ptrCast(@alignCast(arg));
            return x.* * 2;
        }

        const ParentArg = struct {
            scheduler: *Scheduler,
            child_input: i64,
        };

        fn parent(arg: *anyopaque) callconv(.c) i64 {
            const p: *ParentArg = @ptrCast(@alignCast(arg));
            const child_task = spawn(p.scheduler, i64, child, &p.child_input) catch unreachable;
            defer p.scheduler.allocator.destroy(child_task);
            return child_task.await_() + 1;
        }
    };

    var scheduler = try Scheduler.init(std.heap.page_allocator);
    defer scheduler.deinit();
    // v1.29.1: `Task.await_()` artık `currentScheduler()`e dayanıyor (bkz.
    // `Waiter`in belge notu) — `bridge.zig`nin `nox_async_init`inin GERÇEK
    // programlarda ZATEN KOŞULSUZ yaptığı eşitlemeyi BURADA elle yapıyoruz.
    setCurrentScheduler(&scheduler);
    defer setCurrentScheduler(null);

    var parent_arg = Fn.ParentArg{ .scheduler = &scheduler, .child_input = 10 };
    const parent_task = try spawn(&scheduler, i64, Fn.parent, &parent_arg);
    defer scheduler.allocator.destroy(parent_task);

    try scheduler.run();

    try std.testing.expect(parent_task.state.load(.acquire) == Task(i64).COMPLETED);
    try std.testing.expectEqual(@as(i64, 21), parent_task.result);
}

test "dairesel await -> Deadlock hatası net şekilde fırlatılır (asılı KALMAZ)" {
    const Pair = struct {
        a: *Task(i64) = undefined,
        b: *Task(i64) = undefined,
    };
    const Fn = struct {
        fn waitForB(arg: *anyopaque) callconv(.c) i64 {
            const pair: *Pair = @ptrCast(@alignCast(arg));
            return pair.b.await_();
        }
        fn waitForA(arg: *anyopaque) callconv(.c) i64 {
            const pair: *Pair = @ptrCast(@alignCast(arg));
            return pair.a.await_();
        }
    };

    var scheduler = try Scheduler.init(std.heap.page_allocator);
    defer scheduler.deinit();
    // v1.29.1: bkz. yukarıdaki "iç içe askıya alma" testinin AYNI notu.
    setCurrentScheduler(&scheduler);
    defer setCurrentScheduler(null);

    var pair = Pair{};
    pair.a = try spawn(&scheduler, i64, Fn.waitForB, &pair);
    pair.b = try spawn(&scheduler, i64, Fn.waitForA, &pair);

    try std.testing.expectError(error.Deadlock, scheduler.run());

    // Deadlock tespit edildiğinde iki görev de KALICI olarak askıda kalır
    // (hiçbiri tamamlanmadı) — v0.1'de zamanlayıcının otomatik bir
    // "deadlock sonrası temizlik" mekanizması YOK (bkz. spec), bu yüzden
    // testte fiber'lar elle serbest bırakılır.
    pair.a.fiber.destroy();
    pair.b.fiber.destroy();
    scheduler.allocator.destroy(pair.a);
    scheduler.allocator.destroy(pair.b);
}

test "Faz S.1: tamamlanmadan (fire-and-forget) 'destroy' edilen görev sızmadan/UAF'siz kendi kendini temizler" {
    // `nox_async_destroy_task`in (bkz. `bridge.zig`) SİMÜLASYONU: görev
    // HENÜZ tamamlanmamışken "yok et" isteği gelir. Eski (Faz S.1 ÖNCESİ)
    // davranış struct'ı BURADA HEMEN serbest bırakırdı — fiber SONRADAN
    // `entryTrampoline`de `self.result`/`self.completed`e YAZARKEN serbest
    // bırakılmış belleğe yazan bir use-after-free olurdu. `Task.detached`
    // (bkz. onun belge notu) bunun yerine gerçek serbest bırakmayı görev
    // KENDİ KENDİNE tamamlanana kadar ERTELER.
    //
    // **`entryTrampoline` BİLEREK gerçek bir fiber/`scheduler.run()` ÜZERİNDEN
    // DEĞİL, DOĞRUDAN çağrılır:** `runtime/async_rt/fiber.zig`nin modül üstü
    // notu (bkz. `callEntryPadded`) bir fiber yığınının SAHTE önyükleme
    // çerçevesi İÇİNDEN `std.testing.allocator` (DebugAllocator) İLE bir
    // `alloc`/`free` yapmanın, ReleaseFast'ta çerçeve-işaretçisi tabanlı
    // yığın-izi yakalamasının GEÇERSİZ belleğe düşüp SIGSEGV vermesine yol
    // açtığını GERÇEKTEN kanıtlıyor (bu test İLK yazıldığında `scheduler.
    // run()` üzerinden GERÇEK bir fiber içinde çalıştırılmıştı — `-Doptimize=
    // ReleaseFast`ta TAM OLARAK bu şekilde çöktü). `entryTrampoline`in
    // `detached` dalı fiber bağlamına ÖZGÜ bir şey YAPMADIĞINDAN (yalnızca
    // `self.func`/`self.scheduler.allocator`e erişir), test onu doğrudan
    // ÇAĞIRARAK AYNI mantığı fiber/yığın karmaşıklığı OLMADAN, güvenle
    // egzersiz eder — `std.testing.allocator` da BU YÜZDEN güvenle
    // kullanılabilir (test fonksiyonunun KENDİ, normal çağrı yığınında).
    const Fn = struct {
        fn triple(arg: *anyopaque) callconv(.c) i64 {
            const x: *i64 = @ptrCast(@alignCast(arg));
            return x.* * 3;
        }
    };

    var scheduler = try Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    const TaskI64 = Task(i64);
    const task = try scheduler.allocator.create(TaskI64);
    var input: i64 = 7;
    task.* = .{ .scheduler = &scheduler, .func = Fn.triple, .arg = &input };

    try std.testing.expect(task.state.load(.acquire) == TaskI64.PENDING);
    task.detached = true;

    TaskI64.entryTrampoline(task);
    // `task`e BURADA (serbest bırakıldıktan sonra) KASITLI olarak hiç
    // erişilmiyor — `entryTrampoline` görevi tamamlayıp KENDİSİ serbest
    // bıraktı (bkz. yukarıdaki not). Testin asıl iddiası, `std.testing.
    // allocator`ın fonksiyon SONUNDA OTOMATİK olarak doğruladığı şeydir:
    // struct ne SIZDI ne de ÇİFT serbest bırakıldı.
}

// ---- Faz MN.6: STW bariyeri (sense-reversing barrier) testi ----
//
// `alloc/`den TAMAMEN BAĞIMSIZ (`async-rt-test`nin HIZLI çalıştırdığı
// standalone hedefin BİR PARÇASI) — GERÇEK bir `WorkerPool` KURULMAZ,
// `PoolLink`in TÜM alanları BURADA ELLE inşa edilir. Bariyerin KENDİSİNE
// ODAKLANIR (`Scheduler.stwParticipate`i doğrudan çağırır) — bu, "TEK bir
// paylaşılan bayrağın YENİDEN KULLANIMI" ABA-tipi hatasının (bkz. proje
// planı, "Faz MN.6" tasarım notu #1) DOĞRUDAN regresyon testidir: HATALI
// tasarımla BU test 50 round'un ÇOK ÖNCESİNDE bir straggler worker'ın
// SONSUZA KADAR bloke KALMASIYLA (dolayısıyla `t.join()`ün ASLA
// DÖNMEMESİYLE) ASILI KALIRDI.

test "Faz MN.6: STW bariyeri (sense-reversal) ART ARDA round'larda KİLİTLENMEDEN çalışır" {
    const N = 4;
    const ROUNDS = 50;

    const Shared = struct {
        stw_requested: std.atomic.Value(bool) = .init(false),
        stw_arrived: std.atomic.Value(usize) = .init(0),
        stw_sense: std.atomic.Value(bool) = .init(false),
        collect_count: std.atomic.Value(usize) = .init(0),
        live_count: std.atomic.Value(usize) = .init(0),
        waiting_on_io: std.atomic.Value(usize) = .init(0),
        idle_workers: std.atomic.Value(usize) = .init(0),
        activity_epoch: std.atomic.Value(u64) = .init(0),
        deques: [N]Deque = @splat(.{}),
        deque_ptrs: [N]*Deque = undefined,
        wake_fds: [N]std.atomic.Value(i32) = @splat(.init(-1)),
        rounds_done: [N]std.atomic.Value(usize) = @splat(.init(0)),
    };

    const Fn = struct {
        fn fakeCollect(rt: ?*anyopaque) callconv(.c) void {
            const s: *Shared = @ptrCast(@alignCast(rt.?));
            _ = s.collect_count.fetchAdd(1, .monotonic);
        }

        fn workerBody(shared: *Shared, own_slot: usize) void {
            var sched = Scheduler.init(std.testing.allocator) catch @panic("zamanlayici baslatilamadi");
            defer sched.deinit();
            sched.attachToPool(.{
                .own_slot = own_slot,
                .sibling_deques = &shared.deque_ptrs,
                .live_count = &shared.live_count,
                .waiting_on_io = &shared.waiting_on_io,
                .idle_workers = &shared.idle_workers,
                .activity_epoch = &shared.activity_epoch,
                .stw_requested = &shared.stw_requested,
                .stw_arrived = &shared.stw_arrived,
                .stw_sense = &shared.stw_sense,
                .wake_fds = &shared.wake_fds,
                .collect_fn = &fakeCollect,
                .rt = shared,
            }) catch {};

            var r: usize = 0;
            while (r < ROUNDS) : (r += 1) {
                while (!shared.stw_requested.load(.acquire)) std.Thread.yield() catch {};
                sched.stwParticipate();
                _ = shared.rounds_done[own_slot].fetchAdd(1, .monotonic);
            }
        }
    };

    var shared = Shared{};
    for (0..N) |i| shared.deque_ptrs[i] = &shared.deques[i];

    var threads: [N]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Fn.workerBody, .{ &shared, i });
    }

    // Faz MN.6: ART ARDA `ROUNDS` round'u SÜRÜCÜLE — HER round'u BAŞLATMADAN
    // ÖNCE ÖNCEKİ round'un GERÇEKTEN TAMAMLANDIĞINI (`collect_count`
    // ARTTI) doğrula, bu YÜZDEN round'lar ASLA ÇAKIŞMAZ (sense-reversal
    // düzeltmesinin DOĞRU çalıştığının bağımsız bir kanıtı).
    var round: usize = 0;
    while (round < ROUNDS) : (round += 1) {
        // **GERÇEK, DENEYEREK BULUNAN hata**: `collect_fn` (`fakeCollect`)
        // `collect_count`u lider'in `arrived`/`stw_requested`i TEMİZLEMESİNDEN
        // ÖNCE artırır — bu YÜZDEN bu sürücü, "önceki round bitti" sinyalini
        // (`collect_count` arttı) lider HENÜZ `stw_requested`i `false`
        // YAPMADAN görebilir. TEK seferlik bir `cmpxchgStrong` (ÖNCEKİ
        // kod) bu dar pencerede BAŞARISIZ olup HİÇ TEKRAR DENEMEZSE, `true`
        // değeri KALICI olarak KAYBOLUR — lider (ÖNCEKİ round'dan) HEMEN
        // ARDINDAN `false` yazar VE HİÇ KİMSE bir daha `true` YAZMAZ,
        // TÜM worker'lar `stwParticipate`in dışındaki OUTER `while
        // (!stw_requested.load()) yield();` döngüsünde SONSUZA KADAR
        // döner (GERÇEKTEN, `zig build test`in TAM takımında, 494% CPU'lu
        // bir livelock OLARAK gözlemlendi). Düzeltme: `false`→`true`
        // GEÇİŞİNİ GERÇEKTEN BAŞARANA KADAR TEKRAR DENE — üretim kodundaki
        // (`nox_cycle_possible_root`) TEK-seferlik cmpxchg GÜVENLİDİR
        // ÇÜNKÜ o SÜREKLİ tekrar tekrar çağrılır (HER olası-kök olayında);
        // BU test sürücüsü İSE round başına TAM BİR KEZ çağrıldığından
        // KENDİ İçİNDE tekrar etmesi GEREKİR.
        while (shared.stw_requested.cmpxchgWeak(false, true, .acq_rel, .monotonic) != null) {
            std.Thread.yield() catch {};
        }
        while (shared.collect_count.load(.acquire) <= round) std.Thread.yield() catch {};
    }

    for (&threads) |t| t.join();

    try std.testing.expectEqual(@as(usize, ROUNDS), shared.collect_count.load(.monotonic));
    for (0..N) |i| {
        try std.testing.expectEqual(@as(usize, ROUNDS), shared.rounds_done[i].load(.monotonic));
    }
}
