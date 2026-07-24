//! `compiler/module_loader.zig` için ek testler.
//!
//! Gerçek span sistemi (bkz. plan dosyası "Gerçek span sistemi +
//! yapılandırılmış tanılamalar", Bulgu #2 — GERÇEK bir hatayla KEŞFEDİLDİ):
//! `resolveImportsImpl` (`resolveImports`/`resolveImportsFrom`/
//! `resolveProjectImports`nin TEK choke point'i, `core.nox`u KOŞULSUZ
//! birleştirdiğinden HER GERÇEK derlemede/LSP çağrısında çalışır) YENİ bir
//! `ast.Module` İNŞA EDER — `user_module.expr_spans`i BU YENİ modüle
//! TAŞIMAMAK, argüman span verisini SESSİZCE SIFIRLARDI. `tests/golden/
//! typecheck_golden_test.zig` `checker.check`i module_loader'a HİÇ
//! UĞRAMADAN (ham parser çıktısı üzerinde) çağırdığından bu hatayı ASLA
//! YAKALAYAMAZDI — bu dosya, module_loader'IN KENDİSİNİN ÜZERİNDEN GEÇEN
//! (`resolveImports`) TEK regresyon testidir.

const std = @import("std");
const nox = @import("nox");

test "resolveImports: bir çağrı argümanının span'ı module_loader birleştirmesinden SONRA da hayatta kalır" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    const source = "def bar() -> int:\n    return 1\n\ndef foo(x: int) -> int:\n    return x\n\nfoo(bar())\n";
    const tokens = try nox.lexer.tokenize(a, source);
    const user_module = try nox.parser.parseModule(a, tokens);

    // Ham parser çıktısında `foo(bar())`in argümanı ('bar()') İçin bir
    // span KAYITLI olmalı.
    try std.testing.expect(user_module.expr_spans.count() > 0);

    // module_loader ÜZERİNDEN geçir (core.nox KOŞULSUZ birleştirilir —
    // TAM OLARAK bu, hatayı üreten choke point'tir).
    const resolved = try nox.module_loader.resolveImports(a, io, user_module);

    // `foo(bar())` çağrısını YENİ (core.nox + user_module birleştirilmiş)
    // gövdede bul, argümanının ADRESİNİN (span anahtarı) HÂLÂ haritada
    // OLDUĞUNU doğrula.
    var found_span: ?nox.span.Span = null;
    for (resolved.body) |stmt| {
        if (stmt.kind != .expr_stmt) continue;
        if (stmt.kind.expr_stmt != .call) continue;
        const call = stmt.kind.expr_stmt.call;
        if (call.callee.* != .identifier or !std.mem.eql(u8, call.callee.identifier, "foo")) continue;
        if (call.args.len != 1) continue;
        found_span = resolved.expr_spans.get(@intFromPtr(&call.args[0]));
    }
    try std.testing.expect(found_span != null);
    try std.testing.expect(!found_span.?.isNone());
}
