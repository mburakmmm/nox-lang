//! `nox.http` sunucu Zig kabuğu — stdlib fazı §D.1.4 (bkz. nox-teknik-
//! spesifikasyon.md). İstemci kabuğunun (`http_client.zig`, D.1.3) AKSİNE
//! arka plan İŞ PARÇACIĞI KULLANMAZ — `runtime/async_rt/io.zig`nin D.0'da
//! kurulan `nonBlockingAccept`/`nonBlockingRead`/`nonBlockingWrite`i
//! üzerine KÜÇÜK, ÖZEL bir `std.Io.Reader`/`Writer` (yalnızca ZORUNLU
//! `stream`/`drain` fonksiyonlarını uygular, bkz. `Io/net.zig`nin KENDİ
//! soket Reader/Writer'ıyla AYNI desen) inşa edip DOĞRUDAN `std.http.Server`e
//! besler — bu, sunucunun GERÇEK fiber-native eşzamanlılıkla çalışmasını
//! sağlar (Keşif 1, bkz. plan dosyası): HER bağlantı KENDİ fiber'ında işlenir,
//! biri G/Ç beklerken (`receiveHead`/gövde okuma sırasında `EAGAIN` alıp
//! `suspendForIo`ya düşerse) zamanlayıcı BAŞKA bir bağlantının fiber'ına
//! GERÇEKTEN geçer (D.0'ın reaktörü sayesinde).
//!
//! **Bağlantı başına "ateşle-ve-unut" fiber (`Task[T]` SARMALAMADAN):**
//! `bridge.nox_async_spawn`ın `Task(i64)` sarmalayıcısı, sonucu `await_`
//! edilecek bir tutamaç VARSAYAR (`entryTrampoline`, işlev döndükten SONRA
//! `self.completed`/`self.result`ı YAZAR — işlev kendi `Task`ını kendi
//! SONUNDA yıkarsa bu bir kullanım-sonrası-serbest-bırakma olurdu). Bir HTTP
//! sunucusunun bağlantı işleyicileri İSE hiçbir zaman `await` EDİLMEZ (kabul
//! döngüsü bir SONRAKİ bağlantıyı beklemeye devam eder) — bu yüzden burada
//! `scheduler_mod.Scheduler`/`fiber_mod.Fiber`i (İKİSİ DE `pub`, Faz 21'den
//! beri) DOĞRUDAN kullanan, `Task` sarmalayıcısını ATLAYAN ayrı, minimal bir
//! "ateşle-ve-unut" spawn deseni uygulanır: `Fiber.create` + `scheduler.
//! live_count += 1` + `scheduler.markReady(fiber)` (`scheduler_mod.spawn`ın
//! KENDİ iç tarifiyle AYNI, yalnızca `Task` sarmalamadan) — fiber bittiğinde
//! `Scheduler.run()`ün MEVCUT temizleme yolu (`fiber.destroyKeepStack`+
//! `releaseStack`) OTOMATİK devreye girer, EK bir "task'ı yık" çağrısına
//! HİÇ GEREK KALMAZ.
//!
//! **`nox.http.serve`in çağrı-sitesi entegrasyonu (D.1.6) HENÜZ YOK:** bu
//! dosya, Nox'un `handle(req) -> HttpResponse` işlevini ÇAĞIRACAK per-call-site
//! sarmalayıcı (Keşif 5) İÇİN TEK bir genişletme noktası bırakır — `handler:
//! *const fn(?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque` (bağlam,
//! istek tutamacı) -> yanıt tutamacı. D.1.6, `nox.http.serve(port, handle)`
//! çağrı sitesini bu imzaya uyan bir sarmalayıcıyı `nox_http_serve_raw`a
//! geçirecek şekilde ÇEVİRECEK; bu dosyanın KENDİ birim testi (aşağıda) BU
//! genişletme noktasını DOĞRUDAN (Nox'a hiç dokunmadan) elle sağlanan bir
//! Zig işleviyle egzersiz eder.

const std = @import("std");
const posix = std.posix;
const asap = @import("../alloc/asap.zig");
const arc = @import("../alloc/arc.zig");
const dict_mod = @import("../collections/dict.zig");
const bridge = @import("../async_rt/bridge.zig");
const io_mod = @import("../async_rt/io.zig");
const scheduler_mod = @import("../async_rt/scheduler.zig");
const fiber_mod = @import("../async_rt/fiber.zig");
const http_client = @import("http_client.zig");
const str_mod = @import("../str.zig");

/// Faz HH.7 (bkz. nox-teknik-spesifikasyon.md §3.68): okuma zaman aşımı —
/// bir bağlantı BAŞLIK/GÖVDE göndermeden bu süreden UZUN askıda kalırsa
/// (slowloris tarzı) bağlantı SESSİZCE kapatılır (bkz. `rawRead`in `Timeout`
/// dalı, `FiberReader.stream` üzerinden `receiveHead`/gövde döngüsüne
/// GENEL bir okuma hatası olarak YAYILIR — Q.5'in "reddetmenin KENDİSİ ek
/// kaynak tüketmemeli" ilkesiyle TUTARLI, hiçbir HTTP yanıtı YAZILMAZ).
const READ_TIMEOUT_MS: u32 = 30_000;

fn rawRead(scheduler: ?*scheduler_mod.Scheduler, fd: posix.fd_t, buf: []u8, read_timeout_ms: u32) !usize {
    if (scheduler) |s| return io_mod.nonBlockingReadWithTimeout(s, fd, buf, read_timeout_ms);
    while (true) {
        const rc = std.c.read(fd, buf.ptr, buf.len);
        if (rc >= 0) return @intCast(rc);
        switch (posix.errno(rc)) {
            .INTR => continue,
            else => |e| return posix.unexpectedErrno(e),
        }
    }
}

fn rawWriteAll(scheduler: ?*scheduler_mod.Scheduler, fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = if (scheduler) |s|
            try io_mod.nonBlockingWrite(s, fd, bytes[off..])
        else blk: {
            while (true) {
                const rc = std.c.write(fd, bytes[off..].ptr, bytes.len - off);
                if (rc >= 0) break :blk @as(usize, @intCast(rc));
                switch (posix.errno(rc)) {
                    .INTR => continue,
                    else => |e| return posix.unexpectedErrno(e),
                }
            }
        };
        off += n;
    }
}

/// `stream`i (tek ZORUNLU `Io.Reader.VTable` alanı) D.0'ın `nonBlockingRead`ine
/// (fiber içi) ya da sıradan bloklayan `read()`e (fiber dışı) delege eder —
/// istemci kabuğunun `bridge.currentFiberScheduler` dual-path desenIYLE AYNI.
const FiberReader = struct {
    interface: std.Io.Reader,
    fd: posix.fd_t,
    scheduler: ?*scheduler_mod.Scheduler,
    read_timeout_ms: u32,

    fn init(fd: posix.fd_t, scheduler: ?*scheduler_mod.Scheduler, buffer: []u8, read_timeout_ms: u32) FiberReader {
        return .{
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
            .fd = fd,
            .scheduler = scheduler,
            .read_timeout_ms = read_timeout_ms,
        };
    }

    fn stream(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *FiberReader = @alignCast(@fieldParentPtr("interface", io_r));
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        const n = rawRead(self.scheduler, self.fd, dest, self.read_timeout_ms) catch return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        io_w.advance(n);
        return n;
    }
};

/// `drain`i (tek ZORUNLU `Io.Writer.VTable` alanı) AYNI dual-path desenle
/// gerçek bir soket yazmasına çevirir — HER `drain` çağrısı `buffer`+`data`
/// (+`splat` tekrarı) TAMAMEN yazılana kadar döngüde bekler (kısmi yazma
/// muhasebesiyle UĞRAŞILMAZ — basitlik İÇİN bilinçli, `Writer.consume`in
/// TÜM baytların yazıldığını varsayan tek-seferlik çağrısı yeterli).
const FiberWriter = struct {
    interface: std.Io.Writer,
    fd: posix.fd_t,
    scheduler: ?*scheduler_mod.Scheduler,

    fn init(fd: posix.fd_t, scheduler: ?*scheduler_mod.Scheduler, buffer: []u8) FiberWriter {
        return .{
            .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer },
            .fd = fd,
            .scheduler = scheduler,
        };
    }

    fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FiberWriter = @alignCast(@fieldParentPtr("interface", io_w));
        rawWriteAll(self.scheduler, self.fd, io_w.buffered()) catch return error.WriteFailed;
        for (data[0 .. data.len - 1]) |chunk| {
            rawWriteAll(self.scheduler, self.fd, chunk) catch return error.WriteFailed;
        }
        const pattern = data[data.len - 1];
        var i: usize = 0;
        while (i < splat) : (i += 1) {
            rawWriteAll(self.scheduler, self.fd, pattern) catch return error.WriteFailed;
        }
        const total = io_w.end + std.Io.Writer.countSplat(data, splat);
        return io_w.consume(total);
    }
};

/// Faz DD.1 (bkz. nox-teknik-spesifikasyon.md §3.60) — `owns_fd`:
/// `nox_http_server_close`in `listen_fd`yi GERÇEKTEN `close()`LAYIP
/// LAMAYACAĞINI belirler. Çok-çekirdekli sunum, TEK bir `listen_fd`yi
/// BİRDEN FAZLA bağımsız iş parçacığı/`ServerHandle` arasında PAYLAŞIR
/// (bkz. `nox_http_server_from_fd`) — paylaşılan bir fd'yi KOŞULSUZ
/// kapatmak, HENÜZ o fd üzerinde `accept()` bekleyen DİĞER iş
/// parçacıklarını "bad file descriptor" ile keserdi. `true` YALNIZCA
/// `nox_http_server_listen`in KENDİSİ fd'yi `socket()`/`bind()`/`listen()`
/// İLE YARATTIĞINDA (fd'nin GERÇEK sahibi OLDUĞUNDA).
const ServerHandle = struct { listen_fd: posix.fd_t, owns_fd: bool };

/// `nox_http_server_listen`in socket/bind/listen mantığı — Faz DD.1'de
/// `nox_http_listen_fd`in de (ham fd'yi `ServerHandle` SARMADAN, saf bir
/// `int` olarak dönmesi için) kullanabilmesi için ÇIKARILDI. `port = 0`
/// İSE OS boş bir port ATAR.
fn bindAndListen(port: i64) ?posix.fd_t {
    const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (fd < 0) return null;
    var reuse: c_int = 1;
    _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &reuse, @sizeOf(c_int));

    var addr: std.c.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, @intCast(port)),
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) != 0) {
        _ = std.c.close(fd);
        return null;
    }
    // Faz HH.1 (bkz. nox-teknik-spesifikasyon.md §3.6X): ÖNCEDEN 128 —
    // `benchmarks/http_compare/zig_server.zig`nin KARŞILAŞTIRMA sunucusu
    // ZATEN 1024 kullanıyordu, Nox'un KENDİSİ dezavantajlı bir backlog İLE
    // ölçülüyordu. Düşük backlog + `serve_multicore`nin N iş parçacığının
    // AYNI fd üzerinde thundering-herd `accept()`i (bkz. `nox_http_listen_fd`nin
    // belge notu) BİRLİKTE, yüksek eşzamanlılıkta gözlemlenen bağlantı
    // reddi/soket hatalarının BİR bileşenidir.
    if (std.c.listen(fd, 1024) != 0) {
        _ = std.c.close(fd);
        return null;
    }
    return fd;
}

/// `127.0.0.1:port`e bağlanıp dinlemeye başlar. `port = 0` İSE OS boş bir
/// port ATAR — gerçek portu `nox_http_server_port`la öğren.
export fn nox_http_server_listen(rt: ?*anyopaque, port: i64) callconv(.c) ?*anyopaque {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    const fd = bindAndListen(port) orelse return null;

    const handle = state.allocator().create(ServerHandle) catch {
        _ = std.c.close(fd);
        return null;
    };
    handle.* = .{ .listen_fd = fd, .owns_fd = true };
    return handle;
}

/// Faz DD.1 — `bindAndListen`i çağırıp ham fd'yi (ya da hatada `-1`)
/// DOĞRUDAN döner, hiçbir `ServerHandle` YARATMAZ. Bu ham `int`, `nox.
/// thread`in ZATEN desteklediği iş-parçacıkları-arası aktarım
/// tiplerinden biridir (bkz. `thread_bridge.zig`) — çok-çekirdekli
/// sunumun TEMEL taşı: TEK bir dinleme soketi, `nox_http_server_from_fd`
/// İLE N bağımsız iş parçacığına DAĞITILABİLİR (her biri KENDİ kqueue/
/// epoll'ıyla AYNI fd üzerinde `accept()` çağırır — işletim sistemi
/// düzeyinde standart, güvenli bir davranış, nginx worker'larının
/// PAYLAŞILAN bir dinleme soketini KENDİ epoll'larıyla izlemesiyle AYNI
/// desen; bkz. `nonBlockingAccept`in ÇAĞIRANIN KENDİ zamanlayıcısı
/// üzerinden kayıt yaptığı `io.zig`).
export fn nox_http_listen_fd(rt: ?*anyopaque, port: i64) callconv(.c) i64 {
    _ = rt;
    const fd = bindAndListen(port) orelse return -1;
    return @intCast(fd);
}

/// Faz DD.1 — `nox_http_listen_fd`İLE elde edilmiş, ZATEN dinlemede olan
/// PAYLAŞILAN bir fd'yi ÇAĞIRAN iş parçacığının KENDİ (`state.
/// allocator()`) taze bir `ServerHandle`ına SARAR — YENİDEN bağlamaz/
/// dinlemez. `owns_fd = false`: bu `ServerHandle` ÜZERİNDE `nox_http_
/// server_close` çağrılırsa YALNIZCA bu KÜÇÜK struct serbest bırakılır,
/// PAYLAŞILAN fd'nin KENDİSİ kapatılmaz (bkz. `ServerHandle`in belge
/// notu).
export fn nox_http_server_from_fd(rt: ?*anyopaque, fd: i64) callconv(.c) ?*anyopaque {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    if (fd < 0) return null;
    const handle = state.allocator().create(ServerHandle) catch return null;
    handle.* = .{ .listen_fd = @intCast(fd), .owns_fd = false };
    return handle;
}

export fn nox_http_server_port(server: ?*anyopaque) callconv(.c) i64 {
    const h: *ServerHandle = @ptrCast(@alignCast(server orelse return 0));
    var addr: std.c.sockaddr.in = undefined;
    var len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
    if (std.c.getsockname(h.listen_fd, @ptrCast(&addr), &len) != 0) return 0;
    return std.mem.bigToNative(u16, addr.port);
}

export fn nox_http_server_close(rt: ?*anyopaque, server: ?*anyopaque) callconv(.c) void {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return));
    const h: *ServerHandle = @ptrCast(@alignCast(server orelse return));
    if (h.owns_fd) _ = std.c.close(h.listen_fd);
    state.allocator().destroy(h);
}

fn blockingAccept(listen_fd: posix.fd_t) !posix.fd_t {
    while (true) {
        const rc = std.c.accept(listen_fd, null, null);
        if (rc >= 0) return rc;
        switch (posix.errno(rc)) {
            .INTR => continue,
            else => |e| return posix.unexpectedErrno(e),
        }
    }
}

/// D.1.6'nın `nox.http.serve(port, handle)` İÇİN üreteceği per-call-site
/// sarmalayıcının uyacağı imza — bkz. modül üstü not.
pub const HandlerFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;

/// Faz Q.5 (bkz. docs/uretim-hazirlik-analizi.md, P0 bulgusu: "sıfır HTTP
/// sunucusu DoS koruması") — İKİ somut kaynak-tüketimi vektörüne karşı
/// SABİT güvenlik sınırları: (1) tek bir isteğin gövdesi BELLEĞİ sınırsız
/// büyütemez (`connectionEntry`nin ÖNCEDEN `streamRemaining` ile SINIRSIZ
/// okuduğu yer, bkz. aşağı); (2) bir saldırgan `accept()`i sınırsız
/// tekrarlayıp HER biri İÇİN bir fiber+yığın (havuzdan ya da taze 256 KiB)
/// tükettiremez (`nox_http_serve_raw`nin kabul döngüsü, bkz. aşağı).
/// **Bilinçli KAPSAM DIŞI (dürüstçe belgelenen bir sınırlama):** bir
/// bağlantının BAŞLIK/GÖVDE göndermeden (slowloris tarzı) SINIRSIZ süre
/// askıda kalmasına karşı bir OKUMA ZAMAN AŞIMI henüz YOK — bu, `runtime/
/// async_rt`in kqueue reaktörüne bir ZAMANLAYICI (`EVFILT_TIMER`) desteği
/// EKLENMESİNİ gerektirir (mevcut reaktör YALNIZCA soket G/Ç olaylarını
/// dinler, bkz. `nox.time.sleep_ms`in "bloklayıcı" belge notuyla AYNI kök
/// neden) — bu, GELECEKTEKİ bir faza (muhtemelen R fazlarıyla BİRLİKTE,
/// reaktöre zamanlayıcı desteği eklenirken) bırakıldı. Bu sınırlama,
/// AŞAĞIDAKİ eşzamanlı-bağlantı SINIRI ile KISMEN azaltılır (askıda kalan
/// bağlantılar da bu sınıra dahildir, yani sınırsız ÇOĞALAMAZLAR).
const MAX_REQUEST_BODY_BYTES: usize = 10 * 1024 * 1024;
const DEFAULT_MAX_CONCURRENT_CONNECTIONS: usize = 4096;

// Faz HH.1: bir `ConnCtx` havuzu (Scheduler.stack_pool'un AYNI "geri
// dönüştür" deseni) DENENDİ, ama GERÇEK bir kullanım-sonrası-serbest-
// bırakma tuzağı bulundu: `serveImpl` (fiber yolunda) `max_connections`
// bağlantıyı KABUL EDER etmez DÖNER — henüz TAMAMLANMAMIŞ bağlantı
// fiber'ları (ör. "yavaş" bir istemci) `serveImpl`nin KENDİ yığın çerçevesi
// GERİ DÖNDÜKTEN ÇOK SONRA (zamanlayıcı onları HÂLÂ çalıştırırken)
// tamamlanabilir — havuz `serveImpl`nin yerel bir değişkeni OLSAYDI, o
// GERİ DÖNDÜKTEN sonra fiber'ın `defer`i SALLANAN bir işaretçiye yazardı.
// `ConnCtx` KÜÇÜK bir struct (birkaç işaretçi/usize) olduğundan, bu riski
// (havuzu `Scheduler`e taşıyıp modüller arası bağımlılık YARATMAK yerine)
// üstlenmeye DEĞMEDİ — `gpa.create`/`gpa.destroy` KORUNDU.
const ConnCtx = struct {
    allocator: std.mem.Allocator,
    // Faz HH.2: `connectionEntry`nin ARC-sahipli istek alanları inşa
    // edebilmesi (`nox_rc_alloc`/`dupeToNoxStr` `rt` GEREKTİRİR) İÇİN
    // eklendi — ÖNCEDEN yalnızca `allocator` (`state.allocator()`)
    // taşınıyordu, HAM `rt` işaretçisinin KENDİSİ YOKTU.
    rt: ?*anyopaque,
    fd: posix.fd_t,
    handler: HandlerFn,
    handler_ctx: ?*anyopaque,
    max_body_bytes: usize,
    active_connections: *usize,
    /// Faz HH.7: bkz. `READ_TIMEOUT_MS`in belge notu — `serveImpl`nin
    /// `max_body_bytes`/`max_concurrent`İYLE AYNI "gerçekçi varsayılanı
    /// BEKLEMEDEN testlerin KÜÇÜK/HIZLI değerlerle sınırı EGZERSİZ
    /// edebilmesi" gerekçesiyle PARAMETRE olarak taşınır.
    read_timeout_ms: u32,
};

// Faz HH.2 (bkz. nox-teknik-spesifikasyon.md §3.68): `method`/`target`/
// `body`/header isim-değerleri ARTIK `connectionEntry` TARAFINDAN
// DOĞRUDAN ARC-sahipli (`nox_rc_alloc` tabanlı, `http_client.dupeToNoxStr`
// İLE AYNI temsil) olarak inşa edilir — `nox_http_request_*` erişimcileri
// ARTIK BİR DAHA kopyalamaz, YALNIZCA `nox_rc_retain` yapar (bkz. onların
// belge notu). Bu, ÖNCEDEN VAR OLAN "ÖNCE `gpa.dupe` İLE düz bir kopya,
// SONRA `nox_http_request_*` çağrıldığında `dupeToNoxStr` İLE İKİNCİ bir
// ARC kopyası" çift-kopya desenini GİDERİR.
const ServerRequest = struct {
    method: ?[*:0]u8,
    target: ?[*:0]u8,
    body: ?[*:0]u8,
    headers: []const std.http.Header,
};

// Faz HH.3 (bkz. nox-teknik-spesifikasyon.md §3.68): `body`/`headers`
// ARTIK KOPYALANMAZ — `nox_http_response_new`nin TEK gerçek çağrı sitesi
// (`genHttpServeWrapper`) BUNLARI HER ZAMAN Nox'un KENDİ ARC-sahipli
// `HttpResponse.body`/`.headers` alanlarından geçirdiğinden, `retain`
// YETERLİDİR (bkz. `ServerRequest`in AYNI gerekçesi, HH.2).
const ServerResponse = struct {
    status: u16,
    body: ?[*:0]u8,
    headers: []const std.http.Header,
};

fn destroyResponse(rt: ?*anyopaque, gpa: std.mem.Allocator, resp: *ServerResponse) void {
    if (resp.body) |p| str_mod.nox_str_release(rt, p);
    for (resp.headers) |h| {
        str_mod.nox_str_release(rt, @ptrCast(@constCast(h.name.ptr)));
        str_mod.nox_str_release(rt, @ptrCast(@constCast(h.value.ptr)));
    }
    if (resp.headers.len > 0) gpa.free(resp.headers);
    gpa.destroy(resp);
}

/// `headers_dict`in HER isim/değerini `retain` edip (kopyalamadan)
/// `[]std.http.Header`e AKTARIR — `http_client.copyHeaders`nin (İSTEMCİ
/// kabuğunun arka plan iş parçacığına GEÇİŞ İÇİN KASITLI olarak BAĞIMSIZ
/// bir kopya çıkardığı, bkz. onun belge notu) AKSİNE, bu fonksiyon
/// YALNIZCA sunucu yolunda (`nox_http_response_new`), fiber'ın ÇALIŞTIĞI
/// AYNI OS iş parçacığında (ARC sahibi) çağrılır — cross-thread bir ARC
/// paylaşımı SÖZ KONUSU DEĞİLDİR, bu yüzden `copyHeaders`in KENDİSİ
/// DEĞİŞTİRİLMEDEN (istemci yolunu ETKİLEMEDEN) AYRI bir fonksiyon olarak
/// eklendi.
/// Güvenlik bulgusu M-1 (bkz. güvenlik raporu) — `http_client.
/// containsCrOrLf`nin AYNISI: `std.http`nin KENDİ başlık doğrulaması
/// yalnızca `assert`/`runtime_safety` İLE yapıldığından `ReleaseFast`te
/// TAMAMEN devre dışıydı — bir Nox `handle`in kullanıcı girdisini bir
/// yanıt başlığına yansıtması (ör. `HttpResponse(200, body, {"X-Echo":
/// query_param})`), ÜRETİM derlemesinde SESSİZCE CRLF enjekte edip yanıt
/// bölmesine (response splitting) yol açabiliyordu.
fn containsCrOrLf(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, '\r') != null or std.mem.indexOfScalar(u8, s, '\n') != null;
}

fn retainHeaders(rt: ?*anyopaque, gpa: std.mem.Allocator, headers_dict: ?*anyopaque) ![]std.http.Header {
    const d: *dict_mod.Dict = @ptrCast(@alignCast(headers_dict orelse return &.{}));
    if (d.entries.items.len == 0) return &.{};
    const out = try gpa.alloc(std.http.Header, d.entries.items.len);
    errdefer gpa.free(out);
    var filled: usize = 0;
    // Bir başlık CR/LF İÇERDİĞİNDEN dolayı REDDEDİLİRSE, o ANA KADAR ZATEN
    // `retain` edilmiş elemanların (bkz. `arc.nox_rc_retain`) refcount'unu
    // BURADA geri almak GEREKİR — aksi halde `out` `errdefer` İLE serbest
    // bırakılsa BİLE, İÇİNDEKİ str'lerin fazladan retain'i ASLA dengelenmez
    // (kalıcı bir sızıntı olurdu).
    errdefer for (out[0..filled]) |h| {
        str_mod.nox_str_release(rt, @ptrCast(@constCast(h.name.ptr)));
        str_mod.nox_str_release(rt, @ptrCast(@constCast(h.value.ptr)));
    };
    for (d.entries.items) |e| {
        const key_ptr: [*:0]u8 = @ptrFromInt(@as(usize, @bitCast(e.key)));
        const value_ptr: [*:0]u8 = @ptrFromInt(@as(usize, @bitCast(e.value)));
        const key = std.mem.span(key_ptr);
        const value = std.mem.span(value_ptr);
        if (containsCrOrLf(key) or containsCrOrLf(value)) return error.InvalidHeaderValue;
        arc.nox_rc_retain(key_ptr);
        arc.nox_rc_retain(value_ptr);
        out[filled] = .{ .name = key, .value = value };
        filled += 1;
    }
    return out;
}

/// Bir `handler`ın DÖNECEĞİ yanıt tutamacını inşa eder — Faz HH.3'ten beri
/// `body`/`headers` KOPYALANMAZ, `retain` edilir (bkz. modül üstü not).
export fn nox_http_response_new(rt: ?*anyopaque, status: i64, body: ?[*:0]const u8, headers: ?*anyopaque) callconv(.c) ?*anyopaque {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    const gpa = state.allocator();
    const resp = gpa.create(ServerResponse) catch return null;
    const body_ptr: ?[*:0]u8 = if (body) |b| @ptrCast(@constCast(b)) else null;
    if (body_ptr) |p| arc.nox_rc_retain(p);
    // Güvenlik M-1: bir başlık CR/LF İÇERİYORSA (bkz. `retainHeaders`in
    // belge notu) TÜM yanıt REDDEDİLİR (`null` döner) — `connectionEntry`
    // BUNU ZATEN, `gpa.create` OOM'uyla AYNI, GÜVENLE ele alınan "handler
    // null döndürdü" yoluyla (temiz bir 500 Internal Server Error'a
    // düşerek) karşılar (bkz. onun `if (resp_payload) |r| ... else ...`i)
    // — bozuk başlığı SESSİZCE ATLAMAK YERİNE.
    const hdrs = retainHeaders(rt, gpa, headers) catch {
        if (body_ptr) |p| str_mod.nox_str_release(rt, p);
        gpa.destroy(resp);
        return null;
    };
    resp.* = .{ .status = @intCast(status), .body = body_ptr, .headers = hdrs };
    return resp;
}

/// Faz HH.2: `connectionEntry` ZATEN `r.method`i ARC-sahipli olarak inşa
/// ETTİĞİNDEN, burada YENİDEN kopyalamaya GEREK YOK — yalnızca `retain`
/// edilip AYNI işaretçi döner (O(1), `memcpy` YOK). `connectionEntry`nin
/// KENDİ referansı (bkz. onun `defer`i) bu çağrıdan BAĞIMSIZ olarak HER
/// ZAMAN serbest bırakılır — standart retain/release disiplini, "transfer"
/// bookkeeping'i GEREKMEZ.
export fn nox_http_request_method(rt: ?*anyopaque, req: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    _ = rt;
    const r: *ServerRequest = @ptrCast(@alignCast(req orelse return null));
    if (r.method) |p| arc.nox_rc_retain(p);
    return r.method;
}

export fn nox_http_request_target(rt: ?*anyopaque, req: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    _ = rt;
    const r: *ServerRequest = @ptrCast(@alignCast(req orelse return null));
    if (r.target) |p| arc.nox_rc_retain(p);
    return r.target;
}

export fn nox_http_request_body(rt: ?*anyopaque, req: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    _ = rt;
    const r: *ServerRequest = @ptrCast(@alignCast(req orelse return null));
    if (r.body) |p| arc.nox_rc_retain(p);
    return r.body;
}

/// Faz HH.2: `r.headers`nin isim/değerleri ZATEN `connectionEntry`
/// TARAFINDAN ARC-sahipli olarak inşa edildi — burada YENİDEN `dupeToNoxStr`
/// İLE kopyalamak YERİNE `retain` edilip dict'e AYNEN eklenir (`nox_dict_set`
/// KENDİSİ retain YAPMAZ, çağıranın ZATEN retain ETTİĞİNİ VARSAYAR — bkz.
/// dict.zig'in modül üstü notu).
export fn nox_http_request_headers(rt: ?*anyopaque, req: ?*anyopaque) callconv(.c) ?*anyopaque {
    const r: *ServerRequest = @ptrCast(@alignCast(req orelse return null));
    const d = dict_mod.nox_dict_new(rt, 1) orelse return null;
    for (r.headers) |h| {
        const k: [*:0]u8 = @ptrCast(@constCast(h.name.ptr));
        const v: [*:0]u8 = @ptrCast(@constCast(h.value.ptr));
        arc.nox_rc_retain(k);
        arc.nox_rc_retain(v);
        dict_mod.nox_dict_set(rt, d, 1, 1, @bitCast(@intFromPtr(k)), @bitCast(@intFromPtr(v)));
    }
    return d;
}

/// Bir bağlantının TÜM ömrü — kabul edildikten SONRA `Fiber.create` ile bare
/// (Task SARMALAMADAN, bkz. modül üstü not) bir fiber olarak çalıştırılır:
/// fiber-native Reader/Writer inşa eder, `std.http.Server` üzerinden GERÇEK
/// bir istek alır, `conn.handler`ı (D.1.6'nın Nox sarmalayıcısı YA DA bu
/// dosyanın kendi testindeki elle yazılmış bir Zig işlevi) çağırıp yanıtı
/// yazar, bağlantıyı kapatır.
/// Faz HH.6 (bkz. nox-teknik-spesifikasyon.md §3.68): TEK bir bağlantının
/// sonsuza dek (okuma zaman aşımı HH.7'ye kadar YOK olduğundan) bir
/// fiber'ı MONOPOLİZE etmesini önleyen ek bir DoS sınırı — Q.5'in
/// `MAX_REQUEST_BODY_BYTES`/`DEFAULT_MAX_CONCURRENT_CONNECTIONS`iyle AYNI
/// ruhta, TAMAMLAYICI bir üst sınır.
const MAX_REQUESTS_PER_CONNECTION: usize = 1000;

fn connectionEntry(arg: *anyopaque) void {
    const conn: *ConnCtx = @ptrCast(@alignCast(arg));
    const gpa = conn.allocator;
    const rt = conn.rt;
    defer gpa.destroy(conn);
    defer _ = std.c.close(conn.fd);
    defer conn.active_connections.* -= 1;

    const scheduler = bridge.currentFiberScheduler();

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var fiber_reader = FiberReader.init(conn.fd, scheduler, &read_buf, conn.read_timeout_ms);
    var fiber_writer = FiberWriter.init(conn.fd, scheduler, &write_buf);

    // Faz HH.6: `std.http.Server` ZATEN "aynı bağlantıda birden çok
    // isteği" desteklemek İçin tasarlanmıştır (bkz. `Server.zig`nin modül
    // üstü notu) — TEK `receiveHead()` çağrısı YERİNE bir döngüye alınır.
    // HER turun `defer`leri (Zig'in blok-kapsamlı defer semantiği
    // sayesinde) O TURUN sonunda (bir SONRAKİ `receiveHead`den ÖNCE)
    // ateşlenir — ÖNCEKİ (tek-istekli) davranışla AYNI temizlik disiplini,
    // yalnızca TEKRARLANIR.
    var server: std.http.Server = .init(&fiber_reader.interface, &fiber_writer.interface);
    var requests_served: usize = 0;
    while (requests_served < MAX_REQUESTS_PER_CONNECTION) : (requests_served += 1) {
        var request = server.receiveHead() catch break;

        // Faz HH.2: ÖNCEDEN `gpa.dupe` (düz kopya) — `nox_http_request_*`
        // ÇAĞRILDIĞINDA `dupeToNoxStr` İKİNCİ bir ARC kopyası çıkarırdı.
        // ARTIK TEK kopya DOĞRUDAN burada, ARC-sahipli olarak inşa edilir;
        // `connectionEntry`nin KENDİ referansı `defer` İLE HER ZAMAN
        // serbest bırakılır (erişimciler `retain` eder, bu `defer`i
        // ETKİLEMEZ).
        const method_str = http_client.dupeToNoxStr(rt, @tagName(request.head.method)) orelse break;
        defer str_mod.nox_str_release(rt, method_str);
        const target_str = http_client.dupeToNoxStr(rt, request.head.target) orelse break;
        defer str_mod.nox_str_release(rt, target_str);

        var headers_list: std.ArrayListUnmanaged(std.http.Header) = .empty;
        defer {
            for (headers_list.items) |h| {
                str_mod.nox_str_release(rt, @ptrCast(@constCast(h.name.ptr)));
                str_mod.nox_str_release(rt, @ptrCast(@constCast(h.value.ptr)));
            }
            headers_list.deinit(gpa);
        }
        var it = request.iterateHeaders();
        while (it.next()) |h| {
            const name_copy = http_client.dupeToNoxStr(rt, h.name) orelse continue;
            const value_copy = http_client.dupeToNoxStr(rt, h.value) orelse {
                str_mod.nox_str_release(rt, name_copy);
                continue;
            };
            headers_list.append(gpa, .{ .name = std.mem.span(name_copy), .value = std.mem.span(value_copy) }) catch {
                str_mod.nox_str_release(rt, name_copy);
                str_mod.nox_str_release(rt, value_copy);
                continue;
            };
        }

        var transfer_buffer: [1024]u8 = undefined;
        const body_reader = request.readerExpectNone(&transfer_buffer);
        // Gövde HÂLÂ düz (ARC-DIŞI) bir `Writer.Allocating`e PARÇA PARÇA
        // okunur — soket okumaları ARC bloklarının aksine artımlı olarak
        // BÜYÜYEMEDİĞİNDEN bu ADIM KAÇINILMAZDIR. ARC'a geçiş, TÜM gövde
        // toplandıktan SONRA TEK bir `dupeToNoxStr` çağrısıyla (aşağıda)
        // olur — `nox_http_request_body`nin ARTIK YENİDEN kopyalamaması
        // İÇİN yeterli (ikinci kopya BURADA, TEK kopyaya indirgenir).
        var body_out: std.Io.Writer.Allocating = .init(gpa);
        defer body_out.deinit();
        // Faz Q.5: `streamRemaining` (SINIRSIZ) YERİNE `conn.max_body_bytes`e
        // kadar PARÇA PARÇA okunur — her `stream` çağrısı `FiberReader.stream`
        // aracılığıyla TEK bir soket okumasına denk geldiğinden (bkz. modül
        // üstü not), sınır AŞILDIĞI ANDA daha fazla veri OKUNMADAN durulur
        // (saldırganın gönderdiği KALAN baytlar HİÇ tüketilmez/tahsis edilmez).
        var body_too_large = false;
        while (true) {
            const n = body_reader.stream(&body_out.writer, .unlimited) catch |err| switch (err) {
                error.EndOfStream => break,
                else => break,
            };
            if (n == 0) break;
            if (body_out.written().len > conn.max_body_bytes) {
                request.respond("Payload Too Large", .{
                    .status = .payload_too_large,
                    .keep_alive = false,
                }) catch {};
                body_too_large = true;
                break;
            }
        }
        if (body_too_large) break;

        const body_str = http_client.dupeToNoxStr(rt, body_out.written()) orelse break;
        defer str_mod.nox_str_release(rt, body_str);

        var req_handle: ServerRequest = .{
            .method = method_str,
            .target = target_str,
            .body = body_str,
            .headers = headers_list.items,
        };

        const resp_payload = conn.handler(conn.handler_ctx, &req_handle);
        defer if (resp_payload) |r| destroyResponse(rt, gpa, @ptrCast(@alignCast(r)));

        if (resp_payload) |r| {
            const resp: *ServerResponse = @ptrCast(@alignCast(r));
            const body_slice: []const u8 = if (resp.body) |p| std.mem.span(p) else &.{};
            request.respond(body_slice, .{
                .status = @enumFromInt(resp.status),
                .keep_alive = true,
                .extra_headers = resp.headers,
            }) catch break;
        } else {
            request.respond("Internal Server Error", .{
                .status = .internal_server_error,
                .keep_alive = true,
            }) catch break;
        }

        // Faz HH.6 — DÜZELTME: ÖNCEDEN `server.reader.state != .ready`
        // kontrol ediliyordu, ama BU YANLIŞTI: `connectionEntry` gövdeyi
        // `respond()`DAN ÖNCE ELLE TÜKETTİĞİNDEN (bkz. yukarıdaki `body_
        // reader.stream` döngüsü — `MAX_REQUEST_BODY_BYTES` sınırını
        // PARÇA PARÇA denetleyebilmek İÇİN GEREKLİ), `reader`in İÇ durumu
        // `respond()` ÇAĞRILMADAN ÖNCE ZATEN `.received_head`in ÖTESİNE
        // (`.ready`e) GEÇMİŞ olur — `discardBody`nin "kapanıyor OLARAK
        // işaretle" dalı YALNIZCA `.received_head`DEN geçiş yaptığından
        // (bkz. Zig std'sinin `Server.zig`si), gövdeli (POST/PUT) istekler
        // İçin bu bayrak HİÇ tetiklenmez — `state` HER ZAMAN `.ready`
        // GÖRÜNÜR, İSTEMCİ `Connection: close` GÖNDERMİŞ OLSA BİLE (GERÇEK
        // bir SONSUZ askıda kalma İLE — `zig build test`nin gövdeli-istek
        // golden testlerinde — YAKALANDI). Bunun yerine İSTEMCİNİN
        // BEYAN ETTİĞİ tercih (`request.head.keep_alive`) DOĞRUDAN
        // kullanılır — `respond()`e HER ZAMAN `.keep_alive = true`
        // GEÇTİĞİMİZDEN, Zig'in KENDİ `server_keep_alive AND request.head.
        // keep_alive` formülü BUNA (`request.head.keep_alive`in KENDİSİNE)
        // İNDİRGENİR; bu, HTTP SÜRÜM varsayılanını (HTTP/1.0 vs 1.1) DA
        // ZATEN İÇERİR (bkz. `Request.Head.parse`).
        if (!request.head.keep_alive) break;
    }
}

/// Kabul döngüsü — `bridge.currentFiberScheduler()`e göre fiber-native
/// (`nonBlockingAccept`, bağlantı BAŞINA bare bir fiber SPAWN edilir, kabul
/// döngüsünün KENDİSİ hemen bir SONRAKİ bağlantıyı beklemeye döner) YA DA
/// senkron (fiber DIŞI — bağlantılar SIRAYLA, doğrudan `connectionEntry`
/// çağrılarak işlenir, eşzamanlılık YOK ama YİNE DE doğru çalışır) davranır.
/// `max_connections <= 0` İSE SINIRSIZ (gerçek bir sunucu programı İÇİN);
/// pozitifse TAM O SAYIDA bağlantı kabul edilince döner (bu dosyanın KENDİ
/// testinin deterministik olması İÇİN gerekli).
export fn nox_http_serve_raw(rt: ?*anyopaque, server: ?*anyopaque, handler: HandlerFn, handler_ctx: ?*anyopaque, max_connections: i64) callconv(.c) void {
    serveImpl(rt, server, handler, handler_ctx, max_connections, DEFAULT_MAX_CONCURRENT_CONNECTIONS, MAX_REQUEST_BODY_BYTES, READ_TIMEOUT_MS);
}

/// `nox_http_serve_raw`nin GERÇEK gövdesi — `max_concurrent`/`max_body_bytes`/
/// `read_timeout_ms` PARAMETRE olarak ALINIR (dışa açık C ABI'nin İMZASINI
/// DEĞİŞTİRMEDEN, bkz. `genHttpServe`'in `nox_http_serve_raw`ı SABİT
/// 5-argümanlı imzayla çağırması) — bu, `MAX_REQUEST_BODY_BYTES`/`DEFAULT_
/// MAX_CONCURRENT_CONNECTIONS`/`READ_TIMEOUT_MS` gibi GERÇEKÇİ (büyük)
/// varsayılanları BEKLEMEDEN, testlerin KÜÇÜK/HIZLI değerlerle sınırları
/// GERÇEKTEN EGZERSİZ edebilmesi İÇİNDİR (bkz. aşağıdaki testler).
fn serveImpl(rt: ?*anyopaque, server: ?*anyopaque, handler: HandlerFn, handler_ctx: ?*anyopaque, max_connections: i64, max_concurrent: usize, max_body_bytes: usize, read_timeout_ms: u32) void {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return));
    const h: *ServerHandle = @ptrCast(@alignCast(server orelse return));
    const gpa = state.allocator();

    // Faz Q.5: eşzamanlı bağlantı SAYACI — kabul döngüsü VE bağlantı
    // fiber'ları AYNI OS iş parçacığında (tek `Scheduler`, kooperatif
    // zamanlama) çalıştığından, GERÇEK paralel erişim ASLA olmaz — atomik
    // olmayan sıradan bir `usize` GÜVENLİDİR.
    var active_connections: usize = 0;

    var served: i64 = 0;
    while (max_connections <= 0 or served < max_connections) : (served += 1) {
        const scheduler = bridge.currentFiberScheduler();
        const conn_fd = if (scheduler) |s|
            io_mod.nonBlockingAccept(s, h.listen_fd) catch break
        else
            blockingAccept(h.listen_fd) catch break;

        // Faz Q.5: eşzamanlı bağlantı SINIRI — bir saldırganın `accept()`i
        // sınırsız tekrarlayıp HER biri İÇİN bir fiber+yığın tükettirmesini
        // ÖNLER. Bağlantı DAHA `receiveHead`i bile ÇAĞIRMADAN reddedilir
        // (fd sessizce kapatılır, hiçbir HTTP yanıtı YAZILMAZ — reddetmenin
        // KENDİSİNİN ek kaynak tüketmemesi İÇİN en ucuz tepki).
        if (active_connections >= max_concurrent) {
            _ = std.c.close(conn_fd);
            continue;
        }

        const conn = gpa.create(ConnCtx) catch {
            _ = std.c.close(conn_fd);
            continue;
        };
        conn.* = .{
            .allocator = gpa,
            .rt = rt,
            .fd = conn_fd,
            .handler = handler,
            .handler_ctx = handler_ctx,
            .max_body_bytes = max_body_bytes,
            .active_connections = &active_connections,
            .read_timeout_ms = read_timeout_ms,
        };
        // `connectionEntry`nin (fiber İÇİNDE YA DA senkron çağrıldığında
        // AYNI şekilde) `defer conn.active_connections.* -= 1`i bunu HER
        // ZAMAN dengeler — spawn/çağrı BAŞARISIZ OLURSA (aşağıdaki `catch`
        // dalları) `connectionEntry` HİÇ ÇALIŞMAZ, bu yüzden O durumlarda
        // sayaç ELLE geri alınır (bkz. aşağı).
        active_connections += 1;

        if (scheduler) |s| {
            // Dil stabilizasyonu fazı §M.4: ÖNCEDEN `Fiber.create` DOĞRUDAN
            // çağrılıyordu — bu HER ZAMAN taze bir 256 KiB yığın tahsis
            // eder, `Scheduler`in fiber-yığın HAVUZUNU (performans fazında
            // `async_task_churn` İÇİN inşa edilmişti) HİÇ KULLANMAZ. Bağlantı
            // fiber'ı TAMAMLANINCA `Scheduler.run()`ün MEVCUT temizleme yolu
            // (`destroyKeepStack`+`releaseStack`) yığını YİNE DE havuza GERİ
            // KOYARDI — yani havuz DOLAR ama HİÇ ÇEKİLMEZDİ, her YENİ
            // bağlantı YİNE DE taze bir tahsis öderdi (`spawn`ın KENDİSİNİN
            // ZATEN çözdüğü AYNI darboğaz, sunucu yolunda YENİDEN ortaya
            // çıkmış — bkz. `benchmarks/http_bench.zig`nin ÖNCESİ/SONRASI
            // ölçümü). Düzeltme: `spawn` İLE AYNI `acquireStack`+
            // `createWithStack` çifti.
            const stack = s.acquireStack() catch {
                active_connections -= 1;
                gpa.destroy(conn);
                _ = std.c.close(conn_fd);
                continue;
            };
            const fiber = fiber_mod.Fiber.createWithStack(gpa, connectionEntry, conn, stack) catch {
                active_connections -= 1;
                s.releaseStack(stack);
                gpa.destroy(conn);
                _ = std.c.close(conn_fd);
                continue;
            };
            // `scheduler_mod.spawn`ın KENDİ iç tarifiyle AYNI (bkz. modül
            // üstü not) — `Task` sarmalamadan `live_count`ı elle artırıyoruz,
            // `Scheduler.run()`ün MEVCUT temizleme yolu bunu dengeler.
            s.live_count += 1;
            s.markReady(fiber);
        } else {
            connectionEntry(conn);
        }
    }
}

// ---- Birim testleri ----------------------------------------------------
//
// **DİKKAT (bkz. `http_client.zig`nin "BLOKE OLMAZ" testinin belge notu VE
// nox-teknik-spesifikasyon.md §3.31'in "İKİNCİ, DAHA DERİN keşif"i):**
// `DebugAllocator`in yığın-izi yakalaması bir fiber'ın SIĞ, sahte-köklü
// çağrı zincirinin ÖTESİNE geçemez. Bu testin `handler` geri çağrısı
// KASITLI OLARAK HİÇBİR `gpa.alloc`/`free` YAPMAZ (yalnızca `page_allocator`
// ile günlük tutar VE sabit bir `nox_http_response_new` çağrısı yapar — BU
// çağrı `state.allocator()` ÜZERİNDEN tahsis YAPAR, ama `connectionEntry`
// (fiber'ın giriş noktasına `fiber.trampoline`den yalnızca 1 çerçeve
// UZAKTA) zaten KENDİSİ `gpa.dupe`/`ArrayList.append` ile TAHSİS yaptığından
// VE testler ZATEN yeşil ÇIKTIĞINDAN, bu senaryoda GERÇEK çağrı derinliği
// (DebugAllocator'ın KENDİ iç izleme çağrılarıyla BİRLİKTE) yeterli
// görünüyor — yine de bu KIRILGAN bir denge olduğundan, GELECEKTE bu testte
// bir "asılı kalma"/segfault gözlemlenirse ÖNCE bu notu OKUYUN.

fn testConnect(port: u16) !posix.fd_t {
    const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    var addr: std.c.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) != 0) {
        _ = std.c.close(fd);
        return error.ConnectFailed;
    }
    return fd;
}

fn testSendGet(fd: posix.fd_t, path: []const u8) void {
    var buf: [256]u8 = undefined;
    const req = std.fmt.bufPrint(&buf, "GET {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", .{path}) catch unreachable;
    var off: usize = 0;
    while (off < req.len) {
        const n = std.c.write(fd, req[off..].ptr, req.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
}

fn testReadAll(fd: posix.fd_t) void {
    var buf: [256]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) break;
    }
}

const TestHandlerLog = struct {
    var log: std.ArrayListUnmanaged([]const u8) = .empty;
    var rt_ptr: ?*anyopaque = null;

    fn handle(_: ?*anyopaque, req: ?*anyopaque) callconv(.c) ?*anyopaque {
        const r: *ServerRequest = @ptrCast(@alignCast(req.?));
        const target = std.mem.span(r.target.?);
        log.append(std.heap.page_allocator, if (std.mem.eql(u8, target, "/slow")) "slow tamamlandi" else "fast tamamlandi") catch unreachable;
        // Faz HH.3: `nox_http_response_new` ARTIK `body`nin GERÇEK bir ARC
        // `str` (8 baytlık görünmez başlığı OLAN) OLDUĞUNU varsayıp `retain`
        // eder — düz bir C literal'i DOĞRUDAN geçirmek (`retain`in literal'in
        // BAŞLIĞI OLMAYAN belleğine YAZMASINA yol AÇARDI) artık GÜVENSİZ;
        // önce `dupeToNoxStr` İLE gerçek bir ARC dizesi inşa edilir.
        const body = http_client.dupeToNoxStr(rt_ptr, "hi") orelse return null;
        defer str_mod.nox_str_release(rt_ptr, body);
        return nox_http_response_new(rt_ptr, 200, body, null);
    }
};

const ServeArgs = struct {
    rt: ?*anyopaque,
    server: ?*anyopaque,
    max_connections: i64,
    max_concurrent: usize = DEFAULT_MAX_CONCURRENT_CONNECTIONS,
    max_body_bytes: usize = MAX_REQUEST_BODY_BYTES,
    read_timeout_ms: u32 = READ_TIMEOUT_MS,
};

fn testServeEntry(arg: *anyopaque) callconv(.c) i64 {
    const args: *ServeArgs = @ptrCast(@alignCast(arg));
    serveImpl(args.rt, args.server, TestHandlerLog.handle, null, args.max_connections, args.max_concurrent, args.max_body_bytes, args.read_timeout_ms);
    return 0;
}

fn testSendPost(fd: posix.fd_t, path: []const u8, body: []const u8) void {
    var header_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "POST {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ path, body.len }) catch unreachable;
    var off: usize = 0;
    while (off < header.len) {
        const n = std.c.write(fd, header[off..].ptr, header.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
    off = 0;
    while (off < body.len) {
        const n = std.c.write(fd, body[off..].ptr, body.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

fn testReadResponse(fd: posix.fd_t, buf: []u8) usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.c.read(fd, buf[total..].ptr, buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    return total;
}

test "nox_http_serve_raw: GERÇEK bir TCP bağlantısı kabul edip std.http.Server üzerinden GERÇEK bir istek/yanıt tamamlar" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const server = nox_http_server_listen(rt, 0) orelse return error.ListenFailed;
    defer nox_http_server_close(rt, server);
    const port: u16 = @intCast(nox_http_server_port(server));

    TestHandlerLog.log.clearRetainingCapacity();
    TestHandlerLog.rt_ptr = rt;

    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: u16) void {
            const fd = testConnect(p) catch return;
            defer _ = std.c.close(fd);
            testSendGet(fd, "/hello");
            testReadAll(fd);
        }
    }.run, .{port});
    defer client_thread.join();

    var args: ServeArgs = .{ .rt = rt, .server = server, .max_connections = 1 };
    _ = testServeEntry(&args);

    try std.testing.expectEqual(@as(usize, 1), TestHandlerLog.log.items.len);
    try std.testing.expectEqualStrings("fast tamamlandi", TestHandlerLog.log.items[0]);
}

test "nox_http_serve_raw: bir fiber İÇİNDEN çalıştırıldığında eşzamanlı İKİ bağlantı GERÇEKTEN çakışır (yavaş bağlantı hızlıyı BLOKE ETMEZ)" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    bridge.nox_async_init(rt);
    defer bridge.nox_async_deinit(rt);

    const server = nox_http_server_listen(rt, 0) orelse return error.ListenFailed;
    defer nox_http_server_close(rt, server);
    const port: u16 = @intCast(nox_http_server_port(server));

    TestHandlerLog.log.clearRetainingCapacity();
    TestHandlerLog.rt_ptr = rt;

    // "slow" istemci: bağlanır ama isteği GÖNDERMEDEN ÖNCE kısa bir süre
    // bekler — sunucunun bu bağlantı İÇİN `receiveHead`i (dolayısıyla
    // `FiberReader.stream`i) EAGAIN alıp `suspendForIo`ya düşmesini
    // ZORLAR (D.0'ın `nonBlockingRead` testiyle AYNI "sıra kanıtı" deseni).
    const slow_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: u16) void {
            const fd = testConnect(p) catch return;
            defer _ = std.c.close(fd);
            const req_ts: posix.timespec = .{ .sec = 0, .nsec = 150 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&req_ts, null);
            testSendGet(fd, "/slow");
            testReadAll(fd);
        }
    }.run, .{port});
    defer slow_thread.join();

    const fast_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: u16) void {
            const fd = testConnect(p) catch return;
            defer _ = std.c.close(fd);
            testSendGet(fd, "/fast");
            testReadAll(fd);
        }
    }.run, .{port});
    defer fast_thread.join();

    var args: ServeArgs = .{ .rt = rt, .server = server, .max_connections = 2 };
    const serve_task = bridge.nox_async_spawn(rt, testServeEntry, &args).?;
    try std.testing.expectEqual(@as(i32, 0), bridge.nox_async_run_to_completion(rt));
    _ = bridge.nox_async_await(rt, serve_task);
    bridge.nox_async_destroy_task(rt, serve_task);

    // Sıra KANITI: "slow" bağlantı GÖNDERMEDEN önce beklerken, sunucu
    // BLOKE OLMADAN "fast" bağlantıyı ÖNCE tamamlayabildi.
    try std.testing.expectEqual(@as(usize, 2), TestHandlerLog.log.items.len);
    try std.testing.expectEqualStrings("fast tamamlandi", TestHandlerLog.log.items[0]);
    try std.testing.expectEqualStrings("slow tamamlandi", TestHandlerLog.log.items[1]);
}

/// Faz DD.1 (bkz. nox-teknik-spesifikasyon.md §3.60) — çok-çekirdekli
/// sunumun ÇEKİRDEK varsayımını, derleyiciden TAMAMEN İZOLE doğrular:
/// TEK bir paylaşılan `listen_fd` üzerinde İKİ BAĞIMSIZ OS iş parçacığı
/// (HER BİRİ KENDİ `RuntimeState`i VE KENDİ `ServerHandle`ı — `nox_http_
/// server_from_fd` İLE, `owns_fd = false`) senkron (bloklayıcı,
/// `serveImpl`nin `scheduler == null` dalı) `accept()` çağırdığında,
/// GERÇEKTEN ikisi de kendi bağlantısını ALIR — çökme/veri bozulması
/// OLMADAN. `nox_http_server_close`in HİÇBİRİ paylaşılan fd'yi kapatmaz
/// (`owns_fd = false`), bu yüzden HER İKİ İŞ PARÇACIĞI da SORUNSUZ
/// tamamlanabilir.
const ThreadSafeCounter = struct {
    var served: std.atomic.Value(u32) = .init(0);

    // `ctx`, `serveImpl`nin `handler_ctx` olarak GEÇİRDİĞİ, ÇAĞIRAN iş
    // parçacığının KENDİ `rt`sidir (bkz. `sharedFdServeEntry`) — İKİ
    // BAĞIMSIZ iş parçacığı ARASINDA PAYLAŞILAN TEK bir `rt_ptr`
    // KULLANILMASI (ÖNCEKİ, HATALI tasarım) bir iş parçacığının YANIT
    // nesnesini DİĞERİNİN allocator'ıyla oluşturmasına, dolayısıyla
    // `destroyResponse`nin YANLIŞ (çapraz-iş-parçacığı) bir allocator ile
    // serbest bırakmaya ÇALIŞMASINA yol açan GERÇEK bir hataydı
    // (DebugAllocator'ın "bucket eşleşmiyor" doğrulamasıyla YAKALANDI).
    fn handle(ctx: ?*anyopaque, req: ?*anyopaque) callconv(.c) ?*anyopaque {
        _ = req;
        _ = served.fetchAdd(1, .monotonic);
        // Faz HH.3: bkz. `TestHandlerLog.handle`nin AYNI notu — `ctx`
        // ÇAĞIRAN iş parçacığının KENDİ `rt`si OLDUĞUNDAN (bkz. modül üstü
        // not) burada ARC tahsisi yapmak GÜVENLİDİR (aynı iş parçacığı).
        const body = http_client.dupeToNoxStr(ctx, "ok") orelse return null;
        defer str_mod.nox_str_release(ctx, body);
        return nox_http_response_new(ctx, 200, body, null);
    }
};

fn sharedFdServeEntry(args: *ServeArgs) void {
    serveImpl(args.rt, args.server, ThreadSafeCounter.handle, args.rt, args.max_connections, args.max_concurrent, args.max_body_bytes, args.read_timeout_ms);
}

// Faz DD.1 — `owns_fd`in KENDİSİNİ (bkz. `ServerHandle`in belge notu),
// zamanlama/yarışa BAĞIMLI OLMAYAN, DETERMİNİSTİK bir şekilde doğrular:
// `nox_http_server_from_fd` İLE SARILAN bir `ServerHandle` (`owns_fd =
// false`) üzerinde `nox_http_server_close` çağrıldıktan SONRA, ALTTAKİ
// paylaşılan fd HÂLÂ GEÇERLİ olmalıdır (`fcntl(fd, F_GETFD)` başarılı) —
// `nox_http_server_listen` İLE YARATILAN (`owns_fd = true`) bir handle
// İSE AKSİNE fd'yi GERÇEKTEN kapatmalıdır.
test "Faz DD.1: nox_http_server_close — owns_fd=false PAYLAŞILAN fd'yi KAPATMAZ, owns_fd=true KENDİ fd'sini kapatır" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const shared_fd = bindAndListen(0) orelse return error.ListenFailed;
    defer _ = std.c.close(shared_fd);

    const wrapped = nox_http_server_from_fd(rt, @intCast(shared_fd)) orelse return error.WrapFailed;
    nox_http_server_close(rt, wrapped);
    // `owns_fd = false`: `shared_fd` HÂLÂ geçerli bir dosya tanımlayıcısı
    // OLMALI — `fcntl(F_GETFD)` yalnızca fd AÇIKKEN başarılı döner.
    try std.testing.expect(std.c.fcntl(shared_fd, std.c.F.GETFD) >= 0);

    const owned = nox_http_server_listen(rt, 0) orelse return error.ListenFailed;
    const owned_h: *ServerHandle = @ptrCast(@alignCast(owned));
    const owned_fd = owned_h.listen_fd;
    nox_http_server_close(rt, owned);
    // `owns_fd = true`: `owned_fd` GERÇEKTEN kapatılmış OLMALI —
    // `fcntl(F_GETFD)` `EBADF` İLE başarısız olur.
    try std.testing.expect(std.c.fcntl(owned_fd, std.c.F.GETFD) < 0);
}

test "Faz DD.1: PAYLAŞILAN bir listen_fd üzerinde İKİ BAĞIMSIZ iş parçacığı/ServerHandle GERÇEKTEN kendi bağlantısını kabul eder" {
    const fd = bindAndListen(0) orelse return error.ListenFailed;
    defer _ = std.c.close(fd);
    var addr: std.c.sockaddr.in = undefined;
    var len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
    _ = std.c.getsockname(fd, @ptrCast(&addr), &len);
    const port: u16 = std.mem.bigToNative(u16, addr.port);

    const rt1 = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt1);
    const rt2 = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt2);

    // `owns_fd = false` — HİÇBİRİ paylaşılan `fd`yi kapatmaz (bkz.
    // `nox_http_server_close`in belge notu); `defer`ler bu yüzden HER
    // ZAMAN güvenlidir, sıraları ÖNEMSİZDİR.
    const server1 = nox_http_server_from_fd(rt1, @intCast(fd)) orelse return error.WrapFailed;
    defer nox_http_server_close(rt1, server1);
    const server2 = nox_http_server_from_fd(rt2, @intCast(fd)) orelse return error.WrapFailed;
    defer nox_http_server_close(rt2, server2);

    ThreadSafeCounter.served.store(0, .monotonic);

    var args1: ServeArgs = .{ .rt = rt1, .server = server1, .max_connections = 1 };
    var args2: ServeArgs = .{ .rt = rt2, .server = server2, .max_connections = 1 };
    const server_thread1 = try std.Thread.spawn(.{}, sharedFdServeEntry, .{&args1});
    const server_thread2 = try std.Thread.spawn(.{}, sharedFdServeEntry, .{&args2});

    const client_thread1 = try std.Thread.spawn(.{}, struct {
        fn run(p: u16) void {
            const fd_c = testConnect(p) catch return;
            defer _ = std.c.close(fd_c);
            testSendGet(fd_c, "/a");
            testReadAll(fd_c);
        }
    }.run, .{port});
    const client_thread2 = try std.Thread.spawn(.{}, struct {
        fn run(p: u16) void {
            const fd_c = testConnect(p) catch return;
            defer _ = std.c.close(fd_c);
            testSendGet(fd_c, "/b");
            testReadAll(fd_c);
        }
    }.run, .{port});

    client_thread1.join();
    client_thread2.join();
    server_thread1.join();
    server_thread2.join();

    // İKİ bağlantı da GERÇEKTEN sunuldu — paylaşılan fd'nin İKİ bağımsız
    // kqueue/epoll örneği tarafından SORUNSUZ izlenebildiğinin KANITI.
    try std.testing.expectEqual(@as(u32, 2), ThreadSafeCounter.served.load(.monotonic));
}

test "Faz Q.5: govde boyutu siniri asilirsa 413 Payload Too Large doner, handler HIC CAGRILMAZ" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const server = nox_http_server_listen(rt, 0) orelse return error.ListenFailed;
    defer nox_http_server_close(rt, server);
    const port: u16 = @intCast(nox_http_server_port(server));

    TestHandlerLog.log.clearRetainingCapacity();
    TestHandlerLog.rt_ptr = rt;

    var resp_buf: [256]u8 = undefined;
    var resp_len: usize = 0;

    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: u16, out: []u8, out_len: *usize) void {
            const fd = testConnect(p) catch return;
            defer _ = std.c.close(fd);
            // 27 bayt gövde — aşağıdaki KASITLI KÜÇÜK 16 baytlık test
            // sınırının (gerçek varsayılan 10 MiB'ı BEKLEMEDEN testin HIZLI/
            // deterministik olması İÇİN) ÜZERİNDE.
            testSendPost(fd, "/upload", "0123456789ABCDEF0123456789");
            out_len.* = testReadResponse(fd, out);
        }
    }.run, .{ port, &resp_buf, &resp_len });

    serveImpl(rt, server, TestHandlerLog.handle, null, 1, DEFAULT_MAX_CONCURRENT_CONNECTIONS, 16, READ_TIMEOUT_MS);
    client_thread.join();

    try std.testing.expectEqual(@as(usize, 0), TestHandlerLog.log.items.len);
    try std.testing.expect(std.mem.indexOf(u8, resp_buf[0..resp_len], "413") != null);
}

test "Faz Q.5: esizamanli baglanti siniri asilinca fazla baglanti hicbir HTTP yaniti almadan reddedilir" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    bridge.nox_async_init(rt);
    defer bridge.nox_async_deinit(rt);

    const server = nox_http_server_listen(rt, 0) orelse return error.ListenFailed;
    defer nox_http_server_close(rt, server);
    const port: u16 = @intCast(nox_http_server_port(server));

    TestHandlerLog.log.clearRetainingCapacity();
    TestHandlerLog.rt_ptr = rt;

    // "slow" istemci: bağlanır, isteği GÖNDERMEDEN önce 150ms bekler — bu
    // sürede bağlantısı "aktif" sayılıp `max_concurrent = 1` sınırını
    // DOLDURUR (D.0'ın "sıra kanıtı" testleriyle AYNI teknik).
    const slow_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: u16) void {
            const fd = testConnect(p) catch return;
            defer _ = std.c.close(fd);
            const ts: posix.timespec = .{ .sec = 0, .nsec = 150 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
            testSendGet(fd, "/slow");
            testReadAll(fd);
        }
    }.run, .{port});

    // Sunucunun "slow" bağlantıyı kabul edip sayacı 1'e çıkarmasını beklemek
    // İÇİN kısa bir emniyet payı (kabul döngüsü mikrosaniyeler içinde tepki
    // verir — 30ms fazlasıyla yeterli).
    const settle_ts: posix.timespec = .{ .sec = 0, .nsec = 30 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&settle_ts, null);

    // "fast" istemci: `max_concurrent = 1` ZATEN DOLU olduğundan reddedilmesi
    // BEKLENİR — bağlantı HİÇBİR HTTP yanıtı ALMADAN (sıfır bayt okuyarak,
    // sunucu fd'yi sessizce kapattığı İÇİN) kapanmalı.
    var fast_rejected: bool = false;
    const fast_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: u16, rejected: *bool) void {
            const fd = testConnect(p) catch return;
            defer _ = std.c.close(fd);
            var buf: [16]u8 = undefined;
            const n = std.c.read(fd, &buf, buf.len);
            rejected.* = (n <= 0);
        }
    }.run, .{ port, &fast_rejected });

    var args: ServeArgs = .{ .rt = rt, .server = server, .max_connections = 2, .max_concurrent = 1 };
    const serve_task = bridge.nox_async_spawn(rt, testServeEntry, &args).?;
    try std.testing.expectEqual(@as(i32, 0), bridge.nox_async_run_to_completion(rt));
    _ = bridge.nox_async_await(rt, serve_task);
    bridge.nox_async_destroy_task(rt, serve_task);

    slow_thread.join();
    fast_thread.join();
    try std.testing.expect(fast_rejected);
    // Yalnızca "slow" GERÇEKTEN işlendi (handler ÇAĞRILDI) — "fast" daha
    // `receiveHead`e bile ULAŞAMADAN reddedildi.
    try std.testing.expectEqual(@as(usize, 1), TestHandlerLog.log.items.len);
    try std.testing.expectEqualStrings("slow tamamlandi", TestHandlerLog.log.items[0]);
}

// Faz HH.7 (bkz. nox-teknik-spesifikasyon.md §3.68): okuma zaman aşımı —
// GERÇEK (30 saniyelik) varsayılanı BEKLEMEDEN test edebilmek İçin
// `ServeArgs.read_timeout_ms` (bkz. onun belge notu, `max_body_bytes`
// testinin AYNI "küçük/hızlı değer" gerekçesi) KISA bir değere (100ms)
// ayarlanır.

test "Faz HH.7: baglanti HICBIR sey gondermezse okuma zaman asimiyla sessizce kapatilir, handler HIC CAGRILMAZ" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    bridge.nox_async_init(rt);
    defer bridge.nox_async_deinit(rt);

    const server = nox_http_server_listen(rt, 0) orelse return error.ListenFailed;
    defer nox_http_server_close(rt, server);
    const port: u16 = @intCast(nox_http_server_port(server));

    TestHandlerLog.log.clearRetainingCapacity();
    TestHandlerLog.rt_ptr = rt;

    // İstemci bağlanır, HİÇBİR ŞEY GÖNDERMEZ — sunucunun `receiveHead`i
    // (dolayısıyla `FiberReader.stream`i) EAGAIN alıp `suspendForIoOrTimeout`a
    // düşmesini ZORLAR (D.0'ın "sıra kanıtı" testleriyle AYNI teknik) —
    // KISA zaman aşımı (100ms) GERÇEKTEN ateşlemek ZORUNDADIR.
    var timed_out: bool = false;
    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: u16, out: *bool) void {
            const fd = testConnect(p) catch return;
            defer _ = std.c.close(fd);
            var buf: [16]u8 = undefined;
            const n = std.c.read(fd, &buf, buf.len);
            out.* = (n <= 0);
        }
    }.run, .{ port, &timed_out });

    var args: ServeArgs = .{ .rt = rt, .server = server, .max_connections = 1, .read_timeout_ms = 100 };
    const serve_task = bridge.nox_async_spawn(rt, testServeEntry, &args).?;
    try std.testing.expectEqual(@as(i32, 0), bridge.nox_async_run_to_completion(rt));
    _ = bridge.nox_async_await(rt, serve_task);
    bridge.nox_async_destroy_task(rt, serve_task);

    client_thread.join();
    // Bağlantı HİÇBİR HTTP yanıtı ALMADAN (sıfır bayt okuyarak) kapanmalı
    // — reddetmenin KENDİSİ ek kaynak tüketmemeli (bkz. Q.5'in AYNI ilkesi).
    try std.testing.expect(timed_out);
    try std.testing.expectEqual(@as(usize, 0), TestHandlerLog.log.items.len);
}

test "Faz HH.7: zaman asimi ICINDE tamamlanan normal bir istek YANLIS-POZITIF olmadan islenir" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    bridge.nox_async_init(rt);
    defer bridge.nox_async_deinit(rt);

    const server = nox_http_server_listen(rt, 0) orelse return error.ListenFailed;
    defer nox_http_server_close(rt, server);
    const port: u16 = @intCast(nox_http_server_port(server));

    TestHandlerLog.log.clearRetainingCapacity();
    TestHandlerLog.rt_ptr = rt;

    // İstemci bağlanır, KISA bir gecikmeyle (zaman aşımının İÇİNDE, 100ms
    // sınırın YARISI kadar) isteği gönderir — bu, YANLIŞ-POZİTİF (normal,
    // biraz gecikmeli trafiğin de zaman aşımına UĞRAMASI) OLMADIĞININ kanıtı.
    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: u16) void {
            const fd = testConnect(p) catch return;
            defer _ = std.c.close(fd);
            const ts: posix.timespec = .{ .sec = 0, .nsec = 40 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
            testSendGet(fd, "/normal");
            testReadAll(fd);
        }
    }.run, .{port});

    var args: ServeArgs = .{ .rt = rt, .server = server, .max_connections = 1, .read_timeout_ms = 100 };
    const serve_task = bridge.nox_async_spawn(rt, testServeEntry, &args).?;
    try std.testing.expectEqual(@as(i32, 0), bridge.nox_async_run_to_completion(rt));
    _ = bridge.nox_async_await(rt, serve_task);
    bridge.nox_async_destroy_task(rt, serve_task);

    client_thread.join();
    try std.testing.expectEqual(@as(usize, 1), TestHandlerLog.log.items.len);
    try std.testing.expectEqualStrings("fast tamamlandi", TestHandlerLog.log.items[0]);
}

// Güvenlik bulgusu M-1 (bkz. güvenlik raporu, 20 Temmuz 2026) — DÜZELTİLDİ:
// `retainHeaders`/`nox_http_response_new` ÖNCEDEN CR/LF baytlarını HİÇ
// DENETLEMİYORDU. Bu testler `assert`e DEĞİL GERÇEK bir `if` kontrolüne
// dayandığından HER build modunda (`ReleaseFast` DAHİL) geçerlidir.
test "Güvenlik M-1: nox_http_response_new CR/LF İÇEREN bir başlık DEĞERİNDE null döner (500'e düşer)" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const d = dict_mod.nox_dict_new(rt, 1) orelse return error.NewFailed;
    defer dict_mod.nox_dict_release(rt, d, 1, 1);
    const key = str_mod.nox_str_concat(rt, "X-Ec", "ho") orelse return error.ConcatFailed;
    const value = str_mod.nox_str_concat(rt, "zararli\r\nSet-Cookie: pwned=", "1") orelse return error.ConcatFailed;
    dict_mod.nox_dict_set(rt, d, 1, 1, @bitCast(@intFromPtr(key)), @bitCast(@intFromPtr(value)));

    const resp = nox_http_response_new(rt, 200, null, d);
    try std.testing.expect(resp == null);
}

test "Güvenlik M-1: nox_http_response_new normal (CR/LF'siz) başlıklarda HÂLÂ doğru çalışır (yanlış-pozitif YOK)" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const d = dict_mod.nox_dict_new(rt, 1) orelse return error.NewFailed;
    defer dict_mod.nox_dict_release(rt, d, 1, 1);
    const key = str_mod.nox_str_concat(rt, "X-Norm", "al") orelse return error.ConcatFailed;
    const value = str_mod.nox_str_concat(rt, "deger", "1") orelse return error.ConcatFailed;
    dict_mod.nox_dict_set(rt, d, 1, 1, @bitCast(@intFromPtr(key)), @bitCast(@intFromPtr(value)));

    const resp = nox_http_response_new(rt, 200, null, d) orelse return error.UnexpectedNull;
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt));
    defer destroyResponse(rt, state.allocator(), @ptrCast(@alignCast(resp)));
    const r: *ServerResponse = @ptrCast(@alignCast(resp));
    try std.testing.expectEqual(@as(usize, 1), r.headers.len);
    try std.testing.expectEqualStrings("X-Normal", r.headers[0].name);
    try std.testing.expectEqualStrings("deger1", r.headers[0].value);
}
