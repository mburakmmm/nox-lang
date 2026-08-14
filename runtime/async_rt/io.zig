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

/// Faz LL.4/LL.5 (bkz. nox-teknik-spesifikasyon.md §3.71): `fcntl`/
/// `std.c.O` (bu Zig sürümünde Windows İçin `void`, bkz. `fs.zig`nin
/// `WinFile`nin AYNI belge notu) Windows'ta YOK — Winsock'un KENDİ
/// non-blocking-yapma ilkeli `ioctlsocket(fd, FIONBIO, &1)`dir. Benzer
/// şekilde `std.c.accept`/`read`/`write`in Windows SOCKET'leri İÇİN
/// GEÇERSİZ olması (CRT fd-tablosu İÇİN tasarlanmışlardır — bkz. `fs.
/// zig`nin AYNI ayrımı) YÜZÜNDEN Winsock'un KENDİ `accept`/`recv`/`send`i
/// KULLANILIR; hata denetimi İçin `posix.errno` DEĞİL `WSAGetLastError`
/// (Winsock CRT'nin `errno`SUNU ASLA doldurmaz).
/// `pub` — `http_server.zig`/`http_client.zig` (LL.5) DA AYNI Winsock
/// ilkellerine ihtiyaç duyar, `io_mod.WinSock` ÜZERİNDEN yeniden kullanır
/// (tekrar hand-declare ETMEK yerine).
pub const WinSock = if (builtin.os.tag == .windows) struct {
    pub extern "ws2_32" fn ioctlsocket(s: usize, cmd: i32, argp: *u32) callconv(.c) i32;
    pub extern "ws2_32" fn accept(s: usize, addr: ?*anyopaque, addrlen: ?*i32) callconv(.c) usize;
    pub extern "ws2_32" fn recv(s: usize, buf: [*]u8, len: i32, flags: i32) callconv(.c) i32;
    pub extern "ws2_32" fn send(s: usize, buf: [*]const u8, len: i32, flags: i32) callconv(.c) i32;
    pub extern "ws2_32" fn WSAGetLastError() callconv(.c) i32;
    /// LL.5: `http_server.zig`/`http_client.zig`nin bağlantı-KURMA
    /// (`socket`/`bind`/`listen`/`connect`/`setsockopt`/`getsockname`/
    /// `closesocket`) İçin ek olarak ihtiyaç duyduğu Winsock ilkelleri —
    /// AYNI "CRT fd-tablosu İçin tasarlanmış std.c.* SOCKET'ler İçin
    /// GEÇERSİZ" gerekçesiyle.
    pub extern "ws2_32" fn socket(af: i32, socket_type: i32, protocol: i32) callconv(.c) usize;
    pub extern "ws2_32" fn bind(s: usize, addr: *const std.os.windows.ws2_32.sockaddr.in, namelen: i32) callconv(.c) i32;
    pub extern "ws2_32" fn listen(s: usize, backlog: i32) callconv(.c) i32;
    pub extern "ws2_32" fn connect(s: usize, addr: *const std.os.windows.ws2_32.sockaddr.in, namelen: i32) callconv(.c) i32;
    pub extern "ws2_32" fn setsockopt(s: usize, level: i32, optname: i32, optval: ?*const anyopaque, optlen: i32) callconv(.c) i32;
    pub extern "ws2_32" fn getsockname(s: usize, addr: *std.os.windows.ws2_32.sockaddr.in, namelen: *i32) callconv(.c) i32;
    pub extern "ws2_32" fn closesocket(s: usize) callconv(.c) i32;
    pub const FIONBIO: i32 = -2147195266; // 0x8004667e (i32 olarak imzalı bit deseni)
    pub const INVALID_SOCKET: usize = ~@as(usize, 0);
    pub const WSAEWOULDBLOCK: i32 = 10035;
    /// Bir istemcinin bağlantıyı ANİDEN sıfırlaması (TCP RST) — POSIX'in
    /// `ECONNRESET`/`ECONNABORTED`sinin Winsock eşleniği. Bkz. aşağıdaki
    /// `.CONNRESET`/`.CONNABORTED` işleme notu (POSIX yolu).
    pub const WSAECONNRESET: i32 = 10054;
    pub const WSAECONNABORTED: i32 = 10053;
    pub const AF_INET: i32 = 2;
    pub const SOCK_STREAM: i32 = 1;
    pub const SOL_SOCKET: i32 = 0xffff;
    pub const SO_REUSEADDR: i32 = 0x0004;
    /// Performans notu (bkz. `setTcpNodelay`nin belge notu): standart
    /// Winsock değerleri — `IPPROTO_TCP`/`TCP_NODELAY` platformdan bağımsız
    /// SABİT sayılardır (BSD soket API'siyle PAYLAŞILIR).
    pub const IPPROTO_TCP: i32 = 6;
    pub const TCP_NODELAY: i32 = 1;
} else struct {};

/// Bir soketi non-blocking yapar — idempotenttir (zaten non-blocking olan
/// bir fd üzerinde tekrar çağrılması güvenlidir), bu yüzden HER
/// `nonBlockingAccept`/`Read`/`Write` çağrısının başında koşulsuz çağrılır.
fn setNonBlocking(fd: posix.fd_t) void {
    if (builtin.os.tag == .windows) {
        var mode: u32 = 1;
        _ = WinSock.ioctlsocket(@intFromPtr(fd), WinSock.FIONBIO, &mode);
        return;
    }
    const current = std.c.fcntl(fd, std.c.F.GETFL);
    var flags: std.c.O = @bitCast(@as(u32, @intCast(current)));
    flags.NONBLOCK = true;
    _ = std.c.fcntl(fd, std.c.F.SETFL, @as(u32, @bitCast(flags)));
}

/// Performans: Nagle algoritmasını KAPATIR — `nox.http`nin kabul ettiği
/// HER bağlantı soketine (dinleme soketine DEĞİL) uygulanır. `http_server.
/// zig`nin `connectionEntry`si küçük yanıtları (JSON gövdeli, birkaç yüz
/// bayt) `request.respond`ın KENDİ TAMPONLU `Writer`ı ÜZERİNDEN yazar —
/// Nagle AÇIKKEN, bu küçük yazımlar istemcinin gecikmeli-ACK'ıyla
/// ETKİLEŞİME girip yanıt başına onlarca milisaniyelik GEREKSİZ bir
/// gecikme EKLEYEBİLİR (klasik "Nagle + delayed-ACK" sorunu — HTTP
/// keep-alive sunucularında İYİ bilinen bir throughput darboğazı).
/// `setsockopt` başarısız OLURSA (nadir, platforma özgü) sessizce
/// YOKSAYILIR — bu SADECE bir gecikme OPTİMİZASYONU, doğruluğu ETKİLEMEZ.
/// `pub` — `nonBlockingAccept` (aşağı) VE `http_server.zig`nin `blockingAccept`i
/// (fiber-DIŞI/senkron kabul yolu) İKİSİ de ÇAĞIRIR.
pub fn setTcpNodelay(fd: posix.fd_t) void {
    var enable: c_int = 1;
    if (builtin.os.tag == .windows) {
        _ = WinSock.setsockopt(@intFromPtr(fd), WinSock.IPPROTO_TCP, WinSock.TCP_NODELAY, &enable, @sizeOf(c_int));
        return;
    }
    _ = std.c.setsockopt(fd, std.c.IPPROTO.TCP, std.c.TCP.NODELAY, &enable, @sizeOf(c_int));
}

/// `listen_fd` üzerinde bir bağlantı hazır olana kadar ÇAĞIRAN fiber'ı
/// (bkz. `Scheduler.suspendForIo`) askıya alır — GERÇEK sonuç alınana ya
/// da gerçek bir hataya kadar TEKRAR dener.
pub fn nonBlockingAccept(scheduler: *Scheduler, listen_fd: posix.fd_t) !posix.fd_t {
    setNonBlocking(listen_fd);
    while (true) {
        if (builtin.os.tag == .windows) {
            const rc = WinSock.accept(@intFromPtr(listen_fd), null, null);
            if (rc != WinSock.INVALID_SOCKET) {
                const conn_fd: posix.fd_t = @ptrFromInt(rc);
                setTcpNodelay(conn_fd);
                return conn_fd;
            }
            if (WinSock.WSAGetLastError() == WinSock.WSAEWOULDBLOCK) {
                scheduler.suspendForIo(listen_fd, .read);
                continue;
            }
            // Bkz. POSIX yolunun `.CONNABORTED` notu — İstemci, kuyruğa
            // alınmış bir bağlantıyı `accept()` İŞLENMEDEN İPTAL/RESET
            // ETMİŞ olabilir; dinleme soketinin KENDİSİ hâlâ GEÇERLİDİR,
            // BASİTÇE TEKRAR denenir.
            if (WinSock.WSAGetLastError() == WinSock.WSAECONNABORTED or WinSock.WSAGetLastError() == WinSock.WSAECONNRESET) continue;
            return error.Unexpected;
        }
        const rc = std.c.accept(listen_fd, null, null);
        if (rc >= 0) {
            setTcpNodelay(rc);
            return rc;
        }
        switch (posix.errno(rc)) {
            .AGAIN => scheduler.suspendForIo(listen_fd, .read),
            // POSIX bunu AÇIKÇA İZİN VERİR (bkz. `accept(2)`): istemci,
            // kuyruğa alınmış bir bağlantıyı `accept()` onu İŞLEMEDEN
            // ÖNCE RST İLE İPTAL ederse `ECONNABORTED` dönebilir —
            // dinleme soketinin KENDİSİ hâlâ GEÇERLİDİR, bu TEK bağlantı
            // adayı YOK SAYILIP döngü TEKRARLANIR (`unexpectedErrno`nin
            // gürültülü/panik-BENZERİ yoluna DÜŞMEDEN).
            .CONNABORTED => {},
            else => |e| return posix.unexpectedErrno(e),
        }
    }
}

/// `nonBlockingAccept`İLE AYNI, AMA `timeout_ms` GEÇTİĞİNDE (bağlantı
/// GELMEDEN) `error.Timeout` DÖNER — `suspendForIoOrTimeout`nin AYNI
/// (`nonBlockingReadWithTimeout`de KANITLANMIŞ) deseni. Faz MN.11.1
/// (bkz. proje planı, "SO_REUSEPORT + sınırlı max_connections" düzeltmesi):
/// `nox.http.serve_multicore`nin PAYLAŞILAN bağlantı bütçesi (`SharedServeBudget`)
/// KULLANILDIĞINDA, HER worker'ın `accept()`i SINIRLI bir pencerede
/// beklemesini VE zaman aşımında paylaşılan sayacı YENİDEN kontrol
/// edebilmesini SAĞLAR — aksi halde kotayı hiç ALAMAYAN bir worker,
/// `SO_REUSEPORT`nin kernel-seviyesi bağlantı dağılımının kendisine
/// HİÇBİR ŞEY yönlendirmediği durumda `accept()`te SONSUZA KADAR bekler.
pub fn nonBlockingAcceptWithTimeout(scheduler: *Scheduler, listen_fd: posix.fd_t, timeout_ms: u32) !posix.fd_t {
    setNonBlocking(listen_fd);
    while (true) {
        if (builtin.os.tag == .windows) {
            const rc = WinSock.accept(@intFromPtr(listen_fd), null, null);
            if (rc != WinSock.INVALID_SOCKET) {
                const conn_fd: posix.fd_t = @ptrFromInt(rc);
                setTcpNodelay(conn_fd);
                return conn_fd;
            }
            if (WinSock.WSAGetLastError() == WinSock.WSAEWOULDBLOCK) {
                if (scheduler.suspendForIoOrTimeout(listen_fd, .read, timeout_ms) == .timed_out) return error.Timeout;
                continue;
            }
            if (WinSock.WSAGetLastError() == WinSock.WSAECONNABORTED or WinSock.WSAGetLastError() == WinSock.WSAECONNRESET) continue;
            return error.Unexpected;
        }
        const rc = std.c.accept(listen_fd, null, null);
        if (rc >= 0) {
            setTcpNodelay(rc);
            return rc;
        }
        switch (posix.errno(rc)) {
            .AGAIN => if (scheduler.suspendForIoOrTimeout(listen_fd, .read, timeout_ms) == .timed_out) return error.Timeout,
            // Bkz. `nonBlockingAccept`in AYNI notu.
            .CONNABORTED => {},
            else => |e| return posix.unexpectedErrno(e),
        }
    }
}

/// `fd`den `buf`a okur — veri hazır olana kadar askıya alıp TEKRAR dener.
/// `read()`in `0` dönmesi (EOF/bağlantı kapandı) GEÇERLİ bir sonuçtur,
/// hata SAYILMAZ (çağıran bunu ayırt eder — `strlen`/döngü sonlandırma
/// mantığı `nox.http`in (D.1) kendi sorumluluğudur). **`ECONNRESET`
/// (istemci TCP RST İLE bağlantıyı ANİDEN kapattı — `wrk` GİBİ yük-test
/// araçlarının zaman aşımında/koşum sonunda RUTİN olarak yaptığı bir şey)
/// AYNI şekilde `0` (EOF) OLARAK ele alınır**: pratik sonuç AYNIDIR ("bu
/// bağlantıdan artık KULLANILABİLİR veri gelmeyecek"), bu yüzden `.AGAIN`
/// DIŞINDAKİ HER şeyi `posix.unexpectedErrno`nin gürültülü (`stderr`e iz
/// düşüren) YOLUNA düşüren ESKİ `switch`, TAMAMEN NORMAL/beklenen bu
/// durumu YANLIŞLIKLA bir "beklenmeyen hata" gibi ele alıyordu (GERÇEK,
/// yeniden üretilebilir bir hata — `wrk` yükü ALTINDA gözlemlenip
/// düzeltildi). Bu sayede `FiberReader.stream`in MEVCUT `if (n == 0)
/// return error.EndOfStream` yolu (bkz. `http_server.zig`) HİÇBİR ek
/// değişiklik GEREKMEDEN doğru şekilde devreye girer.
pub fn nonBlockingRead(scheduler: *Scheduler, fd: posix.fd_t, buf: []u8) !usize {
    setNonBlocking(fd);
    while (true) {
        if (builtin.os.tag == .windows) {
            const rc = WinSock.recv(@intFromPtr(fd), buf.ptr, @intCast(buf.len), 0);
            if (rc >= 0) return @intCast(rc);
            if (WinSock.WSAGetLastError() == WinSock.WSAEWOULDBLOCK) {
                scheduler.suspendForIo(fd, .read);
                continue;
            }
            if (WinSock.WSAGetLastError() == WinSock.WSAECONNRESET) return 0;
            return error.Unexpected;
        }
        const rc = std.c.read(fd, buf.ptr, buf.len);
        if (rc >= 0) return @intCast(rc);
        switch (posix.errno(rc)) {
            .AGAIN => scheduler.suspendForIo(fd, .read),
            .CONNRESET => return 0,
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
        if (builtin.os.tag == .windows) {
            const rc = WinSock.recv(@intFromPtr(fd), buf.ptr, @intCast(buf.len), 0);
            if (rc >= 0) return @intCast(rc);
            if (WinSock.WSAGetLastError() == WinSock.WSAEWOULDBLOCK) {
                if (scheduler.suspendForIoOrTimeout(fd, .read, timeout_ms) == .timed_out) return error.Timeout;
                continue;
            }
            // Bkz. `nonBlockingRead`in AYNI notu — `ECONNRESET` EOF (`0`)
            // GİBİ ele alınır.
            if (WinSock.WSAGetLastError() == WinSock.WSAECONNRESET) return 0;
            return error.Unexpected;
        }
        const rc = std.c.read(fd, buf.ptr, buf.len);
        if (rc >= 0) return @intCast(rc);
        switch (posix.errno(rc)) {
            .AGAIN => if (scheduler.suspendForIoOrTimeout(fd, .read, timeout_ms) == .timed_out) return error.Timeout,
            // Bkz. `nonBlockingRead`in AYNI notu — `wrk` GİBİ istemcilerin
            // yük-testi SIRASINDA/SONUNDA RUTİN olarak yaptığı bir TCP RST,
            // `posix.unexpectedErrno`nin gürültülü YOLUNA DÜŞMEDEN, EOF
            // İLE AYNI (`0`) şekilde ele alınır. **BULUNAN, ÇOK DAHA CİDDİ
            // bir GERÇEK hata (bkz. AYRI görev): `posix.unexpectedErrno`nin
            // `debug.dumpCurrentStackTrace()`si bir Nox FİBER'ının (ÖZEL,
            // OS iş parçacığı yığınından FARKLI) yığınını unwind ETMEYE
            // ÇALIŞTIĞINDA GERÇEK bir SEGFAULT'a (Zig'in yerel unwind'ı
            // fiber'ın YIĞIN düzenini ANLAMAZ), ARDINDAN o segfault'un
            // KENDİ handler'ının AYNI bozuk yolu TEKRAR ÇAĞIRMASIYLA
            // (`debug.handleSegfault` → `writeCurrentStackTrace` →
            // TEKRAR) SÜRECİ ASKIYA DÜŞÜRÜYOR — BU switch koluna GERÇEKTEN
            // bu düzeltme GERİ ALINIP test ÇALIŞTIRILARAK DOĞRUDAN
            // GÖZLEMLENDİ. Yani `.CONNRESET`i BURADA yakalamak SADECE
            // gürültüyü ÖNLEMİYOR, `nonBlockingReadWithTimeout`ı ÇAĞIRAN
            // HER fiber İçİn GERÇEK bir askıya-düşme/çökme riskini de
            // ORTADAN KALDIRIYOR.
            .CONNRESET => return 0,
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
        if (builtin.os.tag == .windows) {
            const rc = WinSock.send(@intFromPtr(fd), buf.ptr, @intCast(buf.len), 0);
            if (rc >= 0) return @intCast(rc);
            if (WinSock.WSAGetLastError() == WinSock.WSAEWOULDBLOCK) {
                scheduler.suspendForIo(fd, .write);
                continue;
            }
            // Bkz. POSIX yolunun `.CONNRESET`/`.PIPE` notu — YAZMA'da (okumanın
            // AKSİNE) `0` dönmenin YERLEŞİK bir "bağlantı kapandı" ANLAMI
            // YOKTUR, bu YÜZDEN EOF'a benzetmek YERİNE `std.posix.read`in
            // KENDİ `ECONNRESET` İçin kullandığı (`posix.zig:426`) AYNI
            // isimli, `FiberWriter.drain`in (bkz. `http_server.zig`) ZATEN
            // GENEL olarak `catch return error.WriteFailed` İLE yakaladığı
            // ADLANDIRILMIŞ bir hata döner.
            if (WinSock.WSAGetLastError() == WinSock.WSAECONNRESET) return error.ConnectionResetByPeer;
            return error.Unexpected;
        }
        const rc = std.c.write(fd, buf.ptr, buf.len);
        if (rc >= 0) return @intCast(rc);
        switch (posix.errno(rc)) {
            .AGAIN => scheduler.suspendForIo(fd, .write),
            // İstemci bağlantıyı bir TCP RST İLE ANİDEN kapattı (`wrk`
            // GİBİ yük-test araçlarının zaman aşımında/koşum sonunda
            // RUTİN olarak yaptığı bir şey) — `Zig`in KENDİ `std.posix.
            // read`inin `ECONNRESET` İçin kullandığı AYNI isimli hata
            // (`error.ConnectionResetByPeer`, `posix.zig:426`), NOKTALI
            // `posix.unexpectedErrno`nin gürültülü YOLU YERİNE.
            .CONNRESET => return error.ConnectionResetByPeer,
            // `EPIPE`: karşı taraf ZATEN okuma ucunu kapatmış bir soket/
            // borsağa yazma denemesi — `std.Io.zig`nin (`Io.zig:313`)
            // KENDİ `BrokenPipe` adını taşır, AYNI gerekçeyle.
            .PIPE => return error.BrokenPipe,
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

// **GERÇEK, `wrk` yük-testi ALTINDA yakalanan bir hata**: bir istemci
// bağlantısını `SO_LINGER{onoff=1, linger=0}` İLE (TCP RST — ANİ
// sıfırlama, normal FIN DEĞİL) kapattığında, sunucu tarafındaki fd'de
// bekleyen bir `nonBlockingReadWithTimeout`/`nonBlockingRead` çağrısı
// `ECONNRESET` alıyordu — ESKİ `switch`in `.AGAIN` DIŞINDAKİ HER ŞEYİ
// `posix.unexpectedErrno`nin gürültülü (`stderr`e iz düşüren) YOLUNA
// düşürmesi YÜZÜNDEN. Bu test, GERÇEK bir TCP soket ÇİFTİ (AF_UNIX
// `socketpair` DEĞİL — `SO_LINGER`nin RST-ÜRETME semantiği YALNIZCA
// GERÇEK TCP'de ANLAMLIDIR) İLE bu KOŞULU DETERMİNİSTİK olarak üretip:
// (1) okuma çağrısının bir HATA/panik OLMADAN, EOF İLE AYNI (`0`) sonucu
// döndürdüğünü, (2) BUNUN, zamanlayıcının/reaktörün KENDİSİNİ BOZMADIĞINI
// (AYNI `scheduler.run()` çağrısı İÇİNDE ÇALIŞAN, TAMAMEN AYRI BAŞKA bir
// fiber'ın normal G/Ç'sinin de doğru tamamlandığını doğrulayarak) kanıtlar.
test "nonBlockingReadWithTimeout: istemci TCP RST ile ANİ kapatınca ECONNRESET EOF gibi (panik OLMADAN) ele alınır, zamanlayıcı BOZULMAZ" {
    // Bkz. yukarıdaki testin AYNI "Windows'ta HENÜZ Winsock'a taşınmadı"
    // gerekçesi (LL.5 kapsamı) — `SO_LINGER`nin KENDİSİ de platforma özgü
    // BSD-soket API'sidir.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    // Dinleme soketi: 127.0.0.1'de OS'un ATADIĞI bir port (`bind(0)` +
    // `getsockname`) — `tests/compat/http_serve_golden_test.zig`nin AYNI
    // `probeFreePort` desenine PARALEL, ama BURADA tek bir soket
    // KULLANILARAK (dinle → BAĞLAN → kabul et, HEPSİ TEK testte).
    const listen_fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (listen_fd < 0) return error.SocketFailed;
    defer _ = std.c.close(listen_fd);
    var reuse: c_int = 1;
    _ = std.c.setsockopt(listen_fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &reuse, @sizeOf(c_int));
    var bind_addr: std.c.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (std.c.bind(listen_fd, @ptrCast(&bind_addr), @sizeOf(std.c.sockaddr.in)) != 0) return error.BindFailed;
    if (std.c.listen(listen_fd, 4) != 0) return error.ListenFailed;
    var got_addr: std.c.sockaddr.in = undefined;
    var got_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
    if (std.c.getsockname(listen_fd, @ptrCast(&got_addr), &got_len) != 0) return error.GetsocknameFailed;
    const port = std.mem.bigToNative(u16, got_addr.port);

    const client_fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (client_fd < 0) return error.SocketFailed;
    var connect_addr: std.c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (std.c.connect(client_fd, @ptrCast(&connect_addr), @sizeOf(std.c.sockaddr.in)) != 0) return error.ConnectFailed;

    const server_fd = std.c.accept(listen_fd, null, null);
    if (server_fd < 0) return error.AcceptFailed;

    // `SO_LINGER{onoff=1, linger=0}` + `close()`: OS'a bu bağlantıyı
    // NORMAL bir FIN İLE DEĞİL, ANİ bir RST İLE sonlandırmasını SÖYLER —
    // karşı tarafın (sunucu, `server_fd`) BİR SONRAKİ `read()`i `ECONNRESET`
    // alır (GERÇEK `wrk` DAVRANIŞININ, KENDİ testimizde DETERMİNİSTİK
    // ÜRETİMİ).
    const lopt: std.c.linger = .{ .onoff = 1, .linger = 0 };
    _ = std.c.setsockopt(client_fd, std.c.SOL.SOCKET, std.c.SO.LINGER, &lopt, @sizeOf(std.c.linger));
    _ = std.c.close(client_fd);

    // İKİNCİ, TAMAMEN BAĞIMSIZ bir soket çifti (`socketpair`, İLK testle
    // AYNI desen) — reset-tetikleyen okuma İLE AYNI `scheduler.run()`
    // çağrısı İÇİNDE ÇALIŞTIRILIR: zamanlayıcının/reaktörün RESET
    // OLAYINDAN SONRA da BAŞKA fiber'lara doğru hizmet vermeye devam
    // ETTİĞİNİN kanıtı (kullanıcının "sunucu ... BAŞKA bağlantılara
    // hizmet vermeye devam eder" gerekçesi).
    var pair_fds: [2]posix.fd_t = undefined;
    if (std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &pair_fds) != 0) return error.SocketPairFailed;
    defer _ = std.c.close(pair_fds[0]);
    defer _ = std.c.close(pair_fds[1]);

    const spawn = @import("scheduler.zig").spawn;
    var scheduler = try Scheduler.init(std.heap.page_allocator);
    defer scheduler.deinit();

    const Shared = struct {
        var reset_result: ?(anyerror!usize) = null;
        var scheduler_ptr: *Scheduler = undefined;
        var reset_fd: posix.fd_t = undefined;
        var pair_read_fd: posix.fd_t = undefined;
        var pair_write_fd: posix.fd_t = undefined;
        var pair_got: [16]u8 = undefined;
        var pair_got_len: usize = 0;

        fn resetReaderFn(_: *anyopaque) callconv(.c) void {
            var buf: [64]u8 = undefined;
            reset_result = nonBlockingReadWithTimeout(scheduler_ptr, reset_fd, &buf, 2000);
        }
        fn pairReaderFn(_: *anyopaque) callconv(.c) void {
            pair_got_len = nonBlockingRead(scheduler_ptr, pair_read_fd, &pair_got) catch unreachable;
        }
        fn pairWriterFn(_: *anyopaque) callconv(.c) void {
            _ = nonBlockingWrite(scheduler_ptr, pair_write_fd, "hala-canli") catch unreachable;
        }
    };
    Shared.scheduler_ptr = &scheduler;
    Shared.reset_fd = server_fd;
    Shared.pair_read_fd = pair_fds[0];
    Shared.pair_write_fd = pair_fds[1];

    var dummy: u8 = 0;
    const reset_task = try spawn(&scheduler, void, Shared.resetReaderFn, &dummy);
    defer scheduler.allocator.destroy(reset_task);
    const pair_reader_task = try spawn(&scheduler, void, Shared.pairReaderFn, &dummy);
    defer scheduler.allocator.destroy(pair_reader_task);
    const pair_writer_task = try spawn(&scheduler, void, Shared.pairWriterFn, &dummy);
    defer scheduler.allocator.destroy(pair_writer_task);

    try scheduler.run();
    _ = std.c.close(server_fd);

    // (1) RST-tetikleyen okuma bir HATA/panik DEĞİL, `0` (EOF İLE AYNI)
    // döndürdü.
    const rr = Shared.reset_result orelse return error.ReaderNeverRan;
    try std.testing.expectEqual(@as(usize, 0), try rr);
    // (2) Zamanlayıcı/reaktör BOZULMADI — TAMAMEN BAĞIMSIZ soket çifti
    // AYNI koşumda doğru tamamlandı.
    try std.testing.expectEqualStrings("hala-canli", Shared.pair_got[0..Shared.pair_got_len]);
}
