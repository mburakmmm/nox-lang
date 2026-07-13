//! Kqueue/epoll tabanlı async G/Ç reaktörü (bkz. nox-teknik-spesifikasyon.md
//! §3.29, "D.0 — Async I/O Reaktörü"). `scheduler.zig`nin (Faz 21, `Task`/
//! `Channel` için TAMAMLANDI) M:1 kooperatif zamanlayıcısı ŞU ANA KADAR
//! yalnızca Task/Channel senkronizasyon noktalarında (`suspendCurrent`/
//! `markReady`) geçiş yapıyordu — GERÇEK G/Ç hazır-olma bildirimi YOKTU. Bu
//! dosya, bir fiber bir soket okunabilir/yazılabilir OLANA kadar askıya
//! alındığında, OS iş parçacığının GERÇEKTEN başka bir hazır fiber'a
//! devredilebilmesini sağlayan alt katmandır (bkz. `Scheduler.suspendForIo`/
//! `waiting_on_io`).
//!
//! **v0.1 kapsamı (`fiber.zig`nin CPU-mimarisi kısıtlamasıyla — yalnızca
//! aarch64 — TUTARLI, ama İŞLETİM SİSTEMİ bazında ARTIK İKİ platform
//! destekleniyor, bkz. Faz R.1):** macOS (kqueue) VE Linux (epoll). Diğer
//! POSIX benzeri sistemler (BSD türevleri vb.) bu fazın DIŞINDA.
//!
//! **Faz R.1 mimari notu:** kqueue VE epoll YOLLARI, AYNI genel `IoReactor`
//! ADI altında, `comptime` ile SEÇİLEN İKİ AYRI struct'tır (`KqueueReactor`/
//! `EpollReactor`) — HER İKİSİ de AYNI `init`/`deinit`/`register`/`poll`
//! ARAYÜZÜNÜ sağlar, bu yüzden `scheduler.zig`/`io.zig` HİÇBİR platform
//! dallanması İÇERMEZ (`IoReactor` TEK bir somut tip gibi KULLANILIR). HER
//! bir reaktör struct'ı `if (builtin.os.tag == ...) struct {...} else
//! struct {}` deseniyle SARILIR — bu, YANLIŞ platformda derlenirken OS'e
//! özgü tiplerin (`posix.Kevent`, `std.os.linux.epoll_event`) HİÇ
//! semantik analiz EDİLMEMESİNİ garanti eder (Zig'in struct alan/imza
//! analizinin fonksiyon gövdelerinin AKSİNE "istekli/eager" olabilmesi
//! nedeniyle KRİTİK bir önlem).
//!
//! **`EV_ONESHOT`/`EPOLLONESHOT` kullanımı (kritik):** her `register` çağrısı
//! bir olayı YALNIZCA BİR KEZ bildirecek şekilde kaydeder. **Kqueue'da**
//! ateşlendikten SONRA kayıt KENDİLİĞİNDEN kaldırılır — `register`in
//! SONRAKİ çağrısı HER ZAMAN taze bir `EV_ADD`dir. **Epoll'da İSE
//! `EPOLLONESHOT` fd'yi interest LİSTESİNDEN SİLMEZ, yalnızca YENİDEN
//! `EPOLL_CTL_MOD` İLE "silahlandırılana" KADAR o fd İÇİN olay ÜRETMEYİ
//! DURDURUR** — bu yüzden `EpollReactor.register`, ÖNCE `EPOLL_CTL_ADD`
//! DENER, fd ZATEN kayıtlıysa (`EEXIST`) `EPOLL_CTL_MOD`a DÜŞER (nginx/
//! libevent gibi olgun epoll kullanıcılarının KENDİ "yeniden silahlandırma"
//! deseniyle AYNI) — fd `close()` EDİLDİĞİNDE çekirdek onu TÜM epoll
//! kümelerinden OTOMATİK kaldırır, bu yüzden bir fd numarası YENİDEN
//! KULLANILDIĞINDA (ör. `accept()`in döndürdüğü YENİ bir bağlantı) `EEXIST`
//! YANLIŞLIKLA tetiklenmez.
//!
//! Bu dosyadaki API'ler (`init`/`register`/`poll`) Nox diline/checker'a/
//! codegen'e HİÇBİR değişiklik GETİRMEZ — saf runtime altyapısıdır (`export
//! fn` DEĞİL, yalnızca Zig-seviyesi `pub fn`).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Fiber = @import("fiber.zig").Fiber;

comptime {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) {
        @compileError("io_reactor.zig şu an yalnızca macOS (kqueue) ve Linux (epoll) için uygulandı (bkz. modül üstü not, v0.1 sınırlaması)");
    }
}

pub const Filter = enum { read, write };

/// **Kqueue (macOS).** Yalnızca `builtin.os.tag == .macos` İKEN GERÇEK
/// gövdesiyle derlenir — Linux'ta bu `struct {}`e (boş, hiçbir OS-özgü tip
/// REFERANSI OLMAYAN) indirgenir, bkz. modül üstü not.
const KqueueReactor = if (builtin.os.tag == .macos) struct {
    kq: posix.fd_t,

    /// Zig'in std'sinde `kqueue()`/`kevent()` İÇİN yüksek seviye (hata
    /// kümesi döndüren) bir sarmalayıcı YOK — burada `std.Io.Kqueue`nun
    /// (Zig'in KENDİ `std.Io.Threaded` arka ucu) KULLANDIĞI AYNI ham
    /// `posix.system.*` + `posix.errno` deseni elle uygulanır.
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

    pub fn init() !@This() {
        return .{ .kq = try sysKqueue() };
    }

    pub fn deinit(self: *@This()) void {
        _ = std.c.close(self.kq);
    }

    /// `fd` `filter` yönünde (okunabilir/yazılabilir) hazır olduğunda
    /// `waiter`ı BİR KEZ bildirir (bkz. modül üstü not, `EV_ONESHOT`) —
    /// `poll` bu olayı görünce `waiter`ı hazır kuyruğa GERİ koyar.
    pub fn register(self: *@This(), fd: posix.fd_t, filter: Filter, waiter: *Fiber) !void {
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
    /// çağırır, bu yüzden bloklamak GÜVENLİDİR. HER olayın `udata`sındaki
    /// fiber'ı `scheduler.markReady(...)` ile hazır kuyruğa ekler —
    /// `scheduler` parametresi `anytype`dır (Zig dosyaları arası ÇAPRAZ
    /// bağımlılığı `Scheduler`in TAM tipine değil, yalnızca `markReady(*Fiber)
    /// void` imzasına indirger).
    pub fn poll(self: *@This(), scheduler: anytype) !usize {
        var events: [64]posix.Kevent = undefined;
        const n = try sysKevent(self.kq, &.{}, &events, null);
        for (events[0..n]) |ev| {
            const fiber: *Fiber = @ptrFromInt(ev.udata);
            scheduler.markReady(fiber);
        }
        return n;
    }
} else struct {};

/// **Epoll (Linux, Faz R.1).** Yalnızca `builtin.os.tag == .linux` İKEN
/// GERÇEK gövdesiyle derlenir (bkz. modül üstü not).
const EpollReactor = if (builtin.os.tag == .linux) struct {
    epfd: posix.fd_t,

    const linux = std.os.linux;

    /// **KRİTİK (bkz. bu fonksiyonların İLK sürümünün GERÇEK bir hatasıyla
    /// keşfedildi — Docker/aarch64-linux'ta GERÇEKTEN çalıştırılıp KANITLANDI,
    /// bkz. commit geçmişi):** `std.os.linux.epoll_*` HAM sistem çağrısı
    /// sarmalayıcılarıdır — `usize` döner, hata negatif errno'yu BÜYÜK bir
    /// `usize` olarak KODLAR, libc'nin TLS `errno` DEĞİŞKENİNE ASLA
    /// DOKUNMAZ. `posix.errno()` İSE (bu proje libc'ye BAĞLANDIĞINDA,
    /// `KqueueReactor`nin `posix.system.kqueue/kevent` KULLANIMIYLA TUTARLI
    /// olması İÇİN) libc'nin TLS `errno`SUNU okur — bu İKİSİNİ KARIŞTIRMAK
    /// (ham `linux.epoll_ctl` + `posix.errno`) HATA DURUMUNU SESSİZCE
    /// `.SUCCESS` olarak YANLIŞ yorumlar (rc'nin KENDİSİ hataliyken bile).
    /// Çözüm: `posix.system.epoll_*` KULLANILIR — bu, libc BAĞLIYSA
    /// `std.c.epoll_*`e (GERÇEK errno YAN ETKİSİYLE, `c_int` `-1`/`errno`
    /// sözleşmesiyle) çözülür, `KqueueReactor`nin `posix.system.kqueue()`
    /// deseniyle BİREBİR AYNI.
    fn sysEpollCreate() !posix.fd_t {
        const rc = posix.system.epoll_create1(0);
        return switch (posix.errno(rc)) {
            .SUCCESS => rc,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .NOMEM => error.SystemResources,
            else => |err| posix.unexpectedErrno(err),
        };
    }

    /// `EEXIST` (fd ZATEN kayıtlı — bkz. modül üstü not, ONESHOT yeniden
    /// silahlandırma) `error.AlreadyRegistered` OLARAK ayırt edilir; geri
    /// kalan HER hata `posix.unexpectedErrno`ya düşer.
    fn sysEpollCtl(epfd: posix.fd_t, op: u32, fd: posix.fd_t, event: *linux.epoll_event) !void {
        const rc = posix.system.epoll_ctl(epfd, op, fd, event);
        return switch (posix.errno(rc)) {
            .SUCCESS => {},
            .EXIST => error.AlreadyRegistered,
            .NOMEM => error.SystemResources,
            .NOSPC => error.SystemResources,
            else => |err| posix.unexpectedErrno(err),
        };
    }

    fn sysEpollWait(epfd: posix.fd_t, events: []linux.epoll_event, timeout_ms: i32) !usize {
        while (true) {
            const rc = posix.system.epoll_wait(epfd, events.ptr, @intCast(events.len), timeout_ms);
            return switch (posix.errno(rc)) {
                .SUCCESS => @intCast(rc),
                .INTR => continue,
                else => |err| posix.unexpectedErrno(err),
            };
        }
    }

    pub fn init() !@This() {
        return .{ .epfd = try sysEpollCreate() };
    }

    pub fn deinit(self: *@This()) void {
        _ = std.c.close(self.epfd);
    }

    /// `fd` `filter` yönünde hazır olduğunda `waiter`ı BİR KEZ bildirir
    /// (`EPOLLONESHOT`) — ÖNCE `EPOLL_CTL_ADD` DENER, fd ZATEN kayıtlıysa
    /// (bir ÖNCEKİ `register`in ONESHOT'u ateşlenmiş ama fd HÂLÂ interest
    /// listesindeyse) `EPOLL_CTL_MOD`a DÜŞER — bkz. modül üstü not.
    pub fn register(self: *@This(), fd: posix.fd_t, filter: Filter, waiter: *Fiber) !void {
        const filter_bits: u32 = switch (filter) {
            .read => linux.EPOLL.IN,
            .write => linux.EPOLL.OUT,
        };
        var ev: linux.epoll_event = .{
            .events = filter_bits | linux.EPOLL.ONESHOT,
            .data = .{ .ptr = @intFromPtr(waiter) },
        };
        sysEpollCtl(self.epfd, linux.EPOLL.CTL_ADD, fd, &ev) catch |err| switch (err) {
            error.AlreadyRegistered => try sysEpollCtl(self.epfd, linux.EPOLL.CTL_MOD, fd, &ev),
            else => return err,
        };
    }

    /// En az bir olay hazır olana kadar BLOKE OLUR (`timeout_ms = -1`) —
    /// `KqueueReactor.poll` İLE AYNI kullanım sözleşmesi (bkz. onun belge
    /// notu). HER olayın `data.ptr`sindeki fiber'ı `scheduler.markReady(...)`
    /// ile hazır kuyruğa ekler.
    pub fn poll(self: *@This(), scheduler: anytype) !usize {
        var events: [64]linux.epoll_event = undefined;
        const n = try sysEpollWait(self.epfd, &events, -1);
        for (events[0..n]) |ev| {
            const fiber: *Fiber = @ptrFromInt(ev.data.ptr);
            scheduler.markReady(fiber);
        }
        return n;
    }
} else struct {};

pub const IoReactor = if (builtin.os.tag == .macos)
    KqueueReactor
else if (builtin.os.tag == .linux)
    EpollReactor
else
    @compileError("desteklenmeyen platform (bkz. modül üstü comptime denetimi)");

test "IoReactor: bir soket çiftinde yazma tarafı, okuma tarafını hazır bildirir" {
    var fds: [2]posix.fd_t = undefined;
    if (std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var reactor = try IoReactor.init();
    defer reactor.deinit();

    // Sahte bir "fiber" işaretçisi (bu test yalnızca reaktörün olay
    // taşıyıcısında (kqueue: `udata`, epoll: `data.ptr`) fiber işaretçisini
    // doğru taşıdığını doğrular — gerçek bir Fiber'a ihtiyaç yoktur, ama
    // doğru HİZALAMAYI garantilemek için gerçek `Fiber` tipi kullanılır).
    var fake_fiber_storage: Fiber = undefined;
    const fake_fiber: *Fiber = &fake_fiber_storage;

    try reactor.register(fds[0], .read, fake_fiber);

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

test "IoReactor: AYNI fd birden çok kez register edilebilir (EAGAIN-tekrar-dene döngüsünün gerçek deseni)" {
    // Faz R.1: epoll'un `EPOLLONESHOT`u kqueue'nun `EV_ONESHOT`unun AKSİNE
    // ateşlendikten SONRA fd'yi interest LİSTESİNDEN SİLMEZ — `register`in
    // (`io.zig`nin nonBlockingRead/Write/Accept döngülerinin HER `EAGAIN`
    // sonrası TEKRAR çağırdığı, bkz. o dosyanın belge notu) AYNI fd İÇİN
    // İKİNCİ KEZ çağrılması, `EpollReactor`in ÖNCE `EPOLL_CTL_ADD` DENEYİP
    // `EEXIST` alınca `EPOLL_CTL_MOD`a DÜŞMESİ OLMADAN `error.AlreadyRegistered`
    // ile BAŞARISIZ olurdu — bu test TAM OLARAK bu ikinci-kez-register
    // senaryosunu (kqueue'da zaten trivial-doğru, epoll'da GERÇEK bir
    // mantık gerektiren) egzersiz eder.
    var fds: [2]posix.fd_t = undefined;
    if (std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var reactor = try IoReactor.init();
    defer reactor.deinit();

    var fake_fiber_storage: Fiber = undefined;
    const fake_fiber: *Fiber = &fake_fiber_storage;

    // İLK tur: register + ateşle + tüket.
    try reactor.register(fds[0], .read, fake_fiber);
    _ = std.c.write(fds[1], "a", 1);
    const MarkReadySpy = struct {
        marked: ?*Fiber = null,
        fn markReady(self: *@This(), fiber: *Fiber) void {
            self.marked = fiber;
        }
    };
    var spy1 = MarkReadySpy{};
    _ = try reactor.poll(&spy1);
    try std.testing.expectEqual(@as(?*Fiber, fake_fiber), spy1.marked);
    var drain_buf: [1]u8 = undefined;
    _ = std.c.read(fds[0], &drain_buf, 1);

    // İKİNCİ tur: AYNI fd (fds[0]) TEKRAR register edilir — epoll'da bu,
    // ADD→EEXIST→MOD yoluna GİRMEK ZORUNDADIR (fd hâlâ interest listesinde).
    try reactor.register(fds[0], .read, fake_fiber);
    _ = std.c.write(fds[1], "b", 1);
    var spy2 = MarkReadySpy{};
    const n2 = try reactor.poll(&spy2);
    try std.testing.expectEqual(@as(usize, 1), n2);
    try std.testing.expectEqual(@as(?*Fiber, fake_fiber), spy2.marked);
}
