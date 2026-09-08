//! Nox yabancı fonksiyon köprüsü (Faz 14) — Faz 12/13'ün bağımsız test
//! araçları olarak kalan HPy/WASM köprülerini GERÇEKTEN derlenmiş Nox
//! programlarına bağlar. İki yerleşik fonksiyona (bkz. compiler/codegen_qbe/
//! codegen.zig, `genCall`) karşılık gelir: `hpy_call(...)`/`wasm_call(...)`.
//!
//! **Kapsam (v0.1, bilinçli olarak dar):** her çağrı, ilgili modülü
//! BAŞTAN dlopen/ayrıştırıp (önbellek YOK) tek bir `i64 -> i64` (HPy
//! tarafında `HPyFunc_O` imzalı bir metod, WASM tarafında `i32` parametre/
//! dönüşlü bir export) çağrısı yapar ve kapatır/serbest bırakır. Bu, İlke
//! #6'ya (allocator her zaman `rt` üzerinden açık) uyar: `rt`nin kendi
//! sızıntı-tespit eden `DebugAllocator`'ı (bkz. alloc/asap.zig) kullanılır,
//! hiçbir gizli/global durum tutulmaz. Bir hata oluşursa (dosya bulunamadı,
//! sembol/metod/export eksik, ...) `0` döner — Nox'un genel istisna
//! mekanizmasıyla (bkz. errors/handle.zig) entegre bir hata sinyali HENÜZ
//! yok (bkz. nox-teknik-spesifikasyon.md §3.14, bilinen sınırlamalar).
//!
//! **Faz 16 — kalıcı tutamaç** (bkz. plan dosyası "hpy_call'e kalıcı
//! modül+context"): `hpy_call`/`hpy_call_str`nin "her çağrıda baştan aç/
//! kapat" modeli, TEKRARLANAN çağrılar İçİn (a) her seferinde YENİDEN
//! dlopen/`HPyInit_*` çalıştırma maliyetini VE (b) modül-seviyeli C
//! durumunun (bkz. `tests/compat/hpy_ext/noxtest.c`nin `call_count`
//! sayacı) HER çağrıda kaybolmasını (paylaşımlı kütüphane YENİDEN
//! eşlendiğinde `static` C global'leri SIFIRLANIR) getiriyordu. `hpy_open`
//! modülü VE `HPyContext`i BİR KEZ yaratıp `PersistentHpyHandle` İçİnde
//! saklar; `hpy_call_on`/`hpy_call_str_on` bu İKİSİNİ YENİDEN KULLANIR
//! (SIFIR yeniden-yükleme); `hpy_close` İKİSİNİ de yok eder. Tutamaç,
//! Nox'un `extern def`in ZATEN kullandığı opak `ptr` tipiyle temsil edilir
//! (bkz. checker.zig'deki eşdeğer not) — `hpy_call`in AYNI "path/ext_name/
//! func_name SADECE string LİTERALİ" güvenlik kısıtı BURADA da GEÇERLİDİR.
//!
//! **Faz 17 — çoklu-argüman + list/dict/class marshalling** (bkz. plan
//! dosyası "kalıcı tutamaçlı HPy çağrılarına çoklu-argüman..."): Faz 16'nın
//! `nox_hpy_call_on`/`nox_hpy_call_str_on`sı (SADECE TEK bir `int`/`str`
//! argüman) BURADA `nox_hpy_args_begin`/`nox_hpy_args_add_*`/`nox_hpy_
//! call_{int,float,bool,str}_finish` "builder" zincirine YERİNİ BIRAKTI —
//! bkz. `MarshalCtx`nin belge notu (aşağıda) TAM tasarım İçİn.
//!
//! **Faz 18 — istisna entegrasyonu** (bkz. plan dosyası "HPy köprüsünü
//! Nox'un istisna mekanizmasına entegre etme"): yukarıdaki "Kapsam"
//! notunun "Nox'un genel istisna mekanizmasıyla entegre bir hata sinyali
//! HENÜZ yok" cümlesi ARTIK GEÇERLİ DEĞİL — `g_hpy_last_error`/`nox_hpy_
//! take_error` (aşağıda) bir hata METNİ TAŞIR, `compiler/codegen_qbe/
//! calls.zig`nin `emitHpyErrorCheckOrRaise`i HER `hpy_*` çağrısından
//! HEMEN SONRA BUNU okuyup (VARSA) bir `HPyError` (bkz. `stdlib/nox/
//! core.nox`) inşa edip `raise` eder — `try`/`except HPyError:` İLE
//! GERÇEKTEN yakalanabilir.

const std = @import("std");
const asap = @import("alloc/asap.zig");
const hpy_bridge = @import("hpy_bridge");
const wasm_bridge = @import("wasm_bridge");
const str_mod = @import("str.zig");
const abi_layout = @import("abi_layout");
const arc_mod = @import("alloc/arc.zig");
const dict_mod = @import("collections/dict.zig");

/// Doğrudan libc bağlamaları — bu dosya `std.Io`nun (uygulama düzeyi,
/// başlatma gerektiren) soyutlamasını KULLANMAZ; runtime zaten sistem
/// `cc`siyle bağlandığı için (bkz. compiler/main.zig) bu semboller her
/// zaman mevcuttur. Yalnızca bir dosyayı baştan sona okumak için minimal
/// bir yol.
const libc = struct {
    extern "c" fn fopen(filename: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
    extern "c" fn fclose(stream: *anyopaque) c_int;
    extern "c" fn fread(ptr: [*]u8, size: usize, count: usize, stream: *anyopaque) usize;
    extern "c" fn fseek(stream: *anyopaque, offset: c_long, whence: c_int) c_int;
    extern "c" fn ftell(stream: *anyopaque) c_long;
};

fn readFileAll(allocator: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const f = libc.fopen(path, "rb") orelse return error.FileNotFound;
    defer _ = libc.fclose(f);
    if (libc.fseek(f, 0, 2) != 0) return error.SeekFailed; // SEEK_END
    const size = libc.ftell(f);
    if (size < 0) return error.TellFailed;
    _ = libc.fseek(f, 0, 0); // SEEK_SET
    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);
    const n = libc.fread(buf.ptr, 1, buf.len, f);
    return buf[0..n];
}

/// Faz 18: `hpy_*` fonksiyonlarının HERHANGİ birinin GERÇEKLEŞTİRDİĞİ
/// son hatanın METNİ — codegen'in `nox_hpy_take_error`sı İLE HEMEN
/// SONRA (senkron, AYNI fiber, AYNI çağrı zincirinin İÇİNDE — fiber
/// migrasyonu SADECE `await` NOKTALARINDA olur, BURADA YOK) okunup
/// TÜKETİLİR — bu YÜZDEN threadlocal GÜVENLİDİR (bkz. `g_scheduler`nin
/// AYNI güvenlik gerekçesi). `std.heap.page_allocator` KULLANILIR (bu
/// SADECE bir hata METNİ, `rt`nin KENDİ, sızıntı-tespit eden allocator'ına
/// İHTİYAÇ YOK — `cycle_detector.zig`nin worklist'inin AYNI "geçici
/// scratch İçİn page_allocator" deseni).
threadlocal var g_hpy_last_error: ?[:0]u8 = null;

fn setHpyError(comptime fmt: []const u8, args: anytype) void {
    if (g_hpy_last_error) |old| std.heap.page_allocator.free(old);
    g_hpy_last_error = null;
    const msg = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch return;
    defer std.heap.page_allocator.free(msg);
    g_hpy_last_error = std.heap.page_allocator.dupeZ(u8, msg) catch null;
}

/// `g_hpy_last_error`i (VARSA) GERÇEK bir Nox `str`ine (`nox_str_from_bytes`)
/// çevirip DÖNER VE yuvayı TEMİZLER (`nox_exception_take`nin AYNI "bir kez
/// tüket" deseni); hata YOKSA `null`. Codegen HER `hpy_*` çağrısından
/// HEMEN SONRA BUNU çağırıp `null`-DIŞI dönerse bir `HPyError` inşa edip
/// `raise` eder (bkz. `compiler/codegen_qbe/calls.zig`nin `emitHpyErrorCheckOrRaise`i).
pub export fn nox_hpy_take_error(rt: ?*anyopaque) ?[*:0]u8 {
    const msg = g_hpy_last_error orelse return null;
    defer std.heap.page_allocator.free(msg);
    g_hpy_last_error = null;
    return str_mod.nox_str_from_bytes(rt, msg);
}

/// `path`teki paylaşımlı kütüphaneyi (gerçek bir `HPY_ABI_UNIVERSAL`
/// eklentisi) yükler, `ext_name` giriş noktasını çağırır, `func_name`
/// adlı (`HPyFunc_O` imzalı) metodu `arg` ile çağırıp sonucu döner.
pub export fn nox_hpy_call(
    rt: ?*anyopaque,
    path: ?[*:0]const u8,
    ext_name: ?[*:0]const u8,
    func_name: ?[*:0]const u8,
    arg: i64,
) i64 {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return 0));
    const allocator = state.allocator();
    const p = path orelse return 0;
    const en = ext_name orelse return 0;
    const fnm = func_name orelse return 0;

    var mod = hpy_bridge.loader.load(std.mem.span(p), std.mem.span(en)) catch |e| {
        setHpyError("HPy modülü açılamadı: {s} ({s}): {t}", .{ std.mem.span(p), std.mem.span(en), e });
        return 0;
    };
    defer mod.deinit();

    // Faz 20: `mod.findMethodO` (HPyFunc_O, TEK arg) BULUNAMAZSA `mod.
    // findMethodNoArgs`e (HPyFunc_NOARGS) DÜŞÜLÜR — GERÇEK Cython-üretimi
    // kod `HPy_mod_exec` İçİnde populate ettiği modül attribute'larını
    // OKUYAN fonksiyonlar TİPİK olarak argümansızdır (`answer()` GİBİ).
    const method_o = mod.findMethodO(std.mem.span(fnm));
    const method_noargs = if (method_o == null) mod.findMethodNoArgs(std.mem.span(fnm)) else null;
    if (method_o == null and method_noargs == null) {
        setHpyError("'{s}' bulunamadı", .{std.mem.span(fnm)});
        return 0;
    }

    const ctx = hpy_bridge.context.createContext(allocator) catch {
        setHpyError("HPy context oluşturulamadı", .{});
        return 0;
    };
    defer hpy_bridge.context.destroyContext(allocator, ctx);

    // Faz 20 (bkz. plan dosyası "HPy modül nesnesi + HPy_mod_exec desteği"):
    // GERÇEK Cython-üretimi kod `self`in GERÇEK modül nesnesi OLMASINI
    // BEKLER (derleme-zamanı sabitlerini `self`in attribute'u OLARAK okur)
    // — `HPy_NULL` GEÇİRMEK ARTIK YETERSİZ.
    const module_obj = setupModuleObject(ctx, &mod) orelse return 0;
    defer ctx.ctx_Close.?(ctx, module_obj);

    const h_result: hpy_bridge.context.HPy = blk: {
        if (method_o) |method| {
            const h_arg = ctx.ctx_Long_FromInt64_t.?(ctx, arg);
            defer ctx.ctx_Close.?(ctx, h_arg);
            break :blk method(ctx, module_obj, h_arg);
        }
        break :blk method_noargs.?(ctx, module_obj);
    };
    defer ctx.ctx_Close.?(ctx, h_result);
    if (ctx.ctx_Err_Occurred.?(ctx) != 0) {
        ctx.ctx_Err_Clear.?(ctx);
        setHpyError("'{s}' bir istisna fırlattı", .{std.mem.span(fnm)});
        return 0;
    }
    return ctx.ctx_Long_AsInt64_t.?(ctx, h_result);
}

/// Faz 15 (bkz. compiler/typecheck/checker.zig'deki `hpy_call_str`in
/// belge notu): `nox_hpy_call`nin YALNIZCA `str` argüman/dönüşlü kardeşi
/// — `HPyFunc_KEYWORDS` imzalı metodları (`ujson_hpy.dumps`/`loads` GİBİ)
/// TEK, POZİSYONEL argümanla (anahtar kelime OLMADAN, `kwnames=HPy_NULL`)
/// çağırır. `arg`, GEÇERLİ (başlıklı) bir Nox `str`i OLMALIDIR — `str_mod.
/// nox_str_slice` İLE O(1) okunur (bkz. `str.zig`nin modül üstü notu,
/// bu ARTIK bir `strlen` taraması GEREKTİRMEZ). Sonuç, `ctx_Unicode_
/// AsUTF8AndSize` İLE HPy tarafından okunup `dupeToNoxStr` İLE GERÇEK,
/// başlıklı bir Nox `str`ine KOPYALANIR (HPy handle'ının KENDİSİ `ctx_
/// Close` İLE hemen ARDINDAN kapatıldığından, ham işaretçiyi PAYLAŞMAK
/// GÜVENLİ DEĞİLDİR). Herhangi bir adımda hata OLURSA (yükleme/metod
/// bulunamadı, HPy istisnası, sonuç `str` DEĞİL) `hpy_call`nin AYNI
/// "entegre istisna mekanizması HENÜZ yok" ilkesiyle boş bir `str` döner.
pub export fn nox_hpy_call_str(
    rt: ?*anyopaque,
    path: ?[*:0]const u8,
    ext_name: ?[*:0]const u8,
    func_name: ?[*:0]const u8,
    arg: ?[*:0]const u8,
) ?[*:0]u8 {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    const allocator = state.allocator();
    const p = path orelse return str_mod.nox_str_from_bytes(rt, "");
    const en = ext_name orelse return str_mod.nox_str_from_bytes(rt, "");
    const fnm = func_name orelse return str_mod.nox_str_from_bytes(rt, "");
    const arg_h = arg orelse return str_mod.nox_str_from_bytes(rt, "");

    var mod = hpy_bridge.loader.load(std.mem.span(p), std.mem.span(en)) catch |e| {
        setHpyError("HPy modülü açılamadı: {s} ({s}): {t}", .{ std.mem.span(p), std.mem.span(en), e });
        return str_mod.nox_str_from_bytes(rt, "");
    };
    defer mod.deinit();

    const method = mod.findMethodKeywords(std.mem.span(fnm)) orelse {
        setHpyError("'{s}' bulunamadı", .{std.mem.span(fnm)});
        return str_mod.nox_str_from_bytes(rt, "");
    };

    const ctx = hpy_bridge.context.createContext(allocator) catch {
        setHpyError("HPy context oluşturulamadı", .{});
        return str_mod.nox_str_from_bytes(rt, "");
    };
    defer hpy_bridge.context.destroyContext(allocator, ctx);

    const module_obj = setupModuleObject(ctx, &mod) orelse return str_mod.nox_str_from_bytes(rt, "");
    defer ctx.ctx_Close.?(ctx, module_obj);

    const arg_slice = str_mod.nox_str_slice(arg_h);
    const arg_z = allocator.dupeZ(u8, arg_slice) catch return str_mod.nox_str_from_bytes(rt, "");
    defer allocator.free(arg_z);
    const h_arg = ctx.ctx_Unicode_FromString.?(ctx, arg_z);
    defer ctx.ctx_Close.?(ctx, h_arg);

    const args = [_]hpy_bridge.context.HPy{h_arg};
    const h_result = method(ctx, module_obj, &args, 1, hpy_bridge.context.HPy_NULL);
    defer ctx.ctx_Close.?(ctx, h_result);

    if (ctx.ctx_Err_Occurred.?(ctx) != 0) {
        ctx.ctx_Err_Clear.?(ctx);
        setHpyError("'{s}' bir istisna fırlattı", .{std.mem.span(fnm)});
        return str_mod.nox_str_from_bytes(rt, "");
    }

    var size: isize = 0;
    const result_str = ctx.ctx_Unicode_AsUTF8AndSize.?(ctx, h_result, &size) orelse return str_mod.nox_str_from_bytes(rt, "");
    return str_mod.nox_str_from_bytes(rt, result_str[0..@intCast(size)]);
}

/// Faz 16: `hpy_open`/`hpy_call_on`/`hpy_call_str_on`/`hpy_close`nin
/// paylaştığı, `rt`nin allocator'ında yaşayan opak tutamaç — `nox_hpy_open`
/// TARAFINDAN yaratılır, Nox tarafında `ptr` OLARAK taşınır (İçİNE
/// BAKILMAZ), `nox_hpy_close` TARAFINDAN yok edilir.
const PersistentHpyHandle = struct {
    mod: hpy_bridge.loader.LoadedModule,
    ctx: *hpy_bridge.context.HPyContext,
    /// Faz 20 (bkz. plan dosyası "HPy modül nesnesi + HPy_mod_exec desteği"):
    /// modülün KENDİ nesnesi — GERÇEK HPy host'larının import ANINDA
    /// oluşturup `HPy_mod_exec` slot'una geçirdiği (`self` OLARAK KULLANILAN)
    /// nesnenin AYNISI. `noxtest.c`nin HİÇ KULLANMADIĞI (`self`i HER ZAMAN
    /// yok sayan) test fonksiyonlarının AKSİNE, GERÇEK Cython-üretimi kod
    /// (`answer()` GİBİ) derleme-zamanı sabitlerini BU nesnenin attribute'u
    /// OLARAK saklar — `self = HPy_NULL` GEÇİRİLİRSE `HPy_GetAttr_s`
    /// BAŞARISIZ olur.
    module_obj: hpy_bridge.context.HPy,
};

/// Faz 20: `mod`nin KENDİ modül nesnesini (`context.createModuleObject`)
/// yaratıp, VARSA `HPy_mod_exec` slot'unu BU nesneyle ÇAĞIRIR (derleme-
/// zamanı sabitlerini/globallerini populate ETMESİ İçİn) — HEM `nox_hpy_
/// open` (kalıcı tutamaç) HEM `nox_hpy_call`/`nox_hpy_call_str` (Faz
/// 14/15'in ESKİ, tek-seferlik fonksiyonları) TARAFINDAN PAYLAŞILIR.
/// `HPy_mod_exec` BAŞARISIZ olursa (`!= 0` döner — GERÇEK HPy sözleşmesi,
/// hata durumu ZATEN `ctx`e YAZILMIŞTIR) modül nesnesi kapatılıp `null`
/// döner.
fn setupModuleObject(ctx: *hpy_bridge.context.HPyContext, mod: *const hpy_bridge.loader.LoadedModule) ?hpy_bridge.context.HPy {
    const m = hpy_bridge.context.createModuleObject(ctx) catch {
        setHpyError("modül nesnesi oluşturulamadı", .{});
        return null;
    };
    if (mod.findModExecSlot()) |exec_fn| {
        if (exec_fn(ctx, m) != 0) {
            ctx.ctx_Err_Clear.?(ctx);
            setHpyError("modül exec (HPy_mod_exec) başarısız oldu", .{});
            ctx.ctx_Close.?(ctx, m);
            return null;
        }
    }
    return m;
}

/// `path`teki paylaşımlı kütüphaneyi (`ext_name` giriş noktasıyla) BİR
/// KEZ yükler VE BİR KEZ bir `HPyContext` yaratıp `PersistentHpyHandle`
/// İçİnde saklar. Herhangi bir adım BAŞARISIZ olursa (dosya bulunamadı,
/// giriş noktası eksik, context yaratma başarısız) KISMİ olarak açılmış
/// kaynaklar TEMİZLENİP `null` DÖNER — `hpy_call`nin AYNI "hata sinyali
/// HENÜZ yok, güvenli-varsayılan dön" ilkesiyle TUTARLI.
pub export fn nox_hpy_open(
    rt: ?*anyopaque,
    path: ?[*:0]const u8,
    ext_name: ?[*:0]const u8,
) ?*anyopaque {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    const allocator = state.allocator();
    const p = path orelse return null;
    const en = ext_name orelse return null;

    var mod = hpy_bridge.loader.load(std.mem.span(p), std.mem.span(en)) catch |e| {
        setHpyError("HPy modülü açılamadı: {s} ({s}): {t}", .{ std.mem.span(p), std.mem.span(en), e });
        return null;
    };
    const ctx = hpy_bridge.context.createContext(allocator) catch {
        mod.deinit();
        setHpyError("HPy context oluşturulamadı", .{});
        return null;
    };
    const module_obj = setupModuleObject(ctx, &mod) orelse {
        hpy_bridge.context.destroyContext(allocator, ctx);
        mod.deinit();
        return null;
    };
    const handle = allocator.create(PersistentHpyHandle) catch {
        ctx.ctx_Close.?(ctx, module_obj);
        hpy_bridge.context.destroyContext(allocator, ctx);
        mod.deinit();
        setHpyError("bellek yetersiz", .{});
        return null;
    };
    handle.* = .{ .mod = mod, .ctx = ctx, .module_obj = module_obj };
    return handle;
}

/// `handle`nin modül nesnesini VE context'ini yok eder, kütüphaneyi
/// kapatır, tutamaç struct'ının KENDİSİNİ serbest bırakır. `handle_ptr
/// == null` İSE (ör. `hpy_open` BAŞARISIZ olduysa) SESSİZCE hiçbir şey
/// yapmaz.
pub export fn nox_hpy_close(rt: ?*anyopaque, handle_ptr: ?*anyopaque) void {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return));
    const allocator = state.allocator();
    const handle: *PersistentHpyHandle = @ptrCast(@alignCast(handle_ptr orelse return));
    handle.ctx.ctx_Close.?(handle.ctx, handle.module_obj);
    hpy_bridge.context.destroyContext(allocator, handle.ctx);
    handle.mod.deinit();
    allocator.destroy(handle);
}

/// Faz 17 (bkz. plan dosyası "kalıcı tutamaçlı HPy çağrılarına çoklu-
/// argüman + list/dict/class marshalling"): `hpy_call_on`/`hpy_call_str_on`
/// (VE YENİ `hpy_call_float_on`/`hpy_call_bool_on`) ARTIK SIFIR VEYA DAHA
/// FAZLA, HETEROJEN tipli (int/float/bool/str/list[T]/dict[K,V]/class)
/// argüman kabul eder. Tasarım: "builder" deseni — codegen HER argümanın
/// STATİK tipine göre (checker ZATEN biliyor) tip-başına KÜÇÜK bir marshal
/// fonksiyonu çağırır (`nox_hpy_args_add_*`), HEPSİ paylaşılan bir
/// `MarshalCtx`e (aşağıda) EKLER; SONUNDA dönüş-tipine özel bir
/// `nox_hpy_call_{int,float,bool,str}_finish` GERÇEK çağrıyı yapıp sonucu
/// unmarshal eder VE `MarshalCtx`i TAMAMEN serbest bırakır.
///
/// **Yaşam döngüsü kuralı**: bir HPy handle'ı bir KONTEYNERE (liste/dict)
/// YERLEŞTİRİLDİĞİ ANDA (append/setitem SONRASI) HEMEN `ctx_Close` İLE
/// kapatılır (GEÇİCİ kullanım, `hpy_call_str`nin ZATEN kanıtladığı
/// `defer ctx.ctx_Close` disiplininin GENELLEŞTİRİLMİŞ hali) — SADECE
/// `mc.args`e DOĞRUDAN eklenen ÜST-DÜZEY (positional) argüman handle'ları,
/// GERÇEK çağrı YAPILANA kadar açık kalır ve çağrı SONRASI (`_finish`
/// fonksiyonlarının İÇİNDE) toplu kapatılır.
///
/// **Kapsam (v1, bilinçli olarak dar)**: `list[T]`/`dict[K,V]` yalnızca
/// SKALER `T`/`K`/`V` (int/float/bool/str, `dict`in KENDİ v1 kısıtıyla
/// ZATEN TUTARLI) — İÇ İÇE konteynerler DESTEKLENMEZ (checker reddeder).
/// `class` örnekleri yalnızca TÜM alanları skaler İSE marshalling'e
/// KATILIR VE yalnızca alan-adı→değer bir HPy `dict`i OLARAK ("surrogate"
/// temsil, GERÇEK bir HPy özel tipi DEĞİL — bkz. `HPyType_FromSpec`nin
/// HENÜZ desteklenmediği, gelecekteki bir faz) — bu SADECE GİDEN yönde
/// çalışır, DÖNÜŞ tipi (bu fazda) yalnızca int/float/bool/str olabilir
/// (geriye-dönük tip çıkarımı olmadığından list/dict/class dönüş tipi
/// AYRI/gelecekteki bir iştir).
/// Faz 19 (bkz. plan dosyası "opak HPy nesne tutamaçları"): HER argüman
/// girdisi ARTIK "bu handle ÇAĞRI SONRASI OTOMATİK kapatılsın mı" bilgisini
/// de taşır — TAZE inşa edilen skaler/list/dict/class-dict argümanları
/// (`owned=true`) ÇAĞRI SONRASI kapatılır; `nox_hpy_args_add_handle` İLE
/// eklenen bir OPAK tutamaç argümanı (`owned=false`) İSE Nox'un ZATEN
/// SAHİP OLDUĞU, ÖDÜNÇ verilen bir referanstır — kapatılmaz (Nox `hpy_
/// close_obj` İLE KENDİSİ AÇIKÇA kapatacaktır).
const ArgEntry = struct { h: hpy_bridge.context.HPy, owned: bool };

const MarshalCtx = struct {
    handle: *PersistentHpyHandle,
    allocator: std.mem.Allocator,
    args: std.ArrayListUnmanaged(ArgEntry) = .empty,
    /// Bir `class` argümanı alan-alan İNŞA EDİLİRKEN kullanılan GEÇİCİ
    /// "şu an inşa edilen dict" — sınıf alanları İÇ İÇE OLAMAYACAĞINDAN
    /// (checker reddeder) AYNI ANDA SADECE TEK bir class-dict'in inşa
    /// halinde olması GARANTİdir.
    current_class_dict: ?hpy_bridge.context.HPy = null,
    /// Faz 21 (bkz. plan dosyası "modül-seviyesi tip inşası + GETSET +
    /// NOARGS tip metodları"): `hpy_call_attr_on`nin hedefi — `mc.handle.
    /// module_obj` DEĞİL, KEYFİ bir opak örnek tutamacı (`nox_hpy_args_
    /// begin_for_obj` TARAFINDAN doldurulur; `nox_hpy_args_begin`nin
    /// (module-seviyesi çağrılar İçİn) doldurduğu YOL BUNU `null` BIRAKIR).
    target_obj: ?hpy_bridge.context.HPy = null,
};

fn freeMarshalCtx(mc: *MarshalCtx) void {
    const ctx = mc.handle.ctx;
    for (mc.args.items) |e| if (e.owned) ctx.ctx_Close.?(ctx, e.h);
    mc.args.deinit(mc.allocator);
    mc.allocator.destroy(mc);
}

/// `list_ptr`nin (opak, ARC başlığından SONRAKİ `len@0`/`elemler@16`
/// düzenine sahip) `index`teki elemanını `elem_kind`e (0=int,1=float,
/// 2=bool,3=str) göre TAZE bir HPy handle'ına marshal eder — ÇAĞIRAN,
/// bu handle'ı kullanımı BİTER BİTMEZ `ctx_Close` İLE kapatmalıdır.
fn readListElemAsHpy(mc: *MarshalCtx, list_ptr: ?*anyopaque, index: usize, elem_kind: i32) hpy_bridge.context.HPy {
    const ctx = mc.handle.ctx;
    const base: [*]const u8 = @ptrCast(@alignCast(list_ptr orelse return hpy_bridge.context.HPy_NULL));
    switch (elem_kind) {
        0 => {
            const slot: *align(1) const i64 = @ptrCast(base + abi_layout.LIST_HEADER_SIZE + index * 8);
            return ctx.ctx_Long_FromInt64_t.?(ctx, slot.*);
        },
        1 => {
            const slot: *align(1) const i64 = @ptrCast(base + abi_layout.LIST_HEADER_SIZE + index * 8);
            const f: f64 = @bitCast(slot.*);
            return ctx.ctx_Float_FromDouble.?(ctx, f);
        },
        2 => {
            const slot: *align(1) const i32 = @ptrCast(base + abi_layout.LIST_HEADER_SIZE + index * 4);
            return ctx.ctx_Bool_FromBool.?(ctx, slot.* != 0);
        },
        3 => {
            const slot: *align(1) const i64 = @ptrCast(base + abi_layout.LIST_HEADER_SIZE + index * 8);
            const raw: usize = @intCast(slot.*);
            if (raw == 0) return ctx.ctx_Unicode_FromString.?(ctx, "");
            const sp: [*:0]const u8 = @ptrFromInt(raw);
            const s = str_mod.nox_str_slice(sp);
            const z = mc.allocator.dupeZ(u8, s) catch return hpy_bridge.context.HPy_NULL;
            defer mc.allocator.free(z);
            return ctx.ctx_Unicode_FromString.?(ctx, z);
        },
        else => return hpy_bridge.context.HPy_NULL,
    }
}

/// `nox_hpy_args_add_dict_scalar`nin `nox_dict_keys`/`nox_dict_values`ten
/// aldığı GEÇİCİ tarama listelerini serbest bırakır — `str` elemanlıysa
/// (`buildEntryList`in HER `str` elemanı retain ettiği İçin) ÖNCE HER
/// elemanın KENDİ referansını `nox_str_release` İLE bırakır, SONRA
/// listenin KENDİ ARC başlığını `nox_rc_release` İLE.
fn freeTempScalarList(rt: ?*anyopaque, list_ptr: ?*anyopaque, elem_size: i64, is_str: bool) void {
    const lp = list_ptr orelse return;
    const base: [*]const u8 = @ptrCast(@alignCast(lp));
    const len_ptr: *align(1) const i64 = @ptrCast(base);
    const len: usize = @intCast(len_ptr.*);
    if (is_str) {
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const slot: *align(1) const i64 = @ptrCast(base + abi_layout.LIST_HEADER_SIZE + i * 8);
            const raw: usize = @intCast(slot.*);
            if (raw != 0) {
                const sp: [*:0]u8 = @ptrFromInt(raw);
                str_mod.nox_str_release(rt, sp);
            }
        }
    }
    const payload_size = abi_layout.LIST_HEADER_SIZE + @as(usize, @intCast(elem_size)) * len;
    arc_mod.nox_rc_release(rt, lp, payload_size);
}

/// `handle`nin `ctx`iyle YENİ bir `MarshalCtx` yaratır — `handle_ptr`
/// `null`sa (ör. `hpy_open` başarısız olduysa) `null` döner, TÜM sonraki
/// `add_*`/`finish` fonksiyonları BUNU sessizce yok sayar.
pub export fn nox_hpy_args_begin(rt: ?*anyopaque, handle_ptr: ?*anyopaque) ?*anyopaque {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    const allocator = state.allocator();
    const hp = handle_ptr orelse {
        setHpyError("geçersiz (açılamamış) HPy tutamacı", .{});
        return null;
    };
    const handle: *PersistentHpyHandle = @ptrCast(@alignCast(hp));
    const mc = allocator.create(MarshalCtx) catch return null;
    mc.* = .{ .handle = handle, .allocator = allocator };
    return mc;
}

/// Faz 21: `nox_hpy_args_begin`nin AYNI karşılığı — `hpy_call_attr_on`
/// İçİn, hedef `mc.handle.module_obj` DEĞİL, `obj_ptr`nin İŞARET ETTİĞİ
/// KEYFİ bir opak örnek tutamacıdır (ör. `hpy_new_on`nin DAHA ÖNCE
/// döndürdüğü bir Box örneği).
pub export fn nox_hpy_args_begin_for_obj(rt: ?*anyopaque, handle_ptr: ?*anyopaque, obj_ptr: ?*anyopaque) ?*anyopaque {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    const allocator = state.allocator();
    const hp = handle_ptr orelse {
        setHpyError("geçersiz (açılamamış) HPy tutamacı", .{});
        return null;
    };
    const op = obj_ptr orelse {
        setHpyError("geçersiz nesne", .{});
        return null;
    };
    const handle: *PersistentHpyHandle = @ptrCast(@alignCast(hp));
    const mc = allocator.create(MarshalCtx) catch return null;
    mc.* = .{ .handle = handle, .allocator = allocator, .target_obj = .{ ._i = @bitCast(@intFromPtr(op)) } };
    return mc;
}

pub export fn nox_hpy_args_add_int(mc_ptr: ?*anyopaque, value: i64) void {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return));
    const ctx = mc.handle.ctx;
    const h = ctx.ctx_Long_FromInt64_t.?(ctx, value);
    mc.args.append(mc.allocator, .{ .h = h, .owned = true }) catch ctx.ctx_Close.?(ctx, h);
}

pub export fn nox_hpy_args_add_float(mc_ptr: ?*anyopaque, value: f64) void {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return));
    const ctx = mc.handle.ctx;
    const h = ctx.ctx_Float_FromDouble.?(ctx, value);
    mc.args.append(mc.allocator, .{ .h = h, .owned = true }) catch ctx.ctx_Close.?(ctx, h);
}

pub export fn nox_hpy_args_add_bool(mc_ptr: ?*anyopaque, value: i32) void {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return));
    const ctx = mc.handle.ctx;
    const h = ctx.ctx_Bool_FromBool.?(ctx, value != 0);
    mc.args.append(mc.allocator, .{ .h = h, .owned = true }) catch ctx.ctx_Close.?(ctx, h);
}

pub export fn nox_hpy_args_add_str(mc_ptr: ?*anyopaque, value: ?[*:0]const u8) void {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return));
    const ctx = mc.handle.ctx;
    const v = value orelse "";
    const s = str_mod.nox_str_slice(v);
    const z = mc.allocator.dupeZ(u8, s) catch return;
    defer mc.allocator.free(z);
    const h = ctx.ctx_Unicode_FromString.?(ctx, z);
    mc.args.append(mc.allocator, .{ .h = h, .owned = true }) catch ctx.ctx_Close.?(ctx, h);
}

/// `list_ptr`i (skaler elemanlı, `elem_kind` 0=int/1=float/2=bool/3=str)
/// gezip HER elemanı marshal edip TAZE bir HPy list'ine (`ctx_List_
/// Append`) ekler, SONRA bu list'i (tek bir üst-düzey argüman olarak)
/// `mc.args`e ekler. `list_ptr == null` (BAŞLANGIÇ DEĞERİ verilmemiş bir
/// list yereli — Nox tipçekleyicisi BUNU normalde ENGELLER, savunmacı dal)
/// İSE boş bir HPy listesi geçirilir.
pub export fn nox_hpy_args_add_list_scalar(mc_ptr: ?*anyopaque, list_ptr: ?*anyopaque, elem_kind: i32) void {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return));
    const ctx = mc.handle.ctx;
    const h_list = ctx.ctx_List_New.?(ctx, 0);
    const lp = list_ptr orelse {
        mc.args.append(mc.allocator, .{ .h = h_list, .owned = true }) catch ctx.ctx_Close.?(ctx, h_list);
        return;
    };
    const base: [*]const u8 = @ptrCast(@alignCast(lp));
    const len_ptr: *align(1) const i64 = @ptrCast(base);
    const len: usize = @intCast(len_ptr.*);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const h_elem = readListElemAsHpy(mc, lp, i, elem_kind);
        _ = ctx.ctx_List_Append.?(ctx, h_list, h_elem);
        ctx.ctx_Close.?(ctx, h_elem);
    }
    mc.args.append(mc.allocator, .{ .h = h_list, .owned = true }) catch ctx.ctx_Close.?(ctx, h_list);
}

/// `dict_ptr`i (skaler anahtar/değerli, `key_kind`/`value_kind` AYNI
/// 0=int/1=float/2=bool/3=str kodlaması) `nox_dict_keys`/`nox_dict_values`
/// (ZATEN VAR olan runtime fonksiyonları) İLE İKİ Nox list'ine (AYNI SIRAYLA
/// — dict değişmeden İKİ ardışık çağrı) çözüp ZIP'leyerek TAZE bir HPy
/// dict'ine (`ctx_SetItem`) doldurur, SONRA bunu `mc.args`e ekler.
pub export fn nox_hpy_args_add_dict_scalar(rt: ?*anyopaque, mc_ptr: ?*anyopaque, dict_ptr: ?*anyopaque, key_kind: i32, value_kind: i32) void {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return));
    const ctx = mc.handle.ctx;
    const h_dict = ctx.ctx_Dict_New.?(ctx);
    const dp = dict_ptr orelse {
        mc.args.append(mc.allocator, .{ .h = h_dict, .owned = true }) catch ctx.ctx_Close.?(ctx, h_dict);
        return;
    };
    const key_is_str: i32 = if (key_kind == 3) 1 else 0;
    const value_is_str: i32 = if (value_kind == 3) 1 else 0;
    const key_elem_size: i64 = if (key_kind == 2) 4 else 8;
    const value_elem_size: i64 = if (value_kind == 2) 4 else 8;
    const keys_list = dict_mod.nox_dict_keys(rt, dp, key_is_str, key_elem_size);
    const values_list = dict_mod.nox_dict_values(rt, dp, value_is_str, 0, value_elem_size);
    defer freeTempScalarList(rt, keys_list, key_elem_size, key_is_str != 0);
    defer freeTempScalarList(rt, values_list, value_elem_size, value_is_str != 0);
    if (keys_list != null and values_list != null) {
        const klp: [*]const u8 = @ptrCast(@alignCast(keys_list.?));
        const len_ptr: *align(1) const i64 = @ptrCast(klp);
        const len: usize = @intCast(len_ptr.*);
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const h_key = readListElemAsHpy(mc, keys_list, i, key_kind);
            const h_val = readListElemAsHpy(mc, values_list, i, value_kind);
            _ = ctx.ctx_SetItem.?(ctx, h_dict, h_key, h_val);
            ctx.ctx_Close.?(ctx, h_key);
            ctx.ctx_Close.?(ctx, h_val);
        }
    }
    mc.args.append(mc.allocator, .{ .h = h_dict, .owned = true }) catch ctx.ctx_Close.?(ctx, h_dict);
}

/// Bir `class` argümanının marshalling'İNE BAŞLAR — YENİ, boş bir HPy
/// `dict`i (alan-adı→değer "surrogate" temsili) `mc.current_class_dict`e
/// atar. Codegen, sınıfın HER skaler alanı İçİn `nox_hpy_class_arg_set_*`i
/// SIRAYLA çağırır, SONRA `nox_hpy_class_arg_end`i çağırır.
pub export fn nox_hpy_class_arg_begin(mc_ptr: ?*anyopaque) void {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return));
    const ctx = mc.handle.ctx;
    mc.current_class_dict = ctx.ctx_Dict_New.?(ctx);
}

fn classArgSetKeyValue(mc: *MarshalCtx, field_name: ?[*:0]const u8, h_value: hpy_bridge.context.HPy) void {
    const ctx = mc.handle.ctx;
    const dict_h = mc.current_class_dict orelse return;
    const fname = field_name orelse return;
    const s = std.mem.span(fname);
    const z = mc.allocator.dupeZ(u8, s) catch return;
    defer mc.allocator.free(z);
    const h_key = ctx.ctx_Unicode_FromString.?(ctx, z);
    defer ctx.ctx_Close.?(ctx, h_key);
    _ = ctx.ctx_SetItem.?(ctx, dict_h, h_key, h_value);
}

pub export fn nox_hpy_class_arg_set_int(mc_ptr: ?*anyopaque, field_name: ?[*:0]const u8, value: i64) void {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return));
    const ctx = mc.handle.ctx;
    const h = ctx.ctx_Long_FromInt64_t.?(ctx, value);
    defer ctx.ctx_Close.?(ctx, h);
    classArgSetKeyValue(mc, field_name, h);
}

pub export fn nox_hpy_class_arg_set_float(mc_ptr: ?*anyopaque, field_name: ?[*:0]const u8, value: f64) void {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return));
    const ctx = mc.handle.ctx;
    const h = ctx.ctx_Float_FromDouble.?(ctx, value);
    defer ctx.ctx_Close.?(ctx, h);
    classArgSetKeyValue(mc, field_name, h);
}

pub export fn nox_hpy_class_arg_set_bool(mc_ptr: ?*anyopaque, field_name: ?[*:0]const u8, value: i32) void {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return));
    const ctx = mc.handle.ctx;
    const h = ctx.ctx_Bool_FromBool.?(ctx, value != 0);
    defer ctx.ctx_Close.?(ctx, h);
    classArgSetKeyValue(mc, field_name, h);
}

pub export fn nox_hpy_class_arg_set_str(mc_ptr: ?*anyopaque, field_name: ?[*:0]const u8, value: ?[*:0]const u8) void {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return));
    const ctx = mc.handle.ctx;
    const v = value orelse "";
    const s = str_mod.nox_str_slice(v);
    const z = mc.allocator.dupeZ(u8, s) catch return;
    defer mc.allocator.free(z);
    const h = ctx.ctx_Unicode_FromString.?(ctx, z);
    defer ctx.ctx_Close.?(ctx, h);
    classArgSetKeyValue(mc, field_name, h);
}

/// `mc.current_class_dict`i (tamamlanmış "surrogate" dict) TEK bir
/// üst-düzey argüman olarak `mc.args`e ekleyip GEÇİCİ alanı temizler.
pub export fn nox_hpy_class_arg_end(mc_ptr: ?*anyopaque) void {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return));
    const ctx = mc.handle.ctx;
    const dict_h = mc.current_class_dict orelse return;
    mc.current_class_dict = null;
    mc.args.append(mc.allocator, .{ .h = dict_h, .owned = true }) catch ctx.ctx_Close.?(ctx, dict_h);
}

/// Faz 19 (bkz. plan dosyası "opak HPy nesne tutamaçları"): `obj_ptr`
/// (Nox `ptr` DEĞERİ — `hpy_call_obj_on`nin DAHA ÖNCE döndürdüğü, bir
/// `HPyType_FromSpec` İLE tanımlanmış bir C eklenti tipinin ÖRNEĞİNE
/// işaret eden OPAK bir tutamaç) bir `HPy{._i=...}` OLARAK yeniden
/// yorumlanıp `mc.args`e `owned=false` OLARAK eklenir — Nox'un ZATEN
/// SAHİP olduğu, ÇAĞRI SONRASI kapatılMAYACAK, ÖDÜNÇ verilen bir
/// referanstır (kullanıcı, KENDİSİ bitirdiğinde `hpy_close_obj` İLE
/// AÇIKÇA kapatmalıdır). `compiler/codegen_qbe/calls.zig`nin `__nox_
/// hpy_obj_arg` İŞARETLEYİCİSİ TARAFINDAN, DİĞER `add_*` fonksiyonlarının
/// YERİNE (int/float/bool/str/list/dict/class-dict'in NORMAL tip-başına
/// dispatch'İNE HİÇ girmeden) çağrılır.
pub export fn nox_hpy_args_add_handle(mc_ptr: ?*anyopaque, obj_ptr: ?*anyopaque) void {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return));
    const op = obj_ptr orelse return;
    const h: hpy_bridge.context.HPy = .{ ._i = @bitCast(@intFromPtr(op)) };
    mc.args.append(mc.allocator, .{ .h = h, .owned = false }) catch {};
}

/// `mc.args`i `func_name` adlı metoda geçirip GERÇEK çağrıyı yapar —
/// ÖNCE `HPyFunc_KEYWORDS` imzasını dener (`nargs = mc.args.items.len`,
/// `nargs == 0` İçin `args = null`, GEÇERLİ bir çağrı biçimi); BULUNAMAZSA
/// (ör. Faz 16'nın `get_call_count`/`add_one` GİBİ ESKİ, `HPyFunc_O`
/// imzalı test fonksiyonları — GERİYE DÖNÜK uyumluluk İçİn) VE TAM
/// OLARAK 1 argüman VARSA `HPyFunc_O` imzasına DÜŞER. HİÇBİRİ
/// BULUNAMAZSA (Faz 18) `setHpyError` çağırıp `null` döner. BAŞARILI
/// bir çağrı SONRASI `ctx_Err_Occurred` İSE (çağrılan HPy C fonksiyonunun
/// KENDİSİ bir istisna fırlattı) SONUCU kapatıp HPy'nin KENDİ hata
/// durumunu temizleyip (`ctx_Err_Clear`) `setHpyError` çağırıp `null`
/// döner — çağıran (4 `_finish` fonksiyonu) `null`ı `0`/`0.0`/boş `str`
/// İLE karşılar, `compiler/codegen_qbe/calls.zig`nin `emitHpyErrorCheckOrRaise`i
/// bunu GERÇEK bir `HPyError`e çevirir.
fn invokeHpyMethod(mc: *MarshalCtx, func_name: []const u8) ?hpy_bridge.context.HPy {
    const ctx = mc.handle.ctx;
    // Faz 19: `mc.args` ARTIK `ArgEntry{h, owned}` TAŞIDIĞINDAN (opak
    // tutamaç argümanlarının `owned=false` OLABİLMESİ İçİn), GERÇEK
    // çağrı İçİn (`?[*]const HPy` bekleyen HPy imzasına UYMAK İçİn)
    // KISA ömürlü, YOĞUN bir `[]HPy` dizisi İNŞA EDİLİR.
    const n = mc.args.items.len;
    const packed_args = mc.allocator.alloc(hpy_bridge.context.HPy, n) catch {
        setHpyError("bellek yetersiz", .{});
        return null;
    };
    defer mc.allocator.free(packed_args);
    for (mc.args.items, 0..) |e, i| packed_args[i] = e.h;
    // Faz 20 (bkz. plan dosyası "HPy modül nesnesi + HPy_mod_exec desteği"):
    // `self` ARTIK `HPy_NULL` DEĞİL, `mc.handle.module_obj` — GERÇEK
    // Cython-üretimi kod derleme-zamanı sabitlerini `self`in attribute'u
    // OLARAK okur (`HPy_GetAttr_s(ctx, self, ...)`), `HPy_NULL` GEÇİLİRSE
    // BAŞARISIZ olur.
    const module_obj = mc.handle.module_obj;
    const h_result: hpy_bridge.context.HPy = blk: {
        if (mc.handle.mod.findMethodKeywords(func_name)) |method| {
            const args_ptr: ?[*]const hpy_bridge.context.HPy = if (n > 0) packed_args.ptr else null;
            break :blk method(ctx, module_obj, args_ptr, n, hpy_bridge.context.HPy_NULL);
        }
        // GERÇEK Cython-üretimi (aHPy `hpy-universal` arka ucu) kod
        // `HPyFunc_VARARGS`i (KEYWORDS'ün AYNISI, `kwnames` HARİÇ) VE
        // `HPyFunc_NOARGS`i (argümansız fonksiyonlar) de SIK kullanır —
        // `noxtest.c`nin ELLE yazılmış test fonksiyonları BUNLARI HİÇ
        // egzersiz ETMEDİĞİNDEN bu boşluk `hpy_tier0_test.zig`de HİÇ
        // fark edilmemişti.
        if (mc.handle.mod.findMethodVarargs(func_name)) |method| {
            const args_ptr: ?[*]const hpy_bridge.context.HPy = if (n > 0) packed_args.ptr else null;
            break :blk method(ctx, module_obj, args_ptr, n);
        }
        if (n == 1) {
            if (mc.handle.mod.findMethodO(func_name)) |method| {
                break :blk method(ctx, module_obj, packed_args[0]);
            }
        }
        if (n == 0) {
            if (mc.handle.mod.findMethodNoArgs(func_name)) |method| {
                break :blk method(ctx, module_obj);
            }
        }
        setHpyError("'{s}' bulunamadı", .{func_name});
        return null;
    };
    if (ctx.ctx_Err_Occurred.?(ctx) != 0) {
        ctx.ctx_Close.?(ctx, h_result);
        ctx.ctx_Err_Clear.?(ctx);
        setHpyError("'{s}' bir istisna fırlattı", .{func_name});
        return null;
    }
    return h_result;
}

/// Faz 24 (bkz. plan dosyası "bellek-içi file-like writer/reader
/// nesneleri" — GERÇEK `hpy-ujson`nin `dump()`u ELLE test EDİLİRKEN
/// bulunan, YAZAR/OKUYUCU özelliğiyle İLİŞKİSİZ, AYRI bir hata):
/// `nox_hpy_call_int_finish`/`_float_finish`/`_bool_finish`/`_str_finish`
/// ÖNCEDEN unmarshal (`ctx_Long_AsInt64_t`/vb.) BAŞARISIZ olduğunda
/// (ör. `dump()` GİBİ `None` DÖNEN bir fonksiyon YANLIŞLIKLA `hpy_call_on`
/// İLE — int bekleyerek — çağrıldığında) `ctx`nin KENDİ İÇ hata durumuna
/// (`ctxErrSetString`, Nox'un AYRI `g_hpy_last_error` KANALINDAN TAMAMEN
/// BAĞIMSIZ) bir `TypeError` YAZIP ASLA KONTROL/TEMİZLEMİYORDU — bu
/// SESSİZCE "başarılı" (garbage `0`/`0.0`/`false`/`""`) dönerdi VE
/// `ctx`nin İÇ hata durumu KİRLİ KALIRDI, AYNI `h` üzerindeki BAŞKA,
/// TAMAMEN İLİŞKİSİZ bir SONRAKİ çağrıyı (`HPyArg_ParseKeywords`nin
/// KENDİSİ BİLE bir PENDING hatayla karşılaştığında BAŞARISIZ OLABİLİR)
/// GİZEMLİ şekilde BOZARDI. Düzeltme: unmarshal SONRASI da `ctx_Err_
/// Occurred` KONTROL EDİLİR — VARSA temizlenip GERÇEK bir `HPyError`
/// OLARAK yüzeye ÇIKARILIR (`emitHpyErrorCheckOrRaise`nin ZATEN kontrol
/// ettiği KANALA yazılarak).
fn checkUnmarshalErr(ctx: *hpy_bridge.context.HPyContext, func_name: []const u8) bool {
    if (ctx.ctx_Err_Occurred.?(ctx) == 0) return false;
    ctx.ctx_Err_Clear.?(ctx);
    setHpyError("'{s}' beklenen tipte bir değer döndürmedi", .{func_name});
    return true;
}

/// `func_name` adlı metodu `mc.args`la çağırıp `int` sonucu unmarshal
/// eder, `mc`yi TAMAMEN serbest bırakır. `Err_Occurred`/"bulunamadı"
/// kontrolü `invokeHpyMethod`nin İÇİNDE yapılır (Faz 18) — BURADA
/// SADECE `null` (hata OLDU) İçin varsayılan `0` döner.
pub export fn nox_hpy_call_int_finish(mc_ptr: ?*anyopaque, func_name: ?[*:0]const u8) i64 {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return 0));
    defer freeMarshalCtx(mc);
    const fnm = func_name orelse return 0;
    const ctx = mc.handle.ctx;
    const h_result = invokeHpyMethod(mc, std.mem.span(fnm)) orelse return 0;
    defer ctx.ctx_Close.?(ctx, h_result);
    const v = ctx.ctx_Long_AsInt64_t.?(ctx, h_result);
    if (checkUnmarshalErr(ctx, std.mem.span(fnm))) return 0;
    return v;
}

/// `nox_hpy_call_int_finish`nin AYNISI, `float` dönüşle.
pub export fn nox_hpy_call_float_finish(mc_ptr: ?*anyopaque, func_name: ?[*:0]const u8) f64 {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return 0));
    defer freeMarshalCtx(mc);
    const fnm = func_name orelse return 0;
    const ctx = mc.handle.ctx;
    const h_result = invokeHpyMethod(mc, std.mem.span(fnm)) orelse return 0;
    defer ctx.ctx_Close.?(ctx, h_result);
    const v = ctx.ctx_Float_AsDouble.?(ctx, h_result);
    if (checkUnmarshalErr(ctx, std.mem.span(fnm))) return 0;
    return v;
}

/// `nox_hpy_call_int_finish`nin AYNISI, `bool` (0/1) dönüşle — genel
/// `ctx_IsTrue` (truthiness) İLE unmarshal eder. Not: `ctx_IsTrue`
/// GERÇEK HPy'de HERHANGİ bir nesne İçİn (Nox'un `.none`/`.exc_type`/
/// `.io_writer_`/vb. tagli TÜM nesneler DAHİL, bkz. `ctxIsTrue`nin KENDİ
/// switch'i) her zaman BAŞARIYLA bir 0/1 döner (`TypeError` fırlatmaz) —
/// bu YÜZDEN diğer üçünün AKSİNE bu unmarshal ADIMI ASLA başarısız
/// olamaz, `checkUnmarshalErr` GEREKMEZ (netlik İçİn AÇIKÇA belirtildi).
pub export fn nox_hpy_call_bool_finish(mc_ptr: ?*anyopaque, func_name: ?[*:0]const u8) i32 {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return 0));
    defer freeMarshalCtx(mc);
    const fnm = func_name orelse return 0;
    const ctx = mc.handle.ctx;
    const h_result = invokeHpyMethod(mc, std.mem.span(fnm)) orelse return 0;
    defer ctx.ctx_Close.?(ctx, h_result);
    return if (ctx.ctx_IsTrue.?(ctx, h_result) != 0) 1 else 0;
}

/// `nox_hpy_call_int_finish`nin AYNISı, `str` dönüşle — `Err_Occurred`/
/// "bulunamadı" kontrolü AYNI şekilde `invokeHpyMethod`nin İÇİNDE.
pub export fn nox_hpy_call_str_finish(rt: ?*anyopaque, mc_ptr: ?*anyopaque, func_name: ?[*:0]const u8) ?[*:0]u8 {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return null));
    defer freeMarshalCtx(mc);
    const fnm = func_name orelse return str_mod.nox_str_from_bytes(rt, "");
    const ctx = mc.handle.ctx;
    const h_result = invokeHpyMethod(mc, std.mem.span(fnm)) orelse return str_mod.nox_str_from_bytes(rt, "");
    defer ctx.ctx_Close.?(ctx, h_result);
    var size: isize = 0;
    const result_str = ctx.ctx_Unicode_AsUTF8AndSize.?(ctx, h_result, &size);
    if (checkUnmarshalErr(ctx, std.mem.span(fnm))) return str_mod.nox_str_from_bytes(rt, "");
    const rs = result_str orelse return str_mod.nox_str_from_bytes(rt, "");
    return str_mod.nox_str_from_bytes(rt, rs[0..@intCast(size)]);
}

/// Faz 19: `func_name` adlı metodu `mc.args`la çağırıp SONUCU unmarshal
/// ETMEDEN (ctx_Close ETMEDEN) DOĞRUDAN bir Nox `ptr` (`*anyopaque`)
/// OLARAK döner — GENELLİKLE bir `HPyType_FromSpec` İLE tanımlanmış
/// örnek (`make_counter`in ÖRNEĞİ GİBİ). Sahiplik Nox'a GEÇER — kullanıcı
/// SONUNDA `hpy_close_obj` İLE AÇIKÇA kapatmalıdır (KAPATMAZSA sızar,
/// `hpy_tier0_test.zig`nin KENDİ, ZATEN kabul ettiği "tip nesneleri
/// bilinçli olarak sızıyor" v1 ödünleşimiyle TUTARLI).
pub export fn nox_hpy_call_obj_finish(mc_ptr: ?*anyopaque, func_name: ?[*:0]const u8) ?*anyopaque {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return null));
    defer freeMarshalCtx(mc);
    const fnm = func_name orelse return null;
    const h_result = invokeHpyMethod(mc, std.mem.span(fnm)) orelse return null;
    const raw: usize = @bitCast(h_result._i);
    if (raw == 0) return null;
    return @ptrFromInt(raw);
}

/// Faz 19: `obj_ptr`nin (`hpy_call_obj_on`nin DAHA ÖNCE döndürdüğü opak
/// tutamaç) `handle.ctx` ÜZERİNDEN `ctx_Close`ünü çağırır — refcount
/// sıfıra düşerse C eklentisinin KENDİ `tp_destroy`sunu tetikler.
/// `obj_ptr == null` İSE (ör. `hpy_call_obj_on` BAŞARISIZ olduysa)
/// SESSİZCE hiçbir şey yapmaz.
pub export fn nox_hpy_close_obj(handle_ptr: ?*anyopaque, obj_ptr: ?*anyopaque) void {
    const handle: *PersistentHpyHandle = @ptrCast(@alignCast(handle_ptr orelse return));
    const op = obj_ptr orelse return;
    const ctx = handle.ctx;
    const h: hpy_bridge.context.HPy = .{ ._i = @bitCast(@intFromPtr(op)) };
    ctx.ctx_Close.?(ctx, h);
}

/// Faz 21 (bkz. plan dosyası "modül-seviyesi tip inşası + GETSET + NOARGS
/// tip metodları"): `mc.args`i `class_name` adlı, MODÜL nesnesinin KENDİ
/// bir attribute'u OLAN bir TİP nesnesine (`HPyType_FromSpec`in dönüşü,
/// ör. aHPy'nin `Box`u) `ctx_Call` İLE geçirir — GERÇEK HPy'nin `Type(...)`
/// çağrısının karşılığı (`ctx_GetAttr_s` + `ctx_Call`, İKİSİ de ZATEN VAR
/// OLAN, genel HPy operasyonları — YENİ bir "inşa" mekanizması GEREKMEZ).
/// Sonuç, `nox_hpy_call_obj_finish`in AYNI "unmarshal YOK, ham ptr döner"
/// deseniyle döner — sahiplik Nox'a GEÇER, kullanıcı SONUNDA `hpy_close_obj`
/// İLE AÇIKÇA kapatmalıdır.
pub export fn nox_hpy_new_finish(mc_ptr: ?*anyopaque, class_name: ?[*:0]const u8) ?*anyopaque {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return null));
    defer freeMarshalCtx(mc);
    const cn = class_name orelse return null;
    const ctx = mc.handle.ctx;
    const cls_h = ctx.ctx_GetAttr_s.?(ctx, mc.handle.module_obj, cn);
    if (ctx.ctx_Err_Occurred.?(ctx) != 0) {
        ctx.ctx_Err_Clear.?(ctx);
        setHpyError("'{s}' modülde bulunamadı", .{cn});
        return null;
    }
    defer ctx.ctx_Close.?(ctx, cls_h);
    const n = mc.args.items.len;
    const packed_args = mc.allocator.alloc(hpy_bridge.context.HPy, n) catch {
        setHpyError("bellek yetersiz", .{});
        return null;
    };
    defer mc.allocator.free(packed_args);
    for (mc.args.items, 0..) |e, i| packed_args[i] = e.h;
    const args_ptr: ?[*]const hpy_bridge.context.HPy = if (n > 0) packed_args.ptr else null;
    const h_result = ctx.ctx_Call.?(ctx, cls_h, args_ptr, n, hpy_bridge.context.HPy_NULL);
    if (ctx.ctx_Err_Occurred.?(ctx) != 0) {
        ctx.ctx_Close.?(ctx, h_result);
        ctx.ctx_Err_Clear.?(ctx);
        setHpyError("'{s}' inşa edilemedi", .{cn});
        return null;
    }
    const raw: usize = @bitCast(h_result._i);
    if (raw == 0) return null;
    return @ptrFromInt(raw);
}

/// Faz 21: `obj_ptr`nin (bir örnek tutamacı — GETSET/HPyField'a sahip bir
/// tip örneği, ör. `Box`) `attr_name` adlı attribute'unu (`ctx_GetAttr_s`
/// İLE — GETSET kayıtlıysa GERÇEK C getter'ı ÇAĞRILIR) OKUYUP `int` OLARAK
/// unmarshal eder.
pub export fn nox_hpy_getattr_int(handle_ptr: ?*anyopaque, obj_ptr: ?*anyopaque, attr_name: ?[*:0]const u8) i64 {
    const handle: *PersistentHpyHandle = @ptrCast(@alignCast(handle_ptr orelse return 0));
    const op = obj_ptr orelse {
        setHpyError("geçersiz nesne", .{});
        return 0;
    };
    const an = attr_name orelse return 0;
    const ctx = handle.ctx;
    const obj_h: hpy_bridge.context.HPy = .{ ._i = @bitCast(@intFromPtr(op)) };
    const h_result = ctx.ctx_GetAttr_s.?(ctx, obj_h, an);
    if (ctx.ctx_Err_Occurred.?(ctx) != 0) {
        ctx.ctx_Err_Clear.?(ctx);
        setHpyError("'{s}' attribute'u bulunamadı", .{an});
        return 0;
    }
    defer ctx.ctx_Close.?(ctx, h_result);
    return ctx.ctx_Long_AsInt64_t.?(ctx, h_result);
}

/// Faz 21: `obj_ptr`nin `attr_name` adlı attribute'unu `value`ya AYARLAR
/// (`ctx_SetAttr_s` İLE — GETSET kayıtlıysa GERÇEK C setter'ı ÇAĞRILIR,
/// `instance_dict`e SESSİZCE bir girdi EKLENMEZ).
pub export fn nox_hpy_setattr_int(handle_ptr: ?*anyopaque, obj_ptr: ?*anyopaque, attr_name: ?[*:0]const u8, value: i64) void {
    const handle: *PersistentHpyHandle = @ptrCast(@alignCast(handle_ptr orelse return));
    const op = obj_ptr orelse {
        setHpyError("geçersiz nesne", .{});
        return;
    };
    const an = attr_name orelse return;
    const ctx = handle.ctx;
    const obj_h: hpy_bridge.context.HPy = .{ ._i = @bitCast(@intFromPtr(op)) };
    const h_val = ctx.ctx_Long_FromInt64_t.?(ctx, value);
    defer ctx.ctx_Close.?(ctx, h_val);
    if (ctx.ctx_SetAttr_s.?(ctx, obj_h, an, h_val) < 0) {
        ctx.ctx_Err_Clear.?(ctx);
        setHpyError("'{s}' attribute'u ayarlanamadı", .{an});
    }
}

/// Faz 21: `mc.target_obj`nin (bir örnek tutamacı) `attr_name` adlı BAĞLI
/// METODUNU (`ctx_GetAttr_s`, `attrLookup`nin `.bound_method_` sarmalaması
/// — bkz. context.zig) `mc.args`la `ctx_Call` İLE çağırıp SONUCU `int`
/// OLARAK unmarshal eder — Box'ın `identity()`si GİBİ `HPyFunc_NOARGS`
/// tip metodlarının Nox'tan ÇAĞRILABİLMESİNİ sağlar.
pub export fn nox_hpy_call_attr_int_finish(mc_ptr: ?*anyopaque, attr_name: ?[*:0]const u8) i64 {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return 0));
    defer freeMarshalCtx(mc);
    const an = attr_name orelse return 0;
    const ctx = mc.handle.ctx;
    const target = mc.target_obj orelse return 0;
    const method_h = ctx.ctx_GetAttr_s.?(ctx, target, an);
    if (ctx.ctx_Err_Occurred.?(ctx) != 0) {
        ctx.ctx_Err_Clear.?(ctx);
        setHpyError("'{s}' bulunamadı", .{an});
        return 0;
    }
    defer ctx.ctx_Close.?(ctx, method_h);
    const n = mc.args.items.len;
    const packed_args = mc.allocator.alloc(hpy_bridge.context.HPy, n) catch {
        setHpyError("bellek yetersiz", .{});
        return 0;
    };
    defer mc.allocator.free(packed_args);
    for (mc.args.items, 0..) |e, i| packed_args[i] = e.h;
    const args_ptr: ?[*]const hpy_bridge.context.HPy = if (n > 0) packed_args.ptr else null;
    const h_result = ctx.ctx_Call.?(ctx, method_h, args_ptr, n, hpy_bridge.context.HPy_NULL);
    if (ctx.ctx_Err_Occurred.?(ctx) != 0) {
        ctx.ctx_Close.?(ctx, h_result);
        ctx.ctx_Err_Clear.?(ctx);
        setHpyError("'{s}' bir istisna fırlattı", .{an});
        return 0;
    }
    defer ctx.ctx_Close.?(ctx, h_result);
    return ctx.ctx_Long_AsInt64_t.?(ctx, h_result);
}

/// Faz 22 (bkz. plan dosyası "bare attribute-nesnesi + gerçek slice tipi
/// + numpy-tarzı skaler-broadcast slice ataması"): `context.createModuleObject`i
/// (Faz 20) YENİDEN KULLANIR — boş, TİPSİZ bir `.instance_` örneği (attribute'ları
/// SONRADAN `hpy_setattr_int_on` İLE EKLENEBİLİR). `hpy_new_object_on`,
/// aHPy'nin `external_nogil_targets`inin `obj.amount`/`obj.value` GİBİ
/// SADECE attribute'lu (subscript İSTEMEYEN) bir "target" argümanı
/// beklediği durumlar İçİndir.
pub export fn nox_hpy_new_object(handle_ptr: ?*anyopaque) ?*anyopaque {
    const handle: *PersistentHpyHandle = @ptrCast(@alignCast(handle_ptr orelse return null));
    const h = hpy_bridge.context.createModuleObject(handle.ctx) catch {
        setHpyError("bellek yetersiz", .{});
        return null;
    };
    const raw: usize = @bitCast(h._i);
    if (raw == 0) return null;
    return @ptrFromInt(raw);
}

/// Faz 22: `container`in (bir opak `.list_`/`.tuple_` tutamacı — ör.
/// `hpy_call_obj_on`dan alınmış bir dönüş değeri) `index`teki elemanını
/// `ctx_GetItem_i` İLE OKUYUP `int` OLARAK unmarshal eder.
pub export fn nox_hpy_getitem_int(handle_ptr: ?*anyopaque, container_ptr: ?*anyopaque, index: i64) i64 {
    const handle: *PersistentHpyHandle = @ptrCast(@alignCast(handle_ptr orelse return 0));
    const op = container_ptr orelse {
        setHpyError("geçersiz nesne", .{});
        return 0;
    };
    const ctx = handle.ctx;
    const container_h: hpy_bridge.context.HPy = .{ ._i = @bitCast(@intFromPtr(op)) };
    const h_result = ctx.ctx_GetItem_i.?(ctx, container_h, @intCast(index));
    if (ctx.ctx_Err_Occurred.?(ctx) != 0) {
        ctx.ctx_Err_Clear.?(ctx);
        setHpyError("indeks {d} okunamadı", .{index});
        return 0;
    }
    defer ctx.ctx_Close.?(ctx, h_result);
    return ctx.ctx_Long_AsInt64_t.?(ctx, h_result);
}

/// Faz 24 (bkz. plan dosyası "bellek-içi file-like writer/reader
/// nesneleri"): boş bir `.io_writer_` (`context.createStringWriter`)
/// İNŞA EDER — GERÇEK bir `.write(str) -> int`-çağrılabilir attribute'a
/// sahip, bellek-İçİ bir "dosya" nesnesi (`ujson_hpy`nin `dump()`u GİBİ
/// file-like bir nesne BEKLEYEN HPy fonksiyonlarına argüman olarak
/// GEÇİLEBİLİR — Faz 19'un `.ptr` argüman marshalanabilirliği SAYESİNDE).
pub export fn nox_hpy_new_string_writer(handle_ptr: ?*anyopaque) ?*anyopaque {
    const handle: *PersistentHpyHandle = @ptrCast(@alignCast(handle_ptr orelse return null));
    const h = hpy_bridge.context.createStringWriter(handle.ctx) catch {
        setHpyError("bellek yetersiz", .{});
        return null;
    };
    const raw: usize = @bitCast(h._i);
    if (raw == 0) return null;
    return @ptrFromInt(raw);
}

/// Faz 24: `writer_ptr`nin (`nox_hpy_new_string_writer`den alınmış bir
/// tutamaç) BİRİKMİŞ İÇERİĞİNİ (TÜM `.write()` çağrılarının birleşimi)
/// GERÇEK bir Nox `str`i OLARAK döner — `context.getStringWriterContent`
/// `ctx`e HİÇ İHTİYAÇ DUYMADAN (Obj erişimi tag/işaretçi-tabanlı) çalışır.
pub export fn nox_hpy_writer_get_str(rt: ?*anyopaque, handle_ptr: ?*anyopaque, writer_ptr: ?*anyopaque) ?[*:0]u8 {
    if (handle_ptr == null) return str_mod.nox_str_from_bytes(rt, "");
    const wp = writer_ptr orelse return str_mod.nox_str_from_bytes(rt, "");
    const h: hpy_bridge.context.HPy = .{ ._i = @bitCast(@intFromPtr(wp)) };
    const slice = hpy_bridge.context.getStringWriterContent(h) orelse "";
    return str_mod.nox_str_from_bytes(rt, slice);
}

/// Faz 24: `content`in (bir Nox `str`i) SAHİPLENİLEN bir kopyasıyla YENİ
/// bir `.io_reader_` (`context.createStringReader`) İNŞA EDER — GERÇEK
/// bir `.read() -> str`-çağrılabilir attribute'a sahip, bellek-İçİ bir
/// "dosya" nesnesi (`ujson_hpy`nin `load()`u GİBİ file-like bir nesne
/// BEKLEYEN HPy fonksiyonlarına argüman olarak GEÇİLEBİLİR).
pub export fn nox_hpy_new_string_reader(handle_ptr: ?*anyopaque, content: ?[*:0]const u8) ?*anyopaque {
    const handle: *PersistentHpyHandle = @ptrCast(@alignCast(handle_ptr orelse return null));
    const slice = str_mod.nox_str_slice(content orelse "");
    const h = hpy_bridge.context.createStringReader(handle.ctx, slice) catch {
        setHpyError("bellek yetersiz", .{});
        return null;
    };
    const raw: usize = @bitCast(h._i);
    if (raw == 0) return null;
    return @ptrFromInt(raw);
}

/// `path`teki `.wasm` ikilisini yükler, `func_name` adlı (yalnızca `i32`
/// parametre/dönüşlü) export'u `arg` ile çağırıp sonucu döner.
pub export fn nox_wasm_call(
    rt: ?*anyopaque,
    path: ?[*:0]const u8,
    func_name: ?[*:0]const u8,
    arg: i64,
) i64 {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return 0));
    const allocator = state.allocator();
    const p = path orelse return 0;
    const fnm = func_name orelse return 0;

    const bytes = readFileAll(allocator, p) catch return 0;
    defer allocator.free(bytes);

    var mod = wasm_bridge.module.parse(allocator, bytes) catch return 0;
    defer mod.deinit();

    const func_index = mod.findExportedFunc(std.mem.span(fnm)) orelse return 0;
    const arg32: i32 = @truncate(arg);
    const result = wasm_bridge.interp.callFunc(allocator, &mod, func_index, &.{arg32}) catch return 0;
    return result orelse 0;
}
