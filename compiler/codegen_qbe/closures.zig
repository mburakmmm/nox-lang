//! Closure ("iç içe `def`") + Go-tarzı `defer` codegen'i — bkz. plan dosyası
//! "QBE codegen backend'ini alt modüllere bölme". Faz U.4.3/U.4.4'ün
//! closure-inşa çekirdeği (`buildClosureValue`) VE `defer` mekanizması
//! (checker'ın sentetik `FuncDef`ini AYNI closure çekirdeğiyle inşa eden
//! `genDeferStmt`) burada toplanır — ikisi de AYNI `nox_rc_alloc`+capture
//! deseni ÜZERİNE kuruludur.

const std = @import("std");
const ast = @import("../parser/ast.zig");
const types = @import("types.zig");
const abi = @import("abi.zig");
const codegen = @import("codegen.zig");

const Codegen = codegen.Codegen;
const LocalDecl = types.LocalDecl;
const ClosureCaptureField = types.ClosureCaptureField;
const ClosureFuncSpec = types.ClosureFuncSpec;
const CLOSURE_HEADER_SIZE = types.CLOSURE_HEADER_SIZE;
const CLOSURE_RELEASE_FN_PTR_OFFSET = types.CLOSURE_RELEASE_FN_PTR_OFFSET;
const RT_PARAM = types.RT_PARAM;
const CodegenError = abi.CodegenError;
const sanitizePathToSymbol = abi.sanitizePathToSymbol;
const isHeapManaged = abi.isHeapManaged;

/// Faz U.4.3/U.4.4: bir iç içe `def` DEYİMİNİN (`genStmts`in `.func_def`
/// dalı) codegen'i — DIŞ (kapsayan) fonksiyonun BAĞLAMINDA çalışır
/// (`self.vars` HÂLÂ dış fonksiyonun yerellerini İÇERİR). İKİ İŞ yapar:
/// 1. Closure HEAP BLOĞUNU İNŞA eder (`{fn_ptr: l @0, release_fn_ptr: l
///    @8, yakalananlar... @16+}` — bkz. `HeapKind.closure`in belge notu,
///    Faz U.4.4'ün offset-8'e release fonksiyon işaretçisi EKLEMESİ)
///    — `genConstructFromValues`in AYNI `nox_rc_alloc` + alan-doldurma
///    deseni, ama ALAN İSİMLERİ yerine checker'ın capture SIRASI kullanılır.
///    Her yakalanan DEĞER, DIŞ fonksiyonun O ANKİ slotundan yüklenir;
///    heap-yönetimliyse RETAIN edilir (closure KENDİ bağımsız referansını
///    TUTAR — bkz. nox-teknik-spesifikasyon.md §3.23, "değer anlık
///    görüntüsü" kararı).
/// 2. İç fonksiyonun GÖVDESİNİ (henüz DERLENMEMİŞ) `self.closure_funcs`e
///    TEMBEL kaydeder (bkz. `ClosureFuncSpec`in belge notu) — GERÇEK QBE
///    fonksiyonu `generateModule`nin SONUNDA (`genClosureFunc`) üretilir.
///
/// `fd.name`, ÖNCEDEN (bkz. `collectLocals`in `.func_def` dalı, AYNI
/// `path`/`mangled` FORMÜLÜYLE) `self.vars`e KAYDEDİLMİŞ olmalıdır —
/// burada YALNIZCA o slotun DEĞERİ (yeni inşa edilen pointer) YAZILIR,
/// tıpkı bir `var_decl`in KENDİ slotuna yazması gibi (bkz. `genStmts`in
/// `.var_decl` dalı, AYNI "önce ESKİYİ serbest bırak, SONRA YENİYİ yaz"
/// sırası — bir DÖNGÜ İÇİNDE tekrar tekrar TANIMLANAN bir iç içe `def`
/// İÇİN GÜVENLİ olması İÇİN).
/// `genNestedFuncDef`/`genDeferStmt`nin PAYLAŞTIĞI closure-İNŞA çekirdeği
/// (bkz. `genNestedFuncDef`nin ÖNCEKİ belge notu, "İKİ İŞ" — BU yalnızca
/// 1. işi yapar): `fd`nin closure BLOĞUNU İNŞA edip pointer'ının TEMP
/// adını DÖNER (HİÇBİR yere STORE ETMEDEN — çağıran KENDİ hedefine
/// yazar/GEÇİRİR) VE `fd`nin gövdesini `self.closure_funcs`e TEMBEL
/// kaydeder (`genClosureFunc` bunu SONRADAN üretir).
pub fn buildClosureValue(self: *Codegen, fd: ast.FuncDef) CodegenError![]const u8 {
    const path = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ self.current_path, fd.name });
    const mangled = try sanitizePathToSymbol(self.allocator, path);
    const capture_names = self.closure_infos.get(path) orelse &[_][]const u8{};

    const captures = try self.allocator.alloc(ClosureCaptureField, capture_names.len);
    for (capture_names, 0..) |name, i| {
        const src = self.vars.get(name) orelse return error.Unsupported;
        captures[i] = .{ .name = name, .info = .{
            .qtype = src.qtype,
            .heap = src.heap,
            .elem_qtype = src.elem_qtype,
            .class_name = src.class_name,
            .elem_heap_info = src.elem_heap_info,
            .elem_is_str = src.elem_is_str,
            .dict_info = src.dict_info,
            // Bulundu (nyx framework — bkz. proje belleği "nyx'te farkedilen
            // Nox eksiklikleri" görevi): bu alan EKSİKTİ — `heap == .closure`
            // OLAN bir yakalanan (capture) değerin STATİK çağrı imzası
            // (`func_sig`) BURADA kopyalanmadığından, iç içe `def`in KENDİ
            // gövdesi yakalanan bir FONKSİYON-TİPLİ değeri (ör. `handler(x)`)
            // ÇAĞIRMAYA çalıştığında `genCall`nin dolaylı-çağrı yolu
            // `func_sig`i `null` BULUP `error.Unsupported` dönüyordu — SADECE
            // fonksiyon-tipli yakalamalar ETKİLENİYORDU (list/dict/str/sınıf
            // GİBİ VERİ tipi yakalamalar `func_sig` KULLANMADIĞINDAN
            // sorunsuzdu). `allocSlot` (bkz. `registration.zig`) BU alanı
            // zaten doğru taşıyordu — eksik olan yalnızca BURASIYDI.
            .func_sig = src.func_sig,
        } };
    }

    const total_size = CLOSURE_HEADER_SIZE + 8 * captures.len;
    const block = try self.newTemp();
    try self.qbeCall(.{ .name = block, .ty = .l }, "$nox_rc_alloc", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{total_size}) } });
    const mangled_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{mangled});
    try self.qbeStoreL(mangled_sym, block);
    {
        const rel_addr = try self.newTemp();
        try self.qbeOp2Imm(rel_addr, .l, "add", block, @intCast(CLOSURE_RELEASE_FN_PTR_OFFSET));
        const mangled_release_sym = try std.fmt.allocPrint(self.allocator, "${s}_release", .{mangled});
        try self.qbeStoreL(mangled_release_sym, rel_addr);
    }
    for (captures, 0..) |c, i| {
        const offset = CLOSURE_HEADER_SIZE + 8 * i;
        const addr = try self.newTemp();
        try self.qbeOp2Imm(addr, .l, "add", block, @intCast(offset));
        const src_slot = self.vars.get(c.name).?;
        const v = try self.newTemp();
        try self.qbeLoad(v, src_slot.qtype, src_slot.qtype, src_slot.slot);
        if (isHeapManaged(c.info.heap)) try self.emitInlineRetain(v, c.info.heap);
        try self.qbeStore(src_slot.qtype, v, addr);
    }

    try self.closure_funcs.append(self.allocator, .{ .mangled_name = mangled, .path = path, .fd = fd, .captures = captures });
    return block;
}

pub fn genNestedFuncDef(self: *Codegen, fd: ast.FuncDef) CodegenError!void {
    const block = try self.buildClosureValue(fd);
    const bound = self.vars.get(fd.name).?;
    try self.releaseSlotIfSet(bound);
    try self.qbeStoreL(block, bound.slot);
}

/// Go-tarzı `defer CALL` (bkz. `ast.DeferStmt`nin belge notu) — checker'ın
/// `self.defer_synthetic_names`e (anahtar: `d.call.callee`nin pointer
/// kimliği) KAYDETTİĞİ sentetik adı okuyup, checker'IN KENDİSİNİN
/// `checkDeferStmt`de İNŞA ETTİĞİ AYNI (tek gövde deyimi `expr_stmt
/// (call d.call)` olan) sentetik `ast.FuncDef`i BURADA (codegen
/// tarafında) YENİDEN inşa eder — `buildClosureValue`yi (GERÇEK bir
/// iç içe `def` İLE AYNI mekanizma) ÇAĞIRIP SONUCU bir yerel değişkene
/// STORE ETMEK YERİNE çalışma zamanının `nox_defer_stack_push`ine
/// GEÇİRİR (bkz. `fnBodyHasDefer`/`current_defer_list`nin belge notu).
pub fn genDeferStmt(self: *Codegen, d: ast.DeferStmt, line: u32) CodegenError!void {
    const synthetic_name = self.defer_synthetic_names.get(@intFromPtr(d.call.callee)) orelse return error.Unsupported;
    const body = try self.allocator.alloc(ast.Stmt, 1);
    body[0] = .{ .kind = .{ .expr_stmt = ast.Expr{ .call = d.call } }, .line = line };
    const synthetic_fd: ast.FuncDef = .{
        .name = synthetic_name,
        .type_params = &.{},
        .params = &.{},
        .return_type = .{ .simple = "None" },
        .body = body,
        .is_async = false,
    };
    const closure_ptr = try self.buildClosureValue(synthetic_fd);
    const defer_list = self.current_defer_list orelse return error.Unsupported;
    try self.qbeCall(null, "$nox_defer_stack_push", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = defer_list }, .{ .ty = .l, .text = closure_ptr } });
}

/// `genFunction`/`genMethod`/`genClosureFunc`nin ÜÇÜNÜN de girişinde
/// (parametre store'larından SONRA, `genStmts`den ÖNCE) ÇAĞRILAN TEK
/// nokta — `body` (bu fonksiyonun KENDİ düz-metin gövdesi, İÇ İÇE
/// `func_def` gövdelerine İNMEDEN — bkz. `fnBodyHasDefer`) bir `defer`
/// İÇERİYORSA çalışma-zamanı defer-yığınını OLUŞTURUP `self.current_
/// defer_list`e ATAR, AKSİ HALDE `null` yapar (bir SONRAKİ fonksiyonun
/// KENDİ derlemesine SIZMAMASI İçin HER ZAMAN AÇIKÇA ATANIR).
pub fn setupDeferListIfNeeded(self: *Codegen, body: []const ast.Stmt) CodegenError!void {
    if (fnBodyHasDefer(body)) {
        const dl = try self.newTemp();
        try self.qbeCall(.{ .name = dl, .ty = .l }, "$nox_defer_stack_new", &.{.{ .ty = .l, .text = RT_PARAM }});
        self.current_defer_list = dl;
    } else {
        self.current_defer_list = null;
    }
}

/// TÜM 5 fonksiyon-çıkış noktasında (bkz. görev listesi #62'nin belge
/// notu) `drainFinally`/`drainArenas`den HEMEN SONRA ÇAĞRILIR — İÇ İÇE
/// `try`/`with` blokları KENDİ temizliklerini ÖNCE, fonksiyon-seviyesi
/// `defer` SONRA çalışır (doğal İÇTEN-DIŞA sıralama).
pub fn drainDeferIfSet(self: *Codegen) CodegenError!void {
    if (self.current_defer_list) |dl| {
        try self.qbeCall(null, "$nox_defer_stack_run_all", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = dl } });
    }
}

/// `body`nin (bu fonksiyonun KENDİ düz-metin gövdesi) HERHANGİ bir
/// derinlikte bir `defer_stmt` İÇERİP İÇERMEDİĞİNİ döner — `bodyHasNested
/// FuncDef`in AYNI deseni (`if`/`while`/`for`/`try`/`with`/`lowlevel`
/// gövdelerine RECURSE eder, ama `func_def` İÇİNE İNMEZ — İÇ İÇE bir
/// tanımın KENDİ `defer`leri KENDİ activation'ına AİTTİR).
fn fnBodyHasDefer(body: []const ast.Stmt) bool {
    for (body) |stmt| {
        switch (stmt.kind) {
            .defer_stmt => return true,
            .if_stmt => |f| {
                if (fnBodyHasDefer(f.then_body)) return true;
                for (f.elif_clauses) |ec| if (fnBodyHasDefer(ec.body)) return true;
                if (f.else_body) |eb| if (fnBodyHasDefer(eb)) return true;
            },
            .while_stmt => |w| if (fnBodyHasDefer(w.body)) return true,
            .for_stmt => |f| if (fnBodyHasDefer(f.body)) return true,
            .try_stmt => |t| {
                if (fnBodyHasDefer(t.try_body)) return true;
                for (t.except_clauses) |ec| if (fnBodyHasDefer(ec.body)) return true;
                if (t.finally_body) |fb| if (fnBodyHasDefer(fb)) return true;
            },
            .with_stmt => |w| if (fnBodyHasDefer(w.body)) return true,
            .lowlevel_stmt => |ll| if (fnBodyHasDefer(ll.body)) return true,
            else => {},
        }
    }
    return false;
}

/// Faz U.4.3: `self.closure_funcs`e TEMBEL kaydedilen bir iç içe `def`in
/// GERÇEK gövdesini üretir — `genFunction`in AYNI iskeleti, İKİ FARKLA:
/// (1) imzaya gizli bir `l %env` parametresi (RT_PARAM'DAN HEMEN SONRA)
/// eklenir; (2) HER yakalanan (capture) değer, NORMAL bir parametre
/// GİBİ (`is_param = true` — kapsam-sonu release'i ATLAR, bkz.
/// `LocalDecl`in belge notu, "ödünç alınmış referans" deseni) KENDİ
/// slotuna sahip olur, AMA değeri bir QBE `%p_<isim>` argüman
/// REGISTER'INDAN DEĞİL, `%env`nin `CLOSURE_HEADER_SIZE + 8*i` OFSETİNDEN
/// YÜKLENEREK doldurulur. Bu İKİ FARK dışında gövde (`genStmts`) TAMAMEN NORMAL
/// çalışır — capture'lar "sıradan, ÖNCEDEN doldurulmuş yereller" gibi
/// GÖRÜNÜR.
pub fn genClosureFunc(self: *Codegen, spec: ClosureFuncSpec) CodegenError!void {
    self.vars.clearRetainingCapacity();
    self.narrowed_unbox.clearRetainingCapacity();
    self.temp_counter = 0;
    self.label_counter = 0;
    // Bkz. `Codegen.mod_cache`nin belge notu: slot ADLARI ("%t0", ...)
    // SADECE bir FONKSİYON içinde benzersizdir (`temp_counter` HER
    // fonksiyon BAŞLANGICINDA sıfırlanır, tıpkı BURADA olduğu gibi) —
    // BİR ÖNCEKİ fonksiyondan kalan bir önbellek girdisi, BU fonksiyonda
    // AYNI ADI TAŞIYAN TAMAMEN FARKLI bir slotla YANLIŞLIKLA eşleşebilir
    // (çapraz-fonksiyon çakışması). Bu YÜZDEN HER fonksiyon-benzeri
    // codegen girişinde (`temp_counter`/`label_counter` İLE AYNI
    // noktalarda) TAMAMEN BOŞALTILIR.
    self.mod_cache.deinit(self.allocator);
    self.mod_cache = .empty;
    self.current_path = spec.path;

    const ret_info = try self.resolveType(spec.fd.return_type);
    self.current_ret_qtype = ret_info.qtype;
    self.current_ret_info = ret_info;
    self.current_catch_label = null;
    self.in_main = false;

    var locals: std.ArrayListUnmanaged(LocalDecl) = .empty;
    defer locals.deinit(self.allocator);
    for (spec.captures) |c| {
        try locals.append(self.allocator, .{ .name = c.name, .info = c.info, .is_param = true });
    }
    for (spec.fd.params) |p| {
        try locals.append(self.allocator, .{ .name = p.name, .info = try self.resolveType(p.type_expr), .is_param = true });
    }
    try self.collectLocals(&locals, spec.fd.body, false);

    const mangled_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{spec.mangled_name});
    try self.qbeFuncHeaderStart(if (ret_info.qtype == .none) null else ret_info.qtype, mangled_sym);
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%env", false);
    for (spec.fd.params) |p| {
        const info = try self.resolveType(p.type_expr);
        const param_text = try std.fmt.allocPrint(self.allocator, "%p_{s}", .{p.name});
        try self.qbeFuncParam(info.qtype, param_text, false);
    }
    try self.qbeFuncHeaderEnd();

    try self.registerLocalStackSlots(spec.fd.body, spec.fd.params);
    for (locals.items) |l| try self.allocSlot(l.name, l.info, l.is_param, l.arena);
    try self.prepareInlineSites(spec.fd.body);
    for (spec.captures, 0..) |c, i| {
        const offset = CLOSURE_HEADER_SIZE + 8 * i;
        const info = self.vars.get(c.name).?;
        const addr = try self.newTemp();
        try self.qbeOp2Imm(addr, .l, "add", "%env", @intCast(offset));
        const v = try self.newTemp();
        try self.qbeLoad(v, info.qtype, info.qtype, addr);
        try self.qbeStore(info.qtype, v, info.slot);
    }
    for (spec.fd.params) |p| {
        const info = self.vars.get(p.name).?;
        const param_text = try std.fmt.allocPrint(self.allocator, "%p_{s}", .{p.name});
        try self.qbeStore(info.qtype, param_text, info.slot);
    }
    try self.setupDeferListIfNeeded(spec.fd.body);

    try self.genStmts(spec.fd.body, ret_info.qtype);
    try self.drainDeferIfSet();
    try self.releaseAllLocals();

    const end_label = try self.newLabel("fn_end");
    try self.qbeLabel(end_label);
    try self.emitDefaultReturn(ret_info.qtype);
    try self.qbeFuncEnd();

    try self.genClosureRelease(spec.mangled_name, spec.captures);
}

/// Faz U.4.3: `$<mangled>_release(rt, p)` üretir — `genClassRelease`in
/// AYNI iskeleti (predecrement, sıfıra düşerse HER yakalanan
/// heap-yönetimli/Task/Channel/dict değeri release/destroy et, SONRA
/// `nox_rc_free_payload`). Katman 3'ün döngü-çözücü entegrasyonu
/// (`nox_cycle_possible_root`/`forget`) BİLİNÇLİ OLARAK atlanır — v1
/// kapsamı, `list[T]`/`dict[K,V]` elemanlarıyla AYNI gerekçeyle (bkz.
/// runtime/alloc/cycle_detector.zig'in modül üstü notu, "yalnızca SINIF
/// örnekleri") closure'ları döngü TARAMASININ dışında bırakır.
pub fn genClosureRelease(self: *Codegen, mangled_name: []const u8, captures: []const ClosureCaptureField) CodegenError!void {
    self.temp_counter = 0;
    self.label_counter = 0;
    // Bkz. `Codegen.mod_cache`nin belge notu: slot ADLARI ("%t0", ...)
    // SADECE bir FONKSİYON içinde benzersizdir (`temp_counter` HER
    // fonksiyon BAŞLANGICINDA sıfırlanır, tıpkı BURADA olduğu gibi) —
    // BİR ÖNCEKİ fonksiyondan kalan bir önbellek girdisi, BU fonksiyonda
    // AYNI ADI TAŞIYAN TAMAMEN FARKLI bir slotla YANLIŞLIKLA eşleşebilir
    // (çapraz-fonksiyon çakışması). Bu YÜZDEN HER fonksiyon-benzeri
    // codegen girişinde (`temp_counter`/`label_counter` İLE AYNI
    // noktalarda) TAMAMEN BOŞALTILIR.
    self.mod_cache.deinit(self.allocator);
    self.mod_cache = .empty;

    const mangled_release_sym = try std.fmt.allocPrint(self.allocator, "${s}_release", .{mangled_name});
    try self.qbeFuncHeaderStart(null, mangled_release_sym);
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%p", false);
    try self.qbeFuncHeaderEnd();
    const should_free = try self.emitInlinePredecrement("%p", .closure);
    const free_label = try self.newLabel("release_free");
    const done_label = try self.newLabel("release_done");
    try self.qbeJnz(should_free, free_label, done_label);
    try self.qbeLabel(free_label);
    for (captures, 0..) |c, i| {
        const offset = CLOSURE_HEADER_SIZE + 8 * i;
        if (isHeapManaged(c.info.heap)) {
            const addr = try self.newTemp();
            try self.qbeOp2Imm(addr, .l, "add", "%p", @intCast(offset));
            const fv = try self.newTemp();
            try self.qbeLoadL(fv, addr);
            try self.releaseValueIfSet(fv, c.info.heap, c.info.elem_qtype, c.info.class_name, c.info.elem_heap_info, c.info.dict_info);
        } else if (c.info.heap == .task or c.info.heap == .channel or c.info.heap == .thread_handle or c.info.heap == .thread_channel or c.info.heap == .task_local) {
            const addr = try self.newTemp();
            try self.qbeOp2Imm(addr, .l, "add", "%p", @intCast(offset));
            const fv = try self.newTemp();
            try self.qbeLoadL(fv, addr);
            try self.destroyNonArcValue(fv, c.info.heap);
        }
    }
    const total_size = CLOSURE_HEADER_SIZE + 8 * captures.len;
    try self.qbeCall(null, "$nox_rc_free_payload", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = "%p" }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{total_size}) } });
    try self.qbeJmp(done_label);
    try self.qbeLabel(done_label);
    try self.qbeRet(null);
    try self.qbeFuncEnd();
}

/// Faz U.4.5 (bkz. `checker.zig`nin `checkExpr`'in `.identifier` dalı VE
/// `functions_used_as_value`in belge notu): üst-düzey (non-generic) bir
/// `def`, ÇAĞRI DIŞINDA bir DEĞER olarak kullanıldığında (bir değişkene
/// atama, bir listeye/sınıf alanına KOYMA) BU fonksiyon çağrılır.
///
/// **Neden GEREKLİ (basit bir "değeri closure olarak işaretle" DEĞİL):**
/// üst-düzey bir `def`in KENDİ ABI'si (`registration.zig`nin `genFunction`ı,
/// `export function ... $<isim>(l rt, ...params)`) HİÇBİR `%env`
/// parametresi TAŞIMAZ — ama TÜM dolaylı-çağrı kodu (bkz. `calls.zig`nin
/// `genIndirectCallThroughClosure`ı) HER ZAMAN `fn_ptr(rt, env, ...args)`
/// çağırır (closure pointer'ının KENDİSİ `%env` OLARAK geçirilir, bkz.
/// `HeapKind.closure`in belge notu). Bu YÜZDEN `$<isim>`i DOĞRUDAN
/// `fn_ptr` OLARAK KULLANMAK yanlış argüman SAYISIYLA çağrılmasına yol
/// açardı — KÜÇÜK bir SARMALAYICI (`$<isim>__fnval`, `%env`i YOK SAYIP
/// gerçek fonksiyona DÜZ geçen) GEREKİR. `genClosureRelease`in SIFIR-
/// yakalama yolu (`captures.len == 0`, ZATEN doğru ÇALIŞIYOR — DÖNGÜ
/// gövdesi yalnızca HİÇ ÇALIŞMAZ) bu sarmalayıcının `$<isim>__fnval_
/// release`ını BEDAVA verir, YENİ bir "boş serbest bırakma" yolu
/// YAZILMASINA GEREK KALMAZ.
///
/// `generateModule`nin `registerFunc` geçişinden HEMEN SONRA, HERHANGİ
/// bir fonksiyon GÖVDESİ üretilmeden ÖNCE çağrılır (bkz. onun çağrı
/// sitesi) — bu YÜZDEN `.identifier` codegen'inin (bkz. `expr.zig`)
/// üretilen `$<isim>__fnval` sembolüne REFERANS VERDİĞİ NOKTADA sembol
/// ZATEN VARDIR.
pub fn genFunctionValueTrampoline(self: *Codegen, name: []const u8) CodegenError!void {
    const sig = self.functions.get(name) orelse return error.Unsupported;
    const trampoline_name = try std.fmt.allocPrint(self.allocator, "{s}__fnval", .{name});

    self.temp_counter = 0;
    self.label_counter = 0;
    self.mod_cache.deinit(self.allocator);
    self.mod_cache = .empty;

    const trampoline_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{trampoline_name});
    try self.qbeFuncHeaderStart(if (sig.ret.qtype == .none) null else sig.ret.qtype, trampoline_sym);
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%env", false);
    for (sig.params, 0..) |p, i| {
        const param_text = try std.fmt.allocPrint(self.allocator, "%p{d}", .{i});
        try self.qbeFuncParam(p.qtype, param_text, false);
    }
    try self.qbeFuncHeaderEnd();

    const ret_temp: ?[]const u8 = if (sig.ret.qtype == .none) null else try self.newTemp();
    const inner_args = try self.allocator.alloc(codegen.QbeArg, 1 + sig.params.len);
    inner_args[0] = .{ .ty = .l, .text = RT_PARAM };
    for (sig.params, 0..) |p, i| {
        inner_args[1 + i] = .{ .ty = p.qtype, .text = try std.fmt.allocPrint(self.allocator, "%p{d}", .{i}) };
    }
    const name_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{name});
    try self.qbeCall(if (ret_temp) |rv| .{ .name = rv, .ty = sig.ret.qtype } else null, name_sym, inner_args);
    // Faz U.4.5: burada `emitExceptionCheck` GEREKMEZ — `name`nin ATTIĞI
    // bir istisna (bu çalışma zamanının paylaşılan/genel istisna
    // BAYRAĞI mekanizmasıyla) BURADA temizlenmeden geçer, DIŞ dolaylı-
    // çağrı sitesi (`genIndirectCallThroughClosure`, HER ZAMAN çağrı
    // SONRASI kontrol eder — hedef derleme-zamanında BİLİNMEDİĞİNDEN
    // eleme YAPILAMAZ) BUNU zaten YAKALAR; sarmalayıcının ARADA hiçbir
    // temizlik/ARC işi YOK, erken dönmeye GEREK yok.
    try self.qbeRet(ret_temp);
    try self.qbeFuncEnd();

    try self.genClosureRelease(trampoline_name, &.{});
}
