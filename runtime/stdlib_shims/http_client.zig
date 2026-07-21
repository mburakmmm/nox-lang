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
//! ERİŞEMEZ). Bunun bedeli: OTOMATİK yönlendirme (redirect) takibi VE
//! otomatik sıkıştırma (gzip/deflate) çözme YOK — `redirect_behavior =
//! .unhandled` (bir 3xx durumu OLDUĞU GİBİ status+body olarak döner,
//! TAKİP EDİLMEZ), gövde HAM (Content-Encoding'e bakılmaksızın) okunur.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const asap = @import("../alloc/asap.zig");
const arc = @import("../alloc/arc.zig");
const dict_mod = @import("../collections/dict.zig");
const bridge = @import("../async_rt/bridge.zig");
const io_mod = @import("../async_rt/io.zig");
const str_mod = @import("../str.zig");

/// Faz LL.5 (bkz. nox-teknik-spesifikasyon.md §3.71): `workerThreadFn`nin
/// "tamamlanma sinyali" self-pipe'ı `std.c.pipe`ye dayanır — Windows'ta
/// `pipe()` YOKTUR. Yerine, BAĞLANMIŞ (connected) bir UDP-loopback ÇİFTİ
/// kullanılır (`io_reactor.zig`nin `WindowsReactor.makeLoopbackPair`iYLE
/// AYNI teknik) — bir tarafa `send` edilen TEK bayt, diğer taraftan
/// `recv` edilerek OKUNUR, `nonBlockingRead`in (D.0'ın reaktörü) BEKLEDİĞİ
/// "hazır-olma bildirimi alınabilen bir fd" sözleşmesini AYNEN karşılar.
pub fn makeSelfPipe() ?[2]posix.fd_t {
    if (builtin.os.tag == .windows) {
        const ws = io_mod.WinSock;
        const a = ws.socket(ws.AF_INET, 2, 17); // SOCK_DGRAM=2, IPPROTO_UDP=17
        if (a == ws.INVALID_SOCKET) return null;
        const b = ws.socket(ws.AF_INET, 2, 17);
        if (b == ws.INVALID_SOCKET) {
            _ = ws.closesocket(a);
            return null;
        }
        var addr_a: std.os.windows.ws2_32.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        var addr_b: std.os.windows.ws2_32.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (ws.bind(a, &addr_a, @sizeOf(std.os.windows.ws2_32.sockaddr.in)) != 0 or
            ws.bind(b, &addr_b, @sizeOf(std.os.windows.ws2_32.sockaddr.in)) != 0)
        {
            _ = ws.closesocket(a);
            _ = ws.closesocket(b);
            return null;
        }
        var len_a: i32 = @sizeOf(std.os.windows.ws2_32.sockaddr.in);
        var len_b: i32 = @sizeOf(std.os.windows.ws2_32.sockaddr.in);
        _ = ws.getsockname(a, &addr_a, &len_a);
        _ = ws.getsockname(b, &addr_b, &len_b);
        if (ws.connect(a, &addr_b, @sizeOf(std.os.windows.ws2_32.sockaddr.in)) != 0 or
            ws.connect(b, &addr_a, @sizeOf(std.os.windows.ws2_32.sockaddr.in)) != 0)
        {
            _ = ws.closesocket(a);
            _ = ws.closesocket(b);
            return null;
        }
        // `read_fd` = a (okunur), `write_fd` = b (yazılır) — `pipe()`in
        // `fds[0]`=oku/`fds[1]`=yaz sözleşmesiyle AYNI.
        return .{ @ptrFromInt(a), @ptrFromInt(b) };
    }
    var fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return null;
    return fds;
}

pub fn closeFd(fd: posix.fd_t) void {
    if (builtin.os.tag == .windows) {
        _ = io_mod.WinSock.closesocket(@intFromPtr(fd));
    } else {
        _ = std.c.close(fd);
    }
}

pub fn signalSelfPipe(fd: posix.fd_t) void {
    if (builtin.os.tag == .windows) {
        var b: [1]u8 = .{1};
        _ = io_mod.WinSock.send(@intFromPtr(fd), &b, 1, 0);
    } else {
        var signal_byte = [_]u8{1};
        _ = std.c.write(fd, &signal_byte, 1);
    }
}

pub fn readSelfPipe(fd: posix.fd_t, buf: []u8) void {
    if (builtin.os.tag == .windows) {
        _ = io_mod.WinSock.recv(@intFromPtr(fd), buf.ptr, @intCast(buf.len), 0);
    } else {
        _ = std.c.read(fd, buf.ptr, buf.len);
    }
}

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

fn sharedClientIo() std.Io {
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

    status: u16 = 0,
    response_body: []u8 = &.{},
    response_headers: []std.http.Header = &.{},
    failed: bool = false,

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

    const io = sharedClientIo();

    var client: std.http.Client = .{ .allocator = ctx.allocator, .io = io };
    defer client.deinit();

    const uri = std.Uri.parse(ctx.url) catch {
        ctx.failed = true;
        return;
    };

    var req = client.request(ctx.method, uri, .{
        .extra_headers = ctx.request_headers,
        .redirect_behavior = .unhandled,
    }) catch {
        ctx.failed = true;
        return;
    };
    defer req.deinit();

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

    var transfer_buffer: [1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var body_out: std.Io.Writer.Allocating = .init(ctx.allocator);
    _ = reader.streamRemaining(&body_out.writer) catch {
        ctx.failed = true;
        return;
    };
    ctx.response_body = body_out.toOwnedSlice() catch &.{};
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
        const key = std.mem.span(key_ptr);
        const value = std.mem.span(value_ptr);
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
) ?*anyopaque {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    const gpa = state.allocator();
    const u = url orelse return null;

    const ctx = gpa.create(RequestCtx) catch return null;
    errdefer gpa.destroy(ctx);

    const fds = makeSelfPipe() orelse return null;

    const url_copy = gpa.dupeZ(u8, std.mem.span(u)) catch {
        closeFd(fds[0]);
        closeFd(fds[1]);
        return null;
    };
    const body_copy: ?[]const u8 = if (body) |b| (gpa.dupe(u8, std.mem.span(b)) catch null) else null;
    // Güvenlik M-1: `copyHeaders`in `error.InvalidHeaderValue`si (bkz. onun
    // belge notu) İSTEĞİN TAMAMI reddedilerek ele alınır — `url_copy`
    // başarısızlığıyla AYNI "temizle, `null` dön" deseni.
    const headers_copy = copyHeaders(gpa, headers_dict) catch {
        closeFd(fds[0]);
        closeFd(fds[1]);
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

    const thread = std.Thread.spawn(.{}, workerThreadFn, .{ctx}) catch {
        ctx.destroyOwned();
        gpa.destroy(ctx);
        closeFd(fds[0]);
        closeFd(fds[1]);
        return null;
    };
    thread.detach();

    if (bridge.currentFiberScheduler()) |scheduler| {
        var buf: [1]u8 = undefined;
        _ = io_mod.nonBlockingRead(scheduler, fds[0], &buf) catch {};
    } else {
        var buf: [1]u8 = undefined;
        readSelfPipe(fds[0], &buf);
    }
    closeFd(fds[0]);

    if (ctx.failed) {
        ctx.destroyOwned();
        gpa.destroy(ctx);
        return null;
    }
    return ctx;
}

export fn nox_http_get_raw(rt: ?*anyopaque, url: ?[*:0]const u8, headers: ?*anyopaque) callconv(.c) ?*anyopaque {
    return doRequest(rt, .GET, url, null, headers);
}

export fn nox_http_post_raw(rt: ?*anyopaque, url: ?[*:0]const u8, body: ?[*:0]const u8, headers: ?*anyopaque) callconv(.c) ?*anyopaque {
    return doRequest(rt, .POST, url, body, headers);
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
        dict_mod.nox_dict_set(rt, d, 1, 1, @bitCast(@intFromPtr(key_str)), @bitCast(@intFromPtr(value_str)));
        // `nox_dict_set` KENDİ kopyasını SAKLAR (str'i doğrudan payload
        // olarak depolar, bkz. onun belge notu — "sahiplik ÇAĞIRANDAN
        // devralınır") — `dupeToNoxStr`nin ürettiği YENİ referans artık
        // dict'in mülkiyetindedir, burada AYRICA serbest bırakılmaz.
    }
    return d;
}

/// Bir C bayt dizisini `nox_rc_alloc` üzerinden YENİ, sıfırla-sonlanan bir
/// Nox `str`ine kopyalar (refcount 1 İLE başlar) — `runtime/str.zig`nin
/// `nox_str_concat`ıyla AYNI tahsis deseni.
pub fn dupeToNoxStr(rt: ?*anyopaque, bytes: []const u8) ?[*:0]u8 {
    const raw = arc.nox_rc_alloc(rt, bytes.len + 1) orelse return null;
    const out: [*]u8 = @ptrCast(raw);
    @memcpy(out[0..bytes.len], bytes);
    out[bytes.len] = 0;
    return @ptrCast(out);
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
fn testServeOnceDelayed(listen_fd: posix.fd_t, delay_ms: i64) void {
    if (builtin.os.tag == .windows) {
        const ws = io_mod.WinSock;
        const conn = ws.accept(@intFromPtr(listen_fd), null, null);
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
    const conn = std.c.accept(listen_fd, null, null);
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

    const url = try std.fmt.allocPrintSentinel(std.testing.allocator, "http://127.0.0.1:{d}/hello", .{port}, 0);
    defer std.testing.allocator.free(url);

    const resp = nox_http_get_raw(rt, url.ptr, null) orelse return error.RequestFailed;
    defer nox_http_response_free(resp);

    try std.testing.expectEqual(@as(i32, 1), nox_http_response_ok(resp));
    try std.testing.expectEqual(@as(i64, 200), nox_http_response_status(resp));

    const body = nox_http_response_body(rt, resp) orelse return error.NoBody;
    defer str_mod.nox_str_release(rt, body);
    try std.testing.expectEqualStrings("hello", std.mem.sliceTo(body, 0));

    const headers = nox_http_response_headers(rt, resp) orelse return error.NoHeaders;
    defer dict_mod.nox_dict_release(rt, headers, 1, 1);
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

    const url = try std.fmt.allocPrintSentinel(std.testing.allocator, "http://127.0.0.1:{d}/hello", .{port}, 0);
    defer std.testing.allocator.free(url);

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
    const req_task = bridge.nox_async_spawn(rt, Fn.requestOne, url.ptr).?;
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
    defer dict_mod.nox_dict_release(rt, d, 1, 1);
    const key = str_mod.nox_str_concat(rt, "X-Ec", "ho") orelse return error.ConcatFailed;
    const value = str_mod.nox_str_concat(rt, "zararli\r\nSet-Cookie: pwned=", "1") orelse return error.ConcatFailed;
    dict_mod.nox_dict_set(rt, d, 1, 1, @bitCast(@intFromPtr(key)), @bitCast(@intFromPtr(value)));

    try std.testing.expectError(error.InvalidHeaderValue, copyHeaders(std.testing.allocator, d));
}

test "Güvenlik M-1: copyHeaders CR/LF İÇEREN bir başlık ADINDA da InvalidHeaderValue döner" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const d = dict_mod.nox_dict_new(rt, 1) orelse return error.NewFailed;
    defer dict_mod.nox_dict_release(rt, d, 1, 1);
    const key = str_mod.nox_str_concat(rt, "X-Bad\r\nSet-Cookie", ": pwned=1") orelse return error.ConcatFailed;
    const value = str_mod.nox_str_concat(rt, "zararsiz", "") orelse return error.ConcatFailed;
    dict_mod.nox_dict_set(rt, d, 1, 1, @bitCast(@intFromPtr(key)), @bitCast(@intFromPtr(value)));

    try std.testing.expectError(error.InvalidHeaderValue, copyHeaders(std.testing.allocator, d));
}

test "Güvenlik M-1: copyHeaders normal (CR/LF'siz) başlıklarda HÂLÂ doğru çalışır (yanlış-pozitif YOK)" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const d = dict_mod.nox_dict_new(rt, 1) orelse return error.NewFailed;
    defer dict_mod.nox_dict_release(rt, d, 1, 1);
    const key = str_mod.nox_str_concat(rt, "X-Norm", "al") orelse return error.ConcatFailed;
    const value = str_mod.nox_str_concat(rt, "deger", "1") orelse return error.ConcatFailed;
    dict_mod.nox_dict_set(rt, d, 1, 1, @bitCast(@intFromPtr(key)), @bitCast(@intFromPtr(value)));

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
