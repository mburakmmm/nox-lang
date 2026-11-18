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

test "selfhost_glue: bileşen simgeleri bu birimde çözülmez (yalnızca nightly ikilisinde bağlanır)" {
    // Bu dosya normal test derlemesinde analiz edilmez; yer tutucu.
}
