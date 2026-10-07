//! Deyim (`ast.Stmt`) codegen çekirdeği — bkz. plan dosyası "QBE codegen
//! backend'ini alt modüllere bölme". `genStmts` (TÜM deyim üretiminin TEK
//! özyinelemeli dağıtım noktası) VE onun doğrudan alt-dalları (atama,
//! `if`/`while`/`for`, `lowlevel`) burada toplanır.

const std = @import("std");
const ast = @import("../parser/ast.zig");
const types = @import("types.zig");
const abi = @import("abi.zig");
const codegen = @import("codegen.zig");
const optimizations = @import("optimizations.zig");

const Codegen = codegen.Codegen;
const Value = types.Value;
const QbeType = types.QbeType;
const HeapKind = types.HeapKind;
const ElemHeapInfo = types.ElemHeapInfo;
const DictInfo = types.DictInfo;
const LocalDecl = types.LocalDecl;
const TypeInfo = types.TypeInfo;
const RT_PARAM = types.RT_PARAM;
const LIST_HEADER_SIZE = types.LIST_HEADER_SIZE;
const CodegenError = abi.CodegenError;
const qbeSizeOf = abi.qbeSizeOf;
const isHeapManaged = abi.isHeapManaged;
const isTemporaryExpr = abi.isTemporaryExpr;
const forListIdxName = abi.forListIdxName;
const collectReassignedNames = optimizations.collectReassignedNames;

pub fn genStmts(self: *Codegen, stmts: []const ast.Stmt, ret_qtype: QbeType) CodegenError!void {
    for (stmts, 0..) |stmt, stmt_idx| {
        // Faz T.3: bkz. modül üstü not — `genStmts` TÜM deyim kodgen'inin
        // TEK, özyinelemeli dağıtım noktası olduğundan (if/while/for/try
        // gövdeleri DAHİL), burada TEK bir `dbgloc` yayını HER deyimi
        // (iç içe olanlar DAHİL) otomatik kapsar (T.1'in `checkStmt`
        // deseniyle AYNI).
        if (self.debug_info and stmt.line > 0) {
            try self.qbeRaw("    dbgloc {d}\n", .{stmt.line});
        }
        // Faz OO.3: bkz. `current_raise_line`in belge notu — `dbgloc`den
        // BAĞIMSIZ, HER ZAMAN AÇIK.
        self.current_raise_line = stmt.line;
        switch (stmt.kind) {
            .return_stmt => |r| {
                // Faz GG.2 (bkz. nox-teknik-spesifikasyon.md §3.67): bir
                // inline-splice SIRASINDAYIZ (`genInlinedCall` tarafından
                // ayarlanmış) — gerçek bir `ret` YERİNE sonuç slotuna
                // yazıp `jmp` ile "bitti" etiketine gidilir; `drainFinally`/
                // `drainArenas` ATLANIR (uygunluk kuralı §1.2 bunları
                // GEREKSİZ kılar — inline edilebilir bir gövde ASLA `try`/
                // `with`/`lowlevel` İÇEREMEZ) VE yalnızca callee'nin KENDİ
                // isimleri (`t.owned_names`) serbest bırakılır, caller'ın
                // DİĞER yerellerine DOKUNULMAZ.
                if (self.inline_return_target) |t| {
                    if (r) |e| {
                        const v0 = try self.genExprForTarget(e, self.current_ret_info);
                        try self.checkNoLowlevelEscape(v0);
                        if (isHeapManaged(v0.heap) and self.returnNeedsRetain(e, v0)) {
                            try self.emitInlineRetain(v0.text, v0.heap);
                        } else if (self.isSpawnRefcountedType(v0.heap) and self.returnNeedsRetain(e, v0)) {
                            // v1.29.12: bkz. `ownership.zig`nin `isSpawnRefcountedType`
                            // belge notu — `Task[T]`/`Channel[T]`nin
                            // (VE `--release`de Task/Channel OLAN thread_handle/
                            // thread_channel'ın) `return`den de KOPYALANABİLDİĞİ
                            // (`return some_task_param` GİBİ) durum.
                            try self.retainNonArcValue(v0.text, v0.heap);
                        }
                        const v = try self.convert(v0, ret_qtype);
                        const except_name: ?[]const u8 = if (e == .identifier) e.identifier else null;
                        try self.releaseNamedLocalsExcept(t.owned_names, except_name);
                        if (t.result_slot) |rs| {
                            try self.qbeStore(ret_qtype, v.text, rs);
                        }
                    } else {
                        try self.releaseNamedLocalsExcept(t.owned_names, null);
                    }
                    try self.qbeJmp(t.done_label);
                    const label = try self.newLabel("after_inline_return");
                    try self.qbeLabel(label);
                    return;
                }
                if (r) |e| {
                    const v0 = try self.genExprForTarget(e, self.current_ret_info);
                    try self.checkNoLowlevelEscape(v0);
                    // Bir parametreyi ya da bir alan okumasını OLDUĞU
                    // GİBİ döndürmek, BAŞKA BİR YERDE ZATEN sahibi olan
                    // ödünç alınmış bir referansı dışarı vermektir —
                    // çağıran bunu kendi (yeni) bir sahipliğine
                    // bağlayabileceği için retain GEREKİR (bkz.
                    // `returnNeedsRetain`). Bu retain, aşağıdaki
                    // `releaseAllLocalsExcept`'TEN ÖNCE yapılmalıdır —
                    // aksi halde bu fonksiyonun kendi yerel temizliği
                    // (ör. döndürülen değere daha önce takma ad olmuş
                    // başka bir yerel) onu erken sıfıra indirebilirdi.
                    if (isHeapManaged(v0.heap) and self.returnNeedsRetain(e, v0)) {
                        try self.emitInlineRetain(v0.text, v0.heap);
                    } else if (self.isSpawnRefcountedType(v0.heap) and self.returnNeedsRetain(e, v0)) {
                        // v1.29.12: bkz. yukarıdaki inline-return dalının
                        // AYNI notu.
                        try self.retainNonArcValue(v0.text, v0.heap);
                    }
                    const v = try self.convert(v0, ret_qtype);
                    // Sıra önemli: finally/arena yıkımı, yereller hâlâ
                    // geçerliyken (serbest bırakılmadan ÖNCE) çalışmalıdır —
                    // aksi hâlde içlerindeki bir okuma, kullanım-sonrası-
                    // serbest-bırakma (use-after-free) olurdu.
                    try self.drainFinally(ret_qtype);
                    try self.drainArenas();
                    try self.drainFunctionArena();
                    try self.drainDeferIfSet();
                    const except_name: ?[]const u8 = if (e == .identifier) e.identifier else null;
                    try self.releaseAllLocalsExcept(except_name);
                    try self.qbeRet(v.text);
                } else {
                    try self.drainFinally(ret_qtype);
                    try self.drainArenas();
                    try self.drainFunctionArena();
                    try self.drainDeferIfSet();
                    try self.releaseAllLocalsExcept(null);
                    try self.qbeRet(null);
                }
                const label = try self.newLabel("after_return");
                try self.qbeLabel(label);
            },
            .var_decl => |v| {
                const info = self.vars.get(v.name).?;
                const v0 = try self.genExprForTarget(v.value, info);
                // GG.12 (bkz. nox-teknik-spesifikasyon.md §3.66):
                // `info.borrowed_field` — `selfFieldSnapshotEligible`nin
                // KANITLADIĞI, `self`in bir alanının salt-okunur/tek-
                // kullanım kopyası — retain'İ TAMAMEN atlar (`self` bu
                // metodun tüm aktivasyonu boyunca CANLI, alan hiç yeniden
                // atanmıyor, kopya hiçbir yere aktarılmıyor).
                const retained = if (info.borrowed_field) v0 else try self.retainIfAliasing(v.value, v0);
                const val = try self.convert(retained, info.qtype);
                // `.arena` bir yerelse (bir `lowlevel` bloğu içindeyse),
                // bu bildirim bir DÖNGÜ gövdesinde olabilir ve slot önceki
                // yinelemeden kalan bir işaretçi tutuyor olabilir — ama o
                // bellek zaten arenanın TOPLU `nox_arena_destroy`'u ile
                // serbest bırakılmıştır (bkz. `genLowLevel`). Burada normal
                // ARC serbest bırakmayı çağırmak, ZATEN serbest bırakılmış
                // belleği tekrar serbest bırakmaya (geçersiz free) yol açar.
                // GG.12: `borrowed_field` yerelleri de (arena YERELLERİYLE
                // AYNI gerekçeyle) ASLA bireysel release EDİLMEZ — slot
                // ZATEN sıfır kalır (`allocSlot` bunu `is_param` OLMAYAN
                // heap-yönetimli yerellerde `storel 0` İLE başlatır),
                // bu YÜZDEN `releaseSlotIfSet` burada ÇAĞRILMASA da
                // ZARARSIZDIR — ama tutarlılık İçin AÇIKÇA atlanır.
                if (isHeapManaged(info.heap) and !info.arena and !info.borrowed_field and !info.is_stack_local and !info.manual) {
                    try self.releaseSlotIfSet(info);
                } else if ((info.heap == .task or info.heap == .channel or info.heap == .thread_handle or info.heap == .thread_channel or info.heap == .task_local) and !info.arena and !info.borrowed_field and !info.is_stack_local and !info.manual) {
                    // **GERÇEK, DENEYEREK BULUNAN sızıntı**: `genAssign`nin
                    // `.identifier` dalı (BURADAN AŞAĞIDA) `Task[T]`/
                    // `Channel[T]`/vb. tipli bir DEĞİŞKENE yeniden atama
                    // yapıldığında `destroyNonArcSlotIfSet` İLE eski değeri
                    // yok eder — AMA bu AYNI çağrı BURADA (`.var_decl`)
                    // EKSİKTİ. `t: Task[int] = spawn ...` GİBİ tip
                    // ANOTASYONLU bir bildirim bir `while`/`for` GÖVDESİNDE
                    // (Nox'ta HER yineleme "yeni" bir yerel değişken doğuşu
                    // sayılır) YAZILDIĞINDA, ÜRETİLEN kod TEK bir `.var_decl`
                    // sitesidir — RUNTIME'da HER yinelemede TEKRAR ÇALIŞIR VE
                    // slotun İÇİNDEKİ BİR ÖNCEKİ yinelemenin `Task`ını
                    // SERBEST BIRAKMADAN üzerine yazardı (`benchmarks/
                    // async_task_churn.nox`, 500k yinelemede yineleme
                    // başına TAM OLARAK BİR `Task(T)` struct'ı sızdırdığı
                    // DebugAllocator İLE doğrulandı). Düzeltme, `.identifier`
                    // dalıyla AYNI: üzerine yazmadan ÖNCE eskiyi yok et.
                    // `destroyNonArcValue` slotun İLK yazımında (henüz
                    // sıfır/`null` İKEN) de ÇAĞRILDIĞINDAN, ARTIK karşılık
                    // gelen `nox_*_destroy` fonksiyonlarının (bridge.zig)
                    // TÜMÜ `orelse return` İLE null-güvenli (bkz. onların
                    // belge notu).
                    try self.destroyNonArcSlotIfSet(info);
                }
                try self.qbeStore(info.qtype, val.text, info.slot);
                // Bkz. `Codegen.mod_cache`nin belge notu, madde 2: bu
                // slota YENİ bir değer YAZILDI — o slot İçin ÖNCEKİ TÜM
                // `%d`-önbellek girdileri BAYATLADI.
                try self.modCacheInvalidateSlot(info.slot);
            },
            .assign => |a| {
                try self.genAssign(a);
                if (a.target == .identifier) try self.modCacheInvalidateName(a.target.identifier);
            },
            .expr_stmt => |e| {
                const v = try self.genExpr(e);
                // Tamamen dolaylanmış (hiçbir yere bağlanmamış) bir taze
                // heap değeri (ör. bir çağrının sonucunu bir deyim olarak
                // kullanmak) sızmaz — bkz. `releaseIfTemporary`.
                try self.releaseIfTemporary(e, v);
            },
            .if_stmt => |f| try self.genIf(f, ret_qtype),
            .while_stmt => |w| {
                const saved_bounds_ctx = self.bounds_elide_ctx;
                self.bounds_elide_ctx = try self.detectWhileBoundsElideCtx(stmts, stmt_idx, w);
                try self.genWhile(w, ret_qtype);
                self.bounds_elide_ctx = saved_bounds_ctx;
            },
            .for_stmt => |f| try self.genFor(f, ret_qtype),
            .raise_stmt => |e| try self.genRaise(e),
            .del_stmt => |e| try self.genDel(e),
            .try_stmt => |t| try self.genTry(t, ret_qtype),
            .lowlevel_stmt => |ll| try self.genLowLevel(ll, ret_qtype),
            .pass_stmt => {},
            .break_stmt => try self.genLoopJump(true),
            .continue_stmt => try self.genLoopJump(false),
            .func_def => |fd| try self.genNestedFuncDef(fd),
            .with_stmt => |w| try self.genWith(w, stmt.line, ret_qtype),
            .defer_stmt => |d| try self.genDeferStmt(d, stmt.line),
            .class_def, .protocol_def, .extern_def, .import_stmt, .from_import_stmt => return error.Unsupported,
        }
    }
}

/// Bir `lowlevel:` bloğu için yeni bir arena oluşturur, blok boyunca
/// `arena_stack`'e iter (böylece `genConstruct`/`genListLit` bu arenadan
/// tahsis eder), gövdeyi üretir ve normal tamamlanmada arenayı yıkar.
/// Gövde içinde bir `return`/yakalanmamış istisna olduysa, o çıkış yolu
/// `drainArenas` ile arenayı ZATEN yıkmıştır — bu durumda buradaki yıkım
/// çağrısı erişilemez (ölü) koddur, `genTry`'deki eşdeğer durum gibi.
///
/// GG.15 (bkz. nox-teknik-spesifikasyon.md §3.66): `prepareInlineSites`in
/// (`.lowlevel_stmt` dalından `scanStackConstructSites` ÜZERİNDEN) BU
/// AYNI `ll.body`YE daha ÖNCE (fonksiyon GİRİŞİNDEYKEN) baktığı VE
/// İÇİNDEKİ TÜM inşaların (en az BİR tane VARSA) yığın slotlarına
/// dönüştürüldüğü KANITLANMIŞSA (`self.lowlevel_arena_elidable`), `nox_
/// arena_create`/`destroy` çifti TAMAMEN ATLANIR — ama `arena_stack`e
/// YİNE DE bir GİRDİ (`.elided=true`) İTİLİR: `Value.arena`/`checkNoLowlevel
/// Escape`nin "BU değer lowlevel kapsamına AİT" ayrımı DEĞİŞMEMELİDİR
/// (SADECE gerçek `nox_arena_alloc` çağrıları elenir).
pub fn genLowLevel(self: *Codegen, ll: ast.LowLevelStmt, ret_qtype: QbeType) CodegenError!void {
    const elided = self.lowlevel_arena_elidable.get(@intFromPtr(ll.body.ptr)) orelse false;
    if (elided) {
        try self.arena_stack.append(self.allocator, .{ .handle = "0", .elided = true });
    } else {
        const arena_temp = try self.newTemp();
        try self.qbeCall(.{ .name = arena_temp, .ty = .l }, "$nox_arena_create", &.{.{ .ty = .l, .text = RT_PARAM }});
        try self.arena_stack.append(self.allocator, .{ .handle = arena_temp, .elided = false });
    }
    self.in_lowlevel_depth += 1;
    try self.genStmts(ll.body, ret_qtype);
    self.in_lowlevel_depth -= 1;
    const entry = self.arena_stack.pop().?;
    if (!entry.elided) {
        try self.qbeCall(null, "$nox_arena_destroy", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = entry.handle } });
    }
}

/// v1.142.17: `s = s + a + b ...` (yerel `str` değişkeni; ekleme ifadelerinde `s` geçmiyor) —
/// her ekleme tüm dizeyi kopyalayan O(n²) birleştirme yerine `nox_str_append` ile yerinde
/// büyütme (bkz. `runtime/str.zig`). Operandlar ÖNCE (kaynak sırasıyla) değerlendirilir; bir
/// istisna `s`yi yarım değiştirmez. Desen AST düzeyinde doğrulanır (kod yayılmadan `false`).
fn tryGenStrAppendAssign(self: *Codegen, name: []const u8, info: types.VarInfo, a: ast.Assign) CodegenError!bool {
    if (info.heap != .str or info.is_param or info.arena or info.borrowed_field or info.is_stack_local or info.manual) return false;
    if (a.value != .binary) return false;
    var rights: std.ArrayListUnmanaged(ast.Expr) = .empty;
    defer rights.deinit(self.allocator);
    var cur: ast.Expr = a.value;
    while (cur == .binary and cur.binary.op == .add) {
        try rights.append(self.allocator, cur.binary.right.*);
        cur = cur.binary.left.*;
    }
    if (rights.items.len == 0) return false;
    if (cur != .identifier or !std.mem.eql(u8, cur.identifier, name)) return false;
    for (rights.items) |r| {
        if (optimizations.exprMentionsName(r, name)) return false;
    }

    const n = rights.items.len;
    const values = try self.allocator.alloc(Value, n);
    const exprs = try self.allocator.alloc(ast.Expr, n);
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const e = rights.items[n - 1 - k];
        exprs[k] = e;
        const v = try self.genExpr(e);
        if (v.heap != .str) return error.Unsupported;
        try self.checkNoLowlevelEscape(v);
        values[k] = v;
    }
    var acc = try self.newTemp();
    try self.qbeLoadL(acc, info.slot);
    for (values) |v| {
        const res = try self.newTemp();
        try self.qbeCall(.{ .name = res, .ty = .l }, "$nox_str_append", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = acc }, .{ .ty = .l, .text = v.text } });
        acc = res;
    }
    try self.qbeStoreL(acc, info.slot);
    for (values, 0..) |v, i| try self.releaseIfTemporary(exprs[i], v);
    return true;
}

pub fn genAssign(self: *Codegen, a: ast.Assign) CodegenError!void {
    switch (a.target) {
        .identifier => |name| {
            if (self.vars.get(name)) |info| {
                if (try tryGenStrAppendAssign(self, name, info, a)) return;
                const v0 = try self.genExprForTarget(a.value, info);
                // v1.156.0: yeniden atama, kutulu Optional'ın daraltma (unbox) durumunu geçersiz kılar (checker `checkAssign`in aynası: RHS
                // eski daraltmayla okunur, sonrasındaki okumalar Optional'dır).
                _ = self.narrowed_unbox.remove(name);
                // v3 madde 3 (ownership/ptr[T] red-team, bkz. nox-teknik-
                // spesifikasyon.md ilgili bölüm): **DÜZELTME (GERÇEK, bir
                // kaçış-taramasında BULUNAN bir hata)** — `.attribute`
                // ataması (aşağıda) `checkNoLowlevelEscape`i HEM alıcı HEM
                // YENİ değer İçİn çağırır ("bir isme atamakla AYNI anlamı
                // taşır" — bkz. onun belge notu); BU dal (düz `<isim> =
                // <değer>`, TAM OLARAK AYNI "kalıcı paylaşım" anlamını
                // taşır) bu çağrıyı EKSİK bırakıyordu — bir arena değeri
                // (ör. `lowlevel:` İÇİNDE `pt = Point(...)`) arena-DIŞI bir
                // slota SESSİZCE yazılabiliyordu, arena yıkılınca DANGLING
                // bir işaretçi bırakarak (GERÇEK bir SIGBUS İLE KANITLANDI).
                try self.checkNoLowlevelEscape(v0);
                const retained = try self.retainIfAliasing(a.value, v0);
                const val = try self.convert(retained, info.qtype);
                // Bkz. `var_decl` kolundaki aynı gerekçe: arena yerelleri asla
                // ARC ile serbest bırakılmaz (arenanın toplu yıkımı zaten
                // bunu yapar) — aksi halde döngü içinde yeniden atama, önceki
                // yinelemede zaten yıkılmış bir arenaya ait belleği tekrar
                // serbest bırakmaya çalışır. **DÜZELTME (v3 madde 3): `var_decl`nin
                // AYNI korumasıyla (`stmt.zig`nin YUKARISI) TAM eşleşecek
                // şekilde `!info.borrowed_field`/`!info.is_stack_local`/
                // `!info.manual` de EKLENDİ** — SONUNCUSU EKSİK OLDUĞUNDAN
                // `detach()` edilmiş bir değişkene yeniden atama, HÂLÂ CANLI
                // olan ham `ptr`ı ARC'nin ERKEN serbest bırakmasına yol
                // açıyordu (GERÇEK bir SIGSEGV İLE KANITLANDI).
                if (isHeapManaged(info.heap) and !info.is_param and !info.arena and !info.borrowed_field and !info.is_stack_local and !info.manual) {
                    try self.releaseSlotIfSet(info);
                } else if ((info.heap == .task or info.heap == .channel or info.heap == .thread_handle or info.heap == .thread_channel or info.heap == .task_local) and !info.is_param and !info.arena and !info.borrowed_field and !info.is_stack_local and !info.manual) {
                    // Faz S.1: `Task[T]`/`Channel[T]`/`ThreadHandle[T]`/
                    // `ThreadChannel[T]` yeniden atamada ESKİ değer artık
                    // sızmaz — `destroyNonArcSlotIfSet`
                    // (bkz. onun belge notu, `Task` İÇİN `nox_async_destroy_task`nin
                    // GÜVENLİ ertelenmiş yıkım semantiği) mevcut slot değerini
                    // YENİ değer BURAYA yazılmadan ÖNCE yok eder.
                    try self.destroyNonArcSlotIfSet(info);
                }
                try self.qbeStore(info.qtype, val.text, info.slot);
                return;
            }
            // Bulundu (bkz. proje belleği "modül-seviyesi global durum"
            // planı): yerel BAŞARISIZ olursa modül-seviyesi bir global
            // yazması denenir — `.attribute` yazmasıYLA (aşağıda) AYNI
            // "eski değeri yükle → yeni değeri yaz → eskiyi serbest
            // bırak" deseni.
            const g = self.module_globals.get(name) orelse return error.Unsupported;
            const v0 = try self.genExprForTarget(a.value, g.info);
            const retained = try self.retainIfAliasing(a.value, v0);
            const val = try self.convert(retained, g.info.qtype);
            const block = try self.newTemp();
            try self.qbeCall(.{ .name = block, .ty = .l }, "$nox_globals_get", &.{.{ .ty = .l, .text = RT_PARAM }});
            const addr = try self.newTemp();
            try self.qbeOp2Imm(addr, .l, "add", block, @intCast(g.offset));
            if (isHeapManaged(g.info.heap)) {
                const old_ptr = try self.newTemp();
                try self.qbeLoadL(old_ptr, addr);
                try self.qbeStore(g.info.qtype, val.text, addr);
                try self.releaseValueIfSet(old_ptr, g.info.heap, g.info.elem_qtype, g.info.class_name, g.info.elem_heap_info, g.info.dict_info);
            } else {
                try self.qbeStore(g.info.qtype, val.text, addr);
            }
        },
        .attribute => |attr| {
            // Genel durum (bkz. checker.zig'in `checkAssign`indeki AYNI
            // genelleme): `<ifade>.<alan> = <değer>` — `<ifade>` HERHANGİ
            // bir sınıf örneğine değerlenebilir, `self` OLMAK ZORUNDA
            // DEĞİL. `obj`, bir metod çağrısının ALICISI gibi (bkz.
            // `genMethodCall`) TAZE bir değer OLABİLİR — bu yüzden aynı
            // "lowlevel kaçışını engelle" + "taze ise sonda serbest
            // bırak" deseni burada da uygulanır.
            const obj = try self.genExpr(attr.obj.*);
            if (obj.heap != .class) return error.Unsupported;
            try self.checkNoLowlevelEscape(obj);
            const cinfo = self.classes.get(obj.class_name.?).?;
            for (cinfo.fields.items) |f| {
                if (!std.mem.eql(u8, f.name, attr.attr)) continue;
                const v0 = try self.genExprForTarget(a.value, f.info);
                // Bir sınıf alanına atamak, bir isme atamakla (`y = x`)
                // aynı anlamı taşır: nesne artık bu değeri KALICI olarak
                // paylaşıyor — bu yüzden aynı takma ad/kaçış kuralları
                // uygulanır (bkz. `retainIfAliasing`/`checkNoLowlevelEscape`).
                try self.checkNoLowlevelEscape(v0);
                const retained = try self.retainIfAliasing(a.value, v0);
                const val = try self.convert(retained, f.info.qtype);
                const addr = try self.newTemp();
                try self.qbeOp2Imm(addr, .l, "add", obj.text, @intCast(f.offset));
                if (isHeapManaged(f.info.heap)) {
                    // Üzerine yazılacak ESKİ değeri önce oku (adres henüz
                    // üzerine yazılmadı), yeni değeri sakla, SONRA eskiyi
                    // serbest bırak — aksi halde eski nesne sonsuza dek
                    // sızardı (kendi refcount'u hiç azalmazdı).
                    const old_ptr = try self.newTemp();
                    try self.qbeLoadL(old_ptr, addr);
                    try self.qbeStore(f.info.qtype, val.text, addr);
                    try self.releaseValueIfSet(old_ptr, f.info.heap, f.info.elem_qtype, f.info.class_name, f.info.elem_heap_info, f.info.dict_info);
                } else if (f.info.heap == .task or f.info.heap == .channel or f.info.heap == .thread_handle or f.info.heap == .thread_channel or f.info.heap == .task_local) {
                    // Faz S.1: `isHeapManaged`in DIŞINDaki DÖRT tür İÇİN de
                    // (yukarıdaki dalla AYNI "önce oku, SONRA üzerine yaz,
                    // SONRA eskiyi yok et" sırası) — bkz. `destroyNonArcValue`.
                    const old_ptr = try self.newTemp();
                    try self.qbeLoadL(old_ptr, addr);
                    try self.qbeStore(f.info.qtype, val.text, addr);
                    try self.destroyNonArcValue(old_ptr, f.info.heap);
                } else {
                    // v2.0 madde 5: SADECE bu (skaler) dal `narrowStore`
                    // gerektirir — yukarıdaki İKİ dal HER ZAMAN 8-baytlık
                    // pointer alanlarını (heap-yönetimli/task-benzeri)
                    // hedefler, bunlar ASLA daralmaz.
                    try self.narrowStore(val.text, f.info, cinfo.layout_mode, addr);
                }
                try self.releaseIfTemporary(attr.obj.*, obj);
                return;
            }
            return error.Unsupported;
        },
        // `d[key] = value` (dict) / `xs[i] = value` (list, Faz U.1) —
        // checker.zig'in `checkAssign`i BU İKİSİNİ dışında hiçbir tipi
        // GEÇİRMEZ, bu yüzden `idx.obj`in ÇÖZÜLEN tipine göre AYIRT
        // ETMEK için tekrar `genExpr` ÇAĞIRMAK YERİNE (iki kez
        // değerlendirme YAN ETKİ riski taşırdı) doğrudan alt fonksiyonlara
        // devredilir — `genListAssign`/`genDictAssign`in İKİSİ de
        // `obj.heap`i KENDİLERİ kontrol edip UYUŞMAZSA `error.Unsupported`
        // döner, bu yüzden BURADA sırayla DENEME GÜVENLİDİR: hiçbiri
        // `idx.obj`i genExpr'DEN önce başka BİR YAN ETKİ üretmez.
        // `d[key] = value` (dict) / `xs[i] = value` (list, Faz U.1) —
        // `idx.obj`, `genIndex`in (OKUMA yönü) İLE AYNI GEREKÇEYLE, TEK
        // SEFER değerlendirilir (`idx.obj` KEYFİ bir ifade OLABİLİR —
        // ör. `self.items[i] = v`, YALNIZCA çıplak bir isim DEĞİL —
        // checker ZATEN bunu genelleştirdi) VE sonucun `.heap`ine göre
        // `genListAssign`/`genDictAssign`e (İKİSİ de ARTIK ham `idx`
        // yerine ÖNCEDEN değerlendirilmiş `obj`u ALIR) dağıtılır.
        .index => |idx| {
            const obj = try self.genExpr(idx.obj.*);
            if (obj.heap == .list) return self.genListAssign(obj, idx, a.value);
            return self.genDictAssign(obj, idx, a.value);
        },
        else => return error.Unsupported,
    }
}

/// `xs[i] = value` — Faz U.1. `genIndex`in list dalıyla AYNI "önce
/// doğrula, hata dalında raise et, phi'SİZ ok'e atla" sınır-kontrolü
/// desenini (bkz. Faz S.2) YENİDEN kullanır; eski eleman heap-yönetimli
/// İSE `genAssign`in `.attribute` kolundaki AYNI "önce ESKİYİ oku, YENİ
/// değeri yaz, SONRA eskiyi serbest bırak" sırasını izler. `obj` (ÇAĞIRAN
/// TARAFINDAN önceden değerlendirilmiş) her ZAMAN `.heap == .list`
/// GARANTİLİDİR (bkz. `genAssign`in `.index` dalı).
///
/// v4 Faz A madde 5 (bkz. nox-teknik-spesifikasyon.md §3.2xx) — GERÇEK,
/// önceden keşfedilmemiş bir hata: BU fonksiyon ÖNCEDEN `obj` (ALICI
/// listenin KENDİSİ) üzerinde `checkNoLowlevelEscape` ÇAĞIRIYORDU — ASAP
/// (Katman 1) `xs: list[u8] = [...]` GİBİ KAÇMAYAN (escape-safe) bir
/// listeyi ARENA'ya sınıflandırdığında (`obj.arena == true`), BU kontrol
/// `xs[i] = v`yi (SAF bir YERİNDE MUTASYON — `genIndex`in OKUMA yolu,
/// AŞAĞIDAKİ SATIR SATIR AYNI `obj.text` adresini kullanır, HİÇBİR
/// `checkNoLowlevelEscape` ÇAĞIRMAZ) YANLIŞLIKLA "bilinmeyen tip: T"
/// SINIFI bir `error.Unsupported`la reddediyordu — bir ARENA değerinin
/// KENDİ ADRESİNE yazmak, o değeri HİÇBİR yere "kaçırmaz" (aksine, `genIndex`
/// İLE TAM SİMETRİK, GÜVENLİ bir işlemdir). Kontrol SİLİNDİ — `value_v0`
/// (YENİ yazılan DEĞER, aşağıda) üzerindeki AYRI `checkNoLowlevelEscape`
/// çağrısı (GERÇEKTEN bir arena-değerinin LİSTEYE kaçmasını önlediği İçİn)
/// KORUNDU, DEĞİŞMEDİ.
pub fn genListAssign(self: *Codegen, obj: Value, idx: ast.Index, value_expr: ast.Expr) CodegenError!void {
    if (obj.heap != .list) return error.Unsupported;
    const index_v = try self.genExpr(idx.index.*);

    const len_t = try self.newTemp();
    try self.qbeLoadL(len_t, obj.text);
    // v1.142.5: `idx < 0 or idx >= len` TEK işaretsiz karşılaştırma: negatif indeks
    // işaretsiz yorumlandığında ≥ 2^63 > len olur (3 işlem → 1).
    const oob_t = try self.newTemp();
    try self.qbeOp2(oob_t, .w, "cugel", index_v.text, len_t);
    const err_label = try self.newLabel("list_assign_err");
    const ok_label = try self.newLabel("list_assign_ok");
    try self.qbeJnzCold(oob_t, err_label, ok_label);
    const cold_start = self.beginCold();
    try self.qbeLabel(err_label);

    const msg_value = try self.emitStringLiteral("liste indeksi sinirlarin disinda");
    const ie_cinfo = self.classes.get("IndexError") orelse return error.Unsupported;
    const ie_obj = try self.genConstructFromValues("IndexError", ie_cinfo, &.{msg_value}, null);
    try self.emitExceptionLineStore(ie_obj.text, "IndexError", self.current_raise_line);
    try self.qbeCall(null, "$nox_raise", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ie_obj.text }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{self.current_raise_line}) } });
    // Bkz. `genIndex`in AYNI belge notu — Faz NN kök-neden düzeltmesinden
    // (bkz. `ownership.zig`nin `releaseNamedLocalsExcept`i) SONRA GÜVENLE
    // yeniden eklendi, döngü testiyle DOĞRULANDI.
    try self.releaseIfTemporary(idx.obj.*, obj);
    try self.emitRaisePropagate();
    try self.stashCold(cold_start);

    try self.qbeLabel(ok_label);
    const value_v0 = try self.genExpr(value_expr);
    try self.checkNoLowlevelEscape(value_v0);
    const retained = try self.retainIfAliasing(value_expr, value_v0);
    const val = try self.convert(retained, obj.elem_qtype);

    const byte_off = try self.newTemp();
    try self.qbeOp2Imm(byte_off, .l, "mul", index_v.text, @intCast(qbeSizeOf(obj.elem_qtype)));
    const off16 = try self.newTemp();
    try self.qbeOp2Imm(off16, .l, "add", byte_off, @intCast(LIST_HEADER_SIZE));
    const addr = try self.newTemp();
    try self.qbeOp2(addr, .l, "add", obj.text, off16);

    // v2.0 madde 4 (Faz D): `elem_heap_info != null` ARTIK "eleman HEAP-
    // yönetimli" ANLAMINA GELMİYOR (`list[u8]` GİBİ skaler-AMA-sabit-
    // genişlikli elemanların da `elem_heap_info`si DOLU) — `isHeapManaged`
    // KONTROLÜ olmadan bu dal, `old_ptr`e YÜKLENEN HAM bir SKALER değeri
    // (adres DEĞİL) `releaseValueIfSet`e geçirip onu bir `list` SANIP
    // (fonksiyonun KENDİ `else` dalı) KEYFİ bir bellek adresini
    // list-başlığı gibi OKUMAYA ÇALIŞIRDI — GERÇEK bir bellek bozulması/
    // çökme riski (ÇALIŞTIRILMADAN ÖNCE fark edilip DÜZELTİLDİ).
    const elem_needs_release = (if (obj.elem_heap_info) |ehi| isHeapManaged(ehi.heap) else false) or obj.elem_is_str;
    if (elem_needs_release) {
        const old_ptr = try self.newTemp();
        try self.qbeLoadL(old_ptr, addr);
        try self.qbeStore(obj.elem_qtype, val.text, addr);
        const elem_heap: HeapKind = if (obj.elem_heap_info) |ehi| ehi.heap else .str;
        const elem_class_name: ?[]const u8 = if (obj.elem_heap_info) |ehi| ehi.class_name else null;
        const elem_inner_qtype: QbeType = if (obj.elem_heap_info) |ehi| ehi.elem_qtype else .none;
        const elem_nested: ?*const ElemHeapInfo = if (obj.elem_heap_info) |ehi| ehi.nested else null;
        // Bulundu (nyx framework — bkz. proje belleği "NOX_LIMITATIONS.md
        // incelemesi", C1): ÖNCEDEN burada SABİT `null` geçiriliyordu —
        // `list[dict[...]]`e İNDEKSLE atama (`xs[i] = {...}`) `releaseValueIfSet`in
        // `.dict` dalına (bkz. onun belge notu) `dict_info == null` İLE
        // ULAŞIP `dinfo.?` üzerinde bir Zig optional-unwrap PANİĞİYLE
        // (derleyicinin KENDİSİ çökerdi, Nox-seviyesi bir hata DEĞİL)
        // ÇÖKERDİ. `elem_heap_info.dict_info` BURADAN DOĞRU akıtılır.
        const elem_dict_info: ?*const DictInfo = if (obj.elem_heap_info) |ehi| ehi.dict_info else null;
        try self.releaseValueIfSet(old_ptr, elem_heap, elem_inner_qtype, elem_class_name, elem_nested, elem_dict_info);
    } else {
        try self.qbeStore(obj.elem_qtype, val.text, addr);
    }
    try self.releaseIfTemporary(idx.obj.*, obj);
}

/// `d[key] = value` — `nox_dict_set`e lowerlanır (bkz. `genDictLit`in
/// belge notu, AYNI "sahiplik çağırandan devralınır" ilkesi). Anahtar/
/// değer, bir isme atamakla (`y = x`) AYNI takma ad kuralına tabidir
/// (`retainIfAliasing`) — `nox_dict_set`in KENDİSİ (runtime tarafında)
/// yalnızca bir anahtar ZATEN VARSA eski değeri (VE `str` ise eski
/// değeri/anahtarı) serbest bırakır (bkz. `runtime/collections/dict.zig`).
/// `obj` (ÇAĞIRAN TARAFINDAN önceden değerlendirilmiş) `.heap != .dict`
/// İSE (Faz U.1'den beri — `genAssign`in `.index` dalı ARTIK `list`i
/// de yönlendirebildiğinden) `error.Unsupported` döner.
pub fn genDictAssign(self: *Codegen, obj: Value, idx: ast.Index, value_expr: ast.Expr) CodegenError!void {
    if (obj.heap != .dict) return error.Unsupported;
    try self.checkNoLowlevelEscape(obj);
    const dinfo = obj.dict_info.?;

    const key_v0 = try self.genExpr(idx.index.*);
    try self.checkNoLowlevelEscape(key_v0);
    const key_v = try self.retainIfAliasing(idx.index.*, key_v0);

    const value_v0 = try self.genExpr(value_expr);
    try self.checkNoLowlevelEscape(value_v0);
    const value_v = try self.retainIfAliasing(value_expr, value_v0);
    const value_converted = try self.convert(value_v, dinfo.value_qtype);

    const key_payload = try self.toPayload(key_v);
    const value_payload = try self.toPayload(value_converted);
    const key_is_str_lit: []const u8 = if (dinfo.key_is_str) "1" else "0";
    const value_is_str_lit: []const u8 = if (dinfo.value_is_str) "1" else "0";
    const value_is_class_lit: []const u8 = if (dinfo.valueIsArc()) "1" else "0";
    try self.qbeCall(null, "$nox_dict_set", &.{
        .{ .ty = .l, .text = RT_PARAM },
        .{ .ty = .l, .text = obj.text },
        .{ .ty = .w, .text = key_is_str_lit },
        .{ .ty = .w, .text = value_is_str_lit },
        .{ .ty = .w, .text = value_is_class_lit },
        .{ .ty = .l, .text = key_payload.text },
        .{ .ty = .l, .text = value_payload.text },
    });
    try self.releaseIfTemporary(idx.obj.*, obj);
}

/// `d[key]` (okuma) — `nox_dict_get`e lowerlanır. BORROWED bir okumadır
/// (`list[T]` eleman okumasıyla AYNI — dict `str` değerin sahipliğini
/// KORUR, dönen değer retain EDİLMEZ). `key_expr` TAZE bir heap değerse
/// (ör. `d["a" + "b"]`), arama SONRASI serbest bırakılır (`nox_dict_get`
/// anahtarı SAKLAMAZ, yalnızca hash/eşitlik için ÖDÜNÇ kullanır).
///
/// **Güvenlik bulgusu H-2 (bkz. güvenlik raporu) — DÜZELTİLDİ:** eksik
/// bir anahtarda `nox_dict_get` SESSİZCE `0` (null) dönüyordu VE bu
/// değer normal, opsiyonel-olmayan bir `str`/`list`/`class` gibi ileri
/// taşınıyordu — `len()`/indeksleme/birleştirme gibi HERHANGİ bir
/// sonraki kullanım null-pointer çökmesine (`d: dict[str,str] =
/// {"a":"1"}; print(len(d["missing"]))` → SIGSEGV) yol açıyordu.
/// `genIndex`in `list[T]` sınır kontrolüyle AYNI "önce doğrula, hata
/// dalında raise et, phi'siz ok'e atla" deseni İZLENİR: `nox_dict_
/// contains` İLE ÖNCE VARLIK kontrol edilir, yoksa `KeyError` raise
/// edilir — `int`/`float`/`bool` değer TİPLERİ İçin BİLE (ör.
/// `dict[str,int]`de saklı bir `0` DEĞERİYLE "anahtar YOK" durumunu
/// AYIRT ETMEK GEREKTİĞİNDEN, `nox_dict_get`in KENDİ dönüş değerine
/// GÜVENMEK ASLA YETERLİ DEĞİLDİ — bu AYRICA bağımsız bir doğruluk
/// hatasıydı, yalnızca bellek güvenliği DEĞİL).
pub fn genDictGet(self: *Codegen, obj_expr: ast.Expr, obj: Value, key_expr: ast.Expr) CodegenError!Value {
    const dinfo = obj.dict_info.?;
    const key_v0 = try self.genExpr(key_expr);
    try self.checkNoLowlevelEscape(key_v0);
    const key_payload = try self.toPayload(key_v0);
    const key_is_str_lit: []const u8 = if (dinfo.key_is_str) "1" else "0";

    const contains_t = try self.newTemp();
    // Faz MN.4: bkz. `calls.zig`nin `genDictMethod`indeki AYNI notu.
    try self.qbeCall(.{ .name = contains_t, .ty = .w }, "$nox_dict_contains", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj.text }, .{ .ty = .w, .text = key_is_str_lit }, .{ .ty = .l, .text = key_payload.text } });
    const err_label = try self.newLabel("dict_get_err");
    const ok_label = try self.newLabel("dict_get_ok");
    try self.qbeJnz(contains_t, ok_label, err_label);
    try self.qbeLabel(err_label);

    const msg_value = try self.emitStringLiteral("anahtar bulunamadi");
    const ke_cinfo = self.classes.get("KeyError") orelse return error.Unsupported;
    const ke_obj = try self.genConstructFromValues("KeyError", ke_cinfo, &.{msg_value}, null);
    try self.emitExceptionLineStore(ke_obj.text, "KeyError", self.current_raise_line);
    try self.qbeCall(null, "$nox_raise", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ke_obj.text }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{self.current_raise_line}) } });
    // Faz NN: `genIndex`/`genListAssign`in AYNI belge notu — kök-neden
    // düzeltmesinden (bkz. `ownership.zig`) SONRA GÜVENLE eklendi. `obj`
    // (taban SÖZLÜK) İçin de aynı serbest bırakma GEREKİYORDU — bu dal
    // `emitExceptionCheck`in ÜRETTİĞİ jnz İLE fonksiyonun temizlik/yayma
    // yoluna ATLADIĞINDAN, BU noktadan SONRA (ör. `genIndex`nin çağrı
    // SİTESİNDE, fonksiyon DÖNDÜKTEN sonra) eklenecek herhangi bir serbest
    // bırakma KOD'u HİÇ ÇALIŞMAZ — bu YÜZDEN `emitExceptionCheck`den ÖNCE,
    // BURADA olmak ZORUNDA.
    try self.releaseIfTemporary(key_expr, key_v0);
    try self.releaseIfTemporary(obj_expr, obj);
    try self.emitRaisePropagate();

    try self.qbeLabel(ok_label);

    const payload_t = try self.newTemp();
    try self.qbeCall(.{ .name = payload_t, .ty = .l }, "$nox_dict_get", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj.text }, .{ .ty = .w, .text = key_is_str_lit }, .{ .ty = .l, .text = key_payload.text } });
    const converted = try self.fromPayload(.{ .text = payload_t, .qtype = .l }, dinfo.value_qtype);
    try self.releaseIfTemporary(key_expr, key_v0);
    // `nox_dict_get` ÖDÜNÇ bir referans döner (bkz. `runtime/collections/
    // dict.zig`, retain YOK) — değer `str` İSE (dict[K,V]'nin TEK olası
    // heap-yönetimli değer tipi) VE taban TEMPORARY'YSE, tabanı serbest
    // bırakmadan ÖNCE retain ET (`genIndex`nin list dalıyla AYNI koruma) —
    // aksi halde taban hemen aşağıda serbest bırakılınca (refcount sıfıra
    // düşüp dict'in TÜM girdileri özyinelemeli serbest bırakılınca) az
    // önce okuduğumuz string kullanım-sonrası-serbest-bırakmaya döner.
    if (isTemporaryExpr(obj_expr) and dinfo.value_is_str) {
        try self.emitInlineRetain(converted.text, .str);
    } else if (isTemporaryExpr(obj_expr) and dinfo.value_is_class) {
        try self.emitInlineRetain(converted.text, .class);
    } else if (isTemporaryExpr(obj_expr) and (dinfo.value_heap == .list or dinfo.value_heap == .dict)) {
        try self.emitInlineRetain(converted.text, dinfo.value_heap);
    }
    try self.releaseIfTemporary(obj_expr, obj);
    return abi.dictValueValue(dinfo, converted.text, converted.qtype);
}

/// Faz FF.6.4 (bkz. `narrowed_unbox`ın belge notu): `checker.zig`'in
/// `Checker.detectNarrowing`iyle AYNI DAR AST örüntüsü — yalnızca
/// `<isim> != None`/`<isim> == None` (VE yansımaları) — ama BURADA
/// yalnızca `name`in KENDİSİNİN `boxed_scalar` OLUP OLMADIĞI ÖNEMLİDİR
/// (checker ZATEN tüm STATİK doğruluğu kanıtladı — bu, YALNIZCA "kutuyu
/// AÇMALI MIYIM" kararı İÇİN gereken minimal bilgidir).
pub fn detectNarrowedBoxedName(self: *Codegen, cond: ast.Expr) ?struct { name: []const u8, narrows_then: bool } {
    if (cond != .binary) return null;
    const b = cond.binary;
    if (b.op != .eq and b.op != .ne) return null;
    const name: []const u8 = if (b.left.* == .identifier and b.right.* == .none_lit)
        b.left.identifier
    else if (b.right.* == .identifier and b.left.* == .none_lit)
        b.right.identifier
    else
        return null;
    const info = self.vars.get(name) orelse return null;
    if (info.heap != .boxed_scalar) return null;
    return .{ .name = name, .narrows_then = (b.op == .ne) };
}

/// v1.156.0: bileşik koşullardan (`and`/`or`/`not`) daraltılan KUTULU skaler Optional isimleri (checker `collectNarrows`ın aynası, en çok 8).
pub const NameList = struct {
    items: [8][]const u8 = undefined,
    len: usize = 0,
    pub fn add(self: *NameList, n: []const u8) void {
        for (self.items[0..self.len]) |e| if (std.mem.eql(u8, e, n)) return;
        if (self.len < self.items.len) {
            self.items[self.len] = n;
            self.len += 1;
        }
    }
    pub fn slice(self: *const NameList) []const []const u8 {
        return self.items[0..self.len];
    }
};

pub fn collectNarrowedBoxed(self: *Codegen, cond: ast.Expr, positive: bool, out: *NameList) void {
    switch (cond) {
        .binary => |b| switch (b.op) {
            .and_ => if (positive) {
                self.collectNarrowedBoxed(b.left.*, true, out);
                self.collectNarrowedBoxed(b.right.*, true, out);
            },
            .or_ => if (!positive) {
                self.collectNarrowedBoxed(b.left.*, false, out);
                self.collectNarrowedBoxed(b.right.*, false, out);
            },
            .eq, .ne => if (self.detectNarrowedBoxedName(cond)) |n| {
                if (positive == n.narrows_then) out.add(n.name);
            },
            else => {},
        },
        .unary => |u| if (u.op == .not_) self.collectNarrowedBoxed(u.operand.*, !positive, out),
        else => {},
    }
}

/// `names`i `narrowed_unbox`a ekleyip `body`yi üretir; çıkışta önceden var olmayanları geri alır.
pub fn genNarrowedStmts(self: *Codegen, names: []const []const u8, body: []const ast.Stmt, ret_qtype: QbeType) CodegenError!void {
    var was: [8]bool = .{false} ** 8;
    for (names, 0..) |n, i| {
        was[i] = self.narrowed_unbox.contains(n);
        try self.narrowed_unbox.put(self.allocator, n, {});
    }
    try self.genStmts(body, ret_qtype);
    for (names, 0..) |n, i| if (!was[i]) {
        _ = self.narrowed_unbox.remove(n);
    };
}

pub fn genIf(self: *Codegen, f: ast.IfStmt, ret_qtype: QbeType) CodegenError!void {
    const end_label = try self.newLabel("if_end");

    // Bkz. `Codegen.mod_cache`nin belge notu, madde 3 — KRİTİK bir
    // düzeltme (bkz. AGENTS.md İlke #7, hedeflenmiş bir güvenlik
    // testiyle YAKALANDI): `then`/`elif`/`else` gövdelerinden HERHANGİ
    // BİRİ bir ismi yeniden atıyorsa, if SONRASI kod o isim İçin if
    // ÖNCESİNDEN kalma HERHANGİ bir önbellek girdisine GÜVENEMEZ —
    // HANGİ dalın (varsa) alındığı statik olarak BİLİNMEZ. Bu YÜZDEN
    // TÜM dalların yeniden-atadığı isimlerin BİRLEŞİMİ, `cond0`
    // hesaplanmadan ÖNCE (böylece cond0/sonraki koşulların KENDİ TAZE
    // hesaplamaları hâlâ if BOYUNCA paylaşılabilir kalır — bkz. madde 3
    // "if/elif zincirinin TAMAMI BOYUNCA GÜVENLE KALICI" notu) geçersiz
    // KILINIR. (Aşağıdaki dal-yerel anlık-görüntü/geri-yükleme AYRI bir
    // amaca hizmet eder: bir dalın KENDİ İÇİNDE kurduğu TAZE bir girdinin
    // kardeş dallara/if SONRASINA sızmasını önlemek — bu İKİSİ
    // TAMAMLAYICIDIR, biri diğerinin YERİNE geçmez.)
    {
        var all_reassigned: std.StringHashMapUnmanaged(void) = .empty;
        defer all_reassigned.deinit(self.allocator);
        try collectReassignedNames(f.then_body, &all_reassigned, self.allocator);
        for (f.elif_clauses) |ec| try collectReassignedNames(ec.body, &all_reassigned, self.allocator);
        if (f.else_body) |eb| try collectReassignedNames(eb, &all_reassigned, self.allocator);
        var it = all_reassigned.keyIterator();
        while (it.next()) |k| try self.modCacheInvalidateName(k.*);
    }

    const cond0 = try self.genExpr(f.cond);
    const then_label = try self.newLabel("if_then");
    var next_label = if (f.elif_clauses.len > 0)
        try self.newLabel("if_elif")
    else if (f.else_body != null)
        try self.newLabel("if_else")
    else
        end_label;
    try self.qbeJnz(cond0.text, then_label, next_label);
    try self.qbeLabel(then_label);
    {
        // Bkz. `Codegen.mod_cache`nin belge notu, madde 3: bu dal
        // ÇALIŞMAMIŞ OLABİLİR (KARDEŞ bir dal alınmış olabilir) — dal
        // İÇİNDE ÖĞRENİLEN/geçersiz KILINAN hiçbir şey if SONRASINA
        // (ya da kardeş dallara) SIZMAMALI.
        const mc_snap = try self.snapshotModCache();
        var then_n: NameList = .{};
        self.collectNarrowedBoxed(f.cond, true, &then_n);
        try genNarrowedStmts(self, then_n.slice(), f.then_body, ret_qtype);
        self.restoreModCache(mc_snap);
    }
    try self.qbeJmp(end_label);

    for (f.elif_clauses, 0..) |ec, i| {
        try self.qbeLabel(next_label);
        // `ec.cond` if/elif zincirinin BU NOKTAYA ULAŞAN HER yolunda
        // KOŞULSUZ değerlendirilir — bu YÜZDEN önbelleğe katkısı
        // ANLIK-GÖRÜNTÜLENMEZ (bkz. `Codegen.mod_cache`nin belge notu,
        // madde 3).
        const cond_i = try self.genExpr(ec.cond);
        const body_label = try self.newLabel("if_elif_body");
        const is_last = i == f.elif_clauses.len - 1;
        const following = if (!is_last)
            try self.newLabel("if_elif")
        else if (f.else_body != null)
            try self.newLabel("if_else")
        else
            end_label;
        try self.qbeJnz(cond_i.text, body_label, following);
        try self.qbeLabel(body_label);
        {
            const mc_snap = try self.snapshotModCache();
            try self.genStmts(ec.body, ret_qtype);
            self.restoreModCache(mc_snap);
        }
        try self.qbeJmp(end_label);
        next_label = following;
    }

    if (f.else_body) |eb| {
        try self.qbeLabel(next_label);
        const mc_snap = try self.snapshotModCache();
        var else_n: NameList = .{};
        self.collectNarrowedBoxed(f.cond, false, &else_n);
        try genNarrowedStmts(self, else_n.slice(), eb, ret_qtype);
        self.restoreModCache(mc_snap);
        try self.qbeJmp(end_label);
    }

    try self.qbeLabel(end_label);
}

/// Faz GG.5: iç içe geçmiş İFADE ağacının HER YERİNDE (`if`/`while`/`for`/
/// `try`/`with`/`lowlevel` gövdeleri DAHİL) `s[i]` desenini arar, `s`nin
/// `str`-tipli BİR KİMLİK (identifier) OLDUĞU durumlarda `s`yi aday
/// kümesine ekler. `func_def`in (iç içe closure) İÇİNE İNMEZ — bu tarama
/// KENDİSİ `bodyHasNestedFuncDef` tarafından TAMAMEN elenir (bkz. onun
/// belge notu), bu yüzden burada AYRICA bir `func_def` dalı GEREKMEZ.
pub fn collectIndexStrBasesExpr(self: *Codegen, e: ast.Expr, candidates: *std.StringHashMapUnmanaged(void)) CodegenError!void {
    switch (e) {
        .list_comp => |lc| {
            try self.collectIndexStrBasesExpr(lc.elem.*, candidates);
            for (lc.clauses) |cl| switch (cl) {
                .for_clause => |fc| try self.collectIndexStrBasesExpr(fc.iterable, candidates),
                .if_clause => |ce| try self.collectIndexStrBasesExpr(ce, candidates),
            };
        },
        .dict_comp => |dc| {
            try self.collectIndexStrBasesExpr(dc.key.*, candidates);
            try self.collectIndexStrBasesExpr(dc.value.*, candidates);
            for (dc.clauses) |cl| switch (cl) {
                .for_clause => |fc| try self.collectIndexStrBasesExpr(fc.iterable, candidates),
                .if_clause => |ce| try self.collectIndexStrBasesExpr(ce, candidates),
            };
        },
        .lambda => |lam| {
            try self.collectIndexStrBasesExpr(lam.body.*, candidates);
        },
        .slice => |sl| {
            try self.collectIndexStrBasesExpr(sl.obj.*, candidates);
            if (sl.lo) |x| try self.collectIndexStrBasesExpr(x.*, candidates);
            if (sl.hi) |x| try self.collectIndexStrBasesExpr(x.*, candidates);
            if (sl.step) |x| try self.collectIndexStrBasesExpr(x.*, candidates);
        },
        .index => |idx| {
            if (idx.obj.* == .identifier) {
                if (self.vars.get(idx.obj.identifier)) |vi| {
                    if (vi.heap == .str) try candidates.put(self.allocator, idx.obj.identifier, {});
                }
            }
            try self.collectIndexStrBasesExpr(idx.obj.*, candidates);
            try self.collectIndexStrBasesExpr(idx.index.*, candidates);
        },
        .unary => |u| try self.collectIndexStrBasesExpr(u.operand.*, candidates),
        .kwarg => |k| try self.collectIndexStrBasesExpr(k.value.*, candidates),
        .ternary => |t| {
            try self.collectIndexStrBasesExpr(t.cond.*, candidates);
            try self.collectIndexStrBasesExpr(t.then_expr.*, candidates);
            try self.collectIndexStrBasesExpr(t.else_expr.*, candidates);
        },
        .binary => |b| {
            try self.collectIndexStrBasesExpr(b.left.*, candidates);
            try self.collectIndexStrBasesExpr(b.right.*, candidates);
        },
        .call => |c| {
            try self.collectIndexStrBasesExpr(c.callee.*, candidates);
            for (c.args) |a| try self.collectIndexStrBasesExpr(a, candidates);
        },
        .attribute => |a| try self.collectIndexStrBasesExpr(a.obj.*, candidates),
        .list_lit => |items| for (items) |it| try self.collectIndexStrBasesExpr(it, candidates),
        .tuple_lit => |items| for (items) |it| try self.collectIndexStrBasesExpr(it, candidates),
        .dict_lit => |pairs| for (pairs) |p| {
            try self.collectIndexStrBasesExpr(p.key, candidates);
            try self.collectIndexStrBasesExpr(p.value, candidates);
        },
        .await_expr => |inner| try self.collectIndexStrBasesExpr(inner.*, candidates),
        .spawn_expr => |inner| try self.collectIndexStrBasesExpr(inner.*, candidates),
        .generic_construct => |g| for (g.args) |a| try self.collectIndexStrBasesExpr(a, candidates),
        .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => {},
    }
}

pub fn collectIndexStrBasesStmts(self: *Codegen, body: []const ast.Stmt, candidates: *std.StringHashMapUnmanaged(void)) CodegenError!void {
    for (body) |stmt| {
        switch (stmt.kind) {
            .expr_stmt => |e| try self.collectIndexStrBasesExpr(e, candidates),
            .var_decl => |v| try self.collectIndexStrBasesExpr(v.value, candidates),
            .assign => |a| {
                try self.collectIndexStrBasesExpr(a.target, candidates);
                try self.collectIndexStrBasesExpr(a.value, candidates);
            },
            .if_stmt => |s| {
                try self.collectIndexStrBasesExpr(s.cond, candidates);
                try self.collectIndexStrBasesStmts(s.then_body, candidates);
                for (s.elif_clauses) |ec| {
                    try self.collectIndexStrBasesExpr(ec.cond, candidates);
                    try self.collectIndexStrBasesStmts(ec.body, candidates);
                }
                if (s.else_body) |eb| try self.collectIndexStrBasesStmts(eb, candidates);
            },
            .while_stmt => |s| {
                try self.collectIndexStrBasesExpr(s.cond, candidates);
                try self.collectIndexStrBasesStmts(s.body, candidates);
            },
            .for_stmt => |s| {
                try self.collectIndexStrBasesExpr(s.iterable, candidates);
                try self.collectIndexStrBasesStmts(s.body, candidates);
            },
            .return_stmt => |e| if (e) |ex| try self.collectIndexStrBasesExpr(ex, candidates),
            .raise_stmt => |e| try self.collectIndexStrBasesExpr(e, candidates),
            .del_stmt => |e| try self.collectIndexStrBasesExpr(e, candidates),
            .try_stmt => |s| {
                try self.collectIndexStrBasesStmts(s.try_body, candidates);
                for (s.except_clauses) |ec| try self.collectIndexStrBasesStmts(ec.body, candidates);
                if (s.finally_body) |fb| try self.collectIndexStrBasesStmts(fb, candidates);
            },
            .lowlevel_stmt => |s| try self.collectIndexStrBasesStmts(s.body, candidates),
            .with_stmt => |s| {
                try self.collectIndexStrBasesExpr(s.ctx_expr, candidates);
                try self.collectIndexStrBasesStmts(s.body, candidates);
            },
            .defer_stmt => |d| try self.collectIndexStrBasesExpr(.{ .call = d.call }, candidates),
            .func_def, .class_def, .protocol_def, .extern_def, .pass_stmt, .break_stmt, .continue_stmt, .import_stmt, .from_import_stmt => {},
        }
    }
}

/// v1.149.0: `del d[k]` — anahtar yoksa `KeyError`, varsa girdi (anahtar + str/sınıf değer) serbest bırakılarak silinir.
pub fn genDel(self: *Codegen, e: ast.Expr) CodegenError!void {
    if (e != .index) return error.Unsupported;
    const ix = e.index;
    const obj = try self.genExpr(ix.obj.*);
    if (obj.heap == .list) return self.genListDelete(ix, obj);
    if (obj.heap != .dict) return error.Unsupported;
    const dinfo = obj.dict_info orelse return error.Unsupported;
    const key_v0 = try self.genExpr(ix.index.*);
    try self.checkNoLowlevelEscape(obj);
    try self.checkNoLowlevelEscape(key_v0);
    const key_payload = try self.toPayload(key_v0);
    const key_is_str_lit: []const u8 = if (dinfo.key_is_str) "1" else "0";
    const value_is_str_lit: []const u8 = if (dinfo.value_is_str) "1" else "0";
    const value_is_class_lit: []const u8 = if (dinfo.valueIsArc()) "1" else "0";
    const removed = try self.newTemp();
    try self.qbeCall(.{ .name = removed, .ty = .w }, "$nox_dict_remove", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj.text }, .{ .ty = .w, .text = key_is_str_lit }, .{ .ty = .w, .text = value_is_str_lit }, .{ .ty = .w, .text = value_is_class_lit }, .{ .ty = .l, .text = key_payload.text } });
    const err_label = try self.newLabel("dict_del_err");
    const ok_label = try self.newLabel("dict_del_ok");
    try self.qbeJnz(removed, ok_label, err_label);
    try self.qbeLabel(err_label);
    const msg_value = try self.emitStringLiteral("anahtar bulunamadi");
    const ke_cinfo = self.classes.get("KeyError") orelse return error.Unsupported;
    const ke_obj = try self.genConstructFromValues("KeyError", ke_cinfo, &.{msg_value}, null);
    try self.emitExceptionLineStore(ke_obj.text, "KeyError", self.current_raise_line);
    try self.qbeCall(null, "$nox_raise", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ke_obj.text }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{self.current_raise_line}) } });
    try self.releaseIfTemporary(ix.index.*, key_v0);
    try self.releaseIfTemporary(ix.obj.*, obj);
    try self.emitRaisePropagate();
    try self.qbeLabel(ok_label);
    try self.releaseIfTemporary(ix.index.*, key_v0);
    try self.releaseIfTemporary(ix.obj.*, obj);
}

/// `break` (`is_break`) / `continue`: en içteki döngünün etiketine atlar. Önce döngü gövdesi İÇİNDE açılmış
/// `try/finally`/`with` gövdeleri ve `lowlevel` arenaları (en içten) boşaltılır — `return` ile aynı kapsam-çıkışı
/// mekanizması (AGENTS.md §9), ama yalnızca döngü giriş derinliğinin ÜSTÜNDEKİLER için. Yerel değişkenler yinelemede
/// serbest bırakılmaz (bkz. `Codegen.loop_stack`). Checker döngü dışı kullanımı reddettiğinden `loop_stack` boş olamaz.
pub fn genLoopJump(self: *Codegen, is_break: bool) CodegenError!void {
    if (self.loop_stack.items.len == 0) return error.Unsupported;
    const ctx = self.loop_stack.items[self.loop_stack.items.len - 1];
    try self.drainFinallyDownTo(ctx.finally_depth, self.current_ret_qtype);
    try self.drainArenasDownTo(ctx.arena_depth);
    try self.qbeJmp(if (is_break) ctx.break_label else ctx.continue_label);
    const label = if (is_break) try self.newLabel("after_break") else try self.newLabel("after_continue");
    try self.qbeLabel(label);
}

fn pushLoop(self: *Codegen, break_label: []const u8, continue_label: []const u8) CodegenError!void {
    try self.loop_stack.append(self.allocator, .{
        .break_label = break_label,
        .continue_label = continue_label,
        .finally_depth = self.finally_stack.items.len,
        .arena_depth = self.arena_stack.items.len,
    });
}

pub fn genWhile(self: *Codegen, w: ast.WhileStmt, ret_qtype: QbeType) CodegenError!void {
    const cond_label = try self.newLabel("while_cond");
    const body_label = try self.newLabel("while_body");
    const end_label = try self.newLabel("while_end");

    const str_len_scope = try self.enterStrLenCacheScope(w.body);
    const mc_scope = try self.enterModCacheLoopScope(w.body);
    try self.qbeJmp(cond_label);
    try self.qbeLabel(cond_label);
    const cond_v = try self.genExpr(w.cond);
    try self.qbeJnz(cond_v.text, body_label, end_label);
    try self.qbeLabel(body_label);
    try pushLoop(self, end_label, cond_label);
    defer _ = self.loop_stack.pop();
    var while_n: NameList = .{};
    self.collectNarrowedBoxed(w.cond, true, &while_n);
    try genNarrowedStmts(self, while_n.slice(), w.body, ret_qtype);
    try self.qbeJmp(cond_label);
    try self.qbeLabel(end_label);
    self.restoreModCache(mc_scope);
    self.exitStrLenCacheScope(str_len_scope);
}

pub fn isRangeCall(e: ast.Expr) bool {
    return e == .call and e.call.callee.* == .identifier and
        std.mem.eql(u8, e.call.callee.identifier, "range") and e.call.args.len >= 1 and e.call.args.len <= 3;
}

pub fn findLocal(locals: []const LocalDecl, name: []const u8) ?TypeInfo {
    var i = locals.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, locals[i].name, name)) return locals[i].info;
    }
    return null;
}

pub fn genFor(self: *Codegen, f: ast.ForStmt, ret_qtype: QbeType) CodegenError!void {
    if (isRangeCall(f.iterable)) return self.genForRange(f, ret_qtype);
    // v1.148.0: iterable adlandırılmış bir liste değilse checker bir gizli yerel (`hoist`) tanımlamıştır: ifade BİR KEZ,
    // sıradan bir `var_decl` gibi (retain/serbest bırakma/tüm çıkış yolları) o yerele alınır, sonra yerel üzerinde dönülür.
    if (f.hoist) |h| {
        const decl = [_]ast.Stmt{.{ .kind = .{ .var_decl = .{ .name = h.name, .type_expr = h.type_expr, .value = f.iterable } }, .line = @intCast(@max(self.current_raise_line, 0)) }};
        try self.genStmts(&decl, ret_qtype);
        var f2 = f;
        f2.iterable = .{ .identifier = h.name };
        f2.hoist = null;
        return self.genForList(f2, ret_qtype);
    }
    if (f.iterable == .identifier) return self.genForList(f, ret_qtype);
    return error.Unsupported;
}

/// `range(...)` adımının DERLEME-ZAMANI değeri: argüman yok → 1; int literal (ya da negatif literal) → o değer;
/// aksi halde (çalışma zamanı ifadesi) `null`.
fn rangeStepLiteral(args: []const ast.Expr) ?i64 {
    if (args.len < 3) return 1;
    return switch (args[2]) {
        .int_lit => |v| v,
        .unary => |u| if (u.op == .neg and u.operand.* == .int_lit) -u.operand.int_lit else null,
        else => null,
    };
}

pub fn genForRange(self: *Codegen, f: ast.ForStmt, ret_qtype: QbeType) CodegenError!void {
    const rargs = f.iterable.call.args;
    const var_info = self.vars.get(f.var_name).?;
    // v1.148.0: `range(bitiş)` / `range(başlangıç, bitiş)` / `range(başlangıç, bitiş, adım)`. Değerlendirme sırası
    // başlangıç → bitiş → adım; üçü de döngüye girmeden BİR KEZ.
    var limit: Value = undefined;
    if (rargs.len >= 2) {
        const start = try self.genExpr(rargs[0]);
        try self.qbeStoreL(start.text, var_info.slot);
        limit = try self.genExpr(rargs[1]);
    } else {
        limit = try self.genExpr(rargs[0]);
        try self.qbeStoreImmL(0, var_info.slot);
    }
    const step_lit = rangeStepLiteral(rargs);
    var step_dyn: ?Value = null;
    if (step_lit == null) {
        const sv = try self.genExpr(rargs[2]);
        step_dyn = sv;
        // Çalışma zamanı adımı sıfır olamaz (Python: ValueError).
        const zero_t = try self.newTemp();
        try self.qbeOp2Imm(zero_t, .w, "ceql", sv.text, 0);
        const zerr_label = try self.newLabel("range_step_err");
        const zok_label = try self.newLabel("range_step_ok");
        try self.qbeJnzCold(zero_t, zerr_label, zok_label);
        const cold_start = self.beginCold();
        try self.qbeLabel(zerr_label);
        const zmsg = try self.emitStringLiteral("range() adimi sifir olamaz");
        const zve_cinfo = self.classes.get("ValueError") orelse return error.Unsupported;
        const zve_obj = try self.genConstructFromValues("ValueError", zve_cinfo, &.{zmsg}, null);
        try self.emitExceptionLineStore(zve_obj.text, "ValueError", self.current_raise_line);
        try self.qbeCall(null, "$nox_raise", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = zve_obj.text }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{self.current_raise_line}) } });
        try self.emitRaisePropagate();
        try self.stashCold(cold_start);
        try self.qbeLabel(zok_label);
    }

    const cond_label = try self.newLabel("for_cond");
    const body_label = try self.newLabel("for_body");
    const end_label = try self.newLabel("for_end");
    // `continue` artırma adımına gider (v1.144.0).
    const step_label = try self.newLabel("for_step");

    const str_len_scope = try self.enterStrLenCacheScope(f.body);
    // `f.var_name`in artışı (aşağıda) BİR `.assign` AST düğümünü
    // BAYPAS EDER (DOĞRUDAN QBE yayını) — `collectReassignedNames`
    // (AŞAĞIDAKİ `enterModCacheLoopScope`) bunu YAKALAYAMAZ, bu YÜZDEN
    // AYRICA geçersiz kılınır (bkz. `Codegen.mod_cache`nin belge notu,
    // madde 4). **KRİTİK sıra:** bu, `enterModCacheLoopScope`DEN ÖNCE
    // yapılır — o fonksiyon anlık görüntüyü TÜM geçersiz kılmalar
    // TAMAMLANDIKTAN SONRA alır (bkz. onun belge notu, `genIf`yle AYNI
    // düzeltme); TERSİ sırada BU isim döngü SONRASI YANLIŞLIKLA geri
    // gelirdi.
    try self.modCacheInvalidateName(f.var_name);
    const mc_scope = try self.enterModCacheLoopScope(f.body);
    const saved_bounds_ctx = self.bounds_elide_ctx;
    self.bounds_elide_ctx = try self.detectBoundsElideCtx(f);
    try self.qbeJmp(cond_label);
    try self.qbeLabel(cond_label);
    const cur = try self.newTemp();
    try self.qbeLoadL(cur, var_info.slot);
    const cmp = try self.newTemp();
    if (step_lit) |sl| {
        // Adım derleme zamanında biliniyor: yön sabit (pozitif → `<`, negatif → `>`).
        try self.qbeOp2(cmp, .w, if (sl > 0) "csltl" else "csgtl", cur, limit.text);
    } else {
        // Çalışma zamanı adımı: (adım > 0 ve cur < bitiş) veya (adım < 0 ve cur > bitiş).
        const sv = step_dyn.?;
        const lt = try self.newTemp();
        try self.qbeOp2(lt, .w, "csltl", cur, limit.text);
        const gt = try self.newTemp();
        try self.qbeOp2(gt, .w, "csgtl", cur, limit.text);
        const pos = try self.newTemp();
        try self.qbeOp2Imm(pos, .w, "csgtl", sv.text, 0);
        const neg = try self.newTemp();
        try self.qbeOp2Imm(neg, .w, "csltl", sv.text, 0);
        const c1 = try self.newTemp();
        try self.qbeOp2(c1, .w, "and", pos, lt);
        const c2 = try self.newTemp();
        try self.qbeOp2(c2, .w, "and", neg, gt);
        try self.qbeOp2(cmp, .w, "or", c1, c2);
    }
    try self.qbeJnz(cmp, body_label, end_label);
    try self.qbeLabel(body_label);
    try pushLoop(self, end_label, step_label);
    try self.genStmts(f.body, ret_qtype);
    _ = self.loop_stack.pop();
    try self.qbeJmp(step_label);
    try self.qbeLabel(step_label);
    const cur2 = try self.newTemp();
    try self.qbeLoadL(cur2, var_info.slot);
    const next = try self.newTemp();
    if (step_lit) |sl| {
        try self.qbeOp2Imm(next, .l, "add", cur2, sl);
    } else {
        try self.qbeOp2(next, .l, "add", cur2, step_dyn.?.text);
    }
    try self.qbeStoreL(next, var_info.slot);
    try self.qbeJmp(cond_label);
    try self.qbeLabel(end_label);
    self.bounds_elide_ctx = saved_bounds_ctx;
    self.restoreModCache(mc_scope);
    self.exitStrLenCacheScope(str_len_scope);
}

pub fn genForList(self: *Codegen, f: ast.ForStmt, ret_qtype: QbeType) CodegenError!void {
    const list_info = self.vars.get(f.iterable.identifier) orelse return error.Unsupported;
    if (list_info.heap != .list) return error.Unsupported;
    const loop_var = self.vars.get(f.var_name).?;

    // İndeks yuvası, `collectLocals`de (bkz. `forListIdxName`) FONKSİYON
    // GİRİŞİNDE bir kez tahsis edilmiş olmalıdır — burada taze bir
    // `alloc8` yapmak, bu `for` başka bir döngünün içine gömülüyse her
    // dış yinelemede yığını küçültüp asla geri almaz (yığın taşması).
    const idx_name = try forListIdxName(self.allocator, f.var_name);
    const idx_slot = self.vars.get(idx_name).?.slot;
    try self.qbeStoreImmL(0, idx_slot);

    const list_ptr = try self.newTemp();
    try self.qbeLoadL(list_ptr, list_info.slot);
    const len_t = try self.newTemp();
    try self.qbeLoadL(len_t, list_ptr);

    const cond_label = try self.newLabel("forlist_cond");
    const body_label = try self.newLabel("forlist_body");
    const end_label = try self.newLabel("forlist_end");
    const step_label = try self.newLabel("forlist_step");

    const str_len_scope = try self.enterStrLenCacheScope(f.body);
    // `loop_var`e HER yinelemede öğenin DEĞERİ yazılır (aşağıda) —
    // bu da BİR `.assign` AST düğümünü BAYPAS EDER, bu YÜZDEN AYRICA
    // geçersiz kılınır (bkz. `genForRange`nin AYNI notu — SIRA AYNI
    // ŞEKİLDE kritiktir: `enterModCacheLoopScope`DEN ÖNCE).
    try self.modCacheInvalidateName(f.var_name);
    const mc_scope = try self.enterModCacheLoopScope(f.body);
    try self.qbeJmp(cond_label);
    try self.qbeLabel(cond_label);
    const idx_cur = try self.newTemp();
    try self.qbeLoadL(idx_cur, idx_slot);
    const cmp = try self.newTemp();
    try self.qbeOp2(cmp, .w, "csltl", idx_cur, len_t);
    try self.qbeJnz(cmp, body_label, end_label);
    try self.qbeLabel(body_label);

    const byte_off = try self.newTemp();
    // v1.142.19: adım ve yükleme LİSTENİN eleman depolama tipinden (`.b` = 1 bayt), döngü değişkeni ise
    // değer tipinden (`.w`) gelir.
    try self.qbeOp2Imm(byte_off, .l, "mul", idx_cur, @intCast(qbeSizeOf(list_info.elem_qtype)));
    const off8 = try self.newTemp();
    try self.qbeOp2Imm(off8, .l, "add", byte_off, @intCast(LIST_HEADER_SIZE));
    const elem_addr = try self.newTemp();
    try self.qbeOp2(elem_addr, .l, "add", list_ptr, off8);
    const elem_val = try self.newTemp();
    try self.loadListElem(elem_val, list_info.elem_qtype, elem_addr);
    try self.qbeStore(loop_var.qtype, elem_val, loop_var.slot);

    try pushLoop(self, end_label, step_label);
    try self.genStmts(f.body, ret_qtype);
    _ = self.loop_stack.pop();
    try self.qbeJmp(step_label);
    try self.qbeLabel(step_label);

    const idx_base = try self.newTemp();
    try self.qbeLoadL(idx_base, idx_slot);
    const idx_next = try self.newTemp();
    try self.qbeOp2Imm(idx_next, .l, "add", idx_base, 1);
    try self.qbeStoreL(idx_next, idx_slot);
    try self.qbeJmp(cond_label);
    try self.qbeLabel(end_label);
    self.restoreModCache(mc_scope);
    self.exitStrLenCacheScope(str_len_scope);
}
