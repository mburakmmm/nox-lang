//! `nox.json` Zig kabuğu — stdlib fazı §L (bkz. nox-teknik-spesifikasyon.md).
//!
//! **Bu dosya, PROJEDE İLK KEZ, Zig KAYNAK kodunun (önceden, `noxrt.o`
//! olarak derlenmiş) QBE'nin SONRADAN derleyeceği bir Nox sembolünü
//! (`nox_json_make_json_value`, aşağıya bkz.) ÇAĞIRDIĞI yerdir** — ŞİMDİYE
//! KADAR hep TERSİ olmuştu (codegen QBE seviyesinde Zig fonksiyonlarını
//! çağırırdı).
//!
//! **NEDEN sabit bir `extern fn` DEĞİL, `dlsym` İLE ÇALIŞMA ZAMANINDA
//! aranan bir sembol:** `JsonValue`/`make_json_value` `stdlib/nox/core.nox`da
//! (bkz. onun belge notu) TANIMLI olduğundan, `noxc` CLI'sinin GERÇEK
//! derleme yolunda (`module_loader.resolveImports`, HER programa KOŞULSUZ)
//! bu sembol HER ZAMAN mevcuttur — AMA `noxrt.o`nun KENDİSİ (json.zig'in
//! makine kodu DAHİL) HER derlenen Nox programına KOŞULSUZ bağlanan TEK bir
//! nesne dosyasıdır; sabit bir `extern fn` kullanılsaydı, `noxrt.o`yu
//! `resolveImports`DAN GEÇMEYEN bir bağlamda (ör. bu projenin `tests/compat/`
//! altındaki, ham `parser.parseModule`i kullanan DAHA ESKİ/İZOLE test
//! altyapıları) VEYA HİÇ bir Nox programı OLMADAN (`zig build test`nin
//! `runtime/lib.zig`yi DOĞRUDAN test eden `noxrt_test` hedefi) BAĞLAMAK
//! GEREKTİĞİNDE `cc`/`zig`nin bağlama adımı "symbol not found" hatasıyla
//! ÇÖKERDİ (GERÇEKTEN denenip YAKALANDI). `dlsym` ÇALIŞMA ZAMANINDA arandığı
//! İÇİN bu sorunu TAMAMEN ORTADAN KALDIRIR: sembol GERÇEKTEN mevcutsa
//! (GERÇEK bir `noxc` programı çalışırken HER ZAMAN mevcuttur) bulunur;
//! DEĞİLSE (yukarıdaki izole test bağlamları) `nox_json_decode_raw` zaten
//! HİÇ ÇAĞRILMADIĞINDAN (o testler `nox.json` KULLANMAZ) bu asla bir sorun
//! OLMAZ.
//!
//! **Neden bu yaklaşım (Zig'in `JsonValue`yi KENDİSİNİN ham bellek olarak
//! İNŞA ETMESİ YERİNE) — TARİHSEL, artık YALNIZCA İLK çağrı İçİn geçerli:**
//! her sınıfın `class_id`si (`codegen.zig`nin `next_class_id` sayacı)
//! DERLEME SIRASINA bağlıdır — bu YÜZDEN sabit kodlanan bir sayı GÜVENLE
//! kullanılamaz. AMA `class_id` ÖNGÖRÜLEMEZ DEĞİLDİR: `module_loader.zig`nin
//! `resolveImportsImpl`i `core.nox`u (bkz. `JsonValue`nin tanımlı olduğu
//! dosya) HER programda KOŞULSUZ VE HER ZAMAN İLK sırada birleştirir, bu
//! yüzden `JsonValue`nin `class_id`si HER derlenmiş Nox programında AYNIDIR
//! — SADECE Zig-derleme-zamanında BİLİNEMEZ (`json.zig` `noxrt.o`ya AYRI
//! derlenir). Performans fazı (bkz. proje belleği): düğüm-başına bu
//! GERÇEK Nox çağrısını yapmanın (ARC retain/predecrement dengeleme dansı
//! DAHİL) `nox.json.decode()`yi domine eden bir maliyet olduğu ÖLÇÜLDÜ —
//! bu yüzden `class_id` artık ÇALIŞMA ZAMANINDA (derleme-zamanı sabiti
//! DEĞİL, `core.nox`nin GELECEKTE değişmesine karşı KENDİ KENDİNİ
//! doğrulayan bir tasarımla) BİR KEZ, aşağıdaki `makeLeaf`/`buildNode`
//! (bu YAVAŞ/keşif yolu, DEĞİŞMEDEN KALIR) İLE üretilen İLK GERÇEK
//! `JsonValue`nin tag baytından OKUNUP `g_json_value_class_id`ye
//! önbelleğe alınır — SONRAKİ HER `decode()` çağrısı `makeJsonValueDirect`/
//! `buildNodeFast`/`makeLeafFast` (aşağıya bkz.) İLE `JsonValue`yi
//! `buildPtrList`nin AYNI ilkesiyle DOĞRUDAN Zig'de inşa eder — HİÇBİR
//! Nox çağrısı, HİÇBİR retain/predecrement dengeleme dansı OLMADAN.
//!
//! **`arr`/`keys`/`vals` İÇİN `list[T]` payload'ları BU DOSYADA el ile inşa
//! edilir** (`buildPtrList`, Alt-Faz F'nin `nox_test_make_list`iyle AYNI
//! teknik — 8 bayt uzunluk başlığı + işaretçiler, `genListLit` İLE AYNI bayt
//! düzeni) — Nox'un "boş liste literali yok" KISITLAMASI yalnızca KAYNAK
//! sözdizimi/checker seviyesindedir, ÇALIŞMA ZAMANI temsili sıfır uzunluklu
//! bir `list[T]` GAYET geçerlidir; bu sayede `null`/`bool`/`number`/`string`
//! türü düğümler İÇİN (kullanılmayan `arr`/`keys`/`vals` alanları) sıfır
//! elemanlı listeler sorunsuzca üretilir — ne kendine-başvuran bir literal
//! ne de bir `MAX_CHILDREN` sınırı GEREKİR (GERÇEKTEN "tam" — keyfi derinlik).
//!
//! **`nox_json_decode_raw` HATA durumunda BİLE GEÇERLİ (null OLMAYAN) bir
//! `JsonValue` döner** (`nox.fs`nin `read_to_string_raw`ıyla AYNI "asla null
//! dönme" deseni) — `stdlib/nox/json.nox`nin `decode`si `nox_json_last_op_ok`u
//! kontrol ETMEDEN `v`ye HİÇ dokunmaz, ama bu HER İHTİMALE karşı release
//! yolunda bir null-pointer çökmesini de ÖNLER.

const std = @import("std");
const builtin = @import("builtin");
const arc = @import("../alloc/arc.zig");
const http_client = @import("http_client.zig");
const abi_layout = @import("abi_layout");
const str_mod = @import("../str.zig");
const bridge = @import("../async_rt/bridge.zig");

const dupeToNoxStr = http_client.dupeToNoxStr;
/// Faz P1.2: bkz. `strings.zig`nin AYNI re-export notu.
const LIST_HEADER_SIZE = abi_layout.LIST_HEADER_SIZE;
const FIELD_SLOT_SIZE = abi_layout.FIELD_SLOT_SIZE;
const TAG_SIZE = abi_layout.TAG_SIZE;

/// `stdlib/nox/core.nox`nin `nox_json_make_json_value` fonksiyonu — ismi
/// core.nox'ta SABİT (mangle EDİLMEZ) yazıldığından ("nox_json_make_json_value"),
/// aşağıdaki `resolveMakeJsonValue`nin `dlsym`i BU TAM ismi arar. Her çağrısı
/// `JsonValue(kind, b, n, s, arr, keys, vals)`i NORMAL bir Nox fonksiyon
/// çağrısı olarak çalıştırır (`RT_PARAM` İLK argüman — HER top-level Nox
/// fonksiyonu İÇİN KOŞULSUZ, bkz. `codegen.zig`nin `genFunction`ı).
const MakeJsonValueFn = fn (
    rt: ?*anyopaque,
    kind: i64,
    b: i32,
    n: f64,
    s: ?[*:0]const u8,
    arr: ?*anyopaque,
    keys: ?*anyopaque,
    vals: ?*anyopaque,
) callconv(.c) ?*anyopaque;

// Faz BB.1 (bkz. nox-teknik-spesifikasyon.md §3.47): `threadlocal` —
// `resolveMakeJsonValue`nin `dlsym` önbelleği İDEMPOTENT olsa da (HER
// zaman AYNI sembole çözülür), `nox.thread.spawn`in paylaşımsız modeliyle
// İKİ GERÇEK OS iş parçacığı AYNI ANDA BU önbelleğe YAZABİLİR — bu TEKNİK
// olarak TANIMSIZ DAVRANIŞ (senkronize olmayan eşzamanlı yazım) OLDUĞUNDAN,
// `g_last_op_ok`la AYNI gerekçeyle SIFIR maliyetle DÜZELTİLİR.
threadlocal var g_make_json_value_fn: ?*const MakeJsonValueFn = null;
threadlocal var g_make_json_value_resolved = false;

/// Faz LL.5 (bkz. nox-teknik-spesifikasyon.md §3.71): `std.c.dlopen`nin
/// `RTLD` parametre tipi Windows İçin `void`dir — `cycle_detector.zig`nin
/// `WinSelf`iYLE AYNI `GetModuleHandleA(null)`+`GetProcAddress` deseni
/// (o dosyanın belge notundaki "bağlayıcı bayrağı KOŞULU" AYNEN geçerli).
const WinSelf = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn GetModuleHandleA(name: ?[*:0]const u8) callconv(.c) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.c) ?*anyopaque;
} else struct {};

fn resolveMakeJsonValue() ?*const MakeJsonValueFn {
    if (g_make_json_value_resolved) return g_make_json_value_fn;
    g_make_json_value_resolved = true;
    if (builtin.os.tag == .windows) {
        const module = WinSelf.GetModuleHandleA(null) orelse return null;
        const sym = WinSelf.GetProcAddress(module, "nox_json_make_json_value") orelse return null;
        g_make_json_value_fn = @ptrCast(@alignCast(sym));
        return g_make_json_value_fn;
    }
    const handle = std.c.dlopen(null, .{ .NOW = true }) orelse return null;
    const sym = std.c.dlsym(handle, "nox_json_make_json_value") orelse return null;
    g_make_json_value_fn = @ptrCast(@alignCast(sym));
    return g_make_json_value_fn;
}

fn nox_json_make_json_value(
    rt: ?*anyopaque,
    kind: i64,
    b: i32,
    n: f64,
    s: ?[*:0]const u8,
    arr: ?*anyopaque,
    keys: ?*anyopaque,
    vals: ?*anyopaque,
) ?*anyopaque {
    const f = resolveMakeJsonValue() orelse return null;
    return f(rt, kind, b, n, s, arr, keys, vals);
}

// Faz BB.1: `nox.fs`nin `g_last_ok`ıyla AYNI gerekçeyle `threadlocal`.
// Faz MN.2: bkz. `fiber.zig`nin belge notu — fiber İÇİNDE `Fiber.
// json_last_op_ok`e, DIŞINDA (senkron üst-düzey kod) BU yedeğe düşer.
threadlocal var g_last_op_ok_fallback: bool = true;

fn jsonLastOpOkPtr() *bool {
    if (bridge.currentFiber()) |f| return &f.json_last_op_ok;
    return &g_last_op_ok_fallback;
}

export fn nox_json_last_op_ok() callconv(.c) i32 {
    return if (jsonLastOpOkPtr().*) 1 else 0;
}

/// `nox_json_make_json_value`nin (yani `JsonValue.__init__`in) `self.field =
/// param` atamalarının HER BİRİ — `param` bir `.identifier` olduğundan
/// (`isAliasingExpr`, bkz. codegen.zig) — kendi heap-yönetimli argümanını
/// (`s`/`arr`/`keys`/`vals`) BİR KEZ retain EDER. Nox KAYNAĞINDAN yapılan
/// çağrılarda bu fazlalık, ARGÜMAN olarak geçirilen İSİMLENDİRİLMİŞ yerel
/// değişkenin KENDİ kapsam-sonu release'iyle her zaman dengelenir (ör.
/// `dyn: str = ...; make_foo(dyn)` — `dyn`in $main sonundaki release'i BU
/// fazlalığı GİDERİR). BURADA ÇAĞIRAN Zig KAYNAK KODU olduğundan böyle bir
/// kapsam-sonu release ASLA üretilmez — bu yüzden HER argüman İÇİN elle BİR
/// telafi edici `nox_rc_predecrement` GEREKİR (asla gerçek serbest bırakmayı
/// TETİKLEMEZ, çünkü dönen `JsonValue`nin karşılık gelen alanı HÂLÂ bir
/// referans TUTAR — GERÇEK "iki referans" durumu YALNIZCA BİRE iner).
/// Bu olmadan HER `nox.json.decode` çağrısı `s`/`arr`/`keys`/`vals`i
/// KALICI olarak sızdırırdı (GERÇEKTEN yaşandı, DebugAllocator'ın "memory
/// address leaked" raporuyla YAKALANDI — bkz. stdlib fazı §L'nin doğrulama
/// notu).
fn callMakeJsonValue(
    rt: ?*anyopaque,
    kind: i64,
    b: i32,
    n: f64,
    s: ?[*:0]const u8,
    arr: ?*anyopaque,
    keys: ?*anyopaque,
    vals: ?*anyopaque,
) ?*anyopaque {
    const result = nox_json_make_json_value(rt, kind, b, n, s, arr, keys, vals);
    // `result == null` YALNIZCA `resolveMakeJsonValue`nin sembolü BULAMADIĞI
    // (yukarıdaki belge notundaki izole test bağlamları) DEĞİRDEĞİN bir
    // senaryoda olur — o durumda `__init__` HİÇ ÇALIŞMADIĞINDAN retain de
    // HİÇ olmamıştır, telafi edici predecrement'i ATLAMAK GEREKİR (aksi
    // halde HENÜZ hiç retain edilmemiş taze değerleri ERKEN serbest bırakırdı).
    if (result == null) return null;
    _ = str_mod.nox_str_predecrement(s);
    _ = arc.nox_rc_predecrement(arr);
    _ = arc.nox_rc_predecrement(keys);
    _ = arc.nox_rc_predecrement(vals);
    return result;
}

/// `genListLit`in ürettiği AYNI bayt düzeni (Faz U.1'den beri: 8 bayt
/// uzunluk + 8 bayt kapasite başlığı + N adet 8 baytlık işaretçi) — hem
/// `list[JsonValue]` (`arr`/`vals`) hem `list[str]` (`keys`) için AYNI
/// (ikisi de düz 8 baytlık işaretçi dizisi). Kapasite HER ZAMAN uzunluğa
/// eşittir (tam-oturan — bkz. `nox_strings_split_raw`daki AYNI gerekçe).
fn buildPtrList(rt: ?*anyopaque, items: []const ?*anyopaque) ?*anyopaque {
    const raw = arc.nox_rc_alloc(rt, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * items.len) orelse return null;
    const bytes: [*]u8 = @ptrCast(raw);
    @as(*align(1) i64, @ptrCast(bytes)).* = @intCast(items.len);
    @as(*align(1) i64, @ptrCast(bytes + 8)).* = @intCast(items.len);
    for (items, 0..) |it, i| {
        const slot = bytes + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i;
        @as(*align(1) i64, @ptrCast(slot)).* = @bitCast(@as(isize, @intCast(@intFromPtr(it))));
    }
    return @ptrCast(bytes);
}

fn emptyList(rt: ?*anyopaque) ?*anyopaque {
    return buildPtrList(rt, &.{});
}

/// Her `arr`/`keys`/`vals`/`s` alanı SKALER (null/bool/number) VEYA yarı-
/// SKALER (dizi düğümünün `keys`/`vals`'ı, obje düğümünün `arr`'ı) yapraklar
/// İçin ANLAMSIZ boş bir `list`/`""` DEĞERİDİR — ÖNCEDEN HER düğüm İçin
/// AYRI AYRI tahsis edilirdi (yaprak başına 3 boş liste + 1 boş string,
/// dizi/obje düğümü başına 2 boş liste + 1 boş string). `nox_json_decode_raw`
/// artık TEK bir paylaşılan boş liste + TEK bir paylaşılan boş string
/// (`SharedEmpties`) inşa edip TÜM düğümler arasında `nox_rc_retain`le
/// PAYLAŞIYOR — gerçek tahsis sayısı, belge boyutundan BAĞIMSIZ olarak
/// sabit (O(1)) kalıyor, yalnızca UCUZ bir refcount artışı (retain) ödeniyor.
/// GÜVENLİ: `.append()`in büyüme yolu (bkz. `genListAppend`) kapasite=0 bir
/// listeyi ASLA yerinde MUTATE etmez (her zaman YENİ bir blok tahsis eder),
/// bu yüzden paylaşılan nesne başka bir yerden "gizlice değiştirilmiş" gibi
/// GÖRÜNMEZ; TEK gerçek risk refcount muhasebesiydi — `callMakeJsonValue`nin
/// kendi retain+predecrement'i NET SIFIR olduğundan (bkz. onun belge notu),
/// paylaşılan nesneyi YENİDEN kullanmadan ÖNCE HER SEFERİNDE elle bir
/// `nox_rc_retain` ile GERÇEK bir sahiplik birimi eklemek GEREKİR — aksi
/// halde refcount HER ZAMAN 1'de kalır ve İLK release GERÇEK sahiplerden
/// BAŞKALARININ da işaretçisini geçersiz kılardı (use-after-free).
const SharedEmpties = struct {
    list: ?*anyopaque,
    str: ?[*:0]u8,
};

fn initSharedEmpties(rt: ?*anyopaque) ?SharedEmpties {
    const list = buildPtrList(rt, &.{}) orelse return null;
    const s = dupeToNoxStr(rt, "") orelse {
        arc.nox_rc_release(rt, list, LIST_HEADER_SIZE);
        return null;
    };
    return .{ .list = list, .str = s };
}

/// `nox_json_decode_raw`nin fonksiyon-ömrü boyunca tuttuğu KENDİ sahiplik
/// birimini bırakır — Nox tarafında bir yerel değişkenin kapsam-sonu
/// release'ine denk gelir (bkz. `SharedEmpties`nin belge notu).
fn releaseSharedEmpties(rt: ?*anyopaque, shared: SharedEmpties) void {
    arc.nox_rc_release(rt, shared.list, LIST_HEADER_SIZE);
    str_mod.nox_str_release(rt, shared.str);
}

fn sharedEmptyList(shared: SharedEmpties) ?*anyopaque {
    arc.nox_rc_retain(shared.list);
    return shared.list;
}

fn sharedEmptyStr(shared: SharedEmpties) ?[*:0]const u8 {
    str_mod.nox_str_retain(shared.str);
    return shared.str;
}

/// `initSharedEmpties`in KENDİSİ başarısız olduğu (OOM, pratikte HİÇ
/// gerçekleşmeyen) SON ÇARE durum İçin — `shared` HİÇ yokken BİLE geçerli
/// bir `JsonValue` üretebilmek amacıyla ESKİ, paylaşılmayan (ama HER ZAMAN
/// çalışan) yolu KORUR.
fn makeLeafUnshared(rt: ?*anyopaque, kind: i64, b: bool, n: f64, s: []const u8) ?*anyopaque {
    const dup = dupeToNoxStr(rt, s) orelse return null;
    const empty_arr = emptyList(rt) orelse return null;
    const empty_keys = emptyList(rt) orelse return null;
    const empty_vals = emptyList(rt) orelse return null;
    return callMakeJsonValue(rt, kind, if (b) 1 else 0, n, dup, empty_arr, empty_keys, empty_vals);
}

fn makeLeaf(rt: ?*anyopaque, shared: SharedEmpties, kind: i64, b: bool, n: f64, s: ?[*:0]const u8) ?*anyopaque {
    const empty_arr = sharedEmptyList(shared);
    const empty_keys = sharedEmptyList(shared);
    const empty_vals = sharedEmptyList(shared);
    return callMakeJsonValue(rt, kind, if (b) 1 else 0, n, s, empty_arr, empty_keys, empty_vals);
}

fn buildNode(rt: ?*anyopaque, allocator: std.mem.Allocator, shared: SharedEmpties, v: std.json.Value) !?*anyopaque {
    return switch (v) {
        .null => makeLeaf(rt, shared, 0, false, 0.0, sharedEmptyStr(shared)),
        .bool => |b| makeLeaf(rt, shared, 1, b, 0.0, sharedEmptyStr(shared)),
        .integer => |i| makeLeaf(rt, shared, 2, false, @floatFromInt(i), sharedEmptyStr(shared)),
        .float => |f| makeLeaf(rt, shared, 2, false, f, sharedEmptyStr(shared)),
        .number_string => |s| makeLeaf(rt, shared, 2, false, std.fmt.parseFloat(f64, s) catch 0.0, sharedEmptyStr(shared)),
        .string => |s| blk: {
            const dup = dupeToNoxStr(rt, s) orelse break :blk null;
            break :blk makeLeaf(rt, shared, 3, false, 0.0, dup);
        },
        .array => |arr_val| blk: {
            const items = try allocator.alloc(?*anyopaque, arr_val.items.len);
            for (arr_val.items, 0..) |child, i| items[i] = try buildNode(rt, allocator, shared, child);
            const arr_list = buildPtrList(rt, items) orelse break :blk null;
            const empty_keys = sharedEmptyList(shared);
            const empty_vals = sharedEmptyList(shared);
            break :blk callMakeJsonValue(rt, 4, 0, 0.0, sharedEmptyStr(shared), arr_list, empty_keys, empty_vals);
        },
        .object => |obj_val| blk: {
            const n = obj_val.count();
            const key_items = try allocator.alloc(?*anyopaque, n);
            const val_items = try allocator.alloc(?*anyopaque, n);
            for (obj_val.keys(), 0..) |k, i| key_items[i] = dupeToNoxStr(rt, k);
            for (obj_val.values(), 0..) |val, i| val_items[i] = try buildNode(rt, allocator, shared, val);
            const keys_list = buildPtrList(rt, key_items) orelse break :blk null;
            const vals_list = buildPtrList(rt, val_items) orelse break :blk null;
            const empty_arr = sharedEmptyList(shared);
            break :blk callMakeJsonValue(rt, 5, 0, 0.0, sharedEmptyStr(shared), empty_arr, keys_list, vals_list);
        },
    };
}

/// `JsonValue`nin (`TAG_SIZE` + 7 alan, `core.nox:52-61`nin `__init__`
/// atama SIRASIYLA BİREBİR: kind@8, b@16, n@24, s@32, arr@40, keys@48,
/// vals@56 — `calls.zig`nin `genConstructFromValues`ıyla BAĞIMSIZ olarak
/// doğrulandı) toplam payload boyutu.
const JSONVALUE_FIELD_COUNT: usize = 7;
const JSONVALUE_PAYLOAD_SIZE: usize = TAG_SIZE + JSONVALUE_FIELD_COUNT * FIELD_SLOT_SIZE;

/// `buildPtrList`nin AYNI ilkesi — bir `JsonValue` örneğini `nox_rc_alloc`
/// + ham alan yazımıyla DOĞRUDAN inşa eder, `__init__`e (VE onun retain/
/// `callMakeJsonValue`nin telafi edici predecrement'ine, bkz. yukarıdaki
/// belge notu) HİÇ gerek KALMADAN. `s`/`arr`/`keys`/`vals` ÇAĞIRANIN ZATEN
/// TEK bir sahiplik birimiyle (refcount katkısı = 1) ürettiği TAZE
/// değerler OLDUĞUNDAN (bkz. `dupeToNoxStr`/`buildPtrList`/
/// `sharedEmptyList`), doğrudan alan yuvasına YAZMAK (retain YOK,
/// predecrement YOK) `__init__` yolunun NET etkisiyle BİREBİR aynı
/// sonucu verir — daha AZ atomik işlemle. `class_id`, `g_json_value_
/// class_id`den (bkz. `nox_json_decode_raw`nin dallanması) GEÇİRİLİR —
/// BURADA ASLA sabit kodlanmaz.
fn makeJsonValueDirect(
    rt: ?*anyopaque,
    class_id: i64,
    kind: i64,
    b: bool,
    n: f64,
    s: ?[*:0]const u8,
    arr: ?*anyopaque,
    keys: ?*anyopaque,
    vals: ?*anyopaque,
) ?*anyopaque {
    const raw = arc.nox_rc_alloc(rt, JSONVALUE_PAYLOAD_SIZE) orelse return null;
    const bytes: [*]u8 = @ptrCast(raw);
    @as(*align(1) i64, @ptrCast(bytes)).* = class_id;
    @as(*align(1) i64, @ptrCast(bytes + FIELD_SLOT_SIZE * 1)).* = kind;
    @as(*align(1) i64, @ptrCast(bytes + FIELD_SLOT_SIZE * 2)).* = if (b) 1 else 0;
    @as(*align(1) f64, @ptrCast(bytes + FIELD_SLOT_SIZE * 3)).* = n;
    @as(*align(1) ?[*:0]const u8, @ptrCast(bytes + FIELD_SLOT_SIZE * 4)).* = s;
    @as(*align(1) ?*anyopaque, @ptrCast(bytes + FIELD_SLOT_SIZE * 5)).* = arr;
    @as(*align(1) ?*anyopaque, @ptrCast(bytes + FIELD_SLOT_SIZE * 6)).* = keys;
    @as(*align(1) ?*anyopaque, @ptrCast(bytes + FIELD_SLOT_SIZE * 7)).* = vals;
    return raw;
}

fn makeLeafFast(rt: ?*anyopaque, shared: SharedEmpties, class_id: i64, kind: i64, b: bool, n: f64, s: ?[*:0]const u8) ?*anyopaque {
    const empty_arr = sharedEmptyList(shared);
    const empty_keys = sharedEmptyList(shared);
    const empty_vals = sharedEmptyList(shared);
    return makeJsonValueDirect(rt, class_id, kind, b, n, s, empty_arr, empty_keys, empty_vals);
}

/// `buildNode`nin BİREBİR yapısal kopyası — TEK fark: `callMakeJsonValue`
/// (derlenmiş Nox'a geri dönen YAVAŞ yol) YERİNE `makeJsonValueDirect`
/// (doğrudan Zig inşası) çağrılır. `class_id` `g_json_value_class_id`den
/// ZATEN keşfedilmiş OLARAK gelir (bkz. `nox_json_decode_raw`).
fn buildNodeFast(rt: ?*anyopaque, allocator: std.mem.Allocator, shared: SharedEmpties, class_id: i64, v: std.json.Value) !?*anyopaque {
    return switch (v) {
        .null => makeLeafFast(rt, shared, class_id, 0, false, 0.0, sharedEmptyStr(shared)),
        .bool => |b| makeLeafFast(rt, shared, class_id, 1, b, 0.0, sharedEmptyStr(shared)),
        .integer => |i| makeLeafFast(rt, shared, class_id, 2, false, @floatFromInt(i), sharedEmptyStr(shared)),
        .float => |f| makeLeafFast(rt, shared, class_id, 2, false, f, sharedEmptyStr(shared)),
        .number_string => |s| makeLeafFast(rt, shared, class_id, 2, false, std.fmt.parseFloat(f64, s) catch 0.0, sharedEmptyStr(shared)),
        .string => |s| blk: {
            const dup = dupeToNoxStr(rt, s) orelse break :blk null;
            break :blk makeLeafFast(rt, shared, class_id, 3, false, 0.0, dup);
        },
        .array => |arr_val| blk: {
            const items = try allocator.alloc(?*anyopaque, arr_val.items.len);
            for (arr_val.items, 0..) |child, i| items[i] = try buildNodeFast(rt, allocator, shared, class_id, child);
            const arr_list = buildPtrList(rt, items) orelse break :blk null;
            const empty_keys = sharedEmptyList(shared);
            const empty_vals = sharedEmptyList(shared);
            break :blk makeJsonValueDirect(rt, class_id, 4, false, 0.0, sharedEmptyStr(shared), arr_list, empty_keys, empty_vals);
        },
        .object => |obj_val| blk: {
            const n = obj_val.count();
            const key_items = try allocator.alloc(?*anyopaque, n);
            const val_items = try allocator.alloc(?*anyopaque, n);
            for (obj_val.keys(), 0..) |k, i| key_items[i] = dupeToNoxStr(rt, k);
            for (obj_val.values(), 0..) |val, i| val_items[i] = try buildNodeFast(rt, allocator, shared, class_id, val);
            const keys_list = buildPtrList(rt, key_items) orelse break :blk null;
            const vals_list = buildPtrList(rt, val_items) orelse break :blk null;
            const empty_arr = sharedEmptyList(shared);
            break :blk makeJsonValueDirect(rt, class_id, 5, false, 0.0, sharedEmptyStr(shared), empty_arr, keys_list, vals_list);
        },
    };
}

/// `JsonValue`nin `class_id`si — `nox_json_decode_raw`nin İLK çağrısında
/// (bu OS iş parçacığında) MEVCUT yavaş/keşif yolundan (`buildNode`)
/// dönen GERÇEK bir örneğin tag baytından OKUNUP BİR KEZ önbelleğe alınır
/// (bkz. dosya üstü belge notu — `core.nox`nin HER programda İLK sırada
/// birleştirilmesi SAYESİNDE bu değer HER programda AYNIDIR, ama YİNE DE
/// burada SABİT KODLANMAZ). `g_make_json_value_fn`/`g_make_json_value_
/// resolved`İLE AYNI `threadlocal` gerekçesi (Faz BB.1, satır 81-88).
threadlocal var g_json_value_class_id: ?i64 = null;

export fn nox_json_decode_raw(rt: ?*anyopaque, s: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    // NOT: `s`in null olduğu dal İçin `str_mod.nox_str_slice`e DÜŞMEYİZ —
    // o yol yalnızca GERÇEK bir Nox `str` (görünmez başlıklı) BEKLER, boş
    // Zig dize literal'i "" BUNU SAĞLAMAZ (başlıksız bellek okunması OLURDU).
    const slice = if (s) |sp| str_mod.nox_str_slice(sp) else "";

    // Dil stabilizasyonu fazı §M.6: ÖNCEDEN `std.json.parseFromSlice` VE
    // `buildNode`nin dizi/obje dalları `std.heap.page_allocator`a DOĞRUDAN
    // (HER JSON düğümü/liste KENDİ AYRI tahsisini alarak) çok sayıda küçük
    // tahsis yapıyordu. ARTIK TEK bir `ArenaAllocator` (page_allocator'ı
    // SARAN) kullanılıyor — TÜM ayrıştırma + geçici Zig-taraflı dilimler
    // BU arena ÜZERİNDEN yapılır, fonksiyon DÖNMEDEN ÖNCE `arena.deinit()`
    // TEK seferde HEPSİNİ serbest bırakır (`rt`/ARC'a GEÇEN `dupeToNoxStr`/
    // `buildPtrList` çıktıları ETKİLENMEZ, onlar ZATEN AYRI/`nox_rc_alloc`
    // tabanlı). `std.json.parseFromSlice`nin KENDİ `Parsed(T).deinit()`ı
    // (kendi İÇ arenasını serbest bırakan) ARTIK ayrıca ÇAĞRILMIYOR — dış
    // arena zaten HER ŞEYİ (iç içe olsa BİLE) tek seferde temizliyor.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, slice, .{}) catch {
        jsonLastOpOkPtr().* = false;
        return makeLeafUnshared(rt, 0, false, 0.0, "");
    };

    // `g_last_op_ok`, JSON SÖZDİZİMİNİN geçerliliğini yansıtır — bir
    // AYIRICI (allocator) arızası (`rt=null` İLE çağrılan İZOLE test
    // bağlamlarında `nox_rc_alloc`nin havuz hızlı-yolunun GERÇEK bir
    // `RuntimeState` GEREKTİRMESİ YÜZÜNDEN OLABİLİR, GERÇEK Nox
    // programlarında `rt` HİÇBİR ZAMAN null DEĞİLDİR) BUNU DEĞİŞTİRMEMELİ
    // — buraya SADECE parse BAŞARILI OLDUKTAN SONRA ulaşılır, bu yüzden
    // `initSharedEmpties` başarısız olsa BİLE `ok=true` KALIR (GERÇEK bir
    // BUG olarak bulunup düzeltildi: ÖNCEDEN bu adım parse'DAN ÖNCE
    // yapılıp başarısızlıkta koşulsuz `g_last_op_ok=false` YAZIYORDU —
    // `rt=null`lı testte GEÇERLİ JSON'u BİLE "geçersiz" olarak işaretledi).
    const shared = initSharedEmpties(rt) orelse {
        jsonLastOpOkPtr().* = true;
        return makeLeafUnshared(rt, 0, false, 0.0, "");
    };
    defer releaseSharedEmpties(rt, shared);

    if (g_json_value_class_id) |cid| {
        const root = buildNodeFast(rt, allocator, shared, cid, parsed.value) catch {
            jsonLastOpOkPtr().* = false;
            return makeLeafFast(rt, shared, cid, 0, false, 0.0, sharedEmptyStr(shared));
        };
        jsonLastOpOkPtr().* = true;
        return root orelse makeLeafFast(rt, shared, cid, 0, false, 0.0, sharedEmptyStr(shared));
    }

    // İLK çağrı (bu OS iş parçacığında): `class_id` HENÜZ bilinmiyor —
    // MEVCUT yavaş/kendi-kendini-doğrulayan yoldan geç, DÖNEN kökün tag
    // baytından `class_id`yi OKUYUP TÜM sonraki çağrılar İçİn önbelleğe al.
    const root = buildNode(rt, allocator, shared, parsed.value) catch {
        jsonLastOpOkPtr().* = false;
        return makeLeaf(rt, shared, 0, false, 0.0, sharedEmptyStr(shared));
    };
    jsonLastOpOkPtr().* = true;
    if (root) |r| {
        g_json_value_class_id = @as(*align(1) const i64, @ptrCast(r)).*;
        return r;
    }
    return makeLeaf(rt, shared, 0, false, 0.0, sharedEmptyStr(shared));
}

// Faz BB.1: `g_last_op_ok`nin `threadlocal` OLMASININ, İKİ GERÇEK OS iş
// parçacığının AYNI ANDA `nox.json.decode` ÇAĞIRDIĞINDA (biri BOZUK, diğeri
// GEÇERLİ JSON İLE) birbirinin bayrağını EZMEDİĞİNİ kanıtlar.
test "g_last_op_ok threadlocal: iki gerçek OS iş parçacığı bağımsız bayrak görür" {
    // `nox_json_decode_raw`nin `s` parametresi `str_mod.nox_str_slice`den
    // GEÇTİĞİNDEN (bkz. yukarısı) GEÇERLİ bir Nox `str` başlığı GEREKİR —
    // çıplak Zig LİTERALLERİNİ DOĞRUDAN geçirmek `regex.zig`nin AYNI belge
    // notunda UYARDIĞI tuzak. TEK bir `rt` İLE İNŞA EDİLİP HER İKİ iş
    // parçacığı ARASINDA (SADECE OKUNDUĞU İÇİN GÜVENLE) PAYLAŞILIR.
    const asap = @import("../alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const malformed_json = str_mod.nox_str_from_bytes(rt, "{ bozuk") orelse return error.AllocFailed;
    defer str_mod.nox_str_release(rt, malformed_json);
    const valid_json = str_mod.nox_str_from_bytes(rt, "{\"a\": 1}") orelse return error.AllocFailed;
    defer str_mod.nox_str_release(rt, valid_json);

    const Worker = struct {
        fn malformed(iterations: usize, s: [*:0]const u8, all_false: *bool) void {
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                _ = nox_json_decode_raw(null, s);
                if (nox_json_last_op_ok() != 0) all_false.* = false;
            }
        }
        fn valid(iterations: usize, s: [*:0]const u8, all_true: *bool) void {
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                _ = nox_json_decode_raw(null, s);
                if (nox_json_last_op_ok() == 0) all_true.* = false;
            }
        }
    };

    var all_false = true;
    var all_true = true;
    const thread_a = try std.Thread.spawn(.{}, Worker.malformed, .{ 2000, malformed_json, &all_false });
    const thread_b = try std.Thread.spawn(.{}, Worker.valid, .{ 2000, valid_json, &all_true });
    thread_a.join();
    thread_b.join();

    try std.testing.expect(all_false);
    try std.testing.expect(all_true);
}
