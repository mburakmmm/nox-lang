const std = @import("std");
const builtin = @import("builtin");

/// Faz TEST.3 (bkz. plan dosyasının "Faz TEST.3" bölümü): `tests/compat/`
/// altındaki HTTP golden testlerinin GERÇEK bir Nox `prog` alt-sürecini
/// spawn edip SONRA `allocRemaining`/`child.wait(io)` İLE (zaman aşımsız)
/// beklediği yerlerde, istemci bağlantısı KURULAMAZSA sunucunun SONSUZA
/// KADAR `accept()`te bloklaması riskini kapatır. `arm()` çağrıldıktan
/// `timeout_ms` SÜRE SONRA `disarm()` ÇAĞRILMAMIŞSA süreç zorla kapanır.
///
/// `Child.id` POSIX'te pid, Windows'ta süreç tutamacıdır (`std.process.
/// Child.Id`). POSIX `SIGKILL`, Windows `NtTerminateProcess` kullanır.
/// `Child` struct'ına HİÇ DOKUNULMAZ — iki iş parçacığı aynı struct'ı
/// değiştirmesin diye.
///
/// BU DOSYA HİÇBİR `test` BLOĞU İÇERMEMELİDİR — Zig'in test-keşfi bu
/// dosyayı `@import` EDEN HER dosyada `test` bloklarını TEKRAR ÇALIŞTIRIR.
pub const ChildWatchdog = struct {
    done: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,
    active: bool = false,

    pub fn arm(self: *ChildWatchdog, child: *const std.process.Child, timeout_ms: u32) !void {
        const id = child.id orelse return error.ProcessNotRunning;
        self.thread = try std.Thread.spawn(.{}, run, .{ self, id, timeout_ms });
        self.active = true;
    }

    fn run(self: *ChildWatchdog, id: std.process.Child.Id, timeout_ms: u32) void {
        const step_ms: u32 = 200;
        var waited: u32 = 0;
        while (waited < timeout_ms) : (waited += step_ms) {
            if (self.done.load(.acquire)) return;
            sleepMs(step_ms);
        }
        if (self.done.load(.acquire)) return;
        switch (builtin.os.tag) {
            .windows => _ = std.os.windows.ntdll.NtTerminateProcess(id, 1),
            else => std.posix.kill(id, .KILL) catch {},
        }
    }

    pub fn disarm(self: *ChildWatchdog) void {
        if (!self.active) return;
        self.done.store(true, .release);
        self.thread.join();
    }
};

const WinSleep = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.c) void;
} else struct {};

/// `runtime/async_rt/scheduler.zig`nin `sleepMs`iyle AYNI, KANITLANMIŞ
/// desen — bu Zig sürümünde `std.Thread.sleep` YOK (proje-genelinde
/// ZATEN belgelenmiş bir kısıt). Windows'ta `nanosleep` yoktur.
fn sleepMs(ms: u32) void {
    switch (builtin.os.tag) {
        .windows => WinSleep.Sleep(ms),
        else => {
            const ts: std.c.timespec = .{
                .sec = ms / std.time.ms_per_s,
                .nsec = (ms % std.time.ms_per_s) * std.time.ns_per_ms,
            };
            _ = std.c.nanosleep(&ts, null);
        },
    }
}
