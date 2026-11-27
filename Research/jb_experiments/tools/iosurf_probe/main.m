#import <UIKit/UIKit.h>
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#import <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <IOKit/IOKitLib.h>

static FILE *g_log;
static void L(const char *fmt, ...) { va_list ap; va_start(ap, fmt); vfprintf(g_log, fmt, ap); va_end(ap); fputc('\n', g_log); fflush(g_log); }

// IOSurfaceRootUserClient (23F84 table 0xfffffff007f10918): selector -> (scalars in, struct in, struct out).
// struct sizes are exactly what the dispatch table checks; no other lengths are sent.
static void call(const char *name, io_connect_t c, uint32_t sel, uint32_t nin, uint64_t *in,
                 const void *sin, size_t lin, size_t lout) {
    // the dispatch table of these selectors checks scalars_out == 0 and struct_out == lout exactly
    uint64_t out[16] = {0}; uint32_t nout = 0; static char so[0x1000]; memset(so, 0, sizeof so);
    size_t so_len = lout;
    kern_return_t r = IOConnectCallMethod(c, sel, in, nin, sin ? (void *)sin : NULL, (uint32_t)lin,
                                          lout ? out : NULL, lout ? &nout : NULL, lout ? so : NULL, lout ? &so_len : NULL);
    L("%-14s sel %2u -> 0x%08x nout=%u out0=%llu", name, sel, r, nout, (unsigned long long)out[0]);
}

static void run(void) {
    io_iterator_t it = 0;
    CFMutableDictionaryRef m = IOServiceMatching("IOSurfaceRoot");
    kern_return_t r = IOServiceGetMatchingServices(kIOMainPortDefault, m, &it);
    L("iOS %s | IOSurfaceRoot enum 0x%08x", UIDevice.currentDevice.systemVersion.UTF8String, r);
    io_service_t s; int n = 0;
    while ((s = IOIteratorNext(it))) {
        n++;
        for (int t = 0; t < 3; t++) {
            io_connect_t c = 0;
            kern_return_t o = IOServiceOpen(s, mach_task_self(), t, &c);
            L("INST %d type %d open -> 0x%08x", n, t, o);
            if (o) continue;
            // sel 4: 1 scalar, struct out 0xc68
            uint64_t one = 1;
            call("s4", c, 4, 1, &one, NULL, 0, 0xc68);
            // sel 13: 0 scalars, struct out 0x28
            call("s13", c, 13, 0, NULL, NULL, 0, 0x28);
            // sel 0 (allocate): 1 scalar + serialized dict, struct out 0xc68
            CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CFDictionarySetValue(d, CFSTR("kIOSurfaceBytesPerElement"), CFSTR("4"));
            CFDataRef xd = CFPropertyListCreateData(NULL, d, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
            CFRelease(d);
            uint64_t zero = 0;
            call("s0-alloc", c, 0, 1, &zero, CFDataGetBytePtr(xd), CFDataGetLength(xd), 0xc68);
            CFRelease(xd);
            IOServiceClose(c);
        }
        IOObjectRelease(s);
        if (n >= 3) break;
    }
    IOObjectRelease(it);
    L("DONE %d instance(s)", n);
}

@interface VC : UIViewController @end
@implementation VC
- (void)viewDidAppear:(BOOL)a {
    [super viewDidAppear:a];
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *p = [docs[0] stringByAppendingPathComponent:@"out.txt"];
    g_log = fopen(p.UTF8String, "w");
    run();
    fclose(g_log); g_log = NULL;
}
@end
@interface CD : NSObject
@property (strong) UIWindow *window;
@end
@implementation CD
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)o {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [VC new]; [self.window makeKeyAndVisible]; return YES;
}
@end
int main(int argc, char **argv) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"CD"); } }
