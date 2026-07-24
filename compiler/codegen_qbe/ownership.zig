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
    if (entry.is_param or entry.arena) return;
    if (isHeapManaged(entry.heap)) {
        try self.releaseSlotIfSet(entry);
    } else if (entry.heap == .task or entry.heap == .channel or entry.heap == .thread_handle or entry.heap == .thread_channel) {
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
pub fn releaseNamedLocalsExcept(self: *Codegen, names: []const []const u8, except_name: ?[]const u8) CodegenError!void {
    for (names) |name| {
        if (except_name) |en| {
            if (std.mem.eql(u8, name, en)) continue;
        }
        const entry = self.vars.get(name) orelse continue;
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
    try self.out.writer.print("    {s} =l add {s}, 8\n", .{ cap_addr, ptr });
    const cap_t = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ cap_t, cap_addr });
    const size_t = try self.newTemp();
    try self.out.writer.print("    {s} =l mul {s}, {d}\n", .{ size_t, cap_t, qbeSizeOf(elem_qtype) });
    const total_t = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ total_t, size_t, LIST_HEADER_SIZE });
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

    try self.out.writer.print("export function ${s}_release(l {s}, l %p) {{\n@start\n", .{ fn_name, RT_PARAM });
    const should_free = try self.emitInlinePredecrement("%p");
    const free_label = try self.newLabel("list_release_free");
    const done_label = try self.newLabel("list_release_done");
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ should_free, free_label, done_label });
    try self.out.writer.print("{s}\n", .{free_label});

    const len_t = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl %p\n", .{len_t});
    // Faz U.1: gerçek TAHSİS EDİLMİŞ boyut `cap`e (@8) karşılık gelir,
    // `len`e (@0) DEĞİL — `len`, ELEMAN döngüsünün SINIRI olarak KALIR
    // (yalnızca GEÇERLİ elemanlar release edilmeli), ama belleği
    // serbest bırakırken `cap` KULLANILMALIDIR (aksi halde `.append()`in
    // büyüttüğü bir liste, ONA AYRILAN gerçek bloktan DAHA KÜÇÜK bir
    // boyutla serbest bırakılır — havuzun serbest-liste sınıf indeksini
    // BOZAR, bkz. `arc.zig`nin `nox_rc_free_payload` notu).
    const cap_addr = try self.newTemp();
    try self.out.writer.print("    {s} =l add %p, 8\n", .{cap_addr});
    const cap_t = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ cap_t, cap_addr });

    if (info.nested) |n| {
        const callee: ?[]const u8 = if (n.heap == .str) null else try self.releaseFnNameFor(n.*);
        const idx_slot = try self.newTemp();
        try self.out.writer.print("    {s} =l alloc8 8\n", .{idx_slot});
        try self.out.writer.print("    storel 0, {s}\n", .{idx_slot});

        const cond_label = try self.newLabel("list_release_cond");
        const body_label = try self.newLabel("list_release_body");
        const loopend_label = try self.newLabel("list_release_loopend");
        const skip_label = try self.newLabel("list_release_skip");
        const rel_label = try self.newLabel("list_release_elem");

        try self.out.writer.print("    jmp {s}\n", .{cond_label});
        try self.out.writer.print("{s}\n", .{cond_label});
        const idx_cur = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ idx_cur, idx_slot });
        const cont = try self.newTemp();
        try self.out.writer.print("    {s} =w csltl {s}, {s}\n", .{ cont, idx_cur, len_t });
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ cont, body_label, loopend_label });
        try self.out.writer.print("{s}\n", .{body_label});

        const off = try self.newTemp();
        try self.out.writer.print("    {s} =l mul {s}, 8\n", .{ off, idx_cur });
        const off8 = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ off8, off, LIST_HEADER_SIZE });
        const addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add %p, {s}\n", .{ addr, off8 });
        const elem = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ elem, addr });
        const is_null = try self.newTemp();
        try self.out.writer.print("    {s} =w ceql {s}, 0\n", .{ is_null, elem });
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ is_null, skip_label, rel_label });
        try self.out.writer.print("{s}\n", .{rel_label});
        if (callee) |c| {
            try self.out.writer.print("    call ${s}_release(l {s}, l {s})\n", .{ c, RT_PARAM, elem });
        } else {
            try self.out.writer.print("    call $nox_str_release(l {s}, l {s})\n", .{ RT_PARAM, elem });
        }
        try self.out.writer.print("    jmp {s}\n", .{skip_label});
        try self.out.writer.print("{s}\n", .{skip_label});
        const idx_next = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, 1\n", .{ idx_next, idx_cur });
        try self.out.writer.print("    storel {s}, {s}\n", .{ idx_next, idx_slot });
        try self.out.writer.print("    jmp {s}\n", .{cond_label});
        try self.out.writer.print("{s}\n", .{loopend_label});

        const size_t = try self.newTemp();
        try self.out.writer.print("    {s} =l mul {s}, 8\n", .{ size_t, cap_t });
        const total_t = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ total_t, size_t, LIST_HEADER_SIZE });
        try self.out.writer.print("    call $nox_rc_free_payload(l {s}, l %p, l {s})\n", .{ RT_PARAM, total_t });
    } else {
        const size_t = try self.newTemp();
        try self.out.writer.print("    {s} =l mul {s}, {d}\n", .{ size_t, cap_t, qbeSizeOf(info.elem_qtype) });
        const total_t = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ total_t, size_t, LIST_HEADER_SIZE });
        try self.out.writer.print("    call $nox_rc_free_payload(l {s}, l %p, l {s})\n", .{ RT_PARAM, total_t });
    }
    try self.out.writer.print("    jmp {s}\n", .{done_label});
    try self.out.writer.print("{s}\n", .{done_label});
    try self.out.writer.writeAll("    ret\n}\n");
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
    try self.out.writer.print("    {s} =w ceql {s}, 0\n", .{ is_null, ptr });
    const release_label = try self.newLabel("release");
    const skip_label = try self.newLabel("release_skip");
    const done_label = try self.newLabel("release_done");
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ is_null, skip_label, release_label });
    try self.out.writer.print("{s}\n", .{release_label});
    if (heap == .class) {
        const cn = class_name.?;
        try self.out.writer.print("    call ${s}_release(l {s}, l {s})\n", .{ cn, RT_PARAM, ptr });
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
        try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ rel_addr, ptr, CLOSURE_RELEASE_FN_PTR_OFFSET });
        const rel_fn = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ rel_fn, rel_addr });
        try self.out.writer.print("    call {s}(l {s}, l {s})\n", .{ rel_fn, RT_PARAM, ptr });
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
        const should_free = try self.emitInlinePredecrement(ptr);
        const free_label = try self.newLabel("str_free");
        const skip_free_label = try self.newLabel("str_free_skip");
        const free_done_label = try self.newLabel("str_free_done");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ should_free, free_label, skip_free_label });
        try self.out.writer.print("{s}\n", .{free_label});
        try self.out.writer.print("    call $nox_str_free_now(l {s}, l {s})\n", .{ RT_PARAM, ptr });
        try self.out.writer.print("    jmp {s}\n", .{free_done_label});
        try self.out.writer.print("{s}\n", .{skip_free_label});
        try self.out.writer.print("    jmp {s}\n", .{free_done_label});
        try self.out.writer.print("{s}\n", .{free_done_label});
    } else if (heap == .dict) {
        // Faz FF.3 (bkz. nox-teknik-spesifikasyon.md §3.62): `dict`
        // ARTIK `str` İLE AYNI "predecrement'e göre koşullu release"
        // desenini izler — `nox_dict_release`nin KENDİSİ `nox_rc_
        // predecrement` çağırır (bkz. `dict.zig`).
        const dinfo = dict_info.?;
        const key_is_str_lit: []const u8 = if (dinfo.key_is_str) "1" else "0";
        const value_is_str_lit: []const u8 = if (dinfo.value_is_str) "1" else "0";
        try self.out.writer.print("    call $nox_dict_release(l {s}, l {s}, w {s}, w {s})\n", .{ RT_PARAM, ptr, key_is_str_lit, value_is_str_lit });
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
        const should_free = try self.emitInlinePredecrement(ptr);
        const free_label = try self.newLabel("boxed_free");
        const skip_free_label = try self.newLabel("boxed_free_skip");
        const free_done_label = try self.newLabel("boxed_free_done");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ should_free, free_label, skip_free_label });
        try self.out.writer.print("{s}\n", .{free_label});
        try self.out.writer.print("    call $nox_rc_free_payload(l {s}, l {s}, l 8)\n", .{ RT_PARAM, ptr });
        try self.out.writer.print("    jmp {s}\n", .{free_done_label});
        try self.out.writer.print("{s}\n", .{skip_free_label});
        try self.out.writer.print("    jmp {s}\n", .{free_done_label});
        try self.out.writer.print("{s}\n", .{free_done_label});
    } else if (elem_heap_info) |info| {
        // `ptr`nin KENDİSİ bir listedir; `info` bu listenin İÇİNDEKİ
        // elemanları betimler — `releaseFnNameFor` ise "release edilecek
        // DEĞERİN KENDİ türü"nü ister, bu yüzden burada `ptr`nin KENDİ
        // tam betimleyicisi sentezlenir (`heap = .list` her zaman, çünkü
        // bu dal zaten `heap != .class` demektir).
        const self_info: ElemHeapInfo = .{ .heap = .list, .elem_qtype = elem_qtype, .nested = info };
        const fn_name = try self.releaseFnNameFor(self_info);
        try self.out.writer.print("    call ${s}_release(l {s}, l {s})\n", .{ fn_name, RT_PARAM, ptr });
    } else {
        // Faz GG.7: yukarıdaki `.boxed_scalar` dalıyla AYNI gerekçe —
        // ilkel-elemanlı `list[T]` release'i (ÇOK SIK bir yol) inline
        // predecrement'e taşınır.
        const size = try self.listPayloadSize(ptr, elem_qtype);
        const should_free = try self.emitInlinePredecrement(ptr);
        const free_label = try self.newLabel("list_free");
        const skip_free_label = try self.newLabel("list_free_skip");
        const free_done_label = try self.newLabel("list_free_done");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ should_free, free_label, skip_free_label });
        try self.out.writer.print("{s}\n", .{free_label});
        try self.out.writer.print("    call $nox_rc_free_payload(l {s}, l {s}, l {s})\n", .{ RT_PARAM, ptr, size });
        try self.out.writer.print("    jmp {s}\n", .{free_done_label});
        try self.out.writer.print("{s}\n", .{skip_free_label});
        try self.out.writer.print("    jmp {s}\n", .{free_done_label});
        try self.out.writer.print("{s}\n", .{free_done_label});
    }
    try self.out.writer.print("    jmp {s}\n", .{done_label});
    try self.out.writer.print("{s}\n", .{skip_label});
    try self.out.writer.print("    jmp {s}\n", .{done_label});
    try self.out.writer.print("{s}\n", .{done_label});
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
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ ptr, info.slot });
    try self.releaseValueIfSet(ptr, info.heap, info.elem_qtype, info.class_name, info.elem_heap_info, info.dict_info);
    try self.out.writer.print("    storel 0, {s}\n", .{info.slot});
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
        .task, .channel, .thread_handle, .thread_channel => {
            const fn_name = switch (heap) {
                .task => "nox_async_destroy_task",
                .channel => "nox_channel_destroy",
                .thread_handle => "nox_thread_destroy",
                .thread_channel => "nox_threadchannel_destroy",
                else => unreachable,
            };
            try self.out.writer.print("    call ${s}(l {s}, l {s})\n", .{ fn_name, RT_PARAM, ptr });
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
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ ptr, info.slot });
    try self.destroyNonArcValue(ptr, info.heap);
    try self.out.writer.print("    storel 0, {s}\n", .{info.slot});
}

pub fn emitDefaultReturn(self: *Codegen, ret_qtype: QbeType) CodegenError!void {
    switch (ret_qtype) {
        .none => try self.out.writer.writeAll("    ret\n"),
        .l, .w => try self.out.writer.writeAll("    ret 0\n"),
        .d => try self.out.writer.writeAll("    ret d_0\n"),
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
pub fn emitInlineRetain(self: *Codegen, ptr: []const u8) CodegenError!void {
    const is_null = try self.newTemp();
    try self.out.writer.print("    {s} =w ceql {s}, 0\n", .{ is_null, ptr });
    const retain_label = try self.newLabel("retain");
    const skip_label = try self.newLabel("retain_skip");
    const done_label = try self.newLabel("retain_done");
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ is_null, skip_label, retain_label });
    try self.out.writer.print("{s}\n", .{retain_label});
    const hdr = try self.newTemp();
    try self.out.writer.print("    {s} =l sub {s}, {d}\n", .{ hdr, ptr, ARC_HEADER_SIZE });
    const rc = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ rc, hdr });
    const rc2 = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, 1\n", .{ rc2, rc });
    try self.out.writer.print("    storel {s}, {s}\n", .{ rc2, hdr });
    try self.out.writer.print("    jmp {s}\n", .{done_label});
    try self.out.writer.print("{s}\n", .{skip_label});
    try self.out.writer.print("    jmp {s}\n", .{done_label});
    try self.out.writer.print("{s}\n", .{done_label});
}

/// `nox_rc_predecrement`in gömülü (inline) karşılığı — `emitInlineRetain`
/// ile AYNI gerekçe. Dönüş (bir `%temp`, `w`) AYNI anlamı taşır: `1` —
/// refcount sıfıra/altına düştü, belleği GERÇEKTEN serbest bırakma
/// sorumluluğu ÇAĞIRANDADIR (`nox_rc_free_payload`, HÂLÂ bir runtime
/// çağrısı — gerçek `free` allocator'a ihtiyaç duyduğundan inline
/// edilemez); `0` — nesne hâlâ canlı (başka bir sahibi var).
pub fn emitInlinePredecrement(self: *Codegen, ptr: []const u8) CodegenError![]const u8 {
    const hdr = try self.newTemp();
    try self.out.writer.print("    {s} =l sub {s}, {d}\n", .{ hdr, ptr, ARC_HEADER_SIZE });
    const rc = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ rc, hdr });
    const rc2 = try self.newTemp();
    try self.out.writer.print("    {s} =l sub {s}, 1\n", .{ rc2, rc });
    try self.out.writer.print("    storel {s}, {s}\n", .{ rc2, hdr });
    const should_free = try self.newTemp();
    try self.out.writer.print("    {s} =w cslel {s}, 0\n", .{ should_free, rc2 });
    return should_free;
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
    // `v0.always_fresh` (bkz. `Value`nin belge notu, stdlib fazı §G):
    // `s[i]` gibi TABANDAN BAĞIMSIZ TAZE bir tahsis üreten ifadeler
    // ASLA aliasing SAYILMAZ — `isAliasingExpr`in AST-tabanlı sezgisi
    // (`.index`in tabanı temporary DEĞİLSE aliasing SAYAR) burada
    // GEÇERSİZDİR (tip bilgisi olmadan `.index`in `str` mi `list`/
    // `dict` mi olduğunu AYIRT EDEMEZ).
    if (!v0.always_fresh and isAliasingExpr(value) and isHeapManaged(v0.heap)) {
        try self.checkNoLowlevelEscape(v0);
        try self.emitInlineRetain(v0.text);
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
