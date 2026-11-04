//! WASM'da (`wasm32-wasi` ve `wasm32-freestanding`, tüm kipler) `nox.http` çalışma zamanı sembolleri: "network" YETENEĞİ YOK davranışı.
//!
//! `nox.http` (ve ona bağlı `router`, `web`, `reflect`, `transfer`) artık WASM'da DERLENİR: yönlendirme, çerezler, CORS, istek/yanıt sınıfları ve bir
//! handler'ın doğrudan çağrılarak sınanması (`HttpRequest(..., conn=0)`) saf Nox'tur ve çalışır. Yalnızca gerçek soket gerektiren çağrılar (`get`/`post`/`request`/
//! `stream_*`, `serve*`, `listen_fd*`) bir ağa ihtiyaç duyar. Bu dosya o çağrıların gerçek (`http_client.zig`/`http_server.zig`, soket + std.http) karşılıkları
//! yerine geçer ve host bir ağ yeteneği sağlamadığı sürece şunu yapar:
//!   - istemci çağrıları başarısız bir tutamaç döner (`ok == 0`, `error_kind == 4`); `stdlib/nox/http.nox` bunu `HttpCapabilityError`a çevirir (yakalanabilir);
//!   - sunucu çağrıları (`listen`) bir tanı mesajı yazıp sıfır/null döner: `serve` gerçek bir bind hatasındaki gibi hemen döner.
//! Gerçek bir ağ yeteneği (tarayıcıda `fetch`, Node/wasmtime'da host HTTP'si) sonraki adımlarda `nox_host` import'ları olarak eklenir; bu dosyadaki sembol adları ve
//! imzalar `http_client.zig`/`http_server.zig` ile BİREBİR aynı kalmak zorundadır (`scripts/check_wasm_http_stubs.py` bunu denetler).
//!
//! Küresel/gizli durum yoktur (AGENTS §2.6): "başarısız tutamaç" sabit bir işaretçidir, hiç yazılmaz.

const diag_sink = @import("diag_sink");

/// `nox_http_response_error_kind`/`nox_http_stream_error_kind` değeri: host bu yeteneği sağlamıyor (0 = bağlantı, 1 = zaman aşımı, 3 = geçersiz istek).
pub const ERROR_KIND_CAPABILITY: i64 = 4;

/// İstemci çağrılarının döndüğü, hiç yazılmayan ve hiç serbest bırakılmayan başarısız-yanıt tutamacı.
const unavailable_handle: u8 = 0;

fn failedHandle() ?*anyopaque {
    return @ptrCast(@constCast(&unavailable_handle));
}

fn serverUnavailable(rt: ?*anyopaque) void {
    diag_sink.report(rt, "nox.http: serving needs the 'network' capability, which this host does not provide (WASM has no sockets; see docs/tools/wasm.md)\n", .{});
}

// ---- Ayarlar / kapanış (etkisiz) -------------------------------------------------------------------------------------------------------------------

export fn nox_http_config_set_raw(key: i64, value: i64) callconv(.c) void {
    _ = key;
    _ = value;
}

export fn nox_http_shutdown_raw() callconv(.c) void {}

export fn nox_http_client_pool_set_raw(max_idle: i64) callconv(.c) void {
    _ = max_idle;
}

export fn nox_http_client_pool_idle_timeout_raw(ms: i64) callconv(.c) void {
    _ = ms;
}

export fn nox_http_client_pool_idle_raw() callconv(.c) i64 {
    return 0;
}

// ---- İstemci (başarısız tutamaç) --------------------------------------------------------------------------------------------------------------------

export fn nox_http_get_raw(rt: ?*anyopaque, url: ?[*:0]const u8, headers: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = rt;
    _ = url;
    _ = headers;
    return failedHandle();
}

export fn nox_http_post_raw(rt: ?*anyopaque, url: ?[*:0]const u8, body: ?[*:0]const u8, headers: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = rt;
    _ = url;
    _ = body;
    _ = headers;
    return failedHandle();
}

export fn nox_http_request_raw(rt: ?*anyopaque, method: ?[*:0]const u8, url: ?[*:0]const u8, body: ?[*:0]const u8, has_body: i32, headers: ?*anyopaque, timeout_ms: i64) callconv(.c) ?*anyopaque {
    _ = rt;
    _ = method;
    _ = url;
    _ = body;
    _ = has_body;
    _ = headers;
    _ = timeout_ms;
    return failedHandle();
}

export fn nox_http_response_error_kind(h: ?*anyopaque) callconv(.c) i64 {
    _ = h;
    return ERROR_KIND_CAPABILITY;
}

export fn nox_http_response_ok(h: ?*anyopaque) callconv(.c) i32 {
    _ = h;
    return 0;
}

export fn nox_http_response_status(h: ?*anyopaque) callconv(.c) i64 {
    _ = h;
    return 0;
}

export fn nox_http_response_body(rt: ?*anyopaque, h: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    _ = rt;
    _ = h;
    return null;
}

export fn nox_http_response_headers(rt: ?*anyopaque, h: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = rt;
    _ = h;
    return null;
}

export fn nox_http_response_free(h: ?*anyopaque) callconv(.c) void {
    _ = h;
}

// ---- Akışlı istemci (`transfer`, `http.stream_*`) ---------------------------------------------------------------------------------------------------

export fn nox_http_stream_open_raw(rt: ?*anyopaque, method: ?[*:0]const u8, url: ?[*:0]const u8, headers: ?*anyopaque, body: ?[*:0]const u8, has_body: i32, upload_len: i64, timeout_ms: i64) callconv(.c) ?*anyopaque {
    _ = rt;
    _ = method;
    _ = url;
    _ = headers;
    _ = body;
    _ = has_body;
    _ = upload_len;
    _ = timeout_ms;
    return failedHandle();
}

export fn nox_http_stream_error_kind(h: ?*anyopaque) callconv(.c) i64 {
    _ = h;
    return ERROR_KIND_CAPABILITY;
}

export fn nox_http_stream_ok(h: ?*anyopaque) callconv(.c) i32 {
    _ = h;
    return 0;
}

export fn nox_http_stream_status(h: ?*anyopaque) callconv(.c) i64 {
    _ = h;
    return 0;
}

export fn nox_http_stream_headers(rt: ?*anyopaque, h: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = rt;
    _ = h;
    return null;
}

export fn nox_http_stream_read_raw(rt: ?*anyopaque, h: ?*anyopaque, n: i64) callconv(.c) ?[*:0]u8 {
    _ = rt;
    _ = h;
    _ = n;
    return null;
}

export fn nox_http_stream_write_raw(h: ?*anyopaque, content: ?[*:0]const u8) callconv(.c) i32 {
    _ = h;
    _ = content;
    return 0;
}

export fn nox_http_stream_finish_raw(h: ?*anyopaque) callconv(.c) i32 {
    _ = h;
    return 0;
}

export fn nox_http_stream_close_raw(h: ?*anyopaque) callconv(.c) void {
    _ = h;
}

// ---- Sunucu (dinleme yok) ----------------------------------------------------------------------------------------------------------------------------

export fn nox_http_server_listen(rt: ?*anyopaque, port: i64) callconv(.c) ?*anyopaque {
    _ = port;
    serverUnavailable(rt);
    return null;
}

export fn nox_http_server_listen_tls(rt: ?*anyopaque, port: i64, cert_path: ?[*:0]const u8, key_path: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    _ = port;
    _ = cert_path;
    _ = key_path;
    serverUnavailable(rt);
    return null;
}

export fn nox_http_listen_fd(rt: ?*anyopaque, port: i64) callconv(.c) i64 {
    _ = port;
    serverUnavailable(rt);
    return -1;
}

export fn nox_http_listen_fd_v6(rt: ?*anyopaque, port: i64, v6_only: i64) callconv(.c) i64 {
    _ = port;
    _ = v6_only;
    serverUnavailable(rt);
    return -1;
}

export fn nox_http_listen_fd_tls(rt: ?*anyopaque, port: i64, cert_path: ?[*:0]const u8, key_path: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    _ = port;
    _ = cert_path;
    _ = key_path;
    serverUnavailable(rt);
    return null;
}

export fn nox_http_server_listen_multicore_worker(rt: ?*anyopaque, port: i64) callconv(.c) ?*anyopaque {
    _ = port;
    serverUnavailable(rt);
    return null;
}

export fn nox_http_build_tls_ctx(cert_path: ?[*:0]const u8, key_path: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    _ = cert_path;
    _ = key_path;
    return null;
}

export fn nox_http_make_port_tls_payload(rt: ?*anyopaque, port: i64, tls_ctx: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = rt;
    _ = port;
    _ = tls_ctx;
    return null;
}

export fn nox_http_server_listen_multicore_worker_tls(rt: ?*anyopaque, port: i64, tls_ctx: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = port;
    _ = tls_ctx;
    serverUnavailable(rt);
    return null;
}

export fn nox_http_make_shared_budget(rt: ?*anyopaque, max_connections_per_worker: i64, num_workers: i64) callconv(.c) ?*anyopaque {
    _ = rt;
    _ = max_connections_per_worker;
    _ = num_workers;
    return null;
}

export fn nox_http_make_bounded_payload(rt: ?*anyopaque, port: i64, tls_ctx: ?*anyopaque, budget: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = rt;
    _ = port;
    _ = tls_ctx;
    _ = budget;
    return null;
}

export fn nox_http_free_shared_budget(rt: ?*anyopaque, budget: ?*anyopaque) callconv(.c) void {
    _ = rt;
    _ = budget;
}

export fn nox_http_free_bounded_payload(rt: ?*anyopaque, payload: ?*anyopaque) callconv(.c) void {
    _ = rt;
    _ = payload;
}

export fn nox_http_server_from_fd(rt: ?*anyopaque, fd: i64) callconv(.c) ?*anyopaque {
    _ = fd;
    serverUnavailable(rt);
    return null;
}

export fn nox_http_server_from_fd_tls(rt: ?*anyopaque, fd: i64, tls_ctx: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = fd;
    _ = tls_ctx;
    serverUnavailable(rt);
    return null;
}

export fn nox_http_server_from_fd_tls_owned(rt: ?*anyopaque, fd: i64, cert_path: ?[*:0]const u8, key_path: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    _ = fd;
    _ = cert_path;
    _ = key_path;
    serverUnavailable(rt);
    return null;
}

export fn nox_http_server_port(server: ?*anyopaque) callconv(.c) i64 {
    _ = server;
    return 0;
}

export fn nox_http_server_close(rt: ?*anyopaque, server: ?*anyopaque) callconv(.c) void {
    _ = rt;
    _ = server;
}

export fn nox_http_serve_raw(rt: ?*anyopaque, server: ?*anyopaque, handler: ?*const anyopaque, handler_ctx: ?*anyopaque, max_connections: i64, needs_headers: i32, shared_budget: ?*anyopaque) callconv(.c) void {
    // Gerçek çalışma zamanı da dinleyemediğinde (bind hatası) hemen döner; `server` burada her zaman null'dır.
    _ = rt;
    _ = server;
    _ = handler;
    _ = handler_ctx;
    _ = max_connections;
    _ = needs_headers;
    _ = shared_budget;
}

export fn nox_http_serve_ws_raw(rt: ?*anyopaque, server: ?*anyopaque, handler: ?*const anyopaque, handler_ctx: ?*anyopaque, ws_handler: ?*const anyopaque, max_connections: i64, needs_headers: i32, shared_budget: ?*anyopaque) callconv(.c) void {
    _ = rt;
    _ = server;
    _ = handler;
    _ = handler_ctx;
    _ = ws_handler;
    _ = max_connections;
    _ = needs_headers;
    _ = shared_budget;
}

export fn nox_http_handler_ctx_new(rt: ?*anyopaque, closure: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = rt;
    _ = closure;
    return null;
}

export fn nox_http_handler_ctx_release(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
}

// ---- Sunucu tarafı istek/yanıt erişimcileri (handler wrapper'ları yalnızca gerçek bir sunucuda çalışır) -------------------------------------------------

export fn nox_http_response_new(rt: ?*anyopaque, status: i64, body: ?[*:0]const u8, headers: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = rt;
    _ = status;
    _ = body;
    _ = headers;
    return null;
}

export fn nox_http_request_method(rt: ?*anyopaque, req: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    _ = rt;
    _ = req;
    return null;
}

export fn nox_http_request_target(rt: ?*anyopaque, req: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    _ = rt;
    _ = req;
    return null;
}

export fn nox_http_request_body(rt: ?*anyopaque, req: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    _ = rt;
    _ = req;
    return null;
}

export fn nox_http_request_peer_addr(rt: ?*anyopaque, req: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    _ = rt;
    _ = req;
    return null;
}

export fn nox_http_request_headers(rt: ?*anyopaque, req: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = rt;
    _ = req;
    return null;
}

export fn nox_http_request_trailer_raw(rt: ?*anyopaque, conn: i64, name: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    _ = rt;
    _ = conn;
    _ = name;
    return null;
}

// ---- Akışlı yanıt (yalnızca bir sunucu bağlantısında anlamlı; birim testlerinde `conn == 0` Nox tarafında ele alınır) ---------------------------------------

export fn nox_http_respstream_start_raw(rt: ?*anyopaque, conn: i64, status: i64, headers: ?*anyopaque) callconv(.c) i64 {
    _ = rt;
    _ = conn;
    _ = status;
    _ = headers;
    return 0;
}

export fn nox_http_respstream_send_raw(conn: i64, data: ?[*:0]const u8) callconv(.c) i64 {
    _ = conn;
    _ = data;
    return 0;
}

export fn nox_http_respstream_end_raw(conn: i64) callconv(.c) i64 {
    _ = conn;
    return 0;
}

export fn nox_http_respstream_trailers_raw(rt: ?*anyopaque, conn: i64, headers: ?*anyopaque) callconv(.c) i64 {
    _ = rt;
    _ = conn;
    _ = headers;
    return 0;
}

export fn nox_http_respstream_open_raw(conn: i64) callconv(.c) i64 {
    _ = conn;
    return 0;
}

export fn nox_http_respstream_sleep_raw(ms: i64) callconv(.c) void {
    _ = ms;
}
