//! `nox.strings` Zig kabuğu — stdlib fazı §H (bkz. nox-teknik-spesifikasyon.md).
//! `split`/`trim`/`upper`/`lower`/`replace` DEĞİŞKEN uzunluklu sonuç
//! üretir/byte-seviyeli tarama gerektirir, bu yüzden Zig'de yazılır. `join`
//! (EE.1, §3.61) VE `index_of`/`starts_with`/`ends_with` (Faz II, §3.67)
//! AYNI gerekçeyle SONRADAN Zig'e taşındı — saf Nox'un `nox_str_byte_at`
//! (HER bayt İçin fonksiyon çağrısı) tabanlı O(n×m) taramasının Rust'ın
//! SIMD-destekli `std.mem.indexOf`ine göre GERÇEK ölçümle (bkz.
//! `benchmarks/strings_perf_bench`) ~16x yavaş olduğu tespit edilmesi
//! ÜZERİNE. `contains` İSE HÂLÂ saf Nox'ta (`index_of(s,needle)>=0`,
//! `stdlib/nox/strings.nox`) — Zig'e taşınan `index_of`nin hızı ONA da
//! otomatik yansır, ayrı bir extern GEREKMEZ. `split`, Alt-Faz F'nin
//! `list[str]` DÖNÜŞ tipi FFI-güvenliğinin GERÇEK ihtiyaç sahibidir.
//!
//! ASCII v1 kapsamı (bilinçli) — Unicode/UTF-8 büyük/küçük harf dönüşümü
//! ERTELENDİ (`std.ascii.toUpper`/`toLower` yalnızca ASCII baytları etkiler,
//! çok baytlı UTF-8 dizileri OLDUĞU GİBİ bırakılır — hatalı değil, sadece
//! büyük/küçük harfe duyarsız).

const std = @import("std");
const arc = @import("../alloc/arc.zig");
const http_client = @import("http_client.zig");
const abi_layout = @import("abi_layout");
const str_mod = @import("../str.zig");

const dupeToNoxStr = http_client.dupeToNoxStr;
/// Faz P1.2: `list[T]` başlığının bayt boyutu — `../../shared/abi_layout.zig`den
/// (derleyiciyle PAYLAŞILAN TEK doğruluk kaynağı) RE-EXPORT. Başlığın
/// İÇİNDEKİ `cap` alanının ofseti (bilinçli olarak AYRI bir sabit
/// verilmez, bkz. P1.2'nin plan notu) hâlâ literal `8`dir.
const LIST_HEADER_SIZE = abi_layout.LIST_HEADER_SIZE;
/// Her `list[T]` elemanı (burada HER ZAMAN bir `str` işaretçisi) TAM 8
/// bayt yuva kaplar.
const FIELD_SLOT_SIZE = abi_layout.FIELD_SLOT_SIZE;

/// Stdlib fazı §F'nin `list[str]` DÖNÜŞ desteğinin GERÇEK ihtiyaç sahibi —
/// `genListLit`in ÜRETTİĞİ AYNI bayt düzeninde (Faz U.1'den beri: 8 bayt
/// uzunluk + 8 bayt kapasite başlığı + `str` işaretçileri, bkz. codegen_qbe/
/// codegen.zig'in `list[T]` başlık düzeni notu) bir payload'ı EL İLE inşa
/// eder — kapasite BURADA HER ZAMAN uzunluğa EŞİTTİR (tam-oturan, büyüme
/// SLACK'i YOK — `.append()` GEREKTİĞİNDE KENDİSİ büyütür). `sep` BOŞSA (v1
/// bilinçli basitleştirmesi — `std.mem.splitSequence`in boş bir ayraçla
/// TANIMSIZ/kullanışsız davranışına GÜVENMEK YERİNE), TÜM `s`i TEK elemanlı
/// bir liste olarak döner.
export fn nox_strings_split_raw(rt: ?*anyopaque, s: ?[*:0]const u8, sep: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    const s_slice = str_mod.nox_str_slice(s orelse return null);
    const sep_slice = str_mod.nox_str_slice(sep orelse return null);

    if (sep_slice.len == 0) {
        const raw = arc.nox_rc_alloc(rt, LIST_HEADER_SIZE + FIELD_SLOT_SIZE) orelse return null;
        const bytes: [*]u8 = @ptrCast(raw);
        @as(*align(1) i64, @ptrCast(bytes)).* = 1;
        @as(*align(1) i64, @ptrCast(bytes + 8)).* = 1;
        const dup = dupeToNoxStr(rt, s_slice) orelse return null;
        @as(*align(1) i64, @ptrCast(bytes + LIST_HEADER_SIZE)).* = @bitCast(@as(isize, @intCast(@intFromPtr(dup))));
        return @ptrCast(bytes);
    }

    var count: usize = 0;
    {
        var it = std.mem.splitSequence(u8, s_slice, sep_slice);
        while (it.next()) |_| count += 1;
    }

    const raw = arc.nox_rc_alloc(rt, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * count) orelse return null;
    const bytes: [*]u8 = @ptrCast(raw);
    @as(*align(1) i64, @ptrCast(bytes)).* = @intCast(count);
    @as(*align(1) i64, @ptrCast(bytes + 8)).* = @intCast(count);

    var it = std.mem.splitSequence(u8, s_slice, sep_slice);
    var i: usize = 0;
    while (it.next()) |part| {
        const dup = dupeToNoxStr(rt, part) orelse return null;
        const slot = bytes + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i;
        @as(*align(1) i64, @ptrCast(slot)).* = @bitCast(@as(isize, @intCast(@intFromPtr(dup))));
        i += 1;
    }
    return @ptrCast(bytes);
}

export fn nox_strings_trim_raw(rt: ?*anyopaque, s: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const slice = str_mod.nox_str_slice(s orelse return null);
    const trimmed = std.mem.trim(u8, slice, " \t\r\n");
    return dupeToNoxStr(rt, trimmed);
}

// Faz III.2 (bkz. nox-teknik-spesifikasyon.md §3.69) — `trim`in TEK
// yönlü varyantları, AYNI boşluk kümesiyle.
export fn nox_strings_trim_start_raw(rt: ?*anyopaque, s: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const slice = str_mod.nox_str_slice(s orelse return null);
    const trimmed = std.mem.trimStart(u8, slice, " \t\r\n");
    return dupeToNoxStr(rt, trimmed);
}

export fn nox_strings_trim_end_raw(rt: ?*anyopaque, s: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const slice = str_mod.nox_str_slice(s orelse return null);
    const trimmed = std.mem.trimEnd(u8, slice, " \t\r\n");
    return dupeToNoxStr(rt, trimmed);
}

/// Faz III.2 — `split`in AKSİNE EN FAZLA `n` parça üretir (SONUNCU parça
/// KALANIN TAMAMIdır — Rust'ın `str::splitn`iyle TUTARLI). `n<=1` VEYA
/// boş `sep` (`split`in KENDİ v1 basitleştirmesiyle AYNI ilke) TÜM `s`i
/// TEK elemanlı bir liste olarak döner. `buildStrList` (aşağıda TANIMLI,
/// `nox_strings_join_raw`nin test yardımcısıyla PAYLAŞILAN) İLE inşa
/// edilir.
export fn nox_strings_splitn_raw(rt: ?*anyopaque, s: ?[*:0]const u8, sep: ?[*:0]const u8, n: i64) callconv(.c) ?*anyopaque {
    const s_slice = str_mod.nox_str_slice(s orelse return null);
    const sep_slice = str_mod.nox_str_slice(sep orelse return null);

    if (n <= 1 or sep_slice.len == 0) {
        return buildStrList(rt, &.{s_slice});
    }

    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer parts.deinit(std.heap.page_allocator);

    var rest = s_slice;
    var count: i64 = 1;
    while (count < n) : (count += 1) {
        const idx = std.mem.indexOf(u8, rest, sep_slice) orelse break;
        parts.append(std.heap.page_allocator, rest[0..idx]) catch return null;
        rest = rest[idx + sep_slice.len ..];
    }
    parts.append(std.heap.page_allocator, rest) catch return null;

    return buildStrList(rt, parts.items);
}

/// Faz III.2 — `split`in AYNI parçalarını, SONDAN başlayarak (Rust'ın
/// `str::rsplit`iyle TUTARLI — AYNI eleman kümesi, TERS sıra) döner.
export fn nox_strings_rsplit_raw(rt: ?*anyopaque, s: ?[*:0]const u8, sep: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    const s_slice = str_mod.nox_str_slice(s orelse return null);
    const sep_slice = str_mod.nox_str_slice(sep orelse return null);

    if (sep_slice.len == 0) {
        return buildStrList(rt, &.{s_slice});
    }

    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer parts.deinit(std.heap.page_allocator);

    var it = std.mem.splitSequence(u8, s_slice, sep_slice);
    while (it.next()) |part| {
        parts.append(std.heap.page_allocator, part) catch return null;
    }
    std.mem.reverse([]const u8, parts.items);

    return buildStrList(rt, parts.items);
}

/// Faz III.2 — `s`i `n` kez ART ARDA birleştirir, TEK geçişte (EE.1'in
/// `join`iyle AYNI "toplam uzunluğu hesapla, TEK tahsis yap" stratejisi
/// — saf Nox `out = out + s` döngüsünün O(n²) maliyetinden KAÇINMAK
/// İçin). `n<=0` BOŞ dize döner.
export fn nox_strings_repeat_raw(rt: ?*anyopaque, s: ?[*:0]const u8, n: i64) callconv(.c) ?[*:0]u8 {
    const s_slice = str_mod.nox_str_slice(s orelse return null);
    if (n <= 0) return dupeToNoxStr(rt, "");

    const count: usize = @intCast(n);
    const total_len = s_slice.len * count;
    // `str`e uzunluk alanı + ASCII bayrağı eklenmesinden BERİ (bkz. plan
    // dosyası) düz (ARA) bir arabellekte İNŞA EDİLİP `dupeToNoxStr` İLE
    // GERÇEK, başlıklı bir Nox `str`ine kopyalanır.
    const buf = std.heap.page_allocator.alloc(u8, total_len) catch return null;
    defer std.heap.page_allocator.free(buf);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        @memcpy(buf[i * s_slice.len ..][0..s_slice.len], s_slice);
    }
    return dupeToNoxStr(rt, buf);
}

/// Faz III.2 — ASCII büyük/küçük harf DUYARSIZ karşılaştırma (ASCII v1
/// kapsamı, bkz. dosya başındaki belge notu — çok baytlı UTF-8 aynen
/// karşılaştırılır).
export fn nox_strings_eq_ignore_case_raw(a: ?[*:0]const u8, b: ?[*:0]const u8) callconv(.c) i32 {
    const a_slice = str_mod.nox_str_slice(a orelse return 0);
    const b_slice = str_mod.nox_str_slice(b orelse return 0);
    return if (std.ascii.eqlIgnoreCase(a_slice, b_slice)) 1 else 0;
}

export fn nox_strings_upper_raw(rt: ?*anyopaque, s: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const slice = str_mod.nox_str_slice(s orelse return null);
    const buf = std.heap.page_allocator.alloc(u8, slice.len) catch return null;
    defer std.heap.page_allocator.free(buf);
    for (slice, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
    return dupeToNoxStr(rt, buf);
}

export fn nox_strings_lower_raw(rt: ?*anyopaque, s: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const slice = str_mod.nox_str_slice(s orelse return null);
    const buf = std.heap.page_allocator.alloc(u8, slice.len) catch return null;
    defer std.heap.page_allocator.free(buf);
    for (slice, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return dupeToNoxStr(rt, buf);
}

/// `old` BOŞSA (v1 bilinçli basitleştirmesi — sonsuz/anlamsız bir
/// eşleştirme sayısına yol AÇMAMAK İÇİN) `s`nin DEĞİŞMEMİŞ bir kopyasını
/// döner.
export fn nox_strings_replace_raw(rt: ?*anyopaque, s: ?[*:0]const u8, old: ?[*:0]const u8, new: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const s_slice = str_mod.nox_str_slice(s orelse return null);
    const old_slice = str_mod.nox_str_slice(old orelse return null);
    const new_slice = str_mod.nox_str_slice(new orelse return null);
    if (old_slice.len == 0) return dupeToNoxStr(rt, s_slice);

    const out_len = std.mem.replacementSize(u8, s_slice, old_slice, new_slice);
    const buf = std.heap.page_allocator.alloc(u8, out_len) catch return null;
    defer std.heap.page_allocator.free(buf);
    _ = std.mem.replace(u8, s_slice, old_slice, new_slice, buf[0..out_len]);
    return dupeToNoxStr(rt, buf);
}

/// Faz EE.1 (bkz. nox-teknik-spesifikasyon.md §3.61) — `join`nin ÖNCEKİ
/// saf-Nox uygulaması `result = result + sep + p` döngüsüydü: `nox_str_
/// concat` (bkz. `str.zig`) HER ÇAĞRIDA TAM bir kopya yaptığından bu O(n²)
/// idi (`split`/`trim`/vb.'nin ZATEN izlediği "değişken uzunluklu sonuç →
/// Zig'e sar" gerekçesiyle AYNI, ama `join` bu düzene UYMUYORDU). Burada
/// TEK geçişte toplam uzunluk hesaplanır, TEK `nox_rc_alloc` yapılır, TÜM
/// parçalar/ayırıcılar KOPYALANIR — O(n). `parts`in ham bayt düzeni
/// `nox_strings_split_raw`nin ÜRETTİĞİYLE (8 bayt uzunluk + 8 bayt
/// kapasite + `str` işaretçileri) AYNIDIR — bkz. onun belge notu.
export fn nox_strings_join_raw(rt: ?*anyopaque, parts: ?*anyopaque, sep: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const bytes: [*]u8 = @ptrCast(parts orelse return null);
    const sep_slice = str_mod.nox_str_slice(sep orelse return null);
    const count: usize = @intCast(@as(*align(1) i64, @ptrCast(bytes)).*);

    if (count == 0) return dupeToNoxStr(rt, "");

    var total_len: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const addr: usize = @bitCast(@as(*align(1) i64, @ptrCast(bytes + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i)).*);
        const p: [*:0]const u8 = @ptrFromInt(addr);
        total_len += std.mem.len(p);
        if (i + 1 < count) total_len += sep_slice.len;
    }

    const buf = std.heap.page_allocator.alloc(u8, total_len) catch return null;
    defer std.heap.page_allocator.free(buf);
    var off: usize = 0;
    i = 0;
    while (i < count) : (i += 1) {
        const addr: usize = @bitCast(@as(*align(1) i64, @ptrCast(bytes + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i)).*);
        const p: [*:0]const u8 = @ptrFromInt(addr);
        const slice = str_mod.nox_str_slice(p);
        @memcpy(buf[off..][0..slice.len], slice);
        off += slice.len;
        if (i + 1 < count) {
            @memcpy(buf[off..][0..sep_slice.len], sep_slice);
            off += sep_slice.len;
        }
    }
    return dupeToNoxStr(rt, buf);
}

/// Faz II devamı (bkz. nox-teknik-spesifikasyon.md §3.67) — `index_of`nin
/// İLK Zig'e taşınan sürümü DOĞRUDAN `std.mem.indexOf`i (Boyer-Moore-
/// Horspool, `haystack.len>52 VE needle.len>4` için) çağırıyordu; bu,
/// saf-Nox O(n×m) döngüsüne göre `strings_perf_bench`nin yavaşlamasını
/// 16.2x'ten 3.6x'e düşürdü AMA Rust'ın `str::contains`ine göre HÂLÂ ~3.3x
/// yavaştı. **İzole ölçümle (Nox/QBE/ARC HİÇ karışmadan, SAF Zig döngüsü)
/// DOĞRULANDI:** kalan fark Nox'un çağrı/ARC/istisna makinesinden
/// GELMİYORDU — `std.mem.indexOf`nin KENDİSİ (BMH'nin HER çağrıda 256
/// baytlık bir skip-tablosu YENİDEN kurması VE SIMD KULLANMAYAN taraması)
/// Rust'ın deyiminden yavaştı. Burada YERİNE Zig'in `std.mem.indexOfScalarPos`
/// (TEK bayt İçin, SIMD-vektörleştirilmiş) İLE "ilk baytı bul, sonra
/// doğrula" stratejisi kullanılır — ÖLÇÜLDÜ: AYNI 50000×2006-bayt
/// senaryosunda BMH'nin ~30ms'ine karşı ~0-1ms (Rust'a EŞDEĞER/ondan
/// hızlı). **Bilinçli v1 basitleştirmesi (kabul edilen risk):** bu
/// yaklaşımın EN KÖTÜ durumu (`needle`in İLK baytı `haystack`ta ÇOK sık
/// tekrarlıyorsa, ör. `needle="aaab"` `haystack="aaaaaaaa..."`da) O(n×m)ye
/// GERİ döner — BMH'nin garantili sub-lineer davranışı YOKTUR. Gerçek
/// dünya metninde (doğal dil, JSON, log satırları) İLK baytın böylesine
/// PATOLOJİK tekrarı NADİRDİR; bu ödünleşim, ÖLÇÜLEN GERÇEK kazanç
/// karşılığında BİLİNÇLİ olarak kabul edildi. Değişken-uzunluklu SONUÇ
/// üretmediğinden (`int` döner) `rt`/`with_rt` GEREKMEZ. Boş `needle`
/// (v1 sözleşmesi, `strings_search.expected` golden testiyle SABİTLENMİŞ)
/// `0` döner.
fn fastIndexOf(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    const first = needle[0];
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, haystack, start, first)) |pos| {
        if (pos + needle.len > haystack.len) return null;
        if (std.mem.eql(u8, haystack[pos..][0..needle.len], needle)) return pos;
        start = pos + 1;
    }
    return null;
}

export fn nox_strings_index_of_raw(s: ?[*:0]const u8, needle: ?[*:0]const u8) callconv(.c) i64 {
    const s_slice = str_mod.nox_str_slice(s orelse return -1);
    const needle_slice = str_mod.nox_str_slice(needle orelse return -1);
    if (needle_slice.len == 0) return 0;
    const idx = fastIndexOf(s_slice, needle_slice) orelse return -1;
    return @intCast(idx);
}

/// Faz II — `starts_with`/`ends_with`nin AYNI gerekçeyle (bkz. yukarısı)
/// Zig'e taşınan eşdeğerleri. `int` (0/1) döner — `nox_fs_exists_raw`
/// gibi mevcut "ham bool" extern'lerle AYNI sözleşme, Nox tarafı `!= 0`
/// ile `bool`a çevirir.
export fn nox_strings_starts_with_raw(s: ?[*:0]const u8, prefix: ?[*:0]const u8) callconv(.c) i64 {
    const s_slice = str_mod.nox_str_slice(s orelse return 0);
    const prefix_slice = str_mod.nox_str_slice(prefix orelse return 0);
    return if (std.mem.startsWith(u8, s_slice, prefix_slice)) 1 else 0;
}

export fn nox_strings_ends_with_raw(s: ?[*:0]const u8, suffix: ?[*:0]const u8) callconv(.c) i64 {
    const s_slice = str_mod.nox_str_slice(s orelse return 0);
    const suffix_slice = str_mod.nox_str_slice(suffix orelse return 0);
    return if (std.mem.endsWith(u8, s_slice, suffix_slice)) 1 else 0;
}

// `nox_strings_*_raw` (DIŞA açılan C-ABI sarmalayıcıları) `str_mod.nox_str_
// slice`i ÇAĞIRIYOR — GEÇERLİ bir Nox `str` başlığı (ARC+STR_HEADER) BEKLER.
// Çıplak Zig string LİTERALLERİNİ DOĞRUDAN bu fonksiyonlara geçirmek
// `regex.zig`nin AYNI belge notunda UYARDIĞI tuzak — bu yüzden AŞAĞIDAKİ
// TÜM testler `makeTestStr` İLE GERÇEK başlıklı `str`ler İNŞA EDER.
fn makeTestStr(rt: ?*anyopaque, bytes: []const u8) [*:0]u8 {
    return str_mod.nox_str_from_bytes(rt, bytes) orelse unreachable;
}

test "nox_strings_index_of_raw/starts_with_raw/ends_with_raw dogru calisir" {
    const asap = @import("../alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const hello = makeTestStr(rt, "hello");
    defer str_mod.nox_str_release(rt, hello);
    const l = makeTestStr(rt, "l");
    defer str_mod.nox_str_release(rt, l);
    const z = makeTestStr(rt, "z");
    defer str_mod.nox_str_release(rt, z);
    const empty = makeTestStr(rt, "");
    defer str_mod.nox_str_release(rt, empty);
    const hi = makeTestStr(rt, "hi");
    defer str_mod.nox_str_release(rt, hi);
    const aaab = makeTestStr(rt, "aaab");
    defer str_mod.nox_str_release(rt, aaab);
    const b = makeTestStr(rt, "b");
    defer str_mod.nox_str_release(rt, b);
    const aaXY = makeTestStr(rt, "aaXY");
    defer str_mod.nox_str_release(rt, aaXY);
    const aY = makeTestStr(rt, "aY");
    defer str_mod.nox_str_release(rt, aY);
    const XY = makeTestStr(rt, "XY");
    defer str_mod.nox_str_release(rt, XY);
    const he = makeTestStr(rt, "he");
    defer str_mod.nox_str_release(rt, he);
    const lo = makeTestStr(rt, "lo");
    defer str_mod.nox_str_release(rt, lo);

    try std.testing.expectEqual(@as(i64, 2), nox_strings_index_of_raw(hello, l));
    try std.testing.expectEqual(@as(i64, -1), nox_strings_index_of_raw(hello, z));
    try std.testing.expectEqual(@as(i64, 0), nox_strings_index_of_raw(hello, empty));
    // `fastIndexOf`nin (BMH degil, "ilk bayti bul + dogrula") kenar durumlari:
    try std.testing.expectEqual(@as(i64, -1), nox_strings_index_of_raw(hi, hello));
    try std.testing.expectEqual(@as(i64, 0), nox_strings_index_of_raw(hello, hello));
    try std.testing.expectEqual(@as(i64, 3), nox_strings_index_of_raw(aaab, b));
    // Ilk bayti TEKRARLI eslesmeyen adaylar (yanlis-pozitif "ilk bayt"
    // sonrasi geri sarma dogru calisiyor mu): "aaXY" icinde "aY" araninca
    // ilk 'a' (idx 0) eslesmez ('a' sonrasi 'a' != 'Y'), idx 1'de ('a'
    // sonrasi 'X' != 'Y') de eslesmez, gercek eslesme YOK.
    try std.testing.expectEqual(@as(i64, -1), nox_strings_index_of_raw(aaXY, aY));
    try std.testing.expectEqual(@as(i64, 2), nox_strings_index_of_raw(aaXY, XY));

    try std.testing.expectEqual(@as(i64, 1), nox_strings_starts_with_raw(hello, he));
    try std.testing.expectEqual(@as(i64, 0), nox_strings_starts_with_raw(hello, lo));
    try std.testing.expectEqual(@as(i64, 1), nox_strings_ends_with_raw(hello, lo));
    try std.testing.expectEqual(@as(i64, 0), nox_strings_ends_with_raw(hello, he));
}

test "nox_strings_split_raw temel bolme" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const s_in = makeTestStr(rt, "a,b,c");
    defer str_mod.nox_str_release(rt, s_in);
    const sep_in = makeTestStr(rt, ",");
    defer str_mod.nox_str_release(rt, sep_in);
    const list_ptr = nox_strings_split_raw(rt, s_in, sep_in) orelse return error.SplitFailed;
    const bytes: [*]u8 = @ptrCast(list_ptr);
    const count: i64 = @as(*align(1) i64, @ptrCast(bytes)).*;
    try std.testing.expectEqual(@as(i64, 3), count);

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const addr: usize = @bitCast(@as(*align(1) i64, @ptrCast(bytes + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i)).*);
        const p: [*:0]u8 = @ptrFromInt(addr);
        defer str.nox_str_release(rt, p);
        if (i == 0) try std.testing.expectEqualStrings("a", std.mem.sliceTo(p, 0));
        if (i == 2) try std.testing.expectEqualStrings("c", std.mem.sliceTo(p, 0));
    }
    arc.nox_rc_release(rt, list_ptr, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * 3);
}

test "nox_strings_trim/upper/lower/replace_raw dogru calisir" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const padded = makeTestStr(rt, "  hi  ");
    defer str.nox_str_release(rt, padded);
    const t = nox_strings_trim_raw(rt, padded) orelse return error.Failed;
    defer str.nox_str_release(rt, t);
    try std.testing.expectEqualStrings("hi", std.mem.sliceTo(t, 0));

    const hi_in = makeTestStr(rt, "hi");
    defer str.nox_str_release(rt, hi_in);
    const u = nox_strings_upper_raw(rt, hi_in) orelse return error.Failed;
    defer str.nox_str_release(rt, u);
    try std.testing.expectEqualStrings("HI", std.mem.sliceTo(u, 0));

    const HI_in = makeTestStr(rt, "HI");
    defer str.nox_str_release(rt, HI_in);
    const l = nox_strings_lower_raw(rt, HI_in) orelse return error.Failed;
    defer str.nox_str_release(rt, l);
    try std.testing.expectEqualStrings("hi", std.mem.sliceTo(l, 0));

    const foobar = makeTestStr(rt, "foo bar foo");
    defer str.nox_str_release(rt, foobar);
    const foo = makeTestStr(rt, "foo");
    defer str.nox_str_release(rt, foo);
    const x_new = makeTestStr(rt, "x");
    defer str.nox_str_release(rt, x_new);
    const r = nox_strings_replace_raw(rt, foobar, foo, x_new) orelse return error.Failed;
    defer str.nox_str_release(rt, r);
    try std.testing.expectEqualStrings("x bar x", std.mem.sliceTo(r, 0));
}

test "Faz III.2: nox_strings_trim_start_raw/trim_end_raw dogru calisir" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const padded = makeTestStr(rt, "  hi  ");
    defer str.nox_str_release(rt, padded);

    const ts = nox_strings_trim_start_raw(rt, padded) orelse return error.Failed;
    defer str.nox_str_release(rt, ts);
    try std.testing.expectEqualStrings("hi  ", std.mem.sliceTo(ts, 0));

    const te = nox_strings_trim_end_raw(rt, padded) orelse return error.Failed;
    defer str.nox_str_release(rt, te);
    try std.testing.expectEqualStrings("  hi", std.mem.sliceTo(te, 0));
}

test "Faz III.2: nox_strings_repeat_raw dogru calisir" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const ab = makeTestStr(rt, "ab");
    defer str.nox_str_release(rt, ab);

    const r0 = nox_strings_repeat_raw(rt, ab, 0) orelse return error.Failed;
    defer str.nox_str_release(rt, r0);
    try std.testing.expectEqualStrings("", std.mem.sliceTo(r0, 0));

    const r3 = nox_strings_repeat_raw(rt, ab, 3) orelse return error.Failed;
    defer str.nox_str_release(rt, r3);
    try std.testing.expectEqualStrings("ababab", std.mem.sliceTo(r3, 0));
}

test "Faz III.2: nox_strings_eq_ignore_case_raw dogru calisir" {
    const asap = @import("../alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const Hello = makeTestStr(rt, "Hello");
    defer str_mod.nox_str_release(rt, Hello);
    const hello = makeTestStr(rt, "hello");
    defer str_mod.nox_str_release(rt, hello);
    const world = makeTestStr(rt, "world");
    defer str_mod.nox_str_release(rt, world);

    try std.testing.expectEqual(@as(i32, 1), nox_strings_eq_ignore_case_raw(Hello, hello));
    try std.testing.expectEqual(@as(i32, 0), nox_strings_eq_ignore_case_raw(Hello, world));
}

/// `nox_strings_split_raw temel bolme` testindeki (bkz. yukarısı) AYNI
/// "sayacı oku, HER elemanı release'e KAYDEDEREK doğrula, SONRA listenin
/// KENDİSİNİ serbest bırak" desenini paylaşan yardımcı.
fn expectStrListAndRelease(rt: ?*anyopaque, list_ptr: *anyopaque, expected: []const []const u8) !void {
    const str = @import("../str.zig");
    const bytes: [*]u8 = @ptrCast(list_ptr);
    const count: usize = @intCast(@as(*align(1) i64, @ptrCast(bytes)).*);
    try std.testing.expectEqual(expected.len, count);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const addr: usize = @bitCast(@as(*align(1) i64, @ptrCast(bytes + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i)).*);
        const p: [*:0]u8 = @ptrFromInt(addr);
        defer str.nox_str_release(rt, p);
        try std.testing.expectEqualStrings(expected[i], std.mem.sliceTo(p, 0));
    }
    arc.nox_rc_release(rt, list_ptr, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * count);
}

test "Faz III.2: nox_strings_splitn_raw en fazla n parca uretir, sonuncu kalanin tamami" {
    const asap = @import("../alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const s_in = makeTestStr(rt, "a,b,c,d");
    defer str_mod.nox_str_release(rt, s_in);
    const sep_in = makeTestStr(rt, ",");
    defer str_mod.nox_str_release(rt, sep_in);
    const list_ptr = nox_strings_splitn_raw(rt, s_in, sep_in, 2) orelse return error.Failed;
    try expectStrListAndRelease(rt, list_ptr, &.{ "a", "b,c,d" });
}

test "Faz III.2: nox_strings_rsplit_raw AYNI parcalari TERS sirada doner" {
    const asap = @import("../alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const s_in = makeTestStr(rt, "a,b,c");
    defer str_mod.nox_str_release(rt, s_in);
    const sep_in = makeTestStr(rt, ",");
    defer str_mod.nox_str_release(rt, sep_in);
    const list_ptr = nox_strings_rsplit_raw(rt, s_in, sep_in) orelse return error.Failed;
    try expectStrListAndRelease(rt, list_ptr, &.{ "c", "b", "a" });
}

/// `nox_strings_split_raw`nin TERSİ: bir Zig `[]const []const u8`ten
/// `nox_strings_join_raw`nin BEKLEDİĞİ ham `list[str]` payload'ını EL İLE
/// inşa eder — `nox_strings_split_raw`nin KENDİSİNİN inşa mantığıyla AYNI
/// (bkz. onun belge notu).
fn buildStrList(rt: ?*anyopaque, parts: []const []const u8) ?*anyopaque {
    const raw = arc.nox_rc_alloc(rt, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * parts.len) orelse return null;
    const bytes: [*]u8 = @ptrCast(raw);
    @as(*align(1) i64, @ptrCast(bytes)).* = @intCast(parts.len);
    @as(*align(1) i64, @ptrCast(bytes + 8)).* = @intCast(parts.len);
    for (parts, 0..) |part, i| {
        const dup = dupeToNoxStr(rt, part) orelse return null;
        const slot = bytes + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i;
        @as(*align(1) i64, @ptrCast(slot)).* = @bitCast(@as(isize, @intCast(@intFromPtr(dup))));
    }
    return @ptrCast(bytes);
}

test "nox_strings_join_raw parcalari ayiraçla dogru birlestirir (tek gecis, O(n))" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const parts = buildStrList(rt, &.{ "a", "bb", "ccc" }) orelse return error.BuildFailed;
    const parts_bytes: [*]u8 = @ptrCast(parts);
    defer {
        // `nox_rc_release` (bkz. `nox_strings_split_raw`nin AYNI notu) yalnızca
        // liste kabının KENDİ belleğini serbest bırakır — ELEMANLARIN kendi
        // refcount'larını AYRI AYRI (`str.nox_str_release`) düşürmek gerekir.
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            const addr: usize = @bitCast(@as(*align(1) i64, @ptrCast(parts_bytes + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i)).*);
            str.nox_str_release(rt, @ptrFromInt(addr));
        }
        arc.nox_rc_release(rt, parts, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * 3);
    }

    const sep_in = makeTestStr(rt, ", ");
    defer str.nox_str_release(rt, sep_in);
    const joined = nox_strings_join_raw(rt, parts, sep_in) orelse return error.JoinFailed;
    defer str.nox_str_release(rt, joined);
    try std.testing.expectEqualStrings("a, bb, ccc", std.mem.sliceTo(joined, 0));
}

test "nox_strings_join_raw bos liste bos dize doner" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const parts = buildStrList(rt, &.{}) orelse return error.BuildFailed;
    defer arc.nox_rc_release(rt, parts, 16);

    const sep_in = makeTestStr(rt, ", ");
    defer str.nox_str_release(rt, sep_in);
    const joined = nox_strings_join_raw(rt, parts, sep_in) orelse return error.JoinFailed;
    defer str.nox_str_release(rt, joined);
    try std.testing.expectEqualStrings("", std.mem.sliceTo(joined, 0));
}
