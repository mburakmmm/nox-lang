//! Nox v0.1 semantik tip temsili. Sözdizimsel tip ifadeleri (`ast.TypeExpr`)
//! `checker.zig` tarafından bu tiplere çözümlenir.

const std = @import("std");

pub const Type = union(enum) {
    int,
    float,
    boolean,
    str,
    none,
    list: *const Type,
    class: []const u8,
    /// `Task[T]` — bir `spawn`dan gelen tutamaç (bkz. nox-teknik-
    /// spesifikasyon.md §3.21). Yalnızca `spawn`ın kendisi ÜRETİR; `await`
    /// ile `T`ye çözülür.
    task: *const Type,
    /// `Channel[T]` — yerleşik bir generic tip (bkz. §3.21). `Channel[T](
    /// capacity)` ile inşa edilir; `.send(v)`/`.recv()` (her ikisi de
    /// `await` ile sarmalanmalıdır) `T` üzerinde çalışır.
    channel: *const Type,
    /// `ptr` — Faz 20'nin ikinci artımı (bkz. nox-teknik-spesifikasyon.md
    /// §3.20): handle-tabanlı C API'leri (`FILE*`/`sqlite3*` gibi) açan,
    /// ARC-İZLENMEYEN OPAK bir işaretçi. Nox bunun İÇİNDEKİ veriyi HİÇ
    /// bilmez/yorumlamaz — yalnızca `extern def` sınırından geçirir,
    /// saklar, karşılaştırır. Yaşam süresi TAMAMEN kullanıcının
    /// sorumluluğundadır (ilgili C API'nin kendi "destroy"/"close"
    /// fonksiyonuyla, extern def aracılığıyla) — Nox hiçbir zaman
    /// otomatik olarak serbest bırakmaz.
    ptr,
    /// `dict[K, V]` — stdlib fazı §C (bkz. nox-teknik-spesifikasyon.md).
    /// v1 kapsamı bilinçli olarak dar: `K`/`V` yalnızca `int`/`bool`/`str`
    /// olabilir (sınıf anahtar/değer ERTELENDİ — bkz. checker.zig'in
    /// `typeExprToType`indeki `"dict"` dalı).
    dict: Dict,
};

pub const Dict = struct { key: *const Type, value: *const Type };

pub fn eql(a: Type, b: Type) bool {
    if (@as(std.meta.Tag(Type), a) != @as(std.meta.Tag(Type), b)) return false;
    return switch (a) {
        .int, .float, .boolean, .str, .none, .ptr => true,
        .list => |elem_a| eql(elem_a.*, b.list.*),
        .class => |name_a| std.mem.eql(u8, name_a, b.class),
        .task => |elem_a| eql(elem_a.*, b.task.*),
        .channel => |elem_a| eql(elem_a.*, b.channel.*),
        .dict => |d_a| eql(d_a.key.*, b.dict.key.*) and eql(d_a.value.*, b.dict.value.*),
    };
}

pub fn isNumeric(t: Type) bool {
    return t == .int or t == .float;
}

pub fn format(t: Type, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (t) {
        .int => try writer.writeAll("int"),
        .float => try writer.writeAll("float"),
        .boolean => try writer.writeAll("bool"),
        .str => try writer.writeAll("str"),
        .none => try writer.writeAll("None"),
        .list => |elem| {
            try writer.writeAll("list[");
            try format(elem.*, writer);
            try writer.writeAll("]");
        },
        .class => |name| try writer.writeAll(name),
        .task => |elem| {
            try writer.writeAll("Task[");
            try format(elem.*, writer);
            try writer.writeAll("]");
        },
        .channel => |elem| {
            try writer.writeAll("Channel[");
            try format(elem.*, writer);
            try writer.writeAll("]");
        },
        .ptr => try writer.writeAll("ptr"),
        .dict => |d| {
            try writer.writeAll("dict[");
            try format(d.key.*, writer);
            try writer.writeAll(", ");
            try format(d.value.*, writer);
            try writer.writeAll("]");
        },
    }
}

pub fn toAlloc(allocator: std.mem.Allocator, t: Type) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try format(t, &aw.writer);
    return aw.toOwnedSlice();
}

test "eql aynı iç içe list tiplerini eşit sayar" {
    var elem: Type = .int;
    const a: Type = .{ .list = &elem };
    const b: Type = .{ .list = &elem };
    try std.testing.expect(eql(a, b));
}

test "eql farklı sınıf adlarını eşit saymaz" {
    try std.testing.expect(!eql(.{ .class = "Point" }, .{ .class = "Vector" }));
}
