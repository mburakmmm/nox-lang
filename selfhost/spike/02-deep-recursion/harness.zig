const std = @import("std");
extern fn nox_runtime_init() ?*anyopaque;
extern fn nox_runtime_deinit(rt: ?*anyopaque) void;
extern fn nox_lib_init(rt: ?*anyopaque) void;
extern fn nox_lib_fini(rt: ?*anyopaque) void;
extern fn sh_chain(rt: ?*anyopaque, n: i64) i64;

const Job = struct { n: i64, out: i64 = -1 };
fn work(job: *Job) void {
    const rt = nox_runtime_init();
    nox_lib_init(rt);
    job.out = sh_chain(rt, job.n);
    nox_lib_fini(rt);
    nox_runtime_deinit(rt);
}

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const n = try std.fmt.parseInt(i64, args.next() orelse "1000", 10);
    const stack_mb = try std.fmt.parseInt(usize, args.next() orelse "0", 10);
    var job: Job = .{ .n = n };
    if (stack_mb == 0) {
        work(&job); // ana iş parçacığı (işletim sistemi varsayılan yığını)
    } else {
        const t = try std.Thread.spawn(.{ .stack_size = stack_mb * 1024 * 1024 }, work, .{&job});
        t.join();
    }
    var buf: [64]u8 = undefined;
    const out = try std.fmt.bufPrint(&buf, "n={d} derinlik={d}\n", .{ n, job.out });
    _ = std.c.write(1, out.ptr, out.len);
}
