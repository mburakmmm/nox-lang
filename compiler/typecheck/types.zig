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
    /// `ThreadHandle[T]` — Faz BB.3 (bkz. nox-teknik-spesifikasyon.md
    /// §3.49): `nox.thread.spawn(entry, arg)`den gelen tutamaç. `Task[T]`
    /// İLE AYNI "sihirli generic isim" deseni (GERÇEK bir sınıf DEĞİL) —
    /// ama AYRI bir tiptir, ÇÜNKÜ `Task`ın AKSİNE GERÇEK bir OS iş
    /// parçacığına bağlıdır (`await` DEĞİL, `.join()` ile çözülür).
    thread_handle: *const Type,
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
    /// `(ParamTipi, ...) -> DönüşTipi` — Faz U.4 (bkz. nox-teknik-
    /// spesifikasyon.md §3.23): birinci-sınıf bir fonksiyon/closure DEĞERİNİN
    /// tipi. Çalışma zamanı temsili `class` örnekleriyle AYNI (ARC pointer,
    /// bkz. codegen.zig'in `HeapKind.closure`su) — yalnızca İÇ DÜZENİ VE
    /// "çağırma" işlemi FARKLIDIR.
    func: FuncType,
};

pub const Dict = struct { key: *const Type, value: *const Type };
pub const FuncType = struct { params: []const Type, return_type: *const Type };

pub fn eql(a: Type, b: Type) bool {
    if (@as(std.meta.Tag(Type), a) != @as(std.meta.Tag(Type), b)) return false;
    return switch (a) {
        .int, .float, .boolean, .str, .none, .ptr => true,
        .list => |elem_a| eql(elem_a.*, b.list.*),
        .class => |name_a| std.mem.eql(u8, name_a, b.class),
        .task => |elem_a| eql(elem_a.*, b.task.*),
        .channel => |elem_a| eql(elem_a.*, b.channel.*),
        .thread_handle => |elem_a| eql(elem_a.*, b.thread_handle.*),
        .dict => |d_a| eql(d_a.key.*, b.dict.key.*) and eql(d_a.value.*, b.dict.value.*),
        .func => |f_a| blk: {
            const f_b = b.func;
            if (f_a.params.len != f_b.params.len) break :blk false;
            for (f_a.params, f_b.params) |pa, pb| {
                if (!eql(pa, pb)) break :blk false;
            }
            break :blk eql(f_a.return_type.*, f_b.return_type.*);
        },
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
        .thread_handle => |elem| {
            try writer.writeAll("ThreadHandle[");
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
        .func => |f| {
            try writer.writeAll("(");
            for (f.params, 0..) |p, i| {
                if (i != 0) try writer.writeAll(", ");
                try format(p, writer);
            }
            try writer.writeAll(") -> ");
            try format(f.return_type.*, writer);
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

test "Faz U.4.1: func tipi format (int, int) -> int biçiminde yazdırılır" {
    var ret: Type = .int;
    const params = [_]Type{ .int, .int };
    const f: Type = .{ .func = .{ .params = &params, .return_type = &ret } };
    const s = try toAlloc(std.testing.allocator, f);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("(int, int) -> int", s);
}

test "Faz U.4.1: func tipi eql aynı imzayı eşit, farklı dönüş tipini FARKLI sayar" {
    var ret_int: Type = .int;
    var ret_float: Type = .float;
    const params = [_]Type{.int};
    const a: Type = .{ .func = .{ .params = &params, .return_type = &ret_int } };
    const b: Type = .{ .func = .{ .params = &params, .return_type = &ret_int } };
    const c: Type = .{ .func = .{ .params = &params, .return_type = &ret_float } };
    try std.testing.expect(eql(a, b));
    try std.testing.expect(!eql(a, c));
}

test "Faz U.4.1: func tipi eql farklı parametre SAYISINI farklı sayar" {
    var ret: Type = .int;
    const one_param = [_]Type{.int};
    const two_params = [_]Type{ .int, .int };
    const a: Type = .{ .func = .{ .params = &one_param, .return_type = &ret } };
    const b: Type = .{ .func = .{ .params = &two_params, .return_type = &ret } };
    try std.testing.expect(!eql(a, b));
}
