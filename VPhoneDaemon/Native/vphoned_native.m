#import "Include/VphonedNative.h"
#import <CommonCrypto/CommonDigest.h>
#include <mach-o/dyld.h>
#include <unistd.h>

static const char *cache = "/var/root/Library/Caches/vphoned";
static const char *marker = "/var/root/Library/Caches/vphoned.api-v2";
static const char *pending = "/var/root/Library/Caches/vphoned.api-v2.pending";

void vp_native_bootstrap_cached_binary(void) {
    // A cached update gets one attempt to bind. If it fails, launchd restarts
    // the bundled daemon, which remains the fallback.
    if (access(cache, X_OK) != 0 || access(marker, R_OK) != 0) return;
    NSData *binary = [NSData dataWithContentsOfFile:@(cache) options:NSDataReadingMappedIfSafe error:nil];
    NSString *expected = [NSString stringWithContentsOfFile:@(marker) encoding:NSUTF8StringEncoding error:nil];
    if (!binary || expected.length != CC_SHA256_DIGEST_LENGTH * 2) return;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(binary.bytes, (CC_LONG)binary.length, digest);
    NSMutableString *actual = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [actual appendFormat:@"%02x", digest[i]];
    if (![actual isEqualToString:expected]) return;
    char current[4096];
    uint32_t size = sizeof(current);
    if (_NSGetExecutablePath(current, &size) != 0 || strcmp(current, cache) == 0) return;
    if (rename(marker, pending) != 0) return;
    char *const arguments[] = {(char *)cache, NULL};
    execv(cache, arguments);
    NSLog(@"vphoned: cached binary launch failed: %s", strerror(errno));
}

void vp_native_confirm_cached_binary(void) {
    char current[4096];
    uint32_t size = sizeof(current);
    if (_NSGetExecutablePath(current, &size) != 0 || strcmp(current, cache) != 0) return;
    if (rename(pending, marker) != 0)
        NSLog(@"vphoned: could not confirm cached binary: %s", strerror(errno));
}
