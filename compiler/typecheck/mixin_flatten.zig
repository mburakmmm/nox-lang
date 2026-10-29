//! TODO 8.2: çoklu kalıtım — `class C(A, B, D):` karışımı (mixin) düzleştirmesi.
//!
//! İlk taban (`A`) gerçek tekli kalıtımdır (vtable, `super()`, hiyerarşik `except`). Kalan tabanlar (`B`, `D`) MIXIN olarak ele alınır:
//! metodları (`__init__` HARİÇ), sınıf-düzeyi alan bildirimleri ve sabitleri `C`ye KOPYALANIR (checker'dan ÖNCE, AST üzerinde).
//! Çözümleme sırası Python'un MRO'suyla uyumludur: `C`nin kendi üyeleri > `A` zinciri > `B` > `D`. Mixin kendi tabanlarından da (özyinelemeli) alır.
//! SINIRLAR (belgelenmiş): mixin durumu `x: int` biçiminde SINIF-DÜZEYİ alan bildirimiyle tanımlanmalı ve `C.__init__` tarafından atanmalıdır
//! (mixin `__init__`i kopyalanmaz); `super()` bir mixin metodunda kullanılamaz; `isinstance(c, B)` / `except B` mixin için tutmaz
//! (yapısal protokoller yine çalışır); generic mixin yok.

const std = @import("std");
const ast = @import("../parser/ast.zig");

pub const Diagnostic = struct { message: []const u8, line: u32 };

const Pass = struct {
    a: std.mem.Allocator,
    classes: std.StringHashMapUnmanaged(*ast.ClassDef) = .empty,
    lines: std.StringHashMapUnmanaged(u32) = .empty,
    done: std.StringHashMapUnmanaged(void) = .empty,
    visiting: std.StringHashMapUnmanaged(void) = .empty,
    from_imports: *const std.StringHashMapUnmanaged([]const u8),
    diag: ?Diagnostic = null,

    fn fail(self: *Pass, line: u32, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        if (self.diag == null) self.diag = .{ .message = try std.fmt.allocPrint(self.a, fmt, args), .line = line };
    }

    fn resolve(self: *Pass, name: []const u8) ?*ast.ClassDef {
        if (self.classes.get(name)) |c| return c;
        if (self.from_imports.get(name)) |q| if (self.classes.get(q)) |c| return c;
        return null;
    }

    fn hasMethodInChain(self: *Pass, cd: *const ast.ClassDef, name: []const u8) bool {
        var cur: ?*const ast.ClassDef = cd;
        var guard: usize = 0;
        while (cur) |c| : (guard += 1) {
            if (guard > 64) return false;
            for (c.methods) |m| if (std.mem.eql(u8, m.name, name)) return true;
            cur = if (c.base) |b| self.resolve(b) else null;
        }
        return false;
    }

    fn hasField(cd: *const ast.ClassDef, name: []const u8) bool {
        for (cd.fields) |f| if (std.mem.eql(u8, f.name, name)) return true;
        return false;
    }

    fn hasConst(cd: *const ast.ClassDef, name: []const u8) bool {
        for (cd.consts) |k| if (std.mem.eql(u8, k.name, name)) return true;
        return false;
    }

    /// `cd`nin mixin'lerini (kendi tabanları dahil) önce düzleştirir, sonra üyelerini `cd`ye kopyalar.
    fn flatten(self: *Pass, cd: *ast.ClassDef) std.mem.Allocator.Error!void {
        if (self.done.contains(cd.name) or self.diag != null) return;
        if (self.visiting.contains(cd.name)) {
            try self.fail(self.lines.get(cd.name) orelse 0, "class '{s}': cyclic base classes", .{cd.name});
            return;
        }
        try self.visiting.put(self.a, cd.name, {});
        defer _ = self.visiting.remove(cd.name);
        const line = self.lines.get(cd.name) orelse 0;
        // Önce gerçek tabanı (kendi mixin'leri `C`nin MRO'sunda önce gelmeli).
        if (cd.base) |b| if (self.resolve(b)) |bc| try self.flatten(bc);
        if (cd.extra_bases.len == 0) {
            try self.done.put(self.a, cd.name, {});
            return;
        }
        var methods: std.ArrayList(ast.FuncDef) = .empty;
        try methods.appendSlice(self.a, cd.methods);
        var fields: std.ArrayList(ast.FieldDecl) = .empty;
        try fields.appendSlice(self.a, cd.fields);
        var consts: std.ArrayList(ast.ConstDecl) = .empty;
        try consts.appendSlice(self.a, cd.consts);
        for (cd.extra_bases) |mn| {
            const mixin = self.resolve(mn) orelse {
                try self.fail(line, "class '{s}': unknown base class '{s}'", .{ cd.name, mn });
                return;
            };
            if (mixin.type_params.len != 0) {
                try self.fail(line, "class '{s}': the generic class '{s}' cannot be used as a mixin", .{ cd.name, mn });
                return;
            }
            if (cd.base != null and mixin.name.ptr == (self.resolve(cd.base.?) orelse mixin).name.ptr) continue;
            try self.flatten(mixin);
            if (self.diag != null) return;
            // mixin'in kendi (zaten düzleştirilmiş) üyeleri + gerçek taban zinciri
            var src: ?*const ast.ClassDef = mixin;
            var guard: usize = 0;
            while (src) |sc| : (guard += 1) {
                if (guard > 64) break;
                for (sc.methods) |m| {
                    if (std.mem.eql(u8, m.name, "__init__")) continue;
                    var taken = false;
                    for (methods.items) |e| if (std.mem.eql(u8, e.name, m.name)) {
                        taken = true;
                        break;
                    };
                    if (!taken and cd.base != null) if (self.resolve(cd.base.?)) |bc| {
                        if (self.hasMethodInChain(bc, m.name)) taken = true;
                    };
                    if (taken) continue;
                    var copy = m;
                    if (copy.params.len > 0 and std.mem.eql(u8, copy.params[0].name, "self")) {
                        const ps = try self.a.dupe(ast.Param, copy.params);
                        ps[0].type_expr = .{ .simple = cd.name };
                        copy.params = ps;
                    }
                    try methods.append(self.a, copy);
                }
                for (sc.fields) |f| {
                    var have = false;
                    for (fields.items) |e| if (std.mem.eql(u8, e.name, f.name)) {
                        have = true;
                        break;
                    };
                    if (!have) try fields.append(self.a, f);
                }
                for (sc.consts) |k| {
                    var have = false;
                    for (consts.items) |e| if (std.mem.eql(u8, e.name, k.name)) {
                        have = true;
                        break;
                    };
                    if (!have) try consts.append(self.a, k);
                }
                src = if (sc.base) |b| self.resolve(b) else null;
            }
        }
        cd.methods = try methods.toOwnedSlice(self.a);
        cd.fields = try fields.toOwnedSlice(self.a);
        cd.consts = try consts.toOwnedSlice(self.a);
        cd.extra_bases = &.{};
        try self.done.put(self.a, cd.name, {});
    }
};

/// Modüldeki tüm sınıfları YERİNDE düzleştirir; hata varsa tanılamayı döner.
pub fn run(allocator: std.mem.Allocator, body: []ast.Stmt, from_imports: *const std.StringHashMapUnmanaged([]const u8)) std.mem.Allocator.Error!?Diagnostic {
    var any = false;
    for (body) |st| if (st.kind == .class_def and st.kind.class_def.extra_bases.len > 0) {
        any = true;
        break;
    };
    if (!any) return null;
    var pass: Pass = .{ .a = allocator, .from_imports = from_imports };
    for (body) |*st| if (st.kind == .class_def) {
        try pass.classes.put(allocator, st.kind.class_def.name, &st.kind.class_def);
        try pass.lines.put(allocator, st.kind.class_def.name, st.line);
    };
    for (body) |*st| if (st.kind == .class_def) {
        try pass.flatten(&st.kind.class_def);
        if (pass.diag) |d| return d;
    };
    return null;
}
