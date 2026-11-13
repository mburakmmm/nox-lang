//! `@dataclass` ve `@derive(...)` (v2.1.110, TODO 5.2): sınıf bildirimindeki ALANLARDAN yardımcı metodların derleme zamanında üretilmesi.
//!
//! Mekanizma `@ffi.errors` sarmalayıcısıyla aynıdır: üretilecek metodların Nox KAYNAĞI metin olarak kurulur, normal sözcük çözümleyici/ayrıştırıcıdan geçer ve
//! sınıfın `methods` listesine eklenir. Böylece üretilen kod sıradan kod gibi tip denetimine girer (İlke 2: tipler yine zorunlu ve statik; yeni sözdizimi yok,
//! hiçbir şey çalışma zamanında üretilmez). Geçiş, `mixin_flatten` ve `class_attr_promote`tan SONRA, sınıf adları toplanmadan ÖNCE çalışır.
//!
//! Desteklenenler (alan = sınıf gövdesindeki çıplak `ad: tip` bildirimi, taban dataclass alanları önde):
//!   `@dataclass`          -> `__init__(self, alanlar...)`
//!   `@derive("order")`    -> `__lt__ __le__ __gt__ __ge__` (alanlara göre sözlüksel)
//!   `@derive("copy")`     -> `copy(self)` (sığ kopya; `@dataclass` gerekir)
//!   `@derive("json")`     -> `to_json`, `write_json`, `@staticmethod from_json`, `from_json_value` (`import nox.json` ve `@dataclass` gerekir)
//! Eşitlik (`==`), yazdırma (`str`/`repr`) ve karma ZATEN yapısal/varsayılan olduğundan türetilmez.

const std = @import("std");
const ast = @import("../parser/ast.zig");
const lexer_mod = @import("../lexer/lexer.zig");
const parser_mod = @import("../parser/parser.zig");

pub const Diag = struct { line: u32, message: []const u8 };

const Want = struct {
    dataclass: bool = false,
    order: bool = false,
    copy: bool = false,
    json: bool = false,
};

const Pass = struct {
    a: std.mem.Allocator,
    classes: std.StringHashMapUnmanaged(*ast.ClassDef) = .empty,
    wants: std.StringHashMapUnmanaged(Want) = .empty,
    /// sınıf adı -> tüm alanlar (taban dataclass alanları önde); yalnızca işlenmiş dataclass'lar
    all_fields: std.StringHashMapUnmanaged([]const ast.FieldDecl) = .empty,
    done: std.StringHashMapUnmanaged(void) = .empty,
    json_imported: bool = false,
    diag: ?Diag = null,
    counter: usize = 0,

    fn next(self: *Pass) usize {
        self.counter += 1;
        return self.counter;
    }

    fn fail(self: *Pass, line: u32, comptime fmt: []const u8, args: anytype) error{Derive} {
        self.diag = .{ .line = line, .message = std.fmt.allocPrint(self.a, fmt, args) catch "derive error" };
        return error.Derive;
    }
};

const SrcBuf = struct {
    a: std.mem.Allocator,
    list: std.ArrayListUnmanaged(u8) = .empty,

    fn line(self: *SrcBuf, indent: usize, comptime fmt: []const u8, args: anytype) !void {
        for (0..indent) |_| try self.list.appendSlice(self.a, "    ");
        try self.list.appendSlice(self.a, try std.fmt.allocPrint(self.a, fmt, args));
        try self.list.append(self.a, '\n');
    }
};

fn typeText(p: *Pass, t: ast.TypeExpr, line: u32) anyerror![]const u8 {
    switch (t) {
        .simple => |n| return n,
        .generic => |g| {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            try buf.appendSlice(p.a, g.name);
            try buf.append(p.a, '[');
            for (g.args, 0..) |x, i| {
                if (i > 0) try buf.appendSlice(p.a, ", ");
                try buf.appendSlice(p.a, try typeText(p, x, line));
            }
            try buf.append(p.a, ']');
            return buf.items;
        },
        .qualified => |segs| {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            for (segs, 0..) |sg, i| {
                if (i > 0) try buf.append(p.a, '.');
                try buf.appendSlice(p.a, sg);
            }
            return buf.items;
        },
        .optional => |inner| return try std.fmt.allocPrint(p.a, "{s} | None", .{try typeText(p, inner.*, line)}),
        .func_type => return p.fail(line, "a function-typed field cannot be used with @dataclass/@derive", .{}),
    }
}

fn isScalar(n: []const u8) bool {
    return std.mem.eql(u8, n, "int") or std.mem.eql(u8, n, "float") or std.mem.eql(u8, n, "bool") or std.mem.eql(u8, n, "str");
}

fn decoratorWants(p: *Pass, cd: *const ast.ClassDef) !Want {
    var w: Want = .{};
    for (cd.decorators) |dec| {
        if (std.mem.eql(u8, dec.name, "dataclass")) {
            if (dec.args.len != 0) return p.fail(dec.line, "@dataclass takes no arguments (class {s})", .{cd.name});
            w.dataclass = true;
        } else if (std.mem.eql(u8, dec.name, "derive")) {
            if (dec.args.len == 0) return p.fail(dec.line, "@derive needs at least one name: \"order\", \"copy\" or \"json\" (class {s})", .{cd.name});
            for (dec.args) |arg| {
                if (arg != .string_lit) return p.fail(dec.line, "@derive arguments must be string literals (class {s})", .{cd.name});
                const n = arg.string_lit;
                if (std.mem.eql(u8, n, "order")) w.order = true else if (std.mem.eql(u8, n, "copy")) w.copy = true else if (std.mem.eql(u8, n, "json")) w.json = true else if (std.mem.eql(u8, n, "eq") or std.mem.eql(u8, n, "repr") or std.mem.eql(u8, n, "str") or std.mem.eql(u8, n, "hash")) {
                    return p.fail(dec.line, "@derive(\"{s}\") is not needed: == and printing are already structural for every class (class {s})", .{ n, cd.name });
                } else return p.fail(dec.line, "unknown @derive name \"{s}\" (known: \"order\", \"copy\", \"json\"; class {s})", .{ n, cd.name });
            }
        }
    }
    return w;
}

fn hasMethod(cd: *const ast.ClassDef, name: []const u8) bool {
    for (cd.methods) |m| if (std.mem.eql(u8, m.name, name)) return true;
    return false;
}

// ------------------------------------------------------------------ JSON kod üreticileri

/// `E` ifadesini (tipi `t`) JsonWriter `w`ye yazan deyimler.
fn genWrite(p: *Pass, s: *SrcBuf, indent: usize, e: []const u8, t: ast.TypeExpr, depth: usize, line: u32) anyerror!void {
    _ = depth;
    const id = p.next();
    switch (t) {
        .simple => |n| {
            if (std.mem.eql(u8, n, "int")) return s.line(indent, "w.write_int({s})", .{e});
            if (std.mem.eql(u8, n, "float")) return s.line(indent, "w.write_float({s})", .{e});
            if (std.mem.eql(u8, n, "bool")) return s.line(indent, "w.write_bool({s})", .{e});
            if (std.mem.eql(u8, n, "str")) return s.line(indent, "w.write_string({s})", .{e});
            const w = p.wants.get(n) orelse return p.fail(line, "@derive(\"json\"): field type '{s}' is not a basic type and has no @derive(\"json\")", .{n});
            if (!w.json) return p.fail(line, "@derive(\"json\"): field type '{s}' needs @derive(\"json\") too", .{n});
            return s.line(indent, "{s}.write_json(w)", .{e});
        },
        .generic => |g| {
            if (std.mem.eql(u8, g.name, "list") and g.args.len == 1) {
                try s.line(indent, "w.begin_array()", .{});
                try s.line(indent, "for __e{d} in {s}:", .{ id, e });
                const ev = try std.fmt.allocPrint(p.a, "__e{d}", .{id});
                try genWrite(p, s, indent + 1, ev, g.args[0], 0, line);
                try s.line(indent, "w.end_array()", .{});
                return;
            }
            if (std.mem.eql(u8, g.name, "dict") and g.args.len == 2 and g.args[0] == .simple and std.mem.eql(u8, g.args[0].simple, "str")) {
                try s.line(indent, "w.begin_object()", .{});
                try s.line(indent, "for __k{d}, __v{d} in {s}.items():", .{ id, id, e });
                try s.line(indent + 1, "w.write_key(__k{d})", .{id});
                const vv = try std.fmt.allocPrint(p.a, "__v{d}", .{id});
                try genWrite(p, s, indent + 1, vv, g.args[1], 0, line);
                try s.line(indent, "w.end_object()", .{});
                return;
            }
            return p.fail(line, "@derive(\"json\"): unsupported field type {s}[...] (supported: int, float, bool, str, list[T], dict[str, T], T | None, and classes with @derive(\"json\"))", .{g.name});
        },
        .optional => |inner| {
            const tt = try typeText(p, inner.*, line);
            try s.line(indent, "__o{d}: {s} | None = {s}", .{ id, tt, e });
            try s.line(indent, "if __o{d} is None:", .{id});
            try s.line(indent + 1, "w.write_null()", .{});
            try s.line(indent, "else:", .{});
            const ov = try std.fmt.allocPrint(p.a, "__o{d}", .{id});
            try genWrite(p, s, indent + 1, ov, inner.*, 0, line);
        },
        else => return p.fail(line, "@derive(\"json\"): unsupported field type", .{}),
    }
}

/// `E` (bir JsonValue ifadesi) okunup `target` adlı, tipi `t` olan YENİ yerele atanır (deyimler).
fn genRead(p: *Pass, s: *SrcBuf, indent: usize, target: []const u8, e: []const u8, t: ast.TypeExpr, depth: usize, line: u32) anyerror!void {
    _ = depth;
    const id = p.next();
    const tt = try typeText(p, t, line);
    switch (t) {
        .simple => |n| {
            if (std.mem.eql(u8, n, "int")) return s.line(indent, "{s}: int = nox.json.read_int({s})", .{ target, e });
            if (std.mem.eql(u8, n, "float")) return s.line(indent, "{s}: float = nox.json.read_float({s})", .{ target, e });
            if (std.mem.eql(u8, n, "bool")) return s.line(indent, "{s}: bool = nox.json.read_bool({s})", .{ target, e });
            if (std.mem.eql(u8, n, "str")) return s.line(indent, "{s}: str = nox.json.read_str({s})", .{ target, e });
            const w = p.wants.get(n) orelse return p.fail(line, "@derive(\"json\"): field type '{s}' is not a basic type and has no @derive(\"json\")", .{n});
            if (!w.json) return p.fail(line, "@derive(\"json\"): field type '{s}' needs @derive(\"json\") too", .{n});
            return s.line(indent, "{s}: {s} = {s}.from_json_value({s})", .{ target, n, n, e });
        },
        .generic => |g| {
            if (std.mem.eql(u8, g.name, "list") and g.args.len == 1) {
                try s.line(indent, "__lv{d}: JsonValue = {s}", .{ id, e });
                try s.line(indent, "nox.json.expect_array(__lv{d})", .{id});
                try s.line(indent, "{s}: {s} = []", .{ target, tt });
                try s.line(indent, "__i{d}: int = 0", .{id});
                try s.line(indent, "while __i{d} < nox.json.array_len(__lv{d}):", .{ id, id });
                const xv = try std.fmt.allocPrint(p.a, "__x{d}", .{id});
                const get = try std.fmt.allocPrint(p.a, "nox.json.array_get(__lv{d}, __i{d})", .{ id, id });
                try genRead(p, s, indent + 1, xv, get, g.args[0], 0, line);
                try s.line(indent + 1, "{s}.append({s})", .{ target, xv });
                try s.line(indent + 1, "__i{d} += 1", .{id});
                return;
            }
            if (std.mem.eql(u8, g.name, "dict") and g.args.len == 2 and g.args[0] == .simple and std.mem.eql(u8, g.args[0].simple, "str")) {
                try s.line(indent, "__dv{d}: JsonValue = {s}", .{ id, e });
                try s.line(indent, "nox.json.expect_object(__dv{d}, \"dict\")", .{id});
                try s.line(indent, "{s}: {s} = {{}}", .{ target, tt });
                try s.line(indent, "__j{d}: int = 0", .{id});
                try s.line(indent, "while __j{d} < nox.json.object_len(__dv{d}):", .{ id, id });
                const xv = try std.fmt.allocPrint(p.a, "__x{d}", .{id});
                const get = try std.fmt.allocPrint(p.a, "nox.json.object_value(__dv{d}, __j{d})", .{ id, id });
                try genRead(p, s, indent + 1, xv, get, g.args[1], 0, line);
                try s.line(indent + 1, "{s}[nox.json.object_key(__dv{d}, __j{d})] = {s}", .{ target, id, id, xv });
                try s.line(indent + 1, "__j{d} += 1", .{id});
                return;
            }
            return p.fail(line, "@derive(\"json\"): unsupported field type {s}[...]", .{g.name});
        },
        .optional => |inner| {
            try s.line(indent, "__ov{d}: JsonValue = {s}", .{ id, e });
            try s.line(indent, "{s}: {s} = None", .{ target, tt });
            try s.line(indent, "if not nox.json.is_null(__ov{d}):", .{id});
            const xv = try std.fmt.allocPrint(p.a, "__x{d}", .{id});
            const ov = try std.fmt.allocPrint(p.a, "__ov{d}", .{id});
            try genRead(p, s, indent + 1, xv, ov, inner.*, 0, line);
            try s.line(indent + 1, "{s} = {s}", .{ target, xv });
        },
        else => return p.fail(line, "@derive(\"json\"): unsupported field type", .{}),
    }
}

// ------------------------------------------------------------------ sınıf genişletmesi

fn expandClass(p: *Pass, cd: *ast.ClassDef, line: u32) anyerror!void {
    if (p.done.contains(cd.name)) return;
    try p.done.put(p.a, cd.name, {});
    const w = p.wants.get(cd.name) orelse return;
    if (cd.type_params.len > 0) return p.fail(line, "@dataclass/@derive cannot be used on a generic class ({s})", .{cd.name});
    if (cd.enum_variants.len > 0) return p.fail(line, "@dataclass/@derive cannot be used on an enum ({s})", .{cd.name});

    // alanlar: taban dataclass'ın alanları önde
    var fields: std.ArrayListUnmanaged(ast.FieldDecl) = .empty;
    var base_has_dc = false;
    if (cd.base) |bn| {
        if (p.classes.get(bn)) |bc| {
            if (p.wants.get(bn)) |bw| {
                if (bw.dataclass) {
                    try expandClass(p, bc, line);
                    if (p.all_fields.get(bn)) |bf| try fields.appendSlice(p.a, bf);
                    base_has_dc = true;
                }
            }
        }
    }
    if (cd.base != null and !base_has_dc and w.dataclass) {
        return p.fail(line, "@dataclass class {s}: its base class '{s}' must also be a @dataclass", .{ cd.name, cd.base.? });
    }
    for (cd.fields) |f| {
        for (fields.items) |g| if (std.mem.eql(u8, g.name, f.name)) return p.fail(line, "@dataclass class {s}: field '{s}' repeats a field of its base class", .{ cd.name, f.name });
        try fields.append(p.a, f);
    }
    const own_start = fields.items.len - cd.fields.len;
    if (w.dataclass) {
        try p.all_fields.put(p.a, cd.name, fields.items);
        if (hasMethod(cd, "__init__")) return p.fail(line, "@dataclass class {s} must not define __init__ (the compiler generates it)", .{cd.name});
        if (fields.items.len == 0) return p.fail(line, "@dataclass class {s} has no fields (declare them as `name: type` lines in the class body)", .{cd.name});
    } else if (w.order or w.copy or w.json) {
        // alanlar: yalnızca bu sınıfın çıplak bildirimleri (+ taban dataclass alanları); __init__ elle yazılmışsa yalnızca order
        if (fields.items.len == 0) return p.fail(line, "@derive on class {s} needs fields declared as `name: type` lines in the class body", .{cd.name});
        try p.all_fields.put(p.a, cd.name, fields.items);
    }
    if ((w.copy or w.json) and !w.dataclass) return p.fail(line, "@derive(\"copy\"/\"json\") on class {s} needs @dataclass as well (it rebuilds the object through the generated __init__)", .{cd.name});
    if (w.json and !p.json_imported) return p.fail(line, "@derive(\"json\") on class {s} needs `import nox.json`", .{cd.name});

    var s: SrcBuf = .{ .a = p.a };
    try s.line(0, "class __Stub:", .{});
    if (w.dataclass) {
        var params: std.ArrayListUnmanaged(u8) = .empty;
        for (fields.items) |f| {
            try params.appendSlice(p.a, ", ");
            try params.appendSlice(p.a, try std.fmt.allocPrint(p.a, "{s}: {s}", .{ f.name, try typeText(p, f.type_expr, line) }));
        }
        try s.line(1, "def __init__(self{s}) -> None:", .{params.items});
        if (base_has_dc) {
            var call: std.ArrayListUnmanaged(u8) = .empty;
            for (fields.items[0..own_start], 0..) |f, i| {
                if (i > 0) try call.appendSlice(p.a, ", ");
                try call.appendSlice(p.a, f.name);
            }
            try s.line(2, "super().__init__({s})", .{call.items});
        }
        for (fields.items[own_start..]) |f| try s.line(2, "self.{s} = {s}", .{ f.name, f.name });
    }
    if (w.order) {
        for ([_][]const u8{ "__lt__", "__le__", "__gt__", "__ge__" }) |m| if (hasMethod(cd, m)) return p.fail(line, "class {s} defines {s} itself: remove @derive(\"order\") or the method", .{ cd.name, m });
        for (fields.items) |f| {
            const ok = switch (f.type_expr) {
                .simple => true, // int/float/bool/str ya da bir sınıf (kendi sıralaması varsa)
                else => false,
            };
            if (!ok) return p.fail(line, "@derive(\"order\") class {s}: field '{s}' has a type that cannot be ordered (use int, float, bool, str or an orderable class)", .{ cd.name, f.name });
        }
        try s.line(1, "def __lt__(self, o: {s}) -> bool:", .{cd.name});
        for (fields.items) |f| {
            try s.line(2, "if self.{s} != o.{s}:", .{ f.name, f.name });
            try s.line(3, "return self.{s} < o.{s}", .{ f.name, f.name });
        }
        try s.line(2, "return False", .{});
        try s.line(1, "def __le__(self, o: {s}) -> bool:", .{cd.name});
        try s.line(2, "return not (o < self)", .{});
        try s.line(1, "def __gt__(self, o: {s}) -> bool:", .{cd.name});
        try s.line(2, "return o < self", .{});
        try s.line(1, "def __ge__(self, o: {s}) -> bool:", .{cd.name});
        try s.line(2, "return not (self < o)", .{});
    }
    if (w.copy) {
        if (hasMethod(cd, "copy")) return p.fail(line, "class {s} defines copy itself: remove @derive(\"copy\") or the method", .{cd.name});
        var args: std.ArrayListUnmanaged(u8) = .empty;
        for (fields.items, 0..) |f, i| {
            if (i > 0) try args.appendSlice(p.a, ", ");
            try args.appendSlice(p.a, try std.fmt.allocPrint(p.a, "self.{s}", .{f.name}));
        }
        try s.line(1, "def copy(self) -> {s}:", .{cd.name});
        try s.line(2, "return {s}({s})", .{ cd.name, args.items });
    }
    if (w.json) {
        for ([_][]const u8{ "to_json", "write_json", "from_json", "from_json_value" }) |m| if (hasMethod(cd, m)) return p.fail(line, "class {s} defines {s} itself: remove @derive(\"json\") or the method", .{ cd.name, m });
        try s.line(1, "def write_json(self, w: nox.json.JsonWriter) -> None:", .{});
        try s.line(2, "w.begin_object()", .{});
        for (fields.items) |f| {
            try s.line(2, "w.write_key(\"{s}\")", .{f.name});
            const e = try std.fmt.allocPrint(p.a, "self.{s}", .{f.name});
            try genWrite(p, &s, 2, e, f.type_expr, 1, line);
        }
        try s.line(2, "w.end_object()", .{});
        try s.line(1, "def to_json(self) -> str:", .{});
        try s.line(2, "w: nox.json.JsonWriter = nox.json.JsonWriter()", .{});
        try s.line(2, "self.write_json(w)", .{});
        try s.line(2, "return w.build()", .{});
        try s.line(1, "@staticmethod", .{});
        try s.line(1, "def from_json_value(v: JsonValue) -> {s}:", .{cd.name});
        try s.line(2, "nox.json.expect_object(v, \"{s}\")", .{cd.name});
        var ctor: std.ArrayListUnmanaged(u8) = .empty;
        for (fields.items, 0..) |f, i| {
            const tgt = try std.fmt.allocPrint(p.a, "__f{d}", .{i});
            const getter: []const u8 = if (f.type_expr == .optional) "get_or_null" else "get";
            const e = try std.fmt.allocPrint(p.a, "nox.json.{s}(v, \"{s}\")", .{ getter, f.name });
            try genRead(p, &s, 2, tgt, e, f.type_expr, 1, line);
            if (i > 0) try ctor.appendSlice(p.a, ", ");
            try ctor.appendSlice(p.a, tgt);
        }
        try s.line(2, "return {s}({s})", .{ cd.name, ctor.items });
        try s.line(1, "@staticmethod", .{});
        try s.line(1, "def from_json(s: str) -> {s}:", .{cd.name});
        try s.line(2, "return {s}.from_json_value(nox.json.parse(s))", .{cd.name});
    }
    if (std.mem.endsWith(u8, s.list.items, "class __Stub:\n")) return; // üretilecek bir şey yok

    const toks = lexer_mod.tokenize(p.a, s.list.items) catch return p.fail(line, "internal: could not build the derived methods of {s}", .{cd.name});
    const m = parser_mod.parseModule(p.a, toks) catch return p.fail(line, "internal: could not parse the derived methods of {s}:\n{s}", .{ cd.name, s.list.items });
    if (m.body.len != 1 or m.body[0].kind != .class_def) return p.fail(line, "internal: derived methods of {s} did not parse as one class", .{cd.name});
    const stub = m.body[0].kind.class_def;
    // ayrıştırıcı `self`i kapsayan (geçici) sınıf adına bağladı: gerçek sınıfa çevir
    for (stub.methods) |sm| {
        if (sm.params.len > 0 and sm.params[0].self_inferred) sm.params[0].type_expr = .{ .simple = cd.name };
    }
    const merged = try p.a.alloc(ast.FuncDef, cd.methods.len + stub.methods.len);
    @memcpy(merged[0..cd.methods.len], cd.methods);
    @memcpy(merged[cd.methods.len..], stub.methods);
    cd.methods = merged;
}

/// Modül gövdesindeki `@dataclass`/`@derive` sınıflarını genişletir. Kullanıcı hatasında `Diag` döner.
pub fn run(a: std.mem.Allocator, body: []ast.Stmt) std.mem.Allocator.Error!?Diag {
    var p: Pass = .{ .a = a };
    for (body) |*stmt| {
        switch (stmt.kind) {
            .import_stmt => |imp| {
                if (imp.segments.len == 2 and std.mem.eql(u8, imp.segments[0], "nox") and std.mem.eql(u8, imp.segments[1], "json") and imp.alias == null) p.json_imported = true;
            },
            .class_def => |*cd| {
                try p.classes.put(a, cd.name, @constCast(cd));
            },
            else => {},
        }
    }
    // bildirimler
    var any = false;
    for (body) |*stmt| {
        if (stmt.kind != .class_def) continue;
        const cd = &stmt.kind.class_def;
        if (cd.decorators.len == 0) continue;
        const w = decoratorWants(&p, cd) catch return p.diag;
        if (w.dataclass or w.order or w.copy or w.json) {
            try p.wants.put(a, cd.name, w);
            any = true;
        }
    }
    if (!any) return null;
    for (body) |*stmt| {
        if (stmt.kind != .class_def) continue;
        const cd = &stmt.kind.class_def;
        expandClass(&p, cd, stmt.line) catch |e| switch (e) {
            error.Derive => return p.diag,
            else => return error.OutOfMemory,
        };
    }
    return null;
}

test "dataclass + order + copy üretilir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\@dataclass
        \\@derive("order", "copy")
        \\class P:
        \\    x: int
        \\    name: str
        \\
    ;
    const toks = try lexer_mod.tokenize(a, src);
    const m = try parser_mod.parseModule(a, toks);
    const d = try run(a, m.body);
    try std.testing.expect(d == null);
    const cd = m.body[0].kind.class_def;
    var names: [8][]const u8 = undefined;
    for (cd.methods, 0..) |mm, i| names[i] = mm.name;
    try std.testing.expectEqual(@as(usize, 6), cd.methods.len);
    try std.testing.expectEqualStrings("__init__", names[0]);
    try std.testing.expectEqualStrings("__lt__", names[1]);
    try std.testing.expectEqualStrings("copy", names[5]);
}

test "bilinmeyen derive adı ve elle __init__ hata verir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        const toks = try lexer_mod.tokenize(a, "@derive(\"nope\")\nclass P:\n    x: int\n");
        const m = try parser_mod.parseModule(a, toks);
        const d = try run(a, m.body);
        try std.testing.expect(d != null);
        try std.testing.expect(std.mem.indexOf(u8, d.?.message, "unknown @derive name") != null);
    }
    {
        const toks = try lexer_mod.tokenize(a, "@dataclass\nclass P:\n    x: int\n    def __init__(self) -> None:\n        self.x = 1\n");
        const m = try parser_mod.parseModule(a, toks);
        const d = try run(a, m.body);
        try std.testing.expect(d != null);
        try std.testing.expect(std.mem.indexOf(u8, d.?.message, "must not define __init__") != null);
    }
}
