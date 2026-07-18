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
const fiber_mod = @import("fiber.zig");
const Fiber = fiber_mod.Fiber;
const Context = fiber_mod.Context;
const io_reactor = @import("io_reactor.zig");
const IoReactor = io_reactor.IoReactor;

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    ready: std.ArrayListUnmanaged(*Fiber) = .empty,
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

    pub fn init(allocator: std.mem.Allocator) !Scheduler {
        return .{ .allocator = allocator, .reactor = try IoReactor.init() };
    }

    pub fn deinit(self: *Scheduler) void {
        self.reactor.deinit();
        self.ready.deinit(self.allocator);
        for (self.stack_pool.items) |stack| self.allocator.free(stack);
        self.stack_pool.deinit(self.allocator);
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
    /// tamamlanıp bekleyenini uyandırırken kullanılır.
    pub fn markReady(self: *Scheduler, fiber: *Fiber) void {
        self.ready.append(self.allocator, fiber) catch @panic("OOM: zamanlayıcı hazır kuyruğu büyütülemedi");
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
        fiber.yield();
        self.waiting_on_io -= 1;
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
        fiber.yield();
        self.waiting_on_io -= 1;
        return ctx.result;
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
            if (self.ready.items.len == 0) {
                if (self.live_count == 0) return;
                if (self.waiting_on_io > 0) {
                    _ = self.reactor.poll(self) catch @panic("kqueue poll basarisiz");
                    continue;
                }
                return error.Deadlock;
            }
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
            const fiber = self.ready.swapRemove(0);
            self.current = fiber;
            fiber.resume_(&self.root_ctx);
            self.current = null;
            if (fiber.finished) {
                self.live_count -= 1;
                self.releaseStack(fiber.destroyKeepStack());
            }
        }
    }
};

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
    scheduler.live_count += 1;
    scheduler.markReady(task.fiber);
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
