//! `nox.http` akışlı istemci (v2.0.69, Nova N.4): büyük gövdeleri belleğe almadan indirme ve yükleme.
//!
//! `http_client.zig` her isteği tek seferde yapar ve yanıt gövdesinin TAMAMINI belleğe alır. Burada tek bir isteğin ömrü boyunca
//! yaşayan bir işçi iş parçacığı vardır (`std.http.Client`, istek ve yanıt hep onun yığınında kalır) ve çağıran taraf ona
//! komut gönderir: `write` (yükleme parçası), `finish_send` (yüklemeyi bitir, yanıt başlığını al), `read` (en çok `n` bayt
//! gövde), `close`. Komutlar iki self-pipe üzerinden eşzamanlanır:
//!   - `cmd` borusu çağıran -> işçi: işçi bir bayt bekler (bloklayan okuma, kendi OS iş parçacığındadır).
//!   - `ready` borusu işçi -> çağıran: çağıran bir Nox FIBER'ındaysa fiber askıya alınır (başka fiber'lar ilerler),
//!     değilse sıradan bloklayan okuma yapılır (`http_client.zig`nin `doRequest` deseniyle aynı).
//! Her komut tam olarak bir `ready` baytıyla cevaplanır; böylece iş parçacıkları arasında aynı anda yalnızca biri çalışır
//! ve bellek sıralaması boru sistem çağrılarıyla sağlanır. Okuma çekme (pull) tabanlıdır: işçi yalnızca çağıran `read`
//! istediğinde ağdan okur, yani geri basınç (backpressure) doğaldır ve bellek kullanımı parça boyutuyla sınırlıdır.
//!
//! **Zaman aşımı** işlem başınadır (boşta kalma): `timeout_ms > 0` ise her komut süresince bir bekçi iş parçacığı sayar ve
//! süre dolunca açık soketi `shutdown` eder (`http_client.zig`nin `Shared.abortConnection`ı). DNS/TCP bağlantı aşaması
//! `std.http.Client` içinde olduğundan bu aşama işletim sisteminin süresiyle sınırlı kalır (N.2b).
//!
//! **Sahiplik:** `StreamCtx`i yalnızca ÇAĞIRAN taraf serbest bırakır (`nox_http_stream_close_raw`). İşçi, bir komuta son
//! `ready` baytıyla cevap verdikten sonra `ctx`ye ASLA dokunmaz; başarısızlıkta bile önce tüm kaynaklarını kapatır, sonra
//! cevap verir. Çağıran `close` çağırmazsa işçi iş parçacığı komut borusunda sonsuza dek bekler (Nox tarafı `with`/`close`
//! ile kapatmakla yükümlüdür; kapatılmayan bir akış `nox.fs` dosyaları gibi sızar).
//!
//! **Kısıtlar:** gövde yalnızca POST/PUT/PATCH ile gönderilebilir (`std.http`). Yönlendirmeler izlenmez (`http_client.zig` ile aynı).
//! Yanıt gövdesi `Content-Encoding`e göre (gzip/deflate) çözülerek verilir. `read` en az bir bayt hazır olunca döner (en çok
//! `n`), dosya gibi tam `n` doldurmaz — canlı akışlar bloklanmaz.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const asap = @import("../alloc/asap.zig");
const dict_mod = @import("../collections/dict.zig");
const bridge = @import("../async_rt/bridge.zig");
const io_mod = @import("../async_rt/io.zig");
const str_mod = @import("../str.zig");
const http = @import("http_client.zig");

const Cmd = enum(u8) { none, write, finish_send, read, close };

/// `upload_len` için: gövde yüklenmiyor (isteğe bağlı bellek-içi gövde `body` ile gönderilir).
const no_upload: i64 = -2;
/// Tek bir `read` isteğinin üst sınırı (bayt).
const max_read_chunk: usize = 16 * 1024 * 1024;

const StreamCtx = struct {
    allocator: std.mem.Allocator,
    url: [:0]const u8,
    method: std.http.Method,
    request_headers: []const std.http.Header,
    in_memory_body: ?[]const u8,
    /// -2: yükleme yok, -1: chunked yükleme, >= 0: sabit Content-Length ile yükleme.
    upload_len: i64,
    shared: *http.Shared,
    timeout_ms: u64,

    ready_r: posix.fd_t,
    ready_w: posix.fd_t,
    cmd_r: posix.fd_t,
    cmd_w: posix.fd_t,

    // çağıran -> işçi (komut gönderilmeden önce yazılır)
    cmd: Cmd = .none,
    cmd_data: []const u8 = &.{},
    read_n: usize = 0,

    // işçi -> çağıran (cevap `ready` baytından önce yazılır)
    head_received: bool = false,
    status: u16 = 0,
    response_headers: []std.http.Header = &.{},
    chunk: []u8 = &.{},
    chunk_len: usize = 0,
    failed: bool = false,
    /// 1 = zaman aşımı, 2 = diğer hata.
    err_kind: u8 = 0,
    /// İşçi çıktı (ya da çıkıyor): artık komut gönderilemez.
    dead: std.atomic.Value(bool) = .init(false),

    fn destroyOwned(self: *StreamCtx) void {
        const gpa = self.allocator;
        gpa.free(self.url);
        if (self.in_memory_body) |b| gpa.free(b);
        for (self.request_headers) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        if (self.request_headers.len > 0) gpa.free(self.request_headers);
        for (self.response_headers) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        if (self.response_headers.len > 0) gpa.free(self.response_headers);
        if (self.chunk.len > 0) gpa.free(self.chunk);
    }
};

/// Bloklayan tek bayt okuma (EINTR'da yeniden dener). `false`: boru kapandı ya da hata.
fn blockingReadByte(fd: posix.fd_t) bool {
    var b: [1]u8 = undefined;
    while (true) {
        if (builtin.os.tag == .windows) {
            const rc = io_mod.WinSock.recv(@intFromPtr(fd), &b, 1, 0);
            return rc > 0;
        }
        const rc = std.c.read(fd, &b, 1);
        if (rc > 0) return true;
        if (rc == 0) return false;
        if (posix.errno(rc) == .INTR) continue;
        return false;
    }
}

/// Fiber dışında beklemek için `fd`yi bloklayan kipe alır (fiber yolu aynı `fd`yi bloklamayan yapmış olabilir).
fn setBlocking(fd: posix.fd_t) void {
    if (builtin.os.tag == .windows) {
        var mode: u32 = 0;
        _ = io_mod.WinSock.ioctlsocket(@intFromPtr(fd), io_mod.WinSock.FIONBIO, &mode);
        return;
    }
    const current = std.c.fcntl(fd, std.c.F.GETFL);
    if (current < 0) return;
    var flags: std.c.O = @bitCast(@as(u32, @intCast(current)));
    flags.NONBLOCK = false;
    _ = std.c.fcntl(fd, std.c.F.SETFL, @as(u32, @bitCast(flags)));
}

fn markFailed(ctx: *StreamCtx) void {
    ctx.failed = true;
    ctx.err_kind = if (ctx.shared.timed_out.load(.acquire)) 1 else 2;
    ctx.dead.store(true, .release);
}

/// En az bir bayt hazır olunca döner (`0` = gövde sonu). Hata: `error.ReadFailed`.
fn readSome(r: *std.Io.Reader, buf: []u8) error{ReadFailed}!usize {
    var vec = [_][]u8{buf};
    while (true) {
        const n = r.readVec(&vec) catch |e| switch (e) {
            error.EndOfStream => return 0,
            error.ReadFailed => return error.ReadFailed,
        };
        if (n > 0) return n;
    }
}

const transfer_buffer_len: usize = 32 * 1024;

fn streamWorker(ctx: *StreamCtx) void {
    // Kaynak kapatma ve son cevap, `ctx`ye DOKUNMADAN yerel kopyalarla yapılır (bkz. modül notu: sahiplik).
    const ready_w = ctx.ready_w;
    const cmd_r = ctx.cmd_r;
    const shared = ctx.shared;
    const gpa = ctx.allocator;
    var pending_signal = true; // çağıran açılışı (open) bekliyor
    defer {
        if (pending_signal) http.signalSelfPipe(ready_w);
        http.closeFd(ready_w);
        http.closeFd(cmd_r);
    }
    defer {
        shared.done.store(true, .release);
        shared.release();
    }

    if (http.networkDenied()) {
        markFailed(ctx);
        return;
    }

    const io = http.sharedClientIo();
    var request_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer request_arena.deinit();
    var client: std.http.Client = .{ .allocator = request_arena.allocator(), .io = io };
    defer client.deinit();

    const uri = std.Uri.parse(ctx.url) catch {
        markFailed(ctx);
        return;
    };
    if (comptime builtin.os.tag == .ios) {
        if (!http.loadIosCa(&client)) {
            markFailed(ctx);
            return;
        }
    }
    var android_host: [std.Io.net.HostName.max_len]u8 = undefined;
    var android_ip: [64]u8 = undefined;
    const dialed: ?*std.http.Client.Connection = if (comptime builtin.abi.isAndroid())
        http.androidDial(&client, uri, &android_host, android_ip[0..])
    else
        null;

    var req = client.request(ctx.method, uri, .{
        .extra_headers = ctx.request_headers,
        .redirect_behavior = .unhandled,
        .connection = dialed,
    }) catch {
        markFailed(ctx);
        return;
    };
    defer req.deinit();
    if (req.connection) |conn| shared.setHandle(http.socketHandleToUsize(conn.stream_reader.stream.socket.handle));
    defer shared.clearHandle();

    // ---- istek gövdesi ----
    var body_writer: std.http.BodyWriter = undefined;
    const uploading = ctx.upload_len != no_upload;
    if (uploading) {
        req.transfer_encoding = if (ctx.upload_len < 0) .chunked else .{ .content_length = @intCast(ctx.upload_len) };
        body_writer = req.sendBodyUnflushed(&.{}) catch {
            markFailed(ctx);
            return;
        };
        // Başlığı hemen gönder: sunucu yükleme sürerken bile bağlantıyı görür.
        const conn = req.connection orelse {
            markFailed(ctx);
            return;
        };
        conn.flush() catch {
            markFailed(ctx);
            return;
        };
    } else if (ctx.in_memory_body) |b| {
        req.transfer_encoding = .{ .content_length = b.len };
        var bw = req.sendBodyUnflushed(&.{}) catch {
            markFailed(ctx);
            return;
        };
        bw.writer.writeAll(b) catch {
            markFailed(ctx);
            return;
        };
        bw.end() catch {
            markFailed(ctx);
            return;
        };
        const conn = req.connection orelse {
            markFailed(ctx);
            return;
        };
        conn.flush() catch {
            markFailed(ctx);
            return;
        };
    } else {
        req.sendBodiless() catch {
            markFailed(ctx);
            return;
        };
    }

    // ---- yanıt (başlık alındıktan sonra dolar) ----
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response: std.http.Client.Response = undefined;
    var decompress: std.http.Decompress = undefined;
    var reader: *std.Io.Reader = undefined;
    var transfer_buffer: ?[]u8 = null;
    var decompress_buffer: []u8 = &.{};
    defer {
        if (transfer_buffer) |b| gpa.free(b);
        if (decompress_buffer.len > 0) gpa.free(decompress_buffer);
    }

    if (!uploading) {
        if (!receiveHead(ctx, &req, &redirect_buffer, &response, &decompress, &reader, &transfer_buffer, &decompress_buffer)) return;
    }

    // Açılış tamam: başlık (indirme) ya da hazır gövde yazıcısı (yükleme).
    pending_signal = false;
    http.signalSelfPipe(ready_w);

    var uploaded: usize = 0;
    while (true) {
        if (!blockingReadByte(cmd_r)) {
            // Çağıran boruyu kapattı (close göndermeden): temizlik, cevap beklenmiyor.
            return;
        }
        switch (ctx.cmd) {
            .none => {},
            .close => {
                pending_signal = true; // kapatma teardown bitince onaylanır
                return;
            },
            .write => {
                if (!uploading or ctx.head_received) {
                    markFailed(ctx);
                    pending_signal = true;
                    return;
                }
                // Sabit Content-Length: fazla yazma da eksik bitirme de `std.http` içinde assert'e çarpar; burada hata olarak bildirilir.
                if (ctx.upload_len >= 0 and uploaded + ctx.cmd_data.len > @as(usize, @intCast(ctx.upload_len))) {
                    markFailed(ctx);
                    pending_signal = true;
                    return;
                }
                uploaded += ctx.cmd_data.len;
                body_writer.writer.writeAll(ctx.cmd_data) catch {
                    markFailed(ctx);
                    pending_signal = true;
                    return;
                };
                body_writer.flush() catch {
                    markFailed(ctx);
                    pending_signal = true;
                    return;
                };
                http.signalSelfPipe(ready_w);
            },
            .finish_send => {
                if (!uploading or ctx.head_received) {
                    markFailed(ctx);
                    pending_signal = true;
                    return;
                }
                if (ctx.upload_len >= 0 and uploaded != @as(usize, @intCast(ctx.upload_len))) {
                    markFailed(ctx);
                    pending_signal = true;
                    return;
                }
                body_writer.end() catch {
                    markFailed(ctx);
                    pending_signal = true;
                    return;
                };
                const conn = req.connection orelse {
                    markFailed(ctx);
                    pending_signal = true;
                    return;
                };
                conn.flush() catch {
                    markFailed(ctx);
                    pending_signal = true;
                    return;
                };
                if (!receiveHead(ctx, &req, &redirect_buffer, &response, &decompress, &reader, &transfer_buffer, &decompress_buffer)) {
                    pending_signal = true;
                    return;
                }
                http.signalSelfPipe(ready_w);
            },
            .read => {
                if (!ctx.head_received) {
                    markFailed(ctx);
                    pending_signal = true;
                    return;
                }
                if (ctx.chunk.len < ctx.read_n) {
                    if (ctx.chunk.len > 0) gpa.free(ctx.chunk);
                    ctx.chunk = &.{};
                    ctx.chunk = gpa.alloc(u8, ctx.read_n) catch {
                        markFailed(ctx);
                        pending_signal = true;
                        return;
                    };
                }
                const n = readSome(reader, ctx.chunk[0..ctx.read_n]) catch {
                    ctx.chunk_len = 0;
                    markFailed(ctx);
                    pending_signal = true;
                    return;
                };
                // Bekçi bağlantıyı `shutdown` ettiğinde okuyucu temiz bir gövde sonu gibi `0` görebilir: zaman aşımı sessizce
                // "gövde bitti"ye dönüşmesin.
                if (n == 0 and (shared.timed_out.load(.acquire) or http.responseBodyTruncated(&req, ctx.method, response.head.status))) {
                    ctx.chunk_len = 0;
                    markFailed(ctx);
                    pending_signal = true;
                    return;
                }
                ctx.chunk_len = n;
                http.signalSelfPipe(ready_w);
            },
        }
    }
}

/// Yanıt başlığını alır, `ctx`ye durum/başlıkları kopyalar ve gövde okuyucusunu kurar. Başarısızlıkta `markFailed` çağrılır.
fn receiveHead(
    ctx: *StreamCtx,
    req: *std.http.Client.Request,
    redirect_buffer: []u8,
    response: *std.http.Client.Response,
    decompress: *std.http.Decompress,
    reader: **std.Io.Reader,
    transfer_buffer: *?[]u8,
    decompress_buffer: *[]u8,
) bool {
    const gpa = ctx.allocator;
    response.* = req.receiveHead(redirect_buffer) catch {
        markFailed(ctx);
        return false;
    };
    ctx.status = @intFromEnum(response.head.status);

    var headers_list: std.ArrayListUnmanaged(std.http.Header) = .empty;
    var it = response.head.iterateHeaders();
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
    ctx.response_headers = headers_list.toOwnedSlice(gpa) catch &.{};

    decompress_buffer.* = switch (response.head.content_encoding) {
        .identity => &.{},
        .deflate, .gzip => gpa.alloc(u8, std.compress.flate.max_window_len) catch {
            markFailed(ctx);
            return false;
        },
        .zstd, .compress => {
            markFailed(ctx);
            return false;
        },
    };
    transfer_buffer.* = gpa.alloc(u8, transfer_buffer_len) catch {
        markFailed(ctx);
        return false;
    };
    reader.* = response.readerDecompressing(transfer_buffer.*.?, decompress, decompress_buffer.*);
    ctx.head_received = true;
    return true;
}

fn streamWatchdog(shared: *http.Shared, timeout_ms: u64) void {
    defer shared.release();
    var elapsed: u64 = 0;
    var last_epoch: u32 = shared.epoch.load(.acquire);
    while (!shared.done.load(.acquire)) {
        http.sleepMs(5);
        const ep = shared.epoch.load(.acquire);
        if (ep != last_epoch) {
            last_epoch = ep;
            elapsed = 0;
        }
        if (!shared.armed.load(.acquire)) {
            elapsed = 0;
            continue;
        }
        elapsed += 5;
        if (elapsed >= timeout_ms) {
            shared.timed_out.store(true, .release);
            shared.abortConnection();
        }
    }
}

// ---- çağıran taraf ----

fn waitReady(ctx: *StreamCtx) void {
    if (bridge.currentFiberScheduler()) |scheduler| {
        var buf: [1]u8 = undefined;
        _ = io_mod.nonBlockingReadOnce(scheduler, ctx.ready_r, &buf) catch {};
    } else {
        setBlocking(ctx.ready_r);
        _ = blockingReadByte(ctx.ready_r);
    }
}

/// Bir komutu işçiye gönderir ve cevabı bekler; `true`: başarılı.
fn roundTrip(ctx: *StreamCtx, cmd: Cmd) bool {
    if (ctx.failed or ctx.dead.load(.acquire)) return false;
    ctx.cmd = cmd;
    if (ctx.timeout_ms > 0) {
        _ = ctx.shared.epoch.fetchAdd(1, .acq_rel);
        ctx.shared.armed.store(true, .release);
    }
    http.signalSelfPipe(ctx.cmd_w);
    waitReady(ctx);
    if (ctx.timeout_ms > 0) ctx.shared.armed.store(false, .release);
    return !ctx.failed;
}

fn fail_cleanup(g: std.mem.Allocator, c: *StreamCtx, r: [2]posix.fd_t, cm: [2]posix.fd_t) void {
    http.closeFd(r[0]);
    http.closeFd(r[1]);
    http.closeFd(cm[0]);
    http.closeFd(cm[1]);
    g.destroy(c);
}

/// İşçi ya da bekçi iş parçacığı başlatılamadı: tüm payları bırakıp bağlamı yıkar.
fn abort_spawn(c: *StreamCtx, g: std.mem.Allocator, r: [2]posix.fd_t, cm: [2]posix.fd_t, watchdog_never_started: bool) void {
    c.shared.done.store(true, .release);
    c.shared.release(); // işçi payı
    if (watchdog_never_started) c.shared.release(); // bekçi payı (hiç başlamadı)
    c.shared.release(); // çağıran payı
    c.destroyOwned();
    fail_cleanup(g, c, r, cm);
}

fn openStream(
    rt: ?*anyopaque,
    method: std.http.Method,
    url: ?[*:0]const u8,
    headers_dict: ?*anyopaque,
    body: ?[*:0]const u8,
    upload_len: i64,
    timeout_ms: i64,
) ?*anyopaque {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    const gpa = state.allocator();
    const u = url orelse return null;

    const ctx = gpa.create(StreamCtx) catch return null;
    const ready = http.makeSelfPipe() orelse {
        gpa.destroy(ctx);
        return null;
    };
    const cmdp = http.makeSelfPipe() orelse {
        http.closeFd(ready[0]);
        http.closeFd(ready[1]);
        gpa.destroy(ctx);
        return null;
    };
    const url_copy = gpa.dupeZ(u8, str_mod.nox_str_slice(u)) catch {
        fail_cleanup(gpa, ctx, ready, cmdp);
        return null;
    };
    const body_copy: ?[]const u8 = if (body) |b| (gpa.dupe(u8, str_mod.nox_str_slice(b)) catch {
        gpa.free(url_copy);
        fail_cleanup(gpa, ctx, ready, cmdp);
        return null;
    }) else null;
    const headers_copy = http.copyHeaders(gpa, headers_dict) catch {
        gpa.free(url_copy);
        if (body_copy) |b| gpa.free(b);
        fail_cleanup(gpa, ctx, ready, cmdp);
        return null;
    };
    const timeout: u64 = if (timeout_ms > 0) @intCast(timeout_ms) else 0;
    const shared = std.heap.page_allocator.create(http.Shared) catch {
        gpa.free(url_copy);
        if (body_copy) |b| gpa.free(b);
        for (headers_copy) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        if (headers_copy.len > 0) gpa.free(headers_copy);
        fail_cleanup(gpa, ctx, ready, cmdp);
        return null;
    };
    // Paylar: işçi + çağıran (`close`) (+ bekçi).
    shared.* = .{ .refs = .init(if (timeout > 0) 3 else 2) };

    ctx.* = .{
        .allocator = gpa,
        .url = url_copy,
        .method = method,
        .request_headers = headers_copy,
        .in_memory_body = body_copy,
        .upload_len = upload_len,
        .shared = shared,
        .timeout_ms = timeout,
        .ready_r = ready[0],
        .ready_w = ready[1],
        .cmd_r = cmdp[0],
        .cmd_w = cmdp[1],
    };

    if (timeout > 0) {
        const wd = std.Thread.spawn(.{}, streamWatchdog, .{ shared, timeout }) catch {
            abort_spawn(ctx, gpa, ready, cmdp, true);
            return null;
        };
        wd.detach();
    }
    const worker = std.Thread.spawn(.{}, streamWorker, .{ctx}) catch {
        if (timeout > 0) {
            // Bekçi başladı: `done` görünce kendi payını bırakır.
            shared.done.store(true, .release);
            shared.release(); // işçi payı
            shared.release(); // çağıran payı
            ctx.destroyOwned();
            fail_cleanup(gpa, ctx, ready, cmdp);
        } else {
            abort_spawn(ctx, gpa, ready, cmdp, false);
        }
        return null;
    };
    worker.detach();

    // Açılış cevabı (başlık alındı / yükleme hazır / hata).
    if (ctx.timeout_ms > 0) {
        _ = shared.epoch.fetchAdd(1, .acq_rel);
        shared.armed.store(true, .release);
    }
    waitReady(ctx);
    if (ctx.timeout_ms > 0) shared.armed.store(false, .release);
    return ctx;
}

/// `method`: GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS. `has_body != 0`: `body` bellek-içi gövdedir (yalnızca POST/PUT/PATCH).
/// `upload_len`: -2 = akışlı yükleme yok, -1 = chunked yükleme, >= 0 = sabit Content-Length ile yükleme (yalnızca POST/PUT/PATCH;
/// `has_body` ile birlikte kullanılamaz). Geçersiz istek `null`; ağ hatası başarısız bir tutamaç döner (`ok == 0`, `error_kind`).
export fn nox_http_stream_open_raw(
    rt: ?*anyopaque,
    method: ?[*:0]const u8,
    url: ?[*:0]const u8,
    headers: ?*anyopaque,
    body: ?[*:0]const u8,
    has_body: i32,
    upload_len: i64,
    timeout_ms: i64,
) callconv(.c) ?*anyopaque {
    const m = http.parseMethod(str_mod.nox_str_slice(method orelse return null)) orelse return null;
    if (upload_len < no_upload) return null;
    if ((has_body != 0 or upload_len != no_upload) and !m.requestHasBody()) return null;
    if (has_body != 0 and upload_len != no_upload) return null;
    return openStream(rt, m, url, headers, if (has_body != 0) body else null, upload_len, timeout_ms);
}

/// 0 = başarılı, 1 = zaman aşımı, 2 = diğer hata, 3 = geçersiz istek (tutamaç `null`).
export fn nox_http_stream_error_kind(h: ?*anyopaque) callconv(.c) i64 {
    const ctx: *StreamCtx = @ptrCast(@alignCast(h orelse return 3));
    if (!ctx.failed) return 0;
    return ctx.err_kind;
}

export fn nox_http_stream_ok(h: ?*anyopaque) callconv(.c) i32 {
    const ctx: *StreamCtx = @ptrCast(@alignCast(h orelse return 0));
    return if (ctx.failed) 0 else 1;
}

/// Yanıt durum kodu; yükleme `finish` edilene kadar 0.
export fn nox_http_stream_status(h: ?*anyopaque) callconv(.c) i64 {
    const ctx: *StreamCtx = @ptrCast(@alignCast(h orelse return 0));
    return ctx.status;
}

/// Yanıt başlıkları (başlık alınmadıysa boş sözlük); `nox_http_response_headers` ile aynı biçim.
export fn nox_http_stream_headers(rt: ?*anyopaque, h: ?*anyopaque) callconv(.c) ?*anyopaque {
    const ctx: *StreamCtx = @ptrCast(@alignCast(h orelse return null));
    const d = dict_mod.nox_dict_new(rt, 1) orelse return null;
    for (ctx.response_headers) |header| {
        const key_str = http.dupeToNoxStr(rt, header.name) orelse continue;
        const value_str = http.dupeToNoxStr(rt, header.value) orelse continue;
        dict_mod.nox_dict_set(rt, d, 1, 1, 0, @bitCast(@intFromPtr(key_str)), @bitCast(@intFromPtr(value_str)));
    }
    return d;
}

/// En fazla `n` bayt gövde (en az bir bayt hazır olunca döner); gövde bitince boş `str`. Hata: boş `str` ve `ok == 0`.
export fn nox_http_stream_read_raw(rt: ?*anyopaque, h: ?*anyopaque, n: i64) callconv(.c) ?[*:0]u8 {
    const ctx: *StreamCtx = @ptrCast(@alignCast(h orelse return http.dupeToNoxStr(rt, "")));
    if (n <= 0) return http.dupeToNoxStr(rt, "");
    ctx.read_n = @min(@as(usize, @intCast(n)), max_read_chunk);
    if (!roundTrip(ctx, .read)) return http.dupeToNoxStr(rt, "");
    return http.dupeToNoxStr(rt, ctx.chunk[0..ctx.chunk_len]);
}

/// Yükleme parçası gönderir (`content`in tüm baytları, gömülü NUL dahil). `1` = başarılı.
export fn nox_http_stream_write_raw(h: ?*anyopaque, content: ?[*:0]const u8) callconv(.c) i32 {
    const ctx: *StreamCtx = @ptrCast(@alignCast(h orelse return 0));
    const c = content orelse return 0;
    ctx.cmd_data = str_mod.nox_str_slice(c);
    const ok = roundTrip(ctx, .write);
    ctx.cmd_data = &.{};
    return if (ok) 1 else 0;
}

/// Yüklemeyi bitirir ve yanıt başlığını alır. `1` = başarılı.
export fn nox_http_stream_finish_raw(h: ?*anyopaque) callconv(.c) i32 {
    const ctx: *StreamCtx = @ptrCast(@alignCast(h orelse return 0));
    return if (roundTrip(ctx, .finish_send)) 1 else 0;
}

/// Bağlantıyı kapatır ve tutamacı serbest bırakır (çift çağrı YOK: Nox sınıfı bunu `closed` bayrağıyla korur).
export fn nox_http_stream_close_raw(h: ?*anyopaque) callconv(.c) void {
    const ctx: *StreamCtx = @ptrCast(@alignCast(h orelse return));
    if (!ctx.dead.load(.acquire)) {
        ctx.cmd = .close;
        if (ctx.timeout_ms > 0) ctx.shared.armed.store(false, .release);
        http.signalSelfPipe(ctx.cmd_w);
        waitReady(ctx);
    }
    const shared = ctx.shared;
    http.closeFd(ctx.ready_r);
    http.closeFd(ctx.cmd_w);
    const gpa = ctx.allocator;
    ctx.destroyOwned();
    gpa.destroy(ctx);
    shared.release();
}
