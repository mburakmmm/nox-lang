//! `nox.regex` Zig kabuğu — stdlib fazı V.6 (bkz. nox-teknik-spesifikasyon.md).
//!
//! **Bilinçli v1 kapsamı — TAM bir regex motoru DEĞİL, KLASİK/İYİ BİLİNEN
//! minimal bir alt küme:** Brian Kernighan'ın "Beautiful Code"/"The
//! Practice of Programming"de yayımlanan (kamuya mal olmuş, HERKESÇE
//! bilinen) minimal geri-izlemeli (backtracking) regex algoritmasının
//! GENİŞLETİLMİŞ bir versiyonu — `nox.json`nin `std.json` KULLANMA
//! kararıyla AYNI ilke ("sıfırdan KARMAŞIK bir algoritma İCAT ETME",
//! ama BURADA Zig'in KENDİSİ bir regex motoru SAĞLAMADIĞINDAN, İYİ
//! BİLİNEN/KÜÇÜK/doğruluğu KOLAY doğrulanabilir bir ALGORİTMA seçildi).
//!
//! Desteklenenler: literal karakterler, `.` (herhangi bir karakter),
//! `*`/`+`/`?` (ÖNCEKİ ATOMUN 0-veya-fazla/1-veya-fazla/0-veya-1 tekrarı,
//! AÇGÖZLÜ/greedy), `^`/`$` (başlangıç/bitiş çapaları), `[abc]`/`[a-z]`/
//! `[^abc]` (karakter sınıfları, olumsuzlama DAHİL).
//!
//! **Desteklenmeyenler (bilinçli v1 kapsam DIŞI):** GRUPLAMA (`(...)`),
//! YAKALAMA GRUPLARI, ALTERNASYON (`a|b`), GERİ-REFERANSLAR (`\1`),
//! `{m,n}` sayısal tekrar sözdizimi, ESCAPE dizileri (`\d`, `\w` vb.) —
//! bunların HER BİRİ TAM bir regex motorunun (parser + AST + yürütücü)
//! GEREKTİRDİĞİ mühendislik yükünü GETİRİR; v1 hedefi basit ARAMA/doğrulama
//! senaryolarıdır (ör. bir dosya adının bir uzantıyla BİTİP bitmediğini,
//! bir metnin YALNIZCA rakam İÇERİP içermediğini kontrol etmek).
const std = @import("std");
const str_mod = @import("../str.zig");

/// Bir "atom"un (literal karakter, `.`, ya da `[...]` karakter sınıfı)
/// pattern İÇİNDEKİ bayt uzunluğunu (nicelik işaretçisi — `*`/`+`/`?` —
/// HARİÇ) hesaplar.
fn atomLen(pat: []const u8) usize {
    if (pat.len == 0) return 0;
    if (pat[0] == '[') {
        var i: usize = 1;
        if (i < pat.len and pat[i] == '^') i += 1;
        if (i < pat.len and pat[i] == ']') i += 1; // ']' İLK karakterse LİTERALDİR
        while (i < pat.len and pat[i] != ']') i += 1;
        if (i < pat.len) i += 1; // kapanış ']'
        return i;
    }
    return 1;
}

/// `ch`in `atom` (pat[0..atomLen(pat)]) İLE eşleşip eşleşmediğini kontrol eder.
fn atomMatches(atom: []const u8, ch: u8) bool {
    if (atom.len == 0) return false;
    if (atom[0] == '.') return true;
    if (atom[0] == '[') {
        var negate = false;
        var i: usize = 1;
        if (i < atom.len and atom[i] == '^') {
            negate = true;
            i += 1;
        }
        var found = false;
        const end = atom.len - 1; // son ']' HARİÇ
        while (i < end) {
            if (i + 2 < end and atom[i + 1] == '-') {
                if (ch >= atom[i] and ch <= atom[i + 2]) found = true;
                i += 3;
            } else {
                if (atom[i] == ch) found = true;
                i += 1;
            }
        }
        return found != negate;
    }
    return atom[0] == ch;
}

/// `pat`in `text`in TAM BAŞINDAN eşleştiğini (bir ÖN EK olarak) dener —
/// Kernighan'ın `matchhere`si, `*`/`+`/`?` + karakter sınıfı DESTEĞİYLE
/// GENİŞLETİLDİ.
fn matchHere(pat: []const u8, text: []const u8) bool {
    if (pat.len == 0) return true;
    if (pat[0] == '$' and pat.len == 1) return text.len == 0;

    const alen = atomLen(pat);
    const atom = pat[0..alen];
    const rest = pat[alen..];

    if (rest.len > 0 and (rest[0] == '*' or rest[0] == '+' or rest[0] == '?')) {
        const quant = rest[0];
        const after = rest[1..];
        if (quant == '?') {
            if (text.len > 0 and atomMatches(atom, text[0]) and matchHere(after, text[1..])) return true;
            return matchHere(after, text);
        }
        // '*'/'+': ÖNCE AÇGÖZLÜCE mümkün olduğunca çok atomu TÜKET, SONRA
        // eşleşme bulunana KADAR TEK TEK geri ÇEKİL (klasik backtracking).
        var count: usize = 0;
        while (count < text.len and atomMatches(atom, text[count])) count += 1;
        const min: usize = if (quant == '+') 1 else 0;
        while (count + 1 > min) {
            if (matchHere(after, text[count..])) return true;
            if (count == 0) break;
            count -= 1;
        }
        return false;
    }

    if (text.len > 0 and atomMatches(atom, text[0])) {
        return matchHere(rest, text[1..]);
    }
    return false;
}

/// `pat`in `text` İÇİNDE HERHANGİ bir yerde eşleşip eşleşmediğini
/// (`^` VARSA yalnızca BAŞTAN) dener.
fn matchFrom(pat: []const u8, text: []const u8) bool {
    if (pat.len > 0 and pat[0] == '^') {
        return matchHere(pat[1..], text);
    }
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (matchHere(pat, text[i..])) return true;
    }
    return false;
}

export fn nox_regex_is_match_raw(pattern: ?[*:0]const u8, text: ?[*:0]const u8) callconv(.c) i32 {
    const p = pattern orelse return 0;
    const t = text orelse return 0;
    return if (matchFrom(str_mod.nox_str_slice(p), str_mod.nox_str_slice(t))) 1 else 0;
}

/// İlk eşleşmenin BAŞLADIĞI 0-tabanlı bayt İNDEKSİNİ döner, eşleşme YOKSA
/// `-1`.
export fn nox_regex_find_raw(pattern: ?[*:0]const u8, text: ?[*:0]const u8) callconv(.c) i64 {
    const p = pattern orelse return -1;
    const t = text orelse return -1;
    const pat = str_mod.nox_str_slice(p);
    const txt = str_mod.nox_str_slice(t);
    if (pat.len > 0 and pat[0] == '^') {
        return if (matchHere(pat[1..], txt)) 0 else -1;
    }
    var i: usize = 0;
    while (i <= txt.len) : (i += 1) {
        if (matchHere(pat, txt[i..])) return @intCast(i);
    }
    return -1;
}

test "literal eşleşme" {
    try std.testing.expect(matchFrom("abc", "xabcy"));
    try std.testing.expect(!matchFrom("abc", "abx"));
}

test "'.' herhangi bir karakterle eşleşir" {
    try std.testing.expect(matchFrom("a.c", "abc"));
    try std.testing.expect(matchFrom("a.c", "aXc"));
    try std.testing.expect(!matchFrom("a.c", "ac"));
}

test "'*' sıfır-veya-fazla, açgözlü ama geri çekilebilir" {
    try std.testing.expect(matchFrom("ab*c", "ac"));
    try std.testing.expect(matchFrom("ab*c", "abbbbc"));
    try std.testing.expect(matchFrom("a.*c", "axyzc"));
    try std.testing.expect(!matchFrom("ab*c", "abd"));
}

test "'+' bir-veya-fazla" {
    try std.testing.expect(!matchFrom("ab+c", "ac"));
    try std.testing.expect(matchFrom("ab+c", "abc"));
    try std.testing.expect(matchFrom("ab+c", "abbbc"));
}

test "'?' sıfır-veya-bir" {
    try std.testing.expect(matchFrom("colou?r", "color"));
    try std.testing.expect(matchFrom("colou?r", "colour"));
    try std.testing.expect(!matchFrom("colou?r", "colouur"));
}

test "'^'/'$' çapaları" {
    try std.testing.expect(matchFrom("^abc$", "abc"));
    try std.testing.expect(!matchFrom("^abc$", "xabc"));
    try std.testing.expect(!matchFrom("^abc$", "abcx"));
    try std.testing.expect(matchFrom("^abc", "abcxyz"));
}

test "karakter sınıfları" {
    try std.testing.expect(matchFrom("[abc]", "xbz"));
    try std.testing.expect(!matchFrom("[abc]", "xyz"));
    try std.testing.expect(matchFrom("^[0-9]+$", "12345"));
    try std.testing.expect(!matchFrom("^[0-9]+$", "123a5"));
    try std.testing.expect(matchFrom("[^0-9]", "a"));
    try std.testing.expect(!matchFrom("^[^0-9]+$", "abc123"));
}

// `nox_regex_is_match_raw`/`nox_regex_find_raw` (DIŞA açılan C-ABI
// sarmalayıcıları) artık `str_mod.nox_str_slice`i ÇAĞIRIYOR — bu, GEÇERLİ
// bir Nox `str` başlığı (ARC+STR_HEADER, bkz. `str.zig`) BEKLER. Çıplak Zig
// string LİTERALLERİNİ (başlıksız) DOĞRUDAN bu fonksiyonlara geçirmek,
// `tests/compat/zig_ext/util.zig`nin belge notunda UYARDIĞI AYNI tuzak —
// başlığın hemen ÖNCESİNDEKİ rastgele belleği "paketlenmiş uzunluk" olarak
// OKUR (GERÇEKTEN gözlemlendi: `zig build test` çalıştırmalarında kararsız
// ÇÖKME/sonsuz-döngü DAVRANIŞI). Bu yüzden bu testler `nox_str_from_bytes`
// İLE GERÇEK başlıklı `str`ler İNŞA EDER (`matchFrom`i DOĞRUDAN çağıran
// YUKARIDAKİ testler İSE `matchFrom`in DÜZ `[]const u8` ALDIĞINDAN etkilenmez).
fn makeTestStr(rt: ?*anyopaque, bytes: []const u8) [*:0]u8 {
    return str_mod.nox_str_from_bytes(rt, bytes) orelse unreachable;
}

test "nox_regex_find_raw ilk eşleşmenin indeksini döner" {
    const asap = @import("../alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const wor_d = makeTestStr(rt, "wor.d");
    defer str_mod.nox_str_release(rt, wor_d);
    const xyz = makeTestStr(rt, "xyz");
    defer str_mod.nox_str_release(rt, xyz);
    const caret_hello = makeTestStr(rt, "^hello");
    defer str_mod.nox_str_release(rt, caret_hello);
    const hello_world = makeTestStr(rt, "hello world");
    defer str_mod.nox_str_release(rt, hello_world);

    try std.testing.expectEqual(@as(i64, 6), nox_regex_find_raw(wor_d, hello_world));
    try std.testing.expectEqual(@as(i64, -1), nox_regex_find_raw(xyz, hello_world));
    try std.testing.expectEqual(@as(i64, 0), nox_regex_find_raw(caret_hello, hello_world));
}

// Faz II devamı (test kapsamı genişletmesi, bkz. nox-teknik-spesifikasyon.md
// §3.67) — YUKARIDAKİ testler İÇ yardımcıyı (`matchFrom`) test ediyordu,
// DIŞA açılan `nox_regex_is_match_raw`/`nox_regex_find_raw` sarmalayıcıları
// DOĞRUDAN hiç test edilmemişti; ayrıca negatif karakter sınıfı + nicelik
// işaretçisi KOMBİNASYONU ve boş desen/metin kenar durumları da eksikti.
test "nox_regex_is_match_raw sarmalayicisi dogrudan calisir" {
    const asap = @import("../alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const digits_plus = makeTestStr(rt, "[0-9]+");
    defer str_mod.nox_str_release(rt, digits_plus);
    const anchored_digits = makeTestStr(rt, "^[0-9]+$");
    defer str_mod.nox_str_release(rt, anchored_digits);
    const abc123 = makeTestStr(rt, "abc123");
    defer str_mod.nox_str_release(rt, abc123);

    try std.testing.expectEqual(@as(i32, 1), nox_regex_is_match_raw(digits_plus, abc123));
    try std.testing.expectEqual(@as(i32, 0), nox_regex_is_match_raw(anchored_digits, abc123));
}

test "negatif karakter sinifi + nicelik isaretcisi kombinasyonu" {
    const asap = @import("../alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    try std.testing.expect(matchFrom("^[^0-9]+$", "hello"));
    try std.testing.expect(!matchFrom("^[^0-9]+$", "hell0"));

    const not_lower_plus = makeTestStr(rt, "[^a-z]+");
    defer str_mod.nox_str_release(rt, not_lower_plus);
    const mixed = makeTestStr(rt, "abc123def");
    defer str_mod.nox_str_release(rt, mixed);
    try std.testing.expectEqual(@as(i64, 3), nox_regex_find_raw(not_lower_plus, mixed));
}

test "bos desen/metin kenar durumlari" {
    const asap = @import("../alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const empty = makeTestStr(rt, "");
    defer str_mod.nox_str_release(rt, empty);
    const anything = makeTestStr(rt, "anything");
    defer str_mod.nox_str_release(rt, anything);
    const a_pat = makeTestStr(rt, "a");
    defer str_mod.nox_str_release(rt, a_pat);
    const a_star = makeTestStr(rt, "a*");
    defer str_mod.nox_str_release(rt, a_star);

    // Bos desen HER metinde (bos metin DAHIL) index 0'da eslesir.
    try std.testing.expectEqual(@as(i32, 1), nox_regex_is_match_raw(empty, anything));
    try std.testing.expectEqual(@as(i64, 0), nox_regex_find_raw(empty, empty));
    // Bos metinde bos-olmayan bir desen (nicelik isaretcisi olmadan) eslesmez.
    try std.testing.expectEqual(@as(i32, 0), nox_regex_is_match_raw(a_pat, empty));
    // Ama `a*` (sifir-veya-fazla) bos metinde de eslesir.
    try std.testing.expectEqual(@as(i32, 1), nox_regex_is_match_raw(a_star, empty));
}
