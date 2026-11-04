//! WASM'da `nox.websocket` istemcisi (spec §3.356): host'un `WebSocket`ine dayanır. `wasm32-freestanding --asyncify` + host ağ yeteneği (`nox_host_caps_set(1)`) varsa
//! gerçek bağlantı; aksi halde `connect` "ağ yeteneği yok" iletisiyle başarısız olur (`WebSocketError`). Mekanizma `http_fetch.zig` ile aynıdır: istek kayıtları (`kind` 4 açma,
//! 5 gönderme (yanıtsız), 6 alma, 7 kapatma (yanıtsız)); `recv` fiber'ı bekletir, başka fiber'lar çalışır. `nox_ws_*` imzaları `websocket.zig` ile BİREBİR aynıdır
//! (`scripts/gen_wasm_abi.py` tablosu). Sunucu tarafı (`nox_ws_server_*`) WASM'da yoktur (dinleme yok): çağrılar başarısız döner.

const std = @import("std");
const wasm_options = @import("wasm_options");
const str_mod = @import("../str.zig");
const shim_util = @import("shim_util.zig");

const enabled = @import("../wasm_host.zig").is_freestanding_wasm and wasm_options.asyncify and !wasm_options.threads;
const fetch = if (enabled) @import("http_fetch.zig") else struct {};

const gpa = std.heap.page_allocator;

const no_capability = "the 'network' capability is not available on this host (WebSocket needs wasm32-freestanding --asyncify and a host-provided fetch/WebSocket; see docs/tools/wasm.md)";

const WsConn = struct {
    connected: bool = false,
    /// Host'taki soketin kimliği (açan isteğin kimliği); 0 = yok.
    id: u32 = 0,
    errmsg: []const u8 = "",
    errmsg_owned: bool = false,
};

fn setErr(c: *WsConn, msg: []const u8) void {
    if (c.errmsg_owned) gpa.free(c.errmsg);
    if (gpa.dupe(u8, msg)) |d| {
        c.errmsg = d;
        c.errmsg_owned = true;
    } else |_| {
        c.errmsg = "out of memory";
        c.errmsg_owned = false;
    }
}

export fn nox_ws_connect_raw(host: ?[*:0]const u8, port: i64, path: ?[*:0]const u8, use_tls: i64) callconv(.c) ?*anyopaque {
    const conn = gpa.create(WsConn) catch return null;
    conn.* = .{};
    if (comptime !enabled) {
        conn.errmsg = no_capability;
        return conn;
    }
    if (!fetch.available()) {
        conn.errmsg = no_capability;
        return conn;
    }
    const h = host orelse {
        conn.errmsg = "host cannot be empty";
        return conn;
    };
    const p = path orelse {
        conn.errmsg = "path cannot be empty";
        return conn;
    };
    const url = std.fmt.allocPrint(gpa, "{s}://{s}:{d}{s}", .{ if (use_tls != 0) "wss" else "ws", str_mod.nox_str_slice(h), port, str_mod.nox_str_slice(p) }) catch {
        conn.errmsg = "out of memory";
        return conn;
    };
    defer gpa.free(url);
    const req = fetch.submit(.{ .kind = .ws_open, .url = url }, false) orelse {
        conn.errmsg = "out of memory";
        return conn;
    };
    const id = req.id;
    const resp = fetch.waitFor(req) orelse {
        conn.errmsg = "out of memory";
        return conn;
    };
    defer fetch.responseFree(resp);
    if (!resp.ok) {
        setErr(conn, if (resp.body.len > 0) resp.body else "connection failed");
        return conn;
    }
    conn.id = id;
    conn.connected = true;
    return conn;
}

export fn nox_ws_ok_raw(handle: ?*anyopaque) callconv(.c) i64 {
    const conn: *WsConn = @ptrCast(@alignCast(handle orelse return 0));
    return if (conn.connected) 1 else 0;
}

export fn nox_ws_errmsg_raw(rt: ?*anyopaque, handle: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const conn: *WsConn = @ptrCast(@alignCast(handle orelse return shim_util.dupeToNoxStr(rt, "")));
    return shim_util.dupeToNoxStr(rt, conn.errmsg);
}

/// Metin çerçevesi gönderir (yanıtsız; hata sonraki `recv`de görünür). Başarıda `len`, hatada -1.
export fn nox_ws_send_text_raw(handle: ?*anyopaque, data: ?[*]const u8, len: i64) callconv(.c) i64 {
    const conn: *WsConn = @ptrCast(@alignCast(handle orelse return -1));
    if (comptime !enabled) return -1;
    if (!conn.connected) return -1;
    const d = data orelse return -1;
    if (len < 0) return -1;
    _ = fetch.submit(.{ .kind = .ws_send, .stream = conn.id, .body = d[0..@intCast(len)] }, true) orelse {
        setErr(conn, "out of memory");
        return -1;
    };
    return len;
}

/// Sonraki iletiyi alır; bağlantı kapanırsa boş `str` ve `nox_ws_ok_raw == 0`.
export fn nox_ws_recv_raw(rt: ?*anyopaque, handle: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const conn: *WsConn = @ptrCast(@alignCast(handle orelse return shim_util.dupeToNoxStr(rt, "")));
    if (comptime !enabled) return shim_util.dupeToNoxStr(rt, "");
    if (!conn.connected) return shim_util.dupeToNoxStr(rt, "");
    const req = fetch.submit(.{ .kind = .ws_recv, .stream = conn.id }, false) orelse {
        conn.connected = false;
        setErr(conn, "out of memory");
        return shim_util.dupeToNoxStr(rt, "");
    };
    const resp = fetch.waitFor(req) orelse {
        conn.connected = false;
        setErr(conn, "out of memory");
        return shim_util.dupeToNoxStr(rt, "");
    };
    defer fetch.responseFree(resp);
    if (!resp.ok or resp.status == 1) {
        // Sunucu kapattı ya da hata: bağlantı artık kapalı.
        conn.connected = false;
        if (!resp.ok) setErr(conn, if (resp.body.len > 0) resp.body else "connection error") else conn.id = 0;
        return shim_util.dupeToNoxStr(rt, "");
    }
    return shim_util.dupeToNoxStr(rt, resp.body);
}

export fn nox_ws_close_raw(handle: ?*anyopaque) callconv(.c) void {
    const conn: *WsConn = @ptrCast(@alignCast(handle orelse return));
    if (comptime enabled) {
        if (conn.connected and conn.id != 0) _ = fetch.submit(.{ .kind = .ws_close, .stream = conn.id }, true);
    }
    if (conn.errmsg_owned) gpa.free(conn.errmsg);
    gpa.destroy(conn);
}

export fn nox_ws_is_null_ptr(p: ?*anyopaque) callconv(.c) i64 {
    return if (p == null) 1 else 0;
}

// ---- Sunucu tarafı (WASM'da dinleme yok) ---------------------------------------------------------------------------------------------------------------

export fn nox_ws_server_recv_raw(rt: ?*anyopaque, handle: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    _ = handle;
    return shim_util.dupeToNoxStr(rt, "");
}

export fn nox_ws_server_send_text_raw(handle: ?*anyopaque, data: ?[*]const u8, len: i64) callconv(.c) i64 {
    _ = handle;
    _ = data;
    _ = len;
    return -1;
}

export fn nox_ws_server_errmsg_raw(rt: ?*anyopaque, handle: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    _ = handle;
    return shim_util.dupeToNoxStr(rt, no_capability);
}

export fn nox_ws_server_ok_raw(handle: ?*anyopaque) callconv(.c) i64 {
    _ = handle;
    return 0;
}

export fn nox_ws_server_close_raw(handle: ?*anyopaque) callconv(.c) void {
    _ = handle;
}

export fn nox_ws_server_is_null_ptr(p: ?*anyopaque) callconv(.c) i64 {
    return if (p == null) 1 else 0;
}
