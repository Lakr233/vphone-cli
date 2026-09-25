#import "Include/VphonedNative.h"
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static const char *cache = "/var/root/Library/Caches/vphoned";
static const char *marker = "/var/root/Library/Caches/vphoned.api-v2";
static const char *pending = "/var/root/Library/Caches/vphoned.api-v2.pending";

static bool cached_binary_matches_marker(void) {
    FILE *image = fopen(cache, "rb");
    if (!image) return false;
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    unsigned char buffer[64 * 1024];
    size_t count;
    while ((count = fread(buffer, 1, sizeof(buffer), image)) > 0)
        CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    bool complete = !ferror(image);
    fclose(image);
    if (!complete) return false;

    FILE *record = fopen(marker, "rb");
    if (!record) return false;
    char expected[65];
    count = fread(expected, 1, sizeof(expected), record);
    fclose(record);
    if (count != 64) return false;
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

void vp_native_bootstrap_cached_binary(void) {
    // Keep the launchd process small: hash the cache in bounded chunks.
    if (access(cache, X_OK) != 0 || !cached_binary_matches_marker()) return;
    char current[4096];
    uint32_t size = sizeof(current);
    if (_NSGetExecutablePath(current, &size) != 0 || strcmp(current, cache) == 0) return;
    if (rename(marker, pending) != 0) return;
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
