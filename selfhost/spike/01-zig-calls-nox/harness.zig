const std = @import("std");
extern fn nox_runtime_init() ?*anyopaque;
extern fn nox_runtime_deinit(rt: ?*anyopaque) void;
extern fn count_ident_tokens(rt: ?*anyopaque, buf: [*]const u8, n: i64) i64;

fn isStart(c: u8) bool { return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_'; }
fn isChar(c: u8) bool { return isStart(c) or (c >= '0' and c <= '9'); }
fn zigCount(buf: []const u8) i64 {
    var count: i64 = 0;
    var i: usize = 0;
    while (i < buf.len) {
        if (isStart(buf[i])) {
            count += 1;
            while (i < buf.len and isChar(buf[i])) i += 1;
        } else i += 1;
    }
    return count;
}
fn now() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
pub fn main() !void {
    const rt = nox_runtime_init();
    defer nox_runtime_deinit(rt);
    const unit = "def foo(x_1, y): return x_1 + y  # 12 ab\nclass Bar: pass\n    value = items[0] + other_name * 3\n";
    const reps = 20000;
    const buf = try std.heap.page_allocator.alloc(u8, unit.len * reps);
    for (0..reps) |i| @memcpy(buf[i * unit.len ..][0..unit.len], unit);
    var best_nox: u64 = std.math.maxInt(u64);
    var best_zig: u64 = std.math.maxInt(u64);
    var rn: i64 = 0;
    var rz: i64 = 0;
    for (0..10) |_| {
        var t = now();
        rn = count_ident_tokens(rt, buf.ptr, @intCast(buf.len));
        best_nox = @min(best_nox, now() - t);
        t = now();
        rz = zigCount(buf);
        std.mem.doNotOptimizeAway(rz);
        best_zig = @min(best_zig, now() - t);
    }
    std.debug.print("{d} bytes: nox={d} us (r={d})  zig={d} us (r={d})  oran={d:.2}x\n", .{ buf.len, best_nox / 1000, rn, best_zig / 1000, rz, @as(f64, @floatFromInt(best_nox)) / @as(f64, @floatFromInt(best_zig)) });
}
