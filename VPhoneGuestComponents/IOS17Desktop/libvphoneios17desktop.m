#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
static id noFlashlight(id self, SEL sel) { return nil; }
static BOOL noFlashlightCapability(id self, SEL sel) { return NO; }
static void skipUnavailableWidgets(id self, SEL sel) {}
__attribute__((constructor)) static void start(void) {
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion != 17 ||
        ![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) return;
    dlopen("/System/Library/PrivateFrameworks/ChronoServices.framework/ChronoServices", RTLD_LAZY);
    Class widgets = objc_getClass("CHSWidgetExtensionProvider");
    SEL load = sel_registerName("_lock_loadContentInitiallySynchronouslyIfNecessary");
    Method loader = class_getInstanceMethod(widgets, load);
    if (loader) class_replaceMethod(widgets, load, (IMP)skipUnavailableWidgets, method_getTypeEncoding(loader));
    dlopen("/System/Library/PrivateFrameworks/AVFCapture.framework/AVFCapture", RTLD_LAZY);
    Class cls = objc_getClass("AVFlashlight");
    if (!cls) { NSLog(@"[ios17-desktop-fix] AVFlashlight absent"); return; }
    Method init = class_getInstanceMethod(cls, @selector(init));
    if (init) class_replaceMethod(cls, @selector(init), (IMP)noFlashlight, method_getTypeEncoding(init));
    SEL cap = sel_registerName("hasFlashlight");
    Method has = class_getClassMethod(cls, cap);
    if (has) class_replaceMethod(object_getClass(cls), cap, (IMP)noFlashlightCapability, method_getTypeEncoding(has));
    NSLog(@"[ios17-desktop-fix] disabled unavailable virtual flashlight");
}
