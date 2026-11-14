//! Yayın bildirimleri (attestation) — istemci tarafı (TODO 7.4 S2, tasarım: `project/registry-guvenlik-tasarimi-2026-11.md`).
//! Yayıncı `{ad, depo, ref, commit, SBOM SHA-256}` kanonik metnini Ed25519 anahtarıyla imzalar (`noxc publish`), registry yalnızca hesabına KAYITLI, ETKİN anahtarın imzasını kabul eder
//! (`services/noxpkg/handlers_api.nox`), tüketici `noxc sign check` ile kilit dosyasındaki her commit için bildirimi KENDİ başına yeniden doğrular (sunucuya güvenmek zorunda değildir).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;
const registry = @import("registry.zig");
const signing = @import("signing.zig");

/// Sunucuyla BİREBİR aynı kanonik metin (`statement_text` in handlers_api.nox).
pub fn statement(a: Allocator, name: []const u8, repo: []const u8, ref: []const u8, commit: []const u8, sbom_sha256: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "nox-attest-v1\nname={s}\nrepo={s}\nref={s}\ncommit={s}\nsbom={s}\n", .{ name, repo, ref, commit, sbom_sha256 });
}

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    Sha256.hash(bytes, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

/// Ed25519 imzası (128 hex).
pub fn signHex(seed: [32]u8, text: []const u8) ![128]u8 {
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const sig = try kp.sign(text, null);
    return std.fmt.bytesToHex(sig.toBytes(), .lower);
}

pub fn verifyHex(pub_hex: []const u8, text: []const u8, sig_hex: []const u8) bool {
    if (pub_hex.len != 64 or sig_hex.len != 128) return false;
    var pk: [32]u8 = undefined;
    var sg: [64]u8 = undefined;
    _ = std.fmt.hexToBytes(&pk, pub_hex) catch return false;
    _ = std.fmt.hexToBytes(&sg, sig_hex) catch return false;
    const public_key = Ed25519.PublicKey.fromBytes(pk) catch return false;
    Ed25519.Signature.fromBytes(sg).verify(text, public_key) catch return false;
    return true;
}

const ApiAck = struct { ok: bool = false, status: []const u8 = "", fingerprint: []const u8 = "", @"error": []const u8 = "" };

fn post(a: Allocator, io: Io, api_base: []const u8, route: []const u8, body: []const u8, token: []const u8, insecure: bool) !ApiAck {
    const url = try std.fmt.allocPrint(a, "{s}{s}", .{ api_base, route });
    const reply = try registry.jsonRequest(a, io, .POST, url, body, token, insecure);
    const parsed = std.json.parseFromSlice(ApiAck, a, reply.body, .{ .ignore_unknown_fields = true }) catch return ApiAck{ .ok = false, .@"error" = "unexpected server reply" };
    return parsed.value;
}

/// Açık anahtarı hesaba kaydeder (`POST /api/keys`).
pub fn registerKey(a: Allocator, io: Io, api_base: []const u8, token: []const u8, pub_hex: []const u8, label: []const u8, insecure: bool) !ApiAck {
    const body = try std.fmt.allocPrint(a, "{{\"pub\": \"{s}\", \"label\": {f}}}", .{ pub_hex, std.json.fmt(label, .{}) });
    return post(a, io, api_base, "/api/keys", body, token, insecure);
}

pub const Submit = struct { name: []const u8, repo: []const u8, ref: []const u8, commit: []const u8, sbom: []const u8, signer: []const u8, sig: []const u8 };

pub fn submit(a: Allocator, io: Io, api_base: []const u8, token: []const u8, s: Submit, insecure: bool) !ApiAck {
    const body = try std.fmt.allocPrint(a, "{{\"name\": {f}, \"repo\": {f}, \"ref\": {f}, \"commit\": \"{s}\", \"sbom\": \"{s}\", \"signer\": \"{s}\", \"sig\": \"{s}\"}}", .{ std.json.fmt(s.name, .{}), std.json.fmt(s.repo, .{}), std.json.fmt(s.ref, .{}), s.commit, s.sbom, s.signer, s.sig });
    return post(a, io, api_base, "/api/attest", body, token, insecure);
}

pub const Remote = struct {
    name: []const u8 = "",
    repo: []const u8 = "",
    ref: []const u8 = "",
    commit: []const u8 = "",
    sbom: []const u8 = "",
    signer: []const u8 = "",
    pub_key: []const u8 = "",
    sig: []const u8 = "",
    publisher: []const u8 = "",
    key_revoked: bool = false,
};

const Listing = struct { ok: bool = false, attestations: []const RemoteWire = &.{} };
const RemoteWire = struct { name: []const u8 = "", repo: []const u8 = "", ref: []const u8 = "", commit: []const u8 = "", sbom: []const u8 = "", signer: []const u8 = "", @"pub": []const u8 = "", sig: []const u8 = "", publisher: []const u8 = "", key_revoked: bool = false };

/// `GET /api/attestations/<name>` — kimlik doğrulaması gerekmez.
pub fn fetchRemote(a: Allocator, io: Io, api_base: []const u8, name: []const u8, insecure: bool) ![]Remote {
    const url = try std.fmt.allocPrint(a, "{s}/api/attestations/{s}", .{ api_base, name });
    const reply = try registry.jsonRequest(a, io, .GET, url, null, null, insecure);
    if (reply.status != 200) return &.{};
    const parsed = std.json.parseFromSlice(Listing, a, reply.body, .{ .ignore_unknown_fields = true }) catch return &.{};
    var out = try a.alloc(Remote, parsed.value.attestations.len);
    for (parsed.value.attestations, 0..) |w, i| out[i] = .{ .name = w.name, .repo = w.repo, .ref = w.ref, .commit = w.commit, .sbom = w.sbom, .signer = w.signer, .pub_key = w.@"pub", .sig = w.sig, .publisher = w.publisher, .key_revoked = w.key_revoked };
    return out;
}

pub const Status = enum { signed_trusted, signed, unsigned, mismatch, bad_signature, key_revoked };

/// Bir kilitli paket (`repo`, `resolved` commit) için en iyi bildirimi seçer ve istemci tarafında yeniden doğrular.
/// `trusted_fps`: yerelde `noxc sign trust` ile güvenilir ilan edilmiş parmak izleri.
pub fn judge(remote: []const Remote, repo: []const u8, resolved: []const u8, trusted_fps: []const []const u8) struct { status: Status, publisher: []const u8 } {
    var any_for_name = false;
    for (remote) |r| {
        if (!std.mem.eql(u8, r.repo, repo)) continue;
        any_for_name = true;
        if (!std.mem.eql(u8, r.commit, resolved)) continue;
        // Bildirimin imzasını sunucuya güvenmeden doğrula + açık anahtar parmak izi bildirilen `signer` ile uyuşmalı.
        const text = statement(std.heap.page_allocator, r.name, r.repo, r.ref, r.commit, r.sbom) catch continue;
        defer std.heap.page_allocator.free(text);
        if (!verifyHex(r.pub_key, text, r.sig)) return .{ .status = .bad_signature, .publisher = r.publisher };
        var pk: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&pk, r.pub_key) catch return .{ .status = .bad_signature, .publisher = r.publisher };
        const fp = signing.fingerprint(pk);
        if (!std.mem.eql(u8, &fp, r.signer)) return .{ .status = .bad_signature, .publisher = r.publisher };
        if (r.key_revoked) return .{ .status = .key_revoked, .publisher = r.publisher };
        for (trusted_fps) |t| if (std.mem.eql(u8, t, r.signer)) return .{ .status = .signed_trusted, .publisher = r.publisher };
        return .{ .status = .signed, .publisher = r.publisher };
    }
    return .{ .status = if (any_for_name) .mismatch else .unsigned, .publisher = "" };
}

test "statement + imza + doğrulama gidiş-dönüş; başka ileti reddedilir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const seed = [_]u8{9} ** 32;
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const pub_hex = std.fmt.bytesToHex(kp.public_key.toBytes(), .lower);
    const text = try statement(a, "pkg", "github.com/o/r", "v1", "0123456789abcdef0123456789abcdef01234567", &sha256Hex("sbom"));
    const sig = try signHex(seed, text);
    try std.testing.expect(verifyHex(&pub_hex, text, &sig));
    const other = try statement(a, "pkg", "github.com/o/r", "v1", "89abcdef0123456789abcdef0123456789abcdef", &sha256Hex("sbom"));
    try std.testing.expect(!verifyHex(&pub_hex, other, &sig));
    try std.testing.expect(!verifyHex("zz", text, &sig));
}

test "judge: imzalı/güvenilir/iptal/uyuşmayan/imzasız" {
    const seed = [_]u8{3} ** 32;
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const pk = kp.public_key.toBytes();
    const pub_hex = std.fmt.bytesToHex(pk, .lower);
    const fp = signing.fingerprint(pk);
    const commit = "0123456789abcdef0123456789abcdef01234567";
    const text = try statement(std.testing.allocator, "pkg", "github.com/o/r", "v1", commit, &sha256Hex("s"));
    defer std.testing.allocator.free(text);
    const sig = try signHex(seed, text);
    const base: Remote = .{ .name = "pkg", .repo = "github.com/o/r", .ref = "v1", .commit = commit, .sbom = &sha256Hex("s"), .signer = &fp, .pub_key = &pub_hex, .sig = &sig, .publisher = "alice" };
    const trusted = [_][]const u8{&fp};
    try std.testing.expectEqual(Status.signed_trusted, judge(&.{base}, "github.com/o/r", commit, &trusted).status);
    try std.testing.expectEqual(Status.signed, judge(&.{base}, "github.com/o/r", commit, &.{}).status);
    var revoked = base;
    revoked.key_revoked = true;
    try std.testing.expectEqual(Status.key_revoked, judge(&.{revoked}, "github.com/o/r", commit, &trusted).status);
    try std.testing.expectEqual(Status.mismatch, judge(&.{base}, "github.com/o/r", "89abcdef0123456789abcdef0123456789abcdef", &trusted).status);
    try std.testing.expectEqual(Status.unsigned, judge(&.{}, "github.com/o/r", commit, &trusted).status);
    var tampered = base;
    tampered.ref = "v2";
    try std.testing.expectEqual(Status.bad_signature, judge(&.{tampered}, "github.com/o/r", commit, &trusted).status);
}
