//! TODO 8.3: değişebilir sınıf öznitelikleri.
//!
//! Parser her sınıf sabiti (`NAME: T = literal`) için sınıfın önüne sentetik bir modül değişkeni (`__nox_cls_<Sınıf>_<NAME>`) ekler.
//! Bu geçiş, programın HERHANGİ bir yerinde `Sınıf.NAME = ...` (ya da `Sınıf.NAME += ...`) biçiminde ATANAN sabitleri bulur:
//! onlar `promoted` olur (checker okumaları/yazmaları sentetik değişkene yönlendirir; modül-global durum mekanizması saklar).
//! Hiç atanmayan sabitler eskisi gibi literal olarak katlanır ve sentetik değişkenleri `pass`e çevrilir (IR'a sızmaz).

const std = @import("std");
const ast = @import("../parser/ast.zig");

pub fn globalName(a: std.mem.Allocator, owner: []const u8, name: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "__nox_cls_{s}_{s}", .{ owner, name });
}

const Pass = struct {
    a: std.mem.Allocator,
    classes: std.StringHashMapUnmanaged(*ast.ClassDef) = .empty,
    from_imports: *const std.StringHashMapUnmanaged([]const u8),
    aliases: *const std.StringHashMapUnmanaged([]const []const u8),
    assigned: std.StringHashMapUnmanaged(void) = .empty,

    fn resolve(self: *Pass, n: []const u8) ?*ast.ClassDef {
        if (self.classes.get(n)) |c| return c;
        if (self.from_imports.get(n)) |q| if (self.classes.get(q)) |c| return c;
        return null;
    }

    /// `pkg.mod.Cls` (ya da `alias.Cls`) nitelikli sınıf başvurusu: segmentler `_` ile birleşip (yükleyicinin mangle kuralı) sınıfa çözülür.
    fn resolveQualified(self: *Pass, e: ast.Expr) std.mem.Allocator.Error!?*ast.ClassDef {
        var segs: std.ArrayListUnmanaged([]const u8) = .empty;
        defer segs.deinit(self.a);
        var cur = e;
        while (cur == .attribute) {
            try segs.append(self.a, cur.attribute.attr);
            cur = cur.attribute.obj.*;
        }
        if (cur != .identifier) return null;
        try segs.append(self.a, cur.identifier);
        std.mem.reverse([]const u8, segs.items);
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.a);
        var start: usize = 0;
        if (self.aliases.get(segs.items[0])) |target| {
            for (target) |t| {
                try buf.appendSlice(self.a, t);
                try buf.append(self.a, '_');
            }
            start = 1;
        }
        for (segs.items[start..], start..) |sg, i| {
            if (i > start) try buf.append(self.a, '_');
            try buf.appendSlice(self.a, sg);
        }
        return self.classes.get(buf.items);
    }

    fn noteTarget(self: *Pass, target: ast.Expr) std.mem.Allocator.Error!void {
        if (target != .attribute) return;
        const cd = (if (target.attribute.obj.* == .identifier) self.resolve(target.attribute.obj.identifier) else try self.resolveQualified(target.attribute.obj.*)) orelse return;
        for (cd.consts) |k| if (std.mem.eql(u8, k.name, target.attribute.attr)) {
            try self.assigned.put(self.a, try globalName(self.a, k.owner orelse cd.name, k.name), {});
            return;
        };
    }

    fn walk(self: *Pass, stmts: []const ast.Stmt) std.mem.Allocator.Error!void {
        for (stmts) |st| switch (st.kind) {
            .assign => |as| try self.noteTarget(as.target),
            .if_stmt => |s| {
                try self.walk(s.then_body);
                for (s.elif_clauses) |ec| try self.walk(ec.body);
                if (s.else_body) |eb| try self.walk(eb);
            },
            .while_stmt => |s| try self.walk(s.body),
            .for_stmt => |s| try self.walk(s.body),
            .try_stmt => |s| {
                try self.walk(s.try_body);
                for (s.except_clauses) |ec| try self.walk(ec.body);
                if (s.finally_body) |fb| try self.walk(fb);
            },
            .with_stmt => |s| try self.walk(s.body),
            .lowlevel_stmt => |s| try self.walk(s.body),
            .func_def => |fd| try self.walk(fd.body),
            .class_def => |cd| for (cd.methods) |m| try self.walk(m.body),
            else => {},
        };
    }
};

/// Modülü YERİNDE işler (eleman mutasyonu; dilim uzunluğu değişmez).
pub fn run(allocator: std.mem.Allocator, body: []ast.Stmt, from_imports: *const std.StringHashMapUnmanaged([]const u8), aliases: *const std.StringHashMapUnmanaged([]const []const u8)) std.mem.Allocator.Error!void {
    var any = false;
    for (body) |st| if (st.kind == .var_decl and st.kind.var_decl.class_attr != null) {
        any = true;
        break;
    };
    if (!any) return;
    var pass: Pass = .{ .a = allocator, .from_imports = from_imports, .aliases = aliases };
    for (body) |*st| if (st.kind == .class_def) try pass.classes.put(allocator, st.kind.class_def.name, &st.kind.class_def);
    try pass.walk(body);
    // Sınıflardaki sabitleri işaretle.
    for (body) |*st| if (st.kind == .class_def) {
        const cd = &st.kind.class_def;
        if (cd.consts.len == 0) continue;
        const marked = try allocator.dupe(ast.ConstDecl, cd.consts);
        for (marked) |*k| k.promoted = pass.assigned.contains(try globalName(allocator, k.owner orelse cd.name, k.name));
        cd.consts = marked;
    };
    // Kullanılmayan sentetik depolar IR'a sızmasın.
    for (body) |*st| if (st.kind == .var_decl and st.kind.var_decl.class_attr != null) {
        if (!pass.assigned.contains(st.kind.var_decl.name)) st.kind = .pass_stmt;
    };
}
