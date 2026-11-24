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
/// `+atomics` açık wasm (ADR-015) iş parçacıklı olduğundan yerel (freestanding olmayan) yolları kullanır; çıplak donanım/tek iş parçacıklı wasm "freestanding" kalır.
const is_freestanding = (builtin.os.tag == .freestanding or builtin.os.tag == .other) and !(builtin.cpu.arch.isWasm() and std.Target.wasm.featureSetHas(builtin.cpu.features, .atomics));

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
    return abi_ptr.ptr(?*anyopaque, f(abi_ptr.arg(rt), tag, abi_ptr.arg(p)));
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
    f(abi_ptr.arg(rt), tag, abi_ptr.arg(p));
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
/// Faz 9.0 F1: yuva indeksi 28 → 26 bit (≈ 67 milyon kök); 58 `SHARED`, 59 `LOCK` bitlerine (bkz. `shared_obj.zig`) yer açar.
const IDX_BITS: u6 = 26;
const MAX_ROOT_IDX: usize = (@as(usize, 1) << IDX_BITS) - 1;
const IDX_MASK: u64 = ((@as(u64, 1) << IDX_BITS) - 1) << IDX_SHIFT;
const COLOR_SHIFT: u6 = 60;
const COLOR_MASK: u64 = @as(u64, 3) << COLOR_SHIFT;
const BUFFERED_BIT: u64 = @as(u64, 1) << 62;
const FLAG_MASK: u64 = IDX_MASK | COLOR_MASK | BUFFERED_BIT;

// wasm32: Zig 64-bit atomikleri derlemez; `atomic64` (iş parçacıklı kipte `i64.atomic.*`, tek iş parçacıklıda düz erişim) kullanılır.
const wasm_hdr = builtin.cpu.arch.isWasm();

fn hdrLoad(h: *u64) u64 {
    return if (comptime wasm_hdr) atomic64.load(u64, h) else @atomicLoad(u64, h, .monotonic);
}

fn hdrAnd(h: *u64, m: u64) void {
    if (comptime wasm_hdr) _ = atomic64.rmw(u64, .@"and", h, m) else _ = @atomicRmw(u64, h, .And, m, .monotonic);
}

fn hdrOr(h: *u64, m: u64) void {
    if (comptime wasm_hdr) _ = atomic64.rmw(u64, .@"or", h, m) else _ = @atomicRmw(u64, h, .Or, m, .monotonic);
}

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
    /// v2.1.79 (TODO 4.5.4): tamponda hâlâ CANLI (tombstone olmayan) kök sayısı. `nox_cycle_forget` düşürür; tombstone oranı yüksekse `compactRoots` diziyi sıkıştırır.
    live_roots: usize = 0,
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
    /// F: paralel toplama yapılandırması (bkz. `parConfigure`). `par_threads < 2` ⇒ her zaman sıralı.
    par_threads: usize = 0,
    /// Önceki toplamanın ziyaret ettiği düğüm sayısı bu değere ulaştıysa sonraki toplama paralel çalışır (iş parçacığı başlatma maliyeti amorti olsun).
    par_min_visited: usize = PAR_MIN_VISITED_DEFAULT,
    par_aux: [PAR_MAX_WORKERS]?*asap.RuntimeState = @splat(null),
    /// Paralel yolun çalıştırıldığı toplama sayısı (tanılama/test).
    par_runs: usize = 0,
    /// YALNIZCA test derlemesi (GPT-6 P0.2): `N != 0` ise işaretleme/tarama iş listesinin N'inci itişi `error.OutOfMemory` ile başarısız olur (bellek-yetersizliği enjeksiyonu).
    test_fail_pushes: usize = 0,
    /// R1-P1.5 (v2.2.52): collect aşamasında kaydedilemeyen (OOM) beyaz düğüm sayısı (sızar, serbest bırakılmaz); tanılama/test.
    dropped_whites: usize = 0,
    /// P1.4: bayt baskısı adımı (bkz. `rearmPressure`).
    pressure_step: usize = asap.GC_PRESSURE_BASE,

    fn deinit(self: *CycleGc, allocator: std.mem.Allocator) void {
        for (&self.par_aux) |*slot| {
            if (slot.*) |aux| {
                nox_cycle_deinit(@ptrCast(aux));
                asap.destroyAuxState(aux);
                slot.* = null;
            }
        }
        if (self.scratch.len > 0) allocator.rawFree(self.scratch, asap.nox_alloc_alignment, @returnAddress());
        self.roots.deinit(allocator);
    }
};

fn getGc(state: *asap.RuntimeState) *CycleGc {
    if (state.cycle_gc == null) {
        const gc = state.allocator().create(CycleGc) catch @panic("OOM: dongu cozucu");
        gc.* = .{};
        parConfigure(gc);
        state.cycle_gc = gc;
    }
    return @ptrCast(@alignCast(state.cycle_gc.?));
}

fn readTag(p: *anyopaque) i64 {
    const tag_ptr: *const i64 = @ptrCast(@alignCast(p));
    return tag_ptr.*;
}

const ChildrenBuf = struct {
    items: []abi_ptr.Slot,
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
    const children_ptr: [*]abi_ptr.Slot = @ptrFromInt(@intFromPtr(buf) + TRACE_BUF_LEN_SIZE);
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

/// `compactRoots`un tetiklenmesi için en küçük dizi uzunluğu (küçük dizilerde sıkıştırma maliyeti kazançtan büyüktür).
const COMPACT_MIN_LEN: usize = 8192;

/// v2.1.79: `gc.roots` içindeki tombstone'ları (`null`) atıp canlı kökleri öne taşır ve her taşınan nesnenin başlığındaki yuva indeksini günceller. Çağıran
/// `cycle_gc_lock`u TUTMALIDIR. Eşzamanlı sayaç güncellemeleri başlığın düşük bitlerine atomik yazar; indeks bitleri yalnızca bu kilit altında değiştiğinden
/// `hdrAnd`+`hdrOr` çifti güvenlidir. Amortize O(1): sıkıştırma ≥ 3/4 tombstone varken çalışır.
fn compactRoots(gc: *CycleGc) void {
    var w: usize = 0;
    for (gc.roots.items) |maybe| {
        const ptr = maybe orelse continue;
        if (w < gc.roots.items.len) gc.roots.items[w] = ptr;
        const h = hdrWord(ptr);
        hdrAnd(h, ~IDX_MASK);
        hdrOr(h, (@as(u64, @intCast(w)) << IDX_SHIFT) & IDX_MASK);
        w += 1;
    }
    gc.roots.shrinkRetainingCapacity(w);
}

/// `nox_cycle_collect` sonunda kök tablosunun korunacağı en büyük kapasite (eleman sayısı); aşan kapasite bırakılır.
const ROOTS_KEEP_CAPACITY: usize = 4096;

/// Bacon-Rajan'ın `PossibleRoot(S)`si — bkz. modül üstü not. `codegen.zig`nin
/// `genClassRelease`i, `nox_rc_predecrement` refcount'u SIFIRA
/// DÜŞÜRMEDİĞİNDE (nesne hâlâ CANLI, ama BELKİ bir döngünün parçası) bunu
/// çağırır.
/// B1/I3 (2.3): havuz hiç etkinleşmediyse (`pool_ever_active == false`) bu `RuntimeState`i yalnızca TEK bir iş parçacığı kullanır (fiber'lar kooperatiftir, `nox.thread` çocuklarının KENDİ rt'si vardır),
/// bu yüzden olası-kök kaydı/forget için kilit gereksizdir: kilit al/bırak (2 atomik işlem) AST/ağaç iş yüklerinde düğüm başına ödeniyordu. Havuz yaratılmadan ÖNCE hiçbir ikinci iş parçacığı bu rt'ye dokunamaz,
/// bu yüzden "kilitsiz → kilitli" geçişi yarışsızdır. wasm'da (paylaşımlı bellekli iş parçacıkları) eski davranış korunur.
inline fn gcLockIfShared(state: *asap.RuntimeState) bool {
    if (comptime builtin.cpu.arch.isWasm()) {
        state.cycle_gc_lock.lock();
        return true;
    }
    if (!state.pool_ever_active.load(.monotonic)) return false;
    state.cycle_gc_lock.lock();
    return true;
}

inline fn gcUnlockIfShared(state: *asap.RuntimeState, locked: bool) void {
    if (locked) state.cycle_gc_lock.unlock();
}

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
        const w0 = hdrLoad(hdrWord(ptr));
        if (w0 & BUFFERED_BIT != 0 and (w0 & COLOR_MASK) == (@as(u64, @intFromEnum(Color.purple)) << COLOR_SHIFT)) return;
    }
    const locked = gcLockIfShared(state);
    defer gcUnlockIfShared(state, locked);
    const gc = getGc(state);

    // Kilit altında yeniden kontrol (hızlı yol kilitsiz okur).
    const h = hdrWord(ptr);
    if (h.* & BUFFERED_BIT != 0) {
        // Zaten tamponda (toplamalar arasında buffered ⇒ mor; savunmacı olarak
        // atomik olarak mora çek — başka bir iş parçacığı refcount'u aynı kelimede
        // eşzamanlı değiştiriyor olabilir).
        hdrAnd(h, ~COLOR_MASK);
        hdrOr(h, @as(u64, @intFromEnum(Color.purple)) << COLOR_SHIFT);
        return;
    }
    // v2.1.79: tombstone'lar (serbest bırakılan köklerin boş yuvaları) dizinin ≥ 3/4'ünü kaplıyorsa önce sıkıştır: kısa ömürlü, döngüye elverişli nesneler
    // (zincir/ağaç/graf düğümleri) her tur kök olarak kaydedilip bırakılırken tampon ve toplama sıklığı sınırsız şişmesin.
    if (gc.roots.items.len >= COMPACT_MIN_LEN and gc.roots.items.len >= 4 * gc.live_roots) compactRoots(gc);
    const idx = gc.roots.items.len;
    if (idx > MAX_ROOT_IDX) return; // yuva indeksi başlık alanına sığmaz: bu nesne kök olarak kaydedilmez (yalnızca döngü toplama kaçırılır, güvenlik etkilenmez)
    gc.roots.append(state.allocator(), ptr) catch return;
    gc.live_roots += 1;
    // Refcount'u eşzamanlı artıran/azaltan iş parçacıklarıyla (atomik ARC) çakışmamak
    // için tek atomik OR: renk=mor, buffered, yuva indeksi.
    const set: u64 = BUFFERED_BIT | (@as(u64, @intFromEnum(Color.purple)) << COLOR_SHIFT) | ((@as(u64, @intCast(idx)) << IDX_SHIFT) & IDX_MASK);
    hdrOr(h, set);

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
    // P1.4: büyük bloklarda bayt baskısı da toplamayı tetikler (`asap.RuntimeState.gc_pressure`; yalnızca tamponda kök varken buraya gelinir).
    if (gc.possible_roots_since_collect >= gc.collect_threshold or state.gc_pressure.load(.monotonic)) {
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
            if (!already_requested and builtin.os.tag != .windows and comptime !builtin.cpu.arch.isWasm()) {
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
    const locked = gcLockIfShared(state);
    defer gcUnlockIfShared(state, locked);
    const gc_ptr = state.cycle_gc orelse return; // hiç başlatılmadıysa unutacak bir şey yok
    const gc: *CycleGc = @ptrCast(@alignCast(gc_ptr));
    const idx: usize = @intCast((hdrWord(ptr).* & IDX_MASK) >> IDX_SHIFT);
    if (idx < gc.roots.items.len and gc.roots.items[idx] == ptr) {
        gc.roots.items[idx] = null;
        if (gc.live_roots > 0) gc.live_roots -= 1;
        // Toplama baskısı da düşer: serbest bırakılan kök artık toplanacak bir aday değil (aksi halde hep canlı-olmayan kayıtlar eşiği tetikler ve verimsiz toplamalar eşiği katlar).
        if (gc.possible_roots_since_collect > 0) gc.possible_roots_since_collect -= 1;
    }
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
    if (comptime gcTimingAvailable) {
        if (state.rcstat_on) {
            const t0 = nowNs();
            collectLockedInner(rt, state, gc);
            const dt = nowNs() -| t0;
            const g = &state.gcstat;
            g[0] += 1;
            g[1] += dt;
            g[2] = @max(g[2], dt);
            g[3] += gc.visited_in_collect;
            g[4] += gc.freed_in_collect;
            g[5] = gc.par_runs;
            const us = dt / 1000;
            const bucket: usize = if (us == 0) 0 else @min(@as(usize, 64 - @clz(us)), 23);
            g[8 + bucket] += 1;
            return;
        }
    }
    collectLockedInner(rt, state, gc);
}

/// E0: yalnızca hosted, Windows olmayan hedeflerde (tanılama aracı).
const gcTimingAvailable = !is_freestanding and !builtin.cpu.arch.isWasm() and builtin.os.tag != .windows;

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// P1.4: baskı toplamasından sonra bayrağı indirir ve bir sonraki eşiği kurar: canlı büyük bayt + adım. Baskıyla yapılan toplama (kökün dörtte birinden azını serbest bıraktıysa) verimsizse adım
/// ikiye katlanır (üst sınırlı) — büyük, canlı, döngüsel bir yapı için tekrarlı boş tarama olmaz; verimliyse taban adıma döner. Baskısız toplamada adım değişmez.
fn rearmPressure(state: *asap.RuntimeState, gc: *CycleGc, by_pressure: bool, scanned: usize) void {
    if (by_pressure) {
        const wasted = gc.freed_in_collect * 4 < scanned;
        gc.pressure_step = if (wasted) @min(gc.pressure_step *| 2, MAX_PRESSURE_STEP) else asap.GC_PRESSURE_BASE;
    }
    const net = state.gc_large_bytes.load(.monotonic);
    state.gc_pressure_at.store(net +| gc.pressure_step, .monotonic);
    state.gc_pressure.store(false, .monotonic);
}

const MAX_PRESSURE_STEP: usize = if (@sizeOf(usize) >= 8) 4 * 1024 * 1024 * 1024 else 1024 * 1024 * 1024; // 32-bit hedeflerde (wasm32) 4 GiB `usize`a sığmaz

fn collectLockedInner(rt: ?*anyopaque, state: *asap.RuntimeState, gc: *CycleGc) void {
    const by_pressure = state.gc_pressure.load(.monotonic);
    const scanned_at_start = gc.roots.items.len;
    collectBody(rt, state, gc);
    rearmPressure(state, gc, by_pressure, scanned_at_start);
}

fn collectBody(rt: ?*anyopaque, state: *asap.RuntimeState, gc: *CycleGc) void {
    const prev_visited = gc.visited_in_collect;
    gc.possible_roots_since_collect = 0;
    gc.freed_in_collect = 0;
    gc.visited_in_collect = 0;
    const scanned = gc.roots.items.len;
    if (comptime par_available) {
        if (gc.par_threads >= 2 and prev_visited >= gc.par_min_visited) {
            var whites: std.ArrayListUnmanaged(*anyopaque) = .empty;
            defer whites.deinit(state.allocator());
            if (parMarkScan(state, gc, &whites)) {
                collectRootsFinish(rt, state, gc, &whites);
                adaptThreshold(gc, scanned);
                return;
            }
        }
    }
    markRoots(rt, state, gc);
    scanRoots(rt, state, gc) catch fatalOom();
    collectRoots(rt, state, gc);
    adaptThreshold(gc, scanned);
}

fn adaptThreshold(gc: *CycleGc, scanned: usize) void {
    // Uyarlanabilir eşik (bkz. `MAX_COLLECT_THRESHOLD`): verimsiz toplama →
    // sıklığı azalt; verimli → varsayılan.
    if (scanned > 0 and gc.freed_in_collect * 4 < scanned) {
        // Amortizasyon: bir toplamın maliyeti ~ziyaret edilen düğüm sayısı;
        // eşik en az bunun 2 katı olsun (toplama başına maliyet kayıt başına O(1)).
        const by_visits = gc.visited_in_collect *| 2;
        gc.collect_threshold = @min(@max(gc.collect_threshold *| 2, by_visits), MAX_COLLECT_THRESHOLD);
    } else {
        // K3 (2.3): verimli toplamada bile bir sonraki toplama, ziyaret edilen düğüm sayısının en az 1/4'ü kadar olası-kök kaydından SONRA yapılır: büyük, canlı, döngüsel bir graf (halka/ağaç+geri kenar)
        // her 700 kayıtta baştan sona taranırsa program ~14x yavaşlıyordu (500 bin canlı düğümde yineleme başına 13,9 µs); eşik grafla orantılı olunca toplama maliyeti kayıt başına O(1)'e amortize olur.
        gc.collect_threshold = @min(@max(DEFAULT_COLLECT_THRESHOLD, gc.visited_in_collect / 4), MAX_COLLECT_THRESHOLD);
    }
}

fn markRoots(rt: ?*anyopaque, state: *asap.RuntimeState, gc: *CycleGc) void {
    for (gc.roots.items) |maybe_ptr| {
        const ptr = maybe_ptr orelse continue; // `nox_cycle_forget` tombstone'u
        if (getColor(ptr) == .purple) {
            markGray(rt, state, gc, ptr) catch fatalOom();
        } else {
            // Orijinal `meta.buffered = false`: yalnızca buffered/yuva bayrakları
            // temizlenir, RENK korunur (kök zaten başka bir kökün alt-grafiğinde
            // gri/beyaz boyanmış olabilir).
            hdrWord(ptr).* &= ~(BUFFERED_BIT | IDX_MASK);
        }
    }
}

/// GPT-6 P0.2: işaretleme/tarama (deneme-silme) aşamaları başlık sayaçlarını YERİNDE değiştirir; iş listesi büyütülemeyip bir düğüm atlanırsa sayaçlar tutarsız kalır
/// (özellikle `scanBlack`te geri yüklenmemiş canlı çocuklar ⇒ erken serbest bırakma/UAF). Tutarlı biçimde sürdürülemediği için bu durum SESSİZCE yutulmaz: hata yayılır
/// ve toplama giriş noktasında `fatalOom` ile kesin bir panikle sonlanır (`nox_cycle_collect`in diğer OOM yolu `getGc`nin `@panic`iyle aynı politika).
const WorklistError = error{OutOfMemory};

fn fatalOom() noreturn {
    @panic("OOM: dongu cozucu is listesi buyutulemedi; toplama tutarli surdurulemez");
}

inline fn wlPush(state: *asap.RuntimeState, gc: *CycleGc, list: *std.ArrayListUnmanaged(*anyopaque), item: *anyopaque) WorklistError!void {
    if (comptime builtin.is_test) {
        if (gc.test_fail_pushes != 0) {
            gc.test_fail_pushes -= 1;
            if (gc.test_fail_pushes == 0) return error.OutOfMemory;
        }
    }
    try list.append(state.allocator(), item);
}

/// GG.23 (bkz. plan dosyası "fiber-stack sertleştirmesi"): Zig-çağrı-yığını
/// (dolayısıyla fiber'ın SABİT yığını) ÜZERİNDE ÖZYİNELEMELİ DEĞİL —
/// worklist HEAP'te. v1.142.14: renk başlıkta; bir düğüm gri boyanırken
/// (itme anında) işaretlenir, bu yüzden her düğüm tam bir kez işlenir.
fn markGray(rt: ?*anyopaque, state: *asap.RuntimeState, gc: *CycleGc, root: *anyopaque) WorklistError!void {
    if (getColor(root) == .gray) return;
    var stack: std.ArrayListUnmanaged(*anyopaque) = .empty;
    defer stack.deinit(state.allocator());
    try wlPush(state, gc, &stack, root); // kök boyanmadan ÖNCE: başarısızlık kökü değiştirilmemiş bırakır
    setColor(root, .gray);
    while (stack.pop()) |ptr| {
        gc.visited_in_collect += 1;

        var children = traceChildren(rt, ptr);
        defer children.deinit(state);
        for (children.items) |maybe_child| {
            const child = abi_ptr.slotPtr(maybe_child) orelse continue;
            hdrWord(child).* -%= 1;
            if (getColor(child) == .gray) continue;
            setColor(child, .gray);
            try wlPush(state, gc, &stack, child);
        }
    }
}

fn scanRoots(rt: ?*anyopaque, state: *asap.RuntimeState, gc: *CycleGc) WorklistError!void {
    for (gc.roots.items) |maybe_ptr| {
        const ptr = maybe_ptr orelse continue;
        try scan(rt, state, gc, ptr);
    }
}

/// `markGray`İLE AYNI iteratif dönüşüm — `scanBlack`e devretme (`rcValue > 0`)
/// dalı `scanBlack`i DOĞRUDAN çağırır (SIRALI çalışır, aynı anda DEĞİL).
fn scan(rt: ?*anyopaque, state: *asap.RuntimeState, gc: *CycleGc, root: *anyopaque) WorklistError!void {
    var stack: std.ArrayListUnmanaged(*anyopaque) = .empty;
    defer stack.deinit(state.allocator());
    try wlPush(state, gc, &stack, root);
    while (stack.pop()) |ptr| {
        if (getColor(ptr) != .gray) continue;
        if (rcValue(ptr) > 0) {
            try scanBlack(rt, state, gc, ptr);
            continue;
        }
        setColor(ptr, .white);
        var children = traceChildren(rt, ptr);
        defer children.deinit(state);
        for (children.items) |maybe_child| {
            const child = abi_ptr.slotPtr(maybe_child) orelse continue;
            if (getColor(child) != .gray) continue; // zaten işlenmiş (beyaz/siyah)
            try wlPush(state, gc, &stack, child);
        }
    }
}

/// GG.23 — KRİTİK, İNCE bir doğruluk noktası: LIFO worklist'te AYNI pointer
/// İKİ KEZ push EDİLEBİLİR; ikinci pop'ta TEKRAR işlenirse çocukların
/// refcount'u YANLIŞLIKLA İKİ KEZ artırılırdı. Bu yüzden POP ANINDA `siyah
/// mı` kontrolü ŞART (bkz. `scanBlack` diamond testi). Refcount artışı her
/// zaman ebeveynin çocuk döngüsünde, push'tan ÖNCE koşulsuzdur.
fn scanBlack(rt: ?*anyopaque, state: *asap.RuntimeState, gc: *CycleGc, root: *anyopaque) WorklistError!void {
    var stack: std.ArrayListUnmanaged(*anyopaque) = .empty;
    defer stack.deinit(state.allocator());
    try wlPush(state, gc, &stack, root);
    while (stack.pop()) |ptr| {
        if (getColor(ptr) == .black) continue;
        setColor(ptr, .black);
        var children = traceChildren(rt, ptr);
        defer children.deinit(state);
        for (children.items) |maybe_child| {
            const child = abi_ptr.slotPtr(maybe_child) orelse continue;
            hdrWord(child).* +%= 1;
            if (getColor(child) != .black) {
                try wlPush(state, gc, &stack, child);
            }
        }
    }
}

// ---- F: paralel (durdur-ve-işaretle) işaretleme/tarama ----
//
// Dünya durmuşken (STW) `markGray` ve `scan` aşamaları birkaç iş parçacığına bölünür; mutator yoktur, bu yüzden E planındaki
// yan-tablo/bariyer/karantina sorunları yoktur. Başlık kelimesi (sayaç + renk) yalnızca atomik RMW/CAS ile değiştirilir; her düğüm
// bir kez "talep edilerek" (renk CAS'ı) işlenir. `collectRoots` (serbest bırakma) sıralı kalır. Doğruluk argümanı: `scan`de beyaza
// boyama bayat `rc==0` okumasıyla yapılsa bile, siyah bir ebeveynin sayaç artışı çocuğu beyazdan da siyaha çevirip (CAS: siyah dışı → siyah)
// yeniden işlediğinden son durum sıralı algoritmayla aynı sabit noktadır. Sayaç yalnızca `scan`de artar, bu yüzden `rc>0` okuması hiç yanlış pozitif değildir.

const par_available = !is_freestanding and !builtin.cpu.arch.isWasm() and !builtin.single_threaded;
const PAR_MAX_WORKERS: usize = 8;
const PAR_MIN_VISITED_DEFAULT: usize = 32 * 1024;
const PAR_ROOT_CHUNK: usize = 64;
const PAR_DONATE_AT: usize = 512;
const PAR_BATCH: usize = 256;
const BLACK_TAG: usize = 1;

/// `NOX_GC_THREADS=<n>`: paralel toplama iş parçacığı sayısı (0/1 = kapalı; varsayılan min(CPU, 4)). `NOX_GC_PAR_MIN=<n>`: paralele geçiş eşiği (düğüm).
fn parConfigure(gc: *CycleGc) void {
    if (comptime !par_available) return;
    var n: usize = @min(std.Thread.getCpuCount() catch 1, 4);
    if (std.c.getenv("NOX_GC_THREADS")) |v| n = std.fmt.parseInt(usize, std.mem.span(v), 10) catch n;
    gc.par_threads = @min(n, PAR_MAX_WORKERS);
    if (std.c.getenv("NOX_GC_PAR_MIN")) |v| gc.par_min_visited = std.fmt.parseInt(usize, std.mem.span(v), 10) catch gc.par_min_visited;
}

fn hdrAtomic(p: *anyopaque) *std.atomic.Value(u64) {
    return @ptrCast(hdrWord(p));
}

fn colorOf(w: u64) Color {
    return @enumFromInt(@as(u2, @truncate(w >> COLOR_SHIFT)));
}

/// Rengi `to`ya çeker; zaten `to` ise `false` (başka bir işçi talep etti).
fn claimColor(p: *anyopaque, to: Color) bool {
    const a = hdrAtomic(p);
    var old = a.load(.monotonic);
    while (true) {
        if (colorOf(old) == to) return false;
        const new = (old & ~COLOR_MASK) | (@as(u64, @intFromEnum(to)) << COLOR_SHIFT);
        old = a.cmpxchgWeak(old, new, .monotonic, .monotonic) orelse return true;
    }
}

/// `gray`den `white`a: başka bir işçi çoktan siyaha boyadıysa dokunmaz.
fn whiten(p: *anyopaque) bool {
    const a = hdrAtomic(p);
    var old = a.load(.monotonic);
    while (true) {
        if (colorOf(old) != .gray) return false;
        const new = (old & ~COLOR_MASK) | (@as(u64, @intFromEnum(Color.white)) << COLOR_SHIFT);
        old = a.cmpxchgWeak(old, new, .monotonic, .monotonic) orelse return true;
    }
}

/// `white`tan `black`e: yalnızca beyazsa (başka bir işçi çoktan talep etmediyse).
fn claimWhite(p: *anyopaque) bool {
    const a = hdrAtomic(p);
    var old = a.load(.monotonic);
    while (true) {
        if (colorOf(old) != .white) return false;
        const new = (old & ~COLOR_MASK) | (@as(u64, @intFromEnum(Color.black)) << COLOR_SHIFT);
        old = a.cmpxchgWeak(old, new, .monotonic, .monotonic) orelse return true;
    }
}

const ParShared = struct {
    roots: []const ?*anyopaque,
    n: usize,
    next_root: std.atomic.Value(usize) = .init(0),
    lock: asap.SpinLock = .{},
    queue: std.ArrayListUnmanaged(usize) = .empty,
    idle: usize = 0,
    done: bool = false,
    qalloc: std.mem.Allocator,
    /// GPT-6 P0.2: mark/scan aşamalarında bir iş listesi büyütülemedi ⇒ işaretleme tutarsız; `parPhase` join'den sonra `fatalOom` verir.
    oom: std.atomic.Value(bool) = .init(false),
    /// R1-P1.5 (v2.2.52): collect aşamasında kaydedilemeyen (OOM) beyaz düğüm sayısı; bu düğümler yalnızca SIZAR (serbest bırakılmaz), asla erken serbest bırakılmaz. `parPhase` sonunda `gc.dropped_whites`e eklenir.
    dropped: std.atomic.Value(usize) = .init(0),
};

const ParPhase = enum { mark, scan, collect };

const ParWorker = struct {
    sh: *ParShared,
    rt: *asap.RuntimeState,
    phase: ParPhase,
    stack: std.ArrayListUnmanaged(usize) = .empty,
    whites: std.ArrayListUnmanaged(*anyopaque) = .empty,
    visited: usize = 0,

    fn push(self: *ParWorker, v: usize) void {
        self.stack.append(self.sh.qalloc, v) catch {
            // mark/scan'de atlanan düğüm sayaçları tutarsız bırakır (fatal); collect'te yalnızca bir beyaz düğümün alt-ağacı toplanmadan (sızıntı) kalır.
            if (self.phase != .collect) self.sh.oom.store(true, .release) else _ = self.sh.dropped.fetchAdd(1, .monotonic);
        };
    }

    fn donate(self: *ParWorker) void {
        if (self.stack.items.len < PAR_DONATE_AT) return;
        const sh = self.sh;
        sh.lock.lock();
        defer sh.lock.unlock();
        sh.queue.appendSlice(sh.qalloc, self.stack.items[0..PAR_BATCH]) catch return;
        const rest = self.stack.items.len - PAR_BATCH;
        std.mem.copyForwards(usize, self.stack.items[0..rest], self.stack.items[PAR_BATCH..]);
        self.stack.items.len = rest;
    }

    /// Paylaşılan kuyruktan iş alır; hiç iş kalmadıysa (tüm işçiler boşta) `false`.
    fn getWork(self: *ParWorker) bool {
        const sh = self.sh;
        self.stack.ensureTotalCapacity(sh.qalloc, PAR_BATCH) catch {
            if (self.phase != .collect) sh.oom.store(true, .release);
            sh.lock.lock();
            sh.idle += 1;
            if (sh.idle >= sh.n) sh.done = true;
            sh.lock.unlock();
            return false;
        };
        var waiting = false;
        while (true) {
            sh.lock.lock();
            if (sh.queue.items.len > 0) {
                if (waiting) sh.idle -= 1;
                const take = @min(sh.queue.items.len, PAR_BATCH);
                const start = sh.queue.items.len - take;
                self.stack.appendSliceAssumeCapacity(sh.queue.items[start..]);
                sh.queue.items.len = start;
                sh.lock.unlock();
                return true;
            }
            if (!waiting) {
                waiting = true;
                sh.idle += 1;
            }
            if (sh.idle >= sh.n) sh.done = true;
            const fin = sh.done;
            sh.lock.unlock();
            if (fin) return false;
            std.Thread.yield() catch {};
        }
    }

    fn processMark(self: *ParWorker, ptr: *anyopaque) void {
        self.visited += 1;
        var children = traceChildren(@ptrCast(self.rt), ptr);
        defer children.deinit(self.rt);
        for (children.items) |maybe_child| {
            const child = abi_ptr.slotPtr(maybe_child) orelse continue;
            _ = hdrAtomic(child).fetchSub(1, .monotonic);
            if (claimColor(child, .gray)) self.push(@intFromPtr(child));
        }
    }

    fn processScan(self: *ParWorker, item: usize) void {
        if (item & BLACK_TAG != 0) {
            const ptr: *anyopaque = @ptrFromInt(item & ~BLACK_TAG);
            var children = traceChildren(@ptrCast(self.rt), ptr);
            defer children.deinit(self.rt);
            for (children.items) |maybe_child| {
                const child = abi_ptr.slotPtr(maybe_child) orelse continue;
                _ = hdrAtomic(child).fetchAdd(1, .monotonic);
                if (claimColor(child, .black)) self.push(@intFromPtr(child) | BLACK_TAG);
            }
            return;
        }
        const ptr: *anyopaque = @ptrFromInt(item);
        const w = hdrAtomic(ptr).load(.monotonic);
        if (colorOf(w) != .gray) return;
        if ((w & RC_MASK) > 0) {
            if (claimColor(ptr, .black)) self.push(@intFromPtr(ptr) | BLACK_TAG);
            return;
        }
        if (!whiten(ptr)) return;
        var children = traceChildren(@ptrCast(self.rt), ptr);
        defer children.deinit(self.rt);
        for (children.items) |maybe_child| {
            const child = abi_ptr.slotPtr(maybe_child) orelse continue;
            if (colorOf(hdrAtomic(child).load(.monotonic)) == .gray) self.push(@intFromPtr(child));
        }
    }

    fn processCollect(self: *ParWorker, ptr: *anyopaque) void {
        var children = traceChildren(@ptrCast(self.rt), ptr);
        defer children.deinit(self.rt);
        for (children.items) |maybe_child| {
            const child = abi_ptr.slotPtr(maybe_child) orelse continue;
            if (claimWhite(child)) {
                self.whites.append(self.sh.qalloc, child) catch {
                    _ = self.sh.dropped.fetchAdd(1, .monotonic); // kaydedilemedi: alt-ağaç sızar, asla serbest bırakılmaz
                    continue;
                };
                self.push(@intFromPtr(child));
            }
        }
    }

    fn drain(self: *ParWorker) void {
        while (self.stack.pop()) |item| {
            switch (self.phase) {
                .mark => self.processMark(@ptrFromInt(item)),
                .scan => self.processScan(item),
                .collect => self.processCollect(@ptrFromInt(item)),
            }
            self.donate();
        }
    }

    fn run(self: *ParWorker) void {
        const sh = self.sh;
        while (true) {
            const start = sh.next_root.fetchAdd(PAR_ROOT_CHUNK, .monotonic);
            if (start >= sh.roots.len) break;
            const end = @min(start + PAR_ROOT_CHUNK, sh.roots.len);
            for (sh.roots[start..end]) |maybe_ptr| {
                const ptr = maybe_ptr orelse continue;
                switch (self.phase) {
                    .mark => {
                        if (colorOf(hdrAtomic(ptr).load(.monotonic)) == .purple) {
                            if (claimColor(ptr, .gray)) self.push(@intFromPtr(ptr));
                        } else {
                            _ = hdrAtomic(ptr).fetchAnd(~(BUFFERED_BIT | IDX_MASK), .monotonic);
                        }
                    },
                    .scan => self.push(@intFromPtr(ptr)),
                    .collect => {
                        // `collectRootsDiscover` ile aynı: tampon bayrakları temizlenir, renk korunur; yalnız beyaz kökler toplanır.
                        const was_white = colorOf(hdrAtomic(ptr).fetchAnd(~(BUFFERED_BIT | IDX_MASK), .monotonic)) == .white;
                        if (was_white and claimWhite(ptr)) {
                            self.whites.append(self.sh.qalloc, ptr) catch {
                                _ = self.sh.dropped.fetchAdd(1, .monotonic);
                                continue;
                            };
                            self.push(@intFromPtr(ptr));
                        }
                    },
                }
                self.drain();
            }
        }
        while (self.getWork()) self.drain();
        self.stack.deinit(sh.qalloc);
    }
};

fn parPhase(state: *asap.RuntimeState, gc: *CycleGc, phase: ParPhase, n: usize, whites_out: ?*std.ArrayListUnmanaged(*anyopaque)) void {
    var sh: ParShared = .{ .roots = gc.roots.items, .n = n, .qalloc = state.allocator() };
    defer sh.queue.deinit(sh.qalloc);
    var workers: [PAR_MAX_WORKERS]ParWorker = undefined;
    var threads: [PAR_MAX_WORKERS]?std.Thread = @splat(null);
    for (0..n) |i| workers[i] = .{ .sh = &sh, .rt = gc.par_aux[i].?, .phase = phase };
    for (1..n) |i| {
        threads[i] = std.Thread.spawn(.{}, ParWorker.run, .{&workers[i]}) catch blk: {
            // Başlatılamayan işçi "kalıcı boşta" sayılır; kalan işçiler işi tamamlar.
            sh.lock.lock();
            sh.idle += 1;
            if (sh.idle >= sh.n) sh.done = true;
            sh.lock.unlock();
            break :blk null;
        };
    }
    workers[0].run();
    for (1..n) |i| if (threads[i]) |t| t.join();
    if (sh.oom.load(.acquire)) fatalOom();
    if (phase == .mark) {
        for (0..n) |i| gc.visited_in_collect += workers[i].visited;
    }
    gc.dropped_whites += sh.dropped.load(.monotonic);
    for (0..n) |i| {
        if (whites_out) |out| out.appendSlice(state.allocator(), workers[i].whites.items) catch {
            gc.dropped_whites += workers[i].whites.items.len; // birleştirilemedi: bu beyazlar sızar (serbest bırakılmaz)
        };
        workers[i].whites.deinit(sh.qalloc);
    }
}

/// `true`: işaretleme + tarama + beyaz toplama paralel yapıldı (`whites` serbest bırakılacak düğümlerle dolar); `false`: kurulamadı (çağıran sıralı yola düşer).
fn parMarkScan(state: *asap.RuntimeState, gc: *CycleGc, whites: *std.ArrayListUnmanaged(*anyopaque)) bool {
    const n = gc.par_threads;
    for (0..n) |i| {
        if (gc.par_aux[i] == null) {
            gc.par_aux[i] = asap.createAuxState();
            if (gc.par_aux[i] == null) return false;
        }
    }
    parPhase(state, gc, .mark, n, null);
    parPhase(state, gc, .scan, n, null);
    parPhase(state, gc, .collect, n, whites);
    gc.par_runs += 1;
    return true;
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
    collectRootsDiscover(rt, state, gc, &whites);
    collectRootsFinish(rt, state, gc, &whites);
}

/// R1-P1.5 (v2.2.52): beyaz keşif aşaması (serbest bırakmadan ÖNCE; sayaçlar zaten tutarlı) iş listesi itişi. Başarısızlık sessizce yutulmaz: `dropped_whites` artar, düğüm (ve
/// alt-ağacı) yalnızca SIZAR — asla erken serbest bırakılmaz (mark/scan OOM'undan farklı olarak sayaçlar bozulmaz).
fn discoverPush(state: *asap.RuntimeState, gc: *CycleGc, list: *std.ArrayListUnmanaged(*anyopaque), item: *anyopaque) bool {
    wlPush(state, gc, list, item) catch {
        gc.dropped_whites += 1;
        return false;
    };
    return true;
}

fn collectRootsDiscover(rt: ?*anyopaque, state: *asap.RuntimeState, gc: *CycleGc, whites_out: *std.ArrayListUnmanaged(*anyopaque)) void {
    const whites = whites_out;
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
        if (!discoverPush(state, gc, &stack, ptr) or !discoverPush(state, gc, whites, ptr)) continue;
        while (stack.pop()) |cur| {
            var children = traceChildren(rt, cur);
            defer children.deinit(state);
            for (children.items) |maybe_child| {
                const child = abi_ptr.slotPtr(maybe_child) orelse continue;
                if (getColor(child) != .white) continue;
                setColor(child, .black);
                if (!discoverPush(state, gc, &stack, child) or !discoverPush(state, gc, whites, child)) continue;
            }
        }
    }
}

fn collectRootsFinish(rt: ?*anyopaque, state: *asap.RuntimeState, gc: *CycleGc, whites: *std.ArrayListUnmanaged(*anyopaque)) void {
    gc.roots.clearRetainingCapacity();
    gc.live_roots = 0;
    // Faz 9.11: tepe yük sonrası kök tablosunun kapasitesi sonsuza dek tutulmasın (kararlı düşük yükte RSS şişkin kalıyordu): büyük kapasite boşaltılır, küçük kapasite korunur.
    if (gc.roots.capacity > ROOTS_KEEP_CAPACITY) gc.roots.shrinkAndFree(state.allocator(), 0);

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
    const field_addr: *const abi_ptr.Slot = @ptrFromInt(@intFromPtr(p.?) + TAG_SIZE);
    // `ChildrenBuf.deinit`in (asap.nox_alloc_alignment İLE) serbest
    // bıraktığı AYNI hizalama İLE tahsis edilmeli.
    const buf = state.allocator().alignedAlloc(u8, asap.nox_alloc_alignment, TRACE_BUF_LEN_SIZE + TRACE_BUF_SLOT_SIZE) catch return null;
    const len_ptr: *i64 = @ptrCast(@alignCast(buf.ptr));
    len_ptr.* = 1;
    const child_ptr: *abi_ptr.Slot = @ptrFromInt(@intFromPtr(buf.ptr) + TRACE_BUF_LEN_SIZE);
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
    const field_addr: *abi_ptr.Slot = @ptrFromInt(@intFromPtr(p) + TAG_SIZE);
    field_addr.* = abi_ptr.slot(child);
}

/// Faz MN.3b: `pub` — bkz. `FAKE_PAYLOAD_SIZE`in belge notu.
pub fn newFakeObject(rt: ?*anyopaque) *anyopaque {
    const p = arc.nox_rc_alloc(rt, FAKE_PAYLOAD_SIZE).?;
    const tag_ptr: *i64 = @ptrCast(@alignCast(p));
    tag_ptr.* = 99; // keyfi, `fakeTraceDispatch` tag'e hiç BAKMIYOR
    const field_addr: *abi_ptr.Slot = @ptrFromInt(@intFromPtr(p) + TAG_SIZE);
    field_addr.* = abi_ptr.slot(@as(?*anyopaque, null));
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
    const field_addr: *abi_ptr.Slot = @ptrFromInt(@intFromPtr(p) + TAG_SIZE + slot * FIELD_SLOT_SIZE);
    field_addr.* = abi_ptr.slot(child);
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
        const field_addr: *abi_ptr.Slot = @ptrFromInt(@intFromPtr(p) + TAG_SIZE + i * FIELD_SLOT_SIZE);
        field_addr.* = abi_ptr.slot(@as(?*anyopaque, null));
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
    const children_ptr: [*]abi_ptr.Slot = @ptrFromInt(@intFromPtr(buf.ptr) + TRACE_BUF_LEN_SIZE);
    var i: usize = 0;
    while (i < n_fields) : (i += 1) {
        const field_addr: *const abi_ptr.Slot = @ptrFromInt(@intFromPtr(p.?) + TAG_SIZE + i * FIELD_SLOT_SIZE);
        children_ptr[i] = field_addr.*;
    }
    return buf.ptr;
}

/// GPT-6 P1.2: serbest bırakma kimlik günlüğü (yalnızca testler; toplama kilidi altında TEK iş parçacığında çağrılır). `null` ⇒ kapalı.
var g_free_log: ?*std.ArrayListUnmanaged(usize) = null;

fn fakeGcFreeDispatchDiamond(rt: ?*anyopaque, tag: i64, p: ?*anyopaque) callconv(.c) void {
    if (g_free_log) |log| log.append(testing.allocator, @intFromPtr(p.?)) catch {};
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
const abi_ptr = @import("../abi_ptr.zig");
const atomic64 = @import("../async_rt/atomic64.zig");

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
    asap.destroyState(std.heap.page_allocator, state);
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
test "v2.1.79: tombstone sıkıştırması — çok sayıda kök kaydedilip unutulunca dizi küçülür, indeksler tutarlı kalır, toplama çalışmaya devam eder" {
    injectFakeDispatch();
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt));
    const gc = getGc(state);
    gc.collect_threshold = 1 << 24; // bu testte otomatik toplama tetiklenmesin
    const n: usize = COMPACT_MIN_LEN + 1000;
    const objs = try testing.allocator.alloc(*anyopaque, n);
    defer testing.allocator.free(objs);
    for (objs) |*o| {
        o.* = newFakeObject(rt);
        arc.nox_rc_retain(o.*); // RC=2: bırakma sayacı sıfırlamasın
        nox_cycle_possible_root(rt, o.*);
    }
    try testing.expectEqual(n, gc.live_roots);
    try testing.expectEqual(n, gc.roots.items.len);
    // Hepsini (sonuncu hariç) unut: tombstone oranı eşiği aşar.
    for (objs[0 .. n - 1]) |o| nox_cycle_forget(rt, o);
    try testing.expectEqual(@as(usize, 1), gc.live_roots);
    try testing.expectEqual(n, gc.roots.items.len); // henüz sıkıştırılmadı
    // Yeni bir kök kaydı sıkıştırmayı tetikler.
    const extra = newFakeObject(rt);
    arc.nox_rc_retain(extra);
    nox_cycle_possible_root(rt, extra);
    try testing.expectEqual(@as(usize, 2), gc.roots.items.len);
    try testing.expectEqual(@as(usize, 2), gc.live_roots);
    // Her canlı kökün başlık indeksi dizideki konumuyla eşleşmeli.
    for (gc.roots.items, 0..) |maybe, idx| {
        const ptr = maybe.?;
        try testing.expect(isBuffered(ptr));
        try testing.expectEqual(idx, @as(usize, @intCast((hdrWord(ptr).* & IDX_MASK) >> IDX_SHIFT)));
    }
    // Sıkıştırma sonrası unutma doğru yuvayı bulur.
    nox_cycle_forget(rt, objs[n - 1]);
    nox_cycle_forget(rt, extra);
    try testing.expectEqual(@as(usize, 0), gc.live_roots);
    nox_cycle_collect(rt);
    // Temizlik: tüm nesneler birer fazladan retain taşıyor.
    for (objs) |o| {
        _ = arc.nox_rc_predecrement(o);
        arc.nox_rc_free_payload(rt, o, FAKE_PAYLOAD_SIZE);
    }
    _ = arc.nox_rc_predecrement(extra);
    arc.nox_rc_free_payload(rt, extra, FAKE_PAYLOAD_SIZE);
    try deinitRuntimeExpectNoLeak(rt);
}

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
    setColor(root, .gray);
    setColor(d, .gray);
    setColor(b, .gray);

    const e_refcount_before = rcValue(e);

    try scanBlack(rt, state, gc, root);

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

test "GPT-6 P0.2: iş listesi OOM'u sessizce yutulmaz — markGray/scan/scanBlack her itişte error.OutOfMemory yayar (hata enjeksiyonu)" {
    injectFakeDispatchDiamond();
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt));
    const gc = getGc(state);

    // root -> d -> e ; root -> b -> d  (elmas): markGray 4 düğümü iter (root, d, e, b)
    const e = newFakeObject(rt);
    const d = newFakeObject(rt);
    wireField(d, e);
    const b = newFakeObject(rt);
    wireField(b, d);
    const root = newFakeObject2(rt);
    wireFieldAt(root, 0, d);
    wireFieldAt(root, 1, b);

    // markGray: her itiş noktasında (1..4) başarısızlık enjekte edilir; hepsi hata döndürmeli. Sonra durum atılır (bu test yalnızca ERROR yayılımını sınar).
    var fail_at: usize = 1;
    while (fail_at <= 4) : (fail_at += 1) {
        // sayaç/renkleri her turda sıfırdan kur
        for ([_]*anyopaque{ root, d, b, e }) |nd| hdrWord(nd).* = (hdrWord(nd).* & ~COLOR_MASK) | (@as(u64, @intFromEnum(Color.black)) << COLOR_SHIFT);
        gc.test_fail_pushes = fail_at;
        try testing.expectError(error.OutOfMemory, markGray(rt, state, gc, root));
        gc.test_fail_pushes = 0;
    }

    // scan: gri + rc>0 kök scanBlack'e devreder; ilk itiş (scan) ve ilk scanBlack itişi (2.) ayrı ayrı başarısız olmalı.
    for ([_]usize{ 1, 2 }) |n| {
        for ([_]*anyopaque{ root, d, b, e }) |nd| setColor(nd, .gray);
        gc.test_fail_pushes = n;
        try testing.expectError(error.OutOfMemory, scan(rt, state, gc, root));
        gc.test_fail_pushes = 0;
    }

    // scanBlack: kök itişi ve çocuk itişi
    for ([_]usize{ 1, 2, 3 }) |n| {
        for ([_]*anyopaque{ root, d, b, e }) |nd| setColor(nd, .gray);
        gc.test_fail_pushes = n;
        try testing.expectError(error.OutOfMemory, scanBlack(rt, state, gc, root));
        gc.test_fail_pushes = 0;
    }

    arc.nox_rc_free_payload(rt, root, FAKE_PAYLOAD_SIZE_2);
    arc.nox_rc_free_payload(rt, d, FAKE_PAYLOAD_SIZE);
    arc.nox_rc_free_payload(rt, b, FAKE_PAYLOAD_SIZE);
    arc.nox_rc_free_payload(rt, e, FAKE_PAYLOAD_SIZE);
    try deinitRuntimeExpectNoLeak(rt);
}

test "GPT-6 P0.2: paralel işçi mark/scan'de OOM'u bayrakla bildirir (collect'te yalnızca sızıntı, bayrak yok)" {
    if (comptime !par_available) return error.SkipZigTest;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var sh: ParShared = .{ .roots = &.{}, .n = 1, .qalloc = failing.allocator() };
    var w: ParWorker = .{ .sh = &sh, .rt = undefined, .phase = .mark };
    w.push(0x1000);
    try testing.expect(sh.oom.load(.acquire));
    try testing.expectEqual(@as(usize, 0), w.stack.items.len);

    var sh2: ParShared = .{ .roots = &.{}, .n = 1, .qalloc = failing.allocator() };
    var w2: ParWorker = .{ .sh = &sh2, .rt = undefined, .phase = .collect };
    w2.push(0x1000);
    try testing.expect(!sh2.oom.load(.acquire));

    var sh3: ParShared = .{ .roots = &.{}, .n = 1, .qalloc = failing.allocator() };
    var w3: ParWorker = .{ .sh = &sh3, .rt = undefined, .phase = .scan };
    try testing.expect(!w3.getWork());
    try testing.expect(sh3.oom.load(.acquire));
}

test "P1.4: büyük blok baytı eşiği aşınca baskı bayrağı kalkar, toplama onu indirir; verimsiz baskı toplaması adımı ikiye katlar" {
    if (comptime is_freestanding or builtin.cpu.arch.isWasm()) return error.SkipZigTest;
    injectFakeDispatch();
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt));
    const gc = getGc(state);
    gc.collect_threshold = 1 << 24; // yalnızca bayt baskısı tetiklesin

    const a = newFakeObject(rt);
    const b = newFakeObject(rt);
    wireField(a, b);
    wireField(b, a);
    simulateRelease(rt, a); // kök tamponlanır, henüz bayrak yok

    // Eşik altı: bayrak kalkmaz.
    const small = asap.nox_alloc(rt, 1 << 20) orelse return error.AllocFailed;
    try testing.expect(!state.gc_pressure.load(.monotonic));
    // Eşiği aşan büyük tahsis bayrağı kaldırır; serbest bırakma net baytı düşürür (bayrak toplamaya kadar kalır).
    const big = asap.nox_alloc(rt, asap.GC_PRESSURE_BASE) orelse return error.AllocFailed;
    try testing.expect(state.gc_pressure.load(.monotonic));
    asap.nox_free(rt, big, asap.GC_PRESSURE_BASE);
    asap.nox_free(rt, small, 1 << 20);
    try testing.expectEqual(@as(usize, 0), state.gc_large_bytes.load(.monotonic));

    // Bayrak varken bir sonraki olası kök kaydı toplamayı tetikler (eşik sayacı aşılmadan); döngüsel çöp serbest kalır, bayrak iner.
    simulateRelease(rt, b);
    try testing.expectEqual(@as(usize, 2), g_fake_freed_count);
    try testing.expect(!state.gc_pressure.load(.monotonic));
    try testing.expectEqual(asap.GC_PRESSURE_BASE, gc.pressure_step); // verimli toplama: taban adım

    // Verimsiz baskı toplaması (hiçbir şey serbest kalmaz): adım iki katına çıkar.
    state.gc_pressure.store(true, .monotonic);
    rearmPressure(state, gc, true, 10);
    try testing.expectEqual(asap.GC_PRESSURE_BASE * 2, gc.pressure_step);
    try testing.expect(!state.gc_pressure.load(.monotonic));

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

/// `freed1`/`freed2`: düğüm İNDEKSİ başına bayrak — 1. / 2. toplamada serbest bırakıldı mı (kimlik kümesi karşılaştırması; sayı eşitliği tek başına yanlış-düğüm serbest bırakmayı yakalamaz). Çağıran serbest bırakır.
const ParGraphResult = struct { first: usize, second: usize, visited: usize, par_runs: usize, freed1: []bool, freed2: []bool };

/// F: aynı rastgele graf (8'li döngü öbekleri + seyrek ileri çapraz kenarlar, 1/200 düğüm dışarıdan tutulu) önce `threads` iş parçacığıyla
/// toplanır; ilk toplamada serbest kalan sayı, tutulu referanslar bırakıldıktan sonraki ikinci toplamada kalanların hepsi (sızıntı yok).
fn parGraphRun(seed: u64, n: usize, threads: usize) !ParGraphResult {
    injectFakeDispatchDiamond();
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt));
    const gc = getGc(state);
    gc.collect_threshold = 1 << 24; // otomatik toplama tetiklenmesin
    gc.par_threads = threads;
    gc.par_min_visited = 0;
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    const G: usize = 8;
    const nodes = try testing.allocator.alloc(*anyopaque, n);
    defer testing.allocator.free(nodes);
    const held = try testing.allocator.alloc(bool, n);
    defer testing.allocator.free(held);
    for (nodes) |*nd| nd.* = newFakeObject2(rt);
    var index_of: std.AutoHashMapUnmanaged(usize, usize) = .empty;
    defer index_of.deinit(testing.allocator);
    for (nodes, 0..) |nd, i| try index_of.put(testing.allocator, @intFromPtr(nd), i);
    var free_log: std.ArrayListUnmanaged(usize) = .empty;
    defer free_log.deinit(testing.allocator);
    g_free_log = &free_log;
    defer g_free_log = null;
    const freed1 = try testing.allocator.alloc(bool, n);
    errdefer testing.allocator.free(freed1);
    const freed2 = try testing.allocator.alloc(bool, n);
    errdefer testing.allocator.free(freed2);
    @memset(freed1, false);
    @memset(freed2, false);
    for (0..n) |i| {
        const base = i - i % G;
        wireFieldAt(nodes[i], 0, nodes[base + (i % G + 1) % G]);
        const gi = i / G;
        if (rnd.uintLessThan(u32, 100) < 15 and gi + 1 < n / G) {
            const tg = gi + 1 + rnd.uintLessThan(usize, n / G - gi - 1);
            wireFieldAt(nodes[i], 1, nodes[tg * G + rnd.uintLessThan(usize, G)]);
        }
    }
    for (nodes, 0..) |nd, i| {
        held[i] = rnd.uintLessThan(u32, 200) == 0;
        if (held[i]) continue;
        try testing.expectEqual(@as(i32, 0), arc.nox_rc_predecrement(nd)); // halka kenarı nedeniyle rc ≥ 2
        nox_cycle_possible_root(rt, nd);
    }
    nox_cycle_collect(rt);
    const first = gc.freed_in_collect;
    const visited = gc.visited_in_collect;
    for (free_log.items) |ptr| freed1[index_of.get(ptr).?] = true;
    free_log.clearRetainingCapacity();
    for (nodes, 0..) |nd, i| {
        if (!held[i]) continue;
        try testing.expectEqual(@as(i32, 0), arc.nox_rc_predecrement(nd));
        nox_cycle_possible_root(rt, nd);
    }
    nox_cycle_collect(rt);
    const second = gc.freed_in_collect;
    const par_runs = gc.par_runs;
    for (free_log.items) |ptr| freed2[index_of.get(ptr).?] = true;
    try deinitRuntimeExpectNoLeak(rt);
    return .{ .first = first, .second = second, .visited = visited, .par_runs = par_runs, .freed1 = freed1, .freed2 = freed2 };
}

test "F: paralel işaretleme/tarama, sıralı toplayıcıyla AYNI nesneleri serbest bırakır (rastgele döngü-öbekli graflar, 2/3/4/8 iş parçacığı)" {
    if (comptime !par_available) return error.SkipZigTest;
    // `NOX_GC_STRESS_SEEDS=<n>`: yerel yarış avı için tohum sayısı (varsayılan 3).
    var n_seeds: u64 = 3;
    if (std.c.getenv("NOX_GC_STRESS_SEEDS")) |v| n_seeds = std.fmt.parseInt(u64, std.mem.span(v), 10) catch n_seeds;
    var seed: u64 = 1;
    while (seed <= n_seeds) : (seed += 1) {
        const n: usize = 20000;
        const seq = try parGraphRun(seed, n, 0);
        defer testing.allocator.free(seq.freed1);
        defer testing.allocator.free(seq.freed2);
        try testing.expectEqual(n, seq.first + seq.second);
        // Her düğüm tam bir kez serbest bırakılmış olmalı (1. ya da 2. turda; ikisinde birden değil, hiçbirinde değil değil).
        for (seq.freed1, seq.freed2) |a, b| try testing.expect(a != b);
        try testing.expectEqual(@as(usize, 0), seq.par_runs);
        try testing.expect(seq.first > 0);
        for ([_]usize{ 2, 3, 4, 8 }) |t| {
            const par = try parGraphRun(seed, n, t);
            defer testing.allocator.free(par.freed1);
            defer testing.allocator.free(par.freed2);
            try testing.expectEqual(@as(usize, 2), par.par_runs); // iki toplamanın İKİSİ de paralel
            // GPT-6 P1.2: yalnızca SAYI değil KİMLİK kümesi de sıralı toplayıcıyla aynı (yanlış düğümü serbest bırakıp başka birini sızdırmak sayıyı değiştirmez).
            try testing.expectEqualSlices(bool, seq.freed1, par.freed1);
            try testing.expectEqualSlices(bool, seq.freed2, par.freed2);
            try testing.expectEqual(seq.first, par.first);
            try testing.expectEqual(seq.second, par.second);
            try testing.expectEqual(seq.visited, par.visited);
        }
    }
}

test "R1-P1.5 (v2.2.52): beyaz keşifte OOM yutulmaz — dropped_whites artar, düğüm sızar ama erken serbest bırakılmaz; kayıtlı beyazlar tutarlı kalır" {
    injectFakeDispatchDiamond();
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt));
    const gc = getGc(state);

    // r -> d -> e hepsi beyaz (çöp zinciri); keşif itişleri: r(stack 1, whites 2), d(stack 3, whites 4 → ENJEKTE), e(stack 5, whites 6)
    const e = newFakeObject(rt);
    const d = newFakeObject(rt);
    wireField(d, e);
    const r = newFakeObject(rt);
    wireField(r, d);
    for ([_]*anyopaque{ r, d, e }) |nd| setColor(nd, .white);
    try gc.roots.append(state.allocator(), r);

    var whites: std.ArrayListUnmanaged(*anyopaque) = .empty;
    gc.test_fail_pushes = 4;
    collectRootsDiscover(rt, state, gc, &whites);
    gc.test_fail_pushes = 0;

    try testing.expectEqual(@as(usize, 1), gc.dropped_whites); // sessizce yutulmadı
    try testing.expectEqual(@as(usize, 2), whites.items.len); // r ve e kayıtlı; d sızar
    for (whites.items) |w| try testing.expect(w != d);
    try testing.expectEqual(Color.black, getColor(d)); // boyandı ama listede yok → asla serbest bırakılmaz

    // `collectRootsFinish` ÇAĞRILMAZ (kayıtlı beyazları serbest bırakırdı); test düğümleri elle bırakır.
    whites.deinit(state.allocator());
    gc.roots.clearRetainingCapacity();
    arc.nox_rc_free_payload(rt, r, FAKE_PAYLOAD_SIZE);
    arc.nox_rc_free_payload(rt, d, FAKE_PAYLOAD_SIZE);
    arc.nox_rc_free_payload(rt, e, FAKE_PAYLOAD_SIZE);
    try deinitRuntimeExpectNoLeak(rt);
}
