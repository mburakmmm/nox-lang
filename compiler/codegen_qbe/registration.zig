//! Sınıf/fonksiyon KAYDI (tip çözümleme, alan/parametre imzaları) VE
//! fonksiyon/metod/`main` gövde ÜRETİMİNİN giriş noktaları — bkz. plan
//! dosyası "QBE codegen backend'ini alt modüllere bölme". TEMEL/kayıt
//! aşaması: diğer HER şeyden (deyim/ifade codegen'i DAHİL) ÖNCE çalışır.

const std = @import("std");
const ast = @import("../parser/ast.zig");
const types = @import("types.zig");
const abi = @import("abi.zig");
const codegen = @import("codegen.zig");
const inlining = @import("inlining.zig");

const Codegen = codegen.Codegen;
const QbeType = types.QbeType;
const TypeInfo = types.TypeInfo;
const DictInfo = types.DictInfo;
const ElemHeapInfo = types.ElemHeapInfo;
const FuncSigInfo = types.FuncSigInfo;
const LocalDecl = types.LocalDecl;
const NamedSlot = inlining.NamedSlot;
const RT_PARAM = types.RT_PARAM;
const TAG_SIZE = types.TAG_SIZE;
const FIELD_SLOT_SIZE = types.FIELD_SLOT_SIZE;
const CodegenError = abi.CodegenError;
const qbeTypeName = abi.qbeTypeName;
const isHeapManaged = abi.isHeapManaged;
const sanitizePathToSymbol = abi.sanitizePathToSymbol;
const forListIdxName = abi.forListIdxName;

pub fn newTemp(self: *Codegen) CodegenError![]const u8 {
    const n = self.temp_counter;
    self.temp_counter += 1;
    return std.fmt.allocPrint(self.allocator, "%t{d}", .{n});
}

pub fn newLabel(self: *Codegen, comptime prefix: []const u8) CodegenError![]const u8 {
    const n = self.label_counter;
    self.label_counter += 1;
    return std.fmt.allocPrint(self.allocator, "@{s}{d}", .{ prefix, n });
}

/// Faz P2.1 (bkz. proje belleği "generic sınıflar" planı): `checker.zig`nin
/// `mangleName`/`appendMangledType`i İLE AYNI adlandırma şemasını,
/// checker'ın ÇÖZÜLMÜŞ `Type`si YERİNE DOĞRUDAN `ast.TypeExpr` ÜZERİNDE
/// (codegen'in KENDİ, BAĞIMSIZ tip çözümleme geçişi bu noktada checker'ın
/// `Type`sine erişemez) yeniden üretir — `Box[int]` GİBİ bir tip
/// ifadesinin, checker'ın ZATEN monomorphize edip `self.classes`e
/// kaydettiği `Box__int` mangled adını BULABİLMESİ İçin. **Bu iki
/// fonksiyon SENKRON KALMALIDIR** — biri değişirse (ör. yeni bir mangled
/// isim BİÇİMİ) diğeri de GÜNCELLENMELİDİR.
fn mangleGenericClassName(self: *Codegen, base: []const u8, args: []const ast.TypeExpr) CodegenError![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(self.allocator, base);
    try buf.appendSlice(self.allocator, "__");
    for (args, 0..) |a, i| {
        if (i != 0) try buf.appendSlice(self.allocator, "_");
        try appendMangledTypeExprName(self, &buf, a);
    }
    return buf.toOwnedSlice(self.allocator);
}

fn appendMangledTypeExprName(self: *Codegen, buf: *std.ArrayListUnmanaged(u8), te: ast.TypeExpr) CodegenError!void {
    switch (te) {
        // İlkel adlar (`int`/`float`/`bool`/`str`/`None`/`ptr`) VE sınıf
        // adları — checker'ın `appendMangledType`inde AYNI ÇIPLAK isim
        // olarak (`Type.class`in taşıdığı isim, TAM OLARAK bir `.simple`
        // TypeExpr'in yazıldığı GİBİ) yazılır.
        .simple => |name| try buf.appendSlice(self.allocator, name),
        .generic => |g| {
            if (std.mem.eql(u8, g.name, "dict") and g.args.len == 2) {
                try buf.appendSlice(self.allocator, "dict_");
                try appendMangledTypeExprName(self, buf, g.args[0]);
                try buf.appendSlice(self.allocator, "_");
                try appendMangledTypeExprName(self, buf, g.args[1]);
                return;
            }
            if (g.args.len == 0) return error.Unsupported;
            try buf.appendSlice(self.allocator, g.name);
            try buf.appendSlice(self.allocator, "_");
            try appendMangledTypeExprName(self, buf, g.args[0]);
        },
        // Checker'ın `unifyTypeExpr`/`instantiateGenericClass`ı ZATEN bir
        // generic tip argümanının func-tipi/Optional OLMASINI reddeder —
        // bu dal PRATİKTE tetiklenmez, yalnızca exhaustive switch
        // GEREKSİNİMİNİ karşılar.
        .func_type, .optional => return error.Unsupported,
    }
}

pub fn resolveType(self: *Codegen, te: ast.TypeExpr) CodegenError!TypeInfo {
    switch (te) {
        .simple => |name| {
            if (std.mem.eql(u8, name, "int")) return .{ .qtype = .l };
            if (std.mem.eql(u8, name, "float")) return .{ .qtype = .d };
            if (std.mem.eql(u8, name, "bool")) return .{ .qtype = .w };
            if (std.mem.eql(u8, name, "None")) return .{ .qtype = .none };
            if (std.mem.eql(u8, name, "str")) return .{ .qtype = .l, .heap = .str };
            // `ptr` — Faz 20'nin ikinci artımı (bkz. nox-teknik-
            // spesifikasyon.md §3.20): ARC-İZLENMEYEN opak bir işaretçi
            // (`heap = .none`, `list`/`class` gibi ÖZEL bir dispatch
            // GEREKTİRMEZ — düz bir `l` değeridir, `int` gibi).
            if (std.mem.eql(u8, name, "ptr")) return .{ .qtype = .l, .heap = .none };
            if (self.classes.contains(name)) return .{ .qtype = .l, .heap = .class, .class_name = name };
            // Bulundu (bkz. proje belleği "from-import class type
            // annotations" görevi, `Codegen.from_imports`in belge notu İLE
            // AYNI gerekçe): `checker.zig`nin `typeExprToType`iyle AYNI
            // geri düşüş — `from X import Y` İLE bağlanan ÇIPLAK bir sınıf
            // adı.
            if (self.from_imports.get(name)) |mangled| {
                if (self.classes.contains(mangled)) return .{ .qtype = .l, .heap = .class, .class_name = mangled };
            }
            return error.Unsupported;
        },
        .generic => |g| {
            if (std.mem.eql(u8, g.name, "dict")) {
                if (g.args.len != 2) return error.Unsupported;
                const key = try self.resolveType(g.args[0]);
                const value = try self.resolveType(g.args[1]);
                // v1 kapsamı (checker.zig'in `typeExprToType`indeki
                // `"dict"` dalıyla TUTARLI): K int/bool/str, V int/float/
                // bool/str — sınıf/list/dict/Task/Channel anahtar/değer
                // checker'da ZATEN reddedilir, burası savunmacıdır.
                if (key.heap != .none and key.heap != .str) return error.Unsupported;
                if (value.heap != .none and value.heap != .str) return error.Unsupported;
                const dinfo = try self.allocator.create(DictInfo);
                dinfo.* = .{ .key_is_str = key.heap == .str, .key_qtype = key.qtype, .value_qtype = value.qtype, .value_is_str = value.heap == .str };
                return .{ .qtype = .l, .heap = .dict, .dict_info = dinfo };
            }
            const is_list = std.mem.eql(u8, g.name, "list");
            const is_task = std.mem.eql(u8, g.name, "Task");
            const is_channel = std.mem.eql(u8, g.name, "Channel");
            const is_thread_handle = std.mem.eql(u8, g.name, "ThreadHandle");
            const is_thread_channel = std.mem.eql(u8, g.name, "ThreadChannel");
            if (!(is_list or is_task or is_channel or is_thread_handle or is_thread_channel)) {
                // Faz P2.1: kullanıcı-tanımlı bir generic sınıf tip ifadesi
                // (ör. bir alan/parametre `Box[int]` OLARAK bildirilmiş) —
                // checker'ın ZATEN monomorphize edip `self.classes`e
                // kaydettiği mangled adı (bkz. `mangleGenericClassName`in
                // belge notu) BURADA YENİDEN HESAPLAYIP arar. Bulunamazsa
                // (`g.name` gerçekten bilinmeyen bir isimse) `error.
                // Unsupported`a düşülür — checker BUNU ZATEN reddetmiş
                // olmalıydı, bu SAVUNMACI bir GÜVENLİK AĞIdır.
                const mangled = try mangleGenericClassName(self, g.name, g.args);
                if (self.classes.contains(mangled)) {
                    return .{ .qtype = .l, .heap = .class, .class_name = mangled };
                }
                return error.Unsupported;
            }
            if (g.args.len != 1) return error.Unsupported;
            const elem = try self.resolveType(g.args[0]);
            var elem_heap_info: ?*const ElemHeapInfo = null;
            // `str` DAHİL — bkz. `ElemHeapInfo.nested`in belge notu:
            // stdlib fazı §B'den beri `str` de ARC-yönetimli, `list[str]`
            // elemanlarının özyinelemeli release'e girmesi İÇİN burada da
            // `elem_heap_info` doldurulmalı (`genListElemRelease`in
            // `info.nested`in `.str` özel durumuna bkz.).
            // Faz U.4.5: `.closure` EKLENDİ — üst-düzey fonksiyonların
            // birinci-sınıf DEĞER olarak kullanılabilmesiyle (bkz.
            // `checker.zig`nin `functions_used_as_value`i) `list[(T)->U]`
            // ARTIK GERÇEK bir kullanım senaryosu (bkz. `stdlib/nox/
            // router.nox`). DAHA ÖNCE bu dal `.closure`u ATLIYORDU —
            // `genListElemRelease`in listenin KENDİSİ DÜŞÜRÜLDÜĞÜNDE
            // eleman closure'larını HİÇ serbest BIRAKMAMASINA (GERÇEK bir
            // sızıntı) yol AÇARDI.
            if (elem.heap == .class or elem.heap == .list or elem.heap == .str or elem.heap == .closure) {
                const info = try self.allocator.create(ElemHeapInfo);
                info.* = .{ .heap = elem.heap, .class_name = elem.class_name, .elem_qtype = elem.elem_qtype, .nested = elem.elem_heap_info, .elem_is_str = elem.elem_is_str, .func_sig = elem.func_sig };
                elem_heap_info = info;
            } else if (elem.heap != .none) {
                return error.Unsupported;
            }
            // `list[T]`nin KENDİSİ (heap=.list) ARC-yönetimlidir (refcount
            // başlığı, retain-on-alias). `Task[T]`/`Channel[T]`nin KENDİSİ
            // İSE DEĞİLDİR (heap=.task/.channel, `isHeapManaged`in DIŞINDA
            // — bkz. `HeapKind`in belge notu) — zamanlayıcı kendi ömrünü
            // kendi yönetir, kapsam-sonu temizliği DOĞRUDAN bir `nox_async_
            // destroy_task`/`nox_channel_destroy` çağrısıdır (predecrement
            // YOK, bkz. `releaseAllLocalsExcept`). `elem_qtype`/
            // `elem_heap_info`/`elem_is_str` PAYLOAD (T) tipini tam olarak
            // taşır — `await`/`Channel.recv`in doğru tipte bir SONUÇ değeri
            // üretebilmesi için (bkz. `genAwaitExpr`, `genChannelOp`).
            return .{
                .qtype = .l,
                .heap = if (is_list) .list else if (is_task) .task else if (is_channel) .channel else if (is_thread_handle) .thread_handle else .thread_channel,
                .elem_qtype = elem.qtype,
                .elem_heap_info = elem_heap_info,
                .elem_is_str = elem.heap == .str,
            };
        },
        // Faz U.4.3: bir closure değeri, ARC pointer AÇISINDAN `class`
        // İLE AYNIdır (bkz. `HeapKind.closure`nin belge notu) — YALNIZCA
        // `class_name` (BURADA bilinçli olarak `null`, çünkü SALT bir
        // TİP İFADESİNDEN hangi SOMUT closure kastedildiği bilinemez)
        // gerçek bir SOMUT closure DEĞERİNİN (bir iç içe `def` deyiminin
        // KENDİSİ tarafından, bkz. `genNestedFuncDef`) `VarInfo`sinde
        // doldurulur. Faz U.4.4: STATİK imza (`func_sig`, bkz.
        // `FuncSigInfo`in belge notu) BURADA, tip ifadesinin KENDİSİNDEN
        // her zaman TAM olarak çözülür — dolaylı çağrının (`genCall`in
        // `.closure` dalı) argüman/dönüş tiplerini bilebilmesi İÇİN
        // yeterlidir, SOMUT closure'ın kimliği GEREKMEZ.
        .func_type => |ft| {
            const params = try self.allocator.alloc(TypeInfo, ft.params.len);
            for (ft.params, 0..) |pt, i| params[i] = try self.resolveType(pt);
            const ret = try self.resolveType(ft.return_type.*);
            const sig = try self.allocator.create(FuncSigInfo);
            sig.* = .{ .params = params, .ret = ret };
            return .{ .qtype = .l, .heap = .closure, .func_sig = sig };
        },
        // Faz FF.6 (bkz. nox-teknik-spesifikasyon.md §3.65): `T | None`.
        // TAM ARC-yönetimli heap tipler (`class`/`str`/`list`/`dict`/
        // `closure` — bkz. `isHeapManaged`) VE `ptr` İÇİN Optional'ın
        // çalışma zamanı temsili taban tiple TAMAMEN AYNIDIR (null
        // pointer = None, dolu pointer = Some(x)) — ARC release/eşitlik/
        // trace/gc-free KODUNUN HİÇBİRİ DEĞİŞMEZ (zaten null-güvenli,
        // bkz. `releaseValueIfSet`); retain'e de AYRICA bir null-güvenlik
        // eklendi (bkz. `emitInlineRetain`in belge notu). Bu yüzden
        // burada YALNIZCA taban tipin `TypeInfo`si AYNEN döndürülür —
        // codegen SEVİYESİNDE ayrı bir "Optional" temsili YOKTUR
        // (yalnızca checker'ın daraltma denetimi bu ayrımı bilir).
        // BİLİNÇLİ v1 DIŞI bırakılanlar: `Task`/`Channel`/`ThreadHandle`/
        // `ThreadChannel` (ARC-DIŞI, KENDİ ayrı yıkım mekanizmaları var —
        // bkz. `destroyNonArcValue`, null-güvenlikleri AYRICA
        // doğrulanmadı).
        .optional => |inner_te| {
            const inner = try self.resolveType(inner_te.*);
            const is_ptr = switch (inner_te.*) {
                .simple => |n| std.mem.eql(u8, n, "ptr"),
                else => false,
            };
            if (isHeapManaged(inner.heap) or is_ptr) return inner;
            // Faz FF.6.4: `int | None`/`float | None`/`bool | None` —
            // İLKELLERİN QBE'de "boş" temsil edecek yedek biti
            // OLMADIĞINDAN (bkz. spec §3.65), tek-alanlı, ARC-yönetimli
            // BASİT bir kutu (`HeapKind.boxed_scalar`) İÇİNE sarılır.
            // `elem_qtype` KUTUNUN İÇİNDEKİ GERÇEK skaler QBE tipini
            // taşır (`list[T]`in `elem_qtype`iyle AYNI deseni yeniden
            // kullanır) — kutunun KENDİSİ HER ZAMAN `.l` (pointer).
            if (inner.heap == .none and (inner.qtype == .l or inner.qtype == .d or inner.qtype == .w)) {
                return .{ .qtype = .l, .heap = .boxed_scalar, .elem_qtype = inner.qtype };
            }
            return error.Unsupported;
        },
    }
}

// ---- Sınıf kaydı (fonksiyon/main gövdeleri üretilmeden ÖNCE tamamlanmalı) ----

pub fn registerClass(self: *Codegen, cd: ast.ClassDef) CodegenError!void {
    var init_fd: ?ast.FuncDef = null;
    for (cd.methods) |m| {
        if (std.mem.eql(u8, m.name, "__init__")) init_fd = m;
    }

    var info: types.ClassInfo = .{};
    // Faz FF.5 (bkz. nox-teknik-spesifikasyon.md §3.64): AÇIKÇA
    // bildirilen alanlar, `__init__` gövdesi taranmadan ÖNCE (bildirim
    // SIRASIYLA) `info.fields`e eklenir — tipleri `resolveType` İLE
    // DOĞRUDAN çözülür (metod parametreleri/dönüşleri İçin ZATEN
    // kullanılan AYNI genel çözücü), `inferFieldType`nin dar
    // YETENEĞİNİ (yalnızca `self`/`__init__` parametresi/literal)
    // TAMAMEN ATLAR. Aşağıdaki `__init__`-tarama döngüsünün MEVCUT
    // "zaten var mı" kontrolü (`exists`), bu ÖNCEDEN eklenmiş alanları
    // OTOMATİK olarak ATLAR — `inferFieldType`e HİÇ uğramazlar.
    for (cd.fields) |fd| {
        try info.fields.append(self.allocator, .{
            .name = fd.name,
            .info = try self.resolveType(fd.type_expr),
            .offset = TAG_SIZE + info.fields.items.len * FIELD_SLOT_SIZE,
        });
    }
    if (init_fd) |init| {
        for (init.body) |stmt| {
            if (stmt.kind != .assign) continue;
            const a = stmt.kind.assign;
            if (a.target != .attribute) continue;
            const attr = a.target.attribute;
            if (attr.obj.* != .identifier or !std.mem.eql(u8, attr.obj.identifier, "self")) continue;
            var exists = false;
            for (info.fields.items) |f| {
                if (std.mem.eql(u8, f.name, attr.attr)) {
                    exists = true;
                    break;
                }
            }
            if (exists) continue;
            const ftype = try self.inferFieldType(cd.name, init.params[1..], a.value);
            try info.fields.append(self.allocator, .{
                .name = attr.attr,
                .info = ftype,
                .offset = TAG_SIZE + info.fields.items.len * FIELD_SLOT_SIZE,
            });
        }
        info.total_size = TAG_SIZE + info.fields.items.len * FIELD_SLOT_SIZE;

        const iparams = try self.allocator.alloc(TypeInfo, init.params.len - 1);
        for (init.params[1..], 0..) |p, i| iparams[i] = try self.resolveType(p.type_expr);
        info.init_params = iparams;
    } else {
        // `__init__`i olmayan sınıf (bkz. `ClassInfo.has_init`in belge
        // notu): kurucu 0 argüman alır — checker zaten bu durumda
        // çağrı sitesinde 0 argüman şart koşar (bkz. checker.zig,
        // `checkCall`in `.identifier` dalı, `init_sig orelse` varsayılanı).
        // Faz FF.5: bildirilen alanlar (varsa) YİNE de `info.fields`de
        // KALIR (yukarıda eklendi) — ama checker BU durumu (bildirilen
        // bir alanın `__init__` OLMADIĞI İçin HİÇ atanamaması) ZATEN
        // `UnassignedField` İLE REDDETTİĞİNDEN (bkz. `checkClassBody`),
        // bu yol PRATİKTE codegen'e HİÇ ULAŞMAZ — yalnızca savunmacı
        // tutarlılık İçin `total_size` yine de alanları HESABA katar.
        info.has_init = false;
        info.total_size = TAG_SIZE + info.fields.items.len * FIELD_SLOT_SIZE;
    }
    info.class_id = self.next_class_id;
    self.next_class_id += 1;

    for (cd.methods) |m| {
        if (std.mem.eql(u8, m.name, "__init__")) continue;
        const params = try self.allocator.alloc(TypeInfo, m.params.len - 1);
        for (m.params[1..], 0..) |p, i| params[i] = try self.resolveType(p.type_expr);
        const ret = try self.resolveType(m.return_type);
        try info.methods.put(self.allocator, m.name, .{ .params = params, .ret = ret });
    }

    try self.classes.put(self.allocator, cd.name, info);
}

/// Bir sınıf alanının tipini yalnızca gerçekçi/yaygın örüntülerden çıkarır:
/// doğrudan bir `__init__` parametresi, `self` (bkz. aşağı), ya da bir
/// literal. Daha karmaşık ifadeler (checker'ın tam tip çıkarımını burada
/// yeniden uygulamamak için) bilinçli olarak desteklenmiyor.
pub fn inferFieldType(self: *Codegen, class_name: []const u8, init_params: []const ast.Param, expr: ast.Expr) CodegenError!TypeInfo {
    switch (expr) {
        .identifier => |name| {
            // Faz S.3: `self.next = self` — bir nesnenin KENDİ türünden
            // bir alana KENDİSİNE atanması (öz-referans). `generateModule`nin
            // TÜM sınıf adlarını (alanları çözülmeden ÖNCE) boş bir yer
            // tutucuyla `self.classes`a ÖNCEDEN eklemesi SAYESİNDE
            // (stdlib fazı §L'nin `list[JsonValue]` düzeltmesi, bkz. onun
            // belge notu) `class_name`in KENDİSİ bu noktada ZATEN
            // kayıtlıdır — bu, GERÇEK bir A↔B referans döngüsü kurmanın
            // bootstrap adımıdır (bkz. Faz S.3, `runtime/alloc/
            // cycle_detector.zig`): bir nesne `__init__` İÇİNDE KENDİSİNE
            // (geçerli, KISMİ ama tahsis edilmiş bir `self` işaretçisine)
            // işaret ederek başlar (1-döngülük bir öz-döngü), SONRADAN
            // `a.next = b; b.next = a;` gibi bir yeniden atamayla GERÇEK
            // bir A↔B döngüsüne dönüştürülebilir — `None`/opsiyonel tipler
            // OLMADAN kullanılabilecek EN BASİT bootstrap deseni.
            if (std.mem.eql(u8, name, "self")) {
                return .{ .qtype = .l, .heap = .class, .class_name = class_name };
            }
            for (init_params) |p| {
                if (std.mem.eql(u8, p.name, name)) {
                    // `list[T]` alanlar (bkz. görev "Sınıf alanı list[T]
                    // tipinde olabilsin") — `resolveType` zaten TAM
                    // `elem_qtype`/`elem_heap_info`/`elem_is_str`
                    // betimleyicisini üretir; `genClassRelease` bunu
                    // `releaseValueIfSet` üzerinden özyinelemeli release
                    // için kullanır (bkz. `genClassRelease`in belge
                    // notu). Sınıf tipli alanlar (öz-referans DAHİL —
                    // bkz. yukarıdaki `self` dalı VE stdlib fazı §L'nin
                    // `list[JsonValue]` düzeltmesi) `resolveType`'ın
                    // `self.classes.contains` kontrolü SAYESİNDE artık
                    // ileri-referanslı sınıflara da (aynı modüldeki HER
                    // sınıf ÖNCEDEN yer tutucuyla kaydedildiğinden)
                    // referans verebilir.
                    return try self.resolveType(p.type_expr);
                }
            }
            return error.Unsupported;
        },
        .int_lit => return .{ .qtype = .l },
        .float_lit => return .{ .qtype = .d },
        .bool_lit => return .{ .qtype = .w },
        .string_lit => return .{ .qtype = .l, .heap = .str },
        else => return error.Unsupported,
    }
}

pub fn registerFunc(self: *Codegen, fd: ast.FuncDef) CodegenError!void {
    const params = try self.allocator.alloc(TypeInfo, fd.params.len);
    for (fd.params, 0..) |p, i| params[i] = try self.resolveType(p.type_expr);
    const ret = try self.resolveType(fd.return_type);
    try self.functions.put(self.allocator, fd.name, .{ .params = params, .ret = ret });
    try self.func_defs.put(self.allocator, fd.name, fd);
}

pub fn registerExternFunc(self: *Codegen, ed: ast.ExternDef) CodegenError!void {
    const params = try self.allocator.alloc(TypeInfo, ed.params.len);
    for (ed.params, 0..) |p, i| params[i] = try self.resolveType(p.type_expr);
    const ret = try self.resolveType(ed.return_type);
    try self.extern_functions.put(self.allocator, ed.name, .{ .params = params, .ret = ret, .needs_rt = ed.needs_rt });
}

pub fn collectLocals(self: *Codegen, locals: *std.ArrayListUnmanaged(LocalDecl), stmts: []const ast.Stmt, in_lowlevel: bool) CodegenError!void {
    for (stmts) |stmt| {
        switch (stmt.kind) {
            .var_decl => |v| {
                const info = try self.resolveType(v.type_expr);
                try locals.append(self.allocator, .{ .name = v.name, .info = info, .arena = in_lowlevel });
            },
            .for_stmt => |f| {
                if (Codegen.isRangeCall(f.iterable)) {
                    try locals.append(self.allocator, .{ .name = f.var_name, .info = .{ .qtype = .l } });
                } else if (f.iterable == .identifier) {
                    const src = Codegen.findLocal(locals.items, f.iterable.identifier) orelse return error.Unsupported;
                    if (src.heap != .list) return error.Unsupported;
                    // Döngü değişkeni listenin İÇİNDEKİ bir elemana ÖDÜNÇ
                    // ALINMIŞ bir referanstır (listenin kendisi hâlâ
                    // sahibidir) — heap-yönetimli elemanlarda (Faz 21
                    // ön-koşulu) bunu `is_param = true` ile işaretlemek
                    // (teknik olarak parametre olmasa da) kapsam-sonu
                    // otomatik release'i ATLATIR; aksi halde listenin
                    // KENDİ sahipliğini bozan bir çifte-serbest-bırakma
                    // riski doğardı. `.class`/iç-içe `.list` DIŞINDA
                    // (int/float/bool/str) bu zaten etkisizdir.
                    var loop_var_info: TypeInfo = .{ .qtype = src.elem_qtype };
                    if (src.elem_heap_info) |ehi| {
                        loop_var_info.heap = ehi.heap;
                        loop_var_info.class_name = ehi.class_name;
                        loop_var_info.elem_qtype = ehi.elem_qtype;
                        loop_var_info.elem_heap_info = ehi.nested;
                    } else if (src.elem_is_str) {
                        loop_var_info.heap = .str;
                    }
                    try locals.append(self.allocator, .{ .name = f.var_name, .info = loop_var_info, .is_param = true });
                    // `genForList`nin dahili döngü indeksi için gizli bir
                    // yerel — FONKSİYON GİRİŞİNDE (`allocSlot` ile) BİR
                    // KEZ tahsis edilmesi gerekir. Aksi halde (bu `for`
                    // başka bir döngünün içine gömülüyse) `genForList`nin
                    // kendi `alloc8`'i her dış yinelemede yığını küçültüp
                    // asla geri almaz — bkz. `adjustModSign`deki AYNI
                    // yığın taşması hatası ve oradaki belge notu.
                    try locals.append(self.allocator, .{ .name = try forListIdxName(self.allocator, f.var_name), .info = .{ .qtype = .l } });
                } else {
                    return error.Unsupported;
                }
                try self.collectLocals(locals, f.body, in_lowlevel);
            },
            .if_stmt => |f| {
                try self.collectLocals(locals, f.then_body, in_lowlevel);
                for (f.elif_clauses) |ec| try self.collectLocals(locals, ec.body, in_lowlevel);
                if (f.else_body) |eb| try self.collectLocals(locals, eb, in_lowlevel);
            },
            .while_stmt => |w| try self.collectLocals(locals, w.body, in_lowlevel),
            .try_stmt => |t| {
                try self.collectLocals(locals, t.try_body, in_lowlevel);
                for (t.except_clauses) |ec| {
                    // Bulundu (bkz. proje belleği "from-import class type
                    // annotations" görevi, `exceptions.zig`nin `genTry`
                    // dallıyla AYNI KÖK neden — bu ÜÇÜNCÜ bağımsız kod
                    // yolu, `genTry`den ÖNCE, `genMain`in `collectLocals`
                    // ÇAĞRISINDAN çalışır): `from nox.sqlite import
                    // SqliteError` GİBİ bir from-import edilmiş istisna
                    // sınıfı BURADA da AYNI `from_imports` geri düşüşüne
                    // İHTİYAÇ duyar.
                    const class_name = if (self.classes.contains(ec.class_name))
                        ec.class_name
                    else if (self.from_imports.get(ec.class_name)) |mangled| blk: {
                        if (!self.classes.contains(mangled)) return error.Unsupported;
                        break :blk mangled;
                    } else return error.Unsupported;
                    if (ec.bind_name) |bn| {
                        try locals.append(self.allocator, .{
                            .name = bn,
                            .info = .{ .qtype = .l, .heap = .class, .class_name = class_name },
                            .arena = in_lowlevel,
                        });
                    }
                    try self.collectLocals(locals, ec.body, in_lowlevel);
                }
                if (t.finally_body) |fb| try self.collectLocals(locals, fb, in_lowlevel);
            },
            .lowlevel_stmt => |ll| try self.collectLocals(locals, ll.body, true),
            // Faz U.4.3: bir iç içe `def`in BAĞLADIĞI isim (`fd.name`)
            // BAŞKA bir yerel gibi ÖNCEDEN (fonksiyon girişinde) bir
            // slota sahip OLMALIDIR — `genNestedFuncDef` (bkz. `genStmts`in
            // `.func_def` dalı) BU slotu construction ANINDA doldurur.
            // `class_name` BURADA (mangled sembol adı) ÖNCEDEN
            // hesaplanır — checker İLE AYNI FORMÜL (`self.current_path`
            // + "." + `fd.name`), `genNestedFuncDef`in construction
            // ANINDA BAĞIMSIZ olarak YENİDEN hesapladığı DEĞERLE
            // TUTARLI kalması İÇİN (bkz. `sanitizePathToSymbol`).
            .func_def => |fd| {
                const path = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ self.current_path, fd.name });
                const mangled = try sanitizePathToSymbol(self.allocator, path);
                try locals.append(self.allocator, .{ .name = fd.name, .info = .{ .qtype = .l, .heap = .closure, .class_name = mangled } });
            },
            // Faz U.5: `with EXPR as NAME:` — İKİ gizli/örtük yerel
            // GEREKİR: (1) `EXPR`in değerini TUTAN, fonksiyon-genelinde
            // bir gizli yerel (`__with_ctx_L<satır>` — bkz. `genWith`in
            // belge notu, AYNI formül) ve (2) `binding` VERİLDİYSE onun
            // KENDİ slotu. `EXPR`in SINIFI (bkz. `inferWithCtxClassName`)
            // codegen'in (checker'ın AKSİNE tam tip çıkarımı OLMAYAN)
            // KISITLI desenlerinden (`ClassAdı(...)` kurucu çağrısı YA
            // DA ZATEN bilinen bir yerel) çıkarılır — `for x in xs:`nin
            // AYNI kısıtıyla TUTARLI (bkz. yukarıdaki `.for_stmt` dalı).
            .with_stmt => |w| {
                const class_name = try self.inferWithCtxClassName(w.ctx_expr, locals.items);
                try locals.append(self.allocator, .{
                    .name = try std.fmt.allocPrint(self.allocator, "__with_ctx_L{d}", .{stmt.line}),
                    .info = .{ .qtype = .l, .heap = .class, .class_name = class_name },
                    .arena = in_lowlevel,
                });
                if (w.binding) |bn| {
                    const cinfo = self.classes.get(class_name).?;
                    const enter_sig = cinfo.methods.get("__enter__") orelse return error.Unsupported;
                    try locals.append(self.allocator, .{ .name = bn, .info = enter_sig.ret, .arena = in_lowlevel });
                }
                try self.collectLocals(locals, w.body, in_lowlevel);
            },
            .class_def, .protocol_def, .extern_def => return error.Unsupported,
            else => {},
        }
    }
}

/// Faz U.5: `collectLocals`in `.with_stmt` dalı İÇİN — `ctx_expr`in
/// SINIFINI, checker'ın TAM tip çıkarımı OLMADAN, YALNIZCA iki gerçekçi
/// desenden çıkarır: doğrudan bir `ClassAdı(...)` kurucu çağrısı (ör.
/// `with FileHandle("x.txt") as f:`) ya da ZATEN bilinen (önceden
/// `locals`e eklenmiş) bir sınıf tipli yerelin adı (ör. `with existing_
/// resource:`). Başka HİÇBİR ifade şekli (alan okuması, metod çağrısı,
/// indeksleme...) v1 kapsamında DESTEKLENMEZ — `inferFieldType`in AYNI
/// bilinçli dar kapsamıyla TUTARLI.
pub fn inferWithCtxClassName(self: *Codegen, ctx_expr: ast.Expr, locals: []const LocalDecl) CodegenError![]const u8 {
    switch (ctx_expr) {
        .call => |c| {
            if (c.callee.* != .identifier) return error.Unsupported;
            const name = c.callee.identifier;
            if (!self.classes.contains(name)) return error.Unsupported;
            return name;
        },
        .identifier => |name| {
            const info = Codegen.findLocal(locals, name) orelse return error.Unsupported;
            if (info.heap != .class) return error.Unsupported;
            return info.class_name orelse return error.Unsupported;
        },
        else => return error.Unsupported,
    }
}

pub fn allocSlot(self: *Codegen, name: []const u8, info: TypeInfo, is_param: bool, arena: bool) CodegenError!void {
    const slot = try self.newTemp();
    const size: usize = if (info.qtype == .w) 4 else 8;
    try self.out.writer.print("    {s} =l alloc{d} {d}\n", .{ slot, size, size });
    if (isHeapManaged(info.heap) and !is_param) {
        try self.out.writer.print("    storel 0, {s}\n", .{slot});
    }
    try self.vars.put(self.allocator, name, .{
        .slot = slot,
        .qtype = info.qtype,
        .heap = info.heap,
        .elem_qtype = info.elem_qtype,
        .class_name = info.class_name,
        .elem_heap_info = info.elem_heap_info,
        .elem_is_str = info.elem_is_str,
        .dict_info = info.dict_info,
        .func_sig = info.func_sig,
        .is_param = is_param,
        .arena = arena,
    });
}

/// Faz GG.2 (bkz. nox-teknik-spesifikasyon.md §3.67): `allocSlot`in AYNISI
/// (slotu QBE giriş bloğunda tahsis eder, heap-yönetimliyse sıfırla
/// doldurur) AMA `self.vars`a HİÇ YAZMAZ — YALNIZCA bir `NamedSlot`
/// döner. Bir inline-splice sitesinin ÖN-TAHSİS EDİLMİŞ slotları BURADAN
/// geçer, ÇÜNKÜ `self.vars`a KALICI olarak yazmak (normal `allocSlot`
/// gibi) caller'IN AYNI isimli KENDİ yerelini (varsa) KALICI olarak
/// EZERDİ — `genInlinedCall` bunun yerine BU slotu YALNIZCA splice
/// SÜRESİNCE `self.vars`a GEÇİCİ olarak GÖLGELER (bkz. onun belge notu).
pub fn allocInlineSlot(self: *Codegen, orig_name: []const u8, info: TypeInfo, is_param: bool) CodegenError!NamedSlot {
    const slot = try self.newTemp();
    const size: usize = if (info.qtype == .w) 4 else 8;
    try self.out.writer.print("    {s} =l alloc{d} {d}\n", .{ slot, size, size });
    if (isHeapManaged(info.heap) and !is_param) {
        try self.out.writer.print("    storel 0, {s}\n", .{slot});
    }
    return .{ .orig_name = orig_name, .slot = slot, .info = info };
}

pub fn genFunction(self: *Codegen, fd: ast.FuncDef) CodegenError!void {
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
    self.current_path = fd.name;

    const ret_info = try self.resolveType(fd.return_type);
    self.current_ret_qtype = ret_info.qtype;
    self.current_ret_info = ret_info;
    self.current_catch_label = null;
    self.in_main = false;

    var locals: std.ArrayListUnmanaged(LocalDecl) = .empty;
    defer locals.deinit(self.allocator);
    for (fd.params) |p| {
        try locals.append(self.allocator, .{ .name = p.name, .info = try self.resolveType(p.type_expr), .is_param = true });
    }
    try self.collectLocals(&locals, fd.body, false);

    if (ret_info.qtype == .none) {
        try self.out.writer.print("export function ${s}(l {s}", .{ fd.name, RT_PARAM });
    } else {
        try self.out.writer.print("export function {s} ${s}(l {s}", .{ qbeTypeName(ret_info.qtype), fd.name, RT_PARAM });
    }
    for (fd.params) |p| {
        try self.out.writer.writeAll(", ");
        const info = try self.resolveType(p.type_expr);
        try self.out.writer.print("{s} %p_{s}", .{ qbeTypeName(info.qtype), p.name });
    }
    try self.out.writer.writeAll(") {\n@start\n");

    for (locals.items) |l| try self.allocSlot(l.name, l.info, l.is_param, l.arena);
    try self.prepareInlineSites(fd.body);
    for (fd.params) |p| {
        const info = self.vars.get(p.name).?;
        try self.out.writer.print("    store{s} %p_{s}, {s}\n", .{ qbeTypeName(info.qtype), p.name, info.slot });
    }
    try self.setupDeferListIfNeeded(fd.body);

    try self.genStmts(fd.body, ret_info.qtype);
    try self.drainDeferIfSet();
    try self.releaseAllLocals();

    const end_label = try self.newLabel("fn_end");
    try self.out.writer.print("{s}\n", .{end_label});
    try self.emitDefaultReturn(ret_info.qtype);
    try self.out.writer.writeAll("}\n");
}

pub fn genMethod(self: *Codegen, class_name: []const u8, m: ast.FuncDef) CodegenError!void {
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
    self.current_path = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ class_name, m.name });

    const ret_info = try self.resolveType(m.return_type);
    self.current_ret_qtype = ret_info.qtype;
    self.current_ret_info = ret_info;
    self.current_catch_label = null;
    self.in_main = false;

    var locals: std.ArrayListUnmanaged(LocalDecl) = .empty;
    defer locals.deinit(self.allocator);
    try locals.append(self.allocator, .{
        .name = "self",
        .info = .{ .qtype = .l, .heap = .class, .class_name = class_name },
        .is_param = true,
    });
    for (m.params[1..]) |p| {
        try locals.append(self.allocator, .{ .name = p.name, .info = try self.resolveType(p.type_expr), .is_param = true });
    }
    try self.collectLocals(&locals, m.body, false);

    const fn_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ class_name, m.name });
    if (ret_info.qtype == .none) {
        try self.out.writer.print("export function ${s}(l {s}, l %p_self", .{ fn_name, RT_PARAM });
    } else {
        try self.out.writer.print("export function {s} ${s}(l {s}, l %p_self", .{ qbeTypeName(ret_info.qtype), fn_name, RT_PARAM });
    }
    for (m.params[1..]) |p| {
        try self.out.writer.writeAll(", ");
        const info = try self.resolveType(p.type_expr);
        try self.out.writer.print("{s} %p_{s}", .{ qbeTypeName(info.qtype), p.name });
    }
    try self.out.writer.writeAll(") {\n@start\n");

    for (locals.items) |l| try self.allocSlot(l.name, l.info, l.is_param, l.arena);
    try self.prepareInlineSites(m.body);
    {
        const info = self.vars.get("self").?;
        try self.out.writer.print("    storel %p_self, {s}\n", .{info.slot});
    }
    for (m.params[1..]) |p| {
        const info = self.vars.get(p.name).?;
        try self.out.writer.print("    store{s} %p_{s}, {s}\n", .{ qbeTypeName(info.qtype), p.name, info.slot });
    }
    try self.setupDeferListIfNeeded(m.body);

    try self.genStmts(m.body, ret_info.qtype);
    try self.drainDeferIfSet();
    try self.releaseAllLocals();

    const end_label = try self.newLabel("fn_end");
    try self.out.writer.print("{s}\n", .{end_label});
    try self.emitDefaultReturn(ret_info.qtype);
    try self.out.writer.writeAll("}\n");
}

pub fn genMain(self: *Codegen, stmts: []const ast.Stmt, use_async: bool) CodegenError!void {
    if (use_async) return self.genMainAsync(stmts);

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
    self.current_ret_qtype = .w;
    self.current_catch_label = null;
    // `defer`, modül seviyesinde ASLA geçerli DEĞİLDİR (checker'ın
    // `checkDeferStmt`i `ctx.expected_return == null`i REDDEDER) — ama
    // BAŞKA bir fonksiyonun derlemesinden KALAN bayat bir değeri
    // (`emitExceptionCheck`nin `in_main` dalı ONU KULLANIR) burada
    // AÇIKÇA sıfırlamak, `current_catch_label` İLE AYNI savunmacı
    // disiplindir.
    self.current_defer_list = null;
    self.in_main = true;

    var locals: std.ArrayListUnmanaged(LocalDecl) = .empty;
    defer locals.deinit(self.allocator);
    try self.collectLocals(&locals, stmts, false);

    // Stdlib fazı §J: `w %argc, l %argv` — C ABI'nin GERÇEK `main(int
    // argc, char **argv)` imzasıyla UYUMLU (bkz. `nox_os_init`in belge
    // notu, `runtime/stdlib_shims/os.zig`) — `nox.os` HİÇ import
    // edilmese BİLE KOŞULSUZ eklenir (basitlik: ikinci bir `$main`
    // kodgen yolu YOK, argv'yi HİÇ kullanmayan programlar İÇİN bu
    // parametreler yalnızca kullanılmadan geçilir, sıfıra yakın
    // maliyet).
    try self.out.writer.writeAll("export function w $main(w %argc, l %argv) {\n@start\n");
    try self.out.writer.print("    {s} =l call $nox_runtime_init()\n", .{RT_PARAM});
    try self.out.writer.writeAll("    call $nox_os_init(w %argc, l %argv)\n");
    // Not: `main`in kendi PARAMETRESİ yoktur, ama `collectLocals` artık
    // BAZI yerelleri (heap-yönetimli elemanlı bir `for`nin döngü
    // değişkeni — bkz. `collectLocals`) ödünç alınmış olarak `is_param =
    // true` ile işaretleyebiliyor; bu bilgiyi burada YOK SAYMAK
    // (eskiden olduğu gibi sabit `false`) kapsam-sonu otomatik release'i
    // yanlışlıkla tetikleyip listenin sahipliğini bozardı.
    for (locals.items) |l| try self.allocSlot(l.name, l.info, l.is_param, l.arena);
    try self.prepareInlineSites(stmts);
    try self.genStmts(stmts, .w);
    try self.releaseAllLocals();
    try self.out.writer.print("    call $nox_runtime_deinit(l {s})\n", .{RT_PARAM});
    const end_label = try self.newLabel("fn_end");
    try self.out.writer.print("{s}\n", .{end_label});
    try self.out.writer.writeAll("    ret 0\n}\n");
}

/// `moduleUsesAsync` `true` döndüğünde `genMain` yerine kullanılır —
/// modülün üst düzey deyimleri (Nox'ta açık bir `def main()` sözleşmesi
/// YOK, bkz. `checkModule`nin `top_ctx.in_async = true` notu) bir fiber
/// GİRİŞİ olarak (`$main_body`) derlenir, `$main` (gerçek C ABI girişi)
/// yalnızca onu zamanlayıcıya spawn edip tamamlanmasını bekleyen İNCE
/// bir sürücüye dönüşür. Bu, async KULLANMAYAN programların (büyük
/// çoğunluk) `genMain`in DEĞİŞMEMİŞ, sıfır-ek-maliyetli yolundan
/// geçmeye devam etmesini sağlar (bkz. nox-teknik-spesifikasyon.md
/// §3.21, aşama 4).
pub fn genMainAsync(self: *Codegen, stmts: []const ast.Stmt) CodegenError!void {
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
    self.current_ret_qtype = .l;
    self.current_catch_label = null;
    self.current_defer_list = null;
    self.in_main = true;

    var locals: std.ArrayListUnmanaged(LocalDecl) = .empty;
    defer locals.deinit(self.allocator);
    try self.collectLocals(&locals, stmts, false);

    try self.out.writer.writeAll("export function l $main_body(l %argp) {\n@start\n");
    try self.out.writer.print("    {s} =l loadl %argp\n", .{RT_PARAM});
    for (locals.items) |l| try self.allocSlot(l.name, l.info, l.is_param, l.arena);
    try self.prepareInlineSites(stmts);
    try self.genStmts(stmts, .l);
    try self.releaseAllLocals();
    try self.out.writer.print("    call $nox_free(l {s}, l %argp, l 8)\n", .{RT_PARAM});
    const end_label = try self.newLabel("fn_end");
    try self.out.writer.print("{s}\n", .{end_label});
    try self.out.writer.writeAll("    ret 0\n}\n");

    // `$main` — gerçek C ABI girişi: çalışma zamanını/zamanlayıcıyı
    // başlatır, üst düzey kodu (`$main_body`) TEK bir görev olarak
    // spawn eder, tamamlanmasını (ya da bir kilitlenmeyi) bekler.
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
    // Bkz. `genMain`in AYNI notu — `w %argc, l %argv` KOŞULSUZ eklenir.
    try self.out.writer.writeAll("export function w $main(w %argc, l %argv) {\n@start\n");
    try self.out.writer.print("    {s} =l call $nox_runtime_init()\n", .{RT_PARAM});
    try self.out.writer.writeAll("    call $nox_os_init(w %argc, l %argv)\n");
    try self.out.writer.print("    call $nox_async_init(l {s})\n", .{RT_PARAM});
    const closure_t = try self.newTemp();
    try self.out.writer.print("    {s} =l call $nox_alloc(l {s}, l 8)\n", .{ closure_t, RT_PARAM });
    try self.out.writer.print("    storel {s}, {s}\n", .{ RT_PARAM, closure_t });
    const task_t = try self.newTemp();
    try self.out.writer.print("    {s} =l call $nox_async_spawn(l {s}, l $main_body, l {s})\n", .{ task_t, RT_PARAM, closure_t });
    const run_result_t = try self.newTemp();
    try self.out.writer.print("    {s} =w call $nox_async_run_to_completion(l {s})\n", .{ run_result_t, RT_PARAM });
    const deadlock_label = try self.newLabel("deadlock");
    const ok_label = try self.newLabel("no_deadlock");
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ run_result_t, deadlock_label, ok_label });
    try self.out.writer.print("{s}\n", .{deadlock_label});
    try self.out.writer.print("    call $nox_async_deadlock_abort(l {s})\n", .{RT_PARAM});
    try self.out.writer.writeAll("    ret 0\n"); // erişilemez — savunmacı (bkz. `emitExceptionCheck`in AYNI deseni)
    try self.out.writer.print("{s}\n", .{ok_label});
    try self.out.writer.print("    call $nox_async_destroy_task(l {s}, l {s})\n", .{ RT_PARAM, task_t });
    try self.out.writer.print("    call $nox_async_deinit(l {s})\n", .{RT_PARAM});
    try self.out.writer.print("    call $nox_runtime_deinit(l {s})\n", .{RT_PARAM});
    try self.out.writer.writeAll("    ret 0\n}\n");
}
