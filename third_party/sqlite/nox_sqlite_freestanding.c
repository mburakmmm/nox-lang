/* v2.0.146: wasm32-freestanding için tek çeviri birimi. Zig, bir `addObject`e birden çok C dosyası verilince yalnızca birini nesneye yazar; bu yüzden amalgamation ile
 * işletim sistemi katmanı (`nox_sqlite_os_free.c`) tek dosyada birleştirilir. */
#include "sqlite3.c"
#include "nox_sqlite_os_free.c"
