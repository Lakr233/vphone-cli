#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <assert.h>
static NSInteger version;
static NSString *process;
static int loads;
static NSOperatingSystemVersion testVersion(id self, SEL sel) { return (NSOperatingSystemVersion){version,0,0}; }
static NSString *testProcess(id self, SEL sel) { return process; }
@interface AVFlashlight : NSObject
+ (BOOL)hasFlashlight;
@end
@implementation AVFlashlight
+ (BOOL)hasFlashlight { return YES; }
@end
@interface CHSWidgetExtensionProvider : NSObject
- (void)_lock_loadContentInitiallySynchronouslyIfNecessary;
@end
@implementation CHSWidgetExtensionProvider
- (void)_lock_loadContentInitiallySynchronouslyIfNecessary { loads++; }
@end
int main(int argc, char **argv) { @autoreleasepool {
    assert(argc == 4);
    version = atoi(argv[2]); process = [NSString stringWithUTF8String:argv[3]];
    Class cls = object_getClass(NSProcessInfo.processInfo);
    Method v = class_getInstanceMethod(cls, @selector(operatingSystemVersion));
    Method p = class_getInstanceMethod(cls, @selector(processName));
    class_replaceMethod(cls, @selector(operatingSystemVersion), (IMP)testVersion, method_getTypeEncoding(v));
    class_replaceMethod(cls, @selector(processName), (IMP)testProcess, method_getTypeEncoding(p));
    assert(dlopen(argv[1], RTLD_NOW));
    BOOL selected = version == 17 && [process isEqualToString:@"SpringBoard"];
    assert([AVFlashlight hasFlashlight] == !selected);
    assert(([AVFlashlight new] == nil) == selected);
    [[CHSWidgetExtensionProvider new] _lock_loadContentInitiallySynchronouslyIfNecessary];
    assert(loads == (selected ? 0 : 1));
    puts("desktop hook guard and unavailable-service behavior passed");
}}
