//! Sınıf/liste bellek DÜZENİ + yapısal eşitlik codegen'i — bkz. plan
//! dosyası "QBE codegen backend'ini alt modüllere bölme". Faz S.3'ün
//! döngü-çözücü ARC entegrasyonu (`release`/`trace`/`gc_free` + dispatch
//! tabloları) VE Python-tarzı ALAN-ALANA yapısal eşitlik (`_eq` üretimi,
//! `list[T]` DAHİL) burada toplanır.

const std = @import("std");
const ast = @import("../parser/ast.zig");
const types = @import("types.zig");
const abi = @import("abi.zig");
const codegen = @import("codegen.zig");

const Codegen = codegen.Codegen;
const QbeType = types.QbeType;
const HeapKind = types.HeapKind;
const ElemHeapInfo = types.ElemHeapInfo;
const ClassField = types.ClassField;
const ClassInfo = types.ClassInfo;
const ClassIdEntry = types.ClassIdEntry;
const RT_PARAM = types.RT_PARAM;
const LIST_HEADER_SIZE = types.LIST_HEADER_SIZE;
const TRACE_BUF_LEN_SIZE = types.TRACE_BUF_LEN_SIZE;
const TRACE_BUF_SLOT_SIZE = types.TRACE_BUF_SLOT_SIZE;
const CodegenError = abi.CodegenError;
const qbeTypeName = abi.qbeTypeName;
const qbeSizeOf = abi.qbeSizeOf;
const isHeapManaged = abi.isHeapManaged;

/// Her sınıf için `$ClassName_release(rt, p)` üretir: refcount'u azaltır
/// (`nox_rc_predecrement`); sıfıra düştüyse, ÖNCE heap-yönetimli her alanı
/// (sınıf TİPLİ ya da — bkz. görev "Sınıf alanı list[T] tipinde olabilsin"
/// — `list[T]` TİPLİ, varsa/null değilse) özyinelemeli olarak serbest
/// bırakır, SONRA belleği gerçekten serbest bırakır (`nox_rc_free_payload`).
/// Çalışma zamanının (`arc.zig`) aksine bu, derleme zamanında bilinen alan
/// düzenini (`cinfo.fields`) kullanabildiği için iç içe serbest bırakmayı
/// yapabilir — bkz. modül üstü not, "İç içe sınıf alanları". Her iki alan
/// türü de (sınıf/liste) `releaseValueIfSet` ile AYNI tek yoldan geçer —
/// bu, bir yerel değişkenin kapsam-sonu temizliğiyle (`releaseSlotIfSet`)
/// TAMAMEN aynı mantıktır (null kontrolü + doğru release fonksiyonuna
/// dispatch).
pub fn genClassRelease(self: *Codegen, class_name: []const u8, cinfo: ClassInfo) CodegenError!void {
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

    // Faz S.3: BU sınıf en az bir SINIF-TİPLİ alan taşıyorsa (yalnızca
    // BÖYLE sınıflar bir referans DÖNGÜSÜNÜN "kaynağı" olabilir — bkz.
    // `runtime/alloc/cycle_detector.zig`nin modül üstü notu) predecrement
    // SIFIRA düşmediğinde (nesne hâlâ canlı, AMA belki bir döngünün
    // parçası) `nox_cycle_possible_root`e KAYDEDİLİR; sıfıra düştüğünde
    // (GERÇEKTEN serbest bırakılıyor) `nox_cycle_forget` ile yan
    // tablodaki olası bir kalıntı TEMİZLENİR (adres yeniden kullanımına
    // karşı, bkz. onun belge notu). Sınıf-tipli alanı OLMAYAN sınıflar
    // İÇİN bu iki çağrı da GEREKSİZ (asla bir döngünün kaynağı OLAMAZLAR)
    // — performans İÇİN atlanır (ÇOĞUNLUK vakada, sıradan bir sınıfta,
    // sıfır ek maliyet).
    var has_class_field = false;
    for (cinfo.fields.items) |f| {
        if (f.info.heap == .class) {
            has_class_field = true;
            break;
        }
    }

    try self.out.writer.print("export function ${s}_release(l {s}, l %p) {{\n@start\n", .{ class_name, RT_PARAM });
    const should_free = try self.emitInlinePredecrement("%p");
    const free_label = try self.newLabel("release_free");
    const done_label = try self.newLabel("release_done");
    if (has_class_field) {
        const root_label = try self.newLabel("release_possible_root");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ should_free, free_label, root_label });
        try self.out.writer.print("{s}\n", .{root_label});
        try self.out.writer.print("    call $nox_cycle_possible_root(l {s}, l %p)\n", .{RT_PARAM});
        try self.out.writer.print("    jmp {s}\n", .{done_label});
    } else {
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ should_free, free_label, done_label });
    }
    try self.out.writer.print("{s}\n", .{free_label});
    if (has_class_field) {
        try self.out.writer.print("    call $nox_cycle_forget(l {s}, l %p)\n", .{RT_PARAM});
    }
    for (cinfo.fields.items) |f| {
        if (isHeapManaged(f.info.heap)) {
            const addr = try self.newTemp();
            try self.out.writer.print("    {s} =l add %p, {d}\n", .{ addr, f.offset });
            const fv = try self.newTemp();
            try self.out.writer.print("    {s} =l loadl {s}\n", .{ fv, addr });
            try self.releaseValueIfSet(fv, f.info.heap, f.info.elem_qtype, f.info.class_name, f.info.elem_heap_info, f.info.dict_info);
        } else if (f.info.heap == .task or f.info.heap == .channel or f.info.heap == .thread_handle or f.info.heap == .thread_channel) {
            // `Task[T]`/`Channel[T]`/`ThreadHandle[T]`/`ThreadChannel[T]`
            // sınıf alanı — ARC-yönetimli DEĞİLDİR (`isHeapManaged` bunu
            // KAPSAMAZ, `dict[K,V]`in AKSİNE — bkz. Faz FF.3), bu yüzden
            // AYRI bir dal: `destroyNonArcValue` ile DOĞRUDAN bir kez
            // yıkılır (bkz. `releaseAllLocalsExcept`in AYNI deseni —
            // yalnızca YEREL değil, sınıf ALANI için, Faz S.1'den beri
            // doğru).
            const addr = try self.newTemp();
            try self.out.writer.print("    {s} =l add %p, {d}\n", .{ addr, f.offset });
            const fv = try self.newTemp();
            try self.out.writer.print("    {s} =l loadl {s}\n", .{ fv, addr });
            try self.destroyNonArcValue(fv, f.info.heap);
        }
    }
    try self.out.writer.print("    call $nox_rc_free_payload(l {s}, l %p, l {d})\n", .{ RT_PARAM, cinfo.total_size });
    try self.out.writer.print("    jmp {s}\n", .{done_label});
    try self.out.writer.print("{s}\n", .{done_label});
    try self.out.writer.writeAll("    ret\n}\n");
}

/// Faz S.3: HER sınıf İÇİN `$ClassName_trace(rt, p) -> l` üretir —
/// `p`nin SINIF-TİPLİ alanlarının DEĞERLERİNİ küçük, `nox_alloc`'lu bir
/// arabelleğe (8 baytlık `l` uzunluk BAŞLIĞI + N adet `l` çocuk
/// işaretçisi — `genListLit`in AYNI bayt düzeni) yazıp döner;
/// `runtime/alloc/cycle_detector.zig`nin `traceChildren`i OKUDUKTAN
/// SONRA bu arabelleği `nox_free`lemekle YÜKÜMLÜDÜR. HER sınıf İÇİN
/// (sınıf-tipli alanı OLMASA BİLE, `genClassRelease`/`genClassEq` İLE
/// TUTARLI biçimde KOŞULSUZ) üretilir — bir sınıf ÖRNEĞİ, KENDİSİ HİÇ
/// döngü KAYNAĞI olamasa BİLE, BAŞKA bir sınıfın alanı olarak döngü
/// çözücü tarafından KEŞFEDİLİP `nox_gc_free_dispatch`e (bkz.
/// `genClassGcFree`) YÖNLENDİRİLEBİLİR — dağıtım fonksiyonlarının HER
/// sınıf İÇİN bir DALI olması GEREKİR (bkz. `genTraceDispatch`).
pub fn genClassTrace(self: *Codegen, class_name: []const u8, cinfo: ClassInfo) CodegenError!void {
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

    var class_fields: std.ArrayListUnmanaged(ClassField) = .empty;
    defer class_fields.deinit(self.allocator);
    for (cinfo.fields.items) |f| {
        if (f.info.heap == .class) try class_fields.append(self.allocator, f);
    }

    try self.out.writer.print("export function l ${s}_trace(l {s}, l %p) {{\n@start\n", .{ class_name, RT_PARAM });
    const buf = try self.newTemp();
    try self.out.writer.print("    {s} =l call $nox_alloc(l {s}, l {d})\n", .{ buf, RT_PARAM, TRACE_BUF_LEN_SIZE + class_fields.items.len * TRACE_BUF_SLOT_SIZE });
    try self.out.writer.print("    storel {d}, {s}\n", .{ class_fields.items.len, buf });
    for (class_fields.items, 0..) |f, i| {
        const addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add %p, {d}\n", .{ addr, f.offset });
        const fv = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ fv, addr });
        const slot = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ slot, buf, TRACE_BUF_LEN_SIZE + i * TRACE_BUF_SLOT_SIZE });
        try self.out.writer.print("    storel {s}, {s}\n", .{ fv, slot });
    }
    try self.out.writer.print("    ret {s}\n}}\n", .{buf});
}

/// Faz S.3: HER sınıf İÇİN `$ClassName_gc_free(rt, p)` üretir —
/// `collectWhite`in (bkz. `cycle_detector.zig`) ÇAĞIRDIĞI, `$ClassName_
/// release`DEN KASITLI olarak FARKLI bir temizlik yolu: SINIF-TİPLİ
/// OLMAYAN alanları (str/list/Task/Channel/dict) NORMAL şekilde serbest
/// bırakır, ama SINIF-TİPLİ alanlara HİÇ DOKUNMAZ (ne release ne
/// predecrement) — onlar `collectWhite`in KENDİ özyinelemeli çağrısıyla
/// AYRICA (VE YALNIZCA bir kez) ele alınır; burada da dokunulsaydı ÇİFT
/// serbest bırakma OLURDU. Nesnenin KENDİ belleği SONRA KOŞULSUZ (bkz.
/// `nox_rc_free_payload` — predecrement OLMADAN, çünkü çöp olduğu
/// döngü çözücü TARAFINDAN ZATEN KANITLANMIŞTIR) serbest bırakılır.
pub fn genClassGcFree(self: *Codegen, class_name: []const u8, cinfo: ClassInfo) CodegenError!void {
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

    try self.out.writer.print("export function ${s}_gc_free(l {s}, l %p) {{\n@start\n", .{ class_name, RT_PARAM });
    for (cinfo.fields.items) |f| {
        if (f.info.heap == .class) continue; // bkz. yukarıdaki belge notu
        if (isHeapManaged(f.info.heap)) {
            const addr = try self.newTemp();
            try self.out.writer.print("    {s} =l add %p, {d}\n", .{ addr, f.offset });
            const fv = try self.newTemp();
            try self.out.writer.print("    {s} =l loadl {s}\n", .{ fv, addr });
            try self.releaseValueIfSet(fv, f.info.heap, f.info.elem_qtype, f.info.class_name, f.info.elem_heap_info, f.info.dict_info);
        } else if (f.info.heap == .task or f.info.heap == .channel or f.info.heap == .thread_handle or f.info.heap == .thread_channel) {
            const addr = try self.newTemp();
            try self.out.writer.print("    {s} =l add %p, {d}\n", .{ addr, f.offset });
            const fv = try self.newTemp();
            try self.out.writer.print("    {s} =l loadl {s}\n", .{ fv, addr });
            try self.destroyNonArcValue(fv, f.info.heap);
        }
    }
    try self.out.writer.print("    call $nox_rc_free_payload(l {s}, l %p, l {d})\n", .{ RT_PARAM, cinfo.total_size });
    try self.out.writer.writeAll("    ret\n}\n");
}

/// Faz S.3: `$nox_trace_dispatch(rt, tag, p) -> l` — `runtime/alloc/
/// cycle_detector.zig`nin ÇALIŞMA ZAMANI sınıf ETİKETİNE (`tag`, bkz.
/// `TAG_SIZE`) göre doğru `$ClassName_trace`ye dal açan bir if-zinciri
/// (QBE'de `switch` YOK). Eşleşen bir dal BULUNAMAZSA (savunmacı — HER
/// GERÇEK sınıf örneğinin tag'i BİLİNEN bir `class_id`dir, bu dal ASLA
/// tetiklenMEMELİDİR) boş (uzunluk=0) bir arabellek döner.
pub fn genTraceDispatch(self: *Codegen, classes: []const ClassIdEntry) CodegenError!void {
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

    try self.out.writer.print("export function l $nox_trace_dispatch(l {s}, l %tag, l %p) {{\n@start\n", .{RT_PARAM});
    for (classes) |c| {
        const eq = try self.newTemp();
        try self.out.writer.print("    {s} =w ceql %tag, {d}\n", .{ eq, c.id });
        const case_label = try self.newLabel("trace_case");
        const next_label = try self.newLabel("trace_next");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ eq, case_label, next_label });
        try self.out.writer.print("{s}\n", .{case_label});
        const r = try self.newTemp();
        try self.out.writer.print("    {s} =l call ${s}_trace(l {s}, l %p)\n", .{ r, c.name, RT_PARAM });
        try self.out.writer.print("    ret {s}\n", .{r});
        try self.out.writer.print("{s}\n", .{next_label});
    }
    const empty = try self.newTemp();
    try self.out.writer.print("    {s} =l call $nox_alloc(l {s}, l {d})\n", .{ empty, RT_PARAM, TRACE_BUF_LEN_SIZE });
    try self.out.writer.print("    storel 0, {s}\n", .{empty});
    try self.out.writer.print("    ret {s}\n}}\n", .{empty});
}

/// `genTraceDispatch` İLE AYNI desen, `$ClassName_gc_free`ye dağıtan
/// `$nox_gc_free_dispatch(rt, tag, p)` (dönüş değeri YOK).
pub fn genGcFreeDispatch(self: *Codegen, classes: []const ClassIdEntry) CodegenError!void {
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

    try self.out.writer.print("export function $nox_gc_free_dispatch(l {s}, l %tag, l %p) {{\n@start\n", .{RT_PARAM});
    for (classes) |c| {
        const eq = try self.newTemp();
        try self.out.writer.print("    {s} =w ceql %tag, {d}\n", .{ eq, c.id });
        const case_label = try self.newLabel("gc_free_case");
        const next_label = try self.newLabel("gc_free_next");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ eq, case_label, next_label });
        try self.out.writer.print("{s}\n", .{case_label});
        try self.out.writer.print("    call ${s}_gc_free(l {s}, l %p)\n", .{ c.name, RT_PARAM });
        try self.out.writer.writeAll("    ret\n");
        try self.out.writer.print("{s}\n", .{next_label});
    }
    try self.out.writer.writeAll("    ret\n}\n");
}

/// Her sınıf için `$ClassName_eq(rt, a, b) w` üretir — Python'un varsayılan
/// `__eq__`inin AKSİNE (kimlik/`is` karşılaştırması), Nox'ta `==`/`!=`
/// PYTHON'daki `dataclass`lar gibi ALAN ALANA YAPISAL karşılaştırmadır
/// (bkz. görev "list/class için derin yapısal eşitlik"). Alanı olmayan
/// bir sınıf (bkz. `ClassInfo.has_init`) için sonuç her zaman `1`dir (iki
/// örnek yapısal olarak her zaman "eşit"tir — kimlik önemsizdir). Her alan
/// için `genEqCompareOrJump` kullanılır (bkz. onun belge notu — NEDEN
/// alloc/yığın yuvası KULLANILMADIĞI için).
pub fn genClassEq(self: *Codegen, class_name: []const u8, cinfo: ClassInfo) CodegenError!void {
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

    try self.out.writer.print("export function w ${s}_eq(l {s}, l %a, l %b) {{\n@start\n", .{ class_name, RT_PARAM });
    const mismatch_label = try self.newLabel("classeq_mismatch");
    for (cinfo.fields.items) |f| {
        const addr_a = try self.newTemp();
        try self.out.writer.print("    {s} =l add %a, {d}\n", .{ addr_a, f.offset });
        const addr_b = try self.newTemp();
        try self.out.writer.print("    {s} =l add %b, {d}\n", .{ addr_b, f.offset });
        const va = try self.newTemp();
        try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ va, qbeTypeName(f.info.qtype), qbeTypeName(f.info.qtype), addr_a });
        const vb = try self.newTemp();
        try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ vb, qbeTypeName(f.info.qtype), qbeTypeName(f.info.qtype), addr_b });
        try self.genEqCompareOrJump(va, vb, f.info.qtype, f.info.heap, f.info.class_name, f.info.elem_qtype, f.info.elem_heap_info, f.info.elem_is_str, mismatch_label, null);
    }
    try self.out.writer.writeAll("    ret 1\n");
    try self.out.writer.print("{s}\n", .{mismatch_label});
    try self.out.writer.writeAll("    ret 0\n}\n");
}

/// Verilen iki (zaten yüklenmiş) `w`/`l`/`d` değerini `heap`/`class_name`/
/// `elem_*` betimleyicisine göre karşılaştırır: uyuşmuyorsa `mismatch_label`e
/// ATLAR, uyuşuyorsa NORMAL AKIŞA (çağıranın bir sonraki satırına) DEVAM
/// EDER — bir DEĞER DÖNDÜRMEZ. Bu BİLİNÇLİ bir tasarım: `heap == .class`/
/// `.list` durumunda (`va`/`vb` NULL OLABİLİR — bkz. `__init__`in koşullu
/// bir dalda alan atlaması bilinen sınırlaması) sonucu bir dal SONRASI
/// TEK bir değere birleştirmek ya QBE'nin `phi`sini ya da bir yığın
/// yuvasını (`alloc4`/`alloc8`) gerektirirdi — İKİNCİSİ, bu fonksiyon bir
/// KULLANICI DÖNGÜSÜ içinden çağrılan `==`/`!=`de (bkz. `genBinary`) HER
/// yinelemede tekrar tekrar çalışıp QBE'nin fonksiyon-girişi-tahsisi
/// varsayımını ihlal ederek yığın taşmasına yol açardı (bkz. §3.16'daki
/// AYNI hata sınıfı, `adjustModSign`/`genForList`). Çözüm: hiç DEĞER
/// TAŞIMADAN, doğrudan `mismatch_label`e ATLAMAK ya da DEVAM ETMEK —
/// `genClassEq`/`genListEq`nin KENDİ döngü/alan yapısı zaten "eşleşmedi ->
/// dışarı" ile "eşleşti -> bir sonraki alan/elemana geç" ayrımını doğal
/// olarak taşıdığından, ayrı bir taşınabilir değere hiç gerek YOKTUR.
/// `success_label` (opsiyonel): VERİLMİŞSE, BAŞARILI karşılaştırma
/// SONRASI (bu fonksiyonun KENDİ İÇ `cont_label`ine düşmenin HEMEN
/// ARDINDAN) KOŞULSUZ olarak ORAYA sıçranır — genListEq'in bulgu #4
/// düzeltmesi (bkz. onun belge notu) BUNU, döngü-taşınan sayacın
/// `phi`sinin DOĞRU ÖNCÜL (predecessor) blok ADINI ÖNCEDEN (bu
/// fonksiyon HİÇ ÇAĞRILMADAN ÖNCE `newLabel` İLE) BİLMESİ İçin
/// KULLANIR (QBE, phi'nin öncüllerinin GERÇEK kontrol-akışıyla TAM
/// eşleşmesini ZORUNLU kılar — bu fonksiyonun KENDİ İÇİNDE AYRICA
/// bloklar AÇTIĞI İçin çağıranın "en son yazdığım blok" TAHMİNİ
/// GÜVENİLMEZDİR; `success_label` bunu ÇAĞIRANIN KENDİ KONTROLÜNE
/// verir). `null` İSE (genClassEq'in AYNI, DEĞİŞMEMİŞ kullanımı)
/// eski davranış AYNEN korunur: düz düşme, sonraki alan kontrolü
/// hemen ARDINDAN gelir.
pub fn genEqCompareOrJump(
    self: *Codegen,
    va: []const u8,
    vb: []const u8,
    qtype: QbeType,
    heap: HeapKind,
    class_name: ?[]const u8,
    elem_qtype: QbeType,
    elem_heap_info: ?*const ElemHeapInfo,
    elem_is_str: bool,
    mismatch_label: []const u8,
    success_label: ?[]const u8,
) CodegenError!void {
    if (heap == .none) {
        const t = try self.newTemp();
        const mnemonic: []const u8 = switch (qtype) {
            .l => "ceql",
            .w => "ceqw",
            .d => "ceqd",
            .none => unreachable,
        };
        try self.out.writer.print("    {s} =w {s} {s}, {s}\n", .{ t, mnemonic, va, vb });
        const cont_label = try self.newLabel("eqcmp_cont");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ t, cont_label, mismatch_label });
        try self.out.writer.print("{s}\n", .{cont_label});
        if (success_label) |sl| try self.out.writer.print("    jmp {s}\n", .{sl});
        return;
    }
    if (heap == .str) {
        const cmp = try self.newTemp();
        try self.out.writer.print("    {s} =w call $strcmp(l {s}, l {s})\n", .{ cmp, va, vb });
        const cont_label = try self.newLabel("eqcmp_cont");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ cmp, mismatch_label, cont_label });
        try self.out.writer.print("{s}\n", .{cont_label});
        if (success_label) |sl| try self.out.writer.print("    jmp {s}\n", .{sl});
        return;
    }

    // `heap == .class` ya da `.list` — NULL olabilir (bkz. belge notu).
    const a_null = try self.newTemp();
    try self.out.writer.print("    {s} =w ceql {s}, 0\n", .{ a_null, va });
    const b_null = try self.newTemp();
    try self.out.writer.print("    {s} =w ceql {s}, 0\n", .{ b_null, vb });
    const either_null = try self.newTemp();
    try self.out.writer.print("    {s} =w or {s}, {s}\n", .{ either_null, a_null, b_null });
    const null_case_label = try self.newLabel("eqcmp_nullcase");
    const rec_label = try self.newLabel("eqcmp_rec");
    const cont_label = try self.newLabel("eqcmp_cont");
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ either_null, null_case_label, rec_label });
    try self.out.writer.print("{s}\n", .{null_case_label});
    const both_null = try self.newTemp();
    try self.out.writer.print("    {s} =w and {s}, {s}\n", .{ both_null, a_null, b_null });
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ both_null, cont_label, mismatch_label });
    try self.out.writer.print("{s}\n", .{rec_label});
    const rec: []const u8 = switch (heap) {
        .class => blk: {
            const t = try self.newTemp();
            try self.out.writer.print("    {s} =w call ${s}_eq(l {s}, l {s}, l {s})\n", .{ t, class_name.?, RT_PARAM, va, vb });
            break :blk t;
        },
        .list => blk: {
            const fn_name = try self.eqFnNameForList(elem_qtype, elem_heap_info, elem_is_str);
            const t = try self.newTemp();
            try self.out.writer.print("    {s} =w call ${s}_eq(l {s}, l {s}, l {s})\n", .{ t, fn_name, RT_PARAM, va, vb });
            break :blk t;
        },
        // `dict`/`Task`/`Channel` — opak tutamaçlar, YAPISAL derinlemesine
        // eşitliği YOK (stdlib fazı §C'nin `dict` KAPSAM dışı bıraktığı
        // bir özellik, bkz. checker.zig). `HttpResponse.headers` gibi bir
        // `dict[str,str]` sınıf ALANI, HER sınıf İÇİN OTOMATİK üretilen
        // `$ClassName_eq`de (kullanıcı `==` HİÇ kullanmasa BİLE) bu dala
        // düşer — güvenli varsayılan: TUTAMAÇ KİMLİĞİ (pointer) karşılaştırması.
        // Faz U.4.3: closure değerleri henüz `==` karşılaştırmasını
        // DESTEKLEMİYOR (checker bu dala HİÇ düşürmemeli) — savunmacı
        // olarak `dict`/`Task`/`Channel` İLE AYNI tutamaç-kimliği
        // (pointer) karşılaştırmasına düşülür.
        // Faz FF.6.4: `list[int | None]` gibi bir kutulanmış-Optional
        // ELEMANLI liste (v1'de HİÇBİR golden fixture'ın EGZERSİZ
        // ETMEDİĞİ, ama exhaustive switch GEREKSİNİMİYLE buraya düşen
        // bir kombinasyon) — GÜVENLİ/tutucu bir varsayılan olarak
        // `dict`/`Task`/`Channel` İLE AYNI tutamaç-kimliği (pointer)
        // karşılaştırmasına düşülür (DEĞER eşitliği DEĞİL) — İKİ AYRI
        // kutunun AYNI değeri TAŞISA BİLE eşit SAYILMAYACAĞI, bilinçli
        // bir v1 sınırlamasıdır.
        .dict, .task, .channel, .closure, .thread_handle, .thread_channel, .boxed_scalar => blk: {
            const t = try self.newTemp();
            try self.out.writer.print("    {s} =w ceql {s}, {s}\n", .{ t, va, vb });
            break :blk t;
        },
        .none, .str => unreachable,
    };
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ rec, cont_label, mismatch_label });
    try self.out.writer.print("{s}\n", .{cont_label});
    if (success_label) |sl| try self.out.writer.print("    jmp {s}\n", .{sl});
}

/// `releaseFnNameFor` ile AYNI özyineli mangling şeması, ama derin
/// yapısal eşitlik İÇİN: `str` elemanlar `int`/`float`/`bool`dan (`prim*`)
/// AYRI bir ad alır — release'in aksine eşitlik `strcmp` ile `ceq*`i
/// KARIŞTIRAMAZ (bkz. `list_eq_queue`nin belge notu).
pub fn eqMangleFor(self: *Codegen, elem_qtype: QbeType, elem_heap_info: ?*const ElemHeapInfo, elem_is_str: bool) CodegenError![]const u8 {
    if (elem_heap_info) |ehi| {
        return switch (ehi.heap) {
            .class => ehi.class_name.?,
            .str => "str",
            .list => blk: {
                const inner = try self.eqMangleFor(ehi.elem_qtype, ehi.nested, ehi.elem_is_str);
                break :blk try std.fmt.allocPrint(self.allocator, "List_{s}", .{inner});
            },
            // `dict`/`Task`/`Channel`/`closure`/iş parçacığı tutamaçları/
            // kutulanmış-Optional — `genEqCompareOrJump`nin AYNI dalıyla
            // (yukarıdaki `.dict, .task, .channel, .closure, ...` durumu)
            // TUTARLI: bu türlerin YAPISAL derinlemesine eşitliği YOK,
            // yalnızca tutamaç-kimliği (pointer) karşılaştırılır — bu
            // YÜZDEN `$List_<mangled>_eq`nin adı İçin de sadece BİRBİRİNDEN
            // AYIRT EDİLEBİLİR bir etiket YETERLİDİR (gövdesi zaten
            // `genEqCompareOrJump` ÜZERİNDEN doğru pointer-eşitliğine
            // düşer). **Bulundu, GERÇEK bir çökme:** `list[(T)->U]` gibi
            // bir SINIF ALANI, HER sınıf İçin OTOMATİK üretilen
            // `$ClassName_eq`de (kullanıcı `==` HİÇ kullanmasa BİLE) BU
            // dala düşer (`nox.router`nin `Router.before`si — `Router|None`
            // karşılaştırması İçin DEĞİL, ama `genClassEq`nin TÜM alanları
            // KOŞULSUZ ziyaret etmesi YÜZÜNDEN) — ÖNCEDEN `unreachable`e
            // düşüp ÇÖKÜYORDU.
            .dict => "dict",
            .task => "task",
            .channel => "channel",
            .closure => "closure",
            .thread_handle => "thread_handle",
            .thread_channel => "thread_channel",
            .boxed_scalar => "boxed_scalar",
            .none => unreachable,
        };
    }
    if (elem_is_str) return "str";
    return try std.fmt.allocPrint(self.allocator, "prim{s}", .{qbeTypeName(elem_qtype)});
}

/// Bir `list[T]`nin (elemanları `elem_qtype`/`elem_heap_info`/`elem_is_str`
/// ile betimlenen) `$List_<mangled>_eq`ini ister — ilk istekte
/// `list_eq_queue`ya TEMBEL kaydedilir (`list_release_queue` ile AYNI
/// desen, bkz. `releaseFnNameFor`).
pub fn eqFnNameForList(self: *Codegen, elem_qtype: QbeType, elem_heap_info: ?*const ElemHeapInfo, elem_is_str: bool) CodegenError![]const u8 {
    const inner = try self.eqMangleFor(elem_qtype, elem_heap_info, elem_is_str);
    const name = try std.fmt.allocPrint(self.allocator, "List_{s}", .{inner});
    if (!self.list_eq_seen.contains(name)) {
        try self.list_eq_seen.put(self.allocator, name, {});
        try self.list_eq_queue.append(self.allocator, .{ .name = name, .elem_qtype = elem_qtype, .elem_heap_info = elem_heap_info, .elem_is_str = elem_is_str });
    }
    return name;
}

/// `eqFnNameForList`in kuyruğa aldığı `$List_<name>_eq(rt, a, b) w`i
/// üretir: önce uzunlukları karşılaştırır (farklıysa hemen `0`), sonra
/// elemanları TEK TEK (`genEqCompareOrJump` ile) karşılaştırır — ilk
/// uyuşmazlıkta erken `0` döner (kısa devre), tümü eşleşirse `1`.
pub fn genListEq(self: *Codegen, name: []const u8, elem_qtype: QbeType, elem_heap_info: ?*const ElemHeapInfo, elem_is_str: bool) CodegenError!void {
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

    try self.out.writer.print("export function w ${s}_eq(l {s}, l %a, l %b) {{\n@start\n", .{ name, RT_PARAM });
    const len_a = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl %a\n", .{len_a});
    const len_b = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl %b\n", .{len_b});
    const len_diff = try self.newTemp();
    try self.out.writer.print("    {s} =w cnel {s}, {s}\n", .{ len_diff, len_a, len_b });
    const false_label = try self.newLabel("listeq_lendiff");
    const loop_init_label = try self.newLabel("listeq_init");
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ len_diff, false_label, loop_init_label });
    try self.out.writer.print("{s}\n", .{loop_init_label});

    const cond_label = try self.newLabel("listeq_cond");
    const body_label = try self.newLabel("listeq_body");
    const true_label = try self.newLabel("listeq_true");
    // Bkz. AŞAĞIDAKİ `phi`nin belge notu — bu etiket, `genEqCompareOrJump`
    // TAMAMLANDIKTAN SONRA GERÇEKTEN `cond_label`e sıçrayan bloğun
    // ADIDIR; ÖNCEDEN (o fonksiyon HİÇ ÇAĞRILMADAN) burada oluşturulur
    // kİ `phi`nin öncül-blok adı DOĞRU olsun (bkz. `genEqCompareOrJump`nin
    // `success_label` parametresinin belge notu — bu fonksiyon KENDİ
    // İÇİNDE AYRICA bloklar AÇTIĞINDAN "en son yazdığım blok" TAHMİNİ
    // GÜVENİLMEZ, GERÇEK bir `qbe` HATASIYLA kanıtlandı: "predecessors
    // not matched in phi").
    const backedge_label = try self.newLabel("listeq_backedge");

    // Darboğaz analizi bulgu #4 (bkz. benchmarks/RESULTS.md, 2026-07-22):
    // döngü sayacı ESKİDEN bir yığın slotuna (`alloc8`) yazılıp HER
    // yinelemede geri okunuyordu — ama ÜRETİLEN ARM64 kodu okunduğunda
    // (`_List_priml_eq`) QBE'nin KENDİ register ayırıcısının sayacı
    // ZATEN TEK bir yazmaçta (`x0`) tuttuğu, "geri okuma"yı KENDİSİ
    // baştan savarak ATLADIĞI (`L234` etiketinde HİÇ `ldr` YOK)
    // GÖRÜLDÜ — ama `str`in KENDİSİ (kimse OKUMASA bile) HER yinelemede
    // ÇALIŞMAYA devam ediyordu (klasik "ölü mağaza", QBE'nin KENDİSİ bu
    // özel optimizasyonu YAPMIYOR). Çözüm: bellek/slot HİÇ kullanmadan
    // QBE'nin KENDİ `phi` talimatıyla (döngü-taşınan bir SSA değeri
    // İçin standart, uygun ARAÇ) `idx_cur`ı DOĞRUDAN ifade etmek — bu
    // fonksiyonun kontrol AKIŞI SABİT VE BASİT olduğundan (kullanıcı
    // AST'sinden TÜRETİLMEMİŞ, TEK bir döngü, dallanmasız artış) `phi`
    // BURADA güvenle uygulanabilir (genel `genFor*`/`genWhile`
    // fonksiyonlarının AKSİNE, ONLAR keyfi iç içe kullanıcı kontrol
    // akışını İŞLEMEK ZORUNDA, bu YÜZDEN slot-tabanlı SAĞLAM deseni
    // KORUR). Doğrulama: `qbe`nin ÜRETTİĞİ ARM64'te ARTIK NE `alloc8`/
    // `sub sp` NE DE bir `str`/`ldr` ÇİFTİ VAR — sayaç TAMAMEN TEK bir
    // yazmaçta YAŞIYOR.
    try self.out.writer.print("    jmp {s}\n", .{cond_label});
    try self.out.writer.print("{s}\n", .{cond_label});
    const idx_cur = try self.newTemp();
    const idx_next = try self.newTemp();
    try self.out.writer.print("    {s} =l phi {s} 0, {s} {s}\n", .{ idx_cur, loop_init_label, backedge_label, idx_next });
    const cont = try self.newTemp();
    try self.out.writer.print("    {s} =w csltl {s}, {s}\n", .{ cont, idx_cur, len_a });
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ cont, body_label, true_label });
    try self.out.writer.print("{s}\n", .{body_label});

    const off = try self.newTemp();
    try self.out.writer.print("    {s} =l mul {s}, {d}\n", .{ off, idx_cur, qbeSizeOf(elem_qtype) });
    const off8 = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ off8, off, LIST_HEADER_SIZE });
    const addr_a = try self.newTemp();
    try self.out.writer.print("    {s} =l add %a, {s}\n", .{ addr_a, off8 });
    const addr_b = try self.newTemp();
    try self.out.writer.print("    {s} =l add %b, {s}\n", .{ addr_b, off8 });
    const ea = try self.newTemp();
    try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ ea, qbeTypeName(elem_qtype), qbeTypeName(elem_qtype), addr_a });
    const eb = try self.newTemp();
    try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ eb, qbeTypeName(elem_qtype), qbeTypeName(elem_qtype), addr_b });
    const elem_heap: HeapKind = if (elem_heap_info) |ehi| ehi.heap else if (elem_is_str) .str else .none;
    const elem_class_name: ?[]const u8 = if (elem_heap_info) |ehi| ehi.class_name else null;
    try self.genEqCompareOrJump(ea, eb, elem_qtype, elem_heap, elem_class_name, if (elem_heap_info) |ehi| ehi.elem_qtype else .none, if (elem_heap_info) |ehi| ehi.nested else null, if (elem_heap_info) |ehi| ehi.elem_is_str else false, false_label, backedge_label);
    try self.out.writer.print("{s}\n", .{backedge_label});
    try self.out.writer.print("    {s} =l add {s}, 1\n", .{ idx_next, idx_cur });
    try self.out.writer.print("    jmp {s}\n", .{cond_label});
    try self.out.writer.print("{s}\n", .{true_label});
    try self.out.writer.writeAll("    ret 1\n");
    try self.out.writer.print("{s}\n", .{false_label});
    try self.out.writer.writeAll("    ret 0\n}\n");
}
