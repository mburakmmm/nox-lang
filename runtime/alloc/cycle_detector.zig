//! Nox Katman 3 (döngü çözücü) çalışma zamanı — AGENTS.md §8, Faz S.3.
//!
//! **Kapsam (v1, bilinçli dar):** yalnızca SINIF ÖRNEKLERİ arasındaki
//! referans döngülerini (`class A: b: B` / `class Node: next: Node` gibi
//! öz-referans DAHİL) tespit eder — `list[T]`/`dict[K,V]` elemanları/`str`
//! bu taramaya DAHİL DEĞİLDİR (AGENTS.md §8: "Yalnızca ARC modundaki
//! nesneleri tarar" — bu projede BUGÜN yalnızca sınıf örnekleri arasında
//! GERÇEK bir A↔B döngüsü kurulabilir, bkz. `compiler/codegen_qbe/codegen.zig`,
//! `inferFieldType`in `self` dalı).
//!
//! **Algoritma — Bacon & Rajan'ın senkron "trial deletion" (deneme-yanılma
//! silme) döngü toplayıcısı** (Nim'in ORC'unun da temel aldığı KLASİK
//! algoritma, CPython'ın kendi döngü GC'sinin de yakın akrabası): her
//! `nox_rc_predecrement` refcount'u SIFIRA DÜŞÜRMEDEN azalttığında, nesne
//! bir "olası kök" (possible root, RENK=mor/purple) olarak İŞARETLENİR —
//! kalan referansların TAMAMEN bir döngünün İÇİNDEN mi geldiği (bu durumda
//! nesne GERÇEKTEN çöptür) yoksa dışarıdan (canlı bir değişken/yığın
//! çerçevesi) mi geldiği henüz BİLİNMEZ. `nox_cycle_collect` üç geçişte
//! bunu çözer:
//!   1. **MarkRoots/MarkGray:** her olası kökten başlayıp TÜM alt-grafiği
//!      GRİ'ye boyar, HER kenar İÇİN çocuğun refcount'unu bir azaltır (bu,
//!      "döngünün İÇİNDEN gelen" katkıları GEÇİCİ olarak çıkarır).
//!   2. **ScanRoots/Scan/ScanBlack:** azaltmadan SONRA refcount'u hâlâ >0
//!      olan bir GRİ nesne, GERÇEKTEN dışarıdan da referanslanıyor demektir
//!      — bu nesne (ve TÜM alt-grafiği) SİYAH'a geri boyanır VE refcount'lar
//!      GERİ EKLENİR (bu düzeltmeyi TERSİNE ÇEVİRİR). Kalan (hâlâ ≤0 olan)
//!      nesneler BEYAZ'a boyanır — GERÇEKTEN çöp.
//!   3. **CollectRoots/CollectWhite:** BEYAZ alt-grafik GÜVENLE serbest
//!      bırakılır (artık HİÇBİR canlı referans yoktur — kanıtlanmıştır).
//!
//! **Nesne başına renk/buffered durumu NEREDE tutulur:** ARC nesnelerinin
//! KENDİ 8 baytlık başlığı (bkz. `arc.zig`) yalnızca refcount taşır —
//! bu formatı DEĞİŞTİRMEMEK için (mevcut TÜM inline retain/predecrement QBE
//! emisyonu/`arc.zig`nin HER çağrı sitesini etkileme riskini almadan) renk/
//! buffered bilgisi AYRI bir yan tabloda (`CycleGc.meta`, işaretçiden
//! meta'ya bir `AutoHashMap`) tutulur — daha az önbellek-dostu ama ÇOK daha
//! az invaziv ve GÜVENLİ bir tasarım kararı.
//!
//! **Çocukları KEŞFETME (`traceChildren`):** derleyici EN AZ BİR sınıf İÇEREN
//! HER programda, HER sınıf İÇİN bir `$ClassName_trace(rt, p) -> l` üretir
//! (bkz. codegen.zig, `genClassTrace`) — SINIF TİPLİ alanların DEĞERLERİNİ
//! küçük, `nox_alloc`'lu bir arabelleğe (8 baytlık uzunluk başlığı + N adet
//! 8 baytlık işaretçi, `list[T]`nin AYNI düzeni) yazıp döner;
//! `$nox_trace_dispatch(rt, tag, p) -> l` bu fonksiyonları çalışma zamanı
//! sınıf ETİKETİNE (`tag`, her örneğin İLK 8 baytı) göre DAĞITIR. Bu sembol
//! `runtime/stdlib_shims/json.zig`nin `nox_json_make_json_value`
//! çözümlemesiyle AYNI gerekçeyle `dlsym` İLE ÇALIŞMA ZAMANINDA aranır (bkz.
//! `resolveTraceDispatch`in belge notu) — SINIFSIZ bir programda YA DA
//! `noxrt.o`yu HİÇ bir Nox programı OLMADAN test eden `noxrt_test`
//! hedefinde (bkz. `zig build test`) HİÇ ÜRETİLMEZ, sabit bir `extern fn`
//! bu durumlarda bağlama adımını ÇÖKERTİRDİ.

const std = @import("std");
const asap = @import("asap.zig");

/// Derleyicinin ÜRETTİĞİ, TÜM sınıflar için tek bir dağıtım noktası —
/// bkz. modül üstü not. `tag`, `p`nin İLK 8 baytından (bkz. codegen.zig,
/// `TAG_SIZE`/`class_id`) okunan sınıf kimliğidir. Dönüş: `nox_alloc`'lu
/// bir arabellek (8 baytlık `l` uzunluk + N adet `l` çocuk işaretçisi) —
/// çağıran (`traceChildren`) OKUDUKTAN SONRA `nox_free`lemekle YÜKÜMLÜDÜR.
///
/// **NEDEN sabit bir `extern fn` DEĞİL, `dlsym` İLE ÇALIŞMA ZAMANINDA aranan
/// bir sembol — `runtime/stdlib_shims/json.zig`nin `nox_json_make_json_value`
/// çözümlemesiyle BİREBİR AYNI gerekçe (bkz. onun belge notu):** bu sembol
/// yalnızca SINIF İÇEREN bir programda üretilir (`generateModule`, bkz.
/// `genTraceDispatch`) — sınıfSIZ bir programda YA DA `noxrt.o`yu HİÇ bir
/// Nox programı OLMADAN test eden `noxrt_test` hedefinde (bkz. `zig build
/// test`) HİÇ ÜRETİLMEZ. Sabit bir `extern fn` bu durumlarda bağlama
/// adımını "symbol not found" ile ÇÖKERTİRDİ; `dlsym` bunun yerine sembolü
/// bulamayınca `null` döner, `traceChildren` bunu "çocuğu yok" olarak GÜVENLE
/// yorumlar (bu doğrudur: sınıfSIZ bir programda `nox_cycle_possible_root`
/// zaten HİÇ ÇAĞRILMAZ, çünkü onu tetikleyen `genClassRelease` de YOK).
fn resolveTraceDispatch() ?*const fn (?*anyopaque, i64, ?*anyopaque) callconv(.c) ?*anyopaque {
    return resolveSymbol(fn (?*anyopaque, i64, ?*anyopaque) callconv(.c) ?*anyopaque, &g_trace_dispatch_resolved, &g_trace_dispatch_fn, "nox_trace_dispatch");
}
// Faz BB.1 (bkz. nox-teknik-spesifikasyon.md §3.47): `threadlocal` —
// `nox.json.zig`nin `g_make_json_value_fn`ıyla AYNI gerekçe (idempotent
// dlsym önbelleği, ama `nox.thread.spawn` SONRASI eşzamanlı YAZIM artık
// mümkün olduğundan senkronize-olmayan bir paylaşım TANIMSIZ DAVRANIŞTIR).
threadlocal var g_trace_dispatch_resolved = false;
threadlocal var g_trace_dispatch_fn: ?*const fn (?*anyopaque, i64, ?*anyopaque) callconv(.c) ?*anyopaque = null;

/// `$ClassName_gc_free(rt, p)`ye dağıtır (bkz. codegen.zig, `genClassGcFree`)
/// — sınıf-TİPLİ OLMAYAN alanları (str/list/Task/Channel/dict) normal
/// şekilde serbest bırakır, SINIF TİPLİ alanlara HİÇ DOKUNMAZ (onlar
/// `collectWhite`in KENDİ özyinelemeli çağrısıyla AYRICA ele alınır — iki
/// kez serbest bırakmayı ÖNLEMEK için), SONRA nesnenin KENDİ belleğini
/// KOŞULSUZ (predecrement OLMADAN — zaten çöp olduğu KANITLANMIŞTIR) serbest
/// bırakır. AYNI `dlsym` gerekçesi (bkz. yukarısı).
fn resolveGcFreeDispatch() ?*const fn (?*anyopaque, i64, ?*anyopaque) callconv(.c) void {
    return resolveSymbol(fn (?*anyopaque, i64, ?*anyopaque) callconv(.c) void, &g_gc_free_dispatch_resolved, &g_gc_free_dispatch_fn, "nox_gc_free_dispatch");
}
threadlocal var g_gc_free_dispatch_resolved = false;
threadlocal var g_gc_free_dispatch_fn: ?*const fn (?*anyopaque, i64, ?*anyopaque) callconv(.c) void = null;

fn resolveSymbol(comptime Fn: type, resolved: *bool, cache: *?*const Fn, comptime name: [:0]const u8) ?*const Fn {
    if (resolved.*) return cache.*;
    resolved.* = true;
    const handle = std.c.dlopen(null, .{ .NOW = true }) orelse return null;
    const sym = std.c.dlsym(handle, name) orelse return null;
    cache.* = @ptrCast(@alignCast(sym));
    return cache.*;
}

fn nox_trace_dispatch(rt: ?*anyopaque, tag: i64, p: ?*anyopaque) ?*anyopaque {
    const f = resolveTraceDispatch() orelse return null;
    return f(rt, tag, p);
}

fn nox_gc_free_dispatch(rt: ?*anyopaque, tag: i64, p: ?*anyopaque) void {
    const f = resolveGcFreeDispatch() orelse return;
    f(rt, tag, p);
}

const HEADER_SIZE: usize = 8;

const Color = enum(u2) { black, gray, white, purple };
const GcMeta = struct {
    color: Color = .black,
    buffered: bool = false,
};

/// AGENTS.md §8: "Tarama sıklığı/tetikleyici heuristiği ayarlanabilir
/// olmalı, varsayılan: tahsis baskısı eşiği." — CPython'ın gen0 eşiğine
/// (700) yakın, KEYFİ ama makul bir varsayılan; `nox_cycle_collect`
/// doğrudan da çağrılabilir (ör. testler İÇİN deterministik tetikleme).
const DEFAULT_COLLECT_THRESHOLD: usize = 700;

const CycleGc = struct {
    meta: std.AutoHashMapUnmanaged(*anyopaque, GcMeta) = .empty,
    roots: std.ArrayListUnmanaged(*anyopaque) = .empty,
    possible_roots_since_collect: usize = 0,
    collect_threshold: usize = DEFAULT_COLLECT_THRESHOLD,

    fn deinit(self: *CycleGc, allocator: std.mem.Allocator) void {
        self.meta.deinit(allocator);
        self.roots.deinit(allocator);
    }
};

fn getGc(state: *asap.RuntimeState) *CycleGc {
    if (state.cycle_gc == null) {
        const gc = state.allocator().create(CycleGc) catch @panic("OOM: dongu cozucu");
        gc.* = .{};
        state.cycle_gc = gc;
    }
    return @ptrCast(@alignCast(state.cycle_gc.?));
}

fn refcountOf(p: *anyopaque) *i64 {
    const bytes: [*]u8 = @ptrCast(p);
    return @ptrCast(@alignCast(bytes - HEADER_SIZE));
}

fn readTag(p: *anyopaque) i64 {
    const tag_ptr: *const i64 = @ptrCast(@alignCast(p));
    return tag_ptr.*;
}

const ChildrenBuf = struct {
    items: []?*anyopaque,
    raw_len: usize,

    fn deinit(self: ChildrenBuf, state: *asap.RuntimeState) void {
        // `raw_len == 0` yalnızca `traceChildren`in ZATEN serbest bıraktığı
        // (boş) durumlarda üretilir (bkz. orada) — bu yüzden burada
        // `items.len > 0` GARANTİDİR, `items.ptr - 1` (bir `?*anyopaque`
        // GENİŞLİĞİ, TAM OLARAK `HEADER_SIZE`) GÜVENLE arabelleğin BAŞINA
        // geri döner.
        if (self.raw_len == 0) return;
        const raw_ptr: [*]u8 = @ptrCast(@alignCast(self.items.ptr - 1));
        state.allocator().free(raw_ptr[0..self.raw_len]);
    }
};

/// `$nox_trace_dispatch`i çağırıp dönen ham arabelleği (bkz. modül üstü
/// not) bir Zig dilimine çevirir. `state`, YALNIZCA arabelleği SONRADAN
/// `deinit` ile serbest bırakabilmek İÇİN taşınır (`nox_trace_dispatch`in
/// KENDİSİ `nox_alloc` KULLANDIĞINDAN, serbest bırakma da AYNI allocator'a
/// GİTMELİDİR — bkz. `asap.nox_free`nin sözleşmesi).
fn traceChildren(rt: ?*anyopaque, p: *anyopaque) ChildrenBuf {
    const tag = readTag(p);
    const buf = nox_trace_dispatch(rt, tag, p) orelse return .{ .items = &.{}, .raw_len = 0 };
    const len_ptr: *const i64 = @ptrCast(@alignCast(buf));
    const len: usize = @intCast(@max(len_ptr.*, 0));
    // `len == 0` DAHİL: arabellek HER ZAMAN en az `HEADER_SIZE` bayttır
    // (yalnızca uzunluk alanı) — `ChildrenBuf.deinit` bunu TEK, ORTAK yoldan
    // serbest bırakır (bkz. onun belge notu, `items.ptr - 1` aritmetiği
    // `len == 0` İÇİN de GEÇERLİDİR, çünkü `children_ptr` yine de `buf +
    // HEADER_SIZE`e işaret eder — hiç DEREFERANS edilmese bile).
    const children_ptr: [*]?*anyopaque = @ptrFromInt(@intFromPtr(buf) + HEADER_SIZE);
    return .{ .items = children_ptr[0..len], .raw_len = HEADER_SIZE + len * HEADER_SIZE };
}

/// `runtime/async_rt/scheduler.zig`nin `Task.detached`i İLE AYNI ruhta:
/// çalışma zamanı bağlamı yıkılırken (bkz. `asap.nox_runtime_deinit`)
/// döngü çözücünün KENDİ (nesne meta verisi İÇİN kullandığı) yan tablosunu
/// da serbest bırakır — `asap.zig`nin `cycle_detector.zig`yi IMPORT
/// ETMEDEN (döngüsel bağımlılık kurmadan) bu fonksiyonu ÇAĞIRABİLMESİ İÇİN
/// `extern fn` ile düz bağlanır (bkz. `asap.zig`deki forward declaration).
pub export fn nox_cycle_deinit(rt: ?*anyopaque) void {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return));
    const gc_ptr = state.cycle_gc orelse return;
    const gc: *CycleGc = @ptrCast(@alignCast(gc_ptr));
    gc.deinit(state.allocator());
    state.allocator().destroy(gc);
    state.cycle_gc = null;
}

/// Bacon-Rajan'ın `PossibleRoot(S)`si — bkz. modül üstü not. `codegen.zig`nin
/// `genClassRelease`i, `nox_rc_predecrement` refcount'u SIFIRA
/// DÜŞÜRMEDİĞİNDE (nesne hâlâ CANLI, ama BELKİ bir döngünün parçası) bunu
/// çağırır.
pub export fn nox_cycle_possible_root(rt: ?*anyopaque, p: ?*anyopaque) void {
    const ptr = p orelse return;
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt.?));
    const gc = getGc(state);

    const entry = gc.meta.getOrPut(state.allocator(), ptr) catch return;
    if (!entry.found_existing) entry.value_ptr.* = .{};
    if (entry.value_ptr.color != .purple) {
        entry.value_ptr.color = .purple;
        if (!entry.value_ptr.buffered) {
            entry.value_ptr.buffered = true;
            gc.roots.append(state.allocator(), ptr) catch {};
        }
    }

    gc.possible_roots_since_collect += 1;
    if (gc.possible_roots_since_collect >= gc.collect_threshold) {
        nox_cycle_collect(rt);
    }
}

/// Bir nesne GERÇEKTEN serbest bırakıldığında (refcount 0'a düştüğünde,
/// bkz. `genClassRelease`nin `free_label` dalı) döngü çözücünün YAN
/// TABLOSUNDAKİ olası bir kalıntıyı SİLER — bu, adres YENİDEN
/// KULLANILDIĞINDA (havuzlanmış bir bloğun bir SONRAKİ tahsisi) `nox_cycle_
/// collect`in ESKİ (artık BAŞKA bir nesneye ait) bir `meta` girdisini
/// YANLIŞLIKLA GEÇERLİ sanmasını ÖNLEYEN kritik bir güvenlik adımıdır —
/// `gc.roots` dizisindeki olası bir kalıntı BURADA temizlenmez (O(n)
/// tarama gerektirirdi); bunun yerine `markRoots`/`collectRoots` HER ZAMAN
/// önce `gc.meta`ya (tek yetkili kaynak) bakar, ORADA bulunmayan (bu
/// fonksiyonla SİLİNMİŞ) bir kökü SESSİZCE atlar (bkz. `markRoots`).
pub export fn nox_cycle_forget(rt: ?*anyopaque, p: ?*anyopaque) void {
    const ptr = p orelse return;
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt.?));
    const gc_ptr = state.cycle_gc orelse return; // hiç başlatılmadıysa unutacak bir şey yok
    const gc: *CycleGc = @ptrCast(@alignCast(gc_ptr));
    _ = gc.meta.remove(ptr);
}

/// Üç geçişli Bacon-Rajan taraması — bkz. modül üstü not. `nox_cycle_
/// possible_root` eşik AŞILDIĞINDA OTOMATİK çağırır; testler/GERÇEK
/// programlar deterministik bir toplama İÇİN doğrudan da çağırabilir.
pub export fn nox_cycle_collect(rt: ?*anyopaque) void {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return));
    const gc_ptr = state.cycle_gc orelse return;
    const gc: *CycleGc = @ptrCast(@alignCast(gc_ptr));
    gc.possible_roots_since_collect = 0;

    markRoots(rt, state, gc);
    scanRoots(rt, state, gc);
    collectRoots(rt, state, gc);
}

fn markRoots(rt: ?*anyopaque, state: *asap.RuntimeState, gc: *CycleGc) void {
    for (gc.roots.items) |ptr| {
        const meta = gc.meta.getPtr(ptr) orelse continue; // bkz. `nox_cycle_forget`in belge notu
        if (meta.color == .purple) {
            markGray(rt, state, gc, ptr);
        } else {
            meta.buffered = false;
        }
    }
}

fn markGray(rt: ?*anyopaque, state: *asap.RuntimeState, gc: *CycleGc, ptr: *anyopaque) void {
    const meta = gc.meta.getPtr(ptr) orelse return;
    if (meta.color == .gray) return;
    meta.color = .gray;

    var children = traceChildren(rt, ptr);
    defer children.deinit(state);
    for (children.items) |maybe_child| {
        const child = maybe_child orelse continue;
        refcountOf(child).* -= 1;
        const centry = gc.meta.getOrPut(state.allocator(), child) catch continue;
        if (!centry.found_existing) centry.value_ptr.* = .{};
        markGray(rt, state, gc, child);
    }
}

fn scanRoots(rt: ?*anyopaque, state: *asap.RuntimeState, gc: *CycleGc) void {
    for (gc.roots.items) |ptr| {
        if (gc.meta.getPtr(ptr) == null) continue;
        scan(rt, state, gc, ptr);
    }
}

fn scan(rt: ?*anyopaque, state: *asap.RuntimeState, gc: *CycleGc, ptr: *anyopaque) void {
    const meta = gc.meta.getPtr(ptr) orelse return;
    if (meta.color != .gray) return;
    if (refcountOf(ptr).* > 0) {
        scanBlack(rt, state, gc, ptr);
        return;
    }
    meta.color = .white;
    var children = traceChildren(rt, ptr);
    defer children.deinit(state);
    for (children.items) |maybe_child| {
        const child = maybe_child orelse continue;
        scan(rt, state, gc, child);
    }
}

fn scanBlack(rt: ?*anyopaque, state: *asap.RuntimeState, gc: *CycleGc, ptr: *anyopaque) void {
    const meta = gc.meta.getPtr(ptr) orelse return;
    meta.color = .black;
    var children = traceChildren(rt, ptr);
    defer children.deinit(state);
    for (children.items) |maybe_child| {
        const child = maybe_child orelse continue;
        refcountOf(child).* += 1;
        const centry = gc.meta.getOrPut(state.allocator(), child) catch continue;
        if (!centry.found_existing) centry.value_ptr.* = .{};
        if (centry.value_ptr.color != .black) {
            scanBlack(rt, state, gc, child);
        }
    }
}

fn collectRoots(rt: ?*anyopaque, state: *asap.RuntimeState, gc: *CycleGc) void {
    // Faz S.3: `gc.roots`un bir KOPYASI ÜZERİNDE yinelenmez — asıl liste
    // BU FONKSİYON SONUNDA tamamen temizlenir (aşağı bkz.); `collectWhite`in
    // özyinelemeli çağrıları `gc.roots`u DEĞİŞTİRMEZ (yalnızca `gc.meta`yı),
    // bu yüzden `for (gc.roots.items)` yinelemesi sırasında listenin
    // KENDİSİ sabit kalır.
    for (gc.roots.items) |ptr| {
        const color: Color = if (gc.meta.getPtr(ptr)) |m| blk: {
            m.buffered = false;
            break :blk m.color;
        } else .black;
        if (color == .white) {
            collectWhite(rt, state, gc, ptr);
        }
    }
    gc.roots.clearRetainingCapacity();
}

fn collectWhite(rt: ?*anyopaque, state: *asap.RuntimeState, gc: *CycleGc, ptr: *anyopaque) void {
    const meta = gc.meta.getPtr(ptr) orelse return;
    if (meta.color != .white) return;
    meta.color = .black;

    var children = traceChildren(rt, ptr);
    defer children.deinit(state);
    for (children.items) |maybe_child| {
        const child = maybe_child orelse continue;
        collectWhite(rt, state, gc, child);
    }

    _ = gc.meta.remove(ptr);
    const tag = readTag(ptr);
    nox_gc_free_dispatch(rt, tag, ptr);
}

// ---- Testler ----
//
// `nox_trace_dispatch`/`nox_gc_free_dispatch` (bkz. `resolveTraceDispatch`in
// belge notu) GERÇEK bir QBE-derlenmiş programa (`dlsym`) BAĞLIDIR — bu
// dosyanın SAF Zig birim testleri İÇİN modül-seviyesi `g_trace_dispatch_fn`/
// `g_gc_free_dispatch_fn` ÖNBELLEĞİ DOĞRUDAN SAHTE bir uygulamayla
// DOLDURULUR (bkz. `injectFakeDispatch`) — bu, Bacon-Rajan algoritmasının
// KENDİSİNİ, hiçbir QBE/`noxc` derlemesi OLMADAN, GERÇEK `nox_rc_alloc`'lu
// nesneler ÜZERİNDE (ve `std.testing.allocator` YERİNE `asap.RuntimeState`in
// KENDİ `debug_gpa`si ÜZERİNDEN, tam bir sızıntı/çift-serbest-bırakma
// denetimiyle) doğrulamayı sağlar.

const arc = @import("arc.zig");
const testing = std.testing;

const FAKE_PAYLOAD_SIZE: usize = 16; // TAG_SIZE(8) + 1 alan yuvası(8)

fn fakeTraceDispatch(rt: ?*anyopaque, tag: i64, p: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = tag;
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt.?));
    const field_addr: *const ?*anyopaque = @ptrFromInt(@intFromPtr(p.?) + HEADER_SIZE);
    const buf = state.allocator().alloc(u8, 2 * HEADER_SIZE) catch return null;
    const len_ptr: *i64 = @ptrCast(@alignCast(buf.ptr));
    len_ptr.* = 1;
    const child_ptr: *?*anyopaque = @ptrFromInt(@intFromPtr(buf.ptr) + HEADER_SIZE);
    child_ptr.* = field_addr.*;
    return buf.ptr;
}

// Sabit boyutlu bir arabellek — `g_trace_dispatch_fn`/`g_gc_free_dispatch_fn`
// İLE AYNI modül-seviyesi (TÜM testler arasında PAYLAŞILAN) yaşam süresine
// sahip olduğundan, testler arası `deinit`/yeniden kullanım karmaşasından
// (bir `ArrayListUnmanaged`in GEREKTİRECEĞİ) KAÇINMAK için BİLİNÇLİ olarak
// dinamik değil.
var g_fake_freed_buf: [8]?*anyopaque = @splat(null);
var g_fake_freed_count: usize = 0;

fn fakeGcFreeDispatch(rt: ?*anyopaque, tag: i64, p: ?*anyopaque) callconv(.c) void {
    _ = tag;
    if (g_fake_freed_count < g_fake_freed_buf.len) {
        g_fake_freed_buf[g_fake_freed_count] = p.?;
        g_fake_freed_count += 1;
    }
    arc.nox_rc_free_payload(rt, p, FAKE_PAYLOAD_SIZE);
}

fn injectFakeDispatch() void {
    g_trace_dispatch_resolved = true;
    g_trace_dispatch_fn = &fakeTraceDispatch;
    g_gc_free_dispatch_resolved = true;
    g_gc_free_dispatch_fn = &fakeGcFreeDispatch;
    g_fake_freed_count = 0;
}

/// `p`nin TEK (8 baytlık) alanına `child`i yazar — `self.next = <ifade>`nin
/// codegen'deki karşılığının ÇALIŞMA ZAMANI etkisiyle AYNI (bkz.
/// `genAssign`'ın `.attribute` dalı): yazmadan ÖNCE `child`i retain eder.
fn wireField(p: *anyopaque, child: *anyopaque) void {
    arc.nox_rc_retain(child);
    const field_addr: *?*anyopaque = @ptrFromInt(@intFromPtr(p) + HEADER_SIZE);
    field_addr.* = child;
}

fn newFakeObject(rt: ?*anyopaque) *anyopaque {
    const p = arc.nox_rc_alloc(rt, FAKE_PAYLOAD_SIZE).?;
    const tag_ptr: *i64 = @ptrCast(@alignCast(p));
    tag_ptr.* = 99; // keyfi, `fakeTraceDispatch` tag'e hiç BAKMIYOR
    const field_addr: *?*anyopaque = @ptrFromInt(@intFromPtr(p) + HEADER_SIZE);
    field_addr.* = null;
    return p;
}

/// `genClassRelease`nin ÇALIŞMA ZAMANI davranışının SİMÜLASYONU: predecrement
/// eder, sıfıra düşerse `nox_gc_free_dispatch`e (GERÇEK kodda `$ClassName_
/// gc_free`ye DEĞİL, DOĞRUDAN `nox_rc_free_payload`e — ama testte tag/alan
/// düzeni AYNI olduğundan `fakeGcFreeDispatch` da doğru çalışır), DÜŞMEZSE
/// `nox_cycle_possible_root`e YÖNLENDİRİR.
fn simulateRelease(rt: ?*anyopaque, p: *anyopaque) void {
    if (arc.nox_rc_predecrement(p) != 0) {
        fakeGcFreeDispatch(rt, 99, p);
    } else {
        nox_cycle_possible_root(rt, p);
    }
}

const builtin = @import("builtin");

fn deinitRuntimeExpectNoLeak(rt: ?*anyopaque) !void {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt.?));
    nox_cycle_deinit(rt);
    // `RuntimeState.debug_gpa`nin tipi (bkz. `asap.zig`) yalnızca Debug
    // modunda GERÇEK bir `DebugAllocator`dır — Release modlarında `void`
    // (sızıntı tespiti zaten YAPILMAZ, bkz. `asap.zig`nin modül üstü notu)
    // — bu yüzden `.deinit()` çağrısı YALNIZCA Debug'da anlamlıdır.
    if (builtin.mode == .Debug) {
        const check = state.debug_gpa.deinit();
        try testing.expectEqual(std.heap.Check.ok, check);
    }
    std.heap.page_allocator.destroy(state);
}

test "Faz S.3: gerçek A<->B döngüsü (self-referans YOLUYLA kurulan), nox_cycle_collect ikisini de sızmadan serbest bırakır" {
    injectFakeDispatch();

    const rt = asap.nox_runtime_init() orelse return error.InitFailed;

    const a = newFakeObject(rt);
    const b = newFakeObject(rt);
    wireField(a, b); // a.next = b (b'yi retain eder, RC(b)=2)
    wireField(b, a); // b.next = a (a'yı retain eder, RC(a)=2)

    // İKİ "yerel değişken"in de kapsam dışına çıkması — HİÇBİRİ sıfıra
    // düşmez (RC(a)=RC(b)=1, TAMAMEN birbirlerinden gelen döngüsel katkı) —
    // İKİSİ de `nox_cycle_possible_root`e (mor/olası kök) girer.
    simulateRelease(rt, a);
    simulateRelease(rt, b);

    try testing.expectEqual(@as(i64, 1), refcountOf(a).*);
    try testing.expectEqual(@as(i64, 1), refcountOf(b).*);
    try testing.expectEqual(@as(usize, 0), g_fake_freed_count);

    nox_cycle_collect(rt);

    try testing.expectEqual(@as(usize, 2), g_fake_freed_count);
    var freed_a = false;
    var freed_b = false;
    for (g_fake_freed_buf[0..g_fake_freed_count]) |maybe_p| {
        const p = maybe_p.?;
        if (p == a) freed_a = true;
        if (p == b) freed_b = true;
    }
    try testing.expect(freed_a);
    try testing.expect(freed_b);

    try deinitRuntimeExpectNoLeak(rt);
}

test "Faz S.3: bir döngü İÇİNDEKİ nesne dışarıdan da canlıysa (surviving retain) YANLIŞLIKLA toplanmaz" {
    injectFakeDispatch();

    const rt = asap.nox_runtime_init() orelse return error.InitFailed;

    const a = newFakeObject(rt);
    const b = newFakeObject(rt);
    wireField(a, b); // a.next = b
    wireField(b, a); // b.next = a
    // `b`yi ayrıca "dışarıdan" (ör. bir global/hâlâ canlı bir değişken)
    // TUTAN üçüncü bir retain — bu, `a`nın (yalnızca `b` ÜZERİNDEN,
    // GEÇİŞLİ olarak) canlı kalması İÇİN yeterli olmalıdır.
    arc.nox_rc_retain(b);

    simulateRelease(rt, a); // a'nın TEK dış referansı gider — RC(a)=1 (yalnızca b.next'ten)
    simulateRelease(rt, b); // b'nin ORİJİNAL dış referansı gider — RC(b)=2 (a.next + hayatta kalan)

    try testing.expectEqual(@as(i64, 1), refcountOf(a).*);
    try testing.expectEqual(@as(i64, 2), refcountOf(b).*);

    nox_cycle_collect(rt);

    // HİÇBİRİ toplanmadı — `b`nin GERÇEK dış referansı SAYESİNDE `a` da
    // (b'nin alanı ÜZERİNDEN) geçişli olarak canlı kaldı.
    try testing.expectEqual(@as(usize, 0), g_fake_freed_count);
    try testing.expectEqual(@as(i64, 1), refcountOf(a).*);
    try testing.expectEqual(@as(i64, 2), refcountOf(b).*);

    // Testin KENDİSİ sızdırmasın diye elle temizlik: gerçek bir programda
    // BUNU YAPACAK olan "hayatta kalan" referansın KENDİ SONRAKİ serbest
    // bırakması burada TAKLİT edilir (önce b'nin fazladan retain'i, SONRA
    // her iki nesnenin GERÇEK son referansı).
    arc.nox_rc_release(rt, b, FAKE_PAYLOAD_SIZE); // fazladan retain geri alınır (RC(b)=1)
    simulateRelease(rt, b); // RC(b) 1->0 İSE gc_free; DEĞİLSE tekrar possible_root
    simulateRelease(rt, a);
    nox_cycle_collect(rt);
    try testing.expectEqual(@as(usize, 2), g_fake_freed_count);

    try deinitRuntimeExpectNoLeak(rt);
}

// Faz BB.1: `g_trace_dispatch_fn`/`g_gc_free_dispatch_fn` (+ `_resolved`
// bayrakları) `threadlocal` OLMASININ, bir OS iş parçacığındaki
// `injectFakeDispatch` çağrısının BAŞKA bir iş parçacığının KENDİ (henüz
// çözülmemiş) önbelleğine SIZMADIĞINI kanıtlar.
test "g_trace_dispatch_fn threadlocal: bir iş parçacığındaki enjeksiyon diğerine SIZMAZ" {
    const Ctx = struct {
        resolved_before_inject: bool = undefined,
        fn injectOnThisThread(self: *@This()) void {
            self.resolved_before_inject = g_trace_dispatch_resolved;
            injectFakeDispatch();
        }
    };
    var ctx = Ctx{};
    const t = try std.Thread.spawn(.{}, Ctx.injectOnThisThread, .{&ctx});
    t.join();

    // Enjeksiyon YAPILAN iş parçacığı BAŞLARKEN kendi threadlocal'ı henüz
    // çözülmemiş OLMALIYDI (paylaşılan bir global OLSAYDI, AYNI test
    // ikilisindeki BAŞKA testlerin ÇAĞIRDIĞI `injectFakeDispatch`DEN dolayı
    // BU ZATEN `true` OLABİLİRDİ — threadlocal'la HER iş parçacığı TAZE
    // başlar).
    try testing.expect(!ctx.resolved_before_inject);
    // Test-çalıştırma iş parçacığının (BU fonksiyonun KENDİSİ) KENDİ
    // threadlocal önbelleği, DİĞER iş parçacığın enjeksiyonundan
    // ETKİLENMEMİŞ olmalı (paylaşılan bir global OLSAYDI, `t.join()`
    // SONRASI burada `true` GÖRÜNÜRDÜ).
    if (!g_trace_dispatch_resolved) {
        try testing.expect(g_trace_dispatch_fn == null);
    } else {
        // Bu test dosyasında BAŞKA testler ZATEN bu iş parçacığında
        // `injectFakeDispatch` çağırmış OLABİLİR (testler AYNI iş
        // parçacığında SIRAYLA koşar) — o durumda hedef fonksiyon HER
        // ZAMAN `fakeTraceDispatch` OLMALI, yeni thread'in enjeksiyonundan
        // ETKİLENMEMİŞ olmalı.
        try testing.expect(g_trace_dispatch_fn == &fakeTraceDispatch);
    }
}
