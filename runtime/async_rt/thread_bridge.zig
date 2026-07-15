//! `nox.thread` Katman 1'in saf-Zig çekirdeği — Faz BB.2 (bkz. nox-teknik-
//! spesifikasyon.md §3.48). Gerçek bir YENİ OS iş parçacığı başlatır, o
//! iş parçacığında TAMAMEN BAĞIMSIZ bir `RuntimeState`/`Scheduler`
//! kurar, kullanıcının `entry`ini o iş parçacığının TEK üst-düzey görevi
//! olarak çalıştırır — `$main`in KENDİ `nox_runtime_init→nox_os_init→
//! nox_async_init→spawn($main_body)→run_to_completion→yıkım` dizisinin
//! (bkz. `codegen.zig`nin `genMainAsync`ı) BİREBİR aynı yapısı, tek farkla:
//! `nox_os_init` TEKRAR ÇAĞRILMAZ (argv süreç geneli, bir kez yeter).
//!
//! **Paylaşımsız (shared-nothing) protokol — argüman/sonuç GEÇİŞİ:**
//! `int/float/bool/none/ptr` payload'ları DOĞRUDAN (ARC-dışı, 8 baytlık
//! bit-örtüşmesi) taşınır. `str` payload'ları İSE `http_client.zig`nin
//! GERÇEK OS iş parçacığı İÇİN ZATEN AUDIT EDİLMİŞ desenini İZLER:
//! ebeveyn `nox_thread_spawn`da SENKRON olarak (çocuk iş parçacığı DAHİ
//! BAŞLAMADAN ÖNCE) baytları DÜZ (ARC-dışı, `std.heap.page_allocator`)
//! bir hazırlık arabelleğine KOPYALAR — bu, ebeveynin ORİJİNAL `str`
//! referansının `nox_thread_spawn` DÖNER DÖNMEZ serbest bırakılabilmesini
//! GÜVENLİ kılar (çocuk ASLA ebeveynin ARC belleğine DOKUNMAZ). Çocuk,
//! KENDİ `RuntimeState`i kurulduktan SONRA bu düz baytlardan TAZE bir ARC
//! `str` inşa eder. SONUÇ İÇİN (str dönerse) TAM SİMETRİK protokol: çocuk
//! KENDİ ARC `str`ini düz baytlara KOPYALAR, KENDİ referansını serbest
//! bırakır, TÜM `RuntimeState`ini YIKAR — ebeveyn `nox_thread_join`da bu
//! düz baytlardan KENDİ ARC `str`ini inşa eder.
//!
//! **`ThreadHandle`nin ömrü — atomik referans SAYIMI (Task'ın `detached`
//! deseninden BİLİNÇLİ olarak FARKLI):** `Task.detached` (bkz. `scheduler.
//! zig`) TEK bir OS iş parçacığında kooperatif ÇALIŞTIĞI İÇİN güvenlidir
//! (gerçek bir veri yarışı YOK). `ThreadHandle` İSE GERÇEKTEN İKİ bağımsız
//! OS iş parçacığı arasında paylaşılır — ebeveyn (`nox_thread_destroy`)
//! VE çocuk (kendi işini bitirince) HER İKİSİ de `handle`e "sahip"tir,
//! HANGİSİNİN SIRAYLA biteceği BELİRSİZDİR. Bu yüzden `owners` GERÇEK bir
//! atomik sayaçtır (2'den başlar) — her taraf işini bitirince BİR azaltır,
//! sayaç 0'a düştüğünde (hangi taraf SON düşürürse O) struct GERÇEKTEN
//! serbest bırakılır. `ThreadHandle`nin KENDİSİ (VE `ChildCtx`/hazırlık
//! arabellekleri) BİLİNÇLİ olarak `std.heap.page_allocator` üzerinden
//! tahsis edilir — `rt`nin (`RuntimeState`) ARC ayırıcısı DEĞİL: `rt`nin
//! ayırıcısı BİR iş parçacığına AİT olma VARSAYIMINI TAŞIR (bkz. Faz X.3'ün
//! `arc_owner_tid`ı) — `page_allocator` İSE (Zig'in DOĞRUDAN OS `mmap`
//! sarmalayıcısı) doğası GEREĞİ iş-parçacığı-BAĞIMSIZDIR, bu yüzden
//! `ThreadHandle`nin İKİ taraftan da GÜVENLE serbest bırakılabilmesi İÇİN
//! DOĞRU seçimdir (`rt`nin Debug-modu `DebugAllocator`ı VARSAYILAN olarak
//! `thread_safe = true` olsa BİLE — bkz. Zig std kaynağı — BU dosya
//! BİLİNÇLİ olarak `rt`nin ayırıcısına GÜVENMEZ, ÇÜNKÜ paylaşımsız model
//! bir `RuntimeState`in TEK bir iş parçacığına AİT OLMA prensibini
//! (mimari düzeyde, salt bellek-güvenliği düzeyinde DEĞİL) korumalıdır).

const std = @import("std");
const posix = std.posix;
const asap = @import("../alloc/asap.zig");
const bridge = @import("bridge.zig");
const io_mod = @import("io.zig");
const http_client = @import("../stdlib_shims/http_client.zig");
const str_mod = @import("../str.zig");

const dupeToNoxStr = http_client.dupeToNoxStr;

/// `nox_thread_spawn`ın `entry`ye geçtiği paket — `rt` (çocuğun TAZE
/// `RuntimeState`i) + tek argümanın (zaten gerekiyorsa ARC'a KLONLANMIŞ)
/// payload'ı. Faz BB.4'ün codegen'i, `genSpawnWrapper`in AYNI desenindeki
/// bir sarmalayıcı üretip BU şekli (`%rt =l loadl %argp` İLK adımı) TÜKETİR
/// — bu dosyanın testleri, o sarmalayıcının YERİNE GEÇEN düz Zig
/// fonksiyonları yazarak AYNI sözleşmeyi egzersiz eder.
const ThreadEntryClosure = struct {
    rt: ?*anyopaque,
    payload: i64,
};

const ChildCtx = struct {
    entry: *const fn (*anyopaque) callconv(.c) i64,
    arg_payload: i64,
    /// `null` DEĞİLSE, ebeveynin SENKRON olarak KOPYALADIĞI düz (ARC-dışı)
    /// argüman baytları — çocuk KENDİ `RuntimeState`i kurulduktan SONRA
    /// BUNLARDAN taze bir ARC `str` inşa edip bu arabelleği serbest bırakır.
    arg_is_str_bytes: ?[]u8,
    result_is_str: bool,
    handle: *ThreadHandle,
};

pub const ThreadHandle = struct {
    done_read_fd: posix.fd_t,
    done_write_fd: posix.fd_t,
    result: i64 = 0,
    /// `null` DEĞİLSE, çocuğun SİMETRİK protokolle KOPYALADIĞI düz sonuç
    /// baytları — `nox_thread_join` bunlardan TAZE bir ARC `str` inşa edip
    /// bu alanı `null`a çevirir (`release`in son temizliğinin ÇİFT
    /// serbest bırakmaması İÇİN).
    result_is_str_bytes: ?[]u8 = null,
    /// Bkz. modül üstü not: `Task.detached`den FARKLI olarak GERÇEK bir
    /// atomik sayaç — ebeveyn (`nox_thread_destroy`) VE çocuk (işini
    /// bitirince) HER İKİSİ de BİR azaltır, 0'a düşüren taraf struct'ı
    /// GERÇEKTEN serbest bırakır (hangi taraf ÖNCE/SONRA biterse bitsin
    /// güvenli — klasik atomik referans sayımı).
    owners: std.atomic.Value(u32) = .init(2),
    /// Yalnızca EBEVEYN tarafından (join/destroy, HER ZAMAN AYNI OS iş
    /// parçacığında, SIRAYLA — birbirleriyle GERÇEKTEN eşzamanlı DEĞİL)
    /// dokunulur — atomik OLMASINA GEREK YOK.
    read_fd_closed: bool = false,

    fn release(self: *ThreadHandle) void {
        if (self.owners.fetchSub(1, .acq_rel) == 1) {
            if (!self.read_fd_closed) _ = std.c.close(self.done_read_fd);
            if (self.result_is_str_bytes) |bytes| std.heap.page_allocator.free(bytes);
            std.heap.page_allocator.destroy(self);
        }
    }
};

/// `runtime/stdlib_shims/time.zig`nin `nox_time_sleep_ms_raw`ıyla AYNI
/// düz `nanosleep` deseni — bu Zig sürümünde `std.Thread.sleep` YOK, TEST
/// kodunun KENDİ senkronizasyon/zamanlama ihtiyacı İÇİN (özellik KODU
/// DEĞİL).
fn sleepMs(ms: i64) void {
    const ts: std.c.timespec = .{
        .sec = @divTrunc(ms, std.time.ms_per_s),
        .nsec = @mod(ms, std.time.ms_per_s) * std.time.ns_per_ms,
    };
    _ = std.c.nanosleep(&ts, null);
}

fn payloadToStrPtr(payload: i64) [*:0]const u8 {
    return @ptrFromInt(@as(usize, @bitCast(payload)));
}

fn strPtrToPayload(ptr: [*:0]const u8) i64 {
    return @bitCast(@as(isize, @intCast(@intFromPtr(ptr))));
}

fn childThreadMain(ctx: *ChildCtx) void {
    defer std.heap.page_allocator.destroy(ctx);

    const child_rt = asap.nox_runtime_init() orelse @panic("nox.thread: RuntimeState baslatilamadi");
    bridge.nox_async_init(child_rt);

    const closure = std.heap.page_allocator.create(ThreadEntryClosure) catch @panic("OOM: nox.thread closure");
    defer std.heap.page_allocator.destroy(closure);
    closure.rt = child_rt;
    if (ctx.arg_is_str_bytes) |bytes| {
        const cloned = dupeToNoxStr(child_rt, bytes) orelse @panic("OOM: nox.thread arg klonu");
        std.heap.page_allocator.free(bytes);
        closure.payload = strPtrToPayload(cloned);
    } else {
        closure.payload = ctx.arg_payload;
    }

    const task = bridge.nox_async_spawn(child_rt, ctx.entry, closure).?;
    _ = bridge.nox_async_run_to_completion(child_rt);
    const result_payload = bridge.nox_async_await(child_rt, task);
    bridge.nox_async_destroy_task(child_rt, task);

    if (ctx.result_is_str) {
        const result_ptr = payloadToStrPtr(result_payload);
        const bytes_copy = std.heap.page_allocator.dupe(u8, std.mem.span(result_ptr)) catch @panic("OOM: nox.thread sonuc hazirligi");
        str_mod.nox_str_release(child_rt, @constCast(result_ptr));
        ctx.handle.result_is_str_bytes = bytes_copy;
    } else {
        ctx.handle.result = result_payload;
    }

    // Çocuğun TÜM ARC heap'i, tamamlanma sinyalinden ÖNCE TAMAMEN YIKILIR —
    // bu noktadan SONRA hiçbir çapraz-iş-parçacığı ARC erişimi MÜMKÜN
    // DEĞİLDİR (bkz. modül üstü not).
    bridge.nox_async_deinit(child_rt);
    asap.nox_runtime_deinit(child_rt);

    var signal_byte = [_]u8{1};
    _ = std.c.write(ctx.handle.done_write_fd, &signal_byte, 1);
    _ = std.c.close(ctx.handle.done_write_fd);

    ctx.handle.release();
}

/// Gerçek bir YENİ OS iş parçacığı başlatır — `entry`, `str_payload`
/// baytları GÜVENLE KOPYALANDIKTAN SONRA (çocuk iş parçacığı DAHİ
/// BAŞLAMADAN ÖNCE) döner, bu yüzden `arg_payload`ın (str İSE) orijinal
/// ARC referansı ÇAĞIRAN TARAFÇA HEMEN serbest BIRAKILABİLİR.
/// `arg_is_str`/`result_is_str`: 0/1 (C ABI — codegen'de STATİK olarak
/// bilinen tipten TÜRETİLİR, bkz. Faz BB.4).
export fn nox_thread_spawn(
    rt: ?*anyopaque,
    entry: *const fn (*anyopaque) callconv(.c) i64,
    arg_payload: i64,
    arg_is_str: i32,
    result_is_str: i32,
) callconv(.c) ?*anyopaque {
    _ = rt; // Bilinçli olarak KULLANILMAZ — bkz. modül üstü not, `ThreadHandle`
    // `page_allocator` üzerinden tahsis edilir, `rt`ye BAĞIMLI DEĞİLDİR.

    var fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return null;

    var arg_bytes: ?[]u8 = null;
    if (arg_is_str != 0) {
        const src = payloadToStrPtr(arg_payload);
        arg_bytes = std.heap.page_allocator.dupe(u8, std.mem.span(src)) catch {
            _ = std.c.close(fds[0]);
            _ = std.c.close(fds[1]);
            return null;
        };
    }

    const handle = std.heap.page_allocator.create(ThreadHandle) catch {
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
        return null;
    };
    handle.* = .{ .done_read_fd = fds[0], .done_write_fd = fds[1] };

    const ctx = std.heap.page_allocator.create(ChildCtx) catch {
        std.heap.page_allocator.destroy(handle);
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
        return null;
    };
    ctx.* = .{
        .entry = entry,
        .arg_payload = arg_payload,
        .arg_is_str_bytes = arg_bytes,
        .result_is_str = result_is_str != 0,
        .handle = handle,
    };

    const thread = std.Thread.spawn(.{}, childThreadMain, .{ctx}) catch {
        std.heap.page_allocator.destroy(ctx);
        std.heap.page_allocator.destroy(handle);
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
        return null;
    };
    thread.detach();

    return handle;
}

/// Çocuk iş parçacığı TAMAMLANANA kadar bekler — `http_client.zig`nin
/// `doRequest`ıyla AYNI iki-modlu desen: bir Nox FİBER İÇİNDEYSEK
/// (`bridge.currentFiberScheduler`), D.0'ın reaktörü ÜZERİNDEN askıya
/// alınır (BAŞKA fiber'lar bu SIRADA GERÇEKTEN ilerleyebilir); fiber
/// DIŞINDAYSAK sıradan bloklayan bir `read()` YETERLİDİR. Sonucu döner —
/// `str` İSE (statik olarak `result_is_str` ile İŞARETLENMİŞ çağrı
/// sitelerinde) `rt` üzerinden TAZE bir ARC `str` inşa EDİLİR.
export fn nox_thread_join(rt: ?*anyopaque, handle: ?*anyopaque) callconv(.c) i64 {
    const h: *ThreadHandle = @ptrCast(@alignCast(handle orelse return 0));

    if (bridge.currentFiberScheduler()) |scheduler| {
        var buf: [1]u8 = undefined;
        _ = io_mod.nonBlockingRead(scheduler, h.done_read_fd, &buf) catch {};
    } else {
        var buf: [1]u8 = undefined;
        _ = std.c.read(h.done_read_fd, &buf, 1);
    }
    if (!h.read_fd_closed) {
        _ = std.c.close(h.done_read_fd);
        h.read_fd_closed = true;
    }

    if (h.result_is_str_bytes) |bytes| {
        h.result_is_str_bytes = null;
        defer std.heap.page_allocator.free(bytes);
        const cloned = dupeToNoxStr(rt, bytes) orelse return 0;
        return strPtrToPayload(cloned);
    }
    return h.result;
}

/// `ThreadHandle`i (bkz. onun belge notu, atomik referans SAYIMI) serbest
/// bırakır — codegen, `ThreadHandle[T]` tipli bir yerel değişkenin kapsam
/// sonunda ÇAĞIRIR (`nox_async_destroy_task`in AYNI koşulsuz-çağrı
/// deseni — `join()` ÇAĞRILMIŞ olsun ya da OLMASIN HER ZAMAN çağrılır).
export fn nox_thread_destroy(rt: ?*anyopaque, handle: ?*anyopaque) callconv(.c) void {
    _ = rt;
    const h: *ThreadHandle = @ptrCast(@alignCast(handle orelse return));
    h.release();
}

// ---- Birim testleri (Faz BB.2) -----------------------------------------

test "nox_thread_spawn/join: int payload uctan uca" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const Entry = struct {
        fn double(arg: *anyopaque) callconv(.c) i64 {
            const closure: *ThreadEntryClosure = @ptrCast(@alignCast(arg));
            return closure.payload * 2;
        }
    };

    const handle = nox_thread_spawn(rt, Entry.double, 21, 0, 0).?;
    const result = nox_thread_join(rt, handle);
    nox_thread_destroy(rt, handle);

    try std.testing.expectEqual(@as(i64, 42), result);
}

test "nox_thread_spawn/join: str payload, ebeveynin orijinal str'i HEMEN serbest bırakılabilir (sızıntı/UAF yok)" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const Entry = struct {
        fn greet(arg: *anyopaque) callconv(.c) i64 {
            const closure: *ThreadEntryClosure = @ptrCast(@alignCast(arg));
            const arg_str = payloadToStrPtr(closure.payload);
            const name = std.mem.span(arg_str);
            var buf: [64]u8 = undefined;
            const greeting = std.fmt.bufPrint(&buf, "merhaba, {s}!", .{name}) catch unreachable;
            const out = dupeToNoxStr(closure.rt, greeting).?;
            // Gerçek Nox codegen'inde bir parametrenin kapsam-sonu
            // release'inin KARŞILIĞI — `entry`nin ALDIĞI klonlanmış `str`
            // argümanı BURADA (kullanıldıktan SONRA) serbest bırakılmalıdır,
            // aksi halde her `nox.thread.spawn` çağrısı argüman str'ini
            // KALICI olarak sızdırır.
            str_mod.nox_str_release(closure.rt, @constCast(arg_str));
            return strPtrToPayload(out);
        }
    };

    const original = dupeToNoxStr(rt, "nox").?;
    const payload = strPtrToPayload(original);

    const handle = nox_thread_spawn(rt, Entry.greet, payload, 1, 1).?;
    // Ebeveynin orijinal referansı HEMEN serbest bırakılır — `nox_thread_spawn`
    // baytları SENKRON olarak KOPYALADIKTAN SONRA döndüğünden GÜVENLİDİR.
    str_mod.nox_str_release(rt, original);

    const result_payload = nox_thread_join(rt, handle);
    nox_thread_destroy(rt, handle);

    const result_ptr = payloadToStrPtr(result_payload);
    try std.testing.expectEqualStrings("merhaba, nox!", std.mem.span(result_ptr));
    str_mod.nox_str_release(rt, @constCast(result_ptr));
}

test "nox_thread_spawn: entry KENDİ nox_async_spawn'ını kullanabilir (tam işlevsel bağımsız zamanlayıcı)" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const Entry = struct {
        fn increment(arg: *anyopaque) callconv(.c) i64 {
            const x: *i64 = @ptrCast(@alignCast(arg));
            return x.* + 1;
        }
        fn outer(arg: *anyopaque) callconv(.c) i64 {
            const closure: *ThreadEntryClosure = @ptrCast(@alignCast(arg));
            var input: i64 = closure.payload;
            const task = bridge.nox_async_spawn(closure.rt, increment, &input).?;
            const result = bridge.nox_async_await(closure.rt, task);
            bridge.nox_async_destroy_task(closure.rt, task);
            return result * 10;
        }
    };

    const handle = nox_thread_spawn(rt, Entry.outer, 4, 0, 0).?;
    const result = nox_thread_join(rt, handle);
    nox_thread_destroy(rt, handle);

    try std.testing.expectEqual(@as(i64, 50), result);
}

test "nox_thread_destroy: çocuk henüz bitmeden çağrılırsa sızmadan/UAF'siz kendi kendini temizler" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const Done = struct {
        var flag: std.atomic.Value(bool) = .init(false);
    };
    Done.flag.store(false, .release);

    const Entry = struct {
        fn slowish(arg: *anyopaque) callconv(.c) i64 {
            const closure: *ThreadEntryClosure = @ptrCast(@alignCast(arg));
            sleepMs(20);
            const r = closure.payload * 2;
            Done.flag.store(true, .release);
            return r;
        }
    };

    const handle = nox_thread_spawn(rt, Entry.slowish, 7, 0, 0).?;
    // `join()` HİÇ çağrılmadan doğrudan `destroy` — "fire and forget".
    nox_thread_destroy(rt, handle);

    // Çocuğun GERÇEKTEN bitmesini bekle (testin KENDİSİNİN temiz çıkması
    // için) — asıl doğrulama `std.testing.allocator`/`page_allocator`ın
    // (bkz. `DebugAllocator`ın süreç geneli izlemesi) sızıntı/çift-serbest-
    // bırakma raporu vermemesidir, bu bekleme yalnızca test-sonu senkronizasyonu.
    var waited: usize = 0;
    while (!Done.flag.load(.acquire) and waited < 200) : (waited += 1) {
        sleepMs(5);
    }
    try std.testing.expect(Done.flag.load(.acquire));
    // Çocuğun `release()`i (owners 2->1->0 sırasının SON adımı) ile
    // `ThreadHandle`i GERÇEKTEN serbest bırakması İÇİN kısa bir ek pay.
    sleepMs(20);
}
