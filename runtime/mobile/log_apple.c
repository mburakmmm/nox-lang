#include <os/log.h>

void nox_host_log_debug(const char *msg) {
    if (msg == 0) return;
    os_log(OS_LOG_DEFAULT, "%{public}s", msg);
}
