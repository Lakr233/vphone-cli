// VPhoneKmutilShim.c — Lets the kmutil of another macOS link a kernelcache as the user.
//
// `KernelCollectionToolchain` runs an ad hoc signed copy of a release's kmutil
// with this library in DYLD_INSERT_LIBRARIES. It changes two things kmutil
// sees, nothing it writes:
//
//   * kmutil ignores, without a word, every kext that root does not own or
//     that is group- or world-writable. Files the invoking user owns are
//     reported as root:wheel without those write bits, so the staged volume
//     links where the user staged it, and no part of the link runs as root.
//   * kmutil reads KernelManagement's configuration from the framework of the
//     running system, whose format changed in macOS 26. The path in
//     VPHONE_KMUTIL_CONFIG_FROM is opened as VPHONE_KMUTIL_CONFIG_TO, the
//     configuration of kmutil's own release.
//
// Built for arm64e by StageBundle.sh into Contents/MacOS.

#include <fcntl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define VPHONE_INTERPOSE(replacement, original)                                                   \
    __attribute__((used)) static const struct {                                                   \
        const void *replacement;                                                                  \
        const void *original;                                                                     \
    } vphone_interpose_##original __attribute__((section("__DATA,__interpose"))) = {              \
        (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&original};

static void as_root(struct stat *status) {
    if (status->st_uid == getuid()) {
        status->st_uid = 0;
        status->st_gid = 0;
        status->st_mode &= ~(S_IWGRP | S_IWOTH);
    }
}

static const char *redirected(const char *path) {
    const char *from = getenv("VPHONE_KMUTIL_CONFIG_FROM");
    const char *to = getenv("VPHONE_KMUTIL_CONFIG_TO");
    return path && from && to && strcmp(path, from) == 0 ? to : path;
}

static int vphone_stat(const char *path, struct stat *status) {
    int result = stat(redirected(path), status);
    if (result == 0) as_root(status);
    return result;
}

static int vphone_lstat(const char *path, struct stat *status) {
    int result = lstat(redirected(path), status);
    if (result == 0) as_root(status);
    return result;
}

static int vphone_fstat(int descriptor, struct stat *status) {
    int result = fstat(descriptor, status);
    if (result == 0) as_root(status);
    return result;
}

static int vphone_fstatat(int directory, const char *path, struct stat *status, int flags) {
    int result = fstatat(directory, redirected(path), status, flags);
    if (result == 0) as_root(status);
    return result;
}

static int vphone_open(const char *path, int flags, ...) {
    int mode = 0;
    if (flags & O_CREAT) {
        va_list arguments;
        va_start(arguments, flags);
        mode = va_arg(arguments, int);
        va_end(arguments);
    }
    return open(redirected(path), flags, mode);
}

static int vphone_openat(int directory, const char *path, int flags, ...) {
    int mode = 0;
    if (flags & O_CREAT) {
        va_list arguments;
        va_start(arguments, flags);
        mode = va_arg(arguments, int);
        va_end(arguments);
    }
    return openat(directory, redirected(path), flags, mode);
}

VPHONE_INTERPOSE(vphone_stat, stat)
VPHONE_INTERPOSE(vphone_lstat, lstat)
VPHONE_INTERPOSE(vphone_fstat, fstat)
VPHONE_INTERPOSE(vphone_fstatat, fstatat)
VPHONE_INTERPOSE(vphone_open, open)
VPHONE_INTERPOSE(vphone_openat, openat)
