//! MySQL/MariaDB istemci/sunucu protokolü için SAF (G/Ç'siz) yardımcılar (spec §3.361): el sıkışma (Handshake v10) ayrıştırma, `mysql_native_password` ve `caching_sha2_password`
//! kimlik doğrulama hesapları, sunucunun RSA genel anahtarıyla (OAEP/SHA-1) parola şifreleme (TLS'siz tam kimlik doğrulama için), OK/ERR/sütun/satır paketi ayrıştırma ve
//! `mysql_real_escape_string` eşdeğeri. `mysql_wasm.zig` bunları host TCP üzerinde kullanır; burada ağ yoktur, bu yüzden yerelde birim testlenir.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha1 = std.crypto.hash.Sha1;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Buf = std.ArrayListUnmanaged(u8);

// ---- İstemci yetenekleri / durum bayrakları ------------------------------------------------------------------------------------------------------

pub const CLIENT_LONG_PASSWORD: u32 = 0x1;
pub const CLIENT_LONG_FLAG: u32 = 0x4;
pub const CLIENT_CONNECT_WITH_DB: u32 = 0x8;
pub const CLIENT_PROTOCOL_41: u32 = 0x200;
pub const CLIENT_TRANSACTIONS: u32 = 0x2000;
pub const CLIENT_SECURE_CONNECTION: u32 = 0x8000;
pub const CLIENT_MULTI_RESULTS: u32 = 0x20000;
pub const CLIENT_PLUGIN_AUTH: u32 = 0x80000;
pub const CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA: u32 = 0x200000;

pub const SERVER_MORE_RESULTS_EXISTS: u16 = 0x0008;
pub const SERVER_STATUS_NO_BACKSLASH_ESCAPES: u16 = 0x0200;

pub const base_caps: u32 = CLIENT_LONG_PASSWORD | CLIENT_LONG_FLAG | CLIENT_PROTOCOL_41 | CLIENT_TRANSACTIONS | CLIENT_SECURE_CONNECTION | CLIENT_MULTI_RESULTS | CLIENT_PLUGIN_AUTH | CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA;

pub const COM_QUIT: u8 = 0x01;
pub const COM_QUERY: u8 = 0x03;

pub const plugin_native = "mysql_native_password";
pub const plugin_sha2 = "caching_sha2_password";

// ---- Okuyucu -------------------------------------------------------------------------------------------------------------------------------------

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn left(self: Reader) usize {
        return self.buf.len - self.pos;
    }

    pub fn u8_(self: *Reader) ?u8 {
        if (self.pos >= self.buf.len) return null;
        const v = self.buf[self.pos];
        self.pos += 1;
        return v;
    }

    pub fn u16_(self: *Reader) ?u16 {
        if (self.left() < 2) return null;
        const v = std.mem.readInt(u16, self.buf[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }

    pub fn u32_(self: *Reader) ?u32 {
        if (self.left() < 4) return null;
        const v = std.mem.readInt(u32, self.buf[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }

    pub fn bytes(self: *Reader, n: usize) ?[]const u8 {
        if (self.left() < n) return null;
        const s = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    /// NUL ile biten dize (NUL tüketilir); NUL yoksa kalanın tamamı.
    pub fn cstr(self: *Reader) []const u8 {
        const rest = self.buf[self.pos..];
        const end = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
        self.pos += @min(rest.len, end + 1);
        return rest[0..end];
    }

    /// Uzunluk kodlu tamsayı. `0xFB` (NULL) için `null_marker` doğru döner.
    pub fn lenenc(self: *Reader, null_marker: *bool) ?u64 {
        null_marker.* = false;
        const first = self.u8_() orelse return null;
        switch (first) {
            0xFB => {
                null_marker.* = true;
                return 0;
            },
            0xFC => {
                const v = self.u16_() orelse return null;
                return v;
            },
            0xFD => {
                const b = self.bytes(3) orelse return null;
                return @as(u64, b[0]) | (@as(u64, b[1]) << 8) | (@as(u64, b[2]) << 16);
            },
            0xFE => {
                const b = self.bytes(8) orelse return null;
                return std.mem.readInt(u64, b[0..8], .little);
            },
            else => return first,
        }
    }

    /// Uzunluk kodlu dize; SQL NULL için `.null`.
    pub fn lenencStr(self: *Reader) error{Truncated}!?[]const u8 {
        var is_null = false;
        const n = self.lenenc(&is_null) orelse return error.Truncated;
        if (is_null) return null;
        return self.bytes(@intCast(n)) orelse error.Truncated;
    }
};

pub fn putLenenc(a: Allocator, b: *Buf, v: u64) !void {
    if (v < 0xFB) {
        try b.append(a, @intCast(v));
    } else if (v <= 0xFFFF) {
        try b.append(a, 0xFC);
        try b.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, @intCast(v))));
    } else if (v <= 0xFFFFFF) {
        try b.append(a, 0xFD);
        try b.appendSlice(a, &.{ @intCast(v & 0xFF), @intCast((v >> 8) & 0xFF), @intCast((v >> 16) & 0xFF) });
    } else {
        try b.append(a, 0xFE);
        try b.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u64, v)));
    }
}

pub fn putU32(a: Allocator, b: *Buf, v: u32) !void {
    try b.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
}

pub fn putCStr(a: Allocator, b: *Buf, s: []const u8) !void {
    try b.appendSlice(a, s);
    try b.append(a, 0);
}

// ---- El sıkışma ----------------------------------------------------------------------------------------------------------------------------------

pub const Handshake = struct {
    server_version: []const u8,
    /// Sunucunun tuz verisi (20 bayt); `a` ile tahsislidir.
    scramble: []u8,
    plugin: []const u8,
    caps: u32,
    status: u16,
};

pub const HandshakeError = error{ UnsupportedProtocol, Malformed, OutOfMemory };

/// Sunucunun ilk paketini ayrıştırır (Protocol::HandshakeV10). Dönen dizgeler `payload`a işaret eder, yalnızca `scramble` tahsislidir.
pub fn parseHandshake(a: Allocator, payload: []const u8) HandshakeError!Handshake {
    var r: Reader = .{ .buf = payload };
    const proto = r.u8_() orelse return error.Malformed;
    if (proto != 10) return error.UnsupportedProtocol;
    const version = r.cstr();
    _ = r.u32_() orelse return error.Malformed; // bağlantı kimliği
    const part1 = r.bytes(8) orelse return error.Malformed;
    _ = r.u8_() orelse return error.Malformed; // dolgu
    const caps_lo = r.u16_() orelse return error.Malformed;
    var caps: u32 = caps_lo;
    var status: u16 = 0;
    var auth_len: usize = 0;
    var part2: []const u8 = "";
    var plugin: []const u8 = plugin_native;
    if (r.left() > 0) {
        _ = r.u8_(); // karakter kümesi
        status = r.u16_() orelse return error.Malformed;
        const caps_hi = r.u16_() orelse return error.Malformed;
        caps |= @as(u32, caps_hi) << 16;
        auth_len = r.u8_() orelse return error.Malformed;
        _ = r.bytes(10) orelse return error.Malformed;
        if (caps & CLIENT_SECURE_CONNECTION != 0) {
            const n = @max(13, if (auth_len > 8) auth_len - 8 else 0);
            part2 = r.bytes(@min(n, r.left())) orelse return error.Malformed;
        }
        if (caps & CLIENT_PLUGIN_AUTH != 0 and r.left() > 0) plugin = r.cstr();
    }
    var scramble = try a.alloc(u8, 20);
    errdefer a.free(scramble);
    @memset(scramble, 0);
    @memcpy(scramble[0..8], part1);
    const p2 = if (part2.len > 0 and part2[part2.len - 1] == 0) part2[0 .. part2.len - 1] else part2;
    const take: usize = @min(p2.len, 12);
    @memcpy(scramble[8 .. 8 + take], p2[0..take]);
    return .{ .server_version = version, .scramble = scramble, .plugin = plugin, .caps = caps, .status = status };
}

// ---- Kimlik doğrulama hesapları -----------------------------------------------------------------------------------------------------------------

/// `mysql_native_password`: SHA1(parola) XOR SHA1(tuz + SHA1(SHA1(parola))).
pub fn nativeScramble(password: []const u8, scramble: []const u8) [20]u8 {
    var h1: [20]u8 = undefined;
    Sha1.hash(password, &h1, .{});
    var h2: [20]u8 = undefined;
    Sha1.hash(&h1, &h2, .{});
    var s = Sha1.init(.{});
    s.update(scramble[0..@min(20, scramble.len)]);
    s.update(&h2);
    var h3: [20]u8 = undefined;
    s.final(&h3);
    var out: [20]u8 = undefined;
    for (&out, h1, h3) |*o, x, y| o.* = x ^ y;
    return out;
}

/// `caching_sha2_password` (hızlı yol): SHA256(parola) XOR SHA256(SHA256(SHA256(parola)) + tuz).
pub fn sha2Scramble(password: []const u8, scramble: []const u8) [32]u8 {
    var h1: [32]u8 = undefined;
    Sha256.hash(password, &h1, .{});
    var h2: [32]u8 = undefined;
    Sha256.hash(&h1, &h2, .{});
    var s = Sha256.init(.{});
    s.update(&h2);
    s.update(scramble[0..@min(20, scramble.len)]);
    var h3: [32]u8 = undefined;
    s.final(&h3);
    var out: [32]u8 = undefined;
    for (&out, h1, h3) |*o, x, y| o.* = x ^ y;
    return out;
}

/// Eklentiye göre ilk kimlik doğrulama yanıtı. Parola boşsa yanıt boştur. Bilinmeyen eklenti için `null`.
pub fn authResponse(plugin: []const u8, password: []const u8, scramble: []const u8, out: *[32]u8) ?[]const u8 {
    if (std.mem.eql(u8, plugin, plugin_native)) {
        if (password.len == 0) return out[0..0];
        const r = nativeScramble(password, scramble);
        @memcpy(out[0..20], &r);
        return out[0..20];
    }
    if (std.mem.eql(u8, plugin, plugin_sha2)) {
        if (password.len == 0) return out[0..0];
        out.* = sha2Scramble(password, scramble);
        return out[0..32];
    }
    return null;
}

/// HandshakeResponse41 paketinin gövdesi.
pub fn handshakeResponse(a: Allocator, user: []const u8, auth: []const u8, db: []const u8, plugin: []const u8) !Buf {
    var caps = base_caps;
    if (db.len > 0) caps |= CLIENT_CONNECT_WITH_DB;
    var b: Buf = .empty;
    errdefer b.deinit(a);
    try putU32(a, &b, caps);
    try putU32(a, &b, 0x01000000); // en büyük paket
    try b.append(a, 45); // utf8mb4_general_ci (MySQL ve MariaDB'de ortak)
    try b.appendNTimes(a, 0, 23);
    try putCStr(a, &b, user);
    try putLenenc(a, &b, auth.len);
    try b.appendSlice(a, auth);
    if (db.len > 0) try putCStr(a, &b, db);
    try putCStr(a, &b, plugin);
    return b;
}

// ---- RSA (TLS'siz tam kimlik doğrulama için parola şifreleme) ------------------------------------------------------------------------------------

const Mod4096 = std.crypto.ff.Modulus(4096);

const Tlv = struct { tag: u8, value: []const u8, end: usize };

fn readTlv(buf: []const u8, pos: usize) ?Tlv {
    if (pos + 2 > buf.len) return null;
    const tag = buf[pos];
    var len: usize = buf[pos + 1];
    var p = pos + 2;
    if (len & 0x80 != 0) {
        const nb = len & 0x7F;
        if (nb == 0 or nb > 4 or p + nb > buf.len) return null;
        len = 0;
        for (buf[p .. p + nb]) |x| len = (len << 8) | x;
        p += nb;
    }
    if (p + len > buf.len) return null;
    return .{ .tag = tag, .value = buf[p .. p + len], .end = p + len };
}

pub const RsaKey = struct { n: []const u8, e: []const u8 };

/// SubjectPublicKeyInfo (DER) -> RSA modülü ve genel üs (baştaki sıfır baytlar atılır; dilimler `der`e işaret eder).
pub fn parseSpki(der: []const u8) ?RsaKey {
    const outer = readTlv(der, 0) orelse return null;
    if (outer.tag != 0x30) return null;
    const alg = readTlv(outer.value, 0) orelse return null;
    const bits = readTlv(outer.value, alg.end) orelse return null;
    if (bits.tag != 0x03 or bits.value.len < 2) return null;
    const rsa_seq = readTlv(bits.value[1..], 0) orelse return null;
    if (rsa_seq.tag != 0x30) return null;
    const n = readTlv(rsa_seq.value, 0) orelse return null;
    const e = readTlv(rsa_seq.value, n.end) orelse return null;
    if (n.tag != 0x02 or e.tag != 0x02) return null;
    var nv = n.value;
    while (nv.len > 1 and nv[0] == 0) nv = nv[1..];
    var ev = e.value;
    while (ev.len > 1 and ev[0] == 0) ev = ev[1..];
    return .{ .n = nv, .e = ev };
}

/// PEM ("-----BEGIN PUBLIC KEY-----") -> DER baytları.
pub fn pemToDer(a: Allocator, pem: []const u8) ![]u8 {
    var b64: Buf = .empty;
    defer b64.deinit(a);
    var it = std.mem.splitScalar(u8, pem, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '-') continue;
        try b64.appendSlice(a, t);
    }
    const dec = std.base64.standard.Decoder;
    const size = dec.calcSizeForSlice(b64.items) catch return error.InvalidPem;
    const out = try a.alloc(u8, size);
    errdefer a.free(out);
    dec.decode(out, b64.items) catch return error.InvalidPem;
    return out;
}

fn mgf1(out: []u8, seed: []const u8) void {
    var counter: u32 = 0;
    var off: usize = 0;
    while (off < out.len) : (counter += 1) {
        var h = Sha1.init(.{});
        h.update(seed);
        var c: [4]u8 = undefined;
        std.mem.writeInt(u32, &c, counter, .big);
        h.update(&c);
        var d: [20]u8 = undefined;
        h.final(&d);
        const n = @min(20, out.len - off);
        @memcpy(out[off .. off + n], d[0..n]);
        off += n;
    }
}

/// RSAES-OAEP (SHA-1, MGF1-SHA-1, boş etiket) ile `msg`i şifreler. `seed`: 20 rastgele bayt.
pub fn oaepEncrypt(a: Allocator, key: RsaKey, msg: []const u8, seed: [20]u8) ![]u8 {
    const m = Mod4096.fromBytes(key.n, .big) catch return error.InvalidKey;
    const k = key.n.len;
    if (k < 128 or msg.len + 42 > k) return error.MessageTooLong;
    const em = try a.alloc(u8, k);
    defer a.free(em);
    @memset(em, 0);
    const masked_seed = em[1..21];
    const db = em[21..];
    Sha1.hash("", db[0..20], .{});
    db[db.len - msg.len - 1] = 1;
    @memcpy(db[db.len - msg.len ..], msg);
    const db_mask = try a.alloc(u8, db.len);
    defer a.free(db_mask);
    mgf1(db_mask, &seed);
    for (db, db_mask) |*x, y| x.* ^= y;
    var seed_mask: [20]u8 = undefined;
    mgf1(&seed_mask, db);
    for (masked_seed, seed, seed_mask) |*o, s, mk| o.* = s ^ mk;

    const x = Mod4096.Fe.fromBytes(m, em, .big) catch return error.InvalidKey;
    const y = m.powWithEncodedPublicExponent(x, key.e, .big) catch return error.InvalidKey;
    const out = try a.alloc(u8, k);
    errdefer a.free(out);
    y.toBytes(out, .big) catch return error.InvalidKey;
    return out;
}

/// Tam kimlik doğrulamada gönderilecek şifreli parola: (parola + NUL) XOR tuz, sunucunun PEM anahtarıyla OAEP.
pub fn encryptPassword(a: Allocator, pem: []const u8, password: []const u8, scramble: []const u8, seed: [20]u8) ![]u8 {
    const der = try pemToDer(a, pem);
    defer a.free(der);
    const key = parseSpki(der) orelse return error.InvalidKey;
    const plain = try a.alloc(u8, password.len + 1);
    defer a.free(plain);
    @memcpy(plain[0..password.len], password);
    plain[password.len] = 0;
    const sc = scramble[0..@min(20, scramble.len)];
    for (plain, 0..) |*x, i| x.* ^= sc[i % sc.len];
    return oaepEncrypt(a, key, plain, seed);
}

// ---- Yanıt paketleri -----------------------------------------------------------------------------------------------------------------------------

pub const Ok = struct { affected: u64, insert_id: u64, status: u16 };

/// OK paketi (`0x00` ile başlar).
pub fn parseOk(payload: []const u8) ?Ok {
    var r: Reader = .{ .buf = payload };
    _ = r.u8_() orelse return null;
    var nm = false;
    const affected = r.lenenc(&nm) orelse return null;
    const id = r.lenenc(&nm) orelse return null;
    const status = r.u16_() orelse 0;
    return .{ .affected = affected, .insert_id = id, .status = status };
}

/// ERR paketi (`0xFF`): sunucu iletisi (libmysqlclient'ın `mysql_error` dizesi).
pub fn errMessage(payload: []const u8) []const u8 {
    var r: Reader = .{ .buf = payload };
    _ = r.u8_();
    _ = r.u16_();
    if (r.left() > 0 and r.buf[r.pos] == '#') _ = r.bytes(@min(6, r.left()));
    return r.buf[r.pos..];
}

/// EOF paketi: `0xFE` ile başlar ve 9 bayttan kısadır.
pub fn isEof(payload: []const u8) bool {
    return payload.len > 0 and payload.len < 9 and payload[0] == 0xFE;
}

/// EOF paketinden sunucu durumu (`0xFE`, uyarılar u16, durum u16).
pub fn eofStatus(payload: []const u8) u16 {
    if (payload.len >= 5) return std.mem.readInt(u16, payload[3..5], .little);
    return 0;
}

/// ColumnDefinition41 paketinden sütun adı.
pub fn columnName(payload: []const u8) ?[]const u8 {
    var r: Reader = .{ .buf = payload };
    inline for (0..4) |_| _ = (r.lenencStr() catch return null); // catalog, schema, table, org_table
    return (r.lenencStr() catch return null) orelse null; // name
}

// ---- Kaçışlama -----------------------------------------------------------------------------------------------------------------------------------

/// `mysql_real_escape_string` eşdeğeri. `NO_BACKSLASH_ESCAPES` kipinde yalnızca `'` ikilenir.
pub fn escapeString(a: Allocator, src: []const u8, no_backslash: bool) ![]u8 {
    var out: Buf = .empty;
    errdefer out.deinit(a);
    for (src) |c| {
        if (no_backslash) {
            if (c == '\'') try out.append(a, '\'');
            try out.append(a, c);
            continue;
        }
        const esc: ?u8 = switch (c) {
            0 => '0',
            '\n' => 'n',
            '\r' => 'r',
            '\\' => '\\',
            '\'' => '\'',
            '"' => '"',
            0x1a => 'Z',
            else => null,
        };
        if (esc) |e| {
            try out.append(a, '\\');
            try out.append(a, e);
        } else try out.append(a, c);
    }
    return out.toOwnedSlice(a);
}

// ---- Testler -------------------------------------------------------------------------------------------------------------------------------------

test "lenenc oku/yaz" {
    const a = std.testing.allocator;
    const cases = [_]u64{ 0, 250, 251, 65535, 65536, 0xFFFFFF, 0x1000000, 1 << 40 };
    for (cases) |v| {
        var b: Buf = .empty;
        defer b.deinit(a);
        try putLenenc(a, &b, v);
        var r: Reader = .{ .buf = b.items };
        var nm = false;
        try std.testing.expectEqual(v, r.lenenc(&nm).?);
        try std.testing.expectEqual(@as(usize, 0), r.left());
    }
    var r: Reader = .{ .buf = &.{0xFB} };
    var nm = false;
    _ = r.lenenc(&nm);
    try std.testing.expect(nm);
}

test "native ve sha2 tuz hesabi (bagimsiz Python/hashlib vektorleri)" {
    const scramble = "abcdefghijklmnopqrst";
    const n = nativeScramble("secret", scramble);
    try std.testing.expectEqualStrings("8817c50fa779daef010ee7577825b0847df9842e", &std.fmt.bytesToHex(n, .lower));
    const s = sha2Scramble("secret", scramble);
    try std.testing.expectEqualStrings("c76e2898612a4cf042c77fa8c4702c4c64c0c2c557c53c4d75595aaa6abae809", &std.fmt.bytesToHex(s, .lower));
}

test "el sikisma ayristirma" {
    const a = std.testing.allocator;
    var b: Buf = .empty;
    defer b.deinit(a);
    try b.append(a, 10);
    try putCStr(a, &b, "8.4.0");
    try putU32(a, &b, 7);
    try b.appendSlice(a, "abcdefgh");
    try b.append(a, 0);
    const caps: u32 = CLIENT_PROTOCOL_41 | CLIENT_SECURE_CONNECTION | CLIENT_PLUGIN_AUTH;
    try b.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, @intCast(caps & 0xFFFF))));
    try b.append(a, 255);
    try b.appendSlice(a, &.{ 2, 0 });
    try b.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, @intCast(caps >> 16))));
    try b.append(a, 21);
    try b.appendNTimes(a, 0, 10);
    try b.appendSlice(a, "ijklmnopqrst");
    try b.append(a, 0);
    try putCStr(a, &b, "caching_sha2_password");
    const h = try parseHandshake(a, b.items);
    defer a.free(h.scramble);
    try std.testing.expectEqualStrings("8.4.0", h.server_version);
    try std.testing.expectEqualStrings("abcdefghijklmnopqrst", h.scramble);
    try std.testing.expectEqualStrings("caching_sha2_password", h.plugin);
    try std.testing.expect(h.caps & CLIENT_PLUGIN_AUTH != 0);
}

test "kacislama" {
    const a = std.testing.allocator;
    const e = try escapeString(a, "a'b\"c\\d\ne\r\x00\x1a", false);
    defer a.free(e);
    try std.testing.expectEqualStrings("a\\'b\\\"c\\\\d\\ne\\r\\0\\Z", e);
    const e2 = try escapeString(a, "it's \\ fine", true);
    defer a.free(e2);
    try std.testing.expectEqualStrings("it''s \\ fine", e2);
}

test "OK/ERR/EOF paketleri" {
    const ok = parseOk(&.{ 0x00, 0x03, 0x2a, 0x02, 0x00, 0x00, 0x00 }).?;
    try std.testing.expectEqual(@as(u64, 3), ok.affected);
    try std.testing.expectEqual(@as(u64, 42), ok.insert_id);
    try std.testing.expectEqual(@as(u16, 2), ok.status);
    try std.testing.expectEqualStrings("Access denied", errMessage("\xff\x15\x04#28000Access denied"));
    try std.testing.expect(isEof(&.{ 0xFE, 0, 0, 2, 0 }));
    try std.testing.expect(!isEof(&.{ 0xFE, 1, 2, 3, 4, 5, 6, 7, 8, 9 }));
}

test "OAEP: PEM ayristirma, MGF1 ve sifreleme (openssl ile dogrulandi)" {
    const a = std.testing.allocator;
    const pem =
        "-----BEGIN PUBLIC KEY-----\n" ++
        "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAnT+eDKmzyVb2I6rrrF5m\n" ++
        "oAB+0WxlF8O+2SsooiKYt3MDZ3fv671yPB+qflWpnNCvdF1lU/SQHEUiPsrFmQIc\n" ++
        "IZH5X7vr25/5ZIsIQfNcAcag9c32UbO/JfibdUo7Is6x0P4xsY3TO4IdAdGDTDMK\n" ++
        "D9Wz30tGAkKweWDR4ZzB5GI4rufX81lt91qdstdFDcQZ934quHcoQlyDYH1KJ8xJ\n" ++
        "s5gfm5kVsYJYfEFpOUUhZTO6ZZy7cB1dG8S8yLgifWNoRhANb2FfKssonuCC8sG5\n" ++
        "Umz4EAJ+3kJRRMFUefmkg7CS0bKlZRgDZCMDo5azx7Mfa5GT7ZbcBKny0CAw2Jbx\n" ++
        "tQIDAQAB\n" ++
        "-----END PUBLIC KEY-----\n";
    const der = try pemToDer(a, pem);
    defer a.free(der);
    const k = parseSpki(der).?;
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x00, 0x01 }, k.e);
    try std.testing.expectEqual(@as(usize, 256), k.n.len);

    var out: [50]u8 = undefined;
    mgf1(&out, "seed");
    var h = Sha1.init(.{});
    h.update("seed");
    h.update(&.{ 0, 0, 0, 0 });
    var d: [20]u8 = undefined;
    h.final(&d);
    try std.testing.expectEqualSlices(u8, &d, out[0..20]);

    const seed: [20]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 };
    const ct = try encryptPassword(a, pem, "secret", "abcdefghijklmnopqrst", seed);
    defer a.free(ct);
    try std.testing.expectEqual(@as(usize, 256), ct.len);
    // Sabit tohumla OAEP belirlenimlidir; bu sifreli metin `openssl pkeyutl -decrypt -pkeyopt rsa_padding_mode:oaep` ile cozulup
    // "secret\0" XOR tuz olarak dogrulandi.
    try std.testing.expectEqualStrings("961440d194922233c0b0f8b25361c2b40cf800eada4366c37734aa6a0361f0d55a267a8ec1996e47f15b3535ab3f99f5e28fc33b8b77695b5243abd562a2f03f2561fbb798f18b4f3c59ef7e7fbdaebea651e7f19f792478d3836d5f063213e0334148387a7b8897c14ffd27d5253300bc947672a6bd980b6f8fc91a062fb37fdf32522c315a00f864b7ca646c03ed13505ff26ac152301b0c20f48aa89a643b281f17a8e9e046ddf624f17a58d848920ade23ddade0d2097bc6c873c196bb22b11e6e73a561c0401ce0ec5845b8cbc494031bda668ac6ed92201f9ca953aa3768565a6133c770aec41383fcf71d979f67df52a807cb217f2b65b2cedfc9eac3", &std.fmt.bytesToHex(ct[0..256].*, .lower));
}
