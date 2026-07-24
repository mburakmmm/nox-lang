//! QBE codegen backend'inin optimizasyon kümesi — bkz. plan dosyası "QBE
//! codegen backend'ini alt modüllere bölme". Burada TOPLANANLAR: mod_cache
//! CSE (`Codegen.mod_cache`nin belge notu), bounds-check elision tespiti
//! (`for`/`while` ikisi İçin) VE `str_len_cache` döngü-değişmezi önbelleği.
//! `genMod`/`adjustModSign` DE burada — CSE'nin KENDİ ait olduğu yer.

const std = @import("std");
const ast = @import("../parser/ast.zig");
const types = @import("types.zig");
const abi = @import("abi.zig");
const codegen = @import("codegen.zig");

const Codegen = codegen.Codegen;
const QbeType = types.QbeType;
const Value = types.Value;
const ModCacheEntry = types.ModCacheEntry;
const CodegenError = abi.CodegenError;
const qbeTypeName = abi.qbeTypeName;

/// Faz GG.5: bir isim BU gövde İÇİNDE YENİDEN atanıyorsa (doğrudan
/// `assign`/`var_decl` gölgelemesi/`for` döngü değişkeni/`except ... as
/// name`/`with ... as name` İLE) `strlen` önbelleğine ADAY OLAMAZ —
/// aksi halde önbelleklenen uzunluk BAYATLAR (`s = s2` SONRASI `s[i]`
/// hâlâ ESKİ `s`nin uzunluğunu kullanırdı). Bilinçli MUHAFAZAKÂR:
/// SADECE BU gövdedeki (iç içe döngüler DAHİL, ama bu gövdenin DIŞINDA
/// DEĞİL) atamalara bakar — `enterStrLenCacheScope`in HER döngü
/// GİRİŞİNDE bu taramayı TAZE çalıştırması, iç içe bir döngünün KENDİ
/// (dıştaki gövdede reddedilen bir ismi, o ad İÇ döngüde YENİDEN
/// atanmıyorsa) BAĞIMSIZ olarak önbelleklemesine olanak tanır.
pub fn collectReassignedNames(body: []const ast.Stmt, reassigned: *std.StringHashMapUnmanaged(void), allocator: std.mem.Allocator) CodegenError!void {
    for (body) |stmt| {
        switch (stmt.kind) {
            .assign => |a| if (a.target == .identifier) try reassigned.put(allocator, a.target.identifier, {}),
            .var_decl => |v| try reassigned.put(allocator, v.name, {}),
            .if_stmt => |s| {
                try collectReassignedNames(s.then_body, reassigned, allocator);
                for (s.elif_clauses) |ec| try collectReassignedNames(ec.body, reassigned, allocator);
                if (s.else_body) |eb| try collectReassignedNames(eb, reassigned, allocator);
            },
            .while_stmt => |s| try collectReassignedNames(s.body, reassigned, allocator),
            .for_stmt => |s| {
                try reassigned.put(allocator, s.var_name, {});
                try collectReassignedNames(s.body, reassigned, allocator);
            },
            .try_stmt => |s| {
                try collectReassignedNames(s.try_body, reassigned, allocator);
                for (s.except_clauses) |ec| {
                    if (ec.bind_name) |bn| try reassigned.put(allocator, bn, {});
                    try collectReassignedNames(ec.body, reassigned, allocator);
                }
                if (s.finally_body) |fb| try collectReassignedNames(fb, reassigned, allocator);
            },
            .lowlevel_stmt => |s| try collectReassignedNames(s.body, reassigned, allocator),
            .with_stmt => |s| {
                if (s.binding) |b| try reassigned.put(allocator, b, {});
                try collectReassignedNames(s.body, reassigned, allocator);
            },
            .expr_stmt, .return_stmt, .raise_stmt, .func_def, .class_def, .protocol_def, .extern_def, .pass_stmt, .import_stmt, .from_import_stmt, .defer_stmt => {},
        }
    }
}

/// Faz GG.5: gövdede (herhangi bir derinlikte) bir `func_def` (iç içe
/// closure) VARSA `true` döner — BU durumda `enterStrLenCacheScope`
/// TÜM önbellekleme fırsatını (closure'ın YAKALANAN bir ismi kapanış
/// SIRASINDA/SONRASINDA nasıl ele aldığı bu turun kapsamı DIŞINDA
/// AYRICA analiz EDİLMEDİĞİNDEN) BİLİNÇLİ VE MUHAFAZAKÂR biçimde
/// TAMAMEN atlar.
pub fn bodyHasNestedFuncDef(body: []const ast.Stmt) bool {
    for (body) |stmt| {
        switch (stmt.kind) {
            .func_def => return true,
            .if_stmt => |s| {
                if (bodyHasNestedFuncDef(s.then_body)) return true;
                for (s.elif_clauses) |ec| if (bodyHasNestedFuncDef(ec.body)) return true;
                if (s.else_body) |eb| if (bodyHasNestedFuncDef(eb)) return true;
            },
            .while_stmt => |s| if (bodyHasNestedFuncDef(s.body)) return true,
            .for_stmt => |s| if (bodyHasNestedFuncDef(s.body)) return true,
            .try_stmt => |s| {
                if (bodyHasNestedFuncDef(s.try_body)) return true;
                for (s.except_clauses) |ec| if (bodyHasNestedFuncDef(ec.body)) return true;
                if (s.finally_body) |fb| if (bodyHasNestedFuncDef(fb)) return true;
            },
            .lowlevel_stmt => |s| if (bodyHasNestedFuncDef(s.body)) return true,
            .with_stmt => |s| if (bodyHasNestedFuncDef(s.body)) return true,
            else => {},
        }
    }
    return false;
}

pub fn collectLoopInvariantStrBases(self: *Codegen, body: []const ast.Stmt) CodegenError!std.StringHashMapUnmanaged(void) {
    var result: std.StringHashMapUnmanaged(void) = .empty;
    if (bodyHasNestedFuncDef(body)) return result;
    var candidates: std.StringHashMapUnmanaged(void) = .empty;
    try self.collectIndexStrBasesStmts(body, &candidates);
    var reassigned: std.StringHashMapUnmanaged(void) = .empty;
    try collectReassignedNames(body, &reassigned, self.allocator);
    var it = candidates.keyIterator();
    while (it.next()) |k| {
        if (!reassigned.contains(k.*)) try result.put(self.allocator, k.*, {});
    }
    return result;
}

pub const StrLenCacheScope = struct {
    added_names: []const []const u8,
};

/// Faz GG.9: bkz. `bounds_elide_ctx`in belge notu.
pub const BoundsElideCtx = struct { list_name: []const u8, idx_var: []const u8 };

/// Bounds-check elemesi (`bounds_elide_ctx`) ÖNCEDEN yalnızca `for i in
/// range(len(xs)): ... xs[i] ...` idiomunu (bkz. `detectBoundsElideCtx`)
/// tanıyordu — elle yazılmış eşdeğer bir `while` deseni (`benchmarks/
/// compare/lowlevel_arena.nox`nin `while j < 8: ... nums[j] ...` gibi)
/// hiç faydalanamıyordu (bkz. `benchmarks/RESULTS.md`nin darboğaz
/// analizi, 2026-07-22). Bu, AYNI güvenlik ÇITASINI (idx HER ZAMAN
/// `[0, üst_sınır)` ARALIĞINDA, KANITLANABİLİR biçimde) `while` için
/// GENELLEŞTİRİR — for-range'in KENDİ yapısal garantilerinin (0'dan
/// başlar, TAM 1 artar, ASLA atlanmaz) YERİNE burada SÖZDİZİMSEL
/// desen eşleştirmeyle DOĞRULANMASI gerekir:
///
/// 1. `w`den HEMEN ÖNCEKİ (AYNI gövde listesinde) deyim TAM OLARAK
///    `IDX: int = 0` (bir `var_decl`, `int_lit(0)` değeriyle) OLMALIDIR.
/// 2. `w.cond` TAM OLARAK `IDX < ÜST_SINIR` biçiminde olmalıdır.
/// 3. `ÜST_SINIR` YA `len(LIST_NAME)` (HER ZAMAN güvenli — çalışma
///    zamanında TAZE okunur) YA DA LIST_NAME'in EN SON (bu deyimden
///    ÖNCE, AYNI gövdede) bir `list_lit` İLE kurulduğu VE o literalin
///    eleman SAYISINA TAM OLARAK eşit bir `int_lit` olmalıdır (bkz.
///    `lastListLiteralLenBefore`) — LIST_NAME, `w.body` İÇİNDE `[IDX]`
///    İLE indekslenen TEK adaydır (bkz. `findListIndexedByVar`).
/// 4. `w.body`nin SON deyimi TAM OLARAK `IDX = IDX + 1` olmalı VE
///    `IDX` bunun DIŞINDA gövde İÇİNDE HİÇ yeniden atanmamalıdır —
///    for-range'in "TAM 1 artar, asla atlanmaz" garantisinin elle
///    yazılmış KARŞILIĞI.
/// 5. `LIST_NAME` `w.body` İÇİNDE yeniden atanmamalı (`collectReassigned
///    Names`, `detectBoundsElideCtx` İLE AYNI disiplin), İÇ İÇE bir
///    `func_def` (closure) OLMAMALIDIR (`bodyHasNestedFuncDef`).
///
/// HERHANGİ bir adım BAŞARISIZ olursa `null` döner (GÜVENLİ, MUHAFAZAKÂR
/// geri düşüş — sınır kontrolü NORMAL şekilde üretilir, bkz. `detectBounds
/// ElideCtx`in AYNI ilkesi). Nox'ta `break`/`continue` OLMADIĞINDAN
/// (gövde HER ZAMAN baştan sona TAM çalışır) bu desen eşleştirme,
/// for-range'in kendi garantileriyle AYNI güvenlik düzeyini sağlar.
pub fn detectWhileBoundsElideCtx(self: *Codegen, stmts: []const ast.Stmt, i: usize, w: ast.WhileStmt) CodegenError!?BoundsElideCtx {
    if (w.cond != .binary) return null;
    const cond_b = w.cond.binary;
    if (cond_b.op != .lt) return null;
    if (cond_b.left.* != .identifier) return null;
    const idx_var = cond_b.left.identifier;

    // `idx_var`in `w`den ÖNCE 0'a eşitlendiğini doğrula — bkz. adım 1.
    // AYRI bir statement (ör. `inner: int = 0`) `idx_var`in kendi
    // bildirimi İLE `while` ARASINA GİREBİLİR (`lowlevel_arena.nox`nin
    // GERÇEK deseni TAM OLARAK budur) — bu yüzden "HEMEN ÖNCEKİ deyim"
    // YERİNE, `idx_var`e DOKUNAN EN SON deyim GERİYE doğru taranır.
    const idx_init = lastAssignedIntLiteral(stmts, i, idx_var) orelse return null;
    if (idx_init != 0) return null;

    const list_name: []const u8 = blk: {
        if (cond_b.right.* == .call) {
            const c = cond_b.right.call;
            if (c.callee.* != .identifier or !std.mem.eql(u8, c.callee.identifier, "len")) return null;
            if (c.args.len != 1 or c.args[0] != .identifier) return null;
            const name = c.args[0].identifier;
            const vi = self.vars.get(name) orelse return null;
            if (vi.heap != .list and vi.heap != .str) return null;
            break :blk name;
        }
        if (cond_b.right.* == .int_lit) {
            const upper = cond_b.right.int_lit;
            const name = findListIndexedByVar(w.body, idx_var) orelse return null;
            const vi = self.vars.get(name) orelse return null;
            if (vi.heap != .list) return null;
            const known_len = lastListLiteralLenBefore(stmts, i, name) orelse return null;
            if (@as(i64, @intCast(known_len)) != upper) return null;
            break :blk name;
        }
        return null;
    };

    if (!whileBodyEndsWithIncrement(w.body, idx_var)) return null;
    if (bodyHasNestedFuncDef(w.body)) return null;
    var reassigned: std.StringHashMapUnmanaged(void) = .empty;
    try collectReassignedNames(w.body, &reassigned, self.allocator);
    if (reassigned.contains(list_name)) return null;
    // `idx_var`in SON deyim (artırma) DIŞINDA yeniden atanmadığını
    // doğrula — `collectReassignedNames`in TÜM gövdeyi (SON deyim
    // DAHİL) taraması normal koşulda `idx_var`ı HER ZAMAN bulur (artırma
    // deyiminin kendisi bir atamadır), bu yüzden gövdenin SON deyimi
    // HARİÇ TUTULARAK ayrıca taranır.
    var reassigned_excl_last: std.StringHashMapUnmanaged(void) = .empty;
    try collectReassignedNames(w.body[0 .. w.body.len - 1], &reassigned_excl_last, self.allocator);
    if (reassigned_excl_last.contains(idx_var)) return null;

    return .{ .list_name = list_name, .idx_var = idx_var };
}

/// `body` İçinde `LIST[idx_var]` biçiminde (LIST bir `list[T]` yereli)
/// indekslenen TEK bir adı arar — bkz. `detectWhileBoundsElideCtx`nin
/// belge notu, adım 3. Yalnızca en yaygın deyim/ifade biçimlerini
/// GEZER (`func_def`/`try`/`with`/`lowlevel` İÇİNE İNMEZ) — eksik
/// kapsam yalnızca eleme fırsatını KAÇIRIR (GÜVENLİ, asla YANLIŞ bir
/// eleme ÜRETMEZ).
fn findListIndexedByVar(body: []const ast.Stmt, idx_var: []const u8) ?[]const u8 {
    for (body) |stmt| {
        const found = switch (stmt.kind) {
            .expr_stmt => |e| findListIndexedByVarExpr(e, idx_var),
            .var_decl => |v| findListIndexedByVarExpr(v.value, idx_var),
            .assign => |a| findListIndexedByVarExpr(a.target, idx_var) orelse findListIndexedByVarExpr(a.value, idx_var),
            .if_stmt => |f| blk: {
                if (findListIndexedByVarExpr(f.cond, idx_var)) |n| break :blk n;
                if (findListIndexedByVar(f.then_body, idx_var)) |n| break :blk n;
                for (f.elif_clauses) |ec| {
                    if (findListIndexedByVarExpr(ec.cond, idx_var)) |n| break :blk n;
                    if (findListIndexedByVar(ec.body, idx_var)) |n| break :blk n;
                }
                break :blk if (f.else_body) |eb| findListIndexedByVar(eb, idx_var) else null;
            },
            .while_stmt => |ws| blk: {
                if (findListIndexedByVarExpr(ws.cond, idx_var)) |n| break :blk n;
                break :blk findListIndexedByVar(ws.body, idx_var);
            },
            .for_stmt => |f| blk: {
                if (findListIndexedByVarExpr(f.iterable, idx_var)) |n| break :blk n;
                break :blk findListIndexedByVar(f.body, idx_var);
            },
            .return_stmt => |r| if (r) |e| findListIndexedByVarExpr(e, idx_var) else null,
            .raise_stmt => |e| findListIndexedByVarExpr(e, idx_var),
            else => null,
        };
        if (found) |n| return n;
    }
    return null;
}

fn findListIndexedByVarExpr(e: ast.Expr, idx_var: []const u8) ?[]const u8 {
    switch (e) {
        .index => |idx| {
            if (idx.obj.* == .identifier and idx.index.* == .identifier and std.mem.eql(u8, idx.index.identifier, idx_var)) {
                return idx.obj.identifier;
            }
            if (findListIndexedByVarExpr(idx.obj.*, idx_var)) |n| return n;
            return findListIndexedByVarExpr(idx.index.*, idx_var);
        },
        .unary => |u| return findListIndexedByVarExpr(u.operand.*, idx_var),
        .binary => |b| {
            if (findListIndexedByVarExpr(b.left.*, idx_var)) |n| return n;
            return findListIndexedByVarExpr(b.right.*, idx_var);
        },
        .call => |c| {
            if (findListIndexedByVarExpr(c.callee.*, idx_var)) |n| return n;
            for (c.args) |a| {
                if (findListIndexedByVarExpr(a, idx_var)) |n| return n;
            }
            return null;
        },
        .attribute => |a| return findListIndexedByVarExpr(a.obj.*, idx_var),
        .list_lit => |items| {
            for (items) |it| {
                if (findListIndexedByVarExpr(it, idx_var)) |n| return n;
            }
            return null;
        },
        .dict_lit => |pairs| {
            for (pairs) |p| {
                if (findListIndexedByVarExpr(p.key, idx_var)) |n| return n;
                if (findListIndexedByVarExpr(p.value, idx_var)) |n| return n;
            }
            return null;
        },
        .await_expr => |inner| return findListIndexedByVarExpr(inner.*, idx_var),
        .spawn_expr => |inner| return findListIndexedByVarExpr(inner.*, idx_var),
        .generic_construct => |g| {
            for (g.args) |a| {
                if (findListIndexedByVarExpr(a, idx_var)) |n| return n;
            }
            return null;
        },
        .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => return null,
    }
}

/// `stmts[0..upto]`i GERİYE doğru tarayıp `list_name`e AİT EN SON
/// `var_decl`/`assign`i bulur; DEĞERİ bir `list_lit` İSE eleman SAYISINI
/// döner, DEĞİLSE (ör. bir fonksiyon çağrısından atanmışsa) `null`
/// (STATİK olarak BİLİNEMEZ — güvenli geri düşüş).
fn lastListLiteralLenBefore(stmts: []const ast.Stmt, upto: usize, list_name: []const u8) ?usize {
    var i = upto;
    while (i > 0) {
        i -= 1;
        switch (stmts[i].kind) {
            .var_decl => |v| if (std.mem.eql(u8, v.name, list_name)) {
                return if (v.value == .list_lit) v.value.list_lit.len else null;
            },
            .assign => |a| if (a.target == .identifier and std.mem.eql(u8, a.target.identifier, list_name)) {
                return if (a.value == .list_lit) a.value.list_lit.len else null;
            },
            else => {},
        }
    }
    return null;
}

/// `lastListLiteralLenBefore` İLE AYNI geriye-tarama deseni, ama `int`
/// bir yerelin EN SON bilinen sabit değerini arar (`detectWhileBounds
/// ElideCtx`nin adım 1'i — `idx_var`in 0'a eşitlendiğini doğrulamak
/// İçin). Değer bir `int_lit` DEĞİLSE (ör. bir ifadeden hesaplanmışsa)
/// `null` (STATİK olarak BİLİNEMEZ).
fn lastAssignedIntLiteral(stmts: []const ast.Stmt, upto: usize, name: []const u8) ?i64 {
    var i = upto;
    while (i > 0) {
        i -= 1;
        switch (stmts[i].kind) {
            .var_decl => |v| if (std.mem.eql(u8, v.name, name)) {
                return if (v.value == .int_lit) v.value.int_lit else null;
            },
            .assign => |a| if (a.target == .identifier and std.mem.eql(u8, a.target.identifier, name)) {
                return if (a.value == .int_lit) a.value.int_lit else null;
            },
            else => {},
        }
    }
    return null;
}

/// `body`nin SON deyiminin TAM OLARAK `idx_var = idx_var + 1` olup
/// OLMADIĞINI doğrular — bkz. `detectWhileBoundsElideCtx`nin belge
/// notu, adım 4.
fn whileBodyEndsWithIncrement(body: []const ast.Stmt, idx_var: []const u8) bool {
    if (body.len == 0) return false;
    const last = body[body.len - 1];
    if (last.kind != .assign) return false;
    const a = last.kind.assign;
    if (a.target != .identifier or !std.mem.eql(u8, a.target.identifier, idx_var)) return false;
    if (a.value != .binary) return false;
    const b = a.value.binary;
    if (b.op != .add) return false;
    if (b.left.* != .identifier or !std.mem.eql(u8, b.left.identifier, idx_var)) return false;
    if (b.right.* != .int_lit or b.right.int_lit != 1) return false;
    return true;
}

/// Faz GG.5: döngüye girmeden HEMEN ÖNCE (döngü gövdesi ÜRETİLMEDEN
/// ÖNCE) çağrılır — `collectLoopInvariantStrBases`in bulduğu HER isim
/// İçin `strlen`i TEK SEFERLİK ÖNCEDEN hesaplayıp `self.str_len_cache`e
/// KAYDEDER. Bir isim ZATEN (dıştaki bir döngüden) önbellekteyse
/// ATLANIR — iç içe döngüler dıştaki döngünün ÖNCEDEN hesapladığı
/// AYNI QBE temp'ini YENİDEN KULLANIR (QBE temp'leri fonksiyon
/// BOYUNCA GEÇERLİDİR — bkz. `emitInlineRetain`in AYNI önculü), İKİNCİ
/// bir `strlen` çağrısı ÜRETİLMEZ; bu YÜZDEN yalnızca BU çağrının
/// GERÇEKTEN eklediği isimler `added_names`e kaydedilir (`exitStrLen
/// CacheScope`in yalnızca KENDİ eklediklerini silmesi İÇİN — dıştaki
/// döngünün girişini YANLIŞLIKLA SİLMEMEK KRİTİKTİR).
pub fn enterStrLenCacheScope(self: *Codegen, body: []const ast.Stmt) CodegenError!StrLenCacheScope {
    var invariants = try self.collectLoopInvariantStrBases(body);
    defer invariants.deinit(self.allocator);
    var added: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = invariants.keyIterator();
    while (it.next()) |k| {
        const name = k.*;
        if (self.str_len_cache.contains(name)) continue;
        const v = try self.genExpr(.{ .identifier = name });
        const len_t = try self.newTemp();
        // Bulundu (bkz. proje belleği "UTF-8 farkındalığı" görevi): ÖNCEDEN
        // `strlen` (bayt sayısı) çağırıyordu — `genStrIndex`in AYNI notuyla
        // TUTARLI OLMASI GEREKİYOR (`nox_str_char_count`, codepoint sayar).
        try self.out.writer.print("    {s} =l call $nox_str_char_count(l {s})\n", .{ len_t, v.text });
        try self.str_len_cache.put(self.allocator, name, len_t);
        // Bulundu (bkz. `Codegen.str_ascii_cache`nin belge notu, GERÇEK
        // ölçüm: `str_index_loop_licm.nox` ~30 saniyeye çıktı) — AYNI
        // döngü-değişmez `str` tabanının TAMAMEN ASCII olup OLMADIĞI DA
        // BURADA, BİR KEZ hesaplanır — `genStrIndex` çalışma-zamanında
        // buna göre O(1) HAM erişim İLE O(i) UTF-8 yürüyüşü ARASINDA
        // dallanır.
        const ascii_t = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_str_is_ascii(l {s})\n", .{ ascii_t, v.text });
        try self.str_ascii_cache.put(self.allocator, name, ascii_t);
        try added.append(self.allocator, name);
    }
    return .{ .added_names = try added.toOwnedSlice(self.allocator) };
}

pub fn exitStrLenCacheScope(self: *Codegen, scope: StrLenCacheScope) void {
    for (scope.added_names) |name| {
        _ = self.str_len_cache.remove(name);
        _ = self.str_ascii_cache.remove(name);
    }
}

/// Bkz. `Codegen.mod_cache`nin belge notu, madde 4 — bir döngü gövdesi
/// İşlenmeden HEMEN ÖNCE çağrılır: ÖNCE gövde İÇİNDE (`collectReassigned
/// Names` İLE tespit edilen) yeniden atanan HER isim İçin önbellek
/// geçersiz KILINIR, SONRA (KRİTİK sıra — bkz. `genIf`nin AYNI
/// düzeltmesi) anlık GÖRÜNTÜ ANCAK BUNDAN SONRA alınır: döngü SONRASI
/// geri yüklenecek durum, yeniden ATANABİLECEK hiçbir isim İÇERMEMELİDİR
/// (döngü SIFIR KEZ çalışsa BİLE — geri yükleme HÂLÂ bu isimleri
/// geçersiz TUTMALIDIR, aksi halde döngü SONRASI kod bir yeniden-atamayı
/// KAÇIRMIŞ gibi bayat bir değeri YANLIŞLIKLA yeniden kullanırdı — TAM
/// OLARAK `genIf`nin düzeltmesiyle AYNI hata sınıfı). Bu AYRICA gövdenin
/// KENDİ İÇİNDEKİ, yeniden-atamadan ÖNCEKİ İLK kullanımın bayat bir ÖN-
/// döngü değerini YANLIŞLIKLA yeniden kullanmasını da ÖNLER (VE bu
/// YÜZDEN AYNI talimatın TEKRAR çalıştığı SONRAKİ yinelemelerde de bayat
/// KALMASINI). Döner: gövde BİTTİĞİNDE `restoreModCache`e geçirilecek
/// anlık görüntü.
pub fn enterModCacheLoopScope(self: *Codegen, body: []const ast.Stmt) CodegenError!std.StringHashMapUnmanaged(ModCacheEntry) {
    var reassigned: std.StringHashMapUnmanaged(void) = .empty;
    defer reassigned.deinit(self.allocator);
    try collectReassignedNames(body, &reassigned, self.allocator);
    var it = reassigned.keyIterator();
    while (it.next()) |k| try self.modCacheInvalidateName(k.*);
    return self.snapshotModCache();
}

/// Faz GG.9: `f`nin `for i in range(len(xs)): ...` TAM OLARAK bu desene
/// UYUYORSA (`xs` BASİT bir kimlik, `list`/`str`-tipli, VE `xs`/`i`
/// gövde İÇİNDE HİÇ yeniden atanmıyor, hiçbir iç içe closure YOK —
/// `str_len_cache`in AYNI `collectReassignedNames`/`bodyHasNestedFuncDef`
/// güvenlik disiplini) `(xs, i)` çiftini döner — AKSİ TAKDİRDE `null`
/// (GÜVENLİ, MUHAFAZAKÂR geri düşüş: sınır kontrolü NORMAL şekilde
/// üretilir).
pub fn detectBoundsElideCtx(self: *Codegen, f: ast.ForStmt) CodegenError!?BoundsElideCtx {
    if (!Codegen.isRangeCall(f.iterable)) return null;
    const limit_expr = f.iterable.call.args[0];
    if (limit_expr != .call) return null;
    if (limit_expr.call.callee.* != .identifier) return null;
    if (!std.mem.eql(u8, limit_expr.call.callee.identifier, "len")) return null;
    if (limit_expr.call.args.len != 1) return null;
    const list_arg = limit_expr.call.args[0];
    if (list_arg != .identifier) return null;
    const list_name = list_arg.identifier;
    const vi = self.vars.get(list_name) orelse return null;
    if (vi.heap != .list and vi.heap != .str) return null;
    if (bodyHasNestedFuncDef(f.body)) return null;
    var reassigned: std.StringHashMapUnmanaged(void) = .empty;
    try collectReassignedNames(f.body, &reassigned, self.allocator);
    if (reassigned.contains(list_name)) return null;
    if (reassigned.contains(f.var_name)) return null;
    return .{ .list_name = list_name, .idx_var = f.var_name };
}

/// Bkz. `Codegen.mod_cache`nin belge notu — `slot#bölen` anahtarını
/// üretir (İSİM DEĞİL, slot: gölgeleme sırasında çakışmayı ÖNLEMEK
/// için).
pub fn modCacheKey(allocator: std.mem.Allocator, slot: []const u8, divisor: i64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}#{d}", .{ slot, divisor });
}

/// `slot` İçin önbelleklenmiş HERHANGİ bir böleni (divisor) geçersiz
/// kılar (o slotun DEĞERİ değişti/değişebilir — ör. yeniden atama,
/// bir inline çağrı sitesinin parametre yazması, ya da bir gölgeleme
/// sınırı).
pub fn modCacheInvalidateSlot(self: *Codegen, slot: []const u8) CodegenError!void {
    var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
    defer to_remove.deinit(self.allocator);
    var it = self.mod_cache.keyIterator();
    while (it.next()) |k| {
        if (std.mem.startsWith(u8, k.*, slot) and k.*.len > slot.len and k.*[slot.len] == '#') {
            try to_remove.append(self.allocator, k.*);
        }
    }
    for (to_remove.items) |k| _ = self.mod_cache.remove(k);
}

/// `name`nin BU ANDAKİ (`self.vars` üzerinden çözülen) slotu İçin
/// `modCacheInvalidateSlot`i çağırır. `name` şu an bilinmiyorsa
/// (`self.vars`ta YOKSA) sessizce hiçbir şey yapmaz — savunmacı.
pub fn modCacheInvalidateName(self: *Codegen, name: []const u8) CodegenError!void {
    const vi = self.vars.get(name) orelse return;
    try self.modCacheInvalidateSlot(vi.slot);
}

/// `genIf`/`genWhile`/`genForRange`/`genForList`nin dal/gövde İşlemeden
/// ÖNCE aldığı, İşlem BİTTİĞİNDE `restoreModCache` İLE geri yüklenen
/// anlık görüntü (bkz. `Codegen.mod_cache`nin belge notu, madde 3-4).
pub fn snapshotModCache(self: *Codegen) CodegenError!std.StringHashMapUnmanaged(ModCacheEntry) {
    return self.mod_cache.clone(self.allocator);
}

pub fn restoreModCache(self: *Codegen, snap: std.StringHashMapUnmanaged(ModCacheEntry)) void {
    self.mod_cache.deinit(self.allocator);
    self.mod_cache = snap;
}

/// Bkz. `genInlinedCall`in 4.5 adımı — `from_slot` İçin önbelleklenmiş
/// HER böleni, `to_slot` ALTINDA da (AYNI değerle) KOPYALAR. `from_slot`
/// İçin HİÇBİR girdi YOKSA (callee o parametreyi hiç `% <sabit>` İLE
/// kullanmadıysa) hiçbir şey EKLENMEZ.
pub fn copyModCacheAlias(self: *Codegen, from_slot: []const u8, to_slot: []const u8) CodegenError!void {
    const ToAdd = struct { key: []const u8, entry: ModCacheEntry };
    var to_add: std.ArrayListUnmanaged(ToAdd) = .empty;
    defer to_add.deinit(self.allocator);
    var it = self.mod_cache.iterator();
    while (it.next()) |kv| {
        const k = kv.key_ptr.*;
        if (std.mem.startsWith(u8, k, from_slot) and k.len > from_slot.len and k[from_slot.len] == '#') {
            const suffix = k[from_slot.len..];
            const new_key = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ to_slot, suffix });
            try to_add.append(self.allocator, .{ .key = new_key, .entry = kv.value_ptr.* });
        }
    }
    for (to_add.items) |item| try self.mod_cache.put(self.allocator, item.key, item.entry);
}

pub fn genMod(self: *Codegen, l: Value, r: Value, common: QbeType) CodegenError!Value {
    const rem = if (common == .d) try self.callLibm2("fmod", l, r) else try self.emitBin("rem", l, r, .l);
    return self.adjustModSign(rem, r, common);
}

/// Not (kritik): bu fonksiyon eskiden bir `alloc8` yığın yuvası + dallanma
/// (jnz/label) kullanıyordu. Bir `%`/`//` ifadesi bir DÖNGÜ gövdesi
/// içinde tekrar tekrar değerlendirildiğinde (ör. `while i < n: x = i % 3`),
/// QBE'nin `alloc8`'i FONKSİYON GİRİŞİNDE bir kez yapılacak bir tahsis
/// olarak varsayması nedeniyle, döngü içine gömülü her `alloc8` her
/// yinelemede yığın işaretçisini (`sub sp, sp, 16`) küçültüyor ve ASLA
/// geri almıyordu — bu da (deneyerek doğrulandı, bkz. benchmark suite
/// kalibrasyonu) yüz binlerce yinelemeden sonra sessiz bir yığın
/// taşmasına (stack overflow → segfault) yol açıyordu. Çözüm: dallanma/
/// bellek KULLANMADAN, `need_adjust`i (0 ya da 1) ortak tipe genişletip
/// bölene çarpıp kalana eklemek — SAF aritmetik, hiçbir döngü derinliğinde
/// yığın büyümesi olmaz (ayrıca dallanmasız olduğu için daha hızlıdır).
pub fn adjustModSign(self: *Codegen, rem: Value, divisor: Value, common: QbeType) CodegenError!Value {
    const zero_lit: []const u8 = if (common == .d) "d_0" else "0";
    const eq_ne_suffix: []const u8 = if (common == .d) "d" else "l";
    const lt_op: []const u8 = if (common == .d) "cltd" else "csltl";

    const rem_nonzero = try self.newTemp();
    try self.out.writer.print("    {s} =w cne{s} {s}, {s}\n", .{ rem_nonzero, eq_ne_suffix, rem.text, zero_lit });
    const rem_neg = try self.newTemp();
    try self.out.writer.print("    {s} =w {s} {s}, {s}\n", .{ rem_neg, lt_op, rem.text, zero_lit });
    const div_neg = try self.newTemp();
    try self.out.writer.print("    {s} =w {s} {s}, {s}\n", .{ div_neg, lt_op, divisor.text, zero_lit });
    const sign_diff = try self.newTemp();
    try self.out.writer.print("    {s} =w xor {s}, {s}\n", .{ sign_diff, rem_neg, div_neg });
    const need_adjust = try self.newTemp();
    try self.out.writer.print("    {s} =w and {s}, {s}\n", .{ need_adjust, rem_nonzero, sign_diff });

    const mask = try self.newTemp();
    if (common == .d) {
        try self.out.writer.print("    {s} =d uwtof {s}\n", .{ mask, need_adjust });
    } else {
        try self.out.writer.print("    {s} =l extuw {s}\n", .{ mask, need_adjust });
    }
    const amount = try self.newTemp();
    try self.out.writer.print("    {s} ={s} mul {s}, {s}\n", .{ amount, qbeTypeName(common), mask, divisor.text });
    const result = try self.newTemp();
    try self.out.writer.print("    {s} ={s} add {s}, {s}\n", .{ result, qbeTypeName(common), rem.text, amount });
    return .{ .text = result, .qtype = common };
}
