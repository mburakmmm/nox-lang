//! `nox.path` Zig kabuğu — Faz EE.1 (bkz. nox-teknik-spesifikasyon.md
//! §3.61). SAF string manipülasyonu — HİÇBİR I/O YAPMAZ (bkz. `nox.fs`,
//! dosya sistemiyle etkileşen sorgular İçin, ör. `exists`/`is_file`).
//! `std.fs.path.*`i DOĞRUDAN sarar; HİÇBİR fonksiyon "başarısız" olamaz
//! (saf string işlemleri), bu yüzden `.nox` tarafında `raise` YOLU YOKTUR.

const std = @import("std");
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
