//! UR-008 (NoxPy, v2.2.86): `--host-abi` ile `T | None`, `list[T]`, `dict[K, V]`, `tuple[...]` parametre/dönüş desteği.
//!
//! Strateji: `@export` işlevlerinin imzasında bir konteyner/Optional varsa, kullanıcı kaynağının SONUNA saf Nox kaynağı olarak bir ADAPTÖR eklenir
//! (`nox_host_adapt_<ad>`): konteyner parametreleri `NoxHostValue` handle'ı (`int`) olarak alınır, `runtime/host.zig`'in `nox_hv_*` ilkelleriyle Nox'un KENDİ list/dict/Optional/tuple
//! değerlerine çevrilir, gerçek işlev çağrılır, sonuç aynı yolla yeni bir handle'a çevrilir. Böylece list/dict/Optional/tuple'ın iç bellek düzenini bilen tek taraf Nox'un kendi codegen'idir
//! (İlke #4: düzen hiçbir yerde sızmaz; QBE ve LLVM aynı sentez kaynağını derler). C sarmalayıcısı (`host_abi.zig`) adaptörü çağırır ve dışa açık sembol YİNE `nox_host_export_<modül>_<ad>`dır.
//!
//! Desteklenen eleman tipleri: `int`, `float`, `bool`, `str`, `bytes`, bunların `T | None`'ı ve iç içe `list`/`dict`(anahtar skaler)/`tuple`. Sınıf örnekleri kapsayıcı İÇİNDE desteklenmez
//! (üst-düzey sınıf parametreleri `NoxHostHandle` olarak çalışmaya devam eder). Dönüşte tür/handle hataları `ValueError` olarak (`NOX_HOST_ERR_EXCEPTION`) döner.

const std = @import("std");
const ast = @import("parser/ast.zig");

pub const Result = union(enum) {
    /// Hiçbir `@export` konteyner/Optional içermiyor: kaynak değişmez.
    none,
    /// Kaynağın sonuna eklenecek Nox metni.
    text: []const u8,
    /// Kullanıcıya gösterilecek hata iletisi.
    err: []const u8,
};

/// Adaptörün adı (`collectHostExports` ve `expand` aynı kuralı kullanır).
pub fn adapterName(a: std.mem.Allocator, export_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "nox_host_adapt_{s}", .{export_name});
}

/// `T | None`, `list[...]`, `dict[...]`, `tuple[...]` konteyner/Optional mi?
pub fn isContainerish(te: ast.TypeExpr) bool {
    return switch (te) {
        .optional => true,
        .generic => |g| std.mem.eql(u8, g.name, "list") or std.mem.eql(u8, g.name, "dict") or std.mem.eql(u8, g.name, "tuple"),
        else => false,
    };
}

fn isScalarName(n: []const u8) bool {
    return std.mem.eql(u8, n, "int") or std.mem.eql(u8, n, "float") or std.mem.eql(u8, n, "bool") or std.mem.eql(u8, n, "str") or std.mem.eql(u8, n, "bytes");
}

/// Desteklenen tip mi? `nested`: bir kapsayıcının ELEMANI mı? Nox codegen'i kapsayıcı eleman olarak `int | None`/`float | None`/`bool | None` (kutulanmış skaler) derleyemez
/// (`list[int | None]`, `dict[str, int | None]`, `tuple[int | None, str]`: dil sınırı); üst-düzey parametre/dönüşte ve heap tipli (`str`/`bytes`/konteyner) Optional elemanlarda sorun yoktur.
fn validElem(te: ast.TypeExpr, nested: bool, cls: *const ClassSet) bool {
    switch (te) {
        .simple => |n| return isScalarName(n) or cls.contains(n),
        .optional => |inner| {
            if (inner.* == .optional) return false;
            if (nested and inner.* == .simple and isScalarName(inner.simple) and !(std.mem.eql(u8, inner.simple, "str") or std.mem.eql(u8, inner.simple, "bytes"))) return false;
            return validElem(inner.*, nested, cls);
        },
        .generic => |g| {
            if (std.mem.eql(u8, g.name, "list")) return g.args.len == 1 and validElem(g.args[0], true, cls);
            if (std.mem.eql(u8, g.name, "dict")) return g.args.len == 2 and g.args[0] == .simple and isScalarName(g.args[0].simple) and validElem(g.args[1], true, cls);
            if (std.mem.eql(u8, g.name, "tuple")) {
                if (g.args.len == 0) return false;
                for (g.args) |x| if (!validElem(x, true, cls)) return false;
                return true;
            }
            return false;
        },
        else => return false,
    }
}

/// Modülün üst-düzey (jenerik/enum olmayan) sınıf adları: kapsayıcı içinde `NOX_HOST_VALUE_HANDLE` olarak geçebilirler (UR-009).
const ClassSet = std.StringHashMapUnmanaged(void);

fn collectClassSet(a: std.mem.Allocator, module: ast.Module) !ClassSet {
    var set: ClassSet = .empty;
    for (module.body) |stmt| {
        if (stmt.kind != .class_def) continue;
        const cd = stmt.kind.class_def;
        if (cd.type_params.len > 0 or cd.enum_variants.len > 0) continue;
        try set.put(a, cd.name, {});
    }
    return set;
}

/// Tip ifadesinin kanonik yüzey yazımı (yalnızca adaptörün desteklediği biçimler); desteklenmeyen biçimde `false`.
fn typeText(a: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), te: ast.TypeExpr) std.mem.Allocator.Error!bool {
    switch (te) {
        .simple => |n| {
            try buf.appendSlice(a, n);
            return true;
        },
        .optional => |inner| {
            if (!try typeText(a, buf, inner.*)) return false;
            try buf.appendSlice(a, " | None");
            return true;
        },
        .generic => |g| {
            try buf.appendSlice(a, g.name);
            try buf.append(a, '[');
            for (g.args, 0..) |x, i| {
                if (i > 0) try buf.appendSlice(a, ", ");
                if (!try typeText(a, buf, x)) return false;
            }
            try buf.append(a, ']');
            return true;
        },
        .qualified => |segs| {
            for (segs, 0..) |sg, i| {
                if (i > 0) try buf.append(a, '.');
                try buf.appendSlice(a, sg);
            }
            return true;
        },
        else => return false,
    }
}

fn textOf(a: std.mem.Allocator, te: ast.TypeExpr) std.mem.Allocator.Error!?[]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    if (!try typeText(a, &buf, te)) return null;
    return buf.items;
}

const Synth = struct {
    a: std.mem.Allocator,
    classes: *const ClassSet,
    /// Adaptörlerde kullanılan sınıflar (ilk kullanım sırası): her biri için `nox_hv_obj_<Sınıf>`/`nox_hv_new_obj_<Sınıf>` extern bildirimi eklenir; sembolleri `--host-abi` kod üreteci sağlar.
    used_classes: std.ArrayListUnmanaged([]const u8) = .empty,
    helpers: std.ArrayListUnmanaged(u8) = .empty,
    in_memo: std.StringHashMapUnmanaged([]const u8) = .empty,
    out_memo: std.StringHashMapUnmanaged([]const u8) = .empty,
    get_memo: std.StringHashMapUnmanaged([]const u8) = .empty,
    next: u32 = 0,

    fn p(self: *Synth, buf: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.a, fmt, args);
        try buf.appendSlice(self.a, s);
    }

    fn noteClass(self: *Synth, n: []const u8) !void {
        for (self.used_classes.items) |c| if (std.mem.eql(u8, c, n)) return;
        try self.used_classes.append(self.a, n);
    }

    fn fresh(self: *Synth, prefix: []const u8) ![]const u8 {
        const id = self.next;
        self.next += 1;
        return std.fmt.allocPrint(self.a, "{s}{d}", .{ prefix, id });
    }

    /// `(h: int) -> T` — handle'ı (BORÇLU) Nox değerine çeviren yardımcının adı.
    fn inName(self: *Synth, te: ast.TypeExpr) std.mem.Allocator.Error![]const u8 {
        const ty = (try textOf(self.a, te)).?;
        if (self.in_memo.get(ty)) |n| return n;
        const name = try self.fresh("nox_hin_");
        try self.in_memo.put(self.a, ty, name);
        var d: std.ArrayListUnmanaged(u8) = .empty;
        switch (te) {
            .simple => |n| {
                if (self.classes.contains(n)) {
                    try self.noteClass(n);
                    try self.p(&d, "def {s}(h: int) -> {s}:\n    nox_host_expect(h, 9, \"handle\")\n    if nox_hv_class_is(h, \"{s}\") == 0:\n        raise ValueError(\"expected a {s} handle (subclass instances are not accepted inside containers)\")\n    return nox_hv_obj_{s}(h)\n\n", .{ name, n, n, n, n });
                } else if (std.mem.eql(u8, n, "int")) {
                    try self.p(&d, "def {s}(h: int) -> int:\n    nox_host_expect(h, 1, \"int\")\n    return nox_hv_int(h)\n\n", .{name});
                } else if (std.mem.eql(u8, n, "float")) {
                    try self.p(&d, "def {s}(h: int) -> float:\n    nox_host_expect(h, 2, \"float\")\n    return nox_hv_float(h)\n\n", .{name});
                } else if (std.mem.eql(u8, n, "bool")) {
                    try self.p(&d, "def {s}(h: int) -> bool:\n    nox_host_expect(h, 3, \"bool\")\n    return nox_hv_int(h) != 0\n\n", .{name});
                } else if (std.mem.eql(u8, n, "str")) {
                    try self.p(&d, "def {s}(h: int) -> str:\n    nox_host_expect(h, 4, \"str\")\n    return nox_hv_str(h)\n\n", .{name});
                } else {
                    try self.p(&d, "def {s}(h: int) -> bytes:\n    nox_host_expect(h, 5, \"bytes\")\n    return nox_hv_bytes(h)\n\n", .{name});
                }
            },
            .optional => |inner| {
                const f = try self.inName(inner.*);
                try self.p(&d, "def {s}(h: int) -> {s}:\n    if nox_hv_kind(h) == 0:\n        return None\n    return {s}(h)\n\n", .{ name, ty, f });
            },
            .generic => |g| {
                if (std.mem.eql(u8, g.name, "list")) {
                    const get = try self.getName(0, g.args[0]);
                    try self.p(&d, "def {s}(h: int) -> {s}:\n    nox_host_expect(h, 6, \"list\")\n    out: {s} = []\n    cnt: int = nox_hv_len(h)\n    for i in range(cnt):\n        out.append({s}(h, i))\n    return out\n\n", .{ name, ty, ty, get });
                } else if (std.mem.eql(u8, g.name, "dict")) {
                    const kget = try self.getName(1, g.args[0]);
                    const vget = try self.getName(2, g.args[1]);
                    try self.p(&d, "def {s}(h: int) -> {s}:\n    nox_host_expect(h, 7, \"dict\")\n    out: {s} = {{}}\n    cnt: int = nox_hv_len(h)\n    for i in range(cnt):\n        out[{s}(h, i)] = {s}(h, i)\n    return out\n\n", .{ name, ty, ty, kget, vget });
                } else {
                    try self.p(&d, "def {s}(h: int) -> {s}:\n    nox_host_expect(h, 8, \"tuple\")\n    if nox_hv_len(h) != {d}:\n        raise ValueError(\"expected a tuple of {d} items\")\n    return (", .{ name, ty, g.args.len, g.args.len });
                    for (g.args, 0..) |x, i| {
                        const get = try self.getName(0, x);
                        if (i > 0) try d.appendSlice(self.a, ", ");
                        try self.p(&d, "{s}(h, {d})", .{ get, i });
                    }
                    if (g.args.len == 1) try d.append(self.a, ',');
                    try d.appendSlice(self.a, ")\n\n");
                }
            },
            else => unreachable,
        }
        try self.helpers.appendSlice(self.a, d.items);
        return name;
    }

    /// `(h: int, i: int) -> T` — kapsayıcının `i`inci elemanını (`which`: 0 eleman, 1 anahtar, 2 değer) çevirir ve ara handle'ı bırakır.
    fn getName(self: *Synth, which: u8, te: ast.TypeExpr) std.mem.Allocator.Error![]const u8 {
        const ty = (try textOf(self.a, te)).?;
        const key = try std.fmt.allocPrint(self.a, "{d}:{s}", .{ which, ty });
        if (self.get_memo.get(key)) |n| return n;
        const name = try self.fresh("nox_hget_");
        try self.get_memo.put(self.a, key, name);
        const conv = try self.inName(te);
        const prim: []const u8 = switch (which) {
            0 => "nox_hv_item",
            1 => "nox_hv_key",
            else => "nox_hv_val",
        };
        var d: std.ArrayListUnmanaged(u8) = .empty;
        try self.p(&d, "def {s}(h: int, i: int) -> {s}:\n    c: int = {s}(h, i)\n    try:\n        return {s}(c)\n    finally:\n        nox_hv_release(c)\n\n", .{ name, ty, prim, conv });
        try self.helpers.appendSlice(self.a, d.items);
        return name;
    }

    /// `(v: T) -> int` — Nox değerini YENİ bir handle'a çeviren yardımcının adı.
    fn outName(self: *Synth, te: ast.TypeExpr) std.mem.Allocator.Error![]const u8 {
        const ty = (try textOf(self.a, te)).?;
        if (self.out_memo.get(ty)) |n| return n;
        const name = try self.fresh("nox_hout_");
        try self.out_memo.put(self.a, ty, name);
        var d: std.ArrayListUnmanaged(u8) = .empty;
        switch (te) {
            .simple => |n| {
                if (self.classes.contains(n)) {
                    try self.noteClass(n);
                    try self.p(&d, "def {s}(v: {s}) -> int:\n    return nox_hv_new_obj_{s}(v)\n\n", .{ name, n, n });
                    try self.helpers.appendSlice(self.a, d.items);
                    return name;
                }
                const body: []const u8 = if (std.mem.eql(u8, n, "int")) "nox_hv_new_int(v)" else if (std.mem.eql(u8, n, "float")) "nox_hv_new_float(v)" else if (std.mem.eql(u8, n, "bool")) "nox_hv_new_bool(int(v))" else if (std.mem.eql(u8, n, "str")) "nox_hv_new_str(v)" else "nox_hv_new_bytes(v)";
                try self.p(&d, "def {s}(v: {s}) -> int:\n    return {s}\n\n", .{ name, ty, body });
            },
            .optional => |inner| {
                const f = try self.outName(inner.*);
                try self.p(&d, "def {s}(v: {s}) -> int:\n    if v is None:\n        return nox_hv_new(0)\n    return {s}(v)\n\n", .{ name, ty, f });
            },
            .generic => |g| {
                if (std.mem.eql(u8, g.name, "list")) {
                    const f = try self.outName(g.args[0]);
                    try self.p(&d, "def {s}(v: {s}) -> int:\n    h: int = nox_hv_new(6)\n    for x in v:\n        nox_host_push(h, {s}(x))\n    return h\n\n", .{ name, ty, f });
                } else if (std.mem.eql(u8, g.name, "dict")) {
                    const kf = try self.outName(g.args[0]);
                    const vf = try self.outName(g.args[1]);
                    try self.p(&d, "def {s}(v: {s}) -> int:\n    h: int = nox_hv_new(7)\n    for k in v.keys():\n        nox_host_put(h, {s}(k), {s}(v[k]))\n    return h\n\n", .{ name, ty, kf, vf });
                } else {
                    try self.p(&d, "def {s}(v: {s}) -> int:\n    h: int = nox_hv_new(8)\n", .{ name, ty });
                    for (g.args, 0..) |x, i| {
                        const f = try self.outName(x);
                        try self.p(&d, "    nox_host_push(h, {s}(v[{d}]))\n", .{ f, i });
                    }
                    try d.appendSlice(self.a, "    return h\n\n");
                }
            },
            else => unreachable,
        }
        try self.helpers.appendSlice(self.a, d.items);
        return name;
    }
};

const prelude =
    \\
    \\# --- UR-008: --host-abi adaptörleri (compiler/host_adapt.zig tarafından sentezlendi) ---
    \\extern def nox_hv_kind(h: int) -> int from "zig-out/lib/noxrt.o" with_rt
    \\extern def nox_hv_int(h: int) -> int from "zig-out/lib/noxrt.o" with_rt
    \\extern def nox_hv_float(h: int) -> float from "zig-out/lib/noxrt.o" with_rt
    \\extern def nox_hv_str(h: int) -> str from "zig-out/lib/noxrt.o" with_rt
    \\extern def nox_hv_bytes(h: int) -> bytes from "zig-out/lib/noxrt.o" with_rt
    \\extern def nox_hv_len(h: int) -> int from "zig-out/lib/noxrt.o" with_rt
    \\extern def nox_hv_item(h: int, i: int) -> int from "zig-out/lib/noxrt.o" with_rt
    \\extern def nox_hv_key(h: int, i: int) -> int from "zig-out/lib/noxrt.o" with_rt
    \\extern def nox_hv_val(h: int, i: int) -> int from "zig-out/lib/noxrt.o" with_rt
    \\extern def nox_hv_release(h: int) -> None from "zig-out/lib/noxrt.o" with_rt
    \\extern def nox_hv_new(kind: int) -> int from "zig-out/lib/noxrt.o" with_rt
    \\extern def nox_hv_new_int(v: int) -> int from "zig-out/lib/noxrt.o" with_rt
    \\extern def nox_hv_new_float(v: float) -> int from "zig-out/lib/noxrt.o" with_rt
    \\extern def nox_hv_new_bool(v: int) -> int from "zig-out/lib/noxrt.o" with_rt
    \\extern def nox_hv_new_str(v: str) -> int from "zig-out/lib/noxrt.o" with_rt
    \\extern def nox_hv_new_bytes(v: bytes) -> int from "zig-out/lib/noxrt.o" with_rt
    \\extern def nox_hv_append(c: int, item: int) -> int from "zig-out/lib/noxrt.o" with_rt
    \\extern def nox_hv_dict_set(d: int, k: int, v: int) -> int from "zig-out/lib/noxrt.o" with_rt
    \\extern def nox_hv_class_is(h: int, name: str) -> int from "zig-out/lib/noxrt.o" with_rt
    \\
    \\def nox_host_expect(h: int, kind: int, what: str) -> None:
    \\    k: int = nox_hv_kind(h)
    \\    if k == -1:
    \\        raise ValueError("invalid NoxHostValue handle")
    \\    if k != kind:
    \\        raise ValueError("expected a " + what + " host value")
    \\
    \\def nox_host_push(c: int, item: int) -> None:
    \\    st: int = nox_hv_append(c, item)
    \\    nox_hv_release(item)
    \\    if st != 0:
    \\        raise ValueError("cannot add the value to the host container")
    \\
    \\def nox_host_put(d: int, k: int, v: int) -> None:
    \\    st: int = nox_hv_dict_set(d, k, v)
    \\    nox_hv_release(k)
    \\    nox_hv_release(v)
    \\    if st != 0:
    \\        raise ValueError("cannot add the entry to the host dict")
    \\
;

// ---- UR-009: `@export class` — sınıf/yöntem/özellik/statik/classmethod/dunder/istisna planı ve C sarmalayıcı kaynağı ----
// Strateji AYNI: dışa açılan her yöntem için kaynağın sonuna ÜST-DÜZEY bir `@export def <Sınıf>_<yöntem>(...)` sarmalayıcısı sentezlenir (örnek yöntemleri ilk parametre olarak sınıf örneğini
// alır → `NoxHostHandle`); böylece `--host-abi` kod üreteci ve UR-008 konteyner adaptörleri DEĞİŞMEDEN çalışır ve C sembolü `nox_host_export_<modül>_<Sınıf>_<yöntem>` olur.

/// Sentezlenen sınıf sarmalayıcılarının Nox adı `nox_hcls_<c_name>`dir (yöntemlerin derleyici sembolü `Counter_inc` ile ÇAKIŞMAMASI için); C'ye açılan ad ÖNEKSİZ `<c_name>`dir.
pub const class_wrapper_prefix = "nox_hcls_";

/// `@export` işlevinin C'ye açılan adı: sınıf sarmalayıcılarında önek atılır.
pub fn exportNameOf(fn_name: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, fn_name, class_wrapper_prefix)) fn_name[class_wrapper_prefix.len..] else fn_name;
}

pub const MethodKind = enum { instance, staticmethod, classmethod, property_get, property_set, dunder };

pub fn methodKindName(k: MethodKind) []const u8 {
    return switch (k) {
        .instance => "instance",
        .staticmethod => "staticmethod",
        .classmethod => "classmethod",
        .property_get => "property_get",
        .property_set => "property_set",
        .dunder => "dunder",
    };
}

pub const MethodPlan = struct {
    /// Kaynaktaki yöntem/özellik adı (`inc`, `value`, `__repr__`).
    name: []const u8,
    kind: MethodKind,
    fd: ast.FuncDef,
    /// Sarmalayıcının `@export` adı (C sembolü `nox_host_export_<modül>_<c_name>`): `Counter_inc`, `Counter_get_value`, `Counter_set_value`, `Counter___repr__`.
    c_name: []const u8,
    /// `self`/`cls` HARİÇ parametreler (kaynak sırasıyla).
    params: []const ast.Param,
    /// C imzasında ilk parametre sınıf örneğidir (`NoxHostHandle self`).
    has_self: bool,
};

pub const ClassPlan = struct {
    name: []const u8,
    line: u32,
    policy: []const u8,
    is_exception: bool,
    base: ?[]const u8,
    doc: ?[]const u8,
    /// `__init__` (yoksa null: parametresiz kurucu).
    ctor: ?ast.FuncDef,
    ctor_name: []const u8,
    ctor_params: []const ast.Param,
    methods: []const MethodPlan,
};

pub const Plans = union(enum) { ok: []const ClassPlan, err: []const u8 };

const builtin_exceptions = [_][]const u8{ "Exception", "ValueError", "IndexError", "RuntimeError", "AssertionError", "ZeroDivisionError", "KeyError", "StopIteration", "GeneratorExit", "CancelledError" };

fn findClass(module: ast.Module, name: []const u8) ?ast.ClassDef {
    for (module.body) |stmt| {
        if (stmt.kind == .class_def and std.mem.eql(u8, stmt.kind.class_def.name, name)) return stmt.kind.class_def;
    }
    return null;
}

/// Taban zinciri yerleşik `Exception` hiyerarşisine ulaşıyor mu? (kullanıcı sınıfları modülden, yerleşikler adla çözülür)
pub fn isExceptionClass(module: ast.Module, cd: ast.ClassDef) bool {
    var cur: ?[]const u8 = cd.base;
    var guard: usize = 0;
    while (cur) |b| : (guard += 1) {
        if (guard > 64) return false;
        for (builtin_exceptions) |e| if (std.mem.eql(u8, b, e)) return true;
        const next = findClass(module, b) orelse return false;
        cur = next.base;
    }
    return false;
}

fn exportDecorator(decs: []const ast.Decorator) ?ast.Decorator {
    for (decs) |d| if (std.mem.eql(u8, d.name, "export")) return d;
    return null;
}

fn isAllowedDunder(n: []const u8) bool {
    const allowed = [_][]const u8{ "__repr__", "__str__", "__eq__", "__len__", "__iter__", "__next__", "__enter__", "__exit__" };
    for (allowed) |x| if (std.mem.eql(u8, x, n)) return true;
    return false;
}

fn stripSelf(fd: ast.FuncDef, drop: usize) []const ast.Param {
    return if (fd.params.len >= drop) fd.params[drop..] else fd.params;
}

/// `@export` taşıyan üst-düzey sınıfların planı (JSON ve sentez bunu paylaşır). `module` ÇEKİLMEMİŞ (checker'dan ÖNCEKİ) kaynak ağacı olmalıdır: checker `@property`/`@staticmethod` dekoratörlerini sınıf gövdesinden çıkarır.
pub fn planClasses(a: std.mem.Allocator, module: ast.Module) !Plans {
    var plans: std.ArrayListUnmanaged(ClassPlan) = .empty;
    var taken: std.StringHashMapUnmanaged(void) = .empty;
    for (module.body) |stmt| {
        if (stmt.kind == .func_def) try taken.put(a, stmt.kind.func_def.name, {});
    }
    for (module.body) |stmt| {
        if (stmt.kind != .class_def) continue;
        const cd = stmt.kind.class_def;
        const dec = exportDecorator(cd.decorators) orelse continue;
        if (cd.type_params.len > 0 or cd.enum_variants.len > 0) return .{ .err = try std.fmt.allocPrint(a, "--host-abi: '@export class {s}': generic classes and enums cannot be exported\n", .{cd.name}) };
        for (cd.decorators) |d| {
            if (std.mem.eql(u8, d.name, "dataclass") or std.mem.eql(u8, d.name, "derive")) return .{ .err = try std.fmt.allocPrint(a, "--host-abi: '@export class {s}': '@{s}' classes are not supported yet (write an explicit __init__)\n", .{ cd.name, d.name }) };
        }
        var policy: []const u8 = "parallel";
        if (dec.args.len > 0 and dec.args[0] == .string_lit) policy = dec.args[0].string_lit;
        const line: u32 = if (stmt.line != 0) stmt.line else 0;
        if (isExceptionClass(module, cd)) {
            try plans.append(a, .{ .name = cd.name, .line = line, .policy = policy, .is_exception = true, .base = cd.base, .doc = cd.doc, .ctor = null, .ctor_name = "", .ctor_params = &.{}, .methods = &.{} });
            continue;
        }
        var ctor: ?ast.FuncDef = null;
        var methods: std.ArrayListUnmanaged(MethodPlan) = .empty;
        const ctor_name = try std.fmt.allocPrint(a, "{s}___new__", .{cd.name});
        if (taken.contains(ctor_name)) return .{ .err = try std.fmt.allocPrint(a, "--host-abi: '@export class {s}': the C export name '{s}' collides with another function\n", .{ cd.name, ctor_name }) };
        try taken.put(a, ctor_name, {});
        for (cd.methods) |m| {
            if (std.mem.eql(u8, m.name, "__init__")) {
                ctor = m;
                continue;
            }
            var kind: MethodKind = .instance;
            var prop_name: []const u8 = m.name;
            for (m.decorators) |d| {
                if (std.mem.eql(u8, d.name, "staticmethod")) {
                    kind = .staticmethod;
                } else if (std.mem.eql(u8, d.name, "classmethod")) {
                    kind = .classmethod;
                } else if (std.mem.eql(u8, d.name, "property")) {
                    kind = .property_get;
                } else if (std.mem.endsWith(u8, d.name, ".setter")) {
                    kind = .property_set;
                    prop_name = d.name[0 .. d.name.len - ".setter".len];
                }
            }
            const is_dunder = std.mem.startsWith(u8, m.name, "__") and std.mem.endsWith(u8, m.name, "__");
            if (kind == .instance) {
                if (is_dunder) {
                    if (!isAllowedDunder(m.name)) continue;
                    kind = .dunder;
                } else if (std.mem.startsWith(u8, m.name, "_")) continue; // özel yöntem: dışa açılmaz
            } else if (std.mem.startsWith(u8, prop_name, "_")) continue;
            if (m.type_params.len > 0) return .{ .err = try std.fmt.allocPrint(a, "--host-abi: '@export class {s}': method '{s}' cannot be generic\n", .{ cd.name, m.name }) };
            if (m.is_async) return .{ .err = try std.fmt.allocPrint(a, "--host-abi: '@export class {s}': async method '{s}' cannot be exported yet\n", .{ cd.name, m.name }) };
            const c_name = switch (kind) {
                .property_get => try std.fmt.allocPrint(a, "{s}_get_{s}", .{ cd.name, prop_name }),
                .property_set => try std.fmt.allocPrint(a, "{s}_set_{s}", .{ cd.name, prop_name }),
                else => try std.fmt.allocPrint(a, "{s}_{s}", .{ cd.name, m.name }),
            };
            if (taken.contains(c_name)) return .{ .err = try std.fmt.allocPrint(a, "--host-abi: '@export class {s}': the C export name '{s}' collides with another function/method\n", .{ cd.name, c_name }) };
            try taken.put(a, c_name, {});
            const drop: usize = if (kind == .staticmethod) 0 else 1;
            try methods.append(a, .{ .name = prop_name, .kind = kind, .fd = m, .c_name = c_name, .params = stripSelf(m, drop), .has_self = kind != .staticmethod and kind != .classmethod });
        }
        try plans.append(a, .{
            .name = cd.name,
            .line = line,
            .policy = policy,
            .is_exception = false,
            .base = cd.base,
            .doc = cd.doc,
            .ctor = ctor,
            .ctor_name = ctor_name,
            .ctor_params = if (ctor) |c| stripSelf(c, 1) else &.{},
            .methods = try methods.toOwnedSlice(a),
        });
    }
    return .{ .ok = try plans.toOwnedSlice(a) };
}

/// Parametre listesini `a0: T0, a1: T1` başlığına ve `a0, a1` argümanlarına çevirir; desteklenmeyen parametrede nedeni döner. `lead_comma`: başlıkta öncesinde başka parametre var.
fn appendParams(a: std.mem.Allocator, head: *std.ArrayListUnmanaged(u8), args: *std.ArrayListUnmanaged(u8), params: []const ast.Param, lead_comma: bool) !?[]const u8 {
    for (params, 0..) |prm, i| {
        if (prm.variadic or prm.var_kw) return try std.fmt.allocPrint(a, "parameter '{s}' (*args/**kwargs cannot cross the host ABI)", .{prm.name});
        const t = (try textOf(a, prm.type_expr)) orelse return try std.fmt.allocPrint(a, "parameter '{s}' has a type that cannot cross the host ABI", .{prm.name});
        if (lead_comma or i > 0) try head.appendSlice(a, ", ");
        if (i > 0) try args.appendSlice(a, ", ");
        try head.appendSlice(a, try std.fmt.allocPrint(a, "a{d}: {s}", .{ i, t }));
        try args.appendSlice(a, try std.fmt.allocPrint(a, "a{d}", .{i}));
    }
    return null;
}

/// `@export class` sarmalayıcılarının Nox kaynağı (kaynağın SONUNA eklenir; `.none`: dışa açık sınıf yok).
pub fn synthesizeClasses(a: std.mem.Allocator, module: ast.Module) !Result {
    const plans = switch (try planClasses(a, module)) {
        .ok => |p| p,
        .err => |m| return .{ .err = m },
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var any = false;
    for (plans) |cp| {
        if (cp.is_exception) continue;
        any = true;
        // kurucu: `def Counter___new__(a0: T0, ...) -> Counter: return Counter(a0, ...)`
        {
            var head: std.ArrayListUnmanaged(u8) = .empty;
            var args: std.ArrayListUnmanaged(u8) = .empty;
            if (try appendParams(a, &head, &args, cp.ctor_params, false)) |why| return fail(a, "--host-abi: '@export class {s}': constructor {s}\n", .{ cp.name, why });
            try out.appendSlice(a, try std.fmt.allocPrint(a, "@export\ndef {s}{s}({s}) -> {s}:\n    return {s}({s})\n\n", .{ class_wrapper_prefix, cp.ctor_name, head.items, cp.name, cp.name, args.items }));
        }
        for (cp.methods) |mp| {
            var head: std.ArrayListUnmanaged(u8) = .empty;
            var args: std.ArrayListUnmanaged(u8) = .empty;
            if (mp.has_self) try head.appendSlice(a, try std.fmt.allocPrint(a, "obj: {s}", .{cp.name}));
            if (try appendParams(a, &head, &args, mp.params, mp.has_self)) |why| return fail(a, "--host-abi: '@export class {s}': method '{s}': {s}\n", .{ cp.name, mp.name, why });
            const ret_none = mp.fd.return_type == .simple and std.mem.eql(u8, mp.fd.return_type.simple, "None");
            const rt_text: []const u8 = if (mp.kind == .property_set or ret_none) "None" else (try textOf(a, mp.fd.return_type)) orelse return fail(a, "--host-abi: '@export class {s}': method '{s}': return type cannot cross the host ABI\n", .{ cp.name, mp.name });
            if (mp.kind == .property_set) {
                try out.appendSlice(a, try std.fmt.allocPrint(a, "@export\ndef {s}{s}({s}) -> None:\n    obj.{s} = a0\n\n", .{ class_wrapper_prefix, mp.c_name, head.items, mp.name }));
                continue;
            }
            const call: []const u8 = switch (mp.kind) {
                .instance, .dunder => try std.fmt.allocPrint(a, "obj.{s}({s})", .{ mp.name, args.items }),
                .staticmethod, .classmethod => try std.fmt.allocPrint(a, "{s}.{s}({s})", .{ cp.name, mp.name, args.items }),
                .property_get => try std.fmt.allocPrint(a, "obj.{s}", .{mp.name}),
                .property_set => unreachable,
            };
            if (std.mem.eql(u8, rt_text, "None")) {
                try out.appendSlice(a, try std.fmt.allocPrint(a, "@export\ndef {s}{s}({s}) -> None:\n    {s}\n\n", .{ class_wrapper_prefix, mp.c_name, head.items, call }));
            } else {
                try out.appendSlice(a, try std.fmt.allocPrint(a, "@export\ndef {s}{s}({s}) -> {s}:\n    return {s}\n\n", .{ class_wrapper_prefix, mp.c_name, head.items, rt_text, call }));
            }
        }
    }
    if (!any) return .none;
    return .{ .text = try std.mem.concat(a, u8, &.{ "\n# --- UR-009: @export class sarmalayicilari (compiler/host_adapt.zig tarafindan sentezlendi) ---\n", out.items }) };
}

fn isExport(fd: ast.FuncDef) bool {
    for (fd.decorators) |d| if (std.mem.eql(u8, d.name, "export")) return true;
    return false;
}

fn fail(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !Result {
    return .{ .err = try std.fmt.allocPrint(a, fmt, args) };
}

pub fn synthesize(a: std.mem.Allocator, module: ast.Module) !Result {
    var cls = try collectClassSet(a, module);
    var s: Synth = .{ .a = a, .classes = &cls };
    var adapters: std.ArrayListUnmanaged(u8) = .empty;
    var any = false;
    for (module.body) |stmt| {
        if (stmt.kind != .func_def) continue;
        const fd = stmt.kind.func_def;
        if (!isExport(fd) or fd.is_async or fd.type_params.len > 0) continue;
        var needs = isContainerish(fd.return_type);
        for (fd.params) |prm| needs = needs or isContainerish(prm.type_expr);
        if (!needs) continue;
        any = true;

        var head: std.ArrayListUnmanaged(u8) = .empty;
        var args: std.ArrayListUnmanaged(u8) = .empty;
        try head.appendSlice(a, try std.fmt.allocPrint(a, "def nox_host_adapt_{s}(", .{fd.name}));
        for (fd.params, 0..) |prm, i| {
            if (i > 0) {
                try head.appendSlice(a, ", ");
                try args.appendSlice(a, ", ");
            }
            if (isContainerish(prm.type_expr)) {
                if (!validElem(prm.type_expr, false, &cls)) return fail(a, "--host-abi: '@export def {s}': parameter '{s}' has a container/Optional type with unsupported elements (supported: int, float, bool, str, bytes, user classes, T | None, list, dict with scalar keys, tuple; int/float/bool | None are not supported inside containers)\n", .{ fd.name, prm.name });
                try head.appendSlice(a, try std.fmt.allocPrint(a, "a{d}: int", .{i}));
                try args.appendSlice(a, try std.fmt.allocPrint(a, "{s}(a{d})", .{ try s.inName(prm.type_expr), i }));
            } else {
                const t = (try textOf(a, prm.type_expr)) orelse return fail(a, "--host-abi: '@export def {s}': parameter '{s}' has a type that cannot cross the host ABI\n", .{ fd.name, prm.name });
                try head.appendSlice(a, try std.fmt.allocPrint(a, "a{d}: {s}", .{ i, t }));
                try args.appendSlice(a, try std.fmt.allocPrint(a, "a{d}", .{i}));
            }
        }
        const call = try std.fmt.allocPrint(a, "{s}({s})", .{ fd.name, args.items });
        const ret_none = fd.return_type == .simple and std.mem.eql(u8, fd.return_type.simple, "None");
        if (ret_none) {
            try adapters.appendSlice(a, try std.fmt.allocPrint(a, "{s}) -> None:\n    {s}\n\n", .{ head.items, call }));
        } else if (isContainerish(fd.return_type)) {
            if (!validElem(fd.return_type, false, &cls)) return fail(a, "--host-abi: '@export def {s}': return type is a container/Optional with unsupported elements (supported: int, float, bool, str, bytes, user classes, T | None, list, dict with scalar keys, tuple)\n", .{fd.name});
            try adapters.appendSlice(a, try std.fmt.allocPrint(a, "{s}) -> int:\n    return {s}({s})\n\n", .{ head.items, try s.outName(fd.return_type), call }));
        } else {
            const t = (try textOf(a, fd.return_type)) orelse return fail(a, "--host-abi: '@export def {s}': return type cannot cross the host ABI\n", .{fd.name});
            try adapters.appendSlice(a, try std.fmt.allocPrint(a, "{s}) -> {s}:\n    return {s}\n\n", .{ head.items, t, call }));
        }
    }
    if (!any) return .none;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(a, prelude);
    for (s.used_classes.items) |cn| {
        try out.appendSlice(a, try std.fmt.allocPrint(a, "extern def nox_hv_obj_{s}(h: int) -> {s} from \"zig-out/lib/noxrt.o\" with_rt\nextern def nox_hv_new_obj_{s}(o: {s}) -> int from \"zig-out/lib/noxrt.o\" with_rt\n", .{ cn, cn, cn, cn }));
    }
    try out.appendSlice(a, s.helpers.items);
    try out.appendSlice(a, adapters.items);
    return .{ .text = out.items };
}

test "synthesize: konteyner içermeyen modül değişmez, konteynerli export adaptör üretir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(isContainerish(.{ .generic = .{ .name = "list", .args = &.{} } }));
    try std.testing.expect(!isContainerish(.{ .simple = "int" }));
    var cs: ClassSet = .empty;
    try cs.put(a, "Counter", {});
    try std.testing.expect(validElem(.{ .simple = "bytes" }, true, &cs));
    try std.testing.expect(!validElem(.{ .simple = "Point" }, true, &cs));
    try std.testing.expect(validElem(.{ .simple = "Counter" }, true, &cs));
    try std.testing.expectEqualStrings("nox_host_adapt_f", try adapterName(a, "f"));
}
