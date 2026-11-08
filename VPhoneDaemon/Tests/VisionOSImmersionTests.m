#define VP_VISIONOS_IMMERSION_TESTING
#import "../Native/vphoned_visionos_immersion.m"
#include <assert.h>

static float mockLevel;
static unsigned writes;
static BOOL failSet, failRead, delayedRead, invalidRead, launchAngel;
@interface VPImmersionMockService : NSObject
- (void)setImmersionLevel:(float)level immersionType:(uint8_t)type animationDuration:(double)duration completion:(void (^)(NSError *))completion;
- (void)getImmersionLevelForType:(uint8_t)type completion:(void (^)(float, NSError *))completion;
@end
@implementation VPImmersionMockService
+ (id)launchAngelDomain { return launchAngel ? @"unreviewed" : nil; }
+ (id)launchAngelServiceProtocol { return nil; }
+ (id)machServiceName { return @"com.apple.surfboard.immersionservice"; }
- (void)setImmersionLevel:(float)level immersionType:(uint8_t)type animationDuration:(double)duration completion:(void (^)(NSError *))completion {
    assert(type == 0 && duration == 0.25);
    writes++;
    if (!failSet) mockLevel = level;
    completion(failSet ? [NSError errorWithDomain:@"test-set" code:1 userInfo:nil] : nil);
}
- (void)getImmersionLevelForType:(uint8_t)type completion:(void (^)(float, NSError *))completion {
    assert(type == 0);
    float value = invalidRead ? NAN : mockLevel;
    NSError *error = failRead ? [NSError errorWithDomain:@"test-read" code:2 userInfo:nil] : nil;
    if (delayedRead) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            completion(value, error);
        });
    } else completion(value, error);
}
@end

@interface VPImmersionWrongABI : VPImmersionMockService
- (void)setImmersionLevel:(double)level immersionType:(uint8_t)type animationDuration:(double)duration completion:(void (^)(NSError *))completion;
@end
@implementation VPImmersionWrongABI
- (void)setImmersionLevel:(double)level immersionType:(uint8_t)type animationDuration:(double)duration completion:(void (^)(NSError *))completion {
    (void)level; (void)type; (void)duration; (void)completion;
    assert(0 && "Wrong ABI must never execute");
}
@end

static NSDictionary *call(double level, BOOL apply) {
    char *json = vp_visionos_immersion_copy_json(level, apply);
    assert(json);
    NSData *data = [NSData dataWithBytes:json length:strlen(json)];
    free(json);
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

int main(void) { @autoreleasepool {
    assert(!vp_visionos_immersion_available());
    vpImmersionTestClass = VPImmersionMockService.class;
    assert(vp_visionos_immersion_available());
    launchAngel = YES;
    assert(!vp_visionos_immersion_available() && ![call(1, YES)[@"ok"] boolValue]);
    launchAngel = NO;
    for (NSNumber *level in @[@0, @0.5, @1]) {
        NSDictionary *reply = call(level.doubleValue, YES);
        assert([reply[@"ok"] boolValue]);
        assert([reply[@"result"][@"level"] floatValue] == level.floatValue);
        assert([reply[@"result"][@"requested_level"] doubleValue] == level.doubleValue);
    }
    unsigned before = writes;
    NSDictionary *read = call(0, NO);
    assert([read[@"ok"] boolValue] && ![read[@"result"][@"applied"] boolValue] && writes == before);
    for (NSNumber *invalid in @[@(-0.1), @1.1, @(NAN), @(INFINITY)]) {
        assert(![call(invalid.doubleValue, YES)[@"ok"] boolValue]);
        assert(writes == before);
    }
    failSet = YES;
    assert(![call(0.5, YES)[@"ok"] boolValue]);
    failSet = NO; failRead = YES;
    assert(![call(0.5, YES)[@"ok"] boolValue]);
    failRead = NO; invalidRead = YES;
    assert(![call(0, NO)[@"ok"] boolValue]);
    invalidRead = NO; delayedRead = YES;
    NSDictionary *timeout = call(0, NO);
    assert(![timeout[@"ok"] boolValue] && [timeout[@"error"] containsString:@"timed out"]);
    // An XPC completion can arrive after timeout; its heap-owned state survives.
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
    delayedRead = NO;
    vpImmersionTestClass = VPImmersionWrongABI.class;
    assert(!vp_visionos_immersion_available() && ![call(1, YES)[@"ok"] boolValue]);
    puts("visionOS immersion: ABI, system type, native readback, failures and late callbacks passed");
} }
