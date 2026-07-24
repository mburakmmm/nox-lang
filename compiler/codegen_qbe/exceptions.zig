//! İstisna kontrol-akışı (`raise`/`try`/`except`/`finally`/`with`) codegen'i
//! VE derleme-zamanı istisna-güvenliği statik analizi (`must_not_raise`/
//! inlining'in ön-koşulu olan özyineleme tespiti) — bkz. plan dosyası "QBE
//! codegen backend'ini alt modüllere bölme". Bu iki küme İÇ İÇE geçmiştir
//! (`genTry`/`genWith` çalışma-zamanı istisna YAYILIMINI üretirken,
//! `computeMustNotRaise`/`markRecursiveFuncs` HANGİ çağrıların ASLA
//! istisna FIRLATAMAYACAĞINI derleme zamanında KANITLAYIP gereksiz
//! `emitExceptionCheck`leri eler) — TEK dosyada birleştirilir.

const std = @import("std");
const ast = @import("../parser/ast.zig");
const types = @import("types.zig");
const abi = @import("abi.zig");
const codegen = @import("codegen.zig");

const Codegen = codegen.Codegen;
const QbeType = types.QbeType;
const RT_PARAM = types.RT_PARAM;
const CodegenError = abi.CodegenError;
const qbeTypeName = abi.qbeTypeName;
const isHeapManaged = abi.isHeapManaged;

pub fn genRaise(self: *Codegen, expr: ast.Expr) CodegenError!void {
    const obj = try self.genExpr(expr);
    if (obj.heap != .class) return error.Unsupported;
    try self.out.writer.print("    call $nox_raise(l {s}, l {s})\n", .{ RT_PARAM, obj.text });
    try self.emitExceptionCheck();
}

/// Şu an aktif olan (en içten en dışa) tüm `finally` gövdelerini satır
/// içi (inline) üretir — `return_stmt` tarafından gerçek `ret`ten hemen
/// önce çağrılır (bkz. `finally_stack` alanının belge notu).
pub fn drainFinally(self: *Codegen, ret_qtype: QbeType) CodegenError!void {
    var i = self.finally_stack.items.len;
    while (i > 0) {
        i -= 1;
        try self.genStmts(self.finally_stack.items[i], ret_qtype);
    }
}

/// Şu an aktif olan (en içten en dışa) tüm `lowlevel` arenalarını yıkar —
/// `drainFinally` ile aynı gerekçeyle, bir `return`/yakalanmamış istisna
/// gerçek çıkıştan önce (bkz. `finally_stack`'in belge notu, aynı mantık
/// arenalar için de geçerlidir).
pub fn drainArenas(self: *Codegen) CodegenError!void {
    var i = self.arena_stack.items.len;
    while (i > 0) {
        i -= 1;
        try self.out.writer.print("    call $nox_arena_destroy(l {s}, l {s})\n", .{ RT_PARAM, self.arena_stack.items[i] });
    }
}

/// `genTry`nin KENDİ `finally_body`sini (`fb`) "gerçek", KORUNMASIZ bir
/// çıkış eylemi OLARAK çalıştırır — `fb`, ÇAĞRILDIĞI ANDA `finally_stack`in
/// EN ÜSTÜNDEDİR (genTry'nin push'u SAYESİNDE, bkz. `finally_stack`in
/// belge notu); GEÇİCİ olarak POP'lanıp (KENDİ İÇİNDEKİ bir çağrı istisna
/// fırlatırsa bu istisnanın `emitExceptionCheck` ARACILIĞIYLA `fb`yi
/// TEKRAR draine ETMEK YERİNE doğru şekilde DIŞARIYA, `saved_catch`e
/// yayılması İÇİN) çalıştırılır, SONRA (BAŞKA bir çıkış yolu — ör. bir
/// SONRAKİ `except` dalının KENDİ `return`ü — HÂLÂ onu gerektirebileceğinden)
/// GERİ EKLENİR.
///
/// **Düzeltilen kritik hata (Faz U.5'in doğrulaması SIRASINDA bulundu):**
/// bu SARMALAMA OLMADAN, `fb` `finally_stack`deYKEN doğrudan `genStmts(fb)`
/// İLE çalıştırılırsa VE `fb` bir `emitExceptionCheck` ÜRETEN çağrı
/// İÇERİYORSA (Faz M.8 (yeniden ele alındı) ÖNCESİNDE HER metod çağrısı
/// KOŞULSUZ böyleydi; ARTIK yalnızca `must_not_raise`e GİRMEYEN çağrılar
/// böyle — ama bu SARMALAMA her iki durumda da GENEL/SAVUNMACI olarak
/// GEREKLİDİR, çünkü `fb`nin GERÇEKTEN bir kontrol üretip üretmediği
/// burada STATİK olarak varsayılamaz), `current_catch_label` bu noktada
/// ZATEN eski değerine (genellikle `null`) DÖNMÜŞ OLDUĞUNDAN
/// `emitExceptionCheck` `drainFinally`yi ÇAĞIRIR — bu da `finally_stack`de
/// HÂLÂ DURAN `fb`yi TEKRAR çalıştırır, bu da AYNI çağrıyı TEKRAR
/// üretir... SONSUZ DERLEME-ZAMANI özyinelemesi (noxc'nin KENDİSİNİN
/// yığın taşmasıyla ÇÖKMESİ). Bu, Faz U.5'in `with` desteğini genTry'ye
/// DEVREDEN `genWith`i doğrularken KEŞFEDİLDİ — `__exit__()` HER ZAMAN
/// bir metod çağrısı OLDUĞUNDAN, İÇİNDE bir METOD ÇAĞRISI OLAN HER
/// `finally`/`with` bloğu bunu tetikler (yalnızca `with`e özgü DEĞİL —
/// sıradan `try/finally` İÇİN de GEÇERLİ bir düzeltmedir, `with` bunu
/// YALNIZCA İLK KEZ ORTAYA ÇIKARDI).
pub fn runDetachedFinally(self: *Codegen, fb: []const ast.Stmt, ret_qtype: QbeType) CodegenError!void {
    _ = self.finally_stack.pop();
    try self.genStmts(fb, ret_qtype);
    try self.finally_stack.append(self.allocator, fb);
}

pub fn genTry(self: *Codegen, t: ast.TryStmt, ret_qtype: QbeType) CodegenError!void {
    const dispatch_label = try self.newLabel("try_dispatch");
    const after_label = try self.newLabel("try_after");
    const end_label = try self.newLabel("try_end");

    if (t.finally_body) |fb| try self.finally_stack.append(self.allocator, fb);

    const saved_catch = self.current_catch_label;
    self.current_catch_label = dispatch_label;
    try self.genStmts(t.try_body, ret_qtype);
    self.current_catch_label = saved_catch;
    // Normal tamamlanma (ne `return` ne yakalanmamış istisna): finally'i
    // burada BİR KEZ çalıştır. `t.try_body` bir `return` ile bittiyse bu
    // nokta hiç erişilmez (üstteki `genStmts` zaten bir `ret` üretti ve
    // `drainFinally` orada devreye girdi) — o durumda burası ölü koddur.
    // `runDetachedFinally` (bkz. onun belge notu) kullanılır — `fb`nin
    // KENDİSİ `finally_stack`de İKEN çalıştırılırsa, İÇİNDE bir
    // `emitExceptionCheck` üreten çağrı varsa `current_catch_label`
    // ZATEN eski değerine döndüğünden `drainFinally` `fb`yi TEKRAR
    // çalıştırıp SONSUZ derleme-zamanı özyinelemesine yol açardı
    // (bkz. Faz U.5'in doğrulaması, bunu İLK KEZ ortaya çıkaran senaryo).
    if (t.finally_body) |fb| try self.runDetachedFinally(fb, ret_qtype);
    try self.out.writer.print("    jmp {s}\n", .{after_label});

    try self.out.writer.print("{s}\n", .{dispatch_label});
    const exc_ptr = try self.newTemp();
    try self.out.writer.print("    {s} =l call $nox_exception_take(l {s})\n", .{ exc_ptr, RT_PARAM });
    const tag = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ tag, exc_ptr });

    var next_check = try self.newLabel("except_check");
    try self.out.writer.print("    jmp {s}\n", .{next_check});

    for (t.except_clauses, 0..) |ec, i| {
        // Bulundu (bkz. proje belleği "from-import class type
        // annotations" görevi, `registration.zig`nin `resolveType`
        // `.simple` dalıyla AYNI KÖK neden): checker `ec.class_name`i
        // KENDİ amaçları İçin çözse BİLE, AST düğümünün KENDİSİ
        // (`ast.ExceptClause.class_name`, düz bir DEĞER alanı) YENİDEN
        // YAZILMAZ — codegen'in KENDİ (BAĞIMSIZ) `self.classes` araması
        // bu YÜZDEN AYNI `from_imports` geri düşüşüne İHTİYAÇ duyar.
        const cinfo = self.classes.get(ec.class_name) orelse blk: {
            if (self.from_imports.get(ec.class_name)) |mangled| {
                if (self.classes.get(mangled)) |info| break :blk info;
            }
            return error.Unsupported;
        };
        try self.out.writer.print("{s}\n", .{next_check});
        const matches = try self.newTemp();
        try self.out.writer.print("    {s} =w ceql {s}, {d}\n", .{ matches, tag, cinfo.class_id });
        const handler_label = try self.newLabel("except_body");
        const is_last = i == t.except_clauses.len - 1;
        const following = if (!is_last) try self.newLabel("except_check") else try self.newLabel("except_reraise");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ matches, handler_label, following });
        try self.out.writer.print("{s}\n", .{handler_label});
        if (ec.bind_name) |bn| {
            const info = self.vars.get(bn).?;
            // Bu `except` gövdesi bir döngü içindeyse aynı bağlama ismi
            // (`e`) her yinelemede yeniden kullanılır — sıradan bir isme
            // atama gibi (bkz. `genAssign`'in `.identifier` kolu), ESKİ
            // değeri (varsa) ÜZERİNE YAZMADAN ÖNCE serbest bırakmazsak
            // önceki istisna nesnesi sonsuza dek sızar.
            try self.releaseSlotIfSet(info);
            try self.out.writer.print("    storel {s}, {s}\n", .{ exc_ptr, info.slot });
        }
        try self.genStmts(ec.body, ret_qtype);
        if (t.finally_body) |fb| try self.runDetachedFinally(fb, ret_qtype);
        try self.out.writer.print("    jmp {s}\n", .{after_label});
        next_check = following;
    }

    // Bu `try`nin korumalı bölgesinden (try_body + except gövdeleri) çıkıldı;
    // `finally` artık `return_stmt`'in örtük olarak bulacağı yığında olmamalı.
    if (t.finally_body != null) _ = self.finally_stack.pop();

    // Hiçbir `except` eşleşmedi: finally'i çalıştır, istisnayı yeniden
    // işaretle ve dışarıya yay (bu `try`'ın kendi dispatch'i artık devrede
    // değil — `current_catch_label` yukarıda eski değerine geri alındı).
    try self.out.writer.print("{s}\n", .{next_check});
    if (t.finally_body) |fb| try self.genStmts(fb, ret_qtype);
    try self.out.writer.print("    call $nox_raise(l {s}, l {s})\n", .{ RT_PARAM, exc_ptr });
    try self.emitExceptionCheck();
    try self.out.writer.print("    jmp {s}\n", .{after_label});

    try self.out.writer.print("{s}\n", .{after_label});
    try self.out.writer.print("{s}\n", .{end_label});
}

/// Faz U.5: `with EXPR as NAME:` — bkz. `ast.WithStmt`in belge notu.
/// `EXPR`in DEĞERİ (`ctx_val`), fonksiyonun geri kalanıyla AYNI
/// "fonksiyon-genelinde yerel" modelini paylaşan GİZLİ bir yerelde
/// (`__with_ctx_L<satır>`, bkz. `collectLocals`in `.with_stmt` dalı —
/// AYNI isim FORMÜLÜ) TUTULUR — GERÇEK bellek serbest bırakması normal
/// fonksiyon-sonu `releaseAllLocals`e ERTELENİR (Python'un HEMEN bloğun
/// SONUNDA serbest bırakmasından FARKLI, ama ARC doğruluğu AÇISINDAN
/// eşdeğerdir).
///
/// **Kritik tasarım kararı — gövde/temizlik İLİŞKİSİ, SIFIR `except`
/// dallı bir `try/finally` İLE BİREBİR AYNIDIR:** İlk tasarım (`__exit__`
/// çağrısını `finally_stack`e itip yalnızca NORMAL tamamlanmada elle
/// çalıştırmak) YANLIŞTI — bir istisna, `with` gövdesini SARAN bir DIŞ
/// `try`nin dispatch'i tarafından yakalandığında, `emitExceptionCheck`
/// `current_catch_label` AYARLIYSA doğrudan O dispatch'e ATLAR
/// (`drainFinally`Yİ HİÇ ÇAĞIRMADAN, bkz. onun belge notu) — bu durumda
/// `with`in `__exit__`i ASLA çalışmazdı. `genTry`nin KENDİSİ bunu TAM
/// OLARAK ÇÖZER: `current_catch_label`i KENDİ dispatch'ine ÇEVİRİP HER
/// çıkış yolunda (normal/eşleşen-except/eşleşmeyen-yeniden-fırlatma)
/// `finally_body`yi SATIR İÇİNDE ÇALIŞTIRIR — `with`in `__exit__`i TAM
/// OLARAK bu `finally_body` ROLÜNÜ oynar. Bu yüzden `genWith`, KENDİ
/// dispatch/reraise mantığını YENİDEN YAZMAK YERİNE, `except_clauses`i
/// BOŞ bir sentetik `ast.TryStmt` inşa edip DOĞRUDAN `genTry`ye
/// (battle-tested, `raise`/`return`/normal tamamlanma DAHİL HER yolu
/// zaten doğru işleyen) DEVREDER.
pub fn genWith(self: *Codegen, w: ast.WithStmt, line: u32, ret_qtype: QbeType) CodegenError!void {
    const hidden_name = try std.fmt.allocPrint(self.allocator, "__with_ctx_L{d}", .{line});
    const ctx_val = try self.genExpr(w.ctx_expr);
    if (ctx_val.heap != .class) return error.Unsupported;
    const hidden = self.vars.get(hidden_name).?;
    const retained = try self.retainIfAliasing(w.ctx_expr, ctx_val);
    if (isHeapManaged(hidden.heap) and !hidden.arena) try self.releaseSlotIfSet(hidden);
    try self.out.writer.print("    storel {s}, {s}\n", .{ retained.text, hidden.slot });

    const enter_call = try self.buildMethodCallExpr(hidden_name, "__enter__");
    const enter_result = try self.genExpr(enter_call);
    if (w.binding) |bn| {
        const bind_info = self.vars.get(bn).?;
        const converted = try self.convert(enter_result, bind_info.qtype);
        if (isHeapManaged(bind_info.heap) and !bind_info.arena) try self.releaseSlotIfSet(bind_info);
        try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(bind_info.qtype), converted.text, bind_info.slot });
    } else {
        try self.releaseIfTemporary(enter_call, enter_result);
    }

    const exit_call = try self.buildMethodCallExpr(hidden_name, "__exit__");
    const exit_stmts = try self.allocator.alloc(ast.Stmt, 1);
    exit_stmts[0] = .{ .kind = .{ .expr_stmt = exit_call }, .line = line };

    try self.genTry(.{ .try_body = w.body, .except_clauses = &.{}, .finally_body = exit_stmts }, ret_qtype);
}

/// `genWith`in sentetik `obj.method()` çağrı ifadesi kurucusu —
/// `__enter__`/`__exit__`i, `genExpr`in NORMAL `.call`/`.attribute`
/// dağıtımından (`genMethodCall`) geçirebilmek İÇİN (retain/release/
/// istisna kontrolü DAHİL, HİÇBİR ÖZEL kod GEREKMEDEN).
pub fn buildMethodCallExpr(self: *Codegen, obj_name: []const u8, method: []const u8) CodegenError!ast.Expr {
    const obj_expr = try self.allocator.create(ast.Expr);
    obj_expr.* = .{ .identifier = obj_name };
    const attr_expr = try self.allocator.create(ast.Expr);
    attr_expr.* = .{ .attribute = .{ .obj = obj_expr, .attr = method } };
    return .{ .call = .{ .callee = attr_expr, .args = &.{} } };
}

/// Bir serbest fonksiyonun/kurucunun (`__init__`) gövdesi hakkında
/// toplanan ham bilgi — bkz. `computeMustNotRaise`.
pub const FuncSafetyInfo = struct {
    /// `true`: gövde İÇİNDE doğrudan bir `raise`, bir METOD ÇAĞRISI
    /// (`obj.method()` — bkz. `computeMustNotRaise`in "muhafazakâr" notu)
    /// ya da bir `await`/`spawn` var — bu durumda BU sembol HER ZAMAN
    /// "güvensiz" sayılır, çağırdıklarından bağımsız olarak.
    direct_unsafe: bool = false,
    /// Gövdenin çağırdığı serbest fonksiyon/kurucu sembollerinin listesi
    /// (deduplike edilmemiş — önemli değil, yalnızca üyelik kontrolü
    /// için kullanılır). Bu sembollerden HERHANGİ BİRİ güvensizse, BU
    /// sembol de (fixpoint yoluyla) güvensiz sayılır.
    callees: std.ArrayListUnmanaged([]const u8) = .empty,
};

/// `class_ctx`/`var_types`/`poisoned` — Faz M.8 (yeniden ele alındı, bkz.
/// nox-teknik-spesifikasyon.md §3.59): `obj.method()` çağrılarını (basit,
/// çözülebilir alıcılar için) `direct_unsafe` yerine gerçek bir `callees`
/// bağımlılığına çevirebilmek için TÜM gövde boyunca taşınan, DÜZ (blok-
/// kapsamsız — `collectLocals`in AYNI Python-tarzı fonksiyon-seviyesi
/// kapsam varsayımı, bkz. onun belge notu) durum: `class_ctx` metodun AİT
/// OLDUĞU sınıfın adı (`self.diğer_metod()` çözümü için, serbest
/// fonksiyonlarda `null`), `var_types` yerel isim → sınıf adı haritası
/// (parametrelerden ÖN-DOLDURULUR, `var_decl` deyimleriyle METİN
/// SIRASINDA güncellenir), `poisoned` ise bir isim BİRDEN FAZLA kez
/// bildirilirse (`if`/`else` dallarında FARKLI sınıflara — `checker.zig`nin
/// `Scope.declare`si YİNELENEN isim kontrolü YAPMAZ, satır ~97-111)
/// KALICI olarak "çözülemez" işaretlenen isimlerin kümesidir — bir isim
/// ASLA `poisoned`dan çıkmaz, bu da `genMethodCall`in GERÇEKTE çağırdığı
/// sembolle bu analizin çözdüğü sembolün HER ZAMAN aynı kalmasını garanti
/// eder (aksi halde YANLIŞ bir sınıfın metodu "güvenli" sayılabilir —
/// SESSİZ-YUTMA riski).
pub fn declareVarType(self: *Codegen, name: []const u8, class_name: ?[]const u8, var_types: *std.StringHashMapUnmanaged([]const u8), poisoned: *std.StringHashMapUnmanaged(void)) CodegenError!void {
    if (poisoned.contains(name)) return;
    if (var_types.contains(name)) {
        _ = var_types.remove(name);
        try poisoned.put(self.allocator, name, {});
        return;
    }
    if (class_name) |cn| try var_types.put(self.allocator, name, cn);
}

/// `stmts`i özyinelemeli olarak gezip `info`yi doldurur — `moduleUsesAsync`/
/// `stmtUsesAsync`in AYNI ağaç gezinme deseni (bkz. onların belge notu),
/// ama "async kullanımı var mı" yerine "raise/metod-çağrısı/await-spawn
/// var mı VE hangi serbest fonksiyon/kurucular çağrılıyor" topluyor.
pub fn collectRaiseInfoStmts(self: *Codegen, stmts: []const ast.Stmt, info: *FuncSafetyInfo, class_ctx: ?[]const u8, var_types: *std.StringHashMapUnmanaged([]const u8), poisoned: *std.StringHashMapUnmanaged(void), list_elem_types: *std.StringHashMapUnmanaged([]const u8)) CodegenError!void {
    for (stmts) |stmt| try self.collectRaiseInfoStmt(stmt, info, class_ctx, var_types, poisoned, list_elem_types);
}

pub fn collectRaiseInfoStmt(self: *Codegen, stmt: ast.Stmt, info: *FuncSafetyInfo, class_ctx: ?[]const u8, var_types: *std.StringHashMapUnmanaged([]const u8), poisoned: *std.StringHashMapUnmanaged(void), list_elem_types: *std.StringHashMapUnmanaged([]const u8)) CodegenError!void {
    switch (stmt.kind) {
        .expr_stmt => |e| try self.collectRaiseInfoExpr(e, info, class_ctx, var_types, poisoned),
        .var_decl => |v| {
            try self.collectRaiseInfoExpr(v.value, info, class_ctx, var_types, poisoned);
            const cn: ?[]const u8 = if (v.type_expr == .simple and self.classes.contains(v.type_expr.simple)) v.type_expr.simple else null;
            try self.declareVarType(v.name, cn, var_types, poisoned);
            // Faz GG.3 (bkz. nox-teknik-spesifikasyon.md §3.68): `xs:
            // list[ClassName] = ...` İSE, `list_elem_types`e de
            // KAYDEDİLİR — `.for_stmt`in AŞAĞIDAKİ dalı `for v in xs:`
            // İÇİNDEKİ `v`nin sınıfını BURADAN çözer. AYNI `poisoned`
            // kümesi (bkz. `declareVarType`) hem `var_types` hem
            // `list_elem_types` İçin PAYLAŞILIR — bir isim HER İKİ
            // anlamda da YENİDEN bildirilirse GÜVENLİ tarafta kalınır.
            const elem_cn: ?[]const u8 = blk: {
                if (v.type_expr != .generic) break :blk null;
                const g = v.type_expr.generic;
                if (!std.mem.eql(u8, g.name, "list") or g.args.len != 1) break :blk null;
                if (g.args[0] != .simple or !self.classes.contains(g.args[0].simple)) break :blk null;
                break :blk g.args[0].simple;
            };
            try self.declareVarType(v.name, elem_cn, list_elem_types, poisoned);
        },
        .assign => |a| {
            try self.collectRaiseInfoExpr(a.target, info, class_ctx, var_types, poisoned);
            try self.collectRaiseInfoExpr(a.value, info, class_ctx, var_types, poisoned);
        },
        .if_stmt => |f| {
            try self.collectRaiseInfoExpr(f.cond, info, class_ctx, var_types, poisoned);
            try self.collectRaiseInfoStmts(f.then_body, info, class_ctx, var_types, poisoned, list_elem_types);
            for (f.elif_clauses) |ec| {
                try self.collectRaiseInfoExpr(ec.cond, info, class_ctx, var_types, poisoned);
                try self.collectRaiseInfoStmts(ec.body, info, class_ctx, var_types, poisoned, list_elem_types);
            }
            if (f.else_body) |eb| try self.collectRaiseInfoStmts(eb, info, class_ctx, var_types, poisoned, list_elem_types);
        },
        .while_stmt => |w| {
            try self.collectRaiseInfoExpr(w.cond, info, class_ctx, var_types, poisoned);
            try self.collectRaiseInfoStmts(w.body, info, class_ctx, var_types, poisoned, list_elem_types);
        },
        .for_stmt => |f| {
            try self.collectRaiseInfoExpr(f.iterable, info, class_ctx, var_types, poisoned);
            // Faz GG.3 (yeniden ele alındı, bkz. nox-teknik-spesifikasyon.md
            // §3.68): ÖNCEDEN döngü değişkeni HER ZAMAN `null` İLE
            // zehirlenirdi (sınıfı "bilinmiyor" sayılırdı) — bu, `for x
            // in xs: x.method()` kalıbının OLDUĞU HER fonksiyonu
            // KOŞULSUZ güvensiz işaretleyip Faz M.8'in kazanımını
            // SIFIRLIYORDU (GERÇEKTEN bulunan bir boşluk). ARTIK
            // `f.iterable` ÇIPLAK bir isimse VE o isim `list_elem_types`de
            // (bir `list[ClassName]` yerel/parametresi olarak) BİLİNİYORSA,
            // döngü değişkeni O sınıfla `var_types`e KAYDEDİLİR — `genForList`nin
            // GERÇEK codegen'İNİN (bkz. `collectLocals`in `.for_stmt` dalı)
            // ZATEN yaptığı AYNI çözümleme, burada TEKRARLANIR.
            const elem_cn: ?[]const u8 = blk: {
                if (f.iterable != .identifier) break :blk null;
                if (poisoned.contains(f.iterable.identifier)) break :blk null;
                break :blk list_elem_types.get(f.iterable.identifier);
            };
            try self.declareVarType(f.var_name, elem_cn, var_types, poisoned);
            try self.collectRaiseInfoStmts(f.body, info, class_ctx, var_types, poisoned, list_elem_types);
        },
        .func_def, .class_def, .protocol_def, .extern_def, .pass_stmt, .import_stmt, .from_import_stmt => {},
        .return_stmt => |r| if (r) |e| try self.collectRaiseInfoExpr(e, info, class_ctx, var_types, poisoned),
        .raise_stmt => |e| {
            info.direct_unsafe = true;
            try self.collectRaiseInfoExpr(e, info, class_ctx, var_types, poisoned);
        },
        .try_stmt => |t| {
            try self.collectRaiseInfoStmts(t.try_body, info, class_ctx, var_types, poisoned, list_elem_types);
            for (t.except_clauses) |ec| try self.collectRaiseInfoStmts(ec.body, info, class_ctx, var_types, poisoned, list_elem_types);
            if (t.finally_body) |fb| try self.collectRaiseInfoStmts(fb, info, class_ctx, var_types, poisoned, list_elem_types);
        },
        .lowlevel_stmt => |ll| try self.collectRaiseInfoStmts(ll.body, info, class_ctx, var_types, poisoned, list_elem_types),
        // Faz U.5: bir `with` deyimi HER ZAMAN örtük `__enter__`/
        // `__exit__` METOD ÇAĞRILARI içerir — bunlar da (diğer tüm metod
        // çağrıları gibi) `collectRaiseInfoExpr`in `.attribute` dalından
        // GEÇMEZ (yalnızca `w.ctx_expr`in KENDİSİ, çağrının hedefi değil,
        // gezilir), bu yüzden burası KOŞULSUZ güvensiz kalmaya devam eder.
        .with_stmt => |w| {
            info.direct_unsafe = true;
            try self.collectRaiseInfoExpr(w.ctx_expr, info, class_ctx, var_types, poisoned);
            try self.collectRaiseInfoStmts(w.body, info, class_ctx, var_types, poisoned, list_elem_types);
        },
        // `defer` HENÜZ (görev #62'ye kadar) inline-edilebilir fonksiyon
        // gövdelerinde desteklenmiyor — `with_stmt` İLE AYNI gerekçeyle
        // `direct_unsafe = true` işaretlenip `isFuncInlineEligible`in
        // BU fonksiyonu ASLA inline ADAYI SAYMAMASI sağlanır (`defer`in
        // KENDİ çalışma-zamanı yığını, inlining'in "İÇ İÇE inlining YOK"
        // kısıtıyla HENÜZ doğrulanmadı).
        .defer_stmt => |d| {
            info.direct_unsafe = true;
            try self.collectRaiseInfoExpr(ast.Expr{ .call = d.call }, info, class_ctx, var_types, poisoned);
        },
    }
}

pub fn collectRaiseInfoExpr(self: *Codegen, expr: ast.Expr, info: *FuncSafetyInfo, class_ctx: ?[]const u8, var_types: *std.StringHashMapUnmanaged([]const u8), poisoned: *std.StringHashMapUnmanaged(void)) CodegenError!void {
    switch (expr) {
        // `await`/`spawn`: async istisna yayılımı ZATEN bilinçli olarak
        // eksik/ele alınmamış bir alan (bkz. nox-teknik-spesifikasyon.md
        // §3.21) — bu analiz oraya HİÇ dokunmaz, muhafazakâr kalır.
        .await_expr, .spawn_expr => info.direct_unsafe = true,
        // Faz P2.1 (bkz. proje belleği "generic sınıflar" planı): `Channel[T](
        // ...)`/`ThreadChannel[T](...)` (yerleşikler, `resolved_class_name`
        // HER ZAMAN `null`) Nox'un istisna mekanizmasına katılmaz (kendi
        // runtime çağrısı `emitExceptionCheck` KULLANMAZ) — GÜVENLİDİR,
        // davranış DEĞİŞMEDİ. Kullanıcı-tanımlı bir generic sınıf kurucusu
        // İSE (`resolved_class_name` DOLU) GERÇEK bir `__init__` çalıştırır
        // — `.call`in `.identifier` dalıyla (aşağıda, satır ~391) AYNI
        // desen: `has_init` İSE mangled `___init__` sembolü `info.callees`e
        // eklenir. (Not: `g.args` içindeki alt-ifadeler burada, `Channel`/
        // `ThreadChannel` dalıyla TUTARLI biçimde, YİNE de gezilmez — bu ayrı,
        // ÖNCEDEN VAR OLAN bir kısıttır, bu değişiklikle GENİŞLETİLMEDİ.)
        .generic_construct => |g| {
            if (g.resolved_class_name.*) |mangled| {
                const cinfo = self.classes.get(mangled) orelse return error.Unsupported;
                if (cinfo.has_init) {
                    const sym = try std.fmt.allocPrint(self.allocator, "{s}___init__", .{mangled});
                    try info.callees.append(self.allocator, sym);
                }
            }
        },
        .unary => |u| try self.collectRaiseInfoExpr(u.operand.*, info, class_ctx, var_types, poisoned),
        .binary => |b| {
            try self.collectRaiseInfoExpr(b.left.*, info, class_ctx, var_types, poisoned);
            try self.collectRaiseInfoExpr(b.right.*, info, class_ctx, var_types, poisoned);
        },
        .call => |c| {
            switch (c.callee.*) {
                .identifier => |name| {
                    if (self.classes.contains(name)) {
                        const cinfo = self.classes.get(name).?;
                        if (cinfo.has_init) {
                            const sym = try std.fmt.allocPrint(self.allocator, "{s}___init__", .{name});
                            try info.callees.append(self.allocator, sym);
                        }
                        // `has_init == false`: kurucu çağrısı hiçbir zaman
                        // `emitExceptionCheck` üretmez (bkz. `genConstruct`) —
                        // bağımlılık eklemeye gerek yok.
                    } else if (self.functions.contains(name)) {
                        try info.callees.append(self.allocator, name);
                    } else if (self.extern_functions.contains(name)) {
                        // `extern def`: Nox'un istisna mekanizmasına HİÇ
                        // katılmaz (bkz. `genCall`in extern dalı) — güvenli.
                    } else if (std.mem.eql(u8, name, "print") or std.mem.eql(u8, name, "len") or
                        std.mem.eql(u8, name, "str") or std.mem.eql(u8, name, "hpy_call") or
                        std.mem.eql(u8, name, "wasm_call"))
                    {
                        // `genCall`in KENDİ özel dispatch'iyle (satır ~4258
                        // civarı) TUTARLI, AÇIKÇA belgelenmiş "asla raise
                        // etmez" yerleşikler — `int`/`float` BİLEREK BU
                        // listede DEĞİL (`genParseOrRaise` ile GERÇEKTEN
                        // `ValueError` raise EDEBİLİRLER, bkz. checker.zig'in
                        // eşdeğer notu) — o ikisi AŞAĞIDAKİ `else` dalına
                        // düşüp MUHAFAZAKAR şekilde güvensiz sayılır.
                    } else {
                        // Faz M.8 (yeniden ele alındı, bkz. nox-teknik-
                        // spesifikasyon.md §3.59): BURASI ÖNCEDEN (bu
                        // `else` dalı hiç YOKTU) SESSİZCE hiçbir şey
                        // YAPMIYORDU — isim ne `self.classes` ne `self.
                        // functions`se (ör. bir iç içe closure'ı TUTAN
                        // yerel bir değişken/parametre) GÜVENLİ SAYILIYORDU,
                        // bu da GERÇEK bir istisnanın SESSİZCE YUTULMASINA
                        // yol açabilen, GERÇEKTEN doğrulanmış bir hataydı
                        // (bkz. `closure_raise_not_swallowed.nox` golden
                        // testi — düzeltmeden ÖNCE KIRMIZIYDI). BİLİNMEYEN
                        // bir çağrı hedefi HER ZAMAN güvensiz sayılır.
                        info.direct_unsafe = true;
                    }
                },
                // Metod çağrısı (`obj.method()`) — Faz M.8 (yeniden ele
                // alındı, bkz. nox-teknik-spesifikasyon.md §3.59): alıcı
                // ÇIPLAK bir yerel isimse VE o ismin sınıfı `var_types`
                // ÜZERİNDEN BİLİNİYORSA (ve isim `poisoned` DEĞİLSE),
                // hedef metod GERÇEK bir `callees` bağımlılığı olarak
                // eklenir (serbest fonksiyon çağrılarıyla AYNI muamele).
                // AKSİ HALDE (zincirleme çağrı, attribute-of-attribute,
                // index, ÇÖZÜLEMEYEN/poisoned isim, `self.classes`de
                // OLMAYAN bir tip — protokol/generic parametre gibi)
                // MUHAFAZAKÂR `direct_unsafe = true` davranışı KORUNUR.
                .attribute => |att| {
                    var resolved = false;
                    if (att.obj.* == .identifier) {
                        const recv_name = att.obj.identifier;
                        if (!poisoned.contains(recv_name)) {
                            if (var_types.get(recv_name)) |class_name| {
                                if (self.classes.get(class_name)) |cinfo| {
                                    if (cinfo.methods.contains(att.attr)) {
                                        const sym = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ class_name, att.attr });
                                        try info.callees.append(self.allocator, sym);
                                        resolved = true;
                                    }
                                }
                            }
                        }
                    }
                    if (!resolved) info.direct_unsafe = true;
                },
                else => info.direct_unsafe = true,
            }
            for (c.args) |a| try self.collectRaiseInfoExpr(a, info, class_ctx, var_types, poisoned);
        },
        .attribute => |a| try self.collectRaiseInfoExpr(a.obj.*, info, class_ctx, var_types, poisoned),
        .index => |idx| {
            try self.collectRaiseInfoExpr(idx.obj.*, info, class_ctx, var_types, poisoned);
            try self.collectRaiseInfoExpr(idx.index.*, info, class_ctx, var_types, poisoned);
        },
        .list_lit => |elems| for (elems) |el| try self.collectRaiseInfoExpr(el, info, class_ctx, var_types, poisoned),
        .dict_lit => |pairs| for (pairs) |p| {
            try self.collectRaiseInfoExpr(p.key, info, class_ctx, var_types, poisoned);
            try self.collectRaiseInfoExpr(p.value, info, class_ctx, var_types, poisoned);
        },
        .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => {},
    }
}

/// Performans fazı — `nox_exception_pending` çağrılarının (özyinelemeli/
/// küçük-fonksiyon-ağırlıklı kodda, bkz. `fib`in profillenmesi) baskın
/// bir maliyet olduğu bulundu. Bu fonksiyon, HER serbest fonksiyonun/
/// kurucunun (`__init__`) TRANSİTİF olarak ASLA istisna FIRLATAMAYACAĞINI
/// KANITLAYABİLDİĞİMİZ bir küme (`self.must_not_raise`) hesaplar —
/// `genCall`/`genConstruct` bu kümedeki bir çağrı SONRASI
/// `emitExceptionCheck`i ATLAYABİLİR.
///
/// **Bilinçli olarak MUHAFAZAKÂR (yanlış negatifte İSTİSNA ASLA
/// YUTULMAZ, yalnızca gereksiz bir kontrol FAZLADAN kalabilir):**
///   - Metod çağrıları (`obj.method()`) YALNIZCA alıcının sınıfı basit bir
///     yerel isim üzerinden `var_types` ile KANITLANABİLİYORSA (bkz. Faz
///     M.8, `collectRaiseInfoExpr`in `.attribute` dalı) gerçek bir
///     bağımlılığa çevrilir; ÇÖZÜLEMEYEN her alıcı (zincirleme çağrı,
///     tam tip çıkarımı gerektiren durumlar, `poisoned` bir isim) İÇİNDE
///     bulunduğu fonksiyonu/kurucuyu KOŞULSUZ güvensiz sayar.
///   - `await`/`spawn` içeren HERHANGİ bir gövde KOŞULSUZ güvensiz sayılır
///     (async istisna yayılımı zaten bilinçli olarak eksik bir alan).
///   - Sabit nokta (fixpoint) hesabı: `direct_unsafe` bulunanlarla
///     başlanır, sonra HERHANGİ bir çağrı hedefi (`callees`) güvensiz
///     kümedeyse çağıran da güvensiz kümeye eklenir — değişiklik
///     kalmayana kadar tekrarlanır (yalnızca BÜYÜYEN, sonlu bir küme,
///     bu yüzden sonlanması garantidir). Özyinelemeli fonksiyonlar
///     (ör. `fib`) doğru şekilde ele alınır: `fib` kendi kendini
///     çağırır, ama kendisi `direct_unsafe` değilse VE kendisi (henüz)
///     güvensiz kümede DEĞİLSE, bu öz-çağrı fixpoint'i ASLA tetiklemez —
///     `fib` güvenli kalır (doğru sonuç, çünkü `fib` GERÇEKTEN hiçbir
///     zaman raise etmez).
///
/// **Faz M.8 (yeniden ele alındı):** metodlar ARTIK `__init__` ile
/// SINIRLI değil — `cd.methods`deki HER metod analiz edilir, sembol
/// formatı TÜM metodlar için `"{class_name}_{method_name}"` (`genMethod`/
/// `genMethodCall`in KENDİ ÇAĞRI/TANIM sembolüyle BİREBİR aynı formül,
/// `__init__` özel durumu `"{s}___init__"` İLE ZATEN AYNI ŞEYDİR).
/// `obj.method()` çağrıları hâlâ VARSAYILAN olarak güvensizdir — YALNIZCA
/// alıcının sınıfı `var_types` ÜZERİNDEN kanıtlanabilir bir yerel isimse
/// (bkz. `collectRaiseInfoExpr`in `.attribute` dalı) gerçek bir `callees`
/// bağımlılığına çevrilir.
pub fn buildParamVarTypes(self: *Codegen, params: []const ast.Param, class_ctx: ?[]const u8) CodegenError!std.StringHashMapUnmanaged([]const u8) {
    var var_types: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (params) |p| {
        if (std.mem.eql(u8, p.name, "self")) {
            if (class_ctx) |cc| try var_types.put(self.allocator, p.name, cc);
        } else if (p.type_expr == .simple and self.classes.contains(p.type_expr.simple)) {
            try var_types.put(self.allocator, p.name, p.type_expr.simple);
        }
    }
    return var_types;
}

/// Faz GG.3 (bkz. nox-teknik-spesifikasyon.md §3.68): `buildParamVarTypes`in
/// AYNI deseni, ama `list[ClassName]` tipli parametreler İçin — `for x
/// in some_list_param:` kalıbının ZATEN M.8'in `.identifier` çözümlemesinden
/// FAYDALANABİLMESİ İçin GEREKİR (bkz. `collectRaiseInfoStmt`in
/// `.for_stmt` dalı).
pub fn buildParamListElemTypes(self: *Codegen, params: []const ast.Param) CodegenError!std.StringHashMapUnmanaged([]const u8) {
    var list_elem_types: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (params) |p| {
        if (p.type_expr != .generic) continue;
        const g = p.type_expr.generic;
        if (!std.mem.eql(u8, g.name, "list") or g.args.len != 1) continue;
        if (g.args[0] != .simple or !self.classes.contains(g.args[0].simple)) continue;
        try list_elem_types.put(self.allocator, p.name, g.args[0].simple);
    }
    return list_elem_types;
}

/// Faz GG.2 (bkz. nox-teknik-spesifikasyon.md §3.67): `computeMustNotRaise`
/// VE `computeInlinableFunctions`in İKİSİNİN de İHTİYAÇ DUYDUĞU whole-
/// program `FuncSafetyInfo` haritasını inşa eden ORTAK çekirdek —
/// ÖNCEDEN yalnızca `computeMustNotRaise`in İÇİNDEYDİ, GG.2'nin KENDİ
/// özyineleme-tespiti (`markRecursiveFuncs`) İçin AYNI çağrı-grafiği
/// bilgisine (`callees` listeleri) İHTİYACI olduğundan buraya
/// ÇIKARILDI (basit kod-taşıma, davranış DEĞİŞMEDİ).
pub fn buildFuncSafetyInfoMap(self: *Codegen, module: ast.Module, extra_functions: []const ast.FuncDef, extra_classes: []const ast.ClassDef) CodegenError!std.StringHashMapUnmanaged(FuncSafetyInfo) {
    var info_map: std.StringHashMapUnmanaged(FuncSafetyInfo) = .empty;

    for (module.body) |stmt| {
        switch (stmt.kind) {
            .func_def => |fd| {
                if (fd.is_async) continue; // async fonksiyonlar yalnızca `spawn` ile başlatılır, bu optimizasyonun çağrı sitelerinde hiç görünmezler.
                var info: FuncSafetyInfo = .{};
                var var_types = try self.buildParamVarTypes(fd.params, null);
                var poisoned: std.StringHashMapUnmanaged(void) = .empty;
                var list_elem_types = try self.buildParamListElemTypes(fd.params);
                try self.collectRaiseInfoStmts(fd.body, &info, null, &var_types, &poisoned, &list_elem_types);
                try info_map.put(self.allocator, fd.name, info);
            },
            .class_def => |cd| {
                for (cd.methods) |m| {
                    var info: FuncSafetyInfo = .{};
                    var var_types = try self.buildParamVarTypes(m.params, cd.name);
                    var poisoned: std.StringHashMapUnmanaged(void) = .empty;
                    var list_elem_types = try self.buildParamListElemTypes(m.params);
                    try self.collectRaiseInfoStmts(m.body, &info, cd.name, &var_types, &poisoned, &list_elem_types);
                    const sym = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ cd.name, m.name });
                    try info_map.put(self.allocator, sym, info);
                }
            },
            else => {},
        }
    }
    for (extra_functions) |fd| {
        if (fd.is_async) continue;
        var info: FuncSafetyInfo = .{};
        var var_types = try self.buildParamVarTypes(fd.params, null);
        var poisoned: std.StringHashMapUnmanaged(void) = .empty;
        var list_elem_types = try self.buildParamListElemTypes(fd.params);
        try self.collectRaiseInfoStmts(fd.body, &info, null, &var_types, &poisoned, &list_elem_types);
        try info_map.put(self.allocator, fd.name, info);
    }
    // Faz P2.1 (bkz. proje belleği "generic sınıflar" planı): `extra_functions`
    // İLE AYNI gerekçe — `module.body`nin `.class_def` dalı (YUKARIDA) YALNIZCA
    // ŞABLONLARI (VE generic-olmayan sıradan sınıfları) görür; checker'ın
    // ürettiği somut (monomorphize edilmiş) sınıfların metodları BURADA
    // eklenmezse, onlara yapılan çağrılar MUHAFAZAKÂR biçimde "belki fırlatır"
    // sayılır (GÜVENLİDİR ama inlining'i SESSİZCE devre dışı bırakır).
    for (extra_classes) |cd| {
        for (cd.methods) |m| {
            var info: FuncSafetyInfo = .{};
            var var_types = try self.buildParamVarTypes(m.params, cd.name);
            var poisoned: std.StringHashMapUnmanaged(void) = .empty;
            var list_elem_types = try self.buildParamListElemTypes(m.params);
            try self.collectRaiseInfoStmts(m.body, &info, cd.name, &var_types, &poisoned, &list_elem_types);
            const sym = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ cd.name, m.name });
            try info_map.put(self.allocator, sym, info);
        }
    }
    return info_map;
}

pub fn computeMustNotRaise(self: *Codegen, module: ast.Module, extra_functions: []const ast.FuncDef, extra_classes: []const ast.ClassDef) CodegenError!void {
    var info_map = try self.buildFuncSafetyInfoMap(module, extra_functions, extra_classes);

    // Dil stabilizasyonu fazı §M.1: ÖNCEDEN burada naif bir
    // `while (changed)` sabit-nokta döngüsü vardı — HER turda TÜM
    // `info_map`i (VE her fonksiyonun TÜM çağrı listesini) YENİDEN
    // tarardı; uzun bir çağrı zincirinde (A→B→C→…→Z, Z güvensiz)
    // güvensizlik HER turda yalnızca BİR sıçrama ilerlediğinden bu
    // O(F²) (fonksiyon SAYISININ karesi) idi. `core.nox` artık HER
    // programa koşulsuz dahil olduğundan F her zaman büyük bir taban
    // içeriyor — bu YÜZDEN bunun yerine TERS çağrı grafiği
    // (`callee -> callers`) ÖNCEDEN inşa edilip GERÇEK bir worklist
    // kullanılır: yalnızca YENİ güvensiz işaretlenen bir fonksiyonun
    // ÇAĞIRANLARI kuyruğa eklenir, HER düğüm/kenar EN FAZLA bir kez
    // işlenir — O(F+E).
    var callers_of: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
    {
        var it = info_map.iterator();
        while (it.next()) |entry| {
            const caller_name = entry.key_ptr.*;
            for (entry.value_ptr.callees.items) |callee| {
                const gop = try callers_of.getOrPut(self.allocator, callee);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(self.allocator, caller_name);
            }
        }
    }

    var unsafe_set: std.StringHashMapUnmanaged(void) = .empty;
    var worklist: std.ArrayListUnmanaged([]const u8) = .empty;
    {
        var it = info_map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.direct_unsafe) {
                try unsafe_set.put(self.allocator, entry.key_ptr.*, {});
                try worklist.append(self.allocator, entry.key_ptr.*);
            }
        }
    }
    while (worklist.pop()) |name| {
        const callers = callers_of.get(name) orelse continue;
        for (callers.items) |caller| {
            if (unsafe_set.contains(caller)) continue;
            try unsafe_set.put(self.allocator, caller, {});
            try worklist.append(self.allocator, caller);
        }
    }

    var it = info_map.iterator();
    while (it.next()) |entry| {
        if (!unsafe_set.contains(entry.key_ptr.*)) {
            try self.must_not_raise.put(self.allocator, entry.key_ptr.*, {});
        }
    }

    // `ClassInfo.init_is_safe`i doldur — `genConstruct`in tekrar tekrar
    // `"{s}___init__"` biçimlendirip `must_not_raise`de aramak yerine
    // doğrudan okuyabileceği tek bir alan (bkz. onun belge notu).
    var cit = self.classes.iterator();
    while (cit.next()) |entry| {
        if (!entry.value_ptr.has_init) continue;
        const sym = try std.fmt.allocPrint(self.allocator, "{s}___init__", .{entry.key_ptr.*});
        if (self.must_not_raise.contains(sym)) entry.value_ptr.init_is_safe = true;
    }
}

// ---- Faz GG.2: seçici serbest-fonksiyon inlining'i (bkz. nox-teknik-
// spesifikasyon.md §3.67) ----

/// Bir DFS yığınında (`stack`) hâlâ AKTİF olan bir isme geri-kenar (back-
/// edge) bulunursa, yığının O NOKTADAN SONRAKİ TÜMÜ (döngüdeki HER düğüm,
/// yalnızca doğrudan hedef DEĞİL) `self.recursive_funcs`e eklenir — bu,
/// A→B→C→A gibi ÇOK-düğümlü döngülerde B'nin de (yalnızca A/C değil)
/// doğru işaretlenmesini SAĞLAR. Derleme-zamanı-YALNIZCA bir geçiş
/// (çalışma zamanı maliyeti YOK) olduğundan, `callers_of`in O(F+E)
/// hassasiyeti BURADA GEREKMEZ — basit/okunabilir bir yığın-taraması
/// tercih edildi.
pub fn dfsMarkRecursive(self: *Codegen, name: []const u8, info_map: *const std.StringHashMapUnmanaged(FuncSafetyInfo), visited: *std.StringHashMapUnmanaged(void), stack: *std.ArrayListUnmanaged([]const u8)) CodegenError!void {
    try visited.put(self.allocator, name, {});
    try stack.append(self.allocator, name);
    if (info_map.get(name)) |info| {
        for (info.callees.items) |callee| {
            var cycle_start: ?usize = null;
            for (stack.items, 0..) |s, i| {
                if (std.mem.eql(u8, s, callee)) {
                    cycle_start = i;
                    break;
                }
            }
            if (cycle_start) |start| {
                for (stack.items[start..]) |cyc_name| {
                    try self.recursive_funcs.put(self.allocator, cyc_name, {});
                }
                continue;
            }
            if (!visited.contains(callee)) {
                try self.dfsMarkRecursive(callee, info_map, visited, stack);
            }
        }
    }
    _ = stack.pop();
}

/// `self.recursive_funcs`i doldurur — `computeInlinableFunctions`
/// TARAFINDAN, `buildFuncSafetyInfoMap`in (transitif çağrı grafiği İçin,
/// `computeMustNotRaise`in ZATEN inşa ettiğiyle AYNI YAPI) İKİNCİ, BAĞIMSIZ
/// bir çağrısıyla BİRLİKTE kullanılır.
pub fn markRecursiveFuncs(self: *Codegen, info_map: *const std.StringHashMapUnmanaged(FuncSafetyInfo)) CodegenError!void {
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    var it = info_map.iterator();
    while (it.next()) |entry| {
        if (!visited.contains(entry.key_ptr.*)) {
            var stack: std.ArrayListUnmanaged([]const u8) = .empty;
            try self.dfsMarkRecursive(entry.key_ptr.*, info_map, &visited, &stack);
        }
    }
}

/// Bir kullanıcı fonksiyonu/metodu/kurucu çağrısından hemen sonra çağrılır.
/// QBE hiçbir zaman unwind tablosu üretmez (İlke #3); bunun yerine bekleyen
/// bir istisna olup olmadığı burada AÇIKÇA kontrol edilir — Zig'in error
/// union'larına benzer örtük bir hata-döndürme zinciri. İçinde bulunulan
/// bir `try` varsa (`current_catch_label`) oraya, yoksa doğrudan bu
/// fonksiyonun erken (temizlenmiş) çıkışına dallanır.
pub fn emitExceptionCheck(self: *Codegen) CodegenError!void {
    const pending = try self.newTemp();
    try self.out.writer.print("    {s} =w call $nox_exception_pending(l {s})\n", .{ pending, RT_PARAM });
    const propagate_label = try self.newLabel("exc_propagate");
    const continue_label = try self.newLabel("exc_continue");
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ pending, propagate_label, continue_label });
    try self.out.writer.print("{s}\n", .{propagate_label});
    if (self.current_catch_label) |cl| {
        // Bu `try`nin kendi dispatch'ine giriyoruz — henüz onun korumalı
        // bölgesinden ÇIKMIYORUZ, bu yüzden `finally` burada DEĞİL,
        // dispatch'in kendi tamamlanma/yeniden-fırlatma yollarında çalışır.
        try self.out.writer.print("    jmp {s}\n", .{cl});
    } else if (self.in_main) {
        // Gerçekten dışarı sızıyoruz: aradan geçtiğimiz her `try`nin
        // `finally`'si ve her `lowlevel` arenası burada, program
        // sonlanmadan ÖNCE çalışmalıdır/yıkılmalıdır.
        try self.drainFinally(self.current_ret_qtype);
        try self.drainArenas();
        try self.drainDeferIfSet();
        // `nox_unhandled_exception` `noreturn`dur (process.exit çağırır),
        // ama QBE bunu bilmez — bloğun bir sonlandırıcıyla bitmesi için
        // savunmacı (asla çalışmayacak) bir `ret` gerekir.
        try self.out.writer.print("    call $nox_unhandled_exception(l {s})\n", .{RT_PARAM});
        try self.out.writer.writeAll("    ret 0\n");
    } else {
        try self.drainFinally(self.current_ret_qtype);
        try self.drainArenas();
        try self.drainDeferIfSet();
        try self.releaseAllLocals();
        try self.emitDefaultReturn(self.current_ret_qtype);
    }
    try self.out.writer.print("{s}\n", .{continue_label});
}
