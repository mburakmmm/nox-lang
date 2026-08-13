//! Nox async runtime — `Channel[T]` (bkz. nox-teknik-spesifikasyon.md
//! §3.21, aşama 3). `scheduler.zig`deki AYNI `suspendCurrent`/`markReady`
//! ilkellerini yeniden kullanır — deadlock tespiti zaten `Scheduler.run()`
//! içinde, Task/Channel'dan BAĞIMSIZ yaşıyor (bkz. scheduler.zig).
//!
//! `capacity == 0`: tamponsuz (rendezvous) — `send` ancak bekleyen bir
//! `recv` varsa (ya da biri gelene kadar bekleyerek) tamamlanır.
//! `capacity > 0`: `N` öğeye kadar tamponlu — tampon doluyken `send`
//! bloklar, boşken `recv` bloklar.
//!
//! **Faz MN.9.1 — `SpinLock` (BULUNAN, ÖNCEDEN VAR OLAN bir hata İçİN
//! düzeltme):** `buffer`/`send_waiters`/`recv_waiters` ESKİDEN DÜZ,
//! kilitsiz `ArrayListUnmanaged`di — M:1 modelinde GÜVENLİYDİ (bir OS iş
//! parçacığında AYNI ANDA TEK fiber çalışır), AMA Faz MN.4/5'in İş-çalma
//! M:N zamanlayıcısı ALTINDA GERÇEK bir veri yarışıydı: checker'ın
//! `isSpawnParamSafeType`si `Channel[T]`yi `spawn`e argüman OLARAK
//! ZATEN İZİN VERİYOR — bir ebeveyn fiber bir `Channel`i oluşturup bir
//! alt göreve GEÇİREBİLİR, o alt görev BAŞKA bir worker'a ÇALINABİLİR,
//! VE ebeveyn+çalınan-çocuk AYNI ANDA `.send()`/`.recv()` çağırırsa
//! `buffer`/bekleyen-listeleri KİLİTSİZ MUTASYONA UĞRARDI. `suspendCurrent`/
//! `markReady`nin KENDİSİ ZATEN çapraz-worker güvenliydi (MN.4/5/6) —
//! SADECE bu tampon/liste MUTASYONLARI korumasızdı. Kilit `ThreadChannel`
//! (`thread_channel.zig`) İLE AYNI desende: `suspendCurrent`/`markReady`
//! ÇAĞRILMADAN ÖNCE SERBEST BIRAKILIR (iki kilidi bir fiber-askıya-alma
//! noktası BOYUNCA TUTMAMAK İçİn). MN.3b'nin KENDİ ilkesiyle TUTARLI
//! olarak KOŞULSUZ eklendi (havuzlu/havuzsuz AYRIMI YOK — çekişmesiz
//! `SpinLock` UCUZDUR, TEK kod yolu HER ZAMAN doğrudur). `asap.SpinLock`
//! YERİNE DOĞRUDAN `spinlock.zig`den İTHAL EDİLİR (`asap.SpinLock` ZATEN
//! SADECE bunun yeniden-dışa-açımı, bkz. `asap.zig`nin KENDİ notu) —
//! `channel.zig`nin `scheduler.zig`/`fiber.zig` İLE PAYLAŞTIĞI, `runtime/
//! alloc/`den BAĞIMSIZ kalma sınırını (standalone `async-rt-test`/Windows
//! CI hedefi) KORUR.

const std = @import("std");
const fiber_mod = @import("fiber.zig");
const Fiber = fiber_mod.Fiber;
const scheduler_mod = @import("scheduler.zig");
const Scheduler = scheduler_mod.Scheduler;
const SpinLock = @import("spinlock.zig").SpinLock;

pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Bir alıcının kendi yığınında BEKLEYEN, `send`in dolduracağı
        /// sonuç yuvası — fiber askıdayken yığını CANLI kaldığından
        /// (yığınlı fiber'ların temel avantajı) bu güvenle bir yerel
        /// değişken olarak tutulabilir, ısıya ayırma GEREKMEZ.
        ///
        /// **Faz MN.9.1: `scheduler` alanı — GERÇEK, DENEYEREK bulunan
        /// bir hata İçİn EKLENDİ.** İLK düzeltme (`markReady`i her
        /// zaman ÇAĞIRANIN KENDİ `currentScheduler()`ıyla çağırmak)
        /// YANLIŞTI — `markReady(self, fiber)`nin `self`i, `fiber`in
        /// PİNLİ OLDUĞU scheduler'ı hedeflemelidir, ÇAĞIRANINKİNİ DEĞİL
        /// (ÇALINAN bir üretici worker 2'de askıya alınırsa, worker 0'daki
        /// bir tüketicinin `markReady`i KENDİ (worker 0'ın) scheduler'ıyla
        /// çağırması fiber'ı YANLIŞ worker'ın hazır listesine eklerdi —
        /// fiber worker 2'nin run() döngüsüne ASLA ULAŞMAZ, SONSUZ
        /// kilitlenme — GERÇEKTEN ReleaseFast'ta çökme, ReleaseSafe'te
        /// 23+ dakikalık bir asılı kalma OLARAK gözlemlendi). Düzeltme:
        /// HER bekleyen yuva KENDİ `scheduler_mod.currentScheduler()`ını
        /// (askıya alma ANINDA) KAYDEDER — uyandıran taraf `slot.scheduler.
        /// markReady(slot.fiber)` çağırır, KENDİ scheduler'ı DEĞİL.
        const RecvSlot = struct {
            fiber: *Fiber,
            scheduler: *Scheduler,
            result: T = undefined,
        };
        const SendSlot = struct {
            fiber: *Fiber,
            scheduler: *Scheduler,
            value: T,
        };

        /// **Faz MN.9.1: SADECE `.allocator` İçİn kullanılır** (buffer/
        /// bekleyen-listesi tahsisleri) — bir havuzdaki TÜM worker'ların
        /// `Scheduler.allocator`ı ZATEN AYNI (`WorkerPool.create`, HER
        /// worker'ı `Scheduler.init(pool.allocator)` İLE kurar) olduğundan
        /// bu HER ZAMAN güvenlidir. `.current`/`suspendCurrent`/`markReady`
        /// İçİn KULLANILMAZ — bkz. `scheduler_mod.currentScheduler()`nin
        /// belge notu (BURADA NEDEN).
        scheduler: *Scheduler,
        capacity: usize,
        mutex: SpinLock = .{},
        buffer: std.ArrayListUnmanaged(T) = .empty,
        send_waiters: std.ArrayListUnmanaged(*SendSlot) = .empty,
        recv_waiters: std.ArrayListUnmanaged(*RecvSlot) = .empty,

        pub fn init(scheduler: *Scheduler, capacity: usize) Self {
            return .{ .scheduler = scheduler, .capacity = capacity };
        }

        pub fn deinit(self: *Self) void {
            self.buffer.deinit(self.scheduler.allocator);
            self.send_waiters.deinit(self.scheduler.allocator);
            self.recv_waiters.deinit(self.scheduler.allocator);
        }

        /// Tampondan bir öğe boşaldıktan sonra, bekleyen (tampon DOLUYKEN
        /// bloklanmış) bir gönderici varsa değerini tampona taşır. **Çağıran
        /// `self.mutex`i TUTMALIDIR** — `markReady`i BURADA ÇAĞIRMAZ (kilit
        /// TUTULURKEN çapraz-worker uyandırma YAPILMAZ), bunun yerine
        /// uyandırılacak yuvayı (VARSA — `.fiber`+`.scheduler`, bkz.
        /// `RecvSlot`/`SendSlot`nin belge notu) döner — çağıran kilidi
        /// SERBEST BIRAKTIKTAN SONRA `slot.scheduler.markReady(slot.fiber)`
        /// çağırmalıdır (KENDİ scheduler'IYLA DEĞİL).
        fn wakeOneSenderLocked(self: *Self) ?*SendSlot {
            if (self.send_waiters.items.len == 0) return null;
            const slot = self.send_waiters.orderedRemove(0);
            self.buffer.append(self.scheduler.allocator, slot.value) catch @panic("OOM: kanal tamponu büyütülemedi");
            return slot;
        }

        pub fn recv(self: *Self) T {
            // Faz MN.9.1: ÇAĞIRANIN KENDİ, GERÇEKTEN ÇALIŞAN worker'ının
            // scheduler'ı — `self.scheduler` DEĞİL (bkz. struct alanının
            // belge notu). `.current`/`suspendCurrent` İçİn (BU fiber'ın
            // KENDİSİ) DOĞRUDUR; `markReady` İçİn (BAŞKA bir fiber'ı
            // uyandırmak) İSE O fiber'ın KENDİ kayıtlı `.scheduler`ı
            // kullanılmalıdır (bkz. `wakeOneSenderLocked`nin notu).
            const sched = scheduler_mod.currentScheduler().?;
            self.mutex.lock();
            if (self.buffer.items.len > 0) {
                const value = self.buffer.orderedRemove(0);
                const woken = self.wakeOneSenderLocked();
                self.mutex.unlock();
                if (woken) |s| s.scheduler.markReady(s.fiber);
                return value;
            }
            // Tamponsuz (rendezvous) kanalda tampon her zaman boştur —
            // doğrudan bekleyen bir göndericiden AL (el ele teslim).
            if (self.send_waiters.items.len > 0) {
                const slot = self.send_waiters.orderedRemove(0);
                self.mutex.unlock();
                slot.scheduler.markReady(slot.fiber);
                return slot.value;
            }
            var slot = RecvSlot{ .fiber = sched.current.?, .scheduler = sched };
            self.recv_waiters.append(self.scheduler.allocator, &slot) catch @panic("OOM: kanal alıcı kuyruğu büyütülemedi");
            self.mutex.unlock();
            sched.suspendCurrent();
            return slot.result;
        }

        pub fn send(self: *Self, value: T) void {
            const sched = scheduler_mod.currentScheduler().?;
            self.mutex.lock();
            // Bekleyen bir alıcı varsa DOĞRUDAN teslim et (tampon hiç
            // kullanılmaz — hem rendezvous hem tamponlu kanalda geçerli
            // hızlı yol).
            if (self.recv_waiters.items.len > 0) {
                const slot = self.recv_waiters.orderedRemove(0);
                slot.result = value;
                self.mutex.unlock();
                slot.scheduler.markReady(slot.fiber);
                return;
            }
            if (self.buffer.items.len < self.capacity) {
                self.buffer.append(self.scheduler.allocator, value) catch @panic("OOM: kanal tamponu büyütülemedi");
                self.mutex.unlock();
                return;
            }
            // Tampon dolu (ya da kapasite 0 ve bekleyen alıcı yok) —
            // gönderici olarak bloklanır.
            var slot = SendSlot{ .fiber = sched.current.?, .scheduler = sched, .value = value };
            self.send_waiters.append(self.scheduler.allocator, &slot) catch @panic("OOM: kanal gönderici kuyruğu büyütülemedi");
            self.mutex.unlock();
            sched.suspendCurrent();
        }
    };
}

const spawn = scheduler_mod.spawn;

test "tamponsuz (rendezvous) kanal: gönderen alıcıyı bekler, veri doğru taşınır" {
    const ChanI64 = Channel(i64);
    var scheduler = try Scheduler.init(std.heap.page_allocator);
    defer scheduler.deinit();
    // Faz MN.9.1: `Channel.send`/`recv` artık `scheduler_mod.currentScheduler()`e
    // dayanıyor (bkz. onun belge notu) — `bridge.zig`nin `nox_async_init`i
    // BUNU GERÇEK programlarda OTOMATİK ayarlar, standalone testler KENDİLERİ
    // ayarlamalıdır.
    scheduler_mod.setCurrentScheduler(&scheduler);
    defer scheduler_mod.setCurrentScheduler(null);
    var chan = ChanI64.init(&scheduler, 0);
    defer chan.deinit();

    const Fn = struct {
        fn sender(arg: *anyopaque) callconv(.c) void {
            const ch: *ChanI64 = @ptrCast(@alignCast(arg));
            ch.send(42);
        }
        var received: i64 = 0;
        fn receiver(arg: *anyopaque) callconv(.c) void {
            const ch: *ChanI64 = @ptrCast(@alignCast(arg));
            received = ch.recv();
        }
    };

    const sender_task = try spawn(&scheduler, void, Fn.sender, &chan);
    defer scheduler.allocator.destroy(sender_task);
    const receiver_task = try spawn(&scheduler, void, Fn.receiver, &chan);
    defer scheduler.allocator.destroy(receiver_task);

    try scheduler.run();

    try std.testing.expectEqual(@as(i64, 42), Fn.received);
}

test "tamponlu kanal: kapasiteye kadar bloklamaz, dolunca gönderen bekler" {
    const ChanI64 = Channel(i64);
    var scheduler = try Scheduler.init(std.heap.page_allocator);
    defer scheduler.deinit();
    // Faz MN.9.1: `Channel.send`/`recv` artık `scheduler_mod.currentScheduler()`e
    // dayanıyor (bkz. onun belge notu) — `bridge.zig`nin `nox_async_init`i
    // BUNU GERÇEK programlarda OTOMATİK ayarlar, standalone testler KENDİLERİ
    // ayarlamalıdır.
    scheduler_mod.setCurrentScheduler(&scheduler);
    defer scheduler_mod.setCurrentScheduler(null);
    var chan = ChanI64.init(&scheduler, 2);
    defer chan.deinit();

    const Fn = struct {
        fn sender(arg: *anyopaque) callconv(.c) void {
            const ch: *ChanI64 = @ptrCast(@alignCast(arg));
            ch.send(1);
            ch.send(2);
            // Tampon (kapasite 2) burada DOLU — alıcı bir öğe alana kadar bloklanır.
            ch.send(3);
        }
        var log: std.ArrayListUnmanaged(i64) = .empty;
        fn receiver(arg: *anyopaque) callconv(.c) void {
            const ch: *ChanI64 = @ptrCast(@alignCast(arg));
            log.append(std.heap.page_allocator, ch.recv()) catch unreachable;
            log.append(std.heap.page_allocator, ch.recv()) catch unreachable;
            log.append(std.heap.page_allocator, ch.recv()) catch unreachable;
        }
    };
    defer Fn.log.deinit(std.heap.page_allocator);

    const sender_task = try spawn(&scheduler, void, Fn.sender, &chan);
    defer scheduler.allocator.destroy(sender_task);
    const receiver_task = try spawn(&scheduler, void, Fn.receiver, &chan);
    defer scheduler.allocator.destroy(receiver_task);

    try scheduler.run();

    try std.testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, Fn.log.items);
}

test "kanaldan asla gelmeyecek bir recv -> Deadlock hatası (asılı KALMAZ)" {
    const ChanI64 = Channel(i64);
    var scheduler = try Scheduler.init(std.heap.page_allocator);
    defer scheduler.deinit();
    // Faz MN.9.1: `Channel.send`/`recv` artık `scheduler_mod.currentScheduler()`e
    // dayanıyor (bkz. onun belge notu) — `bridge.zig`nin `nox_async_init`i
    // BUNU GERÇEK programlarda OTOMATİK ayarlar, standalone testler KENDİLERİ
    // ayarlamalıdır.
    scheduler_mod.setCurrentScheduler(&scheduler);
    defer scheduler_mod.setCurrentScheduler(null);
    var chan = ChanI64.init(&scheduler, 0);
    defer chan.deinit();

    const Fn = struct {
        fn receiver(arg: *anyopaque) callconv(.c) void {
            const ch: *ChanI64 = @ptrCast(@alignCast(arg));
            _ = ch.recv(); // hiçbir zaman gelmeyecek bir göndericiyi bekler
        }
    };

    const receiver_task = try spawn(&scheduler, void, Fn.receiver, &chan);

    try std.testing.expectError(error.Deadlock, scheduler.run());

    // Deadlock sonrası v0.1'de otomatik temizlik YOK (bkz. scheduler.zig
    // testindeki aynı not) — elle serbest bırakılır.
    receiver_task.fiber.destroy();
    scheduler.allocator.destroy(receiver_task);
}
