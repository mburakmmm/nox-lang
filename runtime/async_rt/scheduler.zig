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
        for (self.stack_pool.items) |stack| self.allocator.free(stack);
        self.stack_pool.deinit(self.allocator);
        if (self.wake_read_fd) |fd| closeSelfPipeFd(fd);
        if (self.wake_write_fd) |fd| closeSelfPipeFd(fd);
    }

    /// Faz MN.4/5: bu zamanlayıcıyı bir `WorkerPool`e BAĞLAR — `bridge.zig`nin
    /// `nox_async_init`i, `rt`nin `RuntimeState.worker_pool`u SET İSE bunu
    /// OTOMATİK çağırır (bkz. onun belge notu). Self-pipe kurar VE HEMEN
    /// reaktöre kaydeder (`armWakeFd`) — `run`, İLK `reactor.poll()`
    /// çağrısından İTİBAREN çapraz-worker uyandırmaya HAZIR olur.
    pub fn attachToPool(
        self: *Scheduler,
        own_slot: usize,
        sibling_deques: []const *Deque,
        pool_live_count: *std.atomic.Value(usize),
        pool_waiting_on_io: *std.atomic.Value(usize),
        pool_idle_workers: *std.atomic.Value(usize),
    ) !void {
        self.own_slot = own_slot;
        self.sibling_deques = sibling_deques;
        self.pool_live_count = pool_live_count;
        self.pool_waiting_on_io = pool_waiting_on_io;
        self.pool_idle_workers = pool_idle_workers;
        const fds = try makeSelfPipe();
        self.wake_read_fd = fds[0];
        self.wake_write_fd = fds[1];
        self.armWakeFd();
    }

    /// Faz MN.4/5.8: `sibling_deques[own_slot]` — BU worker'ın KENDİ
    /// deque'i (spawn/pop İçİn).
    fn ownDeque(self: *Scheduler) ?*Deque {
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
        return self.allocator.alignedAlloc(u8, .fromByteUnits(fiber_mod.STACK_ALIGN), fiber_mod.STACK_SIZE);
    }

    /// Bir yığını (artık kullanılmayan) genel ayırıcıya GERİ VERMEK yerine
    /// havuza ekler. Havuzun kendisi büyütülemezse (OOM — son derece
    /// olası değil ama Zig'in `try` sözleşmesi bunu ele almayı gerektirir),
    /// akışı bozmamak için bloğu doğrudan serbest bırakır. `pub` — bkz.
    /// `acquireStack`in AYNI gerekçesi.
    pub fn releaseStack(self: *Scheduler, stack: []align(fiber_mod.STACK_ALIGN) u8) void {
        self.stack_pool.append(self.allocator, stack) catch {
            self.allocator.free(stack);
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
            if (self.wake_read_fd) |fd| drainWakeFd(fd);
            self.armWakeFd();
            return;
        }
        const is_foreign = self.pool_live_count != null and std.Thread.getCurrentId() != self.owner_tid;
        self.ready_lock.lock();
        self.ready.append(self.allocator, fiber) catch @panic("OOM: zamanlayıcı hazır kuyruğu büyütülemedi");
        self.ready_lock.unlock();
        if (is_foreign) {
            if (self.wake_write_fd) |fd| signalWakeFd(fd);
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
    fn poolWideDeadlockCheck(self: *Scheduler) bool {
        const n_workers = self.sibling_deques.len;
        const live = self.pool_live_count.?;
        const waiting_io = self.pool_waiting_on_io.?;
        const idle = self.pool_idle_workers.?;
        _ = idle.fetchAdd(1, .monotonic);
        defer _ = idle.fetchSub(1, .monotonic);

        var attempt: usize = 0;
        while (attempt < 20) : (attempt += 1) {
            sleepMs(1);
            if (self.tryStealFromSiblings()) |f| {
                self.markReady(f);
                return false;
            }
            if (live.load(.monotonic) == 0) return false;
            if (waiting_io.load(.monotonic) > 0) return false;
            if (idle.load(.monotonic) < n_workers) return false;
        }
        return idle.load(.monotonic) >= n_workers and
            live.load(.monotonic) > 0 and
            waiting_io.load(.monotonic) == 0;
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
                    if (plc.load(.monotonic) == 0) return;
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
                    _ = plc.fetchSub(1, .monotonic);
                } else {
                    self.live_count -= 1;
                }
                self.releaseStack(fiber.destroyKeepStack());
            }
        }
    }
};

// ---- Faz MN.4/5: havuz-farkındalı self-pipe yardımcıları ----
//
// `http_client.zig`nin `makeSelfPipe`/`signalSelfPipe`/`readSelfPipe`si İLE
// AYNI teknik (POSIX `pipe()` + tek-bayt `write`/`read`, `PIPE_BUF` altı
// boyutlar İçİn POSIX'te ATOMİK, kilitsiz GÜVENLİ) — ama BURADA AYRICA
// tanımlanır, DOĞRUDAN İTHAL EDİLMEZ: `http_client.zig`, `bridge.zig`yi
// (O DA `scheduler.zig`yi) İTHAL EDER — `scheduler.zig`nin `http_client.
// zig`yi DOĞRUDAN İTHAL ETMESİ döngüsel bir bağımlılık (Zig'de TEKNİK
// olarak İZİN VERİLİR ama katman disiplinini BOZAR: `scheduler.zig`
// `bridge.zig`nin ALTINDA yer alan bir katmandır) kurardı. Faz LL.2
// (nox-teknik-spesifikasyon.md §3.71) Windows İçİn `pipe()` YERİNE bir
// UDP-loopback ÇİFTİ KULLANIYORDU — BURADA Windows dalı BİLİNÇLİ olarak
// UYGULANMADI (`makeSelfPipe` `error.Unsupported` döner): work-stealing
// HENÜZ (bu fazda) GERÇEK bir Nox programından/codegen'den BAĞLANMADIĞINDAN
// (bkz. proje planı, MN.7 kapsamı) Windows'ta test EDİLEMEZ durumda —
// `attachToPool` başarısız OLURSA havuz KURULUMU (bkz. `worker_pool.zig`)
// BUNU ele almalıdır.
fn makeSelfPipe() ![2]posix.fd_t {
    if (builtin.os.tag == .windows) return error.Unsupported;
    var fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    return fds;
}

fn closeSelfPipeFd(fd: posix.fd_t) void {
    if (builtin.os.tag != .windows) _ = std.c.close(fd);
}

fn signalWakeFd(fd: posix.fd_t) void {
    if (builtin.os.tag != .windows) {
        var signal_byte = [_]u8{1};
        _ = std.c.write(fd, &signal_byte, 1);
    }
}

fn drainWakeFd(fd: posix.fd_t) void {
    if (builtin.os.tag != .windows) {
        var buf: [1]u8 = undefined;
        _ = std.c.read(fd, &buf, 1);
    }
}

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
        completed: bool = false,
        waiter: ?*Fiber = null,
        /// Faz S.1: `destroy` (bkz. `bridge.zig`nin `nox_async_destroy_task`ı)
        /// bu görev HENÜZ tamamlanmamışken çağrıldıysa `true` olur — bu
        /// GÜVENLİK için ZORUNLUDUR: `self` (`Task` struct'ının KENDİSİ),
        /// fiber'ın `entryTrampoline`si HENÜZ tamamlanmadığından, fiber
        /// tarafından `self.result`/`self.completed`e YAZILACAK bellektir.
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
            self.completed = true;
            if (self.waiter) |w| self.scheduler.markReady(w);
        }

        pub fn await_(self: *Self) T {
            if (!self.completed) {
                self.waiter = self.scheduler.current.?;
                self.scheduler.suspendCurrent();
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
    } else {
        scheduler.markReady(task.fiber);
    }
    return task;
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

    try std.testing.expect(task.completed);
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

    var parent_arg = Fn.ParentArg{ .scheduler = &scheduler, .child_input = 10 };
    const parent_task = try spawn(&scheduler, i64, Fn.parent, &parent_arg);
    defer scheduler.allocator.destroy(parent_task);

    try scheduler.run();

    try std.testing.expect(parent_task.completed);
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

    try std.testing.expect(!task.completed);
    task.detached = true;

    TaskI64.entryTrampoline(task);
    // `task`e BURADA (serbest bırakıldıktan sonra) KASITLI olarak hiç
    // erişilmiyor — `entryTrampoline` görevi tamamlayıp KENDİSİ serbest
    // bıraktı (bkz. yukarıdaki not). Testin asıl iddiası, `std.testing.
    // allocator`ın fonksiyon SONUNDA OTOMATİK olarak doğruladığı şeydir:
    // struct ne SIZDI ne de ÇİFT serbest bırakıldı.
}
