//! Nox derleyicisinin dış dünyaya (testler, ileride codegen/typecheck) açtığı
//! tek giriş noktası. `noxc` (main.zig) ile testler aynı sembollere buradan erişir.

pub const span = @import("span.zig");
pub const token = @import("lexer/token.zig");
pub const lexer = @import("lexer/lexer.zig");
pub const ast = @import("parser/ast.zig");
pub const parser = @import("parser/parser.zig");
pub const ast_dump = @import("parser/ast_dump.zig");
pub const formatter = @import("fmt/formatter.zig");
pub const types = @import("typecheck/types.zig");
pub const checker = @import("typecheck/checker.zig");
pub const ownership = @import("ownership/analysis.zig");
pub const codegen = @import("codegen_qbe/codegen.zig");
pub const module_loader = @import("module_loader.zig");
pub const project = @import("project.zig");
pub const test_runner = @import("pkg/test_runner.zig");
pub const fetch = @import("pkg/fetch.zig");
pub const pkg_index = @import("pkg/index.zig");
pub const upgrade = @import("pkg/upgrade.zig");
pub const qbe_target = @import("qbe_target.zig");

// `zig build test`in `nox_mod`u (bu dosyayı KÖK olarak KULLANAN `lib_test`
// hedefi, bkz. build.zig) YALNIZCA bu dosyanın KENDİ üst-düzey deyimlerinden
// erişilebilir (referans verilen) kod yollarını semantik olarak analiz eder
// — Zig'in tembel (lazy) analiz modeli GEREĞİ, YUKARIDAKİ `pub const`
// yeniden-dışa-aktarımların (`lexer`, `checker`, `codegen`, ...) TEK BAŞINA
// VAR OLMASI, İÇLERİNDEKİ `test "..."` bloklarının BU test ikilisi
// TARAFINDAN keşfedilmesini GARANTİ ETMEZ (yalnızca `tests/unit/`/`tests/
// golden/` gibi `nox`ı DIŞARIDAN kullanan AYRI test dosyaları çalıştırılırdı
// — `compiler/lexer/lexer.zig`/`compiler/parser/parser.zig`/`typecheck/
// types.zig`/vb. İÇİNE gömülü TÜM `test` blokları SESSİZCE atlanıyordu, bu
// KEŞFEDİLENE KADAR HİÇBİR "zig build test yeşil" iddiası BUNLARI
// DOĞRULAMIYORDU). Aşağıdaki `test` bloğu, `refAllDeclsRecursive`in BU Zig
// sürümünde (0.16) HENÜZ VAR OLMAMASI nedeniyle EL İLE yazılmış özyinelemeli
// bir sürümüyle TÜM yeniden-dışa-aktarılan modüllerin (VE onların KENDİ
// nested struct/enum/union tipi bildirimlerinin) HER birine bir referans
// zorlar — bu, Zig'in test-toplama mekanizmasının HER dosyayı GERÇEKTEN
// Sema'dan geçirmesini (ve böylece İÇLERİNDEKİ `test` bloklarını GERÇEKTEN
// KEŞFETMESİNİ) sağlar.
fn refAllDeclsRecursive(comptime T: type) void {
    const std = @import("std");
    if (!@import("builtin").is_test) return;
    inline for (comptime std.meta.declarations(T)) |decl| {
        const field = @field(T, decl.name);
        if (@TypeOf(field) == type) {
            switch (@typeInfo(field)) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(field),
                else => {},
            }
        }
        _ = &field;
    }
}

test {
    refAllDeclsRecursive(@This());
}
