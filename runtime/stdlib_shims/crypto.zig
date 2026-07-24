//! `nox.crypto` Zig kabuğu — stdlib fazı V.3 (bkz. nox-teknik-spesifikasyon.md).
//!
//! Kapsam bilinçli olarak DAR: yalnızca SHA-256 (Zig'in KENDİ, savaş-test
//! edilmiş `std.crypto.hash.sha2.Sha256`si — sıfırdan bir hash algoritması
//! YAZILMAZ, `nox.json`nin `std.json.parseFromSlice`i KULLANMA kararıyla
//! AYNI ilke). Sonuç, ARC'lı bir `str`e (KÜÇÜK harf hex, 64 karakter)
//! ÇEVRİLİP döner — `with_rt` GEREKİR (bkz. `http_client.zig`nin
//! `dupeToNoxStr`ı, AYNI ARC-str üretim deseni).
const std = @import("std");
const builtin = @import("builtin");
const http_client = @import("http_client.zig");

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
    const p = password orelse return dupeToNoxStr(rt, "");
    var buf: [pwhash_buf_len]u8 = undefined;
    const hash = pwhash.argon2.strHash(std.mem.span(p), .{
        .allocator = std.heap.page_allocator,
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
    const h = hash orelse return 0;
    const p = password orelse return 0;
    pwhash.argon2.strVerify(std.mem.span(h), std.mem.span(p), .{
        .allocator = std.heap.page_allocator,
    }, sharedIo()) catch return 0;
    return 1;
}

export fn nox_crypto_bcrypt_hash_raw(rt: ?*anyopaque, password: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const p = password orelse return dupeToNoxStr(rt, "");
    var buf: [pwhash_buf_len]u8 = undefined;
    const hash = pwhash.bcrypt.strHash(std.mem.span(p), .{
        .params = pwhash.bcrypt.Params.owasp,
        .encoding = .crypt,
    }, &buf, sharedIo()) catch return dupeToNoxStr(rt, "");
    return dupeToNoxStr(rt, hash);
}

export fn nox_crypto_bcrypt_verify_raw(hash: ?[*:0]const u8, password: ?[*:0]const u8) callconv(.c) i32 {
    const h = hash orelse return 0;
    const p = password orelse return 0;
    pwhash.bcrypt.strVerify(std.mem.span(h), std.mem.span(p), .{
        .silently_truncate_password = false,
    }) catch return 0;
    return 1;
}

export fn nox_crypto_scrypt_hash_raw(rt: ?*anyopaque, password: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const p = password orelse return dupeToNoxStr(rt, "");
    var buf: [pwhash_buf_len]u8 = undefined;
    const hash = pwhash.scrypt.strHash(std.mem.span(p), .{
        .allocator = std.heap.page_allocator,
        .params = pwhash.scrypt.Params.owasp,
        .encoding = .phc,
    }, &buf, sharedIo()) catch return dupeToNoxStr(rt, "");
    return dupeToNoxStr(rt, hash);
}

export fn nox_crypto_scrypt_verify_raw(hash: ?[*:0]const u8, password: ?[*:0]const u8) callconv(.c) i32 {
    const h = hash orelse return 0;
    const p = password orelse return 0;
    pwhash.scrypt.strVerify(std.mem.span(h), std.mem.span(p), .{
        .allocator = std.heap.page_allocator,
    }) catch return 0;
    return 1;
}

/// Faz LL.4 (bkz. nox-teknik-spesifikasyon.md §3.71): `std.c.arc4random_buf`
/// Windows'ta void'dir (bkz. `runtime/collections/dict.zig`nin AYNI
/// düzeltmesi) — `advapi32.dll`nin `RtlGenRandom`i (`SystemFunction036`)
/// YERİNE kullanılır.
fn secureRandomBuf(buf: []u8) void {
    if (builtin.os.tag == .windows) {
        _ = SystemFunction036(buf.ptr, @intCast(buf.len));
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}
extern "advapi32" fn SystemFunction036(buf: [*]u8, len: u32) callconv(.c) u8;

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

/// Faz III.9 (bkz. nox-teknik-spesifikasyon.md §3.69) — `sha256_hex_raw`
/// İLE BİREBİR AYNI desen, YALNIZCA Zig'in `std.crypto.hash.Sha1`i
/// kullanır (20 baytlık özet, 40 karakterlik hex).
export fn nox_crypto_sha1_hex_raw(rt: ?*anyopaque, data: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const d = data orelse return dupeToNoxStr(rt, "");
    const span = std.mem.span(d);

    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(span, &digest, .{});

    var hex_buf: [digest.len * 2]u8 = undefined;
    for (digest, 0..) |byte, i| {
        hex_buf[i * 2] = hex_chars[byte >> 4];
        hex_buf[i * 2 + 1] = hex_chars[byte & 0xF];
    }
    return dupeToNoxStr(rt, &hex_buf);
}

/// Faz III.9 — `sha256_hex_raw` İLE BİREBİR AYNI desen, `std.crypto.hash.
/// sha2.Sha512` (64 baytlık özet, 128 karakterlik hex).
export fn nox_crypto_sha512_hex_raw(rt: ?*anyopaque, data: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const d = data orelse return dupeToNoxStr(rt, "");
    const span = std.mem.span(d);

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
    const key_span = std.mem.span(k);
    const data_span = std.mem.span(d);

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
    const a_span = std.mem.span(av);
    const b_span = std.mem.span(bv);
    if (a_span.len != b_span.len) return 0;
    var diff: u8 = 0;
    for (a_span, 0..) |byte, i| {
        diff |= byte ^ b_span[i];
    }
    return if (diff == 0) 1 else 0;
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

test "Faz III.9: nox_crypto_sha1_hex_raw bilinen vektörler" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const empty = nox_crypto_sha1_hex_raw(rt, "") orelse return error.Failed;
    defer str.nox_str_release(rt, empty);
    try std.testing.expectEqualStrings(
        "da39a3ee5e6b4b0d3255bfef95601890afd80709",
        std.mem.sliceTo(empty, 0),
    );

    const abc = nox_crypto_sha1_hex_raw(rt, "abc") orelse return error.Failed;
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

    const empty = nox_crypto_sha512_hex_raw(rt, "") orelse return error.Failed;
    defer str.nox_str_release(rt, empty);
    try std.testing.expectEqualStrings(
        "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e",
        std.mem.sliceTo(empty, 0),
    );

    const abc = nox_crypto_sha512_hex_raw(rt, "abc") orelse return error.Failed;
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
        const h1 = nox_crypto_sha1_hex_raw(rt, @ptrCast(input.ptr)) orelse return error.Failed;
        defer str.nox_str_release(rt, h1);
        const s1 = std.mem.sliceTo(h1, 0);
        try std.testing.expectEqual(@as(usize, 40), s1.len);
        for (s1) |c| try std.testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));

        const h5 = nox_crypto_sha512_hex_raw(rt, @ptrCast(input.ptr)) orelse return error.Failed;
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

    const mac = nox_crypto_hmac_sha256_hex_raw(rt, "Jefe", "what do ya want for nothing?") orelse return error.Failed;
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

    const mac1 = nox_crypto_hmac_sha256_hex_raw(rt, "anahtar1", "ayni mesaj") orelse return error.Failed;
    defer str.nox_str_release(rt, mac1);
    const mac2 = nox_crypto_hmac_sha256_hex_raw(rt, "anahtar2", "ayni mesaj") orelse return error.Failed;
    defer str.nox_str_release(rt, mac2);
    try std.testing.expect(!std.mem.eql(u8, std.mem.sliceTo(mac1, 0), std.mem.sliceTo(mac2, 0)));
}

test "Faz KK.6: nox_crypto_constant_time_eq_raw eşit/farklı/farklı-uzunluk dizeleri doğru ayırt eder" {
    try std.testing.expectEqual(@as(i32, 1), nox_crypto_constant_time_eq_raw("gizli-belirtec", "gizli-belirtec"));
    try std.testing.expectEqual(@as(i32, 0), nox_crypto_constant_time_eq_raw("gizli-belirtec", "gizli-belirteC"));
    try std.testing.expectEqual(@as(i32, 0), nox_crypto_constant_time_eq_raw("kisa", "cokdahauzunbirdize"));
    try std.testing.expectEqual(@as(i32, 1), nox_crypto_constant_time_eq_raw("", ""));
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

    const hash = nox_crypto_argon2_hash_raw(rt, "doğru parola") orelse return error.Failed;
    defer str.nox_str_release(rt, hash);
    try std.testing.expect(std.mem.startsWith(u8, std.mem.sliceTo(hash, 0), "$argon2id$"));

    try std.testing.expectEqual(@as(i32, 1), nox_crypto_argon2_verify_raw(hash, "doğru parola"));
    try std.testing.expectEqual(@as(i32, 0), nox_crypto_argon2_verify_raw(hash, "yanlış parola"));
}

test "bcrypt_hash/verify: dogru parola dogrulanir, yanlis parola reddedilir" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const hash = nox_crypto_bcrypt_hash_raw(rt, "doğru parola") orelse return error.Failed;
    defer str.nox_str_release(rt, hash);
    try std.testing.expect(std.mem.startsWith(u8, std.mem.sliceTo(hash, 0), "$2"));

    try std.testing.expectEqual(@as(i32, 1), nox_crypto_bcrypt_verify_raw(hash, "doğru parola"));
    try std.testing.expectEqual(@as(i32, 0), nox_crypto_bcrypt_verify_raw(hash, "yanlış parola"));
}

test "scrypt_hash/verify: dogru parola dogrulanir, yanlis parola reddedilir" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const hash = nox_crypto_scrypt_hash_raw(rt, "doğru parola") orelse return error.Failed;
    defer str.nox_str_release(rt, hash);
    try std.testing.expect(std.mem.startsWith(u8, std.mem.sliceTo(hash, 0), "$scrypt$"));

    try std.testing.expectEqual(@as(i32, 1), nox_crypto_scrypt_verify_raw(hash, "doğru parola"));
    try std.testing.expectEqual(@as(i32, 0), nox_crypto_scrypt_verify_raw(hash, "yanlış parola"));
}

test "parola hash'leri her cagrida farkli tuz uretir (deterministik DEGIL)" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const h1 = nox_crypto_argon2_hash_raw(rt, "ayni parola") orelse return error.Failed;
    defer str.nox_str_release(rt, h1);
    const h2 = nox_crypto_argon2_hash_raw(rt, "ayni parola") orelse return error.Failed;
    defer str.nox_str_release(rt, h2);
    try std.testing.expect(!std.mem.eql(u8, std.mem.sliceTo(h1, 0), std.mem.sliceTo(h2, 0)));
    // İKİSİ de AYNI parolayı doğrulamalı — farklı tuz, AYNI sonuç.
    try std.testing.expectEqual(@as(i32, 1), nox_crypto_argon2_verify_raw(h1, "ayni parola"));
    try std.testing.expectEqual(@as(i32, 1), nox_crypto_argon2_verify_raw(h2, "ayni parola"));
}

test "bozuk/capraz-algoritma hash dizeleri cokme yerine guvenle reddedilir" {
    try std.testing.expectEqual(@as(i32, 0), nox_crypto_argon2_verify_raw("gecersiz-bir-dize", "parola"));
    try std.testing.expectEqual(@as(i32, 0), nox_crypto_bcrypt_verify_raw("gecersiz-bir-dize", "parola"));
    try std.testing.expectEqual(@as(i32, 0), nox_crypto_scrypt_verify_raw("gecersiz-bir-dize", "parola"));
    try std.testing.expectEqual(@as(i32, 0), nox_crypto_argon2_verify_raw("", ""));
}
