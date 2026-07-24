//! İfade (`ast.Expr`) codegen çekirdeği — bkz. plan dosyası "QBE codegen
//! backend'ini alt modüllere bölme". `genExpr`in KENDİSİ (TÜM ifade
//! üretiminin TEK dağıtım noktası) VE onun doğrudan alt-dalları (alan
//! okuma, indeksleme, liste/dict literalleri, tekli/ikili operatörler,
//! `print` görüntüleme yardımcıları) burada toplanır.

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
const RT_PARAM = types.RT_PARAM;
const LIST_HEADER_SIZE = types.LIST_HEADER_SIZE;
const ARC_HEADER_SIZE = types.ARC_HEADER_SIZE;
const CLOSURE_HEADER_SIZE = types.CLOSURE_HEADER_SIZE;
const CLOSURE_RELEASE_FN_PTR_OFFSET = types.CLOSURE_RELEASE_FN_PTR_OFFSET;
const FuncSigInfo = types.FuncSigInfo;
const CodegenError = abi.CodegenError;
const qbeTypeName = abi.qbeTypeName;
const qbeSizeOf = abi.qbeSizeOf;
const cmpMnemonic = abi.cmpMnemonic;
const isHeapManaged = abi.isHeapManaged;
const isTemporaryExpr = abi.isTemporaryExpr;
const valueFromElemDescriptor = abi.valueFromElemDescriptor;
const escapeForQbeString = abi.escapeForQbeString;
const modCacheKey = optimizations.modCacheKey;

/// Faz FF.6 (bkz. nox-teknik-spesifikasyon.md §3.65): `.none_lit`in
/// bağlam-duyarlı üretimi — `genExpr`in KENDİSİ (bkz. onun `.none_lit`
/// dalı) hâlâ koşulsuz `error.Unsupported` döner (HİÇBİR bağlam
/// bilgisi ALMAZ), ÇÜNKÜ Nox'un GENEL ifade üretim mimarisi aşağıdan-
/// yukarıya (bottom-up, hedef tipten BAĞIMSIZ) çalışır — `genExpr`in
/// imzasına bir "beklenen tip" parametresi EKLEMEK tüm özyinelemeli
/// çağrı grafiğini (`genExpr`in KENDİSİNİ çağıran ONLARCA site)
/// etkileyen, bu görevin kapsamını AŞAN bir DEĞİŞİKLİK olurdu. Bunun
/// YERİNE, HEDEFİN (bir değişken/alan/parametre/dönüş yuvasının)
/// ÇÖZÜLMÜŞ `TypeInfo`sini ZATEN elinde bulunduran ÇAĞRI SİTELERİ
/// (`var_decl`/`assign`/`genConstruct`/`genMethodCall`/`return_stmt`)
/// `genExpr` yerine BUNU çağırır — FF.5'in `registerClass`ının
/// `inferFieldType`i BYPASS ETMESİYLE AYNI "çağıran taraf bilir"
/// deseni. Yalnızca HEAP-yönetimli (ya da `ptr`) bir hedef İçin
/// anlamlıdır — `resolveType`in `.optional` dalı ZATEN İLKEL Optional'ları
/// (kutulama HENÜZ yok, Faz FF.6.4) `error.Unsupported` İLE eledi, bu
/// yüzden `target.heap == .none` burada YALNIZCA "gerçekten Optional
/// OLMAYAN bir hedefe `None` YAZILMAYA ÇALIŞILDI" anlamına gelir —
/// checker BUNU zaten reddetmiş olmalı, savunmacı olarak `genExpr`in
/// KENDİ hatasına düşülür.
pub fn genExprForTarget(self: *Codegen, expr: ast.Expr, target: anytype) CodegenError!Value {
    // Faz P2.2 (bkz. proje belleği "P0/P1/P2 inceleme düzeltme listesi"):
    // checker ARTIK boş bir liste literalinin (`[]`) tipini, BİR BEKLENEN
    // tip biliniyorsa (bkz. `checker.zig`nin `checkExprExpected`i) kabul
    // ediyor — codegen'in KENDİ (BAĞIMSIZ) `genListLit`i HÂLÂ en az bir
    // eleman GEREKTİRİR (elemanın QBE tipini/heap-bilgisini SADECE İLK
    // elemandan ÇIKARABİLDİĞİNDEN) — bu YÜZDEN `.none_lit`in AYNI "hedefin
    // ÇÖZÜLMÜŞ TypeInfo'sunu kullan" desenini İZLER.
    if (expr == .list_lit and expr.list_lit.len == 0 and target.heap == .list) {
        return genEmptyListLit(self, target);
    }
    // `genEmptyListLit`in AYNISI, `{}` (boş dict) İÇİN — bkz. `genEmptyDictLit`nin
    // belge notu.
    if (expr == .dict_lit and expr.dict_lit.len == 0 and target.heap == .dict) {
        return genEmptyDictLit(self, target);
    }
    if (expr == .none_lit and target.heap != .none) {
        return .{
            .text = "0",
            .qtype = target.qtype,
            .heap = target.heap,
            .elem_qtype = target.elem_qtype,
            .class_name = target.class_name,
            .elem_heap_info = target.elem_heap_info,
            .elem_is_str = target.elem_is_str,
            .dict_info = target.dict_info,
        };
    }
    const v0 = try self.genExpr(expr);
    // Faz FF.6.4 (bkz. nox-teknik-spesifikasyon.md §3.65): hedef
    // kutulanmış bir Optional-ilkel (`boxed_scalar`) İSE VE `v0`
    // KENDİSİ HENÜZ kutulanmamış bir ÇIPLAK skalerse (ör. `x: int |
    // None = 5`, ya da daraltılmış/kutu OLMAYAN bir ifadeden gelen
    // değer) — YENİ bir kutu tahsis edilip değer İÇİNE yazılır. `v0`
    // ZATEN kutulanmışsa (ör. `y: int | None = x`, `x` KENDİSİ `int |
    // None`) OLDUĞU GİBİ geçirilir (retain, ÇAĞIRAN TARAFTA — bkz.
    // `retainIfAliasing` — normal aliasing yoluyla ZATEN ele alınır).
    if (target.heap == .boxed_scalar and v0.heap != .boxed_scalar) {
        return self.boxScalar(v0, target.elem_qtype);
    }
    return v0;
}

/// Faz FF.6.4: `v` (ham bir `.l`/`.d`/`.w` skaleri) TEK-ALANLI, ARC-
/// yönetimli bir kutu İÇİNE sarar — `nox_rc_alloc(rt, 8)`, döndürülen
/// pointer'ın KENDİSİNİN (list/class'ın AKSİNE, tag/başlık YOK) offset
/// 0'ına DOĞRUDAN değeri yazar. `releaseValueIfSet`in `.boxed_scalar`
/// dalı BU DÜZ 8-baytlık payload'ı VARSAYAR — İKİSİ TUTARLI kalmalıdır.
pub fn boxScalar(self: *Codegen, v: Value, elem_qtype: QbeType) CodegenError!Value {
    const box = try self.newTemp();
    try self.out.writer.print("    {s} =l call $nox_rc_alloc(l {s}, l 8)\n", .{ box, RT_PARAM });
    try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(elem_qtype), v.text, box });
    // `always_fresh = true` (bkz. `Value`nin belge notu, stdlib fazı §G
    // — `emitStringLiteral`in AYNI deseni): bu kutu HER ZAMAN TAZE bir
    // tahsistir (kaynak ifade bir `.identifier` OLSA BİLE — ör. `y: int
    // | None = some_bare_int` — kutunun KENDİSİ o değişkenin bir
    // ALIAS'I DEĞİLDİR) — `retainIfAliasing`in AST-tabanlı sezgisinin
    // (çıplak bir isim HER ZAMAN aliasing sayılır) burada YANLIŞ
    // POZİTİF üretip TAZE kutuyu SPÜRİYÖZ retain etmesini (kalıcı sızıntı)
    // ÖNLER.
    return .{ .text = box, .qtype = .l, .heap = .boxed_scalar, .elem_qtype = elem_qtype, .always_fresh = true };
}

pub fn convert(self: *Codegen, v: Value, target: QbeType) CodegenError!Value {
    if (v.qtype == target) return v;
    if (v.qtype == .l and target == .d) {
        const t = try self.newTemp();
        try self.out.writer.print("    {s} =d sltof {s}\n", .{ t, v.text });
        return .{ .text = t, .qtype = .d };
    }
    if (v.qtype == .d and target == .l) {
        const t = try self.newTemp();
        try self.out.writer.print("    {s} =l dtosi {s}\n", .{ t, v.text });
        return .{ .text = t, .qtype = .l };
    }
    return error.Unsupported;
}

/// Faz 21 aşama 4: `v`yi (doğal QBE tipinde — `l`/`w`/`d`) `Task`/
/// `Channel`in çalışma zamanı köprüsünün (bkz. `runtime/async_rt/
/// bridge.zig`) beklediği tekdüze 8 baytlık `i64` "payload"a çevirir.
/// `convert`in AKSİNE (sayısal DEĞER dönüşümü, ör. int->float), bu
/// BİT-KORUYUCU bir yeniden yorumlamadır (`l`/`d` zaten 8 bayt — `cast`
/// yalnızca bit örüntüsünü ikisi arasında taşır; `w`/bool `extuw` ile
/// sıfır-genişletilir). `None` dönüşü önemsiz bir `0`dır.
pub fn toPayload(self: *Codegen, v: Value) CodegenError!Value {
    return switch (v.qtype) {
        .l => v,
        .w => blk: {
            const t = try self.newTemp();
            try self.out.writer.print("    {s} =l extuw {s}\n", .{ t, v.text });
            break :blk .{ .text = t, .qtype = .l };
        },
        .d => blk: {
            const t = try self.newTemp();
            try self.out.writer.print("    {s} =l cast {s}\n", .{ t, v.text });
            break :blk .{ .text = t, .qtype = .l };
        },
        .none => .{ .text = "0", .qtype = .l },
    };
}

/// `toPayload`in tersi: bir `i64` payload'ı `target_qtype`e geri çevirir
/// (`l`->`w` düz `copy` ile DÜŞÜK 32 biti alır — QBE'de geçerli bir
/// daraltma; `l`->`d` `cast` ile bit örüntüsünü geri yorumlar).
pub fn fromPayload(self: *Codegen, payload: Value, target_qtype: QbeType) CodegenError!Value {
    return switch (target_qtype) {
        .l => payload,
        .w => blk: {
            const t = try self.newTemp();
            try self.out.writer.print("    {s} =w copy {s}\n", .{ t, payload.text });
            break :blk .{ .text = t, .qtype = .w };
        },
        .d => blk: {
            const t = try self.newTemp();
            try self.out.writer.print("    {s} =d cast {s}\n", .{ t, payload.text });
            break :blk .{ .text = t, .qtype = .d };
        },
        .none => .{ .text = "0", .qtype = .none },
    };
}

/// Bir dize LİTERALİNİ (kaynak kodda YAZILMIŞ bir `.string_lit` İÇİN
/// `genExpr` TARAFINDAN, ya da codegen'İN KENDİSİNİN sentezlediği sabit
/// bir mesaj İÇİN — bkz. `genParseOrRaise`, stdlib fazı §E — DOĞRUDAN)
/// `.data` bölümüne PINNED-refcount'lu bir dize olarak yayar, `str`
/// tipli bir `Value` döner. Bkz. modül üstü not (`PINNED_REFCOUNT`
/// hilesi) — `nox_rc_alloc`'un ürettüğü payload'larla AYNI temsili
/// TAŞIMALIDIR, aksi halde bu değer bir ARC release'e uğradığında
/// statik belleği bozardı.
pub fn emitStringLiteral(self: *Codegen, s: []const u8) CodegenError!Value {
    const sym = try std.fmt.allocPrint(self.allocator, "$str{d}", .{self.string_counter});
    self.string_counter += 1;
    const escaped = try escapeForQbeString(self.allocator, s);
    try self.string_data.append(self.allocator, .{ .symbol = sym, .escaped = escaped });
    const addr = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ addr, sym, ARC_HEADER_SIZE });
    return .{ .text = addr, .qtype = .l, .heap = .str };
}

/// Faz U.4.5 (bkz. `checker.zig`nin `checkExpr`'in `.identifier` dalı VE
/// `functions_used_as_value`in belge notu): `genExpr`nin `.identifier`
/// dalının, `self.vars`de BULUNAMAYAN bir isim İçin YEDEK inşası — üst-
/// düzey (non-generic) bir `def`, ÇAĞRI DIŞINDA bir DEĞER olarak
/// kullanılıyor OLABİLİR. Checker BUNU ZATEN `functions_used_as_value`e
/// KAYDEDİP `generateModule`nin `genFunctionValueTrampoline` GEÇİŞİNİN
/// (BU noktadan ÖNCE çalışır, bkz. onun çağrı sitesi) `$<isim>__fnval`/
/// `$<isim>__fnval_release`i ZATEN ÜRETMİŞ olmasını GARANTİ eder — burada
/// YALNIZCA `buildClosureValue`nin AYNI SIFIR-yakalama İnşa deseni (bkz.
/// onun belge notu) TEKRARLANIR.
///
/// **BİLİNÇLİ OLARAK `noinline` VE `genExpr`den AYRI bir fonksiyon:**
/// `checker.zig`nin `resolveIdentifierAsFunctionValue`iyle AYNI gerekçe
/// (bkz. onun belge notu) — `genExpr` de (`genBinary` ÜZERİNDEN)
/// ÖZYİNELEMELİDİR, bu YÜZDEN `.identifier` dalına YENİ yerel değişkenleri
/// DOĞRUDAN EKLEMEK `genExpr`nin HER özyinelemeli çağrısının çerçeve
/// boyutunu büyütüp DERİN (`.binary` ZİNCİRLERİ GİBİ) özyinelemelerde
/// YIĞIN-TAŞMASI RİSKİNİ ARTIRIRDI (bkz. checker.zig tarafında GERÇEKTEN
/// YAKALANAN AYNI sınıf hata — bir fuzz-regresyon testi).
pub noinline fn buildFunctionValueForIdentifier(self: *Codegen, name: []const u8) CodegenError!Value {
    const sig = self.functions.get(name) orelse return error.Unsupported;
    const trampoline_name = try std.fmt.allocPrint(self.allocator, "{s}__fnval", .{name});
    const block = try self.newTemp();
    try self.out.writer.print("    {s} =l call $nox_rc_alloc(l {s}, l {d})\n", .{ block, RT_PARAM, CLOSURE_HEADER_SIZE });
    try self.out.writer.print("    storel ${s}, {s}\n", .{ trampoline_name, block });
    const rel_addr = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ rel_addr, block, CLOSURE_RELEASE_FN_PTR_OFFSET });
    try self.out.writer.print("    storel ${s}_release, {s}\n", .{ trampoline_name, rel_addr });
    const fsig = try self.allocator.create(FuncSigInfo);
    fsig.* = .{ .params = sig.params, .ret = sig.ret };
    // `always_fresh = true`: `isAliasingExpr`in `.identifier => true` GENEL
    // kuralı (bkz. onun belge notu — normalde bir ÇIPLAK isim HER ZAMAN
    // VAR OLAN bir yereli/parametreyi ALIASLAR, bu YÜZDEN `retainIfAliasing`
    // bir retain EMİTİR) BURADA GEÇERSİZDİR — bu değer VAR OLAN hiçbir
    // şeyi ALIASLAMAZ, HER değerlendirmede TAZE inşa edilir (bir `.call`
    // GİBİ). `always_fresh` (`s[i]`nin AYNI mekanizması, bkz.
    // `retainIfAliasing`nin belge notu) BUNU `retainIfAliasing`e bildirir
    // — AKSİ HALDE GERÇEK bir ÇİFT-RETAIN/sızıntı OLUŞUR (test EDİLİP
    // BULUNDU).
    return .{ .text = block, .qtype = .l, .heap = .closure, .func_sig = fsig, .always_fresh = true };
}

pub fn genExpr(self: *Codegen, expr: ast.Expr) CodegenError!Value {
    return switch (expr) {
        .int_lit => |v| .{ .text = try std.fmt.allocPrint(self.allocator, "{d}", .{v}), .qtype = .l },
        .float_lit => |v| .{ .text = try std.fmt.allocPrint(self.allocator, "d_{d}", .{v}), .qtype = .d },
        .bool_lit => |v| .{ .text = if (v) "1" else "0", .qtype = .w },
        .string_lit => |s| try self.emitStringLiteral(s),
        .identifier => |name| blk: {
            const info = self.vars.get(name) orelse break :blk try self.buildFunctionValueForIdentifier(name);
            const t = try self.newTemp();
            try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ t, qbeTypeName(info.qtype), qbeTypeName(info.qtype), info.slot });
            // Faz FF.6.4: bkz. `narrowed_unbox`'ın belge notu — bu isim
            // ŞU AN daraltılmış bir kutulanmış Optional-ilkel İSE, kutu
            // POINTER'ı DEĞİL İÇİNDEKİ ham değer döndürülür.
            if (info.heap == .boxed_scalar and self.narrowed_unbox.contains(name)) {
                const payload = try self.newTemp();
                try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ payload, qbeTypeName(info.elem_qtype), qbeTypeName(info.elem_qtype), t });
                break :blk .{ .text = payload, .qtype = info.elem_qtype };
            }
            break :blk .{ .text = t, .qtype = info.qtype, .heap = info.heap, .elem_qtype = info.elem_qtype, .class_name = info.class_name, .elem_heap_info = info.elem_heap_info, .elem_is_str = info.elem_is_str, .dict_info = info.dict_info, .func_sig = info.func_sig, .arena = info.arena };
        },
        .unary => |u| try self.genUnary(u),
        .binary => |b| try self.genBinary(b),
        .call => |c| try self.genCall(c),
        .index => |idx| try self.genIndex(idx),
        .list_lit => |elems| try self.genListLit(elems),
        .dict_lit => |pairs| try self.genDictLit(pairs),
        .attribute => |a| try self.genFieldRead(a),
        .none_lit => error.Unsupported,
        // Faz 21 aşama 4 (bkz. nox-teknik-spesifikasyon.md §3.21):
        // `Task[T]`/`Channel[T]`in çalışma zamanı köprüsüne (bkz.
        // runtime/async_rt/bridge.zig) lowering.
        .await_expr => |operand| try self.genAwaitExpr(operand.*),
        .spawn_expr => |operand| try self.genSpawnExpr(operand.*),
        .generic_construct => |g| try self.genGenericConstruct(g),
    };
}

pub fn genFieldRead(self: *Codegen, a: ast.Attribute) CodegenError!Value {
    const obj = try self.genExpr(a.obj.*);
    if (obj.heap != .class) return error.Unsupported;
    const cinfo = self.classes.get(obj.class_name.?).?;
    for (cinfo.fields.items) |f| {
        if (!std.mem.eql(u8, f.name, a.attr)) continue;
        const addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ addr, obj.text, f.offset });
        const result = try self.newTemp();
        try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ result, qbeTypeName(f.info.qtype), qbeTypeName(f.info.qtype), addr });
        // `obj` TAZE bir değerse (ör. `make_car(i).engine`), okunan alanı
        // döndürmeden ÖNCE `obj`'yi serbest bırakırız (bkz.
        // `releaseIfTemporary`) — ama alanın KENDİSİ heap tipliyse (sınıf
        // YA DA list[T], bkz. görev "Sınıf alanı list[T] tipinde
        // olabilsin"), önce ONU retain etmeliyiz: aksi halde `obj`'nin
        // serbest bırakılması (özellikle refcount'u sıfıra düşüp `obj`
        // yok edilirse) bu alanı da özyinelemeli olarak serbest bırakabilir
        // (`genClassRelease`) — az önce okuduğumuz değeri kullanım-
        // sonrası-serbest-bırakmaya dönüştürür.
        if (isTemporaryExpr(a.obj.*) and isHeapManaged(f.info.heap)) {
            try self.emitInlineRetain(result);
        }
        try self.releaseIfTemporary(a.obj.*, obj);
        return .{ .text = result, .qtype = f.info.qtype, .heap = f.info.heap, .elem_qtype = f.info.elem_qtype, .class_name = f.info.class_name, .elem_heap_info = f.info.elem_heap_info, .elem_is_str = f.info.elem_is_str, .dict_info = f.info.dict_info, .func_sig = f.info.func_sig };
    }
    return error.Unsupported;
}

/// `genFieldRead`in AST-BAĞIMSIZ, BASİTLEŞTİRİLMİŞ çekirdeği — stdlib
/// fazı §D.1.6'nın `nox.http.serve` sarmalayıcısı (bkz.
/// `genHttpServeWrapper`), kullanıcının döndürdüğü bir `HttpResponse`
/// örneğinden (`ast.Expr`den DEĞİL, zaten hesaplanmış bir `Value`den)
/// `status`/`body`/`headers` alanlarını okumak İÇİN kullanır. `genFieldRead`in
/// AKSİNE `obj`i retain/release ETMEZ — sarmalayıcı `obj`nin (yanıt
/// örneğinin) TÜM YAŞAM DÖNGÜSÜNÜ kendisi yönetir (alanları okuduktan
/// SONRA `releaseValueIfSet` ile AÇIKÇA serbest bırakır), bu yüzden
/// `genFieldRead`in "taban taze bir geçiciyse ÖNCE retain et" dansına
/// GEREK YOKTUR.
pub fn genFieldReadFromValue(self: *Codegen, obj: Value, field_name: []const u8) CodegenError!Value {
    if (obj.heap != .class) return error.Unsupported;
    const cinfo = self.classes.get(obj.class_name.?).?;
    for (cinfo.fields.items) |f| {
        if (!std.mem.eql(u8, f.name, field_name)) continue;
        const addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ addr, obj.text, f.offset });
        const result = try self.newTemp();
        try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ result, qbeTypeName(f.info.qtype), qbeTypeName(f.info.qtype), addr });
        return .{ .text = result, .qtype = f.info.qtype, .heap = f.info.heap, .elem_qtype = f.info.elem_qtype, .class_name = f.info.class_name, .elem_heap_info = f.info.elem_heap_info, .elem_is_str = f.info.elem_is_str, .dict_info = f.info.dict_info, .func_sig = f.info.func_sig };
    }
    return error.Unsupported;
}

/// Faz GG.9: `idx`nin `genForRange`nin TESPİT ETTİĞİ (`bounds_elide_ctx`)
/// `for i in range(len(xs)): ... xs[i] ...` deseninin TAM İÇİNDE OLUP
/// OLMADIĞINI (isim BAZINDA, `idx.obj`/`idx.index` İKİSİ de BASİT birer
/// kimlik OLMALI) doğrular.
pub fn boundsElideApplies(self: *Codegen, idx: ast.Index) bool {
    if (idx.obj.* != .identifier or idx.index.* != .identifier) return false;
    const ctx = self.bounds_elide_ctx orelse return false;
    return std.mem.eql(u8, ctx.list_name, idx.obj.identifier) and std.mem.eql(u8, ctx.idx_var, idx.index.identifier);
}

pub fn genIndex(self: *Codegen, idx: ast.Index) CodegenError!Value {
    const obj = try self.genExpr(idx.obj.*);
    if (obj.heap == .dict) return self.genDictGet(obj, idx.index.*);
    if (obj.heap == .str) return self.genStrIndex(obj, idx);
    if (obj.heap != .list) return error.Unsupported;
    const index_v = try self.genExpr(idx.index.*);

    // Faz S.2: sınır kontrolü — `genStrIndex`in AYNI "önce doğrula, hata
    // dalında raise et, phi'SİZ ok'e atla" deseni (bkz. onun belge notu).
    // `list[T]`nin uzunluğu payload'ın İLK 8 baytıdır (bkz. `genListLit`),
    // bu yüzden AYRI bir betimleyiciye gerek yok — doğrudan `obj.text`ten
    // okunur. Faz GG.9: `xs[i]`, `genForRange`nin TESPİT ETTİĞİ `for i in
    // range(len(xs)): ...` deseninin TAM İÇİNDEYSE (bkz. `bounds_elide_ctx`)
    // bu kontrol TAMAMEN ATLANIR — `i`nin `[0, len(xs))` ARALIĞINDA
    // olduğu döngünün KENDİ sınırından ZATEN KANITLANMIŞTIR.
    if (!self.boundsElideApplies(idx)) {
        const len_t = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ len_t, obj.text });
        const neg_t = try self.newTemp();
        try self.out.writer.print("    {s} =w csltl {s}, 0\n", .{ neg_t, index_v.text });
        const oob_hi_t = try self.newTemp();
        try self.out.writer.print("    {s} =w csgel {s}, {s}\n", .{ oob_hi_t, index_v.text, len_t });
        const oob_t = try self.newTemp();
        try self.out.writer.print("    {s} =w or {s}, {s}\n", .{ oob_t, neg_t, oob_hi_t });
        const err_label = try self.newLabel("list_idx_err");
        const ok_label = try self.newLabel("list_idx_ok");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ oob_t, err_label, ok_label });
        try self.out.writer.print("{s}\n", .{err_label});

        const msg_value = try self.emitStringLiteral("liste indeksi sinirlarin disinda");
        const ie_cinfo = self.classes.get("IndexError") orelse return error.Unsupported;
        const ie_obj = try self.genConstructFromValues("IndexError", ie_cinfo, &.{msg_value});
        try self.out.writer.print("    call $nox_raise(l {s}, l {s})\n", .{ RT_PARAM, ie_obj.text });
        try self.emitExceptionCheck();
        try self.out.writer.print("    jmp {s}\n", .{ok_label});

        try self.out.writer.print("{s}\n", .{ok_label});
    }
    const byte_off = try self.newTemp();
    try self.out.writer.print("    {s} =l mul {s}, {d}\n", .{ byte_off, index_v.text, qbeSizeOf(obj.elem_qtype) });
    const off8 = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ off8, byte_off, LIST_HEADER_SIZE });
    const addr = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, {s}\n", .{ addr, obj.text, off8 });
    const result = try self.newTemp();
    try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ result, qbeTypeName(obj.elem_qtype), qbeTypeName(obj.elem_qtype), addr });
    // `list[T]`nin elemanları (Faz 21 ön-koşulundan beri) heap tipli
    // (sınıf/iç içe liste) OLABİLİR — okunan değer listenin İÇİNDEKİ bir
    // elemana ÖDÜNÇ ALINMIŞ bir referanstır (bu okuma BAŞLI BAŞINA retain
    // gerektirmez, tıpkı bir `.attribute` okuması gibi), ama `.heap`/
    // `.class_name`/`.elem_heap_info`nin DOĞRU taşınması, bu değerin
    // sonradan bir çağrıya argüman/başka bir listeye eleman olarak doğru
    // release edilebilmesi için GEREKLİDİR. `obj`'nin KENDİSİ taze bir
    // liste olabilir (ör. `make_list()[0]`), bu yüzden yine de serbest
    // bırakılmalıdır — ama `obj` TAZE VE eleman heap tipliyse (bkz.
    // `genFieldRead`'deki AYNI gerekçe), `obj`'yi serbest bırakmadan ÖNCE
    // okunan elemanı retain ETMELİYİZ: aksi halde `obj`'nin refcount'u
    // sıfıra düşüp (`releaseIfTemporary`) elemanları özyinelemeli olarak
    // serbest bırakırsa (`genListElemRelease`), az önce okuduğumuz
    // elemanı kullanım-sonrası-serbest-bırakmaya çeviririz.
    if (isTemporaryExpr(idx.obj.*) and obj.elem_heap_info != null) {
        try self.emitInlineRetain(result);
    }
    try self.releaseIfTemporary(idx.obj.*, obj);
    return valueFromElemDescriptor(result, obj.elem_qtype, obj.elem_heap_info, obj.elem_is_str);
}

/// `s[i]` — stdlib fazı §G. Sınır KONTROLÜ QBE'de yapılır (`strlen` +
/// karşılaştırma) — `genParseOrRaise`in AYNI "önce doğrula, hata
/// dalında raise et, `phi`SİZ `ok`e atla" deseni (bkz. onun belge
/// notu). Sonuç TEMEL diziden BAĞIMSIZ TAZE bir tahsistir (bkz.
/// `nox_str_char_at`in belge notu) — `list`/`dict` indekslemesinin
/// AKSİNE (o TABANIN İÇİNE bir takma addır), bu yüzden taban temporary
/// olsa BİLE ÖNCE retain etmeye GEREK YOKTUR, yalnızca SONRADAN
/// `releaseIfTemporary` ile tabanı serbest bırakmak yeterlidir.
pub fn genStrIndex(self: *Codegen, obj: Value, idx: ast.Index) CodegenError!Value {
    const index_v = try self.genExpr(idx.index.*);
    // Faz GG.9: `genForRange`nin TESPİT ETTİĞİ `for i in range(len(s)):
    // ... s[i] ...` deseninin TAM İÇİNDEYSE (bkz. `bounds_elide_ctx`)
    // sınır kontrolü TAMAMEN ATLANIR — `strlen`in KENDİSİ de (`len_t`
    // YALNIZCA bu kontrol İÇİN GEREKTİĞİNDEN, GG.5'in önbelleği DAHİL)
    // HİÇ HESAPLANMAZ.
    if (!self.boundsElideApplies(idx)) {
        // Faz GG.5: `idx.obj` döngü-değişmez, `str`-tipli bir kimlikse VE
        // enclosing döngü GİRİŞİ bunun İçin ÖNCEDEN bir codepoint sayımı
        // hesaplayıp önbelleğe ALDIYSA (bkz. `enterStrLenCacheScope`), o
        // TEK SEFERLİK hesaplanmış değer YENİDEN KULLANILIR — YENİ bir
        // çağrı ÜRETİLMEZ. Bulundu (bkz. proje belleği "UTF-8 farkındalığı"
        // görevi): burası ÖNCEDEN `strlen` (bayt sayısı) çağırıyordu —
        // `len()`in ARTIK codepoint saydığı (bkz. `calls.zig`nin `len`
        // dalı) yeni dünyada BU sınır kontrolü de AYNI miktarla (codepoint
        // sayısı) TUTARLI olmak ZORUNDA, aksi halde GG.9'un bounds-elision
        // varsayımı (`i`, `range(len(s))`ten codepoint sayısı kadar gelir)
        // BOZULUR.
        const len_t = if (idx.obj.* == .identifier and self.str_len_cache.get(idx.obj.identifier) != null)
            self.str_len_cache.get(idx.obj.identifier).?
        else blk: {
            const t = try self.newTemp();
            try self.out.writer.print("    {s} =l call $nox_str_char_count(l {s})\n", .{ t, obj.text });
            break :blk t;
        };
        const neg_t = try self.newTemp();
        try self.out.writer.print("    {s} =w csltl {s}, 0\n", .{ neg_t, index_v.text });
        const oob_hi_t = try self.newTemp();
        try self.out.writer.print("    {s} =w csgel {s}, {s}\n", .{ oob_hi_t, index_v.text, len_t });
        const oob_t = try self.newTemp();
        try self.out.writer.print("    {s} =w or {s}, {s}\n", .{ oob_t, neg_t, oob_hi_t });
        const err_label = try self.newLabel("str_idx_err");
        const ok_label = try self.newLabel("str_idx_ok");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ oob_t, err_label, ok_label });
        try self.out.writer.print("{s}\n", .{err_label});

        const msg_value = try self.emitStringLiteral("str indeksi sinirlarin disinda");
        const ie_cinfo = self.classes.get("IndexError") orelse return error.Unsupported;
        const ie_obj = try self.genConstructFromValues("IndexError", ie_cinfo, &.{msg_value});
        try self.out.writer.print("    call $nox_raise(l {s}, l {s})\n", .{ RT_PARAM, ie_obj.text });
        try self.emitExceptionCheck();
        try self.out.writer.print("    jmp {s}\n", .{ok_label});

        try self.out.writer.print("{s}\n", .{ok_label});
    }
    const result_t = try self.newTemp();
    // Bulundu (bkz. `Codegen.str_ascii_cache`nin belge notu, GERÇEK ölçüm:
    // `nox_str_char_at`in O(i) UTF-8 yürüyüşü YÜZÜNDEN `str_index_loop_
    // licm.nox` ~30 saniyeye çıktı) — `idx.obj` hoisted bir döngü
    // bağlamındaysa (`str_ascii_cache`de BİR KEZ hesaplanmış bir ASCII
    // bayrağı VARSA), çalışma-zamanı dallan: ASCII İSE ESKİ O(1) HAM bayt
    // erişimi İNLINE edilir (perf regresyonu YOK), DEĞİLSE doğru ama YAVAŞ
    // `nox_str_char_at`e düşülür. `phi`, `layout.zig`nin `idx_cur`ıyla AYNI
    // desen (döngü-taşınan/dallı bir SSA değeri İçin QBE'nin KENDİ aracı) —
    // her iki dal da DÜZ (İÇ İÇE başka blok AÇMAZ), bu yüzden `ascii_label`/
    // `unicode_label` phi'nin öncülleri olarak GÜVENLE kullanılabilir.
    if (idx.obj.* == .identifier and self.str_ascii_cache.get(idx.obj.identifier) != null) {
        const ascii_flag = self.str_ascii_cache.get(idx.obj.identifier).?;
        const ascii_label = try self.newLabel("str_idx_ascii");
        const unicode_label = try self.newLabel("str_idx_unicode");
        const done_label = try self.newLabel("str_idx_done");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ ascii_flag, ascii_label, unicode_label });

        try self.out.writer.print("{s}\n", .{ascii_label});
        const byte_addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {s}\n", .{ byte_addr, obj.text, index_v.text });
        const byte_val = try self.newTemp();
        try self.out.writer.print("    {s} =w loadub {s}\n", .{ byte_val, byte_addr });
        const ascii_result = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_rc_alloc(l {s}, l 2)\n", .{ ascii_result, RT_PARAM });
        try self.out.writer.print("    storeb {s}, {s}\n", .{ byte_val, ascii_result });
        const nul_addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, 1\n", .{ nul_addr, ascii_result });
        try self.out.writer.print("    storeb 0, {s}\n", .{nul_addr});
        try self.out.writer.print("    jmp {s}\n", .{done_label});

        try self.out.writer.print("{s}\n", .{unicode_label});
        const unicode_result = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_str_char_at(l {s}, l {s}, l {s})\n", .{ unicode_result, RT_PARAM, obj.text, index_v.text });
        try self.out.writer.print("    jmp {s}\n", .{done_label});

        try self.out.writer.print("{s}\n", .{done_label});
        try self.out.writer.print("    {s} =l phi {s} {s}, {s} {s}\n", .{ result_t, ascii_label, ascii_result, unicode_label, unicode_result });
    } else {
        try self.out.writer.print("    {s} =l call $nox_str_char_at(l {s}, l {s}, l {s})\n", .{ result_t, RT_PARAM, obj.text, index_v.text });
    }
    try self.releaseIfTemporary(idx.obj.*, obj);
    return .{ .text = result_t, .qtype = .l, .heap = .str, .always_fresh = true };
}

/// Faz P2.2: `genListLit`in `len=0` özel durumu — hedefin (bkz.
/// `genExprForTarget`in belge notu) `TypeInfo`sinden alınan `elem_qtype`/
/// `elem_heap_info`/`elem_is_str` İLE, `len=0, cap=0`lı BOŞ bir `list[T]`
/// tahsis eder (`genListLit`in dolu-liste yolunun AYNI başlık/kapasite
/// yazma deseni, yalnızca eleman döngüsü YOK).
fn genEmptyListLit(self: *Codegen, target: anytype) CodegenError!Value {
    const t = try self.newTemp();
    const arena = self.currentArena();
    if (arena) |ap| {
        try self.out.writer.print("    {s} =l call $nox_arena_alloc(l {s}, l {d})\n", .{ t, ap, LIST_HEADER_SIZE });
    } else {
        try self.out.writer.print("    {s} =l call $nox_rc_alloc(l {s}, l {d})\n", .{ t, RT_PARAM, LIST_HEADER_SIZE });
    }
    try self.out.writer.print("    storel 0, {s}\n", .{t});
    const cap_addr = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, 8\n", .{ cap_addr, t });
    try self.out.writer.print("    storel 0, {s}\n", .{cap_addr});
    return .{
        .text = t,
        .qtype = .l,
        .heap = .list,
        .elem_qtype = target.elem_qtype,
        .elem_heap_info = target.elem_heap_info,
        .elem_is_str = target.elem_is_str,
        .arena = arena != null,
    };
}

pub fn genListLit(self: *Codegen, elems: []const ast.Expr) CodegenError!Value {
    if (elems.len == 0) return error.Unsupported; // checker zaten reddeder; savunmacı

    // Darboğaz analizi (bkz. benchmarks/RESULTS.md, 2026-07-22): TÜM
    // elemanları derleme-zamanı sabiti olan literaller İçin, HER elemanı
    // AYRI bir "adres hesapla + store et" üçlüsüyle yazmak YERİNE tek
    // bir QBE `blit` İLE statik bir şablondan TOPLU kopyalamak DENENDİ
    // (bir SONRAKİ commit'te — bkz. git geçmişi) — ama ÖLÇÜLDÜĞÜNDE
    // GERÇEK bir REGRESYON olduğu bulundu: bu ARM64 hedefinde QBE'nin
    // `blit` lowering'i KAYNAK adresini HER 8-baytlık parça İçin
    // (`adrp`+`add`) YENİDEN hesaplıyor (BİR KEZ hesaplayıp yeniden
    // KULLANMAK YERİNE) — bu, "değeri DOĞRUDAN bir `mov`/`str` immediate
    // olarak gömmek" (AŞAĞIDAKİ, mevcut yaklaşım) İLE KIYASLANDIĞINDA
    // DAHA FAZLA talimat üretiyor. `list_traversal` A/B testinde:
    // blit'Lİ 71.4ms, blit'SİZ (bu kod) 59.8ms — ~%19 YAVAŞLAMA.
    // Bu, QBE'nin (harici bir araç, YAMALANAMAZ) KENDİ bir eksikliği —
    // Nox'un KENDİ IR üretimi DOĞRU olsa bile arka ucun lowering'i
    // rekabetçi DEĞİL. Değiştirilmeden BIRAKILDI.
    const values = try self.allocator.alloc(Value, elems.len);
    for (elems, 0..) |el, i| {
        const v0 = try self.genExpr(el);
        // checker.zig burada tip düzeyinde kısıtlamıyor (bir `list_lit`
        // ifadesinin kendisi, isimlendirilmiş bir `list[T]` bildirimi
        // gerektirmeden `list[Sınıf]` olarak da tiplenebilir). Faz 21
        // ön-koşulundan beri heap-yönetimli (sınıf/iç içe liste) elemanlar
        // da DESTEKLENİYOR — bkz. modül üstü not, `releaseValueIfSet`/
        // `genListElemRelease`. Bir isim ALIASI ise (`retainIfAliasing`)
        // retain edilir; `lowlevel` içindeyken bu, `checkNoLowlevelEscape`
        // aracılığıyla ZATEN reddedilir (mevcut, değişmemiş geniş kural).
        values[i] = try self.retainIfAliasing(el, v0);
    }
    const first = values[0];
    const elem_qtype = first.qtype;
    var elem_heap_info: ?*const ElemHeapInfo = null;
    // `str` DAHİL (bkz. `resolveType`in list dalındaki AYNI gerekçe,
    // stdlib fazı §B) — `list[str]` elemanlarının kapsam-sonu/yeniden
    // atamada özyinelemeli release'e girmesi için gerekli.
    // Faz U.4.5: `.closure` EKLENDİ — bkz. `resolveType`nin list dalındaki
    // AYNI gerekçe/belge notu (`stdlib/nox/router.nox`nin `list[(T)->U]`
    // alanları İçin — bu OLMADAN listenin KENDİSİ düşürüldüğünde eleman
    // closure'ları HİÇ serbest bırakılmazdı, GERÇEK bir sızıntı).
    if (first.heap == .class or first.heap == .list or first.heap == .str or first.heap == .closure) {
        const info = try self.allocator.create(ElemHeapInfo);
        info.* = .{ .heap = first.heap, .class_name = first.class_name, .elem_qtype = first.elem_qtype, .nested = first.elem_heap_info, .elem_is_str = first.elem_is_str, .func_sig = first.func_sig };
        elem_heap_info = info;
    }
    const elem_is_str = first.heap == .str;
    const elem_size = qbeSizeOf(elem_qtype);
    const payload_size = LIST_HEADER_SIZE + elem_size * elems.len;

    const t = try self.newTemp();
    const arena = self.currentArena();
    if (arena) |ap| {
        try self.out.writer.print("    {s} =l call $nox_arena_alloc(l {s}, l {d})\n", .{ t, ap, payload_size });
    } else {
        try self.out.writer.print("    {s} =l call $nox_rc_alloc(l {s}, l {d})\n", .{ t, RT_PARAM, payload_size });
    }
    try self.out.writer.print("    storel {d}, {s}\n", .{ elems.len, t });
    // Faz U.1: kapasite (@8) — bir literalden inşa edilen bir liste HER
    // ZAMAN tam-oturan başlar (kapasite=uzunluk, büyüme SLACK'i YOK) —
    // yalnızca `.append()` GEREKTİĞİNDE gerçek büyüme uygular.
    const cap_addr = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, 8\n", .{ cap_addr, t });
    try self.out.writer.print("    storel {d}, {s}\n", .{ elems.len, cap_addr });
    for (values, 0..) |v, i| {
        const off = LIST_HEADER_SIZE + elem_size * i;
        const addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ addr, t, off });
        try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(elem_qtype), v.text, addr });
    }
    return .{ .text = t, .qtype = .l, .heap = .list, .elem_qtype = elem_qtype, .elem_heap_info = elem_heap_info, .elem_is_str = elem_is_str, .arena = arena != null };
}

/// `genEmptyListLit`in AYNISI, `{}` (boş dict) İÇİN — `nox_dict_new`nin
/// KENDİSİ yalnızca `key_is_str`e ihtiyaç duyar (bkz. `dict.zig`, değer/
/// anahtar TİPİ çalışma zamanında hiç saklanmaz, salt derleme-zamanı bir
/// kavramdır) — bu YÜZDEN hedefin (bkz. `genExprForTarget`in belge notu)
/// `dict_info`sinden alınan `key_is_str` DIŞINDA hiçbir şeye gerek yoktur;
/// `nox_dict_set` HİÇ çağrılmaz (0 çift).
fn genEmptyDictLit(self: *Codegen, target: anytype) CodegenError!Value {
    const dinfo = target.dict_info.?;
    const key_is_str_lit: []const u8 = if (dinfo.key_is_str) "1" else "0";
    const d = try self.newTemp();
    try self.out.writer.print("    {s} =l call $nox_dict_new(l {s}, w {s})\n", .{ d, RT_PARAM, key_is_str_lit });
    return .{ .text = d, .qtype = .l, .heap = .dict, .dict_info = dinfo };
}

/// `{k1: v1, k2: v2, ...}` — `runtime/collections/dict.zig`nin
/// `nox_dict_new`/`nox_dict_set`ine lowerlanır (bkz. nox-teknik-
/// spesifikasyon.md §3.28). `dict`in KENDİSİ ARC-yönetimli DEĞİLDİR
/// (bkz. `HeapKind`in belge notu, `Task`/`Channel`le AYNI desen) — ama
/// `str` anahtar/değerler `retainIfAliasing` ile (list_lit İLE AYNI
/// desen) doğru şekilde retain edilir; `nox_dict_set` bunları OLDUĞU
/// GİBİ (ek bir retain OLMADAN) depolar — sahiplik ÇAĞIRANDAN (buradan)
/// devralınır.
pub fn genDictLit(self: *Codegen, pairs: []const ast.DictPair) CodegenError!Value {
    if (pairs.len == 0) return error.Unsupported; // checker zaten reddeder; savunmacı

    const key_values = try self.allocator.alloc(Value, pairs.len);
    const value_values = try self.allocator.alloc(Value, pairs.len);
    for (pairs, 0..) |p, i| {
        const k0 = try self.genExpr(p.key);
        try self.checkNoLowlevelEscape(k0);
        key_values[i] = try self.retainIfAliasing(p.key, k0);
        const v0 = try self.genExpr(p.value);
        try self.checkNoLowlevelEscape(v0);
        value_values[i] = try self.retainIfAliasing(p.value, v0);
    }
    const key_is_str = key_values[0].heap == .str;
    const value_is_str = value_values[0].heap == .str;
    const key_qtype = key_values[0].qtype;
    const value_qtype = value_values[0].qtype;

    const dinfo = try self.allocator.create(DictInfo);
    dinfo.* = .{ .key_is_str = key_is_str, .key_qtype = key_qtype, .value_qtype = value_qtype, .value_is_str = value_is_str };

    const key_is_str_lit: []const u8 = if (key_is_str) "1" else "0";
    const value_is_str_lit: []const u8 = if (value_is_str) "1" else "0";

    const d = try self.newTemp();
    try self.out.writer.print("    {s} =l call $nox_dict_new(l {s}, w {s})\n", .{ d, RT_PARAM, key_is_str_lit });

    for (key_values, 0..) |kv, i| {
        const key_payload = try self.toPayload(kv);
        const value_payload = try self.toPayload(value_values[i]);
        try self.out.writer.print("    call $nox_dict_set(l {s}, l {s}, w {s}, w {s}, l {s}, l {s})\n", .{ RT_PARAM, d, key_is_str_lit, value_is_str_lit, key_payload.text, value_payload.text });
    }

    return .{ .text = d, .qtype = .l, .heap = .dict, .dict_info = dinfo };
}

pub fn genUnary(self: *Codegen, u: ast.Unary) CodegenError!Value {
    const operand = try self.genExpr(u.operand.*);
    return switch (u.op) {
        .neg => blk: {
            const t = try self.newTemp();
            try self.out.writer.print("    {s} ={s} neg {s}\n", .{ t, qbeTypeName(operand.qtype), operand.text });
            break :blk .{ .text = t, .qtype = operand.qtype };
        },
        .not_ => blk: {
            const t = try self.newTemp();
            try self.out.writer.print("    {s} =w xor {s}, 1\n", .{ t, operand.text });
            break :blk .{ .text = t, .qtype = .w };
        },
    };
}

pub fn emitBin(self: *Codegen, mnemonic: []const u8, l: Value, r: Value, result_qtype: QbeType) CodegenError!Value {
    const t = try self.newTemp();
    try self.out.writer.print("    {s} ={s} {s} {s}, {s}\n", .{ t, qbeTypeName(result_qtype), mnemonic, l.text, r.text });
    return .{ .text = t, .qtype = result_qtype };
}

pub fn emitCmp(self: *Codegen, op: ast.BinaryOp, l: Value, r: Value, common: QbeType) CodegenError!Value {
    const t = try self.newTemp();
    try self.out.writer.print("    {s} =w {s} {s}, {s}\n", .{ t, cmpMnemonic(op, common), l.text, r.text });
    return .{ .text = t, .qtype = .w };
}

pub fn callLibm1(self: *Codegen, comptime name: []const u8, v: Value) CodegenError!Value {
    const t = try self.newTemp();
    try self.out.writer.print("    {s} =d call ${s}(d {s})\n", .{ t, name, v.text });
    return .{ .text = t, .qtype = .d };
}

pub fn callLibm2(self: *Codegen, comptime name: []const u8, l: Value, r: Value) CodegenError!Value {
    const t = try self.newTemp();
    try self.out.writer.print("    {s} =d call ${s}(d {s}, d {s})\n", .{ t, name, l.text, r.text });
    return .{ .text = t, .qtype = .d };
}

/// `strcmp` (libc, `cc` bağlantısında zaten mevcut — `printf` gibi başka
/// çağrılarla AYNI şekilde ekstra bir bağlama argümanı gerekmez) ile iki
/// `str`in İÇERİĞİNİ karşılaştırır; sonucu `0`a karşı `w` bir bool'a çevirir.
pub fn genStrCompare(self: *Codegen, op: ast.BinaryOp, l: Value, r: Value) CodegenError!Value {
    const cmp_t = try self.newTemp();
    try self.out.writer.print("    {s} =w call $strcmp(l {s}, l {s})\n", .{ cmp_t, l.text, r.text });
    const result = try self.newTemp();
    const mnemonic: []const u8 = if (op == .eq) "ceqw" else "cnew";
    try self.out.writer.print("    {s} =w {s} {s}, 0\n", .{ result, mnemonic, cmp_t });
    return .{ .text = result, .qtype = .w };
}

pub fn genBinary(self: *Codegen, b: ast.Binary) CodegenError!Value {
    // Darboğaz analizi bulgu #3 (bkz. `Codegen.mod_cache`nin belge
    // notu): `<isim> % <tam-sayı-sabiti>` İçin ÖNCE önbelleğe bak —
    // İSABET varsa `l0`/`r0`yı HİÇ üretmeden (döngü/koşul İfadesinin
    // KENDİSİ dahil, `identifier`in okunması bile ATLANIR) doğrudan
    // ÖNCEKİ SONUCU döndürür.
    if (b.op == .mod and b.left.* == .identifier and b.right.* == .int_lit) {
        if (self.vars.get(b.left.identifier)) |vi| {
            if (vi.heap == .none and vi.qtype != .d) {
                const key = try modCacheKey(self.allocator, vi.slot, b.right.int_lit);
                if (self.mod_cache.get(key)) |entry| {
                    return .{ .text = entry.text, .qtype = entry.qtype };
                }
            }
        }
    }
    if (b.op == .and_ or b.op == .or_) {
        const l = try self.genExpr(b.left.*);
        const r = try self.genExpr(b.right.*);
        const mnemonic: []const u8 = if (b.op == .and_) "and" else "or";
        return self.emitBin(mnemonic, l, r, .w);
    }

    // Faz FF.6 (bkz. nox-teknik-spesifikasyon.md §3.65): `x != None` /
    // `x == None` — checker'ın narrowing'in ÖN KOŞULU olarak KABUL
    // ETTİĞİ TEK örüntü (bkz. `checkBinary`in `.eq, .ne` dalı VE
    // `Checker.detectNarrowing`). `.none_lit`in KENDİSİ `genExpr`den
    // GEÇİRİLMEZ (o hâlâ koşulsuz `error.Unsupported` döner) — DİĞER
    // taraf ÜRETİLİR VE doğrudan `0` (null pointer sentinel) İLE
    // karşılaştırılır; Optional'ın çalışma zamanı temsili taban HEAP
    // tiple AYNI OLDUĞUNDAN (bkz. `resolveType`in `.optional` dalı) bu
    // `_eq`/`strcmp` GEREKTİRMEYEN, basit bir işaretçi karşılaştırmasıdır.
    if ((b.op == .eq or b.op == .ne) and (b.left.* == .none_lit or b.right.* == .none_lit)) {
        const other_expr: ast.Expr = if (b.left.* == .none_lit) b.right.* else b.left.*;
        const other = try self.genExpr(other_expr);
        const cmp_t = try self.newTemp();
        const mnemonic: []const u8 = if (b.op == .eq) "ceql" else "cnel";
        try self.out.writer.print("    {s} =w {s} {s}, 0\n", .{ cmp_t, mnemonic, other.text });
        try self.releaseIfTemporary(other_expr, other);
        return .{ .text = cmp_t, .qtype = .w };
    }

    const l0 = try self.genExpr(b.left.*);
    const r0 = try self.genExpr(b.right.*);

    // `str == str` / `str != str` — GERÇEK içerik karşılaştırması
    // (`strcmp`, çünkü `str` her zaman sıfırla-sonlanan bir C dizesidir).
    // checker.zig zaten yalnızca `==`/`!=`i (ve yalnızca AYNI tipteki iki
    // tarafı) buraya kadar geçirir (bkz. `checkBinary`in `.eq, .ne`
    // dalı). **Düzeltme (stdlib fazı §H'de BULUNAN gerçek bir sızıntı):**
    // bu dalın ESKİ belge notu "str HİÇBİR ZAMAN ARC-yönetimli değildir"
    // diyordu — bu, Alt-Faz B'nin `str`i ARC-yönetimli YAPMASINDAN
    // ÖNCEKİ bir varsayımdı, ASLA güncellenmemişti. Operandlardan biri
    // TEMPORARY ise (ör. `s[i] != prefix[j]` — Alt-Faz G'nin `s[i]`si,
    // YA DA `(a + b) == c` gibi bir concat sonucu) SERBEST BIRAKILMASI
    // GEREKİR — `list`/`class` eşitlik dalıyla (aşağı) VE `str + str`
    // dalıyla (aşağı) AYNI desen.
    if (l0.heap == .str and r0.heap == .str and (b.op == .eq or b.op == .ne)) {
        const result = try self.genStrCompare(b.op, l0, r0);
        try self.releaseIfTemporary(b.left.*, l0);
        try self.releaseIfTemporary(b.right.*, r0);
        return result;
    }

    // `list[T] == list[T]` / `sınıf == sınıf` — ÖZYİNELEMELİ yapısal
    // karşılaştırma (bkz. görev "list/class için derin yapısal eşitlik",
    // `genClassEq`/`genListEq`). checker zaten yalnızca AYNI (iç içe)
    // tipteki iki tarafı buraya kadar geçirir (`types.eql`, bkz.
    // `checkBinary`in `.eq, .ne` dalı) — bu yüzden `l0`nin
    // betimleyicileri (`class_name`/`elem_*`) `r0` için de geçerlidir.
    // Operandlar `lowlevel` arenasından gelemez (aşağıdaki
    // `checkNoLowlevelEscape` ile AYNI geniş kural, bkz. modül üstü not) —
    // bir arena işaretçisini `$..._eq`e ARGÜMAN olarak geçirmek de
    // "çağrıya argüman" kısıtlamasına girer. `l0`/`r0`nin KENDİLERİ
    // (bir DEĞİŞKENE bağlı tam liste/sınıf DEĞERLERİ, bir ALAN/ELEMAN
    // DEĞİL) hiçbir zaman null OLAMAZ — bu yüzden `genEqCompareOrJump`'ın
    // alan/eleman-seviyesi null-güvenliği burada GEREKMEZ; `$..._eq`
    // DOĞRUDAN çağrılır.
    if ((l0.heap == .list or l0.heap == .class) and r0.heap == l0.heap and (b.op == .eq or b.op == .ne)) {
        try self.checkNoLowlevelEscape(l0);
        try self.checkNoLowlevelEscape(r0);
        const eq_temp = try self.newTemp();
        if (l0.heap == .class) {
            try self.out.writer.print("    {s} =w call ${s}_eq(l {s}, l {s}, l {s})\n", .{ eq_temp, l0.class_name.?, RT_PARAM, l0.text, r0.text });
        } else {
            const fn_name = try self.eqFnNameForList(l0.elem_qtype, l0.elem_heap_info, l0.elem_is_str);
            try self.out.writer.print("    {s} =w call ${s}_eq(l {s}, l {s}, l {s})\n", .{ eq_temp, fn_name, RT_PARAM, l0.text, r0.text });
        }
        const result: []const u8 = if (b.op == .ne) blk: {
            const t = try self.newTemp();
            try self.out.writer.print("    {s} =w xor {s}, 1\n", .{ t, eq_temp });
            break :blk t;
        } else eq_temp;
        try self.releaseIfTemporary(b.left.*, l0);
        try self.releaseIfTemporary(b.right.*, r0);
        return .{ .text = result, .qtype = .w };
    }

    // `str + str` — YENİ bir birleştirilmiş dize üretir (stdlib fazı §B,
    // bkz. `runtime/str.zig`). checker zaten yalnızca iki tarafı da
    // `str` olan bir `+`i buraya kadar geçirir (`checkBinary`in `.add`
    // dalı). Sonuç TAZE bir heap değeridir (refcount 1 ile başlar) —
    // `.call` sonucuyla AYNI şekilde ele alınır (bkz. `isTemporaryExpr`in
    // `.binary` dalı).
    if (l0.heap == .str and r0.heap == .str and b.op == .add) {
        try self.checkNoLowlevelEscape(l0);
        try self.checkNoLowlevelEscape(r0);
        const result_t = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_str_concat(l {s}, l {s}, l {s})\n", .{ result_t, RT_PARAM, l0.text, r0.text });
        try self.releaseIfTemporary(b.left.*, l0);
        try self.releaseIfTemporary(b.right.*, r0);
        return .{ .text = result_t, .qtype = .l, .heap = .str };
    }

    // list[T]/sınıf içerik karşılaştırması yalnızca `==`/`!=` içindir —
    // başka bir ikili operatör (`<`, `+`, ...) heap tipli bir işlenenle
    // hâlâ reddedilir (checker zaten bunu sayısal/bool tiplerle
    // sınırlar, burası savunmacıdır).
    if (l0.heap != .none or r0.heap != .none) return error.Unsupported;

    if (b.op == .div) {
        const l = try self.convert(l0, .d);
        const r = try self.convert(r0, .d);
        return self.emitBin("div", l, r, .d);
    }

    const common: QbeType = if (l0.qtype == .d or r0.qtype == .d)
        .d
    else if (l0.qtype == .w or r0.qtype == .w)
        .w
    else
        .l;
    const l = try self.convert(l0, common);
    const r = try self.convert(r0, common);

    return switch (b.op) {
        .add => self.emitBin("add", l, r, common),
        .sub => self.emitBin("sub", l, r, common),
        .mul => self.emitBin("mul", l, r, common),
        .floordiv => self.genFloorDiv(l, r, common),
        .mod => blk: {
            const result = try self.genMod(l, r, common);
            // Bkz. genBinary'nin BAŞINDAKİ önbellek KONTROLÜYLE eşleşen
            // desen — YALNIZCA AYNI şekle (`isim % tam-sayı-sabiti`)
            // SAHİPSE popüle edilir.
            if (b.left.* == .identifier and b.right.* == .int_lit) {
                if (self.vars.get(b.left.identifier)) |vi| {
                    if (vi.heap == .none and vi.qtype != .d) {
                        const key = try modCacheKey(self.allocator, vi.slot, b.right.int_lit);
                        try self.mod_cache.put(self.allocator, key, .{ .text = result.text, .qtype = result.qtype });
                    }
                }
            }
            break :blk result;
        },
        .pow => self.genPow(l, r, common),
        .eq, .ne, .lt, .le, .gt, .ge => self.emitCmp(b.op, l, r, common),
        .div, .and_, .or_ => unreachable,
    };
}

pub fn genFloorDiv(self: *Codegen, l: Value, r: Value, common: QbeType) CodegenError!Value {
    if (common == .d) {
        const divided = try self.emitBin("div", l, r, .d);
        return self.callLibm1("floor", divided);
    }

    const q = try self.emitBin("div", l, r, .l);
    const rem = try self.emitBin("rem", l, r, .l);

    const rem_nonzero = try self.newTemp();
    try self.out.writer.print("    {s} =w cnel {s}, 0\n", .{ rem_nonzero, rem.text });
    const rem_neg = try self.newTemp();
    try self.out.writer.print("    {s} =w csltl {s}, 0\n", .{ rem_neg, rem.text });
    const r_neg = try self.newTemp();
    try self.out.writer.print("    {s} =w csltl {s}, 0\n", .{ r_neg, r.text });
    const sign_diff = try self.newTemp();
    try self.out.writer.print("    {s} =w xor {s}, {s}\n", .{ sign_diff, rem_neg, r_neg });
    const need_adjust = try self.newTemp();
    try self.out.writer.print("    {s} =w and {s}, {s}\n", .{ need_adjust, rem_nonzero, sign_diff });

    // Dallanma/yığın yuvası KULLANMADAN (bkz. `adjustModSign`'daki aynı
    // gerekçe) `need_adjust`i (0 ya da 1) `l`ye genişletip bölümden
    // çıkarırız — 0 ise değişiklik yok, 1 ise bir eksiltilmiş olur.
    const mask = try self.newTemp();
    try self.out.writer.print("    {s} =l extuw {s}\n", .{ mask, need_adjust });
    const result = try self.newTemp();
    try self.out.writer.print("    {s} =l sub {s}, {s}\n", .{ result, q.text, mask });
    return .{ .text = result, .qtype = .l };
}

pub fn genPow(self: *Codegen, l: Value, r: Value, common: QbeType) CodegenError!Value {
    const lf = try self.convert(l, .d);
    const rf = try self.convert(r, .d);
    const t = try self.newTemp();
    try self.out.writer.print("    {s} =d call $pow(d {s}, d {s})\n", .{ t, lf.text, rf.text });
    const result: Value = .{ .text = t, .qtype = .d };
    if (common == .l) return self.convert(result, .l);
    return result;
}

/// `print(<ifade>)`in tek giriş noktası. `list[T]`/sınıf İÇİN
/// `genPrintFragment`e (özyineli, tırnaksız-OLMAYAN `str` biçimi — bkz.
/// onun belge notu) yönlenip bir satır sonu ekler; değer tipleri İÇİN
/// (Python'un `print()`i `str()` kullanır, `repr()` DEĞİL — bu yüzden en
/// dıştaki bir `str` TIRNAKSIZ basılır, `genPrintFragment`in `str_frag`
/// biçiminden BİLEREK FARKLI) DEĞİŞMEMİŞ eski (satır-sonu dahil) format
/// sabitlerini kullanır.
pub fn genPrint(self: *Codegen, v: Value) CodegenError!void {
    if (v.heap == .list or v.heap == .class) {
        try self.genPrintFragment(v);
        try self.out.writer.writeAll("    call $printf(l $fmt_newline)\n");
        return;
    }
    switch (v.qtype) {
        .l => if (v.heap == .str)
            try self.out.writer.print("    call $printf(l $fmt_str, ..., l {s})\n", .{v.text})
        else
            try self.out.writer.print("    call $printf(l $fmt_int, ..., l {s})\n", .{v.text}),
        .d => try self.out.writer.print("    call $printf(l $fmt_float, ..., d {s})\n", .{v.text}),
        .w => {
            const true_label = try self.newLabel("print_true");
            const false_label = try self.newLabel("print_false");
            const done_label = try self.newLabel("print_done");
            try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ v.text, true_label, false_label });
            try self.out.writer.print("{s}\n", .{true_label});
            try self.out.writer.writeAll("    call $printf(l $fmt_bool_true)\n");
            try self.out.writer.print("    jmp {s}\n", .{done_label});
            try self.out.writer.print("{s}\n", .{false_label});
            try self.out.writer.writeAll("    call $printf(l $fmt_bool_false)\n");
            try self.out.writer.print("    jmp {s}\n", .{done_label});
            try self.out.writer.print("{s}\n", .{done_label});
        },
        .none => return error.Unsupported,
    }
}

/// `v`yi satır SONU OLMADAN basar — `list[T]`/sınıf görüntülemesi (bkz.
/// görev "print(list)/print(class) görüntüleme biçimi") ÖZYİNELEMELİDİR
/// (bir listenin/sınıfın elemanı/alanı yine bir liste/sınıf olabilir);
/// yalnızca en dıştaki `genPrint` çağrısı bir satır sonu ekler.
pub fn genPrintFragment(self: *Codegen, v: Value) CodegenError!void {
    if (v.heap == .list) return self.genPrintList(v);
    if (v.heap == .class) return self.genPrintClass(v);
    switch (v.qtype) {
        .l => if (v.heap == .str)
            try self.out.writer.print("    call $printf(l $fmt_str_frag, ..., l {s})\n", .{v.text})
        else
            try self.out.writer.print("    call $printf(l $fmt_int_frag, ..., l {s})\n", .{v.text}),
        .d => try self.out.writer.print("    call $printf(l $fmt_float_frag, ..., d {s})\n", .{v.text}),
        .w => {
            const true_label = try self.newLabel("print_true");
            const false_label = try self.newLabel("print_false");
            const done_label = try self.newLabel("print_done");
            try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ v.text, true_label, false_label });
            try self.out.writer.print("{s}\n", .{true_label});
            try self.out.writer.writeAll("    call $printf(l $fmt_bool_true_frag)\n");
            try self.out.writer.print("    jmp {s}\n", .{done_label});
            try self.out.writer.print("{s}\n", .{false_label});
            try self.out.writer.writeAll("    call $printf(l $fmt_bool_false_frag)\n");
            try self.out.writer.print("    jmp {s}\n", .{done_label});
            try self.out.writer.print("{s}\n", .{done_label});
        },
        .none => return error.Unsupported,
    }
}

/// Derleme zamanında bilinen (kullanıcı verisi İÇERMEYEN — yalnızca sınıf/
/// alan adları gibi kaynak-kodu metinleri) sabit bir metni `printf`e
/// FORMAT dizesi olarak geçirilebilecek bir `data` sembolüne dönüştürür.
/// Normal `str` literallerinden (`string_data`) FARKLI: burada üretilen
/// sembol ARC'ın "pinned refcount" başlığını TAŞIMAZ (bu metin hiçbir
/// zaman bir Nox `str` DEĞERİ olarak dolaşmaz, yalnızca `printf`in İLK
/// argümanı olarak kullanılır) — bu yüzden `.string_lit`in aksine `+8`
/// ofsetlemesi GEREKMEZ.
pub fn internFmtString(self: *Codegen, text: []const u8) CodegenError![]const u8 {
    const sym = try std.fmt.allocPrint(self.allocator, "$fmt_lit{d}", .{self.fmt_counter});
    self.fmt_counter += 1;
    const escaped = try escapeForQbeString(self.allocator, text);
    try self.fmt_data.append(self.allocator, .{ .symbol = sym, .escaped = escaped });
    return sym;
}

/// `list[T]` görüntülemesi — Python'un `repr([...])`ine benzer:
/// `[e1, e2, ...]`, elemanlar `genPrintFragment` ile ÖZYİNELEMELİ basılır
/// (bir liste elemanı yine bir liste/sınıf olabilir). Liste UZUNLUĞU
/// yalnızca ÇALIŞMA ZAMANINDA bilindiğinden (derleme zamanında sabit bir
/// format dizesi ÇÖZÜLEMEZ), `genForList`/`genListElemRelease` ile AYNI
/// güvenli döngü desenini (FONKSİYON GİRİŞİNDE bir kez `alloc8`) kullanır.
pub fn genPrintList(self: *Codegen, v: Value) CodegenError!void {
    try self.out.writer.writeAll("    call $printf(l $fmt_lbracket)\n");

    const len_t = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ len_t, v.text });
    const idx_slot = try self.newTemp();
    try self.out.writer.print("    {s} =l alloc8 8\n", .{idx_slot});
    try self.out.writer.print("    storel 0, {s}\n", .{idx_slot});

    const cond_label = try self.newLabel("printlist_cond");
    const body_label = try self.newLabel("printlist_body");
    const end_label = try self.newLabel("printlist_end");
    try self.out.writer.print("    jmp {s}\n", .{cond_label});
    try self.out.writer.print("{s}\n", .{cond_label});
    const idx_cur = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ idx_cur, idx_slot });
    const cont = try self.newTemp();
    try self.out.writer.print("    {s} =w csltl {s}, {s}\n", .{ cont, idx_cur, len_t });
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ cont, body_label, end_label });
    try self.out.writer.print("{s}\n", .{body_label});

    const not_first = try self.newTemp();
    try self.out.writer.print("    {s} =w cnel {s}, 0\n", .{ not_first, idx_cur });
    const comma_label = try self.newLabel("printlist_comma");
    const skip_comma_label = try self.newLabel("printlist_skipcomma");
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ not_first, comma_label, skip_comma_label });
    try self.out.writer.print("{s}\n", .{comma_label});
    try self.out.writer.writeAll("    call $printf(l $fmt_comma_sp)\n");
    try self.out.writer.print("    jmp {s}\n", .{skip_comma_label});
    try self.out.writer.print("{s}\n", .{skip_comma_label});

    const off = try self.newTemp();
    try self.out.writer.print("    {s} =l mul {s}, {d}\n", .{ off, idx_cur, qbeSizeOf(v.elem_qtype) });
    const off8 = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ off8, off, LIST_HEADER_SIZE });
    const addr = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, {s}\n", .{ addr, v.text, off8 });
    const elem = try self.newTemp();
    try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ elem, qbeTypeName(v.elem_qtype), qbeTypeName(v.elem_qtype), addr });
    try self.genPrintFragment(valueFromElemDescriptor(elem, v.elem_qtype, v.elem_heap_info, v.elem_is_str));

    const idx_next = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, 1\n", .{ idx_next, idx_cur });
    try self.out.writer.print("    storel {s}, {s}\n", .{ idx_next, idx_slot });
    try self.out.writer.print("    jmp {s}\n", .{cond_label});
    try self.out.writer.print("{s}\n", .{end_label});

    try self.out.writer.writeAll("    call $printf(l $fmt_rbracket)\n");
}

/// Sınıf görüntülemesi — `ClassName(alan1=değer1, alan2=değer2, ...)`.
/// Alan sayısı/adları/tipleri derleme zamanında SABİTTİR (`cinfo.fields`),
/// bu yüzden döngü GEREKMEZ — ama alan DEĞERLERİ (özellikle iç içe
/// sınıf/`list[T]` alanları) `genPrintFragment` ile ÖZYİNELEMELİ basılır.
pub fn genPrintClass(self: *Codegen, v: Value) CodegenError!void {
    const class_name = v.class_name.?;
    const cinfo = self.classes.get(class_name).?;
    const open_sym = try self.internFmtString(try std.fmt.allocPrint(self.allocator, "{s}(", .{class_name}));
    try self.out.writer.print("    call $printf(l {s})\n", .{open_sym});
    for (cinfo.fields.items, 0..) |f, i| {
        if (i != 0) try self.out.writer.writeAll("    call $printf(l $fmt_comma_sp)\n");
        const name_sym = try self.internFmtString(try std.fmt.allocPrint(self.allocator, "{s}=", .{f.name}));
        try self.out.writer.print("    call $printf(l {s})\n", .{name_sym});
        const addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ addr, v.text, f.offset });
        const fv = try self.newTemp();
        try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ fv, qbeTypeName(f.info.qtype), qbeTypeName(f.info.qtype), addr });
        try self.genPrintFragment(.{ .text = fv, .qtype = f.info.qtype, .heap = f.info.heap, .elem_qtype = f.info.elem_qtype, .class_name = f.info.class_name, .elem_heap_info = f.info.elem_heap_info, .elem_is_str = f.info.elem_is_str });
    }
    try self.out.writer.writeAll("    call $printf(l $fmt_rparen)\n");
}
