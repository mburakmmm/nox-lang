//! Faz F.4 (bkz. plan dosyası "Gerçek bare-metal boot zinciri (x86_64)"):
//! Bu FAZIN FALSIFIABLE deneyi — `runtime/freestanding/x86_64/kernel_demo.
//! nox`u GERÇEKTEN `noxc build --profile freestanding` (`NOX_FREESTANDING_
//! KERNEL_ARCH=x86_64` dâhilî kancasıyla) derleyip, `zig cc`yi linker
//! sürücüsü olarak kullanarak `runtime/freestanding/x86_64/kernel.ld`
//! (linker script) + `boot_x86_64.o` (boot.S) + `noxrt-freestanding-x86_64.o`
//! ile birleştirir, SONUCU GERÇEK bir `qemu-system-x86_64` çalıştırmasıyla
//! doğrular (SIRAYLA basılan 6 checkpoint string'i + `isa-debug-exit`in
//! KESİN `33` çıkış kodu).
//!
//! `qbe`/`qemu-system-x86_64` PATH'te YOKSA (CI'de — F.5'in KENDİ, gelecekteki
//! işi — qemu HENÜZ KURULMUYOR) test SESSİZCE `SkipZigTest` ile atlanır
//! (`freestanding_link_test.zig`nin AYNI "harici araç eksikse ana takımı
//! KIRMA" ilkesi).

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

/// `std.process.run`nin `environ_map == null` İKEN çocuk sürece HANGİ
/// çevreyi geçireceği BU Zig sürümünde `setenv()` İLE yapılan çalışma-
/// zamanı MUTASYONLARI YANSITMIYOR (doğrudan denenip GÖZLENDİ) — bu YÜZDEN
/// mevcut süreç çevresini (`std.c.environ`) KOPYALAYIP `NOX_FREESTANDING_
/// KERNEL_ARCH`i EKLEYEN, AÇIKÇA geçirilen bir `Environ.Map` kullanılır.
fn buildEnvironWithKernelArch(allocator: std.mem.Allocator) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    var i: usize = 0;
    while (std.c.environ[i]) |entry_ptr| : (i += 1) {
        const entry: [:0]const u8 = std.mem.span(entry_ptr);
        const eq_idx = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        try map.put(entry[0..eq_idx], entry[eq_idx + 1 ..]);
    }
    try map.put("NOX_FREESTANDING_KERNEL_ARCH", "x86_64");
    return map;
}

/// Faz TEST.3'ün `tests/compat/child_watchdog.zig`sinin AYNI, KASITLI
/// küçük kopyası — modül-kök sınırları YÜZÜNDEN (bu dosya `tests/golden/`
/// kökünde, `child_watchdog.zig` `tests/compat/`te) relative import
/// MÜMKÜN DEĞİL, bu YÜZDEN BU projenin KENDİ "kasıtlı, küçük tekrar"
/// konvansiyonu (`compile_helpers.zig`/`http_serve_tls_golden_test.zig`nin
/// AYNI ilkesi) İZLENİR. BU DOSYA HİÇBİR BAŞKA `test` bloğu İçERMEZ.
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

/// GERÇEK bir QEMU çalıştırmasıyla KEŞFEDİLDİ: QEMU'nun dahili Multiboot1
/// yükleyicisi ELF64 KABUL ETMİYOR — bu YÜZDEN normal (elf64-x86-64) linkten
/// SONRA, bir `objcopy` İLE ELF32/EM_386 KONTEYNERİNE dönüştürülür (bkz.
/// `kernel.ld`nin belge notu — relokasyonlar link ANINDA ZATEN çözüldüğünden
/// bu POST-PROCESS adımı GÜVENLİDİR/relax GEREKTİRMEZ).
fn findTool(allocator: std.mem.Allocator, io: std.Io, candidates: []const []const u8) ?[]const u8 {
    for (candidates) |c| {
        if (toolAvailable(allocator, io, &.{ c, "--version" })) return c;
    }
    return null;
}

test "Faz F.4: kernel_demo.nox GERÇEK bir x86_64 kernel imajına derlenip QEMU'da başarıyla önyükleniyor" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    if (!toolAvailable(allocator, io, &.{ "qbe", "-h" })) return error.SkipZigTest;
    if (!toolAvailable(allocator, io, &.{ "qemu-system-x86_64", "--version" })) return error.SkipZigTest;
    const objcopy_name = findTool(allocator, io, &.{ "x86_64-elf-objcopy", "objcopy" }) orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];

    const kernel_stem = try std.fmt.allocPrint(allocator, "{s}/kernel", .{dir_path});
    defer allocator.free(kernel_stem);
    const kernel_s_path = try std.fmt.allocPrint(allocator, "{s}.s", .{kernel_stem});
    defer allocator.free(kernel_s_path);
    const kernel_elf64_path = try std.fmt.allocPrint(allocator, "{s}/kernel64.elf", .{dir_path});
    defer allocator.free(kernel_elf64_path);
    const kernel_elf_path = try std.fmt.allocPrint(allocator, "{s}/kernel.elf", .{dir_path});
    defer allocator.free(kernel_elf_path);

    // (3) `noxc build --profile freestanding <kernel_src> -o <tmp>/kernel`
    // — `NOX_FREESTANDING_KERNEL_ARCH=x86_64` dâhilî kancasıyla (bkz.
    // `compiler/main.zig`nin `buildOne`ı) linkleme ATLANIR, `<tmp>/kernel.s`
    // (HAM QBE assembly) döner.
    var kernel_env = try buildEnvironWithKernelArch(allocator);
    defer kernel_env.deinit();
    const build_result = try std.process.run(allocator, io, .{
        .argv = &.{ build_options.noxc_path, "build", "--profile", "freestanding", build_options.kernel_src_path, "-o", kernel_stem },
        .environ_map = &kernel_env,
    });
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);
    if (build_result.term != .exited or build_result.term.exited != 0) {
        std.debug.print("noxc build basarisiz:\nstdout: {s}\nstderr: {s}\n", .{ build_result.stdout, build_result.stderr });
        return error.NoxcBuildFailed;
    }

    // (4) Madde 8.3'ün link komutu — `boot_x86_64.o` (32-bit giriş + long-
    // mode geçişi + ISR trambolinleri) + `<tmp>/kernel.s` (QBE'nin ürettiği
    // Nox programı) + `noxrt-freestanding-x86_64.o` (runtime), `kernel.ld`
    // linker script'iyle. NORMAL (elf64-x86-64) çıktı — `zig cc`nin gömülü
    // LLD'si BU formatta `R_X86_64_REX_GOTPCRELX` relokasyonlarını DOĞRU
    // "relax" eder (bkz. `kernel.ld`nin belge notu).
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

    // (4b) ELF64 → ELF32/EM_386 KONTEYNER dönüşümü (`objcopy`, POST-LINK —
    // bkz. `kernel.ld`nin belge notu) — QEMU'nun Multiboot1 yükleyicisi
    // İçİn GEREKLİ, TÜM relokasyonlar ZATEN çözüldüğünden GÜVENLİDİR.
    const convert_result = try std.process.run(allocator, io, .{
        .argv = &.{ objcopy_name, "-O", "elf32-i386", "-S", kernel_elf64_path, kernel_elf_path },
    });
    defer allocator.free(convert_result.stdout);
    defer allocator.free(convert_result.stderr);
    if (convert_result.term != .exited or convert_result.term.exited != 0) {
        std.debug.print("{s} (elf32-i386 donusumu) basarisiz:\nstdout: {s}\nstderr: {s}\n", .{ objcopy_name, convert_result.stdout, convert_result.stderr });
        return error.KernelConvertFailed;
    }

    // (5) QEMU'DAN ÖNCE, ucuz/harici-araçsız ELF doğrulaması —
    // `freestanding_link_test.zig`nin AYNI hand-rolled ELF-header tekniği.
    const elf_bytes = try tmp.dir.readFileAlloc(io, "kernel.elf", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(elf_bytes);
    try std.testing.expect(elf_bytes.len >= 64);
    try std.testing.expectEqualSlices(u8, "\x7fELF", elf_bytes[0..4]);
    // `kernel.ld`nin `OUTPUT_FORMAT(elf32-i386)` hilesi YÜZÜNDEN (bkz. o
    // dosyanın notu — QEMU'nun Multiboot1 yükleyicisi ELF64'ü REDDEDİYOR)
    // dosya BİLİNÇLİ olarak ELF32/EM_386 KAPSAYICISINDA — GERÇEK MAKİNE
    // KODU HÂLÂ x86_64'tür, sadece KONTEYNER-seviyesi metadata 32-bit
    // (e_entry BU YÜZDEN 4 baytlık bir alandır, ELF64'teki 8 bayt DEĞİL).
    try std.testing.expectEqualSlices(u8, &.{1}, elf_bytes[4..5]); // ELFCLASS32
    const e_type = std.mem.readInt(u16, elf_bytes[16..18], .little);
    try std.testing.expectEqual(@as(u16, 2), e_type); // ET_EXEC
    const e_machine = std.mem.readInt(u16, elf_bytes[18..20], .little);
    try std.testing.expectEqual(@as(u16, 3), e_machine); // EM_386 (konteyner-seviyesi — bkz. yukarıdaki not)
    const e_entry = std.mem.readInt(u32, elf_bytes[24..28], .little);
    try std.testing.expect(e_entry >= 0x100000 and e_entry < 0x200000);
    // Multiboot1 magic (0x1BADB002, little-endian) dosyanın İLK 8192
    // baytında, 4-hizalı bir ofsette bulunmalı.
    var found_multiboot = false;
    var mb_off: usize = 0;
    while (mb_off + 4 <= @min(elf_bytes.len, 8192)) : (mb_off += 4) {
        if (std.mem.readInt(u32, elf_bytes[mb_off..][0..4], .little) == 0x1BADB002) {
            found_multiboot = true;
            break;
        }
    }
    try std.testing.expect(found_multiboot);
    // 4 MiB'lik kernel heap'in (`nox_runtime_init_freestanding`nin `.bss`
    // arabelleği) dosya boyutunu ŞİŞİRMEDİĞİNİN (GERÇEKTEN `.bss`e gittiğinin)
    // dolaylı kanıtı.
    try std.testing.expect(elf_bytes.len < 1024 * 1024);

    // (6) GERÇEK QEMU çalıştırması — `isa-debug-exit` (normal çıkış) +
    // `-no-reboot` (triple fault → QEMU sonlanır) + `ChildWatchdog` (20s
    // SIGKILL) — sonsuza kadar asılma İMKÂNSIZ.
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

    // (7) Başarısızlıkta TAM stdout+stderr dök (teşhis İçİn).
    errdefer std.debug.print("QEMU stdout:\n{s}\nQEMU stderr:\n{s}\n", .{ stdout_data, stderr_data });

    try std.testing.expect(std.mem.indexOf(u8, stdout_data, "Hello Nox") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_data, "IDT_BP_OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_data, "IDT_OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_data, "PAGE_ALLOC_OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_data, "HEAP_OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_data, "ALL_CHECKPOINTS_OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_data, "KERNEL_FAULT") == null);

    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 33), term.exited); // (0x10<<1)|1
}
