//! Windows CI test koşucusu. `zig build test -Dwin-test-timeout=N` ile
//! bağlanır. Her testin adını başlamadan stderr'e yazar. Test `N` saniyede
//! bitmezse süreç o adla çıkar. Böylece asılı bir test, işin 180 dakikalık
//! sınırına kadar sessiz kalmaz.
//!
//! Süre `NOX_WIN_TEST_TIMEOUT_SEC` ile gelir. `0` veya boş değer zaman
//! aşımını kapatır; testler yine tek tek yazılır.
const builtin = @import("builtin");
const std = @import("std");

const tick_ms: u32 = 200;

var current_index = std.atomic.Value(usize).init(0);
var started_ms = std.atomic.Value(u64).init(0);
var in_test = std.atomic.Value(bool).init(false);
var stop_watch = std.atomic.Value(bool).init(false);

pub fn main(init: std.process.Init.Minimal) void {
    const timeout_s = readTimeoutSeconds();
    const watcher = if (timeout_s != 0)
        std.Thread.spawn(.{}, watch, .{timeout_s}) catch null
    else
        null;
    defer if (watcher) |thread| {
        stop_watch.store(true, .release);
        thread.join();
    };

    if (timeout_s == 0) {
        writeAll("win-test-timeout: disabled\n");
    } else {
        var line_buf: [80]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "win-test-timeout: {d}s per test\n", .{timeout_s}) catch "win-test-timeout: on\n";
        writeAll(line);
    }

    var failed: usize = 0;
    var skipped: usize = 0;
    var leaks: usize = 0;
    const tests = builtin.test_functions;
    for (tests, 0..) |t, i| {
        var head_buf: [512]u8 = undefined;
        const head = std.fmt.bufPrint(&head_buf, "{d}/{d} {s}...\n", .{ i + 1, tests.len, t.name }) catch "?\n";
        writeAll(head);

        current_index.store(i, .release);
        started_ms.store(monoMs(), .release);
        in_test.store(true, .release);

        testingSetup(init);
        const result = t.func();
        if (testingTeardown() == .leak) leaks += 1;
        in_test.store(false, .release);

        if (result) |_| {
            writeAll("OK\n");
        } else |err| switch (err) {
            error.SkipZigTest => {
                skipped += 1;
                writeAll("SKIP\n");
            },
            else => {
                failed += 1;
                var fail_buf: [160]u8 = undefined;
                const fail = std.fmt.bufPrint(&fail_buf, "FAIL ({s})\n", .{@errorName(err)}) catch "FAIL\n";
                writeAll(fail);
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            },
        }
    }

    var summary_buf: [160]u8 = undefined;
    const summary = std.fmt.bufPrint(
        &summary_buf,
        "{d} passed; {d} skipped; {d} failed; {d} leaked.\n",
        .{ tests.len - failed - skipped, skipped, failed, leaks },
    ) catch "summary\n";
    writeAll(summary);
    if (failed != 0 or leaks != 0) std.process.exit(1);
}

fn watch(timeout_s: u64) void {
    const limit_ms: u64 = timeout_s * 1000;
    while (!stop_watch.load(.acquire)) {
        sleepMs(tick_ms);
        if (!in_test.load(.acquire)) continue;
        const started = started_ms.load(.acquire);
        if (monoMs() - started < limit_ms) continue;
        const index = current_index.load(.acquire);
        const name = if (index < builtin.test_functions.len) builtin.test_functions[index].name else "?";
        var buf: [640]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "\nTIMEOUT: {s} exceeded {d}s\n", .{ name, timeout_s }) catch "\nTIMEOUT\n";
        writeAll(msg);
        hardExit(2);
    }
}

fn testingSetup(init: std.process.Init.Minimal) void {
    std.testing.allocator_instance = .{};
    std.testing.io_instance = .init(std.testing.allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    std.testing.log_level = .warn;
    std.testing.environ = init.environ;
}

fn testingTeardown() std.heap.Check {
    std.testing.io_instance.deinit();
    return std.testing.allocator_instance.deinit();
}

fn readTimeoutSeconds() u64 {
    var raw_buf: [32]u8 = undefined;
    const raw = envValue("NOX_WIN_TEST_TIMEOUT_SEC", &raw_buf) orelse return 0;
    return std.fmt.parseInt(u64, raw, 10) catch 0;
}

fn envValue(key: [:0]const u8, buf: []u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        const k = struct {
            extern "kernel32" fn GetEnvironmentVariableA(name: [*:0]const u8, out: [*]u8, cap: u32) callconv(.c) u32;
        };
        const n = k.GetEnvironmentVariableA(key, buf.ptr, @intCast(buf.len));
        if (n == 0 or n >= buf.len) return null;
        return buf[0..n];
    }
    const value = std.c.getenv(key) orelse return null;
    const slice = std.mem.span(value);
    if (slice.len >= buf.len) return null;
    @memcpy(buf[0..slice.len], slice);
    return buf[0..slice.len];
}

fn monoMs() u64 {
    if (builtin.os.tag == .windows) {
        const k = struct {
            extern "kernel32" fn GetTickCount64() callconv(.c) u64;
        };
        return k.GetTickCount64();
    }
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(@divTrunc(ts.nsec, 1_000_000)));
}

fn sleepMs(ms: u32) void {
    if (builtin.os.tag == .windows) {
        const k = struct {
            extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.c) void;
        };
        k.Sleep(ms);
        return;
    }
    const ts: std.c.timespec = .{
        .sec = ms / 1000,
        .nsec = @as(isize, ms % 1000) * std.time.ns_per_ms,
    };
    _ = std.c.nanosleep(&ts, null);
}

fn writeAll(bytes: []const u8) void {
    if (builtin.os.tag == .windows) {
        const k = struct {
            extern "kernel32" fn GetStdHandle(n: i32) callconv(.c) ?*anyopaque;
            extern "kernel32" fn WriteFile(h: ?*anyopaque, buf: [*]const u8, n: u32, written: ?*u32, overlapped: ?*anyopaque) callconv(.c) i32;
        };
        var wrote: u32 = 0;
        _ = k.WriteFile(k.GetStdHandle(-12), bytes.ptr, @intCast(bytes.len), &wrote, null);
        return;
    }
    _ = std.c.write(2, bytes.ptr, bytes.len);
}

fn hardExit(code: u8) noreturn {
    if (builtin.os.tag == .windows) {
        const k = struct {
            extern "kernel32" fn ExitProcess(code: u32) callconv(.c) noreturn;
        };
        k.ExitProcess(code);
    }
    std.c.exit(code);
}
