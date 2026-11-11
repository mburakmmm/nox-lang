//! mTLS istemci sertifikası yükleyici (v2.1.40): PEM sertifika zinciri + PEM özel anahtar → `TlsClient.ClientCert`.
//!
//! Desteklenen anahtarlar (Zig std'de RSA imzalama olmadığından RSA YOK): ECDSA P-256 ve P-384 (PKCS#8 `BEGIN PRIVATE KEY` ya da SEC1 `BEGIN EC PRIVATE KEY`), Ed25519 (PKCS#8).
//! DER ayrıştırması bilinçli olarak asgaridir: yalnızca anahtar baytlarına ulaşmak için gereken TLV'ler okunur.

const std = @import("std");
const TlsClient = @import("../vendor/tls_client.zig");

pub const Loaded = struct {
    gpa: std.mem.Allocator,
    chain: [][]u8,
    cert: TlsClient.ClientCert,

    pub fn deinit(self: *Loaded) void {
        for (self.chain) |c| self.gpa.free(c);
        self.gpa.free(self.chain);
    }
};

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

pub fn parsePrivateKey(gpa: std.mem.Allocator, pem: []const u8) LoadError!TlsClient.ClientCert.Key {
    var blocks: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (blocks.items) |b| gpa.free(b);
        blocks.deinit(gpa);
    }
    try pemBlocks(gpa, pem, &.{ "PRIVATE KEY", "EC PRIVATE KEY" }, &blocks);
    if (blocks.items.len == 0) {
        // Etiket ayrımı: RSA anahtarı özel bir iletiyle reddedilsin.
        if (std.mem.indexOf(u8, pem, "BEGIN RSA PRIVATE KEY") != null or std.mem.indexOf(u8, pem, "BEGIN ENCRYPTED PRIVATE KEY") != null) return error.UnsupportedKey;
        return error.BadKeyPem;
    }
    const der = blocks.items[0];
    const is_sec1 = std.mem.indexOf(u8, pem, "BEGIN EC PRIVATE KEY") != null;
    if (is_sec1) {
        const raw = sec1Key(der) orelse return error.BadKeyPem;
        return keyFromBytes(raw, false);
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
        return keyFromBytes(inner.content, true);
    }
    if (std.mem.eql(u8, oid.content, &oid_ec_public_key)) {
        const raw = sec1Key(priv.content) orelse return error.BadKeyPem;
        return keyFromBytes(raw, false);
    }
    return error.UnsupportedKey; // RSA (rsaEncryption) ve diğerleri
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
    const key = try parsePrivateKey(gpa, key_pem);
    const out = try gpa.create(Loaded);
    out.* = .{
        .gpa = gpa,
        .chain = chain,
        .cert = .{ .gpa = gpa, .chain = @ptrCast(chain), .key = key },
    };
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
    const k1 = try parsePrivateKey(gpa, test_p256_sec1);
    try std.testing.expect(k1 == .p256);
    const k2 = try parsePrivateKey(gpa, test_p256_pkcs8);
    try std.testing.expect(k2 == .p256);
    // Aynı anahtarın iki biçimi aynı baytları vermeli.
    try std.testing.expectEqualSlices(u8, &k1.p256, &k2.p256);
    const k3 = try parsePrivateKey(gpa, test_p384_pkcs8);
    try std.testing.expect(k3 == .p384);
    const k4 = try parsePrivateKey(gpa, test_ed25519);
    try std.testing.expect(k4 == .ed25519);
}

test "RSA anahtarı açık hatayla reddedilir" {
    const rsa =
        \\-----BEGIN RSA PRIVATE KEY-----
        \\MIIBOgIBAAJBAL
        \\-----END RSA PRIVATE KEY-----
        \\
    ;
    try std.testing.expectError(error.UnsupportedKey, parsePrivateKey(std.testing.allocator, rsa));
}
