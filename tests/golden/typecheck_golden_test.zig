//! Tip denetleyici golden testleri: `tests/golden/typecheck_cases/*.nox`
//! kaynaklarını denetleyip sonucu (`OK` ya da `HATA <kod>: <mesaj>`)
//! `*.expected` ile karşılaştırır. AGENTS.md İlke #7.

const std = @import("std");
const nox = @import("nox");

fn expectGolden(comptime source: []const u8, comptime expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    switch (nox.checker.check(allocator, module)) {
        .ok => try aw.writer.writeAll("OK\n"),
        .err => |e| try aw.writer.print("HATA {t}: {s}\n", .{ e.code, e.message }),
    }

    try std.testing.expectEqualStrings(expected, aw.written());
}

test "golden(typecheck): aritmetik ve kontrol akışı" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_arith_and_control_flow.nox"),
        @embedFile("typecheck_cases/ok_arith_and_control_flow.expected"),
    );
}

test "golden(typecheck): fonksiyon ve sınıf" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_function_and_class.nox"),
        @embedFile("typecheck_cases/ok_function_and_class.expected"),
    );
}

test "golden(typecheck): liste ve indeksleme" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_list_and_index.nox"),
        @embedFile("typecheck_cases/ok_list_and_index.expected"),
    );
}

test "golden(typecheck): var_decl tip uyuşmazlığı" {
    try expectGolden(
        @embedFile("typecheck_cases/err_var_decl_mismatch.nox"),
        @embedFile("typecheck_cases/err_var_decl_mismatch.expected"),
    );
}

test "golden(typecheck): tanımsız değişken" {
    try expectGolden(
        @embedFile("typecheck_cases/err_undefined_variable.nox"),
        @embedFile("typecheck_cases/err_undefined_variable.expected"),
    );
}

test "golden(typecheck): argüman sayısı uyuşmazlığı" {
    try expectGolden(
        @embedFile("typecheck_cases/err_arg_count_mismatch.nox"),
        @embedFile("typecheck_cases/err_arg_count_mismatch.expected"),
    );
}

test "golden(typecheck): bool olmayan koşul" {
    try expectGolden(
        @embedFile("typecheck_cases/err_condition_not_bool.nox"),
        @embedFile("typecheck_cases/err_condition_not_bool.expected"),
    );
}

test "golden(typecheck): tanımsız sınıf alanı" {
    try expectGolden(
        @embedFile("typecheck_cases/err_undefined_attribute.nox"),
        @embedFile("typecheck_cases/err_undefined_attribute.expected"),
    );
}

test "golden(typecheck): range için geçersiz argüman" {
    try expectGolden(
        @embedFile("typecheck_cases/err_range_bad_arg.nox"),
        @embedFile("typecheck_cases/err_range_bad_arg.expected"),
    );
}

test "golden(typecheck): tüm yollarda return olmayan fonksiyon" {
    try expectGolden(
        @embedFile("typecheck_cases/err_missing_return.nox"),
        @embedFile("typecheck_cases/err_missing_return.expected"),
    );
}

test "golden(typecheck): raise/try/except/finally" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_raise_try_except.nox"),
        @embedFile("typecheck_cases/ok_raise_try_except.expected"),
    );
}

test "golden(typecheck): sınıf örneği olmayan bir şeyi raise etmek" {
    try expectGolden(
        @embedFile("typecheck_cases/err_raise_non_class.nox"),
        @embedFile("typecheck_cases/err_raise_non_class.expected"),
    );
}

test "golden(typecheck): lowlevel bloğu normal kurallarla denetlenir" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_lowlevel_block.nox"),
        @embedFile("typecheck_cases/ok_lowlevel_block.expected"),
    );
}

test "golden(typecheck): lowlevel içinde de tip uyuşmazlığı yakalanır" {
    try expectGolden(
        @embedFile("typecheck_cases/err_lowlevel_type_mismatch.nox"),
        @embedFile("typecheck_cases/err_lowlevel_type_mismatch.expected"),
    );
}

test "golden(typecheck): lowlevel içinde tanımlanan ad bloktan sonra kapsam dışı kalır" {
    try expectGolden(
        @embedFile("typecheck_cases/err_lowlevel_scope_leak.nox"),
        @embedFile("typecheck_cases/err_lowlevel_scope_leak.expected"),
    );
}

test "golden(typecheck): generic fonksiyon — birden çok somut tiple örnekleme" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_generic_function.nox"),
        @embedFile("typecheck_cases/ok_generic_function.expected"),
    );
}

test "golden(typecheck): generic tip parametresi çelişkili tiplere çözümlenirse hata" {
    try expectGolden(
        @embedFile("typecheck_cases/err_generic_conflicting_binding.nox"),
        @embedFile("typecheck_cases/err_generic_conflicting_binding.expected"),
    );
}

test "golden(typecheck): yalnızca dönüş tipinde kullanılan bir generic tip parametresi çıkarılamaz" {
    try expectGolden(
        @embedFile("typecheck_cases/err_generic_unresolved_param.nox"),
        @embedFile("typecheck_cases/err_generic_unresolved_param.expected"),
    );
}

test "golden(typecheck): metodlar generic olamaz" {
    try expectGolden(
        @embedFile("typecheck_cases/err_generic_method_rejected.nox"),
        @embedFile("typecheck_cases/err_generic_method_rejected.expected"),
    );
}

test "golden(typecheck): protokol — iki farklı sınıfla yapısal eşleşme + monomorphization" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_protocol_dispatch.nox"),
        @embedFile("typecheck_cases/ok_protocol_dispatch.expected"),
    );
}

test "golden(typecheck): protokolü karşılamayan (eksik metod) sınıf reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_protocol_missing_method.nox"),
        @embedFile("typecheck_cases/err_protocol_missing_method.expected"),
    );
}

test "golden(typecheck): protokol imzasıyla uyuşmayan (dönüş tipi) metod reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_protocol_signature_mismatch.nox"),
        @embedFile("typecheck_cases/err_protocol_signature_mismatch.expected"),
    );
}

test "golden(typecheck): protokol metodu yalnızca 'pass' gövdesine sahip olabilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_protocol_method_bad_body.nox"),
        @embedFile("typecheck_cases/err_protocol_method_bad_body.expected"),
    );
}

test "golden(typecheck): extern def (C ABI FFI bildirimi) normal fonksiyon gibi çağrılabilir" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_extern_def.nox"),
        @embedFile("typecheck_cases/ok_extern_def.expected"),
    );
}

test "golden(typecheck): extern def, C ABI'de güvenli olmayan (list[T]) bir parametre reddeder" {
    try expectGolden(
        @embedFile("typecheck_cases/err_extern_unsafe_param.nox"),
        @embedFile("typecheck_cases/err_extern_unsafe_param.expected"),
    );
}

test "golden(typecheck): async def + spawn + await + Channel[T].send/recv" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_async_spawn_await_channel.nox"),
        @embedFile("typecheck_cases/ok_async_spawn_await_channel.expected"),
    );
}

test "golden(typecheck): 'await', 'async def' dışında reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_await_outside_async.nox"),
        @embedFile("typecheck_cases/err_await_outside_async.expected"),
    );
}

test "golden(typecheck): 'spawn', async olmayan bir fonksiyonu reddeder" {
    try expectGolden(
        @embedFile("typecheck_cases/err_spawn_non_async.nox"),
        @embedFile("typecheck_cases/err_spawn_non_async.expected"),
    );
}

test "golden(typecheck): bir 'async def' fonksiyonu doğrudan (spawn'sız) çağrılamaz" {
    try expectGolden(
        @embedFile("typecheck_cases/err_call_async_directly.nox"),
        @embedFile("typecheck_cases/err_call_async_directly.expected"),
    );
}

test "golden(typecheck): extern def — opak ptr tipi (Faz 20 ikinci artım)" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_extern_ptr.nox"),
        @embedFile("typecheck_cases/ok_extern_ptr.expected"),
    );
}

test "golden(typecheck): __init__ içermeyen sınıf (alansız, yalnızca metod)" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_class_no_init.nox"),
        @embedFile("typecheck_cases/ok_class_no_init.expected"),
    );
}

test "golden(typecheck): 'obj.attr = değer' ataması self dışından, MEVCUT bir alana" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_attr_assign_external.nox"),
        @embedFile("typecheck_cases/ok_attr_assign_external.expected"),
    );
}

test "golden(typecheck): 'obj.attr = değer' self dışından YENİ bir alan tanımlayamaz" {
    try expectGolden(
        @embedFile("typecheck_cases/err_attr_assign_new_field_external.nox"),
        @embedFile("typecheck_cases/err_attr_assign_new_field_external.expected"),
    );
}

test "golden(typecheck): iki FARKLI sınıfı '==' ile karşılaştırmak reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_class_eq_type_mismatch.nox"),
        @embedFile("typecheck_cases/err_class_eq_type_mismatch.expected"),
    );
}
