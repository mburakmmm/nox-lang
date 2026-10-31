//! `stdout`u boşaltır. `fflush(NULL)` (tüm akımlar) yerine kullanılır: Bionic'te (Android) `fflush(NULL)` her akımı kilitler ve başka bir iş parçacığı `getaddrinfo` içindeyken
//! (resolver `/etc/hosts` akımını sorgu boyunca tutar) DNS bitene kadar bloke olur; bir `print` ya da çalışma zamanı kapanışı DNS süresi (10 sn+) kadar takılırdı (v2.0.91, mobil ağ
//! matrisinde bulundu). Nox yalnızca `stdout`a yazan stdio kullanır; `stderr` zaten tamponsuzdur.

const std = @import("std");
const builtin = @import("builtin");

const crt = struct {
    extern "c" fn fflush(stream: ?*anyopaque) c_int;
};

pub fn flushStdout() void {
    if (comptime (builtin.os.tag == .freestanding or builtin.os.tag == .other or builtin.os.tag == .wasi)) return;
    if (comptime builtin.os.tag == .windows) {
        // Windows CRT'sinde `stdout` bir makrodur (`__acrt_iob_func(1)`); burada tüm akımları boşaltmak zararsızdır (DNS kilidi sorunu bionic'e özgüdür).
        _ = crt.fflush(null);
        return;
    }
    const sym = comptime if (builtin.os.tag.isDarwin()) "__stdoutp" else "stdout";
    const stdout_ptr = @extern(*const ?*anyopaque, .{ .name = sym });
    _ = crt.fflush(stdout_ptr.*);
}
