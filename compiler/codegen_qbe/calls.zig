//! Çağrı codegen'i (serbest fonksiyon/metod/kurucu/dict-metodu/list-metodu)
//! — bkz. plan dosyası "QBE codegen backend'ini alt modüllere bölme".
//! `genCall`in dev switch-dispatch'i (yerleşikler: `print`/`len`/`str`/
//! `int`/`float`/`hpy_call`/`wasm_call`, kurucular, `extern def`ler,
//! closure'lar üzerinden dolaylı çağrılar, inline-splice, normal serbest
//! fonksiyonlar) VE metod/dict/list çağrı yolları (`genMethodCall`,
//! `genDictMethod`, `genListAppend`/`genListSort`) burada toplanır.

const std = @import("std");
const ast = @import("../parser/ast.zig");
const types = @import("types.zig");
const abi = @import("abi.zig");
const codegen = @import("codegen.zig");
const async_thread_mod = @import("async_thread.zig");

const Codegen = codegen.Codegen;
const Value = types.Value;
const QbeType = types.QbeType;
const ClassInfo = types.ClassInfo;
const ElemHeapInfo = types.ElemHeapInfo;
const RT_PARAM = types.RT_PARAM;
const LIST_HEADER_SIZE = types.LIST_HEADER_SIZE;
const TAG_SIZE = types.TAG_SIZE;
const FuncSigInfo = types.FuncSigInfo;
const CodegenError = abi.CodegenError;
const qbeSizeOf = abi.qbeSizeOf;
const isHeapManaged = abi.isHeapManaged;
const isTemporaryExpr = abi.isTemporaryExpr;
const matchIntrinsicKind = async_thread_mod.matchIntrinsicKind;
const IntrinsicKind = async_thread_mod.IntrinsicKind;

/// Faz U.4.5: `closure_ptr`in (ZATEN yüklenmiş/değerlendirilmiş bir QBE
/// geçici/işaretçi metni — bir DEĞİŞKEN slotundan (`.identifier` dalı),
/// bir sınıf alanından (`genMethodCall`nin alan-fallback'ı), YA DA bir
/// liste elemanından (`.index` dalı) gelebilir) ARDINDAKİ SOMUT closure'ı
/// çağıran ORTAK çekirdek — Faz U.4.4'ün ESKİ `.identifier`-ÖZEL koduyla
/// AYNI (bkz. eski sürümün belge notu), yalnızca ARTIK herhangi bir
/// çağrı ŞEKLİNDEN (identifier/index/attribute) YENİDEN KULLANILABİLİR.
/// **KRİTİK asimetri (bkz. eski koddaki AYNI davranış, KORUNDU):**
/// `closure_ptr`ın KENDİSİ ASLA serbest BIRAKILMAZ — yalnızca `arg_values`
/// (bkz. `releaseTemporaryArgs`) — closure pointer HER ZAMAN "ödünç" bir
/// okumadır (bir DEĞİŞKEN/alan/liste elemanının KENDİ referansı), bu
/// çağrı SİTESİ onu SAHİPLENMEZ.
pub fn genIndirectCallThroughClosurePtr(self: *Codegen, closure_ptr: []const u8, fsig: *const FuncSigInfo, args: []const ast.Expr) CodegenError!Value {
    if (fsig.params.len != args.len) return error.Unsupported;
    const fn_ptr = try self.newTemp();
    try self.qbeLoadL(fn_ptr, closure_ptr);

    const arg_values = try self.allocator.alloc(Value, args.len);
    for (args, 0..) |a, i| {
        const v0 = try self.genExprForTarget(a, fsig.params[i]);
        try self.checkNoLowlevelEscape(v0);
        arg_values[i] = try self.convert(v0, fsig.params[i].qtype);
    }

    const ret_qtype = fsig.ret.qtype;
    const result_temp: ?[]const u8 = if (ret_qtype == .none) null else try self.newTemp();
    {
        const call_args = try self.allocator.alloc(codegen.QbeArg, 2 + arg_values.len);
        call_args[0] = .{ .ty = .l, .text = RT_PARAM };
        call_args[1] = .{ .ty = .l, .text = closure_ptr };
        for (arg_values, 0..) |v, i| call_args[2 + i] = .{ .ty = v.qtype, .text = v.text };
        if (result_temp) |rt| {
            try self.qbeCall(.{ .name = rt, .ty = ret_qtype }, fn_ptr, call_args);
        } else {
            try self.qbeCall(null, fn_ptr, call_args);
        }
    }
    // Dolaylı çağrının HEDEFİ (çağrılan SOMUT closure) derleme zamanında
    // bilinmediğinden `must_not_raise` eleme optimizasyonu (bkz. normal
    // fonksiyon çağrısı dalı) burada UYGULANAMAZ — İSTİSNA kontrolü HER
    // ZAMAN yapılır (güvenli varsayılan).
    // Bulundu (bkz. proje belleği "4 yeni stdlib modülü" planı, `genMethodCall`nin
    // AYNI belge notu): çağrı ZATEN yapıldığından (başarılı ya da
    // İSTİSNALI), geçici argümanların serbest bırakılması çağrının
    // SONUCUNDAN BAĞIMSIZDIR — `emitExceptionCheck` İSTİSNA durumunda
    // BURADAN SONRAKİ HER ŞEYİ atlayıp propagate/catch etiketine
    // ZIPLADIĞINDAN, serbest bırakma ÖNCEYE taşınmalıdır (aksi halde
    // İSTİSNA fırlatan bir dolaylı çağrının geçici argümanları sızar).
    try self.releaseTemporaryArgs(args, arg_values);
    try self.emitExceptionCheck();

    if (result_temp) |rt| {
        return .{ .text = rt, .qtype = ret_qtype, .heap = fsig.ret.heap, .elem_qtype = fsig.ret.elem_qtype, .class_name = fsig.ret.class_name, .elem_heap_info = fsig.ret.elem_heap_info, .elem_is_str = fsig.ret.elem_is_str, .dict_info = fsig.ret.dict_info };
    }
    return .{ .text = "0", .qtype = .w };
}

pub fn genCall(self: *Codegen, c: ast.Call) CodegenError!Value {
    switch (c.callee.*) {
        .identifier => |name| {
            if (std.mem.eql(u8, name, "print")) {
                if (c.args.len != 1) return error.Unsupported;
                const v = try self.genExpr(c.args[0]);
                try self.genPrint(v);
                // `v` TAZE bir liste/sınıf olabilir (ör. `print(Point(1,2))`,
                // `print([1, 2, 3])`) — artık `print` bunları BASABİLDİĞİNDEN
                // (bkz. görev "print(list)/print(class)"), tamamen
                // dolaylanmış diğer heap değerlerle (bkz. `expr_stmt`,
                // `releaseIfTemporary`) AYNI şekilde sızmaması gerekir.
                try self.releaseIfTemporary(c.args[0], v);
                return .{ .text = "0", .qtype = .w };
            }
            // `len(s) -> int` — stdlib fazı §B (bkz. checker.zig'deki
            // eşdeğer not). Bulundu (bkz. proje belleği "UTF-8
            // farkındalığı" görevi): ÖNCEDEN `strlen`e (bayt sayısı)
            // lowerleniyordu — çok baytlı UTF-8 metinlerde (ör. "café")
            // YANLIŞ sonuç veriyordu. ARTIK `nox_str_char_count`e
            // (`runtime/str.zig`, codepoint sayar) lowerlenir — `strlen`le
            // AYNI tek-argümanlı imza, yalnızca fonksiyon adı değişti.
            if (std.mem.eql(u8, name, "len")) {
                if (c.args.len != 1) return error.Unsupported;
                const v = try self.genExpr(c.args[0]);
                const result_t = try self.newTemp();
                // Stdlib fazı §L: `list[T]` dalı — `genListLit`in AYNI
                // bayt düzeni (8 bayt uzunluk başlığı, ofset 0) DOĞRUDAN
                // okunur (`nox.json`nin `array_len`/`object_len`si İÇİN
                // eklendi — GENEL bir yerleşik, JSON'a özgü DEĞİL).
                if (v.heap == .list) {
                    try self.qbeLoadL(result_t, v.text);
                } else {
                    try self.qbeCall(.{ .name = result_t, .ty = .l }, "$nox_str_char_count", &.{.{ .ty = .l, .text = v.text }});
                }
                try self.releaseIfTemporary(c.args[0], v);
                return .{ .text = result_t, .qtype = .l };
            }
            // `str(x)` — stdlib fazı §E (bkz. checker.zig'deki eşdeğer
            // not). `x`in qtype'ına göre doğru runtime dönüştürücüsüne
            // lowerlanır — HEPSİ HER ZAMAN başarılıdır (bkz. runtime/
            // str.zig'in belge notu), istisna kontrolü GEREKMEZ.
            if (std.mem.eql(u8, name, "str")) {
                if (c.args.len != 1) return error.Unsupported;
                const v = try self.genExpr(c.args[0]);
                // Bulundu (bkz. proje belleği "f-string + augmented atama"
                // görevi): `str` KİMLİK olarak (kopyalamadan) döner —
                // `v` bir TAKMA AD (ör. `str(my_var)`) İSE, `retainIfAliasing`
                // (`.call` sonucunu "TAZE/bağımsız sahipli" SAYAN çağrı
                // tarafının KENDİ refcount'unu YANLIŞLIKLA azaltmasını
                // ÖNLEMEK İçin) GEREKLİDİR — `v` ZATEN TAZE (ör. `str(a+b)`)
                // İSE bu bir no-op'tur (bkz. `retainIfAliasing`in belge notu).
                if (v.heap == .str) {
                    return self.retainIfAliasing(c.args[0], v);
                }
                // `bool` — `int` (`.l`) VE `float` (`.d`)DEN AYRI, `.w`
                // qtype'lı TEK ilkel (bkz. `registration.zig`nin `resolveType`
                // `.boolean` dalı). `nox_bool_to_str` runtime fonksiyonu YOK —
                // ikisi de PINNED (retain/release GEREKTİRMEYEN) statik
                // literal olan "True"/"False"den `v`ye göre BİRİNİ QBE
                // `jnz`+`phi` İLE seçmek yeterli (YENİ bir runtime fonksiyonu
                // GEREKMEZ).
                if (v.qtype == .w and v.heap == .none) {
                    const true_label = try self.newLabel("str_bool_true");
                    const false_label = try self.newLabel("str_bool_false");
                    const done_label = try self.newLabel("str_bool_done");
                    try self.qbeJnz(v.text, true_label, false_label);
                    try self.qbeLabel(true_label);
                    const true_v = try self.emitStringLiteral("True");
                    try self.qbeJmp(done_label);
                    try self.qbeLabel(false_label);
                    const false_v = try self.emitStringLiteral("False");
                    try self.qbeJmp(done_label);
                    try self.qbeLabel(done_label);
                    const result_t = try self.newTemp();
                    try self.qbePhi(result_t, .l, true_label, true_v.text, false_label, false_v.text);
                    return .{ .text = result_t, .qtype = .l, .heap = .str };
                }
                const result_t = try self.newTemp();
                if (v.qtype == .d) {
                    try self.qbeCall(.{ .name = result_t, .ty = .l }, "$nox_float_to_str", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .d, .text = v.text } });
                } else {
                    try self.qbeCall(.{ .name = result_t, .ty = .l }, "$nox_int_to_str", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = v.text } });
                }
                return .{ .text = result_t, .qtype = .l, .heap = .str };
            }
            // `int(s)`/`float(s)` — stdlib fazı §E. Ayrıştırma
            // BAŞARISIZSA bir `ValueError` `raise` eder (bkz.
            // `genParseOrRaise`in belge notu).
            if (std.mem.eql(u8, name, "int")) {
                if (c.args.len != 1) return error.Unsupported;
                const v = try self.genExpr(c.args[0]);
                // `float` argümanı: `dtosi` İLE sıfıra-doğru KIRP (checker
                // ARTIK `str`e EK olarak `float`e de İZİN VERİYOR — bkz.
                // `round()` builtin'inin `int(x + 0.5)` ihtiyacı).
                if (v.qtype == .d) {
                    const result = try self.convert(v, .l);
                    try self.releaseIfTemporary(c.args[0], v);
                    return result;
                }
                const result = try self.genParseOrRaise(v, "nox_str_is_valid_int", "nox_str_to_int", .l, "int(): gecersiz sayi bicimi");
                try self.releaseIfTemporary(c.args[0], v);
                return result;
            }
            if (std.mem.eql(u8, name, "float")) {
                if (c.args.len != 1) return error.Unsupported;
                const v = try self.genExpr(c.args[0]);
                const result = try self.genParseOrRaise(v, "nox_str_is_valid_float", "nox_str_to_float", .d, "float(): gecersiz sayi bicimi");
                try self.releaseIfTemporary(c.args[0], v);
                return result;
            }
            // Faz 14: `hpy_call`/`wasm_call` — bkz. checker.zig'deki
            // eşdeğer not. Runtime'ın `nox_hpy_call`/`nox_wasm_call`sine
            // (bkz. runtime/foreign_bridge.zig) doğrudan çağrıya çevrilir;
            // `str` argümanları zaten sıfırla-sonlanan verilere işaret
            // eden düz `l` işaretçileridir (bkz. modül üstü not, "str
            // neden hep tahsissiz") — hiçbir dönüşüm gerekmez.
            if (std.mem.eql(u8, name, "hpy_call")) {
                if (c.args.len != 4) return error.Unsupported;
                const path_v = try self.genExpr(c.args[0]);
                const ext_v = try self.genExpr(c.args[1]);
                const func_v = try self.genExpr(c.args[2]);
                const arg_v = try self.genExpr(c.args[3]);
                const result_temp = try self.newTemp();
                try self.qbeCall(.{ .name = result_temp, .ty = .l }, "$nox_hpy_call", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = path_v.text }, .{ .ty = .l, .text = ext_v.text }, .{ .ty = .l, .text = func_v.text }, .{ .ty = .l, .text = arg_v.text } });
                return .{ .text = result_temp, .qtype = .l };
            }
            // Faz 15 (bkz. checker.zig'deki eşdeğer not): `hpy_call`in
            // yalnızca-`str` kardeşi — dönüş DEĞERİ (`nox_hpy_call_str`,
            // bkz. `runtime/foreign_bridge.zig`) GERÇEK, başlıklı bir Nox
            // `str`i olduğundan (`dupeToNoxStr` İLE inşa edilir), `.heap =
            // .str` İŞARETLENMELİDİR — aksi halde çağıran taraf bunu ARC-
            // yönetimli bir değer olarak TANIMAZ (retain/release ASLA
            // tetiklenmez, sızıntıya yol açar).
            if (std.mem.eql(u8, name, "hpy_call_str")) {
                if (c.args.len != 4) return error.Unsupported;
                const path_v = try self.genExpr(c.args[0]);
                const ext_v = try self.genExpr(c.args[1]);
                const func_v = try self.genExpr(c.args[2]);
                const arg_v = try self.genExpr(c.args[3]);
                const result_temp = try self.newTemp();
                try self.qbeCall(.{ .name = result_temp, .ty = .l }, "$nox_hpy_call_str", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = path_v.text }, .{ .ty = .l, .text = ext_v.text }, .{ .ty = .l, .text = func_v.text }, .{ .ty = .l, .text = arg_v.text } });
                return .{ .text = result_temp, .qtype = .l, .heap = .str };
            }
            // Faz 1 decorator (bkz. plan dosyası "Decorator sözdizimi +
            // metadata-tabanlı metaprogramming", `checker.zig`deki eşdeğer
            // not): `stdlib/nox/reflect.nox`nin sardığı 6 SABİT-imzalı
            // yerleşik — hepsi `decorators.zig`nin `genDecoratorMetadata`
            // TARAFINDAN KOŞULSUZ üretilen (Zig runtime shim'i OLMAYAN,
            // TAMAMEN derleyici-emisyonlu QBE fonksiyonu olan) `$__nox_
            // reflect_decorator_*` sembollerine DOĞRUDAN çağrıya çevrilir.
            if (std.mem.eql(u8, name, "__nox_reflect_decorator_count")) {
                if (c.args.len != 0) return error.Unsupported;
                const result_temp = try self.newTemp();
                try self.qbeCall(.{ .name = result_temp, .ty = .l }, "$__nox_reflect_decorator_count", &.{.{ .ty = .l, .text = RT_PARAM }});
                return .{ .text = result_temp, .qtype = .l };
            }
            if (std.mem.eql(u8, name, "__nox_reflect_decorator_target_name") or std.mem.eql(u8, name, "__nox_reflect_decorator_name")) {
                if (c.args.len != 1) return error.Unsupported;
                const i_v = try self.genExpr(c.args[0]);
                const result_temp = try self.newTemp();
                const sym = try std.fmt.allocPrint(self.allocator, "${s}", .{name});
                try self.qbeCall(.{ .name = result_temp, .ty = .l }, sym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = i_v.text } });
                return .{ .text = result_temp, .qtype = .l, .heap = .str };
            }
            if (std.mem.eql(u8, name, "__nox_reflect_decorator_arg_count")) {
                if (c.args.len != 1) return error.Unsupported;
                const i_v = try self.genExpr(c.args[0]);
                const result_temp = try self.newTemp();
                try self.qbeCall(.{ .name = result_temp, .ty = .l }, "$__nox_reflect_decorator_arg_count", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = i_v.text } });
                return .{ .text = result_temp, .qtype = .l };
            }
            if (std.mem.eql(u8, name, "__nox_reflect_decorator_arg")) {
                if (c.args.len != 2) return error.Unsupported;
                const i_v = try self.genExpr(c.args[0]);
                const j_v = try self.genExpr(c.args[1]);
                const result_temp = try self.newTemp();
                try self.qbeCall(.{ .name = result_temp, .ty = .l }, "$__nox_reflect_decorator_arg", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = i_v.text }, .{ .ty = .l, .text = j_v.text } });
                return .{ .text = result_temp, .qtype = .l, .heap = .str };
            }
            if (std.mem.eql(u8, name, "__nox_reflect_decorator_is_handler")) {
                if (c.args.len != 1) return error.Unsupported;
                const i_v = try self.genExpr(c.args[0]);
                const result_temp = try self.newTemp();
                try self.qbeCall(.{ .name = result_temp, .ty = .w }, "$__nox_reflect_decorator_is_handler", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = i_v.text } });
                return .{ .text = result_temp, .qtype = .w };
            }
            // `.heap = .closure` — dönüş DEĞERİ normal kullanımda HER ZAMAN
            // TAZE bir ARC kapanış BLOĞUDUR (`router_from_decorators()`
            // ÖNCE `__nox_reflect_decorator_is_handler`ı KONTROL ETMELİDİR
            // — bkz. checker.zig'deki eşdeğer not); eşleşmeyen bir `i` İçin
            // `decorators.zig`nin `genReflectDecoratorHandler`ı `0` döner
            // (YANLIŞ kullanımda null-çağrı çökmesi, BEKLENEN sözleşme
            // İHLALİ — framework KODU BUNU asla tetiklememelidir).
            if (std.mem.eql(u8, name, "__nox_reflect_decorator_handler")) {
                if (c.args.len != 1) return error.Unsupported;
                const i_v = try self.genExpr(c.args[0]);
                const result_temp = try self.newTemp();
                try self.qbeCall(.{ .name = result_temp, .ty = .l }, "$__nox_reflect_decorator_handler", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = i_v.text } });
                return .{ .text = result_temp, .qtype = .l, .heap = .closure };
            }
            if (std.mem.eql(u8, name, "wasm_call")) {
                if (c.args.len != 3) return error.Unsupported;
                const path_v = try self.genExpr(c.args[0]);
                const func_v = try self.genExpr(c.args[1]);
                const arg_v = try self.genExpr(c.args[2]);
                const result_temp = try self.newTemp();
                try self.qbeCall(.{ .name = result_temp, .ty = .l }, "$nox_wasm_call", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = path_v.text }, .{ .ty = .l, .text = func_v.text }, .{ .ty = .l, .text = arg_v.text } });
                return .{ .text = result_temp, .qtype = .l };
            }

            if (self.classes.get(name)) |cinfo| {
                // GG.15 (bkz. nox-teknik-spesifikasyon.md §3.66): BU inşa
                // sitesi, `prepareStackConstructSites`in ÖNCEDEN taradığı
                // bir `lowlevel:` bloğu İÇİNDEYSE, `self.pending_stack_slot`
                // GEÇİCİ olarak İŞARETLENİR — `genConstructFromValues`
                // BUNU görüp `nox_arena_alloc` ÇAĞRISI YERİNE fonksiyon-
                // girişinde ÖNCEDEN ayrılmış bu yığın slotunu KULLANIR.
                if (self.stack_construct_sites.get(@intFromPtr(c.callee))) |site| {
                    self.pending_stack_slot = site.slot;
                }
                return self.genConstruct(name, cinfo, c.args);
            }

            // `extern def` — Nox'un runtime çağrılarıyla (`RT_PARAM`) VE
            // istisna yayılımıyla (`emitExceptionCheck`) HİÇ ilgisi
            // olmayan, doğrudan bir C ABI çağrısı (bkz. nox-teknik-
            // spesifikasyon.md §3.20). `str` argümanları/dönüşü zaten
            // sıfırla-sonlanan ham işaretçiler olduğundan dönüşüm
            // gerekmez (`hpy_call`/`wasm_call` ile AYNI ücretsiz tasarım).
            if (self.extern_functions.get(name)) |esig| {
                if (esig.params.len != c.args.len) return error.Unsupported;
                const arg_values = try self.allocator.alloc(Value, c.args.len);
                for (c.args, 0..) |a, i| {
                    const v0 = try self.genExpr(a);
                    try self.checkNoLowlevelEscape(v0);
                    arg_values[i] = try self.convert(v0, esig.params[i].qtype);
                }
                const result_temp: ?[]const u8 = if (esig.ret.qtype == .none) null else try self.newTemp();
                // `with_rt` (bkz. `ast.ExternDef.needs_rt`in belge notu,
                // stdlib fazı §D.1): `RT_PARAM` GİZLİCE argüman
                // listesinin BAŞINA eklenir (normal fonksiyon
                // çağrılarıyla AYNI kalıp) — Zig tarafının İLK parametresi
                // `rt: ?*anyopaque` olmalıdır.
                const extern_args = try self.allocator.alloc(codegen.QbeArg, (if (esig.needs_rt) @as(usize, 1) else 0) + arg_values.len);
                {
                    var idx: usize = 0;
                    if (esig.needs_rt) {
                        extern_args[idx] = .{ .ty = .l, .text = RT_PARAM };
                        idx += 1;
                    }
                    for (arg_values) |v| {
                        extern_args[idx] = .{ .ty = v.qtype, .text = v.text };
                        idx += 1;
                    }
                }
                const extern_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{name});
                if (result_temp) |rt| {
                    try self.qbeCall(.{ .name = rt, .ty = esig.ret.qtype }, extern_sym, extern_args);
                } else {
                    try self.qbeCall(null, extern_sym, extern_args);
                }
                // Stdlib fazı §F: `elem_qtype`/`elem_heap_info`/
                // `elem_is_str` ÖNCEDEN eksikti (yalnızca `qtype`/`heap`
                // kopyalanıyordu) — D.1.5'in `genFieldRead`de bulunan
                // `dict_info` eksikliğiyle AYNI KATEGORİDE bir hataydı.
                // `list[str]` DÖNÜŞ tipi FFI-güvenli sayılınca (bkz.
                // `isFfiSafeListReturnType`) bu eksiklik GERÇEK bir
                // çökmeye yol açardı (dönen listenin elemanları `str`
                // olarak İŞARETLENMEDEN indekslenir/serbest bırakılırdı).
                // Stdlib fazı §L: `class_name` ÖNCEDEN eksikti (bkz.
                // yukarıdaki `elem_qtype`/`elem_heap_info`/`elem_is_str`
                // notu, Alt-Faz F — AYNI KATEGORİDE bir hata). `JsonValue`
                // DÖNEN bir extern def (`isFfiSafeClassReturnType`)
                // olmadan ÖNCE HİÇBİR extern def sınıf DÖNDÜRMEDİĞİNDEN
                // bu eksiklik fark edilmemişti — `class_name` OLMADAN
                // sonraki `.attribute` okumaları/`genClassRelease`
                // `self.classes.get(obj.class_name.?)`de ÇÖKERDİ.
                // Faz FF.3: AYNI KATEGORİDE bir ÜÇÜNCÜ eksiklik — `dict_info`
                // — `dict[K,V]` DÖNEN bir extern def'in SONUCU BURADAN
                // GEÇTİĞİNDE (ör. `nox_http_response_headers`) EKSİKTİ;
                // `dict`in Faz FF.3'ten ÖNCE `isHeapManaged`in DIŞINDA
                // olması (release YOLU HİÇ TETİKLENMEMESİ) bunu
                // MASKELİYORDU — `dict` ARTIK TAM ARC'lı OLDUĞUNDAN
                // `dict_info` OLMADAN `releaseValueIfSet`in `.dict` dalı
                // `dict_info.?` üzerinde ÇÖKER (bkz. `http_serve_golden_
                // test.zig`nin bu YOLU KANITLAYAN çökme testi).
                if (result_temp) |rt| return .{ .text = rt, .qtype = esig.ret.qtype, .heap = esig.ret.heap, .class_name = esig.ret.class_name, .elem_qtype = esig.ret.elem_qtype, .elem_heap_info = esig.ret.elem_heap_info, .elem_is_str = esig.ret.elem_is_str, .dict_info = esig.ret.dict_info };
                return .{ .text = "0", .qtype = .w };
            }

            // Faz U.4.4: `name` bir SIRADAN fonksiyon/sınıf/extern def
            // DEĞİL, çıplak bir İSİMDEN bağlanan (yerel değişken/
            // parametre — bkz. `checker.zig`nin AYNI dala karşılık gelen
            // `checkCall`in `.identifier` dalı) func-tipli bir DEĞER İSE
            // bu DOLAYLI çağrıdır: hedef fonksiyon işaretçisi (`fn_ptr`,
            // offset 0) STATİK olarak bilinmez, closure DEĞERİNİN
            // KENDİSİNDEN çalışma zamanında YÜKLENİR (bkz. `HeapKind.
            // closure`in belge notu, "kendi kendine yeten TEK işaretçi").
            // Argüman/dönüş tipleri İSE STATİK olarak bilinir —
            // `resolveType`in `.func_type` dalının önceden hesapladığı
            // `func_sig`den (bkz. `FuncSigInfo`in belge notu).
            if (self.vars.get(name)) |info| {
                if (info.heap == .closure) {
                    const fsig = info.func_sig orelse return error.Unsupported;
                    const closure_ptr = try self.newTemp();
                    try self.qbeLoadL(closure_ptr, info.slot);
                    return self.genIndirectCallThroughClosurePtr(closure_ptr, fsig, c.args);
                }
            }

            // Faz GG.2 (bkz. nox-teknik-spesifikasyon.md §3.67): bu ÇAĞRI
            // SİTESİ (`prepareInlineSites` TARAFINDAN ÖNCEDEN, `ast.Call.
            // callee` POINTER kimliğiyle) inline-edilebilir bulunduysa,
            // GERÇEK bir `call`in YERİNE callee'nin gövdesi BURAYA splice
            // edilir — bkz. `genInlinedCall`in belge notu.
            if (self.inline_sites.get(@intFromPtr(c.callee))) |site| {
                return self.genInlinedCall(c, site);
            }

            const sig = self.functions.get(name) orelse return error.Unsupported;
            if (sig.params.len != c.args.len) return error.Unsupported;

            const arg_values = try self.allocator.alloc(Value, c.args.len);
            for (c.args, 0..) |a, i| {
                const v0 = try self.genExprForTarget(a, sig.params[i]);
                try self.checkNoLowlevelEscape(v0);
                arg_values[i] = try self.convert(v0, sig.params[i].qtype);
            }

            const result_temp: ?[]const u8 = if (sig.ret.qtype == .none) null else try self.newTemp();
            {
                const fn_args = try self.allocator.alloc(codegen.QbeArg, 1 + arg_values.len);
                fn_args[0] = .{ .ty = .l, .text = RT_PARAM };
                for (arg_values, 0..) |v, i| fn_args[1 + i] = .{ .ty = v.qtype, .text = v.text };
                const fn_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{name});
                if (result_temp) |rt| {
                    try self.qbeCall(.{ .name = rt, .ty = sig.ret.qtype }, fn_sym, fn_args);
                } else {
                    try self.qbeCall(null, fn_sym, fn_args);
                }
            }
            // Performans fazı: `name`in ASLA istisna fırlatamayacağı
            // KANITLANDIYSA (bkz. `self.must_not_raise`, `computeMustNotRaise`)
            // kontrolü ATLA.
            // Bulundu (bkz. proje belleği "4 yeni stdlib modülü" planı,
            // `genMethodCall`nin AYNI belge notu): serbest bırakma
            // kontrolden ÖNCEYE taşındı — bu, DERLEYİCİDEKİ EN SIK
            // ÇALIŞAN çağrı yolu (HER serbest fonksiyon çağrısı) OLDUĞUNDAN
            // özellikle önemli.
            try self.releaseTemporaryArgs(c.args, arg_values);
            if (!self.must_not_raise.contains(name)) try self.emitExceptionCheck();

            if (result_temp) |rt| {
                return .{ .text = rt, .qtype = sig.ret.qtype, .heap = sig.ret.heap, .elem_qtype = sig.ret.elem_qtype, .class_name = sig.ret.class_name, .elem_heap_info = sig.ret.elem_heap_info, .elem_is_str = sig.ret.elem_is_str };
            }
            return .{ .text = "0", .qtype = .w };
        },
        .attribute => |a| {
            // Faz P1.6 (bkz. `async_thread.zig`nin `matchIntrinsicKind`inin
            // belge notu): stdlib "intrinsic" çağrılarının (`nox.http.serve*`/
            // `nox.thread.start`) callee'si checker tarafından mangled bir
            // isme YENİDEN YAZILMAZ (bkz. `matchesNoxAttr`in belge notu), bu
            // yüzden burada, sıradan metod-çağrısı çözümlemesinden
            // (`genMethodCall`) ÖNCE ŞEKLİ tanımak GEREKİR.
            if (matchIntrinsicKind(c.callee.*)) |kind| {
                return switch (kind) {
                    .http_serve => self.genHttpServe(c),
                    .http_serve_fd => self.genHttpServeFd(c),
                    .http_serve_multicore => self.genHttpServeMulticore(c),
                    .http_serve_tls => self.genHttpServeGeneric(c, true, false),
                    .http_serve_ws => self.genHttpServeGeneric(c, false, true),
                    .http_serve_ws_tls => self.genHttpServeGeneric(c, true, true),
                    .http_serve_fd_tls => self.genHttpServeFdGeneric(c, true, false),
                    .http_serve_fd_ws => self.genHttpServeFdGeneric(c, false, true),
                    .http_serve_fd_ws_tls => self.genHttpServeFdGeneric(c, true, true),
                    .http_serve_multicore_tls => self.genHttpServeMulticoreGeneric(c, true, false),
                    .http_serve_multicore_ws => self.genHttpServeMulticoreGeneric(c, false, true),
                    .http_serve_multicore_ws_tls => self.genHttpServeMulticoreGeneric(c, true, true),
                    .thread_start => self.genThreadStartExpr(c),
                };
            }
            return self.genMethodCall(a, c.args);
        },
        // Faz U.4.5: `xs[i](...)` — `xs`nin ELEMAN tipi func-tipliyse
        // (checker BUNU ZATEN doğruladı, bkz. `checkCall`nin `.index`
        // dalı) `genIndex`in DÖNDÜRDÜĞÜ closure pointer'ı `genIndirectCallThroughClosurePtr`e
        // (bkz. onun belge notu) geçirir.
        .index => |idx| {
            const v = try self.genIndex(idx);
            if (v.heap != .closure) return error.Unsupported;
            const fsig = v.func_sig orelse return error.Unsupported;
            return self.genIndirectCallThroughClosurePtr(v.text, fsig, c.args);
        },
        else => return error.Unsupported,
    }
}

/// `int(s)`/`float(s)` — stdlib fazı §E: `valid_fn(s) -> w` ÖNCE
/// çağrılır; geçersizse bir `ValueError` inşa edilip `raise` edilir
/// (`emitExceptionCheck` DEVREYE girer — bkz. `genRaise`in AYNI
/// deseni); geçerliyse `convert_fn(s) -> result_qtype` gerçek
/// dönüşümü yapar. `genEqCompareOrJump`in belge notuyla AYNI gerekçeyle
/// QBE'nin `phi`sinden BİLİNÇLİ olarak KAÇINILIR: hata dalı `nox_raise`
/// ÇAĞIRDIKTAN SONRA (bu koşulsuz olarak istisnayı BEKLEYEN bir dal
/// olduğundan `emitExceptionCheck`in `exc_continue` etiketi PRATİKTE
/// asla erişilmez) doğrudan `ok_label`e ATLAR — TEK bir SSA değeri
/// (`result`), YALNIZCA `ok_label` İÇİNDE, hangi kenardan gelinirse
/// gelinsin YENİDEN hesaplanır (iki farklı DEĞERİ birleştirmek YERİNE
/// "buraya vardıysan şunu hesapla" deseni — bkz. `genEqCompareOrJump`in
/// belge notu, aynı yığın-taşması endişesi burada da geçerli olmasa
/// bile TUTARLILIK için AYNI desen tercih edildi).
pub fn genParseOrRaise(self: *Codegen, v: Value, valid_fn: []const u8, convert_fn: []const u8, result_qtype: QbeType, message: []const u8) CodegenError!Value {
    const valid_t = try self.newTemp();
    const valid_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{valid_fn});
    try self.qbeCall(.{ .name = valid_t, .ty = .w }, valid_sym, &.{.{ .ty = .l, .text = v.text }});
    const err_label = try self.newLabel("parse_err");
    const ok_label = try self.newLabel("parse_ok");
    try self.qbeJnz(valid_t, ok_label, err_label);
    try self.qbeLabel(err_label);

    const msg_value = try self.emitStringLiteral(message);
    const ve_cinfo = self.classes.get("ValueError") orelse return error.Unsupported;
    const ve_obj = try self.genConstructFromValues("ValueError", ve_cinfo, &.{msg_value}, null);
    try self.qbeCall(null, "$nox_raise", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ve_obj.text }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{self.current_raise_line}) } });
    try self.emitExceptionCheck();
    try self.qbeJmp(ok_label);

    try self.qbeLabel(ok_label);
    const result_t = try self.newTemp();
    const convert_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{convert_fn});
    try self.qbeCall(.{ .name = result_t, .ty = result_qtype }, convert_sym, &.{.{ .ty = .l, .text = v.text }});
    return .{ .text = result_t, .qtype = result_qtype };
}

/// Bir çağrının (fonksiyon/metod/kurucu) argümanları arasındaki TAZE
/// (henüz hiçbir isme bağlanmamış — yalnızca `.call`/`.list_lit`
/// ifadelerinden gelen) heap değerlerini çağrı DÖNDÜKTEN SONRA serbest
/// bırakır.
///
/// Neden gerekli: bir argümanı geçirmek yalnızca bir "ödünç"tür (refcount
/// etkilenmez, bkz. modül üstü not) — ama çağrılan taraf (Faz 9'dan beri)
/// parametreyi bir sınıf ALANINA (`self.attr = param`) ya da yeni bir
/// yerel değişkene (`q = param`) atayarak KALICI hale getirebilir; bu
/// durumda `retainIfAliasing` parametreyi retain eder (çağrı sınırında
/// hiçbir şey bunu telafi etmez). Çağıran taraf, argümanın ORİJİNAL
/// ifadesinin bir isim mi (kendi releaser'ı zaten var — `.identifier`/
/// `.attribute`/`.index`, dokunulmaz) yoksa TAZE bir değer mi (`.call`/
/// `.list_lit`, hiçbir releaser'ı yok) olduğunu bilen tek taraftır — bu
/// yüzden dengeleme sorumluluğu burada, çağrı noktasındadır: çağrılan
/// taraf değeri kalıcı hale getirdiyse refcount 2'ye çıkmıştır, bu release
/// onu doğru şekilde 1'e (tek kalıcı sahip) indirir; getirmediyse
/// (yalnızca okuduysa) refcount zaten 1'dir, bu release onu 0'a indirip
/// gerçekten serbest bırakır — iki durumda da doğru.
pub fn releaseTemporaryArgs(self: *Codegen, exprs: []const ast.Expr, values: []const Value) CodegenError!void {
    for (exprs, 0..) |e, i| {
        const v = values[i];
        // `v.always_fresh` (bkz. `Value`nin belge notu, stdlib fazı §G):
        // `s[i]` HER ZAMAN serbest bırakılmalıdır — AST-tabanlı
        // `isTemporaryExpr` sezgisi burada GEÇERSİZDİR.
        // GG.14: `v.is_pinned` (bkz. `retainIfAliasing`nin AYNI gerekçesi)
        // İSE release TAMAMEN ATLANIR. GG.16: `v.is_stack_slot` (bkz. `Value`nin
        // belge notu) İSE de AYNI şekilde ATLANIR — serbest bırakılacak
        // HİÇBİR ŞEY YOK (bellek yığında, `nox_rc_free_payload` ASLA
        // çağrılmamalı).
        if (!v.is_pinned and !v.is_stack_slot and isHeapManaged(v.heap) and (v.always_fresh or isTemporaryExpr(e))) {
            try self.releaseValueIfSet(v.text, v.heap, v.elem_qtype, v.class_name, v.elem_heap_info, v.dict_info);
        }
    }
}

/// `releaseTemporaryArgs` ile aynı gerekçe, tek bir değer için — bir metod
/// çağrısının ALICISI (ör. `Engine(1).some_method()`), bir alan
/// okumasının/indekslemenin TABANI (ör. `make_car(i).engine`,
/// `make_list()[0]`) da aynı şekilde taze bir geçici olabilir.
pub fn releaseIfTemporary(self: *Codegen, e: ast.Expr, v: Value) CodegenError!void {
    // Bkz. `releaseTemporaryArgs`in AYNI notu (`v.always_fresh`/`v.is_pinned`/`v.is_stack_slot`).
    if (!v.is_pinned and !v.is_stack_slot and isHeapManaged(v.heap) and (v.always_fresh or isTemporaryExpr(e))) {
        try self.releaseValueIfSet(v.text, v.heap, v.elem_qtype, v.class_name, v.elem_heap_info, v.dict_info);
    }
}

/// İçinde bulunulan en yakın `lowlevel` bloğunun arena işaretçisi (varsa).
/// GG.15: `.elided` girdiler İçin de (bilinçli olarak) NON-NULL bir
/// tutamaç DÖNDÜRÜR — `Value.arena`/`checkNoLowlevelEscape`nin "BU değer
/// bir lowlevel kapsamına AİT" ayrımı yığın-dönüştürülmüş değerler İçin
/// de AYNEN KORUNMALIDIR (SADECE gerçek `nox_arena_alloc` çağrısı
/// atlanır — bkz. `genConstructFromValues`/`genListLit`).
pub fn currentArena(self: *Codegen) ?[]const u8 {
    if (self.arena_stack.items.len == 0) return null;
    return self.arena_stack.items[self.arena_stack.items.len - 1].handle;
}

pub fn genConstruct(self: *Codegen, class_name: []const u8, cinfo: ClassInfo, args: []const ast.Expr) CodegenError!Value {
    if (cinfo.init_params.len != args.len) return error.Unsupported;
    const arg_values = try self.allocator.alloc(Value, args.len);
    for (args, 0..) |a, i| {
        const v0 = try self.genExprForTarget(a, cinfo.init_params[i]);
        try self.checkNoLowlevelEscape(v0);
        arg_values[i] = try self.convert(v0, cinfo.init_params[i].qtype);
    }
    // Bulundu (bkz. proje belleği "4 yeni stdlib modülü" planı): geçici
    // argümanların serbest bırakılması ÖNCEDEN `genConstructFromValues`in
    // DÖNÜŞÜNDEN SONRA (burada, bu Zig fonksiyonunun İÇİNDE) yapılıyordu —
    // ama `__init__` GERÇEKTEN istisna fırlatırsa, `genConstructFromValues`in
    // KENDİSİNİN emisyon ettiği `emitExceptionCheck` (QBE ÇIKTISINDA,
    // `__init__` çağrısının HEMEN ARDINDAN) propagate/catch etiketine
    // ZIPLAR — bu ZIP, BURAYA (Zig çağrı sınırı ÖTESİNDEKİ bu satıra)
    // HİÇ dönmeden GERÇEKLEŞİR, bu yüzden aşağıdaki (ARTIK KALDIRILAN)
    // `releaseTemporaryArgs` çağrısının ÜRETTİĞİ kod ASLA ÇALIŞMAZDI —
    // GERÇEK bir tekrar-üretimle (`SomeClass(gecici_arg()).use()` GİBİ,
    // `__init__` istisna fırlatan bir sınıf) DOĞRULANDI. Düzeltme:
    // serbest bırakma artık `genConstructFromValues`e (`temp_release`
    // parametresi İLE) taşındı — O fonksiyon BUNU `__init__` çağrısından
    // HEMEN SONRA, KENDİ `emitExceptionCheck`İNDEN ÖNCE yapar.
    return self.genConstructFromValues(class_name, cinfo, arg_values, .{ .exprs = args, .values = arg_values });
}

/// `genConstruct`ın AST-BAĞIMSIZ çekirdeği — stdlib fazı §D.1.6'nın
/// `nox.http.serve` sarmalayıcısı (bkz. `genHttpServeWrapper`), bir
/// `HttpRequest` örneğini kaynak-düzeyi `ast.Expr` argümanlarından DEĞİL,
/// zaten HESAPLANMIŞ `Value`lerden (extern erişimci çağrılarının
/// sonuçlarından) inşa etmesi GEREKTİĞİNDEN bu ayrım gerekli. `temp_release`
/// (bkz. proje belleği "4 yeni stdlib modülü" planı, GERÇEK bir bellek
/// sızıntısı düzeltmesi): `genConstruct`ın ÇAĞIRDIĞI durumda dolu (kaynak-
/// düzeyi `args`/`arg_values` çifti) — bu ikisi `__init__` çağrısından
/// HEMEN SONRA, `emitExceptionCheck`DEN ÖNCE serbest bırakılır (aksi
/// halde `__init__` istisna fırlatırsa SIZAR, bkz. `genConstruct`ın
/// belge notu). Diğer TÜM çağıranlar (`genConstructFromValues`in KENDİ
/// çağrı siteleri — `ValueError`/`IndexError`/`KeyError` GİBİ yerleşik
/// hata sınıfları İçin bir string LİTERALİ argümanıyla, ya da
/// `genHttpServeWrapper`ın extern-erişimci `Value`leriyle — HİÇBİRİNİN
/// karşılık gelen bir `ast.Expr`si YOK) `null` bırakır.
pub fn genConstructFromValues(self: *Codegen, class_name: []const u8, cinfo: ClassInfo, arg_values: []const Value, temp_release: ?struct { exprs: []const ast.Expr, values: []const Value }) CodegenError!Value {
    if (cinfo.init_params.len != arg_values.len) return error.Unsupported;
    const arena = self.currentArena();
    // GG.15 (bkz. nox-teknik-spesifikasyon.md §3.66): BU inşa sitesi İçin
    // `genCall`in DAHA ÖNCE (`stack_construct_sites` sorgusuyla) ÖNCEDEN
    // ayrılmış bir yığın slotu BULDUYSA, `nox_arena_alloc`/`nox_rc_alloc`
    // ÇAĞRISI TAMAMEN ATLANIR — slot DOĞRUDAN `t` OLARAK kullanılır (arena
    // yolunun `cinfo.total_size` argümanıyla AYNI boyutta ÖNCEDEN ayrılmıştı,
    // hiçbir başlık-boşluğu FARKI YOK — bkz. arena/`nox_rc_alloc`'un
    // `t` üzerindeki AYNI, header-SONRASI kullanım deseni). `pending_stack_
    // slot` her zaman `self.currentArena() != null` İKEN (BU splice sitesi
    // ZATEN bir `lowlevel:` bloğu İÇİNDE) ayarlandığından, `arena != null`
    // AŞAĞIDAKİ dönüş değerinde de doğru KALIR.
    const t: []const u8 = blk: {
        if (self.pending_stack_slot) |slot| {
            self.pending_stack_slot = null;
            break :blk slot;
        }
        const temp = try self.newTemp();
        if (arena) |ap| {
            try self.qbeCall(.{ .name = temp, .ty = .l }, "$nox_arena_alloc", &.{ .{ .ty = .l, .text = ap }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{cinfo.total_size}) } });
        } else {
            try self.qbeCall(.{ .name = temp, .ty = .l }, "$nox_rc_alloc", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{cinfo.total_size}) } });
        }
        break :blk temp;
    };
    try self.qbeStoreImmL(@intCast(cinfo.class_id), t);
    // Faz 7 (tekli kalıtım): `has_vtable` İSE, TAG'den HEMEN SONRA (alanlar
    // BAŞLAMADAN ÖNCE) bu SOMUT sınıfın vtable veri bloğunun adresini
    // yaz (bkz. `layout.zig`nin `genClassVtable`ı, `abi_layout.VTABLE_
    // PTR_SIZE`nin belge notu) — `genMethodCall`in dolaylı çağrı yolu
    // BUNU okur.
    if (cinfo.has_vtable) {
        const vt_addr = try self.newTemp();
        try self.qbeOp2Imm(vt_addr, .l, "add", t, @intCast(TAG_SIZE));
        // `next_vtable_slot == 0`: bu SOMUT sınıfın (VE tüm hiyerarşisinin
        // BURAYA kadar) HİÇ sanal metodu yok (`genClassVtable` BU durumda
        // hiçbir `data $..._vtable` bloğu YAYINLAMAZ, bkz. onun belge
        // notu) — VAR OLMAYAN bir sembole işaret ETMEK yerine yuvayı
        // SIFIRLA (zaten HİÇBİR yerden okunmayacak, ama bağlantı-zamanı
        // "tanımsız sembol" hatasından KAÇINMAK İçin).
        if (cinfo.next_vtable_slot > 0) {
            const vtable_sym = try std.fmt.allocPrint(self.allocator, "${s}_vtable", .{class_name});
            try self.qbeStoreL(vtable_sym, vt_addr);
        } else {
            try self.qbeStoreImmL(0, vt_addr);
        }
    }
    // Alanlar `__init__` çalışmadan ÖNCE sıfırlanır: bu sayede sınıf tipli
    // bir alana ilk kez yazarken `genAssign`'in "önce eskiyi serbest
    // bırak" mantığı (bkz. `.attribute` durumu) çöp bir işaretçiyi asla
    // release etmeye çalışmaz — tahsis edilmiş bellek sıfırla
    // doldurulmuş SAYILAMAZ (bkz. runtime/alloc/asap.zig, DebugAllocator).
    for (cinfo.fields.items) |f| {
        const addr = try self.newTemp();
        try self.qbeOp2Imm(addr, .l, "add", t, @intCast(f.offset));
        try self.qbeStoreImmL(0, addr);
    }
    // `has_init == false`: sınıfın hiç `__init__`i yok (bkz.
    // `ClassInfo.has_init`in belge notu) — `generateModule` bu sınıf için
    // `$ClassName___init__`i HİÇ ÜRETMEDİ, bu yüzden burada çağırmak
    // bağlantı zamanında çözülemeyen bir sembole yol açardı. Faz 7: bu
    // sınıfın KENDİ `__init__`i yoksa (taban sınıftan MİRAS alındı)
    // `cinfo.init_owner` GERÇEK implementasyonu TAŞIYAN sınıfa işaret
    // eder — `class_name`in KENDİSİ DEĞİL (o sembol HİÇ ÜRETİLMEZ).
    if (cinfo.has_init) {
        const init_owner = cinfo.init_owner.?;
        {
            const init_args = try self.allocator.alloc(codegen.QbeArg, 2 + arg_values.len);
            init_args[0] = .{ .ty = .l, .text = RT_PARAM };
            init_args[1] = .{ .ty = .l, .text = t };
            for (arg_values, 0..) |v, i| init_args[2 + i] = .{ .ty = v.qtype, .text = v.text };
            const init_sym = try std.fmt.allocPrint(self.allocator, "${s}___init__", .{init_owner});
            try self.qbeCall(null, init_sym, init_args);
        }
        // Bkz. bu fonksiyonun `temp_release` belge notu — `__init__`
        // çağrısından HEMEN SONRA, `emitExceptionCheck`DEN ÖNCE.
        if (temp_release) |tr| try self.releaseTemporaryArgs(tr.exprs, tr.values);
        // Performans fazı: `__init__`in ASLA istisna fırlatamayacağı
        // KANITLANDIYSA (bkz. `ClassInfo.init_is_safe`, `computeMustNotRaise`)
        // kontrolü ATLA.
        if (!cinfo.init_is_safe) {
            // Bulundu (bkz. proje belleği "4 yeni stdlib modülü" planı,
            // `Command`/`temp_release` düzeltmesiyle AYNI turda YAKALANDI):
            // `__init__` GERÇEKTEN istisna fırlatırsa, TAM OLARAK inşa
            // EDİLMEMİŞ `t` (yukarıda ayrılan yeni örnek — İÇİNDE __init__in
            // istisnadan ÖNCE atadığı HERHANGİ bir alan DAHİL) hiçbir yere
            // atanmadan/döndürülmeden SIZIYORDU (`genConstruct`nin çağıranı
            // istisna nedeniyle sonucu HİÇ kullanmıyor) — GERÇEK bir
            // tekrar-üretimle (`__init__`i istisna fırlatan bir sınıfın
            // kurucu çağrısı) DOĞRULANDI. Arena-tahsisli örnekler HARİÇ
            // (arena'nın KENDİSİ toplu serbest bırakılır, tekil `_release`
            // YANLIŞ olur) — `t` istisna durumunda `$ClassName_release`
            // İLE (alanları ÖNCEDEN sıfırlandığından, henüz atanmamış
            // alanlar GÜVENLE atlanır) serbest bırakılır.
            if (arena == null) {
                const pending = try self.newTemp();
                try self.qbeCall(.{ .name = pending, .ty = .w }, "$nox_exception_pending", &.{.{ .ty = .l, .text = RT_PARAM }});
                const release_label = try self.newLabel("ctor_init_failed");
                const cont_label = try self.newLabel("ctor_init_cont");
                try self.qbeJnz(pending, release_label, cont_label);
                try self.qbeLabel(release_label);
                try self.releaseValueIfSet(t, .class, .none, class_name, null, null);
                try self.qbeJmp(cont_label);
                try self.qbeLabel(cont_label);
            }
            try self.emitExceptionCheck();
        }
    }
    return .{ .text = t, .qtype = .l, .heap = .class, .class_name = class_name, .arena = arena != null };
}

/// Faz 7 (tekli kalıtım): `e` TAM OLARAK `super()` MI — checker.zig'in
/// AYNI adlı yardımcısıyla BİREBİR AYNI kalıp tanıma (checker `super()`in
/// SADECE bu ŞEKİLDE, doğrudan bir metod çağrısının alıcısı OLARAK
/// kullanılmasına İZİN VERDİĞİNDEN, codegen buraya BAŞKA bir şekilde ASLA
/// ULAŞAMAZ).
fn isSuperCallExpr(e: ast.Expr) bool {
    return switch (e) {
        .call => |c| switch (c.callee.*) {
            .identifier => |n| c.args.len == 0 and std.mem.eql(u8, n, "super"),
            else => false,
        },
        else => false,
    };
}

pub fn genMethodCall(self: *Codegen, a: ast.Attribute, args: []const ast.Expr) CodegenError!Value {
    if (isSuperCallExpr(a.obj.*)) return self.genSuperMethodCall(a, args);
    const obj = try self.genExpr(a.obj.*);
    if (obj.heap == .dict) return self.genDictMethod(obj, a, args);
    if (obj.heap == .list) {
        // Faz EE.1 (bkz. nox-teknik-spesifikasyon.md §3.61): checker
        // ZATEN `a.attr`in `append`/`sort`den biri OLDUĞUNU doğruladı
        // (bkz. checker.zig'in `.list` dalı) — codegen İSİM üzerinden
        // dispatch eder (`genListAppend`nin KENDİSİ isim KONTROLÜ
        // YAPMAZ, `args.len`e göre AYRIM yapardı — `sort`nin 0 argümanı
        // `append`nin "tam olarak 1 argüman" KONTROLÜNE takılırdı).
        if (std.mem.eql(u8, a.attr, "sort")) return self.genListSort(obj, a, args);
        if (std.mem.eql(u8, a.attr, "pop")) return self.genListPop(obj, a);
        return self.genListAppend(obj, a, args);
    }
    // Faz OO.2 (bkz. nox-teknik-spesifikasyon.md §3.83): `TaskLocal[T]`in
    // `get`/`set`/`clear`i — `Channel`nin `send`/`recv`sinin AKSİNE
    // `await` GEREKTİRMEZ, bu YÜZDEN (yerleşik bir tip olarak `self.
    // classes`de YOK OLMASINA RAĞMEN) `genAwaitExpr` YERİNE BURADA,
    // NORMAL metod-çağrısı yolunda ele alınır.
    if (obj.heap == .task_local) return async_thread_mod.genTaskLocalOp(self, obj, a, args);
    if (obj.heap != .class) return error.Unsupported;
    try self.checkNoLowlevelEscape(obj);
    const cinfo = self.classes.get(obj.class_name.?).?;
    const msig = cinfo.methods.get(a.attr) orelse {
        // Faz U.4.5: `a.attr` bir METOD DEĞİLSE, func-tipli bir ALAN
        // OLABİLİR (checker BUNU ZATEN doğruladı, bkz. `checkCall`nin
        // `.attribute` dalındaki AYNI method-önce/alan-sonra sıralaması)
        // — alanın KENDİ closure pointer'ı OKUNUP `genIndirectCallThroughClosurePtr`e
        // (bkz. onun belge notu) geçirilir.
        for (cinfo.fields.items) |f| {
            if (!std.mem.eql(u8, f.name, a.attr) or f.info.heap != .closure) continue;
            const fsig = f.info.func_sig orelse return error.Unsupported;
            const addr = try self.newTemp();
            try self.qbeOp2Imm(addr, .l, "add", obj.text, @intCast(f.offset));
            const closure_ptr = try self.newTemp();
            try self.qbeLoadL(closure_ptr, addr);
            const result = try self.genIndirectCallThroughClosurePtr(closure_ptr, fsig, args);
            try self.releaseIfTemporary(a.obj.*, obj);
            return result;
        }
        return error.Unsupported;
    };
    if (msig.sig.params.len != args.len) return error.Unsupported;

    const arg_values = try self.allocator.alloc(Value, args.len);
    for (args, 0..) |arg, i| {
        const v0 = try self.genExprForTarget(arg, msig.sig.params[i]);
        try self.checkNoLowlevelEscape(v0);
        arg_values[i] = try self.convert(v0, msig.sig.params[i].qtype);
    }

    const result_temp: ?[]const u8 = if (msig.sig.ret.qtype == .none) null else try self.newTemp();
    // Faz 7: `cinfo.has_vtable` İSE metod çağrısı DOLAYLI (indirect) yapılır
    // — statik alıcı tipi (`obj.class_name.?`) ile ÇALIŞMA ZAMANI tipi
    // (Base-tipli bir değişken bir Derived örneği TUTABİLİR) FARKLI
    // olabileceğinden, çağrının GERÇEKTEN hangi override'a gideceği
    // ÇALIŞMA ZAMANINDA belirlenir: nesnenin vtable işaretçisi OKUNUR,
    // ilgili SLOT'taki fonksiyon işaretçisi YÜKLENİR, ONUN ÜZERİNDEN
    // çağrılır (closure'ların `genIndirectCallThroughClosurePtr`ıyla AYNI
    // register-call mekanizması). **Bilinçli v1 kapsamı**: override
    // EDİLMEMİŞ metodlar İçin BİLE (devirtualization YOK) — kalıtıma HİÇ
    // KATILMAYAN sınıflar İçin (`has_vtable == false`, Nox kodunun BÜYÜK
    // ÇOĞUNLUĞU) davranış/performans BİREBİR ÖNCEKİ GİBİ kalır.
    {
        const method_args = try self.allocator.alloc(codegen.QbeArg, 2 + arg_values.len);
        method_args[0] = .{ .ty = .l, .text = RT_PARAM };
        method_args[1] = .{ .ty = .l, .text = obj.text };
        for (arg_values, 0..) |v, i| method_args[2 + i] = .{ .ty = v.qtype, .text = v.text };
        const dst: ?codegen.QbeCallDst = if (result_temp) |rt| .{ .name = rt, .ty = msig.sig.ret.qtype } else null;
        if (cinfo.has_vtable) {
            const vt_addr = try self.newTemp();
            try self.qbeOp2Imm(vt_addr, .l, "add", obj.text, @intCast(TAG_SIZE));
            const vtable_ptr = try self.newTemp();
            try self.qbeLoadL(vtable_ptr, vt_addr);
            const slot_addr = try self.newTemp();
            try self.qbeOp2Imm(slot_addr, .l, "add", vtable_ptr, @intCast(msig.slot * 8));
            const fn_ptr = try self.newTemp();
            try self.qbeLoadL(fn_ptr, slot_addr);
            try self.qbeCall(dst, fn_ptr, method_args);
        } else {
            const method_sym = try std.fmt.allocPrint(self.allocator, "${s}_{s}", .{ msig.owner, a.attr });
            try self.qbeCall(dst, method_sym, method_args);
        }
    }
    // Faz M.8 (yeniden ele alındı, bkz. nox-teknik-spesifikasyon.md
    // §3.59): `computeMustNotRaise` ARTIK TÜM metodları (yalnızca
    // `__init__` değil) analiz ediyor — hedef metod bu kümedeyse
    // (sembol formatı `genCall`in serbest-fonksiyon dalıyla TUTARLI,
    // bkz. `computeMustNotRaise`in belge notu) kontrol atlanabilir. Faz 7:
    // DOLAYLI (vtable) bir çağrının GERÇEKTE hangi override'a gideceği
    // ÇALIŞMA ZAMANINDA belirlendiğinden, bu optimizasyon SADECE DOĞRUDAN
    // çağrılar İçin (has_vtable == false) uygulanır — vtable çağrıları
    // HER ZAMAN MUHAFAZAKÂR (güvenli) davranır, kontrolü ASLA atlamaz.
    // Bulundu (bkz. proje belleği "4 yeni stdlib modülü" planı, nox.process):
    // GERÇEK bir bellek sızıntısı — alıcı/argümanların serbest bırakılması
    // ÖNCEDEN `emitExceptionCheck`DEN SONRA geliyordu, bu da metod
    // İSTİSNA fırlatırsa (`Command("yok").run()` GİBİ bir GEÇİCİ alıcı
    // üzerinde) kontrolün BU serbest bırakma satırlarına HİÇ ULAŞMADAN
    // (catch/propagate etiketine ZIPLAYARAK) sızmasına yol açıyordu —
    // GERÇEK bir tekrar-üretimle (`Cmd("x").boom()` İÇİNDE `boom` istisna
    // fırlatıyor) DOĞRULANDI. Çağrı ZATEN yapıldığından (başarılı ya da
    // İSTİSNALI), alıcı/argümanların SERBEST BIRAKILMASI çağrının
    // SONUCUNDAN BAĞIMSIZDIR — bu yüzden kontrolden ÖNCEYE taşındı.
    try self.releaseIfTemporary(a.obj.*, obj);
    try self.releaseTemporaryArgs(args, arg_values);
    if (cinfo.has_vtable) {
        try self.emitExceptionCheck();
    } else {
        const method_sym = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ msig.owner, a.attr });
        if (!self.must_not_raise.contains(method_sym)) try self.emitExceptionCheck();
    }

    if (result_temp) |rt| {
        return .{ .text = rt, .qtype = msig.sig.ret.qtype, .heap = msig.sig.ret.heap, .elem_qtype = msig.sig.ret.elem_qtype, .class_name = msig.sig.ret.class_name, .elem_heap_info = msig.sig.ret.elem_heap_info, .elem_is_str = msig.sig.ret.elem_is_str };
    }
    return .{ .text = "0", .qtype = .w };
}

/// Faz 7: `super().metod(...)` / `super().__init__(...)` — checker.zig'in
/// AYNI adlı özel-işlemesinin codegen tarafı. HER ZAMAN DOĞRUDAN (asla
/// vtable ÜZERİNDEN) çağrılır: `self`in ÇALIŞMA ZAMANI tipi (Derived)
/// SET OLSA BİLE, `super()`in AMACI TAM OLARAK belirli bir ATANIN
/// implementasyonunu çağırmaktır (ANLIK sınıfın KENDİ vtable'ı ÜZERİNDEN
/// gitmek, GERİ DÖNÜP KENDİ override'ını TEKRAR çağırarak sonsuz
/// özyinelemeye yol açardı).
pub fn genSuperMethodCall(self: *Codegen, a: ast.Attribute, args: []const ast.Expr) CodegenError!Value {
    const self_class = self.current_self_class.?;
    const base_name = self.classes.get(self_class).?.base.?;
    const base_info = self.classes.get(base_name).?;
    const self_val = try self.genExpr(.{ .identifier = "self" });

    if (std.mem.eql(u8, a.attr, "__init__")) {
        const init_owner = base_info.init_owner.?;
        const arg_values = try self.allocator.alloc(Value, args.len);
        for (args, base_info.init_params, 0..) |arg, pt, i| {
            const v0 = try self.genExprForTarget(arg, pt);
            try self.checkNoLowlevelEscape(v0);
            arg_values[i] = try self.convert(v0, pt.qtype);
        }
        {
            const init_args = try self.allocator.alloc(codegen.QbeArg, 2 + arg_values.len);
            init_args[0] = .{ .ty = .l, .text = RT_PARAM };
            init_args[1] = .{ .ty = .l, .text = self_val.text };
            for (arg_values, 0..) |v, i| init_args[2 + i] = .{ .ty = v.qtype, .text = v.text };
            const init_sym = try std.fmt.allocPrint(self.allocator, "${s}___init__", .{init_owner});
            try self.qbeCall(null, init_sym, init_args);
        }
        try self.releaseTemporaryArgs(args, arg_values);
        try self.emitExceptionCheck();
        return .{ .text = "0", .qtype = .w };
    }

    const msig = base_info.methods.get(a.attr) orelse return error.Unsupported;
    if (msig.sig.params.len != args.len) return error.Unsupported;
    const arg_values = try self.allocator.alloc(Value, args.len);
    for (args, 0..) |arg, i| {
        const v0 = try self.genExprForTarget(arg, msig.sig.params[i]);
        try self.checkNoLowlevelEscape(v0);
        arg_values[i] = try self.convert(v0, msig.sig.params[i].qtype);
    }
    const result_temp: ?[]const u8 = if (msig.sig.ret.qtype == .none) null else try self.newTemp();
    {
        const method_args = try self.allocator.alloc(codegen.QbeArg, 2 + arg_values.len);
        method_args[0] = .{ .ty = .l, .text = RT_PARAM };
        method_args[1] = .{ .ty = .l, .text = self_val.text };
        for (arg_values, 0..) |v, i| method_args[2 + i] = .{ .ty = v.qtype, .text = v.text };
        const method_sym = try std.fmt.allocPrint(self.allocator, "${s}_{s}", .{ msig.owner, a.attr });
        const dst: ?codegen.QbeCallDst = if (result_temp) |rt| .{ .name = rt, .ty = msig.sig.ret.qtype } else null;
        try self.qbeCall(dst, method_sym, method_args);
    }
    try self.releaseTemporaryArgs(args, arg_values);
    try self.emitExceptionCheck();
    if (result_temp) |rt| {
        return .{ .text = rt, .qtype = msig.sig.ret.qtype, .heap = msig.sig.ret.heap, .elem_qtype = msig.sig.ret.elem_qtype, .class_name = msig.sig.ret.class_name, .elem_heap_info = msig.sig.ret.elem_heap_info, .elem_is_str = msig.sig.ret.elem_is_str };
    }
    return .{ .text = "0", .qtype = .w };
}

/// `d.contains(key)`/`d.len()` — `Channel.send/recv` İLE AYNI desen
/// (bir kullanıcı sınıfı DEĞİL, burada özel işlenir — bkz. checker.zig'in
/// eşdeğer notu).
pub fn genDictMethod(self: *Codegen, obj: Value, a: ast.Attribute, args: []const ast.Expr) CodegenError!Value {
    const dinfo = obj.dict_info.?;
    if (std.mem.eql(u8, a.attr, "contains")) {
        if (args.len != 1) return error.Unsupported;
        const key_v0 = try self.genExpr(args[0]);
        try self.checkNoLowlevelEscape(key_v0);
        const key_payload = try self.toPayload(key_v0);
        const key_is_str_lit: []const u8 = if (dinfo.key_is_str) "1" else "0";
        const result = try self.newTemp();
        try self.qbeCall(.{ .name = result, .ty = .w }, "$nox_dict_contains", &.{ .{ .ty = .l, .text = obj.text }, .{ .ty = .w, .text = key_is_str_lit }, .{ .ty = .l, .text = key_payload.text } });
        try self.releaseIfTemporary(args[0], key_v0);
        try self.releaseIfTemporary(a.obj.*, obj);
        return .{ .text = result, .qtype = .w };
    }
    if (std.mem.eql(u8, a.attr, "len")) {
        if (args.len != 0) return error.Unsupported;
        const result = try self.newTemp();
        try self.qbeCall(.{ .name = result, .ty = .l }, "$nox_dict_len", &.{.{ .ty = .l, .text = obj.text }});
        try self.releaseIfTemporary(a.obj.*, obj);
        return .{ .text = result, .qtype = .l };
    }
    // Faz III.6 (bkz. nox-teknik-spesifikasyon.md §3.69) —
    // `keys()`/`values()`: `runtime/collections/dict.zig`nin
    // `nox_dict_keys`/`nox_dict_values`ine (bir `list[T]`nin ham bayt
    // düzenini `entries`den KOPYALAYAN, `str` İSE her elemanı `nox_rc_
    // retain` ile PAYLAŞAN yardımcılar) lowerlanır. Eleman boyutu
    // (`bool` İSE 4/`w`, aksi hâlde 8/`l`-`d`) `dinfo.key_qtype`/
    // `value_qtype`den (bkz. `DictInfo`nun belge notu) `qbeSizeOf` İLE
    // türetilir. Dönen `list[T]`nin `elem_heap_info`si `str` İSE
    // `genListLit`nin AYNI desenini İZLER (özyinelemeli release İçin).
    if (std.mem.eql(u8, a.attr, "keys")) {
        if (args.len != 0) return error.Unsupported;
        const key_is_str_lit: []const u8 = if (dinfo.key_is_str) "1" else "0";
        const elem_size = qbeSizeOf(dinfo.key_qtype);
        const result = try self.newTemp();
        try self.qbeCall(.{ .name = result, .ty = .l }, "$nox_dict_keys", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj.text }, .{ .ty = .w, .text = key_is_str_lit }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{elem_size}) } });
        try self.releaseIfTemporary(a.obj.*, obj);
        var elem_heap_info: ?*const ElemHeapInfo = null;
        if (dinfo.key_is_str) {
            const info = try self.allocator.create(ElemHeapInfo);
            info.* = .{ .heap = .str };
            elem_heap_info = info;
        }
        return .{ .text = result, .qtype = .l, .heap = .list, .elem_qtype = dinfo.key_qtype, .elem_heap_info = elem_heap_info, .elem_is_str = dinfo.key_is_str };
    }
    if (std.mem.eql(u8, a.attr, "values")) {
        if (args.len != 0) return error.Unsupported;
        const value_is_str_lit: []const u8 = if (dinfo.value_is_str) "1" else "0";
        const value_is_class_lit: []const u8 = if (dinfo.value_is_class) "1" else "0";
        const elem_size = qbeSizeOf(dinfo.value_qtype);
        const result = try self.newTemp();
        try self.qbeCall(.{ .name = result, .ty = .l }, "$nox_dict_values", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj.text }, .{ .ty = .w, .text = value_is_str_lit }, .{ .ty = .w, .text = value_is_class_lit }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{elem_size}) } });
        try self.releaseIfTemporary(a.obj.*, obj);
        var elem_heap_info: ?*const ElemHeapInfo = null;
        if (dinfo.value_is_str) {
            const info = try self.allocator.create(ElemHeapInfo);
            info.* = .{ .heap = .str };
            elem_heap_info = info;
        } else if (dinfo.value_is_class) {
            const info = try self.allocator.create(ElemHeapInfo);
            info.* = .{ .heap = .class, .class_name = dinfo.value_class_name };
            elem_heap_info = info;
        }
        return .{ .text = result, .qtype = .l, .heap = .list, .elem_qtype = dinfo.value_qtype, .elem_heap_info = elem_heap_info, .elem_is_str = dinfo.value_is_str };
    }
    return error.Unsupported;
}

/// `xs.append(v)` — Faz U.1, GERÇEK paylaşım semantikli büyüme (bkz.
/// nox-teknik-spesifikasyon.md §3.20'nin AYRINTILI notu — kullanıcıyla
/// netleşen karar). İKİ yol:
///   - **Hızlı yol** (`len < cap`): YENİ eleman `obj.text`in KENDİ
///     bloğuna, YERİNDE yazılır, `len` ARTIRILIR — bloğun ADRESİ HİÇ
///     DEĞİŞMEZ, bu yüzden AYNI listeye başka bir isimden (`ys = xs`)
///     bakan HERHANGİ bir alias bu değişikliği ANINDA GÖRÜR (gerçek
///     paylaşım).
///   - **Büyüme yolu** (`len == cap`): `nox_list_grow` (bkz. `arc.zig`)
///     YENİ (kapasitesi ikiye katlanmış — `cap == 0` İSE `1`) bir blok
///     ayırıp ESKİ içeriği KOPYALAR; YENİ eleman ORAYA yazılır; ESKİ
///     blok (elemanları TAŞINDIĞINDAN — AYNI işaretçi DEĞERLERİ, refcount
///     DEĞİŞMEDEN — özyinelemeli release EDİLMEDEN, yalnızca KENDİ ham
///     belleği) `nox_rc_predecrement`+`nox_rc_free_payload` ile serbest
///     bırakılır; YENİ işaretçi ALICININ KENDİ SLOTUNA geri yazılır.
///     **Bilinçli v1 sınırlaması (KABUL EDİLDİ):** bu ANDA listenin
///     BAŞKA bir alias'ı (`ys = xs`) VARSA, O alias ESKİ (artık daha
///     KISA/serbest bırakılmış) bloğu GÖRMEYE devam eder — `xs`in KENDİ
///     slotu güncellenir ama `ys`in DEĞİL (Nox'un işaretçi-DEĞERİ-
///     tutan, TEK dolaylama SEVİYELİ ARC temsilinin doğal bir sonucu —
///     TAM düzeltme bir "handle" [çift dolaylama] yeniden tasarımı
///     gerektirir, v1 kapsamı DIŞINDA).
///
/// **Bilinçli v1 sınırlaması — alıcı BİR PARAMETRE OLAMAZ:** bir
/// parametre ÖDÜNÇ alınmıştır (refcount'u ETKİLENMEDEN geçirilir, bkz.
/// modül üstü not) — büyüme yolu ESKİ bloğu predecrement/free ETTİĞİNDEN,
/// bu, callee'nin SAHİP OLMADIĞI bir referansı YANLIŞLIKLA serbest
/// bırakmasına (ÇAĞIRANIN hâlâ geçerli saydığı belleği bozmasına) yol
/// AÇARDI — checker BUNU AYIRT EDEMEDİĞİNDEN (parametre/yerel ayrımı
/// tip düzeyinde YOK), codegen `var_info.is_param` İSE `error.Unsupported`
/// döner (`checkNoLowlevelEscape`in "geniş kural, codegen seviyesinde
/// uygulanır" ÖNCEDEN kabul edilmiş desenle AYNI).
pub fn genListAppend(self: *Codegen, obj: Value, a: ast.Attribute, args: []const ast.Expr) CodegenError!Value {
    if (args.len != 1) return error.Unsupported;
    if (obj.arena) return error.Unsupported; // arena listeleri büyütülemez (v1 sınırlaması)
    // checker `a.obj.*`in bir `.identifier` OLMASINI ZORUNLU kıldı
    // (bkz. checker.zig'in `.list` dalı) — codegen bu ŞEKLE GÜVENİR.
    const recv_name = a.obj.identifier;
    // Bulundu (bkz. proje belleği "modül-seviyesi global durum" planı):
    // alıcı YEREL DEĞİL modül-seviyesi bir global OLABİLİR — büyüme
    // yolunun YENİ işaretçiyi geri yazacağı ADRES ya bir yerelin KENDİ
    // stack slotu ya da globals bloğundaki ofsetidir (`recv_addr`, HER
    // İKİ durumda da düz bir `storel val, <adres>` hedefi).
    const recv_addr: []const u8 = blk: {
        if (self.vars.get(recv_name)) |var_info| {
            if (var_info.is_param) return error.Unsupported;
            break :blk var_info.slot;
        }
        const g = self.module_globals.get(recv_name) orelse return error.Unsupported;
        const block = try self.newTemp();
        try self.qbeCall(.{ .name = block, .ty = .l }, "$nox_globals_get", &.{.{ .ty = .l, .text = RT_PARAM }});
        const addr = try self.newTemp();
        try self.qbeOp2Imm(addr, .l, "add", block, @intCast(g.offset));
        break :blk addr;
    };

    const v0 = try self.genExpr(args[0]);
    try self.checkNoLowlevelEscape(v0);
    const retained = try self.retainIfAliasing(args[0], v0);
    const val = try self.convert(retained, obj.elem_qtype);
    const elem_size = qbeSizeOf(obj.elem_qtype);

    const len_t = try self.newTemp();
    try self.qbeLoadL(len_t, obj.text);
    const cap_addr = try self.newTemp();
    try self.qbeOp2Imm(cap_addr, .l, "add", obj.text, 8);
    const cap_t = try self.newTemp();
    try self.qbeLoadL(cap_t, cap_addr);
    const has_room = try self.newTemp();
    try self.qbeOp2(has_room, .w, "csltl", len_t, cap_t);
    const grow_label = try self.newLabel("append_grow");
    const write_label = try self.newLabel("append_write");
    const done_label = try self.newLabel("append_done");
    try self.qbeJnz(has_room, write_label, grow_label);

    // Büyüme yolu: new_cap = (cap == 0) ? 1 : cap * 2 (phi'siz, alloc8
    // tabanlı bir slot ile — bu projenin TÜM merge noktalarında
    // kullandığı AYNI desen, bkz. `genListElemRelease`nin idx_slot'u).
    try self.qbeLabel(grow_label);
    const cap_is_zero = try self.newTemp();
    try self.qbeOp2Imm(cap_is_zero, .w, "ceql", cap_t, 0);
    const doubled = try self.newTemp();
    try self.qbeOp2Imm(doubled, .l, "mul", cap_t, 2);
    const new_cap_slot = try self.newTemp();
    try self.qbeAlloc(new_cap_slot, .eight, 8);
    const capzero_label = try self.newLabel("append_capzero");
    const capnz_label = try self.newLabel("append_capnz");
    const capdone_label = try self.newLabel("append_capdone");
    try self.qbeJnz(cap_is_zero, capzero_label, capnz_label);
    try self.qbeLabel(capzero_label);
    try self.qbeStoreImmL(1, new_cap_slot);
    try self.qbeJmp(capdone_label);
    try self.qbeLabel(capnz_label);
    try self.qbeStoreL(doubled, new_cap_slot);
    try self.qbeJmp(capdone_label);
    try self.qbeLabel(capdone_label);
    const new_cap = try self.newTemp();
    try self.qbeLoadL(new_cap, new_cap_slot);

    const new_payload_size = try self.newTemp();
    {
        const sz = try self.newTemp();
        try self.qbeOp2Imm(sz, .l, "mul", new_cap, @intCast(elem_size));
        try self.qbeOp2Imm(new_payload_size, .l, "add", sz, @intCast(LIST_HEADER_SIZE));
    }
    const copy_bytes = try self.newTemp();
    {
        const sz = try self.newTemp();
        try self.qbeOp2Imm(sz, .l, "mul", len_t, @intCast(elem_size));
        try self.qbeOp2Imm(copy_bytes, .l, "add", sz, @intCast(LIST_HEADER_SIZE));
    }
    const new_ptr = try self.newTemp();
    try self.qbeCall(.{ .name = new_ptr, .ty = .l }, "$nox_list_grow", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj.text }, .{ .ty = .l, .text = copy_bytes }, .{ .ty = .l, .text = new_payload_size } });

    // **Bulundu, GERÇEK bir çift-serbest-bırakma/erken-serbest-bırakma
    // hatası** (`self.attr` alanı `list[T]`i büyüten "yerel değişkene
    // oku, `.append()` et, geri yaz" desenindeki — `.append`in alıcısının
    // ÇIPLAK bir yerel OLMASI ZORUNLULUĞU YÜZÜNDEN ZORUNLU olan bir
    // örüntü, bkz. bu fonksiyonun belge notu) tam olarak bu ANDA (`self.
    // attr` HÂLÂ ESKİ bloğu görürken, yerel ZATEN YENİ bloğa geçmişken):
    // `nox_list_grow`nin `@memcpy`i ESKİ bloktaki eleman İŞARETÇİLERİNİ
    // (heap-yönetimli İSE — sınıf/liste/dize/closure) HİÇBİR retain
    // OLMADAN YENİ bloğa kopyalar. Eğer ESKİ blok bu ÇAĞRIDA hemen
    // serbest BIRAKILMAZSA (aşağıdaki `should_free` `false` İSE — ör.
    // `self.attr` HÂLÂ ona işaret ETTİĞİNDEN), ESKİ blok DAHA SONRA
    // (`self.attr = yerel` atamasının ESKİ değeri serbest bırakma
    // adımında) TAM anlamıyla ÖZYİNELEMELİ olarak serbest bırakılır
    // (`genListElemRelease`) — bu, İÇİNDEKİ HER elemanın refcount'unu
    // BİR AZALTIR, SANKİ o eleman SADECE eski bloğa AİTMİŞ gibi. Ama YENİ
    // blok da AYNI (retain edilmemiş) işaretçiyi TAŞIYOR — bu YÜZDEN
    // eleman GERÇEKTEN hâlâ İKİ blok tarafından paylaşılıyorken tek bir
    // referansmış gibi SAYILIYOR, refcount'u ERKEN sıfıra düşürüp elemanı
    // GERÇEKTEN CANLIYKEN serbest BIRAKIYOR (gerçekten gözlemlendi:
    // `router.nox`nin `Router.add`ı gibi bir sınıf-alanı büyüme
    // deseninde, İKİNCİ `.append()`den SONRA İLK elemanın alanları
    // `(null)` okunuyordu). Düzeltme: her KOPYALANMIŞ elemanı (varsa)
    // burada, YENİ bloktan, KOŞULSUZ retain et — ESKİ blok ARTIK
    // (kavramsal olarak) O elemanlara AYRI, GEÇERLİ bir sahiplik payı
    // TAŞIYORMUŞ gibi davranılır; aşağıdaki `should_free` dalı BU
    // retain'i (ESKİ blok GERÇEKTEN bu ÇAĞRIDA ölüyorsa) düz bir
    // decrement İLE dengeler — böylece HER İKİ olası kaderde (ESKİ blok
    // HEMEN ölür / DAHA SONRA bir alias üzerinden ölür) net refcount
    // DEĞİŞİMİ doğru kalır.
    if (obj.elem_heap_info != null) {
        try self.emitListElemRetainLoop(new_ptr, len_t, obj.elem_heap_info.?.heap);
    }

    // YENİ elemanı YENİ bloğa yaz, başlığı (len/cap) GÜNCELLE.
    {
        const byte_off = try self.newTemp();
        try self.qbeOp2Imm(byte_off, .l, "mul", len_t, @intCast(elem_size));
        const off16 = try self.newTemp();
        try self.qbeOp2Imm(off16, .l, "add", byte_off, @intCast(LIST_HEADER_SIZE));
        const addr = try self.newTemp();
        try self.qbeOp2(addr, .l, "add", new_ptr, off16);
        try self.qbeStore(obj.elem_qtype, val.text, addr);
    }
    const new_len = try self.newTemp();
    try self.qbeOp2Imm(new_len, .l, "add", len_t, 1);
    try self.qbeStoreL(new_len, new_ptr);
    const new_cap_addr = try self.newTemp();
    try self.qbeOp2Imm(new_cap_addr, .l, "add", new_ptr, 8);
    try self.qbeStoreL(new_cap, new_cap_addr);

    // ESKİ bloğu (yalnızca KENDİ ham belleğini — elemanlar TAŞINDI,
    // özyinelemeli release EDİLMEZ) refcount'u sıfıra düşerse serbest
    // bırak (bkz. bu fonksiyonun belge notu, "büyüme yolu").
    const should_free = try self.emitInlinePredecrement(obj.text, .list);
    const free_label = try self.newLabel("append_free_old");
    const skip_free_label = try self.newLabel("append_skip_free");
    try self.qbeJnz(should_free, free_label, skip_free_label);
    try self.qbeLabel(free_label);
    if (obj.elem_heap_info != null) {
        // ESKİ blok BU çağrıda gerçekten ölüyor (`self.attr` GİBİ başka
        // bir alias YOK) — yukarıdaki retain döngüsünün eklediği "fazladan"
        // payı DÜZ bir decrement İLE dengele (TAM özyinelemeli release
        // DEĞİL: bu decrement ASLA sıfıra/altına düşemez, çünkü elemanın
        // ÖNCEKİ, GEÇERLİ sahipliği HÂLÂ duruyor — bkz. `genListAppend`nin
        // büyüme-retain notunun tam gerekçesi).
        try self.emitListElemPlainDecrementLoop(obj.text, len_t, obj.elem_heap_info.?.heap);
    }
    const old_size = try self.newTemp();
    {
        const sz = try self.newTemp();
        try self.qbeOp2Imm(sz, .l, "mul", cap_t, @intCast(elem_size));
        try self.qbeOp2Imm(old_size, .l, "add", sz, @intCast(LIST_HEADER_SIZE));
    }
    try self.qbeCall(null, "$nox_rc_free_payload", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj.text }, .{ .ty = .l, .text = old_size } });
    try self.qbeJmp(skip_free_label);
    try self.qbeLabel(skip_free_label);

    // Alıcının KENDİ slotuna/global ofsetine YENİ işaretçiyi geri yaz —
    // TEK yerde (hızlı yol bloğun adresini HİÇ değiştirmediğinden
    // gerekmez).
    try self.qbeStoreL(new_ptr, recv_addr);
    try self.qbeJmp(done_label);

    // Hızlı yol: KENDİ bloğuna yerinde yaz.
    try self.qbeLabel(write_label);
    {
        const byte_off = try self.newTemp();
        try self.qbeOp2Imm(byte_off, .l, "mul", len_t, @intCast(elem_size));
        const off16 = try self.newTemp();
        try self.qbeOp2Imm(off16, .l, "add", byte_off, @intCast(LIST_HEADER_SIZE));
        const addr = try self.newTemp();
        try self.qbeOp2(addr, .l, "add", obj.text, off16);
        try self.qbeStore(obj.elem_qtype, val.text, addr);
    }
    const fast_new_len = try self.newTemp();
    try self.qbeOp2Imm(fast_new_len, .l, "add", len_t, 1);
    try self.qbeStoreL(fast_new_len, obj.text);
    try self.qbeJmp(done_label);

    try self.qbeLabel(done_label);
    return .{ .text = "0", .qtype = .w };
}

/// `xs.sort()` — Faz EE.1 (bkz. nox-teknik-spesifikasyon.md §3.61).
/// `.append`nin AKSİNE alıcının SLOTUNA geri yazma/`nox_list_grow`
/// GEREKMEZ — sıralama MEVCUT arabelleği YERİNDE değiştirir (`len`/
/// `cap` DEĞİŞMEZ), bu yüzden `genListAppend`nin "alıcı çıplak isim/
/// yerel OLMALI" kısıtı burada UYGULANMAZ (checker de UYGULAMAZ, bkz.
/// onun `.list` dalı). Eleman tipine göre (`elem_qtype`/`elem_is_str`)
/// `nox_list_sort_int`/`_float`/`_str`den (bkz. `runtime/collections/
/// list_sort.zig`) DOĞRU olanı, listenin BAŞLIKTAN (16 bayt) SONRAKİ
/// ham eleman adresi + `len`i geçirerek çağırır.
pub fn genListSort(self: *Codegen, obj: Value, a: ast.Attribute, args: []const ast.Expr) CodegenError!Value {
    if (args.len != 0) return error.Unsupported;

    const len_t = try self.newTemp();
    try self.qbeLoadL(len_t, obj.text);
    const data_addr = try self.newTemp();
    try self.qbeOp2Imm(data_addr, .l, "add", obj.text, @intCast(LIST_HEADER_SIZE));

    const fn_name = if (obj.elem_qtype == .d)
        "nox_list_sort_float"
    else if (obj.elem_is_str)
        "nox_list_sort_str"
    else
        "nox_list_sort_int";
    const fn_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{fn_name});
    try self.qbeCall(null, fn_sym, &.{ .{ .ty = .l, .text = data_addr }, .{ .ty = .l, .text = len_t } });
    // `.append`nin AKSİNE alıcı çıplak bir isimle SINIRLI DEĞİLDİR
    // (bkz. bu fonksiyonun belge notu) — `a.obj.*` bir GEÇİCİ (ör.
    // `getList().sort()`) OLABİLİR, `genDictMethod`nin `contains`/`len`
    // dallarıyla AYNI şekilde serbest bırakılmalıdır.
    try self.releaseIfTemporary(a.obj.*, obj);
    return .{ .text = "0", .qtype = .none };
}

/// `list[T].pop()` — SON elemanı kaldırıp döner. `.append`in AKSİNE HİÇBİR
/// ZAMAN büyümez/yeniden ayırmaz (SADECE `len` başlığını AYNI blokta bir
/// AZALTIR) — bu yüzden `.sort()` İLE AYNI şekilde alıcı keyfi bir ifade
/// olabilir (`self.items.pop()` doğrudan geçerli, "yerele kopyala-mutasyona
/// uğrat-geri yaz" dansı GEREKMEZ, bkz. `stdlib/nox/collections.nox`).
/// Sahiplik: dönen değer ARTIK SADECE çağırana AİTTİR — `len`i AZALTMAK
/// bu slotu listenin KENDİ yıkımının (`genListElemRelease`, 0..len'i
/// gezer) taradığı ARALIK DIŞINA çıkarır, bu yüzden EK bir retain/release
/// GEREKMEZ (net refcount DEĞİŞMEZ, sadece MÜLKİYET listeden çağırana
/// TAŞINIR) — `genIndex`in ÖDÜNÇ-ALINMIŞ okumasının AKSİNE (bkz. onun
/// belge notu), çünkü ORADA eleman listenin İÇİNDE KALIR.
pub fn genListPop(self: *Codegen, obj: Value, a: ast.Attribute) CodegenError!Value {
    const len_t = try self.newTemp();
    try self.qbeLoadL(len_t, obj.text);

    const empty_t = try self.newTemp();
    try self.qbeOp2Imm(empty_t, .w, "ceql", len_t, 0);
    const err_label = try self.newLabel("list_pop_err");
    const ok_label = try self.newLabel("list_pop_ok");
    try self.qbeJnz(empty_t, err_label, ok_label);
    try self.qbeLabel(err_label);
    const msg_value = try self.emitStringLiteral("bos liste (list) pop edilemez");
    const ie_cinfo = self.classes.get("IndexError") orelse return error.Unsupported;
    const ie_obj = try self.genConstructFromValues("IndexError", ie_cinfo, &.{msg_value}, null);
    try self.qbeCall(null, "$nox_raise", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ie_obj.text }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{self.current_raise_line}) } });
    // Bulundu (bkz. proje belleği "4 yeni stdlib modülü" planı — AYNI
    // sınıf hata, `genMethodCall`in belge notundaki GİBİ): bu dal
    // KOŞULSUZ raise edip aşağı ATLAR — `obj` (alıcı) TEMPORARY İSE
    // (ör. `getList().pop()` boş bir liste üzerinde) normal yoldaki
    // (aşağıdaki `ok_label` SONRASI) serbest bırakma BURAYA HİÇ
    // ULAŞMAZ. `obj`nin BURADAN SONRA HİÇ kullanılmadığı İçin (SADECE
    // raise edip çıkıyoruz) serbest bırakmak GÜVENLİDİR.
    try self.releaseIfTemporary(a.obj.*, obj);
    try self.emitExceptionCheck();
    try self.qbeJmp(ok_label);
    try self.qbeLabel(ok_label);

    const new_len = try self.newTemp();
    try self.qbeOp2Imm(new_len, .l, "sub", len_t, 1);
    // Yeni `len`i ÖNCE yaz — `obj` temporary İSE aşağıdaki `releaseIfTemporary`
    // listeyi TAMAMEN yıkıyorsa (refcount sıfıra düşerse), `genListElemRelease`
    // bu ANDAN İTİBAREN yalnızca 0..new_len'i gezer, az önce okuduğumuz
    // (şimdi new_len indeksindeki) elemana HİÇ dokunmaz.
    try self.qbeStoreL(new_len, obj.text);

    const byte_off = try self.newTemp();
    try self.qbeOp2Imm(byte_off, .l, "mul", new_len, @intCast(qbeSizeOf(obj.elem_qtype)));
    const off8 = try self.newTemp();
    try self.qbeOp2Imm(off8, .l, "add", byte_off, @intCast(LIST_HEADER_SIZE));
    const addr = try self.newTemp();
    try self.qbeOp2(addr, .l, "add", obj.text, off8);
    const result = try self.newTemp();
    try self.qbeLoad(result, obj.elem_qtype, obj.elem_qtype, addr);

    try self.releaseIfTemporary(a.obj.*, obj);

    return abi.valueFromElemDescriptor(result, obj.elem_qtype, obj.elem_heap_info, obj.elem_is_str);
}

/// `Channel[T](capacity)`/`ThreadChannel[T](capacity)` (yerleşikler) YA DA
/// Faz P2.1'in kullanıcı-tanımlı generic sınıf kurucusu (bkz. `ast.
/// GenericConstruct.resolved_class_name`in belge notu) — AÇIK tip argümanlı
/// bir kurucu çağrısı.
pub fn genGenericConstruct(self: *Codegen, g: ast.GenericConstruct) CodegenError!Value {
    // Faz P2.1: checker `resolved_class_name`i YALNIZCA kullanıcı-tanımlı
    // generic sınıf dalında doldurur (`Channel`/`ThreadChannel` İçin HER
    // ZAMAN `null` kalır) — dolu İSE, sıradan `ClassName(args)` kurucu
    // çağrısıyla AYNI yol (`genConstruct`) kullanılır (bkz. calls.zig:134'ün
    // AYNI deseni).
    if (g.resolved_class_name.*) |mangled| {
        const cinfo = self.classes.get(mangled) orelse return error.Unsupported;
        return self.genConstruct(mangled, cinfo, g.args);
    }
    // Faz OO.2 (bkz. nox-teknik-spesifikasyon.md §3.83): `TaskLocal[T]()`
    // — `Channel[T]`in AYNI `elem_heap_info`/`elem_is_str` yakalama
    // deseni (checker `T`nin HEAP-yönetimli OLMASINI ZATEN ZORUNLU KILDI),
    // ama `nox_tasklocal_new`nin `capacity` argümanı YOKTUR.
    if (std.mem.eql(u8, g.name, "TaskLocal")) {
        if (g.type_args.len != 1 or g.args.len != 0) return error.Unsupported;
        const elem = try self.resolveType(g.type_args[0]);
        const tl_t = try self.newTemp();
        try self.qbeCall(.{ .name = tl_t, .ty = .l }, "$nox_tasklocal_new", &.{.{ .ty = .l, .text = RT_PARAM }});
        var elem_heap_info: ?*const ElemHeapInfo = null;
        if (elem.heap == .class or elem.heap == .list) {
            const info = try self.allocator.create(ElemHeapInfo);
            info.* = .{ .heap = elem.heap, .class_name = elem.class_name, .elem_qtype = elem.elem_qtype, .nested = elem.elem_heap_info, .elem_is_str = elem.elem_is_str };
            elem_heap_info = info;
        }
        return .{
            .text = tl_t,
            .qtype = .l,
            .heap = .task_local,
            .elem_qtype = elem.qtype,
            .elem_heap_info = elem_heap_info,
            .elem_is_str = elem.heap == .str,
        };
    }
    const is_thread_channel = std.mem.eql(u8, g.name, "ThreadChannel");
    if (!(is_thread_channel or std.mem.eql(u8, g.name, "Channel")) or g.type_args.len != 1 or g.args.len != 1) return error.Unsupported;
    const elem = try self.resolveType(g.type_args[0]);
    const cap_val = try self.genExpr(g.args[0]);
    const ch_t = try self.newTemp();
    const new_fn_name = if (is_thread_channel) "nox_threadchannel_new" else "nox_channel_new";
    const new_fn_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{new_fn_name});
    try self.qbeCall(.{ .name = ch_t, .ty = .l }, new_fn_sym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = cap_val.text } });

    var elem_heap_info: ?*const ElemHeapInfo = null;
    if (elem.heap == .class or elem.heap == .list) {
        const info = try self.allocator.create(ElemHeapInfo);
        info.* = .{ .heap = elem.heap, .class_name = elem.class_name, .elem_qtype = elem.elem_qtype, .nested = elem.elem_heap_info, .elem_is_str = elem.elem_is_str };
        elem_heap_info = info;
    }
    return .{
        .text = ch_t,
        .qtype = .l,
        .heap = if (is_thread_channel) .thread_channel else .channel,
        .elem_qtype = elem.qtype,
        .elem_heap_info = elem_heap_info,
        .elem_is_str = elem.heap == .str,
    };
}
