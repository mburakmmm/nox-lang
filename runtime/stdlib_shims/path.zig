//! `nox.path` Zig kabuğu — Faz EE.1 (bkz. nox-teknik-spesifikasyon.md
//! §3.61). SAF string manipülasyonu — HİÇBİR I/O YAPMAZ (bkz. `nox.fs`,
//! dosya sistemiyle etkileşen sorgular İçin, ör. `exists`/`is_file`).
//! `std.fs.path.*`i DOĞRUDAN sarar; HİÇBİR fonksiyon "başarısız" olamaz
//! (saf string işlemleri), bu yüzden `.nox` tarafında `raise` YOLU YOKTUR.

const std = @import("std");
const http_client = @import("http_client.zig");

const dupeToNoxStr = http_client.dupeToNoxStr;

export fn nox_path_join_raw(rt: ?*anyopaque, a: ?[*:0]const u8, b: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const a_slice = std.mem.span(a orelse return null);
    const b_slice = std.mem.span(b orelse return null);
    const joined = std.fs.path.join(std.heap.page_allocator, &.{ a_slice, b_slice }) catch return null;
    defer std.heap.page_allocator.free(joined);
    return dupeToNoxStr(rt, joined);
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
