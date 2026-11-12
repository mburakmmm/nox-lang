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
const scratch_util = @import("shim_util.zig");
const arc = @import("../alloc/arc.zig");
const dispatch_registry = @import("../alloc/dispatch_registry.zig");
const http_client = @import("shim_util.zig");
const abi_layout = @import("abi_layout");
const str_mod = @import("../str.zig");
const bridge = @import("../async_rt/bridge.zig");

const dupeToNoxStr = http_client.dupeToNoxStr;
/// Faz P1.2: bkz. `strings.zig`nin AYNI re-export notu.
const LIST_HEADER_SIZE = abi_layout.LIST_HEADER_SIZE;
const FIELD_SLOT_SIZE = abi_layout.FIELD_SLOT_SIZE;
const TAG_SIZE = abi_layout.TAG_SIZE;
const abi_ptr = @import("../abi_ptr.zig");

/// `stdlib/nox/core.nox`nin `nox_json_make_json_value` fonksiyonu — ismi
/// core.nox'ta SABİT (mangle EDİLMEZ) yazıldığından ("nox_json_make_json_value").
/// Her çağrısı `JsonValue(kind, b, n, s, arr, keys, vals)`i NORMAL bir Nox
/// fonksiyon çağrısı olarak çalıştırır (`RT_PARAM` İLK argüman — HER top-level
/// Nox fonksiyonu İÇİN KOŞULSUZ, bkz. `codegen.zig`nin `genFunction`ı). Faz
/// F.0.1'DEN İTİBAREN `dispatch_registry`nin (bkz. onun modül üstü notu)
/// program-başlangıcında BİR KEZ kaydedilen, statik tablosu ÜZERİNDEN
/// erişilir (ÖNCEDEN `dlsym` İLE ÇALIŞMA ZAMANINDA aranıyordu).
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
    const f = dispatch_registry.makeJsonValueFn() orelse return null;
    return abi_ptr.ptr(?*anyopaque, f(abi_ptr.arg(rt), kind, b, n, abi_ptr.arg(s), abi_ptr.arg(arr), abi_ptr.arg(keys), abi_ptr.arg(vals)));
}

// Faz BB.1: `nox.fs`nin `g_last_ok`ıyla AYNI gerekçeyle `threadlocal`.
// Faz MN.2: bkz. `fiber.zig`nin belge notu — fiber İÇİNDE `Fiber.
// json_last_op_ok`e, DIŞINDA (senkron üst-düzey kod) BU yedeğe düşer.
const LastOkFallbackSlot = scratch_util.TlsSlot(bool, true);

fn jsonLastOpOkPtr() *bool {
    if (bridge.currentFiber()) |f| return &f.json_last_op_ok;
    return &LastOkFallbackSlot.value;
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
    // `result == null` YALNIZCA `dispatch_registry.makeJsonValueFn()`in
    // KAYITLI OLMADIĞI (ör. `noxrt_test` GİBİ, GERÇEK bir Nox programının
    // `$main`'inin HİÇ ÇALIŞMADIĞI izole test bağlamları) senaryoda olur —
    // o durumda `__init__` HİÇ ÇALIŞMADIĞINDAN retain de HİÇ olmamıştır,
    // telafi edici predecrement'i ATLAMAK GEREKİR (aksi halde HENÜZ hiç
    // retain edilmemiş taze değerleri ERKEN serbest bırakırdı).
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
        @as(*align(1) i64, @ptrCast(slot)).* = @as(i64, @bitCast(@as(u64, @intFromPtr(it))));
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

/// 2^53'ten büyük/eşit büyüklükteki tamsayılar `f64`e SIĞMAZ (`9007199254740993` → `9007199254740992`). Bu durumda sayının tam ondalık metni yaprağın `s` alanında
/// da tutulur (`nox.json.as_int`/`number_text` onu okur, `dump` onu aynen yazar); diğer sayılarda `s` paylaşılan boş dizedir (ek tahsis yok).
fn exactNumberText(rt: ?*anyopaque, shared: SharedEmpties, text: []const u8) ?[*:0]const u8 {
    return dupeToNoxStr(rt, text) orelse sharedEmptyStr(shared);
}

fn isPlainBigInteger(s: []const u8) bool {
    var digits = s;
    if (digits.len > 0 and digits[0] == '-') digits = digits[1..];
    if (digits.len < 16) return false;
    for (digits) |c| if (c < '0' or c > '9') return false;
    return true;
}

fn buildNode(rt: ?*anyopaque, allocator: std.mem.Allocator, shared: SharedEmpties, v: std.json.Value) !?*anyopaque {
    return switch (v) {
        .null => makeLeaf(rt, shared, 0, false, 0.0, sharedEmptyStr(shared)),
        .bool => |b| makeLeaf(rt, shared, 1, b, 0.0, sharedEmptyStr(shared)),
        .integer => |i| blk: {
            if (i >= (1 << 53) or i <= -(1 << 53)) {
                var buf: [24]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "{d}", .{i}) catch break :blk makeLeaf(rt, shared, 2, false, @floatFromInt(i), sharedEmptyStr(shared));
                break :blk makeLeaf(rt, shared, 2, false, @floatFromInt(i), exactNumberText(rt, shared, text));
            }
            break :blk makeLeaf(rt, shared, 2, false, @floatFromInt(i), sharedEmptyStr(shared));
        },
        .float => |f| makeLeaf(rt, shared, 2, false, f, sharedEmptyStr(shared)),
        .number_string => |s| makeLeaf(rt, shared, 2, false, std.fmt.parseFloat(f64, s) catch 0.0, if (isPlainBigInteger(s)) exactNumberText(rt, shared, s) else sharedEmptyStr(shared)),
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
    @as(*align(1) abi_ptr.Slot, @ptrCast(bytes + FIELD_SLOT_SIZE * 4)).* = abi_ptr.slot(s);
    @as(*align(1) abi_ptr.Slot, @ptrCast(bytes + FIELD_SLOT_SIZE * 5)).* = abi_ptr.slot(arr);
    @as(*align(1) abi_ptr.Slot, @ptrCast(bytes + FIELD_SLOT_SIZE * 6)).* = abi_ptr.slot(keys);
    @as(*align(1) abi_ptr.Slot, @ptrCast(bytes + FIELD_SLOT_SIZE * 7)).* = abi_ptr.slot(vals);
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
        .integer => |i| blk: {
            if (i >= (1 << 53) or i <= -(1 << 53)) {
                var buf: [24]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "{d}", .{i}) catch break :blk makeLeafFast(rt, shared, class_id, 2, false, @floatFromInt(i), sharedEmptyStr(shared));
                break :blk makeLeafFast(rt, shared, class_id, 2, false, @floatFromInt(i), exactNumberText(rt, shared, text));
            }
            break :blk makeLeafFast(rt, shared, class_id, 2, false, @floatFromInt(i), sharedEmptyStr(shared));
        },
        .float => |f| makeLeafFast(rt, shared, class_id, 2, false, f, sharedEmptyStr(shared)),
        .number_string => |s| makeLeafFast(rt, shared, class_id, 2, false, std.fmt.parseFloat(f64, s) catch 0.0, if (isPlainBigInteger(s)) exactNumberText(rt, shared, s) else sharedEmptyStr(shared)),
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
/// burada SABİT KODLANMAZ). `g_last_op_ok_fallback`la AYNI `threadlocal`
/// gerekçesi (Faz BB.1) — İDEMPOTENT bir önbellek OLSA da, `nox.thread.
/// spawn`in paylaşımsız modeliyle İKİ GERÇEK OS iş parçacığı AYNI ANDA BU
/// önbelleğe senkronize-olmadan YAZABİLİR.
const JsonValueClassIdSlot = scratch_util.TlsSlot(?i64, null);

/// `decode()`nin GEÇİCİ ayrıştırma-ağacı arabelleği İçİn kullandığı arena
/// — `lowlevel.zig`nin `nox_arena_create`/`nox_arena_destroy`sıYLA AYNI
/// ilke (Faz M.7: `reset` fresh init/deinit'in mmap/munmap syscall
/// ÇİFTİNDEN KURTARIR — `sample` İLE ÖLÇÜLDÜ: bu ÇİFT, `nox_json_decode_
/// raw`nin TOPLAM maliyetinin ~%62'sini oluşturuyordu, JSON'un boyutundan
/// TAMAMEN BAĞIMSIZ, `std.heap.page_allocator` HİÇBİR önbellekleme
/// YAPMADIĞINDAN HER init/deinit'in KENDİSİ ham bir syscall ÇİFTİYDİ),
/// AMA `threadlocal` (`g_json_value_class_id`İLE AYNI desen) —
/// `lowlevel.zig`nin ÇALIŞMA-ZAMANI DebugAllocator'ını SARMASININ AKSİNE
/// bu arena `std.heap.page_allocator`ı DOĞRUDAN SARDIĞINDAN (ARC'ın KENDİ
/// leak-izleme muhasebesiyle HİÇBİR etkileşimi YOK), `lowlevel.zig`nin
/// `builtin.mode != .Debug` KOŞULUNA GEREK YOK — HER build modunda
/// güvenli.
// v2.1.57: çıplak çekirdekte (freestanding, wasm DIŞI) FS tabanı kurulu değildir; `threadlocal` erişimi (#GP) yerine düz global kullanılır (tek iş parçacığı). random.zig'in AYNI deseni.
const DecodeArenaSlot = if (scratch_util.bare_kernel) struct {
    var value: ?std.heap.ArenaAllocator = null;
} else struct {
    threadlocal var value: ?std.heap.ArenaAllocator = null;
};

/// Nadir/büyük bir payload'ın thread-yerel arenayı KALICI olarak
/// şişirmesini ÖNLEMEK İçİn üst sınır (`reset`in KENDİ `.retain_with_
/// limit` modu) — TİPİK (küçük) payload'lar İçİn arena mmap/munmap
/// OLMADAN yeniden kullanılır, bunu AŞAN nadir isteklerde fazlalık
/// serbest bırakılır.
const DECODE_ARENA_RETAIN_LIMIT: usize = 64 * 1024;

/// GG.23 (bkz. plan dosyası "fiber-stack sertleştirmesi", Madde 2):
/// `std.json.parseFromSlice`nin KENDİ İÇ özyinelemesi (Zig std'sinin
/// KENDİSİ, DEĞİŞTİRİLEMEZ) VE `buildNode`/`buildNodeFast`nin (aşağıda,
/// ZATEN AYRIŞTIRILMIŞ ağacı GEZEN AYRI bir özyineleme geçişi) İKİSİ DE
/// SINIRSIZ derinlikte iç-içe geçmiş `[`/`{` girdisinde fiber'ın SABİT
/// yığınını AŞABİLİR (bkz. plan dosyasının araştırma bulguları — ~137
/// seviyede 256 KiB AŞILIYORDU). Bu SAF/yan-etkisiz ön-tarama, `slice`i
/// TEK GEÇİŞTE (string literalleri/escape'leri ATLAYARAK, SADECE metin-
/// DIŞI `[`/`{`/`]`/`}` karakterlerini SAYARAK) tarar — HERHANGİ bir
/// noktada derinlik `max_depth`i AŞARSA `true` döner (çağıran, `std.json.
/// parseFromSlice`ı HİÇ ÇAĞIRMADAN, MEVCUT "geçersiz JSON" hata yoluna
/// düşer — bkz. `nox_json_decode_raw`nin çağrı sitesi).
fn jsonNestingDepthExceeds(s: []const u8, max_depth: usize) bool {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (s) |c| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '[', '{' => {
                depth += 1;
                if (depth > max_depth) return true;
            },
            ']', '}' => {
                if (depth > 0) depth -= 1;
            },
            else => {},
        }
    }
    return false;
}

/// GG.23: gerçek HİÇBİR API/konfigürasyon formatının İHTİYAÇ DUYMADIĞI
/// kadar CÖMERT bir sınır (bkz. plan dosyasının Madde 4 — yeniden-ölçüm
/// SONRASI STACK_SIZE hedefine göre KALİBRE edilir, bu İLK değer bir
/// başlangıç noktasıdır).
const MAX_JSON_NESTING_DEPTH: usize = 32;

/// v1.142.1 (bkz. nox-teknik-spesifikasyon.md §3.241): `nox.json.dump_string`
/// ÖNCEDEN saf Nox'ta karakter-karakter dönüyordu (HER karakter için
/// `s[i]` ile yeni bir `str` + `out + c` ile yeni bir birleştirme tahsisi
/// — O(n²) tahsis; Aether echo profilinde iki küçük dize için bile
/// thread süresinin ~%4'ü). `bytes`ı çift tırnaklı, JSON-kaçışlı bir
/// UTF-8 dizeye çevirir: `"` `\` `\n` `\t` `\r` `\b` `\f` kısa
/// kaçışlarla, DİĞER C0 kontrol karakterleri (0-31) `\u00XX` ile (JSON
/// bir dize içindeki HER ham kontrol karakterinin kaçışlanmasını zorunlu
/// kılar; eski saf-Nox sürümü bunları kaçışlamıyordu, Zig'in `std.json`ı
/// o çıktıyı geri OKUYAMIYORDU). 0x7F ve ≥0x80 baytlar (UTF-8 devam
/// baytları dahil) OLDUĞU GİBİ geçer. Çağıran `allocator`dan alınan
/// dilimin sahibidir.
fn escapeJsonString(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![]u8 {
    var extra: usize = 0;
    for (bytes) |c| {
        extra += switch (c) {
            '"', '\\', '\n', '\t', '\r', 8, 12 => 1,
            0...7, 11, 14...31 => 5,
            else => 0,
        };
    }
    const out = try allocator.alloc(u8, bytes.len + extra + 2);
    var w: usize = 0;
    out[w] = '"';
    w += 1;
    for (bytes) |c| {
        switch (c) {
            '"' => {
                out[w] = '\\';
                out[w + 1] = '"';
                w += 2;
            },
            '\\' => {
                out[w] = '\\';
                out[w + 1] = '\\';
                w += 2;
            },
            '\n' => {
                out[w] = '\\';
                out[w + 1] = 'n';
                w += 2;
            },
            '\t' => {
                out[w] = '\\';
                out[w + 1] = 't';
                w += 2;
            },
            '\r' => {
                out[w] = '\\';
                out[w + 1] = 'r';
                w += 2;
            },
            8 => {
                out[w] = '\\';
                out[w + 1] = 'b';
                w += 2;
            },
            12 => {
                out[w] = '\\';
                out[w + 1] = 'f';
                w += 2;
            },
            0...7, 11, 14...31 => {
                const hex = "0123456789abcdef";
                out[w] = '\\';
                out[w + 1] = 'u';
                out[w + 2] = '0';
                out[w + 3] = '0';
                out[w + 4] = hex[c >> 4];
                out[w + 5] = hex[c & 0xF];
                w += 6;
            },
            else => {
                out[w] = c;
                w += 1;
            },
        }
    }
    out[w] = '"';
    return out;
}

export fn nox_json_escape_string_raw(rt: ?*anyopaque, s: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const slice = if (s) |sp| str_mod.nox_str_slice(sp) else "";
    // Küçük dizeler (HTTP/JSON'un ezici çoğunluğu) için yığın tamponu:
    // `page_allocator` HER çağrıda mmap/munmap sistem çağrısı yapar (ölçüldü:
    // Aether echo'da istek başına CPU'yu ~2x ARTIRDI). Yalnızca 4 KiB'ı
    // aşan kaçışlı çıktı `page_allocator`a düşer.
    var sfa = std.heap.stackFallback(4096, scratch_util.scratchAllocator());
    const allocator = sfa.get();
    const escaped = escapeJsonString(allocator, slice) catch return null;
    defer allocator.free(escaped);
    return dupeToNoxStr(rt, escaped);
}

// ---------------------------------------------------------------------------------------------------------------------------------------------------------------
// v2.1.61: DOĞRUDAN-DÜĞÜM JSON ayrıştırıcısı. `std.json.parseFromSlice` (Scanner + ara `Value` ağacı + düğüm kopyaları) yerine iki geçiş:
//   1. `validate`: ALLOCATION'SIZ (yalnızca yinelenen-anahtar denetimi için küçük arena listesi) tam dilbilgisi denetimi — `std.json`un kabul/ret kümesiyle AYNI: katı JSON dilbilgisi, kontrol
//      karakteri (< 0x20) yasak, geçerli UTF-8 şart, `\uXXXX` vekil çiftleri eşli olmalı, yinelenen anahtar = hata, iç içe kapsayıcı derinliği <= MAX_JSON_NESTING_DEPTH.
//   2. `build`: doğrulanmış girdiden doğrudan `JsonValue` düğümleri üretir (sözdizimi hatası olamaz; tahsis hatası `null` yayar).
// `std.json` tabanlı eski yol (ilk çağrıda sınıf keşfi için) ve `jsonNestingDepthExceeds` REFERANS olarak kalır; farksal testler (aşağıda) ve `json_fast_parser_equivalence` golden'ı ikisini karşılaştırır.
// ---------------------------------------------------------------------------------------------------------------------------------------------------------------
const FastJson = struct {
    s: []const u8,
    i: usize = 0,
    allocator: std.mem.Allocator,
    keys: std.ArrayListUnmanaged(KeySpan) = .empty,
    scratch: std.ArrayListUnmanaged(u8) = .empty,
    scratch2: std.ArrayListUnmanaged(u8) = .empty,
    /// `JsonValue` sınıf kimliği; bilinmiyorsa (bu iş parçacığında ilk ayrıştırma) İLK düğüm Nox kurucusundan (`callMakeJsonValue`) üretilir ve kimlik oradan okunur.
    cid: ?i64 = null,

    const KeySpan = struct { start: usize, end: usize, esc: bool };

    fn ws(self: *FastJson) void {
        while (self.i < self.s.len) : (self.i += 1) {
            switch (self.s[self.i]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    fn lit(self: *FastJson, word: []const u8) bool {
        if (self.s.len - self.i < word.len or !std.mem.eql(u8, self.s[self.i..][0..word.len], word)) return false;
        self.i += word.len;
        return true;
    }

    fn hex4(self: *const FastJson, at: usize) ?u16 {
        if (at + 4 > self.s.len) return null;
        var v: u16 = 0;
        for (self.s[at..][0..4]) |c| {
            const d: u16 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return null,
            };
            v = (v << 4) | d;
        }
        return v;
    }

    /// `self.i` açılış tırnağında. Başarıda `self.i` kapanış tırnağının ARDINDA; `start`/`end` ham içerik, `esc` kaçış içerir mi.
    fn validString(self: *FastJson, start: *usize, end: *usize, esc: *bool) bool {
        self.i += 1;
        start.* = self.i;
        esc.* = false;
        while (self.i < self.s.len) {
            const c = self.s[self.i];
            if (c == '"') {
                end.* = self.i;
                self.i += 1;
                return true;
            }
            if (c < 0x20) return false;
            if (c == '\\') {
                esc.* = true;
                if (self.i + 1 >= self.s.len) return false;
                switch (self.s[self.i + 1]) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => self.i += 2,
                    'u' => {
                        const hi = self.hex4(self.i + 2) orelse return false;
                        self.i += 6;
                        if (hi >= 0xD800 and hi <= 0xDBFF) {
                            if (self.i + 1 >= self.s.len or self.s[self.i] != '\\' or self.s[self.i + 1] != 'u') return false;
                            const lo = self.hex4(self.i + 2) orelse return false;
                            if (lo < 0xDC00 or lo > 0xDFFF) return false;
                            self.i += 6;
                        } else if (hi >= 0xDC00 and hi <= 0xDFFF) {
                            return false;
                        }
                    },
                    else => return false,
                }
                continue;
            }
            if (c < 0x80) {
                self.i += 1;
                continue;
            }
            const n = std.unicode.utf8ByteSequenceLength(c) catch return false;
            if (self.i + n > self.s.len) return false;
            _ = std.unicode.utf8Decode(self.s[self.i..][0..n]) catch return false;
            self.i += n;
        }
        return false;
    }

    fn validNumber(self: *FastJson) bool {
        var i = self.i;
        const s = self.s;
        if (i < s.len and s[i] == '-') i += 1;
        if (i >= s.len) return false;
        if (s[i] == '0') {
            i += 1;
        } else if (s[i] >= '1' and s[i] <= '9') {
            while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        } else return false;
        if (i < s.len and s[i] == '.') {
            i += 1;
            const d0 = i;
            while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
            if (i == d0) return false;
        }
        if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
            i += 1;
            if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
            const d0 = i;
            while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
            if (i == d0) return false;
        }
        self.i = i;
        return true;
    }

    fn validValue(self: *FastJson, open_depth: usize) bool {
        if (self.i >= self.s.len) return false;
        switch (self.s[self.i]) {
            '{' => return self.validObject(open_depth + 1),
            '[' => return self.validArray(open_depth + 1),
            '"' => {
                var a: usize = 0;
                var b: usize = 0;
                var e = false;
                return self.validString(&a, &b, &e);
            },
            't' => return self.lit("true"),
            'f' => return self.lit("false"),
            'n' => return self.lit("null"),
            '-', '0'...'9' => return self.validNumber(),
            else => return false,
        }
    }

    fn validArray(self: *FastJson, depth: usize) bool {
        if (depth > MAX_JSON_NESTING_DEPTH) return false;
        self.i += 1;
        self.ws();
        if (self.i < self.s.len and self.s[self.i] == ']') {
            self.i += 1;
            return true;
        }
        while (true) {
            self.ws();
            if (!self.validValue(depth)) return false;
            self.ws();
            if (self.i >= self.s.len) return false;
            switch (self.s[self.i]) {
                ',' => self.i += 1,
                ']' => {
                    self.i += 1;
                    return true;
                },
                else => return false,
            }
        }
    }

    fn validObject(self: *FastJson, depth: usize) bool {
        if (depth > MAX_JSON_NESTING_DEPTH) return false;
        self.i += 1;
        self.ws();
        if (self.i < self.s.len and self.s[self.i] == '}') {
            self.i += 1;
            return true;
        }
        const key_base = self.keys.items.len;
        while (true) {
            self.ws();
            if (self.i >= self.s.len or self.s[self.i] != '"') return false;
            var a: usize = 0;
            var b: usize = 0;
            var e = false;
            if (!self.validString(&a, &b, &e)) return false;
            self.keys.append(self.allocator, .{ .start = a, .end = b, .esc = e }) catch return false;
            self.ws();
            if (self.i >= self.s.len or self.s[self.i] != ':') return false;
            self.i += 1;
            self.ws();
            if (!self.validValue(depth)) return false;
            self.ws();
            if (self.i >= self.s.len) return false;
            switch (self.s[self.i]) {
                ',' => self.i += 1,
                '}' => {
                    self.i += 1;
                    const ok = !self.hasDuplicate(key_base);
                    self.keys.shrinkRetainingCapacity(key_base);
                    return ok;
                },
                else => return false,
            }
        }
    }

    /// `slot` indeksindeki anahtarın KAÇIŞSIZ baytları (`buf` yalnızca kaçışlı anahtarlarda kullanılır).
    fn keyBytes(self: *FastJson, k: KeySpan, buf: *std.ArrayListUnmanaged(u8)) []const u8 {
        if (!k.esc) return self.s[k.start..k.end];
        buf.clearRetainingCapacity();
        self.unescapeInto(buf, self.s[k.start..k.end]) catch return self.s[k.start..k.end];
        return buf.items;
    }

    fn hasDuplicate(self: *FastJson, base: usize) bool {
        const ks = self.keys.items[base..];
        if (ks.len < 2) return false;
        if (ks.len <= 8) {
            for (ks, 0..) |a, ai| {
                const ab = self.keyBytes(a, &self.scratch);
                for (ks[ai + 1 ..]) |b| {
                    const bb = self.keyBytes(b, &self.scratch2);
                    if (std.mem.eql(u8, ab, bb)) return true;
                }
            }
            return false;
        }
        // Büyük nesneler: açık adresli karma tablosu (anahtar baytları KAÇIŞSIZ karşılaştırılır).
        var cap: usize = 16;
        while (cap < ks.len * 2) cap *= 2;
        const table = self.allocator.alloc(u32, cap) catch return true; // bellek yoksa güvenli tarafta: hata say
        defer self.allocator.free(table);
        @memset(table, std.math.maxInt(u32));
        for (ks, 0..) |a, ai| {
            const ab = self.keyBytes(a, &self.scratch);
            var pos: usize = @intCast(std.hash.Wyhash.hash(0, ab) & (cap - 1));
            while (table[pos] != std.math.maxInt(u32)) : (pos = (pos + 1) & (cap - 1)) {
                const other = ks[table[pos]];
                const ob = self.keyBytes(other, &self.scratch2);
                if (std.mem.eql(u8, ab, ob)) return true;
            }
            table[pos] = @intCast(ai);
        }
        return false;
    }

    /// Doğrulanmış ham dize içeriğini (kaçışlar dahil) çözülmüş UTF-8 baytlarına çevirip `out`a ekler.
    fn unescapeInto(self: *FastJson, out: *std.ArrayListUnmanaged(u8), raw: []const u8) !void {
        var j: usize = 0;
        while (j < raw.len) {
            const c = raw[j];
            if (c != '\\') {
                // Kaçışsız çalışmayı toplu kopyala.
                var k = j + 1;
                while (k < raw.len and raw[k] != '\\') k += 1;
                try out.appendSlice(self.allocator, raw[j..k]);
                j = k;
                continue;
            }
            const e = raw[j + 1];
            switch (e) {
                '"' => try out.append(self.allocator, '"'),
                '\\' => try out.append(self.allocator, '\\'),
                '/' => try out.append(self.allocator, '/'),
                'b' => try out.append(self.allocator, 0x08),
                'f' => try out.append(self.allocator, 0x0C),
                'n' => try out.append(self.allocator, '\n'),
                'r' => try out.append(self.allocator, '\r'),
                't' => try out.append(self.allocator, '\t'),
                'u' => {
                    var cp: u21 = hexQuad(raw[j + 2 ..][0..4]);
                    j += 6;
                    if (cp >= 0xD800 and cp <= 0xDBFF) {
                        const lo: u21 = hexQuad(raw[j + 2 ..][0..4]);
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        j += 6;
                    }
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
                    try out.appendSlice(self.allocator, buf[0..n]);
                    continue;
                },
                else => unreachable,
            }
            j += 2;
        }
    }

    fn hexQuad(q: *const [4]u8) u21 {
        var v: u21 = 0;
        for (q) |c| {
            const d: u21 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => unreachable,
            };
            v = (v << 4) | d;
        }
        return v;
    }

    // ---- build (girdi `validate`ten geçmiştir) ----

    fn node(self: *FastJson, rt: ?*anyopaque, kind: i64, b: bool, n: f64, str: ?[*:0]const u8, arr: ?*anyopaque, keys: ?*anyopaque, vals: ?*anyopaque) ?*anyopaque {
        if (self.cid) |c| return makeJsonValueDirect(rt, c, kind, b, n, str, arr, keys, vals);
        const r = callMakeJsonValue(rt, kind, if (b) 1 else 0, n, str, arr, keys, vals) orelse return null;
        const c = @as(*align(1) const i64, @ptrCast(r)).*;
        self.cid = c;
        JsonValueClassIdSlot.value = c;
        return r;
    }

    fn leaf(self: *FastJson, rt: ?*anyopaque, shared: SharedEmpties, kind: i64, b: bool, n: f64, str: ?[*:0]const u8) ?*anyopaque {
        return self.node(rt, kind, b, n, str, sharedEmptyList(shared), sharedEmptyList(shared), sharedEmptyList(shared));
    }

    /// Çözülmüş dize değeri → Nox `str`.
    fn buildStr(self: *FastJson, rt: ?*anyopaque, a: usize, b: usize, esc: bool) ?[*:0]u8 {
        if (!esc) return dupeToNoxStr(rt, self.s[a..b]);
        self.scratch.clearRetainingCapacity();
        self.unescapeInto(&self.scratch, self.s[a..b]) catch return null;
        return dupeToNoxStr(rt, self.scratch.items);
    }

    fn buildValue(self: *FastJson, rt: ?*anyopaque, shared: SharedEmpties) ?*anyopaque {
        self.ws();
        switch (self.s[self.i]) {
            '{' => {
                self.i += 1;
                var key_items: std.ArrayListUnmanaged(?*anyopaque) = .empty;
                var val_items: std.ArrayListUnmanaged(?*anyopaque) = .empty;
                self.ws();
                if (self.s[self.i] == '}') {
                    self.i += 1;
                } else {
                    while (true) {
                        self.ws();
                        var a: usize = 0;
                        var b: usize = 0;
                        var e = false;
                        _ = self.validString(&a, &b, &e); // geçerli: yalnızca aralığı bul
                        key_items.append(self.allocator, self.buildStr(rt, a, b, e)) catch return null;
                        self.ws();
                        self.i += 1; // ':'
                        const child = self.buildValue(rt, shared);
                        val_items.append(self.allocator, child) catch return null;
                        self.ws();
                        const c = self.s[self.i];
                        self.i += 1;
                        if (c == '}') break;
                    }
                }
                const keys_list = buildPtrList(rt, key_items.items) orelse return null;
                const vals_list = buildPtrList(rt, val_items.items) orelse return null;
                return self.node(rt, 5, false, 0.0, sharedEmptyStr(shared), sharedEmptyList(shared), keys_list, vals_list);
            },
            '[' => {
                self.i += 1;
                var items: std.ArrayListUnmanaged(?*anyopaque) = .empty;
                self.ws();
                if (self.s[self.i] == ']') {
                    self.i += 1;
                } else {
                    while (true) {
                        const child = self.buildValue(rt, shared);
                        items.append(self.allocator, child) catch return null;
                        self.ws();
                        const c = self.s[self.i];
                        self.i += 1;
                        if (c == ']') break;
                    }
                }
                const arr_list = buildPtrList(rt, items.items) orelse return null;
                return self.node(rt, 4, false, 0.0, sharedEmptyStr(shared), arr_list, sharedEmptyList(shared), sharedEmptyList(shared));
            },
            '"' => {
                var a: usize = 0;
                var b: usize = 0;
                var e = false;
                _ = self.validString(&a, &b, &e);
                const dup = self.buildStr(rt, a, b, e) orelse return null;
                return self.leaf(rt, shared, 3, false, 0.0, dup);
            },
            't' => {
                self.i += 4;
                return self.leaf(rt, shared, 1, true, 0.0, sharedEmptyStr(shared));
            },
            'f' => {
                self.i += 5;
                return self.leaf(rt, shared, 1, false, 0.0, sharedEmptyStr(shared));
            },
            'n' => {
                self.i += 4;
                return self.leaf(rt, shared, 0, false, 0.0, sharedEmptyStr(shared));
            },
            else => {
                const start = self.i;
                _ = self.validNumber();
                return self.numberLeaf(rt, shared, self.s[start..self.i]);
            },
        }
    }

    /// `std.json.Value.parseFromNumberSlice` + `buildNodeFast`in sayı dallarıyla BİREBİR aynı sınıflandırma.
    fn numberLeaf(self: *FastJson, rt: ?*anyopaque, shared: SharedEmpties, tok: []const u8) ?*anyopaque {
        const integer_like = !std.mem.eql(u8, tok, "-0") and std.mem.indexOfAny(u8, tok, ".eE") == null;
        if (!integer_like) {
            const f = std.fmt.parseFloat(f64, tok) catch 0.0;
            if (std.math.isFinite(f)) return self.leaf(rt, shared, 2, false, f, sharedEmptyStr(shared));
            return self.leaf(rt, shared, 2, false, f, if (isPlainBigInteger(tok)) exactNumberText(rt, shared, tok) else sharedEmptyStr(shared));
        }
        if (std.fmt.parseInt(i64, tok, 10)) |i| {
            if (i >= (1 << 53) or i <= -(1 << 53)) {
                var buf: [24]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "{d}", .{i}) catch return self.leaf(rt, shared, 2, false, @floatFromInt(i), sharedEmptyStr(shared));
                return self.leaf(rt, shared, 2, false, @floatFromInt(i), exactNumberText(rt, shared, text));
            }
            return self.leaf(rt, shared, 2, false, @floatFromInt(i), sharedEmptyStr(shared));
        } else |_| {
            return self.leaf(rt, shared, 2, false, std.fmt.parseFloat(f64, tok) catch 0.0, if (isPlainBigInteger(tok)) exactNumberText(rt, shared, tok) else sharedEmptyStr(shared));
        }
    }
};

/// Referans/farksal test girişi: `slice` geçerli JSON mu (derinlik <= MAX_JSON_NESTING_DEPTH dahil)?
fn fastValidate(allocator: std.mem.Allocator, slice: []const u8) bool {
    var p = FastJson{ .s = slice, .allocator = allocator };
    defer p.keys.deinit(allocator);
    defer p.scratch.deinit(allocator);
    defer p.scratch2.deinit(allocator);
    p.ws();
    if (!p.validValue(0)) return false;
    p.ws();
    return p.i == slice.len;
}

// v2.1.61: `nox.json.dump` Zig'de. Düğüm ağacı (JsonValue: kind@8, b@16, n@24, s@32, arr@40, keys@48, vals@56; liste: len@0, cap@8, elemanlar@LIST_HEADER_SIZE) tek tampona yazılır.
// Anlam `json.nox`un saf-Nox `dump`ıyla BİREBİR: sayı = `s` doluysa (tam tamsayı metni) o, değilse |n| < 1e15 ve tamsayı ise tamsayı, aksi halde `str(float)` (Python repr).
fn rdI64(p: [*]const u8, off: usize) i64 {
    return @as(*align(1) const i64, @ptrCast(p + off)).*;
}

fn rdF64(p: [*]const u8, off: usize) f64 {
    return @as(*align(1) const f64, @ptrCast(p + off)).*;
}

fn rdPtr(p: [*]const u8, off: usize) ?[*]const u8 {
    const v = @as(*align(1) const u64, @ptrCast(p + off)).*;
    if (v == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(v)));
}

/// v2.1.88: JSON yazıcı yardımcıları — küçük dilimlerde libc `memmove` çağrısı yerine satır içi kopya (çıktı düğüm başına onlarca küçük ekleme içerir),
/// kaçış gerektirmeyen dizeler tek taramayla doğrudan tampona.
inline fn copySmall(dst: [*]u8, src: [*]const u8, n: usize) void {
    if (n >= 16) {
        @memcpy(dst[0..n], src[0..n]);
    } else if (n >= 8) {
        const a = @as(*align(1) const u64, @ptrCast(src)).*;
        const b = @as(*align(1) const u64, @ptrCast(src + n - 8)).*;
        @as(*align(1) u64, @ptrCast(dst)).* = a;
        @as(*align(1) u64, @ptrCast(dst + n - 8)).* = b;
    } else if (n >= 4) {
        const a = @as(*align(1) const u32, @ptrCast(src)).*;
        const b = @as(*align(1) const u32, @ptrCast(src + n - 4)).*;
        @as(*align(1) u32, @ptrCast(dst)).* = a;
        @as(*align(1) u32, @ptrCast(dst + n - 4)).* = b;
    } else if (n > 0) {
        dst[0] = src[0];
        dst[n / 2] = src[n / 2];
        dst[n - 1] = src[n - 1];
    }
}

fn putSlice(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), sl: []const u8) std.mem.Allocator.Error!void {
    try out.ensureUnusedCapacity(a, sl.len);
    copySmall(out.items.ptr + out.items.len, sl.ptr, sl.len);
    out.items.len += sl.len;
}

fn putByte(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), b: u8) std.mem.Allocator.Error!void {
    try out.ensureUnusedCapacity(a, 1);
    out.items.ptr[out.items.len] = b;
    out.items.len += 1;
}

/// `"..."` biçiminde kaçışlı dizeyi doğrudan `out`a yazar (`escapeJsonString` ile aynı çıktı).
fn putEscaped(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), bytes: []const u8) std.mem.Allocator.Error!void {
    var clean = true;
    for (bytes) |c| {
        if (c < 0x20 or c == '"' or c == '\\') {
            clean = false;
            break;
        }
    }
    if (clean) {
        try out.ensureUnusedCapacity(a, bytes.len + 2);
        const d = out.items.ptr + out.items.len;
        d[0] = '"';
        copySmall(d + 1, bytes.ptr, bytes.len);
        d[bytes.len + 1] = '"';
        out.items.len += bytes.len + 2;
        return;
    }
    var sfa = std.heap.stackFallback(1024, a);
    const ea = sfa.get();
    const esc = try escapeJsonString(ea, bytes);
    defer ea.free(esc);
    try putSlice(a, out, esc);
}

fn putInt(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), v: i64) std.mem.Allocator.Error!void {
    var tmp: [20]u8 = undefined;
    var i: usize = tmp.len;
    var u: u64 = if (v < 0) @as(u64, @intCast(-(v + 1))) + 1 else @as(u64, @intCast(v));
    if (u == 0) {
        i -= 1;
        tmp[i] = '0';
    }
    while (u != 0) {
        i -= 1;
        tmp[i] = @intCast('0' + u % 10);
        u /= 10;
    }
    if (v < 0) {
        i -= 1;
        tmp[i] = '-';
    }
    try putSlice(a, out, tmp[i..]);
}

fn dumpNumberInto(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), n: f64) std.mem.Allocator.Error!void {
    if (n < 1000000000000000.0 and n > -1000000000000000.0) {
        const i: i64 = @intFromFloat(n);
        if (@as(f64, @floatFromInt(i)) == n) {
            return putInt(a, out, i);
        }
    }
    var fb: [64]u8 = undefined;
    return putSlice(a, out, str_mod.formatFloatRepr(&fb, n));
}

fn dumpNodeInto(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), node: [*]const u8) std.mem.Allocator.Error!void {
    switch (rdI64(node, FIELD_SLOT_SIZE * 1)) {
        0 => try putSlice(a, out, "null"),
        1 => try putSlice(a, out, if (rdI64(node, FIELD_SLOT_SIZE * 2) != 0) "true" else "false"),
        2 => {
            if (rdPtr(node, FIELD_SLOT_SIZE * 4)) |sp| {
                const sl = str_mod.nox_str_slice(@ptrCast(sp));
                if (sl.len > 0) return putSlice(a, out, sl);
            }
            try dumpNumberInto(a, out, rdF64(node, FIELD_SLOT_SIZE * 3));
        },
        3 => {
            const sl: []const u8 = if (rdPtr(node, FIELD_SLOT_SIZE * 4)) |sp| str_mod.nox_str_slice(@ptrCast(sp)) else "";
            try putEscaped(a, out, sl);
        },
        4 => {
            const list = rdPtr(node, FIELD_SLOT_SIZE * 5) orelse return putSlice(a, out, "[]");
            const n: usize = @intCast(rdI64(list, 0));
            try putByte(a, out, '[');
            for (0..n) |i| {
                if (i > 0) try putByte(a, out, ',');
                const child = rdPtr(list, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i) orelse {
                    try putSlice(a, out, "null");
                    continue;
                };
                try dumpNodeInto(a, out, child);
            }
            try putByte(a, out, ']');
        },
        else => {
            const keys = rdPtr(node, FIELD_SLOT_SIZE * 6) orelse return putSlice(a, out, "{}");
            const vals = rdPtr(node, FIELD_SLOT_SIZE * 7) orelse return putSlice(a, out, "{}");
            const n: usize = @intCast(rdI64(keys, 0));
            try putByte(a, out, '{');
            for (0..n) |i| {
                if (i > 0) try putByte(a, out, ',');
                const kp = rdPtr(keys, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i);
                const ksl: []const u8 = if (kp) |k| str_mod.nox_str_slice(@ptrCast(k)) else "";
                try putEscaped(a, out, ksl);
                try putByte(a, out, ':');
                const child = rdPtr(vals, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i) orelse {
                    try putSlice(a, out, "null");
                    continue;
                };
                try dumpNodeInto(a, out, child);
            }
            try putByte(a, out, '}');
        },
    }
}

export fn nox_json_dump_raw(rt: ?*anyopaque, v: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const node: [*]const u8 = @ptrCast(v orelse return dupeToNoxStr(rt, "null"));
    const a = scratch_util.scratchAllocator();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    dumpNodeInto(a, &out, node) catch return null;
    return dupeToNoxStr(rt, out.items);
}

export fn nox_json_decode_raw(rt: ?*anyopaque, s: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    // NOT: `s`in null olduğu dal İçin `str_mod.nox_str_slice`e DÜŞMEYİZ —
    // o yol yalnızca GERÇEK bir Nox `str` (görünmez başlıklı) BEKLER, boş
    // Zig dize literal'i "" BUNU SAĞLAMAZ (başlıksız bellek okunması OLURDU).
    const slice = if (s) |sp| str_mod.nox_str_slice(sp) else "";

    // v2.1.61: doğrudan-düğüm ayrıştırıcı (ilk çağrı dahil: sınıf kimliği ilk düğüm Nox kurucusundan okunur). `std.json` tabanlı aşağıdaki yol REFERANS olarak (farksal testler) kalır.
    {
        if (DecodeArenaSlot.value == null) {
            DecodeArenaSlot.value = std.heap.ArenaAllocator.init(scratch_util.scratchAllocator());
        }
        const farena = &DecodeArenaSlot.value.?;
        defer _ = farena.reset(.{ .retain_with_limit = DECODE_ARENA_RETAIN_LIMIT });
        var fp = FastJson{ .s = slice, .allocator = farena.allocator(), .cid = JsonValueClassIdSlot.value };
        fp.ws();
        const ok = fp.validValue(0) and blk: {
            fp.ws();
            break :blk fp.i == slice.len;
        };
        if (!ok) {
            jsonLastOpOkPtr().* = false;
            return makeLeafUnshared(rt, 0, false, 0.0, "");
        }
        const fshared = initSharedEmpties(rt) orelse {
            jsonLastOpOkPtr().* = true;
            return makeLeafUnshared(rt, 0, false, 0.0, "");
        };
        defer releaseSharedEmpties(rt, fshared);
        fp.i = 0;
        const froot = fp.buildValue(rt, fshared);
        jsonLastOpOkPtr().* = true;
        return froot orelse makeLeaf(rt, fshared, 0, false, 0.0, sharedEmptyStr(fshared));
    }

    // GG.23: `std.json.parseFromSlice`ı HİÇ ÇAĞIRMADAN ÖNCE — bkz.
    // `jsonNestingDepthExceeds`in belge notu. Sözdizimi-hatasıyla AYNI
    // hata-yüzeyi (MEVCUT `stdlib/nox/json.nox`nin `decode`si ZATEN
    // `nox_json_last_op_ok() == 0` İSE `JsonError` fırlatıyor) — YENİ bir
    // istisna türü/mekanizma GEREKMEZ.
    if (jsonNestingDepthExceeds(slice, MAX_JSON_NESTING_DEPTH)) {
        jsonLastOpOkPtr().* = false;
        return makeLeafUnshared(rt, 0, false, 0.0, "");
    }

    // Dil stabilizasyonu fazı §M.6: ÖNCEDEN `std.json.parseFromSlice` VE
    // `buildNode`nin dizi/obje dalları `std.heap.page_allocator`a DOĞRUDAN
    // (HER JSON düğümü/liste KENDİ AYRI tahsisini alarak) çok sayıda küçük
    // tahsis yapıyordu. ARTIK TEK bir `ArenaAllocator` (page_allocator'ı
    // SARAN) kullanılıyor — TÜM ayrıştırma + geçici Zig-taraflı dilimler
    // BU arena ÜZERİNDEN yapılır (`rt`/ARC'a GEÇEN `dupeToNoxStr`/
    // `buildPtrList` çıktıları ETKİLENMEZ, onlar ZATEN AYRI/`nox_rc_alloc`
    // tabanlı). `std.json.parseFromSlice`nin KENDİ `Parsed(T).deinit()`ı
    // (kendi İÇ arenasını serbest bırakan) ayrıca ÇAĞRILMAZ — dış arena
    // zaten HER ŞEYİ (iç içe olsa BİLE) tek seferde temizler.
    //
    // Performans fazı (bkz. yukarıdaki `g_decode_arena`nin belge notu):
    // arena artık HER ÇAĞRIDA taze `init`/`deinit` (mmap/munmap) YERİNE
    // thread-yerel olarak BİR KEZ oluşturulup `reset` İLE YENİDEN
    // kullanılır — dönen `JsonValue` ağacının TAMAMI (`nox_rc_alloc`/
    // `dupeToNoxStr`/`buildPtrList` ÜZERİNDEN, ARENADAN TAMAMEN AYRI)
    // kalıcı ARC belleğinde OLDUĞUNDAN, fonksiyon dönmeden HEMEN ÖNCE
    // arenayı `reset` etmek (`defer`) GÜVENLİDİR — `items`/`key_items`/
    // `val_items` gibi arena-tahsisli geçici diziler `buildPtrList`nin
    // ONLARI GERÇEK bir `list[T]`ye KOPYALAMASINDAN SONRA BİR DAHA
    // kullanılmaz.
    if (DecodeArenaSlot.value == null) {
        DecodeArenaSlot.value = std.heap.ArenaAllocator.init(scratch_util.scratchAllocator());
    }
    const arena = &DecodeArenaSlot.value.?;
    defer _ = arena.reset(.{ .retain_with_limit = DECODE_ARENA_RETAIN_LIMIT });
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

    if (JsonValueClassIdSlot.value) |cid| {
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
        JsonValueClassIdSlot.value = @as(*align(1) const i64, @ptrCast(r)).*;
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

// GG.23 (bkz. plan dosyası "fiber-stack sertleştirmesi", Madde 2):
// `jsonNestingDepthExceeds`nin SAF/yan-etkisiz saf-fonksiyon davranışı —
// string literalleri/escape'leri İçİndeki `[`/`{` karakterlerini DOĞRU
// ŞEKİLDE ATLADIĞINI da kanıtlar (aksi halde bir string DEĞERİ İçİndeki
// alakasız parantez/küme ayracı YANLIŞLIKLA derinliğe SAYILIRDI).
test "GG.23: jsonNestingDepthExceeds derinliği dogru sayar, string icerigini atlar" {
    try std.testing.expect(!jsonNestingDepthExceeds("{\"a\": 1}", 32));
    try std.testing.expect(!jsonNestingDepthExceeds("[1, 2, [3, 4]]", 32));
    // String DEĞERİ İçİndeki `[`/`{`/kaçış tırnağı derinliğe SAYILMAMALI.
    try std.testing.expect(!jsonNestingDepthExceeds("{\"a\": \"[[[[[\\\"]]]]]\"}", 2));
    try std.testing.expect(!jsonNestingDepthExceeds("[]", 1));
    try std.testing.expect(jsonNestingDepthExceeds("[[]]", 1));
    try std.testing.expect(!jsonNestingDepthExceeds("[[]]", 2));
}

// GG.23: `nox_json_decode_raw`ın uçtan-uca davranışı — sınırın ALTINDA
// BAŞARIYLA decode EDER, sınırı AŞAN girdi ÇÖKMEDEN (`nox_json_last_op_ok
// () == 0`) TEMİZ reddedilir.
test "GG.23: nox_json_decode_raw derinlik sinirini asan girdiyi cokmeden reddeder" {
    const asap = @import("../alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const allocator = std.testing.allocator;

    // `MAX_JSON_NESTING_DEPTH` seviye `[` + kapanışları + İÇ değer.
    const under_src = try buildNestedArrayJson(allocator, MAX_JSON_NESTING_DEPTH);
    defer allocator.free(under_src);
    const over_src = try buildNestedArrayJson(allocator, MAX_JSON_NESTING_DEPTH + 1);
    defer allocator.free(over_src);

    const under_str = str_mod.nox_str_from_bytes(rt, under_src) orelse return error.AllocFailed;
    defer str_mod.nox_str_release(rt, under_str);
    const over_str = str_mod.nox_str_from_bytes(rt, over_src) orelse return error.AllocFailed;
    defer str_mod.nox_str_release(rt, over_str);

    // `rt=null` İLE çağrılır — `g_last_op_ok threadlocal` testinin AYNI
    // deseni (bkz. yukarısı): `nox_json_decode_raw`nin İZOLE test
    // bağlamları İçİn desteklediği, dönen `JsonValue`nin GERÇEK bir ARC
    // ağacı OLMADIĞI (dolayısıyla manuel serbest bırakma GEREKMEYEN) yol.
    _ = nox_json_decode_raw(null, under_str);
    try std.testing.expect(nox_json_last_op_ok() != 0);

    _ = nox_json_decode_raw(null, over_str);
    try std.testing.expect(nox_json_last_op_ok() == 0);
}

/// `depth` seviye iç-içe `[1]` üretir (ör. depth=2 -> "[[1]]").
fn buildNestedArrayJson(allocator: std.mem.Allocator, depth: usize) ![:0]u8 {
    const buf = try allocator.alloc(u8, depth * 2 + 1 + 1);
    var i: usize = 0;
    while (i < depth) : (i += 1) buf[i] = '[';
    buf[depth] = '1';
    i = 0;
    while (i < depth) : (i += 1) buf[depth + 1 + i] = ']';
    buf[buf.len - 1] = 0;
    return buf[0 .. buf.len - 1 :0];
}

test "escapeJsonString: kısa kaçışlar, C0 -> \\u00XX, UTF-8 ve DEL olduğu gibi" {
    const a = std.testing.allocator;
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "", .out = "\"\"" },
        .{ .in = "hello", .out = "\"hello\"" },
        .{ .in = "a\"b\\c", .out = "\"a\\\"b\\\\c\"" },
        .{ .in = "l1\nl2\tx\r", .out = "\"l1\\nl2\\tx\\r\"" },
        .{ .in = "\x08\x0c", .out = "\"\\b\\f\"" },
        .{ .in = "\x00\x01\x1f", .out = "\"\\u0000\\u0001\\u001f\"" },
        .{ .in = "caf\xc3\xa9 \x7f", .out = "\"caf\xc3\xa9 \x7f\"" },
    };
    for (cases) |c| {
        const got = try escapeJsonString(a, c.in);
        defer a.free(got);
        try std.testing.expectEqualStrings(c.out, got);
    }
}

test "escapeJsonString: çıktı std.json ile geri okunabilir (round-trip)" {
    const a = std.testing.allocator;
    var raw: [256]u8 = undefined;
    for (&raw, 0..) |*b, i| b.* = @intCast(i % 128);
    const escaped = try escapeJsonString(a, &raw);
    defer a.free(escaped);
    const parsed = try std.json.parseFromSlice([]const u8, a, escaped, .{});
    defer parsed.deinit();
    try std.testing.expectEqualSlices(u8, &raw, parsed.value);
}

// v2.1.61: farksal test — doğrudan-düğüm ayrıştırıcının doğrulayıcısı (`fastValidate`), `std.json` tabanlı referansla (derinlik ön geçişi + `parseFromSlice`) AYNI kabul/ret kararını verir.
// Tohum belgeler yapısal olarak değiştirilir (karakter ekle/sil/değiştir, parça kopyala) — hem geçerli hem geçersiz binlerce belge üretir.
test "v2.1.61: fastValidate, std.json tabanlı referansla 150k mutasyonda aynı kabul/ret kararını verir" {
    const gpa = std.testing.allocator;
    const seeds = [_][]const u8{
        "{\"a\":1,\"b\":[true,null,{\"c\":\"d\\n\\u00e9\\ud83d\\ude00\"}],\"e\":-1.5e+10}",
        "[1,2.5,-0,0,1e3,\"x\",{},[],[[1]]]",
        "{\"k\":{\"k\":{\"k\":[]}}}",
        " \t\r\n[ 1 , 2 ]\n",
        "\"h\xc3\xa9llo \xe4\xb8\x96\xe7\x95\x8c \xf0\x9f\x98\x80\"",
        "{\"é\":1,\"\\u0061\":2,\"b\":3}",
        "12345678901234567890",
        "{\"a\":1,\"a\":2}",
    };
    const alphabet = "{}[]\",:\\/ \t\n\r0123456789+-.eEabfnrtul\xc3\xa9\x80\xff";
    var prng = std.Random.DefaultPrng.init(0xFA57);
    const rand = prng.random();
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    var accepted: usize = 0;
    var rejected: usize = 0;
    var round: usize = 0;
    while (round < 150_000) : (round += 1) {
        buf.clearRetainingCapacity();
        try buf.appendSlice(gpa, seeds[rand.uintLessThan(usize, seeds.len)]);
        const edits = rand.uintLessThan(usize, 4);
        var e: usize = 0;
        while (e < edits) : (e += 1) {
            if (buf.items.len == 0) break;
            const pos = rand.uintLessThan(usize, buf.items.len);
            switch (rand.uintLessThan(u8, 4)) {
                0 => buf.items[pos] = alphabet[rand.uintLessThan(usize, alphabet.len)],
                1 => _ = buf.orderedRemove(pos),
                2 => try buf.insert(gpa, pos, alphabet[rand.uintLessThan(usize, alphabet.len)]),
                else => {
                    const len = @min(rand.uintLessThan(usize, 6), buf.items.len - pos);
                    var tmp: [6]u8 = undefined;
                    @memcpy(tmp[0..len], buf.items[pos..][0..len]);
                    try buf.insertSlice(gpa, pos, tmp[0..len]);
                },
            }
        }
        const doc = buf.items;
        // Referans: derinlik ön geçişi + std.json (eski `nox_json_decode_raw` yolu).
        const ref_ok = blk: {
            if (jsonNestingDepthExceeds(doc, MAX_JSON_NESTING_DEPTH)) break :blk false;
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            _ = std.json.parseFromSlice(std.json.Value, arena.allocator(), doc, .{}) catch break :blk false;
            break :blk true;
        };
        var arena2 = std.heap.ArenaAllocator.init(gpa);
        defer arena2.deinit();
        const got = fastValidate(arena2.allocator(), doc);
        if (got != ref_ok) {
            std.debug.print("AYRIŞTI (ref={}, fast={}): {any}\n  metin: {s}\n", .{ ref_ok, got, doc, doc });
            return error.ValidatorDisagrees;
        }
        if (got) accepted += 1 else rejected += 1;
    }
    // Test anlamlı olsun: hem kabul hem ret yeterince örneklenmiş olmalı.
    try std.testing.expect(accepted > 5_000);
    try std.testing.expect(rejected > 5_000);
}

test "v2.1.61: fastValidate sınır durumları (derinlik 32/33, yinelenen anahtar, vekil çiftler, -0)" {
    const a = std.testing.allocator;
    var deep32: [66]u8 = undefined;
    @memset(deep32[0..32], '[');
    deep32[32] = '1';
    @memset(deep32[33..65], ']');
    // 32 açılış + 32 kapanış
    var d32: [65]u8 = undefined;
    @memset(d32[0..32], '[');
    d32[32] = '1';
    @memset(d32[33..65], ']');
    try std.testing.expect(fastValidate(a, &d32));
    var d33: [67]u8 = undefined;
    @memset(d33[0..33], '[');
    d33[33] = '1';
    @memset(d33[34..67], ']');
    try std.testing.expect(!fastValidate(a, &d33));
    try std.testing.expect(!fastValidate(a, "{\"a\":1,\"a\":2}"));
    try std.testing.expect(!fastValidate(a, "{\"a\":1,\"\\u0061\":2}"));
    try std.testing.expect(fastValidate(a, "\"\\ud83d\\ude00\""));
    try std.testing.expect(!fastValidate(a, "\"\\ud83d\""));
    try std.testing.expect(!fastValidate(a, "\"\\ude00\""));
    try std.testing.expect(fastValidate(a, "-0"));
    try std.testing.expect(!fastValidate(a, "01"));
    try std.testing.expect(!fastValidate(a, ""));
    // 20 anahtarlı nesne (karma yolu) ve sonda yinelenen anahtar
    try std.testing.expect(fastValidate(a, "{\"a\":1,\"b\":1,\"c\":1,\"d\":1,\"e\":1,\"f\":1,\"g\":1,\"h\":1,\"i\":1,\"j\":1,\"k\":1,\"l\":1}"));
    try std.testing.expect(!fastValidate(a, "{\"a\":1,\"b\":1,\"c\":1,\"d\":1,\"e\":1,\"f\":1,\"g\":1,\"h\":1,\"i\":1,\"j\":1,\"k\":1,\"a\":1}"));
}
