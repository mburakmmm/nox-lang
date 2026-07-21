//! `nox.os` Zig kabuğu — stdlib fazı §J (bkz. nox-teknik-spesifikasyon.md).
//!
//! `argc`/`argv` yakalama: `main.zig`nin QBE-üretilmiş `$main`i ŞİMDİYE
//! KADAR HİÇ parametre almıyordu (`export function w $main() {`) — Nox'un
//! bunları YAKALAMASININ TEK yolu, `$main`in imzasını GERÇEK C ABI'sine
//! (`int main(int argc, char **argv)`) UYGUN hâle getirip (bkz.
//! `codegen.zig`nin `genMain`/`genMainAsync`si) HER programın (nox.os HİÇ
//! import edilmese BİLE, basitlik İÇİN KOŞULSUZ) başlangıcında bu değerleri
//! BURADAKİ statik (süreç ömrü boyunca yaşayan) değişkenlere KAYDETMESİDİR
//! — `nox_os_init`, `$main`in İLK satırlarından biri olarak çağrılır.
//!
//! **Bilinçli v1 sınırlaması:** `nox_os_arg`in sınır dışı `i` İÇİN bir
//! istisna RAISE ETMEK YERİNE BOŞ bir `str` döndürmesi — `nox.os`/`nox.fs`
//! alt-fazının TASARIM kararı GEREĞİNCE (bkz. plan dosyası) HİÇBİR yeni
//! checker/codegen özel-durumu (Alt-Faz E/G'nin `genParseOrRaise`/
//! `genStrIndex`si GİBİ) GEREKTİRMEMESİ İÇİN — yalnızca `getenv`/dosya G/Ç
//! GİBİ GERÇEKTEN başarısız OLABİLEN işlemler (bkz. `stdlib/nox/os.nox`nin
//! KENDİSİ, sıradan `if`/`raise` İLE) istisna fırlatır.

const std = @import("std");
const builtin = @import("builtin");
const http_client = @import("http_client.zig");

const dupeToNoxStr = http_client.dupeToNoxStr;

var g_argc: i64 = 0;
var g_argv: ?[*]const ?[*:0]const u8 = null;

export fn nox_os_init(argc: i32, argv: ?[*]const ?[*:0]const u8) callconv(.c) void {
    g_argc = argc;
    g_argv = argv;
}

// NOT: dört fonksiyondan ÜÇÜ (`arg_count`/`arg`/`exit`) `_raw` SONEKİYLE
// biter — `stdlib/nox/os.nox`nin AYNI KISA adlı bir sarmalayıcıya SAHİP
// olması (`arg_count()`/`arg(i)`/`exit(code)`) YÜZÜNDEN ZORUNLU: `module_
// loader.zig`nin mangleWith'i sarmalayıcıyı "nox_os_arg_count" gibi
// MANGLE EDER — extern def'in KENDİSİ bu isme SAHİP OLSAYDI (`_raw` SONEKİ
// OLMADAN), checker'ın `registerExternFunc`ı BUNU "fonksiyon zaten
// tanımlı" olarak REDDEDERDİ (BU HATA GERÇEKTEN YAPILDI VE YAKALANDI —
// bkz. stdlib fazı §J'nin doğrulama notu). `getenv`in kendisi "nox_os_
// getenv_raw" İSMİNİ ZATEN TAŞIDIĞINDAN (sarmalayıcı "nox_os_getenv"e
// mangle EDİLİR, FARKLI bir dize) bu çakışma yoktu; `has_env`in KISA adlı
// bir sarmalayıcısı hiç OLMADIĞINDAN o da ÇAKIŞMAZ.
export fn nox_os_arg_count_raw() callconv(.c) i64 {
    return g_argc;
}

export fn nox_os_arg_raw(rt: ?*anyopaque, i: i64) callconv(.c) ?[*:0]u8 {
    if (i < 0 or i >= g_argc) return dupeToNoxStr(rt, "");
    const argv = g_argv orelse return dupeToNoxStr(rt, "");
    const arg = argv[@intCast(i)] orelse return dupeToNoxStr(rt, "");
    return dupeToNoxStr(rt, std.mem.span(arg));
}

export fn nox_os_has_env(name: ?[*:0]const u8) callconv(.c) i32 {
    const n = name orelse return 0;
    return if (std.c.getenv(n) != null) 1 else 0;
}

export fn nox_os_getenv_raw(rt: ?*anyopaque, name: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const n = name orelse return dupeToNoxStr(rt, "");
    const v = std.c.getenv(n) orelse return dupeToNoxStr(rt, "");
    return dupeToNoxStr(rt, std.mem.span(v));
}

export fn nox_os_exit_raw(code: i64) callconv(.c) noreturn {
    std.process.exit(@intCast(code));
}

// Faz III.5 (bkz. nox-teknik-spesifikasyon.md §3.69) — `setenv` bu Zig
// sürümünün `std.c`sinde YOK (`getenv`nin AKSİNE) — `runtime/foreign_
// bridge.zig`nin AYNI "std.c'de eksikse ham `extern \"c\" fn` bildir"
// deseniyle DOĞRUDAN bağlanır.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
/// Faz LL.4 (bkz. nox-teknik-spesifikasyon.md §3.71): Windows'un MinGW
/// CRT'si `setenv`i (POSIX) DEĞİL, `_putenv_s`i (ISO C uyumlu isimlendirme)
/// sağlar — imzası da farklıdır (`overwrite` bayrağı YOK, HER ZAMAN
/// üzerine yazar, `nox_os_set_var_raw`nin zaten VARSAYDIĞI davranışla
/// AYNI).
extern "c" fn _putenv_s(name: [*:0]const u8, value: [*:0]const u8) c_int;

export fn nox_os_set_var_raw(name: ?[*:0]const u8, value: ?[*:0]const u8) callconv(.c) void {
    const n = name orelse return;
    const v = value orelse return;
    if (builtin.os.tag == .windows) {
        _ = _putenv_s(n, v);
    } else {
        _ = setenv(n, v, 1);
    }
}

export fn nox_os_current_dir_raw(rt: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    var buf: [std.c.PATH_MAX]u8 = undefined;
    const result = std.c.getcwd(&buf, buf.len) orelse return dupeToNoxStr(rt, "");
    const z: [*:0]u8 = @ptrCast(result);
    return dupeToNoxStr(rt, std.mem.span(z));
}

test "Faz III.5: nox_os_set_var_raw ortam degiskenini gercekten ayarlar" {
    try std.testing.expectEqual(@as(i32, 0), nox_os_has_env("NOX_III5_TEST_VAR"));
    nox_os_set_var_raw("NOX_III5_TEST_VAR", "merhaba");
    try std.testing.expectEqual(@as(i32, 1), nox_os_has_env("NOX_III5_TEST_VAR"));

    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const v = nox_os_getenv_raw(rt, "NOX_III5_TEST_VAR") orelse return error.Failed;
    defer str.nox_str_release(rt, v);
    try std.testing.expectEqualStrings("merhaba", std.mem.sliceTo(v, 0));
}

test "Faz III.5: nox_os_current_dir_raw bos olmayan bir mutlak yol doner" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const cwd = nox_os_current_dir_raw(rt) orelse return error.Failed;
    defer str.nox_str_release(rt, cwd);
    const slice = std.mem.sliceTo(cwd, 0);
    try std.testing.expect(slice.len > 0);
    // Faz LL.4 (bkz. nox-teknik-spesifikasyon.md §3.71): Windows'ta mutlak
    // yollar `/` İLE DEĞİL bir sürücü harfiyle (`C:\...`) BAŞLAR.
    if (builtin.os.tag == .windows) {
        try std.testing.expect(slice.len >= 2 and slice[1] == ':');
    } else {
        try std.testing.expect(slice[0] == '/');
    }
}
