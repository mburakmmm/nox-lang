//! Faz 10 (WASM, ADR-015): iş parçacıklı wasi'de `printf`. wasi-libc'nin stdio'su tek iş parçacıklıdır (kilit yok, tampon ortak): çok iş parçacığı aynı anda yazdırırsa
//! tampon bozulur. Bu `printf` her çağrıyı biçimler ve WASI `fd_write(1)` ile bir kilit altında TEK parça yazar (yerel libc'nin çağrı başına stdio kilidine denk). `print`
//! başına birden çok `printf` parçası olabilir; parçalar arası sıra iş parçacıkları arasında serbesttir (yerel LLVM/M:N ile aynı).

const std = @import("std");
const wasm_printf = @import("wasm_printf.zig");

var lock_state: std.atomic.Value(u32) = .init(0);

fn futexWait(ptr: *const u32, expected: u32) void {
    const exp: i32 = @bitCast(expected);
    _ = asm volatile ("local.get %[ptr]\nlocal.get %[exp]\ni64.const -1\nmemory.atomic.wait32 0\nlocal.set %[ret]"
        : [ret] "=r" (-> u32),
        : [ptr] "r" (ptr),
          [exp] "r" (exp),
        : .{ .memory = true });
}

fn futexWake(ptr: *const u32) void {
    _ = asm volatile ("local.get %[ptr]\ni32.const 1\nmemory.atomic.notify 0\nlocal.set %[ret]"
        : [ret] "=r" (-> u32),
        : [ptr] "r" (ptr),
        : .{ .memory = true });
}

fn emit(bytes: []const u8) void {
    while (lock_state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) futexWait(&lock_state.raw, 1);
    defer {
        lock_state.store(0, .release);
        futexWake(&lock_state.raw);
    }
    var off: usize = 0;
    while (off < bytes.len) {
        var iov = [_]std.os.wasi.ciovec_t{.{ .base = bytes.ptr + off, .len = bytes.len - off }};
        var n: usize = 0;
        if (std.os.wasi.fd_write(1, &iov, 1, &n) != .SUCCESS or n == 0) return;
        off += n;
    }
}

export fn printf(fmt: ?[*:0]const u8, ...) callconv(.c) c_int {
    const f = fmt orelse return 0;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return @intCast(wasm_printf.printfImpl(emit, f, &ap));
}
