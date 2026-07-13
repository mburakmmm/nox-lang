//! Nox async runtime — `Channel[T]` (bkz. nox-teknik-spesifikasyon.md
//! §3.21, aşama 3). `scheduler.zig`deki AYNI `suspendCurrent`/`markReady`
//! ilkellerini yeniden kullanır — deadlock tespiti zaten `Scheduler.run()`
//! içinde, Task/Channel'dan BAĞIMSIZ yaşıyor (bkz. scheduler.zig).
//!
//! `capacity == 0`: tamponsuz (rendezvous) — `send` ancak bekleyen bir
//! `recv` varsa (ya da biri gelene kadar bekleyerek) tamamlanır.
//! `capacity > 0`: `N` öğeye kadar tamponlu — tampon doluyken `send`
//! bloklar, boşken `recv` bloklar.

const std = @import("std");
const fiber_mod = @import("fiber.zig");
const Fiber = fiber_mod.Fiber;
const scheduler_mod = @import("scheduler.zig");
const Scheduler = scheduler_mod.Scheduler;

pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Bir alıcının kendi yığınında BEKLEYEN, `send`in dolduracağı
        /// sonuç yuvası — fiber askıdayken yığını CANLI kaldığından
        /// (yığınlı fiber'ların temel avantajı) bu güvenle bir yerel
        /// değişken olarak tutulabilir, ısıya ayırma GEREKMEZ.
        const RecvSlot = struct {
            fiber: *Fiber,
            result: T = undefined,
        };
        const SendSlot = struct {
            fiber: *Fiber,
            value: T,
        };

        scheduler: *Scheduler,
        capacity: usize,
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
        /// bloklanmış) bir gönderici varsa değerini tampona taşır ve onu
        /// uyandırır.
        fn wakeOneSender(self: *Self) void {
            if (self.send_waiters.items.len == 0) return;
            const slot = self.send_waiters.orderedRemove(0);
            self.buffer.append(self.scheduler.allocator, slot.value) catch @panic("OOM: kanal tamponu büyütülemedi");
            self.scheduler.markReady(slot.fiber);
        }

        pub fn recv(self: *Self) T {
            if (self.buffer.items.len > 0) {
                const value = self.buffer.orderedRemove(0);
                self.wakeOneSender();
                return value;
            }
            // Tamponsuz (rendezvous) kanalda tampon her zaman boştur —
            // doğrudan bekleyen bir göndericiden AL (el ele teslim).
            if (self.send_waiters.items.len > 0) {
                const slot = self.send_waiters.orderedRemove(0);
                self.scheduler.markReady(slot.fiber);
                return slot.value;
            }
            var slot = RecvSlot{ .fiber = self.scheduler.current.? };
            self.recv_waiters.append(self.scheduler.allocator, &slot) catch @panic("OOM: kanal alıcı kuyruğu büyütülemedi");
            self.scheduler.suspendCurrent();
            return slot.result;
        }

        pub fn send(self: *Self, value: T) void {
            // Bekleyen bir alıcı varsa DOĞRUDAN teslim et (tampon hiç
            // kullanılmaz — hem rendezvous hem tamponlu kanalda geçerli
            // hızlı yol).
            if (self.recv_waiters.items.len > 0) {
                const slot = self.recv_waiters.orderedRemove(0);
                slot.result = value;
                self.scheduler.markReady(slot.fiber);
                return;
            }
            if (self.buffer.items.len < self.capacity) {
                self.buffer.append(self.scheduler.allocator, value) catch @panic("OOM: kanal tamponu büyütülemedi");
                return;
            }
            // Tampon dolu (ya da kapasite 0 ve bekleyen alıcı yok) —
            // gönderici olarak bloklanır.
            var slot = SendSlot{ .fiber = self.scheduler.current.?, .value = value };
            self.send_waiters.append(self.scheduler.allocator, &slot) catch @panic("OOM: kanal gönderici kuyruğu büyütülemedi");
            self.scheduler.suspendCurrent();
        }
    };
}

const spawn = scheduler_mod.spawn;

test "tamponsuz (rendezvous) kanal: gönderen alıcıyı bekler, veri doğru taşınır" {
    const ChanI64 = Channel(i64);
    var scheduler = try Scheduler.init(std.heap.page_allocator);
    defer scheduler.deinit();
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
