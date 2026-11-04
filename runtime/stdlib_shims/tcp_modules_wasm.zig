//! WASM'da `nox.tls` ve `nox.smtp` (spec §3.357): `tcp_host.zig` üzerinde, `tls.zig`/`smtp.zig` ile BİREBİR aynı `nox_tls_*`/`nox_smtp_*` imzaları. TLS host'ta sonlandırılır
//! (Node `tls.connect`), bu yüzden modülde CA paketi ya da el sıkışma kodu yoktur. Host TCP yeteneği yokken `connect` "tcp capability" iletisiyle başarısız olur
//! (`TlsError`/`SmtpError`).

const std = @import("std");
const str_mod = @import("../str.zig");
const shim_util = @import("shim_util.zig");
const tcp = @import("tcp_host.zig");

const gpa = std.heap.page_allocator;

fn dupeStr(rt: ?*anyopaque, b: []const u8) ?[*:0]u8 {
    return shim_util.dupeToNoxStr(rt, b);
}

// ---- nox.tls ---------------------------------------------------------------------------------------------------------------------------------------

export fn nox_tls_connect_raw(host: ?[*:0]const u8, port: i64) callconv(.c) ?*anyopaque {
    const h = host orelse {
        const c = gpa.create(tcp.Conn) catch return null;
        c.* = .{ .errmsg = "host cannot be empty" };
        return c;
    };
    return tcp.connect(str_mod.nox_str_slice(h), port, true);
}

export fn nox_tls_ok_raw(handle: ?*anyopaque) callconv(.c) i64 {
    const c: *tcp.Conn = @ptrCast(@alignCast(handle orelse return 0));
    return if (c.ok) 1 else 0;
}

export fn nox_tls_errmsg_raw(rt: ?*anyopaque, handle: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const c: *tcp.Conn = @ptrCast(@alignCast(handle orelse return dupeStr(rt, "")));
    return dupeStr(rt, c.errmsg);
}

export fn nox_tls_write_raw(handle: ?*anyopaque, data: ?[*]const u8, len: i64) callconv(.c) i64 {
    const c: *tcp.Conn = @ptrCast(@alignCast(handle orelse return -1));
    if (!c.ok) return -1;
    const d = data orelse return -1;
    if (len <= 0) return 0;
    return if (tcp.write(c, d[0..@intCast(len)])) len else -1;
}

/// En çok `max_len` bayt; bağlantı temiz kapandıysa boş `str` (hata değil).
export fn nox_tls_read_raw(rt: ?*anyopaque, handle: ?*anyopaque, max_len: i64) callconv(.c) ?[*:0]u8 {
    const c: *tcp.Conn = @ptrCast(@alignCast(handle orelse return dupeStr(rt, "")));
    if (!c.ok or max_len <= 0) return dupeStr(rt, "");
    return dupeStr(rt, tcp.readSome(c, @intCast(max_len)));
}

export fn nox_tls_close_raw(handle: ?*anyopaque) callconv(.c) void {
    const c: *tcp.Conn = @ptrCast(@alignCast(handle orelse return));
    tcp.close(c);
}

export fn nox_tls_is_null_ptr(p: ?*anyopaque) callconv(.c) i64 {
    return if (p == null) 1 else 0;
}

// ---- nox.smtp --------------------------------------------------------------------------------------------------------------------------------------

/// SMTP bağlantısı: TCP + (isteğe bağlı) host TLS; STARTTLS için sunucu adı saklanır.
const SmtpConn = struct { tcp: *tcp.Conn, host: []u8 };

export fn nox_smtp_connect_raw(host: ?[*:0]const u8, port: i64, use_tls: i64) callconv(.c) ?*anyopaque {
    const conn = gpa.create(SmtpConn) catch return null;
    const h = if (host) |hp| str_mod.nox_str_slice(hp) else "";
    conn.host = gpa.dupe(u8, h) catch {
        gpa.destroy(conn);
        return null;
    };
    conn.tcp = tcp.connect(h, port, use_tls != 0) orelse {
        gpa.free(conn.host);
        gpa.destroy(conn);
        return null;
    };
    if (host == null) {
        conn.tcp.ok = false;
        conn.tcp.errmsg = "host cannot be empty";
    }
    return conn;
}

fn smtp(handle: ?*anyopaque) ?*SmtpConn {
    return @ptrCast(@alignCast(handle orelse return null));
}

export fn nox_smtp_ok_raw(handle: ?*anyopaque) callconv(.c) i64 {
    const c = smtp(handle) orelse return 0;
    return if (c.tcp.ok) 1 else 0;
}

export fn nox_smtp_errmsg_raw(rt: ?*anyopaque, handle: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const c = smtp(handle) orelse return dupeStr(rt, "");
    return dupeStr(rt, c.tcp.errmsg);
}

export fn nox_smtp_write_raw(handle: ?*anyopaque, data: ?[*]const u8, len: i64) callconv(.c) i64 {
    const c = smtp(handle) orelse return -1;
    if (!c.tcp.ok) return -1;
    const d = data orelse return -1;
    if (len <= 0) return 0;
    return if (tcp.write(c.tcp, d[0..@intCast(len)])) len else -1;
}

/// Bir CRLF-sonlu satır (CRLF kırpılır). Hata/EOF'ta boş `str` ( `.nox` bunu "okuma başarısız" sayar).
export fn nox_smtp_read_line_raw(rt: ?*anyopaque, handle: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const c = smtp(handle) orelse return dupeStr(rt, "");
    if (!c.tcp.ok) return dupeStr(rt, "");
    const line = tcp.readLine(c.tcp) orelse {
        if (c.tcp.errmsg.len == 0) c.tcp.setErr("connection closed");
        return dupeStr(rt, "");
    };
    defer gpa.free(line);
    return dupeStr(rt, line);
}

export fn nox_smtp_starttls_raw(handle: ?*anyopaque) callconv(.c) i64 {
    const c = smtp(handle) orelse return 0;
    return if (tcp.startTls(c.tcp, c.host)) 1 else 0;
}

export fn nox_smtp_base64_encode_raw(rt: ?*anyopaque, s: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const text = std.mem.span(s orelse return dupeStr(rt, ""));
    const out_len = std.base64.standard.Encoder.calcSize(text.len);
    const buf = gpa.alloc(u8, out_len) catch return dupeStr(rt, "");
    defer gpa.free(buf);
    return dupeStr(rt, std.base64.standard.Encoder.encode(buf, text));
}

export fn nox_smtp_base64_auth_plain_raw(rt: ?*anyopaque, username: ?[*:0]const u8, password: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const u = std.mem.span(username orelse return dupeStr(rt, ""));
    const p = std.mem.span(password orelse return dupeStr(rt, ""));
    const payload = std.fmt.allocPrint(gpa, "\x00{s}\x00{s}", .{ u, p }) catch return dupeStr(rt, "");
    defer gpa.free(payload);
    const buf = gpa.alloc(u8, std.base64.standard.Encoder.calcSize(payload.len)) catch return dupeStr(rt, "");
    defer gpa.free(buf);
    return dupeStr(rt, std.base64.standard.Encoder.encode(buf, payload));
}

export fn nox_smtp_close_raw(handle: ?*anyopaque) callconv(.c) void {
    const c = smtp(handle) orelse return;
    tcp.close(c.tcp);
    gpa.free(c.host);
    gpa.destroy(c);
}

export fn nox_smtp_is_null_ptr(p: ?*anyopaque) callconv(.c) i64 {
    return if (p == null) 1 else 0;
}
