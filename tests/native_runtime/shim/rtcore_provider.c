/* rtcore_provider.c — hosted (POSIX) platform provider for the bootstrap allocator spike (readiness R3).
 * Link-time provider: rtcore_os_map / rtcore_os_unmap / rtcore_fatal. Nox runtime YOK; libc yalniz mmap/munmap/write/_exit.
 * Fault injection: g_fail_after = N -> N basarili map'ten SONRA her map 0 (OOM) doner (-1 = kapali).
 * Ledger: g_mapped_bytes (canli), g_map_calls. rtcore_fatal TAHSISSIZ (write + _exit(80+code)); kod -> sabit mesaj. */
#include <stdint.h>
#include <sys/mman.h>
#include <unistd.h>
typedef int64_t w;
long g_fail_after = -1;
long g_mapped_bytes = 0;
long g_map_calls = 0;
w rtcore_os_map(w size) {
    if (size <= 0) return 0;
    if (g_fail_after == 0) return 0;
    if (g_fail_after > 0) g_fail_after--;
    void *p = mmap(0, (size_t)size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) return 0;
    g_mapped_bytes += size; g_map_calls++;
    return (w)(intptr_t)p;
}
void rtcore_os_unmap(w addr, w size) {
    if (munmap((void *)(intptr_t)addr, (size_t)size) == 0) g_mapped_bytes -= size;
}
void rtcore_fatal(w code) {
    static const char m0[] = "fatal: runtime-core error code ";
    char d[3] = {(char)('0' + (code / 10) % 10), (char)('0' + code % 10), '\n'};
    write(2, m0, sizeof m0 - 1); write(2, d, 3);
    _exit((int)(80 + code));
}
