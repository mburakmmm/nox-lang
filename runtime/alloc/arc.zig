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

/// `payload_size` baytlık bir nesne + görünmez 8 baytlık refcount başlığı
/// tahsis eder; refcount 1 ile başlar. Döndürülen işaretçi PAYLOAD'ın
/// başlangıcıdır. Başarısızlıkta `null` döner. Release modunda önce havuzdan
/// (bkz. modül üstü not) karşılamayı dener; havuz boşsa (ya da nesne
/// havuzlanamayacak kadar büyükse) genel ayırıcıdan TAM SINIF BÜYÜKLÜĞÜNDE
/// (istenenden fazla olabilir — bu blok daha sonra AYNI sınıfa geri
/// dönecektir) bir blok alır.
pub export fn nox_rc_alloc(rt: ?*anyopaque, payload_size: usize) ?*anyopaque {
    // Faz X.3 (bkz. `asap.RuntimeState.arc_owner_tid`nin belge notu):
    // Debug modunda BU rt'nin ARC işlemlerine dokunan iş parçacığının
    // HER ZAMAN AYNI olduğunu doğrular — ihlal EDİLİRSE burada, gerçek
    // bir data-race'e İLERLEMEDEN, KESİN bir panikle DURUR.
    if (rt) |r| std.debug.assert(asap.arcOwnerThreadOk(@ptrCast(@alignCast(r))));
    const total = payload_size + HEADER_SIZE;
    if (use_pool) {
        if (poolClassIndex(total)) |idx| {
            const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
            const base: *anyopaque = blk: {
                if (state.pool_free_lists[idx]) |node| {
                    state.pool_free_lists[idx] = node.next;
                    break :blk @ptrCast(node);
                }
                break :blk asap.nox_alloc(rt, poolClassSize(idx)) orelse return null;
            };
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
pub export fn nox_rc_retain(ptr: ?*anyopaque) void {
    const p = ptr orelse return;
    const rc = refcountOf(p);
    rc.* += 1;
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
    const rc = refcountOf(p);
    rc.* -= 1;
    return if (rc.* <= 0) 1 else 0;
}

/// `nox_rc_predecrement` 1 döndürdükten SONRA belleği (başlık dahil) gerçekten
/// serbest bırakır. `payload_size`, `nox_rc_alloc`'a verilenle birebir aynı
/// olmalıdır. Release modunda (bkz. modül üstü not) "serbest bırakmak"
/// GENEL ayırıcıya gitmek DEĞİL, bloğu KENDİ büyüklük sınıfının serbest
/// listesine eklemektir — `total_size` `nox_rc_alloc`daki İLE AYNI sınıfa
/// deterministik olarak eşleneceğinden (aynı boyut her zaman aynı sınıf),
/// bu blok yalnızca AYNI sınıftan bir sonraki tahsiste güvenle geri
/// dönüştürülür.
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
            node.* = .{ .next = state.pool_free_lists[idx] };
            state.pool_free_lists[idx] = node;
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
