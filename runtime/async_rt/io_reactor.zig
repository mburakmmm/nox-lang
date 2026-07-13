//! Kqueue tabanlı async G/Ç reaktörü (bkz. nox-teknik-spesifikasyon.md §3.29,
//! "D.0 — Async I/O Reaktörü"). `scheduler.zig`nin (Faz 21, `Task`/`Channel`
//! için TAMAMLANDI) M:1 kooperatif zamanlayıcısı ŞU ANA KADAR yalnızca
//! Task/Channel senkronizasyon noktalarında (`suspendCurrent`/`markReady`)
//! geçiş yapıyordu — GERÇEK G/Ç hazır-olma bildirimi YOKTU. Bu dosya, bir
//! fiber bir soket okunabilir/yazılabilir OLANA kadar askıya alındığında,
//! OS iş parçacığının GERÇEKTEN başka bir hazır fiber'a devredilebilmesini
//! sağlayan alt katmandır (bkz. `Scheduler.suspendForIo`/`waiting_on_io`).
//!
//! **v0.1 kapsamı (bilinçli dar, `fiber.zig`nin "yalnızca aarch64"
//! kısıtlamasıyla TUTARLI — bkz. onun modül üstü notu):** yalnızca macOS
//! (kqueue). epoll (Linux) bu fazın DIŞINDA, gelecekte platform desteği
//! genişletilirse ayrıca ele alınacak.
//!
//! **`EV_ONESHOT` kullanımı (kritik):** her `register` çağrısı bir olayı
//! YALNIZCA BİR KEZ bildirecek şekilde kaydeder — ateşlendikten SONRA kqueue
//! kaydı KENDİLİĞİNDEN kaldırır. Bu, `unregister` mantığına hiç GEREK
//! BIRAKMAZ (aksi halde aynı fd için birden fazla bekleyen olduğunda ya da
//! bir fiber aynı fd'yi tekrar tekrar beklediğinde eski kayıtları elle
//! temizlemek gerekirdi) — v0.1'in "bir fd, bir bekleyen, bir seferlik
//! bildirim" modeliyle TAM uyumlu (bkz. `runtime/async_rt/io.zig`'in
//! non-blocking accept/read/write döngüleri, HER EAGAIN sonrası YENİDEN
//! `register` çağırır).
//!
//! Bu dosyadaki API'ler (`init`/`register`/`poll`) Nox diline/checker'a/
//! codegen'e HİÇBİR değişiklik GETİRMEZ — saf runtime altyapısıdır (`export
//! fn` DEĞİL, yalnızca Zig-seviyesi `pub fn`).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Fiber = @import("fiber.zig").Fiber;

comptime {
    if (builtin.os.tag != .macos) {
        @compileError("io_reactor.zig şu an yalnızca macOS (kqueue) için uygulandı (bkz. modül üstü not, v0.1 sınırlaması)");
    }
}

/// Zig'in std'sinde `kqueue()`/`kevent()` İÇİN yüksek seviye (hata kümesi
/// döndüren) bir sarmalayıcı YOK (bkz. modül üstü not) — burada `std.Io.Kqueue`nun
/// (Zig'in KENDİ `std.Io.Threaded` arka ucu) KULLANDIĞI AYNI ham `posix.system.*`
/// + `posix.errno` deseni elle uygulanır.
fn sysKqueue() !posix.fd_t {
    const rc = posix.system.kqueue();
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        else => |err| posix.unexpectedErrno(err),
    };
}

fn sysKevent(
    kq: posix.fd_t,
    changelist: []const posix.Kevent,
    eventlist: []posix.Kevent,
    timeout: ?*const posix.timespec,
) !usize {
    while (true) {
        const rc = posix.system.kevent(
            kq,
            changelist.ptr,
            std.math.cast(c_int, changelist.len) orelse return error.Overflow,
            eventlist.ptr,
            std.math.cast(c_int, eventlist.len) orelse return error.Overflow,
            timeout,
        );
        return switch (posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .INTR => continue,
            .ACCES => error.AccessDenied,
            .NOMEM => error.SystemResources,
            else => |err| posix.unexpectedErrno(err),
        };
    }
}

pub const Filter = enum { read, write };

pub const IoReactor = struct {
    kq: posix.fd_t,

    pub fn init() !IoReactor {
        return .{ .kq = try sysKqueue() };
    }

    pub fn deinit(self: *IoReactor) void {
        _ = std.c.close(self.kq);
    }

    /// `fd` `filter` yönünde (okunabilir/yazılabilir) hazır olduğunda
    /// `waiter`ı BİR KEZ bildirir (bkz. modül üstü not, `EV_ONESHOT`) —
    /// `poll` bu olayı görünce `waiter`ı hazır kuyruğa GERİ koyar
    /// (`Scheduler.suspendForIo` çağırır, `Scheduler.markReady`YE
    /// BENZER ama tipten bağımsız kalmak için `anytype` üzerinden).
    pub fn register(self: *IoReactor, fd: posix.fd_t, filter: Filter, waiter: *Fiber) !void {
        const kevent_filter: i16 = switch (filter) {
            .read => std.c.EVFILT.READ,
            .write => std.c.EVFILT.WRITE,
        };
        var changes = [_]posix.Kevent{.{
            .ident = @intCast(fd),
            .filter = kevent_filter,
            .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
            .fflags = 0,
            .data = 0,
            .udata = @intFromPtr(waiter),
        }};
        _ = try sysKevent(self.kq, &changes, &.{}, null);
    }

    /// En az bir olay hazır olana kadar BLOKE OLUR (`timeout == null`) —
    /// `scheduler.run()` yalnızca YAPACAK BAŞKA İŞİ (hazır fiber) KALMADIĞINDA
    /// çağırır (bkz. `Scheduler.run`), bu yüzden bloklamak GÜVENLİDİR. HER
    /// olayın `udata`sındaki fiber'ı `scheduler.markReady(...)` ile hazır
    /// kuyruğa ekler — `scheduler` parametresi `anytype`dır (Zig dosyaları
    /// arası ÇAPRAZ bağımlılığı `Scheduler`in TAM tipine değil, yalnızca
    /// `markReady(*Fiber) void` imzasına indirger).
    pub fn poll(self: *IoReactor, scheduler: anytype) !usize {
        var events: [64]posix.Kevent = undefined;
        const n = try sysKevent(self.kq, &.{}, &events, null);
        for (events[0..n]) |ev| {
            const fiber: *Fiber = @ptrFromInt(ev.udata);
            scheduler.markReady(fiber);
        }
        return n;
    }
};

test "IoReactor: bir soket çiftinde yazma tarafı, okuma tarafını hazır bildirir" {
    var fds: [2]posix.fd_t = undefined;
    if (std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var reactor = try IoReactor.init();
    defer reactor.deinit();

    // Sahte bir "fiber" işaretçisi (bu test yalnızca reaktörün udata'yı
    // doğru taşıdığını doğrular — gerçek bir Fiber'a ihtiyaç yoktur, ama
    // doğru HİZALAMAYI garantilemek için gerçek `Fiber` tipi kullanılır).
    var fake_fiber_storage: Fiber = undefined;
    const fake_fiber: *Fiber = &fake_fiber_storage;

    try reactor.register(fds[0], .read, fake_fiber);

    // Henüz veri YOK — kısa bir zaman aşımıyla poll edilirse hiç olay
    // dönmemeli (bu bloğu sonsuza dek beklememek için doğrudan `sysKevent`i
    // sıfır zaman aşımıyla çağırıyoruz, `poll`un KENDİSİ hep bloklar).
    {
        var events: [1]posix.Kevent = undefined;
        const timeout: posix.timespec = .{ .sec = 0, .nsec = 0 };
        const n = try sysKevent(reactor.kq, &.{}, &events, &timeout);
        try std.testing.expectEqual(@as(usize, 0), n);
    }

    const written = std.c.write(fds[1], "merhaba", 7);
    try std.testing.expectEqual(@as(isize, 7), written);

    const MarkReadySpy = struct {
        marked: ?*Fiber = null,
        fn markReady(self: *@This(), fiber: *Fiber) void {
            self.marked = fiber;
        }
    };
    var spy = MarkReadySpy{};
    const n = try reactor.poll(&spy);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(?*Fiber, fake_fiber), spy.marked);
}
