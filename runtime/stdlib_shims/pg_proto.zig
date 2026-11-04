//! PostgreSQL ön uç/arka uç protokolü 3.0 için SAF (G/Ç'siz) yardımcılar (spec §3.358): bağlantı dizesi ayrıştırma, ileti kurma, SCRAM-SHA-256 ve MD5 kimlik doğrulaması.
//! `pg_wasm.zig` bunları host TCP üzerinde kullanır; burada ağ yoktur, bu yüzden yerelde birim testlenir (RFC 7677 SCRAM test vektörü dahil).

const std = @import("std");
const Allocator = std.mem.Allocator;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Md5 = std.crypto.hash.Md5;

pub const ConnInfo = struct {
    host: []const u8 = "localhost",
    port: u16 = 5432,
    user: []const u8 = "",
    password: []const u8 = "",
    dbname: []const u8 = "",
    /// `require` / `verify-ca` / `verify-full`: SSLRequest + TLS (host doğrular). Diğerleri düz metin (libpq\'nun `prefer` varsayılanından bilinçli sapma: bkz. spec).
    require_tls: bool = false,
};

fn percentDecode(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            const v = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch {
                try out.append(a, s[i]);
                continue;
            };
            try out.append(a, v);
            i += 2;
        } else try out.append(a, s[i]);
    }
    return out.items;
}

fn applyKey(info: *ConnInfo, key: []const u8, val: []const u8) void {
    if (std.mem.eql(u8, key, "host") or std.mem.eql(u8, key, "hostaddr")) info.host = val else if (std.mem.eql(u8, key, "port")) info.port = std.fmt.parseInt(u16, val, 10) catch 5432 else if (std.mem.eql(u8, key, "user")) info.user = val else if (std.mem.eql(u8, key, "password")) info.password = val else if (std.mem.eql(u8, key, "dbname")) info.dbname = val else if (std.mem.eql(u8, key, "sslmode")) info.require_tls = std.mem.eql(u8, val, "require") or std.mem.eql(u8, val, "verify-ca") or std.mem.eql(u8, val, "verify-full");
}

/// `host=... port=... user=... password=... dbname=...` (değerler `'...'` ile tırnaklanabilir, `\\` kaçışı) ya da `postgres://user:pass@host:port/db?sslmode=require`.
pub fn parseConnInfo(a: Allocator, text: []const u8) !ConnInfo {
    var info: ConnInfo = .{};
    const t = std.mem.trim(u8, text, " \t\r\n");
    const uri_prefix: ?usize = if (std.mem.startsWith(u8, t, "postgresql://")) 13 else if (std.mem.startsWith(u8, t, "postgres://")) 11 else null;
    if (uri_prefix) |pre| {
        var rest = t[pre..];
        var query: []const u8 = "";
        if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
            query = rest[q + 1 ..];
            rest = rest[0..q];
        }
        var path: []const u8 = "";
        if (std.mem.indexOfScalar(u8, rest, '/')) |sl| {
            path = rest[sl + 1 ..];
            rest = rest[0..sl];
        }
        if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| {
            const cred = rest[0..at];
            rest = rest[at + 1 ..];
            if (std.mem.indexOfScalar(u8, cred, ':')) |c| {
                info.user = try percentDecode(a, cred[0..c]);
                info.password = try percentDecode(a, cred[c + 1 ..]);
            } else info.user = try percentDecode(a, cred);
        }
        if (rest.len > 0) {
            if (std.mem.lastIndexOfScalar(u8, rest, ':')) |c| {
                info.host = rest[0..c];
                info.port = std.fmt.parseInt(u16, rest[c + 1 ..], 10) catch 5432;
            } else info.host = rest;
        }
        if (path.len > 0) info.dbname = try percentDecode(a, path);
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
            applyKey(&info, kv[0..eq], try percentDecode(a, kv[eq + 1 ..]));
        }
    } else {
        var i: usize = 0;
        while (i < t.len) {
            while (i < t.len and std.ascii.isWhitespace(t[i])) i += 1;
            if (i >= t.len) break;
            const ks = i;
            while (i < t.len and t[i] != '=' and !std.ascii.isWhitespace(t[i])) i += 1;
            const key = t[ks..i];
            while (i < t.len and (t[i] == '=' or std.ascii.isWhitespace(t[i]))) i += 1;
            var val: std.ArrayListUnmanaged(u8) = .empty;
            if (i < t.len and t[i] == '\'') {
                i += 1;
                while (i < t.len and t[i] != '\'') : (i += 1) {
                    if (t[i] == '\\' and i + 1 < t.len) i += 1;
                    try val.append(a, t[i]);
                }
                i += 1;
            } else {
                while (i < t.len and !std.ascii.isWhitespace(t[i])) : (i += 1) {
                    if (t[i] == '\\' and i + 1 < t.len) i += 1;
                    try val.append(a, t[i]);
                }
            }
            applyKey(&info, key, val.items);
        }
    }
    if (info.dbname.len == 0) info.dbname = info.user;
    return info;
}

// ---- İleti kurma -----------------------------------------------------------------------------------------------------------------------------------

pub const Buf = std.ArrayListUnmanaged(u8);

pub fn putI32(a: Allocator, b: *Buf, v: i32) !void {
    try b.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(i32, v)));
}

pub fn putI16(a: Allocator, b: *Buf, v: i16) !void {
    try b.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(i16, v)));
}

pub fn putCStr(a: Allocator, b: *Buf, s: []const u8) !void {
    try b.appendSlice(a, s);
    try b.append(a, 0);
}

/// Tip baytlı ileti: `tag`, `i32 uzunluk` (kendisi dahil), gövde.
pub fn finishTagged(a: Allocator, out: *Buf, tag: u8, body: []const u8) !void {
    try out.append(a, tag);
    try putI32(a, out, @intCast(body.len + 4));
    try out.appendSlice(a, body);
}

pub fn startupMessage(a: Allocator, info: ConnInfo) ![]u8 {
    var body: Buf = .empty;
    try putI32(a, &body, 196608); // 3.0
    try putCStr(a, &body, "user");
    try putCStr(a, &body, info.user);
    try putCStr(a, &body, "database");
    try putCStr(a, &body, info.dbname);
    try body.append(a, 0);
    var out: Buf = .empty;
    try putI32(a, &out, @intCast(body.items.len + 4));
    try out.appendSlice(a, body.items);
    return out.items;
}

pub const ssl_request = [_]u8{ 0, 0, 0, 8, 4, 210, 22, 47 }; // 80877103

// ---- Kimlik doğrulama --------------------------------------------------------------------------------------------------------------------------------

/// `"md5" ++ hex(md5(hex(md5(password ++ user)) ++ salt))`
pub fn md5Password(a: Allocator, user: []const u8, password: []const u8, salt: [4]u8) ![]u8 {
    var h1: [16]u8 = undefined;
    var m = Md5.init(.{});
    m.update(password);
    m.update(user);
    m.final(&h1);
    const hex1 = std.fmt.bytesToHex(h1, .lower);
    var h2: [16]u8 = undefined;
    var m2 = Md5.init(.{});
    m2.update(&hex1);
    m2.update(&salt);
    m2.final(&h2);
    const hex2 = std.fmt.bytesToHex(h2, .lower);
    return std.fmt.allocPrint(a, "md5{s}", .{hex2});
}

pub const Scram = struct {
    client_nonce: []const u8,
    client_first_bare: []u8,
    /// SASLContinue sonrası dolar.
    server_signature: [32]u8 = undefined,

    pub fn init(a: Allocator, nonce: []const u8) !Scram {
        return .{ .client_nonce = nonce, .client_first_bare = try std.fmt.allocPrint(a, "n=,r={s}", .{nonce}) };
    }

    pub fn clientFirst(self: *const Scram, a: Allocator) ![]u8 {
        return std.fmt.allocPrint(a, "n,,{s}", .{self.client_first_bare});
    }

    /// Sunucunun ilk iletisinden (`r=<nonce>,s=<salt b64>,i=<iter>`) istemci son iletisini üretir ve beklenen sunucu imzasını saklar.
    pub fn clientFinal(self: *Scram, a: Allocator, password: []const u8, server_first: []const u8) ![]u8 {
        var nonce: []const u8 = "";
        var salt_b64: []const u8 = "";
        var iter: u32 = 0;
        var it = std.mem.splitScalar(u8, server_first, ',');
        while (it.next()) |part| {
            if (part.len < 2 or part[1] != '=') continue;
            switch (part[0]) {
                'r' => nonce = part[2..],
                's' => salt_b64 = part[2..],
                'i' => iter = std.fmt.parseInt(u32, part[2..], 10) catch 0,
                else => {},
            }
        }
        if (nonce.len == 0 or salt_b64.len == 0 or iter == 0) return error.BadServerFirst;
        if (!std.mem.startsWith(u8, nonce, self.client_nonce)) return error.NonceMismatch;
        const salt = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(salt_b64));
        try std.base64.standard.Decoder.decode(salt, salt_b64);

        var salted: [32]u8 = undefined;
        try std.crypto.pwhash.pbkdf2(&salted, password, salt, iter, HmacSha256);
        var client_key: [32]u8 = undefined;
        HmacSha256.create(&client_key, "Client Key", &salted);
        var stored: [32]u8 = undefined;
        Sha256.hash(&client_key, &stored, .{});

        const final_wo_proof = try std.fmt.allocPrint(a, "c=biws,r={s}", .{nonce});
        const auth_message = try std.fmt.allocPrint(a, "{s},{s},{s}", .{ self.client_first_bare, server_first, final_wo_proof });
        var client_sig: [32]u8 = undefined;
        HmacSha256.create(&client_sig, auth_message, &stored);
        var proof: [32]u8 = undefined;
        for (&proof, client_key, client_sig) |*p, ck, cs| p.* = ck ^ cs;

        var server_key: [32]u8 = undefined;
        HmacSha256.create(&server_key, "Server Key", &salted);
        HmacSha256.create(&self.server_signature, auth_message, &server_key);

        var proof_b64: [44]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&proof_b64, &proof);
        return std.fmt.allocPrint(a, "{s},p={s}", .{ final_wo_proof, proof_b64 });
    }

    /// SASLFinal (`v=<b64>`) içindeki sunucu imzasını doğrular.
    pub fn verifyServerFinal(self: *const Scram, server_final: []const u8) bool {
        if (!std.mem.startsWith(u8, server_final, "v=")) return false;
        var expect: [44]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&expect, &self.server_signature);
        return std.mem.eql(u8, server_final[2..], &expect);
    }
};

/// `INSERT 0 5` / `UPDATE 3` / `SELECT 2` gibi CommandComplete etiketinden etkilenen satır sayısı (son sayı); yoksa 0.
pub fn changesFromTag(tag: []const u8) i64 {
    const sp = std.mem.lastIndexOfScalar(u8, tag, ' ') orelse return 0;
    return std.fmt.parseInt(i64, tag[sp + 1 ..], 10) catch 0;
}

test "parseConnInfo: anahtar=değer, tırnak, URI, varsayılanlar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ci1 = try parseConnInfo(a, "host=db.example port=6543 user=alice password='p w\\'x' dbname=app sslmode=require");
    try std.testing.expectEqualStrings("db.example", ci1.host);
    try std.testing.expectEqual(@as(u16, 6543), ci1.port);
    try std.testing.expectEqualStrings("alice", ci1.user);
    try std.testing.expectEqualStrings("p w'x", ci1.password);
    try std.testing.expectEqualStrings("app", ci1.dbname);
    try std.testing.expect(ci1.require_tls);
    const ci2 = try parseConnInfo(a, "postgres://bob:s%40cret@10.0.0.5:5433/shop?sslmode=disable");
    try std.testing.expectEqualStrings("bob", ci2.user);
    try std.testing.expectEqualStrings("s@cret", ci2.password);
    try std.testing.expectEqualStrings("10.0.0.5", ci2.host);
    try std.testing.expectEqual(@as(u16, 5433), ci2.port);
    try std.testing.expectEqualStrings("shop", ci2.dbname);
    try std.testing.expect(!ci2.require_tls);
    const ci3 = try parseConnInfo(a, "user=carol");
    try std.testing.expectEqualStrings("localhost", ci3.host);
    try std.testing.expectEqualStrings("carol", ci3.dbname); // dbname varsayılanı kullanıcı adı
}

test "SCRAM-SHA-256: RFC 7677 test vektörü" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Scram.init(a, "rOprNGfwEbeRWgbNEkqO");
    try std.testing.expectEqualStrings("n,,n=,r=rOprNGfwEbeRWgbNEkqO", try s.clientFirst(a));
    // RFC 7677 örneği kullanıcı adını "user" olarak verir; PostgreSQL `n=` boş bırakır, bu yüzden vektörü bare-message'ı RFC'ninki ile yeniden kurarak sınarız.
    s.client_first_bare = try a.dupe(u8, "n=user,r=rOprNGfwEbeRWgbNEkqO");
    const server_first = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";
    const final = try s.clientFinal(a, "pencil", server_first);
    try std.testing.expectEqualStrings("c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=", final);
    try std.testing.expect(s.verifyServerFinal("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="));
    try std.testing.expect(!s.verifyServerFinal("v=AAAA"));
}

test "md5Password: PostgreSQL belgelerindeki biçim" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try md5Password(arena.allocator(), "postgres", "secret", .{ 1, 2, 3, 4 });
    try std.testing.expect(out.len == 35 and std.mem.startsWith(u8, out, "md5"));
}

test "changesFromTag" {
    try std.testing.expectEqual(@as(i64, 5), changesFromTag("INSERT 0 5"));
    try std.testing.expectEqual(@as(i64, 3), changesFromTag("UPDATE 3"));
    try std.testing.expectEqual(@as(i64, 0), changesFromTag("CREATE TABLE"));
}

test "startupMessage ve ssl_request biçimi" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = try startupMessage(arena.allocator(), .{ .user = "u", .dbname = "d" });
    try std.testing.expectEqual(@as(u32, @intCast(m.len)), std.mem.readInt(u32, m[0..4], .big));
    try std.testing.expectEqual(@as(u32, 196608), std.mem.readInt(u32, m[4..8], .big));
    try std.testing.expect(std.mem.indexOf(u8, m, "user\x00u\x00database\x00d\x00") != null);
    try std.testing.expectEqual(@as(u32, 80877103), std.mem.readInt(u32, ssl_request[4..8], .big));
}
