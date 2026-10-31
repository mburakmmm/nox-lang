/* Faz 3.7 sandbox probe sürücüsü: Nox programı (tests/golden/mobile_sandbox_probe.nox) `nox_app_start` sırasında çalışır.
 * NOX_SBX_FSIZE (bayt) verilirse dosya boyutu sınırı kurulur (RLIMIT_FSIZE) ve SIGXFSZ yok sayılır: büyük yazma EFBIG ile başarısız olur (disk-dolu benzetimi). */
#include "nox_embed.h"
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>

int main(void) {
    const char *dir = getenv("NOX_MOBILE_ROOT");
    const char *fsize = getenv("NOX_SBX_FSIZE");
    NoxEmbedSlot slot = {NOX_EMBED_ABI, 0};
    NoxHostConfig cfg;
    void *app = 0;
    if (dir == 0 || dir[0] == 0) return 9;
    if (fsize != 0 && fsize[0] != 0) {
        struct rlimit rl;
        signal(SIGXFSZ, SIG_IGN);
        rl.rlim_cur = rl.rlim_max = (rlim_t)strtoull(fsize, 0, 10);
        if (setrlimit(RLIMIT_FSIZE, &rl) != 0) return 21;
    }
    if (mkdir(dir, 0700) != 0 && errno != EEXIST) return 19;
    memset(&cfg, 0, sizeof(cfg));
    cfg.size = sizeof(cfg);
    cfg.abi_version = NOX_EMBED_ABI;
    cfg.slot = &slot;
    cfg.documents = dir;
    cfg.support = dir;
    cfg.cache = dir;
    cfg.temp_dir = dir;
    if (nox_app_create(&cfg, &app) != 0 || app == 0) return 10;
    nox_embed_bind(app);
    if (nox_app_start(app) != 0) return 11;
    if (nox_app_destroy(slot.app) != 0) return 15;
    return 0;
}
