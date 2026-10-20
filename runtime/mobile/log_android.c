#include <android/log.h>

void nox_host_log_debug(const char *msg) {
    if (msg == 0) return;
    __android_log_write(ANDROID_LOG_INFO, "nox", msg);
}
