//! v2.1.96 (TODO 7.8): "referans liste parametresi" analizi.
//!
//! Bir serbest işlev `list[T]` parametresini BÜYÜTÜYORSA (`p.append(...)`, `p.insert(...)`; `extend` checker'da `for`+`append`e indirgenir) büyüme yolu
//! listenin blok işaretçisini DEĞİŞTİRİR; eskiden bu, çağıranın değişkenini BAYAT bırakacağı için derleyici "desteklenmiyor" der ve program derlenmezdi.
//! Çözüm (kullanıcı sözdiziminde hiçbir şey görünmez, İlke 1): böyle bir parametre için çağrı sözleşmesi "değer" yerine "çağıranın DEĞİŞKEN YUVASININ adresi"dir
//! (QBE'de her ikisi de `l`: imza değişmez). Çağrı yerinde argüman bir yerel/global/alan ise yuvasının adresi, aksi halde geçici bir yuva geçirilir; işlev gövdesinde
//! parametre, yuvası çağıranın yuvası olan bir yerel gibi davranır (okuma yüklemedir, büyüme yeni işaretçiyi o yuvaya yazar).
//!
//! Kapsam (bilinçli olarak dar): yalnızca serbest işlevler. Şu durumlarda parametre "referans" OLMAZ ve eski "desteklenmiyor" davranışı sürer: işlev `async`/dekoratörlü,
//! işlev değeri olarak kullanılıyor ya da `@ffi.callback` hedefi, parametre aynı işlevde yeniden bağlanıyor (`p = ...`, `p += ...`, `for p in ...`). Referans parametre
//! geçişlidir: `def g(a): f(a)` ve `f` referans alıyorsa `g`nin `a`sı da referans olur (sabit nokta).

const std = @import("std");
const ast = @import("../parser/ast.zig");

pub const RefMap = std.StringHashMapUnmanaged([]bool);

const Finder = struct {
    param: []const u8,
    refs: *const RefMap,
    grown: bool = false,
    rebound: bool = false,

    fn expr(self: *Finder, e: ast.Expr) void {
        switch (e) {
            .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => {},
            .unary => |u| self.expr(u.operand.*),
            .binary => |b| {
                self.expr(b.left.*);
                self.expr(b.right.*);
            },
            .call => |c| self.call(c),
            .attribute => |a| self.expr(a.obj.*),
            .index => |ix| {
                self.expr(ix.obj.*);
                self.expr(ix.index.*);
            },
            .list_lit => |xs| for (xs) |x| self.expr(x),
            .tuple_lit => |xs| for (xs) |x| self.expr(x),
            .dict_lit => |ps| for (ps) |p| {
                self.expr(p.key);
                self.expr(p.value);
            },
            .await_expr => |x| self.expr(x.*),
            .spawn_expr => |x| self.expr(x.*),
            .generic_construct => |g| for (g.args) |x| self.expr(x),
            .ternary => |t| {
                self.expr(t.cond.*);
                self.expr(t.then_expr.*);
                self.expr(t.else_expr.*);
            },
            .kwarg => |k| self.expr(k.value.*),
            .slice => |s| {
                self.expr(s.obj.*);
                if (s.lo) |x| self.expr(x.*);
                if (s.hi) |x| self.expr(x.*);
                if (s.step) |x| self.expr(x.*);
            },
            .lambda => |l| self.expr(l.body.*),
            .list_comp => |lc| {
                self.expr(lc.elem.*);
                self.clauses(lc.clauses);
            },
            .dict_comp => |dc| {
                self.expr(dc.key.*);
                self.expr(dc.value.*);
                self.clauses(dc.clauses);
            },
        }
    }

    fn clauses(self: *Finder, cs: []const ast.CompClause) void {
        for (cs) |c| switch (c) {
            .for_clause => |f| self.expr(f.iterable),
            .if_clause => |x| self.expr(x),
        };
    }

    fn call(self: *Finder, c: ast.Call) void {
        switch (c.callee.*) {
            // `p.append(x)` / `p.insert(i, x)`: alıcı çıplak `p` ise büyüme.
            .attribute => |a| {
                if (a.obj.* == .identifier and std.mem.eql(u8, a.obj.identifier, self.param) and
                    (std.mem.eql(u8, a.attr, "append") or std.mem.eql(u8, a.attr, "insert")))
                {
                    self.grown = true;
                }
                self.expr(a.obj.*);
            },
            // `g(.., p, ..)` ve `g`nin ilgili konumu referans ise `p` de referanstır (geçişlilik).
            .identifier => |name| {
                if (self.refs.get(name)) |flags| {
                    for (c.args, 0..) |arg, i| {
                        if (i < flags.len and flags[i] and arg == .identifier and std.mem.eql(u8, arg.identifier, self.param)) self.grown = true;
                    }
                }
            },
            else => self.expr(c.callee.*),
        }
        for (c.args) |arg| self.expr(arg);
    }

    fn stmts(self: *Finder, ss: []const ast.Stmt) void {
        for (ss) |s| self.stmt(s);
    }

    fn stmt(self: *Finder, s: ast.Stmt) void {
        switch (s.kind) {
            .expr_stmt => |e| self.expr(e),
            .var_decl => |v| {
                if (std.mem.eql(u8, v.name, self.param)) self.rebound = true;
                self.expr(v.value);
            },
            .assign => |a| {
                if (a.target == .identifier and std.mem.eql(u8, a.target.identifier, self.param)) self.rebound = true;
                self.expr(a.target);
                self.expr(a.value);
            },
            .if_stmt => |i| {
                self.expr(i.cond);
                self.stmts(i.then_body);
                for (i.elif_clauses) |ec| {
                    self.expr(ec.cond);
                    self.stmts(ec.body);
                }
                if (i.else_body) |eb| self.stmts(eb);
            },
            .while_stmt => |w| {
                self.expr(w.cond);
                self.stmts(w.body);
            },
            .for_stmt => |f| {
                if (std.mem.eql(u8, f.var_name, self.param)) self.rebound = true;
                self.expr(f.iterable);
                self.stmts(f.body);
            },
            .return_stmt => |r| if (r) |e| self.expr(e),
            .raise_stmt => |e| self.expr(e),
            .try_stmt => |t| {
                self.stmts(t.try_body);
                for (t.except_clauses) |ec| self.stmts(ec.body);
                if (t.finally_body) |fb| self.stmts(fb);
            },
            .lowlevel_stmt => |l| self.stmts(l.body),
            .del_stmt => |e| self.expr(e),
            .with_stmt => |w| {
                self.expr(w.ctx_expr);
                self.stmts(w.body);
            },
            .defer_stmt => |d| self.call(d.call),
            // İç içe tanımlar kendi kapsamlarında analiz edilir (kapanış yakalamaları referans parametre YAPMAZ).
            .func_def, .class_def, .protocol_def, .extern_def, .import_stmt, .from_import_stmt, .pass_stmt, .break_stmt, .continue_stmt => {},
        }
    }
};

fn isListType(t: ast.TypeExpr) bool {
    return switch (t) {
        .generic => |g| std.mem.eql(u8, g.name, "list"),
        else => false,
    };
}

fn contains(names: []const []const u8, n: []const u8) bool {
    // callback hedef anahtarları `ad@k` biçiminde olabilir (v2.1.108: userdata konumu)
    for (names) |x| if (std.mem.eql(u8, x, n) or (x.len > n.len and std.mem.startsWith(u8, x, n) and x[n.len] == '@')) return true;
    return false;
}

/// Serbest işlevlerin referans-liste-parametre bayraklarını hesaplar. Sonuç yalnızca EN AZ BİR bayrağı doğru olan işlevleri içerir.
pub fn analyze(
    allocator: std.mem.Allocator,
    defs: []const ast.FuncDef,
    excluded_names: []const []const u8,
    excluded2: []const []const u8,
) !RefMap {
    var map: RefMap = .empty;
    // Aday işlevler için sıfırlı bayrak dizileri.
    for (defs) |fd| {
        if (fd.is_async or fd.decorators.len > 0 or fd.type_params.len > 0) continue;
        if (contains(excluded_names, fd.name) or contains(excluded2, fd.name)) continue;
        var any_list = false;
        for (fd.params) |p| {
            if (p.variadic or p.var_kw) {
                any_list = false;
                break;
            }
            if (isListType(p.type_expr)) any_list = true;
        }
        if (!any_list) continue;
        const flags = try allocator.alloc(bool, fd.params.len);
        @memset(flags, false);
        try map.put(allocator, fd.name, flags);
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (defs) |fd| {
            const flags = map.get(fd.name) orelse continue;
            for (fd.params, 0..) |p, i| {
                if (flags[i] or !isListType(p.type_expr)) continue;
                var f: Finder = .{ .param = p.name, .refs = &map };
                f.stmts(fd.body);
                if (f.grown and !f.rebound) {
                    flags[i] = true;
                    changed = true;
                }
            }
        }
    }
    // Hiç bayrağı olmayanları çıkar.
    var it = map.iterator();
    var drop: std.ArrayListUnmanaged([]const u8) = .empty;
    defer drop.deinit(allocator);
    while (it.next()) |e| {
        var any = false;
        for (e.value_ptr.*) |b| any = any or b;
        if (!any) try drop.append(allocator, e.key_ptr.*);
    }
    for (drop.items) |k| _ = map.remove(k);
    return map;
}
