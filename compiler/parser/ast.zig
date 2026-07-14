//! Nox v0.1 AST düğüm tanımları. Düğümler bir arena allocator üzerinde
//! tahsis edilir (bkz. parser.zig); bu yalnızca derleyicinin kendi
//! implementasyon detayıdır, Nox dilinin sahiplik modeliyle ilgisi yoktur.

pub const TypeExpr = union(enum) {
    simple: []const u8, // int, float, bool, str, None, ya da bir sınıf adı
    generic: Generic,
};

pub const Generic = struct {
    name: []const u8, // ör. "list"
    args: []TypeExpr,
};

pub const Param = struct {
    name: []const u8,
    type_expr: TypeExpr,
};

pub const UnaryOp = enum { neg, not_ };
pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    floordiv,
    mod,
    pow,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    and_,
    or_,
};

pub const Expr = union(enum) {
    int_lit: i64,
    float_lit: f64,
    bool_lit: bool,
    string_lit: []const u8,
    none_lit,
    identifier: []const u8,
    unary: Unary,
    binary: Binary,
    call: Call,
    attribute: Attribute,
    index: Index,
    list_lit: []Expr,
    /// `{k1: v1, k2: v2, ...}` — stdlib fazı §C (bkz. nox-teknik-
    /// spesifikasyon.md). Boş `{}` DESTEKLENMEZ — `[]` (boş `list_lit`)
    /// İLE AYNI gerekçeyle (checker'da tip çıkarımı için hiçbir eleman
    /// yok — bkz. checker.zig'in `.list_lit` dalı, "boş liste literalinin
    /// tipi çıkarılamaz").
    dict_lit: []DictPair,
    /// `await <ifade>` — bir `Task[T]`i ya da bir `Channel[T]` işlemini
    /// (`ch.send(v)`/`ch.recv()`) bekler (bkz. nox-teknik-spesifikasyon.md
    /// §3.21). Yalnızca `async def` gövdesi içinde geçerlidir (checker
    /// zorunlu kılar).
    await_expr: *Expr,
    /// `spawn <çağrı-ifadesi>` — çağrıyı HEMEN bir yeşil iş parçacığında
    /// başlatır, bir `Task[T]` döner (bloklamaz). `operand`ın gerçekten bir
    /// `.call` (bir `async def`e) olması checker tarafından zorunlu kılınır
    /// (gramer düzeyinde kısıtlanmaz — bkz. `isRangeCall` gibi benzer
    /// desenler).
    spawn_expr: *Expr,
    /// `Channel[T](capacity)` — yerleşik `Channel` tipi için AÇIK tip
    /// argümanlı kurucu çağrısı (bkz. nox-teknik-spesifikasyon.md §3.21).
    /// Dilde başka HİÇBİR yerde `İsim[TipArgs](args)` sözdizimi YOKTUR —
    /// yalnızca ayrılmış `Channel` adı için parser'da özel olarak tanınır
    /// (bkz. `parser.zig`, `isGenericConstructName`).
    generic_construct: GenericConstruct,
};

pub const Unary = struct { op: UnaryOp, operand: *Expr };
pub const Binary = struct { op: BinaryOp, left: *Expr, right: *Expr };
pub const Call = struct { callee: *Expr, args: []Expr };
pub const Attribute = struct { obj: *Expr, attr: []const u8 };
pub const Index = struct { obj: *Expr, index: *Expr };
pub const GenericConstruct = struct { name: []const u8, type_args: []TypeExpr, args: []Expr };
pub const DictPair = struct { key: Expr, value: Expr };

pub const ElifClause = struct { cond: Expr, body: []Stmt };

pub const IfStmt = struct {
    cond: Expr,
    then_body: []Stmt,
    elif_clauses: []ElifClause,
    else_body: ?[]Stmt,
};

pub const WhileStmt = struct { cond: Expr, body: []Stmt };

pub const ForStmt = struct {
    var_name: []const u8,
    iterable: Expr,
    body: []Stmt,
};

pub const FuncDef = struct {
    name: []const u8,
    /// `def name[T, U](...)` — boşsa sıradan (generic olmayan) bir fonksiyon/
    /// metod. Yalnızca serbest fonksiyonlarda desteklenir (bkz. Faz 10);
    /// metodlarda her zaman boştur.
    type_params: []const []const u8 = &.{},
    params: []Param,
    return_type: TypeExpr,
    body: []Stmt,
    /// `async def` — gövdesi içinde `await` kullanılabilir (checker zorunlu
    /// kılar); yalnızca `spawn` ile çağrılabilir (bkz. nox-teknik-
    /// spesifikasyon.md §3.21).
    is_async: bool = false,
};

pub const ClassDef = struct {
    name: []const u8,
    methods: []FuncDef,
};

/// Yapısal (structural) bir protokol — Python'ın `typing.Protocol`'üne
/// benzer: yalnızca metod İMZALARINI bildirir, hiçbir sınıf bunu açıkça
/// "implements" etmez (bkz. AGENTS.md §12, nox-teknik-spesifikasyon.md
/// §3.11). Her `FuncDef`in gövdesi tek bir `pass` olmalıdır (checker
/// zorunlu kılar) — yalnızca imza taşırlar.
pub const ProtocolDef = struct {
    name: []const u8,
    methods: []FuncDef,
};

/// `extern def name(params) -> ReturnType from "lib"` — gövdesi OLMAYAN,
/// derleme/bağlama zamanında çözülen bir C ABI fonksiyon bildirimi (bkz.
/// nox-teknik-spesifikasyon.md §3.20). `from_lib`, bir sistem kütüphanesi
/// ADI (`cc`ye `-l<ad>` olarak geçirilir) ya da doğrudan bir nesne/arşiv
/// dosya yoludur (`.o`/`.a` uzantılı ya da `/`/`.` içeren — bkz.
/// `compiler/main.zig`'in ayrım mantığı).
pub const ExternDef = struct {
    name: []const u8,
    params: []Param,
    return_type: TypeExpr,
    from_lib: []const u8,
    /// `with_rt` işareti — bkz. nox-teknik-spesifikasyon.md, stdlib fazı
    /// §D.1 (Keşif 3). Varsayılan (`false`): bu extern def ÇAĞRILIRKEN
    /// hiçbir gizli argüman GEÇİRİLMEZ (Faz 20'nin ZATEN var olan "ARC-dışı
    /// opak" tasarımı, DEĞİŞMEDEN — `counter.c`/HPy/WASM köprüleri). `true`
    /// İSE (`extern def ... from "lib" with_rt`), codegen'in `genCall`i
    /// argüman listesinin BAŞINA GİZLİCE `RT_PARAM`ı ekler (normal
    /// fonksiyon çağrılarıyla AYNI kalıp) — Zig tarafındaki fonksiyonun
    /// İLK parametresi `rt: ?*anyopaque` OLMALIDIR. Bu, `str`/`dict[str,str]`
    /// gibi ARC/allocator erişimi gerektiren DEĞERLER üreten stdlib
    /// kabuklarının (ör. `nox.http`) `rt`ye erişebilmesi İÇİNDİR.
    needs_rt: bool = false,
};

pub const VarDecl = struct {
    name: []const u8,
    type_expr: TypeExpr,
    value: Expr,
};

pub const Assign = struct {
    target: Expr,
    value: Expr,
};

pub const ExceptClause = struct {
    class_name: []const u8,
    bind_name: ?[]const u8,
    body: []Stmt,
};

pub const TryStmt = struct {
    try_body: []Stmt,
    except_clauses: []ExceptClause,
    finally_body: ?[]Stmt,
};

pub const LowLevelStmt = struct {
    body: []Stmt,
};

/// `import nox.http` — Python'un `import a.b` semantiğiyle BİREBİR aynı:
/// yerel kapsama `segments[0]` (ör. `"nox"`) adı girer, çağrı sitelerinde
/// TAM noktalı yol (`nox.http.get(...)`) kullanılır (bkz. nox-teknik-
/// spesifikasyon.md, stdlib fazı §A). Yalnızca modül seviyesinde geçerlidir.
/// Faz U.3: `import nox.http as h` — `alias` VERİLDİĞİNDE, `h` YERİNE TAM
/// yolun (`nox.http`) KENDİSİNE bağlanır (Python'un `import a.b as x`
/// semantiğiyle AYNI) — `h.get(...)` `nox.http.get(...)` İLE EŞDEĞERDİR.
pub const ImportStmt = struct {
    segments: []const []const u8,
    alias: ?[]const u8 = null,
};

/// Faz U.3: `from nox.http import get` / `from nox.http import get as g` —
/// `names` içindeki HER üye, MODÜL niteliği OLMADAN doğrudan yerel kapsama
/// bağlanır (`alias` VERİLMEDİYSE `name`in KENDİSİYLE, VERİLDİYSE `alias`
/// ile). Bkz. `ast.ImportStmt`in belge notu — dosya çözümlemesi (`segments`)
/// AYNI mekanizmayı kullanır, yalnızca yerel isimlendirme FARKLIDIR.
pub const FromImportName = struct {
    name: []const u8,
    alias: ?[]const u8 = null,
};

pub const FromImportStmt = struct {
    segments: []const []const u8,
    names: []const FromImportName,
};

/// Faz T.1: kaynak pozisyonu — bilinçli olarak yalnızca DEYİM (statement)
/// GRANÜLERLİĞİNDE (ifade/`Expr` düzeyinde DEĞİL). `checker.zig`/`codegen.zig`nin
/// `ast.Expr`i eşleştirdiği DÜZİNELERCE yer (her `checkExpr`/`genExpr`
/// özyinelemesi) varken, `ast.Stmt`i eşleştiren yer sayısı ÇOK daha azdır
/// (yalnızca `checkStmt`/`genStmts`in kendi dağıtım noktaları + birkaç modül-
/// düzeyi filtre) — bu, DEYİM düzeyinde pozisyon eklemeyi GÜVENLE, `Expr`in
/// TÜM kod tabanına yayılmış temsilini DEĞİŞTİRMEDEN yapılabilir kılar.
/// Bir DEYİM içindeki bir ALT ifadede oluşan bir hata, o DEYİMİN satırını
/// raporlar (Python'un KENDİ hata raporlamasıyla BENZER granülerlik) —
/// tam sütun/ifade-düzeyi hassasiyeti BİLİNÇLİ olarak v1 kapsamı DIŞINDA
/// bırakılmıştır (gelecekteki bir faz İÇİN not, bkz. nox-teknik-
/// spesifikasyon.md §3.15).
pub const StmtKind = union(enum) {
    expr_stmt: Expr,
    var_decl: VarDecl,
    assign: Assign,
    if_stmt: IfStmt,
    while_stmt: WhileStmt,
    for_stmt: ForStmt,
    func_def: FuncDef,
    class_def: ClassDef,
    protocol_def: ProtocolDef,
    extern_def: ExternDef,
    return_stmt: ?Expr,
    raise_stmt: Expr,
    try_stmt: TryStmt,
    lowlevel_stmt: LowLevelStmt,
    import_stmt: ImportStmt,
    from_import_stmt: FromImportStmt,
    pass_stmt,
};

/// `parser.zig`nin `parseStmt`i (TÜM deyim ayrıştırmasının TEK dağıtım
/// noktası) her deyimi SARIP `line`i (1-tabanlı kaynak satırı, bkz.
/// `lexer/token.zig`nin `Token.line`i) EKLER — bkz. `StmtKind`in belge
/// notu. `.kind` alanına erişim, ÖNCEDEN `ast.Stmt` DOĞRUDAN birleşimin
/// kendisiyken şimdi bir SARMALAYICI struct İÇİNDE olduğundan, TÜM mevcut
/// `stmt == .xxx`/`switch (stmt)` yerleri `stmt.kind == .xxx`/`switch
/// (stmt.kind)`e güncellendi (bkz. checker.zig/codegen_qbe/codegen.zig).
pub const Stmt = struct {
    kind: StmtKind,
    line: u32 = 0,
};

pub const Module = struct {
    body: []Stmt,
};
