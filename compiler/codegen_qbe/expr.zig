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
const layout = @import("layout.zig");
const calls = @import("calls.zig");

const Codegen = codegen.Codegen;
const Value = types.Value;
const QbeType = types.QbeType;
const HeapKind = types.HeapKind;
const ElemHeapInfo = types.ElemHeapInfo;
const NameList = @import("stmt.zig").NameList;
const DictInfo = types.DictInfo;
const RT_PARAM = types.RT_PARAM;
const TAG_SIZE = types.TAG_SIZE;
const LIST_HEADER_SIZE = types.LIST_HEADER_SIZE;
const ARC_HEADER_SIZE = types.ARC_HEADER_SIZE;
const STR_HEADER_SIZE = types.STR_HEADER_SIZE;
const packStrHeader = types.packStrHeader;
const STR_ASCII_TRUE = types.STR_ASCII_TRUE;
const CLOSURE_HEADER_SIZE = types.CLOSURE_HEADER_SIZE;
const CLOSURE_RELEASE_FN_PTR_OFFSET = types.CLOSURE_RELEASE_FN_PTR_OFFSET;
const FuncSigInfo = types.FuncSigInfo;
const CodegenError = abi.CodegenError;
const qbeSizeOf = abi.qbeSizeOf;
const cmpMnemonic = abi.cmpMnemonic;
const isHeapManaged = abi.isHeapManaged;
const isTemporaryExpr = abi.isTemporaryExpr;
const valueFromElemDescriptor = abi.valueFromElemDescriptor;
const escapeForQbeString = abi.escapeForQbeString;
const modCacheKey = optimizations.modCacheKey;
const classEqInlineEligible = layout.classEqInlineEligible;

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
    // Faz F.3 (bkz. plan dosyası "Dil uzantısı: 'lowlevel:'in 'manuel
    // katman'a genişletilmesi"): `adopt(p)`nin dönüş DEĞERİ (`.none_lit`in
    // AYNI, ZATEN kanıtlanmış "hedefin ÇÖZÜLMÜŞ TypeInfo'sunu KULLAN"
    // deseni) — checker'ın `UnknownType`i BU durumu ZATEN DERLEME-
    // ZAMANINDA elediğinden, bu dal YALNIZCA savunmacı bir GÜVENLİK
    // AĞIdır.
    if (expr == .call and expr.call.callee.* == .identifier and std.mem.eql(u8, expr.call.callee.identifier, "adopt")) {
        if (self.in_lowlevel_depth == 0) return error.Unsupported;
        const p = try self.genExpr(expr.call.args[0]);
        return .{
            .text = p.text,
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
    try self.qbeCall(.{ .name = box, .ty = .l }, "$nox_rc_alloc", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = "8" } });
    try self.qbeStore(elem_qtype, v.text, box);
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

pub fn convert(self: *Codegen, v: Value, target_in: QbeType) CodegenError!Value {
    // `.b` (bool eleman DEPOLAMA tipi) bir DEĞER tipi değildir — değer `.w`dir.
    const target: QbeType = abi.elemValueQtype(target_in);
    if (v.qtype == target) return v;
    if (v.qtype == .l and target == .d) {
        const t = try self.newTemp();
        try self.qbeOp1(t, .d, "sltof", v.text);
        return .{ .text = t, .qtype = .d };
    }
    if (v.qtype == .d and target == .l) {
        const t = try self.newTemp();
        try self.qbeOp1(t, .l, "dtosi", v.text);
        return .{ .text = t, .qtype = .l, .fixed_int = v.fixed_int };
    }
    // v2.0 madde 4: `u8`/`i16`/vb. gibi `.w`de hesaplanan sabit-genişlikli
    // kind'lerin literal/`int`-kaynaklı değerleri `genExpr` yolundan HER
    // ZAMAN `.l` (int'in DOĞAL kayıt sınıfı) olarak gelir — `fromPayload`in
    // AYNI, ZATEN kanıtlanmış `copy` deseniyle DÜŞÜK 32 bite daraltılır
    // (aralık kontrolü BURADAN ÖNCE, `checkExprExpected`/`fitsValue`
    // İLE derleme-zamanında ZATEN yapıldı).
    if (v.qtype == .l and target == .w) {
        const t = try self.newTemp();
        try self.qbeOp1(t, .w, "copy", v.text);
        return .{ .text = t, .qtype = .w, .fixed_int = v.fixed_int };
    }
    // v2.0 madde 4: `'/'`in HER ZAMAN `.float` dönmesi (checker'ın
    // `.div` dalı) — `.w`de hesaplanan sabit-genişlikli bir kind (u8/i8/
    // u16/i16/u32/i32) İçİn ÖNCE `.l`ye (işaretliliğe göre `extsw`/
    // `extuw`, `v.fixed_int` doluysa ONA göre, aksi halde (BURAYA HİÇ
    // ULAŞMAMASI GEREKEN `bool`, savunmacı) işaretli varsayılır) genişletip
    // SONRA `sltof` İLE `.d`ye çevrilir.
    if (v.qtype == .w and target == .d) {
        const signed = if (v.fixed_int) |k| k.isSigned() else true;
        const widened = try self.newTemp();
        try self.qbeOp1(widened, .l, if (signed) "extsw" else "extuw", v.text);
        const t = try self.newTemp();
        try self.qbeOp1(t, .d, "sltof", widened);
        return .{ .text = t, .qtype = .d };
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
        .w, .b, .sb, .h, .sh => blk: {
            const t = try self.newTemp();
            try self.qbeOp1(t, .l, "extuw", v.text);
            break :blk .{ .text = t, .qtype = .l };
        },
        .d => blk: {
            const t = try self.newTemp();
            try self.qbeOp1(t, .l, "cast", v.text);
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
        .w, .b, .sb, .h, .sh => blk: {
            const t = try self.newTemp();
            try self.qbeOp1(t, .w, "copy", payload.text);
            break :blk .{ .text = t, .qtype = .w };
        },
        .d => blk: {
            const t = try self.newTemp();
            try self.qbeOp1(t, .d, "cast", payload.text);
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
    var is_ascii = true;
    for (s) |b| {
        if (b >= 0x80) {
            is_ascii = false;
            break;
        }
    }
    try self.string_data.append(self.allocator, .{ .symbol = sym, .escaped = escaped, .byte_len = s.len, .is_ascii = is_ascii, .raw = s });
    const addr = try self.newTemp();
    try self.qbeOp2Imm(addr, .l, "add", sym, @intCast(ARC_HEADER_SIZE + STR_HEADER_SIZE));
    return .{ .text = addr, .qtype = .l, .heap = .str, .is_pinned = true };
}

/// `emitStringLiteral`nin STATİK-BAĞLAM kardeşi (Faz 1 decorator, bkz.
/// `decorators.zig`nin metadata tablosu): bir ÇALIŞMA-ZAMANI `add` komutu
/// üretmek YERİNE (bir `data $__nox_decorators` bloğunun İÇİNDE
/// kullanılacak SABİT bir sembol İFADESİ gerektiğinden) DOĞRUDAN
/// `"$strN+16"` biçiminde bir dize döner — QBE'nin data initializer'
/// larının `$sym + SAYI` sözdizimini DESTEKLEDİĞİ elle doğrulandı.
pub fn internPinnedStringConst(self: *Codegen, s: []const u8) CodegenError![]const u8 {
    const sym = try std.fmt.allocPrint(self.allocator, "$str{d}", .{self.string_counter});
    self.string_counter += 1;
    const escaped = try escapeForQbeString(self.allocator, s);
    var is_ascii = true;
    for (s) |b| {
        if (b >= 0x80) {
            is_ascii = false;
            break;
        }
    }
    try self.string_data.append(self.allocator, .{ .symbol = sym, .escaped = escaped, .byte_len = s.len, .is_ascii = is_ascii, .raw = s });
    return std.fmt.allocPrint(self.allocator, "{s}+{d}", .{ sym, ARC_HEADER_SIZE + STR_HEADER_SIZE });
}

/// `buildFunctionValueForIdentifier`in çözümleyemediği ad için kesin bir iletiyle `error.Unsupported`
/// döner (checker adı zaten kabul ettiğinden bu, codegen'in o noktada o ada bağlı bir yerel/modül
/// değişkeni/fonksiyon bulamadığı bir iç tutarsızlıktır — ör. modül-global ilklendiricisinde terfi
/// etmemiş bir üst düzey değişken).
noinline fn unresolvedIdentifier(self: *Codegen, name: []const u8) CodegenError {
    std.debug.print("codegen: '{s}' adı bu noktada çözümlenemedi (satır {d}): ne bir yerel/parametre, ne bir modül değişkeni, ne de üst düzey bir fonksiyon olarak codegen'e görünür. Modül-global ilklendiricilerinde bu, adın terfi etmemiş bir üst düzey değişkene işaret etmesi anlamına gelebilir\n", .{ name, self.current_raise_line });
    return error.Unsupported;
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
    // Faz KK.1 (task_32f43efe): `registration.zig`/`exceptions.zig`nin
    // KENDİ `from_imports` geri düşüşüyle AYNI desen — `name` bir `from
    // other_module import f` İLE alınan BARE isim OLABİLİR; `self.functions`
    // yalnızca (`checker.zig`nin `resolveIdentifierAsFunctionValue`ının
    // AYNI geri düşüşle `functions_used_as_value`e KAYDETTİĞİ) MANGLED
    // anahtarı taşır.
    // Önceden iki başarısızlık da genel "desteklenmeyen yapı" iletisine düşüyordu; buraya yalnızca
    // `genExpr`nin `.identifier` dalı bir yerel/parametre/modül değişkeni bulamadığında gelinir.
    const resolved_name = if (self.functions.contains(name))
        name
    else
        self.from_imports.get(name) orelse return unresolvedIdentifier(self, name);
    const sig = self.functions.get(resolved_name) orelse return unresolvedIdentifier(self, name);
    const trampoline_name = try std.fmt.allocPrint(self.allocator, "{s}__fnval", .{resolved_name});
    const block = try self.newTemp();
    try self.qbeCall(.{ .name = block, .ty = .l }, "$nox_rc_alloc", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = std.fmt.comptimePrint("{d}", .{CLOSURE_HEADER_SIZE}) } });
    const trampoline_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{trampoline_name});
    try self.qbeStoreL(trampoline_sym, block);
    const rel_addr = try self.newTemp();
    try self.qbeOp2Imm(rel_addr, .l, "add", block, @intCast(CLOSURE_RELEASE_FN_PTR_OFFSET));
    const trampoline_release_sym = try std.fmt.allocPrint(self.allocator, "${s}_release", .{trampoline_name});
    try self.qbeStoreL(trampoline_release_sym, rel_addr);
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
            if (self.vars.get(name)) |info| {
                const t = try self.newTemp();
                try self.qbeLoad(t, info.qtype, info.qtype, info.slot);
                // Faz FF.6.4: bkz. `narrowed_unbox`'ın belge notu — bu isim
                // ŞU AN daraltılmış bir kutulanmış Optional-ilkel İSE, kutu
                // POINTER'ı DEĞİL İÇİNDEKİ ham değer döndürülür.
                if (info.heap == .boxed_scalar and self.narrowed_unbox.contains(name)) {
                    const payload = try self.newTemp();
                    try self.qbeLoad(payload, info.elem_qtype, info.elem_qtype, t);
                    break :blk .{ .text = payload, .qtype = info.elem_qtype };
                }
                break :blk .{ .text = t, .qtype = info.qtype, .heap = info.heap, .elem_qtype = info.elem_qtype, .class_name = info.class_name, .elem_heap_info = info.elem_heap_info, .elem_is_str = info.elem_is_str, .dict_info = info.dict_info, .func_sig = info.func_sig, .arena = info.arena, .growable_arena = info.growable_arena, .fixed_int = info.fixed_int, .elem_fixed_int = info.elem_fixed_int };
            }
            // Bulundu (bkz. proje belleği "modül-seviyesi global durum"
            // planı): yerel/parametre BAŞARISIZ olursa — `buildFunctionValueForIdentifier`
            // fonksiyon-değeri YEDEĞİNDEN ÖNCE — modül-seviyesi bir global
            // denenir. `nox_globals_get(rt)` + ofset + `load<qtype>` İLE
            // İNŞA edilen `Value`nin ŞEKLİ `genFieldRead`nin sınıf-alanı
            // okumasıYLA BİREBİR AYNIDIR (checker.zig'in AYNI düşüşüyle
            // TUTARLI, bkz. onun belge notu).
            if (self.module_globals.get(name)) |g| {
                const block = try self.newTemp();
                try self.qbeCall(.{ .name = block, .ty = .l }, "$nox_globals_get", &.{.{ .ty = .l, .text = RT_PARAM }});
                const addr = try self.newTemp();
                try self.qbeOp2Imm(addr, .l, "add", block, @intCast(g.offset));
                const t = try self.newTemp();
                try self.qbeLoad(t, g.info.qtype, g.info.qtype, addr);
                break :blk .{ .text = t, .qtype = g.info.qtype, .heap = g.info.heap, .elem_qtype = g.info.elem_qtype, .class_name = g.info.class_name, .elem_heap_info = g.info.elem_heap_info, .elem_is_str = g.info.elem_is_str, .dict_info = g.info.dict_info, .func_sig = g.info.func_sig, .fixed_int = g.info.fixed_int, .elem_fixed_int = g.info.elem_fixed_int };
            }
            break :blk try self.buildFunctionValueForIdentifier(name);
        },
        .unary => |u| try self.genUnary(u),
        .binary => |b| try self.genBinary(b),
        .ternary => |t| try self.genTernary(t),
        // `kwarg` checker tarafından konumsal argümanlara açılır; codegen'e ASLA ulaşmamalı.
        .kwarg => error.Unsupported,
        .call => |c| try self.genCall(c),
        .list_comp => |lc| try self.genListComp(lc),
        .dict_comp => |dc| try self.genDictComp(dc),
        .lambda => error.Unsupported,
        .tuple_lit => error.Unsupported,
        .slice => |sl| try self.genSlice(sl),
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

/// v2.0 madde 5: bir sınıf ALANINI (`ti`) `addr`den, sahibi sınıfın
/// `layout_mode`ine göre DOĞRU genişlikte okur. `default` modda (BÜYÜK
/// ÇOĞUNLUK, DEĞİŞMEMİŞ) her zaman `qbeLoad(dst, ti.qtype, ti.qtype,
/// addr)` — mevcut davranış BİREBİR korunur (204 fixture'lık IR-birebir
/// garantisi). `repr_c`/`packed_` modda, u8/i8/u16/i16 alanlar (`.w`de
/// hesaplanan AMA depoda DAHA DAR olan TEK 4 kind, bkz. `abi.zig`nin
/// `storageSizeOf`u) bayt/yarım-kelime granülerlikli okumaya YÖNLENDİRİLİR
/// — DİĞER TÜM genişlikler (u32/i32/u64/i64/int/float/bool/str/sınıf-
/// pointer/vb.) ZATEN kendi doğal genişliğinde depolandığından (bkz.
/// `abi.zig`nin `nextFieldOffset`i, boyut==hizalama) normal `qbeLoad`
/// YETERLİDİR — TEK istisna: `packed_` modda ÖNCESİNDE dar bir alan
/// varsa BU geniş alan bile hizasız bir adreste OLABİLİR, bu YÜZDEN
/// `packed_`da `qbeLoadUnaligned` kullanılır (`repr_c`da GEREKMEZ — bkz.
/// `qbeLoadUnaligned`in KENDİ belge notu, hizalama ZİNCİRLEME korunur).
pub fn narrowLoad(self: *Codegen, dst: []const u8, ti: types.TypeInfo, layout_mode: types.ClassLayoutMode, addr: []const u8) CodegenError!void {
    if (layout_mode == .default) {
        try self.qbeLoad(dst, ti.qtype, ti.qtype, addr);
        return;
    }
    if (ti.fixed_int) |k| {
        switch (k) {
            .u8 => return self.qbeLoadUB(dst, addr),
            .i8 => return self.qbeLoadSB(dst, addr),
            .u16 => return self.qbeLoadUH(dst, addr),
            .i16 => return self.qbeLoadSH(dst, addr),
            else => {},
        }
    }
    if (layout_mode == .packed_) {
        try self.qbeLoadUnaligned(dst, ti.qtype, ti.qtype, addr);
    } else {
        try self.qbeLoad(dst, ti.qtype, ti.qtype, addr);
    }
}

/// v2.0 madde 5: `narrowLoad`in yazma yönü — bkz. onun belge notu, AYNI
/// gerekçe.
pub fn narrowStore(self: *Codegen, value: []const u8, ti: types.TypeInfo, layout_mode: types.ClassLayoutMode, addr: []const u8) CodegenError!void {
    if (layout_mode == .default) {
        try self.qbeStore(ti.qtype, value, addr);
        return;
    }
    if (ti.fixed_int) |k| {
        switch (k) {
            .u8, .i8 => return self.qbeStoreB(value, addr),
            .u16, .i16 => return self.qbeStoreH(value, addr),
            else => {},
        }
    }
    if (layout_mode == .packed_) {
        try self.qbeStoreUnaligned(ti.qtype, value, addr);
    } else {
        try self.qbeStore(ti.qtype, value, addr);
    }
}

/// v2.0 madde 7 (bkz. plan dosyası §3): `ptr_read_volatile`nin skaler-T
/// yolu — `narrowLoad`in `.packed_` dalıyla AYNI genişlik-dispatch'i,
/// AMA `layout_mode` PARAMETRESİ ALMAZ (`ptr[T]` İçİn her zaman "hizasız/
/// volatile" varsayılır, `genTypedPtrLoad`in ZATEN yaptığı GİBİ) VE
/// dar-OLMAYAN genişlikler İçİn `qbeLoadUnaligned` YERİNE `qbeLoadVolatile`
/// çağırır (LLVM'de GERÇEK `load volatile`, QBE'de AYIRT EDİLEMEZ).
pub fn narrowLoadVolatile(self: *Codegen, dst: []const u8, ti: types.TypeInfo, addr: []const u8) CodegenError!void {
    if (ti.fixed_int) |k| {
        switch (k) {
            .u8 => return self.qbeLoadUBVolatile(dst, addr),
            .i8 => return self.qbeLoadSBVolatile(dst, addr),
            .u16 => return self.qbeLoadUHVolatile(dst, addr),
            .i16 => return self.qbeLoadSHVolatile(dst, addr),
            else => {},
        }
    }
    try self.qbeLoadVolatile(dst, ti.qtype, ti.qtype, addr);
}

/// `narrowLoadVolatile`in yazma yönü — bkz. onun belge notu, AYNI gerekçe.
pub fn narrowStoreVolatile(self: *Codegen, value: []const u8, ti: types.TypeInfo, addr: []const u8) CodegenError!void {
    if (ti.fixed_int) |k| {
        switch (k) {
            .u8, .i8 => return self.qbeStoreBVolatile(value, addr),
            .u16, .i16 => return self.qbeStoreHVolatile(value, addr),
            else => {},
        }
    }
    try self.qbeStoreVolatile(ti.qtype, value, addr);
}

pub fn genFieldRead(self: *Codegen, a: ast.Attribute) CodegenError!Value {
    const obj = try self.genExpr(a.obj.*);
    if (obj.heap != .class) return error.Unsupported;
    const cinfo = self.classes.get(obj.class_name.?).?;
    for (cinfo.fields.items) |f| {
        if (!std.mem.eql(u8, f.name, a.attr)) continue;
        const addr = try self.newTemp();
        try self.qbeOp2Imm(addr, .l, "add", obj.text, @intCast(f.offset));
        const result = try self.newTemp();
        try self.narrowLoad(result, f.info, cinfo.layout_mode, addr);
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
            try self.emitInlineRetain(result, f.info.heap);
        }
        try self.releaseIfTemporary(a.obj.*, obj);
        return .{ .text = result, .qtype = f.info.qtype, .heap = f.info.heap, .elem_qtype = f.info.elem_qtype, .class_name = f.info.class_name, .elem_heap_info = f.info.elem_heap_info, .elem_is_str = f.info.elem_is_str, .dict_info = f.info.dict_info, .func_sig = f.info.func_sig, .fixed_int = f.info.fixed_int, .elem_fixed_int = f.info.elem_fixed_int };
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
        try self.qbeOp2Imm(addr, .l, "add", obj.text, @intCast(f.offset));
        const result = try self.newTemp();
        try self.narrowLoad(result, f.info, cinfo.layout_mode, addr);
        return .{ .text = result, .qtype = f.info.qtype, .heap = f.info.heap, .elem_qtype = f.info.elem_qtype, .class_name = f.info.class_name, .elem_heap_info = f.info.elem_heap_info, .elem_is_str = f.info.elem_is_str, .dict_info = f.info.dict_info, .func_sig = f.info.func_sig, .fixed_int = f.info.fixed_int, .elem_fixed_int = f.info.elem_fixed_int };
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

/// v1.161.0: Python gibi negatif indeks (`xs[-1]`, `s[-2]`): `i < 0` ise `i + len`. Dallanmasız (`sar`/`and`/`add`); pozitif sabit
/// literal indekste (`xs[0]`) atlanır. Sonuçtan sonra mevcut TEK işaretsiz `cugel` sınır kontrolü hâlâ geçerlidir
/// (`i + len` hâlâ negatifse işaretsiz olarak çok büyüktür → `IndexError`).
pub fn normalizeNegativeIndex(self: *Codegen, index_expr: ast.Expr, index_text: []const u8, len_t: []const u8) CodegenError![]const u8 {
    if (index_expr == .int_lit and index_expr.int_lit >= 0) return index_text;
    const sign = try self.newTemp();
    try self.qbeOp2(sign, .l, "sar", index_text, "63");
    const add_len = try self.newTemp();
    try self.qbeOp2(add_len, .l, "and", sign, len_t);
    const adj = try self.newTemp();
    try self.qbeOp2(adj, .l, "add", index_text, add_len);
    return adj;
}

pub fn genIndex(self: *Codegen, idx: ast.Index) CodegenError!Value {
    const obj = try self.genExpr(idx.obj.*);
    // Faz NN: `d[key]`nin taban SÖZLÜĞÜ (`obj`) TEMPORARY İSE (ör.
    // `make_dict()[key]`), `genDictGet` ÖNCEDEN yalnızca ANAHTARI serbest
    // bırakıyordu — sözlüğün KENDİSİ HİÇ serbest bırakılmıyordu (ne başarı
    // ne hata dalında, GERÇEK bir sızıntıyla DOĞRULANDI). Bu ARTIK
    // `genDictGet`nin KENDİSİ (hem hata DALINDA `emitExceptionCheck`den
    // ÖNCE, hem başarı dalında retain-önce-serbest-bırak korumasıyla)
    // ele alınır — `obj_expr` (taban ifadenin AST'ı) bu YÜZDEN de geçirilir.
    if (obj.heap == .dict) return self.genDictGet(idx.obj.*, obj, idx.index.*);
    if (obj.heap == .str) return self.genStrIndex(obj, idx);
    if (obj.heap != .list) return error.Unsupported;
    var index_v = try self.genExpr(idx.index.*);

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
        try self.qbeLoadL(len_t, obj.text);
        index_v.text = try normalizeNegativeIndex(self, idx.index.*, index_v.text, len_t);
        // v1.142.5: `idx < 0 or idx >= len` TEK işaretsiz karşılaştırma: negatif indeks
        // işaretsiz yorumlandığında ≥ 2^63 > len olur (3 işlem → 1).
        const oob_t = try self.newTemp();
        try self.qbeOp2(oob_t, .w, "cugel", index_v.text, len_t);
        const err_label = try self.newLabel("list_idx_err");
        const ok_label = try self.newLabel("list_idx_ok");
        try self.qbeJnzCold(oob_t, err_label, ok_label);
        const cold_start = self.beginCold();
        try self.qbeLabel(err_label);

        const msg_value = try self.emitStringLiteral("liste indeksi sinirlarin disinda");
        const ie_cinfo = self.classes.get("IndexError") orelse return error.Unsupported;
        const ie_obj = try self.genConstructFromValues("IndexError", ie_cinfo, &.{msg_value}, null);
        try self.emitExceptionLineStore(ie_obj.text, "IndexError", self.current_raise_line);
        try self.qbeCall(null, "$nox_raise", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ie_obj.text }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{self.current_raise_line}) } });
        // Bulundu (bkz. proje belleği "4 yeni stdlib modülü" planı): bu dal
        // KOŞULSUZ raise edip ATLADIĞINDAN, `obj` (taban liste) TEMPORARY
        // İSE normal yoldaki serbest bırakma BURAYA HİÇ ULAŞMAZ (GERÇEK
        // bir sızıntı). Faz NN: kök neden (`releaseNamedLocalsExcept`nin
        // "identifier ile taşınan" değerin slotunu sıfırlamaması, bkz.
        // `ownership.zig`) DÜZELTİLDİKTEN SONRA bu çağrı GÜVENLE yeniden
        // eklendi — 50 iterasyonluk döngü testiyle DOĞRULANDI (bkz. proje
        // belleği "ARC sızıntı düzeltmeleri").
        try self.releaseIfTemporary(idx.obj.*, obj);
        try self.emitRaisePropagate();
        try self.stashCold(cold_start);

        try self.qbeLabel(ok_label);
    }
    const byte_off = try self.newTemp();
    try self.qbeOp2Imm(byte_off, .l, "mul", index_v.text, @intCast(qbeSizeOf(obj.elem_qtype)));
    const off8 = try self.newTemp();
    try self.qbeOp2Imm(off8, .l, "add", byte_off, @intCast(LIST_HEADER_SIZE));
    const addr = try self.newTemp();
    try self.qbeOp2(addr, .l, "add", obj.text, off8);
    const result = try self.newTemp();
    try self.loadListElem(result, obj.elem_qtype, addr);
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
    // v2.0 madde 4 (Faz D): `elem_heap_info != null` ARTIK "eleman HEAP-
    // yönetimli" ANLAMINA GELMİYOR (bkz. registration.zig'in YENİ `heap
    // == .none and elem.fixed_int != null` dalı — `list[u8]`nin
    // `elem_heap_info`si de DOLU, AMA `.heap == .none`) — `isHeapManaged`
    // KONTROLÜ olmadan `emitInlineRetain`e HAM bir SKALER değer (pointer
    // DEĞİL) geçirmek, onu BİR BELLEK ADRESİ SANIP atomic-add YAPMAYA
    // ÇALIŞIRDI (GERÇEK bir bellek bozulması riski — ÇALIŞTIRILMADAN
    // ÖNCE fark edilip DÜZELTİLDİ).
    if (isTemporaryExpr(idx.obj.*) and obj.elem_heap_info != null and isHeapManaged(obj.elem_heap_info.?.heap)) {
        try self.emitInlineRetain(result, obj.elem_heap_info.?.heap);
    }
    try self.releaseIfTemporary(idx.obj.*, obj);
    return valueFromElemDescriptor(result, obj.elem_qtype, obj.elem_heap_info, obj.elem_is_str, obj.elem_fixed_int);
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
    var index_v = try self.genExpr(idx.index.*);
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
            try self.qbeCall(.{ .name = t, .ty = .l }, "$nox_str_char_count", &.{.{ .ty = .l, .text = obj.text }});
            break :blk t;
        };
        index_v.text = try normalizeNegativeIndex(self, idx.index.*, index_v.text, len_t);
        // v1.142.5: `idx < 0 or idx >= len` TEK işaretsiz karşılaştırma: negatif indeks
        // işaretsiz yorumlandığında ≥ 2^63 > len olur (3 işlem → 1).
        const oob_t = try self.newTemp();
        try self.qbeOp2(oob_t, .w, "cugel", index_v.text, len_t);
        const err_label = try self.newLabel("str_idx_err");
        const ok_label = try self.newLabel("str_idx_ok");
        try self.qbeJnzCold(oob_t, err_label, ok_label);
        const cold_start = self.beginCold();
        try self.qbeLabel(err_label);

        const msg_value = try self.emitStringLiteral("str indeksi sinirlarin disinda");
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
        try self.qbeJnzL(ascii_flag, ascii_label, unicode_label);

        try self.qbeLabel(ascii_label);
        const byte_addr = try self.newTemp();
        try self.qbeOp2(byte_addr, .l, "add", obj.text, index_v.text);
        const byte_val = try self.newTemp();
        try self.qbeLoadUB(byte_val, byte_addr);
        // `str`e uzunluk alanı + ASCII bayrağı eklenmesinden BERİ (bkz.
        // plan dosyası) bu O(1) ASCII-hızlı-yol İNLINE'ı (`nox_str_char_at`i
        // ÇAĞIRMAK YERİNE doğrudan QBE'de bir 2 baytlık `[bayt][NUL]`
        // tahsis ediyordu) PAKETLENMİŞ başlığı UNUTUYORDU — GERÇEK bir bug
        // olarak bulunup düzeltildi (`s[i]` bir DÖNGÜ İÇİNDE, cache'lenmiş-
        // ASCII bir tabandan çağrıldığında SESSİZCE başlıksız/bozuk bir
        // `str` üretiyordu, SONRAKİ HERHANGİ bir `nox_str_*` çağrısında
        // çökme/veri bozulmasına yol açıyordu — GERÇEKTEN `s[i]` bir
        // döngüde kullanılan HER golden test regresyona uğradı). Tek
        // karakterlik SONUÇ HER ZAMAN ascii'dir (bu dal, tanım gereği) —
        // paketlenmiş başlık (`uzunluk=1, ascii=TRUE`) DERLEME ZAMANINDA
        // sabit bir değerdir, SIFIR ek çalışma-zamanı maliyetiyle yazılır.
        // v1.142.18: tahsis YOK — önceden kurulmuş PINNED ASCII tablosundan (`runtime/str.zig`nin
        // `nox_ascii_chars`i: 24 baytlık girişler, dize işaretçisi giriş + 16) adres hesaplanır.
        const byte_l = try self.newTemp();
        try self.qbeOp1(byte_l, .l, "extuw", byte_val);
        const tbl_off = try self.newTemp();
        try self.qbeOp2Imm(tbl_off, .l, "mul", byte_l, 24);
        const tbl_addr = try self.newTemp();
        try self.qbeOp2(tbl_addr, .l, "add", "$nox_ascii_chars", tbl_off);
        const ascii_result = try self.newTemp();
        try self.qbeOp2Imm(ascii_result, .l, "add", tbl_addr, @intCast(ARC_HEADER_SIZE + STR_HEADER_SIZE));
        try self.qbeJmp(done_label);

        try self.qbeLabel(unicode_label);
        const unicode_result = try self.newTemp();
        try self.qbeCall(.{ .name = unicode_result, .ty = .l }, "$nox_str_char_at", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj.text }, .{ .ty = .l, .text = index_v.text } });
        try self.qbeJmp(done_label);

        try self.qbeLabel(done_label);
        try self.qbePhi(result_t, .l, ascii_label, ascii_result, unicode_label, unicode_result);
    } else {
        try self.qbeCall(.{ .name = result_t, .ty = .l }, "$nox_str_char_at", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj.text }, .{ .ty = .l, .text = index_v.text } });
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
    // GG.18 (bkz. plan dosyası "ASAP güçlendirmesi — Tur 2", `local_escape.
    // zig`nin `registerLocalStackSlots`ı): `target.growable_arena` (bir
    // `VarInfo`den geliyorsa) `allocSlotEx` TARAFINDAN ZATEN doldurulmuş
    // olabilir — boş `[]` literalleri İçin AST-düğüm-anahtarlı bir tabloya
    // GÜVENİLEMEZ (Zig'in TÜM sıfır-boyutlu tahsislere AYNI kanonik
    // işaretçiyi vermesi YÜZÜNDEN — DOĞRUDAN doğrulandı), bu YÜZDEN BURADA
    // `target`den DOĞRUDAN okunur. `currentArena()`DAN (`lowlevel:` kapsamı)
    // ÖNCELİKLİDİR.
    const growable_arena: ?[]const u8 = if (@hasField(@TypeOf(target), "growable_arena")) target.growable_arena else null;
    const arena = growable_arena orelse self.currentArena();
    const list_header_size_text = comptime std.fmt.comptimePrint("{d}", .{LIST_HEADER_SIZE});
    if (arena) |ap| {
        try self.qbeCall(.{ .name = t, .ty = .l }, "$nox_arena_alloc", &.{ .{ .ty = .l, .text = ap }, .{ .ty = .l, .text = list_header_size_text } });
    } else {
        try self.qbeCall(.{ .name = t, .ty = .l }, "$nox_rc_alloc", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = list_header_size_text } });
    }
    try self.qbeStoreImmL(0, t);
    const cap_addr = try self.newTemp();
    try self.qbeOp2Imm(cap_addr, .l, "add", t, 8);
    try self.qbeStoreImmL(0, cap_addr);
    return .{
        .text = t,
        .qtype = .l,
        .heap = .list,
        .elem_qtype = target.elem_qtype,
        .elem_heap_info = target.elem_heap_info,
        .elem_is_str = target.elem_is_str,
        .elem_fixed_int = target.elem_fixed_int,
        .arena = arena != null,
        .growable_arena = growable_arena,
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
    // v1.142.19: bool elemanlar 1 bayt depolanır (`.b`).
    const elem_qtype = abi.elemStorageQtype(first.qtype, first.fixed_int, first.heap);
    var elem_heap_info: ?*const ElemHeapInfo = null;
    // `str` DAHİL (bkz. `resolveType`in list dalındaki AYNI gerekçe,
    // stdlib fazı §B) — `list[str]` elemanlarının kapsam-sonu/yeniden
    // atamada özyinelemeli release'e girmesi için gerekli.
    // Faz U.4.5: `.closure` EKLENDİ — bkz. `resolveType`nin list dalındaki
    // AYNI gerekçe/belge notu (`stdlib/nox/router.nox`nin `list[(T)->U]`
    // alanları İçin — bu OLMADAN listenin KENDİSİ düşürüldüğünde eleman
    // closure'ları HİÇ serbest bırakılmazdı, GERÇEK bir sızıntı).
    // Bulundu (nyx framework — bkz. proje belleği "NOX_LIMITATIONS.md
    // incelemesi", C1): `.dict` EKLENDİ — bkz. `registration.zig`nin
    // `resolveType`indeki AYNI gerekçe/belge notu. Bu dal ÖNCEDEN `.dict`i
    // ATLIYORDU — `[{...}, {...}]` GİBİ bir `list_lit` ifadesi SESSİZCE
    // `elem_heap_info = null` ile devam ediyordu (GERÇEK bir sızıntı: dict
    // elemanları listenin KENDİSİ düşürüldüğünde HİÇ serbest bırakılmıyordu).
    if (first.heap == .class or first.heap == .list or first.heap == .str or first.heap == .closure or first.heap == .dict) {
        const info = try self.allocator.create(ElemHeapInfo);
        info.* = .{ .heap = first.heap, .class_name = first.class_name, .elem_qtype = first.elem_qtype, .nested = first.elem_heap_info, .elem_is_str = first.elem_is_str, .func_sig = first.func_sig, .dict_info = first.dict_info };
        elem_heap_info = info;
    }
    const elem_is_str = first.heap == .str;
    // v2.0 madde 4 (Faz D): `[u8(1), u8(2)]` GİBİ bir liste literalinin
    // eleman kind'ı, İLK elemandan ÇIKARILIR (checker'ın "aynı-kind-only"
    // kısıtı TÜM elemanların AYNI kind OLMASINI ZATEN garanti eder —
    // `types.eql` pairwise kontrolü, bkz. modül üstü not).
    const elem_fixed_int = first.fixed_int;
    const elem_size = qbeSizeOf(elem_qtype);
    const payload_size = LIST_HEADER_SIZE + elem_size * elems.len;

    const arena = self.currentArena();
    // GG.15/GG.16 (bkz. nox-teknik-spesifikasyon.md §3.66): BU `list_lit`
    // İçin ÖNCEDEN bir yığın slotu ayrılmışsa `nox_arena_alloc`/`nox_rc_alloc`
    // ÇAĞRISI TAMAMEN ATLANIR. İKİ AYRI kaynak kontrol edilir:
    // (1) `self.pending_stack_slot` — GG.16'nın `genInlinedCall`nin BU ÖZEL
    // splice sitesi İçin GEÇİCİ olarak ayarladığı, ÇAĞRI-SİTESİNE ÖZGÜ slot
    // (bkz. `Codegen.stack_slot_call_sites`in belge notu — AYNI `list_lit`
    // gövdesinin BAŞKA bir çağrı sitesinde YANLIŞLIKLA tüketilmesini
    // ÖNLEMEK İçin BUNUN `elems.ptr`den ÖNCE kontrol edilmesi ZORUNLUDUR).
    // (2) `self.stack_construct_sites` (`elems.ptr` İLE anahtarlı) — GG.15'in
    // DOĞRUDAN bir `lowlevel:` gövdesi İÇİNDEKİ (fonksiyon-çağrısı SINIRI
    // OLMAYAN, bu YÜZDEN AST-düğüm-kimliği GÜVENLİ olan) inşaları İçin.
    var from_stack_site = false;
    var growable_arena: ?[]const u8 = null;
    const t: []const u8 = blk: {
        if (self.pending_stack_slot) |slot| {
            self.pending_stack_slot = null;
            from_stack_site = true;
            break :blk slot;
        }
        if (self.stack_construct_sites.get(@intFromPtr(elems.ptr))) |site| {
            from_stack_site = true;
            break :blk site.slot;
        }
        // GG.18 (bkz. `local_escape.zig`nin `registerLocalStackSlots`ı):
        // BU DOLU `list_lit`in (boş `[]` DEĞİL — o `genEmptyListLit`den
        // GEÇER) ÖNCEDEN bir fonksiyon-kapsamlı arenaya kaydedilip
        // kaydedilmediğini kontrol eder. `currentArena()`DAN (`lowlevel:`
        // kapsamı) ÖNCELİKLİDİR.
        if (self.arena_local_construct_sites.get(@intFromPtr(elems.ptr))) |ap| {
            growable_arena = ap;
            const temp = try self.newTemp();
            try self.qbeCall(.{ .name = temp, .ty = .l }, "$nox_arena_alloc", &.{ .{ .ty = .l, .text = ap }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{payload_size}) } });
            break :blk temp;
        }
        const temp = try self.newTemp();
        if (arena) |ap| {
            try self.qbeCall(.{ .name = temp, .ty = .l }, "$nox_arena_alloc", &.{ .{ .ty = .l, .text = ap }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{payload_size}) } });
        } else {
            try self.qbeCall(.{ .name = temp, .ty = .l }, "$nox_rc_alloc", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{payload_size}) } });
        }
        break :blk temp;
    };
    try self.qbeStoreImmL(@intCast(elems.len), t);
    // Faz U.1: kapasite (@8) — bir literalden inşa edilen bir liste HER
    // ZAMAN tam-oturan başlar (kapasite=uzunluk, büyüme SLACK'i YOK) —
    // yalnızca `.append()` GEREKTİĞİNDE gerçek büyüme uygular.
    const cap_addr = try self.newTemp();
    try self.qbeOp2Imm(cap_addr, .l, "add", t, 8);
    try self.qbeStoreImmL(@intCast(elems.len), cap_addr);
    for (values, 0..) |v, i| {
        const off = LIST_HEADER_SIZE + elem_size * i;
        const addr = try self.newTemp();
        try self.qbeOp2Imm(addr, .l, "add", t, @intCast(off));
        try self.qbeStore(elem_qtype, v.text, addr);
    }
    return .{ .text = t, .qtype = .l, .heap = .list, .elem_qtype = elem_qtype, .elem_heap_info = elem_heap_info, .elem_is_str = elem_is_str, .elem_fixed_int = elem_fixed_int, .arena = arena != null or growable_arena != null, .is_stack_slot = from_stack_site and arena == null, .growable_arena = growable_arena };
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
    try self.qbeCall(.{ .name = d, .ty = .l }, "$nox_dict_new", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .w, .text = key_is_str_lit } });
    try self.emitDictInstallValueRelease(d, dinfo);
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
    const dinfo = try abi.makeDictInfo(self.allocator, abi.typeInfoOfValue(key_values[0]), abi.typeInfoOfValue(value_values[0]));
    const value_is_class = dinfo.valueIsArc();

    const key_is_str_lit: []const u8 = if (key_is_str) "1" else "0";
    const value_is_str_lit: []const u8 = if (value_is_str) "1" else "0";
    const value_is_class_lit: []const u8 = if (value_is_class) "1" else "0";

    const d = try self.newTemp();
    try self.qbeCall(.{ .name = d, .ty = .l }, "$nox_dict_new", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .w, .text = key_is_str_lit } });
    try self.emitDictInstallValueRelease(d, dinfo);

    for (key_values, 0..) |kv, i| {
        const key_payload = try self.toPayload(kv);
        const value_payload = try self.toPayload(value_values[i]);
        try self.qbeCall(null, "$nox_dict_set", &.{
            .{ .ty = .l, .text = RT_PARAM },
            .{ .ty = .l, .text = d },
            .{ .ty = .w, .text = key_is_str_lit },
            .{ .ty = .w, .text = value_is_str_lit },
            .{ .ty = .w, .text = value_is_class_lit },
            .{ .ty = .l, .text = key_payload.text },
            .{ .ty = .l, .text = value_payload.text },
        });
    }

    return .{ .text = d, .qtype = .l, .heap = .dict, .dict_info = dinfo };
}

pub fn genUnary(self: *Codegen, u: ast.Unary) CodegenError!Value {
    const operand = try self.genExpr(u.operand.*);
    return switch (u.op) {
        .neg => blk: {
            const t = try self.newTemp();
            try self.qbeOp1(t, operand.qtype, "neg", operand.text);
            break :blk .{ .text = t, .qtype = operand.qtype };
        },
        .not_ => blk: {
            const t = try self.newTemp();
            try self.qbeOp2Imm(t, .w, "xor", operand.text, 1);
            break :blk .{ .text = t, .qtype = .w };
        },
        // v3 madde 2 (bitwise operatörler): `~x` — TÜM bitleri ters
        // çevirir (`xor -1`). **İNCE bir nokta (GERÇEKTEN düşünülüp
        // DOĞRULANDI, tahmin YÜRÜTÜLMEDİ):** `emitCheckedFixedBinNarrow`nin
        // belge notunun KURDUĞU değişmez — bir u8/i8/u16/i16 değeri HER
        // ZAMAN `.w` yazmacında KENDİ genişliğine göre DOĞRU şekilde
        // işaret-genişletilmiş/sıfır-genişletilmiş TUTULUR — `and`/`or`/
        // `xor` (İKİLİ) BU değişmezi OTOMATİK KORUR (HER çıktı biti
        // YALNIZCA KENDİ konumundaki giriş bitlerine bağlıdır; üst
        // "genişletme" bitleri zaten SABİT bir desen olduğundan sonuç da
        // sabit bir desen ÜRETİR) — AMA `~` (tekli, `xor -1`) İŞARETSİZ
        // dar kind'lerde (u8/u16) BU DEĞİŞMEZİ BOZAR: sıfır-genişletilmiş
        // üst bitler (HER ZAMAN 0) `-1` İLE XOR'lanınca TÜMÜ 1'e döner
        // (0xFFFFFF...), OYSA işaretsiz bir kind'in değişmezi üst
        // bitlerin HER ZAMAN 0 KALMASINI gerektirir (alt baytın DEĞERİNDEN
        // BAĞIMSIZ) — bu YÜZDEN işaretsiz dar kind'ler İçİn XOR'DAN SONRA
        // AYRICA sıfır-genişletme (extub/extuh) GEREKİR. İşaretli dar
        // kind'ler (i8/i16) İçİn BU SORUN YOK (işaret-genişletme, "üst
        // bitler = işaret biti" olduğundan, invert SONRASI da OTOMATİK
        // doğru kalır — YENİ işaret biti de ters çevrilmiş OLUR, İKİSİ
        // TUTARLI). u32/i32/u64/i64/plain int İçİn zaten TÜM yazmaç
        // genişliği "mantıksal" genişlikle ÇAKIŞTIĞINDAN ek adım GEREKMEZ.
        .invert => blk: {
            const t = try self.newTemp();
            try self.qbeOp2Imm(t, operand.qtype, "xor", operand.text, -1);
            if (operand.fixed_int) |k| {
                if (!k.isSigned() and (k == .u8 or k == .u16)) {
                    const ext_mnemonic: []const u8 = if (k == .u8) "extub" else "extuh";
                    const narrowed = try self.newTemp();
                    try self.qbeOp1(narrowed, .w, ext_mnemonic, t);
                    break :blk .{ .text = narrowed, .qtype = .w, .fixed_int = k };
                }
            }
            break :blk .{ .text = t, .qtype = operand.qtype, .fixed_int = operand.fixed_int };
        },
    };
}

pub fn emitBin(self: *Codegen, mnemonic: []const u8, l: Value, r: Value, result_qtype: QbeType) CodegenError!Value {
    const t = try self.newTemp();
    try self.qbeOp2(t, result_qtype, mnemonic, l.text, r.text);
    return .{ .text = t, .qtype = result_qtype };
}

/// v2.0 madde 4 (§3): sabit-genişlikli `+`/`-`/`*`in TEK giriş noktası —
/// depolama genişliğine göre ÜÇ ayrı alt-yola dağıtır (bkz. plan
/// dosyasının "Aritmetik taşma kontrolü" bölümü). v1.169.0: taşma HER İKİ
/// backend'de (QBE ve LLVM) AYNI şekilde yakalanamaz bir tuzağa düşer —
/// önceden LLVM sessizce sarıyordu (backend'e bağlı program anlamı).
pub fn emitCheckedFixedBin(self: *Codegen, mnemonic: []const u8, l: Value, r: Value, kind: types.FixedIntKind) CodegenError!Value {
    return switch (kind.bitWidth()) {
        8, 16 => self.emitCheckedFixedBinNarrow(mnemonic, l, r, kind),
        32 => self.emitCheckedFixedBin32(mnemonic, l, r, kind),
        64 => self.emitCheckedFixedBin64(mnemonic, l, r, kind),
        else => unreachable,
    };
}

/// u8/i8/u16/i16 — HEPSİ `.w`de (32-bit) hesaplanır. Girdiler ZATEN
/// [0,255]/[-128,127]/[0,65535]/[-32768,32767] aralığında OLDUĞUNDAN,
/// `add`/`sub`/`mul`in 32-bit'lik ARA sonucu ASLA 32-bit'i AŞMAZ (EN
/// KÖTÜ durum `mul`: 65535*65535 < 2^32) — taşma YALNIZCA HEDEF
/// GENİŞLİKTE olur, bu yüzden DOĞRUDAN `.w`de hesaplayıp SONRA bir
/// daraltma/genişletme round-trip'İYLE (bkz. `qbeOp1`'in `extub`/`extsb`/
/// `extuh`/`extsh` mnemonikleri, QBE'nin AYNI zaten var olan bayt/yarım-
/// kelime granülerlikli talimatları) kontrol etmek yeterlidir.
pub fn emitCheckedFixedBinNarrow(self: *Codegen, mnemonic: []const u8, l: Value, r: Value, kind: types.FixedIntKind) CodegenError!Value {
    const raw = try self.emitBin(mnemonic, l, r, .w);
    const check_mnemonic: []const u8 = switch (kind) {
        .u8 => "extub",
        .i8 => "extsb",
        .u16 => "extuh",
        .i16 => "extsh",
        else => unreachable,
    };
    // `narrowed` — `raw`nin GERÇEK depolama genişliğine (bkz. `check_
    // mnemonic`, QBE'nin bayt/yarım-kelime granülerlikli genişletme
    // talimatları) daraltılıp GERİ genişletilmiş hali. Bu, HEM taşma
    // TESPİTİ (QBE: `narrowed != raw` İSE taştı) HEM DE `--release`/LLVM'in
    // SESSİZ SARMASININ KENDİSİDİR (`narrowed`, taşan bir toplamın DOĞRU
    // "mod 2^genişlik" DEĞERİdir — ÖNCEDEN BURADA hiç HESAPLANMIYORDU,
    // `raw`nin KENDİSİ [ör. `255u8 + 1` İçİn 32-bit'lik ham `256`]
    // DOĞRUDAN geri DÖNDÜRÜLÜYORDU, GERÇEK bir "sarma YOK" hatası —
    // ÇALIŞTIRILIP BULUNDU).
    const narrowed = try self.newTemp();
    try self.qbeOp1(narrowed, .w, check_mnemonic, raw.text);
    const mismatch = try self.newTemp();
    try self.qbeOp2(mismatch, .w, "cnew", narrowed, raw.text);
    try self.emitOverflowTrapIfNonzero(mismatch, kind);
    return .{ .text = narrowed, .qtype = .w, .fixed_int = kind };
}

/// u32/i32 — `.w`nin KENDİSİ taşma bayrağı SUNMAZ, bu yüzden çekirdek
/// hesaplama `.l`YE YÜKSELTİLEREK yapılır (32-bit girdilerin add/sub/
/// mul'ı HER ZAMAN 64-bit'e TAM sığar — İMZASIZ EN KÖTÜ durum
/// `(2^32-1)^2 < 2^64`, İMZALI en kötü durum `|i32|<=2^31` olduğundan
/// çarpım büyüklüğü `<=2^62 < 2^63`), SONRA `.w`ye geri daraltılıp AYNI
/// kind'a göre YENİDEN genişletilerek orijinal 64-bit sonuçla
/// KARŞILAŞTIRILIR (`widenFixedIntForPrint`in AYNI extsw/extuw deseni,
/// bkz. onun belge notu — "print İçİn" adı YANILTICI, SAF bit-genişletme
/// olduğundan burada da GEÇERLİ).
pub fn emitCheckedFixedBin32(self: *Codegen, mnemonic: []const u8, l: Value, r: Value, kind: types.FixedIntKind) CodegenError!Value {
    const lw = try self.widenFixedIntForPrint(l, kind);
    const rw = try self.widenFixedIntForPrint(r, kind);
    const wide = try self.emitBin(mnemonic, lw, rw, .l);
    const truncated = try self.newTemp();
    try self.qbeOp1(truncated, .w, "copy", wide.text);
    const truncated_val: Value = .{ .text = truncated, .qtype = .w };
    const rewidened = try self.widenFixedIntForPrint(truncated_val, kind);
    const mismatch = try self.newTemp();
    try self.qbeOp2(mismatch, .w, "cnel", rewidened.text, wide.text);
    try self.emitOverflowTrapIfNonzero(mismatch, kind);
    return .{ .text = truncated, .qtype = .w, .fixed_int = kind };
}

/// u64/i64/usize/isize — EN GENİŞ register (`.l`), YÜKSELTME YOK.
/// `add`/`sub`: ÖNCE/SONRA işaret-karşılaştırma deseni (branch-free bir
/// koşul üretilip TEK bir `emitOverflowTrapIfNonzero` çağrısına
/// devredilir). `mul`: KENDİ AYRI, bölme-tabanlı kontrolüne (bkz.
/// `emitMul64OverflowCheck`in belge notu — İMZALI yol İçİn `INT64_MIN /
/// -1`in donanım SIGFPE'sinden KAÇINAN AYRI bir özel durum İÇERİR)
/// devredilir.
pub fn emitCheckedFixedBin64(self: *Codegen, mnemonic: []const u8, l: Value, r: Value, kind: types.FixedIntKind) CodegenError!Value {
    const raw = try self.emitBin(mnemonic, l, r, .l);
    const signed = kind.isSigned();
    if (std.mem.eql(u8, mnemonic, "mul")) {
        try self.emitMul64OverflowCheck(l, r, raw, kind, signed);
        return .{ .text = raw.text, .qtype = .l, .fixed_int = kind };
    }
    const cond = try self.newTemp();
    if (std.mem.eql(u8, mnemonic, "add")) {
        if (signed) {
            const l_neg = try self.newTemp();
            try self.qbeOp2Imm(l_neg, .w, "csltl", l.text, 0);
            const r_neg = try self.newTemp();
            try self.qbeOp2Imm(r_neg, .w, "csltl", r.text, 0);
            const same_sign = try self.newTemp();
            try self.qbeOp2(same_sign, .w, "ceqw", l_neg, r_neg);
            const res_neg = try self.newTemp();
            try self.qbeOp2Imm(res_neg, .w, "csltl", raw.text, 0);
            const diff_res = try self.newTemp();
            try self.qbeOp2(diff_res, .w, "cnew", l_neg, res_neg);
            try self.qbeOp2(cond, .w, "and", same_sign, diff_res);
        } else {
            try self.qbeOp2(cond, .w, "cultl", raw.text, l.text);
        }
    } else if (std.mem.eql(u8, mnemonic, "sub")) {
        if (signed) {
            const l_neg = try self.newTemp();
            try self.qbeOp2Imm(l_neg, .w, "csltl", l.text, 0);
            const r_neg = try self.newTemp();
            try self.qbeOp2Imm(r_neg, .w, "csltl", r.text, 0);
            const diff_sign = try self.newTemp();
            try self.qbeOp2(diff_sign, .w, "cnew", l_neg, r_neg);
            const res_neg = try self.newTemp();
            try self.qbeOp2Imm(res_neg, .w, "csltl", raw.text, 0);
            const diff_res = try self.newTemp();
            try self.qbeOp2(diff_res, .w, "cnew", l_neg, res_neg);
            try self.qbeOp2(cond, .w, "and", diff_sign, diff_res);
        } else {
            try self.qbeOp2(cond, .w, "cultl", l.text, r.text);
        }
    } else {
        return error.Unsupported;
    }
    try self.emitOverflowTrapIfNonzero(cond, kind);
    return .{ .text = raw.text, .qtype = .l, .fixed_int = kind };
}

/// `u64/i64/usize/isize`in `*`i — EN RİSKLİ alt-parça (bkz. plan notu).
/// İşaretsiz: `l==0` İSE taşma İMKANSIZ (kısayol), AKSİ HALDE bölme-
/// tabanlı kontrol (`result /u l != r`). İşaretli: AYNI bölme-tabanlı
/// kontrol, AMA `l==-1`İKEN bölme YERİNE `r==I64_MIN` DOĞRUDAN kontrol
/// edilir — donanımın `idiv`i `INT64_MIN / -1`de SIGFPE ÜRETİR (bu,
/// mantıksal OLARAK da taşan TEK durum), bu yüzden bölme HİÇ ÇALIŞTIRILMAZ.
pub fn emitMul64OverflowCheck(self: *Codegen, l: Value, r: Value, raw: Value, kind: types.FixedIntKind, signed: bool) CodegenError!void {
    const trap_label = try self.newLabel("ovf_trap");
    const ok_label = try self.newLabel("ovf_ok");
    const l_zero = try self.newTemp();
    try self.qbeOp2Imm(l_zero, .w, "ceql", l.text, 0);
    const after_zero_label = try self.newLabel("ovf_after_zero");
    try self.qbeJnz(l_zero, ok_label, after_zero_label);
    try self.qbeLabel(after_zero_label);
    if (signed) {
        const l_neg1 = try self.newTemp();
        try self.qbeOp2Imm(l_neg1, .w, "ceql", l.text, -1);
        const minmin_label = try self.newLabel("ovf_minmin");
        const div_check_label = try self.newLabel("ovf_div_check");
        try self.qbeJnz(l_neg1, minmin_label, div_check_label);
        try self.qbeLabel(minmin_label);
        const r_is_min = try self.newTemp();
        try self.qbeOp2Imm(r_is_min, .w, "ceql", r.text, std.math.minInt(i64));
        try self.qbeJnz(r_is_min, trap_label, ok_label);
        try self.qbeLabel(div_check_label);
        const q = try self.newTemp();
        try self.qbeOp2(q, .l, "div", raw.text, l.text);
        const mismatch = try self.newTemp();
        try self.qbeOp2(mismatch, .w, "cnel", q, r.text);
        try self.qbeJnz(mismatch, trap_label, ok_label);
    } else {
        const q = try self.newTemp();
        try self.qbeOp2(q, .l, "udiv", raw.text, l.text);
        const mismatch = try self.newTemp();
        try self.qbeOp2(mismatch, .w, "cnel", q, r.text);
        try self.qbeJnz(mismatch, trap_label, ok_label);
    }
    try self.qbeLabel(trap_label);
    const name_sym = try self.internFmtString(kind.name());
    try self.qbeCall(null, "$nox_int_overflow_trap", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = name_sym } });
    try self.emitDefaultReturn(self.current_ret_qtype);
    try self.qbeLabel(ok_label);
}

/// `cond` (bir `.w` bool) sıfır DEĞİLSE `nox_int_overflow_trap`e dallanır
/// (`nox_unhandled_exception`in AYNI, ZATEN kanıtlanmış "noreturn çağrı +
/// savunmacı `emitDefaultReturn`" deseni, bkz. `exceptions.zig`nin AYNI
/// notu) — SIFIRSA doğrudan devam eder.
pub fn emitOverflowTrapIfNonzero(self: *Codegen, cond: []const u8, kind: types.FixedIntKind) CodegenError!void {
    const trap_label = try self.newLabel("ovf_trap");
    const ok_label = try self.newLabel("ovf_ok");
    try self.qbeJnz(cond, trap_label, ok_label);
    try self.qbeLabel(trap_label);
    const name_sym = try self.internFmtString(kind.name());
    try self.qbeCall(null, "$nox_int_overflow_trap", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = name_sym } });
    try self.emitDefaultReturn(self.current_ret_qtype);
    try self.qbeLabel(ok_label);
}

/// v2.0 madde 4 (§4): `u8(x)`/`i32(x)`/vb. — DARALTMA cast'i. `emitChecked
/// FixedBin*`in AKSİNE (SADECE QBE'de kontrollü), BU HER ZAMAN (backend
/// FARK ETMEKSİZİN) aralık-kontrollüdür — plan notu: "sarma SADECE
/// işlemler sırasında (backend'e göre); dönüşümler HER ZAMAN kontrollü."
///
/// Algoritma: `v`yi ÖNCE 64-bit'lik "kanonik" bir `.l` temsile getirir
/// (`float` İçİn `dtosi`, `.w`de hesaplanan 8/16/32-bit kind'ler İçİn
/// `widenFixedIntForPrint`in AYNI sign/zero-extend deseni — SONUÇ HER
/// ZAMAN i64 olarak GÜVENLE karşılaştırılabilir büyüklükte OLDUĞUNDAN
/// bu genişletmeden SONRA "signed" karşılaştırma HER ZAMAN doğrudur),
/// SONRA hedef kind'in [min,max] aralığına göre kontrol eder. **Tek
/// özel durum**: kaynak İMZASIZ 64-bit (`u64`/`usize`) VE hedef `u64`/
/// `usize` DIŞINDA bir 64-bit hedef (`i64`/`isize`) İSE, kaynağın ham
/// bit örüntüsü i64::MAX'ı AŞABİLİR (İMZALI yorumda NEGATİF görünür) —
/// bu durumda GERÇEK kısıt "değer negatif mi" (0'dan büyük-eşit) OLUR,
/// `i64::MIN` DEĞİL (aksi halde `u64::MAX` YANLIŞLIKLA `i64(-1)`e
/// "sığar" görünürdü — DENENİP bu tuzak BULUNDU).
pub fn genNarrowingCast(self: *Codegen, v: Value, target_kind: types.FixedIntKind) CodegenError!Value {
    var wide: Value = undefined;
    var source_is_unsigned = false;
    if (v.qtype == .d) {
        wide = try self.convert(v, .l);
    } else if (v.fixed_int) |sk| {
        if (sk.bitWidth() == 64) {
            wide = v;
            source_is_unsigned = !sk.isSigned();
        } else {
            wide = try self.widenFixedIntForPrint(v, sk);
        }
    } else {
        wide = v; // düz `int`, zaten `.l`, işaretli.
    }

    if (target_kind.bitWidth() == 64 and !target_kind.isSigned()) {
        // Hedef `u64`/`usize`: HERHANGİ bir 64-bit örüntü GEÇERLİDİR —
        // TEK kısıt, kaynak İMZALIYSA negatif OLMAMASIDIR.
        if (!source_is_unsigned) {
            const neg = try self.newTemp();
            try self.qbeOp2Imm(neg, .w, "csltl", wide.text, 0);
            try self.emitOverflowTrapIfNonzero(neg, target_kind);
        }
    } else {
        const target_min: i64 = if (!target_kind.isSigned())
            0
        else if (source_is_unsigned and target_kind.bitWidth() == 64)
            0
        else switch (target_kind.bitWidth()) {
            8 => -128,
            16 => -32768,
            32 => -2147483648,
            64 => std.math.minInt(i64),
            else => unreachable,
        };
        const target_max: i64 = switch (target_kind.bitWidth()) {
            8 => if (target_kind.isSigned()) 127 else 255,
            16 => if (target_kind.isSigned()) 32767 else 65535,
            32 => if (target_kind.isSigned()) 2147483647 else 4294967295,
            64 => std.math.maxInt(i64),
            else => unreachable,
        };
        const below = try self.newTemp();
        try self.qbeOp2Imm(below, .w, "csltl", wide.text, target_min);
        const above = try self.newTemp();
        try self.qbeOp2Imm(above, .w, "csgtl", wide.text, target_max);
        const out_of_range = try self.newTemp();
        try self.qbeOp2(out_of_range, .w, "or", below, above);
        try self.emitOverflowTrapIfNonzero(out_of_range, target_kind);
    }

    if (target_kind.bitWidth() == 64) {
        return .{ .text = wide.text, .qtype = .l, .fixed_int = target_kind };
    }
    const truncated = try self.newTemp();
    try self.qbeOp1(truncated, .w, "copy", wide.text);
    return .{ .text = truncated, .qtype = .w, .fixed_int = target_kind };
}

pub fn emitCmp(self: *Codegen, op: ast.BinaryOp, l: Value, r: Value, common: QbeType) CodegenError!Value {
    // v2.0 madde 4 (§7): sabit-genişlikli bir kind İSE karşılaştırma
    // MNEMONİĞİ onun işaretliliğine göre seçilir (checker'ın "aynı-kind-
    // only" kısıtı — bkz. `requireSameFixedIntOrNone` — İKİ tarafın da
    // AYNI kind OLMASINI GARANTİ ettiğinden, YALNIZCA `l`ye BAKMAK yeterli).
    // Hiçbiri fixed_int DEĞİLSE (mevcut int/float/bool) `signed = true`
    // — DAVRANIŞ DEĞİŞMEZ.
    const signed = if (l.fixed_int) |k| k.isSigned() else true;
    const t = try self.newTemp();
    try self.qbeOp2(t, .w, cmpMnemonic(op, common, signed), l.text, r.text);
    return .{ .text = t, .qtype = .w };
}

pub fn callLibm1(self: *Codegen, comptime name: []const u8, v: Value) CodegenError!Value {
    const t = try self.newTemp();
    try self.qbeCall(.{ .name = t, .ty = .d }, "$" ++ name, &.{.{ .ty = .d, .text = v.text }});
    return .{ .text = t, .qtype = .d };
}

pub fn callLibm2(self: *Codegen, comptime name: []const u8, l: Value, r: Value) CodegenError!Value {
    const t = try self.newTemp();
    try self.qbeCall(.{ .name = t, .ty = .d }, "$" ++ name, &.{ .{ .ty = .d, .text = l.text }, .{ .ty = .d, .text = r.text } });
    return .{ .text = t, .qtype = .d };
}

/// `strcmp` (libc, `cc` bağlantısında zaten mevcut — `printf` gibi başka
/// çağrılarla AYNI şekilde ekstra bir bağlama argümanı gerekmez) ile iki
/// `str`in İÇERİĞİNİ karşılaştırır; sonucu `0`a karşı `w` bir bool'a çevirir.
pub fn genStrCompare(self: *Codegen, op: ast.BinaryOp, l: Value, r: Value) CodegenError!Value {
    const cmp_t = try self.newTemp();
    try self.qbeCall(.{ .name = cmp_t, .ty = .w }, "$strcmp", &.{ .{ .ty = .l, .text = l.text }, .{ .ty = .l, .text = r.text } });
    const result = try self.newTemp();
    const mnemonic: []const u8 = if (op == .eq) "ceqw" else "cnew";
    try self.qbeOp2Imm(result, .w, mnemonic, cmp_t, 0);
    return .{ .text = result, .qtype = .w };
}

/// İki aynı-tipli değerin eşitliği (`w` 0/1 temp metni): `genBinary`nin `==` dallarıyla AYNI yollar —
/// `str` (`strcmp`), `class`/`list` (`$X_eq`), skaler (ortak tipe `convert` + `ceq*`). `genIn` liste elemanlarını
/// aranan değerle karşılaştırmak için kullanır.
pub fn emitValueEq(self: *Codegen, l0: Value, r0: Value) CodegenError![]const u8 {
    if (l0.heap == .str and r0.heap == .str) return (try self.genStrCompare(.eq, l0, r0)).text;
    if ((l0.heap == .list or l0.heap == .class) and r0.heap == l0.heap) {
        const t = try self.newTemp();
        if (l0.heap == .class) {
            const eq_sym = try std.fmt.allocPrint(self.allocator, "${s}_eq", .{l0.class_name.?});
            try self.qbeCall(.{ .name = t, .ty = .w }, eq_sym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = l0.text }, .{ .ty = .l, .text = r0.text } });
        } else {
            const fn_name = try self.eqFnNameForList(l0.elem_qtype, l0.elem_heap_info, l0.elem_is_str);
            const eq_sym = try std.fmt.allocPrint(self.allocator, "${s}_eq", .{fn_name});
            try self.qbeCall(.{ .name = t, .ty = .w }, eq_sym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = l0.text }, .{ .ty = .l, .text = r0.text } });
        }
        return t;
    }
    if (l0.heap != .none or r0.heap != .none) return error.Unsupported;
    const common: QbeType = if (l0.qtype == .d or r0.qtype == .d) .d else if (l0.qtype == .w or r0.qtype == .w) .w else .l;
    const l = try self.convert(l0, common);
    const r = try self.convert(r0, common);
    return (try self.emitCmp(.eq, l, r, common)).text;
}

/// v1.150.0: `coll` listesinde `x`e EŞİT (`emitValueEq`) ilk elemanın indeksini (`l` temp metni) ya da bulunamazsa `-1`
/// döner (doğrusal tarama). `in`, `list.index` ve `list.remove` ortak kullanır; eleman ödünç okunur (retain/release yok).
pub fn emitListFind(self: *Codegen, coll: Value, x: Value) CodegenError![]const u8 {
    const idx_slot = try self.newTemp();
    try self.qbeAlloc(idx_slot, .eight, 8);
    const res_slot = try self.newTemp();
    try self.qbeAlloc(res_slot, .eight, 8);
    try self.qbeStoreImmL(0, idx_slot);
    try self.qbeStoreImmL(-1, res_slot);
    const len_t = try self.newTemp();
    try self.qbeLoadL(len_t, coll.text);

    const cond_label = try self.newLabel("find_cond");
    const body_label = try self.newLabel("find_body");
    const next_label = try self.newLabel("find_next");
    const hit_label = try self.newLabel("find_hit");
    const done_label = try self.newLabel("find_done");
    try self.qbeJmp(cond_label);
    try self.qbeLabel(cond_label);
    const idx = try self.newTemp();
    try self.qbeLoadL(idx, idx_slot);
    const cmp = try self.newTemp();
    try self.qbeOp2(cmp, .w, "csltl", idx, len_t);
    try self.qbeJnz(cmp, body_label, done_label);
    try self.qbeLabel(body_label);

    const elem = try self.loadListElemValueAt(coll, idx);
    const eq = try emitValueEq(self, elem, x);
    try self.qbeJnz(eq, hit_label, next_label);

    try self.qbeLabel(hit_label);
    try self.qbeStoreL(idx, res_slot);
    try self.qbeJmp(done_label);

    try self.qbeLabel(next_label);
    const idx2 = try self.newTemp();
    try self.qbeOp2Imm(idx2, .l, "add", idx, 1);
    try self.qbeStoreL(idx2, idx_slot);
    try self.qbeJmp(cond_label);

    try self.qbeLabel(done_label);
    const res = try self.newTemp();
    try self.qbeLoadL(res, res_slot);
    return res;
}

/// v1.150.0: `list.count(x)` — `x`e eşit eleman sayısı (`l` temp metni).
pub fn emitListCount(self: *Codegen, coll: Value, x: Value) CodegenError![]const u8 {
    const idx_slot = try self.newTemp();
    try self.qbeAlloc(idx_slot, .eight, 8);
    const cnt_slot = try self.newTemp();
    try self.qbeAlloc(cnt_slot, .eight, 8);
    try self.qbeStoreImmL(0, idx_slot);
    try self.qbeStoreImmL(0, cnt_slot);
    const len_t = try self.newTemp();
    try self.qbeLoadL(len_t, coll.text);

    const cond_label = try self.newLabel("count_cond");
    const body_label = try self.newLabel("count_body");
    const inc_label = try self.newLabel("count_inc");
    const next_label = try self.newLabel("count_next");
    const done_label = try self.newLabel("count_done");
    try self.qbeJmp(cond_label);
    try self.qbeLabel(cond_label);
    const idx = try self.newTemp();
    try self.qbeLoadL(idx, idx_slot);
    const cmp = try self.newTemp();
    try self.qbeOp2(cmp, .w, "csltl", idx, len_t);
    try self.qbeJnz(cmp, body_label, done_label);
    try self.qbeLabel(body_label);

    const elem = try self.loadListElemValueAt(coll, idx);
    const eq = try emitValueEq(self, elem, x);
    try self.qbeJnz(eq, inc_label, next_label);

    try self.qbeLabel(inc_label);
    const c0 = try self.newTemp();
    try self.qbeLoadL(c0, cnt_slot);
    const c1 = try self.newTemp();
    try self.qbeOp2Imm(c1, .l, "add", c0, 1);
    try self.qbeStoreL(c1, cnt_slot);
    try self.qbeJmp(next_label);

    try self.qbeLabel(next_label);
    const idx2 = try self.newTemp();
    try self.qbeOp2Imm(idx2, .l, "add", idx, 1);
    try self.qbeStoreL(idx2, idx_slot);
    try self.qbeJmp(cond_label);

    try self.qbeLabel(done_label);
    const res = try self.newTemp();
    try self.qbeLoadL(res, cnt_slot);
    return res;
}

/// v1.145.0: `a in b` / `a not in b`. Sol işlenen ÖNCE, sonra sağ işlenen değerlendirilir. `str` içinde alt-dize
/// (`$nox_str_contains`), `dict`te anahtar (`$nox_dict_contains`, `d.contains(k)` ile aynı), `list[T]`de eleman eşitliği
/// (doğrusal tarama; eşitlik `==` ile aynı yollar, bkz. `emitValueEq`). Sonuç `w` (0/1); `not in` sonucu tersler.
pub fn genIn(self: *Codegen, b: ast.Binary) CodegenError!Value {
    const x = try self.genExpr(b.left.*);
    const coll = try self.genExpr(b.right.*);
    try self.checkNoLowlevelEscape(x);
    try self.checkNoLowlevelEscape(coll);

    var found: []const u8 = undefined;
    switch (coll.heap) {
        .str => {
            const t = try self.newTemp();
            try self.qbeCall(.{ .name = t, .ty = .l }, "$nox_str_contains", &.{ .{ .ty = .l, .text = coll.text }, .{ .ty = .l, .text = x.text } });
            const w = try self.newTemp();
            try self.qbeOp2Imm(w, .w, "cnel", t, 0);
            found = w;
        },
        .dict => {
            const dinfo = coll.dict_info orelse return error.Unsupported;
            const key_payload = try self.toPayload(x);
            const key_is_str_lit: []const u8 = if (dinfo.key_is_str) "1" else "0";
            const t = try self.newTemp();
            try self.qbeCall(.{ .name = t, .ty = .w }, "$nox_dict_contains", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = coll.text }, .{ .ty = .w, .text = key_is_str_lit }, .{ .ty = .l, .text = key_payload.text } });
            found = t;
        },
        .list => {
            const hit = try emitListFind(self, coll, x);
            const w = try self.newTemp();
            try self.qbeOp2Imm(w, .w, "cnel", hit, -1);
            found = w;
        },
        else => return error.Unsupported,
    }

    try self.releaseIfTemporary(b.left.*, x);
    try self.releaseIfTemporary(b.right.*, coll);
    if (b.op == .not_in) {
        const t = try self.newTemp();
        try self.qbeOp2Imm(t, .w, "xor", found, 1);
        return .{ .text = t, .qtype = .w };
    }
    return .{ .text = found, .qtype = .w };
}

/// `genTernary`nin tek bir dalı: koşulun ilgili tarafında Optional daraltması varsa (`boxed_scalar`) o dal için
/// `narrowed_unbox`a eklenir; `mod_cache` anlık görüntüsü geri yüklenir (dal çalışmamış olabilir); heap-yönetimli
/// bir sonuç ÖDÜNÇ ise (`identifier`/alan/eleman okuması) retain edilir — böylece ternary'nin sonucu HER ZAMAN
/// sahipli (+1) bir değerdir (`isTemporaryExpr(.ternary) == true`).
pub fn genTernaryBranch(self: *Codegen, branch: ast.Expr, narrowed: []const []const u8) CodegenError!Value {
    const mc_snap = try self.snapshotModCache();
    var was: [8]bool = .{false} ** 8;
    for (narrowed, 0..) |n, i| {
        was[i] = self.narrowed_unbox.contains(n);
        try self.narrowed_unbox.put(self.allocator, n, {});
    }
    var v = try self.genExpr(branch);
    for (narrowed, 0..) |n, i| if (!was[i]) {
        _ = self.narrowed_unbox.remove(n);
    };
    self.restoreModCache(mc_snap);
    try self.checkNoLowlevelEscape(v);
    v = try self.retainIfAliasing(branch, v);
    v.always_fresh = false;
    v.is_pinned = false;
    v.is_stack_slot = false;
    return v;
}

/// v1.146.0: `then if cond else else_` — yalnızca seçilen dal değerlendirilir. `phi` ile birleşir (`and`/`or`
/// ile aynı desen: öncül etiket `current_label`dir, çünkü dal ifadesi kendi blokları üretmiş olabilir).
pub fn genTernary(self: *Codegen, t: ast.Ternary) CodegenError!Value {
    const cond = try self.genExpr(t.cond.*);
    const then_label = try self.newLabel("tern_then");
    const else_label = try self.newLabel("tern_else");
    const end_label = try self.newLabel("tern_end");
    try self.qbeJnz(cond.text, then_label, else_label);

    var then_n: NameList = .{};
    var else_n: NameList = .{};
    self.collectNarrowedBoxed(t.cond.*, true, &then_n);
    self.collectNarrowedBoxed(t.cond.*, false, &else_n);
    try self.qbeLabel(then_label);
    const vt = try genTernaryBranch(self, t.then_expr.*, then_n.slice());
    const then_pred = self.current_label;
    try self.qbeJmp(end_label);

    try self.qbeLabel(else_label);
    const ve = try genTernaryBranch(self, t.else_expr.*, else_n.slice());
    const else_pred = self.current_label;
    try self.qbeJmp(end_label);

    try self.qbeLabel(end_label);
    const result_t = try self.newTemp();
    try self.qbePhi(result_t, vt.qtype, then_pred, vt.text, else_pred, ve.text);
    var result = vt;
    result.text = result_t;
    return result;
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
    // `and`/`or` KISA DEVRE yapar (bkz. nox-teknik-spesifikasyon.md §"Bilinen
    // sınırlamalar" — ESKİDEN "v0.1'de bilinçli bir basitleştirme" olarak
    // belgelenen bu davranış GERÇEK bir çökmeye yol açtığı İÇİN düzeltildi:
    // `pos < n and text[pos] == "X"` gibi bir koruma örüntüsünde `pos >= n`
    // İKEN `text[pos]`in HÂLÂ değerlendirilmesi bir IndexError'a, sınırın
    // TAM ÜZERİNDE İSE bir NULL-işaretçi SIGSEGV'e yol açıyordu). Checker
    // (`checkBinary`in `.and_, .or_` dalı) HER İKİ operandın da `.boolean`
    // OLMASINI ZORUNLU KILAR — bu yüzden birleştirilmiş değer HER ZAMAN `.w`
    // (0/1) olur VE `and`/`or`ın KENDİ operandları HİÇBİR ZAMAN heap-yönetimli
    // DEĞİLDİR (retain/release GEREKMEZ) — SADECE kontrol akışı değişir.
    // Örüntü, `calls.zig`deki `str(bool)`nin AYNI jnz+phi şablonuyla BİREBİR
    // AYNIDIR.
    if (b.op == .and_ or b.op == .or_) {
        const l = try self.genExpr(b.left.*);
        const rhs_label = try self.newLabel("logic_rhs");
        const short_label = try self.newLabel("logic_short");
        const done_label = try self.newLabel("logic_done");
        if (b.op == .and_) {
            try self.qbeJnz(l.text, rhs_label, short_label);
        } else {
            try self.qbeJnz(l.text, short_label, rhs_label);
        }
        try self.qbeLabel(short_label);
        const short_value: []const u8 = if (b.op == .and_) "0" else "1";
        // `short_label`den `qbeJmp`e KADAR HİÇBİR şey dallanmadığından
        // (`short_value` SABİT bir literal) `self.current_label` HÂLÂ
        // `short_label`dir — YİNE DE `self.current_label`i KULLANMAK
        // (`short_label`i DOĞRUDAN KULLANMAK YERİNE) BURADAKİ VE aşağıdaki
        // `rhs` dalıyla AYNI, TEK bir doğruluk İLKESİNİ (phi'nin önceli
        // HER ZAMAN "en son yazılan etiket"tir) KORUR.
        const short_pred = self.current_label;
        try self.qbeJmp(done_label);
        try self.qbeLabel(rhs_label);
        const r = try self.genExpr(b.right.*);
        // KRİTİK: `b.right` KEYFİ bir ifadedir — KENDİ İçİNDE BAŞKA bir
        // `and`/`or`/istisna-kontrolü/vb. İçEREBİLİR, bu YÜZDEN `genExpr`
        // döndüğünde "şu anki blok" ARTIK `rhs_label` OLMAYABİLİR (o alt-
        // ifadenin KENDİ ÜRETTİĞİ EN SON etiket OLABİLİR) — `qbePhi`nin
        // önceli OLARAK `rhs_label`i SABİT varsaymak "predecessors not
        // matched in phi" hatasına yol açar (GERÇEK bir regresyonla
        // KANITLANDI). `self.current_label` (bkz. `qbeLabel`in belge
        // notu) HER ZAMAN GERÇEK, GÜNCEL bloğu taşır.
        const rhs_pred = self.current_label;
        try self.qbeJmp(done_label);
        try self.qbeLabel(done_label);
        const result_t = try self.newTemp();
        try self.qbePhi(result_t, .w, short_pred, short_value, rhs_pred, r.text);
        return .{ .text = result_t, .qtype = .w };
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
        try self.qbeOp2Imm(cmp_t, .w, mnemonic, other.text, 0);
        try self.releaseIfTemporary(other_expr, other);
        return .{ .text = cmp_t, .qtype = .w };
    }

    if (b.op == .in_ or b.op == .not_in) return self.genIn(b);

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
        // GG.13 (bkz. nox-teknik-spesifikasyon.md §3.66): küçük (≤8 alan),
        // paylaşılan `$ClassName_eq`e bir `call`+dönüş yerine, karşılaştırıcıyı
        // DOĞRUDAN BU kullanım sitesine splice et — `list == list` (HER ZAMAN
        // bir döngü gerektirir) BU optimizasyonun kapsamı DIŞINDA kalır.
        const eq_temp: []const u8 = if (l0.heap == .class and classEqInlineEligible(self.classes.get(l0.class_name.?).?))
            try self.genClassEqInline(self.classes.get(l0.class_name.?).?, l0.text, r0.text)
        else blk: {
            const t = try self.newTemp();
            if (l0.heap == .class) {
                const eq_sym = try std.fmt.allocPrint(self.allocator, "${s}_eq", .{l0.class_name.?});
                try self.qbeCall(.{ .name = t, .ty = .w }, eq_sym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = l0.text }, .{ .ty = .l, .text = r0.text } });
            } else {
                const fn_name = try self.eqFnNameForList(l0.elem_qtype, l0.elem_heap_info, l0.elem_is_str);
                const eq_sym = try std.fmt.allocPrint(self.allocator, "${s}_eq", .{fn_name});
                try self.qbeCall(.{ .name = t, .ty = .w }, eq_sym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = l0.text }, .{ .ty = .l, .text = r0.text } });
            }
            break :blk t;
        };
        const result: []const u8 = if (b.op == .ne) blk: {
            const t = try self.newTemp();
            try self.qbeOp2Imm(t, .w, "xor", eq_temp, 1);
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
        try self.qbeCall(.{ .name = result_t, .ty = .l }, "$nox_str_concat", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = l0.text }, .{ .ty = .l, .text = r0.text } });
        try self.releaseIfTemporary(b.left.*, l0);
        try self.releaseIfTemporary(b.right.*, r0);
        return .{ .text = result_t, .qtype = .l, .heap = .str };
    }

    // v1.153.0: `str < str` / `<=` / `>` / `>=` — `strcmp` (bayt sırası; UTF-8'de codepoint sırasıyla aynı).
    if (l0.heap == .str and r0.heap == .str and (b.op == .lt or b.op == .le or b.op == .gt or b.op == .ge)) {
        const cmp_t = try self.newTemp();
        try self.qbeCall(.{ .name = cmp_t, .ty = .w }, "$strcmp", &.{ .{ .ty = .l, .text = l0.text }, .{ .ty = .l, .text = r0.text } });
        const result = try self.newTemp();
        const mnemonic: []const u8 = switch (b.op) {
            .lt => "csltw",
            .le => "cslew",
            .gt => "csgtw",
            else => "csgew",
        };
        try self.qbeOp2Imm(result, .w, mnemonic, cmp_t, 0);
        try self.releaseIfTemporary(b.left.*, l0);
        try self.releaseIfTemporary(b.right.*, r0);
        return .{ .text = result, .qtype = .w };
    }
    // v1.153.0: `str * n` / `n * str` — `nox_str_repeat` (tek tahsis). Sonuç TAZE (+1).
    if (b.op == .mul and ((l0.heap == .str and r0.heap == .none) or (l0.heap == .none and r0.heap == .str))) {
        const s = if (l0.heap == .str) l0 else r0;
        const n0 = if (l0.heap == .str) r0 else l0;
        const n = try self.convert(n0, .l);
        const result_t = try self.newTemp();
        try self.qbeCall(.{ .name = result_t, .ty = .l }, "$nox_str_repeat", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = s.text }, .{ .ty = .l, .text = n.text } });
        try self.releaseIfTemporary(if (l0.heap == .str) b.left.* else b.right.*, s);
        return .{ .text = result_t, .qtype = .l, .heap = .str };
    }

    // v1.150.0: `list[T] + list[T]` ve `list[T] * n` / `n * list[T]` — YENİ bir liste (heap-yönetimli elemanlar retain edilir;
    // `nox_list_concat`/`nox_list_repeat`, bkz. `runtime/collections/list_ops.zig`). Sonuç TAZE (+1) bir değerdir.
    if (l0.heap == .list and r0.heap == .list and b.op == .add) {
        try self.checkNoLowlevelEscape(l0);
        try self.checkNoLowlevelEscape(r0);
        const result_t = try self.newTemp();
        try self.qbeCall(.{ .name = result_t, .ty = .l }, "$nox_list_concat", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = l0.text }, .{ .ty = .l, .text = r0.text }, .{ .ty = .l, .text = try self.listEszLit(l0) }, .{ .ty = .w, .text = self.listKindLit(l0) } });
        try self.releaseIfTemporary(b.left.*, l0);
        try self.releaseIfTemporary(b.right.*, r0);
        return self.freshListValue(l0, result_t);
    }
    if (b.op == .mul and ((l0.heap == .list and r0.heap == .none) or (l0.heap == .none and r0.heap == .list))) {
        const lst = if (l0.heap == .list) l0 else r0;
        const n0 = if (l0.heap == .list) r0 else l0;
        try self.checkNoLowlevelEscape(lst);
        const n = try self.convert(n0, .l);
        const result_t = try self.newTemp();
        try self.qbeCall(.{ .name = result_t, .ty = .l }, "$nox_list_repeat", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = lst.text }, .{ .ty = .l, .text = n.text }, .{ .ty = .l, .text = try self.listEszLit(lst) }, .{ .ty = .w, .text = self.listKindLit(lst) } });
        try self.releaseIfTemporary(if (l0.heap == .list) b.left.* else b.right.*, lst);
        return self.freshListValue(lst, result_t);
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

    // v3 madde 2 (bitwise operatörler): `<<`/`>>` kaydırma miktarının
    // ÇALIŞMA ZAMANI doğrulaması GEREKTİRDİĞİNDEN (checker bunu derleme
    // zamanında YAPAMAZ, miktar keyfi bir ifade olabilir) — VE sonucun
    // genişliği/işaretliliği `l0`nin KENDİSİNDEN (`r0`nin DEĞİL) geldiğinden
    // — aşağıdaki GENEL `common` hesaplamasının (İKİ operandı da AYNI
    // genişliğe zorlayan) DIŞINDA, KENDİ ÖZEL yoluna sahiptir (bkz.
    // `genCheckedShift`in belge notu).
    if (b.op == .shl or b.op == .shr) {
        return self.genCheckedShift(b.op, l0, r0);
    }

    const common: QbeType = if (l0.qtype == .d or r0.qtype == .d)
        .d
    else if (l0.qtype == .w or r0.qtype == .w)
        .w
    else
        .l;
    const l = try self.convert(l0, common);
    const r = try self.convert(r0, common);
    // v2.0 madde 4: checker'ın "aynı-kind-only" kısıtı (bkz.
    // `requireSameFixedIntOrNone`) İKİ tarafın da AYNI `FixedIntKind`
    // OLMASINI GARANTİ ettiğinden, YALNIZCA `l0`ye BAKMAK yeterlidir.
    const fixed_kind: ?types.FixedIntKind = l0.fixed_int;

    return switch (b.op) {
        .add => if (fixed_kind) |k| self.emitCheckedFixedBin("add", l, r, k) else self.emitBin("add", l, r, common),
        .sub => if (fixed_kind) |k| self.emitCheckedFixedBin("sub", l, r, k) else self.emitBin("sub", l, r, common),
        .mul => if (fixed_kind) |k| self.emitCheckedFixedBin("mul", l, r, k) else self.emitBin("mul", l, r, common),
        .floordiv => blk: {
            try emitZeroDivisorCheck(self, r, common);
            break :blk self.genFloorDiv(l, r, common);
        },
        .mod => blk: {
            try emitZeroDivisorCheck(self, r, common);
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
        // v3 madde 2: bitwise `&`/`|`/`^` — taşma RİSKİ olmadığından
        // (`add`/`sub`/`mul`ın AKSİNE, bkz. `emitCheckedFixedBin`in belge
        // notu) sabit-genişlikli kind'ler İçİN de DOĞRUDAN `common`
        // genişliğinde hesaplanabilir — bit-per-bit işlemler ekstra
        // genişlikten ETKİLENMEZ (her bit BAĞIMSIZ hesaplanır). **DÜZELTME
        // (GERÇEK bir hata, `bitwise_ops.nox` golden test'İYLE
        // YAKALANDI):** `emitBin`in dönüşü `fixed_int` alanını HİÇ
        // DOLDURMAZ (`null` KALIR) — checker `u8&u8` İçİn `fixed_int(u8)`
        // döndürse BİLE, bu etiket EKLENMEZSE `genPrint` sonucu (yanlışlıkla,
        // `.w`+`fixed_int==null` deseni SIRADAN bir `bool`la ÇAKIŞTIĞINDAN)
        // "True"/"False" olarak BASAR — `add`/`sub`/`mul`ın `emitCheckedFixedBin`
        // ARACILIĞIYLA ZATEN yaptığı GİBİ, sonuca `fixed_kind` AÇIKÇA
        // damgalanmalı.
        .bit_and => blk: {
            var v = try self.emitBin("and", l, r, common);
            v.fixed_int = fixed_kind;
            break :blk v;
        },
        .bit_or => blk: {
            var v = try self.emitBin("or", l, r, common);
            v.fixed_int = fixed_kind;
            break :blk v;
        },
        .bit_xor => blk: {
            var v = try self.emitBin("xor", l, r, common);
            v.fixed_int = fixed_kind;
            break :blk v;
        },
        .div, .and_, .or_, .shl, .shr, .in_, .not_in => unreachable,
    };
}

/// v3 madde 2 (bitwise operatörler, bkz. nox-teknik-spesifikasyon.md ilgili
/// bölüm): `<<`/`>>`in TEK giriş noktası. Kaydırma miktarının GEÇERLİ
/// ARALIKTA ([0, bit-genişliği)) olduğunu ÇALIŞMA ZAMANINDA doğrular
/// (checker bunu derleme zamanında YAPAMAZ — miktar keyfi bir ifade
/// olabilir) — kullanıcı KARARI: geçersizse SESSİZCE maskelemek YERİNE
/// bir `ValueError` fırlatılır (platformdan bağımsız/deterministik
/// davranış, bkz. proje belleği "v3 sertleştirme yol haritası"). `>>`in
/// KENDİSİ işaretliliğe göre `sar` (aritmetik, işaretli tipler/`int`) ya
/// da `shr` (mantıksal, işaretsiz sabit-genişlikli tipler) İLE derlenir —
/// C/Rust/Zig'in (VE nox-lang'in KENDİ HPy köprüsünün, `runtime/hpy_
/// bridge/context.zig`nin `bitwiseBinOp`ının, orada `>>` Zig'in KENDİ
/// işaretli `i64`i için HER ZAMAN aritmetik) AYNI emsali. `genParseOrRaise`
/// (calls.zig) İLE AYNI "önce doğrula, hata dalında raise et, phi'siz
/// ok'e atla" deseni — TEK fark, ok-dalının hesapladığı DEĞER (`add`/`sub`
/// GİBİ değil) `r0`ye DEĞİL `l0`nin genişliğine göre yeniden hesaplanır.
pub fn genCheckedShift(self: *Codegen, op: ast.BinaryOp, l0: Value, r0: Value) CodegenError!Value {
    const fixed_kind: ?types.FixedIntKind = l0.fixed_int;
    const width: i64 = if (fixed_kind) |k| k.bitWidth() else 64;
    const signed: bool = if (fixed_kind) |k| k.isSigned() else true;

    const neg_t = try self.newTemp();
    try self.qbeOp2Imm(neg_t, .w, "csltl", r0.text, 0);
    const hi_t = try self.newTemp();
    try self.qbeOp2Imm(hi_t, .w, "csgel", r0.text, width);
    const bad_t = try self.newTemp();
    try self.qbeOp2(bad_t, .w, "or", neg_t, hi_t);

    const err_label = try self.newLabel("shift_err");
    const ok_label = try self.newLabel("shift_ok");
    try self.qbeJnzCold(bad_t, err_label, ok_label);
    const cold_start = self.beginCold();
    try self.qbeLabel(err_label);

    const msg_value = try self.emitStringLiteral("kaydirma miktari gecersiz (negatif ya da tipin bit genisligini asiyor)");
    const ve_cinfo = self.classes.get("ValueError") orelse return error.Unsupported;
    const ve_obj = try self.genConstructFromValues("ValueError", ve_cinfo, &.{msg_value}, null);
    try self.emitExceptionLineStore(ve_obj.text, "ValueError", self.current_raise_line);
    try self.qbeCall(null, "$nox_raise", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ve_obj.text }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{self.current_raise_line}) } });
    try self.emitRaisePropagate();
    try self.stashCold(cold_start);

    try self.qbeLabel(ok_label);
    const r = try self.convert(r0, l0.qtype);
    const mnemonic: []const u8 = if (op == .shl) "shl" else if (signed) "sar" else "shr";
    const t = try self.newTemp();
    try self.qbeOp2(t, l0.qtype, mnemonic, l0.text, r.text);
    // **`<<` İçİn dar (8/16-bit) kind'lerde AYRICA yeniden-daraltma
    // GEREKİR (`~`in AYNI belge notundaki gerekçe) — sola kaydırma bitleri
    // YUKARI taşıdığından, dar bir değerin "genişletme" bölgesine GERÇEK
    // veri sızdırabilir (ör. `u8(200) << 2`, ham 32-bit'te 800 verir,
    // OYSA u8 MANTIĞI 32'ye SARMALIDIR — Zig'in/Rust'ın/C'nin KENDİ `<<`
    // operatörüyle AYNI, SESSİZ sarma semantiği, `add`/`sub`/`mul`ın
    // taşma-TUZAKLAMASINDAN BİLİNÇLİ olarak FARKLI: bit kaydırmada üst
    // bitlerin "kaybolması" HER ZAMAN kasıtlı/beklenen bir işlemdir, bir
    // mantık hatası GÖSTERGESİ DEĞİL). `>>` (sar/shr) İçİN bu adım
    // GEREKMEZ — sağa kaydırma ZATEN üst (genişletme) bitlerinden
    // GELDİĞİNDEN sonucun KENDİSİ otomatik olarak doğru kalır (bkz. plan
    // dosyasının doğrulaması).
    if (op == .shl) {
        if (fixed_kind) |k| {
            if (k == .u8 or k == .i8 or k == .u16 or k == .i16) {
                const ext_mnemonic: []const u8 = switch (k) {
                    .u8 => "extub",
                    .i8 => "extsb",
                    .u16 => "extuh",
                    .i16 => "extsh",
                    else => unreachable,
                };
                const narrowed = try self.newTemp();
                try self.qbeOp1(narrowed, .w, ext_mnemonic, t);
                return .{ .text = narrowed, .qtype = .w, .fixed_int = k };
            }
        }
    }
    return .{ .text = t, .qtype = l0.qtype, .fixed_int = fixed_kind };
}

/// v1.159.0: tamsayı `//` ve `%` sıfır bölenle `ZeroDivisionError` fırlatır (önceden LLVM'de tanımsız davranış,
/// QBE'de çöp/0). Sabit pozitif bölen kontrolsüz kalır. `float` bölme IEEE (inf/nan) olarak kalır.
fn emitZeroDivisorCheck(self: *Codegen, r: Value, common: QbeType) CodegenError!void {
    if (common == .d) return;
    if (optimizations.constPositiveDivisor(r) != null) return;
    const bad = try self.newTemp();
    try self.qbeOp2Imm(bad, .w, if (r.qtype == .l) "ceql" else "ceqw", r.text, 0);
    try calls.emitColdListError(self, bad, "ZeroDivisionError", "sifira bolme", &.{});
}

pub fn genFloorDiv(self: *Codegen, l: Value, r: Value, common: QbeType) CodegenError!Value {
    if (common == .d) {
        const divided = try self.emitBin("div", l, r, .d);
        return self.callLibm1("floor", divided);
    }

    // v1.142.5 (bkz. nox-teknik-spesifikasyon.md §3.244) — sabit pozitif bölen
    // + 2'nin kuvveti: `x // 2^k` Python'un TABAN bölmesiyle (negatiflerde
    // -∞'a yuvarlama) BİREBİR `sar x, k`dır (aritmetik kaydırma taban
    // bölmesidir). Ne `div`, ne `rem`, ne düzeltme dizisi.
    if (optimizations.constPositiveDivisor(r)) |d| {
        if (l.qtype == .l and l.fixed_int == null) {
            if (d == 1) return .{ .text = l.text, .qtype = .l };
            if (std.math.isPowerOfTwo(@as(u64, @intCast(d)))) {
                const shifted = try self.newTemp();
                try self.qbeOp2(shifted, .l, "sar", l.text, try std.fmt.allocPrint(self.allocator, "{d}", .{@ctz(@as(u64, @intCast(d)))}));
                return .{ .text = shifted, .qtype = .l };
            }
        }
    }

    // Tek bölme: kalan, ikinci bir `rem` (QBE bunu SIFIRDAN sdiv+msub'a
    // çevirir — yani İKİNCİ bir bölme) YERİNE `l - q*r` ile türetilir.
    const q = try self.emitBin("div", l, r, .l);
    const prod = try self.emitBin("mul", q, r, .l);
    const rem = try self.emitBin("sub", l, prod, .l);

    const rem_nonzero = try self.newTemp();
    try self.qbeOp2Imm(rem_nonzero, .w, "cnel", rem.text, 0);
    const rem_neg = try self.newTemp();
    try self.qbeOp2Imm(rem_neg, .w, "csltl", rem.text, 0);
    const r_neg = try self.newTemp();
    try self.qbeOp2Imm(r_neg, .w, "csltl", r.text, 0);
    const sign_diff = try self.newTemp();
    try self.qbeOp2(sign_diff, .w, "xor", rem_neg, r_neg);
    const need_adjust = try self.newTemp();
    try self.qbeOp2(need_adjust, .w, "and", rem_nonzero, sign_diff);

    // Dallanma/yığın yuvası KULLANMADAN (bkz. `adjustModSign`'daki aynı
    // gerekçe) `need_adjust`i (0 ya da 1) `l`ye genişletip bölümden
    // çıkarırız — 0 ise değişiklik yok, 1 ise bir eksiltilmiş olur.
    const mask = try self.newTemp();
    try self.qbeOp1(mask, .l, "extuw", need_adjust);
    const result = try self.newTemp();
    try self.qbeOp2(result, .l, "sub", q.text, mask);
    return .{ .text = result, .qtype = .l };
}

pub fn genPow(self: *Codegen, l: Value, r: Value, common: QbeType) CodegenError!Value {
    // v2.0: `int ** int` tam sayı üs almadır (sarmalı, iki backend'de aynı); yalnızca bir taraf `float` ise `pow()` kullanılır.
    if (common == .l and l.qtype == .l and r.qtype == .l and l.fixed_int == null and r.fixed_int == null) {
        const base_zero = try self.newTemp();
        try self.qbeOp2Imm(base_zero, .w, "ceql", l.text, 0);
        const exp_neg = try self.newTemp();
        try self.qbeOp2Imm(exp_neg, .w, "csltl", r.text, 0);
        const bad = try self.newTemp();
        try self.qbeOp2(bad, .w, "and", base_zero, exp_neg);
        try calls.emitColdListError(self, bad, "ZeroDivisionError", "sifira bolme", &.{});
        const t = try self.newTemp();
        try self.qbeCall(.{ .name = t, .ty = .l }, "$nox_int_pow", &.{ .{ .ty = .l, .text = l.text }, .{ .ty = .l, .text = r.text } });
        return .{ .text = t, .qtype = .l };
    }
    const lf = try self.convert(l, .d);
    const rf = try self.convert(r, .d);
    const t = try self.newTemp();
    try self.qbeCall(.{ .name = t, .ty = .d }, "$pow", &.{ .{ .ty = .d, .text = lf.text }, .{ .ty = .d, .text = rf.text } });
    const result: Value = .{ .text = t, .qtype = .d };
    if (common == .l) return self.convert(result, .l);
    return result;
}

/// v2.0 madde 4 (Faz B): sabit-genişlikli bir değeri (`u8`/`i16`/vb.)
/// yazdırma İçİn 8 bayta (QBE `l`) genişletir. `.w`de hesaplanan
/// kind'ler (u8/i8/u16/i16/u32/i32) İçİn işaretliliğe göre `extsw`
/// (işaretli) veya `extuw` (işaretsiz) kullanılır — zaten `.l`de
/// hesaplanan kind'ler (u64/i64/usize/isize) DEĞİŞMEDEN döner.
pub fn widenFixedIntForPrint(self: *Codegen, v: Value, kind: types.FixedIntKind) CodegenError!Value {
    if (v.qtype == .l) return v;
    const t = try self.newTemp();
    const mnemonic = if (kind.isSigned()) "extsw" else "extuw";
    try self.qbeOp1(t, .l, mnemonic, v.text);
    return .{ .text = t, .qtype = .l };
}

/// `print(<ifade>)`in tek giriş noktası. `list[T]`/sınıf İÇİN
/// `genPrintFragment`e (özyineli, tırnaksız-OLMAYAN `str` biçimi — bkz.
/// onun belge notu) yönlenip bir satır sonu ekler; değer tipleri İÇİN
/// (Python'un `print()`i `str()` kullanır, `repr()` DEĞİL — bu yüzden en
/// dıştaki bir `str` TIRNAKSIZ basılır, `genPrintFragment`in `str_frag`
/// biçiminden BİLEREK FARKLI) DEĞİŞMEMİŞ eski (satır-sonu dahil) format
/// sabitlerini kullanır.
pub fn genPrint(self: *Codegen, v: Value) CodegenError!void {
    if (printMayBeNull(v)) return genPrintNullGuarded(self, v, false);
    return genPrintRaw(self, v);
}

/// v1.159.0: `str | None` / `list[T] | None` / `Sınıf | None` / `int | None` değerleri Python gibi
/// `None` basar (önceden null işaretçi `printf("%s")`/sınıf-alan yüklemesine gidiyor, `int | None` ise
/// kutunun adresini basıyordu). Boş (null) işaretçi hiçbir Optional-OLMAYAN yığın değerinde oluşamaz,
/// bu yüzden koşulsuz çalışma-zamanı kontrolü güvenlidir.
fn printMayBeNull(v: Value) bool {
    return v.heap == .str or v.heap == .list or v.heap == .class or v.heap == .boxed_scalar or v.heap == .dict;
}

fn genPrintNullGuarded(self: *Codegen, v: Value, frag: bool) CodegenError!void {
    const is_null = try self.newTemp();
    try self.qbeOp2Imm(is_null, .w, "ceql", v.text, 0);
    const none_label = try self.newLabel("print_none");
    const val_label = try self.newLabel("print_some");
    const done_label = try self.newLabel("print_opt_done");
    try self.qbeJnz(is_null, none_label, val_label);
    try self.qbeLabel(none_label);
    const none_sym = try self.internFmtString("None");
    try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = none_sym }});
    if (!frag) try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = "$fmt_newline" }});
    try self.qbeJmp(done_label);
    try self.qbeLabel(val_label);
    if (v.heap == .boxed_scalar) {
        const inner = try self.newTemp();
        try self.qbeLoad(inner, v.elem_qtype, v.elem_qtype, v.text);
        const iv: Value = .{ .text = inner, .qtype = v.elem_qtype };
        if (frag) try genPrintFragmentRaw(self, iv) else try genPrintRaw(self, iv);
    } else if (frag) {
        try genPrintFragmentRaw(self, v);
    } else {
        try genPrintRaw(self, v);
    }
    try self.qbeJmp(done_label);
    try self.qbeLabel(done_label);
}

/// v1.167.0: `v`nin YAPISAL yazdırma biçimini (`print`in AYNI kodu: liste/sözlük/sınıf/tuple/Optional, `str` elemanlar tırnaklı) yeni bir ARC `str` olarak
/// üretir — `str(xs)`, `repr(x)`, f-string `{xs}`. `print_acc` yuvası etkinken `$printf` çağrıları birikime eklenir (bkz. `Codegen.sinkPrintf`).
pub fn genReprString(self: *Codegen, v: Value) CodegenError!Value {
    const slot = try self.newTemp();
    try self.qbeAlloc(slot, .eight, 8);
    const empty = try self.emitStringLiteral("");
    try self.qbeStoreL(empty.text, slot);
    const saved = self.print_acc;
    self.print_acc = slot;
    genPrintFragment(self, v) catch |e| {
        self.print_acc = saved;
        return e;
    };
    self.print_acc = saved;
    const result = try self.newTemp();
    try self.qbeLoadL(result, slot);
    return .{ .text = result, .qtype = .l, .heap = .str };
}

/// v1.160.0: `float` Python `repr` biçiminde basılır (bkz. `runtime/str.zig` `formatFloatRepr`): geçici bir `str`e
/// çevrilip `fmt` (`%s\n` ya da yalın `%s`) ile yazılır, sonra serbest bırakılır.
fn genPrintFloat(self: *Codegen, v: Value, fmt: []const u8) CodegenError!void {
    const s = try self.newTemp();
    try self.qbeCall(.{ .name = s, .ty = .l }, "$nox_float_to_str", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .d, .text = v.text } });
    try self.qbeCallVariadic(null, "$printf", &.{.{ .ty = .l, .text = fmt }}, &.{.{ .ty = .l, .text = s }});
    try self.qbeCall(null, "$nox_str_release", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = s } });
}

fn genPrintRaw(self: *Codegen, v: Value) CodegenError!void {
    if (v.heap == .list or v.heap == .class or v.heap == .dict) {
        try genPrintFragmentRaw(self, v);
        try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = "$fmt_newline" }});
        return;
    }
    if (v.fixed_int) |kind| {
        const widened = try self.widenFixedIntForPrint(v, kind);
        const fmt: []const u8 = if (kind.isSigned()) "$fmt_int" else "$fmt_uint";
        try self.qbeCallVariadic(null, "$printf", &.{.{ .ty = .l, .text = fmt }}, &.{.{ .ty = .l, .text = widened.text }});
        return;
    }
    switch (v.qtype) {
        .l => if (v.heap == .str)
            try self.qbeCallVariadic(null, "$printf", &.{.{ .ty = .l, .text = "$fmt_str" }}, &.{.{ .ty = .l, .text = v.text }})
        else
            try self.qbeCallVariadic(null, "$printf", &.{.{ .ty = .l, .text = "$fmt_int" }}, &.{.{ .ty = .l, .text = v.text }}),
        .d => try genPrintFloat(self, v, "$fmt_str"),
        .w => {
            const true_label = try self.newLabel("print_true");
            const false_label = try self.newLabel("print_false");
            const done_label = try self.newLabel("print_done");
            try self.qbeJnz(v.text, true_label, false_label);
            try self.qbeLabel(true_label);
            try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = "$fmt_bool_true" }});
            try self.qbeJmp(done_label);
            try self.qbeLabel(false_label);
            try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = "$fmt_bool_false" }});
            try self.qbeJmp(done_label);
            try self.qbeLabel(done_label);
        },
        // v2.0: `print(None)` (çıplak `None` değişmezi) Python gibi `None` basar.
        .none => {
            const none_sym = try self.internFmtString("None");
            try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = none_sym }});
            try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = "$fmt_newline" }});
        },
        .b, .sb, .h, .sh => return error.Unsupported,
    }
}

/// `v`yi satır SONU OLMADAN basar — `list[T]`/sınıf görüntülemesi (bkz.
/// görev "print(list)/print(class) görüntüleme biçimi") ÖZYİNELEMELİDİR
/// (bir listenin/sınıfın elemanı/alanı yine bir liste/sınıf olabilir);
/// yalnızca en dıştaki `genPrint` çağrısı bir satır sonu ekler.
pub fn genPrintFragment(self: *Codegen, v: Value) CodegenError!void {
    if (printMayBeNull(v)) return genPrintNullGuarded(self, v, true);
    return genPrintFragmentRaw(self, v);
}

fn genPrintFragmentRaw(self: *Codegen, v: Value) CodegenError!void {
    if (v.heap == .dict) return genPrintDict(self, v);
    if (v.heap == .list) return self.genPrintList(v);
    if (v.heap == .class) return self.genPrintClass(v);
    if (v.fixed_int) |kind| {
        const widened = try self.widenFixedIntForPrint(v, kind);
        const fmt: []const u8 = if (kind.isSigned()) "$fmt_int_frag" else "$fmt_uint_frag";
        try self.qbeCallVariadic(null, "$printf", &.{.{ .ty = .l, .text = fmt }}, &.{.{ .ty = .l, .text = widened.text }});
        return;
    }
    switch (v.qtype) {
        .l => if (v.heap == .str)
            try self.qbeCallVariadic(null, "$printf", &.{.{ .ty = .l, .text = "$fmt_str_frag" }}, &.{.{ .ty = .l, .text = v.text }})
        else
            try self.qbeCallVariadic(null, "$printf", &.{.{ .ty = .l, .text = "$fmt_int_frag" }}, &.{.{ .ty = .l, .text = v.text }}),
        .d => try genPrintFloat(self, v, try self.internFmtString("%s")),
        .w => {
            const true_label = try self.newLabel("print_true");
            const false_label = try self.newLabel("print_false");
            const done_label = try self.newLabel("print_done");
            try self.qbeJnz(v.text, true_label, false_label);
            try self.qbeLabel(true_label);
            try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = "$fmt_bool_true_frag" }});
            try self.qbeJmp(done_label);
            try self.qbeLabel(false_label);
            try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = "$fmt_bool_false_frag" }});
            try self.qbeJmp(done_label);
            try self.qbeLabel(done_label);
        },
        .none, .b, .sb, .h, .sh => return error.Unsupported,
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
    try self.fmt_data.append(self.allocator, .{ .symbol = sym, .escaped = escaped, .raw = text });
    return sym;
}

/// `list[T]` görüntülemesi — Python'un `repr([...])`ine benzer:
/// `[e1, e2, ...]`, elemanlar `genPrintFragment` ile ÖZYİNELEMELİ basılır
/// (bir liste elemanı yine bir liste/sınıf olabilir). Liste UZUNLUĞU
/// yalnızca ÇALIŞMA ZAMANINDA bilindiğinden (derleme zamanında sabit bir
/// format dizesi ÇÖZÜLEMEZ), `genForList`/`genListElemRelease` ile AYNI
/// güvenli döngü desenini (FONKSİYON GİRİŞİNDE bir kez `alloc8`) kullanır.
pub fn genPrintList(self: *Codegen, v: Value) CodegenError!void {
    try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = "$fmt_lbracket" }});

    const len_t = try self.newTemp();
    try self.qbeLoadL(len_t, v.text);
    const idx_slot = try self.newTemp();
    try self.qbeAlloc(idx_slot, .eight, 8);
    try self.qbeStoreImmL(0, idx_slot);

    const cond_label = try self.newLabel("printlist_cond");
    const body_label = try self.newLabel("printlist_body");
    const end_label = try self.newLabel("printlist_end");
    try self.qbeJmp(cond_label);
    try self.qbeLabel(cond_label);
    const idx_cur = try self.newTemp();
    try self.qbeLoadL(idx_cur, idx_slot);
    const cont = try self.newTemp();
    try self.qbeOp2(cont, .w, "csltl", idx_cur, len_t);
    try self.qbeJnz(cont, body_label, end_label);
    try self.qbeLabel(body_label);

    const not_first = try self.newTemp();
    try self.qbeOp2Imm(not_first, .w, "cnel", idx_cur, 0);
    const comma_label = try self.newLabel("printlist_comma");
    const skip_comma_label = try self.newLabel("printlist_skipcomma");
    try self.qbeJnz(not_first, comma_label, skip_comma_label);
    try self.qbeLabel(comma_label);
    try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = "$fmt_comma_sp" }});
    try self.qbeJmp(skip_comma_label);
    try self.qbeLabel(skip_comma_label);

    const off = try self.newTemp();
    try self.qbeOp2Imm(off, .l, "mul", idx_cur, @intCast(qbeSizeOf(v.elem_qtype)));
    const off8 = try self.newTemp();
    try self.qbeOp2Imm(off8, .l, "add", off, @intCast(LIST_HEADER_SIZE));
    const addr = try self.newTemp();
    try self.qbeOp2(addr, .l, "add", v.text, off8);
    const elem = try self.newTemp();
    try self.loadListElem(elem, v.elem_qtype, addr);
    try self.genPrintFragment(valueFromElemDescriptor(elem, v.elem_qtype, v.elem_heap_info, v.elem_is_str, v.elem_fixed_int));

    const idx_next = try self.newTemp();
    try self.qbeOp2Imm(idx_next, .l, "add", idx_cur, 1);
    try self.qbeStoreL(idx_next, idx_slot);
    try self.qbeJmp(cond_label);
    try self.qbeLabel(end_label);

    try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = "$fmt_rbracket" }});
}

/// v1.161.0: `dict[K, V]` Python gibi `{k: v, ...}` (ekleme sırası; `str` anahtar/değerler tırnaklı) basılır — `keys()`/`values()`
/// listeleri üretilip paralel gezilir, sonra serbest bırakılır (boş sözlük `{}`).
fn genPrintDict(self: *Codegen, v: Value) CodegenError!void {
    var none_expr: ast.Expr = .none_lit;
    const keys = try self.genDictMethod(v, .{ .obj = &none_expr, .attr = "keys" }, &.{});
    const vals = try self.genDictMethod(v, .{ .obj = &none_expr, .attr = "values" }, &.{});
    const lb = try self.internFmtString("{");
    try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = lb }});

    const len_t = try self.newTemp();
    try self.qbeLoadL(len_t, keys.text);
    const idx_slot = try self.newTemp();
    try self.qbeAlloc(idx_slot, .eight, 8);
    try self.qbeStoreImmL(0, idx_slot);
    const cond_label = try self.newLabel("printdict_cond");
    const body_label = try self.newLabel("printdict_body");
    const end_label = try self.newLabel("printdict_end");
    try self.qbeJmp(cond_label);
    try self.qbeLabel(cond_label);
    const idx_cur = try self.newTemp();
    try self.qbeLoadL(idx_cur, idx_slot);
    const cont = try self.newTemp();
    try self.qbeOp2(cont, .w, "csltl", idx_cur, len_t);
    try self.qbeJnz(cont, body_label, end_label);
    try self.qbeLabel(body_label);

    const not_first = try self.newTemp();
    try self.qbeOp2Imm(not_first, .w, "cnel", idx_cur, 0);
    const comma_label = try self.newLabel("printdict_comma");
    const skip_label = try self.newLabel("printdict_skipcomma");
    try self.qbeJnz(not_first, comma_label, skip_label);
    try self.qbeLabel(comma_label);
    try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = "$fmt_comma_sp" }});
    try self.qbeJmp(skip_label);
    try self.qbeLabel(skip_label);

    const kv = try self.loadListElemValueAt(keys, idx_cur);
    try self.genPrintFragment(kv);
    const colon = try self.internFmtString(": ");
    try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = colon }});
    const vv = try self.loadListElemValueAt(vals, idx_cur);
    try self.genPrintFragment(vv);

    const idx_next = try self.newTemp();
    try self.qbeOp2Imm(idx_next, .l, "add", idx_cur, 1);
    try self.qbeStoreL(idx_next, idx_slot);
    try self.qbeJmp(cond_label);
    try self.qbeLabel(end_label);
    const rb = try self.internFmtString("}");
    try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = rb }});
    try self.releaseValueIfSet(keys.text, keys.heap, keys.elem_qtype, keys.class_name, keys.elem_heap_info, keys.dict_info);
    try self.releaseValueIfSet(vals.text, vals.heap, vals.elem_qtype, vals.class_name, vals.elem_heap_info, vals.dict_info);
}

/// Sınıf görüntülemesi — `ClassName(alan1=değer1, alan2=değer2, ...)`.
/// Alan sayısı/adları/tipleri derleme zamanında SABİTTİR (`cinfo.fields`),
/// bu yüzden döngü GEREKMEZ — ama alan DEĞERLERİ (özellikle iç içe
/// sınıf/`list[T]` alanları) `genPrintFragment` ile ÖZYİNELEMELİ basılır.
pub fn genPrintClass(self: *Codegen, v: Value) CodegenError!void {
    const class_name = v.class_name.?;
    const cinfo = self.classes.get(class_name).?;
    // v1.157.0: tuple sınıfları Python gibi `(a, b)` / `(a,)` basılır.
    if (std.mem.startsWith(u8, class_name, "tuple__")) {
        const lp = try self.internFmtString("(");
        try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = lp }});
        for (cinfo.fields.items, 0..) |f, i| {
            if (i != 0) try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = "$fmt_comma_sp" }});
            const addr = try self.newTemp();
            try self.qbeOp2Imm(addr, .l, "add", v.text, @intCast(f.offset));
            const fv = try self.newTemp();
            try self.qbeLoad(fv, f.info.qtype, f.info.qtype, addr);
            try self.genPrintFragment(.{ .text = fv, .qtype = f.info.qtype, .heap = f.info.heap, .elem_qtype = f.info.elem_qtype, .class_name = f.info.class_name, .elem_heap_info = f.info.elem_heap_info, .elem_is_str = f.info.elem_is_str, .fixed_int = f.info.fixed_int });
        }
        if (cinfo.fields.items.len == 1) {
            const comma = try self.internFmtString(",");
            try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = comma }});
        }
        try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = "$fmt_rparen" }});
        return;
    }
    // v1.168.0: sınıfta `__repr__` (yoksa `__str__`) tanımlıysa konteyner içindeki/doğrudan yazdırılan örnek onunla yazılır (Set, kullanıcı sınıfları).
    if (cinfo.methods.get("__repr__") orelse cinfo.methods.get("__str__")) |msig| {
        const mname: []const u8 = if (cinfo.methods.contains("__repr__")) "__repr__" else "__str__";
        if (msig.sig.params.len == 0 and msig.sig.ret.heap == .str) {
            const res = try self.newTemp();
            const margs = [_]codegen.QbeArg{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = v.text } };
            if (cinfo.has_vtable) {
                const vt_addr = try self.newTemp();
                try self.qbeOp2Imm(vt_addr, .l, "add", v.text, @intCast(TAG_SIZE));
                const vtable_ptr = try self.newTemp();
                try self.qbeLoadL(vtable_ptr, vt_addr);
                const slot_addr = try self.newTemp();
                try self.qbeOp2Imm(slot_addr, .l, "add", vtable_ptr, @intCast(msig.slot * 8));
                const fn_ptr = try self.newTemp();
                try self.qbeLoadL(fn_ptr, slot_addr);
                try self.qbeCall(.{ .name = res, .ty = .l }, fn_ptr, &margs);
                try self.emitExceptionCheck();
            } else {
                const sym = try std.fmt.allocPrint(self.allocator, "${s}_{s}", .{ msig.owner, mname });
                try self.qbeCall(.{ .name = res, .ty = .l }, sym, &margs);
                const plain = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ msig.owner, mname });
                if (!self.must_not_raise.contains(plain)) try self.emitExceptionCheck();
            }
            const pct_s = try self.internFmtString("%s");
            try self.qbeCallVariadic(null, "$printf", &.{.{ .ty = .l, .text = pct_s }}, &.{.{ .ty = .l, .text = res }});
            try self.qbeCall(null, "$nox_str_release", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = res } });
            return;
        }
    }
    const open_sym = try self.internFmtString(try std.fmt.allocPrint(self.allocator, "{s}(", .{class_name}));
    try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = open_sym }});
    for (cinfo.fields.items, 0..) |f, i| {
        if (i != 0) try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = "$fmt_comma_sp" }});
        const name_sym = try self.internFmtString(try std.fmt.allocPrint(self.allocator, "{s}=", .{f.name}));
        try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = name_sym }});
        const addr = try self.newTemp();
        try self.qbeOp2Imm(addr, .l, "add", v.text, @intCast(f.offset));
        const fv = try self.newTemp();
        try self.qbeLoad(fv, f.info.qtype, f.info.qtype, addr);
        // v4 Faz A madde 4 (bkz. nox-teknik-spesifikasyon.md §3.2xx):
        // `genCall`/`genInlinedCall`in AYNI bulgusu — bir sınıfın
        // sabit-genişlikli tamsayı ALANI (`x: u8` GİBİ) `print(obj)`
        // İLE basıldığında `fixed_int` DAMGALANMADIĞINDAN "True"/"False"
        // OLARAK YANLIŞ basılıyordu.
        try self.genPrintFragment(.{ .text = fv, .qtype = f.info.qtype, .heap = f.info.heap, .elem_qtype = f.info.elem_qtype, .class_name = f.info.class_name, .elem_heap_info = f.info.elem_heap_info, .elem_is_str = f.info.elem_is_str, .fixed_int = f.info.fixed_int });
    }
    try self.qbeCall(null, "$printf", &.{.{ .ty = .l, .text = "$fmt_rparen" }});
}
