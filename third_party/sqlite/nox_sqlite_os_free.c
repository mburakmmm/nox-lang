/*
** wasm32-freestanding için SQLite OS katmanı (SQLITE_OS_OTHER=1): dosya sistemi yok, yalnızca bellek içi veritabanları (":memory:" ve geçici
** veritabanları; SQLITE_TEMP_STORE=3). Dosya açmak SQLITE_CANTOPEN döner, yani `nox.sqlite.open("x.db")` temiz bir hata verir.
** Rastgelelik ve saat, çalışma zamanı üzerinden host'a (nox_host.random_fill / clock_ms) bağlanır (runtime/wasm_libc_sqlite.zig).
** Gerekçe ve bağlam: nox-teknik-spesifikasyon.md §3.348.
*/
#include "sqlite3.h"
#include <string.h>

extern int nox_sqlite_rt_random(void *buf, int n);
extern long long nox_sqlite_rt_now_ms(void);

static int noxOpen(sqlite3_vfs *vfs, sqlite3_filename name, sqlite3_file *file, int flags, int *outFlags) {
  (void)vfs; (void)name; (void)file; (void)flags; (void)outFlags;
  return SQLITE_CANTOPEN;
}

static int noxDelete(sqlite3_vfs *vfs, const char *name, int syncDir) {
  (void)vfs; (void)name; (void)syncDir;
  return SQLITE_OK;
}

static int noxAccess(sqlite3_vfs *vfs, const char *name, int flags, int *res) {
  (void)vfs; (void)name; (void)flags;
  *res = 0;
  return SQLITE_OK;
}

static int noxFullPathname(sqlite3_vfs *vfs, const char *name, int n, char *out) {
  (void)vfs;
  int i = 0;
  while (i < n - 1 && name[i]) { out[i] = name[i]; i++; }
  out[i] = 0;
  return SQLITE_OK;
}

static int noxRandomness(sqlite3_vfs *vfs, int n, char *buf) {
  (void)vfs;
  return nox_sqlite_rt_random(buf, n);
}

static int noxSleep(sqlite3_vfs *vfs, int microseconds) {
  (void)vfs;
  return microseconds;
}

static int noxCurrentTimeInt64(sqlite3_vfs *vfs, sqlite3_int64 *out) {
  (void)vfs;
  /* Julian gün sayısı milisaniye cinsinden: Unix epoch = 2440587.5 gün = 210866760000000 ms. */
  *out = 210866760000000LL + (sqlite3_int64)nox_sqlite_rt_now_ms();
  return SQLITE_OK;
}

static int noxGetLastError(sqlite3_vfs *vfs, int n, char *buf) {
  (void)vfs; (void)n; (void)buf;
  return 0;
}

static sqlite3_vfs noxVfs = {
  2,                       /* iVersion */
  (int)sizeof(sqlite3_file), /* szOsFile: xOpen hiçbir zaman başarılı olmaz */
  512,                     /* mxPathname */
  0,                       /* pNext */
  "nox-mem",               /* zName */
  0,                       /* pAppData */
  noxOpen,
  noxDelete,
  noxAccess,
  noxFullPathname,
  0, 0, 0, 0,              /* xDlOpen, xDlError, xDlSym, xDlClose */
  noxRandomness,
  noxSleep,
  0,                       /* xCurrentTime (v2'de xCurrentTimeInt64 tercih edilir) */
  noxGetLastError,
  noxCurrentTimeInt64,
};

int sqlite3_os_init(void) {
  return sqlite3_vfs_register(&noxVfs, 1);
}

int sqlite3_os_end(void) {
  return SQLITE_OK;
}
