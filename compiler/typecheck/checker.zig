//! Nox zorunlu statik tip denetleyicisi (AGENTS.md §5, §7 adım 2).
//!
//! İki geçişli çalışır: (1) modül düzeyindeki tüm fonksiyon/sınıf imzaları
//! ileri-referansları destekleyecek şekilde önceden kaydedilir, (2) gövdeler
//! bu imzalar ışığında denetlenir. Sınıf alanları (`self.<ad>`) yalnızca
//! `__init__` içindeki ilk atamada tipiyle birlikte örtük olarak tanımlanır;
//! bu yalnızca alan *tipinin* çıkarımıdır, AGENTS.md İlke #1'in yasakladığı
//! bir ownership/mutability sözdizimiyle karıştırılmamalıdır.
//!
//! Kapsam notu: kaynak konumu DEYİM (statement) granülerliğinde izlenir
//! (Faz T.1, bkz. `current_line`/`ast.Stmt.line`) — İFADE (expression)
//! düzeyi hassasiyet HENÜZ yok (bkz. nox-teknik-spesifikasyon.md §3.15).
//!
//! **Faz T.2 — çoklu-tanılama/hata kurtarma:** `fail()` HÂLÂ tek bir
//! Zig hatası FIRLATIR (kontrol akışını KESER), ama `checkModule`nin
//! ÜST-DÜZEY döngüsü (HER fonksiyon/sınıf/gevşek deyim İÇİN) VE
//! `checkClassBody`nin metod döngüsü bunu YAKALAYIP `self.diagnostics`e
//! KAYDEDER, SONRA bir SONRAKİ bağımsız birime DEVAM EDER — bu, TEK bir
//! `noxc build` çalıştırmasında BİRDEN ÇOK (farklı fonksiyon/sınıf/metoddaki)
//! hatanın RAPORLANMASINI sağlar. **Bilinçli sınırlama:** kurtarma yalnızca
//! bu İRİ granülerlikte (fonksiyon/metod/gevşek-deyim SINIRINDA) — AYNI
//! fonksiyon/metod İÇİNDEKİ İKİNCİ bir hata HÂLÂ raporlanMAZ (o birimin
//! KENDİ denetimi İLK hatada durur); ayrıca bir üst-düzey `var_decl`
//! BAŞARISIZ olursa o isim kapsama HİÇ girmez, bu yüzden SONRAKİ bir
//! deyimin AYNI ismi kullanması İKİNCİL (cascading) bir "tanımsız değişken"
//! hatası üretebilir — bu, İYİ bilinen bir hata-kurtarma ödünleşimidir,
//! v1 kapsamında KABUL EDİLİR.
//!
//! **Faz 10 — generics (compile-time monomorphization):** bkz. bu dosyanın
//! altındaki "Faz 10: generics" bölümü ve nox-teknik-spesifikasyon.md §3.10.
//! Yalnızca serbest fonksiyonlar; tip parametreleri yalnızca argüman
//! tiplerinden çıkarılır.
//!
//! **Faz 11 — yapısal protokoller:** bir parametre/dönüş tipi bir
//! `protocol_def` adına başvuran bir fonksiyon, açık `[T]` sözdizimi hiç
//! kullanılmasa bile Faz 10'un generic altyapısına yönlendirilir — protokol
//! adı, çağrı sitesinde somut bir sınıfa çözümlenmesi gereken ÖRTÜK bir tip
//! parametresi gibi davranır (bkz. `computeEffectiveTypeParams`), ama ek
//! olarak `satisfiesProtocol` ile YAPISAL eşleşme (implements sözdizimi
//! YOK) doğrulanır. Heterojen (fat-pointer/vtable) fallback henüz yok —
//! bkz. nox-teknik-spesifikasyon.md §3.11.

const std = @import("std");
const ast = @import("../parser/ast.zig");
const types = @import("types.zig");
const Type = types.Type;
const span_mod = @import("../span.zig");
const Span = span_mod.Span;
const effect_graph = @import("../effect_graph.zig");

pub const TypeError = error{
    TypeMismatch,
    UndefinedVariable,
    UndefinedFunction,
    UndefinedClass,
    UndefinedAttribute,
    UndefinedMethod,
    ArgumentCountMismatch,
    NotIterable,
    NotCallable,
    UnknownType,
    DuplicateDefinition,
    MissingReturn,
    /// Faz FF.5 (bkz. nox-teknik-spesifikasyon.md §3.64): AÇIKÇA bildirilen
    /// bir sınıf alanı, `__init__` gövdesinde HİÇ `self.<ad> = ...` İLE
    /// atanmadı — `TypeMismatch`/`UndefinedAttribute`e AŞIRI YÜKLEMEK
    /// YERİNE ayrı, grep-lenebilir bir tanı kodu.
    UnassignedField,
    /// Faz FF.6 (bkz. nox-teknik-spesifikasyon.md §3.65): daraltılmamış
    /// (`if x != None:` gibi TANINAN bir örüntüyle henüz elenmemiş) bir
    /// `T | None` değerine alan/metod/index erişimi — `TypeMismatch`e
    /// AŞIRI YÜKLEMEK yerine ayrı, grep-lenebilir bir tanı kodu (FF.5'in
    /// `UnassignedField`iyle AYNI gerekçe).
    OptionalNotNarrowed,
    /// v1.30.0 (bkz. nox-teknik-spesifikasyon.md §3.95): bir `spawn` HEDEFİ
    /// fonksiyonun `list`/`dict`/`class` tipli bir parametresi kendi
    /// gövdesinde mutasyona uğratıldı — `TypeMismatch`e AŞIRI YÜKLEMEK
    /// yerine ayrı, grep-lenebilir bir tanı kodu (`UnassignedField`/
    /// `OptionalNotNarrowed` İLE AYNI gerekçe).
    SpawnSharedMutation,
    /// v1.30.1 (bkz. nox-teknik-spesifikasyon.md §3.96): `checkExpr`in canlı
    /// özyineleme derinliği `MAX_EXPR_DEPTH`i aştı (parser'ın
    /// `RecursionLimitExceeded`iyle AYNI ilke, checker tarafı İçİn).
    TooDeeplyNested,
    OutOfMemory,
};

/// Faz T.2: `recordDiagnostic` tarafından `Checker.diagnostics`e eklenen tek
/// bir kurtarılmış (recovered) tanılama — `message` ZATEN `fail()`in "satır
/// N: " önekini taşır (bkz. `current_line`), `line` AYRICA yapısal erişim
/// İÇİN saklanır.
pub const Diagnostic = struct {
    code: TypeError,
    line: u32,
    message: []const u8,
    /// Gerçek span sistemi (bkz. plan dosyası "Gerçek span sistemi +
    /// yapılandırılmış tanılamalar") — SAF ekleme: `line`/`message`nin
    /// DAVRANIŞI/BİÇİMİ DEĞİŞMEZ (70+ mevcut `tests/golden/typecheck_cases/
    /// *.expected` fixture'ı bu YÜZDEN DEĞİŞMEDEN geçer). Normalde DEYİM-
    /// seviyesinde (`current_span`, `stmt.span`dan), ama `checkArgs`nin
    /// TİP UYUŞMAZLIĞI dalında (bkz. onun belge notu) TEK BİR argümanın
    /// DAHA DAR span'ına GEÇİCİ olarak daraltılabilir.
    span: Span = .{},
};

const FuncSig = struct {
    params: []const Type,
    return_type: Type,
};

/// Faz 1 decorator: `Checker.decorated_functions`in ELEMANI (bkz. onun
/// belge notu). `args`, decorator'ın string-literal argümanlarının ÇÖZÜLMÜŞ
/// (tırnaksız/kaçışsız) DEĞERLERİDİR — `ast.Decorator.args`nin HAM `Expr`
/// AĞACI DEĞİL.
pub const DecoratedFuncInfo = struct {
    /// `registerFunc`e ULAŞTIĞI ANDAKİ `fd.name` — üst-düzey fonksiyonlar
    /// İçin bu ZATEN codegen sembolüyle (VE `functions_used_as_value`nin
    /// anahtarıyla) BİREBİR AYNIDIR (ithal edilen paket modüllerinde
    /// `module_loader.zig` TARAFINDAN ÖNCEDEN mangle edilmiş olabilir).
    func_name: []const u8,
    decorator_name: []const u8,
    args: []const []const u8,
    /// `true` İSE fonksiyonun imzası TAM OLARAK `(ctx: Context) ->
    /// HttpResponse`dir — `nox.reflect.decorator_handler(i)` bu durumda
    /// çağrılabilir bir DEĞER döner (bkz. `functions_used_as_value`e
    /// otomatik eklenmesi), aksi halde `None` döner.
    is_handler_shaped: bool,
};

const ClassInfo = struct {
    /// Faz 7 (tekli kalıtım): `class Derived(Base):` — `ast.ClassDef.base`nin
    /// AYNISI, `registerClassSignatures` tarafından KOPYALANIR. `fields`/
    /// `methods`/`init_sig` HER ZAMAN ZATEN DÜZLEŞTİRİLMİŞTİR (tabanın
    /// KENDİ tabanı DAHİL TÜM ataları BURAYA KOPYALANMIŞTIR) — bu alan
    /// SADECE `isSubclassOf`/`super()` çözümlemesi İçin taşınır, alan/metod
    /// ARAMALARI HİÇBİR YERDE bu zinciri KENDİLERİ YÜRÜMEZ (bkz. Faz 7
    /// tasarım notu: "en az invaziv strateji" — kayıt-zamanında düzleştirme).
    base: ?[]const u8 = null,
    fields: std.StringHashMapUnmanaged(Type) = .{},
    methods: std.StringHashMapUnmanaged(FuncSig) = .{},
    /// GG.21 (bkz. plan dosyası "ASAP güçlendirmesi — Tur 5"): `methods`
    /// İLE PARALEL doldurulur — HER metod adı İçİn O metodun GÖVDESİNİ
    /// GERÇEKTEN TAŞIYAN sınıfın adı (KENDİSİ — YENİ bir metod YA DA bir
    /// override — YA DA bir atası, override EDİLMEMİŞSE). `computeMutatesGraph`nin
    /// metod-çağrısı `NodeKey`ini (`"{owner}_{metod}"`) VE `methodIsFinal`in
    /// override-tespitini besler — codegen'in ZATEN VAR OLAN `ClassMethodInfo.
    /// owner`ıyla AYNI KAVRAM, checker tarafında EKSİKTİ.
    method_owners: std.StringHashMapUnmanaged([]const u8) = .{},
    init_sig: ?FuncSig = null,
    /// Faz FF.5 (bkz. nox-teknik-spesifikasyon.md §3.64): AÇIKÇA bildirilen
    /// (`ast.FieldDecl`) ama HENÜZ `__init__` içinde `self.<ad> = ...` İLE
    /// ATANMAMIŞ alan adları — `registerClassSignatures` `cd.fields`den
    /// doldurur, `checkAssign`in `.attribute` dalı HER atamada İLGİLİ adı
    /// SİLER (bkz. onun belge notu); `checkClassBody`, `__init__`
    /// denetiminden HEMEN SONRA burada KALAN varsa `UnassignedField` İLE
    /// reddeder — bildirilen bir alanın HİÇ atanmadan (ör. heap-tipli İSE
    /// sallanan/null bir işaretçi OLARAK) kalmasını ÖNLER.
    declared_unassigned: std.StringHashMapUnmanaged(void) = .{},
};

/// Bir yapısal protokolün (Faz 11) gerektirdiği tek bir metod imzası —
/// `self` hariç parametre tipleri + dönüş tipi.
const ProtocolMethod = struct {
    name: []const u8,
    params: []const Type,
    return_type: Type,
};

const ProtocolInfo = struct {
    methods: []const ProtocolMethod,
};

const Scope = struct {
    vars: std.StringHashMapUnmanaged(Type) = .{},
    /// Faz U.4.2: yalnızca bir İÇ İÇE `def`in KENDİ scope'unda NON-null —
    /// dış (kapsayan) fonksiyonun scope'una işaret eder. Üst-düzey bir
    /// fonksiyonun/metodun scope'unda HER ZAMAN `null`dır.
    parent: ?*Scope = null,
    /// Faz U.4.2: yalnızca bir İÇ İÇE `def`in KENDİ scope'unda NON-null —
    /// `lookup`un `parent` zincirine düşerek çözdüğü HER isim (bir "serbest
    /// değişken"/capture) burada (isim → tip) KAYDEDİLİR (bkz. `checkStmt`in
    /// `.func_def` dalı, `checkNestedFuncDef`).
    captures: ?*std.StringHashMapUnmanaged(Type) = null,

    fn declare(self: *Scope, allocator: std.mem.Allocator, name: []const u8, ty: Type) !void {
        try self.vars.put(allocator, name, ty);
    }

    /// YALNIZCA bu scope'un KENDİ değişkenlerine bakar — `parent` zincirine
    /// DÜŞMEZ (bkz. `checkAssign`in `.identifier` dalı, "yakalanan bir
    /// değişkene ATAMA denemesi" ayrımı İÇİN kullanılır).
    fn lookupLocal(self: *Scope, name: []const u8) ?Type {
        return self.vars.get(name);
    }

    /// KENDİ değişkenlerinde bulunamazsa `parent` zincirine DÜŞER — bulunursa
    /// VE `self.captures` AYARLIYSA bu ismi (İLK karşılaşmada) bir "serbest
    /// değişken" (capture) olarak KAYDEDER.
    fn lookup(self: *Scope, allocator: std.mem.Allocator, name: []const u8) !?Type {
        if (self.vars.get(name)) |t| return t;
        if (self.parent) |p| {
            if (try p.lookup(allocator, name)) |t| {
                if (self.captures) |caps| {
                    if (!caps.contains(name)) try caps.put(allocator, name, t);
                }
                return t;
            }
        }
        return null;
    }

    /// `lookup`la AYNI zincir, ama HİÇBİR yan etkisi (capture kaydı) YOK —
    /// yalnızca "bu isim BULUNABİLİR Mİ" sorusuna yanıt verir (bkz.
    /// `checkAssign`in `.identifier` dalı, "yakalanan bir değişkene ATAMA
    /// denemesi" İÇİN daha İYİ bir hata mesajı ÜRETMEK amacıyla kullanılır).
    fn existsInChain(self: *Scope, name: []const u8) bool {
        if (self.vars.contains(name)) return true;
        if (self.parent) |p| return p.existsInChain(name);
        return false;
    }
};

/// Faz U.4.2: bir İÇ İÇE `def`in YAKALADIĞI TEK bir dış değişken (isim + tip).
pub const CaptureVar = struct { name: []const u8, ty: Type };

/// Faz U.4.2: bir İÇ İÇE `def`in TAM yakalama listesi — `Checker.closure_infos`da
/// (anahtar: `"<dış_yol>.<iç_isim>"`, bkz. `FnCtx.path`in belge notu) saklanır,
/// U.4.3'ün codegen'i TARAFINDAN (closure heap bloğunun İNŞASI İÇİN)
/// TÜKETİLECEKTİR.
pub const ClosureInfo = struct { captures: []const CaptureVar };

/// Bir fonksiyon/metod gövdesi denetlenirken taşınan bağlam.
const FnCtx = struct {
    scope: *Scope,
    /// `null`: modül-seviyesi gevşek deyimler (fonksiyon dışı) — `return` burada geçersizdir.
    expected_return: ?Type,
    /// İçinde bulunulan sınıfın adı (yalnızca metod gövdelerinde dolu).
    self_class: ?[]const u8 = null,
    /// `__init__` içindeyken `self.<alan> = ...` yeni bir alan tanımlayabilir.
    is_init: bool = false,
    /// `true`: bir `async def` gövdesi içindeyiz — `await` yalnızca burada
    /// geçerlidir (bkz. nox-teknik-spesifikasyon.md §3.21).
    in_async: bool = false,
    /// Faz U.4.2: şu an denetlenen fonksiyonun/metodun/İÇ İÇE `def`in
    /// "yolu" (üst-düzey İÇİN yalnızca kendi adı, iç içe İÇİN
    /// `"<dış_yol>.<iç_isim>"`) — `Checker.closure_infos`ın anahtarı olarak
    /// kullanılır (bkz. `checkNestedFuncDef`).
    path: []const u8 = "",
    /// Faz FF.6 (bkz. nox-teknik-spesifikasyon.md §3.65): `checkStmt`in
    /// `.if_stmt`/`.while_stmt` dallarının `detectNarrowing` İLE açtığı
    /// GEÇİCİ "bu isim şu an daraltılmış" örtüsü — `ctx.scope.vars`ı
    /// DOĞRUDAN MUTATE ETMEK YERİNE (bu, o ismin GERÇEK/bildirilen tipini
    /// KAYBEDERDİ — `checkAssign`in "yeni değer eski bildirilen tiple
    /// UYUŞUYOR MU" kontrolü İÇİN o GERÇEK tipe İHTİYACI VARDIR, ör. `cur
    /// = cur.next` — `cur` GÖVDE İÇİNDE `Node`e daraltılmışken BİLE bu
    /// atamanın SAĞ TARAFI `Node | None`dir VE bu GEÇERLİ bir atamadır)
    /// AYRI bir örtü katmanıdır: `checkExpr`in `.identifier` dalı ÖNCE
    /// buraya, SONRA `ctx.scope`a bakar; `checkAssign`in `.identifier`
    /// dalı BAŞARILI bir atamadan SONRA ismi buradan SİLER (yeniden atanan
    /// bir değişkenin daraltma DURUMU artık GEÇERSİZDİR — GÜVENLİ/tutucu
    /// tercih, TypeScript'in "reassignment invalidates narrowing"ıyla
    /// AYNI gerekçe).
    narrowed: std.StringHashMapUnmanaged(Type) = .{},
};

pub const Checker = struct {
    allocator: std.mem.Allocator,
    functions: std.StringHashMapUnmanaged(FuncSig) = .{},
    classes: std.StringHashMapUnmanaged(ClassInfo) = .{},
    diagnostic: ?[]const u8 = null,
    /// Faz T.1: `fail`in tanılama mesajına EKLEDİĞİ "şu an hangi DEYİMİ
    /// işliyoruz" satır numarası (1-tabanlı, bkz. `ast.Stmt.line`) — DEYİM
    /// granülerliğinde (bkz. `ast.Stmt`in belge notu), bir DEYİM İÇİNDEKİ
    /// bir ALT ifadede oluşan hata O DEYİMİN satırını raporlar.
    /// `checkStmt`in HER çağrısında güncellenir (TEK dağıtım noktası); ayrıca
    /// `checkStmt`e HİÇ girmeyen üst-düzey geçişlerin (`collectClassNames`/
    /// `registerSignatures`/`collectProtocols`) KENDİ döngülerinde de
    /// AYRICA güncellenir.
    current_line: u32 = 0,
    /// Bkz. `Diagnostic.span`nin belge notu — `current_line` İLE AYNI
    /// yerlerde, `stmt.span`dan doldurulur.
    current_span: Span = .{},
    /// `checkModule` BAŞINDA `module.expr_spans`ten (bkz. `ast.Module`nin
    /// belge notu) BİR KEZ doldurulur — `checkArgs`nin argüman-uyuşmazlığı
    /// dalı, TEK bir argümanın DAHA DAR span'ını BURADAN arar (bkz. onun
    /// belge notu).
    module_expr_spans: std.AutoHashMapUnmanaged(usize, Span) = .empty,
    /// `defer` deyimleri İçin BENZERSİZ sentetik closure adları üretmek
    /// İçin bir sayaç (bkz. `checkDeferStmt`in belge notu).
    defer_counter: usize = 0,
    /// `checkDeferStmt`in ÜRETTİĞİ sentetik closure adı — anahtar
    /// `@intFromPtr(d.call.callee)` (bkz. `ast.DeferStmt`nin belge notu,
    /// `registerInlineSite`nin AYNI pointer-kimliği deseni). Codegen
    /// (`genDeferStmt`) AYNI anahtarla BURAYA bakar.
    defer_synthetic_names: std.AutoHashMapUnmanaged(usize, []const u8) = .{},
    /// Generic (`type_params.len > 0`) serbest fonksiyonlar — ham AST'leri,
    /// somut bir çağrı sitesiyle karşılaşılana kadar burada beklerler (bkz.
    /// Faz 10, `instantiateGeneric`). Gövdeleri normal geçişte DENETLENMEZ.
    generic_functions: std.StringHashMapUnmanaged(ast.FuncDef) = .{},
    /// `async def` olarak tanımlanmış serbest fonksiyon adları — yalnızca
    /// bunlar `spawn` ile başlatılabilir (bkz. `checkExpr`in `.spawn_expr`
    /// dalı, nox-teknik-spesifikasyon.md §3.21).
    async_functions: std.StringHashMapUnmanaged(void) = .{},
    /// v1.30.0: `spawn f(...)` İLE HERHANGİ bir yerde HEDEF alınan TÜM
    /// üst-düzey `async def` fonksiyon adlarının kümesi — `checkModule`nin
    /// diğer pre-pass'larıyla AYNI aşamada, `checkFunctionBody` HERHANGİ
    /// bir fonksiyonu denetlemeden ÖNCE (`collectSpawnTargets`) doldurulur
    /// (METİNSEL sıradan BAĞIMSIZ olması İÇİN). `checkFunctionBody`
    /// bunu kullanarak `list`/`dict`/`class` tipli parametrelerin
    /// spawn-hedefi fonksiyonun KENDİ gövdesinde mutasyona
    /// uğratılmadığını doğrular (bkz. `checkNoSpawnSharedMutation`) —
    /// çalışma zamanında senkronizasyonsuz cross-worker mutasyon
    /// riskine karşı derleme-zamanı reddi.
    spawn_target_functions: std.StringHashMapUnmanaged(void) = .{},
    /// GG.20 (bkz. plan dosyası "ASAP güçlendirmesi — Tur 4"): whole-program
    /// `(fonksiyon_adı, parametre_indeksi)` çiftlerinin — `list`/`dict`/
    /// `class` tipli bir parametrenin, O fonksiyonun KENDİ gövdesinde
    /// DOĞRUDAN YA DA (YENİ) bir yardımcı SERBEST fonksiyona argüman
    /// olarak geçip O fonksiyonun KARŞILIK GELEN parametresinde mutasyona
    /// uğraması YOLUYLA — mutasyona UĞRADIĞI KANITLANMIŞ kümesi.
    /// `computeMutatesGraph` TARAFINDAN (`collectSpawnTargets`İLE AYNI
    /// aşamada) doldurulur; `checkNoSpawnSharedMutation` bunu kullanarak
    /// `helper(xs)` GİBİ TRANSİTİF mutasyonları da YAKALAR (v1.30.0'ın
    /// "yalnızca KENDİ gövde" sınırlamasının GENELLEMESİ).
    mutates_params: effect_graph.NodeSet = .{},
    /// v1.30.1 (bkz. nox-teknik-spesifikasyon.md §3.96): `parser.zig`nin
    /// GÜVENLİK bulgusu H-3 düzeltmesiyle (`enterRecursion`/
    /// `MAX_EXPR_DEPTH`) AYNI mekanizma — AMA parser'ın guard'ı YALNIZCA
    /// parantez/önek-operatör iç içe geçmesini kapsar; DÜZ bir ikili-
    /// operatör zinciri (`1+1+1+...`) parser'da YİNELEMELİ İŞLENİP
    /// ÖZYİNELEME DERİNLİĞİNİ ARTIRMAZ AMA YİNE DE N-derin bir AST üretir
    /// — `checkExpr`/`checkBinary` bu AST'yi GERÇEKTEN özyinelemeli
    /// gezdiğinden (GERÇEK, 2000-derin bir fuzz testiyle KANITLANMIŞ
    /// SIGABRT — `tests/fuzz/lexer_parser_checker_fuzz.zig`), AYNI sınır
    /// BURADA checker'ın KENDİ canlı özyineleme derinliğine uygulanır.
    /// `enterExprRecursion`/`exitExprRecursion` İLE `defer` üzerinden
    /// otomatik sıfırlanır (parser'ın KENDİ deseniyle BİREBİR AYNI).
    expr_depth: usize = 0,
    /// Faz U.4.5 (bkz. `checkExpr`nin `.identifier` dalı): üst-düzey
    /// (non-generic) bir `def`in BARE adı, ÇAĞRI DIŞINDA bir bağlamda
    /// (bir değişkene atama, bir listeye/alana KOYMA) kullanıldığında bu
    /// kümeye EKLENİR — codegen'in (bkz. `genFunctionValueTrampoline`)
    /// HANGİ fonksiyonlar İçin bir `%env`-yok-sayan sarmalayıcı üretmesi
    /// GEREKTİĞİNİ BİLMESİ İçin (üst-düzey fonksiyonların KENDİ ABI'si
    /// `%env` TAŞIMAZ — bkz. `closures.zig`nin `genFunctionValueTrampoline`
    /// belge notu).
    functions_used_as_value: std.StringHashMapUnmanaged(void) = .{},
    /// Faz 1 decorator (bkz. plan dosyası "Decorator sözdizimi +
    /// metadata-tabanlı metaprogramming"): `registerFunc` TARAFINDAN
    /// doldurulan, HER `@isim(...)` decoratörlü üst-düzey `def` İçin BİR
    /// `DecoratedFuncInfo` — codegen'in `$__nox_decorators` statik `.data`
    /// tablosunu (bkz. `layout.zig`nin `genClassVtable`ıyla AYNI desen)
    /// ÜRETMESİ İçin `generateModule`e AYNEN `functions_used_as_value` GİBİ
    /// bir parametre olarak geçirilir.
    decorated_functions: std.ArrayListUnmanaged(DecoratedFuncInfo) = .empty,
    /// `instantiateGeneric` tarafından üretilen, somut (monomorphize edilmiş)
    /// fonksiyon tanımları — `main.zig`/codegen bunları modülün geri kalanı
    /// gibi normal, generic olmayan fonksiyonlar olarak derler. Adları
    /// (`mangleName`) ile önbelleğe alınır: aynı (fonksiyon, somut tip demeti)
    /// çifti için en fazla bir kez sentezlenir.
    instantiations: std.ArrayListUnmanaged(ast.FuncDef) = .empty,
    /// Faz P2.1 (bkz. proje belleği "generic sınıflar" planı): `generic_
    /// functions`in AYNISI ama SINIFLAR İçin — generic (`type_params.len >
    /// 0`) sınıflar, somut bir kullanım (kurucu çağrısı YA DA tip ifadesi,
    /// bkz. `instantiateGenericClass`) İLE karşılaşılana kadar burada
    /// beklerler; `self.classes`e ASLA girmez (bare isimleriyle DOĞRUDAN
    /// inşa/tip OLARAK kullanılamazlar).
    generic_classes: std.StringHashMapUnmanaged(ast.ClassDef) = .{},
    /// Faz 7 (tekli kalıtım): `collectClassNames` tarafından doldurulur —
    /// `ensureClassBodyChecked`in bir sınıfın ADINDAN kendi `ast.ClassDef`ine
    /// (taban zincirini YUKARI doğru YÜRÜMEK İçin) geri gitmesi İçin.
    class_defs_by_name: std.StringHashMapUnmanaged(ast.ClassDef) = .{},
    /// Faz 7: `ensureClassBodyChecked` tarafından tutulan — bir sınıfın
    /// gövdesinin (Geçiş 3) ZATEN denetlenip denetlenmediği (bkz. onun
    /// belge notu, "taban ÖNCE, ama SADECE gerektiğinde" deseni).
    class_body_checked: std.StringHashMapUnmanaged(void) = .{},
    /// Faz 7: `ensureClassSignatureRegistered` tarafından tutulan — bir
    /// sınıfın İMZASININ (Geçiş 2) ZATEN kaydedilip kaydedilmediği.
    class_sig_registered: std.StringHashMapUnmanaged(void) = .{},
    /// Faz 7: `ensureClassSignatureRegistered`in KENDİ ÇAĞRI YIĞININDA
    /// "şu an işleniyor" işareti — döngüsel kalıtımı (A→B→A) yakalamak
    /// İçin (`class_sig_registered`den AYRI: o SADECE "TAMAMLANDI" bilgisi
    /// taşır, BU ise "HÂLÂ İŞLENİYOR" bilgisini).
    class_sig_in_progress: std.StringHashMapUnmanaged(void) = .{},
    /// `instantiateGenericClass` tarafından üretilen, somut (monomorphize
    /// edilmiş) sınıf tanımları — `instantiations`in AYNISI ama SINIFLAR
    /// İçin.
    class_instantiations: std.ArrayListUnmanaged(ast.ClassDef) = .empty,
    /// Yapısal protokoller (Faz 11) — adları modül düzeyinde benzersizdir,
    /// bir sınıfla hiçbir açık ilişki (implements) bildirmezler (bkz.
    /// `collectProtocols`). Bir fonksiyonun bir parametresi/dönüş tipi bir
    /// protokol adına başvurursa, o fonksiyon Faz 10'un generic altyapısına
    /// (`generic_functions`) yönlendirilir — protokol adı, çağrı sitesinde
    /// somut bir sınıfa çözümlenmesi gereken ÖRTÜK bir tip parametresi gibi
    /// davranır, ama ek olarak YAPISAL EŞLEŞME (`satisfiesProtocol`) ile
    /// doğrulanır.
    protocols: std.StringHashMapUnmanaged(ProtocolInfo) = .{},
    /// `import nox.http` gibi bir deyimle içeri alınan modül yollarının
    /// kümesi — noktalarla birleştirilmiş TAM yol (`"nox.http"`) olarak
    /// saklanır (bkz. `checkModule`in `.import_stmt` kolu). `checkCall`in
    /// `.attribute` dalı, bir çağrı sitesindeki noktalı zinciri (`nox.http.get`)
    /// düzleştirip bu kümeyle eşleştirir — bkz. `tryResolveQualifiedCall`in
    /// belge notu.
    imported_modules: std.StringHashMapUnmanaged(void) = .{},
    /// Faz U.3: `import X.Y as Z` — takma ad (`"Z"`) → TAM modül yolunun
    /// segmentleri (`["X","Y"]`). `substituteAlias` bir çağrı sitesindeki
    /// düzleştirilmiş noktalı zincirin İLK segmentini bu haritada ararsa,
    /// onu HEDEF segmentlerle DEĞİŞTİRİR (ör. `Z.foo` → `["X","Y","foo"]`)
    /// — geri kalan çözümleme (`tryResolveQualifiedCall`) DEĞİŞMEDEN devam
    /// eder.
    module_aliases: std.StringHashMapUnmanaged([]const []const u8) = .{},
    /// Faz U.3: `from X.Y import foo[as bar]` — yerel ÇIPLAK isim (`"bar"`
    /// ya da `"foo"`) → mangled TAM sembol adı (`"X_Y_foo"`). `checkCall`in
    /// `.identifier` dalı, NORMAL çözümleme (yerel fonksiyon/sınıf) BAŞARISIZ
    /// olduğunda bu haritaya bakar — böylece `from`la içe aktarılan bir isim
    /// yerel bir tanımla ÇAKIŞTIĞINDA yerel tanım HER ZAMAN ÖNCELİKLİDİR
    /// (Python'un gölgeleme davranışına BENZER, ama statik/tek-geçişli).
    from_imports: std.StringHashMapUnmanaged([]const u8) = .{},
    /// Modül-seviyesi global durum (bkz. proje belleği "modül-seviyesi
    /// global durum" planı — `nyx`/`services/noxpkg/` bağımsız olarak
    /// çarptığı, ÖNCEDEN üst-düzey `var_decl`ların HİÇBİR fonksiyon
    /// gövdesinden GÖRÜLEMEDİĞİ gerçek kısıtın çözümü). `collectModuleGlobals`
    /// (Geçiş 1.5 — `collectClassNames`den SONRA, `registerSignatures`den
    /// ÖNCE de OLABİLİRDİ ama fonksiyon İMZALARININ global TİPLERE bağımlı
    /// OLMAMASI nedeniyle sıralama ESNEKTİR; `checkModule`nin KENDİSİ
    /// `registerSignatures`den HEMEN SONRA çağırır) TARAFINDAN doldurulur.
    /// Yalnızca DECLARED tip taşınır (initializer İFADESİ DEĞİL) — tıpkı
    /// `registerSignatures`in parametre/dönüş tiplerini gövdeyi kontrol
    /// ETMEDEN çözmesi gibi.
    module_globals: std.StringHashMapUnmanaged(Type) = .{},
    /// Faz U.4.2: İÇ İÇE `def`lerin yakalama listeleri — anahtar
    /// `"<dış_yol>.<iç_isim>"` (bkz. `FnCtx.path`in belge notu),
    /// `checkNestedFuncDef` tarafından doldurulur. U.4.3'ün codegen'i
    /// TARAFINDAN (closure heap bloğunun İNŞASI İÇİN) TÜKETİLECEKTİR.
    closure_infos: std.StringHashMapUnmanaged(ClosureInfo) = .{},
    /// Faz T.2: `checkModule`nin üst-düzey döngüsünde (fonksiyon/sınıf/gevşek
    /// deyim SINIRINDA) VE `checkClassBody`nin metod döngüsünde YAKALANIP
    /// KURTARILAN tanılamalar — bkz. modül üstü not. `recordDiagnostic`
    /// tarafından doldurulur, `check()` tarafından `CheckOutcome.err.all`e
    /// kopyalanır.
    diagnostics: std.ArrayListUnmanaged(Diagnostic) = .empty,
    /// Faz MN.9.4: `isThreadTransferSafeType`nin (bkz. onun belge notu)
    /// backend-farkındalı gevşetmesi İçİn — VARSAYILAN `.qbe` (TÜM MEVCUT
    /// çağrı SİTELERİ/testler/golden fixture'lar BUNU BEKLER, SIFIR
    /// davranış değişikliği). SADECE `compiler/main.zig`nin `buildOne`si,
    /// `--release` İKEN (backend ZATEN `codegen.Backend`e ÇÖZÜLDÜKTEN
    /// SONRA, `checkModule` ÇAĞRILMADAN ÖNCE) BUNU `.llvm` OLARAK
    /// AYARLAR — `cmdCheck`/`cmdExpand` (HİÇ `--release` KAVRAMI OLMAYAN
    /// komutlar) HİÇ dokunmaz, VARSAYILANDA KALIR (BİLİNÇLİ taşınabilirlik-
    /// maliyeti: `noxc check`, `list`/`class`/`dict` taşıyan bir `nox.
    /// thread.start`ı HATA olarak İŞARETLER, AYNI program `noxc build
    /// --release` İLE GERÇEKTEN DERLENEBİLİR OLSA BİLE).
    backend: types.Backend = .qbe,

    pub fn init(allocator: std.mem.Allocator) Checker {
        return .{ .allocator = allocator };
    }

    fn fail(self: *Checker, err: TypeError, comptime fmt: []const u8, args: anytype) TypeError {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch
            "(tanılama mesajı oluşturulamadı: bellek yetersiz)";
        self.diagnostic = if (self.current_line > 0)
            std.fmt.allocPrint(self.allocator, "satır {d}: {s}", .{ self.current_line, msg }) catch msg
        else
            msg;
        return err;
    }

    /// v1.30.1 (bkz. `expr_depth`in belge notu): `compiler/parser/parser.zig`
    /// nin `MAX_EXPR_DEPTH`iyle AYNI sabit/gerekçe — GERÇEKÇİ HİÇBİR Nox
    /// programının asla yaklaşmayacağı ama macOS'un varsayılan 8MB
    /// yığınında GÜVENLE bol pay bırakan bir sınır.
    const MAX_EXPR_DEPTH: usize = 500;

    /// v1.30.1: `parser.zig`nin `enterRecursion`iyle AYNI desen —
    /// `checkExpr`in HER çağrısında (switch'TEN ÖNCE) çağrılır, `defer
    /// exitExprRecursion()` İLE eşleştirilir.
    fn enterExprRecursion(self: *Checker) TypeError!void {
        self.expr_depth += 1;
        if (self.expr_depth > MAX_EXPR_DEPTH) {
            return self.fail(error.TooDeeplyNested, "ifade çok derin iç içe geçmiş (izin verilen en fazla derinlik: {d})", .{MAX_EXPR_DEPTH});
        }
    }

    fn exitExprRecursion(self: *Checker) void {
        self.expr_depth -= 1;
    }

    /// Faz T.2: bir bağımsız birimin (fonksiyon/sınıf/metod/gevşek deyim)
    /// denetiminden fırlayan bir `TypeError`i YAKALAYIP `self.diagnostics`e
    /// kaydeder — `error.OutOfMemory` İSE KURTARILAMAZ bir durumdur, ASLA
    /// bir "tanılama" DEĞİLDİR, bu yüzden DEĞİŞTİRİLMEDEN yeniden fırlatılır
    /// (çağıranın KENDİSİ de OOM'u aynı şekilde yukarı ilettiğinden bu,
    /// `checkModule`nin/`checkClassBody`nin TAMAMEN durmasına yol açar —
    /// bu, İSTENEN davranıştır).
    fn recordDiagnostic(self: *Checker, err: TypeError) TypeError!void {
        if (err == error.OutOfMemory) return err;
        try self.diagnostics.append(self.allocator, .{
            .code = err,
            .line = self.current_line,
            .message = self.diagnostic orelse "(mesaj yok)",
            .span = self.current_span,
        });
    }

    fn typeExprToType(self: *Checker, te: ast.TypeExpr) TypeError!Type {
        switch (te) {
            .simple => |name| {
                if (std.mem.eql(u8, name, "int")) return .int;
                if (std.mem.eql(u8, name, "float")) return .float;
                if (std.mem.eql(u8, name, "bool")) return .boolean;
                if (std.mem.eql(u8, name, "str")) return .str;
                if (std.mem.eql(u8, name, "None")) return .none;
                if (std.mem.eql(u8, name, "ptr")) return .ptr;
                if (self.classes.contains(name)) return .{ .class = name };
                // Bulundu (bkz. proje belleği "from-import class type
                // annotations" görevi): `checkCall`in `.identifier` dalının
                // `from_imports` GERİ DÜŞÜŞÜYLE (bkz. ~satır 2236) AYNI
                // ilke — `from X import Widget` İLE bağlanan ÇIPLAK bir isim
                // `Widget(...)` OLARAK ÇAĞRILABİLİYORDU ama `w: Widget = ...`
                // TİP ANNOTASYONU olarak KULLANILAMIYORDU (`typeExprToType`
                // `from_imports`ı HİÇ danışmıyordu — GERÇEK, önceden
                // keşfedilmemiş bir hata, PLAIN/generic-olmayan sınıflar
                // DAHİL). Yerel bir sınıf (YUKARIDAKİ `self.classes.contains`)
                // HER ZAMAN ÖNCELİKLİDİR (from-import çözümlemesi yalnızca
                // NORMAL çözümleme başarısız olduğunda denenir, `checkCall`
                // İLE AYNI ilke). `mangled` bir SINIF DEĞİLSE (ör. `from X
                // import some_func` bir FONKSİYONA eşleniyorsa) BİLİNÇLİ
                // olarak reddedilir — bir TİP konumunda bir fonksiyon adı
                // ANLAMSIZDIR.
                if (self.from_imports.get(name)) |mangled| {
                    if (self.classes.contains(mangled)) return .{ .class = mangled };
                }
                return self.fail(error.UnknownType, "bilinmeyen tip: {s}", .{name});
            },
            .generic => |g| {
                if (std.mem.eql(u8, g.name, "list") or std.mem.eql(u8, g.name, "Task") or std.mem.eql(u8, g.name, "Channel") or std.mem.eql(u8, g.name, "ThreadHandle") or std.mem.eql(u8, g.name, "ThreadChannel") or std.mem.eql(u8, g.name, "TaskLocal")) {
                    if (g.args.len != 1) {
                        return self.fail(error.UnknownType, "'{s}' tam olarak bir tip argümanı alır", .{g.name});
                    }
                    const elem = try self.typeExprToType(g.args[0]);
                    // Faz OO.2: `TaskLocal[T]`nin `T`si — `checkGenericConstruct`nin
                    // AYNI kısıtlaması (bkz. onun belge notu) BURADA da (BİR
                    // `TaskLocal[int]` DEĞİŞKEN/ALAN TİPİ bildirimi İçin de)
                    // GEÇERLİDİR.
                    if (std.mem.eql(u8, g.name, "TaskLocal") and (elem == .int or elem == .float or elem == .boolean)) {
                        return self.fail(error.TypeMismatch, "'TaskLocal[T]'nin T'si bir sınıf/str/list/dict olmalıdır (çıplak int/float/bool v1 kapsamı dışı)", .{});
                    }
                    const boxed = try self.allocator.create(Type);
                    boxed.* = elem;
                    if (std.mem.eql(u8, g.name, "list")) return .{ .list = boxed };
                    if (std.mem.eql(u8, g.name, "Task")) return .{ .task = boxed };
                    if (std.mem.eql(u8, g.name, "Channel")) return .{ .channel = boxed };
                    if (std.mem.eql(u8, g.name, "ThreadHandle")) return .{ .thread_handle = boxed };
                    if (std.mem.eql(u8, g.name, "TaskLocal")) return .{ .task_local = boxed };
                    return .{ .thread_channel = boxed };
                }
                // `dict[K, V]` — stdlib fazı §C. v1 kapsamı bilinçli olarak
                // dar: `K` yalnızca `int`/`bool`/`str` (hashlenebilir, basit
                // eşitlik/hash gerektirir — bkz. runtime/collections/dict.zig),
                // `V` `int`/`float`/`bool`/`str` (sınıf DEĞER/ANAHTAR ERTELENDİ
                // — bkz. nox-teknik-spesifikasyon.md §3.28).
                if (std.mem.eql(u8, g.name, "dict")) {
                    if (g.args.len != 2) {
                        return self.fail(error.UnknownType, "'dict' tam olarak iki tip argümanı alır (K, V)", .{});
                    }
                    const key_t = try self.typeExprToType(g.args[0]);
                    const value_t = try self.typeExprToType(g.args[1]);
                    if (key_t != .int and key_t != .boolean and key_t != .str) {
                        return self.fail(error.UnknownType, "'dict' anahtar tipi yalnızca int/bool/str olabilir (v1 kapsamı)", .{});
                    }
                    // Faz OO.4 (bkz. nox-teknik-spesifikasyon.md §3.85):
                    // `.class` DEĞER OLARAK KABUL EDİLİR — `nox_class_
                    // release_dispatch`in (bkz. `layout.zig`) tag-tabanlı
                    // dispatch'i ÜZERİNDEN, ÇALIŞMA ZAMANI sınıf etiketi
                    // değerin KENDİ gömülü baytlarından okunur, `dict.zig`
                    // KENDİSİ hangi SOMUT sınıf olduğunu BİLMEK ZORUNDA
                    // DEĞİLDİR (Madde 1'in `TaskLocal[T]`siyle AYNI desen).
                    // Sınıf ANAHTAR olarak HÂLÂ REDDEDİLİR (hash/eşitlik
                    // AYRI, DAHA ZOR bir problem — bilinçli kapsam DIŞI).
                    if (value_t != .int and value_t != .float and value_t != .boolean and value_t != .str and value_t != .class) {
                        return self.fail(error.UnknownType, "'dict' değer tipi yalnızca int/float/bool/str/sınıf olabilir (v1 kapsamı)", .{});
                    }
                    const key_boxed = try self.allocator.create(Type);
                    key_boxed.* = key_t;
                    const value_boxed = try self.allocator.create(Type);
                    value_boxed.* = value_t;
                    return .{ .dict = .{ .key = key_boxed, .value = value_boxed } };
                }
                // Faz P2.1: kullanıcı-tanımlı bir generic sınıf — bir alan/
                // parametre `Box[int]` OLARAK bildirilirse (bir kurucu
                // çağrısı HİÇ görülmeden BİLE) buradan çözülür (bkz.
                // `instantiateGenericClass`in belge notu). Bulundu (bkz.
                // proje belleği "4 yeni stdlib modülü" planı, nox.collections):
                // `checkGenericConstruct`in (satır ~2175) `from_imports`
                // GERİ DÜŞÜŞÜ BURADA EKSİKTİ — `from nox.collections import
                // Stack` İLE getirilen bir generic sınıf, `s: Stack[int] =
                // ...` GİBİ bir TİP ANNOTASYONUNDA (kurucu çağrısından ÖNCE
                // BİLE, ör. bir alan bildirimi) "bilinmeyen generic tip"
                // hatası verirdi çünkü `g.name` ("Stack") burada YALNIZCA
                // `self.generic_classes`e (mangled isimlerle anahtarlı)
                // ÇIPLAK karşılaştırılıyordu — GERÇEK bir tekrar-üretimle
                // (nox.collections'ın `import`+tip-annotasyon KULLANIMIYLA)
                // DOĞRULANDI.
                const maybe_gcd = self.generic_classes.get(g.name) orelse blk: {
                    const mangled_base = self.from_imports.get(g.name) orelse break :blk null;
                    break :blk self.generic_classes.get(mangled_base);
                };
                if (maybe_gcd) |gcd| {
                    const bound = try self.allocator.alloc(Type, g.args.len);
                    for (g.args, 0..) |a, i| bound[i] = try self.typeExprToType(a);
                    return try self.instantiateGenericClass(gcd, bound);
                }
                return self.fail(error.UnknownType, "bilinmeyen generic tip: {s}", .{g.name});
            },
            // Faz U.4: `(int, int) -> int` — birinci-sınıf fonksiyon/closure
            // tip ifadesi (bkz. nox-teknik-spesifikasyon.md §3.23).
            .func_type => |ft| {
                const params = try self.allocator.alloc(Type, ft.params.len);
                for (ft.params, 0..) |p, i| params[i] = try self.typeExprToType(p);
                const ret = try self.allocator.create(Type);
                ret.* = try self.typeExprToType(ft.return_type.*);
                return .{ .func = .{ .params = params, .return_type = ret } };
            },
            // Faz FF.6 (bkz. nox-teknik-spesifikasyon.md §3.65): `T | None`.
            // İç tipin KENDİSİ `.none`/`.optional` İSE reddedilir — `None |
            // None` ya da iç içe Optional anlamsızdır (parser bunu zaten
            // ÜRETEMEZ, bu SAVUNMACI bir kontrol).
            .optional => |inner_te| {
                const inner = try self.typeExprToType(inner_te.*);
                if (inner == .none or inner == .optional) {
                    return self.fail(error.UnknownType, "'None | None' ya da iç içe Optional geçersizdir", .{});
                }
                const boxed = try self.allocator.create(Type);
                boxed.* = inner;
                return .{ .optional = boxed };
            },
            // Faz NN.2 (bkz. proje belleği "nyx v2 limitasyon listesi
            // doğrulaması"): `pkg.module.ClassName` bir TİP-AÇIKLAMASI
            // konumunda — `tryResolveQualifiedCall`in (satır ~978) İFADE
            // konumundaki AYNI mangling mantığı burada tekrar kullanılır
            // (alias ikame + `module_path`nin `imported_modules`de olduğu
            // doğrulaması + `_`-birleştirilmiş mangled ad araması), ama
            // BURADA yalnızca `self.classes`e bakılır — bir TİP konumunda
            // bir FONKSİYON/generic-fonksiyon adı anlamsızdır.
            .qualified => |raw_segments| {
                const segments = try self.substituteAlias(raw_segments);
                if (segments.len < 2) {
                    return self.fail(error.UnknownType, "gecersiz nitelikli tip adi", .{});
                }
                const module_path = try self.joinSegments(segments[0 .. segments.len - 1], '.');
                if (!self.imported_modules.contains(module_path)) {
                    return self.fail(error.UnknownType, "bilinmeyen modul: {s}", .{module_path});
                }
                const mangled = try self.joinSegments(segments, '_');
                if (self.classes.contains(mangled)) return .{ .class = mangled };
                return self.fail(error.UnknownType, "'{s}' modulunun '{s}' adli bir sinifi yok", .{ module_path, segments[segments.len - 1] });
            },
        }
    }

    fn assignable(self: *Checker, declared: Type, value: Type) bool {
        if (types.eql(declared, value)) return true;
        if (declared == .float and value == .int) return true;
        // Faz 7 (tekli kalıtım): bir taban-sınıf tipi bildirilen bir yere
        // (parametre/alan/dönüş/var_decl) taban sınıfın HERHANGİ bir
        // (transitif) ALT sınıfının bir örneği atanabilir — standart
        // nesne-yönelimli kovaryans (bkz. `isSubclassOf`).
        if (declared == .class and value == .class) {
            return self.isSubclassOf(value.class, declared.class);
        }
        // Faz FF.6 (bkz. nox-teknik-spesifikasyon.md §3.65): `T | None`e
        // hem `None` HEM DE çıplak `T` (Python'daki "auto-wrap" gibi,
        // `x: int | None = 5` GEÇERLİDİR) atanabilir.
        if (declared == .optional) {
            if (value == .none) return true;
            return self.assignable(declared.optional.*, value);
        }
        return false;
    }

    /// Faz 7 (tekli kalıtım): `sub` sınıfı `sup`un KENDİSİ ya da
    /// (transitif) bir alt sınıfı MI — taban zincirini `sup`a ULAŞANA ya
    /// da taban BİTENE (bilinmeyen/YOK) kadar yukarı doğru YÜRÜR.
    fn isSubclassOf(self: *Checker, sub: []const u8, sup: []const u8) bool {
        var cur: ?[]const u8 = sub;
        while (cur) |name| {
            if (std.mem.eql(u8, name, sup)) return true;
            const info = self.classes.get(name) orelse return false;
            cur = info.base;
        }
        return false;
    }

    /// GG.21 (bkz. plan dosyası "ASAP güçlendirmesi — Tur 5"): `class_name`
    /// (VEYA HERHANGİ bir BİLİNEN alt sınıfı) `method_name` adlı metodu
    /// HİÇBİR YERDE override ETMİYOR MU — `isSubclassOf`nin (YUKARIDA)
    /// taban-zinciri yürüyüşünü TERSİNE çevirerek TÜM kayıtlı sınıfları
    /// tarar (program-boyu sınıf sayısı TİPİK olarak küçük, önbelleğe
    /// GEREK YOK). `false` dönmesi (polimorfik OLABİLİR) HER ZAMAN
    /// GÜVENLİ/muhafazakâr taraftır — `method_owners`in henüz doldurulmadığı
    /// bir sınıf İçİn de (bulunamazsa) `false`a düşer.
    fn methodIsFinal(self: *Checker, class_name: []const u8, method_name: []const u8) bool {
        var it = self.classes.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, class_name)) continue;
            if (!self.isSubclassOf(entry.key_ptr.*, class_name)) continue;
            if (entry.value_ptr.method_owners.get(method_name)) |owner| {
                if (std.mem.eql(u8, owner, entry.key_ptr.*)) return false;
            }
        }
        return true;
    }

    /// Faz 7 (tekli kalıtım): `e` TAM OLARAK `super()` (argümansız,
    /// çıplak `super` tanımlayıcısına yapılan bir çağrı) MI — `checkCall`in
    /// `.attribute` dalının `super().metod(...)` desenini tanıması İçin.
    fn isSuperCallExpr(e: ast.Expr) bool {
        return switch (e) {
            .call => |c| switch (c.callee.*) {
                .identifier => |n| c.args.len == 0 and std.mem.eql(u8, n, "super"),
                else => false,
            },
            else => false,
        };
    }

    /// Faz FF.6 (bkz. nox-teknik-spesifikasyon.md §3.65): bir alan/metod/
    /// index erişiminin ALICISI (`a.obj`) `T | None` İSE — daraltılmamış
    /// bir Optional üzerinde HERHANGİ bir erişim çağrı sitesinin TEK,
    /// paylaşılan kapısı. `detectNarrowing`in DAR desen tanıması DIŞINDA
    /// (ör. `if x:` gibi truthy-kontrol, ya da bambaşka bir koşul) bir
    /// Optional ASLA "otomatik" daraltılmaz.
    fn requireNotOptional(self: *Checker, t: Type, what: []const u8) TypeError!void {
        if (t == .optional) {
            return self.fail(error.OptionalNotNarrowed, "'{s}' için Optional (T | None) bir değer kullanılamaz — önce 'if ... != None:' ile daraltın", .{what});
        }
    }

    // ---- Geçiş 0: import/from-import bildirimlerini topla ----

    /// Bulundu (bkz. proje belleği "from-import class type annotations"
    /// görevi) — GERÇEK, önceden keşfedilmemiş bir SIRALAMA hatası:
    /// `.import_stmt`/`.from_import_stmt` ÖNCEDEN yalnızca `checkModule`nin
    /// ANA (Geçiş 3) döngüsünde işlenirdi — AMA bu döngü `registerSignatures`
    /// (Geçiş 2, PARAMETRE/dönüş tiplerini `typeExprToType` İLE ÇÖZEN geçiş)
    /// TAMAMLANDIKTAN SONRA çalışır. Bu YÜZDEN `from X import Widget` İLE
    /// bağlanan bir sınıf, bir DEĞİŞKEN/atama TİPİ olarak (Geçiş 3'te
    /// çözülür) ÇALIŞIRDI ama bir FONKSİYON PARAMETRESİ tipi olarak (Geçiş
    /// 2'de çözülür — `self.from_imports` O ANDA HÂLÂ BOŞTUR) `error.
    /// UnknownType` İLE BAŞARISIZ olurdu. Düzeltme: import/from-import
    /// bildirimleri ARTIK `registerSignatures`DEN ÖNCE, AYRI bir erken
    /// geçişte toplanır — `.import_stmt`/`.from_import_stmt`in KENDİSİ hiçbir
    /// ŞEYE (Geçiş 1/2'nin ÜRETTİĞİ HİÇBİR duruma) BAĞIMLI OLMADIĞINDAN bu
    /// TAMAMEN GÜVENLİDİR (yalnızca AST'nin KENDİSİNDEN okur). Ana Geçiş 3
    /// döngüsü artık bu İKİ deyim türünü NO-OP olarak GEÇER (bkz. AŞAĞIDAKİ
    /// `checkModule`).
    fn collectImports(self: *Checker, module: ast.Module) TypeError!void {
        for (module.body) |stmt| {
            switch (stmt.kind) {
                .import_stmt => |imp| {
                    const joined = try self.joinSegments(imp.segments, '.');
                    try self.imported_modules.put(self.allocator, joined, {});
                    if (imp.alias) |alias| {
                        try self.module_aliases.put(self.allocator, alias, imp.segments);
                    }
                },
                .from_import_stmt => |fi| {
                    const joined = try self.joinSegments(fi.segments, '.');
                    try self.imported_modules.put(self.allocator, joined, {});
                    for (fi.names) |nm| {
                        var mangled_segments: std.ArrayListUnmanaged([]const u8) = .empty;
                        try mangled_segments.appendSlice(self.allocator, fi.segments);
                        try mangled_segments.append(self.allocator, nm.name);
                        const mangled = try self.joinSegments(mangled_segments.items, '_');
                        const local_name = nm.alias orelse nm.name;
                        try self.from_imports.put(self.allocator, local_name, mangled);
                    }
                },
                else => {},
            }
        }
    }

    // ---- Geçiş 1: sınıf adlarını topla (ileri referansları desteklemek için) ----

    fn collectClassNames(self: *Checker, module: ast.Module) TypeError!void {
        for (module.body) |stmt| {
            self.current_line = stmt.line;
            self.current_span = stmt.span;
            if (stmt.kind == .class_def) {
                const cd = stmt.kind.class_def;
                if (self.classes.contains(cd.name) or self.generic_classes.contains(cd.name)) {
                    return self.fail(error.DuplicateDefinition, "sınıf zaten tanımlı: {s}", .{cd.name});
                }
                // Faz 1 decorator (bkz. plan dosyası "kapsam DIŞI"): sınıf
                // decorator'ları PARSE EDİLİR (`ast.ClassDef.decorators`)
                // ama v1'de HENÜZ desteklenmez — Nox'ta "bir metodu `self`e
                // bağlı, çağrılabilir bir DEĞER olarak dışarı ver" mekanizması
                // YOK, bu YÜZDEN sessizce YOK SAYMAK YERİNE AÇIK bir hata
                // verilir (kullanıcı yanlışlıkla decorator'ının hiçbir ETKİSİ
                // olmadığını SANMASIN).
                if (cd.decorators.len > 0) {
                    return self.fail(error.TypeMismatch, "sınıf decorator'ları henüz desteklenmiyor: @{s} (sınıf: {s}) — v1 yalnızca üst-düzey fonksiyon decorator'larını destekler", .{ cd.decorators[0].name, cd.name });
                }
                // Faz P2.1: generic (`type_params.len > 0`) bir sınıf
                // `self.classes`e ASLA girmez — `registerFunc`in
                // `generic_functions` İLE AYNI ayrımı (bkz. `generic_classes`
                // in belge notu). Somut tip argümanları OLMADAN bare isim
                // ne DOĞRUDAN inşa EDİLEBİLİR ne de bir tip ifadesinde
                // KULLANILABİLİR.
                if (cd.type_params.len > 0) {
                    // Faz 7 (tekli kalıtım): generic sınıf + kalıtım
                    // ETKİLEŞİMİ v1 KAPSAMI DIŞINDA (bkz. proje belleği
                    // "7 fazlı düzeltme planı" Faz 7) — `instantiateGenericClass`
                    // somut örneklemeyi `.base` OLMADAN sentezlediğinden
                    // (bilerek, generic+kalıtım DESTEKLENMEDİĞİNDEN),
                    // bunu SESSİZCE DÜŞÜRMEK YERİNE burada AÇIKÇA reddedilir.
                    if (cd.base != null) {
                        return self.fail(error.TypeMismatch, "generic bir sınıfın ('{s}') taban sınıfı olamaz (generic + kalıtım v1 kapsamında desteklenmiyor)", .{cd.name});
                    }
                    try self.generic_classes.put(self.allocator, cd.name, cd);
                } else {
                    try self.classes.put(self.allocator, cd.name, .{});
                    try self.class_defs_by_name.put(self.allocator, cd.name, cd);
                }
            }
        }
    }

    // Bulundu (bkz. proje belleği "modül-seviyesi global durum" planı):
    // üst-düzey `var_decl`ların (declared) tiplerini `self.module_globals`e
    // kaydeder — `collectClassNames`in AYNI "ileri referansları destekle"
    // gerekçesiyle: `checkModule`nin ana geçişi fonksiyon gövdelerini
    // METİN SIRASIYLA kontrol ettiğinden (registerSignatures'ın AKSİNE
    // ERTELENMİŞ değil), bu ön-geçiş OLMADAN bir global'den ÖNCE tanımlı
    // bir fonksiyon o global'i HİÇ GÖREMEZDİ. Yalnızca DECLARED tip
    // taşınır — initializer İFADESİ burada DEĞERLENDİRİLMEZ (checker'ın
    // ana geçişindeki normal `.var_decl` işleyişi `top_scope` İÇİN bunu
    // zaten yapıyor, bkz. `checkModule`).
    //
    // **Bilinçli v1 semantiği (codegen'in `globals.zig`sindeki `genNoxInitGlobals`
    // İLE UYGULANIR, burada YALNIZCA belgelenir):** üst-düzey `var_decl`
    // initializer'ları ÇALIŞMA ZAMANINDA HER ZAMAN diğer TÜM üst-düzey
    // deyimlerden ÖNCE çalışır — metinsel sırayla İÇ İÇE geçmiş olsalar
    // BİLE (`x: int = 1; print(x); y: int = f()` → HEM `x` HEM `y`
    // initializer'ı `print`den ÖNCE çalışır). Bu, `collectImports`/
    // `collectClassNames`in ZATEN "yapısal bildirimleri ÖNCE işle"
    // deseniyle TUTARLI ama DAHA GÜÇLÜ bir iddiadır (initializer KODU,
    // sadece bildirim DEĞİL, metin dışı sırada çalışıyor) — BİLİNÇLİ.
    fn collectModuleGlobals(self: *Checker, module: ast.Module) TypeError!void {
        for (module.body) |stmt| {
            self.current_line = stmt.line;
            self.current_span = stmt.span;
            if (stmt.kind != .var_decl) continue;
            const v = stmt.kind.var_decl;
            const declared = try self.typeExprToType(v.type_expr);
            try self.module_globals.put(self.allocator, v.name, declared);
        }
    }

    // ---- Geçiş 2: fonksiyon/sınıf imzalarını çözümle ----

    fn registerSignatures(self: *Checker, module: ast.Module) TypeError!void {
        // Faz 7 (tekli kalıtım): sınıflar METİNSEL sırayla kaydedilmeye
        // DEVAM eder (`func_def`/`extern_def` İLE İÇ İÇE geçmiş — bu SIRA
        // KORUNMALIDIR: bir `func_def`in dönüş/parametre tipi bir generic
        // sınıfı ANINDA (Geçiş 2 SIRASINDA, `typeExprToType`nin `.generic`
        // dalı üzerinden) somutlaştırabilir — bkz. `instantiateGenericClass`
        // — bu YÜZDEN "ÖNCE TÜM sınıfları, SONRA TÜM fonksiyonları
        // kaydet" gibi bir GENEL yeniden-sıralama YANLIŞTIR: `core.nox`nin
        // `ValueError` GİBİ (kullanıcı kodundan ÖNCE, ama LİSTEDE HENÜZ
        // "sınıf" olarak İŞLENMEMİŞ) sınıfları, DAHA SONRAKİ bir
        // fonksiyonun İMZASI (ör. `-> Box[int]`) TARAFINDAN TETİKLENEN bir
        // somutlaştırmanın (`raise ValueError(...)` İÇEREN bir `__init__`
        // gövdesi) İÇİNDE HENÜZ KAYITLI OLMAYAN bir `init_sig`le
        // BULUNMASINA yol AÇARDI — GERÇEK bir regresyonla BULUNDU/
        // DÜZELTİLDİ, bkz. proje belleği). SADECE `cd.base` bir İLERİ
        // referansSA (Derived, Base'den ÖNCE YAZILMIŞSA) `ensureClass
        // SignatureRegistered` Base'i HEMEN, sıra dışı kaydeder — AKSİ
        // HALDE (BÜYÜK ÇOĞUNLUK: taban YOK ya da taban ZATEN ÖNCE
        // YAZILMIŞ) davranış BİREBİR ÖNCEKİ METİNSEL sırayla AYNIDIR.
        for (module.body) |stmt| {
            self.current_line = stmt.line;
            self.current_span = stmt.span;
            switch (stmt.kind) {
                .func_def => |fd| try self.registerFunc(fd),
                .class_def => |cd| try self.ensureClassSignatureRegistered(cd),
                .extern_def => |ed| try self.registerExternFunc(ed),
                else => {},
            }
        }
    }

    /// Faz 7: `cd`nin İMZASININ (Geçiş 2) KAYITLI olduğundan EMİN olur —
    /// taban sınıfı (varsa) HENÜZ kayıtlı DEĞİLSE (`class Derived(Base):`
    /// `Base`den ÖNCE de YAZILABİLİR) ÖNCE ONU (özyinelemeli olarak)
    /// kaydeder. `class_sig_in_progress` DÖNGÜSEL kalıtımı (A→B→A)
    /// yakalar (`class_sig_registered`e HENÜZ EKLENMEMİŞ ama BU ÇAĞRI
    /// YIĞININDA HÂLÂ "işleniyor" İŞARETLİ bir sınıfa TEKRAR rastlanırsa).
    fn ensureClassSignatureRegistered(self: *Checker, cd: ast.ClassDef) TypeError!void {
        if (cd.type_params.len > 0) return; // generic şablon — registerClassSignatures ZATEN erken döner
        if (self.class_sig_registered.contains(cd.name)) return;
        if (self.class_sig_in_progress.contains(cd.name)) {
            return self.fail(error.TypeMismatch, "sınıflar arasında döngüsel kalıtım tespit edildi: {s}", .{cd.name});
        }
        try self.class_sig_in_progress.put(self.allocator, cd.name, {});
        if (cd.base) |base_name| {
            if (self.class_defs_by_name.get(base_name)) |base_cd| {
                try self.ensureClassSignatureRegistered(base_cd);
            }
            // `class_defs_by_name`de YOKSA (ne bir sıradan ne generic bir
            // sınıf adı) — `registerClassSignatures`in KENDİ `self.classes.
            // get(base_name) orelse UndefinedClass` kontrolü BUNU zaten
            // NET bir tanılamayla YAKALAYACAKTIR, burada EK bir kontrol
            // GEREKMEZ.
        }
        try self.registerClassSignatures(cd);
        try self.class_sig_registered.put(self.allocator, cd.name, {});
    }

    /// `extern def` bildirimini normal fonksiyonlarla AYNI tabloya
    /// (`self.functions`) kaydeder — bu sayede çağrı siteleri sıradan bir
    /// fonksiyon çağrısı gibi tip denetlenir (bkz. `checkCall`). Tek fark:
    /// v0.1 kapsamı yalnızca C ABI'sinde doğrudan (kutulanmadan) geçirilebilen
    /// ilkel tipleri (int/float/bool/str/None) kabul eder — `list[T]`/sınıf
    /// örnekleri Nox'un kendi ARC başlığını taşır, bu da C tarafına anlamsız
    /// bir bellek düzeni dayatır (bkz. nox-teknik-spesifikasyon.md §3.20).
    fn registerExternFunc(self: *Checker, ed: ast.ExternDef) TypeError!void {
        if (self.functions.contains(ed.name) or self.generic_functions.contains(ed.name)) {
            return self.fail(error.DuplicateDefinition, "fonksiyon zaten tanımlı: {s}", .{ed.name});
        }
        const params = try self.allocator.alloc(Type, ed.params.len);
        for (ed.params, 0..) |p, i| {
            const pt = try self.typeExprToType(p.type_expr);
            // Faz EE.1 (bkz. nox-teknik-spesifikasyon.md §3.61): `list[str]`
            // ARTIK parametre olarak da kabul edilir — `isFfiSafeListType`in
            // "yalnızca DÖNÜŞ, PARAMETRE değil" kısıtının gerekçesi ("bir Zig
            // fonksiyonunun ZATEN VAR OLAN bir list[str]i TÜKETMESİ İÇİN henüz
            // bir kullanım örneği YOK") ARTIK GEÇERLİ DEĞİL —
            // `nox_strings_join_raw`nin GERÇEK bir ihtiyacı VAR. Aynı akıl
            // yürütme (çalışma zamanı temsili ZATEN ARC'lı bir payload — 8
            // bayt uzunluk başlığı + `str` işaretçileri, Zig tarafı bunu
            // DOĞRUDAN OKUYABİLİR, İNŞA ETMEK ZORUNDA DEĞİL) PARAMETRE
            // yönünde de AYNEN geçerlidir.
            if (!isFfiSafeType(pt) and !isFfiSafeListType(pt)) {
                return self.fail(error.TypeMismatch, "extern fonksiyon '{s}': parametre '{s}' desteklenmeyen bir tipte (yalnızca int/float/bool/str/None/list[str] v0.1'de C ABI sınırında geçirilebilir)", .{ ed.name, p.name });
            }
            params[i] = pt;
        }
        const ret = try self.typeExprToType(ed.return_type);
        if (!isFfiSafeType(ret) and !isFfiSafeListType(ret) and !isFfiSafeClassReturnType(ret)) {
            return self.fail(error.TypeMismatch, "extern fonksiyon '{s}': dönüş tipi desteklenmeyen bir tipte (yalnızca int/float/bool/str/None/list[str]/sınıf v0.1'de C ABI sınırında geçirilebilir)", .{ed.name});
        }
        try self.functions.put(self.allocator, ed.name, .{ .params = params, .return_type = ret });
    }

    /// Stdlib fazı §F: `extern def`in DÖNÜŞ TİPİ olarak `list[str]` (v1
    /// kapsamı yalnızca bu somut örnekleme) kabul edilir — `dict[str,
    /// str]`in D.1'de aldığı MUAMELENİN AYNISI (bkz. `isFfiSafeType`'ın
    /// `.dict` dalı): çalışma zamanı temsili ZATEN ARC'lı bir `list[T]`
    /// payload'ıdır (8 bayt uzunluk başlığı + `str` işaretçileri, bkz.
    /// `codegen.zig`'in `genListLit`ı) — Zig tarafı bunu `nox_rc_alloc` +
    /// el ile yazılmış AYNI uzunluk başlığıyla DOĞRUDAN inşa edebilir (dönüş
    /// yönü) YA DA (Faz EE.1'den beri, bkz. nox-teknik-spesifikasyon.md
    /// §3.61) DOĞRUDAN OKUYABİLİR (PARAMETRE yönü — `nox_strings_join_raw`
    /// bunun ilk GERÇEK ihtiyaç sahibi; ÖNCEDEN "henüz bir kullanım örneği
    /// yok" gerekçesiyle YALNIZCA dönüş tipi olarak izin veriliyordu, AYNI
    /// alttaki temsil GEREKÇESİ parametre yönünde de GEÇERLİ olduğundan bu
    /// kısıt KALDIRILDI).
    fn isFfiSafeListType(t: Type) bool {
        return switch (t) {
            .list => |elem| elem.* == .str,
            else => false,
        };
    }

    /// Stdlib fazı §L: `isFfiSafeListType`den FARKLI olarak (Faz EE.1'de
    /// PARAMETRE yönü de açıldı, bkz. onun belge notu) BU hâlâ "yalnızca
    /// DÖNÜŞ, PARAMETRE değil" — bir sınıf tipi (ör. `JsonValue`) `with_rt
    /// extern def`in DÖNÜŞ tipi olarak kabul edilir. Bu GÜVENLİDİR çünkü Zig
    /// tarafı sınıfın HAM baytlarını KENDİSİ inşa ETMEZ (`class_id` derleme
    /// sırasına bağlı olduğundan Zig'den TAHMİN EDİLEMEZ) — bunun yerine
    /// AYNI sınıfın GERÇEK, QBE-derlenmiş bir Nox fabrika fonksiyonunu
    /// (`extern fn` ile, bkz. `runtime/stdlib_shims/json.zig`nin belge notu)
    /// ÇAĞIRIR; dönen değer ZATEN doğru `class_id`/ARC muhasebesiyle
    /// (normal `__init__` yoluyla) inşa edilmiş, sıradan bir işaretçidir —
    /// `extern def`in KENDİSİ yalnızca bu işaretçiyi OLDUĞU GİBİ yukarı
    /// taşır. PARAMETRE yönü BURADA HÂLÂ desteklenmez — `list[str]`den
    /// FARKLI olarak bir sınıfın ham baytlarını Zig'in DOĞRUDAN OKUMASI,
    /// `class_id`nin derleme sırasına bağlı olması nedeniyle GÜVENLİ
    /// DEĞİLDİR.
    fn isFfiSafeClassReturnType(t: Type) bool {
        return t == .class;
    }

    fn isFfiSafeType(t: Type) bool {
        return switch (t) {
            // `ptr` TAM OLARAK bu sınırdan geçmek İÇİN var (bkz. `Type.ptr`in
            // belge notu, Faz 20'nin ikinci artımı) — handle-tabanlı C
            // API'lerinin (`FILE*`/`sqlite3*`) parametre/dönüş tipi.
            .int, .float, .boolean, .str, .none, .ptr => true,
            // `dict[str, str]` (YALNIZCA bu somut örnekleme) — stdlib fazı
            // §D.1 (Keşif 4): çalışma zamanı temsili ZATEN opak bir `ptr`
            // olduğundan (`HeapKind.dict`, ARC başlığı YOK) bunu bir
            // `extern def`e (özellikle `with_rt` işaretli olanlara)
            // geçirmek güvenlidir — Zig tarafı `runtime/collections/dict.zig`nin
            // `Dict` struct'ını DOĞRUDAN `@import` edip alanlarına erişir.
            // Diğer K/V kombinasyonları (int anahtar, sınıf değer, ...)
            // BİLİNÇLİ OLARAK kapsam dışı bırakıldı — v1 yalnızca header
            // gibi dict[str,str] kullanım örneğini hedefliyor.
            .dict => |d| d.key.* == .str and d.value.* == .str,
            // Faz FF.6 (bkz. nox-teknik-spesifikasyon.md §3.65): bilinçli
            // v1 sınırlaması — `Optional[T]` (heap İÇİN etiket-only, ilkel
            // İÇİN KUTULANMIŞ/ARC-yönetimli) bir `extern def` sınırından
            // GEÇEMEZ. `ptr`in AKSİNE hiçbir Optional temsili ARC-DIŞI
            // DEĞİLDİR (heap tarafı BİLE checker seviyesinde "bu bir null
            // olabilir" anlamı taşır, C tarafı bunu YORUMLAYAMAZ).
            .list, .class, .task, .channel, .thread_handle, .thread_channel, .task_local, .func, .optional => false,
        };
    }

    /// `isFfiSafeType`den AYRI: `spawn`ın kapanış paketlemesi (bkz.
    /// codegen.zig, `genSpawnExpr`) yalnızca sabit boyutlu, ARC-DIŞI
    /// değerleri (int/float/bool/str/None) VE `Task[T]`/`Channel[T]`i
    /// (bunlar da ARC-yönetimli DEĞİLDİR — bkz. `HeapKind`in belge notu,
    /// yalnızca bir işaretçi kopyalamak yeterlidir) paketleyebilir. Sınıf/
    /// `list[T]` parametreleri (paketleme ÖNCESİ retain, çağrı SONRASI
    /// release gerektirirdi) v0.1 kapsamı DIŞI bırakıldı.
    ///
    /// **BU FONKSİYON, `registerFunc` ÜZERİNDEN, HER `async def`in KENDİ
    /// PARAMETRE TİPLERİNİ tanım ANINDA (nasıl kullanılacağından
    /// BAĞIMSIZ olarak — `spawn` İLE de, `nox.thread.start` İLE de
    /// başlatılabilir) denetler.** Faz BB.6: `thread_channel` BU YÜZDEN
    /// BURADA DA `true` OLMALIDIR (`Task`/`Channel` İLE AYNI gerekçeyle —
    /// bir `*Scheduler` alanı TAŞIMADIĞINDAN, bkz. `isThreadTransferSafeType`in
    /// AYNI notu) — AKSİ HALDE `nox.thread.start`ın `entry`i BİR
    /// `ThreadChannel[T]` parametresi ASLA ALAMAZDI, ki Katman 2'nin
    /// TÜM AMACI TAM OLARAK BUDUR (bir kanalın `nox.thread.start`ın `arg`ı
    /// olarak çocuk iş parçacığına GEÇİRİLMESİ).
    /// Faz MN.9.4: `self.backend == .llvm` İKEN `list`/`class`/`dict`
    /// DE İZİN VERİLİR — `async_thread.zig`nin `genSpawnExpr`/
    /// `genSpawnWrapper`si `--release` altında (LLVM-only ATOMİK
    /// `qbeAtomicAdd`/`qbeAtomicSub`, MN.1'in ZATEN inşa ettiği) YENİ
    /// retain/release-farkındalıklı kapanış paketleme KAZANDIĞINDAN
    /// (bkz. onların belge notu) — BU GEVŞETME `nox.thread.start`ın
    /// `--release` altında `genSpawnExpr`in AYNI mekanizmasını yeniden
    /// KULLANMASININ (bkz. `genThreadStartExpr`) ÖN KOŞULUDUR: `entry`
    /// bir `async def` OLDUĞUNDAN, KENDİ parametre tipleri BURADA
    /// (ÇAĞRI MEKANİZMASINDAN — `spawn` mı `thread.start` mı —
    /// BAĞIMSIZ, TANIM ANINDA) denetlenir. `.qbe` dalı BİREBİR
    /// DEĞİŞMEDEN kalır.
    fn isSpawnParamSafeType(self: *const Checker, t: Type) bool {
        if (self.backend == .llvm) {
            return switch (t) {
                .int, .float, .boolean, .str, .none, .task, .channel, .ptr, .thread_channel, .task_local, .list, .class, .dict => true,
                .thread_handle, .func, .optional => false,
            };
        }
        return switch (t) {
            .int, .float, .boolean, .str, .none, .task, .channel, .ptr, .thread_channel, .task_local => true,
            // Faz FF.6: bilinçli v1 sınırlaması — `isFfiSafeType`in AYNI
            // gerekçesiyle, `Optional[T]` `spawn`ın kapanış paketlemesinden
            // GEÇEMEZ.
            .list, .class, .dict, .thread_handle, .func, .optional => false,
        };
    }

    /// Faz BB.3 (bkz. nox-teknik-spesifikasyon.md §3.49): `nox.thread.
    /// spawn`ın argüman/dönüş tipi kısıtı — `isSpawnParamSafeType`in AYNI
    /// GÜVENLİ temel kümesi (`int/float/bool/str/none/ptr`), AMA `task`/
    /// `channel`/`thread_handle` BİLİNÇLİ olarak HARİÇ TUTULUR: bunlar
    /// KENDİ zamanlayıcılarına/OS iş parçacıklarına BAĞLIDIR (`Task.
    /// scheduler`/`Channel.scheduler` alanları, bkz. `scheduler.zig`/
    /// `channel.zig`) — BAŞKA bir OS iş parçacığına TAŞINMALARI, o
    /// tutamacın YANLIŞ bir zamanlayıcıya İŞARET ETMESİNE (kullanım
    /// anında ÇÖKME/tanımsız davranışa) yol AÇARDI. `class`/`list`/`dict`
    /// AYNI gerekçeyle (genel özyinelemeli derin-klonlama mekanizması
    /// HENÜZ YOK, bkz. `nox.thread`in modül üstü planı) kapsam DIŞI.
    ///
    /// **`thread_channel` BİLİNÇLİ bir İSTİSNA — BİLE İSİLE DAHİL EDİLİR
    /// (Faz BB.6, bkz. nox-teknik-spesifikasyon.md §3.52):** `Task`/
    /// `Channel`/`ThreadHandle`nin AKSİNE, `ThreadChannel` bir
    /// `*Scheduler` alanı TAŞIMAZ (`thread_channel.zig`nin modül üstü
    /// notu — SAF `page_allocator` + OS pipe'ları + spin-kilit) — BAŞKA
    /// bir OS iş parçacığına GÜVENLE taşınabilir, ZATEN TASARIM AMACI
    /// BUDUR (Katman 2'nin İKİ iş parçacığı ARASINDA gerçek iletişim
    /// sağlaması İÇİN `nox.thread.start`ın `arg`ı olarak GEÇİRİLEBİLMESİ
    /// GEREKİR).
    /// Faz MN.9.4: `self.backend == .llvm` İKEN İKİ AŞAMALI GEVŞETİLİR
    /// (bkz. proje planı, "Gevşetilmiş tip kümesi, İKİ AŞAMALI" tasarım
    /// notu) — `.qbe` DALI BİREBİR DEĞİŞMEDEN kalır (paylaşımsız model,
    /// SIFIR regresyon riski): (1) `isSpawnParamSafeType`nin KÜMESİ
    /// (task/channel/task_local EKLENİR — ÜCRETSİZ, sıradan `spawn`ın
    /// ZATEN yaptığı ARC-siz FFI paketlemeyi yeniden kullanır, ÇÜNKÜ
    /// `--release` altında `nox.thread.start`/`ThreadChannel[T]` ARTIK
    /// AYNI paylaşılan havuza/`Task[T]`/`Channel[T]`ye İNDİRGENİR — bkz.
    /// `genThreadStartExpr`/`genThreadChannelOp`nin `--release` dalları);
    /// (2) `list`/`class`/`dict` (YENİ, `async_thread.zig`nin `--release`-
    /// SINIRLI retain/release-farkındalı kapanış paketlemesi GEREKTİRİR).
    fn isThreadTransferSafeType(self: *const Checker, t: Type) bool {
        if (self.backend == .llvm) {
            return switch (t) {
                .int, .float, .boolean, .str, .none, .ptr, .thread_channel, .task, .channel, .task_local, .list, .class, .dict => true,
                .thread_handle, .func, .optional => false,
            };
        }
        return switch (t) {
            .int, .float, .boolean, .str, .none, .ptr, .thread_channel => true,
            // Faz FF.6: bilinçli v1 sınırlaması — `isFfiSafeType`in AYNI
            // gerekçesiyle, `Optional[T]` `nox.thread.start`ın sınırından
            // GEÇEMEZ. `task_local` da (`task`/`channel` İLE AYNI
            // gerekçeyle — per-fiber depolama BAŞKA bir OS iş parçacığının
            // KENDİ fiber ağacına ANLAMLI biçimde taşınamaz) HARİÇ.
            .list, .class, .dict, .task, .channel, .thread_handle, .task_local, .func, .optional => false,
        };
    }

    fn registerFunc(self: *Checker, fd: ast.FuncDef) TypeError!void {
        // Bulundu (bkz. proje belleği "nox.http gzip düzeltmesi + dil
        // eksikleri" görevi): Nox'ta bir `def main()` sözleşmesi YOK — üst
        // düzey deyimler ZATEN programın giriş noktasıdır (bkz. nox-teknik-
        // spesifikasyon.md'nin `async def main()` ÖRNEĞİYLE İLGİLİ AYNI notu,
        // §3.21 civarı). `codegen.zig`nin
        // `genFunction`ı ÜST DÜZEY fonksiyon isimlerini OLDUĞU GİBİ (mangling
        // OLMADAN) bir QBE/asm sembolüne yazar (bkz. `genFunction`in
        // `export function ... ${s}(...)` satırı) — modülün KENDİSİ de
        // (üst düzey deyimler) TAM OLARAK `main` sembolüne (C giriş noktası,
        // `_main`) derlenir (bkz. `in_main`). Kullanıcı AYRICA `def main():`
        // yazarsa İKİSİ AYNI sembole ÇAKIŞIR — ÖNCEDEN bu, `cc`nin ham
        // "sembol '_main' zaten tanımlı" hatasına kadar (derleme SONUNA)
        // fark edilmeden ULAŞIYORDU (GERÇEKTEN gözlemlendi). Burada ERKEN
        // VE açık bir tanılamayla reddedilir.
        if (std.mem.eql(u8, fd.name, "main")) {
            return self.fail(error.DuplicateDefinition, "'main' ayrılmış bir isimdir: Nox'ta 'def main()' sözleşmesi yok, üst düzey deyimler zaten programın giriş noktasıdır — bu fonksiyonu başka bir adla tanımlayın", .{});
        }
        if (self.functions.contains(fd.name) or self.generic_functions.contains(fd.name)) {
            return self.fail(error.DuplicateDefinition, "fonksiyon zaten tanımlı: {s}", .{fd.name});
        }
        // Generic bir fonksiyonun (açık `[T]` VEYA bir protokol tipli
        // parametre/dönüş aracılığıyla ÖRTÜK) parametre/dönüş tipleri somut
        // olmayan adlara başvurabilir — bu yüzden normal `typeExprToType`
        // çözümlemesi burada ATLANIR. Ham AST (etkin tip parametre listesiyle
        // birlikte), ilk somut çağrı sitesinde `instantiateGeneric` tarafından
        // kullanılmak üzere saklanır (bkz. Faz 10/11).
        const effective_type_params = try self.computeEffectiveTypeParams(fd);
        if (effective_type_params.len > 0) {
            var deferred = fd;
            deferred.type_params = effective_type_params;
            try self.generic_functions.put(self.allocator, fd.name, deferred);
            return;
        }
        const params = try self.allocator.alloc(Type, fd.params.len);
        for (fd.params, 0..) |p, i| params[i] = try self.typeExprToType(p.type_expr);
        const ret = try self.typeExprToType(fd.return_type);
        if (fd.is_async) {
            // `spawn`ın argümanları codegen tarafından bir kapanış (closure)
            // struct'ına PAKETLENİR (bkz. nox-teknik-spesifikasyon.md §3.21,
            // aşama 4) — bu paketleme, sınıf/liste gibi ARC-yönetimli
            // parametreler için (paketleme ÖNCESİ retain, çağrı SONRASI
            // release gerektirirdi) v0.1 kapsamı DIŞI bırakıldı; DÖNÜŞ tipi
            // (Task[T]'nin T'si) bu kısıta TABİ DEĞİLDİR (dönüş zaten sıfır
            // maliyetli bir taşımadır, ekstra paketleme gerekmez).
            for (fd.params, 0..) |p, i| {
                if (!self.isSpawnParamSafeType(params[i])) {
                    return self.fail(error.TypeMismatch, "'async def {s}': parametre '{s}' desteklenmeyen bir tipte (yalnızca int/float/bool/str/None/Task[T]/Channel[T]/ThreadChannel[T] parametreleri paketleyebilir, --release altında ayrıca list/class/dict)", .{ fd.name, p.name });
                }
            }
        }
        try self.functions.put(self.allocator, fd.name, .{ .params = params, .return_type = ret });
        if (fd.is_async) try self.async_functions.put(self.allocator, fd.name, {});
        if (fd.decorators.len > 0) try self.registerDecorators(fd, params, ret);
    }

    /// Faz 1 decorator: `registerFunc`in AYIRDIĞI (sinyal amaçlı) alt
    /// adım — `fd.decorators`nin HER girdisi İçin (a) argümanların
    /// YALNIZCA string LİTERALİ olduğunu doğrular (`hpy_call`nin AYNI
    /// deseni, bkz. onun belge notu), (b) fonksiyonu `functions_used_as_
    /// value`e EKLEYEREK codegen'in bir trampoline ÜRETMESİNİ sağlar
    /// (`resolveIdentifierAsFunctionValue`in AYNI mekanizması), (c) imza
    /// TAM OLARAK `(ctx: Context) -> HttpResponse` İSE `is_handler_shaped`
    /// bayrağını işaretler (bkz. `DecoratedFuncInfo`nin belge notu).
    fn registerDecorators(self: *Checker, fd: ast.FuncDef, params: []const Type, ret: Type) TypeError!void {
        // `Context`/`HttpResponse` (`stdlib/nox/router.nox`/`nox/http.nox`de
        // TANIMLI), `module_loader.zig`nin HER içe aktarılan modülün üst-
        // düzey adlarını mangle ETME kuralına TABİDİR (ör. "nox_router_
        // Context") — bu YÜZDEN ham "Context"/"HttpResponse" DİZE
        // karşılaştırması YANLIŞTIR. Bunun yerine `self.from_imports`ın
        // (PROGRAM GENELİNDE PAYLAŞILAN, `resolveIdentifierAsFunctionValue`/
        // `typeExprToType`in AYNI YEDEK mekanizması) GEÇERLİ mangled adını
        // ARANIR — bu isimler YALNIZCA `stdlib/nox/reflect.nox`nin KENDİSİ
        // `from nox.router import Context`/`from nox.http import
        // HttpResponse` yaptığı İçin haritada BULUNUR (o dosya HER ZAMAN
        // ithal edilir, bkz. onun modül üstü notu).
        const context_name = self.from_imports.get("Context") orelse "Context";
        const http_response_name = self.from_imports.get("HttpResponse") orelse "HttpResponse";
        const is_handler_shaped = params.len == 1 and
            params[0] == .class and std.mem.eql(u8, params[0].class, context_name) and
            ret == .class and std.mem.eql(u8, ret.class, http_response_name);
        for (fd.decorators) |dec| {
            const arg_values = try self.allocator.alloc([]const u8, dec.args.len);
            for (dec.args, 0..) |a, i| {
                if (a != .string_lit) {
                    return self.fail(error.TypeMismatch, "decorator '@{s}' argümanı {d} yalnızca bir string LİTERALİ olabilir (fonksiyon: {s})", .{ dec.name, i + 1, fd.name });
                }
                arg_values[i] = a.string_lit;
            }
            if (is_handler_shaped) try self.functions_used_as_value.put(self.allocator, fd.name, {});
            try self.decorated_functions.append(self.allocator, .{
                .func_name = fd.name,
                .decorator_name = dec.name,
                .args = arg_values,
                .is_handler_shaped = is_handler_shaped,
            });
        }
    }

    /// `fd`nin GERÇEK (etkin) tip parametre listesini hesaplar: açıkça
    /// bildirilenler (`fd.type_params`, ör. `[T]`) BİRLEŞİMİ parametre/dönüş
    /// tiplerinde DOĞRUDAN (yalnızca `list[...]` içinde değil, en dış
    /// düzeyde de) kullanılan protokol adlarıyla. Bir protokol adı, çağrı
    /// sitesinde somut bir sınıfa çözümlenmesi GEREKEN örtük bir tip
    /// parametresi gibi davranır (bkz. `unifyTypeExpr`'in protokol kontrolü).
    fn computeEffectiveTypeParams(self: *Checker, fd: ast.FuncDef) TypeError![]const []const u8 {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        for (fd.type_params) |tp| try names.append(self.allocator, tp);
        for (fd.params) |p| try self.collectProtocolNames(p.type_expr, &names);
        try self.collectProtocolNames(fd.return_type, &names);
        return names.toOwnedSlice(self.allocator);
    }

    fn collectProtocolNames(self: *Checker, te: ast.TypeExpr, names: *std.ArrayListUnmanaged([]const u8)) TypeError!void {
        switch (te) {
            .simple => |name| {
                if (self.protocols.contains(name) and !containsName(names.items, name)) {
                    try names.append(self.allocator, name);
                }
            },
            .generic => |g| for (g.args) |a| try self.collectProtocolNames(a, names),
            .func_type => |ft| {
                for (ft.params) |p| try self.collectProtocolNames(p, names);
                try self.collectProtocolNames(ft.return_type.*, names);
            },
            .optional => |inner| try self.collectProtocolNames(inner.*, names),
            // Nitelikli (`pkg.module.X`) bir tip adı ASLA bir protokol
            // adına eşit OLAMAZ (protokoller yalnızca ÇIPLAK isimle
            // tanımlanır) — yapılacak bir şey yok.
            .qualified => {},
        }
    }

    fn containsName(list: []const []const u8, name: []const u8) bool {
        for (list) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    /// `segments`i `sep` ile birleştirir (bkz. `checkModule`in `.import_stmt`
    /// kolu — `imported_modules` anahtarları için `"."`, `tryResolveQualifiedCall`
    /// için mangled sembol adı olarak `"_"`).
    fn joinSegments(self: *Checker, segments: []const []const u8, sep: u8) TypeError![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        for (segments, 0..) |seg, i| {
            if (i != 0) try buf.append(self.allocator, sep);
            try buf.appendSlice(self.allocator, seg);
        }
        return buf.toOwnedSlice(self.allocator);
    }

    /// `expr`in TAMAMEN `.identifier`/`.attribute` düğümlerinden oluşan bir
    /// nokta zinciri (ör. `nox.http.get`) olup olmadığını dener; öyleyse
    /// segmentleri (SOLDAN SAĞA sırayla) `out`a ekleyip `true` döner. Bir
    /// `.call`/`.index`/vb. içeren bir zincir İÇİN (ör. `f().method`) `false`
    /// döner — bu durumda `tryResolveQualifiedCall` sessizce vazgeçer,
    /// MEVCUT (değişmemiş) metod-çağrısı çözümlemesine bırakır.
    fn flattenDottedPath(self: *Checker, expr: ast.Expr, out: *std.ArrayListUnmanaged([]const u8)) TypeError!bool {
        switch (expr) {
            .identifier => |name| {
                try out.append(self.allocator, name);
                return true;
            },
            .attribute => |a| {
                if (!try self.flattenDottedPath(a.obj.*, out)) return false;
                try out.append(self.allocator, a.attr);
                return true;
            },
            else => return false,
        }
    }

    /// Faz U.3: `segments[0]` bilinen bir modül TAKMA ADI (`self.module_aliases`)
    /// İSE, onu HEDEF modülün TAM segment dizisiyle DEĞİŞTİRİR (ör.
    /// `import nox.http as h` sonrası `["h","get"]` → `["nox","http","get"]`)
    /// — geri kalan çözümleme (module_path/mangled hesaplaması) bu genişletilmiş
    /// listeyle DEĞİŞMEDEN çalışır. Takma ad EŞLEŞMİYORSA `segments` OLDUĞU
    /// GİBİ döner (kopyasız — yaygın durum İÇİN sıfır ek tahsis).
    fn substituteAlias(self: *Checker, segments: []const []const u8) TypeError![]const []const u8 {
        if (segments.len == 0) return segments;
        const target = self.module_aliases.get(segments[0]) orelse return segments;
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        try out.appendSlice(self.allocator, target);
        try out.appendSlice(self.allocator, segments[1..]);
        return out.toOwnedSlice(self.allocator);
    }

    /// Faz U.3: `tryResolveQualifiedCall`in `mangled` sembolü BULUNDUKTAN
    /// SONRAKİ ORTAK gövdesi (fonksiyon/kurucu ara + argüman denetimi +
    /// callee'yi YERİNDE yeniden yaz) — hem noktalı nitelikli çağrılar
    /// (`X.Y.foo(...)`) hem `from X.Y import foo` İLE bağlanan ÇIPLAK
    /// çağrılar (`foo(...)`) TARAFINDAN paylaşılır (bkz. `checkCall`in
    /// `.identifier` dalındaki `self.from_imports` kullanımı).
    fn resolveMangledCall(self: *Checker, ctx: *FnCtx, c: ast.Call, mangled: []const u8, not_found_msg: []const u8) TypeError!Type {
        // Faz III.8 (bkz. nox-teknik-spesifikasyon.md §3.69) — `nox.random.
        // shuffle(xs)` gibi NİTELİKLİ bir çağrının bir GENERIC fonksiyona
        // (`shuffle[T]`) İŞARET ETTİĞİ durum: module_loader `fd.name`i ZATEN
        // mangled hâle (`nox_random_shuffle`) getirdiğinden, `generic_
        // functions` haritası da BU mangled adla anahtarlanır (bkz. `.identifier`
        // dalının AYNI, ÇIPLAK-çağrı İÇİN ÇALIŞAN kontrolü) — ama BU fonksiyon
        // (nitelikli çağrı yolu) ÖNCEDEN yalnızca `self.functions`/`self.
        // classes`e bakıyordu, generic'leri HİÇ KONTROL ETMİYORDU (GERÇEKTEN
        // denenip "modülün 'shuffle' adlı üyesi yok" hatasıyla YAKALANDI).
        if (self.generic_functions.get(mangled)) |gfd| {
            return try self.instantiateGeneric(ctx, gfd, c);
        }
        if (self.functions.get(mangled)) |sig| {
            if (self.async_functions.contains(mangled)) {
                return self.fail(error.TypeMismatch, "'{s}' bir 'async def' fonksiyonudur, yalnızca 'spawn' ile başlatılabilir", .{mangled});
            }
            try self.checkArgs(ctx, sig.params, c.args, mangled);
            c.callee.* = .{ .identifier = mangled };
            return sig.return_type;
        }
        if (self.classes.contains(mangled)) {
            const info = self.classes.get(mangled).?;
            const init_sig = info.init_sig orelse FuncSig{ .params = &.{}, .return_type = .none };
            try self.checkArgs(ctx, init_sig.params, c.args, mangled);
            c.callee.* = .{ .identifier = mangled };
            return Type{ .class = mangled };
        }
        return self.fail(error.UndefinedFunction, "{s}", .{not_found_msg});
    }

    /// `c`nin callee'sinin `import` edilmiş bir stdlib modülüne noktalı
    /// nitelikli bir erişim (ör. `nox.http.get(url)`) olup OLMADIĞINI dener.
    /// Öyleyse: tüm segmentler `"_"` ile birleştirilip (`"nox_http_get"`)
    /// karşılık gelen fonksiyon/kurucu `self.functions`/`self.classes`de
    /// (main.zig'in stdlib birleştirmesi tarafından ZATEN bu mangled adla
    /// kaydedilmiş olmalı — bkz. modül üstü not) aranır; bulunursa normal
    /// argüman denetimi yapılır VE **çağrının callee'si YERİNDE mangled
    /// isme yeniden yazılır** (Faz 10'un `instantiateGeneric`iyle AYNI
    /// desen) — böylece codegen'in HİÇBİR ek işlem yapmasına gerek kalmaz.
    /// Zincir bir import'a karşılık GELMİYORSA (ör. sıradan `p.scale(2)`
    /// bir yerel değişken üzerinde) `null` döner — çağıran MEVCUT metod-
    /// çağrısı çözümlemesine devam eder.
    fn tryResolveQualifiedCall(self: *Checker, ctx: *FnCtx, c: ast.Call) TypeError!?Type {
        var raw_segments: std.ArrayListUnmanaged([]const u8) = .empty;
        if (!(try self.flattenDottedPath(c.callee.*, &raw_segments))) return null;
        if (raw_segments.items.len < 2) return null;
        const segments = try self.substituteAlias(raw_segments.items);

        const module_path = try self.joinSegments(segments[0 .. segments.len - 1], '.');
        if (!self.imported_modules.contains(module_path)) return null;

        const mangled = try self.joinSegments(segments, '_');
        const not_found_msg = try std.fmt.allocPrint(self.allocator, "'{s}' modülünün '{s}' adlı bir üyesi yok", .{ module_path, segments[segments.len - 1] });
        return try self.resolveMangledCall(ctx, c, mangled, not_found_msg);
    }

    /// `nox.http.serve`/`serve_fd`/`serve_multicore`nin ÜÇÜNÜN de paylaştığı
    /// `handle` doğrulaması — Faz DD.1 (bkz. nox-teknik-spesifikasyon.md
    /// §3.60) İçin `tryResolveHttpServeCall`in (stdlib fazı §D.1.6, §3.34)
    /// ORİJİNAL gövdesinden ÇIKARILDI, kod TEKRARINI önlemek İçin. `spawn`ın
    /// "çıplak isim" çözümüyle (bkz. `.spawn_expr` dalı) AYNI gerekçeyle:
    /// `handle` birinci sınıf bir DEĞER olarak GEÇİRİLEMEZ (Nox'ta
    /// fonksiyonlar değer DEĞİLDİR), bu yüzden normal argüman tipi
    /// denetiminden (`checkArgs`/`checkExpr`) GEÇMEDEN doğrudan bir
    /// fonksiyon ADI olarak doğrulanır. `fn_label`, hata mesajlarında
    /// hangi çağrı formunun (`'nox.http.serve'`/`'nox.http.serve_fd'`/
    /// `'nox.http.serve_multicore'`) başarısız olduğunu BELİRTMEK İçindir.
    fn validateHttpHandler(self: *Checker, fn_label: []const u8, handle_expr: ast.Expr) TypeError!void {
        const handle_name = switch (handle_expr) {
            .identifier => |n| n,
            else => return self.fail(error.NotCallable, "'{s}': 'handle' doğrudan bir fonksiyon adı olmalı (metod/lambda henüz desteklenmiyor)", .{fn_label}),
        };
        if (self.async_functions.contains(handle_name)) {
            return self.fail(error.TypeMismatch, "'{s}': 'handle' ('{s}') bir 'async def' OLAMAZ (bağlantı işleyicisi zaten kendi fiber'ında senkron çalışır)", .{ fn_label, handle_name });
        }
        const sig = self.functions.get(handle_name) orelse
            return self.fail(error.UndefinedFunction, "tanımsız fonksiyon: {s}", .{handle_name});
        if (sig.params.len != 1) {
            return self.fail(error.TypeMismatch, "'{s}': 'handle' TAM OLARAK bir parametre almalı (bir HttpRequest)", .{fn_label});
        }
        const req_class = switch (sig.params[0]) {
            .class => |n| n,
            else => return self.fail(error.TypeMismatch, "'{s}': 'handle'in parametresi 'HttpRequest' olmalı", .{fn_label}),
        };
        if (!std.mem.eql(u8, req_class, "nox_http_HttpRequest")) {
            return self.fail(error.TypeMismatch, "'{s}': 'handle'in parametresi 'HttpRequest' olmalı", .{fn_label});
        }
        const resp_class = switch (sig.return_type) {
            .class => |n| n,
            else => return self.fail(error.TypeMismatch, "'{s}': 'handle' bir 'HttpResponse' döndürmeli", .{fn_label}),
        };
        if (!std.mem.eql(u8, resp_class, "nox_http_HttpResponse")) {
            return self.fail(error.TypeMismatch, "'{s}': 'handle' bir 'HttpResponse' döndürmeli", .{fn_label});
        }
    }

    /// `nox.http.serve(port, handle[, max_connections])` — stdlib fazı
    /// §D.1.6'nın özel yerleşiği (bkz. nox-teknik-spesifikasyon.md §3.34).
    /// `tryResolveQualifiedCall`DAN ÖNCE çağrılmalıdır (o, `handle`i
    /// SIRADAN bir argüman gibi `checkArgs`a göndermeye çalışırdı,
    /// "tanımsız değişken" hatasıyla BAŞARISIZ olurdu). Callee TAM OLARAK
    /// `nox.http.serve` DEĞİLSE (ya da `nox.http` HİÇ `import` edilmemişse)
    /// `null` döner — çağıran MEVCUT `tryResolveQualifiedCall`a (`nox.
    /// http`in DİĞER üyeleri İÇİN, DEĞİŞMEMİŞ) devam eder.
    fn tryResolveHttpServeCall(self: *Checker, ctx: *FnCtx, c: ast.Call) TypeError!?Type {
        if (!(try self.matchesNoxHttpCall(c, "serve"))) return null;

        if (c.args.len != 2 and c.args.len != 3) {
            return self.fail(error.ArgumentCountMismatch, "'nox.http.serve' 2 ya da 3 argüman alır: (port, handle[, max_connections])", .{});
        }
        if (try self.checkExpr(ctx, c.args[0]) != .int) {
            return self.fail(error.TypeMismatch, "'nox.http.serve': 'port' bir 'int' olmalı", .{});
        }
        if (c.args.len == 3) {
            if (try self.checkExpr(ctx, c.args[2]) != .int) {
                return self.fail(error.TypeMismatch, "'nox.http.serve': 'max_connections' bir 'int' olmalı", .{});
            }
        }
        try self.validateHttpHandler("nox.http.serve", c.args[1]);
        return .none;
    }

    /// Faz DD.1 (bkz. nox-teknik-spesifikasyon.md §3.60) — `nox.http.
    /// serve_fd(fd: int, handle[, max_connections])`: `nox.http.serve`nin
    /// AYNI şekli, `port` YERİNE ZATEN dinlemede olan (`nox.http.listen`
    /// İLE elde edilmiş) ham bir dosya tanımlayıcısı alır — çok-çekirdekli
    /// sunumun BİRLEŞTİRİLEBİLİR ilkellerinden biri (`nox.thread.start`
    /// İLE birleştirilerek TEK bir dinleme soketi N bağımsız iş
    /// parçacığına dağıtılabilir).
    fn tryResolveHttpServeFdCall(self: *Checker, ctx: *FnCtx, c: ast.Call) TypeError!?Type {
        if (!(try self.matchesNoxHttpCall(c, "serve_fd"))) return null;

        if (c.args.len != 2 and c.args.len != 3) {
            return self.fail(error.ArgumentCountMismatch, "'nox.http.serve_fd' 2 ya da 3 argüman alır: (fd, handle[, max_connections])", .{});
        }
        if (try self.checkExpr(ctx, c.args[0]) != .int) {
            return self.fail(error.TypeMismatch, "'nox.http.serve_fd': 'fd' bir 'int' olmalı", .{});
        }
        if (c.args.len == 3) {
            if (try self.checkExpr(ctx, c.args[2]) != .int) {
                return self.fail(error.TypeMismatch, "'nox.http.serve_fd': 'max_connections' bir 'int' olmalı", .{});
            }
        }
        try self.validateHttpHandler("nox.http.serve_fd", c.args[1]);
        return .none;
    }

    /// Faz DD.1 (bkz. nox-teknik-spesifikasyon.md §3.60) — `nox.http.
    /// serve_multicore(port: int, handle, num_threads: int[,
    /// max_connections])`: `nox.http.listen`+`nox.thread.start`+`nox.
    /// http.serve_fd`nin (yukarıdaki) el ile birleştirilmesinin
    /// derleyici tarafından ÜRETİLEN kolaylık sarmalayıcısı — `port` bir
    /// kez dinlemeye alınır, `num_threads - 1` ek `nox.thread` worker'ı
    /// AYNI paylaşılan fd üzerinde sunum yapar, ÇAĞIRAN iş parçacığının
    /// KENDİSİ Nninci worker OLUR (bugünkü `nox.http.serve`nin "çağrı
    /// sonsuza kadar bloke olur" sözleşmesiyle TUTARLI).
    ///
    /// **`max_connections`in KESİNLİKLE bir tamsayı LİTERALİ olması
    /// gerekir** (`serve`/`serve_fd`nin daha gevşek "herhangi bir int
    /// ifadesi" kuralından KASITLI bir sapma): bu değer, codegen
    /// TARAFINDAN HEM çağıran iş parçacığının HEM SENTEZLENEN worker
    /// fonksiyonunun gövdesine DERLEME-ZAMANI bir metin sabiti olarak
    /// GÖMÜLÜR (bkz. `codegen.zig`nin `genHttpServeMulticore`si) — bir
    /// ÇALIŞMA-ZAMANI ifadesi olsaydı, worker başına AYRI bir aktarım
    /// kanalı gerekirdi (`nox_thread_spawn`ın TEK-argümanlı sözleşmesi
    /// ZATEN `fd`yi taşıyor).
    fn tryResolveHttpServeMulticoreCall(self: *Checker, ctx: *FnCtx, c: ast.Call) TypeError!?Type {
        if (!(try self.matchesNoxHttpCall(c, "serve_multicore"))) return null;

        if (c.args.len != 3 and c.args.len != 4) {
            return self.fail(error.ArgumentCountMismatch, "'nox.http.serve_multicore' 3 ya da 4 argüman alır: (port, handle, num_threads[, max_connections])", .{});
        }
        if (try self.checkExpr(ctx, c.args[0]) != .int) {
            return self.fail(error.TypeMismatch, "'nox.http.serve_multicore': 'port' bir 'int' olmalı", .{});
        }
        if (try self.checkExpr(ctx, c.args[2]) != .int) {
            return self.fail(error.TypeMismatch, "'nox.http.serve_multicore': 'num_threads' bir 'int' olmalı", .{});
        }
        if (c.args.len == 4) {
            if (c.args[3] != .int_lit) {
                return self.fail(error.TypeMismatch, "'nox.http.serve_multicore': 'max_connections' sabit bir tamsayı olmalı (bir DEĞİŞKEN/ifade değil — derleme zamanında TÜM worker fonksiyonlarına gömülür)", .{});
            }
        }
        try self.validateHttpHandler("nox.http.serve_multicore", c.args[1]);
        return .none;
    }

    /// `validateHttpHandler`in WebSocket eşleniği — Faz "sunucu-tarafı
    /// WebSocket Upgrade" (bkz. plan dosyası): `ws_handle` de `handle`
    /// GİBİ çıplak bir fonksiyon ADI olmalı (birinci sınıf değer OLARAK
    /// GEÇİRİLEMEZ), TEK farkı: parametresi `HttpRequest` DEĞİL
    /// `WebSocketServerConn`dir ve `HttpResponse` DEĞİL `None` döner (bir
    /// WS oturumunun "yanıt nesnesi" YOKTUR).
    fn validateWsHandler(self: *Checker, fn_label: []const u8, handle_expr: ast.Expr) TypeError!void {
        const handle_name = switch (handle_expr) {
            .identifier => |n| n,
            else => return self.fail(error.NotCallable, "'{s}': 'ws_handle' doğrudan bir fonksiyon adı olmalı (metod/lambda henüz desteklenmiyor)", .{fn_label}),
        };
        if (self.async_functions.contains(handle_name)) {
            return self.fail(error.TypeMismatch, "'{s}': 'ws_handle' ('{s}') bir 'async def' OLAMAZ (WS oturumu zaten kendi fiber'ında senkron çalışır)", .{ fn_label, handle_name });
        }
        const sig = self.functions.get(handle_name) orelse
            return self.fail(error.UndefinedFunction, "tanımsız fonksiyon: {s}", .{handle_name});
        if (sig.params.len != 1) {
            return self.fail(error.TypeMismatch, "'{s}': 'ws_handle' TAM OLARAK bir parametre almalı (bir WebSocketServerConn)", .{fn_label});
        }
        const conn_class = switch (sig.params[0]) {
            .class => |n| n,
            else => return self.fail(error.TypeMismatch, "'{s}': 'ws_handle'in parametresi 'WebSocketServerConn' olmalı", .{fn_label}),
        };
        if (!std.mem.eql(u8, conn_class, "nox_websocket_WebSocketServerConn")) {
            return self.fail(error.TypeMismatch, "'{s}': 'ws_handle'in parametresi 'WebSocketServerConn' olmalı", .{fn_label});
        }
        if (sig.return_type != .none) {
            return self.fail(error.TypeMismatch, "'{s}': 'ws_handle' 'None' döndürmeli", .{fn_label});
        }
    }

    /// Faz "sunucu-tarafı TLS + WebSocket Upgrade" (bkz. plan dosyası §6,
    /// TAM 12'lik isim matrisi): `serve`/`serve_fd`/`serve_multicore`nin
    /// `_tls`/`_ws`/`_ws_tls` VARYANTLARININ HEPSİ İçin PAYLAŞILAN TEK bir
    /// çözümleyici — argümanların SIRASI (bkz. plan dosyasının şeması)
    /// SABİT bir formüle uyar: `[port|fd, handle, (num_threads varsa),
    /// (ws_handle varsa), (cert_path, key_path varsa), (max_connections
    /// isteğe bağlı)]`. Var OLAN 3 çıplak `serve`/`serve_fd`/`serve_
    /// multicore` fonksiyonuna DOKUNULMADI (hata mesajları/testler İLE
    /// TAM UYUMLULUK İçin) — bu, YALNIZCA 9 YENİ varyant İçin kullanılır.
    fn tryResolveHttpServeGeneric(
        self: *Checker,
        ctx: *FnCtx,
        c: ast.Call,
        name: []const u8,
        is_multicore: bool,
        want_ws: bool,
        want_tls: bool,
    ) TypeError!?Type {
        if (!(try self.matchesNoxHttpCall(c, name))) return null;
        const fn_label = try std.fmt.allocPrint(self.allocator, "nox.http.{s}", .{name});

        var next: usize = 2;
        const num_threads_idx: ?usize = if (is_multicore) blk: {
            const i = next;
            next += 1;
            break :blk i;
        } else null;
        const ws_idx: ?usize = if (want_ws) blk: {
            const i = next;
            next += 1;
            break :blk i;
        } else null;
        const cert_idx: ?usize = if (want_tls) blk: {
            const i = next;
            next += 2;
            break :blk i;
        } else null;
        const key_idx: ?usize = if (cert_idx) |ci| ci + 1 else null;
        const min_args = next;
        const max_args = next + 1;

        if (c.args.len != min_args and c.args.len != max_args) {
            return self.fail(error.ArgumentCountMismatch, "'{s}' {d} ya da {d} argüman alır", .{ fn_label, min_args, max_args });
        }
        if (try self.checkExpr(ctx, c.args[0]) != .int) {
            return self.fail(error.TypeMismatch, "'{s}': '{s}' bir 'int' olmalı", .{ fn_label, if (is_multicore) "port" else "port/fd" });
        }
        if (num_threads_idx) |i| {
            if (try self.checkExpr(ctx, c.args[i]) != .int) {
                return self.fail(error.TypeMismatch, "'{s}': 'num_threads' bir 'int' olmalı", .{fn_label});
            }
        }
        if (c.args.len == max_args) {
            const max_idx = max_args - 1;
            if (is_multicore) {
                if (c.args[max_idx] != .int_lit) {
                    return self.fail(error.TypeMismatch, "'{s}': 'max_connections' sabit bir tamsayı olmalı (derleme zamanında worker fonksiyonlarına gömülür)", .{fn_label});
                }
            } else if (try self.checkExpr(ctx, c.args[max_idx]) != .int) {
                return self.fail(error.TypeMismatch, "'{s}': 'max_connections' bir 'int' olmalı", .{fn_label});
            }
        }
        if (cert_idx) |ci| {
            if (try self.checkExpr(ctx, c.args[ci]) != .str) {
                return self.fail(error.TypeMismatch, "'{s}': 'cert_path' bir 'str' olmalı", .{fn_label});
            }
            if (try self.checkExpr(ctx, c.args[key_idx.?]) != .str) {
                return self.fail(error.TypeMismatch, "'{s}': 'key_path' bir 'str' olmalı", .{fn_label});
            }
        }
        try self.validateHttpHandler(fn_label, c.args[1]);
        if (ws_idx) |wi| {
            try self.validateWsHandler(fn_label, c.args[wi]);
        }
        return .none;
    }

    /// v1.32.0 (bkz. nox-teknik-spesifikasyon.md §3.98): `matchesNoxHttpCall`
    /// (aşağıda) VE eskiden `tryResolveThreadSpawnCall`/`tryResolvePoolRunCall`
    /// İÇİNE AYRI AYRI İNLİNE edilmiş İKİ KOPYASININ birleştiği TEK, alias-
    /// farkında (`substituteAlias` ÜZERİNDEN) eşleştirici — callee TAM OLARAK
    /// `nox.<module>.<name>` şeklinde (üç segmentli) VE `nox.<module>` İTHAL
    /// edilmişse `true`. Codegen'in KENDİ `matchesNoxAttr`i (async_thread.zig,
    /// Faz P1.6) İLE AYNI ROLÜ oynar AMA (checker/codegen'in AYRI modül
    /// grafikleri OLMASI yüzünden — bkz. `types.zig`nin `Backend` notu)
    /// PAYLAŞILAMAZ; BURADAKİ alias-farkındalığı codegen'İN sürümünde YOK
    /// (`checkCall`in `.attribute` kolu bu YÜZDEN eşleşen bir çağrının
    /// callee'sini KANONİK forma yeniden yazar, bkz. `rewriteIntrinsicCalleeToCanonical`).
    fn matchesNoxAttrCall(self: *Checker, c: ast.Call, module: []const u8, name: []const u8) TypeError!bool {
        var raw_segments: std.ArrayListUnmanaged([]const u8) = .empty;
        if (!(try self.flattenDottedPath(c.callee.*, &raw_segments))) return false;
        if (raw_segments.items.len < 2) return false;
        const segments = try self.substituteAlias(raw_segments.items);
        if (segments.len != 3) return false;
        if (!std.mem.eql(u8, segments[0], "nox")) return false;
        if (!std.mem.eql(u8, segments[1], module)) return false;
        if (!std.mem.eql(u8, segments[2], name)) return false;
        const module_path = try self.joinSegments(segments[0..2], '.');
        return self.imported_modules.contains(module_path);
    }

    /// `matchIntrinsicKind`in (codegen_qbe/async_thread.zig, Faz P1.6) çekirdek
    /// çözümleme mantığı — callee TAM OLARAK `nox.http.<name>` şeklinde (üç
    /// segmentli, `nox`/`http`/`name`) VE `nox.http` İTHAL edilmişse `true`.
    fn matchesNoxHttpCall(self: *Checker, c: ast.Call, name: []const u8) TypeError!bool {
        return self.matchesNoxAttrCall(c, "http", name);
    }

    /// v1.32.0: codegen'in `IntrinsicKind`/`intrinsic_table`/`matchIntrinsicKind`
    /// üçlüsünün (async_thread.zig:128-174) checker'a ÖZEL, BAĞIMSIZ kopyası
    /// — `checker.zig`nin `codegen_qbe`ye import EDİLEMEMESİ yüzünden (gerçek
    /// bir döngüsel bağımlılık olurdu, bkz. plan dosyası "Tasarım kararı")
    /// PAYLAŞILAMAZ, YAPISAL olarak birebir aynı tutulur. ESKİDEN `checkCall`
    /// (satır ~3163) `.attribute` kolunda 14 sıralı `tryResolveX` çağrısı
    /// vardı (3 çıplak + 9 generic + thread_start + pool_run) — ARTIK TEK bir
    /// `matchIntrinsicKind` çağrısı + switch.
    const IntrinsicKind = enum {
        http_serve,
        http_serve_fd,
        http_serve_multicore,
        http_serve_tls,
        http_serve_ws,
        http_serve_ws_tls,
        http_serve_fd_tls,
        http_serve_fd_ws,
        http_serve_fd_ws_tls,
        http_serve_multicore_tls,
        http_serve_multicore_ws,
        http_serve_multicore_ws_tls,
        thread_start,
        pool_run,
    };

    const IntrinsicEntry = struct { module: []const u8, name: []const u8, kind: IntrinsicKind };

    const intrinsic_table = [_]IntrinsicEntry{
        .{ .module = "http", .name = "serve", .kind = .http_serve },
        .{ .module = "http", .name = "serve_fd", .kind = .http_serve_fd },
        .{ .module = "http", .name = "serve_multicore", .kind = .http_serve_multicore },
        .{ .module = "http", .name = "serve_tls", .kind = .http_serve_tls },
        .{ .module = "http", .name = "serve_ws", .kind = .http_serve_ws },
        .{ .module = "http", .name = "serve_ws_tls", .kind = .http_serve_ws_tls },
        .{ .module = "http", .name = "serve_fd_tls", .kind = .http_serve_fd_tls },
        .{ .module = "http", .name = "serve_fd_ws", .kind = .http_serve_fd_ws },
        .{ .module = "http", .name = "serve_fd_ws_tls", .kind = .http_serve_fd_ws_tls },
        .{ .module = "http", .name = "serve_multicore_tls", .kind = .http_serve_multicore_tls },
        .{ .module = "http", .name = "serve_multicore_ws", .kind = .http_serve_multicore_ws },
        .{ .module = "http", .name = "serve_multicore_ws_tls", .kind = .http_serve_multicore_ws_tls },
        .{ .module = "thread", .name = "start", .kind = .thread_start },
        .{ .module = "thread", .name = "pool_run", .kind = .pool_run },
    };

    fn matchIntrinsicKind(self: *Checker, c: ast.Call) TypeError!?IntrinsicEntry {
        for (intrinsic_table) |entry| {
            if (try self.matchesNoxAttrCall(c, entry.module, entry.name)) return entry;
        }
        return null;
    }

    /// v1.32.0 (bkz. nox-teknik-spesifikasyon.md §3.98, "alias-uyuşmazlığı
    /// düzeltmesi"): `matchIntrinsicKind` bir eşleşme bulduğunda (ALIAS
    /// ÜZERİNDEN de olsa, ör. `import nox.http as h; h.serve(...)`) callee'yi
    /// KANONİK `nox.<module>.<name>` üç-seviyeli `Attribute` zincirine
    /// YENİDEN YAZAR — `tryResolveQualifiedCall`in `c.callee.* = .{
    /// .identifier = mangled }` desenİYLE AYNI ilke. Codegen'in KENDİ
    /// `matchesNoxAttr`i (async_thread.zig) alias-FARKINDA DEĞİL (temel
    /// tanımlayıcının KELİMESİ KELİMESİNE `"nox"` olmasını şart koşar) —
    /// BU rewrite OLMADAN, bir takma-ad İLE yazılan bir intrinsic çağrısı
    /// checker'dan GEÇER ama codegen'de SIRADAN bir metod çağrısı SANILIP
    /// YANLIŞ/çökme İLE SONUÇLANIRDI (GERÇEK, ayrı bir bug — araştırma
    /// SIRASINDA bulundu).
    fn rewriteIntrinsicCalleeToCanonical(self: *Checker, c: ast.Call, module: []const u8, name: []const u8) TypeError!void {
        const nox_ident = try self.allocator.create(ast.Expr);
        nox_ident.* = .{ .identifier = "nox" };
        const mod_attr = try self.allocator.create(ast.Expr);
        mod_attr.* = .{ .attribute = .{ .obj = nox_ident, .attr = module } };
        c.callee.* = .{ .attribute = .{ .obj = mod_attr, .attr = name } };
    }

    /// `nox.thread.start(entry, arg) -> ThreadHandle[T]` — Faz BB.3 (bkz.
    /// nox-teknik-spesifikasyon.md §3.49). **İSİM NEDEN "start", "spawn"
    /// DEĞİL:** `spawn` ZATEN `kw_spawn` olarak lexer'a KAYITLI, dilin
    /// KENDİ fiber-spawn sözdiziminin (`spawn <fn>(...)`) anahtar
    /// kelimesidir — `nox.thread.spawn` YAZILSAYDI, `.` SONRASI `spawn`
    /// bir `.identifier` DEĞİL bir `kw_spawn` token'ı olarak GELİRDİ,
    /// `parsePostfix`in nokta-erişim çözümlemesi (`self.expect(.identifier)`)
    /// bunu REDDEDERDİ (GERÇEKTEN denenip `error.UnexpectedToken`la
    /// KEŞFEDİLDİ). `start` HİÇBİR anahtar kelimeyle ÇAKIŞMIYOR — AYRICA
    /// iki AYRI kavramı ("fiber başlat" vs. "OS iş parçacığı başlat")
    /// KULLANICI İÇİN de sözdizimsel olarak AYIRT EDİYOR, bu YÜZDEN
    /// bilinçli olarak KORUNDU (parser'ı `spawn`ı bağlam-duyarlı bir
    /// tanımlayıcı-YA-DA-anahtar-kelime yapmak YERİNE).
    ///
    /// `tryResolveHttpServeCall`in AYNI deseni (`entry` birinci sınıf bir
    /// DEĞER olarak GEÇİRİLEMEZ, ÇIPLAK bir fonksiyon ADI olarak
    /// doğrulanır), AMA `nox.http.serve`nin TERSİ bir kısıtla: `entry`
    /// **`async def` OLMAK ZORUNDADIR** (`nox.http.serve`nin `handle`ı
    /// ZATEN çalışan bir zamanlayıcının fiber'ında senkron çalıştığından
    /// async OLAMAZKEN, `entry` KENDİ TAZE, bağımsız zamanlayıcısının TEK
    /// üst-düzey görevi olarak çalışır — `$main_body` İLE AYNI "üst-düzey/
    /// in_async" muamelesi, bkz. `runtime/async_rt/thread_bridge.zig`nin
    /// modül üstü notu). Argüman/dönüş tipi `isThreadTransferSafeType`den
    /// GEÇMELİDİR (paylaşımsız modelin GÜVENLE taşıyabileceği küme —
    /// `class`/`list`/`dict`/`Task`/`Channel`/`ThreadHandle` HARİÇ).
    fn tryResolveThreadSpawnCall(self: *Checker, ctx: *FnCtx, c: ast.Call) TypeError!?Type {
        if (!(try self.matchesNoxAttrCall(c, "thread", "start"))) return null;

        if (c.args.len != 2) {
            return self.fail(error.ArgumentCountMismatch, "'nox.thread.start' tam olarak 2 argüman alır: (entry, arg)", .{});
        }
        const entry_name = switch (c.args[0]) {
            .identifier => |n| n,
            else => return self.fail(error.NotCallable, "'nox.thread.start': 'entry' doğrudan bir fonksiyon adı olmalı (metod/lambda henüz desteklenmiyor)", .{}),
        };
        // ÖNCE "tanımlı mı" (net bir UndefinedFunction hatası İÇİN), SONRA
        // "async mı" — aksi TAKDİRDE tanımsız bir isim YANLIŞLIKLA "async
        // def olmalı" hatasına DÜŞERDİ (`async_functions.contains` tanımsız
        // bir isim İÇİN de sessizce `false` döner).
        const sig = self.functions.get(entry_name) orelse
            return self.fail(error.UndefinedFunction, "tanımsız fonksiyon: {s}", .{entry_name});
        if (!self.async_functions.contains(entry_name)) {
            return self.fail(error.TypeMismatch, "'nox.thread.start': 'entry' ('{s}') bir 'async def' OLMALI (kendi bağımsız iş parçacığının tek üst-düzey görevi olarak çalışır)", .{entry_name});
        }
        if (sig.params.len != 1) {
            return self.fail(error.TypeMismatch, "'nox.thread.start': 'entry' TAM OLARAK bir parametre almalı", .{});
        }
        if (!self.isThreadTransferSafeType(sig.params[0])) {
            return self.fail(error.TypeMismatch, "'nox.thread.start': 'entry'in parametre tipi iş parçacıkları arası güvenli değil (yalnızca int/float/bool/str/None/ptr, --release altında ayrıca task/channel/list/class/dict)", .{});
        }
        if (!self.isThreadTransferSafeType(sig.return_type)) {
            return self.fail(error.TypeMismatch, "'nox.thread.start': 'entry'in dönüş tipi iş parçacıkları arası güvenli değil (yalnızca int/float/bool/str/None/ptr, --release altında ayrıca task/channel/list/class/dict)", .{});
        }

        const arg_t = try self.checkExpr(ctx, c.args[1]);
        if (!self.assignable(sig.params[0], arg_t)) {
            return self.fail(error.TypeMismatch, "'nox.thread.start': 'arg' tipi 'entry'in parametre tipiyle uyuşmuyor", .{});
        }

        const boxed = try self.allocator.create(Type);
        boxed.* = sig.return_type;
        return .{ .thread_handle = boxed };
    }

    /// Faz MN.7a: `nox.thread.pool_run(num_workers, entry)` — `tryResolve
    /// ThreadSpawnCall`ın AYNI "`entry` ÇIPLAK bir fonksiyon adı, birinci
    /// sınıf DEĞER OLARAK GEÇİRİLEMEZ" deseni, AMA DAHA BASİT: `entry`
    /// SIFIR parametre alır (`pool_run`ın havuza taşınacak bir ARGÜMANI
    /// YOKTUR — SADECE `entry()` İçİNDEN yapılan `spawn`/`await` çağrıları
    /// çapraz-worker çalmadan YARARLANIR, bkz. `runtime/async_rt/pool_
    /// bridge.zig`nin modül üstü notu) — BU YÜZDEN `isThreadTransferSafeType`
    /// kontrolüne HİÇ GEREK YOK (taşınacak bir argüman/dönüş DEĞERİ YOK).
    /// `num_workers`, `serve_multicore`nin `max_connections`ının AKSİNE,
    /// DERLEME-ZAMANI SABİTİ OLMAK ZORUNDA DEĞİLDİR — DOĞRUDAN çalışma-
    /// zamanı değeri olarak `nox_pool_run`e GEÇER.
    fn tryResolvePoolRunCall(self: *Checker, ctx: *FnCtx, c: ast.Call) TypeError!?Type {
        if (!(try self.matchesNoxAttrCall(c, "thread", "pool_run"))) return null;

        if (c.args.len != 2) {
            return self.fail(error.ArgumentCountMismatch, "'nox.thread.pool_run' tam olarak 2 argüman alır: (num_workers, entry)", .{});
        }
        const num_workers_t = try self.checkExpr(ctx, c.args[0]);
        if (num_workers_t != .int) {
            return self.fail(error.TypeMismatch, "'nox.thread.pool_run': 'num_workers' int olmalıdır", .{});
        }
        const entry_name = switch (c.args[1]) {
            .identifier => |n| n,
            else => return self.fail(error.NotCallable, "'nox.thread.pool_run': 'entry' doğrudan bir fonksiyon adı olmalı (metod/lambda henüz desteklenmiyor)", .{}),
        };
        const sig = self.functions.get(entry_name) orelse
            return self.fail(error.UndefinedFunction, "tanımsız fonksiyon: {s}", .{entry_name});
        if (!self.async_functions.contains(entry_name)) {
            return self.fail(error.TypeMismatch, "'nox.thread.pool_run': 'entry' ('{s}') bir 'async def' OLMALI (havuzun tek sürücü worker'ının tek üst-düzey görevi olarak çalışır)", .{entry_name});
        }
        if (sig.params.len != 0) {
            return self.fail(error.TypeMismatch, "'nox.thread.pool_run': 'entry' SIFIR parametre almalıdır", .{});
        }
        if (sig.return_type != .none) {
            return self.fail(error.TypeMismatch, "'nox.thread.pool_run': 'entry' hiçbir şey döndürmemelidir (-> None)", .{});
        }

        return .none;
    }

    fn registerClassSignatures(self: *Checker, cd: ast.ClassDef) TypeError!void {
        // Faz P2.1: generic bir sınıf ŞABLONUNUN gövdesi BURADA HİÇ İŞLENMEZ
        // — `T` gibi bir tip parametresi `typeExprToType`e (AŞAĞIDA, HER
        // alan/metod tipi İçin ÇAĞRILIR) ÇÖZÜLEMEZ türden bir isimdir.
        // Somut (monomorphize edilmiş, `type_params = &.{}`) bir çağrı BU
        // erken dönüşten ETKİLENMEZ.
        if (cd.type_params.len > 0) return;
        const info = self.classes.getPtr(cd.name).?; // collectClassNames'de eklendi
        info.base = cd.base;
        // Faz 7 (tekli kalıtım): taban sınıfın (bu noktada `registerClassesInOrder`
        // sayesinde ZATEN TAM kaydedilmiş) TÜM alanlarını/metodlarını/
        // `init_sig`ini KOPYALA — "en az invaziv strateji" (bkz. Faz 7
        // tasarım notu): tüm arama siteleri (metod çağrısı, alan erişimi,
        // protokol karşılama) HİÇBİR taban-zinciri YÜRÜMEDEN, tek bir düz
        // `info.methods`/`info.fields` haritasına bakmaya DEVAM eder.
        // **ÖNEMLİ SINIRLAMA (bu noktada)**: bu, tabanın `__init__`
        // gövdesinde `self.<ad> = ...` İLE (AÇIKÇA bir `FieldDecl` OLMADAN)
        // ÇIKARSANAN alanları henüz YAKALAYAMAZ — o çıkarım Geçiş 3'te
        // (`checkClassBody`/`checkAssign`) OLUR, BU fonksiyondan (Geçiş 2)
        // SONRA. `ensureClassBodyChecked` (Geçiş 3), taban gövdesi
        // denetlendikten HEMEN SONRA (artık TAM alan kümesiyle) İKİNCİ bir
        // TAMAMLAYICI kopyalama YAPAR — bkz. onun belge notu. Metodlar
        // BURADA TAM kopyalanır (metod imzaları HER ZAMAN açık/tam bilinir,
        // çıkarım YOK) — ikinci bir metod-kopyalama adımına GEREK yoktur.
        if (cd.base) |base_name| {
            const base_info = self.classes.get(base_name) orelse
                return self.fail(error.UndefinedClass, "sınıf '{s}' bilinmeyen bir taban sınıfa sahip: {s}", .{ cd.name, base_name });
            var field_it = base_info.fields.iterator();
            while (field_it.next()) |e| try info.fields.put(self.allocator, e.key_ptr.*, e.value_ptr.*);
            var method_it = base_info.methods.iterator();
            while (method_it.next()) |e| try info.methods.put(self.allocator, e.key_ptr.*, e.value_ptr.*);
            var owner_it = base_info.method_owners.iterator();
            while (owner_it.next()) |e| try info.method_owners.put(self.allocator, e.key_ptr.*, e.value_ptr.*);
            info.init_sig = base_info.init_sig;
        }
        // Faz FF.5 (bkz. nox-teknik-spesifikasyon.md §3.64): AÇIKÇA
        // bildirilen alanlar, metod imza döngüsünden ÖNCE `info.fields`e
        // yerleştirilir — bu SAYEDE `__init__`deki `self.<ad> = ...`
        // atamaları AŞAĞIDAKİ `checkAssign`in ZATEN VAR OLAN "bilinen tip
        // İLE assignable" dalından GEÇER (yeni bir alan YARATMAZ). Aynı
        // alan İKİ KEZ bildirilirse (ya da taban sınıfta ZATEN VARSA)
        // `DuplicateDefinition` (`collectClassNames`nin sınıf-adı
        // yinelemesiyle AYNI hata kodu).
        for (cd.fields) |fd| {
            if (info.fields.contains(fd.name)) {
                if (cd.base != null) {
                    return self.fail(error.DuplicateDefinition, "sınıf '{s}'in '{s}' alanı zaten bildirilmiş (belki de bir taban sınıfta)", .{ cd.name, fd.name });
                }
                return self.fail(error.DuplicateDefinition, "sınıf '{s}'in '{s}' alanı zaten bildirilmiş", .{ cd.name, fd.name });
            }
            const ft = try self.typeExprToType(fd.type_expr);
            try info.fields.put(self.allocator, fd.name, ft);
            try info.declared_unassigned.put(self.allocator, fd.name, {});
        }
        for (cd.methods) |m| {
            if (m.type_params.len > 0) {
                return self.fail(error.TypeMismatch, "metodlar generic olamaz: {s}.{s} (Faz 10 yalnızca serbest fonksiyonları destekler)", .{ cd.name, m.name });
            }
            if (m.params.len == 0 or !std.mem.eql(u8, m.params[0].name, "self")) {
                return self.fail(error.TypeMismatch, "metod '{s}.{s}' ilk parametre olarak 'self' almalı", .{ cd.name, m.name });
            }
            const self_type_ok = m.params[0].type_expr == .simple and
                std.mem.eql(u8, m.params[0].type_expr.simple, cd.name);
            if (!self_type_ok) {
                return self.fail(error.TypeMismatch, "metod '{s}.{s}' içinde 'self' tipi '{s}' olmalıdır", .{ cd.name, m.name, cd.name });
            }
            const params = try self.allocator.alloc(Type, m.params.len - 1);
            for (m.params[1..], 0..) |p, i| params[i] = try self.typeExprToType(p.type_expr);
            const ret = try self.typeExprToType(m.return_type);
            const sig = FuncSig{ .params = params, .return_type = ret };
            if (std.mem.eql(u8, m.name, "__init__")) {
                info.init_sig = sig;
            } else {
                // Faz 7: miras alınan bir metodu EZİYORSA (override) —
                // v1 katı kuralı, Nox'un genel açık/statik tarzıyla TUTARLI:
                // imza (self HARİÇ parametre tipleri + dönüş tipi) taban
                // sınıftakiyle TAM eşleşmeli (kovaryant dönüş/kontravaryant
                // parametre YOK — `protocol` karşılamasının KENDİ katı
                // `types.eql` kuralıyla AYNI gerekçe).
                if (info.methods.get(m.name)) |inherited| {
                    if (!funcSigEqlIgnoringSelf(inherited, sig)) {
                        return self.fail(error.TypeMismatch, "metod '{s}.{s}' taban sınıftaki imzayla eşleşmiyor (override tam imza eşleşmesi gerektirir)", .{ cd.name, m.name });
                    }
                }
                try info.methods.put(self.allocator, m.name, sig);
                try info.method_owners.put(self.allocator, m.name, cd.name);
            }
        }
    }

    /// Faz 7: iki metod imzasının (self HARİÇ) TAM eşleşip eşleşmediğini
    /// kontrol eder — override doğrulaması İçin (`satisfiesProtocol`nin
    /// KENDİ `types.eql` tabanlı katı eşleşmesiyle AYNI ruh, ama TEK bir
    /// `FuncSig` çifti üzerinde).
    fn funcSigEqlIgnoringSelf(a: FuncSig, b: FuncSig) bool {
        if (a.params.len != b.params.len) return false;
        for (a.params, b.params) |pa, pb| {
            if (!types.eql(pa, pb)) return false;
        }
        return types.eql(a.return_type, b.return_type);
    }

    // ---- Geçiş 3: gövdeleri denetle ----

    pub fn checkModule(self: *Checker, module: ast.Module) TypeError!void {
        self.module_expr_spans = module.expr_spans;
        try self.collectImports(module);
        try self.collectClassNames(module);
        try self.collectProtocols(module);
        try self.registerSignatures(module);
        try self.collectModuleGlobals(module);
        try self.collectSpawnTargets(module);
        try self.computeMutatesGraph(module);

        var top_scope: Scope = .{};
        // `in_async = true`: Nox'ta açık bir `def main()` sözleşmesi YOK —
        // modülün gevşek üst-düzey deyimleri KENDİSİ programın giriş
        // noktasıdır (bkz. nox-teknik-spesifikasyon.md §3.1). Bu yüzden
        // `await`/`spawn`ı yalnızca bir `async def` İÇİNDE kullanılabilir
        // kılmak, kullanıcının bir görevi/kanalı ASLA üst düzeyde
        // bekleyemeyeceği anlamına gelirdi — üst düzey deyimler ZATEN
        // örtük olarak "programın kendisi" olduğundan, `await`/`spawn`ı
        // burada da SERBEST bırakmak daha doğal (codegen, gerekirse
        // `main`i bir fiber'a sarmalayarak bunu gerçekleştirir, bkz.
        // codegen.zig, `moduleUsesAsync`).
        var top_ctx: FnCtx = .{ .scope = &top_scope, .expected_return = null, .in_async = true };
        for (module.body) |stmt| {
            self.current_line = stmt.line;
            self.current_span = stmt.span;
            switch (stmt.kind) {
                // Generic fonksiyonların (açık `[T]` VEYA örtük protokol
                // parametresi yoluyla) gövdesi burada denetlenmez — tip
                // parametreleri somut değildir. `fd.type_params.len == 0`
                // YETERLİ DEĞİLDİR: bir protokol parametresi `fd.type_params`ı
                // hiç etkilemez (yalnızca `registerFunc`in hesapladığı ETKİN
                // listeyi etkiler) — bu yüzden asıl kaynak `generic_functions`
                // üyeliğidir. Denetim, `instantiateGeneric` tarafından somut
                // bir örnekleme sentezlendiğinde yapılır.
                .func_def => |fd| {
                    if (!self.generic_functions.contains(fd.name))
                        self.checkFunctionBody(fd) catch |e| try self.recordDiagnostic(e);
                },
                // Faz P2.1: generic sınıf ŞABLONLARININ (`func_def`in HEMEN
                // ÜSTÜNDEKİ notla AYNI gerekçe) gövdesi burada denetlenmez —
                // `T` somut değildir. Denetim, `instantiateGenericClass`
                // tarafından somut bir örnekleme sentezlendiğinde yapılır.
                .class_def => |cd| {
                    if (!self.generic_classes.contains(cd.name))
                        try self.ensureClassBodyChecked(cd);
                },
                // Protokoller `collectProtocols`te zaten tamamen doğrulandı;
                // çalışma zamanı kodu üretmezler (yalnızca imza), bu yüzden
                // burada başka bir işlem gerekmez.
                .protocol_def => {},
                // `extern def`in gövdesi yok — imzası zaten `registerSignatures`de
                // (`registerExternFunc`) kaydedildi/doğrulandı.
                .extern_def => {},
                // `import nox.http` yalnızca modül seviyesinde geçerlidir —
                // bu yüzden `class_def`/`extern_def` gibi burada ÖZEL olarak
                // yakalanır (aksi halde genel `checkStmt` yoluna düşüp HER
                // ZAMAN "yalnızca modül seviyesinde olabilir" hatası verirdi,
                // konumdan bağımsız — bkz. `checkStmt`in `.import_stmt` kolu).
                // Gerçek çözümleme (stdlib dosyasını bulup ayrıştırma) ZATEN
                // `main.zig` tarafından, checker çalışmadan ÖNCE yapılmıştır
                // (bkz. modül üstü not) — burada yalnızca "bu yol import
                // edildi" kaydı tutulur.
                // Bulundu: `.import_stmt`/`.from_import_stmt` ARTIK BURADA
                // İŞLENMEZ — `collectImports`e (Geçiş 0, `registerSignatures`DEN
                // ÖNCE çalışır) TAŞINDI, bkz. onun belge notu (SIRALAMA hatası
                // düzeltmesi). Burada NO-OP olarak KALMALARININ TEK nedeni bu
                // İKİ deyim türünün genel `checkStmt` yoluna (HER ZAMAN "yalnızca
                // modül seviyesinde olabilir" hatası verirdi) DÜŞMESİNİ ÖNLEMEK.
                .import_stmt, .from_import_stmt => {},
                else => self.checkStmt(&top_ctx, stmt) catch |e| try self.recordDiagnostic(e),
            }
        }
        // GG.22: modülün üst-düzey deyimleri de ("main"in kendisi, bkz.
        // yukarıdaki `in_async = true` notu) bir `spawn` çağırabilir —
        // `checkFunctionBody`nin AYNI YENİ kontrolü, BOŞ bir parametre
        // dilimiyle (üst-düzeyin parametresi YOK).
        self.checkNoPostSpawnCallerMutation(module.body, &.{}) catch |e| try self.recordDiagnostic(e);
    }

    /// Modüldeki tüm `protocol_def`leri kaydeder (`self.protocols`). Her
    /// protokol metodu: (a) generic olamaz, (b) ilk parametre olarak
    /// `self: <ProtokolAdı>` almalı, (c) gövdesi TEK bir `pass` olmalı
    /// (yalnızca imza — hiçbir zaman çalıştırılmaz). Bir metodun `self`
    /// dışındaki parametre/dönüş tipleri yalnızca SOMUT tipler (int/float/
    /// bool/str/None/başka bir sınıf) olabilir — başka bir protokole (ya da
    /// kendisine, `self` dışında) başvurmak `typeExprToType`'ın protokolleri
    /// hiç tanımaması sayesinde kendiliğinden `UnknownType` ile reddedilir.
    fn collectProtocols(self: *Checker, module: ast.Module) TypeError!void {
        for (module.body) |stmt| {
            self.current_line = stmt.line;
            self.current_span = stmt.span;
            if (stmt.kind != .protocol_def) continue;
            const pd = stmt.kind.protocol_def;
            if (self.protocols.contains(pd.name)) {
                return self.fail(error.DuplicateDefinition, "protokol zaten tanımlı: {s}", .{pd.name});
            }
            const methods = try self.allocator.alloc(ProtocolMethod, pd.methods.len);
            for (pd.methods, 0..) |m, i| {
                if (m.type_params.len > 0) {
                    return self.fail(error.TypeMismatch, "protokol metodları generic olamaz: {s}.{s}", .{ pd.name, m.name });
                }
                if (m.params.len == 0 or !std.mem.eql(u8, m.params[0].name, "self")) {
                    return self.fail(error.TypeMismatch, "protokol metodu '{s}.{s}' ilk parametre olarak 'self' almalı", .{ pd.name, m.name });
                }
                const self_type_ok = m.params[0].type_expr == .simple and
                    std.mem.eql(u8, m.params[0].type_expr.simple, pd.name);
                if (!self_type_ok) {
                    return self.fail(error.TypeMismatch, "protokol metodu '{s}.{s}' içinde 'self' tipi '{s}' olmalıdır", .{ pd.name, m.name, pd.name });
                }
                if (m.body.len != 1 or m.body[0].kind != .pass_stmt) {
                    return self.fail(error.TypeMismatch, "protokol metodu '{s}.{s}' yalnızca 'pass' gövdesine sahip olabilir (yalnızca imza)", .{ pd.name, m.name });
                }
                const params = try self.allocator.alloc(Type, m.params.len - 1);
                for (m.params[1..], 0..) |p, j| params[j] = try self.typeExprToType(p.type_expr);
                const ret = try self.typeExprToType(m.return_type);
                methods[i] = .{ .name = m.name, .params = params, .return_type = ret };
            }
            try self.protocols.put(self.allocator, pd.name, .{ .methods = methods });
        }
    }

    /// v1.30.0: `checkModule`nin diğer pre-pass'larıyla (`collectImports`
    /// vb.) AYNI aşamada, HERHANGİ bir fonksiyon gövdesi denetlenmeden
    /// ÖNCE çalışır — modülün TAMAMINI (üst-düzey deyimler, TÜM iç içe
    /// kontrol-akışı gövdeleri, iç içe `def`ler, sınıf metodları DAHİL)
    /// tarayıp HER `spawn f(...)` çağrısının `f` adını `spawn_target_
    /// functions`e ekler. METİNSEL sıradan BAĞIMSIZDIR (bir fonksiyon
    /// kendi `spawn` çağrısından SONRA tanımlanmış olsa BİLE yakalanır).
    fn collectSpawnTargets(self: *Checker, module: ast.Module) TypeError!void {
        try self.collectSpawnTargetsStmts(module.body);
    }

    fn collectSpawnTargetsStmts(self: *Checker, stmts: []const ast.Stmt) TypeError!void {
        for (stmts) |stmt| {
            switch (stmt.kind) {
                .expr_stmt => |e| try self.collectSpawnTargetsExpr(e),
                .var_decl => |v| try self.collectSpawnTargetsExpr(v.value),
                .assign => |a| {
                    try self.collectSpawnTargetsExpr(a.target);
                    try self.collectSpawnTargetsExpr(a.value);
                },
                .if_stmt => |i| {
                    try self.collectSpawnTargetsExpr(i.cond);
                    try self.collectSpawnTargetsStmts(i.then_body);
                    for (i.elif_clauses) |ec| {
                        try self.collectSpawnTargetsExpr(ec.cond);
                        try self.collectSpawnTargetsStmts(ec.body);
                    }
                    if (i.else_body) |eb| try self.collectSpawnTargetsStmts(eb);
                },
                .while_stmt => |w| {
                    try self.collectSpawnTargetsExpr(w.cond);
                    try self.collectSpawnTargetsStmts(w.body);
                },
                .for_stmt => |f| {
                    try self.collectSpawnTargetsExpr(f.iterable);
                    try self.collectSpawnTargetsStmts(f.body);
                },
                // İç içe `def` (Faz U.4.2) asla spawn HEDEFİ olamaz
                // (asenkron olamaz, satır ~2098) ama İÇİNDE bir `spawn`
                // çağrısı OLABİLİR.
                .func_def => |fd| try self.collectSpawnTargetsStmts(fd.body),
                .class_def => |cd| for (cd.methods) |m| try self.collectSpawnTargetsStmts(m.body),
                .return_stmt => |maybe_e| if (maybe_e) |e| try self.collectSpawnTargetsExpr(e),
                .raise_stmt => |e| try self.collectSpawnTargetsExpr(e),
                .try_stmt => |t| {
                    try self.collectSpawnTargetsStmts(t.try_body);
                    for (t.except_clauses) |ec| try self.collectSpawnTargetsStmts(ec.body);
                    if (t.finally_body) |fb| try self.collectSpawnTargetsStmts(fb);
                },
                .lowlevel_stmt => |ll| try self.collectSpawnTargetsStmts(ll.body),
                .with_stmt => |w| {
                    try self.collectSpawnTargetsExpr(w.ctx_expr);
                    try self.collectSpawnTargetsStmts(w.body);
                },
                .defer_stmt => |d| {
                    try self.collectSpawnTargetsExpr(d.call.callee.*);
                    for (d.call.args) |a| try self.collectSpawnTargetsExpr(a);
                },
                .protocol_def, .extern_def, .import_stmt, .from_import_stmt, .pass_stmt => {},
            }
        }
    }

    fn collectSpawnTargetsExpr(self: *Checker, e: ast.Expr) TypeError!void {
        switch (e) {
            .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => {},
            .unary => |u| try self.collectSpawnTargetsExpr(u.operand.*),
            .binary => |b| {
                try self.collectSpawnTargetsExpr(b.left.*);
                try self.collectSpawnTargetsExpr(b.right.*);
            },
            .call => |c| {
                try self.collectSpawnTargetsExpr(c.callee.*);
                for (c.args) |a| try self.collectSpawnTargetsExpr(a);
            },
            .attribute => |a| try self.collectSpawnTargetsExpr(a.obj.*),
            .index => |ix| {
                try self.collectSpawnTargetsExpr(ix.obj.*);
                try self.collectSpawnTargetsExpr(ix.index.*);
            },
            .list_lit => |items| for (items) |it| try self.collectSpawnTargetsExpr(it),
            .dict_lit => |pairs| for (pairs) |p| {
                try self.collectSpawnTargetsExpr(p.key);
                try self.collectSpawnTargetsExpr(p.value);
            },
            .await_expr => |operand_ptr| try self.collectSpawnTargetsExpr(operand_ptr.*),
            .generic_construct => |g| for (g.args) |a| try self.collectSpawnTargetsExpr(a),
            .spawn_expr => |operand_ptr| {
                // `spawn`ın operandı TİP kontrolünde `.call` VE `callee =
                // .identifier` OLMAK ZORUNDA (bkz. `checkExpr`in
                // `.spawn_expr` dalı) — ama BU pre-pass tip kontrolünden
                // ÖNCE çalıştığından, geçersiz şekiller SESSİZCE ATLANIR
                // (asıl hata zaten normal akışta `checkExpr` tarafından
                // raporlanır).
                if (operand_ptr.* == .call) {
                    const c = operand_ptr.*.call;
                    if (c.callee.* == .identifier) {
                        try self.spawn_target_functions.put(self.allocator, c.callee.*.identifier, {});
                    }
                    for (c.args) |a| try self.collectSpawnTargetsExpr(a);
                }
            },
        }
    }

    /// GG.20 (bkz. plan dosyası "ASAP güçlendirmesi — Tur 4"): whole-program
    /// pre-pass — `module.body`nin ÜST-DÜZEY `.func_def`leri VE `.class_def`
    /// metodlarının HER `list`/`dict`/`class` tipli parametresi İçİn, O
    /// parametrenin (a) fonksiyonun KENDİ gövdesinde DOĞRUDAN mutasyona
    /// UĞRADIĞINI (tohum) VEYA (b) BAŞKA bir SERBEST fonksiyona argüman
    /// olarak GEÇTİĞİNİ (kenar — hedef fonksiyonun KARŞILIK GELEN
    /// parametresi kötüyse BU parametre de kötü olur) tarar. `effect_graph.propagateBad`
    /// (`computeMustNotRaise`in ZATEN kanıtlanmış ters-grafik/worklist
    /// algoritmasının PAYLAŞILAN çekirdeği) İLE `self.mutates_params`i
    /// doldurur.
    fn computeMutatesGraph(self: *Checker, module: ast.Module) TypeError!void {
        var seeds: std.ArrayListUnmanaged(effect_graph.NodeKey) = .empty;
        defer seeds.deinit(self.allocator);
        var reverse_edges: effect_graph.ReverseEdges = .empty;
        for (module.body) |stmt| {
            switch (stmt.kind) {
                .func_def => |fd| try self.scanMutatesGraphFunc(fd.name, fd.params, fd.body, &seeds, &reverse_edges),
                .class_def => |cd| for (cd.methods) |m| {
                    const sym = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ cd.name, m.name });
                    try self.scanMutatesGraphFunc(sym, m.params, m.body, &seeds, &reverse_edges);
                },
                else => {},
            }
        }
        self.mutates_params = try effect_graph.propagateBad(self.allocator, &reverse_edges, seeds.items);
    }

    /// GG.20: `len`/`str`/`int`/`float`/`print`/vb. — `checkCall`in `.attribute`
    /// DIŞINDAKİ `.identifier` dalının ÖZEL işlediği, KULLANICI TARAFINDAN
    /// yeniden tanımlanamayan, `self.functions`E ASLA KAYDEDİLMEYEN sabit
    /// yerleşikler — HİÇBİRİ argümanını mutasyona UĞRATMAZ (`len`/`print`
    /// salt-okunur, DİĞERLERİ list/dict/class argüman KABUL ETMEZ zaten).
    /// BUNLAR OLMADAN "callee `self.functions`DA YOK" kontrolü BUNLARI da
    /// (YANLIŞLIKLA) "çözülemeyen çağrı" sayıp GEREKSİZ yere tohum
    /// olarak İŞARETLERDİ (ör. `len(xs)` İçEREN salt-okunur bir yardımcı
    /// bile YAKALANIRDI — GERÇEK bir yanlış-pozitif).
    fn isKnownSafeBuiltinCallee(name: []const u8) bool {
        const safe = [_][]const u8{ "len", "print", "str", "int", "float", "bool", "super", "hpy_call", "hpy_call_str", "wasm_call" };
        for (safe) |s| {
            if (std.mem.eql(u8, name, s)) return true;
        }
        return std.mem.startsWith(u8, name, "__nox_reflect_");
    }

    fn paramIndexByName(params: []const ast.Param, name: []const u8) ?u32 {
        for (params, 0..) |p, i| {
            if (std.mem.eql(u8, p.name, name)) return @intCast(i);
        }
        return null;
    }

    fn scanMutatesGraphFunc(self: *Checker, fname: []const u8, params: []const ast.Param, body: []const ast.Stmt, seeds: *std.ArrayListUnmanaged(effect_graph.NodeKey), reverse_edges: *effect_graph.ReverseEdges) TypeError!void {
        var shared: std.ArrayListUnmanaged(SharedParam) = .empty;
        defer shared.deinit(self.allocator);
        for (params) |p| {
            const pt = self.typeExprToType(p.type_expr) catch continue;
            switch (pt) {
                .list, .dict, .class => try shared.append(self.allocator, .{ .name = p.name, .ty = pt }),
                else => {},
            }
        }
        if (shared.items.len == 0) return;
        try self.scanMutatesGraphStmts(fname, params, body, shared.items, seeds, reverse_edges);
    }

    fn addMutatesSeed(self: *Checker, fname: []const u8, params: []const ast.Param, root_param: []const u8, seeds: *std.ArrayListUnmanaged(effect_graph.NodeKey)) TypeError!void {
        const idx = paramIndexByName(params, root_param) orelse return;
        try seeds.append(self.allocator, .{ .func = fname, .index = idx });
    }

    fn addMutatesEdge(self: *Checker, target_func: []const u8, target_index: u32, fname: []const u8, params: []const ast.Param, root_param: []const u8, reverse_edges: *effect_graph.ReverseEdges) TypeError!void {
        const idx = paramIndexByName(params, root_param) orelse return;
        const key: effect_graph.NodeKey = .{ .func = target_func, .index = target_index };
        const gop = try reverse_edges.getOrPut(self.allocator, key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, .{ .func = fname, .index = idx });
    }

    fn scanMutatesGraphStmts(self: *Checker, fname: []const u8, params: []const ast.Param, stmts: []const ast.Stmt, shared: []const SharedParam, seeds: *std.ArrayListUnmanaged(effect_graph.NodeKey), reverse_edges: *effect_graph.ReverseEdges) TypeError!void {
        for (stmts) |stmt| {
            switch (stmt.kind) {
                .assign => |a| {
                    switch (a.target) {
                        .index => |ix| if (self.resolveExprSharedType(ix.obj.*, shared)) |r| {
                            if (r.ty == .list or r.ty == .dict) try self.addMutatesSeed(fname, params, r.root_param, seeds);
                        },
                        .attribute => |at| if (self.resolveExprSharedType(at.obj.*, shared)) |r| {
                            if (r.ty == .class) try self.addMutatesSeed(fname, params, r.root_param, seeds);
                        },
                        else => {},
                    }
                    try self.scanMutatesGraphExpr(fname, params, a.value, shared, seeds, reverse_edges);
                },
                .expr_stmt => |e| {
                    if (e == .call and e.call.callee.* == .attribute) {
                        const at = e.call.callee.*.attribute;
                        if (std.mem.eql(u8, at.attr, "append") or std.mem.eql(u8, at.attr, "pop") or std.mem.eql(u8, at.attr, "sort")) {
                            if (self.resolveExprSharedType(at.obj.*, shared)) |r| {
                                if (r.ty == .list) try self.addMutatesSeed(fname, params, r.root_param, seeds);
                            }
                        }
                    }
                    try self.scanMutatesGraphExpr(fname, params, e, shared, seeds, reverse_edges);
                },
                .var_decl => |v| try self.scanMutatesGraphExpr(fname, params, v.value, shared, seeds, reverse_edges),
                .return_stmt => |maybe_e| if (maybe_e) |e| try self.scanMutatesGraphExpr(fname, params, e, shared, seeds, reverse_edges),
                .raise_stmt => |e| try self.scanMutatesGraphExpr(fname, params, e, shared, seeds, reverse_edges),
                .if_stmt => |i| {
                    try self.scanMutatesGraphExpr(fname, params, i.cond, shared, seeds, reverse_edges);
                    try self.scanMutatesGraphStmts(fname, params, i.then_body, shared, seeds, reverse_edges);
                    for (i.elif_clauses) |ec| {
                        try self.scanMutatesGraphExpr(fname, params, ec.cond, shared, seeds, reverse_edges);
                        try self.scanMutatesGraphStmts(fname, params, ec.body, shared, seeds, reverse_edges);
                    }
                    if (i.else_body) |eb| try self.scanMutatesGraphStmts(fname, params, eb, shared, seeds, reverse_edges);
                },
                .while_stmt => |w| {
                    try self.scanMutatesGraphExpr(fname, params, w.cond, shared, seeds, reverse_edges);
                    try self.scanMutatesGraphStmts(fname, params, w.body, shared, seeds, reverse_edges);
                },
                .for_stmt => |f| {
                    try self.scanMutatesGraphExpr(fname, params, f.iterable, shared, seeds, reverse_edges);
                    try self.scanMutatesGraphStmts(fname, params, f.body, shared, seeds, reverse_edges);
                },
                .try_stmt => |t| {
                    try self.scanMutatesGraphStmts(fname, params, t.try_body, shared, seeds, reverse_edges);
                    for (t.except_clauses) |ec| try self.scanMutatesGraphStmts(fname, params, ec.body, shared, seeds, reverse_edges);
                    if (t.finally_body) |fb| try self.scanMutatesGraphStmts(fname, params, fb, shared, seeds, reverse_edges);
                },
                .with_stmt => |w| {
                    try self.scanMutatesGraphExpr(fname, params, w.ctx_expr, shared, seeds, reverse_edges);
                    try self.scanMutatesGraphStmts(fname, params, w.body, shared, seeds, reverse_edges);
                },
                .lowlevel_stmt => |ll| try self.scanMutatesGraphStmts(fname, params, ll.body, shared, seeds, reverse_edges),
                // İç içe `func_def`/`class_def`/`defer`: AYRI çağrılabilir
                // birimler — v1.30.0'ın "transitif takip yok" kararıyla
                // TUTARLI (BU graf SADECE üst-düzey fonksiyon/metod
                // ÇAĞRILARINI kapsar).
                .func_def, .class_def, .defer_stmt, .protocol_def, .extern_def, .import_stmt, .from_import_stmt, .pass_stmt => {},
            }
        }
    }

    fn scanMutatesGraphExpr(self: *Checker, fname: []const u8, params: []const ast.Param, expr: ast.Expr, shared: []const SharedParam, seeds: *std.ArrayListUnmanaged(effect_graph.NodeKey), reverse_edges: *effect_graph.ReverseEdges) TypeError!void {
        switch (expr) {
            .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => {},
            .unary => |u| try self.scanMutatesGraphExpr(fname, params, u.operand.*, shared, seeds, reverse_edges),
            .binary => |b| {
                try self.scanMutatesGraphExpr(fname, params, b.left.*, shared, seeds, reverse_edges);
                try self.scanMutatesGraphExpr(fname, params, b.right.*, shared, seeds, reverse_edges);
            },
            .call => |c| {
                // YENİ: argümanların HERHANGİ BİRİ paylaşılan bir parametreye
                // ÇÖZÜLÜYORSA — callee ÇÖZÜLEBİLİR bir SERBEST fonksiyon
                // İSE (`self.functions`de, METODLAR/kurucular HARİÇ) bir
                // KENAR, AKSİ HALDE (metod çağrısı/dolaylı/çözülemeyen
                // isim) DOĞRUDAN bir tohum EKLENİR (muhafazakâr).
                const callee_is_resolvable_free_fn = c.callee.* == .identifier and self.functions.contains(c.callee.identifier);
                const callee_is_known_safe_builtin = c.callee.* == .identifier and isKnownSafeBuiltinCallee(c.callee.identifier);
                // GG.21 (bkz. plan dosyası "ASAP güçlendirmesi — Tur 5"):
                // receiver PAYLAŞILAN bir parametreye ÇÖZÜLÜYORSA VE metod
                // PROVABLY final İSE (`methodIsFinal`), metodu ÇÖZÜLEBİLİR
                // bir SERBEST fonksiyon GİBİ ele al (kenar) — AKSİ HALDE
                // (receiver çözülemiyor/final DEĞİL) MEVCUT (tohum) davranış
                // KORUNUR.
                var method_owner_symbol: ?[]const u8 = null;
                if (c.callee.* == .attribute) {
                    const at = c.callee.attribute;
                    if (self.resolveExprSharedType(at.obj.*, shared)) |recv| {
                        if (recv.ty == .class) {
                            if (self.classes.get(recv.ty.class)) |cinfo| {
                                if (cinfo.method_owners.get(at.attr)) |owner| {
                                    if (self.methodIsFinal(recv.ty.class, at.attr)) {
                                        method_owner_symbol = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ owner, at.attr });
                                    }
                                }
                            }
                        }
                    }
                }
                for (c.args, 0..) |a, arg_index| {
                    if (self.resolveExprSharedType(a, shared)) |r| {
                        if (r.ty == .list or r.ty == .dict or r.ty == .class) {
                            if (callee_is_resolvable_free_fn) {
                                try self.addMutatesEdge(c.callee.identifier, @intCast(arg_index), fname, params, r.root_param, reverse_edges);
                            } else if (method_owner_symbol) |owner_symbol| {
                                // `self` metodun KENDİ NodeKey indekslemesinde
                                // HER ZAMAN 0'DADIR (`m.params[0]`) — çağrı
                                // sitesinin `c.args`ı İSE receiver'ı (self)
                                // İÇERMEZ, bu YÜZDEN +1 KAYDIRILIR.
                                try self.addMutatesEdge(owner_symbol, @intCast(arg_index + 1), fname, params, r.root_param, reverse_edges);
                            } else if (!callee_is_known_safe_builtin) {
                                try self.addMutatesSeed(fname, params, r.root_param, seeds);
                            }
                        }
                    }
                    try self.scanMutatesGraphExpr(fname, params, a, shared, seeds, reverse_edges);
                }
                try self.scanMutatesGraphExpr(fname, params, c.callee.*, shared, seeds, reverse_edges);
            },
            .attribute => |a| try self.scanMutatesGraphExpr(fname, params, a.obj.*, shared, seeds, reverse_edges),
            .index => |ix| {
                try self.scanMutatesGraphExpr(fname, params, ix.obj.*, shared, seeds, reverse_edges);
                try self.scanMutatesGraphExpr(fname, params, ix.index.*, shared, seeds, reverse_edges);
            },
            .list_lit => |items| for (items) |it| try self.scanMutatesGraphExpr(fname, params, it, shared, seeds, reverse_edges),
            .dict_lit => |pairs| for (pairs) |p| {
                try self.scanMutatesGraphExpr(fname, params, p.key, shared, seeds, reverse_edges);
                try self.scanMutatesGraphExpr(fname, params, p.value, shared, seeds, reverse_edges);
            },
            .await_expr => |op| try self.scanMutatesGraphExpr(fname, params, op.*, shared, seeds, reverse_edges),
            .spawn_expr => |op| try self.scanMutatesGraphExpr(fname, params, op.*, shared, seeds, reverse_edges),
            .generic_construct => |g| for (g.args) |a| try self.scanMutatesGraphExpr(fname, params, a, shared, seeds, reverse_edges),
        }
    }

    /// v1.34.0 (bkz. nox-teknik-spesifikasyon.md §3.101): `resolveExprSharedType`nin
    /// dönüşü — bir ifadenin (`b`/`b.xs`/`b.inner.xs` GİBİ HERHANGİ derinlikte
    /// bir attribute zinciri) HANGİ paylaşılan parametreden (`root_param`)
    /// türediğini VE ifadenin KENDİ ÇÖZÜLMÜŞ tipini (`ty`) taşır.
    const SharedTypeResolution = struct { root_param: []const u8, ty: Type };

    /// v1.34.0: `b`/`b.xs`/`b.inner.xs`/`b.inner.deep.xs` GİBİ HERHANGİ bir
    /// derinlikteki attribute zincirinin, `params`daki paylaşılan
    /// parametrelerden BİRİNE kadar İZLENİP İZLENEMEDİĞİNİ, İZLENEBİLİYORSA
    /// zincirin SONUNDAKİ (`self.classes`nin ZATEN kayıtlı alan-tip
    /// haritasından ÇÖZÜLEN) tipi ÖZYİNELEMELİ olarak bulur. YENİ bir call-
    /// graph/whole-program analiz DEĞİLDİR — SADECE `registerClassSignatures`nin
    /// ZATEN doldurduğu `ClassInfo.fields` haritasının, TEK seviye YERİNE
    /// ARBİTRER derinlikte kullanılmasıdır (bkz. plan dosyası "Kök neden").
    fn resolveExprSharedType(self: *Checker, expr: ast.Expr, params: []const SharedParam) ?SharedTypeResolution {
        return switch (expr) {
            .identifier => |name| blk: {
                for (params) |p| {
                    if (std.mem.eql(u8, p.name, name)) break :blk .{ .root_param = name, .ty = p.ty };
                }
                break :blk null;
            },
            .attribute => |a| blk: {
                const parent = self.resolveExprSharedType(a.obj.*, params) orelse break :blk null;
                if (parent.ty != .class) break :blk null;
                const info = self.classes.get(parent.ty.class) orelse break :blk null;
                const field_ty = info.fields.get(a.attr) orelse break :blk null;
                break :blk .{ .root_param = parent.root_param, .ty = field_ty };
            },
            else => null,
        };
    }

    /// v1.30.0/v1.34.0: bir `spawn` hedefi fonksiyonun `list`/`dict`/`class`
    /// tipli bir parametresinin (`params`) — DOĞRUDAN VEYA (v1.34.0'DAN
    /// İTİBAREN) HERHANGİ bir derinlikte İÇ İÇE bir alan erişimi ÜZERİNDEN
    /// (`b.xs.append()`, `b.inner.xs[i]=` GİBİ) — fonksiyonun KENDİ gövdesi
    /// (`stmts`) İÇİNDE mutasyona uğratılıp uğratılmadığını tarar —
    /// `xs[i]=`/`d[k]=` (index-atama), `obj.alan=` (attribute-atama) VE
    /// `list[T]`in mutasyon metodları (`.append`/`.pop`/`.sort`). Yalnızca
    /// fonksiyonun KENDİ gövdesi (BAŞKA fonksiyonlara transitif ÇAĞRI-GRAFİĞİ
    /// TAKİBİ YOK, iç içe `func_def`/`class_def` gövdelerine İNMEZ — bunlar
    /// AYRI çağrılabilir birimlerdir) — bkz. plan dosyasının "Kapsam DIŞI"
    /// bölümü.
    /// GG.20: `computeMutatesGraph`nin doldurduğu `self.mutates_params`e
    /// karşı BİR `.call` ifadesindeki HER argümanı kontrol eder — argüman
    /// paylaşılan bir parametreye ÇÖZÜLÜYORSA VE callee ÇÖZÜLEBİLİR bir
    /// SERBEST fonksiyon İSE VE `{callee, arg_index}` `mutates_params`DAYSA,
    /// TRANSİTİF mutasyon hatası verir (v1.30.0'ın "yalnızca KENDİ gövde"
    /// sınırlamasının GENELLEMESİ). ARGÜMANLARIN KENDİSİ de özyinelemeli
    /// olarak taranır (iç içe çağrılar İçİn).
    fn checkTransitiveSpawnSharedMutationExpr(self: *Checker, fd_name: []const u8, expr: ast.Expr, params: []const SharedParam) TypeError!void {
        switch (expr) {
            .unary => |u| try self.checkTransitiveSpawnSharedMutationExpr(fd_name, u.operand.*, params),
            .binary => |b| {
                try self.checkTransitiveSpawnSharedMutationExpr(fd_name, b.left.*, params);
                try self.checkTransitiveSpawnSharedMutationExpr(fd_name, b.right.*, params);
            },
            .call => |c| {
                const callee_is_resolvable_free_fn = c.callee.* == .identifier and self.functions.contains(c.callee.identifier);
                // GG.21: metod çağrısı — receiver paylaşılan bir parametreye
                // çözülüyorsa VE metod PROVABLY final İSE (`methodIsFinal`),
                // `mutates_params`e karşı AYNI şekilde kontrol edilir.
                var method_owner_symbol: ?[]const u8 = null;
                var method_name_for_msg: []const u8 = "";
                if (c.callee.* == .attribute) {
                    const at = c.callee.attribute;
                    if (self.resolveExprSharedType(at.obj.*, params)) |recv| {
                        if (recv.ty == .class) {
                            if (self.classes.get(recv.ty.class)) |cinfo| {
                                if (cinfo.method_owners.get(at.attr)) |owner| {
                                    if (self.methodIsFinal(recv.ty.class, at.attr)) {
                                        method_owner_symbol = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ owner, at.attr });
                                        method_name_for_msg = at.attr;
                                    }
                                }
                            }
                        }
                    }
                }
                for (c.args, 0..) |a, idx| {
                    if (callee_is_resolvable_free_fn) {
                        if (self.resolveExprSharedType(a, params)) |r| {
                            if (r.ty == .list or r.ty == .dict or r.ty == .class) {
                                if (self.mutates_params.contains(.{ .func = c.callee.identifier, .index = @intCast(idx) })) {
                                    return self.fail(error.SpawnSharedMutation, "'{s}' fonksiyonu bir 'spawn' hedefi olduğundan, paylaşılan parametresi '{s}' burada '{s}' üzerinden transitif olarak değiştirilemez (eşzamanlı worker'lar arasında senkronizasyonsuz mutasyon veri yarışına yol açar) — önce yerel bir kopya oluşturun", .{ fd_name, r.root_param, c.callee.identifier });
                                }
                            }
                        }
                    } else if (method_owner_symbol) |owner_symbol| {
                        if (self.resolveExprSharedType(a, params)) |r| {
                            if (r.ty == .list or r.ty == .dict or r.ty == .class) {
                                // `self` metodun KENDİ NodeKey indekslemesinde
                                // HER ZAMAN 0'DADIR — bkz. scanMutatesGraphExpr'in
                                // AYNI +1 KAYDIRMASININ belge notu.
                                if (self.mutates_params.contains(.{ .func = owner_symbol, .index = @intCast(idx + 1) })) {
                                    return self.fail(error.SpawnSharedMutation, "'{s}' fonksiyonu bir 'spawn' hedefi olduğundan, paylaşılan parametresi '{s}' burada '{s}' metodu üzerinden transitif olarak değiştirilemez (eşzamanlı worker'lar arasında senkronizasyonsuz mutasyon veri yarışına yol açar) — önce yerel bir kopya oluşturun", .{ fd_name, r.root_param, method_name_for_msg });
                                }
                            }
                        }
                    }
                    try self.checkTransitiveSpawnSharedMutationExpr(fd_name, a, params);
                }
                try self.checkTransitiveSpawnSharedMutationExpr(fd_name, c.callee.*, params);
            },
            .attribute => |a| try self.checkTransitiveSpawnSharedMutationExpr(fd_name, a.obj.*, params),
            .index => |ix| {
                try self.checkTransitiveSpawnSharedMutationExpr(fd_name, ix.obj.*, params);
                try self.checkTransitiveSpawnSharedMutationExpr(fd_name, ix.index.*, params);
            },
            .list_lit => |items| for (items) |it| try self.checkTransitiveSpawnSharedMutationExpr(fd_name, it, params),
            .dict_lit => |pairs| for (pairs) |p| {
                try self.checkTransitiveSpawnSharedMutationExpr(fd_name, p.key, params);
                try self.checkTransitiveSpawnSharedMutationExpr(fd_name, p.value, params);
            },
            .await_expr => |op| try self.checkTransitiveSpawnSharedMutationExpr(fd_name, op.*, params),
            .spawn_expr => |op| try self.checkTransitiveSpawnSharedMutationExpr(fd_name, op.*, params),
            .generic_construct => |g| for (g.args) |a| try self.checkTransitiveSpawnSharedMutationExpr(fd_name, a, params),
            .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => {},
        }
    }

    fn checkNoSpawnSharedMutation(self: *Checker, fd_name: []const u8, stmts: []const ast.Stmt, params: []const SharedParam) TypeError!void {
        for (stmts) |stmt| {
            self.current_line = stmt.line;
            self.current_span = stmt.span;
            switch (stmt.kind) {
                .assign => |a| {
                    switch (a.target) {
                        .index => |ix| if (self.resolveExprSharedType(ix.obj.*, params)) |r| {
                            if (r.ty == .list or r.ty == .dict) {
                                return self.fail(error.SpawnSharedMutation, "'{s}' fonksiyonu bir 'spawn' hedefi olduğundan, paylaşılan parametresi '{s}' burada değiştirilemez (eşzamanlı worker'lar arasında senkronizasyonsuz mutasyon veri yarışına yol açar) — önce yerel bir kopya oluşturun", .{ fd_name, r.root_param });
                            }
                        },
                        .attribute => |at| if (self.resolveExprSharedType(at.obj.*, params)) |r| {
                            if (r.ty == .class) {
                                return self.fail(error.SpawnSharedMutation, "'{s}' fonksiyonu bir 'spawn' hedefi olduğundan, paylaşılan parametresi '{s}' burada değiştirilemez (eşzamanlı worker'lar arasında senkronizasyonsuz mutasyon veri yarışına yol açar) — önce yerel bir kopya oluşturun", .{ fd_name, r.root_param });
                            }
                        },
                        else => {},
                    }
                    try self.checkTransitiveSpawnSharedMutationExpr(fd_name, a.value, params);
                },
                .var_decl => |v| try self.checkTransitiveSpawnSharedMutationExpr(fd_name, v.value, params),
                .return_stmt => |maybe_e| if (maybe_e) |e| try self.checkTransitiveSpawnSharedMutationExpr(fd_name, e, params),
                .raise_stmt => |e| try self.checkTransitiveSpawnSharedMutationExpr(fd_name, e, params),
                .expr_stmt => |e| {
                    if (e == .call) {
                        const c = e.call;
                        if (c.callee.* == .attribute) {
                            const at = c.callee.*.attribute;
                            if (std.mem.eql(u8, at.attr, "append") or std.mem.eql(u8, at.attr, "pop") or std.mem.eql(u8, at.attr, "sort")) {
                                if (self.resolveExprSharedType(at.obj.*, params)) |r| {
                                    if (r.ty == .list) {
                                        return self.fail(error.SpawnSharedMutation, "'{s}' fonksiyonu bir 'spawn' hedefi olduğundan, paylaşılan parametresi '{s}' burada değiştirilemez (eşzamanlı worker'lar arasında senkronizasyonsuz mutasyon veri yarışına yol açar) — önce yerel bir kopya oluşturun", .{ fd_name, r.root_param });
                                    }
                                }
                            }
                        }
                    }
                    try self.checkTransitiveSpawnSharedMutationExpr(fd_name, e, params);
                },
                .if_stmt => |i| {
                    try self.checkNoSpawnSharedMutation(fd_name, i.then_body, params);
                    for (i.elif_clauses) |ec| try self.checkNoSpawnSharedMutation(fd_name, ec.body, params);
                    if (i.else_body) |eb| try self.checkNoSpawnSharedMutation(fd_name, eb, params);
                },
                .while_stmt => |w| try self.checkNoSpawnSharedMutation(fd_name, w.body, params),
                .for_stmt => |f| try self.checkNoSpawnSharedMutation(fd_name, f.body, params),
                .try_stmt => |t| {
                    try self.checkNoSpawnSharedMutation(fd_name, t.try_body, params);
                    for (t.except_clauses) |ec| try self.checkNoSpawnSharedMutation(fd_name, ec.body, params);
                    if (t.finally_body) |fb| try self.checkNoSpawnSharedMutation(fd_name, fb, params);
                },
                .with_stmt => |w| try self.checkNoSpawnSharedMutation(fd_name, w.body, params),
                .lowlevel_stmt => |ll| try self.checkNoSpawnSharedMutation(fd_name, ll.body, params),
                // İç içe `func_def`/`class_def`: AYRI çağrılabilir birimler
                // — "transitif takip yok" kararıyla TUTARLI, İNİLMEZ.
                else => {},
            }
        }
    }

    /// v1.30.0/v1.34.0: `checkNoSpawnSharedMutation`/`resolveExprSharedType`
    /// tarafından paylaşılan bir "spawn-hedefi fonksiyonun `list`/`dict`/
    /// `class` tipli parametresi" kaydı — `ty` ARTIK (v1.34.0'dan İTİBAREN)
    /// TAM `Type` taşır (basitleştirilmiş bir enum DEĞİL), ÇÜNKÜ `.class`
    /// varyantının KENDİ sınıf ADINI (`ty.class`) taşıması `resolveExprSharedType`nin
    /// iç içe alan ÇÖZÜMLEMESİ İçİn GEREKLİDİR.
    const SharedParam = struct { name: []const u8, ty: Type };

    /// GG.22 (bkz. plan dosyası "spawn-sonrası çağıran-tarafı mutasyon
    /// boşluğu"): `checkDirectSharedMutationStmt`'nin AYNI DOĞRUDAN-mutasyon
    /// şekilleri (`checkNoSpawnSharedMutation`nin KENDİ şekilleriyle AYNI —
    /// index-atama/attribute-atama/`.append`/`.pop`/`.sort`) — AMA hedef
    /// `resolveExprSharedType`nin GÜCÜNÜ KULLANMAZ, SADECE ÇIPLAK bir
    /// `identifier`in `shared_in_flight`te olup OLMADIĞINI kontrol eder
    /// (v1 BİLİNÇLİ sınırı — bkz. plan dosyasının "Kapsam DIŞI" bölümü).
    /// HH.8 (bkz. plan dosyası "post-spawn checker'ına takma-ad [alias]
    /// farkındalığı"): `name`nin ÇIPLAK KENDİSİ DEĞİL, `points_to`den
    /// ÇÖZÜLEN soyut kaynak-kimlik(ler)i `resource_owners`de sahipli
    /// (non-empty) mi diye bakar — `ys = xs` (GERÇEK aliasing) SONRASI
    /// `ys` ÜZERİNDEN yapılan bir mutasyon da, `xs` spawn'a paylaşıldıysa,
    /// AYNI kaynak-kimliğine ÇÖZÜLDÜĞÜNDEN YAKALANIR.
    fn isResourceOwned(points_to: *const std.StringHashMapUnmanaged([]const usize), resource_owners: *const std.AutoHashMapUnmanaged(usize, []const usize), name: []const u8) bool {
        const rids = points_to.get(name) orelse return false;
        for (rids) |rid| {
            if (resource_owners.get(rid)) |owners| {
                if (owners.len > 0) return true;
            }
        }
        return false;
    }

    fn checkDirectSharedMutationStmt(self: *Checker, stmt: ast.Stmt, points_to: *const std.StringHashMapUnmanaged([]const usize), resource_owners: *const std.AutoHashMapUnmanaged(usize, []const usize)) TypeError!void {
        switch (stmt.kind) {
            .assign => |a| switch (a.target) {
                .index => |ix| if (ix.obj.* == .identifier and isResourceOwned(points_to, resource_owners, ix.obj.identifier)) {
                    return self.fail(error.SpawnSharedMutation, "'{s}' bir 'spawn' çağrısına paylaşılan argüman olarak geçtikten sonra, 'await' edilmeden önce burada değiştirilemez (eşzamanlı worker'lar arasında senkronizasyonsuz mutasyon veri yarışına yol açar) — önce 'await' edin ya da bir yerel kopya kullanın", .{ix.obj.identifier});
                },
                .attribute => |at| if (at.obj.* == .identifier and isResourceOwned(points_to, resource_owners, at.obj.identifier)) {
                    return self.fail(error.SpawnSharedMutation, "'{s}' bir 'spawn' çağrısına paylaşılan argüman olarak geçtikten sonra, 'await' edilmeden önce burada değiştirilemez (eşzamanlı worker'lar arasında senkronizasyonsuz mutasyon veri yarışına yol açar) — önce 'await' edin ya da bir yerel kopya kullanın", .{at.obj.identifier});
                },
                else => {},
            },
            .expr_stmt => |e| if (e == .call) {
                const c = e.call;
                if (c.callee.* == .attribute) {
                    const at = c.callee.attribute;
                    if (at.obj.* == .identifier and isResourceOwned(points_to, resource_owners, at.obj.identifier)) {
                        if (std.mem.eql(u8, at.attr, "append") or std.mem.eql(u8, at.attr, "pop") or std.mem.eql(u8, at.attr, "sort")) {
                            return self.fail(error.SpawnSharedMutation, "'{s}' bir 'spawn' çağrısına paylaşılan argüman olarak geçtikten sonra, 'await' edilmeden önce burada değiştirilemez (eşzamanlı worker'lar arasında senkronizasyonsuz mutasyon veri yarışına yol açar) — önce 'await' edin ya da bir yerel kopya kullanın", .{at.obj.identifier});
                        }
                    }
                }
            },
            else => {},
        }
    }

    /// HH.6/HH.7 (bkz. plan dosyaları): `checkTransitiveSpawnSharedMutationExpr`nin
    /// AYNI gezinme şekli — AMA HERHANGİ bir `.await_expr` bulduğunda,
    /// operandı `task_spawn_ids`teki BİR Task adına ÇÖZÜLÜYORSA, O Task'ın
    /// KENDİ spawn-ID'lerini `resource_owners`nin HER girdisinden ÇIKARIR
    /// (koşulsuz TÜM anahtarı SİLMEK YERİNE — v1.54.0/HH.5'in GERÇEK
    /// false-negative'i: `xs`i AYNI ANDA paylaşan İKİNCİ bir task VARSA,
    /// SADECE `t1`in await'i `xs`i "temiz" saymamalı). HH.7: `locked_resources`de
    /// OLAN isimler BU çıkarma işleminden TAMAMEN MUAF (döngü-tekrarlı
    /// spawn-site'ların KALICI kilidi — bkz. `lockRecurrentLoopOwnership`).
    /// Hashmap İTERASYONU SIRASINDA anahtar SİLİNEMEDİĞİNDEN, boşalan
    /// anahtarlar AYRI bir listede toplanıp gezinti BİTTİKTEN SONRA
    /// kaldırılır.
    fn removeAwaitedTaskSharing(self: *Checker, aa: std.mem.Allocator, expr: ast.Expr, task_spawn_ids: *const std.StringHashMapUnmanaged([]const usize), resource_owners: *std.AutoHashMapUnmanaged(usize, []const usize), locked_resources: *const std.AutoHashMapUnmanaged(usize, void)) TypeError!void {
        switch (expr) {
            .await_expr => |op| {
                if (op.* == .identifier) {
                    if (task_spawn_ids.get(op.identifier)) |awaited_ids| {
                        var keys_to_remove: std.ArrayListUnmanaged(usize) = .empty;
                        var it = resource_owners.iterator();
                        while (it.next()) |entry| {
                            if (locked_resources.contains(entry.key_ptr.*)) continue;
                            var remaining: std.ArrayListUnmanaged(usize) = .empty;
                            for (entry.value_ptr.*) |owner_id| {
                                var still_owned = true;
                                for (awaited_ids) |aid| {
                                    if (owner_id == aid) {
                                        still_owned = false;
                                        break;
                                    }
                                }
                                if (still_owned) try remaining.append(aa, owner_id);
                            }
                            if (remaining.items.len == 0) {
                                try keys_to_remove.append(aa, entry.key_ptr.*);
                            } else {
                                entry.value_ptr.* = try remaining.toOwnedSlice(aa);
                            }
                        }
                        for (keys_to_remove.items) |k| _ = resource_owners.remove(k);
                    }
                }
                try self.removeAwaitedTaskSharing(aa, op.*, task_spawn_ids, resource_owners, locked_resources);
            },
            .unary => |u| try self.removeAwaitedTaskSharing(aa, u.operand.*, task_spawn_ids, resource_owners, locked_resources),
            .binary => |b| {
                try self.removeAwaitedTaskSharing(aa, b.left.*, task_spawn_ids, resource_owners, locked_resources);
                try self.removeAwaitedTaskSharing(aa, b.right.*, task_spawn_ids, resource_owners, locked_resources);
            },
            .call => |c| {
                try self.removeAwaitedTaskSharing(aa, c.callee.*, task_spawn_ids, resource_owners, locked_resources);
                for (c.args) |a| try self.removeAwaitedTaskSharing(aa, a, task_spawn_ids, resource_owners, locked_resources);
            },
            .attribute => |a| try self.removeAwaitedTaskSharing(aa, a.obj.*, task_spawn_ids, resource_owners, locked_resources),
            .index => |ix| {
                try self.removeAwaitedTaskSharing(aa, ix.obj.*, task_spawn_ids, resource_owners, locked_resources);
                try self.removeAwaitedTaskSharing(aa, ix.index.*, task_spawn_ids, resource_owners, locked_resources);
            },
            .list_lit => |items| for (items) |it| try self.removeAwaitedTaskSharing(aa, it, task_spawn_ids, resource_owners, locked_resources),
            .dict_lit => |pairs| for (pairs) |p| {
                try self.removeAwaitedTaskSharing(aa, p.key, task_spawn_ids, resource_owners, locked_resources);
                try self.removeAwaitedTaskSharing(aa, p.value, task_spawn_ids, resource_owners, locked_resources);
            },
            .spawn_expr => |op| try self.removeAwaitedTaskSharing(aa, op.*, task_spawn_ids, resource_owners, locked_resources),
            .generic_construct => |g| for (g.args) |a| try self.removeAwaitedTaskSharing(aa, a, task_spawn_ids, resource_owners, locked_resources),
            .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => {},
        }
    }

    /// GG.22 (bkz. plan dosyası "spawn-sonrası çağıran-tarafı mutasyon
    /// boşluğu"): `checkNoSpawnSharedMutation` SADECE spawn-HEDEFİ
    /// fonksiyonun KENDİ gövdesini kontrol eder — bir `spawn` çağrısına
    /// paylaşılan bir `list`/`dict`/`class` yerel GEÇTİKTEN SONRA, çağıranın
    /// KENDİSİNİN bu değişkeni `await` edilmeden ÖNCE mutasyona uğratmasını
    /// HİÇBİR ŞEY KISITLAMIYORDU (`--release`/LLVM'de yapısal olarak İFADE
    /// edilebilen GERÇEK bir veri-yarışı boşluğu, çünkü list/dict/class
    /// SADECE `isSpawnParamSafeType`nin LLVM-gevşetmesiyle spawn-argümanı
    /// olabiliyor). Bu forward kontrol BUNU kapatır. `params`, `checkFunctionBody`
    /// İçİn `fd.params`, `checkModule`nin üst-düzey taraması İçİn BOŞ
    /// dilim olarak geçirilir — durumu (`known_types`/`shared_in_flight`/
    /// `task_to_shared`) KURUP `walkPostSpawnCallerMutation`e (aşağıda)
    /// devreder.
    fn checkNoPostSpawnCallerMutation(self: *Checker, stmts: []const ast.Stmt, params: []const ast.Param) TypeError!void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        var known_types: std.StringHashMapUnmanaged(Type) = .empty;
        var state: SpawnFlowState = .{};
        for (params) |p| {
            const pt = try self.typeExprToType(p.type_expr);
            try known_types.put(aa, p.name, pt);
            // HH.8: parametrenin KENDİ soyut kaynak-kimliği — `p.name.ptr`
            // (lexeme-slice, HERHANGİ bir global intern OLMADAN, DOĞRULANDI
            // stabil) — BU parametrenin BAŞKA bir isme ALIAS OLARAK
            // atanabilmesi İçİn (`ys: list[int] = xs`) gereken BAŞLANGIÇ
            // kimliği.
            switch (pt) {
                .list, .dict, .class => {
                    const one = try aa.dupe(usize, &.{@intFromPtr(p.name.ptr)});
                    try state.points_to.put(aa, p.name, one);
                },
                else => {},
            }
        }
        try self.walkPostSpawnCallerMutation(aa, stmts, &known_types, &state);
    }

    /// HH.6 (bkz. plan dosyası "post-spawn checker'ına çoklu-sahip [multi-
    /// owner] kaynak takibi"): `resource_owners`/`task_spawn_ids`in İKİSİ
    /// de AYNI şekle sahiptir (isim → spawn-site KİMLİK KÜMESİ, "isim →
    /// BOOLEAN" DEĞİL) — bu YÜZDEN TEK, PAYLAŞILAN `mergeUsizeListMap`
    /// yardımcısı İKİSİNİ de klonlayıp birleştirir. `spawn_id`, HER `spawn`
    /// ÇAĞRISININ KENDİ AST-düğüm POINTER'IDIR (`@intFromPtr(sv.spawn_expr)` —
    /// GG.15-18/HH.3'ün ZATEN kullandığı "AST düğüm-pointer = bu derleme-
    /// geçişi İçİn benzersiz kimlik" deseni, YENİ bir kimlik şeması GEREKMEZ).
    ///
    /// **HH.5'in "isim → BOOLEAN" temsili GERÇEK bir İKİNCİ false-negative
    /// İÇERİYORDU** (harici bir inceleme TARAFINDAN BULUNDU): `xs`i İKİ
    /// AYRI `spawn` PAYLAŞTIĞINDA, `await t1` `xs`i TAMAMEN "temiz" sayıyordu
    /// — `t2` HÂLÂ ÇALIŞIYOR olsa BİLE. `resource_owners["xs"] = [id1, id2]`
    /// İLE `await t1` SADECE `id1`i ÇIKARIR, `id2` (t2'nin sahipliği) KALIR,
    /// mutasyon HÂLÂ DOĞRU REDDEDİLİR.
    const SpawnFlowState = struct {
        /// HH.8 (bkz. plan dosyası "post-spawn checker'ına takma-ad [alias]
        /// farkındalığı"): isim → O ismin HÂLÂ referans VEREBİLECEĞİ soyut
        /// kaynak-kimlik(ler)i (`list`/`dict`/`class` tipli yereller/
        /// parametreler İçİn — bkz. `checkNoPostSpawnCallerMutation`nin
        /// parametre-seed'i VE `walkPostSpawnCallerMutation`nin `.var_decl`
        /// bloğu). `ys: list[int] = xs` (ÇIPLAK isim-den-isme atama — Nox'ta
        /// GERÇEK aliasing'in TEK kaynağı) `points_to["ys"] = points_to["xs"]`
        /// YAPARAK `ys`i `xs`YLE AYNI kaynağa BAĞLAR — spawn/mutasyon artık
        /// HANGİ İSİM kullanılırsa kullanılsın AYNI kaynağa ÇÖZÜLÜR.
        points_to: std.StringHashMapUnmanaged([]const usize) = .empty,
        /// kaynak-kimliği → HÂLÂ O kaynağı PAYLAŞAN spawn-site kimliklerinin
        /// listesi. Liste BOŞALDIĞINDA anahtar TAMAMEN kaldırılır (`get`
        /// HÂLÂ "hiçbir owner yok" anlamına DOĞRU gelsin diye). HH.8'DEN
        /// İTİBAREN İSİMLE DEĞİL kaynak-kimliğiyle KEYLENİR (alias-farkında
        /// takip İçİn ŞART).
        resource_owners: std.AutoHashMapUnmanaged(usize, []const usize) = .empty,
        /// task-değişkeni adı → O DEĞİŞKENE atanmış spawn-site kimlikleri
        /// (NORMALDE tek elemanlı — TEK bir `spawn` TEK bir task üretir —
        /// AMA dal-birleştirme SONUCU birden fazla OLABİLİR). Task
        /// değişkenleri list/dict/class DEĞİLDİR, alias-takibi GEREKMEZ —
        /// İSİMLE keylenmeye DEVAM eder.
        task_spawn_ids: std.StringHashMapUnmanaged([]const usize) = .empty,
        /// HH.7 (bkz. plan dosyası "post-spawn checker'ına döngü-tekrarlı
        /// spawn-site kilitlemesi"): bir döngü GÖVDESİNİN KENDİ İÇİNDE
        /// joinlemediği (fixpoint YAKINSADIKTAN SONRA HÂLÂ `resource_owners`de
        /// KALAN) HER YENİ sahiplik İçİn KALICI olarak KİLİTLENEN kaynak-
        /// kimlikleri — bu kaynaklar ARTIK HİÇBİR SONRAKİ `await` İLE
        /// (fonksiyonun KALANI BOYUNCA) TEMİZLENEMEZ (fire-and-forget'in
        /// AYNI "SONSUZA KADAR uçuşta" disipliniyle TUTARLI — bkz.
        /// `lockRecurrentLoopOwnership`). HH.8'DEN İTİBAREN İSİMLE DEĞİL
        /// kaynak-kimliğiyle KEYLENİR. KÖK NEDEN: bir `spawn` çağrısının
        /// `spawn_id`si (AST-düğüm pointer'ı) HER fixpoint iterasyonunda
        /// AYNIDIR — döngü GERÇEKTE N AYRI runtime Task'ı ÜRETSE de, TEK
        /// bir owner OLARAK dedup edilir; döngü SONRASI TEK bir `await`,
        /// SADECE SON iterasyonun task'ını joinler, ÖNCEKİ iterasyonların
        /// task'ları HÂLÂ ÇALIŞIYOR OLABİLİR.
        locked_resources: std.AutoHashMapUnmanaged(usize, void) = .empty,

        fn clone(self: SpawnFlowState, aa: std.mem.Allocator) !SpawnFlowState {
            var out: SpawnFlowState = .{};
            var it0 = self.points_to.iterator();
            while (it0.next()) |e| try out.points_to.put(aa, e.key_ptr.*, e.value_ptr.*);
            var it1 = self.resource_owners.iterator();
            while (it1.next()) |e| try out.resource_owners.put(aa, e.key_ptr.*, e.value_ptr.*);
            var it2 = self.task_spawn_ids.iterator();
            while (it2.next()) |e| try out.task_spawn_ids.put(aa, e.key_ptr.*, e.value_ptr.*);
            var it3 = self.locked_resources.keyIterator();
            while (it3.next()) |k| try out.locked_resources.put(aa, k.*, {});
            return out;
        }

        /// "May" (union) birleştirme — `other`daki HERHANGİ bir points-to/
        /// owner/task-eşlemesi/kilit SONUÇTA da (HANGİ dal GERÇEKTEN
        /// çalışırsa çalışsın) olası sayılır. DEĞİŞİKLİK olduysa `true`
        /// döner (döngü fixpoint'i İçİn).
        fn mergeFrom(self: *SpawnFlowState, aa: std.mem.Allocator, other: SpawnFlowState) !bool {
            const c0 = try mergeUsizeListMap(aa, &self.points_to, other.points_to);
            const c1 = try mergeResourceOwnersMap(aa, &self.resource_owners, other.resource_owners);
            const c2 = try mergeUsizeListMap(aa, &self.task_spawn_ids, other.task_spawn_ids);
            var c3 = false;
            var it3 = other.locked_resources.keyIterator();
            while (it3.next()) |k| {
                const gop = try self.locked_resources.getOrPut(aa, k.*);
                if (!gop.found_existing) c3 = true;
            }
            return c0 or c1 or c2 or c3;
        }
    };

    /// HH.6: `SpawnFlowState`nin İKİ alanının da PAYLAŞTIĞI, dedup-union
    /// birleştirme mantığı — TEK generic fonksiyon (HH.5'in İKİ AYRI el-
    /// yazımı bloğu YERİNE).
    fn mergeUsizeListMap(aa: std.mem.Allocator, self_map: *std.StringHashMapUnmanaged([]const usize), other_map: std.StringHashMapUnmanaged([]const usize)) !bool {
        var changed = false;
        var it = other_map.iterator();
        while (it.next()) |e| {
            if (self_map.getPtr(e.key_ptr.*)) |existing| {
                var merged_list: std.ArrayListUnmanaged(usize) = .empty;
                try merged_list.appendSlice(aa, existing.*);
                var grew = false;
                for (e.value_ptr.*) |id| {
                    var found = false;
                    for (existing.*) |m| {
                        if (m == id) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try merged_list.append(aa, id);
                        grew = true;
                    }
                }
                if (grew) {
                    existing.* = try merged_list.toOwnedSlice(aa);
                    changed = true;
                }
            } else {
                try self_map.put(aa, e.key_ptr.*, e.value_ptr.*);
                changed = true;
            }
        }
        return changed;
    }

    /// HH.8: `mergeUsizeListMap`nin AYNI dedup-union mantığı — SADECE
    /// anahtar tipi `usize` (kaynak-kimliği, `resource_owners`/`locked_resources`
    /// İçİn) — Zig'in generic-OLMAYAN HashMap türleri arası KOD paylaşımı
    /// PRATİK olmadığından KASITLI, küçük bir tekrar (HH.6'nın AYNI kararı).
    fn mergeResourceOwnersMap(aa: std.mem.Allocator, self_map: *std.AutoHashMapUnmanaged(usize, []const usize), other_map: std.AutoHashMapUnmanaged(usize, []const usize)) !bool {
        var changed = false;
        var it = other_map.iterator();
        while (it.next()) |e| {
            if (self_map.getPtr(e.key_ptr.*)) |existing| {
                var merged_list: std.ArrayListUnmanaged(usize) = .empty;
                try merged_list.appendSlice(aa, existing.*);
                var grew = false;
                for (e.value_ptr.*) |id| {
                    var found = false;
                    for (existing.*) |m| {
                        if (m == id) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try merged_list.append(aa, id);
                        grew = true;
                    }
                }
                if (grew) {
                    existing.* = try merged_list.toOwnedSlice(aa);
                    changed = true;
                }
            } else {
                try self_map.put(aa, e.key_ptr.*, e.value_ptr.*);
                changed = true;
            }
        }
        return changed;
    }

    /// HH.6: `map[name]`e `id`i dedup-ederek EKLER (yoksa YENİ, tek-elemanlı
    /// bir girdi oluşturur).
    fn addSpawnOwner(aa: std.mem.Allocator, map: *std.StringHashMapUnmanaged([]const usize), name: []const u8, id: usize) !void {
        if (map.getPtr(name)) |existing| {
            for (existing.*) |e| if (e == id) return;
            var list: std.ArrayListUnmanaged(usize) = .empty;
            try list.appendSlice(aa, existing.*);
            try list.append(aa, id);
            existing.* = try list.toOwnedSlice(aa);
        } else {
            const one = try aa.dupe(usize, &.{id});
            try map.put(aa, name, one);
        }
    }

    /// HH.8: `addSpawnOwner`nin AYNI dedup-ekleme mantığı — SADECE anahtar
    /// tipi `usize` (kaynak-kimliği) — `resource_owners`nin spawn-tespiti
    /// yazma noktası İçİn.
    fn addSpawnOwnerUsize(aa: std.mem.Allocator, map: *std.AutoHashMapUnmanaged(usize, []const usize), key: usize, id: usize) !void {
        if (map.getPtr(key)) |existing| {
            for (existing.*) |e| if (e == id) return;
            var list: std.ArrayListUnmanaged(usize) = .empty;
            try list.appendSlice(aa, existing.*);
            try list.append(aa, id);
            existing.* = try list.toOwnedSlice(aa);
        } else {
            const one = try aa.dupe(usize, &.{id});
            try map.put(aa, key, one);
        }
    }

    /// HH.6: fixpoint cap'i (`MAX_LOOP_FIXPOINT_ITERATIONS`) AŞILDIĞINDA
    /// (VE state HÂLÂ değişiyorsa) SAVUNMA-DERİNLİĞİ olarak — `known_types`teki
    /// HER `list`/`dict`/`class` tipli ismi, HİÇBİR `await`in ASLA
    /// KALDIRAMAYACAĞI bir SENTİNEL kimlikle `resource_owners`e EKLER
    /// (harici bir incelemenin önerisi: "cap'e ulaşıldığında GÜVENLİ
    /// tarafta kal" — TEORİK olarak erken durmak ALT-yaklaşım OLABİLİR,
    /// GERÇEKÇİ HİÇBİR fonksiyon 64 iterasyonu AŞMAYACAĞINDAN pratikte HİÇ
    /// tetiklenmez).
    const CONSERVATIVE_FALLBACK_SPAWN_ID: usize = std.math.maxInt(usize);

    fn forceConservativeState(self: *Checker, aa: std.mem.Allocator, known_types: *const std.StringHashMapUnmanaged(Type), state: *SpawnFlowState) !void {
        _ = self;
        var it = known_types.iterator();
        while (it.next()) |e| {
            switch (e.value_ptr.*) {
                .list, .dict, .class => {
                    if (state.points_to.get(e.key_ptr.*)) |rids| {
                        for (rids) |rid| try addSpawnOwnerUsize(aa, &state.resource_owners, rid, CONSERVATIVE_FALLBACK_SPAWN_ID);
                    }
                },
                else => {},
            }
        }
    }

    /// HH.5: `state`in tükenene KADAR (`mergeFrom` `false` DÖNENE KADAR)
    /// döngü gövdesini TEKRAR TEKRAR analiz eden GERÇEK bir fixpoint —
    /// v1.51.0'ın (HH.2) "iki-geçiş" yaklaşımının YERİNE (harici incelemenin
    /// önerisi). **Sonlanma KANITI**: `state` HER iterasyonda SADECE
    /// BÜYÜYEBİLİR (`mergeFrom` ASLA bir anahtarı SİLMEZ, SADECE EKLER) —
    /// İSİM UZAYI (fonksiyondaki BELİRLİ değişken/task adları) SONLU
    /// olduğundan, dizi EN FAZLA "toplam DİSTİNCT isim sayısı" KADAR
    /// iterasyonda `changed=false`e ULAŞIP SONLANIR — `MAX_LOOP_FIXPOINT_ITERATIONS`
    /// SADECE bir SAVUNMA-DERİNLİĞİ sınırı (GERÇEKÇİ HİÇBİR fonksiyonun
    /// bu kadar DİSTİNCT paylaşılan-isim İçERMESİ BEKLENMEZ) — cap'e
    /// GERÇEKTEN ulaşılırsa (HH.6) `forceConservativeState` İLE GÜVENLİ
    /// tarafta KALINIR.
    const MAX_LOOP_FIXPOINT_ITERATIONS: usize = 64;

    /// HH.7: fixpoint YAKINSADIKTAN SONRA çağrılır — `pre_loop` (döngü
    /// BAŞLAMADAN ÖNCEKİ durum) İLE KARŞILAŞTIRIP, `state.resource_owners`de
    /// HÂLÂ KALAN (yani gövdenin KENDİ İÇİNDE joinlenmediği KANITLANAN) HER
    /// YENİ (pre_loop'ta OLMAYAN) sahiplik İçİn O ismi KALICI olarak
    /// KİLİTLER. Güvenli desen (spawn+await AYNI iterasyon İçİnde eşleşiyor)
    /// İçİn `resource_owners` fixpoint SONUNDA ZATEN BOŞ olduğundan, BU
    /// fonksiyon HİÇBİR ŞEYİ YANLIŞLIKLA kilitlemez.
    fn lockRecurrentLoopOwnership(self: *Checker, aa: std.mem.Allocator, pre_loop: SpawnFlowState, state: *SpawnFlowState) !void {
        _ = self;
        var it = state.resource_owners.iterator();
        while (it.next()) |entry| {
            const pre_ids = pre_loop.resource_owners.get(entry.key_ptr.*) orelse &.{};
            for (entry.value_ptr.*) |id| {
                var was_pre_existing = false;
                for (pre_ids) |p| {
                    if (p == id) {
                        was_pre_existing = true;
                        break;
                    }
                }
                if (!was_pre_existing) {
                    try state.locked_resources.put(aa, entry.key_ptr.*, {});
                    break;
                }
            }
        }
    }

    fn iterateLoopToFixpoint(
        self: *Checker,
        aa: std.mem.Allocator,
        body: []const ast.Stmt,
        known_types: *std.StringHashMapUnmanaged(Type),
        state: *SpawnFlowState,
    ) TypeError!void {
        const pre_loop = try state.clone(aa);
        var iterations: usize = 0;
        while (true) {
            iterations += 1;
            var body_state = try state.clone(aa);
            try self.walkPostSpawnCallerMutation(aa, body, known_types, &body_state);
            const changed = try state.mergeFrom(aa, body_state);
            if (!changed) {
                try self.lockRecurrentLoopOwnership(aa, pre_loop, state);
                return;
            }
            if (iterations >= MAX_LOOP_FIXPOINT_ITERATIONS) {
                try self.forceConservativeState(aa, known_types, state);
                return;
            }
        }
    }

    /// GG.HH.2/HH.5 (bkz. plan dosyaları): `checkNoPostSpawnCallerMutation`nin
    /// ÖZYİNELEMELİ çekirdeği — `if`/`elif`/`else` VE `while`/`for`
    /// gövdelerine İNER (`checkNoSpawnSharedMutation`nin AYNI switch-kolu
    /// şekli, checker.zig:2483). `try`/`except`/`finally`/`with`/`lowlevel`/
    /// İÇ İÇE `func_def`/`class_def` BİLİNÇLİ olarak KAPSAM DIŞI KALIR
    /// (AYRI, gelecekteki bir tur).
    ///
    /// **HH.5: branch-başına KLON + çıkışta UNION-birleştirme** (bkz.
    /// `SpawnFlowState`/`iterateLoopToFixpoint`nin belge notları) —
    /// HH.2'nin "tek, threading edilen durum" tasarımı harici bir
    /// incelemeyle GERÇEK bir false-negative İÇERDİĞİ BULUNUP BU sürümde
    /// düzeltildi (bkz. plan dosyası "HH.5" bölümünün Context'i).
    fn walkPostSpawnCallerMutation(
        self: *Checker,
        aa: std.mem.Allocator,
        stmts: []const ast.Stmt,
        known_types: *std.StringHashMapUnmanaged(Type),
        state: *SpawnFlowState,
    ) TypeError!void {
        for (stmts) |stmt| {
            self.current_line = stmt.line;
            self.current_span = stmt.span;

            // (1) Mutasyon kontrolü — BU deyimin KENDİ (2)/(3) işlemlerinden
            // ÖNCEKİ `points_to`/`resource_owners` durumuna göre.
            try self.checkDirectSharedMutationStmt(stmt, &state.points_to, &state.resource_owners);

            if (stmt.kind == .var_decl) {
                const v = stmt.kind.var_decl;
                const vt = self.typeExprToType(v.type_expr) catch .none;
                try known_types.put(aa, v.name, vt);
                // HH.8: `points_to` güncellemesi — SADECE list/dict/class
                // tipli yerellerde ANLAMLI. `ys = xs` (ÇIPLAK isim-den-isme
                // atama) ALIAS'tır: `points_to[ys]`, `points_to[xs]`nin
                // AYNI dizi REFERANSINI PAYLAŞIR. Bir literal/sınıf-kurucusu
                // İSE YENİ, tek-elemanlı bir kaynak-kimliği ATANIR (GG.15/
                // HH.5'in AYNI "AST-düğüm pointer/slice.ptr = benzersiz
                // kimlik" deseni). BAŞKA HERHANGİ bir RHS şekli (fonksiyon-
                // çağrısı dönüşü, attribute erişimi, vb.) İçİn HİÇBİR
                // kaynak-kimliği ATANMAZ (v1 BİLİNÇLİ sınırı).
                switch (vt) {
                    .list, .dict, .class => {
                        switch (v.value) {
                            .list_lit => |elems| {
                                const one = try aa.dupe(usize, &.{@intFromPtr(elems.ptr)});
                                try state.points_to.put(aa, v.name, one);
                            },
                            .dict_lit => |pairs| {
                                const one = try aa.dupe(usize, &.{@intFromPtr(pairs.ptr)});
                                try state.points_to.put(aa, v.name, one);
                            },
                            .call => |c| if (c.callee.* == .identifier) {
                                const one = try aa.dupe(usize, &.{@intFromPtr(c.callee)});
                                try state.points_to.put(aa, v.name, one);
                            },
                            .identifier => |src_name| if (state.points_to.get(src_name)) |src_ids| {
                                try state.points_to.put(aa, v.name, src_ids);
                            },
                            else => {},
                        }
                    },
                    else => {},
                }
            }

            // (2) `spawn` tespiti — bu deyimin DEĞERİ (var_decl/assign) VEYA
            // `expr_stmt`in KENDİSİ doğrudan bir `spawn_expr` İSE.
            var spawn_value: ?ast.Expr = null;
            var decl_name: ?[]const u8 = null;
            switch (stmt.kind) {
                .var_decl => |v| {
                    spawn_value = v.value;
                    decl_name = v.name;
                },
                .assign => |a| spawn_value = a.value,
                .expr_stmt => |e| spawn_value = e,
                else => {},
            }
            if (spawn_value) |sv| {
                if (sv == .spawn_expr and sv.spawn_expr.* == .call) {
                    const c = sv.spawn_expr.*.call;
                    // HH.6: HER spawn ÇAĞRISININ KENDİ AST-düğüm pointer'ı
                    // — bu derleme-geçişi İçİn benzersiz "spawn-site kimliği"
                    // (GG.15-18/HH.3'ün AYNI `@intFromPtr(...)` deseni).
                    const spawn_id: usize = @intFromPtr(sv.spawn_expr);
                    var any_shared = false;
                    for (c.args) |arg| {
                        if (arg == .identifier) {
                            if (known_types.get(arg.identifier)) |t| {
                                if (t == .list or t == .dict or t == .class) {
                                    any_shared = true;
                                    // HH.8: `arg.identifier`in ÇIPLAK KENDİSİ
                                    // DEĞİL, `points_to`den ÇÖZÜLEN kaynak-
                                    // kimlik(ler)i owned İŞARETLENİR — BÖYLECE
                                    // BAŞKA bir isim (`ys`) AYNI kaynağa ALIAS
                                    // OLDUĞUNDA da AYNI owner kaydını GÖRÜR.
                                    if (state.points_to.get(arg.identifier)) |rids| {
                                        for (rids) |rid| try addSpawnOwnerUsize(aa, &state.resource_owners, rid, spawn_id);
                                    }
                                }
                            }
                        }
                    }
                    if (decl_name) |dn| {
                        if (any_shared) try addSpawnOwner(aa, &state.task_spawn_ids, dn, spawn_id);
                    } else {
                        // Fire-and-forget (`spawn worker(xs)`, isimsiz) —
                        // BİLİNÇLİ olarak `task_spawn_ids`e HİÇ KAYDEDİLMEZ,
                        // bu YÜZDEN bu spawn-ID'si HİÇBİR ZAMAN `await` İLE
                        // TEMİZLENEMEZ (fonksiyonun KALANI BOYUNCA "uçuşta"
                        // kalır — muhafazakâr, KASITLI davranış).
                    }
                }
            }

            // (3) `await` tespiti — deyimin İLGİLİ ifadesinin HERHANGİ bir
            // YERİNDE (genel gezinme İLE).
            switch (stmt.kind) {
                .var_decl => |v| try self.removeAwaitedTaskSharing(aa, v.value, &state.task_spawn_ids, &state.resource_owners, &state.locked_resources),
                .assign => |a| try self.removeAwaitedTaskSharing(aa, a.value, &state.task_spawn_ids, &state.resource_owners, &state.locked_resources),
                .expr_stmt => |e| try self.removeAwaitedTaskSharing(aa, e, &state.task_spawn_ids, &state.resource_owners, &state.locked_resources),
                .return_stmt => |maybe_e| if (maybe_e) |e| try self.removeAwaitedTaskSharing(aa, e, &state.task_spawn_ids, &state.resource_owners, &state.locked_resources),
                .raise_stmt => |e| try self.removeAwaitedTaskSharing(aa, e, &state.task_spawn_ids, &state.resource_owners, &state.locked_resources),
                else => {},
            }

            // (4) CFG'ye özyineleme — if/elif/else VE while/for gövdeleri.
            switch (stmt.kind) {
                .if_stmt => |i| {
                    var then_state = try state.clone(aa);
                    try self.walkPostSpawnCallerMutation(aa, i.then_body, known_types, &then_state);
                    var merged = then_state;
                    for (i.elif_clauses) |ec| {
                        var ec_state = try state.clone(aa);
                        try self.walkPostSpawnCallerMutation(aa, ec.body, known_types, &ec_state);
                        _ = try merged.mergeFrom(aa, ec_state);
                    }
                    if (i.else_body) |eb| {
                        var else_state = try state.clone(aa);
                        try self.walkPostSpawnCallerMutation(aa, eb, known_types, &else_state);
                        _ = try merged.mergeFrom(aa, else_state);
                    } else {
                        // Zımni "else: pass" dalı — GİRİŞ durumu (state.*,
                        // HENÜZ DEĞİŞTİRİLMEDİ) birleşime KATILIR (spawn
                        // bir dalın İÇİNDE olduysa, if KAPANDIKTAN SONRA da
                        // "hâlâ uçuşta" sayılmaya DEVAM eder — HH.2'nin
                        // KASITLI, aşırı-muhafazakâr davranışı KORUNUR).
                        _ = try merged.mergeFrom(aa, state.*);
                    }
                    state.* = merged;
                },
                .while_stmt => |w| try self.iterateLoopToFixpoint(aa, w.body, known_types, state),
                .for_stmt => |f| try self.iterateLoopToFixpoint(aa, f.body, known_types, state),
                else => {},
            }
        }
    }

    fn checkFunctionBody(self: *Checker, fd: ast.FuncDef) TypeError!void {
        var scope: Scope = .{};
        const is_spawn_target = self.spawn_target_functions.contains(fd.name);
        var shared_params: std.ArrayListUnmanaged(SharedParam) = .empty;
        defer shared_params.deinit(self.allocator);
        for (fd.params) |p| {
            const pt = try self.typeExprToType(p.type_expr);
            try scope.declare(self.allocator, p.name, pt);
            if (is_spawn_target) {
                const is_shared_kind = switch (pt) {
                    .list, .dict, .class => true,
                    else => false,
                };
                if (is_shared_kind) try shared_params.append(self.allocator, .{ .name = p.name, .ty = pt });
            }
        }
        if (shared_params.items.len > 0) {
            try self.checkNoSpawnSharedMutation(fd.name, fd.body, shared_params.items);
        }
        // GG.22: bu, `is_spawn_target`den BAĞIMSIZDIR — HERHANGİ bir
        // fonksiyon bir `spawn` çağırabilir (spawn'ın HEDEFİ olmasına GEREK
        // YOK), bu YÜZDEN her fonksiyon gövdesi bu YENİ, AYRI kontrolden
        // geçirilir (bkz. `checkNoPostSpawnCallerMutation`nin belge notu).
        try self.checkNoPostSpawnCallerMutation(fd.body, fd.params);
        const ret = try self.typeExprToType(fd.return_type);
        var ctx: FnCtx = .{ .scope = &scope, .expected_return = ret, .in_async = fd.is_async, .path = fd.name };
        for (fd.body) |s| try self.checkStmt(&ctx, s);
        if (ret != .none and !alwaysReturns(fd.body)) {
            return self.fail(error.MissingReturn, "fonksiyon '{s}' tüm yollarda değer döndürmüyor", .{fd.name});
        }
    }

    /// Faz 7 (tekli kalıtım): `cd`nin gövdesini, taban sınıfının (varsa)
    /// gövdesi ZATEN denetlenmiş OLDUĞUNDAN EMİN OLARAK denetler — bir
    /// tabanın `__init__`inde `self.<ad> = ...` İLE (AÇIKÇA bir `FieldDecl`
    /// OLMADAN) ÇIKARSANAN alanlar SADECE o tabanın KENDİ `checkClassBody`si
    /// ÇALIŞTIKTAN SONRA `info.fields`e girer (bkz. `checkAssign`in
    /// `.attribute` dalı) — `registerClassSignatures` (Geçiş 2) BUNU henüz
    /// YAKALAYAMAMIŞTI (SADECE açıkça bildirilen alanlar/metod imzaları
    /// o AŞAMADA tamdır). `checkModule`nin ana döngüsü `class_def`i METİNSEL
    /// sırada ziyaret ETSE de (`Derived` `Base`den ÖNCE de YAZILABİLİR),
    /// bu fonksiyon taban zincirini GEREKTİĞİNDE (yalnızca kalıtım
    /// KULLANILDIĞINDA — kalıtımsız sınıflar İçin `cd.base == null`,
    /// davranış BİREBİR ÖNCEKİ GİBİ KALIR) ÖNCE ÇAĞIRARAK doğru sırayı
    /// GARANTİ EDER; `class_body_checked` her sınıfı EN FAZLA BİR KEZ
    /// denetler (metinsel döngü, BU fonksiyon TARAFINDAN ÖNCEDEN ÇOKTAN
    /// denetlenmiş bir tabanla TEKRAR karşılaştığında NO-OP olur).
    fn ensureClassBodyChecked(self: *Checker, cd: ast.ClassDef) TypeError!void {
        if (self.class_body_checked.contains(cd.name)) return;
        try self.class_body_checked.put(self.allocator, cd.name, {});
        if (cd.base) |base_name| {
            if (self.class_defs_by_name.get(base_name)) |base_cd| {
                try self.ensureClassBodyChecked(base_cd);
                // Taban gövdesi ARTIK denetlendi (ÇIKARSANMIŞ alanlar DAHİL
                // TAM) — bu alanları ŞİMDİ türetilene TAMAMLAYICI olarak
                // KOPYALA (Geçiş 2'nin kopyalaması SADECE o anda bilinen,
                // yani AÇIKÇA bildirilen, alanları yakalayabilmişti; zaten
                // VAR olan bir alanın ÜZERİNE YAZILMAZ — türetilenin KENDİ
                // AÇIKÇA bildirdiği/ÇIKARSADIĞI bir alan HER ZAMAN ÖNCELİKLİDİR).
                const base_info = self.classes.get(base_name).?;
                const info = self.classes.getPtr(cd.name).?;
                var field_it = base_info.fields.iterator();
                while (field_it.next()) |e| {
                    if (!info.fields.contains(e.key_ptr.*)) {
                        try info.fields.put(self.allocator, e.key_ptr.*, e.value_ptr.*);
                    }
                }
            }
        }
        self.checkClassBody(cd) catch |e| try self.recordDiagnostic(e);
    }

    fn checkClassBody(self: *Checker, cd: ast.ClassDef) TypeError!void {
        const diagnostics_before_init = self.diagnostics.items.len;
        for (cd.methods) |m| {
            if (std.mem.eql(u8, m.name, "__init__"))
                self.checkMethodBody(cd.name, m, true) catch |e| try self.recordDiagnostic(e);
        }
        // Faz FF.5 (bkz. nox-teknik-spesifikasyon.md §3.64): `__init__`
        // denetiminden HEMEN SONRA, DİĞER metodların döngüsünden ÖNCE —
        // bu SIRALAMA, bir alanın YALNIZCA `__init__` DIŞINDA bir metodda
        // atanmasının HÂLÂ "atanmadı" SAYILMASINI sağlar (o metod HENÜZ
        // denetlenmedi). `diagnostics_before_init`e göre KOŞULLU: `__init__`
        // BAŞKA bir nedenle ZATEN BAŞARISIZ olduysa (o hata ZATEN
        // kaydedildiyse), `declared_unassigned` YARIM kalmış (kontrol İLK
        // hatada DURDUĞUNDAN) OLABİLİR — bu durumda İKİNCİ, YANILTICI bir
        // "atanmadı" tanısı EKLEMEK YERİNE atlanır (bkz. modül üstü not,
        // "AYNI birim İÇİNDE İKİNCİ hata raporlanMAZ" kuralıyla TUTARLI).
        if (self.diagnostics.items.len == diagnostics_before_init) {
            const info = self.classes.getPtr(cd.name).?;
            var it = info.declared_unassigned.keyIterator();
            while (it.next()) |name| {
                try self.recordDiagnostic(self.fail(error.UnassignedField, "sınıf '{s}'in bildirilen '{s}' alanı __init__ içinde hiç atanmıyor", .{ cd.name, name.* }));
            }
        }
        for (cd.methods) |m| {
            if (!std.mem.eql(u8, m.name, "__init__"))
                self.checkMethodBody(cd.name, m, false) catch |e| try self.recordDiagnostic(e);
        }
    }

    fn checkMethodBody(self: *Checker, class_name: []const u8, m: ast.FuncDef, is_init: bool) TypeError!void {
        var scope: Scope = .{};
        for (m.params) |p| {
            const pt = try self.typeExprToType(p.type_expr);
            try scope.declare(self.allocator, p.name, pt);
        }
        const ret = try self.typeExprToType(m.return_type);
        const path = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ class_name, m.name });
        var ctx: FnCtx = .{ .scope = &scope, .expected_return = ret, .self_class = class_name, .is_init = is_init, .path = path };
        for (m.body) |s| try self.checkStmt(&ctx, s);
        if (ret != .none and !alwaysReturns(m.body)) {
            return self.fail(error.MissingReturn, "metod '{s}.{s}' tüm yollarda değer döndürmüyor", .{ class_name, m.name });
        }
    }

    /// Bir deyim dizisinin, ulaştığı her yolda kesinlikle `return` ile
    /// sonlandığını muhafazakâr biçimde belirler (yalnızca `if/elif/else`
    /// dallarının TÜMÜNÜN döndürdüğü kanıtlanabilir durumlar sayılır;
    /// `while`/`for` gövdeleri en az bir kez çalışacağı varsayılmaz).
    fn alwaysReturns(stmts: []const ast.Stmt) bool {
        if (stmts.len == 0) return false;
        return switch (stmts[stmts.len - 1].kind) {
            .return_stmt, .raise_stmt => true,
            .if_stmt => |f| blk: {
                if (f.else_body == null) break :blk false;
                if (!alwaysReturns(f.then_body)) break :blk false;
                for (f.elif_clauses) |ec| {
                    if (!alwaysReturns(ec.body)) break :blk false;
                }
                break :blk alwaysReturns(f.else_body.?);
            },
            .try_stmt => |t| blk: {
                if (t.finally_body) |fb| {
                    if (alwaysReturns(fb)) break :blk true;
                }
                if (!alwaysReturns(t.try_body)) break :blk false;
                for (t.except_clauses) |ec| {
                    if (!alwaysReturns(ec.body)) break :blk false;
                }
                break :blk t.except_clauses.len > 0;
            },
            .lowlevel_stmt => |ll| alwaysReturns(ll.body),
            else => false,
        };
    }

    fn checkStmt(self: *Checker, ctx: *FnCtx, stmt: ast.Stmt) TypeError!void {
        // Faz T.1: `fail`in okuduğu "şu an neredeyiz" konumu — bkz.
        // `ast.Stmt`in belge notu (DEYİM granülerliği). Bu, `checkStmt`in
        // TEK, özyinelemeli dağıtım noktası olması SAYESİNDE HER iç içe
        // deyim (if/while/for gövdeleri DAHİL) İÇİN otomatik doğru çalışır.
        self.current_line = stmt.line;
        self.current_span = stmt.span;
        switch (stmt.kind) {
            .expr_stmt => |e| _ = try self.checkExpr(ctx, e),
            .var_decl => |v| {
                const declared = try self.typeExprToType(v.type_expr);
                const value_t = try self.checkExprExpected(ctx, v.value, declared);
                if (!self.assignable(declared, value_t)) {
                    return self.fail(error.TypeMismatch, "'{s}' için tip uyuşmazlığı", .{v.name});
                }
                try ctx.scope.declare(self.allocator, v.name, declared);
            },
            .assign => |a| try self.checkAssign(ctx, a),
            .if_stmt => |f| {
                const ct = try self.checkExpr(ctx, f.cond);
                if (ct != .boolean) return self.fail(error.TypeMismatch, "'if' koşulu bool olmalıdır", .{});
                // Faz FF.6 (bkz. nox-teknik-spesifikasyon.md §3.65): DAR,
                // örüntü-tabanlı daraltma — yalnızca `if x != None:`/`if x
                // == None:` (KENDİ scope'unun DOĞRUDAN bir YERELİ olan `x`
                // için) TANINIR. Genel bir kontrol-akışı analizi DEĞİLDİR;
                // `elif` dalları HİÇ daraltılmaz (bkz. `detectNarrowing`in
                // belge notu) — bu, ÖZELLİKLE dar tutulan, BİLİNÇLİ bir v1
                // kapsamıdır.
                if (detectNarrowing(f.cond, ctx.scope)) |n| {
                    const prior = ctx.narrowed.get(n.name);
                    if (n.narrows_then) {
                        try ctx.narrowed.put(self.allocator, n.name, n.base);
                        for (f.then_body) |s| try self.checkStmt(ctx, s);
                        if (prior) |p| try ctx.narrowed.put(self.allocator, n.name, p) else _ = ctx.narrowed.remove(n.name);
                        for (f.elif_clauses) |ec| {
                            const ect = try self.checkExpr(ctx, ec.cond);
                            if (ect != .boolean) return self.fail(error.TypeMismatch, "'elif' koşulu bool olmalıdır", .{});
                            for (ec.body) |s| try self.checkStmt(ctx, s);
                        }
                        if (f.else_body) |eb| for (eb) |s| try self.checkStmt(ctx, s);
                    } else {
                        for (f.then_body) |s| try self.checkStmt(ctx, s);
                        for (f.elif_clauses) |ec| {
                            const ect = try self.checkExpr(ctx, ec.cond);
                            if (ect != .boolean) return self.fail(error.TypeMismatch, "'elif' koşulu bool olmalıdır", .{});
                            for (ec.body) |s| try self.checkStmt(ctx, s);
                        }
                        if (f.else_body) |eb| {
                            try ctx.narrowed.put(self.allocator, n.name, n.base);
                            for (eb) |s| try self.checkStmt(ctx, s);
                            if (prior) |p| try ctx.narrowed.put(self.allocator, n.name, p) else _ = ctx.narrowed.remove(n.name);
                        }
                    }
                    return;
                }
                for (f.then_body) |s| try self.checkStmt(ctx, s);
                for (f.elif_clauses) |ec| {
                    const ect = try self.checkExpr(ctx, ec.cond);
                    if (ect != .boolean) return self.fail(error.TypeMismatch, "'elif' koşulu bool olmalıdır", .{});
                    for (ec.body) |s| try self.checkStmt(ctx, s);
                }
                if (f.else_body) |eb| for (eb) |s| try self.checkStmt(ctx, s);
            },
            .while_stmt => |w| {
                const ct = try self.checkExpr(ctx, w.cond);
                if (ct != .boolean) return self.fail(error.TypeMismatch, "'while' koşulu bool olmalıdır", .{});
                // Faz FF.6: `while x != None:` — `if`in AYNI DAR
                // `detectNarrowing` örüntüsü, bağlı liste/ağaç TRAVERSAL'ı
                // (bu özelliğin asıl motive edici kullanım örneği) İÇİN
                // GEREKLİ. `while x == None:` (narrows_then=false) İSE gövde
                // İÇİNDE daraltma YAPILMAZ (gövde YALNIZCA x HÂLÂ None İKEN
                // çalışır) — bu yüzden yalnızca `narrows_then` durumu ele
                // alınır. Döngü SONRASI `x` HER ZAMAN Optional'a GERİ DÖNER
                // (bir `break` gövde İÇİNDE x HÂLÂ Optional İKEN çıkabilir,
                // bu yüzden döngü SONRASI daraltılmış SAYILAMAZ — güvenli/
                // tutucu tercih).
                if (detectNarrowing(w.cond, ctx.scope)) |n| {
                    if (n.narrows_then) {
                        const prior = ctx.narrowed.get(n.name);
                        try ctx.narrowed.put(self.allocator, n.name, n.base);
                        for (w.body) |s| try self.checkStmt(ctx, s);
                        if (prior) |p| try ctx.narrowed.put(self.allocator, n.name, p) else _ = ctx.narrowed.remove(n.name);
                        return;
                    }
                }
                for (w.body) |s| try self.checkStmt(ctx, s);
            },
            .for_stmt => |f| {
                const elem_t = try self.checkForIterable(ctx, f.iterable);
                try ctx.scope.declare(self.allocator, f.var_name, elem_t);
                for (f.body) |s| try self.checkStmt(ctx, s);
            },
            // Faz U.4.2: iç içe `def` artık KISITLI bir biçimde
            // desteklenir — yalnızca GENERIC OLMAYAN, `async` OLMAYAN
            // basit closure'lar (bkz. nox-teknik-spesifikasyon.md §3.23/
            // §3.2x). `checkNestedFuncDef`, dış kapsamdaki serbest
            // değişken REFERANSLARINI (capture) analiz eder VE iç
            // fonksiyonun ADINI dış kapsamda `.func` tipinde bir yerel
            // değişken olarak BAĞLAR.
            .func_def => |fd| {
                if (fd.type_params.len > 0) {
                    return self.fail(error.TypeMismatch, "iç içe fonksiyon tanımı generic OLAMAZ: {s}", .{fd.name});
                }
                if (fd.is_async) {
                    return self.fail(error.TypeMismatch, "iç içe fonksiyon tanımı 'async def' OLAMAZ: {s}", .{fd.name});
                }
                const func_type = try self.checkNestedFuncDef(ctx, fd);
                try ctx.scope.declare(self.allocator, fd.name, func_type);
            },
            .class_def => return self.fail(error.TypeMismatch, "sınıf tanımı yalnızca modül seviyesinde olabilir", .{}),
            .protocol_def => return self.fail(error.TypeMismatch, "protokol tanımı yalnızca modül seviyesinde olabilir", .{}),
            .extern_def => return self.fail(error.TypeMismatch, "'extern def' yalnızca modül seviyesinde olabilir", .{}),
            .import_stmt => return self.fail(error.TypeMismatch, "'import' yalnızca modül seviyesinde olabilir", .{}),
            .from_import_stmt => return self.fail(error.TypeMismatch, "'from ... import' yalnızca modül seviyesinde olabilir", .{}),
            .return_stmt => |r| {
                const expected = ctx.expected_return orelse
                    return self.fail(error.TypeMismatch, "'return' yalnızca fonksiyon/metod içinde kullanılabilir", .{});
                if (r) |e| {
                    const rt = try self.checkExprExpected(ctx, e, expected);
                    if (!self.assignable(expected, rt)) return self.fail(error.TypeMismatch, "dönüş tipi uyuşmuyor", .{});
                } else if (expected != .none) {
                    return self.fail(error.TypeMismatch, "fonksiyon bir değer döndürmelidir", .{});
                }
            },
            .raise_stmt => |e| {
                const t = try self.checkExpr(ctx, e);
                if (t != .class) return self.fail(error.TypeMismatch, "'raise' yalnızca bir sınıf örneği alabilir", .{});
            },
            .try_stmt => |t| try self.checkTry(ctx, t),
            .with_stmt => |w| try self.checkWith(ctx, w),
            .defer_stmt => |d| try self.checkDeferStmt(ctx, d),
            .lowlevel_stmt => |ll| {
                // İlke #2: `lowlevel` yalnızca tahsis STRATEJİSİNİ gevşetir;
                // tip sistemi burada da tam olarak zorunludur — gövde normal
                // kurallarla denetlenir (özel bir istisna yok).
                //
                // Ancak gövde içinde tanımlanan adlar bloktan SONRA kapsam
                // dışına alınır: arena blok çıkışında yıkılır (bkz.
                // codegen_qbe/codegen.zig, `genLowLevel`), bu yüzden bu adlar
                // kalıcı olsaydı bloktan sonraki bir kullanım kullanım-
                // sonrası-serbest-bırakma (use-after-free) olurdu. Bunu bir
                // önceki/sonraki anlık görüntü (snapshot) farkıyla yapıyoruz:
                // blok öncesinde var olmayan hiçbir ad bloktan sonra kalmaz.
                var before: std.StringHashMapUnmanaged(void) = .{};
                defer before.deinit(self.allocator);
                var before_it = ctx.scope.vars.keyIterator();
                while (before_it.next()) |k| try before.put(self.allocator, k.*, {});

                for (ll.body) |s| try self.checkStmt(ctx, s);

                var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
                defer to_remove.deinit(self.allocator);
                var after_it = ctx.scope.vars.keyIterator();
                while (after_it.next()) |k| {
                    if (!before.contains(k.*)) try to_remove.append(self.allocator, k.*);
                }
                for (to_remove.items) |name| _ = ctx.scope.vars.remove(name);
            },
            .pass_stmt => {},
        }
    }

    fn checkTry(self: *Checker, ctx: *FnCtx, t: ast.TryStmt) TypeError!void {
        for (t.try_body) |s| try self.checkStmt(ctx, s);
        for (t.except_clauses) |ec| {
            // Bulundu (nyx framework — bkz. proje belleği "NOX_LIMITATIONS.md
            // incelemesi", P5): ÇIPLAK `except:` (`ec.class_name == null`,
            // parser'ın `bind_name`i de HER ZAMAN `null` bıraktığını
            // GARANTİ ettiği) — sınıf çözümlemesi TAMAMEN ATLANIR, HİÇBİR
            // isim BAĞLANMAZ, gövde doğrudan denetlenir.
            const ec_class_name = ec.class_name orelse {
                for (ec.body) |s| try self.checkStmt(ctx, s);
                continue;
            };
            // Bulundu (bkz. proje belleği "from-import class type
            // annotations" görevi, `typeExprToType`in AYNI `from_imports`
            // geri düşüşüyle AYNI KÖK neden): `except X as e:` ÖNCEDEN
            // yalnızca ÇIPLAK `self.classes` anahtarını kontrol ediyordu —
            // `from nox.sqlite import SqliteError` İLE bağlanan bir sınıf
            // `self.classes`e MANGLED adıyla (`nox_sqlite_SqliteError`)
            // kayıtlıyken `ec.class_name` YEREL takma addır (`SqliteError`)
            // — bu YÜZDEN `from`-import EDİLMİŞ HERHANGİ bir istisna
            // sınıfını yakalamak (`import nox.sqlite` + tam mangled ada
            // BAŞVURMADAN) HER ZAMAN `bilinmeyen sınıf` hatasıyla
            // BAŞARISIZ oluyordu (GERÇEKTEN gözlemlendi, bkz. `nox.sqlite`
            // hata-yolu testi).
            const resolved_class_name = if (self.classes.contains(ec_class_name))
                ec_class_name
            else if (self.from_imports.get(ec_class_name)) |mangled|
                (if (self.classes.contains(mangled)) mangled else null)
            else
                null;
            const class_name = resolved_class_name orelse
                return self.fail(error.UndefinedClass, "bilinmeyen sınıf: {s}", .{ec_class_name});
            if (ec.bind_name) |bn| {
                try ctx.scope.declare(self.allocator, bn, .{ .class = class_name });
            }
            for (ec.body) |s| try self.checkStmt(ctx, s);
        }
        if (t.finally_body) |fb| for (fb) |s| try self.checkStmt(ctx, s);
    }

    /// Faz U.5: `with EXPR as NAME:` — `EXPR` bir `__enter__(self) -> T`/
    /// `__exit__(self) -> None` metod çiftine sahip bir SINIF örneği
    /// DEĞERLENDİRMELİDİR (bkz. `ast.WithStmt`in belge notu — v1 kapsamı
    /// bilinçli DAR: İKİ metod da argümansızdır, `__exit__` bir istisnayı
    /// ASLA bastıramaz). `binding` VERİLDİYSE `__enter__`in DÖNÜŞ tipine
    /// bağlanır (`EXPR`in KENDİ tipine DEĞİL — Python'un KENDİ ayrımıyla
    /// TUTARLI).
    fn checkWith(self: *Checker, ctx: *FnCtx, w: ast.WithStmt) TypeError!void {
        const ctx_t = try self.checkExpr(ctx, w.ctx_expr);
        const class_name = switch (ctx_t) {
            .class => |n| n,
            else => return self.fail(error.TypeMismatch, "'with' yalnızca bir sınıf örneği üzerinde çalışır", .{}),
        };
        const info = self.classes.getPtr(class_name) orelse
            return self.fail(error.UndefinedClass, "bilinmeyen sınıf: {s}", .{class_name});
        const enter_sig = info.methods.get("__enter__") orelse
            return self.fail(error.UndefinedMethod, "'{s}' sınıfının '__enter__' metodu yok ('with' için gerekli)", .{class_name});
        if (enter_sig.params.len != 0) {
            return self.fail(error.TypeMismatch, "'{s}.__enter__' hiçbir argüman ALMAMALIDIR", .{class_name});
        }
        const exit_sig = info.methods.get("__exit__") orelse
            return self.fail(error.UndefinedMethod, "'{s}' sınıfının '__exit__' metodu yok ('with' için gerekli)", .{class_name});
        if (exit_sig.params.len != 0) {
            return self.fail(error.TypeMismatch, "'{s}.__exit__' hiçbir argüman ALMAMALIDIR", .{class_name});
        }
        if (exit_sig.return_type != .none) {
            return self.fail(error.TypeMismatch, "'{s}.__exit__' None DÖNMELİDİR", .{class_name});
        }
        if (w.binding) |bn| {
            try ctx.scope.declare(self.allocator, bn, enter_sig.return_type);
        }
        for (w.body) |s| try self.checkStmt(ctx, s);
    }

    /// Go-tarzı `defer CALL` (bkz. `ast.DeferStmt`nin belge notu) — `CALL`i
    /// SIFIR-parametreli/`None`-dönüşlü SENTETİK bir `ast.FuncDef`nin TEK
    /// gövde deyimi (`expr_stmt`) yaparak `checkNestedFuncDef`e VERİR —
    /// GERÇEK bir iç içe `def` GİBİ ele alınır, bu yüzden `call`in yakaladığı
    /// SERBEST değişkenler (çağrılan değer VE argümanlar) MEVCUT yakalama-
    /// analizi (`Scope.captures`) TARAFINDAN OTOMATİK tespit edilip
    /// `self.closure_infos`e YAZILIR — YENİ bir capture-analizi YAZILMAZ.
    /// Üretilen sentetik ad, `d.call.callee`nin POINTER kimliğiyle
    /// `self.defer_synthetic_names`e KAYDEDİLİR (bkz. `ast.DeferStmt`nin
    /// belge notu — codegen'in `genDeferStmt`i AYNI anahtarla okur).
    fn checkDeferStmt(self: *Checker, ctx: *FnCtx, d: ast.DeferStmt) TypeError!void {
        if (ctx.expected_return == null) {
            return self.fail(error.TypeMismatch, "'defer' yalnızca fonksiyon/metod içinde kullanılabilir", .{});
        }
        self.defer_counter += 1;
        const synthetic_name = try std.fmt.allocPrint(self.allocator, "__defer${d}", .{self.defer_counter});
        const body = try self.allocator.alloc(ast.Stmt, 1);
        body[0] = .{ .kind = .{ .expr_stmt = ast.Expr{ .call = d.call } }, .line = self.current_line };
        const synthetic_fd: ast.FuncDef = .{
            .name = synthetic_name,
            .type_params = &.{},
            .params = &.{},
            .return_type = .{ .simple = "None" },
            .body = body,
            .is_async = false,
        };
        _ = try self.checkNestedFuncDef(ctx, synthetic_fd);
        try self.defer_synthetic_names.put(self.allocator, @intFromPtr(d.call.callee), synthetic_name);
    }

    /// Faz U.4.2: bir İÇ İÇE `def`in gövdesini, `ctx.scope`u `parent` OLARAK
    /// KULLANAN YENİ bir scope İÇİNDE denetler — bu scope'un `captures`ı
    /// AYARLIDIR, bu yüzden gövde İÇİNDE dış kapsama düşen HER isim
    /// (bkz. `Scope.lookup`) otomatik olarak KAYDEDİLİR. Denetim
    /// TAMAMLANINCA yakalama listesi `self.closure_infos`e (anahtar:
    /// `"<ctx.path>.<fd.name>"`) YAZILIR VE iç fonksiyonun `Type.func`
    /// tipi DÖNDÜRÜLÜR (çağıran, bunu `fd.name` yerel değişkenine BAĞLAR).
    fn checkNestedFuncDef(self: *Checker, ctx: *FnCtx, fd: ast.FuncDef) TypeError!Type {
        var captures: std.StringHashMapUnmanaged(Type) = .{};
        var inner_scope: Scope = .{ .parent = ctx.scope, .captures = &captures };
        for (fd.params) |p| {
            const pt = try self.typeExprToType(p.type_expr);
            try inner_scope.declare(self.allocator, p.name, pt);
        }
        const ret = try self.typeExprToType(fd.return_type);
        var inner_ctx: FnCtx = .{
            .scope = &inner_scope,
            .expected_return = ret,
            .in_async = false,
            .path = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ ctx.path, fd.name }),
        };
        for (fd.body) |s| try self.checkStmt(&inner_ctx, s);
        if (ret != .none and !alwaysReturns(fd.body)) {
            return self.fail(error.MissingReturn, "iç içe fonksiyon '{s}' tüm yollarda değer döndürmüyor", .{fd.name});
        }

        var capture_list: std.ArrayListUnmanaged(CaptureVar) = .empty;
        var it = captures.iterator();
        while (it.next()) |entry| {
            try capture_list.append(self.allocator, .{ .name = entry.key_ptr.*, .ty = entry.value_ptr.* });
        }
        try self.closure_infos.put(self.allocator, inner_ctx.path, .{ .captures = try capture_list.toOwnedSlice(self.allocator) });

        const params = try self.allocator.alloc(Type, fd.params.len);
        for (fd.params, 0..) |p, i| params[i] = try self.typeExprToType(p.type_expr);
        const ret_boxed = try self.allocator.create(Type);
        ret_boxed.* = ret;
        return Type{ .func = .{ .params = params, .return_type = ret_boxed } };
    }

    fn checkAssign(self: *Checker, ctx: *FnCtx, a: ast.Assign) TypeError!void {
        switch (a.target) {
            .identifier => |name| {
                const existing = ctx.scope.lookupLocal(name) orelse blk: {
                    // Faz U.4.2: `name` bir İÇ İÇE `def`in yakaladığı DIŞ
                    // bir değişkense (`parent` zincirinde bulunuyorsa) BUNU
                    // AYIRT EDEN, daha AÇIK bir hata verilir — capture BİLİNÇLİ
                    // olarak YALNIZCA OKUNABİLİR (bkz. nox-teknik-spesifikasyon.md
                    // §3.23, "mutasyon-görünür closure YOK" kararı).
                    if (ctx.scope.parent != null and ctx.scope.existsInChain(name)) {
                        return self.fail(error.TypeMismatch, "'{s}' iç içe fonksiyonun DIŞINDAN yakalanan bir değişkendir, yalnızca OKUNABİLİR (atama desteklenmiyor)", .{name});
                    }
                    // Bulundu (bkz. proje belleği "modül-seviyesi global durum"
                    // planı): yerel BAŞARISIZ olursa (VE bir yakalama da
                    // DEĞİLSE) modül-seviyesi bir global denenir — capture-yazma
                    // hatasından SONRA ama `UndefinedVariable`den ÖNCE, böylece
                    // bir yakalama İLE aynı isimli bir global ARASINDA capture
                    // hatası ÖNCELİKLİ kalır (capture'lar zaten mutasyona
                    // KAPALI, bu değişmiyor).
                    if (self.module_globals.get(name)) |gt| break :blk gt;
                    return self.fail(error.UndefinedVariable, "tanımsız değişken: {s}", .{name});
                };
                const value_t = try self.checkExprExpected(ctx, a.value, existing);
                if (!self.assignable(existing, value_t)) {
                    return self.fail(error.TypeMismatch, "'{s}' için tip uyuşmazlığı", .{name});
                }
                // Faz FF.6: yeniden atama, daraltma DURUMUNU geçersiz kılar
                // (bkz. `FnCtx.narrowed`in belge notu) — İÇİNDE bulunulan
                // if/while gövdesi çıkışta ESKİ değeri KENDİSİ geri
                // yükleyeceğinden (bkz. `checkStmt`), burada YALNIZCA
                // GÖVDENİN GERİ KALANI İÇİN geçersiz kılmak yeterlidir.
                _ = ctx.narrowed.remove(name);
            },
            .attribute => |attr| {
                // Genel durum: `<ifade>.<alan> = <değer>` — `<ifade>` HERHANGİ
                // bir sınıf örneğine çözümlenebilir (`self` OLMAK ZORUNDA
                // DEĞİL, bkz. görev "obj.attr = value ataması self dışına
                // genelleştir"). Yalnızca YENİ bir alan TANIMLAMAK (mevcut
                // sözlükte henüz olmayan bir ad) hâlâ `self.<alan> = ...`
                // biçiminde VE `__init__` içinde olmaya mecburdur — aksi halde
                // bir sınıfın alan kümesi çağrı sitesine göre değişken olurdu
                // (AGENTS.md §5'in yasakladığı dinamik alan ekleme).
                const obj_t = try self.checkExpr(ctx, attr.obj.*);
                try self.requireNotOptional(obj_t, attr.attr);
                const class_name = switch (obj_t) {
                    .class => |n| n,
                    else => return self.fail(error.TypeMismatch, "'.{s}' yalnızca sınıf örneklerinde kullanılabilir", .{attr.attr}),
                };
                const is_self = attr.obj.* == .identifier and std.mem.eql(u8, attr.obj.identifier, "self");
                const info = self.classes.getPtr(class_name).?;
                // Faz P2.2: alan ZATEN bildirilmişse (Faz FF.5 — AÇIKÇA
                // tipli bir `FieldDecl`) kendi tipi, boş bir liste literali
                // (`self.items = []`) İçin `expected` olarak KULLANILIR
                // (bkz. `checkExprExpected`in belge notu) — bu YÜZDEN
                // ÖNCE bakılır, `checkExpr` ÇAĞRILMADAN.
                const existing_field_t = info.fields.get(attr.attr);
                const value_t = try self.checkExprExpected(ctx, a.value, existing_field_t);
                if (existing_field_t) |existing_t| {
                    if (!self.assignable(existing_t, value_t)) {
                        return self.fail(error.TypeMismatch, "'{s}.{s}' için tip uyuşmazlığı", .{ class_name, attr.attr });
                    }
                    // Faz FF.5: AÇIKÇA bildirilen bir alan (`registerClassSignatures`
                    // tarafından ÖNCEDEN `info.fields`e YERLEŞTİRİLMİŞ) BURADA
                    // GERÇEKTEN atanıyor — `declared_unassigned`den DÜŞÜLÜR
                    // (bildirilMEMİŞ/çıkarım-only alanlar İÇİN ZARARSIZ no-op).
                    _ = info.declared_unassigned.remove(attr.attr);
                } else {
                    if (!(is_self and ctx.is_init)) {
                        return self.fail(error.UndefinedAttribute, "'{s}' sınıfının '{s}' alanı yalnızca __init__ içinde 'self.{s} = ...' ile tanımlanabilir", .{ class_name, attr.attr, attr.attr });
                    }
                    try info.fields.put(self.allocator, attr.attr, value_t);
                }
            },
            // `d[key] = value` (dict) VE `xs[i] = value` (Faz U.1'den beri
            // `list[T]` İÇİN de — bkz. nox-teknik-spesifikasyon.md §3.28/
            // §3.20 — TUTARLILIK GEREKÇESİYLE, dict ZATEN destekliyordu).
            .index => |idx| {
                const obj_t = try self.checkExpr(ctx, idx.obj.*);
                try self.requireNotOptional(obj_t, "[]");
                if (obj_t == .list) {
                    const key_t = try self.checkExpr(ctx, idx.index.*);
                    if (key_t != .int) {
                        return self.fail(error.TypeMismatch, "liste indeksi 'int' olmalı", .{});
                    }
                    const value_t = try self.checkExpr(ctx, a.value);
                    if (!self.assignable(obj_t.list.*, value_t)) {
                        return self.fail(error.TypeMismatch, "indeksli atamada tip uyuşmazlığı: listenin eleman tipiyle uyuşmuyor", .{});
                    }
                    return;
                }
                if (obj_t != .dict) {
                    return self.fail(error.TypeMismatch, "indeksli atama yalnızca 'list'/'dict' üzerinde çalışır", .{});
                }
                const key_t = try self.checkExpr(ctx, idx.index.*);
                if (!types.eql(key_t, obj_t.dict.key.*)) {
                    return self.fail(error.TypeMismatch, "dict indeksi anahtar tipiyle uyuşmuyor", .{});
                }
                const value_t = try self.checkExpr(ctx, a.value);
                if (!self.assignable(obj_t.dict.value.*, value_t)) {
                    return self.fail(error.TypeMismatch, "dict değeri değer tipiyle uyuşmuyor", .{});
                }
            },
            else => return self.fail(error.TypeMismatch, "geçersiz atama hedefi", .{}),
        }
    }

    fn checkForIterable(self: *Checker, ctx: *FnCtx, iterable: ast.Expr) TypeError!Type {
        if (iterable == .call and iterable.call.callee.* == .identifier and
            std.mem.eql(u8, iterable.call.callee.identifier, "range"))
        {
            const c = iterable.call;
            if (c.args.len != 1) return self.fail(error.ArgumentCountMismatch, "'range' tam olarak 1 argüman alır", .{});
            const at = try self.checkExpr(ctx, c.args[0]);
            if (at != .int) return self.fail(error.TypeMismatch, "'range' bir int argüman bekler", .{});
            return .int;
        }
        const t = try self.checkExpr(ctx, iterable);
        return switch (t) {
            .list => |elem| elem.*,
            else => self.fail(error.NotIterable, "bu ifade üzerinde 'for' çalıştırılamaz", .{}),
        };
    }

    /// Faz P2.2 (bkz. proje belleği "P0/P1/P2 inceleme düzeltme listesi"):
    /// `checkExpr`in AYNISI, ama bir BEKLENEN tip (`expected`) BİLİNİYORSA
    /// (bir `var_decl`in bildirilen tipi, bir çağrının parametre tipi, bir
    /// `return`ün fonksiyon dönüş tipi, bir atamanın HEDEFİNİN ZATEN
    /// bilinen tipi — dört doğal "bağlam" noktası) VE `expr` BOŞ bir liste
    /// literaliyse (`[]`, `checkExpr`in KENDİSİ TEK BAŞINA tipini asla
    /// çıkaramaz), `expected` bir `list[T]` İSE elemanın tipini ORADAN alır.
    /// **Bilinçli v1 kapsamı:** yalnızca BU DÖRT çağrı sitesinde (aşağıya
    /// bkz.) kullanılır — bir boş listenin/sözlüğün DAHA İÇ İÇE bir bağlamda
    /// (ör. başka bir liste literalinin elemanı, bir dict değeri) geçmesi
    /// HÂLÂ desteklenmez (`checkExpr`in KENDİSİ HİÇ DEĞİŞMEDİ, aynı "boş
    /// liste/dict literalinin tipi çıkarılamaz" hatasını üretmeye devam
    /// eder — bu yalnızca dört EK yol için bir GERİ DÜŞÜŞ katmanıdır).
    /// Boş `{}` (dict) de ARTIK BURADA ele alınır — `[]`nin AYNI mantığı
    /// (parser'ın `.l_brace` dalı ARTIK `{}`ye izin verir, bkz. onun belge
    /// notu; codegen'in `genExprForTarget`i AYNI şekilde `target.dict_info`den
    /// tipi alan bir `genEmptyDictLit`e sahiptir).
    fn checkExprExpected(self: *Checker, ctx: *FnCtx, expr: ast.Expr, expected: ?Type) TypeError!Type {
        if (expr == .list_lit and expr.list_lit.len == 0) {
            if (expected) |exp| {
                if (exp == .list) return exp;
            }
        }
        // Faz 7 (tekli kalıtım): eleman tipi bir SINIF olan, BOŞ OLMAYAN
        // bir liste literali İçin bir BEKLENEN tip BİLİNİYORSA, HER
        // elemanın ONA `assignable` (taban/alt sınıf İLİŞKİSİ DAHİL)
        // olması YETERLİDİR — `xs: list[Animal] = [Dog(...), Cat(...)]`
        // GİBİ polimorfik liste literallerini MÜMKÜN KILAR. **Bilinçli v1
        // kapsamı**: SADECE sınıf eleman tipleri İçin (primitive
        // list'lerin `checkExpr`in KENDİ katı pairwise-`types.eql`
        // davranışı DEĞİŞMEDİ — int→float genişletme GİBİ farklı bir
        // semantiğe kazara KAYMAMAK İçin bilinçli olarak dar tutuldu).
        if (expr == .list_lit and expr.list_lit.len > 0) {
            if (expected) |exp| {
                if (exp == .list and exp.list.* == .class) {
                    for (expr.list_lit) |el| {
                        const t = try self.checkExpr(ctx, el);
                        if (!self.assignable(exp.list.*, t)) {
                            return self.fail(error.TypeMismatch, "liste elemanı beklenen sınıf tipiyle uyuşmuyor", .{});
                        }
                    }
                    return exp;
                }
            }
        }
        if (expr == .dict_lit and expr.dict_lit.len == 0) {
            if (expected) |exp| {
                if (exp == .dict) return exp;
            }
        }
        return self.checkExpr(ctx, expr);
    }

    /// Faz U.4.5: `checkExpr`nin `.identifier` dalının, YEREL kapsamda
    /// (parametre/değişken/yakalanan) BULUNAMAYAN bir isim İçin YEDEK
    /// çözümlemesi — ÜST-DÜZEY (non-generic) bir `def`in BARE adı bir
    /// DEĞER olarak kullanılıyor OLABİLİR (bkz. `checkCall`nin `.identifier`
    /// dalıyla — satır ~2289 — AYNI `self.functions` kontrolü, ama BURADA
    /// çağrı OLMADIĞINDAN `functions_used_as_value`e KAYDEDİLİR — bkz.
    /// onun belge notu, codegen'in trampoline ÜRETMESİ İçin). Generic
    /// fonksiyonlar BİLİNÇLİ olarak v1'de DIŞLANIR: somut örnekleme
    /// YALNIZCA bir ÇAĞRI SİTESİNDE (argüman tiplerinden) çözülebilir,
    /// "bare" bir kullanımda HANGİ örneklemenin kastedildiği BELİRSİZDİR.
    ///
    /// **BİLİNÇLİ OLARAK `noinline` VE `checkExpr`den AYRI bir fonksiyon:**
    /// bir fuzz-regresyon testi (2000 seviyeli iç içe `1 + 1 + ...`) BUNU
    /// `checkExpr`nin GÖVDESİNE DOĞRUDAN yazınca GERÇEK bir yığın-taşması
    /// (stack overflow) İLE ÇÖKTÜ — Zig `switch` KOLLARININ hepsi AYNI
    /// çağrı çerçevesini (stack frame) PAYLAŞTIĞINDAN, `.identifier`
    /// dalına eklenen YENİ yerel değişkenler `checkExpr`nin (2000 kat
    /// ÖZYİNELEMELİ ÇAĞRILAN) HER çağrısının çerçeve BOYUTUNU büyütüyordu
    /// — `.binary` dalı HİÇ `.identifier`e uğramasa BİLE. AYRI bir
    /// fonksiyona ÇIKARMAK bu ek yerelleri yalnızca GERÇEKTEN bu yedek
    /// yola girildiğinde açılan KENDİ çerçevesine TAŞIR, `checkExpr`nin
    /// KENDİ çerçevesi (VE onun tekrarlı özyinelemesinin GÜVENLİ derinliği)
    /// DEĞİŞMEZ.
    noinline fn resolveIdentifierAsFunctionValue(self: *Checker, name: []const u8) TypeError!Type {
        if (self.generic_functions.contains(name)) {
            return self.fail(error.TypeMismatch, "generic fonksiyon '{s}' bir değer olarak kullanılamaz (yalnızca çağrılabilir)", .{name});
        }
        // Faz KK.1 (task_32f43efe): `checkCall`nin `.identifier` dalıyla
        // (satır ~2289, `resolveMangledCall`) AYNI `from_imports` geri
        // düşüşü — ÖNCEDEN yalnızca YEREL (bare) `self.functions` anahtarı
        // denenirdi, bu YÜZDEN `from other_module import f` İLE alınan
        // `f`nin ÇAĞRI DIŞINDA bir DEĞER olarak kullanılması (ör.
        // `some_list.append(f)`) HER ZAMAN `UndefinedVariable` verirdi —
        // `module_loader.zig`nin ithal edilen modüllerdeki ÜST-DÜZEY
        // isimleri MANGLE ETTİĞİ (bkz. onun belge notu) İÇİN `self.functions`
        // yalnızca mangled anahtarı ("other_module_f") TAŞIR, bare "f"yi
        // DEĞİL. `functions_used_as_value`e MANGLED adı KAYDETMEK
        // (codegen'in `genFunctionValueTrampoline`/`buildFunctionValueForIdentifier`ı
        // AYNI `from_imports` geri düşüşünü KENDİ tarafında TEKRARLAR,
        // bkz. `expr.zig`) — AST YENİDEN YAZILMAZ (bare `.identifier`
        // `Call.callee`nin AKSİNE bir `*Expr` İşaretçisi TAŞIMAZ, bkz.
        // `ast.Expr`in belge notu), bu YÜZDEN codegen KENDİ geri düşüşünü
        // BAĞIMSIZ olarak yapmalıdır.
        const resolved_name = if (self.functions.contains(name))
            name
        else if (self.from_imports.get(name)) |mangled|
            mangled
        else
            null;
        if (resolved_name) |rn| {
            const sig = self.functions.get(rn).?;
            if (self.async_functions.contains(rn)) {
                return self.fail(error.TypeMismatch, "'{s}' bir 'async def' fonksiyonudur, bir değer olarak kullanılamaz", .{name});
            }
            try self.functions_used_as_value.put(self.allocator, rn, {});
            const ret_boxed = try self.allocator.create(Type);
            ret_boxed.* = sig.return_type;
            return .{ .func = .{ .params = sig.params, .return_type = ret_boxed } };
        }
        return self.fail(error.UndefinedVariable, "tanımsız değişken: {s}", .{name});
    }

    fn checkExpr(self: *Checker, ctx: *FnCtx, expr: ast.Expr) TypeError!Type {
        try self.enterExprRecursion();
        defer self.exitExprRecursion();
        return switch (expr) {
            .int_lit => .int,
            .float_lit => .float,
            .bool_lit => .boolean,
            .string_lit => .str,
            .none_lit => .none,
            // Faz FF.6: daraltma örtüsü (bkz. `FnCtx.narrowed`in belge notu)
            // GERÇEK scope aramasından ÖNCE denetlenir.
            .identifier => |name| blk: {
                if (ctx.narrowed.get(name)) |t| break :blk t;
                if (try ctx.scope.lookup(self.allocator, name)) |t| break :blk t;
                // Bulundu (bkz. proje belleği "modül-seviyesi global durum"
                // planı): yerel/parametre/yakalama BAŞARISIZ olursa —
                // `resolveIdentifierAsFunctionValue`den ÖNCE — modül-seviyesi
                // bir global denenir. Yerel gölgeleme OTOMATİK çalışır:
                // aynı isimde bir yerel/parametre HER ZAMAN `ctx.scope.lookup`
                // TARAFINDAN BURADAN ÖNCE bulunur, bu dala HİÇ ULAŞILMAZ.
                if (self.module_globals.get(name)) |t| break :blk t;
                break :blk try self.resolveIdentifierAsFunctionValue(name);
            },
            .unary => |u| blk: {
                const t = try self.checkExpr(ctx, u.operand.*);
                switch (u.op) {
                    .neg => {
                        if (!types.isNumeric(t)) return self.fail(error.TypeMismatch, "unary '-' yalnızca sayısal tiplere uygulanabilir", .{});
                        break :blk t;
                    },
                    .not_ => {
                        if (t != .boolean) return self.fail(error.TypeMismatch, "'not' yalnızca bool ile kullanılabilir", .{});
                        break :blk .boolean;
                    },
                }
            },
            .binary => |b| try self.checkBinary(ctx, b),
            .call => |c| try self.checkCall(ctx, c),
            .attribute => |a| try self.checkAttribute(ctx, a),
            .index => |idx| blk: {
                const obj_t = try self.checkExpr(ctx, idx.obj.*);
                try self.requireNotOptional(obj_t, "[]");
                if (obj_t == .dict) {
                    const idx_t = try self.checkExpr(ctx, idx.index.*);
                    if (!types.eql(idx_t, obj_t.dict.key.*)) {
                        return self.fail(error.TypeMismatch, "dict indeksi anahtar tipiyle uyuşmuyor", .{});
                    }
                    break :blk obj_t.dict.value.*;
                }
                // Stdlib fazı §G: `s[i]` — TEK karakterlik bir `str` döner
                // (Nox'ta AYRI bir "char" tipi YOK, Python'un `str[i]`siyle
                // AYNI sadelik). Sınır dışı erişim ÇALIŞMA ZAMANINDA bir
                // `IndexError` `raise` eder (bkz. codegen.zig'in `genIndex`i) —
                // burada yalnızca TİP kontrolü yapılır.
                if (obj_t == .str) {
                    const idx_t = try self.checkExpr(ctx, idx.index.*);
                    if (idx_t != .int) return self.fail(error.TypeMismatch, "str indeksi int olmalıdır", .{});
                    break :blk .str;
                }
                const idx_t = try self.checkExpr(ctx, idx.index.*);
                if (idx_t != .int) return self.fail(error.TypeMismatch, "liste indeksi int olmalıdır", .{});
                break :blk switch (obj_t) {
                    .list => |elem| elem.*,
                    else => return self.fail(error.TypeMismatch, "indeksleme yalnızca 'list'/'dict'/'str' üzerinde çalışır", .{}),
                };
            },
            .list_lit => |elems| blk: {
                if (elems.len == 0) return self.fail(error.UnknownType, "boş liste literalinin tipi çıkarılamaz", .{});
                const first = try self.checkExpr(ctx, elems[0]);
                for (elems[1..]) |el| {
                    const t = try self.checkExpr(ctx, el);
                    if (!types.eql(t, first)) return self.fail(error.TypeMismatch, "liste elemanları aynı tipte olmalıdır", .{});
                }
                const boxed = try self.allocator.create(Type);
                boxed.* = first;
                break :blk .{ .list = boxed };
            },
            .dict_lit => |pairs| blk: {
                // Boş `{}`nin tipi BURADA (bağlamsız `checkExpr`de) HÂLÂ
                // çıkarılamaz — `[]`in AYNI kısıtlaması. Bir BEKLENEN tip
                // biliniyorsa `checkExprExpected` (bkz. onun belge notu)
                // bunu ÖNCEDEN ele alır; buraya YALNIZCA bağlamsız (ör.
                // başka bir literalin içine gömülü) bir boş `{}` düşer.
                if (pairs.len == 0) return self.fail(error.UnknownType, "boş dict literalinin tipi çıkarılamaz", .{});
                const first_key = try self.checkExpr(ctx, pairs[0].key);
                const first_value = try self.checkExpr(ctx, pairs[0].value);
                if (first_key != .int and first_key != .boolean and first_key != .str) {
                    return self.fail(error.TypeMismatch, "'dict' anahtar tipi yalnızca int/bool/str olabilir (v1 kapsamı)", .{});
                }
                if (first_value != .int and first_value != .float and first_value != .boolean and first_value != .str and first_value != .class) {
                    return self.fail(error.TypeMismatch, "'dict' değer tipi yalnızca int/float/bool/str/sınıf olabilir (v1 kapsamı)", .{});
                }
                for (pairs[1..]) |p| {
                    const kt = try self.checkExpr(ctx, p.key);
                    const vt = try self.checkExpr(ctx, p.value);
                    if (!types.eql(kt, first_key)) return self.fail(error.TypeMismatch, "dict anahtarları aynı tipte olmalıdır", .{});
                    if (!types.eql(vt, first_value)) return self.fail(error.TypeMismatch, "dict değerleri aynı tipte olmalıdır", .{});
                }
                const key_boxed = try self.allocator.create(Type);
                key_boxed.* = first_key;
                const value_boxed = try self.allocator.create(Type);
                value_boxed.* = first_value;
                break :blk .{ .dict = .{ .key = key_boxed, .value = value_boxed } };
            },
            .await_expr => |operand_ptr| blk: {
                if (!ctx.in_async) return self.fail(error.TypeMismatch, "'await' yalnızca 'async def' gövdesi içinde kullanılabilir", .{});
                const operand = operand_ptr.*;
                const t = try self.checkExpr(ctx, operand);
                if (t == .task) break :blk t.task.*;
                // Task DEĞİLSE, yalnızca bir Channel.send/recv YA DA (Faz
                // BB.3) bir ThreadHandle.join() çağrısı olabilir — bu
                // çağrılar (bkz. `checkCall`in `.channel` dalı/
                // `tryResolveThreadSpawnCall`ın DÖNÜŞ tipi) `T`yi (ya da
                // `send` için `None`u) ZATEN DOĞRUDAN döndürür; burada
                // yalnızca "açıkça bir askıya alma noktası" sözdizimsel ŞEKLİ
                // doğrulanır — `ThreadHandle.join()` de (bkz. `runtime/
                // async_rt/thread_bridge.zig`nin `nox_thread_join`ı)
                // `Channel.recv` İLE AYNI reaktör-tabanlı askıya alma
                // mekanizmasını KULLANDIĞINDAN AYNI kurala TABİDİR.
                const is_channel_op = switch (operand) {
                    .call => |c| switch (c.callee.*) {
                        .attribute => |a| blk2: {
                            const recv_t = self.checkExpr(ctx, a.obj.*) catch return self.fail(error.TypeMismatch, "'await' ifadesinin alıcısı çözümlenemedi", .{});
                            if ((std.mem.eql(u8, a.attr, "send") or std.mem.eql(u8, a.attr, "recv")) and (recv_t == .channel or recv_t == .thread_channel)) break :blk2 true;
                            if (std.mem.eql(u8, a.attr, "join") and recv_t == .thread_handle) break :blk2 true;
                            break :blk2 false;
                        },
                        else => false,
                    },
                    else => false,
                };
                if (!is_channel_op) return self.fail(error.TypeMismatch, "'await' yalnızca bir Task değeri, bir Channel.send/recv, bir ThreadChannel.send/recv ya da bir ThreadHandle.join() çağrısı üzerinde kullanılabilir", .{});
                break :blk t;
            },
            .spawn_expr => |operand_ptr| blk: {
                const operand = operand_ptr.*;
                const call = switch (operand) {
                    .call => |c| c,
                    else => return self.fail(error.NotCallable, "'spawn' yalnızca bir çağrı ifadesini sarmalayabilir", .{}),
                };
                const fn_name = switch (call.callee.*) {
                    .identifier => |n| n,
                    else => return self.fail(error.NotCallable, "'spawn' yalnızca doğrudan bir fonksiyon çağrısını sarmalayabilir (metod/kurucu çağrıları henüz desteklenmiyor)", .{}),
                };
                if (!self.async_functions.contains(fn_name)) {
                    return self.fail(error.TypeMismatch, "'spawn' yalnızca 'async def' fonksiyonlarını başlatabilir: '{s}' async değil", .{fn_name});
                }
                const sig = self.functions.get(fn_name).?; // async_functions'a girdiyse functions'ta da vardır
                try self.checkArgs(ctx, sig.params, call.args, fn_name);
                const boxed = try self.allocator.create(Type);
                boxed.* = sig.return_type;
                break :blk .{ .task = boxed };
            },
            .generic_construct => |g| try self.checkGenericConstruct(ctx, g),
        };
    }

    /// `checkExpr`in `.generic_construct` dalından (bkz. Faz U.4.1'in
    /// AYNI çıkarımı) BİLİNÇLİ olarak AYRI bir fonksiyona ÇIKARILDI —
    /// `checkExpr`/`checkBinary` çok DERİN özyinelemeli bir çift OLDUĞUNDAN
    /// (bkz. `tests/fuzz/lexer_parser_checker_fuzz.zig`nin "çok uzun tek
    /// satırlık ifade çökmeden işlenir" regresyon testi, 2000 seviye
    /// derinlik), `checkExpr`in KENDİ switch gövdesine DOĞRUDAN eklenen
    /// HER yeni yerel değişken/dal (Faz BB.6'nın `ThreadChannel` kurucu
    /// mantığı GİBİ) `checkExpr`in TEK bir çağrısının yığın çerçevesini
    /// BÜYÜTÜR — VE bu, HER özyinelemeli seviyede TEKRARLANDIĞINDAN
    /// (2000 kez), küçük bir büyüme BİLE önceden marjinal olan yığın
    /// bütçesini AŞABİLİR (GERÇEKTEN GÖZLEMLENDİ: bu mantık `checkExpr`in
    /// KENDİ switch'İNE eklendiğinde YUKARIDAKİ regresyon testi
    /// `Segmentation fault`la ÇÖKTÜ, `checkCall`/`tryResolveThreadSpawnCall`
    /// GİBİ AYRI bir fonksiyona TAŞININCA sorun ORTADAN KALKTI — `.binary`/
    /// `.int_lit` zincirleri BU kodu HİÇ ÇALIŞTIRMASA BİLE, Debug modunda
    /// bir switch'in TÜM dallarının yerel değişkenleri AYNI çerçevede
    /// REZERVE EDİLİR).
    fn checkGenericConstruct(self: *Checker, ctx: *FnCtx, g: ast.GenericConstruct) TypeError!Type {
        // `ThreadChannel[T](capacity)` — Faz BB.6 (bkz. nox-teknik-
        // spesifikasyon.md §3.52): `Channel[T](capacity)` İLE AYNI
        // sözdizimi/kurucu şekli, AMA eleman tipi
        // `isThreadTransferSafeType`den GEÇMELİDİR (iş parçacıkları
        // ARASINDA taşınacağından — `Channel[T]`in AKSİNE, ki O AYNI-
        // iş-parçacığı olduğundan HERHANGİ bir `T`yi kabul eder).
        if (std.mem.eql(u8, g.name, "ThreadChannel")) {
            if (g.type_args.len != 1) {
                return self.fail(error.UnknownType, "'ThreadChannel' tam olarak bir tip argümanı alır", .{});
            }
            const elem_t = try self.typeExprToType(g.type_args[0]);
            if (!self.isThreadTransferSafeType(elem_t)) {
                return self.fail(error.TypeMismatch, "'ThreadChannel' eleman tipi yalnızca int/float/bool/str/None/ptr olabilir (--release altında ayrıca task/channel/list/class/dict)", .{});
            }
            if (g.args.len != 1) {
                return self.fail(error.ArgumentCountMismatch, "'ThreadChannel' kurucusu tam olarak 1 argüman (capacity: int) alır", .{});
            }
            if (try self.checkExpr(ctx, g.args[0]) != .int) {
                return self.fail(error.TypeMismatch, "'ThreadChannel' kurucusunun argümanı (capacity) int olmalıdır", .{});
            }
            const boxed = try self.allocator.create(Type);
            boxed.* = elem_t;
            return .{ .thread_channel = boxed };
        }
        // Faz P2.1 (bkz. proje belleği "generic sınıflar" planı):
        // kullanıcı-tanımlı bir generic sınıf — `Channel`/`ThreadChannel`nin
        // AKSİNE bu GERÇEKTEN monomorphize edilir (bkz. `instantiateGenericClass`).
        // Tip argümanları (`Channel[T](capacity)` İLE AYNI şekilde) AÇIKÇA
        // yazılmalıdır — argümanlardan ÇIKARIM (generic fonksiyonların
        // `unifyTypeExpr`si GİBİ) YOKTUR. `checkCall`in `.identifier` dalının
        // `from_imports` GERİ DÜŞÜŞÜYLE (satır ~2198) AYNI ilke: yerel bir
        // isim `self.generic_classes`de BULUNAMAZSA, `from X import Box`
        // İLE bağlanan mangled bir isim OLUP OLMADIĞI da denenir.
        const maybe_gcd = self.generic_classes.get(g.name) orelse blk: {
            const mangled_base = self.from_imports.get(g.name) orelse break :blk null;
            break :blk self.generic_classes.get(mangled_base);
        };
        if (maybe_gcd) |gcd| {
            const bound = try self.allocator.alloc(Type, g.type_args.len);
            for (g.type_args, 0..) |ta, i| bound[i] = try self.typeExprToType(ta);
            const class_t = try self.instantiateGenericClass(gcd, bound);
            const info = self.classes.get(class_t.class).?;
            const init_sig = info.init_sig orelse FuncSig{ .params = &.{}, .return_type = .none };
            try self.checkArgs(ctx, init_sig.params, g.args, g.name);
            g.resolved_class_name.* = class_t.class;
            return class_t;
        }
        // Faz OO.2 (bkz. nox-teknik-spesifikasyon.md §3.83): `TaskLocal[T]()`
        // — `Channel[T]`nin AYNI "sihirli generic isim" deseni, ama
        // kurucusu ARGÜMAN ALMAZ (bir kapasite kavramı YOK — her fiber
        // İçİn BAŞLANGIÇTA BOŞ bir yuva).
        if (std.mem.eql(u8, g.name, "TaskLocal")) {
            if (g.type_args.len != 1) {
                return self.fail(error.UnknownType, "'TaskLocal' tam olarak bir tip argümanı alır", .{});
            }
            const elem_t = try self.typeExprToType(g.type_args[0]);
            // **Bilinçli v1 kısıtlaması:** `T` bir sınıf/`str`/`list`/`dict`
            // (HEAP-yönetimli, HER ZAMAN null OLABİLEN bir işaretçi temsili)
            // OLMALIDIR — `get() -> T?`nin "hiç ayarlanmamış" (`None`) İLE
            // "0/boş DEĞERİ ayarlandı" durumlarını AYIRT ETMESİ GEREKİR;
            // heap-yönetimli tipler İçin BU ZATEN null-pointer İLE BEDAVA
            // gelir, ama ÇIPLAK bir `int`/`float`/`bool` İçin `0` DEĞERİ
            // "ayarlanmamış" İLE TAM olarak ÇAKIŞIR (`Optional[int]`in
            // KUTULAMA GEREKTİRMESİYLE AYNI sorun, bkz. `boxed_scalar`) —
            // KUTULAMAYI TaskLocal'a AYRICA entegre etmek BU turun kapsamı
            // DIŞINDA bırakıldı (nyx'in GERÇEK kullanım örneği ZATEN her
            // zaman bir SINIF örneğidir).
            if (elem_t == .int or elem_t == .float or elem_t == .boolean) {
                return self.fail(error.TypeMismatch, "'TaskLocal[T]'nin T'si bir sınıf/str/list/dict olmalıdır (çıplak int/float/bool v1 kapsamı dışı — Optional[int] gibi kutulama gerektirir)", .{});
            }
            if (g.args.len != 0) {
                return self.fail(error.ArgumentCountMismatch, "'TaskLocal' kurucusu argüman almaz", .{});
            }
            const boxed = try self.allocator.create(Type);
            boxed.* = elem_t;
            return .{ .task_local = boxed };
        }
        // v0.1'de diğer tanınan yerleşik generic kurucu: `Channel[T](
        // capacity)`.
        if (!std.mem.eql(u8, g.name, "Channel")) {
            return self.fail(error.UnknownType, "bilinmeyen generic kurucu: {s}", .{g.name});
        }
        if (g.type_args.len != 1) {
            return self.fail(error.UnknownType, "'Channel' tam olarak bir tip argümanı alır", .{});
        }
        const elem_t = try self.typeExprToType(g.type_args[0]);
        if (g.args.len != 1) {
            return self.fail(error.ArgumentCountMismatch, "'Channel' kurucusu tam olarak 1 argüman (capacity: int) alır", .{});
        }
        if (try self.checkExpr(ctx, g.args[0]) != .int) {
            return self.fail(error.TypeMismatch, "'Channel' kurucusunun argümanı (capacity) int olmalıdır", .{});
        }
        const boxed = try self.allocator.create(Type);
        boxed.* = elem_t;
        return .{ .channel = boxed };
    }

    fn checkBinary(self: *Checker, ctx: *FnCtx, b: ast.Binary) TypeError!Type {
        const l = try self.checkExpr(ctx, b.left.*);
        const r = try self.checkExpr(ctx, b.right.*);
        return switch (b.op) {
            // `str + str` — birleştirme (bkz. stdlib fazı §B, codegen.zig'in
            // `genBinary`i). Diğer sayısal operatörlerden FARKLI: yalnızca
            // İKİ TARAF DA `str` ise izin verilir, aksi halde (ör. `str + int`)
            // aşağıdaki `numericPromote`ye düşülür ve orada reddedilir.
            .add => blk: {
                if (l == .str and r == .str) break :blk .str;
                break :blk try self.numericPromote(l, r);
            },
            .sub, .mul, .mod, .floordiv, .pow => try self.numericPromote(l, r),
            .div => blk: {
                if (!types.isNumeric(l) or !types.isNumeric(r)) {
                    return self.fail(error.TypeMismatch, "'/' yalnızca sayısal tiplerde kullanılabilir", .{});
                }
                break :blk .float;
            },
            .eq, .ne => blk: {
                if (types.isNumeric(l) and types.isNumeric(r)) break :blk .boolean;
                if (types.eql(l, r)) break :blk .boolean;
                // Faz FF.6 (bkz. nox-teknik-spesifikasyon.md §3.65): `x !=
                // None` / `x == None` — bir Optional'ı `None` ile
                // karşılaştırmak (daraltmanın ÖN KOŞULU, bkz. `detectNarrowing`)
                // HER ZAMAN geçerlidir.
                if ((l == .optional and r == .none) or (l == .none and r == .optional)) break :blk .boolean;
                return self.fail(error.TypeMismatch, "karşılaştırılan tipler uyuşmuyor", .{});
            },
            .lt, .le, .gt, .ge => blk: {
                if (!types.isNumeric(l) or !types.isNumeric(r)) {
                    return self.fail(error.TypeMismatch, "sıralama karşılaştırmaları yalnızca sayısal tiplerde çalışır", .{});
                }
                break :blk .boolean;
            },
            .and_, .or_ => blk: {
                if (l != .boolean or r != .boolean) {
                    return self.fail(error.TypeMismatch, "'and'/'or' yalnızca bool ile kullanılabilir", .{});
                }
                break :blk .boolean;
            },
        };
    }

    /// Faz FF.6 (bkz. nox-teknik-spesifikasyon.md §3.65): `checkStmt`in
    /// `.if_stmt` dalının kullandığı DAR daraltma-örüntüsü tespiti.
    const Narrow = struct {
        name: []const u8,
        /// Daraltılmış (Optional OLMAYAN) taban tip — `then`/`else`
        /// dalında `name`in GEÇİCİ olarak YENİDEN bağlanacağı tip.
        base: Type,
        /// `true`: `x != None` (THEN dalı daraltılır). `false`: `x ==
        /// None` (ELSE dalı daraltılır — `then` dalı Optional OLARAK KALIR).
        narrows_then: bool,
    };

    /// Yalnızca TAM OLARAK `<isim> != None` / `<isim> == None` (VE
    /// yansımaları, `None != <isim>` gibi) biçimindeki bir koşulu tanır —
    /// `<isim>` GEÇERLİ scope'un DOĞRUDAN bir YERELİ (parent zincirinden
    /// YAKALANMIŞ bir değişken DEĞİL — bkz. `lookupLocal`, kasıtlı dar
    /// kapsam: bir capture'ı geçici olarak daraltıp SONRA eski haline
    /// GERİ YÜKLEMEK dış fonksiyonun KENDİ denetimini etkilemez ama
    /// GEREKSİZ karmaşıklık katardı) VE `T | None` tipinde OLMALIDIR.
    /// Başka HİÇBİR koşul biçimi (ör. `if x:`, `if x.field != None:`,
    /// birleşik `and`/`or` koşulları) TANINMAZ — genel bir kontrol-akışı
    /// analizi DEĞİL, BİLİNÇLİ dar bir v1 kapsamıdır.
    fn detectNarrowing(cond: ast.Expr, scope: *Scope) ?Narrow {
        if (cond != .binary) return null;
        const b = cond.binary;
        if (b.op != .eq and b.op != .ne) return null;
        const name: []const u8 = if (b.left.* == .identifier and b.right.* == .none_lit)
            b.left.identifier
        else if (b.right.* == .identifier and b.left.* == .none_lit)
            b.right.identifier
        else
            return null;
        const t = scope.lookupLocal(name) orelse return null;
        if (t != .optional) return null;
        return .{ .name = name, .base = t.optional.*, .narrows_then = (b.op == .ne) };
    }

    fn numericPromote(self: *Checker, l: Type, r: Type) TypeError!Type {
        if (!types.isNumeric(l) or !types.isNumeric(r)) {
            return self.fail(error.TypeMismatch, "aritmetik işlem yalnızca sayısal tiplerde çalışır", .{});
        }
        if (l == .float or r == .float) return .float;
        return .int;
    }

    fn checkAttribute(self: *Checker, ctx: *FnCtx, a: ast.Attribute) TypeError!Type {
        const obj_t = try self.checkExpr(ctx, a.obj.*);
        try self.requireNotOptional(obj_t, a.attr);
        const class_name = switch (obj_t) {
            .class => |n| n,
            else => return self.fail(error.TypeMismatch, "'.{s}' yalnızca sınıf örneklerinde kullanılabilir", .{a.attr}),
        };
        const info = self.classes.getPtr(class_name) orelse
            return self.fail(error.UndefinedClass, "bilinmeyen sınıf: {s}", .{class_name});
        if (info.fields.get(a.attr)) |ft| return ft;
        return self.fail(error.UndefinedAttribute, "'{s}' sınıfının '{s}' alanı yok", .{ class_name, a.attr });
    }

    fn checkCall(self: *Checker, ctx: *FnCtx, c: ast.Call) TypeError!Type {
        switch (c.callee.*) {
            .identifier => |name| {
                // Faz 7 (tekli kalıtım): çıplak `super()` (yani `super().
                // metod(...)`un ALICI konumu DIŞINDA bir yerde) HER ZAMAN
                // reddedilir — `super()`in TEK geçerli kullanımı
                // `checkCall`in `.attribute` dalındaki `isSuperCallExpr`
                // ÖZEL-işlemesidir (bkz. onun belge notu); BU dal SADECE
                // `x = super()` / `f(super())` gibi (`checkExpr` ÜZERİNDEN
                // BURAYA sızan) YANLIŞ kullanımları YAKALAR.
                if (std.mem.eql(u8, name, "super")) {
                    return self.fail(error.TypeMismatch, "'super()' yalnızca 'super().metod(...)' ya da 'super().__init__(...)' kalıbında, doğrudan bir metod çağrısının alıcısı olarak kullanılabilir", .{});
                }
                if (std.mem.eql(u8, name, "print")) {
                    if (c.args.len != 1) return self.fail(error.ArgumentCountMismatch, "'print' tam olarak 1 argüman alır", .{});
                    _ = try self.checkExpr(ctx, c.args[0]);
                    return .none;
                }
                // `len(s) -> int` — stdlib fazı §B, `print`/`range` ile AYNI
                // özel-işlenen yerleşik kalıbı (bkz. codegen.zig'in `genCall`i).
                // Stdlib fazı §L: `list[T]` de kabul edilir (`nox.json`nin
                // `array_len`/`object_len`si İÇİN — GENEL bir genişletme,
                // JSON'a özgü DEĞİL; `dict.len()` HÂLÂ AYRI bir metod
                // çağrısı olarak kalır, bkz. `.attribute` dalındaki `dict`
                // özel işlemesi).
                if (std.mem.eql(u8, name, "len")) {
                    if (c.args.len != 1) return self.fail(error.ArgumentCountMismatch, "'len' tam olarak 1 argüman alır", .{});
                    const t = try self.checkExpr(ctx, c.args[0]);
                    if (t != .str and t != .list) {
                        return self.fail(error.TypeMismatch, "'len' yalnızca str/list üzerinde çalışır", .{});
                    }
                    return .int;
                }
                // `str(x)`/`int(s)`/`float(s)` — stdlib fazı §E, `len` İLE
                // AYNI özel-işlenen yerleşik kalıbı (bkz. codegen.zig'in
                // `genCall`ı). Bu isimler `typeExprToType`de TİP
                // ifadesi olarak da kullanılıyor OLSA da (ör. `x: int = ...`),
                // BURASI bir ÇAĞRI bağlamıdır — iki ayrı ayrıştırma yolu,
                // hiç çakışma yok. `int(s)`/`float(s)` ayrıştırma
                // BAŞARISIZ olursa çalışma zamanında bir `ValueError`
                // `raise` eder (bkz. codegen.zig'in `genCall`ı,
                // `nox_str_is_valid_int`/`float` + `nox_raise`).
                if (std.mem.eql(u8, name, "str")) {
                    if (c.args.len != 1) return self.fail(error.ArgumentCountMismatch, "'str' tam olarak 1 argüman alır", .{});
                    const t = try self.checkExpr(ctx, c.args[0]);
                    // Bulundu (bkz. proje belleği "f-string + augmented
                    // atama" görevi): f-string desugarı (`f"{x}"` →
                    // `... + str(x) + ...`) MEKANİK olduğundan (parser tip
                    // bilgisine SAHİP DEĞİLDİR, "zaten str/bool İSE str()
                    // SARMALAMAYI atla" kararını VEREMEZ) `str()`nin
                    // KENDİSİ `str`/`bool`i de kabul etmelidir — bu AYRICA
                    // genel bir iyileştirme (`str("zaten bir str")`/
                    // `str(True)` artık DOĞRUDAN da çalışır).
                    if (t != .int and t != .float and t != .str and t != .boolean) {
                        return self.fail(error.TypeMismatch, "'str' yalnızca int/float/str/bool üzerinde çalışır", .{});
                    }
                    return .str;
                }
                if (std.mem.eql(u8, name, "int")) {
                    if (c.args.len != 1) return self.fail(error.ArgumentCountMismatch, "'int' tam olarak 1 argüman alır", .{});
                    // `round()` builtin'i (bkz. core.nox) `int(x + 0.5)`
                    // İLE float->int TRUNCATE ETMEYE ihtiyaç duyar — Python'ın
                    // `int(3.9) == 3` davranışıyla AYNI, `str` ayrıştırmasına
                    // EK olarak (onun YERİNE değil).
                    const t = try self.checkExpr(ctx, c.args[0]);
                    if (t != .str and t != .float) {
                        return self.fail(error.TypeMismatch, "'int' yalnızca str/float üzerinde çalışır", .{});
                    }
                    return .int;
                }
                if (std.mem.eql(u8, name, "float")) {
                    if (c.args.len != 1) return self.fail(error.ArgumentCountMismatch, "'float' tam olarak 1 argüman alır", .{});
                    if (try self.checkExpr(ctx, c.args[0]) != .str) {
                        return self.fail(error.TypeMismatch, "'float' yalnızca str üzerinde çalışır", .{});
                    }
                    return .float;
                }
                // Faz 14: `hpy_call`/`wasm_call` — Faz 12/13'ün köprülerini
                // (bkz. runtime/foreign_bridge.zig) Nox kaynağından
                // çağırabilmek için `print` gibi özel işlenen, sabit
                // imzalı iki yerleşik. Bkz. nox-teknik-spesifikasyon.md
                // §3.14.
                if (std.mem.eql(u8, name, "hpy_call")) {
                    if (c.args.len != 4) {
                        return self.fail(error.ArgumentCountMismatch, "'hpy_call' tam olarak 4 argüman alır (yol: str, uzantı_adı: str, fonksiyon_adı: str, argüman: int)", .{});
                    }
                    if (try self.checkExpr(ctx, c.args[0]) != .str) return self.fail(error.TypeMismatch, "'hpy_call' argümanı 1 (yol) str olmalıdır", .{});
                    if (try self.checkExpr(ctx, c.args[1]) != .str) return self.fail(error.TypeMismatch, "'hpy_call' argümanı 2 (uzantı adı) str olmalıdır", .{});
                    if (try self.checkExpr(ctx, c.args[2]) != .str) return self.fail(error.TypeMismatch, "'hpy_call' argümanı 3 (fonksiyon adı) str olmalıdır", .{});
                    if (try self.checkExpr(ctx, c.args[3]) != .int) return self.fail(error.TypeMismatch, "'hpy_call' argümanı 4 (argüman) int olmalıdır", .{});
                    // Güvenlik bulgusu H-1 (bkz. güvenlik raporu) —
                    // DÜZELTİLDİ: `yol`/`uzantı_adı`/`fonksiyon_adı` ÖNCEDEN
                    // yalnızca TİPÇE `str` olmak zorundaydı, DEĞER olarak
                    // keyfi çalışma-zamanı ifadeleri (bir config dosyasından/
                    // ortam değişkeninden/ağ yanıtından okunan bir `str`)
                    // OLABİLİYORDU — `runtime/hpy_bridge/loader.zig`nin
                    // `std.DynLib.open`ı BU yolu doğrulamasız, sandbox'sız
                    // AÇIP eşleşen `HPyInit_*` sembolünü fonksiyon işaretçisi
                    // olarak ÇAĞIRDIĞINDAN, bu SIRADAN Nox kodundan
                    // ulaşılabilen, doğrulamasız bir "keyfi native kütüphane
                    // yükle ve çalıştır" ilkeliydi. ÜÇÜ de ARTIK derleme-
                    // zamanı SABİTİ (`.string_lit`) OLMAK ZORUNDA — bir
                    // Nox programı hangi native kodu yükleyeceğini KAYNAK
                    // KODUNDA AÇIKÇA yazmalıdır, ÇALIŞMA ZAMANINDA hesaplayıp
                    // GİZLEYEMEZ (`extern def ... from "<lib>"`nin ZATEN
                    // dilbilgisi SEVİYESİNDE yalnızca bir string TOKEN'I
                    // kabul etmesiyle AYNI ilke).
                    if (c.args[0] != .string_lit) {
                        return self.fail(error.TypeMismatch, "'hpy_call' argümanı 1 (yol) yalnızca bir string LİTERALİ olabilir (güvenlik: çalışma-zamanı hesaplı bir yoldan keyfi native kütüphane yüklenmesi önlenir)", .{});
                    }
                    if (c.args[1] != .string_lit) {
                        return self.fail(error.TypeMismatch, "'hpy_call' argümanı 2 (uzantı adı) yalnızca bir string LİTERALİ olabilir", .{});
                    }
                    if (c.args[2] != .string_lit) {
                        return self.fail(error.TypeMismatch, "'hpy_call' argümanı 3 (fonksiyon adı) yalnızca bir string LİTERALİ olabilir", .{});
                    }
                    return .int;
                }
                // Faz 15 (bkz. nox-teknik-spesifikasyon.md §3.78): `hpy_call`in
                // AYNI güvenlik kısıtlarına (İLK 3 argüman string LİTERALİ
                // OLMAK ZORUNDA) sahip, YALNIZCA `str` argüman/dönüşlü kardeşi
                // — `HPyFunc_KEYWORDS` imzalı metodları (`hpy_call`nin
                // `HPyFunc_O`sunun AKSİNE, ör. `ujson_hpy.dumps`/`loads`)
                // POZİSYONEL-TEK-ARGÜMAN (anahtar kelime YOK) olarak çağırır.
                if (std.mem.eql(u8, name, "hpy_call_str")) {
                    if (c.args.len != 4) {
                        return self.fail(error.ArgumentCountMismatch, "'hpy_call_str' tam olarak 4 argüman alır (yol: str, uzantı_adı: str, fonksiyon_adı: str, argüman: str)", .{});
                    }
                    if (try self.checkExpr(ctx, c.args[0]) != .str) return self.fail(error.TypeMismatch, "'hpy_call_str' argümanı 1 (yol) str olmalıdır", .{});
                    if (try self.checkExpr(ctx, c.args[1]) != .str) return self.fail(error.TypeMismatch, "'hpy_call_str' argümanı 2 (uzantı adı) str olmalıdır", .{});
                    if (try self.checkExpr(ctx, c.args[2]) != .str) return self.fail(error.TypeMismatch, "'hpy_call_str' argümanı 3 (fonksiyon adı) str olmalıdır", .{});
                    if (try self.checkExpr(ctx, c.args[3]) != .str) return self.fail(error.TypeMismatch, "'hpy_call_str' argümanı 4 (argüman) str olmalıdır", .{});
                    // Güvenlik bulgusu H-1'in AYNI düzeltmesi — bkz. `hpy_call`nin
                    // belge notu.
                    if (c.args[0] != .string_lit) {
                        return self.fail(error.TypeMismatch, "'hpy_call_str' argümanı 1 (yol) yalnızca bir string LİTERALİ olabilir (güvenlik: çalışma-zamanı hesaplı bir yoldan keyfi native kütüphane yüklenmesi önlenir)", .{});
                    }
                    if (c.args[1] != .string_lit) {
                        return self.fail(error.TypeMismatch, "'hpy_call_str' argümanı 2 (uzantı adı) yalnızca bir string LİTERALİ olabilir", .{});
                    }
                    if (c.args[2] != .string_lit) {
                        return self.fail(error.TypeMismatch, "'hpy_call_str' argümanı 3 (fonksiyon adı) yalnızca bir string LİTERALİ olabilir", .{});
                    }
                    return .str;
                }
                // Faz 1 decorator (bkz. plan dosyası "Decorator sözdizimi +
                // metadata-tabanlı metaprogramming"): `stdlib/nox/reflect.
                // nox`nin sardığı 6 SABİT-imzalı yerleşik — `hpy_call`nin
                // AYNI "özel işlenen, kullanıcı TARAFINDAN yeniden
                // tanımlanamayan builtin isim" deseni. İsimler HERHANGİ bir
                // Nox tanımlayıcısıyla ÇAKIŞMAYACAK biçimde `__nox_reflect_`
                // öneki taşır (yalnızca `reflect.nox` bunları çağırır —
                // kullanıcı KODU DOĞRUDAN çağırmaz).
                if (std.mem.eql(u8, name, "__nox_reflect_decorator_count")) {
                    if (c.args.len != 0) return self.fail(error.ArgumentCountMismatch, "'__nox_reflect_decorator_count' hiçbir argüman almaz", .{});
                    return .int;
                }
                if (std.mem.eql(u8, name, "__nox_reflect_decorator_target_name")) {
                    if (c.args.len != 1) return self.fail(error.ArgumentCountMismatch, "'__nox_reflect_decorator_target_name' tam olarak 1 argüman alır (i: int)", .{});
                    if (try self.checkExpr(ctx, c.args[0]) != .int) return self.fail(error.TypeMismatch, "'__nox_reflect_decorator_target_name' argümanı int olmalıdır", .{});
                    return .str;
                }
                if (std.mem.eql(u8, name, "__nox_reflect_decorator_name")) {
                    if (c.args.len != 1) return self.fail(error.ArgumentCountMismatch, "'__nox_reflect_decorator_name' tam olarak 1 argüman alır (i: int)", .{});
                    if (try self.checkExpr(ctx, c.args[0]) != .int) return self.fail(error.TypeMismatch, "'__nox_reflect_decorator_name' argümanı int olmalıdır", .{});
                    return .str;
                }
                if (std.mem.eql(u8, name, "__nox_reflect_decorator_arg_count")) {
                    if (c.args.len != 1) return self.fail(error.ArgumentCountMismatch, "'__nox_reflect_decorator_arg_count' tam olarak 1 argüman alır (i: int)", .{});
                    if (try self.checkExpr(ctx, c.args[0]) != .int) return self.fail(error.TypeMismatch, "'__nox_reflect_decorator_arg_count' argümanı int olmalıdır", .{});
                    return .int;
                }
                if (std.mem.eql(u8, name, "__nox_reflect_decorator_arg")) {
                    if (c.args.len != 2) return self.fail(error.ArgumentCountMismatch, "'__nox_reflect_decorator_arg' tam olarak 2 argüman alır (i: int, j: int)", .{});
                    if (try self.checkExpr(ctx, c.args[0]) != .int) return self.fail(error.TypeMismatch, "'__nox_reflect_decorator_arg' argümanı 1 (i) int olmalıdır", .{});
                    if (try self.checkExpr(ctx, c.args[1]) != .int) return self.fail(error.TypeMismatch, "'__nox_reflect_decorator_arg' argümanı 2 (j) int olmalıdır", .{});
                    return .str;
                }
                // `i`nin kaydı "handler-şekilli" mi (bkz. `registerDecorators`
                // in `is_handler_shaped` belge notu) — `stdlib/nox/router.
                // nox`nin ekleyeceği `router_from_decorators()` yardımcısı,
                // `__nox_reflect_decorator_handler(i)`i ÇAĞIRMADAN ÖNCE BUNU
                // kontrol ETMELİDİR (aksi halde eşleşmeyen bir `i` İçin
                // `handler` NULL/0 döner — bkz. `decorators.zig`nin
                // `genReflectDecoratorHandler`ı).
                if (std.mem.eql(u8, name, "__nox_reflect_decorator_is_handler")) {
                    if (c.args.len != 1) return self.fail(error.ArgumentCountMismatch, "'__nox_reflect_decorator_is_handler' tam olarak 1 argüman alır (i: int)", .{});
                    if (try self.checkExpr(ctx, c.args[0]) != .int) return self.fail(error.TypeMismatch, "'__nox_reflect_decorator_is_handler' argümanı int olmalıdır", .{});
                    return .boolean;
                }
                // Dönüş tipi `(Context) -> HttpResponse` — BİLİNÇLİ OLARAK
                // Optional DEĞİL (Nox'un `T | None` sözdizimi bir `(P) -> R`
                // func_type'ını SARAMAZ — `| None` HER ZAMAN `parseTypeExpr`
                // İÇİNDE en yakın DÖNÜŞ tipine bağlanır, bkz. `parser.zig`nin
                // `parseBaseTypeExpr`inin func_type dalı — bu BİLİNÇLİ, VAR
                // OLAN `list[(Context) -> HttpResponse | None]` (ara katman
                // İmzası, router.nox) semantiğini BOZMAMAK İçin dokunulmadı).
                // Bu YÜZDEN çağıran TARAF (`__nox_reflect_decorator_is_
                // handler` İLE) ÖNCE doğrulamalıdır — "Context"/"HttpResponse"
                // İSE `registerDecorators`in AYNI mangled-isim gerekçesiyle
                // (`self.from_imports` ÜZERİNDEN) çözülür.
                if (std.mem.eql(u8, name, "__nox_reflect_decorator_handler")) {
                    if (c.args.len != 1) return self.fail(error.ArgumentCountMismatch, "'__nox_reflect_decorator_handler' tam olarak 1 argüman alır (i: int)", .{});
                    if (try self.checkExpr(ctx, c.args[0]) != .int) return self.fail(error.TypeMismatch, "'__nox_reflect_decorator_handler' argümanı int olmalıdır", .{});
                    const context_name = self.from_imports.get("Context") orelse "Context";
                    const http_response_name = self.from_imports.get("HttpResponse") orelse "HttpResponse";
                    const params = try self.allocator.alloc(Type, 1);
                    params[0] = .{ .class = context_name };
                    const ret_ty = try self.allocator.create(Type);
                    ret_ty.* = .{ .class = http_response_name };
                    return .{ .func = .{ .params = params, .return_type = ret_ty } };
                }
                if (std.mem.eql(u8, name, "wasm_call")) {
                    if (c.args.len != 3) {
                        return self.fail(error.ArgumentCountMismatch, "'wasm_call' tam olarak 3 argüman alır (yol: str, fonksiyon_adı: str, argüman: int)", .{});
                    }
                    if (try self.checkExpr(ctx, c.args[0]) != .str) return self.fail(error.TypeMismatch, "'wasm_call' argümanı 1 (yol) str olmalıdır", .{});
                    if (try self.checkExpr(ctx, c.args[1]) != .str) return self.fail(error.TypeMismatch, "'wasm_call' argümanı 2 (fonksiyon adı) str olmalıdır", .{});
                    if (try self.checkExpr(ctx, c.args[2]) != .int) return self.fail(error.TypeMismatch, "'wasm_call' argümanı 3 (argüman) int olmalıdır", .{});
                    return .int;
                }
                // GG.22 (bkz. plan dosyası "checkCall gölgeleme-çözümleme
                // düzeltmesi"): yerel bir değişken/parametre (`ctx.scope`,
                // Faz U.4.2'nin capture-farkında `Scope`u) GERÇEK bir global
                // fonksiyon/sınıf/generic fonksiyonla AYNI adı taşıdığında,
                // codegen'in `genCall`ı (calls.zig) HER ZAMAN `self.vars`
                // (yerel/closure) TABLOSUNU `self.functions`den ÖNCE kontrol
                // ediyor — yani YEREL HER ZAMAN kazanıyor. Bu kontrol ÖNCEDEN
                // `generic_functions`/`functions`/`classes`DEN SONRA
                // geliyordu (SADECE `from_imports`e göre öncelikliydi) —
                // checker/codegen ANLAŞMAZLIĞI: bir yerel değişken global BİR
                // fonksiyonla AYNI adı AMA FARKLI bir imza TAŞIDIĞINDA,
                // checker YANLIŞLIKLA global'in imzasına göre doğrulardı,
                // codegen İSE GERÇEKTEN yerelin tuttuğu değeri ÇAĞIRIRDI.
                // Şimdi codegen'İN ÖNCELİK SIRASIYLA TAM eşleşiyor: yerel
                // BULUNURSA (VE `.func` İSE) BURADA sonuçlanır, generic/
                // global/sınıf/from-import'A HİÇ DÜŞMEZ.
                if (try ctx.scope.lookup(self.allocator, name)) |vt| {
                    if (vt == .func) {
                        try self.checkArgs(ctx, vt.func.params, c.args, name);
                        return vt.func.return_type.*;
                    }
                    return self.fail(error.TypeMismatch, "'{s}' bir fonksiyon değildir, çağrılamaz", .{name});
                }
                if (self.generic_functions.get(name)) |gfd| {
                    return try self.instantiateGeneric(ctx, gfd, c);
                }
                if (self.functions.get(name)) |sig| {
                    // `async def` fonksiyonlar DOĞRUDAN çağrılamaz — gövdeleri
                    // `await` içerebilir, bu da bir fiber bağlamı GEREKTİRİR;
                    // yalnızca `spawn` bunu sağlar (bkz. `.spawn_expr` dalı,
                    // nox-teknik-spesifikasyon.md §3.21).
                    if (self.async_functions.contains(name)) {
                        return self.fail(error.TypeMismatch, "'{s}' bir 'async def' fonksiyonudur, yalnızca 'spawn' ile başlatılabilir", .{name});
                    }
                    try self.checkArgs(ctx, sig.params, c.args, name);
                    return sig.return_type;
                }
                if (self.classes.contains(name)) {
                    const info = self.classes.get(name).?;
                    const init_sig = info.init_sig orelse FuncSig{ .params = &.{}, .return_type = .none };
                    try self.checkArgs(ctx, init_sig.params, c.args, name);
                    return .{ .class = name };
                }
                // Faz U.3: `from X.Y import foo[as bar]` ile bağlanan ÇIPLAK
                // bir çağrı (`bar(...)`) — yerel bir fonksiyon/sınıf tanımı
                // (YUKARIDAKİ dallar) HER ZAMAN ÖNCELİKLİDİR, bu dal yalnızca
                // NORMAL çözümleme başarısız olduğunda denenir.
                if (self.from_imports.get(name)) |mangled| {
                    const not_found_msg = try std.fmt.allocPrint(self.allocator, "'{s}' içe aktarılamadı (kaynak modülde '{s}' adlı bir üye yok)", .{ name, mangled });
                    return try self.resolveMangledCall(ctx, c, mangled, not_found_msg);
                }
                return self.fail(error.UndefinedFunction, "tanımsız fonksiyon veya sınıf: {s}", .{name});
            },
            .attribute => |a| {
                // v1.32.0 (bkz. nox-teknik-spesifikasyon.md §3.98): ESKİDEN
                // BURADA `nox.http.serve`/`serve_fd`/`serve_multicore`/9 TLS-
                // WS varyantı/`nox.thread.start`/`pool_run` İçİn 14 SIRALI
                // `tryResolveX` çağrısı vardı (`handle`/`entry` çıplak bir
                // fonksiyon ADI olduğundan — Nox'ta fonksiyonlar birinci
                // sınıf DEĞER OLMADIĞINDAN — normal argüman tipi denetiminden
                // GEÇİRİLEMEDİĞİ İçİn `tryResolveQualifiedCall`DAN ÖNCE
                // denenmesi GEREKİYORDU). ARTIK TEK bir `matchIntrinsicKind`
                // sınıflandırması + switch — codegen'in `IntrinsicKind`/
                // `intrinsic_table`/`matchIntrinsicKind`ünün (Faz P1.6,
                // async_thread.zig) checker'a ÖZEL kopyası (bkz. onun belge
                // notu, PAYLAŞILAMAMA gerekçesi). `rewriteIntrinsicCalleeToCanonical`
                // çağrısı, eşleşen bir çağrı bir modül TAKMA ADI ÜZERİNDEN
                // yazılmış olsa BİLE (`import nox.http as h; h.serve(...)`)
                // codegen'in alias-farkında OLMAYAN `matchesNoxAttr`inin
                // HER ZAMAN tanıyacağı kanonik `nox.<module>.<name>` şeklini
                // GARANTİ EDER (GERÇEK bir bug'ın düzeltmesi — bkz. plan
                // dosyası).
                if (try self.matchIntrinsicKind(c)) |entry| {
                    try self.rewriteIntrinsicCalleeToCanonical(c, entry.module, entry.name);
                    return switch (entry.kind) {
                        .http_serve => (try self.tryResolveHttpServeCall(ctx, c)).?,
                        .http_serve_fd => (try self.tryResolveHttpServeFdCall(ctx, c)).?,
                        .http_serve_multicore => (try self.tryResolveHttpServeMulticoreCall(ctx, c)).?,
                        .http_serve_tls => (try self.tryResolveHttpServeGeneric(ctx, c, "serve_tls", false, false, true)).?,
                        .http_serve_ws => (try self.tryResolveHttpServeGeneric(ctx, c, "serve_ws", false, true, false)).?,
                        .http_serve_ws_tls => (try self.tryResolveHttpServeGeneric(ctx, c, "serve_ws_tls", false, true, true)).?,
                        .http_serve_fd_tls => (try self.tryResolveHttpServeGeneric(ctx, c, "serve_fd_tls", false, false, true)).?,
                        .http_serve_fd_ws => (try self.tryResolveHttpServeGeneric(ctx, c, "serve_fd_ws", false, true, false)).?,
                        .http_serve_fd_ws_tls => (try self.tryResolveHttpServeGeneric(ctx, c, "serve_fd_ws_tls", false, true, true)).?,
                        .http_serve_multicore_tls => (try self.tryResolveHttpServeGeneric(ctx, c, "serve_multicore_tls", true, false, true)).?,
                        .http_serve_multicore_ws => (try self.tryResolveHttpServeGeneric(ctx, c, "serve_multicore_ws", true, true, false)).?,
                        .http_serve_multicore_ws_tls => (try self.tryResolveHttpServeGeneric(ctx, c, "serve_multicore_ws_tls", true, true, true)).?,
                        .thread_start => (try self.tryResolveThreadSpawnCall(ctx, c)).?,
                        .pool_run => (try self.tryResolvePoolRunCall(ctx, c)).?,
                    };
                }
                // `nox.http.get(url)` gibi bir stdlib modülüne nitelikli
                // erişimi dener (bkz. `tryResolveQualifiedCall`in belge
                // notu) — bu, ASAĞIDAKİ `checkExpr(ctx, a.obj.*)`DEN ÖNCE
                // olmalı, çünkü `nox`/`nox.http` GERÇEK bir değişken/ifade
                // DEĞİLDİR (`checkExpr` "tanımsız değişken" ile başarısız
                // olurdu). Eşleşmezse (`null`) MEVCUT metod-çağrısı
                // çözümlemesine (aşağısı, DEĞİŞMEMİŞ) düşülür.
                if (try self.tryResolveQualifiedCall(ctx, c)) |t| return t;
                // Faz 7 (tekli kalıtım): `super().metod(...)` /
                // `super().__init__(...)` — GENEL `checkExpr(a.obj.*)`
                // çağrısından ÖNCE yakalanır (çıplak `super()`, YUKARIDAKİ
                // `.identifier` dalında HER ZAMAN reddedilir — bu yüzden
                // `checkExpr` ÜZERİNDEN asla BURAYA ULAŞAMAZ; süper-çağrı
                // deseni SADECE burada, doğrudan bir metod çağrısının
                // ALICISI olarak tanınır). `__init__` normal `info.methods`
                // haritasında HİÇ YOKTUR (ayrı `info.init_sig`de tutulur,
                // bkz. `registerClassSignatures`) — bu yüzden özel olarak
                // ele alınır.
                if (isSuperCallExpr(a.obj.*)) {
                    const self_class = ctx.self_class orelse
                        return self.fail(error.TypeMismatch, "'super()' yalnızca bir metod gövdesi içinde kullanılabilir", .{});
                    const self_info = self.classes.get(self_class) orelse
                        return self.fail(error.UndefinedClass, "bilinmeyen sınıf: {s}", .{self_class});
                    const base_name = self_info.base orelse
                        return self.fail(error.TypeMismatch, "'{s}' sınıfının bir taban sınıfı yok, 'super()' kullanılamaz", .{self_class});
                    const base_info = self.classes.get(base_name).?;
                    if (std.mem.eql(u8, a.attr, "__init__")) {
                        const init_sig = base_info.init_sig orelse FuncSig{ .params = &.{}, .return_type = .none };
                        try self.checkArgs(ctx, init_sig.params, c.args, "__init__");
                        return .none;
                    }
                    if (base_info.methods.get(a.attr)) |sig| {
                        try self.checkArgs(ctx, sig.params, c.args, a.attr);
                        return sig.return_type;
                    }
                    return self.fail(error.UndefinedMethod, "'{s}' taban sınıfının '{s}' metodu yok", .{ base_name, a.attr });
                }

                const obj_t = try self.checkExpr(ctx, a.obj.*);
                try self.requireNotOptional(obj_t, a.attr);
                // `Channel[T]`in yerleşik `send`/`recv`i — bir kullanıcı
                // sınıfı DEĞİL, bu yüzden `self.classes` yerine burada özel
                // olarak işlenir (bkz. nox-teknik-spesifikasyon.md §3.21).
                // İkisi de `await` ile sarmalanmalıdır — bu kısıt burada
                // DEĞİL, `.await_expr` dalında denetlenir.
                if (obj_t == .channel) {
                    const elem_t = obj_t.channel.*;
                    if (std.mem.eql(u8, a.attr, "send")) {
                        if (c.args.len != 1) return self.fail(error.ArgumentCountMismatch, "'send' tam olarak 1 argüman alır", .{});
                        const at = try self.checkExpr(ctx, c.args[0]);
                        if (!self.assignable(elem_t, at)) return self.fail(error.TypeMismatch, "'send' argümanı kanalın eleman tipiyle uyuşmuyor", .{});
                        return .none;
                    }
                    if (std.mem.eql(u8, a.attr, "recv")) {
                        if (c.args.len != 0) return self.fail(error.ArgumentCountMismatch, "'recv' hiç argüman almaz", .{});
                        return elem_t;
                    }
                    return self.fail(error.UndefinedMethod, "Channel'ın '{s}' metodu yok (yalnızca send/recv)", .{a.attr});
                }
                // `TaskLocal[T]`in yerleşik `get`/`set`/`clear`i — Faz OO.2
                // (bkz. nox-teknik-spesifikasyon.md §3.83), `Channel` İLE
                // AYNI desen (bir kullanıcı sınıfı DEĞİL). `send`/`recv`nin
                // AKSİNE `await` GEREKTİRMEZ — senkron, o AN çalışan fiber'a
                // ÖZGÜ bir okuma/yazma.
                if (obj_t == .task_local) {
                    const elem_t = obj_t.task_local.*;
                    if (std.mem.eql(u8, a.attr, "get")) {
                        if (c.args.len != 0) return self.fail(error.ArgumentCountMismatch, "'get' hiç argüman almaz", .{});
                        const boxed = try self.allocator.create(Type);
                        boxed.* = elem_t;
                        return .{ .optional = boxed };
                    }
                    if (std.mem.eql(u8, a.attr, "set")) {
                        if (c.args.len != 1) return self.fail(error.ArgumentCountMismatch, "'set' tam olarak 1 argüman alır", .{});
                        const at = try self.checkExpr(ctx, c.args[0]);
                        if (!self.assignable(elem_t, at)) return self.fail(error.TypeMismatch, "'set' argümanı TaskLocal'ın eleman tipiyle uyuşmuyor", .{});
                        return .none;
                    }
                    if (std.mem.eql(u8, a.attr, "clear")) {
                        if (c.args.len != 0) return self.fail(error.ArgumentCountMismatch, "'clear' hiç argüman almaz", .{});
                        return .none;
                    }
                    return self.fail(error.UndefinedMethod, "TaskLocal'ın '{s}' metodu yok (yalnızca get/set/clear)", .{a.attr});
                }
                // `ThreadHandle[T]`in yerleşik `join`i — Faz BB.3, `Channel`
                // İLE AYNI desen (bir kullanıcı sınıfı DEĞİL, burada özel
                // işlenir). `await` İLE sarmalanmalıdır — bu kısıt burada
                // DEĞİL, `.await_expr` dalında denetlenir.
                if (obj_t == .thread_handle) {
                    if (std.mem.eql(u8, a.attr, "join")) {
                        if (c.args.len != 0) return self.fail(error.ArgumentCountMismatch, "'join' hiç argüman almaz", .{});
                        return obj_t.thread_handle.*;
                    }
                    return self.fail(error.UndefinedMethod, "ThreadHandle'ın '{s}' metodu yok (yalnızca join)", .{a.attr});
                }
                // `ThreadChannel[T]`in yerleşik `send`/`recv`i — Faz BB.6,
                // `Channel` İLE BİREBİR AYNI desen/sözleşme (İKİSİ de
                // `await` İLE sarmalanmalıdır — bu kısıt burada DEĞİL,
                // `.await_expr` dalında denetlenir). `Channel`den AYRI bir
                // dal olmasının nedeni SADECE `obj_t.channel` yerine
                // `obj_t.thread_channel`in okunması gerekmesi — element tipi
                // KISITI ZATEN `generic_construct`ta (`isThreadTransferSafeType`)
                // uygulandığından burada TEKRAR denetlenmez.
                if (obj_t == .thread_channel) {
                    const elem_t = obj_t.thread_channel.*;
                    if (std.mem.eql(u8, a.attr, "send")) {
                        if (c.args.len != 1) return self.fail(error.ArgumentCountMismatch, "'send' tam olarak 1 argüman alır", .{});
                        const at = try self.checkExpr(ctx, c.args[0]);
                        if (!self.assignable(elem_t, at)) return self.fail(error.TypeMismatch, "'send' argümanı kanalın eleman tipiyle uyuşmuyor", .{});
                        return .none;
                    }
                    if (std.mem.eql(u8, a.attr, "recv")) {
                        if (c.args.len != 0) return self.fail(error.ArgumentCountMismatch, "'recv' hiç argüman almaz", .{});
                        return elem_t;
                    }
                    return self.fail(error.UndefinedMethod, "ThreadChannel'ın '{s}' metodu yok (yalnızca send/recv)", .{a.attr});
                }
                // `dict[K, V]`in yerleşik `contains`/`len`i — `Channel`le AYNI
                // desen: bir kullanıcı sınıfı DEĞİL, burada özel işlenir
                // (bkz. nox-teknik-spesifikasyon.md §3.28).
                if (obj_t == .dict) {
                    if (std.mem.eql(u8, a.attr, "contains")) {
                        if (c.args.len != 1) return self.fail(error.ArgumentCountMismatch, "'contains' tam olarak 1 argüman alır", .{});
                        const kt = try self.checkExpr(ctx, c.args[0]);
                        if (!types.eql(kt, obj_t.dict.key.*)) return self.fail(error.TypeMismatch, "'contains' argümanı dict'in anahtar tipiyle uyuşmuyor", .{});
                        return .boolean;
                    }
                    if (std.mem.eql(u8, a.attr, "len")) {
                        if (c.args.len != 0) return self.fail(error.ArgumentCountMismatch, "'len' hiç argüman almaz", .{});
                        return .int;
                    }
                    // Faz III.6 (bkz. nox-teknik-spesifikasyon.md §3.69) —
                    // salt-okunur iterasyon: `keys()`/`values()`. `remove()`/
                    // `items()` (çift/`DictEntry` tipi gerektirir) BİLİNÇLİ
                    // olarak KAPSAM DIŞI (bkz. planın "Kapsam DIŞI" bölümü).
                    if (std.mem.eql(u8, a.attr, "keys")) {
                        if (c.args.len != 0) return self.fail(error.ArgumentCountMismatch, "'keys' hiç argüman almaz", .{});
                        return Type{ .list = obj_t.dict.key };
                    }
                    if (std.mem.eql(u8, a.attr, "values")) {
                        if (c.args.len != 0) return self.fail(error.ArgumentCountMismatch, "'values' hiç argüman almaz", .{});
                        return Type{ .list = obj_t.dict.value };
                    }
                    return self.fail(error.UndefinedMethod, "dict'in '{s}' metodu yok (yalnızca contains/len/keys/values)", .{a.attr});
                }
                // `list[T]`in yerleşik `append`i — Faz U.1, `dict`in AYNI
                // deseni. **Bilinçli v1 sınırlaması:** alıcı (`a.obj.*`)
                // SADECE çıplak bir isim (yerel değişken/parametre)
                // OLABİLİR — `spawn`in çağrı-hedefi kısıtıyla AYNI gerekçe
                // (bkz. nox-teknik-spesifikasyon.md §3.21): codegen'in
                // BÜYÜME durumunda YENİ bir bloğa geçmesi GEREKEBİLİR
                // (kapasite dolduğunda), bu da alıcının KENDİ SLOTUNA geri
                // yazma gerektirir — bu yalnızca bir DEĞİŞKENİN slotu İÇİN
                // anlamlıdır (`getList().append(v)`/`obj.field.append(v)`
                // gibi bir SLOTU OLMAYAN ifadeler İÇİN DEĞİL).
                if (obj_t == .list) {
                    if (std.mem.eql(u8, a.attr, "append")) {
                        if (a.obj.* != .identifier) {
                            return self.fail(error.TypeMismatch, "'append' yalnızca bir değişken üzerinde çağrılabilir (ör. 'xs.append(v)')", .{});
                        }
                        if (c.args.len != 1) return self.fail(error.ArgumentCountMismatch, "'append' tam olarak 1 argüman alır", .{});
                        const vt = try self.checkExpr(ctx, c.args[0]);
                        if (!self.assignable(obj_t.list.*, vt)) return self.fail(error.TypeMismatch, "'append' argümanı listenin eleman tipiyle uyuşmuyor", .{});
                        return .none;
                    }
                    // Faz EE.1 (bkz. nox-teknik-spesifikasyon.md §3.61) —
                    // `list[T].sort()`: `.append`nin AKSİNE alıcı çıplak bir
                    // isim OLMAK ZORUNDA DEĞİLDİR (`getList().sort()`/`obj.
                    // field.sort()` da GEÇERLİDİR) — sıralama MEVCUT arabelleği
                    // YERİNDE değiştirir, `len`/`cap` DEĞİŞMEZ, bu yüzden
                    // `append`nin "büyüme durumunda alıcının KENDİ SLOTUNA
                    // geri yazma" kısıtı BURADA GEÇERLİ DEĞİLDİR (bkz.
                    // `codegen.zig`nin `genListSort`ı). Eleman tipi `int`/
                    // `float`/`str` OLMALIDIR — Nox'ta kullanıcı-tanımlı
                    // `__lt__`/karşılaştırıcı YOK, bu yüzden sınıf/`list`/
                    // `dict` elemanları İÇİN "nasıl sıralanır" TANIMSIZDIR.
                    if (std.mem.eql(u8, a.attr, "sort")) {
                        if (c.args.len != 0) return self.fail(error.ArgumentCountMismatch, "'sort' hiç argüman almaz", .{});
                        switch (obj_t.list.*) {
                            .int, .float, .str => {},
                            else => return self.fail(error.TypeMismatch, "'sort' yalnızca list[int]/list[float]/list[str] üzerinde çağrılabilir", .{}),
                        }
                        return .none;
                    }
                    // `list[T].pop()`: `.sort()` GİBİ alıcı keyfi bir ifade
                    // OLABİLİR (`self.items.pop()` doğrudan geçerli) —
                    // `.append`in AKSİNE `pop` HİÇBİR ZAMAN büyümez/yeniden
                    // ayırmaz (yalnızca `len` başlığını AYNI blokta bir
                    // AZALTIR, bkz. `codegen_qbe/calls.zig`nin `genListPop`ı),
                    // bu yüzden alıcının KENDİ SLOTUNA geri yazma GEREKMEZ.
                    // Boş listede `IndexError` (bkz. `core.nox`) fırlatılır.
                    if (std.mem.eql(u8, a.attr, "pop")) {
                        if (c.args.len != 0) return self.fail(error.ArgumentCountMismatch, "'pop' hiç argüman almaz", .{});
                        return obj_t.list.*;
                    }
                    return self.fail(error.UndefinedMethod, "list'in '{s}' metodu yok (yalnızca append/sort/pop)", .{a.attr});
                }
                const class_name = switch (obj_t) {
                    .class => |n| n,
                    else => return self.fail(error.TypeMismatch, "metod çağrısı yalnızca sınıf örneklerinde geçerlidir", .{}),
                };
                const info = self.classes.getPtr(class_name) orelse
                    return self.fail(error.UndefinedClass, "bilinmeyen sınıf: {s}", .{class_name});
                if (info.methods.get(a.attr)) |sig| {
                    try self.checkArgs(ctx, sig.params, c.args, a.attr);
                    return sig.return_type;
                }
                // Faz U.4.5: `a.attr` bir METOD DEĞİLSE (method İSİM
                // ÇAKIŞMASINDA HER ZAMAN ÖNCELİKLİDİR — bir sınıf ZATEN
                // aynı isimde hem method hem alan TANIMLAYAMADIĞINDAN bu
                // sıralama BELİRSİZLİK YARATMAZ), func-tipli bir ALAN
                // OLABİLİR (`stdlib/nox/router.nox`nin `route.handler(ctx)`
                // deseni — bkz. `Value.func_sig`in belge notu) — DOLAYLI
                // bir çağrıdır, `ctx.scope.lookup`nin `.func` işleme
                // BLOĞUYLA (aşağısı) AYNI mantık.
                if (info.fields.get(a.attr)) |ft| {
                    if (ft == .func) {
                        try self.checkArgs(ctx, ft.func.params, c.args, a.attr);
                        return ft.func.return_type.*;
                    }
                    return self.fail(error.TypeMismatch, "'{s}' bir fonksiyon değildir, çağrılamaz", .{a.attr});
                }
                return self.fail(error.UndefinedMethod, "'{s}' sınıfının '{s}' metodu yok", .{ class_name, a.attr });
            },
            // Faz U.4.5: `xs[i](...)` — `xs`nin ELEMAN tipi `.func` İSE
            // (`list[(T)->U]`, bkz. `stdlib/nox/router.nox`nin `self.
            // before[j](ctx)` deseni) bu bir DOLAYLI çağrıdır, `ctx.scope.
            // lookup`nin `.func` işleme BLOĞUYLA (yukarısı, ~satır 2316)
            // AYNI mantık.
            .index => |idx| {
                const obj_t = try self.checkExpr(ctx, idx.obj.*);
                try self.requireNotOptional(obj_t, "[]");
                if (obj_t != .list) return self.fail(error.NotCallable, "bu ifade çağrılabilir değil", .{});
                const idx_t = try self.checkExpr(ctx, idx.index.*);
                if (idx_t != .int) return self.fail(error.TypeMismatch, "liste indeksi 'int' olmalıdır", .{});
                const elem_t = obj_t.list.*;
                if (elem_t != .func) return self.fail(error.NotCallable, "bu ifade çağrılabilir değil", .{});
                try self.checkArgs(ctx, elem_t.func.params, c.args, "<liste elemanı>");
                return elem_t.func.return_type.*;
            },
            else => return self.fail(error.NotCallable, "bu ifade çağrılabilir değil", .{}),
        }
    }

    fn checkArgs(self: *Checker, ctx: *FnCtx, params: []const Type, args: []const ast.Expr, name: []const u8) TypeError!void {
        if (params.len != args.len) {
            return self.fail(error.ArgumentCountMismatch, "'{s}' {d} argüman bekler, {d} verildi", .{ name, params.len, args.len });
        }
        for (params, args, 0..) |pt, ae, i| {
            const at = try self.checkExprExpected(ctx, ae, pt);
            if (!self.assignable(pt, at)) {
                // Gerçek span sistemi (bkz. plan dosyası "Gerçek span
                // sistemi + yapılandırılmış tanılamalar"): mümkünse
                // `recordDiagnostic`nin (BU hata YUKARI doğru YAYILDIKTAN
                // SONRA, en üst-düzey çağıranda) OKUYACAĞI `current_span`ı
                // DEYİM-seviyesinden BU SPESİFİK argümana DARALT — BURADA
                // GERİ YÜKLEME YAPILMAZ (bir `defer` İLE DEĞİL): bu bir
                // HATA yoludur, işlev BURADAN itibaren SARILMADAN yukarı
                // doğru YAYILIR, `current_span` bir SONRAKİ deyim/birim
                // işlenirken (`checkStmt`/`checkModule`nin KENDİ normal
                // `current_span = stmt.span` atamasıyla) zaten TAZELENİR.
                // `module_expr_spans` yalnızca SIRADAN çağrı argümanları
                // İçin doldurulur (bkz. `parser.zig`nin `parsePostfix`i),
                // bu YÜZDEN BULUNAMAZSA (stdlib yeniden-adlandırma/generic
                // somutlaştırma SONRASI kopyalanan gövdeler DAHİL — bkz.
                // `ast.Module.expr_spans`nin belge notu) deyim-seviyesi
                // span'a ZARARSIZCA GERİ DÜŞÜLÜR.
                if (self.module_expr_spans.get(@intFromPtr(&args[i]))) |sp| self.current_span = sp;
                return self.fail(error.TypeMismatch, "'{s}' argümanı için tip uyuşmazlığı", .{name});
            }
        }
    }

    // ---- Faz 10: generics (compile-time monomorphization) ----
    //
    // Strateji: bir çağrı sitesinde bir generic fonksiyona rastlanınca,
    // argüman ifadeleri normal şekilde denetlenip somut tipleri elde edilir;
    // bu somut tipler, generic fonksiyonun parametre tip ifadeleriyle
    // (`unifyTypeExpr`) eşleştirilerek her tip parametresi için bir bağlama
    // çözülür. Bu bağlama, generic FuncDef'in DERİN BİR KOPYASINI üretmek
    // için kullanılır (`substituteTypeExpr`/`substituteStmts`) — yalnızca
    // TİP İFADELERİ (parametre/dönüş/`var_decl` tipleri) değiştirilir,
    // ifadelerin kendisi (hesaplama) OLDUĞU GİBİ paylaşılır. Sonuç, adı
    // mangle edilmiş (`mangleName`), tamamen SIRADAN (generic olmayan) bir
    // `ast.FuncDef`dir — normal `registerFunc`/`checkFunctionBody` ile
    // kaydedilip denetlenir ve `self.instantiations`e eklenir (main.zig/
    // codegen bunu modülün geri kalanıymış gibi derler). Çağrı sitesindeki
    // `callee` düğümü bu mangled isme YERİNDE (in-place) yeniden yazılır —
    // bu yüzden ownership analizi ve codegen generics'ten TAMAMEN
    // habersizdir, yalnızca sıradan, somut fonksiyonlar görürler.
    //
    // Bilinçli kapsam sınırlamaları (v0.1): yalnızca serbest fonksiyonlar
    // (metod/sınıf generic'i yok); tip parametreleri yalnızca argüman
    // tiplerinden çıkarılır (dönüş tipinden/açık tip argümanından ["turbofish"]
    // çıkarım yok — Nox'ta böyle bir çağrı sözdizimi henüz yok); yapısal
    // protokoller ve heterojen (fat-pointer) fallback henüz yok (AGENTS.md
    // §12'nin geri kalanı) — bkz. nox-teknik-spesifikasyon.md §3.10.

    fn isTypeParam(name: []const u8, type_params: []const []const u8) bool {
        for (type_params) |tp| {
            if (std.mem.eql(u8, tp, name)) return true;
        }
        return false;
    }

    /// `te` (tip parametresi adları içerebilir) ile `actual` (somut, çağrı
    /// sitesinden gelen) tipi eşleştirir; her tip parametresi karşılaşıldığı
    /// İLK yerde `bindings`e yazılır, SONRAKİ karşılaşmalarda ise ÇELİŞKİ
    /// olup olmadığı denetlenir (ör. `def pair(a: T, b: T)` çağrısında `a`
    /// ve `b` farklı somut tiplerdeyse hata).
    fn unifyTypeExpr(
        self: *Checker,
        te: ast.TypeExpr,
        actual: Type,
        type_params: []const []const u8,
        bindings: *std.StringHashMapUnmanaged(Type),
        fn_name: []const u8,
    ) TypeError!void {
        switch (te) {
            .simple => |name| {
                if (isTypeParam(name, type_params)) {
                    if (bindings.get(name)) |existing| {
                        if (!types.eql(existing, actual)) {
                            return self.fail(error.TypeMismatch, "'{s}' çağrısında tip parametresi '{s}' çelişkili tiplere çözümlendi", .{ fn_name, name });
                        }
                    } else {
                        // `name` bir protokolse, İLK bağlama anında somut
                        // tipin onu yapısal olarak karşıladığı doğrulanır
                        // (bkz. `satisfiesProtocol`) — düz bir tip
                        // parametresi (`[T]`) için böyle bir kısıtlama yoktur.
                        if (self.protocols.contains(name)) {
                            try self.satisfiesProtocol(actual, name, fn_name);
                        }
                        try bindings.put(self.allocator, name, actual);
                    }
                    return;
                }
                const declared = try self.typeExprToType(te);
                if (!self.assignable(declared, actual)) {
                    return self.fail(error.TypeMismatch, "'{s}' argümanı için tip uyuşmazlığı", .{fn_name});
                }
            },
            .generic => |g| {
                if (!std.mem.eql(u8, g.name, "list") or g.args.len != 1) {
                    return self.fail(error.UnknownType, "bilinmeyen generic tip: {s}", .{g.name});
                }
                switch (actual) {
                    .list => |elem| try self.unifyTypeExpr(g.args[0], elem.*, type_params, bindings, fn_name),
                    else => return self.fail(error.TypeMismatch, "'{s}' argümanı için tip uyuşmazlığı", .{fn_name}),
                }
            },
            // Faz U.4.1: generic fonksiyonlarda fonksiyon-tipi parametreler
            // v1 kapsamı DIŞI (closure'lar generics'in monomorphization
            // makinesiyle henüz entegre edilmedi).
            .func_type => return self.fail(error.UnknownType, "'{s}' çağrısında fonksiyon tipi parametreler generic fonksiyonlarda henüz desteklenmiyor", .{fn_name}),
            // Faz FF.6: `T | None`li bir parametre generic bir fonksiyona
            // geçirilirse, `actual`ın da bir Optional olması VE payload'ların
            // özyinelemeli olarak birleşmesi gerekir (v1 kapsamı — Optional
            // İÇİNDEKİ tip parametrelerinin bağlanmasını destekler, örn.
            // `def f[T](x: T | None) -> T`).
            .optional => |inner_te| {
                switch (actual) {
                    .optional => |elem| try self.unifyTypeExpr(inner_te.*, elem.*, type_params, bindings, fn_name),
                    else => return self.fail(error.TypeMismatch, "'{s}' argümanı için tip uyuşmazlığı", .{fn_name}),
                }
            },
            // Nitelikli (`pkg.module.X`) bir tip adı ASLA bir tip
            // parametresi OLAMAZ (`[T]` sözdizimi HER ZAMAN çıplak bir
            // isim) — `.simple`in tip-parametresi OLMAYAN dalıyla AYNI:
            // doğrudan somut tipe çöz VE `assignable` İLE karşılaştır.
            .qualified => {
                const declared = try self.typeExprToType(te);
                if (!self.assignable(declared, actual)) {
                    return self.fail(error.TypeMismatch, "'{s}' argümanı için tip uyuşmazlığı", .{fn_name});
                }
            },
        }
    }

    /// `actual`in `protocol_name` protokolünü YAPISAL olarak karşılayıp
    /// karşılamadığını doğrular: `actual` bir sınıf örneği olmalı VE o
    /// sınıf, protokolün gerektirdiği HER metodu (aynı isim, aynı parametre
    /// tipleri, aynı dönüş tipi — `self` hariç) taşımalıdır. Hiçbir
    /// `implements`/açık ilişki bildirimi ARANMAZ (bkz. AGENTS.md §12).
    fn satisfiesProtocol(self: *Checker, actual: Type, protocol_name: []const u8, fn_name: []const u8) TypeError!void {
        const class_name = switch (actual) {
            .class => |n| n,
            else => return self.fail(
                error.TypeMismatch,
                "'{s}' çağrısında '{s}' yalnızca sınıf örnekleriyle eşleşebilir",
                .{ fn_name, protocol_name },
            ),
        };
        const proto = self.protocols.get(protocol_name).?;
        const cinfo = self.classes.getPtr(class_name).?;
        for (proto.methods) |pm| {
            const cm = cinfo.methods.get(pm.name) orelse return self.fail(
                error.TypeMismatch,
                "'{s}' sınıfı '{s}' protokolünü karşılamıyor: '{s}' metodu eksik",
                .{ class_name, protocol_name, pm.name },
            );
            if (cm.params.len != pm.params.len) {
                return self.fail(
                    error.TypeMismatch,
                    "'{s}' sınıfının '{s}' metodu '{s}' protokolüyle uyuşmuyor (parametre sayısı)",
                    .{ class_name, pm.name, protocol_name },
                );
            }
            for (cm.params, pm.params) |ct, pt| {
                if (!types.eql(ct, pt)) {
                    return self.fail(
                        error.TypeMismatch,
                        "'{s}' sınıfının '{s}' metodu '{s}' protokolüyle uyuşmuyor (parametre tipi)",
                        .{ class_name, pm.name, protocol_name },
                    );
                }
            }
            if (!types.eql(cm.return_type, pm.return_type)) {
                return self.fail(
                    error.TypeMismatch,
                    "'{s}' sınıfının '{s}' metodu '{s}' protokolüyle uyuşmuyor (dönüş tipi)",
                    .{ class_name, pm.name, protocol_name },
                );
            }
        }
    }

    /// Somut bir `Type`i, kaynak sözdizimindeki karşılığı olan bir
    /// `TypeExpr`e çevirir — `substituteTypeExpr`'in bir tip parametresini
    /// somut hâliyle DEĞİŞTİRMEK için kullandığı ters yön.
    fn typeToTypeExpr(self: *Checker, t: Type) TypeError!ast.TypeExpr {
        return switch (t) {
            .int => .{ .simple = "int" },
            .float => .{ .simple = "float" },
            .boolean => .{ .simple = "bool" },
            .str => .{ .simple = "str" },
            .none => .{ .simple = "None" },
            .ptr => .{ .simple = "ptr" },
            .class => |n| .{ .simple = n },
            .list => |elem| blk: {
                const args = try self.allocator.alloc(ast.TypeExpr, 1);
                args[0] = try self.typeToTypeExpr(elem.*);
                break :blk .{ .generic = .{ .name = "list", .args = args } };
            },
            .task => |elem| blk: {
                const args = try self.allocator.alloc(ast.TypeExpr, 1);
                args[0] = try self.typeToTypeExpr(elem.*);
                break :blk .{ .generic = .{ .name = "Task", .args = args } };
            },
            .channel => |elem| blk: {
                const args = try self.allocator.alloc(ast.TypeExpr, 1);
                args[0] = try self.typeToTypeExpr(elem.*);
                break :blk .{ .generic = .{ .name = "Channel", .args = args } };
            },
            .thread_handle => |elem| blk: {
                const args = try self.allocator.alloc(ast.TypeExpr, 1);
                args[0] = try self.typeToTypeExpr(elem.*);
                break :blk .{ .generic = .{ .name = "ThreadHandle", .args = args } };
            },
            .thread_channel => |elem| blk: {
                const args = try self.allocator.alloc(ast.TypeExpr, 1);
                args[0] = try self.typeToTypeExpr(elem.*);
                break :blk .{ .generic = .{ .name = "ThreadChannel", .args = args } };
            },
            .task_local => |elem| blk: {
                const args = try self.allocator.alloc(ast.TypeExpr, 1);
                args[0] = try self.typeToTypeExpr(elem.*);
                break :blk .{ .generic = .{ .name = "TaskLocal", .args = args } };
            },
            .dict => |d| blk: {
                const args = try self.allocator.alloc(ast.TypeExpr, 2);
                args[0] = try self.typeToTypeExpr(d.key.*);
                args[1] = try self.typeToTypeExpr(d.value.*);
                break :blk .{ .generic = .{ .name = "dict", .args = args } };
            },
            // Faz U.4.1: generics'in bu ters-çevirme yolu (somut örnekleme
            // sentezi) closure'lar İÇİN henüz kullanılmıyor (bkz.
            // `unifyTypeExpr`in AYNI kısıtı) — yine de HİÇBİR generic
            // fonksiyon func-tipi bir tip parametresine BAĞLANAMAYACAĞINDAN
            // (yukarısı), bu dal PRATİKTE HİÇ tetiklenmez; yalnızca
            // exhaustive switch GEREKSİNİMİNİ karşılamak için var.
            .func => |f| blk: {
                const params = try self.allocator.alloc(ast.TypeExpr, f.params.len);
                for (f.params, 0..) |p, i| params[i] = try self.typeToTypeExpr(p);
                const ret = try self.allocator.create(ast.TypeExpr);
                ret.* = try self.typeToTypeExpr(f.return_type.*);
                break :blk .{ .func_type = .{ .params = params, .return_type = ret } };
            },
            .optional => |elem| blk: {
                const boxed = try self.allocator.create(ast.TypeExpr);
                boxed.* = try self.typeToTypeExpr(elem.*);
                break :blk .{ .optional = boxed };
            },
        };
    }

    fn substituteTypeExpr(self: *Checker, te: ast.TypeExpr, bindings: *const std.StringHashMapUnmanaged(Type)) TypeError!ast.TypeExpr {
        return switch (te) {
            .simple => |name| if (bindings.get(name)) |t| try self.typeToTypeExpr(t) else te,
            .generic => |g| blk: {
                const args = try self.allocator.alloc(ast.TypeExpr, g.args.len);
                for (g.args, 0..) |a, i| args[i] = try self.substituteTypeExpr(a, bindings);
                break :blk .{ .generic = .{ .name = g.name, .args = args } };
            },
            .func_type => |ft| blk: {
                const params = try self.allocator.alloc(ast.TypeExpr, ft.params.len);
                for (ft.params, 0..) |p, i| params[i] = try self.substituteTypeExpr(p, bindings);
                const ret = try self.allocator.create(ast.TypeExpr);
                ret.* = try self.substituteTypeExpr(ft.return_type.*, bindings);
                break :blk .{ .func_type = .{ .params = params, .return_type = ret } };
            },
            .optional => |inner| blk: {
                const boxed = try self.allocator.create(ast.TypeExpr);
                boxed.* = try self.substituteTypeExpr(inner.*, bindings);
                break :blk .{ .optional = boxed };
            },
            // Nitelikli (`pkg.module.X`) bir tip adı ASLA bir tip
            // parametresi (`bindings`in anahtarları HER ZAMAN çıplak
            // isimlerdir) OLAMAZ — değiştirilecek bir şey yok.
            .qualified => te,
        };
    }

    /// Bir gövdeyi (`[]Stmt`) derin kopyalar; yalnızca `var_decl.type_expr`
    /// tip parametresi içerebilir (parametre/dönüş tipleri ayrıca ele alınır)
    /// — ifadelerin kendisi (hesaplama, `Expr` ağaçları) hiç değişmediği için
    /// olduğu gibi paylaşılır. İç içe bloklar (if/while/for/try/lowlevel)
    /// özyinelemeli olarak yeniden inşa edilir.
    fn substituteStmts(self: *Checker, stmts: []const ast.Stmt, bindings: *const std.StringHashMapUnmanaged(Type)) TypeError![]ast.Stmt {
        const out = try self.allocator.alloc(ast.Stmt, stmts.len);
        for (stmts, 0..) |s, i| out[i] = try self.substituteStmt(s, bindings);
        return out;
    }

    fn substituteStmt(self: *Checker, s: ast.Stmt, bindings: *const std.StringHashMapUnmanaged(Type)) TypeError!ast.Stmt {
        // Faz T.1: `s`nin ORİJİNAL satırı (bkz. `ast.Stmt`in belge notu)
        // yeni sentezlenen deyime AYNEN taşınır — bu, generic örneklemesinin
        // (Faz 10) ÜRETTİĞİ deyimlerin de doğru bir kaynak konumu taşımasını
        // sağlar (`s` DEĞİŞMEDEN döndürüldüğü `else` dalı zaten otomatik).
        const kind: ast.StmtKind = switch (s.kind) {
            .var_decl => |v| .{ .var_decl = .{
                .name = v.name,
                .type_expr = try self.substituteTypeExpr(v.type_expr, bindings),
                .value = v.value,
            } },
            .if_stmt => |f| blk: {
                const elifs = try self.allocator.alloc(ast.ElifClause, f.elif_clauses.len);
                for (f.elif_clauses, 0..) |ec, i| {
                    elifs[i] = .{ .cond = ec.cond, .body = try self.substituteStmts(ec.body, bindings) };
                }
                break :blk .{ .if_stmt = .{
                    .cond = f.cond,
                    .then_body = try self.substituteStmts(f.then_body, bindings),
                    .elif_clauses = elifs,
                    .else_body = if (f.else_body) |eb| try self.substituteStmts(eb, bindings) else null,
                } };
            },
            .while_stmt => |w| .{ .while_stmt = .{ .cond = w.cond, .body = try self.substituteStmts(w.body, bindings) } },
            .for_stmt => |f| .{ .for_stmt = .{ .var_name = f.var_name, .iterable = f.iterable, .body = try self.substituteStmts(f.body, bindings) } },
            .try_stmt => |t| blk: {
                const ecs = try self.allocator.alloc(ast.ExceptClause, t.except_clauses.len);
                for (t.except_clauses, 0..) |ec, i| {
                    ecs[i] = .{ .class_name = ec.class_name, .bind_name = ec.bind_name, .body = try self.substituteStmts(ec.body, bindings) };
                }
                break :blk .{ .try_stmt = .{
                    .try_body = try self.substituteStmts(t.try_body, bindings),
                    .except_clauses = ecs,
                    .finally_body = if (t.finally_body) |fb| try self.substituteStmts(fb, bindings) else null,
                } };
            },
            .lowlevel_stmt => |ll| .{ .lowlevel_stmt = .{ .body = try self.substituteStmts(ll.body, bindings) } },
            .with_stmt => |w| .{ .with_stmt = .{
                .ctx_expr = w.ctx_expr,
                .binding = w.binding,
                .body = try self.substituteStmts(w.body, bindings),
            } },
            // expr_stmt/assign/return_stmt/raise_stmt/pass_stmt hiç TypeExpr
            // içermez; func_def/class_def bir fonksiyon gövdesi içinde zaten
            // reddedilir (bkz. checkStmt) — bu yüzden buraya hiç ulaşmazlar.
            else => return s,
        };
        return .{ .kind = kind, .line = s.line };
    }

    fn mangleName(self: *Checker, base: []const u8, bound_types: []const Type) TypeError![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        try buf.appendSlice(self.allocator, base);
        try buf.appendSlice(self.allocator, "__");
        for (bound_types, 0..) |t, i| {
            if (i != 0) try buf.appendSlice(self.allocator, "_");
            try self.appendMangledType(&buf, t);
        }
        return buf.toOwnedSlice(self.allocator);
    }

    fn appendMangledType(self: *Checker, buf: *std.ArrayListUnmanaged(u8), t: Type) TypeError!void {
        switch (t) {
            .int => try buf.appendSlice(self.allocator, "int"),
            .float => try buf.appendSlice(self.allocator, "float"),
            .boolean => try buf.appendSlice(self.allocator, "bool"),
            .str => try buf.appendSlice(self.allocator, "str"),
            .none => try buf.appendSlice(self.allocator, "None"),
            .ptr => try buf.appendSlice(self.allocator, "ptr"),
            .class => |n| try buf.appendSlice(self.allocator, n),
            .list => |elem| {
                try buf.appendSlice(self.allocator, "list_");
                try self.appendMangledType(buf, elem.*);
            },
            .task => |elem| {
                try buf.appendSlice(self.allocator, "Task_");
                try self.appendMangledType(buf, elem.*);
            },
            .channel => |elem| {
                try buf.appendSlice(self.allocator, "Channel_");
                try self.appendMangledType(buf, elem.*);
            },
            .thread_handle => |elem| {
                try buf.appendSlice(self.allocator, "ThreadHandle_");
                try self.appendMangledType(buf, elem.*);
            },
            .thread_channel => |elem| {
                try buf.appendSlice(self.allocator, "ThreadChannel_");
                try self.appendMangledType(buf, elem.*);
            },
            .task_local => |elem| {
                try buf.appendSlice(self.allocator, "TaskLocal_");
                try self.appendMangledType(buf, elem.*);
            },
            .dict => |d| {
                try buf.appendSlice(self.allocator, "dict_");
                try self.appendMangledType(buf, d.key.*);
                try buf.appendSlice(self.allocator, "_");
                try self.appendMangledType(buf, d.value.*);
            },
            // Faz U.4.1: `unifyTypeExpr`in AYNI kısıtı gereği bir generic
            // fonksiyon HİÇBİR ZAMAN func-tipi bir tip parametresine
            // BAĞLANAMAZ — bu dal PRATİKTE tetiklenmez, yalnızca exhaustive
            // switch GEREKSİNİMİNİ karşılar.
            .func => |f| {
                try buf.appendSlice(self.allocator, "func_");
                for (f.params) |p| {
                    try self.appendMangledType(buf, p);
                    try buf.appendSlice(self.allocator, "_");
                }
                try self.appendMangledType(buf, f.return_type.*);
            },
            .optional => |elem| {
                try buf.appendSlice(self.allocator, "Optional_");
                try self.appendMangledType(buf, elem.*);
            },
        }
    }

    /// Bir generic fonksiyon çağrısını (`gfd`) somutlaştırır: argümanları
    /// denetler, tip parametrelerini çıkarır, (önbellekte yoksa) somut bir
    /// `FuncDef` sentezleyip kaydeder/denetler ve çağrı sitesinin `callee`
    /// düğümünü YERİNDE mangled isme yeniden yazar. Döndürülen `Type`, bu
    /// çağrı ifadesinin (`c`) kendi tipidir.
    /// Faz P2.1 (bkz. proje belleği "generic sınıflar" planı): `instantiateGeneric`
    /// (FONKSİYONLAR İçin) İLE AYNI iskelet, SINIFLAR İçin — TEK önemli fark:
    /// tip parametreleri `unifyTypeExpr` İLE ARGÜMAN tiplerinden ÇIKARILMAZ,
    /// DOĞRUDAN (çağıranın ZATEN çözdüğü) `bound_types`ten ALINIR. Bu, hem
    /// `checkGenericConstruct`nin (bir `Box[int](5)` kurucu çağrısı, `g.
    /// type_args`ten) hem `typeExprToType`nin `.generic` dalının (bir kurucu
    /// çağrısı HİÇ görülmeden — ör. bir alan/parametre tipi olarak `Box[int]`
    /// — `g.args`ten) ORTAK çağırma noktasıdır. Metodları generic bir
    /// sınıfın KENDİ tip parametresini (`self.value: T`) kullanabilir — bu
    /// "generic METODLAR" (`def foo[U](...)`, checker.zig'in AYRI, HÂLÂ
    /// geçerli "metodlar generic olamaz" reddi) İLE KARIŞTIRILMAMALIDIR:
    /// burada `T` DIŞARIDAN (sınıf düzeyinde) bağlanan bir isimdir, metodun
    /// KENDİ `type_params`ı HER ZAMAN boş kalır.
    ///
    /// **Bilinen, DEVREDEN sınırlama (`substituteStmt`nin belge notuyla AYNI):**
    /// yalnızca `var_decl.type_expr` değiştirilir — bir metodun GÖVDESİ
    /// KENDİ `T`sini kullanan BAŞKA bir generic kurucu (`Channel[T](...)`
    /// gibi) çağırırsa, o iç `.generic_construct.type_args`i BURADA
    /// YÜRÜNMEDİĞİNDEN `T` somutlaştırma ANINDA çözülemez ve tip hatası
    /// verir. Bu, generic FONKSİYONLARDAN miras kalan bir kısıttır (bu
    /// biletin KAPSAMI DIŞINDA — `substituteStmt`i TÜM ifade-gömülü
    /// `TypeExpr` sitelerini gezecek şekilde genişletmek çok daha büyük,
    /// ayrı bir değişiklik olurdu).
    fn instantiateGenericClass(self: *Checker, gcd: ast.ClassDef, bound_types: []const Type) TypeError!Type {
        if (bound_types.len != gcd.type_params.len) {
            return self.fail(error.ArgumentCountMismatch, "'{s}' {d} tip argümanı bekler, {d} verildi", .{ gcd.name, gcd.type_params.len, bound_types.len });
        }

        const mangled = try self.mangleName(gcd.name, bound_types);
        if (self.classes.contains(mangled)) return .{ .class = mangled };

        var bindings: std.StringHashMapUnmanaged(Type) = .{};
        defer bindings.deinit(self.allocator);
        for (gcd.type_params, bound_types) |tp, t| try bindings.put(self.allocator, tp, t);
        // Fonksiyonların AKSİNE, sınıfa ÖZGÜ bir adım: sınıfın KENDİ çıplak
        // adını da somut (mangled) tipe bağlar — `self: Box` (parser'ın HER
        // metod İçin sentezlediği `self_inferred` parametre) VE öz-başvurulu
        // alan/dönüş tipleri (`next: Box | None`) AYNI `substituteTypeExpr`
        // yürüyüşüyle "ücretsiz" doğru çözülsün diye.
        try bindings.put(self.allocator, gcd.name, .{ .class = mangled });

        const fields = try self.allocator.alloc(ast.FieldDecl, gcd.fields.len);
        for (gcd.fields, 0..) |f, i| {
            fields[i] = .{ .name = f.name, .type_expr = try self.substituteTypeExpr(f.type_expr, &bindings), .line = f.line };
        }
        const methods = try self.allocator.alloc(ast.FuncDef, gcd.methods.len);
        for (gcd.methods, 0..) |m, i| {
            const params = try self.allocator.alloc(ast.Param, m.params.len);
            for (m.params, 0..) |p, j| {
                params[j] = .{ .name = p.name, .type_expr = try self.substituteTypeExpr(p.type_expr, &bindings), .self_inferred = p.self_inferred };
            }
            methods[i] = .{
                .name = m.name,
                .type_params = &.{},
                .params = params,
                .return_type = try self.substituteTypeExpr(m.return_type, &bindings),
                .body = try self.substituteStmts(m.body, &bindings),
                .is_async = m.is_async,
            };
        }
        const concrete: ast.ClassDef = .{ .name = mangled, .type_params = &.{}, .methods = methods, .fields = fields };

        // Önce yer tutucuyu kaydet (olası öz-başvurulu/özyinelemeli generic
        // sınıflar AYNI somutlaştırmayı YENİDEN bulsun diye — `instantiateGeneric`in
        // AYNI yorumuyla TUTARLI), SONRA gövdeyi denetle.
        try self.classes.put(self.allocator, mangled, .{});
        try self.registerClassSignatures(concrete);
        try self.class_instantiations.append(self.allocator, concrete);
        try self.checkClassBody(concrete);
        return .{ .class = mangled };
    }

    fn instantiateGeneric(self: *Checker, ctx: *FnCtx, gfd: ast.FuncDef, c: ast.Call) TypeError!Type {
        if (gfd.params.len != c.args.len) {
            return self.fail(error.ArgumentCountMismatch, "'{s}' {d} argüman bekler, {d} verildi", .{ gfd.name, gfd.params.len, c.args.len });
        }

        var bindings: std.StringHashMapUnmanaged(Type) = .{};
        defer bindings.deinit(self.allocator);
        for (gfd.params, c.args) |p, arg| {
            const at = try self.checkExpr(ctx, arg);
            try self.unifyTypeExpr(p.type_expr, at, gfd.type_params, &bindings, gfd.name);
        }

        const bound_types = try self.allocator.alloc(Type, gfd.type_params.len);
        for (gfd.type_params, 0..) |tp, i| {
            bound_types[i] = bindings.get(tp) orelse return self.fail(
                error.TypeMismatch,
                "'{s}' için tip parametresi '{s}' çıkarılamadı (yalnızca argüman tiplerinden çıkarım destekleniyor)",
                .{ gfd.name, tp },
            );
        }

        const mangled = try self.mangleName(gfd.name, bound_types);
        if (self.functions.get(mangled)) |sig| {
            c.callee.* = .{ .identifier = mangled };
            return sig.return_type;
        }

        const params = try self.allocator.alloc(ast.Param, gfd.params.len);
        for (gfd.params, 0..) |p, i| {
            params[i] = .{ .name = p.name, .type_expr = try self.substituteTypeExpr(p.type_expr, &bindings) };
        }
        const concrete: ast.FuncDef = .{
            .name = mangled,
            .type_params = &.{},
            .params = params,
            .return_type = try self.substituteTypeExpr(gfd.return_type, &bindings),
            .body = try self.substituteStmts(gfd.body, &bindings),
        };

        // Önce imzayı kaydet (olası özyinelemeli çağrılar aynı somutlaştırmayı
        // yeniden bulsun diye), SONRA gövdeyi denetle — `registerFunc`/
        // `checkFunctionBody`'nin normal, generic-olmayan sırasıyla aynı.
        try self.registerFunc(concrete);
        try self.instantiations.append(self.allocator, concrete);
        try self.checkFunctionBody(concrete);

        c.callee.* = .{ .identifier = mangled };
        return self.functions.get(mangled).?.return_type;
    }
};

pub const CheckOutcome = union(enum) {
    ok,
    err: struct { code: TypeError, message: []const u8, all: []const Diagnostic },
};

/// Bir modülü tipçe denetler. Hatayı ve tanılama mesajını `CheckOutcome` olarak döner.
///
/// Faz T.2: `checkModule` artık ÇOĞU (fonksiyon/sınıf/metod/gevşek deyim
/// SINIRINDAKİ) hatada FIRLATMAZ — bunun yerine `checker.diagnostics`e
/// KAYDEDİP DEVAM eder (bkz. `recordDiagnostic`). Bu yüzden `checkModule`
/// BAŞARIYLA (hatasız) DÖNSE BİLE `checker.diagnostics` DOLU olabilir —
/// `err`, `code`/`message` alanlarında İLK tanılamayı (geriye dönük uyumluluk
/// İÇİN, `all` alanı EKLENMEDEN ÖNCEKİ tek-hata tüketicileriyle AYNI biçimde),
/// `all` alanında İSE TÜM (kurtarılmış + varsa fırlatılmış) tanılamaları taşır.
pub fn check(allocator: std.mem.Allocator, module: ast.Module) CheckOutcome {
    var checker = Checker.init(allocator);
    checker.checkModule(module) catch |e| {
        return .{ .err = .{
            .code = e,
            .message = checker.diagnostic orelse "(mesaj yok)",
            .all = checker.diagnostics.items,
        } };
    };
    if (checker.diagnostics.items.len > 0) {
        const first = checker.diagnostics.items[0];
        return .{ .err = .{ .code = first.code, .message = first.message, .all = checker.diagnostics.items } };
    }
    return .ok;
}
