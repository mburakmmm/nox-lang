//! v2.1.151 (TODO 1.11): aarch64 ve riscv64 QEMU `virt` çıplak çekirdek boot testleri. `runtime/freestanding/<arch>/kernel_demo.nox`u `noxc build --target <arch> --profile freestanding
//! --emit-asm` ile derler, `zig cc` ile `boot_<arch>.o` + `kernel.ld` + `noxrt-freestanding-<arch>.o` ile bağlar ve GERÇEK `qemu-system-<arch>`ta çalıştırır; UART'tan sırayla basılan
//! işaretleri ve çıkış kodunu (0) doğrular. `qbe`/`qemu-system-<arch>` yoksa test sessizce atlanır (x86_64 boot testiyle aynı ilke). Yalnızca POSIX ana makine.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const ChildWatchdog = struct {
    done: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,
    active: bool = false,

    fn arm(self: *ChildWatchdog, child: *const std.process.Child, timeout_ms: u32) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{ self, child.id.?, timeout_ms });
        self.active = true;
    }

    fn run(self: *ChildWatchdog, pid: std.posix.pid_t, timeout_ms: u32) void {
        var waited: i64 = 0;
        while (waited < timeout_ms) : (waited += 200) {
            if (self.done.load(.acquire)) return;
            const ts: std.c.timespec = .{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
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

fn toolAvailable(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) bool {
    const result = std.process.run(allocator, io, .{ .argv = argv }) catch return false;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    return true;
}

const Arch = enum { aarch64, riscv64 };

fn bootAndCheck(arch: Arch) !void {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const name = @tagName(arch);
    const qemu = try std.fmt.allocPrint(allocator, "qemu-system-{s}", .{name});
    defer allocator.free(qemu);
    if (!toolAvailable(allocator, io, &.{ "qbe", "-h" })) return error.SkipZigTest;
    if (!toolAvailable(allocator, io, &.{ qemu, "--version" })) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const stem = try std.fmt.allocPrint(allocator, "{s}/kernel", .{dir});
    defer allocator.free(stem);
    const asm_path = try std.fmt.allocPrint(allocator, "{s}.s", .{stem});
    defer allocator.free(asm_path);
    const elf_path = try std.fmt.allocPrint(allocator, "{s}/kernel.elf", .{dir});
    defer allocator.free(elf_path);
    const src = try std.fmt.allocPrint(allocator, "runtime/freestanding/{s}/kernel_demo.nox", .{name});
    defer allocator.free(src);
    const ld = try std.fmt.allocPrint(allocator, "runtime/freestanding/{s}/kernel.ld", .{name});
    defer allocator.free(ld);
    const boot = try std.fmt.allocPrint(allocator, "runtime/freestanding/{s}/boot_{s}.o", .{ name, name });
    defer allocator.free(boot);
    const rt = try std.fmt.allocPrint(allocator, "zig-out/lib/noxrt-freestanding-{s}.o", .{name});
    defer allocator.free(rt);
    const triple = try std.fmt.allocPrint(allocator, "{s}-freestanding-none", .{name});
    defer allocator.free(triple);
    const ld_flag = try std.fmt.allocPrint(allocator, "-Wl,-T,{s}", .{ld});
    defer allocator.free(ld_flag);

    const build_result = try std.process.run(allocator, io, .{
        .argv = &.{ build_options.noxc_path, "build", "--target", name, "--profile", "freestanding", "--emit-asm", src, "-o", stem },
    });
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);
    if (build_result.term != .exited or build_result.term.exited != 0) {
        std.debug.print("noxc build basarisiz:\n{s}\n", .{build_result.stderr});
        return error.NoxcBuildFailed;
    }

    const link_result = try std.process.run(allocator, io, .{
        .argv = &.{ build_options.zig_exe_path, "cc", "-target", triple, "-nostdlib", "-static", ld_flag, "-Wl,--build-id=none", "-Wl,-z,max-page-size=0x1000", "-o", elf_path, boot, asm_path, rt },
    });
    defer allocator.free(link_result.stdout);
    defer allocator.free(link_result.stderr);
    if (link_result.term != .exited or link_result.term.exited != 0) {
        std.debug.print("zig cc (kernel link) basarisiz:\n{s}\n", .{link_result.stderr});
        return error.KernelLinkFailed;
    }

    const argv_a64 = [_][]const u8{ qemu, "-machine", "virt", "-cpu", "cortex-a57", "-m", "128M", "-kernel", elf_path, "-nographic", "-semihosting", "-monitor", "none", "-serial", "stdio", "-no-reboot" };
    const argv_rv64 = [_][]const u8{ qemu, "-machine", "virt", "-cpu", "rv64", "-m", "128M", "-bios", "none", "-kernel", elf_path, "-nographic", "-monitor", "none", "-serial", "stdio", "-no-reboot" };
    var child = try std.process.spawn(io, .{
        .argv = if (arch == .aarch64) &argv_a64 else &argv_rv64,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var watchdog: ChildWatchdog = .{};
    try watchdog.arm(&child, 30_000);
    defer watchdog.disarm();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const out = try stdout_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(out);
    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const err_out = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(err_out);
    const term = try child.wait(io);
    errdefer std.debug.print("QEMU stdout:\n{s}\nQEMU stderr:\n{s}\n", .{ out, err_out });

    const marks = [_][]const u8{ "Hello Nox", "HEAP_OK", "DICT_OK", "STR_OK", "CLASS_OK", "FLOAT_OK", "RECURSION_OK", "EXCEPT_OK", "INT_PRINT 328350 100", "FLOAT_PRINT 3.0", "ALL_CHECKPOINTS_OK" };
    var last: usize = 0;
    for (marks) |m| {
        // İşaretler SIRAYLA basılmalı (her biri öncekinden sonra).
        const at = std.mem.indexOfPos(u8, out, last, m) orelse {
            std.debug.print("eksik/sirasiz isaret: {s}\n", .{m});
            return error.MarkerMissing;
        };
        last = at + m.len;
    }
    try std.testing.expect(std.mem.indexOf(u8, out, "KERNEL_FAULT") == null);
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);
}

test "TODO 1.11: kernel_demo.nox aarch64 (QEMU virt) çıplak çekirdeğine derlenip önyükleniyor" {
    try bootAndCheck(.aarch64);
}

test "TODO 1.11: kernel_demo.nox riscv64 (QEMU virt) çıplak çekirdeğine derlenip önyükleniyor" {
    try bootAndCheck(.riscv64);
}
