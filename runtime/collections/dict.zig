//! `dict[K, V]` çalışma zamanı desteği — stdlib fazı §C (bkz. nox-teknik-
//! spesifikasyon.md). `dict`in Nox tarafındaki temsili opak bir `ptr`dir
//! (bkz. codegen_qbe/codegen.zig'in `HeapKind.dict`i).
//!
//! **Faz FF.3 (bkz. nox-teknik-spesifikasyon.md §3.62) — TAM ARC-yönetimli
//! (`str`/`list`/`class` İLE AYNI model):** ÖNCEDEN `dict`, `Task`/`Channel`
//! İLE AYNI "tek sahiplilik, kapsam sonunda KOŞULSUZ yıkım" modelindeydi —
//! GERÇEK, KANITLANMIŞ bir sallanan-işaretçi/çift-serbest-bırakma
//! açığıydı: bir dict adlandırılmış bir yerele bağlanıp SONRA bir sınıf
//! alanına GEÇİRİLİRSE (`self.headers = headers`), yerelin kapsam-sonu
//! temizliği dict'i KOŞULSUZ yok ederdi — sınıf alanı SALLANAN bir
//! işaretçi kalırdı (bkz. `tests/golden/codegen_cases/dict_field_outlives_
//! local_no_dangling.nox`, GERÇEK bir SIGSEGV İLE doğrulandı). `nox_dict_
//! new` artık `nox_rc_alloc` İLE (gizli bir refcount başlığı ALTINDA)
//! tahsis eder; `nox_dict_release` (ESKİ `nox_dict_destroy`) `nox_rc_
//! predecrement`e GÖRE koşulludur — `runtime/str.zig`nin `nox_str_
//! release`iyle BİREBİR AYNI desen. Retain, DİĞER ARC-yönetimli tipler
//! GİBİ, ÇAĞIRAN (codegen) tarafında `emitInlineRetain`/`retainIfAliasing`
//! ile YAPILIR (bu dosya HÂLÂ bir retain YAPMAZ — yalnızca `.dict`in
//! KENDİ konteyner refcount'u ARTIK VAR, İÇİNDEKİ `str` anahtar/
//! değerlerin AYRI retain disiplini DEĞİŞMEDİ, bkz. aşağıdaki not).
//!
//! **Dil stabilizasyonu fazı §M.3 — gerçek hash tablosu (v1'in doğrusal
//! aramasının YERİNE):** `entries: ArrayListUnmanaged(Entry)` (sıralı, DEĞER
//! deposu — `stdlib fazı §D.1`in Keşif 4'ünde `nox.http`in Zig kabuğunun
//! DOĞRUDAN `@import` edip `entries`i gezdiği ALAN, İSİM/ŞEKİL DEĞİŞMEDEN
//! KORUNDU) ARTIK yalnızca DEĞER deposu — arama BUNUN üzerinde DEĞİL, AYRI
//! bir `index: std.HashMapUnmanaged(i64, usize, StrOrIntContext, ...)`
//! (anahtar → `entries` İÇİNDEKİ konum) üzerinden O(1) ortalama sürede
//! yapılır. `str` anahtarlar İÇİN `StrOrIntContext`in `hash`/`eql`i
//! POINTER'ı DEĞİL, İŞARET ETTİĞİ İÇERİĞİ (`strcmp`/hash) kullanır (D.1'in
//! Keşif 4'ünün AYNI gerekçesi). **İnce bir tuzak (ve düzeltmesi):** bir
//! `str` anahtar İÇERİK olarak AYNI ama POINTER olarak FARKLI bir değerle
//! "üzerine yazıldığında" (`nox_dict_set`), `index`in KENDİ sakladığı
//! anahtar (ESKİ pointer) da YENİ pointer'la DEĞİŞTİRİLMELİDİR — aksi
//! halde `nox_dict_set` ESKİ anahtarı `nox_str_release` İLE serbest
//! bıraktıktan SONRA, `index`in İÇİNDE HÂLÂ o (artık SERBEST bırakılmış)
//! pointer saklı kalır ve GELECEKTEKİ bir arama (İÇERİK-tabanlı `eql`
//! HER karşılaştırmada pointer'ı DEREFERANS ettiğinden) bir kullanım-
//! sonrası-serbest-bırakma olurdu — bu yüzden üzerine yazma yolu her
//! zaman `removeContext`+`putContext` (yalnızca değer GÜNCELLEME DEĞİL)
//! yapar.
//!
//! **ARC sahiplik disiplini (DEĞİŞMEDİ):** anahtar/değerlerin `str` olup
//! olmadığı HER ÇAĞRIDA (`nox_dict_set`/`get`/`contains`/`release`) açık
//! bir `i32` bayrağı (`key_is_str`/`value_is_str`) olarak GEÇİRİLİR —
//! codegen bunu `dict[K, V]`nin derleme zamanında bilinen K/V tipinden
//! üretir (bkz. `DictInfo`nun belge notu). Retain, ÇAĞIRAN (codegen)
//! tarafında `retainIfAliasing` ile YAPILIR (bu dosya bir retain YAPMAZ) —
//! yalnızca ÜZERİNE YAZILAN/silinen ESKİ `str` değerler burada
//! `nox_str_release` ile serbest bırakılır (`genAssign`in "eskiyi oku,
//! serbest bırak, yeniyi yaz" deseniyle AYNI disiplin).

const std = @import("std");
const asap = @import("../alloc/asap.zig");
const str_mod = @import("../str.zig");
const arc = @import("../alloc/arc.zig");

/// `pub` — stdlib fazı §D.1 (Keşif 4): `nox.http`in Zig kabuğu, bir
/// `dict[str, str]`in içeriğini (ör. yanıt başlıklarını inşa ederken)
/// Nox'ta HENÜZ olmayan bir "dict iterasyonu" sözdizimine (`for k in d`)
/// GEREK KALMADAN, bu struct'ı DOĞRUDAN `@import` edip `entries`i
/// gezerek okur/yazar. §M.3'ten SONRA da AYNI şekilde çalışır — `entries`
/// HÂLÂ TÜM anahtar/değer çiftlerinin SIRALI, eksiksiz bir listesi.
pub const Entry = struct { key: i64, value: i64 };

fn keysEqual(key_is_str: bool, a: i64, b: i64) bool {
    if (!key_is_str) return a == b;
    if (a == b) return true;
    if (a == 0 or b == 0) return false;
    const pa: [*:0]const u8 = @ptrFromInt(@as(usize, @bitCast(a)));
    const pb: [*:0]const u8 = @ptrFromInt(@as(usize, @bitCast(b)));
    return std.mem.orderZ(u8, pa, pb) == .eq;
}

/// `index`in hash tablosu Context'i — `key_is_str` ÇALIŞMA ZAMANINDA
/// (Dict'in KENDİSİNE göre) belirlendiğinden comptime-sabit bir Context
/// KULLANILAMAZ, bu yüzden HER çağrıda (`getContext`/`putContext`/
/// `removeContext`) `Dict.key_is_str`den türetilen bir örneği argüman
/// olarak GEÇİRİLİR (`std.HashMapUnmanaged`in *Context varyantları TAM
/// BUNUN İÇİN var).
const StrOrIntContext = struct {
    key_is_str: bool,

    pub fn hash(self: @This(), key: i64) u64 {
        if (!self.key_is_str) return std.hash.Wyhash.hash(0, std.mem.asBytes(&key));
        if (key == 0) return 0;
        const p: [*:0]const u8 = @ptrFromInt(@as(usize, @bitCast(key)));
        return std.hash.Wyhash.hash(0, std.mem.sliceTo(p, 0));
    }

    pub fn eql(self: @This(), a: i64, b: i64) bool {
        return keysEqual(self.key_is_str, a, b);
    }
};

const IndexMap = std.HashMapUnmanaged(i64, usize, StrOrIntContext, std.hash_map.default_max_load_percentage);

pub const Dict = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    index: IndexMap = .empty,
    key_is_str: bool,
};

fn payloadToStrPtr(v: i64) ?[*:0]u8 {
    if (v == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(v)));
}

fn findIndex(d: *Dict, key: i64) ?usize {
    return d.index.getContext(key, .{ .key_is_str = d.key_is_str });
}

/// Yeni, boş bir dict tahsis eder. `key_is_str`, `d[key]`/`.contains(key)`
/// gibi TÜM sonraki çağrılarda da AYNI şekilde (codegen tarafından, `dict[K,V]`nin
/// derleme zamanında bilinen `K`sinden) tutarlı olarak geçirilmelidir.
pub export fn nox_dict_new(rt: ?*anyopaque, key_is_str: i32) ?*anyopaque {
    const raw = arc.nox_rc_alloc(rt, @sizeOf(Dict)) orelse return null;
    const d: *Dict = @ptrCast(@alignCast(raw));
    d.* = .{ .key_is_str = key_is_str != 0 };
    return d;
}

/// Bir anahtar/değer çiftini ekler ya da (ZATEN varsa) üzerine yazar.
/// Üzerine yazma: ESKİ anahtar/değer (`str` iseler) serbest bırakılır,
/// YENİ anahtar/değer (çağıran tarafından ZATEN retain edilmiş — bkz. modül
/// üstü not) saklanır.
pub export fn nox_dict_set(rt: ?*anyopaque, dp: ?*anyopaque, key_is_str: i32, value_is_str: i32, key: i64, value: i64) void {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return));
    const d: *Dict = @ptrCast(@alignCast(dp orelse return));
    const ctx: StrOrIntContext = .{ .key_is_str = key_is_str != 0 };
    if (findIndex(d, key)) |i| {
        const old = d.entries.items[i];
        if (value_is_str != 0) str_mod.nox_str_release(rt, payloadToStrPtr(old.value));
        // `index`in KENDİ sakladığı anahtar (ESKİ pointer, İÇERİK olarak
        // AYNI ama pointer FARKLI olabilir) YENİ anahtarla DEĞİŞTİRİLİR
        // (yalnızca DEĞER GÜNCELLENMEZ) — bkz. modül üstü not, "ince tuzak".
        _ = d.index.removeContext(old.key, ctx);
        d.index.putContext(state.allocator(), key, i, ctx) catch {};
        if (key_is_str != 0) str_mod.nox_str_release(rt, payloadToStrPtr(old.key));
        d.entries.items[i] = .{ .key = key, .value = value };
    } else {
        const new_index = d.entries.items.len;
        d.entries.append(state.allocator(), .{ .key = key, .value = value }) catch return;
        d.index.putContext(state.allocator(), key, new_index, ctx) catch {
            _ = d.entries.pop();
        };
    }
}

/// Bir anahtarın değerini okur — BORROWED bir okumadır (`str` değer İSE
/// retain EDİLMEZ, dict sahipliği korur — `list[T]` eleman okumasıyla AYNI
/// semantik). Anahtar YOKSA `0` döner (v1 kapsamı: Python'ın `KeyError`ı
/// YOK — bkz. nox-teknik-spesifikasyon.md §3.28, bilinçli sınırlama).
pub export fn nox_dict_get(rt: ?*anyopaque, dp: ?*anyopaque, key_is_str: i32, key: i64) i64 {
    _ = rt;
    _ = key_is_str;
    const d: *Dict = @ptrCast(@alignCast(dp orelse return 0));
    if (findIndex(d, key)) |i| return d.entries.items[i].value;
    return 0;
}

pub export fn nox_dict_contains(dp: ?*anyopaque, key_is_str: i32, key: i64) i32 {
    _ = key_is_str;
    const d: *Dict = @ptrCast(@alignCast(dp orelse return 0));
    return if (findIndex(d, key) != null) 1 else 0;
}

pub export fn nox_dict_len(dp: ?*anyopaque) i64 {
    const d: *Dict = @ptrCast(@alignCast(dp orelse return 0));
    return @intCast(d.entries.items.len);
}

/// Faz FF.3 — `dict`in refcount'unu bir azaltır; sıfıra/altına düşerse
/// KENDİSİNİ (ve İÇİNDEKİ TÜM `str` anahtar/değerleri, varsa) GERÇEKTEN
/// yıkar — `runtime/str.zig`nin `nox_str_release`iyle (`nox_rc_
/// predecrement`e göre koşullu) BİREBİR AYNI desen (ESKİ `nox_dict_
/// destroy`nin AKSİNE, artık KOŞULSUZ değil — bkz. modül üstü not).
pub export fn nox_dict_release(rt: ?*anyopaque, dp: ?*anyopaque, key_is_str: i32, value_is_str: i32) void {
    const ptr = dp orelse return;
    if (arc.nox_rc_predecrement(ptr) == 0) return;
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return));
    const d: *Dict = @ptrCast(@alignCast(ptr));
    for (d.entries.items) |e| {
        if (value_is_str != 0) str_mod.nox_str_release(rt, payloadToStrPtr(e.value));
        if (key_is_str != 0) str_mod.nox_str_release(rt, payloadToStrPtr(e.key));
    }
    d.entries.deinit(state.allocator());
    d.index.deinit(state.allocator());
    arc.nox_rc_free_payload(rt, ptr, @sizeOf(Dict));
}

test "nox_dict_new/set/get/contains/len/destroy — int anahtar/değer" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const d = nox_dict_new(rt, 0) orelse return error.NewFailed;
    nox_dict_set(rt, d, 0, 0, 1, 100);
    nox_dict_set(rt, d, 0, 0, 2, 200);
    try std.testing.expectEqual(@as(i64, 100), nox_dict_get(rt, d, 0, 1));
    try std.testing.expectEqual(@as(i64, 200), nox_dict_get(rt, d, 0, 2));
    try std.testing.expectEqual(@as(i64, 0), nox_dict_get(rt, d, 0, 999));
    try std.testing.expectEqual(@as(i32, 1), nox_dict_contains(d, 0, 1));
    try std.testing.expectEqual(@as(i32, 0), nox_dict_contains(d, 0, 999));
    try std.testing.expectEqual(@as(i64, 2), nox_dict_len(d));

    // Üzerine yazma: aynı anahtar, YENİ değer.
    nox_dict_set(rt, d, 0, 0, 1, 999);
    try std.testing.expectEqual(@as(i64, 999), nox_dict_get(rt, d, 0, 1));
    try std.testing.expectEqual(@as(i64, 2), nox_dict_len(d));

    nox_dict_release(rt, d, 0, 0);
}

test "nox_dict — str anahtar İÇERİK eşitliğiyle bulunur (pointer eşitliği DEĞİL), üzerine yazma eskiyi serbest bırakır" {
    const str_lib = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const d = nox_dict_new(rt, 1) orelse return error.NewFailed;

    const k1 = str_lib.nox_str_concat(rt, "ana", "htar") orelse return error.ConcatFailed; // "anahtar"
    const v1 = str_lib.nox_str_concat(rt, "deger", "1") orelse return error.ConcatFailed;
    nox_dict_set(rt, d, 1, 1, @bitCast(@intFromPtr(k1)), @bitCast(@intFromPtr(v1)));

    // AYNI İÇERİKLİ ama FARKLI POINTER'lı ikinci bir anahtar — content-based
    // eşleşme sayesinde AYNI slotu güncellemeli (yeni bir eleman EKLENMEMELİ).
    const k2 = str_lib.nox_str_concat(rt, "ana", "htar") orelse return error.ConcatFailed;
    const v2 = str_lib.nox_str_concat(rt, "deger", "2") orelse return error.ConcatFailed;
    nox_dict_set(rt, d, 1, 1, @bitCast(@intFromPtr(k2)), @bitCast(@intFromPtr(v2)));

    try std.testing.expectEqual(@as(i64, 1), nox_dict_len(d));
    const got = nox_dict_get(rt, d, 1, @bitCast(@intFromPtr(k2)));
    const got_ptr: [*:0]u8 = @ptrFromInt(@as(usize, @bitCast(got)));
    try std.testing.expectEqualStrings("deger2", std.mem.sliceTo(got_ptr, 0));

    // k2/v2'nin sahipliği dict'e geçti (set İÇİNDE retain edilmedi — testin
    // KENDİSİ çağıran rolünü oynuyor, bu yüzden burada MANUEL retain
    // GEREKMEDİ: k1/v1 üzerine yazıldığı için dict tarafından ZATEN serbest
    // bırakıldı, k2/v2 dict'in TEK sahibi).
    nox_dict_release(rt, d, 1, 1);
}

// Faz FF.3 (bkz. nox-teknik-spesifikasyon.md §3.62) — `dict`in ARTIK
// PAYLAŞILABİLİR (birden fazla sahipli) olduğunun DOĞRUDAN kanıtı:
// `nox_rc_retain` İLE refcount 1→2 çıkarılır, İLK `nox_dict_release`
// (2→1) dict'i HÂLÂ CANLI/OKUNABİLİR bırakmalıdır (ERKEN serbest
// bırakılmamalı — ESKİ, ARC-yönetimli OLMAYAN modelde bu senaryo
// ANLAMSIZDI, `nox_dict_destroy` HER ZAMAN koşulsuz yıkardı), İKİNCİ
// `nox_dict_release` (1→0) GERÇEKTEN serbest bırakmalıdır — `asap.
// nox_runtime_deinit`in ALTINDAKİ DebugAllocator, iki release'in TAM
// DENGEDE olmadığı (bir eksik/fazla) durumda sızıntı/çift-serbest-
// bırakma raporlayıp bu testi ÇÖKERTİRDİ.
test "nox_dict — nox_rc_retain + İKİ nox_dict_release: birinci HÂLÂ canlı bırakır, ikinci GERÇEKTEN serbest bırakır" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const d = nox_dict_new(rt, 0) orelse return error.NewFailed;
    nox_dict_set(rt, d, 0, 0, 1, 42);

    arc.nox_rc_retain(d);

    // Birinci release: refcount 2 → 1, dict HÂLÂ canlı/okunabilir olmalı.
    nox_dict_release(rt, d, 0, 0);
    try std.testing.expectEqual(@as(i64, 42), nox_dict_get(rt, d, 0, 1));
    try std.testing.expectEqual(@as(i64, 1), nox_dict_len(d));

    // İkinci release: refcount 1 → 0, GERÇEKTEN serbest bırakılır.
    nox_dict_release(rt, d, 0, 0);
}
