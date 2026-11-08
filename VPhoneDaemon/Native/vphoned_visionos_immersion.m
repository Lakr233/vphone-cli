// Native system-environment immersion (type 0), inspected on visionOS 26.4.
// No synthetic HID device, replacement renderer, or physical tracking override.
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <math.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

@interface VPImmersionReply : NSObject
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic) BOOL completed;
@property(nonatomic) float level;
@property(nonatomic, strong) NSError *error;
@end
@implementation VPImmersionReply
- (instancetype)init { if ((self = [super init])) _lock = [NSLock new]; return self; }
@end

#ifdef VP_VISIONOS_IMMERSION_TESTING
static Class vpImmersionTestClass;
#endif

static BOOL vpImmersionMethod(Class cls, NSString *name, const char **arguments, unsigned count) {
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
    if (!method || method_getNumberOfArguments(method) != count + 2) return NO;
    char *result = method_copyReturnType(method);
    BOOL valid = result && !strcmp(result, @encode(void));
    free(result);
    for (unsigned i = 0; valid && i < count; i++) {
        char *type = method_copyArgumentType(method, i + 2);
        valid = type && !strcmp(type, arguments[i]);
        free(type);
    }
    return valid;
}

static Class vpImmersionClass(void) {
#ifdef VP_VISIONOS_IMMERSION_TESTING
    Class cls = vpImmersionTestClass;
#else
    char machine[128] = {0};
    size_t size = sizeof(machine);
    if (sysctlbyname("hw.machine", machine, &size, NULL, 0) || strncmp(machine, "RealityDevice", 13)
        || access("/System/Library/CoreServices/SurfBoard.app/SurfBoard", F_OK)) return Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/SurfBoardServices.framework/SurfBoardServices", RTLD_NOW | RTLD_LOCAL);
    });
    Class cls = NSClassFromString(@"SFBSImmersionService");
#endif
    // The nested reply signatures come from the matching native call sites:
    // setter (NSError *), getter (float, NSError *).
    const char *setTypes[] = {@encode(float), @encode(uint8_t), @encode(double), "@?"};
    const char *getTypes[] = {@encode(uint8_t), "@?"};
    if (!vpImmersionMethod(cls, @"setImmersionLevel:immersionType:animationDuration:completion:", setTypes, 4)
        || !vpImmersionMethod(cls, @"getImmersionLevelForType:completion:", getTypes, 2)) return Nil;
    // 26.4 uses the ordinary NSXPC mach-service path here. A future LaunchAngel
    // variant would use a BS endpoint whose absence can trap rather than throw;
    // do not enter that unreviewed path merely because its selectors match.
    for (NSString *name in @[@"launchAngelDomain", @"launchAngelServiceProtocol", @"machServiceName"]) {
        Method method = class_getClassMethod(cls, NSSelectorFromString(name));
        if (!method || method_getNumberOfArguments(method) != 2) return Nil;
        char *type = method_copyReturnType(method);
        BOOL object = type && !strcmp(type, "@");
        free(type);
        if (!object) return Nil;
        id value = ((id (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(name));
        if ([name isEqualToString:@"machServiceName"]) {
            if (![value isKindOfClass:NSString.class] || ![value isEqualToString:@"com.apple.surfboard.immersionservice"]) return Nil;
        } else if (value) return Nil;
    }
    return cls;
}

bool vp_visionos_immersion_available(void) { return vpImmersionClass() != Nil; }

static double vpImmersionMonotonicTime(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec + now.tv_nsec / 1e9;
}

static BOOL vpImmersionWait(VPImmersionReply *reply) {
#ifdef VP_VISIONOS_IMMERSION_TESTING
    NSTimeInterval timeout = 0.1;
#else
    NSTimeInterval timeout = 5;
#endif
    double deadline = vpImmersionMonotonicTime() + timeout;
    while (YES) {
        [reply.lock lock];
        BOOL done = reply.completed;
        [reply.lock unlock];
        if (done) return YES;
        if (vpImmersionMonotonicTime() >= deadline) return NO;
        BOOL handled = [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                              beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        if (!handled) {
            // A GCD request worker may have no run-loop sources. Keep waiting
            // for the service queue's callback without spinning that worker.
            struct timespec delay = {.tv_sec = 0, .tv_nsec = 10000000};
            nanosleep(&delay, NULL);
        }
    }
}

static NSDictionary *vpImmersionResult(double desired, BOOL apply) {
    if (apply && (!isfinite(desired) || desired < 0 || desired > 1))
        return @{@"ok": @NO, @"error": @"Immersion level must be a finite number from 0 to 1"};
    Class cls = vpImmersionClass();
    if (!cls) return @{@"ok": @NO, @"error": @"Native visionOS immersion API is unavailable or its ABI differs"};
    id service = [cls new];
    if (!service) return @{@"ok": @NO, @"error": @"Native visionOS immersion service is unavailable"};
    if (apply) {
        VPImmersionReply *reply = [VPImmersionReply new];
        ((void (*)(id, SEL, float, uint8_t, double, id))objc_msgSend)(service,
            NSSelectorFromString(@"setImmersionLevel:immersionType:animationDuration:completion:"),
            (float)desired, 0, 0.25, ^(NSError *error) {
                [reply.lock lock]; reply.error = error; reply.completed = YES; [reply.lock unlock];
            });
        if (!vpImmersionWait(reply))
            return @{@"ok": @NO, @"error": @"Immersion request timed out; its resulting state is unknown"};
        if (reply.error) return @{@"ok": @NO, @"error": reply.error.description};
    }
    VPImmersionReply *reply = [VPImmersionReply new];
    ((void (*)(id, SEL, uint8_t, id))objc_msgSend)(service,
        NSSelectorFromString(@"getImmersionLevelForType:completion:"), 0, ^(float level, NSError *error) {
            [reply.lock lock]; reply.level = level; reply.error = error; reply.completed = YES; [reply.lock unlock];
        });
    if (!vpImmersionWait(reply))
        return @{@"ok": @NO, @"error": apply ? @"Immersion request was acknowledged but independent readback timed out" : @"Immersion readback timed out"};
    if (reply.error) return @{@"ok": @NO, @"error": reply.error.description};
    if (!isfinite(reply.level) || reply.level < 0 || reply.level > 1)
        return @{@"ok": @NO, @"error": @"Native immersion readback returned an invalid level"};
    NSMutableDictionary *result = [@{@"available": @YES, @"applied": @(apply), @"level": @(reply.level)} mutableCopy];
    if (apply) result[@"requested_level"] = @(desired);
    return @{@"ok": @YES, @"result": result};
}

char *vp_visionos_immersion_copy_json(double level, bool apply) {
    @autoreleasepool {
        NSDictionary *reply;
        @try { reply = vpImmersionResult(level, apply); }
        @catch (NSException *exception) {
            reply = @{@"ok": @NO, @"error": exception.reason ?: exception.name};
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
        return data ? strndup(data.bytes, data.length) : NULL;
    }
}
