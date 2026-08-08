//! ARC (retain/release/predecrement) çekirdeği — bkz. plan dosyası "QBE
//! codegen backend'ini alt modüllere bölme". Kapsam-sonu temizliği
//! (`release*`), inline retain/predecrement (performans fazının çekirdek
//! optimizasyonu), Task/Channel/ThreadHandle/ThreadChannel'ın ARC-DIŞI
//! yıkımı (`destroyNonArc*`) VE takma-ad (aliasing) analizi
//! (`retainIfAliasing`/`returnNeedsRetain`) burada toplanır.

const std = @import("std");
const ast = @import("../parser/ast.zig");
const types = @import("types.zig");
const abi = @import("abi.zig");
const codegen = @import("codegen.zig");

const Codegen = codegen.Codegen;
const QbeType = types.QbeType;
const HeapKind = types.HeapKind;
const ElemHeapInfo = types.ElemHeapInfo;
const DictInfo = types.DictInfo;
const Value = types.Value;
const VarInfo = types.VarInfo;
const RT_PARAM = types.RT_PARAM;
const LIST_HEADER_SIZE = types.LIST_HEADER_SIZE;
const ARC_HEADER_SIZE = types.ARC_HEADER_SIZE;
const CLOSURE_RELEASE_FN_PTR_OFFSET = types.CLOSURE_RELEASE_FN_PTR_OFFSET;
const CodegenError = abi.CodegenError;
const qbeTypeName = abi.qbeTypeName;
const qbeSizeOf = abi.qbeSizeOf;
const isHeapManaged = abi.isHeapManaged;
const isTemporaryExpr = abi.isTemporaryExpr;

/// Bu fonksiyonun/main'in TÜM heap tipli YEREL (parametre olmayan)
/// değişkenlerini serbest bırakır (slotta ne varsa — sıfır/null dahil,
/// güvenle atlanır). Kapsam sonu için çağrılır. Bilinen sınırlama: erken
/// `return` noktalarında bu temizlik ÇALIŞMAZ (bkz. modül üstü not).
pub fn releaseAllLocals(self: *Codegen) CodegenError!void {
    try self.releaseAllLocalsExcept(null);
}

/// `releaseAllLocals` ile aynıdır, yalnızca `except_name` adlı yerel hariç
/// (varsa) — `return <isim>` bir "taşıma"dır: döndürülen bağlamanın kendi
/// slotu serbest bırakılmaz (aksi hâlde döndürülen değer serbest
/// bırakılmış bir belleğe işaret ederdi), ama AYNI kapsamdaki DİĞER heap
/// tipli yereller (bkz. bilinen sınırlama — artık yalnızca `return`'ün
/// KENDİ değeri için değil, `except ... as` ile yakalanan nesneler gibi
/// diğer yereller için de doğru serbest bırakılıyor) hâlâ serbest bırakılır.
pub fn releaseAllLocalsExcept(self: *Codegen, except_name: ?[]const u8) CodegenError!void {
    var it = self.vars.iterator();
    while (it.next()) |entry| {
        if (except_name) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) continue;
        }
        try self.releaseOneLocalIfManaged(entry.value_ptr.*);
    }
}

/// `releaseAllLocalsExcept`in TEK bir `VarInfo` GİRİŞİ İçin çalıştırdığı
/// çekirdek — Faz GG.2 (bkz. nox-teknik-spesifikasyon.md §3.67) İçin
/// `releaseNamedLocalsExcept`nin de YENİDEN KULLANABİLMESİ İçin
/// ÇIKARILDI (basit kod-taşıma, davranış DEĞİŞMEDİ).
pub fn releaseOneLocalIfManaged(self: *Codegen, entry: VarInfo) CodegenError!void {
    // Arena tipli bağlamalar hiçbir zaman bireysel release edilmez —
    // refcount başlıkları yoktur, yaşam süreleri yalnızca kendi
    // `lowlevel` bloğunun `nox_arena_destroy`'una bağlıdır.
    if (entry.is_param or entry.arena or entry.borrowed_field) return;
    if (isHeapManaged(entry.heap)) {
        try self.releaseSlotIfSet(entry);
    } else if (entry.heap == .task or entry.heap == .channel or entry.heap == .thread_handle or entry.heap == .thread_channel or entry.heap == .task_local) {
        // `Task[T]`/`Channel[T]`/`ThreadHandle[T]`/`ThreadChannel[T]`
        // ARC-yönetimli DEĞİLDİR (bkz. `HeapKind`in belge notu,
        // `dict[K,V]`in AKSİNE — bkz. Faz FF.3) — `destroyNonArcSlotIfSet`
        // (bkz. onun belge notu) DOĞRUDAN bir kez yıkar. Faz S.1'den
        // beri BU AYNI yol yeniden atamada da (`genAssign`) kullanılır
        // — artık ne kapsam sonunda ne de yeniden atamada eski değer
        // sızmaz.
        try self.destroyNonArcSlotIfSet(entry);
    }
}

/// Faz GG.2: `releaseAllLocalsExcept`in AYNISI, ama TÜM `self.vars`
/// YERİNE yalnızca `names`teki (BİR inline-splice sitesinin KENDİ
/// parametre+yerelleri) isimler İçin — inline edilen bir `return_stmt`
/// (bkz. `genStmts`in `.return_stmt` dalı) caller'ın DİĞER yerellerine
/// ASLA dokunmamalıdır, yalnızca callee'nin KENDİ kapsamını KAPATIR.
///
/// **Faz NN (Faz JJ'nin "identifier ile taşınan" varyantı — GERÇEK bir
/// çift-serbest-bırakma, `make_list() -> list[T]` gibi bir fonksiyonun
/// `return xs` İLE (çıplak identifier) bir `while` döngüsü İçİNDE inline
/// edilip TEKRAR TEKRAR çağrıldığı senaryoda bir .ssa dökümüyle KANITLANDI):**
/// `except_name` eşleşen dalda (değer sahipliği ARAYANA TAŞINDIĞI İçin
/// serbest bırakma ÇAĞRILMAZ) ÖNCEDEN slot HİÇ sıfırlanmıyordu. Bu, Faz
/// JJ'nin `releaseSlotIfSet`de düzelttiği AYNI kök nedenin (inline edilmiş
/// bir çağrı sitesinin kalıcı slotu döngü yinelemeleri ARASI YENİDEN
/// KULLANILIR) "gerçekten serbest bırakılan" DEĞİL "arayana taşınan" varyantı
/// içindi: bir SONRAKİ yinelemede callee'nin KENDİ `var_decl`i (ör. `xs:
/// list[int] = [...]`), "üzerine yazmadan ÖNCE eskiyi serbest bırak"
/// mantığında (bkz. `stmt.zig`'in `.var_decl` dalı) BU AYNI (artık ARAYANA
/// ait, muhtemelen ZATEN serbest bırakılmış) işaretçiyi HÂLÂ "canlı" SANIP
/// TEKRAR serbest bırakıyordu — GERÇEK çift serbest bırakma. Düzeltme:
/// `releaseSlotIfSet`nin YAPTIĞI AYNI sıfırlamayı (serbest bırakma ÇAĞRISI
/// OLMADAN) burada da uygula. Parametreler (`is_param`) İçin GEREK YOK —
/// `genInlinedCall`in argüman-geçirme adımı (bkz. `inlining.zig`) parametre
/// slotlarını HER yinelemede KOŞULSUZ (release-before-overwrite OLMADAN)
/// ÜZERİNE YAZAR, bu YÜZDEN param slotlarında STALE bir "taşınmış" işaretçi
/// ZARARSIZDIR (hiçbir kod ONU okuyup serbest bırakmaya ÇALIŞMAZ).
pub fn releaseNamedLocalsExcept(self: *Codegen, names: []const []const u8, except_name: ?[]const u8) CodegenError!void {
    for (names) |name| {
        const entry = self.vars.get(name) orelse continue;
        if (except_name) |en| {
            if (std.mem.eql(u8, name, en)) {
                if (!entry.is_param and !entry.arena and isHeapManaged(entry.heap)) {
                    try self.qbeStoreImmL(0, entry.slot);
                }
                continue;
            }
        }
        try self.releaseOneLocalIfManaged(entry);
    }
}

/// Yalnızca `list[T]` için: boyut çalışma zamanında `cap` alanından
/// (Faz U.1'den beri `@8` — ÖNCEDEN `len`den, `@0`, hesaplanıyordu,
/// AMA `.append()`in GERÇEK büyümesi sonrası GERÇEKTEN TAHSİS EDİLMİŞ
/// bayt sayısı `cap`e karşılık gelir, `len`e DEĞİL — bkz. `LIST_HEADER_
/// SIZE`in belge notu) hesaplanır (sınıflar için artık `genClassRelease`'in
/// ürettiği `$ClassName_release` kullanılır — `total_size` derleme
/// zamanında zaten sabittir, bu yol üzerinden hesaplanmaya gerek yoktur).
pub fn listPayloadSize(self: *Codegen, ptr: []const u8, elem_qtype: QbeType) CodegenError![]const u8 {
    const cap_addr = try self.newTemp();
    try self.qbeOp2Imm(cap_addr, .l, "add", ptr, 8);
    const cap_t = try self.newTemp();
    try self.qbeLoadL(cap_t, cap_addr);
    const size_t = try self.newTemp();
    try self.qbeOp2Imm(size_t, .l, "mul", cap_t, @intCast(qbeSizeOf(elem_qtype)));
    const total_t = try self.newTemp();
    try self.qbeOp2Imm(total_t, .l, "add", size_t, @intCast(LIST_HEADER_SIZE));
    return total_t;
}

/// `info`nin betimlediği TEK bir DEĞERİ (bir sınıf örneği ya da bir
/// `list[T]`nin KENDİSİ) serbest bırakacak `$<isim>_release(rt, p)`
/// fonksiyonunun ismini (baştaki `$` OLMADAN) döner.
///   - `info.heap == .class`: doğrudan sınıf adı (`genClassRelease`
///     tarafından ZATEN üretilmiştir, burada YENİ bir şey kaydedilmez).
///   - `info.heap == .list`: `p`nin KENDİSİ bir listedir; `info.elem_qtype`/
///     `info.nested` BU listenin KENDİ elemanlarını betimler (bkz. modül
///     üstü not, "Faz 21 ön-koşulu"). Gereken `$List_<mangled>_release`i
///     TEMBEL olarak kaydeder (henüz üretilmemişse `list_release_queue`ya
///     ekler — gerçek üretim `generateModule`nin sonunda, `string_data`
///     gibi drenaj yoluyla olur, bkz. `genListElemRelease`).
/// **Dikkat — iki farklı "elemanları betimleme" düzeyi:** bu fonksiyona
/// verilen `info`, RELEASE EDİLECEK DEĞERİN KENDİSİNİ betimler (`info.heap`
/// o değerin KENDİ heap türüdür) — `Value`/`VarInfo.elem_heap_info` gibi
/// "BİR listenin İÇİNDEKİ elemanların türü" alanlarıyla KARIŞTIRILMAMALI;
/// çağıran taraf (bkz. `releaseValueIfSet`) bu ikisini birbirine
/// dönüştürmekle sorumludur.
pub fn releaseFnNameFor(self: *Codegen, info: ElemHeapInfo) CodegenError![]const u8 {
    switch (info.heap) {
        .class => return info.class_name.?,
        // Yalnızca DIŞ `$List_str_release` sembolünün adını üretmek için
        // bir "etiket" — GERÇEK release ÇAĞRISI `nox_str_release`e gider
        // (`$str_release` diye bir sembol YOK) — bkz. `genListElemRelease`in
        // `info.nested` dalındaki ÖZEL durum.
        .str => return "str",
        // Faz U.4.5: `.str` İLE AYNI desen — yalnızca DIŞ `$List_closure_
        // release` sembolünün adını üretmek İçin bir "etiket". GERÇEK
        // eleman release'i BURADAN farklı olarak SABİT bir `$<isim>_
        // release` çağrısı OLAMAZ (AYNI listedeki İKİ closure FARKLI
        // somut release fonksiyonlarına sahip OLABİLİR, ör. bir trampoline
        // İLE gerçek bir iç içe `def`) — bu YÜZDEN `genListElemRelease`
        // `.closure` İçin dinamik dispatch'e (elemanın KENDİ offset-8'i,
        // `releaseValueIfSet`nin `.closure` dalıYLA AYNI desen) AYRICA
        // özel durum uygular.
        .closure => return "closure",
        // Bulundu (nyx framework — bkz. proje belleği "NOX_LIMITATIONS.md
        // incelemesi", C1): `.str`/`.closure` İLE AYNI "yalnızca etiket"
        // deseni — GERÇEK eleman release'i `$dict_release` diye bir sembol
        // ÜZERİNDEN DEĞİL, DOĞRUDAN `nox_dict_release(rt, ptr, key_is_str,
        // value_is_str)` çağrısıyla (bkz. `releaseValueIfSet`nin `.dict`
        // dalıYLA AYNI desen) — `genListElemRelease` bunu `info.dict_info`den
        // okuyarak ÖZEL durum uygular.
        .dict => return "dict",
        .list => {
            const inner_tag = if (info.nested) |n|
                try self.releaseFnNameFor(n.*)
            else
                try std.fmt.allocPrint(self.allocator, "prim{s}", .{qbeTypeName(info.elem_qtype)});
            const name = try std.fmt.allocPrint(self.allocator, "List_{s}", .{inner_tag});
            if (!self.list_release_seen.contains(name)) {
                try self.list_release_seen.put(self.allocator, name, {});
                try self.list_release_queue.append(self.allocator, .{ .name = name, .info = info });
            }
            return name;
        },
        else => return error.Unsupported,
    }
}

/// `fn_name`/`info` = `releaseFnNameFor`den gelen kayıt (`info.heap`
/// HER ZAMAN `.list`dir — `.class` değerler zaten `genClassRelease`
/// tarafından üretilir, bu kuyruğa hiç girmez). `genClassRelease` ile
/// AYNI şekilde refcount'u azaltır (`nox_rc_predecrement`); sıfıra
/// düştüyse:
///   - `info.nested == null` (BU listenin elemanları primitive/str):
///     hiçbir eleman release'i GEREKMEZ — doğrudan (genel `nox_rc_release`
///     ile AYNI hesapla) belleği serbest bırakır.
///   - `info.nested != null` (elemanları heap-yönetimli): `genForList`deki
///     AYNI güvenli döngü deseniyle (indeks sayacı FONKSİYON GİRİŞİNDE bir
///     kez `alloc8` — bu fonksiyon başına TEK sefer çalışır, döngü
///     YİNELEMESİ başına değil, bu yüzden Faz 16'da bulunan alloc-döngü-
///     içi yığın taşması hatasına yol AÇMAZ) her elemanı (null değilse)
///     `$<releaseFnNameFor(info.nested.*)>_release` ile özyinelemeli
///     olarak serbest bırakır — SONRA belleği gerçekten serbest bırakır.
pub fn genListElemRelease(self: *Codegen, fn_name: []const u8, info: ElemHeapInfo) CodegenError!void {
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

    const release_sym = try std.fmt.allocPrint(self.allocator, "${s}_release", .{fn_name});
    try self.qbeFuncHeaderStart(null, release_sym);
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%p", false);
    try self.qbeFuncHeaderEnd();
    const should_free = try self.emitInlinePredecrement("%p", .list);
    const free_label = try self.newLabel("list_release_free");
    const done_label = try self.newLabel("list_release_done");
    try self.qbeJnz(should_free, free_label, done_label);
    try self.qbeLabel(free_label);

    const len_t = try self.newTemp();
    try self.qbeLoadL(len_t, "%p");
    // Faz U.1: gerçek TAHSİS EDİLMİŞ boyut `cap`e (@8) karşılık gelir,
    // `len`e (@0) DEĞİL — `len`, ELEMAN döngüsünün SINIRI olarak KALIR
    // (yalnızca GEÇERLİ elemanlar release edilmeli), ama belleği
    // serbest bırakırken `cap` KULLANILMALIDIR (aksi halde `.append()`in
    // büyüttüğü bir liste, ONA AYRILAN gerçek bloktan DAHA KÜÇÜK bir
    // boyutla serbest bırakılır — havuzun serbest-liste sınıf indeksini
    // BOZAR, bkz. `arc.zig`nin `nox_rc_free_payload` notu).
    const cap_addr = try self.newTemp();
    try self.qbeOp2Imm(cap_addr, .l, "add", "%p", 8);
    const cap_t = try self.newTemp();
    try self.qbeLoadL(cap_t, cap_addr);

    if (info.nested) |n| {
        // Faz U.4.5: `.closure` elemanları HİÇBİR ZAMAN sabit bir `$<isim>_
        // release` çağrısı ile serbest BIRAKILAMAZ (bkz. `releaseFnNameFor`nin
        // `.closure` dalının belge notu) — bu YÜZDEN `callee` BURADA
        // `null` bırakılır (`.str`in KENDİ "özel durum" desenine BENZER),
        // ama aşağıdaki ÇAĞRI SİTESİ (`if (n.heap == .closure)`) BUNU
        // `nox_str_release` YERİNE dinamik dispatch'e YÖNLENDİRİR.
        // Bulundu (nyx framework — bkz. proje belleği "NOX_LIMITATIONS.md
        // incelemesi", C1): `.dict` de AYNI "özel durum" listesine eklendi
        // — `nox_dict_release` sabit bir `$<isim>_release` sembolü DEĞİL,
        // `key_is_str`/`value_is_str` argümanları GEREKTİREN doğrudan bir
        // çağrı (bkz. aşağıdaki `if (n.heap == .dict)` dalı).
        const callee: ?[]const u8 = if (n.heap == .str or n.heap == .closure or n.heap == .dict) null else try self.releaseFnNameFor(n.*);
        const idx_slot = try self.newTemp();
        try self.qbeAlloc(idx_slot, .eight, 8);
        try self.qbeStoreImmL(0, idx_slot);

        const cond_label = try self.newLabel("list_release_cond");
        const body_label = try self.newLabel("list_release_body");
        const loopend_label = try self.newLabel("list_release_loopend");
        const skip_label = try self.newLabel("list_release_skip");
        const rel_label = try self.newLabel("list_release_elem");

        try self.qbeJmp(cond_label);
        try self.qbeLabel(cond_label);
        const idx_cur = try self.newTemp();
        try self.qbeLoadL(idx_cur, idx_slot);
        const cont = try self.newTemp();
        try self.qbeOp2(cont, .w, "csltl", idx_cur, len_t);
        try self.qbeJnz(cont, body_label, loopend_label);
        try self.qbeLabel(body_label);

        const off = try self.newTemp();
        try self.qbeOp2Imm(off, .l, "mul", idx_cur, 8);
        const off8 = try self.newTemp();
        try self.qbeOp2Imm(off8, .l, "add", off, @intCast(LIST_HEADER_SIZE));
        const addr = try self.newTemp();
        try self.qbeOp2(addr, .l, "add", "%p", off8);
        const elem = try self.newTemp();
        try self.qbeLoadL(elem, addr);
        const is_null = try self.newTemp();
        try self.qbeOp2Imm(is_null, .w, "ceql", elem, 0);
        try self.qbeJnz(is_null, skip_label, rel_label);
        try self.qbeLabel(rel_label);
        if (callee) |c| {
            // Faz 7 (tekli kalıtım): `releaseValueIfSet`in AYNI gerekçesi —
            // `n.class_name` (BU listenin STATİK eleman sınıfı) kalıtıma
            // KATILIYORSA, ÇALIŞMA ZAMANI elemanı bir alt sınıf OLABİLİR
            // (fazladan alanlarla) — sabit `$c_release` yerine ÇALIŞMA-
            // ZAMANI etiket-dağıtımına gidilir.
            const dispatch_dynamic = if (n.heap == .class) blk: {
                const ci = self.classes.get(c) orelse break :blk false;
                break :blk ci.has_vtable;
            } else false;
            if (dispatch_dynamic) {
                const tag = try self.newTemp();
                try self.qbeLoadL(tag, elem);
                try self.qbeCall(null, "$nox_class_release_dispatch", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = tag }, .{ .ty = .l, .text = elem } });
            } else {
                const c_sym = try std.fmt.allocPrint(self.allocator, "${s}_release", .{c});
                try self.qbeCall(null, c_sym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = elem } });
            }
        } else if (n.heap == .closure) {
            // Faz U.4.5: `releaseValueIfSet`nin `.closure` dalıYLA AYNI
            // dinamik dispatch (bkz. onun belge notu) — elemanın KENDİ
            // offset-8'indeki release fonksiyon işaretçisi ÜZERİNDEN.
            const rel_addr = try self.newTemp();
            try self.qbeOp2Imm(rel_addr, .l, "add", elem, @intCast(CLOSURE_RELEASE_FN_PTR_OFFSET));
            const rel_fn = try self.newTemp();
            try self.qbeLoadL(rel_fn, rel_addr);
            try self.qbeCall(null, rel_fn, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = elem } });
        } else if (n.heap == .dict) {
            // Bulundu (nyx framework — bkz. proje belleği "NOX_LIMITATIONS.md
            // incelemesi", C1): `releaseValueIfSet`nin `.dict` dalıYLA AYNI
            // çağrı deseni — `nox_dict_release`nin KENDİSİ predecrement'e
            // göre koşullu serbest bırakır, burada EK bir `jnz`/`should_free`
            // sarmalayıcı GEREKMEZ.
            const dinfo = n.dict_info.?;
            const key_is_str_lit: []const u8 = if (dinfo.key_is_str) "1" else "0";
            const value_is_str_lit: []const u8 = if (dinfo.value_is_str) "1" else "0";
            const value_is_class_lit: []const u8 = if (dinfo.value_is_class) "1" else "0";
            try self.qbeCall(null, "$nox_dict_release", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = elem }, .{ .ty = .w, .text = key_is_str_lit }, .{ .ty = .w, .text = value_is_str_lit }, .{ .ty = .w, .text = value_is_class_lit } });
        } else {
            try self.qbeCall(null, "$nox_str_release", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = elem } });
        }
        try self.qbeJmp(skip_label);
        try self.qbeLabel(skip_label);
        const idx_next = try self.newTemp();
        try self.qbeOp2Imm(idx_next, .l, "add", idx_cur, 1);
        try self.qbeStoreL(idx_next, idx_slot);
        try self.qbeJmp(cond_label);
        try self.qbeLabel(loopend_label);

        const size_t = try self.newTemp();
        try self.qbeOp2Imm(size_t, .l, "mul", cap_t, 8);
        const total_t = try self.newTemp();
        try self.qbeOp2Imm(total_t, .l, "add", size_t, @intCast(LIST_HEADER_SIZE));
        try self.qbeCall(null, "$nox_rc_free_payload", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = "%p" }, .{ .ty = .l, .text = total_t } });
    } else {
        const size_t = try self.newTemp();
        try self.qbeOp2Imm(size_t, .l, "mul", cap_t, @intCast(qbeSizeOf(info.elem_qtype)));
        const total_t = try self.newTemp();
        try self.qbeOp2Imm(total_t, .l, "add", size_t, @intCast(LIST_HEADER_SIZE));
        try self.qbeCall(null, "$nox_rc_free_payload", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = "%p" }, .{ .ty = .l, .text = total_t } });
    }
    try self.qbeJmp(done_label);
    try self.qbeLabel(done_label);
    try self.qbeRet(null);
    try self.qbeFuncEnd();
}

/// `ptr` içindeki değer null değilse serbest bırakır: sınıf örnekleri
/// üretilmiş `$ClassName_release`'e (iç içe alanları özyinelemeli olarak
/// serbest bırakır), primitif elemanlı `list[T]` genel `nox_rc_release`'e,
/// heap-yönetimli elemanlı `list[T]` (`elem_heap_info != null`) ise
/// üretilmiş `$List_<...>_release`'e (elemanları ÖNCE özyinelemeli olarak
/// serbest bırakır — bkz. `genListElemRelease`) gider. `dict` (Faz FF.3,
/// bkz. nox-teknik-spesifikasyon.md §3.62) `nox_dict_release`e gider —
/// `dict_info` (`.dict` DIŞINDAKİ tüm türler İçin `null` GEÇİRİLEBİLİR)
/// bu YOLUN İhtiyacı olan `key_is_str`/`value_is_str` bayraklarını taşır.
/// Hem yerel değişken kapsam-sonu temizliğinde (`releaseSlotIfSet`) hem
/// de bir sınıf alanının üzerine yazılırken eski değeri serbest bırakmak
/// için (`genAssign`, `.attribute` durumu) kullanılan tek ortak yoldur.
pub fn releaseValueIfSet(self: *Codegen, ptr: []const u8, heap: HeapKind, elem_qtype: QbeType, class_name: ?[]const u8, elem_heap_info: ?*const ElemHeapInfo, dict_info: ?*const DictInfo) CodegenError!void {
    const is_null = try self.newTemp();
    try self.qbeOp2Imm(is_null, .w, "ceql", ptr, 0);
    const release_label = try self.newLabel("release");
    const skip_label = try self.newLabel("release_skip");
    const done_label = try self.newLabel("release_done");
    try self.qbeJnz(is_null, skip_label, release_label);
    try self.qbeLabel(release_label);
    if (heap == .class) {
        const cn = class_name.?;
        // Faz 7 (tekli kalıtım): `cn` (bu SLOT'un STATİK/bildirilen sınıfı)
        // kalıtıma KATILIYORSA, ÇALIŞMA ZAMANI nesnesi `cn`nin bir alt
        // sınıfı OLABİLİR — o alt sınıf `cn`nin SAHİP OLMADIĞI EK alanlar
        // TAŞIYOR olabileceğinden, sabit `$cn_release` çağrısı SADECE
        // `cn`nin KENDİ (miras alınan) alanlarını serbest bırakır, alt
        // sınıfın EK alanlarını SESSİZCE ATLAR (GERÇEK bir sızıntı —
        // bellek BOZULMAZ, `nox_rc_free_payload` YİNE de TÜM payload'ı
        // serbest bırakır, ama alt sınıfın EK alanlarının KENDİ İÇ
        // referansları hiç serbest bırakılmaz). Düzeltme: bare `except:`in
        // ZATEN kullandığı AYNI ÇALIŞMA-ZAMANI etiket-dağıtımı
        // (`$nox_class_release_dispatch`, bkz. `layout.zig`nin
        // `genClassReleaseDispatch`ı) — nesnenin KENDİ tag'i OKUNUP DOĞRU
        // (GERÇEK, çalışma-zamanı) sınıfın `_release`ine dal açılır.
        // Kalıtıma KATILMAYAN sınıflar İçin (`has_vtable == false`, BÜYÜK
        // ÇOĞUNLUK) davranış BİREBİR ÖNCEKİ GİBİ (sabit çağrı) kalır.
        if (self.classes.get(cn)) |cinfo| {
            if (cinfo.has_vtable) {
                const tag = try self.newTemp();
                try self.qbeLoadL(tag, ptr);
                try self.qbeCall(null, "$nox_class_release_dispatch", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = tag }, .{ .ty = .l, .text = ptr } });
            } else {
                const cn_sym = try std.fmt.allocPrint(self.allocator, "${s}_release", .{cn});
                try self.qbeCall(null, cn_sym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ptr } });
            }
        } else {
            const cn_sym = try std.fmt.allocPrint(self.allocator, "${s}_release", .{cn});
            try self.qbeCall(null, cn_sym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ptr } });
        }
    } else if (heap == .closure) {
        // Faz U.4.4: bir `.closure` değerinin SOMUT release fonksiyonu
        // ARTIK `class_name` (statik/isim-tabanlı dispatch) ÜZERİNDEN
        // DEĞİL, bloğun KENDİSİNİN offset 8'inde TAŞIDIĞI `release_fn_ptr`
        // ÜZERİNDEN DOLAYLI olarak çağrılır (bkz. `HeapKind.closure`in
        // belge notu, "küçük vtable") — bu, bir func-tipli DEĞİŞKENİN/
        // DÖNÜŞÜN çıplak tip ANNOTASYONUNDAN (`class_name` HER ZAMAN
        // `null`dır, çünkü `Type.func` YAPISAL/polimorfiktir) SOMUT
        // closure'ın kimliği ÇIKARILAMASA BİLE (`class`ın AKSİNE) DOĞRU
        // release fonksiyonuna ulaşılabilmesini sağlar — U.4.3'ün
        // panik-yerine-güvenli-hata geçici çözümünü GEREKSİZ kılar.
        const rel_addr = try self.newTemp();
        try self.qbeOp2Imm(rel_addr, .l, "add", ptr, @intCast(CLOSURE_RELEASE_FN_PTR_OFFSET));
        const rel_fn = try self.newTemp();
        try self.qbeLoadL(rel_fn, rel_addr);
        try self.qbeCall(null, rel_fn, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ptr } });
    } else if (heap == .str) {
        // Faz GG.1 (bkz. nox-teknik-spesifikasyon.md — performans fazı):
        // predecrement adımı `emitInlinePredecrement` İLE (class/list
        // release fonksiyonlarının ZATEN yaptığı AYNI desen) DOĞRUDAN
        // QBE IR'ına inline edilir — `nox_str_release`in TAMAMINI HER
        // release'de ÇAĞIRMAK YERİNE (ki bu, HER PINNED/literal dizenin
        // BİLE — asla gerçekten serbest bırakılmasalar da — tam bir
        // fonksiyon çağrısı+prologue/epilogue ödemesi anlamına
        // geliyordu — `string_passing` benchmark'ında ÖLÇÜLEN Go/Rust'a
        // 7-11x kayıp bulgusunun BİRİNCİL kaynağı, bkz. GG.1 notu).
        // `str`nin boyutu (`list[T]`nin AKSİNE) başlıkta SAKLANMAZ (bkz.
        // `runtime/str.zig`in modül üstü notu) — bu yüzden yalnızca
        // GERÇEKTEN sıfıra/altına düştüğünde (NADİR yol) `strlen`+gerçek
        // serbest bırakma İçin `nox_str_free_now`ya (predecrement'siz
        // hafif sürüm) düşülür.
        const should_free = try self.emitInlinePredecrement(ptr, .str);
        const free_label = try self.newLabel("str_free");
        const skip_free_label = try self.newLabel("str_free_skip");
        const free_done_label = try self.newLabel("str_free_done");
        try self.qbeJnz(should_free, free_label, skip_free_label);
        try self.qbeLabel(free_label);
        try self.qbeCall(null, "$nox_str_free_now", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ptr } });
        try self.qbeJmp(free_done_label);
        try self.qbeLabel(skip_free_label);
        try self.qbeJmp(free_done_label);
        try self.qbeLabel(free_done_label);
    } else if (heap == .dict) {
        // Faz FF.3 (bkz. nox-teknik-spesifikasyon.md §3.62): `dict`
        // ARTIK `str` İLE AYNI "predecrement'e göre koşullu release"
        // desenini izler — `nox_dict_release`nin KENDİSİ `nox_rc_
        // predecrement` çağırır (bkz. `dict.zig`).
        const dinfo = dict_info.?;
        const key_is_str_lit: []const u8 = if (dinfo.key_is_str) "1" else "0";
        const value_is_str_lit: []const u8 = if (dinfo.value_is_str) "1" else "0";
        const value_is_class_lit: []const u8 = if (dinfo.value_is_class) "1" else "0";
        try self.qbeCall(null, "$nox_dict_release", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ptr }, .{ .ty = .w, .text = key_is_str_lit }, .{ .ty = .w, .text = value_is_str_lit }, .{ .ty = .w, .text = value_is_class_lit } });
    } else if (heap == .boxed_scalar) {
        // Faz FF.6.4 (bkz. nox-teknik-spesifikasyon.md §3.65): kutu,
        // `nox_rc_alloc(rt, 8)`den gelen DÜZ 8 baytlık bir skaler
        // payload'dır — `list`in len/cap BAŞLIĞI, `class`ın tag'ı YOK,
        // İÇİNDE nested bir heap referansı ASLA yok (ham int/float/bool)
        // — bu yüzden `listPayloadSize`in list-başlığı VARSAYAN genel
        // dalına (aşağı) DEĞİL, doğrudan sabit boyutlu bir `nox_rc_
        // release`e gider. **KRİTİK:** `nox_rc_free_payload` DEĞİL —
        // O, refcount'u KENDİSİ AZALTMADAN belleği KOŞULSUZ serbest
        // bırakan DÜŞÜK SEVİYE bir ilkeldir (yalnızca `nox_rc_
        // predecrement`in "sıfıra düştü" dönüşünden SONRA çağrılması
        // GEREKİR, bkz. `nox_rc_release`in KENDİSİ) — BU YANLIŞLIKLA
        // KULLANILDIĞINDA (İLK sürümde OLDUĞU GİBİ) paylaşılan bir
        // kutu (ör. `w: int | None = y`) HÂLÂ BAŞKA BİR sahibi VARKEN
        // ERKEN serbest bırakılır, bu da SONRAKİ (GERÇEK) sahibinin
        // scope-sonu temizliğinde ÇİFTE-SERBEST-BIRAKMAYA (segfault,
        // GERÇEKTEN gözlemlendi — bkz. break→red→fix ritüeli) yol açar.
        // Faz GG.7: GG.1'in `.str` dalıyla AYNI desen — `nox_rc_release`
        // (predecrement + koşullu `nox_rc_free_payload`) doğrudan bir
        // ÇAĞRI OLARAK DEĞİL, predecrement'i `emitInlinePredecrement`
        // İLE inline edip YALNIZCA GERÇEKTEN sıfıra/altına düştüğünde
        // (NADİR yol) `nox_rc_free_payload`ya düşerek.
        const should_free = try self.emitInlinePredecrement(ptr, .boxed_scalar);
        const free_label = try self.newLabel("boxed_free");
        const skip_free_label = try self.newLabel("boxed_free_skip");
        const free_done_label = try self.newLabel("boxed_free_done");
        try self.qbeJnz(should_free, free_label, skip_free_label);
        try self.qbeLabel(free_label);
        try self.qbeCall(null, "$nox_rc_free_payload", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ptr }, .{ .ty = .l, .text = "8" } });
        try self.qbeJmp(free_done_label);
        try self.qbeLabel(skip_free_label);
        try self.qbeJmp(free_done_label);
        try self.qbeLabel(free_done_label);
    } else if (elem_heap_info) |info| {
        // `ptr`nin KENDİSİ bir listedir; `info` bu listenin İÇİNDEKİ
        // elemanları betimler — `releaseFnNameFor` ise "release edilecek
        // DEĞERİN KENDİ türü"nü ister, bu yüzden burada `ptr`nin KENDİ
        // tam betimleyicisi sentezlenir (`heap = .list` her zaman, çünkü
        // bu dal zaten `heap != .class` demektir).
        const self_info: ElemHeapInfo = .{ .heap = .list, .elem_qtype = elem_qtype, .nested = info };
        const fn_name = try self.releaseFnNameFor(self_info);
        const fn_sym = try std.fmt.allocPrint(self.allocator, "${s}_release", .{fn_name});
        try self.qbeCall(null, fn_sym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ptr } });
    } else {
        // Faz GG.7: yukarıdaki `.boxed_scalar` dalıyla AYNI gerekçe —
        // ilkel-elemanlı `list[T]` release'i (ÇOK SIK bir yol) inline
        // predecrement'e taşınır.
        const size = try self.listPayloadSize(ptr, elem_qtype);
        const should_free = try self.emitInlinePredecrement(ptr, .list);
        const free_label = try self.newLabel("list_free");
        const skip_free_label = try self.newLabel("list_free_skip");
        const free_done_label = try self.newLabel("list_free_done");
        try self.qbeJnz(should_free, free_label, skip_free_label);
        try self.qbeLabel(free_label);
        try self.qbeCall(null, "$nox_rc_free_payload", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ptr }, .{ .ty = .l, .text = size } });
        try self.qbeJmp(free_done_label);
        try self.qbeLabel(skip_free_label);
        try self.qbeJmp(free_done_label);
        try self.qbeLabel(free_done_label);
    }
    try self.qbeJmp(done_label);
    try self.qbeLabel(skip_label);
    try self.qbeJmp(done_label);
    try self.qbeLabel(done_label);
}

/// **Faz JJ (bkz. nox-teknik-spesifikasyon.md §3.68'in devamı) — GERÇEK
/// çift-serbest-bırakma/kullanım-sonrası-serbest-bırakma KÖK NEDENİ
/// BULUNDU VE DÜZELTİLDİ:** bu fonksiyon `info.slot`u serbest bıraktıktan
/// SONRA slotu SIFIRLAMIYORDU. Bir GERÇEK (inline OLMAYAN) fonksiyon
/// çağrısı İçin bu ZARARSIZDIR (slot, fonksiyonun KENDİ yığın çerçevesi
/// YIKILDIĞINDA zaten YOK OLUR) — ama `genInlinedCall`in inline ettiği
/// bir yerel (ör. bir `list[str]` yerel değişkeni, bkz. §3.68'in
/// `loopcall` tekrarlaması), ÇAĞRI SİTESİ başına TEK bir `alloc8` İLE
/// (döngünün DIŞINDA, YALNIZCA BİR KEZ) temsil edilir — bu slot,
/// döngünün HER yinelemesinde YENİDEN KULLANILIR. `releaseNamedLocalsExcept`
/// (inline edilmiş `return_stmt`nin simüle ettiği "kapsam sonu"
/// temizliği) HER yinelemenin SONUNDA bu yerel değişkeni serbest
/// BIRAKIYORDU AMA slotu sıfırlamıyordu — bu yüzden BİR SONRAKİ
/// yinelemede, yerel değişkenin KENDİ "üzerine yazmadan ÖNCE eskiyi
/// serbest bırak" mantığı (bkz. `var_decl`nin kodgen'i), ÖNCEKİ
/// yinelemede ZATEN serbest bırakılmış (ve genellikle ARTIK BAŞKA bir
/// tahsis tarafından YENİDEN KULLANILMIŞ) o AYNI işaretçiyi HÂLÂ "canlı"
/// SANIP TEKRAR serbest bırakıyordu — GERÇEK bir çift-serbest-bırakma
/// (`List_str_release` → `nox_str_release` → `nox_rc_predecrement` →
/// `alloc.arc.refcountOf`de "incorrect alignment" panikiyle KANITLANDI,
/// lldb İLE: üçüncü `List_str_release` çağrısı BİRİNCİYLE AYNI adresi
/// KULLANDI VE içeriği zaten ÇÖPTÜ). Düzeltme: serbest bırakmadan HEMEN
/// SONRA slotu `0`a sıfırlamak — GERÇEK fonksiyon çağrıları İçin
/// TAMAMEN zararsız (slot ZATEN atılacaktı), inline edilmiş döngü-içi
/// yerel değişkenler İçin İSE bu tam olarak GEREKEN "kapsam sonunda
/// boşaltılmış" değişmezini SAĞLAR.
pub fn releaseSlotIfSet(self: *Codegen, info: VarInfo) CodegenError!void {
    const ptr = try self.newTemp();
    try self.qbeLoadL(ptr, info.slot);
    try self.releaseValueIfSet(ptr, info.heap, info.elem_qtype, info.class_name, info.elem_heap_info, info.dict_info);
    try self.qbeStoreImmL(0, info.slot);
}

/// `Task[T]`/`Channel[T]`/`ThreadHandle[T]`/`ThreadChannel[T]` (bkz.
/// `HeapKind`in belge notu — bunlar ARC-yönetimli DEĞİLDİR, `isHeapManaged`in
/// DIŞINDadır, `dict[K,V]`in AKSİNE — bkz. Faz FF.3) TEK bir DEĞERİ yok
/// eder — `releaseValueIfSet`in bu dört tür İÇİNDEKİ karşılığı
/// (null-kontrolü/predecrement YOK, DOĞRUDAN bir kez yıkım). Hem kapsam-
/// sonu temizliğinde (`releaseAllLocalsExcept`) hem de Faz S.1'den beri
/// yeniden atamada eski değeri serbest bırakmak için (`genAssign`nin
/// `.identifier`/`.attribute` dalları) kullanılan tek ortak yoldur —
/// `Task` İÇİN GÜVENLİK açısından KRİTİK bir çağrıdır: `nox_async_destroy_task`
/// görev HENÜZ tamamlanmamışsa struct'ı HEMEN serbest BIRAKMAZ (bkz.
/// `runtime/async_rt/scheduler.zig`nin `Task.detached`i) — aksi halde
/// fiber kendi sonucunu SERBEST BIRAKILMIŞ belleğe yazardı.
pub fn destroyNonArcValue(self: *Codegen, ptr: []const u8, heap: HeapKind) CodegenError!void {
    switch (heap) {
        .task, .channel, .thread_handle, .thread_channel, .task_local => {
            const fn_name = switch (heap) {
                .task => "nox_async_destroy_task",
                .channel => "nox_channel_destroy",
                .thread_handle => "nox_thread_destroy",
                .thread_channel => "nox_threadchannel_destroy",
                .task_local => "nox_tasklocal_destroy",
                else => unreachable,
            };
            const fn_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{fn_name});
            try self.qbeCall(null, fn_sym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ptr } });
        },
        else => unreachable,
    }
}

/// `destroyNonArcValue` ile AYNI, yalnızca bir yerel değişkenin (henüz
/// ÜZERİNE yazılmamış) MEVCUT slot değerini önce yükleyip sonra yok eder
/// — `releaseSlotIfSet`in `Task`/`Channel`/`ThreadHandle`/`ThreadChannel`
/// karşılığı.
/// `releaseSlotIfSet`nin AYNI düzeltmesi (bkz. onun belge notu, Faz JJ) —
/// `Task[T]`/`Channel[T]`/`ThreadHandle[T]`/`ThreadChannel[T]` tipli bir
/// yerel İÇİN de, inline edilmiş bir çağrı sitesinde döngü-yinelemeleri
/// ARASI slot yeniden KULLANIMI AYNI riski taşır — yıkımdan SONRA slot
/// sıfırlanmazsa bir SONRAKİ yinelemenin "üzerine yazmadan önce eskiyi
/// yok et" mantığı ZATEN yıkılmış bir değeri TEKRAR yıkmaya çalışabilir.
pub fn destroyNonArcSlotIfSet(self: *Codegen, info: VarInfo) CodegenError!void {
    const ptr = try self.newTemp();
    try self.qbeLoadL(ptr, info.slot);
    try self.destroyNonArcValue(ptr, info.heap);
    try self.qbeStoreImmL(0, info.slot);
}

pub fn emitDefaultReturn(self: *Codegen, ret_qtype: QbeType) CodegenError!void {
    switch (ret_qtype) {
        .none => try self.qbeRet(null),
        .l, .w => try self.qbeRet("0"),
        .d => try self.qbeRet("d_0"),
    }
}

/// `value` tam olarak izlenen bir heap bağlamına (takma ad) işaret
/// ediyorsa, o değeri retain eder (iki bağımsız sahip artık aynı nesneyi
/// paylaşıyor). Aksi halde `v0`'ı olduğu gibi döndürür.
/// `v`, bir `lowlevel` bloğunun arenasından gelen (`.arena`) ya da şu an
/// lexical olarak bir `lowlevel` bloğunun içinde bulunulan (`in_lowlevel_depth
/// > 0`) bir heap tipli (`list`/sınıf) değerse hata döner. Basitlik ve
/// güvenlik için, bir `lowlevel` bloğu içindeyken HİÇBİR heap tipli değer
/// (arena olsun olmasın) bir çağrıya argüman/alıcı olamaz, döndürülemez ya
/// da başka bir isme takma ad olamaz — bkz. modül üstü not.
pub fn checkNoLowlevelEscape(self: *Codegen, v: Value) CodegenError!void {
    if (isHeapManaged(v.heap) and (v.arena or self.in_lowlevel_depth > 0)) return error.Unsupported;
}

/// `nox_rc_retain`in çalışma zamanı ÇAĞRISI YERİNE doğrudan gömülen (inline)
/// karşılığı — performans fazında (bkz. nox-teknik-spesifikasyon.md,
/// benchmark darboğaz denetimi) ARC-ağırlıklı kodda (`oop_arc_churn`,
/// liste takma adı) ölçülen bir darboğaz: retain, refcount'u (payload'dan
/// HEMEN ÖNCEKİ görünmez 8 baytlık başlık, bkz. `runtime/alloc/arc.zig`'in
/// `HEADER_SIZE`i — bu ofset iki taraf arasında SABİT bir sözleşmedir) bir
/// artırmaktan İBARETTİR; AYRI bir nesne dosyasına (kendi çağrı/yığın
/// çerçevesi maliyetiyle) bir fonksiyon çağrısı GEREKTİRMEZ. `nox_rc_alloc`/
/// `nox_rc_free_payload` (gerçek `malloc`/`free`e ihtiyaç duyar) İSE inline
/// EDİLEMEZ — yalnızca bu saf aritmetik işlem inline edilir.
/// Faz FF.6 (bkz. nox-teknik-spesifikasyon.md §3.65): `ptr` `null`
/// OLABİLİR — bir `T | None` (heap) değeri (bkz. `resolveType`in
/// `.optional` dalı, "null = None" temsili). ÖNCEDEN bu fonksiyon
/// KOŞULSUZDU (`sub`/`load`/`add`/`store` DOĞRUDAN), ÇÜNKÜ heap-
/// yönetimli bir slot Optional'dan ÖNCE ASLA null bir Nox DEĞERİ
/// TUTAMAZDI (null yalnızca `__init__`-öncesi/dahili bir sentinel'DI,
/// hiçbir kullanıcı kodu yolunun onu `retainIfAliasing`e GEÇİREBİLECEĞİ
/// bir durum yoktu) — `self.next = next` (`next: Node | None`) gibi bir
/// atama BUNU artık MÜMKÜN KILDIĞINDAN, `releaseValueIfSet`in ZATEN
/// sahip olduğu AYNI null-güvenliği retain YÖNÜNDE de eklemek GEREKTİ
/// (aksi halde `null - 8` adresinden okuma DENEMESİ çöker — bu, GERÇEK
/// bir segfault olarak GÖZLEMLENDİ, bkz. break→red→fix ritüeli).
/// Faz (str-header genişletmesi, bkz. plan dosyası "`str`e uzunluk alanı +
/// ASCII bayrağı ekleme"): `str` DIŞINDAKİ HER heap tipi İçin refcount
/// `ARC_HEADER_SIZE` uzaklıktadır (`payload_ptr - ARC_HEADER_SIZE`) — ama
/// `str`nin KENDİ paketlenmiş uzunluk+ascii başlığı (`STR_HEADER_SIZE`)
/// ARC başlığı İLE kamuya açık işaretçi ARASINA girdiğinden (bkz.
/// `runtime/str.zig`nin modül üstü notu), `str` İçin refcount
/// `ARC_HEADER_SIZE + STR_HEADER_SIZE` uzaklıktadır. `emitInlineRetain`/
/// `emitInlinePredecrement`in TEK bir sabit ofset varsayması (`.str`
/// DAHİL) `list[str].append()`nin büyüme yolu GİBİ yerlerde SESSİZCE
/// yanlış adreste refcount okur/yazardı — bulunup düzeltildi.
fn retainOffset(heap: HeapKind) usize {
    return if (heap == .str) ARC_HEADER_SIZE + types.STR_HEADER_SIZE else ARC_HEADER_SIZE;
}

pub fn emitInlineRetain(self: *Codegen, ptr: []const u8, heap: HeapKind) CodegenError!void {
    const is_null = try self.newTemp();
    try self.qbeOp2Imm(is_null, .w, "ceql", ptr, 0);
    const retain_label = try self.newLabel("retain");
    const skip_label = try self.newLabel("retain_skip");
    const done_label = try self.newLabel("retain_done");
    try self.qbeJnz(is_null, skip_label, retain_label);
    try self.qbeLabel(retain_label);
    const hdr = try self.newTemp();
    try self.qbeOp2Imm(hdr, .l, "sub", ptr, @intCast(retainOffset(heap)));
    // Faz MN.1 (bkz. plan dosyası): `load → add → store` dizisi
    // `qbeAtomicAdd`e taşındı — QBE'de BAYT-BİREBİR AYNI metni üretir,
    // LLVM'de (`--release`) GERÇEK bir `atomicrmw add` yayar. Dönüş
    // değeri (yeni refcount) burada KULLANILMIYOR — sadece `qbeAlloc`
    // deseninin AKSİNE burada bir slot DEĞİL, HEAP başlığı söz konusu
    // olduğundan mem2reg'in KENDİSİ zaten İLGİSİZ.
    _ = try self.qbeAtomicAdd(hdr, 1);
    try self.qbeJmp(done_label);
    try self.qbeLabel(skip_label);
    try self.qbeJmp(done_label);
    try self.qbeLabel(done_label);
}

/// `nox_rc_predecrement`in gömülü (inline) karşılığı — `emitInlineRetain`
/// ile AYNI gerekçe. Dönüş (bir `%temp`, `w`) AYNI anlamı taşır: `1` —
/// refcount sıfıra/altına düştü, belleği GERÇEKTEN serbest bırakma
/// sorumluluğu ÇAĞIRANDADIR (`nox_rc_free_payload`, HÂLÂ bir runtime
/// çağrısı — gerçek `free` allocator'a ihtiyaç duyduğundan inline
/// edilemez); `0` — nesne hâlâ canlı (başka bir sahibi var).
pub fn emitInlinePredecrement(self: *Codegen, ptr: []const u8, heap: HeapKind) CodegenError![]const u8 {
    const hdr = try self.newTemp();
    try self.qbeOp2Imm(hdr, .l, "sub", ptr, @intCast(retainOffset(heap)));
    // Faz MN.1 (bkz. plan dosyası, VE `emitInlineRetain`nin AYNI notu):
    // `load → sub → store` dizisi `qbeAtomicSub`e taşındı. `qbeAtomicSub`
    // İŞLEM-SONRASI (NEW) değeri döner (`qbeAtomicAdd` İLE AYNI SÖZLEŞME)
    // — bu YÜZDEN aşağıdaki `cslel rc2, 0` karşılaştırması DEĞİŞMEDEN
    // kalıyor (LLVM'in `atomicrmw sub`ı ESKİ değeri döndürse DE, seam'in
    // KENDİSİ `new = old - imm`yi DAHİLİ olarak hesaplayıp döner — bkz.
    // `llvm_emit.zig`nin AYNI-isimli metodu).
    const rc2 = try self.qbeAtomicSub(hdr, 1);
    const should_free = try self.newTemp();
    try self.qbeOp2Imm(should_free, .w, "cslel", rc2, 0);
    return should_free;
}

/// `genListAppend`nin büyüme yolu İçin: `list_ptr`nin (başlıktan SONRAKİ)
/// İLK `count` elemanını (null OLMAYANLARI) KOŞULSUZ retain eder (düz
/// "refcount+1" — `emitInlinePredecrement`in TERSİ, ama HİÇBİR ZAMAN
/// serbest bırakmaya yol AÇAMAYACAĞINDAN tek bir inline artırım YETERLİDİR,
/// TİPE özgü özyinelemeli dispatch GEREKMEZ). Bkz. `genListAppend`nin
/// büyüme-retain notunun TAM gerekçesi: `nox_list_grow`nin ham `@memcpy`i
/// eleman işaretçilerini retain'SİZ kopyaladığından, bu ÇAĞRI YENİ bloğun
/// bu elemanlar üzerinde ESKİ bloktan BAĞIMSIZ, GEÇERLİ bir sahiplik payı
/// KAZANDIĞINI YANSITIR.
pub fn emitListElemRetainLoop(self: *Codegen, list_ptr: []const u8, count: []const u8, elem_heap: HeapKind) CodegenError!void {
    const idx_slot = try self.newTemp();
    try self.qbeAlloc(idx_slot, .eight, 8);
    try self.qbeStoreImmL(0, idx_slot);
    const cond_label = try self.newLabel("append_retain_cond");
    const body_label = try self.newLabel("append_retain_body");
    const end_label = try self.newLabel("append_retain_end");
    try self.qbeJmp(cond_label);
    try self.qbeLabel(cond_label);
    const idx_cur = try self.newTemp();
    try self.qbeLoadL(idx_cur, idx_slot);
    const cont = try self.newTemp();
    try self.qbeOp2(cont, .w, "csltl", idx_cur, count);
    try self.qbeJnz(cont, body_label, end_label);
    try self.qbeLabel(body_label);
    const off = try self.newTemp();
    try self.qbeOp2Imm(off, .l, "mul", idx_cur, 8);
    const off16 = try self.newTemp();
    try self.qbeOp2Imm(off16, .l, "add", off, @intCast(LIST_HEADER_SIZE));
    const addr = try self.newTemp();
    try self.qbeOp2(addr, .l, "add", list_ptr, off16);
    const elem = try self.newTemp();
    try self.qbeLoadL(elem, addr);
    try self.emitInlineRetain(elem, elem_heap);
    const idx_next = try self.newTemp();
    try self.qbeOp2Imm(idx_next, .l, "add", idx_cur, 1);
    try self.qbeStoreL(idx_next, idx_slot);
    try self.qbeJmp(cond_label);
    try self.qbeLabel(end_label);
}

/// `emitListElemRetainLoop`nin dengeleyicisi: `genListAppend`nin büyüme
/// yolunda ESKİ blok BU ÇAĞRIDA GERÇEKTEN ölüyorsa (`emitInlinePredecrement`
/// `true` dönerse), retain döngüsünün eklediği fazladan payı GERİ ALMAK
/// İçin `list_ptr`nin İLK `count` elemanını düz bir decrement İLE azaltır.
/// **ASLA sıfıra/altına düşüremez** (elemanın KENDİ ÖNCEKİ, geçerli
/// sahipliği HÂLÂ durur — bu SADECE bu fonksiyonun EKLEDİĞİ +1'i geri
/// alır) — bu YÜZDEN TAM özyinelemeli `release` (nested serbest bırakma)
/// GEREKMEZ, TİPE özgü dispatch OLMADAN düz bir "refcount-1" YETERLİDİR.
pub fn emitListElemPlainDecrementLoop(self: *Codegen, list_ptr: []const u8, count: []const u8, elem_heap: HeapKind) CodegenError!void {
    const idx_slot = try self.newTemp();
    try self.qbeAlloc(idx_slot, .eight, 8);
    try self.qbeStoreImmL(0, idx_slot);
    const cond_label = try self.newLabel("append_deccomp_cond");
    const body_label = try self.newLabel("append_deccomp_body");
    const dec_label = try self.newLabel("append_deccomp_do");
    const skip_label = try self.newLabel("append_deccomp_skip");
    const end_label = try self.newLabel("append_deccomp_end");
    try self.qbeJmp(cond_label);
    try self.qbeLabel(cond_label);
    const idx_cur = try self.newTemp();
    try self.qbeLoadL(idx_cur, idx_slot);
    const cont = try self.newTemp();
    try self.qbeOp2(cont, .w, "csltl", idx_cur, count);
    try self.qbeJnz(cont, body_label, end_label);
    try self.qbeLabel(body_label);
    const off = try self.newTemp();
    try self.qbeOp2Imm(off, .l, "mul", idx_cur, 8);
    const off16 = try self.newTemp();
    try self.qbeOp2Imm(off16, .l, "add", off, @intCast(LIST_HEADER_SIZE));
    const addr = try self.newTemp();
    try self.qbeOp2(addr, .l, "add", list_ptr, off16);
    const elem = try self.newTemp();
    try self.qbeLoadL(elem, addr);
    const is_null = try self.newTemp();
    try self.qbeOp2Imm(is_null, .w, "ceql", elem, 0);
    try self.qbeJnz(is_null, skip_label, dec_label);
    try self.qbeLabel(dec_label);
    // Bu decrement ASLA sıfıra/altına düşemez (bkz. bu fonksiyonun belge
    // notu) — `should_free` dönüş değeri BİLİNÇLİ olarak yok sayılır.
    _ = try self.emitInlinePredecrement(elem, elem_heap);
    try self.qbeJmp(skip_label);
    try self.qbeLabel(skip_label);
    const idx_next = try self.newTemp();
    try self.qbeOp2Imm(idx_next, .l, "add", idx_cur, 1);
    try self.qbeStoreL(idx_next, idx_slot);
    try self.qbeJmp(cond_label);
    try self.qbeLabel(end_label);
}

/// `expr` değerlendirildiğinde BAŞKA BİR YERDE ZATEN sahibi olan, ÖDÜNÇ
/// ALINMIŞ bir heap referansı mı üretir (bu durumda yeni bir isme takma ad
/// olması `nox_rc_retain` GEREKTİRİR), yoksa TAZE bir değer mi (`isTemporaryExpr`
/// — retain GEREKTİRMEZ, zaten tek sahiplidir) ya da alanın/elemanın
/// KENDİSİ genFieldRead/genIndex TARAFINDAN ZATEN retain edilmiş mi
/// (taze bir TABAN üzerinden okunmuşsa — bu durumda BURADA TEKRAR retain
/// etmek ÇİFTE retain'e yol açardı) belirler:
///   - `.identifier`: her zaman bir takma ad (ödünç alınmış, retain gerekir).
///   - `.attribute`/`.index`: tabanı (`obj`) TAZE değilse bir takma addır
///     (retain gerekir, çünkü `genFieldRead`/`genIndex` bu durumda retain
///     ETMEMİŞTİR); tabanı TAZE ise `genFieldRead`/`genIndex` ZATEN
///     retain etmiştir (bkz. o fonksiyonların belge notu) — burada
///     retain YAPILMAMALIDIR.
///   - Diğerleri (`.call`, `.list_lit`, ...): taze, retain gerekmez.
fn isAliasingExpr(expr: ast.Expr) bool {
    return switch (expr) {
        .identifier => true,
        .attribute => |a| !isTemporaryExpr(a.obj.*),
        .index => |idx| !isTemporaryExpr(idx.obj.*),
        else => false,
    };
}

pub fn retainIfAliasing(self: *Codegen, value: ast.Expr, v0: Value) CodegenError!Value {
    // GG.14 (bkz. nox-teknik-spesifikasyon.md §3.66): `v0.is_pinned`
    // (`emitStringLiteral`in DOĞRUDAN işaretlediği) YA DA `value` BİLİNEN,
    // BU splice sitesinde HER ZAMAN pinned OLDUĞU KANITLANMIŞ bir
    // parametre İSE (`VarInfo.is_pinned_str`) — retain, `PINNED_REFCOUNT`
    // (ASLA sıfıra İNMEZ) üzerinde mantıksal olarak GÜVENLİ ama TAMAMEN
    // GEREKSİZ bir no-op olurdu, TAMAMEN ATLANIR.
    if (v0.is_pinned) return v0;
    if (value == .identifier) {
        if (self.vars.get(value.identifier)) |info| {
            if (info.is_pinned_str) return v0;
        }
    }
    // `v0.always_fresh` (bkz. `Value`nin belge notu, stdlib fazı §G):
    // `s[i]` gibi TABANDAN BAĞIMSIZ TAZE bir tahsis üreten ifadeler
    // ASLA aliasing SAYILMAZ — `isAliasingExpr`in AST-tabanlı sezgisi
    // (`.index`in tabanı temporary DEĞİLSE aliasing SAYAR) burada
    // GEÇERSİZDİR (tip bilgisi olmadan `.index`in `str` mi `list`/
    // `dict` mi olduğunu AYIRT EDEMEZ).
    if (!v0.always_fresh and isAliasingExpr(value) and isHeapManaged(v0.heap)) {
        try self.checkNoLowlevelEscape(v0);
        try self.emitInlineRetain(v0.text, v0.heap);
    }
    return v0;
}

/// `return <ifade>` bir heap değeri döndürüyorsa, bu değerin BU
/// FONKSİYONUN kendi münhasır (ve zaten terk edilecek) sahipliğini mi
/// devrettiğini, yoksa BAŞKA BİR YERDE ZATEN sahibi olan ödünç alınmış
/// bir referansı mı dışarı verdiğini belirler:
///   - Yerel bir değişkeni (`return x`, `x` bir PARAMETRE DEĞİL)
///     döndürmek retain GEREKTİRMEZ: sıfır maliyetli bir "taşıma"dır
///     (`x` zaten kapsam-sonu temizliğinden muaf tutulur).
///   - TAZE bir değer (`.call`/`.list_lit`) döndürmek de bir taşımadır
///     (başka hiçbir sahibi yoktur).
///   - Bir PARAMETREYİ olduğu gibi döndürmek (`return p`) ya da bir ALAN
///     OKUMASINI döndürmek (`return self.attr`) retain GEREKTİRİR: bu
///     değerin BAŞKA BİR sahibi zaten var (çağıranın kendi bağlaması ya
///     da içinde bulunulan nesnenin alanı) — çağıran bunu kendi (yeni)
///     bir sahipliğine bağlayabilir. Bu retain, olası bir çağıran-taraf
///     telafi release'iyle (bkz. `releaseTemporaryArgs`/
///     `releaseIfTemporary` — TAZE bir argüman/alıcının çağrı sonrası
///     serbest bırakılması) doğru dengeye ulaşır; bu ikisi birlikte
///     "passthrough" fonksiyonları (ör. `def identity(p): return p`)
///     bile güvenli kılar.
pub fn returnNeedsRetain(self: *Codegen, e: ast.Expr) bool {
    return switch (e) {
        .identifier => |name| blk: {
            const info = self.vars.get(name) orelse break :blk false;
            // GG.14 (bkz. nox-teknik-spesifikasyon.md §3.66):
            // `info.is_pinned_str` — BU parametrenin, BU splice sitesinde,
            // HER ZAMAN bir string literaline (`PINNED_REFCOUNT`, ASLA
            // sıfıra İNMEZ) çözüldüğü KANITLANDI (`exprAlwaysProducesPinnedString`)
            // — `is_param` OLSA BİLE retain GEREKSİZDİR.
            if (info.is_pinned_str) break :blk false;
            break :blk info.is_param;
        },
        .attribute => true,
        // Stdlib fazı §L: `.index` İÇİN eksik dal — `return list[i]`
        // (ör. `nox.json.array_get`in `return v.arr[i]`si) `list`/
        // `dict`in İÇİNE ÖDÜNÇ ALINMIŞ bir referansı (bkz. `genIndex`'in
        // AYNI "taban temporary DEĞİLSE retain gerekmez" gerekçesi)
        // OLDUĞU GİBİ dışarı verir — TABAN temporary DEĞİLSE bu ödünç
        // retain EDİLMEDEN döndürülürse çağıran onu KENDİ sahipliğiymiş
        // gibi (bir `.call` sonucu) release eder, bu da listenin PAYLAŞTIĞI
        // referansı ERKEN sıfıra indirip bir kullanım-sonrası-serbest-
        // bırakmaya yol açar (GERÇEKTEN yaşandı — `nox.json.array_get`
        // "incorrect alignment" ile ÇÖKEN bir çift-serbest-bırakmaya yol
        // açtı). TABAN temporary İSE `genIndex` KENDİSİ zaten BİR retain
        // yapmıştır (`emitInlineRetain`, taban serbest bırakılmadan ÖNCE)
        // — burada TEKRAR retain etmek ÇİFT retain (kalıcı sızıntı)
        // olurdu, bu yüzden koşul `isAliasingExpr`in AYNI `.index` dalıyla
        // BİREBİR eşleşir.
        .index => |idx| !isTemporaryExpr(idx.obj.*),
        else => false,
    };
}
