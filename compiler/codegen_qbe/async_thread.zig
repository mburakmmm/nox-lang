//! Async/thread/HTTP-sarmalayıcı tespiti + codegen'i — bkz. plan dosyası
//! "QBE codegen backend'ini alt modüllere bölme". `spawn`/`await`/
//! `Channel[T]`/`nox.thread.start`/`nox.http.serve*` ile ilgili KOD YOLLARI
//! burada toplanır.

const std = @import("std");
const ast = @import("../parser/ast.zig");
const types = @import("types.zig");
const abi = @import("abi.zig");
const codegen = @import("codegen.zig");

const Codegen = codegen.Codegen;
const Value = types.Value;
const QbeType = types.QbeType;
const ElemHeapInfo = types.ElemHeapInfo;
const SpawnWrapperSpec = types.SpawnWrapperSpec;
const ThreadWrapperSpec = types.ThreadWrapperSpec;
const RT_PARAM = types.RT_PARAM;
const CodegenError = abi.CodegenError;
const qbeTypeName = abi.qbeTypeName;
const valueFromElemDescriptor = abi.valueFromElemDescriptor;

/// Modülün (üst düzey deyimler + tüm fonksiyon/metod gövdeleri) HERHANGİ bir
/// yerinde `async` özelliği (bir `async def`, `spawn`, `await`, ya da
/// `Channel[T](...)`) kullanılıp kullanılmadığını belirler — `generateModule`
/// bunu, `main`i fiber-sarmalı bir kökle mi (`genMainAsync`) yoksa ŞİMDİYE
/// KADAR OLDUĞU GİBİ değişmeden mi (`genMain`) üreteceğine karar vermek için
/// kullanır.
pub fn moduleUsesAsync(module: ast.Module, extra_functions: []const ast.FuncDef) bool {
    for (module.body) |stmt| if (stmtUsesAsync(stmt)) return true;
    for (extra_functions) |fd| {
        if (fd.is_async) return true;
        for (fd.body) |s| if (stmtUsesAsync(s)) return true;
    }
    return false;
}

pub fn stmtUsesAsync(stmt: ast.Stmt) bool {
    return switch (stmt.kind) {
        .expr_stmt => |e| exprUsesAsync(e),
        .var_decl => |v| exprUsesAsync(v.value),
        .assign => |a| exprUsesAsync(a.target) or exprUsesAsync(a.value),
        .if_stmt => |f| blk: {
            if (exprUsesAsync(f.cond)) break :blk true;
            for (f.then_body) |s| if (stmtUsesAsync(s)) break :blk true;
            for (f.elif_clauses) |ec| {
                if (exprUsesAsync(ec.cond)) break :blk true;
                for (ec.body) |s| if (stmtUsesAsync(s)) break :blk true;
            }
            if (f.else_body) |eb| for (eb) |s| if (stmtUsesAsync(s)) break :blk true;
            break :blk false;
        },
        .while_stmt => |w| blk: {
            if (exprUsesAsync(w.cond)) break :blk true;
            for (w.body) |s| if (stmtUsesAsync(s)) break :blk true;
            break :blk false;
        },
        .for_stmt => |f| blk: {
            if (exprUsesAsync(f.iterable)) break :blk true;
            for (f.body) |s| if (stmtUsesAsync(s)) break :blk true;
            break :blk false;
        },
        .func_def => |fd| blk: {
            if (fd.is_async) break :blk true;
            for (fd.body) |s| if (stmtUsesAsync(s)) break :blk true;
            break :blk false;
        },
        .class_def => |cd| blk: {
            for (cd.methods) |m| {
                if (m.is_async) break :blk true;
                for (m.body) |s| if (stmtUsesAsync(s)) break :blk true;
            }
            break :blk false;
        },
        .protocol_def, .extern_def, .pass_stmt, .import_stmt, .from_import_stmt => false,
        .return_stmt => |r| if (r) |e| exprUsesAsync(e) else false,
        .raise_stmt => |e| exprUsesAsync(e),
        .try_stmt => |t| blk: {
            for (t.try_body) |s| if (stmtUsesAsync(s)) break :blk true;
            for (t.except_clauses) |ec| for (ec.body) |s| if (stmtUsesAsync(s)) break :blk true;
            if (t.finally_body) |fb| for (fb) |s| if (stmtUsesAsync(s)) break :blk true;
            break :blk false;
        },
        .lowlevel_stmt => |ll| blk: {
            for (ll.body) |s| if (stmtUsesAsync(s)) break :blk true;
            break :blk false;
        },
        .with_stmt => |w| blk: {
            if (exprUsesAsync(w.ctx_expr)) break :blk true;
            for (w.body) |s| if (stmtUsesAsync(s)) break :blk true;
            break :blk false;
        },
        .defer_stmt => |d| exprUsesAsync(ast.Expr{ .call = d.call }),
    };
}

/// `nox.<module>.<name>(...)` çağrı sitesinin callee'sinin TAM OLARAK bu
/// şekilde (üç seviyeli `Attribute`/`Attribute`/`identifier` zinciri)
/// ayrıştırılıp ayrıştırılMADIĞINI belirler.
///
/// Faz P1.6 (bkz. proje belleği "stdlib-vs-language boundary" kararı):
/// ÖNCEDEN bu, yalnızca "http" modülüne özel `matchesNoxHttpAttr` OLARAK
/// (VE `nox.thread.start` İçin AYNI yürüyüşü TEKRARLAYAN AYRI bir
/// `isThreadStartCallee` OLARAK) İKİ KOPYA halinde vardı — TEK parametrik
/// sürüme birleştirildi (bkz. AŞAĞIDAKİ `intrinsic_table`/`matchIntrinsicKind`).
pub fn matchesNoxAttr(callee: ast.Expr, module: []const u8, name: []const u8) bool {
    if (callee != .attribute) return false;
    const attr = callee.attribute;
    if (!std.mem.eql(u8, attr.attr, name)) return false;
    if (attr.obj.* != .attribute) return false;
    const mod_attr = attr.obj.attribute;
    if (!std.mem.eql(u8, mod_attr.attr, module)) return false;
    if (mod_attr.obj.* != .identifier) return false;
    return std.mem.eql(u8, mod_attr.obj.identifier, "nox");
}

/// Codegen'in genel çağrı yolunun (bkz. `calls.zig`nin `genCall`i, `.attribute`
/// dalı) ÖZEL bir kod yolu GEREKTİREN (sıradan bir fonksiyon çağrısına
/// İNDİRGENEMEYEN — ör. bir sarmalayıcı/thread/worker fonksiyonu İNŞA ETMESİ
/// gereken) bir stdlib "intrinsic" çağrısını sınıflandırır. Bu, P1.1'in
/// `http_intrinsics.zig`nin modül üstü notunun İŞARET ettiği "P1.6'nın GENEL
/// intrinsic mekanizması" — ÖNCEDEN `genCall`/`exprUsesAsync` HER İKİSİ de,
/// HER intrinsic İçin AYRI bir `isXCallee` fonksiyonuna karşı SIRALI `if`
/// zincirleri taşıyordu (4 kontrol × 2 çağrı sitesi). YENİ bir intrinsic
/// EKLEMEK ARTIK yalnızca `intrinsic_table`e BİR satır + `IntrinsicKind`e
/// BİR varyant + `genCall`nin dispatch switch'ine BİR `case` eklemektir —
/// `exprUsesAsync` HİÇ DEĞİŞMEZ (TÜM intrinsic'ler ZATEN async-tetikleyici
/// olduğundan `matchIntrinsicKind(...) != null` TEK kontrolü yeterlidir).
pub const IntrinsicKind = enum { http_serve, http_serve_fd, http_serve_multicore, thread_start };

const IntrinsicEntry = struct { module: []const u8, name: []const u8, kind: IntrinsicKind };

const intrinsic_table = [_]IntrinsicEntry{
    .{ .module = "http", .name = "serve", .kind = .http_serve },
    .{ .module = "http", .name = "serve_fd", .kind = .http_serve_fd },
    .{ .module = "http", .name = "serve_multicore", .kind = .http_serve_multicore },
    .{ .module = "thread", .name = "start", .kind = .thread_start },
};

pub fn matchIntrinsicKind(callee: ast.Expr) ?IntrinsicKind {
    for (intrinsic_table) |entry| {
        if (matchesNoxAttr(callee, entry.module, entry.name)) return entry.kind;
    }
    return null;
}

pub fn exprUsesAsync(expr: ast.Expr) bool {
    return switch (expr) {
        .await_expr, .spawn_expr, .generic_construct => true,
        .unary => |u| exprUsesAsync(u.operand.*),
        .binary => |b| exprUsesAsync(b.left.*) or exprUsesAsync(b.right.*),
        .call => |c| blk: {
            if (matchIntrinsicKind(c.callee.*) != null) break :blk true;
            if (exprUsesAsync(c.callee.*)) break :blk true;
            for (c.args) |a| if (exprUsesAsync(a)) break :blk true;
            break :blk false;
        },
        .attribute => |a| exprUsesAsync(a.obj.*),
        .index => |idx| exprUsesAsync(idx.obj.*) or exprUsesAsync(idx.index.*),
        .list_lit => |elems| blk: {
            for (elems) |el| if (exprUsesAsync(el)) break :blk true;
            break :blk false;
        },
        .dict_lit => |pairs| blk: {
            for (pairs) |p| {
                if (exprUsesAsync(p.key) or exprUsesAsync(p.value)) break :blk true;
            }
            break :blk false;
        },
        .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => false,
    };
}

/// `spawn <hedef_fn>(args...)` — checker ZATEN operandın `.call` olup
/// `.identifier` bir `async def`e başvurduğunu doğruladı (bkz.
/// checker.zig'in `.spawn_expr` dalı); codegen burada bu ŞEKLE GÜVENİR.
/// Argümanlar bir kapanış (closure) struct'ına PAKETLENİR (`rt` + her
/// argüman, 8 baytlık aralıklarla — `nox_alloc` ile tahsis edilir,
/// sarmalayıcı KENDİSİ tüketip serbest bırakır, bkz. `genSpawnWrapper`).
/// `async def` parametreleri checker tarafından FFI-güvenli tiplerle
/// (int/float/bool/str/None) SINIRLANDI (bkz. checker.zig, `registerFunc`)
/// — bu yüzden hiçbir ARC retain/release GEREKMEZ.
pub fn genSpawnExpr(self: *Codegen, operand: ast.Expr) CodegenError!Value {
    const call = operand.call;
    const fn_name = call.callee.identifier;
    const sig = self.functions.get(fn_name) orelse return error.Unsupported;
    if (sig.params.len != call.args.len) return error.Unsupported;

    const arg_values = try self.allocator.alloc(Value, call.args.len);
    for (call.args, 0..) |a, i| {
        const v0 = try self.genExpr(a);
        arg_values[i] = try self.convert(v0, sig.params[i].qtype);
    }

    const closure_size = 8 + 8 * call.args.len;
    const closure = try self.newTemp();
    try self.out.writer.print("    {s} =l call $nox_alloc(l {s}, l {d})\n", .{ closure, RT_PARAM, closure_size });
    try self.out.writer.print("    storel {s}, {s}\n", .{ RT_PARAM, closure });
    for (arg_values, 0..) |av, i| {
        const off = 8 + 8 * i;
        const addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ addr, closure, off });
        try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(av.qtype), av.text, addr });
    }

    const wrapper_name = try std.fmt.allocPrint(self.allocator, "spawn_wrap_{d}", .{self.spawn_wrapper_counter});
    self.spawn_wrapper_counter += 1;
    try self.spawn_wrappers.append(self.allocator, .{ .name = wrapper_name, .target_fn = fn_name, .sig = sig });

    const task_ptr = try self.newTemp();
    try self.out.writer.print("    {s} =l call $nox_async_spawn(l {s}, l ${s}, l {s})\n", .{ task_ptr, RT_PARAM, wrapper_name, closure });

    var elem_heap_info: ?*const ElemHeapInfo = null;
    if (sig.ret.heap == .class or sig.ret.heap == .list) {
        const info = try self.allocator.create(ElemHeapInfo);
        info.* = .{ .heap = sig.ret.heap, .class_name = sig.ret.class_name, .elem_qtype = sig.ret.elem_qtype, .nested = sig.ret.elem_heap_info, .elem_is_str = sig.ret.elem_is_str };
        elem_heap_info = info;
    }
    // `Task[T]`nin KENDİSİ (görev tutamacı) ARC-yönetimli DEĞİLDİR (bkz.
    // `HeapKind`in belge notu) — `heap = .task` yalnızca kapsam-sonu
    // `nox_async_destroy_task` çağrısını tetiklemek İÇİNDİR; `elem_*`
    // alanları T'yi (payload tipini) taşır.
    return .{
        .text = task_ptr,
        .qtype = .l,
        .heap = .task,
        .elem_qtype = sig.ret.qtype,
        .elem_heap_info = elem_heap_info,
        .elem_is_str = sig.ret.heap == .str,
    };
}

/// `nox_async_spawn`in çağırdığı, `spawn` çağrı sitesi başına üretilen
/// bir fiber girişi — bkz. `SpawnWrapperSpec`in belge notu. `%argp`den
/// (kapanış) argümanları paketten çıkarır, `spec.target_fn`i normal
/// şekilde çağırır, sonucu bir `i64` payload'a çevirir, kapanışı serbest
/// bırakır.
///
/// **Bilinçli v0.1 sınırlaması:** `spec.target_fn`in içinde bir istisna
/// oluşup YAKALANMAZSA, bu BURADA denetlenmez/temizlenmez (bkz.
/// nox-teknik-spesifikasyon.md §3.21'in "kalan" notu) — Nox'un istisna
/// mekanizmasının async görevlerle tam entegrasyonu ayrı bir artımdır.
pub fn genSpawnWrapper(self: *Codegen, spec: SpawnWrapperSpec) CodegenError!void {
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

    try self.out.writer.print("export function l ${s}(l %argp) {{\n@start\n", .{spec.name});
    try self.out.writer.print("    {s} =l loadl %argp\n", .{RT_PARAM});

    const arg_texts = try self.allocator.alloc([]const u8, spec.sig.params.len);
    for (spec.sig.params, 0..) |p, i| {
        const off = 8 + 8 * i;
        const addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add %argp, {d}\n", .{ addr, off });
        const val = try self.newTemp();
        try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ val, qbeTypeName(p.qtype), qbeTypeName(p.qtype), addr });
        arg_texts[i] = val;
    }

    const payload = blk: {
        if (spec.sig.ret.qtype == .none) {
            try self.out.writer.print("    call ${s}(l {s}", .{ spec.target_fn, RT_PARAM });
            for (spec.sig.params, arg_texts) |p, at| try self.out.writer.print(", {s} {s}", .{ qbeTypeName(p.qtype), at });
            try self.out.writer.writeAll(")\n");
            break :blk Value{ .text = "0", .qtype = .l };
        }
        const result_t = try self.newTemp();
        try self.out.writer.print("    {s} ={s} call ${s}(l {s}", .{ result_t, qbeTypeName(spec.sig.ret.qtype), spec.target_fn, RT_PARAM });
        for (spec.sig.params, arg_texts) |p, at| try self.out.writer.print(", {s} {s}", .{ qbeTypeName(p.qtype), at });
        try self.out.writer.writeAll(")\n");
        break :blk try self.toPayload(.{ .text = result_t, .qtype = spec.sig.ret.qtype });
    };

    const closure_size = 8 + 8 * spec.sig.params.len;
    try self.out.writer.print("    call $nox_free(l {s}, l %argp, l {d})\n", .{ RT_PARAM, closure_size });
    try self.out.writer.print("    ret {s}\n}}\n", .{payload.text});
}

/// `nox.thread.start(entry, arg)` çağrı sitesi codegen'i — Faz BB.4
/// (bkz. nox-teknik-spesifikasyon.md §3.50). Checker ZATEN `entry`in
/// ÇIPLAK bir `async def` ismi OLDUĞUNU, `arg`ın tipinin `entry`in TEK
/// parametresiyle UYUŞTUĞUNU VE HER İKİSİNİN de `isThreadTransferSafeType`den
/// GEÇTİĞİNİ doğruladı (bkz. checker.zig'in `tryResolveThreadSpawnCall`ı).
///
/// `genSpawnExpr`DEN FARKLI: `arg`ın (str İSE) hazırlık-arabelleğine
/// KOPYALANMASI VE ÇOCUK iş parçacığının KENDİ `RuntimeState`i ÜZERİNDEN
/// taze bir ARC `str` İNŞA ETMESİ TAMAMEN `runtime/async_rt/thread_bridge.
/// zig`nin `nox_thread_spawn`ının/`childThreadMain`inin İÇİNDE olur —
/// BURADA (çağrı SİTESİNDE) `arg`ın kendisi SADECE `toPayload`a çevrilip
/// `nox_thread_spawn`a AKTARILIR, `arg_is_str`/`result_is_str` (statik
/// olarak `entry`in İMZASINDAN türetilir) O tarafın HANGİ protokolü
/// (düz payload mı, str-klonlama mı) İZLEYECEĞİNİ SÖYLER. `arg` İÇİN
/// (Faz BB.2'nin belge notunda AÇIKLANDIĞI GİBİ) HİÇBİR ÖZEL retain
/// GEREKMEZ — `nox_thread_spawn` orijinal işaretçiyi ASLA SAKLAMAZ,
/// yalnızca SENKRON olarak baytlarını OKUR/KOPYALAR (normal bir
/// fonksiyon argümanı GİBİ davranır, `spawn`ın kapanış-paketlemesinin
/// AKSİNE).
pub fn genThreadStartExpr(self: *Codegen, c: ast.Call) CodegenError!Value {
    if (c.args.len != 2) return error.Unsupported;
    const fn_name = switch (c.args[0]) {
        .identifier => |n| n,
        else => return error.Unsupported,
    };
    const sig = self.functions.get(fn_name) orelse return error.Unsupported;
    if (sig.params.len != 1) return error.Unsupported;

    const arg_v0 = try self.genExpr(c.args[1]);
    const arg_v = try self.convert(arg_v0, sig.params[0].qtype);
    const arg_payload = try self.toPayload(arg_v);

    const arg_is_str: []const u8 = if (sig.params[0].heap == .str) "1" else "0";
    const result_is_str: []const u8 = if (sig.ret.heap == .str) "1" else "0";

    const wrapper_name = try std.fmt.allocPrint(self.allocator, "thread_wrap_{d}", .{self.thread_wrapper_counter});
    self.thread_wrapper_counter += 1;
    try self.thread_wrappers.append(self.allocator, .{ .name = wrapper_name, .target_fn = fn_name, .sig = sig });

    const handle_ptr = try self.newTemp();
    try self.out.writer.print("    {s} =l call $nox_thread_spawn(l {s}, l ${s}, l {s}, w {s}, w {s})\n", .{ handle_ptr, RT_PARAM, wrapper_name, arg_payload.text, arg_is_str, result_is_str });

    var elem_heap_info: ?*const ElemHeapInfo = null;
    if (sig.ret.heap == .class or sig.ret.heap == .list) {
        const info = try self.allocator.create(ElemHeapInfo);
        info.* = .{ .heap = sig.ret.heap, .class_name = sig.ret.class_name, .elem_qtype = sig.ret.elem_qtype, .nested = sig.ret.elem_heap_info, .elem_is_str = sig.ret.elem_is_str };
        elem_heap_info = info;
    }
    // `ThreadHandle[T]`in KENDİSİ (bkz. `HeapKind`in belge notu) ARC-
    // yönetimli DEĞİLDİR — `heap = .thread_handle` yalnızca kapsam-sonu
    // `nox_thread_destroy` çağrısını TETİKLEMEK içindir; `elem_*` alanları
    // T'yi (payload tipini) taşır.
    return .{
        .text = handle_ptr,
        .qtype = .l,
        .heap = .thread_handle,
        .elem_qtype = sig.ret.qtype,
        .elem_heap_info = elem_heap_info,
        .elem_is_str = sig.ret.heap == .str,
    };
}

/// `nox_thread_spawn`ın çağırdığı, `nox.thread.start` çağrı sitesi
/// başına üretilen bir ÇOCUK İŞ PARÇACIĞI girişi — bkz. `ThreadWrapperSpec`in
/// belge notu. `genSpawnWrapper`DEN İKİ noktada FARKLI: (1) argüman
/// SAYISI HER ZAMAN TAM OLARAK 1'dir (Tier 1'in kısıtı); (2) kapanış
/// (`ThreadEntryClosure`) native-qtype'lı DEĞİL, HER ZAMAN `l` (i64)
/// genişliğinde bir `payload` alanı TAŞIR (bkz. `thread_bridge.zig`nin
/// Zig struct TANIMI) — bu yüzden argüman `loadl` İLE okunup `fromPayload`
/// İLE hedef tipe ÇEVRİLİR (`genSpawnWrapper`nin native `load{qtype}`inin
/// AKSİNE). Kapanışın KENDİSİ (`ThreadEntryClosure`) `runtime/async_rt/
/// thread_bridge.zig`nin `childThreadMain`i TARAFINDAN (SAF Zig'de)
/// tahsis edilip serbest BIRAKILIR — BURADA `nox_free` ÇAĞRILMAZ
/// (`genSpawnWrapper`nin kapanışının AKSİNE, bkz. `ThreadWrapperSpec`in
/// belge notu).
pub fn genThreadStartWrapper(self: *Codegen, spec: ThreadWrapperSpec) CodegenError!void {
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

    try self.out.writer.print("export function l ${s}(l %argp) {{\n@start\n", .{spec.name});
    try self.out.writer.print("    {s} =l loadl %argp\n", .{RT_PARAM});

    const payload_addr = try self.newTemp();
    try self.out.writer.print("    {s} =l add %argp, 8\n", .{payload_addr});
    const payload_val = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ payload_val, payload_addr });
    const arg_val = try self.fromPayload(.{ .text = payload_val, .qtype = .l }, spec.sig.params[0].qtype);

    const result_payload = blk: {
        if (spec.sig.ret.qtype == .none) {
            try self.out.writer.print("    call ${s}(l {s}, {s} {s})\n", .{ spec.target_fn, RT_PARAM, qbeTypeName(arg_val.qtype), arg_val.text });
            break :blk Value{ .text = "0", .qtype = .l };
        }
        const result_t = try self.newTemp();
        try self.out.writer.print("    {s} ={s} call ${s}(l {s}, {s} {s})\n", .{ result_t, qbeTypeName(spec.sig.ret.qtype), spec.target_fn, RT_PARAM, qbeTypeName(arg_val.qtype), arg_val.text });
        break :blk try self.toPayload(.{ .text = result_t, .qtype = spec.sig.ret.qtype });
    };

    // Parametreler `spec.target_fn` TARAFINDAN ÖDÜNÇ ALINIR (bkz.
    // `collectLocals`/`allocSlot`in `is_param` notu — kapsam-sonu
    // otomatik release'i HER ZAMAN ATLAR) — çağrı SİTESİ (BURASI)
    // sahipliği ELİNDE TUTAR (normal `genCall`nin `releaseTemporaryArgs`
    // İLE AYNI sözleşme). `arg_val` BURADA `childThreadMain`in TAZE
    // klonladığı, TEK sahipli bir ARC `str`tir (Tier 1 SADECE `str`i
    // heap-yönetimli tip olarak KABUL EDER) — çağrı DÖNDÜKTEN SONRA
    // BURADA serbest bırakılMAZSA sızar (bu, `dupeToNoxStr`in Faz BB.4
    // uçtan uca golden testinde YAKALANAN GERÇEK bir sızıntıydı).
    if (spec.sig.params[0].heap == .str) {
        try self.releaseValueIfSet(arg_val.text, .str, .none, null, null, null);
    }

    try self.out.writer.print("    ret {s}\n}}\n", .{result_payload.text});
}

/// `handle.join()` — YALNIZCA `await` üzerinden (bkz. `genAwaitExpr`)
/// çağrılır, `genCall`in normal metod-çağrısı yolundan GEÇMEZ
/// (`ThreadHandle` `self.classes`de yok, yerleşik bir tiptir) —
/// `genChannelOp`in `recv` dalıyla AYNI desen.
pub fn genThreadHandleJoin(self: *Codegen, a: ast.Attribute) CodegenError!Value {
    const handle_val = try self.genExpr(a.obj.*);
    const payload_t = try self.newTemp();
    try self.out.writer.print("    {s} =l call $nox_thread_join(l {s}, l {s})\n", .{ payload_t, RT_PARAM, handle_val.text });
    const converted = try self.fromPayload(.{ .text = payload_t, .qtype = .l }, handle_val.elem_qtype);
    return valueFromElemDescriptor(converted.text, converted.qtype, handle_val.elem_heap_info, handle_val.elem_is_str);
}

/// `await <ifade>` — checker ZATEN operandın ya bir `Task` değeri ya da
/// bir `Channel.send`/`recv` çağrısı olduğunu doğruladı (bkz. checker'ın
/// `.await_expr` dalı); codegen AYNI şekle bakarak dallanır.
pub fn genAwaitExpr(self: *Codegen, operand: ast.Expr) CodegenError!Value {
    if (operand == .call) {
        const c = operand.call;
        if (c.callee.* == .attribute) {
            const a = c.callee.attribute;
            if (std.mem.eql(u8, a.attr, "send") or std.mem.eql(u8, a.attr, "recv")) {
                // Alıcının statik tipi (`Channel[T]` mi `ThreadChannel[T]`
                // mi) BİR KEZ değerlendirilir — Faz BB.6: `ThreadChannel`
                // AYRI bir çalışma-zamanı protokolü (`nox_threadchannel_*`,
                // dual-pipe) kullandığından `genChannelOp`DAN AYRI bir
                // fonksiyona (`genThreadChannelOp`) dispatch edilir.
                const recv_val = try self.genExpr(a.obj.*);
                if (recv_val.heap == .thread_channel) return self.genThreadChannelOp(a, c.args, recv_val);
                return self.genChannelOp(a, c.args, recv_val);
            }
            // Faz BB.4: `ThreadHandle[T].join()` — `Channel.send`/`.recv`
            // İLE AYNI "yalnızca await üzerinden" desen (bkz.
            // `genThreadHandleJoin`in belge notu).
            if (std.mem.eql(u8, a.attr, "join")) {
                return self.genThreadHandleJoin(a);
            }
        }
    }
    const task_val = try self.genExpr(operand);
    const payload_t = try self.newTemp();
    try self.out.writer.print("    {s} =l call $nox_async_await(l {s}, l {s})\n", .{ payload_t, RT_PARAM, task_val.text });
    const converted = try self.fromPayload(.{ .text = payload_t, .qtype = .l }, task_val.elem_qtype);
    return valueFromElemDescriptor(converted.text, converted.qtype, task_val.elem_heap_info, task_val.elem_is_str);
}

/// `ch.send(v)`/`ch.recv()` — YALNIZCA `await` üzerinden (bkz.
/// `genAwaitExpr`) çağrılır, `genCall`in normal metod-çağrısı yolundan
/// GEÇMEZ (`Channel` `self.classes`de yok, yerleşik bir tiptir). `ch_val`
/// `genAwaitExpr` TARAFINDAN ZATEN değerlendirilmiştir (Faz BB.6: alıcı
/// tipinin `Channel` mi `ThreadChannel` mi OLDUĞUNU görmek İÇİN zaten
/// BİR KEZ değerlendirilmesi GEREKTİĞİNDEN, burada TEKRAR değerlendirip
/// yan etkileri İKİ KEZ tetiklemek yerine parametre olarak alınır).
pub fn genChannelOp(self: *Codegen, a: ast.Attribute, args: []const ast.Expr, ch_val: Value) CodegenError!Value {
    if (std.mem.eql(u8, a.attr, "send")) {
        if (args.len != 1) return error.Unsupported;
        const v = try self.genExpr(args[0]);
        const converted = try self.convert(v, ch_val.elem_qtype);
        const payload = try self.toPayload(converted);
        try self.out.writer.print("    call $nox_channel_send(l {s}, l {s}, l {s})\n", .{ RT_PARAM, ch_val.text, payload.text });
        return .{ .text = "0", .qtype = .none };
    }
    if (std.mem.eql(u8, a.attr, "recv")) {
        if (args.len != 0) return error.Unsupported;
        const payload_t = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_channel_recv(l {s}, l {s})\n", .{ payload_t, RT_PARAM, ch_val.text });
        const converted = try self.fromPayload(.{ .text = payload_t, .qtype = .l }, ch_val.elem_qtype);
        return valueFromElemDescriptor(converted.text, converted.qtype, ch_val.elem_heap_info, ch_val.elem_is_str);
    }
    return error.Unsupported;
}

/// `tc.send(v)`/`tc.recv()` — Faz BB.6 (bkz. nox-teknik-spesifikasyon.md
/// §3.52): `genChannelOp`in AYNI deseni, AMA `nox_channel_*` yerine
/// `nox_threadchannel_*`e ÇAĞRI YAPAR VE `T`nin `str` OLUP OLMADIĞINA
/// (statik olarak `ch_val.elem_is_str`den BİLİNİR — `thread_channel.zig`nin
/// `_val`/`_str` ikili API'sinin GEREĞİ) GÖRE `_val`/`_str` varyantı
/// SEÇER.
pub fn genThreadChannelOp(self: *Codegen, a: ast.Attribute, args: []const ast.Expr, ch_val: Value) CodegenError!Value {
    if (std.mem.eql(u8, a.attr, "send")) {
        if (args.len != 1) return error.Unsupported;
        const v = try self.genExpr(args[0]);
        const converted = try self.convert(v, ch_val.elem_qtype);
        const payload = try self.toPayload(converted);
        const fn_name = if (ch_val.elem_is_str) "nox_threadchannel_send_str" else "nox_threadchannel_send_val";
        try self.out.writer.print("    call ${s}(l {s}, l {s}, l {s})\n", .{ fn_name, RT_PARAM, ch_val.text, payload.text });
        return .{ .text = "0", .qtype = .none };
    }
    if (std.mem.eql(u8, a.attr, "recv")) {
        if (args.len != 0) return error.Unsupported;
        const fn_name = if (ch_val.elem_is_str) "nox_threadchannel_recv_str" else "nox_threadchannel_recv_val";
        const payload_t = try self.newTemp();
        try self.out.writer.print("    {s} =l call ${s}(l {s}, l {s})\n", .{ payload_t, fn_name, RT_PARAM, ch_val.text });
        const converted = try self.fromPayload(.{ .text = payload_t, .qtype = .l }, ch_val.elem_qtype);
        return valueFromElemDescriptor(converted.text, converted.qtype, ch_val.elem_heap_info, ch_val.elem_is_str);
    }
    return error.Unsupported;
}
