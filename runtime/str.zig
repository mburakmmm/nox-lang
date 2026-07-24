//! `str` için Alt-Faz B çalışma zamanı desteği — birleştirme (`+`) ve
//! ARC release (bkz. nox-teknik-spesifikasyon.md, stdlib fazı §B).
//!
//! `str` artık ARC-yönetimli bir heap tipidir (bkz. codegen_qbe/codegen.zig,
//! `isHeapManaged`) — ama `list[T]`/sınıflardan FARKLI olarak boyutunu
//! (uzunluğunu) görünmez başlıkta SAKLAMAZ: bir string literali ile
//! dinamik (birleştirilmiş) bir string'in AYNI temsili (sıfırla-sonlanan
//! bir C dizesi, hemen önünde 8 baytlık bir refcount) paylaşabilmesi İÇİN
//! bilinçli bir tasarım (bkz. `.string_lit`in codegen belge notu,
//! `PINNED_REFCOUNT` hilesi). Bu yüzden `nox_rc_release`in aksine
//! (`payload_size`i ÇAĞIRANDAN alır) burada release `strlen` ile boyutu
//! KENDİSİ hesaplar.

const std = @import("std");
const arc = @import("alloc/arc.zig");

/// `a`+`b`nin birleşimi olan YENİ, sıfırla-sonlanan bir dize tahsis eder
/// (refcount 1 ile başlar, `nox_rc_alloc` üzerinden — ARC havuzundan
/// faydalanır). `a`/`b` NE değiştirilir NE serbest bırakılır — çağıranın
/// (codegen'in `genBinary`i) kendi ARC kuralları operandların releaser'ını
/// AYRICA yönetir.
pub export fn nox_str_concat(rt: ?*anyopaque, a: ?[*:0]const u8, b: ?[*:0]const u8) ?[*:0]u8 {
    const pa = a orelse return null;
    const pb = b orelse return null;
    const len_a = std.mem.len(pa);
    const len_b = std.mem.len(pb);
    const total_len = len_a + len_b;

    const raw = arc.nox_rc_alloc(rt, total_len + 1) orelse return null;
    const bytes: [*]u8 = @ptrCast(raw);
    @memcpy(bytes[0..len_a], pa[0..len_a]);
    @memcpy(bytes[len_a..][0..len_b], pb[0..len_b]);
    bytes[total_len] = 0;
    return @ptrCast(bytes);
}

/// `ptr`nin refcount'unu bir azaltır; sıfıra/altına düşerse belleği
/// (`strlen(ptr)+1` baytlık payload — `nox_rc_alloc`a verilenle AYNI hesap)
/// gerçekten serbest bırakır. Pinned (literal) dizeler İÇİN predecrement
/// asla sıfıra düşmeyeceğinden bu HİÇBİR ZAMAN gerçekten serbest bırakmaz
/// (bkz. modül üstü not).
pub export fn nox_str_release(rt: ?*anyopaque, ptr: ?[*:0]u8) void {
    const p = ptr orelse return;
    if (arc.nox_rc_predecrement(p) != 0) {
        const len = std.mem.len(p);
        arc.nox_rc_free_payload(rt, p, len + 1);
    }
}

/// Faz GG.1 (bkz. nox-teknik-spesifikasyon.md — performans fazı): `nox_str_release`in
/// AYNISI, ama predecrement adımı ÇIKARILMIŞ — `codegen.zig`nin `releaseValueIfSet`i
/// ARTIK predecrement'i (`emitInlinePredecrement` İLE AYNI desen) DOĞRUDAN QBE IR'ına
/// inline ediyor (`nox_rc_retain`/`predecrement`in class/list İçin ZATEN yaptığı GİBİ) —
/// bu, HER `str` release'inde (pinned/literal dizeler DAHİL, ki HİÇBİR ZAMAN
/// gerçekten serbest bırakılmazlar) tam bir fonksiyon çağrısı maliyetini ORTADAN
/// KALDIRIR; yalnızca refcount GERÇEKTEN sıfıra/altına düştüğünde (NADİR yol) BU
/// fonksiyon çağrılır — `strlen` + gerçek serbest bırakma İÇİN. `ptr`nin KENDİSİ
/// null OLAMAZ (çağıran taraf, `releaseValueIfSet`in KENDİ null-kontrolü ZATEN
/// GEÇTİKTEN SONRA buraya gelir).
pub export fn nox_str_free_now(rt: ?*anyopaque, ptr: [*:0]u8) void {
    const len = std.mem.len(ptr);
    arc.nox_rc_free_payload(rt, ptr, len + 1);
}

test "nox_str_concat iki dizeyi doğru birleştirir, sıfırla sonlanır" {
    const asap = @import("alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const result = nox_str_concat(rt, "merhaba ", "dünya") orelse return error.ConcatFailed;
    defer nox_str_release(rt, result);
    try std.testing.expectEqualStrings("merhaba dünya", std.mem.sliceTo(result, 0));
}

/// Stdlib fazı §E: `str(x)`/`int(s)`/`float(s)` çekirdek dönüşüm
/// yerleşiklerinin çalışma zamanı desteği — `print`/`len` İLE AYNI, checker/
/// codegen'de ÖZEL işlenen (bkz. `checker.zig`nin `checkCall`ı,
/// `codegen.zig`nin `genCall`ı) yerleşikler, `extern def` DEĞİLLER.
///
/// `nox_int_to_str`/`nox_float_to_str` HER ZAMAN başarılıdır (bir `int`/
/// `float` değeri ASLA "geçersiz" olamaz) — ARC'lı YENİ bir `str` döner.
/// `nox_str_to_int`/`nox_str_to_float` İSE ayrıştırma BAŞARISIZ olabilir —
/// bu yüzden codegen ÖNCE karşılık gelen `nox_str_is_valid_*`yi çağırıp
/// (bir `ValueError` `raise` etmesi gerekip gerekmediğine karar vermek
/// için), YALNIZCA geçerliyse gerçek dönüşüm fonksiyonunu çağırır — bu iki
/// adımlı tasarım, dönüşümün KENDİSİNİN "başarı/hata" durumunu Zig
/// tarafında bir `out` parametresi/struct DÖNÜŞÜYLE taşımak YERİNE
/// (QBE çağrı ABI'sini KARMAŞIKLAŞTIRIRDI), TAMAMEN codegen'İN KENDİ
/// dallanma/`nox_raise` altyapısıyla (bkz. `genRaise`) çözülmesini sağlar.
pub export fn nox_int_to_str(rt: ?*anyopaque, n: i64) ?[*:0]u8 {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return null;
    const raw = arc.nox_rc_alloc(rt, s.len + 1) orelse return null;
    const bytes: [*]u8 = @ptrCast(raw);
    @memcpy(bytes[0..s.len], s);
    bytes[s.len] = 0;
    return @ptrCast(bytes);
}

pub export fn nox_float_to_str(rt: ?*anyopaque, f: f64) ?[*:0]u8 {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch return null;
    const raw = arc.nox_rc_alloc(rt, s.len + 1) orelse return null;
    const bytes: [*]u8 = @ptrCast(raw);
    @memcpy(bytes[0..s.len], s);
    bytes[s.len] = 0;
    return @ptrCast(bytes);
}

pub export fn nox_str_is_valid_int(s: ?[*:0]const u8) i32 {
    const p = s orelse return 0;
    _ = std.fmt.parseInt(i64, std.mem.span(p), 10) catch return 0;
    return 1;
}

pub export fn nox_str_to_int(s: ?[*:0]const u8) i64 {
    const p = s orelse return 0;
    return std.fmt.parseInt(i64, std.mem.span(p), 10) catch 0;
}

pub export fn nox_str_is_valid_float(s: ?[*:0]const u8) i32 {
    const p = s orelse return 0;
    _ = std.fmt.parseFloat(f64, std.mem.span(p)) catch return 0;
    return 1;
}

pub export fn nox_str_to_float(s: ?[*:0]const u8) f64 {
    const p = s orelse return 0;
    return std.fmt.parseFloat(f64, std.mem.span(p)) catch 0;
}

/// Stdlib fazı §G: `s[i]` string indekslemesinin çalışma zamanı desteği.
/// Sınır KONTROLÜ BURADA yapılMAZ — codegen'in `genIndex`i (QBE'de
/// `strlen`+karşılaştırma ile) `idx`nin GEÇERLİ olduğunu ÖNCEDEN doğrular
/// Bulundu (bkz. proje belleği "UTF-8 farkındalığı" görevi): `s[i]`
/// ÖNCEDEN HAM bir bayt okuyordu (`p[idx]`) — çok baytlı UTF-8 karakterler
/// (ör. "café"nin "é"si, 2 bayt) İÇİN YANLIŞ, bir dizinin ORTASINDAN
/// KESİP geçersiz/çöp bir bayt döndürüyordu (`"café"[3]`). ARTIK `idx`.
/// CODEPOINT'e (Unicode "karakter") KADAR `std.unicode.Utf8View` İLE
/// yürür — `runtime/hpy_bridge/context.zig`nin ZATEN kullandığı AYNI
/// `Utf8View`/iterator deseni. GEÇERSİZ UTF-8 baytlara (ör. `nox.fs`den
/// gelen Latin-1 dosya İçeriği) karşı GÜVENLİ bir geri düşüş: doğrulama
/// BAŞARISIZ olursa HAM bayt semantiğine (ÖNCEKİ davranış) düşülür —
/// `nox_str_char_count`ün AYNI geri düşüşüyle TUTARLI (`0 <= idx < len(s)`
/// değişmezi HER İKİ modda da geçerli kalır, ASLA çökmez).
///
/// (bkz. `genParseOrRaise`in AYNI "önce doğrula, sonra çağır" deseni,
/// stdlib fazı §E) — bu fonksiyon YALNIZCA GEÇERLİ bir `idx` İÇİN çağrılır.
/// TEK karakterlik YENİ bir ARC'lı `str` döner (temel dizeden BAĞIMSIZ bir
/// tahsis — `list`/`dict` indekslemesinin AKSİNE, temel dizenin İÇİNE
/// bir takma ad DEĞİLDİR, bu yüzden temel dize TEMPORARY olsa bile önce
/// retain etmeye GEREK YOKTUR).
pub export fn nox_str_char_at(rt: ?*anyopaque, s: ?[*:0]const u8, idx: i64) ?[*:0]u8 {
    const p = s orelse return null;
    if (idx < 0) return null;
    const bytes = std.mem.span(p);
    if (std.unicode.Utf8View.init(bytes)) |view| {
        var it = view.iterator();
        var i: i64 = 0;
        while (it.nextCodepointSlice()) |slice| {
            if (i == idx) {
                const raw = arc.nox_rc_alloc(rt, slice.len + 1) orelse return null;
                const out: [*]u8 = @ptrCast(raw);
                @memcpy(out[0..slice.len], slice);
                out[slice.len] = 0;
                return @ptrCast(out);
            }
            i += 1;
        }
        return null;
    } else |_| {
        if (@as(usize, @intCast(idx)) >= bytes.len) return null;
        const raw = arc.nox_rc_alloc(rt, 2) orelse return null;
        const out: [*]u8 = @ptrCast(raw);
        out[0] = bytes[@intCast(idx)];
        out[1] = 0;
        return @ptrCast(out);
    }
}

/// Bulundu (bkz. proje belleği "UTF-8 farkındalığı" görevi): `len(s)`
/// (bir `str` İçin, bkz. `codegen_qbe/calls.zig`nin `len` dalı) ÖNCEDEN
/// DOĞRUDAN `strlen`e inlineleniyordu — bayt sayısı, "café" İçin YANLIŞ
/// (5, BEKLENEN 4). `std.unicode.utf8CountCodepoints` (SIMD ASCII hızlı
/// yolu DAHİL) codepoint sayar. `rt` PARAMETRESİ YOK (tahsis YAPMAZ) —
/// `strlen`in TEK-argümanlı imzasıyla BİREBİR eşleşir, codegen'in 3 çağrı
/// sitesi (bkz. plan dosyası) SADECE fonksiyon adını değiştirir. Geçersiz
/// UTF-8'e karşı `nox_str_char_at`in AYNI güvenli geri düşüşü: HAM bayt
/// sayısına düşer, ASLA çökmez.
pub export fn nox_str_char_count(s: ?[*:0]const u8) i64 {
    const p = s orelse return 0;
    const bytes = std.mem.span(p);
    const count = std.unicode.utf8CountCodepoints(bytes) catch return @intCast(bytes.len);
    return @intCast(count);
}

/// Bulundu (bkz. proje belleği "UTF-8 farkındalığı" görevi, GERÇEK ölçüm:
/// `benchmarks/str_index_loop_licm.nox` ~30 saniyeye çıktı): `nox_str_
/// char_at`in ARTIK O(i) UTF-8 yürüyüşü olması, TAMAMEN ASCII dizelerde
/// (GERÇEK dünyada çoğu metin) GEREKSİZ bir yavaşlama — ASCII'de HER bayt
/// KENDİ codepoint'i olduğundan bayt-ofseti == codepoint-ofseti, O(1) HAM
/// erişim HÂLÂ DOĞRUDUR. `compiler/codegen_qbe/optimizations.zig`nin
/// `enterStrLenCacheScope`si BU fonksiyonu döngüye girmeden HEMEN ÖNCE BİR
/// KEZ çağırıp sonucu önbelleğe alır — `genStrIndex` (expr.zig) HER erişimde
/// bu önbellekten ÇALIŞMA-ZAMANI dallanır: ASCII İSE ESKİ O(1) yol İNLINE
/// edilir, DEĞİLSE `nox_str_char_at`e düşülür.
pub export fn nox_str_is_ascii(s: ?[*:0]const u8) i64 {
    const p = s orelse return 1;
    const bytes = std.mem.span(p);
    for (bytes) |b| {
        if (b >= 0x80) return 0;
    }
    return 1;
}

test "nox_str_char_at gecerli indekste dogru karakteri doner (ASCII)" {
    const asap = @import("alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const c0 = nox_str_char_at(rt, "hello", 0) orelse return error.ConvFailed;
    defer nox_str_release(rt, c0);
    try std.testing.expectEqualStrings("h", std.mem.sliceTo(c0, 0));

    const c4 = nox_str_char_at(rt, "hello", 4) orelse return error.ConvFailed;
    defer nox_str_release(rt, c4);
    try std.testing.expectEqualStrings("o", std.mem.sliceTo(c4, 0));
}

test "nox_str_char_at cok baytli UTF-8 karakteri BOLMEDEN dogru doner" {
    const asap = @import("alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    // "café" -- 'é' = 2 baytlik UTF-8 (0xC3 0xA9), toplam 5 bayt, 4 codepoint.
    const c3 = nox_str_char_at(rt, "café", 3) orelse return error.ConvFailed;
    defer nox_str_release(rt, c3);
    try std.testing.expectEqualStrings("é", std.mem.sliceTo(c3, 0));

    // "日本語" -- her biri 3 baytlik UTF-8, toplam 9 bayt, 3 codepoint.
    const c1 = nox_str_char_at(rt, "日本語", 1) orelse return error.ConvFailed;
    defer nox_str_release(rt, c1);
    try std.testing.expectEqualStrings("本", std.mem.sliceTo(c1, 0));
}

test "nox_str_char_count ASCII'de strlen ile ayni, cok baytli UTF-8'de codepoint sayar" {
    try std.testing.expectEqual(@as(i64, 5), nox_str_char_count("hello"));
    try std.testing.expectEqual(@as(i64, 4), nox_str_char_count("café"));
    try std.testing.expectEqual(@as(i64, 3), nox_str_char_count("日本語"));
    try std.testing.expectEqual(@as(i64, 0), nox_str_char_count(""));
}

test "nox_str_is_ascii ASCII dizelerde 1, cok baytli UTF-8 iceren dizelerde 0 doner" {
    try std.testing.expectEqual(@as(i64, 1), nox_str_is_ascii("hello"));
    try std.testing.expectEqual(@as(i64, 1), nox_str_is_ascii(""));
    try std.testing.expectEqual(@as(i64, 0), nox_str_is_ascii("café"));
    try std.testing.expectEqual(@as(i64, 0), nox_str_is_ascii("日本語"));
}

/// Faz EE.1 (bkz. nox-teknik-spesifikasyon.md §3.61) — `nox_str_char_at`
/// İLE AYNI "çağıran ÖNCEDEN sınırı doğruladı" sözleşmesi, ama HİÇBİR
/// TAHSİS YAPMAZ: ham bayt değerini doğrudan bir `int` olarak döner.
/// `s[i]`nin KENDİSİ (Python-tarzı "indeksleme bir `str` döner" semantiği,
/// `nox_str_char_at`) BİLEREK DEĞİŞTİRİLMEDİ — bu, YALNIZCA bayt-bayt
/// KARŞILAŞTIRMA amaçlı (ör. `nox.strings.starts_with`/`index_of`in İÇ
/// döngüleri) EK, alloc-sız bir ilkeldir; `nox.strings.byte_at` olarak
/// genel kullanıma da açılır (bkz. `stdlib/nox/strings.nox`).
pub export fn nox_str_byte_at(s: ?[*:0]const u8, idx: i64) i64 {
    const p = s orelse return 0;
    if (idx < 0) return 0;
    return p[@intCast(idx)];
}

test "nox_str_byte_at gecerli indekste dogru bayti tahsissiz doner" {
    try std.testing.expectEqual(@as(i64, 'h'), nox_str_byte_at("hello", 0));
    try std.testing.expectEqual(@as(i64, 'o'), nox_str_byte_at("hello", 4));
}

test "nox_int_to_str/nox_float_to_str dogru bicimlendirir" {
    const asap = @import("alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const s1 = nox_int_to_str(rt, 42) orelse return error.ConvFailed;
    defer nox_str_release(rt, s1);
    try std.testing.expectEqualStrings("42", std.mem.sliceTo(s1, 0));

    const s2 = nox_int_to_str(rt, -7) orelse return error.ConvFailed;
    defer nox_str_release(rt, s2);
    try std.testing.expectEqualStrings("-7", std.mem.sliceTo(s2, 0));

    const s3 = nox_float_to_str(rt, 3.5) orelse return error.ConvFailed;
    defer nox_str_release(rt, s3);
    try std.testing.expectEqualStrings("3.5", std.mem.sliceTo(s3, 0));
}

test "nox_str_is_valid_int/nox_str_to_int gecerli/gecersiz girdiyi ayirt eder" {
    try std.testing.expectEqual(@as(i32, 1), nox_str_is_valid_int("42"));
    try std.testing.expectEqual(@as(i64, 42), nox_str_to_int("42"));
    try std.testing.expectEqual(@as(i32, 0), nox_str_is_valid_int("abc"));
}

test "nox_str_is_valid_float/nox_str_to_float gecerli/gecersiz girdiyi ayirt eder" {
    try std.testing.expectEqual(@as(i32, 1), nox_str_is_valid_float("3.5"));
    try std.testing.expectEqual(@as(f64, 3.5), nox_str_to_float("3.5"));
    try std.testing.expectEqual(@as(i32, 0), nox_str_is_valid_float("abc"));
}

test "nox_str_release: refcount sıfıra düşünce gerçekten serbest bırakır (sızıntı yok, DebugAllocator doğrular)" {
    const asap = @import("alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const result = nox_str_concat(rt, "a", "b") orelse return error.ConcatFailed;
    arc.nox_rc_retain(result);
    nox_str_release(rt, result); // refcount: 1 — hâlâ canlı
    nox_str_release(rt, result); // refcount: 0 — serbest bırakıldı
}
