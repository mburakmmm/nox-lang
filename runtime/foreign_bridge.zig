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

    var mod = hpy_bridge.loader.load(std.mem.span(p), std.mem.span(en)) catch return 0;
    defer mod.deinit();

    const method = mod.findMethodO(std.mem.span(fnm)) orelse return 0;

    const ctx = hpy_bridge.context.createContext(allocator) catch return 0;
    defer hpy_bridge.context.destroyContext(allocator, ctx);

    const h_arg = ctx.ctx_Long_FromInt64_t.?(ctx, arg);
    defer ctx.ctx_Close.?(ctx, h_arg);
    const h_result = method(ctx, hpy_bridge.context.HPy_NULL, h_arg);
    defer ctx.ctx_Close.?(ctx, h_result);
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

    var mod = hpy_bridge.loader.load(std.mem.span(p), std.mem.span(en)) catch return str_mod.nox_str_from_bytes(rt, "");
    defer mod.deinit();

    const method = mod.findMethodKeywords(std.mem.span(fnm)) orelse return str_mod.nox_str_from_bytes(rt, "");

    const ctx = hpy_bridge.context.createContext(allocator) catch return str_mod.nox_str_from_bytes(rt, "");
    defer hpy_bridge.context.destroyContext(allocator, ctx);

    const arg_slice = str_mod.nox_str_slice(arg_h);
    const arg_z = allocator.dupeZ(u8, arg_slice) catch return str_mod.nox_str_from_bytes(rt, "");
    defer allocator.free(arg_z);
    const h_arg = ctx.ctx_Unicode_FromString.?(ctx, arg_z);
    defer ctx.ctx_Close.?(ctx, h_arg);

    const args = [_]hpy_bridge.context.HPy{h_arg};
    const h_result = method(ctx, hpy_bridge.context.HPy_NULL, &args, 1, hpy_bridge.context.HPy_NULL);
    defer ctx.ctx_Close.?(ctx, h_result);

    if (ctx.ctx_Err_Occurred.?(ctx) != 0) {
        ctx.ctx_Err_Clear.?(ctx);
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
};

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

    var mod = hpy_bridge.loader.load(std.mem.span(p), std.mem.span(en)) catch return null;
    const ctx = hpy_bridge.context.createContext(allocator) catch {
        mod.deinit();
        return null;
    };
    const handle = allocator.create(PersistentHpyHandle) catch {
        hpy_bridge.context.destroyContext(allocator, ctx);
        mod.deinit();
        return null;
    };
    handle.* = .{ .mod = mod, .ctx = ctx };
    return handle;
}

/// `handle`nin context'ini yok eder, kütüphaneyi kapatır, tutamaç
/// struct'ının KENDİSİNİ serbest bırakır. `handle_ptr == null` İSE (ör.
/// `hpy_open` BAŞARISIZ olduysa) SESSİZCE hiçbir şey yapmaz.
pub export fn nox_hpy_close(rt: ?*anyopaque, handle_ptr: ?*anyopaque) void {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return));
    const allocator = state.allocator();
    const handle: *PersistentHpyHandle = @ptrCast(@alignCast(handle_ptr orelse return));
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
const MarshalCtx = struct {
    handle: *PersistentHpyHandle,
    allocator: std.mem.Allocator,
    args: std.ArrayListUnmanaged(hpy_bridge.context.HPy) = .empty,
    /// Bir `class` argümanı alan-alan İNŞA EDİLİRKEN kullanılan GEÇİCİ
    /// "şu an inşa edilen dict" — sınıf alanları İÇ İÇE OLAMAYACAĞINDAN
    /// (checker reddeder) AYNI ANDA SADECE TEK bir class-dict'in inşa
    /// halinde olması GARANTİdir.
    current_class_dict: ?hpy_bridge.context.HPy = null,
};

fn freeMarshalCtx(mc: *MarshalCtx) void {
    const ctx = mc.handle.ctx;
    for (mc.args.items) |h| ctx.ctx_Close.?(ctx, h);
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
    const handle: *PersistentHpyHandle = @ptrCast(@alignCast(handle_ptr orelse return null));
    const mc = allocator.create(MarshalCtx) catch return null;
    mc.* = .{ .handle = handle, .allocator = allocator };
    return mc;
}

pub export fn nox_hpy_args_add_int(mc_ptr: ?*anyopaque, value: i64) void {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return));
    const ctx = mc.handle.ctx;
    const h = ctx.ctx_Long_FromInt64_t.?(ctx, value);
    mc.args.append(mc.allocator, h) catch ctx.ctx_Close.?(ctx, h);
}

pub export fn nox_hpy_args_add_float(mc_ptr: ?*anyopaque, value: f64) void {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return));
    const ctx = mc.handle.ctx;
    const h = ctx.ctx_Float_FromDouble.?(ctx, value);
    mc.args.append(mc.allocator, h) catch ctx.ctx_Close.?(ctx, h);
}

pub export fn nox_hpy_args_add_bool(mc_ptr: ?*anyopaque, value: i32) void {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return));
    const ctx = mc.handle.ctx;
    const h = ctx.ctx_Bool_FromBool.?(ctx, value != 0);
    mc.args.append(mc.allocator, h) catch ctx.ctx_Close.?(ctx, h);
}

pub export fn nox_hpy_args_add_str(mc_ptr: ?*anyopaque, value: ?[*:0]const u8) void {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return));
    const ctx = mc.handle.ctx;
    const v = value orelse "";
    const s = str_mod.nox_str_slice(v);
    const z = mc.allocator.dupeZ(u8, s) catch return;
    defer mc.allocator.free(z);
    const h = ctx.ctx_Unicode_FromString.?(ctx, z);
    mc.args.append(mc.allocator, h) catch ctx.ctx_Close.?(ctx, h);
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
        mc.args.append(mc.allocator, h_list) catch ctx.ctx_Close.?(ctx, h_list);
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
    mc.args.append(mc.allocator, h_list) catch ctx.ctx_Close.?(ctx, h_list);
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
        mc.args.append(mc.allocator, h_dict) catch ctx.ctx_Close.?(ctx, h_dict);
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
    mc.args.append(mc.allocator, h_dict) catch ctx.ctx_Close.?(ctx, h_dict);
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
    mc.args.append(mc.allocator, dict_h) catch ctx.ctx_Close.?(ctx, dict_h);
}

/// `mc.args`i `func_name` adlı metoda geçirip GERÇEK çağrıyı yapar —
/// ÖNCE `HPyFunc_KEYWORDS` imzasını dener (`nargs = mc.args.items.len`,
/// `nargs == 0` İçin `args = null`, GEÇERLİ bir çağrı biçimi); BULUNAMAZSA
/// (ör. Faz 16'nın `get_call_count`/`add_one` GİBİ ESKİ, `HPyFunc_O`
/// imzalı test fonksiyonları — GERİYE DÖNÜK uyumluluk İçİn) VE TAM
/// OLARAK 1 argüman VARSA `HPyFunc_O` imzasına DÜŞER. HİÇBİRİ
/// BULUNAMAZSA `null` döner (çağıran `0`/`0.0`/boş `str` İLE karşılar).
fn invokeHpyMethod(mc: *MarshalCtx, func_name: []const u8) ?hpy_bridge.context.HPy {
    const ctx = mc.handle.ctx;
    if (mc.handle.mod.findMethodKeywords(func_name)) |method| {
        const args_ptr: ?[*]const hpy_bridge.context.HPy = if (mc.args.items.len > 0) mc.args.items.ptr else null;
        return method(ctx, hpy_bridge.context.HPy_NULL, args_ptr, mc.args.items.len, hpy_bridge.context.HPy_NULL);
    }
    if (mc.args.items.len == 1) {
        if (mc.handle.mod.findMethodO(func_name)) |method| {
            return method(ctx, hpy_bridge.context.HPy_NULL, mc.args.items[0]);
        }
    }
    return null;
}

/// `func_name` adlı metodu `mc.args`la çağırıp `int` sonucu unmarshal
/// eder, `mc`yi TAMAMEN serbest bırakır. `hpy_call_on`nin ESKİ (Faz 16,
/// TEK-`int`-argümanlı) davranışıyla `Err_Occurred` KONTROLÜ AÇISINDAN
/// TUTARLI — KONTROL ETMEZ (istisna entegrasyonu Faz 18'in işi).
pub export fn nox_hpy_call_int_finish(mc_ptr: ?*anyopaque, func_name: ?[*:0]const u8) i64 {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return 0));
    defer freeMarshalCtx(mc);
    const fnm = func_name orelse return 0;
    const ctx = mc.handle.ctx;
    const h_result = invokeHpyMethod(mc, std.mem.span(fnm)) orelse return 0;
    defer ctx.ctx_Close.?(ctx, h_result);
    return ctx.ctx_Long_AsInt64_t.?(ctx, h_result);
}

/// `nox_hpy_call_int_finish`nin AYNISI, `float` dönüşle.
pub export fn nox_hpy_call_float_finish(mc_ptr: ?*anyopaque, func_name: ?[*:0]const u8) f64 {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return 0));
    defer freeMarshalCtx(mc);
    const fnm = func_name orelse return 0;
    const ctx = mc.handle.ctx;
    const h_result = invokeHpyMethod(mc, std.mem.span(fnm)) orelse return 0;
    defer ctx.ctx_Close.?(ctx, h_result);
    return ctx.ctx_Float_AsDouble.?(ctx, h_result);
}

/// `nox_hpy_call_int_finish`nin AYNISI, `bool` (0/1) dönüşle — genel
/// `ctx_IsTrue` (truthiness) İLE unmarshal eder.
pub export fn nox_hpy_call_bool_finish(mc_ptr: ?*anyopaque, func_name: ?[*:0]const u8) i32 {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return 0));
    defer freeMarshalCtx(mc);
    const fnm = func_name orelse return 0;
    const ctx = mc.handle.ctx;
    const h_result = invokeHpyMethod(mc, std.mem.span(fnm)) orelse return 0;
    defer ctx.ctx_Close.?(ctx, h_result);
    return if (ctx.ctx_IsTrue.?(ctx, h_result) != 0) 1 else 0;
}

/// `nox_hpy_call_str_on`nin ESKİ (Faz 16, TEK-`str`-argümanlı) davranışıyla
/// TUTARLI — `Err_Occurred` KONTROL EDİLİR (o davranış BURADA KORUNUR).
pub export fn nox_hpy_call_str_finish(rt: ?*anyopaque, mc_ptr: ?*anyopaque, func_name: ?[*:0]const u8) ?[*:0]u8 {
    const mc: *MarshalCtx = @ptrCast(@alignCast(mc_ptr orelse return null));
    defer freeMarshalCtx(mc);
    const fnm = func_name orelse return str_mod.nox_str_from_bytes(rt, "");
    const ctx = mc.handle.ctx;
    const h_result = invokeHpyMethod(mc, std.mem.span(fnm)) orelse return str_mod.nox_str_from_bytes(rt, "");
    defer ctx.ctx_Close.?(ctx, h_result);
    if (ctx.ctx_Err_Occurred.?(ctx) != 0) {
        ctx.ctx_Err_Clear.?(ctx);
        return str_mod.nox_str_from_bytes(rt, "");
    }
    var size: isize = 0;
    const result_str = ctx.ctx_Unicode_AsUTF8AndSize.?(ctx, h_result, &size) orelse return str_mod.nox_str_from_bytes(rt, "");
    return str_mod.nox_str_from_bytes(rt, result_str[0..@intCast(size)]);
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
