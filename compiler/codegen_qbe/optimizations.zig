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
const LocalDecl = types.LocalDecl;
const CodegenError = abi.CodegenError;

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

/// GG.12 (bkz. nox-teknik-spesifikasyon.md §3.66): `expr` içinde (HERHANGİ
/// bir derinlikte) `name` adlı bir tanımlayıcı GEÇİYOR mu? `nameUsedUnsafely`
/// İçin çekirdek — `ast.Expr`nin TÜM varyantlarını AÇIKÇA ele alır (sessiz
/// `else => false` YOK): eksik bırakılan bir dal burada YANLIŞ bir
/// "kullanılmıyor" sonucuna (ve dolayısıyla GÜVENSİZ bir eleme kararına)
/// yol açardı — `detectWhileBoundsElideCtx`nin AKSİNE (orada eksik kapsam
/// sadece fırsatı KAÇIRIR), bu YÜZDEN burada TAM kapsam ZORUNLUDUR.
fn exprMentionsName(expr: ast.Expr, name: []const u8) bool {
    return switch (expr) {
        .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit => false,
        .identifier => |n| std.mem.eql(u8, n, name),
        .unary => |u| exprMentionsName(u.operand.*, name),
        .binary => |b| exprMentionsName(b.left.*, name) or exprMentionsName(b.right.*, name),
        .call => |c| callMentionsName(c, name),
        .attribute => |a| exprMentionsName(a.obj.*, name),
        .index => |idx| exprMentionsName(idx.obj.*, name) or exprMentionsName(idx.index.*, name),
        .list_lit => |items| blk: {
            for (items) |it| if (exprMentionsName(it, name)) break :blk true;
            break :blk false;
        },
        .dict_lit => |pairs| blk: {
            for (pairs) |p| {
                if (exprMentionsName(p.key, name)) break :blk true;
                if (exprMentionsName(p.value, name)) break :blk true;
            }
            break :blk false;
        },
        .await_expr => |e| exprMentionsName(e.*, name),
        .spawn_expr => |e| exprMentionsName(e.*, name),
        .generic_construct => |gc| blk: {
            for (gc.args) |a| if (exprMentionsName(a, name)) break :blk true;
            break :blk false;
        },
    };
}

fn callMentionsName(c: ast.Call, name: []const u8) bool {
    if (exprMentionsName(c.callee.*, name)) return true;
    for (c.args) |a| if (exprMentionsName(a, name)) return true;
    return false;
}

/// GG.12: `body` içinde `name`in, DOĞRUDAN bir `for_stmt`nin ÜST-DÜZEY
/// iterable'ı (`for x in name:`) OLMAYAN HERHANGİ BİR kullanımı var mı?
/// `selfFieldSnapshotEligible`nin (e) adımı İçin — "TEK kullanım for
/// iterable'ı" garantisi BURADA doğrulanır. `ast.Stmt`nin TÜM varyantları
/// AÇIKÇA ele alınır (`exprMentionsName`İLE AYNI TAM-kapsam gerekçesi).
/// İç içe bir `func_def` (closure `name`i YAKALAYABİLİR — bilinmeyen
/// kapsam) HER ZAMAN "güvensiz" SAYILIR.
fn nameUsedUnsafely(body: []const ast.Stmt, name: []const u8) bool {
    for (body) |stmt| {
        switch (stmt.kind) {
            .var_decl => |v| if (exprMentionsName(v.value, name)) return true,
            .assign => |a| {
                if (exprMentionsName(a.target, name)) return true;
                if (exprMentionsName(a.value, name)) return true;
            },
            .expr_stmt => |e| if (exprMentionsName(e, name)) return true,
            .return_stmt => |maybe_e| {
                if (maybe_e) |e| if (exprMentionsName(e, name)) return true;
            },
            .raise_stmt => |e| if (exprMentionsName(e, name)) return true,
            .if_stmt => |f| {
                if (exprMentionsName(f.cond, name)) return true;
                if (nameUsedUnsafely(f.then_body, name)) return true;
                for (f.elif_clauses) |ec| {
                    if (exprMentionsName(ec.cond, name)) return true;
                    if (nameUsedUnsafely(ec.body, name)) return true;
                }
                if (f.else_body) |eb| if (nameUsedUnsafely(eb, name)) return true;
            },
            .while_stmt => |w| {
                if (exprMentionsName(w.cond, name)) return true;
                if (nameUsedUnsafely(w.body, name)) return true;
            },
            .for_stmt => |f| {
                const iterable_is_direct_match = f.iterable == .identifier and std.mem.eql(u8, f.iterable.identifier, name);
                if (!iterable_is_direct_match and exprMentionsName(f.iterable, name)) return true;
                if (nameUsedUnsafely(f.body, name)) return true;
            },
            .try_stmt => |t| {
                if (nameUsedUnsafely(t.try_body, name)) return true;
                for (t.except_clauses) |ec| if (nameUsedUnsafely(ec.body, name)) return true;
                if (t.finally_body) |fb| if (nameUsedUnsafely(fb, name)) return true;
            },
            .lowlevel_stmt => |ll| if (nameUsedUnsafely(ll.body, name)) return true,
            .with_stmt => |w| {
                if (exprMentionsName(w.ctx_expr, name)) return true;
                if (nameUsedUnsafely(w.body, name)) return true;
            },
            .func_def => return true,
            .defer_stmt => |d| if (callMentionsName(d.call, name)) return true,
            .pass_stmt, .class_def, .protocol_def, .extern_def, .import_stmt, .from_import_stmt => {},
        }
    }
    return false;
}

/// GG.12: `body` içinde `self.<field_name>`e (doğrudan `self.<alan> =
/// ...` biçiminde) bir YENİDEN ATAMA var mı? `selfFieldSnapshotEligible`nin
/// (c) adımı İçin. İç içe bir `func_def` (closure `self`i YAKALAYIP alanı
/// değiştirebilir) HER ZAMAN "yeniden atanmış" SAYILIR (güvenli taraf).
fn fieldReassignedInBody(body: []const ast.Stmt, field_name: []const u8) bool {
    for (body) |stmt| {
        switch (stmt.kind) {
            .assign => |a| {
                if (a.target == .attribute) {
                    const t = a.target.attribute;
                    if (t.obj.* == .identifier and std.mem.eql(u8, t.obj.identifier, "self") and std.mem.eql(u8, t.attr, field_name)) return true;
                }
            },
            .if_stmt => |f| {
                if (fieldReassignedInBody(f.then_body, field_name)) return true;
                for (f.elif_clauses) |ec| if (fieldReassignedInBody(ec.body, field_name)) return true;
                if (f.else_body) |eb| if (fieldReassignedInBody(eb, field_name)) return true;
            },
            .while_stmt => |w| if (fieldReassignedInBody(w.body, field_name)) return true,
            .for_stmt => |f| if (fieldReassignedInBody(f.body, field_name)) return true,
            .try_stmt => |t| {
                if (fieldReassignedInBody(t.try_body, field_name)) return true;
                for (t.except_clauses) |ec| if (fieldReassignedInBody(ec.body, field_name)) return true;
                if (t.finally_body) |fb| if (fieldReassignedInBody(fb, field_name)) return true;
            },
            .lowlevel_stmt => |ll| if (fieldReassignedInBody(ll.body, field_name)) return true,
            .with_stmt => |w| if (fieldReassignedInBody(w.body, field_name)) return true,
            .func_def => return true,
            else => {},
        }
    }
    return false;
}

/// GG.12: `v.name`in KENDİ bildirim satırından SONRA GERÇEKTEN yeniden
/// atanıp/gölgelenmediğini kontrol eder. `collectReassignedNames`in
/// KENDİSİ KULLANILAMAZ — o fonksiyon HER `var_decl`i (BİR ismin İLK/TEK
/// bildirimi DAHİL) "yeniden atama" SAYAR (GG.5'teki KULLANIM deseninde
/// zararsızdır, çünkü ORADA izlenen isim HER ZAMAN bir PARAMETRE, gövde
/// İÇİNDE ASLA bildirilmez) — BURADA İSE `name` TAM OLARAK gövdede
/// bildirilen isim OLDUĞUNDAN `collectReassignedNames` HER ZAMAN `true`
/// dönerdi (yanlış-pozitif, optimizasyonun HİÇ tetiklenmemesine yol açar).
/// Bu YÜZDEN SADECE gerçek bir yeniden-atama/gölgeleme (`.assign`/for
/// döngü değişkeni/`except ... as`/`with ... as`) arar, `var_decl`in
/// KENDİSİNİ SAYMAZ (`varDeclCountForName`in `!= 1` kontrolü ZATEN aynı
/// isimle İKİNCİ bir `var_decl`i ayrıca ELİYOR).
fn nameReassignedAfterDecl(body: []const ast.Stmt, name: []const u8) bool {
    for (body) |stmt| {
        switch (stmt.kind) {
            .assign => |a| if (a.target == .identifier and std.mem.eql(u8, a.target.identifier, name)) return true,
            .for_stmt => |f| {
                if (std.mem.eql(u8, f.var_name, name)) return true;
                if (nameReassignedAfterDecl(f.body, name)) return true;
            },
            .if_stmt => |f| {
                if (nameReassignedAfterDecl(f.then_body, name)) return true;
                for (f.elif_clauses) |ec| if (nameReassignedAfterDecl(ec.body, name)) return true;
                if (f.else_body) |eb| if (nameReassignedAfterDecl(eb, name)) return true;
            },
            .while_stmt => |w| if (nameReassignedAfterDecl(w.body, name)) return true,
            .try_stmt => |t| {
                if (nameReassignedAfterDecl(t.try_body, name)) return true;
                for (t.except_clauses) |ec| {
                    if (ec.bind_name) |bn| if (std.mem.eql(u8, bn, name)) return true;
                    if (nameReassignedAfterDecl(ec.body, name)) return true;
                }
                if (t.finally_body) |fb| if (nameReassignedAfterDecl(fb, name)) return true;
            },
            .lowlevel_stmt => |ll| if (nameReassignedAfterDecl(ll.body, name)) return true,
            .with_stmt => |w| {
                if (w.binding) |b| if (std.mem.eql(u8, b, name)) return true;
                if (nameReassignedAfterDecl(w.body, name)) return true;
            },
            .func_def => return true,
            else => {},
        }
    }
    return false;
}

/// GG.12: `body` (TAM gövde) içinde `name` adlı bir `var_decl`in KAÇ KEZ
/// geçtiğini sayar — `selfFieldSnapshotEligible`nin AYNI adın (ör. iki
/// farklı `if`/`else` dalında) BELİRSİZ/çelişkili biçimde İKİ KEZ
/// bildirilmesi durumunda GÜVENLİ tarafta kalması İçin (tek bir `VarInfo`
/// girdisi HER İKİ bildirime de karşılık geldiğinden — bkz. `self.vars`in
/// "son yazan kazanır" HashMap semantiği).
fn varDeclCountForName(body: []const ast.Stmt, name: []const u8) usize {
    var count: usize = 0;
    for (body) |stmt| {
        switch (stmt.kind) {
            .var_decl => |v| if (std.mem.eql(u8, v.name, name)) {
                count += 1;
            },
            .if_stmt => |f| {
                count += varDeclCountForName(f.then_body, name);
                for (f.elif_clauses) |ec| count += varDeclCountForName(ec.body, name);
                if (f.else_body) |eb| count += varDeclCountForName(eb, name);
            },
            .while_stmt => |w| count += varDeclCountForName(w.body, name),
            .for_stmt => |f| count += varDeclCountForName(f.body, name),
            .try_stmt => |t| {
                count += varDeclCountForName(t.try_body, name);
                for (t.except_clauses) |ec| count += varDeclCountForName(ec.body, name);
                if (t.finally_body) |fb| count += varDeclCountForName(fb, name);
            },
            .lowlevel_stmt => |ll| count += varDeclCountForName(ll.body, name),
            .with_stmt => |w| count += varDeclCountForName(w.body, name),
            else => {},
        }
    }
    return count;
}

/// GG.12 (bkz. nox-teknik-spesifikasyon.md §3.66): `Box.sum()`daki
/// `local_items: list[int] = self.items` gibi bir `var_decl`in — `self`in
/// bir alanının salt-okunur, TEK-kullanım (bir `for` döngüsünün iterable'ı)
/// bir kopyası olduğu, dolayısıyla retain/release'inin TAMAMEN GEREKSİZ
/// olduğu — kanıtlanıp KANITLANAMADIĞINI belirler. TÜM koşullar
/// sağlanmazsa (belirsizlikte) `false` döner (mevcut davranış KORUNUR) —
/// `detectWhileBoundsElideCtx`in "dar, yerel, deyim-başına, belirsizlikte
/// null'a düş" deseniyle AYNI disiplin.
pub fn selfFieldSnapshotEligible(self: *Codegen, v: ast.VarDecl, locals: []const LocalDecl, body: []const ast.Stmt) CodegenError!bool {
    // `self` (Codegen) burada KULLANILMIYOR — diğer `optimizations.zig`
    // yardımcılarıyla (ör. `detectWhileBoundsElideCtx`) AYNI çağrı
    // imzasını KORUMAK İçin bilinçli olarak TUTULDU (`markBorrowedFieldLocals`
    // KENDİSİ bir `Codegen` metodu OLDUĞUNDAN `self.selfFieldSnapshotEligible(...)`
    // ŞEKLİNDE ÇAĞRILIR).
    _ = self;
    // (a) v.value TAM OLARAK `self.<alan>` biçiminde olmalı.
    if (v.value != .attribute) return false;
    const attr = v.value.attribute;
    if (attr.obj.* != .identifier or !std.mem.eql(u8, attr.obj.identifier, "self")) return false;

    // (b) `self` bilinen, parametre-olan bir sınıf örneği olmalı.
    // `Codegen.findLocal`in DÖNDÜRDÜĞÜ `TypeInfo` `is_param`ı taşımaz —
    // burada `LocalDecl`in KENDİSİ gerekir, bu YÜZDEN listenin en SONUNDAN
    // (gölgeleme İçin AYNI "en son eşleşen kazanır" kuralı) elle aranır.
    const self_decl: LocalDecl = blk: {
        var i = locals.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, locals[i].name, "self")) break :blk locals[i];
        }
        return false;
    };
    if (self_decl.info.heap != .class or !self_decl.is_param) return false;

    // `v.name` gövdede BİRDEN FAZLA `var_decl` İLE bildirilmişse (ör. bir
    // `if`/`else`nin İKİ dalında AYRI AYRI), TEK bir `VarInfo` girdisi HER
    // İKİSİNE de karşılık geleceğinden (bkz. `varDeclCountForName`nin
    // belge notu) BELİRSİZLİK var — GÜVENLİ tarafta kal.
    if (varDeclCountForName(body, v.name) != 1) return false;

    // (c) alan BU metodun gövdesinde HİÇ yeniden atanmıyor.
    if (fieldReassignedInBody(body, attr.attr)) return false;

    // (d) `v.name` normal bir yeniden-atamayla GÖLGELENMİYOR/değişmiyor
    // (bkz. `nameReassignedAfterDecl`nin belge notu — `collectReassigned
    // Names` BURADA KULLANILAMAZ, KENDİ `var_decl` bildirimini de "yeniden
    // atama" SAYARDI).
    if (nameReassignedAfterDecl(body, v.name)) return false;

    // (e) `v.name`in TEK kullanımı bir `for` döngüsünün iterable'ı olmalı
    // — başka HERHANGİ bir kullanım (return/çağrı argümanı/bir alana-
    // listeye-dict'e yazma/iç içe `def` tarafından yakalanma) `false`a düşer.
    if (nameUsedUnsafely(body, v.name)) return false;

    return true;
}

/// GG.12: `full_body` (metodun TAM gövdesi, HER derinlikte SABİT — sadece
/// `selfFieldSnapshotEligible`nin (c)/(e) adımları İçin taşınır) İçindeki
/// HERHANGİ bir derinlikteki `var_decl`leri BULUP uygun olanları `locals`
/// İÇİNDEKİ karşılık gelen `LocalDecl.borrowed_field`i İŞARETLER. AYRI,
/// İKİNCİ bir geçiş olarak tasarlandı — `collectLocals`in KENDİ imzasına
/// DOKUNMAZ (patlama yarıçapı SADECE `genMethod`e, `self`i OLAN TEK codegen
/// yoluna, daralır).
pub fn markBorrowedFieldLocals(self: *Codegen, locals: *std.ArrayListUnmanaged(LocalDecl), body: []const ast.Stmt, full_body: []const ast.Stmt) CodegenError!void {
    for (body) |stmt| {
        switch (stmt.kind) {
            .var_decl => |v| {
                if (try selfFieldSnapshotEligible(self, v, locals.items, full_body)) {
                    for (locals.items) |*l| {
                        if (std.mem.eql(u8, l.name, v.name)) {
                            l.borrowed_field = true;
                            break;
                        }
                    }
                }
            },
            .if_stmt => |f| {
                try markBorrowedFieldLocals(self, locals, f.then_body, full_body);
                for (f.elif_clauses) |ec| try markBorrowedFieldLocals(self, locals, ec.body, full_body);
                if (f.else_body) |eb| try markBorrowedFieldLocals(self, locals, eb, full_body);
            },
            .while_stmt => |w| try markBorrowedFieldLocals(self, locals, w.body, full_body),
            .for_stmt => |f| try markBorrowedFieldLocals(self, locals, f.body, full_body),
            .try_stmt => |t| {
                try markBorrowedFieldLocals(self, locals, t.try_body, full_body);
                for (t.except_clauses) |ec| try markBorrowedFieldLocals(self, locals, ec.body, full_body);
                if (t.finally_body) |fb| try markBorrowedFieldLocals(self, locals, fb, full_body);
            },
            .lowlevel_stmt => |ll| try markBorrowedFieldLocals(self, locals, ll.body, full_body),
            .with_stmt => |w| try markBorrowedFieldLocals(self, locals, w.body, full_body),
            else => {},
        }
    }
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
        try self.qbeCall(.{ .name = len_t, .ty = .l }, "$nox_str_char_count", &.{.{ .ty = .l, .text = v.text }});
        try self.str_len_cache.put(self.allocator, name, len_t);
        // Bulundu (bkz. `Codegen.str_ascii_cache`nin belge notu, GERÇEK
        // ölçüm: `str_index_loop_licm.nox` ~30 saniyeye çıktı) — AYNI
        // döngü-değişmez `str` tabanının TAMAMEN ASCII olup OLMADIĞI DA
        // BURADA, BİR KEZ hesaplanır — `genStrIndex` çalışma-zamanında
        // buna göre O(1) HAM erişim İLE O(i) UTF-8 yürüyüşü ARASINDA
        // dallanır.
        const ascii_t = try self.newTemp();
        try self.qbeCall(.{ .name = ascii_t, .ty = .l }, "$nox_str_is_ascii", &.{.{ .ty = .l, .text = v.text }});
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
    const cne_mnemonic = try std.fmt.allocPrint(self.allocator, "cne{s}", .{eq_ne_suffix});
    try self.qbeOp2(rem_nonzero, .w, cne_mnemonic, rem.text, zero_lit);
    const rem_neg = try self.newTemp();
    try self.qbeOp2(rem_neg, .w, lt_op, rem.text, zero_lit);
    const div_neg = try self.newTemp();
    try self.qbeOp2(div_neg, .w, lt_op, divisor.text, zero_lit);
    const sign_diff = try self.newTemp();
    try self.qbeOp2(sign_diff, .w, "xor", rem_neg, div_neg);
    const need_adjust = try self.newTemp();
    try self.qbeOp2(need_adjust, .w, "and", rem_nonzero, sign_diff);

    const mask = try self.newTemp();
    if (common == .d) {
        try self.qbeOp1(mask, .d, "uwtof", need_adjust);
    } else {
        try self.qbeOp1(mask, .l, "extuw", need_adjust);
    }
    const amount = try self.newTemp();
    try self.qbeOp2(amount, common, "mul", mask, divisor.text);
    const result = try self.newTemp();
    try self.qbeOp2(result, common, "add", rem.text, amount);
    return .{ .text = result, .qtype = common };
}
