//! WASM'da `nox.process` (spec §3.359): alt süreç çalıştırma bir HOST yeteneğidir (bit 2). `wasm32-freestanding --asyncify` + host `process` sağlayıcısı (Node: `child_process.spawn`, kabuksuz)
//! varsa gerçek çalıştırma; aksi halde `Command.run()` "could not run the process" ile `ProcessError` verir. `nox_process_*` imzaları `process.zig` ile BİREBİR aynıdır. İstek kaydı:
//! kind 13, `method` = program, `url` = çalışma dizini, `body` = argümanlar (NUL ayraçlı), `arg` = zaman aşımı (ms); yanıt: `status` = çıkış kodu (sinyal = -1), gövde = stdout, başlık alanı = stderr.

const std = @import("std");
const wasm_options = @import("wasm_options");
const str_mod = @import("../str.zig");
const shim_util = @import("shim_util.zig");
const abi_layout = @import("abi_layout");

const enabled = @import("../wasm_host.zig").is_freestanding_wasm and wasm_options.asyncify and !wasm_options.threads;
const fetch = if (enabled) @import("http_fetch.zig") else struct {};

const gpa = std.heap.page_allocator;
const LIST_HEADER_SIZE = abi_layout.LIST_HEADER_SIZE;
const FIELD_SLOT_SIZE = abi_layout.FIELD_SLOT_SIZE;

const Out = struct {
    ok: bool = false,
    status: i64 = -1,
    stdout: []u8 = &.{},
    stderr: []u8 = &.{},
};

export fn nox_process_run_raw(rt: ?*anyopaque, program: ?[*:0]const u8, args: ?*anyopaque, cwd: ?[*:0]const u8, timeout_ms: i64) callconv(.c) ?*anyopaque {
    _ = rt;
    const out = gpa.create(Out) catch return null;
    out.* = .{};
    if (comptime !enabled) return out;
    if (!fetch.processAvailable()) return out;
    const prog = str_mod.nox_str_slice(program orelse return out);
    // Argümanlar NUL ile ayrılır (Nox `str` değerleri NUL içeremez).
    var joined: std.ArrayListUnmanaged(u8) = .empty;
    defer joined.deinit(gpa);
    if (args) |a| {
        const bytes: [*]u8 = @ptrCast(a);
        const count: usize = @intCast(@as(*align(1) i64, @ptrCast(bytes)).*);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const addr: usize = @intCast(@as(u64, @bitCast(@as(*align(1) i64, @ptrCast(bytes + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i)).*)));
            const p: [*:0]const u8 = @ptrFromInt(addr);
            if (i > 0) joined.append(gpa, 0) catch return out;
            joined.appendSlice(gpa, str_mod.nox_str_slice(p)) catch return out;
        }
    }
    const cwd_s: []const u8 = if (cwd) |c| str_mod.nox_str_slice(c) else "";
    const req = fetch.submit(.{ .kind = .proc_run, .method = prog, .url = cwd_s, .body = joined.items, .timeout_ms = timeout_ms }, false) orelse return out;
    const resp = fetch.waitFor(req) orelse return out;
    defer fetch.responseFree(resp);
    if (!resp.ok) return out;
    out.stdout = gpa.dupe(u8, resp.body) catch return out;
    out.stderr = gpa.dupe(u8, resp.headers) catch {
        gpa.free(out.stdout);
        out.stdout = &.{};
        return out;
    };
    out.status = resp.status;
    out.ok = true;
    return out;
}

fn outOf(h: ?*anyopaque) ?*Out {
    return @ptrCast(@alignCast(h orelse return null));
}

export fn nox_process_output_ok_raw(h: ?*anyopaque) callconv(.c) i64 {
    const o = outOf(h) orelse return 0;
    return if (o.ok) 1 else 0;
}

export fn nox_process_output_status_raw(h: ?*anyopaque) callconv(.c) i64 {
    const o = outOf(h) orelse return -1;
    return o.status;
}

export fn nox_process_output_stdout_raw(rt: ?*anyopaque, h: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const o = outOf(h) orelse return shim_util.dupeToNoxStr(rt, "");
    return shim_util.dupeToNoxStr(rt, o.stdout);
}

export fn nox_process_output_stderr_raw(rt: ?*anyopaque, h: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const o = outOf(h) orelse return shim_util.dupeToNoxStr(rt, "");
    return shim_util.dupeToNoxStr(rt, o.stderr);
}

export fn nox_process_output_free_raw(h: ?*anyopaque) callconv(.c) void {
    const o = outOf(h) orelse return;
    if (o.stdout.len > 0) gpa.free(o.stdout);
    if (o.stderr.len > 0) gpa.free(o.stderr);
    gpa.destroy(o);
}
