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
const DictInfo = types.DictInfo;
const HeapKind = types.HeapKind;
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

/// Faz 17: `runtime/foreign_bridge.zig`nin `elem_kind`/`key_kind`/`value_kind`
/// kodlaması (0=int,1=float,2=bool,3=str) — bir skaler `QbeType`+`is_str`
/// çiftinden BU kod'un QBE İçİN metinsel (`w`-tipi immediate) temsili.
fn hpyElemKindLit(qtype: QbeType, is_str: bool) []const u8 {
    if (is_str) return "3";
    return switch (qtype) {
        .l => "0", // int
        .d => "1", // float
        .w, .b, .sb, .h, .sh => "2", // bool
        .none => "0",
    };
}

/// Faz 18 (bkz. plan dosyası "HPy köprüsünü Nox'un istisna mekanizmasına
/// entegre etme"): `genParseOrRaise`in (bkz. onun belge notu) AYNI err/
/// ok-etiket şablonu — `$nox_hpy_take_error`in dönüşü null-DIŞIYSA
/// (GERÇEK bir Nox `str`, hata metni) bir `HPyError` inşa edip `raise`
/// eder. HER `hpy_call`/`hpy_call_str`/`hpy_open`/`hpy_call_{on,str_on,
/// float_on,bool_on}` çağrısından HEMEN SONRA çağrılır.
///
/// `err_t` (fresh, PINNED OLMAYAN bir str) `genConstructFromValues`in
/// İÇİNDEKİ `__init__`in `self.message = message` atamasıyla (aliasing→
/// retain, bkz. `retainIfAliasing`) BAĞIMSIZ bir KOPYA daha kazanır — bu
/// YÜZDEN inşadan HEMEN SONRA `err_t`nin KENDİ (çağıranın) referansı
/// `nox_str_release` İLE bırakılır (`temp_release`in AST-BAĞIMLI
/// mekanizması BURADA kullanılamaz — `err_t`nin karşılık geldiği bir
/// `ast.Expr` YOK, bu YÜZDEN doğrudan, elle bir release ÇAĞRISI YAPILIR).
pub fn emitHpyErrorCheckOrRaise(self: *Codegen) CodegenError!void {
    const err_t = try self.newTemp();
    try self.qbeCall(.{ .name = err_t, .ty = .l }, "$nox_hpy_take_error", &.{.{ .ty = .l, .text = RT_PARAM }});
    const err_label = try self.newLabel("hpy_err");
    const ok_label = try self.newLabel("hpy_ok");
    try self.qbeJnz(err_t, err_label, ok_label);
    try self.qbeLabel(err_label);
    const he_cinfo = self.classes.get("HPyError") orelse return error.Unsupported;
    const msg_value: Value = .{ .text = err_t, .qtype = .l, .heap = .str };
    const he_obj = try self.genConstructFromValues("HPyError", he_cinfo, &.{msg_value}, null);
    try self.qbeCall(null, "$nox_str_release", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = err_t } });
    try self.emitExceptionLineStore(he_obj.text, "HPyError", self.current_raise_line);
    try self.qbeCall(null, "$nox_raise", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = he_obj.text }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{self.current_raise_line}) } });
    try self.emitRaisePropagate();
    try self.qbeLabel(ok_label);
}

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
        // v4 Faz A madde 4: `genCall`in AYNI bulgusu (bkz. onun belge
        // notu) — dolaylı (closure ÜZERİNDEN) çağrı yolu.
        return .{ .text = rt, .qtype = ret_qtype, .heap = fsig.ret.heap, .elem_qtype = fsig.ret.elem_qtype, .class_name = fsig.ret.class_name, .elem_heap_info = fsig.ret.elem_heap_info, .elem_is_str = fsig.ret.elem_is_str, .dict_info = fsig.ret.dict_info, .fixed_int = fsig.ret.fixed_int };
    }
    return .{ .text = "0", .qtype = .w };
}

/// Faz 21 (bkz. plan dosyası "modül-seviyesi tip inşası + GETSET + NOARGS
/// tip metodları"): `hpy_call_on`/vb.nin per-argüman marshal DÖNGÜSÜNÜN
/// PAYLAŞILAN gövdesi — Faz 17-19'un ORİJİNAL, tek-siteli implementasyonu,
/// `hpy_new_on`/`hpy_call_attr_on`nin İKİSİ de AYNI zinciri (`__nox_hpy_obj_arg`
/// işaretleyicisi DAHİL) İhtiyaç duyduğundan BURAYA ÇIKARILDI (davranış
/// DEĞİŞMEDEN, SAF bir kod-taşıma).
pub fn genHpyMarshalTrailingArgs(self: *Codegen, mc_temp: []const u8, trailing: []const ast.Expr) CodegenError!void {
    var arg_values: std.ArrayListUnmanaged(Value) = .empty;
    for (trailing) |arg_expr| {
        // Faz 19 (bkz. plan dosyası "opak HPy nesne tutamaçları"):
        // checker'ın `__nox_hpy_obj_arg` İŞARETLEYİCİSİ (`ptr`-
        // tipli argümanlar İçİn, `isHpyMarshalableArgType`nin
        // çağrıldığı yerdeki AST-rewrite) — İÇ ifadeyi normal
        // `genExpr` İLE değerlendirip `$nox_hpy_args_add_handle`e
        // YÖNLENDİRİR, AŞAĞIDAKİ `av.heap`/`av.qtype` dispatch'İNE
        // HİÇ GİRMEDEN (`ptr` codegen'de `int` İLE BİREBİR AYNI
        // temsile sahip OLDUĞUNDAN, o dala düşerse YANLIŞLIKLA
        // `nox_hpy_args_add_int` İLE marshal EDİLİRDİ).
        if (arg_expr == .call and arg_expr.call.callee.* == .identifier and std.mem.eql(u8, arg_expr.call.callee.identifier, "__nox_hpy_obj_arg")) {
            const inner_v = try self.genExpr(arg_expr.call.args[0]);
            try arg_values.append(self.allocator, inner_v);
            try self.qbeCall(null, "$nox_hpy_args_add_handle", &.{ .{ .ty = .l, .text = mc_temp }, .{ .ty = .l, .text = inner_v.text } });
            continue;
        }
        const av = try self.genExpr(arg_expr);
        try arg_values.append(self.allocator, av);
        switch (av.heap) {
            .str => try self.qbeCall(null, "$nox_hpy_args_add_str", &.{ .{ .ty = .l, .text = mc_temp }, .{ .ty = .l, .text = av.text } }),
            .list => {
                const elem_kind = hpyElemKindLit(av.elem_qtype, av.elem_is_str);
                try self.qbeCall(null, "$nox_hpy_args_add_list_scalar", &.{ .{ .ty = .l, .text = mc_temp }, .{ .ty = .l, .text = av.text }, .{ .ty = .w, .text = elem_kind } });
            },
            .dict => {
                const di = av.dict_info.?;
                const key_kind = hpyElemKindLit(di.key_qtype, di.key_is_str);
                const value_kind = hpyElemKindLit(di.value_qtype, di.value_is_str);
                try self.qbeCall(null, "$nox_hpy_args_add_dict_scalar", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = mc_temp }, .{ .ty = .l, .text = av.text }, .{ .ty = .w, .text = key_kind }, .{ .ty = .w, .text = value_kind } });
            },
            .class => {
                try self.qbeCall(null, "$nox_hpy_class_arg_begin", &.{.{ .ty = .l, .text = mc_temp }});
                const cinfo = self.classes.get(av.class_name.?).?;
                for (cinfo.fields.items) |f| {
                    const fv = try self.genFieldReadFromValue(av, f.name);
                    const fname_v = try self.emitStringLiteral(f.name);
                    const setter: []const u8 = switch (f.info.qtype) {
                        .l => if (f.info.heap == .str) "$nox_hpy_class_arg_set_str" else "$nox_hpy_class_arg_set_int",
                        .d => "$nox_hpy_class_arg_set_float",
                        .w => "$nox_hpy_class_arg_set_bool",
                        .none, .b, .sb, .h, .sh => return error.Unsupported,
                    };
                    try self.qbeCall(null, setter, &.{ .{ .ty = .l, .text = mc_temp }, .{ .ty = .l, .text = fname_v.text }, .{ .ty = f.info.qtype, .text = fv.text } });
                }
                try self.qbeCall(null, "$nox_hpy_class_arg_end", &.{.{ .ty = .l, .text = mc_temp }});
            },
            .none => switch (av.qtype) {
                .l => try self.qbeCall(null, "$nox_hpy_args_add_int", &.{ .{ .ty = .l, .text = mc_temp }, .{ .ty = .l, .text = av.text } }),
                .d => try self.qbeCall(null, "$nox_hpy_args_add_float", &.{ .{ .ty = .l, .text = mc_temp }, .{ .ty = .d, .text = av.text } }),
                .w => try self.qbeCall(null, "$nox_hpy_args_add_bool", &.{ .{ .ty = .l, .text = mc_temp }, .{ .ty = .w, .text = av.text } }),
                .none, .b, .sb, .h, .sh => return error.Unsupported,
            },
            else => return error.Unsupported,
        }
    }
    try self.releaseTemporaryArgs(trailing, arg_values.items);
}

/// Faz F.3: `ptr_from_int`/`ptr_to_int`/`ptr_add`/`ptr_read_int`/
/// `ptr_read_float`/`ptr_read_bool`/`ptr_write_int`/`ptr_write_float`/
/// `ptr_write_bool`/`detach`nin PAYLAŞILAN "yalnızca lowlevel: içinde"
/// isim-kümesi.
/// v2.0 madde 6 (bkz. plan dosyası §3): `ptr[T]`in stride'ı — `sizeof(T)`in
/// KENDİ formülüyle (bkz. bu dosyanın `sizeof`/`alignof` dalı) BİREBİR
/// AYNI: `T` HER ZAMAN statik olarak bilindiğinden ÇALIŞMA-zamanı
/// `sizeof()` çağrısı GEREKMEZ, DERLEME-zamanı bir SABİT döner.
pub fn typedPtrStride(self: *Codegen, p: Value) usize {
    if (p.elem_heap_info) |ehi| {
        if (ehi.heap == .class) return self.classes.get(ehi.class_name.?).?.total_size;
        return 8; // str/list/dict/closure — HER ZAMAN SADECE bir pointer
    }
    return abi.storageSizeOf(p.elem_qtype, p.elem_fixed_int);
}

/// v2.0 madde 6 (bkz. plan dosyası §4): skaler `T` İçİn `ptr_read` —
/// madde 5'in `narrowLoad`ını YENİDEN KULLANIR, AMA `layout_mode`i HER
/// ZAMAN `.packed_` GİBİ ele alır: `ptr[T]`nin ÇALIŞMA-zamanı adresi (bir
/// sınıf alanının offsetinin AKSİNE) HİÇBİR ZAMAN statik olarak hizalı
/// KANITLANAMAZ, bu YÜZDEN dar OLMAYAN genişlikler İçİn BİLE KOŞULSUZ
/// hizasız yükleme kullanılır.
pub fn genTypedPtrLoad(self: *Codegen, p: Value) CodegenError!Value {
    const ti = types.TypeInfo{ .qtype = p.elem_qtype, .fixed_int = p.elem_fixed_int };
    const dst = try self.newTemp();
    try self.narrowLoad(dst, ti, .packed_, p.text);
    return .{ .text = dst, .qtype = p.elem_qtype, .fixed_int = p.elem_fixed_int };
}

/// `genTypedPtrLoad`in yazma yönü — bkz. onun belge notu, AYNI gerekçe.
pub fn genTypedPtrStore(self: *Codegen, p: Value, v: Value) CodegenError!void {
    const ti = types.TypeInfo{ .qtype = p.elem_qtype, .fixed_int = p.elem_fixed_int };
    try self.narrowStore(v.text, ti, .packed_, p.text);
}

/// v2.0 madde 7 (bkz. plan dosyası §4): `ptr_read`/`ptr_read_volatile`
/// arasında PAYLAŞILAN `class` T dalı — `nox_raw_memcpy` ZATEN opak bir
/// FONKSİYON ÇAĞRISI olduğundan (ne Nox'un KENDİ codegen'i ne LLVM'in
/// optimize edicisi `readnone`/`pure` işaretlenmemiş bir çağrıyı ELEMEZ/
/// yeniden SIRALAMAZ), "volatile" BURADA HİÇBİR EK koda ihtiyaç DUYMAZ —
/// `ptr_read_volatile` bu fonksiyonu HARFİYEN AYNI şekilde çağırır.
pub fn genPtrClassCopyRead(self: *Codegen, p: Value, ehi: *const ElemHeapInfo) CodegenError!Value {
    const cinfo = self.classes.get(ehi.class_name.?).?;
    const stride_lit = try std.fmt.allocPrint(self.allocator, "{d}", .{cinfo.total_size});
    const new_ptr = try self.newTemp();
    try self.qbeCall(.{ .name = new_ptr, .ty = .l }, "$nox_rc_alloc", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = stride_lit } });
    try self.qbeCall(null, "$nox_raw_memcpy", &.{ .{ .ty = .l, .text = new_ptr }, .{ .ty = .l, .text = p.text }, .{ .ty = .l, .text = stride_lit } });
    for (cinfo.fields.items) |f| {
        if (!isHeapManaged(f.info.heap)) continue;
        const addr = try self.newTemp();
        try self.qbeOp2Imm(addr, .l, "add", new_ptr, @intCast(f.offset));
        const fv = try self.newTemp();
        try self.qbeLoad(fv, .l, .l, addr);
        try self.emitInlineRetain(fv, f.info.heap);
    }
    return .{ .text = new_ptr, .qtype = .l, .heap = .class, .class_name = ehi.class_name };
}

/// `genPtrClassCopyRead`in yazma yönü — bkz. onun belge notu, AYNI gerekçe.
pub fn genPtrClassCopyWrite(self: *Codegen, p: Value, v: Value, ehi: *const ElemHeapInfo) CodegenError!void {
    const cinfo = self.classes.get(ehi.class_name.?).?;
    const stride_lit = try std.fmt.allocPrint(self.allocator, "{d}", .{cinfo.total_size});
    try self.qbeCall(null, "$nox_raw_memcpy", &.{ .{ .ty = .l, .text = p.text }, .{ .ty = .l, .text = v.text }, .{ .ty = .l, .text = stride_lit } });
    for (cinfo.fields.items) |f| {
        if (!isHeapManaged(f.info.heap)) continue;
        const addr = try self.newTemp();
        try self.qbeOp2Imm(addr, .l, "add", p.text, @intCast(f.offset));
        const fv = try self.newTemp();
        try self.qbeLoad(fv, .l, .l, addr);
        try self.emitInlineRetain(fv, f.info.heap);
    }
}

/// v2.0 madde 7 (bkz. plan dosyası §3): `ptr_read_volatile`in skaler-T
/// yolu — `genTypedPtrLoad`in BİREBİR AYNISI, AMA `narrowLoad`
/// YERİNE `narrowLoadVolatile` çağırır (LLVM'de GERÇEK `load volatile`,
/// QBE'de `narrowLoad`dan AYIRT EDİLEMEZ — bkz. `qbeLoadVolatile`nin
/// belge notu).
pub fn genTypedPtrLoadVolatile(self: *Codegen, p: Value) CodegenError!Value {
    const ti = types.TypeInfo{ .qtype = p.elem_qtype, .fixed_int = p.elem_fixed_int };
    const dst = try self.newTemp();
    try self.narrowLoadVolatile(dst, ti, p.text);
    return .{ .text = dst, .qtype = p.elem_qtype, .fixed_int = p.elem_fixed_int };
}

/// `genTypedPtrLoadVolatile`in yazma yönü — bkz. onun belge notu.
pub fn genTypedPtrStoreVolatile(self: *Codegen, p: Value, v: Value) CodegenError!void {
    const ti = types.TypeInfo{ .qtype = p.elem_qtype, .fixed_int = p.elem_fixed_int };
    try self.narrowStoreVolatile(v.text, ti, p.text);
}

fn isPtrManualBuiltin(name: []const u8) bool {
    const names = [_][]const u8{ "ptr_from_int", "ptr_to_int", "ptr_add", "ptr_read_int", "ptr_read_float", "ptr_read_bool", "ptr_write_int", "ptr_write_float", "ptr_write_bool", "detach", "ptr_offset", "ptr_read", "ptr_write", "ptr_read_volatile", "ptr_write_volatile", "memory_fence", "compiler_fence" };
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Faz F.3: `checkNoLowlevelEscape`nin (ownership.zig) AYNI "codegen-
/// seviyesi kısıtlama, genel Unsupported mesajı" ilkesi — `self.in_
/// lowlevel_depth == 0` İSE (çağrı bir `lowlevel:` bloğunun DIŞINDA)
/// `main.zig`nin ZATEN karşıladığı genel, temiz bir hata mesajıyla
/// başarısız olur.
fn checkInsideLowlevel(self: *Codegen) CodegenError!void {
    if (self.in_lowlevel_depth == 0) return error.Unsupported;
}

pub fn genCall(self: *Codegen, c: ast.Call) CodegenError!Value {
    switch (c.callee.*) {
        .identifier => |name| {
            if (std.mem.eql(u8, name, "print")) {
                // v1.156.0: çok argümanlı / `sep=`/`end=` biçimleri ayrı yolda (tek argüman hızlı yolu aşağıda değişmedi).
                if (c.args.len != 1 or c.args[0] == .kwarg) return genPrintGeneral(self, c.args);
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
                } else if (v.heap == .dict) {
                    // v1.149.0: `len(d)` — `d.len()` ile aynı.
                    try self.qbeCall(.{ .name = result_t, .ty = .l }, "$nox_dict_len", &.{.{ .ty = .l, .text = v.text }});
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
                // v2.0 madde 4: sabit-genişlikli bir kind — `genPrint`in
                // AYNI widen+işaretlilik-farkında dallanmasi (bkz. onun
                // belge notu); `bool`in AŞAĞIDAKİ `.w`+`.heap==.none`
                // dalından ÖNCE kontrol edilmeli (u8/i8/u16/i16/u32/i32
                // de AYNI `.w` qtype'ı PAYLAŞIYOR).
                if (v.fixed_int) |kind| {
                    const widened = try self.widenFixedIntForPrint(v, kind);
                    const result_t = try self.newTemp();
                    if (kind.isSigned()) {
                        try self.qbeCall(.{ .name = result_t, .ty = .l }, "$nox_int_to_str", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = widened.text } });
                    } else {
                        try self.qbeCall(.{ .name = result_t, .ty = .l }, "$nox_uint_to_str", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = widened.text } });
                    }
                    return .{ .text = result_t, .qtype = .l, .heap = .str };
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
                // v1.151.0: sayısal kaynaklar ayrıştırmasız dönüştürülür; işaretsiz 64-bit (`u64`/`usize`) `ultof` ile.
                if (v.heap == .none) {
                    if (v.qtype == .d) return v;
                    if (v.fixed_int) |k| {
                        if (v.qtype == .l and !k.isSigned()) {
                            const t = try self.newTemp();
                            try self.qbeOp1(t, .d, "ultof", v.text);
                            return .{ .text = t, .qtype = .d };
                        }
                    }
                    return self.convert(v, .d);
                }
                const result = try self.genParseOrRaise(v, "nox_str_is_valid_float", "nox_str_to_float", .d, "float(): gecersiz sayi bicimi");
                try self.releaseIfTemporary(c.args[0], v);
                return result;
            }
            // v2.0 madde 4 (§4): `u8(x)`/`i32(x)`/vb. — DARALTMA cast'i,
            // checker'ın KENDİ eşdeğer notundaki gerekçeyle backend'DEN
            // BAĞIMSIZ HER ZAMAN aralık-kontrollü (bkz. `genNarrowingCast`).
            if (std.meta.stringToEnum(types.FixedIntKind, name)) |target_kind| {
                if (c.args.len != 1) return error.Unsupported;
                const v = try self.genExpr(c.args[0]);
                const result = try self.genNarrowingCast(v, target_kind);
                try self.releaseIfTemporary(c.args[0], v);
                return result;
            }
            // v2.0 madde 5: `sizeof(T)`/`alignof(T)`/`offsetof(T,
            // "field")` — ÜÇÜ de SAF derleme-zamanı SABİTİ, `genExpr`
            // çağrısı YOK (bir `int_lit`nin KENDİSİ GİBİ doğrudan bir
            // tamsayı literali Value'su üretilir, `.fixed_int = .usize`
            // İLE). `checker.zig` argüman şeklini/geçerliliğini ZATEN
            // doğruladı — burası SADECE sayıyı hesaplar.
            if (std.mem.eql(u8, name, "sizeof") or std.mem.eql(u8, name, "alignof")) {
                if (c.args.len != 1 or c.args[0] != .identifier) return error.Unsupported;
                const ti = try self.resolveType(.{ .simple = c.args[0].identifier });
                const n: usize = if (ti.heap == .class)
                    (if (std.mem.eql(u8, name, "sizeof")) self.classes.get(ti.class_name.?).?.total_size else 8)
                else
                    abi.storageSizeOf(ti.qtype, ti.fixed_int);
                return .{ .text = try std.fmt.allocPrint(self.allocator, "{d}", .{n}), .qtype = .l, .fixed_int = .usize };
            }
            if (std.mem.eql(u8, name, "offsetof")) {
                if (c.args.len != 2 or c.args[0] != .identifier or c.args[1] != .string_lit) return error.Unsupported;
                const cinfo = self.classes.get(c.args[0].identifier).?;
                for (cinfo.fields.items) |f| {
                    if (std.mem.eql(u8, f.name, c.args[1].string_lit)) {
                        return .{ .text = try std.fmt.allocPrint(self.allocator, "{d}", .{f.offset}), .qtype = .l, .fixed_int = .usize };
                    }
                }
                return error.Unsupported; // erişilemez: checker zaten doğruladı
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
                try self.emitHpyErrorCheckOrRaise();
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
                try self.emitHpyErrorCheckOrRaise();
                return .{ .text = result_temp, .qtype = .l, .heap = .str };
            }
            // Faz 16 (bkz. checker.zig'deki eşdeğer not): `hpy_call`in
            // kalıcı-tutamaçlı 4 kardeşi — `$nox_hpy_open`/`$nox_hpy_call_on`/
            // `$nox_hpy_call_str_on`/`$nox_hpy_close`e (bkz. runtime/
            // foreign_bridge.zig) DOĞRUDAN çağrıya çevrilir. `ptr` tutamacı
            // `int` İLE AYNI QBE temsiline (`l`) sahiptir (opak, ARC-yönetimli
            // DEĞİL — `hpy_call_str_on`nin dönüşü HARİÇ, o `hpy_call_str`İLE
            // AYNI gerekçeyle `.heap = .str` işaretlenir).
            if (std.mem.eql(u8, name, "hpy_open")) {
                if (c.args.len != 2) return error.Unsupported;
                const path_v = try self.genExpr(c.args[0]);
                const ext_v = try self.genExpr(c.args[1]);
                const result_temp = try self.newTemp();
                try self.qbeCall(.{ .name = result_temp, .ty = .l }, "$nox_hpy_open", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = path_v.text }, .{ .ty = .l, .text = ext_v.text } });
                try self.emitHpyErrorCheckOrRaise();
                return .{ .text = result_temp, .qtype = .l };
            }
            // Faz 17 (bkz. plan dosyası "kalıcı tutamaçlı HPy çağrılarına
            // çoklu-argüman + list/dict/class marshalling"): `hpy_call_on`/
            // `hpy_call_str_on`/`hpy_call_float_on`/`hpy_call_bool_on`
            // ARTIK `$nox_hpy_args_begin`+HER trailing argüman İçİn TİP-
            // BAŞINA bir `$nox_hpy_args_add_*`/`$nox_hpy_class_arg_*`
            // çağrısı+dönüş-tipine özel bir `$nox_hpy_call_*_finish`
            // ZİNCİRİNE çevrilir — checker `isHpyMarshalableArgType` İLE
            // HER argümanın MARSHAL EDİLEBİLİR olduğunu ZATEN kanıtladı,
            // bu YÜZDEN aşağıdaki `else => unreachable` dalları GÜVENLİDİR.
            if (std.mem.eql(u8, name, "hpy_call_on") or std.mem.eql(u8, name, "hpy_call_str_on") or std.mem.eql(u8, name, "hpy_call_float_on") or std.mem.eql(u8, name, "hpy_call_bool_on") or std.mem.eql(u8, name, "hpy_call_obj_on")) {
                if (c.args.len < 2) return error.Unsupported;
                const handle_v = try self.genExpr(c.args[0]);
                const func_v = try self.genExpr(c.args[1]);
                const mc_temp = try self.newTemp();
                try self.qbeCall(.{ .name = mc_temp, .ty = .l }, "$nox_hpy_args_begin", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = handle_v.text } });

                const trailing = c.args[2..];
                try self.genHpyMarshalTrailingArgs(mc_temp, trailing);

                const result_temp = try self.newTemp();
                if (std.mem.eql(u8, name, "hpy_call_on")) {
                    try self.qbeCall(.{ .name = result_temp, .ty = .l }, "$nox_hpy_call_int_finish", &.{ .{ .ty = .l, .text = mc_temp }, .{ .ty = .l, .text = func_v.text } });
                    try self.emitHpyErrorCheckOrRaise();
                    return .{ .text = result_temp, .qtype = .l };
                }
                if (std.mem.eql(u8, name, "hpy_call_float_on")) {
                    try self.qbeCall(.{ .name = result_temp, .ty = .d }, "$nox_hpy_call_float_finish", &.{ .{ .ty = .l, .text = mc_temp }, .{ .ty = .l, .text = func_v.text } });
                    try self.emitHpyErrorCheckOrRaise();
                    return .{ .text = result_temp, .qtype = .d };
                }
                if (std.mem.eql(u8, name, "hpy_call_bool_on")) {
                    try self.qbeCall(.{ .name = result_temp, .ty = .w }, "$nox_hpy_call_bool_finish", &.{ .{ .ty = .l, .text = mc_temp }, .{ .ty = .l, .text = func_v.text } });
                    try self.emitHpyErrorCheckOrRaise();
                    return .{ .text = result_temp, .qtype = .w };
                }
                if (std.mem.eql(u8, name, "hpy_call_obj_on")) {
                    try self.qbeCall(.{ .name = result_temp, .ty = .l }, "$nox_hpy_call_obj_finish", &.{ .{ .ty = .l, .text = mc_temp }, .{ .ty = .l, .text = func_v.text } });
                    try self.emitHpyErrorCheckOrRaise();
                    return .{ .text = result_temp, .qtype = .l };
                }
                try self.qbeCall(.{ .name = result_temp, .ty = .l }, "$nox_hpy_call_str_finish", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = mc_temp }, .{ .ty = .l, .text = func_v.text } });
                try self.emitHpyErrorCheckOrRaise();
                return .{ .text = result_temp, .qtype = .l, .heap = .str };
            }
            if (std.mem.eql(u8, name, "hpy_close")) {
                if (c.args.len != 1) return error.Unsupported;
                const handle_v = try self.genExpr(c.args[0]);
                try self.qbeCall(null, "$nox_hpy_close", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = handle_v.text } });
                return .{ .text = "0", .qtype = .w };
            }
            // Faz 19: `hpy_close_obj` — `hpy_call_obj_on`nin döndürdüğü opak
            // örnek tutamacını serbest bırakır.
            if (std.mem.eql(u8, name, "hpy_close_obj")) {
                if (c.args.len != 2) return error.Unsupported;
                const handle_v = try self.genExpr(c.args[0]);
                const obj_v = try self.genExpr(c.args[1]);
                try self.qbeCall(null, "$nox_hpy_close_obj", &.{ .{ .ty = .l, .text = handle_v.text }, .{ .ty = .l, .text = obj_v.text } });
                return .{ .text = "0", .qtype = .w };
            }
            // Faz 21 (bkz. plan dosyası "modül-seviyesi tip inşası + GETSET
            // + NOARGS tip metodları"): `hpy_new_on` — `hpy_call_on`nin AYNI
            // `$nox_hpy_args_begin`+marshal ZİNCİRİNİ paylaşır, SADECE
            // "finish" adımı FARKLI (`$nox_hpy_new_finish`, `GetAttr`+`Call`
            // İLE İNŞA eder), dönüş `ptr`.
            if (std.mem.eql(u8, name, "hpy_new_on")) {
                if (c.args.len < 2) return error.Unsupported;
                const handle_v = try self.genExpr(c.args[0]);
                const class_v = try self.genExpr(c.args[1]);
                const mc_temp = try self.newTemp();
                try self.qbeCall(.{ .name = mc_temp, .ty = .l }, "$nox_hpy_args_begin", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = handle_v.text } });
                try self.genHpyMarshalTrailingArgs(mc_temp, c.args[2..]);
                const result_temp = try self.newTemp();
                try self.qbeCall(.{ .name = result_temp, .ty = .l }, "$nox_hpy_new_finish", &.{ .{ .ty = .l, .text = mc_temp }, .{ .ty = .l, .text = class_v.text } });
                try self.emitHpyErrorCheckOrRaise();
                return .{ .text = result_temp, .qtype = .l };
            }
            // Faz 21: `hpy_getattr_int_on`/`hpy_setattr_int_on` — SABİT
            // arity, DOĞRUDAN çağrı (marshal zinciri GEREKMEZ).
            if (std.mem.eql(u8, name, "hpy_getattr_int_on")) {
                if (c.args.len != 3) return error.Unsupported;
                const handle_v = try self.genExpr(c.args[0]);
                const obj_v = try self.genExpr(c.args[1]);
                const attr_v = try self.genExpr(c.args[2]);
                const result_temp = try self.newTemp();
                try self.qbeCall(.{ .name = result_temp, .ty = .l }, "$nox_hpy_getattr_int", &.{ .{ .ty = .l, .text = handle_v.text }, .{ .ty = .l, .text = obj_v.text }, .{ .ty = .l, .text = attr_v.text } });
                try self.emitHpyErrorCheckOrRaise();
                return .{ .text = result_temp, .qtype = .l };
            }
            if (std.mem.eql(u8, name, "hpy_setattr_int_on")) {
                if (c.args.len != 4) return error.Unsupported;
                const handle_v = try self.genExpr(c.args[0]);
                const obj_v = try self.genExpr(c.args[1]);
                const attr_v = try self.genExpr(c.args[2]);
                const value_v = try self.genExpr(c.args[3]);
                try self.qbeCall(null, "$nox_hpy_setattr_int", &.{ .{ .ty = .l, .text = handle_v.text }, .{ .ty = .l, .text = obj_v.text }, .{ .ty = .l, .text = attr_v.text }, .{ .ty = .l, .text = value_v.text } });
                try self.emitHpyErrorCheckOrRaise();
                return .{ .text = "0", .qtype = .w };
            }
            // Faz 21: `hpy_call_attr_on` — `hpy_call_on`nin AYNI marshal
            // zincirini paylaşır, SADECE başlangıç (`$nox_hpy_args_begin_
            // for_obj`, `obj`i de hedef olarak taşır) VE bitiş (`$nox_hpy_
            // call_attr_int_finish`) FARKLI.
            if (std.mem.eql(u8, name, "hpy_call_attr_on")) {
                if (c.args.len < 3) return error.Unsupported;
                const handle_v = try self.genExpr(c.args[0]);
                const obj_v = try self.genExpr(c.args[1]);
                const attr_v = try self.genExpr(c.args[2]);
                const mc_temp = try self.newTemp();
                try self.qbeCall(.{ .name = mc_temp, .ty = .l }, "$nox_hpy_args_begin_for_obj", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = handle_v.text }, .{ .ty = .l, .text = obj_v.text } });
                try self.genHpyMarshalTrailingArgs(mc_temp, c.args[3..]);
                const result_temp = try self.newTemp();
                try self.qbeCall(.{ .name = result_temp, .ty = .l }, "$nox_hpy_call_attr_int_finish", &.{ .{ .ty = .l, .text = mc_temp }, .{ .ty = .l, .text = attr_v.text } });
                try self.emitHpyErrorCheckOrRaise();
                return .{ .text = result_temp, .qtype = .l };
            }
            // Faz 22 (bkz. plan dosyası "bare attribute-nesnesi + gerçek
            // slice tipi + numpy-tarzı skaler-broadcast slice ataması"):
            // `hpy_new_object_on`/`hpy_getitem_int_on` — İKİSİ de SABİT
            // arity, marshal zinciri GEREKMEZ, DOĞRUDAN çağrıya çevrilir.
            if (std.mem.eql(u8, name, "hpy_new_object_on")) {
                if (c.args.len != 1) return error.Unsupported;
                const handle_v = try self.genExpr(c.args[0]);
                const result_temp = try self.newTemp();
                try self.qbeCall(.{ .name = result_temp, .ty = .l }, "$nox_hpy_new_object", &.{.{ .ty = .l, .text = handle_v.text }});
                try self.emitHpyErrorCheckOrRaise();
                return .{ .text = result_temp, .qtype = .l };
            }
            if (std.mem.eql(u8, name, "hpy_getitem_int_on")) {
                if (c.args.len != 3) return error.Unsupported;
                const handle_v = try self.genExpr(c.args[0]);
                const obj_v = try self.genExpr(c.args[1]);
                const index_v = try self.genExpr(c.args[2]);
                const result_temp = try self.newTemp();
                try self.qbeCall(.{ .name = result_temp, .ty = .l }, "$nox_hpy_getitem_int", &.{ .{ .ty = .l, .text = handle_v.text }, .{ .ty = .l, .text = obj_v.text }, .{ .ty = .l, .text = index_v.text } });
                try self.emitHpyErrorCheckOrRaise();
                return .{ .text = result_temp, .qtype = .l };
            }
            // Faz 24 (bkz. plan dosyası "bellek-içi file-like writer/
            // reader nesneleri"): `hpy_new_string_writer_on`/`hpy_writer_
            // get_str_on`/`hpy_new_string_reader_on` — ÜÇÜ de SABİT arity,
            // marshal zinciri GEREKMEZ, DOĞRUDAN çağrıya çevrilir.
            if (std.mem.eql(u8, name, "hpy_new_string_writer_on")) {
                if (c.args.len != 1) return error.Unsupported;
                const handle_v = try self.genExpr(c.args[0]);
                const result_temp = try self.newTemp();
                try self.qbeCall(.{ .name = result_temp, .ty = .l }, "$nox_hpy_new_string_writer", &.{.{ .ty = .l, .text = handle_v.text }});
                try self.emitHpyErrorCheckOrRaise();
                return .{ .text = result_temp, .qtype = .l };
            }
            if (std.mem.eql(u8, name, "hpy_writer_get_str_on")) {
                if (c.args.len != 2) return error.Unsupported;
                const handle_v = try self.genExpr(c.args[0]);
                const writer_v = try self.genExpr(c.args[1]);
                const result_temp = try self.newTemp();
                try self.qbeCall(.{ .name = result_temp, .ty = .l }, "$nox_hpy_writer_get_str", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = handle_v.text }, .{ .ty = .l, .text = writer_v.text } });
                // Not: BU çağrı ASLA HPy hatası ÜRETMEZ (`hpy_close_obj`in
                // AYNI "sessiz" muamelesi) — `emitHpyErrorCheckOrRaise`
                // GEREKMEZ.
                return .{ .text = result_temp, .qtype = .l, .heap = .str };
            }
            if (std.mem.eql(u8, name, "hpy_new_string_reader_on")) {
                if (c.args.len != 2) return error.Unsupported;
                const handle_v = try self.genExpr(c.args[0]);
                const content_v = try self.genExpr(c.args[1]);
                const result_temp = try self.newTemp();
                try self.qbeCall(.{ .name = result_temp, .ty = .l }, "$nox_hpy_new_string_reader", &.{ .{ .ty = .l, .text = handle_v.text }, .{ .ty = .l, .text = content_v.text } });
                try self.releaseIfTemporary(c.args[1], content_v);
                try self.emitHpyErrorCheckOrRaise();
                return .{ .text = result_temp, .qtype = .l };
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
            // Faz B.5 + C.3: imza/constructor metadata yerleşikleri (hepsi
            // `(rt, int...)` → `l`; sonuç `str` olanlar pinned dizedir).
            // `uses_reflect_meta` bayrağı, `decorators.zig`nin tablo/erişimci
            // üretimini YALNIZCA bu yerleşikleri GERÇEKTEN çağıran programlarla
            // sınırlar (diğer programların IR'ı DEĞİŞMEZ).
            // Faz C.1b: `bound_method_fixup.zig`nin ürettiği `obj.ad` bağlama
            // çağrısı — alan İSE düz okuma, metod İSE bağlı closure.
            if (std.mem.eql(u8, name, "__nox_bind_method")) return genBindMethod(self, c);
            if (std.mem.eql(u8, name, "__nox_hash")) return genNoxHash(self, c);
            if (std.mem.eql(u8, name, "__nox_str_chars")) return genStrChars(self, c);
            if (reflectMetaResult(name)) |ret_is_str| {
                self.uses_reflect_meta = true;
                const arg_values = try self.allocator.alloc(codegen.QbeArg, 1 + c.args.len);
                arg_values[0] = .{ .ty = .l, .text = RT_PARAM };
                for (c.args, 0..) |arg, i| {
                    const v = try self.genExpr(arg);
                    arg_values[1 + i] = .{ .ty = .l, .text = v.text };
                }
                const result_temp = try self.newTemp();
                const sym = try std.fmt.allocPrint(self.allocator, "${s}", .{name});
                try self.qbeCall(.{ .name = result_temp, .ty = .l }, sym, arg_values);
                return if (ret_is_str) .{ .text = result_temp, .qtype = .l, .heap = .str } else .{ .text = result_temp, .qtype = .l };
            }
            // Faz A.6: `__nox_reflect_decorator_arg`in int/bool/string-listesi
            // eşdeğerleri — bkz. `decorators.zig`nin `genReflectDecoratorArgKind`/
            // `genReflectDecoratorArgInt`/`genReflectDecoratorArgBool`/
            // `genReflectDecoratorArgListLen`/`genReflectDecoratorArgListItem`si.
            if (std.mem.eql(u8, name, "__nox_reflect_decorator_arg_kind")) {
                if (c.args.len != 2) return error.Unsupported;
                const i_v = try self.genExpr(c.args[0]);
                const j_v = try self.genExpr(c.args[1]);
                const result_temp = try self.newTemp();
                try self.qbeCall(.{ .name = result_temp, .ty = .l }, "$__nox_reflect_decorator_arg_kind", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = i_v.text }, .{ .ty = .l, .text = j_v.text } });
                return .{ .text = result_temp, .qtype = .l };
            }
            if (std.mem.eql(u8, name, "__nox_reflect_decorator_arg_int")) {
                if (c.args.len != 2) return error.Unsupported;
                const i_v = try self.genExpr(c.args[0]);
                const j_v = try self.genExpr(c.args[1]);
                const result_temp = try self.newTemp();
                try self.qbeCall(.{ .name = result_temp, .ty = .l }, "$__nox_reflect_decorator_arg_int", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = i_v.text }, .{ .ty = .l, .text = j_v.text } });
                return .{ .text = result_temp, .qtype = .l };
            }
            if (std.mem.eql(u8, name, "__nox_reflect_decorator_arg_bool")) {
                if (c.args.len != 2) return error.Unsupported;
                const i_v = try self.genExpr(c.args[0]);
                const j_v = try self.genExpr(c.args[1]);
                const result_temp = try self.newTemp();
                try self.qbeCall(.{ .name = result_temp, .ty = .w }, "$__nox_reflect_decorator_arg_bool", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = i_v.text }, .{ .ty = .l, .text = j_v.text } });
                return .{ .text = result_temp, .qtype = .w };
            }
            if (std.mem.eql(u8, name, "__nox_reflect_decorator_arg_list_len")) {
                if (c.args.len != 2) return error.Unsupported;
                const i_v = try self.genExpr(c.args[0]);
                const j_v = try self.genExpr(c.args[1]);
                const result_temp = try self.newTemp();
                try self.qbeCall(.{ .name = result_temp, .ty = .l }, "$__nox_reflect_decorator_arg_list_len", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = i_v.text }, .{ .ty = .l, .text = j_v.text } });
                return .{ .text = result_temp, .qtype = .l };
            }
            if (std.mem.eql(u8, name, "__nox_reflect_decorator_arg_list_item")) {
                if (c.args.len != 3) return error.Unsupported;
                const i_v = try self.genExpr(c.args[0]);
                const j_v = try self.genExpr(c.args[1]);
                const k_v = try self.genExpr(c.args[2]);
                const result_temp = try self.newTemp();
                try self.qbeCall(.{ .name = result_temp, .ty = .l }, "$__nox_reflect_decorator_arg_list_item", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = i_v.text }, .{ .ty = .l, .text = j_v.text }, .{ .ty = .l, .text = k_v.text } });
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
            // Faz F.3 (bkz. plan dosyası "Dil uzantısı: 'lowlevel:'in
            // 'manuel katman'a genişletilmesi"): 9 yeni `ptr` aritmetiği/
            // okuma-yazma + `detach` yerleşiği — HEPSİ SADECE `lowlevel:`
            // İçİnde geçerli (checker bunu KONTROL ETMEZ, bkz. plan
            // dosyasının Context bölümü madde 2 — `checkInsideLowlevel`
            // TÜM 10 site TARAFINDAN paylaşılır). Codegen'i TAMAMEN
            // backend-SOYUTLANMIŞ `qbeOp2`/`qbeOp2Imm`/`qbeLoad`/`qbeStore`
            // emitter'larını KULLANIR — HEM QBE HEM LLVM'de SIFIR EK kod
            // İLE çalışır.
            if (isPtrManualBuiltin(name)) {
                try checkInsideLowlevel(self);
                if (std.mem.eql(u8, name, "ptr_from_int")) {
                    if (c.args.len != 1) return error.Unsupported;
                    const v = try self.genExpr(c.args[0]);
                    return .{ .text = v.text, .qtype = .l, .heap = .none };
                }
                if (std.mem.eql(u8, name, "ptr_to_int")) {
                    if (c.args.len != 1) return error.Unsupported;
                    const v = try self.genExpr(c.args[0]);
                    return .{ .text = v.text, .qtype = .l };
                }
                if (std.mem.eql(u8, name, "ptr_add")) {
                    if (c.args.len != 2) return error.Unsupported;
                    const p = try self.genExpr(c.args[0]);
                    const n = try self.genExpr(c.args[1]);
                    const result_temp = try self.newTemp();
                    try self.qbeOp2(result_temp, .l, "add", p.text, n.text);
                    return .{ .text = result_temp, .qtype = .l, .heap = .none };
                }
                if (std.mem.eql(u8, name, "ptr_read_int")) {
                    if (c.args.len != 1) return error.Unsupported;
                    const p = try self.genExpr(c.args[0]);
                    const result_temp = try self.newTemp();
                    try self.qbeLoad(result_temp, .l, .l, p.text);
                    return .{ .text = result_temp, .qtype = .l };
                }
                if (std.mem.eql(u8, name, "ptr_read_float")) {
                    if (c.args.len != 1) return error.Unsupported;
                    const p = try self.genExpr(c.args[0]);
                    const result_temp = try self.newTemp();
                    try self.qbeLoad(result_temp, .d, .d, p.text);
                    return .{ .text = result_temp, .qtype = .d };
                }
                if (std.mem.eql(u8, name, "ptr_read_bool")) {
                    if (c.args.len != 1) return error.Unsupported;
                    const p = try self.genExpr(c.args[0]);
                    const result_temp = try self.newTemp();
                    try self.qbeLoad(result_temp, .w, .w, p.text);
                    return .{ .text = result_temp, .qtype = .w };
                }
                if (std.mem.eql(u8, name, "ptr_write_int")) {
                    if (c.args.len != 2) return error.Unsupported;
                    const p = try self.genExpr(c.args[0]);
                    const v = try self.genExpr(c.args[1]);
                    try self.qbeStore(.l, v.text, p.text);
                    return .{ .text = "0", .qtype = .none };
                }
                if (std.mem.eql(u8, name, "ptr_write_float")) {
                    if (c.args.len != 2) return error.Unsupported;
                    const p = try self.genExpr(c.args[0]);
                    const v = try self.genExpr(c.args[1]);
                    try self.qbeStore(.d, v.text, p.text);
                    return .{ .text = "0", .qtype = .none };
                }
                if (std.mem.eql(u8, name, "ptr_write_bool")) {
                    if (c.args.len != 2) return error.Unsupported;
                    const p = try self.genExpr(c.args[0]);
                    const v = try self.genExpr(c.args[1]);
                    try self.qbeStore(.w, v.text, p.text);
                    return .{ .text = "0", .qtype = .none };
                }
                // v2.0 madde 6 (bkz. plan dosyası §3): `ptr_offset(p: ptr[T],
                // n: int) -> ptr[T]` — `sizeof(T)`e göre ÖLÇEKLENMİŞ, `T`
                // HER ZAMAN statik olarak bilindiğinden DERLEME-zamanı SABİTİ
                // bir çarpan (`typedPtrStride`, `sizeof`in KENDİ formülüyle
                // BİREBİR AYNI).
                if (std.mem.eql(u8, name, "ptr_offset")) {
                    if (c.args.len != 2) return error.Unsupported;
                    const p = try self.genExpr(c.args[0]);
                    const n = try self.genExpr(c.args[1]);
                    const stride = self.typedPtrStride(p);
                    const byte_off = try self.newTemp();
                    try self.qbeOp2Imm(byte_off, .l, "mul", n.text, @intCast(stride));
                    const new_addr = try self.newTemp();
                    try self.qbeOp2(new_addr, .l, "add", p.text, byte_off);
                    return .{ .text = new_addr, .qtype = .l, .heap = .typed_ptr, .elem_qtype = p.elem_qtype, .elem_heap_info = p.elem_heap_info, .elem_is_str = p.elem_is_str, .elem_fixed_int = p.elem_fixed_int };
                }
                // v2.0 madde 6 (bkz. plan dosyası §5): `ptr_read(p: ptr[T])
                // -> T`. Skaler `T` İçİn dar/hizasız yükleme
                // (`genTypedPtrLoad`). Heap-yönetimli `T` İçİn Model B:
                // sınıf-DIŞI (str/list/dict/closure, HER ZAMAN 8-baytlık
                // POINTER) "yükle + retain et"e (Model A'nın KENDİSİ)
                // KENDİLİĞİNDEN İNDİRGENİR; `class` T İçİn GERÇEK memcpy +
                // İÇ İÇE heap alanların retain-fixup'ı.
                if (std.mem.eql(u8, name, "ptr_read")) {
                    if (c.args.len != 1) return error.Unsupported;
                    const p = try self.genExpr(c.args[0]);
                    if (p.elem_heap_info) |ehi| {
                        if (ehi.heap == .class) return try self.genPtrClassCopyRead(p, ehi);
                        // Sınıf-DIŞI heap T (str/list/dict/closure) — stride
                        // HER ZAMAN 8 (SADECE bir pointer), bu YÜZDEN "T bayt
                        // kopyala" KENDİLİĞİNDEN Model A'ya (yükle+retain)
                        // İNDİRGENİR, AYRI bir memcpy GEREKMEZ.
                        const loaded = try self.newTemp();
                        try self.qbeLoadUnaligned(loaded, .l, .l, p.text);
                        try self.emitInlineRetain(loaded, ehi.heap);
                        return .{ .text = loaded, .qtype = .l, .heap = ehi.heap, .class_name = ehi.class_name, .elem_qtype = ehi.elem_qtype, .elem_heap_info = ehi.nested, .elem_is_str = ehi.elem_is_str, .dict_info = ehi.dict_info, .func_sig = ehi.func_sig };
                    }
                    return try self.genTypedPtrLoad(p);
                }
                // v2.0 madde 6: `ptr_write(p: ptr[T], v: T) -> None`. `v`
                // ÇAĞIRANIN sahipliğinde KALIR (normal alan-atamasının
                // "takma ad İSE retain et" deseni, `retainIfAliasing`) —
                // `*p`de ÖNCEDEN NE OLURSA OLSUN ASLA release EDİLMEZ (raw
                // bellek, GEÇMİŞİ BİLİNMİYOR — `detach`İLE AYNI güven sınırı).
                if (std.mem.eql(u8, name, "ptr_write")) {
                    if (c.args.len != 2) return error.Unsupported;
                    const p = try self.genExpr(c.args[0]);
                    const v = try self.genExpr(c.args[1]);
                    if (p.elem_heap_info) |ehi| {
                        if (ehi.heap == .class) {
                            try self.genPtrClassCopyWrite(p, v, ehi);
                        } else {
                            const retained_v = try self.retainIfAliasing(c.args[1], v);
                            try self.qbeStoreUnaligned(.l, retained_v.text, p.text);
                        }
                    } else {
                        try self.genTypedPtrStore(p, v);
                    }
                    return .{ .text = "0", .qtype = .none };
                }
                // v2.0 madde 7 (bkz. plan dosyası §4): `ptr_read_volatile`/
                // `ptr_write_volatile` — `ptr_read`/`ptr_write`nin BİREBİR
                // kopyası, SADECE İKİ noktada farklı: `class` T dalı AYNI
                // paylaşılan yardımcıyı (`genPtrClassCopyRead`/`Write`)
                // çağırır (`nox_raw_memcpy` ZATEN opak bir çağrı olduğundan
                // SIFIR fark), sınıf-DIŞI heap/skaler dallarda İSE
                // `qbeLoadUnaligned`/`qbeStoreUnaligned`/`genTypedPtrLoad`/
                // `genTypedPtrStore` YERİNE `qbeLoadVolatile`/
                // `qbeStoreVolatile`/`genTypedPtrLoadVolatile`/
                // `genTypedPtrStoreVolatile` kullanılır.
                if (std.mem.eql(u8, name, "ptr_read_volatile")) {
                    if (c.args.len != 1) return error.Unsupported;
                    const p = try self.genExpr(c.args[0]);
                    if (p.elem_heap_info) |ehi| {
                        if (ehi.heap == .class) return try self.genPtrClassCopyRead(p, ehi);
                        const loaded = try self.newTemp();
                        try self.qbeLoadVolatile(loaded, .l, .l, p.text);
                        try self.emitInlineRetain(loaded, ehi.heap);
                        return .{ .text = loaded, .qtype = .l, .heap = ehi.heap, .class_name = ehi.class_name, .elem_qtype = ehi.elem_qtype, .elem_heap_info = ehi.nested, .elem_is_str = ehi.elem_is_str, .dict_info = ehi.dict_info, .func_sig = ehi.func_sig };
                    }
                    return try self.genTypedPtrLoadVolatile(p);
                }
                if (std.mem.eql(u8, name, "ptr_write_volatile")) {
                    if (c.args.len != 2) return error.Unsupported;
                    const p = try self.genExpr(c.args[0]);
                    const v = try self.genExpr(c.args[1]);
                    if (p.elem_heap_info) |ehi| {
                        if (ehi.heap == .class) {
                            try self.genPtrClassCopyWrite(p, v, ehi);
                        } else {
                            const retained_v = try self.retainIfAliasing(c.args[1], v);
                            try self.qbeStoreVolatile(.l, retained_v.text, p.text);
                        }
                    } else {
                        try self.genTypedPtrStoreVolatile(p, v);
                    }
                    return .{ .text = "0", .qtype = .none };
                }
                // v2.0 madde 7 (bkz. plan dosyası §2): `memory_fence()`/
                // `compiler_fence()` — HER İKİSİ de argümansız, dönüş
                // DEĞERSİZ. Backend-farklılığı TAMAMEN `qbeMemoryFence`/
                // `qbeCompilerFence`in KENDİ dispatch'İNE bırakılır (bkz.
                // codegen.zig).
                if (std.mem.eql(u8, name, "memory_fence")) {
                    if (c.args.len != 0) return error.Unsupported;
                    try self.qbeMemoryFence();
                    return .{ .text = "0", .qtype = .none };
                }
                if (std.mem.eql(u8, name, "compiler_fence")) {
                    if (c.args.len != 0) return error.Unsupported;
                    try self.qbeCompilerFence();
                    return .{ .text = "0", .qtype = .none };
                }
                // `detach(x) -> ptr` — `x` çıplak bir isim OLMAK ZORUNDADIR
                // (checker ZATEN GARANTİ ETTİ). `self.vars.getPtr(name)` İLE
                // BULUNAN `VarInfo`ye `manual = true` YAZILIR (KALICI
                // release-atlama, bkz. `VarInfo.manual`'ın belge notu) —
                // bir PARAMETRE (`entry.is_param`) DETACH EDİLEMEZ (çağıran
                // taraf ZATEN o değerin sahibi/serbest bırakma sorumlusudur).
                if (std.mem.eql(u8, name, "detach")) {
                    if (c.args.len != 1 or c.args[0] != .identifier) return error.Unsupported;
                    const var_name = c.args[0].identifier;
                    const entry = self.vars.getPtr(var_name) orelse return error.Unsupported;
                    if (entry.is_param) return error.Unsupported;
                    entry.manual = true;
                    const t = try self.newTemp();
                    try self.qbeLoad(t, entry.qtype, entry.qtype, entry.slot);
                    return .{ .text = t, .qtype = .l, .heap = .none };
                }
                unreachable;
            }
            // `adopt(p)`nin BAĞLAMSIZ (bir hedef-tipli çağrı-siteSİNDEN
            // GEÇMEDEN, ör. `print(adopt(p))`) BURAYA ulaşması — checker'ın
            // `UnknownType`i BU durumu ZATEN DERLEME-ZAMANINDA elediğinden,
            // BU dal YALNIZCA savunmacı bir GÜVENLİK AĞIdır.
            if (std.mem.eql(u8, name, "adopt")) {
                return error.Unsupported;
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
                } else if (self.arena_local_construct_sites.get(@intFromPtr(c.callee))) |handle| {
                    // GG.19: `classifyVarDecl`nin sınıflar İçİn YENİ arena-
                    // fallback'i (boyut/aggregate-bütçe AŞAN AMA escape-
                    // güvenli bir sınıf örneği) — bkz. `genConstructFromValues`nin
                    // `pending_arena_handle` tüketimi.
                    self.pending_arena_handle = handle;
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
                // v2.0 madde 2.3 (bkz. nox-teknik-spesifikasyon.md §3.189):
                // `@ffi.callback` taşıyan bir extern def — `context_idx`
                // yuvası ÇAĞRI SİTESİNDE (checker TARAFINDAN ZATEN
                // doğrulanmış) HİÇ YAZILMAZ, derleyici `%rt`yi OTOMATİK
                // doldurur; `param_idx` yuvasındaki argüman (checker'ın
                // `checkCallbackTargetArg`ı TARAFINDAN ZATEN bare bir üst-
                // düzey fonksiyon adı OLDUĞU doğrulanmış) NORMAL OLARAK
                // `genExpr` İLE DEĞERLENDİRİLMEZ — bunun yerine ZATEN
                // üretilmiş (bkz. `codegen.zig`nin `callback_targets`
                // geçişi) `$<isim>__cbtramp` trampoline SEMBOLÜNÜN adresi
                // doğrudan (derleme-anı sabiti) argüman olarak geçirilir.
                if (esig.callback) |cb| {
                    if (esig.params.len != c.args.len + 1) return error.Unsupported;
                    const arg_values = try self.allocator.alloc(Value, esig.params.len);
                    // `releaseTemporaryArgs` `exprs`/`values`i POZİSYONEL
                    // olarak eşleştirir (bkz. onun belge notu) — bu YÜZDEN
                    // `context_idx`/`param_idx` yuvaları İçİn de (ASLA heap-
                    // yönetimli OLMAYACAKLARINDAN — `isHeapManaged` KISA-
                    // DEVRE yapar, `release_exprs`teki İçERİK ÖNEMSİZDİR)
                    // AYNI UZUNLUKTA bir dizi GEREKİR; `c.args[0]` (checker'ın
                    // `registerExternCallback`ı `param_idx != context_idx`ı
                    // ZATEN doğruladığından `ed.params.len >= 2`, dolayısıyla
                    // `c.args.len >= 1` HER ZAMAN GARANTİDİR) ZARARSIZ bir
                    // dolgu DEĞERİDİR.
                    const release_exprs = try self.allocator.alloc(ast.Expr, esig.params.len);
                    var arg_i: usize = 0;
                    for (esig.params, 0..) |p, pi| {
                        if (pi == cb.context_idx) {
                            arg_values[pi] = .{ .text = RT_PARAM, .qtype = .l };
                            release_exprs[pi] = c.args[0];
                            continue;
                        }
                        if (pi == cb.param_idx) {
                            const target_name = c.args[arg_i].identifier;
                            arg_i += 1;
                            const tramp_sym = try std.fmt.allocPrint(self.allocator, "${s}__cbtramp", .{target_name});
                            arg_values[pi] = .{ .text = tramp_sym, .qtype = .l };
                            release_exprs[pi] = c.args[0];
                            continue;
                        }
                        const v0 = try self.genExpr(c.args[arg_i]);
                        try self.checkNoLowlevelEscape(v0);
                        arg_values[pi] = try self.convert(v0, p.qtype);
                        release_exprs[pi] = c.args[arg_i];
                        arg_i += 1;
                    }
                    return try self.genExternCallEmit(name, esig, arg_values, release_exprs);
                }
                if (esig.params.len != c.args.len) return error.Unsupported;
                const arg_values = try self.allocator.alloc(Value, c.args.len);
                for (c.args, 0..) |a, i| {
                    const v0 = try self.genExpr(a);
                    try self.checkNoLowlevelEscape(v0);
                    arg_values[i] = try self.convert(v0, esig.params[i].qtype);
                }
                return try self.genExternCallEmit(name, esig, arg_values, c.args);
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
                // v4 Faz A madde 4 (bkz. nox-teknik-spesifikasyon.md
                // §3.2xx): GERÇEK, önceden keşfedilmemiş bir hata — bu
                // struct-literal `sig.ret.fixed_int`i HİÇ KOPYALAMIYORDU,
                // `Value.fixed_int`in VARSAYILAN DEĞERİNE (`null`) SESSİZCE
                // düşüyordu. Sonuç: `def f() -> u8: ...` GİBİ bir fonksiyonun
                // dönüşü DOĞRUDAN kullanıldığında (ör. `print(f())`, bir
                // DEĞİŞKENE ATANMADAN) `genPrint`in `.w`+`fixed_int==null`
                // deseni (SIRADAN bir `bool`la ÇAKIŞTIĞINDAN, bkz. §3.199'un
                // AYNI kategorideki bulgusu) SESSİZCE "True"/"False"
                // BASIYORDU — `x: u8 = f(); print(x)` İSE ÇALIŞIYORDU
                // (`x`in KENDİ değişken slotu fixed_int'i AYRICA taşır).
                // `nox.bits`nin (bu madde) `print(nox.bits.rotl_u8(...))`
                // GİBİ ÇAĞRILARI GERÇEKTEN denenip YAKALANDI.
                return .{ .text = rt, .qtype = sig.ret.qtype, .heap = sig.ret.heap, .elem_qtype = sig.ret.elem_qtype, .class_name = sig.ret.class_name, .elem_heap_info = sig.ret.elem_heap_info, .elem_is_str = sig.ret.elem_is_str, .dict_info = sig.ret.dict_info, .fixed_int = sig.ret.fixed_int };
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
                    .pool_run => self.genPoolRunExpr(c),
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
    try self.emitExceptionLineStore(ve_obj.text, "ValueError", self.current_raise_line);
    try self.qbeCall(null, "$nox_raise", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ve_obj.text }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{self.current_raise_line}) } });
    try self.emitRaisePropagate();

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
/// `genCall`in `extern def` dalının (bkz. onun belge notu, nox-teknik-
/// spesifikasyon.md §3.20) ORTAK kuyruğu — argümanlar ZATEN `arg_values`e
/// (esig.params İLE İNDEKS-hizalı) değerlendirilmiş/dönüştürülmüştür.
/// `release_exprs`, `releaseTemporaryArgs`in POZİSYONEL eşleştirmesi İçİn
/// `arg_values` İLE AYNI UZUNLUKTA/hizada bir ifade dizisidir (v2.0 madde
/// 2.3'ün `@ffi.callback` yolunda `c.args`tan FARKLI olabilir — context/
/// callback yuvaları İçİn ZARARSIZ bir dolgu taşır, bkz. çağıranın belge
/// notu).
pub fn genExternCallEmit(self: *Codegen, name: []const u8, esig: types.FuncSig, arg_values: []const Value, release_exprs: []const ast.Expr) CodegenError!Value {
    const result_temp: ?[]const u8 = if (esig.ret.qtype == .none) null else try self.newTemp();
    // `with_rt` (bkz. `ast.ExternDef.needs_rt`in belge notu, stdlib fazı
    // §D.1): `RT_PARAM` GİZLİCE argüman listesinin BAŞINA eklenir (normal
    // fonksiyon çağrılarıyla AYNI kalıp) — Zig tarafının İLK parametresi
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
    // Faz FFI.1 (bkz. nox-teknik-spesifikasyon.md §3.146): extern def
    // çağrısı da GEÇİCİ (taze/fresh) bir str/list/dict/class argümanının
    // refcount'unu ÇAĞRI SONRASI DOĞRU dengeler (`releaseTemporaryArgs`in
    // KENDİ `is_pinned`/`is_stack_slot`/`always_fresh`/`isTemporaryExpr`
    // korumaları OLDUĞU GİBİ devreye girer). Sıralama ÖNEMSİZ: extern def
    // `emitExceptionCheck` HİÇ ÇAĞIRMAZ, dönüş-değeri paketleme SADECE
    // `esig.ret.*` alanlarını okur, `arg_values`a HİÇ dokunmaz.
    try self.releaseTemporaryArgs(release_exprs, arg_values);
    // Stdlib fazı §F/§L, Faz FF.3: `elem_qtype`/`elem_heap_info`/
    // `elem_is_str`/`class_name`/`dict_info` — dönen `list[str]`/sınıf/
    // `dict[K,V]` değerlerinin doğru ARC izlenmesi İçİn GEREKLİ (bkz. git
    // geçmişinin AYNI notu).
    if (result_temp) |rt| return .{ .text = rt, .qtype = esig.ret.qtype, .heap = esig.ret.heap, .class_name = esig.ret.class_name, .elem_qtype = esig.ret.elem_qtype, .elem_heap_info = esig.ret.elem_heap_info, .elem_is_str = esig.ret.elem_is_str, .dict_info = esig.ret.dict_info };
    return .{ .text = "0", .qtype = .w };
}

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
    // GG.19 (bkz. plan dosyası "ASAP güçlendirmesi — Tur 3"): `genCall`in
    // `.identifier` dalı, BU inşa sitesini `arena_local_construct_sites`de
    // (`classifyVarDecl`nin sınıflar İçİn YENİ arena-fallback'i — boyut/
    // aggregate-bütçe AŞAN AMA escape-güvenli bir sınıf örneği) BULURSA
    // `self.pending_arena_handle`i GEÇİCİ olarak İŞARETLER — `currentArena()`
    // (`lowlevel:` kapsamı) İLE KARIŞTIRILMAZ, TAMAMEN AYRI bir kanal.
    var growable_arena: ?[]const u8 = null;
    const t: []const u8 = blk: {
        if (self.pending_stack_slot) |slot| {
            self.pending_stack_slot = null;
            break :blk slot;
        }
        if (self.pending_arena_handle) |ap| {
            self.pending_arena_handle = null;
            growable_arena = ap;
            const temp = try self.newTemp();
            try self.qbeCall(.{ .name = temp, .ty = .l }, "$nox_arena_alloc", &.{ .{ .ty = .l, .text = ap }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{cinfo.total_size}) } });
            break :blk temp;
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
        if (cinfo.layout_mode == .default) {
            // `default` mod DEĞİŞMEDEN: HER alan zaten 8-baytlık bir slot
            // (KOŞULSUZ `storel 0` — bir `float` alanı İçİn BİLE GEÇERLİ,
            // çünkü IEEE754 `0.0`nın bit örüntüsü TÜM-SIFIR, `int`in
            // sıfırıyla AYNI).
            try self.qbeStoreImmL(0, addr);
        } else {
            // v2.0 madde 5: **GERÇEK, ÇALIŞTIRILMADAN ÖNCE bulunan hata**
            // — `@packed`/`@repr("C")` bir sınıfın SON alanı 8 bayttan
            // DARSA (ör. tek bir `u8`), KOŞULSUZ 8-baytlık `storel 0`
            // `total_size`i AŞIP `nox_rc_alloc`/`nox_arena_alloc`in
            // AYIRDIĞI bellek bloğundan TAŞARDI (yığın bozulması). BURADA
            // SADECE alanın KENDİ GERÇEK genişliği kadar sıfırlanır —
            // BİT ÖRÜNTÜSÜ (0) her tip İçİn (int/float/bool/pointer) AYNI
            // olduğundan `qtype` yerine SADECE genişliğe göre dallanmak
            // yeterlidir.
            const width = abi.storageSizeOf(f.info.qtype, f.info.fixed_int);
            switch (width) {
                1 => try self.qbeStoreB("0", addr),
                2 => try self.qbeStoreH("0", addr),
                4 => try self.qbeStore(.w, "0", addr),
                8 => try self.qbeStoreImmL(0, addr),
                else => unreachable,
            }
        }
    }
    // `has_init == false`: sınıfın hiç `__init__`i yok (bkz.
    // `ClassInfo.has_init`in belge notu) — `generateModule` bu sınıf için
    // `$ClassName___init__`i HİÇ ÜRETMEDİ, bu yüzden burada çağırmak
    // bağlantı zamanında çözülemeyen bir sembole yol açardı. Faz 7: bu
    // sınıfın KENDİ `__init__`i yoksa (taban sınıftan MİRAS alındı)
    // `cinfo.init_owner` GERÇEK implementasyonu TAŞIYAN sınıfa işaret
    // eder — `class_name`in KENDİSİ DEĞİL (o sembol HİÇ ÜRETİLMEZ).
    if (cinfo.has_init and cinfo.simple_init_ok and temp_release != null and std.mem.eql(u8, cinfo.init_owner.?, class_name)) {
        // v1.142.15 "basit `__init__`" satır içi açma: gövde yalnızca `self.alan = parametre`/literal
        // atamalarından oluştuğundan çağrı + retain/release çifti + istisna kontrolü yerine alan
        // depolamaları DOĞRUDAN burada yazılır. Argüman ifadesi taze ise sahiplik alana TAŞINIR
        // (retain/release yok); değilse `retainIfAliasing` retain eder — `self.alan = arg_ifadesi`
        // atamasıyla BİREBİR aynı kurallar.
        const tr = temp_release.?;
        const consumed = try self.allocator.alloc(bool, arg_values.len);
        @memset(consumed, false);
        for (cinfo.simple_init) |st| {
            var fld: ?types.ClassField = null;
            for (cinfo.fields.items) |f| {
                if (std.mem.eql(u8, f.name, st.field)) fld = f;
            }
            const f = fld orelse return error.Unsupported;
            const addr = try self.newTemp();
            try self.qbeOp2Imm(addr, .l, "add", t, @intCast(f.offset));
            if (st.param_index) |pi| {
                const retained = try self.retainIfAliasing(tr.exprs[pi], arg_values[pi]);
                const val = try self.convert(retained, f.info.qtype);
                try self.qbeStore(f.info.qtype, val.text, addr);
                consumed[pi] = true;
            } else if (st.literal) |lit| {
                const lv = try self.genExprForTarget(lit, f.info);
                const val = try self.convert(lv, f.info.qtype);
                try self.qbeStore(f.info.qtype, val.text, addr);
            }
        }
        // Tüketilmeyen (kullanılmayan parametreli) taze argümanlar normal şekilde serbest bırakılır.
        var rel_exprs: std.ArrayListUnmanaged(ast.Expr) = .empty;
        var rel_values: std.ArrayListUnmanaged(Value) = .empty;
        for (tr.exprs, 0..) |e, i| {
            if (consumed[i]) continue;
            try rel_exprs.append(self.allocator, e);
            try rel_values.append(self.allocator, tr.values[i]);
        }
        try self.releaseTemporaryArgs(rel_exprs.items, rel_values.items);
    } else if (cinfo.has_init) {
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
            if (arena == null and growable_arena == null) {
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
    return .{ .text = t, .qtype = .l, .heap = .class, .class_name = class_name, .arena = arena != null or growable_arena != null, .growable_arena = growable_arena };
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

/// Faz B.5 + C.3: `name` bir imza/constructor metadata yerleşiği İSE
/// dönüşün `str` olup olmadığını (`true` = pinned `str`, `false` = `int`),
/// DEĞİLSE `null` döner. Checker'ın `checkReflectMetaIntrinsic` tablosuyla
/// AYNI küme.
fn reflectMetaResult(name: []const u8) ?bool {
    const Entry = struct { name: []const u8, is_str: bool };
    const table = [_]Entry{
        .{ .name = "__nox_reflect_decorator_param_count", .is_str = false },
        .{ .name = "__nox_reflect_decorator_param_name", .is_str = true },
        .{ .name = "__nox_reflect_decorator_param_type", .is_str = true },
        .{ .name = "__nox_reflect_decorator_return_type", .is_str = true },
        .{ .name = "__nox_reflect_decorator_kind", .is_str = false },
        .{ .name = "__nox_reflect_decorator_owner", .is_str = true },
        .{ .name = "__nox_reflect_class_count", .is_str = false },
        .{ .name = "__nox_reflect_class_name", .is_str = true },
        .{ .name = "__nox_reflect_class_init_param_count", .is_str = false },
        .{ .name = "__nox_reflect_class_init_param_name", .is_str = true },
        .{ .name = "__nox_reflect_class_init_param_type", .is_str = true },
    };
    for (table) |e| {
        if (std.mem.eql(u8, name, e.name)) return e.is_str;
    }
    return null;
}

/// v1.142.20: `__nox_hash(x)` — dahili karma ilkeli (bkz. checker'daki aynı ad). `str` → `nox_hash_str`,
/// `int`/`bool`/sabit-genişlikli → `nox_hash_int`, `float` → `nox_hash_float`; heap-yönetimli diğer
/// tipler (sınıf/liste/dict/...) için sabit 0 (`Set[Point]` gibi kullanımlar doğrusal ama DOĞRU kalır).
/// `__nox_str_chars(s)` (v1.148.0, `for c in s` yeniden yazımı): `$nox_str_chars` — `list[str]`.
fn genStrChars(self: *Codegen, c: ast.Call) CodegenError!Value {
    if (c.args.len != 1) return error.Unsupported;
    const v = try self.genExpr(c.args[0]);
    try self.checkNoLowlevelEscape(v);
    const result = try self.newTemp();
    try self.qbeCall(.{ .name = result, .ty = .l }, "$nox_str_chars", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = v.text } });
    try self.releaseIfTemporary(c.args[0], v);
    const info = try self.allocator.create(ElemHeapInfo);
    info.* = .{ .heap = .str };
    return .{ .text = result, .qtype = .l, .heap = .list, .elem_qtype = .l, .elem_heap_info = info, .elem_is_str = true };
}

fn genNoxHash(self: *Codegen, c: ast.Call) CodegenError!Value {
    if (c.args.len != 1) return error.Unsupported;
    const v = try self.genExpr(c.args[0]);
    const result = try self.newTemp();
    if (v.heap == .str) {
        try self.qbeCall(.{ .name = result, .ty = .l }, "$nox_hash_str", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = v.text } });
    } else if (v.heap == .none and v.qtype == .d) {
        try self.qbeCall(.{ .name = result, .ty = .l }, "$nox_hash_float", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .d, .text = v.text } });
    } else if (v.heap == .none and (v.qtype == .l or v.qtype == .w)) {
        var lv_text: []const u8 = v.text;
        if (v.qtype == .w) {
            // bool / 32-bit-ve-altı sabit-genişlikli: sıfır-genişletme (eşit değer ⇒ eşit karma)
            const ext = try self.newTemp();
            try self.qbeOp1(ext, .l, "extuw", v.text);
            lv_text = ext;
        }
        try self.qbeCall(.{ .name = result, .ty = .l }, "$nox_hash_int", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = lv_text } });
    } else {
        try self.qbeOp1(result, .l, "copy", "0");
    }
    try self.releaseIfTemporary(c.args[0], v);
    return .{ .text = result, .qtype = .l };
}

/// Faz C.1b (bkz. `bound_method_fixup.zig`): `__nox_bind_method(obj, "ad")`.
/// `ad` obj'nin sınıfında bir ALAN İSE normal `obj.ad` okumasının AYNISI
/// (`genExpr(.attribute)`) — AMA bu bir `.call` olarak göründüğünden
/// çağıran sonucu TAZE sayıp RETAIN ETMEZ, bu yüzden retain BURADA yapılır
/// (`retainIfAliasing`, `var_decl x = obj.ad`nin AYNI kuralı). `ad` bir
/// METOD İSE: alıcı RETAIN edilip `{fn_ptr, release_fn, self}` bir closure
/// bloğuna yakalanır; trampoline (`genBoundMethodTrampoline`) (statik sınıf,
/// metod) çifti BAŞINA TEK, TEMBEL üretilir. `always_fresh`: blok HİÇBİR
/// mevcut şeyi aliaslamaz (bkz. `buildFunctionValueForIdentifier`in AYNI
/// notu).
fn genBindMethod(self: *Codegen, c: ast.Call) CodegenError!Value {
    if (c.args.len != 2 or c.args[1] != .string_lit) return error.Unsupported;
    const attr = c.args[1].string_lit;
    const obj = try self.genExpr(c.args[0]);
    if (obj.heap != .class or obj.class_name == null) return error.Unsupported;
    const class_name = obj.class_name.?;
    const cinfo = self.classes.get(class_name) orelse return error.Unsupported;
    for (cinfo.fields.items) |f| {
        if (std.mem.eql(u8, f.name, attr)) {
            const attr_expr: ast.Expr = .{ .attribute = .{ .obj = &c.args[0], .attr = attr } };
            const fv = try self.genExpr(attr_expr);
            return self.retainIfAliasing(attr_expr, fv);
        }
    }
    const msig = cinfo.methods.get(attr) orelse return error.Unsupported;
    try self.checkNoLowlevelEscape(obj);

    const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ class_name, attr });
    if (!self.bound_method_seen.contains(key)) {
        try self.bound_method_seen.put(self.allocator, key, {});
        try self.bound_method_specs.append(self.allocator, .{
            .class_name = class_name,
            .method = attr,
            .owner = msig.owner,
            .slot = msig.slot,
            .has_vtable = cinfo.has_vtable,
            .sig = msig.sig,
        });
    }
    const base = try std.fmt.allocPrint(self.allocator, "{s}_{s}__bound", .{ class_name, attr });
    const block = try self.newTemp();
    const total = types.CLOSURE_HEADER_SIZE + 8;
    try self.qbeCall(.{ .name = block, .ty = .l }, "$nox_rc_alloc", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{total}) } });
    try self.qbeStoreL(try std.fmt.allocPrint(self.allocator, "${s}", .{base}), block);
    const rel_addr = try self.newTemp();
    try self.qbeOp2Imm(rel_addr, .l, "add", block, @intCast(types.CLOSURE_RELEASE_FN_PTR_OFFSET));
    try self.qbeStoreL(try std.fmt.allocPrint(self.allocator, "${s}_release", .{base}), rel_addr);
    const self_slot = try self.newTemp();
    try self.qbeOp2Imm(self_slot, .l, "add", block, @intCast(types.CLOSURE_HEADER_SIZE));
    try self.emitInlineRetain(obj.text, .class);
    try self.qbeStoreL(obj.text, self_slot);

    const fsig = try self.allocator.create(FuncSigInfo);
    fsig.* = .{ .params = msig.sig.params, .ret = msig.sig.ret };
    return .{ .text = block, .qtype = .l, .heap = .closure, .func_sig = fsig, .always_fresh = true };
}

pub fn genMethodCall(self: *Codegen, a: ast.Attribute, args: []const ast.Expr) CodegenError!Value {
    if (isSuperCallExpr(a.obj.*)) return self.genSuperMethodCall(a, args);
    const obj = try self.genExpr(a.obj.*);
    if (obj.heap == .str) return genStrMethod(self, obj, a, args);
    if (obj.heap == .dict) return self.genDictMethod(obj, a, args);
    if (obj.heap == .list) {
        // Faz EE.1 (bkz. nox-teknik-spesifikasyon.md §3.61): checker
        // ZATEN `a.attr`in `append`/`sort`den biri OLDUĞUNU doğruladı
        // (bkz. checker.zig'in `.list` dalı) — codegen İSİM üzerinden
        // dispatch eder (`genListAppend`nin KENDİSİ isim KONTROLÜ
        // YAPMAZ, `args.len`e göre AYRIM yapardı — `sort`nin 0 argümanı
        // `append`nin "tam olarak 1 argüman" KONTROLÜNE takılırdı).
        if (std.mem.eql(u8, a.attr, "sort")) return self.genListSort(obj, a, args);
        if (std.mem.eql(u8, a.attr, "pop")) return if (args.len == 1) genListPopAt(self, obj, a, args) else self.genListPop(obj, a);
        // v1.150.0 (bkz. nox-teknik-spesifikasyon.md §3.267).
        if (std.mem.eql(u8, a.attr, "reverse")) return genListReverse(self, obj, a);
        if (std.mem.eql(u8, a.attr, "clear")) return genListClear(self, obj, a);
        if (std.mem.eql(u8, a.attr, "copy")) return genListCopy(self, obj, a);
        if (std.mem.eql(u8, a.attr, "insert")) return genListInsert(self, obj, a, args);
        if (std.mem.eql(u8, a.attr, "remove") or std.mem.eql(u8, a.attr, "index") or std.mem.eql(u8, a.attr, "count")) return genListSearchOp(self, obj, a, args);
        return self.genListAppend(obj, a, args);
    }
    // Faz OO.2 (bkz. nox-teknik-spesifikasyon.md §3.83): `TaskLocal[T]`in
    // `get`/`set`/`clear`i — `Channel`nin `send`/`recv`sinin AKSİNE
    // `await` GEREKTİRMEZ, bu YÜZDEN (yerleşik bir tip olarak `self.
    // classes`de YOK OLMASINA RAĞMEN) `genAwaitExpr` YERİNE BURADA,
    // NORMAL metod-çağrısı yolunda ele alınır.
    if (obj.heap == .task_local) return async_thread_mod.genTaskLocalOp(self, obj, a, args);
    // Faz SC.2: `t.cancel()` — checker ZATEN 0-argümanlı `cancel`i
    // doğruladı, `await` GEREKMEDEN NORMAL metod-çağrısı yolunda ele
    // alınır (`.task_local`nin AYNI ilkesi).
    if (obj.heap == .task) return async_thread_mod.genTaskCancel(self, obj);
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
        // v4 Faz A madde 4 (bkz. nox-teknik-spesifikasyon.md §3.2xx): genCall'ın
        // AYNI bulgusu (bkz. onun belge notu) — metod çağrısı dönüş yolu.
        return .{ .text = rt, .qtype = msig.sig.ret.qtype, .heap = msig.sig.ret.heap, .elem_qtype = msig.sig.ret.elem_qtype, .class_name = msig.sig.ret.class_name, .elem_heap_info = msig.sig.ret.elem_heap_info, .elem_is_str = msig.sig.ret.elem_is_str, .fixed_int = msig.sig.ret.fixed_int };
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
        // v4 Faz A madde 4 (bkz. nox-teknik-spesifikasyon.md §3.2xx): genCall'ın
        // AYNI bulgusu (bkz. onun belge notu) — metod çağrısı dönüş yolu.
        return .{ .text = rt, .qtype = msig.sig.ret.qtype, .heap = msig.sig.ret.heap, .elem_qtype = msig.sig.ret.elem_qtype, .class_name = msig.sig.ret.class_name, .elem_heap_info = msig.sig.ret.elem_heap_info, .elem_is_str = msig.sig.ret.elem_is_str, .fixed_int = msig.sig.ret.fixed_int };
    }
    return .{ .text = "0", .qtype = .w };
}

/// v1.152.0 (roadmap 1.6b): değeri `list[T]`/`dict[K2, V2]` olan YENİ bir sözlüğe (`d`) değer serbest bırakıcısını yazar — runtime
/// (`dict.zig`) bu değerleri tür-bağımsız `fn(rt, ptr)` ile bırakır (`Dict.value_release`). Diğer değer türlerinde no-op.
pub fn emitDictInstallValueRelease(self: *Codegen, d: []const u8, dinfo: *const DictInfo) CodegenError!void {
    switch (dinfo.value_heap) {
        .list => {
            const ti = dinfo.value_ti.?;
            const self_info: ElemHeapInfo = .{ .heap = .list, .elem_qtype = ti.elem_qtype, .nested = ti.elem_heap_info };
            const fn_name = try self.releaseFnNameFor(self_info);
            const fn_sym = try std.fmt.allocPrint(self.allocator, "${s}_release", .{fn_name});
            try self.qbeCall(null, "$nox_dict_set_value_release", &.{ .{ .ty = .l, .text = d }, .{ .ty = .l, .text = fn_sym } });
        },
        .dict => {
            const inner = dinfo.value_ti.?.dict_info orelse return error.Unsupported;
            const combo: u8 = (@as(u8, @intFromBool(inner.key_is_str)) << 2) | (@as(u8, @intFromBool(inner.value_is_str)) << 1) | @as(u8, @intFromBool(inner.valueIsArc()));
            try self.qbeCall(null, "$nox_dict_set_value_release_dict", &.{ .{ .ty = .l, .text = d }, .{ .ty = .w, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{combo}) } });
        },
        else => {},
    }
}

/// `dict` değer `Value`sine (okunan ham yük `converted`) heap meta verisini ekler.
fn dictValueOf(dinfo: *const DictInfo, converted: Value) Value {
    return abi.dictValueValue(dinfo, converted.text, converted.qtype);
}

fn emitKeyError(self: *Codegen, release_a: ast.Expr, release_av: Value, release_b: ast.Expr, release_bv: Value) CodegenError!void {
    const msg_value = try self.emitStringLiteral("anahtar bulunamadi");
    const ke_cinfo = self.classes.get("KeyError") orelse return error.Unsupported;
    const ke_obj = try self.genConstructFromValues("KeyError", ke_cinfo, &.{msg_value}, null);
    try self.emitExceptionLineStore(ke_obj.text, "KeyError", self.current_raise_line);
    try self.qbeCall(null, "$nox_raise", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ke_obj.text }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{self.current_raise_line}) } });
    try self.releaseIfTemporary(release_a, release_av);
    try self.releaseIfTemporary(release_b, release_bv);
    try self.emitRaisePropagate();
}

/// v1.149.0: `d.get(k[, varsayılan])`, `d.pop(k[, varsayılan])`, `d.setdefault(k, varsayılan)`. Sonuç HER ZAMAN sahipli (+1):
/// sözlükten OKUNAN ödünç değer (get/setdefault bulunca) retain edilir; `pop` sahipliği zaten sözlükten devralır; varsayılan
/// dal `genTernaryBranch` (retainIfAliasing) ile sahipli yapılır. Varsayılan YALNIZCA anahtar yokken değerlendirilir (tembel).
/// `get(k)` (varsayılansız) `V | None` döner: heap değerde null işaretçi, skalerde kutulanmış (`boxScalar`) değer ya da null.
fn genDictGetLike(self: *Codegen, obj: Value, a: ast.Attribute, args: []const ast.Expr, dinfo: *const DictInfo) CodegenError!Value {
    const is_get = std.mem.eql(u8, a.attr, "get");
    const is_pop = std.mem.eql(u8, a.attr, "pop");
    if (args.len < 1 or args.len > 2) return error.Unsupported;
    if (!is_get and !is_pop and args.len != 2) return error.Unsupported; // setdefault
    try self.checkNoLowlevelEscape(obj);
    const key_expr = args[0];
    const key_v0 = try self.genExpr(key_expr);
    try self.checkNoLowlevelEscape(key_v0);
    const key_payload = try self.toPayload(key_v0);
    const key_is_str_lit: []const u8 = if (dinfo.key_is_str) "1" else "0";
    const value_is_str_lit: []const u8 = if (dinfo.value_is_str) "1" else "0";
    const value_is_class_lit: []const u8 = if (dinfo.valueIsArc()) "1" else "0";
    const heap_value = dinfo.value_is_str or dinfo.valueIsArc();
    const heap_kind: HeapKind = if (dinfo.value_is_str) .str else if (dinfo.value_is_class) .class else dinfo.value_heap;

    const has_t = try self.newTemp();
    try self.qbeCall(.{ .name = has_t, .ty = .w }, "$nox_dict_contains", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj.text }, .{ .ty = .w, .text = key_is_str_lit }, .{ .ty = .l, .text = key_payload.text } });
    const found_label = try self.newLabel("dict_found");
    const miss_label = try self.newLabel("dict_miss");
    const end_label = try self.newLabel("dict_end");

    // `pop(k)` varsayılansız: eksik anahtar KeyError.
    const strict_pop = is_pop and args.len == 1;
    if (strict_pop) {
        const err_label = try self.newLabel("dict_pop_err");
        try self.qbeJnz(has_t, found_label, err_label);
        try self.qbeLabel(err_label);
        try emitKeyError(self, key_expr, key_v0, a.obj.*, obj);
        try self.qbeLabel(found_label);
        const payload_t = try self.newTemp();
        try self.qbeCall(.{ .name = payload_t, .ty = .l }, "$nox_dict_pop", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj.text }, .{ .ty = .w, .text = key_is_str_lit }, .{ .ty = .l, .text = key_payload.text } });
        const conv = try self.fromPayload(.{ .text = payload_t, .qtype = .l }, dinfo.value_qtype);
        try self.releaseIfTemporary(key_expr, key_v0);
        try self.releaseIfTemporary(a.obj.*, obj);
        return dictValueOf(dinfo, conv);
    }

    try self.qbeJnz(has_t, found_label, miss_label);

    // ---- bulundu ----
    try self.qbeLabel(found_label);
    var found_text: []const u8 = undefined;
    var found_qtype: QbeType = undefined;
    var found_val: Value = undefined;
    {
        const payload_t = try self.newTemp();
        if (is_pop) {
            try self.qbeCall(.{ .name = payload_t, .ty = .l }, "$nox_dict_pop", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj.text }, .{ .ty = .w, .text = key_is_str_lit }, .{ .ty = .l, .text = key_payload.text } });
        } else {
            try self.qbeCall(.{ .name = payload_t, .ty = .l }, "$nox_dict_get", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj.text }, .{ .ty = .w, .text = key_is_str_lit }, .{ .ty = .l, .text = key_payload.text } });
        }
        const conv = try self.fromPayload(.{ .text = payload_t, .qtype = .l }, dinfo.value_qtype);
        found_val = dictValueOf(dinfo, conv);
        // `get`/`setdefault`: ödünç okuma → sonuç için retain; `pop`: sahiplik zaten devralındı.
        if (!is_pop and heap_value) try self.emitInlineRetain(found_val.text, heap_kind);
        if (is_get and args.len == 1) {
            // `get(k)`: Optional sonuç — skalerde kutula.
            if (!heap_value) {
                const boxed = try self.boxScalar(found_val, dinfo.value_qtype);
                found_text = boxed.text;
                found_qtype = .l;
                found_val = boxed;
            } else {
                found_text = found_val.text;
                found_qtype = .l;
            }
        } else {
            found_text = found_val.text;
            found_qtype = found_val.qtype;
        }
        // Anahtar bu dalda saklanmaz: geçici ise serbest bırak (setdefault'ın miss dalında sahiplik sözlüğe geçer).
        try self.releaseIfTemporary(key_expr, key_v0);
    }
    const found_pred = self.current_label;
    try self.qbeJmp(end_label);

    // ---- bulunamadı ----
    try self.qbeLabel(miss_label);
    var miss_text: []const u8 = "0";
    if (args.len == 1) {
        // get(k): None
        miss_text = "0";
        try self.releaseIfTemporary(key_expr, key_v0);
    } else {
        const dv0 = try self.genTernaryBranch(args[1], &.{});
        const dv = try self.convert(dv0, dinfo.value_qtype);
        miss_text = dv.text;
        if (std.mem.eql(u8, a.attr, "setdefault")) {
            // sözlüğe EKLE: anahtar (ödünç ise retain; geçici ise sahiplik sözlüğe geçer) + değer için ayrı +1.
            const key_v = try self.retainIfAliasing(key_expr, key_v0);
            const key_payload2 = try self.toPayload(key_v);
            if (heap_value) try self.emitInlineRetain(dv.text, heap_kind);
            const value_payload = try self.toPayload(.{ .text = dv.text, .qtype = dv.qtype });
            try self.qbeCall(null, "$nox_dict_set", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj.text }, .{ .ty = .w, .text = key_is_str_lit }, .{ .ty = .w, .text = value_is_str_lit }, .{ .ty = .w, .text = value_is_class_lit }, .{ .ty = .l, .text = key_payload2.text }, .{ .ty = .l, .text = value_payload.text } });
        } else {
            try self.releaseIfTemporary(key_expr, key_v0);
        }
    }
    const miss_pred = self.current_label;
    try self.qbeJmp(end_label);

    try self.qbeLabel(end_label);
    const result_t = try self.newTemp();
    const phi_ty: QbeType = if (is_get and args.len == 1) .l else found_qtype;
    try self.qbePhi(result_t, phi_ty, found_pred, found_text, miss_pred, miss_text);
    try self.releaseIfTemporary(a.obj.*, obj);
    var result = found_val;
    result.text = result_t;
    result.qtype = phi_ty;
    return result;
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
        // Faz MN.4: `nox_dict_contains` ARTIK `rt` ALIYOR (hash-tohumu
        // `RuntimeState`e taşındı — bkz. `dict.zig`nin `hashSeed` belge
        // notu) — İLK argüman olarak `RT_PARAM` EKLENDİ.
        try self.qbeCall(.{ .name = result, .ty = .w }, "$nox_dict_contains", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj.text }, .{ .ty = .w, .text = key_is_str_lit }, .{ .ty = .l, .text = key_payload.text } });
        try self.releaseIfTemporary(args[0], key_v0);
        try self.releaseIfTemporary(a.obj.*, obj);
        return .{ .text = result, .qtype = .w };
    }
    // v1.149.0: get/pop/setdefault/clear/update/copy (bkz. spec §3.266).
    if (std.mem.eql(u8, a.attr, "get") or std.mem.eql(u8, a.attr, "pop") or std.mem.eql(u8, a.attr, "setdefault")) return genDictGetLike(self, obj, a, args, dinfo);
    if (std.mem.eql(u8, a.attr, "clear")) {
        if (args.len != 0) return error.Unsupported;
        try self.checkNoLowlevelEscape(obj);
        try self.qbeCall(null, "$nox_dict_clear", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj.text }, .{ .ty = .w, .text = if (dinfo.key_is_str) "1" else "0" }, .{ .ty = .w, .text = if (dinfo.value_is_str) "1" else "0" }, .{ .ty = .w, .text = if (dinfo.valueIsArc()) "1" else "0" } });
        try self.releaseIfTemporary(a.obj.*, obj);
        return .{ .text = "0", .qtype = .w };
    }
    if (std.mem.eql(u8, a.attr, "update")) {
        if (args.len != 1) return error.Unsupported;
        const other = try self.genExpr(args[0]);
        try self.checkNoLowlevelEscape(obj);
        try self.checkNoLowlevelEscape(other);
        try self.qbeCall(null, "$nox_dict_update", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj.text }, .{ .ty = .l, .text = other.text }, .{ .ty = .w, .text = if (dinfo.key_is_str) "1" else "0" }, .{ .ty = .w, .text = if (dinfo.value_is_str) "1" else "0" }, .{ .ty = .w, .text = if (dinfo.valueIsArc()) "1" else "0" } });
        try self.releaseIfTemporary(args[0], other);
        try self.releaseIfTemporary(a.obj.*, obj);
        return .{ .text = "0", .qtype = .w };
    }
    if (std.mem.eql(u8, a.attr, "copy")) {
        if (args.len != 0) return error.Unsupported;
        try self.checkNoLowlevelEscape(obj);
        const copy_t = try self.newTemp();
        try self.qbeCall(.{ .name = copy_t, .ty = .l }, "$nox_dict_new", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .w, .text = if (dinfo.key_is_str) "1" else "0" } });
        try emitDictInstallValueRelease(self, copy_t, dinfo);
        try self.qbeCall(null, "$nox_dict_update", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = copy_t }, .{ .ty = .l, .text = obj.text }, .{ .ty = .w, .text = if (dinfo.key_is_str) "1" else "0" }, .{ .ty = .w, .text = if (dinfo.value_is_str) "1" else "0" }, .{ .ty = .w, .text = if (dinfo.valueIsArc()) "1" else "0" } });
        try self.releaseIfTemporary(a.obj.*, obj);
        return .{ .text = copy_t, .qtype = .l, .heap = .dict, .dict_info = dinfo };
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
        const key_storage = abi.elemStorageQtype(dinfo.key_qtype, null, .none);
        const elem_size = qbeSizeOf(key_storage);
        const result = try self.newTemp();
        try self.qbeCall(.{ .name = result, .ty = .l }, "$nox_dict_keys", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj.text }, .{ .ty = .w, .text = key_is_str_lit }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{elem_size}) } });
        try self.releaseIfTemporary(a.obj.*, obj);
        var elem_heap_info: ?*const ElemHeapInfo = null;
        if (dinfo.key_is_str) {
            const info = try self.allocator.create(ElemHeapInfo);
            info.* = .{ .heap = .str };
            elem_heap_info = info;
        }
        return .{ .text = result, .qtype = .l, .heap = .list, .elem_qtype = key_storage, .elem_heap_info = elem_heap_info, .elem_is_str = dinfo.key_is_str };
    }
    if (std.mem.eql(u8, a.attr, "values")) {
        if (args.len != 0) return error.Unsupported;
        const value_is_str_lit: []const u8 = if (dinfo.value_is_str) "1" else "0";
        const value_is_class_lit: []const u8 = if (dinfo.valueIsArc()) "1" else "0";
        const value_storage = abi.elemStorageQtype(dinfo.value_qtype, null, .none);
        const elem_size = qbeSizeOf(value_storage);
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
        } else if (dinfo.value_ti) |ti| {
            // v1.152.0: `list[T]`/`dict` değerler — sonuç `list[list[T]]`/`list[dict]`: eleman betimleyicisi değerin kendisi.
            const info = try self.allocator.create(ElemHeapInfo);
            info.* = .{ .heap = ti.heap, .elem_qtype = ti.elem_qtype, .nested = ti.elem_heap_info, .elem_is_str = ti.elem_is_str, .dict_info = ti.dict_info };
            elem_heap_info = info;
        }
        return .{ .text = result, .qtype = .l, .heap = .list, .elem_qtype = value_storage, .elem_heap_info = elem_heap_info, .elem_is_str = dinfo.value_is_str };
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
    // GG.18: `obj.growable_arena` VARSA (bkz. plan dosyası "ASAP
    // güçlendirmesi — Tur 2") `lowlevel:` kapsamının KATI kısıtlamasının
    // (arena listeleri büyütülemez, v1 sınırlaması) BİR İSTİSNASIdır —
    // BU spesifik arena, `local_escape.zig`nin KANITLADIĞI, SKALER-elemanlı
    // bir yerel İçİn ÖZEL olarak yaratıldı.
    if (obj.arena and obj.growable_arena == null) return error.Unsupported;
    // Faz B.4: alıcı ya çıplak bir isim ya da `<isim>.alan` (TEK seviye,
    // `<isim>` bir sınıf örneği — checker ZORUNLU kıldı). İkinci durumda
    // büyüme yolunun yeni işaretçiyi geri yazacağı adres, nesnenin
    // alan ofsetidir (`genAssign`in `.attribute` dalıyla AYNI hesap).
    var field_recv = false;
    const recv_addr: []const u8 = switch (a.obj.*) {
        .attribute => |fa| blk: {
            const base = try self.genExpr(fa.obj.*);
            if (base.heap != .class) return error.Unsupported;
            try self.checkNoLowlevelEscape(base);
            const cinfo = self.classes.get(base.class_name.?) orelse return error.Unsupported;
            for (cinfo.fields.items) |f| {
                if (!std.mem.eql(u8, f.name, fa.attr)) continue;
                const addr = try self.newTemp();
                try self.qbeOp2Imm(addr, .l, "add", base.text, @intCast(f.offset));
                field_recv = true;
                break :blk addr;
            }
            return error.Unsupported;
        },
        else => blk: {
            const recv_name = a.obj.identifier;
            // Bulundu (bkz. proje belleği "modül-seviyesi global durum"
            // planı): alıcı YEREL DEĞİL modül-seviyesi bir global OLABİLİR
            // — büyüme yolunun YENİ işaretçiyi geri yazacağı ADRES ya bir
            // yerelin KENDİ stack slotu ya da globals bloğundaki ofsetidir.
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
        },
    };

    const v0 = try self.genExpr(args[0]);
    try self.checkNoLowlevelEscape(v0);
    const retained = try self.retainIfAliasing(args[0], v0);
    const val = try self.convert(retained, obj.elem_qtype);
    const elem_size = qbeSizeOf(obj.elem_qtype);
    // Alan alıcısında argümanın değerlendirilmesi (ör. `self.xs.append(
    // self.make())`, `make` AYNI alanı büyütebilir) `obj.text`i BAYAT
    // bırakabilir — işaretçi argümandan SONRA alandan YENİDEN okunur.
    // (Yerel/global alıcıda bu hesap gereksizdir, `obj.text` kullanılır.)
    const list_text: []const u8 = if (field_recv) blk: {
        const t = try self.newTemp();
        try self.qbeLoadL(t, recv_addr);
        break :blk t;
    } else obj.text;

    const len_t = try self.newTemp();
    try self.qbeLoadL(len_t, list_text);
    const cap_addr = try self.newTemp();
    try self.qbeOp2Imm(cap_addr, .l, "add", list_text, 8);
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
    if (obj.growable_arena) |arena_handle| {
        // GG.18: `nox_list_grow`nin arena-farkında ikizi — bkz. `runtime/
        // alloc/arc.zig`nin `nox_arena_list_grow`ının belge notu.
        try self.qbeCall(.{ .name = new_ptr, .ty = .l }, "$nox_arena_list_grow", &.{ .{ .ty = .l, .text = arena_handle }, .{ .ty = .l, .text = list_text }, .{ .ty = .l, .text = copy_bytes }, .{ .ty = .l, .text = new_payload_size } });
    } else {
        try self.qbeCall(.{ .name = new_ptr, .ty = .l }, "$nox_list_grow", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = list_text }, .{ .ty = .l, .text = copy_bytes }, .{ .ty = .l, .text = new_payload_size } });
    }

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
    // GG.18: arena-büyümesinde bu retain-telafi dansı hiç GEREKMEZ (ESKİ
    // blok ASLA bireysel serbest BIRAKILMAYACAĞINDAN — bkz. aşağıdaki
    // `should_free` bloğunun ATLANMASI) — ZATEN `obj.growable_arena != null`
    // İKEN `elem_heap_info` HER ZAMAN `null`dır (`local_escape.zig`nin
    // SKALER-eleman-tipi KISITLAMASI, bkz. `elemTypeIsScalar`), bu kontrol
    // SADECE netlik İçİn açıkça eklenir.
    // v2.0 madde 4 (Faz D): `isHeapManaged` KONTROLÜ — bkz. `expr.zig`nin
    // `genIndex`indeki AYNI bulgu, "elem_heap_info != null" ARTIK
    // (`list[u8]` GİBİ skaler-AMA-sabit-genişlikli elemanlarda) "heap-
    // yönetimli" ANLAMINA GELMİYOR.
    if (obj.elem_heap_info != null and isHeapManaged(obj.elem_heap_info.?.heap) and obj.growable_arena == null) {
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
    // bırak (bkz. bu fonksiyonun belge notu, "büyüme yolu"). GG.18:
    // `obj.growable_arena` VARSA bu TÜM blok ATLANIR — ESKİ chunk'ın
    // REFCOUNT BAŞLIĞI YOK (predecrement/free ANLAMSIZ/GÜVENSİZ olurdu),
    // arenanın KENDİSİ per-object free DESTEKLEMEZ (ESKİ chunk SADECE
    // "çöp" olarak, fonksiyonun `function_arena`sı TOPLU yıkılana kadar
    // yaşar — bu, arenaların DOĞAL/beklenen MODELİDİR).
    if (obj.growable_arena == null) {
        const should_free = try self.emitInlinePredecrement(list_text, .list);
        const free_label = try self.newLabel("append_free_old");
        const skip_free_label = try self.newLabel("append_skip_free");
        try self.qbeJnz(should_free, free_label, skip_free_label);
        try self.qbeLabel(free_label);
        if (obj.elem_heap_info != null and isHeapManaged(obj.elem_heap_info.?.heap)) {
            // ESKİ blok BU çağrıda gerçekten ölüyor (`self.attr` GİBİ başka
            // bir alias YOK) — yukarıdaki retain döngüsünün eklediği "fazladan"
            // payı DÜZ bir decrement İLE dengele (TAM özyinelemeli release
            // DEĞİL: bu decrement ASLA sıfıra/altına düşemez, çünkü elemanın
            // ÖNCEKİ, GEÇERLİ sahipliği HÂLÂ duruyor — bkz. `genListAppend`nin
            // büyüme-retain notunun tam gerekçesi).
            try self.emitListElemPlainDecrementLoop(list_text, len_t, obj.elem_heap_info.?.heap);
        }
        const old_size = try self.newTemp();
        {
            const sz = try self.newTemp();
            try self.qbeOp2Imm(sz, .l, "mul", cap_t, @intCast(elem_size));
            try self.qbeOp2Imm(old_size, .l, "add", sz, @intCast(LIST_HEADER_SIZE));
        }
        try self.qbeCall(null, "$nox_rc_free_payload", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = list_text }, .{ .ty = .l, .text = old_size } });
        try self.qbeJmp(skip_free_label);
        try self.qbeLabel(skip_free_label);
    }

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
        try self.qbeOp2(addr, .l, "add", list_text, off16);
        try self.qbeStore(obj.elem_qtype, val.text, addr);
    }
    const fast_new_len = try self.newTemp();
    try self.qbeOp2Imm(fast_new_len, .l, "add", len_t, 1);
    try self.qbeStoreL(fast_new_len, list_text);
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
    try self.qbeJnzCold(empty_t, err_label, ok_label);
    const cold_start = self.beginCold();
    try self.qbeLabel(err_label);
    const msg_value = try self.emitStringLiteral("bos liste (list) pop edilemez");
    const ie_cinfo = self.classes.get("IndexError") orelse return error.Unsupported;
    const ie_obj = try self.genConstructFromValues("IndexError", ie_cinfo, &.{msg_value}, null);
    try self.emitExceptionLineStore(ie_obj.text, "IndexError", self.current_raise_line);
    try self.qbeCall(null, "$nox_raise", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ie_obj.text }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{self.current_raise_line}) } });
    // Bulundu (bkz. proje belleği "4 yeni stdlib modülü" planı — AYNI
    // sınıf hata, `genMethodCall`in belge notundaki GİBİ): bu dal
    // KOŞULSUZ raise edip aşağı ATLAR — `obj` (alıcı) TEMPORARY İSE
    // (ör. `getList().pop()` boş bir liste üzerinde) normal yoldaki
    // (aşağıdaki `ok_label` SONRASI) serbest bırakma BURAYA HİÇ
    // ULAŞMAZ. `obj`nin BURADAN SONRA HİÇ kullanılmadığı İçin (SADECE
    // raise edip çıkıyoruz) serbest bırakmak GÜVENLİDİR.
    try self.releaseIfTemporary(a.obj.*, obj);
    try self.emitRaisePropagate();
    try self.stashCold(cold_start);
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
    try self.loadListElem(result, obj.elem_qtype, addr);

    try self.releaseIfTemporary(a.obj.*, obj);

    return abi.valueFromElemDescriptor(result, obj.elem_qtype, obj.elem_heap_info, obj.elem_is_str, obj.elem_fixed_int);
}

// ===== v1.150.0: list tam API (reverse/clear/copy/insert/remove/index/count/pop(i)/del xs[i]) — bkz. spec §3.267 =====

/// Eleman baytı (`list_ops.zig` ABI'sine `esz` argümanı) — `append`/`sort` ile aynı paketli boyutlar.
pub fn listEszLit(self: *Codegen, obj: Value) CodegenError![]const u8 {
    return std.fmt.allocPrint(self.allocator, "{d}", .{qbeSizeOf(obj.elem_qtype)});
}

/// Kopyalanan elemanların retain türü (`list_ops.zig` `kind`): 0 skaler, 1 `str`, 2 düz ARC işaretçisi.
pub fn listKindLit(_: *Codegen, obj: Value) []const u8 {
    if (obj.elem_heap_info) |eh| {
        if (isHeapManaged(eh.heap)) return if (eh.heap == .str) "1" else "2";
    }
    return if (obj.elem_is_str) "1" else "0";
}

/// `proto` liste değerinin eleman betimleyicilerini taşıyan, TAZE (+1) bir liste değeri.
pub fn freshListValue(_: *Codegen, proto: Value, text: []const u8) Value {
    var v = proto;
    v.text = text;
    v.qtype = .l;
    v.always_fresh = false;
    v.is_pinned = false;
    v.is_stack_slot = false;
    v.arena = false;
    v.growable_arena = null;
    return v;
}

const RelPair = struct { e: ast.Expr, v: Value };

/// Listeden çıkarılan/silinen elemanı (heap-yönetimliyse) serbest bırakır.
fn releaseListElem(self: *Codegen, obj: Value, elem_text: []const u8) CodegenError!void {
    const eh = obj.elem_heap_info orelse return;
    if (!isHeapManaged(eh.heap)) return;
    try self.releaseValueIfSet(elem_text, eh.heap, eh.elem_qtype, eh.class_name, eh.nested, eh.dict_info);
}

/// `bad` (w, doğruysa HATA) koşuluyla soğuk bir hata dalı üretir: `class_name(msg)` fırlatır, `rels` içindeki geçicileri
/// serbest bırakır ve hata yayılımına atlar; normal akış `ok` etiketinde devam eder (`genListPop`un hata dalıyla aynı desen).
fn emitColdListError(self: *Codegen, bad: []const u8, class_name: []const u8, msg: []const u8, rels: []const RelPair) CodegenError!void {
    const err_label = try self.newLabel("list_err");
    const ok_label = try self.newLabel("list_ok");
    try self.qbeJnzCold(bad, err_label, ok_label);
    const cold_start = self.beginCold();
    try self.qbeLabel(err_label);
    const msg_value = try self.emitStringLiteral(msg);
    const cinfo = self.classes.get(class_name) orelse return error.Unsupported;
    const err_obj = try self.genConstructFromValues(class_name, cinfo, &.{msg_value}, null);
    try self.emitExceptionLineStore(err_obj.text, class_name, self.current_raise_line);
    try self.qbeCall(null, "$nox_raise", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = err_obj.text }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{self.current_raise_line}) } });
    for (rels) |r| try self.releaseIfTemporary(r.e, r.v);
    try self.emitRaisePropagate();
    try self.stashCold(cold_start);
    try self.qbeLabel(ok_label);
}

/// `idx` (l) indeksindeki elemanı sınır denetimiyle (aralık dışı/negatif → `IndexError`) listeden ÇIKARIR (sonrakileri kaydırır,
/// `len`i azaltır). Dönen eleman değeri artık ÇAĞIRANA aittir (serbest bırakmak ya da devralmak çağıranın işidir).
fn emitListRemoveAtChecked(self: *Codegen, obj: Value, idx: []const u8, rels: []const RelPair) CodegenError!Value {
    const len_t = try self.newTemp();
    try self.qbeLoadL(len_t, obj.text);
    const bad = try self.newTemp();
    try self.qbeOp2(bad, .w, "cugel", idx, len_t); // işaretsiz idx >= len (negatif de yakalanır)
    try emitColdListError(self, bad, "IndexError", "liste indeksi aralik disi", rels);
    const elem = try self.loadListElemValueAt(obj, idx);
    const esz = try listEszLit(self, obj);
    try self.qbeCall(null, "$nox_list_remove_at", &.{ .{ .ty = .l, .text = obj.text }, .{ .ty = .l, .text = idx }, .{ .ty = .l, .text = esz } });
    return elem;
}

fn genListReverse(self: *Codegen, obj: Value, a: ast.Attribute) CodegenError!Value {
    try self.checkNoLowlevelEscape(obj);
    const esz = try listEszLit(self, obj);
    try self.qbeCall(null, "$nox_list_reverse", &.{ .{ .ty = .l, .text = obj.text }, .{ .ty = .l, .text = esz } });
    try self.releaseIfTemporary(a.obj.*, obj);
    return .{ .text = "0", .qtype = .none };
}

/// `xs.clear()`: heap-yönetimli elemanları tek tek serbest bırakır, `len`i 0 yapar (kapasite korunur; sonraki `append` yerinde yazar).
fn genListClear(self: *Codegen, obj: Value, a: ast.Attribute) CodegenError!Value {
    try self.checkNoLowlevelEscape(obj);
    if (obj.elem_heap_info != null and isHeapManaged(obj.elem_heap_info.?.heap)) {
        const idx_slot = try self.newTemp();
        try self.qbeAlloc(idx_slot, .eight, 8);
        try self.qbeStoreImmL(0, idx_slot);
        const len_t = try self.newTemp();
        try self.qbeLoadL(len_t, obj.text);
        const cond_label = try self.newLabel("clear_cond");
        const body_label = try self.newLabel("clear_body");
        const done_label = try self.newLabel("clear_done");
        try self.qbeJmp(cond_label);
        try self.qbeLabel(cond_label);
        const idx = try self.newTemp();
        try self.qbeLoadL(idx, idx_slot);
        const cont = try self.newTemp();
        try self.qbeOp2(cont, .w, "csltl", idx, len_t);
        try self.qbeJnz(cont, body_label, done_label);
        try self.qbeLabel(body_label);
        const elem = try self.loadListElemValueAt(obj, idx);
        try releaseListElem(self, obj, elem.text);
        const idx2 = try self.newTemp();
        try self.qbeOp2Imm(idx2, .l, "add", idx, 1);
        try self.qbeStoreL(idx2, idx_slot);
        try self.qbeJmp(cond_label);
        try self.qbeLabel(done_label);
    }
    try self.qbeStoreImmL(0, obj.text);
    try self.releaseIfTemporary(a.obj.*, obj);
    return .{ .text = "0", .qtype = .none };
}

/// `xs.copy()`: yüzeysel kopya — yeni bir blok, heap-yönetimli elemanlar RETAIN edilir (iki liste bağımsız sahip).
fn genListCopy(self: *Codegen, obj: Value, a: ast.Attribute) CodegenError!Value {
    try self.checkNoLowlevelEscape(obj);
    const esz = try listEszLit(self, obj);
    const t = try self.newTemp();
    try self.qbeCall(.{ .name = t, .ty = .l }, "$nox_list_copy", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj.text }, .{ .ty = .l, .text = esz }, .{ .ty = .w, .text = listKindLit(self, obj) } });
    try self.releaseIfTemporary(a.obj.*, obj);
    return freshListValue(self, obj, t);
}

/// `xs.insert(i, v)`: `v` önce `append` ile (büyüme/ARC/yeniden-yazma yolu aynı) sona eklenir, sonra alıcı yeniden okunup
/// (büyüme işaretçiyi değiştirmiş olabilir) son eleman Python semantiğiyle `i` konumuna taşınır (negatif `i` sondan sayılır,
/// sınırlar `[0, len]`e sıkıştırılır). `i` argümanı `v`den ÖNCE değerlendirilir.
fn genListInsert(self: *Codegen, obj: Value, a: ast.Attribute, args: []const ast.Expr) CodegenError!Value {
    if (args.len != 2) return error.Unsupported;
    const idx0 = try self.genExpr(args[0]);
    const idx = try self.convert(idx0, .l);
    _ = try genListAppend(self, obj, a, args[1..2]);
    const fresh = try self.genExpr(a.obj.*);
    const esz = try listEszLit(self, obj);
    try self.qbeCall(null, "$nox_list_move_last", &.{ .{ .ty = .l, .text = fresh.text }, .{ .ty = .l, .text = idx.text }, .{ .ty = .l, .text = esz } });
    return .{ .text = "0", .qtype = .none };
}

/// `xs.remove(x)` / `xs.index(x)` / `xs.count(x)`: doğrusal tarama, eşitlik `==` ile aynı (`emitValueEq`). `remove`/`index`
/// bulunamazsa `ValueError`; `remove` elemanı serbest bırakır.
fn genListSearchOp(self: *Codegen, obj: Value, a: ast.Attribute, args: []const ast.Expr) CodegenError!Value {
    if (args.len != 1) return error.Unsupported;
    const x = try self.genExpr(args[0]);
    try self.checkNoLowlevelEscape(obj);
    try self.checkNoLowlevelEscape(x);
    const rels = [_]RelPair{ .{ .e = a.obj.*, .v = obj }, .{ .e = args[0], .v = x } };
    if (std.mem.eql(u8, a.attr, "count")) {
        const n = try self.emitListCount(obj, x);
        try self.releaseIfTemporary(args[0], x);
        try self.releaseIfTemporary(a.obj.*, obj);
        return .{ .text = n, .qtype = .l };
    }
    const idx = try self.emitListFind(obj, x);
    const bad = try self.newTemp();
    try self.qbeOp2Imm(bad, .w, "csltl", idx, 0);
    const msg: []const u8 = if (std.mem.eql(u8, a.attr, "remove")) "list.remove(x): x listede yok" else "list.index(x): x listede yok";
    try emitColdListError(self, bad, "ValueError", msg, &rels);
    if (std.mem.eql(u8, a.attr, "remove")) {
        const elem = try self.loadListElemValueAt(obj, idx);
        const esz = try listEszLit(self, obj);
        try self.qbeCall(null, "$nox_list_remove_at", &.{ .{ .ty = .l, .text = obj.text }, .{ .ty = .l, .text = idx }, .{ .ty = .l, .text = esz } });
        try releaseListElem(self, obj, elem.text);
        try self.releaseIfTemporary(args[0], x);
        try self.releaseIfTemporary(a.obj.*, obj);
        return .{ .text = "0", .qtype = .none };
    }
    try self.releaseIfTemporary(args[0], x);
    try self.releaseIfTemporary(a.obj.*, obj);
    return .{ .text = idx, .qtype = .l };
}

/// `xs.pop(i)`: `i`indeksindeki elemanı çıkarıp döner (sahiplik listeden çağırana geçer); aralık dışı → `IndexError`.
fn genListPopAt(self: *Codegen, obj: Value, a: ast.Attribute, args: []const ast.Expr) CodegenError!Value {
    try self.checkNoLowlevelEscape(obj);
    const idx0 = try self.genExpr(args[0]);
    const idx = try self.convert(idx0, .l);
    const rels = [_]RelPair{.{ .e = a.obj.*, .v = obj }};
    const elem = try emitListRemoveAtChecked(self, obj, idx.text, &rels);
    try self.releaseIfTemporary(a.obj.*, obj);
    return elem;
}

/// v1.153.0: `obj[lo:hi:step]` — `list[T]` (yeni liste, elemanlar retain) ya da `str` (codepoint tabanlı yeni dize). Sınırlar Python gibi
/// sıkıştırılır; dinamik adım 0 → `ValueError`. Operandlar sırayla (obj, lo, hi, step) değerlendirilir.
pub fn genSlice(self: *Codegen, sl: ast.Slice) CodegenError!Value {
    const obj = try self.genExpr(sl.obj.*);
    try self.checkNoLowlevelEscape(obj);
    const Bound = struct { text: []const u8, has: []const u8 };
    var bounds: [3]Bound = undefined;
    const exprs = [3]?*ast.Expr{ sl.lo, sl.hi, sl.step };
    for (exprs, 0..) |maybe, i| {
        if (maybe) |x| {
            const v = try self.genExpr(x.*);
            const c = try self.convert(v, .l);
            bounds[i] = .{ .text = c.text, .has = "1" };
        } else {
            bounds[i] = .{ .text = "0", .has = "0" };
        }
    }
    if (sl.step) |st| {
        const const_nonzero = (st.* == .int_lit and st.int_lit != 0) or (st.* == .unary and st.unary.op == .neg and st.unary.operand.* == .int_lit and st.unary.operand.int_lit != 0);
        if (!const_nonzero) {
            const bad = try self.newTemp();
            try self.qbeOp2Imm(bad, .w, "ceql", bounds[2].text, 0);
            const rels = [_]RelPair{.{ .e = sl.obj.*, .v = obj }};
            try emitColdListError(self, bad, "ValueError", "dilim adimi sifir olamaz", &rels);
        }
    }
    const result = try self.newTemp();
    if (obj.heap == .str) {
        try self.qbeCall(.{ .name = result, .ty = .l }, "$nox_str_slice_op", &.{
            .{ .ty = .l, .text = RT_PARAM },
            .{ .ty = .l, .text = obj.text },
            .{ .ty = .l, .text = bounds[0].text },
            .{ .ty = .w, .text = bounds[0].has },
            .{ .ty = .l, .text = bounds[1].text },
            .{ .ty = .w, .text = bounds[1].has },
            .{ .ty = .l, .text = bounds[2].text },
            .{ .ty = .w, .text = bounds[2].has },
        });
        try self.releaseIfTemporary(sl.obj.*, obj);
        return .{ .text = result, .qtype = .l, .heap = .str };
    }
    if (obj.heap != .list) return error.Unsupported;
    try self.qbeCall(.{ .name = result, .ty = .l }, "$nox_list_slice", &.{
        .{ .ty = .l, .text = RT_PARAM },
        .{ .ty = .l, .text = obj.text },
        .{ .ty = .l, .text = bounds[0].text },
        .{ .ty = .w, .text = bounds[0].has },
        .{ .ty = .l, .text = bounds[1].text },
        .{ .ty = .w, .text = bounds[1].has },
        .{ .ty = .l, .text = bounds[2].text },
        .{ .ty = .w, .text = bounds[2].has },
        .{ .ty = .l, .text = try listEszLit(self, obj) },
        .{ .ty = .w, .text = listKindLit(self, obj) },
    });
    try self.releaseIfTemporary(sl.obj.*, obj);
    return freshListValue(self, obj, result);
}

// ===== v1.154.0: list/dict comprehension — iç içe döngüler satır içi (ifade bağlamında) üretilir =====

const CompTarget = union(enum) {
    list: struct { elem: ast.Expr, esz: []const u8 },
    dict: struct { key: ast.Expr, value: ast.Expr, dinfo: *const DictInfo },
};

const CompState = struct {
    res_slot: []const u8,
    target: CompTarget,
};

/// Comprehension döngü değişkenini (ödünç eleman) geçici olarak `self.vars`e bağlar; `is_param` release'i atlatır.
fn bindCompVar(self: *Codegen, name: []const u8, slot: []const u8, elem: Value) CodegenError!void {
    try self.vars.put(self.allocator, name, .{
        .slot = slot,
        .qtype = elem.qtype,
        .heap = elem.heap,
        .elem_qtype = elem.elem_qtype,
        .class_name = elem.class_name,
        .elem_heap_info = elem.elem_heap_info,
        .elem_is_str = elem.elem_is_str,
        .dict_info = elem.dict_info,
        .func_sig = elem.func_sig,
        .fixed_int = elem.fixed_int,
        .elem_fixed_int = elem.elem_fixed_int,
        .is_param = true,
    });
    try self.modCacheInvalidateName(name);
}

fn genCompClauses(self: *Codegen, clauses: []const ast.CompClause, i: usize, st: *const CompState) CodegenError!void {
    if (i == clauses.len) return genCompLeaf(self, st);
    switch (clauses[i]) {
        .if_clause => |ce| {
            const c = try self.genExpr(ce);
            const then_label = try self.newLabel("comp_if_then");
            const skip_label = try self.newLabel("comp_if_skip");
            try self.qbeJnz(c.text, then_label, skip_label);
            try self.qbeLabel(then_label);
            try genCompClauses(self, clauses, i + 1, st);
            try self.qbeJmp(skip_label);
            try self.qbeLabel(skip_label);
        },
        .for_clause => |fc| try genCompFor(self, clauses, i, fc, st),
    }
}

fn genCompFor(self: *Codegen, clauses: []const ast.CompClause, i: usize, fc: ast.CompForClause, st: *const CompState) CodegenError!void {
    const saved = self.vars.get(fc.var_name);
    const mc_snap = try self.snapshotModCache();
    const var_slot = try self.newTemp();
    try self.qbeAlloc(var_slot, .eight, 8);
    const cond_label = try self.newLabel("comp_cond");
    const body_label = try self.newLabel("comp_body");
    const end_label = try self.newLabel("comp_end");

    if (isRangeCallExpr(fc.iterable)) {
        const rc = fc.iterable.call;
        var lo: []const u8 = "0";
        var hi: []const u8 = undefined;
        var step: []const u8 = "1";
        var step_sign: i2 = 1; // 1 pozitif sabit, -1 negatif sabit, 0 dinamik
        if (rc.args.len == 1) {
            hi = (try self.convert(try self.genExpr(rc.args[0]), .l)).text;
        } else {
            lo = (try self.convert(try self.genExpr(rc.args[0]), .l)).text;
            hi = (try self.convert(try self.genExpr(rc.args[1]), .l)).text;
            if (rc.args.len == 3) {
                const sa = rc.args[2];
                step = (try self.convert(try self.genExpr(sa), .l)).text;
                if (sa == .int_lit and sa.int_lit > 0) {
                    step_sign = 1;
                } else if (sa == .unary and sa.unary.op == .neg and sa.unary.operand.* == .int_lit and sa.unary.operand.int_lit > 0) {
                    step_sign = -1;
                } else {
                    step_sign = 0;
                    const bad = try self.newTemp();
                    try self.qbeOp2Imm(bad, .w, "ceql", step, 0);
                    const rels = [_]RelPair{};
                    try emitColdListError(self, bad, "ValueError", "range adimi sifir olamaz", &rels);
                }
            }
        }
        try self.qbeStoreL(lo, var_slot);
        try self.qbeJmp(cond_label);
        try self.qbeLabel(cond_label);
        const cur = try self.newTemp();
        try self.qbeLoadL(cur, var_slot);
        const cont = try self.newTemp();
        switch (step_sign) {
            1 => try self.qbeOp2(cont, .w, "csltl", cur, hi),
            -1 => try self.qbeOp2(cont, .w, "csgtl", cur, hi),
            else => {
                const pos = try self.newTemp();
                try self.qbeOp2Imm(pos, .w, "csgtl", step, 0);
                const lt = try self.newTemp();
                try self.qbeOp2(lt, .w, "csltl", cur, hi);
                const gt = try self.newTemp();
                try self.qbeOp2(gt, .w, "csgtl", cur, hi);
                const a1 = try self.newTemp();
                try self.qbeOp2(a1, .w, "and", pos, lt);
                const npos = try self.newTemp();
                try self.qbeOp2Imm(npos, .w, "xor", pos, 1);
                const a2 = try self.newTemp();
                try self.qbeOp2(a2, .w, "and", npos, gt);
                try self.qbeOp2(cont, .w, "or", a1, a2);
            },
        }
        try self.qbeJnz(cont, body_label, end_label);
        try self.qbeLabel(body_label);
        try bindCompVar(self, fc.var_name, var_slot, .{ .text = cur, .qtype = .l });
        try genCompClauses(self, clauses, i + 1, st);
        const cur2 = try self.newTemp();
        try self.qbeLoadL(cur2, var_slot);
        const nxt = try self.newTemp();
        try self.qbeOp2(nxt, .l, "add", cur2, step);
        try self.qbeStoreL(nxt, var_slot);
        try self.qbeJmp(cond_label);
        try self.qbeLabel(end_label);
    } else {
        const iter = try self.genExpr(fc.iterable);
        try self.checkNoLowlevelEscape(iter);
        if (iter.heap != .list) return error.Unsupported;
        const idx_slot = try self.newTemp();
        try self.qbeAlloc(idx_slot, .eight, 8);
        try self.qbeStoreImmL(0, idx_slot);
        const len_t = try self.newTemp();
        try self.qbeLoadL(len_t, iter.text);
        try self.qbeJmp(cond_label);
        try self.qbeLabel(cond_label);
        const idx = try self.newTemp();
        try self.qbeLoadL(idx, idx_slot);
        const cont = try self.newTemp();
        try self.qbeOp2(cont, .w, "csltl", idx, len_t);
        try self.qbeJnz(cont, body_label, end_label);
        try self.qbeLabel(body_label);
        const elem = try self.loadListElemValueAt(iter, idx);
        try self.qbeStore(elem.qtype, elem.text, var_slot);
        try bindCompVar(self, fc.var_name, var_slot, elem);
        try genCompClauses(self, clauses, i + 1, st);
        const idx2 = try self.newTemp();
        try self.qbeOp2Imm(idx2, .l, "add", idx, 1);
        try self.qbeStoreL(idx2, idx_slot);
        try self.qbeJmp(cond_label);
        try self.qbeLabel(end_label);
        try self.releaseIfTemporary(fc.iterable, iter);
    }
    self.restoreModCache(mc_snap);
    if (saved) |sv| {
        try self.vars.put(self.allocator, fc.var_name, sv);
    } else {
        _ = self.vars.remove(fc.var_name);
    }
}

fn isRangeCallExpr(e: ast.Expr) bool {
    return e == .call and e.call.callee.* == .identifier and std.mem.eql(u8, e.call.callee.identifier, "range") and e.call.args.len >= 1 and e.call.args.len <= 3;
}

fn genCompLeaf(self: *Codegen, st: *const CompState) CodegenError!void {
    switch (st.target) {
        .list => |t| {
            const ev0 = try self.genExpr(t.elem);
            try self.checkNoLowlevelEscape(ev0);
            const ev = try self.retainIfAliasing(t.elem, ev0);
            const payload = try self.toPayload(ev);
            const cur = try self.newTemp();
            try self.qbeLoadL(cur, st.res_slot);
            const np = try self.newTemp();
            try self.qbeCall(.{ .name = np, .ty = .l }, "$nox_list_push", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = cur }, .{ .ty = .l, .text = payload.text }, .{ .ty = .l, .text = t.esz } });
            try self.qbeStoreL(np, st.res_slot);
        },
        .dict => |t| {
            const k0 = try self.genExpr(t.key);
            try self.checkNoLowlevelEscape(k0);
            const kv = try self.retainIfAliasing(t.key, k0);
            const v0 = try self.genExpr(t.value);
            try self.checkNoLowlevelEscape(v0);
            const vv = try self.retainIfAliasing(t.value, v0);
            const kp = try self.toPayload(kv);
            const vp = try self.toPayload(vv);
            const d = try self.newTemp();
            try self.qbeLoadL(d, st.res_slot);
            try self.qbeCall(null, "$nox_dict_set", &.{
                .{ .ty = .l, .text = RT_PARAM },
                .{ .ty = .l, .text = d },
                .{ .ty = .w, .text = if (t.dinfo.key_is_str) "1" else "0" },
                .{ .ty = .w, .text = if (t.dinfo.value_is_str) "1" else "0" },
                .{ .ty = .w, .text = if (t.dinfo.valueIsArc()) "1" else "0" },
                .{ .ty = .l, .text = kp.text },
                .{ .ty = .l, .text = vp.text },
            });
        },
    }
}

/// `[elem for x in it if c ...]` — sonuç listesi `result_type`tan (checker) bilinen tipte; döngüler satır içi üretilir, her eleman sahipli
/// (+1) olarak `nox_list_push` ile eklenir. Bilinen sınırlama: gövdede bir istisna fırlarsa kısmi sonuç listesi sızar.
pub fn genListComp(self: *Codegen, lc: ast.ListComp) CodegenError!Value {
    const rt_te = lc.result_type orelse return error.Unsupported;
    const ti = try self.resolveType(rt_te);
    if (ti.heap != .list) return error.Unsupported;
    const res_slot = try self.newTemp();
    try self.qbeAlloc(res_slot, .eight, 8);
    const empty = try self.newTemp();
    try self.qbeCall(.{ .name = empty, .ty = .l }, "$nox_list_empty", &.{.{ .ty = .l, .text = RT_PARAM }});
    try self.qbeStoreL(empty, res_slot);
    const st: CompState = .{ .res_slot = res_slot, .target = .{ .list = .{ .elem = lc.elem.*, .esz = try std.fmt.allocPrint(self.allocator, "{d}", .{qbeSizeOf(ti.elem_qtype)}) } } };
    try genCompClauses(self, lc.clauses, 0, &st);
    const res = try self.newTemp();
    try self.qbeLoadL(res, res_slot);
    return .{ .text = res, .qtype = .l, .heap = .list, .elem_qtype = ti.elem_qtype, .elem_heap_info = ti.elem_heap_info, .elem_is_str = ti.elem_is_str, .elem_fixed_int = ti.elem_fixed_int };
}

/// `{k: v for x in it if c ...}` — sözlük `result_type`tan bilinen tipte kurulur (değer list/dict ise serbest bırakıcı yazılır).
pub fn genDictComp(self: *Codegen, dc: ast.DictComp) CodegenError!Value {
    const rt_te = dc.result_type orelse return error.Unsupported;
    const ti = try self.resolveType(rt_te);
    if (ti.heap != .dict) return error.Unsupported;
    const dinfo = ti.dict_info orelse return error.Unsupported;
    const res_slot = try self.newTemp();
    try self.qbeAlloc(res_slot, .eight, 8);
    const d = try self.newTemp();
    try self.qbeCall(.{ .name = d, .ty = .l }, "$nox_dict_new", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .w, .text = if (dinfo.key_is_str) "1" else "0" } });
    try emitDictInstallValueRelease(self, d, dinfo);
    try self.qbeStoreL(d, res_slot);
    const st: CompState = .{ .res_slot = res_slot, .target = .{ .dict = .{ .key = dc.key.*, .value = dc.value.*, .dinfo = dinfo } } };
    try genCompClauses(self, dc.clauses, 0, &st);
    const res = try self.newTemp();
    try self.qbeLoadL(res, res_slot);
    return .{ .text = res, .qtype = .l, .heap = .dict, .dict_info = dinfo };
}

/// `del xs[i]`: elemanı çıkarıp serbest bırakır; aralık dışı → `IndexError`.
pub fn genListDelete(self: *Codegen, ix: ast.Index, obj: Value) CodegenError!void {
    try self.checkNoLowlevelEscape(obj);
    const idx0 = try self.genExpr(ix.index.*);
    const idx = try self.convert(idx0, .l);
    const rels = [_]RelPair{.{ .e = ix.obj.*, .v = obj }};
    const elem = try emitListRemoveAtChecked(self, obj, idx.text, &rels);
    try releaseListElem(self, obj, elem.text);
    try self.releaseIfTemporary(ix.obj.*, obj);
}

/// v1.156.0: `print(a, b, ...)`, `print()`, `print(..., sep=s, end=e)` — tüm argümanlar ÖNCE değerlendirilir, sonra `sep` (varsayılan " ") ile
/// ayrılarak yazılır, sonunda `end` (varsayılan satır sonu). `str` argümanlar tırnaksız (`%s`), diğerleri tek-argümanlı `print` ile aynı biçimde.
fn genPrintGeneral(self: *Codegen, args: []const ast.Expr) CodegenError!Value {
    var pos: std.ArrayListUnmanaged(ast.Expr) = .empty;
    var sep_expr: ?ast.Expr = null;
    var end_expr: ?ast.Expr = null;
    for (args) |a| {
        if (a == .kwarg) {
            if (std.mem.eql(u8, a.kwarg.name, "sep")) sep_expr = a.kwarg.value.* else end_expr = a.kwarg.value.*;
        } else try pos.append(self.allocator, a);
    }
    const values = try self.allocator.alloc(Value, pos.items.len);
    for (pos.items, 0..) |e, i| values[i] = try self.genExpr(e);
    const sep_v: ?Value = if (sep_expr) |e| try self.genExpr(e) else null;
    const end_v: ?Value = if (end_expr) |e| try self.genExpr(e) else null;
    const fmt_s = try self.internFmtString("%s");
    const fmt_sp = try self.internFmtString(" ");
    const fmt_nl = try self.internFmtString("\n");
    for (values, 0..) |v, i| {
        if (i > 0) {
            if (sep_v) |sv| {
                try self.qbeCallVariadic(null, "$printf", &.{.{ .ty = .l, .text = fmt_s }}, &.{.{ .ty = .l, .text = sv.text }});
            } else try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = fmt_sp }});
        }
        if (v.heap == .str) {
            try self.qbeCallVariadic(null, "$printf", &.{.{ .ty = .l, .text = fmt_s }}, &.{.{ .ty = .l, .text = v.text }});
        } else try self.genPrintFragment(v);
    }
    if (end_v) |ev| {
        try self.qbeCallVariadic(null, "$printf", &.{.{ .ty = .l, .text = fmt_s }}, &.{.{ .ty = .l, .text = ev.text }});
    } else try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = fmt_nl }});
    for (pos.items, values) |e, v| try self.releaseIfTemporary(e, v);
    if (sep_expr) |e| try self.releaseIfTemporary(e, sep_v.?);
    if (end_expr) |e| try self.releaseIfTemporary(e, end_v.?);
    return .{ .text = "0", .qtype = .w };
}

/// v1.156.0: `str` metodları (bkz. `checker.zig` `checkStrMethod`) — `nox_strings_*_raw`/`nox_str_*` çalışma zamanı işlevlerine iner. Sonuç str/list[str] TAZE (+1).
fn genStrMethod(self: *Codegen, obj: Value, a: ast.Attribute, args: []const ast.Expr) CodegenError!Value {
    try self.checkNoLowlevelEscape(obj);
    const m = a.attr;
    const eq = std.mem.eql;
    const vals = try self.allocator.alloc(Value, args.len);
    for (args, 0..) |arg, i| {
        vals[i] = try self.genExpr(arg);
        try self.checkNoLowlevelEscape(vals[i]);
    }
    const rt_arg: codegen.QbeArg = .{ .ty = .l, .text = RT_PARAM };
    const s_arg: codegen.QbeArg = .{ .ty = .l, .text = obj.text };
    const result = try self.newTemp();
    var ret: Value = .{ .text = result, .qtype = .l, .heap = .str };
    if (eq(u8, m, "upper") or eq(u8, m, "lower") or eq(u8, m, "strip") or eq(u8, m, "lstrip") or eq(u8, m, "rstrip")) {
        const sym: []const u8 = if (eq(u8, m, "upper")) "$nox_strings_upper_raw" else if (eq(u8, m, "lower")) "$nox_strings_lower_raw" else if (eq(u8, m, "strip")) "$nox_strings_trim_raw" else if (eq(u8, m, "lstrip")) "$nox_strings_trim_start_raw" else "$nox_strings_trim_end_raw";
        try self.qbeCall(.{ .name = result, .ty = .l }, sym, &.{ rt_arg, s_arg });
    } else if (eq(u8, m, "replace")) {
        try self.qbeCall(.{ .name = result, .ty = .l }, "$nox_strings_replace_raw", &.{ rt_arg, s_arg, .{ .ty = .l, .text = vals[0].text }, .{ .ty = .l, .text = vals[1].text } });
    } else if (eq(u8, m, "split")) {
        if (args.len == 0) {
            try self.qbeCall(.{ .name = result, .ty = .l }, "$nox_strings_split_ws_raw", &.{ rt_arg, s_arg });
        } else {
            try self.qbeCall(.{ .name = result, .ty = .l }, "$nox_strings_split_raw", &.{ rt_arg, s_arg, .{ .ty = .l, .text = vals[0].text } });
        }
        const info = try self.allocator.create(ElemHeapInfo);
        info.* = .{ .heap = .str };
        ret = .{ .text = result, .qtype = .l, .heap = .list, .elem_qtype = .l, .elem_heap_info = info, .elem_is_str = true };
    } else if (eq(u8, m, "join")) {
        // `sep.join(parts)`: alıcı ayraçtır, argüman parçalar listesi.
        try self.qbeCall(.{ .name = result, .ty = .l }, "$nox_strings_join_raw", &.{ rt_arg, .{ .ty = .l, .text = vals[0].text }, s_arg });
    } else if (eq(u8, m, "startswith") or eq(u8, m, "endswith")) {
        const raw = try self.newTemp();
        try self.qbeCall(.{ .name = raw, .ty = .l }, if (eq(u8, m, "startswith")) "$nox_strings_starts_with_raw" else "$nox_strings_ends_with_raw", &.{ s_arg, .{ .ty = .l, .text = vals[0].text } });
        try self.qbeOp2Imm(result, .w, "cnel", raw, 0);
        ret = .{ .text = result, .qtype = .w };
    } else if (eq(u8, m, "find") or eq(u8, m, "index")) {
        try self.qbeCall(.{ .name = result, .ty = .l }, "$nox_str_find", &.{ s_arg, .{ .ty = .l, .text = vals[0].text } });
        ret = .{ .text = result, .qtype = .l };
        if (eq(u8, m, "index")) {
            const bad = try self.newTemp();
            try self.qbeOp2Imm(bad, .w, "csltl", result, 0);
            var rels: [2]RelPair = .{ .{ .e = a.obj.*, .v = obj }, .{ .e = args[0], .v = vals[0] } };
            try emitColdListError(self, bad, "ValueError", "str.index(sub): alt dize bulunamadi", &rels);
        }
    } else if (eq(u8, m, "count")) {
        try self.qbeCall(.{ .name = result, .ty = .l }, "$nox_str_count", &.{ s_arg, .{ .ty = .l, .text = vals[0].text } });
        ret = .{ .text = result, .qtype = .l };
    } else if (eq(u8, m, "isdigit") or eq(u8, m, "isalpha") or eq(u8, m, "isalnum") or eq(u8, m, "isspace") or eq(u8, m, "isupper") or eq(u8, m, "islower")) {
        const kind: []const u8 = if (eq(u8, m, "isdigit")) "0" else if (eq(u8, m, "isalpha")) "1" else if (eq(u8, m, "isalnum")) "2" else if (eq(u8, m, "isspace")) "3" else if (eq(u8, m, "isupper")) "4" else "5";
        const raw = try self.newTemp();
        try self.qbeCall(.{ .name = raw, .ty = .l }, "$nox_str_char_class", &.{ s_arg, .{ .ty = .w, .text = kind } });
        try self.qbeOp2Imm(result, .w, "cnel", raw, 0);
        ret = .{ .text = result, .qtype = .w };
    } else if (eq(u8, m, "zfill") or eq(u8, m, "ljust") or eq(u8, m, "rjust") or eq(u8, m, "center")) {
        const mode: []const u8 = if (eq(u8, m, "ljust")) "0" else if (eq(u8, m, "rjust")) "1" else if (eq(u8, m, "center")) "2" else "3";
        const width = try self.convert(vals[0], .l);
        const fill: []const u8 = if (args.len > 1) vals[1].text else "0";
        try self.qbeCall(.{ .name = result, .ty = .l }, "$nox_str_just", &.{ rt_arg, s_arg, .{ .ty = .l, .text = width.text }, .{ .ty = .l, .text = fill }, .{ .ty = .w, .text = mode } });
    } else return error.Unsupported;
    for (args, vals) |arg, v| try self.releaseIfTemporary(arg, v);
    try self.releaseIfTemporary(a.obj.*, obj);
    return ret;
}

/// `Channel[T](capacity)`/`ThreadChannel[T](capacity)` (yerleşikler) YA DA
/// Faz P2.1'in kullanıcı-tanımlı generic sınıf kurucusu (bkz. `ast.
/// GenericConstruct.resolved_class_name`in belge notu) — AÇIK tip argümanlı
/// bir kurucu çağrısı.
pub fn genGenericConstruct(self: *Codegen, g: ast.GenericConstruct) CodegenError!Value {
    // v2.0 madde 6: `ptr[T](addr)` — SIFIR runtime maliyeti, `addr`
    // değeri OLDUĞU GİBİ `T`nin betimleyicisiyle ETİKETLENİR. 9 `ptr_*`
    // yerleşiğinin AYNI çift-kontrol deseni (checker `requireLowlevel`
    // ZATEN doğruladı, BURADA AYRICA savunmacı olarak TEKRAR kontrol
    // edilir — `Channel`/`TaskLocal` dallarının AKSİNE, `ptr` ailesinin
    // KENDİ, DAHA SIKI hassasiyeti).
    if (std.mem.eql(u8, g.name, "ptr")) {
        try checkInsideLowlevel(self);
        if (g.type_args.len != 1 or g.args.len != 1) return error.Unsupported;
        const elem = try self.resolveType(g.type_args[0]);
        const addr_val = try self.genExpr(g.args[0]);
        var elem_heap_info: ?*const ElemHeapInfo = null;
        if (elem.heap == .class or elem.heap == .list or elem.heap == .str or elem.heap == .closure or elem.heap == .dict) {
            const info = try self.allocator.create(ElemHeapInfo);
            info.* = .{ .heap = elem.heap, .class_name = elem.class_name, .elem_qtype = elem.elem_qtype, .nested = elem.elem_heap_info, .elem_is_str = elem.elem_is_str, .func_sig = elem.func_sig, .dict_info = elem.dict_info };
            elem_heap_info = info;
        }
        return .{
            .text = addr_val.text,
            .qtype = .l,
            .heap = .typed_ptr,
            .elem_qtype = elem.qtype,
            .elem_heap_info = elem_heap_info,
            .elem_is_str = elem.heap == .str,
            .elem_fixed_int = elem.fixed_int,
        };
    }
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
    // Faz MN.9.4: `--release` altında `ThreadChannel[T]`nin ÇALIŞMA-ZAMANI
    // temsili ARTIK GERÇEKTEN bir `Channel(T)` (`nox_channel_new`) —
    // `thread_channel.zig`nin ÖZEL çift-self-pipe protokolü (İKİ BAĞIMSIZ
    // `RuntimeState`yi köprülemek İçİN VARDI, Bölüm 1 SONRASI TEK bir
    // paylaşılan havuzda ARTIK GEREKMEZ) ATLANIR — Nox-KAYNAK seviyesinde
    // `ThreadChannel` tip adı KORUNUR (aşağıdaki `.heap = .thread_channel`
    // etiketi DEĞİŞMEDEN kalır), SADECE ALTTAKİ runtime çağrısı DEĞİŞİR
    // (bkz. `genThreadChannelOp`/`destroyNonArcValue`nin AYNI MN.9.4 notu).
    const new_fn_name = if (is_thread_channel and self.backend != .llvm) "nox_threadchannel_new" else "nox_channel_new";
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
