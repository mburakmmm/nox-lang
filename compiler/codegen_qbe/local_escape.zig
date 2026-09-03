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
//! GG.19 (plan dosyası "ASAP güçlendirmesi — Tur 3"): İKİ EK madde.
//! (1) **Aggregate stack-promotion bütçesi**: `MAX_STACK_ALLOC_SIZE`
//! (nesne-başına) YETERSİZDİ — bir fonksiyonun TÜM stack-promotable
//! yerellerinin TOPLAMI da `MAX_PROMOTED_FRAME_SIZE`i (32 KiB) AŞAMAZ;
//! aşarsa (boyut/escape/basit-literal ŞARTLARI HÂLÂ geçse BİLE) aday
//! arenaya DÜŞER — `classifyVarDecl`nin `running_total: *usize` parametresi
//! BUNU sağlar. Sınıflar İçİn de (ÖNCEDEN SADECE `fixed_stack`/`null`
//! olabiliyordu) BİR arena-fallback EKLENDİ (`.call` dalı).
//! (2) **Inline + ASAP birlikte çalışabilir**: `stack_construct_sites`/
//! `arena_local_construct_sites`in inline-splice SIRASINDA ÇAPRAZ-
//! FONKSİYON çakışması artık `genInlinedCall`nin (inlining.zig) KENDİ
//! `self.vars` gölgeleme desenini TEKRARLAYAN bir üçüncü gölgeleme İLE
//! çözülüyor (bkz. `InlineConstructSite`/`materializeConstructSite`,
//! `inlining.zig`nin `registerInlineSite`/`genInlinedCall`ı) — bu YÜZDEN
//! GG.17/18 adayı İçEREN bir fonksiyonun GG.2 inline-edilebilirliğinden
//! TAMAMEN dışlanması (v1.42.0'ın hotfix'i) ARTIK GEREKMİYOR VE
//! KALDIRILDI.

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
const MAX_PROMOTED_FRAME_SIZE = inlining.MAX_PROMOTED_FRAME_SIZE;
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

/// GG.19: TEK, SAF (HİÇBİR `newTemp`/`qbeAlloc`/tablo-yazma YAN ETKİSİ
/// OLMAYAN, deterministik) sınıflandırıcı — HEM `registerLocalStackSlots`
/// (standalone-derlenen bir fonksiyonun KENDİ üst-düzey adayları) HEM
/// `registerInlineSite` (inlining.zig, İNLİNE edilen bir callee'nin
/// adayları) TARAFINDAN çağrılır. `running_total`, ÇAĞIRANIN (AYNI
/// fiziksel QBE fonksiyon çerçevesini PAYLAŞAN — bir caller'ın KENDİ
/// yerelleri VE İÇİNE splice edilen HER callee'nin yerelleri TEK bir
/// çerçevede TOPLANIR) o ana kadar stack'e SÖZ VERDİĞİ toplam bayt
/// sayısıdır — ÇAĞIRAN BUNU sıfırdan başlatıp HER başarılı `fixed_stack`
/// kararından SONRA artırır.
///
/// ÖNCE Tur 1'i (sabit-boyutlu, basit-literal/sınıf, nesne-başına VE
/// aggregate boyut tavanı İçİnde) dener; BAŞARISIZSA (boş `[]`, KARIŞIK/
/// literal-olmayan elemanlar, nesne-başına/aggregate boyut AŞIMI, YA DA
/// `.append()` KULLANIMI yüzünden KATI kaçış-kontrolü başarısız olduysa)
/// Tur 2'nin arena yolunu dener (liste İçİn: SKALER eleman tipi +
/// `.append()`ye İZİN VEREN daha GEVŞEK kaçış-kontrolü; sınıf İçİn:
/// AYNI KATI kaçış-kontrolü — sınıflar HİÇ büyümediğinden `.append()`
/// carve-out'una gerek YOK, SADECE boyut/bütçe aşımı YÜZÜNDEN stack
/// yerine arenaya düşer).
pub fn classifyVarDecl(self: *Codegen, body: []const ast.Stmt, i: usize, v: ast.VarDecl, running_total: *usize, class_params: []const inlining.ClassParam) CodegenError!?Candidate {
    switch (v.value) {
        .list_lit => |elems| {
            if (simpleLiteralListQtype(elems)) |qt| {
                const size = LIST_HEADER_SIZE + qbeSizeOf(qt) * elems.len;
                if (size <= MAX_STACK_ALLOC_SIZE and running_total.* + size <= MAX_PROMOTED_FRAME_SIZE and localNeverEscapes(self, body, v.name, i + 1, class_params)) {
                    running_total.* += size;
                    return .{ .fixed_stack = size };
                }
            }
            if (!try elemTypeIsScalar(self, v.type_expr)) return null;
            if (!localNeverEscapesGrowable(self, body, v.name, i + 1)) return null;
            return .growable_arena;
        },
        .call => |c| {
            if (c.callee.* != .identifier) return null;
            const cinfo = self.classes.get(c.callee.identifier) orelse return null;
            if (!classSafeForStackAlloc(&cinfo)) return null;
            if (!localNeverEscapes(self, body, v.name, i + 1, class_params)) return null;
            if (cinfo.total_size <= MAX_STACK_ALLOC_SIZE and running_total.* + cinfo.total_size <= MAX_PROMOTED_FRAME_SIZE) {
                running_total.* += cinfo.total_size;
                return .{ .fixed_stack = cinfo.total_size };
            }
            // GG.19: nesne-başına YA DA aggregate tavanı AŞAN (ama HÂLÂ
            // escape-güvenli/heap-yönetimli-alansız) bir sınıf örneği —
            // ÖNCEDEN (Tur 1/2) tek seçenek tam ARC'tı, ARTIK arenaya
            // düşer (arena fiber'ın KENDİ stack'ini KULLANMADIĞINDAN
            // boyut riski TAŞIMAZ).
            return .growable_arena;
        },
        else => return null,
    }
}

/// HH.3 (bkz. plan dosyası "`noxc explain` — derleyicinin ARC/stack/
/// arena tahsis kararlarını insan-okunur biçimde yüzeye çıkarma"):
/// `classifyVarDecl`nin İNSAN-OKUNUR "neden" karşılığı — `noxc explain`in
/// TEK veri kaynağı.
pub const ExplainVerdict = enum { stack, arena, arc };

pub const ExplainRecord = struct {
    line: usize,
    name: []const u8,
    verdict: ExplainVerdict,
    size: ?usize,
    reasons: []const []const u8,
    budget_before: usize,
    budget_after: usize,
};

/// `classifyVarDecl`i ÇAĞIRIR (OTORİTER/GERÇEK karar — SIFIR sapma
/// riski, BU fonksiyon `classifyVarDecl`in KENDİSİNE HİÇBİR DEĞİŞİKLİK
/// YAPMAZ) — SONRA, SADECE İNSAN-OKUNUR "neden" METNİ İçİn, AYNI
/// dosyadaki SAF/yan-etkisiz sub-predicate'leri (`simpleLiteralListQtype`/
/// `elemTypeIsScalar`/`localNeverEscapes`/`localNeverEscapesGrowable`/
/// `classSafeForStackAlloc`) TEKRAR çağırarak HANGİ adımın geçtiğini/
/// başarısız olduğunu BELİRLER — bu tekrar-çağrı SAF fonksiyonlar
/// ÜZERİNDE olduğundan (yan etki YOK) HERHANGİ bir risk TAŞIMAZ, SADECE
/// hesaplama tekrarı (ucuz, bir kerelik bir `explain` çağrısı İçİn
/// önemsiz).
pub fn explainVarDecl(self: *Codegen, allocator: std.mem.Allocator, body: []const ast.Stmt, i: usize, v: ast.VarDecl, running_total: *usize, class_params: []const inlining.ClassParam) CodegenError!ExplainRecord {
    const budget_before = running_total.*;
    var reasons: std.ArrayListUnmanaged([]const u8) = .empty;

    const candidate = try classifyVarDecl(self, body, i, v, running_total, class_params);

    switch (v.value) {
        .list_lit => |elems| {
            if (simpleLiteralListQtype(elems)) |qt| {
                const size = LIST_HEADER_SIZE + qbeSizeOf(qt) * elems.len;
                try reasons.append(allocator, try std.fmt.allocPrint(allocator, "sabit-boyutlu literal liste ({d} bayt)", .{size}));
                if (size > MAX_STACK_ALLOC_SIZE) {
                    try reasons.append(allocator, try std.fmt.allocPrint(allocator, "nesne-başına tavanı aşıyor ({d} > {d} bayt)", .{ size, MAX_STACK_ALLOC_SIZE }));
                } else if (budget_before + size > MAX_PROMOTED_FRAME_SIZE) {
                    try reasons.append(allocator, try std.fmt.allocPrint(allocator, "çerçeve bütçesini aşıyor ({d} + {d} > {d} bayt)", .{ budget_before, size, MAX_PROMOTED_FRAME_SIZE }));
                } else if (!localNeverEscapes(self, body, v.name, i + 1, class_params)) {
                    try reasons.append(allocator, "kaçıyor (yerel, bildirimden SONRA güvensiz bir şekilde kullanılıyor)");
                } else {
                    try reasons.append(allocator, "kaçmıyor, boyut/bütçe İçinde -> stack");
                }
            } else {
                try reasons.append(allocator, "literal olmayan/karışık elemanlı liste (basit-literal DEĞİL)");
            }
            if (candidate == null or candidate.? != .fixed_stack) {
                if (!(try elemTypeIsScalar(self, v.type_expr))) {
                    try reasons.append(allocator, "eleman tipi skaler değil (büyüyebilir-arena YALNIZCA int/float/bool eleman tipini destekler)");
                } else if (!localNeverEscapesGrowable(self, body, v.name, i + 1)) {
                    try reasons.append(allocator, "büyüyebilir-arena yolu İçİn de kaçıyor -> ARC");
                } else {
                    try reasons.append(allocator, "büyüyebilir-arena adayı (skaler eleman, .append() güvenli) -> arena");
                }
            }
        },
        .call => |c| {
            if (c.callee.* == .identifier) {
                if (self.classes.get(c.callee.identifier)) |cinfo| {
                    try reasons.append(allocator, try std.fmt.allocPrint(allocator, "sınıf kurucusu çağrısı ({s}, {d} bayt)", .{ c.callee.identifier, cinfo.total_size }));
                    if (!classSafeForStackAlloc(&cinfo)) {
                        try reasons.append(allocator, "heap-yönetimli (str/list/dict/class) bir alan İçeriyor -> stack/arena GÜVENLİ DEĞİL, ARC");
                    } else if (!localNeverEscapes(self, body, v.name, i + 1, class_params)) {
                        try reasons.append(allocator, "kaçıyor (yerel, bildirimden SONRA güvensiz bir şekilde kullanılıyor) -> ARC");
                    } else if (cinfo.total_size > MAX_STACK_ALLOC_SIZE) {
                        try reasons.append(allocator, try std.fmt.allocPrint(allocator, "nesne-başına tavanı aşıyor ({d} > {d} bayt) -> arena", .{ cinfo.total_size, MAX_STACK_ALLOC_SIZE }));
                    } else if (budget_before + cinfo.total_size > MAX_PROMOTED_FRAME_SIZE) {
                        try reasons.append(allocator, try std.fmt.allocPrint(allocator, "çerçeve bütçesini aşıyor ({d} + {d} > {d} bayt) -> arena", .{ budget_before, cinfo.total_size, MAX_PROMOTED_FRAME_SIZE }));
                    } else {
                        try reasons.append(allocator, "kaçmıyor, boyut/bütçe İçinde -> stack");
                    }
                } else {
                    try reasons.append(allocator, "bilinmeyen çağrı hedefi (sınıf kurucusu DEĞİL) -> ARC");
                }
            } else {
                try reasons.append(allocator, "doğrudan bir isim olmayan çağrı hedefi -> ARC");
            }
        },
        else => {
            try reasons.append(allocator, "yalnızca liste literalleri VE sınıf kurucu çağrıları stack/arena adayı olabilir -> ARC");
        },
    }

    const verdict: ExplainVerdict = if (candidate) |cand| switch (cand) {
        .fixed_stack => .stack,
        .growable_arena => .arena,
    } else .arc;
    const size: ?usize = if (candidate) |cand| switch (cand) {
        .fixed_stack => |s| s,
        .growable_arena => null,
    } else null;

    return .{
        .line = body[i].line,
        .name = v.name,
        .verdict = verdict,
        .size = size,
        .reasons = try reasons.toOwnedSlice(allocator),
        .budget_before = budget_before,
        .budget_after = running_total.*,
    };
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
fn localNeverEscapes(self: *const Codegen, body: []const ast.Stmt, name: []const u8, from_index: usize, class_params: []const inlining.ClassParam) bool {
    return stmtsSafeForLocal(self, body[from_index..], name, class_params);
}

/// GG.18: `localNeverEscapes`in AYNISI, AMA `stmtsSafeForGrowableLocal`ya
/// (aşağıda, `.append()`e İZİN VEREN) delege eder. GG.21'in `class_params`
/// carve-out'unu ALMAZ — bkz. `exprHasUnsafeGrowableLocalUse`nin belge notu
/// (arena değerleri HİÇBİR çağrı sınırını aşamaz, metod dahil).
fn localNeverEscapesGrowable(self: *const Codegen, body: []const ast.Stmt, name: []const u8, from_index: usize) bool {
    return stmtsSafeForGrowableLocal(self, body[from_index..], name);
}

/// `inlining.zig`'in `stmtsSafeForParam`iyle AYNI yapı/AYNI muhafazakârlık
/// (ŞÜPHEDE `false`) — SADECE `exprHasUnsafeLocalUse`ya (aşağıda, `.attribute`
/// salt-okunur okuma İçİn EK bir güvenli şekil TAŞIR) delege eder.
fn stmtsSafeForLocal(self: *const Codegen, stmts: []const ast.Stmt, name: []const u8, class_params: []const inlining.ClassParam) bool {
    for (stmts) |stmt| {
        switch (stmt.kind) {
            .var_decl => |v| {
                if (std.mem.eql(u8, v.name, name)) return false;
                if (exprHasUnsafeLocalUse(self, v.value, name, class_params)) return false;
            },
            .assign => |a| {
                if (a.target == .identifier and std.mem.eql(u8, a.target.identifier, name)) return false;
                if (exprHasUnsafeLocalUse(self, a.target, name, class_params)) return false;
                if (exprHasUnsafeLocalUse(self, a.value, name, class_params)) return false;
            },
            .expr_stmt => |e| if (exprHasUnsafeLocalUse(self, e, name, class_params)) return false,
            .if_stmt => |f| {
                if (exprHasUnsafeLocalUse(self, f.cond, name, class_params)) return false;
                if (!stmtsSafeForLocal(self, f.then_body, name, class_params)) return false;
                for (f.elif_clauses) |ec| {
                    if (exprHasUnsafeLocalUse(self, ec.cond, name, class_params)) return false;
                    if (!stmtsSafeForLocal(self, ec.body, name, class_params)) return false;
                }
                if (f.else_body) |eb| if (!stmtsSafeForLocal(self, eb, name, class_params)) return false;
            },
            .while_stmt => |w| {
                if (exprHasUnsafeLocalUse(self, w.cond, name, class_params)) return false;
                if (!stmtsSafeForLocal(self, w.body, name, class_params)) return false;
            },
            .for_stmt => |f| {
                if (std.mem.eql(u8, f.var_name, name)) return false;
                const iterable_is_direct = f.iterable == .identifier and std.mem.eql(u8, f.iterable.identifier, name);
                if (!iterable_is_direct and exprHasUnsafeLocalUse(self, f.iterable, name, class_params)) return false;
                if (!stmtsSafeForLocal(self, f.body, name, class_params)) return false;
            },
            .return_stmt => |r| {
                if (r) |e| if (exprHasUnsafeLocalUse(self, e, name, class_params)) return false;
            },
            .raise_stmt => |e| if (exprHasUnsafeLocalUse(self, e, name, class_params)) return false,
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
/// GG.20 (bkz. plan dosyası "ASAP güçlendirmesi — Tur 4"): `.call` dalı
/// ARTIK `self.escaping_params`e (`inlining.zig`nin `computeParamEscapes`i)
/// bakarak — argüman ÇÖZÜLEBİLİR bir SERBEST fonksiyona geçiyorsa VE
/// hedef parametre KANITLANMIŞ olarak KAÇMIYORSA — bunu GÜVENLİ sayar.
/// **`spawn` İSTİSNASI**: `inlining.zig`nin `exprHasUnsafeParamUse`iyle
/// AYNI kritik güvenlik notu — `.spawn_expr` dalı BU carve-out'u HİÇ
/// KULLANMAZ, spawn'ın SARDIĞI çağrının argümanları HER ZAMAN doğrudan
/// kontrol edilir (spawn'ın asenkron/çapraz-fiber doğası "callee kendi
/// gövdesinde kaçırmıyor" kanıtını GEÇERSİZ kılar).
fn exprHasUnsafeLocalUse(self: *const Codegen, expr: ast.Expr, name: []const u8, class_params: []const inlining.ClassParam) bool {
    return switch (expr) {
        .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit => false,
        .identifier => |n| std.mem.eql(u8, n, name),
        .unary => |u| exprHasUnsafeLocalUse(self, u.operand.*, name, class_params),
        .binary => |b| exprHasUnsafeLocalUse(self, b.left.*, name, class_params) or exprHasUnsafeLocalUse(self, b.right.*, name, class_params),
        .call => |c| blk: {
            if (c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, "len") and
                c.args.len == 1 and c.args[0] == .identifier and std.mem.eql(u8, c.args[0].identifier, name))
            {
                break :blk false; // `len(name)` TEK BAŞINA GÜVENLİDİR.
            }
            // KIRMIZI ÇİZGİ: `name.method(...)` HER ZAMAN kaçış sayılır —
            // aşağıdaki `.attribute` dalının salt-okunur carve-out'undan
            // ÖNCE, açıkça kontrol edilir (v1'de metod-gövdesi analizi YOK).
            if (c.callee.* == .attribute) {
                const recv = c.callee.attribute.obj;
                if (recv.* == .identifier and std.mem.eql(u8, recv.identifier, name)) break :blk true;
            }
            if (exprHasUnsafeLocalUse(self, c.callee.*, name, class_params)) break :blk true;
            const callee_is_resolvable_free_fn = c.callee.* == .identifier and self.func_defs.contains(c.callee.identifier);
            // GG.21: receiver `class_params`de bilinen bir sibling-parametreyse
            // VE metod PROVABLY final İSE, AYNI carve-out'u UYGULA (`self`
            // metodun KENDİ NodeKey indekslemesinde HER ZAMAN 0'DA olduğundan
            // `arg_idx` +1 KAYDIRILIR).
            var method_owner: ?[]const u8 = null;
            if (c.callee.* == .attribute) {
                const at = c.callee.attribute;
                if (inlining.resolveClassParamReceiver(at.obj.*, class_params)) |recv_class| {
                    if (self.classes.get(recv_class)) |cinfo| {
                        if (cinfo.methods.get(at.attr)) |msig| {
                            if (inlining.methodIsFinal(self, recv_class, at.attr)) {
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
                if (exprHasUnsafeLocalUse(self, a, name, class_params)) break :blk true;
            }
            break :blk false;
        },
        .attribute => |a| blk: {
            // Salt-okunur (VEYA in-place yazılan, bkz. `.assign`in target
            // kontrolü) alan erişimi GÜVENLİDİR — metod-çağrısı receiver'ı
            // YUKARIDAKİ `.call` dalında AYRICA/ÖNCELİKLE ele alınır, BU
            // dala hiç ULAŞMAZ (`.call`in `c.callee.*` kontrolü BU `.attribute`
            // dalını hiç ÇAĞIRMAZ).
            if (a.obj.* == .identifier and std.mem.eql(u8, a.obj.identifier, name)) break :blk false;
            break :blk exprHasUnsafeLocalUse(self, a.obj.*, name, class_params);
        },
        .index => |idx| blk: {
            const obj_is_direct = idx.obj.* == .identifier and std.mem.eql(u8, idx.obj.identifier, name);
            if (!obj_is_direct and exprHasUnsafeLocalUse(self, idx.obj.*, name, class_params)) break :blk true;
            break :blk exprHasUnsafeLocalUse(self, idx.index.*, name, class_params);
        },
        .list_lit => |elems| blk: {
            for (elems) |el| if (exprHasUnsafeLocalUse(self, el, name, class_params)) break :blk true;
            break :blk false;
        },
        .dict_lit => |pairs| blk: {
            for (pairs) |p| {
                if (exprHasUnsafeLocalUse(self, p.key, name, class_params)) break :blk true;
                if (exprHasUnsafeLocalUse(self, p.value, name, class_params)) break :blk true;
            }
            break :blk false;
        },
        .await_expr => |op| exprHasUnsafeLocalUse(self, op.*, name, class_params),
        .spawn_expr => |op| blk: {
            if (op.* == .call) {
                const c = op.*.call;
                if (exprHasUnsafeLocalUse(self, c.callee.*, name, class_params)) break :blk true;
                for (c.args) |a| {
                    if (a == .identifier and std.mem.eql(u8, a.identifier, name)) break :blk true;
                    if (exprHasUnsafeLocalUse(self, a, name, class_params)) break :blk true;
                }
                break :blk false;
            }
            break :blk exprHasUnsafeLocalUse(self, op.*, name, class_params);
        },
        .generic_construct => |g| blk: {
            for (g.args) |a| if (exprHasUnsafeLocalUse(self, a, name, class_params)) break :blk true;
            break :blk false;
        },
    };
}

/// GG.18: `stmtsSafeForLocal`in BİREBİR AYNISI — SADECE `exprHasUnsafeGrowableLocalUse`ya
/// delege eder (`.append()`e İZİN VEREN EK carve-out İçİn).
fn stmtsSafeForGrowableLocal(self: *const Codegen, stmts: []const ast.Stmt, name: []const u8) bool {
    for (stmts) |stmt| {
        switch (stmt.kind) {
            .var_decl => |v| {
                if (std.mem.eql(u8, v.name, name)) return false;
                if (exprHasUnsafeGrowableLocalUse(self, v.value, name)) return false;
            },
            .assign => |a| {
                if (a.target == .identifier and std.mem.eql(u8, a.target.identifier, name)) return false;
                if (exprHasUnsafeGrowableLocalUse(self, a.target, name)) return false;
                if (exprHasUnsafeGrowableLocalUse(self, a.value, name)) return false;
            },
            .expr_stmt => |e| if (exprHasUnsafeGrowableLocalUse(self, e, name)) return false,
            .if_stmt => |f| {
                if (exprHasUnsafeGrowableLocalUse(self, f.cond, name)) return false;
                if (!stmtsSafeForGrowableLocal(self, f.then_body, name)) return false;
                for (f.elif_clauses) |ec| {
                    if (exprHasUnsafeGrowableLocalUse(self, ec.cond, name)) return false;
                    if (!stmtsSafeForGrowableLocal(self, ec.body, name)) return false;
                }
                if (f.else_body) |eb| if (!stmtsSafeForGrowableLocal(self, eb, name)) return false;
            },
            .while_stmt => |w| {
                if (exprHasUnsafeGrowableLocalUse(self, w.cond, name)) return false;
                if (!stmtsSafeForGrowableLocal(self, w.body, name)) return false;
            },
            .for_stmt => |f| {
                if (std.mem.eql(u8, f.var_name, name)) return false;
                const iterable_is_direct = f.iterable == .identifier and std.mem.eql(u8, f.iterable.identifier, name);
                if (!iterable_is_direct and exprHasUnsafeGrowableLocalUse(self, f.iterable, name)) return false;
                if (!stmtsSafeForGrowableLocal(self, f.body, name)) return false;
            },
            .return_stmt => |r| {
                if (r) |e| if (exprHasUnsafeGrowableLocalUse(self, e, name)) return false;
            },
            .raise_stmt => |e| if (exprHasUnsafeGrowableLocalUse(self, e, name)) return false,
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
/// GG.20 (bkz. plan dosyası "ASAP güçlendirmesi — Tur 4"): **BİLİNÇLİ
/// olarak `exprHasUnsafeLocalUse`nin AYNI "İSPATLANMIŞ güvenli yönlendirme"
/// carve-out'unu KULLANMAZ** — GERÇEK, break→red→fix İLE bulunan bir
/// hata (`growable_arena_arg_escape.nox` fixture'ı, `checkNoLowlevelEscape`
/// TARAFINDAN `error.Unsupported` İLE YAKALANAN bir derleyici İÇİ hata,
/// TESTİ ÇÖKERTMEDEN ÖNCE) KANITLADI: bir arena-yönetimli değerin bir
/// ÇAĞRI SINIRINI (normal argüman-geçişi YOLUYLA) AŞMASI codegen'İN
/// HİÇBİR YERİNDE DESTEKLENMİYOR (`checkNoLowlevelEscape`nin `v.arena`
/// kontrolü BUNU AÇIKÇA YASAKLIYOR) — GG.16'nın `fixed_stack` mekanizmasının
/// AKSİNE (`cross_call_stack_slot.nox`nin ZATEN KANITLADIĞI GİBİ, sabit-
/// boyutlu bir stack slotu GÜVENLE bir çağrı sınırını AŞABİLİR), arena
/// değerleri İçİn BU YOL HİÇ AÇILMAMIŞTIR. Bu YÜZDEN argüman-olarak-geçiş
/// arena-adayları İçİn HÂLÂ (v1.42.0'dan BERİ olduğu GİBİ) KOŞULSUZ
/// kaçış SAYILIR.
fn exprHasUnsafeGrowableLocalUse(self: *const Codegen, expr: ast.Expr, name: []const u8) bool {
    return switch (expr) {
        .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit => false,
        .identifier => |n| std.mem.eql(u8, n, name),
        .unary => |u| exprHasUnsafeGrowableLocalUse(self, u.operand.*, name),
        .binary => |b| exprHasUnsafeGrowableLocalUse(self, b.left.*, name) or exprHasUnsafeGrowableLocalUse(self, b.right.*, name),
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
                        break :blk exprHasUnsafeGrowableLocalUse(self, c.args[0], name);
                    }
                    break :blk true;
                }
            }
            if (exprHasUnsafeGrowableLocalUse(self, c.callee.*, name)) break :blk true;
            for (c.args) |a| if (exprHasUnsafeGrowableLocalUse(self, a, name)) break :blk true;
            break :blk false;
        },
        .attribute => |a| blk: {
            if (a.obj.* == .identifier and std.mem.eql(u8, a.obj.identifier, name)) break :blk false;
            break :blk exprHasUnsafeGrowableLocalUse(self, a.obj.*, name);
        },
        .index => |idx| blk: {
            const obj_is_direct = idx.obj.* == .identifier and std.mem.eql(u8, idx.obj.identifier, name);
            if (!obj_is_direct and exprHasUnsafeGrowableLocalUse(self, idx.obj.*, name)) break :blk true;
            break :blk exprHasUnsafeGrowableLocalUse(self, idx.index.*, name);
        },
        .list_lit => |elems| blk: {
            for (elems) |el| if (exprHasUnsafeGrowableLocalUse(self, el, name)) break :blk true;
            break :blk false;
        },
        .dict_lit => |pairs| blk: {
            for (pairs) |p| {
                if (exprHasUnsafeGrowableLocalUse(self, p.key, name)) break :blk true;
                if (exprHasUnsafeGrowableLocalUse(self, p.value, name)) break :blk true;
            }
            break :blk false;
        },
        .await_expr => |op| exprHasUnsafeGrowableLocalUse(self, op.*, name),
        .spawn_expr => |op| blk: {
            if (op.* == .call) {
                const c = op.*.call;
                if (exprHasUnsafeGrowableLocalUse(self, c.callee.*, name)) break :blk true;
                for (c.args) |a| {
                    if (a == .identifier and std.mem.eql(u8, a.identifier, name)) break :blk true;
                    if (exprHasUnsafeGrowableLocalUse(self, a, name)) break :blk true;
                }
                break :blk false;
            }
            break :blk exprHasUnsafeGrowableLocalUse(self, op.*, name);
        },
        .generic_construct => |g| blk: {
            for (g.args) |a| if (exprHasUnsafeGrowableLocalUse(self, a, name)) break :blk true;
            break :blk false;
        },
    };
}

/// GG.19: `classifyVarDecl`nin DÖNDÜĞÜ SAF `Candidate` sonucunu GERÇEK
/// bir yaşayan tutamağa (stack slotu YA DA arena tutamağı) çevirir —
/// `registerLocalStackSlots` VE `registerInlineSite`nin (inlining.zig)
/// İKİSİ de bunu çağırır, TEK kaynak (emisyon mantığı İKİ YERDE
/// TEKRARLANMAZ). `.growable_arena` İçİn `self.function_arena`yı
/// (fonksiyon-çapında, GEREKİYORSA BURADA İLK KEZ yaratılan, PAYLAŞILAN
/// TEK arena — bir caller'ın KENDİ adayları VE İçİNE splice edilen HER
/// callee'nin adayları AYNI arenayı PAYLAŞIR, ÇÜNKÜ SONUÇTA AYNI fiziksel
/// fonksiyon çıkışında yıkılırlar) kullanır/yaratır.
pub fn materializeConstructSite(self: *Codegen, candidate: Candidate) CodegenError![]const u8 {
    return switch (candidate) {
        .fixed_stack => |size| blk: {
            const slot = try self.newTemp();
            try self.qbeAlloc(slot, .eight, size);
            break :blk slot;
        },
        .growable_arena => blk: {
            if (self.function_arena == null) {
                const arena_temp = try self.newTemp();
                try self.qbeCall(.{ .name = arena_temp, .ty = .l }, "$nox_arena_create", &.{.{ .ty = .l, .text = types.RT_PARAM }});
                self.function_arena = arena_temp;
            }
            break :blk self.function_arena.?;
        },
    };
}

/// `classifyVarDecl`nin `.list_lit`/`.call` dallarının KENDİ anahtarlama
/// deseni — `registerLocalStackSlots`/`registerInlineSite`nin İKİSİ de
/// `stack_construct_sites`/`arena_local_construct_sites`e (VEYA inline
/// İçİn `InlineConstructSite.node_key`e) YAZARKEN AYNI anahtarı ÜRETMESİ
/// GEREKİR (`genListLit`/`genConstructFromValues`nin TÜKETİM tarafı BU
/// anahtarla SORGULAR) — TEK kaynak, iki yerde birbirinden BAĞIMSIZ
/// yanlış yazılma riskini ELER.
pub fn constructNodeKey(v: ast.VarDecl) usize {
    return switch (v.value) {
        .list_lit => |elems| @intFromPtr(elems.ptr),
        .call => |c| @intFromPtr(c.callee),
        else => unreachable,
    };
}

/// `prepareInlineSites`in (inlining.zig) HER çağrı sitesinin YANINDA
/// (`registration.zig`/`closures.zig`, AYNI fonksiyon-girişi ön-tarama
/// noktasında) çağrılır. `body`nin ÜST DÜZEYİNDEKİ HER `var_decl`i
/// `classifyVarDecl` İLE sınıflandırır — `.fixed_stack(size)` DÖNERSE
/// `self.stack_construct_sites`e (GG.15/16 İLE PAYLAŞILAN tüketim
/// tablosu) bir `alloc8` slotu, `.growable_arena` DÖNERSE (GG.18)
/// `self.arena_local_construct_sites`e bir arena-tutamağı KAYDEDER.
pub fn registerLocalStackSlots(self: *Codegen, body: []const ast.Stmt, params: []const ast.Param) CodegenError!void {
    self.stack_local_names.clearRetainingCapacity();
    self.growable_arena_names.clearRetainingCapacity();
    // GG.18/19: BİR ÖNCEKİ fonksiyondan kalan bir arena tutamağı/aggregate
    // sayaç, BURADA sıfırlanmazsa YANLIŞ sonuçlara yol açardı — `stack_
    // local_names` İLE AYNI zamanlamada (HER fonksiyon-girişinde) sıfırlanır.
    self.function_arena = null;
    self.promoted_stack_total = 0;
    // GG.21 (bkz. plan dosyası "ASAP güçlendirmesi — Tur 5"): BU fonksiyonun
    // KENDİ `class`-tipli parametreleri — `obj.method(xs)` şeklindeki
    // metod-çağrısı receiver'larını (SADECE DOĞRUDAN sibling-parametre
    // şekli, bkz. `ClassParam`nin belge notu) çözebilmek İçİn.
    const class_params = try inlining.collectClassParams(self, self.allocator, params);
    for (body, 0..) |stmt, i| {
        if (stmt.kind != .var_decl) continue;
        const v = stmt.kind.var_decl;
        const candidate = try classifyVarDecl(self, body, i, v, &self.promoted_stack_total, class_params) orelse continue;
        const handle = try materializeConstructSite(self, candidate);
        switch (candidate) {
            .fixed_stack => {
                try self.stack_construct_sites.put(self.allocator, constructNodeKey(v), .{ .slot = handle });
                try self.stack_local_names.put(self.allocator, v.name, {});
            },
            .growable_arena => {
                // NOT: boş `[]` literalleri BURADA `arena_local_construct_
                // sites`e KAYDEDİLMEZ — Zig'İN sıfır-boyutlu tahsislerin
                // HEPSİNE AYNI (bir kanonik "boş") işaretçiyi verdiği
                // DOĞRUDAN DOĞRULANDI (`elems.ptr` TÜM boş listeler İçİn
                // AYNI OLURDU — GERÇEK bir çapraz-değişken çakışması).
                // `genEmptyListLit` bunun YERİNE `target.growable_arena`yı
                // (`VarInfo`den, `allocSlotEx` ÜZERİNDEN) DOĞRUDAN okur —
                // AST-düğüm anahtarlamaya HİÇ GEREK YOK (`target` ZATEN
                // BU SPESİFİK `var_decl`e AİT). Sınıf kurucusu YOLUNDA
                // (GG.19'un YENİ arena-fallback'i) BU sorun YOK — `c.callee`
                // HER ZAMAN benzersizdir, KOŞULSUZ kaydedilir.
                const is_empty_list = v.value == .list_lit and v.value.list_lit.len == 0;
                if (!is_empty_list) {
                    try self.arena_local_construct_sites.put(self.allocator, constructNodeKey(v), handle);
                }
                try self.growable_arena_names.put(self.allocator, v.name, handle);
            },
        }
    }
}
