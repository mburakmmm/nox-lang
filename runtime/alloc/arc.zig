//! Nox Katman 2 (ARC) çalışma zamanı — AGENTS.md §8.
//!
//! Katman 1'in (`asap.zig`) üzerine ince bir referans sayacı katmanı ekler.
//! Her ARC nesnesi, gövdesinden (payload) hemen önce görünmez 8 baytlık bir
//! refcount alanı taşır; `nox_rc_alloc`'un döndürdüğü işaretçi her zaman
//! PAYLOAD'ın başlangıcıdır — çağıran QBE kodu refcount başlığının
//! varlığından tamamen habersizdir (aynı işaretçi hem Katman 1'in ASAP
//! kararı hem Katman 2'nin ARC kararı için tekdüze kullanılabilir: ASAP
//! durumunda nesne yalnızca bir kez `nox_rc_release` alır ve 1→0 olup hemen
//! serbest kalır; ARC durumunda takma ad/alan ataması gibi noktalarda ek
//! `nox_rc_retain` çağrıları sayaç 1'in üstüne çıkarır).
//!
//! İlke #6: allocator/bağlam (`rt`) burada da her zaman açık parametredir.
//!
//! **Sabit büyüklük-sınıflı serbest liste havuzu (performans fazı):**
//! `oop_arc_churn` benchmark'ının profillenmesi (bkz. nox-teknik-
//! spesifikasyon.md), örneklerin ~%45'inin `smp_allocator`ın kendi tahsis/
//! serbest bırakma overhead'inde (sistem çağrıları/kilitleme/bookkeeping)
//! geçtiğini gösterdi — Nox nesneleri (sınıf/liste) tipik olarak KÜÇÜKTÜR
//! (birkaç 8-baytlık alan) ve döngülerde SIK sIK inşa edilip yıkılır, bu da
//! genel amaçlı ayırıcıyı gereksiz yere zorlar. Çözüm: `nox_rc_alloc`/
//! `nox_rc_free_payload`, boyutu `POOL_NUM_CLASSES` sabit sınıftan birine
//! (16, 32, 64, ... bayt, ikiye katlanarak) denk düşen nesneler için genel
//! ayırıcıya HİÇ gitmeden kendi aralarında geri dönüştürülen basit bir
//! serbest liste (bkz. `asap.zig`'in `RuntimeState.pool_free_lists`i)
//! kullanır — serbest bırakılan bir blok gerçekten `free`lenmez, kendi
//! sınıfının listesine (bloğun İLK 8 baytına bir `next` işaretçisi yazarak —
//! minimum blok boyutu HER ZAMAN >=16 bayttır, bu güvenlidir) eklenir;
//! sonraki AYNI sınıftan bir tahsis bu listeden POPLANIR.
//!
//! **Yalnızca Release modlarında aktif** (`use_pool`) — Debug modunda HER
//! tahsis/serbest bırakma DOĞRUDAN `asap.nox_alloc`/`nox_free`e (ve dolayısıyla
//! `DebugAllocator`a) gider, DEĞİŞMEDEN; bu, dört gerçek ARC hatasının
//! yakalanmasını sağlayan güvenlik ağını (bkz. `asap.zig`'in modül üstü notu)
//! KORUR — havuzlama, bir bloğu "serbest" gösterip aslında canlı tutarak bu
//! tespiti ZAYIFLATIRDI (ör. bir kullanım-sonrası-serbest-bırakma hatası,
//! DebugAllocator'a hiç ULAŞMADAN havuzda sessizce veri bozulmasına dönüşürdü).
//!
//! **Bilinçli kabul edilen ödünleşim:** havuzlanan bloklar programın ÖMRÜ
//! BOYUNCA asla işletim sistemine geri verilmez (`nox_runtime_deinit` onları
//! GEZİP serbest BIRAKMAZ) — Release modunda sızıntı tespiti zaten YOK ve
//! `main` işlemi hemen ardından sonlandırdığından (bkz. `genMainAsync`/
//! `genMain`), bu güvenlidir (OS, işlem çıkışında tüm belleği geri alır).
//! Klasik havuz/thread-cache ayırıcılarla (tcmalloc/jemalloc) AYNI, iyi
//! bilinen ödünleşim — tepe bellek kullanımı biraz artabilir, ama v0.1
//! kapsamında kabul edilebilir.

const std = @import("std");
const builtin = @import("builtin");
const asap = @import("asap.zig");
const lowlevel = @import("lowlevel.zig");
const abi_layout = @import("abi_layout");

/// Faz P1.2: `../../shared/abi_layout.zig`den RE-EXPORT (derleyiciyle
/// PAYLAŞILAN TEK doğruluk kaynağı) — yerel alias adı KORUNUR ki bu
/// dosyanın ~6 kullanım sitesi değişmeden kalsın.
const HEADER_SIZE = abi_layout.ARC_HEADER_SIZE;
const use_pool = builtin.mode != .Debug;

/// `total_size` (HEADER_SIZE dahil) için bir havuz sınıfı İNDEKSİ döner —
/// sınıflar `16 << idx` bayt (16, 32, 64, ...); `POOL_NUM_CLASSES`i aşan
/// (varsayılan sınırla 16*2^9 = 8192 bayt üstü) boyutlar İÇİN `null` döner
/// (havuzlanmaz, doğrudan genel ayırıcıya gider — ör. çok büyük listeler).
fn poolClassIndex(total_size: usize) ?usize {
    if (total_size == 0) return null;
    var class_size: usize = 16;
    var idx: usize = 0;
    while (idx < asap.POOL_NUM_CLASSES) : (idx += 1) {
        if (total_size <= class_size) return idx;
        class_size *= 2;
    }
    return null;
}

fn poolClassSize(idx: usize) usize {
    return @as(usize, 16) << @intCast(idx);
}

/// Faz [YENİ] (bkz. plan dosyası "İki gerçek performans regresyonunu
/// düzeltme"): `nox_rc_alloc`/`nox_rc_free_payload`nin İKİSİ de kullanır.
/// **`noinline` OLARAK İŞARETLENMESİ BİLİNÇLİDİR VE LOAD-BEARING'DİR** —
/// İLK denemede BU basit bir üçlü ifade OLARAK (`if (cond) asap.
/// currentWorkerSlot() else 0`) YAZILDIĞINDA, `otool -tV` İLE derlenmiş
/// binary'nin GERÇEK assembly'si okunduğunda LLVM'in `currentWorkerSlot()`
/// (SAF/yan-etkisiz göründüğü İçİn) çağrısını dallanmadan ÖNCE KOŞULSUZ
/// yürütüp (`blr`, TLV thunk'ına) SONUCU bir `csel` İLE 0 İLE SEÇTİĞİ
/// (if-dönüştürme/dallanma-yerine-seçme optimizasyonu) GÖZLEMLENDİ — TAM
/// OLARAK önlemek istediğimiz pahalı TLV erişimini HÂLÂ HER ÇAĞRIDA
/// ÇALIŞTIRIYORDU, düzeltmeyi TAMAMEN etkisiz kılıyordu (`list_release_
/// overhead` ölçümünde SIFIR iyileşme İLE DOĞRULANDI). `noinline`, GERÇEK
/// bir çağrı SINIRI (opak, LLVM'in içini GÖREMEYECEĞİ) kurarak BUNU
/// ÖNLER — düzeltme SONRASI `csel` ORTADAN KALKTI, `blr` YALNIZCA
/// `pool_ever_active == true` dalında ÜRETİLDİ (TEKRAR `otool -tV` İLE
/// doğrulandı).
noinline fn poolSlotFor(state: *asap.RuntimeState) usize {
    if (state.pool_ever_active.load(.monotonic)) {
        @branchHint(.unlikely);
        return asap.currentWorkerSlot();
    }
    return 0;
}

/// `payload_size` baytlık bir nesne + görünmez 8 baytlık refcount başlığı
/// tahsis eder; refcount 1 ile başlar. Döndürülen işaretçi PAYLOAD'ın
/// başlangıcıdır. Başarısızlıkta `null` döner. Release modunda önce havuzdan
/// (bkz. modül üstü not) karşılamayı dener; havuz boşsa (ya da nesne
/// havuzlanamayacak kadar büyükse) genel ayırıcıdan TAM SINIF BÜYÜKLÜĞÜNDE
/// (istenenden fazla olabilir — bu blok daha sonra AYNI sınıfa geri
/// dönecektir) bir blok alır.
pub export fn nox_rc_alloc(rt: ?*anyopaque, payload_size: usize) ?*anyopaque {
    // Faz X.3 (bkz. `asap.RuntimeState.arc_owner_pool`nin belge notu):
    // Debug modunda BU rt'nin ARC işlemlerine dokunan iş parçacığının
    // HER ZAMAN AYNI olduğunu doğrular — ihlal EDİLİRSE burada, gerçek
    // bir data-race'e İLERLEMEDEN, KESİN bir panikle DURUR.
    if (rt) |r| std.debug.assert(asap.arcOwnerThreadOk(@ptrCast(@alignCast(r))));
    const total = payload_size + HEADER_SIZE;
    if (use_pool) {
        if (poolClassIndex(total)) |idx| {
            const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
            // Faz MN.10: `pool_free_lists[slot]`, ÇAĞIRAN OS iş
            // parçacığının KENDİ satırıdır (bkz. `asap.currentWorkerSlot`
            // — 1-iş-parçacığı-1-slot değişmezi, `worker_pool.zig`nin
            // `setWorkerSlot` çağrı siteleriyle GARANTİ edilir) — SADECE
            // BU iş parçacığı BU satıra YAZAR, kilit GEREKMEZ (`globals_
            // blocks`İLE AYNI desen, bkz. `asap.zig`nin `pool_free_lists`
            // belge notu). Faz [YENİ] (bkz. plan dosyası "İki gerçek
            // performans regresyonunu düzeltme"): `asap.currentWorkerSlot()`
            // (threadlocal, macOS'ta pahalı bir TLV thunk çağrısı) HİÇ
            // `WorkerPool` YARATILMAMIŞ (`state.pool_ever_active == false`)
            // programlarda TAMAMEN ATLANIR — BÖYLE bir programda slot
            // ZATEN HER ZAMAN 0'dır (bkz. `pool_ever_active`nin belge notu).
            const slot = poolSlotFor(state);
            const row = &asap.poolFreeListsRow(state, slot).classes;
            const popped = row[idx];
            if (popped) |node| row[idx] = node.next;
            const base: *anyopaque = if (popped) |node| @ptrCast(node) else (asap.nox_alloc(rt, poolClassSize(idx)) orelse return null);
            const rc: *i64 = @ptrCast(@alignCast(base));
            rc.* = 1;
            const base_bytes: [*]u8 = @ptrCast(base);
            return base_bytes + HEADER_SIZE;
        }
    }
    const base = asap.nox_alloc(rt, total) orelse return null;
    const rc: *i64 = @ptrCast(@alignCast(base));
    rc.* = 1;
    const base_bytes: [*]u8 = @ptrCast(base);
    return base_bytes + HEADER_SIZE;
}

/// Refcount'u bir artırır (bir değer başka bir isme/alana atandığında).
/// Faz MN.1 (bkz. plan dosyası "LLVM-only atomic ARC"): bu fonksiyon
/// ZATEN gerçek bir çağrı (inline EDİLMİYOR — bkz. `codegen_qbe/
/// ownership.zig`nin `emitInlineRetain`si, HIZLI yol AYRI), bu YÜZDEN
/// KOŞULSUZ atomic yapmanın maliyeti SIFIR ek çağrı — SADECE ZATEN
/// yapılan bir çağrıda birkaç ekstra çevrim. `noxrt.o` TEK (bkz.
/// `main.zig`nin HEM QBE HEM LLVM yolunda AYNI `noxrt_path`yi bağlaması)
/// — build bayrağı YOK, `--release` OLMADAN da ATOMİK, davranış AYNI
/// (atomiklik non-atomic'in GÖZLEMLENEBİLİR bir DAVRANIŞ FARKI yaratmadığı
/// tek-iş-parçacıklı bir bağlamda hiçbir şeyi BOZMAZ).
pub export fn nox_rc_retain(ptr: ?*anyopaque) void {
    const p = ptr orelse return;
    const rc: *std.atomic.Value(i64) = @ptrCast(refcountOf(p));
    _ = rc.fetchAdd(1, .acq_rel);
}

/// Refcount'u bir azaltır; sıfıra ya da altına düşerse tüm bloğu (başlık
/// dahil) serbest bırakır. `payload_size`, `nox_rc_alloc`'a verilenle
/// birebir aynı olmalıdır.
pub export fn nox_rc_release(rt: ?*anyopaque, ptr: ?*anyopaque, payload_size: usize) void {
    if (ptr == null) return;
    if (nox_rc_predecrement(ptr) != 0) nox_rc_free_payload(rt, ptr, payload_size);
}

/// Refcount'u bir azaltır ama belleği SERBEST BIRAKMAZ — yalnızca sıfıra ya
/// da altına düşüp düşmediğini bildirir (1: düştü, 0: hâlâ canlı). Sınıf
/// örnekleri için üretilen `$ClassName_release` (bkz. codegen_qbe/codegen.zig,
/// `genClassRelease`) bunu, iç içe (sınıf tipli) alanları belleği gerçekten
/// serbest bırakmadan ÖNCE özyinelemeli olarak serbest bırakabilmek için
/// `nox_rc_release`'den ayrıştırılmış olarak kullanır.
pub export fn nox_rc_predecrement(ptr: ?*anyopaque) i32 {
    const p = ptr orelse return 0;
    const rc: *std.atomic.Value(i64) = @ptrCast(refcountOf(p));
    // `fetchSub` işlem-ÖNCESİ değeri döner (`old`); eski kodun `rc.* <= 0`
    // (post-decrement) karşılaştırması `old <= 1`e denk düşer.
    const old = rc.fetchSub(1, .acq_rel);
    return if (old <= 1) 1 else 0;
}

/// `nox_rc_predecrement` 1 döndürdükten SONRA belleği (başlık dahil) gerçekten
/// serbest bırakır. `payload_size`, `nox_rc_alloc`'a verilenle birebir aynı
/// olmalıdır. Release modunda (bkz. modül üstü not) "serbest bırakmak"
/// GENEL ayırıcıya gitmek DEĞİL, bloğu KENDİ büyüklük sınıfının serbest
/// listesine eklemektir — `total_size` `nox_rc_alloc`daki İLE AYNI sınıfa
/// deterministik olarak eşleneceğinden (aynı boyut her zaman aynı sınıf),
/// bu blok yalnızca AYNI sınıftan bir sonraki tahsiste güvenle geri
/// dönüştürülür. Faz MN.10: blok, ÇAĞIRAN (serbest bırakan) OS iş
/// parçacığının KENDİ `pool_free_lists` satırına GİDER — bu, nesneyi
/// TAHSİS EDEN iş parçacığıYLA AYNI OLMAK ZORUNDA DEĞİLDİR (bir fiber
/// work-stealing İLE göç ETMİŞ olabilir); bu GÜVENLİDİR (bkz. `nox_rc_
/// alloc`nin AYNI notu), sadece nesnenin geri dönüştürüleceği HAVUZ
/// satırını DEĞİŞTİRİR (bkz. `asap.zig`nin `pool_free_lists` belge notu,
/// "bilinçli kabul edilen ödünleşim").
pub export fn nox_rc_free_payload(rt: ?*anyopaque, ptr: ?*anyopaque, payload_size: usize) void {
    const p = ptr orelse return;
    // Faz X.3 — bkz. `nox_rc_alloc`nin AYNI notu.
    if (rt) |r| std.debug.assert(asap.arcOwnerThreadOk(@ptrCast(@alignCast(r))));
    const bytes: [*]u8 = @ptrCast(p);
    const base = bytes - HEADER_SIZE;
    const total = payload_size + HEADER_SIZE;
    if (use_pool) {
        if (poolClassIndex(total)) |idx| {
            const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return));
            const node: *asap.PoolNode = @ptrCast(@alignCast(base));
            // Faz MN.10 — bkz. `nox_rc_alloc`nin AYNI notu. Faz [YENİ] —
            // bkz. `nox_rc_alloc`nin AYNI `pool_ever_active` kısa-yolu notu.
            const slot = poolSlotFor(state);
            const row = &asap.poolFreeListsRow(state, slot).classes;
            node.* = .{ .next = row[idx] };
            row[idx] = node;
            return;
        }
    }
    asap.nox_free(rt, base, total);
}

fn refcountOf(ptr: *anyopaque) *i64 {
    const bytes: [*]u8 = @ptrCast(ptr);
    const base = bytes - HEADER_SIZE;
    return @ptrCast(@alignCast(base));
}

/// Faz U.1: `list[T].append()`in "büyütme" yolunun tek çalışma zamanı
/// primitifi — YENİ (refcount 1'le başlayan, `new_payload_size` baytlık) bir
/// blok tahsis eder, `old_ptr`den `copy_bytes` baytı (KENDİ başlığı DAHİL —
/// bkz. `codegen_qbe/codegen.zig`nin `list[T]` başlık düzeni notu, `{len@0,
/// cap@8, elemanlar@16...}`) KOPYALAR, YENİ işaretçiyi döner. `old_ptr`nin
/// KENDİSİNE HİÇ DOKUNMAZ (ne serbest bırakır ne refcount'unu değiştirir) —
/// bu, ÇAĞIRANIN (codegen'in ürettiği `.append()` kodu) sorumluluğundadır
/// (eski bloğun refcount'unu `nox_rc_predecrement` ile azaltıp, sıfıra
/// düşerse `nox_rc_free_payload` ile serbest bırakması GEREKİR — elemanların
/// KENDİSİ bu kopyalamada TAŞINDIĞINDAN [aynı işaretçi değerleri], eski
/// blok ASLA elemanlarını özyinelemeli olarak release ETMEMELİDİR, yalnızca
/// KENDİ ham belleği serbest bırakılmalıdır).
pub export fn nox_list_grow(rt: ?*anyopaque, old_ptr: ?*anyopaque, copy_bytes: usize, new_payload_size: usize) ?*anyopaque {
    const new_ptr = nox_rc_alloc(rt, new_payload_size) orelse return null;
    if (old_ptr) |op| {
        const src: [*]const u8 = @ptrCast(op);
        const dst: [*]u8 = @ptrCast(new_ptr);
        @memcpy(dst[0..copy_bytes], src[0..copy_bytes]);
    }
    return new_ptr;
}

/// GG.18 (bkz. plan dosyası "ASAP güçlendirmesi — Tur 2"): `nox_list_grow`nin
/// arena-farkında ikizi — bir fonksiyon-kapsamlı arenaya (`compiler/
/// codegen_qbe/local_escape.zig`nin kanıtladığı, SKALER-elemanlı, kaçmayan
/// bir `list[T]` yereli İçİn) büyüyen listelerin TEK çalışma zamanı
/// primitifi. `nox_list_grow`DAN TEK FARKI: YENİ blok `nox_rc_alloc`
/// YERİNE `nox_arena_alloc` İLE tahsis edilir. `old_ptr`e (`nox_list_grow`
/// İLE AYNI gerekçeyle) HİÇ DOKUNULMAZ — AMA BURADA çağıran TARAFINDAN
/// `nox_rc_predecrement`/`nox_rc_free_payload` de HİÇ ÇAĞRILMAZ (arenalar
/// per-object free DESTEKLEMEZ; ESKİ chunk, fonksiyonun KENDİ arenası
/// TOPLU `nox_arena_destroy` İLE yıkılana kadar SADECE "çöp" olarak
/// yaşar — bu, arenaların DOĞAL/beklenen MODELİDİR).
pub export fn nox_arena_list_grow(arena_ptr: ?*anyopaque, old_ptr: ?*anyopaque, copy_bytes: usize, new_payload_size: usize) ?*anyopaque {
    const new_ptr = lowlevel.nox_arena_alloc(arena_ptr, new_payload_size) orelse return null;
    if (old_ptr) |op| {
        const src: [*]const u8 = @ptrCast(op);
        const dst: [*]u8 = @ptrCast(new_ptr);
        @memcpy(dst[0..copy_bytes], src[0..copy_bytes]);
    }
    return new_ptr;
}

// GG.24 (bkz. plan dosyası "genClassRelease'in özyineleme derinliği
// sertleştirmesi"): derinlik-eşiği KARMA yaklaşımı — `compiler/codegen_qbe/
// layout.zig`nin `genClassRelease`i, bir sınıf-tipli alanı serbest
// bırakırken (alan KENDİSİ de sınıf-tipliyse) ÖNCEDEN DOĞRUDAN `call
// $FieldClass_release` üretiyordu — bir bağlı-liste/ağaç ZİNCİRİNİ serbest
// bırakırken HER halka İçİn GERÇEK bir QBE çağrısı/yığın çerçevesi
// tüketiyordu (GG.23'ün ARAŞTIRMASININ bulduğu, cycle_detector.zig'DEN
// TAMAMEN AYRI bir risk — bkz. plan dosyası). Aşağıdaki İKİ fonksiyon,
// `ownership.zig`/`exceptions.zig`nin ÜÇ çağrı sitesi TARAFINDAN, DOĞRUDAN
// `$ClassName_release`/`$nox_class_release_dispatch` çağrısının YERİNE
// çağrılır — `compiler/parser/parser.zig`nin `enterRecursion`/`exitRecursion`
// VE `compiler/typecheck/checker.zig`nin `enterExprRecursion`/
// `exitExprRecursion`iyle AYNI ilke: bir derinlik sayacı İLK `MAX_DIRECT_
// RELEASE_DEPTH` seviye İçİn BUGÜNKÜ GİBİ (SIFIR ek yük) DOĞRUDAN
// çağırmaya İZİN VERİR, SADECE bunu GERÇEKTEN aşan patolojik zincirlerde
// yığın-tabanlı (heap, pratikte SINIRSIZ) bir worklist'e düşer —
// `cycle_detector.zig`nin `markGray`/`scanBlack`İYLE AYNI iteratif-
// worklist deseni.
//
// **Bulundu, GERÇEK bir performans regresyonu (git worktree A/B, `oop_
// arc_churn` mikro-benchmarkıyla ÖLÇÜLDÜ — ~2x YAVAŞLAMA)**: durum
// (`depth`/`pump_active`/`worklist`/dlsym önbelleği) İLK sürümde Zig
// `threadlocal var`larla tutuluyordu — TEK bir struct'a/TEK bir
// threadlocal DEĞİŞKENE birleştirilse BİLE, `otool -tV` İLE derlenmiş
// ARM64 kodun DOĞRUDAN okunmasıyla KANITLANDI: macOS'un TLV (Thread-
// Local Variable) thunk'ı, `rs = releaseState()` İLE elde edilen bir
// POINTER olsa BİLE, `rs.depth`/`rs.pump_active` GİBİ HER AYRI ALAN
// erişiminde AYRI bir thunk-çağrısı ÜRETİYORDU (Zig/LLVM bunu TEK bir
// bloğun İÇİNDE BİLE CSE ETMİYOR) — `arc.zig`nin ZATEN VAR OLAN
// `poolSlotFor`nin AYNI, DAHA ÖNCE bulunmuş "TLV erişimi HOT path'te"
// dersiyle AYNI KÖK NEDEN. **Düzeltme**: durumu `asap.RuntimeState`nin
// KENDİSİNE (ZATEN `rt` PARAMETRESİ olarak elde bulunan, `pool_free_
// lists_slot0`/`poolFreeListsRow` İLE AYNI slot-BAŞINA hiç-kilit-
// gerekmeyen desen) TAŞIMAK — `asap.releaseStateFor(state, poolSlotFor(
// state))`, SIRADAN bir bellek erişimi (TLV YOK). Release cascade'i
// (`_release`/`_gc_free` fonksiyonları TAMAMEN mekanik/üretilmiş, Nox'ta
// kullanıcı-tanımlı yıkıcı/`__del__` YOK) ASLA bir `await`/fiber-yield
// NOKTASI İÇERMEDİĞİNDEN, bir OS iş parçacığının KENDİ slotuna SADECE O
// iş parçacığı yazdığından (bkz. `poolFreeListsRow`nin AYNI gerekçesi)
// kilit GEREKMEZ.
// GG.25 (bkz. plan dosyası "STACK_SIZE küçültmesi — MAX_DIRECT_RELEASE_
// DEPTH ayarı"): GG.24'ün İLK tahmini (200 seviye × ~32 B/seviye ≈ 6,4 KB)
// GERÇEK ölçümle DOĞRULANDI (`nox_rc_release_enqueue_fixed`/`_dynamic`
// SARMALAYICILARIYLA BİRLİKTE bile ~75 B/seviye — 200 seviyede tavan
// SADECE ~17.936 B, `NOX_STACK_PAINT`İLE TEMİZ bir ReleaseFast derlemesiyle
// ÖLÇÜLDÜ; ARADA BİR turda YANLIŞLIKLA Debug-modu `noxrt.o` İLE ÖLÇÜLÜP
// ~520 B/seviye/137.904 B GİBİ ÇOK ŞİŞİRİLMİŞ bir rakam elde EDİLMİŞTİ —
// o rakam GEÇERSİZDİ, YANLIŞ ölçüm metodolojisinden kaynaklanıyordu).
// BU sabit YİNE de 200'DEN 50'YE düşürüldü (200'ün KENDİSİ ZATEN GÜVENLİYDİ,
// AMA 50 EK bir güvenlik payı sağlıyor VE GERÇEK-dünya — Aether/Nyx —
// zincirleri PRATİKTE asla 50 seviyeye BİLE YAKLAŞMADIĞINDAN davranış/
// performans SIFIR etkilenir) — 128 KiB'e küçültülen `STACK_SIZE`nin
// (bkz. `fiber.zig`) ÇOK RAHAT altında kalan bir tavan (~5.936 B, ÖLÇÜLDÜ,
// hedefin SADECE ~%4.5'i) sağlar.
const MAX_DIRECT_RELEASE_DEPTH: usize = 50;

/// Sınıf örneğinin (refcount başlığından SONRA) İLK `TAG_SIZE` baytındaki
/// çalışma-zamanı sınıf etiketi — `cycle_detector.zig`nin `readTag`ıyla
/// AYNI, KÜÇÜK bir bağımsız kopya (`arc.zig` `cycle_detector.zig`yi
/// import EDEMEZ — TERS yönde ZATEN bir bağımlılık var: `cycle_detector.
/// zig` `arc.zig`yi import ediyor, döngüsel olurdu).
fn releaseWorklistReadTag(p: *anyopaque) i64 {
    const tag_ptr: *const i64 = @ptrCast(@alignCast(p));
    return tag_ptr.*;
}

const WinDlSelf = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn GetModuleHandleA(name: ?[*:0]const u8) callconv(.c) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.c) ?*anyopaque;
} else struct {};

/// `$nox_class_release_dispatch(rt, tag, p)`e (bkz. `layout.zig`nin
/// `genClassReleaseDispatch`ı) `dlsym` İLE ÇALIŞMA ZAMANINDA dağıtır —
/// `cycle_detector.zig`nin `resolveTraceDispatch`/`resolveGcFreeDispatch`
/// İLE AYNI gerekçe (BAĞIMSIZ, KÜÇÜK bir kopya): bu sembol SADECE sınıf
/// İÇEREN programlarda üretilir (`class_ids.items.len > 0` koşulu), sabit
/// bir `extern fn` sınıfSIZ bir programda/`noxrt_test`te bağlama adımını
/// çökertirdi.
fn resolveClassReleaseDispatch(rs: *asap.ReleaseState) ?*const fn (?*anyopaque, i64, ?*anyopaque) callconv(.c) void {
    if (rs.class_release_dispatch_resolved) return rs.class_release_dispatch_fn;
    rs.class_release_dispatch_resolved = true;
    if (builtin.os.tag == .windows) {
        const module = WinDlSelf.GetModuleHandleA(null) orelse return null;
        const sym = WinDlSelf.GetProcAddress(module, "nox_class_release_dispatch") orelse return null;
        rs.class_release_dispatch_fn = @ptrCast(@alignCast(sym));
        return rs.class_release_dispatch_fn;
    }
    const handle = std.c.dlopen(null, .{ .NOW = true }) orelse return null;
    const sym = std.c.dlsym(handle, "nox_class_release_dispatch") orelse return null;
    rs.class_release_dispatch_fn = @ptrCast(@alignCast(sym));
    return rs.class_release_dispatch_fn;
}

fn dispatchClassRelease(rt: ?*anyopaque, tag: i64, p: *anyopaque, rs: *asap.ReleaseState) void {
    const f = resolveClassReleaseDispatch(rs) orelse return;
    f(rt, tag, p);
}

/// `rt`den (`RuntimeState`) BU OS iş parçacığının KENDİ release-durumunu
/// (`asap.ReleaseState`) döner — `arc.zig`nin ZATEN VAR OLAN `poolSlotFor`ı
/// İLE AYNI slot (`pool_free_lists` İLE PAYLAŞILAN numaralandırma).
/// `rt == null` OLAN (İZOLE Zig birim testleri, GERÇEK Nox programlarında
/// ASLA olmaz) NADİR durumda `null` döner — çağıran BUNU "SADECE doğrudan
/// çağır, derinlik/worklist İZLEME YOK" OLARAK yorumlar (bu durumda
/// GERÇEK bir RuntimeState/slot YOK, izlenecek bir ŞEY de yok).
fn releaseStateForRt(rt: ?*anyopaque) ?*asap.ReleaseState {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    // `poolSlotFor(state)`i KOŞULSUZ ÇAĞIRMAK YERİNE — bir `oop_arc_churn`
    // A/B ölçümü, `poolSlotFor`nin `noinline` çağrı MALİYETİNİN (COMMON,
    // havuzsuz durumda BİLE ÖDENEN prologue/epilogue+dal) HÂLÂ ÖLÇÜLEBİLİR
    // olduğunu gösterdi — `pool_ever_active`nin KENDİSİ (`state`nin SIRADAN
    // bir alanı, TLV DEĞİL) BURADA DOĞRUDAN kontrol edilip HAVUZSUZ (BÜYÜK
    // ÇOĞUNLUK) durumda `poolSlotFor`e HİÇ GİRİLMEZ. GÜVENLİ: `poolSlotFor`nin
    // KENDİ `noinline`+`@branchHint(.unlikely)` bariyeri SADECE "havuz VARSA"
    // dalında (aşağıda) korunuyor — `poolSlotFor`nin ÖNLEDİĞİ if-dönüştürme
    // hatası (bkz. onun belge notu) SADECE "KÜÇÜK/inline-EDİLEBİLİR bir
    // threadlocal erişimini KOŞULLU sarmalamak" durumunda oluşur; BURADAKİ
    // koşul (`pool_ever_active`) TLV DEĞİL, VE `poolSlotFor`nin KENDİSİ
    // (`.unlikely` dalda) HÂLÂ GERÇEK bir çağrı SINIRI olarak KALIYOR.
    if (!state.pool_ever_active.load(.monotonic)) {
        return &state.release_state_slot0;
    }
    return asap.releaseStateFor(state, poolSlotFor(state));
}

/// `MAX_DIRECT_RELEASE_DEPTH`i AŞAN (VEYA worklist ZATEN drenajda olan,
/// İÇ İÇE bir çağrı) durumlarda düşülen yol — `ptr`i (tag'İYLE birlikte)
/// worklist'e EKLER; bir pompa ZATEN AKTİF DEĞİLSE ("dıştan" İLK çağrı)
/// worklist BOŞALANA kadar POP+dispatch eder (`cycle_detector.zig`nin
/// `markGray`/`scanBlack`İYLE AYNI heap-tabanlı worklist deseni — TOPLAM
/// en kötü-durum yığın derinliği ARTIK zincir uzunluğundan BAĞIMSIZ,
/// SADECE `MAX_DIRECT_RELEASE_DEPTH` + BU pompanın KENDİ SABİT birkaç
/// çerçevesiyle sınırlıdır).
fn enqueueAndMaybePump(rt: ?*anyopaque, tag: i64, ptr: *anyopaque, rs: *asap.ReleaseState) void {
    rs.worklist.append(std.heap.page_allocator, .{ .tag = tag, .ptr = ptr }) catch {
        // OOM: BEST-EFFORT — doğrudan dispatch et (astronomik derecede
        // NADİR bir yedek yol, whatever kalan yığın riskini KABUL eder).
        dispatchClassRelease(rt, tag, ptr, rs);
        return;
    };
    if (rs.pump_active) return; // DIŞ bir pompa BUNU er geç işleyecek.
    rs.pump_active = true;
    defer rs.pump_active = false;
    while (rs.worklist.pop()) |item| dispatchClassRelease(rt, item.tag, item.ptr, rs);
}

/// Sabit (non-polymorphic, `has_vtable == false`) sınıflar İçİn — `release_fn`,
/// GERÇEK `$ClassName_release` sembolünün ADRESİDİR (codegen, sembol
/// ADINI bir `l`-tipi ARGÜMAN olarak GEÇİRİR — `closures.zig`nin
/// `qbeStoreL(mangled_release_sym, ...)` İLE AYNI, ZATEN kanıtlanmış
/// "QBE sembol-adı = geçerli `l` değeri" mekaniği). İLK `MAX_DIRECT_
/// RELEASE_DEPTH` seviye İçİn (worklist pompası ZATEN aktif DEĞİLSE)
/// BUGÜNKÜ GİBİ DOĞRUDAN çağırır (SIFIR ek yük) — SADECE eşik AŞILDIĞINDA
/// (VEYA worklist ZATEN drenajdaysa) `enqueueAndMaybePump`e düşer.
pub export fn nox_rc_release_enqueue_fixed(rt: ?*anyopaque, ptr: ?*anyopaque, release_fn: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void) void {
    const p = ptr orelse return;
    const f = release_fn orelse return;
    const rs = releaseStateForRt(rt) orelse {
        f(rt, p); // rt=null (izole test) — izleme YOK, doğrudan çağır.
        return;
    };
    if (!rs.pump_active and rs.depth < MAX_DIRECT_RELEASE_DEPTH) {
        rs.depth += 1;
        defer rs.depth -= 1;
        f(rt, p);
        return;
    }
    enqueueAndMaybePump(rt, releaseWorklistReadTag(p), p, rs);
}

/// Polimorfik (`has_vtable`) sınıflar VE çalışma-zamanı sınıfı derleme
/// zamanında BİLİNMEYEN durumlar (bare `except:`) İçİn — HER ZAMAN tag-
/// dispatch (BUGÜNKÜ `$nox_class_release_dispatch` çağrısıyla AYNI),
/// `nox_rc_release_enqueue_fixed`İLE AYNI derinlik-eşiği mantığı.
pub export fn nox_rc_release_enqueue_dynamic(rt: ?*anyopaque, ptr: ?*anyopaque) void {
    const p = ptr orelse return;
    const tag = releaseWorklistReadTag(p);
    const rs = releaseStateForRt(rt) orelse {
        // rt=null (izole test) — dlsym önbelleği OLMADAN TEK SEFERLİK
        // bir dispatch, izleme YOK.
        var scratch: asap.ReleaseState = .{};
        dispatchClassRelease(rt, tag, p, &scratch);
        return;
    };
    if (!rs.pump_active and rs.depth < MAX_DIRECT_RELEASE_DEPTH) {
        rs.depth += 1;
        defer rs.depth -= 1;
        dispatchClassRelease(rt, tag, p, rs);
        return;
    }
    enqueueAndMaybePump(rt, tag, p, rs);
}

test "rc_alloc 1 ile başlar, retain artırır, release azaltır ve sıfırda serbest bırakır" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const ptr = nox_rc_alloc(rt, 16) orelse return error.AllocFailed;
    const bytes: [*]u8 = @ptrCast(ptr);
    bytes[0] = 7;

    nox_rc_retain(ptr); // refcount: 2
    nox_rc_release(rt, ptr, 16); // refcount: 1 — hâlâ canlı
    try std.testing.expectEqual(@as(u8, 7), bytes[0]);
    nox_rc_release(rt, ptr, 16); // refcount: 0 — serbest bırakıldı
}

test "nox_rc_retain/release(null) güvenli bir hiçbir şey yapmama işlemidir" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    nox_rc_retain(null);
    nox_rc_release(rt, null, 0);
}

test "havuz: aynı boyut sınıfında serbest bırakılan blok yeniden kullanılır (yalnızca Release)" {
    // Debug modunda havuz KASITLI OLARAK devre dışıdır (bkz. modül üstü not
    // — DebugAllocator'ın tam güvenlik ağını korumak için); bu test o zaman
    // bir iddia yapmadan geçer, yalnızca Release modlarında (`zig build test
    // -Doptimize=ReleaseFast`) GERÇEK havuz geri dönüşümünü doğrular.
    if (!use_pool) return;

    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const p1 = nox_rc_alloc(rt, 8) orelse return error.AllocFailed;
    nox_rc_free_payload(rt, p1, 8);
    const p2 = nox_rc_alloc(rt, 8) orelse return error.AllocFailed;
    try std.testing.expectEqual(p1, p2);
    nox_rc_free_payload(rt, p2, 8);
}

test "havuz: çok büyük bir tahsis (havuz sınırının üstünde) hâlâ doğru çalışır" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const big_size: usize = 1 << 20; // 1 MiB — POOL_NUM_CLASSES sınırının çok üstünde
    const ptr = nox_rc_alloc(rt, big_size) orelse return error.AllocFailed;
    const bytes: [*]u8 = @ptrCast(ptr);
    bytes[0] = 99;
    try std.testing.expectEqual(@as(u8, 99), bytes[0]);
    nox_rc_free_payload(rt, ptr, big_size);
}
