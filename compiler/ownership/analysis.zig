//! Nox v0.1 sahiplik analizi (AGENTS.md §8, §7 adım 3).
//!
//! Önkoşul: girdi modülü Faz 2 tip denetleyicisinden (checker.zig) başarıyla
//! geçmiş olmalıdır (iyi tiplenmiş). Bu geçiş yalnızca heap tipli bağlamaları
//! (str, list[T], sınıf örnekleri) analiz eder; int/float/bool/None hiçbir
//! zaman bu analize girmez (registerde/yığında tutulur, destructor gerekmez).
//!
//! Karar kuralı (muhafazakâr — bkz. AGENTS.md §8 Katman 1: "yanlış pozitif
//! 'güvenli' karar asla verilmez"):
//!   - Parametreler (self dahil) HER ZAMAN Katman 2 (ARC)'dir: bir değerin
//!     fonksiyon sınırını geçtikten sonra çağıran tarafından tekrar
//!     kullanılmadığını kanıtlayacak bir ödünç/taşıma (borrow/move) analizi
//!     yoktur, dolayısıyla en güvenli seçenek olan ARC uygulanır.
//!   - Yerel `var_decl` bağlamaları varsayılan olarak Katman 1 (ASAP)'dir;
//!     aşağıdaki "kaçış" durumlarından biri tespit edilirse SESSİZCE Katman 2
//!     (ARC)'ye terfi eder (İlke #1: bu terfi kullanıcıya hiçbir şekilde
//!     yansımaz, yalnızca derleyici içi bir karardır):
//!       * `return <ad>` ile doğrudan döndürülme
//!       * `self.<alan> = <ad>` ile bir sınıf alanına atanma
//!       * `[..., <ad>, ...]` ile bir liste literaline eklenme
//!       * bir fonksiyon/metod çağrısına argüman ya da metod alıcısı olarak geçme
//!
//! Kapsam dışı (v0.1, bilinçli sınırlama — bkz. nox-teknik-spesifikasyon.md §3.3):
//!   - `for x in <iterable>:` döngü değişkenleri bu analize dahil değildir.
//!   - Sınıf alanlarının kendi başına ayrı bir ASAP/ARC kararı yoktur; alan
//!     ömrü sahibi olan örneğin kararına bağlıdır.

const std = @import("std");
const ast = @import("../parser/ast.zig");

pub const Decision = enum { asap, arc };

pub const Binding = struct {
    name: []const u8,
    type_name: []const u8,
    is_param: bool,
    decision: Decision,
    reason: []const u8,
    alloc_desc: []const u8,
    free_events: std.ArrayListUnmanaged([]const u8) = .empty,
};

pub const ScopeReport = struct {
    label: []const u8,
    bindings: std.ArrayListUnmanaged(Binding) = .empty,
};

pub const Report = struct {
    scopes: std.ArrayListUnmanaged(ScopeReport) = .empty,
};

const BindingMap = std.StringHashMapUnmanaged(usize);

pub const Analyzer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return .{ .allocator = allocator };
    }

    pub fn analyzeModule(self: *Analyzer, module: ast.Module, extra_functions: []const ast.FuncDef, generic_template_names: []const []const u8) !Report {
        var report: Report = .{};

        var loose: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        defer loose.deinit(self.allocator);
        for (module.body) |stmt| {
            switch (stmt) {
                .func_def, .class_def, .protocol_def, .extern_def => {},
                else => try loose.append(self.allocator, stmt),
            }
        }
        try report.scopes.append(self.allocator, try self.analyzeScope("modül", &.{}, loose.items));

        for (module.body) |stmt| {
            switch (stmt) {
                // Generic (Faz 10/11: açık `[T]` VEYA protokol parametresi
                // yoluyla örtük) fonksiyon ŞABLONLARI burada atlanır: tip
                // parametreleri/protokol adları somut değildir, anlamlı bir
                // analiz mümkün değildir. Somut örneklemeleri
                // (`extra_functions`) aşağıda sıradan fonksiyonlar gibi
                // analiz edilir.
                .func_def => |fd| {
                    if (fd.type_params.len > 0 or containsName(generic_template_names, fd.name)) continue;
                    const label = try std.fmt.allocPrint(self.allocator, "fonksiyon {s}", .{fd.name});
                    try report.scopes.append(self.allocator, try self.analyzeScope(label, fd.params, fd.body));
                },
                .class_def => |cd| {
                    for (cd.methods) |m| {
                        const label = try std.fmt.allocPrint(self.allocator, "metod {s}.{s}", .{ cd.name, m.name });
                        try report.scopes.append(self.allocator, try self.analyzeScope(label, m.params, m.body));
                    }
                },
                else => {},
            }
        }
        for (extra_functions) |fd| {
            const label = try std.fmt.allocPrint(self.allocator, "fonksiyon {s}", .{fd.name});
            try report.scopes.append(self.allocator, try self.analyzeScope(label, fd.params, fd.body));
        }
        return report;
    }

    fn analyzeScope(self: *Analyzer, label: []const u8, params: []const ast.Param, body: []const ast.Stmt) !ScopeReport {
        var scope: ScopeReport = .{ .label = label };
        var index_of: BindingMap = .empty;
        defer index_of.deinit(self.allocator);

        for (params) |p| {
            if (!isHeapTypeExpr(p.type_expr)) continue;
            const type_name = try typeExprName(self.allocator, p.type_expr);
            try scope.bindings.append(self.allocator, .{
                .name = p.name,
                .type_name = type_name,
                .is_param = true,
                .decision = .arc,
                .reason = "parametre: fonksiyon sınırını zaten geçti",
                .alloc_desc = "parametre",
            });
            try scope.bindings.items[scope.bindings.items.len - 1].free_events.append(self.allocator, "kapsam sonu");
            try index_of.put(self.allocator, p.name, scope.bindings.items.len - 1);
        }

        try self.collectVarDecls(&scope, &index_of, body);
        try self.scanStmts(&scope, &index_of, body);

        for (scope.bindings.items) |*b| {
            if (!b.is_param) try b.free_events.append(self.allocator, "kapsam sonu");
        }

        return scope;
    }

    fn collectVarDecls(self: *Analyzer, scope: *ScopeReport, index_of: *BindingMap, stmts: []const ast.Stmt) !void {
        for (stmts) |stmt| {
            switch (stmt) {
                .var_decl => |v| {
                    if (!isHeapTypeExpr(v.type_expr)) continue;
                    if (index_of.get(v.name)) |idx| {
                        try scope.bindings.items[idx].free_events.append(self.allocator, "yeniden tanımlama (var_decl)");
                        continue;
                    }
                    const type_name = try typeExprName(self.allocator, v.type_expr);
                    try scope.bindings.append(self.allocator, .{
                        .name = v.name,
                        .type_name = type_name,
                        .is_param = false,
                        .decision = .asap,
                        .reason = "kapsam içinde kalıyor (kaçış tespit edilmedi)",
                        .alloc_desc = "var_decl",
                    });
                    try index_of.put(self.allocator, v.name, scope.bindings.items.len - 1);
                },
                .if_stmt => |f| {
                    try self.collectVarDecls(scope, index_of, f.then_body);
                    for (f.elif_clauses) |ec| try self.collectVarDecls(scope, index_of, ec.body);
                    if (f.else_body) |eb| try self.collectVarDecls(scope, index_of, eb);
                },
                .while_stmt => |w| try self.collectVarDecls(scope, index_of, w.body),
                .for_stmt => |f| try self.collectVarDecls(scope, index_of, f.body),
                .try_stmt => |t| {
                    try self.collectVarDecls(scope, index_of, t.try_body);
                    for (t.except_clauses) |ec| {
                        if (ec.bind_name) |bn| {
                            if (!index_of.contains(bn)) {
                                try scope.bindings.append(self.allocator, .{
                                    .name = bn,
                                    .type_name = ec.class_name,
                                    .is_param = false,
                                    .decision = .asap,
                                    .reason = "kapsam içinde kalıyor (kaçış tespit edilmedi)",
                                    .alloc_desc = "except ... as",
                                });
                                try index_of.put(self.allocator, bn, scope.bindings.items.len - 1);
                            }
                        }
                        try self.collectVarDecls(scope, index_of, ec.body);
                    }
                    if (t.finally_body) |fb| try self.collectVarDecls(scope, index_of, fb);
                },
                else => {},
            }
        }
    }

    fn markArc(scope: *ScopeReport, index_of: *BindingMap, name: []const u8, reason: []const u8) void {
        const idx = index_of.get(name) orelse return;
        const b = &scope.bindings.items[idx];
        if (b.is_param) return; // zaten ARC
        b.decision = .arc;
        b.reason = reason;
    }

    fn markEscapeIfIdentifier(scope: *ScopeReport, index_of: *BindingMap, e: ast.Expr, reason: []const u8) void {
        if (e == .identifier) markArc(scope, index_of, e.identifier, reason);
    }

    fn scanStmts(self: *Analyzer, scope: *ScopeReport, index_of: *BindingMap, stmts: []const ast.Stmt) !void {
        for (stmts) |stmt| {
            switch (stmt) {
                .var_decl => |v| {
                    // `ys: T = xs` gibi bir takma ad (alias) durumu, `xs`'in ömrünü
                    // `ys` ile dolaştırır; bu da başlı başına bir kaçıştır (İlke #8:
                    // muhafazakâr olmak zorunda — aksi kanıtlanamaz).
                    markEscapeIfIdentifier(scope, index_of, v.value, "başka bir değişkene (isimle) atandığı için (takma ad)");
                    self.scanExprEscapes(scope, index_of, v.value);
                },
                .assign => |a| {
                    switch (a.target) {
                        .identifier => |name| {
                            if (index_of.get(name)) |idx| {
                                try scope.bindings.items[idx].free_events.append(self.allocator, "yeniden atama");
                            }
                            markEscapeIfIdentifier(scope, index_of, a.value, "başka bir değişkene (isimle) atandığı için (takma ad)");
                        },
                        .attribute => |attr| {
                            if (attr.obj.* == .identifier and std.mem.eql(u8, attr.obj.identifier, "self")) {
                                markEscapeIfIdentifier(scope, index_of, a.value, "bir sınıf alanına atandığı için (self.<alan>)");
                            }
                        },
                        else => {},
                    }
                    self.scanExprEscapes(scope, index_of, a.value);
                },
                .expr_stmt => |e| self.scanExprEscapes(scope, index_of, e),
                .if_stmt => |f| {
                    self.scanExprEscapes(scope, index_of, f.cond);
                    try self.scanStmts(scope, index_of, f.then_body);
                    for (f.elif_clauses) |ec| {
                        self.scanExprEscapes(scope, index_of, ec.cond);
                        try self.scanStmts(scope, index_of, ec.body);
                    }
                    if (f.else_body) |eb| try self.scanStmts(scope, index_of, eb);
                },
                .while_stmt => |w| {
                    self.scanExprEscapes(scope, index_of, w.cond);
                    try self.scanStmts(scope, index_of, w.body);
                },
                .for_stmt => |f| {
                    self.scanExprEscapes(scope, index_of, f.iterable);
                    try self.scanStmts(scope, index_of, f.body);
                },
                .return_stmt => |r| {
                    if (r) |e| {
                        markEscapeIfIdentifier(scope, index_of, e, "fonksiyondan döndürüldüğü için");
                        self.scanExprEscapes(scope, index_of, e);
                    }
                },
                .raise_stmt => |e| {
                    markEscapeIfIdentifier(scope, index_of, e, "raise ile fırlatıldığı için");
                    self.scanExprEscapes(scope, index_of, e);
                },
                .try_stmt => |t| {
                    try self.scanStmts(scope, index_of, t.try_body);
                    for (t.except_clauses) |ec| try self.scanStmts(scope, index_of, ec.body);
                    if (t.finally_body) |fb| try self.scanStmts(scope, index_of, fb);
                },
                // `lowlevel` içindeki bağlamalar bilerek taranmıyor: farklı bir
                // tahsis stratejisi (arena) tarafından yönetiliyorlar ve bu
                // modülün ASAP/ARC karar alanının bir parçası değiller (bkz.
                // nox-teknik-spesifikasyon.md §3.8).
                .func_def, .class_def, .protocol_def, .extern_def, .pass_stmt, .lowlevel_stmt, .import_stmt => {},
            }
        }
    }

    fn scanExprEscapes(self: *Analyzer, scope: *ScopeReport, index_of: *BindingMap, expr: ast.Expr) void {
        switch (expr) {
            .list_lit => |elems| {
                for (elems) |el| {
                    markEscapeIfIdentifier(scope, index_of, el, "bir liste literaline eklendiği için");
                    self.scanExprEscapes(scope, index_of, el);
                }
            },
            .dict_lit => |pairs| {
                for (pairs) |p| {
                    markEscapeIfIdentifier(scope, index_of, p.key, "bir dict literaline anahtar olarak eklendiği için");
                    self.scanExprEscapes(scope, index_of, p.key);
                    markEscapeIfIdentifier(scope, index_of, p.value, "bir dict literaline değer olarak eklendiği için");
                    self.scanExprEscapes(scope, index_of, p.value);
                }
            },
            .call => |c| {
                // 'print' derleyiciye gömülü, bilinen bir yerleşiktir (bkz. checker.zig):
                // argümanını hiçbir yerde saklamadığı kesin olarak bilindiği için
                // (kullanıcı tanımlı fonksiyonların aksine) kaçış saymıyoruz.
                const is_print = c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, "print");
                for (c.args) |a| {
                    if (!is_print) markEscapeIfIdentifier(scope, index_of, a, "bir çağrıya argüman olarak geçildiği için");
                    self.scanExprEscapes(scope, index_of, a);
                }
                switch (c.callee.*) {
                    .attribute => |a| {
                        markEscapeIfIdentifier(scope, index_of, a.obj.*, "bir metod çağrısının alıcısı olduğu için");
                        self.scanExprEscapes(scope, index_of, a.obj.*);
                    },
                    else => self.scanExprEscapes(scope, index_of, c.callee.*),
                }
            },
            .binary => |b| {
                self.scanExprEscapes(scope, index_of, b.left.*);
                self.scanExprEscapes(scope, index_of, b.right.*);
            },
            .unary => |u| self.scanExprEscapes(scope, index_of, u.operand.*),
            .attribute => |a| self.scanExprEscapes(scope, index_of, a.obj.*),
            .index => |idx| {
                self.scanExprEscapes(scope, index_of, idx.obj.*);
                self.scanExprEscapes(scope, index_of, idx.index.*);
            },
            .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => {},
            // `spawn <çağrı>`nın operandı ZATEN bir `.call`dır — bu dalın
            // MEVCUT mantığı (yukarıda) argümanlarını ZATEN kaçış olarak
            // işaretler, ki bu spawn için hatta DAHA da gereklidir (görev
            // eşzamansız çalıştığından argümanlar mevcut çağrı çerçevesinden
            // UZUN yaşayabilir). `await <ifade>` yalnızca OKUR (bir Task'ı
            // sahiplenmez/tüketmez), bu yüzden operandının kendisi kaçış
            // olarak işaretlenmez — normal bir ikili işlem okuması gibi.
            .await_expr => |operand| self.scanExprEscapes(scope, index_of, operand.*),
            .spawn_expr => |operand| self.scanExprEscapes(scope, index_of, operand.*),
            .generic_construct => |g| {
                for (g.args) |a| self.scanExprEscapes(scope, index_of, a);
            },
        }
    }
};

fn containsName(list: []const []const u8, name: []const u8) bool {
    for (list) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn isHeapTypeExpr(te: ast.TypeExpr) bool {
    return switch (te) {
        .simple => |name| !(std.mem.eql(u8, name, "int") or std.mem.eql(u8, name, "float") or
            std.mem.eql(u8, name, "bool") or std.mem.eql(u8, name, "None")),
        .generic => true,
    };
}

fn typeExprName(allocator: std.mem.Allocator, te: ast.TypeExpr) ![]const u8 {
    return switch (te) {
        .simple => |name| name,
        .generic => |g| blk: {
            if (g.args.len == 0) break :blk try std.fmt.allocPrint(allocator, "{s}[]", .{g.name});
            const inner = try typeExprName(allocator, g.args[0]);
            break :blk try std.fmt.allocPrint(allocator, "{s}[{s}]", .{ g.name, inner });
        },
    };
}

/// Bir modülü analiz eder. Girdinin Faz 2 tip denetiminden geçmiş olması
/// önkoşuldur. `extra_functions`: Faz 10'un checker tarafından üretilen
/// somut (monomorphize edilmiş) generic fonksiyon örneklemeleri (boş
/// olabilir — generic kullanılmayan modüllerde `&.{}` verilir).
/// `generic_template_names`: `checker.Checker.generic_functions`in anahtarları
/// (generic kullanılmıyorsa `&.{}`) — bkz. `analyzeModule` belge notu.
pub fn analyze(allocator: std.mem.Allocator, module: ast.Module, extra_functions: []const ast.FuncDef, generic_template_names: []const []const u8) !Report {
    var analyzer = Analyzer.init(allocator);
    return analyzer.analyzeModule(module, extra_functions, generic_template_names);
}

pub fn dumpReport(writer: *std.Io.Writer, report: Report) std.Io.Writer.Error!void {
    for (report.scopes.items) |scope| {
        try writer.print("[{s}]\n", .{scope.label});
        if (scope.bindings.items.len == 0) {
            try writer.writeAll("  (heap tipli bağlama yok)\n");
        }
        for (scope.bindings.items) |b| {
            try writer.print("  {s}: {s}{s} -> {s} ({s})\n", .{
                b.name,
                b.type_name,
                if (b.is_param) " (parametre)" else "",
                if (b.decision == .asap) "ASAP" else "ARC",
                b.reason,
            });
            try writer.print("    tahsis: {s}\n", .{b.alloc_desc});
            for (b.free_events.items) |fe| {
                try writer.print("    serbest: {s}\n", .{fe});
            }
        }
    }
}

pub fn dumpToAlloc(allocator: std.mem.Allocator, report: Report) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try dumpReport(&aw.writer, report);
    return aw.toOwnedSlice();
}
