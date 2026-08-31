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

/// `prepareInlineSites`in (inlining.zig) HER çağrı sitesinin YANINDA
/// (`registration.zig`/`closures.zig`, AYNI fonksiyon-girişi ön-tarama
/// noktasında) çağrılır. `body`nin ÜST DÜZEYİNDEKİ HER `var_decl`i, bir
/// sınıf-kurucusu/basit-literal-liste OLUP OLMADIĞINI VE gerisinde (AYNI
/// gövde İçİnde, `i+1`den İTİBAREN) HİÇ kaçmadığını kontrol eder — İKİSİ
/// de doğruysa `self.stack_construct_sites`e (GG.15/16 İLE PAYLAŞILAN
/// tüketim tablosu — `genListLit`/`genConstructFromValues` ZATEN bunu
/// ÖNCELİKLE kontrol ediyor, TÜKETİM tarafına SIFIR değişiklik gerekir)
/// bir slot kaydeder VE `self.stack_local_names`e ismi ekler (`allocSlotEx`
/// BUNU `VarInfo.is_stack_local`e AKTARIR).
pub fn registerLocalStackSlots(self: *Codegen, body: []const ast.Stmt) CodegenError!void {
    self.stack_local_names.clearRetainingCapacity();
    for (body, 0..) |stmt, i| {
        if (stmt.kind != .var_decl) continue;
        const v = stmt.kind.var_decl;
        const size: ?usize = switch (v.value) {
            .list_lit => |elems| blk: {
                const qt = simpleLiteralListQtype(elems) orelse break :blk null;
                break :blk LIST_HEADER_SIZE + qbeSizeOf(qt) * elems.len;
            },
            .call => |c| blk: {
                if (c.callee.* != .identifier) break :blk null;
                const cinfo = self.classes.get(c.callee.identifier) orelse break :blk null;
                if (!classSafeForStackAlloc(&cinfo)) break :blk null;
                break :blk cinfo.total_size;
            },
            else => null,
        };
        const s = size orelse continue;
        if (s > MAX_STACK_ALLOC_SIZE) continue;
        if (!localNeverEscapes(body, v.name, i + 1)) continue;
        const slot = try self.newTemp();
        try self.qbeAlloc(slot, .eight, s);
        const key: usize = switch (v.value) {
            .list_lit => |elems| @intFromPtr(elems.ptr),
            .call => |c| @intFromPtr(c.callee),
            else => unreachable,
        };
        try self.stack_construct_sites.put(self.allocator, key, .{ .slot = slot });
        try self.stack_local_names.put(self.allocator, v.name, {});
    }
}

/// `stmtsSafeForLocal`in TEK giriş noktası — `body[from_index..]`i
/// (bildirimden SONRAKİ TÜM deyimler, AYNI üst-düzey gövdede) tarar.
fn localNeverEscapes(body: []const ast.Stmt, name: []const u8, from_index: usize) bool {
    return stmtsSafeForLocal(body[from_index..], name);
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
