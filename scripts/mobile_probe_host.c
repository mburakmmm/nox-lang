#include "nox_embed.h"
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

extern int64_t smtp_link(void *rt);

int main(void) {
    const char *dir = getenv("NOX_MOBILE_ROOT");
    NoxEmbedSlot slot = {NOX_EMBED_ABI, 0};
    NoxHostConfig cfg;
    void *app = 0;
    void *rt = 0;
    char path[512];
    char buf[16];
    FILE *f = 0;
    int32_t pending = 0;
    if (dir == 0 || dir[0] == 0) return 9;
    volatile void *keep = (void *)smtp_link;
    if (keep == 0) return 8;
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
    rt = nox_app_runtime(app);
    if (rt == 0) return 12;
    pending = nox_exception_pending(rt);
    snprintf(path, sizeof(path), "%s/probe.txt", dir);
    f = fopen(path, "r");
    if (f == 0) {
        fprintf(stderr, "probe missing pending %d\n", pending);
        return 17;
    }
    if (fgets(buf, (int)sizeof(buf), f) == 0) {
        fclose(f);
        return 18;
    }
    fclose(f);
    fprintf(stderr, "probe %s pending %d\n", buf, pending);
    if (pending) return 20;
    if (buf[0] != '0') return 30 + (buf[0] - '0');
    if (nox_app_destroy(slot.app) != 0) return 15;
    return 0;
}
