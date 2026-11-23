//! R1-P0.4 (GPT-6 sağlamlaştırma raporu): "bir çağrı sınıf ALANLARINI değiştirebilir mi?" için modül-düzeyi, muhafazakâr, dolaylı (transitif) özet.
//!
//! Optional özellik-yolu daraltması (`n.left != None and n.left.depth() > 0`) yalnızca sağ operandın alan yazamadığı KANITLANABİLDİĞİNDE korunur. Çağrı hedefleri AD ile çözülür
//! (serbest işlev adı; metot adı — o adı taşıyan HERHANGİ bir sınıfın metodu, alt sınıf/protokol dağıtımı dahil): bir ad yalnızca onu taşıyan TÜM tanımlar güvenliyse güvenlidir.
//!
//! Bir işlev doğrudan "güvensiz" sayılır: (a) `X.f = ...` ataması — yalnızca `__init__` içinde doğrudan `self.f = ...` güvenlidir (yeni nesne yazılıyor, daha önce daraltılmış bir yol değil);
//! (b) `await`/`spawn`/`lowlevel`/`with` (kullanıcı kodu ya da ham bellek); (c) çözülemeyen ya da değer olarak çağrılan hedef (işlev değeri/closure parametresi, `extern def`).
//! Güvensizlik çağrı grafiği üzerinde ters yönde yayılır (`effect_graph.propagateBad`). Yan etkisiz yerleşikler (`len`, `str`, `print` ...) ve kullanıcı tanımlı olmayan ad taşıyan
//! metot çağrıları (`xs.append(...)`, `s.startswith(...)`: yerleşik koleksiyon/dize metotları) güvenlidir. Kapsam dışı (bilinçli): kullanıcı dunder'ı/`@property` — bkz. `Checker.dunder_hit`.

const std = @import("std");
const ast = @import("../parser/ast.zig");
const effect_graph = @import("../effect_graph.zig");

const NodeKey = effect_graph.NodeKey;

pub const Summary = struct {
    allocator: std.mem.Allocator,
    bad: effect_graph.NodeSet,
    /// Bu adlı en az bir kullanıcı tanımı var mı (`f:ad` / `m:ad` / sınıf adı)?
    defined: std.StringHashMapUnmanaged(void),
    classes: std.StringHashMapUnmanaged(void),
    /// R1-P0.5 (v2.2.48): kullanıcı dunder'ı (`__str__`/`__len__`/... `__init__` hariç) bir alan yazıyorsa dunder'ı örtük çağıran yerleşikler (`print/str/len/...`) artık yan etkisiz SAYILMAZ.
    unsafe_dunders: std.StringHashMapUnmanaged(void) = .empty,

    const pure_builtins = [_][]const u8{
        "len",   "str",  "int",  "float",  "bool",      "print", "abs", "min", "max",        "round", "sum", "repr", "ord", "chr", "range",
        "super", "list", "dict", "sorted", "enumerate", "zip",   "any", "all", "isinstance",
    };

    fn isPureBuiltin(name: []const u8) bool {
        return isPureBuiltinWith(name, null);
    }

    /// Yerleşiğin örtük çağırabileceği dunder'lar (yalnızca bunlardan biri alan yazıyorsa yerleşik güvensizdir).
    fn relatedDunders(name: []const u8) []const []const u8 {
        const eq = std.mem.eql;
        if (eq(u8, name, "str") or eq(u8, name, "print") or eq(u8, name, "repr")) return &.{ "__str__", "__repr__" };
        if (eq(u8, name, "len")) return &.{"__len__"};
        if (eq(u8, name, "bool") or eq(u8, name, "any") or eq(u8, name, "all")) return &.{ "__bool__", "__len__", "__iter__", "__next__" };
        if (eq(u8, name, "int")) return &.{ "__int__", "__index__" };
        if (eq(u8, name, "float")) return &.{"__float__"};
        if (eq(u8, name, "abs")) return &.{"__abs__"};
        if (eq(u8, name, "round")) return &.{"__round__"};
        if (eq(u8, name, "min") or eq(u8, name, "max") or eq(u8, name, "sorted")) return &.{ "__lt__", "__gt__", "__le__", "__ge__", "__eq__", "__iter__", "__next__" };
        if (eq(u8, name, "sum")) return &.{ "__add__", "__radd__", "__iter__", "__next__" };
        if (eq(u8, name, "list") or eq(u8, name, "dict") or eq(u8, name, "enumerate") or eq(u8, name, "zip")) return &.{ "__iter__", "__next__", "__getitem__", "__len__" };
        return &.{};
    }

    /// `unsafe`: alan yazan kullanıcı dunder adları; yerleşiğin ilgili dunder'larından biri kümedeyse saf SAYILMAZ.
    fn isPureBuiltinWith(name: []const u8, unsafe: ?*const std.StringHashMapUnmanaged(void)) bool {
        if (unsafe) |set| {
            for (relatedDunders(name)) |d| if (set.contains(d)) return false;
        }
        for (pure_builtins) |n| if (std.mem.eql(u8, n, name)) return true;
        return std.mem.startsWith(u8, name, "__nox_");
    }

    /// `c` çağrısı (hedef işlevinin yürütülmesi) kullanıcı koduyla bir sınıf alanını değiştirebilir mi? (Argüman ifadelerinin kendisi çağıranda ayrıca taranır.)
    pub fn callMayWriteFields(self: *const Summary, c: ast.Call) bool {
        switch (c.callee.*) {
            .identifier => |n| {
                if (self.defined.contains(n)) return self.isBad("f", n);
                if (self.classes.contains(n)) return self.isBad("m", "__init__");
                return !isPureBuiltinWith(n, &self.unsafe_dunders);
            },
            .attribute => |a| {
                if (self.defined.contains(a.attr)) return self.isBad("m", a.attr);
                return false; // yerleşik koleksiyon/dize/sözlük metodu
            },
            else => return true, // değer olarak çağrılan hedef (closure/işlev değeri/çağrı sonucu)
        }
    }

    pub fn constructorMayWrite(self: *const Summary) bool {
        return self.isBad("m", "__init__");
    }

    fn isBad(self: *const Summary, kind: []const u8, name: []const u8) bool {
        var buf: [256]u8 = undefined;
        if (kind.len + 1 + name.len > buf.len) return true;
        const key = std.fmt.bufPrint(&buf, "{s}:{s}", .{ kind, name }) catch return true;
        return self.bad.contains(.{ .func = key, .index = 0 });
    }
};

const Builder = struct {
    allocator: std.mem.Allocator,
    unsafe_dunders: ?*const std.StringHashMapUnmanaged(void) = null,
    seeds: std.ArrayListUnmanaged(NodeKey) = .empty,
    reverse: effect_graph.ReverseEdges = .empty,
    defined: std.StringHashMapUnmanaged(void) = .empty,
    classes: std.StringHashMapUnmanaged(void) = .empty,
    /// Şu an taranan işlevin düğüm anahtarı (`f:ad` / `m:ad`).
    cur: NodeKey = .{ .func = "", .index = 0 },
    cur_self: ?[]const u8 = null,
    cur_is_init: bool = false,

    fn key(self: *Builder, kind: []const u8, name: []const u8) !NodeKey {
        return .{ .func = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ kind, name }), .index = 0 };
    }

    fn seed(self: *Builder) !void {
        try self.seeds.append(self.allocator, self.cur);
    }

    /// `cur` düğümü `callee` düğümüne bağlıdır: `callee` kötüyse `cur` de kötü.
    fn edge(self: *Builder, callee: NodeKey) !void {
        const gop = try self.reverse.getOrPut(self.allocator, callee);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, self.cur);
    }

    fn collectDefs(self: *Builder, stmts: []const ast.Stmt) !void {
        for (stmts) |*st| switch (st.kind) {
            .func_def => |fd| {
                try self.defined.put(self.allocator, fd.name, {});
                try self.collectDefs(fd.body);
            },
            .class_def => |cd| {
                try self.classes.put(self.allocator, cd.name, {});
                for (cd.methods) |m| {
                    try self.defined.put(self.allocator, m.name, {});
                    try self.collectDefs(m.body);
                }
            },
            .protocol_def => |pd| for (pd.methods) |m| try self.defined.put(self.allocator, m.name, {}),
            .extern_def => |ed| try self.defined.put(self.allocator, ed.name, {}),
            .if_stmt => |f| {
                try self.collectDefs(f.then_body);
                for (f.elif_clauses) |ec| try self.collectDefs(ec.body);
                if (f.else_body) |eb| try self.collectDefs(eb);
            },
            .while_stmt => |w| try self.collectDefs(w.body),
            .for_stmt => |f| try self.collectDefs(f.body),
            .try_stmt => |t| {
                try self.collectDefs(t.try_body);
                for (t.except_clauses) |ec| try self.collectDefs(ec.body);
                if (t.finally_body) |fb| try self.collectDefs(fb);
            },
            .with_stmt => |w| try self.collectDefs(w.body),
            .lowlevel_stmt => |l| try self.collectDefs(l.body),
            else => {},
        };
    }

    fn scanTop(self: *Builder, stmts: []const ast.Stmt) !void {
        for (stmts) |*st| switch (st.kind) {
            .func_def => |fd| try self.scanFunc("f", fd, null, false),
            .class_def => |cd| for (cd.methods) |m| {
                const self_name: ?[]const u8 = if (m.params.len > 0) m.params[0].name else null;
                try self.scanFunc("m", m, self_name, std.mem.eql(u8, m.name, "__init__"));
            },
            else => {},
        };
    }

    fn scanFunc(self: *Builder, kind: []const u8, fd: ast.FuncDef, self_name: ?[]const u8, is_init: bool) !void {
        const saved = .{ self.cur, self.cur_self, self.cur_is_init };
        defer {
            self.cur = saved[0];
            self.cur_self = saved[1];
            self.cur_is_init = saved[2];
        }
        self.cur = try self.key(kind, fd.name);
        self.cur_self = self_name;
        self.cur_is_init = is_init;
        try self.scanStmts(fd.body);
    }

    fn scanStmts(self: *Builder, stmts: []const ast.Stmt) error{OutOfMemory}!void {
        for (stmts) |*st| try self.scanStmt(st.*);
    }

    fn scanStmt(self: *Builder, st: ast.Stmt) error{OutOfMemory}!void {
        switch (st.kind) {
            .expr_stmt => |e| try self.scanExpr(e),
            .var_decl => |v| try self.scanExpr(v.value),
            .assign => |a| {
                try self.scanExpr(a.value);
                switch (a.target) {
                    .attribute => |t| {
                        const direct_self_in_init = self.cur_is_init and t.obj.* == .identifier and self.cur_self != null and std.mem.eql(u8, t.obj.identifier, self.cur_self.?);
                        if (!direct_self_in_init) try self.seed();
                        try self.scanExpr(t.obj.*);
                    },
                    .index => |ix| {
                        try self.scanExpr(ix.obj.*);
                        try self.scanExpr(ix.index.*);
                    },
                    else => {},
                }
            },
            .if_stmt => |f| {
                try self.scanExpr(f.cond);
                try self.scanStmts(f.then_body);
                for (f.elif_clauses) |ec| {
                    try self.scanExpr(ec.cond);
                    try self.scanStmts(ec.body);
                }
                if (f.else_body) |eb| try self.scanStmts(eb);
            },
            .while_stmt => |w| {
                try self.scanExpr(w.cond);
                try self.scanStmts(w.body);
            },
            .for_stmt => |f| {
                try self.scanExpr(f.iterable);
                try self.scanStmts(f.body);
            },
            .func_def => |fd| try self.scanStmts(fd.body), // iç içe işlev: gövdesi kapsayanın parçası (muhafazakâr)
            .return_stmt => |r| if (r) |e| try self.scanExpr(e),
            .raise_stmt => |e| try self.scanExpr(e),
            .del_stmt => |e| try self.scanExpr(e),
            .try_stmt => |t| {
                try self.scanStmts(t.try_body);
                for (t.except_clauses) |ec| try self.scanStmts(ec.body);
                if (t.finally_body) |fb| try self.scanStmts(fb);
            },
            .defer_stmt => |d| try self.scanCall(d.call),
            .with_stmt, .lowlevel_stmt => try self.seed(),
            .class_def, .protocol_def, .extern_def, .type_alias, .import_stmt, .from_import_stmt, .pass_stmt, .break_stmt, .continue_stmt => {},
        }
    }

    fn scanCall(self: *Builder, c: ast.Call) error{OutOfMemory}!void {
        for (c.args) |arg| try self.scanExpr(arg);
        switch (c.callee.*) {
            .identifier => |n| {
                if (self.defined.contains(n)) {
                    try self.edge(try self.key("f", n));
                } else if (self.classes.contains(n)) {
                    try self.edge(try self.key("m", "__init__"));
                } else if (!Summary.isPureBuiltinWith(n, self.unsafe_dunders)) {
                    try self.seed(); // çözülemeyen ad: işlev değeri/closure parametresi/dış simge
                }
            },
            .attribute => |a| {
                try self.scanExpr(a.obj.*);
                if (self.defined.contains(a.attr)) try self.edge(try self.key("m", a.attr));
            },
            else => {
                try self.scanExpr(c.callee.*);
                try self.seed();
            },
        }
    }

    fn scanExpr(self: *Builder, e: ast.Expr) error{OutOfMemory}!void {
        switch (e) {
            .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => {},
            .unary => |u| try self.scanExpr(u.operand.*),
            .binary => |b| {
                try self.scanExpr(b.left.*);
                try self.scanExpr(b.right.*);
            },
            .call => |c| try self.scanCall(c),
            .attribute => |a| try self.scanExpr(a.obj.*),
            .index => |ix| {
                try self.scanExpr(ix.obj.*);
                try self.scanExpr(ix.index.*);
            },
            .slice => |sl| {
                try self.scanExpr(sl.obj.*);
                if (sl.lo) |x| try self.scanExpr(x.*);
                if (sl.hi) |x| try self.scanExpr(x.*);
                if (sl.step) |x| try self.scanExpr(x.*);
            },
            .list_lit, .tuple_lit => |items| for (items) |it| try self.scanExpr(it),
            .dict_lit => |pairs| for (pairs) |p| {
                try self.scanExpr(p.key);
                try self.scanExpr(p.value);
            },
            .ternary => |t| {
                try self.scanExpr(t.cond.*);
                try self.scanExpr(t.then_expr.*);
                try self.scanExpr(t.else_expr.*);
            },
            .kwarg => |k| try self.scanExpr(k.value.*),
            .generic_construct => |g| {
                for (g.args) |arg| try self.scanExpr(arg);
                try self.edge(try self.key("m", "__init__"));
            },
            .list_comp => |lc| {
                try self.scanExpr(lc.elem.*);
                for (lc.clauses) |cl| switch (cl) {
                    .for_clause => |fc| try self.scanExpr(fc.iterable),
                    .if_clause => |ce| try self.scanExpr(ce),
                };
            },
            .dict_comp => |dc| {
                try self.scanExpr(dc.key.*);
                try self.scanExpr(dc.value.*);
                for (dc.clauses) |cl| switch (cl) {
                    .for_clause => |fc| try self.scanExpr(fc.iterable),
                    .if_clause => |ce| try self.scanExpr(ce),
                };
            },
            .lambda => |l| try self.scanExpr(l.body.*),
            .await_expr, .spawn_expr => try self.seed(),
        }
    }
};

/// `body` (içe aktarılan modüller dahil birleştirilmiş modül gövdesi) için özet kurar. Bellek `allocator`dadır (derleme boyunca yaşar; arena beklenir).
pub fn build(allocator: std.mem.Allocator, body: []const ast.Stmt) !Summary {
    var unsafe: std.StringHashMapUnmanaged(void) = .empty;
    var pass: u8 = 0;
    while (true) : (pass += 1) {
        var b: Builder = .{ .allocator = allocator, .unsafe_dunders = if (pass == 0) null else &unsafe };
        try b.collectDefs(body);
        try b.scanTop(body);
        // `extern def` adları: çağrıları dış koddur → güvensiz tohum (`defined`da olduklarından kenarsız kalmasın)
        for (body) |*st| switch (st.kind) {
            .extern_def => |ed| try b.seeds.append(allocator, try b.key("f", ed.name)),
            else => {},
        };
        const bad = try effect_graph.propagateBad(allocator, &b.reverse, b.seeds.items);
        var sum: Summary = .{ .allocator = allocator, .bad = bad, .defined = b.defined, .classes = b.classes, .unsafe_dunders = unsafe };
        // 1. geçiş: yerleşikler saf varsayılır; alan yazan dunder'lar (`m:__x__`, `__init__` hariç) toplanır. Varsa 2. geçiş ilgili yerleşikleri güvensiz sayarak yeniden kurar.
        if (pass == 0) {
            var it = b.defined.keyIterator();
            while (it.next()) |k| {
                if (k.len > 4 and std.mem.startsWith(u8, k.*, "__") and std.mem.endsWith(u8, k.*, "__") and !std.mem.eql(u8, k.*, "__init__") and sum.isBad("m", k.*)) try unsafe.put(allocator, k.*, {});
            }
            if (unsafe.count() > 0) continue;
        }
        return sum;
    }
}
