//! noxc-nightly Aşama 2.B: Zig `ast.Module`ünü Nox AST'sinin düz-dizi kodlamasına (project/selfhost-ast-tasarimi-2026-11.md §2; `scripts/gen_selfhost_ast.py` bunun Nox karşılığını üretir) çevirir.
//! Yansıma-tabanlı: `ast.zig`ye eklenen her alan otomatik kodlanır. Amaç: Nox parser'ı yazılmadan ÖNCE üretilmiş Nox yazıcısını (`d_*`) tüm depo üzerinde Zig dökümüne karşı doğrulamak
//! (`noxc-nightly ast-roundtrip` ↔ `noxc ast --full`) ve ileride checker sonrası tiplenmiş AST köprüsü için kodlayıcıyı hazır tutmak.
//!
//! Kodlama (Python `Gen.size` ile aynı): bool/int/enum/node = 1 tamsayı (enum: bildirim sırası); f64 = ham bit deseni; str = 2 (x, y: x >= 0 kaynak [x, y); x < 0 `sb[-x-1 .. -x-1+y]`);
//! slice = 2 (L'de başlangıç, uzunluk); ptr(T) = T; opt(node) = id ya da -1; opt(str)/opt(slice) yokluğu x = NONE. Struct/union değeri bir DÜĞÜMDÜR: `N`de ardışık alanlar (union: önce etiket).

const std = @import("std");
const ast = @import("ast.zig");
const span_mod = @import("../span.zig");

pub const NONE: i64 = -4611686018427387904;

const List = std.ArrayListUnmanaged(i64);

pub const Flat = struct {
    n: List = .empty,
    l: List = .empty,
    sb: std.ArrayListUnmanaged(u8) = .empty,
    /// (düğüm kimliği, Span düğüm kimliği) çiftleri.
    sp: List = .empty,
    body_start: i64 = 0,
    body_len: i64 = 0,
    exp_start: i64 = 0,
    exp_len: i64 = 0,
};

const Enc = struct {
    a: std.mem.Allocator,
    f: *Flat,
    src: []const u8,
    spans: *const std.AutoHashMapUnmanaged(usize, span_mod.Span),

    fn isNodeType(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .@"struct", .@"union" => true,
            .pointer => |p| p.size == .one and isNodeType(p.child),
            else => false,
        };
    }

    fn isMap(comptime T: type) bool {
        return @typeInfo(T) == .@"struct" and std.mem.indexOf(u8, @typeName(T), "HashMap") != null;
    }

    /// Bir `[]const u8` için (x, y) çifti.
    fn strComps(self: *Enc, s: []const u8, out: *List) !void {
        const base = @intFromPtr(self.src.ptr);
        const p = @intFromPtr(s.ptr);
        if (s.len > 0 and p >= base and p + s.len <= base + self.src.len) {
            const x: i64 = @intCast(p - base);
            try out.append(self.a, x);
            try out.append(self.a, x + @as(i64, @intCast(s.len)));
        } else if (s.len == 0) {
            try out.append(self.a, 0);
            try out.append(self.a, 0);
        } else {
            const off: i64 = @intCast(self.f.sb.items.len);
            try self.f.sb.appendSlice(self.a, s);
            try out.append(self.a, -off - 1);
            try out.append(self.a, @intCast(s.len));
        }
    }

    fn comps(self: *Enc, comptime T: type, v: T, out: *List, addr: usize) anyerror!void {
        switch (@typeInfo(T)) {
            .bool => try out.append(self.a, @intFromBool(v)),
            .int => try out.append(self.a, @intCast(v)),
            .float => try out.append(self.a, @bitCast(@as(f64, v))),
            .@"enum" => try out.append(self.a, @intFromEnum(v)),
            .@"struct", .@"union" => {
                const id = try self.node(T, v);
                try out.append(self.a, id);
                if (T == ast.Expr and addr != 0) try self.recordSpan(id, addr);
            },
            .optional => |o| {
                const Inner = o.child;
                if (comptime isNodeType(Inner)) {
                    if (v) |x| try self.comps(Inner, x, out, 0) else try out.append(self.a, -1);
                } else switch (@typeInfo(Inner)) {
                    .pointer => |p| {
                        if (p.size == .slice and p.child != u8) {
                            if (v) |x| try self.comps(Inner, x, out, 0) else {
                                try out.append(self.a, NONE);
                                try out.append(self.a, 0);
                            }
                        } else if (p.size == .slice) {
                            if (v) |x| try self.strComps(x, out) else {
                                try out.append(self.a, NONE);
                                try out.append(self.a, 0);
                            }
                        } else @compileError("ast_flat: desteklenmeyen opt(ptr) " ++ @typeName(T));
                    },
                    else => @compileError("ast_flat: desteklenmeyen opt " ++ @typeName(T)),
                }
            },
            .pointer => |p| switch (p.size) {
                .one => {
                    try self.comps(p.child, v.*, out, if (p.child == ast.Expr) @intFromPtr(v) else 0);
                },
                .slice => {
                    if (p.child == u8) {
                        try self.strComps(v, out);
                    } else {
                        var tmp: List = .empty;
                        defer tmp.deinit(self.a);
                        for (v) |*item| try self.comps(p.child, item.*, &tmp, if (p.child == ast.Expr) @intFromPtr(item) else 0);
                        const start: i64 = @intCast(self.f.l.items.len);
                        try self.f.l.appendSlice(self.a, tmp.items);
                        try out.append(self.a, start);
                        try out.append(self.a, @intCast(v.len));
                    }
                },
                else => @compileError("ast_flat: desteklenmeyen işaretçi " ++ @typeName(T)),
            },
            else => @compileError("ast_flat: desteklenmeyen tür " ++ @typeName(T)),
        }
    }

    fn recordSpan(self: *Enc, id: i64, addr: usize) !void {
        if (self.spans.get(addr)) |s| {
            const sid = try self.node(span_mod.Span, s);
            try self.f.sp.append(self.a, id);
            try self.f.sp.append(self.a, sid);
        }
    }

    fn node(self: *Enc, comptime T: type, v: T) anyerror!i64 {
        var tmp: List = .empty;
        defer tmp.deinit(self.a);
        switch (@typeInfo(T)) {
            .@"struct" => |s| {
                inline for (s.fields) |f| {
                    if (comptime isMap(f.type)) continue;
                    try self.comps(f.type, @field(v, f.name), &tmp, 0);
                }
            },
            .@"union" => {
                const tag = std.meta.activeTag(v);
                try tmp.append(self.a, @intFromEnum(tag));
                inline for (std.meta.fields(T)) |f| {
                    if (tag == @field(std.meta.Tag(T), f.name)) {
                        if (f.type != void) try self.comps(f.type, @field(v, f.name), &tmp, 0);
                    }
                }
            },
            else => @compileError("ast_flat.node: " ++ @typeName(T)),
        }
        const id: i64 = @intCast(self.f.n.items.len);
        try self.f.n.appendSlice(self.a, tmp.items);
        return id;
    }
};

/// `module`ü düz dizilere kodlar; `src` kaynak metindir (dizeler ona işaret ediyorsa (x, y) aralığı olarak kodlanır).
pub fn encodeModule(a: std.mem.Allocator, module: ast.Module, src: []const u8) !Flat {
    var f: Flat = .{};
    var e: Enc = .{ .a = a, .f = &f, .src = src, .spans = &module.expr_spans };
    var tmp: List = .empty;
    defer tmp.deinit(a);
    try e.comps([]ast.Stmt, module.body, &tmp, 0);
    f.body_start = tmp.items[0];
    f.body_len = tmp.items[1];
    var tmp2: List = .empty;
    defer tmp2.deinit(a);
    try e.comps([]const ast.ModuleExports, module.exports, &tmp2, 0);
    f.exp_start = tmp2.items[0];
    f.exp_len = tmp2.items[1];
    return f;
}
