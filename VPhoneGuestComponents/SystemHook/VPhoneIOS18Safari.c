#include <dlfcn.h>
#include <objc/objc.h>

// SystemHook is loaded into daemons too. Use Safari's already loaded
// Objective-C runtime and Foundation classes without linking Foundation
// into every guest process.
void vpUseIOS18SafariSoftwareRendering(void) {
    Class (*getClass)(const char *) = dlsym(RTLD_DEFAULT, "objc_getClass");
    SEL (*selector)(const char *) = dlsym(RTLD_DEFAULT, "sel_registerName");
    void *send = dlsym(RTLD_DEFAULT, "objc_msgSend");
    if (!getClass || !selector || !send) return;

    Class strings = getClass("NSString");
    Class numbers = getClass("NSNumber");
    Class userDefaults = getClass("NSUserDefaults");
    if (!strings || !numbers || !userDefaults) return;

    id (*get)(id, SEL) = send;
    id (*string)(id, SEL, const char *) = send;
    id (*number)(id, SEL, BOOL) = send;
    id (*getDomain)(id, SEL, id) = send;
    void (*set)(id, SEL, id, id) = send;

    id defaults = get((id)userDefaults, selector("standardUserDefaults"));
    SEL utf8 = selector("stringWithUTF8String:");
    id name = string((id)strings, utf8, "NSArgumentDomain");
    id existing = getDomain(defaults, selector("volatileDomainForName:"), name);
    id arguments = get(existing, selector("mutableCopy"));
    id off = number((id)numbers, selector("numberWithBool:"), NO);

    // iOS 18 WebKit can paint a page but fail to display its accelerated
    // backing stores on cloudOS 26.1. Select bitmap backing stores at launch.
    // Argument-domain values are process-local, even on a used Safari profile.
    set(arguments, selector("setObject:forKey:"), off,
        string((id)strings, utf8, "WebKitDebugAcceleratedDrawingEnabled"));
    set(defaults, selector("setVolatileDomain:forName:"), arguments, name);
    ((void (*)(id, SEL))send)(arguments, selector("release"));
}
