//! v3 sertleştirme yol haritası, madde 6 (bkz. nox-teknik-spesifikasyon.md
//! ilgili bölüm) — "Concurrency Torture Suite 2": `concurrency_torture_
//! test.zig`nin (v1.100.0, seed-tabanlı/deterministik) AYNI ALTYAPI
//! deseniyle (`masterPrngFromEnv`/`nextSeed`/`ChildWatchdog`/`absPath`),
//! AMA Suite 1'in HİÇ EGZERSİZ ETMEDİĞİ üç eşzamanlılık İLKELİNİ hedefler:
//!
//! 1. **`ThreadChannel[T]`** (`nox.thread.thread.nox`nin "Katman 2"si) —
//!    GERÇEK, AYRI bir OS iş parçacığıyla (`nox.thread.start`) çift-yönlü
//!    kanal iletişimi. Suite 1 SADECE `spawn`/`await`/`Task[T]` KULLANIYOR,
//!    `nox.thread.start`/`ThreadChannel[T]` (MN.9.1'in çapraz-worker
//!    güvenli SpinLock'lu tamponu) HİÇ EGZERSİZ EDİLMEMİŞTİ.
//! 2. **`Channel[T]`** (AYNI paylaşılan havuz İçİNDE, `spawn` İLE üretici/
//!    tüketici) — Suite 1'in TÜM görevleri BİRBİRİNDEN TAMAMEN bağımsız
//!    (paylaşılan durum YOK); bu Suite, GERÇEKTEN paylaşılan bir `Channel[T]`
//!    tamponunun ÇAPRAZ-worker doğruluğunu (work-stealing ALTINDA BİLE)
//!    sınar.
//! 3. **`list[T]` transfer'i `spawn` SINIRI ÜZERİNDEN** (`--release`-SINIRLI,
//!    `isThreadTransferSafeType`nin GENİŞLETİLMİŞ kümesi, MN.9.2) — Suite
//!    1'in TÜM argümanları `int`/`str` (retain/release-farkındalı kapanış
//!    paketleme YOK); bu Suite `list[int]`in `spawn` sınırını GERÇEKTEN
//!    (retain/release İLE) geçtiğini sınar.
//!
//! Suite 1 İLE AYNI İKİ kritik tasarım kısıtı GEÇERLİDİR (bkz. o dosyanın
//! belge notu): TÜM rastgele kararlar `entry()`de, spawn'DAN ÖNCE, SIRALI
//! alınır (`nox.random`'ın fiber-başına PRNG'si YÜZÜNDEN); `nox.thread.
//! start`ın worker'ı TEK bir argüman ALABİLDİĞİNDEN (bkz. `err_thread_
//! start_param_count.nox`), `ThreadChannel` üreticisi (`producer_tc`)
//! SABİT bir modül-seviyesi `TC_N` KULLANIR — Suite 1'in `param`
//! rastgeleliği SADECE `Channel[T]`/`list[T]` yollarına uygulanır.

const std = @import("std");
const child_watchdog = @import("child_watchdog.zig");

fn tortureSeedCountFromEnv(default_count: u32) u32 {
    const v = std.c.getenv("NOX_TORTURE2_SEED_COUNT") orelse return default_count;
    return std.fmt.parseInt(u32, std.mem.span(v), 10) catch default_count;
}

fn tortureTaskCountFromEnv(default_tasks: u32) u32 {
    const v = std.c.getenv("NOX_TORTURE2_TASKS") orelse return default_tasks;
    return std.fmt.parseInt(u32, std.mem.span(v), 10) catch default_tasks;
}

/// `concurrency_torture_test.zig`nin `masterPrngFromEnv`iyle AYNI desen —
/// KASITLI olarak AYRI bir env değişkeni adı (`NOX_TORTURE2_MASTER_SEED`)
/// KULLANIR, bu YÜZDEN İKİ suite BİRBİRİNİN meta-koşu seed'ini ETKİLEMEZ.
fn masterPrngFromEnv() ?std.Random.DefaultPrng {
    const v = std.c.getenv("NOX_TORTURE2_MASTER_SEED") orelse return null;
    const s = std.fmt.parseInt(u64, std.mem.span(v), 10) catch return null;
    return std.Random.DefaultPrng.init(s);
}

fn nextSeed(master: *?std.Random.DefaultPrng) i64 {
    if (master.*) |*p| return @bitCast(p.random().int(u64));
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const raw: i64 = ts.sec *% 1_000_000_000 +% ts.nsec;
    return @mod(raw, std.math.maxInt(i64));
}

fn absPath(io: std.Io, dir: std.Io.Dir, buf: []u8) ![]const u8 {
    const len = try dir.realPath(io, buf);
    return buf[0..len];
}

const torture2_source =
    \\import nox.random
    \\import nox.os
    \\import nox.thread
    \\
    \\TC_N: int = 20
    \\
    \\async def producer_tc(tc: ThreadChannel[int]) -> None:
    \\    i: int = 0
    \\    while i < TC_N:
    \\        await tc.send(i)
    \\        i = i + 1
    \\
    \\async def producer_ch(ch: Channel[int], n: int) -> None:
    \\    i: int = 0
    \\    while i < n:
    \\        await ch.send(i)
    \\        i = i + 1
    \\
    \\async def sum_list(xs: list[int]) -> int:
    \\    total: int = 0
    \\    i: int = 0
    \\    while i < len(xs):
    \\        total = total + xs[i]
    \\        i = i + 1
    \\    return total
    \\
    \\async def entry() -> None:
    \\    seed: int = int(nox.os.arg(1))
    \\    task_count: int = int(nox.os.arg(2))
    \\    nox.random.seed(seed)
    \\
    \\    kinds: list[int] = []
    \\    params: list[int] = []
    \\    i: int = 0
    \\    while i < task_count:
    \\        kinds.append(nox.random.randint(0, 2))
    \\        params.append(nox.random.randint(1, 50))
    \\        i = i + 1
    \\
    \\    completed: int = 0
    \\    j: int = 0
    \\    while j < task_count:
    \\        kind: int = kinds[j]
    \\        n: int = params[j]
    \\        if kind == 0:
    \\            tc: ThreadChannel[int] = ThreadChannel[int](2)
    \\            h: ThreadHandle[None] = nox.thread.start(producer_tc, tc)
    \\            total: int = 0
    \\            k: int = 0
    \\            while k < TC_N:
    \\                v: int = await tc.recv()
    \\                total = total + v
    \\                k = k + 1
    \\            await h.join()
    \\            expected: int = 0
    \\            ek: int = 0
    \\            while ek < TC_N:
    \\                expected = expected + ek
    \\                ek = ek + 1
    \\            if total == expected:
    \\                completed = completed + 1
    \\        elif kind == 1:
    \\            ch: Channel[int] = Channel[int](2)
    \\            p: Task[None] = spawn producer_ch(ch, n)
    \\            total2: int = 0
    \\            m: int = 0
    \\            while m < n:
    \\                v2: int = await ch.recv()
    \\                total2 = total2 + v2
    \\                m = m + 1
    \\            await p
    \\            expected2: int = 0
    \\            em: int = 0
    \\            while em < n:
    \\                expected2 = expected2 + em
    \\                em = em + 1
    \\            if total2 == expected2:
    \\                completed = completed + 1
    \\        else:
    \\            xs: list[int] = []
    \\            k2: int = 0
    \\            while k2 < n:
    \\                xs.append(k2)
    \\                k2 = k2 + 1
    \\            t: Task[int] = spawn sum_list(xs)
    \\            total3: int = await t
    \\            expected3: int = 0
    \\            ek3: int = 0
    \\            while ek3 < n:
    \\                expected3 = expected3 + ek3
    \\                ek3 = ek3 + 1
    \\            if total3 == expected3:
    \\                completed = completed + 1
    \\        j = j + 1
    \\
    \\    print("TORTURE2_OK " + str(seed) + " " + str(task_count) + " " + str(completed))
    \\
    \\nox.thread.pool_run(8, entry)
    \\
;

fn compileTortureBinary(gpa: std.mem.Allocator, io: std.Io, nox_path: []const u8, bin_path: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = nox_path, .data = torture2_source });
    const compile_result = try std.process.run(gpa, io, .{
        .argv = &.{ "zig-out/bin/noxc", "build", "--release", nox_path, "-o", bin_path },
    });
    defer gpa.free(compile_result.stdout);
    defer gpa.free(compile_result.stderr);
    if (compile_result.term != .exited or compile_result.term.exited != 0) {
        std.debug.print("concurrency-torture2: derleme basarisiz: {s}\n", .{compile_result.stderr});
        return error.CompileFailed;
    }
}

test "concurrency torture 2: ThreadChannel/Channel/list-transfer seed-tabanlı stres" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const seed_count = tortureSeedCountFromEnv(3);
    const task_count = tortureTaskCountFromEnv(300);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = try absPath(io, tmp.dir, &dir_buf);
    const nox_path = try std.fmt.allocPrint(gpa, "{s}/torture2.nox", .{dir_path});
    defer gpa.free(nox_path);
    const bin_path = try std.fmt.allocPrint(gpa, "{s}/torture2", .{dir_path});
    defer gpa.free(bin_path);

    try compileTortureBinary(gpa, io, nox_path, bin_path);

    var master = masterPrngFromEnv();
    var round: u32 = 0;
    while (round < seed_count) : (round += 1) {
        const seed = nextSeed(&master);
        var seed_buf: [32]u8 = undefined;
        var task_buf: [16]u8 = undefined;
        const seed_arg = try std.fmt.bufPrint(&seed_buf, "{d}", .{seed});
        const task_arg = try std.fmt.bufPrint(&task_buf, "{d}", .{task_count});

        var child = try std.process.spawn(io, .{
            .argv = &.{ bin_path, seed_arg, task_arg },
            .stdout = .pipe,
            .stderr = .pipe,
        });

        var watchdog: child_watchdog.ChildWatchdog = .{};
        try watchdog.arm(&child, 45_000);
        defer watchdog.disarm();

        var stdout_buf: [4096]u8 = undefined;
        var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
        const stdout_data = try stdout_reader.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(stdout_data);

        var stderr_buf: [4096]u8 = undefined;
        var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
        const stderr_data = try stderr_reader.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(stderr_data);

        const term = try child.wait(io);

        if (term != .exited or term.exited != 0 or std.mem.indexOf(u8, stdout_data, "TORTURE2_OK") == null or stderr_data.len != 0) {
            std.debug.print(
                "TORTURE2 REPRO: seed={d} task_count={d} (elle tekrar: '{s}' '{d}' '{d}')\nterm={any}\nstdout:\n{s}\nstderr:\n{s}\n",
                .{ seed, task_count, bin_path, seed, task_count, term, stdout_data, stderr_data },
            );
        }
        try std.testing.expect(term == .exited);
        try std.testing.expectEqual(@as(u8, 0), term.exited);
        try std.testing.expect(std.mem.indexOf(u8, stdout_data, "TORTURE2_OK") != null);
        try std.testing.expectEqual(@as(usize, 0), stderr_data.len);

        // `completed` HER ZAMAN `task_count`e EŞİT OLMALI — bu suite'te
        // (Suite 1'in AKSİNE, `cancel`/`except` YOK) HER görev BAŞARIYLA
        // TAMAMLANIP BEKLENEN toplamı ÜRETMELİDİR; herhangi bir çapraz-
        // worker veri bozulması (`Channel`/`ThreadChannel`nin YANLIŞ
        // teslim ETMESİ, `list[T]` transferinin retain/release'i BOZMASI)
        // `total`in `expected`den SAPMASINA, dolayısıyla `completed <
        // task_count`e yol AÇARDI.
        const ok_prefix = "TORTURE2_OK ";
        const idx = std.mem.indexOf(u8, stdout_data, ok_prefix).?;
        var it = std.mem.splitScalar(u8, stdout_data[idx + ok_prefix.len ..], ' ');
        _ = it.next(); // seed
        _ = it.next(); // task_count
        const completed_str = std.mem.trim(u8, it.next() orelse "", " \r\n");
        const completed = try std.fmt.parseInt(u32, completed_str, 10);
        try std.testing.expectEqual(task_count, completed);
    }
}

// Determinizm kanıtı — `concurrency_torture_test.zig`nin AYNI madde 3
// doğrulamasının BU suite İçİn TEKRARI.
test "concurrency torture 2: aynı seed iki kez BİREBİR aynı sonucu üretir (determinizm kanıtı)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const task_count = tortureTaskCountFromEnv(80);
    const fixed_seed: i64 = 987654321;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = try absPath(io, tmp.dir, &dir_buf);
    const nox_path = try std.fmt.allocPrint(gpa, "{s}/torture2_det.nox", .{dir_path});
    defer gpa.free(nox_path);
    const bin_path = try std.fmt.allocPrint(gpa, "{s}/torture2_det", .{dir_path});
    defer gpa.free(bin_path);

    try compileTortureBinary(gpa, io, nox_path, bin_path);

    var outputs: [2][]const u8 = undefined;
    defer for (outputs) |o| gpa.free(o);

    for (0..2) |i| {
        var seed_buf: [32]u8 = undefined;
        var task_buf: [16]u8 = undefined;
        const seed_arg = try std.fmt.bufPrint(&seed_buf, "{d}", .{fixed_seed});
        const task_arg = try std.fmt.bufPrint(&task_buf, "{d}", .{task_count});

        var child = try std.process.spawn(io, .{
            .argv = &.{ bin_path, seed_arg, task_arg },
            .stdout = .pipe,
            .stderr = .pipe,
        });

        var watchdog: child_watchdog.ChildWatchdog = .{};
        try watchdog.arm(&child, 45_000);
        defer watchdog.disarm();

        var stdout_buf: [4096]u8 = undefined;
        var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
        const stdout_data = try stdout_reader.interface.allocRemaining(gpa, .unlimited);

        var stderr_buf: [4096]u8 = undefined;
        var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
        const stderr_data = try stderr_reader.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(stderr_data);

        const term = try child.wait(io);
        try std.testing.expect(term == .exited);
        try std.testing.expectEqual(@as(u8, 0), term.exited);
        try std.testing.expectEqual(@as(usize, 0), stderr_data.len);

        outputs[i] = stdout_data;
    }

    try std.testing.expectEqualStrings(outputs[0], outputs[1]);
}
