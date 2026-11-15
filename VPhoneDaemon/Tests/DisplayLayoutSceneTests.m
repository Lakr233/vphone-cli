// Compile the actual extraction helper so malformed private-API responses are
// exercised without depending on FrontBoard being present on the test host.
#import "../Native/vphoned_display.m"
#include <stdio.h>
#include <stdlib.h>

@interface VPTestScene : NSObject
@end
@implementation VPTestScene
- (id)bundleIdentifier { return @"com.example.reader"; }
- (id)identifier { return @"reader-scene"; }
- (CGRect)frame { return CGRectMake(0, 0, 951, 669); }
- (CGRect)referenceFrame { return CGRectMake(0, 0, 669, 951); }
@end

@interface VPTestOwner : NSObject
@property(nonatomic, strong) id value;
@property(nonatomic) BOOL throws;
@end
@implementation VPTestOwner
- (id)bundleIdentifier {
    if (self.throws) [NSException raise:@"OwnerUnavailable" format:@"Owner lookup failed"];
    return self.value;
}
@end

@interface VPTestWrongOwnerABI : NSObject
@end
@implementation VPTestWrongOwnerABI
- (int)bundleIdentifier { return 42; }
@end

@interface VPTestLayout : NSObject
@property(nonatomic, copy) NSArray *elements;
@end
@implementation VPTestLayout
@end

static void checkOwner(id owner, BOOL expectedAvailable) {
    VPTestLayout *layout = [VPTestLayout new];
    // The known scene comes first: rejecting the second owner must discard
    // this otherwise usable partial result, not declare it unique.
    layout.elements = @[[VPTestScene new], owner];
    NSMutableDictionary *row = [NSMutableDictionary dictionary];
    vpLayoutApplicationScenes(layout, @"com.example.reader", row, [NSMutableDictionary dictionary]);
    for (NSString *key in @[@"elements_available", @"elements_truncated"]) {
        if (!row[key] || CFGetTypeID((__bridge CFTypeRef)row[key]) != CFBooleanGetTypeID()) {
            fprintf(stderr, "%s must be a CFBoolean, not a boxed C integer\n", key.UTF8String);
            exit(EXIT_FAILURE);
        }
    }
    BOOL available = [row[@"elements_available"] boolValue];
    NSArray *scenes = row[@"application_scenes"];
    if (available != expectedAvailable
        || (expectedAvailable ? scenes.count != 1 : scenes != nil)) {
        fprintf(stderr, "scene owner %s: available=%d, published scenes=%s\n",
                class_getName([owner class]), available, scenes.description.UTF8String ?: "none");
        exit(EXIT_FAILURE);
    }
}

int main(void) {
    @autoreleasepool {
        VPTestOwner *nilOwner = [VPTestOwner new];
        checkOwner(nilOwner, YES);
        VPTestOwner *otherApp = [VPTestOwner new];
        otherApp.value = @"com.example.other";
        checkOwner(otherApp, YES);
        checkOwner([NSObject new], NO);
        checkOwner([VPTestWrongOwnerABI new], NO);
        VPTestOwner *malformed = [VPTestOwner new];
        malformed.value = @42;
        checkOwner(malformed, NO);
        VPTestOwner *overlong = [VPTestOwner new];
        overlong.value = [@"x" stringByPaddingToLength:256 withString:@"x" startingAtIndex:0];
        checkOwner(overlong, NO);
        VPTestOwner *throwing = [VPTestOwner new];
        throwing.throws = YES;
        checkOwner(throwing, NO);
        puts("display scene ownership: verified nil is allowed; unreadable owners discard partial inventories");
    }
    return EXIT_SUCCESS;
}
