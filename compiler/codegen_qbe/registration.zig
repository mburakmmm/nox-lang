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
/// Faz NN.2: `pkg.module.ClassName` — `.qualified`in segmentlerini
/// (`self.module_aliases` İLE ilk segmenti ikame ettikten SONRA) `_`
/// İLE birleştirip checker'ın `typeExprToType`indeki (VE `resolveType`in
/// `.qualified` dalındaki) AYNI mangled sınıf adını üretir. Hem `resolveType`
/// hem `appendMangledTypeExprName` (bir generic sınıf tip ARGÜMANI olarak
/// kullanıldığında, ör. `Box[pkg.module.Foo]`) TARAFINDAN paylaşılır —
/// checker'ın `appendMangledType`inin `.class` dalı ZATEN ÇÖZÜLMÜŞ (mangled)
/// isimle çalıştığından, İKİSİNİN de AYNI sonucu üretmesi GEREKİR.
fn mangledQualifiedClassName(self: *Codegen, raw_segments: []const []const u8) CodegenError![]const u8 {
    var segments: []const []const u8 = raw_segments;
    if (raw_segments.len > 0) {
        if (self.module_aliases.get(raw_segments[0])) |target| {
            const out = try self.allocator.alloc([]const u8, target.len + raw_segments.len - 1);
            @memcpy(out[0..target.len], target);
            @memcpy(out[target.len..], raw_segments[1..]);
            segments = out;
        }
    }
    var mangled: std.ArrayListUnmanaged(u8) = .empty;
    for (segments, 0..) |seg, i| {
        if (i != 0) try mangled.append(self.allocator, '_');
        try mangled.appendSlice(self.allocator, seg);
    }
    return mangled.toOwnedSlice(self.allocator);
}

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
        // Faz NN.2: `Box[pkg.module.Foo]` gibi bir generic tip ARGÜMANI —
        // checker'ın `appendMangledType`inin `.class` dalı ZATEN ÇÖZÜLMÜŞ
        // mangled isimle çalıştığından, BURADA da AYNI mangled ismi
        // (`mangledQualifiedClassName`) üretip yazıyoruz.
        .qualified => |segments| try buf.appendSlice(self.allocator, try mangledQualifiedClassName(self, segments)),
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
                // bool/str/sınıf (Faz OO.4) — list/dict/Task/Channel
                // anahtar/değer checker'da ZATEN reddedilir, burası
                // savunmacıdır.
                if (key.heap != .none and key.heap != .str) return error.Unsupported;
                if (value.heap != .none and value.heap != .str and value.heap != .class) return error.Unsupported;
                const dinfo = try self.allocator.create(DictInfo);
                dinfo.* = .{ .key_is_str = key.heap == .str, .key_qtype = key.qtype, .value_qtype = value.qtype, .value_is_str = value.heap == .str, .value_is_class = value.heap == .class, .value_class_name = value.class_name };
                return .{ .qtype = .l, .heap = .dict, .dict_info = dinfo };
            }
            const is_list = std.mem.eql(u8, g.name, "list");
            const is_task = std.mem.eql(u8, g.name, "Task");
            const is_channel = std.mem.eql(u8, g.name, "Channel");
            const is_thread_handle = std.mem.eql(u8, g.name, "ThreadHandle");
            const is_thread_channel = std.mem.eql(u8, g.name, "ThreadChannel");
            const is_task_local = std.mem.eql(u8, g.name, "TaskLocal");
            if (!(is_list or is_task or is_channel or is_thread_handle or is_thread_channel or is_task_local)) {
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
                // Bulundu (bkz. proje belleği "4 yeni stdlib modülü" planı,
                // nox.collections): `.simple` dalı (satır ~109) `from_imports`
                // geri düşüşüne SAHİPTİ ama BU dal DEĞİLDİ — `from nox.
                // collections import Stack` İLE getirilen bir generic sınıf,
                // `g.name` HÂLÂ ÇIPLAK "Stack" OLDUĞUNDAN (module_loader'ın
                // `renameTypeExpr`i `.generic` kolunda YALNIZCA `g.args`ı
                // yeniden adlandırır, `g.name`i DEĞİL — bkz. onun belge notu)
                // `mangleGenericClassName(self, "Stack", ...)` checker'ın
                // GERÇEKTEN kaydettiği (modül-önekli TABAN isimden türeyen)
                // mangled adla HİÇ EŞLEŞMEZDİ. `from_imports` üzerinden
                // TABAN ismi çözüp mangling'i O isimle TEKRARLIYORUZ.
                if (self.from_imports.get(g.name)) |mangled_base| {
                    const mangled2 = try mangleGenericClassName(self, mangled_base, g.args);
                    if (self.classes.contains(mangled2)) {
                        return .{ .qtype = .l, .heap = .class, .class_name = mangled2 };
                    }
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
            // Bulundu (nyx framework — bkz. proje belleği "NOX_LIMITATIONS.md
            // incelemesi", C1): `.dict` EKLENDİ — `dict` (Faz FF.3'ten beri
            // `str`/`list`/`class` İLE AYNI TAM ARC modelinde, bkz. `HeapKind`in
            // belge notu) bir `list[T]`nin ELEMAN tipi OLARAK kullanıldığında
            // (`list[dict[str,str]]`) BU dal ÖNCEDEN `.dict`i ATLIYORDU —
            // `error.Unsupported`a düşüp "desteklenmeyen bir yapı" hatasıyla
            // ÇÖKÜYORDU (checker ZATEN kabul ettiğinden — `Type`, `list`nin
            // eleman tipinin `dict` OLMASINI hiç KISITLAMAZ — bu SADECE
            // codegen'in `ElemHeapInfo`sunda eksik bir dal, mimari bir sınır
            // DEĞİLDİ).
            if (elem.heap == .class or elem.heap == .list or elem.heap == .str or elem.heap == .closure or elem.heap == .dict) {
                const info = try self.allocator.create(ElemHeapInfo);
                info.* = .{ .heap = elem.heap, .class_name = elem.class_name, .elem_qtype = elem.elem_qtype, .nested = elem.elem_heap_info, .elem_is_str = elem.elem_is_str, .func_sig = elem.func_sig, .dict_info = elem.dict_info };
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
                .heap = if (is_list) .list else if (is_task) .task else if (is_channel) .channel else if (is_thread_handle) .thread_handle else if (is_thread_channel) .thread_channel else .task_local,
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
        // Faz NN.2: `pkg.module.ClassName` — checker'ın `typeExprToType`
        // İLE AYNI alias-ikame + `_`-mangling mantığı (bkz. `Codegen.
        // module_aliases`in belge notu) — codegen KENDİ BAĞIMSIZ kopyasını
        // yapmak ZORUNDADIR çünkü checker `ast.TypeExpr.qualified`'ı YERİNDE
        // mangled forma YENİDEN YAZAMAZ (`from_imports`in AYNI kısıtı).
        // Checker BUNU ZATEN başarıyla çözmüş OLMALIDIR (aksi halde tip
        // denetimi BAŞARISIZ olurdu) — burası SAVUNMACI bir güvenlik ağıdır.
        .qualified => |raw_segments| {
            const mangled_name = try mangledQualifiedClassName(self, raw_segments);
            if (self.classes.contains(mangled_name)) {
                return .{ .qtype = .l, .heap = .class, .class_name = mangled_name };
            }
            return error.Unsupported;
        },
    }
}

// ---- Sınıf kaydı (fonksiyon/main gövdeleri üretilmeden ÖNCE tamamlanmalı) ----

/// Faz 7 (tekli kalıtım): `class_defs`i TABAN sınıf ÖNCE, türetilen SONRA
/// olacak şekilde bir İŞ LİSTESİ (worklist) İLE kaydeder — `registerClass`ın
/// alan/metod DÜZLEŞTİRMESİ tabanın ZATEN TAM doldurulmuş `ClassInfo`suna
/// ihtiyaç duyar (checker.zig'in `registerClassesInOrder`ıyla AYNI
/// gerekçe/tasarım). Checker BU sıralamayı ZATEN doğruladığından (döngüsel
/// kalıtım/bilinmeyen taban DERLEME buraya HİÇ ULAŞAMAZ) burada SADECE
/// savunmacı bir `error.Unsupported` vardır.
pub fn registerClassesInOrder(self: *Codegen, class_defs: []const ast.ClassDef) CodegenError!void {
    var remaining: std.ArrayListUnmanaged(ast.ClassDef) = .empty;
    try remaining.appendSlice(self.allocator, class_defs);
    var processed: std.StringHashMapUnmanaged(void) = .{};
    while (remaining.items.len > 0) {
        var progress = false;
        var i: usize = 0;
        while (i < remaining.items.len) {
            const cd = remaining.items[i];
            const ready = cd.base == null or processed.contains(cd.base.?);
            if (ready) {
                try self.registerClass(cd);
                try processed.put(self.allocator, cd.name, {});
                _ = remaining.swapRemove(i);
                progress = true;
            } else {
                i += 1;
            }
        }
        if (!progress) return error.Unsupported;
    }
}

/// Faz 7: `class_defs`teki HER `cd.base`i (KENDİSİ VE hedefi) toplayan,
/// SAF/sıraya BAĞIMSIZ bir ön-tarama — bir sınıfın kalıtıma KATILIP
/// KATILMADIĞINI (`ClassInfo.has_vtable`), o sınıf HENÜZ (taban-önce
/// sırada) kaydedilmeden ÖNCE bilmek İçin gerekir (bir taban sınıfın
/// KENDİ nesne düzeni, HENÜZ KAYDEDİLMEMİŞ bir alt sınıfın var OLUP
/// OLMADIĞINA bağlı olduğundan — bkz. Faz 7 tasarım notu, "ileri bilgi
/// problemi").
pub fn computeInheritingClasses(allocator: std.mem.Allocator, class_defs: []const ast.ClassDef) !std.StringHashMapUnmanaged(void) {
    var set: std.StringHashMapUnmanaged(void) = .{};
    for (class_defs) |cd| {
        if (cd.base) |b| {
            try set.put(allocator, cd.name, {});
            try set.put(allocator, b, {});
        }
    }
    return set;
}

pub fn registerClass(self: *Codegen, cd: ast.ClassDef) CodegenError!void {
    var init_fd: ?ast.FuncDef = null;
    for (cd.methods) |m| {
        if (std.mem.eql(u8, m.name, "__init__")) init_fd = m;
    }

    var info: types.ClassInfo = .{};
    info.base = cd.base;
    info.has_vtable = self.inheriting_classes.contains(cd.name);
    const field_base_offset = TAG_SIZE + (if (info.has_vtable) types.VTABLE_PTR_SIZE else 0);

    // Faz 7: taban sınıfın (bu noktada `registerClassesInOrder` sayesinde
    // ZATEN TAM kaydedilmiş) alanlarını/metodlarını KOPYALA — "en az
    // invaziv strateji" (checker.zig'in `registerClassSignatures`ıyla
    // AYNI gerekçe). Codegen'in checker'DAN FARKLI olarak İKİNCİ bir
    // "gövde denetiminden SONRA tamamlayıcı kopyalama" adımına İHTİYACI
    // YOKTUR — `inferFieldType` HER ZAMAN SADECE bu sınıfın KENDİ
    // `__init__` AST'sini tarar (başka bir sınıfın gövdesinin ÖNCE
    // işlenmiş OLMASINA hiç bağımlı DEĞİL), bu yüzden taban-önce KAYIT
    // sırası (checker'ın taban-önce GÖVDE DENETİM sırasından FARKLI
    // olarak) TEK BAŞINA yeterlidir.
    var base_info: ?types.ClassInfo = null;
    if (cd.base) |base_name| {
        base_info = self.classes.get(base_name).?;
        for (base_info.?.fields.items) |f| try info.fields.append(self.allocator, f);
    }

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
            .offset = field_base_offset + (info.fields.items.len) * FIELD_SLOT_SIZE,
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
                .offset = field_base_offset + (info.fields.items.len) * FIELD_SLOT_SIZE,
            });
        }
        info.total_size = field_base_offset + info.fields.items.len * FIELD_SLOT_SIZE;

        const iparams = try self.allocator.alloc(TypeInfo, init.params.len - 1);
        for (init.params[1..], 0..) |p, i| iparams[i] = try self.resolveType(p.type_expr);
        info.init_params = iparams;
        info.init_owner = cd.name;
    } else if (base_info) |bi| {
        // Faz 7: bu sınıfın KENDİ `__init__`i yok — taban sınıfın
        // kurucusunu (parametreleri VE hangi sınıfın onu GERÇEKTEN
        // uyguladığını) OLDUĞU GİBİ MİRAS AL (Python-tarzı örtük kurucu
        // zincirleme — checker.zig'in `registerClassSignatures`ıyla AYNI
        // semantik).
        info.has_init = bi.has_init;
        info.init_params = bi.init_params;
        info.init_owner = bi.init_owner;
        info.total_size = field_base_offset + info.fields.items.len * FIELD_SLOT_SIZE;
    } else {
        // `__init__`i olmayan (VE taban sınıfı da OLMAYAN) sınıf (bkz.
        // `ClassInfo.has_init`in belge notu): kurucu 0 argüman alır —
        // checker zaten bu durumda çağrı sitesinde 0 argüman şart koşar
        // (bkz. checker.zig, `checkCall`in `.identifier` dalı, `init_sig
        // orelse` varsayılanı). Faz FF.5: bildirilen alanlar (varsa) YİNE
        // de `info.fields`de KALIR (yukarıda eklendi) — ama checker BU
        // durumu (bildirilen bir alanın `__init__` OLMADIĞI İçin HİÇ
        // atanamaması) ZATEN `UnassignedField` İLE REDDETTİĞİNDEN (bkz.
        // `checkClassBody`), bu yol PRATİKTE codegen'e HİÇ ULAŞMAZ —
        // yalnızca savunmacı tutarlılık İçin `total_size` yine de
        // alanları HESABA katar.
        info.has_init = false;
        info.total_size = field_base_offset + info.fields.items.len * FIELD_SLOT_SIZE;
    }
    info.class_id = self.next_class_id;
    self.next_class_id += 1;

    // Faz 7: taban sınıfın metodlarını (SAHİP/owner + vtable slotuyla
    // BİRLİKTE) KOPYALA — miras alınan, override EDİLMEMİŞ bir metod
    // İçin `owner`/`slot` DEĞİŞMEDEN kalır (`genMethodCall`in ÜRETTİĞİ
    // sembol/dispatch, TABANIN KENDİ gövdesine gider).
    var next_slot: usize = 0;
    if (base_info) |bi| {
        var mit = bi.methods.iterator();
        while (mit.next()) |e| try info.methods.put(self.allocator, e.key_ptr.*, e.value_ptr.*);
        next_slot = bi.next_vtable_slot;
    }
    for (cd.methods) |m| {
        if (std.mem.eql(u8, m.name, "__init__")) continue;
        const params = try self.allocator.alloc(TypeInfo, m.params.len - 1);
        for (m.params[1..], 0..) |p, i| params[i] = try self.resolveType(p.type_expr);
        const ret = try self.resolveType(m.return_type);
        var slot: usize = 0;
        if (info.has_vtable) {
            if (info.methods.get(m.name)) |inherited| {
                slot = inherited.slot; // override: AYNI slot (checker ZATEN imzanın TAM eşleştiğini doğruladı)
            } else {
                slot = next_slot;
                next_slot += 1;
            }
        }
        try info.methods.put(self.allocator, m.name, .{ .sig = .{ .params = params, .ret = ret }, .owner = cd.name, .slot = slot });
    }
    info.next_vtable_slot = next_slot;

    try self.classes.put(self.allocator, cd.name, info);
}

/// Bulundu, GERÇEK bir regresyon (bkz. proje belleği "modül-seviyesi
/// global durum" planı): İLK uygulama HER üst-düzey `var_decl`yi
/// KOŞULSUZ bir "global" sayıp `$main`in SIRADAN yerellerinden (bkz.
/// `codegen.zig`nin `loose` inşası) ÇIKARIYORDU — bu, SADECE üst-düzey
/// kodun KENDİSİ İçinde kullanılan (HİÇBİR fonksiyondan REFERANS
/// ALINMAYAN) sıradan bir betik değişkenini de (ör. `xs: list[int] =
/// [...]` + `for v in xs: ...`, HİÇ fonksiyon İÇERMEYEN onlarca MEVCUT
/// golden test) `self.vars`den ÇIKARDI — `genForList`/`genListAppend`
/// GİBİ ALICIYI `self.vars.get(isim)` İLE DOĞRUDAN (genExpr'in genel
/// düşüşünden BAĞIMSIZ) arayan ÖZEL-DURUM kod yolları BU YÜZDEN
/// `error.Unsupported`a düşüyordu (23 AYRI, TAMAMEN ilgisiz golden test
/// GERÇEKTEN kırıldı — tekrar-üretilip DOĞRULANDI). **Düzeltme:** bir
/// `var_decl`, YALNIZCA adı HİÇ OLMAZSA bir fonksiyon/metod gövdesinin
/// İÇİNDEN (nerede olursa olsun, iç içe `def`ler DAHİL) REFERANS
/// ALINIYORSA "global" sayılır — SAF üst-düzey betik değişkenleri
/// (fonksiyonlardan HİÇ erişilmeyenler) `$main`in SIRADAN bir yereli
/// olarak KALMAYA devam eder, DAVRANIŞLARI HİÇ DEĞİŞMEZ.
///
/// `registerClass`in AYNI alan-ofseti formülü (`idx * FIELD_SLOT_SIZE`),
/// ama `TAG_SIZE` YOK (opak globals bloğu bir ARC başlığı TAŞIMAZ —
/// `nox_alloc` İLE ayrılan DÜZ bellek). TÜM sınıflar KAYDEDİLDİKTEN
/// SONRA çağrılmalıdır (`generateModule`, sınıf kayıt döngülerinden
/// HEMEN SONRA) — bir global'in tipi `list[Foo]`/`Foo` OLABİLİR,
/// `resolveType`in `self.classes`e İHTİYACI VAR.
pub fn collectModuleGlobals(self: *Codegen, module: ast.Module) CodegenError!void {
    var used_in_functions: std.StringHashMapUnmanaged(void) = .empty;
    defer used_in_functions.deinit(self.allocator);
    for (module.body) |stmt| {
        switch (stmt.kind) {
            .func_def => |fd| try collectFreeNamesForTopLevelFunc(self.allocator, fd.params, fd.body, &used_in_functions),
            .class_def => |cd| for (cd.methods) |m| try collectFreeNamesForTopLevelFunc(self.allocator, m.params, m.body, &used_in_functions),
            else => {},
        }
    }

    var idx: usize = 0;
    for (module.body) |stmt| {
        if (stmt.kind != .var_decl) continue;
        const v = stmt.kind.var_decl;
        if (!used_in_functions.contains(v.name)) continue;
        const info = try self.resolveType(v.type_expr);
        try self.module_globals.put(self.allocator, v.name, .{
            .name = v.name,
            .info = info,
            .offset = idx * FIELD_SLOT_SIZE,
        });
        idx += 1;
    }
    self.module_globals_size = idx * FIELD_SLOT_SIZE;
}

/// Bir üst-düzey `func_def`/metod gövdesindeki (İÇ İÇE `def`ler DAHİL,
/// hepsi TEK bir düz ağaç olarak) HANGİ isimlerin GERÇEKTEN "serbest"
/// (yani KENDİ parametresi/yerel bildirimi OLMAYAN, dolayısıyla bir
/// modül-global'e DÜŞEBİLECEK) olduğunu hesaplar. **Bulundu:** ilk
/// uygulama SADECE kullanılan isimleri (`collectIdentifierNamesStmts`)
/// topluyordu, KENDİ parametresi/yerelini HİÇ ÇIKARMADAN — bu YÜZDEN
/// otomatik-enjekte edilen builtin sarmalayıcıları (ör. `sum(xs: list[int])`,
/// `compiler/codegen_qbe/registration.zig`nin builtin-genişletme fazında
/// eklenen fonksiyonlar) KENDİ `xs` PARAMETRESİNİ, kullanıcının TAMAMEN
/// İLGİSİZ üst-düzey `xs` değişkeniyle SADECE İSİM ÇAKIŞMASI yüzünden
/// bir "global kullanımı" SANIYORDU — 22 AYRI golden test'i KIRDI (hiçbir
/// fonksiyonu OLMAYAN programlar DAHİL, çünkü her programa OTOMATİK
/// enjekte edilen builtin fonksiyonlar zaten module.body'DE mevcuttur).
/// **Düzeltme:** `bound` kümesi (parametreler + `var_decl`/for-döngüsü/
/// except-as/with-as bağlamaları, İÇ İÇE `def`ler DAHİL tek bir düz
/// kümede biriktirilir) `used` kümesinden ÇIKARILIR — yalnızca GERÇEKTEN
/// dışarıdan (modül-seviyesinden) gelmesi gereken isimler `out`a girer.
fn collectFreeNamesForTopLevelFunc(a: std.mem.Allocator, params: []const ast.Param, body: []const ast.Stmt, out: *std.StringHashMapUnmanaged(void)) CodegenError!void {
    var bound: std.StringHashMapUnmanaged(void) = .empty;
    defer bound.deinit(a);
    for (params) |p| try bound.put(a, p.name, {});
    try collectBoundNamesStmts(a, body, &bound);

    var used: std.StringHashMapUnmanaged(void) = .empty;
    defer used.deinit(a);
    try collectIdentifierNamesStmts(a, body, &used);

    var it = used.keyIterator();
    while (it.next()) |k| {
        if (!bound.contains(k.*)) try out.put(a, k.*, {});
    }
}

/// `collectIdentifierNamesStmts`nin "İKİZİ" — KULLANILAN isimler YERİNE
/// BAĞLANAN (bir parametre, `var_decl`, for-döngüsü değişkeni, except-as/
/// with-as bağlaması ya da İÇ İÇE bir `def`in KENDİ adı/parametreleri
/// OLARAK tanımlanan) isimleri toplar — İÇ İÇE `def`/sınıf gövdelerine
/// de İNER (kapsayan fonksiyonun TÜM ağacı TEK düz bir "bağlı isimler"
/// kümesi sayılır, closure'ların dış yerelleri YAKALAMASIYLA TUTARLI).
fn collectBoundNamesStmts(a: std.mem.Allocator, stmts: []const ast.Stmt, out: *std.StringHashMapUnmanaged(void)) CodegenError!void {
    for (stmts) |stmt| {
        switch (stmt.kind) {
            .var_decl => |v| try out.put(a, v.name, {}),
            .for_stmt => |f| {
                try out.put(a, f.var_name, {});
                try collectBoundNamesStmts(a, f.body, out);
            },
            .if_stmt => |f| {
                try collectBoundNamesStmts(a, f.then_body, out);
                for (f.elif_clauses) |ec| try collectBoundNamesStmts(a, ec.body, out);
                if (f.else_body) |eb| try collectBoundNamesStmts(a, eb, out);
            },
            .while_stmt => |w| try collectBoundNamesStmts(a, w.body, out),
            .func_def => |fd| {
                try out.put(a, fd.name, {});
                for (fd.params) |p| try out.put(a, p.name, {});
                try collectBoundNamesStmts(a, fd.body, out);
            },
            .class_def => |cd| for (cd.methods) |m| {
                for (m.params) |p| try out.put(a, p.name, {});
                try collectBoundNamesStmts(a, m.body, out);
            },
            .try_stmt => |t| {
                try collectBoundNamesStmts(a, t.try_body, out);
                for (t.except_clauses) |ec| {
                    if (ec.bind_name) |n| try out.put(a, n, {});
                    try collectBoundNamesStmts(a, ec.body, out);
                }
                if (t.finally_body) |fb| try collectBoundNamesStmts(a, fb, out);
            },
            .lowlevel_stmt => |ll| try collectBoundNamesStmts(a, ll.body, out),
            .with_stmt => |w| {
                if (w.binding) |n| try out.put(a, n, {});
                try collectBoundNamesStmts(a, w.body, out);
            },
            else => {},
        }
    }
}

/// `async_thread.zig`nin `stmtUsesAsync`/`exprUsesAsync`ıyla AYNI
/// KAPSAMLI (TÜM `StmtKind`/`Expr` varyantlarını gezen, iç içe `func_def`/
/// `class_def` gövdelerine de İNEN) gezinme İSKELETİ — yalnızca "async
/// kullanımı VAR MI" bool'u YERİNE, karşılaşılan HER çıplak `.identifier`
/// ismini (HEM okuma HEM `.assign` hedefi konumunda — `ast.Assign.target`
/// KENDİSİ bir `Expr` olduğundan, `.identifier` varyantı İKİSİNİ de
/// KAPSAR) `out`a ekler.
fn collectIdentifierNamesStmts(a: std.mem.Allocator, stmts: []const ast.Stmt, out: *std.StringHashMapUnmanaged(void)) CodegenError!void {
    for (stmts) |stmt| {
        switch (stmt.kind) {
            .expr_stmt => |e| try collectIdentifierNamesExpr(a, e, out),
            .var_decl => |v| try collectIdentifierNamesExpr(a, v.value, out),
            .assign => |asg| {
                try collectIdentifierNamesExpr(a, asg.target, out);
                try collectIdentifierNamesExpr(a, asg.value, out);
            },
            .if_stmt => |f| {
                try collectIdentifierNamesExpr(a, f.cond, out);
                try collectIdentifierNamesStmts(a, f.then_body, out);
                for (f.elif_clauses) |ec| {
                    try collectIdentifierNamesExpr(a, ec.cond, out);
                    try collectIdentifierNamesStmts(a, ec.body, out);
                }
                if (f.else_body) |eb| try collectIdentifierNamesStmts(a, eb, out);
            },
            .while_stmt => |w| {
                try collectIdentifierNamesExpr(a, w.cond, out);
                try collectIdentifierNamesStmts(a, w.body, out);
            },
            .for_stmt => |f| {
                try collectIdentifierNamesExpr(a, f.iterable, out);
                try collectIdentifierNamesStmts(a, f.body, out);
            },
            .func_def => |fd| try collectIdentifierNamesStmts(a, fd.body, out),
            .class_def => |cd| for (cd.methods) |m| try collectIdentifierNamesStmts(a, m.body, out),
            .protocol_def, .extern_def, .pass_stmt, .import_stmt, .from_import_stmt => {},
            .return_stmt => |r| if (r) |e| try collectIdentifierNamesExpr(a, e, out),
            .raise_stmt => |e| try collectIdentifierNamesExpr(a, e, out),
            .try_stmt => |t| {
                try collectIdentifierNamesStmts(a, t.try_body, out);
                for (t.except_clauses) |ec| try collectIdentifierNamesStmts(a, ec.body, out);
                if (t.finally_body) |fb| try collectIdentifierNamesStmts(a, fb, out);
            },
            .lowlevel_stmt => |ll| try collectIdentifierNamesStmts(a, ll.body, out),
            .with_stmt => |w| {
                try collectIdentifierNamesExpr(a, w.ctx_expr, out);
                try collectIdentifierNamesStmts(a, w.body, out);
            },
            .defer_stmt => |d| try collectIdentifierNamesExpr(a, ast.Expr{ .call = d.call }, out),
        }
    }
}

fn collectIdentifierNamesExpr(a: std.mem.Allocator, expr: ast.Expr, out: *std.StringHashMapUnmanaged(void)) CodegenError!void {
    switch (expr) {
        .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit => {},
        .identifier => |name| try out.put(a, name, {}),
        .unary => |u| try collectIdentifierNamesExpr(a, u.operand.*, out),
        .binary => |b| {
            try collectIdentifierNamesExpr(a, b.left.*, out);
            try collectIdentifierNamesExpr(a, b.right.*, out);
        },
        .call => |c| {
            try collectIdentifierNamesExpr(a, c.callee.*, out);
            for (c.args) |arg| try collectIdentifierNamesExpr(a, arg, out);
        },
        .attribute => |attr| try collectIdentifierNamesExpr(a, attr.obj.*, out),
        .index => |idx| {
            try collectIdentifierNamesExpr(a, idx.obj.*, out);
            try collectIdentifierNamesExpr(a, idx.index.*, out);
        },
        .list_lit => |elems| for (elems) |el| try collectIdentifierNamesExpr(a, el, out),
        .dict_lit => |pairs| for (pairs) |p| {
            try collectIdentifierNamesExpr(a, p.key, out);
            try collectIdentifierNamesExpr(a, p.value, out);
        },
        .await_expr => |operand| try collectIdentifierNamesExpr(a, operand.*, out),
        .spawn_expr => |operand| try collectIdentifierNamesExpr(a, operand.*, out),
        .generic_construct => |g| for (g.args) |arg| try collectIdentifierNamesExpr(a, arg, out),
    }
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
                    // Bulundu (nyx framework — bkz. proje belleği
                    // "NOX_LIMITATIONS.md incelemesi", P5): ÇIPLAK
                    // `except:` (`ec.class_name == null`) — HİÇBİR sınıf
                    // çözümlemesi/YEREL EKLENMEZ (parser `bind_name`i de
                    // HER ZAMAN `null` bırakır), yalnızca gövde işlenir.
                    if (ec.class_name) |cn| {
                        // Bulundu (bkz. proje belleği "from-import class type
                        // annotations" görevi, `exceptions.zig`nin `genTry`
                        // dallıyla AYNI KÖK neden — bu ÜÇÜNCÜ bağımsız kod
                        // yolu, `genTry`den ÖNCE, `genMain`in `collectLocals`
                        // ÇAĞRISINDAN çalışır): `from nox.sqlite import
                        // SqliteError` GİBİ bir from-import edilmiş istisna
                        // sınıfı BURADA da AYNI `from_imports` geri düşüşüne
                        // İHTİYAÇ duyar.
                        const class_name = if (self.classes.contains(cn))
                            cn
                        else if (self.from_imports.get(cn)) |mangled| blk: {
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
                    try locals.append(self.allocator, .{ .name = bn, .info = enter_sig.sig.ret, .arena = in_lowlevel });
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
    try self.allocSlotEx(name, info, is_param, arena, false);
}

/// GG.12: `allocSlot`in AYNISI, YALNIZCA `borrowed_field`i (`VarInfo`ye
/// AKTARILMASI GEREKEN TEK ekstra bayrak) de kabul eder — mevcut
/// `allocSlot` çağıranlarının (self'i OLMAYAN fonksiyonlar/inline-splice
/// siteleri DAHİL, HİÇBİRİ bu bayrağı KULLANMIYOR) imzasını DEĞİŞTİRMEDEN.
pub fn allocSlotEx(self: *Codegen, name: []const u8, info: TypeInfo, is_param: bool, arena: bool, borrowed_field: bool) CodegenError!void {
    // GG.18: `registerLocalStackSlots`in (local_escape.zig) BU isim İçin
    // ÖNCEDEN verdiği kanıt — bkz. `VarInfo.growable_arena`nın belge notu.
    // Non-null İSE `.arena` DA `true` OLUR (release-atlama MEVCUT
    // `entry.arena` mantığı KULLANSIN DİYE — `releaseOneLocalIfManaged`e
    // HİÇBİR YENİ DEĞİŞİKLİK GEREKMEZ).
    const growable_arena = self.growable_arena_names.get(name);
    const effective_arena = arena or (growable_arena != null);
    const slot = try self.newTemp();
    const size: usize = if (info.qtype == .w) 4 else 8;
    try self.qbeAlloc(slot, if (info.qtype == .w) .four else .eight, size);
    // **GERÇEK, DENEYEREK BULUNAN sızıntının kök nedeninin BİR KISMI**
    // (bkz. `stmt.zig`nin `.var_decl` dalındaki YENİ `destroyNonArcSlotIfSet`
    // çağrısının belge notu): `Task[T]`/`Channel[T]`/`ThreadHandle[T]`/
    // `ThreadChannel[T]`/`TaskLocal[T]` `isHeapManaged`in DIŞINDA
    // OLDUĞUNDAN, ÖNCEDEN yalnızca ARC-yönetimli türler sıfırla
    // dolduruluyordu — bu türlerin slotu YIĞINDAN gelen ÇÖP baytlarla
    // BAŞLIYORDU. `.var_decl`nin "üzerine yazmadan ÖNCE eskiyi yok et"
    // mantığı (döngü İçİNDE TEKRAR TEKRAR çalıştığında) İLK çalışmada BU
    // ÇÖPÜ geçerli bir işaretçi SANIP `nox_async_destroy_task`e geçirip
    // "incorrect alignment" panikleriyle ÇÖKÜYORDU (GERÇEKTEN denenip
    // gözlemlendi). Düzeltme: BU BEŞ tür de (ARC-yönetimli türlerle AYNI
    // gerekçeyle) slot GİRİŞTE sıfırlanmalı — `destroyNonArcValue`nin
    // KARŞILIK gelen `nox_*_destroy` fonksiyonlarının HEPSİ (bkz. bridge.zig)
    // ARTIK `orelse return` İLE null-güvenli olduğundan, sıfır bir
    // "henüz atanmadı" duyargası olarak GÜVENLE İŞLENİR.
    if ((isHeapManaged(info.heap) or info.heap == .task or info.heap == .channel or info.heap == .thread_handle or info.heap == .thread_channel or info.heap == .task_local) and !is_param) {
        try self.qbeStoreL("0", slot);
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
        .arena = effective_arena,
        .borrowed_field = borrowed_field,
        // GG.17: `registerLocalStackSlots`in (local_escape.zig) BU isim İçin
        // ÖNCEDEN (`prepareInlineSites`in YANINDA, AYNI fonksiyon-girişi
        // ön-taramasında) verdiği kanıt — bkz. `VarInfo.is_stack_local`in
        // belge notu.
        .is_stack_local = self.stack_local_names.contains(name),
        .growable_arena = growable_arena,
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
    try self.qbeAlloc(slot, if (info.qtype == .w) .four else .eight, size);
    // Bkz. `allocSlotEx`nin AYNI belge notu — TUTARLILIK İçİn burada da.
    if ((isHeapManaged(info.heap) or info.heap == .task or info.heap == .channel or info.heap == .thread_handle or info.heap == .thread_channel or info.heap == .task_local) and !is_param) {
        try self.qbeStoreL("0", slot);
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

    const fn_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{fd.name});
    try self.qbeFuncHeaderStart(if (ret_info.qtype == .none) null else ret_info.qtype, fn_sym);
    try self.qbeFuncParam(.l, RT_PARAM, true);
    for (fd.params) |p| {
        const info = try self.resolveType(p.type_expr);
        const param_text = try std.fmt.allocPrint(self.allocator, "%p_{s}", .{p.name});
        try self.qbeFuncParam(info.qtype, param_text, false);
    }
    try self.qbeFuncHeaderEnd();

    // GG.17: `allocSlotEx`nin (aşağıdaki `allocSlot` döngüsü İÇİNDE)
    // `VarInfo.is_stack_local`i DOĞRU okuyabilmesi İçİn `self.stack_local_
    // names` BU döngüden ÖNCE doldurulmuş OLMALIDIR — SIRA TERSİYSE
    // (`allocSlot` ÖNCE çalışırsa) bayrak HER ZAMAN `false` kalır VE
    // `releaseOneLocalIfManaged`/`.var_decl` kapsam-sonu release'i bir
    // STACK adresini `nox_rc_free_payload`e geçirip GERÇEK bir SIGBUS'a
    // yol açar (GERÇEKTEN denenip gözlemlendi, break→red→fix).
    try self.registerLocalStackSlots(fd.body);
    for (locals.items) |l| try self.allocSlot(l.name, l.info, l.is_param, l.arena);
    try self.prepareInlineSites(fd.body);
    for (fd.params) |p| {
        const info = self.vars.get(p.name).?;
        const param_text = try std.fmt.allocPrint(self.allocator, "%p_{s}", .{p.name});
        try self.qbeStore(info.qtype, param_text, info.slot);
    }
    try self.setupDeferListIfNeeded(fd.body);

    try self.genStmts(fd.body, ret_info.qtype);
    try self.drainDeferIfSet();
    try self.releaseAllLocals();

    const end_label = try self.newLabel("fn_end");
    try self.qbeLabel(end_label);
    try self.emitDefaultReturn(ret_info.qtype);
    try self.qbeFuncEnd();
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
    // Faz 7 (tekli kalıtım): `super().metod(...)`/`super().__init__(...)`in
    // (bkz. `calls.zig`nin `genSuperMethodCall`ı) BU metodun HANGİ SINIFA
    // AİT olduğunu (taban sınıfı bulmak İçin) bilmesi gerekir.
    self.current_self_class = class_name;

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
    // GG.12 (bkz. nox-teknik-spesifikasyon.md §3.66): `self.<alan>`ın
    // salt-okunur, tek-kullanım kopyalarını (ör. `local_items: list[int]
    // = self.items`) `collectLocals`in KENDİSİNE dokunmadan AYRI bir
    // geçişle işaretle — `retainIfAliasing`/`releaseOneLocalIfManaged`
    // BU bayrağı görüp gereksiz retain/release trafiğini atlar.
    try self.markBorrowedFieldLocals(&locals, m.body, m.body);

    const fn_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ class_name, m.name });
    const fn_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{fn_name});
    try self.qbeFuncHeaderStart(if (ret_info.qtype == .none) null else ret_info.qtype, fn_sym);
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%p_self", false);
    for (m.params[1..]) |p| {
        const info = try self.resolveType(p.type_expr);
        const param_text = try std.fmt.allocPrint(self.allocator, "%p_{s}", .{p.name});
        try self.qbeFuncParam(info.qtype, param_text, false);
    }
    try self.qbeFuncHeaderEnd();

    try self.registerLocalStackSlots(m.body);
    for (locals.items) |l| try self.allocSlotEx(l.name, l.info, l.is_param, l.arena, l.borrowed_field);
    try self.prepareInlineSites(m.body);
    {
        const info = self.vars.get("self").?;
        try self.qbeStoreL("%p_self", info.slot);
    }
    for (m.params[1..]) |p| {
        const info = self.vars.get(p.name).?;
        const param_text = try std.fmt.allocPrint(self.allocator, "%p_{s}", .{p.name});
        try self.qbeStore(info.qtype, param_text, info.slot);
    }
    try self.setupDeferListIfNeeded(m.body);

    try self.genStmts(m.body, ret_info.qtype);
    try self.drainDeferIfSet();
    try self.releaseAllLocals();

    const end_label = try self.newLabel("fn_end");
    try self.qbeLabel(end_label);
    try self.emitDefaultReturn(ret_info.qtype);
    try self.qbeFuncEnd();
}

pub fn genMain(self: *Codegen, stmts: []const ast.Stmt, use_async: bool, wants_multicore_pool: bool) CodegenError!void {
    if (use_async) return self.genMainAsync(stmts, wants_multicore_pool);

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
    try self.qbeFuncHeaderStart(.w, "$main");
    try self.qbeFuncParam(.w, "%argc", true);
    try self.qbeFuncParam(.l, "%argv", false);
    try self.qbeFuncHeaderEnd();
    try self.qbeCall(.{ .name = RT_PARAM, .ty = .l }, "$nox_runtime_init", &.{});
    try self.qbeCall(null, "$nox_os_init", &.{ .{ .ty = .w, .text = "%argc" }, .{ .ty = .l, .text = "%argv" } });
    // Bulundu (bkz. proje belleği "modül-seviyesi global durum" planı):
    // üst-düzey `var_decl`ların initializer'ları, KALAN gevşek deyimler
    // (`stmts`, artık modül-global `var_decl`ları HARİÇ tutar — bkz.
    // `codegen.zig`nin `loose` inşası) İŞLENMEDEN ÖNCE çalıştırılır.
    if (self.module_globals.count() > 0) {
        try self.qbeCall(null, "$nox_init_globals", &.{.{ .ty = .l, .text = RT_PARAM }});
    }
    // Not: `main`in kendi PARAMETRESİ yoktur, ama `collectLocals` artık
    // BAZI yerelleri (heap-yönetimli elemanlı bir `for`nin döngü
    // değişkeni — bkz. `collectLocals`) ödünç alınmış olarak `is_param =
    // true` ile işaretleyebiliyor; bu bilgiyi burada YOK SAYMAK
    // (eskiden olduğu gibi sabit `false`) kapsam-sonu otomatik release'i
    // yanlışlıkla tetikleyip listenin sahipliğini bozardı.
    try self.registerLocalStackSlots(stmts);
    for (locals.items) |l| try self.allocSlot(l.name, l.info, l.is_param, l.arena);
    try self.prepareInlineSites(stmts);
    try self.genStmts(stmts, .w);
    try self.releaseAllLocals();
    if (self.module_globals.count() > 0) {
        try self.qbeCall(null, "$nox_deinit_globals", &.{.{ .ty = .l, .text = RT_PARAM }});
    }
    try self.qbeCall(null, "$nox_runtime_deinit", &.{.{ .ty = .l, .text = RT_PARAM }});
    const end_label = try self.newLabel("fn_end");
    try self.qbeLabel(end_label);
    try self.qbeRet("0");
    try self.qbeFuncEnd();
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
pub fn genMainAsync(self: *Codegen, stmts: []const ast.Stmt, wants_multicore_pool: bool) CodegenError!void {
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

    try self.qbeFuncHeaderStart(.l, "$main_body");
    try self.qbeFuncParam(.l, "%argp", true);
    try self.qbeFuncHeaderEnd();
    try self.qbeLoadL(RT_PARAM, "%argp");
    try self.registerLocalStackSlots(stmts);
    for (locals.items) |l| try self.allocSlot(l.name, l.info, l.is_param, l.arena);
    try self.prepareInlineSites(stmts);
    try self.genStmts(stmts, .l);
    try self.releaseAllLocals();
    try self.qbeCall(null, "$nox_free", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = "%argp" }, .{ .ty = .l, .text = "8" } });
    const end_label = try self.newLabel("fn_end");
    try self.qbeLabel(end_label);
    try self.qbeRet("0");
    try self.qbeFuncEnd();

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
    try self.qbeFuncHeaderStart(.w, "$main");
    try self.qbeFuncParam(.w, "%argc", true);
    try self.qbeFuncParam(.l, "%argv", false);
    try self.qbeFuncHeaderEnd();
    // Faz MN.9.2: `--release` altında `$main`in KENDİSİ otomatik olarak
    // bir `WorkerPool` kurar — `nox_pool_main_init`, `$nox_runtime_init`in
    // YAPTIĞI HER ŞEYİ yapar (TEK, PAYLAŞILAN `RuntimeState`) + `$main`in
    // OS iş parçacığını slot 0'a BAĞLAR. `$nox_async_init`in ARTIK
    // DEĞİŞMESİ GEREKMEZ — `state.worker_pool` ZATEN DOLU olduğundan
    // OTOMATİK `attachToPool` çağırır (bkz. `bridge.zig`nin belge notu).
    // QBE dalı BİREBİR AYNI kalır (`self.backend == .qbe` İKEN ATOMİK
    // OLMAYAN inline ARC retain/release YÜZÜNDEN paylaşılan-havuz MN.9
    // ailesinin TAMAMI GÜVENSİZDİR — bkz. `pool_bridge.zig`nin backend
    // sınırı notu).
    if (self.backend == .llvm) {
        // Performans (bkz. proje planı, "Nox tavan hızı" bölümü, Madde 3):
        // `wants_multicore_pool` — modül `serve_multicore*`/`pool_run`
        // HİÇ ÇAĞIRMIYORSA (`moduleUsesMulticorePool`, `async_thread.zig`)
        // `pickMainWorkerCount` CPU-sayısı YERİNE küçük bir sabite düşer
        // (bkz. `pool_bridge.zig`nin belge notu, BURADA SADECE derleme-
        // zamanı sinyali `.w`-tipli 0/1 olarak TAŞINIR).
        const wmp_text: []const u8 = if (wants_multicore_pool) "1" else "0";
        try self.qbeCall(.{ .name = RT_PARAM, .ty = .l }, "$nox_pool_main_init", &.{.{ .ty = .w, .text = wmp_text }});
    } else {
        try self.qbeCall(.{ .name = RT_PARAM, .ty = .l }, "$nox_runtime_init", &.{});
    }
    try self.qbeCall(null, "$nox_os_init", &.{ .{ .ty = .w, .text = "%argc" }, .{ .ty = .l, .text = "%argv" } });
    try self.qbeCall(null, "$nox_async_init", &.{.{ .ty = .l, .text = RT_PARAM }});
    // Bulundu (bkz. proje belleği "modül-seviyesi global durum" planı):
    // `$main_body`nin GERÇEK üst-düzey deyimleri (bkz. `genStmts` çağrısı
    // YUKARIDA) çalıştırılmadan ÖNCE — `$main_body` BİR GÖREV olarak
    // spawn edilir, bu YÜZDEN init BURADA (spawn'DAN ÖNCE), `$main_body`nin
    // KENDİSİNDE DEĞİL. `--release` altında BU, driver'ın (slot 0'ın)
    // KENDİ globals'ıdır — MN.8'in `pool_run` düzeltmesiyle AYNI "doğrudan,
    // koşulsuz, run()'dan bağımsız" desen (entry_task'ın ÇALINABİLİRLİĞİNDEN
    // TAMAMEN BAĞIMSIZ, ÇÜNKÜ BURADA HİÇ bir fiber'ın GÖVDESİNE GÖMÜLÜ
    // DEĞİL — düz, sıralı `$main` kodu).
    if (self.module_globals.count() > 0) {
        try self.qbeCall(null, "$nox_init_globals", &.{.{ .ty = .l, .text = RT_PARAM }});
    }
    const closure_t = try self.newTemp();
    try self.qbeCall(.{ .name = closure_t, .ty = .l }, "$nox_alloc", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = "8" } });
    try self.qbeStoreL(RT_PARAM, closure_t);
    const task_t = try self.newTemp();
    try self.qbeCall(.{ .name = task_t, .ty = .l }, "$nox_async_spawn", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = "$main_body" }, .{ .ty = .l, .text = closure_t } });
    // Faz MN.9.2: kardeş worker'lar `$main_body` GÖREVİ spawn EDİLDİKTEN
    // HEMEN SONRA başlatılır — MN.8'in KENDİ, KANITLANMIŞ sıralama
    // düzeltmesiyle TUTARLI (entry görevi HER ZAMAN kardeşler BAŞLAMADAN
    // ÖNCE spawn EDİLMELİDİR, AKSİ HALDE `pool_live_count==0` GÖREN bir
    // kardeş HEMEN döner VE o görevi SONSUZA KADAR kaçırabilir).
    var main_ginit_name: ?[]const u8 = null;
    var main_gdeinit_name: ?[]const u8 = null;
    if (self.backend == .llvm) {
        var ginit_sym: []const u8 = "0";
        var gdeinit_sym: []const u8 = "0";
        if (self.module_globals.count() > 0) {
            main_ginit_name = try std.fmt.allocPrint(self.allocator, "main_pool_ginit", .{});
            main_gdeinit_name = try std.fmt.allocPrint(self.allocator, "main_pool_gdeinit", .{});
            ginit_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{main_ginit_name.?});
            gdeinit_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{main_gdeinit_name.?});
        }
        try self.qbeCall(null, "$nox_pool_main_spawn_workers", &.{
            .{ .ty = .l, .text = RT_PARAM },
            .{ .ty = .l, .text = ginit_sym },
            .{ .ty = .l, .text = gdeinit_sym },
        });
    }
    const run_result_t = try self.newTemp();
    try self.qbeCall(.{ .name = run_result_t, .ty = .w }, "$nox_async_run_to_completion", &.{.{ .ty = .l, .text = RT_PARAM }});
    const deadlock_label = try self.newLabel("deadlock");
    const ok_label = try self.newLabel("no_deadlock");
    try self.qbeJnz(run_result_t, deadlock_label, ok_label);
    try self.qbeLabel(deadlock_label);
    try self.qbeCall(null, "$nox_async_deadlock_abort", &.{.{ .ty = .l, .text = RT_PARAM }});
    try self.qbeRet("0"); // erişilemez — savunmacı (bkz. `emitExceptionCheck`in AYNI deseni)
    try self.qbeLabel(ok_label);
    try self.qbeCall(null, "$nox_async_destroy_task", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = task_t } });
    try self.qbeCall(null, "$nox_async_deinit", &.{.{ .ty = .l, .text = RT_PARAM }});
    if (self.module_globals.count() > 0) {
        try self.qbeCall(null, "$nox_deinit_globals", &.{.{ .ty = .l, .text = RT_PARAM }});
    }
    if (self.backend == .llvm) {
        try self.qbeCall(null, "$nox_pool_main_join_and_destroy", &.{.{ .ty = .l, .text = RT_PARAM }});
    } else {
        try self.qbeCall(null, "$nox_runtime_deinit", &.{.{ .ty = .l, .text = RT_PARAM }});
    }
    try self.qbeRet("0");
    try self.qbeFuncEnd();

    // Faz MN.9.2: kardeş worker'ların KENDİ slotu İçİn modül-global
    // ilklendirme/temizleme sarmalayıcıları — `$main`nin KENDİ `qbeFuncEnd`ı
    // SONRASI (YENİ, BAĞIMSIZ fonksiyonlar), SADECE kaydedildilerse
    // (`module_globals.count() > 0`) üretilir — MN.8'in `pool_run_wrappers`
    // TÜKETİM DÖNGÜSÜNÜN (`codegen.zig`) AYNI desenini BURADA DOĞRUDAN
    // (TEMBEL bir kuyruk GEREKMEDEN, `genMainAsync` ZATEN TEK SEFERLİK VE
    // İYİ-TANIMLI bir noktada çağrıldığından) uygular.
    if (main_ginit_name) |n| try self.genPoolRunGlobalsInitWrapper(n);
    if (main_gdeinit_name) |n| try self.genPoolRunGlobalsDeinitWrapper(n);
}
