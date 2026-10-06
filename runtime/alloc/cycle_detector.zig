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
//! **Nesne başına renk/buffered durumu NEREDE tutulur (v1.142.14):** ARC
//! başlığının 8 baytlık kelimesi artık BÖLÜNMÜŞTÜR (little-endian): düşük 32
//! bit refcount; bit 32-59 `roots` dizisindeki yuva indeksi; bit 60-61 renk;
//! bit 62 "buffered". Önceki sürümde bu bilgi `ptr_map` yan tablosundaydı
//! (her olası-kök kaydı = global kilit + hash yazımı + `forget`te hash silme;
//! ikili ağaç benchmark'ında süre %90+ burada geçiyordu). Artık kayıt: başlık
//! okuması + dizi eklemesi; `forget`: başlık okuması + O(1) tombstone. SADECE
//! döngüsel olabilen SINIF örnekleri bayrak taşır; string/liste başlıkları
//! DEĞİŞMEZ. Sınıf serbest bırakmanın sıfır testi `(kelime & RC_MASK) == 0`
//! olmalıdır (`emitInlinePredecrement`, `nox_rc_predecrement`).
//!
//! **Çocukları KEŞFETME (`traceChildren`):** derleyici EN AZ BİR sınıf İÇEREN
//! HER programda, HER sınıf İÇİN bir `$ClassName_trace(rt, p) -> l` üretir
//! (bkz. codegen.zig, `genClassTrace`) — SINIF TİPLİ alanların DEĞERLERİNİ
//! küçük, `nox_alloc`'lu bir arabelleğe (8 baytlık uzunluk başlığı + N adet
//! 8 baytlık işaretçi, `list[T]`nin AYNI düzeni) yazıp döner;
//! `$nox_trace_dispatch(rt, tag, p) -> l` bu fonksiyonları çalışma zamanı
//! sınıf ETİKETİNE (`tag`, her örneğin İLK 8 baytı) göre DAĞITIR. Faz F.0.1
//! (bkz. proje planı "Freestanding Nox — dlopen/dlsym-tabanlı dispatch'i
//! statik, 'push' modeli bir kayıt mekanizmasına çevirme") ÖNCESİ bu sembol
//! `dlsym` İLE ÇALIŞMA ZAMANINDA ARANIYORDU — ARTIK `dispatch_registry`nin
//! (bkz. onun modül üstü notu) program-başlangıcında BİR KEZ kaydedilen,
//! statik tablosu KULLANILIYOR.

const std = @import("std");
const asap = @import("asap.zig");
const dispatch_registry = @import("dispatch_registry.zig");
const abi_layout = @import("abi_layout");
/// Faz MN.6: `runtime/alloc/`den `runtime/async_rt/`e — `asap.zig`nin
/// `spinlock.zig` İçİn ZATEN yaptığı AYNI yön, SORUNSUZ (`self_pipe.zig`
/// SIFIR-bağımlılıklı bir yaprak dosya, `runtime/async_rt/`nin standalone
/// sınırını BOZMAZ — SADECE `runtime/alloc/`den ONA BAKMAK, TERSİ DEĞİL,
/// yasak olan yöndü). YENİ bir STW round'u BAŞLATILDIĞINDA (bkz. `nox_
/// cycle_possible_root`) TÜM worker'ların wake-fd'lerini uyandırmak İçİn.
const self_pipe = @import("../async_rt/self_pipe.zig");

/// Faz F.0.7 (bkz. plan dosyası "Kritik düzeltme #3"in çözümü): `nox_cycle_
/// possible_root`nin havuz-uyandırma dalı (aşağıda) `state.pool_ext.?.
/// pool_wake_fds`'i (`posix.fd_t`, freestanding'de `void`) `@intCast`
/// İLE koşulsuz analiz ediyordu — `bridge.zig`nin `nox_async_init`indeki
/// AYNI kök nedenle (`state.worker_pool` bir ÇALIŞMA-ZAMANI kontrolü,
/// F.2'nin capability allowlist'i freestanding'de GERÇEK bir WorkerPool'u
/// ZATEN İMKANSIZ kıldığından bu dal PRATİKTE hiç tetiklenmez).
const is_freestanding = builtin.os.tag == .freestanding or builtin.os.tag == .other;

/// Derleyicinin ÜRETTİĞİ, TÜM sınıflar için tek bir dağıtım noktası —
/// bkz. modül üstü not. `tag`, `p`nin İLK 8 baytından (bkz. codegen.zig,
/// `TAG_SIZE`/`class_id`) okunan sınıf kimliğidir. Dönüş: `nox_alloc`'lu
/// bir arabellek (8 baytlık `l` uzunluk + N adet `l` çocuk işaretçisi) —
/// çağıran (`traceChildren`) OKUDUKTAN SONRA `nox_free`lemekle YÜKÜMLÜDÜR.
/// Faz F.0.1'DEN İTİBAREN `dispatch_registry.traceFn()` (bkz. onun modül
/// üstü notu) KULLANILIR — `null` İSE (`nox_register_dispatch_table` HİÇ
/// çağrılmadıysa, ör. `noxrt_test`) "çocuğu yok" OLARAK GÜVENLE yorumlanır.
fn nox_trace_dispatch(rt: ?*anyopaque, tag: i64, p: ?*anyopaque) ?*anyopaque {
    const f = dispatch_registry.traceFn() orelse return null;
    return f(rt, tag, p);
}

/// `$ClassName_gc_free(rt, p)`ye dağıtır (bkz. codegen.zig, `genClassGcFree`)
/// — sınıf-TİPLİ OLMAYAN alanları (str/list/Task/Channel/dict) normal
/// şekilde serbest bırakır, SINIF TİPLİ alanlara HİÇ DOKUNMAZ (onlar
/// `collectWhite`in KENDİ özyinelemeli çağrısıyla AYRICA ele alınır — iki
/// kez serbest bırakmayı ÖNLEMEK için), SONRA nesnenin KENDİ belleğini
/// KOŞULSUZ (predecrement OLMADAN — zaten çöp olduğu KANITLANMIŞTIR) serbest
/// bırakır. AYNI `dispatch_registry` gerekçesi (bkz. yukarısı).
fn nox_gc_free_dispatch(rt: ?*anyopaque, tag: i64, p: ?*anyopaque) void {
    const f = dispatch_registry.gcFreeFn() orelse return;
    f(rt, tag, p);
}

// Faz P1.2: ÖNCEDEN buradaki TEK `HEADER_SIZE` sabiti (sayısal olarak
// hepsi 8, ama üç AYRI ABI gerçeği) İKİ FARKLI amaç İçin kullanılıyordu:
// (1) `refcountOf`nin ARC refcount başlığı ofseti, (2) `traceChildren`nin
// trace-buffer uzunluk ön-eki/yuva boyutu. `newFakeObject`/`wireField`/
// `fakeTraceDispatch` test yardımcıları da AYRICA (3) sınıf tipi
// ETİKETİNİN (`TAG_SIZE`) boyutunu BU AYNI sabitle temsil ediyordu. Bu ÜÇÜ
// SESSİZCE ÇAKIŞIYORDU (hepsi 8) — biri diverge ederse DİĞERİ fark
// etmeden yanlış yorumlanırdı. `abi_layout`den AYRI adlarla re-export
// edilerek disentangle edilir (bkz. o dosyanın belge notu).
const ARC_HEADER_SIZE = abi_layout.ARC_HEADER_SIZE;
const TAG_SIZE = abi_layout.TAG_SIZE;
const TRACE_BUF_LEN_SIZE = abi_layout.TRACE_BUF_LEN_SIZE;
const TRACE_BUF_SLOT_SIZE = abi_layout.TRACE_BUF_SLOT_SIZE;

const Color = enum(u2) { black, gray, white, purple };

/// Başlık kelimesi düzeni (bkz. modül üstü not).
const RC_MASK: u64 = 0xFFFF_FFFF;
const IDX_SHIFT: u6 = 32;
const IDX_MASK: u64 = ((@as(u64, 1) << 28) - 1) << IDX_SHIFT;
const COLOR_SHIFT: u6 = 60;
const COLOR_MASK: u64 = @as(u64, 3) << COLOR_SHIFT;
const BUFFERED_BIT: u64 = @as(u64, 1) << 62;
const FLAG_MASK: u64 = IDX_MASK | COLOR_MASK | BUFFERED_BIT;

fn hdrWord(p: *anyopaque) *u64 {
    const bytes: [*]u8 = @ptrCast(p);
    return @ptrCast(@alignCast(bytes - ARC_HEADER_SIZE));
}

fn getColor(p: *anyopaque) Color {
    return @enumFromInt(@as(u2, @truncate(hdrWord(p).* >> COLOR_SHIFT)));
}

/// Yalnızca toplama (kilit altında, dünya durmuşken) çağrılır — düz RMW.
fn setColor(p: *anyopaque, c: Color) void {
    const h = hdrWord(p);
    h.* = (h.* & ~COLOR_MASK) | (@as(u64, @intFromEnum(c)) << COLOR_SHIFT);
}

fn isBuffered(p: *anyopaque) bool {
    return hdrWord(p).* & BUFFERED_BIT != 0;
}

fn clearFlags(p: *anyopaque) void {
    const h = hdrWord(p);
    h.* &= ~FLAG_MASK;
}

/// Gerçek refcount (düşük 32 bit).
fn rcValue(p: *anyopaque) i64 {
    return @intCast(hdrWord(p).* & RC_MASK);
}

/// AGENTS.md §8: "Tarama sıklığı/tetikleyici heuristiği ayarlanabilir
/// olmalı, varsayılan: tahsis baskısı eşiği." — CPython'ın gen0 eşiğine
/// (700) yakın, KEYFİ ama makul bir varsayılan; `nox_cycle_collect`
/// doğrudan da çağrılabilir (ör. testler İÇİN deterministik tetikleme).
const DEFAULT_COLLECT_THRESHOLD: usize = 700;

/// v1.142.5 (bkz. nox-teknik-spesifikasyon.md §3.244): uyarlanabilir eşiğin
/// ÜST sınırı. Büyük, ÇÖP OLMAYAN, kendine işaret eden yapılar (ör. 2M
/// düğümlü ikili ağaç) üzerinde her 700 olası-kökte tüm alt-grafiği baştan
/// dolaşan sabit eşik ikinci-dereceden maliyet üretiyordu (ağaç benchmark'ı:
/// C'den 111x yavaş, Python'dan 4x yavaş, süre %75 döngü çözücüde). Nim
/// ORC'nun `rootsThreshold` ayarlamasıyla AYNI fikir: bir toplama VERİMSİZ
/// (serbest bırakılan < taranan kökün 1/4'ü) ise eşik ikiye katlanır (bu üst
/// sınıra kadar), VERİMLİ ise varsayılana döner. `roots` + `meta` bellek
/// maliyeti sınırı: ~1M kök ≈ 8 MB (roots) en kötü durumda.
const MAX_COLLECT_THRESHOLD: usize = 1 << 24;

const CycleGc = struct {
    /// `null` girdiler: `nox_cycle_forget`in tombstone'ları (serbest bırakılmış kök).
    roots: std.ArrayListUnmanaged(?*anyopaque) = .empty,
    possible_roots_since_collect: usize = 0,
    collect_threshold: usize = DEFAULT_COLLECT_THRESHOLD,
    /// Son `collectRoots`in serbest bıraktığı nesne sayısı (uyarlanabilir eşik İçin).
    freed_in_collect: usize = 0,
    /// Son `markGray`in ziyaret ettiği düğüm sayısı: bir toplamın maliyeti ~bununla orantılı,
    /// eşik de buna göre ölçeklenir (toplama başına maliyet ≥ 2 kayıtla amorti edilir).
    visited_in_collect: usize = 0,
    /// v1.142.14: `$Sınıf_trace` arabelleği için yeniden kullanılan TEK tampon (toplama
    /// kilit altında serileşiktir ve arabellek ziyaret başına tam bir kez
    /// alınıp bırakılır — LIFO). Her ziyarette `nox_alloc`/`free` çifti yoktu
    /// ikili ağaç profilinde süreyi %40 şişiriyordu.
    scratch: []u8 = &.{},
    scratch_in_use: bool = false,

    fn deinit(self: *CycleGc, allocator: std.mem.Allocator) void {
        if (self.scratch.len > 0) allocator.rawFree(self.scratch, asap.nox_alloc_alignment, @returnAddress());
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
        // GENİŞLİĞİ, TAM OLARAK `TRACE_BUF_LEN_SIZE`) GÜVENLE arabelleğin
        // BAŞINA geri döner.
        if (self.raw_len == 0) return;
        const raw_ptr: [*]u8 = @ptrCast(@alignCast(self.items.ptr - 1));
        traceBufFree(state, raw_ptr, self.raw_len);
    }
};

/// v1.142.14: üretilen `$Sınıf_trace` fonksiyonlarının arabellek tahsisi (eskiden
/// `$nox_alloc`). Toplama sırasında (kilit altında, ziyaret başına bir kez, LIFO)
/// çağrıldığından yeniden kullanılan tek bir tampon yeterlidir; tampon meşgulse
/// (savunmacı) normal tahsise düşer. `traceBufFree` ikisini de ayırt eder.
pub export fn nox_trace_buf_alloc(rt: ?*anyopaque, size: usize) ?*anyopaque {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    const gc = getGc(state);
    if (!gc.scratch_in_use) {
        if (size > gc.scratch.len) {
            if (gc.scratch.len > 0) state.allocator().rawFree(gc.scratch, asap.nox_alloc_alignment, @returnAddress());
            gc.scratch = &.{};
            const cap = @max(size, 256);
            const mem = state.allocator().alignedAlloc(u8, asap.nox_alloc_alignment, cap) catch return null;
            gc.scratch = mem;
        }
        gc.scratch_in_use = true;
        return gc.scratch.ptr;
    }
    return asap.nox_alloc(rt, size);
}

fn traceBufFree(state: *asap.RuntimeState, ptr: [*]u8, raw_len: usize) void {
    const gc = getGc(state);
    if (gc.scratch.len > 0 and ptr == gc.scratch.ptr) {
        gc.scratch_in_use = false;
        return;
    }
    state.allocator().rawFree(ptr[0..raw_len], asap.nox_alloc_alignment, @returnAddress());
}

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
    // `len == 0` DAHİL: arabellek HER ZAMAN en az `TRACE_BUF_LEN_SIZE`
    // bayttır (yalnızca uzunluk alanı) — `ChildrenBuf.deinit` bunu TEK,
    // ORTAK yoldan serbest bırakır (bkz. onun belge notu, `items.ptr - 1`
    // aritmetiği `len == 0` İÇİN de GEÇERLİDİR, çünkü `children_ptr` yine
    // de `buf + TRACE_BUF_LEN_SIZE`e işaret eder — hiç DEREFERANS edilmese
    // bile).
    const children_ptr: [*]?*anyopaque = @ptrFromInt(@intFromPtr(buf) + TRACE_BUF_LEN_SIZE);
    return .{ .items = children_ptr[0..len], .raw_len = TRACE_BUF_LEN_SIZE + len * TRACE_BUF_SLOT_SIZE };
}

/// `runtime/async_rt/scheduler.zig`nin `Task.detached`i İLE AYNI ruhta:
/// çalışma zamanı bağlamı yıkılırken (bkz. `asap.nox_runtime_deinit`)
/// döngü çözücünün KENDİ (nesne meta verisi İÇİN kullandığı) yan tablosunu
/// da serbest bırakır — `asap.zig`nin `cycle_detector.zig`yi IMPORT
/// ETMEDEN (döngüsel bağımlılık kurmadan) bu fonksiyonu ÇAĞIRABİLMESİ İÇİN
/// `extern fn` ile düz bağlanır (bkz. `asap.zig`deki forward declaration).
pub export fn nox_cycle_deinit(rt: ?*anyopaque) void {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return));
    state.cycle_gc_lock.lock();
    defer state.cycle_gc_lock.unlock();
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
    // Faz MN.3b: TÜM fonksiyon TEK bir kilit ALTINDA — eşik AŞILDIĞINDA
    // `collectLocked`i (`nox_cycle_collect`in KENDİSİNİ DEĞİL, aşağıya
    // bkz.) DOĞRUDAN çağırır, AKSİ HALDE `nox_cycle_collect`in KENDİ
    // kilidini TEKRAR almaya ÇALIŞIR — bu SpinLock YENİDEN-GİRİLEBİLİR
    // (reentrant) DEĞİLDİR, KENDİ KENDİSİYLE KİLİTLENİRDİ.
    // Hızlı yol (kilitsiz): zaten tamponda VE mor — yapılacak bir şey yok.
    // Aynı nesne kısa aralıklarla tekrar tekrar bırakılırken (ör. yerel alias'ların
    // kapsam sonu release'i) global kilit + dizi eklemesi tamamen atlanır.
    {
        const w0 = @atomicLoad(u64, hdrWord(ptr), .monotonic);
        if (w0 & BUFFERED_BIT != 0 and (w0 & COLOR_MASK) == (@as(u64, @intFromEnum(Color.purple)) << COLOR_SHIFT)) return;
    }
    state.cycle_gc_lock.lock();
    defer state.cycle_gc_lock.unlock();
    const gc = getGc(state);

    // Kilit altında yeniden kontrol (hızlı yol kilitsiz okur).
    const h = hdrWord(ptr);
    if (h.* & BUFFERED_BIT != 0) {
        // Zaten tamponda (toplamalar arasında buffered ⇒ mor; savunmacı olarak
        // atomik olarak mora çek — başka bir iş parçacığı refcount'u aynı kelimede
        // eşzamanlı değiştiriyor olabilir).
        _ = @atomicRmw(u64, h, .And, ~COLOR_MASK, .monotonic);
        _ = @atomicRmw(u64, h, .Or, @as(u64, @intFromEnum(Color.purple)) << COLOR_SHIFT, .monotonic);
        return;
    }
    const idx = gc.roots.items.len;
    gc.roots.append(state.allocator(), ptr) catch return;
    // Refcount'u eşzamanlı artıran/azaltan iş parçacıklarıyla (atomik ARC) çakışmamak
    // için tek atomik OR: renk=mor, buffered, yuva indeksi.
    const set: u64 = BUFFERED_BIT | (@as(u64, @intFromEnum(Color.purple)) << COLOR_SHIFT) | ((@as(u64, @intCast(idx)) << IDX_SHIFT) & IDX_MASK);
    _ = @atomicRmw(u64, h, .Or, set, .monotonic);

    gc.possible_roots_since_collect += 1;
    // Faz MN.6: havuzsuz İSE (BUGÜNKÜ gibi) DOĞRUDAN, SENKRON collect —
    // SIFIR davranış değişikliği. Havuzlu İSE (Faz MN.4/5.4'ün GEÇİCİ
    // "koşulsuz devre dışı bırakma" ÖNLEMİNİN YERİNE) `pool_stw_requested`i
    // `cmpxchgStrong` İLE ayarla — SADECE bu YARIŞI KAZANAN çağrı YENİ bir
    // STW round'u BAŞLATIR (bkz. `asap.RuntimeState`nin AYNI-adlı alanının
    // belge notu). GERÇEK collect, `runtime/async_rt/scheduler.zig`nin
    // `stwParticipate`i TARAFINDAN, TÜM worker'lar KENDİ safe point'lerinde
    // bariyerde BULUŞTUĞUNDA ASENKRON olarak çalışır — BU fonksiyon
    // ÇAĞIRAN fiber'ı HİÇ BLOKE ETMEDEN HEMEN döner. Sonra, `reactor.
    // poll()`de bloke olmuş (GERÇEK, İLİŞKİSİZ G/Ç bekleyen) worker'ları
    // DERHAL uyandırmak İçİn TÜM DOLU `pool_wake_fds` slotlarına bir bayt
    // yazılır (AKSİ HALDE `io_reactor.zig`nin `poll()`ü NULL/-1 zaman
    // aşımıyla SONSUZA KADAR bloke KALIR, `stw_requested`i HİÇ FARK ETMEZ).
    if (gc.possible_roots_since_collect >= gc.collect_threshold) {
        if (state.worker_pool == null) {
            collectLocked(rt, state, gc);
        } else if (comptime !is_freestanding) {
            // Faz [YENİ] (bkz. plan dosyası "STW bariyeri kilitlenmesi
            // düzeltmesi" — GERÇEK bir gdb backtrace'İYLE bulunan, önceden
            // var olan bir yarış): ÖNCEDEN `cmpxchgStrong` TEK BAŞINA (bkz.
            // `pool_stw_requested`in belge notu) YARIŞI KAZANAN çağrıyı
            // belirliyordu AMA `pool_active_workers`e (bir worker'ın AYNI
            // ANDA `run()`dan KALICI çıkışıyla) HİÇBİR karşılıklı-dışlama
            // SAĞLAMIYORDU — `pool_stw_lock` ALTINDA yapmak (`scheduler.
            // zig`nin `tryPermanentExit`inin AYNI kilidi kullanması SAYESİNDE)
            // BU İKİ olayı SERİLEŞTİRİR. Kilit ALTINDA "zaten true mu"
            // kontrolü, `cmpxchgStrong`in "SADECE YARIŞI KAZANAN" garantisiyle
            // AYNI (kilit SAYESİNDE artık GERÇEK bir CAS'a GEREK YOK — hiçbir
            // BAŞKA iş parçacığı AYNI ANDA BU değeri DEĞİŞTİREMEZ).
            const ext = state.pool_ext.?;
            ext.pool_stw_lock.lock();
            const already_requested = ext.pool_stw_requested.load(.monotonic);
            if (!already_requested) {
                // `pool_active_workers`in O ANKİ değeri BU round'un
                // katılımcı sayısı OLARAK DONDURULUR (bkz. `stwParticipate`nin
                // `stw_round_n` okumasının belge notu) — `pool_stw_requested`in
                // HEMEN ALTINDAKİ `.release` store, BU yazmayı da (program
                // sırasına göre ÖNCE olduğundan) senkronize eder.
                ext.pool_stw_round_n.store(ext.pool_active_workers.load(.monotonic), .monotonic);
                ext.pool_stw_requested.store(true, .release);
            }
            ext.pool_stw_lock.unlock();
            if (!already_requested and builtin.os.tag != .windows) {
                for (&ext.pool_wake_fds) |*fd_atomic| {
                    const fd = fd_atomic.load(.monotonic);
                    if (fd >= 0) self_pipe.signalWakeFd(@intCast(fd));
                }
            }
        }
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
    // Hızlı yol: tamponda değilse (çoğu nesne) yapılacak bir şey yok — kilit yok.
    if (!isBuffered(ptr)) return;
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt.?));
    state.cycle_gc_lock.lock();
    defer state.cycle_gc_lock.unlock();
    const gc_ptr = state.cycle_gc orelse return; // hiç başlatılmadıysa unutacak bir şey yok
    const gc: *CycleGc = @ptrCast(@alignCast(gc_ptr));
    const idx: usize = @intCast((hdrWord(ptr).* & IDX_MASK) >> IDX_SHIFT);
    if (idx < gc.roots.items.len and gc.roots.items[idx] == ptr) gc.roots.items[idx] = null;
    clearFlags(ptr);
}

/// Üç geçişli Bacon-Rajan taraması — bkz. modül üstü not. `nox_cycle_
/// possible_root` eşik AŞILDIĞINDA OTOMATİK çağırır; testler/GERÇEK
/// programlar deterministik bir toplama İÇİN doğrudan da çağırabilir.
pub export fn nox_cycle_collect(rt: ?*anyopaque) void {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return));
    state.cycle_gc_lock.lock();
    defer state.cycle_gc_lock.unlock();
    const gc_ptr = state.cycle_gc orelse return;
    const gc: *CycleGc = @ptrCast(@alignCast(gc_ptr));
    collectLocked(rt, state, gc);
}

/// Faz MN.3b: `nox_cycle_collect`in KENDİSİNDEN VE `nox_cycle_possible_
/// root`un eşik-aşıldı dalından (ZATEN `cycle_gc_lock` TUTULUYORKEN)
/// PAYLAŞILAN, KİLİTSİZ çekirdek — bkz. `nox_cycle_possible_root`un belge
/// notu, "YENİDEN-GİRİLEBİLİR DEĞİL" gerekçesi.
fn collectLocked(rt: ?*anyopaque, state: *asap.RuntimeState, gc: *CycleGc) void {
    gc.possible_roots_since_collect = 0;
    gc.freed_in_collect = 0;
    gc.visited_in_collect = 0;
    const scanned = gc.roots.items.len;
    markRoots(rt, state, gc);
    scanRoots(rt, state, gc);
    collectRoots(rt, state, gc);
    // Uyarlanabilir eşik (bkz. `MAX_COLLECT_THRESHOLD`): verimsiz toplama →
    // sıklığı azalt; verimli → varsayılan.
    if (scanned > 0 and gc.freed_in_collect * 4 < scanned) {
        // Amortizasyon: bir toplamın maliyeti ~ziyaret edilen düğüm sayısı;
        // eşik en az bunun 2 katı olsun (toplama başına maliyet kayıt başına O(1)).
        const by_visits = gc.visited_in_collect *| 2;
        gc.collect_threshold = @min(@max(gc.collect_threshold *| 2, by_visits), MAX_COLLECT_THRESHOLD);
    } else {
        gc.collect_threshold = DEFAULT_COLLECT_THRESHOLD;
    }
}

fn markRoots(rt: ?*anyopaque, state: *asap.RuntimeState, gc: *CycleGc) void {
    for (gc.roots.items) |maybe_ptr| {
        const ptr = maybe_ptr orelse continue; // `nox_cycle_forget` tombstone'u
        if (getColor(ptr) == .purple) {
            markGray(rt, state, gc, ptr);
        } else {
            // Orijinal `meta.buffered = false`: yalnızca buffered/yuva bayrakları
            // temizlenir, RENK korunur (kök zaten başka bir kökün alt-grafiğinde
            // gri/beyaz boyanmış olabilir).
            hdrWord(ptr).* &= ~(BUFFERED_BIT | IDX_MASK);
        }
    }
}

/// GG.23 (bkz. plan dosyası "fiber-stack sertleştirmesi"): Zig-çağrı-yığını
/// (dolayısıyla fiber'ın SABİT yığını) ÜZERİNDE ÖZYİNELEMELİ DEĞİL —
/// worklist HEAP'te. v1.142.14: renk başlıkta; bir düğüm gri boyanırken
/// (itme anında) işaretlenir, bu yüzden her düğüm tam bir kez işlenir.
fn markGray(rt: ?*anyopaque, state: *asap.RuntimeState, gc: *CycleGc, root: *anyopaque) void {
    if (getColor(root) == .gray) return;
    var stack: std.ArrayListUnmanaged(*anyopaque) = .empty;
    defer stack.deinit(state.allocator());
    setColor(root, .gray);
    stack.append(state.allocator(), root) catch return;
    while (stack.pop()) |ptr| {
        gc.visited_in_collect += 1;

        var children = traceChildren(rt, ptr);
        defer children.deinit(state);
        for (children.items) |maybe_child| {
            const child = maybe_child orelse continue;
            hdrWord(child).* -%= 1;
            if (getColor(child) == .gray) continue;
            setColor(child, .gray);
            stack.append(state.allocator(), child) catch continue;
        }
    }
}

fn scanRoots(rt: ?*anyopaque, state: *asap.RuntimeState, gc: *CycleGc) void {
    for (gc.roots.items) |maybe_ptr| {
        const ptr = maybe_ptr orelse continue;
        scan(rt, state, gc, ptr);
    }
}

/// `markGray`İLE AYNI iteratif dönüşüm — `scanBlack`e devretme (`rcValue > 0`)
/// dalı `scanBlack`i DOĞRUDAN çağırır (SIRALI çalışır, aynı anda DEĞİL).
fn scan(rt: ?*anyopaque, state: *asap.RuntimeState, gc: *CycleGc, root: *anyopaque) void {
    _ = gc;
    var stack: std.ArrayListUnmanaged(*anyopaque) = .empty;
    defer stack.deinit(state.allocator());
    stack.append(state.allocator(), root) catch return;
    while (stack.pop()) |ptr| {
        if (getColor(ptr) != .gray) continue;
        if (rcValue(ptr) > 0) {
            scanBlack(rt, state, ptr);
            continue;
        }
        setColor(ptr, .white);
        var children = traceChildren(rt, ptr);
        defer children.deinit(state);
        for (children.items) |maybe_child| {
            const child = maybe_child orelse continue;
            if (getColor(child) != .gray) continue; // zaten işlenmiş (beyaz/siyah)
            stack.append(state.allocator(), child) catch continue;
        }
    }
}

/// GG.23 — KRİTİK, İNCE bir doğruluk noktası: LIFO worklist'te AYNI pointer
/// İKİ KEZ push EDİLEBİLİR; ikinci pop'ta TEKRAR işlenirse çocukların
/// refcount'u YANLIŞLIKLA İKİ KEZ artırılırdı. Bu yüzden POP ANINDA `siyah
/// mı` kontrolü ŞART (bkz. `scanBlack` diamond testi). Refcount artışı her
/// zaman ebeveynin çocuk döngüsünde, push'tan ÖNCE koşulsuzdur.
fn scanBlack(rt: ?*anyopaque, state: *asap.RuntimeState, root: *anyopaque) void {
    var stack: std.ArrayListUnmanaged(*anyopaque) = .empty;
    defer stack.deinit(state.allocator());
    stack.append(state.allocator(), root) catch return;
    while (stack.pop()) |ptr| {
        if (getColor(ptr) == .black) continue;
        setColor(ptr, .black);
        var children = traceChildren(rt, ptr);
        defer children.deinit(state);
        for (children.items) |maybe_child| {
            const child = maybe_child orelse continue;
            hdrWord(child).* +%= 1;
            if (getColor(child) != .black) {
                stack.append(state.allocator(), child) catch continue;
            }
        }
    }
}

/// Beyaz (kanıtlanmış çöp) alt-grafikleri TOPLAR ve serbest bırakır. v1.142.14:
/// renk/meta artık başlıkta olduğundan, serbest bırakılmış bir düğümün
/// başlığı (havuz bağlı-listesi işaretçisiyle ÜZERİNE YAZILIR) BİR DAHA
/// OKUNMAMALIDIR — bu yüzden iki aşama: (1) hiçbir şey serbest bırakılmadan
/// tüm beyaz düğümler tespit edilir (itme anında siyaha boyanır, her düğüm
/// tam bir kez listelenir), (2) hepsi serbest bırakılır. `gc_free` sınıf-
/// tipli çocuklara dokunmadığından sıra güvenlik için önemsizdir.
fn collectRoots(rt: ?*anyopaque, state: *asap.RuntimeState, gc: *CycleGc) void {
    var whites: std.ArrayListUnmanaged(*anyopaque) = .empty;
    defer whites.deinit(state.allocator());
    var stack: std.ArrayListUnmanaged(*anyopaque) = .empty;
    defer stack.deinit(state.allocator());

    // Önce TÜM köklerin buffered bayrağını temizle + rengini oku (hiçbir şey
    // henüz serbest bırakılmadığından başlıklar geçerli).
    for (gc.roots.items) |maybe_ptr| {
        const ptr = maybe_ptr orelse continue;
        const was_white = getColor(ptr) == .white;
        // Buffered/indeks bayraklarını temizle, rengi koru (white ayrımı için).
        const h = hdrWord(ptr);
        h.* &= ~(BUFFERED_BIT | IDX_MASK);
        if (!was_white) continue;
        setColor(ptr, .black);
        stack.append(state.allocator(), ptr) catch continue;
        whites.append(state.allocator(), ptr) catch continue;
        while (stack.pop()) |cur| {
            var children = traceChildren(rt, cur);
            defer children.deinit(state);
            for (children.items) |maybe_child| {
                const child = maybe_child orelse continue;
                if (getColor(child) != .white) continue;
                setColor(child, .black);
                stack.append(state.allocator(), child) catch continue;
                whites.append(state.allocator(), child) catch continue;
            }
        }
    }
    gc.roots.clearRetainingCapacity();

    for (whites.items) |ptr| {
        const tag = readTag(ptr);
        nox_gc_free_dispatch(rt, tag, ptr);
        gc.freed_in_collect += 1;
    }
}

// ---- Testler ----
//
// `nox_trace_dispatch`/`nox_gc_free_dispatch` (bkz. `dispatch_registry`nin
// modül üstü notu) GERÇEK bir QBE-derlenmiş programın `$main`'ının yaptığı
// `nox_register_dispatch_table` ÇAĞRISINA BAĞLIDIR — bu dosyanın SAF Zig
// birim testleri İçİn `dispatch_registry`nin PAYLAŞILAN, program-genelindeki
// tablosu DOĞRUDAN SAHTE bir uygulamayla DOLDURULUR (bkz. `injectFakeDispatch`)
// — bu, Bacon-Rajan algoritmasının
// KENDİSİNİ, hiçbir QBE/`noxc` derlemesi OLMADAN, GERÇEK `nox_rc_alloc`'lu
// nesneler ÜZERİNDE (ve `std.testing.allocator` YERİNE `asap.RuntimeState`in
// KENDİ `debug_gpa`si ÜZERİNDEN, tam bir sızıntı/çift-serbest-bırakma
// denetimiyle) doğrulamayı sağlar.

const arc = @import("arc.zig");
const testing = std.testing;
const FIELD_SLOT_SIZE = abi_layout.FIELD_SLOT_SIZE;

/// Faz MN.3b: `pub` — `runtime/async_rt/worker_pool.zig`nin KENDİ eşzamanlı
/// testi de BU sahte dispatch enjeksiyon desenini (BU dosyanın KENDİ
/// testleriyle AYNI) yeniden kullanır.
pub const FAKE_PAYLOAD_SIZE: usize = TAG_SIZE + FIELD_SLOT_SIZE; // 1 alan yuvası

fn fakeTraceDispatch(rt: ?*anyopaque, tag: i64, p: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = tag;
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt.?));
    // Sahte nesnenin TEK alanı, etiketten (`TAG_SIZE`) HEMEN SONRA oturur —
    // bu, ARC başlığı/trace-buffer'la SAYISAL olarak ÇAKIŞSA da AYRI bir
    // ABI gerçeğidir (bkz. `abi_layout.TAG_SIZE`nin belge notu).
    const field_addr: *const ?*anyopaque = @ptrFromInt(@intFromPtr(p.?) + TAG_SIZE);
    // `ChildrenBuf.deinit`in (asap.nox_alloc_alignment İLE) serbest
    // bıraktığı AYNI hizalama İLE tahsis edilmeli.
    const buf = state.allocator().alignedAlloc(u8, asap.nox_alloc_alignment, TRACE_BUF_LEN_SIZE + TRACE_BUF_SLOT_SIZE) catch return null;
    const len_ptr: *i64 = @ptrCast(@alignCast(buf.ptr));
    len_ptr.* = 1;
    const child_ptr: *?*anyopaque = @ptrFromInt(@intFromPtr(buf.ptr) + TRACE_BUF_LEN_SIZE);
    child_ptr.* = field_addr.*;
    return buf.ptr;
}

// Sabit boyutlu bir arabellek — `dispatch_registry`nin KENDİSİ GİBİ modül-
// seviyesi (TÜM testler arasında PAYLAŞILAN) yaşam süresine sahip olduğundan,
// testler arası `deinit`/yeniden kullanım karmaşasından
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

/// Faz MN.3b: `pub` — bkz. `FAKE_PAYLOAD_SIZE`in belge notu. Faz F.0.1'DEN
/// İTİBAREN sahte dispatch, `dispatch_registry`nin (bkz. onun modül üstü
/// notu) TEK, PAYLAŞILAN kayıt tablosuna, GERÇEK bir programın `genMain`/
/// `genMainAsync`'ının yapacağı AYNI `nox_register_dispatch_table`
/// çağrısıyla ENJEKTE edilir — testin KENDİSİ HİÇBİR "önbellek"e DOĞRUDAN
/// dokunmaz (ARTIK böyle bir önbellek YOK, tablo GLOBAL VE HER ZAMAN
/// GÜNCEL).
pub fn injectFakeDispatch() void {
    dispatch_registry.nox_register_dispatch_table(&fakeTraceDispatch, &fakeGcFreeDispatch, null, null, null);
    g_fake_freed_count = 0;
}

/// `p`nin TEK (8 baytlık) alanına `child`i yazar — `self.next = <ifade>`nin
/// codegen'deki karşılığının ÇALIŞMA ZAMANI etkisiyle AYNI (bkz.
/// `genAssign`'ın `.attribute` dalı): yazmadan ÖNCE `child`i retain eder.
/// Faz MN.6: `pub` — `worker_pool.zig`nin KENDİ eşzamanlı otomatik-collect
/// stres testi de BU sahte A<->B döngü kurma desenini yeniden kullanır.
pub fn wireField(p: *anyopaque, child: *anyopaque) void {
    arc.nox_rc_retain(child);
    const field_addr: *?*anyopaque = @ptrFromInt(@intFromPtr(p) + TAG_SIZE);
    field_addr.* = child;
}

/// Faz MN.3b: `pub` — bkz. `FAKE_PAYLOAD_SIZE`in belge notu.
pub fn newFakeObject(rt: ?*anyopaque) *anyopaque {
    const p = arc.nox_rc_alloc(rt, FAKE_PAYLOAD_SIZE).?;
    const tag_ptr: *i64 = @ptrCast(@alignCast(p));
    tag_ptr.* = 99; // keyfi, `fakeTraceDispatch` tag'e hiç BAKMIYOR
    const field_addr: *?*anyopaque = @ptrFromInt(@intFromPtr(p) + TAG_SIZE);
    field_addr.* = null;
    return p;
}

test "v1.142.14: başlık bayrakları — possible_root tamponlar, tekrar çağrı çoğaltmaz, forget tombstone'lar, refcount bozulmaz" {
    injectFakeDispatch();
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt));

    const a = newFakeObject(rt);
    arc.nox_rc_retain(a); // RC=2
    try testing.expectEqual(@as(i64, 2), rcValue(a));
    nox_cycle_possible_root(rt, a);
    try testing.expect(isBuffered(a));
    try testing.expectEqual(Color.purple, getColor(a));
    try testing.expectEqual(@as(i64, 2), rcValue(a)); // bayraklar refcount'u etkilemez
    nox_cycle_possible_root(rt, a); // hızlı yol — çoğaltmaz
    try testing.expectEqual(@as(usize, 1), getGc(state).roots.items.len);

    // Bayraklı nesnede retain/predecrement düşük 32 bit üzerinde doğru çalışır.
    arc.nox_rc_retain(a);
    try testing.expectEqual(@as(i64, 3), rcValue(a));
    try testing.expectEqual(@as(i32, 0), arc.nox_rc_predecrement(a));
    try testing.expectEqual(@as(i32, 0), arc.nox_rc_predecrement(a));
    try testing.expectEqual(@as(i64, 1), rcValue(a));
    // Son referans: bayraklı olsa BİLE sıfır testi doğru (1 döndürür).
    try testing.expectEqual(@as(i32, 1), arc.nox_rc_predecrement(a));

    // forget: kök yuvası tombstone'lanır, bayraklar temizlenir; collect serbest
    // bırakılmış (burada: bırakılacak) nesneye DOKUNMAZ.
    nox_cycle_forget(rt, a);
    try testing.expect(!isBuffered(a));
    try testing.expectEqual(@as(?*anyopaque, null), getGc(state).roots.items[0]);
    nox_cycle_collect(rt);
    arc.nox_rc_free_payload(rt, a, FAKE_PAYLOAD_SIZE);

    try deinitRuntimeExpectNoLeak(rt);
}

// GG.23 (bkz. plan dosyası "fiber-stack sertleştirmesi"): `scanBlack`nin
// iteratif dönüşümünün KRİTİK doğruluk noktasını (paylaşılan/"elmas" bir
// çocuğun İKİ AYRI ebeveynden erişildiğinde TAM OLARAK BİR KEZ işlenmesi)
// kanıtlayabilmek İçİn `newFakeObject`/`fakeTraceDispatch`in TEK-alanlı
// (1 çocuk) sınırını AŞAN, 2-alanlı (2 çocuk) bir sahte nesne türü.

/// `TAG=2` OLAN nesneler İçİn payload boyutu — `fakeTraceDispatchDiamond`/
/// `fakeGcFreeDispatchDiamond` BU etikete göre 2-alanlı düzeni SEÇER.
pub const FAKE_PAYLOAD_SIZE_2: usize = TAG_SIZE + 2 * FIELD_SLOT_SIZE;

/// `wireField`in İNDEKSLİ genellemesi — `p`nin `slot`'ıncı (0-tabanlı)
/// alanına `child`i yazar (retain EDEREK).
fn wireFieldAt(p: *anyopaque, slot: usize, child: *anyopaque) void {
    arc.nox_rc_retain(child);
    const field_addr: *?*anyopaque = @ptrFromInt(@intFromPtr(p) + TAG_SIZE + slot * FIELD_SLOT_SIZE);
    field_addr.* = child;
}

/// `newFakeObject`in 2-alanlı kardeşi — `tag=2` (aşağıdaki `fakeTraceDispatchDiamond`/
/// `fakeGcFreeDispatchDiamond`nin AYIRT ETMESİ İçİn, `newFakeObject`in
/// `tag=99`sundan FARKLI).
fn newFakeObject2(rt: ?*anyopaque) *anyopaque {
    const p = arc.nox_rc_alloc(rt, FAKE_PAYLOAD_SIZE_2).?;
    const tag_ptr: *i64 = @ptrCast(@alignCast(p));
    tag_ptr.* = 2;
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        const field_addr: *?*anyopaque = @ptrFromInt(@intFromPtr(p) + TAG_SIZE + i * FIELD_SLOT_SIZE);
        field_addr.* = null;
    }
    return p;
}

/// `fakeTraceDispatch`in TAG-FARKINDA genellemesi: `tag==2` İSE 2 alanı,
/// AKSİ HALDE (`fakeTraceDispatch`İLE AYNI, tag=99) TEK alanı raporlar —
/// TEK bir enjekte edilmiş dispatch fonksiyonuyla HEM 1-alanlı HEM
/// 2-alanlı sahte nesnelerin AYNI ANDA (elmas testinde OLDUĞU GİBİ)
/// KARIŞTIRILABİLMESİ İçİn.
fn fakeTraceDispatchDiamond(rt: ?*anyopaque, tag: i64, p: ?*anyopaque) callconv(.c) ?*anyopaque {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt.?));
    const n_fields: usize = if (tag == 2) 2 else 1;
    // `fakeTraceDispatch`in AYNI gerekçesi — `ChildrenBuf.deinit`in
    // hizalamasıyla EŞLEŞMELİ.
    const buf = state.allocator().alignedAlloc(u8, asap.nox_alloc_alignment, TRACE_BUF_LEN_SIZE + n_fields * TRACE_BUF_SLOT_SIZE) catch return null;
    const len_ptr: *i64 = @ptrCast(@alignCast(buf.ptr));
    len_ptr.* = @intCast(n_fields);
    const children_ptr: [*]?*anyopaque = @ptrFromInt(@intFromPtr(buf.ptr) + TRACE_BUF_LEN_SIZE);
    var i: usize = 0;
    while (i < n_fields) : (i += 1) {
        const field_addr: *const ?*anyopaque = @ptrFromInt(@intFromPtr(p.?) + TAG_SIZE + i * FIELD_SLOT_SIZE);
        children_ptr[i] = field_addr.*;
    }
    return buf.ptr;
}

fn fakeGcFreeDispatchDiamond(rt: ?*anyopaque, tag: i64, p: ?*anyopaque) callconv(.c) void {
    if (g_fake_freed_count < g_fake_freed_buf.len) {
        g_fake_freed_buf[g_fake_freed_count] = p.?;
        g_fake_freed_count += 1;
    }
    const size: usize = if (tag == 2) FAKE_PAYLOAD_SIZE_2 else FAKE_PAYLOAD_SIZE;
    arc.nox_rc_free_payload(rt, p, size);
}

fn injectFakeDispatchDiamond() void {
    dispatch_registry.nox_register_dispatch_table(&fakeTraceDispatchDiamond, &fakeGcFreeDispatchDiamond, null, null, null);
    g_fake_freed_count = 0;
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

// v3 madde 3 (ownership/ptr[T] red-team, bkz. nox-teknik-spesifikasyon.md
// ilgili bölüm): `wireField`, HEM retain eder HEM alanı `fakeTraceDispatch`in
// GÖRECEĞİ konuma YAZAR — GERÇEK bir `self.next = child` atamasının BİREBİR
// modelidir. AŞAĞIDAKİ test BİLİNÇLİ olarak `wireField` KULLANMAZ — SADECE
// `arc.nox_rc_retain`i DOĞRUDAN çağırıp alanı BOŞ (`null`) bırakır — bu,
// `genClassTrace`nin (`compiler/codegen_qbe/layout.zig`) `list`/`dict`
// TİPLİ bir alanı (GERÇEK bir `a.children.append(b)`nin YAPTIĞI GİBİ
// `b`yi RETAIN EDER ama `$Node_trace`nin ÜRETTİĞİ alan listesine HİÇ
// GİRMEZ, ÇÜNKÜ o fonksiyon YALNIZCA `f.info.heap == .class` alanları
// TOPLAR) davranışının BİREBİR SİMÜLASYONUDUR — **BU DAVRANIŞ v3 madde 3
// İLE `compiler/codegen_qbe/layout.zig`nin `genClassTrace`ı DÜZELTİLDİ**
// (list/dict-of-class alanları da İZLENİYOR); BU test HÂLÂ (BİLİNÇLİ
// olarak) `wireField` KULLANMADAN, DÜZELTME-ÖNCESİ davranışı TAKLİT ederek
// KALICI bir REGRESYON kilidi olarak KALIYOR (derleyicinin KENDİSİ düzeldi,
// AMA algoritmanın "trace hiçbir çocuk raporlamazsa döngü KESİNLİKLE
// KAÇIRILIR" özelliği DOĞRU/beklenen — bu test O KURALI kanıtlıyor).
test "v3 madde 3: trace() çocuk raporlamazsa (list/dict-of-class alanının DÜZELTME-ÖNCESİ simülasyonu) A<->B döngüsü nox_cycle_collect TARAFINDAN KAÇIRILIR" {
    injectFakeDispatch();

    const rt = asap.nox_runtime_init() orelse return error.InitFailed;

    const a = newFakeObject(rt);
    const b = newFakeObject(rt);
    arc.nox_rc_retain(b);
    arc.nox_rc_retain(a);

    simulateRelease(rt, a);
    simulateRelease(rt, b);

    try testing.expectEqual(@as(i64, 1), rcValue(a));
    try testing.expectEqual(@as(i64, 1), rcValue(b));

    nox_cycle_collect(rt);

    try testing.expectEqual(@as(usize, 0), g_fake_freed_count);

    arc.nox_rc_release(rt, b, FAKE_PAYLOAD_SIZE);
    arc.nox_rc_release(rt, a, FAKE_PAYLOAD_SIZE);

    try deinitRuntimeExpectNoLeak(rt);
}

test "v1.142.5: uyarlanabilir eşik — verimsiz toplama eşiği büyütür, verimli (çöp bulan) toplama varsayılana döndürür" {
    injectFakeDispatch();
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt));

    // CANLI nesneler: dış bir "yerel değişken" referansı (RC=2) tutulur, sonra bir
    // referans bırakılır (RC=1 → olası kök) — ama nesne HÂLÂ canlı (verimsiz kök).
    var live: [20]*anyopaque = undefined;
    for (&live) |*slot| {
        slot.* = newFakeObject(rt);
        arc.nox_rc_retain(slot.*); // RC=2
    }
    for (live) |p| simulateRelease(rt, p); // RC=1, olası kök (canlı)

    const gc = getGc(state);
    try testing.expectEqual(DEFAULT_COLLECT_THRESHOLD, gc.collect_threshold);
    nox_cycle_collect(rt); // 20 kök, 0 serbest → VERİMSİZ
    try testing.expectEqual(DEFAULT_COLLECT_THRESHOLD * 2, gc.collect_threshold);
    // Tekrar verimsiz → tekrar ikiye katlanır.
    for (live) |p| {
        arc.nox_rc_retain(p);
        simulateRelease(rt, p);
    }
    nox_cycle_collect(rt);
    try testing.expectEqual(DEFAULT_COLLECT_THRESHOLD * 4, gc.collect_threshold);

    // Gerçek çöp döngüsü → VERİMLİ toplama (2 serbest / 2 kök) → eşik varsayılana döner.
    const a = newFakeObject(rt);
    const b = newFakeObject(rt);
    wireField(a, b);
    wireField(b, a);
    simulateRelease(rt, a);
    simulateRelease(rt, b);
    nox_cycle_collect(rt);
    try testing.expectEqual(@as(usize, 2), g_fake_freed_count);
    try testing.expectEqual(DEFAULT_COLLECT_THRESHOLD, gc.collect_threshold);

    // Canlıları temizle (kalan dış referanslar).
    for (live) |p| arc.nox_rc_release(rt, p, FAKE_PAYLOAD_SIZE);
    try deinitRuntimeExpectNoLeak(rt);
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

    try testing.expectEqual(@as(i64, 1), rcValue(a));
    try testing.expectEqual(@as(i64, 1), rcValue(b));
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

    try testing.expectEqual(@as(i64, 1), rcValue(a));
    try testing.expectEqual(@as(i64, 2), rcValue(b));

    nox_cycle_collect(rt);

    // HİÇBİRİ toplanmadı — `b`nin GERÇEK dış referansı SAYESİNDE `a` da
    // (b'nin alanı ÜZERİNDEN) geçişli olarak canlı kaldı.
    try testing.expectEqual(@as(usize, 0), g_fake_freed_count);
    try testing.expectEqual(@as(i64, 1), rcValue(a));
    try testing.expectEqual(@as(i64, 2), rcValue(b));

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

// GG.23 (bkz. plan dosyası "fiber-stack sertleştirmesi", Madde 1): bu
// test, iteratif `scanBlack`nin (bkz. onun KENDİ belge notu) POP-anı
// "zaten siyah mı" kontrolünün GERÇEKTEN load-bearing olduğunu kanıtlar
// — `root -> [d, b]` VE `b -> d` (yani `d`, `root`TAN HEM DOĞRUDAN HEM
// `b` ÜZERİNDEN erişilen PAYLAŞILAN/"elmas" bir çocuk) yapısı KURULUP
// `scanBlack` DOĞRUDAN (possible_root/markGray/scan boru hattı
// ATLANARAK — BEYAZ-KUTU bir birim testi, SADECE bu fonksiyonun KENDİ
// döngü-güvenliğini hedefler) çağrılır. `d`nin TEK çocuğu `e`nin
// refcount'unun TAM OLARAK 1 ARTMASI beklenir (`d`nin traceChildren'ı
// TAM OLARAK BİR KEZ çalışmalı, `root`+`b`nin İKİSİ de `d`yi "henüz
// siyah değil" olarak GÖRÜP push ETSE BİLE).
test "GG.23: scanBlack paylaşılan (elmas) bir çocuğun kendi alt-ağacını TAM OLARAK bir kez işler" {
    injectFakeDispatchDiamond();

    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt));

    const e = newFakeObject(rt); // d'nin TEK gerçek çocuğu
    const d = newFakeObject(rt);
    wireField(d, e); // d -> e
    const b = newFakeObject(rt);
    wireField(b, d); // b -> d (d'ye İKİNCİ bir gerçek kenar)
    const root = newFakeObject2(rt);
    wireFieldAt(root, 0, d); // root -> d (DOĞRUDAN)
    wireFieldAt(root, 1, b); // root -> b

    // `markGray`/`scan`nin BU üç düğümü ZATEN gri işaretlediği bir ANI
    // simüle eder — `scanBlack`nin KENDİSİ `nox_cycle_possible_root`/
    // `markGray`/`scan` ÇAĞRILMADAN doğrudan test edilir (beyaz-kutu).
    const gc = getGc(state);
    _ = gc;
    setColor(root, .gray);
    setColor(d, .gray);
    setColor(b, .gray);

    const e_refcount_before = rcValue(e);

    scanBlack(rt, state, root);

    // ANA İDDİA: `d`nin traceChildren'ı TAM OLARAK BİR KEZ çalıştı —
    // POP-anı "zaten siyah mı" kontrolü KALDIRILSAYDI (orijinal, GÜVENSİZ
    // davranış) `e`nin refcount'u BURADA +2 OLURDU (d, HEM root'un HEM
    // b'nin push'ları YÜZÜNDEN İKİ KEZ işlenirdi).
    try testing.expectEqual(e_refcount_before + 1, rcValue(e));
    try testing.expectEqual(Color.black, getColor(root));
    try testing.expectEqual(Color.black, getColor(d));
    try testing.expectEqual(Color.black, getColor(b));

    // Temizlik: BU test `nox_cycle_collect`i (VE dolayısıyla GERÇEK
    // serbest-bırakmayı) hiç ÇAĞIRMADI — 4 nesnenin payload'ları DOĞRUDAN
    // serbest bırakılır (SAF test temizliği, gerçek program semantiği
    // SİMÜLE EDİLMEZ — bu testin KENDİSİ zaten `scanBlack`in yığın
    // güvenliğini kanıtladı).
    arc.nox_rc_free_payload(rt, root, FAKE_PAYLOAD_SIZE_2);
    arc.nox_rc_free_payload(rt, d, FAKE_PAYLOAD_SIZE);
    arc.nox_rc_free_payload(rt, b, FAKE_PAYLOAD_SIZE);
    arc.nox_rc_free_payload(rt, e, FAKE_PAYLOAD_SIZE);

    try deinitRuntimeExpectNoLeak(rt);
}

// Faz F.0.1 (bkz. proje planı "Freestanding Nox — dlopen/dlsym-tabanlı
// dispatch'i statik, 'push' modeli bir kayıt mekanizmasına çevirme"):
// ÖNCEKİ tasarımda (`threadlocal` dlsym önbelleği) BU test AKSİNE bir OS
// iş parçacığındaki enjeksiyonun DİĞERİNE SIZMADIĞINI kanıtlıyordu — YENİ
// tasarımda `dispatch_registry` KASITLI olarak PROGRAM-genelinde TEK, PAYLAŞILAN
// bir tablo (GERÇEK bir programda `$main`nin EN BAŞINDA, HERHANGİ bir
// worker/iş parçacığı spawn EDİLMEDEN ÖNCE, TEK SEFER kaydedilir — TÜM
// worker'ların AYNI, TEK dispatch tablosunu GÖRMESİ TAM OLARAK istenen
// davranıştır, İZOLASYON DEĞİL). Bu YÜZDEN test TERSİNE ÇEVRİLDİ: BAŞKA
// bir OS iş parçacığında YAPILAN kayıt, `t.join()`nin (happens-before
// kenarı) SONRASI BU iş parçacığından da GÖRÜNÜR OLMALIDIR.
test "dispatch_registry: bir iş parçacığındaki kayıt, join() sonrası TÜM iş parçacıklarından GÖRÜNÜR" {
    const Ctx = struct {
        fn registerOnThisThread(_: *@This()) void {
            dispatch_registry.nox_register_dispatch_table(&fakeTraceDispatch, &fakeGcFreeDispatch, null, null, null);
        }
    };
    var ctx = Ctx{};
    const t = try std.Thread.spawn(.{}, Ctx.registerOnThisThread, .{&ctx});
    t.join();

    try testing.expect(dispatch_registry.traceFn() == &fakeTraceDispatch);
    try testing.expect(dispatch_registry.gcFreeFn() == &fakeGcFreeDispatch);
}
