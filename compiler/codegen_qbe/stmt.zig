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
const LocalDecl = types.LocalDecl;
const TypeInfo = types.TypeInfo;
const RT_PARAM = types.RT_PARAM;
const LIST_HEADER_SIZE = types.LIST_HEADER_SIZE;
const CodegenError = abi.CodegenError;
const qbeTypeName = abi.qbeTypeName;
const qbeSizeOf = abi.qbeSizeOf;
const isHeapManaged = abi.isHeapManaged;
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
            try self.out.writer.print("    dbgloc {d}\n", .{stmt.line});
        }
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
                        if (isHeapManaged(v0.heap) and self.returnNeedsRetain(e)) {
                            try self.emitInlineRetain(v0.text);
                        }
                        const v = try self.convert(v0, ret_qtype);
                        const except_name: ?[]const u8 = if (e == .identifier) e.identifier else null;
                        try self.releaseNamedLocalsExcept(t.owned_names, except_name);
                        if (t.result_slot) |rs| {
                            try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(ret_qtype), v.text, rs });
                        }
                    } else {
                        try self.releaseNamedLocalsExcept(t.owned_names, null);
                    }
                    try self.out.writer.print("    jmp {s}\n", .{t.done_label});
                    const label = try self.newLabel("after_inline_return");
                    try self.out.writer.print("{s}\n", .{label});
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
                    if (isHeapManaged(v0.heap) and self.returnNeedsRetain(e)) {
                        try self.emitInlineRetain(v0.text);
                    }
                    const v = try self.convert(v0, ret_qtype);
                    // Sıra önemli: finally/arena yıkımı, yereller hâlâ
                    // geçerliyken (serbest bırakılmadan ÖNCE) çalışmalıdır —
                    // aksi hâlde içlerindeki bir okuma, kullanım-sonrası-
                    // serbest-bırakma (use-after-free) olurdu.
                    try self.drainFinally(ret_qtype);
                    try self.drainArenas();
                    try self.drainDeferIfSet();
                    const except_name: ?[]const u8 = if (e == .identifier) e.identifier else null;
                    try self.releaseAllLocalsExcept(except_name);
                    try self.out.writer.print("    ret {s}\n", .{v.text});
                } else {
                    try self.drainFinally(ret_qtype);
                    try self.drainArenas();
                    try self.drainDeferIfSet();
                    try self.releaseAllLocalsExcept(null);
                    try self.out.writer.writeAll("    ret\n");
                }
                const label = try self.newLabel("after_return");
                try self.out.writer.print("{s}\n", .{label});
            },
            .var_decl => |v| {
                const info = self.vars.get(v.name).?;
                const v0 = try self.genExprForTarget(v.value, info);
                const retained = try self.retainIfAliasing(v.value, v0);
                const val = try self.convert(retained, info.qtype);
                // `.arena` bir yerelse (bir `lowlevel` bloğu içindeyse),
                // bu bildirim bir DÖNGÜ gövdesinde olabilir ve slot önceki
                // yinelemeden kalan bir işaretçi tutuyor olabilir — ama o
                // bellek zaten arenanın TOPLU `nox_arena_destroy`'u ile
                // serbest bırakılmıştır (bkz. `genLowLevel`). Burada normal
                // ARC serbest bırakmayı çağırmak, ZATEN serbest bırakılmış
                // belleği tekrar serbest bırakmaya (geçersiz free) yol açar.
                if (isHeapManaged(info.heap) and !info.arena) try self.releaseSlotIfSet(info);
                try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(info.qtype), val.text, info.slot });
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
            .try_stmt => |t| try self.genTry(t, ret_qtype),
            .lowlevel_stmt => |ll| try self.genLowLevel(ll, ret_qtype),
            .pass_stmt => {},
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
pub fn genLowLevel(self: *Codegen, ll: ast.LowLevelStmt, ret_qtype: QbeType) CodegenError!void {
    const arena_temp = try self.newTemp();
    try self.out.writer.print("    {s} =l call $nox_arena_create(l {s})\n", .{ arena_temp, RT_PARAM });
    try self.arena_stack.append(self.allocator, arena_temp);
    self.in_lowlevel_depth += 1;
    try self.genStmts(ll.body, ret_qtype);
    self.in_lowlevel_depth -= 1;
    _ = self.arena_stack.pop();
    try self.out.writer.print("    call $nox_arena_destroy(l {s}, l {s})\n", .{ RT_PARAM, arena_temp });
}

pub fn genAssign(self: *Codegen, a: ast.Assign) CodegenError!void {
    switch (a.target) {
        .identifier => |name| {
            const info = self.vars.get(name) orelse return error.Unsupported;
            const v0 = try self.genExprForTarget(a.value, info);
            const retained = try self.retainIfAliasing(a.value, v0);
            const val = try self.convert(retained, info.qtype);
            // Bkz. `var_decl` kolundaki aynı gerekçe: arena yerelleri asla
            // ARC ile serbest bırakılmaz (arenanın toplu yıkımı zaten
            // bunu yapar) — aksi halde döngü içinde yeniden atama, önceki
            // yinelemede zaten yıkılmış bir arenaya ait belleği tekrar
            // serbest bırakmaya çalışır.
            if (isHeapManaged(info.heap) and !info.is_param and !info.arena) {
                try self.releaseSlotIfSet(info);
            } else if ((info.heap == .task or info.heap == .channel or info.heap == .thread_handle or info.heap == .thread_channel) and !info.is_param and !info.arena) {
                // Faz S.1: `Task[T]`/`Channel[T]`/`ThreadHandle[T]`/
                // `ThreadChannel[T]` yeniden atamada ESKİ değer artık
                // sızmaz — `destroyNonArcSlotIfSet`
                // (bkz. onun belge notu, `Task` İÇİN `nox_async_destroy_task`nin
                // GÜVENLİ ertelenmiş yıkım semantiği) mevcut slot değerini
                // YENİ değer BURAYA yazılmadan ÖNCE yok eder.
                try self.destroyNonArcSlotIfSet(info);
            }
            try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(info.qtype), val.text, info.slot });
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
                try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ addr, obj.text, f.offset });
                if (isHeapManaged(f.info.heap)) {
                    // Üzerine yazılacak ESKİ değeri önce oku (adres henüz
                    // üzerine yazılmadı), yeni değeri sakla, SONRA eskiyi
                    // serbest bırak — aksi halde eski nesne sonsuza dek
                    // sızardı (kendi refcount'u hiç azalmazdı).
                    const old_ptr = try self.newTemp();
                    try self.out.writer.print("    {s} =l loadl {s}\n", .{ old_ptr, addr });
                    try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(f.info.qtype), val.text, addr });
                    try self.releaseValueIfSet(old_ptr, f.info.heap, f.info.elem_qtype, f.info.class_name, f.info.elem_heap_info, f.info.dict_info);
                } else if (f.info.heap == .task or f.info.heap == .channel or f.info.heap == .thread_handle or f.info.heap == .thread_channel) {
                    // Faz S.1: `isHeapManaged`in DIŞINDaki DÖRT tür İÇİN de
                    // (yukarıdaki dalla AYNI "önce oku, SONRA üzerine yaz,
                    // SONRA eskiyi yok et" sırası) — bkz. `destroyNonArcValue`.
                    const old_ptr = try self.newTemp();
                    try self.out.writer.print("    {s} =l loadl {s}\n", .{ old_ptr, addr });
                    try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(f.info.qtype), val.text, addr });
                    try self.destroyNonArcValue(old_ptr, f.info.heap);
                } else {
                    try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(f.info.qtype), val.text, addr });
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
pub fn genListAssign(self: *Codegen, obj: Value, idx: ast.Index, value_expr: ast.Expr) CodegenError!void {
    if (obj.heap != .list) return error.Unsupported;
    try self.checkNoLowlevelEscape(obj);
    const index_v = try self.genExpr(idx.index.*);

    const len_t = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ len_t, obj.text });
    const neg_t = try self.newTemp();
    try self.out.writer.print("    {s} =w csltl {s}, 0\n", .{ neg_t, index_v.text });
    const oob_hi_t = try self.newTemp();
    try self.out.writer.print("    {s} =w csgel {s}, {s}\n", .{ oob_hi_t, index_v.text, len_t });
    const oob_t = try self.newTemp();
    try self.out.writer.print("    {s} =w or {s}, {s}\n", .{ oob_t, neg_t, oob_hi_t });
    const err_label = try self.newLabel("list_assign_err");
    const ok_label = try self.newLabel("list_assign_ok");
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ oob_t, err_label, ok_label });
    try self.out.writer.print("{s}\n", .{err_label});

    const msg_value = try self.emitStringLiteral("liste indeksi sinirlarin disinda");
    const ie_cinfo = self.classes.get("IndexError") orelse return error.Unsupported;
    const ie_obj = try self.genConstructFromValues("IndexError", ie_cinfo, &.{msg_value});
    try self.out.writer.print("    call $nox_raise(l {s}, l {s})\n", .{ RT_PARAM, ie_obj.text });
    try self.emitExceptionCheck();
    try self.out.writer.print("    jmp {s}\n", .{ok_label});

    try self.out.writer.print("{s}\n", .{ok_label});
    const value_v0 = try self.genExpr(value_expr);
    try self.checkNoLowlevelEscape(value_v0);
    const retained = try self.retainIfAliasing(value_expr, value_v0);
    const val = try self.convert(retained, obj.elem_qtype);

    const byte_off = try self.newTemp();
    try self.out.writer.print("    {s} =l mul {s}, {d}\n", .{ byte_off, index_v.text, qbeSizeOf(obj.elem_qtype) });
    const off16 = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ off16, byte_off, LIST_HEADER_SIZE });
    const addr = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, {s}\n", .{ addr, obj.text, off16 });

    if (obj.elem_heap_info != null or obj.elem_is_str) {
        const old_ptr = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ old_ptr, addr });
        try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(obj.elem_qtype), val.text, addr });
        const elem_heap: HeapKind = if (obj.elem_heap_info) |ehi| ehi.heap else .str;
        const elem_class_name: ?[]const u8 = if (obj.elem_heap_info) |ehi| ehi.class_name else null;
        const elem_inner_qtype: QbeType = if (obj.elem_heap_info) |ehi| ehi.elem_qtype else .none;
        const elem_nested: ?*const ElemHeapInfo = if (obj.elem_heap_info) |ehi| ehi.nested else null;
        try self.releaseValueIfSet(old_ptr, elem_heap, elem_inner_qtype, elem_class_name, elem_nested, null);
    } else {
        try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(obj.elem_qtype), val.text, addr });
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
    try self.out.writer.print("    call $nox_dict_set(l {s}, l {s}, w {s}, w {s}, l {s}, l {s})\n", .{ RT_PARAM, obj.text, key_is_str_lit, value_is_str_lit, key_payload.text, value_payload.text });
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
pub fn genDictGet(self: *Codegen, obj: Value, key_expr: ast.Expr) CodegenError!Value {
    const dinfo = obj.dict_info.?;
    const key_v0 = try self.genExpr(key_expr);
    try self.checkNoLowlevelEscape(key_v0);
    const key_payload = try self.toPayload(key_v0);
    const key_is_str_lit: []const u8 = if (dinfo.key_is_str) "1" else "0";

    const contains_t = try self.newTemp();
    try self.out.writer.print("    {s} =w call $nox_dict_contains(l {s}, w {s}, l {s})\n", .{ contains_t, obj.text, key_is_str_lit, key_payload.text });
    const err_label = try self.newLabel("dict_get_err");
    const ok_label = try self.newLabel("dict_get_ok");
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ contains_t, ok_label, err_label });
    try self.out.writer.print("{s}\n", .{err_label});

    const msg_value = try self.emitStringLiteral("anahtar bulunamadi");
    const ke_cinfo = self.classes.get("KeyError") orelse return error.Unsupported;
    const ke_obj = try self.genConstructFromValues("KeyError", ke_cinfo, &.{msg_value});
    try self.out.writer.print("    call $nox_raise(l {s}, l {s})\n", .{ RT_PARAM, ke_obj.text });
    try self.emitExceptionCheck();
    try self.out.writer.print("    jmp {s}\n", .{ok_label});

    try self.out.writer.print("{s}\n", .{ok_label});

    const payload_t = try self.newTemp();
    try self.out.writer.print("    {s} =l call $nox_dict_get(l {s}, l {s}, w {s}, l {s})\n", .{ payload_t, RT_PARAM, obj.text, key_is_str_lit, key_payload.text });
    const converted = try self.fromPayload(.{ .text = payload_t, .qtype = .l }, dinfo.value_qtype);
    try self.releaseIfTemporary(key_expr, key_v0);
    return .{ .text = converted.text, .qtype = converted.qtype, .heap = if (dinfo.value_is_str) .str else .none };
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
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ cond0.text, then_label, next_label });
    try self.out.writer.print("{s}\n", .{then_label});
    {
        // Bkz. `Codegen.mod_cache`nin belge notu, madde 3: bu dal
        // ÇALIŞMAMIŞ OLABİLİR (KARDEŞ bir dal alınmış olabilir) — dal
        // İÇİNDE ÖĞRENİLEN/geçersiz KILINAN hiçbir şey if SONRASINA
        // (ya da kardeş dallara) SIZMAMALI.
        const mc_snap = try self.snapshotModCache();
        if (self.detectNarrowedBoxedName(f.cond)) |n| {
            const was_present = self.narrowed_unbox.contains(n.name);
            if (n.narrows_then) {
                try self.narrowed_unbox.put(self.allocator, n.name, {});
                try self.genStmts(f.then_body, ret_qtype);
                if (!was_present) _ = self.narrowed_unbox.remove(n.name);
            } else {
                try self.genStmts(f.then_body, ret_qtype);
            }
        } else {
            try self.genStmts(f.then_body, ret_qtype);
        }
        self.restoreModCache(mc_snap);
    }
    try self.out.writer.print("    jmp {s}\n", .{end_label});

    for (f.elif_clauses, 0..) |ec, i| {
        try self.out.writer.print("{s}\n", .{next_label});
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
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ cond_i.text, body_label, following });
        try self.out.writer.print("{s}\n", .{body_label});
        {
            const mc_snap = try self.snapshotModCache();
            try self.genStmts(ec.body, ret_qtype);
            self.restoreModCache(mc_snap);
        }
        try self.out.writer.print("    jmp {s}\n", .{end_label});
        next_label = following;
    }

    if (f.else_body) |eb| {
        try self.out.writer.print("{s}\n", .{next_label});
        const mc_snap = try self.snapshotModCache();
        if (self.detectNarrowedBoxedName(f.cond)) |n| {
            const was_present = self.narrowed_unbox.contains(n.name);
            if (!n.narrows_then) {
                try self.narrowed_unbox.put(self.allocator, n.name, {});
                try self.genStmts(eb, ret_qtype);
                if (!was_present) _ = self.narrowed_unbox.remove(n.name);
            } else {
                try self.genStmts(eb, ret_qtype);
            }
        } else {
            try self.genStmts(eb, ret_qtype);
        }
        self.restoreModCache(mc_snap);
        try self.out.writer.print("    jmp {s}\n", .{end_label});
    }

    try self.out.writer.print("{s}\n", .{end_label});
}

/// Faz GG.5: iç içe geçmiş İFADE ağacının HER YERİNDE (`if`/`while`/`for`/
/// `try`/`with`/`lowlevel` gövdeleri DAHİL) `s[i]` desenini arar, `s`nin
/// `str`-tipli BİR KİMLİK (identifier) OLDUĞU durumlarda `s`yi aday
/// kümesine ekler. `func_def`in (iç içe closure) İÇİNE İNMEZ — bu tarama
/// KENDİSİ `bodyHasNestedFuncDef` tarafından TAMAMEN elenir (bkz. onun
/// belge notu), bu yüzden burada AYRICA bir `func_def` dalı GEREKMEZ.
pub fn collectIndexStrBasesExpr(self: *Codegen, e: ast.Expr, candidates: *std.StringHashMapUnmanaged(void)) CodegenError!void {
    switch (e) {
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
            .func_def, .class_def, .protocol_def, .extern_def, .pass_stmt, .import_stmt, .from_import_stmt => {},
        }
    }
}

pub fn genWhile(self: *Codegen, w: ast.WhileStmt, ret_qtype: QbeType) CodegenError!void {
    const cond_label = try self.newLabel("while_cond");
    const body_label = try self.newLabel("while_body");
    const end_label = try self.newLabel("while_end");

    const str_len_scope = try self.enterStrLenCacheScope(w.body);
    const mc_scope = try self.enterModCacheLoopScope(w.body);
    try self.out.writer.print("    jmp {s}\n", .{cond_label});
    try self.out.writer.print("{s}\n", .{cond_label});
    const cond_v = try self.genExpr(w.cond);
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ cond_v.text, body_label, end_label });
    try self.out.writer.print("{s}\n", .{body_label});
    if (self.detectNarrowedBoxedName(w.cond)) |n| {
        if (n.narrows_then) {
            const was_present = self.narrowed_unbox.contains(n.name);
            try self.narrowed_unbox.put(self.allocator, n.name, {});
            try self.genStmts(w.body, ret_qtype);
            if (!was_present) _ = self.narrowed_unbox.remove(n.name);
        } else {
            try self.genStmts(w.body, ret_qtype);
        }
    } else {
        try self.genStmts(w.body, ret_qtype);
    }
    try self.out.writer.print("    jmp {s}\n", .{cond_label});
    try self.out.writer.print("{s}\n", .{end_label});
    self.restoreModCache(mc_scope);
    self.exitStrLenCacheScope(str_len_scope);
}

pub fn isRangeCall(e: ast.Expr) bool {
    return e == .call and e.call.callee.* == .identifier and
        std.mem.eql(u8, e.call.callee.identifier, "range") and e.call.args.len == 1;
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
    if (f.iterable == .identifier) return self.genForList(f, ret_qtype);
    return error.Unsupported;
}

pub fn genForRange(self: *Codegen, f: ast.ForStmt, ret_qtype: QbeType) CodegenError!void {
    const limit = try self.genExpr(f.iterable.call.args[0]);
    const var_info = self.vars.get(f.var_name).?;
    try self.out.writer.print("    storel 0, {s}\n", .{var_info.slot});

    const cond_label = try self.newLabel("for_cond");
    const body_label = try self.newLabel("for_body");
    const end_label = try self.newLabel("for_end");

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
    try self.out.writer.print("    jmp {s}\n", .{cond_label});
    try self.out.writer.print("{s}\n", .{cond_label});
    const cur = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ cur, var_info.slot });
    const cmp = try self.newTemp();
    try self.out.writer.print("    {s} =w csltl {s}, {s}\n", .{ cmp, cur, limit.text });
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ cmp, body_label, end_label });
    try self.out.writer.print("{s}\n", .{body_label});
    try self.genStmts(f.body, ret_qtype);
    const cur2 = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ cur2, var_info.slot });
    const next = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, 1\n", .{ next, cur2 });
    try self.out.writer.print("    storel {s}, {s}\n", .{ next, var_info.slot });
    try self.out.writer.print("    jmp {s}\n", .{cond_label});
    try self.out.writer.print("{s}\n", .{end_label});
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
    try self.out.writer.print("    storel 0, {s}\n", .{idx_slot});

    const list_ptr = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ list_ptr, list_info.slot });
    const len_t = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ len_t, list_ptr });

    const cond_label = try self.newLabel("forlist_cond");
    const body_label = try self.newLabel("forlist_body");
    const end_label = try self.newLabel("forlist_end");

    const str_len_scope = try self.enterStrLenCacheScope(f.body);
    // `loop_var`e HER yinelemede öğenin DEĞERİ yazılır (aşağıda) —
    // bu da BİR `.assign` AST düğümünü BAYPAS EDER, bu YÜZDEN AYRICA
    // geçersiz kılınır (bkz. `genForRange`nin AYNI notu — SIRA AYNI
    // ŞEKİLDE kritiktir: `enterModCacheLoopScope`DEN ÖNCE).
    try self.modCacheInvalidateName(f.var_name);
    const mc_scope = try self.enterModCacheLoopScope(f.body);
    try self.out.writer.print("    jmp {s}\n", .{cond_label});
    try self.out.writer.print("{s}\n", .{cond_label});
    const idx_cur = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ idx_cur, idx_slot });
    const cmp = try self.newTemp();
    try self.out.writer.print("    {s} =w csltl {s}, {s}\n", .{ cmp, idx_cur, len_t });
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ cmp, body_label, end_label });
    try self.out.writer.print("{s}\n", .{body_label});

    const byte_off = try self.newTemp();
    try self.out.writer.print("    {s} =l mul {s}, {d}\n", .{ byte_off, idx_cur, qbeSizeOf(loop_var.qtype) });
    const off8 = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ off8, byte_off, LIST_HEADER_SIZE });
    const elem_addr = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, {s}\n", .{ elem_addr, list_ptr, off8 });
    const elem_val = try self.newTemp();
    try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ elem_val, qbeTypeName(loop_var.qtype), qbeTypeName(loop_var.qtype), elem_addr });
    try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(loop_var.qtype), elem_val, loop_var.slot });

    try self.genStmts(f.body, ret_qtype);

    const idx_base = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ idx_base, idx_slot });
    const idx_next = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, 1\n", .{ idx_next, idx_base });
    try self.out.writer.print("    storel {s}, {s}\n", .{ idx_next, idx_slot });
    try self.out.writer.print("    jmp {s}\n", .{cond_label});
    try self.out.writer.print("{s}\n", .{end_label});
    self.restoreModCache(mc_scope);
    self.exitStrLenCacheScope(str_len_scope);
}
