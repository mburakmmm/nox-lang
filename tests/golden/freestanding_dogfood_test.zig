//! v4 Faz C madde 1+2 (bkz. nox-teknik-spesifikasyon.md §3.2xx, proje
//! belleği "v4 pre20 stdlib roadmap"): `kernel_boot_x86_64_test.zig`nin
//! TEK-hardcoded-dosya (`kernel_demo.nox`) modelini, `compile_helpers.
//! zig`nin hosted modeli GİBİ parametrik bir yardımcıya (`expectFreestandingBoot`)
//! genelleştirir — HERHANGİ bir `.nox` kaynağını GERÇEK bir x86_64 QEMU
//! önyüklemesinde çalıştırıp beklenen checkpoint dizisini doğrular.
//!
//! **Dogfood'un ASIL ÖZÜ** (madde 2): `freestanding_dogfood_corpus.nox`
//! (capability-siz/saf stdlib modülleri — `nox.math`/`nox.bits`/`nox.mem`/
//! `nox.buffer`/`nox.binary`/`nox.collections`/`nox.console`/`nox.time`nin
//! saf kısmı — + çekirdek dil) HEM hosted (`noxc run`) HEM GERÇEK QEMU'da
//! çalıştırılır, İKİSİNİN de AYNI checkpoint dizisini bastığı doğrulanır.
//!
//! `kernel_boot_x86_64_test.zig`nin AYNI `ChildWatchdog`/`toolAvailable`/
//! `findTool` deseni — modül-kök sınırları YÜZÜNDEN BİLİNÇLİ, küçük bir
//! tekrar (bkz. o dosyanın belge notu).

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const ChildWatchdog = struct {
    done: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,
    active: bool = false,

    fn arm(self: *ChildWatchdog, child: *const std.process.Child, timeout_ms: u32) !void {
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

    fn disarm(self: *ChildWatchdog) void {
        if (!self.active) return;
        self.done.store(true, .release);
        self.thread.join();
    }
};

fn sleepMs(ms: i64) void {
    const ts: std.c.timespec = .{
        .sec = @divTrunc(ms, std.time.ms_per_s),
        .nsec = @mod(ms, std.time.ms_per_s) * std.time.ns_per_ms,
    };
    _ = std.c.nanosleep(&ts, null);
}

fn toolAvailable(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) bool {
    const result = std.process.run(allocator, io, .{ .argv = argv }) catch return false;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    return true;
}

fn findTool(allocator: std.mem.Allocator, io: std.Io, candidates: []const []const u8) ?[]const u8 {
    for (candidates) |c| {
        if (toolAvailable(allocator, io, &.{ c, "--version" })) return c;
    }
    return null;
}

/// `kernel_boot_x86_64_test.zig`nin (5)-(7) adımlarının GENELLEŞTİRİLMİŞ
/// hâli — `source`u (GEÇİCİ bir `.nox` dosyasına yazılır) `noxc build
/// --target x86_64 --profile freestanding --emit-asm` İLE derler,
/// `boot_x86_64.o`/`noxrt-freestanding-x86_64.o`/`kernel.ld` İLE linkler,
/// ELF32/EM_386 konteynerine (`objcopy`) çevirir, GERÇEK QEMU'da çalıştırır
/// — `expected_checkpoints`in HER biri stdout'ta (SIRADAN, substring)
/// bulunmalı, `"KERNEL_FAULT"` HİÇ bulunmamalı, çıkış kodu `isa-debug-exit`in
/// `33`ü olmalı. Araçlar (`qbe`/`qemu-system-x86_64`/`objcopy`) EKSİKSE
/// SESSİZCE `error.SkipZigTest` (`kernel_boot_x86_64_test.zig`nin AYNI
/// ilkesi).
pub fn expectFreestandingBoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    expected_checkpoints: []const []const u8,
) !void {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    if (!toolAvailable(allocator, io, &.{ "qbe", "-h" })) return error.SkipZigTest;
    if (!toolAvailable(allocator, io, &.{ "qemu-system-x86_64", "--version" })) return error.SkipZigTest;
    const objcopy_name = findTool(allocator, io, &.{ "x86_64-elf-objcopy", "objcopy" }) orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];

    const src_path = try std.fmt.allocPrint(allocator, "{s}/src.nox", .{dir_path});
    defer allocator.free(src_path);
    try tmp.dir.writeFile(io, .{ .sub_path = "src.nox", .data = source });

    const kernel_stem = try std.fmt.allocPrint(allocator, "{s}/kernel", .{dir_path});
    defer allocator.free(kernel_stem);
    const kernel_s_path = try std.fmt.allocPrint(allocator, "{s}.s", .{kernel_stem});
    defer allocator.free(kernel_s_path);
    const kernel_elf64_path = try std.fmt.allocPrint(allocator, "{s}/kernel64.elf", .{dir_path});
    defer allocator.free(kernel_elf64_path);
    const kernel_elf_path = try std.fmt.allocPrint(allocator, "{s}/kernel.elf", .{dir_path});
    defer allocator.free(kernel_elf_path);

    const build_result = try std.process.run(allocator, io, .{
        .argv = &.{ build_options.noxc_path, "build", "--target", "x86_64", "--profile", "freestanding", "--emit-asm", src_path, "-o", kernel_stem },
    });
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);
    if (build_result.term != .exited or build_result.term.exited != 0) {
        std.debug.print("noxc build basarisiz:\nstdout: {s}\nstderr: {s}\n", .{ build_result.stdout, build_result.stderr });
        return error.NoxcBuildFailed;
    }

    const link_result = try std.process.run(allocator, io, .{
        .argv = &.{
            build_options.zig_exe_path,
            "cc",
            "-target",
            "x86_64-freestanding-none",
            "-ffreestanding",
            "-nostdlib",
            "-static",
            "-Wl,-T," ++ build_options.kernel_ld_path,
            "-Wl,-s",
            "-Wl,--build-id=none",
            "-Wl,-z,max-page-size=0x1000",
            "-o",
            kernel_elf64_path,
            build_options.boot_obj_path,
            kernel_s_path,
            build_options.noxrt_kernel_obj_path,
        },
    });
    defer allocator.free(link_result.stdout);
    defer allocator.free(link_result.stderr);
    if (link_result.term != .exited or link_result.term.exited != 0) {
        std.debug.print("zig cc (kernel link) basarisiz:\nstdout: {s}\nstderr: {s}\n", .{ link_result.stdout, link_result.stderr });
        return error.KernelLinkFailed;
    }

    const convert_result = try std.process.run(allocator, io, .{
        .argv = &.{ objcopy_name, "-O", "elf32-i386", "-S", kernel_elf64_path, kernel_elf_path },
    });
    defer allocator.free(convert_result.stdout);
    defer allocator.free(convert_result.stderr);
    if (convert_result.term != .exited or convert_result.term.exited != 0) {
        if (std.mem.indexOf(u8, convert_result.stderr, "invalid bfd target") != null or
            std.mem.indexOf(u8, convert_result.stderr, "unsupported bfd target") != null)
        {
            return error.SkipZigTest;
        }
        std.debug.print("{s} (elf32-i386 donusumu) basarisiz:\nstdout: {s}\nstderr: {s}\n", .{ objcopy_name, convert_result.stdout, convert_result.stderr });
        return error.KernelConvertFailed;
    }

    var child = try std.process.spawn(io, .{
        .argv = &.{
            "qemu-system-x86_64",
            "-machine",
            "q35",
            "-cpu",
            "qemu64",
            "-m",
            "128M",
            "-kernel",
            kernel_elf_path,
            "-device",
            "isa-debug-exit,iobase=0xf4,iosize=0x04",
            "-serial",
            "stdio",
            "-display",
            "none",
            "-monitor",
            "none",
            "-no-reboot",
        },
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var watchdog: ChildWatchdog = .{};
    try watchdog.arm(&child, 20_000);
    defer watchdog.disarm();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const stdout_data = try stdout_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stdout_data);

    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);

    const term = try child.wait(io);

    errdefer std.debug.print("QEMU stdout:\n{s}\nQEMU stderr:\n{s}\n", .{ stdout_data, stderr_data });

    for (expected_checkpoints) |cp| {
        try std.testing.expect(std.mem.indexOf(u8, stdout_data, cp) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, stdout_data, "KERNEL_FAULT") == null);

    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 33), term.exited);
}

// Madde 2 (dogfood'un ASIL ÖZÜ): `freestanding_dogfood_corpus.nox`
// (capability-siz/saf stdlib modülleri + çekirdek dil) HEM `noxc run`
// (hosted) HEM GERÇEK QEMU'da (freestanding) çalıştırılır — İKİSİNİN
// de TAM OLARAK AYNI checkpoint SIRASINI bastığı kanıtlanır (statik bir
// `expected` sabiti DEĞİL — hosted çalışmasının KENDİ stdout'u, QEMU'nun
// çıktısının BİREBİR ALT-DİZİSİ olmalı).
test "Faz C madde 2: freestanding_dogfood_corpus.nox hosted VE GERÇEK QEMU'da AYNI checkpoint dizisini basar" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const corpus_source = @embedFile("freestanding_dogfood_corpus.nox");

    const hosted_result = try std.process.run(allocator, io, .{
        .argv = &.{ build_options.noxc_path, "run", build_options.dogfood_corpus_path },
    });
    defer allocator.free(hosted_result.stdout);
    defer allocator.free(hosted_result.stderr);
    if (hosted_result.term != .exited or hosted_result.term.exited != 0) {
        std.debug.print("noxc run (hosted) basarisiz:\nstdout: {s}\nstderr: {s}\n", .{ hosted_result.stdout, hosted_result.stderr });
        return error.HostedRunFailed;
    }

    var checkpoints: std.ArrayListUnmanaged([]const u8) = .empty;
    defer checkpoints.deinit(allocator);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, hosted_result.stdout, "\n"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try checkpoints.append(allocator, line);
    }
    try std.testing.expect(checkpoints.items.len >= 10);

    try expectFreestandingBoot(allocator, io, corpus_source, checkpoints.items);
}
