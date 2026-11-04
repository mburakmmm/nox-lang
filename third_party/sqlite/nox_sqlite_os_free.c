/*
** wasm32-freestanding için SQLite OS katmanı (SQLITE_OS_OTHER=1): işletim sistemi yok; dosyalar çalışma zamanının bellek içi sanal dosya sisteminde
** (runtime/wasm_vfs.zig) yaşar, `nox_vfs_*` köprüleri üzerinden (runtime/wasm_libc_sqlite.zig). ":memory:" ve geçici veritabanları (SQLITE_TEMP_STORE=3)
** SQLite'ın kendi belleğindedir. Kilitleme yoktur (tek süreç; iş parçacıkları nox.sqlite'ın kendi kilidiyle seri hale getirilir).
** Rastgelelik ve saat, çalışma zamanı üzerinden host'a (nox_host.random_fill / clock_ms) bağlanır.
** Gerekçe ve bağlam: nox-teknik-spesifikasyon.md §3.348, §3.349.
*/
#include "sqlite3.h"
#include <string.h>

extern int nox_sqlite_rt_random(void *buf, int n);
extern long long nox_sqlite_rt_now_ms(void);

extern int nox_vfs_open(const char *path, int mode);
extern void nox_vfs_close(int fd);
extern int nox_vfs_pread(int fd, void *buf, int n, long long off);
extern int nox_vfs_pwrite(int fd, const void *buf, int n, long long off);
extern int nox_vfs_truncate(int fd, long long size);
extern long long nox_vfs_size(int fd);
extern int nox_vfs_remove(const char *path);
extern int nox_vfs_exists(const char *path);

typedef struct NoxFile {
  sqlite3_file base;
  int fd;
  int deleteOnClose;
  const char *zName;
  char tmpName[48];
} NoxFile;

static int noxClose(sqlite3_file *f) {
  NoxFile *p = (NoxFile *)f;
  nox_vfs_close(p->fd);
  if (p->deleteOnClose && p->zName) nox_vfs_remove(p->zName);
  return SQLITE_OK;
}

static int noxRead(sqlite3_file *f, void *buf, int n, sqlite3_int64 off) {
  NoxFile *p = (NoxFile *)f;
  int got = nox_vfs_pread(p->fd, buf, n, off);
  if (got < 0) return SQLITE_IOERR_READ;
  if (got < n) {
    memset((char *)buf + got, 0, (size_t)(n - got));
    return SQLITE_IOERR_SHORT_READ;
  }
  return SQLITE_OK;
}

static int noxWrite(sqlite3_file *f, const void *buf, int n, sqlite3_int64 off) {
  NoxFile *p = (NoxFile *)f;
  return nox_vfs_pwrite(p->fd, buf, n, off) == n ? SQLITE_OK : SQLITE_IOERR_WRITE;
}

static int noxTruncate(sqlite3_file *f, sqlite3_int64 size) {
  return nox_vfs_truncate(((NoxFile *)f)->fd, size) == 0 ? SQLITE_OK : SQLITE_IOERR_TRUNCATE;
}

static int noxSync(sqlite3_file *f, int flags) { (void)f; (void)flags; return SQLITE_OK; }

static int noxFileSize(sqlite3_file *f, sqlite3_int64 *out) {
  long long sz = nox_vfs_size(((NoxFile *)f)->fd);
  if (sz < 0) return SQLITE_IOERR_FSTAT;
  *out = sz;
  return SQLITE_OK;
}

static int noxLock(sqlite3_file *f, int level) { (void)f; (void)level; return SQLITE_OK; }
static int noxUnlock(sqlite3_file *f, int level) { (void)f; (void)level; return SQLITE_OK; }
static int noxCheckReservedLock(sqlite3_file *f, int *res) { (void)f; *res = 0; return SQLITE_OK; }
static int noxFileControl(sqlite3_file *f, int op, void *arg) { (void)f; (void)op; (void)arg; return SQLITE_NOTFOUND; }
static int noxSectorSize(sqlite3_file *f) { (void)f; return 4096; }
static int noxDeviceCharacteristics(sqlite3_file *f) { (void)f; return 0; }

static const sqlite3_io_methods noxIoMethods = {
  1, noxClose, noxRead, noxWrite, noxTruncate, noxSync, noxFileSize, noxLock, noxUnlock, noxCheckReservedLock,
  noxFileControl, noxSectorSize, noxDeviceCharacteristics,
};

static unsigned int g_tmpCounter = 0;

static int noxOpen(sqlite3_vfs *vfs, sqlite3_filename name, sqlite3_file *file, int flags, int *outFlags) {
  NoxFile *p = (NoxFile *)file;
  (void)vfs;
  p->base.pMethods = 0;
  p->deleteOnClose = (flags & SQLITE_OPEN_DELETEONCLOSE) != 0;
  const char *path = name;
  if (!path) {
    /* Adsız geçici dosya: benzersiz ad, kapanınca silinir. */
    unsigned int n = ++g_tmpCounter;
    char *o = p->tmpName;
    const char *pre = "/tmp/nox-sqlite-";
    while (*pre) *o++ = *pre++;
    char digits[12]; int d = 0;
    do { digits[d++] = (char)('0' + n % 10); n /= 10; } while (n && d < 11);
    while (d) *o++ = digits[--d];
    *o = 0;
    path = p->tmpName;
    p->deleteOnClose = 1;
  }
  p->zName = path;
  int exists = nox_vfs_exists(path);
  int create = (flags & SQLITE_OPEN_CREATE) != 0;
  if ((flags & SQLITE_OPEN_EXCLUSIVE) && create && exists) return SQLITE_CANTOPEN;
  if (!exists && !create) return SQLITE_CANTOPEN;
  int mode = (flags & SQLITE_OPEN_READWRITE) ? 3 : 0;
  int fd = nox_vfs_open(path, mode);
  if (fd < 0) return SQLITE_CANTOPEN;
  p->fd = fd;
  p->base.pMethods = &noxIoMethods;
  if (outFlags) *outFlags = (flags & SQLITE_OPEN_READWRITE) ? (flags & ~SQLITE_OPEN_READONLY) : flags;
  return SQLITE_OK;
}

static int noxDelete(sqlite3_vfs *vfs, const char *name, int syncDir) {
  (void)vfs; (void)syncDir;
  return nox_vfs_remove(name) == 0 ? SQLITE_OK : SQLITE_IOERR_DELETE_NOENT;
}

static int noxAccess(sqlite3_vfs *vfs, const char *name, int flags, int *res) {
  (void)vfs; (void)flags;
  *res = nox_vfs_exists(name);
  return SQLITE_OK;
}

static int noxFullPathname(sqlite3_vfs *vfs, const char *name, int n, char *out) {
  (void)vfs;
  int i = 0;
  if (name[0] != '/' && n > 1) out[i++] = '/'; /* göreli yollar kök altında çözülür (sanal dosya sistemi) */
  int j = 0;
  while (i < n - 1 && name[j]) { out[i++] = name[j++]; }
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
  (int)sizeof(NoxFile),    /* szOsFile */
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
