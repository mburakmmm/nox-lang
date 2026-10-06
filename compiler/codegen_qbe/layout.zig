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
const llvm_emit = @import("llvm_emit.zig");

const Codegen = codegen.Codegen;
const QbeType = types.QbeType;
const HeapKind = types.HeapKind;
const ElemHeapInfo = types.ElemHeapInfo;
const DictInfo = types.DictInfo;
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
const escapeForQbeString = abi.escapeForQbeString;

/// Faz 7 (tekli kalıtım): `cinfo.has_vtable` İSE bu SOMUT sınıfın vtable
/// veri bloğunu YAYINLAR — `data $ClassName_vtable = { l $Owner1_M1, l
/// $Owner2_M2, ... }`, slot SIRASINA göre (0..`next_vtable_slot`-1). HER
/// slot İçin o slotu TAŞIYAN metod adını `cinfo.methods`de ARAYIP
/// `owner`ını KULLANARAK gerçek sembolü yazar — miras alınan (override
/// EDİLMEMİŞ) bir slot İçin bu, ATANIN sembolüdür (bu SINIFIN KENDİ
/// sembolü DEĞİL). `genMethodCall`in dolaylı çağrı yolu BU bloğu
/// `loadl $ClassName_vtable + slot*8` İLE OKUR; `genConstructFromValues`
/// bu bloğun ADRESİNİ HER yeni örneğe (TAG'den HEMEN SONRA) yazar.
pub fn genClassVtable(self: *Codegen, class_name: []const u8, cinfo: ClassInfo) CodegenError!void {
    if (!cinfo.has_vtable or cinfo.next_vtable_slot == 0) return;
    const slots = try self.allocator.alloc(?struct { owner: []const u8, name: []const u8 }, cinfo.next_vtable_slot);
    @memset(slots, null);
    var it = cinfo.methods.iterator();
    while (it.next()) |e| {
        slots[e.value_ptr.slot] = .{ .owner = e.value_ptr.owner, .name = e.key_ptr.* };
    }
    // Faz LLVM.5 (bkz. plan dosyası "`noxc build --release` için deneysel
    // bir LLVM backend'i"): `core.nox`nin (Exception/ValueError/...)
    // KOŞULSUZ HER programa birleştirilmesi YÜZÜNDEN sınıf-makinesi
    // (vtable/release/trace/gc_free/name-dispatch) LİTERALDE "sınıf
    // kullanmayan" bir program TARAFINDAN BİLE tetiklenir — bu YÜZDEN bu
    // metot de (SIBLING dosyaların geri kalanının AKSİNE, `qbe_emit`/
    // `llvm_emit` seam'İNİN DIŞINDA) DOĞRUDAN `self.backend`e göre
    // dallanır — `generateModule`nin KENDİ direkt-yazıcı sitelerinin
    // (bkz. onun belge notu) AYNI deseni.
    if (self.backend == .qbe) {
        try self.qbeRaw("data ${s}_vtable = {{ ", .{class_name});
        for (slots, 0..) |s, i| {
            if (i > 0) try self.qbeRawAll(", ");
            // Her slot HER ZAMAN bir metod TARAFINDAN doldurulmuş OLMALIDIR —
            // `registerClass` HER hiyerarşi seviyesinde TÜM önceki slotları
            // (miras yoluyla) KORUR, hiçbiri asla BOŞ kalmaz.
            const entry = s.?;
            try self.qbeRaw("l ${s}_{s}", .{ entry.owner, entry.name });
        }
        try self.qbeRawAll(" }\n");
    } else {
        const syms = try self.allocator.alloc([]const u8, slots.len);
        for (slots, 0..) |s, i| {
            const entry = s.?;
            syms[i] = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ entry.owner, entry.name });
        }
        const vtable_name = try std.fmt.allocPrint(self.allocator, "{s}_vtable", .{class_name});
        const line = try llvm_emit.llvmPtrArrayConstant(self.allocator, vtable_name, syms);
        try self.out.writer.writeAll(line);
    }
}

/// v1.142.0 (bkz. nox-teknik-spesifikasyon.md §3.240): bir sınıf örneği
/// YALNIZCA tip-düzeyi "işaret eder" grafında kendisine dönen bir yol
/// VARSA bir referans döngüsünün üyesi OLABİLİR. Kenarlar, `genClassTrace`in
/// İZLEDİĞİ alanlarla AYNIDIR (sınıf-tipli alan, `list[Sınıf]` elemanı,
/// `dict[K, Sınıf]` değeri); bir alanın hedef tipi `T` ise ÇALIŞMA ZAMANI
/// değeri `T`nin HERHANGİ bir alt sınıfı da OLABİLİR (alt sınıf örneği
/// ek alanlar taşıyabilir), bu yüzden kenar `T`nin TÜM alt-ağacına gider.
/// Hedef sınıf adı bilinmeyen bir alan (savunmacı) TÜM sınıflara kenar sayılır.
///
/// Sonuç: bir döngü ASLA kendi üyesi OLMAYAN bir sınıfın örneğini "olası
/// kök" olarak GEREKTİRMEZ — döngünün son dış referansı bırakıldığında
/// kaydedilmesi gereken düğümler DÖNGÜNÜN ÜYELERİDİR (onlar da bu kümededir);
/// döngüye yalnızca İŞARET EDEN bir sahip (ör. bir `list[JsonValue]` tutan
/// `ValidatedBody`) sıfıra düştüğünde zaten serbest bırakılır ve alanlarını
/// bırakır. `genClassRelease` bu yüzden `nox_cycle_possible_root`u (global
/// kilit + hash-map yazımı) YALNIZCA bu kümedeki sınıflar İçin yayınlar.
pub fn computeCyclicClasses(self: *Codegen) CodegenError!void {
    const a = self.allocator;
    self.cyclic_classes.deinit(a);
    self.cyclic_classes = .empty;

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(a);
    var index_of: std.StringHashMapUnmanaged(usize) = .empty;
    defer index_of.deinit(a);
    var it = self.classes.iterator();
    while (it.next()) |e| {
        try index_of.put(a, e.key_ptr.*, names.items.len);
        try names.append(a, e.key_ptr.*);
    }
    const n = names.items.len;
    if (n == 0) return;

    // subtree[t] = t ve tüm (dolaylı) alt sınıflarının indeksleri.
    const subtree = try a.alloc(std.ArrayListUnmanaged(usize), n);
    defer {
        for (subtree) |*l| l.deinit(a);
        a.free(subtree);
    }
    for (subtree) |*l| l.* = .empty;
    for (names.items, 0..) |nm, i| {
        var cur: ?[]const u8 = nm;
        var guard: usize = 0;
        while (cur) |c| : (guard += 1) {
            if (guard > n) break; // savunmacı: bozuk (döngüsel) kalıtım
            const ci = index_of.get(c) orelse break;
            try subtree[ci].append(a, i);
            cur = self.classes.get(c).?.base;
        }
    }

    // adj[r] = r'nin alanlarının işaret edebildiği sınıf indeksleri.
    const adj = try a.alloc(std.ArrayListUnmanaged(usize), n);
    defer {
        for (adj) |*l| l.deinit(a);
        a.free(adj);
    }
    for (adj) |*l| l.* = .empty;
    for (names.items, 0..) |nm, r| {
        const cinfo = self.classes.get(nm).?;
        for (cinfo.fields.items) |f| {
            var unknown = false;
            if (f.info.heap == .class) {
                if (f.info.class_name) |t| {
                    if (index_of.get(t)) |ti| try adj[r].appendSlice(a, subtree[ti].items) else unknown = true;
                } else unknown = true;
            } else if (f.info.heap == .list or f.info.heap == .dict) {
                // Eleman/değer zincirini (iç içe list[list[Sınıf]] DAHİL) gez.
                var eh: ?*const ElemHeapInfo = f.info.elem_heap_info;
                while (eh) |h| : (eh = h.nested) {
                    if (h.heap == .class) {
                        if (h.class_name) |t| {
                            if (index_of.get(t)) |ti| try adj[r].appendSlice(a, subtree[ti].items) else unknown = true;
                        } else unknown = true;
                    }
                }
                if (f.info.heap == .dict) {
                    if (f.info.dict_info) |di| {
                        if (di.value_is_class) {
                            if (di.value_class_name) |t| {
                                if (index_of.get(t)) |ti| try adj[r].appendSlice(a, subtree[ti].items) else unknown = true;
                            } else unknown = true;
                        }
                    }
                }
            }
            if (unknown) {
                var all: usize = 0;
                while (all < n) : (all += 1) try adj[r].append(a, all);
            }
        }
    }

    // r döngüsel <=> r'den başlayıp r'ye dönen en az bir kenarlı yol var.
    const visited = try a.alloc(bool, n);
    defer a.free(visited);
    var stack: std.ArrayListUnmanaged(usize) = .empty;
    defer stack.deinit(a);
    for (names.items, 0..) |nm, r| {
        @memset(visited, false);
        stack.clearRetainingCapacity();
        for (adj[r].items) |s| try stack.append(a, s);
        var found = false;
        while (stack.pop()) |u| {
            if (u == r) {
                found = true;
                break;
            }
            if (visited[u]) continue;
            visited[u] = true;
            for (adj[u].items) |v| if (!visited[v] or v == r) try stack.append(a, v);
        }
        if (found) try self.cyclic_classes.put(a, nm, {});
    }
}

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
    // v3 madde 3 (ownership/ptr[T] red-team, bkz. nox-teknik-
    // spesifikasyon.md ilgili bölüm): **DÜZELTME (GERÇEK, bu turun
    // ASIL kök nedeni — `genClassTrace`/`genClassGcFree`nin list/dict
    // düzeltmeleri TEK BAŞINA YETERSİZDİ)** — bu bayrak ÖNCEDEN SADECE
    // `f.info.heap == .class` alanlarını sayıyordu; bir sınıfın TEK
    // "döngü kaynağı" olabilme yolu `list[ClassType]`/`dict[K,
    // ClassType]` alanlarıysa (`Node`nin `children: list[Node]` alanı
    // GİBİ), `has_class_field` HİÇBİR ZAMAN `true` OLMUYOR — bu YÜZDEN
    // `nox_cycle_possible_root` HİÇ ÇAĞRILMIYOR, nesne predecrement
    // sıfıra düşmediğinde (GERÇEK bir döngünün parçası OLDUĞUNDA) YALNIZ
    // BAŞINA BIRAKILIYOR — döngü çözücü onu ASLA GÖRMÜYOR, SONSUZA DEK
    // sızıyordu (GERÇEK bir program çalıştırmasıyla, `DebugAllocator`ın
    // "leaked" raporuyla KANITLANDI — `genClassTrace`/`genClassGcFree`
    // düzeltmeleri TEK BAŞINA bu belirtiyi GİDEREMEDİ, ÇÜNKÜ collectWhite
    // hiçbir zaman ÇAĞRILMIYORDU).
    var has_class_field = false;
    for (cinfo.fields.items) |f| {
        if (f.info.heap == .class) {
            has_class_field = true;
            break;
        }
        if (f.info.heap == .list and f.info.elem_heap_info != null and f.info.elem_heap_info.?.heap == .class) {
            has_class_field = true;
            break;
        }
        if (f.info.heap == .dict and f.info.dict_info != null and f.info.dict_info.?.value_is_class) {
            has_class_field = true;
            break;
        }
    }

    const release_sym = try std.fmt.allocPrint(self.allocator, "${s}_release", .{class_name});
    try self.qbeFuncHeaderStart(null, release_sym);
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%p", false);
    try self.qbeFuncHeaderEnd();
    const should_free = try self.emitInlinePredecrement("%p", .class);
    const free_label = try self.newLabel("release_free");
    const done_label = try self.newLabel("release_done");
    // v1.142.0: `has_class_field` tek başına yetmez — sınıf bir referans
    // döngüsünün ÜYESİ olamıyorsa (bkz. `computeCyclicClasses`) olası-kök
    // kaydı (global kilit + hash yazımı) GEREKSİZDİR.
    const registers_root = has_class_field and self.cyclic_classes.contains(class_name);
    if (registers_root) {
        const root_label = try self.newLabel("release_possible_root");
        try self.qbeJnz(should_free, free_label, root_label);
        try self.qbeLabel(root_label);
        try self.qbeCall(null, "$nox_cycle_possible_root", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = "%p" } });
        try self.qbeJmp(done_label);
    } else {
        try self.qbeJnz(should_free, free_label, done_label);
    }
    try self.qbeLabel(free_label);
    if (has_class_field) {
        try self.qbeCall(null, "$nox_cycle_forget", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = "%p" } });
    }
    for (cinfo.fields.items) |f| {
        if (isHeapManaged(f.info.heap)) {
            const addr = try self.newTemp();
            try self.qbeOp2Imm(addr, .l, "add", "%p", @intCast(f.offset));
            const fv = try self.newTemp();
            try self.qbeLoadL(fv, addr);
            try self.releaseValueIfSet(fv, f.info.heap, f.info.elem_qtype, f.info.class_name, f.info.elem_heap_info, f.info.dict_info);
        } else if (f.info.heap == .task or f.info.heap == .channel or f.info.heap == .thread_handle or f.info.heap == .thread_channel or f.info.heap == .task_local) {
            // `Task[T]`/`Channel[T]`/`ThreadHandle[T]`/`ThreadChannel[T]`
            // sınıf alanı — ARC-yönetimli DEĞİLDİR (`isHeapManaged` bunu
            // KAPSAMAZ, `dict[K,V]`in AKSİNE — bkz. Faz FF.3), bu yüzden
            // AYRI bir dal: `destroyNonArcValue` ile DOĞRUDAN bir kez
            // yıkılır (bkz. `releaseAllLocalsExcept`in AYNI deseni —
            // yalnızca YEREL değil, sınıf ALANI için, Faz S.1'den beri
            // doğru).
            const addr = try self.newTemp();
            try self.qbeOp2Imm(addr, .l, "add", "%p", @intCast(f.offset));
            const fv = try self.newTemp();
            try self.qbeLoadL(fv, addr);
            try self.destroyNonArcValue(fv, f.info.heap);
        }
    }
    try self.qbeCall(null, "$nox_rc_free_payload", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = "%p" }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{cinfo.total_size}) } });
    try self.qbeJmp(done_label);
    try self.qbeLabel(done_label);
    try self.qbeRet(null);
    try self.qbeFuncEnd();
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
    // v3 madde 3 (ownership/ptr[T] red-team, bkz. nox-teknik-
    // spesifikasyon.md ilgili bölüm): **DÜZELTME (GERÇEK, bir kaçış-
    // taramasında BULUNAN, sonsuz-sızıntı sınıfı bir hata)** — bu fonksiyon
    // ÖNCEDEN SADECE `f.info.heap == .class` alanlarını topluyordu.
    // `list[ClassType]`/`dict[K, ClassType]` alanları (HeapKind.list/.dict,
    // `.class`DAN AYRI) TAMAMEN GÖRMEZDEN GELİNİYORDU — bu modülün ESKİ
    // belge notu "bugün yalnızca sınıf örnekleri arasında GERÇEK bir A↔B
    // döngüsü kurulabilir" diyordu, AMA bu YANLIŞTI: `a.children.append(b)`
    // GİBİ bir çağrı `b`yi RETAIN EDER (bkz. `calls.zig`nin `genListAppend`ı),
    // AMA bu referans ESKİ `$ClassName_trace`nin GÖRDÜĞÜ hiçbir yere
    // YAZILMAZDI — döngü çözücü BÖYLE bir A↔B'yi ASLA tespit EDEMİYORDU
    // (GERÇEK bir birim testiyle, `runtime/alloc/cycle_detector.zig`,
    // KANITLANDI: 0/2 nesne toplanıyordu). Şimdi list/dict-of-class
    // alanları da AYRI listelerde toplanıp aşağıda İZLENİYOR.
    var list_class_fields: std.ArrayListUnmanaged(ClassField) = .empty;
    defer list_class_fields.deinit(self.allocator);
    var dict_class_fields: std.ArrayListUnmanaged(ClassField) = .empty;
    defer dict_class_fields.deinit(self.allocator);
    for (cinfo.fields.items) |f| {
        if (f.info.heap == .class) {
            try class_fields.append(self.allocator, f);
        } else if (f.info.heap == .list and f.info.elem_heap_info != null and f.info.elem_heap_info.?.heap == .class) {
            try list_class_fields.append(self.allocator, f);
        } else if (f.info.heap == .dict and f.info.dict_info != null and f.info.dict_info.?.value_is_class) {
            try dict_class_fields.append(self.allocator, f);
        }
    }

    const trace_sym = try std.fmt.allocPrint(self.allocator, "${s}_trace", .{class_name});
    try self.qbeFuncHeaderStart(.l, trace_sym);
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%p", false);
    try self.qbeFuncHeaderEnd();

    // Hızlı yol — list/dict-tipli sınıf alanı YOKSA, ESKİ (tamamen
    // derleme-zamanı sabit boyutlu) kod ÜRETİLİR, SIFIR ek maliyetle
    // (bu, sınıfların BÜYÜK çoğunluğu İçİn geçerlidir).
    if (list_class_fields.items.len == 0 and dict_class_fields.items.len == 0) {
        const buf = try self.newTemp();
        try self.qbeCall(.{ .name = buf, .ty = .l }, "$nox_alloc", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{TRACE_BUF_LEN_SIZE + class_fields.items.len * TRACE_BUF_SLOT_SIZE}) } });
        try self.qbeStoreImmL(@intCast(class_fields.items.len), buf);
        for (class_fields.items, 0..) |f, i| {
            const addr = try self.newTemp();
            try self.qbeOp2Imm(addr, .l, "add", "%p", @intCast(f.offset));
            const fv = try self.newTemp();
            try self.qbeLoadL(fv, addr);
            const slot = try self.newTemp();
            try self.qbeOp2Imm(slot, .l, "add", buf, @intCast(TRACE_BUF_LEN_SIZE + i * TRACE_BUF_SLOT_SIZE));
            try self.qbeStoreL(fv, slot);
        }
        try self.qbeRet(buf);
        try self.qbeFuncEnd();
        return;
    }

    // Yavaş yol: list/dict-of-class alanları VAR — toplam çocuk sayısı
    // ÇALIŞMA ZAMANINDA (liste/dict uzunluklarına bağlı) belirlenir, bu
    // yüzden İKİ geçişli bir strateji kullanılır: (1) SAYIM geçişi —
    // arabellek boyutunu hesapla, (2) DOLDURMA geçişi — HEM doğrudan
    // sınıf alanlarını (sabit yuvalar) HEM liste/dict elemanlarını
    // (çalışma-zamanı ARTAN bir yazma-indeksiyle) yaz.
    const count_slot = try self.newTemp();
    try self.qbeAlloc(count_slot, .eight, 8);
    try self.qbeStoreImmL(@intCast(class_fields.items.len), count_slot);

    for (list_class_fields.items) |f| {
        const faddr = try self.newTemp();
        try self.qbeOp2Imm(faddr, .l, "add", "%p", @intCast(f.offset));
        const list_ptr = try self.newTemp();
        try self.qbeLoadL(list_ptr, faddr);
        const is_null = try self.newTemp();
        try self.qbeOp2Imm(is_null, .w, "ceql", list_ptr, 0);
        const skip_label = try self.newLabel("trace_list_len_skip");
        const have_label = try self.newLabel("trace_list_len_have");
        const after_label = try self.newLabel("trace_list_len_after");
        try self.qbeJnz(is_null, skip_label, have_label);
        try self.qbeLabel(have_label);
        const len_v = try self.newTemp();
        try self.qbeLoadL(len_v, list_ptr);
        const cur_count = try self.newTemp();
        try self.qbeLoadL(cur_count, count_slot);
        const new_count = try self.newTemp();
        try self.qbeOp2(new_count, .l, "add", cur_count, len_v);
        try self.qbeStoreL(new_count, count_slot);
        try self.qbeJmp(after_label);
        try self.qbeLabel(skip_label);
        try self.qbeJmp(after_label);
        try self.qbeLabel(after_label);
    }

    for (dict_class_fields.items) |f| {
        const faddr = try self.newTemp();
        try self.qbeOp2Imm(faddr, .l, "add", "%p", @intCast(f.offset));
        const dict_ptr = try self.newTemp();
        try self.qbeLoadL(dict_ptr, faddr);
        const is_null = try self.newTemp();
        try self.qbeOp2Imm(is_null, .w, "ceql", dict_ptr, 0);
        const skip_label = try self.newLabel("trace_dict_len_skip");
        const have_label = try self.newLabel("trace_dict_len_have");
        const after_label = try self.newLabel("trace_dict_len_after");
        try self.qbeJnz(is_null, skip_label, have_label);
        try self.qbeLabel(have_label);
        const len_v = try self.newTemp();
        try self.qbeCall(.{ .name = len_v, .ty = .l }, "$nox_dict_len", &.{.{ .ty = .l, .text = dict_ptr }});
        const cur_count = try self.newTemp();
        try self.qbeLoadL(cur_count, count_slot);
        const new_count = try self.newTemp();
        try self.qbeOp2(new_count, .l, "add", cur_count, len_v);
        try self.qbeStoreL(new_count, count_slot);
        try self.qbeJmp(after_label);
        try self.qbeLabel(skip_label);
        try self.qbeJmp(after_label);
        try self.qbeLabel(after_label);
    }

    const total_count = try self.newTemp();
    try self.qbeLoadL(total_count, count_slot);
    const size_bytes_a = try self.newTemp();
    try self.qbeOp2Imm(size_bytes_a, .l, "mul", total_count, @intCast(TRACE_BUF_SLOT_SIZE));
    const size_bytes = try self.newTemp();
    try self.qbeOp2Imm(size_bytes, .l, "add", size_bytes_a, @intCast(TRACE_BUF_LEN_SIZE));
    const buf = try self.newTemp();
    try self.qbeCall(.{ .name = buf, .ty = .l }, "$nox_alloc", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = size_bytes } });
    try self.qbeStoreL(total_count, buf);

    const write_idx_slot = try self.newTemp();
    try self.qbeAlloc(write_idx_slot, .eight, 8);
    try self.qbeStoreImmL(@intCast(class_fields.items.len), write_idx_slot);

    // Doğrudan sınıf alanları — SABİT yuvalar (0..class_fields.len),
    // tıpkı hızlı yoldaki GİBİ (bunlar İçİn çalışma-zamanı bir sayaca
    // gerek YOK, sayıları ZATEN derleme-zamanında bilinir).
    for (class_fields.items, 0..) |f, i| {
        const addr = try self.newTemp();
        try self.qbeOp2Imm(addr, .l, "add", "%p", @intCast(f.offset));
        const fv = try self.newTemp();
        try self.qbeLoadL(fv, addr);
        const slot = try self.newTemp();
        try self.qbeOp2Imm(slot, .l, "add", buf, @intCast(TRACE_BUF_LEN_SIZE + i * TRACE_BUF_SLOT_SIZE));
        try self.qbeStoreL(fv, slot);
    }

    for (list_class_fields.items) |f| {
        const faddr = try self.newTemp();
        try self.qbeOp2Imm(faddr, .l, "add", "%p", @intCast(f.offset));
        const list_ptr = try self.newTemp();
        try self.qbeLoadL(list_ptr, faddr);
        const is_null = try self.newTemp();
        try self.qbeOp2Imm(is_null, .w, "ceql", list_ptr, 0);
        const skip_label = try self.newLabel("trace_list_fill_skip");
        const have_label = try self.newLabel("trace_list_fill_have");
        const after_label = try self.newLabel("trace_list_fill_after");
        try self.qbeJnz(is_null, skip_label, have_label);
        try self.qbeLabel(have_label);
        const len_v = try self.newTemp();
        try self.qbeLoadL(len_v, list_ptr);
        try self.emitTraceCopyLoop(list_ptr, len_v, buf, write_idx_slot, "trace_list_fill");
        try self.qbeJmp(after_label);
        try self.qbeLabel(skip_label);
        try self.qbeJmp(after_label);
        try self.qbeLabel(after_label);
    }

    for (dict_class_fields.items) |f| {
        const faddr = try self.newTemp();
        try self.qbeOp2Imm(faddr, .l, "add", "%p", @intCast(f.offset));
        const dict_ptr = try self.newTemp();
        try self.qbeLoadL(dict_ptr, faddr);
        const is_null = try self.newTemp();
        try self.qbeOp2Imm(is_null, .w, "ceql", dict_ptr, 0);
        const skip_label = try self.newLabel("trace_dict_fill_skip");
        const have_label = try self.newLabel("trace_dict_fill_have");
        const after_label = try self.newLabel("trace_dict_fill_after");
        try self.qbeJnz(is_null, skip_label, have_label);
        try self.qbeLabel(have_label);
        // `nox_dict_values` (bkz. `runtime/collections/dict.zig`) DEĞER
        // başına bir retain yapan, GERÇEK bir `list[ClassType]` (ARC
        // başlıklı, `nox_rc_alloc`la tahsisli) döner — `d.values()`nin
        // KENDİ, ZATEN VAR OLAN çalışma zamanı ilkeli, İKİNCİ bir mekanizma
        // İCAT EDİLMEDİ. Anahtar tipi (`key_is_str`) DEĞER çıkarımını
        // ETKİLEMEZ, bu YÜZDEN HER ZAMAN `0` geçilir.
        const values_list = try self.newTemp();
        try self.qbeCall(.{ .name = values_list, .ty = .l }, "$nox_dict_values", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = dict_ptr }, .{ .ty = .w, .text = "0" }, .{ .ty = .w, .text = "1" }, .{ .ty = .l, .text = "8" } });
        const len_v = try self.newTemp();
        try self.qbeLoadL(len_v, values_list);
        try self.emitTraceCopyLoop(values_list, len_v, buf, write_idx_slot, "trace_dict_fill");
        // `values_list`in KENDİSİ (geçici) serbest bırakılır — İÇİNDEKİ HER
        // sınıf değeri `nox_dict_values`in KENDİSİ TARAFINDAN BİR KEZ
        // retain edilmişti; bu release SADECE o retain'i geri alır —
        // elemanların KENDİLERİ (orijinal dict HÂLÂ REFERANS TUTTUĞUNDAN)
        // serbest BIRAKILMAZ (bkz. `releaseValueIfSet`in `.list` dalı,
        // AYNI "refcount>0 İSE sadece azalt" güvenliği).
        const elem_info = try self.allocator.create(ElemHeapInfo);
        elem_info.* = .{ .heap = .class, .class_name = f.info.dict_info.?.value_class_name };
        try self.releaseValueIfSet(values_list, .list, .l, null, elem_info, null);
        try self.qbeJmp(after_label);
        try self.qbeLabel(skip_label);
        try self.qbeJmp(after_label);
        try self.qbeLabel(after_label);
    }

    try self.qbeRet(buf);
    try self.qbeFuncEnd();
}

/// `genClassTrace`nin yavaş yolunun ORTAK "bir `list[ClassType]`nin (ya da
/// `nox_dict_values`in döndürdüğü GEÇİCİ listenin) TÜM elemanlarını
/// `buf`nin İÇİNE, `write_idx_slot`teki ÇALIŞMA-ZAMANI yazma-indeksinden
/// BAŞLAYARAK kopyala, indeksi HER elemanda artır" döngüsü — hem gerçek
/// bir `list[T]` alanı HEM `nox_dict_values`in geçici sonucu AYNI bayt
/// düzenini (`LIST_HEADER_SIZE` + 8-baytlık işaretçi elemanları)
/// TAŞIDIĞINDAN TEK bir yardımcı yeterlidir.
pub fn emitTraceCopyLoop(self: *Codegen, list_ptr: []const u8, len_v: []const u8, buf: []const u8, write_idx_slot: []const u8, comptime label_prefix: []const u8) CodegenError!void {
    const i_slot = try self.newTemp();
    try self.qbeAlloc(i_slot, .eight, 8);
    try self.qbeStoreImmL(0, i_slot);
    const cond_label = try self.newLabel(label_prefix ++ "_cond");
    const body_label = try self.newLabel(label_prefix ++ "_body");
    const loop_end_label = try self.newLabel(label_prefix ++ "_loopend");
    try self.qbeJmp(cond_label);
    try self.qbeLabel(cond_label);
    const cur_i = try self.newTemp();
    try self.qbeLoadL(cur_i, i_slot);
    const cmp = try self.newTemp();
    try self.qbeOp2(cmp, .w, "csltl", cur_i, len_v);
    try self.qbeJnz(cmp, body_label, loop_end_label);
    try self.qbeLabel(body_label);
    const elem_off = try self.newTemp();
    try self.qbeOp2Imm(elem_off, .l, "mul", cur_i, 8);
    const elem_off2 = try self.newTemp();
    try self.qbeOp2Imm(elem_off2, .l, "add", elem_off, @intCast(LIST_HEADER_SIZE));
    const elem_addr = try self.newTemp();
    try self.qbeOp2(elem_addr, .l, "add", list_ptr, elem_off2);
    const elem_v = try self.newTemp();
    try self.qbeLoadL(elem_v, elem_addr);
    const wi = try self.newTemp();
    try self.qbeLoadL(wi, write_idx_slot);
    const wi_off = try self.newTemp();
    try self.qbeOp2Imm(wi_off, .l, "mul", wi, @intCast(TRACE_BUF_SLOT_SIZE));
    const wi_off2 = try self.newTemp();
    try self.qbeOp2Imm(wi_off2, .l, "add", wi_off, @intCast(TRACE_BUF_LEN_SIZE));
    const slot_addr = try self.newTemp();
    try self.qbeOp2(slot_addr, .l, "add", buf, wi_off2);
    try self.qbeStoreL(elem_v, slot_addr);
    const wi_next = try self.newTemp();
    try self.qbeOp2Imm(wi_next, .l, "add", wi, 1);
    try self.qbeStoreL(wi_next, write_idx_slot);
    const i_next = try self.newTemp();
    try self.qbeOp2Imm(i_next, .l, "add", cur_i, 1);
    try self.qbeStoreL(i_next, i_slot);
    try self.qbeJmp(cond_label);
    try self.qbeLabel(loop_end_label);
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

    const gc_free_sym = try std.fmt.allocPrint(self.allocator, "${s}_gc_free", .{class_name});
    try self.qbeFuncHeaderStart(null, gc_free_sym);
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%p", false);
    try self.qbeFuncHeaderEnd();
    for (cinfo.fields.items) |f| {
        if (f.info.heap == .class) continue; // bkz. yukarıdaki belge notu
        // v3 madde 3 (bkz. `nox_list_shallow_gc_free`/`nox_dict_shallow_
        // gc_free_class_values`in belge notu, `runtime/alloc/arc.zig`/
        // `runtime/collections/dict.zig`) — DÜZELTME: list[ClassType]/
        // dict[K, ClassType] alanları da (DOĞRUDAN `.class` alanları
        // GİBİ) sınıf-tipli ÇOCUKLARA erişebildiğinden, NORMAL `release
        // ValueIfSet` (elemanları/değerleri NORMAL ARC İLE serbest
        // bırakır, `nox_cycle_possible_root`u TEKRAR tetikleyip
        // `collectWhite`in worklist'İNİ BOZAR) YERİNE "sığ" bir serbest
        // bırakma kullanılır — SADECE liste/dict'in KENDİ yapısı serbest
        // bırakılır, İÇİNDEKİ sınıf değerlerine HİÇ DOKUNULMAZ (onlar
        // `collectWhite`in KENDİ özyinelemesiyle AYRICA ele alınır).
        if (f.info.heap == .list and f.info.elem_heap_info != null and f.info.elem_heap_info.?.heap == .class) {
            const addr = try self.newTemp();
            try self.qbeOp2Imm(addr, .l, "add", "%p", @intCast(f.offset));
            const fv = try self.newTemp();
            try self.qbeLoadL(fv, addr);
            const is_null = try self.newTemp();
            try self.qbeOp2Imm(is_null, .w, "ceql", fv, 0);
            const skip_label = try self.newLabel("gcfree_list_skip");
            const have_label = try self.newLabel("gcfree_list_have");
            const after_label = try self.newLabel("gcfree_list_after");
            try self.qbeJnz(is_null, skip_label, have_label);
            try self.qbeLabel(have_label);
            try self.qbeCall(null, "$nox_list_shallow_gc_free", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = fv } });
            try self.qbeJmp(after_label);
            try self.qbeLabel(skip_label);
            try self.qbeJmp(after_label);
            try self.qbeLabel(after_label);
            continue;
        }
        if (f.info.heap == .dict and f.info.dict_info != null and f.info.dict_info.?.value_is_class) {
            const addr = try self.newTemp();
            try self.qbeOp2Imm(addr, .l, "add", "%p", @intCast(f.offset));
            const fv = try self.newTemp();
            try self.qbeLoadL(fv, addr);
            const is_null = try self.newTemp();
            try self.qbeOp2Imm(is_null, .w, "ceql", fv, 0);
            const skip_label = try self.newLabel("gcfree_dict_skip");
            const have_label = try self.newLabel("gcfree_dict_have");
            const after_label = try self.newLabel("gcfree_dict_after");
            try self.qbeJnz(is_null, skip_label, have_label);
            try self.qbeLabel(have_label);
            const key_is_str_lit: []const u8 = if (f.info.dict_info.?.key_is_str) "1" else "0";
            try self.qbeCall(null, "$nox_dict_shallow_gc_free_class_values", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = fv }, .{ .ty = .w, .text = key_is_str_lit } });
            try self.qbeJmp(after_label);
            try self.qbeLabel(skip_label);
            try self.qbeJmp(after_label);
            try self.qbeLabel(after_label);
            continue;
        }
        if (isHeapManaged(f.info.heap)) {
            const addr = try self.newTemp();
            try self.qbeOp2Imm(addr, .l, "add", "%p", @intCast(f.offset));
            const fv = try self.newTemp();
            try self.qbeLoadL(fv, addr);
            try self.releaseValueIfSet(fv, f.info.heap, f.info.elem_qtype, f.info.class_name, f.info.elem_heap_info, f.info.dict_info);
        } else if (f.info.heap == .task or f.info.heap == .channel or f.info.heap == .thread_handle or f.info.heap == .thread_channel or f.info.heap == .task_local) {
            const addr = try self.newTemp();
            try self.qbeOp2Imm(addr, .l, "add", "%p", @intCast(f.offset));
            const fv = try self.newTemp();
            try self.qbeLoadL(fv, addr);
            try self.destroyNonArcValue(fv, f.info.heap);
        }
    }
    try self.qbeCall(null, "$nox_rc_free_payload", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = "%p" }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{cinfo.total_size}) } });
    try self.qbeRet(null);
    try self.qbeFuncEnd();
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

    try self.qbeFuncHeaderStart(.l, "$nox_trace_dispatch");
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%tag", false);
    try self.qbeFuncParam(.l, "%p", false);
    try self.qbeFuncHeaderEnd();
    for (classes) |c| {
        const eq = try self.newTemp();
        try self.qbeOp2Imm(eq, .w, "ceql", "%tag", @intCast(c.id));
        const case_label = try self.newLabel("trace_case");
        const next_label = try self.newLabel("trace_next");
        try self.qbeJnz(eq, case_label, next_label);
        try self.qbeLabel(case_label);
        const r = try self.newTemp();
        const trace_sym = try std.fmt.allocPrint(self.allocator, "${s}_trace", .{c.name});
        try self.qbeCall(.{ .name = r, .ty = .l }, trace_sym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = "%p" } });
        try self.qbeRet(r);
        try self.qbeLabel(next_label);
    }
    const empty = try self.newTemp();
    try self.qbeCall(.{ .name = empty, .ty = .l }, "$nox_alloc", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = "8" } });
    try self.qbeStoreImmL(0, empty);
    try self.qbeRet(empty);
    try self.qbeFuncEnd();
}

/// Bulundu (nyx framework — bkz. proje belleği "NOX_LIMITATIONS.md
/// incelemesi", P5): `genGcFreeDispatch`/`genTraceDispatch` İLE AYNI
/// desen, ama `$ClassName_gc_free` (koşulsuz, cycle-detector'ın KENDİ
/// yolu) YERİNE NORMAL ARC `$ClassName_release`e (predecrement'e göre
/// KOŞULLU serbest bırakma) dağıtan `$nox_class_release_dispatch(rt,
/// tag, p)`. **Tek gerçek kullanım yeri:** `exceptions.zig`nin `genTry`ı
/// — ÇIPLAK `except:` (VEYA `as e:` bağlaması OLMAYAN TİPLİ bir `except
/// X:`) bir istisnayı yakaladığında, `nox_exception_take`in döndürdüğü
/// nesnenin ÇALIŞMA-ZAMANI sınıfı DERLEME ZAMANINDA BİLİNMEZ (Nox'ta
/// kalıtım/RTTI OLMADIĞINDAN, HERHANGİ bir sınıf `raise` EDİLEBİLİR) —
/// bu YÜZDEN sabit bir `$<isim>_release` çağrısı YAPILAMAZ, ÇALIŞMA
/// ZAMANINDA tag'e göre DOĞRU release fonksiyonuna dal açılması GEREKİR
/// (aksi halde yakalanan istisna nesnesi HER ZAMAN sızar — GERÇEK bir
/// tekrar-üretimle DOĞRULANDI).
pub fn genClassReleaseDispatch(self: *Codegen, classes: []const ClassIdEntry) CodegenError!void {
    self.temp_counter = 0;
    self.label_counter = 0;
    self.mod_cache.deinit(self.allocator);
    self.mod_cache = .empty;

    try self.qbeFuncHeaderStart(null, "$nox_class_release_dispatch");
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%tag", false);
    try self.qbeFuncParam(.l, "%p", false);
    try self.qbeFuncHeaderEnd();
    for (classes) |c| {
        const eq = try self.newTemp();
        try self.qbeOp2Imm(eq, .w, "ceql", "%tag", @intCast(c.id));
        const case_label = try self.newLabel("class_release_case");
        const next_label = try self.newLabel("class_release_next");
        try self.qbeJnz(eq, case_label, next_label);
        try self.qbeLabel(case_label);
        const release_sym = try std.fmt.allocPrint(self.allocator, "${s}_release", .{c.name});
        try self.qbeCall(null, release_sym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = "%p" } });
        try self.qbeRet(null);
        try self.qbeLabel(next_label);
    }
    try self.qbeRet(null);
    try self.qbeFuncEnd();
}

/// Faz OO.3 (bkz. nox-teknik-spesifikasyon.md §3.84): `genClassRelease
/// Dispatch` İLE AYNI if-zinciri kalıbı, ama `$ClassName_release`e
/// DAĞITMAK YERİNE sınıfın KENDİ ADINI döndüren `$nox_class_name_
/// dispatch(rt, tag, p) -> l`. **Tek gerçek kullanım yeri:**
/// `runtime/errors/handle.zig`nin `nox_unhandled_exception`ı — yakalan-
/// mamış bir istisnanın ÇALIŞMA-ZAMANI sınıfı DERLEME ZAMANINDA
/// BİLİNMEZ (`genClassReleaseDispatch`İN AYNI gerekçesi), bu YÜZDEN
/// tip adı da TAG'e göre ÇALIŞMA ZAMANINDA aranmalıdır. Dönen değer
/// BİLİNÇLİ OLARAK ARC-başlıksız, düz (NUL-sonlandırılmış) bir C dizesi
/// SEMBOLÜdür — `internPinnedStringConst`in ürettiği pinned-refcount'lu
/// Nox `str` biçimi DEĞİL, çünkü TEK tüketicisi (`nox_unhandled_
/// exception`) SAF Zig kodudur ve Nox `str`in ARC/uzunluk başlığı
/// biçimini (`STR_HEADER_SIZE`) BİLMEK ZORUNDA KALMAMALIDIR. Eşleşen
/// bir dal BULUNAMAZSA (savunmacı) `$__nox_classname_unknown`e döner.
pub fn genClassNameDispatch(self: *Codegen, classes: []const ClassIdEntry) CodegenError!void {
    self.temp_counter = 0;
    self.label_counter = 0;
    self.mod_cache.deinit(self.allocator);
    self.mod_cache = .empty;

    // Faz LLVM.5 (bkz. `genClassVtable`nin AYNI belge notu): `string_data`/
    // `fmt_data` İLE AYNI şekil (ARC başlıksız, düz C dizesi) — `.llvm`de
    // `llvm_emit.llvmCStringConstant` KULLANILIR, KAÇAN metin (`escaped`)
    // DEĞİL HAM metin (`llvmCStringConstant` KENDİ escape'ini yapar).
    if (self.backend == .qbe) {
        const unknown_escaped = try escapeForQbeString(self.allocator, "bilinmeyen sinif");
        try self.qbeRaw("data $__nox_classname_unknown = {{ b \"{s}\", b 0 }}\n", .{unknown_escaped});
    } else {
        const line = try llvm_emit.llvmCStringConstant(self.allocator, "__nox_classname_unknown", "bilinmeyen sinif");
        try self.out.writer.writeAll(line);
    }

    var name_syms: std.ArrayListUnmanaged([]const u8) = .empty;
    defer name_syms.deinit(self.allocator);
    for (classes) |c| {
        const sym = try std.fmt.allocPrint(self.allocator, "$__nox_classname_{s}", .{c.name});
        if (self.backend == .qbe) {
            const escaped = try escapeForQbeString(self.allocator, c.name);
            try self.qbeRaw("data {s} = {{ b \"{s}\", b 0 }}\n", .{ sym, escaped });
        } else {
            const llvm_name = try std.fmt.allocPrint(self.allocator, "__nox_classname_{s}", .{c.name});
            const line = try llvm_emit.llvmCStringConstant(self.allocator, llvm_name, c.name);
            try self.out.writer.writeAll(line);
        }
        try name_syms.append(self.allocator, sym);
    }

    try self.qbeFuncHeaderStart(.l, "$nox_class_name_dispatch");
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%tag", false);
    try self.qbeFuncParam(.l, "%p", false);
    try self.qbeFuncHeaderEnd();
    for (classes, name_syms.items) |c, sym| {
        const eq = try self.newTemp();
        try self.qbeOp2Imm(eq, .w, "ceql", "%tag", @intCast(c.id));
        const case_label = try self.newLabel("class_name_case");
        const next_label = try self.newLabel("class_name_next");
        try self.qbeJnz(eq, case_label, next_label);
        try self.qbeLabel(case_label);
        try self.qbeRet(sym);
        try self.qbeLabel(next_label);
    }
    try self.qbeRet("$__nox_classname_unknown");
    try self.qbeFuncEnd();
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

    try self.qbeFuncHeaderStart(null, "$nox_gc_free_dispatch");
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%tag", false);
    try self.qbeFuncParam(.l, "%p", false);
    try self.qbeFuncHeaderEnd();
    for (classes) |c| {
        const eq = try self.newTemp();
        try self.qbeOp2Imm(eq, .w, "ceql", "%tag", @intCast(c.id));
        const case_label = try self.newLabel("gc_free_case");
        const next_label = try self.newLabel("gc_free_next");
        try self.qbeJnz(eq, case_label, next_label);
        try self.qbeLabel(case_label);
        const gc_free_sym = try std.fmt.allocPrint(self.allocator, "${s}_gc_free", .{c.name});
        try self.qbeCall(null, gc_free_sym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = "%p" } });
        try self.qbeRet(null);
        try self.qbeLabel(next_label);
    }
    try self.qbeRet(null);
    try self.qbeFuncEnd();
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

    const eq_sym = try std.fmt.allocPrint(self.allocator, "${s}_eq", .{class_name});
    try self.qbeFuncHeaderStart(.w, eq_sym);
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%a", false);
    try self.qbeFuncParam(.l, "%b", false);
    try self.qbeFuncHeaderEnd();
    const mismatch_label = try self.newLabel("classeq_mismatch");
    for (cinfo.fields.items) |f| {
        const addr_a = try self.newTemp();
        try self.qbeOp2Imm(addr_a, .l, "add", "%a", @intCast(f.offset));
        const addr_b = try self.newTemp();
        try self.qbeOp2Imm(addr_b, .l, "add", "%b", @intCast(f.offset));
        const va = try self.newTemp();
        try self.narrowLoad(va, f.info, cinfo.layout_mode, addr_a);
        const vb = try self.newTemp();
        try self.narrowLoad(vb, f.info, cinfo.layout_mode, addr_b);
        try self.genEqCompareOrJump(va, vb, f.info.qtype, f.info.heap, f.info.class_name, f.info.elem_qtype, f.info.elem_heap_info, f.info.elem_is_str, mismatch_label, null);
    }
    try self.qbeRet("1");
    try self.qbeLabel(mismatch_label);
    try self.qbeRet("0");
    try self.qbeFuncEnd();
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
        try self.qbeOp2(t, .w, mnemonic, va, vb);
        const cont_label = try self.newLabel("eqcmp_cont");
        try self.qbeJnz(t, cont_label, mismatch_label);
        try self.qbeLabel(cont_label);
        if (success_label) |sl| try self.qbeJmp(sl);
        return;
    }
    if (heap == .str) {
        const cmp = try self.newTemp();
        try self.qbeCall(.{ .name = cmp, .ty = .w }, "$strcmp", &.{ .{ .ty = .l, .text = va }, .{ .ty = .l, .text = vb } });
        const cont_label = try self.newLabel("eqcmp_cont");
        try self.qbeJnz(cmp, mismatch_label, cont_label);
        try self.qbeLabel(cont_label);
        if (success_label) |sl| try self.qbeJmp(sl);
        return;
    }

    // `heap == .class` ya da `.list` — NULL olabilir (bkz. belge notu).
    const a_null = try self.newTemp();
    try self.qbeOp2Imm(a_null, .w, "ceql", va, 0);
    const b_null = try self.newTemp();
    try self.qbeOp2Imm(b_null, .w, "ceql", vb, 0);
    const either_null = try self.newTemp();
    try self.qbeOp2(either_null, .w, "or", a_null, b_null);
    const null_case_label = try self.newLabel("eqcmp_nullcase");
    const rec_label = try self.newLabel("eqcmp_rec");
    const cont_label = try self.newLabel("eqcmp_cont");
    try self.qbeJnz(either_null, null_case_label, rec_label);
    try self.qbeLabel(null_case_label);
    const both_null = try self.newTemp();
    try self.qbeOp2(both_null, .w, "and", a_null, b_null);
    try self.qbeJnz(both_null, cont_label, mismatch_label);
    try self.qbeLabel(rec_label);
    const rec: []const u8 = switch (heap) {
        .class => blk: {
            const t = try self.newTemp();
            const eq_sym = try std.fmt.allocPrint(self.allocator, "${s}_eq", .{class_name.?});
            try self.qbeCall(.{ .name = t, .ty = .w }, eq_sym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = va }, .{ .ty = .l, .text = vb } });
            break :blk t;
        },
        .list => blk: {
            const fn_name = try self.eqFnNameForList(elem_qtype, elem_heap_info, elem_is_str);
            const eq_sym = try std.fmt.allocPrint(self.allocator, "${s}_eq", .{fn_name});
            const t = try self.newTemp();
            try self.qbeCall(.{ .name = t, .ty = .w }, eq_sym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = va }, .{ .ty = .l, .text = vb } });
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
        // v2.0 madde 6: `ptr[T]` de (`dict`/`Task`/`Channel` İLE AYNI
        // gerekçe) yapısal derinlemesine eşitliğe SAHİP DEĞİL — güvenli
        // varsayılan: tutamaç-kimliği (pointer/adres) karşılaştırması.
        .dict, .task, .channel, .closure, .thread_handle, .thread_channel, .boxed_scalar, .task_local, .typed_ptr => blk: {
            const t = try self.newTemp();
            try self.qbeOp2(t, .w, "ceql", va, vb);
            break :blk t;
        },
        .none, .str => unreachable,
    };
    try self.qbeJnz(rec, cont_label, mismatch_label);
    try self.qbeLabel(cont_label);
    if (success_label) |sl| try self.qbeJmp(sl);
}

/// GG.13 (bkz. nox-teknik-spesifikasyon.md §3.66): `a == b`/`a != b`
/// (`a`/`b` `cinfo` sınıfının örnekleri) — bir `call $ClassName_eq`
/// ÜRETMEK YERİNE `genClassEq`nin AYNI alan-alana karşılaştırma
/// mantığını KULLANIM SİTESİNE doğrudan SPLICE edip edemeyeceğimizi
/// belirler. BU sadece bir KOD-BOYUTU sezgisidir (DOĞRULUK kapısı
/// DEĞİL) — `genEqCompareOrJump` iç içe `.class`/`.list` alanları İçin
/// ZATEN sadece TEK bir `call` üretir (kendi İÇİNE splice etmez), bu
/// yüzden alan sayısı ne olursa olsun sonuç HER ZAMAN doğrudur; SADECE
/// `==`in ÇOK sayıda KULLANIM sitesinde tekrar tekrar üretilen kod
/// miktarını sınırlamak İçin küçük bir eşik (≤8 alan) uygulanır.
pub fn classEqInlineEligible(cinfo: ClassInfo) bool {
    return cinfo.fields.items.len <= 8;
}

/// GG.13: `genClassEq`nin AYNI alan-alana karşılaştırma mantığını,
/// PAYLAŞILAN bir `$ClassName_eq` fonksiyonu ÜZERİNDEN ÇAĞIRMAK YERİNE,
/// `expr.zig`nin `.binary` `==`/`!=` KULLANIM SİTESİNE DOĞRUDAN splice
/// eder — çağrı/dönüş overhead'ini eler. `a_ptr`/`b_ptr` (ZATEN
/// yüklenmiş, HİÇBİR ZAMAN null OLAMAYAN — bkz. `expr.zig`nin AYNI
/// gerekçesi, TAM sınıf örnekleri, alan/eleman OKUMASI DEĞİL) iki
/// işaretçidir. Dönen `Value.text`, `1`/`0` OLARAK çözülen bir QBE
/// `phi`dir — GG.2'nin fonksiyon-girişi ÖN-TAHSİSLİ slot mekanizmasına
/// (`inlining.zig`) GEREK YOKTUR: burada TAŞINACAK bir YEREL DEĞİŞKEN
/// yok, sadece bir dal-sonucu KONSOLİDASYONU — QBE'nin `phi`si bunu
/// (bir `alloc` GİBİ) yığın büyümesi RİSKİ OLMADAN, HER kontrol-akışı
/// geçişinde TAZE çözer (bkz. `layout.zig`nin `genForList`teki AYNI
/// `phi` kullanımı, §3.16'nın `alloc`/yığın-taşması dersiyle KARIŞTIRILMAMALI
/// — o ders SADECE `alloc4`/`alloc8`e ÖZGÜDÜR).
pub fn genClassEqInline(self: *Codegen, cinfo: ClassInfo, a_ptr: []const u8, b_ptr: []const u8) CodegenError![]const u8 {
    const mismatch_label = try self.newLabel("eqinline_mismatch");
    const match_label = try self.newLabel("eqinline_match");
    if (cinfo.fields.items.len == 0) {
        // Alanı olmayan bir sınıf: iki örnek YAPISAL olarak HER ZAMAN
        // "eşit"tir (bkz. `genClassEq`nin AYNI ilkesi) — karşılaştırılacak
        // hiçbir şey yok, doğrudan eşleşme dalına atla.
        try self.qbeJmp(match_label);
    }
    for (cinfo.fields.items, 0..) |f, i| {
        const addr_a = try self.newTemp();
        try self.qbeOp2Imm(addr_a, .l, "add", a_ptr, @intCast(f.offset));
        const addr_b = try self.newTemp();
        try self.qbeOp2Imm(addr_b, .l, "add", b_ptr, @intCast(f.offset));
        const va = try self.newTemp();
        try self.narrowLoad(va, f.info, cinfo.layout_mode, addr_a);
        const vb = try self.newTemp();
        try self.narrowLoad(vb, f.info, cinfo.layout_mode, addr_b);
        const is_last = i == cinfo.fields.items.len - 1;
        try self.genEqCompareOrJump(va, vb, f.info.qtype, f.info.heap, f.info.class_name, f.info.elem_qtype, f.info.elem_heap_info, f.info.elem_is_str, mismatch_label, if (is_last) match_label else null);
    }
    try self.qbeLabel(match_label);
    const done_label = try self.newLabel("eqinline_done");
    try self.qbeJmp(done_label);
    try self.qbeLabel(mismatch_label);
    try self.qbeJmp(done_label);
    try self.qbeLabel(done_label);
    const result = try self.newTemp();
    try self.qbePhi(result, .w, match_label, "1", mismatch_label, "0");
    return result;
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
            .task_local => "task_local",
            // v2.0 madde 6: `list[ptr[T]]` bu turda desteklenmez (bkz. plan
            // dosyası "kapsam DIŞI") — `resolveType`in `list` dalının elem-
            // heap izin-listesi `.typed_ptr`i HİÇ KABUL ETMEDİĞİNDEN bu dal
            // PRATİKTE erişilemez, sadece exhaustive switch GEREKSİNİMİNİ
            // karşılar.
            .typed_ptr => "ptr",
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

    const listeq_sym = try std.fmt.allocPrint(self.allocator, "${s}_eq", .{name});
    try self.qbeFuncHeaderStart(.w, listeq_sym);
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%a", false);
    try self.qbeFuncParam(.l, "%b", false);
    try self.qbeFuncHeaderEnd();
    const len_a = try self.newTemp();
    try self.qbeLoadL(len_a, "%a");
    const len_b = try self.newTemp();
    try self.qbeLoadL(len_b, "%b");
    const len_diff = try self.newTemp();
    try self.qbeOp2(len_diff, .w, "cnel", len_a, len_b);
    const false_label = try self.newLabel("listeq_lendiff");
    const loop_init_label = try self.newLabel("listeq_init");
    try self.qbeJnz(len_diff, false_label, loop_init_label);
    try self.qbeLabel(loop_init_label);

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
    try self.qbeJmp(cond_label);
    try self.qbeLabel(cond_label);
    const idx_cur = try self.newTemp();
    const idx_next = try self.newTemp();
    try self.qbePhi(idx_cur, .l, loop_init_label, "0", backedge_label, idx_next);
    const cont = try self.newTemp();
    try self.qbeOp2(cont, .w, "csltl", idx_cur, len_a);
    try self.qbeJnz(cont, body_label, true_label);
    try self.qbeLabel(body_label);

    const off = try self.newTemp();
    try self.qbeOp2Imm(off, .l, "mul", idx_cur, @intCast(qbeSizeOf(elem_qtype)));
    const off8 = try self.newTemp();
    try self.qbeOp2Imm(off8, .l, "add", off, @intCast(LIST_HEADER_SIZE));
    const addr_a = try self.newTemp();
    try self.qbeOp2(addr_a, .l, "add", "%a", off8);
    const addr_b = try self.newTemp();
    try self.qbeOp2(addr_b, .l, "add", "%b", off8);
    const ea = try self.newTemp();
    try self.qbeLoad(ea, elem_qtype, elem_qtype, addr_a);
    const eb = try self.newTemp();
    try self.qbeLoad(eb, elem_qtype, elem_qtype, addr_b);
    const elem_heap: HeapKind = if (elem_heap_info) |ehi| ehi.heap else if (elem_is_str) .str else .none;
    const elem_class_name: ?[]const u8 = if (elem_heap_info) |ehi| ehi.class_name else null;
    try self.genEqCompareOrJump(ea, eb, elem_qtype, elem_heap, elem_class_name, if (elem_heap_info) |ehi| ehi.elem_qtype else .none, if (elem_heap_info) |ehi| ehi.nested else null, if (elem_heap_info) |ehi| ehi.elem_is_str else false, false_label, backedge_label);
    try self.qbeLabel(backedge_label);
    try self.qbeOp2Imm(idx_next, .l, "add", idx_cur, 1);
    try self.qbeJmp(cond_label);
    try self.qbeLabel(true_label);
    try self.qbeRet("1");
    try self.qbeLabel(false_label);
    try self.qbeRet("0");
    try self.qbeFuncEnd();
}
