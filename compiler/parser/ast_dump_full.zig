//! noxc-nightly Aşama 2 (oracle): AST'nin TAM, kayıpsız ve kanonik dökümü — `ast.zig`deki HER alanı (yüzey-koruma bayrakları, `*Origin` yapıları, span'ler, ifade span'leri dahil)
//! comptime yansımasıyla yazar; böylece yeni bir alan eklendiğinde döküm otomatik kapsar ve Nox parser'ının çıktısı alan alan karşılaştırılabilir. Elle yazılan `ast_dump.zig`den (golden'lar için,
//! insan-okunur ve kasıtlı olarak özet) AYRIDIR.
//!
//! Biçim (Nox tarafının üreteceği biçimle birebir aynı olmak zorunda; `scripts/gen_selfhost_ast.py` bunu aynı tanımdan türetir):
//!   - yapı:        `{alan=değer alan=değer ...}` (bildirim sırasıyla)
//!   - birleşim:    `(etiket değer)` ya da yük yoksa `(etiket)`
//!   - dilim/dizi:  `[öğe öğe ...]` (`[]const u8` dizesi: `"..."` kaçışlı)
//!   - isteğe bağlı: `null` ya da değer
//!   - sayı: `i64`/`u32`/`usize` onluk; `f64` ham bit deseni `f64:0x<16 hex>` (biçim sapması yok)
//!   - enum: `.ad`; bool: `true`/`false`
//!   - her `Stmt` yeni bir satırda başlar; `Module.expr_spans` alanı DÖKÜLMEZ, bunun yerine ifade düğümünün adresi tabloda varsa değerin sonuna `@<başlangıç_satır>:<sütun>-<bitiş_satır>:<sütun>/<bayt>-<bayt>` eklenir.

const std = @import("std");
const ast = @import("ast.zig");

const Writer = std.Io.Writer;

pub fn dumpModuleFull(w: *Writer, module: ast.Module) Writer.Error!void {
    var d: Dumper = .{ .w = w, .spans = &module.expr_spans };
    try w.writeAll("{body=");
    try d.slice(ast.Stmt, module.body, 0);
    try w.writeAll(" exports=");
    try d.value([]const ast.ModuleExports, module.exports, 0);
    try w.writeAll("}\n");
}

const Dumper = struct {
    w: *Writer,
    spans: *const std.AutoHashMapUnmanaged(usize, @import("../span.zig").Span),

    fn spanSuffix(self: *Dumper, addr: usize) Writer.Error!void {
        if (self.spans.get(addr)) |s| {
            try self.w.print("@{d}:{d}-{d}:{d}/{d}-{d}", .{ s.start_line, s.start_col, s.end_line, s.end_col, s.start_byte, s.end_byte });
        }
    }

    fn str(self: *Dumper, s: []const u8) Writer.Error!void {
        try self.w.writeByte('"');
        for (s) |c| switch (c) {
            '"' => try self.w.writeAll("\\\""),
            '\\' => try self.w.writeAll("\\\\"),
            '\n' => try self.w.writeAll("\\n"),
            '\r' => try self.w.writeAll("\\r"),
            '\t' => try self.w.writeAll("\\t"),
            0...8, 11, 12, 14...31, 127 => try self.w.print("\\u00{x:0>2}", .{c}),
            else => try self.w.writeByte(c),
        };
        try self.w.writeByte('"');
    }

    fn slice(self: *Dumper, comptime T: type, items: []const T, depth: usize) Writer.Error!void {
        try self.w.writeByte('[');
        for (items, 0..) |*it, i| {
            if (T == ast.Stmt) {
                try self.w.writeByte('\n');
            } else if (i > 0) try self.w.writeByte(' ');
            try self.value(T, it.*, depth + 1);
            if (T == ast.Expr) try self.spanSuffix(@intFromPtr(it));
        }
        try self.w.writeByte(']');
    }

    fn value(self: *Dumper, comptime T: type, v: T, depth: usize) Writer.Error!void {
        switch (@typeInfo(T)) {
            .bool => try self.w.writeAll(if (v) "true" else "false"),
            .int => try self.w.print("{d}", .{v}),
            .float => try self.w.print("f64:0x{x:0>16}", .{@as(u64, @bitCast(@as(f64, v)))}),
            .@"enum" => try self.w.print(".{s}", .{@tagName(v)}),
            .void => {},
            .optional => |o| {
                if (v) |inner| try self.value(o.child, inner, depth) else try self.w.writeAll("null");
            },
            .pointer => |p| switch (p.size) {
                .slice => {
                    if (p.child == u8) {
                        try self.str(v);
                    } else {
                        try self.slice(p.child, v, depth);
                    }
                },
                .one => {
                    try self.value(p.child, v.*, depth);
                    if (p.child == ast.Expr) try self.spanSuffix(@intFromPtr(v));
                },
                else => @compileError("ast_dump_full: desteklenmeyen işaretçi türü " ++ @typeName(T)),
            },
            .@"struct" => |s| {
                try self.w.writeByte('{');
                inline for (s.fields, 0..) |f, i| {
                    if (i > 0) try self.w.writeByte(' ');
                    try self.w.print("{s}=", .{f.name});
                    try self.value(f.type, @field(v, f.name), depth + 1);
                }
                try self.w.writeByte('}');
            },
            .@"union" => {
                const tag = std.meta.activeTag(v);
                try self.w.print("({s}", .{@tagName(tag)});
                inline for (std.meta.fields(T)) |f| {
                    if (tag == @field(std.meta.Tag(T), f.name)) {
                        if (f.type != void) {
                            try self.w.writeByte(' ');
                            try self.value(f.type, @field(v, f.name), depth + 1);
                        }
                    }
                }
                try self.w.writeByte(')');
            },
            else => @compileError("ast_dump_full: desteklenmeyen tür " ++ @typeName(T)),
        }
    }
};
