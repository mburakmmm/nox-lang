#include "nox_embed.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Mobil korpus ana programu (scripts/mobile_corpus.py): gömme ABI ile çalışma zamanını başlatır ve Nox'un üst düzey ifadelerini (kullanıcı girişi) çalıştırır.
 * Çalışma dizini NOX_MOBILE_ROOT'tur; geçici dizin kökü NOX_MOBILE_TEMP'tir (varsayılan: aynı dizin). Kök politikası gevşetilmez: ana program yalnızca hangi dizinlerin uygulama kökü sayıldığını bildirir. Çıkış kodu: 0 başarı, 10-13 başlatma hatası, 20+rc `nox_app_start` hatası. */
int main(void) {
    const char *dir = getenv("NOX_MOBILE_ROOT");
    const char *tmp = getenv("NOX_MOBILE_TEMP");
    NoxEmbedSlot slot = {NOX_EMBED_ABI, 0};
    NoxHostConfig cfg;
    void *app = 0;
    int rc;
    if (dir == 0 || dir[0] == 0) dir = "/tmp/nox-corpus-root";
    if (tmp == 0 || tmp[0] == 0) tmp = dir; /* uygulamanın "geçici dizin" kökü: korpus fixture'ları mutlak /tmp yolları kullanır */
    mkdir(dir, 0700);
    if (chdir(dir) != 0) return 9;
    memset(&cfg, 0, sizeof(cfg));
    cfg.size = sizeof(cfg);
    cfg.abi_version = NOX_EMBED_ABI;
    cfg.slot = &slot;
    cfg.documents = dir;
    cfg.support = dir;
    cfg.cache = dir;
    cfg.temp_dir = tmp;
    if (nox_app_create(&cfg, &app) != 0 || app == 0) return 10;
    nox_embed_bind(app);
    rc = nox_app_start(app);
    fflush(stdout);
    return rc == 0 ? 0 : 20 + rc;
}
