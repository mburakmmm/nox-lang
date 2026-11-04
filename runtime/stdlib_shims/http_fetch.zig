//! `wasm32-freestanding --asyncify`: `nox.http` istemcisinin host `fetch`ine dayanan gerçek uygulaması (spec §3.351, ADR-016). `http_wasm.zig`nin "ağ yeteneği yok" saplamalarının
//! yerine, host `nox_host_caps_set(CAP_FETCH)` ile yeteneği açtığında devreye girer.
//!
//! **Protokol (hiçbir `nox_host` import'u yoktur, yalnızca dışa aktarımlar):**
//!  1. Host `_start`tan önce `nox_host_caps_set(1)` çağırır (yetenek açık). Çağırmazsa istemci çağrıları eskisi gibi `HttpCapabilityError` verir.
//!  2. Nox kodu `nox.http.get/post/request` çağırınca istek bir tabloya yazılır ve çağıran fiber `suspendForHost` ile beklemeye alınır (ana akış doğrudan askıya alınır);
//!     başka fiber'lar çalışmaya devam eder. Hazır fiber kalmayınca zamanlayıcı TÜM programı `asyncify.hostSuspend` ile host'a döndürür: `_start`/`nox_host_resume` çıkış
//!     bildirmeden döner, `nox_host_status() == 1` olur.
//!  3. Host `nox_host_fetch_pending` ile yeni istekleri alır (serileştirilmiş), `fetch` başlatır; biten her istek için `nox_host_fetch_complete` çağırır (fiber `markReady`
//!     ile uyandırılır) ve `nox_host_resume()` ile programı sürdürür. Program bitince `nox_host_resume` host'un `exit` import'unu çağırır (JS tarafında `NoxExit`).
//!
//! **Akışlı istemci (`stream_*`, v2.0.152):** indirme akışı host'ta `fetch` yanıtının `ReadableStream` okuyucusudur; her `read_raw` bir `read` isteği olarak host'a gider
//! (geri basınç doğal: yalnızca istenince okunur). Yükleme (`stream_upload`) çalışma zamanında tamponlanır ve `finish` ile tek istek olarak gönderilir (`fetch` yükleme akışı
//! her tarayıcıda yoktur); `write` bloklamaz. İstek kayıtları bir `kind` taşır: 0 fetch, 1 stream_open, 2 stream_read, 3 stream_close (yanıtsız). Küresel durum (istek tablosu, yetenek maskesi) vardır; bu,
//! `wasm_vfs.zig` ve `nox.os` ortam tablosu gibi, tek örnekli freestanding modülün host köprüsüdür (AGENTS §2.6'nın belgelenmiş dar istisnası).

const std = @import("std");
const dict_mod = @import("../collections/dict.zig");
const str_mod = @import("../str.zig");
const shim_util = @import("shim_util.zig");
const bridge = @import("../async_rt/bridge.zig");
const asyncify = @import("../async_rt/asyncify.zig");
const scheduler_mod = @import("../async_rt/scheduler.zig");
const fiber_mod = @import("../async_rt/fiber.zig");
const wasm_entry = @import("../wasm_entry.zig");
const host = @import("../wasm_host.zig");
const wasm_options = @import("wasm_options");
/// `--threads` modülleri çağıran iş parçacığını bloke eden eşzamanlı ağ import'unu kullanır (`nox_host.net_fetch`, spec §3.355); asyncify'da askıya alma kullanılır.
const sync_net = wasm_options.threads;

const gpa = std.heap.page_allocator;

pub const CAP_FETCH: u32 = 1;
/// Bit 1: ham TCP (host `connect`: Node `net`/`tls`; tarayıcıda yok). `smtp`, `tls` ve veritabanı sürücüleri için (spec §3.357).
pub const CAP_TCP: u32 = 2;
/// Bit 2: alt süreç çalıştırma (host `spawn`; `nox.process`, spec §3.359).
pub const CAP_PROCESS: u32 = 4;
/// Bit 3: HTTP sunucusu (host dinler, istekleri modüle iletir; `nox.http.serve`, spec §3.360).
pub const CAP_SERVE: u32 = 8;
var g_caps: u32 = 0;
var g_next_id: u32 = 1;
var g_reqs: std.ArrayListUnmanaged(*Request) = .empty;

/// İstek türü (host'a giden kaydın `kind` alanı): 0 tam yanıt `fetch`i, 1 akış açma (başlıklar gelince döner, gövde host'ta okuyucuda kalır), 2 akıştan bir parça okuma,
/// 3 akışı kapatma (yanıtsız, "detached"), 4-7 WebSocket (`websocket_wasm.zig`): açma, gönderme (yanıtsız), alma, kapatma (yanıtsız).
pub const Kind = enum(u32) { fetch = 0, stream_open = 1, stream_read = 2, stream_close = 3, ws_open = 4, ws_send = 5, ws_recv = 6, ws_close = 7, tcp_open = 8, tcp_write = 9, tcp_read = 10, tcp_starttls = 11, tcp_close = 12, proc_run = 13, http_listen = 14, http_unlisten = 15 };

pub const Request = struct {
    id: u32,
    kind: Kind = .fetch,
    /// `stream_read`/`stream_close`: hedef akışın host kimliği (açan `stream_open` isteğinin `id`si).
    stream: u32 = 0,
    /// `stream_read`: istenen en çok bayt; diğerlerinde zaman aşımı (ms).
    arg: u32 = 0,
    handed_out: bool = false,
    done: bool = false,
    /// Yanıt beklenmez (`stream_close`): host'a verilince tablodan atılır.
    detached: bool = false,
    method: []u8,
    url: []u8,
    headers: []u8,
    body: []u8,
    has_body: bool,
    timeout_ms: u32,
    sched: ?*scheduler_mod.Scheduler,
    fiber: ?*fiber_mod.Fiber,
    resp: ?*Response = null,
};

/// Bir yanıt tutamacı (`nox_http_response_*`): gövde ve `Ad: değer\n` satırlarından oluşan başlık metni.
pub const Response = struct {
    ok: bool,
    status: i64,
    error_kind: i64,
    body: []u8,
    headers: []u8,
};

pub fn serveAvailable() bool {
    return g_caps & CAP_SERVE != 0;
}

pub fn processAvailable() bool {
    return g_caps & CAP_PROCESS != 0;
}

pub fn tcpAvailable() bool {
    return g_caps & CAP_TCP != 0;
}

pub fn available() bool {
    // `--threads`: yetenek host'un `net_fetch` import'una verdiği yanıtla anlaşılır (-1 = yok); her zaman denenir.
    if (comptime sync_net) return true;
    return g_caps & CAP_FETCH != 0;
}

fn containsCrOrLf(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "\r\n") != null;
}

/// Başlık sözlüğünü `Ad: değer\n` satırlarına çevirir (çağıran serbest bırakır). CR/LF içeren ad/değer isteği reddeder (`null`).
fn headersToText(headers_dict: ?*anyopaque) ?[]u8 {
    const d: *dict_mod.Dict = @ptrCast(@alignCast(headers_dict orelse return gpa.alloc(u8, 0) catch null));
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (d.entries.items) |e| {
        const key_ptr: [*:0]const u8 = @ptrFromInt(@as(usize, @intCast(@as(u64, @bitCast(e.key)))));
        const value_ptr: [*:0]const u8 = @ptrFromInt(@as(usize, @intCast(@as(u64, @bitCast(e.value)))));
        const key = str_mod.nox_str_slice(key_ptr);
        const value = str_mod.nox_str_slice(value_ptr);
        if (containsCrOrLf(key) or containsCrOrLf(value) or std.mem.indexOfScalar(u8, key, ':') != null) {
            out.deinit(gpa);
            return null;
        }
        out.appendSlice(gpa, key) catch {
            out.deinit(gpa);
            return null;
        };
        out.appendSlice(gpa, ": ") catch {
            out.deinit(gpa);
            return null;
        };
        out.appendSlice(gpa, value) catch {
            out.deinit(gpa);
            return null;
        };
        out.append(gpa, '\n') catch {
            out.deinit(gpa);
            return null;
        };
    }
    return out.toOwnedSlice(gpa) catch null;
}

fn isBodyMethod(m: []const u8) bool {
    return std.mem.eql(u8, m, "POST") or std.mem.eql(u8, m, "PUT") or std.mem.eql(u8, m, "PATCH");
}

fn knownMethod(m: []const u8) bool {
    const names = [_][]const u8{ "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS" };
    for (names) |n| if (std.mem.eql(u8, m, n)) return true;
    return false;
}

fn destroyRequest(r: *Request) void {
    gpa.free(r.method);
    gpa.free(r.url);
    gpa.free(r.headers);
    gpa.free(r.body);
    gpa.destroy(r);
}

pub const Spec = struct {
    kind: Kind = .fetch,
    stream: u32 = 0,
    arg: u32 = 0,
    method: []const u8 = "",
    url: []const u8 = "",
    headers_text: []const u8 = "",
    body: ?[]const u8 = null,
    timeout_ms: i64 = 0,
};

fn clampMs(ms: i64) u32 {
    return if (ms > 0) @intCast(@min(ms, std.math.maxInt(u32))) else 0;
}

/// İsteği tabloya yazar (kopyalar). Tahsis hatasında `null`.
pub fn submit(spec: Spec, detached: bool) ?*Request {
    const method = gpa.dupe(u8, spec.method) catch return null;
    const url = gpa.dupe(u8, spec.url) catch {
        gpa.free(method);
        return null;
    };
    const headers = gpa.dupe(u8, spec.headers_text) catch {
        gpa.free(method);
        gpa.free(url);
        return null;
    };
    const body = gpa.dupe(u8, spec.body orelse "") catch {
        gpa.free(method);
        gpa.free(url);
        gpa.free(headers);
        return null;
    };
    const req = gpa.create(Request) catch {
        gpa.free(method);
        gpa.free(url);
        gpa.free(headers);
        gpa.free(body);
        return null;
    };
    req.* = .{
        .id = g_next_id,
        .kind = spec.kind,
        .stream = spec.stream,
        .arg = if (spec.kind == .stream_read or spec.kind == .ws_recv or spec.kind == .tcp_read) spec.arg else clampMs(spec.timeout_ms),
        .detached = detached,
        .method = method,
        .url = url,
        .headers = headers,
        .body = body,
        .has_body = spec.body != null,
        .timeout_ms = clampMs(spec.timeout_ms),
        .sched = bridge.currentFiberScheduler(),
        .fiber = bridge.currentFiber(),
    };
    g_next_id +%= 1;
    if (g_next_id == 0) g_next_id = 1;
    g_reqs.append(gpa, req) catch {
        destroyRequest(req);
        return null;
    };
    return req;
}

/// Sonuç gelene kadar bekler (fiber ise `suspendForHost`, ana akış ise doğrudan `hostSuspend`), isteği tablodan çıkarır ve yanıtı döner (sahiplik çağırana geçer).
pub fn waitFor(req: *Request) ?*Response {
    if (req.fiber != null and req.sched != null) {
        while (!req.done) req.sched.?.suspendForHost();
    } else {
        // Ana akış (fiber değil): programı doğrudan host'a döndür; başka fiber çalışmaz (yerel istemcinin ana akışta bloklamasıyla aynı anlam).
        while (!req.done) asyncify.hostSuspend();
    }
    for (g_reqs.items, 0..) |r, i| {
        if (r == req) {
            _ = g_reqs.orderedRemove(i);
            break;
        }
    }
    const resp = req.resp;
    destroyRequest(req);
    return resp;
}

/// Tam yanıtlı istek (`get`/`post`/`request`). Geçersiz istek (bilinmeyen metod, gövdesiz metodda gövde, bozuk başlık) ya da tahsis hatası için `null` (yerel istemcideki gibi:
/// hata türü 3).
pub fn request(method: []const u8, url: []const u8, body: ?[]const u8, headers: ?*anyopaque, timeout_ms: i64) ?*Response {
    if (!knownMethod(method)) return null;
    if (body != null and !isBodyMethod(method)) return null;
    const htext = headersToText(headers) orelse return null;
    defer gpa.free(htext);
    if (comptime sync_net) return requestSync(method, url, body, htext, timeout_ms);
    const req = submit(.{ .method = method, .url = url, .headers_text = htext, .body = body, .timeout_ms = timeout_ms }, false) orelse return null;
    return waitFor(req);
}

/// `--threads`: isteği tek kayıt olarak host'a verir, çağıran iş parçacığı yanıt gelene kadar BLOKE olur (havuzun diğer işçileri çalışır). Yanıt: `u32 status`, `u32 başlık
/// uzunluğu`, başlıklar, gövde. Host `-1` dönerse ağ yeteneği yoktur (`error_kind` 4 -> `HttpCapabilityError`).
fn requestSync(method: []const u8, url: []const u8, body: ?[]const u8, htext: []const u8, timeout_ms: i64) ?*Response {
    var rec: std.ArrayListUnmanaged(u8) = .empty;
    defer rec.deinit(gpa);
    if (!(putU32(&rec, 0) and putU32(&rec, 0) and putU32(&rec, 0) and putU32(&rec, clampMs(timeout_ms)) and putU32(&rec, @intFromBool(body != null)) and putBytes(&rec, method) and putBytes(&rec, url) and putBytes(&rec, htext) and putBytes(&rec, body orelse ""))) return null;
    const resp = gpa.create(Response) catch return null;
    resp.* = .{ .ok = false, .status = 0, .error_kind = 2, .body = &.{}, .headers = &.{} };
    const n = host.net_fetch(rec.items.ptr, rec.items.len);
    if (n < 0) {
        resp.error_kind = switch (n) {
            -1 => 4,
            -2 => 0,
            -3 => 1,
            else => 2,
        };
        return resp;
    }
    const buf = gpa.alloc(u8, @max(@as(usize, @intCast(n)), 1)) catch {
        gpa.destroy(resp);
        return null;
    };
    defer gpa.free(buf);
    const got: usize = @intCast(host.net_read(buf.ptr, @intCast(n)));
    if (got < 8) return resp;
    const status = std.mem.readInt(u32, buf[0..4], .little);
    const hlen = std.mem.readInt(u32, buf[4..8], .little);
    if (8 + hlen > got) return resp;
    resp.headers = gpa.dupe(u8, buf[8 .. 8 + hlen]) catch return resp;
    resp.body = gpa.dupe(u8, buf[8 + hlen .. got]) catch return resp;
    resp.ok = true;
    resp.status = status;
    resp.error_kind = 0;
    return resp;
}

// ---- Akışlı istemci --------------------------------------------------------------------------------------------------------------------------------

/// `read_raw` tek seferde host'tan en çok bu kadar bayt ister (host bir parçayı bölmez; fazlası `leftover`da kalır).
const read_request_bytes: u32 = 256 * 1024;

/// Bir akış tutamacı (`nox_http_stream_*`).
pub const Stream = struct {
    /// Başarısızlık sonrası `ok == false`; `error_kind` `Response.error_kind` ile aynı anlamda (1 zaman aşımı, 0/2 bağlantı/diğer).
    ok: bool = true,
    error_kind: i64 = 0,
    status: i64 = 0,
    /// Yanıt başlıkları (`Ad: değer\n` satırları).
    resp_headers: []u8 = &.{},
    /// Host'taki açık akışın kimliği (0 = yok / kapandı).
    host_id: u32 = 0,
    eof: bool = false,
    /// Okunmuş ama henüz verilmemiş baytlar.
    leftover: std.ArrayListUnmanaged(u8) = .empty,
    leftover_off: usize = 0,
    // Yükleme akışı: istek `finish` ile tek seferde gönderilir.
    uploading: bool = false,
    upload_len: i64 = -2,
    upload: std.ArrayListUnmanaged(u8) = .empty,
    method: []u8 = &.{},
    url: []u8 = &.{},
    req_headers: []u8 = &.{},
    timeout_ms: i64 = 0,
};

fn failStream(st: *Stream, kind: i64) void {
    st.ok = false;
    st.error_kind = kind;
}

/// İsteği host'a gönderip başlıkların gelmesini bekler; sonucu `st`ye yazar. `body`: yüklenecek gövde (yoksa `null`).
fn openRemote(st: *Stream, body: ?[]const u8) void {
    const req = submit(.{ .kind = .stream_open, .method = st.method, .url = st.url, .headers_text = st.req_headers, .body = body, .timeout_ms = st.timeout_ms }, false) orelse {
        failStream(st, 2);
        return;
    };
    const id = req.id;
    const resp = waitFor(req) orelse {
        failStream(st, 2);
        return;
    };
    defer gpa.destroy(resp);
    defer gpa.free(resp.body);
    if (!resp.ok) {
        gpa.free(resp.headers);
        failStream(st, resp.error_kind);
        return;
    }
    if (st.resp_headers.len > 0) gpa.free(st.resp_headers);
    st.resp_headers = resp.headers;
    st.status = resp.status;
    st.host_id = id;
}

/// `nox_http_stream_open_raw`. Geçersiz istekte `null` (hata türü 3).
pub fn streamOpen(method: []const u8, url: []const u8, headers: ?*anyopaque, body: ?[]const u8, upload_len: i64, timeout_ms: i64) ?*Stream {
    if (!knownMethod(method)) return null;
    if (comptime sync_net) {
        // `--threads`: eşzamanlı ağ import'u akış (parça parça okuma) sunamaz; yetenek hatası olarak bildirilir (`stream_*` yalnızca `--asyncify` freestanding'de).
        const st = gpa.create(Stream) catch return null;
        st.* = .{ .ok = false, .error_kind = 4, .req_headers = gpa.alloc(u8, 0) catch return null };
        return st;
    }
    const uploading = upload_len != -2;
    if ((body != null or uploading) and !isBodyMethod(method)) return null;
    const htext = headersToText(headers) orelse return null;
    const st = gpa.create(Stream) catch {
        gpa.free(htext);
        return null;
    };
    st.* = .{ .uploading = uploading, .upload_len = upload_len, .timeout_ms = timeout_ms, .req_headers = htext };
    st.method = gpa.dupe(u8, method) catch {
        streamFree(st);
        return null;
    };
    st.url = gpa.dupe(u8, url) catch {
        streamFree(st);
        return null;
    };
    if (!uploading) openRemote(st, body);
    return st;
}

pub fn streamOk(st: *Stream) i32 {
    return if (st.ok) 1 else 0;
}

pub fn streamHeaders(rt: ?*anyopaque, st: *Stream) ?*anyopaque {
    var tmp = Response{ .ok = true, .status = st.status, .error_kind = 0, .body = &.{}, .headers = st.resp_headers };
    return responseHeaders(rt, &tmp);
}

/// En çok `n` bayt döner; gövde bitince boş `str`. Hata: `st.ok = false`.
pub fn streamRead(rt: ?*anyopaque, st: *Stream, n: i64) ?[*:0]u8 {
    if (!st.ok or st.uploading or n <= 0) return shim_util.dupeToNoxStr(rt, "");
    const want: usize = @intCast(@min(n, 16 * 1024 * 1024));
    if (st.leftover_off >= st.leftover.items.len and !st.eof and st.host_id != 0) {
        st.leftover.clearRetainingCapacity();
        st.leftover_off = 0;
        const req = submit(.{ .kind = .stream_read, .stream = st.host_id, .arg = read_request_bytes, .timeout_ms = st.timeout_ms }, false) orelse {
            failStream(st, 2);
            return shim_util.dupeToNoxStr(rt, "");
        };
        const resp = waitFor(req) orelse {
            failStream(st, 2);
            return shim_util.dupeToNoxStr(rt, "");
        };
        defer responseFree(resp);
        if (!resp.ok) {
            failStream(st, resp.error_kind);
            return shim_util.dupeToNoxStr(rt, "");
        }
        if (resp.body.len == 0) {
            st.eof = true;
            st.host_id = 0; // host okuyucuyu kendiliğinden bırakır
        } else {
            st.leftover.appendSlice(gpa, resp.body) catch {
                failStream(st, 2);
                return shim_util.dupeToNoxStr(rt, "");
            };
        }
    }
    const avail = st.leftover.items.len - st.leftover_off;
    const take = @min(avail, want);
    const out = shim_util.dupeToNoxStr(rt, st.leftover.items[st.leftover_off .. st.leftover_off + take]);
    st.leftover_off += take;
    return out;
}

/// Yükleme parçası (tamponlanır). Sabit `Content-Length` aşılırsa `0`.
pub fn streamWrite(st: *Stream, content: []const u8) i32 {
    if (!st.ok or !st.uploading) return 0;
    if (st.upload_len >= 0 and st.upload.items.len + content.len > @as(usize, @intCast(st.upload_len))) {
        failStream(st, 3);
        return 0;
    }
    st.upload.appendSlice(gpa, content) catch {
        failStream(st, 2);
        return 0;
    };
    return 1;
}

/// Yüklemeyi bitirir: tamponlanan gövdeyi tek istek olarak gönderir ve başlıkları bekler.
pub fn streamFinish(st: *Stream) i32 {
    if (!st.ok or !st.uploading) return 0;
    if (st.upload_len >= 0 and st.upload.items.len != @as(usize, @intCast(st.upload_len))) {
        failStream(st, 3);
        return 0;
    }
    st.uploading = false;
    openRemote(st, st.upload.items);
    st.upload.clearAndFree(gpa);
    return if (st.ok) 1 else 0;
}

/// Akışı kapatır: host'taki okuyucuyu bırakır (yanıt beklenmez) ve belleği serbest bırakır.
pub fn streamFree(st: *Stream) void {
    if (st.host_id != 0) {
        if (submit(.{ .kind = .stream_close, .stream = st.host_id }, true)) |_| {}
    }
    st.leftover.deinit(gpa);
    st.upload.deinit(gpa);
    if (st.resp_headers.len > 0) gpa.free(st.resp_headers);
    if (st.method.len > 0) gpa.free(st.method);
    if (st.url.len > 0) gpa.free(st.url);
    gpa.free(st.req_headers);
    gpa.destroy(st);
}

pub fn responseOk(r: *Response) i32 {
    return if (r.ok) 1 else 0;
}

pub fn responseBody(rt: ?*anyopaque, r: *Response) ?[*:0]u8 {
    return shim_util.dupeToNoxStr(rt, r.body);
}

pub fn responseHeaders(rt: ?*anyopaque, r: *Response) ?*anyopaque {
    const d = dict_mod.nox_dict_new(rt, 1) orelse return null;
    var lines = std.mem.splitScalar(u8, r.headers, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOf(u8, line, ": ") orelse continue;
        const key_str = shim_util.dupeToNoxStr(rt, line[0..colon]) orelse continue;
        const value_str = shim_util.dupeToNoxStr(rt, line[colon + 2 ..]) orelse continue;
        dict_mod.nox_dict_set(rt, d, 1, 1, 0, @as(i64, @bitCast(@as(u64, @intFromPtr(key_str)))), @as(i64, @bitCast(@as(u64, @intFromPtr(value_str)))));
    }
    return d;
}

pub fn responseFree(r: *Response) void {
    gpa.free(r.body);
    gpa.free(r.headers);
    gpa.destroy(r);
}

// ---- Host'un çağırdığı dışa aktarımlar ----------------------------------------------------------------------------------------------------------------

/// Yetenek maskesini ayarlar (bit 0: fetch). Host `_start`tan ÖNCE çağırır.
export fn nox_host_caps_set(mask: u32) callconv(.c) void {
    g_caps = mask;
}

/// Host'un modül belleğine bayt yazabilmesi için geçici blok ayırır (`nox_host_free` ile bırakılır). Hata `null`.
export fn nox_host_alloc(len: usize) callconv(.c) ?[*]u8 {
    const block = gpa.alloc(u8, @max(len, 1)) catch return null;
    return block.ptr;
}

export fn nox_host_free(ptr: ?[*]u8, len: usize) callconv(.c) void {
    const p = ptr orelse return;
    gpa.free(p[0..@max(len, 1)]);
}

/// Program host'u bekliyor mu (1) yoksa bitti/çalışıyor mu (0)?
export fn nox_host_status() callconv(.c) i32 {
    return if (wasm_entry.suspended()) 1 else 0;
}

fn putU32(out: *std.ArrayListUnmanaged(u8), v: u32) bool {
    out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, v))) catch return false;
    return true;
}

fn putBytes(out: *std.ArrayListUnmanaged(u8), b: []const u8) bool {
    if (!putU32(out, @intCast(b.len))) return false;
    out.appendSlice(gpa, b) catch return false;
    return true;
}

/// Henüz host'a verilmemiş istekleri serileştirir ve "verildi" olarak işaretler. Kayıt (küçük-endian): `u32 id`, `u32 kind` (0 fetch, 1 stream_open, 2 stream_read, 3 stream_close),
/// `u32 stream` (hedef akış kimliği), `u32 arg` (zaman aşımı ms; `stream_read`te istenen bayt), `u32 has_body`, sonra uzunluk-önekli (`u32`) `method`, `url`, `headers`
/// (`Ad: değer\n` satırları), `body`. Yanıtsız (`stream_close`) kayıtlar verildikten sonra tablodan atılır. Uzunluk `out_len`e yazılır; hata `null`. Host baytları kopyalayıp
/// `nox_host_free(ptr, len)` çağırmalıdır.
export fn nox_host_fetch_pending(out_len: *usize) callconv(.c) ?[*]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < g_reqs.items.len) {
        const r = g_reqs.items[i];
        if (r.handed_out) {
            i += 1;
            continue;
        }
        if (!(putU32(&out, r.id) and putU32(&out, @intFromEnum(r.kind)) and putU32(&out, r.stream) and putU32(&out, r.arg) and putU32(&out, @intFromBool(r.has_body)) and putBytes(&out, r.method) and putBytes(&out, r.url) and putBytes(&out, r.headers) and putBytes(&out, r.body))) {
            out.deinit(gpa);
            return null;
        }
        r.handed_out = true;
        if (r.detached) {
            _ = g_reqs.orderedRemove(i);
            destroyRequest(r);
            continue;
        }
        i += 1;
    }
    out_len.* = out.items.len;
    if (out.items.len == 0) {
        out.deinit(gpa);
        const one = gpa.alloc(u8, 1) catch return null;
        return one.ptr;
    }
    const slice = out.toOwnedSlice(gpa) catch return null;
    return slice.ptr;
}

/// Bir isteğin sonucunu iletir ve bekleyen fiber'ı uyandırır. `error_kind`: -1 başarı; 0 bağlantı hatası, 1 zaman aşımı, 2 diğer. `status` HTTP durum kodu. Başlıklar `Ad: değer\n`
/// satırlarıdır. Host bellek bloklarını kendisi serbest bırakır (veriler kopyalanır). Bilinmeyen `id` için `-1`.
export fn nox_host_fetch_complete(id: u32, status: i32, error_kind: i32, hdr_ptr: ?[*]const u8, hdr_len: usize, body_ptr: ?[*]const u8, body_len: usize) callconv(.c) i32 {
    var target: ?*Request = null;
    for (g_reqs.items) |r| {
        if (r.id == id) {
            target = r;
            break;
        }
    }
    const req = target orelse return -1;
    if (req.done) return -1;
    const resp = gpa.create(Response) catch return -1;
    const body = gpa.dupe(u8, if (body_ptr) |p| p[0..body_len] else "") catch {
        gpa.destroy(resp);
        return -1;
    };
    const hdrs = gpa.dupe(u8, if (hdr_ptr) |p| p[0..hdr_len] else "") catch {
        gpa.free(body);
        gpa.destroy(resp);
        return -1;
    };
    resp.* = .{ .ok = error_kind < 0, .status = status, .error_kind = if (error_kind < 0) 0 else error_kind, .body = body, .headers = hdrs };
    req.resp = resp;
    req.done = true;
    if (req.fiber) |f| {
        if (req.sched) |s| s.markReady(f);
    }
    return 0;
}

/// Askıdaki programı sürdürür. Program biterse host'un `exit`i çağrılır (JS'te `NoxExit`); yeniden askıdaysa `nox_host_status() == 1` ile döner.
export fn nox_host_resume() callconv(.c) void {
    const rc = wasm_entry.resumeRun();
    if (wasm_entry.suspended()) return;
    host.exit(rc);
}
