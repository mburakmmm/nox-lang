//! v1.147.0 (varsayılan + keyword argümanlar): checker her çağrıyı hedefin imzasına göre TAM konumsal argüman listesine
//! genişletir (keyword'ler parametre sırasına dizilir, eksikler varsayılan literalle dolar) ama `checkExpr` AST'yi
//! DEĞER olarak aldığından genişletmeyi `Checker.call_expansions`a (anahtar: çağrının `callee` kutusunun adresi,
//! `generic_construct` için `resolved_class_name` kutusunun adresi) yazar. Bu geçiş checker bittikten SONRA AST'yi YERİNDE
//! yeniden yazar: böylece sahiplik/kaçış/inline/raise analizleri ve codegen (argüman↔parametre eşlemesini İNDEKSLE yapan
//! her şey) yalnızca sıradan, tam konumsal çağrılar görür; `kwarg` düğümü hiçbir aşağı-akış geçişine ulaşmaz.

const std = @import("std");
const ast = @import("../parser/ast.zig");

pub const Map = std.AutoHashMapUnmanaged(usize, []ast.Expr);

/// v1.148.0: bir `for`un checker tarafından belirlenen yeniden yazımı (anahtar: `body.ptr`): `iterable` yerine geçecek
/// ifade (dict → `d.keys()`, str → karakter listesi) ve/veya gizli yerel bildirimi.
pub const ForRewrite = struct { iterable: ?ast.Expr, hoist: ?ast.ForHoist };
pub const ForMap = std.AutoHashMapUnmanaged(usize, ForRewrite);

/// v1.150.0: `xs.extend(ys)` deyimi checker'da bir `for e in ys: xs.append(e)` döngüsüne, v1.152.0: `d[k].append(v)` bir
/// `if True:` bloğuna (geçici yerel + işlem + geri yazma) yeniden yazılır (anahtar: çağrının `callee` kutusunun adresi). Böylece büyüme/sahiplik/ARC yolları `append` ile BİREBİR aynıdır, yeni bir codegen yolu yoktur.
pub const StmtForMap = std.AutoHashMapUnmanaged(usize, ast.StmtKind);

/// v1.154.0: comprehension sonuç tipleri (anahtar: `elem`/`key` kutusunun adresi) — checker'ın çıkardığı tip codegen'e `result_type` olarak akar.
pub const CompTypeMap = std.AutoHashMapUnmanaged(usize, ast.TypeExpr);

/// v1.155.0: lambda → yükseltilmiş `FuncDef` (anahtar: lambda gövde kutusunun adresi). Bkz. `Ctx.pending`/`Ctx.lifted`.
pub const LambdaEntry = struct { fd: ast.FuncDef, has_captures: bool };
pub const LambdaMap = std.AutoHashMapUnmanaged(usize, LambdaEntry);

/// `calls`/`fors`/`stmt_fors`/`comps`/`lambdas` salt-okunur yan tablolardır; `pending` (işlenen deyimin başlığında karşılaşılan, o deyimden ÖNCE
/// tanımlanacak iç içe `def`ler), `lifted` (modül üst düzeyindeki lambda'ların yükseltildiği üst-düzey fonksiyonlar) ve `in_func` (fonksiyon/metod
/// gövdesi derinliği) değiştirilebilir durumdur.
/// v1.157.0: ifade yeniden yazımları (anahtar: tuple literal için `items.ptr`, `d.items()`/`len(t)` için çağrının `callee` kutusu, `t[k]` için indeks kutusu).
pub const ExprRewriteMap = std.AutoHashMapUnmanaged(usize, ast.Expr);

/// v1.157.0: tip-çıkarımlı (`__infer`) `var_decl`ların çözülmüş tipleri (anahtar: bildirilen ismin işaretçisi).
pub const InferMap = std.AutoHashMapUnmanaged(usize, ast.TypeExpr);

pub const Ctx = struct {
    exprs: *const ExprRewriteMap,
    infers: *const InferMap,
    calls: *const Map,
    fors: *const ForMap,
    stmt_fors: *const StmtForMap,
    comps: *const CompTypeMap,
    lambdas: *const LambdaMap,
    allocator: std.mem.Allocator,
    pending: *std.ArrayListUnmanaged(ast.Stmt),
    lifted: *std.ArrayListUnmanaged(ast.FuncDef),
    in_func: *u32,
};

fn applyClauses(clauses: []ast.CompClause, map: *const Ctx) void {
    for (clauses) |*cl| switch (cl.*) {
        .for_clause => |*fc| {
            if (map.fors.get(@intFromPtr(&fc.iterable))) |rw| {
                if (rw.iterable) |it| fc.iterable = it;
            }
            expr(&fc.iterable, map);
        },
        .if_clause => |*ce| expr(ce, map),
    };
}

pub fn stmts(body: []ast.Stmt, map: *const Ctx) void {
    for (body) |*stmt| {
        const pending_mark = map.pending.items.len;
        if (stmt.kind == .expr_stmt and stmt.kind.expr_stmt == .call) {
            if (map.stmt_fors.get(@intFromPtr(stmt.kind.expr_stmt.call.callee))) |rw| stmt.kind = rw;
        }
        // v1.163.0: `obj[i] = v` → `obj.__setitem__(i, v)` (anahtar: indeks kutusu).
        if (stmt.kind == .assign and stmt.kind.assign.target == .index) {
            if (map.stmt_fors.get(@intFromPtr(stmt.kind.assign.target.index.index))) |rw| stmt.kind = rw;
        }
        switch (stmt.kind) {
            .expr_stmt => |*e| expr(e, map),
            .var_decl => |*v| {
                if (map.infers.get(@intFromPtr(v.name.ptr))) |te| v.type_expr = te;
                expr(&v.value, map);
            },
            .assign => |*a| {
                expr(&a.target, map);
                expr(&a.value, map);
            },
            .if_stmt => |*s| {
                expr(&s.cond, map);
                stmts(s.then_body, map);
                for (s.elif_clauses) |*ec| {
                    expr(&ec.cond, map);
                    stmts(ec.body, map);
                }
                if (s.else_body) |eb| stmts(eb, map);
            },
            .while_stmt => |*s| {
                expr(&s.cond, map);
                stmts(s.body, map);
            },
            .for_stmt => |*s| {
                if (map.fors.get(@intFromPtr(s.body.ptr))) |rw| {
                    if (rw.iterable) |it| s.iterable = it;
                    s.hoist = rw.hoist;
                }
                expr(&s.iterable, map);
                stmts(s.body, map);
            },
            .func_def => |fd| {
                map.in_func.* += 1;
                stmts(fd.body, map);
                map.in_func.* -= 1;
            },
            .class_def => |cd| for (cd.methods) |m| {
                map.in_func.* += 1;
                stmts(m.body, map);
                map.in_func.* -= 1;
            },
            .return_stmt => |*maybe| if (maybe.*) |*e| expr(e, map),
            .raise_stmt => |*e| expr(e, map),
            .del_stmt => |*e| expr(e, map),
            .try_stmt => |*s| {
                stmts(s.try_body, map);
                for (s.except_clauses) |ec| stmts(ec.body, map);
                if (s.finally_body) |fb| stmts(fb, map);
            },
            .lowlevel_stmt => |s| stmts(s.body, map),
            .with_stmt => |*s| {
                expr(&s.ctx_expr, map);
                stmts(s.body, map);
            },
            .defer_stmt => |*d| {
                if (map.calls.get(@intFromPtr(d.call.callee))) |exp| d.call.args = exp;
                expr(d.call.callee, map);
                for (d.call.args) |*a| expr(a, map);
            },
            .protocol_def, .extern_def, .import_stmt, .from_import_stmt, .pass_stmt, .break_stmt, .continue_stmt => {},
        }
        // v1.155.0: bu deyimin başlığında yükseltilen lambda `def`leri (fonksiyon içinde) deyimden ÖNCE tanımlanır: deyim, `def`lerle birlikte
        // `if True:` bloğuna sarılır (Nox'ta blok kapsamı yoktur; değişkenler fonksiyon boyunca görünür kalır).
        if (map.pending.items.len > pending_mark) {
            const defs = map.pending.items[pending_mark..];
            const inner = map.allocator.alloc(ast.Stmt, defs.len + 1) catch return;
            @memcpy(inner[0..defs.len], defs);
            inner[defs.len] = .{ .kind = stmt.kind, .line = stmt.line, .span = stmt.span };
            map.pending.shrinkRetainingCapacity(pending_mark);
            stmt.kind = .{ .if_stmt = .{ .cond = .{ .bool_lit = true }, .then_body = inner, .elif_clauses = &.{}, .else_body = null } };
        }
    }
}

pub fn expr(e: *ast.Expr, map: *const Ctx) void {
    switch (e.*) {
        .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => {},
        .unary => |*u| {
            // v1.163.0: `-obj` / `~obj` → `obj.__neg__()` / `obj.__invert__()` (anahtar: operand kutusu).
            if (map.exprs.get(@intFromPtr(u.operand))) |r| {
                e.* = r;
                expr(e, map);
                return;
            }
            expr(u.operand, map);
        },
        .kwarg => |*k| expr(k.value, map),
        .ternary => |*t| {
            expr(t.cond, map);
            expr(t.then_expr, map);
            expr(t.else_expr, map);
        },
        .binary => |*b| {
            // v1.163.0: operatör aşırı yükleme — `a + b` → `a.__add__(b)` (anahtar: sol işlenen kutusu).
            if (map.exprs.get(@intFromPtr(b.left))) |r| {
                e.* = r;
                expr(e, map);
                return;
            }
            expr(b.left, map);
            expr(b.right, map);
        },
        .call => |*c| {
            if (map.exprs.get(@intFromPtr(c.callee))) |r| {
                e.* = r;
                expr(e, map);
                return;
            }
            if (map.calls.get(@intFromPtr(c.callee))) |exp| c.args = exp;
            expr(c.callee, map);
            for (c.args) |*a| expr(a, map);
        },
        .attribute => |*a| expr(a.obj, map),
        .list_comp => |*lc| {
            expr(lc.elem, map);
            applyClauses(lc.clauses, map);
            if (map.comps.get(@intFromPtr(lc.elem))) |te| lc.result_type = te;
        },
        .dict_comp => |*dc| {
            expr(dc.key, map);
            expr(dc.value, map);
            applyClauses(dc.clauses, map);
            if (map.comps.get(@intFromPtr(dc.key))) |te| dc.result_type = te;
        },
        .lambda => |*lam| {
            const entry = map.lambdas.get(@intFromPtr(lam.body)) orelse {
                expr(lam.body, map);
                return;
            };
            const fd = entry.fd;
            // Gövdedeki iç içe lambda/çağrı genişletmeleri yükseltilmiş fonksiyonun gövdesinde işlenir.
            map.in_func.* += 1;
            stmts(fd.body, map);
            map.in_func.* -= 1;
            // Modül üst düzeyindeki lambda üst-düzey fonksiyona yükseltilir (yakaladığı modül değişkenleri global olarak terfi eder); fonksiyon içindeki
            // lambda deyimden önce iç içe `def` olur (yakalamalar closure mekanizmasıyla).
            if (map.in_func.* == 0) {
                map.lifted.append(map.allocator, fd) catch return;
            } else {
                map.pending.append(map.allocator, .{ .kind = .{ .func_def = fd } }) catch return;
            }
            e.* = .{ .identifier = fd.name };
        },
        .slice => |*sl| {
            expr(sl.obj, map);
            if (sl.lo) |x| expr(x, map);
            if (sl.hi) |x| expr(x, map);
            if (sl.step) |x| expr(x, map);
        },
        .index => |*ix| {
            if (map.exprs.get(@intFromPtr(ix.index))) |r| {
                e.* = r;
                expr(e, map);
                return;
            }
            expr(ix.obj, map);
            expr(ix.index, map);
        },
        .list_lit => |items| for (items) |*it| expr(it, map),
        .tuple_lit => |items| {
            if (map.exprs.get(@intFromPtr(items.ptr))) |r| {
                e.* = r;
                expr(e, map);
                return;
            }
            for (items) |*it| expr(it, map);
        },
        .dict_lit => |pairs| for (pairs) |*p| {
            expr(&p.key, map);
            expr(&p.value, map);
        },
        .await_expr => |op| expr(op, map),
        .spawn_expr => |op| expr(op, map),
        .generic_construct => |*g| {
            if (map.calls.get(@intFromPtr(g.resolved_class_name))) |exp| g.args = exp;
            for (g.args) |*a| expr(a, map);
        },
    }
}
