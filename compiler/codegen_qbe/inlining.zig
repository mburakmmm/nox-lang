//! Faz GG.2 fonksiyon-içi splice (inlining) mekanizması — bkz. plan dosyası
//! "QBE codegen backend'ini alt modüllere bölme". Uygunluk analizi
//! (`isFuncInlineEligible`/`computeInlinableFunctions`), çağrı-sitesi keşfi
//! (`collectInlineSites*`) VE fiili splice üretimi (`genInlinedCall`) burada
//! toplanır.

const std = @import("std");
const ast = @import("../parser/ast.zig");
const types = @import("types.zig");
const abi = @import("abi.zig");
const codegen = @import("codegen.zig");
const optimizations = @import("optimizations.zig");
const local_escape = @import("local_escape.zig");
const effect_graph = @import("../effect_graph.zig");

const Codegen = codegen.Codegen;
const Value = types.Value;
const TypeInfo = types.TypeInfo;
const VarInfo = types.VarInfo;
const QbeType = types.QbeType;
const LIST_HEADER_SIZE = types.LIST_HEADER_SIZE;
const CodegenError = abi.CodegenError;
const qbeSizeOf = abi.qbeSizeOf;
const collectReassignedNames = optimizations.collectReassignedNames;

/// Faz GG.2 (bkz. nox-teknik-spesifikasyon.md §3.67): inline edilen bir
/// callee'nin TEK bir parametresi/yerel değişkeni İçİN, caller'ın giriş
/// bloğunda ÖNCEDEN tahsis edilmiş (bkz. `registerInlineSite`) slot —
/// `orig_name` callee'nin KAYNAK isim, `slot` VE `info` `allocSlot`in
/// ÜRETTİĞİ AYNI temsil (bkz. `VarInfo`).
pub const NamedSlot = struct {
    orig_name: []const u8,
    slot: []const u8,
    info: TypeInfo,
};

/// Faz GG.2: TEK bir inline-splice sitesi İçin ÖN-TAHSİS EDİLMİŞ TÜM
/// slotlar — `prepareInlineSites` TARAFINDAN doldurulur, `genInlinedCall`
/// TARAFINDAN tüketilir.
pub const InlineSiteInfo = struct {
    callee: ast.FuncDef,
    params: []const NamedSlot,
    locals: []const NamedSlot,
    /// `null` İSE callee'nin dönüş tipi `None` (sonuç YOK).
    result: ?NamedSlot,
    /// GG.19 (bkz. plan dosyası "ASAP güçlendirmesi — Tur 3"): callee'nin
    /// gövdesindeki GG.17/18-kalifiye üst-düzey `var_decl`ler İçİn, BU
    /// SPESİFİK splice sitesine ÖZGÜ, TAZE (`registerInlineSite`de
    /// caller'ın KENDİ giriş bloğunda tahsis edilmiş) tutamaklar — bkz.
    /// `InlineConstructSite`nin belge notu.
    construct_sites: []const InlineConstructSite = &.{},
};

/// GG.19: `registerInlineSite`in callee gövdesinde bulduğu HER GG.17/18
/// adayı İçİn TAZE bir tutamak (stack slotu YA DA arena tutamağı) —
/// `genInlinedCall` bunu `genStmts(site.callee.body, ...)`DAN HEMEN ÖNCE
/// `self.stack_construct_sites`/`self.arena_local_construct_sites`e
/// GEÇİCİ olarak YÜKLER (AYNI AST düğümünün standalone-derlenmiş `callee`
/// İçİNDEKİ ESKİ kaydını GEÇİCİ olarak GÖLGELEYEREK) VE splice
/// BİTTİĞİNDE SİLER — `helper()` AYNI caller İçİnde BİRDEN FAZLA
/// çağrılırsa HER splice KENDİ TAZE tutamağını alır (bu YÜZDEN "eski
/// değeri geri yükle" DEĞİL "bu splice'a ÖZGÜ girdiyi SİL" — AYNI düğüm
/// İçİn kalıcı bir "önceki" değer YOKTUR, sadece standalone `callee`
/// derlemesinin KENDİ, İLGİSİZ kaydı VARDIR ki O da bu splice'tan
/// TAMAMEN BAĞIMSIZDIR).
pub const InlineConstructSite = struct {
    node_key: usize,
    /// `false`: boş `[]` literali (Tur 2'nin GERÇEK, break→red→fix İLE
    /// bulunan tuzağı — Zig'in TÜM sıfır-boyutlu tahsislere AYNI kanonik
    /// işaretçiyi vermesi YÜZÜNDEN `node_key` GÜVENİLMEZ) — `node_key`
    /// KULLANILMAZ/tabloya HİÇ YAZILMAZ, `genEmptyListLit` `target.
    /// growable_arena`yı (`genInlinedCall`nin shadowed `VarInfo`ye
    /// YAZDIĞI) DOĞRUDAN okur.
    needs_node_registration: bool,
    var_name: []const u8,
    candidate: local_escape.Candidate,
    handle: []const u8,
};

/// GG.15 (bkz. nox-teknik-spesifikasyon.md §3.66): bkz. `Codegen.
/// stack_construct_sites`in belge notu.
pub const StackConstructSite = struct {
    slot: []const u8,
};

/// Faz GG.2: `genStmts`in `.return_stmt` dalının, İÇİNDE bulunulan
/// splice'ın "gerçek bir fonksiyon çıkışı DEĞİL, bir `jmp`e dönüşmesi
/// gerektiğini" bilmesini sağlayan GEÇİCİ bağlam — `genInlinedCall`
/// TARAFINDAN AYARLANIR/GERİ YÜKLENİR (iç içe inline YOK olduğundan
/// ASLA yığınlanmaz, TEK bir aktif hedef yeterlidir).
pub const InlineReturnTarget = struct {
    result_slot: ?[]const u8,
    done_label: []const u8,
    /// Yalnızca BU isimler (callee'nin KENDİ parametre+yerelleri)
    /// `return_stmt`in İÇİNDE serbest bırakılır — caller'ın DİĞER
    /// yerellerine ASLA dokunulmaz.
    owned_names: []const []const u8,
};

const MAX_INLINE_TOP_STMTS: usize = 8;
const MAX_INLINE_TOTAL_STMTS: usize = 20;

/// GG.17 (bkz. nox-teknik-spesifikasyon.md §3.10X): bir fiber'ın SABİT
/// 128 KiB stack'i (`runtime/async_rt/fiber.zig`'in `STACK_SIZE`i, guard-
/// page İLE korunan — GG.25'te 256 KiB'DEN küçültüldü, bkz. plan dosyası
/// "STACK_SIZE küçültmesi") İçİn GÜVENLİ bir üst sınır — İÇ İÇE çağrı
/// çerçeveleri/BİRDEN FAZLA eşzamanlı stack-yerelin PAYINI da bırakacak
/// ŞEKİLDE MUHAFAZAKÂR seçildi (128 KiB'nin ~%1.5'i, ESKİ 256 KiB'İN AYNI
/// ORANI — GG.25 STACK_SIZE'ı YARIYA indirirken BU sabiti de AYNI oranda
/// küçülttü). GG.15/GG.16'nın (bu sabitten ÖNCE SINIRSIZ olan) İKİ
/// üreticisine VE GG.17'nin YENİ `local_escape.zig`sine ORTAK uygulanır —
/// hiçbiri BUNU AŞAN bir `alloc8` üretmez, aşan durumlar SESSİZCE normal
/// ARC/arena yoluna DÜŞER (davranış DEĞİŞMEZ, sadece optimizasyon
/// uygulanmaz).
pub const MAX_STACK_ALLOC_SIZE: usize = 2048;

/// GG.19 (bkz. plan dosyası "ASAP güçlendirmesi — Tur 3"): `MAX_STACK_
/// ALLOC_SIZE` SADECE nesne-BAŞINA — bir fonksiyonun (VE İçİNE splice
/// edilen HER GG.2-inline callee'nin, AYNI fiziksel çerçeveyi PAYLAŞAN)
/// TÜM stack-promotable yerellerinin TOPLAMI da BU tavanı AŞAMAZ (16
/// KiB — fiber'ın 128 KiB stack'inin ~%12.5'i, ESKİ 256 KiB'İN AYNI oranı
/// — GG.25'te YARIYA küçültüldü, bkz. `MAX_STACK_ALLOC_SIZE`nin AYNI
/// güncelleme notu). `classifyVarDecl`nin (`local_escape.zig`) `running_
/// total` parametresi BUNU uygular — aşan bir aday (boyut/escape ŞARTLARI
/// HÂLÂ geçse BİLE) `nox_rc_alloc`a DEĞİL, arena yoluna DÜŞER (davranış
/// DEĞİŞMEZ — SADECE stack yerine arena — sızıntı/çökme RİSKİ YOK).
pub const MAX_PROMOTED_FRAME_SIZE: usize = 16384;

/// Bir inline-adayı gövdenin (özyinelemeli, `if`/`elif`/`else` İÇİNE de
/// uygulanır) YALNIZCA `var_decl`/`assign`/`expr_stmt`/`if_stmt`/
/// `return_stmt`/`pass_stmt` İÇERDİĞİNİ doğrular VE TOPLAM deyim sayısını
/// döner — `while`/`for`/`try`/`with`/`raise`/`lowlevel`/iç içe `func_def`/
/// `class_def` VARSA `null` (diskalifiye) döner. `while`/`for`in DIŞLANMASI
/// İKİ ayrı riski BAŞTAN eler: QBE'nin döngü-İÇİ `alloc4`/`alloc8`
/// tehlikesi (bkz. `adjustModSign`in belge notu) VE `return`i "değeri
/// slota yaz + `jmp`" biçimine çevirmenin KARMAŞIKLAŞMASI (TEK bir
/// doğrusal/dallı gövdede HER `return` ZATEN AYNI `done_label`e gider).
fn inlineBodyStmtCount(stmts: []const ast.Stmt) ?usize {
    var total: usize = 0;
    for (stmts) |stmt| {
        switch (stmt.kind) {
            .var_decl, .assign, .expr_stmt, .return_stmt, .pass_stmt => total += 1,
            .if_stmt => |f| {
                total += 1;
                total += inlineBodyStmtCount(f.then_body) orelse return null;
                for (f.elif_clauses) |ec| total += inlineBodyStmtCount(ec.body) orelse return null;
                if (f.else_body) |eb| total += inlineBodyStmtCount(eb) orelse return null;
            },
            else => return null,
        }
    }
    return total;
}

/// Bir serbest fonksiyonun (`fd`) Faz GG.2 KAPSAMINDA "inline edilebilir"
/// SAYILIP SAYILMADIĞINI belirler — bkz. nox-teknik-spesifikasyon.md
/// §3.67'nin TAM uygunluk listesi. `self.must_not_raise`in ZATEN
/// dolu OLMASI GEREKİR (bkz. `computeInlinableFunctions`in çağrı SIRASI
/// notu) — bu şart, splice SIRASINDA bir istisna kontrolünün caller'ın
/// ERKEN-çıkış yoluna girip GÖLGELENMİŞ bir yerelin GÖRÜNMEZ kalarak
/// SIZMASINI YAPISAL olarak İMKANSIZ kılar (bkz. `genInlinedCall`in
/// belge notu).
pub fn isFuncInlineEligible(self: *Codegen, fd: ast.FuncDef, generic_template_names: []const []const u8) bool {
    if (fd.is_async) return false;
    if (fd.type_params.len != 0) return false;
    for (generic_template_names) |n| {
        if (std.mem.eql(u8, n, fd.name)) return false;
    }
    if (self.recursive_funcs.contains(fd.name)) return false;
    if (!self.must_not_raise.contains(fd.name)) return false;
    // GG.19 (bkz. plan dosyası "ASAP güçlendirmesi — Tur 3"): v1.42.0'ın
    // KABA "GG.17/18 adayı İçEREN HER fonksiyonu TAMAMEN dışla" hotfix'i
    // BURADAN KALDIRILDI — `registerInlineSite` ARTIK callee gövdesindeki
    // HER adayı, BU SPESİFİK splice sitesine ÖZGÜ TAZE bir tutamakla
    // (bkz. `InlineConstructSite`) YENİDEN kaydediyor, bu YÜZDEN inline+
    // ASAP ARTIK GÜVENLE BİRLİKTE çalışabiliyor.
    if (fd.body.len > MAX_INLINE_TOP_STMTS) return false;
    const total = inlineBodyStmtCount(fd.body) orelse return false;
    if (total > MAX_INLINE_TOTAL_STMTS) return false;
    return true;
}

/// GG.20 (bkz. plan dosyası "ASAP güçlendirmesi — Tur 4"): whole-program
/// pre-pass — `self.func_defs`teki (SADECE SERBEST fonksiyonlar, metodlar
/// HARİÇ — `registerFunc` ZATEN metodları BURAYA KAYDETMEZ) HER fonksiyonun
/// HER parametresi İçİn `paramNeverEscapes`in TANIDIĞI 3 güvenli şekil
/// (for-iterable/index-tabanı/len() argümanı) + salt-okunur `.attribute`
/// carve-out'u DIŞINDAKİ HER kullanımı (`return`, başka bir isme atama/
/// alias, başka bir container'a yazma, `spawn` yakalaması, `try`/`with`/
/// `lowlevel`/nested-`def` İçİnde kullanım) TOHUM sayar; parametre BAŞKA
/// bir ÇÖZÜLEBİLİR SERBEST fonksiyona argüman olarak geçerse (metod
/// çağrıları KAPSAM DIŞI) bir KENAR ekler. `effect_graph.propagateBad`
/// İLE `self.escaping_params`i doldurur — `exprHasUnsafeParamUse`/
/// `local_escape.zig`nin escape-kontrol fonksiyonları BUNU KULLANIR.
pub fn computeParamEscapes(self: *Codegen, module: ast.Module, extra_functions: []const ast.FuncDef, extra_classes: []const ast.ClassDef) CodegenError!void {
    var seeds: std.ArrayListUnmanaged(effect_graph.NodeKey) = .empty;
    defer seeds.deinit(self.allocator);
    var reverse_edges: effect_graph.ReverseEdges = .empty;
    for (module.body) |stmt| {
        if (stmt.kind == .func_def) try scanParamEscapesFunc(self, stmt.kind.func_def, &seeds, &reverse_edges);
        // GG.21 (bkz. plan dosyası "ASAP güçlendirmesi — Tur 5"): sınıf
        // metodları da (`ClassMethodInfo.owner`nin AYNI "{sınıf}_{metod}"
        // sembol şemasıyla) taranır — bunlar OLMADAN `escaping_params`
        // HİÇBİR metod-anahtarlı tohum İÇERMEZ, bu da `methodIsFinal`nin
        // KENDİSİ DOĞRU çalışsa BİLE HER final-metod çağrısını YANLIŞLIKLA
        // "güvenli" (kontrol edilecek HİÇBİR şey bulunamadığından) sayardı.
        if (stmt.kind == .class_def) {
            const cd = stmt.kind.class_def;
            for (cd.methods) |m| {
                const sym = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ cd.name, m.name });
                try scanParamEscapesFunc(self, ast.FuncDef{
                    .name = sym,
                    .params = m.params,
                    .return_type = m.return_type,
                    .body = m.body,
                    .type_params = m.type_params,
                    .is_async = false,
                    .decorators = &.{},
                }, &seeds, &reverse_edges);
            }
        }
    }
    for (extra_functions) |fd| try scanParamEscapesFunc(self, fd, &seeds, &reverse_edges);
    for (extra_classes) |cd| {
        for (cd.methods) |m| {
            const sym = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ cd.name, m.name });
            try scanParamEscapesFunc(self, ast.FuncDef{
                .name = sym,
                .params = m.params,
                .return_type = m.return_type,
                .body = m.body,
                .type_params = m.type_params,
                .is_async = false,
                .decorators = &.{},
            }, &seeds, &reverse_edges);
        }
    }
    self.escaping_params = try effect_graph.propagateBad(self.allocator, &reverse_edges, seeds.items);
}

fn scanParamEscapesFunc(self: *Codegen, fd: ast.FuncDef, seeds: *std.ArrayListUnmanaged(effect_graph.NodeKey), reverse_edges: *effect_graph.ReverseEdges) CodegenError!void {
    const class_params = try collectClassParams(self, self.allocator, fd.params);
    for (fd.params, 0..) |p, idx| {
        try scanParamEscapesStmts(self, fd.name, @intCast(idx), p.name, fd.body, class_params, seeds, reverse_edges);
    }
}

fn addEscapeSeed(self: *Codegen, fname: []const u8, param_idx: u32, seeds: *std.ArrayListUnmanaged(effect_graph.NodeKey)) CodegenError!void {
    try seeds.append(self.allocator, .{ .func = fname, .index = param_idx });
}

fn addEscapeEdge(self: *Codegen, target_func: []const u8, target_index: u32, fname: []const u8, param_idx: u32, reverse_edges: *effect_graph.ReverseEdges) CodegenError!void {
    const key: effect_graph.NodeKey = .{ .func = target_func, .index = target_index };
    const gop = try reverse_edges.getOrPut(self.allocator, key);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(self.allocator, .{ .func = fname, .index = param_idx });
}

/// GG.21 (bkz. plan dosyası "ASAP güçlendirmesi — Tur 5"): bir fonksiyonun
/// `class`-tipli parametrelerinin (isim, sınıf-adı) çiftleri — receiver'ı
/// BU fonksiyonun KENDİ (sibling) bir parametresi OLAN metod çağrılarını
/// (`obj.method(...)`) ÇÖZEBİLMEK İçİn. **v1 BİLİNÇLİ sınırı**: SADECE
/// DOĞRUDAN parametreler kapsanır — bir YEREL değişken YA DA bir alan-
/// zinciri (`self.other.method()`) receiver İSE ÇÖZÜLMEZ (checker'ın
/// `resolveExprSharedType`si bunu ÜCRETSİZ kapsar, codegen'in BU saf-
/// sözdizimsel taraması KAPSAMAZ — bkz. plan dosyasının "Kapsam DIŞI").
pub const ClassParam = struct { name: []const u8, class_name: []const u8 };

pub fn collectClassParams(self: *Codegen, allocator: std.mem.Allocator, params: []const ast.Param) CodegenError![]const ClassParam {
    var out: std.ArrayListUnmanaged(ClassParam) = .empty;
    for (params) |p| {
        // GENERİC şablon parametreleri (`T` GİBİ, HENÜZ somut bir tipe
        // ÇÖZÜLEMEYEN) İçİn `resolveType` `error.Unsupported` döner —
        // bu PARAM sadece "class değil" SAYILIR (GÜVENLİ/muhafazakâr:
        // KAÇIŞ carve-out'u BASİTÇE uygulanmaz), HATA PROPAGATE EDİLMEZ.
        const info = self.resolveType(p.type_expr) catch continue;
        if (info.heap == .class and info.class_name != null) {
            try out.append(allocator, .{ .name = p.name, .class_name = info.class_name.? });
        }
    }
    return out.toOwnedSlice(allocator);
}

/// GG.21: checker'ın AYNI-isimli `methodIsFinal`inin codegen-tarafı
/// eşdeğeri — `ClassInfo.descendant_class_ids`/`ClassMethodInfo.owner`
/// (ZATEN VAR OLAN, `computeMustNotRaise`/exception-hiyerarşisi İçİn
/// hesaplanmış bilgi) KULLANILIR, YENİ bir alan GEREKMEZ. `false` dönmesi
/// (polimorfik OLABİLİR/bilinmiyor) HER ZAMAN GÜVENLİ/muhafazakâr taraftır.
pub fn methodIsFinal(self: *const Codegen, class_name: []const u8, method_name: []const u8) bool {
    const cinfo = self.classes.get(class_name) orelse return false;
    const owner_msig = cinfo.methods.get(method_name) orelse return false;
    var it = self.classes.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.class_id == cinfo.class_id) continue;
        var is_descendant = false;
        for (cinfo.descendant_class_ids) |did| {
            if (did == entry.value_ptr.class_id) {
                is_descendant = true;
                break;
            }
        }
        if (!is_descendant) continue;
        if (entry.value_ptr.methods.get(method_name)) |m| {
            if (!std.mem.eql(u8, m.owner, owner_msig.owner)) return false;
        }
    }
    return true;
}

fn scanParamEscapesStmts(self: *Codegen, fname: []const u8, param_idx: u32, name: []const u8, stmts: []const ast.Stmt, class_params: []const ClassParam, seeds: *std.ArrayListUnmanaged(effect_graph.NodeKey), reverse_edges: *effect_graph.ReverseEdges) CodegenError!void {
    for (stmts) |stmt| {
        switch (stmt.kind) {
            .var_decl => |v| {
                if (std.mem.eql(u8, v.name, name)) {
                    try addEscapeSeed(self, fname, param_idx, seeds);
                    return;
                }
                try scanParamEscapesExpr(self, fname, param_idx, name, v.value, class_params, seeds, reverse_edges);
            },
            .assign => |a| {
                if (a.target == .identifier and std.mem.eql(u8, a.target.identifier, name)) {
                    try addEscapeSeed(self, fname, param_idx, seeds);
                    return;
                }
                try scanParamEscapesExpr(self, fname, param_idx, name, a.target, class_params, seeds, reverse_edges);
                try scanParamEscapesExpr(self, fname, param_idx, name, a.value, class_params, seeds, reverse_edges);
            },
            .expr_stmt => |e| try scanParamEscapesExpr(self, fname, param_idx, name, e, class_params, seeds, reverse_edges),
            .if_stmt => |f| {
                try scanParamEscapesExpr(self, fname, param_idx, name, f.cond, class_params, seeds, reverse_edges);
                try scanParamEscapesStmts(self, fname, param_idx, name, f.then_body, class_params, seeds, reverse_edges);
                for (f.elif_clauses) |ec| {
                    try scanParamEscapesExpr(self, fname, param_idx, name, ec.cond, class_params, seeds, reverse_edges);
                    try scanParamEscapesStmts(self, fname, param_idx, name, ec.body, class_params, seeds, reverse_edges);
                }
                if (f.else_body) |eb| try scanParamEscapesStmts(self, fname, param_idx, name, eb, class_params, seeds, reverse_edges);
            },
            .while_stmt => |w| {
                try scanParamEscapesExpr(self, fname, param_idx, name, w.cond, class_params, seeds, reverse_edges);
                try scanParamEscapesStmts(self, fname, param_idx, name, w.body, class_params, seeds, reverse_edges);
            },
            .for_stmt => |f| {
                if (std.mem.eql(u8, f.var_name, name)) {
                    try addEscapeSeed(self, fname, param_idx, seeds);
                    return;
                }
                const iterable_is_direct = f.iterable == .identifier and std.mem.eql(u8, f.iterable.identifier, name);
                if (!iterable_is_direct) try scanParamEscapesExpr(self, fname, param_idx, name, f.iterable, class_params, seeds, reverse_edges);
                try scanParamEscapesStmts(self, fname, param_idx, name, f.body, class_params, seeds, reverse_edges);
            },
            .return_stmt => |r| if (r) |e| try scanParamEscapesExpr(self, fname, param_idx, name, e, class_params, seeds, reverse_edges),
            .raise_stmt => |e| try scanParamEscapesExpr(self, fname, param_idx, name, e, class_params, seeds, reverse_edges),
            // `try`/İç İçe `lowlevel`/`with`/`func_def`/`defer` — BİLİNMEYEN/
            // riskli bölge, `exprHasUnsafeParamUse`in AYNI muhafazakârlığı.
            .try_stmt, .lowlevel_stmt, .with_stmt, .func_def, .defer_stmt => try addEscapeSeed(self, fname, param_idx, seeds),
            .pass_stmt, .class_def, .protocol_def, .extern_def, .import_stmt, .from_import_stmt => {},
        }
    }
}

/// GG.21'in receiver-çözümleme yardımcısı: `expr`in `class_params`de
/// bilinen bir sibling-parametreye DOĞRUDAN eşleşip eşleşmediğini kontrol
/// eder (alan-zincirleri/yerel değişkenler KAPSAM DIŞI — bkz. `ClassParam`nin
/// belge notu).
pub fn resolveClassParamReceiver(expr: ast.Expr, class_params: []const ClassParam) ?[]const u8 {
    if (expr != .identifier) return null;
    for (class_params) |cp| {
        if (std.mem.eql(u8, cp.name, expr.identifier)) return cp.class_name;
    }
    return null;
}

/// GG.20: `exprHasUnsafeParamUse`nin (YUKARIDA) AYNI 3-güvenli-şekil +
/// salt-okunur `.attribute` carve-out'u disiplini — AMA bool DÖNMEK
/// YERİNE tohum/kenar TOPLAR. `spawn`ın SARDIĞI çağrı YİNE ÖZEL/HER ZAMAN
/// tohum olarak ele alınır (bkz. `exprHasUnsafeParamUse`nin AYNI kritik
/// güvenlik notu — spawn'ın ASENKRON/çapraz-fiber doğası, "callee kendi
/// gövdesinde kaçırmıyor" kanıtını GEÇERSİZ kılar). GG.21: `.call` dalı
/// ARTIK receiver `class_params`de bilinen bir sibling-parametreyse VE
/// metod PROVABLY final İSE (`methodIsFinal`) bunu da bir KENAR olarak
/// ele alır (`self` metodun KENDİ NodeKey indekslemesinde HER ZAMAN 0'DA
/// olduğundan çağrı-sitesi `arg_idx`i +1 KAYDIRILIR — checker'ın AYNI
/// düzeltmesiyle TUTARLI).
fn scanParamEscapesExpr(self: *Codegen, fname: []const u8, param_idx: u32, name: []const u8, expr: ast.Expr, class_params: []const ClassParam, seeds: *std.ArrayListUnmanaged(effect_graph.NodeKey), reverse_edges: *effect_graph.ReverseEdges) CodegenError!void {
    switch (expr) {
        .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit => {},
        .identifier => |n| if (std.mem.eql(u8, n, name)) try addEscapeSeed(self, fname, param_idx, seeds),
        .unary => |u| try scanParamEscapesExpr(self, fname, param_idx, name, u.operand.*, class_params, seeds, reverse_edges),
        .binary => |b| {
            try scanParamEscapesExpr(self, fname, param_idx, name, b.left.*, class_params, seeds, reverse_edges);
            try scanParamEscapesExpr(self, fname, param_idx, name, b.right.*, class_params, seeds, reverse_edges);
        },
        .call => |c| {
            if (c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, "len") and
                c.args.len == 1 and c.args[0] == .identifier and std.mem.eql(u8, c.args[0].identifier, name))
            {
                return; // `len(name)` TEK BAŞINA GÜVENLİDİR.
            }
            var method_owner_symbol: ?[]const u8 = null;
            if (c.callee.* == .attribute) {
                const at = c.callee.attribute;
                if (recv: {
                    if (at.obj.* == .identifier and std.mem.eql(u8, at.obj.identifier, name)) {
                        try addEscapeSeed(self, fname, param_idx, seeds);
                    }
                    break :recv resolveClassParamReceiver(at.obj.*, class_params);
                }) |recv_class| {
                    if (self.classes.get(recv_class)) |cinfo| {
                        if (cinfo.methods.get(at.attr)) |msig| {
                            if (methodIsFinal(self, recv_class, at.attr)) {
                                method_owner_symbol = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ msig.owner, at.attr });
                            }
                        }
                    }
                }
            }
            try scanParamEscapesExpr(self, fname, param_idx, name, c.callee.*, class_params, seeds, reverse_edges);
            const callee_is_resolvable_free_fn = c.callee.* == .identifier and self.func_defs.contains(c.callee.identifier);
            for (c.args, 0..) |a, arg_idx| {
                if (a == .identifier and std.mem.eql(u8, a.identifier, name) and callee_is_resolvable_free_fn) {
                    try addEscapeEdge(self, c.callee.identifier, @intCast(arg_idx), fname, param_idx, reverse_edges);
                    continue;
                }
                if (a == .identifier and std.mem.eql(u8, a.identifier, name) and method_owner_symbol != null) {
                    try addEscapeEdge(self, method_owner_symbol.?, @intCast(arg_idx + 1), fname, param_idx, reverse_edges);
                    continue;
                }
                try scanParamEscapesExpr(self, fname, param_idx, name, a, class_params, seeds, reverse_edges);
            }
        },
        .attribute => |a| {
            if (a.obj.* == .identifier and std.mem.eql(u8, a.obj.identifier, name)) return;
            try scanParamEscapesExpr(self, fname, param_idx, name, a.obj.*, class_params, seeds, reverse_edges);
        },
        .index => |idx| {
            const obj_is_direct = idx.obj.* == .identifier and std.mem.eql(u8, idx.obj.identifier, name);
            if (!obj_is_direct) try scanParamEscapesExpr(self, fname, param_idx, name, idx.obj.*, class_params, seeds, reverse_edges);
            try scanParamEscapesExpr(self, fname, param_idx, name, idx.index.*, class_params, seeds, reverse_edges);
        },
        .list_lit => |elems| for (elems) |el| try scanParamEscapesExpr(self, fname, param_idx, name, el, class_params, seeds, reverse_edges),
        .dict_lit => |pairs| for (pairs) |p| {
            try scanParamEscapesExpr(self, fname, param_idx, name, p.key, class_params, seeds, reverse_edges);
            try scanParamEscapesExpr(self, fname, param_idx, name, p.value, class_params, seeds, reverse_edges);
        },
        .await_expr => |op| try scanParamEscapesExpr(self, fname, param_idx, name, op.*, class_params, seeds, reverse_edges),
        .spawn_expr => |op| {
            if (op.* == .call) {
                const c = op.*.call;
                try scanParamEscapesExpr(self, fname, param_idx, name, c.callee.*, class_params, seeds, reverse_edges);
                for (c.args) |a| {
                    if (a == .identifier and std.mem.eql(u8, a.identifier, name)) {
                        try addEscapeSeed(self, fname, param_idx, seeds);
                        continue;
                    }
                    try scanParamEscapesExpr(self, fname, param_idx, name, a, class_params, seeds, reverse_edges);
                }
            } else {
                try scanParamEscapesExpr(self, fname, param_idx, name, op.*, class_params, seeds, reverse_edges);
            }
        },
        .generic_construct => |g| for (g.args) |a| try scanParamEscapesExpr(self, fname, param_idx, name, a, class_params, seeds, reverse_edges),
    }
}

/// Faz GG.2'nin whole-program ÖN-geçişi — `computeMustNotRaise`DEN SONRA
/// (bağımlılık, bkz. `isFuncInlineEligible`) VE herhangi bir gövde
/// codegen'İNDEN ÖNCE (`prepareInlineSites`in `self.inlinable_funcs`e
/// İHTİYACI VAR) çağrılmalıdır — `generateModule`de TEK bir çağrı sitesi.
pub fn computeInlinableFunctions(self: *Codegen, module: ast.Module, extra_functions: []const ast.FuncDef, generic_template_names: []const []const u8, extra_classes: []const ast.ClassDef) CodegenError!void {
    var info_map = try self.buildFuncSafetyInfoMap(module, extra_functions, extra_classes);
    try self.markRecursiveFuncs(&info_map);

    for (module.body) |stmt| {
        switch (stmt.kind) {
            .func_def => |fd| {
                if (self.isFuncInlineEligible(fd, generic_template_names)) {
                    try self.inlinable_funcs.put(self.allocator, fd.name, fd);
                }
            },
            else => {},
        }
    }
    for (extra_functions) |fd| {
        if (self.isFuncInlineEligible(fd, generic_template_names)) {
            try self.inlinable_funcs.put(self.allocator, fd.name, fd);
        }
    }
}

/// Faz GG.2: TEK bir keşfedilen inline-splice sitesi İçin caller'ın
/// GİRİŞ BLOĞUNDA (QBE'nin "alloc yalnızca fonksiyon girişinde" kısıtına
/// UYGUN — bkz. `collectLocals`in belge notu) callee'nin parametre+yerel+
/// sonuç slotlarını `allocInlineSlot` İLE ÖN-TAHSİS eder VE `self.
/// inline_sites`e (çağrı sitesi POINTER kimliğiyle) KAYDEDER. İÇ İÇE
/// inlining YOK — `callee.body`, YENİDEN `collectInlineSitesStmts`DEN
/// DEĞİL, DÜZ `collectLocals`DAN geçirilir (bu, işi SINIRLI/sonlu tutar).
pub fn registerInlineSite(self: *Codegen, call_ptr: usize, callee: ast.FuncDef) CodegenError!void {
    if (self.inline_sites.contains(call_ptr)) return;

    var params: std.ArrayListUnmanaged(NamedSlot) = .empty;
    for (callee.params) |p| {
        const info = try self.resolveType(p.type_expr);
        try params.append(self.allocator, try self.allocInlineSlot(p.name, info, true));
    }

    var callee_locals: std.ArrayListUnmanaged(types.LocalDecl) = .empty;
    try self.collectLocals(&callee_locals, callee.body, false);
    var locals: std.ArrayListUnmanaged(NamedSlot) = .empty;
    for (callee_locals.items) |l| {
        try locals.append(self.allocator, try self.allocInlineSlot(l.name, l.info, l.is_param));
    }

    const ret_info = try self.resolveType(callee.return_type);
    const result: ?NamedSlot = if (ret_info.qtype == .none) null else try self.allocInlineSlot("__inline_result", ret_info, false);

    // GG.19: callee gövdesinin ÜST-DÜZEYİNDEKİ GG.17/18 adaylarını,
    // caller'ın KENDİ (`registerLocalStackSlots`in ÇOKTAN doldurduğu)
    // `self.promoted_stack_total` sayacını PAYLAŞARAK tara — caller'ın
    // KENDİ yerelleri VE BURADAN splice edilecek callee'nin yerelleri
    // SONUÇTA AYNI fiziksel QBE çerçevesine `alloc8` ekliyor, bu YÜZDEN
    // AYNI aggregate bütçeyi PAYLAŞMALILAR.
    var construct_sites: std.ArrayListUnmanaged(InlineConstructSite) = .empty;
    const callee_class_params = try collectClassParams(self, self.allocator, callee.params);
    for (callee.body, 0..) |stmt, i| {
        if (stmt.kind != .var_decl) continue;
        const v = stmt.kind.var_decl;
        const candidate = try local_escape.classifyVarDecl(self, callee.body, i, v, &self.promoted_stack_total, callee_class_params) orelse continue;
        const handle = try local_escape.materializeConstructSite(self, candidate);
        const is_empty_list = v.value == .list_lit and v.value.list_lit.len == 0;
        try construct_sites.append(self.allocator, .{
            .node_key = if (is_empty_list) undefined else local_escape.constructNodeKey(v),
            .needs_node_registration = !is_empty_list,
            .var_name = v.name,
            .candidate = candidate,
            .handle = handle,
        });
    }

    try self.inline_sites.put(self.allocator, call_ptr, .{
        .callee = callee,
        .params = try params.toOwnedSlice(self.allocator),
        .locals = try locals.toOwnedSlice(self.allocator),
        .result = result,
        .construct_sites = try construct_sites.toOwnedSlice(self.allocator),
    });
}

/// Faz GG.2: caller gövdesini (KISITSIZ — `while`/`for`/`try`/vb.
/// İÇEREBİLİR, YALNIZCA CALLEE kısıtlıdır) TARAYIP `.call` bulan
/// özyinelemeli gezinti — `collectRaiseInfoStmt`in AYNI ağaç-gezinme
/// deseni (bkz. onun belge notu), ama raise-izleme YERİNE inline-site
/// KEŞFİ İçin. `.func_def` (iç içe closure) KASITLI olarak
/// ATLANIR/özyinelenmez — o gövde KENDİ `genClosureFunc`i TARAFINDAN
/// AYRICA taranır (bkz. `prepareInlineSites`in 5 çağrı sitesi).
pub fn collectInlineSitesStmts(self: *Codegen, stmts: []const ast.Stmt) CodegenError!void {
    for (stmts) |stmt| try self.collectInlineSitesStmt(stmt);
}

pub fn collectInlineSitesStmt(self: *Codegen, stmt: ast.Stmt) CodegenError!void {
    switch (stmt.kind) {
        .expr_stmt => |e| try self.collectInlineSitesExpr(e),
        .var_decl => |v| try self.collectInlineSitesExpr(v.value),
        .assign => |a| {
            try self.collectInlineSitesExpr(a.target);
            try self.collectInlineSitesExpr(a.value);
        },
        .if_stmt => |f| {
            try self.collectInlineSitesExpr(f.cond);
            try self.collectInlineSitesStmts(f.then_body);
            for (f.elif_clauses) |ec| {
                try self.collectInlineSitesExpr(ec.cond);
                try self.collectInlineSitesStmts(ec.body);
            }
            if (f.else_body) |eb| try self.collectInlineSitesStmts(eb);
        },
        .while_stmt => |w| {
            try self.collectInlineSitesExpr(w.cond);
            try self.collectInlineSitesStmts(w.body);
        },
        .for_stmt => |f| {
            try self.collectInlineSitesExpr(f.iterable);
            try self.collectInlineSitesStmts(f.body);
        },
        .return_stmt => |r| if (r) |e| try self.collectInlineSitesExpr(e),
        .raise_stmt => |e| try self.collectInlineSitesExpr(e),
        .try_stmt => |t| {
            try self.collectInlineSitesStmts(t.try_body);
            for (t.except_clauses) |ec| try self.collectInlineSitesStmts(ec.body);
            if (t.finally_body) |fb| try self.collectInlineSitesStmts(fb);
        },
        .lowlevel_stmt => |ll| {
            try self.collectInlineSitesStmts(ll.body);
            // GG.15 (bkz. nox-teknik-spesifikasyon.md §3.66): AYNI
            // zamanlamada (writer HÂLÂ fonksiyon GİRİŞİNDE), sabit-boyutlu
            // inşalar İçin yığın slotlarını AYRICA tara/ayır.
            try self.scanStackConstructSites(ll.body);
        },
        .with_stmt => |w| {
            try self.collectInlineSitesExpr(w.ctx_expr);
            try self.collectInlineSitesStmts(w.body);
        },
        // `defer` codegen'i HENÜZ YOK (görev #62) — İÇİNDEKİ çağrı
        // inline-site TARAMASINA KASITLI olarak DAHİL EDİLMEZ.
        .defer_stmt, .func_def, .class_def, .protocol_def, .extern_def, .pass_stmt, .import_stmt, .from_import_stmt => {},
    }
}

pub fn collectInlineSitesExpr(self: *Codegen, expr: ast.Expr) CodegenError!void {
    switch (expr) {
        .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => {},
        .unary => |u| try self.collectInlineSitesExpr(u.operand.*),
        .binary => |b| {
            try self.collectInlineSitesExpr(b.left.*);
            try self.collectInlineSitesExpr(b.right.*);
        },
        .call => |c| {
            for (c.args) |a| try self.collectInlineSitesExpr(a);
            switch (c.callee.*) {
                // Faz GG.2: `name` `self.vars`da (herhangi bir yerel/
                // parametre/closure) VARSA bu çağrı ASLA inline
                // edilemez — bu, `genCall`in KENDİ, DEĞİŞMEMİŞ closure-
                // ÖNCELİK sırasıyla (bkz. onun `.identifier` dalı)
                // ÇELİŞMEMEYİ garanti eden TEK, yeterli kontroldür.
                .identifier => |name| {
                    if (!self.vars.contains(name)) {
                        if (self.inlinable_funcs.get(name)) |callee_fd| {
                            try self.registerInlineSite(@intFromPtr(c.callee), callee_fd);
                        }
                        // GG.16 (bkz. nox-teknik-spesifikasyon.md §3.66):
                        // BU çağrının KENDİSİ inline-edilebilir OLMASA da
                        // (ör. `sum_list` bir `for` İÇERİYOR) — argümanlarından
                        // BİRİ sabit-boyutlu bir liste ÜRETEN, GG.2-inline-
                        // edilebilir bir çağrıysa VE karşılık gelen parametre
                        // KAÇMIYORSA, o listeyi bir yığın slotuna dönüştürür.
                        if (self.func_defs.get(name)) |outer_fd| {
                            try self.tryRegisterCrossCallStackSlots(outer_fd, c.args);
                        }
                    }
                },
                .attribute => |att| try self.collectInlineSitesExpr(att.obj.*),
                else => {},
            }
        },
        .attribute => |a| try self.collectInlineSitesExpr(a.obj.*),
        .index => |idx| {
            try self.collectInlineSitesExpr(idx.obj.*);
            try self.collectInlineSitesExpr(idx.index.*);
        },
        .list_lit => |elems| for (elems) |el| try self.collectInlineSitesExpr(el),
        .dict_lit => |pairs| for (pairs) |p| {
            try self.collectInlineSitesExpr(p.key);
            try self.collectInlineSitesExpr(p.value);
        },
        .await_expr => |op| try self.collectInlineSitesExpr(op.*),
        .spawn_expr => |op| try self.collectInlineSitesExpr(op.*),
        .generic_construct => |g| for (g.args) |a| try self.collectInlineSitesExpr(a),
    }
}

/// GG.15 (bkz. nox-teknik-spesifikasyon.md §3.66): `ll_body`i (bir
/// `lowlevel:` bloğunun gövdesi) tarayıp İÇİNDEKİ HER sabit-boyutlu
/// inşa (sınıf kurucusu/basit-literal `list_lit`) İçin fonksiyon
/// GİRİŞİNDE (writer HÂLÂ ORADA — bkz. `collectInlineSitesStmt`nin
/// `.lowlevel_stmt` dalındaki AYNI zamanlama garantisi) bir yığın slotu
/// ayırıp `self.stack_construct_sites`e KAYDEDER. `ll_body`deki TÜM
/// inşalar (en az BİR tane VARSA) dönüştürülebildiyse `self.
/// lowlevel_arena_elidable`e `true` yazar — `genLowLevel` BUNU `nox_
/// arena_create`/`destroy` çiftini TAMAMEN ATLAMAK İçin kullanır.
pub fn scanStackConstructSites(self: *Codegen, ll_body: []const ast.Stmt) CodegenError!void {
    var all_ok = true;
    var any = false;
    try scanStackConstructsStmts(self, ll_body, &all_ok, &any);
    try self.lowlevel_arena_elidable.put(self.allocator, @intFromPtr(ll_body.ptr), any and all_ok);
}

fn scanStackConstructsStmts(self: *Codegen, stmts: []const ast.Stmt, all_ok: *bool, any: *bool) CodegenError!void {
    for (stmts) |stmt| {
        switch (stmt.kind) {
            .var_decl => |v| try scanStackConstructsExpr(self, v.value, all_ok, any),
            .assign => |a| {
                try scanStackConstructsExpr(self, a.target, all_ok, any);
                try scanStackConstructsExpr(self, a.value, all_ok, any);
            },
            .expr_stmt => |e| try scanStackConstructsExpr(self, e, all_ok, any),
            .if_stmt => |f| {
                try scanStackConstructsExpr(self, f.cond, all_ok, any);
                try scanStackConstructsStmts(self, f.then_body, all_ok, any);
                for (f.elif_clauses) |ec| {
                    try scanStackConstructsExpr(self, ec.cond, all_ok, any);
                    try scanStackConstructsStmts(self, ec.body, all_ok, any);
                }
                if (f.else_body) |eb| try scanStackConstructsStmts(self, eb, all_ok, any);
            },
            .while_stmt => |w| {
                try scanStackConstructsExpr(self, w.cond, all_ok, any);
                try scanStackConstructsStmts(self, w.body, all_ok, any);
            },
            .for_stmt => |f| {
                try scanStackConstructsExpr(self, f.iterable, all_ok, any);
                try scanStackConstructsStmts(self, f.body, all_ok, any);
            },
            .return_stmt => |r| if (r) |e| try scanStackConstructsExpr(self, e, all_ok, any),
            .raise_stmt => |e| try scanStackConstructsExpr(self, e, all_ok, any),
            // `try`/İç İçe `lowlevel`/`func_def`/`with` — GG.15'in
            // KAPSAMI DIŞINDA (bilinçli, MUHAFAZAKÂR): BULUNURSA BU
            // `lowlevel:` örneğinin arena elenmesi İPTAL edilir (`all_ok
            // = false`), ama fonksiyonun GERİ KALANI/DİĞER `lowlevel`
            // örnekleri ETKİLENMEZ.
            .try_stmt, .lowlevel_stmt, .func_def, .with_stmt, .defer_stmt => all_ok.* = false,
            .pass_stmt, .class_def, .protocol_def, .extern_def, .import_stmt, .from_import_stmt => {},
        }
    }
}

/// GG.15/GG.16 (bkz. nox-teknik-spesifikasyon.md §3.66): `elems`in TÜMÜ
/// AYNI türden BASİT bir literal (`int_lit`/`float_lit`/`bool_lit`) İSE
/// (boyutun ÇALIŞMA ZAMANI DEĞERLENDİRMESİ OLMADAN, SADECE AST'den
/// bilindiği TEK durum) o türün QBE karşılığını döner; AKSİ HALDE `null`
/// (identifier/çağrı İÇEREN HERHANGİ bir eleman, KARIŞIK türler, boş liste).
pub fn simpleLiteralListQtype(elems: []const ast.Expr) ?QbeType {
    if (elems.len == 0) return null;
    const elem_qtype: QbeType = switch (elems[0]) {
        .int_lit => .l,
        .float_lit => .d,
        .bool_lit => .w,
        else => return null,
    };
    for (elems) |el| {
        const ok = switch (el) {
            .int_lit => elem_qtype == .l,
            .float_lit => elem_qtype == .d,
            .bool_lit => elem_qtype == .w,
            else => false,
        };
        if (!ok) return null;
    }
    return elem_qtype;
}

/// GG.15: bir sınıf kurucusu çağrısı (`ClassName(...)`) YA DA basit-
/// literal (`int_lit`/`float_lit`/`bool_lit`, TÜMÜ AYNI türden) bir
/// `list_lit` BULURSA, HEMEN (writer'ın O ANKİ, GİRİŞ-bloğu konumunda)
/// bir `alloc8` yığın slotu üretir. BAŞKA HERHANGİ bir inşa şekli
/// (identifier/çağrı İÇEREN eleman, `dict_lit`, `generic_construct`)
/// `all_ok`i `false` yapar — GG.13/14 İLE AYNI "belirsizlikte GÜVENLİ
/// tarafta kal" disiplini.
fn scanStackConstructsExpr(self: *Codegen, expr: ast.Expr, all_ok: *bool, any: *bool) CodegenError!void {
    switch (expr) {
        .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => {},
        .unary => |u| try scanStackConstructsExpr(self, u.operand.*, all_ok, any),
        .binary => |b| {
            try scanStackConstructsExpr(self, b.left.*, all_ok, any);
            try scanStackConstructsExpr(self, b.right.*, all_ok, any);
        },
        .call => |c| {
            for (c.args) |a| try scanStackConstructsExpr(self, a, all_ok, any);
            if (c.callee.* == .identifier) {
                if (self.classes.get(c.callee.identifier)) |cinfo| {
                    any.* = true;
                    if (cinfo.total_size <= MAX_STACK_ALLOC_SIZE) {
                        const slot = try self.newTemp();
                        try self.qbeAlloc(slot, .eight, cinfo.total_size);
                        try self.stack_construct_sites.put(self.allocator, @intFromPtr(c.callee), .{ .slot = slot });
                    } else {
                        all_ok.* = false;
                    }
                }
            }
        },
        .attribute => |a| try scanStackConstructsExpr(self, a.obj.*, all_ok, any),
        .index => |idx| {
            try scanStackConstructsExpr(self, idx.obj.*, all_ok, any);
            try scanStackConstructsExpr(self, idx.index.*, all_ok, any);
        },
        .list_lit => |elems| {
            any.* = true;
            if (simpleLiteralListQtype(elems)) |elem_qtype| {
                const elem_size = qbeSizeOf(elem_qtype);
                const payload_size = LIST_HEADER_SIZE + elem_size * elems.len;
                if (payload_size <= MAX_STACK_ALLOC_SIZE) {
                    const slot = try self.newTemp();
                    try self.qbeAlloc(slot, .eight, payload_size);
                    try self.stack_construct_sites.put(self.allocator, @intFromPtr(elems.ptr), .{ .slot = slot });
                } else {
                    all_ok.* = false;
                }
            } else {
                all_ok.* = false;
            }
            for (elems) |el| try scanStackConstructsExpr(self, el, all_ok, any);
        },
        .dict_lit => |pairs| {
            all_ok.* = false;
            for (pairs) |p| {
                try scanStackConstructsExpr(self, p.key, all_ok, any);
                try scanStackConstructsExpr(self, p.value, all_ok, any);
            }
        },
        .await_expr => |op| try scanStackConstructsExpr(self, op.*, all_ok, any),
        .spawn_expr => |op| {
            all_ok.* = false;
            try scanStackConstructsExpr(self, op.*, all_ok, any);
        },
        .generic_construct => |g| {
            all_ok.* = false;
            for (g.args) |a| try scanStackConstructsExpr(self, a, all_ok, any);
        },
    }
}

/// GG.16 (bkz. nox-teknik-spesifikasyon.md §3.66): `fd`nin `param_name`
/// adlı parametresinin, gövde İÇİNDE HİÇ "kaçmadığını" (bir isme
/// BAĞLANMA/`return`/`len` DIŞINDA bir çağrıya argüman/bir alana-listeye-
/// dict'e YAZMA/İÇ İÇE `def` TARAFINDAN yakalanma OLMADIĞINI) KANITLAR.
/// BİLİNÇLİ olarak DAR: v1 SADECE ÜÇ salt-okunur kullanımı GÜVENLİ tanır —
/// (i) bir `for_stmt`nin ÜST-DÜZEY iterable'ı, (ii) bir `.index`
/// okumasının TABANI, (iii) `len(...)`e TEK argüman. VARSAYILAN `false`tur
/// (kaçtığını VARSAY) — BU, bu plandaki EN RİSKLİ karar noktası OLDUĞUNDAN
/// (yanlış bir `true`, ÇOK SONRA bir kullanım-sonrası-serbest-bırakmaya
/// yol açabilir) BİLİNÇLİ bir GÜVENLİK ilkesidir, sadece bir kolaylık
/// DEĞİL — güvenli-şekiller listesini BURADAN AYRI, bilinçli takip
/// işleri/YENİ golden testler OLMADAN GENİŞLETME.
fn paramNeverEscapes(self: *const Codegen, fd: ast.FuncDef, param_name: []const u8, class_params: []const ClassParam) bool {
    return stmtsSafeForParam(self, fd.body, param_name, class_params);
}

fn stmtsSafeForParam(self: *const Codegen, stmts: []const ast.Stmt, name: []const u8, class_params: []const ClassParam) bool {
    for (stmts) |stmt| {
        switch (stmt.kind) {
            .var_decl => |v| {
                if (std.mem.eql(u8, v.name, name)) return false;
                if (exprHasUnsafeParamUse(self, v.value, name, class_params)) return false;
            },
            .assign => |a| {
                if (a.target == .identifier and std.mem.eql(u8, a.target.identifier, name)) return false;
                if (exprHasUnsafeParamUse(self, a.target, name, class_params)) return false;
                if (exprHasUnsafeParamUse(self, a.value, name, class_params)) return false;
            },
            .expr_stmt => |e| if (exprHasUnsafeParamUse(self, e, name, class_params)) return false,
            .if_stmt => |f| {
                if (exprHasUnsafeParamUse(self, f.cond, name, class_params)) return false;
                if (!stmtsSafeForParam(self, f.then_body, name, class_params)) return false;
                for (f.elif_clauses) |ec| {
                    if (exprHasUnsafeParamUse(self, ec.cond, name, class_params)) return false;
                    if (!stmtsSafeForParam(self, ec.body, name, class_params)) return false;
                }
                if (f.else_body) |eb| if (!stmtsSafeForParam(self, eb, name, class_params)) return false;
            },
            .while_stmt => |w| {
                if (exprHasUnsafeParamUse(self, w.cond, name, class_params)) return false;
                if (!stmtsSafeForParam(self, w.body, name, class_params)) return false;
            },
            .for_stmt => |f| {
                if (std.mem.eql(u8, f.var_name, name)) return false;
                const iterable_is_direct = f.iterable == .identifier and std.mem.eql(u8, f.iterable.identifier, name);
                if (!iterable_is_direct and exprHasUnsafeParamUse(self, f.iterable, name, class_params)) return false;
                if (!stmtsSafeForParam(self, f.body, name, class_params)) return false;
            },
            .return_stmt => |r| {
                if (r) |e| if (exprHasUnsafeParamUse(self, e, name, class_params)) return false;
            },
            .raise_stmt => |e| if (exprHasUnsafeParamUse(self, e, name, class_params)) return false,
            // `try`/İç İçe `lowlevel`/`with`/`func_def`/`defer` — BİLİNMEYEN/
            // riskli bölge, TÜM analiz GÜVENLİ tarafta kalmak İçin İPTAL edilir.
            .try_stmt, .lowlevel_stmt, .with_stmt, .func_def, .defer_stmt => return false,
            .pass_stmt, .class_def, .protocol_def, .extern_def, .import_stmt, .from_import_stmt => {},
        }
    }
    return true;
}

/// `expr` İÇİNDE `name`in, `paramNeverEscapes`in TANIDIĞI üç GÜVENLİ
/// şekilden (for-iterable/index-tabanı/tek `len()` argümanı) BİRİSİ
/// OLMAYAN HERHANGİ bir kullanımı VARSA `true` döner (GÜVENSİZ). Bu üç
/// şekil BU fonksiyonun KENDİSİNDE DEĞİL, çağıranların (`stmtsSafeForParam`nin
/// `.for_stmt` dalı VE BURADAKİ `.index`/`len()` özel-durumları) ÖZEL
/// olarak TANIDIĞI konumlardır — bu fonksiyon SADECE "başka HERHANGİ bir
/// yerde çıplak bir `identifier(name)`" durumunu YAKALAR.
/// GG.20 (bkz. plan dosyası "ASAP güçlendirmesi — Tur 4"): `.call` dalı
/// ARTIK `self.escaping_params`e (bkz. `computeParamEscapes`) bakarak —
/// argüman ÇÖZÜLEBİLİR bir SERBEST fonksiyona geçiyorsa VE hedef parametre
/// KANITLANMIŞ olarak KAÇMIYORSA — bunu GÜVENLİ sayar (Tur 1/2/3'ün
/// "argüman-olarak-geçiş HER ZAMAN kaçış" KATI kuralının İLK gevşetilmesi).
/// **`spawn` İSTİSNASI (KRİTİK GÜVENLİK)**: BU carve-out `spawn`ın
/// SARDIĞI çağrının argümanlarına HİÇ UYGULANMAZ (bkz. `.spawn_expr` dalı,
/// AŞAĞIDA AYRICA ele alınır) — `spawn` callee'sinin KENDİ gövdesi "kaçmıyor"
/// KANITLANSA BİLE, çağrı ASENKRON/OLASI FARKLI bir OS iş parçacığında
/// çalışır VE çağıranın stack çerçevesi (fiber'ın KENDİ stack'i) spawn
/// edilen görev HÂLÂ çalışırken YOK EDİLEBİLİR — BU, `computeMustNotRaise`
/// TARZI "aynı çerçeve İçİnde senkron" akıl yürütmesinin GEÇERLİ OLMADIĞI,
/// TAMAMEN FARKLI bir kaçış sınıfıdır.
fn exprHasUnsafeParamUse(self: *const Codegen, expr: ast.Expr, name: []const u8, class_params: []const ClassParam) bool {
    return switch (expr) {
        .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit => false,
        .identifier => |n| std.mem.eql(u8, n, name),
        .unary => |u| exprHasUnsafeParamUse(self, u.operand.*, name, class_params),
        .binary => |b| exprHasUnsafeParamUse(self, b.left.*, name, class_params) or exprHasUnsafeParamUse(self, b.right.*, name, class_params),
        .call => |c| blk: {
            if (c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, "len") and
                c.args.len == 1 and c.args[0] == .identifier and std.mem.eql(u8, c.args[0].identifier, name))
            {
                break :blk false; // `len(name)` TEK BAŞINA GÜVENLİDİR.
            }
            if (exprHasUnsafeParamUse(self, c.callee.*, name, class_params)) break :blk true;
            const callee_is_resolvable_free_fn = c.callee.* == .identifier and self.func_defs.contains(c.callee.identifier);
            // GG.21: receiver `class_params`de bilinen bir sibling-parametreyse
            // VE metod PROVABLY final İSE, AYNI carve-out'u UYGULA (`self`
            // metodun KENDİ NodeKey indekslemesinde HER ZAMAN 0'DA olduğundan
            // `arg_idx` +1 KAYDIRILIR).
            var method_owner: ?[]const u8 = null;
            if (c.callee.* == .attribute) {
                const at = c.callee.attribute;
                if (resolveClassParamReceiver(at.obj.*, class_params)) |recv_class| {
                    if (self.classes.get(recv_class)) |cinfo| {
                        if (cinfo.methods.get(at.attr)) |msig| {
                            if (methodIsFinal(self, recv_class, at.attr)) {
                                method_owner = std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ msig.owner, at.attr }) catch null;
                            }
                        }
                    }
                }
            }
            for (c.args, 0..) |a, arg_idx| {
                if (a == .identifier and std.mem.eql(u8, a.identifier, name) and callee_is_resolvable_free_fn) {
                    if (!self.escaping_params.contains(.{ .func = c.callee.identifier, .index = @intCast(arg_idx) })) {
                        continue; // İSPATLANMIŞ güvenli yönlendirme.
                    }
                }
                if (a == .identifier and std.mem.eql(u8, a.identifier, name) and method_owner != null) {
                    if (!self.escaping_params.contains(.{ .func = method_owner.?, .index = @intCast(arg_idx + 1) })) {
                        continue; // İSPATLANMIŞ güvenli yönlendirme (final metod).
                    }
                }
                if (exprHasUnsafeParamUse(self, a, name, class_params)) break :blk true;
            }
            break :blk false;
        },
        .attribute => |a| exprHasUnsafeParamUse(self, a.obj.*, name, class_params),
        .index => |idx| blk: {
            const obj_is_direct = idx.obj.* == .identifier and std.mem.eql(u8, idx.obj.identifier, name);
            if (!obj_is_direct and exprHasUnsafeParamUse(self, idx.obj.*, name, class_params)) break :blk true;
            break :blk exprHasUnsafeParamUse(self, idx.index.*, name, class_params);
        },
        .list_lit => |elems| blk: {
            for (elems) |el| if (exprHasUnsafeParamUse(self, el, name, class_params)) break :blk true;
            break :blk false;
        },
        .dict_lit => |pairs| blk: {
            for (pairs) |p| {
                if (exprHasUnsafeParamUse(self, p.key, name, class_params)) break :blk true;
                if (exprHasUnsafeParamUse(self, p.value, name, class_params)) break :blk true;
            }
            break :blk false;
        },
        .await_expr => |op| exprHasUnsafeParamUse(self, op.*, name, class_params),
        .spawn_expr => |op| blk: {
            // KRİTİK: `spawn`ın SARDIĞI çağrının argümanları HER ZAMAN
            // (yukarıdaki carve-out'lardan BAĞIMSIZ olarak) `name` İLE
            // doğrudan eşleşirse kaçış SAYILIR — bkz. belge notu.
            if (op.* == .call) {
                const c = op.*.call;
                if (exprHasUnsafeParamUse(self, c.callee.*, name, class_params)) break :blk true;
                for (c.args) |a| {
                    if (a == .identifier and std.mem.eql(u8, a.identifier, name)) break :blk true;
                    if (exprHasUnsafeParamUse(self, a, name, class_params)) break :blk true;
                }
                break :blk false;
            }
            break :blk exprHasUnsafeParamUse(self, op.*, name, class_params);
        },
        .generic_construct => |g| blk: {
            for (g.args) |a| if (exprHasUnsafeParamUse(self, a, name, class_params)) break :blk true;
            break :blk false;
        },
    };
}

/// GG.16: `outer_callee`nin (`self.func_defs`den, GG.2-inline-edilebilirlik
/// ARANMAZ — `sum_list` gibi bir `for` İÇEREN fonksiyon da BURAYA
/// UYGUNDUR) `args`ının HER birinde, argümanın KENDİSİ GG.2-inline-edilebilir
/// bir fonksiyona (`self.inlinable_funcs`) TEK-satırlık `return <basit-
/// literal list_lit>` biçiminde bir çağrıysa VE KARŞILIK GELEN parametre
/// `paramNeverEscapes` İLE KANITLANIYORSA, o `list_lit`i bir yığın slotuna
/// dönüştürür — ama SADECE BU ÖZEL çağrı sitesi İçin (bkz. `Codegen.
/// stack_slot_call_sites`in belge notu: `elems.ptr` DEĞİL, `arg_call.callee`
/// İLE anahtarlanır — AYNI `list_lit` gövdesinin BAŞKA, güvensiz bir çağrı
/// sitesinden — ör. bir isme atanarak — de çağrılabileceği İçin).
pub fn tryRegisterCrossCallStackSlots(self: *Codegen, outer_callee: ast.FuncDef, args: []const ast.Expr) CodegenError!void {
    const class_params = try collectClassParams(self, self.allocator, outer_callee.params);
    const n = @min(outer_callee.params.len, args.len);
    for (0..n) |i| {
        if (args[i] != .call) continue;
        const arg_call = args[i].call;
        if (arg_call.callee.* != .identifier) continue;
        if (self.stack_slot_call_sites.contains(@intFromPtr(arg_call.callee))) continue;
        const arg_fd = self.inlinable_funcs.get(arg_call.callee.identifier) orelse continue;
        if (arg_fd.body.len != 1 or arg_fd.body[0].kind != .return_stmt) continue;
        const ret_expr = arg_fd.body[0].kind.return_stmt orelse continue;
        if (ret_expr != .list_lit) continue; // v1: yalnızca liste literalleri.
        const elems = ret_expr.list_lit;
        if (self.stack_construct_sites.contains(@intFromPtr(elems.ptr))) continue;
        const elem_qtype = simpleLiteralListQtype(elems) orelse continue;
        if (!paramNeverEscapes(self, outer_callee, outer_callee.params[i].name, class_params)) continue;
        const payload_size = LIST_HEADER_SIZE + qbeSizeOf(elem_qtype) * elems.len;
        if (payload_size > MAX_STACK_ALLOC_SIZE) continue; // GG.17: ortak boyut tavanı.
        const slot = try self.newTemp();
        try self.qbeAlloc(slot, .eight, payload_size);
        // `genInlinedCall`, BU SPESİFİK çağrı sitesini (`c.callee ==
        // arg_call.callee`) splice ederken `self.pending_stack_slot`i
        // BUNUNLA ayarlar — `genListLit` BUNU tüketir. AYNI `list_lit`
        // gövdesinin BAŞKA bir çağrı sitesi (ör. `stored = make_pair()`)
        // BU tabloda YOK olduğundan normal heap-tahsise DÜŞMEYE devam eder.
        try self.stack_slot_call_sites.put(self.allocator, @intFromPtr(arg_call.callee), slot);
    }
}

/// Faz GG.2: `genFunction`/`genMethod`/`genMain`/`genMainAsync`/
/// `genClosureFunc`nin BEŞİNİN de KENDİ `allocSlot` döngüsünden HEMEN
/// SONRA, `genStmts` ÇAĞRILMADAN ÖNCE çağırdığı TEK giriş noktası.
pub fn prepareInlineSites(self: *Codegen, stmts: []const ast.Stmt) CodegenError!void {
    // **KRİTİK:** `self.inline_sites` HER üst-düzey gövde-üretim çağrısı
    // (bkz. bu fonksiyonun 5 çağrı sitesi) BAŞINDA TEMİZLENİR — GERÇEK
    // bir çöküşle KANITLANMIŞ bir hatanın düzeltmesi (bkz. break→red→fix
    // ritüeli): bir callee'nin (ör. `quadruple`) KENDİ gövdesi
    // İÇİNDEKİ çağrılar (ör. `double(double(x))`), `quadruple`nin
    // KENDİ `genFunction`ı SIRASINDA KAYDEDİLİP `$quadruple`nin
    // KENDİ QBE metnine `alloc8`'lenmiş slotlarla EŞLEŞTİRİLİR — bu
    // KAYITLAR SİLİNMEZSE VE `quadruple`nin KENDİSİ SONRADAN BAŞKA bir
    // çağrı sitesinde inline edilirse (bkz. `genInlinedCall`), o
    // splice'ın İÇİNDEKİ AYNI çağrı AST düğümleri `self.inline_sites`de
    // BULUNUR ama slotları ARTIK GEÇERSİZ bir QBE fonksiyonuna (`
    // $quadruple`ye) AİTTİR — `main`in İÇİNE splice edilirken BU
    // GEÇERSİZ slotlara `store`/`load` YAPILMASI tanımsız davranışa
    // (GERÇEKTEN gözlemlenen bir segfault) yol açar. Temizleme, "İÇ İÇE
    // inlining YOK" kuralını (bkz. `registerInlineSite`in belge notu)
    // DOĞRU biçimde ZORUNLU kılar: bir splice İÇİNDEKİ iç içe çağrılar
    // ARTIK `self.inline_sites`de HİÇ BULUNAMAZ (bu üst-düzey çağrının
    // KENDİ, TAZE kaydından), bu yüzden GÜVENLE GERÇEK bir `call`e
    // düşerler.
    self.inline_sites.clearRetainingCapacity();
    try self.collectInlineSitesStmts(stmts);
}

/// GG.14 (bkz. nox-teknik-spesifikasyon.md §3.66): `expr`nin HER ZAMAN
/// (çalışma zamanı değerinden BAĞIMSIZ) bir string LİTERALİNE (`PINNED_
/// REFCOUNT`, ASLA sıfıra İNMEZ) çözüldüğünü KANITLAR — TAMAMEN dar VE
/// bilinçli MUHAFAZAKÂR: `.string_lit` → `true`; `self.func_defs`den
/// (ZATEN dolu, YENİ bir tüm-program geçişi GEREKMEZ) çözülen bir SERBEST
/// fonksiyona çağrıysa VE gövdesindeki TÜM `return`lar DOĞRUDAN
/// `.string_lit` (ya da — `depth` sınırı İÇİNDE — YİNE BÖYLE bir fonksiyona
/// çağrı) İSE → `true`; AKSİ HALDE (BAŞTA `pass_through(s): return s` GİBİ
/// bir PARAMETREYİ olduğu gibi döndüren fonksiyonlar — bunun HER ZAMAN
/// pinned OLDUĞU ANCAK ÇAĞRI SİTESİNE bakılarak bilinebilir, bu FONKSİYONUN
/// KENDİ gövdesinden DEĞİL, bu YÜZDEN BİLİNÇLİ olarak TANINMAZ) → `false`.
/// `depth` özyinelemeyi (ör. birbirini ÇAĞIRAN sabit-döndüren fonksiyonlar
/// zinciri) SINIRLAR — aşılırsa GÜVENLİ tarafta (`false`) KAL.
pub fn exprAlwaysProducesPinnedString(self: *Codegen, expr: ast.Expr, depth: u32) bool {
    if (depth > 2) return false;
    return switch (expr) {
        .string_lit => true,
        .call => |c| blk: {
            if (c.callee.* != .identifier) break :blk false;
            const fd = self.func_defs.get(c.callee.identifier) orelse break :blk false;
            break :blk funcAlwaysReturnsPinnedString(self, fd.body, depth + 1);
        },
        else => false,
    };
}

/// `body`deki (özyinelemeli, `if`/`elif`/`else` İÇİNE de) HER `return_stmt`in
/// DOĞRUDAN (ya da GG.14'ün `depth` sınırı İÇİNDE, başka bir sabit-döndüren
/// fonksiyona çağrı İLE) bir string literaline çözüldüğünü doğrular.
/// Dönüş: `null` — bir İHLAL bulundu (GÜVENSİZ, hemen `false`a düş);
/// `true`/`false` — hiçbir İHLAL YOK, ama en az BİR gerçek `return_stmt`
/// bulunup BULUNMADIĞI (boş/return'süz bir dal `false` — vacuous-truth
/// RİSKİNİ engeller, ör. TÜM dalları BOŞ olan bir `if` YANLIŞLIKLA
/// "her zaman pinned" SAYILMASIN).
fn funcAlwaysReturnsPinnedString(self: *Codegen, body: []const ast.Stmt, depth: u32) bool {
    return (bodyReturnsCheck(self, body, depth) orelse false) == true;
}

fn bodyReturnsCheck(self: *Codegen, body: []const ast.Stmt, depth: u32) ?bool {
    var found_any = false;
    for (body) |stmt| {
        switch (stmt.kind) {
            .return_stmt => |r| {
                const e = r orelse return null;
                if (!exprAlwaysProducesPinnedString(self, e, depth)) return null;
                found_any = true;
            },
            .if_stmt => |f| {
                const then_r = bodyReturnsCheck(self, f.then_body, depth) orelse return null;
                if (then_r) found_any = true;
                for (f.elif_clauses) |ec| {
                    const r = bodyReturnsCheck(self, ec.body, depth) orelse return null;
                    if (r) found_any = true;
                }
                if (f.else_body) |eb| {
                    const r = bodyReturnsCheck(self, eb, depth) orelse return null;
                    if (r) found_any = true;
                }
            },
            // Döngü/`try`/`lowlevel`/iç içe `func_def` İÇEREN bir gövde —
            // BİLİNÇLİ olarak TANINMAZ (bu fonksiyon zaten GG.14'ün
            // KAPSAMI DIŞINDA — `while`/`for` İÇİNDEKİ bir `return` bu
            // basit "TÜM return'ler İNCELENDİ" sayımını KARMAŞIKLAŞTIRır).
            .while_stmt, .for_stmt, .try_stmt, .lowlevel_stmt, .func_def, .with_stmt => return null,
            else => {},
        }
    }
    return found_any;
}

/// Faz GG.2: `prepareInlineSites`in ÖNCEDEN KAYDETTİĞİ bir splice
/// sitesini ÜRETİR — GERÇEK bir `call` YERİNE `site.callee.body`yi
/// caller'ın KENDİ QBE akışına SPLICE eder. QBE-seviyesi SSA geçicileri
/// (`%tN`) zaten fonksiyon BOYUNCA benzersiz OLDUĞUNDAN (bkz.
/// `self.temp_counter`) YENİDEN ADLANDIRMA GEREKMEZ — TEK hijyen adımı,
/// callee'nin KAYNAK isimlerini `self.vars`a GEÇİCİ olarak GÖLGELEMEK
/// (eski değeri KAYDEDİP splice SONRASI GERİ YÜKLEMEK). `isFuncInlineEligible`
/// (`must_not_raise` şartı) bu splice SIRASINDA `emitExceptionCheck`in
/// ASLA tetiklenemeyeceğini (dolayısıyla caller'ın ERKEN-çıkış yolunun,
/// o an GÖLGELENMİŞ bir yerelin GÖRÜNMEZ kalıp SIZMASININ) YAPISAL
/// olarak İMKANSIZ olmasını GARANTİ eder.
pub fn genInlinedCall(self: *Codegen, c: ast.Call, site: InlineSiteInfo) CodegenError!Value {
    // 1) Argümanları NORMAL yoldakiyle AYNI şekilde değerlendirip
    // ÖN-TAHSİS EDİLMİŞ parametre slotlarına yaz. `arg_v0s` (dönüşümden
    // ÖNCEKİ, HAM `genExprForTarget` sonuçları) AŞAĞIDA `releaseTemporaryArgs`e
    // geçirilir — GERÇEK (inline OLMAYAN) çağrı yolunun `genCall`de
    // YAPTIĞI AYNI "ödünç alınan parametre slotuna yaz, splice
    // SONRASI TAZE argümanı ÇAĞIRAN serbest bırakır" dengesi BURADA da
    // KORUNMALIDIR — bu adım UNUTULURSA (İLK sürümde OLDUĞU GİBİ) HER
    // taze argüman (ör. `show(safe_div(...))`) KALICI olarak SIZAR
    // (GERÇEKTEN gözlemlendi, break→red→fix ritüeliyle doğrulanacak).
    // Bkz. `Codegen.mod_cache`nin belge notu, madde 5: bir argüman DÜZ
    // bir kimlikse (ör. `pick(i)`), VE o parametre callee'nin KENDİ
    // gövdesi İÇİNDE HİÇ yeniden atanmıyorsa, parametrenin DEĞERİ
    // callee BOYUNCA caller'ın argüman SLOTUYLA AYNI KALIR (BY-VALUE
    // kopya, hiç sapma YOK) — bu YÜZDEN callee'nin KENDİ üst-düzey
    // kodunun bu parametre İçin kurduğu HERHANGİ bir `%d`-önbellek
    // girdisi, splice BİTİMİNDE (`self.vars` ESKİ HALİNE dönmeden
    // HEMEN ÖNCE, bkz. AŞAĞIDAKİ 4.5 adımı) caller'ın KENDİ argüman
    // SLOTU ALTINDA da GÜVENLE KOPYALANABİLİR — `arg_alias_slot[i]`
    // (gölgeleme BAŞLAMADAN ÖNCE, self.vars HÂLÂ caller'ı gösterirken)
    // BURADA yakalanır.
    const arg_alias_slot = try self.allocator.alloc(?[]const u8, site.params.len);
    var callee_reassigned: std.StringHashMapUnmanaged(void) = .empty;
    try collectReassignedNames(site.callee.body, &callee_reassigned, self.allocator);

    const arg_v0s = try self.allocator.alloc(Value, site.params.len);
    for (site.params, 0..) |p, i| {
        arg_alias_slot[i] = blk: {
            if (c.args[i] != .identifier) break :blk null;
            if (callee_reassigned.contains(p.orig_name)) break :blk null;
            const arg_vi = self.vars.get(c.args[i].identifier) orelse break :blk null;
            break :blk arg_vi.slot;
        };
        const v0 = try self.genExprForTarget(c.args[i], p.info);
        try self.checkNoLowlevelEscape(v0);
        arg_v0s[i] = v0;
        const v = try self.convert(v0, p.info.qtype);
        try self.qbeStore(p.info.qtype, v.text, p.slot);
        // Bkz. `Codegen.mod_cache`nin belge notu, madde 5: bu yazma da
        // BİR `.assign` AST düğümünü BAYPAS EDER (BİR ÖNCEKİ çağrıdan —
        // ör. bir döngü İÇİNDEYSE bir ÖNCEKİ yinelemeden — kalan bayat
        // bir argüman değerinin YENİDEN kullanılmasını ÖNLEMEK için
        // AYRICA geçersiz kılınır).
        try self.modCacheInvalidateSlot(p.slot);
    }

    // 2) callee'nin parametre+yerellerini `self.vars`a GÖLGELE (eski
    // değeri SAKLA).
    const owned_count = site.params.len + site.locals.len;
    const owned_names = try self.allocator.alloc([]const u8, owned_count);
    const saved = try self.allocator.alloc(?VarInfo, owned_count);
    var idx: usize = 0;
    for (site.params, 0..) |p, i| {
        owned_names[idx] = p.orig_name;
        saved[idx] = self.vars.get(p.orig_name);
        // GG.14 (bkz. nox-teknik-spesifikasyon.md §3.66): BU splice
        // sitesinde `c.args[i]`nin HER ZAMAN bir string LİTERALİ
        // ürettiği KANITLANABİLİYORSA (`exprAlwaysProducesPinnedString`),
        // `returnNeedsRetain`/`retainIfAliasing`nin BU parametre İçin
        // retain'i TAMAMEN atlaması İçin işaretlenir — `pass_through(s):
        // return s`in `s`si HER ZAMAN `is_param`, bu YÜZDEN normalde
        // KOŞULSUZ retain İSTERdi.
        const is_pinned_str = p.info.heap == .str and exprAlwaysProducesPinnedString(self, c.args[i], 0);
        try self.vars.put(self.allocator, p.orig_name, .{
            .slot = p.slot,
            .qtype = p.info.qtype,
            .heap = p.info.heap,
            .elem_qtype = p.info.elem_qtype,
            .class_name = p.info.class_name,
            .elem_heap_info = p.info.elem_heap_info,
            .elem_is_str = p.info.elem_is_str,
            .dict_info = p.info.dict_info,
            .func_sig = p.info.func_sig,
            .is_param = true,
            .arena = false,
            .is_pinned_str = is_pinned_str,
        });
        idx += 1;
    }
    for (site.locals) |l| {
        owned_names[idx] = l.orig_name;
        saved[idx] = self.vars.get(l.orig_name);
        // GG.19: BU isim `registerInlineSite`nin GG.17/18 taramasında BİR
        // aday olarak KAYDEDİLDİYSE (`site.construct_sites`), shadowed
        // `VarInfo`ye `is_stack_local`/`growable_arena`yı DOĞRUDAN YAZ —
        // `allocSlotEx`nin normal (standalone-derleme) name-keyed tablo
        // OKUMASINA burada HİÇ GEREK YOK (genInlinedCall ZATEN VarInfo'yu
        // elle inşa ediyor).
        var is_stack_local = false;
        var growable_arena: ?[]const u8 = null;
        for (site.construct_sites) |cs| {
            if (!std.mem.eql(u8, cs.var_name, l.orig_name)) continue;
            switch (cs.candidate) {
                .fixed_stack => is_stack_local = true,
                .growable_arena => growable_arena = cs.handle,
            }
            break;
        }
        try self.vars.put(self.allocator, l.orig_name, .{
            .slot = l.slot,
            .qtype = l.info.qtype,
            .heap = l.info.heap,
            .elem_qtype = l.info.elem_qtype,
            .class_name = l.info.class_name,
            .elem_heap_info = l.info.elem_heap_info,
            .elem_is_str = l.info.elem_is_str,
            .dict_info = l.info.dict_info,
            .func_sig = l.info.func_sig,
            .is_param = false,
            .arena = growable_arena != null,
            .is_stack_local = is_stack_local,
            .growable_arena = growable_arena,
        });
        idx += 1;
    }

    // 3) Dönüş bağlamını (`current_ret_info`) VE `inline_return_target`i
    // AYARLA (eski değerleri SAKLA).
    const saved_ret_info = self.current_ret_info;
    const saved_inline_target = self.inline_return_target;
    const callee_ret_info = try self.resolveType(site.callee.return_type);
    self.current_ret_info = callee_ret_info;
    const done_label = try self.newLabel("inline_done");
    self.inline_return_target = .{
        .result_slot = if (site.result) |r| r.slot else null,
        .done_label = done_label,
        .owned_names = owned_names,
    };

    // 4) Gövdeyi DEĞİŞTİRİLMEDEN üret — `.return_stmt` dalı `inline_
    // return_target`i GÖRÜP gerçek `ret` YERİNE `jmp done_label` üretir
    // (VE `owned_names`i KENDİSİ serbest bırakıp BURAYA HİÇ dönmez).
    //
    // **Düzeltme (gerçek bir sızıntıyla KANITLANMIŞ — bkz. break→red→fix
    // ritüeli):** callee'nin gövdesi hiç `return` İÇERMİYORSA (örtük
    // `None` dönüşü, ör. yalnızca `var_decl`lerden oluşan bir gövde),
    // `.return_stmt` dalı HİÇ TETİKLENMEZ — bu durumda `genStmts`
    // BURAYA DÜZ DÜŞEREK döner, callee'nin KENDİ `owned_names`i (ör.
    // heap-yönetimli yerel değişkenleri) HİÇ serbest BIRAKILMADAN
    // atlanırdı (`genFunction`in KENDİ örtük düşme kuyruğunun AKSİNE —
    // o `releaseAllLocals()`ı KOŞULSUZ çağırır). Bu satır AYNI
    // KOŞULSUZ deseni BURAYA da uygular: `return_stmt` YOLU zaten
    // KENDİ serbest bırakmasını yapıp `jmp done_label` İLE BURAYA
    // HİÇ uğramadığından (Zig fonksiyonu erken `return` eder), bu kod
    // YALNIZCA gerçek bir düz-düşme SIRASINDA çalışır — çift serbest
    // bırakma RİSKİ YOKTUR.
    // GG.16: BU splice'ın KENDİ çağrı sitesi (`c.callee`) `tryRegisterCrossCallStackSlots`
    // TARAFINDAN ÖNCEDEN bir yığın slotuna EŞLENDİYSE, `self.pending_stack_slot`i
    // SADECE BU gövde-üretimi SÜRESİNCE ayarla — `genListLit` (gövde İÇİNDEKİ
    // `return [10, 20]`) BUNU görüp `nox_arena_alloc`/`nox_rc_alloc` ÇAĞRISINI
    // ATLAR. Kapsamı BU tek splice'a sıkı tutmak (SAKLA/GERİ-YÜKLE), AYNI
    // `list_lit` gövdesinin BAŞKA bir splice sitesinde (bu tabloda YOK)
    // yanlışlıkla yığın-slotlu ÜRETİLMESİNİ ÖNLER.
    // GG.19: BU splice'a ÖZGÜ, TAZE GG.17/18 tutamaklarını `genStmts`DAN
    // HEMEN ÖNCE `stack_construct_sites`/`arena_local_construct_sites`e
    // GEÇİCİ olarak YÜKLE — `genListLit`/`genConstructFromValues` (callee
    // gövdesi İÇİNDEKİ AYNI AST düğümlerini BURADA YENİDEN işlerken) BU
    // TAZE, caller'a ÖZGÜ tutamakları BULUR (standalone-derlenmiş `callee`nin
    // KENDİ, TAMAMEN İLGİSİZ kaydını DEĞİL).
    for (site.construct_sites) |cs| {
        if (!cs.needs_node_registration) continue;
        switch (cs.candidate) {
            .fixed_stack => try self.stack_construct_sites.put(self.allocator, cs.node_key, .{ .slot = cs.handle }),
            .growable_arena => try self.arena_local_construct_sites.put(self.allocator, cs.node_key, cs.handle),
        }
    }
    const saved_pending_stack_slot = self.pending_stack_slot;
    self.pending_stack_slot = self.stack_slot_call_sites.get(@intFromPtr(c.callee));
    try self.genStmts(site.callee.body, callee_ret_info.qtype);
    self.pending_stack_slot = saved_pending_stack_slot;
    // GG.19: splice BİTTİĞİNDE bu GEÇİCİ girdileri SİL — `helper()` AYNI
    // caller İçİnde BİRDEN FAZLA çağrılırsa HER splice KENDİ TAZE
    // tutamağını İSTER (bkz. `InlineConstructSite`nin belge notu, "save/
    // restore DEĞİL SİL" gerekçesi).
    for (site.construct_sites) |cs| {
        if (!cs.needs_node_registration) continue;
        switch (cs.candidate) {
            .fixed_stack => _ = self.stack_construct_sites.remove(cs.node_key),
            .growable_arena => _ = self.arena_local_construct_sites.remove(cs.node_key),
        }
    }
    try self.releaseNamedLocalsExcept(owned_names, null);
    try self.qbeJmp(done_label);
    try self.qbeLabel(done_label);

    // 4.5) Bkz. `Codegen.mod_cache`nin belge notu, madde 5 VE 1. adımdaki
    // `arg_alias_slot` notu: `self.vars` HENÜZ geri YÜKLENMEDEN (callee'nin
    // parametreleri HÂLÂ görünürken), callee'nin ÜST-DÜZEY kodunun BU
    // parametre İçin kurduğu (yalnızca TÜM dallardan BAĞIMSIZ, GENEL
    // düz-akışta hayatta kalan — `genIf`in dal-yerel girdileri ZATEN
    // ELEDİĞİ, bkz. onun belge notu) HERHANGİ bir `%d`-önbellek girdisi,
    // caller'ın KENDİ argüman SLOTU ALTINDA da KOPYALANIR — `compute`nin
    // `pick(i)` SONRASI KENDİ `if i % 3 == 0` kontrolünün, `pick`nin
    // İÇİNDE ZATEN hesaplanmış `i % 3`yü YENİDEN kullanmasını SAĞLAYAN
    // TAM OLARAK BUDUR.
    for (site.params, 0..) |p, i| {
        if (arg_alias_slot[i]) |caller_slot| {
            try self.copyModCacheAlias(p.slot, caller_slot);
        }
    }

    // 5) HER ŞEYİ geri yükle.
    self.current_ret_info = saved_ret_info;
    self.inline_return_target = saved_inline_target;
    for (owned_names, 0..) |name, i| {
        if (saved[i]) |old| {
            try self.vars.put(self.allocator, name, old);
        } else {
            _ = self.vars.remove(name);
        }
    }

    // 6) GERÇEK (inline OLMAYAN) çağrı yolunun `genCall`de YAPTIĞI AYNI
    // dengeleme: TAZE argümanlar (bkz. `isTemporaryExpr`/`always_fresh`)
    // splice BOYUNCA yalnızca ÖDÜNÇ ALINMIŞ bir parametre slotu OLARAK
    // ele alındığından (`is_param = true`, `.return_stmt`in `releaseNamedLocalsExcept`si
    // ASLA dokunmaz), sahiplikleri HÂLÂ ÇAĞIRANDADIR — BURADA serbest
    // bırakılır.
    try self.releaseTemporaryArgs(c.args, arg_v0s);

    // 7) Sonucu üret.
    if (site.result) |r| {
        const t = try self.newTemp();
        try self.qbeLoad(t, r.info.qtype, r.info.qtype, r.slot);
        return .{
            .text = t,
            .qtype = r.info.qtype,
            .heap = r.info.heap,
            .elem_qtype = r.info.elem_qtype,
            .class_name = r.info.class_name,
            .elem_heap_info = r.info.elem_heap_info,
            .elem_is_str = r.info.elem_is_str,
            .dict_info = r.info.dict_info,
            // GG.16: `c.callee`nin (BU splice'ın KENDİ çağrı sitesi —
            // ör. `make_data()`) `tryRegisterCrossCallStackSlots` TARAFINDAN
            // İŞARETLENİP İŞARETLENMEDİĞİNİ kontrol eder — bkz. `Codegen.
            // stack_slot_call_sites`in belge notu (bu bayrak, `genListLit`nin
            // İÇERİDE ayarladığı `is_stack_slot`in, BU "sonuç-slotundan
            // YÜKLE" adımında KAYBOLMAMASI İçin BURADA YENİDEN kurulur).
            .is_stack_slot = self.stack_slot_call_sites.contains(@intFromPtr(c.callee)),
        };
    }
    return .{ .text = "0", .qtype = .w };
}
