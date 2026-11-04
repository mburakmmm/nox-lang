//! WASM\'da `nox.postgres` (spec §3.358): libpq yerine Zig\'de yazılmış PostgreSQL protokol 3.0 istemcisi, `tcp_host.zig` (host TCP) üzerinde. `nox_pg_*` imzaları `postgres.zig` ile
//! BİREBİR aynıdır. Kimlik doğrulama: trust, cleartext, MD5, SCRAM-SHA-256. Sorgular: basit protokol (`exec`) ve genişletilmiş protokol (`exec_params`: Parse/Bind/Describe/Execute/Sync,
//! metin biçimli parametreler ve sonuçlar). `sslmode=require|verify-*` SSLRequest + host TLS\'i (sertifikayı host doğrular); diğer kipler düz metindir (libpq\'nun `prefer` varsayılanından
//! bilinçli sapma: host TLS\'i her zaman doğruladığından "prefer" kendinden imzalı sunucularda başarısız olurdu).

const std = @import("std");
const builtin = @import("builtin");
const str_mod = @import("../str.zig");
const shim_util = @import("shim_util.zig");
const tcp = @import("tcp_host.zig");
const proto = @import("pg_proto.zig");
const abi_layout = @import("abi_layout");

const gpa = std.heap.page_allocator;
const LIST_HEADER_SIZE = abi_layout.LIST_HEADER_SIZE;
const FIELD_SLOT_SIZE = abi_layout.FIELD_SLOT_SIZE;

const Conn = struct {
    tcp: *tcp.Conn,
    ok: bool = false,
    errmsg: []const u8 = "",
    errmsg_owned: bool = false,

    fn setErr(self: *Conn, msg: []const u8) void {
        if (self.errmsg_owned) gpa.free(self.errmsg);
        if (gpa.dupe(u8, msg)) |d| {
            self.errmsg = d;
            self.errmsg_owned = true;
        } else |_| {
            self.errmsg = "out of memory";
            self.errmsg_owned = false;
        }
    }
};

const Result = struct {
    ok: bool = false,
    errmsg: []const u8 = "",
    errmsg_owned: bool = false,
    cols: std.ArrayListUnmanaged([]u8) = .empty,
    /// Düz dizi: satır * nfields + sütun; `null` = SQL NULL.
    cells: std.ArrayListUnmanaged(?[]u8) = .empty,
    ntuples: usize = 0,
    changes: i64 = 0,

    fn deinit(self: *Result) void {
        for (self.cols.items) |c| gpa.free(c);
        self.cols.deinit(gpa);
        for (self.cells.items) |c| if (c) |b| gpa.free(b);
        self.cells.deinit(gpa);
        if (self.errmsg_owned) gpa.free(self.errmsg);
        gpa.destroy(self);
    }
};

// ---- Okuma/yazma yardımcıları ----------------------------------------------------------------------------------------------------------------------

fn readExact(c: *tcp.Conn, out: []u8) bool {
    var got: usize = 0;
    while (got < out.len) {
        const chunk = tcp.readSome(c, out.len - got);
        if (chunk.len == 0) return false;
        @memcpy(out[got .. got + chunk.len], chunk);
        got += chunk.len;
    }
    return true;
}

const Msg = struct { tag: u8, body: []u8 };

/// Bir arka uç iletisi okur (gövde `gpa` ile tahsislidir). Hata/EOF\'ta `null`.
fn readMsg(c: *tcp.Conn) ?Msg {
    var head: [5]u8 = undefined;
    if (!readExact(c, &head)) return null;
    const len = std.mem.readInt(u32, head[1..5], .big);
    if (len < 4 or len > 1 << 30) return null;
    const body = gpa.alloc(u8, len - 4) catch return null;
    if (!readExact(c, body)) {
        gpa.free(body);
        return null;
    }
    return .{ .tag = head[0], .body = body };
}

/// ErrorResponse/NoticeResponse alanlarından libpq biçimli ileti: `SEVERITY:  message\n`.
fn formatError(a: std.mem.Allocator, body: []const u8) []u8 {
    var sev: []const u8 = "ERROR";
    var msg: []const u8 = "unknown error";
    var i: usize = 0;
    while (i < body.len and body[i] != 0) {
        const code = body[i];
        const end = std.mem.indexOfScalarPos(u8, body, i + 1, 0) orelse body.len;
        const val = body[i + 1 .. end];
        if (code == 'S') sev = val else if (code == 'M') msg = val;
        i = end + 1;
    }
    return std.fmt.allocPrint(a, "{s}:  {s}\n", .{ sev, msg }) catch @constCast("ERROR:  out of memory\n");
}

fn sendAll(c: *tcp.Conn, bytes: []const u8) bool {
    return tcp.write(c, bytes);
}

fn sendTagged(c: *tcp.Conn, tag: u8, body: []const u8) bool {
    var out: proto.Buf = .empty;
    defer out.deinit(gpa);
    proto.finishTagged(gpa, &out, tag, body) catch return false;
    return sendAll(c, out.items);
}

fn fillRandom(buf: []u8) void {
    if (comptime @import("../wasm_host.zig").is_freestanding_wasm) {
        @import("../wasm_host.zig").random_fill(buf.ptr, buf.len);
    } else {
        @memset(buf, 4);
    }
}

// ---- Bağlantı --------------------------------------------------------------------------------------------------------------------------------------

fn authenticate(conn: *Conn, info: proto.ConnInfo) bool {
    const c = conn.tcp;
    var scram: ?proto.Scram = null;
    while (true) {
        const m = readMsg(c) orelse {
            conn.setErr("connection closed during authentication");
            return false;
        };
        defer gpa.free(m.body);
        switch (m.tag) {
            'R' => {
                if (m.body.len < 4) return false;
                const kind = std.mem.readInt(u32, m.body[0..4], .big);
                switch (kind) {
                    0 => {}, // AuthenticationOk
                    3 => {
                        var b: proto.Buf = .empty;
                        defer b.deinit(gpa);
                        proto.putCStr(gpa, &b, info.password) catch return false;
                        if (!sendTagged(c, 'p', b.items)) return false;
                    },
                    5 => {
                        if (m.body.len < 8) return false;
                        const pw = proto.md5Password(gpa, info.user, info.password, m.body[4..8].*) catch return false;
                        defer gpa.free(pw);
                        var b: proto.Buf = .empty;
                        defer b.deinit(gpa);
                        proto.putCStr(gpa, &b, pw) catch return false;
                        if (!sendTagged(c, 'p', b.items)) return false;
                    },
                    10 => { // SASL: mekanizma listesi
                        if (std.mem.indexOf(u8, m.body[4..], "SCRAM-SHA-256") == null) {
                            conn.setErr("server offers no supported SASL mechanism (SCRAM-SHA-256 required)");
                            return false;
                        }
                        var raw: [18]u8 = undefined;
                        fillRandom(&raw);
                        var nonce: [24]u8 = undefined;
                        _ = std.base64.standard.Encoder.encode(&nonce, &raw);
                        const nonce_copy = gpa.dupe(u8, &nonce) catch return false; // SCRAM durumu boyunca yaşar
                        scram = proto.Scram.init(gpa, nonce_copy) catch return false;
                        const first = scram.?.clientFirst(gpa) catch return false;
                        defer gpa.free(first);
                        var b: proto.Buf = .empty;
                        defer b.deinit(gpa);
                        proto.putCStr(gpa, &b, "SCRAM-SHA-256") catch return false;
                        proto.putI32(gpa, &b, @intCast(first.len)) catch return false;
                        b.appendSlice(gpa, first) catch return false;
                        if (!sendTagged(c, 'p', b.items)) return false;
                    },
                    11 => { // SASLContinue
                        var sc = &(scram orelse return false);
                        const final = sc.clientFinal(gpa, info.password, m.body[4..]) catch {
                            conn.setErr("SCRAM authentication failed (bad server challenge)");
                            return false;
                        };
                        defer gpa.free(final);
                        if (!sendTagged(c, 'p', final)) return false;
                    },
                    12 => { // SASLFinal
                        const sc = &(scram orelse return false);
                        if (!sc.verifyServerFinal(m.body[4..])) {
                            conn.setErr("SCRAM server signature mismatch");
                            return false;
                        }
                    },
                    else => {
                        conn.setErr("unsupported authentication method requested by the server");
                        return false;
                    },
                }
            },
            'E' => {
                const e = formatError(gpa, m.body);
                defer gpa.free(e);
                conn.setErr(e);
                return false;
            },
            'S', 'K', 'N' => {}, // ParameterStatus / BackendKeyData / Notice
            'Z' => return true, // ReadyForQuery: oturum hazır
            else => {},
        }
    }
}

export fn nox_pg_connect_raw(conninfo: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    const s = conninfo orelse return null;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const info = proto.parseConnInfo(a, str_mod.nox_str_slice(s)) catch return null;
    const t = tcp.connect(info.host, info.port, false) orelse return null;
    const conn = gpa.create(Conn) catch {
        tcp.close(t);
        return null;
    };
    conn.* = .{ .tcp = t };
    if (!t.ok) {
        conn.setErr(t.errmsg);
        return conn;
    }
    if (info.require_tls) {
        if (!sendAll(t, &proto.ssl_request)) {
            conn.setErr("could not send SSLRequest");
            return conn;
        }
        var reply: [1]u8 = undefined;
        if (!readExact(t, &reply)) {
            conn.setErr("connection closed while negotiating TLS");
            return conn;
        }
        if (reply[0] != 'S') {
            conn.setErr("server does not support TLS (sslmode requires it)");
            return conn;
        }
        if (!tcp.startTls(t, info.host)) {
            conn.setErr(t.errmsg);
            return conn;
        }
    }
    const startup = proto.startupMessage(a, info) catch return conn;
    if (!sendAll(t, startup)) {
        conn.setErr("could not send the startup message");
        return conn;
    }
    if (authenticate(conn, info)) conn.ok = true;
    return conn;
}

export fn nox_pg_status_ok_raw(conn: ?*anyopaque) callconv(.c) i64 {
    const c: *Conn = @ptrCast(@alignCast(conn orelse return 0));
    return if (c.ok) 1 else 0;
}

export fn nox_pg_errmsg_raw(rt: ?*anyopaque, conn: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const c: *Conn = @ptrCast(@alignCast(conn orelse return shim_util.dupeToNoxStr(rt, "")));
    return shim_util.dupeToNoxStr(rt, c.errmsg);
}

export fn nox_pg_finish_raw(conn: ?*anyopaque) callconv(.c) void {
    const c: *Conn = @ptrCast(@alignCast(conn orelse return));
    if (c.ok) _ = sendTagged(c.tcp, 'X', "");
    tcp.close(c.tcp);
    if (c.errmsg_owned) gpa.free(c.errmsg);
    gpa.destroy(c);
}

// ---- Sorgular --------------------------------------------------------------------------------------------------------------------------------------

fn failResult(r: *Result, msg: []const u8) void {
    r.ok = false;
    if (r.errmsg_owned) gpa.free(r.errmsg);
    if (gpa.dupe(u8, msg)) |d| {
        r.errmsg = d;
        r.errmsg_owned = true;
    } else |_| {
        r.errmsg = "out of memory";
        r.errmsg_owned = false;
    }
}

fn parseRowDescription(r: *Result, body: []const u8) void {
    for (r.cols.items) |c| gpa.free(c);
    r.cols.clearRetainingCapacity();
    if (body.len < 2) return;
    const n = std.mem.readInt(u16, body[0..2], .big);
    var i: usize = 2;
    var k: usize = 0;
    while (k < n and i < body.len) : (k += 1) {
        const end = std.mem.indexOfScalarPos(u8, body, i, 0) orelse return;
        const name = gpa.dupe(u8, body[i..end]) catch return;
        r.cols.append(gpa, name) catch {
            gpa.free(name);
            return;
        };
        i = end + 1 + 18; // tableoid(4) attnum(2) typoid(4) typlen(2) typmod(4) format(2)
    }
}

fn parseDataRow(r: *Result, body: []const u8) void {
    if (body.len < 2) return;
    const n = std.mem.readInt(u16, body[0..2], .big);
    var i: usize = 2;
    var k: usize = 0;
    while (k < n and i + 4 <= body.len) : (k += 1) {
        const len = std.mem.readInt(i32, body[i..][0..4], .big);
        i += 4;
        if (len < 0) {
            r.cells.append(gpa, null) catch return;
        } else {
            const l: usize = @intCast(len);
            if (i + l > body.len) return;
            const v = gpa.dupe(u8, body[i .. i + l]) catch return;
            r.cells.append(gpa, v) catch {
                gpa.free(v);
                return;
            };
            i += l;
        }
    }
    r.ntuples += 1;
}

/// `ReadyForQuery` gelene kadar yanıtları okur; son sonucu döner (PQexec gibi son komutun sonucu).
fn collect(conn: *Conn) *Result {
    const r = gpa.create(Result) catch unreachable;
    r.* = .{ .ok = true };
    while (true) {
        const m = readMsg(conn.tcp) orelse {
            conn.ok = false;
            conn.setErr("server closed the connection unexpectedly");
            failResult(r, "server closed the connection unexpectedly\n");
            return r;
        };
        defer gpa.free(m.body);
        switch (m.tag) {
            'T' => {
                // Yeni sonuç kümesi: önceki (çok deyimli sorgu) atılır.
                for (r.cells.items) |c| if (c) |b| gpa.free(b);
                r.cells.clearRetainingCapacity();
                r.ntuples = 0;
                parseRowDescription(r, m.body);
            },
            'D' => parseDataRow(r, m.body),
            'C' => {
                const end = std.mem.indexOfScalar(u8, m.body, 0) orelse m.body.len;
                r.changes = proto.changesFromTag(m.body[0..end]);
            },
            'E' => {
                const e = formatError(gpa, m.body);
                defer gpa.free(e);
                failResult(r, e);
            },
            'Z' => return r,
            else => {}, // ParseComplete, BindComplete, NoData, EmptyQueryResponse, Notice, ParameterStatus, ...
        }
    }
}

export fn nox_pg_exec_raw(conn: ?*anyopaque, query: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    const c: *Conn = @ptrCast(@alignCast(conn orelse return null));
    const q = query orelse return null;
    const r = gpa.create(Result) catch return null;
    r.* = .{};
    if (!c.ok) {
        failResult(r, "no connection to the server\n");
        return r;
    }
    var b: proto.Buf = .empty;
    defer b.deinit(gpa);
    proto.putCStr(gpa, &b, str_mod.nox_str_slice(q)) catch return null;
    if (!sendTagged(c.tcp, 'Q', b.items)) {
        failResult(r, "could not send the query\n");
        return r;
    }
    gpa.destroy(r);
    return collect(c);
}

fn listItem(list: *anyopaque, i: usize) []const u8 {
    const bytes: [*]u8 = @ptrCast(list);
    const addr: usize = @intCast(@as(u64, @bitCast(@as(*align(1) i64, @ptrCast(bytes + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i)).*)));
    const p: [*:0]const u8 = @ptrFromInt(addr);
    return str_mod.nox_str_slice(p);
}

export fn nox_pg_exec_params_raw(conn: ?*anyopaque, query: ?[*:0]const u8, params_list: ?*anyopaque, null_flags_list: ?*anyopaque) callconv(.c) ?*anyopaque {
    const c: *Conn = @ptrCast(@alignCast(conn orelse return null));
    const q = query orelse return null;
    const r = gpa.create(Result) catch return null;
    r.* = .{};
    if (!c.ok) {
        failResult(r, "no connection to the server\n");
        return r;
    }
    const count: usize = if (params_list) |p| @intCast(@as(*align(1) i64, @ptrCast(@as([*]u8, @ptrCast(p)))).*) else 0;

    var out: proto.Buf = .empty;
    defer out.deinit(gpa);
    var body: proto.Buf = .empty;
    defer body.deinit(gpa);
    // Parse: adsız ifade, parametre tipleri sunucuya bırakılır.
    proto.putCStr(gpa, &body, "") catch return null;
    proto.putCStr(gpa, &body, str_mod.nox_str_slice(q)) catch return null;
    proto.putI16(gpa, &body, 0) catch return null;
    proto.finishTagged(gpa, &out, 'P', body.items) catch return null;
    // Bind: adsız portal/ifade, tüm parametreler metin, sonuçlar metin.
    body.clearRetainingCapacity();
    proto.putCStr(gpa, &body, "") catch return null;
    proto.putCStr(gpa, &body, "") catch return null;
    proto.putI16(gpa, &body, 0) catch return null;
    proto.putI16(gpa, &body, @intCast(count)) catch return null;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const is_null = if (null_flags_list) |nf| listItem(nf, i)[0] == '1' else false;
        if (is_null) {
            proto.putI32(gpa, &body, -1) catch return null;
        } else {
            const v = listItem(params_list.?, i);
            proto.putI32(gpa, &body, @intCast(v.len)) catch return null;
            body.appendSlice(gpa, v) catch return null;
        }
    }
    proto.putI16(gpa, &body, 0) catch return null;
    proto.finishTagged(gpa, &out, 'B', body.items) catch return null;
    // Describe portal, Execute (sınırsız), Sync.
    proto.finishTagged(gpa, &out, 'D', "P\x00") catch return null;
    proto.finishTagged(gpa, &out, 'E', "\x00\x00\x00\x00\x00") catch return null;
    proto.finishTagged(gpa, &out, 'S', "") catch return null;
    if (!sendAll(c.tcp, out.items)) {
        failResult(r, "could not send the query\n");
        return r;
    }
    gpa.destroy(r);
    return collect(c);
}

fn res(h: ?*anyopaque) ?*Result {
    return @ptrCast(@alignCast(h orelse return null));
}

export fn nox_pg_result_ok_raw(r: ?*anyopaque) callconv(.c) i64 {
    const x = res(r) orelse return 0;
    return if (x.ok) 1 else 0;
}

export fn nox_pg_result_errmsg_raw(rt: ?*anyopaque, r: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const x = res(r) orelse return shim_util.dupeToNoxStr(rt, "");
    return shim_util.dupeToNoxStr(rt, x.errmsg);
}

export fn nox_pg_ntuples_raw(r: ?*anyopaque) callconv(.c) i64 {
    const x = res(r) orelse return 0;
    return @intCast(x.ntuples);
}

export fn nox_pg_nfields_raw(r: ?*anyopaque) callconv(.c) i64 {
    const x = res(r) orelse return 0;
    return @intCast(x.cols.items.len);
}

export fn nox_pg_fname_raw(rt: ?*anyopaque, r: ?*anyopaque, col: i64) callconv(.c) ?[*:0]u8 {
    const x = res(r) orelse return shim_util.dupeToNoxStr(rt, "");
    if (col < 0 or col >= x.cols.items.len) return shim_util.dupeToNoxStr(rt, "");
    return shim_util.dupeToNoxStr(rt, x.cols.items[@intCast(col)]);
}

fn cell(x: *Result, row: i64, col: i64) ??[]u8 {
    if (row < 0 or col < 0 or col >= x.cols.items.len or row >= x.ntuples) return null;
    return x.cells.items[@as(usize, @intCast(row)) * x.cols.items.len + @as(usize, @intCast(col))];
}

export fn nox_pg_getvalue_raw(rt: ?*anyopaque, r: ?*anyopaque, row: i64, col: i64) callconv(.c) ?[*:0]u8 {
    const x = res(r) orelse return shim_util.dupeToNoxStr(rt, "");
    const v = (cell(x, row, col) orelse return shim_util.dupeToNoxStr(rt, "")) orelse return shim_util.dupeToNoxStr(rt, "");
    return shim_util.dupeToNoxStr(rt, v);
}

export fn nox_pg_getisnull_raw(r: ?*anyopaque, row: i64, col: i64) callconv(.c) i64 {
    const x = res(r) orelse return 1;
    const v = cell(x, row, col) orelse return 1;
    return if (v == null) 1 else 0;
}

export fn nox_pg_changes_raw(r: ?*anyopaque) callconv(.c) i64 {
    const x = res(r) orelse return 0;
    return x.changes;
}

export fn nox_pg_clear_raw(r: ?*anyopaque) callconv(.c) void {
    const x = res(r) orelse return;
    x.deinit();
}

export fn nox_pg_is_null_ptr(p: ?*anyopaque) callconv(.c) i64 {
    return if (p == null) 1 else 0;
}
