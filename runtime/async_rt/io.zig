//! Non-blocking soket ilkelleri — D.0'ın (bkz. nox-teknik-spesifikasyon.md
//! §3.29) kqueue reaktörünü kullanarak `accept`/`read`/`write`i "hazır
//! olana kadar askıya al, hazır olunca TEKRAR dene" döngüsüne çevirir.
//! Nox diline/checker'a/codegen'e HİÇBİR değişiklik GETİRMEZ (bu dosyadaki
//! `pub fn`lar `export fn` DEĞİLDİR) — `nox.http`in (D.1, ayrı bir faz)
//! Zig kabuğunun DOĞRUDAN kullanacağı temel taşlardır.
//!
//! **Neden bir döngü (tek bir `suspendForIo` + ardından TEKRAR deneme)
//! gerekir:** kqueue yalnızca "bu fd artık hazır" der — işlemin (accept/
//! read/write) KENDİSİNİ YAPMAZ. `EV_ONESHOT` (bkz. `io_reactor.zig`)
//! nedeniyle bildirim BİR KEZLİKTİR, bu yüzden her `EAGAIN`den SONRA
//! `register` DE tekrar çağrılmalıdır — bu döngü YAPISI (kayıt → askıya al
//! → tekrar dene) tam da bunu sağlar.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Scheduler = @import("scheduler.zig").Scheduler;

/// Bir soketi non-blocking yapar — idempotenttir (zaten non-blocking olan
/// bir fd üzerinde tekrar çağrılması güvenlidir), bu yüzden HER
/// `nonBlockingAccept`/`Read`/`Write` çağrısının başında koşulsuz çağrılır.
fn setNonBlocking(fd: posix.fd_t) void {
    const current = std.c.fcntl(fd, std.c.F.GETFL);
    var flags: std.c.O = @bitCast(@as(u32, @intCast(current)));
    flags.NONBLOCK = true;
    _ = std.c.fcntl(fd, std.c.F.SETFL, @as(u32, @bitCast(flags)));
}

/// `listen_fd` üzerinde bir bağlantı hazır olana kadar ÇAĞIRAN fiber'ı
/// (bkz. `Scheduler.suspendForIo`) askıya alır — GERÇEK sonuç alınana ya
/// da gerçek bir hataya kadar TEKRAR dener.
pub fn nonBlockingAccept(scheduler: *Scheduler, listen_fd: posix.fd_t) !posix.fd_t {
    setNonBlocking(listen_fd);
    while (true) {
        const rc = std.c.accept(listen_fd, null, null);
        if (rc >= 0) return rc;
        switch (posix.errno(rc)) {
            .AGAIN => scheduler.suspendForIo(listen_fd, .read),
            else => |e| return posix.unexpectedErrno(e),
        }
    }
}

/// `fd`den `buf`a okur — veri hazır olana kadar askıya alıp TEKRAR dener.
/// `read()`in `0` dönmesi (EOF/bağlantı kapandı) GEÇERLİ bir sonuçtur,
/// hata SAYILMAZ (çağıran bunu ayırt eder — `strlen`/döngü sonlandırma
/// mantığı `nox.http`in (D.1) kendi sorumluluğudur).
pub fn nonBlockingRead(scheduler: *Scheduler, fd: posix.fd_t, buf: []u8) !usize {
    setNonBlocking(fd);
    while (true) {
        const rc = std.c.read(fd, buf.ptr, buf.len);
        if (rc >= 0) return @intCast(rc);
        switch (posix.errno(rc)) {
            .AGAIN => scheduler.suspendForIo(fd, .read),
            else => |e| return posix.unexpectedErrno(e),
        }
    }
}

/// Faz HH.7 (bkz. nox-teknik-spesifikasyon.md §3.68): `nonBlockingRead`
/// İLE AYNI, ama `fd` OKUNABİLİR olmadan `timeout_ms` GEÇERSE `error.
/// Timeout` döner — okuma zaman aşımı/slowloris korumasının (bkz.
/// `http_server.zig`nin `FiberReader.stream`i, HEM başlık HEM gövde
/// okumasının TEK geçtiği nokta) temel taşı. **DİKKAT (kasıtlı, GÜVENLİ
/// bir basitleştirme):** eşik `timeout_ms`, TOPLAM bekleme SÜRESİ DEĞİL,
/// HER TEK `EAGAIN` sonrası YENİDEN başlayan bir penceredir — yani bir
/// saldırganın veriyi `timeout_ms`DEN biraz KISA aralıklarla, TEK TEK
/// baytlar halinde göndermesi TEORİK olarak toplam süreyi UZATABİLİR.
/// Bu, slowloris'in KENDİSİNİN (baytları YAVAŞ AMA sürekli göndermek)
/// tanımına ZATEN AYKIRI bir çaba GEREKTİRDİĞİNDEN (gerçek slowloris
/// saldırıları veriyi HİÇ göndermez YA DA çok UZUN aralıklarla gönderir)
/// v1 kapsamında KABUL EDİLEBİLİR bir sınırlama olarak BİLİNÇLİ bırakıldı
/// — TOPLAM-süre tabanlı bir mutlak son tarih (deadline), her `EAGAIN`
/// SONRASI KALAN süreyi YENİDEN hesaplamayı gerektirirdi (ek karmaşıklık,
/// bu turun kapsamı DIŞINDA).
pub fn nonBlockingReadWithTimeout(scheduler: *Scheduler, fd: posix.fd_t, buf: []u8, timeout_ms: u32) !usize {
    setNonBlocking(fd);
    while (true) {
        const rc = std.c.read(fd, buf.ptr, buf.len);
        if (rc >= 0) return @intCast(rc);
        switch (posix.errno(rc)) {
            .AGAIN => if (scheduler.suspendForIoOrTimeout(fd, .read, timeout_ms) == .timed_out) return error.Timeout,
            else => |e| return posix.unexpectedErrno(e),
        }
    }
}

/// `buf`ı `fd`ye yazar — soket YAZILABİLİR olana kadar askıya alıp TEKRAR
/// dener. Kısmi yazmalar (`rc < buf.len`) OLABİLİR — çağıran (`nox.http`in
/// D.1'i) kalan baytlar İÇİN tekrar çağırmalıdır (POSIX `write`in normal
/// sözleşmesi, bu fonksiyon bunu GİZLEMEZ).
pub fn nonBlockingWrite(scheduler: *Scheduler, fd: posix.fd_t, buf: []const u8) !usize {
    setNonBlocking(fd);
    while (true) {
        const rc = std.c.write(fd, buf.ptr, buf.len);
        if (rc >= 0) return @intCast(rc);
        switch (posix.errno(rc)) {
            .AGAIN => scheduler.suspendForIo(fd, .write),
            else => |e| return posix.unexpectedErrno(e),
        }
    }
}

test "nonBlockingRead: bir fiber G/Ç beklerken BAŞKA bir hazır fiber çalışabilir (zamanlayıcı BLOKE OLMAZ)" {
    // Faz LL.2/LL.3 (bkz. nox-teknik-spesifikasyon.md §3.71): bu test
    // `nonBlockingRead`/`nonBlockingWrite`in KENDİSİNİ (yukarıda, `std.c.
    // read`/`write`/`fcntl` KULLANAN — ham CRT çağrıları, Winsock `SOCKET`
    // handle'ları İÇİN GEÇERSİZ) egzersiz eder — bu, `io_reactor.zig`nin
    // (LL.2/LL.3'te Windows'a TAŞINAN) reaktör/fiber KATMANI DEĞİL, SOKET
    // katmanının (LL.5'in kapsamı, HENÜZ Windows'a taşınmadı) bir parçası.
    // `std.c.socketpair`/`AF.UNIX` de Windows'ta YOK. Bu YÜZDEN BİLİNÇLİ
    // olarak Windows'ta ATLANIR — LL.5 bu testi de Winsock'a taşıyacak.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const spawn = @import("scheduler.zig").spawn;

    var fds: [2]posix.fd_t = undefined;
    if (std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var scheduler = try Scheduler.init(std.heap.page_allocator);
    defer scheduler.deinit();

    // `reader` ÖNCE spawn edilir (bkz. `spawn`, hazır kuyruğa hemen eklenir)
    // — bu yüzden `run()` İLK ÖNCE reader'ı çalıştırır, o da HENÜZ veri
    // olmadığından ANINDA askıya alınır (`nonBlockingRead` → `EAGAIN` →
    // `suspendForIo`). Zamanlayıcı GERÇEKTEN bloke OLSAYDI, `writer` HİÇBİR
    // ZAMAN çalışamaz ve test sonsuza dek asılı kalırdı (ya da bir
    // `error.Deadlock` fırlatırdı, çünkü `waiting_on_io` OLMADAN hazır
    // kuyruk boşalırdı) — bu test tam da BUNUN ARTIK doğru olduğunu
    // (reactor.poll'un devreye girdiğini) kanıtlar.
    const Shared = struct {
        var log: std.ArrayListUnmanaged([]const u8) = .empty;
        var scheduler_ptr: *Scheduler = undefined;
        var read_fd: posix.fd_t = undefined;
        var write_fd: posix.fd_t = undefined;
        var got: [16]u8 = undefined;
        var got_len: usize = 0;

        fn readerFn(_: *anyopaque) callconv(.c) void {
            got_len = nonBlockingRead(scheduler_ptr, read_fd, &got) catch unreachable;
            log.append(std.heap.page_allocator, "reader tamamlandi") catch unreachable;
        }
        fn writerFn(_: *anyopaque) callconv(.c) void {
            log.append(std.heap.page_allocator, "writer calisti") catch unreachable;
            _ = nonBlockingWrite(scheduler_ptr, write_fd, "merhaba") catch unreachable;
        }
    };
    defer Shared.log.deinit(std.heap.page_allocator);
    Shared.scheduler_ptr = &scheduler;
    Shared.read_fd = fds[0];
    Shared.write_fd = fds[1];

    var dummy: u8 = 0;
    const reader_task = try spawn(&scheduler, void, Shared.readerFn, &dummy);
    defer scheduler.allocator.destroy(reader_task);
    const writer_task = try spawn(&scheduler, void, Shared.writerFn, &dummy);
    defer scheduler.allocator.destroy(writer_task);

    try scheduler.run();

    // Sıra KANITI: writer, reader TAMAMLANMADAN ÖNCE çalıştı (reader askıda
    // beklerken) — GERÇEK çakışan ilerlemenin somut kanıtı.
    try std.testing.expectEqual(@as(usize, 2), Shared.log.items.len);
    try std.testing.expectEqualStrings("writer calisti", Shared.log.items[0]);
    try std.testing.expectEqualStrings("reader tamamlandi", Shared.log.items[1]);
    try std.testing.expectEqualStrings("merhaba", Shared.got[0..Shared.got_len]);
}
