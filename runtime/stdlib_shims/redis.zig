//! `nox.redis` — saf Zig RESP2 istemcisi (Ember NL-001). `tcp_native.zig` taşıması üzerinde (düz TCP ya da bağlanır bağlanmaz TLS); `libhiredis` gerekmez.
//!
//! Komutlar `*N\r\n$len\r\n...` dizisi olarak gönderilir (argümanlar bayt-güvenlidir: gömülü NUL ve ikili yük aynen gider) ve yanıt özyinelemeli `Reply` ağacı olarak ayrıştırılır
//! (basit dize, hata, tamsayı, toplu dize, nil, dizi). Sunucu hata yanıtı (`-ERR ...`) bir G/Ç hatası DEĞİLDİR: `Reply` olarak döner, Nox tarafı onu `RedisError`a çevirir.
//! G/Ç hatasında (`null` yanıt) bağlantı kullanılamaz olur (`status == 0`); yeniden bağlanmak çağıranın işidir (`Client.reconnect`).
//!
//! Bağlantı `http_client.sharedClientIo()` üzerinden kurulur: bir fiber içinde okuma/yazma yalnızca o fiber'ı askıya alır. Okuma zaman aşımı YOKTUR (`XREADGROUP ... BLOCK` gibi
//! komutlar meşru olarak bekler); yanıt vermeyen bir sunucu çağrıyı bekletir.

const std = @import("std");
const builtin = @import("builtin");
const str_mod = @import("../str.zig");
const shim_util = @import("shim_util.zig");
const tcp = if (builtin.cpu.arch.isWasm()) @import("tcp_host.zig") else @import("tcp_native.zig");
const abi_layout = @import("abi_layout");

const gpa = std.heap.page_allocator;
const LIST_HEADER_SIZE = abi_layout.LIST_HEADER_SIZE;
const FIELD_SLOT_SIZE = abi_layout.FIELD_SLOT_SIZE;

const MAX_DEPTH = 32;
const MAX_BULK: i64 = 256 * 1024 * 1024;
const MAX_ARRAY: i64 = 16 * 1024 * 1024;

const Kind = enum(i64) { nil = 0, simple = 1, err = 2, integer = 3, bulk = 4, array = 5 };

const Reply = struct {
    kind: Kind = .nil,
    int: i64 = 0,
    data: []u8 = &.{},
    items: []Reply = &.{},

    fn deinit(self: *Reply) void {
        if (self.data.len > 0) gpa.free(self.data);
        for (self.items) |*it| it.deinit();
        if (self.items.len > 0) gpa.free(self.items);
        self.* = .{};
    }
};

const RConn = struct {
    c: *tcp.Conn,
    rbuf: std.ArrayListUnmanaged(u8) = .empty,
    rpos: usize = 0,
    ok: bool = false,
    errmsg: []const u8 = "",
    errmsg_owned: bool = false,

    fn setErr(self: *RConn, msg: []const u8) void {
        if (self.errmsg_owned) gpa.free(self.errmsg);
        if (gpa.dupe(u8, msg)) |d| {
            self.errmsg = d;
            self.errmsg_owned = true;
        } else |_| {
            self.errmsg = "out of memory";
            self.errmsg_owned = false;
        }
    }

    fn fail(self: *RConn, msg: []const u8) void {
        self.setErr(msg);
        self.ok = false;
    }

    /// Taşımadan bir parça daha okuyup tampona ekler (tüketilmiş önek atılır). Başarısızlıkta bağlantı kullanılamaz olur.
    fn fill(self: *RConn) bool {
        const chunk = tcp.readSome(self.c, 16 * 1024);
        if (chunk.len == 0) {
            self.fail(if (self.c.eof) "connection closed by the server" else (if (self.c.errmsg.len > 0) self.c.errmsg else "read failed"));
            return false;
        }
        if (self.rpos > 0) {
            const remaining = self.rbuf.items.len - self.rpos;
            std.mem.copyForwards(u8, self.rbuf.items[0..remaining], self.rbuf.items[self.rpos..]);
            self.rbuf.shrinkRetainingCapacity(remaining);
            self.rpos = 0;
        }
        self.rbuf.appendSlice(gpa, chunk) catch {
            self.fail("out of memory");
            return false;
        };
        return true;
    }

    /// Okunmamış tamponda en az `n` bayt olana kadar okur.
    fn need(self: *RConn, n: usize) bool {
        while (self.rbuf.items.len - self.rpos < n) {
            if (!self.fill()) return false;
        }
        return true;
    }

    /// `\r\n`'e kadar bir satır (CRLF hariç); dilim bir sonraki `fill`e kadar geçerlidir.
    fn line(self: *RConn) ?[]const u8 {
        while (true) {
            if (std.mem.indexOfPos(u8, self.rbuf.items, self.rpos, "\r\n")) |at| {
                const l = self.rbuf.items[self.rpos..at];
                self.rpos = at + 2;
                return l;
            }
            if (!self.fill()) return null;
        }
    }

    fn readReply(self: *RConn, out: *Reply, depth: usize) bool {
        if (depth > MAX_DEPTH) {
            self.fail("reply nested too deeply");
            return false;
        }
        const l = self.line() orelse return false;
        if (l.len == 0) {
            self.fail("protocol error: empty reply line");
            return false;
        }
        const t = l[0];
        const rest = l[1..];
        switch (t) {
            '+', '-' => {
                out.kind = if (t == '+') .simple else .err;
                out.data = gpa.dupe(u8, rest) catch {
                    self.fail("out of memory");
                    return false;
                };
            },
            ':' => {
                out.kind = .integer;
                out.int = std.fmt.parseInt(i64, rest, 10) catch {
                    self.fail("protocol error: bad integer");
                    return false;
                };
            },
            '$' => {
                const n = std.fmt.parseInt(i64, rest, 10) catch {
                    self.fail("protocol error: bad bulk length");
                    return false;
                };
                if (n < 0) {
                    out.kind = .nil;
                    return true;
                }
                if (n > MAX_BULK) {
                    self.fail("bulk reply too large");
                    return false;
                }
                const len: usize = @intCast(n);
                if (!self.need(len + 2)) return false;
                out.kind = .bulk;
                out.data = gpa.dupe(u8, self.rbuf.items[self.rpos .. self.rpos + len]) catch {
                    self.fail("out of memory");
                    return false;
                };
                self.rpos += len + 2;
            },
            '*' => {
                const n = std.fmt.parseInt(i64, rest, 10) catch {
                    self.fail("protocol error: bad array length");
                    return false;
                };
                if (n < 0) {
                    out.kind = .nil;
                    return true;
                }
                if (n > MAX_ARRAY) {
                    self.fail("array reply too large");
                    return false;
                }
                const count: usize = @intCast(n);
                out.kind = .array;
                if (count > 0) {
                    out.items = gpa.alloc(Reply, count) catch {
                        self.fail("out of memory");
                        return false;
                    };
                    for (out.items) |*it| it.* = .{};
                    for (out.items) |*it| {
                        if (!self.readReply(it, depth + 1)) return false;
                    }
                }
            },
            else => {
                self.fail("protocol error: unknown reply type");
                return false;
            },
        }
        return true;
    }
};

fn listItem(list: *anyopaque, i: usize) []const u8 {
    const bytes: [*]u8 = @ptrCast(list);
    const addr: usize = @intCast(@as(u64, @bitCast(@as(*align(1) i64, @ptrCast(bytes + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i)).*)));
    const p: [*:0]const u8 = @ptrFromInt(addr);
    return str_mod.nox_str_slice(p);
}

fn listLen(list: *anyopaque) usize {
    const bytes: [*]u8 = @ptrCast(list);
    return @intCast(@as(*align(1) i64, @ptrCast(bytes)).*);
}

fn encode(out: *std.ArrayListUnmanaged(u8), args: []const []const u8) !void {
    var num: [24]u8 = undefined;
    try out.appendSlice(gpa, try std.fmt.bufPrint(&num, "*{d}\r\n", .{args.len}));
    for (args) |a| {
        try out.appendSlice(gpa, try std.fmt.bufPrint(&num, "${d}\r\n", .{a.len}));
        try out.appendSlice(gpa, a);
        try out.appendSlice(gpa, "\r\n");
    }
}

/// Komutu gönderir ve yanıtı okur; G/Ç hatasında `null` (bağlantı kullanılamaz olur).
fn roundTrip(c: *RConn, args: []const []const u8) ?*Reply {
    if (!c.ok) return null;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    encode(&out, args) catch {
        c.fail("out of memory");
        return null;
    };
    if (!tcp.write(c.c, out.items)) {
        c.fail(if (c.c.errmsg.len > 0) c.c.errmsg else "write failed");
        return null;
    }
    const r = gpa.create(Reply) catch {
        c.fail("out of memory");
        return null;
    };
    r.* = .{};
    if (!c.readReply(r, 0)) {
        r.deinit();
        gpa.destroy(r);
        return null;
    }
    return r;
}

/// Bağlanır; `password` doluysa `AUTH` (kullanıcı adı doluysa `AUTH kullanıcı parola`), `db > 0` ise `SELECT db`. Başarısız olsa da geçerli bir tutamak döner (`status == 0`, `errmsg` dolu);
/// yalnızca bellek yetersizliğinde `null`.
pub export fn nox_redis_open_raw(host: ?[*:0]const u8, port: i64, use_tls: i64, user: ?[*:0]const u8, password: ?[*:0]const u8, db: i64) callconv(.c) ?*anyopaque {
    return openImpl(host, port, use_tls != 0, null, null, null, user, password, db);
}

/// `nox_redis_open_raw`ın TLS + özel CA dosyası (PEM) + isteğe bağlı istemci sertifikası/anahtarı (mTLS) eşleniği: `ca_file` doluysa sistem CA deposu YERİNE yalnızca o dosyadaki CA'lara güvenilir (özel/kurumsal CA, kendinden imzalı sunucu).
pub export fn nox_redis_open_tls_ca_raw(host: ?[*:0]const u8, port: i64, ca_file: ?[*:0]const u8, cert_file: ?[*:0]const u8, key_file: ?[*:0]const u8, user: ?[*:0]const u8, password: ?[*:0]const u8, db: i64) callconv(.c) ?*anyopaque {
    return openImpl(host, port, true, ca_file, cert_file, key_file, user, password, db);
}

fn openImpl(host: ?[*:0]const u8, port: i64, use_tls: bool, ca_file: ?[*:0]const u8, cert_file: ?[*:0]const u8, key_file: ?[*:0]const u8, user: ?[*:0]const u8, password: ?[*:0]const u8, db: i64) ?*anyopaque {
    const c = gpa.create(RConn) catch return null;
    const h = str_mod.nox_str_slice(host orelse "");
    // `nox_str_slice` Nox `str` başlığını okur: null işaretçi için DOĞRUDAN boş dilim kullan (bir Zig `""` değişmezinin başlığı yoktur).
    const ca: []const u8 = if (ca_file) |p| str_mod.nox_str_slice(p) else "";
    const cert: []const u8 = if (cert_file) |p| str_mod.nox_str_slice(p) else "";
    const key: []const u8 = if (key_file) |p| str_mod.nox_str_slice(p) else "";
    const custom_ca = use_tls and (ca.len > 0 or cert.len > 0);
    const tc = tcp.connect(h, port, use_tls and !custom_ca) orelse {
        gpa.destroy(c);
        return null;
    };
    if (custom_ca and tc.ok) {
        if (!tcp.startTlsMtls(tc, h, false, ca, cert, key)) {
            c.* = .{ .c = tc, .ok = false };
            c.setErr(if (tc.errmsg.len > 0) tc.errmsg else "TLS handshake failed");
            return c;
        }
    }
    c.* = .{ .c = tc, .ok = tc.ok };
    if (!tc.ok) {
        c.setErr(if (tc.errmsg.len > 0) tc.errmsg else "could not connect");
        return c;
    }
    const u = str_mod.nox_str_slice(user orelse "");
    const pw = str_mod.nox_str_slice(password orelse "");
    if (pw.len > 0) {
        const r = if (u.len > 0) roundTrip(c, &.{ "AUTH", u, pw }) else roundTrip(c, &.{ "AUTH", pw });
        if (r) |rep| {
            defer {
                rep.deinit();
                gpa.destroy(rep);
            }
            if (rep.kind == .err) {
                var buf: [256]u8 = undefined;
                c.fail(std.fmt.bufPrint(&buf, "authentication failed: {s}", .{rep.data}) catch "authentication failed");
                return c;
            }
        } else return c;
    }
    if (db > 0) {
        var num: [24]u8 = undefined;
        const ds = std.fmt.bufPrint(&num, "{d}", .{db}) catch "0";
        if (roundTrip(c, &.{ "SELECT", ds })) |rep| {
            defer {
                rep.deinit();
                gpa.destroy(rep);
            }
            if (rep.kind == .err) {
                var buf: [256]u8 = undefined;
                c.fail(std.fmt.bufPrint(&buf, "SELECT failed: {s}", .{rep.data}) catch "SELECT failed");
            }
        }
    }
    return c;
}

pub export fn nox_redis_status_raw(conn: ?*anyopaque) callconv(.c) i64 {
    const c: *RConn = @ptrCast(@alignCast(conn orelse return 0));
    return if (c.ok) 1 else 0;
}

pub export fn nox_redis_errmsg_raw(rt: ?*anyopaque, conn: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const c: *RConn = @ptrCast(@alignCast(conn orelse return shim_util.dupeToNoxStr(rt, "")));
    return shim_util.dupeToNoxStr(rt, c.errmsg);
}

pub export fn nox_redis_close_raw(conn: ?*anyopaque) callconv(.c) void {
    const c: *RConn = @ptrCast(@alignCast(conn orelse return));
    tcp.close(c.c);
    c.rbuf.deinit(gpa);
    if (c.errmsg_owned) gpa.free(c.errmsg);
    gpa.destroy(c);
}

/// `args` (list[str]) komutunu gönderir, yanıt ağacını döner; G/Ç hatasında `null`.
pub export fn nox_redis_command_raw(conn: ?*anyopaque, args_list: ?*anyopaque) callconv(.c) ?*anyopaque {
    const c: *RConn = @ptrCast(@alignCast(conn orelse return null));
    const list = args_list orelse return null;
    const n = listLen(list);
    if (n == 0) {
        c.setErr("empty command");
        return null;
    }
    const args = gpa.alloc([]const u8, n) catch {
        c.fail("out of memory");
        return null;
    };
    defer gpa.free(args);
    for (args, 0..) |*a, i| a.* = listItem(list, i);
    return roundTrip(c, args);
}

fn asReply(r: ?*anyopaque) ?*Reply {
    return @ptrCast(@alignCast(r orelse return null));
}

/// 0 nil, 1 basit dize, 2 hata, 3 tamsayı, 4 toplu dize, 5 dizi.
pub export fn nox_redis_reply_kind_raw(r: ?*anyopaque) callconv(.c) i64 {
    return @intFromEnum((asReply(r) orelse return 0).kind);
}

pub export fn nox_redis_reply_int_raw(r: ?*anyopaque) callconv(.c) i64 {
    return (asReply(r) orelse return 0).int;
}

pub export fn nox_redis_reply_str_raw(rt: ?*anyopaque, r: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const x = asReply(r) orelse return shim_util.dupeToNoxStr(rt, "");
    return shim_util.dupeToNoxStr(rt, x.data);
}

pub export fn nox_redis_reply_len_raw(r: ?*anyopaque) callconv(.c) i64 {
    return @intCast((asReply(r) orelse return 0).items.len);
}

/// `i`inci dizi öğesi (ebeveynin sahipliğinde ÖDÜNÇ; ebeveyn serbest bırakılınca geçersiz olur).
pub export fn nox_redis_reply_at_raw(r: ?*anyopaque, i: i64) callconv(.c) ?*anyopaque {
    const x = asReply(r) orelse return null;
    if (i < 0 or i >= x.items.len) return null;
    return &x.items[@intCast(i)];
}

pub export fn nox_redis_reply_free_raw(r: ?*anyopaque) callconv(.c) void {
    const x = asReply(r) orelse return;
    x.deinit();
    gpa.destroy(x);
}

pub export fn nox_redis_is_null_raw(p: ?*anyopaque) callconv(.c) i64 {
    return if (p == null) 1 else 0;
}

test "redis: komut kodlama ikili/NUL baytlı argümanları korur" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    // test allocator'ı yerine gpa kullanan encode: küçük bir elle doğrulama
    var tmp: std.ArrayListUnmanaged(u8) = .empty;
    defer tmp.deinit(gpa);
    try encode(&tmp, &.{ "SET", "k\x00ey", "" });
    try std.testing.expectEqualStrings("*3\r\n$3\r\nSET\r\n$4\r\nk\x00ey\r\n$0\r\n\r\n", tmp.items);
}
