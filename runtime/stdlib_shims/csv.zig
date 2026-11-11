//! `nox.csv.parse` Zig kabuğu (v2.1.62): saf Nox karakter-karakter durum makinesi CPython'un C okuyucusundan 1.4x yavaştı. Anlam AYNEN korunur:
//!   - alıntılı alanda `""` = bir `"`; alıntı dışında `\r` YOK SAYILIR (alan içinde de), `\n` satırı bitirir, `,` alanı bitirir;
//!   - boş girdi = 0 satır; sondaki satır sonu yeni satır AÇMAZ; sonda bitmemiş alanı/satırı olan metin kalan alanı ekler;
//!   - kapanmamış alıntı = hata (`last_ok` = 0 -> Nox tarafı `CsvError`).
//! Dönüş türü iç içe liste olamayacağından düz alan listesi (`nox_csv_fields_raw`) + satır uzunlukları (`nox_csv_row_lens_raw`, son ayrıştırmanın) verilir; Nox tarafı bölüp satırlara dizer.

const std = @import("std");
const str_mod = @import("../str.zig");
const shim_util = @import("shim_util.zig");
const abi_layout = @import("abi_layout");

const LIST_HEADER_SIZE = abi_layout.LIST_HEADER_SIZE;
const FIELD_SLOT_SIZE = abi_layout.FIELD_SLOT_SIZE;
const arc = @import("../alloc/arc.zig");

const LastSlot = shim_util.TlsSlot(bool, true);
const LensSlot = shim_util.TlsSlot(?std.ArrayListUnmanaged(i64), null);

fn buildStrList(rt: ?*anyopaque, items: []const ?[*:0]u8) ?*anyopaque {
    const raw = arc.nox_rc_alloc(rt, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * items.len) orelse return null;
    const bytes: [*]u8 = @ptrCast(raw);
    @as(*align(1) i64, @ptrCast(bytes)).* = @intCast(items.len);
    @as(*align(1) i64, @ptrCast(bytes + 8)).* = @intCast(items.len);
    for (items, 0..) |it, i| {
        @as(*align(1) i64, @ptrCast(bytes + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i)).* = @as(i64, @bitCast(@as(u64, @intFromPtr(it))));
    }
    return @ptrCast(bytes);
}

fn buildIntList(rt: ?*anyopaque, vals: []const i64) ?*anyopaque {
    const raw = arc.nox_rc_alloc(rt, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * vals.len) orelse return null;
    const bytes: [*]u8 = @ptrCast(raw);
    @as(*align(1) i64, @ptrCast(bytes)).* = @intCast(vals.len);
    @as(*align(1) i64, @ptrCast(bytes + 8)).* = @intCast(vals.len);
    for (vals, 0..) |v, i| @as(*align(1) i64, @ptrCast(bytes + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i)).* = v;
    return @ptrCast(bytes);
}

/// Ayrıştırır: alanları `fields`e (sahipli Nox str'leri), satır başına alan sayısını `lens`e yazar. Kapanmamış alıntıda `false`. Tahsis hatasında da `false` + `oom` işaretlenir.
pub fn parseInto(
    a: std.mem.Allocator,
    rt: ?*anyopaque,
    text: []const u8,
    fields: *std.ArrayListUnmanaged(?[*:0]u8),
    lens: *std.ArrayListUnmanaged(i64),
) error{ OutOfMemory, Unterminated }!void {
    var field: std.ArrayListUnmanaged(u8) = .empty;
    defer field.deinit(a);
    var row_fields: i64 = 0;
    var in_quotes = false;
    var field_started = false;
    var i: usize = 0;
    const n = text.len;
    while (i < n) {
        const c = text[i];
        if (in_quotes) {
            if (c == '"') {
                if (i + 1 < n and text[i + 1] == '"') {
                    try field.append(a, '"');
                    i += 2;
                } else {
                    in_quotes = false;
                    i += 1;
                }
            } else {
                // alıntı içinde sıradaki '"'e kadar toplu kopyala
                var j = i + 1;
                while (j < n and text[j] != '"') j += 1;
                try field.appendSlice(a, text[i..j]);
                i = j;
            }
        } else if (c == '"') {
            in_quotes = true;
            field_started = true;
            i += 1;
        } else if (c == ',') {
            try fields.append(a, str_mod.nox_str_from_bytes(rt, field.items) orelse return error.OutOfMemory);
            row_fields += 1;
            field.clearRetainingCapacity();
            field_started = false;
            i += 1;
        } else if (c == '\r') {
            i += 1;
        } else if (c == '\n') {
            try fields.append(a, str_mod.nox_str_from_bytes(rt, field.items) orelse return error.OutOfMemory);
            row_fields += 1;
            try lens.append(a, row_fields);
            row_fields = 0;
            field.clearRetainingCapacity();
            field_started = false;
            i += 1;
        } else {
            // alıntısız alan: bir sonraki özel bayta kadar toplu kopyala
            var j = i + 1;
            while (j < n) : (j += 1) {
                const d = text[j];
                if (d == ',' or d == '\n' or d == '\r' or d == '"') break;
            }
            try field.appendSlice(a, text[i..j]);
            field_started = true;
            i = j;
        }
    }
    if (in_quotes) return error.Unterminated;
    if (field.items.len != 0 or field_started or row_fields > 0) {
        try fields.append(a, str_mod.nox_str_from_bytes(rt, field.items) orelse return error.OutOfMemory);
        row_fields += 1;
        try lens.append(a, row_fields);
    }
}

pub export fn nox_csv_fields_raw(rt: ?*anyopaque, s: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    const text = if (s) |sp| str_mod.nox_str_slice(sp) else "";
    const a = shim_util.scratchAllocator();
    var fields: std.ArrayListUnmanaged(?[*:0]u8) = .empty;
    defer fields.deinit(a);
    var lens: std.ArrayListUnmanaged(i64) = .empty;
    LastSlot.value = true;
    if (LensSlot.value) |*old| old.deinit(a);
    LensSlot.value = null;
    parseInto(a, rt, text, &fields, &lens) catch {
        // Kısmen üretilen alanları serbest bırak.
        for (fields.items) |f| str_mod.nox_str_release(rt, f);
        lens.deinit(a);
        LastSlot.value = false;
        return buildStrList(rt, &.{});
    };
    const list = buildStrList(rt, fields.items);
    LensSlot.value = lens;
    return list;
}

pub export fn nox_csv_row_lens_raw(rt: ?*anyopaque) callconv(.c) ?*anyopaque {
    const a = shim_util.scratchAllocator();
    if (LensSlot.value) |*l| {
        const out = buildIntList(rt, l.items);
        l.deinit(a);
        LensSlot.value = null;
        return out;
    }
    return buildIntList(rt, &.{});
}

pub export fn nox_csv_last_ok_raw() callconv(.c) i64 {
    return if (LastSlot.value) 1 else 0;
}

test "parseInto: alanlar ve satır uzunlukları (eski Nox anlamı)" {
    const a = std.testing.allocator;
    const asap = @import("../alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    const cases = [_]struct { src: []const u8, lens: []const i64, nf: usize }{
        .{ .src = "", .lens = &.{}, .nf = 0 },
        .{ .src = "a,b,c\n", .lens = &.{3}, .nf = 3 },
        .{ .src = "a,b,c\r\nd,e,f", .lens = &.{ 3, 3 }, .nf = 6 },
        .{ .src = "\n", .lens = &.{1}, .nf = 1 },
        .{ .src = "a\n\nb", .lens = &.{ 1, 1, 1 }, .nf = 3 },
        .{ .src = "\"he said \"\"hi\"\"\",2\n", .lens = &.{2}, .nf = 2 },
        .{ .src = ",", .lens = &.{2}, .nf = 2 },
        .{ .src = "a\rb,c\n", .lens = &.{2}, .nf = 2 },
    };
    for (cases) |c| {
        var fields: std.ArrayListUnmanaged(?[*:0]u8) = .empty;
        defer fields.deinit(a);
        var lens: std.ArrayListUnmanaged(i64) = .empty;
        defer lens.deinit(a);
        try parseInto(a, rt, c.src, &fields, &lens);
        defer for (fields.items) |f| str_mod.nox_str_release(rt, f);
        try std.testing.expectEqualSlices(i64, c.lens, lens.items);
        try std.testing.expectEqual(c.nf, fields.items.len);
    }
    var fields: std.ArrayListUnmanaged(?[*:0]u8) = .empty;
    defer fields.deinit(a);
    var lens: std.ArrayListUnmanaged(i64) = .empty;
    defer lens.deinit(a);
    try std.testing.expectError(error.Unterminated, parseInto(a, rt, "a,\"x", &fields, &lens));
    for (fields.items) |f| str_mod.nox_str_release(rt, f);
}
