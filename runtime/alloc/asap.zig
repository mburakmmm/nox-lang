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

/// Faz MN.1: `RuntimeState.arc_owner_pool`in DEPOLAMASI — bkz. onun belge
/// notu. `MAX_MEMBERS`, gelecekteki bir worker havuzunun ÜST sınırıdır
/// (dinamik ayırma GEREKTİRMEYECEK kadar KÜÇÜK/sabit); `capacity`,
/// `members`in KAÇ İNDEKSİNİN GEÇERLİ sayılacağını (`MAX_MEMBERS`e KADAR)
/// belirler — varsayılan 1, Faz X.3'ün ORİJİNAL "tek sahip" semantiğidir.
pub const OwnerPool = struct {
    pub const MAX_MEMBERS = 64;
    members: [MAX_MEMBERS]std.Thread.Id = undefined,
    count: usize = 0,
    capacity: usize = 1,
};

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
    pool_free_lists: [POOL_NUM_CLASSES]?*PoolNode = @splat(null),
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
    /// Faz S.3 (Katman 3, döngü çözücü) — `runtime/alloc/cycle_detector.zig`nin
    /// KENDİ `CycleGc` durumuna opak bir işaretçi (tembel/lazy oluşturulur,
    /// bkz. onun `getGc`si). `arena_pool` İLE AYNI gerekçeyle opak: `asap.zig`
    /// `cycle_detector.zig`yi IMPORT ETMEDEN (döngüsel bağımlılık kurmadan)
    /// bu alanı taşıyabilir — gerçek serbest bırakma `nox_cycle_deinit`e
    /// (aşağıdaki `extern fn` bildirimi, DÜZ bağlama — bkz. `runtime/lib.zig`nin
    /// İKİSİNİ de AYNI `noxrt` nesnesine derlediği) DELEGE edilir.
    cycle_gc: ?*anyopaque = null,
    /// Faz X.3, Faz MN.1'de HAVUZ-farkındalıklı hale GENİŞLETİLDİ: bu
    /// `rt`nin ARC (Katman 2, bkz. `runtime/alloc/arc.zig`) işlemlerine
    /// dokunmasına İZİN VERİLEN OS iş parçacıklarının KÜÇÜK bir kümesi
    /// (varsayılan KAPASİTE 1 — Faz X.3'ün ORİJİNAL "tek sahip" semantiğiyle
    /// BİREBİR aynı, aşağıdaki `arcOwnerThreadOk` testleri BUNU KANITLAR).
    /// `nox_rc_alloc`/`nox_rc_free_payload` (aşağıdaki `arcOwnerThreadOk`ya
    /// bkz.) HER çağrıda BUNU doğrular. **Nox'un çalışma zamanı ARC
    /// refcount'u (`arc.zig`nin `i64` başlığı) Faz MN.1'DEN İTİBAREN
    /// KOŞULSUZ atomiktir** (bkz. `arc.zig`nin `nox_rc_retain`/
    /// `nox_rc_predecrement`i) — AMA `pool_free_lists`/`arena_pool`/
    /// `cycle_gc`/`globals_block` (bu struct'ın DİĞER alanları) HÂLÂ
    /// senkronize DEĞİL, bu YÜZDEN bir `RuntimeState`ye GERÇEKTEN birden
    /// fazla worker'ın PARALEL dokunması HÂLÂ GÜVENLİ DEĞİL (bkz. proje
    /// planı "Faz MN.3b" — havuz/arena senkronizasyonu VE paylaşılan-
    /// `RuntimeState` kararı AYRI, HENÜZ uygulanmamış bir faz). Kapasite
    /// varsayılan olarak 1 kaldığı SÜRECE bu alan BUGÜNKÜ "tek sahip"
    /// güvenlik ağını (bkz. `arcOwnerThreadOk`) TAM olarak korur — MN.3b
    /// gerçek bir worker havuzu KURDUĞUNDA `setArcOwnerPoolCapacity` İLE
    /// kapasiteyi havuz büyüklüğüne YÜKSELTİP HER worker'ı KAYITLI bir
    /// üye olarak İŞARETLEYECEKTİR.
    arc_owner_pool: if (debug_thread_check) OwnerPool else void =
        if (debug_thread_check) .{} else {},
    /// Bulundu (bkz. proje belleği "modül-seviyesi global durum" planı):
    /// derleyicinin ürettiği `$nox_init_globals`in `nox_alloc` İLE ayırıp
    /// `nox_globals_set` İLE buraya yazdığı, programa özgü DÜZ bellek
    /// bloğu — üst-düzey (script top-level) `var_decl`ların DEPOLANDIĞI
    /// yer. `arena_pool`/`cycle_gc` İLE AYNI gerekçeyle OPAK: bu dosya
    /// (runtime) HANGİ Nox programının HANGİ global'leri bildirdiğini
    /// HİÇBİR ZAMAN bilmez/yorumlamaz — bayt-düzeni TAMAMEN derleyicinin
    /// (compiler/codegen_qbe/globals.zig) sahip olduğu bir SÖZLEŞMEDİR,
    /// tıpkı bir sınıf örneğinin alan düzeni gibi. Her `RuntimeState`
    /// (bkz. `arc_owner_pool`in belge notu — HER OS iş parçacığı KENDİ
    /// BAĞIMSIZ `RuntimeState`ine sahiptir) KENDİ bağımsız bloğuna
    /// sahiptir — worker'LAR ARASI PAYLAŞIM YOK (bilinçli v1 kapsamı).
    globals_block: ?*anyopaque = null,

    pub fn allocator(self: *RuntimeState) std.mem.Allocator {
        if (use_debug_allocator) return self.debug_gpa.allocator();
        return std.heap.smp_allocator;
    }
};

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
/// `RuntimeState.globals_block`in erişimcileri — QBE codegen `RuntimeState`in
/// KENDİSİNE (Zig struct'ı, ABI garantisi YOK) DOĞRUDAN bayt-ofseti İLE
/// erişemez (`nox_alloc`/`nox_free`nin AYNI `@ptrCast(@alignCast(...))`
/// deseni HARİÇ HİÇBİR alanına doğrudan erişilmez) — bu YÜZDEN diğer
/// TÜM opak `RuntimeState` alanları (`arena_pool`/`cycle_gc`) GİBİ, BURADA
/// da iki küçük `extern fn` GEREKİR. Asıl bayt-ofseti aritmetiği (HANGİ
/// global HANGİ ofsette) TAMAMEN derleyicinin (compiler/codegen_qbe/
/// globals.zig) KENDİ SORUMLULUĞUDUR — bu fonksiyonlar yalnızca OPAK
/// işaretçiyi taşır, hiçbir yorum yapmaz.
pub export fn nox_globals_get(rt: ?*anyopaque) ?*anyopaque {
    const state: *RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    return state.globals_block;
}

pub export fn nox_globals_set(rt: ?*anyopaque, block: ?*anyopaque) void {
    const state: *RuntimeState = @ptrCast(@alignCast(rt orelse return));
    state.globals_block = block;
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
