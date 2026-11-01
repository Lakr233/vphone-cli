#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <string.h>

static id unavailableController(id self, SEL selector) { return nil; }
static void skipWidgets(id self, SEL selector) {}
static BOOL noFlashlightCapability(id self, SEL selector) { return NO; }
static id (*originalModule)(id, SEL, id);
static id moduleWithoutMediaServices(id self, SEL selector, id metadata) {
    SEL identifier = sel_registerName("moduleIdentifier");
    if ([metadata respondsToSelector:identifier]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(metadata, identifier);
        if ([value isEqual:@"com.apple.mediaremote.controlcenter.nowplaying"] ||
            [value isEqual:@"com.apple.mediaremote.controlcenter.audio"] ||
            [value isEqual:@"com.apple.mediaremote.controlcenter.airplaymirroring"]) return nil;
    }
    return originalModule(self, selector, metadata);
}

__attribute__((constructor)) static void start(void) {
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion != 16 ||
        ![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) return;
    dlopen("/System/Library/PrivateFrameworks/MediaExperience.framework/MediaExperience", RTLD_NOW);
    Class controller = objc_getClass("AVSystemController");
    Method method = class_getInstanceMethod(controller, @selector(init));
    if (method && !strcmp(method_getTypeEncoding(method), "@16@0:8")) {
        class_replaceMethod(controller, @selector(init), (IMP)unavailableController, method_getTypeEncoding(method));
        NSLog(@"[ios16-desktop] skipped unavailable audio controller");
    }
    dlopen("/System/Library/PrivateFrameworks/ChronoServices.framework/ChronoServices", RTLD_NOW);
    Class widgets = objc_getClass("CHSWidgetDescriptorProvider");
    SEL load = sel_registerName("_lock_loadContentInitiallySynchronouslyIfNecessary");
    Method loader = class_getInstanceMethod(widgets, load);
    if (loader && !strcmp(method_getTypeEncoding(loader), "v16@0:8"))
        class_replaceMethod(widgets, load, (IMP)skipWidgets, method_getTypeEncoding(loader));
    dlopen("/System/Library/PrivateFrameworks/AVFCapture.framework/AVFCapture", RTLD_NOW);
    Class flashlight = objc_getClass("AVFlashlight");
    Method lightInit = class_getInstanceMethod(flashlight, @selector(init));
    Method capability = class_getClassMethod(flashlight, sel_registerName("hasFlashlight"));
    if (lightInit && !strcmp(method_getTypeEncoding(lightInit), "@16@0:8"))
        class_replaceMethod(flashlight, @selector(init), (IMP)unavailableController, method_getTypeEncoding(lightInit));
    if (capability && !strcmp(method_getTypeEncoding(capability), "B16@0:8"))
        class_replaceMethod(object_getClass(flashlight), sel_registerName("hasFlashlight"),
                            (IMP)noFlashlightCapability, method_getTypeEncoding(capability));
    dlopen("/System/Library/PrivateFrameworks/ControlCenterUI.framework/ControlCenterUI", RTLD_NOW);
    Class modules = objc_getClass("CCUIModuleInstanceManager");
    SEL instantiate = sel_registerName("_instantiateModuleWithMetadata:");
    Method module = class_getInstanceMethod(modules, instantiate);
    if (module && !strcmp(method_getTypeEncoding(module), "@24@0:8@16")) {
        originalModule = (void *)method_getImplementation(module);
        class_replaceMethod(modules, instantiate, (IMP)moduleWithoutMediaServices, method_getTypeEncoding(module));
    }
}
