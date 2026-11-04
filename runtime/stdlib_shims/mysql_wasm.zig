//! WASM'da `nox.mysql` (spec §3.361): libmysqlclient yerine Zig'de yazılmış MySQL/MariaDB istemci protokolü, `tcp_host.zig` (host TCP) üzerinde. `nox_mysql_*` imzaları `mysql.zig` ile
//! BİREBİR aynıdır. Kimlik doğrulama: `mysql_native_password` ve `caching_sha2_password` (hızlı yol; tam kimlik doğrulamada sunucunun RSA anahtarıyla OAEP şifrelenmiş parola, yani TLS
//! gerekmez), kimlik doğrulama eklentisi değiştirme (AuthSwitchRequest) dahil. Sorgular: metin protokolü (`COM_QUERY`); sonuçlar satır satır değil, yanıt bitince bellekte tutulur.
//! Sınırlar: TLS yok (host TLS'i ileride eklenebilir), `host` her zaman TCP'dir (`localhost` için de unix soketi yok), çoklu sonuç kümelerinde yalnızca ilki döner.

const std = @import("std");
const str_mod = @import("../str.zig");
const shim_util = @import("shim_util.zig");
const tcp = @import("tcp_host.zig");
const proto = @import("mysql_proto.zig");

const gpa = std.heap.page_allocator;

const Row = struct { cells: []?[]u8 };

const Result = struct {
    cols: std.ArrayListUnmanaged([]u8) = .empty,
    rows: std.ArrayListUnmanaged(Row) = .empty,
    cursor: usize = 0,

    fn deinit(self: *Result) void {
        for (self.cols.items) |c| gpa.free(c);
        self.cols.deinit(gpa);
        for (self.rows.items) |r| {
            for (r.cells) |c| if (c) |b| gpa.free(b);
            gpa.free(r.cells);
        }
        self.rows.deinit(gpa);
        gpa.destroy(self);
    }
};

const Conn = struct {
    tcp: *tcp.Conn,
    ok: bool = false,
    seq: u8 = 0,
    status: u16 = 0,
    affected: u64 = 0,
    insert_id: u64 = 0,
    field_count: usize = 0,
    pending: ?*Result = null,
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

    fn clearErr(self: *Conn) void {
        if (self.errmsg_owned) gpa.free(self.errmsg);
        self.errmsg = "";
        self.errmsg_owned = false;
    }

    fn dropPending(self: *Conn) void {
        if (self.pending) |p| p.deinit();
        self.pending = null;
    }
};

fn fillRandom(buf: []u8) void {
    if (comptime @import("../wasm_host.zig").is_freestanding_wasm) {
        @import("../wasm_host.zig").random_fill(buf.ptr, buf.len);
    } else {
        @memset(buf, 4);
    }
}

// ---- Paket G/Ç -------------------------------------------------------------------------------------------------------------------------------------

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

/// Bir mantıksal paketi (0xFFFFFF bayt ve katlarındaki devam paketleri dahil) `payload`a okur (önceki içerik silinir). Hata/EOF'ta `false`.
fn readPacket(conn: *Conn, payload: *proto.Buf) bool {
    payload.clearRetainingCapacity();
    while (true) {
        var head: [4]u8 = undefined;
        if (!readExact(conn.tcp, &head)) return false;
        const len: usize = @as(usize, head[0]) | (@as(usize, head[1]) << 8) | (@as(usize, head[2]) << 16);
        conn.seq = head[3] +% 1;
        const start = payload.items.len;
        payload.resize(gpa, start + len) catch return false;
        if (!readExact(conn.tcp, payload.items[start..])) return false;
        if (len < 0xFFFFFF) return true;
    }
}

/// Mantıksal bir paketi yazar (gerekirse 0xFFFFFF'lik parçalara bölerek).
fn writePacket(conn: *Conn, payload: []const u8) bool {
    var rest = payload;
    var out: proto.Buf = .empty;
    defer out.deinit(gpa);
    while (true) {
        const n = @min(rest.len, 0xFFFFFF);
        out.clearRetainingCapacity();
        out.appendSlice(gpa, &.{ @intCast(n & 0xFF), @intCast((n >> 8) & 0xFF), @intCast((n >> 16) & 0xFF), conn.seq }) catch return false;
        out.appendSlice(gpa, rest[0..n]) catch return false;
        conn.seq +%= 1;
        if (!tcp.write(conn.tcp, out.items)) return false;
        rest = rest[n..];
        if (n < 0xFFFFFF) return true;
    }
}

fn protoErr(conn: *Conn, payload: []const u8) void {
    conn.setErr(proto.errMessage(payload));
}

// ---- Bağlantı --------------------------------------------------------------------------------------------------------------------------------------

fn authenticate(conn: *Conn, user: []const u8, password: []const u8, db: []const u8) bool {
    var pkt: proto.Buf = .empty;
    defer pkt.deinit(gpa);
    if (!readPacket(conn, &pkt)) {
        conn.setErr("connection closed while reading the server greeting");
        return false;
    }
    if (pkt.items.len > 0 and pkt.items[0] == 0xFF) {
        protoErr(conn, pkt.items);
        return false;
    }
    const hs = proto.parseHandshake(gpa, pkt.items) catch |e| {
        conn.setErr(if (e == error.UnsupportedProtocol) "unsupported MySQL protocol version" else "malformed server greeting");
        return false;
    };
    // `hs.server_version`/`hs.plugin` pkt'ye işaret eder; pkt bir sonraki readPacket'te değişir, bu yüzden gerekenleri kopyalarız.
    var scramble = hs.scramble;
    defer gpa.free(scramble);
    var plugin_buf: [64]u8 = undefined;
    const plugin_len = @min(hs.plugin.len, plugin_buf.len);
    @memcpy(plugin_buf[0..plugin_len], hs.plugin[0..plugin_len]);
    var plugin: []const u8 = plugin_buf[0..plugin_len];

    var auth_buf: [32]u8 = undefined;
    const first = proto.authResponse(plugin, password, scramble, &auth_buf) orelse {
        conn.setErr("unsupported authentication plugin requested by the server");
        return false;
    };
    var resp = proto.handshakeResponse(gpa, user, first, db, plugin) catch return false;
    defer resp.deinit(gpa);
    if (!writePacket(conn, resp.items)) {
        conn.setErr("could not send the handshake response");
        return false;
    }

    var want_key = false;
    while (true) {
        if (!readPacket(conn, &pkt)) {
            conn.setErr("connection closed during authentication");
            return false;
        }
        if (pkt.items.len == 0) return false;
        switch (pkt.items[0]) {
            0x00 => {
                const ok = proto.parseOk(pkt.items) orelse return false;
                conn.status = ok.status;
                return true;
            },
            0xFF => {
                protoErr(conn, pkt.items);
                return false;
            },
            0xFE => { // AuthSwitchRequest: eklenti adı + yeni tuz
                if (pkt.items.len == 1) {
                    conn.setErr("the server requested the pre-4.1 password hash, which is not supported");
                    return false;
                }
                var r: proto.Reader = .{ .buf = pkt.items, .pos = 1 };
                const name = r.cstr();
                var data = r.buf[r.pos..];
                if (data.len > 0 and data[data.len - 1] == 0) data = data[0 .. data.len - 1];
                const new_scr = gpa.dupe(u8, data) catch return false;
                gpa.free(scramble);
                scramble = new_scr;
                const n = @min(name.len, plugin_buf.len);
                @memcpy(plugin_buf[0..n], name[0..n]);
                plugin = plugin_buf[0..n];
                const ar = proto.authResponse(plugin, password, scramble, &auth_buf) orelse {
                    conn.setErr("unsupported authentication plugin requested by the server");
                    return false;
                };
                if (!writePacket(conn, ar)) return false;
            },
            0x01 => { // AuthMoreData
                const data = pkt.items[1..];
                if (want_key) {
                    var seed: [20]u8 = undefined;
                    fillRandom(&seed);
                    const enc = proto.encryptPassword(gpa, data, password, scramble, seed) catch {
                        conn.setErr("could not encrypt the password with the server's public key");
                        return false;
                    };
                    defer gpa.free(enc);
                    if (!writePacket(conn, enc)) return false;
                    want_key = false;
                } else if (data.len > 0 and data[0] == 3) {
                    // Hızlı kimlik doğrulama başarılı; OK paketi gelecek.
                } else if (data.len > 0 and data[0] == 4) {
                    // Tam kimlik doğrulama: TLS yok, bu yüzden sunucunun RSA genel anahtarı istenir.
                    if (!writePacket(conn, &.{0x02})) return false;
                    want_key = true;
                } else {
                    conn.setErr("unexpected authentication continuation from the server");
                    return false;
                }
            },
            else => {
                conn.setErr("unexpected packet during authentication");
                return false;
            },
        }
    }
}

export fn nox_mysql_connect_raw(host: ?[*:0]const u8, user: ?[*:0]const u8, passwd: ?[*:0]const u8, db: ?[*:0]const u8, port: i64) callconv(.c) ?*anyopaque {
    const h = if (host) |p| str_mod.nox_str_slice(p) else "";
    const u = if (user) |p| str_mod.nox_str_slice(p) else "";
    const pw = if (passwd) |p| str_mod.nox_str_slice(p) else "";
    const d = if (db) |p| str_mod.nox_str_slice(p) else "";
    const t = tcp.connect(if (h.len == 0) "127.0.0.1" else h, if (port <= 0) 3306 else port, false) orelse return null;
    const conn = gpa.create(Conn) catch {
        tcp.close(t);
        return null;
    };
    conn.* = .{ .tcp = t };
    if (!t.ok) {
        conn.setErr(t.errmsg);
        return conn;
    }
    if (authenticate(conn, u, pw, d)) conn.ok = true else if (conn.errmsg.len == 0) conn.setErr("authentication failed");
    return conn;
}

export fn nox_mysql_status_ok_raw(conn: ?*anyopaque) callconv(.c) i64 {
    const c: *Conn = @ptrCast(@alignCast(conn orelse return 0));
    return if (c.ok and c.errmsg.len == 0) 1 else 0;
}

export fn nox_mysql_errmsg_raw(rt: ?*anyopaque, conn: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const c: *Conn = @ptrCast(@alignCast(conn orelse return shim_util.dupeToNoxStr(rt, "")));
    return shim_util.dupeToNoxStr(rt, c.errmsg);
}

export fn nox_mysql_close_raw(conn: ?*anyopaque) callconv(.c) void {
    const c: *Conn = @ptrCast(@alignCast(conn orelse return));
    if (c.ok) {
        c.seq = 0;
        _ = writePacket(c, &.{proto.COM_QUIT});
    }
    c.dropPending();
    tcp.close(c.tcp);
    c.clearErr();
    gpa.destroy(c);
}

// ---- Sorgular --------------------------------------------------------------------------------------------------------------------------------------

const Outcome = union(enum) {
    ok: proto.Ok,
    rs: struct { res: *Result, status: u16 },
    err,
    io,
};

/// Bir sorgu yanıtının tek sonuç parçasını okur (OK, ERR ya da sonuç kümesi).
fn readResponse(conn: *Conn, pkt: *proto.Buf) Outcome {
    if (!readPacket(conn, pkt)) {
        conn.ok = false;
        conn.setErr("server closed the connection unexpectedly");
        return .io;
    }
    if (pkt.items.len == 0) return .io;
    switch (pkt.items[0]) {
        0x00 => return .{ .ok = proto.parseOk(pkt.items) orelse return .io },
        0xFF => {
            protoErr(conn, pkt.items);
            return .err;
        },
        0xFB => {
            conn.setErr("LOCAL INFILE is not supported");
            return .err;
        },
        else => {},
    }
    var r: proto.Reader = .{ .buf = pkt.items };
    var nm = false;
    const ncols: usize = @intCast(r.lenenc(&nm) orelse return .io);
    const res = gpa.create(Result) catch return .io;
    res.* = .{};
    var i: usize = 0;
    while (i < ncols) : (i += 1) {
        if (!readPacket(conn, pkt)) {
            res.deinit();
            conn.ok = false;
            conn.setErr("server closed the connection unexpectedly");
            return .io;
        }
        const name = proto.columnName(pkt.items) orelse "";
        const copy = gpa.dupe(u8, name) catch {
            res.deinit();
            return .io;
        };
        res.cols.append(gpa, copy) catch {
            gpa.free(copy);
            res.deinit();
            return .io;
        };
    }
    // Sütun tanımlarından sonraki EOF (CLIENT_DEPRECATE_EOF istenmedi).
    if (!readPacket(conn, pkt) or !proto.isEof(pkt.items)) {
        res.deinit();
        conn.ok = false;
        conn.setErr("malformed result set (missing column terminator)");
        return .io;
    }
    var status: u16 = 0;
    while (true) {
        if (!readPacket(conn, pkt)) {
            res.deinit();
            conn.ok = false;
            conn.setErr("server closed the connection unexpectedly");
            return .io;
        }
        if (proto.isEof(pkt.items)) {
            status = proto.eofStatus(pkt.items);
            break;
        }
        if (pkt.items.len > 0 and pkt.items[0] == 0xFF) {
            protoErr(conn, pkt.items);
            res.deinit();
            return .err;
        }
        const cells = gpa.alloc(?[]u8, ncols) catch {
            res.deinit();
            return .io;
        };
        @memset(cells, null);
        var rr: proto.Reader = .{ .buf = pkt.items };
        var k: usize = 0;
        var bad = false;
        while (k < ncols) : (k += 1) {
            const v = rr.lenencStr() catch {
                bad = true;
                break;
            };
            if (v) |bytes| cells[k] = gpa.dupe(u8, bytes) catch {
                bad = true;
                break;
            };
        }
        if (bad) {
            for (cells) |c| if (c) |b| gpa.free(b);
            gpa.free(cells);
            res.deinit();
            conn.ok = false;
            conn.setErr("malformed result row");
            return .io;
        }
        res.rows.append(gpa, .{ .cells = cells }) catch {
            for (cells) |c| if (c) |b| gpa.free(b);
            gpa.free(cells);
            res.deinit();
            return .io;
        };
    }
    return .{ .rs = .{ .res = res, .status = status } };
}

export fn nox_mysql_query_raw(conn: ?*anyopaque, stmt_str: ?[*:0]const u8) callconv(.c) i64 {
    const c: *Conn = @ptrCast(@alignCast(conn orelse return 1));
    const sql = stmt_str orelse return 1;
    c.clearErr();
    c.dropPending();
    c.field_count = 0;
    c.affected = 0;
    if (!c.ok) {
        c.setErr("no connection to the server");
        return 1;
    }
    var payload: proto.Buf = .empty;
    defer payload.deinit(gpa);
    payload.append(gpa, proto.COM_QUERY) catch return 1;
    payload.appendSlice(gpa, str_mod.nox_str_slice(sql)) catch return 1;
    c.seq = 0;
    if (!writePacket(c, payload.items)) {
        c.ok = false;
        c.setErr("could not send the query");
        return 1;
    }
    var pkt: proto.Buf = .empty;
    defer pkt.deinit(gpa);
    var first_failed = false;
    var more = true;
    var first = true;
    while (more) {
        more = false;
        switch (readResponse(c, &pkt)) {
            .ok => |ok| {
                if (first) {
                    c.affected = ok.affected;
                    c.insert_id = ok.insert_id;
                }
                c.status = ok.status;
                more = ok.status & proto.SERVER_MORE_RESULTS_EXISTS != 0;
            },
            .rs => |r| {
                c.status = r.status;
                more = r.status & proto.SERVER_MORE_RESULTS_EXISTS != 0;
                if (first) {
                    c.field_count = r.res.cols.items.len;
                    c.affected = r.res.rows.items.len;
                    c.pending = r.res;
                } else r.res.deinit();
            },
            .err => {
                if (first) first_failed = true;
                more = false;
            },
            .io => return 1,
        }
        first = false;
    }
    return if (first_failed) 1 else 0;
}

export fn nox_mysql_field_count_raw(conn: ?*anyopaque) callconv(.c) i64 {
    const c: *Conn = @ptrCast(@alignCast(conn orelse return 0));
    return @intCast(c.field_count);
}

export fn nox_mysql_affected_rows_raw(conn: ?*anyopaque) callconv(.c) i64 {
    const c: *Conn = @ptrCast(@alignCast(conn orelse return 0));
    return @intCast(c.affected);
}

export fn nox_mysql_insert_id_raw(conn: ?*anyopaque) callconv(.c) i64 {
    const c: *Conn = @ptrCast(@alignCast(conn orelse return 0));
    return @intCast(c.insert_id);
}

export fn nox_mysql_store_result_raw(conn: ?*anyopaque) callconv(.c) ?*anyopaque {
    const c: *Conn = @ptrCast(@alignCast(conn orelse return null));
    const r = c.pending orelse return null;
    c.pending = null;
    return r;
}

fn resOf(h: ?*anyopaque) ?*Result {
    return @ptrCast(@alignCast(h orelse return null));
}

export fn nox_mysql_num_fields_raw(r: ?*anyopaque) callconv(.c) i64 {
    const x = resOf(r) orelse return 0;
    return @intCast(x.cols.items.len);
}

export fn nox_mysql_fname_raw(rt: ?*anyopaque, r: ?*anyopaque, col: i64) callconv(.c) ?[*:0]u8 {
    const x = resOf(r) orelse return shim_util.dupeToNoxStr(rt, "");
    if (col < 0 or col >= x.cols.items.len) return shim_util.dupeToNoxStr(rt, "");
    return shim_util.dupeToNoxStr(rt, x.cols.items[@intCast(col)]);
}

/// Sonraki satır; bitince `null`.
export fn nox_mysql_fetch_row_raw(r: ?*anyopaque) callconv(.c) ?*anyopaque {
    const x = resOf(r) orelse return null;
    if (x.cursor >= x.rows.items.len) return null;
    const row = &x.rows.items[x.cursor];
    x.cursor += 1;
    return row;
}

fn rowOf(h: ?*anyopaque) ?*Row {
    return @ptrCast(@alignCast(h orelse return null));
}

export fn nox_mysql_row_isnull_raw(row: ?*anyopaque, col: i64) callconv(.c) i64 {
    const r = rowOf(row) orelse return 1;
    if (col < 0 or col >= r.cells.len) return 1;
    return if (r.cells[@intCast(col)] == null) 1 else 0;
}

export fn nox_mysql_row_getvalue_raw(rt: ?*anyopaque, row: ?*anyopaque, col: i64) callconv(.c) ?[*:0]u8 {
    const r = rowOf(row) orelse return shim_util.dupeToNoxStr(rt, "");
    if (col < 0 or col >= r.cells.len) return shim_util.dupeToNoxStr(rt, "");
    const v = r.cells[@intCast(col)] orelse return shim_util.dupeToNoxStr(rt, "");
    return shim_util.dupeToNoxStr(rt, v);
}

export fn nox_mysql_free_result_raw(r: ?*anyopaque) callconv(.c) void {
    const x = resOf(r) orelse return;
    x.deinit();
}

export fn nox_mysql_is_null_ptr(p: ?*anyopaque) callconv(.c) i64 {
    return if (p == null) 1 else 0;
}

export fn nox_mysql_escape_raw(rt: ?*anyopaque, conn: ?*anyopaque, value: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const v = value orelse return shim_util.dupeToNoxStr(rt, "");
    const c: *Conn = @ptrCast(@alignCast(conn orelse return shim_util.dupeToNoxStr(rt, "")));
    const e = proto.escapeString(gpa, str_mod.nox_str_slice(v), c.status & proto.SERVER_STATUS_NO_BACKSLASH_ESCAPES != 0) catch return shim_util.dupeToNoxStr(rt, "");
    defer gpa.free(e);
    return shim_util.dupeToNoxStr(rt, e);
}
