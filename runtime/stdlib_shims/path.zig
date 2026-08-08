//! `nox.path` Zig kabuğu — Faz EE.1 (bkz. nox-teknik-spesifikasyon.md
//! §3.61). SAF string manipülasyonu — HİÇBİR I/O YAPMAZ (bkz. `nox.fs`,
//! dosya sistemiyle etkileşen sorgular İçin, ör. `exists`/`is_file`).
//! `std.fs.path.*`i DOĞRUDAN sarar; HİÇBİR fonksiyon "başarısız" olamaz
//! (saf string işlemleri), bu yüzden `.nox` tarafında `raise` YOLU YOKTUR.

const std = @import("std");
const builtin = @import("builtin");
const arc = @import("../alloc/arc.zig");
const http_client = @import("http_client.zig");
const str_mod = @import("../str.zig");
const abi_layout = @import("abi_layout");
const bridge = @import("../async_rt/bridge.zig");

const dupeToNoxStr = http_client.dupeToNoxStr;
/// Faz P1.2: bkz. `strings.zig`nin AYNI re-export notu.
const LIST_HEADER_SIZE = abi_layout.LIST_HEADER_SIZE;
const FIELD_SLOT_SIZE = abi_layout.FIELD_SLOT_SIZE;
const STR_HEADER_SIZE = abi_layout.STR_HEADER_SIZE;

/// Faz II devamı (bkz. nox-teknik-spesifikasyon.md §3.67) — `join`nin
/// ÖNCEKİ uygulaması `std.fs.path.join`i `std.heap.page_allocator` İLE
/// çağırıp SONRA `dupeToNoxStr` İLE İKİNCİ bir kopya çıkarıyordu (ÇAĞRI
/// başına 2 tahsis, biri SAYFA-granülerlikli bir "genel amaçlı" ayırıcı
/// üzerinden). Bir Rust `std::path::Path` karşılaştırması (`benchmarks/
/// path_bench`) bunun ~9.4-9.9x YAVAŞ olduğunu ORTAYA ÇIKARDI — düzeltildi
/// (`arc.nox_rc_alloc`a doğrudan tek tahsis).
///
/// **Faz OO.5 — REGRESYON bulundu VE düzeltildi (bkz. nox-teknik-
/// spesifikasyon.md §3.86):** `str`e uzunluk alanı + ASCII bayrağı
/// eklendiğinde (bkz. plan dosyası) BU fonksiyon `page_allocator`
/// temp-arabelleğine GERİ DÖNDÜRÜLMÜŞTÜ (yanlış gerekçeyle: "paketlenmiş
/// başlık İçin yer AYRILMAZ" — ama `total_len` `nox_str_concat`taki (bkz.
/// `runtime/str.zig`) İLE AYNI şekilde ÇAĞRIDAN ÖNCE zaten TAM olarak
/// BİLİNİYOR, bu YÜZDEN başlık İçin yer AYIRMAK hiç ZOR DEĞİLDİ) —
/// düzeltme `nox_str_concat`nin AYNI deseni: `STR_HEADER_SIZE + total_len
/// + 1` tek `arc.nox_rc_alloc`, paketli başlık DOĞRUDAN yazılır, İKİ
/// parça (+ gereken ayraç) DOĞRUDAN `data`ya kopyalanır — ARA
/// (`page_allocator`) tampon YOK. ASCII durumu BİLİNÇLİ OLARAK
/// `STR_ASCII_UNKNOWN` (ESKİ `dupeToNoxStr`/`nox_str_from_bytes` yolunun
/// DAVRANIŞIYLA BİREBİR AYNI — saf bir perf düzeltmesi, davranış
/// DEĞİŞMEDİ).
///
/// Ayırıcı-arasındaki ayraç ÇAKIŞMASI/EKSİKLİĞİ kuralı (`a` SONU VE `b`
/// BAŞI ikisi de ayraçsa TEKİ ATLA, ikisi de DEĞİLSE BİR ayraç EKLE)
/// `std.fs.path.joinSepMaybeZ` İLE BİREBİR AYNIDIR (bkz. Zig std kaynağı) —
/// yalnızca `..`/`.` NORMALİZASYONU YAPILMAZ, ki ZATEN ESKİ `std.fs.path.
/// join` de YAPMIYORDU (davranış DEĞİŞMEDİ, yalnızca tahsis stratejisi).
export fn nox_path_join_raw(rt: ?*anyopaque, a: ?[*:0]const u8, b: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const a_slice = str_mod.nox_str_slice(a orelse return null);
    const b_slice = str_mod.nox_str_slice(b orelse return null);

    if (a_slice.len == 0) return dupeToNoxStr(rt, b_slice);
    if (b_slice.len == 0) return dupeToNoxStr(rt, a_slice);

    const a_ends_sep = std.fs.path.isSep(a_slice[a_slice.len - 1]);
    const b_starts_sep = std.fs.path.isSep(b_slice[0]);
    const need_sep = !a_ends_sep and !b_starts_sep;
    const b_adjusted = if (a_ends_sep and b_starts_sep) b_slice[1..] else b_slice;

    const total_len = a_slice.len + @as(usize, if (need_sep) 1 else 0) + b_adjusted.len;
    const raw = arc.nox_rc_alloc(rt, STR_HEADER_SIZE + total_len + 1) orelse return null;
    const base: [*]u8 = @ptrCast(raw);
    const header: *align(1) i64 = @ptrCast(base);
    header.* = abi_layout.packStrHeader(total_len, abi_layout.STR_ASCII_UNKNOWN);
    const data = base + STR_HEADER_SIZE;
    @memcpy(data[0..a_slice.len], a_slice);
    var off: usize = a_slice.len;
    if (need_sep) {
        data[off] = std.fs.path.sep;
        off += 1;
    }
    @memcpy(data[off..][0..b_adjusted.len], b_adjusted);
    off += b_adjusted.len;
    data[off] = 0;
    return @ptrCast(data);
}

export fn nox_path_basename_raw(rt: ?*anyopaque, p: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const slice = str_mod.nox_str_slice(p orelse return null);
    return dupeToNoxStr(rt, std.fs.path.basename(slice));
}

/// `std.fs.path.dirname` bir üst dizin YOKSA (ör. `"foo.txt"`) `null`
/// döner — Nox `str`ın nullable bir karşılığı OLMADIĞINDAN bu durumda boş
/// dize (`""`) döndürülür (belgelenen, kasıtlı bir varsayılan).
export fn nox_path_dirname_raw(rt: ?*anyopaque, p: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const slice = str_mod.nox_str_slice(p orelse return null);
    const d = std.fs.path.dirname(slice) orelse "";
    return dupeToNoxStr(rt, d);
}

export fn nox_path_extension_raw(rt: ?*anyopaque, p: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const slice = str_mod.nox_str_slice(p orelse return null);
    return dupeToNoxStr(rt, std.fs.path.extension(slice));
}

/// Diğer "sonuç" extern'lerin (`nox_fs_last_op_ok` vb.) AYNI kuralı —
/// `bool` YERİNE `int` (0/1) döner, `.nox` sarmalayıcısı `!= 0` İLE
/// `bool`a çevirir (bu projede DAHA ÖNCE `-> bool` dönüşü test edilmiş bir
/// yol DEĞİL, `-> int` İSE HER YERDE KANITLANMIŞ).
export fn nox_path_is_absolute_raw(p: ?[*:0]const u8) callconv(.c) i32 {
    const slice = str_mod.nox_str_slice(p orelse return 0);
    return if (std.fs.path.isAbsolute(slice)) 1 else 0;
}

// Faz III.4 (bkz. nox-teknik-spesifikasyon.md §3.69) — `canonicalize`
// (yalnızca modül İÇİNDE) GERÇEKTEN I/O YAPAR (`realpath(3)`, sembolik
// linkleri ÇÖZMEK İçin dosyanın VAR OLMASI GEREKİR) — bu modülün üstündeki
// "hiç I/O yok" ilkesinin BİLİNÇLİ, TEK istisnası. Bu YÜZDEN `nox.fs` İLE
// AYNI "ham çağrı + AYRI durum sorgusu" desenine (`PathError`) ihtiyaç
// duyan TEK fonksiyon budur.
/// Faz MN.2: bkz. `fiber.zig`nin belge notu — fiber İÇİNDE `Fiber.
/// path_last_ok`e, DIŞINDA (senkron üst-düzey kod) BU yedeğe düşer.
threadlocal var g_last_ok_fallback: bool = true;

fn pathLastOkPtr() *bool {
    if (bridge.currentFiber()) |f| return &f.path_last_ok;
    return &g_last_ok_fallback;
}

export fn nox_path_last_op_ok() callconv(.c) i32 {
    return if (pathLastOkPtr().*) 1 else 0;
}

/// Faz LL.6 (bkz. nox-teknik-spesifikasyon.md §3.71): `std.c.realpath`
/// MinGW'de (GERÇEK Windows CI'de doğrulanan bir `undefined reference`
/// hatasıyla) BAĞLAYICI SEVİYESİNDE MEVCUT DEĞİL — `O`/`Stat`/`readdir`/
/// `clockid_t`/`F`/`RTLD` GİBİ "unutulmuş case" DEĞİL, tam bir sembol
/// eksikliği. Windows karşılığı `GetFullPathNameA` (Win32) — **bilinçli
/// v1 farkı:** `realpath(3)`in AKSİNE sembolik LİNKLERİ ÇÖZMEZ, yalnızca
/// `.`/`..`yi normalize edip MUTLAK yola çevirir (Windows'ta sembolik
/// link kullanımı ZATEN NADİR VE ek yönetici izni GEREKTİRİR — bu proje
/// İçin YETERLİ bir yaklaşım).
const WinPath = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn GetFullPathNameA(lpFileName: [*:0]const u8, nBufferLength: u32, lpBuffer: [*]u8, lpFilePart: ?*?[*:0]u8) callconv(.c) u32;
} else struct {};

export fn nox_path_canonicalize_raw(rt: ?*anyopaque, p: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const path = p orelse {
        pathLastOkPtr().* = false;
        return dupeToNoxStr(rt, "");
    };
    if (builtin.os.tag == .windows) {
        var buf: [std.c.PATH_MAX]u8 = undefined;
        const len = WinPath.GetFullPathNameA(path, buf.len, &buf, null);
        if (len == 0 or len >= buf.len) {
            pathLastOkPtr().* = false;
            return dupeToNoxStr(rt, "");
        }
        pathLastOkPtr().* = true;
        return dupeToNoxStr(rt, buf[0..len]);
    }
    var buf: [std.c.PATH_MAX]u8 = undefined;
    const resolved = std.c.realpath(path, &buf) orelse {
        pathLastOkPtr().* = false;
        return dupeToNoxStr(rt, "");
    };
    pathLastOkPtr().* = true;
    return dupeToNoxStr(rt, std.mem.span(resolved));
}

/// Faz III.4 — `path` `prefix` İLE BAŞLIYORSA prefix'i (ve HEMEN ARDINDAN
/// gelen TEK bir ayracı, VARSA) ÇIKARIP kalanı döner. Rust'ın `Path::
/// strip_prefix`inin AKSİNE (bir `Result` döner) BAŞLAMAZSA `path`i
/// DEĞİŞMEDEN döner — bilinçli v1 basitleştirmesi (`nox.path`nin "hiç
/// I/O yok, hiç raise yok" ilkesiyle TUTARLI, bkz. modül-üstü not).
export fn nox_path_strip_prefix_raw(rt: ?*anyopaque, p: ?[*:0]const u8, prefix: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const slice = str_mod.nox_str_slice(p orelse return null);
    const pre = str_mod.nox_str_slice(prefix orelse return null);
    if (!std.mem.startsWith(u8, slice, pre)) return dupeToNoxStr(rt, slice);
    var rest = slice[pre.len..];
    if (rest.len > 0 and std.fs.path.isSep(rest[0])) rest = rest[1..];
    return dupeToNoxStr(rt, rest);
}

/// Faz III.4 — yol BİLEŞENLERİNİ (`list[str]`, `nox_strings_split_raw`nin
/// AYNI 8-bayt-uzunluk+8-bayt-kapasite+işaretçi başlık düzeni) sırayla
/// döner. `std.fs.path.componentIterator` SAF bir string ayrıştırıcıdır
/// (I/O GEREKMEZ).
export fn nox_path_components_raw(rt: ?*anyopaque, p: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    const slice = str_mod.nox_str_slice(p orelse return null);

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(std.heap.page_allocator);
    var it = std.fs.path.componentIterator(slice);
    while (it.next()) |comp| {
        names.append(std.heap.page_allocator, comp.name) catch return null;
    }

    const raw = arc.nox_rc_alloc(rt, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * names.items.len) orelse return null;
    const bytes: [*]u8 = @ptrCast(raw);
    @as(*align(1) i64, @ptrCast(bytes)).* = @intCast(names.items.len);
    @as(*align(1) i64, @ptrCast(bytes + 8)).* = @intCast(names.items.len);
    for (names.items, 0..) |name, i| {
        const dup = dupeToNoxStr(rt, name) orelse return null;
        const slot = bytes + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i;
        @as(*align(1) i64, @ptrCast(slot)).* = @bitCast(@as(isize, @intCast(@intFromPtr(dup))));
    }
    return @ptrCast(bytes);
}

// `nox_path_*_raw` (DIŞA açılan C-ABI sarmalayıcıları) `str_mod.nox_str_
// slice`i ÇAĞIRIYOR — GEÇERLİ bir Nox `str` başlığı (ARC+STR_HEADER) BEKLER.
// Çıplak Zig string LİTERALLERİNİ DOĞRUDAN bu fonksiyonlara geçirmek
// `regex.zig`nin AYNI belge notunda UYARDIĞI tuzak — bu yüzden AŞAĞIDAKİ
// TÜM testler `makeTestStr` İLE GERÇEK başlıklı `str`ler İNŞA EDER.
fn makeTestStr(rt: ?*anyopaque, bytes: []const u8) [*:0]u8 {
    return str_mod.nox_str_from_bytes(rt, bytes) orelse unreachable;
}

test "nox_path_join_raw iki parcayi dogru birlestirir" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const a_b = makeTestStr(rt, "a/b");
    defer str.nox_str_release(rt, a_b);
    const c_txt = makeTestStr(rt, "c.txt");
    defer str.nox_str_release(rt, c_txt);
    const j = nox_path_join_raw(rt, a_b, c_txt) orelse return error.Failed;
    defer str.nox_str_release(rt, j);
    try std.testing.expectEqualStrings("a/b/c.txt", std.mem.sliceTo(j, 0));

    // Faz II devamı — `join`in EL İLE yazılan uzunluk-hesabının/ayraç-
    // çakışması mantığının `std.fs.path.joinSepMaybeZ` İLE AYNI davrandığını
    // doğrulayan kenar durumları.
    const a_slash = makeTestStr(rt, "a/");
    defer str.nox_str_release(rt, a_slash);
    const slash_b = makeTestStr(rt, "/b");
    defer str.nox_str_release(rt, slash_b);
    const j2 = nox_path_join_raw(rt, a_slash, slash_b) orelse return error.Failed;
    defer str.nox_str_release(rt, j2);
    try std.testing.expectEqualStrings("a/b", std.mem.sliceTo(j2, 0));

    const empty = makeTestStr(rt, "");
    defer str.nox_str_release(rt, empty);
    const b_only = makeTestStr(rt, "b");
    defer str.nox_str_release(rt, b_only);
    const j3 = nox_path_join_raw(rt, empty, b_only) orelse return error.Failed;
    defer str.nox_str_release(rt, j3);
    try std.testing.expectEqualStrings("b", std.mem.sliceTo(j3, 0));

    const a_only = makeTestStr(rt, "a");
    defer str.nox_str_release(rt, a_only);
    const j4 = nox_path_join_raw(rt, a_only, empty) orelse return error.Failed;
    defer str.nox_str_release(rt, j4);
    try std.testing.expectEqualStrings("a", std.mem.sliceTo(j4, 0));
}

test "nox_path_basename_raw/dirname/extension dogru calisir" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const abc_txt = makeTestStr(rt, "/a/b/c.txt");
    defer str.nox_str_release(rt, abc_txt);
    const c_txt = makeTestStr(rt, "c.txt");
    defer str.nox_str_release(rt, c_txt);

    const b = nox_path_basename_raw(rt, abc_txt) orelse return error.Failed;
    defer str.nox_str_release(rt, b);
    try std.testing.expectEqualStrings("c.txt", std.mem.sliceTo(b, 0));

    const d = nox_path_dirname_raw(rt, abc_txt) orelse return error.Failed;
    defer str.nox_str_release(rt, d);
    try std.testing.expectEqualStrings("/a/b", std.mem.sliceTo(d, 0));

    const d2 = nox_path_dirname_raw(rt, c_txt) orelse return error.Failed;
    defer str.nox_str_release(rt, d2);
    try std.testing.expectEqualStrings("", std.mem.sliceTo(d2, 0));

    const e = nox_path_extension_raw(rt, abc_txt) orelse return error.Failed;
    defer str.nox_str_release(rt, e);
    try std.testing.expectEqualStrings(".txt", std.mem.sliceTo(e, 0));
}

test "nox_path_is_absolute_raw mutlak/goreli yollari dogru ayirt eder" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const abs = makeTestStr(rt, "/a/b");
    defer str.nox_str_release(rt, abs);
    const rel = makeTestStr(rt, "a/b");
    defer str.nox_str_release(rt, rel);

    try std.testing.expectEqual(@as(i32, 1), nox_path_is_absolute_raw(abs));
    try std.testing.expectEqual(@as(i32, 0), nox_path_is_absolute_raw(rel));
}

test "Faz III.4: nox_path_canonicalize_raw sembolik link/./.. cozer, olmayan yolda basarisiz olur" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    // Not: macOS'ta `/tmp` KENDİSİ `/private/tmp`ye bir sembolik LİNKTİR —
    // bu YÜZDEN `/tmp/../tmp`nin TAM çözümü `/tmp` DEĞİL `/private/tmp`dir
    // (GERÇEKTEN çalıştırılıp DOĞRULANDI — `canonicalize`nin sembolik
    // linkleri de ÇÖZDÜĞÜNÜN kanıtı, hata DEĞİL). Linux'ta `/tmp` GERÇEK
    // bir dizindir (sembolik link DEĞİL) — bu YÜZDEN beklenen değer
    // GERÇEK CI'de bulunan bir platform farkıyla (bkz. nox-teknik-
    // spesifikasyon.md §3.71) platform-koşullu hale getirildi.
    const expected_tmp = if (builtin.os.tag == .macos) "/private/tmp" else "/tmp";
    const tmp_dotdot = makeTestStr(rt, "/tmp/../tmp");
    defer str.nox_str_release(rt, tmp_dotdot);
    const c = nox_path_canonicalize_raw(rt, tmp_dotdot) orelse return error.Failed;
    defer str.nox_str_release(rt, c);
    try std.testing.expectEqualStrings(expected_tmp, std.mem.sliceTo(c, 0));
    try std.testing.expect(pathLastOkPtr().*);

    const missing_path = makeTestStr(rt, "/definitely/does/not/exist/nox_iii4_test");
    defer str.nox_str_release(rt, missing_path);
    const missing = nox_path_canonicalize_raw(rt, missing_path) orelse return error.Failed;
    defer str.nox_str_release(rt, missing);
    try std.testing.expect(!pathLastOkPtr().*);
}

test "Faz III.4: nox_path_strip_prefix_raw onek eslesirse cikarir, eslesmezse degismeden doner" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const abc_txt = makeTestStr(rt, "/a/b/c.txt");
    defer str.nox_str_release(rt, abc_txt);
    const ab_pre = makeTestStr(rt, "/a/b");
    defer str.nox_str_release(rt, ab_pre);
    const xy_pre = makeTestStr(rt, "/x/y");
    defer str.nox_str_release(rt, xy_pre);

    const s1 = nox_path_strip_prefix_raw(rt, abc_txt, ab_pre) orelse return error.Failed;
    defer str.nox_str_release(rt, s1);
    try std.testing.expectEqualStrings("c.txt", std.mem.sliceTo(s1, 0));

    const s2 = nox_path_strip_prefix_raw(rt, abc_txt, xy_pre) orelse return error.Failed;
    defer str.nox_str_release(rt, s2);
    try std.testing.expectEqualStrings("/a/b/c.txt", std.mem.sliceTo(s2, 0));
}

test "Faz III.4: nox_path_components_raw yol bilesenlerini dogru sirada doner" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const abc_txt = makeTestStr(rt, "/a/b/c.txt");
    defer str.nox_str_release(rt, abc_txt);
    const list_ptr = nox_path_components_raw(rt, abc_txt) orelse return error.Failed;
    const bytes: [*]u8 = @ptrCast(list_ptr);
    const count: usize = @intCast(@as(*align(1) i64, @ptrCast(bytes)).*);
    try std.testing.expectEqual(@as(usize, 3), count);

    const expected = [_][]const u8{ "a", "b", "c.txt" };
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const addr: usize = @bitCast(@as(*align(1) i64, @ptrCast(bytes + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i)).*);
        const p: [*:0]u8 = @ptrFromInt(addr);
        defer str.nox_str_release(rt, p);
        try std.testing.expectEqualStrings(expected[i], std.mem.sliceTo(p, 0));
    }
    arc.nox_rc_release(rt, list_ptr, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * count);
}
