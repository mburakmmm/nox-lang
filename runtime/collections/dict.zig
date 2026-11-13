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
const abi_ptr = @import("../abi_ptr.zig");
const asap = @import("../alloc/asap.zig");
const str_mod = @import("../str.zig");
const arc = @import("../alloc/arc.zig");
const dispatch_registry = @import("../alloc/dispatch_registry.zig");
const abi_layout = @import("abi_layout");
const LIST_HEADER_SIZE = abi_layout.LIST_HEADER_SIZE;
const FIELD_SLOT_SIZE = abi_layout.FIELD_SLOT_SIZE;

/// Faz OO.4 (bkz. nox-teknik-spesifikasyon.md §3.85): `dict[K, class]` —
/// sınıf DEĞERLİ bir dict'in ESKİ (üzerine yazılan) ya da TÜM (release
/// sırasında) değerlerini serbest bırakmak İçİn derleyicinin ürettiği
/// `$nox_class_release_dispatch(rt, tag, p)`e (bkz. `compiler/codegen_qbe/
/// layout.zig`nin `genClassReleaseDispatch`ı) İHTİYAÇ VAR. Faz F.0.1'DEN
/// İTİBAREN `dispatch_registry`nin (bkz. onun modül üstü notu) program-
/// başlangıcında BİR KEZ kaydedilen, statik tablosu KULLANILIR (ÖNCEDEN
/// `dlsym` İLE ÇALIŞMA ZAMANINDA aranıyordu).
/// `payload`i (`Entry.key`/`.value`) bir sınıf örneği İŞARETÇİSİ olarak
/// yorumlayıp `nox_class_release_dispatch`e (tag'i KENDİ İLK `TAG_SIZE`
/// baytından okuyarak) dağıtır — `payload == 0` (hiç ATANMAMIŞ) İSE
/// hiçbir şey YAPMAZ.
/// `value_is_class` bayraklı bir değeri bırakır: sözlüğün `value_release`i varsa (list/dict değer) onunla, yoksa sınıf dağıtımıyla.
fn releaseValuePayload(rt: ?*anyopaque, d: *const Dict, payload: i64) void {
    if (payload == 0) return;
    if (d.value_release) |f| {
        f(abi_ptr.arg(rt), abi_ptr.arg(@as(*anyopaque, @ptrFromInt(@as(usize, @intCast(@as(u64, @bitCast(payload))))))));
        return;
    }
    releaseClassPayload(rt, payload);
}

/// Codegen, değeri `list[T]`/`dict[K, V]` olan bir sözlüğü kurarken çağırır (bkz. `Dict.value_release`).
pub export fn nox_dict_set_value_release(dp: ?*anyopaque, f: ?*const fn (abi_ptr.Arg, abi_ptr.Arg) callconv(.c) void) void {
    const d: *Dict = @ptrCast(@alignCast(dp orelse return));
    d.value_release = f;
}

fn releaseClassPayload(rt: ?*anyopaque, payload: i64) void {
    if (payload == 0) return;
    const p: *anyopaque = @ptrFromInt(@as(usize, @intCast(@as(u64, @bitCast(payload)))));
    const f = dispatch_registry.classReleaseFn() orelse return;
    const tag: *const i64 = @ptrCast(@alignCast(p));
    f(abi_ptr.arg(rt), tag.*, abi_ptr.arg(p));
}

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
    const pa: [*:0]const u8 = @ptrFromInt(@as(usize, @intCast(@as(u64, @bitCast(a)))));
    const pb: [*:0]const u8 = @ptrFromInt(@as(usize, @intCast(@as(u64, @bitCast(b)))));
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
/// bir `Dict`, `arc_owner_pool`nin ZATEN zorladığı gibi HER ZAMAN TEK bir
/// iş parçacığına aittir) RASTGELE tohumu, İLK dict-hash işleminde BİR
/// KEZ üretilir VE o iş parçacığının TÜM sonraki dict işlemleri İçin
/// YENİDEN KULLANILIR. `std.crypto.random` BU Zig sürümünde YOK —
/// `nox.os`nin `setenv` deneyiminde OLDUĞU GİBİ (bkz. `runtime/stdlib_
/// shims/os.zig`nin belge notu), macOS'un libc'sinin ZATEN GÜVENLE
/// bağladığı ham `std.c.arc4random_buf`ı (OS'un GÜVENLİ rastgelelik
/// kaynağına dayanır) DOĞRUDAN kullanılır.
/// Faz MN.2'de BİLİNÇLİ olarak `Fiber`e TAŞINMAMIŞTI (`nox_dict_contains`
/// `rt` ALMADIĞINDAN — bkz. git geçmişi) — Faz MN.4'te GERÇEK çapraz-
/// iş-parçacığı fiber göçü (work-stealing) AÇILDIĞINDAN, artık `Runtime
/// State`e (`asap.zig`nin `dict_hash_seed`/`dict_hash_seed_init`
/// alanları) TAŞINDI: bir `Dict`, HANGİ worker'a TAŞINIRSA taşınsın AYNI
/// `rt`ye (VE dolayısıyla AYNI tohuma) BAĞLI KALDIĞINDAN, insert/lookup
/// ARASINDA FARKLI worker'ların FARKLI tohumlar KULLANMASI (`Fiber`e
/// taşınsaydı OLACAK hata) İMKANSIZ hale gelir. Bu, `nox_dict_contains`ın
/// ABI'sine (`rt` parametresi EKLENDİ) VE onu çağıran codegen sitesine
/// dokunan, Faz MN.4'ün İLK GERÇEK codegen/checker DEĞİŞİKLİĞİDİR.
/// Faz F.0.7 (bkz. nox-teknik-spesifikasyon.md — "Kritik düzeltme #3"):
/// `secureRandomBuf`nin KOŞULSUZ `std.c.arc4random_buf`/`SystemFunction036`
/// bağımlılığı freestanding hedeflerde HİÇ mevcut DEĞİLDİR — F.0.1-F.0.5'in
/// AYNI "program-genelinde, TEK, atomik `.monotonic`" enjeksiyon deseniyle
/// bir `EntropyProvider` eklenir. VARSAYILAN (kayıt YAPILMAMIŞ HER hosted
/// program): SIFIR davranış değişikliği.
pub const EntropyProviderVTable = struct {
    fill: *const fn (ctx: ?*anyopaque, buf: []u8) void,
};
pub const EntropyProvider = struct {
    ctx: ?*anyopaque = null,
    vtable: *const EntropyProviderVTable,
};
var g_entropy_provider: std.atomic.Value(?*const EntropyProvider) = .init(null);
pub fn nox_register_entropy_provider(provider: ?*const EntropyProvider) void {
    g_entropy_provider.store(provider, .monotonic);
}

const is_freestanding = builtin.os.tag == .freestanding or builtin.os.tag == .other;

/// Faz LL.4 (bkz. nox-teknik-spesifikasyon.md §3.71): `std.c.arc4random_buf`
/// Windows'ta `.windows => {}` İLE (`.linux`nin `fstat`i GİBİ) void'dir —
/// `advapi32.dll`nin `RtlGenRandom`i (dışa açık ismi `SystemFunction036`,
/// Windows 2000'den beri STABİL, GÜVENİLİR bir OS-seviyesi CSPRNG) YERİNE
/// kullanılır. Freestanding'de (sağlayıcı KAYITLI DEĞİLSE) HİÇBİR OS
/// çağrısı YAPILMADAN sessizce döner — `hashSeed` bu durumda SABİT bir
/// tohuma düşer (v0.1 sınırı, bkz. `hashSeed`nin belge notu).
fn secureRandomBuf(buf: []u8) void {
    if (g_entropy_provider.load(.monotonic)) |p| {
        p.vtable.fill(p.ctx, buf);
        return;
    }
    if (comptime is_freestanding) return;
    if (builtin.os.tag == .windows) {
        _ = SystemFunction036(buf.ptr, @intCast(buf.len));
    } else if (builtin.os.tag == .linux) {
        linuxGetRandom(buf);
    } else if (builtin.os.tag == .wasi) {
        _ = std.os.wasi.random_get(buf.ptr, buf.len);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}
extern "advapi32" fn SystemFunction036(buf: [*]u8, len: u32) callconv(.c) u8;

/// v2.0 madde 8 (bkz. plan dosyası): BU turda GERÇEK bir çapraz-derlemeyle
/// ÖLÇÜLEREK bulundu — `std.c.arc4random_buf` Linux'ta SADECE Android YA DA
/// glibc ≥2.36 İKEN gerçek bir implementasyona sahiptir (bkz. Zig'in KENDİ
/// `std.c.zig`si), AKSİ HALDE `void` — `-target x86_64-linux-musl`/`-gnu`
/// (versiyon PİNLENMEDEN, Zig'in VARSAYILAN GENİŞ-uyumluluk tabanı) İLE
/// DERLEME hatasına yol açıyordu. `std.c.getrandom` İSE musl'da KOŞULSUZ,
/// glibc'de ≥2.25 İKEN (2017, Ubuntu 18.04+) gerçek — ÇOK DAHA GENİŞ bir
/// uyumluluk tabanı sağlar; getrandom(2) KÜÇÜK istekler İçİn ATOMİK OLSA
/// da (≤256 bayt), döngü GENEL doğruluk İçİn (`nox.crypto`nin BÜYÜK
/// istekleri DAHİL) tutulur.
fn linuxGetRandom(buf: []u8) void {
    // Bionic, `getrandom` libc sarmalayıcısını API 28'de ekler. Mobil hedef
    // API 24'tür; ham `getrandom` sistem çağrısı bu seviyede vardır.
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
        if (n <= 0) return; // en-iyi-çaba — GERÇEK bir hata sonsuz döngüye YOL AÇMAMALI
        filled += @intCast(n);
    }
}

fn hashSeed(rt: ?*anyopaque) u64 {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt.?));
    if (!state.dict_hash_seed_init) {
        if (comptime is_freestanding) {
            if (g_entropy_provider.load(.monotonic) == null) {
                // Faz F.0.7: freestanding'de KAYITLI bir EntropyProvider
                // YOKSA gerçek rastgelelik kaynağı YOK — SABİT/deterministik
                // bir tohuma düşülür (hash-flooding DoS'a karşı GÜVENSİZ,
                // gömülü/tek-kullanıcılı bağlamda kabul edilebilir bir v0.1
                // sınırı — bkz. plan dosyası).
                state.dict_hash_seed = 0xA5A5A5A5A5A5A5A5;
                state.dict_hash_seed_init = true;
                return state.dict_hash_seed;
            }
        }
        var buf: [8]u8 = undefined;
        secureRandomBuf(&buf);
        state.dict_hash_seed = std.mem.readInt(u64, &buf, .little);
        state.dict_hash_seed_init = true;
    }
    return state.dict_hash_seed;
}

/// v1.142.5 (bkz. nox-teknik-spesifikasyon.md §3.244): `int` anahtarlar
/// İçİN tohumlu, tek-geçişli bir 64-bit karıştırıcı (MurmurHash3'ün `fmix64`
/// sonlandırıcısı, tohum önceden XOR'lanır) — `Wyhash.hash(seed, asBytes(&key))`
/// genel amaçlı bayt-dizisi yolunu (uzunluk dallanması, 8 baytlık okuma
/// döngüsü) HER dict işleminde yürütüyordu; `dict[int,int]` benchmark'ında
/// profilin %16'sı. `fmix64` çığ etkisi (avalanche) iyi: her girdi biti çıktının
/// her bitini ~%50 etkiler — hash tablosunun hem alt (slot) hem üst (parmak
/// izi) bitleri için yeterli. Tohum süreç başına rastgele (`hashSeed`), yani
/// hash-flooding savunması (bkz. M-3) AYNEN korunur.
inline fn mixInt(seed: u64, key: i64) u64 {
    var k: u64 = @as(u64, @bitCast(key)) ^ seed;
    k ^= k >> 33;
    k *%= 0xff51afd7ed558ccd;
    k ^= k >> 33;
    k *%= 0xc4ceb9fe1a85ec53;
    k ^= k >> 33;
    return k;
}

/// `index`in hash tablosu Context'i — `key_is_str` ÇALIŞMA ZAMANINDA
/// (Dict'in KENDİSİNE göre) belirlendiğinden comptime-sabit bir Context
/// KULLANILAMAZ, bu yüzden HER çağrıda (`getContext`/`putContext`/
/// `removeContext`) `Dict.key_is_str`den türetilen bir örneği argüman
/// olarak GEÇİRİLİR (`std.HashMapUnmanaged`in *Context varyantları TAM
/// BUNUN İÇİN var). Faz MN.4: `rt` alanı `hashSeed`in `RuntimeState`e
/// taşınmasıyla EKLENDİ (bkz. `hashSeed`in belge notu).
const StrOrIntContext = struct {
    key_is_str: bool,
    rt: ?*anyopaque,

    pub fn hash(self: @This(), key: i64) u64 {
        if (!self.key_is_str) return mixInt(hashSeed(self.rt), key);
        if (key == 0) return 0;
        const p: [*:0]const u8 = @ptrFromInt(@as(usize, @intCast(@as(u64, @bitCast(key)))));
        return std.hash.Wyhash.hash(hashSeed(self.rt), std.mem.sliceTo(p, 0));
    }

    pub fn eql(self: @This(), a: i64, b: i64) bool {
        return keysEqual(self.key_is_str, a, b);
    }
};

/// v1.142.16: `std.HashMapUnmanaged` yerine kompakt açık adresli indeks tablosu — slot başına TEK
/// `u64`: üst 32 bit hash etiketi (hash'in düşük 32 biti, konum da bundan türer), alt 32 bit
/// `entries` indeksi + 1 (0 = boş). Anahtarlar yalnızca `entries`te yaşar (tabloda kopya yok):
/// bir arama, etiket eşleşmedikçe `entries`e hiç dokunmaz; Zig'in metadata + anahtar + değer
/// ayrı dizilerine karşı büyük tablolarda önbellek ıskası sayısı ~3 → ~2'ye iner. Doğrusal
/// problama, yük ≤ 0.5. Dict'te silme olmadığından mezar taşı yok. Büyütme anahtara dokunmaz
/// (konum etiketten türer).
const IndexTable = struct {
    slots: []u64 = &.{},
    /// Kullanılan (boş OLMAYAN: canlı + silinmiş) slot sayısı; yük çarpanı bunun üzerinden hesaplanır.
    count: usize = 0,
    /// `count` içindeki silinmiş (`DELETED`) slot sayısı. Silme mezar taşı bırakır; bir sonraki büyütme/yeniden kurma temizler.
    deleted: usize = 0,

    /// Silinmiş anahtarın slot işareti: arama bunu atlayıp zinciri sürdürür (0 = zincir biter).
    const DELETED: u64 = std.math.maxInt(u64);

    const empty: IndexTable = .{};

    fn deinit(self: *IndexTable, allocator: std.mem.Allocator) void {
        if (self.slots.len > 0) allocator.free(self.slots);
        self.* = .{};
    }

    inline fn find(self: *const IndexTable, entries: []const Entry, comptime key_is_str: bool, key: i64, h: u64) ?usize {
        if (self.slots.len == 0) return null;
        const mask = self.slots.len - 1;
        const tag: u32 = @truncate(h);
        var pos: usize = @as(usize, tag) & mask;
        while (true) {
            const s = self.slots[pos];
            if (s == 0) return null;
            if (s != DELETED and @as(u32, @truncate(s >> 32)) == tag) {
                const idx: usize = @intCast((s & 0xFFFF_FFFF) - 1);
                if (keysEqual(key_is_str, entries[idx].key, key)) return idx;
            }
            pos = (pos + 1) & mask;
        }
    }

    fn place(slots: []u64, tag: u32, idx: usize) void {
        const mask = slots.len - 1;
        var pos: usize = @as(usize, tag) & mask;
        while (slots[pos] != 0) pos = (pos + 1) & mask;
        slots[pos] = (@as(u64, tag) << 32) | @as(u64, @intCast(idx + 1));
    }

    fn grow(self: *IndexTable, allocator: std.mem.Allocator) !void {
        // Canlı slot sayısına göre büyür: çoğu slot silinmişse (`DELETED`) tabloyu şişirmek yerine aynı boyutta yeniden kurar.
        const live = self.count - self.deleted;
        const new_len: usize = if (self.slots.len == 0) 16 else if ((live + 1) * 4 > self.slots.len) self.slots.len * 2 else self.slots.len;
        const ns = try allocator.alloc(u64, new_len);
        @memset(ns, 0);
        for (self.slots) |s| {
            if (s == 0 or s == DELETED) continue;
            place(ns, @truncate(s >> 32), @intCast((s & 0xFFFF_FFFF) - 1));
        }
        if (self.slots.len > 0) allocator.free(self.slots);
        self.slots = ns;
        self.count = live;
        self.deleted = 0;
    }

    /// Anahtarın slotunu `DELETED` yapar (anahtar `entries`te hâlâ okunabilir olmalı). Bulunduysa `true`.
    fn remove(self: *IndexTable, entries: []const Entry, key_is_str: bool, key: i64, h: u64) bool {
        if (self.slots.len == 0) return false;
        const mask = self.slots.len - 1;
        const tag: u32 = @truncate(h);
        var pos: usize = @as(usize, tag) & mask;
        while (true) {
            const s = self.slots[pos];
            if (s == 0) return false;
            if (s != DELETED and @as(u32, @truncate(s >> 32)) == tag) {
                const idx: usize = @intCast((s & 0xFFFF_FFFF) - 1);
                if (keysEqual(key_is_str, entries[idx].key, key)) {
                    self.slots[pos] = DELETED;
                    self.deleted += 1;
                    return true;
                }
            }
            pos = (pos + 1) & mask;
        }
    }

    /// Anahtarın tabloda OLMADIĞI varsayılır (çağıran `find` ile doğrular).
    fn insertNew(self: *IndexTable, allocator: std.mem.Allocator, h: u64, idx: usize) !void {
        if ((self.count + 1) * 2 > self.slots.len) try self.grow(allocator);
        place(self.slots, @truncate(h), idx);
        self.count += 1;
    }
};

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
    index: IndexTable = .empty,
    key_is_str: bool,
    /// `true` OLUNCA `index` ARTIK GÜNCEL VE YETKİLİDİR (bkz. `findIndex`/
    /// `nox_dict_set`) — bir KEZ `true` olduktan SONRA asla `false`'a
    /// DÖNMEZ (bu dict'te silme YOK, yalnızca ekleme/üzerine yazma —
    /// eleman sayısı asla AZALMAZ).
    index_built: bool = false,
    /// v1.142.16: son BAŞARILI aramanın `entries` indeksi (tek girdilik önbellek). `if d.contains(k):
    /// d[k] = d[k] + 1` kalıbı aynı anahtarı üç kez arar (contains/get/set); önbellek bunu tek
    /// gerçek hash aramasına indirir. Dict'te silme olmadığından indeksler kararlıdır (`entries`
    /// yalnızca büyür), doğrulama `entries[last_idx].key == key` (int: değer, str: aynı işaretçi).
    last_idx: usize = std.math.maxInt(usize),
    /// v1.152.0 (roadmap 1.6b): değerleri `list[T]`/`dict[K, V]` olan sözlüklerde bu değerlerin SOMUT serbest bırakma
    /// fonksiyonu (codegen kurulumda `nox_dict_set_value_release` ile yazar; `value_is_class` bayrağı bu durumda "ARC
    /// işaretçisi" demektir). `null` ise `value_is_class` değerleri sınıf etiket-dağıtımıyla (`releaseClassPayload`) bırakılır.
    value_release: ?*const fn (abi_ptr.Arg, abi_ptr.Arg) callconv(.c) void = null,
    /// Aura L2: indeks kuruluyken (`index_built`) silme `entries`i kaydırmaz (O(n)) — girdiyi MEZAR TAŞI yapar: `dead_bits`te
    /// biti kurulur, indeksteki slotu `DELETED` olur. `dead` mezar taşı sayısıdır; yarısı aşılınca `compact` tek geçişte
    /// temizler (amortize O(1) silme). `dead == 0` iken `dead_bits` kullanılmaz ve her yol eski davranışla aynıdır.
    dead: usize = 0,
    dead_bits: std.ArrayListUnmanaged(u64) = .empty,
    /// Faz 9.0 (v2.1.120): `true` ise sözlük işçiler arasında PAYLAŞILIYOR (derleyici paylaşılan modül globali olarak işaretler,
    /// `nox_dict_make_shared`): her dışa açık işlem `lock` altında çalışır (okumalar dahil: `last_idx` önbelleği okumada da yazılır).
    /// Tek işlemler atomik, bileşik işlemler (`d[k] = d[k] + 1`) değildir; bellek-güvenlidir. Paylaşılmayan sözlüklerde maliyet: bir dal.
    shared: bool = false,
    /// Faz 9.0 F5: derleyici yayımlama noktasından (sınıf/liste değerlerini yayımlamak için) en az bir kez geçti mi?
    published: bool = false,
    /// Sıcak kilit kendi önbellek satırında durur (yanlış paylaşım: kilidi bekleyenler sözlük alanlarının satırını geçersiz kılmasın).
    _pad: [64]u8 = undefined,
    lock: SpinLock = .{},
};

const SpinLock = @import("../async_rt/spinlock.zig").SpinLock;

/// Paylaşılan sözlükte kilidi alır (paylaşılmıyorsa hiçbir şey yapmaz); `unlockShared` ile eşleşir. Okuma da dışlayıcıdır: kısa kritik bölümlerde okuyucu-yazıcı kilidinin iki atomik RMW'si
/// (okuyucu sayacı) tek bir dışlayıcı kilitten PAHALIDIR (ölçüldü: 8 işçide okuma-ağırlıklı yükte RW 12,3 s, dışlayıcı 5,7 s) ve `last_idx` önbelleği okumada da yazıldığından okumalar salt-okunur değildir.
inline fn lockShared(d: *Dict) bool {
    if (!d.shared) return false;
    d.lock.lockBackoff();
    return true;
}

inline fn unlockShared(d: *Dict, held: bool) void {
    if (held) d.lock.unlock();
}

inline fn lockRead(d: *Dict) bool {
    return lockShared(d);
}

inline fn unlockRead(d: *Dict, held: bool) void {
    unlockShared(d, held);
}

/// Sözlüğü işçiler arasında paylaşılan olarak işaretler (derleyici, paylaşılan modül globali başlatıldıktan hemen sonra çağırır). Eş zamanlı erişim BAŞLAMADAN önce çağrılmalıdır.
pub export fn nox_dict_make_shared(rt: ?*anyopaque, dp: ?*anyopaque) void {
    const d: *Dict = @ptrCast(@alignCast(dp orelse return));
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return));
    // Havuzda tek işçi varsa eş zamanlı erişim OLAMAZ: kilit hiç alınmaz (tek işçili çalıştırmada sıfır ek maliyet).
    d.shared = state.main_pool_workers > 1;
}

/// Faz 9.0 F5: `nox_dict_make_shared` gibi ama sözlük bu çağrıdan ÖNCE yayımlanmamışsa 1 döner (derleyici o durumda sınıf/liste değerlerini yayımlar).
pub export fn nox_dict_publish_begin(rt: ?*anyopaque, dp: ?*anyopaque) i32 {
    const d: *Dict = @ptrCast(@alignCast(dp orelse return 0));
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return 0));
    if (d.published) return 0;
    d.published = true;
    d.shared = state.main_pool_workers > 1;
    return 1;
}

/// Faz 9.0 F5: `idx`indeki girdinin anahtarını (`want_value=0`) ya da değerini kilit altında RETAIN ederek döner (`kind`: 1 = `str`, 2 = ARC işaretçisi, 0 = retain yok).
pub export fn nox_dict_entry_owned(dp: ?*anyopaque, idx: i64, want_value: i32, kind: i32) i64 {
    const d: *Dict = @ptrCast(@alignCast(dp orelse return 0));
    const held = lockRead(d);
    defer unlockRead(d, held);
    if (idx < 0) return 0;
    const i = liveEntryAt(d, @intCast(idx)) orelse return 0;
    const v = if (want_value != 0) d.entries.items[i].value else d.entries.items[i].key;
    if (v != 0) {
        if (kind == 2) arc.nox_rc_retain(@as(?*anyopaque, @ptrFromInt(@as(usize, @intCast(@as(u64, @bitCast(v))))))) else if (kind == 1) str_mod.nox_str_retain(payloadToStrPtr(v));
    }
    return v;
}

/// `entries[i]` mezar taşı mı? (`dead == 0` hızlı yolu.)
inline fn isDead(d: *const Dict, i: usize) bool {
    if (d.dead == 0) return false;
    return (d.dead_bits.items[i >> 6] >> @intCast(i & 63)) & 1 == 1;
}

/// Canlı girdi sayısı.
inline fn liveCount(d: *const Dict) usize {
    return d.entries.items.len - d.dead;
}

fn payloadToStrPtr(v: i64) ?[*:0]u8 {
    if (v == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(@as(u64, @bitCast(v)))));
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

/// v2.1.87: sıcak yol satır içi — son-arama önbelleği (`last_idx`) isabeti çağrısız çözülür; kaçırma `findIndexSlow`a (noinline, `usize` sentinel
/// döner: isteğe bağlı sonucun bellekten dönüşü ve büyük prolog/epilog yalnızca yavaş yola düşer).
const NOT_FOUND: usize = std.math.maxInt(usize);

inline fn findIndex(d: *Dict, key: i64, rt: ?*anyopaque) ?usize {
    const li = d.last_idx;
    if (li < d.entries.items.len and d.entries.items[li].key == key) return li;
    const r = findIndexSlow(d, key, rt);
    return if (r == NOT_FOUND) null else r;
}

noinline fn findIndexSlow(d: *Dict, key: i64, rt: ?*anyopaque) usize {
    const found = if (!d.index_built)
        findIndexLinear(d, key)
    else blk: {
        const ctx: StrOrIntContext = .{ .key_is_str = d.key_is_str, .rt = rt };
        // Anahtar türüne göre özelleştirilmiş arama (int: tek `==`, str: içerik karşılaştırması) — çalışma zamanı dalı yok.
        break :blk if (d.key_is_str)
            d.index.find(d.entries.items, true, key, ctx.hash(key))
        else
            d.index.find(d.entries.items, false, key, ctx.hash(key));
    };
    if (found) |i| {
        d.last_idx = i;
        return i;
    }
    return NOT_FOUND;
}

/// `entries`i (TÜMÜNÜ, MEVCUT haliyle) `index`e AKTARIR VE `index_built`i
/// `true` yapar — `SMALL_MAP_THRESHOLD` AŞILDIĞINDA (bkz. `nox_dict_set`)
/// TEK SEFERLİK çağrılır. `putContext` BAŞARISIZ olursa (OOM) `index_built`
/// `false` KALIR — `findIndex`/`nox_dict_set` bu durumda DOĞRUSAL taramaya
/// GÜVENLE geri düşmeye DEVAM eder (yalnızca performans kaybı, DOĞRULUK
/// ETKİLENMEZ).
fn buildIndex(d: *Dict, allocator: std.mem.Allocator, rt: ?*anyopaque) void {
    const ctx: StrOrIntContext = .{ .key_is_str = d.key_is_str, .rt = rt };
    for (d.entries.items, 0..) |e, i| {
        d.index.insertNew(allocator, ctx.hash(e.key), i) catch {
            d.index.deinit(allocator);
            return;
        };
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
pub export fn nox_dict_set(rt: ?*anyopaque, dp: ?*anyopaque, key_is_str: i32, value_is_str: i32, value_is_class: i32, key: i64, value: i64) void {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return));
    const d: *Dict = @ptrCast(@alignCast(dp orelse return));
    const held = lockShared(d);
    defer unlockShared(d, held);
    const ctx: StrOrIntContext = .{ .key_is_str = key_is_str != 0, .rt = rt };
    if (findIndex(d, key, rt)) |i| {
        const old = d.entries.items[i];
        if (value_is_str != 0) str_mod.nox_str_release(rt, payloadToStrPtr(old.value));
        if (value_is_class != 0) releaseValuePayload(rt, d, old.value);
        // v1.142.16: anahtarlar yalnızca `entries`te yaşar (indeks tablosunda kopya yok) — aşağıdaki
        // `entries[i]` güncellemesi (yeni anahtar işaretçisi) tek yetkili güncellemedir.
        if (key_is_str != 0) str_mod.nox_str_release(rt, payloadToStrPtr(old.key));
        d.entries.items[i] = .{ .key = key, .value = value };
    } else {
        d.entries.append(state.allocator(), .{ .key = key, .value = value }) catch return;
        if (d.dead != 0) {
            // Mezar taşı bit kümesi yeni girdiyi de kapsamalı (yeni bitler 0 = canlı).
            const need = (d.entries.items.len + 63) / 64;
            if (d.dead_bits.items.len < need) {
                const old_len = d.dead_bits.items.len;
                d.dead_bits.resize(state.allocator(), need) catch {
                    _ = d.entries.pop();
                    return;
                };
                @memset(d.dead_bits.items[old_len..], 0);
            }
        }
        d.last_idx = d.entries.items.len - 1;
        if (d.index_built) {
            const new_index = d.entries.items.len - 1;
            d.index.insertNew(state.allocator(), ctx.hash(key), new_index) catch {
                _ = d.entries.pop();
            };
        } else if (d.entries.items.len > SMALL_MAP_THRESHOLD) {
            // Faz HH.5: eşik AŞILDI — `index` TEK SEFERLİK inşa edilir,
            // BUNDAN SONRAKİ TÜM aramalar O(1) hash'e geçer.
            buildIndex(d, state.allocator(), rt);
        }
    }
}

/// `entries[i]`yi (ekleme SIRASINI koruyarak) siler. `key`, sözlükte aranan anahtardır (içeriği `entries[i].key` ile aynı; çağıran
/// `str` anahtarı bırakmadan ÖNCE çağırmalı: indeks silme anahtarın karmasını okur).
/// İndeks yokken (küçük sözlük) girdi kaydırılır (en çok `SMALL_MAP_THRESHOLD` öğe). İndeks varken girdi mezar taşı olur (Aura L2).
fn removeAt(rt: ?*anyopaque, d: *Dict, i: usize, key: i64) void {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return));
    d.last_idx = std.math.maxInt(usize);
    if (!d.index_built) {
        _ = d.entries.orderedRemove(i);
        return;
    }
    const ctx: StrOrIntContext = .{ .key_is_str = d.key_is_str, .rt = rt };
    _ = d.index.remove(d.entries.items, d.key_is_str, key, ctx.hash(key));
    if (d.dead == 0) {
        // İlk mezar taşı: bit kümesi `entries` uzunluğunu kapsayacak şekilde (sıfırlı) açılır.
        const words = (d.entries.items.len + 63) / 64;
        d.dead_bits.resize(state.allocator(), words) catch {
            // Bellek yok: eski (O(n)) yola düş — girdiyi kaydır, indeksi yeniden kur.
            _ = d.entries.orderedRemove(i);
            d.index.deinit(state.allocator());
            d.index_built = false;
            if (d.entries.items.len > SMALL_MAP_THRESHOLD) buildIndex(d, state.allocator(), rt);
            return;
        };
        @memset(d.dead_bits.items, 0);
    }
    d.dead_bits.items[i >> 6] |= @as(u64, 1) << @intCast(i & 63);
    d.dead += 1;
    if (d.dead >= 16 and d.dead * 2 > d.entries.items.len) compact(rt, d);
}

/// Mezar taşlarını tek geçişte temizler (ekleme sırası korunur) ve indeksi yeniden kurar. `dead == 0` ise no-op.
fn compact(rt: ?*anyopaque, d: *Dict) void {
    if (d.dead == 0) return;
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return));
    var w: usize = 0;
    for (d.entries.items, 0..) |e, r| {
        if (isDead(d, r)) continue;
        d.entries.items[w] = e;
        w += 1;
    }
    d.entries.shrinkRetainingCapacity(w);
    d.dead = 0;
    d.dead_bits.clearRetainingCapacity();
    d.last_idx = std.math.maxInt(usize);
    // v2.1.84: mevcut indeks dizisi yeni canlı girdi sayısına yetiyorsa YENİDEN TAHSİS ETMEDEN sıfırlayıp yeniden doldurulur. Her yoğunlaştırmada
    // `deinit` + 16 slottan çift katlayarak yeniden kurma (≈ 2x boyutta tahsis/serbest) `SmpAllocator`da sınıf-başına serbest listelerde
    // sürekli yeni 64 KiB dilim açılmasına yol açıyordu (ekle/sil dönen sözlükte RSS doğrusal büyüyordu).
    if (w > SMALL_MAP_THRESHOLD and d.index_built and d.index.slots.len >= 2 * (w + 1)) {
        const ctx: StrOrIntContext = .{ .key_is_str = d.key_is_str, .rt = rt };
        @memset(d.index.slots, 0);
        d.index.count = 0;
        d.index.deleted = 0;
        for (d.entries.items, 0..) |e, i| {
            IndexTable.place(d.index.slots, @truncate(ctx.hash(e.key)), i);
            d.index.count += 1;
        }
        return;
    }
    d.index.deinit(state.allocator());
    d.index_built = false;
    if (w > SMALL_MAP_THRESHOLD) buildIndex(d, state.allocator(), rt);
}

/// `del d[k]` / `d.remove`: anahtar + değer (str/sınıf ise) serbest bırakılarak silinir. Silindiyse 1, yoksa 0.
pub export fn nox_dict_remove(rt: ?*anyopaque, dp: ?*anyopaque, key_is_str: i32, value_is_str: i32, value_is_class: i32, key: i64) i32 {
    const d: *Dict = @ptrCast(@alignCast(dp orelse return 0));
    const held = lockShared(d);
    defer unlockShared(d, held);
    const i = findIndex(d, key, rt) orelse return 0;
    const old = d.entries.items[i];
    // Önce silinir (indeks, `key` canlıyken karmasını okur), SONRA payload'lar bırakılır.
    removeAt(rt, d, i, key);
    if (value_is_str != 0) str_mod.nox_str_release(rt, payloadToStrPtr(old.value));
    if (value_is_class != 0) releaseValuePayload(rt, d, old.value);
    if (key_is_str != 0) str_mod.nox_str_release(rt, payloadToStrPtr(old.key));
    return 1;
}

/// `d.pop(k)`: anahtarı siler ve DEĞERİN sahipliğini çağırana DEVREDER (değer serbest bırakılmaz); anahtar serbest bırakılır.
/// Anahtar yoksa 0 döner (çağıran önce `contains` ile doğrular).
pub export fn nox_dict_pop(rt: ?*anyopaque, dp: ?*anyopaque, key_is_str: i32, key: i64) i64 {
    const d: *Dict = @ptrCast(@alignCast(dp orelse return 0));
    const held = lockShared(d);
    defer unlockShared(d, held);
    const i = findIndex(d, key, rt) orelse return 0;
    const old = d.entries.items[i];
    removeAt(rt, d, i, key);
    if (key_is_str != 0) str_mod.nox_str_release(rt, payloadToStrPtr(old.key));
    return old.value;
}

/// `d.clear()`: tüm girdiler (str/sınıf anahtar-değerler) serbest bırakılır, sözlük boş kalır.
pub export fn nox_dict_clear(rt: ?*anyopaque, dp: ?*anyopaque, key_is_str: i32, value_is_str: i32, value_is_class: i32) void {
    const d: *Dict = @ptrCast(@alignCast(dp orelse return));
    const held = lockShared(d);
    defer unlockShared(d, held);
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return));
    for (d.entries.items, 0..) |e, i| {
        if (isDead(d, i)) continue;
        if (value_is_str != 0) str_mod.nox_str_release(rt, payloadToStrPtr(e.value));
        if (value_is_class != 0) releaseValuePayload(rt, d, e.value);
        if (key_is_str != 0) str_mod.nox_str_release(rt, payloadToStrPtr(e.key));
    }
    d.entries.clearRetainingCapacity();
    d.index.deinit(state.allocator());
    d.index_built = false;
    d.last_idx = std.math.maxInt(usize);
    d.dead = 0;
    d.dead_bits.clearRetainingCapacity();
}

/// `dst.update(src)` / `src.copy()`: `src`nin her girdisi `dst`ye eklenir/üzerine yazılır. Anahtar ve değer (str/sınıf ise)
/// önce RETAIN edilir (`nox_dict_set` kendi sahipliğini alır, üzerine yazılan eskileri serbest bırakır).
pub export fn nox_dict_update(rt: ?*anyopaque, dst: ?*anyopaque, src: ?*anyopaque, key_is_str: i32, value_is_str: i32, value_is_class: i32) void {
    const s: *Dict = @ptrCast(@alignCast(src orelse return));
    if (dst == src) return;
    // Paylaşılan kaynakta kilit yalnızca kaynak okunurken tutulur (dst.set kendi kilidini alır): iki sözlüğün kilidi birlikte tutulmaz, kilitlenme olmaz.
    var held = lockShared(s);
    compact(rt, s); // kaynak sırayla gezilir: mezar taşı bırakma
    if (dst) |dp| {
        const dd: *Dict = @ptrCast(@alignCast(dp));
        if (dd.value_release == null) dd.value_release = s.value_release;
    }
    // `src.entries` `dst` güncellenirken DEĞİŞMEZ (farklı sözlükler), ama güvenli olsun diye uzunluk önceden alınır.
    var i: usize = 0;
    const n = s.entries.items.len;
    unlockShared(s, held);
    while (i < n) : (i += 1) {
        held = lockShared(s);
        if (i >= s.entries.items.len) {
            unlockShared(s, held);
            break;
        }
        const e = s.entries.items[i];
        if (key_is_str != 0 and e.key != 0) str_mod.nox_str_retain(payloadToStrPtr(e.key).?);
        if (value_is_str != 0 and e.value != 0) str_mod.nox_str_retain(payloadToStrPtr(e.value).?);
        if (value_is_class != 0 and e.value != 0) arc.nox_rc_retain(payloadToStrPtr(e.value).?);
        unlockShared(s, held);
        nox_dict_set(rt, dst, key_is_str, value_is_str, value_is_class, e.key, e.value);
    }
}

/// Bir anahtarın değerini okur — BORROWED bir okumadır (`str` değer İSE
/// retain EDİLMEZ, dict sahipliği korur — `list[T]` eleman okumasıyla AYNI
/// semantik). Anahtar YOKSA `0` döner (v1 kapsamı: Python'ın `KeyError`ı
/// YOK — bkz. nox-teknik-spesifikasyon.md §3.28, bilinçli sınırlama).
pub export fn nox_dict_get(rt: ?*anyopaque, dp: ?*anyopaque, key_is_str: i32, key: i64) i64 {
    _ = key_is_str;
    const d: *Dict = @ptrCast(@alignCast(dp orelse return 0));
    const held = lockRead(d);
    defer unlockRead(d, held);
    if (findIndex(d, key, rt)) |i| return d.entries.items[i].value;
    return 0;
}

/// Faz 9.0 dilim 3: `nox_dict_get`in SAHİPLİ (owned) ikizi — `str` değerli paylaşılan sözlükler için. Değer kilit altında RETAIN edilir (çağırana ait taze referans); böylece başka bir işçi aynı anahtarı
/// eş zamanlı üzerine yazıp eski değeri (`str` ya da sınıf örneği) bıraksa bile çağıranın eline geçen işaretçi geçerli kalır. Anahtar yoksa 0 (retain yok).
pub export fn nox_dict_get_owned(rt: ?*anyopaque, dp: ?*anyopaque, key_is_str: i32, key: i64, value_kind: i32) i64 {
    _ = key_is_str;
    const d: *Dict = @ptrCast(@alignCast(dp orelse return 0));
    const held = lockRead(d);
    defer unlockRead(d, held);
    if (findIndex(d, key, rt)) |i| {
        const v = d.entries.items[i].value;
        if (v != 0) {
            // value_kind: 1 = `str` (paketlenmiş başlıklı), 2 = ARC sınıf örneği.
            if (value_kind == 2) arc.nox_rc_retain(@as(?*anyopaque, @ptrFromInt(@as(usize, @intCast(@as(u64, @bitCast(v))))))) else str_mod.nox_str_retain(payloadToStrPtr(v));
        }
        return v;
    }
    return 0;
}

/// Faz MN.4: `rt` parametresi EKLENDİ (bkz. `hashSeed`in belge notu) —
/// `nox_dict_len`in AKSİNE (hiç hash'lemez, `rt`ye ihtiyacı YOK, DEĞİŞMEDİ)
/// BU fonksiyon `findIndex` ÜZERİNDEN hash'e İHTİYAÇ DUYABİLİR.
pub export fn nox_dict_contains(rt: ?*anyopaque, dp: ?*anyopaque, key_is_str: i32, key: i64) i32 {
    _ = key_is_str;
    const d: *Dict = @ptrCast(@alignCast(dp orelse return 0));
    const held = lockRead(d);
    defer unlockRead(d, held);
    return if (findIndex(d, key, rt) != null) 1 else 0;
}

/// v1.142.20: `nox.collections` (Set/Counter/OrderedDict) için dahili karma (`__nox_hash` ilkeli).
/// Dict'inkiyle AYNI tohumlu (hash-flooding'e karşı) karıştırıcılar; sonuç NEGATİF OLMAYAN `int`
/// (çağıran `& (kapasite - 1)` ile konum alır). Eşit değerlerin eşit karması şarttır: `float`
/// için `-0.0` ve `0.0` aynı kabul edilir.
pub export fn nox_hash_int(rt: ?*anyopaque, k: i64) i64 {
    return @bitCast(mixInt(hashSeed(rt), k) & 0x7fff_ffff_ffff_ffff);
}

pub export fn nox_hash_float(rt: ?*anyopaque, f: f64) i64 {
    const bits: i64 = if (f == 0.0) 0 else @bitCast(f);
    return nox_hash_int(rt, bits);
}

pub export fn nox_hash_str(rt: ?*anyopaque, s: ?[*:0]const u8) i64 {
    const p = s orelse return 0;
    const h = std.hash.Wyhash.hash(hashSeed(rt), std.mem.sliceTo(p, 0));
    return @bitCast(h & 0x7fff_ffff_ffff_ffff);
}

/// v2.1.111: `nox_dict_eq`nin DEĞER karşılaştırma türleri (codegen `DictInfo.value_*`dan seçer).
/// `payload`: int/bool/sabit-genişlikli/ptr (8 baytlık payload eşitliği); `float`: sayısal `==` (payload f64 bit örüntüsü);
/// `str`: içerik karşılaştırması (null-güvenli); `callback`: class/list/dict değerler için derleyicinin ürettiği `$X_eq(rt, a, b) w`.
pub const DICT_VEQ_PAYLOAD: i32 = 0;
pub const DICT_VEQ_FLOAT: i32 = 1;
pub const DICT_VEQ_STR: i32 = 2;
pub const DICT_VEQ_CALLBACK: i32 = 3;

fn payloadsEqual(rt: ?*anyopaque, vkind: i32, veq: ?*const fn (abi_ptr.Arg, abi_ptr.Arg, abi_ptr.Arg) callconv(.c) i32, a: i64, b: i64) bool {
    switch (vkind) {
        DICT_VEQ_FLOAT => return @as(f64, @bitCast(a)) == @as(f64, @bitCast(b)),
        DICT_VEQ_STR => {
            if (a == b) return true;
            const pa = payloadToStrPtr(a) orelse return false;
            const pb = payloadToStrPtr(b) orelse return false;
            return std.mem.orderZ(u8, pa, pb) == .eq;
        },
        DICT_VEQ_CALLBACK => {
            if (a == b) return true;
            const pa = payloadToStrPtr(a) orelse return false;
            const pb = payloadToStrPtr(b) orelse return false;
            const f = veq orelse return false;
            return f(abi_ptr.arg(rt), abi_ptr.arg(pa), abi_ptr.arg(pb)) != 0;
        },
        else => return a == b,
    }
}

/// v2.1.111: yapısal `dict == dict` — aynı canlı girdi sayısı ve `a`nın HER anahtarı `b`de var, değerleri eşit (ekleme sırası ÖNEMSİZ,
/// Python gibi). Anahtarlar `b`nin KENDİ arama yoluyla (str: içerik) bulunur. `null` dict'ler (yalnızca ilklenmemiş alan) yalnızca
/// ikisi de `null` ise eşittir.
pub export fn nox_dict_eq(rt: ?*anyopaque, ap: ?*anyopaque, bp: ?*anyopaque, vkind: i32, veq: ?*const fn (abi_ptr.Arg, abi_ptr.Arg, abi_ptr.Arg) callconv(.c) i32) i32 {
    if (ap == bp) return 1;
    const a: *Dict = @ptrCast(@alignCast(ap orelse return 0));
    const b: *Dict = @ptrCast(@alignCast(bp orelse return 0));
    // İki sözlüğü de kilitle (adres sırası: kilitlenme yok).
    const first_a = @intFromPtr(a) < @intFromPtr(b);
    const held_first = lockRead(if (first_a) a else b);
    defer unlockRead(if (first_a) a else b, held_first);
    const held_second = lockRead(if (first_a) b else a);
    defer unlockRead(if (first_a) b else a, held_second);
    if (liveCount(a) != liveCount(b)) return 0;
    for (a.entries.items, 0..) |e, i| {
        if (isDead(a, i)) continue;
        const j = findIndex(b, e.key, rt) orelse return 0;
        if (!payloadsEqual(rt, vkind, veq, e.value, b.entries.items[j].value)) return 0;
    }
    return 1;
}

pub export fn nox_dict_len(dp: ?*anyopaque) i64 {
    const d: *Dict = @ptrCast(@alignCast(dp orelse return 0));
    const held = lockRead(d);
    defer unlockRead(d, held);
    return @intCast(liveCount(d));
}

/// `idx`inci CANLI girdinin `entries` konumu (mezar taşı yokken `idx`in kendisi). Mezar taşı varsa O(n) tarama — yalnızca
/// konumsal okuma (`print`) kullanır; sıralı gezintiler (`keys()`/`values()`/`update`) önce `compact` eder.
fn liveEntryAt(d: *const Dict, idx: usize) ?usize {
    if (d.dead == 0) return if (idx < d.entries.items.len) idx else null;
    var seen: usize = 0;
    for (0..d.entries.items.len) |i| {
        if (isDead(d, i)) continue;
        if (seen == idx) return i;
        seen += 1;
    }
    return null;
}

/// v2.0.23: Sözlüğün `idx` indisindeki (ekleme sırası) anahtarının 8-baytlık ham payload'ını döner (borrowed okuma).
pub export fn nox_dict_entry_key(dp: ?*anyopaque, idx: i64) i64 {
    const d: *Dict = @ptrCast(@alignCast(dp orelse return 0));
    const held = lockRead(d);
    defer unlockRead(d, held);
    if (idx < 0) return 0;
    const i = liveEntryAt(d, @intCast(idx)) orelse return 0;
    return d.entries.items[i].key;
}

/// v2.0.23: Sözlüğün `idx` indisindeki (ekleme sırası) değerinin 8-baytlık ham payload'ını döner (borrowed okuma).
pub export fn nox_dict_entry_value(dp: ?*anyopaque, idx: i64) i64 {
    const d: *Dict = @ptrCast(@alignCast(dp orelse return 0));
    const held = lockRead(d);
    defer unlockRead(d, held);
    if (idx < 0) return 0;
    const i = liveEntryAt(d, @intCast(idx)) orelse return 0;
    return d.entries.items[i].value;
}

/// Faz III.6 (bkz. nox-teknik-spesifikasyon.md §3.69) — `keys()`/`values()`
/// ORTAK yardımcısı: `entries`i (SIRALI, `nox_dict_len`in saydığı AYNI
/// eleman sayısınca) `list[T]`nin ham bayt düzenine (`nox_fs_read_dir_raw`
/// İLE AYNI el-yapımı desen: 8 bayt uzunluk + 8 bayt kapasite + N eleman)
/// KOPYALAR. `elem_size` (1: `bool` — v1.142.19 `list[bool]` 1 bayt/eleman; 4: eski `w`, 8: `int`/`str`/`float`/`l`/`d`)
/// codegen'in `DictInfo.key_qtype`/`value_qtype`sinden ÖNCEDEN bilinir —
/// `Entry.key`/`.value` HER ZAMAN 8 baytlık bir "payload" (bkz. `codegen.
/// zig`nin `toPayload`sı, `bool` DAHİL HER tip `nox_dict_set`e ÖNCE 8
/// bayta genişletilerek geçirilir) OLDUĞUNDAN, 4 baytlık `list[bool]`
/// İÇİN düşük 32 bit ALINIR (`toPayload`nin `extuw`si SIFIR-genişlettiğinden
/// KAYIPSIZ round-trip). `is_str` İSE HER elemanın refcount'u BİR ARTIRILIR
/// (`nox_rc_retain`) — dict KENDİ referansını KORUR, YENİ liste BAĞIMSIZ
/// bir İKİNCİ sahip olur (`nox_dict_release`/liste'nin KENDİ release'i
/// birbirinden bağımsız, İKİSİ de kendi payını serbest bırakır).
fn buildEntryList(rt: ?*anyopaque, d: *Dict, is_str: bool, is_class: bool, elem_size: i64, want_key: bool) ?*anyopaque {
    compact(rt, d); // sıralı gezinti: mezar taşı bırakma
    const n = d.entries.items.len;
    const esz: usize = @intCast(elem_size);
    const raw = arc.nox_rc_alloc(rt, LIST_HEADER_SIZE + esz * n) orelse return null;
    const bytes: [*]u8 = @ptrCast(raw);
    @as(*align(1) i64, @ptrCast(bytes)).* = @intCast(n);
    @as(*align(1) i64, @ptrCast(bytes + 8)).* = @intCast(n);
    for (d.entries.items, 0..) |e, i| {
        const payload = if (want_key) e.key else e.value;
        if (is_str and payload != 0) str_mod.nox_str_retain(payloadToStrPtr(payload).?);
        // Faz OO.4: sınıf DEĞERLERİ `str` İLE AYNI "ödünç okuma, bağımsız
        // ikinci sahip İçİn retain" gerekçesiyle — ama `str`nin KENDİ
        // paketlenmiş uzunluk+ASCII başlığı (`STR_HEADER_SIZE`) OLMADIĞINDAN
        // (bkz. `retainOffset`in codegen'deki AYNI ayrımı) DÜZ `arc.
        // nox_rc_retain` (ARC_HEADER_SIZE'lık sabit ofset) KULLANILIR,
        // `nox_str_retain` DEĞİL.
        if (is_class and payload != 0) arc.nox_rc_retain(payloadToStrPtr(payload).?);
        const slot = bytes + LIST_HEADER_SIZE + esz * i;
        if (esz == 1) {
            slot[0] = @truncate(@as(u64, @bitCast(payload)));
        } else if (esz == 4) {
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
    const held = lockShared(d);
    defer unlockShared(d, held);
    return buildEntryList(rt, d, key_is_str != 0, false, key_elem_size, true);
}

/// `d.values() -> list[V]` — bkz. `buildEntryList`in belge notu.
pub export fn nox_dict_values(rt: ?*anyopaque, dp: ?*anyopaque, value_is_str: i32, value_is_class: i32, value_elem_size: i64) ?*anyopaque {
    const d: *Dict = @ptrCast(@alignCast(dp orelse return null));
    const held = lockShared(d);
    defer unlockShared(d, held);
    return buildEntryList(rt, d, value_is_str != 0, value_is_class != 0, value_elem_size, false);
}

/// Döngü çözücünün `$Sınıf_trace`i için: sözlüğün DEĞERLERİNİ (`dict[K, Sınıf]`)
/// refcount'a HİÇ dokunmadan `buf`ın (8 baytlık uzunluk başlığı + 8 baytlık yuvalar)
/// `start_idx`inci yuvasından itibaren yazar, YENİ yazma indeksini döner.
/// (`nox_dict_values` her değeri retain eden geçici bir liste kurardı; o listenin
/// release'i döngü-çözücü kilidi tutulurken `nox_cycle_possible_root`a yeniden girip
/// kilitleniyordu.)
pub export fn nox_dict_trace_fill(dp: ?*anyopaque, buf: ?*anyopaque, start_idx: i64) i64 {
    const d: *const Dict = @ptrCast(@alignCast(dp orelse return start_idx));
    const out: [*]u8 = @ptrCast(buf orelse return start_idx);
    var idx = start_idx;
    for (d.entries.items, 0..) |e, i| {
        if (isDead(d, i)) continue;
        const slot: *align(1) abi_ptr.Slot = @ptrCast(out + abi_layout.TRACE_BUF_LEN_SIZE + @as(usize, @intCast(idx)) * abi_layout.TRACE_BUF_SLOT_SIZE);
        slot.* = abi_ptr.slot(@as(?*anyopaque, @ptrFromInt(@as(usize, @intCast(@as(u64, @bitCast(e.value)))))));
        idx += 1;
    }
    return idx;
}

/// Faz FF.3 — `dict`in refcount'unu bir azaltır; sıfıra/altına düşerse
/// KENDİSİNİ (ve İÇİNDEKİ TÜM `str` anahtar/değerleri, varsa) GERÇEKTEN
/// yıkar — `runtime/str.zig`nin `nox_str_release`iyle (`nox_rc_
/// predecrement`e göre koşullu) BİREBİR AYNI desen (ESKİ `nox_dict_
/// destroy`nin AKSİNE, artık KOŞULSUZ değil — bkz. modül üstü not).
pub export fn nox_dict_release(rt: ?*anyopaque, dp: ?*anyopaque, key_is_str: i32, value_is_str: i32, value_is_class: i32) void {
    const ptr = dp orelse return;
    if (arc.nox_rc_predecrement(ptr) == 0) return;
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return));
    const d: *Dict = @ptrCast(@alignCast(ptr));
    for (d.entries.items, 0..) |e, i| {
        if (isDead(d, i)) continue;
        if (value_is_str != 0) str_mod.nox_str_release(rt, payloadToStrPtr(e.value));
        if (value_is_class != 0) releaseValuePayload(rt, d, e.value);
        if (key_is_str != 0) str_mod.nox_str_release(rt, payloadToStrPtr(e.key));
    }
    d.entries.deinit(state.allocator());
    d.index.deinit(state.allocator());
    d.dead_bits.deinit(state.allocator());
    arc.nox_rc_free_payload(rt, ptr, @sizeOf(Dict));
}

/// v3 madde 3 (ownership/ptr[T] red-team, bkz. nox-teknik-spesifikasyon.md
/// ilgili bölüm): `nox_list_shallow_gc_free`in (`runtime/alloc/arc.zig`)
/// AYNI gerekçesi/DÜZELTMESİ — `dict[K, ClassType]` alanı İÇEREN bir
/// sınıfın `$ClassName_gc_free`si İçİn. `nox_dict_release`DEN TEK farkı:
/// DEĞER sınıf-tipliyse `releaseClassPayload` (→ `nox_cycle_possible_
/// root`u TEKRAR tetikleyip `collectWhite`in worklist'İNİ BOZAN normal
/// ARC release) ASLA çağrılmaz — anahtar (`str` İSE) HÂLÂ normal serbest
/// bırakılır (döngü ile İLİŞKİSİZ, `trace()`in raporladığı HİÇBİR şeye
/// karışmaz).
pub export fn nox_dict_shallow_gc_free_class_values(rt: ?*anyopaque, dp: ?*anyopaque, key_is_str: i32) void {
    const ptr = dp orelse return;
    if (arc.nox_rc_predecrement(ptr) == 0) return;
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return));
    const d: *Dict = @ptrCast(@alignCast(ptr));
    for (d.entries.items, 0..) |e, i| {
        if (isDead(d, i)) continue;
        if (key_is_str != 0) str_mod.nox_str_release(rt, payloadToStrPtr(e.key));
    }
    d.entries.deinit(state.allocator());
    d.index.deinit(state.allocator());
    d.dead_bits.deinit(state.allocator());
    arc.nox_rc_free_payload(rt, ptr, @sizeOf(Dict));
}

test "nox_dict_remove/pop/clear/update — sıra korunur, indeks yeniden kurulur, int anahtar/değer" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const d = nox_dict_new(rt, 0) orelse return error.NewFailed;
    var k: i64 = 1;
    while (k <= 20) : (k += 1) nox_dict_set(rt, d, 0, 0, 0, k, k * 10); // eşik (8) aşılır -> indeks kurulu
    try std.testing.expectEqual(@as(i32, 1), nox_dict_remove(rt, d, 0, 0, 0, 5));
    try std.testing.expectEqual(@as(i32, 0), nox_dict_remove(rt, d, 0, 0, 0, 5));
    try std.testing.expectEqual(@as(i64, 19), nox_dict_len(d));
    try std.testing.expectEqual(@as(i32, 0), nox_dict_contains(rt, d, 0, 5));
    try std.testing.expectEqual(@as(i64, 200), nox_dict_get(rt, d, 0, 20));
    // Ekleme sırası korunur: 4'ten sonra 6 gelir.
    const dd: *Dict = @ptrCast(@alignCast(d));
    try std.testing.expectEqual(@as(i64, 4), nox_dict_entry_key(dd, 3));
    try std.testing.expectEqual(@as(i64, 6), nox_dict_entry_key(dd, 4));
    try std.testing.expectEqual(@as(i64, 70), nox_dict_pop(rt, d, 0, 7));
    try std.testing.expectEqual(@as(i64, 18), nox_dict_len(d));

    const e = nox_dict_new(rt, 0) orelse return error.NewFailed;
    nox_dict_set(rt, e, 0, 0, 0, 100, 1);
    nox_dict_set(rt, e, 0, 0, 0, 1, 999);
    nox_dict_update(rt, d, e, 0, 0, 0);
    try std.testing.expectEqual(@as(i64, 999), nox_dict_get(rt, d, 0, 1));
    try std.testing.expectEqual(@as(i64, 1), nox_dict_get(rt, d, 0, 100));
    try std.testing.expectEqual(@as(i64, 19), nox_dict_len(d));

    nox_dict_clear(rt, d, 0, 0, 0);
    try std.testing.expectEqual(@as(i64, 0), nox_dict_len(d));
    nox_dict_set(rt, d, 0, 0, 0, 3, 33);
    try std.testing.expectEqual(@as(i64, 33), nox_dict_get(rt, d, 0, 3));
    nox_dict_release(rt, d, 0, 0, 0);
    nox_dict_release(rt, e, 0, 0, 0);
}

test "nox_dict_eq — ekleme sırası önemsiz, boyut/değer farkı eşitsiz, float/str/callback değer türleri" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const a = nox_dict_new(rt, 0) orelse return error.NewFailed;
    const b = nox_dict_new(rt, 0) orelse return error.NewFailed;
    var k: i64 = 1;
    while (k <= 20) : (k += 1) nox_dict_set(rt, a, 0, 0, 0, k, k * 10); // eşik aşılır -> indeks kurulu
    k = 20;
    while (k >= 1) : (k -= 1) nox_dict_set(rt, b, 0, 0, 0, k, k * 10); // ters ekleme sırası
    try std.testing.expectEqual(@as(i32, 1), nox_dict_eq(rt, a, b, DICT_VEQ_PAYLOAD, null));
    try std.testing.expectEqual(@as(i32, 1), nox_dict_eq(rt, a, a, DICT_VEQ_PAYLOAD, null));
    nox_dict_set(rt, b, 0, 0, 0, 7, 71); // farklı değer
    try std.testing.expectEqual(@as(i32, 0), nox_dict_eq(rt, a, b, DICT_VEQ_PAYLOAD, null));
    nox_dict_set(rt, b, 0, 0, 0, 7, 70);
    nox_dict_set(rt, b, 0, 0, 0, 99, 1); // farklı boyut
    try std.testing.expectEqual(@as(i32, 0), nox_dict_eq(rt, a, b, DICT_VEQ_PAYLOAD, null));
    try std.testing.expectEqual(@as(i32, 1), nox_dict_remove(rt, b, 0, 0, 0, 99));
    try std.testing.expectEqual(@as(i32, 1), nox_dict_eq(rt, a, b, DICT_VEQ_PAYLOAD, null)); // mezar taşlı b yine eşit
    try std.testing.expectEqual(@as(i32, 0), nox_dict_eq(rt, a, null, DICT_VEQ_PAYLOAD, null));
    try std.testing.expectEqual(@as(i32, 1), nox_dict_eq(rt, null, null, DICT_VEQ_PAYLOAD, null));

    const fa = nox_dict_new(rt, 0) orelse return error.NewFailed;
    const fb = nox_dict_new(rt, 0) orelse return error.NewFailed;
    nox_dict_set(rt, fa, 0, 0, 0, 1, @bitCast(@as(f64, 0.0)));
    nox_dict_set(rt, fb, 0, 0, 0, 1, @bitCast(@as(f64, -0.0)));
    try std.testing.expectEqual(@as(i32, 1), nox_dict_eq(rt, fa, fb, DICT_VEQ_FLOAT, null)); // 0.0 == -0.0
    try std.testing.expectEqual(@as(i32, 0), nox_dict_eq(rt, fa, fb, DICT_VEQ_PAYLOAD, null)); // ham bit karşılaştırması farklıdır

    nox_dict_release(rt, a, 0, 0, 0);
    nox_dict_release(rt, b, 0, 0, 0);
    nox_dict_release(rt, fa, 0, 0, 0);
    nox_dict_release(rt, fb, 0, 0, 0);
}

test "nox_dict_new/set/get/contains/len/destroy — int anahtar/değer" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const d = nox_dict_new(rt, 0) orelse return error.NewFailed;
    nox_dict_set(rt, d, 0, 0, 0, 1, 100);
    nox_dict_set(rt, d, 0, 0, 0, 2, 200);
    try std.testing.expectEqual(@as(i64, 100), nox_dict_get(rt, d, 0, 1));
    try std.testing.expectEqual(@as(i64, 200), nox_dict_get(rt, d, 0, 2));
    try std.testing.expectEqual(@as(i64, 0), nox_dict_get(rt, d, 0, 999));
    try std.testing.expectEqual(@as(i32, 1), nox_dict_contains(rt, d, 0, 1));
    try std.testing.expectEqual(@as(i32, 0), nox_dict_contains(rt, d, 0, 999));
    try std.testing.expectEqual(@as(i64, 2), nox_dict_len(d));

    // Üzerine yazma: aynı anahtar, YENİ değer.
    nox_dict_set(rt, d, 0, 0, 0, 1, 999);
    try std.testing.expectEqual(@as(i64, 999), nox_dict_get(rt, d, 0, 1));
    try std.testing.expectEqual(@as(i64, 2), nox_dict_len(d));

    nox_dict_release(rt, d, 0, 0, 0);
}

test "nox_dict — str anahtar İÇERİK eşitliğiyle bulunur (pointer eşitliği DEĞİL), üzerine yazma eskiyi serbest bırakır" {
    const str_lib = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const d = nox_dict_new(rt, 1) orelse return error.NewFailed;

    const k1 = str_lib.nox_str_from_bytes(rt, "anahtar") orelse return error.ConcatFailed;
    const v1 = str_lib.nox_str_from_bytes(rt, "deger1") orelse return error.ConcatFailed;
    nox_dict_set(rt, d, 1, 1, 0, @bitCast(@intFromPtr(k1)), @bitCast(@intFromPtr(v1)));

    // AYNI İÇERİKLİ ama FARKLI POINTER'lı ikinci bir anahtar — content-based
    // eşleşme sayesinde AYNI slotu güncellemeli (yeni bir eleman EKLENMEMELİ).
    const k2 = str_lib.nox_str_from_bytes(rt, "anahtar") orelse return error.ConcatFailed;
    const v2 = str_lib.nox_str_from_bytes(rt, "deger2") orelse return error.ConcatFailed;
    nox_dict_set(rt, d, 1, 1, 0, @bitCast(@intFromPtr(k2)), @bitCast(@intFromPtr(v2)));

    try std.testing.expectEqual(@as(i64, 1), nox_dict_len(d));
    const got = nox_dict_get(rt, d, 1, @bitCast(@intFromPtr(k2)));
    const got_ptr: [*:0]u8 = @ptrFromInt(@as(usize, @bitCast(got)));
    try std.testing.expectEqualStrings("deger2", std.mem.sliceTo(got_ptr, 0));

    // k2/v2'nin sahipliği dict'e geçti (set İÇİNDE retain edilmedi — testin
    // KENDİSİ çağıran rolünü oynuyor, bu yüzden burada MANUEL retain
    // GEREKMEDİ: k1/v1 üzerine yazıldığı için dict tarafından ZATEN serbest
    // bırakıldı, k2/v2 dict'in TEK sahibi).
    nox_dict_release(rt, d, 1, 1, 0);
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
    nox_dict_set(rt, d, 0, 0, 0, 1, 42);

    arc.nox_rc_retain(d);

    // Birinci release: refcount 2 → 1, dict HÂLÂ canlı/okunabilir olmalı.
    nox_dict_release(rt, d, 0, 0, 0);
    try std.testing.expectEqual(@as(i64, 42), nox_dict_get(rt, d, 0, 1));
    try std.testing.expectEqual(@as(i64, 1), nox_dict_len(d));

    // İkinci release: refcount 1 → 0, GERÇEKTEN serbest bırakılır.
    nox_dict_release(rt, d, 0, 0, 0);
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
        nox_dict_set(rt, d, 0, 0, 0, ii, ii * 10);
    }
    try std.testing.expectEqual(@as(i64, @intCast(SMALL_MAP_THRESHOLD)), nox_dict_len(d));
    try std.testing.expect(!dict_ptr.index_built);
    // Doğrusal tarama yolu HÂLÂ doğru sonuç vermeli.
    try std.testing.expectEqual(@as(i64, 30), nox_dict_get(rt, d, 0, 3));
    try std.testing.expectEqual(@as(i32, 1), nox_dict_contains(rt, d, 0, 3));
    try std.testing.expectEqual(@as(i32, 0), nox_dict_contains(rt, d, 0, 999));

    // Üzerine yazma (HÂLÂ doğrusal modda) — index güncellemesi GEREKMEZ,
    // yalnızca `entries` içindeki slot değişir.
    nox_dict_set(rt, d, 0, 0, 0, 3, 3000);
    try std.testing.expectEqual(@as(i64, 3000), nox_dict_get(rt, d, 0, 3));
    try std.testing.expectEqual(@as(i64, @intCast(SMALL_MAP_THRESHOLD)), nox_dict_len(d));

    // Eşiği AŞAN (SMALL_MAP_THRESHOLD + 1. eleman) ekleme — index GERÇEKTEN
    // inşa EDİLMELİ (bkz. `buildIndex`).
    nox_dict_set(rt, d, 0, 0, 0, 999, 9990);
    try std.testing.expect(dict_ptr.index_built);
    try std.testing.expectEqual(@as(i64, @intCast(SMALL_MAP_THRESHOLD + 1)), nox_dict_len(d));

    // İndeks-tabanlı yol da (hem eşikten ÖNCE eklenen hem SONRA eklenen
    // anahtarlar İçin) doğru sonuç vermeli.
    try std.testing.expectEqual(@as(i64, 3000), nox_dict_get(rt, d, 0, 3));
    try std.testing.expectEqual(@as(i64, 9990), nox_dict_get(rt, d, 0, 999));
    try std.testing.expectEqual(@as(i64, 0), nox_dict_get(rt, d, 0, 500)); // hiç eklenmedi

    // İndeks modunda ÜZERİNE yazma da (removeContext+putContext yolu) doğru
    // çalışmalı.
    nox_dict_set(rt, d, 0, 0, 0, 999, 12345);
    try std.testing.expectEqual(@as(i64, 12345), nox_dict_get(rt, d, 0, 999));
    try std.testing.expectEqual(@as(i64, @intCast(SMALL_MAP_THRESHOLD + 1)), nox_dict_len(d));

    nox_dict_release(rt, d, 0, 0, 0);
}

test "Faz III.6: nox_dict_keys/nox_dict_values int anahtar/deger icin dogru list olusturur (8 baytlik eleman)" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const d = nox_dict_new(rt, 0) orelse return error.NewFailed;
    nox_dict_set(rt, d, 0, 0, 0, 1, 100);
    nox_dict_set(rt, d, 0, 0, 0, 2, 200);

    const keys_list = nox_dict_keys(rt, d, 0, 8) orelse return error.Failed;
    const kbytes: [*]u8 = @ptrCast(keys_list);
    try std.testing.expectEqual(@as(i64, 2), @as(*align(1) i64, @ptrCast(kbytes)).*);
    try std.testing.expectEqual(@as(i64, 2), @as(*align(1) i64, @ptrCast(kbytes + 8)).*);
    try std.testing.expectEqual(@as(i64, 1), @as(*align(1) i64, @ptrCast(kbytes + LIST_HEADER_SIZE)).*);
    try std.testing.expectEqual(@as(i64, 2), @as(*align(1) i64, @ptrCast(kbytes + 24)).*);
    _ = arc.nox_rc_predecrement(keys_list);
    arc.nox_rc_free_payload(rt, keys_list, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * 2);

    const values_list = nox_dict_values(rt, d, 0, 0, 8) orelse return error.Failed;
    const vbytes: [*]u8 = @ptrCast(values_list);
    try std.testing.expectEqual(@as(i64, 100), @as(*align(1) i64, @ptrCast(vbytes + LIST_HEADER_SIZE)).*);
    try std.testing.expectEqual(@as(i64, 200), @as(*align(1) i64, @ptrCast(vbytes + 24)).*);
    _ = arc.nox_rc_predecrement(values_list);
    arc.nox_rc_free_payload(rt, values_list, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * 2);

    nox_dict_release(rt, d, 0, 0, 0);
}

test "Faz III.6: nox_dict_values bool degerler icin 4 baytlik eleman round-trip yapar (dogru truncate/extend)" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const d = nox_dict_new(rt, 0) orelse return error.NewFailed;
    // `toPayload`in `w`->`l` `extuw` deseni (bkz. codegen.zig) TAKLİT
    // edilir: bool `true`/`false` ÖNCE 8 bayta sifir-genisletilerek saklanir.
    nox_dict_set(rt, d, 0, 0, 0, 1, 1); // true
    nox_dict_set(rt, d, 0, 0, 0, 2, 0); // false

    const values_list = nox_dict_values(rt, d, 0, 0, 4) orelse return error.Failed;
    const vbytes: [*]u8 = @ptrCast(values_list);
    try std.testing.expectEqual(@as(i64, 2), @as(*align(1) i64, @ptrCast(vbytes)).*);
    try std.testing.expectEqual(@as(i32, 1), @as(*align(1) i32, @ptrCast(vbytes + LIST_HEADER_SIZE)).*);
    try std.testing.expectEqual(@as(i32, 0), @as(*align(1) i32, @ptrCast(vbytes + 20)).*);
    _ = arc.nox_rc_predecrement(values_list);
    arc.nox_rc_free_payload(rt, values_list, LIST_HEADER_SIZE + 4 * 2);

    nox_dict_release(rt, d, 0, 0, 0);
}

test "Faz III.6: nox_dict_keys str anahtarlari retain eder — dict VE list bagimsiz serbest birakilabilir" {
    const str_lib = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const d = nox_dict_new(rt, 1) orelse return error.NewFailed;
    const k1 = str_lib.nox_str_from_bytes(rt, "anahtar1") orelse return error.ConcatFailed;
    const v1 = str_lib.nox_str_from_bytes(rt, "deger1") orelse return error.ConcatFailed;
    nox_dict_set(rt, d, 1, 1, 0, @bitCast(@intFromPtr(k1)), @bitCast(@intFromPtr(v1)));

    const keys_list = nox_dict_keys(rt, d, 1, 8) orelse return error.Failed;
    const kbytes: [*]u8 = @ptrCast(keys_list);
    const kptr_val = @as(*align(1) i64, @ptrCast(kbytes + LIST_HEADER_SIZE)).*;
    const kptr: [*:0]u8 = @ptrFromInt(@as(usize, @bitCast(kptr_val)));
    try std.testing.expectEqualStrings("anahtar1", std.mem.sliceTo(kptr, 0));

    // Dict ÖNCE serbest bırakılır (KENDİ anahtar/değer referansını
    // serbest bırakır) — list'in KENDİ retain'i sayesinde `kptr` HÂLÂ
    // GEÇERLİ olmalı (DebugAllocator, dict'in serbest bıraktığı belleğe
    // list'in HÂLÂ eriştiğini fark ederse çökerdi).
    nox_dict_release(rt, d, 1, 1, 0);
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
test "Güvenlik M-3: hashSeed sabit 0 DEĞİL VE aynı rt içinde TUTARLI (memoized)" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    const s1 = hashSeed(rt);
    const s2 = hashSeed(rt);
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
        const key_str = str_mod.nox_str_from_bytes(rt, key) orelse return error.ConcatFailed;
        nox_dict_set(rt, d, 1, 0, 0, @bitCast(@intFromPtr(key_str)), @intCast(i * 10));
    }
    try std.testing.expect(dict_ptr.index_built);

    i = 0;
    while (i < SMALL_MAP_THRESHOLD + 5) : (i += 1) {
        const key = std.fmt.allocPrintSentinel(std.testing.allocator, "anahtar{d}", .{i}, 0) catch return error.OutOfMemory;
        defer std.testing.allocator.free(key);
        const key_str = str_mod.nox_str_from_bytes(rt, key) orelse return error.ConcatFailed;
        defer str_mod.nox_str_release(rt, key_str);
        try std.testing.expectEqual(@as(i64, @intCast(i * 10)), nox_dict_get(rt, d, 1, @bitCast(@intFromPtr(key_str))));
    }

    nox_dict_release(rt, d, 1, 0, 0);
}

test "v1.142.16: kompakt indeks tablosu + son-arama önbelleği — rastgele işlemler std.AutoHashMap modeliyle birebir" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    const d = nox_dict_new(rt, 0) orelse return error.AllocFailed;
    var model = std.AutoHashMap(i64, i64).init(std.testing.allocator);
    defer model.deinit();

    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 60_000) : (i += 1) {
        const k: i64 = rnd.intRangeAtMost(i64, -2000, 30_000);
        switch (rnd.uintLessThan(u8, 4)) {
            0, 1 => {
                const v: i64 = @intCast(i);
                nox_dict_set(rt, d, 0, 0, 0, k, v);
                try model.put(k, v);
            },
            2 => {
                const want = model.get(k);
                try std.testing.expectEqual(@as(i32, if (want != null) 1 else 0), nox_dict_contains(rt, d, 0, k));
                // contains sonrası get/set aynı anahtarda önbellekten gitmeli ve tutarlı kalmalı.
                if (want) |w| try std.testing.expectEqual(w, nox_dict_get(rt, d, 0, k));
            },
            else => {
                try std.testing.expectEqual(model.get(k) orelse 0, nox_dict_get(rt, d, 0, k));
            },
        }
    }
    try std.testing.expectEqual(@as(i64, @intCast(model.count())), nox_dict_len(d));
    var it = model.iterator();
    while (it.next()) |e| try std.testing.expectEqual(e.value_ptr.*, nox_dict_get(rt, d, 0, e.key_ptr.*));
    nox_dict_release(rt, d, 0, 0, 0);
}

/// `dict[K, dict[K2, V2]]` değer serbest bırakıcıları: iç sözlüğün (anahtar-str, değer-str, değer-ARC) bayrak üçlüsüne göre
/// 8 sabit `fn(rt, ptr)` — `Dict.value_release` olarak yazılır. İç sözlüğün KENDİ `value_release`i (iç değerler list/dict ise)
/// iç sözlüğün yapısında durur.
fn dictReleaseWrapper(comptime combo: u3) *const fn (abi_ptr.Arg, abi_ptr.Arg) callconv(.c) void {
    return &struct {
        fn f(rt: abi_ptr.Arg, p: abi_ptr.Arg) callconv(.c) void {
            nox_dict_release(abi_ptr.ptr(?*anyopaque, rt), abi_ptr.ptr(?*anyopaque, p), @intFromBool(combo & 4 != 0), @intFromBool(combo & 2 != 0), @intFromBool(combo & 1 != 0));
        }
    }.f;
}

pub const dict_release_wrappers = [8]*const fn (abi_ptr.Arg, abi_ptr.Arg) callconv(.c) void{
    dictReleaseWrapper(0), dictReleaseWrapper(1), dictReleaseWrapper(2), dictReleaseWrapper(3),
    dictReleaseWrapper(4), dictReleaseWrapper(5), dictReleaseWrapper(6), dictReleaseWrapper(7),
};

/// Codegen için: iç sözlük bayraklarına (`combo = key_is_str<<2 | value_is_str<<1 | value_is_class`) uygun release işaretçisini
/// sözlüğün `value_release`ine yazar.
pub export fn nox_dict_set_value_release_dict(dp: ?*anyopaque, combo: i32) void {
    const d: *Dict = @ptrCast(@alignCast(dp orelse return));
    d.value_release = dict_release_wrappers[@as(usize, @intCast(combo)) & 7];
}

/// Codegen için: iç sözlük bayraklarına (`combo`, bkz. `nox_dict_set_value_release_dict`) uygun `fn(rt, ptr)` bırakma
/// işaretçisini DÖNER (sözlüğe yazmadan) — örn. `TaskLocal[dict[K, V]]` için tutamağa yazılır.
pub export fn nox_dict_release_thunk(combo: i32) *const fn (abi_ptr.Arg, abi_ptr.Arg) callconv(.c) void {
    return dict_release_wrappers[@as(usize, @intCast(combo)) & 7];
}

var test_value_release_calls: usize = 0;
fn testCountingRelease(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    test_value_release_calls += 1;
}

test "v1.152.0: value_release — set/remove/clear/release değerleri sözlüğün kendi fonksiyonuyla bırakır; update fonksiyonu devralır" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    test_value_release_calls = 0;
    const d = nox_dict_new(rt, 0) orelse return error.NewFailed;
    nox_dict_set_value_release(d, &testCountingRelease);
    nox_dict_set(rt, d, 0, 0, 1, 1, 0x1000);
    nox_dict_set(rt, d, 0, 0, 1, 2, 0x2000);
    nox_dict_set(rt, d, 0, 0, 1, 1, 0x3000); // üzerine yazma: eski değer bırakılır
    try std.testing.expectEqual(@as(usize, 1), test_value_release_calls);
    try std.testing.expectEqual(@as(i32, 1), nox_dict_remove(rt, d, 0, 0, 1, 2));
    try std.testing.expectEqual(@as(usize, 2), test_value_release_calls);
    const e = nox_dict_new(rt, 0) orelse return error.NewFailed;
    nox_dict_update(rt, e, d, 0, 0, 0); // value_is_class=0 → retain yok; value_release e'ye geçer
    try std.testing.expect(@as(*Dict, @ptrCast(@alignCast(e))).value_release != null);
    nox_dict_clear(rt, d, 0, 0, 1);
    try std.testing.expectEqual(@as(usize, 3), test_value_release_calls);
    nox_dict_release(rt, d, 0, 0, 1);
    // e'nin tek değeri (0x3000) sahte işaretçi: release'te bırakılmasın diye bayrak 0.
    nox_dict_release(rt, e, 0, 0, 0);
}

test "v2.0.23: nox_dict_entry_key / nox_dict_entry_value ekleme sirasina gore dogru borrowed okuma yapar" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    const d = nox_dict_new(rt, 0) orelse return error.NewFailed;
    nox_dict_set(rt, d, 0, 0, 0, 10, 100);
    nox_dict_set(rt, d, 0, 0, 0, 20, 200);
    nox_dict_set(rt, d, 0, 0, 0, 30, 300);

    try std.testing.expectEqual(@as(i64, 3), nox_dict_len(d));
    try std.testing.expectEqual(@as(i64, 10), nox_dict_entry_key(d, 0));
    try std.testing.expectEqual(@as(i64, 100), nox_dict_entry_value(d, 0));
    try std.testing.expectEqual(@as(i64, 20), nox_dict_entry_key(d, 1));
    try std.testing.expectEqual(@as(i64, 200), nox_dict_entry_value(d, 1));
    try std.testing.expectEqual(@as(i64, 30), nox_dict_entry_key(d, 2));
    try std.testing.expectEqual(@as(i64, 300), nox_dict_entry_value(d, 2));

    // Sinir kontrolleri (gecersiz indeks 0 doner)
    try std.testing.expectEqual(@as(i64, 0), nox_dict_entry_key(d, -1));
    try std.testing.expectEqual(@as(i64, 0), nox_dict_entry_value(d, -1));
    try std.testing.expectEqual(@as(i64, 0), nox_dict_entry_key(d, 3));
    try std.testing.expectEqual(@as(i64, 0), nox_dict_entry_value(d, 3));

    nox_dict_release(rt, d, 0, 0, 0);
}

test "Aura L2: indeks kuruluyken silme mezar taşı bırakır; sıra, len, get/contains ve yeniden ekleme doğru kalır" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    const d = nox_dict_new(rt, 0) orelse return error.NewFailed;
    const dd: *Dict = @ptrCast(@alignCast(d));
    var k: i64 = 0;
    while (k < 100) : (k += 1) nox_dict_set(rt, d, 0, 0, 0, k, k * 10);
    // 10 tekil silme: eşik (16) altında, mezar taşları birikir.
    k = 0;
    while (k < 10) : (k += 1) try std.testing.expectEqual(@as(i32, 1), nox_dict_remove(rt, d, 0, 0, 0, k * 2));
    try std.testing.expectEqual(@as(usize, 10), dd.dead);
    try std.testing.expectEqual(@as(i64, 90), nox_dict_len(d));
    try std.testing.expectEqual(@as(i32, 0), nox_dict_contains(rt, d, 0, 4));
    try std.testing.expectEqual(@as(i32, 1), nox_dict_contains(rt, d, 0, 5));
    try std.testing.expectEqual(@as(i64, 50), nox_dict_get(rt, d, 0, 5));
    try std.testing.expectEqual(@as(i32, 0), nox_dict_remove(rt, d, 0, 0, 0, 4)); // zaten silinmiş
    // Konumsal okuma: canlı girdiler ekleme sırasıyla (0,2,..,18 silindi → ilk canlı 1, sonra 3, 5, ...).
    try std.testing.expectEqual(@as(i64, 1), nox_dict_entry_key(d, 0));
    try std.testing.expectEqual(@as(i64, 3), nox_dict_entry_key(d, 1));
    try std.testing.expectEqual(@as(i64, 20), nox_dict_entry_key(d, 10));
    // Silinen anahtarı yeniden ekle: sona gider.
    nox_dict_set(rt, d, 0, 0, 0, 4, 444);
    try std.testing.expectEqual(@as(i64, 91), nox_dict_len(d));
    try std.testing.expectEqual(@as(i64, 444), nox_dict_get(rt, d, 0, 4));
    try std.testing.expectEqual(@as(i64, 4), nox_dict_entry_key(d, 90));
    // keys() önce sıkıştırır; liste sırası aynı.
    const keys = nox_dict_keys(rt, d, 0, 8) orelse return error.NewFailed;
    defer arc.nox_rc_release(rt, keys, 16 + 8 * 91);
    try std.testing.expectEqual(@as(usize, 0), dd.dead);
    const kb: [*]const u8 = @ptrCast(keys);
    try std.testing.expectEqual(@as(i64, 91), @as(*align(1) const i64, @ptrCast(kb)).*);
    try std.testing.expectEqual(@as(i64, 1), @as(*align(1) const i64, @ptrCast(kb + 16)).*);
    try std.testing.expectEqual(@as(i64, 4), @as(*align(1) const i64, @ptrCast(kb + 16 + 8 * 90)).*);
    try std.testing.expectEqual(@as(i64, 444), nox_dict_get(rt, d, 0, 4)); // indeks sıkıştırmadan sonra da doğru
    nox_dict_release(rt, d, 0, 0, 0);
}

test "v2.1.84: yoğunlaştırma sonrası yeniden kurulan indeksle arama/ekleme/silme doğru kalır" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    const d = nox_dict_new(rt, 0) orelse return error.NewFailed;
    const dd: *Dict = @ptrCast(@alignCast(d));
    var k: i64 = 0;
    while (k < 200) : (k += 1) nox_dict_set(rt, d, 0, 0, 0, k, k * 3);
    // Çok sayıda ekle/sil turu: her tur yoğunlaştırmayı (yerinde yeniden kurma) tetikler; sonuçlar doğru kalmalı.
    var round: i64 = 0;
    while (round < 50) : (round += 1) {
        k = 0;
        while (k < 100) : (k += 1) _ = nox_dict_remove(rt, d, 0, 0, 0, k + @rem(round, 2) * 50);
        k = 0;
        while (k < 100) : (k += 1) nox_dict_set(rt, d, 0, 0, 0, k + @rem(round, 2) * 50, k + round);
    }
    try std.testing.expect(dd.index_built);
    try std.testing.expectEqual(@as(i64, 200), nox_dict_len(d));
    // Son çift tur (48): 0..99 = anahtar + 48; son tek tur (49): 50..149 = (anahtar - 50) + 49; 150..199 ilk değerlerinde.
    try std.testing.expectEqual(@as(i64, 10 + 48), nox_dict_get(rt, d, 0, 10));
    try std.testing.expectEqual(@as(i64, (60 - 50) + 49), nox_dict_get(rt, d, 0, 60));
    try std.testing.expectEqual(@as(i64, 3 * 190), nox_dict_get(rt, d, 0, 190));
    try std.testing.expectEqual(@as(i32, 0), nox_dict_contains(rt, d, 0, 250));
    nox_dict_release(rt, d, 0, 0, 0);
}

test "Aura L2: toplu silme otomatik sıkıştırır (dead sınırlı), str anahtarlar sızdırmaz, ters sırada da çalışır" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    const d = nox_dict_new(rt, 1) orelse return error.NewFailed;
    const dd: *Dict = @ptrCast(@alignCast(d));
    var bufs: [2000][12]u8 = undefined;
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const txt = std.fmt.bufPrint(&bufs[i], "k{d}", .{i}) catch unreachable;
        const sk = str_mod.nox_str_from_bytes(rt, txt) orelse return error.AllocFailed;
        nox_dict_set(rt, d, 1, 0, 0, @bitCast(@as(u64, @intFromPtr(sk))), @intCast(i));
    }
    // Hepsini (tek tek) sil: her silmede aranan anahtar için yeni bir str kurulur.
    i = 0;
    while (i < 2000) : (i += 1) {
        const txt = std.fmt.bufPrint(&bufs[i], "k{d}", .{i}) catch unreachable;
        const probe = str_mod.nox_str_from_bytes(rt, txt) orelse return error.AllocFailed;
        defer str_mod.nox_str_release(rt, probe);
        try std.testing.expectEqual(@as(i32, 1), nox_dict_remove(rt, d, 1, 0, 0, @bitCast(@as(u64, @intFromPtr(probe)))));
        try std.testing.expect(dd.dead <= dd.entries.items.len / 2 + 16);
    }
    try std.testing.expectEqual(@as(i64, 0), nox_dict_len(d));
    nox_dict_release(rt, d, 1, 0, 0);
}
