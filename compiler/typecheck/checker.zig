//! Nox v0.1 zorunlu statik tip denetleyicisi (AGENTS.md §5, §7 adım 2).
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
};

const FuncSig = struct {
    params: []const Type,
    return_type: Type,
};

const ClassInfo = struct {
    fields: std.StringHashMapUnmanaged(Type) = .{},
    methods: std.StringHashMapUnmanaged(FuncSig) = .{},
    init_sig: ?FuncSig = null,
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

    fn declare(self: *Scope, allocator: std.mem.Allocator, name: []const u8, ty: Type) !void {
        try self.vars.put(allocator, name, ty);
    }

    fn lookup(self: *Scope, name: []const u8) ?Type {
        return self.vars.get(name);
    }
};

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
    /// Generic (`type_params.len > 0`) serbest fonksiyonlar — ham AST'leri,
    /// somut bir çağrı sitesiyle karşılaşılana kadar burada beklerler (bkz.
    /// Faz 10, `instantiateGeneric`). Gövdeleri normal geçişte DENETLENMEZ.
    generic_functions: std.StringHashMapUnmanaged(ast.FuncDef) = .{},
    /// `async def` olarak tanımlanmış serbest fonksiyon adları — yalnızca
    /// bunlar `spawn` ile başlatılabilir (bkz. `checkExpr`in `.spawn_expr`
    /// dalı, nox-teknik-spesifikasyon.md §3.21).
    async_functions: std.StringHashMapUnmanaged(void) = .{},
    /// `instantiateGeneric` tarafından üretilen, somut (monomorphize edilmiş)
    /// fonksiyon tanımları — `main.zig`/codegen bunları modülün geri kalanı
    /// gibi normal, generic olmayan fonksiyonlar olarak derler. Adları
    /// (`mangleName`) ile önbelleğe alınır: aynı (fonksiyon, somut tip demeti)
    /// çifti için en fazla bir kez sentezlenir.
    instantiations: std.ArrayListUnmanaged(ast.FuncDef) = .empty,
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
    /// Faz T.2: `checkModule`nin üst-düzey döngüsünde (fonksiyon/sınıf/gevşek
    /// deyim SINIRINDA) VE `checkClassBody`nin metod döngüsünde YAKALANIP
    /// KURTARILAN tanılamalar — bkz. modül üstü not. `recordDiagnostic`
    /// tarafından doldurulur, `check()` tarafından `CheckOutcome.err.all`e
    /// kopyalanır.
    diagnostics: std.ArrayListUnmanaged(Diagnostic) = .empty,

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
                return self.fail(error.UnknownType, "bilinmeyen tip: {s}", .{name});
            },
            .generic => |g| {
                if (std.mem.eql(u8, g.name, "list") or std.mem.eql(u8, g.name, "Task") or std.mem.eql(u8, g.name, "Channel")) {
                    if (g.args.len != 1) {
                        return self.fail(error.UnknownType, "'{s}' tam olarak bir tip argümanı alır", .{g.name});
                    }
                    const elem = try self.typeExprToType(g.args[0]);
                    const boxed = try self.allocator.create(Type);
                    boxed.* = elem;
                    if (std.mem.eql(u8, g.name, "list")) return .{ .list = boxed };
                    if (std.mem.eql(u8, g.name, "Task")) return .{ .task = boxed };
                    return .{ .channel = boxed };
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
                    if (value_t != .int and value_t != .float and value_t != .boolean and value_t != .str) {
                        return self.fail(error.UnknownType, "'dict' değer tipi yalnızca int/float/bool/str olabilir (v1 kapsamı)", .{});
                    }
                    const key_boxed = try self.allocator.create(Type);
                    key_boxed.* = key_t;
                    const value_boxed = try self.allocator.create(Type);
                    value_boxed.* = value_t;
                    return .{ .dict = .{ .key = key_boxed, .value = value_boxed } };
                }
                return self.fail(error.UnknownType, "bilinmeyen generic tip: {s}", .{g.name});
            },
        }
    }

    fn assignable(declared: Type, value: Type) bool {
        if (types.eql(declared, value)) return true;
        if (declared == .float and value == .int) return true;
        return false;
    }

    // ---- Geçiş 1: sınıf adlarını topla (ileri referansları desteklemek için) ----

    fn collectClassNames(self: *Checker, module: ast.Module) TypeError!void {
        for (module.body) |stmt| {
            self.current_line = stmt.line;
            if (stmt.kind == .class_def) {
                const name = stmt.kind.class_def.name;
                if (self.classes.contains(name)) {
                    return self.fail(error.DuplicateDefinition, "sınıf zaten tanımlı: {s}", .{name});
                }
                try self.classes.put(self.allocator, name, .{});
            }
        }
    }

    // ---- Geçiş 2: fonksiyon/sınıf imzalarını çözümle ----

    fn registerSignatures(self: *Checker, module: ast.Module) TypeError!void {
        for (module.body) |stmt| {
            self.current_line = stmt.line;
            switch (stmt.kind) {
                .func_def => |fd| try self.registerFunc(fd),
                .class_def => |cd| try self.registerClassSignatures(cd),
                .extern_def => |ed| try self.registerExternFunc(ed),
                else => {},
            }
        }
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
            if (!isFfiSafeType(pt)) {
                return self.fail(error.TypeMismatch, "extern fonksiyon '{s}': parametre '{s}' desteklenmeyen bir tipte (yalnızca int/float/bool/str/None v0.1'de C ABI sınırında geçirilebilir)", .{ ed.name, p.name });
            }
            params[i] = pt;
        }
        const ret = try self.typeExprToType(ed.return_type);
        if (!isFfiSafeType(ret) and !isFfiSafeListReturnType(ret) and !isFfiSafeClassReturnType(ret)) {
            return self.fail(error.TypeMismatch, "extern fonksiyon '{s}': dönüş tipi desteklenmeyen bir tipte (yalnızca int/float/bool/str/None/list[str]/sınıf v0.1'de C ABI sınırında geçirilebilir)", .{ed.name});
        }
        try self.functions.put(self.allocator, ed.name, .{ .params = params, .return_type = ret });
    }

    /// Stdlib fazı §F: `extern def`in DÖNÜŞ tipi olarak (yalnızca dönüş —
    /// PARAMETRE olarak DEĞİL, bkz. yukarıdaki `registerExternFunc`in
    /// parametre döngüsü — o hâlâ SALT `isFfiSafeType` kullanır) `list[str]`
    /// (v1 kapsamı yalnızca bu somut örnekleme) kabul edilir — `dict[str,
    /// str]`in D.1'de aldığı MUAMELENİN AYNISI (bkz. `isFfiSafeType`'ın
    /// `.dict` dalı): çalışma zamanı temsili ZATEN ARC'lı bir `list[T]`
    /// payload'ıdır (8 bayt uzunluk başlığı + `str` işaretçileri, bkz.
    /// `codegen.zig`'in `genListLit`ı) — Zig tarafı bunu `nox_rc_alloc` +
    /// el ile yazılmış AYNI uzunluk başlığıyla DOĞRUDAN inşa edebilir.
    /// PARAMETRE OLARAK izin VERİLMEMESİNİN nedeni: bir Zig fonksiyonunun
    /// ZATEN VAR OLAN bir `list[str]`i TÜKETMESİ İÇİN henüz bir kullanım
    /// örneği/ihtiyaç YOK — v1 kapsamı bilinçli olarak dar tutuldu.
    fn isFfiSafeListReturnType(t: Type) bool {
        return switch (t) {
            .list => |elem| elem.* == .str,
            else => false,
        };
    }

    /// Stdlib fazı §L: `isFfiSafeListReturnType` İLE AYNI "yalnızca DÖNÜŞ,
    /// PARAMETRE değil" ilkesi — bir sınıf tipi (ör. `JsonValue`) `with_rt
    /// extern def`in DÖNÜŞ tipi olarak kabul edilir. Bu GÜVENLİDİR çünkü Zig
    /// tarafı sınıfın HAM baytlarını KENDİSİ inşa ETMEZ (`class_id` derleme
    /// sırasına bağlı olduğundan Zig'den TAHMİN EDİLEMEZ) — bunun yerine
    /// AYNI sınıfın GERÇEK, QBE-derlenmiş bir Nox fabrika fonksiyonunu
    /// (`extern fn` ile, bkz. `runtime/stdlib_shims/json.zig`nin belge notu)
    /// ÇAĞIRIR; dönen değer ZATEN doğru `class_id`/ARC muhasebesiyle
    /// (normal `__init__` yoluyla) inşa edilmiş, sıradan bir işaretçidir —
    /// `extern def`in KENDİSİ yalnızca bu işaretçiyi OLDUĞU GİBİ yukarı
    /// taşır.
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
            .list, .class, .task, .channel => false,
        };
    }

    /// `isFfiSafeType`den AYRI: `spawn`ın kapanış paketlemesi (bkz.
    /// codegen.zig, `genSpawnExpr`) yalnızca sabit boyutlu, ARC-DIŞI
    /// değerleri (int/float/bool/str/None) VE `Task[T]`/`Channel[T]`i
    /// (bunlar da ARC-yönetimli DEĞİLDİR — bkz. `HeapKind`in belge notu,
    /// yalnızca bir işaretçi kopyalamak yeterlidir) paketleyebilir. Sınıf/
    /// `list[T]` parametreleri (paketleme ÖNCESİ retain, çağrı SONRASI
    /// release gerektirirdi) v0.1 kapsamı DIŞI bırakıldı.
    fn isSpawnParamSafeType(t: Type) bool {
        return switch (t) {
            .int, .float, .boolean, .str, .none, .task, .channel, .ptr => true,
            .list, .class, .dict => false,
        };
    }

    fn registerFunc(self: *Checker, fd: ast.FuncDef) TypeError!void {
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
                if (!isSpawnParamSafeType(params[i])) {
                    return self.fail(error.TypeMismatch, "'async def {s}': parametre '{s}' desteklenmeyen bir tipte (v0.1'de spawn kapanışı yalnızca int/float/bool/str/None/Task[T]/Channel[T] parametreleri paketleyebilir)", .{ fd.name, p.name });
                }
            }
        }
        try self.functions.put(self.allocator, fd.name, .{ .params = params, .return_type = ret });
        if (fd.is_async) try self.async_functions.put(self.allocator, fd.name, {});
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
        var segments: std.ArrayListUnmanaged([]const u8) = .empty;
        if (!(try self.flattenDottedPath(c.callee.*, &segments))) return null;
        if (segments.items.len < 2) return null;

        const module_path = try self.joinSegments(segments.items[0 .. segments.items.len - 1], '.');
        if (!self.imported_modules.contains(module_path)) return null;

        const mangled = try self.joinSegments(segments.items, '_');
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
        return self.fail(error.UndefinedFunction, "'{s}' modülünün '{s}' adlı bir üyesi yok", .{ module_path, segments.items[segments.items.len - 1] });
    }

    /// `nox.http.serve(port, handle[, max_connections])` — stdlib fazı
    /// §D.1.6'nın özel yerleşiği (bkz. nox-teknik-spesifikasyon.md §3.34).
    /// `spawn`ın "çıplak isim" çözümüyle (bkz. `.spawn_expr` dalı) AYNI
    /// gerekçeyle: `handle` birinci sınıf bir DEĞER olarak GEÇİRİLEMEZ
    /// (Nox'ta fonksiyonlar değer DEĞİLDİR), bu yüzden normal argüman tipi
    /// denetiminden (`checkArgs`/`checkExpr`) GEÇMEDEN doğrudan bir
    /// fonksiyon ADI olarak doğrulanır — `tryResolveQualifiedCall`DAN ÖNCE
    /// çağrılmalıdır (o, `handle`i SIRADAN bir argüman gibi `checkArgs`a
    /// göndermeye çalışırdı, "tanımsız değişken" hatasıyla BAŞARISIZ olurdu).
    /// Callee TAM OLARAK `nox.http.serve` DEĞİLSE (ya da `nox.http` HİÇ
    /// `import` edilmemişse) `null` döner — çağıran MEVCUT
    /// `tryResolveQualifiedCall`a (`nox.http`in DİĞER üyeleri İÇİN,
    /// DEĞİŞMEMİŞ) devam eder.
    fn tryResolveHttpServeCall(self: *Checker, ctx: *FnCtx, c: ast.Call) TypeError!?Type {
        var segments: std.ArrayListUnmanaged([]const u8) = .empty;
        if (!(try self.flattenDottedPath(c.callee.*, &segments))) return null;
        if (segments.items.len != 3) return null;
        if (!std.mem.eql(u8, segments.items[0], "nox")) return null;
        if (!std.mem.eql(u8, segments.items[1], "http")) return null;
        if (!std.mem.eql(u8, segments.items[2], "serve")) return null;
        if (!self.imported_modules.contains("nox.http")) return null;

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
        const handle_name = switch (c.args[1]) {
            .identifier => |n| n,
            else => return self.fail(error.NotCallable, "'nox.http.serve': 'handle' doğrudan bir fonksiyon adı olmalı (metod/lambda henüz desteklenmiyor)", .{}),
        };
        if (self.async_functions.contains(handle_name)) {
            return self.fail(error.TypeMismatch, "'nox.http.serve': 'handle' ('{s}') bir 'async def' OLAMAZ (bağlantı işleyicisi zaten kendi fiber'ında senkron çalışır)", .{handle_name});
        }
        const sig = self.functions.get(handle_name) orelse
            return self.fail(error.UndefinedFunction, "tanımsız fonksiyon: {s}", .{handle_name});
        if (sig.params.len != 1) {
            return self.fail(error.TypeMismatch, "'nox.http.serve': 'handle' TAM OLARAK bir parametre almalı (bir HttpRequest)", .{});
        }
        const req_class = switch (sig.params[0]) {
            .class => |n| n,
            else => return self.fail(error.TypeMismatch, "'nox.http.serve': 'handle'in parametresi 'HttpRequest' olmalı", .{}),
        };
        if (!std.mem.eql(u8, req_class, "nox_http_HttpRequest")) {
            return self.fail(error.TypeMismatch, "'nox.http.serve': 'handle'in parametresi 'HttpRequest' olmalı", .{});
        }
        const resp_class = switch (sig.return_type) {
            .class => |n| n,
            else => return self.fail(error.TypeMismatch, "'nox.http.serve': 'handle' bir 'HttpResponse' döndürmeli", .{}),
        };
        if (!std.mem.eql(u8, resp_class, "nox_http_HttpResponse")) {
            return self.fail(error.TypeMismatch, "'nox.http.serve': 'handle' bir 'HttpResponse' döndürmeli", .{});
        }
        return .none;
    }

    fn registerClassSignatures(self: *Checker, cd: ast.ClassDef) TypeError!void {
        const info = self.classes.getPtr(cd.name).?; // collectClassNames'de eklendi
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
                try info.methods.put(self.allocator, m.name, sig);
            }
        }
    }

    // ---- Geçiş 3: gövdeleri denetle ----

    pub fn checkModule(self: *Checker, module: ast.Module) TypeError!void {
        try self.collectClassNames(module);
        try self.collectProtocols(module);
        try self.registerSignatures(module);

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
                .class_def => |cd| self.checkClassBody(cd) catch |e| try self.recordDiagnostic(e),
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
                .import_stmt => |imp| {
                    const joined = try self.joinSegments(imp.segments, '.');
                    try self.imported_modules.put(self.allocator, joined, {});
                },
                else => self.checkStmt(&top_ctx, stmt) catch |e| try self.recordDiagnostic(e),
            }
        }
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

    fn checkFunctionBody(self: *Checker, fd: ast.FuncDef) TypeError!void {
        var scope: Scope = .{};
        for (fd.params) |p| {
            const pt = try self.typeExprToType(p.type_expr);
            try scope.declare(self.allocator, p.name, pt);
        }
        const ret = try self.typeExprToType(fd.return_type);
        var ctx: FnCtx = .{ .scope = &scope, .expected_return = ret, .in_async = fd.is_async };
        for (fd.body) |s| try self.checkStmt(&ctx, s);
        if (ret != .none and !alwaysReturns(fd.body)) {
            return self.fail(error.MissingReturn, "fonksiyon '{s}' tüm yollarda değer döndürmüyor", .{fd.name});
        }
    }

    fn checkClassBody(self: *Checker, cd: ast.ClassDef) TypeError!void {
        for (cd.methods) |m| {
            if (std.mem.eql(u8, m.name, "__init__"))
                self.checkMethodBody(cd.name, m, true) catch |e| try self.recordDiagnostic(e);
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
        var ctx: FnCtx = .{ .scope = &scope, .expected_return = ret, .self_class = class_name, .is_init = is_init };
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
        switch (stmt.kind) {
            .expr_stmt => |e| _ = try self.checkExpr(ctx, e),
            .var_decl => |v| {
                const declared = try self.typeExprToType(v.type_expr);
                const value_t = try self.checkExpr(ctx, v.value);
                if (!assignable(declared, value_t)) {
                    return self.fail(error.TypeMismatch, "'{s}' için tip uyuşmazlığı", .{v.name});
                }
                try ctx.scope.declare(self.allocator, v.name, declared);
            },
            .assign => |a| try self.checkAssign(ctx, a),
            .if_stmt => |f| {
                const ct = try self.checkExpr(ctx, f.cond);
                if (ct != .boolean) return self.fail(error.TypeMismatch, "'if' koşulu bool olmalıdır", .{});
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
                for (w.body) |s| try self.checkStmt(ctx, s);
            },
            .for_stmt => |f| {
                const elem_t = try self.checkForIterable(ctx, f.iterable);
                try ctx.scope.declare(self.allocator, f.var_name, elem_t);
                for (f.body) |s| try self.checkStmt(ctx, s);
            },
            .func_def => return self.fail(error.TypeMismatch, "iç içe fonksiyon tanımı v0.1'de desteklenmiyor", .{}),
            .class_def => return self.fail(error.TypeMismatch, "sınıf tanımı yalnızca modül seviyesinde olabilir", .{}),
            .protocol_def => return self.fail(error.TypeMismatch, "protokol tanımı yalnızca modül seviyesinde olabilir", .{}),
            .extern_def => return self.fail(error.TypeMismatch, "'extern def' yalnızca modül seviyesinde olabilir", .{}),
            .import_stmt => return self.fail(error.TypeMismatch, "'import' yalnızca modül seviyesinde olabilir", .{}),
            .return_stmt => |r| {
                const expected = ctx.expected_return orelse
                    return self.fail(error.TypeMismatch, "'return' yalnızca fonksiyon/metod içinde kullanılabilir", .{});
                if (r) |e| {
                    const rt = try self.checkExpr(ctx, e);
                    if (!assignable(expected, rt)) return self.fail(error.TypeMismatch, "dönüş tipi uyuşmuyor", .{});
                } else if (expected != .none) {
                    return self.fail(error.TypeMismatch, "fonksiyon bir değer döndürmelidir", .{});
                }
            },
            .raise_stmt => |e| {
                const t = try self.checkExpr(ctx, e);
                if (t != .class) return self.fail(error.TypeMismatch, "'raise' yalnızca bir sınıf örneği alabilir", .{});
            },
            .try_stmt => |t| try self.checkTry(ctx, t),
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
            if (!self.classes.contains(ec.class_name)) {
                return self.fail(error.UndefinedClass, "bilinmeyen sınıf: {s}", .{ec.class_name});
            }
            if (ec.bind_name) |bn| {
                try ctx.scope.declare(self.allocator, bn, .{ .class = ec.class_name });
            }
            for (ec.body) |s| try self.checkStmt(ctx, s);
        }
        if (t.finally_body) |fb| for (fb) |s| try self.checkStmt(ctx, s);
    }

    fn checkAssign(self: *Checker, ctx: *FnCtx, a: ast.Assign) TypeError!void {
        switch (a.target) {
            .identifier => |name| {
                const existing = ctx.scope.lookup(name) orelse
                    return self.fail(error.UndefinedVariable, "tanımsız değişken: {s}", .{name});
                const value_t = try self.checkExpr(ctx, a.value);
                if (!assignable(existing, value_t)) {
                    return self.fail(error.TypeMismatch, "'{s}' için tip uyuşmazlığı", .{name});
                }
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
                const class_name = switch (obj_t) {
                    .class => |n| n,
                    else => return self.fail(error.TypeMismatch, "'.{s}' yalnızca sınıf örneklerinde kullanılabilir", .{attr.attr}),
                };
                const is_self = attr.obj.* == .identifier and std.mem.eql(u8, attr.obj.identifier, "self");
                const value_t = try self.checkExpr(ctx, a.value);
                const info = self.classes.getPtr(class_name).?;
                if (info.fields.get(attr.attr)) |existing_t| {
                    if (!assignable(existing_t, value_t)) {
                        return self.fail(error.TypeMismatch, "'{s}.{s}' için tip uyuşmazlığı", .{ class_name, attr.attr });
                    }
                } else {
                    if (!(is_self and ctx.is_init)) {
                        return self.fail(error.UndefinedAttribute, "'{s}' sınıfının '{s}' alanı yalnızca __init__ içinde 'self.{s} = ...' ile tanımlanabilir", .{ class_name, attr.attr, attr.attr });
                    }
                    try info.fields.put(self.allocator, attr.attr, value_t);
                }
            },
            // `d[key] = value` — YALNIZCA `dict` için desteklenir (v1
            // kapsamı — bkz. nox-teknik-spesifikasyon.md §3.28; `list[T]`
            // İÇİN indeksli atama HENÜZ desteklenmiyor, bu YENİ bir
            // kısıtlama DEĞİL, mevcut bir v0.1 sınırlaması — bkz. bu
            // switch'in önceki hâli, hiç `.index` kolu YOKTU).
            .index => |idx| {
                const obj_t = try self.checkExpr(ctx, idx.obj.*);
                if (obj_t != .dict) {
                    return self.fail(error.TypeMismatch, "indeksli atama yalnızca 'dict' üzerinde çalışır", .{});
                }
                const key_t = try self.checkExpr(ctx, idx.index.*);
                if (!types.eql(key_t, obj_t.dict.key.*)) {
                    return self.fail(error.TypeMismatch, "dict indeksi anahtar tipiyle uyuşmuyor", .{});
                }
                const value_t = try self.checkExpr(ctx, a.value);
                if (!assignable(obj_t.dict.value.*, value_t)) {
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

    fn checkExpr(self: *Checker, ctx: *FnCtx, expr: ast.Expr) TypeError!Type {
        return switch (expr) {
            .int_lit => .int,
            .float_lit => .float,
            .bool_lit => .boolean,
            .string_lit => .str,
            .none_lit => .none,
            .identifier => |name| ctx.scope.lookup(name) orelse
                return self.fail(error.UndefinedVariable, "tanımsız değişken: {s}", .{name}),
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
                // Boş `{}` DESTEKLENMEZ — `[]`in AYNI kısıtlaması (bkz.
                // `ast.zig`'in `dict_lit` belge notu); parser zaten en az
                // bir çift ZORUNLU kılar, bu kontrol savunmacıdır.
                if (pairs.len == 0) return self.fail(error.UnknownType, "boş dict literalinin tipi çıkarılamaz", .{});
                const first_key = try self.checkExpr(ctx, pairs[0].key);
                const first_value = try self.checkExpr(ctx, pairs[0].value);
                if (first_key != .int and first_key != .boolean and first_key != .str) {
                    return self.fail(error.TypeMismatch, "'dict' anahtar tipi yalnızca int/bool/str olabilir (v1 kapsamı)", .{});
                }
                if (first_value != .int and first_value != .float and first_value != .boolean and first_value != .str) {
                    return self.fail(error.TypeMismatch, "'dict' değer tipi yalnızca int/float/bool/str olabilir (v1 kapsamı)", .{});
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
                // Task DEĞİLSE, yalnızca bir Channel.send/recv çağrısı olabilir
                // — bu çağrılar (bkz. `checkCall`in `.channel` dalı) `T`yi
                // (ya da `send` için `None`u) ZATEN DOĞRUDAN döndürür; burada
                // yalnızca "açıkça bir askıya alma noktası" sözdizimsel ŞEKLİ
                // doğrulanır.
                const is_channel_op = switch (operand) {
                    .call => |c| switch (c.callee.*) {
                        .attribute => |a| (std.mem.eql(u8, a.attr, "send") or std.mem.eql(u8, a.attr, "recv")) and
                            (self.checkExpr(ctx, a.obj.*) catch return self.fail(error.TypeMismatch, "'await' ifadesinin alıcısı çözümlenemedi", .{})) == .channel,
                        else => false,
                    },
                    else => false,
                };
                if (!is_channel_op) return self.fail(error.TypeMismatch, "'await' yalnızca bir Task değeri ya da bir Channel.send/recv çağrısı üzerinde kullanılabilir", .{});
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
            .generic_construct => |g| blk: {
                // v0.1'de tek tanınan yerleşik generic kurucu: `Channel[T](
                // capacity)` (bkz. `parser.zig`, `isGenericConstructName`).
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
                break :blk .{ .channel = boxed };
            },
        };
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

    fn numericPromote(self: *Checker, l: Type, r: Type) TypeError!Type {
        if (!types.isNumeric(l) or !types.isNumeric(r)) {
            return self.fail(error.TypeMismatch, "aritmetik işlem yalnızca sayısal tiplerde çalışır", .{});
        }
        if (l == .float or r == .float) return .float;
        return .int;
    }

    fn checkAttribute(self: *Checker, ctx: *FnCtx, a: ast.Attribute) TypeError!Type {
        const obj_t = try self.checkExpr(ctx, a.obj.*);
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
                    if (t != .int and t != .float) {
                        return self.fail(error.TypeMismatch, "'str' yalnızca int/float üzerinde çalışır", .{});
                    }
                    return .str;
                }
                if (std.mem.eql(u8, name, "int")) {
                    if (c.args.len != 1) return self.fail(error.ArgumentCountMismatch, "'int' tam olarak 1 argüman alır", .{});
                    if (try self.checkExpr(ctx, c.args[0]) != .str) {
                        return self.fail(error.TypeMismatch, "'int' yalnızca str üzerinde çalışır", .{});
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
                    return .int;
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
                return self.fail(error.UndefinedFunction, "tanımsız fonksiyon veya sınıf: {s}", .{name});
            },
            .attribute => |a| {
                // `nox.http.serve(port, handle[, max_connections])` — D.1.6'nın
                // özel yerleşiği (bkz. `checkHttpServeCall`in belge notu).
                // `tryResolveQualifiedCall`DAN ÖNCE denenir: `handle` çıplak
                // bir fonksiyon ADI olduğundan (`spawn`ınkiyle AYNI kısıt,
                // bkz. `.spawn_expr` dalı) normal argüman tipi denetiminden
                // (`checkArgs`/`checkExpr`) GEÇİRİLEMEZ — fonksiyonlar Nox'ta
                // birinci sınıf DEĞER DEĞİLDİR.
                if (try self.tryResolveHttpServeCall(ctx, c)) |t| return t;
                // `nox.http.get(url)` gibi bir stdlib modülüne nitelikli
                // erişimi dener (bkz. `tryResolveQualifiedCall`in belge
                // notu) — bu, ASAĞIDAKİ `checkExpr(ctx, a.obj.*)`DEN ÖNCE
                // olmalı, çünkü `nox`/`nox.http` GERÇEK bir değişken/ifade
                // DEĞİLDİR (`checkExpr` "tanımsız değişken" ile başarısız
                // olurdu). Eşleşmezse (`null`) MEVCUT metod-çağrısı
                // çözümlemesine (aşağısı, DEĞİŞMEMİŞ) düşülür.
                if (try self.tryResolveQualifiedCall(ctx, c)) |t| return t;

                const obj_t = try self.checkExpr(ctx, a.obj.*);
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
                        if (!assignable(elem_t, at)) return self.fail(error.TypeMismatch, "'send' argümanı kanalın eleman tipiyle uyuşmuyor", .{});
                        return .none;
                    }
                    if (std.mem.eql(u8, a.attr, "recv")) {
                        if (c.args.len != 0) return self.fail(error.ArgumentCountMismatch, "'recv' hiç argüman almaz", .{});
                        return elem_t;
                    }
                    return self.fail(error.UndefinedMethod, "Channel'ın '{s}' metodu yok (yalnızca send/recv)", .{a.attr});
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
                    return self.fail(error.UndefinedMethod, "dict'in '{s}' metodu yok (yalnızca contains/len)", .{a.attr});
                }
                const class_name = switch (obj_t) {
                    .class => |n| n,
                    else => return self.fail(error.TypeMismatch, "metod çağrısı yalnızca sınıf örneklerinde geçerlidir", .{}),
                };
                const info = self.classes.getPtr(class_name) orelse
                    return self.fail(error.UndefinedClass, "bilinmeyen sınıf: {s}", .{class_name});
                const sig = info.methods.get(a.attr) orelse
                    return self.fail(error.UndefinedMethod, "'{s}' sınıfının '{s}' metodu yok", .{ class_name, a.attr });
                try self.checkArgs(ctx, sig.params, c.args, a.attr);
                return sig.return_type;
            },
            else => return self.fail(error.NotCallable, "bu ifade çağrılabilir değil", .{}),
        }
    }

    fn checkArgs(self: *Checker, ctx: *FnCtx, params: []const Type, args: []const ast.Expr, name: []const u8) TypeError!void {
        if (params.len != args.len) {
            return self.fail(error.ArgumentCountMismatch, "'{s}' {d} argüman bekler, {d} verildi", .{ name, params.len, args.len });
        }
        for (params, args) |pt, ae| {
            const at = try self.checkExpr(ctx, ae);
            if (!assignable(pt, at)) return self.fail(error.TypeMismatch, "'{s}' argümanı için tip uyuşmazlığı", .{name});
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
                if (!assignable(declared, actual)) {
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
            .dict => |d| blk: {
                const args = try self.allocator.alloc(ast.TypeExpr, 2);
                args[0] = try self.typeToTypeExpr(d.key.*);
                args[1] = try self.typeToTypeExpr(d.value.*);
                break :blk .{ .generic = .{ .name = "dict", .args = args } };
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
            .dict => |d| {
                try buf.appendSlice(self.allocator, "dict_");
                try self.appendMangledType(buf, d.key.*);
                try buf.appendSlice(self.allocator, "_");
                try self.appendMangledType(buf, d.value.*);
            },
        }
    }

    /// Bir generic fonksiyon çağrısını (`gfd`) somutlaştırır: argümanları
    /// denetler, tip parametrelerini çıkarır, (önbellekte yoksa) somut bir
    /// `FuncDef` sentezleyip kaydeder/denetler ve çağrı sitesinin `callee`
    /// düğümünü YERİNDE mangled isme yeniden yazar. Döndürülen `Type`, bu
    /// çağrı ifadesinin (`c`) kendi tipidir.
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
