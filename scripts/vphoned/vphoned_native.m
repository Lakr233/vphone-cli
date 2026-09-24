#import "include/VphonedNative.h"
#import "vphoned_install.h"
#import "vphoned_keychain.h"
#import <CommonCrypto/CommonDigest.h>
#include <mach-o/dyld.h>
#include <unistd.h>

NSDictionary *vp_native_api_command(NSDictionary *message) {
    NSString *type = message[@"t"];
    if ([type isEqualToString:@"ipa_install"]) return vp_handle_custom_install(message);
    if ([type isEqualToString:@"keychain_list"] || [type isEqualToString:@"keychain_add"])
        return vp_handle_keychain_command(message);
    return @{@"t": @"err", @"msg": @"Unknown native operation"};
}

void vp_native_bootstrap_cached_binary(void) {
    static const char *cache = "/var/root/Library/Caches/vphoned";
    // Pre-HTTP daemon builds also used this cache path. Their binaries lack
    // the marker, so a new firmware daemon must not exec an old protocol.
    static const char *marker = "/var/root/Library/Caches/vphoned.api-v1";
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
    char *const arguments[] = {(char *)cache, NULL};
    execv(cache, arguments);
    NSLog(@"vphoned: cached binary launch failed: %s", strerror(errno));
}
