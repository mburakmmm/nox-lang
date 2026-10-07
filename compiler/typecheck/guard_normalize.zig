//! v1.156.0 (roadmap 1.12): koruma (guard) tarzı Optional daraltma — `if x is None: return` SONRASINDA `x` None-dışıdır.
//!
//! Genel bir akış analizi yerine, mevcut (kanıtlanmış) `if/else` daraltma mekanizmasına İNDİRGENİR: bir `if` deyiminin koşulu bir
//! `ident == None` yaprağı içeriyorsa (yalnızca `or` zincirleri üzerinden), `then` gövdesi HER ZAMAN çıkıyorsa (`return`/`raise`/
//! `break`/`continue`), `elif`/`else` yoksa, bloğun KALAN deyimleri `else` gövdesine taşınır (orijinal konumları `pass` olur). Anlamca
//! özdeştir (then her zaman çıkar), ama `else` dalında `x`in daraltılması checker ve codegen'de HAZIR çalışır. Nox'ta blok kapsamı
//! olmadığından (yerel değişkenler fonksiyon boyunca görünür) değişken görünürlüğü etkilenmez. Yalnızca FONKSİYON/METOD gövdelerinde
//! uygulanır (modül üst düzeyindeki `var_decl`ların global terfisi bozulmasın).

const std = @import("std");
const ast = @import("../parser/ast.zig");

pub fn run(a: std.mem.Allocator, body: []ast.Stmt) std.mem.Allocator.Error!void {
    for (body) |*stmt| switch (stmt.kind) {
        .func_def => |fd| try normalizeBlock(a, fd.body),
        .class_def => |cd| for (cd.methods) |m| try normalizeBlock(a, m.body),
        else => {},
    };
}

fn hasNoneCheckLeaf(cond: ast.Expr) bool {
    return switch (cond) {
        .binary => |b| switch (b.op) {
            .eq => (b.left.* == .identifier and b.right.* == .none_lit) or (b.right.* == .identifier and b.left.* == .none_lit),
            .or_ => hasNoneCheckLeaf(b.left.*) or hasNoneCheckLeaf(b.right.*),
            else => false,
        },
        else => false,
    };
}

fn alwaysExits(stmts: []const ast.Stmt) bool {
    if (stmts.len == 0) return false;
    return switch (stmts[stmts.len - 1].kind) {
        .return_stmt, .raise_stmt, .break_stmt, .continue_stmt => true,
        .if_stmt => |f| blk: {
            if (f.else_body == null) break :blk false;
            if (!alwaysExits(f.then_body)) break :blk false;
            for (f.elif_clauses) |ec| if (!alwaysExits(ec.body)) break :blk false;
            break :blk alwaysExits(f.else_body.?);
        },
        else => false,
    };
}

fn normalizeBlock(a: std.mem.Allocator, stmts: []ast.Stmt) std.mem.Allocator.Error!void {
    var i: usize = 0;
    while (i < stmts.len) : (i += 1) {
        const stmt = &stmts[i];
        if (stmt.kind == .if_stmt) {
            const f = &stmt.kind.if_stmt;
            if (f.else_body == null and f.elif_clauses.len == 0 and i + 1 < stmts.len and hasNoneCheckLeaf(f.cond) and alwaysExits(f.then_body)) {
                const rest = try a.alloc(ast.Stmt, stmts.len - i - 1);
                @memcpy(rest, stmts[i + 1 ..]);
                f.else_body = rest;
                // Koruma deyimi bloğun SON konumuna taşınır (öncekiler `pass`): son deyimin `if/else` olması "tüm yollarda return" analizini korur.
                const guard = stmt.*;
                for (stmts[i .. stmts.len - 1]) |*r| r.kind = .pass_stmt;
                stmts[stmts.len - 1] = guard;
                try normalizeBlock(a, f.then_body);
                try normalizeBlock(a, rest);
                return;
            }
        }
        try normalizeChildren(a, stmt);
    }
}

fn normalizeChildren(a: std.mem.Allocator, stmt: *ast.Stmt) std.mem.Allocator.Error!void {
    switch (stmt.kind) {
        .if_stmt => |*f| {
            try normalizeBlock(a, f.then_body);
            for (f.elif_clauses) |*ec| try normalizeBlock(a, ec.body);
            if (f.else_body) |eb| try normalizeBlock(a, eb);
        },
        .while_stmt => |*w| try normalizeBlock(a, w.body),
        .for_stmt => |*f| try normalizeBlock(a, f.body),
        .try_stmt => |*t| {
            try normalizeBlock(a, t.try_body);
            for (t.except_clauses) |ec| try normalizeBlock(a, ec.body);
            if (t.finally_body) |fb| try normalizeBlock(a, fb);
        },
        .with_stmt => |*w| try normalizeBlock(a, w.body),
        .lowlevel_stmt => |ll| try normalizeBlock(a, ll.body),
        .func_def => |fd| try normalizeBlock(a, fd.body),
        else => {},
    }
}
