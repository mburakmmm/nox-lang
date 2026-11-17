//! `nox.crypto` Zig kabuğu — stdlib fazı V.3 (bkz. nox-teknik-spesifikasyon.md).
//!
//! Kapsam bilinçli olarak DAR: yalnızca SHA-256 (Zig'in KENDİ, savaş-test
//! edilmiş `std.crypto.hash.sha2.Sha256`si — sıfırdan bir hash algoritması
//! YAZILMAZ, `nox.json`nin `std.json.parseFromSlice`i KULLANMA kararıyla
//! AYNI ilke). Sonuç, ARC'lı bir `str`e (KÜÇÜK harf hex, 64 karakter)
//! ÇEVRİLİP döner — `with_rt` GEREKİR (bkz. `http_client.zig`nin
//! `dupeToNoxStr`ı, AYNI ARC-str üretim deseni).
const std = @import("std");
const wasm_host = @import("../wasm_host.zig");
const builtin = @import("builtin");
const http_client = if (@import("builtin").cpu.arch.isWasm() or @import("shim_util.zig").bare_kernel) @import("shim_util.zig") else @import("http_client.zig");
/// v2.1.58: çıplak çekirdek (freestanding, wasm DEĞİL): OS entropisi/`std.Io` yoktur. Özetler (sha1/sha256/sha512/hmac) ve sabit-zamanlı karşılaştırma çalışır; bellek-yoğun parola özetleri (argon2, scrypt: MiB) ve tuz gerektiren `*_hash` işlevleri DESTEKLENMEZ (`""`/0 döner), `bcrypt_verify` çalışır; `secure_random_hex` boş dize döner (sessizce öngörülebilir rastgelelik üretmek yerine).
const bare_kernel = @import("shim_util.zig").bare_kernel;
const str_mod = @import("../str.zig");

const dupeToNoxStr = http_client.dupeToNoxStr;
const hex_chars = "0123456789abcdef";

// Parola hash'leme (argon2id/bcrypt/scrypt) — Zig'in KENDİ, savaş-test
// edilmiş `std.crypto.pwhash.*`si (sıfırdan YAZILMAZ, dosyanın geri kalanıyla
// AYNI ilke). Üçü de OWASP'ın KENDİ önerdiği parametre ön-ayarını kullanır
// (`Params.owasp*`) — kullanıcıya bir tuning API'si SUNULMAZ, "doğru
// varsayılan, hiç seçenek yok" v1 basitleştirmesi (yanlış/zayıf bir maliyet
// parametresi seçme riskini TAMAMEN ortadan kaldırır). `strHash`/`strVerify`
// PHC/crypt biçimli TEK bir dizede TÜM parametreleri+tuzu (salt) gömer, bu
// YÜZDEN doğrulama İçin AYRI bir tuz/parametre saklanmasına GEREK YOK.
// `argon2`/`scrypt`in `strHash`ı bir `std.Io` GEREKTİRİR (yalnızca
// `io.random()` İçin, tuz üretimi — bkz. std kaynağı) — `http_client.zig`nin
// TÜM istekler ARASINDA PAYLAŞILAN `sharedClientIo()`sı burada da YENİDEN
// KULLANILIR (ayrı bir `std.Io.Threaded` örneği İçin AYNI süreç-geneli
// sinyal-işleyici çakışması riski taşımamak İçin — bkz. o fonksiyonun KENDİ
// belge notu).
const pwhash = std.crypto.pwhash;
const sharedIo = http_client.sharedClientIo;

/// Herhangi bir parola-hash `strHash`/`strVerify` çağrısı İçin yeterince
/// büyük, sabit boyutlu bir yığın arabelleği — argon2/scrypt'in KENDİ
/// test dosyalarında AYNI amaçla kullanılan 128 bayt İLE AYNI (bkz. std
/// kaynağı `argon2.zig`/`scrypt.zig` testleri); bcrypt'in `hash_length`i
/// (60) zaten bunun ÇOK altında.
const pwhash_buf_len = 128;

export fn nox_crypto_argon2_hash_raw(rt: ?*anyopaque, password: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    if (comptime bare_kernel) return dupeToNoxStr(rt, "");
    const p = password orelse return dupeToNoxStr(rt, "");
    var buf: [pwhash_buf_len]u8 = undefined;
    const hash = pwhash.argon2.strHash(str_mod.nox_str_slice(p), .{
        .allocator = @import("shim_util.zig").scratchAllocator(),
        .params = pwhash.argon2.Params.owasp_2id,
    }, &buf, sharedIo()) catch return dupeToNoxStr(rt, "");
    return dupeToNoxStr(rt, hash);
}

/// Bir parolayı DAHA ÖNCE `argon2_hash`nin ürettiği bir PHC dizesine karşı
/// doğrular. Yanlış parola VE bozuk/geçersiz bir `hash` dizesi (ör. BAŞKA
/// bir algoritmadan gelen) AYNI şekilde "doğrulanamadı" (0) DÖNER — hangi
/// nedenle başarısız olduğunu AYIRT ETMEMEK bilinçli bir güvenlik kararıdır
/// (bir saldırgana bozuk-hash/yanlış-parola arasındaki farkı bir yan-kanal
/// OLARAK sızdırmaz).
export fn nox_crypto_argon2_verify_raw(hash: ?[*:0]const u8, password: ?[*:0]const u8) callconv(.c) i32 {
    if (comptime bare_kernel) return 0;
    const h = hash orelse return 0;
    const p = password orelse return 0;
    pwhash.argon2.strVerify(str_mod.nox_str_slice(h), str_mod.nox_str_slice(p), .{
        .allocator = @import("shim_util.zig").scratchAllocator(),
    }, sharedIo()) catch return 0;
    return 1;
}

export fn nox_crypto_bcrypt_hash_raw(rt: ?*anyopaque, password: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    if (comptime bare_kernel) return dupeToNoxStr(rt, "");
    const p = password orelse return dupeToNoxStr(rt, "");
    var buf: [pwhash_buf_len]u8 = undefined;
    const hash = pwhash.bcrypt.strHash(str_mod.nox_str_slice(p), .{
        .params = pwhash.bcrypt.Params.owasp,
        .encoding = .crypt,
    }, &buf, sharedIo()) catch return dupeToNoxStr(rt, "");
    return dupeToNoxStr(rt, hash);
}

export fn nox_crypto_bcrypt_verify_raw(hash: ?[*:0]const u8, password: ?[*:0]const u8) callconv(.c) i32 {
    const h = hash orelse return 0;
    const p = password orelse return 0;
    pwhash.bcrypt.strVerify(str_mod.nox_str_slice(h), str_mod.nox_str_slice(p), .{
        .silently_truncate_password = false,
    }) catch return 0;
    return 1;
}

export fn nox_crypto_scrypt_hash_raw(rt: ?*anyopaque, password: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    if (comptime bare_kernel) return dupeToNoxStr(rt, "");
    const p = password orelse return dupeToNoxStr(rt, "");
    var buf: [pwhash_buf_len]u8 = undefined;
    const hash = pwhash.scrypt.strHash(str_mod.nox_str_slice(p), .{
        .allocator = @import("shim_util.zig").scratchAllocator(),
        .params = pwhash.scrypt.Params.owasp,
        .encoding = .phc,
    }, &buf, sharedIo()) catch return dupeToNoxStr(rt, "");
    return dupeToNoxStr(rt, hash);
}

export fn nox_crypto_scrypt_verify_raw(hash: ?[*:0]const u8, password: ?[*:0]const u8) callconv(.c) i32 {
    if (comptime bare_kernel) return 0;
    const h = hash orelse return 0;
    const p = password orelse return 0;
    pwhash.scrypt.strVerify(str_mod.nox_str_slice(h), str_mod.nox_str_slice(p), .{
        .allocator = @import("shim_util.zig").scratchAllocator(),
    }) catch return 0;
    return 1;
}

/// Faz LL.4 (bkz. nox-teknik-spesifikasyon.md §3.71): `std.c.arc4random_buf`
/// Windows'ta void'dir (bkz. `runtime/collections/dict.zig`nin AYNI
/// düzeltmesi) — `advapi32.dll`nin `RtlGenRandom`i (`SystemFunction036`)
/// YERİNE kullanılır.
pub fn secureRandomBuf(buf: []u8) void {
    if (comptime bare_kernel) {
        @memset(buf, 0); // erişilemez: çağıranlar `bare_kernel` iken zaten dönmüştür
        return;
    }
    if (builtin.os.tag == .windows) {
        _ = SystemFunction036(buf.ptr, @intCast(buf.len));
    } else if (builtin.os.tag == .linux) {
        linuxGetRandom(buf);
    } else if (comptime wasm_host.is_freestanding_wasm) {
        wasm_host.random_fill(buf.ptr, buf.len);
    } else if (comptime builtin.os.tag == .wasi) {
        _ = std.os.wasi.random_get(buf.ptr, buf.len);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}
extern "advapi32" fn SystemFunction036(buf: [*]u8, len: u32) callconv(.c) u8;

/// v2.0 madde 8: `runtime/collections/dict.zig`nin AYNI-isimli fonksiyonuyla
/// AYNI gerekçe/keşif — bkz. onun belge notu.
fn linuxGetRandom(buf: []u8) void {
    if (comptime builtin.abi.isAndroid()) {
        var filled: usize = 0;
        while (filled < buf.len) {
            const rc = std.os.linux.getrandom(buf.ptr + filled, buf.len - filled, 0);
            const n: isize = @bitCast(rc);
            if (n <= 0) return;
            filled += @intCast(n);
        }
        return;
    }
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = std.c.getrandom(buf.ptr + filled, buf.len - filled, 0);
        if (n <= 0) return;
        filled += @intCast(n);
    }
}

export fn nox_crypto_sha256_hex_raw(rt: ?*anyopaque, data: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const d = data orelse return dupeToNoxStr(rt, "");
    const span = str_mod.nox_str_slice(d);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(span, &digest, .{});

    var hex_buf: [64]u8 = undefined;
    for (digest, 0..) |byte, i| {
        hex_buf[i * 2] = hex_chars[byte >> 4];
        hex_buf[i * 2 + 1] = hex_chars[byte & 0xF];
    }
    return dupeToNoxStr(rt, &hex_buf);
}

/// Faz III.9 (bkz. nox-teknik-spesifikasyon.md §3.69) — `sha256_hex_raw`
/// İLE BİREBİR AYNI desen, YALNIZCA Zig'in `std.crypto.hash.Sha1`i
/// kullanır (20 baytlık özet, 40 karakterlik hex).
export fn nox_crypto_sha1_hex_raw(rt: ?*anyopaque, data: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const d = data orelse return dupeToNoxStr(rt, "");
    const span = str_mod.nox_str_slice(d);

    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(span, &digest, .{});

    var hex_buf: [digest.len * 2]u8 = undefined;
    for (digest, 0..) |byte, i| {
        hex_buf[i * 2] = hex_chars[byte >> 4];
        hex_buf[i * 2 + 1] = hex_chars[byte & 0xF];
    }
    return dupeToNoxStr(rt, &hex_buf);
}

/// v2.1.70: genel özet -> küçük harf hex yardımcısı (`Hash.hash(bytes, &out, .{})` arayüzüne sahip her `std.crypto.hash` türü).
fn hashHex(comptime Hash: type, rt: ?*anyopaque, data: ?[*:0]const u8) ?[*:0]u8 {
    const d = data orelse return dupeToNoxStr(rt, "");
    const span = str_mod.nox_str_slice(d);
    var digest: [Hash.digest_length]u8 = undefined;
    Hash.hash(span, &digest, .{});
    var hex_buf: [Hash.digest_length * 2]u8 = undefined;
    for (digest, 0..) |byte, i| {
        hex_buf[i * 2] = hex_chars[byte >> 4];
        hex_buf[i * 2 + 1] = hex_chars[byte & 0xF];
    }
    return dupeToNoxStr(rt, &hex_buf);
}

export fn nox_crypto_md5_hex_raw(rt: ?*anyopaque, data: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    return hashHex(std.crypto.hash.Md5, rt, data);
}
export fn nox_crypto_sha384_hex_raw(rt: ?*anyopaque, data: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    return hashHex(std.crypto.hash.sha2.Sha384, rt, data);
}
export fn nox_crypto_sha3_256_hex_raw(rt: ?*anyopaque, data: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    return hashHex(std.crypto.hash.sha3.Sha3_256, rt, data);
}
export fn nox_crypto_sha3_512_hex_raw(rt: ?*anyopaque, data: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    return hashHex(std.crypto.hash.sha3.Sha3_512, rt, data);
}
export fn nox_crypto_blake3_hex_raw(rt: ?*anyopaque, data: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    return hashHex(std.crypto.hash.Blake3, rt, data);
}

/// Faz III.9 — `sha256_hex_raw` İLE BİREBİR AYNI desen, `std.crypto.hash.
/// sha2.Sha512` (64 baytlık özet, 128 karakterlik hex).
export fn nox_crypto_sha512_hex_raw(rt: ?*anyopaque, data: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const d = data orelse return dupeToNoxStr(rt, "");
    const span = str_mod.nox_str_slice(d);

    var digest: [std.crypto.hash.sha2.Sha512.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(span, &digest, .{});

    var hex_buf: [digest.len * 2]u8 = undefined;
    for (digest, 0..) |byte, i| {
        hex_buf[i * 2] = hex_chars[byte >> 4];
        hex_buf[i * 2 + 1] = hex_chars[byte & 0xF];
    }
    return dupeToNoxStr(rt, &hex_buf);
}

// Güvenlik bulguları M-4/M-5/M-6 (bkz. güvenlik raporu, 20 Temmuz 2026) —
// DÜZELTİLDİ: stdlib DAHA ÖNCE (a) mesaj DOĞRULAMASI İçin bir HMAC ilkeli,
// (b) belirteç/parola-özeti KARŞILAŞTIRMASI İçin zaman-sabit bir alternatif,
// (c) GÜVENLİ (kriptografik) bir rastgelelik kaynağı SUNMUYORDU — bir
// kullanıcı bunlara İHTİYAÇ duyarsa ya `==`/`nox.random`ı YANLIŞ bağlamda
// kullanıyordu (zamanlama yan-kanalı/tahmin edilebilir tohum riski) ya da
// KENDİ (muhtemelen hatalı) çözümünü yazıyordu. ÜÇÜ de Zig'in KENDİ,
// savaş-test edilmiş ilkelidir — sıfırdan YAZILMAZ (`sha256`nin AYNI ilkesi).

/// `hmac_sha256(key, data)` — mesaj bütünlüğü/DOĞRULAMASI İçin (`sha256`nin
/// AKSİNE, paylaşılan bir GİZLİ anahtar GEREKTİRİR — saldırgan anahtarı
/// BİLMEDEN geçerli bir MAC ÜRETEMEZ, bu YÜZDEN sıradan bir hash'in
/// AKSİNE kimlik doğrulama/bütünlük İçin GÜVENLİDİR).
export fn nox_crypto_hmac_sha256_hex_raw(rt: ?*anyopaque, key: ?[*:0]const u8, data: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const k = key orelse return dupeToNoxStr(rt, "");
    const d = data orelse return dupeToNoxStr(rt, "");
    const key_span = str_mod.nox_str_slice(k);
    const data_span = str_mod.nox_str_slice(d);

    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var digest: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&digest, data_span, key_span);

    var hex_buf: [digest.len * 2]u8 = undefined;
    for (digest, 0..) |byte, i| {
        hex_buf[i * 2] = hex_chars[byte >> 4];
        hex_buf[i * 2 + 1] = hex_chars[byte & 0xF];
    }
    return dupeToNoxStr(rt, &hex_buf);
}

/// AEAD (v2.1.195, VAULT 1.3): `nox.crypto.aead_seal` / `aead_open`. Algoritma kodları: 0 chacha20-poly1305, 1 aes-256-gcm, 2 aes-128-gcm, 3 xchacha20-poly1305.
/// `key_hex`/`nonce_hex` onaltılık (anahtar/nonce uzunluğu algoritmaya göre denetlenir). Mühür = hex(şifreli metin || etiket). Başarı/başarısızlık `nox_crypto_aead_status_raw`la okunur
/// (0 tamam, 1 geçersiz algoritma, 2 anahtar uzunluğu, 3 nonce uzunluğu, 4 geçersiz hex, 5 kimlik doğrulama başarısız). Durum iş parçacığı-yereldir; iki çağrı arasında fiber askıya alınmaz.
threadlocal var tl_aead_status: i64 = 0;

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn hexDecodeInto(out: []u8, hex: []const u8) bool {
    if (hex.len != out.len * 2) return false;
    for (out, 0..) |*b, i| {
        const hi = hexVal(hex[i * 2]) orelse return false;
        const lo = hexVal(hex[i * 2 + 1]) orelse return false;
        b.* = (hi << 4) | lo;
    }
    return true;
}

/// `hexio` (v2.2.1): düz metin ve AAD onaltılık verilir/açılan düz metin onaltılık döner (ikili veri: NUL ve UTF-8 olmayan baytlar `str`e sığmaz). `seal` çıktısı ve `open` girdisi her iki kipte de onaltılıktır.
fn aeadRun(comptime A: type, rt: ?*anyopaque, seal: bool, hexio: bool, key_hex: []const u8, nonce_hex: []const u8, data_in: []const u8, aad_in: []const u8) ?[*:0]u8 {
    const alloc = @import("shim_util.zig").scratchAllocator();
    var data: []const u8 = data_in;
    var aad: []const u8 = aad_in;
    var data_owned: ?[]u8 = null;
    var aad_owned: ?[]u8 = null;
    defer if (data_owned) |d| alloc.free(d);
    defer if (aad_owned) |d| alloc.free(d);
    if (hexio) {
        if (aad_in.len % 2 != 0 or (seal and data_in.len % 2 != 0)) {
            tl_aead_status = 4;
            return dupeToNoxStr(rt, "");
        }
        if (seal) {
            const d = alloc.alloc(u8, data_in.len / 2) catch {
                tl_aead_status = 5;
                return dupeToNoxStr(rt, "");
            };
            data_owned = d;
            if (!hexDecodeInto(d, data_in)) {
                tl_aead_status = 4;
                return dupeToNoxStr(rt, "");
            }
            data = d;
        }
        const a = alloc.alloc(u8, aad_in.len / 2) catch {
            tl_aead_status = 5;
            return dupeToNoxStr(rt, "");
        };
        aad_owned = a;
        if (!hexDecodeInto(a, aad_in)) {
            tl_aead_status = 4;
            return dupeToNoxStr(rt, "");
        }
        aad = a;
    }
    var key: [A.key_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    var nonce: [A.nonce_length]u8 = undefined;
    if (key_hex.len != A.key_length * 2) {
        tl_aead_status = 2;
        return dupeToNoxStr(rt, "");
    }
    if (nonce_hex.len != A.nonce_length * 2) {
        tl_aead_status = 3;
        return dupeToNoxStr(rt, "");
    }
    if (!hexDecodeInto(&key, key_hex) or !hexDecodeInto(&nonce, nonce_hex)) {
        tl_aead_status = 4;
        return dupeToNoxStr(rt, "");
    }
    if (seal) {
        const buf = alloc.alloc(u8, data.len + A.tag_length) catch {
            tl_aead_status = 5;
            return dupeToNoxStr(rt, "");
        };
        defer alloc.free(buf);
        var tag: [A.tag_length]u8 = undefined;
        A.encrypt(buf[0..data.len], &tag, data, aad, nonce, key);
        @memcpy(buf[data.len..], &tag);
        const hex = alloc.alloc(u8, buf.len * 2) catch {
            tl_aead_status = 5;
            return dupeToNoxStr(rt, "");
        };
        defer alloc.free(hex);
        for (buf, 0..) |byte, i| {
            hex[i * 2] = hex_chars[byte >> 4];
            hex[i * 2 + 1] = hex_chars[byte & 0xF];
        }
        tl_aead_status = 0;
        return dupeToNoxStr(rt, hex);
    }
    // open: `data` = hex(şifreli metin || etiket)
    if (data.len % 2 != 0 or data.len < A.tag_length * 2) {
        tl_aead_status = 4;
        return dupeToNoxStr(rt, "");
    }
    const sealed = alloc.alloc(u8, data.len / 2) catch {
        tl_aead_status = 5;
        return dupeToNoxStr(rt, "");
    };
    defer alloc.free(sealed);
    if (!hexDecodeInto(sealed, data)) {
        tl_aead_status = 4;
        return dupeToNoxStr(rt, "");
    }
    const ct_len = sealed.len - A.tag_length;
    const plain = alloc.alloc(u8, ct_len) catch {
        tl_aead_status = 5;
        return dupeToNoxStr(rt, "");
    };
    defer alloc.free(plain);
    A.decrypt(plain, sealed[0..ct_len], sealed[ct_len..][0..A.tag_length].*, aad, nonce, key) catch {
        tl_aead_status = 5;
        return dupeToNoxStr(rt, "");
    };
    tl_aead_status = 0;
    if (hexio) {
        const hex = alloc.alloc(u8, plain.len * 2) catch {
            tl_aead_status = 5;
            return dupeToNoxStr(rt, "");
        };
        defer alloc.free(hex);
        for (plain, 0..) |byte, i| {
            hex[i * 2] = hex_chars[byte >> 4];
            hex[i * 2 + 1] = hex_chars[byte & 0xF];
        }
        return dupeToNoxStr(rt, hex);
    }
    return dupeToNoxStr(rt, plain);
}

export fn nox_crypto_aead_raw(rt: ?*anyopaque, seal: i64, alg: i64, key_hex: ?[*:0]const u8, nonce_hex: ?[*:0]const u8, data: ?[*:0]const u8, aad: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const k = str_mod.nox_str_slice(key_hex orelse return dupeToNoxStr(rt, ""));
    const n = str_mod.nox_str_slice(nonce_hex orelse return dupeToNoxStr(rt, ""));
    const d = str_mod.nox_str_slice(data orelse return dupeToNoxStr(rt, ""));
    const a = if (aad) |p| str_mod.nox_str_slice(p) else "";
    // `seal`: bit 0 = mühürle (yoksa aç); bit 1 = düz metin/AAD onaltılık (`hexio`).
    const s = (seal & 1) != 0;
    const hx = (seal & 2) != 0;
    return switch (alg) {
        0 => aeadRun(std.crypto.aead.chacha_poly.ChaCha20Poly1305, rt, s, hx, k, n, d, a),
        1 => aeadRun(std.crypto.aead.aes_gcm.Aes256Gcm, rt, s, hx, k, n, d, a),
        2 => aeadRun(std.crypto.aead.aes_gcm.Aes128Gcm, rt, s, hx, k, n, d, a),
        3 => aeadRun(std.crypto.aead.chacha_poly.XChaCha20Poly1305, rt, s, hx, k, n, d, a),
        else => blk: {
            tl_aead_status = 1;
            break :blk dupeToNoxStr(rt, "");
        },
    };
}

export fn nox_crypto_aead_status_raw() callconv(.c) i64 {
    return tl_aead_status;
}

/// `constant_time_eq(a, b)` — bir belirteç/parola-özeti KARŞILAŞTIRIRKEN
/// `==`in (ilk FARKLI bayta rastlayınca DURAN `strcmp`-tabanlı, bkz.
/// `compiler/codegen_qbe/codegen.zig`nin `str` eşitlik kodgen'i) yol AÇTIĞI
/// zamanlama yan-kanalını (bir saldırganın yanıt SÜRESİNDEN DEĞERİ bayt-
/// bayt SIZDIRABİLMESİ) ÖNLER. Python'un `hmac.compare_digest`i/Django'nun
/// `constant_time_compare`ıyla AYNI, standart teknik: uzunluk FARKLIYSA
/// HEMEN `false` (uzunluk genellikle GİZLİ SAYILMAZ — bkz. o kütüphanelerin
/// KENDİ gerekçesi); AYNI uzunluktaysa TÜM baytlar HER ZAMAN (erken çıkış
/// OLMADAN) XOR'lanıp BİRİKTİRİLİR.
export fn nox_crypto_constant_time_eq_raw(a: ?[*:0]const u8, b: ?[*:0]const u8) callconv(.c) i32 {
    const av = a orelse return 0;
    const bv = b orelse return 0;
    const a_span = str_mod.nox_str_slice(av);
    const b_span = str_mod.nox_str_slice(bv);
    if (a_span.len != b_span.len) return 0;
    var diff: u8 = 0;
    for (a_span, 0..) |byte, i| {
        diff |= byte ^ b_span[i];
    }
    return if (diff == 0) 1 else 0;
}

/// v2.1.154 (TODO 7.4 S2): Ed25519 ayrık imza doğrulama. `pub_hex` 64, `sig_hex` 128 küçük/büyük harf hex karakter olmalıdır; `msg` ham bayt dizisidir. Geçerli imza: 1; her türlü bozuk girdi
/// (uzunluk, hex olmayan, düşük dereceli/geçersiz nokta, yanlış imza): 0 — hata ayrıştırması yoktur, çağıran yalnızca "geçerli mi" sorusunu sorar. `nox.ed25519` sarar.
export fn nox_ed25519_verify_raw(pub_hex: ?[*:0]const u8, msg: ?[*:0]const u8, sig_hex: ?[*:0]const u8) callconv(.c) i32 {
    const ph = str_mod.nox_str_slice(pub_hex orelse return 0);
    const mm = str_mod.nox_str_slice(msg orelse return 0);
    const sh = str_mod.nox_str_slice(sig_hex orelse return 0);
    if (ph.len != 64 or sh.len != 128) return 0;
    var pk_bytes: [32]u8 = undefined;
    var sig_bytes: [64]u8 = undefined;
    _ = std.fmt.hexToBytes(&pk_bytes, ph) catch return 0;
    _ = std.fmt.hexToBytes(&sig_bytes, sh) catch return 0;
    const Ed25519 = std.crypto.sign.Ed25519;
    const pk = Ed25519.PublicKey.fromBytes(pk_bytes) catch return 0;
    const sig = Ed25519.Signature.fromBytes(sig_bytes);
    sig.verify(mm, pk) catch return 0;
    return 1;
}

/// Açık anahtarın parmak izi: SHA-256(ham 32 bayt) ilk 16 baytının hex'i (32 karakter) — `noxc sign`un `fingerprint`iyle aynı. Geçersiz girdi: boş dize.
export fn nox_ed25519_fingerprint_raw(rt: ?*anyopaque, pub_hex: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const ph = str_mod.nox_str_slice(pub_hex orelse return dupeToNoxStr(rt, ""));
    if (ph.len != 64) return dupeToNoxStr(rt, "");
    var pk_bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&pk_bytes, ph) catch return dupeToNoxStr(rt, "");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&pk_bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest[0..16].*, .lower);
    return dupeToNoxStr(rt, &hex);
}

test "nox_ed25519_verify_raw: geçerli imza 1, bozuk/yanlış girdi 0; parmak izi noxc sign ile aynı" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    const Ed25519 = std.crypto.sign.Ed25519;
    const kp = try Ed25519.KeyPair.generateDeterministic([_]u8{7} ** 32);
    const msg_text = "nox-attest-v1\nhello";
    const sig = try kp.sign(msg_text, null);
    const pk_hex = std.fmt.bytesToHex(kp.public_key.toBytes(), .lower);
    const sig_hex = std.fmt.bytesToHex(sig.toBytes(), .lower);

    const pkp = makeTestStr(rt, &pk_hex);
    defer str.nox_str_release(rt, pkp);
    const sgp = makeTestStr(rt, &sig_hex);
    defer str.nox_str_release(rt, sgp);
    const mp = makeTestStr(rt, msg_text);
    defer str.nox_str_release(rt, mp);
    try std.testing.expectEqual(@as(i32, 1), nox_ed25519_verify_raw(pkp, mp, sgp));

    const other = makeTestStr(rt, "nox-attest-v1\nHELLO");
    defer str.nox_str_release(rt, other);
    try std.testing.expectEqual(@as(i32, 0), nox_ed25519_verify_raw(pkp, other, sgp));
    var bad = sig_hex;
    bad[3] = if (bad[3] == '0') '1' else '0';
    const bad_s = makeTestStr(rt, &bad);
    defer str.nox_str_release(rt, bad_s);
    try std.testing.expectEqual(@as(i32, 0), nox_ed25519_verify_raw(pkp, mp, bad_s));
    var nonhex = pk_hex;
    nonhex[5] = 'z';
    const nh = makeTestStr(rt, &nonhex);
    defer str.nox_str_release(rt, nh);
    try std.testing.expectEqual(@as(i32, 0), nox_ed25519_verify_raw(nh, mp, sgp));
    try std.testing.expectEqual(@as(i32, 0), nox_ed25519_verify_raw(null, mp, sgp));
    try std.testing.expectEqual(@as(i32, 0), nox_ed25519_verify_raw(pkp, mp, pkp));
    const fp = nox_ed25519_fingerprint_raw(rt, pkp) orelse return error.NoFingerprint;
    defer str.nox_str_release(rt, fp);
    try std.testing.expectEqual(@as(usize, 32), str.nox_str_slice(fp).len);
}

/// `secure_random_hex(n_bytes)` — `nox.random`nin (BİLİNÇLİ OLARAK
/// kriptografik güvenlik iddiası TAŞIMAYAN, tahmin edilebilir zaman-
/// tabanlı OTOMATİK tohumlu Xoshiro256) YERİNE, oturum belirteci/CSRF
/// token/API anahtarı gibi GÜVENLİK-İLGİLİ rastgelelik İçin `nox.dict`nin
/// hash tohumuyla (bkz. §3.70'in M-3'ü) AYNI `std.c.arc4random_buf`
/// (macOS'un OS-düzeyi GÜVENLİ rastgelelik kaynağı) kullanılır. `n_bytes`,
/// makul bir üst sınırla (256 bayt — GERÇEKÇİ HERHANGİ bir token/anahtar
/// büyüklüğünün ÇOK ÜSTÜNDE) KIRPILIR — sabit boyutlu bir yığın arabelleği
/// KULLANMAK İçin bilinçli bir v1 basitleştirmesi (yeni bir hata türü/
/// `raise` yolu GEREKTİRMEZ).
export fn nox_crypto_secure_random_hex_raw(rt: ?*anyopaque, n_bytes: i64) callconv(.c) ?[*:0]u8 {
    if (comptime bare_kernel) return dupeToNoxStr(rt, "");
    if (n_bytes <= 0) return dupeToNoxStr(rt, "");
    const max_bytes = 256;
    const n: usize = @min(@as(usize, @intCast(n_bytes)), max_bytes);

    var buf: [max_bytes]u8 = undefined;
    secureRandomBuf(buf[0..n]);

    var hex_buf: [max_bytes * 2]u8 = undefined;
    for (buf[0..n], 0..) |byte, i| {
        hex_buf[i * 2] = hex_chars[byte >> 4];
        hex_buf[i * 2 + 1] = hex_chars[byte & 0xF];
    }
    return dupeToNoxStr(rt, hex_buf[0 .. n * 2]);
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
// `nox_crypto_*_raw` (DIŞA açılan C-ABI sarmalayıcıları) `str_mod.nox_str_
// slice`i ÇAĞIRIYOR — GEÇERLİ bir Nox `str` başlığı (ARC+STR_HEADER) BEKLER.
// Çıplak Zig string LİTERALLERİNİ DOĞRUDAN bu fonksiyonlara geçirmek
// `regex.zig`nin AYNI belge notunda UYARDIĞI tuzak — bu yüzden AŞAĞIDAKİ
// TÜM testler `makeTestStr` İLE GERÇEK başlıklı `str`ler İNŞA EDER.
fn makeTestStr(rt: ?*anyopaque, bytes: []const u8) [*:0]u8 {
    return str_mod.nox_str_from_bytes(rt, bytes) orelse unreachable;
}

test "nox_crypto_sha256_hex_raw bilinen vektörler" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const empty_in = makeTestStr(rt, "");
    defer str.nox_str_release(rt, empty_in);
    const empty = nox_crypto_sha256_hex_raw(rt, empty_in) orelse return error.Failed;
    defer str.nox_str_release(rt, empty);
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        std.mem.sliceTo(empty, 0),
    );

    const abc_in = makeTestStr(rt, "abc");
    defer str.nox_str_release(rt, abc_in);
    const abc = nox_crypto_sha256_hex_raw(rt, abc_in) orelse return error.Failed;
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
        const input_str = makeTestStr(rt, input);
        defer str.nox_str_release(rt, input_str);
        const h = nox_crypto_sha256_hex_raw(rt, input_str) orelse return error.Failed;
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

    const same_input = makeTestStr(rt, "same input");
    defer str.nox_str_release(rt, same_input);
    const h1 = nox_crypto_sha256_hex_raw(rt, same_input) orelse return error.Failed;
    defer str.nox_str_release(rt, h1);
    const h2 = nox_crypto_sha256_hex_raw(rt, same_input) orelse return error.Failed;
    defer str.nox_str_release(rt, h2);
    try std.testing.expectEqualStrings(std.mem.sliceTo(h1, 0), std.mem.sliceTo(h2, 0));

    const different_input = makeTestStr(rt, "different input");
    defer str.nox_str_release(rt, different_input);
    const h3 = nox_crypto_sha256_hex_raw(rt, different_input) orelse return error.Failed;
    defer str.nox_str_release(rt, h3);
    try std.testing.expect(!std.mem.eql(u8, std.mem.sliceTo(h1, 0), std.mem.sliceTo(h3, 0)));
}

test "Faz III.9: nox_crypto_sha1_hex_raw bilinen vektörler" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const empty_in = makeTestStr(rt, "");
    defer str.nox_str_release(rt, empty_in);
    const empty = nox_crypto_sha1_hex_raw(rt, empty_in) orelse return error.Failed;
    defer str.nox_str_release(rt, empty);
    try std.testing.expectEqualStrings(
        "da39a3ee5e6b4b0d3255bfef95601890afd80709",
        std.mem.sliceTo(empty, 0),
    );

    const abc_in = makeTestStr(rt, "abc");
    defer str.nox_str_release(rt, abc_in);
    const abc = nox_crypto_sha1_hex_raw(rt, abc_in) orelse return error.Failed;
    defer str.nox_str_release(rt, abc);
    try std.testing.expectEqualStrings(
        "a9993e364706816aba3e25717850c26c9cd0d89d",
        std.mem.sliceTo(abc, 0),
    );
}

test "Faz III.9: nox_crypto_sha512_hex_raw bilinen vektörler" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const empty_in = makeTestStr(rt, "");
    defer str.nox_str_release(rt, empty_in);
    const empty = nox_crypto_sha512_hex_raw(rt, empty_in) orelse return error.Failed;
    defer str.nox_str_release(rt, empty);
    try std.testing.expectEqualStrings(
        "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e",
        std.mem.sliceTo(empty, 0),
    );

    const abc_in = makeTestStr(rt, "abc");
    defer str.nox_str_release(rt, abc_in);
    const abc = nox_crypto_sha512_hex_raw(rt, abc_in) orelse return error.Failed;
    defer str.nox_str_release(rt, abc);
    try std.testing.expectEqualStrings(
        "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
        std.mem.sliceTo(abc, 0),
    );
}

test "Faz III.9: nox_crypto_sha1_hex_raw/sha512_hex_raw hep dogru sabit uzunlukta kucuk harf hex doner" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const inputs = [_][]const u8{ "x", "hello world", "a much longer input string used to check chunking" };
    for (inputs) |input| {
        const input_str = makeTestStr(rt, input);
        defer str.nox_str_release(rt, input_str);

        const h1 = nox_crypto_sha1_hex_raw(rt, input_str) orelse return error.Failed;
        defer str.nox_str_release(rt, h1);
        const s1 = std.mem.sliceTo(h1, 0);
        try std.testing.expectEqual(@as(usize, 40), s1.len);
        for (s1) |c| try std.testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));

        const h5 = nox_crypto_sha512_hex_raw(rt, input_str) orelse return error.Failed;
        defer str.nox_str_release(rt, h5);
        const s5 = std.mem.sliceTo(h5, 0);
        try std.testing.expectEqual(@as(usize, 128), s5.len);
        for (s5) |c| try std.testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
    }
}

// Güvenlik bulguları M-4/M-5/M-6 (bkz. güvenlik raporu, 20 Temmuz 2026).

test "Faz KK.6: nox_crypto_hmac_sha256_hex_raw bilinen test vektörü (RFC 4231/2202 'Jefe')" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const key_in = makeTestStr(rt, "Jefe");
    defer str.nox_str_release(rt, key_in);
    const data_in = makeTestStr(rt, "what do ya want for nothing?");
    defer str.nox_str_release(rt, data_in);
    const mac = nox_crypto_hmac_sha256_hex_raw(rt, key_in, data_in) orelse return error.Failed;
    defer str.nox_str_release(rt, mac);
    try std.testing.expectEqualStrings(
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
        std.mem.sliceTo(mac, 0),
    );
}

test "Faz KK.6: nox_crypto_hmac_sha256_hex_raw farklı anahtar farklı MAC üretir (mesaj AYNI kalsa BİLE)" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const key1 = makeTestStr(rt, "anahtar1");
    defer str.nox_str_release(rt, key1);
    const key2 = makeTestStr(rt, "anahtar2");
    defer str.nox_str_release(rt, key2);
    const msg = makeTestStr(rt, "ayni mesaj");
    defer str.nox_str_release(rt, msg);
    const mac1 = nox_crypto_hmac_sha256_hex_raw(rt, key1, msg) orelse return error.Failed;
    defer str.nox_str_release(rt, mac1);
    const mac2 = nox_crypto_hmac_sha256_hex_raw(rt, key2, msg) orelse return error.Failed;
    defer str.nox_str_release(rt, mac2);
    try std.testing.expect(!std.mem.eql(u8, std.mem.sliceTo(mac1, 0), std.mem.sliceTo(mac2, 0)));
}

test "Faz KK.6: nox_crypto_constant_time_eq_raw eşit/farklı/farklı-uzunluk dizeleri doğru ayırt eder" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const secret_token = makeTestStr(rt, "gizli-belirtec");
    defer str.nox_str_release(rt, secret_token);
    const secret_token_diff_case = makeTestStr(rt, "gizli-belirteC");
    defer str.nox_str_release(rt, secret_token_diff_case);
    const short_s = makeTestStr(rt, "kisa");
    defer str.nox_str_release(rt, short_s);
    const long_s = makeTestStr(rt, "cokdahauzunbirdize");
    defer str.nox_str_release(rt, long_s);
    const empty = makeTestStr(rt, "");
    defer str.nox_str_release(rt, empty);

    try std.testing.expectEqual(@as(i32, 1), nox_crypto_constant_time_eq_raw(secret_token, secret_token));
    try std.testing.expectEqual(@as(i32, 0), nox_crypto_constant_time_eq_raw(secret_token, secret_token_diff_case));
    try std.testing.expectEqual(@as(i32, 0), nox_crypto_constant_time_eq_raw(short_s, long_s));
    try std.testing.expectEqual(@as(i32, 1), nox_crypto_constant_time_eq_raw(empty, empty));
}

test "Faz KK.6: nox_crypto_secure_random_hex_raw doğru uzunlukta hex döner VE deterministik DEĞİLDİR" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const t1 = nox_crypto_secure_random_hex_raw(rt, 16) orelse return error.Failed;
    defer str.nox_str_release(rt, t1);
    const s1 = std.mem.sliceTo(t1, 0);
    try std.testing.expectEqual(@as(usize, 32), s1.len);
    for (s1) |c| try std.testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));

    const t2 = nox_crypto_secure_random_hex_raw(rt, 16) orelse return error.Failed;
    defer str.nox_str_release(rt, t2);
    // ~2^-128 olasilikla yanlis-pozitif — pratikte GUVENILIR bir "farkli"
    // kontrolu (GERCEK rastgeleligin, sabit bir SIFIR tohumun DEGIL,
    // KULLANILDIGININ kaniti).
    try std.testing.expect(!std.mem.eql(u8, s1, std.mem.sliceTo(t2, 0)));

    const empty = nox_crypto_secure_random_hex_raw(rt, 0) orelse return error.Failed;
    defer str.nox_str_release(rt, empty);
    try std.testing.expectEqual(@as(usize, 0), std.mem.sliceTo(empty, 0).len);
}

test "argon2_hash/verify: dogru parola dogrulanir, yanlis parola reddedilir" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const correct_pw = makeTestStr(rt, "doğru parola");
    defer str.nox_str_release(rt, correct_pw);
    const wrong_pw = makeTestStr(rt, "yanlış parola");
    defer str.nox_str_release(rt, wrong_pw);

    const hash = nox_crypto_argon2_hash_raw(rt, correct_pw) orelse return error.Failed;
    defer str.nox_str_release(rt, hash);
    try std.testing.expect(std.mem.startsWith(u8, std.mem.sliceTo(hash, 0), "$argon2id$"));

    try std.testing.expectEqual(@as(i32, 1), nox_crypto_argon2_verify_raw(hash, correct_pw));
    try std.testing.expectEqual(@as(i32, 0), nox_crypto_argon2_verify_raw(hash, wrong_pw));
}

test "bcrypt_hash/verify: dogru parola dogrulanir, yanlis parola reddedilir" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const correct_pw = makeTestStr(rt, "doğru parola");
    defer str.nox_str_release(rt, correct_pw);
    const wrong_pw = makeTestStr(rt, "yanlış parola");
    defer str.nox_str_release(rt, wrong_pw);

    const hash = nox_crypto_bcrypt_hash_raw(rt, correct_pw) orelse return error.Failed;
    defer str.nox_str_release(rt, hash);
    try std.testing.expect(std.mem.startsWith(u8, std.mem.sliceTo(hash, 0), "$2"));

    try std.testing.expectEqual(@as(i32, 1), nox_crypto_bcrypt_verify_raw(hash, correct_pw));
    try std.testing.expectEqual(@as(i32, 0), nox_crypto_bcrypt_verify_raw(hash, wrong_pw));
}

test "scrypt_hash/verify: dogru parola dogrulanir, yanlis parola reddedilir" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const correct_pw = makeTestStr(rt, "doğru parola");
    defer str.nox_str_release(rt, correct_pw);
    const wrong_pw = makeTestStr(rt, "yanlış parola");
    defer str.nox_str_release(rt, wrong_pw);

    const hash = nox_crypto_scrypt_hash_raw(rt, correct_pw) orelse return error.Failed;
    defer str.nox_str_release(rt, hash);
    try std.testing.expect(std.mem.startsWith(u8, std.mem.sliceTo(hash, 0), "$scrypt$"));

    try std.testing.expectEqual(@as(i32, 1), nox_crypto_scrypt_verify_raw(hash, correct_pw));
    try std.testing.expectEqual(@as(i32, 0), nox_crypto_scrypt_verify_raw(hash, wrong_pw));
}

test "parola hash'leri her cagrida farkli tuz uretir (deterministik DEGIL)" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const same_pw = makeTestStr(rt, "ayni parola");
    defer str.nox_str_release(rt, same_pw);
    const h1 = nox_crypto_argon2_hash_raw(rt, same_pw) orelse return error.Failed;
    defer str.nox_str_release(rt, h1);
    const h2 = nox_crypto_argon2_hash_raw(rt, same_pw) orelse return error.Failed;
    defer str.nox_str_release(rt, h2);
    try std.testing.expect(!std.mem.eql(u8, std.mem.sliceTo(h1, 0), std.mem.sliceTo(h2, 0)));
    // İKİSİ de AYNI parolayı doğrulamalı — farklı tuz, AYNI sonuç.
    try std.testing.expectEqual(@as(i32, 1), nox_crypto_argon2_verify_raw(h1, same_pw));
    try std.testing.expectEqual(@as(i32, 1), nox_crypto_argon2_verify_raw(h2, same_pw));
}

test "bozuk/capraz-algoritma hash dizeleri cokme yerine guvenle reddedilir" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const invalid_str = makeTestStr(rt, "gecersiz-bir-dize");
    defer str.nox_str_release(rt, invalid_str);
    const pw = makeTestStr(rt, "parola");
    defer str.nox_str_release(rt, pw);
    const empty = makeTestStr(rt, "");
    defer str.nox_str_release(rt, empty);

    try std.testing.expectEqual(@as(i32, 0), nox_crypto_argon2_verify_raw(invalid_str, pw));
    try std.testing.expectEqual(@as(i32, 0), nox_crypto_bcrypt_verify_raw(invalid_str, pw));
    try std.testing.expectEqual(@as(i32, 0), nox_crypto_scrypt_verify_raw(invalid_str, pw));
    try std.testing.expectEqual(@as(i32, 0), nox_crypto_argon2_verify_raw(empty, empty));
}

test "v2.1.70: md5/sha384/sha3/blake3 bilinen vektörler" {
    const asap = @import("../alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    const abc = str_mod.nox_str_from_bytes(rt, "abc") orelse return error.Failed;
    defer str_mod.nox_str_release(rt, abc);
    const cases = [_]struct { f: *const fn (?*anyopaque, ?[*:0]const u8) callconv(.c) ?[*:0]u8, want: []const u8 }{
        .{ .f = nox_crypto_md5_hex_raw, .want = "900150983cd24fb0d6963f7d28e17f72" },
        .{ .f = nox_crypto_sha384_hex_raw, .want = "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7" },
        .{ .f = nox_crypto_sha3_256_hex_raw, .want = "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532" },
        .{ .f = nox_crypto_sha3_512_hex_raw, .want = "b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e10e116e9192af3c91a7ec57647e3934057340b4cf408d5a56592f8274eec53f0" },
        .{ .f = nox_crypto_blake3_hex_raw, .want = "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85" },
    };
    for (cases) |c| {
        const h = c.f(rt, abc) orelse return error.Failed;
        defer str_mod.nox_str_release(rt, h);
        try std.testing.expectEqualStrings(c.want, str_mod.nox_str_slice(h));
    }
}

test "nox_crypto_aead_raw: ChaCha20-Poly1305 RFC 8439 §2.8.2 vektörü + bozuk etiket reddi" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    const key = str.nox_str_from_bytes(rt, "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f") orelse return error.Failed;
    defer str.nox_str_release(rt, key);
    const nonce = str.nox_str_from_bytes(rt, "070000004041424344454647") orelse return error.Failed;
    defer str.nox_str_release(rt, nonce);
    const aad = str.nox_str_from_bytes(rt, "\x50\x51\x52\x53\xc0\xc1\xc2\xc3\xc4\xc5\xc6\xc7") orelse return error.Failed;
    defer str.nox_str_release(rt, aad);
    const msg = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
    const plain = str.nox_str_from_bytes(rt, msg) orelse return error.Failed;
    defer str.nox_str_release(rt, plain);
    const sealed = nox_crypto_aead_raw(rt, 1, 0, key, nonce, plain, aad) orelse return error.Failed;
    defer str.nox_str_release(rt, sealed);
    try std.testing.expectEqual(@as(i64, 0), nox_crypto_aead_status_raw());
    const sealed_s = std.mem.span(sealed);
    try std.testing.expect(std.mem.startsWith(u8, sealed_s, "d31a8d34648e60db7b86afbc53ef7ec2"));
    try std.testing.expect(std.mem.endsWith(u8, sealed_s, "1ae10b594f09e26a7e902ecbd0600691")); // RFC 8439 etiketi
    const opened = nox_crypto_aead_raw(rt, 0, 0, key, nonce, sealed, aad) orelse return error.Failed;
    defer str.nox_str_release(rt, opened);
    try std.testing.expectEqual(@as(i64, 0), nox_crypto_aead_status_raw());
    try std.testing.expectEqualStrings(msg, std.mem.span(opened));
    // bir bit bozulursa kimlik doğrulama başarısız
    var tampered: [400]u8 = undefined;
    @memcpy(tampered[0..sealed_s.len], sealed_s);
    tampered[0] = if (tampered[0] == '0') '1' else '0';
    const bad = str.nox_str_from_bytes(rt, tampered[0..sealed_s.len]) orelse return error.Failed;
    defer str.nox_str_release(rt, bad);
    const rejected = nox_crypto_aead_raw(rt, 0, 0, key, nonce, bad, aad) orelse return error.Failed;
    defer str.nox_str_release(rt, rejected);
    try std.testing.expectEqual(@as(i64, 5), nox_crypto_aead_status_raw());
}

test "nox_crypto_aead_raw: AES-256-GCM McGrew-Viega test case 16 (AAD'li, 60 baytlık düz metin)" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    var plain_bytes: [60]u8 = undefined;
    _ = try std.fmt.hexToBytes(&plain_bytes, "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39");
    var aad_bytes: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&aad_bytes, "feedfacedeadbeeffeedfacedeadbeefabaddad2");
    const key = str.nox_str_from_bytes(rt, "feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308") orelse return error.Failed;
    defer str.nox_str_release(rt, key);
    const nonce = str.nox_str_from_bytes(rt, "cafebabefacedbaddecaf888") orelse return error.Failed;
    defer str.nox_str_release(rt, nonce);
    const plain = str.nox_str_from_bytes(rt, &plain_bytes) orelse return error.Failed;
    defer str.nox_str_release(rt, plain);
    const aad = str.nox_str_from_bytes(rt, &aad_bytes) orelse return error.Failed;
    defer str.nox_str_release(rt, aad);
    const sealed = nox_crypto_aead_raw(rt, 1, 1, key, nonce, plain, aad) orelse return error.Failed;
    defer str.nox_str_release(rt, sealed);
    try std.testing.expectEqual(@as(i64, 0), nox_crypto_aead_status_raw());
    try std.testing.expectEqualStrings("522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f66276fc6ece0f4e1768cddf8853bb2d551b", std.mem.span(sealed));
}
