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
//! İNŞA ETMESİ YERİNE):** her sınıfın `class_id`si (`codegen.zig`nin
//! `next_class_id` sayacı) DERLEME SIRASINA bağlıdır — Zig'den GÜVENLE
//! TAHMİN EDİLEMEZ. Gerçek `make_json_value` çağrısı, doğru `class_id`yi
//! VE doğru ARC muhasebesini (zaten TEST EDİLMİŞ `genConstructFromValues`/
//! `__init__` yolu üzerinden) OTOMATİK olarak doğru yapar.
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
const arc = @import("../alloc/arc.zig");
const http_client = @import("http_client.zig");

const dupeToNoxStr = http_client.dupeToNoxStr;

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

fn resolveMakeJsonValue() ?*const MakeJsonValueFn {
    if (g_make_json_value_resolved) return g_make_json_value_fn;
    g_make_json_value_resolved = true;
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
threadlocal var g_last_op_ok: bool = true;

export fn nox_json_last_op_ok() callconv(.c) i32 {
    return if (g_last_op_ok) 1 else 0;
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
    _ = arc.nox_rc_predecrement(@ptrCast(@constCast(s)));
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
    const raw = arc.nox_rc_alloc(rt, 16 + 8 * items.len) orelse return null;
    const bytes: [*]u8 = @ptrCast(raw);
    @as(*align(1) i64, @ptrCast(bytes)).* = @intCast(items.len);
    @as(*align(1) i64, @ptrCast(bytes + 8)).* = @intCast(items.len);
    for (items, 0..) |it, i| {
        const slot = bytes + 16 + 8 * i;
        @as(*align(1) i64, @ptrCast(slot)).* = @bitCast(@as(isize, @intCast(@intFromPtr(it))));
    }
    return @ptrCast(bytes);
}

fn emptyList(rt: ?*anyopaque) ?*anyopaque {
    return buildPtrList(rt, &.{});
}

fn makeLeaf(rt: ?*anyopaque, kind: i64, b: bool, n: f64, s: []const u8) ?*anyopaque {
    const dup = dupeToNoxStr(rt, s) orelse return null;
    const empty_arr = emptyList(rt) orelse return null;
    const empty_keys = emptyList(rt) orelse return null;
    const empty_vals = emptyList(rt) orelse return null;
    return callMakeJsonValue(rt, kind, if (b) 1 else 0, n, dup, empty_arr, empty_keys, empty_vals);
}

fn buildNode(rt: ?*anyopaque, allocator: std.mem.Allocator, v: std.json.Value) !?*anyopaque {
    return switch (v) {
        .null => makeLeaf(rt, 0, false, 0.0, ""),
        .bool => |b| makeLeaf(rt, 1, b, 0.0, ""),
        .integer => |i| makeLeaf(rt, 2, false, @floatFromInt(i), ""),
        .float => |f| makeLeaf(rt, 2, false, f, ""),
        .number_string => |s| makeLeaf(rt, 2, false, std.fmt.parseFloat(f64, s) catch 0.0, ""),
        .string => |s| makeLeaf(rt, 3, false, 0.0, s),
        .array => |arr_val| blk: {
            const items = try allocator.alloc(?*anyopaque, arr_val.items.len);
            for (arr_val.items, 0..) |child, i| items[i] = try buildNode(rt, allocator, child);
            const arr_list = buildPtrList(rt, items) orelse break :blk null;
            const empty_keys = emptyList(rt) orelse break :blk null;
            const empty_vals = emptyList(rt) orelse break :blk null;
            const dup = dupeToNoxStr(rt, "") orelse break :blk null;
            break :blk callMakeJsonValue(rt, 4, 0, 0.0, dup, arr_list, empty_keys, empty_vals);
        },
        .object => |obj_val| blk: {
            const n = obj_val.count();
            const key_items = try allocator.alloc(?*anyopaque, n);
            const val_items = try allocator.alloc(?*anyopaque, n);
            for (obj_val.keys(), 0..) |k, i| key_items[i] = dupeToNoxStr(rt, k);
            for (obj_val.values(), 0..) |val, i| val_items[i] = try buildNode(rt, allocator, val);
            const keys_list = buildPtrList(rt, key_items) orelse break :blk null;
            const vals_list = buildPtrList(rt, val_items) orelse break :blk null;
            const empty_arr = emptyList(rt) orelse break :blk null;
            const dup = dupeToNoxStr(rt, "") orelse break :blk null;
            break :blk callMakeJsonValue(rt, 5, 0, 0.0, dup, empty_arr, keys_list, vals_list);
        },
    };
}

export fn nox_json_decode_raw(rt: ?*anyopaque, s: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    const slice = std.mem.span(s orelse "");

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
        g_last_op_ok = false;
        return makeLeaf(rt, 0, false, 0.0, "");
    };

    const root = buildNode(rt, allocator, parsed.value) catch {
        g_last_op_ok = false;
        return makeLeaf(rt, 0, false, 0.0, "");
    };
    g_last_op_ok = true;
    return root orelse makeLeaf(rt, 0, false, 0.0, "");
}

// Faz BB.1: `g_last_op_ok`nin `threadlocal` OLMASININ, İKİ GERÇEK OS iş
// parçacığının AYNI ANDA `nox.json.decode` ÇAĞIRDIĞINDA (biri BOZUK, diğeri
// GEÇERLİ JSON İLE) birbirinin bayrağını EZMEDİĞİNİ kanıtlar.
test "g_last_op_ok threadlocal: iki gerçek OS iş parçacığı bağımsız bayrak görür" {
    const Worker = struct {
        fn malformed(iterations: usize, all_false: *bool) void {
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                _ = nox_json_decode_raw(null, "{ bozuk");
                if (nox_json_last_op_ok() != 0) all_false.* = false;
            }
        }
        fn valid(iterations: usize, all_true: *bool) void {
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                _ = nox_json_decode_raw(null, "{\"a\": 1}");
                if (nox_json_last_op_ok() == 0) all_true.* = false;
            }
        }
    };

    var all_false = true;
    var all_true = true;
    const thread_a = try std.Thread.spawn(.{}, Worker.malformed, .{ 2000, &all_false });
    const thread_b = try std.Thread.spawn(.{}, Worker.valid, .{ 2000, &all_true });
    thread_a.join();
    thread_b.join();

    try std.testing.expect(all_false);
    try std.testing.expect(all_true);
}
