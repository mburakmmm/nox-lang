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
