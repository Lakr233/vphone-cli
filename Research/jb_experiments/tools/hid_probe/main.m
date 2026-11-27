#import <UIKit/UIKit.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>
#include <stdlib.h>
#include <mach/mach.h>
#include <IOKit/IOKitLib.h>
// The iOS SDK ships no public IOHIDLib.h; the one HID entry point used here is declared by hand
// (same signature as macOS IOHIDLib.h / open-source IOHIDFamily IOHIDUserDeviceUserClient).
// IOHIDUserDeviceCreate is declared in macOS IOKit but is NOT exported by iOS IOKit (link fails), so the
// "create a virtual HID device from an app" path is not available through the public API.

static FILE *g_log;

static void L(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fputc('\n', g_log);
    fflush(g_log);
}


// Open a service's user clients of type 0..2. No selectors are called.
static void probe(NSString *name) {
    CFMutableDictionaryRef m = IOServiceMatching(name.UTF8String);
    if (!m) { L("SVC %s matching=NULL", name.UTF8String); return; }
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, m); // consumes m
    if (!s) { L("SVC %s inst=0", name.UTF8String); return; }
    for (int t = 0; t < 3; t++) {
        io_connect_t c = 0;
        kern_return_t r = IOServiceOpen(s, mach_task_self(), t, &c);
        L("SVC %s type=%d kr=0x%08x", name.UTF8String, t, r);
        if (r == KERN_SUCCESS) IOServiceClose(c);
    }
    IOObjectRelease(s);
}

// IOHIDManager-style: open the HID system user client by class (IOHIDUserDevice path is separate).
static void manager_probe(void) {
    CFMutableDictionaryRef m = IOServiceMatching("IOHIDUserDevice");
    io_service_t s = m ? IOServiceGetMatchingService(kIOMainPortDefault, m) : 0;
    L("IOHIDUserDevice service %s", s ? "FOUND (that is an existing virtual device, not a creation path)" : "not present (expected)");
    if (s) IOObjectRelease(s);
    L("IOHIDUserDeviceCreate: not linked on iOS (symbol absent from IOKit), virtual-device path skipped");
}

static void enumerate(void) {
    // Every IOService whose class name starts with IOHID / AppleHID / AppleHSV: name + whether it ships a user client.
    CFMutableDictionaryRef m = IOServiceMatching("IOService");
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) != KERN_SUCCESS) { L("iterate failed"); return; }
    io_object_t o; int n = 0;
    while ((o = IOIteratorNext(it))) {
        io_name_t cls = ""; IOObjectGetClass(o, cls);
        NSString *c = @(cls);
        if ([c hasPrefix:@"IOHID"] || [c hasPrefix:@"AppleHID"] || [c hasPrefix:@"AppleHSV"] || [c containsString:@"HIDDevice"]) {
            n++;
            io_service_t child = 0;
            CFMutableDictionaryRef pm = IOServiceMatching(cls);
            io_service_t s = pm ? IOServiceGetMatchingService(kIOMainPortDefault, pm) : 0;
            static NSMutableDictionary *seen = nil;
            if (!seen) seen = [NSMutableDictionary dictionary];
            if (s && !seen[c]) {
                seen[c] = @YES;
                for (int t = 0; t < 3; t++) {
                    io_connect_t cc = 0;
                    kern_return_t r = IOServiceOpen(s, mach_task_self(), t, &cc);
                    L("CLASS %s type=%d kr=0x%08x", cls, t, r);
                    if (r == KERN_SUCCESS) IOServiceClose(cc);
                }
                IOObjectRelease(s);
            }
        }
        IOObjectRelease(o);
    }
    IOObjectRelease(it);
    L("HID-named services seen: %d", n);
}

static void run(void) {
    L("iOS %s | %s | HID probe start", UIDevice.currentDevice.systemVersion.UTF8String, UIDevice.currentDevice.model.UTF8String);
    probe(@"IOHIDDevice");
    probe(@"IOHIDInterface");
    probe(@"IOHIDEventDriver");
    probe(@"AppleHSV1");
    probe(@"AppleHIDTransportHIDDevice");
    probe(@"AppleHIDTransportHIDDeviceEventDriver");
    probe(@"IOHIDEventService");
    probe(@"IOHIDEventSystem");
    probe(@"IOHIDEventSystemManager");
    manager_probe();
    enumerate();
    L("DONE");
}

@interface VC : UIViewController
@end
@implementation VC
- (void)viewDidLoad {
    [super viewDidLoad];
    UITextView *tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    tv.autoresizingMask = 0x3f;
    tv.editable = NO;
    tv.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    tv.textColor = [UIColor greenColor];
    tv.backgroundColor = [UIColor blackColor];
    self.view = tv;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"out.txt"];
        g_log = fopen(path.fileSystemRepresentation, "w");
        L("iOS %s | %s | HID probe start", UIDevice.currentDevice.systemVersion.UTF8String, UIDevice.currentDevice.model.UTF8String);
        run();
        L("DONE");
        fclose(g_log);
        NSString *txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ ((UITextView *)self.view).text = txt; });
    });
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)x {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[VC alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, @"AppDelegate");
    }
}
