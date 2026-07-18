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
//!
//! **Faz HH.7 (bkz. nox-teknik-spesifikasyon.md §3.68) — zaman aşımlı
//! bekleyiş:** `registerWithTimeout`, bir fd'nin `filter` yönünde hazır
//! OLMASINI **VE** `timeout_ms` süresinin GEÇMESİNİ AYNI ANDA bekler,
//! HANGİSİ ÖNCE olursa `waiter`ı BİR KEZ uyandırır — okuma zaman aşımı/
//! slowloris korumasının (bkz. `http_server.zig`nin `FiberReader.stream`i)
//! temel taşı. Bu, `register`in TEK-olay bekleyişinden (bkz. yukarıdaki
//! not) YAPISAL olarak FARKLIDIR: İKİ AYRI olay KAYNAĞI (fd hazır-olma VE
//! zamanlayıcı) AYNI `WaitCtx`e YAZAR, `poll` HANGİSİNİN ateşlediğini
//! (kqueue: `ev.filter`, epoll: `data.u64`nün ETİKETLİ düşük biti — bkz.
//! `packCtx`/`unpackCtx`, epoll_event'in kqueue'nun AKSİNE "hangi filtre"
//! bilgisini TAŞIMAMASI YÜZÜNDEN gereken bir işaretçi-etiketleme hilesi)
//! ayırt edip DİĞER (ateşlemeyen) kaydı İPTAL EDER — aksi halde fiber
//! SONRADAN BAŞKA bir şey İçin AYNI fd'yi kullanırken bir SALLANAN
//! (artık geçersiz bir `WaitCtx`e işaret eden) olay GERİ gelebilirdi
//! (kullanım-sonrası-serbest-bırakma riski). `resolved` bayrağı, AYNI
//! `poll()` TURUNDA HER İKİ kaynağın da ateşlediği (nadir ama OLASI) yarış
//! durumunda `waiter`ın İKİ KEZ hazır kuyruğa EKLENMESİNİ önler.

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

/// Faz HH.7: `registerWithTimeout` İLE oluşturulan bir bekleyişin SONUCU.
pub const WaitResult = enum { ready, timed_out };

/// Faz HH.7: `register`/`registerWithTimeout`in ORTAK "olay taşıyıcısı" —
/// ÖNCEDEN (HH.7'den ÖNCE) `udata`/`data.ptr` DOĞRUDAN `*Fiber` taşıyordu;
/// ARTIK HER ZAMAN bir `*WaitCtx` taşır (`register`in BASİT — zaman
/// aşımsız — çağrıları İçin `has_timeout = false`, DİĞER alanlar
/// KULLANILMAZ) — `poll`ün TEK, TUTARLI bir yorumlama YAPMASI İçin GEREKLİ
/// (bkz. modül üstü not).
pub const WaitCtx = struct {
    fiber: *Fiber,
    result: WaitResult = .ready,
    /// `poll()`ün AYNI turda İKİ kaynağın (fd + zamanlayıcı) BİRLİKTE
    /// ateşlemesi durumunda `waiter`ı İKİ KEZ hazır kuyruğa EKLEMESİNİ
    /// önler.
    resolved: bool = false,
    has_timeout: bool = false,
    target_fd: posix.fd_t = -1,
    target_filter: Filter = .read,
    /// Yalnızca epoll: `registerWithTimeout`in yarattığı `timerfd`— HANGİ
    /// taraf ateşlerse ateşlesin `poll()` TARAFINDAN TAM OLARAK BİR KEZ
    /// `close()`lanır (aksi halde fd SIZARDI).
    timer_fd: posix.fd_t = -1,
};

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

    fn keventFilter(filter: Filter) i16 {
        return switch (filter) {
            .read => std.c.EVFILT.READ,
            .write => std.c.EVFILT.WRITE,
        };
    }

    /// `fd` `filter` yönünde (okunabilir/yazılabilir) hazır olduğunda
    /// `ctx.fiber`ı BİR KEZ bildirir (bkz. modül üstü not, `EV_ONESHOT`) —
    /// `poll` bu olayı görünce `ctx.fiber`ı hazır kuyruğa GERİ koyar.
    pub fn register(self: *@This(), fd: posix.fd_t, filter: Filter, ctx: *WaitCtx) !void {
        var changes = [_]posix.Kevent{.{
            .ident = @intCast(fd),
            .filter = keventFilter(filter),
            .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
            .fflags = 0,
            .data = 0,
            .udata = @intFromPtr(ctx),
        }};
        _ = try sysKevent(self.kq, &changes, &.{}, null);
    }

    /// Faz HH.7: `fd` `filter` yönünde hazır OLANA KADAR **VEYA**
    /// `timeout_ms` GEÇENE KADAR (HANGİSİ ÖNCE olursa) bekler — bkz. modül
    /// üstü not. TEK bir `kevent()` çağrısında İKİ değişiklik (fd + zamanlayıcı)
    /// birlikte gönderilir.
    pub fn registerWithTimeout(self: *@This(), fd: posix.fd_t, filter: Filter, timeout_ms: u32, ctx: *WaitCtx) !void {
        ctx.has_timeout = true;
        ctx.target_fd = fd;
        ctx.target_filter = filter;
        var changes = [_]posix.Kevent{
            .{
                .ident = @intCast(fd),
                .filter = keventFilter(filter),
                .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
                .fflags = 0,
                .data = 0,
                .udata = @intFromPtr(ctx),
            },
            .{
                // Darwin'de EVFILT_TIMER'ın VARSAYILAN birimi (özel bir
                // NOTE_SECONDS/NOTE_NSECONDS bayrağı OLMADIĞINDA) milisaniyedir.
                .ident = @intCast(fd),
                .filter = std.c.EVFILT.TIMER,
                .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
                .fflags = 0,
                .data = timeout_ms,
                .udata = @intFromPtr(ctx),
            },
        };
        _ = try sysKevent(self.kq, &changes, &.{}, null);
    }

    /// `ident`teki BEKLEYEN (henüz ateşlememiş) `filter` kaydını iptal eder
    /// — `ENOENT` (kayıt zaten ateşleyip KENDİLİĞİNDEN kalkmış OLABİLİR,
    /// bkz. `EV_ONESHOT`) SESSİZCE yok sayılır.
    fn cancel(self: *@This(), ident: posix.fd_t, filter: i16) void {
        var del = [_]posix.Kevent{.{
            .ident = @intCast(ident),
            .filter = filter,
            .flags = std.c.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        }};
        _ = sysKevent(self.kq, &del, &.{}, null) catch {};
    }

    /// En az bir olay hazır olana kadar BLOKE OLUR (`timeout == null`) —
    /// `scheduler.run()` yalnızca YAPACAK BAŞKA İŞİ (hazır fiber) KALMADIĞINDA
    /// çağırır, bu yüzden bloklamak GÜVENLİDİR. HER olayın `udata`sındaki
    /// `WaitCtx`i (bkz. onun belge notu) çözüp `scheduler.markReady(...)`
    /// ile hazır kuyruğa ekler — `scheduler` parametresi `anytype`dır (Zig
    /// dosyaları arası ÇAPRAZ bağımlılığı `Scheduler`in TAM tipine değil,
    /// yalnızca `markReady(*Fiber) void` imzasına indirger).
    pub fn poll(self: *@This(), scheduler: anytype) !usize {
        var events: [64]posix.Kevent = undefined;
        const n = try sysKevent(self.kq, &.{}, &events, null);
        for (events[0..n]) |ev| {
            const ctx: *WaitCtx = @ptrFromInt(ev.udata);
            if (ctx.resolved) continue;
            ctx.resolved = true;
            if (ev.filter == std.c.EVFILT.TIMER) {
                ctx.result = .timed_out;
                if (ctx.has_timeout) self.cancel(ctx.target_fd, keventFilter(ctx.target_filter));
            } else {
                ctx.result = .ready;
                if (ctx.has_timeout) self.cancel(ctx.target_fd, std.c.EVFILT.TIMER);
            }
            scheduler.markReady(ctx.fiber);
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

    /// Faz HH.7: `posix.system.timerfd_create`/`settime` — `sysEpollCreate`nin
    /// AYNI "ham linux.* ÇAĞIRMA, libc TLS errno'suyla KARIŞTIRMA" dersini
    /// (bkz. `sysEpollCreate`nin belge notu) İZLER: `posix.system.*` libc
    /// bağlıyken `std.c.timerfd_*`e çözülür, GERÇEK errno yan etkisiyle.
    fn sysTimerfdCreate() !posix.fd_t {
        const rc = posix.system.timerfd_create(posix.timerfd_clockid_t.MONOTONIC, 0);
        return switch (posix.errno(rc)) {
            .SUCCESS => rc,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .NODEV => error.SystemResources,
            .NOMEM => error.SystemResources,
            else => |err| posix.unexpectedErrno(err),
        };
    }

    /// `timeout_ms` SONRA (yalnızca BİR KEZ — `it_interval = 0`, tekrar
    /// YOK) ateşleyecek şekilde `fd`yi silahlandırır.
    fn sysTimerfdSettime(fd: posix.fd_t, timeout_ms: u32) !void {
        const spec: linux.itimerspec = .{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{
                .sec = @intCast(timeout_ms / 1000),
                .nsec = @intCast((timeout_ms % 1000) * std.time.ns_per_ms),
            },
        };
        const rc = posix.system.timerfd_settime(fd, 0, &spec, null);
        return switch (posix.errno(rc)) {
            .SUCCESS => {},
            else => |err| posix.unexpectedErrno(err),
        };
    }

    pub fn init() !@This() {
        return .{ .epfd = try sysEpollCreate() };
    }

    pub fn deinit(self: *@This()) void {
        _ = std.c.close(self.epfd);
    }

    fn epollFilterBits(filter: Filter) u32 {
        return switch (filter) {
            .read => linux.EPOLL.IN,
            .write => linux.EPOLL.OUT,
        };
    }

    fn addOrRearm(self: *@This(), fd: posix.fd_t, ev: *linux.epoll_event) !void {
        sysEpollCtl(self.epfd, linux.EPOLL.CTL_ADD, fd, ev) catch |err| switch (err) {
            error.AlreadyRegistered => try sysEpollCtl(self.epfd, linux.EPOLL.CTL_MOD, fd, ev),
            else => return err,
        };
    }

    /// Faz HH.7: `WaitCtx`in İŞARETÇİSİNİ (8 baytlık hizalama SAYESİNDE
    /// DÜŞÜK 3 biti HER ZAMAN sıfır olan) `epoll_event.data.u64`ye HANGİ
    /// KAYDIN (asıl fd mi zamanlayıcı mı) ait OLDUĞUNU DÜŞÜK bit'e
    /// ETİKETLEYEREK gömer — kqueue'nun `ev.filter`iyle DOĞRUDAN elde
    /// ettiği ayrımı, `epoll_event`in TAŞIMADIĞI İÇİN burada elle taklit
    /// eder (STANDART bir "etiketli işaretçi" tekniği).
    fn packCtx(ctx: *WaitCtx, is_timer: bool) u64 {
        return @as(u64, @intFromPtr(ctx)) | @intFromBool(is_timer);
    }
    fn unpackCtx(bits: u64) struct { ctx: *WaitCtx, is_timer: bool } {
        return .{ .ctx = @ptrFromInt(bits & ~@as(u64, 1)), .is_timer = (bits & 1) != 0 };
    }

    /// `fd` `filter` yönünde hazır olduğunda `ctx.fiber`ı BİR KEZ bildirir
    /// (`EPOLLONESHOT`) — ÖNCE `EPOLL_CTL_ADD` DENER, fd ZATEN kayıtlıysa
    /// (bir ÖNCEKİ `register`in ONESHOT'u ateşlenmiş ama fd HÂLÂ interest
    /// listesindeyse) `EPOLL_CTL_MOD`a DÜŞER — bkz. modül üstü not.
    pub fn register(self: *@This(), fd: posix.fd_t, filter: Filter, ctx: *WaitCtx) !void {
        var ev: linux.epoll_event = .{
            .events = epollFilterBits(filter) | linux.EPOLL.ONESHOT,
            .data = .{ .u64 = packCtx(ctx, false) },
        };
        try self.addOrRearm(fd, &ev);
    }

    /// Faz HH.7: `fd` `filter` yönünde hazır OLANA KADAR **VEYA**
    /// `timeout_ms` GEÇENE KADAR (HANGİSİ ÖNCE olursa) bekler — bkz. modül
    /// üstü not. Linux'ta GERÇEK bir zamanlayıcı ilkeli (`EVFILT_TIMER`)
    /// olmadığından, STANDART Linux idiomu izlenir: bir `timerfd` yaratılıp
    /// SIRADAN bir okunabilir fd GİBİ epoll'a kaydedilir.
    pub fn registerWithTimeout(self: *@This(), fd: posix.fd_t, filter: Filter, timeout_ms: u32, ctx: *WaitCtx) !void {
        ctx.has_timeout = true;
        ctx.target_fd = fd;
        ctx.target_filter = filter;

        const timer_fd = try sysTimerfdCreate();
        errdefer _ = std.c.close(timer_fd);
        try sysTimerfdSettime(timer_fd, timeout_ms);
        ctx.timer_fd = timer_fd;

        var io_ev: linux.epoll_event = .{
            .events = epollFilterBits(filter) | linux.EPOLL.ONESHOT,
            .data = .{ .u64 = packCtx(ctx, false) },
        };
        try self.addOrRearm(fd, &io_ev);

        var timer_ev: linux.epoll_event = .{
            .events = linux.EPOLL.IN | linux.EPOLL.ONESHOT,
            .data = .{ .u64 = packCtx(ctx, true) },
        };
        try sysEpollCtl(self.epfd, linux.EPOLL.CTL_ADD, timer_fd, &timer_ev);
    }

    /// En az bir olay hazır olana kadar BLOKE OLUR (`timeout_ms = -1`) —
    /// `KqueueReactor.poll` İLE AYNI kullanım sözleşmesi (bkz. onun belge
    /// notu). HER olayın `data.u64`sündeki `WaitCtx`i (bkz. `unpackCtx`)
    /// çözüp `scheduler.markReady(...)` ile hazır kuyruğa ekler.
    pub fn poll(self: *@This(), scheduler: anytype) !usize {
        var events: [64]linux.epoll_event = undefined;
        const n = try sysEpollWait(self.epfd, &events, -1);
        for (events[0..n]) |ev| {
            const unpacked = unpackCtx(ev.data.u64);
            const ctx = unpacked.ctx;
            if (ctx.resolved) continue;
            ctx.resolved = true;
            if (unpacked.is_timer) {
                ctx.result = .timed_out;
                // Bekleyen asıl-fd kaydını iptal et — `EPOLL_CTL_DEL`
                // (`close()` EDEMEYİZ, fd BAĞLANTININ SAHİBİDİR).
                var dummy: linux.epoll_event = undefined;
                _ = posix.system.epoll_ctl(self.epfd, linux.EPOLL.CTL_DEL, ctx.target_fd, &dummy);
            } else {
                ctx.result = .ready;
            }
            // HANGİ taraf ateşlerse ateşlesin `timerfd` TAM OLARAK BİR KEZ
            // kapatılır — `close()` onu OTOMATİK olarak epoll kümesinden de
            // kaldırır (bkz. modül üstü not).
            if (ctx.has_timeout) _ = std.c.close(ctx.timer_fd);
            scheduler.markReady(ctx.fiber);
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

const MarkReadySpy = struct {
    marked: ?*Fiber = null,
    fn markReady(self: *@This(), fiber: *Fiber) void {
        self.marked = fiber;
    }
};

test "IoReactor: bir soket çiftinde yazma tarafı, okuma tarafını hazır bildirir" {
    var fds: [2]posix.fd_t = undefined;
    if (std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var reactor = try IoReactor.init();
    defer reactor.deinit();

    // Sahte bir "fiber" işaretçisi (bu test yalnızca reaktörün olay
    // taşıyıcısında (kqueue: `udata`, epoll: `data.u64`) `WaitCtx`i doğru
    // taşıdığını doğrular — gerçek bir Fiber'a ihtiyaç yoktur, ama doğru
    // HİZALAMAYI garantilemek için gerçek `Fiber` tipi kullanılır).
    var fake_fiber_storage: Fiber = undefined;
    const fake_fiber: *Fiber = &fake_fiber_storage;
    var ctx: WaitCtx = .{ .fiber = fake_fiber };

    try reactor.register(fds[0], .read, &ctx);

    const written = std.c.write(fds[1], "merhaba", 7);
    try std.testing.expectEqual(@as(isize, 7), written);

    var spy = MarkReadySpy{};
    const n = try reactor.poll(&spy);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(?*Fiber, fake_fiber), spy.marked);
    try std.testing.expectEqual(WaitResult.ready, ctx.result);
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
    var ctx1: WaitCtx = .{ .fiber = fake_fiber };
    try reactor.register(fds[0], .read, &ctx1);
    _ = std.c.write(fds[1], "a", 1);
    var spy1 = MarkReadySpy{};
    _ = try reactor.poll(&spy1);
    try std.testing.expectEqual(@as(?*Fiber, fake_fiber), spy1.marked);
    var drain_buf: [1]u8 = undefined;
    _ = std.c.read(fds[0], &drain_buf, 1);

    // İKİNCİ tur: AYNI fd (fds[0]) TEKRAR register edilir — epoll'da bu,
    // ADD→EEXIST→MOD yoluna GİRMEK ZORUNDADIR (fd hâlâ interest listesinde).
    var ctx2: WaitCtx = .{ .fiber = fake_fiber };
    try reactor.register(fds[0], .read, &ctx2);
    _ = std.c.write(fds[1], "b", 1);
    var spy2 = MarkReadySpy{};
    const n2 = try reactor.poll(&spy2);
    try std.testing.expectEqual(@as(usize, 1), n2);
    try std.testing.expectEqual(@as(?*Fiber, fake_fiber), spy2.marked);
}

// Faz HH.7 (bkz. nox-teknik-spesifikasyon.md §3.68): `registerWithTimeout`in
// İKİ AYRI GİDİŞ YOLUNU (zaman aşımına UĞRAMA VE fd'nin ZAMANINDA hazır
// OLMASI) DOĞRUDAN, `Scheduler`/`Fiber` KARIŞIKLIĞI OLMADAN (bu dosyanın
// KENDİ testleriyle AYNI "sahte fiber + spy" deseni) doğrular.

test "IoReactor.registerWithTimeout: fd HIC hazir OLMAZSA zaman asimina UGRAR" {
    var fds: [2]posix.fd_t = undefined;
    if (std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var reactor = try IoReactor.init();
    defer reactor.deinit();

    var fake_fiber_storage: Fiber = undefined;
    const fake_fiber: *Fiber = &fake_fiber_storage;
    var ctx: WaitCtx = .{ .fiber = fake_fiber };

    // `fds[1]`e HİÇBİR ŞEY YAZILMAZ — `fds[0]` ASLA okunabilir OLMAZ, bu
    // yüzden KISA (50ms) zaman aşımı GERÇEKTEN ateşlemek ZORUNDADIR.
    try reactor.registerWithTimeout(fds[0], .read, 50, &ctx);

    var spy = MarkReadySpy{};
    const n = try reactor.poll(&spy);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(?*Fiber, fake_fiber), spy.marked);
    try std.testing.expectEqual(WaitResult.timed_out, ctx.result);
}

test "IoReactor.registerWithTimeout: fd ZAMANINDA hazir olursa .ready doner, zamanlayici SESSIZCE iptal edilir" {
    var fds: [2]posix.fd_t = undefined;
    if (std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var reactor = try IoReactor.init();
    defer reactor.deinit();

    var fake_fiber_storage: Fiber = undefined;
    const fake_fiber: *Fiber = &fake_fiber_storage;
    var ctx: WaitCtx = .{ .fiber = fake_fiber };

    // BÜYÜK (30s) bir zaman aşımıyla register edilir — test HEMEN veri
    // YAZDIĞINDAN fd'nin KENDİSİ önce hazır olmalı; test bu 30s'yi ASLA
    // BEKLEMEZ (yalnızca ZAMANLAYICININ İPTAL EDİLİP test'in HIZLI bitmesi
    // GEREKTİĞİNİN dolaylı kanıtı — `poll()` GERÇEKTEN 30s BLOKE OLSAYDI
    // bu test ZATEN pratikte asılı kalırdı).
    try reactor.registerWithTimeout(fds[0], .read, 30_000, &ctx);
    _ = std.c.write(fds[1], "merhaba", 7);

    var spy = MarkReadySpy{};
    const n = try reactor.poll(&spy);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(?*Fiber, fake_fiber), spy.marked);
    try std.testing.expectEqual(WaitResult.ready, ctx.result);
}
