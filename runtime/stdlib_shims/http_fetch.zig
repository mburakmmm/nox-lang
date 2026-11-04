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
//! Akışlı istemci (`stream_*`) bu sürümde desteklenmez (yetenek hatası verir): `fetch` yanıtı tümüyle tamponlanır. Küresel durum (istek tablosu, yetenek maskesi) vardır; bu,
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

const gpa = std.heap.page_allocator;

pub const CAP_FETCH: u32 = 1;
var g_caps: u32 = 0;
var g_next_id: u32 = 1;
var g_reqs: std.ArrayListUnmanaged(*Request) = .empty;

const Request = struct {
    id: u32,
    handed_out: bool = false,
    done: bool = false,
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

pub fn available() bool {
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

/// İsteği tabloya yazar ve sonuç gelene kadar bekler (fiber ise `suspendForHost`, ana akış ise doğrudan `hostSuspend`). Geçersiz istek (bilinmeyen metod, gövdesiz metodda gövde,
/// bozuk başlık) ya da tahsis hatası için `null` (yerel istemcideki gibi: hata türü 3).
pub fn request(method: []const u8, url: []const u8, body: ?[]const u8, headers: ?*anyopaque, timeout_ms: i64) ?*Response {
    if (!knownMethod(method)) return null;
    if (body != null and !isBodyMethod(method)) return null;
    const htext = headersToText(headers) orelse return null;
    const req = gpa.create(Request) catch {
        gpa.free(htext);
        return null;
    };
    req.* = .{
        .id = g_next_id,
        .method = gpa.dupe(u8, method) catch {
            gpa.free(htext);
            gpa.destroy(req);
            return null;
        },
        .url = gpa.dupe(u8, url) catch {
            gpa.free(req.method);
            gpa.free(htext);
            gpa.destroy(req);
            return null;
        },
        .headers = htext,
        .body = gpa.dupe(u8, body orelse "") catch {
            gpa.free(req.method);
            gpa.free(req.url);
            gpa.free(htext);
            gpa.destroy(req);
            return null;
        },
        .has_body = body != null,
        .timeout_ms = if (timeout_ms > 0) @intCast(@min(timeout_ms, std.math.maxInt(u32))) else 0,
        .sched = bridge.currentFiberScheduler(),
        .fiber = bridge.currentFiber(),
    };
    g_next_id +%= 1;
    if (g_next_id == 0) g_next_id = 1;
    g_reqs.append(gpa, req) catch {
        destroyRequest(req);
        return null;
    };

    if (req.fiber != null and req.sched != null) {
        while (!req.done) req.sched.?.suspendForHost();
    } else {
        // Ana akış (fiber değil): programı doğrudan host'a döndür; başka fiber çalışmaz (yerel istemcinin ana akışta bloklamasıyla aynı anlam).
        while (!req.done) asyncify.hostSuspend();
    }

    // Tablodan çıkar.
    for (g_reqs.items, 0..) |r, i| {
        if (r == req) {
            _ = g_reqs.swapRemove(i);
            break;
        }
    }
    const resp = req.resp;
    destroyRequest(req);
    return resp;
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

/// Henüz host'a verilmemiş istekleri serileştirir ve "verildi" olarak işaretler. Kayıt (küçük-endian): `u32 id`, `u32 timeout_ms`, `u32 has_body`, sonra uzunluk-önekli
/// (`u32`) `method`, `url`, `headers` (`Ad: değer\n` satırları), `body`. Uzunluk `out_len`e yazılır; hata `null`. Host baytları kopyalayıp `nox_host_free(ptr, len)` çağırmalıdır.
export fn nox_host_fetch_pending(out_len: *usize) callconv(.c) ?[*]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (g_reqs.items) |r| {
        if (r.handed_out) continue;
        if (!(putU32(&out, r.id) and putU32(&out, r.timeout_ms) and putU32(&out, @intFromBool(r.has_body)) and putBytes(&out, r.method) and putBytes(&out, r.url) and putBytes(&out, r.headers) and putBytes(&out, r.body))) {
            out.deinit(gpa);
            return null;
        }
        r.handed_out = true;
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
