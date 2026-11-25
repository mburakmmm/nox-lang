/* UR-003: AYNI kaynaktan, farklı modül adlarıyla derlenmiş iki bağımsız Nox kütüphanesi bir süreçte yan yana yaşar: her biri kendi çalışma zamanı kopyasına/globaline sahiptir,
 * `nox_host_*` dışında sembol sızmaz (Python eklentileri gibi RTLD_LOCAL). Kullanım: host_dl <libma> <libmb> */
#include "nox_host.h"
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

typedef NoxHostStatus (*create_fn)(const NoxHostContextConfig *, NoxHostContext **);
typedef void (*destroy_fn)(NoxHostContext *);
typedef NoxHostStatus (*init_fn)(NoxHostContext *, NoxHostError **);
typedef void (*fini_fn)(NoxHostContext *);
typedef NoxHostStatus (*bump_fn)(NoxHostContext *, int64_t *, NoxHostError **);
typedef NoxHostStatus (*add_fn)(NoxHostContext *, int64_t, int64_t, int64_t *, NoxHostError **);

static int fails = 0;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)

typedef struct { void *h; create_fn create; destroy_fn destroy; init_fn init; fini_fn fini; bump_fn bump; add_fn add; NoxHostContext *ctx; } Lib;

static int load(Lib *l, const char *path, const char *mod) {
    char name[96];
    l->h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!l->h) { printf("dlopen: %s\n", dlerror()); return 1; }
    l->create = (create_fn)dlsym(l->h, "nox_host_context_create");
    l->destroy = (destroy_fn)dlsym(l->h, "nox_host_context_destroy");
    snprintf(name, sizeof name, "nox_host_module_init_%s", mod); l->init = (init_fn)dlsym(l->h, name);
    snprintf(name, sizeof name, "nox_host_module_fini_%s", mod); l->fini = (fini_fn)dlsym(l->h, name);
    snprintf(name, sizeof name, "nox_host_export_%s_bump", mod); l->bump = (bump_fn)dlsym(l->h, name);
    snprintf(name, sizeof name, "nox_host_export_%s_add", mod); l->add = (add_fn)dlsym(l->h, name);
    return !(l->create && l->destroy && l->init && l->fini && l->bump && l->add);
}

int main(int argc, char **argv) {
    Lib a, b;
    if (argc < 3 || load(&a, argv[1], "ma") || load(&b, argv[2], "mb")) { printf("FAIL: load\n"); return 1; }
    NoxHostContextConfig cfg = { sizeof cfg, NOX_HOST_ABI_VERSION, NULL };
    NoxHostError *e = NULL; int64_t r = 0;
    CHECK(a.create(&cfg, &a.ctx) == NOX_HOST_OK && b.create(&cfg, &b.ctx) == NOX_HOST_OK);
    CHECK(a.init(a.ctx, &e) == NOX_HOST_OK && b.init(b.ctx, &e) == NOX_HOST_OK);
    /* iki modülün `counter` globali birbirinden bağımsız */
    CHECK(a.bump(a.ctx, &r, &e) == NOX_HOST_OK && r == 1);
    CHECK(a.bump(a.ctx, &r, &e) == NOX_HOST_OK && r == 2);
    CHECK(b.bump(b.ctx, &r, &e) == NOX_HOST_OK && r == 1);
    CHECK(a.bump(a.ctx, &r, &e) == NOX_HOST_OK && r == 3);
    CHECK(b.add(b.ctx, 40, 2, &r, &e) == NOX_HOST_OK && r == 42);
    /* `nox_host_*` dışında çalışma zamanı sembolü sızmaz */
    CHECK(dlsym(a.h, "nox_alloc") == NULL && dlsym(a.h, "nox_runtime_init") == NULL && dlsym(b.h, "add") == NULL);
    a.fini(a.ctx); b.fini(b.ctx);
    a.destroy(a.ctx); b.destroy(b.ctx);
    printf(fails ? "FAILED (%d)\n" : "ALL OK\n", fails);
    return fails != 0;
}
