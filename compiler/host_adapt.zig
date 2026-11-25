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
fn validElem(te: ast.TypeExpr, nested: bool) bool {
    switch (te) {
        .simple => |n| return isScalarName(n),
        .optional => |inner| {
            if (inner.* == .optional) return false;
            if (nested and inner.* == .simple and !(std.mem.eql(u8, inner.simple, "str") or std.mem.eql(u8, inner.simple, "bytes"))) return false;
            return validElem(inner.*, nested);
        },
        .generic => |g| {
            if (std.mem.eql(u8, g.name, "list")) return g.args.len == 1 and validElem(g.args[0], true);
            if (std.mem.eql(u8, g.name, "dict")) return g.args.len == 2 and g.args[0] == .simple and isScalarName(g.args[0].simple) and validElem(g.args[1], true);
            if (std.mem.eql(u8, g.name, "tuple")) {
                if (g.args.len == 0) return false;
                for (g.args) |x| if (!validElem(x, true)) return false;
                return true;
            }
            return false;
        },
        else => return false,
    }
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
    helpers: std.ArrayListUnmanaged(u8) = .empty,
    in_memo: std.StringHashMapUnmanaged([]const u8) = .empty,
    out_memo: std.StringHashMapUnmanaged([]const u8) = .empty,
    get_memo: std.StringHashMapUnmanaged([]const u8) = .empty,
    next: u32 = 0,

    fn p(self: *Synth, buf: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.a, fmt, args);
        try buf.appendSlice(self.a, s);
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
                if (std.mem.eql(u8, n, "int")) {
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

fn isExport(fd: ast.FuncDef) bool {
    for (fd.decorators) |d| if (std.mem.eql(u8, d.name, "export")) return true;
    return false;
}

fn fail(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !Result {
    return .{ .err = try std.fmt.allocPrint(a, fmt, args) };
}

pub fn synthesize(a: std.mem.Allocator, module: ast.Module) !Result {
    var s: Synth = .{ .a = a };
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
                if (!validElem(prm.type_expr, false)) return fail(a, "--host-abi: '@export def {s}': parameter '{s}' has a container/Optional type with unsupported elements (supported: int, float, bool, str, bytes, T | None, list, dict with scalar keys, tuple; class instances and int/float/bool | None are not supported inside containers)\n", .{ fd.name, prm.name });
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
            if (!validElem(fd.return_type, false)) return fail(a, "--host-abi: '@export def {s}': return type is a container/Optional with unsupported elements (supported: int, float, bool, str, bytes, T | None, list, dict with scalar keys, tuple)\n", .{fd.name});
            try adapters.appendSlice(a, try std.fmt.allocPrint(a, "{s}) -> int:\n    return {s}({s})\n\n", .{ head.items, try s.outName(fd.return_type), call }));
        } else {
            const t = (try textOf(a, fd.return_type)) orelse return fail(a, "--host-abi: '@export def {s}': return type cannot cross the host ABI\n", .{fd.name});
            try adapters.appendSlice(a, try std.fmt.allocPrint(a, "{s}) -> {s}:\n    return {s}\n\n", .{ head.items, t, call }));
        }
    }
    if (!any) return .none;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(a, prelude);
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
    try std.testing.expect(validElem(.{ .simple = "bytes" }, true));
    try std.testing.expect(!validElem(.{ .simple = "Point" }, true));
    try std.testing.expectEqualStrings("nox_host_adapt_f", try adapterName(a, "f"));
}
