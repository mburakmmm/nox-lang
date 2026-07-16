//! `list[T].sort()` çalışma zamanı desteği — Faz EE.1 (bkz. nox-teknik-
//! spesifikasyon.md §3.61). `codegen.zig`nin `genListSort`ı, listenin ham
//! başlığından (`LIST_HEADER_SIZE` = 16 bayt: 8 uzunluk + 8 kapasite)
//! SONRAKİ ilk eleman adresini (`data`) VE `len`i doğrudan geçirir —
//! kapasite/başlığın KENDİSİ BURADA hiç okunmaz/DOKUNULMAZ (sıralama
//! YERİNDE, eleman SAYISI/kapasite DEĞİŞMEZ, `.append`nin AKSİNE HİÇBİR
//! yeniden-tahsis ihtimali YOKTUR).

const std = @import("std");

export fn nox_list_sort_int(data: [*]i64, len: i64) callconv(.c) void {
    if (len <= 0) return;
    std.mem.sort(i64, data[0..@intCast(len)], {}, std.sort.asc(i64));
}

export fn nox_list_sort_float(data: [*]f64, len: i64) callconv(.c) void {
    if (len <= 0) return;
    std.mem.sort(f64, data[0..@intCast(len)], {}, std.sort.asc(f64));
}

/// `list[str]`in eleman deposu (bkz. modül üstü not) HER slotta bir `str`
/// İŞARETÇİSİNİN ham bit örüntüsünü (`i64` genişliğinde) taşır — bu
/// karşılaştırıcı ONU bir işaretçiye GERİ yorumlayıp GERÇEK bayt
/// içeriklerini (`std.mem.order`) karşılaştırır.
fn lessThanStr(_: void, a: i64, b: i64) bool {
    const pa: [*:0]const u8 = @ptrFromInt(@as(usize, @bitCast(a)));
    const pb: [*:0]const u8 = @ptrFromInt(@as(usize, @bitCast(b)));
    return std.mem.order(u8, std.mem.span(pa), std.mem.span(pb)) == .lt;
}

export fn nox_list_sort_str(data: [*]i64, len: i64) callconv(.c) void {
    if (len <= 0) return;
    std.mem.sort(i64, data[0..@intCast(len)], {}, lessThanStr);
}

test "nox_list_sort_int artan sirada siralar" {
    var data = [_]i64{ 3, 1, 4, 1, 5, 9, 2, 6 };
    nox_list_sort_int(&data, data.len);
    try std.testing.expectEqualSlices(i64, &.{ 1, 1, 2, 3, 4, 5, 6, 9 }, &data);
}

test "nox_list_sort_int bos/tek elemanli listede cokmez" {
    var empty: [0]i64 = .{};
    nox_list_sort_int(&empty, 0);
    var one = [_]i64{42};
    nox_list_sort_int(&one, 1);
    try std.testing.expectEqual(@as(i64, 42), one[0]);
}

test "nox_list_sort_float artan sirada siralar" {
    var data = [_]f64{ 3.5, -1.2, 0.0, 2.1 };
    nox_list_sort_float(&data, data.len);
    try std.testing.expectEqualSlices(f64, &.{ -1.2, 0.0, 2.1, 3.5 }, &data);
}

test "nox_list_sort_str dizeleri sozluksel sirada siralar" {
    const words = [_][:0]const u8{ "banana", "apple", "cherry" };
    var data: [3]i64 = undefined;
    for (words, 0..) |w, i| data[i] = @bitCast(@as(isize, @intCast(@intFromPtr(w.ptr))));
    nox_list_sort_str(&data, data.len);

    const p0: [*:0]const u8 = @ptrFromInt(@as(usize, @bitCast(data[0])));
    const p1: [*:0]const u8 = @ptrFromInt(@as(usize, @bitCast(data[1])));
    const p2: [*:0]const u8 = @ptrFromInt(@as(usize, @bitCast(data[2])));
    try std.testing.expectEqualStrings("apple", std.mem.sliceTo(p0, 0));
    try std.testing.expectEqualStrings("banana", std.mem.sliceTo(p1, 0));
    try std.testing.expectEqualStrings("cherry", std.mem.sliceTo(p2, 0));
}
