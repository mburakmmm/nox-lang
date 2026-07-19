//! `nox.crypto` Zig kabuğu — stdlib fazı V.3 (bkz. nox-teknik-spesifikasyon.md).
//!
//! Kapsam bilinçli olarak DAR: yalnızca SHA-256 (Zig'in KENDİ, savaş-test
//! edilmiş `std.crypto.hash.sha2.Sha256`si — sıfırdan bir hash algoritması
//! YAZILMAZ, `nox.json`nin `std.json.parseFromSlice`i KULLANMA kararıyla
//! AYNI ilke). Sonuç, ARC'lı bir `str`e (KÜÇÜK harf hex, 64 karakter)
//! ÇEVRİLİP döner — `with_rt` GEREKİR (bkz. `http_client.zig`nin
//! `dupeToNoxStr`ı, AYNI ARC-str üretim deseni).
const std = @import("std");
const http_client = @import("http_client.zig");

const dupeToNoxStr = http_client.dupeToNoxStr;
const hex_chars = "0123456789abcdef";

export fn nox_crypto_sha256_hex_raw(rt: ?*anyopaque, data: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const d = data orelse return dupeToNoxStr(rt, "");
    const span = std.mem.span(d);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(span, &digest, .{});

    var hex_buf: [64]u8 = undefined;
    for (digest, 0..) |byte, i| {
        hex_buf[i * 2] = hex_chars[byte >> 4];
        hex_buf[i * 2 + 1] = hex_chars[byte & 0xF];
    }
    return dupeToNoxStr(rt, &hex_buf);
}

// Faz II devamı (test kapsamı genişletmesi, bkz. nox-teknik-spesifikasyon.md
// §3.67) — bu dosyanın DAHA ÖNCE HİÇ Zig-seviyeli unit testi YOKTU (yalnızca
// `tests/golden/codegen_cases/crypto_sha256_known_vectors.nox`, TAM Nox
// ikilisi üzerinden 2 bilinen vektörle). Burada `nox_crypto_sha256_hex_raw`
// DOĞRUDAN (runtime init GEREKMEZ — `with_rt` olsa da, `dupeToNoxStr`nin
// KENDİSİ `rt=null` İLE bile ARC-DIŞI bir statik/heap str üretebiliyor MU
// diye ÖNCE kontrol edilmeli; bkz. `http_client.zig`nin `dupeToNoxStr`ı —
// `nox_rc_alloc` `rt` GEREKTİRDİĞİNDEN GERÇEK bir runtime ile çağrılır) test
// edilir.
test "nox_crypto_sha256_hex_raw bilinen vektörler" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const empty = nox_crypto_sha256_hex_raw(rt, "") orelse return error.Failed;
    defer str.nox_str_release(rt, empty);
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        std.mem.sliceTo(empty, 0),
    );

    const abc = nox_crypto_sha256_hex_raw(rt, "abc") orelse return error.Failed;
    defer str.nox_str_release(rt, abc);
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        std.mem.sliceTo(abc, 0),
    );
}

test "nox_crypto_sha256_hex_raw hep 64 karakter, kucuk harf hex doner" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const inputs = [_][]const u8{ "x", "hello world", "a much longer input string used to check chunking" };
    for (inputs) |input| {
        const h = nox_crypto_sha256_hex_raw(rt, @ptrCast(input.ptr)) orelse return error.Failed;
        defer str.nox_str_release(rt, h);
        const slice = std.mem.sliceTo(h, 0);
        try std.testing.expectEqual(@as(usize, 64), slice.len);
        for (slice) |c| {
            try std.testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
        }
    }
}

test "nox_crypto_sha256_hex_raw deterministik VE farkli girdiler farkli hash uretir" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const h1 = nox_crypto_sha256_hex_raw(rt, "same input") orelse return error.Failed;
    defer str.nox_str_release(rt, h1);
    const h2 = nox_crypto_sha256_hex_raw(rt, "same input") orelse return error.Failed;
    defer str.nox_str_release(rt, h2);
    try std.testing.expectEqualStrings(std.mem.sliceTo(h1, 0), std.mem.sliceTo(h2, 0));

    const h3 = nox_crypto_sha256_hex_raw(rt, "different input") orelse return error.Failed;
    defer str.nox_str_release(rt, h3);
    try std.testing.expect(!std.mem.eql(u8, std.mem.sliceTo(h1, 0), std.mem.sliceTo(h3, 0)));
}
