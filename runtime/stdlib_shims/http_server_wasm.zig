//! WASM'da `nox.http.serve` (spec §3.360): sunucu bir HOST yeteneğidir. Modül soket açmaz; `wasm32-freestanding --asyncify` + host `serve` sağlayıcısı (Node: `node:http`; ya da
//! Nexus/service worker gibi herhangi bir host) dinler, gelen her isteği modülün `nox_host_http_dispatch` dışa aktarımıyla iletir, modül her istek için bir fiber'da kullanıcı
//! handler'ını çalıştırır ve yanıtı `nox_host_http_take_responses` ile geri verir. `serve` çağrısı (ana akış) host bırakana kadar `scheduler.run` + `hostSuspend` döngüsünde
//! bekler; handler'lar diğer fiber'lar gibi `nox.http.get` (fetch), `nox.sqlite`, vb. kullanabilir. Desteklenen: düz istek/yanıt. Desteklenmeyen (yetenek hatası/boş): akışlı yanıt
//! (`respstream_*`), WebSocket upgrade, TLS (host sonlandırır), HTTP/2, çok çekirdekli dinleyiciler. İstek tablosu küresel durumdur (tek örnekli freestanding modülün host köprüsü).

const std = @import("std");
const wasm_options = @import("wasm_options");
const str_mod = @import("../str.zig");
const shim_util = @import("shim_util.zig");
const dict_mod = @import("../collections/dict.zig");
const arc = @import("../alloc/arc.zig");
const asap = @import("../alloc/asap.zig");
const bridge = @import("../async_rt/bridge.zig");
const scheduler_mod = @import("../async_rt/scheduler.zig");

pub const enabled = @import("../wasm_host.zig").is_freestanding_wasm and wasm_options.asyncify and !wasm_options.threads;
const fetch = if (enabled) @import("http_fetch.zig") else struct {};
const asyncify = if (enabled) @import("../async_rt/asyncify.zig") else struct {};

const gpa = std.heap.page_allocator;

/// wasm32'de derlenmiş Nox işlevleri 64-bit sözcük imzalıdır (`define i64 @http_serve_wrap_N(i64 %ctx, i64 %req)`); işaretçiler sıfır genişletilmiş sözcüklerdir.
pub const HandlerFn = *const fn (u64, u64) callconv(.c) u64;

pub fn available() bool {
    return enabled and fetch.serveAvailable();
}

// ---- Bağlam (handler closure) -----------------------------------------------------------------------------------------------------------------------

/// Düzen ABI'dir: üretilen sarmalayıcı `rt`yi @0'dan, closure'ı @8'den 64-bit sözcük olarak okur (wasm32'de işaretçiler 4 bayttır, bu yüzden alanlar açıkça u64).
const HandlerCtx = extern struct {
    rt: u64,
    closure: u64,
    refs: u64,
};

pub fn handlerCtxNew(rt: ?*anyopaque, closure: ?*anyopaque) ?*anyopaque {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    const ctx = state.allocator().create(HandlerCtx) catch return null;
    arc.nox_rc_retain(closure);
    ctx.* = .{ .rt = @intFromPtr(rt), .closure = @intFromPtr(closure), .refs = 1 };
    return ctx;
}

pub fn handlerCtxRelease(p: ?*anyopaque) void {
    const ctx: *HandlerCtx = @ptrCast(@alignCast(p orelse return));
    ctx.refs -= 1;
    if (ctx.refs != 0) return;
    const rt: ?*anyopaque = @ptrFromInt(@as(usize, @intCast(ctx.rt)));
    if (ctx.closure != 0) {
        const base: [*]const u8 = @ptrFromInt(@as(usize, @intCast(ctx.closure)));
        const rel_addr: *align(1) const u64 = @ptrCast(base + 8);
        const rel_fn: *const fn (u64, u64) callconv(.c) void = @ptrFromInt(@as(usize, @intCast(rel_addr.*)));
        rel_fn(ctx.rt, ctx.closure);
    }
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt.?));
    state.allocator().destroy(ctx);
}

// ---- İstek/yanıt ----------------------------------------------------------------------------------------------------------------------------------------

/// Handler'a verilen istek tutamacı (`nox_http_request_*` erişimcileri bunu okur). Dizeler ARC'lı Nox `str`leridir.
const ServerRequest = struct {
    method: ?[*:0]u8 = null,
    target: ?[*:0]u8 = null,
    body: ?[*:0]u8 = null,
    peer: ?[*:0]u8 = null,
    /// `Ad: değer\n` satırları.
    headers: []u8 = &.{},
};

/// `nox_http_response_new`in döndürdüğü yanıt: bayt kopyaları (ARC'a dokunmaz).
const ServerResponse = struct {
    status: u16,
    body: []u8,
    headers: []u8,
};

pub fn responseNew(rt: ?*anyopaque, status: i64, body: ?[*:0]const u8, headers: ?*anyopaque) ?*anyopaque {
    _ = rt;
    const r = gpa.create(ServerResponse) catch return null;
    r.* = .{ .status = @intCast(@max(0, @min(status, 65535))), .body = &.{}, .headers = &.{} };
    if (body) |b| r.body = gpa.dupe(u8, str_mod.nox_str_slice(@constCast(b))) catch {
        gpa.destroy(r);
        return null;
    };
    var text: std.ArrayListUnmanaged(u8) = .empty;
    if (headers) |hp| {
        const d: *dict_mod.Dict = @ptrCast(@alignCast(hp));
        for (d.entries.items) |e| {
            const key = str_mod.nox_str_slice(@ptrFromInt(@as(usize, @intCast(@as(u64, @bitCast(e.key))))));
            const value = str_mod.nox_str_slice(@ptrFromInt(@as(usize, @intCast(@as(u64, @bitCast(e.value))))));
            // Başlık enjeksiyonu: CR/NUL (ve addaki LF) yasak; değerdeki `\n` birden çok başlık satırına ayrılır (`nox.http.multi`).
            if (std.mem.indexOfAny(u8, key, "\r\n\x00:") != null or std.mem.indexOfAny(u8, value, "\r\x00") != null) {
                text.deinit(gpa);
                freeResponse(r);
                return null;
            }
            var it = std.mem.splitScalar(u8, value, '\n');
            var any = false;
            while (it.next()) |seg| {
                if (seg.len == 0) continue;
                any = true;
                text.print(gpa, "{s}: {s}\n", .{ key, seg }) catch {
                    text.deinit(gpa);
                    freeResponse(r);
                    return null;
                };
            }
            if (!any) text.print(gpa, "{s}: \n", .{key}) catch {};
        }
    }
    r.headers = text.toOwnedSlice(gpa) catch &.{};
    return r;
}

fn freeResponse(r: *ServerResponse) void {
    if (r.body.len > 0) gpa.free(r.body);
    if (r.headers.len > 0) gpa.free(r.headers);
    gpa.destroy(r);
}

fn reqOf(h: ?*anyopaque) ?*ServerRequest {
    return @ptrCast(@alignCast(h orelse return null));
}

fn retained(p: ?[*:0]u8) ?[*:0]u8 {
    if (p) |x| str_mod.nox_str_retain(x);
    return p;
}

pub fn requestMethod(req: ?*anyopaque) ?[*:0]u8 {
    return retained((reqOf(req) orelse return null).method);
}

pub fn requestTarget(req: ?*anyopaque) ?[*:0]u8 {
    return retained((reqOf(req) orelse return null).target);
}

pub fn requestBody(req: ?*anyopaque) ?[*:0]u8 {
    return retained((reqOf(req) orelse return null).body);
}

pub fn requestPeer(req: ?*anyopaque) ?[*:0]u8 {
    return retained((reqOf(req) orelse return null).peer);
}

/// Başlıkları `dict[str, str]` yapar; aynı adlı başlıklar birleşir (`, `; `Cookie` için `; `).
pub fn requestHeaders(rt: ?*anyopaque, req: ?*anyopaque) ?*anyopaque {
    const r = reqOf(req) orelse return null;
    const d = dict_mod.nox_dict_new(rt, 1) orelse return null;
    var seen: std.ArrayListUnmanaged([]const u8) = .empty;
    defer seen.deinit(gpa);
    var lines = std.mem.splitScalar(u8, r.headers, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOf(u8, line, ": ") orelse continue;
        const name = line[0..colon];
        var dup = false;
        for (seen.items) |s| if (std.mem.eql(u8, s, name)) {
            dup = true;
            break;
        };
        if (dup) continue;
        seen.append(gpa, name) catch continue;
        const sep: []const u8 = if (std.ascii.eqlIgnoreCase(name, "cookie")) "; " else ", ";
        var combined: std.ArrayListUnmanaged(u8) = .empty;
        defer combined.deinit(gpa);
        var again = std.mem.splitScalar(u8, r.headers, '\n');
        var first = true;
        while (again.next()) |l2| {
            const c2 = std.mem.indexOf(u8, l2, ": ") orelse continue;
            if (!std.mem.eql(u8, l2[0..c2], name)) continue;
            if (!first) combined.appendSlice(gpa, sep) catch break;
            combined.appendSlice(gpa, l2[c2 + 2 ..]) catch break;
            first = false;
        }
        const k = shim_util.dupeToNoxStr(rt, name) orelse continue;
        const v = shim_util.dupeToNoxStr(rt, combined.items) orelse continue;
        dict_mod.nox_dict_set(rt, d, 1, 1, 0, @as(i64, @bitCast(@as(u64, @intFromPtr(k)))), @as(i64, @bitCast(@as(u64, @intFromPtr(v)))));
    }
    return d;
}

// ---- Sunucu --------------------------------------------------------------------------------------------------------------------------------------------

const Server = struct { port: i64, id: u32 };

var g_handler: ?HandlerFn = null;
var g_handler_ctx: ?*anyopaque = null;
var g_rt: ?*anyopaque = null;
var g_stop: bool = false;

const Incoming = struct { id: u32, method: []u8, target: []u8, headers: []u8, body: []u8, peer: []u8 };
const Done = struct { id: u32, status: u16, headers: []u8, body: []u8 };
var g_incoming: std.ArrayListUnmanaged(*Incoming) = .empty;
var g_done: std.ArrayListUnmanaged(Done) = .empty;

/// Host'a bir dinleyici açtırır (`port == 0`: host seçer). Gerçek port `status` alanında döner.
pub fn listen(rt: ?*anyopaque, port: i64) ?*anyopaque {
    _ = rt;
    if (comptime !enabled) return null;
    const req = fetch.submit(.{ .kind = .http_listen, .arg = @intCast(@max(0, @min(port, 65535))) }, false) orelse return null;
    const id = req.id;
    const resp = fetch.waitFor(req) orelse return null;
    defer fetch.responseFree(resp);
    if (!resp.ok) return null;
    const s = gpa.create(Server) catch return null;
    s.* = .{ .port = resp.status, .id = id };
    return s;
}

pub fn serverPort(server: ?*anyopaque) i64 {
    const s: *Server = @ptrCast(@alignCast(server orelse return -1));
    return s.port;
}

pub fn serverClose(server: ?*anyopaque) void {
    const s: *Server = @ptrCast(@alignCast(server orelse return));
    if (comptime enabled) _ = fetch.submit(.{ .kind = .http_unlisten, .stream = s.id }, true);
    gpa.destroy(s);
}

fn dupeNox(rt: ?*anyopaque, b: []const u8) ?[*:0]u8 {
    return shim_util.dupeToNoxStr(rt, b);
}

/// Bir istek için fiber girişi: handler'ı çağırır, yanıtı `g_done`a yazar.
fn dispatchEntry(arg: scheduler_mod.TaskArg) callconv(.c) i64 {
    const inc: *Incoming = @ptrFromInt(@as(usize, @intCast(arg)));
    defer {
        gpa.free(inc.method);
        gpa.free(inc.target);
        gpa.free(inc.headers);
        gpa.free(inc.body);
        gpa.free(inc.peer);
        gpa.destroy(inc);
    }
    const rt = g_rt;
    var req = ServerRequest{
        .method = dupeNox(rt, inc.method),
        .target = dupeNox(rt, inc.target),
        .body = dupeNox(rt, inc.body),
        .peer = dupeNox(rt, inc.peer),
        .headers = inc.headers,
    };
    const resp_word = g_handler.?(@intFromPtr(g_handler_ctx), @intFromPtr(&req));
    const resp_ptr: ?*anyopaque = if (resp_word == 0) null else @ptrFromInt(@as(usize, @intCast(resp_word)));
    for ([_]?[*:0]u8{ req.method, req.target, req.body, req.peer }) |s| if (s) |p| str_mod.nox_str_release(rt, p);
    var done: Done = .{ .id = inc.id, .status = 500, .headers = &.{}, .body = gpa.dupe(u8, "Internal Server Error") catch &.{} };
    if (resp_ptr) |rp| {
        const r: *ServerResponse = @ptrCast(@alignCast(rp));
        if (done.body.len > 0) gpa.free(done.body);
        done = .{ .id = inc.id, .status = r.status, .headers = gpa.dupe(u8, r.headers) catch &.{}, .body = gpa.dupe(u8, r.body) catch &.{} };
        freeResponse(r);
    }
    g_done.append(gpa, done) catch {};
    return 0;
}

/// `serve`: host bırakana (ya da `nox_host_http_stop`) kadar bekler.
pub fn serve(rt: ?*anyopaque, handler: HandlerFn, handler_ctx: ?*anyopaque) void {
    if (comptime !enabled) return;
    g_handler = handler;
    g_handler_ctx = handler_ctx;
    g_rt = rt;
    g_stop = false;
    // Program `async` kullanmıyorsa zamanlayıcı henüz kurulmamıştır: istek fiber'ları için kurulur.
    if (!bridge.schedulerReady()) bridge.nox_async_init(rt);
    var tasks: std.ArrayListUnmanaged(?*anyopaque) = .empty;
    defer tasks.deinit(gpa);
    while (!g_stop) {
        // Gelen istekler eşzamanlı fiber'lara dağıtılır, sonra hepsi beklenir (`await`: ana akıştan zamanlayıcıyı sürer; bir handler host'u bekliyorsa `run` içinde `hostSuspend`
        // olur). Bekleme sırasında gelen yeni istekler bir sonraki tura kalır.
        while (g_incoming.items.len > 0) {
            const inc = g_incoming.orderedRemove(0);
            const t = bridge.nox_async_spawn(rt, &dispatchEntry, inc);
            tasks.append(gpa, t) catch {};
        }
        for (tasks.items) |t| {
            _ = bridge.nox_async_await(rt, t);
            bridge.nox_async_destroy_task(rt, t);
        }
        tasks.clearRetainingCapacity();
        if (g_stop) break;
        if (g_incoming.items.len == 0) asyncify.hostSuspend();
    }
}

// ---- Host'un çağırdığı dışa aktarımlar --------------------------------------------------------------------------------------------------------------

/// Gelen bir isteği kuyruğa yazar (host, dışa aktarımları çağırdıktan sonra `nox_host_resume` ile sürdürür). Başlıklar `Ad: değer\n` satırlarıdır. `0` başarı.
export fn nox_host_http_dispatch(id: u32, m: [*]const u8, m_len: usize, t: [*]const u8, t_len: usize, h: [*]const u8, h_len: usize, b: [*]const u8, b_len: usize, p: [*]const u8, p_len: usize) callconv(.c) i32 {
    const inc = gpa.create(Incoming) catch return -1;
    inc.* = .{
        .id = id,
        .method = gpa.dupe(u8, m[0..m_len]) catch return -1,
        .target = gpa.dupe(u8, t[0..t_len]) catch return -1,
        .headers = gpa.dupe(u8, h[0..h_len]) catch return -1,
        .body = gpa.dupe(u8, b[0..b_len]) catch return -1,
        .peer = gpa.dupe(u8, p[0..p_len]) catch return -1,
    };
    g_incoming.append(gpa, inc) catch return -1;
    return 0;
}

/// Tamamlanan yanıtları serileştirir: `u32 id, u32 durum, u32 başlık uzunluğu, başlıklar, u32 gövde uzunluğu, gövde`. Uzunluk `out_len`e yazılır.
export fn nox_host_http_take_responses(out_len: *usize) callconv(.c) ?[*]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (g_done.items) |d| {
        for ([_]u32{ d.id, d.status, @intCast(d.headers.len) }) |v| out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, v))) catch return null;
        out.appendSlice(gpa, d.headers) catch return null;
        out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(d.body.len)))) catch return null;
        out.appendSlice(gpa, d.body) catch return null;
        if (d.headers.len > 0) gpa.free(d.headers);
        if (d.body.len > 0) gpa.free(d.body);
    }
    g_done.clearRetainingCapacity();
    out_len.* = out.items.len;
    if (out.items.len == 0) {
        out.deinit(gpa);
        const one = gpa.alloc(u8, 1) catch return null;
        return one.ptr;
    }
    return (out.toOwnedSlice(gpa) catch return null).ptr;
}

/// `serve` döngüsünü sonlandırır (host kapanırken).
export fn nox_host_http_stop() callconv(.c) void {
    g_stop = true;
}

