//! `nox.signal` — işlem sinyallerine (SIGINT/SIGTERM/SIGHUP/SIGUSR1/SIGUSR2) abonelik (Ember NL-008).
//!
//! Sinyal işleyicisi YALNIZCA async-signal-safe tek bir iş yapar: sinyale ait atomik bayrağı kurar. Nox kodu bayrağı kendi iş parçacığında/fiber'ında `take`/`pending`/`wait`
//! ile okur; işleyicide hiçbir Nox kodu çalışmaz (durum değişikliği zamanlayıcıya olay olarak taşınır, işleyicide DEĞİL). `nox.http`in kendi SIGTERM/SIGINT işleyicisi varsa
//! (`serve*` başlarken kurulur) son kuran kazanır; ikisini birlikte kullanmayın.
//! Windows, wasm ve freestanding'de `install` 0 döner (sinyal yok); `take`/`pending` hep 0 verir.

const std = @import("std");
const builtin = @import("builtin");

const supported = switch (builtin.os.tag) {
    .windows, .freestanding, .wasi, .other => false,
    else => !builtin.cpu.arch.isWasm(),
};

const is_win = builtin.os.tag == .windows;

// WASM host iptali (2.3 madde 3.9): `wasm32-freestanding --asyncify`da host, modülün `nox_host_signal(sig)` dışa aktarımını çağırarak SIGINT (2) / SIGTERM (15) / SIGHUP (1) iletir; yeni bir
// `nox_host` import'u yoktur. Sinyal yalnızca `install` edilmişse bayrağı kurar (kurulu değilse 0 döner: host varsayılan davranışı uygular). `wait`in uykusu host zamanlayıcısıyla askıya alınır
// (`CAP_TIMER`), böylece JS olay döngüsü çalışır ve sinyal gelebilir.
const wasm_options = if (builtin.cpu.arch.isWasm()) @import("wasm_options") else struct {
    pub const asyncify = false;
};
const wasm_sig = builtin.cpu.arch.isWasm() and builtin.os.tag == .freestanding and wasm_options.asyncify;
const sig_fetch = if (wasm_sig) @import("http_fetch.zig") else struct {};
var g_wasm_installed: [MAX_SIG]bool = [_]bool{false} ** MAX_SIG;

const WasmHostExports = if (wasm_sig) struct {
    /// Host sinyal iletir. Dönüş: 1 = modül `install` etmişti ve bayrak kuruldu; 0 = kurulu değil (host varsayılan davranışı uygular, ör. süreci sonlandırır).
    export fn nox_host_signal(sig: i32) callconv(.c) i32 {
        if (sig <= 0 or sig >= MAX_SIG) return 0;
        const n: usize = @intCast(sig);
        if (!g_wasm_installed[n]) return 0;
        g_flags[n].store(true, .release);
        return 1;
    }
} else struct {};

comptime {
    _ = WasmHostExports;
}

// Windows (v2.2.2, Ember NX-004): POSIX sinyali yoktur ama KONSOL OLAYLARI vardır; `SIGINT`/`SIGTERM`/`SIGHUP` (C `signal.h` numaraları 2/15/1) bunlara eşlenir:
// Ctrl+C → SIGINT, Ctrl+Break ve konsol kapatma/oturum kapatma/kapanış olayları → SIGTERM. `SIGUSR1`/`SIGUSR2` Windows'ta yoktur (0). `raise`, işleyici kurulu sinyal için bayrağı doğrudan kurar
// (`send_self` testleri ve "kendi kendini durdur" kalıbı çalışır). Konsol yoksa (hizmet/arka plan) olay gelmez; Windows HİZMET durdurma (SCM) bu soyutlamanın dışındadır.
const WIN_SIGINT: usize = 2;
const WIN_SIGTERM: usize = 15;
const WIN_SIGHUP: usize = 1;
var g_win_installed: [MAX_SIG]std.atomic.Value(bool) = [_]std.atomic.Value(bool){.init(false)} ** MAX_SIG;
var g_win_handler_registered: std.atomic.Value(bool) = .init(false);
const win_k32 = if (is_win) struct {
    extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (u32) callconv(.winapi) i32, add: i32) callconv(.winapi) i32;
} else struct {};

fn winCtrlHandler(ctrl: u32) callconv(.winapi) i32 {
    // 0 CTRL_C, 1 CTRL_BREAK, 2 CTRL_CLOSE, 5 CTRL_LOGOFF, 6 CTRL_SHUTDOWN
    const sig: usize = switch (ctrl) {
        0 => WIN_SIGINT,
        1, 2, 5, 6 => WIN_SIGTERM,
        else => return 0,
    };
    if (!g_win_installed[sig].load(.acquire)) return 0; // kurulu değil: varsayılan davranış (süreç sonlanır)
    g_flags[sig].store(true, .release);
    return 1;
}

const MAX_SIG = 32;
var g_flags: [MAX_SIG]std.atomic.Value(bool) = [_]std.atomic.Value(bool){.init(false)} ** MAX_SIG;

fn onSignal(sig: std.posix.SIG) callconv(.c) void {
    const n: usize = @intCast(@intFromEnum(sig));
    if (n < MAX_SIG) g_flags[n].store(true, .release);
}

// Windows hizmeti (SCM) kapanışı (2.3 madde 3.9): `service_run(name)` ayrı bir Zig iş parçacığında `StartServiceCtrlDispatcherW` çağırır; Nox kodu SCM'in iş parçacıklarında HİÇ çalışmaz.
// SCM `STOP`/`SHUTDOWN` komutu SIGTERM bayrağını kurar (`wait(sigterm)`/`take(sigterm)` ile alınır); program işini bitirince `service_stopped(kod)` ile `SERVICE_STOPPED` bildirir. Konsoldan/hizmet olmadan
// çalıştırılırsa dağıtıcı başarısız olur (hata 1063) ve `service_run` `0` döner: program normal devam eder. Yalnızca Windows; diğer hedeflerde `0`.
const win_svc = if (is_win) struct {
    const SERVICE_WIN32_OWN_PROCESS: u32 = 0x10;
    const SERVICE_START_PENDING: u32 = 2;
    const SERVICE_STOP_PENDING: u32 = 3;
    const SERVICE_RUNNING: u32 = 4;
    const SERVICE_STOPPED: u32 = 1;
    const SERVICE_ACCEPT_STOP: u32 = 1;
    const SERVICE_ACCEPT_SHUTDOWN: u32 = 4;
    const SERVICE_CONTROL_STOP: u32 = 1;
    const SERVICE_CONTROL_INTERROGATE: u32 = 4;
    const SERVICE_CONTROL_SHUTDOWN: u32 = 5;
    const ERROR_CALL_NOT_IMPLEMENTED: u32 = 120;
    const ERROR_SERVICE_SPECIFIC_ERROR: u32 = 1066;

    const Status = extern struct {
        service_type: u32 = SERVICE_WIN32_OWN_PROCESS,
        current_state: u32 = SERVICE_START_PENDING,
        controls_accepted: u32 = 0,
        win32_exit_code: u32 = 0,
        service_specific_exit_code: u32 = 0,
        check_point: u32 = 0,
        wait_hint: u32 = 0,
    };
    const TableEntry = extern struct { name: ?[*:0]u16, proc: ?*const fn (u32, ?[*]?[*:0]u16) callconv(.winapi) void };

    extern "advapi32" fn StartServiceCtrlDispatcherW(table: [*]const TableEntry) callconv(.winapi) i32;
    extern "advapi32" fn RegisterServiceCtrlHandlerExW(name: [*:0]const u16, handler: *const fn (u32, u32, ?*anyopaque, ?*anyopaque) callconv(.winapi) u32, ctx: ?*anyopaque) callconv(.winapi) usize;
    extern "advapi32" fn SetServiceStatus(handle: usize, status: *const Status) callconv(.winapi) i32;
    extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

    /// 0 yok, 1 bağlanıyor, 2 çalışıyor (SCM bağlandı), 3 bağlanamadı (hizmet olarak başlatılmamış), 4 durduruldu bildirildi.
    var state: std.atomic.Value(u32) = .init(0);
    var handle: usize = 0;
    var name_w: [256:0]u16 = [_:0]u16{0} ** 256;
    var status: Status = .{};
    var status_lock: std.atomic.Value(bool) = .init(false);

    fn setStatus(st: *Status) void {
        while (status_lock.swap(true, .acquire)) std.Thread.yield() catch {};
        defer status_lock.store(false, .release);
        if (handle != 0) _ = SetServiceStatus(handle, st);
    }

    fn handlerEx(control: u32, _: u32, _: ?*anyopaque, _: ?*anyopaque) callconv(.winapi) u32 {
        switch (control) {
            SERVICE_CONTROL_STOP, SERVICE_CONTROL_SHUTDOWN => {
                // `g_win_installed[15]` `service_run`da kurulu: bayrak `take`/`wait` ile alınır.
                g_flags[WIN_SIGTERM].store(true, .release);
                status.current_state = SERVICE_STOP_PENDING;
                status.controls_accepted = 0;
                status.check_point += 1;
                status.wait_hint = 30000;
                setStatus(&status);
                return 0;
            },
            SERVICE_CONTROL_INTERROGATE => {
                setStatus(&status);
                return 0;
            },
            else => return ERROR_CALL_NOT_IMPLEMENTED,
        }
    }

    fn serviceMain(_: u32, _: ?[*]?[*:0]u16) callconv(.winapi) void {
        handle = RegisterServiceCtrlHandlerExW(&name_w, handlerEx, null);
        if (handle == 0) {
            state.store(3, .release);
            return;
        }
        status.current_state = SERVICE_RUNNING;
        status.controls_accepted = SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN;
        setStatus(&status);
        state.store(2, .release);
        // Hizmet durdurulduğu bildirilene kadar bu iş parçacığı bekler (ServiceMain dönünce SCM hizmeti sonlandırılmış sayar).
        while (state.load(.acquire) != 4) Sleep(50);
    }

    fn dispatcher() void {
        const table = [_]TableEntry{ .{ .name = &name_w, .proc = &serviceMain }, .{ .name = null, .proc = null } };
        if (StartServiceCtrlDispatcherW(&table) == 0) state.store(3, .release);
    }

    fn run(name: []const u8) i64 {
        if (state.load(.acquire) != 0) return if (state.load(.acquire) == 2) 1 else 0;
        const n = std.unicode.utf8ToUtf16Le(name_w[0..255], name) catch return 0;
        name_w[n] = 0;
        // Bir hizmet SIGTERM ile durdurulur; kurulu işaretlenir ki `STOP` bayrağı kurabilsin.
        g_win_installed[WIN_SIGTERM].store(true, .release);
        state.store(1, .release);
        const t = std.Thread.spawn(.{}, dispatcher, .{}) catch {
            state.store(3, .release);
            return 0;
        };
        t.detach();
        var waited: u32 = 0;
        while (state.load(.acquire) == 1 and waited < 10000) : (waited += 10) Sleep(10);
        return if (state.load(.acquire) == 2) 1 else 0;
    }

    fn stopped(code: i64) void {
        if (state.load(.acquire) != 2) return;
        status.current_state = SERVICE_STOPPED;
        status.controls_accepted = 0;
        status.wait_hint = 0;
        if (code != 0) {
            status.win32_exit_code = ERROR_SERVICE_SPECIFIC_ERROR;
            status.service_specific_exit_code = @intCast(@as(u64, @bitCast(code)) & 0xffffffff);
        }
        setStatus(&status);
        state.store(4, .release);
        // ServiceMain'in dönmesine ve dağıtıcının çıkmasına kısa süre tanı (süreç hemen çıkarsa SCM yine de durumu görmüştür).
        Sleep(100);
    }
} else struct {};

/// Windows hizmeti olarak başlatıldıysa SCM'e bağlanır (1), aksi halde 0 (konsol, diğer hedefler).
pub export fn nox_signal_service_run_raw(name: ?[*:0]const u8) i64 {
    if (comptime !is_win) return 0;
    const n = name orelse return 0;
    return win_svc.run(std.mem.span(n));
}

/// Hizmet durumunu `SERVICE_STOPPED` bildirir (`code != 0` ise hizmete özgü çıkış kodu). Hizmet değilse etkisizdir.
pub export fn nox_signal_service_stopped_raw(code: i64) void {
    if (comptime !is_win) return;
    win_svc.stopped(code);
}

fn validSig(sig: i64) ?usize {
    if (sig <= 0 or sig >= MAX_SIG) return null;
    return @intCast(sig);
}

/// `which`: 0 = SIGINT, 1 = SIGTERM, 2 = SIGHUP, 3 = SIGUSR1, 4 = SIGUSR2 → platformun sinyal numarası; desteklenmiyorsa 0.
pub export fn nox_signal_number_raw(which: i64) i64 {
    if (comptime wasm_sig) return switch (which) {
        0 => 2,
        1 => 15,
        2 => 1,
        else => 0,
    };
    if (comptime is_win) return switch (which) {
        0 => WIN_SIGINT,
        1 => WIN_SIGTERM,
        2 => WIN_SIGHUP,
        else => 0,
    };
    if (comptime !supported) return 0;
    return switch (which) {
        0 => @intFromEnum(std.posix.SIG.INT),
        1 => @intFromEnum(std.posix.SIG.TERM),
        2 => @intFromEnum(std.posix.SIG.HUP),
        3 => @intFromEnum(std.posix.SIG.USR1),
        4 => @intFromEnum(std.posix.SIG.USR2),
        else => 0,
    };
}

/// Sinyali bayrak-kuran işleyiciye bağlar. Başarılıysa 1.
pub export fn nox_signal_install_raw(sig: i64) i32 {
    if (comptime wasm_sig) {
        const n = validSig(sig) orelse return 0;
        if (n != 1 and n != 2 and n != 15) return 0;
        g_wasm_installed[n] = true;
        return 1;
    }
    if (comptime is_win) {
        const n = validSig(sig) orelse return 0;
        if (n != WIN_SIGINT and n != WIN_SIGTERM and n != WIN_SIGHUP) return 0;
        if (!g_win_handler_registered.swap(true, .acq_rel)) {
            if (win_k32.SetConsoleCtrlHandler(winCtrlHandler, 1) == 0) {
                g_win_handler_registered.store(false, .release);
                return 0;
            }
        }
        // SIGHUP için ayrı bir konsol olayı yok (SIGTERM'e eşlenir): kurulum kabul edilir ama bayrağı yalnızca `raise` kurar.
        g_win_installed[n].store(true, .release);
        return 1;
    }
    if (comptime !supported) return 0;
    const n = validSig(sig) orelse return 0;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(@enumFromInt(n), &act, null);
    return 1;
}

/// `wait`in uykusu: wasm32-freestanding --asyncify ve host zamanlayıcısı (`CAP_TIMER`) varsa program `ms` boyunca host'a askıya alınır (JS olay döngüsü sinyal iletebilir) ve 1 döner;
/// aksi halde (yerel hedefler, eski host) 0 döner ve çağıran normal uykuya düşer.
pub export fn nox_signal_host_sleep_raw(ms: i64) i64 {
    if (comptime !wasm_sig) return 0;
    if (!sig_fetch.timerAvailable()) return 0;
    const req = sig_fetch.submit(.{ .kind = .sleep, .timeout_ms = if (ms < 1) 1 else ms }, false) orelse return 0;
    const resp = sig_fetch.waitFor(req) orelse return 0;
    sig_fetch.responseFree(resp);
    return 1;
}

/// Bayrak kurulu mu? (Tüketmez.)
pub export fn nox_signal_pending_raw(sig: i64) i32 {
    const n = validSig(sig) orelse return 0;
    return if (g_flags[n].load(.acquire)) 1 else 0;
}

/// Bayrağı oku ve temizle: sinyal gelmişse 1 (bir sonraki çağrı yeni bir sinyale kadar 0).
pub export fn nox_signal_take_raw(sig: i64) i32 {
    const n = validSig(sig) orelse return 0;
    return if (g_flags[n].swap(false, .acq_rel)) 1 else 0;
}

/// Bu sürece `sig` sinyalini gönderir (testler ve kendi kendini durdurma için). Başarılıysa 1.
pub export fn nox_signal_raise_raw(sig: i64) i32 {
    if (comptime wasm_sig) {
        const n = validSig(sig) orelse return 0;
        if (!g_wasm_installed[n]) return 0;
        g_flags[n].store(true, .release);
        return 1;
    }
    if (comptime is_win) {
        const n = validSig(sig) orelse return 0;
        if (!g_win_installed[n].load(.acquire)) return 0;
        g_flags[n].store(true, .release);
        return 1;
    }
    if (comptime !supported) return 0;
    const n = validSig(sig) orelse return 0;
    // Yük altında (çok sayıda süreç, 1/1500) `raise` başarısız dönüp sinyali HİÇ göndermiyordu (`send_self` False, ardından `wait` zaman aşımı): geçici hatalar (EAGAIN/EINTR vb.) için
    // kısa aralıklarla yeniden denenir; sonra süreç-yönlendirmeli `kill(getpid())` yedeği.
    var attempt: usize = 0;
    while (attempt < 50) : (attempt += 1) {
        if (std.c.raise(@enumFromInt(n)) == 0) return 1;
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 200 * std.time.ns_per_us };
        _ = std.c.nanosleep(&ts, null);
    }
    return if (std.c.kill(std.c.getpid(), @enumFromInt(n)) == 0) 1 else 0;
}

test "nox_signal: install + raise bayrağı kurar, take temizler" {
    if (comptime !supported) return error.SkipZigTest;
    const usr1 = nox_signal_number_raw(3);
    try std.testing.expect(usr1 > 0);
    try std.testing.expectEqual(@as(i32, 0), nox_signal_take_raw(usr1));
    try std.testing.expectEqual(@as(i32, 1), nox_signal_install_raw(usr1));
    try std.testing.expectEqual(@as(i32, 1), nox_signal_raise_raw(usr1));
    try std.testing.expectEqual(@as(i32, 1), nox_signal_pending_raw(usr1));
    try std.testing.expectEqual(@as(i32, 1), nox_signal_take_raw(usr1));
    try std.testing.expectEqual(@as(i32, 0), nox_signal_pending_raw(usr1));
    try std.testing.expectEqual(@as(i32, 0), nox_signal_install_raw(0));
}
