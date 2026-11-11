//! WASM yorumlayıcısı — yapısal özellik testleri (v2.1.65, TODO 4.1): kontrol akışı, çok değerli blok/dönüş, bellek, global, tablo + dolaylı çağrı,
//! bulk-memory, referanslar, `start`, host işlevleri ve tuzaklar. `tests/compat/wasm_wat/core.wat` (binaryen `wasm-as` ile `core.wasm`) üzerinde çalışır;
//! beklenen değerler Node/V8 ile de doğrulanmıştır (bkz. `scripts/wasm_gen_vectors.py` — sayısal komutlar için bit-bit farksal test).

const std = @import("std");
const wasm = @import("wasm_bridge");
const Instance = wasm.interp.Instance;
const Trap = wasm.interp.Trap;

const core_wasm = @embedFile("wasm_wat/core.wasm");

const Host = struct {
    counter: u64 = 0,

    fn add(_: ?*anyopaque, _: *Instance, args: []const u64, res: []u64) Trap!void {
        res[0] = @as(u32, @truncate(args[0])) +% @as(u32, @truncate(args[1])) +% 1000;
    }
    fn count(ctx: ?*anyopaque, _: *Instance, _: []const u64, res: []u64) Trap!void {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        self.counter += 1;
        res[0] = self.counter;
    }
};

const i32x2 = [_]wasm.module.ValType{ .i32, .i32 };
const i32x1 = [_]wasm.module.ValType{.i32};

const Fixture = struct {
    host: *Host,
    inst: *Instance,

    fn init(cfg: wasm.interp.Config) !Fixture {
        var mod = try wasm.module.parse(std.testing.allocator, core_wasm);
        errdefer mod.deinit();
        const host = try std.testing.allocator.create(Host);
        errdefer std.testing.allocator.destroy(host);
        host.* = .{};
        const bindings = [_]wasm.interp.HostBinding{
            .{ .module = "env", .name = "host_add", .item = .{ .func = .{ .params = &i32x2, .results = &i32x1, .f = Host.add } } },
            .{ .module = "env", .name = "host_counter", .item = .{ .func = .{ .params = &.{}, .results = &i32x1, .f = Host.count, .ctx = host } } },
            .{ .module = "env", .name = "base", .item = .{ .global = .{ .ty = .{ .valtype = .i32, .mutable = false }, .value = 500 } } },
        };
        // `mod` Fixture'a taşındığında adresi değişir; örnek `*const Module` tuttuğundan modül yığın üzerinde sabitlenir.
        const mod_ptr = try std.testing.allocator.create(wasm.module.Module);
        errdefer std.testing.allocator.destroy(mod_ptr);
        mod_ptr.* = mod;
        const inst = try Instance.init(std.testing.allocator, mod_ptr, &bindings, cfg);
        return .{ .host = host, .inst = inst };
    }

    fn deinit(self: *Fixture) void {
        const mp: *wasm.module.Module = @constCast(self.inst.module);
        self.inst.deinit();
        mp.deinit();
        std.testing.allocator.destroy(mp);
        std.testing.allocator.destroy(self.host);
    }

    fn call(self: *Fixture, name: []const u8, args: []const u64) Trap!u64 {
        var res: [2]u64 = undefined;
        const idx = self.inst.findExport(name, .func).?;
        const ft = self.inst.module.typeOf(idx);
        try self.inst.invoke(idx, args, res[0..ft.results.len]);
        return if (ft.results.len > 0) res[0] else 0;
    }

    fn expect(self: *Fixture, want: u64, name: []const u8, args: []const u64) !void {
        try std.testing.expectEqual(want, try self.call(name, args));
    }

    fn expectTrap(self: *Fixture, want: Trap, name: []const u8, args: []const u64) !void {
        try std.testing.expectError(want, self.call(name, args));
    }
};

fn s32(v: i32) u64 {
    return @as(u32, @bitCast(v));
}

test "start işlevi, global'ler, içe aktarılan global ve host işlevleri" {
    var f = try Fixture.init(.{});
    defer f.deinit();
    try f.expect(100, "counter", &.{}); // start: counter = 100
    try f.expect(101, "bump", &.{});
    try f.expect(102, "bump", &.{});
    try f.expect(30, "g64", &.{});
    try f.expect(90, "g64", &.{});
    try std.testing.expectEqual(@as(f64, 3.0), @as(f64, @bitCast(try f.call("gf", &.{}))));
    try f.expect(505, "base_plus", &.{5});
    try f.expect(1003, "use_host", &.{ 1, 2 });
    try f.expect(3, "use_counter", &.{}); // 1 + 2
    try f.expect(7, "use_counter", &.{}); // 3 + 4
}

test "kontrol akışı: özyineleme, döngü, br_table, çok değerli blok/döngü, select, tee" {
    var f = try Fixture.init(.{});
    defer f.deinit();
    try f.expect(3628800, "fac", &.{10});
    try f.expect(55, "fib", &.{10});
    try f.expect(0, "fib", &.{0});
    try f.expect(10, "sw", &.{0});
    try f.expect(20, "sw", &.{1});
    try f.expect(30, "sw", &.{2});
    try f.expect(99, "sw", &.{3});
    try f.expect(99, "sw", &.{1000}); // varsayılan hedef
    try f.expect(7, "block_params", &.{ 10, 3 });
    try f.expect(10, "loop_params", &.{4}); // 1+2+3+4
    try f.expect(11, "select_t", &.{1});
    try f.expect(22, "select_t", &.{0});
    try f.expect(1, "sel_ref", &.{1});
    try f.expect(0, "sel_ref", &.{0});
    try f.expect(30, "tee", &.{5});
    try f.expect(s32(-7), "swap_sub", &.{ 10, 3 });
    try f.expect(2, "nested_br", &.{0});
    try f.expect(1, "nested_br", &.{1});
    try f.expect(7, "early_return", &.{1});
    try f.expect(8, "early_return", &.{0});
    try f.expect(3, "dead_code", &.{});
}

test "çok değerli dönüş: dışarıdan iki sonuç" {
    var f = try Fixture.init(.{});
    defer f.deinit();
    var res: [2]u64 = undefined;
    try f.inst.invoke(f.inst.findExport("swap", .func).?, &.{ 1, 2 }, &res);
    try std.testing.expectEqual(@as(u64, 2), res[0]);
    try std.testing.expectEqual(@as(u64, 1), res[1]);
}

test "tuzaklar: unreachable, sıfıra bölme, taşma, yığın taşması, yakıt" {
    var f = try Fixture.init(.{ .fuel = 100_000, .max_call_depth = 1000 });
    defer f.deinit();
    try f.expectTrap(error.Unreachable, "unreachable_trap", &.{});
    try f.expectTrap(error.IntegerDivideByZero, "div0", &.{0});
    try f.expect(1, "div0", &.{1});
    try f.expectTrap(error.StackExhausted, "rec", &.{0});
    try f.expectTrap(error.OutOfFuel, "spin", &.{});
    // tuzaktan sonra örnek kullanılabilir kalır
    try f.expect(55, "fib", &.{10});
}

test "bellek: genişlikler, işaret/sıfır genişletme, ofset, sınır, büyütme" {
    var f = try Fixture.init(.{});
    defer f.deinit();
    // veri segmenti: "hello, wasm" @ 16
    try f.expect('h', "ld8u", &.{16});
    try f.expect('w', "ld8u", &.{23});
    try f.expect(0x6568, "ld16u", &.{16}); // 'h','e'
    // genişlikler
    try f.expect(0x1234_5678, "store_load", &.{ 100, 0x1234_5678 });
    try f.expect(0xffff_ffff, "store_load", &.{ 100, 0xffff_ffff });
    try f.expect(s32(-1), "ld8s", &.{100});
    try f.expect(0xff, "ld8u", &.{100});
    try f.expect(s32(-1), "ld16s", &.{100});
    try f.expect(0xffff, "ld16u", &.{100});
    try f.expect(0xffff_ffff_ffff_ffff, "ld32s64", &.{100});
    try f.expect(0xffff_ffff, "ld32u64", &.{100});
    try f.expect(0xffff_ffff_ffff_ffff, "ld8s64", &.{100});
    _ = try f.call("st8", &.{ 200, 0x1234 });
    try f.expect(0x34, "ld8u", &.{200});
    _ = try f.call("st16", &.{ 200, 0x1234_abcd });
    try f.expect(0xabcd, "ld16u", &.{200});
    try f.expect(0x0123_4567_89ab_cdef, "st64", &.{ 300, 0x0123_4567_89ab_cdef });
    try std.testing.expectEqual(@as(f64, 2.5), @as(f64, @bitCast(try f.call("stf", &.{ 400, @as(u64, @bitCast(@as(f64, 2.5))) }))));
    try std.testing.expectEqual(@as(f32, -1.25), @as(f32, @bitCast(@as(u32, @truncate(try f.call("stf32", &.{ 400, @as(u32, @bitCast(@as(f32, -1.25))) }))))));
    // ofset: load offset=4 @ 96 okur 100'deki değeri
    _ = try f.call("store_load", &.{ 100, 0xcafe_babe });
    try f.expect(0xcafe_babe, "load_off", &.{96});
    // sınırlar: bellek 1 sayfa = 65536; son geçerli 4 bayt 65532
    try f.expect(7, "store_load", &.{ 65532, 7 });
    try f.expectTrap(error.OutOfBoundsMemoryAccess, "store_load", &.{ 65533, 7 });
    try f.expectTrap(error.OutOfBoundsMemoryAccess, "ld8u", &.{65536});
    try f.expectTrap(error.OutOfBoundsMemoryAccess, "ld8u", &.{0xffff_ffff});
    try f.expectTrap(error.OutOfBoundsMemoryAccess, "load_off", &.{65532}); // 65532 + 4 + 4 > 65536
    // büyütme: max 4
    try f.expect(1, "size", &.{});
    try f.expect(1, "grow", &.{1});
    try f.expect(2, "size", &.{});
    try f.expect(7, "store_load", &.{ 65536 + 100, 7 }); // yeni sayfa erişilebilir, sıfırdan başlar
    try f.expect(s32(-1), "grow", &.{5}); // 2 + 5 > max 4
    try f.expect(2, "size", &.{});
    try f.expect(2, "grow", &.{0});
}

test "bulk-memory: fill, copy (örtüşen), init, data.drop" {
    var f = try Fixture.init(.{});
    defer f.deinit();
    _ = try f.call("fill", &.{ 1000, 0xab, 5 });
    try f.expect(0xab, "ld8u", &.{1000});
    try f.expect(0xab, "ld8u", &.{1004});
    try f.expect(0, "ld8u", &.{1005});
    // örtüşen kopya (ileri): [1000..1005) -> [1002..1007)
    _ = try f.call("st8", &.{ 1000, 1 });
    _ = try f.call("st8", &.{ 1001, 2 });
    _ = try f.call("st8", &.{ 1002, 3 });
    _ = try f.call("copy", &.{ 1002, 1000, 3 });
    try f.expect(1, "ld8u", &.{1002});
    try f.expect(2, "ld8u", &.{1003});
    try f.expect(3, "ld8u", &.{1004});
    // pasif segment: "ABCDEFGH"
    _ = try f.call("init", &.{ 2000, 2, 4 }); // "CDEF"
    try f.expect('C', "ld8u", &.{2000});
    try f.expect('F', "ld8u", &.{2003});
    try f.expectTrap(error.OutOfBoundsMemoryAccess, "init", &.{ 2000, 6, 4 }); // 6 + 4 > 8
    try f.expectTrap(error.OutOfBoundsMemoryAccess, "fill", &.{ 65535, 0, 2 });
    try f.expectTrap(error.OutOfBoundsMemoryAccess, "copy", &.{ 65535, 0, 2 });
    _ = try f.call("drop_data", &.{});
    try f.expectTrap(error.OutOfBoundsMemoryAccess, "init", &.{ 2000, 0, 1 });
    _ = try f.call("init", &.{ 2000, 0, 0 }); // sıfır uzunluk, bırakılmış segmentte bile geçerli
}

test "tablo: call_indirect, tuzaklar, grow/fill/copy/init, referanslar" {
    var f = try Fixture.init(.{});
    defer f.deinit();
    try f.expect(6, "call_ind", &.{ 0, 5 }); // inc
    try f.expect(4, "call_ind", &.{ 1, 5 }); // dec
    try f.expect(10, "call_ind", &.{ 2, 5 }); // mul2
    try f.expect(5, "call_ind", &.{ 3, 5 }); // alias
    try f.expectTrap(error.UninitializedElement, "call_ind", &.{ 4, 5 });
    try f.expectTrap(error.UndefinedElement, "call_ind", &.{ 9, 5 });
    try f.expectTrap(error.IndirectCallTypeMismatch, "call_ind_bad", &.{0});
    try f.expect(8, "tbl_size", &.{});
    try f.expect(8, "tbl_grow", &.{2});
    try f.expect(10, "tbl_size", &.{});
    try f.expect(s32(-1), "tbl_grow", &.{1_000_000_000});
    try f.expect(1, "tbl_null", &.{4});
    _ = try f.call("tbl_set_func", &.{4});
    try f.expect(0, "tbl_null", &.{4});
    _ = try f.call("tbl_clear", &.{4});
    try f.expect(1, "tbl_null", &.{4});
    _ = try f.call("tbl_fill", &.{ 5, 3 });
    try f.expect(0, "tbl_null", &.{7});
    try f.expect(11, "call_ind", &.{ 6, 10 }); // inc
    _ = try f.call("tbl_copy", &.{ 0, 5, 2 });
    try f.expect(11, "call_ind", &.{ 0, 10 }); // inc kopyası (öncekinde de inc)
    // pasif elem [inc, dec, null] -> tablo 8..
    _ = try f.call("tbl_init", &.{ 7, 0, 3 });
    try f.expect(0, "tbl_null", &.{7});
    try f.expect(1, "tbl_null", &.{9});
    try f.expectTrap(error.OutOfBoundsTableAccess, "tbl_init", &.{ 8, 2, 3 });
    try f.expectTrap(error.OutOfBoundsTableAccess, "tbl_fill", &.{ 9, 5 });
    try f.expectTrap(error.OutOfBoundsTableAccess, "tbl_null", &.{100});
    try f.expect(1, "tbl_ext_roundtrip", &.{});
}

test "geçersiz modüller reddedilir (doğrulama)" {
    const a = std.testing.allocator;
    const cases = [_][]const u8{
        // (func (result i32)) boş gövde: sonuç eksik
        "\x00asm\x01\x00\x00\x00\x01\x05\x01\x60\x00\x01\x7f\x03\x02\x01\x00\x0a\x04\x01\x02\x00\x0b",
        // (func (result i32) i64.const 1): yanlış tip
        "\x00asm\x01\x00\x00\x00\x01\x05\x01\x60\x00\x01\x7f\x03\x02\x01\x00\x0a\x06\x01\x04\x00\x42\x01\x0b",
        // (func i32.add): yığın yetersiz
        "\x00asm\x01\x00\x00\x00\x01\x04\x01\x60\x00\x00\x03\x02\x01\x00\x0a\x05\x01\x03\x00\x6a\x0b",
        // yük (bellek yok)
        "\x00asm\x01\x00\x00\x00\x01\x05\x01\x60\x00\x01\x7f\x03\x02\x01\x00\x0a\x09\x01\x07\x00\x41\x00\x28\x02\x00\x0b",
        // br derinliği aşıyor
        "\x00asm\x01\x00\x00\x00\x01\x04\x01\x60\x00\x00\x03\x02\x01\x00\x0a\x06\x01\x04\x00\x0c\x05\x0b",
        // bilinmeyen opcode
        "\x00asm\x01\x00\x00\x00\x01\x04\x01\x60\x00\x00\x03\x02\x01\x00\x0a\x05\x01\x03\x00\xff\x0b",
        // local.get tanımsız yerel
        "\x00asm\x01\x00\x00\x00\x01\x04\x01\x60\x00\x00\x03\x02\x01\x00\x0a\x06\x01\x04\x00\x20\x09\x0b",
    };
    for (cases) |bytes| {
        var m = wasm.module.parse(a, bytes) catch continue; // ayrıştırma düzeyinde reddedilmesi de geçerli
        defer m.deinit();
        try std.testing.expectError(error.InvalidModule, Instance.init(a, &m, &.{}, .{}));
    }
}

test "içe aktarma bağlama hataları" {
    const a = std.testing.allocator;
    var m = try wasm.module.parse(a, core_wasm);
    defer m.deinit();
    try std.testing.expectError(error.ImportNotFound, Instance.init(a, &m, &.{}, .{}));
    var host: Host = .{};
    const wrong = [_]wasm.interp.HostBinding{
        .{ .module = "env", .name = "host_add", .item = .{ .func = .{ .params = &i32x1, .results = &i32x1, .f = Host.add } } },
        .{ .module = "env", .name = "host_counter", .item = .{ .func = .{ .params = &.{}, .results = &i32x1, .f = Host.count, .ctx = &host } } },
        .{ .module = "env", .name = "base", .item = .{ .global = .{ .ty = .{ .valtype = .i32, .mutable = false }, .value = 500 } } },
    };
    try std.testing.expectError(error.ImportTypeMismatch, Instance.init(a, &m, &wrong, .{}));
}

fn mutationRun(bytes: []const u8, stride: usize, bindings: []const wasm.interp.HostBinding) !usize {
    const a = std.testing.allocator;
    const buf = try a.dupe(u8, bytes);
    defer a.free(buf);
    const cfg: wasm.interp.Config = .{ .fuel = 20_000, .max_stack_slots = 4096, .max_call_depth = 64, .max_memory_pages = 40, .max_table_elems = 4096 };
    var instantiated: usize = 0;
    var pos: usize = 0;
    while (pos < bytes.len) : (pos += stride) {
        const orig = bytes[pos];
        for ([_]u8{ 0x00, 0xff, 0x80, 0x7f, orig +% 1, orig -% 1, orig ^ 0x40 }) |v| {
            buf[pos] = v;
            var m = wasm.module.parse(a, buf) catch continue;
            defer m.deinit();
            const inst = Instance.init(a, &m, bindings, cfg) catch continue;
            instantiated += 1;
            inst.deinit();
        }
        buf[pos] = orig;
    }
    // kısaltılmış önekler
    var n: usize = 0;
    while (n < bytes.len) : (n += stride) {
        var m = wasm.module.parse(a, bytes[0..n]) catch continue;
        defer m.deinit();
        const inst = Instance.init(a, &m, bindings, cfg) catch continue;
        inst.deinit();
    }
    return instantiated;
}

test "bozulmuş modüller: bayt mutasyonu ve kısaltma asla çökmez/sızdırmaz (core + gerçek derleyici çıktısı)" {
    var host: Host = .{};
    const bindings = [_]wasm.interp.HostBinding{
        .{ .module = "env", .name = "host_add", .item = .{ .func = .{ .params = &i32x2, .results = &i32x1, .f = Host.add } } },
        .{ .module = "env", .name = "host_counter", .item = .{ .func = .{ .params = &.{}, .results = &i32x1, .f = Host.count, .ctx = &host } } },
        .{ .module = "env", .name = "base", .item = .{ .global = .{ .ty = .{ .valtype = .i32, .mutable = false }, .value = 500 } } },
    };
    const n1 = try mutationRun(core_wasm, 1, &bindings);
    try std.testing.expect(n1 > 100); // geçerli kalan mutasyonlar da var (ör. sabit değerler)
    _ = try mutationRun(@embedFile("wasm_programs/prog.wasm"), 11, &.{});
}
