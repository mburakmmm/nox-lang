//! Faz 9.0 dilim 3 (v2.1.122): işçiler arasında PAYLAŞILAN modül düzeyi `list[T]` ve `dict[K, str]` global'leri — kullanım çözümlemesi ve codegen yönlendirmesi.
//!
//! Strateji (bkz. `project/faz9-kontrol-debug-analizi-2026-11.md` §D.2): bu globaller YALNIZ ad üzerinden ve izinli biçimlerde kullanıldığında paylaşılan tek globals bloğunda yaşar; takma ad (alias) yoktur.
//! - `list`: yuvaya listenin kendisi değil, `runtime/collections/shared_list.zig` hücresi konur (liste büyürken yeniden tahsis edilir). Yazıcılar (`append`/`pop`/`clear`/`xs[i] = v`) ve O(1) okuyucular
//!   (`xs[i]`, `len(xs)`) hücreye yönlendirilir; diğer salt-okunur kullanımlar (`x in xs`, dilim, `print(xs)`) listenin ANLIK KOPYASINI (snapshot) okur.
//! - `dict[K, str]`: sözlüğün kendi kilidi vardır (`nox_dict_make_shared`); okumalar (`d[k]`, `d.get`) `str` değeri kilit altında RETAIN ederek (sahipli) döndürür.
//! Çözümleme izinli listenin DIŞINDA tek bir kullanım bulursa global bu kipe ALINMAZ (program v2.1.117 kuralıyla tek işçide kalır).

const std = @import("std");
const ast = @import("../parser/ast.zig");
const types = @import("types.zig");
const abi = @import("abi.zig");
const codegen = @import("codegen.zig");
const calls = @import("calls.zig");

const Codegen = codegen.Codegen;
const RT_PARAM = types.RT_PARAM;
const Value = types.Value;
const QbeType = types.QbeType;
const CodegenError = abi.CodegenError;
const GlobalVar = types.GlobalVar;

/// `list_ro`: bir işlevin LİSTE PARAMETRESİNİN salt-okunur olup olmadığını denetlemek için (yazıcı yok); yalnız çözümleme içindir.
pub const Kind = enum { list, dict_str, list_ro };

/// Hücre/işlem ABI'si için eleman şekli: `esz` bayt (1 ya da 8), `kind` 0 skaler / 1 `str`.
pub const ElemShape = struct { esz: u8, kind: u8 };

pub fn listElemShape(info: types.TypeInfo) ?ElemShape {
    if (info.elem_fixed_int != null) return null;
    if (info.elem_heap_info) |ehi| {
        if (ehi.heap == .str and ehi.nested == null) return .{ .esz = 8, .kind = 1 };
        // Sınıf örneği elemanlar: paylaşım güvenliği (`isSharedSafeClass`) sınıflamada ayrıca doğrulanır.
        if (ehi.heap == .class and ehi.nested == null and ehi.class_name != null) return .{ .esz = 8, .kind = 2 };
        return null;
    }
    if (info.elem_is_str) return .{ .esz = 8, .kind = 1 };
    return switch (info.elem_qtype) {
        .l, .d => .{ .esz = 8, .kind = 0 },
        .b => .{ .esz = 1, .kind = 0 },
        else => null,
    };
}

// ---- Kullanım çözümlemesi ---------------------------------------------------------------------------------------------------------------------------------------

/// İşlev tablosu ve "parametre salt-okunur mu" önbelleği (liste global'ini işlev argümanı olarak geçirebilmek için; bkz. `paramReadOnly`).
const Ctx = struct {
    a: std.mem.Allocator,
    funcs: std.StringHashMapUnmanaged(*const ast.FuncDef) = .empty,
    memo: std.StringHashMapUnmanaged(bool) = .empty,

    /// `fd`nin `idx`. parametresi salt-okunur mu: gövdede yalnız izinli OKUMA biçimlerinde (indeks okuma, `len`, `in`, dilim, `print`, `for` ile gezme, başka bir salt-okunur parametreye geçirme) geçer;
    /// yazma, metod çağrısı, atama, dönüş, yakalama yok. Özyineleme için iyimser varsayım (döngüdeki çağrılar salt-okunur sayılır; başka bir ihlal yine yakalanır).
    fn paramReadOnly(self: *Ctx, fd: *const ast.FuncDef, idx: usize) bool {
        if (fd.type_params.len > 0 or fd.decorators.len > 0) return false;
        if (idx >= fd.params.len) return false;
        const p = fd.params[idx];
        if (p.variadic or p.var_kw) return false;
        const key = std.fmt.allocPrint(self.a, "{s}#{d}", .{ fd.name, idx }) catch return false;
        if (self.memo.get(key)) |r| return r;
        self.memo.put(self.a, key, true) catch return false; // iyimser (özyineleme)
        var w: Walker = .{ .name = p.name, .kind = .list_ro, .ctx = self };
        for (fd.params, 0..) |q, j| if (j != idx and std.mem.eql(u8, q.name, p.name)) {
            w.bad = true;
        };
        w.stmts(fd.body, false);
        self.memo.put(self.a, key, !w.bad) catch return false;
        return !w.bad;
    }
};

const Walker = struct {
    name: []const u8,
    kind: Kind,
    ctx: *Ctx,
    bad: bool = false,

    fn isG(self: *const Walker, e: ast.Expr) bool {
        return e == .identifier and std.mem.eql(u8, e.identifier, self.name);
    }

    fn allowedMethod(self: *const Walker, m: []const u8, nargs: usize) bool {
        switch (self.kind) {
            .list => {
                if (std.mem.eql(u8, m, "append")) return nargs == 1;
                if (std.mem.eql(u8, m, "pop") or std.mem.eql(u8, m, "clear")) return nargs == 0;
                return false;
            },
            .list_ro => return false,
            .dict_str => {
                if (std.mem.eql(u8, m, "get")) return nargs == 1 or nargs == 2;
                if (std.mem.eql(u8, m, "pop")) return nargs == 1;
                if (std.mem.eql(u8, m, "keys") or std.mem.eql(u8, m, "values")) return nargs == 0;
                return false;
            },
        }
    }

    fn allowedBuiltin(self: *const Walker, f: []const u8) bool {
        if (self.ctx.funcs.contains(f)) return false;
        if (std.mem.eql(u8, f, "len")) return true;
        return self.kind != .dict_str and std.mem.eql(u8, f, "print");
    }

    fn stmts(self: *Walker, list: []const ast.Stmt, top: bool) void {
        for (list) |st| self.stmt(st, top);
    }

    fn params(self: *Walker, ps: []const ast.Param) void {
        for (ps) |p| if (std.mem.eql(u8, p.name, self.name)) {
            self.bad = true;
        };
    }

    fn stmt(self: *Walker, st: ast.Stmt, top: bool) void {
        if (self.bad) return;
        switch (st.kind) {
            .expr_stmt => |e| self.expr(e),
            .var_decl => |v| {
                if (std.mem.eql(u8, v.name, self.name) and !top) self.bad = true;
                self.expr(v.value);
            },
            .assign => |asg| {
                if (asg.target == .index and self.isG(asg.target.index.obj.*)) {
                    if (self.kind == .list_ro) self.bad = true;
                    self.expr(asg.target.index.index.*);
                    self.expr(asg.value);
                } else {
                    self.expr(asg.target);
                    self.expr(asg.value);
                }
            },
            .if_stmt => |f| {
                self.expr(f.cond);
                self.stmts(f.then_body, false);
                for (f.elif_clauses) |ec| {
                    self.expr(ec.cond);
                    self.stmts(ec.body, false);
                }
                if (f.else_body) |eb| self.stmts(eb, false);
            },
            .while_stmt => |w| {
                self.expr(w.cond);
                self.stmts(w.body, false);
            },
            .for_stmt => |f| {
                if (std.mem.eql(u8, f.var_name, self.name)) self.bad = true;
                // `for x in xs` (liste): checker iterable'ı gizli yerele alır; paylaşılan listede bu yerel O ANKİ KOPYADIR (anlık görüntü).
                if (!((self.kind == .list or self.kind == .list_ro) and self.isG(f.iterable))) self.expr(f.iterable);
                self.stmts(f.body, false);
            },
            .func_def => |fd| {
                self.params(fd.params);
                if (std.mem.eql(u8, fd.name, self.name)) self.bad = true;
                self.stmts(fd.body, false);
            },
            .class_def => |cd| for (cd.methods) |m| {
                self.params(m.params);
                self.stmts(m.body, false);
            },
            .protocol_def, .extern_def, .pass_stmt, .break_stmt, .continue_stmt, .import_stmt, .from_import_stmt => {},
            .return_stmt => |r| if (r) |e| self.expr(e),
            .raise_stmt => |e| self.expr(e),
            .del_stmt => |e| {
                if (e == .index and self.isG(e.index.obj.*)) {
                    self.bad = true;
                } else self.expr(e);
            },
            .try_stmt => |t| {
                self.stmts(t.try_body, false);
                for (t.except_clauses) |ec| {
                    if (ec.bind_name) |n| if (std.mem.eql(u8, n, self.name)) {
                        self.bad = true;
                    };
                    self.stmts(ec.body, false);
                }
                if (t.finally_body) |fb| self.stmts(fb, false);
            },
            .lowlevel_stmt => |ll| self.stmts(ll.body, false),
            .with_stmt => |w| {
                if (w.binding) |n| if (std.mem.eql(u8, n, self.name)) {
                    self.bad = true;
                };
                self.expr(w.ctx_expr);
                self.stmts(w.body, false);
            },
            .defer_stmt => |d| self.expr(ast.Expr{ .call = d.call }),
        }
    }

    fn comp(self: *Walker, clauses: []const ast.CompClause) void {
        for (clauses) |cl| switch (cl) {
            .for_clause => |fc| {
                if (std.mem.eql(u8, fc.var_name, self.name)) self.bad = true;
                self.expr(fc.iterable);
            },
            .if_clause => |ce| self.expr(ce),
        };
    }

    fn expr(self: *Walker, e: ast.Expr) void {
        if (self.bad) return;
        switch (e) {
            .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit => {},
            .identifier => |n| if (std.mem.eql(u8, n, self.name)) {
                self.bad = true;
            },
            .unary => |u| self.expr(u.operand.*),
            .kwarg => |k| self.expr(k.value.*),
            .ternary => |t| {
                self.expr(t.cond.*);
                self.expr(t.then_expr.*);
                self.expr(t.else_expr.*);
            },
            .binary => |b| {
                if ((b.op == .in_ or b.op == .not_in) and self.isG(b.right.*)) {
                    self.expr(b.left.*);
                } else {
                    self.expr(b.left.*);
                    self.expr(b.right.*);
                }
            },
            .call => |c| {
                switch (c.callee.*) {
                    .attribute => |at| if (self.isG(at.obj.*)) {
                        if (!self.allowedMethod(at.attr, c.args.len)) self.bad = true;
                        for (c.args) |arg| self.expr(arg);
                        return;
                    },
                    .identifier => |fname| {
                        if (self.allowedBuiltin(fname)) {
                            for (c.args) |arg| {
                                if (self.isG(arg)) continue;
                                self.expr(arg);
                            }
                            return;
                        }
                        // Liste global'i bir modül işlevine ARGÜMAN olarak geçirilebilir; işlev o parametreyi yalnız okuyorsa çağrı ANLIK KOPYA alır (kopya üzerinde okumak eşdeğerdir).
                        if ((self.kind == .list or self.kind == .list_ro) and self.ctx.funcs.get(fname) != null) {
                            const fd = self.ctx.funcs.get(fname).?;
                            for (c.args, 0..) |arg, j| {
                                if (self.isG(arg)) {
                                    if (!self.ctx.paramReadOnly(fd, j)) self.bad = true;
                                } else self.expr(arg);
                            }
                            return;
                        }
                    },
                    else => {},
                }
                self.expr(c.callee.*);
                for (c.args) |arg| self.expr(arg);
            },
            .attribute => |at| self.expr(at.obj.*),
            .list_comp => |lc| {
                self.expr(lc.elem.*);
                self.comp(lc.clauses);
            },
            .dict_comp => |dc| {
                self.expr(dc.key.*);
                self.expr(dc.value.*);
                self.comp(dc.clauses);
            },
            .lambda => |lam| {
                for (lam.params) |p| if (std.mem.eql(u8, p, self.name)) {
                    self.bad = true;
                };
                self.expr(lam.body.*);
            },
            .slice => |sl| {
                if (self.isG(sl.obj.*)) {
                    if (self.kind != .list) self.bad = true;
                } else self.expr(sl.obj.*);
                if (sl.lo) |x| self.expr(x.*);
                if (sl.hi) |x| self.expr(x.*);
                if (sl.step) |x| self.expr(x.*);
            },
            .index => |idx| {
                if (!self.isG(idx.obj.*)) self.expr(idx.obj.*);
                self.expr(idx.index.*);
            },
            .list_lit => |elems| for (elems) |el| self.expr(el),
            .tuple_lit => |elems| for (elems) |el| self.expr(el),
            .dict_lit => |pairs| for (pairs) |p| {
                self.expr(p.key);
                self.expr(p.value);
            },
            .await_expr => |operand| self.expr(operand.*),
            .spawn_expr => |operand| self.expr(operand.*),
            .generic_construct => |g| for (g.args) |arg| self.expr(arg),
        }
    }
};

/// `name` global'inin TÜM kullanımları izinli biçimlerdeyse doğru (bkz. modül notu). `body`: modül deyimleri; `extra`: yükseltilmiş lambda/generic örneklemeleri.
pub fn usesAreRouted(a: std.mem.Allocator, body: []const ast.Stmt, extra: []const ast.FuncDef, name: []const u8, kind: Kind) bool {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var ctx: Ctx = .{ .a = arena.allocator() };
    for (body) |*st| {
        if (st.kind == .func_def) ctx.funcs.put(ctx.a, st.kind.func_def.name, &st.kind.func_def) catch return false;
    }
    var w: Walker = .{ .name = name, .kind = kind, .ctx = &ctx };
    w.stmts(body, true);
    for (extra) |fd| {
        w.params(fd.params);
        w.stmts(fd.body, false);
    }
    return !w.bad;
}

// ---- Codegen yönlendirmesi --------------------------------------------------------------------------------------------------------------------------------------

fn lit(self: *Codegen, comptime fmt: []const u8, args: anytype) CodegenError![]const u8 {
    return std.fmt.allocPrint(self.allocator, fmt, args);
}

/// Hücre işaretçisini (globals bloğundaki yuva) yükler.
fn loadCell(self: *Codegen, g: GlobalVar) CodegenError![]const u8 {
    const block = try self.newTemp();
    try self.qbeCall(.{ .name = block, .ty = .l }, "$nox_globals_get", &.{.{ .ty = .l, .text = RT_PARAM }});
    const addr = try self.newTemp();
    try self.qbeOp2Imm(addr, .l, "add", block, @intCast(g.offset));
    const cell = try self.newTemp();
    try self.qbeLoadL(cell, addr);
    return cell;
}

fn shapeOf(g: GlobalVar) ElemShape {
    return listElemShape(g.info).?;
}

/// Global listenin Value betimleyicisi (`text` verilir).
fn listValue(g: GlobalVar, text: []const u8) Value {
    return .{ .text = text, .qtype = .l, .heap = .list, .elem_qtype = g.info.elem_qtype, .class_name = g.info.class_name, .elem_heap_info = g.info.elem_heap_info, .elem_is_str = g.info.elem_is_str, .dict_info = g.info.dict_info, .func_sig = g.info.func_sig, .fixed_int = g.info.fixed_int, .elem_fixed_int = g.info.elem_fixed_int };
}

/// `$nox_init_globals`te: taze liste bloğunu hücreye sarar; yuvaya yazılacak değeri döndürür.
pub fn wrapInitList(self: *Codegen, block_text: []const u8) CodegenError![]const u8 {
    const cell = try self.newTemp();
    try self.qbeCall(.{ .name = cell, .ty = .l }, "$nox_slist_new", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = block_text } });
    return cell;
}

/// Program çıkışında hücreyi serbest bırakır (`$nox_deinit_globals`).
pub fn freeList(self: *Codegen, g: GlobalVar, handle: []const u8) CodegenError!void {
    const sh = shapeOf(g);
    try self.qbeCall(null, "$nox_slist_free", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = handle }, .{ .ty = .w, .text = try lit(self, "{d}", .{sh.kind}) }, .{ .ty = .l, .text = try lit(self, "{d}", .{sh.esz}) } });
}

/// Salt-okunur toplu kullanımlar için listenin anlık kopyası: taze (`always_fresh`) bir liste değeri.
pub fn genListSnapshot(self: *Codegen, g: GlobalVar) CodegenError!Value {
    const sh = shapeOf(g);
    const cell = try loadCell(self, g);
    const snap = try self.newTemp();
    try self.qbeCall(.{ .name = snap, .ty = .l }, "$nox_slist_snapshot", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = cell }, .{ .ty = .l, .text = try lit(self, "{d}", .{sh.esz}) }, .{ .ty = .w, .text = try lit(self, "{d}", .{sh.kind}) } });
    var v = listValue(g, snap);
    v.always_fresh = true;
    return v;
}

/// `len(xs)` — O(1).
pub fn genListLen(self: *Codegen, g: GlobalVar) CodegenError!Value {
    const cell = try loadCell(self, g);
    const r = try self.newTemp();
    try self.qbeCall(.{ .name = r, .ty = .l }, "$nox_slist_len", &.{.{ .ty = .l, .text = cell }});
    return .{ .text = r, .qtype = .l };
}

/// Çıkış bayrağı için 8 baytlık yığın yuvası ayırıp adresini döndürür.
fn okSlot(self: *Codegen) CodegenError![]const u8 {
    const s = try self.newTemp();
    try self.qbeAlloc(s, .eight, 8);
    return s;
}

/// `bad` = (ok == 0) üretir.
fn notOk(self: *Codegen, slot: []const u8) CodegenError![]const u8 {
    const ok = try self.newTemp();
    try self.qbeLoadL(ok, slot);
    const bad = try self.newTemp();
    try self.qbeOp2Imm(bad, .w, "ceql", ok, 0);
    return bad;
}

/// Eleman değerini Value'ya çevirir (`str` ise sahipli/taze).
fn elemValue(self: *Codegen, g: GlobalVar, raw: []const u8, owned_str: bool) CodegenError!Value {
    const sh = shapeOf(g);
    const conv: Value = blk: {
        if (sh.esz == 1) {
            // list[bool]: 1 baytlık depo -> `w` değer
            const w = try self.newTemp();
            try self.qbeOp2Imm(w, .w, "and", raw, 1);
            break :blk .{ .text = w, .qtype = .w };
        }
        break :blk .{ .text = raw, .qtype = .l };
    };
    var v = abi.valueFromElemDescriptor(conv.text, g.info.elem_qtype, g.info.elem_heap_info, g.info.elem_is_str, g.info.elem_fixed_int);
    if (g.info.elem_qtype == .d) {
        // payload i64 bit deseni -> double
        const d = try self.newTemp();
        try self.qbeOp1(d, .d, "cast", raw);
        v.text = d;
    }
    if (owned_str and sh.kind != 0) v.always_fresh = true;
    return v;
}

/// Eleman değerini hücre ABI'sinin 8 baytlık yüküne çevirir.
fn elemPayload(self: *Codegen, g: GlobalVar, v: Value) CodegenError![]const u8 {
    const sh = shapeOf(g);
    if (g.info.elem_qtype == .d) {
        const t = try self.newTemp();
        try self.qbeOp1(t, .l, "cast", v.text);
        return t;
    }
    if (sh.esz == 1) {
        const t = try self.newTemp();
        try self.qbeOp1(t, .l, "extuw", v.text);
        return t;
    }
    return v.text;
}

/// `xs[i]` — O(1), sınır denetimli (`IndexError`); `str` eleman sahipli (taze) döner.
pub fn genListGet(self: *Codegen, g: GlobalVar, index_expr: ast.Expr) CodegenError!Value {
    const sh = shapeOf(g);
    const idx = try self.genExpr(index_expr);
    const idx_l = try self.convert(idx, .l);
    const cell = try loadCell(self, g);
    const slot = try okSlot(self);
    const raw = try self.newTemp();
    try self.qbeCall(.{ .name = raw, .ty = .l }, "$nox_slist_get", &.{ .{ .ty = .l, .text = cell }, .{ .ty = .l, .text = idx_l.text }, .{ .ty = .l, .text = try lit(self, "{d}", .{sh.esz}) }, .{ .ty = .w, .text = try lit(self, "{d}", .{sh.kind}) }, .{ .ty = .l, .text = slot } });
    try calls.emitColdListError(self, try notOk(self, slot), "IndexError", "list index out of range", &.{});
    return elemValue(self, g, raw, true);
}

/// `xs[i] = v`.
pub fn genListSet(self: *Codegen, g: GlobalVar, index_expr: ast.Expr, value_expr: ast.Expr) CodegenError!void {
    const sh = shapeOf(g);
    const idx = try self.genExpr(index_expr);
    const idx_l = try self.convert(idx, .l);
    const target = abi.valueFromElemDescriptor("0", g.info.elem_qtype, g.info.elem_heap_info, g.info.elem_is_str, g.info.elem_fixed_int);
    const v0 = try self.genExprForTarget(value_expr, abi.typeInfoOfValue(target));
    const retained = try self.retainIfAliasing(value_expr, v0);
    const val = try self.convert(retained, g.info.elem_qtype);
    const payload = try elemPayload(self, g, val);
    const cell = try loadCell(self, g);
    const ok = try self.newTemp();
    try self.qbeCall(.{ .name = ok, .ty = .l }, "$nox_slist_set", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = cell }, .{ .ty = .l, .text = idx_l.text }, .{ .ty = .l, .text = try lit(self, "{d}", .{sh.esz}) }, .{ .ty = .w, .text = try lit(self, "{d}", .{sh.kind}) }, .{ .ty = .l, .text = payload } });
    const bad = try self.newTemp();
    try self.qbeOp2Imm(bad, .w, "ceql", ok, 0);
    // Başarısızsa elemanın sahipliği listeye geçmedi: `str` ise bırak (sızıntı olmasın), sonra IndexError.
    if (sh.kind != 0) {
        const rel_label = try self.newLabel("slist_set_rel");
        const cont_label = try self.newLabel("slist_set_cont");
        try self.qbeJnz(bad, rel_label, cont_label);
        try self.qbeLabel(rel_label);
        try self.releaseValueIfSet(val.text, val.heap, val.elem_qtype, val.class_name, val.elem_heap_info, val.dict_info);
        try self.qbeJmp(cont_label);
        try self.qbeLabel(cont_label);
    }
    try calls.emitColdListError(self, bad, "IndexError", "list assignment index out of range", &.{});
}

/// `xs.append(v)` / `xs.pop()` / `xs.clear()`.
pub fn genListMethod(self: *Codegen, g: GlobalVar, a: ast.Attribute, args: []const ast.Expr) CodegenError!Value {
    const sh = shapeOf(g);
    if (std.mem.eql(u8, a.attr, "append")) {
        const target = abi.valueFromElemDescriptor("0", g.info.elem_qtype, g.info.elem_heap_info, g.info.elem_is_str, g.info.elem_fixed_int);
        const v0 = try self.genExprForTarget(args[0], abi.typeInfoOfValue(target));
        const retained = try self.retainIfAliasing(args[0], v0);
        const val = try self.convert(retained, g.info.elem_qtype);
        const payload = try elemPayload(self, g, val);
        const cell = try loadCell(self, g);
        const ok = try self.newTemp();
        try self.qbeCall(.{ .name = ok, .ty = .l }, "$nox_slist_append", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = cell }, .{ .ty = .l, .text = try lit(self, "{d}", .{sh.esz}) }, .{ .ty = .w, .text = try lit(self, "{d}", .{sh.kind}) }, .{ .ty = .l, .text = payload } });
        return .{ .text = "0", .qtype = .none };
    }
    if (std.mem.eql(u8, a.attr, "pop")) {
        const cell = try loadCell(self, g);
        const slot = try okSlot(self);
        const raw = try self.newTemp();
        try self.qbeCall(.{ .name = raw, .ty = .l }, "$nox_slist_pop", &.{ .{ .ty = .l, .text = cell }, .{ .ty = .l, .text = try lit(self, "{d}", .{sh.esz}) }, .{ .ty = .l, .text = slot } });
        try calls.emitColdListError(self, try notOk(self, slot), "IndexError", "cannot pop from an empty list", &.{});
        return elemValue(self, g, raw, false);
    }
    if (std.mem.eql(u8, a.attr, "clear")) {
        const cell = try loadCell(self, g);
        try self.qbeCall(null, "$nox_slist_clear", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = cell }, .{ .ty = .l, .text = try lit(self, "{d}", .{sh.esz}) }, .{ .ty = .w, .text = try lit(self, "{d}", .{sh.kind}) } });
        return .{ .text = "0", .qtype = .none };
    }
    return error.Unsupported;
}

/// `d[k]` (str değerli paylaşılan sözlük): tek çağrıda sahipli okuma; yoksa `KeyError`.
pub fn genDictGetOwned(self: *Codegen, obj_expr: ast.Expr, obj: Value, key_expr: ast.Expr) CodegenError!Value {
    const dinfo = obj.dict_info.?;
    const key_v0 = try self.genExpr(key_expr);
    try self.checkNoLowlevelEscape(key_v0);
    const key_payload = try self.toPayload(key_v0);
    const key_is_str_lit: []const u8 = if (dinfo.key_is_str) "1" else "0";
    const payload_t = try self.newTemp();
    try self.qbeCall(.{ .name = payload_t, .ty = .l }, "$nox_dict_get_owned", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj.text }, .{ .ty = .w, .text = key_is_str_lit }, .{ .ty = .l, .text = key_payload.text }, .{ .ty = .w, .text = if (dinfo.value_is_class) "2" else "1" } });
    const missing = try self.newTemp();
    try self.qbeOp2Imm(missing, .w, "ceql", payload_t, 0);
    const err_label = try self.newLabel("dict_get_err");
    const ok_label = try self.newLabel("dict_get_ok");
    try self.qbeJnz(missing, err_label, ok_label);
    try self.qbeLabel(err_label);
    const msg_value = try self.emitStringLiteral("key not found");
    const ke_cinfo = self.classes.get("KeyError") orelse return error.Unsupported;
    const ke_obj = try self.genConstructFromValues("KeyError", ke_cinfo, &.{msg_value}, null);
    try self.emitExceptionLineStore(ke_obj.text, "KeyError", self.current_raise_line);
    try self.qbeCall(null, "$nox_raise", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ke_obj.text }, .{ .ty = .l, .text = try lit(self, "{d}", .{self.current_raise_line}) } });
    try self.releaseIfTemporary(key_expr, key_v0);
    try self.releaseIfTemporary(obj_expr, obj);
    try self.emitRaisePropagate();
    try self.qbeLabel(ok_label);
    try self.releaseIfTemporary(key_expr, key_v0);
    try self.releaseIfTemporary(obj_expr, obj);
    var v = abi.dictValueValue(dinfo, payload_t, .l);
    v.always_fresh = true;
    return v;
}
