//! `nox.lock` imzalama (TODO 7.1, ADR-011): Ed25519 ayrık imza. Yayıncı bir anahtar çifti üretir (`noxc sign keygen`), kilit dosyasının
//! SHA-256'sını imzalar (`noxc sign lock` -> `nox.lock.sig`), tüketici açık anahtarı açıkça güvenilir ilan eder (`noxc sign trust`) ve çevrimdışı
//! doğrular (`noxc sign verify`). İptal edilen parmak izleri `revoked.txt`te tutulur ve her zaman güvenden önce gelir.
//!
//! Güven kökü (trust root) merkezi bir sunucu değildir: tüketicinin kendi `trusted/` dizinidir. Anahtar yenileme = yeni anahtarı güvenilir ilan
//! edip eskisini iptal etmek. İmza biçimi: üç satırlık metin (`nox-sig-v1`, `signer=<parmak izi>`, `sig=<128 hex>`). İmzalanan ileti
//! `"nox-lock-v1\n" ++ sha256(nox.lock baytları)`dır, bu yüzden başka bir bağlamda üretilmiş imza yeniden kullanılamaz.

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Verdict = enum { ok, malformed, revoked, untrusted_signer, bad_signature };

const domain = "nox-lock-v1\n";

pub fn fingerprint(pub_key: [32]u8) [32]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(&pub_key, &digest, .{});
    return std.fmt.bytesToHex(digest[0..16].*, .lower);
}

fn message(lock_bytes: []const u8) [domain.len + 32]u8 {
    var msg: [domain.len + 32]u8 = undefined;
    @memcpy(msg[0..domain.len], domain);
    Sha256.hash(lock_bytes, msg[domain.len..][0..32], .{});
    return msg;
}

pub fn publicKeyOf(seed: [32]u8) !Ed25519.KeyPair {
    return Ed25519.KeyPair.generateDeterministic(seed);
}

/// `nox.lock.sig` metnini üretir.
pub fn signLock(a: std.mem.Allocator, seed: [32]u8, lock_bytes: []const u8) ![]u8 {
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const msg = message(lock_bytes);
    const sig = try kp.sign(&msg, null);
    const fp = fingerprint(kp.public_key.toBytes());
    const sig_hex = std.fmt.bytesToHex(sig.toBytes(), .lower);
    return std.fmt.allocPrint(a, "nox-sig-v1\nsigner={s}\nsig={s}\n", .{ fp, sig_hex });
}

pub const Trusted = struct { fingerprint: [32]u8, key: [32]u8 };

/// `sig_text`i `lock_bytes`e karşı doğrular. `trusted`: tüketicinin güvendiği açık anahtarlar; `revoked`: iptal edilmiş parmak izleri (32 hex).
pub fn verifyLock(sig_text: []const u8, lock_bytes: []const u8, trusted: []const Trusted, revoked: []const []const u8) Verdict {
    var lines = std.mem.splitScalar(u8, sig_text, '\n');
    const header = lines.next() orelse return .malformed;
    if (!std.mem.eql(u8, std.mem.trim(u8, header, " \r"), "nox-sig-v1")) return .malformed;
    var signer: ?[]const u8 = null;
    var sig_hex: ?[]const u8 = null;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (std.mem.startsWith(u8, line, "signer=")) signer = line["signer=".len..];
        if (std.mem.startsWith(u8, line, "sig=")) sig_hex = line["sig=".len..];
    }
    const sg = signer orelse return .malformed;
    const sh = sig_hex orelse return .malformed;
    if (sg.len != 32 or sh.len != 128) return .malformed;
    for (revoked) |r| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, r, " \r\t"), sg)) return .revoked;
    var key: ?[32]u8 = null;
    for (trusted) |t| if (std.mem.eql(u8, &t.fingerprint, sg)) {
        key = t.key;
    };
    const pk_bytes = key orelse return .untrusted_signer;
    var sig_bytes: [64]u8 = undefined;
    _ = std.fmt.hexToBytes(&sig_bytes, sh) catch return .malformed;
    const pk = Ed25519.PublicKey.fromBytes(pk_bytes) catch return .malformed;
    const msg = message(lock_bytes);
    Ed25519.Signature.fromBytes(sig_bytes).verify(&msg, pk) catch return .bad_signature;
    return .ok;
}

test "imza turu: üret, doğrula; değiştirilmiş kilit, yanlış anahtar, iptal ve bozuk biçim reddedilir" {
    const a = std.testing.allocator;
    var seed: [32]u8 = undefined;
    for (&seed, 0..) |*b, i| b.* = @intCast(i + 1);
    const kp = try publicKeyOf(seed);
    const lock = "{\"packages\":[{\"alias\":\"nyx\",\"resolved\":\"a12f\"}]}";
    const sig_text = try signLock(a, seed, lock);
    defer a.free(sig_text);
    const fp = fingerprint(kp.public_key.toBytes());
    const trust = [_]Trusted{.{ .fingerprint = fp, .key = kp.public_key.toBytes() }};

    try std.testing.expectEqual(Verdict.ok, verifyLock(sig_text, lock, &trust, &.{}));
    // kilitte tek bayt değişirse imza geçersiz
    try std.testing.expectEqual(Verdict.bad_signature, verifyLock(sig_text, "{\"packages\":[{\"alias\":\"nyx\",\"resolved\":\"a12e\"}]}", &trust, &.{}));
    // güvenilmeyen imzalayan
    try std.testing.expectEqual(Verdict.untrusted_signer, verifyLock(sig_text, lock, &.{}, &.{}));
    // iptal, güvenden önce gelir
    const revoked = [_][]const u8{&fp};
    try std.testing.expectEqual(Verdict.revoked, verifyLock(sig_text, lock, &trust, &revoked));
    // aynı parmak izine başka anahtar iliştirilmişse imza tutmaz
    var other_seed = seed;
    other_seed[0] ^= 0xff;
    const other = try publicKeyOf(other_seed);
    const spoof = [_]Trusted{.{ .fingerprint = fp, .key = other.public_key.toBytes() }};
    try std.testing.expectEqual(Verdict.bad_signature, verifyLock(sig_text, lock, &spoof, &.{}));
    // bozuk biçimler
    try std.testing.expectEqual(Verdict.malformed, verifyLock("", lock, &trust, &.{}));
    try std.testing.expectEqual(Verdict.malformed, verifyLock("nox-sig-v1\nsigner=zz\nsig=00\n", lock, &trust, &.{}));
    try std.testing.expectEqual(Verdict.malformed, verifyLock("baska-v2\nsigner=x\nsig=y\n", lock, &trust, &.{}));
}
