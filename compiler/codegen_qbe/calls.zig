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
const FuncSigInfo = types.FuncSigInfo;
const CodegenError = abi.CodegenError;
const qbeTypeName = abi.qbeTypeName;
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
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ fn_ptr, closure_ptr });

    const arg_values = try self.allocator.alloc(Value, args.len);
    for (args, 0..) |a, i| {
        const v0 = try self.genExprForTarget(a, fsig.params[i]);
        try self.checkNoLowlevelEscape(v0);
        arg_values[i] = try self.convert(v0, fsig.params[i].qtype);
    }

    const ret_qtype = fsig.ret.qtype;
    const result_temp: ?[]const u8 = if (ret_qtype == .none) null else try self.newTemp();
    if (result_temp) |rt| {
        try self.out.writer.print("    {s} ={s} call {s}(l {s}, l {s}", .{ rt, qbeTypeName(ret_qtype), fn_ptr, RT_PARAM, closure_ptr });
    } else {
        try self.out.writer.print("    call {s}(l {s}, l {s}", .{ fn_ptr, RT_PARAM, closure_ptr });
    }
    for (arg_values) |v| try self.out.writer.print(", {s} {s}", .{ qbeTypeName(v.qtype), v.text });
    try self.out.writer.writeAll(")\n");
    // Dolaylı çağrının HEDEFİ (çağrılan SOMUT closure) derleme zamanında
    // bilinmediğinden `must_not_raise` eleme optimizasyonu (bkz. normal
    // fonksiyon çağrısı dalı) burada UYGULANAMAZ — İSTİSNA kontrolü HER
    // ZAMAN yapılır (güvenli varsayılan).
    try self.emitExceptionCheck();
    try self.releaseTemporaryArgs(args, arg_values);

    if (result_temp) |rt| {
        return .{ .text = rt, .qtype = ret_qtype, .heap = fsig.ret.heap, .elem_qtype = fsig.ret.elem_qtype, .class_name = fsig.ret.class_name, .elem_heap_info = fsig.ret.elem_heap_info, .elem_is_str = fsig.ret.elem_is_str };
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
                    try self.out.writer.print("    {s} =l loadl {s}\n", .{ result_t, v.text });
                } else {
                    try self.out.writer.print("    {s} =l call $nox_str_char_count(l {s})\n", .{ result_t, v.text });
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
                    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ v.text, true_label, false_label });
                    try self.out.writer.print("{s}\n", .{true_label});
                    const true_v = try self.emitStringLiteral("True");
                    try self.out.writer.print("    jmp {s}\n", .{done_label});
                    try self.out.writer.print("{s}\n", .{false_label});
                    const false_v = try self.emitStringLiteral("False");
                    try self.out.writer.print("    jmp {s}\n", .{done_label});
                    try self.out.writer.print("{s}\n", .{done_label});
                    const result_t = try self.newTemp();
                    try self.out.writer.print("    {s} =l phi {s} {s}, {s} {s}\n", .{ result_t, true_label, true_v.text, false_label, false_v.text });
                    return .{ .text = result_t, .qtype = .l, .heap = .str };
                }
                const result_t = try self.newTemp();
                if (v.qtype == .d) {
                    try self.out.writer.print("    {s} =l call $nox_float_to_str(l {s}, d {s})\n", .{ result_t, RT_PARAM, v.text });
                } else {
                    try self.out.writer.print("    {s} =l call $nox_int_to_str(l {s}, l {s})\n", .{ result_t, RT_PARAM, v.text });
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
                try self.out.writer.print("    {s} =l call $nox_hpy_call(l {s}, l {s}, l {s}, l {s}, l {s})\n", .{ result_temp, RT_PARAM, path_v.text, ext_v.text, func_v.text, arg_v.text });
                return .{ .text = result_temp, .qtype = .l };
            }
            if (std.mem.eql(u8, name, "wasm_call")) {
                if (c.args.len != 3) return error.Unsupported;
                const path_v = try self.genExpr(c.args[0]);
                const func_v = try self.genExpr(c.args[1]);
                const arg_v = try self.genExpr(c.args[2]);
                const result_temp = try self.newTemp();
                try self.out.writer.print("    {s} =l call $nox_wasm_call(l {s}, l {s}, l {s}, l {s})\n", .{ result_temp, RT_PARAM, path_v.text, func_v.text, arg_v.text });
                return .{ .text = result_temp, .qtype = .l };
            }

            if (self.classes.get(name)) |cinfo| return self.genConstruct(name, cinfo, c.args);

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
                if (result_temp) |rt| {
                    try self.out.writer.print("    {s} ={s} call ${s}(", .{ rt, qbeTypeName(esig.ret.qtype), name });
                } else {
                    try self.out.writer.print("    call ${s}(", .{name});
                }
                // `with_rt` (bkz. `ast.ExternDef.needs_rt`in belge notu,
                // stdlib fazı §D.1): `RT_PARAM` GİZLİCE argüman
                // listesinin BAŞINA eklenir (normal fonksiyon
                // çağrılarıyla AYNI kalıp) — Zig tarafının İLK parametresi
                // `rt: ?*anyopaque` olmalıdır.
                var wrote_arg = false;
                if (esig.needs_rt) {
                    try self.out.writer.print("l {s}", .{RT_PARAM});
                    wrote_arg = true;
                }
                for (arg_values) |v| {
                    if (wrote_arg) try self.out.writer.writeAll(", ");
                    try self.out.writer.print("{s} {s}", .{ qbeTypeName(v.qtype), v.text });
                    wrote_arg = true;
                }
                try self.out.writer.writeAll(")\n");
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
                    try self.out.writer.print("    {s} =l loadl {s}\n", .{ closure_ptr, info.slot });
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
            if (result_temp) |rt| {
                try self.out.writer.print("    {s} ={s} call ${s}(l {s}", .{ rt, qbeTypeName(sig.ret.qtype), name, RT_PARAM });
            } else {
                try self.out.writer.print("    call ${s}(l {s}", .{ name, RT_PARAM });
            }
            for (arg_values) |v| try self.out.writer.print(", {s} {s}", .{ qbeTypeName(v.qtype), v.text });
            try self.out.writer.writeAll(")\n");
            // Performans fazı: `name`in ASLA istisna fırlatamayacağı
            // KANITLANDIYSA (bkz. `self.must_not_raise`, `computeMustNotRaise`)
            // kontrolü ATLA.
            if (!self.must_not_raise.contains(name)) try self.emitExceptionCheck();
            try self.releaseTemporaryArgs(c.args, arg_values);

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
    try self.out.writer.print("    {s} =w call ${s}(l {s})\n", .{ valid_t, valid_fn, v.text });
    const err_label = try self.newLabel("parse_err");
    const ok_label = try self.newLabel("parse_ok");
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ valid_t, ok_label, err_label });
    try self.out.writer.print("{s}\n", .{err_label});

    const msg_value = try self.emitStringLiteral(message);
    const ve_cinfo = self.classes.get("ValueError") orelse return error.Unsupported;
    const ve_obj = try self.genConstructFromValues("ValueError", ve_cinfo, &.{msg_value});
    try self.out.writer.print("    call $nox_raise(l {s}, l {s})\n", .{ RT_PARAM, ve_obj.text });
    try self.emitExceptionCheck();
    try self.out.writer.print("    jmp {s}\n", .{ok_label});

    try self.out.writer.print("{s}\n", .{ok_label});
    const result_t = try self.newTemp();
    try self.out.writer.print("    {s} ={s} call ${s}(l {s})\n", .{ result_t, qbeTypeName(result_qtype), convert_fn, v.text });
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
        if (isHeapManaged(v.heap) and (v.always_fresh or isTemporaryExpr(e))) {
            try self.releaseValueIfSet(v.text, v.heap, v.elem_qtype, v.class_name, v.elem_heap_info, v.dict_info);
        }
    }
}

/// `releaseTemporaryArgs` ile aynı gerekçe, tek bir değer için — bir metod
/// çağrısının ALICISI (ör. `Engine(1).some_method()`), bir alan
/// okumasının/indekslemenin TABANI (ör. `make_car(i).engine`,
/// `make_list()[0]`) da aynı şekilde taze bir geçici olabilir.
pub fn releaseIfTemporary(self: *Codegen, e: ast.Expr, v: Value) CodegenError!void {
    // Bkz. `releaseTemporaryArgs`in AYNI notu (`v.always_fresh`).
    if (isHeapManaged(v.heap) and (v.always_fresh or isTemporaryExpr(e))) {
        try self.releaseValueIfSet(v.text, v.heap, v.elem_qtype, v.class_name, v.elem_heap_info, v.dict_info);
    }
}

/// İçinde bulunulan en yakın `lowlevel` bloğunun arena işaretçisi (varsa).
pub fn currentArena(self: *Codegen) ?[]const u8 {
    if (self.arena_stack.items.len == 0) return null;
    return self.arena_stack.items[self.arena_stack.items.len - 1];
}

pub fn genConstruct(self: *Codegen, class_name: []const u8, cinfo: ClassInfo, args: []const ast.Expr) CodegenError!Value {
    if (cinfo.init_params.len != args.len) return error.Unsupported;
    const arg_values = try self.allocator.alloc(Value, args.len);
    for (args, 0..) |a, i| {
        const v0 = try self.genExprForTarget(a, cinfo.init_params[i]);
        try self.checkNoLowlevelEscape(v0);
        arg_values[i] = try self.convert(v0, cinfo.init_params[i].qtype);
    }
    const result = try self.genConstructFromValues(class_name, cinfo, arg_values);
    try self.releaseTemporaryArgs(args, arg_values);
    return result;
}

/// `genConstruct`ın AST-BAĞIMSIZ çekirdeği — stdlib fazı §D.1.6'nın
/// `nox.http.serve` sarmalayıcısı (bkz. `genHttpServeWrapper`), bir
/// `HttpRequest` örneğini kaynak-düzeyi `ast.Expr` argümanlarından DEĞİL,
/// zaten HESAPLANMIŞ `Value`lerden (extern erişimci çağrılarının
/// sonuçlarından) inşa etmesi GEREKTİĞİNDEN bu ayrım gerekli — çağıran
/// TARAF, `arg_values`in serbest bırakılması/geçici argüman temizliği
/// GEREKİP GEREKMEDİĞİNİ kendisi bilir (bkz. `genConstruct`ın
/// `releaseTemporaryArgs` çağrısı — bu YARDIMCI onu YAPMAZ).
pub fn genConstructFromValues(self: *Codegen, class_name: []const u8, cinfo: ClassInfo, arg_values: []const Value) CodegenError!Value {
    if (cinfo.init_params.len != arg_values.len) return error.Unsupported;
    const t = try self.newTemp();
    const arena = self.currentArena();
    if (arena) |ap| {
        try self.out.writer.print("    {s} =l call $nox_arena_alloc(l {s}, l {d})\n", .{ t, ap, cinfo.total_size });
    } else {
        try self.out.writer.print("    {s} =l call $nox_rc_alloc(l {s}, l {d})\n", .{ t, RT_PARAM, cinfo.total_size });
    }
    try self.out.writer.print("    storel {d}, {s}\n", .{ cinfo.class_id, t });
    // Alanlar `__init__` çalışmadan ÖNCE sıfırlanır: bu sayede sınıf tipli
    // bir alana ilk kez yazarken `genAssign`'in "önce eskiyi serbest
    // bırak" mantığı (bkz. `.attribute` durumu) çöp bir işaretçiyi asla
    // release etmeye çalışmaz — tahsis edilmiş bellek sıfırla
    // doldurulmuş SAYILAMAZ (bkz. runtime/alloc/asap.zig, DebugAllocator).
    for (cinfo.fields.items) |f| {
        const addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ addr, t, f.offset });
        try self.out.writer.print("    storel 0, {s}\n", .{addr});
    }
    // `has_init == false`: sınıfın hiç `__init__`i yok (bkz.
    // `ClassInfo.has_init`in belge notu) — `generateModule` bu sınıf için
    // `$ClassName___init__`i HİÇ ÜRETMEDİ, bu yüzden burada çağırmak
    // bağlantı zamanında çözülemeyen bir sembole yol açardı.
    if (cinfo.has_init) {
        try self.out.writer.print("    call ${s}_{s}(l {s}, l {s}", .{ class_name, "__init__", RT_PARAM, t });
        for (arg_values) |v| try self.out.writer.print(", {s} {s}", .{ qbeTypeName(v.qtype), v.text });
        try self.out.writer.writeAll(")\n");
        // Performans fazı: `__init__`in ASLA istisna fırlatamayacağı
        // KANITLANDIYSA (bkz. `ClassInfo.init_is_safe`, `computeMustNotRaise`)
        // kontrolü ATLA.
        if (!cinfo.init_is_safe) try self.emitExceptionCheck();
    }
    return .{ .text = t, .qtype = .l, .heap = .class, .class_name = class_name, .arena = arena != null };
}

pub fn genMethodCall(self: *Codegen, a: ast.Attribute, args: []const ast.Expr) CodegenError!Value {
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
        return self.genListAppend(obj, a, args);
    }
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
            try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ addr, obj.text, f.offset });
            const closure_ptr = try self.newTemp();
            try self.out.writer.print("    {s} =l loadl {s}\n", .{ closure_ptr, addr });
            const result = try self.genIndirectCallThroughClosurePtr(closure_ptr, fsig, args);
            try self.releaseIfTemporary(a.obj.*, obj);
            return result;
        }
        return error.Unsupported;
    };
    if (msig.params.len != args.len) return error.Unsupported;

    const arg_values = try self.allocator.alloc(Value, args.len);
    for (args, 0..) |arg, i| {
        const v0 = try self.genExprForTarget(arg, msig.params[i]);
        try self.checkNoLowlevelEscape(v0);
        arg_values[i] = try self.convert(v0, msig.params[i].qtype);
    }

    const result_temp: ?[]const u8 = if (msig.ret.qtype == .none) null else try self.newTemp();
    if (result_temp) |rt| {
        try self.out.writer.print("    {s} ={s} call ${s}_{s}(l {s}, l {s}", .{ rt, qbeTypeName(msig.ret.qtype), obj.class_name.?, a.attr, RT_PARAM, obj.text });
    } else {
        try self.out.writer.print("    call ${s}_{s}(l {s}, l {s}", .{ obj.class_name.?, a.attr, RT_PARAM, obj.text });
    }
    for (arg_values) |v| try self.out.writer.print(", {s} {s}", .{ qbeTypeName(v.qtype), v.text });
    try self.out.writer.writeAll(")\n");
    // Faz M.8 (yeniden ele alındı, bkz. nox-teknik-spesifikasyon.md
    // §3.59): `computeMustNotRaise` ARTIK TÜM metodları (yalnızca
    // `__init__` değil) analiz ediyor — hedef metod bu kümedeyse
    // (sembol formatı `genCall`in serbest-fonksiyon dalıyla TUTARLI,
    // bkz. `computeMustNotRaise`in belge notu) kontrol atlanabilir.
    const method_sym = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ obj.class_name.?, a.attr });
    if (!self.must_not_raise.contains(method_sym)) try self.emitExceptionCheck();
    try self.releaseIfTemporary(a.obj.*, obj);
    try self.releaseTemporaryArgs(args, arg_values);

    if (result_temp) |rt| {
        return .{ .text = rt, .qtype = msig.ret.qtype, .heap = msig.ret.heap, .elem_qtype = msig.ret.elem_qtype, .class_name = msig.ret.class_name, .elem_heap_info = msig.ret.elem_heap_info, .elem_is_str = msig.ret.elem_is_str };
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
        try self.out.writer.print("    {s} =w call $nox_dict_contains(l {s}, w {s}, l {s})\n", .{ result, obj.text, key_is_str_lit, key_payload.text });
        try self.releaseIfTemporary(args[0], key_v0);
        try self.releaseIfTemporary(a.obj.*, obj);
        return .{ .text = result, .qtype = .w };
    }
    if (std.mem.eql(u8, a.attr, "len")) {
        if (args.len != 0) return error.Unsupported;
        const result = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_dict_len(l {s})\n", .{ result, obj.text });
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
        try self.out.writer.print("    {s} =l call $nox_dict_keys(l {s}, l {s}, w {s}, l {d})\n", .{ result, RT_PARAM, obj.text, key_is_str_lit, elem_size });
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
        const elem_size = qbeSizeOf(dinfo.value_qtype);
        const result = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_dict_values(l {s}, l {s}, w {s}, l {d})\n", .{ result, RT_PARAM, obj.text, value_is_str_lit, elem_size });
        try self.releaseIfTemporary(a.obj.*, obj);
        var elem_heap_info: ?*const ElemHeapInfo = null;
        if (dinfo.value_is_str) {
            const info = try self.allocator.create(ElemHeapInfo);
            info.* = .{ .heap = .str };
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
    const var_info = self.vars.get(recv_name) orelse return error.Unsupported;
    if (var_info.is_param) return error.Unsupported;

    const v0 = try self.genExpr(args[0]);
    try self.checkNoLowlevelEscape(v0);
    const retained = try self.retainIfAliasing(args[0], v0);
    const val = try self.convert(retained, obj.elem_qtype);
    const elem_size = qbeSizeOf(obj.elem_qtype);

    const len_t = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ len_t, obj.text });
    const cap_addr = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, 8\n", .{ cap_addr, obj.text });
    const cap_t = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ cap_t, cap_addr });
    const has_room = try self.newTemp();
    try self.out.writer.print("    {s} =w csltl {s}, {s}\n", .{ has_room, len_t, cap_t });
    const grow_label = try self.newLabel("append_grow");
    const write_label = try self.newLabel("append_write");
    const done_label = try self.newLabel("append_done");
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ has_room, write_label, grow_label });

    // Büyüme yolu: new_cap = (cap == 0) ? 1 : cap * 2 (phi'siz, alloc8
    // tabanlı bir slot ile — bu projenin TÜM merge noktalarında
    // kullandığı AYNI desen, bkz. `genListElemRelease`nin idx_slot'u).
    try self.out.writer.print("{s}\n", .{grow_label});
    const cap_is_zero = try self.newTemp();
    try self.out.writer.print("    {s} =w ceql {s}, 0\n", .{ cap_is_zero, cap_t });
    const doubled = try self.newTemp();
    try self.out.writer.print("    {s} =l mul {s}, 2\n", .{ doubled, cap_t });
    const new_cap_slot = try self.newTemp();
    try self.out.writer.print("    {s} =l alloc8 8\n", .{new_cap_slot});
    const capzero_label = try self.newLabel("append_capzero");
    const capnz_label = try self.newLabel("append_capnz");
    const capdone_label = try self.newLabel("append_capdone");
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ cap_is_zero, capzero_label, capnz_label });
    try self.out.writer.print("{s}\n", .{capzero_label});
    try self.out.writer.print("    storel 1, {s}\n", .{new_cap_slot});
    try self.out.writer.print("    jmp {s}\n", .{capdone_label});
    try self.out.writer.print("{s}\n", .{capnz_label});
    try self.out.writer.print("    storel {s}, {s}\n", .{ doubled, new_cap_slot });
    try self.out.writer.print("    jmp {s}\n", .{capdone_label});
    try self.out.writer.print("{s}\n", .{capdone_label});
    const new_cap = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ new_cap, new_cap_slot });

    const new_payload_size = try self.newTemp();
    {
        const sz = try self.newTemp();
        try self.out.writer.print("    {s} =l mul {s}, {d}\n", .{ sz, new_cap, elem_size });
        try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ new_payload_size, sz, LIST_HEADER_SIZE });
    }
    const copy_bytes = try self.newTemp();
    {
        const sz = try self.newTemp();
        try self.out.writer.print("    {s} =l mul {s}, {d}\n", .{ sz, len_t, elem_size });
        try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ copy_bytes, sz, LIST_HEADER_SIZE });
    }
    const new_ptr = try self.newTemp();
    try self.out.writer.print("    {s} =l call $nox_list_grow(l {s}, l {s}, l {s}, l {s})\n", .{ new_ptr, RT_PARAM, obj.text, copy_bytes, new_payload_size });

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
        try self.emitListElemRetainLoop(new_ptr, len_t);
    }

    // YENİ elemanı YENİ bloğa yaz, başlığı (len/cap) GÜNCELLE.
    {
        const byte_off = try self.newTemp();
        try self.out.writer.print("    {s} =l mul {s}, {d}\n", .{ byte_off, len_t, elem_size });
        const off16 = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ off16, byte_off, LIST_HEADER_SIZE });
        const addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {s}\n", .{ addr, new_ptr, off16 });
        try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(obj.elem_qtype), val.text, addr });
    }
    const new_len = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, 1\n", .{ new_len, len_t });
    try self.out.writer.print("    storel {s}, {s}\n", .{ new_len, new_ptr });
    const new_cap_addr = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, 8\n", .{ new_cap_addr, new_ptr });
    try self.out.writer.print("    storel {s}, {s}\n", .{ new_cap, new_cap_addr });

    // ESKİ bloğu (yalnızca KENDİ ham belleğini — elemanlar TAŞINDI,
    // özyinelemeli release EDİLMEZ) refcount'u sıfıra düşerse serbest
    // bırak (bkz. bu fonksiyonun belge notu, "büyüme yolu").
    const should_free = try self.emitInlinePredecrement(obj.text);
    const free_label = try self.newLabel("append_free_old");
    const skip_free_label = try self.newLabel("append_skip_free");
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ should_free, free_label, skip_free_label });
    try self.out.writer.print("{s}\n", .{free_label});
    if (obj.elem_heap_info != null) {
        // ESKİ blok BU çağrıda gerçekten ölüyor (`self.attr` GİBİ başka
        // bir alias YOK) — yukarıdaki retain döngüsünün eklediği "fazladan"
        // payı DÜZ bir decrement İLE dengele (TAM özyinelemeli release
        // DEĞİL: bu decrement ASLA sıfıra/altına düşemez, çünkü elemanın
        // ÖNCEKİ, GEÇERLİ sahipliği HÂLÂ duruyor — bkz. `genListAppend`nin
        // büyüme-retain notunun tam gerekçesi).
        try self.emitListElemPlainDecrementLoop(obj.text, len_t);
    }
    const old_size = try self.newTemp();
    {
        const sz = try self.newTemp();
        try self.out.writer.print("    {s} =l mul {s}, {d}\n", .{ sz, cap_t, elem_size });
        try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ old_size, sz, LIST_HEADER_SIZE });
    }
    try self.out.writer.print("    call $nox_rc_free_payload(l {s}, l {s}, l {s})\n", .{ RT_PARAM, obj.text, old_size });
    try self.out.writer.print("    jmp {s}\n", .{skip_free_label});
    try self.out.writer.print("{s}\n", .{skip_free_label});

    // Alıcının KENDİ slotuna YENİ işaretçiyi geri yaz — TEK yerde
    // (hızlı yol bloğun adresini HİÇ değiştirmediğinden gerekmez).
    try self.out.writer.print("    storel {s}, {s}\n", .{ new_ptr, var_info.slot });
    try self.out.writer.print("    jmp {s}\n", .{done_label});

    // Hızlı yol: KENDİ bloğuna yerinde yaz.
    try self.out.writer.print("{s}\n", .{write_label});
    {
        const byte_off = try self.newTemp();
        try self.out.writer.print("    {s} =l mul {s}, {d}\n", .{ byte_off, len_t, elem_size });
        const off16 = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ off16, byte_off, LIST_HEADER_SIZE });
        const addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {s}\n", .{ addr, obj.text, off16 });
        try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(obj.elem_qtype), val.text, addr });
    }
    const fast_new_len = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, 1\n", .{ fast_new_len, len_t });
    try self.out.writer.print("    storel {s}, {s}\n", .{ fast_new_len, obj.text });
    try self.out.writer.print("    jmp {s}\n", .{done_label});

    try self.out.writer.print("{s}\n", .{done_label});
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
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ len_t, obj.text });
    const data_addr = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ data_addr, obj.text, LIST_HEADER_SIZE });

    const fn_name = if (obj.elem_qtype == .d)
        "nox_list_sort_float"
    else if (obj.elem_is_str)
        "nox_list_sort_str"
    else
        "nox_list_sort_int";
    try self.out.writer.print("    call ${s}(l {s}, l {s})\n", .{ fn_name, data_addr, len_t });
    // `.append`nin AKSİNE alıcı çıplak bir isimle SINIRLI DEĞİLDİR
    // (bkz. bu fonksiyonun belge notu) — `a.obj.*` bir GEÇİCİ (ör.
    // `getList().sort()`) OLABİLİR, `genDictMethod`nin `contains`/`len`
    // dallarıyla AYNI şekilde serbest bırakılmalıdır.
    try self.releaseIfTemporary(a.obj.*, obj);
    return .{ .text = "0", .qtype = .none };
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
    const is_thread_channel = std.mem.eql(u8, g.name, "ThreadChannel");
    if (!(is_thread_channel or std.mem.eql(u8, g.name, "Channel")) or g.type_args.len != 1 or g.args.len != 1) return error.Unsupported;
    const elem = try self.resolveType(g.type_args[0]);
    const cap_val = try self.genExpr(g.args[0]);
    const ch_t = try self.newTemp();
    const new_fn_name = if (is_thread_channel) "nox_threadchannel_new" else "nox_channel_new";
    try self.out.writer.print("    {s} =l call ${s}(l {s}, l {s})\n", .{ ch_t, new_fn_name, RT_PARAM, cap_val.text });

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
