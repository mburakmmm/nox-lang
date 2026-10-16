const std = @import("std");
const context = @import("context.zig");

test "HPyContext ofsetleri sampleext.c ile kilitli" {
    if (@sizeOf(usize) != 8) return;
    try std.testing.expectEqual(@as(usize, 352), @offsetOf(context.HPyContext, "h_ValueError"));
    try std.testing.expectEqual(@as(usize, 640), @offsetOf(context.HPyContext, "ctx_Dup"));
    try std.testing.expectEqual(@as(usize, 648), @offsetOf(context.HPyContext, "ctx_Close"));
    try std.testing.expectEqual(@as(usize, 672), @offsetOf(context.HPyContext, "ctx_Long_FromInt64_t"));
    try std.testing.expectEqual(@as(usize, 728), @offsetOf(context.HPyContext, "ctx_Long_AsInt64_t"));
    try std.testing.expectEqual(@as(usize, 1120), @offsetOf(context.HPyContext, "ctx_Err_SetString"));
    try std.testing.expectEqual(@as(usize, 1224), @offsetOf(context.HPyContext, "ctx_Type_FromSpec"));
    try std.testing.expectEqual(@as(usize, 1280), @offsetOf(context.HPyContext, "ctx_SetAttr_s"));
    try std.testing.expectEqual(@as(usize, 1384), @offsetOf(context.HPyContext, "ctx_New"));
    try std.testing.expectEqual(@as(usize, 1368), @offsetOf(context.HPyContext, "ctx_AsStruct_Object"));
    // LP64'te `c_ulong` 8 bayt, `HPyType_Spec` 56 bayt. LLP64'te (Windows)
    // `c_ulong` 4 bayt ve doğal dolgu ile boyut 48'dir.
    const spec_size: usize = if (@sizeOf(c_ulong) == 8) 56 else 48;
    try std.testing.expectEqual(spec_size, @sizeOf(context.HPyType_Spec));
    try std.testing.expectEqual(@as(usize, 1496), @offsetOf(context.HPyContext, "ctx_Bytes_FromStringAndSize"));
    try std.testing.expectEqual(@as(usize, 1472), @offsetOf(context.HPyContext, "ctx_Bytes_AsString"));
    try std.testing.expectEqual(@as(usize, 1456), @offsetOf(context.HPyContext, "ctx_Bytes_Size"));
    try std.testing.expectEqual(@as(usize, 1504), @offsetOf(context.HPyContext, "ctx_Unicode_FromString"));
    try std.testing.expectEqual(@as(usize, 1656), @offsetOf(context.HPyContext, "ctx_Tuple_FromArray"));
}
