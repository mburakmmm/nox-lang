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
const dict_mod = @import("../collections/dict.zig");
const bridge = @import("../async_rt/bridge.zig");
const io_mod = @import("../async_rt/io.zig");
const scheduler_mod = @import("../async_rt/scheduler.zig");
const fiber_mod = @import("../async_rt/fiber.zig");
const http_client = @import("http_client.zig");

fn rawRead(scheduler: ?*scheduler_mod.Scheduler, fd: posix.fd_t, buf: []u8) !usize {
    if (scheduler) |s| return io_mod.nonBlockingRead(s, fd, buf);
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

    fn init(fd: posix.fd_t, scheduler: ?*scheduler_mod.Scheduler, buffer: []u8) FiberReader {
        return .{
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
            .fd = fd,
            .scheduler = scheduler,
        };
    }

    fn stream(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *FiberReader = @alignCast(@fieldParentPtr("interface", io_r));
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        const n = rawRead(self.scheduler, self.fd, dest) catch return error.ReadFailed;
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

const ServerHandle = struct { listen_fd: posix.fd_t };

/// `127.0.0.1:port`e bağlanıp dinlemeye başlar. `port = 0` İSE OS boş bir
/// port ATAR — gerçek portu `nox_http_server_port`la öğren.
export fn nox_http_server_listen(rt: ?*anyopaque, port: i64) callconv(.c) ?*anyopaque {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
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
    if (std.c.listen(fd, 128) != 0) {
        _ = std.c.close(fd);
        return null;
    }

    const handle = state.allocator().create(ServerHandle) catch {
        _ = std.c.close(fd);
        return null;
    };
    handle.* = .{ .listen_fd = fd };
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
    _ = std.c.close(h.listen_fd);
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

const ConnCtx = struct {
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    handler: HandlerFn,
    handler_ctx: ?*anyopaque,
};

const ServerRequest = struct {
    method: []u8,
    target: []u8,
    body: []u8,
    headers: []const std.http.Header,
};

const ServerResponse = struct {
    status: u16,
    body: []u8,
    headers: []const std.http.Header,
};

fn destroyResponse(gpa: std.mem.Allocator, resp: *ServerResponse) void {
    gpa.free(resp.body);
    for (resp.headers) |h| {
        gpa.free(h.name);
        gpa.free(h.value);
    }
    if (resp.headers.len > 0) gpa.free(resp.headers);
    gpa.destroy(resp);
}

/// Bir `handler`ın DÖNECEĞİ yanıt tutamacını inşa eder — `body`/`headers`
/// BAĞIMSIZ kopyalanır (çağıranın Nox tarafındaki `str`/`dict`i bundan
/// SONRA serbest bırakılsa/değişse BİLE güvenlidir, istemci kabuğunun
/// yanıt tutamacıyla AYNI disiplin).
export fn nox_http_response_new(rt: ?*anyopaque, status: i64, body: ?[*:0]const u8, headers: ?*anyopaque) callconv(.c) ?*anyopaque {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    const gpa = state.allocator();
    const resp = gpa.create(ServerResponse) catch return null;
    const body_bytes: []u8 = if (body) |b| (gpa.dupe(u8, std.mem.span(b)) catch &.{}) else &.{};
    const hdrs = http_client.copyHeaders(gpa, headers) catch &.{};
    resp.* = .{ .status = @intCast(status), .body = body_bytes, .headers = hdrs };
    return resp;
}

export fn nox_http_request_method(rt: ?*anyopaque, req: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const r: *ServerRequest = @ptrCast(@alignCast(req orelse return null));
    return http_client.dupeToNoxStr(rt, r.method);
}

export fn nox_http_request_target(rt: ?*anyopaque, req: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const r: *ServerRequest = @ptrCast(@alignCast(req orelse return null));
    return http_client.dupeToNoxStr(rt, r.target);
}

export fn nox_http_request_body(rt: ?*anyopaque, req: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const r: *ServerRequest = @ptrCast(@alignCast(req orelse return null));
    return http_client.dupeToNoxStr(rt, r.body);
}

export fn nox_http_request_headers(rt: ?*anyopaque, req: ?*anyopaque) callconv(.c) ?*anyopaque {
    const r: *ServerRequest = @ptrCast(@alignCast(req orelse return null));
    const d = dict_mod.nox_dict_new(rt, 1) orelse return null;
    for (r.headers) |h| {
        const k = http_client.dupeToNoxStr(rt, h.name) orelse continue;
        const v = http_client.dupeToNoxStr(rt, h.value) orelse continue;
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
fn connectionEntry(arg: *anyopaque) void {
    const conn: *ConnCtx = @ptrCast(@alignCast(arg));
    const gpa = conn.allocator;
    defer gpa.destroy(conn);
    defer _ = std.c.close(conn.fd);

    const scheduler = bridge.currentFiberScheduler();

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var fiber_reader = FiberReader.init(conn.fd, scheduler, &read_buf);
    var fiber_writer = FiberWriter.init(conn.fd, scheduler, &write_buf);

    var server: std.http.Server = .init(&fiber_reader.interface, &fiber_writer.interface);
    var request = server.receiveHead() catch return;

    const method_str = gpa.dupe(u8, @tagName(request.head.method)) catch return;
    defer gpa.free(method_str);
    const target_str = gpa.dupe(u8, request.head.target) catch return;
    defer gpa.free(target_str);

    var headers_list: std.ArrayListUnmanaged(std.http.Header) = .empty;
    defer {
        for (headers_list.items) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        headers_list.deinit(gpa);
    }
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        const name_copy = gpa.dupe(u8, h.name) catch continue;
        const value_copy = gpa.dupe(u8, h.value) catch {
            gpa.free(name_copy);
            continue;
        };
        headers_list.append(gpa, .{ .name = name_copy, .value = value_copy }) catch {
            gpa.free(name_copy);
            gpa.free(value_copy);
            continue;
        };
    }

    var transfer_buffer: [1024]u8 = undefined;
    const body_reader = request.readerExpectNone(&transfer_buffer);
    var body_out: std.Io.Writer.Allocating = .init(gpa);
    defer body_out.deinit();
    _ = body_reader.streamRemaining(&body_out.writer) catch {};

    var req_handle: ServerRequest = .{
        .method = method_str,
        .target = target_str,
        .body = body_out.written(),
        .headers = headers_list.items,
    };

    const resp_payload = conn.handler(conn.handler_ctx, &req_handle);
    defer if (resp_payload) |r| destroyResponse(gpa, @ptrCast(@alignCast(r)));

    if (resp_payload) |r| {
        const resp: *ServerResponse = @ptrCast(@alignCast(r));
        request.respond(resp.body, .{
            .status = @enumFromInt(resp.status),
            .keep_alive = false,
            .extra_headers = resp.headers,
        }) catch {};
    } else {
        request.respond("Internal Server Error", .{
            .status = .internal_server_error,
            .keep_alive = false,
        }) catch {};
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
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return));
    const h: *ServerHandle = @ptrCast(@alignCast(server orelse return));
    const gpa = state.allocator();

    var served: i64 = 0;
    while (max_connections <= 0 or served < max_connections) : (served += 1) {
        const scheduler = bridge.currentFiberScheduler();
        const conn_fd = if (scheduler) |s|
            io_mod.nonBlockingAccept(s, h.listen_fd) catch break
        else
            blockingAccept(h.listen_fd) catch break;

        const conn = gpa.create(ConnCtx) catch {
            _ = std.c.close(conn_fd);
            continue;
        };
        conn.* = .{ .allocator = gpa, .fd = conn_fd, .handler = handler, .handler_ctx = handler_ctx };

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
                gpa.destroy(conn);
                _ = std.c.close(conn_fd);
                continue;
            };
            const fiber = fiber_mod.Fiber.createWithStack(gpa, connectionEntry, conn, stack) catch {
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
        log.append(std.heap.page_allocator, if (std.mem.eql(u8, r.target, "/slow")) "slow tamamlandi" else "fast tamamlandi") catch unreachable;
        return nox_http_response_new(rt_ptr, 200, "hi", null);
    }
};

const ServeArgs = struct {
    rt: ?*anyopaque,
    server: ?*anyopaque,
    max_connections: i64,
};

fn testServeEntry(arg: *anyopaque) callconv(.c) i64 {
    const args: *ServeArgs = @ptrCast(@alignCast(arg));
    nox_http_serve_raw(args.rt, args.server, TestHandlerLog.handle, null, args.max_connections);
    return 0;
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
