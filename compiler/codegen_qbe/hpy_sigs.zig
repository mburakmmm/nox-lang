//! HPy runtime sembollerinin TEK imza tablosu. QBE ve LLVM aynı
//! `qbeCall` kapısından geçer; tablo dışı bir `$nox_hpy_*` çağrısı
//! derleme hatasıdır. Dönüş genişliği de buradan gelir: işaretçi
//! dönüşü `l` (i64) kalır, LLVM bunu `i32` sanmaz.

const std = @import("std");
const types = @import("types.zig");

const QbeType = types.QbeType;

pub const Ret = union(enum) {
    void,
    value: QbeType,
};

const Sig = struct {
    symbol: []const u8,
    ret: Ret,
};

const table = [_]Sig{
    .{ .symbol = "$nox_hpy_take_error", .ret = .{ .value = .l } },
    .{ .symbol = "$nox_hpy_args_add_handle", .ret = .void },
    .{ .symbol = "$nox_hpy_args_add_str", .ret = .void },
    .{ .symbol = "$nox_hpy_args_add_list_scalar", .ret = .void },
    .{ .symbol = "$nox_hpy_args_add_dict_scalar", .ret = .void },
    .{ .symbol = "$nox_hpy_class_arg_begin", .ret = .void },
    .{ .symbol = "$nox_hpy_class_arg_set_str", .ret = .void },
    .{ .symbol = "$nox_hpy_class_arg_set_int", .ret = .void },
    .{ .symbol = "$nox_hpy_class_arg_set_float", .ret = .void },
    .{ .symbol = "$nox_hpy_class_arg_set_bool", .ret = .void },
    .{ .symbol = "$nox_hpy_class_arg_end", .ret = .void },
    .{ .symbol = "$nox_hpy_args_add_int", .ret = .void },
    .{ .symbol = "$nox_hpy_args_add_float", .ret = .void },
    .{ .symbol = "$nox_hpy_args_add_bool", .ret = .void },
    .{ .symbol = "$nox_hpy_call", .ret = .{ .value = .l } },
    .{ .symbol = "$nox_hpy_call_str", .ret = .{ .value = .l } },
    .{ .symbol = "$nox_hpy_open", .ret = .{ .value = .l } },
    .{ .symbol = "$nox_hpy_args_begin", .ret = .{ .value = .l } },
    .{ .symbol = "$nox_hpy_call_int_finish", .ret = .{ .value = .l } },
    .{ .symbol = "$nox_hpy_call_float_finish", .ret = .{ .value = .d } },
    .{ .symbol = "$nox_hpy_call_bool_finish", .ret = .{ .value = .w } },
    .{ .symbol = "$nox_hpy_call_obj_finish", .ret = .{ .value = .l } },
    .{ .symbol = "$nox_hpy_call_str_finish", .ret = .{ .value = .l } },
    .{ .symbol = "$nox_hpy_close", .ret = .void },
    .{ .symbol = "$nox_hpy_close_obj", .ret = .void },
    .{ .symbol = "$nox_hpy_new_finish", .ret = .{ .value = .l } },
    .{ .symbol = "$nox_hpy_getattr_int", .ret = .{ .value = .l } },
    .{ .symbol = "$nox_hpy_setattr_int", .ret = .void },
    .{ .symbol = "$nox_hpy_args_begin_for_obj", .ret = .{ .value = .l } },
    .{ .symbol = "$nox_hpy_call_attr_int_finish", .ret = .{ .value = .l } },
    .{ .symbol = "$nox_hpy_new_object", .ret = .{ .value = .l } },
    .{ .symbol = "$nox_hpy_getitem_int", .ret = .{ .value = .l } },
    .{ .symbol = "$nox_hpy_new_string_writer", .ret = .{ .value = .l } },
    .{ .symbol = "$nox_hpy_writer_get_str", .ret = .{ .value = .l } },
    .{ .symbol = "$nox_hpy_new_string_reader", .ret = .{ .value = .l } },
    .{ .symbol = "$nox_hpy_open_package", .ret = .{ .value = .l } },
    .{ .symbol = "$nox_hpy_package_allow", .ret = .{ .value = .w } },
    .{ .symbol = "$nox_hpy_package_allow_kw", .ret = .{ .value = .w } },
    .{ .symbol = "$nox_hpy_package_check_str", .ret = .void },
    .{ .symbol = "$nox_hpy_package_check_float", .ret = .void },
    .{ .symbol = "$nox_hpy_package_close_obj", .ret = .void },
    .{ .symbol = "$nox_hpy_args_add_bytes", .ret = .void },
    .{ .symbol = "$nox_hpy_call_bytes_finish", .ret = .{ .value = .l } },
    .{ .symbol = "$nox_hpy_call_int_keyword_finish", .ret = .{ .value = .l } },
};

pub fn declared(symbol: []const u8) bool {
    for (table) |sig| {
        if (std.mem.eql(u8, sig.symbol, symbol)) return true;
    }
    return false;
}

pub fn require(symbol: []const u8, ret: ?QbeType) error{HpySignature}!void {
    for (table) |sig| {
        if (!std.mem.eql(u8, sig.symbol, symbol)) continue;
        switch (sig.ret) {
            .void => if (ret == null) return else return error.HpySignature,
            .value => |expected| {
                const got = ret orelse return error.HpySignature;
                if (got != expected) return error.HpySignature;
                return;
            },
        }
    }
    return error.HpySignature;
}

test "tablo dışı HPy sembolü derleme hatasıdır" {
    try require("$nox_hpy_take_error", .l);
    try std.testing.expectError(error.HpySignature, require("$nox_hpy_take_error", .w));
    try std.testing.expectError(error.HpySignature, require("$nox_hpy_not_a_symbol", .l));
    try require("$nox_hpy_close", null);
}

test "calls.zig içindeki her HPy dizgesi tablodadır" {
    const src = @embedFile("calls.zig");
    var i: usize = 0;
    var seen: usize = 0;
    while (std.mem.indexOfPos(u8, src, i, "\"$nox_hpy_")) |pos| {
        const start = pos + 1;
        const end = std.mem.indexOfScalarPos(u8, src, start, '"') orelse return error.Unclosed;
        const sym = src[start..end];
        try std.testing.expect(declared(sym));
        seen += 1;
        i = end + 1;
    }
    try std.testing.expect(seen > 20);
}
