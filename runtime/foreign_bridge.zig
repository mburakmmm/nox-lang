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

const std = @import("std");
const asap = @import("alloc/asap.zig");
const hpy_bridge = @import("hpy_bridge");
const wasm_bridge = @import("wasm_bridge");
const str_mod = @import("str.zig");

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
