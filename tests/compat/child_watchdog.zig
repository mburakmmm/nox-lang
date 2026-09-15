const std = @import("std");
const builtin = @import("builtin");

/// Faz TEST.3 (bkz. plan dosyasının "Faz TEST.3" bölümü): `tests/compat/`
/// altındaki HTTP golden testlerinin GERÇEK bir Nox `prog` alt-sürecini
/// spawn edip SONRA `allocRemaining`/`child.wait(io)` İLE (zaman aşımsız)
/// beklediği yerlerde, istemci bağlantısı KURULAMAZSA sunucunun SONSUZA
/// KADAR `accept()`te bloklaması riskini kapatır. `arm()` çağrıldıktan
/// `timeout_ms` SÜRE SONRA `disarm()` ÇAĞRILMAMIŞSA, `child`i HAM PID
/// üzerinden (`std.posix.kill`, `Child` struct'ına HİÇ DOKUNMADAN — İKİ
/// farklı iş parçacığının AYNI `Child` struct'ını eş zamanlı DEĞİŞTİRMESİNİ
/// ÖNLEMEK İçİn BİLİNÇLİ bir tasarım kararı) SIGKILL İLE zorla SONLANDIRIR.
///
/// BU DOSYA HİÇBİR `test` BLOĞU İçERMEMELİDİR — Zig'in test-keşfi bu
/// dosyayı `@import` EDEN HER dosyada `test` bloklarını TEKRAR ÇALIŞTIRIR.
pub const ChildWatchdog = struct {
    done: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,
    active: bool = false,

    pub fn arm(self: *ChildWatchdog, child: *const std.process.Child, timeout_ms: u32) !void {
        // Bu testler Windows CI'de HİÇ ÇALIŞMIYOR (`windows-frontend` işi
        // SADECE `zig build frontend-test` — lexer/parser/checker — çalıştırır,
        // bkz. .github/workflows/ci.yml) — Windows'ta SESSİZCE no-op.
        if (builtin.os.tag == .windows) return;
        self.thread = try std.Thread.spawn(.{}, run, .{ self, child.id.?, timeout_ms });
        self.active = true;
    }

    fn run(self: *ChildWatchdog, pid: std.posix.pid_t, timeout_ms: u32) void {
        const step_ms: i64 = 200;
        var waited: i64 = 0;
        while (waited < timeout_ms) : (waited += step_ms) {
            if (self.done.load(.acquire)) return;
            sleepMs(step_ms);
        }
        if (self.done.load(.acquire)) return;
        std.posix.kill(pid, .KILL) catch {};
    }

    pub fn disarm(self: *ChildWatchdog) void {
        if (!self.active) return;
        self.done.store(true, .release);
        self.thread.join();
    }
};

/// `runtime/async_rt/scheduler.zig`nin `sleepMs`iyle AYNI, KANITLANMIŞ
/// desen — bu Zig sürümünde `std.Thread.sleep` YOK (proje-genelinde
/// ZATEN belgelenmiş bir kısıt).
fn sleepMs(ms: i64) void {
    const ts: std.c.timespec = .{
        .sec = @divTrunc(ms, std.time.ms_per_s),
        .nsec = @mod(ms, std.time.ms_per_s) * std.time.ns_per_ms,
    };
    _ = std.c.nanosleep(&ts, null);
}
