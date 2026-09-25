#import "Include/VphonedNative.h"
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *cache_directory = "/var/root/Library/Caches";
static const char *cache = "/var/root/Library/Caches/vphoned";
static const char *marker = "/var/root/Library/Caches/vphoned.api-v2";
static const char *pending = "/var/root/Library/Caches/vphoned.api-v2.pending";

static const char *leaf(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

// MARK: - Cached Binary Trust

// The launchd proxy runs as root and execs the cached binary, so only root
// may have been able to write it: the file, its marker, and the directory
// that holds them must be root-owned and not writable by group or other.
static bool root_only(int fd, mode_t type) {
    struct stat info;
    return fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == type && info.st_uid == 0 &&
           (info.st_mode & (S_IWGRP | S_IWOTH)) == 0;
}

static bool cached_binary_matches_marker(int directory, int image) {
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    unsigned char buffer[64 * 1024];
    ssize_t count;
    while ((count = read(image, buffer, sizeof(buffer))) != 0) {
        if (count < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    }

    int record = openat(directory, leaf(marker), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (record < 0) return false;
    char expected[65];
    ssize_t length = root_only(record, S_IFREG) ? read(record, expected, sizeof(expected)) : -1;
    close(record);
    if (length != 64) return false;
    expected[64] = '\0';

    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    static const char hex[] = "0123456789abcdef";
    char actual[65];
    for (int index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        actual[index * 2] = hex[digest[index] >> 4];
        actual[index * 2 + 1] = hex[digest[index] & 15];
    }
    actual[64] = '\0';
    return strcmp(actual, expected) == 0;
}

// MARK: - Bootstrap

void vp_native_bootstrap_cached_binary(void) {
    char current[4096];
    uint32_t size = sizeof(current);
    if (_NSGetExecutablePath(current, &size) != 0 || strcmp(current, cache) == 0) return;

    // Keep the launchd process small: hash the cache in bounded chunks. The
    // file is opened once without following a link, and the hash covers that
    // descriptor.
    int directory = open(cache_directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0) return;
    struct stat hashed;
    int image = -1;
    bool trusted = root_only(directory, S_IFDIR) &&
                   (image = openat(directory, leaf(cache), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)) >= 0 &&
                   root_only(image, S_IFREG) && fstat(image, &hashed) == 0 &&
                   (hashed.st_mode & S_IXUSR) != 0 && cached_binary_matches_marker(directory, image);
    if (image >= 0) close(image);
    if (!trusted || renameat(directory, leaf(marker), directory, leaf(pending)) != 0) {
        close(directory);
        return;
    }

    // The guest has no fexecve. Exec by path only if the path still names the
    // file that was hashed; otherwise the pending marker leaves the cache
    // unconfirmed and the installed binary keeps running.
    struct stat named;
    bool same = fstatat(directory, leaf(cache), &named, AT_SYMLINK_NOFOLLOW) == 0 &&
                named.st_dev == hashed.st_dev && named.st_ino == hashed.st_ino;
    close(directory);
    if (!same) {
        fprintf(stderr, "vphoned proxy: cached binary changed after it was verified\n");
        return;
    }
    char *const arguments[] = {(char *)cache, NULL};
    execv(cache, arguments);
    fprintf(stderr, "vphoned proxy: cached binary exec failed: %s\n", strerror(errno));
    _exit(1);
}

void vp_native_confirm_cached_binary(void) {
    char current[4096];
    uint32_t size = sizeof(current);
    if (_NSGetExecutablePath(current, &size) != 0 || strcmp(current, cache) != 0) return;
    if (rename(pending, marker) != 0)
        fprintf(stderr, "vphoned: could not confirm cached binary: %s\n", strerror(errno));
}
