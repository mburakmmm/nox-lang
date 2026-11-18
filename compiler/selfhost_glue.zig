//! noxc-nightly (Aşama 0.3): Nox ile yazılmış bileşenlerin (`selfhost/*.nox`) Zig tarafı köprüsü. YALNIZCA nightly ikilisinde derlenir (`build_options.nightly`); normal `noxc` bu dosyayı
//! hiç analiz etmez (simgeler `zig build nightly`nin bağladığı `selfhost.o`dan gelir). Sözleşme: `selfhost/README.md`.

const std = @import("std");

extern fn nox_runtime_init() ?*anyopaque;
extern fn nox_runtime_deinit(rt: ?*anyopaque) void;
extern fn nox_lib_init(rt: ?*anyopaque) void;
extern fn nox_lib_fini(rt: ?*anyopaque) void;
extern fn sh_count_ident_tokens(rt: ?*anyopaque, buf: [*]const u8, n: i64) i64;

/// Bir Nox çalışma zamanı bağlamı: `start` ... `stop`. Bileşen çağrıları arasında paylaşılır; iş parçacıkları arası kullanım yok (derleyici tek iş parçacıklıdır).
pub const Runtime = struct {
    rt: ?*anyopaque,

    pub fn start() Runtime {
        const rt = nox_runtime_init();
        nox_lib_init(rt);
        return .{ .rt = rt };
    }

    pub fn stop(self: Runtime) void {
        nox_lib_fini(self.rt);
        nox_runtime_deinit(self.rt);
    }

    /// Aşama 0 deneme bileşeni: ASCII tanımlayıcı sayısı.
    pub fn countIdentTokens(self: Runtime, src: []const u8) i64 {
        return sh_count_ident_tokens(self.rt, src.ptr, @intCast(src.len));
    }
};

/// Nox bileşenleri (parser/checker özyinelemesi) için ayrılan yığın: 256 MiB (yalnızca sanal bellek; dokunulan kadarı fiziksel). Deney (`selfhost/spike/02-deep-recursion`, LLVM -O2): 8 MiB'lık ana yığın
/// iki çocuklu özyinelemede ~300 bin derinliğe yetiyor, 1 milyon çöküyor; 256 MiB 1 milyonu rahat taşıyor (zincir serbest bırakma dahil).
pub const BIG_STACK_BYTES: usize = 256 * 1024 * 1024;

/// `f(ctx, runtime)`ü büyük yığınlı yeni bir iş parçacığında çalıştırır (`Runtime` o iş parçacığında kurulur/yıkılır; çalışma zamanı tek iş parçacığına aittir). `join` ile bekler.
pub fn runOnBigStack(ctx: anytype, comptime f: fn (@TypeOf(ctx), Runtime) void) !void {
    const Ctx = @TypeOf(ctx);
    const Thunk = struct {
        fn entry(c: Ctx) void {
            const nrt = Runtime.start();
            defer nrt.stop();
            f(c, nrt);
        }
    };
    const t = try std.Thread.spawn(.{ .stack_size = BIG_STACK_BYTES }, Thunk.entry, .{ctx});
    t.join();
}

test "selfhost_glue: bileşen simgeleri bu birimde çözülmez (yalnızca nightly ikilisinde bağlanır)" {
    // Bu dosya normal test derlemesinde analiz edilmez; yer tutucu.
}
