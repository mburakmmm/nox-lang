//! `nox.path` Zig kabuğu — Faz EE.1 (bkz. nox-teknik-spesifikasyon.md
//! §3.61). SAF string manipülasyonu — HİÇBİR I/O YAPMAZ (bkz. `nox.fs`,
//! dosya sistemiyle etkileşen sorgular İçin, ör. `exists`/`is_file`).
//! `std.fs.path.*`i DOĞRUDAN sarar; HİÇBİR fonksiyon "başarısız" olamaz
//! (saf string işlemleri), bu yüzden `.nox` tarafında `raise` YOLU YOKTUR.

const std = @import("std");
const builtin = @import("builtin");
const arc = @import("../alloc/arc.zig");
const http_client = @import("http_client.zig");

const dupeToNoxStr = http_client.dupeToNoxStr;

/// Faz II devamı (bkz. nox-teknik-spesifikasyon.md §3.67) — `join`nin
/// ÖNCEKİ uygulaması `std.fs.path.join`i `std.heap.page_allocator` İLE
/// çağırıp SONRA `dupeToNoxStr` İLE İKİNCİ bir kopya çıkarıyordu (ÇAĞRI
/// başına 2 tahsis, biri SAYFA-granülerlikli bir "genel amaçlı" ayırıcı
/// üzerinden). Bir Rust `std::path::Path` karşılaştırması (`benchmarks/
/// path_bench`) bunun ~9.4-9.9x YAVAŞ olduğunu ORTAYA ÇIKARDI; İZOLE bir
/// Zig testiyle (Nox/ARC/QBE HİÇ karışmadan, YALNIZCA `std.fs.path.join`+
/// `page_allocator` döngüsü) DOĞRULANDI: 100000 çağrı TEK BAŞINA ~130ms
/// (path_bench'in TOPLAM ~147ms'inin BÜYÜK kısmı) — `page_allocator`nin
/// KENDİSİ (genel bir bump/pool ayırıcı DEĞİL, OS SAYFASI granülerlikli)
/// darboğazdı. Burada `nox_strings_join_raw`nin (EE.1) AYNI stratejisi
/// uygulanır: `std.fs.path.join`in KENDİ (yalnızca 2 yol İçin basitleşmiş)
/// uzunluk-hesabı + tek-geçiş kopyalama mantığı EL İLE, DOĞRUDAN
/// `arc.nox_rc_alloc`a (TEK tahsis, ARA tampon YOK) yazılarak tekrarlanır.
/// Ayırıcı-arasındaki ayraç ÇAKIŞMASI/EKSİKLİĞİ kuralı (`a` SONU VE `b`
/// BAŞI ikisi de ayraçsa TEKİ ATLA, ikisi de DEĞİLSE BİR ayraç EKLE)
/// `std.fs.path.joinSepMaybeZ` İLE BİREBİR AYNIDIR (bkz. Zig std kaynağı) —
/// yalnızca `..`/`.` NORMALİZASYONU YAPILMAZ, ki ZATEN ESKİ `std.fs.path.
/// join` de YAPMIYORDU (davranış DEĞİŞMEDİ, yalnızca tahsis stratejisi).
export fn nox_path_join_raw(rt: ?*anyopaque, a: ?[*:0]const u8, b: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const a_slice = std.mem.span(a orelse return null);
    const b_slice = std.mem.span(b orelse return null);

    if (a_slice.len == 0) return dupeToNoxStr(rt, b_slice);
    if (b_slice.len == 0) return dupeToNoxStr(rt, a_slice);

    const a_ends_sep = std.fs.path.isSep(a_slice[a_slice.len - 1]);
    const b_starts_sep = std.fs.path.isSep(b_slice[0]);
    const need_sep = !a_ends_sep and !b_starts_sep;
    const b_adjusted = if (a_ends_sep and b_starts_sep) b_slice[1..] else b_slice;

    const total_len = a_slice.len + @as(usize, if (need_sep) 1 else 0) + b_adjusted.len;
    const raw = arc.nox_rc_alloc(rt, total_len + 1) orelse return null;
    const out: [*]u8 = @ptrCast(raw);
    @memcpy(out[0..a_slice.len], a_slice);
    var off: usize = a_slice.len;
    if (need_sep) {
        out[off] = std.fs.path.sep;
        off += 1;
    }
    @memcpy(out[off..][0..b_adjusted.len], b_adjusted);
    off += b_adjusted.len;
    out[off] = 0;
    return @ptrCast(out);
}

export fn nox_path_basename_raw(rt: ?*anyopaque, p: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const slice = std.mem.span(p orelse return null);
    return dupeToNoxStr(rt, std.fs.path.basename(slice));
}

/// `std.fs.path.dirname` bir üst dizin YOKSA (ör. `"foo.txt"`) `null`
/// döner — Nox `str`ın nullable bir karşılığı OLMADIĞINDAN bu durumda boş
/// dize (`""`) döndürülür (belgelenen, kasıtlı bir varsayılan).
export fn nox_path_dirname_raw(rt: ?*anyopaque, p: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const slice = std.mem.span(p orelse return null);
    const d = std.fs.path.dirname(slice) orelse "";
    return dupeToNoxStr(rt, d);
}

export fn nox_path_extension_raw(rt: ?*anyopaque, p: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const slice = std.mem.span(p orelse return null);
    return dupeToNoxStr(rt, std.fs.path.extension(slice));
}

/// Diğer "sonuç" extern'lerin (`nox_fs_last_op_ok` vb.) AYNI kuralı —
/// `bool` YERİNE `int` (0/1) döner, `.nox` sarmalayıcısı `!= 0` İLE
/// `bool`a çevirir (bu projede DAHA ÖNCE `-> bool` dönüşü test edilmiş bir
/// yol DEĞİL, `-> int` İSE HER YERDE KANITLANMIŞ).
export fn nox_path_is_absolute_raw(p: ?[*:0]const u8) callconv(.c) i32 {
    const slice = std.mem.span(p orelse return 0);
    return if (std.fs.path.isAbsolute(slice)) 1 else 0;
}

// Faz III.4 (bkz. nox-teknik-spesifikasyon.md §3.69) — `canonicalize`
// (yalnızca modül İÇİNDE) GERÇEKTEN I/O YAPAR (`realpath(3)`, sembolik
// linkleri ÇÖZMEK İçin dosyanın VAR OLMASI GEREKİR) — bu modülün üstündeki
// "hiç I/O yok" ilkesinin BİLİNÇLİ, TEK istisnası. Bu YÜZDEN `nox.fs` İLE
// AYNI "ham çağrı + AYRI durum sorgusu" desenine (`PathError`) ihtiyaç
// duyan TEK fonksiyon budur.
threadlocal var g_last_ok: bool = true;

export fn nox_path_last_op_ok() callconv(.c) i32 {
    return if (g_last_ok) 1 else 0;
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
        g_last_ok = false;
        return dupeToNoxStr(rt, "");
    };
    if (builtin.os.tag == .windows) {
        var buf: [std.c.PATH_MAX]u8 = undefined;
        const len = WinPath.GetFullPathNameA(path, buf.len, &buf, null);
        if (len == 0 or len >= buf.len) {
            g_last_ok = false;
            return dupeToNoxStr(rt, "");
        }
        g_last_ok = true;
        return dupeToNoxStr(rt, buf[0..len]);
    }
    var buf: [std.c.PATH_MAX]u8 = undefined;
    const resolved = std.c.realpath(path, &buf) orelse {
        g_last_ok = false;
        return dupeToNoxStr(rt, "");
    };
    g_last_ok = true;
    return dupeToNoxStr(rt, std.mem.span(resolved));
}

/// Faz III.4 — `path` `prefix` İLE BAŞLIYORSA prefix'i (ve HEMEN ARDINDAN
/// gelen TEK bir ayracı, VARSA) ÇIKARIP kalanı döner. Rust'ın `Path::
/// strip_prefix`inin AKSİNE (bir `Result` döner) BAŞLAMAZSA `path`i
/// DEĞİŞMEDEN döner — bilinçli v1 basitleştirmesi (`nox.path`nin "hiç
/// I/O yok, hiç raise yok" ilkesiyle TUTARLI, bkz. modül-üstü not).
export fn nox_path_strip_prefix_raw(rt: ?*anyopaque, p: ?[*:0]const u8, prefix: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const slice = std.mem.span(p orelse return null);
    const pre = std.mem.span(prefix orelse return null);
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
    const slice = std.mem.span(p orelse return null);

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(std.heap.page_allocator);
    var it = std.fs.path.componentIterator(slice);
    while (it.next()) |comp| {
        names.append(std.heap.page_allocator, comp.name) catch return null;
    }

    const raw = arc.nox_rc_alloc(rt, 16 + 8 * names.items.len) orelse return null;
    const bytes: [*]u8 = @ptrCast(raw);
    @as(*align(1) i64, @ptrCast(bytes)).* = @intCast(names.items.len);
    @as(*align(1) i64, @ptrCast(bytes + 8)).* = @intCast(names.items.len);
    for (names.items, 0..) |name, i| {
        const dup = dupeToNoxStr(rt, name) orelse return null;
        const slot = bytes + 16 + 8 * i;
        @as(*align(1) i64, @ptrCast(slot)).* = @bitCast(@as(isize, @intCast(@intFromPtr(dup))));
    }
    return @ptrCast(bytes);
}

test "nox_path_join_raw iki parcayi dogru birlestirir" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const j = nox_path_join_raw(rt, "a/b", "c.txt") orelse return error.Failed;
    defer str.nox_str_release(rt, j);
    try std.testing.expectEqualStrings("a/b/c.txt", std.mem.sliceTo(j, 0));

    // Faz II devamı — `join`in EL İLE yazılan uzunluk-hesabının/ayraç-
    // çakışması mantığının `std.fs.path.joinSepMaybeZ` İLE AYNI davrandığını
    // doğrulayan kenar durumları.
    const j2 = nox_path_join_raw(rt, "a/", "/b") orelse return error.Failed;
    defer str.nox_str_release(rt, j2);
    try std.testing.expectEqualStrings("a/b", std.mem.sliceTo(j2, 0));

    const j3 = nox_path_join_raw(rt, "", "b") orelse return error.Failed;
    defer str.nox_str_release(rt, j3);
    try std.testing.expectEqualStrings("b", std.mem.sliceTo(j3, 0));

    const j4 = nox_path_join_raw(rt, "a", "") orelse return error.Failed;
    defer str.nox_str_release(rt, j4);
    try std.testing.expectEqualStrings("a", std.mem.sliceTo(j4, 0));
}

test "nox_path_basename_raw/dirname/extension dogru calisir" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const b = nox_path_basename_raw(rt, "/a/b/c.txt") orelse return error.Failed;
    defer str.nox_str_release(rt, b);
    try std.testing.expectEqualStrings("c.txt", std.mem.sliceTo(b, 0));

    const d = nox_path_dirname_raw(rt, "/a/b/c.txt") orelse return error.Failed;
    defer str.nox_str_release(rt, d);
    try std.testing.expectEqualStrings("/a/b", std.mem.sliceTo(d, 0));

    const d2 = nox_path_dirname_raw(rt, "c.txt") orelse return error.Failed;
    defer str.nox_str_release(rt, d2);
    try std.testing.expectEqualStrings("", std.mem.sliceTo(d2, 0));

    const e = nox_path_extension_raw(rt, "/a/b/c.txt") orelse return error.Failed;
    defer str.nox_str_release(rt, e);
    try std.testing.expectEqualStrings(".txt", std.mem.sliceTo(e, 0));
}

test "nox_path_is_absolute_raw mutlak/goreli yollari dogru ayirt eder" {
    try std.testing.expectEqual(@as(i32, 1), nox_path_is_absolute_raw("/a/b"));
    try std.testing.expectEqual(@as(i32, 0), nox_path_is_absolute_raw("a/b"));
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
    const c = nox_path_canonicalize_raw(rt, "/tmp/../tmp") orelse return error.Failed;
    defer str.nox_str_release(rt, c);
    try std.testing.expectEqualStrings(expected_tmp, std.mem.sliceTo(c, 0));
    try std.testing.expect(g_last_ok);

    const missing = nox_path_canonicalize_raw(rt, "/definitely/does/not/exist/nox_iii4_test") orelse return error.Failed;
    defer str.nox_str_release(rt, missing);
    try std.testing.expect(!g_last_ok);
}

test "Faz III.4: nox_path_strip_prefix_raw onek eslesirse cikarir, eslesmezse degismeden doner" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const s1 = nox_path_strip_prefix_raw(rt, "/a/b/c.txt", "/a/b") orelse return error.Failed;
    defer str.nox_str_release(rt, s1);
    try std.testing.expectEqualStrings("c.txt", std.mem.sliceTo(s1, 0));

    const s2 = nox_path_strip_prefix_raw(rt, "/a/b/c.txt", "/x/y") orelse return error.Failed;
    defer str.nox_str_release(rt, s2);
    try std.testing.expectEqualStrings("/a/b/c.txt", std.mem.sliceTo(s2, 0));
}

test "Faz III.4: nox_path_components_raw yol bilesenlerini dogru sirada doner" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const list_ptr = nox_path_components_raw(rt, "/a/b/c.txt") orelse return error.Failed;
    const bytes: [*]u8 = @ptrCast(list_ptr);
    const count: usize = @intCast(@as(*align(1) i64, @ptrCast(bytes)).*);
    try std.testing.expectEqual(@as(usize, 3), count);

    const expected = [_][]const u8{ "a", "b", "c.txt" };
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const addr: usize = @bitCast(@as(*align(1) i64, @ptrCast(bytes + 16 + 8 * i)).*);
        const p: [*:0]u8 = @ptrFromInt(addr);
        defer str.nox_str_release(rt, p);
        try std.testing.expectEqualStrings(expected[i], std.mem.sliceTo(p, 0));
    }
    arc.nox_rc_release(rt, list_ptr, 16 + 8 * count);
}
