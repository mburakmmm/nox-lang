//! v1.100.0 (bkz. nox-teknik-spesifikasyon.md §3.187): v2.0 stabilizasyon
//! yol haritasının İLK maddesi — seed-tabanlı, DETERMİNİSTİK olarak
//! reproduce edilebilir bir eşzamanlılık "torture" testi. GERÇEK Nox
//! kaynağı (`spawn`/`await`/`Task[T].cancel()`/`CancelledError`/
//! `try/except`/gerçek dosya G/Ç'si), `nox.thread.pool_run(8, entry)`
//! ÜZERİNDEN GERÇEK bir çok-worker M:N havuzunda ÇALIŞTIRILIR — bu YÜZDEN
//! `noxc build --release` (LLVM) GEREKİR (bkz. `stdlib/nox/thread.nox`nin
//! "Katman 3" notu — `pool_run` SADECE `--release` altında ÇALIŞIR).
//!
//! **KRİTİK, tasarımı DOĞRUDAN belirleyen İKİ bulgu** (bkz. plan dosyası):
//! (1) `nox.random`'ın PRNG durumu FİBER-BAŞINADIR (`runtime/stdlib_shims/
//! random.zig`nin `Fiber.prng`si) — spawn edilen HER görev KENDİ, TAZE/
//! UNSEEDED fiber'ında BAŞLAR VE İLK kullanımda ZAMANA-BAĞLI otomatik
//! tohumlanır. Bu YÜZDEN TÜM rastgele kararlar `entry()`nin KENDİSİNDE,
//! spawn'DAN ÖNCE, SIRALI (tek-fiber) alınır — spawn edilen görevler
//! SADECE ÖNCEDEN hesaplanmış parametreleri TÜKETİR, KENDİLERİ `nox.
//! random` ÇAĞIRMAZ. (2) `t.cancel()` SADECE bir bayrak İŞARETLER —
//! `CancelledError`, cancel edilen görevin KENDİ gövdesindeki BİR SONRAKİ
//! `await` NOKTASINDA fırlatılır (`tests/golden/codegen_cases/task_
//! cancel_caught.nox`nin KANITLADIĞI desen) — checkpoint'i OLMAYAN (saf
//! CPU-döngüsü/senkron dosya G/Ç'si) bir görevi cancel etmenin HİÇBİR
//! ETKİSİ OLMAZ, bu YÜZDEN "rastgele iptal" SADECE KENDİ İçİNDE bir
//! `await` BARINDIRAN (`nested_work`) görev türüne uygulanır.
//!
//! `http_soak_test.zig`nin `absPath`/`ChildWatchdog` desenleriyle AYNI
//! konvansiyonu izler (`child_watchdog.zig`nin KENDİ, "HİÇBİR test bloğu
//! İçERMEMELİ" kısıtı — bkz. onun belge notu — BURADA da geçerli, o
//! dosyaya HİÇ DOKUNULMADI).

const std = @import("std");
const child_watchdog = @import("child_watchdog.zig");

fn tortureSeedCountFromEnv(default_count: u32) u32 {
    const v = std.c.getenv("NOX_TORTURE_SEED_COUNT") orelse return default_count;
    return std.fmt.parseInt(u32, std.mem.span(v), 10) catch default_count;
}

fn tortureTaskCountFromEnv(default_tasks: u32) u32 {
    const v = std.c.getenv("NOX_TORTURE_TASKS") orelse return default_tasks;
    return std.fmt.parseInt(u32, std.mem.span(v), 10) catch default_tasks;
}

/// `NOX_TORTURE_MASTER_SEED` AYARLIYSA, seçilen TÜM seed'ler BUNDAN
/// türetilir (TÜM meta-koşunun — HANGİ seed'lerin denendiğinin — de
/// reproduce edilebilir olması İçİn); AKSİ HALDE her seferinde GERÇEKTEN
/// rastgele (`nanoTimestamp`) bir seed üretilir — HER İKİ durumda da
/// KULLANILAN seed HER ZAMAN stdout'a/hata mesajına yazdırılır (bkz.
/// aşağıdaki test gövdesi), bu YÜZDEN "master seed AYARLANMADI" bile OLSA
/// BAŞARISIZ bir seed HER ZAMAN elle tekrar ÇALIŞTIRILABİLİR.
fn masterPrngFromEnv() ?std.Random.DefaultPrng {
    const v = std.c.getenv("NOX_TORTURE_MASTER_SEED") orelse return null;
    const s = std.fmt.parseInt(u64, std.mem.span(v), 10) catch return null;
    return std.Random.DefaultPrng.init(s);
}

fn nextSeed(master: *?std.Random.DefaultPrng) i64 {
    if (master.*) |*p| return @bitCast(p.random().int(u64));
    // `std.time.nanoTimestamp` bu Zig sürümünde YOK (`runtime/stdlib_shims/
    // random.zig`nin `ensureSeeded`i İLE AYNI, KANITLANMIŞ `clock_gettime`
    // deseni).
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const raw: i64 = ts.sec *% 1_000_000_000 +% ts.nsec;
    return @mod(raw, std.math.maxInt(i64));
}

fn absPath(io: std.Io, dir: std.Io.Dir, buf: []u8) ![]const u8 {
    const len = try dir.realPath(io, buf);
    return buf[0..len];
}

const torture_source =
    \\import nox.random
    \\import nox.os
    \\import nox.fs
    \\import nox.thread
    \\
    \\class TortureRaised(Exception):
    \\    pass
    \\
    \\async def leaf_work(n: int) -> int:
    \\    total: int = 0
    \\    i: int = 0
    \\    while i < n:
    \\        total = total + i
    \\        i = i + 1
    \\    return total
    \\
    \\async def io_work(path: str, payload: str) -> int:
    \\    nox.fs.write_string(path, payload)
    \\    content: str = nox.fs.read_to_string(path)
    \\    nox.fs.remove_file(path)
    \\    return len(content)
    \\
    \\async def raising_work(msg: str) -> int:
    \\    raise TortureRaised(msg)
    \\
    \\async def nested_work(n: int) -> int:
    \\    inner: Task[int] = spawn leaf_work(n)
    \\    v: int = await inner
    \\    return v * 2
    \\
    \\async def entry() -> None:
    \\    seed: int = int(nox.os.arg(1))
    \\    task_count: int = int(nox.os.arg(2))
    \\    nox.random.seed(seed)
    \\
    \\    kinds: list[int] = []
    \\    params: list[int] = []
    \\    cancels: list[bool] = []
    \\    i: int = 0
    \\    while i < task_count:
    \\        kinds.append(nox.random.randint(0, 3))
    \\        params.append(nox.random.randint(1, 400))
    \\        cancels.append(nox.random.randint(0, 9) == 0)
    \\        i = i + 1
    \\
    \\    completed: int = 0
    \\    cancelled: int = 0
    \\    excepted: int = 0
    \\    j: int = 0
    \\    while j < task_count:
    \\        kind: int = kinds[j]
    \\        param: int = params[j]
    \\        if kind == 0:
    \\            t0: Task[int] = spawn leaf_work(param)
    \\            v0: int = await t0
    \\            completed = completed + 1
    \\        elif kind == 1:
    \\            path: str = "/tmp/nox_torture_" + str(seed) + "_" + str(j) + ".tmp"
    \\            t1: Task[int] = spawn io_work(path, "payload-" + str(j))
    \\            v1: int = await t1
    \\            completed = completed + 1
    \\        elif kind == 2:
    \\            t2: Task[int] = spawn raising_work("boom-" + str(j))
    \\            try:
    \\                v2: int = await t2
    \\                completed = completed + 1
    \\            except TortureRaised as e:
    \\                excepted = excepted + 1
    \\        else:
    \\            t3: Task[int] = spawn nested_work(param)
    \\            if cancels[j]:
    \\                t3.cancel()
    \\            try:
    \\                v3: int = await t3
    \\                completed = completed + 1
    \\            except CancelledError as e:
    \\                cancelled = cancelled + 1
    \\        j = j + 1
    \\
    \\    print("TORTURE_OK " + str(seed) + " " + str(task_count) + " " + str(completed) + " " + str(cancelled) + " " + str(excepted))
    \\
    \\nox.thread.pool_run(8, entry)
    \\
;

fn compileTortureBinary(gpa: std.mem.Allocator, io: std.Io, nox_path: []const u8, bin_path: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = nox_path, .data = torture_source });
    const compile_result = try std.process.run(gpa, io, .{
        .argv = &.{ "zig-out/bin/noxc", "build", "--release", nox_path, "-o", bin_path },
    });
    defer gpa.free(compile_result.stdout);
    defer gpa.free(compile_result.stderr);
    if (compile_result.term != .exited or compile_result.term.exited != 0) {
        std.debug.print("concurrency-torture: derleme basarisiz: {s}\n", .{compile_result.stderr});
        return error.CompileFailed;
    }
}

test "concurrency torture: seed-tabanlı, deterministik reproduce edilebilir eşzamanlılık stresi" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const seed_count = tortureSeedCountFromEnv(3);
    const task_count = tortureTaskCountFromEnv(3000);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = try absPath(io, tmp.dir, &dir_buf);
    const nox_path = try std.fmt.allocPrint(gpa, "{s}/torture.nox", .{dir_path});
    defer gpa.free(nox_path);
    const bin_path = try std.fmt.allocPrint(gpa, "{s}/torture", .{dir_path});
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

        if (term != .exited or term.exited != 0 or std.mem.indexOf(u8, stdout_data, "TORTURE_OK") == null or stderr_data.len != 0) {
            std.debug.print(
                "TORTURE REPRO: seed={d} task_count={d} (elle tekrar: '{s}' '{d}' '{d}')\nterm={any}\nstdout:\n{s}\nstderr:\n{s}\n",
                .{ seed, task_count, bin_path, seed, task_count, term, stdout_data, stderr_data },
            );
        }
        try std.testing.expect(term == .exited);
        try std.testing.expectEqual(@as(u8, 0), term.exited);
        try std.testing.expect(std.mem.indexOf(u8, stdout_data, "TORTURE_OK") != null);
        try std.testing.expectEqual(@as(usize, 0), stderr_data.len);
    }
}

// Determinizm kanıtı — AYNI seed+task_count İLE İKİ AYRI ÇALIŞTIRMANIN
// `TORTURE_OK` satırının (completed/cancelled/excepted sayıları DAHİL)
// BİREBİR AYNI olduğunu doğrular (bkz. plan dosyasının "Doğrulama"
// bölümü madde 3).
test "concurrency torture: aynı seed iki kez BİREBİR aynı sonucu üretir (determinizm kanıtı)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const task_count = tortureTaskCountFromEnv(500);
    const fixed_seed: i64 = 123456789;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = try absPath(io, tmp.dir, &dir_buf);
    const nox_path = try std.fmt.allocPrint(gpa, "{s}/torture_det.nox", .{dir_path});
    defer gpa.free(nox_path);
    const bin_path = try std.fmt.allocPrint(gpa, "{s}/torture_det", .{dir_path});
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
