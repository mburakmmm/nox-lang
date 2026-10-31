/* Faz 3.5 yığın/TLS probe sürücüsü: Nox programı (tests/golden/mobile_stack_probe.nox) `nox_app_start` sırasında `NOX_STACK_MODE` moduna göre çalışır. */
#include "nox_embed.h"
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

int main(void) {
    const char *dir = getenv("NOX_MOBILE_ROOT");
    NoxEmbedSlot slot = {NOX_EMBED_ABI, 0};
    NoxHostConfig cfg;
    void *app = 0;
    if (dir == 0 || dir[0] == 0) return 9;
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
    fprintf(stderr, "stack probe returned\n");
    if (nox_app_destroy(slot.app) != 0) return 15;
    return 0;
}
