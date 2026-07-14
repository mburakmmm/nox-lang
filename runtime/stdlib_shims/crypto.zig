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
