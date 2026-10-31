//! Sembol adlandırma politikası (v2.0.86): bir Nox üst-düzey `def`i nesne dosyasında düz adıyla (`$getenv`/`@getenv`) bir GLOBAL sembol olur. Aynı adı taşıyan bir libc/libm/POSIX
//! sembolü çalışma zamanı ya da üretilen kod tarafından çağrılıyorsa kullanıcı fonksiyonu onun yerine geçer: `def printf(...)` `print`i sessizce bozar, `def getenv(...)` çalışma
//! zamanının ortam okumasını ele geçirir, wasm'da imza uyuşmazlığı çağrıyı tuzağa düşürür. Politika: bu listedeki bir adı taşıyan kullanıcı fonksiyonunun SEMBOLÜ `nox_user_<ad>` olur
//! (Nox düzeyindeki ad değişmez; hata iletileri, `reflect`, yığın izleri eski adı gösterir). Liste TÜM standart C/POSIX/libm ad alanını kapsar (yalnızca bugün bağlanan semboller değil), çünkü
//! çalışma zamanı yarın yeni bir libc işlevine bağlanabilir. `scripts/check_reserved_symbols.py` çalışma zamanı nesnelerinin tanımsız (libc'den gelen) sembollerinin hepsinin bu listede olduğunu
//! doğrular; `tests/golden/codegen_cases/reserved_symbol_names.nox` her ad için bir kullanıcı fonksiyonu tanımlayıp çağırır.

const std = @import("std");

/// Kullanıcı fonksiyonu sembollerinde ayrılmış adlara eklenen önek.
pub const user_prefix = "nox_user_";

pub const names = [_][]const u8{
    // <string.h>
    "memccpy",                       "memchr",                   "memcmp",                           "memcpy",                       "memmove",                                   "memset",                           "strcat",                            "strchr",                       "strcmp",                          "strcoll",                    "strcpy",
    "strcspn",                       "strdup",                   "strerror",                         "strlen",                       "strncat",                                   "strncmp",                          "strncpy",                           "strndup",                      "strnlen",                         "strpbrk",                    "strrchr",
    "strspn",                        "strstr",                   "strtok",                           "strxfrm",                      "bcmp",                                      "bcopy",                            "bzero",                             "index",                        "rindex",                          "strcasecmp",                 "strncasecmp",
    // <stdlib.h>
    "abort",                         "abs",                      "atexit",                           "atof",                         "atoi",                                      "atol",                             "atoll",                             "bsearch",                      "calloc",                          "div",                        "exit",
    "_exit",                         "free",                     "getenv",                           "labs",                         "ldiv",                                      "llabs",                            "lldiv",                             "malloc",                       "mblen",                           "mkstemp",                    "putenv",
    "qsort",                         "rand",                     "random",                           "srand",                        "srandom",                                   "realloc",                          "setenv",                            "strtod",                       "strtof",                          "strtol",                     "strtoll",
    "strtoul",                       "strtoull",                 "system",                           "unsetenv",                     "realpath",                                  "arc4random",                       "arc4random_buf",                    "posix_memalign",               "aligned_alloc",                   "drand48",                    "lrand48",
    // <stdio.h>
    "clearerr",                      "fclose",                   "fdopen",                           "feof",                         "ferror",                                    "fflush",                           "fgetc",                             "fgetpos",                      "fgets",                           "fileno",                     "fopen",
    "fprintf",                       "fputc",                    "fputs",                            "fread",                        "freopen",                                   "fscanf",                           "fseek",                             "fsetpos",                      "ftell",                           "fwrite",                     "getc",
    "getchar",                       "getline",                  "gets",                             "perror",                       "printf",                                    "putc",                             "putchar",                           "puts",                         "remove",                          "rename",                     "rewind",
    "scanf",                         "setbuf",                   "setvbuf",                          "snprintf",                     "sprintf",                                   "sscanf",                           "tmpfile",                           "tmpnam",                       "ungetc",                          "vfprintf",                   "vprintf",
    "vsnprintf",                     "vsprintf",                 "dprintf",
    // <math.h>
                             "acos",                         "acosh",                                     "asin",                             "asinh",                             "atan",                         "atan2",                           "atanh",                      "cbrt",
    "ceil",                          "copysign",                 "cos",                              "cosh",                         "erf",                                       "erfc",                             "exp",                               "exp2",                         "expm1",                           "fabs",                       "fdim",
    "floor",                         "fma",                      "fmax",                             "fmin",                         "fmod",                                      "frexp",                            "hypot",                             "ilogb",                        "ldexp",                           "lgamma",                     "llrint",
    "llround",                       "log",                      "log10",                            "log1p",                        "log2",                                      "logb",                             "lrint",                             "lround",                       "modf",                            "nan",                        "nearbyint",
    "nextafter",                     "pow",                      "remainder",                        "remquo",                       "rint",                                      "round",                            "scalbn",                            "sin",                          "sinh",                            "sqrt",                       "tan",
    "tanh",                          "tgamma",                   "trunc",                            "fabsf",                        "sqrtf",                                     "powf",                             "sinf",                              "cosf",                         "tanf",                            "expf",                       "logf",
    "floorf",                        "ceilf",                    "roundf",
    // <ctype.h>
                              "isalnum",                      "isalpha",                                   "isblank",                          "iscntrl",                           "isdigit",                      "isgraph",                         "islower",                    "isprint",
    "ispunct",                       "isspace",                  "isupper",                          "isxdigit",                     "tolower",                                   "toupper",                          "isascii",                           "toascii",
    // <time.h>, <sys/time.h>
                         "asctime",                         "clock",                      "clock_getres",
    "clock_gettime",                 "clock_nanosleep",          "ctime",                            "difftime",                     "gmtime",                                    "localtime",                        "mktime",                            "nanosleep",                    "strftime",                        "strptime",                   "time",
    "timegm",                        "gettimeofday",             "settimeofday",                     "usleep",                       "sleep",                                     "tzset",
    // <signal.h>, <setjmp.h>, <locale.h>, <assert.h>, <errno.h>
                               "kill",                              "raise",                        "signal",                          "sigaction",                  "sigaltstack",
    "sigemptyset",                   "sigfillset",               "sigaddset",                        "sigdelset",                    "sigprocmask",                               "sigsuspend",                       "longjmp",                           "setjmp",                       "_setjmp",                         "_longjmp",                   "siglongjmp",
    "sigsetjmp",                     "setlocale",                "localeconv",                       "assert",                       "errno",                                     "__error",
    // <unistd.h>, <fcntl.h>, <sys/*.h>
                             "access",                            "chdir",                        "chmod",                           "chown",                      "close",
    "dup",                           "dup2",                     "execl",                            "execle",                       "execlp",                                    "execv",                            "execve",                            "execvp",                       "faccessat",                       "fchdir",                     "fchmod",
    "fchmodat",                      "fchown",                   "fcntl",                            "flock",                        "fork",                                      "fpathconf",                        "fstat",                             "fstatat",                      "fsync",                           "ftruncate",                  "futimens",
    "getcwd",                        "getegid",                  "geteuid",                          "getgid",                       "getgroups",                                 "gethostname",                      "getpagesize",                       "getpgid",                      "getpid",                          "getppid",                    "getuid",
    "ioctl",                         "isatty",                   "link",                             "linkat",                       "lseek",                                     "lstat",                            "mkdir",                             "mkdirat",                      "mkfifo",                          "mmap",                       "mprotect",
    "munmap",                        "open",                     "openat",                           "pathconf",                     "pipe",                                      "pipe2",                            "pread",                             "preadv",                       "pwrite",                          "pwritev",                    "read",
    "readlink",                      "readlinkat",               "readv",                            "rmdir",                        "setgid",                                    "setpgid",                          "setregid",                          "setreuid",                     "setsid",                          "setuid",                     "stat",
    "symlink",                       "symlinkat",                "sync",                             "sysconf",                      "truncate",                                  "umask",                            "unlink",                            "unlinkat",                     "utimensat",                       "utimes",                     "wait",
    "wait4",                         "waitpid",                  "write",                            "writev",                       "sendfile",                                  "copyfile",                         "fcopyfile",                         "dlclose",                      "dlerror",                         "dlopen",                     "dlsym",
    "shm_open",                      "shm_unlink",               "sched_yield",                      "sysctl",                       "sysctlbyname",
    // <dirent.h>, <poll.h>, <sys/socket.h>, <netdb.h>, <arpa/inet.h>
                                 "closedir",                         "opendir",                           "readdir",                      "rewinddir",                       "scandir",                    "poll",
    "select",                        "pselect",                  "kevent",                           "kqueue",                       "epoll_create",                              "epoll_create1",                    "epoll_ctl",                         "epoll_wait",                   "accept",                          "bind",                       "connect",
    "freeaddrinfo",                  "gai_strerror",             "getaddrinfo",                      "gethostbyname",                "getpeername",                               "getsockname",                      "getsockopt",                        "htonl",                        "htons",                           "inet_addr",                  "inet_ntoa",
    "inet_ntop",                     "inet_pton",                "listen",                           "ntohl",                        "ntohs",                                     "recv",                             "recvfrom",                          "recvmsg",                      "send",                            "sendmsg",                    "sendto",
    "setsockopt",                    "shutdown",                 "socket",                           "socketpair",                   "if_nametoindex",
    // <pthread.h>, <sched.h>
                               "pthread_attr_destroy",             "pthread_attr_init",                 "pthread_attr_setguardsize",    "pthread_attr_setstacksize",       "pthread_cond_broadcast",     "pthread_cond_destroy",
    "pthread_cond_init",             "pthread_cond_signal",      "pthread_cond_timedwait",           "pthread_cond_wait",            "pthread_create",                            "pthread_detach",                   "pthread_equal",                     "pthread_exit",                 "pthread_getspecific",             "pthread_join",               "pthread_key_create",
    "pthread_key_delete",            "pthread_kill",             "pthread_mutex_destroy",            "pthread_mutex_init",           "pthread_mutex_lock",                        "pthread_mutex_trylock",            "pthread_mutex_unlock",              "pthread_once",                 "pthread_self",                    "pthread_setspecific",        "pthread_sigmask",
    "pthread_threadid_np",           "sched_getcpu",             "sched_setaffinity",
    // Darwin / glibc / musl çalışma zamanı ve derleyici-rt sembolleri
                   "_NSGetExecutablePath",         "_dyld_get_image_header_containing_address", "_tlv_bootstrap",                   "__errno_location",                  "__stack_chk_fail",             "__stack_chk_guard",               "__cxa_atexit",               "__cxa_finalize",
    "__assert_rtn",                  "__assert_fail",            "_Unwind_Resume",                   "memalign",                     "valloc",                                    "mallinfo",                         "malloc_usable_size",                "getrandom",                    "getentropy",                      "fputs_unlocked",             "fwrite_unlocked",
    "flockfile",                     "funlockfile",              "dl_iterate_phdr",                  "backtrace",                    "backtrace_symbols",
    // Çapraz derlenen çalışma zamanı nesnelerinin (Linux/Android/iOS/Windows) çözdüğü ek semboller (`scripts/check_reserved_symbols.py` ile doğrulanır)
                            "CertAddEncodedCertificateToStore", "CertCloseStore",                    "CertEnumCertificatesInStore",  "CertFreeCertificateChain",        "CertFreeCertificateContext", "CertGetCertificateChain",
    "CertOpenStore",                 "CertOpenSystemStoreW",     "CertVerifyCertificateChainPolicy", "CloseHandle",                  "CreateFileA",                               "CreateFileMappingA",               "CreateProcessW",                    "DeleteFileA",                  "FindClose",                       "FindFirstFileA",             "FindNextFileA",
    "FreeLibrary",                   "GetCurrentDirectoryA",     "GetCurrentDirectoryW",             "GetEnvironmentVariableA",      "GetFileAttributesA",                        "GetFileSizeEx",                    "GetFileTime",                       "GetFullPathNameA",             "GetLastError",                    "GetProcAddress",             "GetSystemTimePreciseAsFileTime",
    "GetTempPathA",                  "LdrFindEntryForAddress",   "LdrGetProcedureAddress",           "LdrLoadDll",                   "LdrRegisterDllNotification",                "LdrUnloadDll",                     "LoadLibraryA",                      "LoadLibraryExA",               "MapViewOfFile",                   "MoveFileExA",                "NtAlertThread",
    "NtAlertThreadByThreadId",       "NtAllocateVirtualMemory",  "NtCancelIoFileEx",                 "NtCancelSynchronousIoFile",    "NtClose",                                   "NtCreateFile",                     "NtCreateNamedPipeFile",             "NtCreateSection",              "NtCreateThreadEx",                "NtDelayExecution",           "NtDeviceIoControlFile",
    "NtFlushBuffersFile",            "NtFreeVirtualMemory",      "NtFsControlFile",                  "NtLockFile",                   "NtMapViewOfSection",                        "NtOpenFile",                       "NtOpenThread",                      "NtQueryAttributesFile",        "NtQueryDirectoryFile",            "NtQueryInformationFile",     "NtQueryInformationProcess",
    "NtQueryInformationThread",      "NtQueryObject",            "NtQuerySystemInformation",         "NtQueryVolumeInformationFile", "NtReadFile",                                "NtResumeThread",                   "NtSetInformationFile",              "NtTerminateProcess",           "NtUnlockFile",                    "NtUnmapViewOfSection",       "NtWaitForAlertByThreadId",
    "NtWaitForSingleObject",         "NtWriteFile",              "NtYieldExecution",                 "QueryPerformanceCounter",      "QueryPerformanceFrequency",                 "RtlActivateActivationContextEx",   "RtlAllocateHeap",                   "RtlEnterCriticalSection",      "RtlEqualUnicodeString",           "RtlExitUserProcess",         "RtlFreeHeap",
    "RtlGetActiveActivationContext", "RtlGetCurrentDirectory_U", "RtlGetFullPathName_U",             "RtlGetSystemTimePrecise",      "RtlLeaveCriticalSection",                   "RtlLookupFunctionEntry",           "RtlQueryPerformanceCounter",        "RtlQueryPerformanceFrequency", "RtlReleaseActivationContext",     "RtlReportSilentProcessExit", "RtlSetCurrentDirectory_U",
    "RtlUpcaseUnicodeChar",          "RtlVirtualUnwind",         "SetEndOfFile",                     "SetFilePointerEx",             "Sleep",                                     "SystemFunction036",                "UnmapViewOfFile",                   "VirtualAlloc",                 "VirtualFree",                     "VirtualProtect",             "WSAGetLastError",
    "WSAPoll",                       "WSAStartup",               "_close",                           "_errno",                       "_filelengthi64",                            "_get_osfhandle",                   "_lseeki64",                         "_open",                        "_putenv_s",                       "_read",                      "_setmode",
    "_tls_index",                    "_write",                   "accept4",                          "closesocket",                  "copy_file_range",                           "ftruncate64",                      "ioctlsocket",                       "lseek64",                      "malloc_size",                     "mmap64",                     "mremap",
    "open64",                        "openat64",                 "os_log_type_enabled",              "pread64",                      "preadv64",                                  "pthread_mutexattr_destroy",        "pthread_mutexattr_init",            "pthread_mutexattr_settype",    "pwrite64",                        "pwritev64",                  "renameat",
    "sched_getaffinity",             "sendfile64",               "sendmmsg",                         "statx",                        "timerfd_create",                            "timerfd_settime",                  "RtlRemoveVectoredExceptionHandler", "stdout",                       "stderr",                          "stdin",                      "__stdoutp",
    "__stderrp",                     "__stdinp",
    // wasi-libc / wasm libc ikamesi (runtime/wasm_libc.zig)
                    "environ",                          "_start",                       "__wasm_call_ctors",                         "__original_main",                  "__main_void",                       "__wasi_proc_exit",             "emscripten_notify_memory_growth",
};

const set = std.StaticStringMap(void).initComptime(blk: {
    var kvs: [names.len]struct { []const u8 } = undefined;
    for (names, 0..) |n, i| kvs[i] = .{n};
    break :blk kvs;
});

/// Bu ad, bir kullanıcı fonksiyonu sembolünde `nox_user_` önekini gerektirir mi?
pub fn isReserved(name: []const u8) bool {
    return set.has(name);
}

/// Bir kullanıcı üst-düzey fonksiyonunun nesne dosyası sembol adı (öneksiz `$`/`@` olmadan). Ayrılmış değilse `name` aynen döner (tahsis yok).
pub fn symbolName(allocator: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]const u8 {
    if (!isReserved(name)) return name;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ user_prefix, name });
}

test "ayrılmış adlar: libc adları öneklenir, sıradan adlar değişmez" {
    const a = std.testing.allocator;
    const r = try symbolName(a, "getenv");
    defer a.free(r);
    try std.testing.expectEqualStrings("nox_user_getenv", r);
    try std.testing.expectEqualStrings("fibonacci", try symbolName(a, "fibonacci"));
    try std.testing.expect(isReserved("printf"));
    try std.testing.expect(isReserved("round"));
    try std.testing.expect(!isReserved("nox_alloc"));
    try std.testing.expect(!isReserved("my_read"));
}

test "ayrılmış ad listesi yinelenen içermez" {
    for (names, 0..) |n, i| {
        for (names[i + 1 ..]) |m| try std.testing.expect(!std.mem.eql(u8, n, m));
    }
}
