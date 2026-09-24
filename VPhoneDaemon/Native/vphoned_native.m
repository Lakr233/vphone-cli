#import "Include/VphonedNative.h"
#import "vphoned_install.h"
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>
#import <objc/message.h>
#include <mach-o/dyld.h>
#include <unistd.h>

static const char *cache = "/var/root/Library/Caches/vphoned";
static const char *marker = "/var/root/Library/Caches/vphoned.api-v2";
static const char *pending = "/var/root/Library/Caches/vphoned.api-v2.pending";

int vp_low_power_mode_set_async(bool enabled) {
    dlopen("/System/Library/PrivateFrameworks/LowPowerMode.framework/LowPowerMode", RTLD_NOW);
    Class cls = NSClassFromString(@"_PMLowPowerMode");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    SEL set = NSSelectorFromString(@"setPowerMode:fromSource:withCompletion:");
    if (![cls respondsToSelector:shared]) return -1;
    id service = ((id (*)(Class, SEL))objc_msgSend)(cls, shared);
    if (![service respondsToSelector:set]) return -1;

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL accepted = NO;
    __block NSError *failure = nil;
    NSLog(@"vphoned: low power mode async request enabled=%d", enabled);
    // The iOS 26 synchronous selector waits for a powerd XPC reply without a
    // deadline. Its completion variant uses an asynchronous remote proxy.
    void (^completion)(BOOL, NSError *) = ^(BOOL applied, NSError *error) {
        accepted = applied;
        failure = error;
        NSLog(@"vphoned: low power mode async reply applied=%d error_domain=%@ error_code=%ld error_info=%@",
              applied, error.domain, (long)error.code, error.userInfo);
        dispatch_semaphore_signal(done);
    };
    ((void (*)(id, SEL, long, NSString *, id))objc_msgSend)(service, set,
        enabled ? 1 : 0, @"ControlCenter", completion);
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0) {
        NSLog(@"vphoned: low power mode async request timed out after 3 seconds");
        return -2;
    }
    return accepted && !failure ? 0 : -3;
}

NSDictionary *vp_native_api_command(NSDictionary *message) {
    NSString *type = message[@"t"];
    if ([type isEqualToString:@"ipa_install"]) return vp_handle_custom_install(message);
    return @{@"t": @"err", @"msg": @"Unknown native operation"};
}

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
