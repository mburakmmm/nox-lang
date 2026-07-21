//! `ThreadChannel[T]` — Katman 2'nin saf-Zig çekirdeği — Faz BB.5 (bkz.
//! nox-teknik-spesifikasyon.md §3.51). `nox.thread.start`ın (Faz BB.2,
//! `thread_bridge.zig`) paylaşımsız (shared-nothing) modelini KORUYARAK
//! iş parçacıkları ARASINDA GERÇEK, sürekli, çift-yönlü iletişim sağlar
//! — mevcut, sıfır-maliyetli, AYNI-iş-parçacığı `Channel[T]`e (channel.zig,
//! `Scheduler.suspendCurrent`/`markReady` KULLANAN) HİÇ DOKUNMADAN.
//!
//! **Neden `Scheduler.suspendCurrent`/`markReady` KULLANILAMAZ:** o
//! ilkeller TEK bir zamanlayıcının KENDİ hazır kuyruğuna DOĞRUDAN erişir
//! — BAŞKA bir OS iş parçacığındaki bir zamanlayıcının kuyruğuna GÜVENLE
//! DOKUNULAMAZ (kilitsiz, iş-parçacığı-YEREL bir veri yapısıdır). Bunun
//! yerine `nox_thread_join`ın (`thread_bridge.zig`) KENDİSİNİN KULLANDIĞI
//! `Scheduler.suspendForIo`/`io.nonBlockingRead` İKİLİSİ yeniden
//! kullanılır — HER iş parçacığı YALNIZCA KENDİ reaktörüne KAYDOLUR VE
//! YALNIZCA KENDİ `markReady`sini KENDİ iş parçacığından ÇAĞIRIR; DİĞER
//! iş parçacığı YALNIZCA bir OS pipe'ına BAYT YAZAR (`write()`, `PIPE_BUF`
//! altı boyutlar İÇİN POSIX'te ATOMİKTİR, kilitsiz GÜVENLİDİR) — bu, BU
//! dosyanın TEK gerçek "zamanlayıcılar arası" temas noktasıdır.
//!
//! **Simetrik ÇİFT pipe (kullanıcının AskUserQuestion yanıtıyla SEÇİLEN
//! geri basınç modeli):** `recv_wakeup_*` (gönderen→alıcı: "veri var"),
//! `send_wakeup_*` (alıcı→gönderen: "yer açıldı" — tampon DOLUYKEN
//! bloklanmış bir göndericiyi UYANDIRMAK İÇİN). Her İKİ yönde de "reaktör
//! UYANDIRIR, KOŞULU YENİDEN KONTROL ET" deseni (bkz. `io_reactor.zig`nin
//! AYNI belge notu) KULLANILIR — bir pipe'a ERKEN/FAZLADAN yazılan bir
//! bayt asla KAYIP bir uyandırmaya yol AÇMAZ (kernel'in KENDİ pipe
//! arabelleğinde BEKLER, bir SONRAKİ `read()` onu HEMEN YAKALAR), yalnızca
//! zararsız bir ekstra döngü yinelemesine.
//!
//! **`str` transferi — `nox_thread_spawn`ın AYNI "düz baytlarla kopyala,
//! ARC'a hiç dokunma" protokolü:** `send_str`, gönderenin ARC `str`ini
//! SENKRON olarak DÜZ (`page_allocator`) bir NUL-sonlandırılmış arabelleğe
//! KOPYALAR (göndericinin KENDİ referansı `send_str` DÖNER DÖNMEZ GÜVENLE
//! serbest bırakılabilir); tampon İÇİNDE bu düz işaretçi (bit-örtüşmüş bir
//! `i64` payload olarak) taşınır. `recv_str`, ALICININ KENDİ `rt`si
//! ÜZERİNDEN bu baytlardan TAZE bir ARC `str` inşa eder (`http_client.zig`nin
//! `dupeToNoxStr`ı — `thread_bridge.zig` İLE AYNI YENİDEN KULLANIM), düz
//! arabelleği serbest bırakır. `int/float/bool/none/ptr` payload'ları
//! (`_val` varyantları) DOĞRUDAN, dönüşümsüz taşınır — `T`nin `str` OLUP
//! OLMADIĞI ÇAĞRI SİTESİNDE STATİK olarak BİLİNDİĞİNDEN (bkz. codegen'in
//! `Channel[T]`in KENDİ `toPayload`/`fromPayload` erişimiyle TUTARLI
//! statik seçimi), çalışma-zamanı ETİKETİNDEN KAÇINILIR.
//!
//! **Ömür — `ThreadHandle` İLE AYNI atomik referans SAYIMI (bkz.
//! `thread_bridge.zig`nin `ThreadHandle`inin AYNI belge notu):**
//! `ThreadChannel`, TİPİK KULLANIMDA (bir yaratıcı iş parçacığı + `nox.
//! thread.start`ın `arg`ı olarak GEÇİRİLDİĞİ TEK bir çocuk iş parçacığı)
//! TAM OLARAK İKİ tarafça PAYLAŞILIR — `owners` 2'den başlayan GERÇEK bir
//! atomik sayaçtır, `nox_threadchannel_destroy` HER İKİ taraftan da
//! ÇAĞRILIR (kapsam-sonu KOŞULSUZ çağrı, `Task`/`Channel`/`ThreadHandle`
//! İLE AYNI desen), sayaç 0'a düştüğünde struct GERÇEKTEN serbest
//! bırakılır. **Bilinçli v1 sınırlaması:** 3+ tarafça PAYLAŞIM (ör. AYNI
//! kanalın BİRDEN FAZLA `nox.thread.start` çağrısına GEÇİRİLMESİ) checker
//! TARAFINDAN ENGELLENMEZ, AMA `owners` sayacı SADECE 2 İÇİN doğru
//! davranır — bu, `ThreadHandle`nin AYNI sabit-2 varsayımının doğal
//! devamıdır (bkz. §3.50).
//!
//! **Kapasite:** `ThreadChannel[T](capacity)`, AYNI-iş-parçacığı
//! `Channel[T]`nin AKSİNE, `capacity >= 1` GEREKTİRİR (checker TARAFINDAN
//! ZORUNLU KILINACAK, Faz BB.6) — GERÇEK bir el-ele TESLİM (rendezvous,
//! `capacity == 0`) çapraz-iş-parçacığı bağlamda (alıcının TAM O ANDA
//! BEKLEDİĞİNİ üçüncü bir sinyal OLMADAN GÜVENLE bilmenin bir yolu
//! olmadığından) BU turun kapsamı DIŞINDA bırakıldı — `capacity >= 1`
//! basit, kanıtlanabilir doğru bir tampon+çift-pipe modeliyle TAM
//! ihtiyacı KARŞILAR.

const std = @import("std");
const posix = std.posix;
const asap = @import("../alloc/asap.zig");
const bridge = @import("bridge.zig");
const io_mod = @import("io.zig");
const http_client = @import("../stdlib_shims/http_client.zig");
const str_mod = @import("../str.zig");

const dupeToNoxStr = http_client.dupeToNoxStr;

/// `std.Thread.Mutex` bu Zig sürümünde YOK (`std.Io.Mutex`, kilit alma
/// İÇİN bir `Io` arayüzü İSTER — genel amaçlı bir OS-iş-parçacığı
/// kilidi DEĞİL) — `http_client.zig`nin `g_client_io_state`i İÇİN
/// KULLANDIĞI AYNI CAS-tabanlı spin-kilit deseni (bkz. onun belge notu)
/// burada da yeniden kullanılır.
const SpinLock = struct {
    state: std.atomic.Value(u8) = .init(0),

    fn lock(self: *SpinLock) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *SpinLock) void {
        self.state.store(0, .release);
    }
};

pub const ThreadChannel = struct {
    mutex: SpinLock = .{},
    buffer: std.ArrayListUnmanaged(i64) = .empty,
    capacity: usize,
    recv_wakeup_read_fd: posix.fd_t,
    recv_wakeup_write_fd: posix.fd_t,
    send_wakeup_read_fd: posix.fd_t,
    send_wakeup_write_fd: posix.fd_t,
    /// Bkz. modül üstü not — `ThreadHandle.owners` İLE AYNI GEREKÇE/desen.
    owners: std.atomic.Value(u32) = .init(2),

    fn release(self: *ThreadChannel) void {
        if (self.owners.fetchSub(1, .acq_rel) == 1) {
            http_client.closeFd(self.recv_wakeup_read_fd);
            http_client.closeFd(self.recv_wakeup_write_fd);
            http_client.closeFd(self.send_wakeup_read_fd);
            http_client.closeFd(self.send_wakeup_write_fd);
            self.buffer.deinit(std.heap.page_allocator);
            std.heap.page_allocator.destroy(self);
        }
    }
};

/// `fd` üzerinde TEK bir bayt gelene kadar bekler — bir Nox FİBER
/// İÇİNDEYSEK (`bridge.currentFiberScheduler`) D.0'ın reaktörü ÜZERİNDEN
/// askıya alınır (BAŞKA fiber'lar bu SIRADA GERÇEKTEN ilerleyebilir),
/// DEĞİLSE sıradan bloklayan bir `read()` YETERLİDİR — `nox_thread_join`
/// İLE AYNI iki-modlu desen.
fn waitForByte(fd: posix.fd_t) void {
    var buf: [1]u8 = undefined;
    if (bridge.currentFiberScheduler()) |scheduler| {
        _ = io_mod.nonBlockingRead(scheduler, fd, &buf) catch {};
    } else {
        http_client.readSelfPipe(fd, &buf);
    }
}

fn signalByte(fd: posix.fd_t) void {
    http_client.signalSelfPipe(fd);
}

fn ptrToPayload(ptr: anytype) i64 {
    return @bitCast(@as(isize, @intCast(@intFromPtr(ptr))));
}

fn payloadToPlainCStr(payload: i64) [*:0]u8 {
    return @ptrFromInt(@as(usize, @bitCast(payload)));
}

/// Gönderenin baytlarını DÜZ (ARC-dışı) bir NUL-sonlandırılmış arabelleğe
/// kopyalar — bkz. modül üstü not, "str transferi".
fn dupeToPlainCStr(bytes: []const u8) [*:0]u8 {
    const buf = std.heap.page_allocator.alloc(u8, bytes.len + 1) catch @panic("OOM: ThreadChannel str klonu");
    @memcpy(buf[0..bytes.len], bytes);
    buf[bytes.len] = 0;
    return @ptrCast(buf.ptr);
}

fn freePlainCStr(ptr: [*:0]u8) void {
    const len = std.mem.len(ptr);
    std.heap.page_allocator.free(ptr[0 .. len + 1]);
}

/// Tampon `capacity`ye ULAŞMIŞSA — kilit BIRAKILARAK `send_wakeup_read_fd`
/// üzerinde beklenir (alıcı bir öğe TÜKETTİĞİNDE `send_wakeup_write_fd`e
/// yazar), UYANINCA kilit TEKRAR ALINIP KOŞUL YENİDEN KONTROL EDİLİR
/// (klasik "reaktör uyandırır, yeniden dene" — bkz. modül üstü not). Yer
/// AÇILINCA payload İTİLİR, `recv_wakeup_write_fd`e BİR bayt yazılarak
/// (varsa) bekleyen bir alıcı UYANDIRILIR.
fn sendPayload(tc: *ThreadChannel, payload: i64) void {
    tc.mutex.lock();
    while (tc.buffer.items.len >= tc.capacity) {
        tc.mutex.unlock();
        waitForByte(tc.send_wakeup_read_fd);
        tc.mutex.lock();
    }
    tc.buffer.append(std.heap.page_allocator, payload) catch @panic("OOM: ThreadChannel tamponu");
    tc.mutex.unlock();
    signalByte(tc.recv_wakeup_write_fd);
}

/// `sendPayload` İLE SİMETRİK — tampon BOŞSA `recv_wakeup_read_fd`
/// üzerinde beklenir, UYANINCA TEKRAR DENENİR. Bir öğe ÇIKARILINCA
/// `send_wakeup_write_fd`e BİR bayt yazılarak (varsa) bekleyen bir
/// gönderici UYANDIRILIR.
fn recvPayload(tc: *ThreadChannel) i64 {
    tc.mutex.lock();
    while (tc.buffer.items.len == 0) {
        tc.mutex.unlock();
        waitForByte(tc.recv_wakeup_read_fd);
        tc.mutex.lock();
    }
    const value = tc.buffer.orderedRemove(0);
    tc.mutex.unlock();
    signalByte(tc.send_wakeup_write_fd);
    return value;
}

/// `capacity < 1` İSE `null` döner (bkz. modül üstü not, "kapasite") —
/// codegen/checker BUNU zaten ENGELLER (Faz BB.6), BURASI savunmacı bir
/// ikinci katmandır.
export fn nox_threadchannel_new(rt: ?*anyopaque, capacity: i64) callconv(.c) ?*anyopaque {
    _ = rt;
    if (capacity < 1) return null;

    const recv_fds = http_client.makeSelfPipe() orelse return null;
    const send_fds = http_client.makeSelfPipe() orelse {
        http_client.closeFd(recv_fds[0]);
        http_client.closeFd(recv_fds[1]);
        return null;
    };

    const tc = std.heap.page_allocator.create(ThreadChannel) catch {
        http_client.closeFd(recv_fds[0]);
        http_client.closeFd(recv_fds[1]);
        http_client.closeFd(send_fds[0]);
        http_client.closeFd(send_fds[1]);
        return null;
    };
    tc.* = .{
        .capacity = @intCast(capacity),
        .recv_wakeup_read_fd = recv_fds[0],
        .recv_wakeup_write_fd = recv_fds[1],
        .send_wakeup_read_fd = send_fds[0],
        .send_wakeup_write_fd = send_fds[1],
    };
    return tc;
}

export fn nox_threadchannel_send_val(rt: ?*anyopaque, handle: ?*anyopaque, payload: i64) callconv(.c) void {
    _ = rt;
    const tc: *ThreadChannel = @ptrCast(@alignCast(handle.?));
    sendPayload(tc, payload);
}

export fn nox_threadchannel_recv_val(rt: ?*anyopaque, handle: ?*anyopaque) callconv(.c) i64 {
    _ = rt;
    const tc: *ThreadChannel = @ptrCast(@alignCast(handle.?));
    return recvPayload(tc);
}

export fn nox_threadchannel_send_str(rt: ?*anyopaque, handle: ?*anyopaque, payload: i64) callconv(.c) void {
    _ = rt;
    const tc: *ThreadChannel = @ptrCast(@alignCast(handle.?));
    const src = payloadToPlainCStr(payload);
    const plain = dupeToPlainCStr(std.mem.span(src));
    sendPayload(tc, ptrToPayload(plain));
}

export fn nox_threadchannel_recv_str(rt: ?*anyopaque, handle: ?*anyopaque) callconv(.c) i64 {
    const tc: *ThreadChannel = @ptrCast(@alignCast(handle.?));
    const payload = recvPayload(tc);
    const ptr = payloadToPlainCStr(payload);
    const cloned = dupeToNoxStr(rt, std.mem.span(ptr)) orelse @panic("OOM: ThreadChannel str alim klonu");
    freePlainCStr(ptr);
    return ptrToPayload(cloned);
}

/// `ThreadChannel`i (bkz. `ThreadHandle.owners` İLE AYNI atomik referans
/// SAYIMI) serbest bırakır — codegen, `ThreadChannel[T]` tipli bir yerel
/// değişkenin kapsam sonunda KOŞULSUZ çağırır (Faz BB.6).
export fn nox_threadchannel_destroy(rt: ?*anyopaque, handle: ?*anyopaque) callconv(.c) void {
    _ = rt;
    const tc: *ThreadChannel = @ptrCast(@alignCast(handle orelse return));
    tc.release();
}

test "nox_threadchannel: iki gerçek OS iş parçacığı arasında N değer gönderilir/alınır (tamponlu)" {
    const tc = nox_threadchannel_new(null, 4).?;
    defer nox_threadchannel_destroy(null, tc);

    const Fn = struct {
        fn sender(arg: *anyopaque) void {
            const c: *anyopaque = arg;
            var i: i64 = 0;
            while (i < 100) : (i += 1) {
                nox_threadchannel_send_val(null, c, i);
            }
        }
    };

    const t = std.Thread.spawn(.{}, Fn.sender, .{tc}) catch @panic("thread spawn basarisiz");

    var i: i64 = 0;
    while (i < 100) : (i += 1) {
        const v = nox_threadchannel_recv_val(null, tc);
        try std.testing.expectEqual(i, v);
    }
    t.join();
}

test "nox_threadchannel: kapasite-sinirli tampon, gonderen dolu tamponda GERÇEKTEN bekler, alici bosaltinca uyanir" {
    const tc = nox_threadchannel_new(null, 2).?;
    defer nox_threadchannel_destroy(null, tc);

    var sent_all = std.atomic.Value(bool).init(false);
    const SenderArgs = struct { c: *anyopaque, flag: *std.atomic.Value(bool) };
    const Fn = struct {
        fn sender(args: SenderArgs) void {
            var i: i64 = 0;
            while (i < 10) : (i += 1) {
                nox_threadchannel_send_val(null, args.c, i);
            }
            args.flag.store(true, .release);
        }
    };
    const t = std.Thread.spawn(.{}, Fn.sender, .{SenderArgs{ .c = tc, .flag = &sent_all }}) catch @panic("thread spawn basarisiz");

    // Gönderici SADECE 2 (kapasite) öğe iterken, biz HENÜZ hiç `recv`
    // ÇAĞIRMADIK — kısa bir gerçek bekleyişten SONRA göndericinin TÜMÜNÜ
    // GÖNDEREMEMİŞ (bloklanmış) OLMASI GEREKİR, aksi halde tampon geri
    // basıncı ÇALIŞMIYOR demektir.
    var waited_ms: i64 = 0;
    while (waited_ms < 200 and !sent_all.load(.acquire)) : (waited_ms += 5) {
        const ts: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    try std.testing.expect(!sent_all.load(.acquire));

    var i: i64 = 0;
    while (i < 10) : (i += 1) {
        const v = nox_threadchannel_recv_val(null, tc);
        try std.testing.expectEqual(i, v);
    }
    t.join();
    try std.testing.expect(sent_all.load(.acquire));
}

test "nox_threadchannel: str payload, iki BAĞIMSIZ RuntimeState arasinda, sizinti yok" {
    const parent_rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(parent_rt);

    const tc = nox_threadchannel_new(null, 4).?;
    defer nox_threadchannel_destroy(null, tc);

    const Fn = struct {
        fn sender(c: *anyopaque) void {
            const child_rt = asap.nox_runtime_init() orelse @panic("child RuntimeState baslatilamadi");
            defer asap.nox_runtime_deinit(child_rt);

            const names = [_][*:0]const u8{ "bir", "iki", "üç" };
            for (names) |n| {
                const s = str_mod.nox_str_concat(child_rt, n, "") orelse @panic("concat basarisiz");
                defer str_mod.nox_str_release(child_rt, s);
                nox_threadchannel_send_str(child_rt, c, ptrToPayload(s));
            }
        }
    };
    const t = std.Thread.spawn(.{}, Fn.sender, .{tc}) catch @panic("thread spawn basarisiz");

    const expected = [_][]const u8{ "bir", "iki", "üç" };
    for (expected) |exp| {
        const payload = nox_threadchannel_recv_str(parent_rt, tc);
        const got: [*:0]u8 = @ptrFromInt(@as(usize, @bitCast(payload)));
        defer str_mod.nox_str_release(parent_rt, got);
        try std.testing.expectEqualStrings(exp, std.mem.span(got));
    }
    t.join();
}
