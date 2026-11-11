//! mTLS istemci sertifikası yükleyici (v2.1.40): PEM sertifika zinciri + PEM özel anahtar → `TlsClient.ClientCert`.
//!
//! Desteklenen anahtarlar: ECDSA P-256 ve P-384 (PKCS#8 `BEGIN PRIVATE KEY` ya da SEC1 `BEGIN EC PRIVATE KEY`), Ed25519 (PKCS#8) ve RSA (PKCS#1 `BEGIN RSA PRIVATE KEY` ya da PKCS#8; en çok 4096 bit,
//! RSASSA-PSS ile imzalanır: `tls_client.zig` `rsaPssSign`).
//! DER ayrıştırması bilinçli olarak asgaridir: yalnızca anahtar baytlarına ulaşmak için gereken TLV'ler okunur.

const std = @import("std");
const TlsClient = @import("../vendor/tls_client.zig");

pub const Loaded = struct {
    gpa: std.mem.Allocator,
    chain: [][]u8,
    cert: TlsClient.ClientCert,
    /// RSA anahtarının `n ‖ d` baytları (varsa); `deinit` sıfırlayıp serbest bırakır.
    rsa_storage: ?[]u8 = null,

    pub fn deinit(self: *Loaded) void {
        for (self.chain) |c| self.gpa.free(c);
        self.gpa.free(self.chain);
        if (self.rsa_storage) |st| {
            std.crypto.secureZero(u8, st);
            self.gpa.free(st);
        }
    }
};

pub const ParsedKey = struct { key: TlsClient.ClientCert.Key, storage: ?[]u8 = null };

pub const LoadError = error{ OutOfMemory, BadCertificatePem, BadKeyPem, UnsupportedKey, FileTooLarge, ReadFailed };

/// `-----BEGIN <label>-----` … `-----END <label>-----` bloklarından `label` olanların base64 çözülmüş DER'lerini (sırayla) toplar.
fn pemBlocks(gpa: std.mem.Allocator, pem: []const u8, labels: []const []const u8, out: *std.ArrayListUnmanaged([]u8)) LoadError!void {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, pem, pos, "-----BEGIN ")) |b| {
        const label_start = b + "-----BEGIN ".len;
        const label_end = std.mem.indexOfPos(u8, pem, label_start, "-----") orelse return;
        const label = pem[label_start..label_end];
        const body_start = label_end + 5;
        const end_marker = "-----END ";
        const e = std.mem.indexOfPos(u8, pem, body_start, end_marker) orelse return;
        pos = e + end_marker.len;
        var wanted = false;
        for (labels) |l| if (std.mem.eql(u8, l, label)) {
            wanted = true;
        };
        if (!wanted) continue;
        // Boşlukları at, base64 çöz.
        var compact: std.ArrayListUnmanaged(u8) = .empty;
        defer compact.deinit(gpa);
        for (pem[body_start..e]) |ch| {
            if (ch == '\n' or ch == '\r' or ch == ' ' or ch == '\t') continue;
            try compact.append(gpa, ch);
        }
        const dec = std.base64.standard.Decoder;
        const n = dec.calcSizeForSlice(compact.items) catch return error.BadCertificatePem;
        const der = try gpa.alloc(u8, n);
        errdefer gpa.free(der);
        dec.decode(der, compact.items) catch return error.BadCertificatePem;
        try out.append(gpa, der);
    }
}

const Tlv = struct { tag: u8, content: []const u8, end: usize };

fn readTlv(buf: []const u8, pos: usize) ?Tlv {
    if (pos + 2 > buf.len) return null;
    const tag = buf[pos];
    var len: usize = buf[pos + 1];
    var p = pos + 2;
    if (len & 0x80 != 0) {
        const nbytes = len & 0x7f;
        if (nbytes == 0 or nbytes > 4 or p + nbytes > buf.len) return null;
        len = 0;
        for (buf[p .. p + nbytes]) |b| len = (len << 8) | b;
        p += nbytes;
    }
    if (p + len > buf.len) return null;
    return .{ .tag = tag, .content = buf[p .. p + len], .end = p + len };
}

const oid_ec_public_key = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01 };
const oid_ed25519 = [_]u8{ 0x2B, 0x65, 0x70 };
const oid_rsa_encryption = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01 };

/// DER INTEGER içeriğinden baştaki 0x00 işaret baytını atar.
fn stripInt(content: []const u8) []const u8 {
    var c = content;
    while (c.len > 1 and c[0] == 0) c = c[1..];
    return c;
}

/// PKCS#1 `RSAPrivateKey`: SEQUENCE { INTEGER 0, n, e, d, p, q, dp, dq, qinv } → `n ‖ d` kopyası.
fn rsaKey(gpa: std.mem.Allocator, der: []const u8) LoadError!ParsedKey {
    const seq = readTlv(der, 0) orelse return error.BadKeyPem;
    if (seq.tag != 0x30) return error.BadKeyPem;
    const ver = readTlv(seq.content, 0) orelse return error.BadKeyPem;
    const n = readTlv(seq.content, ver.end) orelse return error.BadKeyPem;
    const e = readTlv(seq.content, n.end) orelse return error.BadKeyPem;
    const d = readTlv(seq.content, e.end) orelse return error.BadKeyPem;
    if (n.tag != 0x02 or e.tag != 0x02 or d.tag != 0x02) return error.BadKeyPem;
    const nb = stripInt(n.content);
    const db = stripInt(d.content);
    if (nb.len < 128 or nb.len > 512 or db.len > nb.len) return error.UnsupportedKey; // 1024-4096 bit
    const st = try gpa.alloc(u8, nb.len + db.len);
    @memcpy(st[0..nb.len], nb);
    @memcpy(st[nb.len..], db);
    return .{ .key = .{ .rsa = .{ .n = st[0..nb.len], .d = st[nb.len..] } }, .storage = st };
}

/// SEC1 `ECPrivateKey`: SEQUENCE { INTEGER 1, OCTET STRING privateKey, ... } → ham anahtar baytları.
fn sec1Key(der: []const u8) ?[]const u8 {
    const seq = readTlv(der, 0) orelse return null;
    if (seq.tag != 0x30) return null;
    const ver = readTlv(seq.content, 0) orelse return null;
    if (ver.tag != 0x02) return null;
    const key = readTlv(seq.content, ver.end) orelse return null;
    if (key.tag != 0x04) return null;
    return key.content;
}

fn keyFromBytes(raw: []const u8, ed25519: bool) LoadError!TlsClient.ClientCert.Key {
    if (ed25519) {
        if (raw.len != 32) return error.UnsupportedKey;
        return .{ .ed25519 = raw[0..32].* };
    }
    return switch (raw.len) {
        32 => .{ .p256 = raw[0..32].* },
        48 => .{ .p384 = raw[0..48].* },
        else => error.UnsupportedKey,
    };
}

pub fn parsePrivateKey(gpa: std.mem.Allocator, pem: []const u8) LoadError!ParsedKey {
    var blocks: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (blocks.items) |b| gpa.free(b);
        blocks.deinit(gpa);
    }
    try pemBlocks(gpa, pem, &.{ "PRIVATE KEY", "EC PRIVATE KEY", "RSA PRIVATE KEY" }, &blocks);
    if (blocks.items.len == 0) {
        // Parola korumalı anahtar özel bir iletiyle reddedilsin.
        if (std.mem.indexOf(u8, pem, "BEGIN ENCRYPTED PRIVATE KEY") != null) return error.UnsupportedKey;
        return error.BadKeyPem;
    }
    const der = blocks.items[0];
    if (std.mem.indexOf(u8, pem, "BEGIN RSA PRIVATE KEY") != null) return rsaKey(gpa, der);
    const is_sec1 = std.mem.indexOf(u8, pem, "BEGIN EC PRIVATE KEY") != null;
    if (is_sec1) {
        const raw = sec1Key(der) orelse return error.BadKeyPem;
        return .{ .key = try keyFromBytes(raw, false) };
    }
    // PKCS#8: SEQUENCE { INTEGER 0, SEQUENCE { OID, [params] }, OCTET STRING { privateKey } }
    const seq = readTlv(der, 0) orelse return error.BadKeyPem;
    if (seq.tag != 0x30) return error.BadKeyPem;
    const ver = readTlv(seq.content, 0) orelse return error.BadKeyPem;
    const alg = readTlv(seq.content, ver.end) orelse return error.BadKeyPem;
    if (alg.tag != 0x30) return error.BadKeyPem;
    const oid = readTlv(alg.content, 0) orelse return error.BadKeyPem;
    const priv = readTlv(seq.content, alg.end) orelse return error.BadKeyPem;
    if (priv.tag != 0x04) return error.BadKeyPem;
    if (std.mem.eql(u8, oid.content, &oid_ed25519)) {
        // privateKey = OCTET STRING { OCTET STRING seed(32) }
        const inner = readTlv(priv.content, 0) orelse return error.BadKeyPem;
        if (inner.tag != 0x04) return error.BadKeyPem;
        return .{ .key = try keyFromBytes(inner.content, true) };
    }
    if (std.mem.eql(u8, oid.content, &oid_ec_public_key)) {
        const raw = sec1Key(priv.content) orelse return error.BadKeyPem;
        return .{ .key = try keyFromBytes(raw, false) };
    }
    if (std.mem.eql(u8, oid.content, &oid_rsa_encryption)) return rsaKey(gpa, priv.content);
    return error.UnsupportedKey; // diğer algoritmalar
}

pub fn parseChain(gpa: std.mem.Allocator, pem: []const u8) LoadError![][]u8 {
    var blocks: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (blocks.items) |b| gpa.free(b);
        blocks.deinit(gpa);
    }
    try pemBlocks(gpa, pem, &.{"CERTIFICATE"}, &blocks);
    if (blocks.items.len == 0) return error.BadCertificatePem;
    return blocks.toOwnedSlice(gpa);
}

fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) LoadError![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.FileTooLarge,
        else => error.ReadFailed,
    };
}

pub fn load(gpa: std.mem.Allocator, io: std.Io, cert_path: []const u8, key_path: []const u8) LoadError!*Loaded {
    const cert_pem = try readFile(gpa, io, cert_path);
    defer gpa.free(cert_pem);
    const key_pem = try readFile(gpa, io, key_path);
    defer {
        std.crypto.secureZero(u8, key_pem);
        gpa.free(key_pem);
    }
    const chain = try parseChain(gpa, cert_pem);
    errdefer {
        for (chain) |c| gpa.free(c);
        gpa.free(chain);
    }
    const parsed = try parsePrivateKey(gpa, key_pem);
    errdefer if (parsed.storage) |st| {
        std.crypto.secureZero(u8, st);
        gpa.free(st);
    };
    const out = try gpa.create(Loaded);
    out.* = .{
        .gpa = gpa,
        .chain = chain,
        .cert = .{ .gpa = gpa, .chain = @ptrCast(chain), .key = parsed.key },
        .rsa_storage = parsed.storage,
    };
    // RSA-PSS tuzu: bağlantı başına yeni rastgele bayt.
    io.random(&out.cert.salt);
    return out;
}

const test_p256_sec1 =
        \\-----BEGIN EC PRIVATE KEY-----
        \\MHcCAQEEIFsTdrhnMtevDXcZIMjMHci3qoFVPdaTuuG0PEz9RR8HoAoGCCqGSM49
        \\AwEHoUQDQgAExBlTiJt5/096A37MwgRuFQeBG7CS42jKtMbgDWIBtxTLkE65tsUJ
        \\qstDHYyOSZ/RSrDpLT9842uigSrIc5wQXA==
        \\-----END EC PRIVATE KEY-----
        \\
    ;
const test_p256_pkcs8 =
        \\-----BEGIN PRIVATE KEY-----
        \\MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgWxN2uGcy168Ndxkg
        \\yMwdyLeqgVU91pO64bQ8TP1FHwehRANCAATEGVOIm3n/T3oDfszCBG4VB4EbsJLj
        \\aMq0xuANYgG3FMuQTrm2xQmqy0MdjI5Jn9FKsOktP3zja6KBKshznBBc
        \\-----END PRIVATE KEY-----
        \\
    ;
const test_p384_pkcs8 =
        \\-----BEGIN PRIVATE KEY-----
        \\MIG2AgEAMBAGByqGSM49AgEGBSuBBAAiBIGeMIGbAgEBBDChHe664fahi17HXL3x
        \\h9fE4FBmGiTJmwxT09zAe2QrjbMO9+dZ6KGZY+VtrtAlkiyhZANiAAQ5p0ht92Us
        \\j0BQ8JWDYU51ZZZCXNO079zdVldczjXc2XSGQe/+9MVdLwJs4vDTu/zIZ2Rl1tjC
        \\V19CcQDiVOJliVg9MDixgg7z3bS9uUzFc4uvqZbQFkr790M84e5yeYk=
        \\-----END PRIVATE KEY-----
        \\
    ;
const test_ed25519 =
        \\-----BEGIN PRIVATE KEY-----
        \\MC4CAQAwBQYDK2VwBCIEIGdOua7eB9zyYKuJoNfzIjcLIMKyga8eHY4KvKNLwRRw
        \\-----END PRIVATE KEY-----
        \\
    ;

// Test anahtarları yalnızca bu birim testi için üretilmiş, hiçbir yerde kullanılmayan rastgele anahtarlardır.
test "SEC1 P-256, PKCS#8 P-256/P-384 ve PKCS#8 Ed25519 anahtarları okunur" {
    const gpa = std.testing.allocator;
    const k1 = (try parsePrivateKey(gpa, test_p256_sec1)).key;
    try std.testing.expect(k1 == .p256);
    const k2 = (try parsePrivateKey(gpa, test_p256_pkcs8)).key;
    try std.testing.expect(k2 == .p256);
    // Aynı anahtarın iki biçimi aynı baytları vermeli.
    try std.testing.expectEqualSlices(u8, &k1.p256, &k2.p256);
    const k3 = (try parsePrivateKey(gpa, test_p384_pkcs8)).key;
    try std.testing.expect(k3 == .p384);
    const k4 = (try parsePrivateKey(gpa, test_ed25519)).key;
    try std.testing.expect(k4 == .ed25519);
}

const test_rsa_pkcs1 =
        \\-----BEGIN RSA PRIVATE KEY-----
        \\MIIEpAIBAAKCAQEAlIgpWB5hyck8WeP0lIfbNf3g/eMto0e+9pw8fU1nifDWufAZ
        \\GF3vQJzdnTk8zVfFeqcMOZGXvuVnrqt+HpWqEjiKjMGqVEJSJ6DRbhhVwYhK6F83
        \\mYJwr8LiOI+AwFd3yzzEa+JCCBla38AVqAzSKK2g1DK3VCCEvXzIu0+vidvhE9x3
        \\N1xlJecJ7T178uorOdONbtF6bnxCKdM0A65FTjM6Ol/Vmrs3kuObImLaR0Fq4yZT
        \\Q8MJFp0qXn+izWeJBmwgiA+qtTqU1M/3mzVrP7Xh/B8FSPQI43SXqv1P4A2vfh1D
        \\rNxpimMqR4iFzLfl0DxEDAHg4Ujo9hoSyTI57QIDAQABAoIBABHeruC16QxyrFLh
        \\SNn83VwJ0yGgjStVlK1NXz6xCxmustrUfuRuWrxSkxwZGI5Y9r6are8YK+JQ7dA3
        \\PDl4RqmiCVNFcpVoFEPFxqShA2JBIEgEOqd6qM2QnBBzfWlGrLg0M6qKImkgic0d
        \\Kk3ZWwh/WTfmcSWLMwUsJ+dXPzaN4YLbv3dLa19c4/OsSCuJ0MyvJtAz9KYMVX7V
        \\41N/Tcj/MojB98e/cT21wGhyFfrl5mPi/fJlIamjhN9khDxJPL1S9M7VrdzYoPI/
        \\gphzcHcwmzgledC9vD9CHiuKNuNGJ9qxi04StrmuJGl9ueaf+JV6G0Xz06ycnaW2
        \\i0HnPMECgYEAw6PT0X/8qQ74VPE/p9wv6sB7xgL1qtLsm3H/oyz73yxqBBVgFEvY
        \\yFaVn+7X7uqS6KzMIxy/NnqsOtxIDzURUT+BmAYVMyWAVuLn8jaVscTVDzBaMI+0
        \\z5MVaa9jRWmyqed1abdRU85JmBWv+WMaDFeAG4n8HJH1y1sLHl6dWMECgYEAwluc
        \\fJxbPZoy9+HOi1ewFislW074SCkGDTJtqyx48CinSjHfV8wW0D6FUZVePwYYF60l
        \\v/8LaxO1cCYRsuJW+uPQbtlI2Iqv6nVJ1+QK3NdeTEYgFTB7q8ufq8YhkEU21yoe
        \\i55qX0DXJa7mJdoQjR4HuhVNEer5RN1gLHtRoC0CgYEAi2GVkEVx2XQr4kB6THon
        \\vUTjKcCEC+732QtPyI5M58P5x+z+pZcf3CMruGTufG2suo4ZZc6eQA8H02uK/yKc
        \\stje2FNFGUpXdA92lm7jGWKVNJwLNVu8wsIUWFY3EIXsXvXjBa0wCNgIQIz68V70
        \\eOSCBZy5/BTVG8tCUaGw0kECgYEAiWyDSmy36ufT8AeeplH7NMGPKW++CC/RkpU8
        \\jBLm9FCacNCwrgClhNsgIx5tRDzH3j3UelwYs758xO52BzkY7U8VursyUcJGPo5u
        \\BxO8RoiVqXLQDot4dnGE1c1DQCJgc2TZsjjx16YeOgvfuZXlrBI2vnF/TBML65Bo
        \\Byuu/IUCgYAm8KBSbc0qXvxP0zvTae37tlypzZAEb71gPFx3uBGttMeQKJgOvJht
        \\dpxEeVP1uAV+i2Fvjf+5L2fGDRUNqC5/nmZRO7Zzx5HUMhS+6LzYJsrMVJgfb61l
        \\dicamwg8m9XHfykKGwmTalvgbV9yf0ctZl1TgjdTKCFBctAQVdUVSA==
        \\-----END RSA PRIVATE KEY-----
        \\
    ;
const test_rsa_pkcs8 =
        \\-----BEGIN PRIVATE KEY-----
        \\MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQCUiClYHmHJyTxZ
        \\4/SUh9s1/eD94y2jR772nDx9TWeJ8Na58BkYXe9AnN2dOTzNV8V6pww5kZe+5Weu
        \\q34elaoSOIqMwapUQlInoNFuGFXBiEroXzeZgnCvwuI4j4DAV3fLPMRr4kIIGVrf
        \\wBWoDNIoraDUMrdUIIS9fMi7T6+J2+ET3Hc3XGUl5wntPXvy6is5041u0XpufEIp
        \\0zQDrkVOMzo6X9WauzeS45siYtpHQWrjJlNDwwkWnSpef6LNZ4kGbCCID6q1OpTU
        \\z/ebNWs/teH8HwVI9AjjdJeq/U/gDa9+HUOs3GmKYypHiIXMt+XQPEQMAeDhSOj2
        \\GhLJMjntAgMBAAECggEAEd6u4LXpDHKsUuFI2fzdXAnTIaCNK1WUrU1fPrELGa6y
        \\2tR+5G5avFKTHBkYjlj2vpqt7xgr4lDt0Dc8OXhGqaIJU0VylWgUQ8XGpKEDYkEg
        \\SAQ6p3qozZCcEHN9aUasuDQzqooiaSCJzR0qTdlbCH9ZN+ZxJYszBSwn51c/No3h
        \\gtu/d0trX1zj86xIK4nQzK8m0DP0pgxVftXjU39NyP8yiMH3x79xPbXAaHIV+uXm
        \\Y+L98mUhqaOE32SEPEk8vVL0ztWt3Nig8j+CmHNwdzCbOCV50L28P0IeK4o240Yn
        \\2rGLThK2ua4kaX255p/4lXobRfPTrJydpbaLQec8wQKBgQDDo9PRf/ypDvhU8T+n
        \\3C/qwHvGAvWq0uybcf+jLPvfLGoEFWAUS9jIVpWf7tfu6pLorMwjHL82eqw63EgP
        \\NRFRP4GYBhUzJYBW4ufyNpWxxNUPMFowj7TPkxVpr2NFabKp53Vpt1FTzkmYFa/5
        \\YxoMV4AbifwckfXLWwseXp1YwQKBgQDCW5x8nFs9mjL34c6LV7AWKyVbTvhIKQYN
        \\Mm2rLHjwKKdKMd9XzBbQPoVRlV4/BhgXrSW//wtrE7VwJhGy4lb649Bu2UjYiq/q
        \\dUnX5Arc115MRiAVMHury5+rxiGQRTbXKh6LnmpfQNclruYl2hCNHge6FU0R6vlE
        \\3WAse1GgLQKBgQCLYZWQRXHZdCviQHpMeie9ROMpwIQL7vfZC0/Ijkznw/nH7P6l
        \\lx/cIyu4ZO58bay6jhllzp5ADwfTa4r/Ipyy2N7YU0UZSld0D3aWbuMZYpU0nAs1
        \\W7zCwhRYVjcQhexe9eMFrTAI2AhAjPrxXvR45IIFnLn8FNUby0JRobDSQQKBgQCJ
        \\bINKbLfq59PwB56mUfs0wY8pb74IL9GSlTyMEub0UJpw0LCuAKWE2yAjHm1EPMfe
        \\PdR6XBizvnzE7nYHORjtTxW6uzJRwkY+jm4HE7xGiJWpctAOi3h2cYTVzUNAImBz
        \\ZNmyOPHXph46C9+5leWsEja+cX9MEwvrkGgHK678hQKBgCbwoFJtzSpe/E/TO9Np
        \\7fu2XKnNkARvvWA8XHe4Ea20x5AomA68mG12nER5U/W4BX6LYW+N/7kvZ8YNFQ2o
        \\Ln+eZlE7tnPHkdQyFL7ovNgmysxUmB9vrWV2JxqbCDyb1cd/KQobCZNqW+BtX3J/
        \\Ry1mXVOCN1MoIUFy0BBV1RVI
        \\-----END PRIVATE KEY-----
        \\
    ;

test "RSA PKCS#1 ve PKCS#8 anahtarları aynı n/d değerlerini verir" {
    const gpa = std.testing.allocator;
    const a = try parsePrivateKey(gpa, test_rsa_pkcs1);
    defer gpa.free(a.storage.?);
    const b = try parsePrivateKey(gpa, test_rsa_pkcs8);
    defer gpa.free(b.storage.?);
    try std.testing.expect(a.key == .rsa and b.key == .rsa);
    try std.testing.expectEqualSlices(u8, a.key.rsa.n, b.key.rsa.n);
    try std.testing.expectEqualSlices(u8, a.key.rsa.d, b.key.rsa.d);
    try std.testing.expectEqual(@as(usize, 256), a.key.rsa.n.len);
}

// RSASSA-PSS imzası std'nin kendi doğrulayıcısıyla (e = 65537) doğrulanır: SHA-256, SHA-384 ve SHA-512.
test "rsaPssSign std PSS doğrulayıcısıyla uyumlu imzalar üretir" {
    const gpa = std.testing.allocator;
    const parsed = try parsePrivateKey(gpa, test_rsa_pkcs1);
    defer gpa.free(parsed.storage.?);
    const key = parsed.key.rsa;
    const rsa = std.crypto.Certificate.rsa;
    const pk = try rsa.PublicKey.fromBytes(&.{ 0x01, 0x00, 0x01 }, key.n);
    var salt: [64]u8 = undefined;
    for (&salt, 0..) |*b, i| b.* = @intCast((i * 37 + 11) & 0xff);
    const msg = "TLS 1.3, client CertificateVerify test message";
    inline for (.{ std.crypto.hash.sha2.Sha256, std.crypto.hash.sha2.Sha384, std.crypto.hash.sha2.Sha512 }) |H| {
        var out: [512]u8 = undefined;
        const n = try TlsClient.rsaPssSign(H, key, msg, &salt, &out);
        try std.testing.expectEqual(@as(usize, 256), n);
        try rsa.PSSSignature.verify(256, out[0..256].*, msg, pk, H);
        // Bozulmuş mesaj doğrulanmamalı.
        try std.testing.expectError(error.InvalidSignature, rsa.PSSSignature.verify(256, out[0..256].*, "other message", pk, H));
    }
}

test "şifreli anahtar açık hatayla reddedilir" {
    const enc =
        \\-----BEGIN ENCRYPTED PRIVATE KEY-----
        \\MIIBOgIBAAJBAL
        \\-----END ENCRYPTED PRIVATE KEY-----
        \\
    ;
    try std.testing.expectError(error.UnsupportedKey, parsePrivateKey(std.testing.allocator, enc));
}
