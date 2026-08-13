//! Nox Katman 1 (ASAP) çalışma zamanı ayırıcısı — AGENTS.md §8.
//!
//! İlke #6 (Değişmez): "Global/gizli mutable state yasak. Runtime,
//! allocator'ları her zaman açıkça parametre olarak alır." Derlenmiş bir Nox
//! programı, `nox_runtime_init` ile başlangıçta oluşturulan opak bir bağlamı
//! (`rt`) her fonksiyon çağrısına AÇIKÇA taşır (bkz. compiler/codegen_qbe).
//! Bu bir "gizli global" değildir — QBE IR'da her çağrıda görünür bir
//! parametre olarak geçirilir; runtime'ın kendisi hiçbir statik/global
//! değişken tutmaz.
//!
//! v0.1 kapsamı: yalnızca Katman 1 (ASAP) — tahsis + doğrudan serbest bırakma.
//! Katman 2 (ARC retain/release) ve Katman 3 (döngü çözücü) sonraki bir fazda
//! eklenecektir (bkz. nox-teknik-spesifikasyon.md §3.5).
//!
//! **Backing allocator, build moduna göre KOŞULLU (bkz. Faz 16 — benchmark
//! suite'e Python karşılaştırması eklenirken bulundu):** Debug modunda
//! `std.heap.DebugAllocator` kullanılır (sızıntı tespiti + `zig build test`in
//! dayandığı güvenlik ağı — bkz. tests/golden, 4 gerçek hata bu sayede
//! yakalanmıştı). Ama `DebugAllocator`, `safety` bayrağından BAĞIMSIZ olarak,
//! yüksek hacimli tahsis/serbest-bırakma döngülerinde (ör. bir döngüde
//! tekrar tekrar `list[T]` inşa etmek) `mmap`/`munmap` ağırlıklı, TAMAMEN
//! yapay bir yavaşlığa yol açıyor — ölçüldü: 5 milyon liste tahsisi/serbest
//! bırakması DebugAllocator ile ~12s (çoğu system time), Zig'in üretim
//! kalitesindeki `std.heap.smp_allocator`ıyla ~0.1s. Bu, gerçek dil/codegen
//! performansını YANSITMAYAN, salt ayırıcı seçimine ait bir farktır. Bu
//! yüzden Release modlarında (`ReleaseFast`/`ReleaseSafe`/`ReleaseSmall`)
//! `smp_allocator`a geçilir — sızıntı tespiti o modlarda YAPILMAZ (hız
//! ölçümü/karşılaştırma içindir; doğruluk/sızıntı güvenliği Debug modundaki
//! `zig build test`in kendisiyle zaten sürekli doğrulanır).

const std = @import("std");
const builtin = @import("builtin");

const use_debug_allocator = builtin.mode == .Debug;

/// Faz X.3 (bkz. docs/uretim-hazirlik-analizi.md — "ARC atomikliği/cross-
/// thread invariant'ını YA gerçek atomiklerle YA DA derleme-zamanı bir
/// assertion'la RESMİLEŞTİR"). `builtin.mode == .Debug`de AKTİF —
/// `use_debug_allocator`/`arc.zig`nin `use_pool`u İLE AYNI "Debug =
/// TAM güvenlik ağı, Release = TAM hız" ilkesi.
const debug_thread_check = builtin.mode == .Debug;

/// Faz S.3: `runtime/alloc/cycle_detector.zig`de TANIMLI/`export`lu —
/// `asap.zig`nin O dosyayı IMPORT ETMEDEN (döngüsel bağımlılık kurmadan)
/// çağırabilmesi İÇİN düz bir `extern fn` bildirimi (bkz. `cycle_gc`in
/// belge notu). Her ikisi de `runtime/lib.zig` aracılığıyla AYNI `noxrt`
/// nesnesine derlendiğinden, LİNKER bu referansı normal şekilde çözer.
extern fn nox_cycle_deinit(rt: ?*anyopaque) callconv(.c) void;
/// AYNI gerekçe — `nox_runtime_deinit`, PROGRAM SONUNDA HENÜZ tahsis-baskısı
/// eşiğini AŞMAMIŞ (bkz. `nox_cycle_possible_root`in belge notu) "olası
/// kök" durumundaki döngüleri KAÇIRMAMAK için `nox_cycle_deinit`DEN ÖNCE
/// SON bir kez `nox_cycle_collect` çağırır — aksi halde KÜÇÜK, kısa ömürlü
/// programlardaki (ör. testler) döngüler eşiğe HİÇ ULAŞMADAN sessizce
/// sızardı.
extern fn nox_cycle_collect(rt: ?*anyopaque) callconv(.c) void;

/// ARC nesneleri (bkz. `runtime/alloc/arc.zig`) için sabit büyüklük-sınıflı
/// serbest liste havuzunun sınıf sayısı — performans fazında (benchmark
/// darboğaz denetimi, `oop_arc_churn`in profillenmesiyle bulundu: örneklerin
/// ~%45'i `smp_allocator`ın kendi tahsis/serbest bırakma overhead'indeydi)
/// eklendi. Havuz yalnızca `arc.zig`'in kendi `use_pool` sabitiyle Release
/// modlarında AKTİFTİR — bu alanlar Debug modunda da (basitlik için KOŞULSUZ
/// tip) var olsa da hiç DOKUNULMAZ: her tahsis/serbest bırakma DOĞRUDAN
/// `DebugAllocator`a gider, tam güvenlik ağı (bkz. modül üstü not) KORUNUR.
pub const POOL_NUM_CLASSES = 10;
pub const PoolNode = struct { next: ?*PoolNode };

/// Faz MN.10: `RuntimeState.pool_free_lists`in TEK bir worker'a AİT
/// satırı — `align(std.atomic.cache_line)` (platform başına doğru sabit)
/// BİLİNÇLİ: `POOL_NUM_CLASSES * @sizeOf(?*PoolNode)` (80 bayt, 64-bit'te)
/// TEK bir 64 baytlık cache line'A SIĞMAZ — hizalama OLMADAN komşu
/// worker'ların satırları bir cache line PAYLAŞABİLİR, bu da (satırlar
/// arası HİÇBİR mantıksal veri yarışı OLMASA BİLE) yüksek-frekanslı eş
/// zamanlı erişimde (ör. JSON decode/encode, İSTEK BAŞINA ONLARCA KEZ
/// dokunulur) donanım seviyesinde MESI cache-line "ping-pong"a yol AÇAR.
pub const PoolFreeListRow = struct {
    classes: [POOL_NUM_CLASSES]?*PoolNode align(std.atomic.cache_line) = @splat(null),
};

/// Faz MN.3b: bir `RuntimeState` havuzunun (bkz. proje planı "Worker
/// soyutlaması") destekleyebileceği ÜST worker sınırı — TEK kaynak,
/// `OwnerPool.MAX_MEMBERS` (Faz MN.1) VE `RuntimeState.globals_blocks`
/// (aşağıya bkz.) İKİSİ de BUNU kullanır (AYNI "bir havuzun üst sınırı"
/// kavramının İKİ AYRI sihirli sayıya SÜRÜKLENMESİNİ ÖNLER).
pub const MAX_POOL_WORKERS = 64;

/// Faz MN.1: `RuntimeState.arc_owner_pool`in DEPOLAMASI — bkz. onun belge
/// notu. `MAX_MEMBERS`, gelecekteki bir worker havuzunun ÜST sınırıdır
/// (dinamik ayırma GEREKTİRMEYECEK kadar KÜÇÜK/sabit); `capacity`,
/// `members`in KAÇ İNDEKSİNİN GEÇERLİ sayılacağını (`MAX_MEMBERS`e KADAR)
/// belirler — varsayılan 1, Faz X.3'ün ORİJİNAL "tek sahip" semantiğidir.
pub const OwnerPool = struct {
    pub const MAX_MEMBERS = MAX_POOL_WORKERS;
    members: [MAX_MEMBERS]std.Thread.Id = undefined,
    count: usize = 0,
    capacity: usize = 1,
};

/// Faz MN.3b: `runtime/async_rt/thread_channel.zig`nin `ThreadChannel`ı
/// İçİn yazılmış CAS-tabanlı spin-kilidin BURAYA taşınmış TEK doğruluk
/// kaynağı hali (Faz P1.2'nin AYNI ilkesi) — `RuntimeState`nin senkronize
/// alanları (`arena_pool_lock`/`cycle_gc_lock`, aşağıya bkz. — Faz MN.10'DAN
/// İTİBAREN `pool_free_lists_lock` ARTIK YOK, bkz. `pool_free_lists`in
/// KENDİ belge notu) VE `ThreadChannel`nin KENDİSİ artık AYNI bu tipi
/// paylaşır. `std.Thread.Mutex` bu Zig sürümünde YOK
/// (`std.Io.Mutex`, kilit alma İçİn bir `Io` arayüzü İSTER — genel
/// amaçlı bir OS-iş-parçacığı kilidi DEĞİL).
///
/// Faz MN.4/5.8: GERÇEK tanım `runtime/async_rt/spinlock.zig`ye TAŞINDI
/// (bkz. onun belge notu — `scheduler.zig`nin BUNU `../alloc/asap.zig`
/// ÜZERİNDEN İTHAL ETMESİ, `fiber.zig`/`scheduler.zig`/`channel.zig`/
/// `io.zig`nin BİLİNÇLİ "runtime/alloc/den BAĞIMSIZ" sınırını KIRIYORDU)
/// — BURADA SADECE YENİDEN DIŞA AÇILIR, TÜM mevcut `asap.SpinLock`
/// kullanım siteleri (`thread_channel.zig`, aşağıdaki `*_lock` alanları)
/// SIFIR değişiklik GÖRÜR.
pub const SpinLock = @import("../async_rt/spinlock.zig").SpinLock;

pub const RuntimeState = struct {
    debug_gpa: if (use_debug_allocator) std.heap.DebugAllocator(.{}) else void,
    /// Faz OO.3, Faz MN.2'de fiber-affine hale GETİRİLDİ: birincil depo
    /// ARTIK `Fiber.pending_exception`dir (bkz. onun belge notu) —
    /// BURADAKİ alan SADECE fiber DIŞINDA (senkron üst-düzey kod,
    /// `bridge.currentFiber() == null`) çalışan `nox_raise`/`nox_
    /// exception_*` çağrıları İçin YEDEKTİR (`runtime/errors/handle.zig`nin
    /// `pendingException`i, BUGÜNKÜ davranışla BİREBİR aynı).
    pending_exception: ?*anyopaque = null,
    /// Faz OO.3 (bkz. nox-teknik-spesifikasyon.md §3.84, "zengin exception
    /// stack/source span"): `nox_raise`in ARTIK ikinci bir argümanla
    /// aldığı, `raise`/örtük-raise (IndexError/KeyError/ValueError) SATIR
    /// numarası — `nox_unhandled_exception`ın yakalanmamış bir istisnayı
    /// TİP ADI + SATIR + MESAJLA raporlayabilmesi İçİn. Faz MN.2: AYNI
    /// yedek-depo notu (`pending_exception`e bkz.) BURASI İçin de geçerlidir.
    pending_exception_line: i64 = 0,
    /// Faz MN.10 (bkz. profillenmiş kanıt — Aether'in HTTP+JSON `wrk`
    /// ölçümü, "8 worker 1 worker'dan YAVAŞ" ters ölçekleme): TEK
    /// paylaşılan diziden (Faz MN.3b'nin ORİJİNAL şekli, `pool_free_
    /// lists_lock: SpinLock` İLE korunan `[POOL_NUM_CLASSES]?*PoolNode`)
    /// worker-slotlu bir diziye genişletildi — `globals_blocks`İLE
    /// (aşağıya bkz.) BİREBİR AYNI desen/gerekçe: HER worker KENDİ
    /// satırına `asap.currentWorkerSlot()` İLE erişir, kilit YOK (`nox_
    /// rc_free_payload` HER ZAMAN o ANDA referansı BIRAKAN fiber'ı
    /// ÇALIŞTIRAN OS iş parçacığında çalışır — nesneyi TAHSİS EDEN iş
    /// parçacığı OLMAK ZORUNDA DEĞİL [work-stealing İLE göç edebilir],
    /// AMA bu SORUN DEĞİL: o ANDA `currentWorkerSlot()` O ANKİ iş
    /// parçacığının KENDİ slotunu doğru tanımlar, SADECE O iş parçacığı
    /// O slotun satırına DOKUNUR — hiçbir slot İKİ FARKLI iş parçacığı
    /// TARAFINDAN AYNI ANDA mutasyona UĞRAMAZ).
    ///
    /// **BU, MN.3b'nin "her zaman aktif, TEK kilitli kod yolu" ilkesinden
    /// SAPMA DEĞİL, PROFİLLENMİŞ kanıtla YÖNLENDİRİLEN, DAR kapsamlı bir
    /// istisnadır** — MN.3b'nin O ZAMANKİ varsayımı ("çekişmesiz bir
    /// `cmpxchgWeak` ÇOK UCUZDUR") GERÇEK, profillenmiş bir yük HENÜZ
    /// YOKKEN makuldü; ŞİMDİ (`nox.json.decode`/`encode` GİBİ tahsis-
    /// yoğun bir HTTP handler'ın 8 paylaşılan worker'DA 1 worker'DAN
    /// DAHA YAVAŞ olduğu ÖLÇÜLDÜ — kilit çekişmeli HİÇ de ucuz DEĞİLDİ)
    /// kanıt VAR, bu YÜZDEN SADECE BU alanda `globals_blocks`nin ZATEN
    /// kanıtlanmış worker-slotlu deseni tekrar KULLANILDI. **Kabul
    /// edilen v1 ödünleşimi:** bir fiber worker A'da tahsis edip work-
    /// stealing İLE worker B'ye GÖÇTÜKTEN SONRA serbest bırakırsa,
    /// serbest bırakılan blok worker B'nin YEREL listesine GİDER —
    /// worker'lar arası bellek DAĞILIMI zamanla DENGESİZ OLABİLİR
    /// (SIZINTI DEĞİL, sadece yeniden-kullanım YERELLİĞİ optimal
    /// OLMAYABİLİR); GERÇEK çapraz-worker yeniden-dengeleme (tcmalloc-
    /// tarzı merkezi taşma havuzu) BİLİNÇLİ olarak ERTELENDİ ("ölçülmeden
    /// mimari EKLEME" ilkesiyle TUTARLI — HTTP/JSON İçİn bu risk SIFIRDIR,
    /// bkz. AŞAĞIDAKİ not). `arena_pool_lock`/`cycle_gc_lock` (AŞAĞIDA)
    /// AYRI kaynakları koruyan AYRI kilitlerdir, HİÇBİR profillenmiş
    /// kanıt bunları İŞARET ETMİYOR, DOKUNULMADI.
    ///
    /// HTTP/JSON İçİn (bu değişikliği TETİKLEYEN yük) göç riski SIFIRDIR:
    /// `checker.zig`nin `validateHttpHandler`ı `handle`in `async def`
    /// OLAMAYACAĞINI ZORUNLU kılar — bağlantı handler'ı SENKRONDUR,
    /// HİÇBİR `await` NOKTASI TAŞIMAZ, bu YÜZDEN BİR isteğin TAMAMI
    /// (JSON decode+encode DAHİL) HER ZAMAN AYNI worker'da çalışır.
    pool_free_lists: [MAX_POOL_WORKERS]PoolFreeListRow = @splat(.{}),
    /// Dil stabilizasyonu fazı §M.7: `lowlevel` arena TUTAMAÇLARININ (bkz.
    /// `runtime/alloc/lowlevel.zig`, `ArenaHandle`) LIFO serbest liste BAŞI
    /// — `pool_free_lists`in AYNI Release-only prensibi (`lowlevel.zig`nin
    /// KENDİ `use_pool`u), ama TEK bir boyut sınıfı YETERLİ olduğundan
    /// (`ArenaHandle` HER ZAMAN AYNI boyutta) `pool_free_lists`in çok-
    /// sınıflı dizisi YERİNE tek bir OPAK işaretçi — `lowlevel.zig`
    /// `ArenaHandle`nin KENDİSİNE `next: ?*ArenaHandle` alanı ekleyip BU
    /// alanı `@ptrCast` ile güçlü tipe çevirir (asap.zig↔lowlevel.zig
    /// arasında DAİRESEL import GEREKMEZ, tıpkı `PoolNode`nin arc.zig
    /// tarafından KULLANILMASI gibi).
    arena_pool: ?*anyopaque = null,
    /// Faz MN.3b: `arena_pool`un push/pop'unu (bkz. `lowlevel.zig`nin
    /// `nox_arena_create`/`nox_arena_destroy`ı) korur — `pool_free_lists_
    /// lock`la AYNI "her zaman aktif" gerekçesi.
    arena_pool_lock: SpinLock = .{},
    /// Faz S.3 (Katman 3, döngü çözücü) — `runtime/alloc/cycle_detector.zig`nin
    /// KENDİ `CycleGc` durumuna opak bir işaretçi (tembel/lazy oluşturulur,
    /// bkz. onun `getGc`si). `arena_pool` İLE AYNI gerekçeyle opak: `asap.zig`
    /// `cycle_detector.zig`yi IMPORT ETMEDEN (döngüsel bağımlılık kurmadan)
    /// bu alanı taşıyabilir — gerçek serbest bırakma `nox_cycle_deinit`e
    /// (aşağıdaki `extern fn` bildirimi, DÜZ bağlama — bkz. `runtime/lib.zig`nin
    /// İKİSİNİ de AYNI `noxrt` nesnesine derlediği) DELEGE edilir.
    cycle_gc: ?*anyopaque = null,
    /// Faz MN.3b: `cycle_gc`ye dokunan TÜM fonksiyonları (`getGc`/`nox_
    /// cycle_possible_root`/`nox_cycle_forget`/`nox_cycle_collect`/`nox_
    /// cycle_deinit`) SERİLEŞTİRİR — AMA **SADECE `CycleGc`nin KENDİ
    /// defter tutma yapılarını (`gc.meta`/`gc.roots`) korur, TAM bir
    /// çözüm DEĞİLDİR.** `nox_cycle_collect`in GERÇEK mark/scan geçişi
    /// (bkz. `cycle_detector.zig`nin `markGray`/`scanBlack`ı) taranan
    /// nesnelerin refcount'unu PLAIN (ATOMİK OLMAYAN) `-=`/`+=` İLE
    /// okur/yazar — bu kilidin KAPSAMI DIŞINDA kalan BAŞKA bir worker'ın
    /// AYNI nesneyi O ANDA ATOMİK `nox_rc_retain`/`nox_rc_predecrement`
    /// İLE dokunmasıyla YARIŞABİLİR. **BU, UYGULAMA SIRASINDA (`runtime/
    /// async_rt/worker_pool.zig`nin eşzamanlı stres testinde) GERÇEKTEN
    /// DENENİP SIGBUS İLE ÇÖKTÜĞÜ DOĞRULANDI** — bu YÜZDEN `worker_pool.
    /// zig`nin KENDİ testi `nox_cycle_collect`i eş zamanlı ÇAĞIRMAZ
    /// (SADECE TÜM worker'lar `join` edildikten SONRA, TEK iş parçacıklı
    /// bağlamda). GERÇEK güvenlik SADECE Faz MN.6'nın (TÜM worker'lar
    /// fiber-yield noktalarında DURDURULDUKTAN SONRA collect çalışır)
    /// kooperatif "dünyayı-durdur" bariyeriyle mümkündür — bu alan ONA
    /// kadar SADECE `CycleGc`nin defter tutmasını (collector-VS-collector
    /// çekişmesini) korumaya YARAR, collector-VS-eşzamanlı-ARC-mutasyonu
    /// riskini ORTADAN KALDIRMAZ.
    cycle_gc_lock: SpinLock = .{},
    /// Faz X.3, Faz MN.1'de HAVUZ-farkındalıklı hale GENİŞLETİLDİ: bu
    /// `rt`nin ARC (Katman 2, bkz. `runtime/alloc/arc.zig`) işlemlerine
    /// dokunmasına İZİN VERİLEN OS iş parçacıklarının KÜÇÜK bir kümesi
    /// (varsayılan KAPASİTE 1 — Faz X.3'ün ORİJİNAL "tek sahip" semantiğiyle
    /// BİREBİR aynı, aşağıdaki `arcOwnerThreadOk` testleri BUNU KANITLAR).
    /// `nox_rc_alloc`/`nox_rc_free_payload` (aşağıdaki `arcOwnerThreadOk`ya
    /// bkz.) HER çağrıda BUNU doğrular. **Nox'un çalışma zamanı ARC
    /// refcount'u (`arc.zig`nin `i64` başlığı) Faz MN.1'DEN İTİBAREN
    /// KOŞULSUZ atomiktir**, `arena_pool`/`cycle_gc` Faz MN.3b'DEN
    /// İTİBAREN KİLİTLERLE korunur (bkz. yukarıdaki `*_lock` alanları —
    /// `pool_free_lists` Faz MN.10'DAN İTİBAREN worker-slotlu, KİLİTSİZ
    /// bir dizi, bkz. onun KENDİ belge notu) — kapasite BİR worker havuzu
    /// (bkz. `runtime/async_rt/worker_pool.zig`) KURULDUĞUNDA `setArcOwnerPoolCapacity`
    /// İLE havuz büyüklüğüne YÜKSELTİLİR, HER worker BİRİNCİ ARC
    /// dokunuşunda KENDİLİĞİNDEN KAYITLI bir üye OLUR.
    arc_owner_pool: if (debug_thread_check) OwnerPool else void =
        if (debug_thread_check) .{} else {},
    /// Faz MN.4/5.8: `arcOwnerThreadOk`nin KENDİ "üye mi, DEĞİLSE kaydet"
    /// mantığını korur — **GERÇEK, ÖNCEDEN VAR OLAN bir eşzamanlılık
    /// hatası** (bu görev SIRASINDA, `WorkerPool`nin GERÇEK 4-iş-parçacıklı
    /// stres testinde AMPİRİK olarak yakalandı VE `git stash` İLE
    /// düzeltmeler OLMADAN, TAMAMEN İLİŞKİSİZ bir Zig sürümünde BİLE
    /// TEKRARLANDIĞI doğrulandı — bkz. proje belleği): `arcOwnerThreadOk`
    /// `pool.members[pool.count] = current; pool.count += 1;` yazımını
    /// HİÇBİR kilit OLMADAN yapıyordu — İKİ (VEYA DAHA FAZLA) worker AYNI
    /// ANDA İLK KEZ kayıt OLMAYA çalıştığında (TAM OLARAK bir worker
    /// havuzunun BAŞLANGICINDA olan şey) bu bir veri yarışıydı — kayıp bir
    /// güncelleme `pool.count`u YANLIŞ bırakabilir, DAHA SONRA GERÇEKTEN
    /// KAYITLI bir worker'ın `arcOwnerThreadOk`sinin YANLIŞLIKLA `false`
    /// dönüp `nox_rc_free_payload`nin `std.debug.assert`ini ÇÖKERTMESİNE
    /// yol açabilirdi (GERÇEKTEN GÖZLEMLENDİ). SADECE `debug_thread_check`
    /// AKTİFKEN VAR (Release'de HİÇBİR maliyet — `arc_owner_pool`nun
    /// KENDİSİYLE AYNI koşullu tip deseni).
    arc_owner_pool_lock: if (debug_thread_check) SpinLock else void =
        if (debug_thread_check) .{} else {},
    /// Bulundu (bkz. proje belleği "modül-seviyesi global durum" planı):
    /// derleyicinin ürettiği `$nox_init_globals`in `nox_alloc` İLE ayırıp
    /// `nox_globals_set` İLE buraya yazdığı, programa özgü DÜZ bellek
    /// bloğu — üst-düzey (script top-level) `var_decl`ların DEPOLANDIĞI
    /// yer. `arena_pool`/`cycle_gc` İLE AYNI gerekçeyle OPAK: bu dosya
    /// (runtime) HANGİ Nox programının HANGİ global'leri bildirdiğini
    /// HİÇBİR ZAMAN bilmez/yorumlamaz — bayt-düzeni TAMAMEN derleyicinin
    /// (compiler/codegen_qbe/globals.zig) sahip olduğu bir SÖZLEŞMEDİR,
    /// tıpkı bir sınıf örneğinin alan düzeni gibi.
    ///
    /// **Faz MN.3b: TEKİL alandan `MAX_POOL_WORKERS` uzunluklu bir
    /// DİZİYE genişletildi** — bir worker havuzunda (bkz. `worker_pool.
    /// zig`) N OS iş parçacığı ARTIK TEK bir `RuntimeState`yi
    /// PAYLAŞTIĞINDAN, `globals_block` TEKİL bir alan OLARAK KALSAYDI
    /// TÜM worker'lar YANLIŞLIKLA AYNI globals bloğunu (SON `nox_init_
    /// globals` çağrısı KAZANIR) PAYLAŞIRDI — Nox'ta HENÜZ HİÇBİR
    /// senkronizasyon ilkeli (mutex/atomic) KULLANICI KODUNA AÇIK
    /// OLMADIĞINDAN, BU genuinely-shared mutable global'ları
    /// KORUYAMAYACAKLARI bir veri-yarışı silahı OLURDU — BİLİNÇLİ olarak
    /// REDDEDİLDİ. Bunun yerine HER worker KENDİ `g_worker_slot`una
    /// (aşağıya bkz.) göre dizinin KENDİ HÜCRESİNE erişir — `nox_globals_
    /// get`/`nox_globals_set`in ABI'si (`compiler/codegen_qbe/globals.zig`
    /// tarafından üretilen `$nox_init_globals`/`$nox_deinit_globals`)
    /// DEĞİŞMEZ, SIFIR codegen etkisi. Paylaşımsız (tek-iş-parçacıklı,
    /// BUGÜNKÜ) kullanım HER ZAMAN slot 0'ı kullanır — davranış BİREBİR
    /// aynı kalır.
    globals_blocks: [MAX_POOL_WORKERS]?*anyopaque = @splat(null),
    /// Faz MN.4/5: BU `rt`nin BİR `worker_pool.WorkerPool`e AİT olup
    /// OLMADIĞINI (VE öyleyse HANGİSİNE) İŞARET EDER — `arena_pool`/
    /// `cycle_gc` İLE AYNI OPAK-işaretçi gerekçesiyle (`asap.zig`,
    /// `worker_pool.zig`yi IMPORT ETMEDEN döngüsel bağımlılık kurmadan
    /// bu alanı taşıyabilir). `null` İSE (BUGÜNKÜ, tek-iş-parçacıklı/
    /// paylaşımsız kullanım) DAVRANIŞ TAMAMEN BİREBİR AYNI kalır — BU
    /// alana bakan HER kod yolu (`nox_cycle_possible_root`nun oto-eşik
    /// kapısı, `nox_async_spawn`nin deque-yönlendirmesi) `null` dalında
    /// BUGÜNKÜ, DEĞİŞMEMİŞ mantığı izler. `WorkerPool.create` BUNU
    /// kendine işaret edecek şekilde AYARLAR.
    worker_pool: ?*anyopaque = null,
    /// Faz MN.9.2: `$main`in (`--release` altında) OTOMATİK kurduğu
    /// havuzun `PoolRunCtx`si (`pool_bridge.zig`, `nox_pool_main_spawn_
    /// workers` TARAFINDAN AYARLANIR) — `nox_pool_main_join_and_destroy`
    /// `pool.destroy()`DAN (`state`in KENDİSİNİ FREE EDER) ÖNCE BUNU
    /// serbest bırakabilmek İçİn saklar. `worker_pool`/`arena_pool` İLE
    /// AYNI opak-işaretçi gerekçesi.
    main_pool_ctx: ?*anyopaque = null,
    /// Faz MN.4/5: `dict.zig`nin (ESKİDEN `threadlocal var g_hash_seed`/
    /// `g_hash_seed_init` OLAN) hash-flood-direnç tohumu — BURAYA
    /// TAŞINDI ÇÜNKÜ artık GERÇEK fiber göçü (work-stealing) AÇIK: bir
    /// `Dict`, HANGİ worker'a taşınırsa taşınsın AYNI `rt`ye (VE
    /// dolayısıyla AYNI tohuma) bağlı KALDIĞINDAN, insert/lookup ARASINDA
    /// FARKLI worker'ların FARKLI tohumlar kullanması (eskiden `Fiber`e
    /// TAŞINSAYDI OLACAK hata — bkz. `fiber.zig`nin Faz MN.2 notu, "dict
    /// hash-tohumu BİLİNÇLİ olarak Fiber'e taşınmadı") İMKANSIZ hale
    /// gelir — TEK bir `rt` İçİNDE TÜM worker'lar AYNI tohumu PAYLAŞIR.
    dict_hash_seed: u64 = 0,
    dict_hash_seed_init: bool = false,
    /// Faz MN.5: havuz-çapında YAKLAŞIK deadlock tespiti İçİn (bkz.
    /// proje planı, "Go'nun checkdead()'inin BASİTLEŞTİRİLMİŞ hali") —
    /// HER worker'ın `spawn`/fiber-bitişi KENDİ YEREL `Scheduler.
    /// live_count`uYLA BİRLİKTE BUNU da atomik olarak GÜNCELLER.
    /// `worker_pool == null` İKEN KULLANILMAZ (tek-worker'lı kullanım
    /// KENDİ YEREL `Scheduler.run()` kontrolüne GÜVENMEYE DEVAM eder,
    /// SIFIR davranış değişikliği).
    pool_live_count: std.atomic.Value(usize) = .init(0),
    /// Faz MN.5: AYNI gerekçe — HER worker'ın KENDİ YEREL `waiting_on_io`
    /// sayacıYLA BİRLİKTE günceller.
    pool_waiting_on_io: std.atomic.Value(usize) = .init(0),
    /// Faz MN.5: `runtime/async_rt/scheduler.zig`nin `poolWideDeadlockCheck`i
    /// İçİn — KAÇ worker'ın ŞU AN "boşta" (KENDİ deque'i+hazır kuyruğu BOŞ,
    /// kardeşlerden çalma BAŞARISIZ) OLDUĞUNU sayar. `pool_live_count > 0`
    /// OLMASI TEK BAŞINA deadlock'a İŞARET ETMEZ (BAŞKA bir worker HÂLÂ
    /// MEŞGUL olabilir — bu TAMAMEN NORMAL, dengesiz bir iş yükü) — deadlock
    /// SADECE `pool_idle_workers == (havuzdaki TOPLAM worker sayısı)`
    /// İKEN (yani TÜM worker'lar AYNI ANDA boştaysa) ANLAMLIDIR.
    pool_idle_workers: std.atomic.Value(usize) = .init(0),
    /// Faz MN.8, Bulgu B: `poolWideDeadlockCheck`nin (bkz. scheduler.zig)
    /// YAKLAŞIK sezgiselinin KÖK NEDEN düzeltmesi — MN.7a/7b doğrulamasında
    /// TEKRAR TEKRAR GERÇEKTEN gözlemlenen ("toplu spawn + sıralı await"
    /// deseni, GERÇEK bir fan-out/fan-in kullanımı, YAPAY bir stres deseni
    /// DEĞİL) YANLIŞ pozitif deadlock tespitini HEDEFLER. `markReady`nin
    /// `is_foreign` dalında VE `Scheduler.spawn`ın deque-push dalında
    /// `fetchAdd(1, .release)` EDİLİR (BİLİNÇLİ olarak DAR TUTULDU — HTTP
    /// bağlantı-kabul döngüsü GİBİ AŞIRI SIK AMA HER ZAMAN YEREL `markReady`
    /// çağıran yollar BUNA HİÇ dokunmaz). `poolWideDeadlockCheck`, deadlock
    /// İLAN ETMEDEN ÖNCE, GÖZLEM PENCERESİNİN BAŞINDA VE SONUNDA okunan
    /// İKİ değerin EŞİT OLDUĞUNU (yani HİÇBİR ÜRETİM olayının o pencerede
    /// GERÇEKLEŞMEDİĞİNİ) `.acquire` sıralı okumalarla KANITLAR — sadece
    /// "son anlık görüntü boş GÖRÜNDÜ" DEĞİL.
    pool_activity_epoch: std.atomic.Value(u64) = .init(0),
    /// Faz MN.6: `runtime/async_rt/scheduler.zig`nin `stwParticipate`sinin
    /// kullandığı "sense-reversing barrier" — kooperatif dünyayı-durdur
    /// (STW) round'unun giriş kapısı. `runtime/alloc/cycle_detector.zig`nin
    /// `nox_cycle_possible_root`ü eşiği AŞTIĞINDA `cmpxchgStrong(false,
    /// true, ...)` İLE BUNU ayarlar (yalnızca YARIŞI KAZANAN çağrı YENİ
    /// bir round BAŞLATIR) — GERÇEK collect, TÜM worker'lar `pool_stw_
    /// arrived`e ULAŞTIĞINDA (bkz. aşağısı) round'un LİDERİ TARAFINDAN
    /// çalıştırılır, BURADAN döner (BLOKE ETMEZ).
    pool_stw_requested: std.atomic.Value(bool) = .init(false),
    /// Faz MN.6: bu round'a KATILAN (kendi safe point'inde `stwParticipate`e
    /// GİRMİŞ) worker sayısı — `n_workers`e ULAŞTIĞINDA SON gelen worker
    /// "lider" olur.
    pool_stw_arrived: std.atomic.Value(usize) = .init(0),
    /// Faz MN.6: "sense-reversal" — HER round TAMAMLANDIĞINDA lider
    /// TARAFINDAN o round'un `Scheduler.stw_local_sense`iNE eşitlenir;
    /// straggler worker'lar KENDİ `stw_local_sense`leriyle EŞLEŞENE KADAR
    /// bekler. Bariyerin (TEK bir `bool` bayrağın YENİDEN KULLANILMASI
    /// olsaydı OLUŞACAK) ABA-tipi yeniden-kullanım hatasına KARŞI GEREKLİ
    /// (bkz. proje planı, "Faz MN.6" tasarım notu #1).
    pool_stw_sense: std.atomic.Value(bool) = .init(false),
    /// Faz MN.6: HER worker'ın ÇAPRAZ-worker uyandırma self-pipe'ının
    /// YAZMA ucu (bkz. `runtime/async_rt/self_pipe.zig`) — `-1` = BU
    /// slot HENÜZ yayınlanmadı/Windows'ta desteklenmiyor (bkz. `self_pipe.
    /// zig`nin modül üstü notu). `cycle_detector.zig`, YENİ bir STW
    /// round'u BAŞLATTIĞINDA TÜM DOLU (>= 0) slotlara `signalWakeFd`
    /// göndererek `self.reactor.poll()`de bloke olmuş worker'ları DERHAL
    /// uyandırır — AKSİ HALDE (`io_reactor.zig`nin `poll()`ü NULL/-1
    /// zaman aşımıyla SONSUZA KADAR bloklar) bir worker `stw_requested`i
    /// ASLA FARK ETMEZDİ.
    pool_wake_fds: [MAX_POOL_WORKERS]std.atomic.Value(i32) = @splat(.init(-1)),
    /// Faz MN.9.3: HER worker slotunun KENDİ `*Scheduler`ı (`bridge.zig`nin
    /// `nox_async_init`i, havuzlu dalında, `attachToPool` SONRASI, KENDİ
    /// `g_worker_slot`una YAZAR) — `runtime/async_rt/pool_bridge.zig`nin
    /// `broadcastRunOnEachWorker`ının (bkz. `nox_pool_serve`) TÜM worker'lara
    /// (SADECE ÇAĞIRANA DEĞİL) `scheduler.spawnToForeignScheduler` İLE
    /// ULAŞABİLMESİ İçİn — `null` = O slot HENÜZ `nox_async_init`
    /// ÇAĞIRMADI (`spawnWorkers`nin TRAMPOLİNİ İLE `attachToPool` ARASINDAKİ
    /// KISA pencerede TEORİK olarak mümkün, `broadcastRunOnEachWorker`
    /// BUNU KISA bir "hazır olana KADAR bekle" DÖNGÜSÜYLE ele alır).
    pool_scheduler_ptrs: [MAX_POOL_WORKERS]std.atomic.Value(?*anyopaque) = @splat(.init(null)),

    pub fn allocator(self: *RuntimeState) std.mem.Allocator {
        if (use_debug_allocator) return self.debug_gpa.allocator();
        return std.heap.smp_allocator;
    }
};

/// Faz MN.3b: bu OS iş parçacığının BİR worker havuzu İÇİNDEKİ konumu
/// (`RuntimeState.globals_blocks`e bkz.) — varsayılan 0, tek-iş-parçacıklı
/// (paylaşımsız) kullanım İçİn HER ZAMAN doğru olan değer. Bir havuz
/// worker'ı `worker_pool.zig`nin `WorkerPool.spawnWorkers`ı TARAFINDAN
/// başlatılırken BUNU KENDİ slotuna AYARLAR (`bridge.zig`nin `g_scheduler`ı
/// İLE AYNI `threadlocal` deseni).
threadlocal var g_worker_slot: usize = 0;

pub fn setWorkerSlot(slot: usize) void {
    std.debug.assert(slot < MAX_POOL_WORKERS);
    g_worker_slot = slot;
}

pub fn currentWorkerSlot() usize {
    return g_worker_slot;
}

/// Faz X.3, Faz MN.1'de havuz-farkındalıklı hale GENİŞLETİLDİ:
/// `state.arc_owner_pool`u (bkz. onun belge notu) doğrular/kaydeder.
/// **Yalnızca `debug_thread_check` AKTİFKEN GERÇEK bir kontrol yapar** —
/// Release modlarında HER ZAMAN `true` döner (hiçbir maliyet EKLEMEZ,
/// `std.Thread.getCurrentId()` bile ÇAĞRILMAZ). Çağıran iş parçacığı
/// ZATEN KAYITLI bir üyeyse `true` döner; DEĞİLSE VE havuz KAPASİTESİNİN
/// ALTINDAYSA (varsayılan kapasite 1) YENİ üye olarak KAYDEDİP `true`
/// döner; kapasite DOLUYSA `false` döner (İHLAL YAKALANDI). Kapasite 1
/// kaldığı sürece bu, Faz X.3'ün ORİJİNAL "tek sahip" davranışıyla
/// BİREBİR aynıdır. `pub fn` OLARAK (export DEĞİL) dışa açılır ki bu
/// FONKSİYONUN KENDİSİ (bir `std.debug.assert`e SARILMADAN) DOĞRUDAN
/// test edilebilsin — bkz. aşağıdaki "gerçek bir iş parçacığı ihlali
/// YAKALANIR" testi.
pub fn arcOwnerThreadOk(state: *RuntimeState) bool {
    if (!debug_thread_check) return true;
    const current = std.Thread.getCurrentId();
    // Faz MN.4/5.8: `arc_owner_pool_lock` — bkz. onun belge notu, GERÇEK
    // bir kayıp-güncelleme yarışının düzeltmesi.
    state.arc_owner_pool_lock.lock();
    defer state.arc_owner_pool_lock.unlock();
    const pool = &state.arc_owner_pool;
    var i: usize = 0;
    while (i < pool.count) : (i += 1) {
        if (pool.members[i] == current) return true;
    }
    if (pool.count >= pool.capacity) return false;
    pool.members[pool.count] = current;
    pool.count += 1;
    return true;
}

/// Faz MN.1: gelecekteki bir worker havuzunun (bkz. proje planı "Faz
/// MN.3b") `arc_owner_pool` KAPASİTESİNİ YÜKSELTMESİ İçİn — henüz HİÇBİR
/// çağrı sitesi YOK (MN.3b'nin KENDİ Worker soyutlaması BUNU çağıracak),
/// ama tip/API ŞİMDİDEN burada, MN.1 kapsamında hazırlanıyor. Release
/// modlarında hiçbir etkisi YOK (`debug_thread_check` KAPALIYKEN no-op).
pub fn setArcOwnerPoolCapacity(state: *RuntimeState, capacity: usize) void {
    if (!debug_thread_check) return;
    std.debug.assert(capacity <= OwnerPool.MAX_MEMBERS);
    state.arc_owner_pool.capacity = capacity;
}

/// Yeni bir çalışma zamanı bağlamı oluşturur. Başarısızlıkta `null` döner.
pub export fn nox_runtime_init() ?*anyopaque {
    const state = std.heap.page_allocator.create(RuntimeState) catch return null;
    state.* = .{ .debug_gpa = if (use_debug_allocator) .init else {} };
    return @ptrCast(state);
}

/// Çalışma zamanı bağlamını kapatır. Debug modunda `DebugAllocator` bir
/// sızıntı tespit ederse (AGENTS.md §13'ün "leak testi ... yeşil"
/// gereksinimi doğrultusunda) bunu stderr'e açıkça bildirir — programın
/// çıkış kodunu değiştirmez, ama golden testler bu çıktıyı gözlemleyebilir.
/// Release modlarında (bkz. modül üstü not) sızıntı tespiti yapılmaz.
pub export fn nox_runtime_deinit(rt: ?*anyopaque) void {
    const state: *RuntimeState = @ptrCast(@alignCast(rt orelse return));
    // Faz S.3: SON bir kez döngü topla (bkz. `nox_cycle_collect`in belge
    // notu, eşiğe ulaşmamış kısa ömürlü programlar İÇİN), SONRA döngü
    // çözücünün KENDİ yan tablosunu (bkz. `cycle_gc`in belge notu) yok et —
    // o da AYNI `state.allocator()`ı kullanır, `debug_gpa.deinit()`DEN
    // ÖNCE yapılmalı (aksi halde deinit SONRASI bir kullanım-sonrası-
    // serbest-bırakma yazımı olurdu).
    nox_cycle_collect(rt);
    nox_cycle_deinit(rt);
    if (use_debug_allocator) {
        if (state.debug_gpa.deinit() == .leak) {
            std.debug.print("nox runtime: bellek sızıntısı tespit edildi\n", .{});
        }
    }
    std.heap.page_allocator.destroy(state);
}

/// `size` bayt tahsis eder. Başarısızlıkta `null` döner.
pub export fn nox_alloc(rt: ?*anyopaque, size: usize) ?*anyopaque {
    const state: *RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    const mem = state.allocator().alloc(u8, size) catch return null;
    return mem.ptr;
}

/// Daha önce `nox_alloc(rt, size)` ile tahsis edilmiş belleği serbest bırakır.
/// `size`, tahsis anındaki ile birebir aynı olmalıdır (Zig allocator sözleşmesi).
pub export fn nox_free(rt: ?*anyopaque, ptr: ?*anyopaque, size: usize) void {
    const p = ptr orelse return;
    const state: *RuntimeState = @ptrCast(@alignCast(rt orelse return));
    const bytes: [*]u8 = @ptrCast(p);
    state.allocator().free(bytes[0..size]);
}

/// Bulundu (bkz. proje belleği "modül-seviyesi global durum" planı):
/// `RuntimeState.globals_blocks`in erişimcileri — QBE codegen `RuntimeState`in
/// KENDİSİNE (Zig struct'ı, ABI garantisi YOK) DOĞRUDAN bayt-ofseti İLE
/// erişemez (`nox_alloc`/`nox_free`nin AYNI `@ptrCast(@alignCast(...))`
/// deseni HARİÇ HİÇBİR alanına doğrudan erişilmez) — bu YÜZDEN diğer
/// TÜM opak `RuntimeState` alanları (`arena_pool`/`cycle_gc`) GİBİ, BURADA
/// da iki küçük `extern fn` GEREKİR. Asıl bayt-ofseti aritmetiği (HANGİ
/// global HANGİ ofsette) TAMAMEN derleyicinin (compiler/codegen_qbe/
/// globals.zig) KENDİ SORUMLULUĞUDUR — bu fonksiyonlar yalnızca OPAK
/// işaretçiyi taşır, hiçbir yorum yapmaz. Faz MN.3b: `g_worker_slot`e
/// göre dizinin İLGİLİ hücresine erişir — ABI DEĞİŞMEDİ (bkz. `globals_
/// blocks`in KENDİ belge notu).
pub export fn nox_globals_get(rt: ?*anyopaque) ?*anyopaque {
    const state: *RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    return state.globals_blocks[g_worker_slot];
}

pub export fn nox_globals_set(rt: ?*anyopaque, block: ?*anyopaque) void {
    const state: *RuntimeState = @ptrCast(@alignCast(rt orelse return));
    state.globals_blocks[g_worker_slot] = block;
}

test "tahsis edilen bellek yazılabilir/okunabilir ve serbest bırakılabilir" {
    const rt = nox_runtime_init() orelse return error.InitFailed;
    defer nox_runtime_deinit(rt);

    const ptr = nox_alloc(rt, 16) orelse return error.AllocFailed;
    const bytes: [*]u8 = @ptrCast(ptr);
    bytes[0] = 42;
    try std.testing.expectEqual(@as(u8, 42), bytes[0]);
    nox_free(rt, ptr, 16);
}

test "nox_free(null) güvenli bir hiçbir şey yapmama işlemidir" {
    const rt = nox_runtime_init() orelse return error.InitFailed;
    defer nox_runtime_deinit(rt);
    nox_free(rt, null, 0);
}

test "arcOwnerThreadOk: aynı iş parçacığından tekrarlanan çağrılar hep true döner" {
    if (!debug_thread_check) return;
    var state: RuntimeState = .{ .debug_gpa = if (use_debug_allocator) .init else {} };
    defer if (use_debug_allocator) {
        _ = state.debug_gpa.deinit();
    };
    try std.testing.expect(arcOwnerThreadOk(&state));
    try std.testing.expect(arcOwnerThreadOk(&state));
    try std.testing.expect(arcOwnerThreadOk(&state));
}

test "arcOwnerThreadOk: Faz X.3 — gerçek bir farklı-iş-parçacığı ihlali YAKALANIR" {
    // Bu, X.3'ün TÜM amacının SOMUT kanıtıdır: `state.arc_owner_pool` ANA
    // iş parçacığında SABİTLENDİKTEN SONRA, GERÇEKTEN SPAWN edilmiş AYRI
    // bir OS iş parçacığından (`std.Thread.spawn` — sahte/simüle EDİLMEMİŞ)
    // AYNI `state`e yapılan bir çağrı `false` DÖNMELİDİR — `nox_rc_alloc`/
    // `nox_rc_free_payload`nin `std.debug.assert`i tam da BUNU YAKALAR.
    if (!debug_thread_check) return;
    var state: RuntimeState = .{ .debug_gpa = if (use_debug_allocator) .init else {} };
    defer if (use_debug_allocator) {
        _ = state.debug_gpa.deinit();
    };

    try std.testing.expect(arcOwnerThreadOk(&state)); // ana iş parçacığı SAHİP olur

    const Ctx = struct {
        state: *RuntimeState,
        result: bool = undefined,
        fn run(self: *@This()) void {
            self.result = arcOwnerThreadOk(self.state);
        }
    };
    var ctx = Ctx{ .state = &state };
    const t = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    t.join();

    try std.testing.expect(!ctx.result); // FARKLI iş parçacığı — İHLAL doğru YAKALANDI
}
