//! `nox.http` istemci Zig kabuğu — stdlib fazı §D.1.3 (bkz. nox-teknik-
//! spesifikasyon.md). `std.http.Client`ı DOĞAL (bloklayan) haliyle
//! kullanır (D.0'ın kqueue reaktörüne uyarlamak, `std.http.Client`in
//! KENDİ `std.Io` soyutlamasını TAMAMEN yeniden uygulamayı gerektirirdi —
//! bkz. plan dosyasının "Keşif 2"si), ama HER isteği GERÇEK bir arka plan
//! OS iş parçacığında (`std.Thread.spawn`) çalıştırır. ÇAĞIRAN taraf bir
//! "tamamlanma pipe'ı" (self-pipe tekniği) üzerinden bekler:
//!   - bir Nox FIBER İÇİNDEYSEK (bkz. `bridge.currentFiberScheduler`),
//!     D.0'ın `nonBlockingRead`i ile askıya alınır — BAŞKA fiber'lar bu
//!     sırada GERÇEKTEN ilerleyebilir (thread-per-request eşzamanlılık).
//!   - fiber DIŞINDAYSAK (ör. `async` hiç kullanmayan senkron bir Nox
//!     betiği — bu durumda zamanlayıcı hiç İLKLENMEMİŞTİR), sıradan
//!     bloklayan bir `read()` yeterlidir (korunacak BAŞKA bir fiber YOK).
//!
//! **v1 bilinçli sınırlaması:** `std.http.Client.fetch`in kolaylık
//! sarmalayıcısı YERİNE düşük seviye `client.request`/`receiveHead` API'si
//! kullanılır (kullanıcının "yanıt başlıkları da dahil edilsin" kararı
//! İÇİN gerekli — `fetch()`in dönüşü yalnızca `status` taşır, header'lara
//! ERİŞEMEZ). Bunun bedeli: OTOMATİK yönlendirme (redirect) takibi YOK —
//! `redirect_behavior = .unhandled` (bir 3xx durumu OLDUĞU GİBİ status+body
//! olarak döner, TAKİP EDİLMEZ).
//!
//! **gzip/deflate çözme (bkz. `workerThreadFn`):** `std.http.Client`in
//! VARSAYILAN `accept_encoding`i (bkz. Zig std `Client.Options.default_
//! accept_encoding`) sunucudan zaten gzip/deflate SIKIŞTIRMA istiyor — bu
//! yüzden gövde `Response.readerDecompressing` İLE `Content-Encoding`e göre
//! ÇÖZÜLEREK okunur (düz `Response.reader`, GERÇEK DÜNYADA -- Cloudflare/
//! GitHub/Google DAHİL -- neredeyse HER sunucuda HAM/sıkıştırılmış bayt
//! döndürür). Gövde ikili de olabilir: `str` uzunluğu başlıkta tutar, gömülü `\0`
//! ve geçersiz UTF-8 aynen kopyalanır (v2.0.31 öncesi böyle bir gövde isteği
//! başarısız sayıyordu).
//!
//! **Zaman aşımı (v2.0.31):** `nox_http_request_raw`ın `timeout_ms > 0` değeri için bir
//! bekçi iş parçacığı süre dolunca açık soketi `shutdown` eder (bkz. `Shared`). DNS çözümleme
//! ve TCP bağlantı aşaması `std.http.Client` içinde olduğundan bu aşama bekçiyle iptal edilemez
//! (işletim sisteminin kendi bağlantı süresiyle sınırlıdır); bağlantı kurulduktan sonraki
//! gönderme, başlık ve gövde okuma süresi sınırlıdır.
//!
//! **BİLİNÇLİ kapsam dışı (ziglang/zig#19521):** bu dosya `std.http.Client`ı
//! (dolayısıyla Zig'in KENDİ, orijinal `std.crypto.tls.Client`ını, `nox.tls`/
//! `nox.smtp`/`nox.websocket`nin AKSİNE) DOĞRUDAN kullanır — `runtime/
//! vendor/tls_client.zig`nin `certificate_request` düzeltmesi BURAYA
//! UYGULANMADI. Yani teorik olarak, istemci sertifikası İSTEYEN (mTLS) NADİR
//! bir HTTPS sunucusuna karşı `https://` istekleri YİNE `TlsUnexpectedMessage`
//! İLE başarısız olabilir (sıradan HTTPS sunucuları — google.com/example.com
//! DAHİL — ETKİLENMEZ). Düzeltme BİLİNÇLİ olarak buraya UYGULANMADI: `std.
//! http.Client`ın TAMAMINI forklamayı gerektirir, fayda/risk oranı düşük.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const asap = @import("../alloc/asap.zig");
const arc = @import("../alloc/arc.zig");
const dict_mod = @import("../collections/dict.zig");
const bridge = @import("../async_rt/bridge.zig");
const io_mod = @import("../async_rt/io.zig");
const str_mod = @import("../str.zig");
/// Faz F.0.6 (bkz. plan dosyası "gizli http_client.zig bağımlılığının
/// KESİLMESİ"): `makeSelfPipe`/`closeFd`/`signalSelfPipe`/`readSelfPipe`
/// ÖNCEDEN BURADA tanımlıydı — `async_rt/thread_channel.zig`/`thread_
/// bridge.zig`/`pool_bridge.zig` (ÇEKİRDEK `async_rt` dosyaları) SADECE
/// bunları ödünç almak İçİn BU dosyayı (dolayısıyla `std.http.Client`ı)
/// İTHAL ETMEK ZORUNDA kalıyordu — `runtime/async_rt/completion_pipe.
/// zig`ye TAŞINDI, BURADA aşağıdaki dört satır İLE (`thread_channel.zig`
/// nin KENDİ, ZATEN kanıtlanmış `dupeToNoxStr` re-export deseninin AYNISI,
/// TERS yönde) re-export EDİLİR — davranış SIFIR değişmez.
const completion_pipe = @import("../async_rt/completion_pipe.zig");
pub const makeSelfPipe = completion_pipe.makeSelfPipe;
pub const closeFd = completion_pipe.closeFd;
pub const signalSelfPipe = completion_pipe.signalSelfPipe;
pub const readSelfPipe = completion_pipe.readSelfPipe;

/// `testServeOnceDelayed`nin kasıtlı gecikmesi İçin — `time.zig`nin
/// `WinTime.Sleep`iYLE AYNI desen (`std.c.clockid_t`nin void OLMASI
/// yüzünden `nanosleep` Windows'ta kullanılamaz, bkz. o dosyanın belge
/// notu), KÜÇÜK platform yardımcılarının dosya-başına TEKRARLANMASI
/// projenin YERLEŞİK kuralıyla (bkz. `crypto.zig`/`dict.zig`nin
/// `secureRandomBuf`ı) TUTARLI.
const WinSleep = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn Sleep(ms: u32) callconv(.c) void;
} else struct {};
fn winSleep(ms: u32) void {
    if (builtin.os.tag == .windows) WinSleep.Sleep(ms);
}

/// TÜM istekler ARASINDA PAYLAŞILAN, TEMBEL ilklenen TEK bir `std.Io.Threaded`
/// — `std.Io.Threaded.init` süreç-GENELİ bir `SIGIO`/`SIGPIPE` sinyal
/// işleyicisi KURDUĞUNDAN (bkz. Zig std kaynağı, `Threaded.init`: `posix.
/// sigaction(.IO, &act, &t.old_sig_io)` — ÖNCEKİ işleyiciyi `t.old_sig_io`ya
/// KAYDEDER), HER istek İÇİN (`workerThreadFn` içinde) AYRI bir örnek
/// oluşturmak SÜREÇ-GENELİ bu işleyiciyi TEKRAR TEKRAR üzerine yazar/geri
/// yükler — bu, `zig build test`in `--listen=-` modunda (test çalıştırıcının
/// KENDİSİ, `build/protokol` G/Ç'si İÇİN `Io.Threaded.global_single_threaded`
/// adında AYNI türden SÜREÇ-GENELİ bir örnek KULLANIR, bkz. `test_runner.zig`)
/// ölçülebilir bir çakışmaya/veri yarışına yol açtığı GERÇEK bir hatayla
/// (nadir, zamanlamaya bağlı bir SIGSEGV) KEŞFEDİLDİ — bkz. nox-teknik-
/// spesifikasyon.md §3.31. Çözüm: test çalıştırıcının KENDİ deseniyle AYNI
/// ("bir kez ilklen, HİÇBİR ZAMAN deinit ETME, süreç bitince OS geri alır" —
/// `asap.zig`'in Release modu ARC havuzuyla AYNI felsefe) TEK, paylaşılan bir
/// örnek kullanmak.
const ClientIoState = enum(u8) { uninit, initializing, ready };
var g_client_io_state: std.atomic.Value(ClientIoState) = .init(.uninit);
var g_client_io_storage: std.Io.Threaded = undefined;

pub fn sharedClientIo() std.Io {
    if (g_client_io_state.cmpxchgStrong(.uninit, .initializing, .acquire, .monotonic) == null) {
        // `async_limit`/`concurrent_limit` BİLİNÇLİ olarak `.nothing` —
        // `std.http.Client`in KENDİSİ `io.async`/`io.concurrent` üzerinden
        // AYRICA arka plan iş parçacıkları BAŞLATMASIN diye (bu dosyanın
        // KENDİ arka plan iş parçacığı — `workerThreadFn` — ZATEN yeterli
        // eşzamanlılığı sağlıyor; `Threaded`in KENDİ havuzuna GEREK YOK,
        // gereksiz iş parçacığı oluşturmayı ÖNLER).
        g_client_io_storage = std.Io.Threaded.init(std.heap.page_allocator, .{
            .async_limit = .nothing,
            .concurrent_limit = .nothing,
        });
        g_client_io_state.store(.ready, .release);
    } else {
        while (g_client_io_state.load(.acquire) != .ready) std.Thread.yield() catch {};
    }
    return g_client_io_storage.io();
}

/// İstek zaman aşımı için, arka plan iş parçacığı (`workerThreadFn`) ile bekçi iş parçacığı (`watchdogThreadFn`)
/// arasında paylaşılan küçük durum. `page_allocator` ile ayrılır (rt'den bağımsız); iki taraf da işini bitirince
/// `release` çağırır, son çağıran serbest bırakır. Bekçi, süre dolunca açık soketi `shutdown` eder: bloklanmış okuma/yazma
/// hata ile döner, yani zaman aşımı GERÇEK bir bağlantı iptalidir (istek bittikten sonra süre ölçen sahte bir kontrol değil).
pub const Shared = struct {
    lock: asap.SpinLock = .{},
    /// Açık bağlantının soket tutamacı (`handle_set` iken geçerli); `lock` altında okunur/yazılır.
    handle: usize = 0,
    handle_set: bool = false,
    done: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),
    refs: std.atomic.Value(u32) = .init(2),
    /// Akışlı istekler (`http_stream.zig`): bir işlem sürerken `true`; bekçi yalnızca bu süre içinde sayar (işlem başına boşta kalma zaman aşımı).
    armed: std.atomic.Value(bool) = .init(false),
    /// Her yeni işlemde artar; bekçi değişimi görünce sayacı sıfırlar.
    epoch: std.atomic.Value(u32) = .init(0),

    pub fn release(self: *Shared) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) std.heap.page_allocator.destroy(self);
    }

    pub fn setHandle(self: *Shared, h: usize) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.handle = h;
        self.handle_set = true;
    }

    /// Bağlantı kapanmadan ÖNCE çağrılır: bekçinin kapanmış (belki yeniden kullanılmış) bir tutamaca dokunmasını önler.
    pub fn clearHandle(self: *Shared) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.handle_set = false;
    }

    pub fn abortConnection(self: *Shared) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (!self.handle_set) return;
        if (builtin.os.tag == .windows) {
            const w = struct {
                extern "ws2_32" fn shutdown(s: usize, how: i32) callconv(.c) i32;
            };
            _ = w.shutdown(self.handle, 2);
        } else {
            _ = std.c.shutdown(@intCast(self.handle), 2);
        }
    }
};

pub fn sleepMs(ms: u32) void {
    if (builtin.os.tag == .windows) {
        winSleep(ms);
        return;
    }
    const ts: posix.timespec = .{ .sec = @divTrunc(ms, 1000), .nsec = @as(isize, @intCast(ms % 1000)) * std.time.ns_per_ms };
    _ = std.c.nanosleep(&ts, null);
}

pub fn socketHandleToUsize(h: anytype) usize {
    return switch (@typeInfo(@TypeOf(h))) {
        .pointer => @intFromPtr(h),
        else => @intCast(h),
    };
}

fn watchdogThreadFn(shared: *Shared, timeout_ms: u64) void {
    defer shared.release();
    var elapsed: u64 = 0;
    while (!shared.done.load(.acquire)) {
        sleepMs(5);
        elapsed += 5;
        if (elapsed >= timeout_ms) {
            shared.timed_out.store(true, .release);
            // Bağlantı henüz kurulmamış olabilir (DNS/connect aşaması): tutamaç belirince tekrar denenir.
            shared.abortConnection();
        }
    }
}

const RequestCtx = struct {
    allocator: std.mem.Allocator,
    url: [:0]const u8,
    method: std.http.Method,
    body: ?[]const u8,
    /// Giden istek başlıkları — çağıranın (Nox tarafının) `dict[str, str]`
    /// argümanından KOPYALANDI (bkz. `copyHeaders`), arka plan iş parçacığı
    /// çalışırken orijinal Nox dict'i/string'leri serbest bırakılsa/
    /// değişse BİLE GÜVENLİDİR.
    request_headers: []const std.http.Header,
    write_fd: posix.fd_t,

    /// > 0 ise bekçi iş parçacığı bu süre (ms) dolunca bağlantıyı iptal eder (bkz. `Shared`).
    shared: ?*Shared = null,

    status: u16 = 0,
    response_body: []u8 = &.{},
    response_headers: []std.http.Header = &.{},
    failed: bool = false,
    /// `failed` iken: 1 = zaman aşımı, 2 = diğer (DNS/bağlantı/protokol/gövde okuma).
    err_kind: u8 = 0,

    fn destroyOwned(self: *RequestCtx) void {
        self.allocator.free(self.url);
        if (self.body) |b| self.allocator.free(b);
        for (self.request_headers) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        if (self.request_headers.len > 0) self.allocator.free(self.request_headers);
    }
};

pub fn loadIosCa(client: *std.http.Client) bool {
    const apple_roots = @import("apple_roots.zig");
    const io = client.io;
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(client.allocator);
    const now = std.Io.Clock.real.now(io);
    if (!apple_roots.fill(&bundle, client.allocator, io, now)) return false;
    client.ca_bundle_lock.lock(io) catch return false;
    defer client.ca_bundle_lock.unlock(io);
    client.now = now;
    std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
    return true;
}

fn ensureClientCa(client: *std.http.Client) bool {
    const io = client.io;
    {
        client.ca_bundle_lock.lockShared(io) catch return false;
        defer client.ca_bundle_lock.unlockShared(io);
        if (client.now != null) return true;
    }
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(client.allocator);
    const now = std.Io.Clock.real.now(io);
    bundle.rescan(client.allocator, io, now) catch return false;
    client.ca_bundle_lock.lock(io) catch return false;
    defer client.ca_bundle_lock.unlock(io);
    client.now = now;
    std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
    return true;
}

fn androidIpv4Text(host: []const u8, port: u16, ip_storage: []u8) ?[]const u8 {
    if (host.len > std.Io.net.HostName.max_len) return null;
    var host_z: [std.Io.net.HostName.max_len + 1]u8 = undefined;
    @memcpy(host_z[0..host.len], host);
    host_z[host.len] = 0;
    var service_buf: [8]u8 = undefined;
    const service = std.fmt.bufPrintZ(&service_buf, "{d}", .{port}) catch return null;
    var hints = std.mem.zeroes(std.c.addrinfo);
    hints.family = std.c.AF.INET;
    hints.socktype = std.c.SOCK.STREAM;
    var list: ?*std.c.addrinfo = null;
    if (@intFromEnum(std.c.getaddrinfo(host_z[0..host.len :0], service.ptr, &hints, &list)) != 0) return null;
    const first = list orelse return null;
    defer std.c.freeaddrinfo(first);
    const formatted = struct {
        extern "c" fn inet_ntop(af: c_int, src: *const anyopaque, dst: [*]u8, size: u32) ?[*:0]u8;
    };
    const src: *const anyopaque = @ptrFromInt(@intFromPtr(first.addr.?) + 4);
    const ip_z = formatted.inet_ntop(std.c.AF.INET, src, ip_storage.ptr, @intCast(ip_storage.len)) orelse return null;
    return std.mem.span(ip_z);
}

/// Android'de Zig `HostName.connect` `/etc/resolv.conf` okur. Bionic bu
/// dosyayı tutmaz. Sistem çözümlemesi `getaddrinfo` ile yapılır, TCP
/// adresi IP literali olur. TLS sunucu adı çağıranın verdiği konak olarak
/// kalır.
/// `noxc run --sandbox` ağı kapalı başlatır (ADR-010) ve `NOX_SANDBOX_NO_NET=1` ayarlar. İşletim sistemi `connect`i zaten reddeder, ama
/// Zig'in `std.Io` katmanı beklenmeyen `EPERM`i programcı hatası sayıp süreci düşürür; bu denetim reddi temiz bir bağlantı hatasına çevirir.
pub fn networkDenied() bool {
    if (builtin.os.tag == .windows or builtin.os.tag == .freestanding) return false;
    const v = std.c.getenv("NOX_SANDBOX_NO_NET") orelse return false;
    return v[0] == '1';
}

pub fn connectTcp(io: std.Io, host: []const u8, port: u16) !std.Io.net.Stream {
    if (networkDenied()) return error.AccessDenied;
    if (comptime builtin.abi.isAndroid()) {
        var ip_storage: [64]u8 = undefined;
        const ip = androidIpv4Text(host, port, &ip_storage) orelse return error.DnsFailed;
        const literal = try std.Io.net.HostName.init(ip);
        return literal.connect(io, port, .{ .mode = .stream });
    }
    const host_name = try std.Io.net.HostName.init(host);
    return host_name.connect(io, port, .{ .mode = .stream });
}

test "connectTcp fails on a closed local port" {
    const connected = connectTcp(std.testing.io, "127.0.0.1", 1);
    if (connected) |stream| {
        stream.close(std.testing.io);
        return error.UnexpectedConnect;
    } else |_| {}
}

pub fn androidDial(client: *std.http.Client, uri: std.Uri, host_storage: *[std.Io.net.HostName.max_len]u8, ip_storage: []u8) ?*std.http.Client.Connection {
    const host = uri.getHost(host_storage) catch return null;
    const port = uri.port orelse if (std.mem.eql(u8, uri.scheme, "https")) @as(u16, 443) else @as(u16, 80);
    const ip_text = androidIpv4Text(host.bytes, port, ip_storage) orelse return null;
    const protocol: std.http.Client.Protocol = if (std.mem.eql(u8, uri.scheme, "https")) .tls else .plain;
    if (protocol == .tls and !ensureClientCa(client)) return null;
    return client.connectTcpOptions(.{
        .host = .{ .bytes = ip_text },
        .port = port,
        .protocol = protocol,
        .proxied_host = host,
        .proxied_port = port,
    }) catch null;
}

/// Sunucu Content-Length/chunked gövdesini tamamlamadan bağlantıyı kapattı mı? `std.http` bunu temiz bir gövde sonundan ayırmaz;
/// bağlantı durumundan anlaşılır. Gövdesi olmayan yanıtlar (HEAD, 1xx/204/304) Content-Length taşısa da eksik sayılmaz.
pub fn responseBodyTruncated(req: *std.http.Client.Request, method: std.http.Method, status: std.http.Status) bool {
    if (method == .HEAD) return false;
    switch (status) {
        .no_content, .not_modified => return false,
        else => if (@intFromEnum(status) < 200) return false,
    }
    return switch (req.reader.state) {
        .body_remaining_content_length, .body_remaining_chunk_len => true,
        else => false,
    };
}

fn workerThreadFn(ctx: *RequestCtx) void {
    // `write_fd` BURADA (fonksiyon GİRİŞİNDE) YEREL bir değişkene
    // KOPYALANIR — GERÇEK bir yarış durumu (Linux/x86-64 CI'de bir
    // segfault olarak GÖZLEMLENDİ) `ctx.write_fd`nin AŞAĞIDAKİ `defer`
    // İÇİNDE DOĞRUDAN okunmasından kaynaklanıyordu: `write()` TAMAMLANIR
    // TAMAMLANMAZ ÇAĞIRAN taraf (`doRequest`, pipe'ı OKUYAN) UYANIR ve
    // `ctx`yi (`gpa.destroy(ctx)` İLE, `rt` yıkıldığında) SERBEST
    // BIRAKABİLİR — TAM O SIRADA BU `defer` HÂLÂ `close(ctx.write_fd)`
    // İÇİN `ctx`yi DEREFERANS ETMEYE ÇALIŞIYORSA, ARTIK SERBEST BIRAKILMIŞ
    // belleği OKUR (KULLANIM-SONRASI-SERBEST). Yerel kopya, sinyal
    // YAZILDIKTAN SONRA `ctx`ye HİÇ dokunulmamasını GARANTİ eder.
    const write_fd = ctx.write_fd;
    defer {
        signalSelfPipe(write_fd);
        closeFd(write_fd);
    }
    // Bu defer, yukarıdakinden ÖNCE çalışır (LIFO): sinyalden sonra `ctx`ye dokunulmaz.
    defer {
        const sh = ctx.shared;
        if (ctx.failed) ctx.err_kind = if (sh) |x| (if (x.timed_out.load(.acquire)) @as(u8, 1) else 2) else 2;
        if (sh) |x| {
            x.done.store(true, .release);
            x.release();
        }
    }

    if (networkDenied()) {
        ctx.failed = true;
        return;
    }

    const io = sharedClientIo();

    // İstek ömrü kadar bir arena. `std.http.Client` başarısız bağlantıda
    // (Windows AFD) bıraktığı ara tahsisler Nox'un DebugAllocator sızıntı
    // sayacına düşmesin; istek bitince arena hepsini geri verir.
    var request_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer request_arena.deinit();
    var client: std.http.Client = .{ .allocator = request_arena.allocator(), .io = io };
    defer client.deinit();

    const uri = std.Uri.parse(ctx.url) catch {
        ctx.failed = true;
        return;
    };

    if (comptime builtin.os.tag == .ios) {
        if (!loadIosCa(&client)) {
            ctx.failed = true;
            return;
        }
    }

    // Android'de Zig ad çözümlemesi `/etc/resolv.conf` okur. Bionic bu dosyayı
    // tutmaz; sistem çözümlemesi `getaddrinfo` ile netd'ye gider. TLS sunucu
    // adı URL'deki konak olarak kalır, sertifika doğrulaması kapanmaz.
    var android_host: [std.Io.net.HostName.max_len]u8 = undefined;
    var android_ip: [64]u8 = undefined;
    const dialed: ?*std.http.Client.Connection = if (comptime builtin.abi.isAndroid())
        androidDial(&client, uri, &android_host, android_ip[0..])
    else
        null;

    var req = client.request(ctx.method, uri, .{
        .extra_headers = ctx.request_headers,
        .redirect_behavior = .unhandled,
        .connection = dialed,
    }) catch |err| {
        if (comptime (builtin.abi.isAndroid() or builtin.os.tag == .ios) and builtin.mode == .Debug) {
            const c = struct {
                extern "c" fn nox_host_log_debug(text: [*:0]const u8) void;
            };
            c.nox_host_log_debug(@errorName(err));
        }
        ctx.failed = true;
        return;
    };
    defer req.deinit();
    // Zaman aşımı bekçisi için açık soketi yayınla; bağlantı kapanmadan ÖNCE geri al (LIFO: req.deinit'ten önce çalışır).
    if (ctx.shared) |sh| {
        if (req.connection) |conn| sh.setHandle(socketHandleToUsize(conn.stream_reader.stream.socket.handle));
    }
    defer if (ctx.shared) |sh| sh.clearHandle();

    if (ctx.body) |b| {
        req.transfer_encoding = .{ .content_length = b.len };
        var body_writer = req.sendBodyUnflushed(&.{}) catch {
            ctx.failed = true;
            return;
        };
        body_writer.writer.writeAll(b) catch {
            ctx.failed = true;
            return;
        };
        body_writer.end() catch {
            ctx.failed = true;
            return;
        };
        const conn = req.connection orelse {
            ctx.failed = true;
            return;
        };
        conn.flush() catch {
            ctx.failed = true;
            return;
        };
    } else {
        req.sendBodiless() catch {
            ctx.failed = true;
            return;
        };
    }

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buffer) catch {
        ctx.failed = true;
        return;
    };

    ctx.status = @intFromEnum(response.head.status);

    var headers_list: std.ArrayListUnmanaged(std.http.Header) = .empty;
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        const name_copy = ctx.allocator.dupe(u8, h.name) catch continue;
        const value_copy = ctx.allocator.dupe(u8, h.value) catch {
            ctx.allocator.free(name_copy);
            continue;
        };
        headers_list.append(ctx.allocator, .{ .name = name_copy, .value = value_copy }) catch {
            ctx.allocator.free(name_copy);
            ctx.allocator.free(value_copy);
            continue;
        };
    }
    ctx.response_headers = headers_list.toOwnedSlice(ctx.allocator) catch &.{};
    // Düzeltme 1/2 gövde-okuma başarısızlıklarının (decompress tamponu
    // tahsisi, desteklenmeyen kodlama, `streamRemaining`, gömülü NUL) HEPSİ
    // BURADAN SONRA, yani `ctx.response_headers` ZATEN doldurulduktan SONRA
    // gerçekleşir — bu ARTIK BAŞARISIZ olan istekler İÇİN de `response_
    // headers`ın serbest bırakılmasını GARANTİ eder (`doRequest`nin
    // başarısızlık yolu, `destroyOwned` ÜZERİNDEN yalnızca `request_
    // headers`ı serbest bırakır, `response_headers`ı DEĞİL — bu olmadan
    // gerçek bir bellek sızıntısı olurdu, testle YAKALANDI).
    var headers_committed = false;
    defer if (!headers_committed) {
        for (ctx.response_headers) |header| {
            ctx.allocator.free(header.name);
            ctx.allocator.free(header.value);
        }
        if (ctx.response_headers.len > 0) ctx.allocator.free(ctx.response_headers);
        ctx.response_headers = &.{};
    };

    var transfer_buffer: [1024]u8 = undefined;
    // `std.http.Client`in varsayılan `accept_encoding`i (bkz. Zig std
    // `Client.Options.default_accept_encoding`) sunucudan zaten gzip/deflate
    // İSTEDİĞİNDEN, düz `Response.reader` GERÇEK DÜNYADA (Cloudflare/GitHub/
    // Google DAHİL) neredeyse HER zaman HAM/sıkıştırılmış bayt döndürür —
    // `readerDecompressing` İLE `Content-Encoding`e göre ÇÖZÜLEREK okunur
    // (bkz. Zig std'nin KENDİ `Client.fetch`i, AYNI desen).
    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .deflate, .gzip => ctx.allocator.alloc(u8, std.compress.flate.max_window_len) catch {
            ctx.failed = true;
            return;
        },
        // İstemcinin varsayılan `accept_encoding`i yalnızca gzip/deflate/
        // identity'i talep ettiğinden buraya ULAŞILMASI BEKLENMEZ — sunucu
        // yine de gönderirse (standart-dışı davranış) güvenle reddedilir.
        .zstd, .compress => {
            ctx.failed = true;
            return;
        },
    };
    defer if (decompress_buffer.len > 0) ctx.allocator.free(decompress_buffer);
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    var body_out: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer body_out.deinit();
    _ = reader.streamRemaining(&body_out.writer) catch {
        ctx.failed = true;
        return;
    };
    // Sunucu Content-Length/chunked gövdesini tamamlamadan bağlantıyı kapattıysa `streamRemaining` bunu temiz bir gövde sonu
    // sayar; eksik gövde sessizce başarı olarak dönmesin (v2.0.69).
    if (responseBodyTruncated(&req, ctx.method, response.head.status)) {
        ctx.failed = true;
        return;
    }
    const body: []u8 = body_out.toOwnedSlice() catch &.{};

    // Gövde ikili olabilir (gömülü `\0`, geçersiz UTF-8): `str` uzunluğu başlıkta taşıdığı için
    // `nox_str_from_bytes` hepsini aynen kopyalar; gövde reddedilmez.
    ctx.response_body = body;
    headers_committed = true;
}

/// Güvenlik bulgusu M-1 (bkz. güvenlik raporu) — `std.http`nin KENDİ
/// başlık adı/değeri doğrulaması yalnızca `assert`/`std.debug.runtime_
/// safety` İLE yapılıyordu, bu da `ReleaseFast`/`ReleaseSmall`
/// derlemelerinde TAMAMEN devre dışı kalıyordu — kullanıcı verisini bir
/// başlık değeri olarak yansıtan bir Nox programı (ör. `nox.http.get(url,
/// {"X-Debug": kullanici_girdisi})`), ÜRETİM derlemesinde SESSİZCE CRLF
/// enjekte edip başlık/yanıt bölme (header/response splitting)
/// yapabiliyordu; Debug/ReleaseSafe'de İSE AYNI girdi bu SEFER bir
/// panikle SÜREÇ ÇÖKMESİNE (DoS) yol açıyordu — İKİ modda da güvenli
/// DEĞİLDİ. Bu fonksiyon HER build modunda ÇALIŞAN, GERÇEK bir `if`
/// kontrolüyle CR/LF baytlarını reddeder.
fn containsCrOrLf(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, '\r') != null or std.mem.indexOfScalar(u8, s, '\n') != null;
}

/// Bir `dict[str, str]` handle'ından (ya da `null`) arka plan iş
/// parçacığına GÜVENLE devredilebilecek, BAĞIMSIZ (kopyalanmış) bir
/// `std.http.Header` dizisi inşa eder (bkz. `RequestCtx.request_headers`in
/// belge notu). Bir başlık adı/değeri CR/LF İÇERİYORSA `error.
/// InvalidHeaderValue` döner — ÇAĞIRAN (bkz. `doRequest`) bunu, DİĞER
/// TÜM istek-inşası hatalarıyla (URL/govde kopyalama başarısızlığı gibi)
/// AYNI şekilde, İSTEĞİN TAMAMEN REDDİ olarak ele alır (yalnızca
/// bozuk başlığı SESSİZCE ATLAMAZ — bu, kullanıcının GÖNDERDİĞİNİ
/// SANDIĞI GÜVENLİK-İLGİLİ bir başlığın [ör. `Authorization`]
/// FARK ETTİRMEDEN kaybolmasını ÖNLER).
pub fn copyHeaders(allocator: std.mem.Allocator, headers_dict: ?*anyopaque) ![]std.http.Header {
    const d: *dict_mod.Dict = @ptrCast(@alignCast(headers_dict orelse return &.{}));
    if (d.entries.items.len == 0) return &.{};
    var out = try allocator.alloc(std.http.Header, d.entries.items.len);
    errdefer allocator.free(out);
    var filled: usize = 0;
    errdefer for (out[0..filled]) |h| {
        allocator.free(h.name);
        allocator.free(h.value);
    };
    for (d.entries.items) |e| {
        const key_ptr: [*:0]const u8 = @ptrFromInt(@as(usize, @bitCast(e.key)));
        const value_ptr: [*:0]const u8 = @ptrFromInt(@as(usize, @bitCast(e.value)));
        const key = str_mod.nox_str_slice(key_ptr);
        const value = str_mod.nox_str_slice(value_ptr);
        if (containsCrOrLf(key) or containsCrOrLf(value)) return error.InvalidHeaderValue;
        out[filled] = .{
            .name = try allocator.dupe(u8, key),
            .value = try allocator.dupe(u8, value),
        };
        filled += 1;
    }
    return out;
}

/// GERÇEK bir HTTP isteği (GET/POST) gönderir; tamamlanana kadar ÇAĞIRAN
/// fiber'ı (varsa) askıya alır, YOKSA sıradan bloklar (bkz. modül üstü
/// not). Başarısızlıkta `null` döner (DNS/bağlantı/protokol hatası — Nox
/// sarmalayıcısı bunu `HttpError` olarak `raise` eder, bkz. D.1.5).
/// Başarıda bir "yanıt tutamacı" (opak `ptr`) döner — `nox_http_response_*`
/// erişimcileriyle okunur, `nox_http_response_free` ile serbest bırakılır.
fn doRequest(
    rt: ?*anyopaque,
    method: std.http.Method,
    url: ?[*:0]const u8,
    body: ?[*:0]const u8,
    headers_dict: ?*anyopaque,
    timeout_ms: i64,
    /// `true` ise başarısız bir istek de (`ok == 0`, `error_kind` ile) tutamaç olarak döner; `false` ise `null` (eski davranış).
    keep_failed: bool,
) ?*anyopaque {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    const gpa = state.allocator();
    const u = url orelse return null;

    const ctx = gpa.create(RequestCtx) catch return null;

    const fds = makeSelfPipe() orelse {
        gpa.destroy(ctx);
        return null;
    };

    const url_copy = gpa.dupeZ(u8, str_mod.nox_str_slice(u)) catch {
        closeFd(fds[0]);
        closeFd(fds[1]);
        gpa.destroy(ctx);
        return null;
    };
    const body_copy: ?[]const u8 = if (body) |b| (gpa.dupe(u8, str_mod.nox_str_slice(b)) catch null) else null;
    // Güvenlik M-1: `copyHeaders`in `error.InvalidHeaderValue`si (bkz. onun
    // belge notu) İSTEĞİN TAMAMI reddedilerek ele alınır — `url_copy`
    // başarısızlığıyla AYNI "temizle, `null` dön" deseni.
    const headers_copy = copyHeaders(gpa, headers_dict) catch {
        gpa.free(url_copy);
        if (body_copy) |b| gpa.free(b);
        closeFd(fds[0]);
        closeFd(fds[1]);
        gpa.destroy(ctx);
        return null;
    };

    ctx.* = .{
        .allocator = gpa,
        .url = url_copy,
        .method = method,
        .body = body_copy,
        .request_headers = headers_copy,
        .write_fd = fds[1],
    };

    if (timeout_ms > 0) {
        const shared = std.heap.page_allocator.create(Shared) catch {
            ctx.destroyOwned();
            gpa.destroy(ctx);
            closeFd(fds[0]);
            closeFd(fds[1]);
            return null;
        };
        shared.* = .{};
        const watchdog = std.Thread.spawn(.{}, watchdogThreadFn, .{ shared, @as(u64, @intCast(timeout_ms)) }) catch {
            std.heap.page_allocator.destroy(shared);
            ctx.destroyOwned();
            gpa.destroy(ctx);
            closeFd(fds[0]);
            closeFd(fds[1]);
            return null;
        };
        watchdog.detach();
        ctx.shared = shared;
    }

    const thread = std.Thread.spawn(.{}, workerThreadFn, .{ctx}) catch {
        if (ctx.shared) |sh| {
            // İşçi hiç başlamadı: kendi payını bırak, bekçi `done` görünce çıkıp kendi payını bırakır.
            sh.done.store(true, .release);
            sh.release();
        }
        ctx.destroyOwned();
        gpa.destroy(ctx);
        closeFd(fds[0]);
        closeFd(fds[1]);
        return null;
    };
    thread.detach();

    if (bridge.currentFiberScheduler()) |scheduler| {
        // Faz [YENİ] (bkz. plan dosyası "setNonBlocking'in her okuma/
        // yazmada gereksiz tekrarını gidermek"): bu self-pipe fd'si
        // `nonBlockingAccept`/`bindAndListen`den GEÇMEDEN doğrudan
        // `makeSelfPipe()`den geldiğinden, `nonBlockingReadOnce` İLE
        // TEK SEFERLİK non-blocking ayarı YAPILIR.
        var buf: [1]u8 = undefined;
        _ = io_mod.nonBlockingReadOnce(scheduler, fds[0], &buf) catch {};
    } else {
        var buf: [1]u8 = undefined;
        readSelfPipe(fds[0], &buf);
    }
    closeFd(fds[0]);

    if (ctx.failed and !keep_failed) {
        ctx.destroyOwned();
        gpa.destroy(ctx);
        return null;
    }
    return ctx;
}

pub fn parseMethod(name: []const u8) ?std.http.Method {
    const table = [_]struct { name: []const u8, method: std.http.Method }{
        .{ .name = "GET", .method = .GET },
        .{ .name = "POST", .method = .POST },
        .{ .name = "PUT", .method = .PUT },
        .{ .name = "PATCH", .method = .PATCH },
        .{ .name = "DELETE", .method = .DELETE },
        .{ .name = "HEAD", .method = .HEAD },
        .{ .name = "OPTIONS", .method = .OPTIONS },
    };
    for (table) |e| if (std.mem.eql(u8, name, e.name)) return e.method;
    return null;
}

export fn nox_http_get_raw(rt: ?*anyopaque, url: ?[*:0]const u8, headers: ?*anyopaque) callconv(.c) ?*anyopaque {
    return doRequest(rt, .GET, url, null, headers, 0, false);
}

export fn nox_http_post_raw(rt: ?*anyopaque, url: ?[*:0]const u8, body: ?[*:0]const u8, headers: ?*anyopaque) callconv(.c) ?*anyopaque {
    return doRequest(rt, .POST, url, body, headers, 0, false);
}

/// Genel istek: `method` GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS (büyük harf) olmalıdır; bilinmeyen ad sessizce GET'e
/// DÜŞMEZ, `null` döner. `timeout_ms > 0` ise bağlantı kurulduktan sonra gerçek bir zaman aşımı uygulanır (bkz. modül
/// notu). Başarısız istek de bir tutamaç döner (`nox_http_response_ok == 0`, `nox_http_response_error_kind` ile neden).
/// `has_body != 0` yalnızca POST/PUT/PATCH ile geçerlidir; GET/HEAD/DELETE/OPTIONS + gövde `null` döner.
export fn nox_http_request_raw(
    rt: ?*anyopaque,
    method: ?[*:0]const u8,
    url: ?[*:0]const u8,
    body: ?[*:0]const u8,
    has_body: i32,
    headers: ?*anyopaque,
    timeout_ms: i64,
) callconv(.c) ?*anyopaque {
    const m = parseMethod(str_mod.nox_str_slice(method orelse return null)) orelse return null;
    // `std.http` yalnızca POST/PUT/PATCH'te gövde gönderebilir; diğer metodlarda gövde SESSİZCE düşürülmez, istek reddedilir.
    if (has_body != 0 and !m.requestHasBody()) return null;
    return doRequest(rt, m, url, if (has_body != 0) body else null, headers, timeout_ms, true);
}

/// 0 = başarılı, 1 = zaman aşımı, 2 = diğer hata, 3 = geçersiz istek (tutamaç `null`: bilinmeyen metod, gövdesiz metodda gövde,
/// bozuk başlık, tahsis hatası).
export fn nox_http_response_error_kind(h: ?*anyopaque) callconv(.c) i64 {
    const ctx: *RequestCtx = @ptrCast(@alignCast(h orelse return 3));
    if (!ctx.failed) return 0;
    return ctx.err_kind;
}

export fn nox_http_response_ok(h: ?*anyopaque) callconv(.c) i32 {
    const ctx: *RequestCtx = @ptrCast(@alignCast(h orelse return 0));
    return if (ctx.failed) 0 else 1;
}

export fn nox_http_response_status(h: ?*anyopaque) callconv(.c) i64 {
    const ctx: *RequestCtx = @ptrCast(@alignCast(h orelse return 0));
    return ctx.status;
}

/// Dönen `str` YENİ, `rt` üzerinden tahsis edilmiş bağımsız bir ARC
/// nesnesidir (tutamaçtan ayrı, `nox_http_response_free`den ETKİLENMEZ) —
/// Nox'un `nox_str_release`i bunu her zamanki gibi serbest bırakabilir.
export fn nox_http_response_body(rt: ?*anyopaque, h: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const ctx: *RequestCtx = @ptrCast(@alignCast(h orelse return null));
    return dupeToNoxStr(rt, ctx.response_body);
}

/// Yanıt başlıklarını YENİ bir `dict[str, str]` (`rt` üzerinden tahsis
/// edilmiş, tutamaçtan BAĞIMSIZ) olarak döner — `runtime/collections/dict.zig`nin
/// `pub` yapılmış `nox_dict_new`/`nox_dict_set`i DOĞRUDAN kullanılır (bkz.
/// nox-teknik-spesifikasyon.md §3.30, D.1.2).
export fn nox_http_response_headers(rt: ?*anyopaque, h: ?*anyopaque) callconv(.c) ?*anyopaque {
    const ctx: *RequestCtx = @ptrCast(@alignCast(h orelse return null));
    const d = dict_mod.nox_dict_new(rt, 1) orelse return null;
    for (ctx.response_headers) |header| {
        const key_str = dupeToNoxStr(rt, header.name) orelse continue;
        const value_str = dupeToNoxStr(rt, header.value) orelse continue;
        dict_mod.nox_dict_set(rt, d, 1, 1, 0, @bitCast(@intFromPtr(key_str)), @bitCast(@intFromPtr(value_str)));
        // `nox_dict_set` KENDİ kopyasını SAKLAR (str'i doğrudan payload
        // olarak depolar, bkz. onun belge notu — "sahiplik ÇAĞIRANDAN
        // devralınır") — `dupeToNoxStr`nin ürettiği YENİ referans artık
        // dict'in mülkiyetindedir, burada AYRICA serbest bırakılmaz.
    }
    return d;
}

/// Bir C bayt dizisini YENİ, sıfırla-sonlanan, paketlenmiş uzunluk+ascii
/// başlıklı bir Nox `str`ine kopyalar — `runtime/str.zig`nin KANONİK
/// `nox_str_from_bytes` sarmalayıcısı (bkz. onun belge notu — `str`e
/// uzunluk alanı + ASCII bayrağı eklenmesinden BERİ TEK doğru yol).
pub fn dupeToNoxStr(rt: ?*anyopaque, bytes: []const u8) ?[*:0]u8 {
    return str_mod.nox_str_from_bytes(rt, bytes);
}

/// Tutamacı VE İÇİNDEKİ TÜM (henüz `nox_http_response_body`/`headers`
/// aracılığıyla Nox'a devredilmemiş dahi olsa) ham arabellekleri serbest
/// bırakır — `nox_http_response_body`/`headers`in DÖNDÜRDÜĞÜ değerler
/// BAĞIMSIZ kopyalar olduğundan (bkz. onların belge notu) bundan
/// ETKİLENMEZ.
export fn nox_http_response_free(h: ?*anyopaque) callconv(.c) void {
    const ctx: *RequestCtx = @ptrCast(@alignCast(h orelse return));
    const gpa = ctx.allocator;
    ctx.destroyOwned();
    if (ctx.response_body.len > 0) gpa.free(ctx.response_body);
    for (ctx.response_headers) |header| {
        gpa.free(header.name);
        gpa.free(header.value);
    }
    if (ctx.response_headers.len > 0) gpa.free(ctx.response_headers);
    gpa.destroy(ctx);
}

// ---- Birim testleri ----------------------------------------------------
//
// `std.http.Client`in bağlanacağı GERÇEK bir yerel TCP sunucusu — D.0'ın
// `io.zig`si GİBİ ham POSIX soket çağrılarıyla (`std.c.socket`/`bind`/
// `listen`/`accept`) elle kurulur (`std.Io.net`in tam soyutlamasına
// GİRMEDEN — bu yalnızca test tarafının sahte sunucusu, D.1.4'ün GERÇEK
// fiber-native sunucu kabuğu AYRI bir dosyada, ayrı bir sonraki adımdır).

fn testListenerOn127001(port_out: *u16) !posix.fd_t {
    if (builtin.os.tag == .windows) {
        io_mod.ensureWinsock();
        const ws = io_mod.WinSock;
        const fd = ws.socket(ws.AF_INET, ws.SOCK_STREAM, 0);
        if (fd == ws.INVALID_SOCKET) return error.SocketFailed;
        var reuse: c_int = 1;
        _ = ws.setsockopt(fd, ws.SOL_SOCKET, ws.SO_REUSEADDR, &reuse, @sizeOf(c_int));

        var addr: std.os.windows.ws2_32.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (ws.bind(fd, &addr, @sizeOf(std.os.windows.ws2_32.sockaddr.in)) != 0) return error.BindFailed;
        if (ws.listen(fd, 1) != 0) return error.ListenFailed;

        var got: std.os.windows.ws2_32.sockaddr.in = undefined;
        var got_len: i32 = @sizeOf(std.os.windows.ws2_32.sockaddr.in);
        if (ws.getsockname(fd, &got, &got_len) != 0) return error.GetsocknameFailed;
        port_out.* = std.mem.bigToNative(u16, got.port);
        return @ptrFromInt(fd);
    }
    const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    var reuse: c_int = 1;
    _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &reuse, @sizeOf(c_int));

    var addr: std.c.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    const bind_rc = std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in));
    if (bind_rc != 0) return error.BindFailed;
    if (std.c.listen(fd, 1) != 0) return error.ListenFailed;

    var got: std.c.sockaddr.in = undefined;
    var got_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
    if (std.c.getsockname(fd, @ptrCast(&got), &got_len) != 0) return error.GetsocknameFailed;
    port_out.* = std.mem.bigToNative(u16, got.port);
    return fd;
}

/// Faz TEST.4 (bkz. plan dosyası): `tests/cli/search_test.zig`/`publish_
/// test.zig`/`upgrade_test.zig`/`tests/compat/http_stdlib_golden_test.zig`nin
/// (Faz TEST.1, v1.80.6) AYNI, ZATEN kanıtlanmış `acceptWithTimeout`
/// yardımcısının BİREBİR bir kopyası — o dört dosya düzeltilirken BU dosyanın
/// KENDİ iç testlerinin (`nox_http_get_raw`) AYNI zaman-aşımsız `std.c.
/// accept()` hatasını taşıdığı GÖZDEN KAÇMIŞTI (istemci bağlantısı
/// KURULAMAZSA `accept()` SONSUZA KADAR bekler, `defer server_thread.
/// join()` de test sürecini SONSUZA KADAR askıda bırakır).
fn acceptWithTimeout(listen_fd: posix.fd_t, timeout_ms: i32) posix.fd_t {
    var pfd = [1]std.c.pollfd{.{ .fd = listen_fd, .events = std.c.POLL.IN, .revents = 0 }};
    const n = std.c.poll(&pfd, 1, timeout_ms);
    if (n <= 0) return -1;
    return std.c.accept(listen_fd, null, null);
}

/// Bir bağlantı kabul eder, isteği (yalnızca `\r\n\r\n`e kadar) okur, SABİT
/// bir HTTP/1.1 yanıtı (durum 200, `X-Nox-Test: merhaba` başlığı, `"hello"`
/// gövdesi) yazar, bağlantıyı kapatır.
fn testServeOnce(listen_fd: posix.fd_t) void {
    testServeOnceDelayed(listen_fd, 0);
}

/// `testServeOnce` İLE AYNI, `delay_ms > 0` İSE yanıtı YAZMADAN ÖNCE
/// KASITLI olarak bekler — `http_server.zig`nin "yavaş istemci" testinin
/// (150ms `nanosleep`, bkz. onun belge notu) AYNI "EAGAIN'i ZORLA" deseni,
/// burada SUNUCU tarafına uygulanır. **Neden gerekli (Linux/x86-64 CI'de
/// GERÇEKTEN gözlemlenen bir flake):** gecikme OLMADAN, loopback'teki TÜM
/// istek/yanıt döngüsü BAZEN zamanlayıcının `nonBlockingRead`in İLK
/// deneme'sini yapıp `EAGAIN` GÖZLEMLEMESİNDEN (dolayısıyla fiber'ın
/// GERÇEKTEN askıya ALINIP `suspendForIo`ya DÜŞMESİNDEN) DAHA HIZLI
/// tamamlanabiliyordu — bu durumda istek fiber'ı HİÇ askıya ALINMADAN
/// (BAŞKA fiber'a GEÇİŞ OLMADAN) tek seferde TAMAMLANIYORDU, "sıra kanıtı"
/// testinin (bkz. aşağıdaki test) BEKLEDİĞİ "diger fiber calisti" ÖNCE
/// gelir garantisini BOZUYORDU.
fn windowsAccept(listen: usize, timeout_ms: i32) usize {
    switch (comptime builtin.os.tag) {
        .windows => {
            const poll = struct {
                const Fd = extern struct {
                    fd: usize,
                    events: i16,
                    revents: i16,
                };
                extern "ws2_32" fn WSAPoll(fds: [*]Fd, nfds: u32, timeout: i32) callconv(.c) i32;
            };
            var pfd = [1]poll.Fd{.{ .fd = listen, .events = 0x0100, .revents = 0 }};
            if (poll.WSAPoll(&pfd, 1, timeout_ms) <= 0) return io_mod.WinSock.INVALID_SOCKET;
            return io_mod.WinSock.accept(listen, null, null);
        },
        else => unreachable,
    }
}

fn testServeOnceDelayed(listen_fd: posix.fd_t, delay_ms: i64) void {
    if (builtin.os.tag == .windows) {
        const ws = io_mod.WinSock;
        const conn = windowsAccept(@intFromPtr(listen_fd), 15_000);
        if (conn == ws.INVALID_SOCKET) return;
        defer _ = ws.closesocket(conn);

        var req_buf: [4096]u8 = undefined;
        var total: usize = 0;
        while (total < req_buf.len) {
            const n = ws.recv(conn, req_buf[total..].ptr, @intCast(req_buf.len - total), 0);
            if (n <= 0) break;
            total += @intCast(n);
            if (std.mem.indexOf(u8, req_buf[0..total], "\r\n\r\n") != null) break;
        }

        if (delay_ms > 0) winSleep(@intCast(delay_ms));

        const response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nX-Nox-Test: merhaba\r\nConnection: close\r\n\r\nhello";
        var written: usize = 0;
        while (written < response.len) {
            const n = ws.send(conn, response[written..].ptr, @intCast(response.len - written), 0);
            if (n <= 0) break;
            written += @intCast(n);
        }
        return;
    }
    const conn = acceptWithTimeout(listen_fd, 15_000);
    if (conn < 0) return;
    defer _ = std.c.close(conn);

    var req_buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < req_buf.len) {
        const n = std.c.read(conn, req_buf[total..].ptr, req_buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
        if (std.mem.indexOf(u8, req_buf[0..total], "\r\n\r\n") != null) break;
    }

    if (delay_ms > 0) {
        const ts: posix.timespec = .{
            .sec = @divTrunc(delay_ms, std.time.ms_per_s),
            .nsec = @mod(delay_ms, std.time.ms_per_s) * std.time.ns_per_ms,
        };
        _ = std.c.nanosleep(&ts, null);
    }

    const response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nX-Nox-Test: merhaba\r\nConnection: close\r\n\r\nhello";
    var written: usize = 0;
    while (written < response.len) {
        const n = std.c.write(conn, response[written..].ptr, response.len - written);
        if (n <= 0) break;
        written += @intCast(n);
    }
}

test "nox_http_get_raw: gerçek yerel HTTP sunucusuna GET isteği — status/body/header doğru okunur (senkron, fiber DIŞI)" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    var port: u16 = 0;
    const listen_fd = try testListenerOn127001(&port);
    defer closeFd(listen_fd);

    const server_thread = try std.Thread.spawn(.{}, testServeOnce, .{listen_fd});
    defer server_thread.join();

    var url_buf: [128]u8 = undefined;
    const url_slice = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/hello", .{port});
    const url = str_mod.nox_str_from_bytes(rt, url_slice) orelse return error.AllocFailed;
    defer str_mod.nox_str_release(rt, url);

    const resp = nox_http_get_raw(rt, url, null) orelse return error.RequestFailed;
    defer nox_http_response_free(resp);

    try std.testing.expectEqual(@as(i32, 1), nox_http_response_ok(resp));
    try std.testing.expectEqual(@as(i64, 200), nox_http_response_status(resp));

    const body = nox_http_response_body(rt, resp) orelse return error.NoBody;
    defer str_mod.nox_str_release(rt, body);
    try std.testing.expectEqualStrings("hello", std.mem.sliceTo(body, 0));

    const headers = nox_http_response_headers(rt, resp) orelse return error.NoHeaders;
    defer dict_mod.nox_dict_release(rt, headers, 1, 1, 0);
    const key = try std.testing.allocator.dupeZ(u8, "X-Nox-Test");
    defer std.testing.allocator.free(key);
    const value_payload = dict_mod.nox_dict_get(rt, headers, 1, @bitCast(@intFromPtr(key.ptr)));
    try std.testing.expect(value_payload != 0);
    const value_ptr: [*:0]const u8 = @ptrFromInt(@as(usize, @bitCast(value_payload)));
    try std.testing.expectEqualStrings("merhaba", std.mem.sliceTo(value_ptr, 0));
}

test "nox_http_get_raw: bir fiber İÇİNDEN çağrıldığında zamanlayıcı BLOKE OLMAZ (currentFiberScheduler devreye girer, D.0'ın reaktörü üzerinden tamamlanma pipe'ı beklenir)" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    bridge.nox_async_init(rt);
    defer bridge.nox_async_deinit(rt);

    var port: u16 = 0;
    const listen_fd = try testListenerOn127001(&port);
    defer closeFd(listen_fd);

    // `150` — `http_server.zig`nin "yavaş istemci" testiyle AYNI değer
    // (bkz. `testServeOnceDelayed`in belge notu) — EAGAIN'in GERÇEKTEN
    // gözlemlenmesini (dolayısıyla fiber'ın GERÇEKTEN askıya alınmasını)
    // ZORLAR.
    const server_thread = try std.Thread.spawn(.{}, testServeOnceDelayed, .{ listen_fd, 150 });
    defer server_thread.join();

    var url_buf: [128]u8 = undefined;
    const url_slice = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/hello", .{port});
    const url = str_mod.nox_str_from_bytes(rt, url_slice) orelse return error.AllocFailed;
    defer str_mod.nox_str_release(rt, url);

    // `nox_async_spawn`ın (bkz. `bridge.zig`) ÇAĞIRDIĞI sarmalayıcı — codegen'in
    // GERÇEK bir `spawn <fn>(url)` çağrı sitesi İÇİN ürettiği sarmalayıcıyla
    // AYNI rol: `arg`ı (burada DOĞRUDAN url'in kendisi) paketten çıkarıp GERÇEK
    // fonksiyonu ("işi", `nox_http_get_raw`ı) çağırır.
    // `resp_handle`: `nox_http_response_free`i BİLEREK fiber'ın KENDİ
    // çağrı yığınının İÇİNDEN DEĞİL, testin dış (normal derinlikte) yığınından
    // çağırmak İÇİN — `DebugAllocator`in `stack_trace_frames` (varsayılan
    // AÇIK) izleme özelliği bir tahsis/serbest bırakma sitesinin geri
    // izini YAKALAMAYA çalışır; fiber'ın yığını `fiber.zig`nin KENDİ
    // testinin belge notunda AÇIKÇA UYARDIĞI gibi ("sahte önyükleme
    // çerçevesi... GERÇEK bir çağrı zincirini TEMSİL ETMEZ") sığ VE
    // sahte-köklü olduğundan, bu izleme fiber'ın GERÇEK çerçevelerinin
    // ÖTESİNE (istenen çerçeve sayısına ulaşmak İÇİN) geçmeye çalışırsa
    // geçersiz belleğe düşer (segfault) — bu, `nox_http_response_free`nin
    // KENDİSİNDE bir hata DEĞİL, saf bir tanılama-aracı/fiber-yığını
    // etkileşimi (GERÇEK derlenmiş Nox programları, QBE'nin ürettiği ÇOK
    // katmanlı çağrı zinciri sayesinde bu sığlığa ASLA ulaşmaz).
    const Fn = struct {
        var rt_ptr: ?*anyopaque = null;
        var log: std.ArrayListUnmanaged([]const u8) = .empty;
        var resp_handle: ?*anyopaque = null;

        fn requestOne(arg: *anyopaque) callconv(.c) i64 {
            const u: [*:0]const u8 = @ptrCast(arg);
            const resp = nox_http_get_raw(rt_ptr, u, null);
            log.append(std.heap.page_allocator, "istek tamamlandi") catch unreachable;
            resp_handle = resp;
            if (resp) |r| return nox_http_response_status(r);
            return -1;
        }
    };
    defer Fn.log.deinit(std.heap.page_allocator);
    Fn.rt_ptr = rt;
    Fn.log.clearRetainingCapacity();

    // BAŞKA bir fiber, `nox_http_get_raw` sunucudan yanıt BEKLERKEN
    // GERÇEKTEN ilerleyebiliyor mu? — D.0'ın `nonBlockingRead` testiyle
    // AYNI "sıra kanıtı" deseni: bu fiber ÖNCE çalışır (hazır kuyrukta ilk),
    // hemen tamamlanır; istek-fiber'ı ise sunucu yanıt verene kadar askıda
    // kalır — zamanlayıcı BLOKE OLMADIĞI İÇİN bu fiber istek fiber'ından
    // ÖNCE `log`a yazabilir.
    const OtherFiber = struct {
        fn run(_: *anyopaque) callconv(.c) i64 {
            Fn.log.append(std.heap.page_allocator, "diger fiber calisti") catch unreachable;
            return 0;
        }
    };

    var dummy: i64 = 0;
    const req_task = bridge.nox_async_spawn(rt, Fn.requestOne, url).?;
    const other_task = bridge.nox_async_spawn(rt, OtherFiber.run, &dummy).?;

    try std.testing.expectEqual(@as(i32, 0), bridge.nox_async_run_to_completion(rt));
    try std.testing.expectEqual(@as(i64, 200), bridge.nox_async_await(rt, req_task));
    _ = bridge.nox_async_await(rt, other_task);
    bridge.nox_async_destroy_task(rt, req_task);
    bridge.nox_async_destroy_task(rt, other_task);

    // Bkz. `Fn.resp_handle`in belge notu — bilerek fiber'ın DIŞINDA
    // (testin normal derinlikteki yığınında) serbest bırakılıyor.
    nox_http_response_free(Fn.resp_handle);

    try std.testing.expectEqual(@as(usize, 2), Fn.log.items.len);
    try std.testing.expectEqualStrings("diger fiber calisti", Fn.log.items[0]);
    try std.testing.expectEqualStrings("istek tamamlandi", Fn.log.items[1]);
}

// Güvenlik bulgusu M-1 (bkz. güvenlik raporu, 20 Temmuz 2026) — DÜZELTİLDİ:
// `copyHeaders` ÖNCEDEN CR/LF baytlarını HİÇ DENETLEMİYORDU — bu testler
// `assert`e DEĞİL GERÇEK bir `if` kontrolüne dayandığından, HER build
// modunda (`ReleaseFast` DAHİL) geçerlidir.
test "Güvenlik M-1: copyHeaders CR/LF İÇEREN bir başlık DEĞERİNDE InvalidHeaderValue döner" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const d = dict_mod.nox_dict_new(rt, 1) orelse return error.NewFailed;
    defer dict_mod.nox_dict_release(rt, d, 1, 1, 0);
    const key = str_mod.nox_str_from_bytes(rt, "X-Echo") orelse return error.ConcatFailed;
    const value = str_mod.nox_str_from_bytes(rt, "zararli\r\nSet-Cookie: pwned=1") orelse return error.ConcatFailed;
    dict_mod.nox_dict_set(rt, d, 1, 1, 0, @bitCast(@intFromPtr(key)), @bitCast(@intFromPtr(value)));

    try std.testing.expectError(error.InvalidHeaderValue, copyHeaders(std.testing.allocator, d));
}

test "Güvenlik M-1: copyHeaders CR/LF İÇEREN bir başlık ADINDA da InvalidHeaderValue döner" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const d = dict_mod.nox_dict_new(rt, 1) orelse return error.NewFailed;
    defer dict_mod.nox_dict_release(rt, d, 1, 1, 0);
    const key = str_mod.nox_str_from_bytes(rt, "X-Bad\r\nSet-Cookie: pwned=1") orelse return error.ConcatFailed;
    const value = str_mod.nox_str_from_bytes(rt, "zararsiz") orelse return error.ConcatFailed;
    dict_mod.nox_dict_set(rt, d, 1, 1, 0, @bitCast(@intFromPtr(key)), @bitCast(@intFromPtr(value)));

    try std.testing.expectError(error.InvalidHeaderValue, copyHeaders(std.testing.allocator, d));
}

test "Güvenlik M-1: copyHeaders normal (CR/LF'siz) başlıklarda HÂLÂ doğru çalışır (yanlış-pozitif YOK)" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const d = dict_mod.nox_dict_new(rt, 1) orelse return error.NewFailed;
    defer dict_mod.nox_dict_release(rt, d, 1, 1, 0);
    const key = str_mod.nox_str_from_bytes(rt, "X-Normal") orelse return error.ConcatFailed;
    const value = str_mod.nox_str_from_bytes(rt, "deger1") orelse return error.ConcatFailed;
    dict_mod.nox_dict_set(rt, d, 1, 1, 0, @bitCast(@intFromPtr(key)), @bitCast(@intFromPtr(value)));

    const headers = try copyHeaders(std.testing.allocator, d);
    defer {
        for (headers) |h| {
            std.testing.allocator.free(h.name);
            std.testing.allocator.free(h.value);
        }
        std.testing.allocator.free(headers);
    }
    try std.testing.expectEqual(@as(usize, 1), headers.len);
    try std.testing.expectEqualStrings("X-Normal", headers[0].name);
    try std.testing.expectEqualStrings("deger1", headers[0].value);
}

// ---- v2.0.31: genel metod, gerçek zaman aşımı, ikili gövde ---------------

const CustomMode = enum { echo_method, stall, binary };

/// Tek bağlantı kabul edip isteği (başlık sonuna kadar) okur; `mode`a göre yanıt verir. Yalnızca POSIX (testler Windows'ta atlanır).
fn testServeCustom(listen_fd: posix.fd_t, mode: CustomMode) void {
    const conn = acceptWithTimeout(listen_fd, 15_000);
    if (conn < 0) return;
    defer _ = std.c.close(conn);

    var req_buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < req_buf.len) {
        const n = std.c.read(conn, req_buf[total..].ptr, req_buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
        if (std.mem.indexOf(u8, req_buf[0..total], "\r\n\r\n") != null) break;
    }
    const head = req_buf[0..total];

    switch (mode) {
        .stall => {
            // İstemci bağlantıyı iptal edene (EOF) kadar yanıt vermeden bekle; üst sınır `read` blokajı + istemci kapanışıdır.
            var scratch: [64]u8 = undefined;
            while (true) {
                const n = std.c.read(conn, &scratch, scratch.len);
                if (n <= 0) break;
            }
        },
        .echo_method => {
            const method = head[0 .. std.mem.indexOfScalar(u8, head, ' ') orelse 0];
            var out: [256]u8 = undefined;
            const is_head = std.mem.eql(u8, method, "HEAD");
            const text = std.fmt.bufPrint(&out, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nX-Method: {s}\r\nConnection: close\r\n\r\n{s}", .{ method.len, method, if (is_head) "" else method }) catch return;
            _ = std.c.write(conn, text.ptr, text.len);
        },
        .binary => {
            const body = [_]u8{ 0x00, 0xff, 0x80, 'a', 0x00 };
            const header = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\n";
            _ = std.c.write(conn, header.ptr, header.len);
            _ = std.c.write(conn, &body, body.len);
        },
    }
}

fn testUrl(rt: ?*anyopaque, port: u16, buf: []u8) !?[*:0]u8 {
    const slice = try std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/x", .{port});
    return str_mod.nox_str_from_bytes(rt, slice);
}

test "nox_http_request_raw: PUT/PATCH/DELETE/OPTIONS/HEAD gerçek metodla gider, bilinmeyen metod reddedilir" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const methods = [_][]const u8{ "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD" };
    for (methods) |m| {
        var port: u16 = 0;
        const listen_fd = try testListenerOn127001(&port);
        defer closeFd(listen_fd);
        const server = try std.Thread.spawn(.{}, testServeCustom, .{ listen_fd, CustomMode.echo_method });
        defer server.join();

        var url_buf: [64]u8 = undefined;
        const url = (try testUrl(rt, port, &url_buf)) orelse return error.AllocFailed;
        defer str_mod.nox_str_release(rt, url);
        const method = str_mod.nox_str_from_bytes(rt, m) orelse return error.AllocFailed;
        defer str_mod.nox_str_release(rt, method);
        const body = str_mod.nox_str_from_bytes(rt, "payload") orelse return error.AllocFailed;
        defer str_mod.nox_str_release(rt, body);

        const sends_body = std.mem.eql(u8, m, "PUT") or std.mem.eql(u8, m, "PATCH");
        if (!sends_body) try std.testing.expect(nox_http_request_raw(rt, method, url, body, 1, null, 0) == null);
        const resp = nox_http_request_raw(rt, method, url, body, if (sends_body) 1 else 0, null, 0) orelse return error.RequestFailed;
        defer nox_http_response_free(resp);
        try std.testing.expectEqual(@as(i32, 1), nox_http_response_ok(resp));
        try std.testing.expectEqual(@as(i64, 200), nox_http_response_status(resp));
        const got = nox_http_response_body(rt, resp) orelse return error.NoBody;
        defer str_mod.nox_str_release(rt, got);
        if (std.mem.eql(u8, m, "HEAD")) {
            try std.testing.expectEqualStrings("", str_mod.nox_str_slice(got));
        } else {
            try std.testing.expectEqualStrings(m, str_mod.nox_str_slice(got));
        }
    }

    const bad = str_mod.nox_str_from_bytes(rt, "FETCH") orelse return error.AllocFailed;
    defer str_mod.nox_str_release(rt, bad);
    const url = str_mod.nox_str_from_bytes(rt, "http://127.0.0.1:1/") orelse return error.AllocFailed;
    defer str_mod.nox_str_release(rt, url);
    try std.testing.expect(nox_http_request_raw(rt, bad, url, null, 0, null, 0) == null);
}

test "nox_http_request_raw: sessiz sunucuda timeout_ms gerçek zaman aşımı verir (error_kind 1), bağlantı iptal edilir" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    var port: u16 = 0;
    const listen_fd = try testListenerOn127001(&port);
    defer closeFd(listen_fd);
    const server = try std.Thread.spawn(.{}, testServeCustom, .{ listen_fd, CustomMode.stall });
    defer server.join();

    var url_buf: [64]u8 = undefined;
    const url = (try testUrl(rt, port, &url_buf)) orelse return error.AllocFailed;
    defer str_mod.nox_str_release(rt, url);
    const method = str_mod.nox_str_from_bytes(rt, "GET") orelse return error.AllocFailed;
    defer str_mod.nox_str_release(rt, method);

    var t0: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &t0);
    const resp = nox_http_request_raw(rt, method, url, null, 0, null, 300) orelse return error.RequestFailed;
    defer nox_http_response_free(resp);
    var t1: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &t1);
    const elapsed_ms: i64 = (t1.sec - t0.sec) * 1000 + @divTrunc(t1.nsec - t0.nsec, 1_000_000);

    try std.testing.expectEqual(@as(i32, 0), nox_http_response_ok(resp));
    try std.testing.expectEqual(@as(i64, 1), nox_http_response_error_kind(resp));
    try std.testing.expect(elapsed_ms >= 250);
    try std.testing.expect(elapsed_ms < 5000);
}

test "nox_http_request_raw: ikili gövde (gömülü NUL, 0x80+ baytlar) reddedilmez, aynen döner" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    var port: u16 = 0;
    const listen_fd = try testListenerOn127001(&port);
    defer closeFd(listen_fd);
    const server = try std.Thread.spawn(.{}, testServeCustom, .{ listen_fd, CustomMode.binary });
    defer server.join();

    var url_buf: [64]u8 = undefined;
    const url = (try testUrl(rt, port, &url_buf)) orelse return error.AllocFailed;
    defer str_mod.nox_str_release(rt, url);

    const resp = nox_http_get_raw(rt, url, null) orelse return error.RequestFailed;
    defer nox_http_response_free(resp);
    const got = nox_http_response_body(rt, resp) orelse return error.NoBody;
    defer str_mod.nox_str_release(rt, got);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0xff, 0x80, 'a', 0x00 }, str_mod.nox_str_slice(got));
}
