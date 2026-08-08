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
    const bytes: [*]u8 = @constCast(@ptrCast(str_ptr));
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
    h.* = abi_layout.packStrHeader(len, state);
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

/// `ptr`nin refcount'unu bir azaltır; sıfıra/altına düşerse belleği
/// (`STR_HEADER_SIZE + bayt-uzunluğu + 1` — `nox_rc_alloc`a verilenle AYNI
/// hesap) gerçekten serbest bırakır. Pinned (literal) dizeler İÇİN
/// predecrement asla sıfıra düşmeyeceğinden bu HİÇBİR ZAMAN gerçekten
/// serbest bırakmaz.
pub export fn nox_str_release(rt: ?*anyopaque, ptr: ?[*:0]u8) void {
    const p = ptr orelse return;
    const arc_ptr = strArcPtr(p);
    if (arc.nox_rc_predecrement(arc_ptr) != 0) {
        const len = strByteLen(p);
        arc.nox_rc_free_payload(rt, arc_ptr, STR_HEADER_SIZE + len + 1);
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
    const len = strByteLen(ptr);
    const arc_ptr = strArcPtr(ptr);
    arc.nox_rc_free_payload(rt, arc_ptr, STR_HEADER_SIZE + len + 1);
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
