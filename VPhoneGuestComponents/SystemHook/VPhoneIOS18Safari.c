#include <stdbool.h>
#include <dlfcn.h>
#include <objc/objc.h>
#include <objc/runtime.h>

static void (*vpInitializeWebView)(id, SEL, id);
static void (*vpSetCanvasUsesAcceleratedDrawing)(id, bool);
static void *vpCanvasMessageSend;
static SEL vpCanvasPreferencesSelector;

static void vpInitializeWebViewWithSoftwareCanvas(id view, SEL command, id configuration) {
    id preferences = ((id (*)(id, SEL))vpCanvasMessageSend)(configuration, vpCanvasPreferencesSelector);
    // Cocoa's opaque WKPreferencesRef is the Objective-C wrapper.
    if (preferences) vpSetCanvasUsesAcceleratedDrawing(preferences, false);
    vpInitializeWebView(view, command, configuration);
}

static void vpInstallSoftwareCanvas(Class (*getClass)(const char *),
                                    SEL (*selector)(const char *), void *send) {
    Method (*getMethod)(Class, SEL) = dlsym(RTLD_DEFAULT, "class_getInstanceMethod");
    IMP (*implementation)(Method) = dlsym(RTLD_DEFAULT, "method_getImplementation");
    IMP (*replace)(Method, IMP) = dlsym(RTLD_DEFAULT, "method_setImplementation");
    vpSetCanvasUsesAcceleratedDrawing = dlsym(RTLD_DEFAULT, "WKPreferencesSetCanvasUsesAcceleratedDrawing");
    if (!getMethod || !implementation || !replace || !vpSetCanvasUsesAcceleratedDrawing) return;

    Class webView = getClass("WKWebView");
    Class configuration = getClass("WKWebViewConfiguration");
    SEL initialize = selector("_initializeWithConfiguration:");
    vpCanvasPreferencesSelector = selector("preferences");
    if (!webView || !configuration || !getMethod(configuration, vpCanvasPreferencesSelector))
        return;

    Method method = getMethod(webView, initialize);
    if (!method) return;

    // Turning off GPU-process canvas rendering leaves the WebContent process
    // free to allocate an accelerated buffer for larger 2D canvases. Select
    // software before WebKit copies the configuration into its new page.
    vpCanvasMessageSend = send;
    vpInitializeWebView = (void (*)(id, SEL, id))implementation(method);
    replace(method, (IMP)vpInitializeWebViewWithSoftwareCanvas);
}

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
    // Safari reads this feature flag independently of GraphicsLayer drawing.
    // A GPU-backed 2D canvas can still be blank on an otherwise visible page.
    set(arguments, selector("setObject:forKey:"), off,
        string((id)strings, utf8, "WebKitExperimentalUseGPUProcessForCanvasRenderingEnabled"));
    set(defaults, selector("setVolatileDomain:forName:"), arguments, name);
    ((void (*)(id, SEL))send)(arguments, selector("release"));
    vpInstallSoftwareCanvas(getClass, selector, send);
}
