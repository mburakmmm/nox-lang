//! `str` için Alt-Faz B çalışma zamanı desteği — birleştirme (`+`) ve
//! ARC release (bkz. nox-teknik-spesifikasyon.md, stdlib fazı §B).
//!
//! `str` ARC-yönetimli bir heap tipidir (bkz. codegen_qbe/codegen.zig,
//! `isHeapManaged`) — bir string literali ile dinamik (birleştirilmiş) bir
//! string'in AYNI temsili (sıfırla-sonlanan bir C dizesi, hemen önünde 8
//! baytlık bir refcount) paylaşabilmesi İÇİN bilinçli bir tasarım (bkz.
//! `.string_lit`in codegen belge notu, `PINNED_REFCOUNT` hilesi).
//!
//! **`STR_HEADER_SIZE` (bkz. `shared/abi_layout.zig`nin belge notu):** `str`
//! artık ARC refcount başlığından SONRA, GERÇEK baytlardan ÖNCE, KENDİ
//! paketlenmiş bir başlık (bayt-uzunluğu + ascii-durumu) taşır —
//! `[ARC_HEADER_SIZE][STR_HEADER_SIZE (paketlenmiş)][baytlar...NUL]`.
//! Kamuya açık `str_ptr` (bu dosyanın DÖNDÜRDÜĞÜ HER işaretçi) PAKETLENMİŞ
//! başlığın HEMEN ARDINDAN, HÂLÂ geçerli bir NUL-sonlandırılmış bayt
//! dizisine işaret eder (`extern def`/HPy geçişi BOZULMAZ). `arc.*`
//! fonksiyonları (retain/predecrement/free) İSE `str_ptr - STR_HEADER_SIZE`
//! (`strArcPtr`) üzerinde çağrılmalıdır — `list`/`class`nin AKSİNE, `str`
//! İçin "kamuya açık işaretçi" İLE "arc payload işaretçisi" AYNI DEĞİLDİR.

const std = @import("std");
const arc = @import("alloc/arc.zig");
const abi_layout = @import("abi_layout");

const STR_HEADER_SIZE = abi_layout.STR_HEADER_SIZE;
const ASCII_UNKNOWN = abi_layout.STR_ASCII_UNKNOWN;
const ASCII_TRUE = abi_layout.STR_ASCII_TRUE;
const ASCII_FALSE = abi_layout.STR_ASCII_FALSE;

/// `str_ptr`den ARC payload işaretçisine (`arc.*` fonksiyonlarının
/// beklediği "gerçek" işaretçi) döner.
fn strArcPtr(str_ptr: [*:0]const u8) [*]u8 {
    const bytes: [*]u8 = @ptrCast(@constCast(str_ptr));
    return bytes - STR_HEADER_SIZE;
}

fn strHeaderField(str_ptr: [*:0]const u8) *align(1) i64 {
    return @ptrCast(strArcPtr(str_ptr));
}

/// **BULUNDU (bu ABI değişikliği sırasında, GERÇEK bir veri-bozulması
/// hatası)**: runtime'ın HER YERİNDE (`json.zig`nin `callMakeJsonValue`si,
/// `dict.zig`nin str-anahtar/değer retain'i, `http_server.zig`nin
/// `HttpRequest` alan retain'i, vb.) bir `str` işaretçisi ÜZERİNDE
/// `arc.nox_rc_retain`/`nox_rc_predecrement`/`nox_rc_release` DOĞRUDAN
/// (bare) çağrılıyordu — bu fonksiyonlar `payload_ptr - ARC_HEADER_SIZE`
/// formülünü kullanır, ki bu `list`/`class`/`dict`/`closure` İçin
/// DOĞRUDUR (kamuya açık işaretçi == arc payload işaretçisi) AMA `str`
/// İçin YANLIŞTIR (`str_ptr - ARC_HEADER_SIZE` GERÇEKTE paketlenmiş
/// uzunluk+ascii başlığının KENDİSİDİR, refcount DEĞİL — bkz. bu dosyanın
/// modül üstü notu) — bu YÜZDEN bir `str` üzerinde bare `arc.nox_rc_
/// retain`/`predecrement` çağrısı SESSİZCE paketlenmiş UZUNLUK alanını
/// artırır/azaltır (GERÇEKTEN gözlemlendi: JSON'dan decode edilen "hi"
/// stringi `nox_json_make_json_value`nin __init__ retain'ini telafi eden
/// BARE `arc.nox_rc_predecrement(s)` çağrısı YÜZÜNDEN "h"e KISALDI —
/// paketlenmiş uzunluk 2'den 1'e DÜŞTÜ, GERÇEK bayt İÇERİĞİ DEĞİŞMEDİ).
/// Runtime'ın (str.zig'in KENDİSİ DIŞINDAKİ) HERHANGİ bir dosyası bir
/// `str` işaretçisini retain/predecrement/release ETMESİ GEREKTİĞİNDE
/// `arc.nox_rc_*`i DOĞRUDAN DEĞİL, BU üç fonksiyonu KULLANMALIDIR.
pub fn nox_str_retain(str_ptr: ?[*:0]const u8) void {
    const p = str_ptr orelse return;
    arc.nox_rc_retain(strArcPtr(p));
}

pub fn nox_str_predecrement(str_ptr: ?[*:0]const u8) i32 {
    const p = str_ptr orelse return 0;
    return arc.nox_rc_predecrement(strArcPtr(p));
}

/// **BULUNDU (bu ABI değişikliği sırasında)**: runtime'ın KENDİ İÇİNDE
/// (`dict.zig`nin `nox_dict_keys`i, `thread_channel.zig`nin gönderim
/// yolu) `nox_str_concat(rt, existing_str, "")` "bu string'i bağımsız
/// bir kopya olarak KLONLA" İDİOMU olarak kullanılıyordu — bare `""`
/// (HİÇBİR ARC/STR başlığı TAŞIMAYAN, derleyicinin ürettiği bir Zig
/// KAYNAK-kodu literali) artık `strArcPtr`/`strHeaderField` üzerinden
/// KENDİSİNDEN ÖNCEKİ baytları (paketlenmiş uzunluk/ascii alanı OLARAK)
/// OKUMAYA çalışıldığında ÇÖP bellek okur — GERÇEK bir çökme/bozulma.
/// Bu PINNED (asla serbest bırakılmayan, `codegen.zig`nin `.data $strN`
/// yayınıyla AYNI ruh) tekil boş `str`, `""` yerine HER YERDE GÜVENLE
/// geçirilebilir.
const PinnedEmptyStr = extern struct {
    refcount: i64 = abi_layout.PINNED_REFCOUNT,
    header: i64 = abi_layout.packStrHeader(0, abi_layout.STR_ASCII_TRUE),
    data: [1]u8 = .{0},
};
var g_pinned_empty_str: PinnedEmptyStr = .{};

/// Bare bir `""` Zig literalinin YERİNE HER YERDE (test VEYA üretim kodu)
/// güvenle geçirilebilecek, GEÇERLİ başlıklı, PINNED, boş bir `str`.
pub fn nox_empty_str() [*:0]const u8 {
    return @ptrCast(&g_pinned_empty_str.data);
}

/// `runtime/stdlib_shims/*.zig`nin (HTTP gövdesi, dosya okuma, vb.) KEYFİ
/// bayt dizilerinden `str` inşa eden KANONİK yol — `dupeToNoxStr`nin
/// (`http_client.zig`, 8 dosyada ALIAS'lı + 6 dosyada BAĞIMSIZ kopyalanmış)
/// YERİNİ alır. Ascii-durumu BİLİNMEDİĞİNDEN (`ASCII_UNKNOWN`) SIFIR
/// tarama maliyetiyle inşa edilir — çözüm `ensureAsciiResolved`e
/// ERTELENİR. Runtime'ın KENDİ test dosyaları (`http_client.zig`/
/// `http_server.zig`/`dict.zig`/`thread_channel.zig`) DA aynı sebeple
/// (bare Zig literalleri HİÇBİR ARC/STR başlığı TAŞIMADIĞINDAN
/// `nox_str_concat`/`release`/vb. fonksiyonlara DOĞRUDAN geçirilemez)
/// BUNU kullanır.
pub fn nox_str_from_bytes(rt: ?*anyopaque, bytes: []const u8) ?[*:0]u8 {
    return allocStr(rt, bytes, ASCII_UNKNOWN);
}

/// `len` baytlık, sıfırla-sonlanan YENİ bir Nox `str` tahsis eder ve veri işaretçisini döner;
/// çağıran `len` baytı DOĞRUDAN buraya yazar (ASCII durumu "bilinmiyor"). `nox_strings_*`
/// shim'leri önceden sonucu `page_allocator`dan (her çağrıda mmap/munmap) geçici bir arabelleğe
/// kurup `nox_str_from_bytes` ile ikinci kez kopyalıyordu: `join` Python'dan ~7x yavaştı.
pub fn nox_str_alloc_buf(rt: ?*anyopaque, len: usize) ?[*]u8 {
    const raw = arc.nox_rc_alloc(rt, STR_HEADER_SIZE + len + 1) orelse return null;
    const base: [*]u8 = @ptrCast(raw);
    const header: *align(1) i64 = @ptrCast(base);
    header.* = abi_layout.packStrHeader(len, ASCII_UNKNOWN);
    const data = base + STR_HEADER_SIZE;
    data[len] = 0;
    return data;
}

/// `needle`ın `haystack` içindeki ilk konumu (SIMD ilk-bayt araması + doğrulama; `nox.strings.index_of` ile
/// `in` operatörü paylaşır). `needle` BOŞ OLMAMALI. En kötü durum (needle'ın ilk baytı çok sık) O(n×m).
pub fn fastIndexOf(haystack: []const u8, needle: []const u8) ?usize {
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

/// `needle in haystack` (v1.145.0): alt-dize varsa 1, yoksa 0. Boş `needle` HER ZAMAN 1 (Python: `"" in s`).
pub export fn nox_str_contains(haystack: ?[*:0]const u8, needle: ?[*:0]const u8) i64 {
    const h = nox_str_slice(haystack orelse return 0);
    const n = nox_str_slice(needle orelse return 0);
    if (n.len == 0) return 1;
    return if (fastIndexOf(h, n) != null) 1 else 0;
}

/// O(1) — paketlenmiş başlıktan HAM BAYT uzunluğunu okur (artık `strlen`
/// TARAMASI YOK).
pub fn strByteLen(str_ptr: [*:0]const u8) u64 {
    return abi_layout.unpackStrLength(strHeaderField(str_ptr).*);
}

fn strAsciiState(str_ptr: [*:0]const u8) u64 {
    return abi_layout.unpackStrAsciiState(strHeaderField(str_ptr).*);
}

fn setStrAsciiState(str_ptr: [*:0]const u8, state: u64) void {
    const h = strHeaderField(str_ptr);
    const len = abi_layout.unpackStrLength(h.*);
    h.* = abi_layout.packStrHeaderCap(len, state, abi_layout.unpackStrCapExp(h.*));
}

/// O(1) — paketlenmiş uzunluktan bir Zig dilimi üretir; `runtime/
/// stdlib_shims/`nin `std.mem.span(nox_str_param)` (bir tam `strlen`
/// taraması) yerine kullanması İçin dışa açılır.
pub fn nox_str_slice(str_ptr: [*:0]const u8) []const u8 {
    return str_ptr[0..strByteLen(str_ptr)];
}

/// Paketlenmiş ascii-durumunu OKUR; "bilinmiyor" İSE (artık O(1) BİLİNEN
/// uzunlukla SINIRLI) baytları BİR KEZ tarar, SONUCU header'a YAZARAK
/// önbellekler (gelecekteki TÜM çağrılar İçin), döner.
///
/// **Atomik OLMASI GEREKMEZ**: `runtime/alloc/asap.zig`nin `arc_owner_pool`
/// belge notu, Nox'un ARC nesnelerinin ASLA GERÇEK paralel erişime
/// AÇILMADIĞINI belirtir; `nox.thread`/`ThreadChannel` bir `str`i GERÇEK
/// OS iş parçacıkları ARASINDA geçirirken HER ZAMAN derin kopyalar (bkz.
/// `thread_bridge.zig`/`thread_channel.zig`) — AYNI ARC `str` nesnesi İKİ
/// GERÇEK OS iş parçacığı TARAFINDAN ASLA eşzamanlı TUTULMAZ. Düz bir
/// oku/değiştir/yaz, refcount'un KENDİSİYLE AYNI güvenlik varsayımı
/// altında yeterlidir.
fn ensureAsciiResolved(str_ptr: [*:0]const u8) bool {
    const state = strAsciiState(str_ptr);
    if (state != ASCII_UNKNOWN) return state == ASCII_TRUE;
    const bytes = nox_str_slice(str_ptr);
    var is_ascii = true;
    for (bytes) |b| {
        if (b >= 0x80) {
            is_ascii = false;
            break;
        }
    }
    setStrAsciiState(str_ptr, if (is_ascii) ASCII_TRUE else ASCII_FALSE);
    return is_ascii;
}

/// `str`-üreten HER fonksiyonun kullandığı TEK tahsis sarmalayıcısı —
/// `nox_rc_alloc(rt, STR_HEADER_SIZE + bytes.len + 1)` çağırır, paketlenmiş
/// başlığı (`ascii_state` — çağıran ÇOĞU ZAMAN bunu SIFIR maliyetle
/// biliyorsa dolduru, aksi halde `ASCII_UNKNOWN` geçirip çözümlemeyi
/// `ensureAsciiResolved`e ERTELER) yazar, baytları kopyalar, kamuya açık
/// `str_ptr`yi (paketlenmiş başlığın ARDINDAN) döner.
fn allocStr(rt: ?*anyopaque, bytes: []const u8, ascii_state: u64) ?[*:0]u8 {
    const raw = arc.nox_rc_alloc(rt, STR_HEADER_SIZE + bytes.len + 1) orelse return null;
    const base: [*]u8 = @ptrCast(raw);
    const header: *align(1) i64 = @ptrCast(base);
    header.* = abi_layout.packStrHeader(bytes.len, ascii_state);
    const data = base + STR_HEADER_SIZE;
    @memcpy(data[0..bytes.len], bytes);
    data[bytes.len] = 0;
    return @ptrCast(data);
}

/// `a`+`b`nin birleşimi olan YENİ, sıfırla-sonlanan bir dize tahsis eder
/// (refcount 1 ile başlar, `nox_rc_alloc` üzerinden — ARC havuzundan
/// faydalanır). `a`/`b` NE değiştirilir NE serbest bırakılır — çağıranın
/// (codegen'in `genBinary`i) kendi ARC kuralları operandların releaser'ını
/// AYRICA yönetir. Ascii-durumu: HER İKİ operand da ÇÖZÜLMÜŞ-ascii İSE
/// sonuç ascii; HERHANGİ biri ÇÖZÜLMÜŞ-ascii-DEĞİL İSE sonuç ascii-değil
/// (KISA-DEVRE, TARAMA GEREKMEZ); AKSİ HALDE (herhangi biri "bilinmiyor")
/// sonuç DA "bilinmiyor" — concat'ı yavaşlatacak bir tarama ASLA zorlanmaz.
pub export fn nox_str_concat(rt: ?*anyopaque, a: ?[*:0]const u8, b: ?[*:0]const u8) ?[*:0]u8 {
    const pa = a orelse return null;
    const pb = b orelse return null;
    const len_a = strByteLen(pa);
    const len_b = strByteLen(pb);
    const total_len = len_a + len_b;

    const ascii_a = strAsciiState(pa);
    const ascii_b = strAsciiState(pb);
    const ascii_state: u64 = blk: {
        if (ascii_a == ASCII_FALSE or ascii_b == ASCII_FALSE) break :blk ASCII_FALSE;
        if (ascii_a == ASCII_TRUE and ascii_b == ASCII_TRUE) break :blk ASCII_TRUE;
        break :blk ASCII_UNKNOWN;
    };

    const raw = arc.nox_rc_alloc(rt, STR_HEADER_SIZE + total_len + 1) orelse return null;
    const base: [*]u8 = @ptrCast(raw);
    const header: *align(1) i64 = @ptrCast(base);
    header.* = abi_layout.packStrHeader(total_len, ascii_state);
    const data = base + STR_HEADER_SIZE;
    @memcpy(data[0..len_a], pa[0..len_a]);
    @memcpy(data[len_a..][0..len_b], pb[0..len_b]);
    data[total_len] = 0;
    return @ptrCast(data);
}

/// v1.142.17: `s = s + x` (yerel `s`, `x` ifadelerinde `s` geçmiyor) için yerinde büyütme. `a`
/// (değişkenin KENDİ referansı) TÜKETİLİR, dönen dize +1 sahiplidir; `b` ödünç alınır.
/// Münhasır (refcount == 1, literal/pinned DEĞİL) ve kapasite yetiyorsa aynı blokta ekler; yoksa
/// (amortize) büyütülmüş yeni blok açar, eskisini serbest bırakır. Küçük bloklar (havuz sınıfı ≤ 8 KiB)
/// havuz sınıfının örtük boşluğundan yararlanır (serbest bırakma boyutu aynı sınıfa düşer);
/// büyük bloklar başlıktaki `cap_exp` ile 2'nin kuvvetine yuvarlanır. Önceden her ekleme tüm
/// dizeyi kopyalıyordu (200K `s = s + "ab"` = 2.6 s, O(n²)).
pub export fn nox_str_append(rt: ?*anyopaque, a: ?[*:0]u8, b: ?[*:0]const u8) ?[*:0]u8 {
    const pa = a orelse return nox_str_concat(rt, a, b);
    const pb = b orelse {
        const r = nox_str_concat(rt, a, b);
        nox_str_release(rt, a);
        return r;
    };
    const hdr_ptr = strHeaderField(pa);
    const hdr = hdr_ptr.*;
    const len_a: usize = @intCast(abi_layout.unpackStrLength(hdr));
    const len_b: usize = @intCast(strByteLen(pb));
    const total = len_a + len_b;
    const cap_exp = abi_layout.unpackStrCapExp(hdr);

    const ascii_a = abi_layout.unpackStrAsciiState(hdr);
    const ascii_b = strAsciiState(pb);
    const ascii_state: u64 = blk: {
        if (ascii_a == ASCII_FALSE or ascii_b == ASCII_FALSE) break :blk ASCII_FALSE;
        if (ascii_a == ASCII_TRUE and ascii_b == ASCII_TRUE) break :blk ASCII_TRUE;
        break :blk ASCII_UNKNOWN;
    };

    const arc_ptr = strArcPtr(pa);
    const rc_word: *const i64 = @ptrCast(@alignCast(arc_ptr - abi_layout.ARC_HEADER_SIZE));
    const unique = rc_word.* == 1;
    const need_payload = STR_HEADER_SIZE + total + 1;
    if (unique) {
        const cap_payload: usize = if (cap_exp != 0)
            (@as(usize, 1) << @intCast(cap_exp))
        else
            arc.poolSlotPayloadSize(STR_HEADER_SIZE + len_a + 1);
        if (need_payload <= cap_payload) {
            const data: [*]u8 = @ptrCast(pa);
            @memcpy(data[len_a..][0..len_b], pb[0..len_b]);
            data[total] = 0;
            hdr_ptr.* = abi_layout.packStrHeaderCap(total, ascii_state, cap_exp);
            return pa;
        }
    }
    // Yeni blok: büyük boyutta kapasiteyi 2'nin kuvvetine yuvarla (amortize büyüme).
    var alloc_payload: usize = need_payload;
    var new_cap_exp: u64 = 0;
    if (!arc.poolFits(need_payload)) {
        alloc_payload = std.math.ceilPowerOfTwo(usize, need_payload) catch need_payload;
        if (alloc_payload != need_payload) new_cap_exp = std.math.log2_int(usize, alloc_payload);
    }
    const raw = arc.nox_rc_alloc(rt, alloc_payload) orelse return null;
    const base: [*]u8 = @ptrCast(raw);
    const nh: *align(1) i64 = @ptrCast(base);
    nh.* = abi_layout.packStrHeaderCap(total, ascii_state, new_cap_exp);
    const data = base + STR_HEADER_SIZE;
    @memcpy(data[0..len_a], pa[0..len_a]);
    @memcpy(data[len_a..][0..len_b], pb[0..len_b]);
    data[total] = 0;
    nox_str_release(rt, a);
    return @ptrCast(data);
}

/// `ptr`nin refcount'unu bir azaltır; sıfıra/altına düşerse belleği
/// (`STR_HEADER_SIZE + bayt-uzunluğu + 1` — `nox_rc_alloc`a verilenle AYNI
/// hesap) gerçekten serbest bırakır. Pinned (literal) dizeler İÇİN
/// predecrement asla sıfıra düşmeyeceğinden bu HİÇBİR ZAMAN gerçekten
/// serbest bırakmaz.
pub export fn nox_str_release(rt: ?*anyopaque, ptr: ?[*:0]u8) void {
    const p = ptr orelse return;
    const arc_ptr = strArcPtr(p);
    if (arc.nox_rc_predecrement(arc_ptr) != 0) {
        arc.nox_rc_free_payload(rt, arc_ptr, abi_layout.strPayloadSize(strHeaderField(p).*));
    }
}

/// Faz GG.1 (bkz. nox-teknik-spesifikasyon.md — performans fazı): `nox_str_release`in
/// AYNISI, ama predecrement adımı ÇIKARILMIŞ — `codegen.zig`nin `releaseValueIfSet`i
/// ARTIK predecrement'i (`emitInlinePredecrement` İLE AYNI desen) DOĞRUDAN QBE IR'ına
/// inline ediyor (`nox_rc_retain`/`predecrement`in class/list İçin ZATEN yaptığı GİBİ) —
/// bu, HER `str` release'inde (pinned/literal dizeler DAHİL, ki HİÇBİR ZAMAN
/// gerçekten serbest bırakılmazlar) tam bir fonksiyon çağrısı maliyetini ORTADAN
/// KALDIRIR; yalnızca refcount GERÇEKTEN sıfıra/altına düştüğünde (NADİR yol) BU
/// fonksiyon çağrılır — gerçek serbest bırakma İçin. `ptr`nin KENDİSİ null OLAMAZ
/// (çağıran taraf, `releaseValueIfSet`in KENDİ null-kontrolü ZATEN GEÇTİKTEN SONRA
/// buraya gelir).
pub export fn nox_str_free_now(rt: ?*anyopaque, ptr: [*:0]u8) void {
    const arc_ptr = strArcPtr(ptr);
    arc.nox_rc_free_payload(rt, arc_ptr, abi_layout.strPayloadSize(strHeaderField(ptr).*));
}

test "nox_str_contains alt-dize arar (boş needle her zaman 1)" {
    const asap = @import("alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const hay = allocStr(rt, "hello world", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, hay);
    const yes = allocStr(rt, "lo w", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, yes);
    const no = allocStr(rt, "xyz", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, no);
    const longer = allocStr(rt, "hello world!", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, longer);
    const empty = allocStr(rt, "", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, empty);

    try std.testing.expectEqual(@as(i64, 1), nox_str_contains(hay, yes));
    try std.testing.expectEqual(@as(i64, 0), nox_str_contains(hay, no));
    try std.testing.expectEqual(@as(i64, 0), nox_str_contains(hay, longer));
    try std.testing.expectEqual(@as(i64, 1), nox_str_contains(hay, empty));
    try std.testing.expectEqual(@as(i64, 1), nox_str_contains(empty, empty));
}

test "nox_str_alloc_buf yazılabilir, uzunluk başlıklı, sıfırla sonlanan dize verir" {
    const asap = @import("alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const buf = nox_str_alloc_buf(rt, 5) orelse return error.AllocFailed;
    @memcpy(buf[0..5], "salut");
    const s: [*:0]u8 = @ptrCast(buf);
    defer nox_str_release(rt, s);
    try std.testing.expectEqual(@as(u64, 5), strByteLen(s));
    try std.testing.expectEqualStrings("salut", std.mem.sliceTo(s, 0));

    const empty = nox_str_alloc_buf(rt, 0) orelse return error.AllocFailed;
    const e: [*:0]u8 = @ptrCast(empty);
    defer nox_str_release(rt, e);
    try std.testing.expectEqual(@as(u64, 0), strByteLen(e));
    try std.testing.expectEqual(@as(u8, 0), e[0]);
}

test "nox_str_concat iki dizeyi doğru birleştirir, sıfırla sonlanır" {
    const asap = @import("alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const a = allocStr(rt, "merhaba ", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, a);
    const b = allocStr(rt, "dünya", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, b);

    const result = nox_str_concat(rt, a, b) orelse return error.ConcatFailed;
    defer nox_str_release(rt, result);
    try std.testing.expectEqualStrings("merhaba dünya", std.mem.sliceTo(result, 0));
    try std.testing.expectEqual(@as(u64, "merhaba dünya".len), strByteLen(result));
}

/// Stdlib fazı §E: `str(x)`/`int(s)`/`float(s)` çekirdek dönüşüm
/// yerleşiklerinin çalışma zamanı desteği — `print`/`len` İLE AYNI, checker/
/// codegen'de ÖZEL işlenen (bkz. `checker.zig`nin `checkCall`ı,
/// `codegen.zig`nin `genCall`ı) yerleşikler, `extern def` DEĞİLLER.
///
/// `nox_int_to_str`/`nox_float_to_str` HER ZAMAN başarılıdır (bir `int`/
/// `float` değeri ASLA "geçersiz" olamaz) — ARC'lı YENİ bir `str` döner;
/// çıktı (rakam/`.`/`-`) HER ZAMAN ascii, SIFIR maliyetle `ASCII_TRUE`
/// sabitlenir. `nox_str_to_int`/`nox_str_to_float` İSE ayrıştırma
/// BAŞARISIZ olabilir — bu yüzden codegen ÖNCE karşılık gelen
/// `nox_str_is_valid_*`yi çağırıp (bir `ValueError` `raise` etmesi
/// gerekip gerekmediğine karar vermek için), YALNIZCA geçerliyse gerçek
/// dönüşüm fonksiyonunu çağırır.
pub export fn nox_int_to_str(rt: ?*anyopaque, n: i64) ?[*:0]u8 {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return null;
    return allocStr(rt, s, ASCII_TRUE);
}

/// v2.0 madde 4: `u64`/`usize` (VE zaten sıfır-genişletilmiş küçük
/// işaretsiz kind'ler) İçİn — `nox_int_to_str`nin İMZALI `%lld`
/// karşılığı BÜYÜK (>= 2^63) değerleri YANLIŞLIKLA negatif yazdırır,
/// bu YÜZDEN AYRI bir işaretsiz biçimlendirici gerekir (bkz. `genPrint`in
/// AYNI `$fmt_uint` gerekçesi).
pub export fn nox_uint_to_str(rt: ?*anyopaque, n: u64) ?[*:0]u8 {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return null;
    return allocStr(rt, s, ASCII_TRUE);
}

pub export fn nox_float_to_str(rt: ?*anyopaque, f: f64) ?[*:0]u8 {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch return null;
    return allocStr(rt, s, ASCII_TRUE);
}

pub export fn nox_str_is_valid_int(s: ?[*:0]const u8) i32 {
    const p = s orelse return 0;
    _ = std.fmt.parseInt(i64, nox_str_slice(p), 10) catch return 0;
    return 1;
}

pub export fn nox_str_to_int(s: ?[*:0]const u8) i64 {
    const p = s orelse return 0;
    return std.fmt.parseInt(i64, nox_str_slice(p), 10) catch 0;
}

pub export fn nox_str_is_valid_float(s: ?[*:0]const u8) i32 {
    const p = s orelse return 0;
    _ = std.fmt.parseFloat(f64, nox_str_slice(p)) catch return 0;
    return 1;
}

pub export fn nox_str_to_float(s: ?[*:0]const u8) f64 {
    const p = s orelse return 0;
    return std.fmt.parseFloat(f64, nox_str_slice(p)) catch 0;
}

/// v1.142.18: 128 ASCII karakterin ÖNCEDEN kurulmuş, PINNED (`PINNED_REFCOUNT`) tek karakterlik
/// dizeleri — `s[i]` (ve çağıran derleyici kodu) ASCII bayt için tahsis ETMEZ, serbest
/// bırakma refcount azaltmaktan ibarettir (asla sıfıra düşmez). Düzen string literalleriyle
/// AYNI: `{ refcount: i64, packed_header: i64, bayt, NUL, dolgu }` (24 bayt); dize işaretçisi
/// `&tablo[b].ch`dir (`tablo + b*24 + 16`).
pub const AsciiChar = extern struct {
    rc: i64,
    header: i64,
    ch: u8,
    nul: u8 = 0,
    pad: [6]u8 = .{0} ** 6,
};

pub export var nox_ascii_chars: [128]AsciiChar = blk: {
    var t: [128]AsciiChar = undefined;
    for (&t, 0..) |*e, i| {
        e.* = .{
            .rc = abi_layout.PINNED_REFCOUNT,
            .header = abi_layout.packStrHeader(1, abi_layout.STR_ASCII_TRUE),
            .ch = @intCast(i),
        };
    }
    break :blk t;
};

/// Stdlib fazı §G: `s[i]` string indekslemesinin çalışma zamanı desteği.
/// Sınır KONTROLÜ BURADA yapılMAZ — codegen'in `genIndex`i (QBE'de
/// `nox_str_char_count`+karşılaştırma ile) `idx`nin GEÇERLİ olduğunu
/// ÖNCEDEN doğrular. `idx`. CODEPOINT'e (Unicode "karakter") KADAR
/// `std.unicode.Utf8View` İLE yürür. GEÇERSİZ UTF-8 baytlara (ör.
/// `nox.fs`den gelen Latin-1 dosya İçeriği) karşı GÜVENLİ bir geri
/// düşüş: doğrulama BAŞARISIZ olursa HAM bayt semantiğine düşülür.
/// TEK karakterlik YENİ bir ARC'lı `str` döner — ascii-durumu o TEK
/// çıkarılan karakterden ZATEN biliniyor (SIFIR ek tarama maliyeti).
pub export fn nox_str_char_at(rt: ?*anyopaque, s: ?[*:0]const u8, idx: i64) ?[*:0]u8 {
    const p = s orelse return null;
    if (idx < 0) return null;
    // v1.142.18: ASCII dizelerde O(1) (ascii durumu başlıkta önbellekli) — önceden her çağrı tüm
    // dizeyi UTF-8 doğruluyor ve indekse kadar yürüyordu (O(n)): alan üzerinden `self.src[self.pos]`
    // döngüsü 120 KB'ta 3.85 s sürüyordu.
    if (ensureAsciiResolved(p)) {
        const len: usize = @intCast(strByteLen(p));
        if (@as(usize, @intCast(idx)) >= len) return null;
        return @ptrCast(&nox_ascii_chars[p[@intCast(idx)]].ch);
    }
    const bytes = nox_str_slice(p);
    if (std.unicode.Utf8View.init(bytes)) |view| {
        var it = view.iterator();
        var i: i64 = 0;
        while (it.nextCodepointSlice()) |slice| {
            if (i == idx) {
                const ascii_state: u64 = if (slice.len == 1) ASCII_TRUE else ASCII_FALSE;
                return allocStr(rt, slice, ascii_state);
            }
            i += 1;
        }
        return null;
    } else |_| {
        if (@as(usize, @intCast(idx)) >= bytes.len) return null;
        const byte = bytes[@intCast(idx)];
        const ascii_state: u64 = if (byte < 0x80) ASCII_TRUE else ASCII_FALSE;
        return allocStr(rt, bytes[@intCast(idx)..][0..1], ascii_state);
    }
}

/// `for c in s` (v1.148.0): `s`in her karakterini (UTF-8 codepoint; geçersiz UTF-8'de bayt semantiği, `nox_str_char_at` ile
/// aynı) TEK karakterlik bir `str` olarak içeren yeni bir `list[str]` döner (liste düzeni: 8 bayt uzunluk + 8 bayt kapasite +
/// eleman işaretçileri). ASCII karakterler paylaşılan pinned tablodan gelir (tahsis yok).
pub export fn nox_str_chars(rt: ?*anyopaque, s: ?[*:0]const u8) ?*anyopaque {
    const p = s orelse return null;
    const bytes = nox_str_slice(p);
    const ascii = ensureAsciiResolved(p);
    const valid = ascii or std.unicode.utf8ValidateSlice(bytes);
    const count: usize = if (valid and !ascii) (std.unicode.utf8CountCodepoints(bytes) catch bytes.len) else bytes.len;
    const raw = arc.nox_rc_alloc(rt, 16 + 8 * count) orelse return null;
    const base: [*]u8 = @ptrCast(raw);
    @as(*align(1) i64, @ptrCast(base)).* = @intCast(count);
    @as(*align(1) i64, @ptrCast(base + 8)).* = @intCast(count);
    var out_i: usize = 0;
    if (valid) {
        var it = std.unicode.Utf8View.initUnchecked(bytes).iterator();
        while (it.nextCodepointSlice()) |slice| : (out_i += 1) {
            const elem: ?[*:0]u8 = if (slice.len == 1)
                @ptrCast(&nox_ascii_chars[slice[0]].ch)
            else
                allocStr(rt, slice, ASCII_FALSE);
            @as(*align(1) i64, @ptrCast(base + 16 + 8 * out_i)).* = @bitCast(@as(isize, @intCast(@intFromPtr(elem))));
        }
    } else {
        for (bytes, 0..) |b, i| {
            const elem: ?[*:0]u8 = if (b < 0x80) @ptrCast(&nox_ascii_chars[b].ch) else allocStr(rt, bytes[i..][0..1], ASCII_FALSE);
            @as(*align(1) i64, @ptrCast(base + 16 + 8 * i)).* = @bitCast(@as(isize, @intCast(@intFromPtr(elem))));
        }
    }
    return raw;
}

/// Bulundu (bkz. proje belleği "UTF-8 farkındalığı" görevi): `len(s)`
/// codepoint sayar (bayt sayısı, "café" İçin YANLIŞ olurdu: 5, BEKLENEN
/// 4). Artık ÖNCE `ensureAsciiResolved`e danışır — string ASCII İSE
/// (çözülmüş ya da bu çağrıda İLK KEZ çözülmüş OLSUN) O(1) bayt-uzunluğu
/// DOĞRUDAN codepoint sayısına eşittir, GERÇEK UTF-8 taramasına GEREK
/// YOKTUR; SADECE ascii-DEĞİLSE `std.unicode.utf8CountCodepoints`e düşülür.
pub export fn nox_str_char_count(s: ?[*:0]const u8) i64 {
    const p = s orelse return 0;
    if (ensureAsciiResolved(p)) return @intCast(strByteLen(p));
    const bytes = nox_str_slice(p);
    const count = std.unicode.utf8CountCodepoints(bytes) catch return @intCast(bytes.len);
    return @intCast(count);
}

/// `compiler/codegen_qbe/optimizations.zig`nin `enterStrLenCacheScope`si
/// BU fonksiyonu döngüye girmeden HEMEN ÖNCE BİR KEZ çağırıp sonucu
/// önbelleğe alır — artık `ensureAsciiResolved` ÜZERİNDEN O(1) (İLK
/// çağrıda tek seferlik bir tarama + HEADER'A önbellekleme, sonraki
/// TÜM çağrılar — BAŞKA bir döngü/fonksiyon İÇİNDEN OLSA BİLE — O(1)).
pub export fn nox_str_is_ascii(s: ?[*:0]const u8) i64 {
    const p = s orelse return 1;
    return if (ensureAsciiResolved(p)) 1 else 0;
}

test "nox_str_char_at gecerli indekste dogru karakteri doner (ASCII)" {
    const asap = @import("alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const hello = allocStr(rt, "hello", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, hello);

    const c0 = nox_str_char_at(rt, hello, 0) orelse return error.ConvFailed;
    defer nox_str_release(rt, c0);
    try std.testing.expectEqualStrings("h", std.mem.sliceTo(c0, 0));

    const c4 = nox_str_char_at(rt, hello, 4) orelse return error.ConvFailed;
    defer nox_str_release(rt, c4);
    try std.testing.expectEqualStrings("o", std.mem.sliceTo(c4, 0));
}

test "nox_str_char_at cok baytli UTF-8 karakteri BOLMEDEN dogru doner" {
    const asap = @import("alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    // "café" -- 'é' = 2 baytlik UTF-8 (0xC3 0xA9), toplam 5 bayt, 4 codepoint.
    const cafe = allocStr(rt, "café", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, cafe);
    const c3 = nox_str_char_at(rt, cafe, 3) orelse return error.ConvFailed;
    defer nox_str_release(rt, c3);
    try std.testing.expectEqualStrings("é", std.mem.sliceTo(c3, 0));

    // "日本語" -- her biri 3 baytlik UTF-8, toplam 9 bayt, 3 codepoint.
    const nihon = allocStr(rt, "日本語", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, nihon);
    const c1 = nox_str_char_at(rt, nihon, 1) orelse return error.ConvFailed;
    defer nox_str_release(rt, c1);
    try std.testing.expectEqualStrings("本", std.mem.sliceTo(c1, 0));
}

test "nox_str_char_count ASCII'de bayt-uzunluguyla ayni (O(1) yoldan), cok baytli UTF-8'de codepoint sayar" {
    const asap = @import("alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const hello = allocStr(rt, "hello", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, hello);
    try std.testing.expectEqual(@as(i64, 5), nox_str_char_count(hello));

    const cafe = allocStr(rt, "café", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, cafe);
    try std.testing.expectEqual(@as(i64, 4), nox_str_char_count(cafe));

    const nihon = allocStr(rt, "日本語", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, nihon);
    try std.testing.expectEqual(@as(i64, 3), nox_str_char_count(nihon));

    const empty = allocStr(rt, "", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, empty);
    try std.testing.expectEqual(@as(i64, 0), nox_str_char_count(empty));
}

test "nox_str_is_ascii ASCII dizelerde 1, cok baytli UTF-8 iceren dizelerde 0 doner" {
    const asap = @import("alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const hello = allocStr(rt, "hello", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, hello);
    try std.testing.expectEqual(@as(i64, 1), nox_str_is_ascii(hello));

    const empty = allocStr(rt, "", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, empty);
    try std.testing.expectEqual(@as(i64, 1), nox_str_is_ascii(empty));

    const cafe = allocStr(rt, "café", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, cafe);
    try std.testing.expectEqual(@as(i64, 0), nox_str_is_ascii(cafe));

    const nihon = allocStr(rt, "日本語", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, nihon);
    try std.testing.expectEqual(@as(i64, 0), nox_str_is_ascii(nihon));
}

test "ascii-durumu ONCEDEN bilinen (ASCII_TRUE/ASCII_FALSE) bir str icin ensureAsciiResolved taramayi hic yapmadan onbellekten okur" {
    const asap = @import("alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    // nox_int_to_str: ASCII_TRUE onceden sabitlenir.
    const n = nox_int_to_str(rt, 42) orelse return error.ConvFailed;
    defer nox_str_release(rt, n);
    try std.testing.expectEqual(@as(u64, ASCII_TRUE), strAsciiState(n));
    try std.testing.expectEqual(@as(i64, 1), nox_str_is_ascii(n));
}

test "ASCII_UNKNOWN ile insa edilen bir str, ilk erisimde COZULUP HEADER'A yazilir (sonraki cagrilar O(1))" {
    const asap = @import("alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const s = allocStr(rt, "hello", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, s);
    try std.testing.expectEqual(@as(u64, ASCII_UNKNOWN), strAsciiState(s));
    try std.testing.expectEqual(@as(i64, 1), nox_str_is_ascii(s));
    // ensureAsciiResolved SONUCU onbelleklemis olmali:
    try std.testing.expectEqual(@as(u64, ASCII_TRUE), strAsciiState(s));
}

test "nox_str_concat ascii bayragini 4 durumda da dogru turetir (kisa-devre, tarama yok)" {
    const asap = @import("alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const ascii_a = nox_int_to_str(rt, 1) orelse return error.ConvFailed; // ASCII_TRUE
    defer nox_str_release(rt, ascii_a);
    const ascii_b = nox_int_to_str(rt, 2) orelse return error.ConvFailed; // ASCII_TRUE
    defer nox_str_release(rt, ascii_b);
    const unknown = allocStr(rt, "x", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, unknown);
    const non_ascii = allocStr(rt, "é", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, non_ascii);
    _ = nox_str_is_ascii(non_ascii); // ASCII_FALSE olarak COZUP onbellekler.

    // ascii + ascii -> ascii (kisa-devre, TARAMASIZ).
    const r1 = nox_str_concat(rt, ascii_a, ascii_b) orelse return error.ConcatFailed;
    defer nox_str_release(rt, r1);
    try std.testing.expectEqual(@as(u64, ASCII_TRUE), strAsciiState(r1));

    // ascii + bilinmiyor -> bilinmiyor (TARAMA ZORLANMAZ).
    const r2 = nox_str_concat(rt, ascii_a, unknown) orelse return error.ConcatFailed;
    defer nox_str_release(rt, r2);
    try std.testing.expectEqual(@as(u64, ASCII_UNKNOWN), strAsciiState(r2));

    // ascii + ascii-degil -> ascii-degil (KISA-DEVRE).
    const r3 = nox_str_concat(rt, ascii_a, non_ascii) orelse return error.ConcatFailed;
    defer nox_str_release(rt, r3);
    try std.testing.expectEqual(@as(u64, ASCII_FALSE), strAsciiState(r3));

    // bilinmiyor + bilinmiyor -> bilinmiyor.
    const r4 = nox_str_concat(rt, unknown, unknown) orelse return error.ConcatFailed;
    defer nox_str_release(rt, r4);
    try std.testing.expectEqual(@as(u64, ASCII_UNKNOWN), strAsciiState(r4));
}

/// Bulundu (bkz. proje belleği "4 yeni stdlib modülü" planı, nox.url):
/// `byte_at`i GÜVENLE bayt-bayt gezmek İçin HAM BAYT SAYISI (`strlen`)
/// gerekiyordu — artık O(1) header okuması.
pub export fn nox_str_byte_len(s: ?[*:0]const u8) i64 {
    const p = s orelse return 0;
    return @intCast(strByteLen(p));
}

/// Faz EE.1 (bkz. nox-teknik-spesifikasyon.md §3.61) — `nox_str_char_at`
/// İLE AYNI "çağıran ÖNCEDEN sınırı doğruladı" sözleşmesi, ama HİÇBİR
/// TAHSİS YAPMAZ: ham bayt değerini doğrudan bir `int` olarak döner —
/// header'a HİÇ bakmaz (çağıranın ÖNCEDEN doğruladığı ham bayt indeksi
/// üzerinde doğrudan `p[idx]`), bu YÜZDEN başlıksız (bare) bir işaretçiyle
/// BİLE güvenlidir.
pub export fn nox_str_byte_at(s: ?[*:0]const u8, idx: i64) i64 {
    const p = s orelse return 0;
    if (idx < 0) return 0;
    return p[@intCast(idx)];
}

test "nox_str_byte_at gecerli indekste dogru bayti tahsissiz doner" {
    try std.testing.expectEqual(@as(i64, 'h'), nox_str_byte_at("hello", 0));
    try std.testing.expectEqual(@as(i64, 'o'), nox_str_byte_at("hello", 4));
}

/// `nox_str_byte_at`nin TERSİ (bkz. proje belleği "4 yeni stdlib modülü"
/// planı, nox.url) — HAM bir bayt DEĞERİNİ (0-255) TEK karakterlik bir
/// `str`e çevirir. **Bilinçli v1 kapsamı**: `b` HER ZAMAN TEK bir HAM BAYT
/// olarak yazılır (0-255 aralığı DIŞI `0`a KIRPILIR). **Bulundu (test
/// yazarken)**: `b == 0` (KIRPILMIŞ geçersiz girdi DAHİL) HER ZAMAN BOŞ
/// bir `str` üretir, "tek baytlı" DEĞİL — Nox'un TÜM string temsili
/// NUL-sonlandırmalı (C-tarzı) OLDUĞUNDAN gömülü bir NUL bayt asla
/// TEMSİL EDİLEMEZ. Ascii-durumu tek çıktı baytından ZATEN biliniyor
/// (SIFIR ek tarama).
pub export fn nox_char_from_byte(rt: ?*anyopaque, b: i64) ?[*:0]u8 {
    const byte: u8 = if (b < 0 or b > 255) 0 else @intCast(b);
    if (byte == 0) return allocStr(rt, &.{}, ASCII_TRUE);
    const ascii_state: u64 = if (byte < 0x80) ASCII_TRUE else ASCII_FALSE;
    return allocStr(rt, &[_]u8{byte}, ascii_state);
}

test "nox_char_from_byte gecerli baytlardan tek karakterlik str uretir" {
    const asap = @import("alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    const s1 = nox_char_from_byte(rt, 'A') orelse return error.ConvFailed;
    defer nox_str_release(rt, s1);
    try std.testing.expectEqualStrings("A", std.mem.span(s1));
    const s2 = nox_char_from_byte(rt, 0xC3) orelse return error.ConvFailed;
    defer nox_str_release(rt, s2);
    try std.testing.expectEqual(@as(usize, 1), std.mem.span(s2).len);
    // Kırpılan (0-255 dışı) girdi 0'a düşer — NUL-sonlandırmalı temsil
    // GÖMÜLÜ bir NUL bayt TAŞIYAMADIĞINDAN bu HER ZAMAN boş bir `str`
    // üretir (bkz. fonksiyonun belge notu) — "tek bayt" DEĞİL.
    const s3 = nox_char_from_byte(rt, 300) orelse return error.ConvFailed;
    defer nox_str_release(rt, s3);
    try std.testing.expectEqual(@as(usize, 0), std.mem.span(s3).len);
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
    const asap = @import("alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const valid = allocStr(rt, "42", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, valid);
    try std.testing.expectEqual(@as(i32, 1), nox_str_is_valid_int(valid));
    try std.testing.expectEqual(@as(i64, 42), nox_str_to_int(valid));

    const invalid = allocStr(rt, "abc", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, invalid);
    try std.testing.expectEqual(@as(i32, 0), nox_str_is_valid_int(invalid));
}

test "nox_str_is_valid_float/nox_str_to_float gecerli/gecersiz girdiyi ayirt eder" {
    const asap = @import("alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const valid = allocStr(rt, "3.5", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, valid);
    try std.testing.expectEqual(@as(i32, 1), nox_str_is_valid_float(valid));
    try std.testing.expectEqual(@as(f64, 3.5), nox_str_to_float(valid));

    const invalid = allocStr(rt, "abc", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, invalid);
    try std.testing.expectEqual(@as(i32, 0), nox_str_is_valid_float(invalid));
}

test "nox_str_release: refcount sıfıra düşünce gerçekten serbest bırakır (sızıntı yok, DebugAllocator doğrular)" {
    const asap = @import("alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const a = allocStr(rt, "a", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, a);
    const b = allocStr(rt, "b", ASCII_UNKNOWN) orelse return error.AllocFailed;
    defer nox_str_release(rt, b);

    const result = nox_str_concat(rt, a, b) orelse return error.ConcatFailed;
    arc.nox_rc_retain(strArcPtr(result));
    nox_str_release(rt, result); // refcount: 1 — hâlâ canlı
    nox_str_release(rt, result); // refcount: 0 — serbest bırakıldı
}

test "v1.142.17: nox_str_append — yerinde büyüme, alias'ta kopya, büyük bloklarda kapasite üssü, doğru serbest bırakma" {
    const asap = @import("alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer {
        const state: *asap.RuntimeState = @ptrCast(@alignCast(rt));
        _ = state;
        asap.nox_runtime_deinit(rt);
    }
    const a1 = nox_str_from_bytes(rt, "ab") orelse return error.AllocFailed;
    var s: [*:0]u8 = a1;
    const piece = nox_str_from_bytes(rt, "xy") orelse return error.AllocFailed;
    defer nox_str_release(rt, piece);
    // alias: ikinci sahip VARKEN ekleme eski bloğu bozmamalı
    arc.nox_rc_retain(strArcPtr(s));
    const alias = s;
    s = nox_str_append(rt, s, piece).?;
    try std.testing.expect(s != alias);
    try std.testing.expectEqualStrings("ab", std.mem.sliceTo(alias, 0));
    try std.testing.expectEqualStrings("abxy", std.mem.sliceTo(s, 0));
    nox_str_release(rt, alias);
    // münhasır ve büyüyen: yüzlerce ekleme sonrası içerik ve uzunluk doğru
    var i: usize = 0;
    while (i < 5000) : (i += 1) s = nox_str_append(rt, s, piece).?;
    try std.testing.expectEqual(@as(u64, 4 + 5000 * 2), strByteLen(s));
    try std.testing.expectEqualStrings("abxyxy", std.mem.sliceTo(s, 0)[0..6]);
    try std.testing.expectEqual(@as(u8, 0), std.mem.sliceTo(s, 0).ptr[strByteLen(s)]);
    // kendini ekleme
    const t = nox_str_from_bytes(rt, "qq") orelse return error.AllocFailed;
    var tt: [*:0]u8 = t;
    tt = nox_str_append(rt, tt, tt).?;
    try std.testing.expectEqualStrings("qqqq", std.mem.sliceTo(tt, 0));
    nox_str_release(rt, tt);
    nox_str_release(rt, s);
}

/// v1.153.0: Python dilim çözümlemesi — `len` elemanlı bir dizi için `[lo:hi:step]`in (başlangıç, eleman sayısı, adım)ı. Sınırlar
/// Python gibi sıkıştırılır (hata yok); adım 0 çağıran tarafından önceden reddedilmelidir (burada 1'e düşer).
pub const SliceSpec = struct { start: i64, count: usize, step: i64 };

pub fn computeSlice(len_u: usize, lo_in: i64, has_lo: bool, hi_in: i64, has_hi: bool, step_in: i64, has_step: bool) SliceSpec {
    const len: i64 = @intCast(len_u);
    const step: i64 = if (has_step and step_in != 0) step_in else 1;
    var lo: i64 = undefined;
    var hi: i64 = undefined;
    if (step > 0) {
        lo = if (has_lo) lo_in else 0;
        hi = if (has_hi) hi_in else len;
        if (lo < 0) {
            lo += len;
            if (lo < 0) lo = 0;
        } else if (lo > len) lo = len;
        if (hi < 0) {
            hi += len;
            if (hi < 0) hi = 0;
        } else if (hi > len) hi = len;
        const count: i64 = if (hi > lo) @divTrunc(hi - lo + step - 1, step) else 0;
        return .{ .start = lo, .count = @intCast(count), .step = step };
    }
    lo = if (has_lo) lo_in else len - 1;
    hi = if (has_hi) hi_in else -1;
    if (has_lo) {
        if (lo < 0) {
            lo += len;
            if (lo < 0) lo = -1;
        } else if (lo >= len) lo = len - 1;
    }
    if (has_hi) {
        if (hi < 0) {
            hi += len;
            if (hi < 0) hi = -1;
        } else if (hi >= len) hi = len - 1;
    }
    const nstep = -step;
    const count: i64 = if (lo > hi) @divTrunc(lo - hi + nstep - 1, nstep) else 0;
    return .{ .start = lo, .count = @intCast(count), .step = step };
}

/// `s[lo:hi:step]` (codepoint tabanlı; geçersiz UTF-8'de bayt semantiği, `nox_str_char_at` ile aynı). Her zaman YENİ bir `str` döner.
pub export fn nox_str_slice_op(rt: ?*anyopaque, s: ?[*:0]const u8, lo: i64, has_lo: i32, hi: i64, has_hi: i32, step: i64, has_step: i32) ?[*:0]u8 {
    const p = s orelse return null;
    const bytes = nox_str_slice(p);
    const ascii = ensureAsciiResolved(p);
    const valid = ascii or std.unicode.utf8ValidateSlice(bytes);
    const byte_mode = ascii or !valid;
    const n_units: usize = if (byte_mode) bytes.len else (std.unicode.utf8CountCodepoints(bytes) catch bytes.len);
    const sp = computeSlice(n_units, lo, has_lo != 0, hi, has_hi != 0, step, has_step != 0);
    const result_ascii: u64 = if (ascii) ASCII_TRUE else ASCII_UNKNOWN;
    if (sp.count == 0) return allocStr(rt, "", ASCII_TRUE);
    if (byte_mode) {
        if (sp.step == 1) return allocStr(rt, bytes[@intCast(sp.start)..][0..sp.count], result_ascii);
        const buf = nox_str_alloc_buf(rt, sp.count) orelse return null;
        var k: usize = 0;
        var idx: i64 = sp.start;
        while (k < sp.count) : ({
            k += 1;
            idx += sp.step;
        }) buf[k] = bytes[@intCast(idx)];
        if (ascii) setStrAsciiState(@ptrCast(buf), ASCII_TRUE);
        return @ptrCast(buf);
    }
    // Geçerli, ASCII olmayan UTF-8: codepoint dilimleri iki geçişte işlenir.
    var total: usize = 0;
    var j: i64 = 0;
    var it = std.unicode.Utf8View.initUnchecked(bytes).iterator();
    while (it.nextCodepointSlice()) |cp| : (j += 1) {
        if (selectedAt(sp, j)) total += cp.len;
    }
    const buf = nox_str_alloc_buf(rt, total) orelse return null;
    var write_pos: usize = 0;
    var write_end: usize = total;
    j = 0;
    it = std.unicode.Utf8View.initUnchecked(bytes).iterator();
    while (it.nextCodepointSlice()) |cp| : (j += 1) {
        if (!selectedAt(sp, j)) continue;
        if (sp.step > 0) {
            @memcpy(buf[write_pos..][0..cp.len], cp);
            write_pos += cp.len;
        } else {
            write_end -= cp.len;
            @memcpy(buf[write_end..][0..cp.len], cp);
        }
    }
    return @ptrCast(buf);
}

fn selectedAt(sp: SliceSpec, j: i64) bool {
    if (sp.step > 0) {
        if (j < sp.start) return false;
        const d = j - sp.start;
        return @mod(d, sp.step) == 0 and @divExact(d, sp.step) < @as(i64, @intCast(sp.count));
    }
    if (j > sp.start) return false;
    const d = sp.start - j;
    return @mod(d, -sp.step) == 0 and @divExact(d, -sp.step) < @as(i64, @intCast(sp.count));
}

/// `s * n` / `n * s` — `s`in `n` kez art arda birleşimi (`n <= 0` → boş dize), tek tahsisle.
pub export fn nox_str_repeat(rt: ?*anyopaque, s: ?[*:0]const u8, n: i64) ?[*:0]u8 {
    const p = s orelse return null;
    if (n <= 0) return allocStr(rt, "", ASCII_TRUE);
    const bytes = nox_str_slice(p);
    const count: usize = @intCast(n);
    const buf = nox_str_alloc_buf(rt, bytes.len * count) orelse return null;
    var i: usize = 0;
    while (i < count) : (i += 1) @memcpy(buf[i * bytes.len ..][0..bytes.len], bytes);
    if (ensureAsciiResolved(p)) setStrAsciiState(@ptrCast(buf), ASCII_TRUE);
    return @ptrCast(buf);
}

test "v1.153.0: computeSlice Python dilim semantiği" {
    const t = std.testing;
    // [1,2,3,4,5][1:4] → start 1 count 3
    var sp = computeSlice(5, 1, true, 4, true, 0, false);
    try t.expectEqual(@as(i64, 1), sp.start);
    try t.expectEqual(@as(usize, 3), sp.count);
    // negatif sınırlar: [-2:] → start 3 count 2
    sp = computeSlice(5, -2, true, 0, false, 0, false);
    try t.expectEqual(@as(i64, 3), sp.start);
    try t.expectEqual(@as(usize, 2), sp.count);
    // aralık dışı: [10:20] → boş; [-100:100] → hepsi
    sp = computeSlice(5, 10, true, 20, true, 0, false);
    try t.expectEqual(@as(usize, 0), sp.count);
    sp = computeSlice(5, -100, true, 100, true, 0, false);
    try t.expectEqual(@as(usize, 5), sp.count);
    // adım 2: [::2] → 0,2,4
    sp = computeSlice(5, 0, false, 0, false, 2, true);
    try t.expectEqual(@as(usize, 3), sp.count);
    // adım -1: [::-1] → start 4 count 5
    sp = computeSlice(5, 0, false, 0, false, -1, true);
    try t.expectEqual(@as(i64, 4), sp.start);
    try t.expectEqual(@as(usize, 5), sp.count);
    // [3:0:-1] → 3,2,1
    sp = computeSlice(5, 3, true, 0, true, -1, true);
    try t.expectEqual(@as(usize, 3), sp.count);
    // [::-2] on len 5 → 4,2,0
    sp = computeSlice(5, 0, false, 0, false, -2, true);
    try t.expectEqual(@as(usize, 3), sp.count);
    // boş dizi
    sp = computeSlice(0, 0, false, 0, false, -1, true);
    try t.expectEqual(@as(usize, 0), sp.count);
}

/// v1.156.0 (`s.find(sub)`): `needle`ın ilk konumunun CODEPOINT indeksi (yoksa -1; boş needle → 0). ASCII dizelerde bayt indeksi = codepoint indeksi.
pub export fn nox_str_find(s: ?[*:0]const u8, needle: ?[*:0]const u8) i64 {
    const p = s orelse return -1;
    const bytes = nox_str_slice(p);
    const nb = nox_str_slice(needle orelse return -1);
    if (nb.len == 0) return 0;
    const idx = fastIndexOf(bytes, nb) orelse return -1;
    if (ensureAsciiResolved(p)) return @intCast(idx);
    const cps = std.unicode.utf8CountCodepoints(bytes[0..idx]) catch idx;
    return @intCast(cps);
}

/// `s.count(sub)`: çakışmayan geçiş sayısı; boş `sub` → `len(s) + 1` (Python).
pub export fn nox_str_count(s: ?[*:0]const u8, needle: ?[*:0]const u8) i64 {
    const p = s orelse return 0;
    const bytes = nox_str_slice(p);
    const nb = nox_str_slice(needle orelse return 0);
    if (nb.len == 0) return nox_str_char_count(p) + 1;
    var n: i64 = 0;
    var start: usize = 0;
    while (start <= bytes.len) {
        const pos = fastIndexOf(bytes[start..], nb) orelse break;
        n += 1;
        start += pos + nb.len;
    }
    return n;
}

/// `s.isdigit()`(0) / `isalpha()`(1) / `isalnum()`(2) / `isspace()`(3) / `isupper()`(4) / `islower()`(5) — ASCII; boş dize → 0.
pub export fn nox_str_char_class(s: ?[*:0]const u8, kind: i32) i64 {
    const bytes = nox_str_slice(s orelse return 0);
    if (bytes.len == 0) return 0;
    var cased = false;
    for (bytes) |c| {
        const ok = switch (kind) {
            0 => std.ascii.isDigit(c),
            1 => std.ascii.isAlphabetic(c),
            2 => std.ascii.isAlphanumeric(c),
            3 => std.ascii.isWhitespace(c),
            4 => blk: {
                if (std.ascii.isLower(c)) break :blk false;
                if (std.ascii.isUpper(c)) cased = true;
                break :blk true;
            },
            5 => blk: {
                if (std.ascii.isUpper(c)) break :blk false;
                if (std.ascii.isLower(c)) cased = true;
                break :blk true;
            },
            else => false,
        };
        if (!ok) return 0;
    }
    if (kind == 4 or kind == 5) return if (cased) 1 else 0;
    return 1;
}

/// `s.ljust(w[, f])`(0) / `rjust`(1) / `center`(2) / `zfill`(3): codepoint genişliğine göre doldurma; `fill` boş/null ise boşluk (`zfill` için '0'),
/// çok karakterliyse ilk codepoint kullanılır. `zfill` işaret ('+'/'-') duyarlıdır.
pub export fn nox_str_just(rt: ?*anyopaque, s: ?[*:0]const u8, width: i64, fill: ?[*:0]const u8, mode: i32) ?[*:0]u8 {
    const p = s orelse return null;
    const bytes = nox_str_slice(p);
    const cur: i64 = nox_str_char_count(p);
    if (width <= cur) return allocStr(rt, bytes, if (ensureAsciiResolved(p)) ASCII_TRUE else ASCII_UNKNOWN);
    const pad: usize = @intCast(width - cur);
    var fill_bytes: []const u8 = if (mode == 3) "0" else " ";
    if (fill) |f| {
        const fb = nox_str_slice(f);
        if (fb.len > 0) {
            const l = std.unicode.utf8ByteSequenceLength(fb[0]) catch 1;
            fill_bytes = fb[0..@min(@as(usize, l), fb.len)];
        }
    }
    var left: usize = 0;
    var sign_len: usize = 0;
    switch (mode) {
        0 => left = 0,
        1 => left = pad,
        2 => left = pad / 2 + (pad & @as(usize, @intCast(width)) & 1),
        else => {
            left = pad;
            if (bytes.len > 0 and (bytes[0] == '-' or bytes[0] == '+')) sign_len = 1;
        },
    }
    const right = pad - left;
    const total = bytes.len + pad * fill_bytes.len;
    const buf = nox_str_alloc_buf(rt, total) orelse return null;
    var w: usize = 0;
    if (mode == 3) {
        @memcpy(buf[0..sign_len], bytes[0..sign_len]);
        w = sign_len;
    }
    var i: usize = 0;
    while (i < left) : (i += 1) {
        @memcpy(buf[w..][0..fill_bytes.len], fill_bytes);
        w += fill_bytes.len;
    }
    const body = if (mode == 3) bytes[sign_len..] else bytes;
    @memcpy(buf[w..][0..body.len], body);
    w += body.len;
    i = 0;
    while (i < right) : (i += 1) {
        @memcpy(buf[w..][0..fill_bytes.len], fill_bytes);
        w += fill_bytes.len;
    }
    return @ptrCast(buf);
}

test "v1.156.0: nox_str_find/count/char_class/just" {
    const asap = @import("alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    const s = allocStr(rt, "héllo hello", ASCII_UNKNOWN) orelse return error.Failed;
    defer nox_str_release(rt, s);
    const sub = allocStr(rt, "llo", ASCII_UNKNOWN) orelse return error.Failed;
    defer nox_str_release(rt, sub);
    try std.testing.expectEqual(@as(i64, 2), nox_str_find(s, sub));
    try std.testing.expectEqual(@as(i64, 2), nox_str_count(s, sub));
    const d = allocStr(rt, "12a", ASCII_UNKNOWN) orelse return error.Failed;
    defer nox_str_release(rt, d);
    try std.testing.expectEqual(@as(i64, 0), nox_str_char_class(d, 0));
    const d2 = allocStr(rt, "123", ASCII_UNKNOWN) orelse return error.Failed;
    defer nox_str_release(rt, d2);
    try std.testing.expectEqual(@as(i64, 1), nox_str_char_class(d2, 0));
    const neg = allocStr(rt, "-42", ASCII_UNKNOWN) orelse return error.Failed;
    defer nox_str_release(rt, neg);
    const z = nox_str_just(rt, neg, 6, null, 3) orelse return error.Failed;
    defer nox_str_release(rt, z);
    try std.testing.expectEqualStrings("-00042", nox_str_slice(z));
    const ab = allocStr(rt, "ab", ASCII_UNKNOWN) orelse return error.Failed;
    defer nox_str_release(rt, ab);
    const c = nox_str_just(rt, ab, 5, null, 2) orelse return error.Failed;
    defer nox_str_release(rt, c);
    try std.testing.expectEqualStrings("  ab ", nox_str_slice(c));
}
