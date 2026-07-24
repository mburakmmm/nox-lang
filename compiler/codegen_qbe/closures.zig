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
const qbeTypeName = abi.qbeTypeName;
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
        } };
    }

    const total_size = CLOSURE_HEADER_SIZE + 8 * captures.len;
    const block = try self.newTemp();
    try self.out.writer.print("    {s} =l call $nox_rc_alloc(l {s}, l {d})\n", .{ block, RT_PARAM, total_size });
    try self.out.writer.print("    storel ${s}, {s}\n", .{ mangled, block });
    {
        const rel_addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ rel_addr, block, CLOSURE_RELEASE_FN_PTR_OFFSET });
        try self.out.writer.print("    storel ${s}_release, {s}\n", .{ mangled, rel_addr });
    }
    for (captures, 0..) |c, i| {
        const offset = CLOSURE_HEADER_SIZE + 8 * i;
        const addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ addr, block, offset });
        const src_slot = self.vars.get(c.name).?;
        const v = try self.newTemp();
        try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ v, qbeTypeName(src_slot.qtype), qbeTypeName(src_slot.qtype), src_slot.slot });
        if (isHeapManaged(c.info.heap)) try self.emitInlineRetain(v);
        try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(src_slot.qtype), v, addr });
    }

    try self.closure_funcs.append(self.allocator, .{ .mangled_name = mangled, .path = path, .fd = fd, .captures = captures });
    return block;
}

pub fn genNestedFuncDef(self: *Codegen, fd: ast.FuncDef) CodegenError!void {
    const block = try self.buildClosureValue(fd);
    const bound = self.vars.get(fd.name).?;
    try self.releaseSlotIfSet(bound);
    try self.out.writer.print("    storel {s}, {s}\n", .{ block, bound.slot });
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
    try self.out.writer.print("    call $nox_defer_stack_push(l {s}, l {s}, l {s})\n", .{ RT_PARAM, defer_list, closure_ptr });
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
        try self.out.writer.print("    {s} =l call $nox_defer_stack_new(l {s})\n", .{ dl, RT_PARAM });
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
        try self.out.writer.print("    call $nox_defer_stack_run_all(l {s}, l {s})\n", .{ RT_PARAM, dl });
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

    if (ret_info.qtype == .none) {
        try self.out.writer.print("export function ${s}(l {s}, l %env", .{ spec.mangled_name, RT_PARAM });
    } else {
        try self.out.writer.print("export function {s} ${s}(l {s}, l %env", .{ qbeTypeName(ret_info.qtype), spec.mangled_name, RT_PARAM });
    }
    for (spec.fd.params) |p| {
        try self.out.writer.writeAll(", ");
        const info = try self.resolveType(p.type_expr);
        try self.out.writer.print("{s} %p_{s}", .{ qbeTypeName(info.qtype), p.name });
    }
    try self.out.writer.writeAll(") {\n@start\n");

    for (locals.items) |l| try self.allocSlot(l.name, l.info, l.is_param, l.arena);
    try self.prepareInlineSites(spec.fd.body);
    for (spec.captures, 0..) |c, i| {
        const offset = CLOSURE_HEADER_SIZE + 8 * i;
        const info = self.vars.get(c.name).?;
        const addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add %env, {d}\n", .{ addr, offset });
        const v = try self.newTemp();
        try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ v, qbeTypeName(info.qtype), qbeTypeName(info.qtype), addr });
        try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(info.qtype), v, info.slot });
    }
    for (spec.fd.params) |p| {
        const info = self.vars.get(p.name).?;
        try self.out.writer.print("    store{s} %p_{s}, {s}\n", .{ qbeTypeName(info.qtype), p.name, info.slot });
    }
    try self.setupDeferListIfNeeded(spec.fd.body);

    try self.genStmts(spec.fd.body, ret_info.qtype);
    try self.drainDeferIfSet();
    try self.releaseAllLocals();

    const end_label = try self.newLabel("fn_end");
    try self.out.writer.print("{s}\n", .{end_label});
    try self.emitDefaultReturn(ret_info.qtype);
    try self.out.writer.writeAll("}\n");

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

    try self.out.writer.print("export function ${s}_release(l {s}, l %p) {{\n@start\n", .{ mangled_name, RT_PARAM });
    const should_free = try self.emitInlinePredecrement("%p");
    const free_label = try self.newLabel("release_free");
    const done_label = try self.newLabel("release_done");
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ should_free, free_label, done_label });
    try self.out.writer.print("{s}\n", .{free_label});
    for (captures, 0..) |c, i| {
        const offset = CLOSURE_HEADER_SIZE + 8 * i;
        if (isHeapManaged(c.info.heap)) {
            const addr = try self.newTemp();
            try self.out.writer.print("    {s} =l add %p, {d}\n", .{ addr, offset });
            const fv = try self.newTemp();
            try self.out.writer.print("    {s} =l loadl {s}\n", .{ fv, addr });
            try self.releaseValueIfSet(fv, c.info.heap, c.info.elem_qtype, c.info.class_name, c.info.elem_heap_info, c.info.dict_info);
        } else if (c.info.heap == .task or c.info.heap == .channel or c.info.heap == .thread_handle or c.info.heap == .thread_channel) {
            const addr = try self.newTemp();
            try self.out.writer.print("    {s} =l add %p, {d}\n", .{ addr, offset });
            const fv = try self.newTemp();
            try self.out.writer.print("    {s} =l loadl {s}\n", .{ fv, addr });
            try self.destroyNonArcValue(fv, c.info.heap);
        }
    }
    const total_size = CLOSURE_HEADER_SIZE + 8 * captures.len;
    try self.out.writer.print("    call $nox_rc_free_payload(l {s}, l %p, l {d})\n", .{ RT_PARAM, total_size });
    try self.out.writer.print("    jmp {s}\n", .{done_label});
    try self.out.writer.print("{s}\n", .{done_label});
    try self.out.writer.writeAll("    ret\n}\n");
}
