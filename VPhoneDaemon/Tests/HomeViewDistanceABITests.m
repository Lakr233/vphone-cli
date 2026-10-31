#import "../Native/vphoned_homeview_distance.m"
#include <assert.h>

@protocol VPHomeViewOneWayFixture
- (oneway void)fetchCurrentEnvironmentWithReply:(void (^)(id, NSError *))reply;
- (oneway void)applyEnvironmentOverrides:(id)request completion:(void (^)(id, NSError *))reply;
- (oneway void)resetEnvironmentOverridesWithCompletion:(void (^)(id, NSError *))reply;
@end

@protocol VPHomeViewWrongReplyFixture
- (oneway void)fetchCurrentEnvironmentWithReply:(id)reply;
- (oneway void)applyEnvironmentOverrides:(id)request completion:(void (^)(id, NSError *))reply;
- (oneway void)resetEnvironmentOverridesWithCompletion:(void (^)(id, NSError *))reply;
@end

@protocol VPHomeViewMissingMethodFixture
- (oneway void)fetchCurrentEnvironmentWithReply:(void (^)(id, NSError *))reply;
@end

int main(void) { @autoreleasepool {
    assert(vpDistanceProtocolABI(@protocol(VPHomeViewOneWayFixture)));
    assert(!vpDistanceProtocolABI(@protocol(VPHomeViewWrongReplyFixture)));
    assert(!vpDistanceProtocolABI(@protocol(VPHomeViewMissingMethodFixture)));
    // Exact encoding observed on the installed HomeView 24V514 guest.
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:"Vv24@0:8@?16"];
    assert(strcmp(signature.methodReturnType, "Vv") == 0);
    assert(strcmp(vpDistanceUnqualifiedType(signature.methodReturnType), "v") == 0);
    assert(strcmp(vpDistanceUnqualifiedType("rn@?"), "@?") == 0);
    assert(strcmp(vpDistanceUnqualifiedType("q"), "q") == 0);
    assert(strcmp(vpDistanceUnqualifiedType("i"), "v") != 0);
    puts("HomeView distance ABI: oneway void accepted; invalid callback and missing method refused");
} return 0; }
