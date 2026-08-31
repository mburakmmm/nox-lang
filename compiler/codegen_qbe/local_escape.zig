//! GG.17 (bkz. nox-teknik-spesifikasyon.md §3.10X, plan dosyası "ASAP
//! güçlendirmesi — Tur 1"): GG.15 (`lowlevel:` blok gövdeleri) VE GG.16
//! (bir çağrının argümanı olarak geçen, `paramNeverEscapes`in KANITLADIĞI
//! bir dönüş değeri) DIŞINDA, SIRADAN bir fonksiyon gövdesindeki `var_decl`
//! bağlamalarını (`p: Point = Point(1,2)`, `xs: list[int] = [1,2,3]`)
//! kapsayan ÜÇÜNCÜ bir "kanıtla → stack `alloc8`" üreticisi. `paramNeverEscapes`
//! İLE AYNI disiplin: ŞÜPHEDE HER ZAMAN "kaçıyor" varsay, SADECE MUTLAK
//! kanıtlanabilir durumlar dönüştürülür — kanıtlanamayan HER şey (bugünkü
//! DAVRANIŞLA TAM eşdeğer) `nox_rc_alloc`ta kalır.
//!
//! Kapsam (v1, BİLİNÇLİ sınırlar — bkz. plan dosyasının "Kapsam DIŞI"
//! bölümü): SADECE fonksiyon gövdesinin ÜST DÜZEYİNDEKİ `var_decl`ler
//! (iç içe if/while/for/try/with İÇİNDE bildirilenler DEĞİL — Nox'ta
//! `var_decl` blok-kapsamlı DEĞİLDİR, bu YÜZDEN "bu yerelin kapsamı NEREDE
//! bitiyor" sorusu iç içe bildirimler İçİn KARMAŞIKLAŞIR; üst-düzey
//! bildirimler İçİn kapsam AÇIKÇA "bildirim noktasından fonksiyon sonuna
//! kadar"dır). Değeri: derleme-zamanında boyutu bilinen bir sınıf kurucusu
//! çağrısı (`ClassName(...)`) YA DA basit-literal (`int_lit`/`float_lit`/
//! `bool_lit`, hepsi AYNI türden) bir `list_lit`. Metod çağrıları (`obj.
//! method()`) VE argüman-olarak-geçiş HER ZAMAN kaçış SAYILIR (interprocedural
//! kanıt YOK, `paramNeverEscapes`in KENDİ "bilinçli takip işleri OLMADAN
//! GENİŞLETME" uyarısıyla TUTARLI).
//!
//! GG.18 (plan dosyası "ASAP güçlendirmesi — Tur 2"): YUKARIDAKİ (sabit-
//! boyutlu, `alloc8`) kapsamın DIŞINDA kalan — boş `[]` literali, `.append()`
//! İLE büyüyen, YA DA elemanları literal OLMAYAN — bir `list[T]` (`T`
//! SKALER: int/float/bool) yereli İçİn, AYNI muhafazakâr disiplinle,
//! fonksiyon-kapsamlı ÖZEL bir arena kullanır (`nox_rc_alloc`/refcount
//! başlığı YERİNE). `classifyVarDecl` HER İKİ Turu da TEK, PAYLAŞILAN bir
//! sınıflandırıcıda BİRLEŞTİRİR.
//!
//! **GG.17 hotfix (bkz. plan dosyası, "Tur 2"nin İLK maddesi)**: bu
//! dosyanın kaydettiği HER düğüm (`stack_construct_sites`/`arena_local_
//! construct_sites`), AST-düğüm-POINTER'ı anahtarlı VE HİÇ TEMİZLENMEYEN
//! GLOBAL tablolara yazıldığından, kaydı yapan fonksiyonun KENDİSİ GG.2
//! TARAFINDAN BAŞKA bir çağrı sitesine inline-SPLICE edilirse, splice
//! SIRASINDA AYNI düğüm YENİDEN işlenir VE ESKİ (kayıt ANINDAKİ fonksiyonun
//! KENDİ temp-numaralandırmasına ÖZGÜ) bir QBE geçici adı BULUNUP
//! KULLANILIR — bu, SPLICE edilen fonksiyonda (`caller`) O isim BAŞKA
//! bir yerele AİTSE GERÇEK bir çapraz-fonksiyon bellek bozulmasıdır
//! (doğrudan derlenip ÇALIŞTIRILARAK KANITLANDI). Düzeltme: `computeFuncsWithLocalConstructSites`
//! (whole-program, `computeInlinableFunctions`'DAN ÖNCE çalışan SAF bir
//! ön-tarama) BU dosyanın kaydedeceği HER fonksiyonu ÖNCEDEN belirleyip
//! `isFuncInlineEligible`'ın bu fonksiyonları GG.2 inline-edilebilirliğinden
//! TAMAMEN DIŞLAMASINI sağlar — `lowlevel_stmt` İÇEREn bir gövdenin ZATEN
//! aynı gerekçeyle dışlanmasıyla TUTARLI (bkz. `inlining.zig`).

const std = @import("std");
const ast = @import("../parser/ast.zig");
const types = @import("types.zig");
const abi = @import("abi.zig");
const codegen = @import("codegen.zig");
const inlining = @import("inlining.zig");

const Codegen = codegen.Codegen;
const QbeType = types.QbeType;
const LIST_HEADER_SIZE = types.LIST_HEADER_SIZE;
const CodegenError = abi.CodegenError;
const qbeSizeOf = abi.qbeSizeOf;
const simpleLiteralListQtype = inlining.simpleLiteralListQtype;
const MAX_STACK_ALLOC_SIZE = inlining.MAX_STACK_ALLOC_SIZE;
const isHeapManaged = abi.isHeapManaged;

/// **GERÇEK, DENEYEREK BULUNAN hata (break→red→fix)**: bir sınıf örneğini
/// stack'e almak, örneğin KENDİ alan-seviyesi release'ini de (`ClassName_
/// release`in normalde YAPACAĞI, HER heap-yönetimli alanı özyinelemeli
/// serbest bırakma İŞLEMİNİ) `releaseOneLocalIfManaged`in `is_stack_local`
/// kısayolu YÜZÜNDEN TAMAMEN ATLATIYORDU — `A(B(42))` gibi bir örnekte
/// `B(42)` (bir ALAN olarak `self.b`ye retain edilen, TAMAMEN NORMAL bir
/// `nox_rc_alloc`) HİÇBİR ZAMAN serbest bırakılmıyor, GERÇEK bir sızıntı
/// (VE bazı durumlarda çift-serbest-bırakma/Invalid free) üretiyordu. Bu,
/// `arena`/lowlevel yerelleri İçİn GÜVENLİ olan AYNI kısayolun BURADA
/// GÜVENSİZ olmasının nedenidir: bir `lowlevel:` bloğu İçİNDEKİ TÜM
/// alt-inşalar AYNI arenaya/stack'e GİDER (bkz. `checkNoLowlevelEscape`),
/// AMA GG.17'nin yalnızca EN DIŞTAKİ `var_decl`in KENDİ inşasını stack'e
/// alması, İÇ İÇE argüman ifadelerinin (`B(42)` GİBİ) TAMAMEN NORMAL ARC
/// yolunda KALMASI anlamına gelir. **Düzeltme**: v1'de bu optimizasyon
/// SADECE HİÇBİR alanı heap-yönetimli (list/dict/class/str/closure/
/// boxed_scalar) OLMAYAN sınıflara UYGULANIR — böyle bir sınıfın HİÇBİR
/// alanı release GEREKTİRMEDİĞİNDEN, tüm release'i atlamak GÜVENLİDİR.
fn classSafeForStackAlloc(cinfo: *const types.ClassInfo) bool {
    for (cinfo.fields.items) |f| {
        if (isHeapManaged(f.info.heap)) return false;
    }
    return true;
}

/// GG.17/GG.18'in PAYLAŞILAN sınıflandırma sonucu.
pub const Candidate = union(enum) {
    fixed_stack: usize,
    growable_arena,
};

/// TEK, SAF (HİÇBİR `newTemp`/`qbeAlloc`/tablo-yazma YAN ETKİSİ OLMAYAN,
/// deterministik) sınıflandırıcı — HEM whole-program ön-tarama
/// (`computeFuncsWithLocalConstructSites`, sadece SINIFLANDIRIR) HEM
/// GERÇEK kayıt (`registerLocalStackSlots`, SINIFLANDIRIP GERÇEKTEN
/// tahsis eder) TARAFINDAN çağrılır. ÖNCE Tur 1'i (sabit-boyutlu, basit-
/// literal, boyut tavanı İçİnde) dener; BAŞARISIZSA (boş `[]`, KARIŞIK/
/// literal-olmayan elemanlar, boyut AŞIMI, YA DA `.append()` KULLANIMI
/// yüzünden KATI kaçış-kontrolü başarısız olduysa) Tur 2'yi (SKALER
/// eleman tipi + `.append()`ye İZİN VEREN daha GEVŞEK kaçış-kontrolü)
/// dener.
pub fn classifyVarDecl(self: *Codegen, body: []const ast.Stmt, i: usize, v: ast.VarDecl) CodegenError!?Candidate {
    switch (v.value) {
        .list_lit => |elems| {
            if (simpleLiteralListQtype(elems)) |qt| {
                const size = LIST_HEADER_SIZE + qbeSizeOf(qt) * elems.len;
                if (size <= MAX_STACK_ALLOC_SIZE and localNeverEscapes(body, v.name, i + 1)) {
                    return .{ .fixed_stack = size };
                }
            }
            if (!try elemTypeIsScalar(self, v.type_expr)) return null;
            if (!localNeverEscapesGrowable(body, v.name, i + 1)) return null;
            return .growable_arena;
        },
        .call => |c| {
            if (c.callee.* != .identifier) return null;
            const cinfo = self.classes.get(c.callee.identifier) orelse return null;
            if (!classSafeForStackAlloc(&cinfo)) return null;
            if (cinfo.total_size > MAX_STACK_ALLOC_SIZE) return null;
            if (!localNeverEscapes(body, v.name, i + 1)) return null;
            return .{ .fixed_stack = cinfo.total_size };
        },
        else => return null,
    }
}

/// GG.18: `type_expr`nin (bir `var_decl`in TİP ANOTASYONU — `[]` gibi
/// KENDİ başına tipsiz bir literalin eleman tipini TAŞIMADIĞI durumlar
/// İçİn TEK kaynak) `list[T]` OLDUĞUNU VE `T`nin heap-yönetimli
/// OLMADIĞINI (int/float/bool) doğrular — bir liste heap-yönetimli
/// elemanlarla büyürse, arena'nın per-object free DESTEKLEMEMESİ
/// yüzünden o elemanların HİÇ release edilmemesi (Tur 1'in class-alan-
/// release hatasının AYNISı) riskini BAŞTAN eler.
fn elemTypeIsScalar(self: *Codegen, type_expr: ast.TypeExpr) CodegenError!bool {
    const info = try self.resolveType(type_expr);
    if (info.heap != .list) return false;
    return info.elem_heap_info == null and !info.elem_is_str;
}

/// `stmtsSafeForLocal`in TEK giriş noktası — `body[from_index..]`i
/// (bildirimden SONRAKİ TÜM deyimler, AYNI üst-düzey gövdede) tarar.
fn localNeverEscapes(body: []const ast.Stmt, name: []const u8, from_index: usize) bool {
    return stmtsSafeForLocal(body[from_index..], name);
}

/// GG.18: `localNeverEscapes`in AYNISI, AMA `stmtsSafeForGrowableLocal`ya
/// (aşağıda, `.append()`e İZİN VEREN) delege eder.
fn localNeverEscapesGrowable(body: []const ast.Stmt, name: []const u8, from_index: usize) bool {
    return stmtsSafeForGrowableLocal(body[from_index..], name);
}

/// `inlining.zig`'in `stmtsSafeForParam`iyle AYNI yapı/AYNI muhafazakârlık
/// (ŞÜPHEDE `false`) — SADECE `exprHasUnsafeLocalUse`ya (aşağıda, `.attribute`
/// salt-okunur okuma İçİn EK bir güvenli şekil TAŞIR) delege eder.
fn stmtsSafeForLocal(stmts: []const ast.Stmt, name: []const u8) bool {
    for (stmts) |stmt| {
        switch (stmt.kind) {
            .var_decl => |v| {
                if (std.mem.eql(u8, v.name, name)) return false;
                if (exprHasUnsafeLocalUse(v.value, name)) return false;
            },
            .assign => |a| {
                if (a.target == .identifier and std.mem.eql(u8, a.target.identifier, name)) return false;
                if (exprHasUnsafeLocalUse(a.target, name)) return false;
                if (exprHasUnsafeLocalUse(a.value, name)) return false;
            },
            .expr_stmt => |e| if (exprHasUnsafeLocalUse(e, name)) return false,
            .if_stmt => |f| {
                if (exprHasUnsafeLocalUse(f.cond, name)) return false;
                if (!stmtsSafeForLocal(f.then_body, name)) return false;
                for (f.elif_clauses) |ec| {
                    if (exprHasUnsafeLocalUse(ec.cond, name)) return false;
                    if (!stmtsSafeForLocal(ec.body, name)) return false;
                }
                if (f.else_body) |eb| if (!stmtsSafeForLocal(eb, name)) return false;
            },
            .while_stmt => |w| {
                if (exprHasUnsafeLocalUse(w.cond, name)) return false;
                if (!stmtsSafeForLocal(w.body, name)) return false;
            },
            .for_stmt => |f| {
                if (std.mem.eql(u8, f.var_name, name)) return false;
                const iterable_is_direct = f.iterable == .identifier and std.mem.eql(u8, f.iterable.identifier, name);
                if (!iterable_is_direct and exprHasUnsafeLocalUse(f.iterable, name)) return false;
                if (!stmtsSafeForLocal(f.body, name)) return false;
            },
            .return_stmt => |r| {
                if (r) |e| if (exprHasUnsafeLocalUse(e, name)) return false;
            },
            .raise_stmt => |e| if (exprHasUnsafeLocalUse(e, name)) return false,
            // `try`/İç İçe `lowlevel`/`with`/`func_def`/`defer` — BİLİNMEYEN/
            // riskli bölge, TÜM analiz GÜVENLİ tarafta kalmak İçin İPTAL edilir.
            .try_stmt, .lowlevel_stmt, .with_stmt, .func_def, .defer_stmt => return false,
            .pass_stmt, .class_def, .protocol_def, .extern_def, .import_stmt, .from_import_stmt => {},
        }
    }
    return true;
}

/// `inlining.zig`'in `exprHasUnsafeParamUse`iyle AYNI — İKİ FARK:
/// (1) `.attribute` (salt-okunur alan OKUMASI/YAZMASI, `name.field` YA DA
/// `name.field = ...`nin HEDEFİ) artık GÜVENLİDİR (in-place, stack payload'ı
/// İÇİNE yazan/okuyan bir işlem — YENİDEN tahsis GEREKTİRMEZ, `xs[i]=`nin
/// KENDİSİ zaten güvenli sayıldığı GİBİ);
/// (2) BUNUNLA BİRLİKTE bir METOD ÇAĞRISI (`name.method(...)`) — callee'nin
/// KENDİSİ bir `.attribute` OLDUĞUNDAN (1)'İN YENİ güvenli-şekli BUNU
/// yanlışlıkla İZİN VERİRDİ — `.call` dalında AÇIKÇA VE ÖNCELİKLE
/// YASAKLANIR (v1'de HER metod çağrısı kaçış sayılır, `.append()` GİBİ
/// BÜYÜYEBİLEN bir mutasyonun sabit-boyutlu bir stack slotunu TAŞIRMASINI
/// ÖNLEMEK İçİn — bu KIRMIZI ÇİZGİ, sadece bir basitleştirme DEĞİL).
fn exprHasUnsafeLocalUse(expr: ast.Expr, name: []const u8) bool {
    return switch (expr) {
        .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit => false,
        .identifier => |n| std.mem.eql(u8, n, name),
        .unary => |u| exprHasUnsafeLocalUse(u.operand.*, name),
        .binary => |b| exprHasUnsafeLocalUse(b.left.*, name) or exprHasUnsafeLocalUse(b.right.*, name),
        .call => |c| blk: {
            if (c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, "len") and
                c.args.len == 1 and c.args[0] == .identifier and std.mem.eql(u8, c.args[0].identifier, name))
            {
                break :blk false; // `len(name)` TEK BAŞINA GÜVENLİDİR.
            }
            // KIRMIZI ÇİZGİ: `name.method(...)` HER ZAMAN kaçış sayılır —
            // aşağıdaki `.attribute` dalının salt-okunur carve-out'undan
            // ÖNCE, açıkça kontrol edilir (v1'de interprocedural/metod-
            // gövdesi analizi YOK).
            if (c.callee.* == .attribute) {
                const recv = c.callee.attribute.obj;
                if (recv.* == .identifier and std.mem.eql(u8, recv.identifier, name)) break :blk true;
            }
            if (exprHasUnsafeLocalUse(c.callee.*, name)) break :blk true;
            for (c.args) |a| if (exprHasUnsafeLocalUse(a, name)) break :blk true;
            break :blk false;
        },
        .attribute => |a| blk: {
            // Salt-okunur (VEYA in-place yazılan, bkz. `.assign`in target
            // kontrolü) alan erişimi GÜVENLİDİR — metod-çağrısı receiver'ı
            // YUKARIDAKİ `.call` dalında AYRICA/ÖNCELİKLE ele alınır, BU
            // dala hiç ULAŞMAZ (`.call`in `c.callee.*` kontrolü BU `.attribute`
            // dalını hiç ÇAĞIRMAZ).
            if (a.obj.* == .identifier and std.mem.eql(u8, a.obj.identifier, name)) break :blk false;
            break :blk exprHasUnsafeLocalUse(a.obj.*, name);
        },
        .index => |idx| blk: {
            const obj_is_direct = idx.obj.* == .identifier and std.mem.eql(u8, idx.obj.identifier, name);
            if (!obj_is_direct and exprHasUnsafeLocalUse(idx.obj.*, name)) break :blk true;
            break :blk exprHasUnsafeLocalUse(idx.index.*, name);
        },
        .list_lit => |elems| blk: {
            for (elems) |el| if (exprHasUnsafeLocalUse(el, name)) break :blk true;
            break :blk false;
        },
        .dict_lit => |pairs| blk: {
            for (pairs) |p| {
                if (exprHasUnsafeLocalUse(p.key, name)) break :blk true;
                if (exprHasUnsafeLocalUse(p.value, name)) break :blk true;
            }
            break :blk false;
        },
        .await_expr => |op| exprHasUnsafeLocalUse(op.*, name),
        .spawn_expr => |op| exprHasUnsafeLocalUse(op.*, name),
        .generic_construct => |g| blk: {
            for (g.args) |a| if (exprHasUnsafeLocalUse(a, name)) break :blk true;
            break :blk false;
        },
    };
}

/// GG.18: `stmtsSafeForLocal`in BİREBİR AYNISI — SADECE `exprHasUnsafeGrowableLocalUse`ya
/// delege eder (`.append()`e İZİN VEREN EK carve-out İçİn).
fn stmtsSafeForGrowableLocal(stmts: []const ast.Stmt, name: []const u8) bool {
    for (stmts) |stmt| {
        switch (stmt.kind) {
            .var_decl => |v| {
                if (std.mem.eql(u8, v.name, name)) return false;
                if (exprHasUnsafeGrowableLocalUse(v.value, name)) return false;
            },
            .assign => |a| {
                if (a.target == .identifier and std.mem.eql(u8, a.target.identifier, name)) return false;
                if (exprHasUnsafeGrowableLocalUse(a.target, name)) return false;
                if (exprHasUnsafeGrowableLocalUse(a.value, name)) return false;
            },
            .expr_stmt => |e| if (exprHasUnsafeGrowableLocalUse(e, name)) return false,
            .if_stmt => |f| {
                if (exprHasUnsafeGrowableLocalUse(f.cond, name)) return false;
                if (!stmtsSafeForGrowableLocal(f.then_body, name)) return false;
                for (f.elif_clauses) |ec| {
                    if (exprHasUnsafeGrowableLocalUse(ec.cond, name)) return false;
                    if (!stmtsSafeForGrowableLocal(ec.body, name)) return false;
                }
                if (f.else_body) |eb| if (!stmtsSafeForGrowableLocal(eb, name)) return false;
            },
            .while_stmt => |w| {
                if (exprHasUnsafeGrowableLocalUse(w.cond, name)) return false;
                if (!stmtsSafeForGrowableLocal(w.body, name)) return false;
            },
            .for_stmt => |f| {
                if (std.mem.eql(u8, f.var_name, name)) return false;
                const iterable_is_direct = f.iterable == .identifier and std.mem.eql(u8, f.iterable.identifier, name);
                if (!iterable_is_direct and exprHasUnsafeGrowableLocalUse(f.iterable, name)) return false;
                if (!stmtsSafeForGrowableLocal(f.body, name)) return false;
            },
            .return_stmt => |r| {
                if (r) |e| if (exprHasUnsafeGrowableLocalUse(e, name)) return false;
            },
            .raise_stmt => |e| if (exprHasUnsafeGrowableLocalUse(e, name)) return false,
            .try_stmt, .lowlevel_stmt, .with_stmt, .func_def, .defer_stmt => return false,
            .pass_stmt, .class_def, .protocol_def, .extern_def, .import_stmt, .from_import_stmt => {},
        }
    }
    return true;
}

/// GG.18: `exprHasUnsafeLocalUse`in AYNISI, TEK FARKLA — `name.append(x)`
/// (TEK argümanla) HER ZAMAN kaçış SAYILAN metod-çağrısı KIRMIZI ÇİZGİSİNE
/// bir İSTİSNA: argümanın KENDİSİ NORMAL şekilde escape-kontrol edilir
/// (ör. `xs.append(xs)` GİBİ tuhaf/döngüsel bir durum YİNE yakalanır),
/// AMA `.append`in KENDİSİ artık İZİN VERİLİR. `.pop()`/`.sort()`/BAŞKA
/// HERHANGİ bir metod HÂLÂ YASAKTIR (v1 BİLİNÇLİ olarak SADECE `.append()`
/// destekler).
fn exprHasUnsafeGrowableLocalUse(expr: ast.Expr, name: []const u8) bool {
    return switch (expr) {
        .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit => false,
        .identifier => |n| std.mem.eql(u8, n, name),
        .unary => |u| exprHasUnsafeGrowableLocalUse(u.operand.*, name),
        .binary => |b| exprHasUnsafeGrowableLocalUse(b.left.*, name) or exprHasUnsafeGrowableLocalUse(b.right.*, name),
        .call => |c| blk: {
            if (c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, "len") and
                c.args.len == 1 and c.args[0] == .identifier and std.mem.eql(u8, c.args[0].identifier, name))
            {
                break :blk false;
            }
            if (c.callee.* == .attribute) {
                const recv = c.callee.attribute.obj;
                if (recv.* == .identifier and std.mem.eql(u8, recv.identifier, name)) {
                    if (std.mem.eql(u8, c.callee.attribute.attr, "append") and c.args.len == 1) {
                        break :blk exprHasUnsafeGrowableLocalUse(c.args[0], name);
                    }
                    break :blk true;
                }
            }
            if (exprHasUnsafeGrowableLocalUse(c.callee.*, name)) break :blk true;
            for (c.args) |a| if (exprHasUnsafeGrowableLocalUse(a, name)) break :blk true;
            break :blk false;
        },
        .attribute => |a| blk: {
            if (a.obj.* == .identifier and std.mem.eql(u8, a.obj.identifier, name)) break :blk false;
            break :blk exprHasUnsafeGrowableLocalUse(a.obj.*, name);
        },
        .index => |idx| blk: {
            const obj_is_direct = idx.obj.* == .identifier and std.mem.eql(u8, idx.obj.identifier, name);
            if (!obj_is_direct and exprHasUnsafeGrowableLocalUse(idx.obj.*, name)) break :blk true;
            break :blk exprHasUnsafeGrowableLocalUse(idx.index.*, name);
        },
        .list_lit => |elems| blk: {
            for (elems) |el| if (exprHasUnsafeGrowableLocalUse(el, name)) break :blk true;
            break :blk false;
        },
        .dict_lit => |pairs| blk: {
            for (pairs) |p| {
                if (exprHasUnsafeGrowableLocalUse(p.key, name)) break :blk true;
                if (exprHasUnsafeGrowableLocalUse(p.value, name)) break :blk true;
            }
            break :blk false;
        },
        .await_expr => |op| exprHasUnsafeGrowableLocalUse(op.*, name),
        .spawn_expr => |op| exprHasUnsafeGrowableLocalUse(op.*, name),
        .generic_construct => |g| blk: {
            for (g.args) |a| if (exprHasUnsafeGrowableLocalUse(a, name)) break :blk true;
            break :blk false;
        },
    };
}

/// `prepareInlineSites`in (inlining.zig) HER çağrı sitesinin YANINDA
/// (`registration.zig`/`closures.zig`, AYNI fonksiyon-girişi ön-tarama
/// noktasında) çağrılır. `body`nin ÜST DÜZEYİNDEKİ HER `var_decl`i
/// `classifyVarDecl` İLE sınıflandırır — `.fixed_stack(size)` DÖNERSE
/// `self.stack_construct_sites`e (GG.15/16 İLE PAYLAŞILAN tüketim
/// tablosu) bir `alloc8` slotu, `.growable_arena` DÖNERSE (GG.18)
/// `self.arena_local_construct_sites`e bir arena-tutamağı KAYDEDER
/// (fonksiyonun KENDİ `function_arena`sı, GEREKİYORSA BURADA İLK KEZ
/// `nox_arena_create` İLE yaratılır — birden fazla GG.18 yereli AYNI
/// arenayı PAYLAŞIR).
pub fn registerLocalStackSlots(self: *Codegen, body: []const ast.Stmt) CodegenError!void {
    self.stack_local_names.clearRetainingCapacity();
    self.growable_arena_names.clearRetainingCapacity();
    // GG.18: BİR ÖNCEKİ fonksiyondan kalan bir arena tutamağı, BURADA
    // sıfırlanmazsa, BU fonksiyonun (kendi `.growable_arena` yereli
    // OLMASA BİLE hâlâ null OLMAYAN eski değer yüzünden) YANLIŞLIKLA
    // "zaten bir arenam var" SANMASINA yol açardı — `stack_local_names`
    // İLE AYNI zamanlamada (HER fonksiyon-girişinde, TEK bu fonksiyon
    // ÜZERİNDEN) sıfırlanır.
    self.function_arena = null;
    for (body, 0..) |stmt, i| {
        if (stmt.kind != .var_decl) continue;
        const v = stmt.kind.var_decl;
        const candidate = try classifyVarDecl(self, body, i, v) orelse continue;
        switch (candidate) {
            .fixed_stack => |size| {
                const slot = try self.newTemp();
                try self.qbeAlloc(slot, .eight, size);
                const key: usize = switch (v.value) {
                    .list_lit => |elems| @intFromPtr(elems.ptr),
                    .call => |c| @intFromPtr(c.callee),
                    else => unreachable,
                };
                try self.stack_construct_sites.put(self.allocator, key, .{ .slot = slot });
                try self.stack_local_names.put(self.allocator, v.name, {});
            },
            .growable_arena => {
                if (self.function_arena == null) {
                    const arena_temp = try self.newTemp();
                    try self.qbeCall(.{ .name = arena_temp, .ty = .l }, "$nox_arena_create", &.{.{ .ty = .l, .text = types.RT_PARAM }});
                    self.function_arena = arena_temp;
                }
                // NOT: boş `[]` literalleri BURADA `arena_local_construct_
                // sites`e KAYDEDİLMEZ — Zig'İN sıfır-boyutlu tahsislerin
                // HEPSİNE AYNI (bir kanonik "boş") işaretçiyi verdiği
                // DOĞRUDAN DOĞRULANDI (`elems.ptr` TÜM boş listeler İçİn
                // AYNI OLURDU — GERÇEK bir çapraz-değişken çakışması).
                // `genEmptyListLit` bunun YERİNE `target.growable_arena`yı
                // (`VarInfo`den, `allocSlotEx` ÜZERİNDEN) DOĞRUDAN okur —
                // AST-düğüm anahtarlamaya HİÇ GEREK YOK (`target` ZATEN
                // BU SPESİFİK `var_decl`e AİT).
                if (v.value.list_lit.len > 0) {
                    const key: usize = @intFromPtr(v.value.list_lit.ptr);
                    try self.arena_local_construct_sites.put(self.allocator, key, self.function_arena.?);
                }
                try self.growable_arena_names.put(self.allocator, v.name, self.function_arena.?);
            },
        }
    }
}

/// GG.17 hotfix: whole-program ön-tarama — `computeInlinableFunctions`'DAN
/// ÖNCE (`codegen.zig`nin `generateModule`'ı, TEK çağrı sitesi) çağrılır.
/// `computeInlinableFunctions`nin AYNI iterasyon desenini (module.body'nin
/// üst-düzey `.func_def`leri + `extra_functions` — SADECE serbest
/// fonksiyonlar, METODLAR GG.2 TARAFINDAN ZATEN HİÇ inline EDİLMEDİĞİNDEN
/// bu taramaya DAHİL EDİLMEZ) TEKRARLAR, HER fonksiyonun gövdesini
/// `classifyVarDecl` İLE (SAF, `newTemp`/`qbeAlloc`/tablo-yazma YAN
/// ETKİSİ OLMADAN) tarar — EN AZ bir üst-düzey `var_decl` `null`-DIŞI
/// dönerse `fd.name`i `self.funcs_with_local_construct_sites`e EKLER
/// (`isFuncInlineEligible` BUNU KONTROL EDİP fonksiyonu inline-edilebilirlikten
/// DIŞLAR — bkz. bu dosyanın modül belge notu, "GG.17 hotfix").
pub fn computeFuncsWithLocalConstructSites(self: *Codegen, module: ast.Module, extra_functions: []const ast.FuncDef) CodegenError!void {
    for (module.body) |stmt| {
        switch (stmt.kind) {
            .func_def => |fd| try scanFuncForLocalConstructSites(self, fd),
            else => {},
        }
    }
    for (extra_functions) |fd| try scanFuncForLocalConstructSites(self, fd);
}

fn scanFuncForLocalConstructSites(self: *Codegen, fd: ast.FuncDef) CodegenError!void {
    for (fd.body, 0..) |stmt, i| {
        if (stmt.kind != .var_decl) continue;
        const v = stmt.kind.var_decl;
        if (try classifyVarDecl(self, fd.body, i, v)) |_| {
            try self.funcs_with_local_construct_sites.put(self.allocator, fd.name, {});
            return;
        }
    }
}
