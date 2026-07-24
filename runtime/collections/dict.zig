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
const builtin = @import("builtin");
const asap = @import("../alloc/asap.zig");
const str_mod = @import("../str.zig");
const arc = @import("../alloc/arc.zig");
const abi_layout = @import("abi_layout");
const LIST_HEADER_SIZE = abi_layout.LIST_HEADER_SIZE;
const FIELD_SLOT_SIZE = abi_layout.FIELD_SLOT_SIZE;

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

/// Güvenlik bulgusu M-3 (bkz. güvenlik raporu) — DÜZELTİLDİ: `StrOrIntContext.
/// hash` ÖNCEDEN `std.hash.Wyhash`i HER ZAMAN SABİT `seed=0` İLE
/// çağırıyordu. `nox.http`nin `HttpRequest.headers` alanı TAM OLARAK
/// `dict[str,str]` OLDUĞUNDAN (bkz. `SMALL_MAP_THRESHOLD`in belge notu —
/// 8'den fazla başlık `index` hash-tabanlı yola geçer), bu SABİT/BİLİNEN
/// tohum, saldırganın Wyhash algoritmasını VE tohumu BİLEREK ÖNCEDEN
/// çakışan anahtarlar (ör. çok sayıda başlık adı) İNŞA ETMESİNE — bir Nox
/// HTTP sunucusunun dict işlemlerini O(1) ortalamadan O(n) en-kötü-duruma
/// düşürmesine (klasik hash-flooding/algoritmik-karmaşıklık DoS'u) —
/// OLANAK TANIYORDU. Python/Rust'ın hashmap tohumunu SÜREÇ (BURADA: iş
/// parçacığı) başına RASTGELELEŞTİRMESİYLE AYNI ilkeyle DÜZELTİLDİ: HER
/// iş parçacığının kendi `threadlocal` (bkz. `nox.random`nin `g_prng`si
/// İLE AYNI "gerçek OS iş parçacıkları bir dict'i PAYLAŞMAZ" gerekçesi —
/// bir `Dict`, `arc_owner_tid`nin ZATEN zorladığı gibi HER ZAMAN TEK bir
/// iş parçacığına aittir) RASTGELE tohumu, İLK dict-hash işleminde BİR
/// KEZ üretilir VE o iş parçacığının TÜM sonraki dict işlemleri İçin
/// YENİDEN KULLANILIR. `std.crypto.random` BU Zig sürümünde YOK —
/// `nox.os`nin `setenv` deneyiminde OLDUĞU GİBİ (bkz. `runtime/stdlib_
/// shims/os.zig`nin belge notu), macOS'un libc'sinin ZATEN GÜVENLE
/// bağladığı ham `std.c.arc4random_buf`ı (OS'un GÜVENLİ rastgelelik
/// kaynağına dayanır) DOĞRUDAN kullanılır.
threadlocal var g_hash_seed: u64 = 0;
threadlocal var g_hash_seed_init: bool = false;

/// Faz LL.4 (bkz. nox-teknik-spesifikasyon.md §3.71): `std.c.arc4random_buf`
/// Windows'ta `.windows => {}` İLE (`.linux`nin `fstat`i GİBİ) void'dir —
/// `advapi32.dll`nin `RtlGenRandom`i (dışa açık ismi `SystemFunction036`,
/// Windows 2000'den beri STABİL, GÜVENİLİR bir OS-seviyesi CSPRNG) YERİNE
/// kullanılır.
fn secureRandomBuf(buf: []u8) void {
    if (builtin.os.tag == .windows) {
        _ = SystemFunction036(buf.ptr, @intCast(buf.len));
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}
extern "advapi32" fn SystemFunction036(buf: [*]u8, len: u32) callconv(.c) u8;

fn hashSeed() u64 {
    if (!g_hash_seed_init) {
        var buf: [8]u8 = undefined;
        secureRandomBuf(&buf);
        g_hash_seed = std.mem.readInt(u64, &buf, .little);
        g_hash_seed_init = true;
    }
    return g_hash_seed;
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
        if (!self.key_is_str) return std.hash.Wyhash.hash(hashSeed(), std.mem.asBytes(&key));
        if (key == 0) return 0;
        const p: [*:0]const u8 = @ptrFromInt(@as(usize, @bitCast(key)));
        return std.hash.Wyhash.hash(hashSeed(), std.mem.sliceTo(p, 0));
    }

    pub fn eql(self: @This(), a: i64, b: i64) bool {
        return keysEqual(self.key_is_str, a, b);
    }
};

const IndexMap = std.HashMapUnmanaged(i64, usize, StrOrIntContext, std.hash_map.default_max_load_percentage);

/// Faz HH.5 (bkz. nox-teknik-spesifikasyon.md §3.68): `entries.items.len`
/// bu eşiğin ALTINDAYKEN `index` hashmap'i HİÇ İNŞA EDİLMEZ — DOĞRUSAL
/// tarama (bkz. `findIndex`) küçük N İçin hash'lemekten (`Wyhash` + `str`
/// anahtarlar İçin `strlen`/karşılaştırma + hashmap ekleme/büyütme
/// ek yükü) DAHA HIZLIDIR VE `nox_dict_set`in `index.putContext`
/// çağrısını da TAMAMEN ATLAR. HTTP header/`{"x":"y"}` gibi TREND
/// dict'lerin BÜYÜK ÇOĞUNLUĞU (1-5 giriş) bu eşiğin HİÇ ÜSTÜNE ÇIKMAZ.
const SMALL_MAP_THRESHOLD: usize = 8;

pub const Dict = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    index: IndexMap = .empty,
    key_is_str: bool,
    /// `true` OLUNCA `index` ARTIK GÜNCEL VE YETKİLİDİR (bkz. `findIndex`/
    /// `nox_dict_set`) — bir KEZ `true` olduktan SONRA asla `false`'a
    /// DÖNMEZ (bu dict'te silme YOK, yalnızca ekleme/üzerine yazma —
    /// eleman sayısı asla AZALMAZ).
    index_built: bool = false,
};

fn payloadToStrPtr(v: i64) ?[*:0]u8 {
    if (v == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(v)));
}

/// `index_built` DEĞİLKEN `entries`i DOĞRUSAL tarar (bkz. `SMALL_MAP_
/// THRESHOLD`in belge notu) — `keysEqual`, `StrOrIntContext.eql`in
/// KULLANDIĞI AYNI İÇERİK-tabanlı karşılaştırmadır.
fn findIndexLinear(d: *Dict, key: i64) ?usize {
    for (d.entries.items, 0..) |e, i| {
        if (keysEqual(d.key_is_str, e.key, key)) return i;
    }
    return null;
}

fn findIndex(d: *Dict, key: i64) ?usize {
    if (!d.index_built) return findIndexLinear(d, key);
    return d.index.getContext(key, .{ .key_is_str = d.key_is_str });
}

/// `entries`i (TÜMÜNÜ, MEVCUT haliyle) `index`e AKTARIR VE `index_built`i
/// `true` yapar — `SMALL_MAP_THRESHOLD` AŞILDIĞINDA (bkz. `nox_dict_set`)
/// TEK SEFERLİK çağrılır. `putContext` BAŞARISIZ olursa (OOM) `index_built`
/// `false` KALIR — `findIndex`/`nox_dict_set` bu durumda DOĞRUSAL taramaya
/// GÜVENLE geri düşmeye DEVAM eder (yalnızca performans kaybı, DOĞRULUK
/// ETKİLENMEZ).
fn buildIndex(d: *Dict, allocator: std.mem.Allocator) void {
    const ctx: StrOrIntContext = .{ .key_is_str = d.key_is_str };
    for (d.entries.items, 0..) |e, i| {
        d.index.putContext(allocator, e.key, i, ctx) catch return;
    }
    d.index_built = true;
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
        // Faz HH.5: `index_built` DEĞİLSE `index` BOŞTUR — GÜNCELLEMEYE
        // GEREK YOK (doğrusal tarama `entries`i DOĞRUDAN okur).
        if (d.index_built) {
            _ = d.index.removeContext(old.key, ctx);
            d.index.putContext(state.allocator(), key, i, ctx) catch {};
        }
        if (key_is_str != 0) str_mod.nox_str_release(rt, payloadToStrPtr(old.key));
        d.entries.items[i] = .{ .key = key, .value = value };
    } else {
        d.entries.append(state.allocator(), .{ .key = key, .value = value }) catch return;
        if (d.index_built) {
            const new_index = d.entries.items.len - 1;
            d.index.putContext(state.allocator(), key, new_index, ctx) catch {
                _ = d.entries.pop();
            };
        } else if (d.entries.items.len > SMALL_MAP_THRESHOLD) {
            // Faz HH.5: eşik AŞILDI — `index` TEK SEFERLİK inşa edilir,
            // BUNDAN SONRAKİ TÜM aramalar O(1) hash'e geçer.
            buildIndex(d, state.allocator());
        }
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

/// Faz III.6 (bkz. nox-teknik-spesifikasyon.md §3.69) — `keys()`/`values()`
/// ORTAK yardımcısı: `entries`i (SIRALI, `nox_dict_len`in saydığı AYNI
/// eleman sayısınca) `list[T]`nin ham bayt düzenine (`nox_fs_read_dir_raw`
/// İLE AYNI el-yapımı desen: 8 bayt uzunluk + 8 bayt kapasite + N eleman)
/// KOPYALAR. `elem_size` (4: `bool`/`w`, 8: `int`/`str`/`float`/`l`/`d`)
/// codegen'in `DictInfo.key_qtype`/`value_qtype`sinden ÖNCEDEN bilinir —
/// `Entry.key`/`.value` HER ZAMAN 8 baytlık bir "payload" (bkz. `codegen.
/// zig`nin `toPayload`sı, `bool` DAHİL HER tip `nox_dict_set`e ÖNCE 8
/// bayta genişletilerek geçirilir) OLDUĞUNDAN, 4 baytlık `list[bool]`
/// İÇİN düşük 32 bit ALINIR (`toPayload`nin `extuw`si SIFIR-genişlettiğinden
/// KAYIPSIZ round-trip). `is_str` İSE HER elemanın refcount'u BİR ARTIRILIR
/// (`nox_rc_retain`) — dict KENDİ referansını KORUR, YENİ liste BAĞIMSIZ
/// bir İKİNCİ sahip olur (`nox_dict_release`/liste'nin KENDİ release'i
/// birbirinden bağımsız, İKİSİ de kendi payını serbest bırakır).
fn buildEntryList(rt: ?*anyopaque, d: *Dict, is_str: bool, elem_size: i64, want_key: bool) ?*anyopaque {
    const n = d.entries.items.len;
    const esz: usize = @intCast(elem_size);
    const raw = arc.nox_rc_alloc(rt, LIST_HEADER_SIZE + esz * n) orelse return null;
    const bytes: [*]u8 = @ptrCast(raw);
    @as(*align(1) i64, @ptrCast(bytes)).* = @intCast(n);
    @as(*align(1) i64, @ptrCast(bytes + 8)).* = @intCast(n);
    for (d.entries.items, 0..) |e, i| {
        const payload = if (want_key) e.key else e.value;
        if (is_str and payload != 0) arc.nox_rc_retain(payloadToStrPtr(payload).?);
        const slot = bytes + LIST_HEADER_SIZE + esz * i;
        if (esz == 4) {
            @as(*align(1) i32, @ptrCast(slot)).* = @truncate(payload);
        } else {
            @as(*align(1) i64, @ptrCast(slot)).* = payload;
        }
    }
    return @ptrCast(bytes);
}

/// `d.keys() -> list[K]` — bkz. `buildEntryList`in belge notu.
pub export fn nox_dict_keys(rt: ?*anyopaque, dp: ?*anyopaque, key_is_str: i32, key_elem_size: i64) ?*anyopaque {
    const d: *Dict = @ptrCast(@alignCast(dp orelse return null));
    return buildEntryList(rt, d, key_is_str != 0, key_elem_size, true);
}

/// `d.values() -> list[V]` — bkz. `buildEntryList`in belge notu.
pub export fn nox_dict_values(rt: ?*anyopaque, dp: ?*anyopaque, value_is_str: i32, value_elem_size: i64) ?*anyopaque {
    const d: *Dict = @ptrCast(@alignCast(dp orelse return null));
    return buildEntryList(rt, d, value_is_str != 0, value_elem_size, false);
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

// Faz HH.5 (bkz. nox-teknik-spesifikasyon.md §3.68): `SMALL_MAP_THRESHOLD`
// (8) AŞILANA kadar `index_built = false` (DOĞRUSAL tarama) kalmalı,
// eşik AŞILINCA `index_built = true`e GEÇMELİ VE `index` TÜM mevcut
// girdileri İÇERMELİDİR — HER İKİ modda da (eşik ÖNCESİ/SONRASI) `get`/
// `contains`/üzerine-yazma DOĞRU sonuç vermeli.
test "nox_dict — SMALL_MAP_THRESHOLD asilana kadar dogrusal tarama, sonra index insa edilir" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const d = nox_dict_new(rt, 0) orelse return error.NewFailed;
    const dict_ptr: *Dict = @ptrCast(@alignCast(d));

    // Eşiğe KADAR (dahil) ekle — index_built HÂLÂ false olmalı.
    var i: usize = 0;
    while (i < SMALL_MAP_THRESHOLD) : (i += 1) {
        const ii: i64 = @intCast(i);
        nox_dict_set(rt, d, 0, 0, ii, ii * 10);
    }
    try std.testing.expectEqual(@as(i64, @intCast(SMALL_MAP_THRESHOLD)), nox_dict_len(d));
    try std.testing.expect(!dict_ptr.index_built);
    // Doğrusal tarama yolu HÂLÂ doğru sonuç vermeli.
    try std.testing.expectEqual(@as(i64, 30), nox_dict_get(rt, d, 0, 3));
    try std.testing.expectEqual(@as(i32, 1), nox_dict_contains(d, 0, 3));
    try std.testing.expectEqual(@as(i32, 0), nox_dict_contains(d, 0, 999));

    // Üzerine yazma (HÂLÂ doğrusal modda) — index güncellemesi GEREKMEZ,
    // yalnızca `entries` içindeki slot değişir.
    nox_dict_set(rt, d, 0, 0, 3, 3000);
    try std.testing.expectEqual(@as(i64, 3000), nox_dict_get(rt, d, 0, 3));
    try std.testing.expectEqual(@as(i64, @intCast(SMALL_MAP_THRESHOLD)), nox_dict_len(d));

    // Eşiği AŞAN (SMALL_MAP_THRESHOLD + 1. eleman) ekleme — index GERÇEKTEN
    // inşa EDİLMELİ (bkz. `buildIndex`).
    nox_dict_set(rt, d, 0, 0, 999, 9990);
    try std.testing.expect(dict_ptr.index_built);
    try std.testing.expectEqual(@as(i64, @intCast(SMALL_MAP_THRESHOLD + 1)), nox_dict_len(d));

    // İndeks-tabanlı yol da (hem eşikten ÖNCE eklenen hem SONRA eklenen
    // anahtarlar İçin) doğru sonuç vermeli.
    try std.testing.expectEqual(@as(i64, 3000), nox_dict_get(rt, d, 0, 3));
    try std.testing.expectEqual(@as(i64, 9990), nox_dict_get(rt, d, 0, 999));
    try std.testing.expectEqual(@as(i64, 0), nox_dict_get(rt, d, 0, 500)); // hiç eklenmedi

    // İndeks modunda ÜZERİNE yazma da (removeContext+putContext yolu) doğru
    // çalışmalı.
    nox_dict_set(rt, d, 0, 0, 999, 12345);
    try std.testing.expectEqual(@as(i64, 12345), nox_dict_get(rt, d, 0, 999));
    try std.testing.expectEqual(@as(i64, @intCast(SMALL_MAP_THRESHOLD + 1)), nox_dict_len(d));

    nox_dict_release(rt, d, 0, 0);
}

test "Faz III.6: nox_dict_keys/nox_dict_values int anahtar/deger icin dogru list olusturur (8 baytlik eleman)" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const d = nox_dict_new(rt, 0) orelse return error.NewFailed;
    nox_dict_set(rt, d, 0, 0, 1, 100);
    nox_dict_set(rt, d, 0, 0, 2, 200);

    const keys_list = nox_dict_keys(rt, d, 0, 8) orelse return error.Failed;
    const kbytes: [*]u8 = @ptrCast(keys_list);
    try std.testing.expectEqual(@as(i64, 2), @as(*align(1) i64, @ptrCast(kbytes)).*);
    try std.testing.expectEqual(@as(i64, 2), @as(*align(1) i64, @ptrCast(kbytes + 8)).*);
    try std.testing.expectEqual(@as(i64, 1), @as(*align(1) i64, @ptrCast(kbytes + LIST_HEADER_SIZE)).*);
    try std.testing.expectEqual(@as(i64, 2), @as(*align(1) i64, @ptrCast(kbytes + 24)).*);
    _ = arc.nox_rc_predecrement(keys_list);
    arc.nox_rc_free_payload(rt, keys_list, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * 2);

    const values_list = nox_dict_values(rt, d, 0, 8) orelse return error.Failed;
    const vbytes: [*]u8 = @ptrCast(values_list);
    try std.testing.expectEqual(@as(i64, 100), @as(*align(1) i64, @ptrCast(vbytes + LIST_HEADER_SIZE)).*);
    try std.testing.expectEqual(@as(i64, 200), @as(*align(1) i64, @ptrCast(vbytes + 24)).*);
    _ = arc.nox_rc_predecrement(values_list);
    arc.nox_rc_free_payload(rt, values_list, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * 2);

    nox_dict_release(rt, d, 0, 0);
}

test "Faz III.6: nox_dict_values bool degerler icin 4 baytlik eleman round-trip yapar (dogru truncate/extend)" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const d = nox_dict_new(rt, 0) orelse return error.NewFailed;
    // `toPayload`in `w`->`l` `extuw` deseni (bkz. codegen.zig) TAKLİT
    // edilir: bool `true`/`false` ÖNCE 8 bayta sifir-genisletilerek saklanir.
    nox_dict_set(rt, d, 0, 0, 1, 1); // true
    nox_dict_set(rt, d, 0, 0, 2, 0); // false

    const values_list = nox_dict_values(rt, d, 0, 4) orelse return error.Failed;
    const vbytes: [*]u8 = @ptrCast(values_list);
    try std.testing.expectEqual(@as(i64, 2), @as(*align(1) i64, @ptrCast(vbytes)).*);
    try std.testing.expectEqual(@as(i32, 1), @as(*align(1) i32, @ptrCast(vbytes + LIST_HEADER_SIZE)).*);
    try std.testing.expectEqual(@as(i32, 0), @as(*align(1) i32, @ptrCast(vbytes + 20)).*);
    _ = arc.nox_rc_predecrement(values_list);
    arc.nox_rc_free_payload(rt, values_list, LIST_HEADER_SIZE + 4 * 2);

    nox_dict_release(rt, d, 0, 0);
}

test "Faz III.6: nox_dict_keys str anahtarlari retain eder — dict VE list bagimsiz serbest birakilabilir" {
    const str_lib = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const d = nox_dict_new(rt, 1) orelse return error.NewFailed;
    const k1 = str_lib.nox_str_concat(rt, "anah", "tar1") orelse return error.ConcatFailed;
    const v1 = str_lib.nox_str_concat(rt, "deg", "er1") orelse return error.ConcatFailed;
    nox_dict_set(rt, d, 1, 1, @bitCast(@intFromPtr(k1)), @bitCast(@intFromPtr(v1)));

    const keys_list = nox_dict_keys(rt, d, 1, 8) orelse return error.Failed;
    const kbytes: [*]u8 = @ptrCast(keys_list);
    const kptr_val = @as(*align(1) i64, @ptrCast(kbytes + LIST_HEADER_SIZE)).*;
    const kptr: [*:0]u8 = @ptrFromInt(@as(usize, @bitCast(kptr_val)));
    try std.testing.expectEqualStrings("anahtar1", std.mem.sliceTo(kptr, 0));

    // Dict ÖNCE serbest bırakılır (KENDİ anahtar/değer referansını
    // serbest bırakır) — list'in KENDİ retain'i sayesinde `kptr` HÂLÂ
    // GEÇERLİ olmalı (DebugAllocator, dict'in serbest bıraktığı belleğe
    // list'in HÂLÂ eriştiğini fark ederse çökerdi).
    nox_dict_release(rt, d, 1, 1);
    try std.testing.expectEqualStrings("anahtar1", std.mem.sliceTo(kptr, 0));

    str_lib.nox_str_release(rt, kptr);
    _ = arc.nox_rc_predecrement(keys_list);
    arc.nox_rc_free_payload(rt, keys_list, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * 1);
}

// Güvenlik bulgusu M-3 (bkz. güvenlik raporu, 20 Temmuz 2026) — DÜZELTİLDİ:
// `hashSeed`in artık SABİT `0` DÖNMEDİĞİNİ (eski, hash-flooding'e AÇIK
// davranış) VE AYNI iş parçacığı İçinde TUTARLI (memoized) OLDUĞUNU
// doğrular. `std.c.arc4random_buf`nin GERÇEK entropi KALİTESİ bu testin
// KAPSAMI DIŞINDA (OS'un KENDİ sorumluluğu) — yalnızca "artık sabit
// SIFIR/bilinen bir değer DEĞİL" doğrulanır.
test "Güvenlik M-3: hashSeed sabit 0 DEĞİL VE aynı iş parçacığı içinde TUTARLI (memoized)" {
    const s1 = hashSeed();
    const s2 = hashSeed();
    try std.testing.expectEqual(s1, s2);
    try std.testing.expect(s1 != 0);
}

// SMALL_MAP_THRESHOLD'u AŞAN (hash-tabanlı `index` yoluna GEÇEN) bir dict,
// RASTGELELEŞTİRİLMİŞ tohuma RAĞMEN doğru çalışmaya DEVAM ETMELİDİR —
// yalnızca ARAMA MEKANİZMASI değişti, DOĞRULUK DEĞİŞMEDİ.
test "Güvenlik M-3: rastgeleleştirilmiş hash tohumuyla SMALL_MAP_THRESHOLD üstü bir dict HÂLÂ doğru arama yapar" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const d = nox_dict_new(rt, 1) orelse return error.NewFailed;
    const dict_ptr: *Dict = @ptrCast(@alignCast(d));

    var i: usize = 0;
    while (i < SMALL_MAP_THRESHOLD + 5) : (i += 1) {
        const key = std.fmt.allocPrintSentinel(std.testing.allocator, "anahtar{d}", .{i}, 0) catch return error.OutOfMemory;
        defer std.testing.allocator.free(key);
        const key_str = str_mod.nox_str_concat(rt, key.ptr, "") orelse return error.ConcatFailed;
        nox_dict_set(rt, d, 1, 0, @bitCast(@intFromPtr(key_str)), @intCast(i * 10));
    }
    try std.testing.expect(dict_ptr.index_built);

    i = 0;
    while (i < SMALL_MAP_THRESHOLD + 5) : (i += 1) {
        const key = std.fmt.allocPrintSentinel(std.testing.allocator, "anahtar{d}", .{i}, 0) catch return error.OutOfMemory;
        defer std.testing.allocator.free(key);
        const key_str = str_mod.nox_str_concat(rt, key.ptr, "") orelse return error.ConcatFailed;
        defer str_mod.nox_str_release(rt, key_str);
        try std.testing.expectEqual(@as(i64, @intCast(i * 10)), nox_dict_get(rt, d, 1, @bitCast(@intFromPtr(key_str))));
    }

    nox_dict_release(rt, d, 1, 0);
}
