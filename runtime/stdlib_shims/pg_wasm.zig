//! WASM\'da `nox.postgres` (spec §3.358): libpq yerine Zig\'de yazılmış PostgreSQL protokol 3.0 istemcisi, `tcp_host.zig` (host TCP) üzerinde. `nox_pg_*` imzaları `postgres.zig` ile
//! BİREBİR aynıdır. Kimlik doğrulama: trust, cleartext, MD5, SCRAM-SHA-256. Sorgular: basit protokol (`exec`) ve genişletilmiş protokol (`exec_params`: Parse/Bind/Describe/Execute/Sync,
//! metin biçimli parametreler ve sonuçlar). `sslmode=require|verify-*` SSLRequest + host TLS\'i (sertifikayı host doğrular); diğer kipler düz metindir (libpq\'nun `prefer` varsayılanından
//! bilinçli sapma: host TLS\'i her zaman doğruladığından "prefer" kendinden imzalı sunucularda başarısız olurdu).

const std = @import("std");
const builtin = @import("builtin");
const str_mod = @import("../str.zig");
const shim_util = @import("shim_util.zig");
// Taşıma derleme zamanında seçilir: WASM'da ana makine TCP'si (`tcp_host.zig`), yerel (iOS/Android) derlemede işletim sistemi soketleri (`tcp_native.zig`, v2.0.189). İkisi aynı arayüzü sağlar.
const tcp = if (builtin.cpu.arch.isWasm()) @import("tcp_host.zig") else @import("tcp_native.zig");
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
    /// İstemci tarafı sorgu zaman aşımı (v2.2.2; ms, 0 = kapalı): süre dolunca `CancelRequest` ayrı bir bağlantıdan gönderilir, sunucunun `57014` yanıtı beklenir ve bağlantı kullanılabilir kalır.
    timeout_ms: u32 = 0,
    /// `BackendKeyData` (iptal için) ve ana makine/port (iptal bağlantısı için; `gpa` sahibi).
    pid: u32 = 0,
    secret: u32 = 0,
    host: []u8 = &.{},
    port: u16 = 0,

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
    /// Sunucunun ham ErrorResponse gövdesi (alan kodu + NUL'lu değer çiftleri): `nox_pg_result_field_raw` buradan okur.
    err_body: []u8 = &.{},
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
        if (self.err_body.len > 0) gpa.free(self.err_body);
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

/// `readMsg`in `deadline_ms` sınırlı biçimi: ileti BAŞLAMADAN en çok `wait_ms` bekler (`tcp.waitReadable`); süre dolarsa `error.TimedOut`. İleti başladıktan sonra gövde normal okunur.
const ReadError = error{ TimedOut, Closed };

fn readMsgWithin(c: *tcp.Conn, wait_ms: u32) ReadError!Msg {
    if (!tcp.waitReadable(c, wait_ms)) return error.TimedOut;
    return readMsg(c) orelse error.Closed;
}

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
    } else if (comptime builtin.cpu.arch.isWasm()) {
        @memset(buf, 4); // WASI: ağ yeteneği yoktur, bağlantı kurulamaz (nonce kullanılmaz)
    } else {
        tcp.randomFill(buf); // yerel: SCRAM/kimlik doğrulama nonce'u tahmin edilemez olmalıdır
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
            'K' => if (m.body.len >= 8) { // BackendKeyData: iptal isteği için süreç kimliği + gizli anahtar
                conn.pid = std.mem.readInt(u32, m.body[0..4], .big);
                conn.secret = std.mem.readInt(u32, m.body[4..8], .big);
            },
            'S', 'N' => {}, // ParameterStatus / Notice
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
    conn.* = .{ .tcp = t, .port = info.port };
    conn.host = gpa.dupe(u8, info.host) catch &.{};
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

/// Saf Zig istemcisinde (iOS/Android yerel soketleri) istemci tarafı sorgu zaman aşımı ve iptal vardır (v2.2.2); wasm ana makine soketlerinde yoktur (süre sınırı etkisiz, `cancel` yalnızca yerel hedeflerde çalışır) — sunucu tarafı `statement_timeout` her yerde çalışır.
export fn nox_pg_set_timeout_raw(conn: ?*anyopaque, ms: i64) callconv(.c) void {
    const c: *Conn = @ptrCast(@alignCast(conn orelse return));
    c.timeout_ms = if (ms <= 0) 0 else @intCast(@min(ms, std.math.maxInt(u32)));
}

export fn nox_pg_cancel_raw(conn: ?*anyopaque) callconv(.c) i64 {
    const c: *Conn = @ptrCast(@alignCast(conn orelse return 0));
    return if (sendCancel(c)) 1 else 0;
}

export fn nox_pg_finish_raw(conn: ?*anyopaque) callconv(.c) void {
    const c: *Conn = @ptrCast(@alignCast(conn orelse return));
    if (c.ok) _ = sendTagged(c.tcp, 'X', "");
    tcp.close(c.tcp);
    if (c.errmsg_owned) gpa.free(c.errmsg);
    if (c.host.len > 0) gpa.free(c.host);
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

/// Sunucunun `CancelRequest`e verdiği yanıt (`57014` + `ReadyForQuery`) için bekleme payı.
const CANCEL_GRACE_MS: u64 = 10_000;

fn nowMs() u64 {
    if (comptime builtin.cpu.arch.isWasm()) return 0; // wasm host soketlerinde zaman aşımı yok (`tcp_host.waitReadable` hep hazır)
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(@divTrunc(ts.nsec, std.time.ns_per_ms)));
}

/// `CancelRequest` (protokol 3.0): AYRI, düz bir TCP bağlantısından 16 bayt (uzunluk, 80877102, süreç kimliği, gizli anahtar); sunucu iptali işleyip bağlantıyı kapatır. Gönderildiyse `true`.
fn sendCancel(conn: *Conn) bool {
    if (conn.host.len == 0 or conn.pid == 0) return false;
    const t = tcp.connect(conn.host, conn.port, false) orelse return false;
    defer tcp.close(t);
    if (!t.ok) return false;
    var msg: [16]u8 = undefined;
    std.mem.writeInt(u32, msg[0..4], 16, .big);
    std.mem.writeInt(u32, msg[4..8], 80877102, .big);
    std.mem.writeInt(u32, msg[8..12], conn.pid, .big);
    std.mem.writeInt(u32, msg[12..16], conn.secret, .big);
    if (!sendAll(t, &msg)) return false;
    // Sunucu işleyip bağlantıyı kapatır: EOF'u kısa süre bekle (yanıt gelmez).
    if (tcp.waitReadable(t, 2000)) _ = tcp.readSome(t, 1);
    return true;
}

/// `ReadyForQuery` gelene kadar yanıtları okur; son sonucu döner (PQexec gibi son komutun sonucu). `conn.timeout_ms > 0` ise süre dolunca iptal istenir (bkz. `sendCancel`), sunucunun hata yanıtı okunur ve bağlantı kullanılabilir kalır.
fn collect(conn: *Conn) *Result {
    const r = gpa.create(Result) catch unreachable;
    r.* = .{ .ok = true };
    var deadline: u64 = if (conn.timeout_ms > 0) nowMs() + conn.timeout_ms else 0;
    var cancelled = false;
    while (true) {
        const got: ReadError!Msg = if (deadline != 0) blk: {
            const now = nowMs();
            const left: u32 = if (deadline > now) @intCast(@min(deadline - now, std.math.maxInt(u32))) else 0;
            break :blk readMsgWithin(conn.tcp, left);
        } else (readMsg(conn.tcp) orelse error.Closed);
        const m = got catch |e| switch (e) {
            error.TimedOut => {
                if (!cancelled) {
                    cancelled = true;
                    _ = sendCancel(conn);
                    deadline = nowMs() + CANCEL_GRACE_MS;
                    continue;
                }
                conn.ok = false;
                conn.setErr("query timed out and the server did not answer the cancel request");
                failResult(r, "query timed out and the server did not answer the cancel request\n");
                return r;
            },
            error.Closed => {
                conn.ok = false;
                conn.setErr("server closed the connection unexpectedly");
                failResult(r, "server closed the connection unexpectedly\n");
                return r;
            },
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
                if (r.err_body.len > 0) gpa.free(r.err_body);
                r.err_body = gpa.dupe(u8, m.body) catch &.{};
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

/// `postgres.zig`nin `nox_pg_result_field_raw`ıyla aynı: ErrorResponse alanı ('S' önem, 'C' SQLSTATE, 'D' ayrıntı, 't' tablo, 'c' sütun, 'n' kısıt...).
export fn nox_pg_result_field_raw(rt: ?*anyopaque, r: ?*anyopaque, code: i64) callconv(.c) ?[*:0]u8 {
    const x = res(r) orelse return shim_util.dupeToNoxStr(rt, "");
    const body = x.err_body;
    var i: usize = 0;
    while (i < body.len and body[i] != 0) {
        const c = body[i];
        const end = std.mem.indexOfScalarPos(u8, body, i + 1, 0) orelse body.len;
        if (@as(i64, c) == code) return shim_util.dupeToNoxStr(rt, body[i + 1 .. end]);
        i = end + 1;
    }
    return shim_util.dupeToNoxStr(rt, "");
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

// ---- Test: gerçek PostgreSQL'e karşı istemci tarafı zaman aşımı ve iptal (v2.2.2; `zig build pg-mobile-test`; PostgreSQL ikilileri yoksa atlanır) ----

fn findPgBin(io: std.Io, name: []const u8, buf: []u8) ?[]const u8 {
    const roots = [_][]const u8{ "/opt/homebrew/opt/postgresql@{d}/bin", "/usr/local/opt/postgresql@{d}/bin", "/usr/lib/postgresql/{d}/bin" };
    var v: u32 = 20;
    while (v >= 12) : (v -= 1) {
        inline for (roots) |root| {
            var rb: [96]u8 = undefined;
            if (std.fmt.bufPrint(&rb, root, .{v})) |dir| {
                if (std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name })) |full| {
                    if (std.Io.Dir.cwd().access(io, full, .{})) |_| return full else |_| {}
                } else |_| {}
            } else |_| {}
        }
    }
    return null;
}

fn testFreePort() !u16 {
    const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    defer _ = std.c.close(fd);
    var addr: std.c.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) != 0) return error.BindFailed;
    var got: std.c.sockaddr.in = undefined;
    var len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
    if (std.c.getsockname(fd, @ptrCast(&got), &len) != 0) return error.GetsocknameFailed;
    return std.mem.bigToNative(u16, got.port);
}

test "nox_pg_set_timeout_raw: yavaş sorgu istemci tarafında iptal edilir (57014), bağlantı kullanılabilir kalır; nox_pg_cancel_raw başka bir görevden iptal eder" {
    if (comptime builtin.cpu.arch.isWasm() or builtin.os.tag == .windows) return error.SkipZigTest;
    const asap = @import("../alloc/asap.zig");
    const io = std.testing.io;
    var initdb_buf: [160]u8 = undefined;
    var postgres_buf: [160]u8 = undefined;
    const initdb = findPgBin(io, "initdb", &initdb_buf) orelse return error.SkipZigTest;
    const postgres = findPgBin(io, "postgres", &postgres_buf) orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    var data_sub_buf: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    const pgdata = try std.fmt.bufPrint(&data_sub_buf, "{s}/data", .{data_dir});

    // macOS'ta geçersiz/Türkçe yerel ayar `postmaster became multithreaded during startup` ile sunucuyu düşürür: çocuklara `LC_ALL=C` verilir.
    var env = try std.testing.environ.createMap(std.testing.allocator);
    defer env.deinit();
    try env.put("LC_ALL", "C");
    const init = try std.process.run(std.testing.allocator, io, .{ .argv = &.{ initdb, "-D", pgdata, "-A", "trust", "-U", "nox", "--no-sync" }, .environ_map = &env });
    defer std.testing.allocator.free(init.stdout);
    defer std.testing.allocator.free(init.stderr);
    if (init.term != .exited or init.term.exited != 0) return error.SkipZigTest;

    const port = try testFreePort();
    var port_buf: [8]u8 = undefined;
    const port_s = try std.fmt.bufPrint(&port_buf, "{d}", .{port});
    var child = try std.process.spawn(io, .{
        // Unix soketi kapalı: geçici dizin yolu (+ `.s.PGSQL.<port>`) macOS'un 104 baytlık `sun_path` sınırını aşabilir.
        .argv = &.{ postgres, "-D", pgdata, "-p", port_s, "-c", "unix_socket_directories=", "-c", "listen_addresses=127.0.0.1", "-c", "fsync=off" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .environ_map = &env,
    });
    defer child.kill(io);

    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    const str = @import("../str.zig");
    var conninfo_buf: [128]u8 = undefined;
    const conninfo = try std.fmt.bufPrint(&conninfo_buf, "host=127.0.0.1 port={d} user=nox dbname=postgres", .{port});
    const conninfo_s = str.nox_str_from_bytes(rt, conninfo) orelse return error.Failed;
    defer str.nox_str_release(rt, conninfo_s);

    // Sunucunun hazır olmasını bekle (en çok ~20 sn).
    var conn: ?*anyopaque = null;
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        const c = nox_pg_connect_raw(conninfo_s);
        if (c != null and nox_pg_status_ok_raw(c) == 1) {
            conn = c;
            break;
        }
        if (c) |cc| nox_pg_finish_raw(cc);
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    const c = conn orelse return error.SkipZigTest; // sunucu bu ortamda başlatılamadı (sandbox/yerel ayar): testi başarısız saymak yerine atla
    defer nox_pg_finish_raw(c);

    const sleep_q = str.nox_str_from_bytes(rt, "select pg_sleep(30)") orelse return error.Failed;
    defer str.nox_str_release(rt, sleep_q);
    const one_q = str.nox_str_from_bytes(rt, "select 1") orelse return error.Failed;
    defer str.nox_str_release(rt, one_q);

    // 1) İstemci zaman aşımı: 400 ms sonra iptal, SQLSTATE 57014, bağlantı kullanılabilir.
    nox_pg_set_timeout_raw(c, 400);
    const t0 = nowMs();
    const r1 = nox_pg_exec_raw(c, sleep_q) orelse return error.Failed;
    const elapsed = nowMs() - t0;
    try std.testing.expectEqual(@as(i64, 0), nox_pg_result_ok_raw(r1));
    const sqlstate = nox_pg_result_field_raw(rt, r1, 'C') orelse return error.Failed;
    defer str.nox_str_release(rt, sqlstate);
    try std.testing.expectEqualStrings("57014", std.mem.span(sqlstate));
    try std.testing.expect(elapsed >= 350 and elapsed < 8000);
    nox_pg_clear_raw(r1);
    try std.testing.expectEqual(@as(i64, 1), nox_pg_status_ok_raw(c));
    nox_pg_set_timeout_raw(c, 0);
    const r2 = nox_pg_exec_raw(c, one_q) orelse return error.Failed;
    try std.testing.expectEqual(@as(i64, 1), nox_pg_result_ok_raw(r2));
    nox_pg_clear_raw(r2);

    // 2) `cancel` başka bir iş parçacığından: yavaş sorgu sürerken iptal edilir.
    const Canceller = struct {
        fn run(conn_ptr: *anyopaque) void {
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 300 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
            _ = nox_pg_cancel_raw(conn_ptr);
        }
    };
    const th = try std.Thread.spawn(.{}, Canceller.run, .{c});
    const r3 = nox_pg_exec_raw(c, sleep_q) orelse return error.Failed;
    th.join();
    try std.testing.expectEqual(@as(i64, 0), nox_pg_result_ok_raw(r3));
    const st3 = nox_pg_result_field_raw(rt, r3, 'C') orelse return error.Failed;
    defer str.nox_str_release(rt, st3);
    try std.testing.expectEqualStrings("57014", std.mem.span(st3));
    nox_pg_clear_raw(r3);
}
