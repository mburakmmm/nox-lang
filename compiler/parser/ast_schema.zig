//! noxc-nightly Aşama 2.A: `ast.zig`nin ŞEMASINI (tüm yapı/birleşim/enum tanımları, alan adları, türleri ve varsayılanları) comptime yansımasıyla satır satır yazar. `scripts/gen_selfhost_ast.py`
//! bunu okuyup Nox tarafının düğüm tablosunu, oluşturucularını ve `dump_full` yazıcısını üretir; Zig kaynağı elle ayrıştırılmaz (tek doğruluk kaynağı derleyicinin kendi türleri).
//!
//! Biçim (satır tabanlı):
//!   struct <Ad>            sonra her alan için:  "  <alan> <tür> [= <varsayılan>]"
//!   union <Ad>             sonra her varyant için: "  <etiket> <tür>"  (`void` = yüksüz)
//!   enum <Ad> <ad1> <ad2> ...
//! Tür gösterimi: i64 u32 usize f64 bool str (=[]const u8) void; `opt(T)`; `ptr(T)` (*T, *const T); `slice(T)` ([]T, []const T); adlandırılmış türler `Expr` gibi; `skip` = dökülmeyen (HashMap).
//! Varsayılan: sayı/bool/enum etiketi (`.ad`)/`null`/`[]` (boş dilim)/`zero` (sıfır-değerli yapı)/`?` (dökümlenemez).

const std = @import("std");
const ast = @import("ast.zig");

const Writer = std.Io.Writer;

fn typeText(comptime T: type) []const u8 {
    @setEvalBranchQuota(200000);
    return comptime switch (@typeInfo(T)) {
        .bool => "bool",
        .int => |i| (if (i.signedness == .signed) "i" else "u") ++ std.fmt.comptimePrint("{d}", .{i.bits}),
        .float => "f64",
        .void => "void",
        .optional => |o| "opt(" ++ typeText(o.child) ++ ")",
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8) "str" else "slice(" ++ typeText(p.child) ++ ")",
            .one => "ptr(" ++ typeText(p.child) ++ ")",
            else => "?",
        },
        .@"struct", .@"union", .@"enum" => blk: {
            const full = @typeName(T);
            // `parser.ast.Expr` → `Expr`; ast.zig dışındaki türler (Span, HashMap) tam adıyla.
            if (std.mem.startsWith(u8, full, "parser.ast.")) break :blk full["parser.ast.".len..];
            if (std.mem.indexOf(u8, full, "HashMap") != null) break :blk "skip";
            if (std.mem.eql(u8, full, "span.Span")) break :blk "Span";
            break :blk full;
        },
        else => "?",
    };
}

fn writeDefault(w: *Writer, comptime T: type, v: T) Writer.Error!void {
    switch (@typeInfo(T)) {
        .bool => try w.writeAll(if (v) "true" else "false"),
        .int => try w.print("{d}", .{v}),
        .float => try w.print("{d}", .{v}),
        .@"enum" => try w.print(".{s}", .{@tagName(v)}),
        .optional => if (v == null) try w.writeAll("null") else try w.writeAll("?"),
        .pointer => |p| if (p.size == .slice and v.len == 0) try w.writeAll("[]") else try w.writeAll("?"),
        .@"struct" => try w.writeAll("zero"),
        else => try w.writeAll("?"),
    }
}

pub fn dumpSchema(w: *Writer) Writer.Error!void {
    inline for (@typeInfo(ast).@"struct".decls) |d| {
        const decl = @field(ast, d.name);
        if (@TypeOf(decl) == type) {
            const T: type = decl;
            switch (@typeInfo(T)) {
                .@"struct" => |s| {
                    try w.print("struct {s}\n", .{d.name});
                    inline for (s.fields) |f| {
                        try w.print("  {s} {s}", .{ f.name, comptime typeText(f.type) });
                        if (f.defaultValue()) |dv| {
                            try w.writeAll(" = ");
                            try writeDefault(w, f.type, dv);
                        }
                        try w.writeByte('\n');
                    }
                },
                .@"union" => |u| {
                    try w.print("union {s}\n", .{d.name});
                    inline for (u.fields) |f| try w.print("  {s} {s}\n", .{ f.name, comptime typeText(f.type) });
                },
                .@"enum" => |e| {
                    try w.print("enum {s}", .{d.name});
                    inline for (e.fields) |f| try w.print(" {s}", .{f.name});
                    try w.writeByte('\n');
                },
                else => {},
            }
        }
    }
}
