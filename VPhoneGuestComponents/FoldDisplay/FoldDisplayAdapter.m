// SpringBoard: how the system sees the inner display, and handing it to the
// content mode resolver so the hinge can move content onto it.

#import "FoldDisplayPrivate.h"

static id vpInnerIdentity;

BOOL vpIsInnerDisplayIdentity(id identity) {
    return identity && vpInnerIdentity && [identity isEqual:vpInnerIdentity];
}

// MARK: - the inner display and its scenes

BOOL vpIsInnerDisplay(id display) {
    @try {
        for (NSString *key in @[@"name", @"deviceName"]) {
            if ([display respondsToSelector:NSSelectorFromString(key)] &&
                [[display valueForKey:key] isEqual:vpInnerDisplayName]) return YES;
        }
    } @catch (__unused NSException *exception) {
    }
    return NO;
}

BOOL vpSceneIsOnInnerDisplay(id scene) {
    id configuration = vpReadObject(vpReadObject(vpReadObject(scene, "_FBSScene"), "settings"), "displayConfiguration");
    id identity = vpReadObject(configuration, "identity");
    return vpIsInnerDisplayIdentity(identity);
}

id vpSpringBoardWindowScene(BOOL inner) {
    id app = vpReadObject(objc_getClass("UIApplication"), "sharedApplication");
    for (id scene in [vpReadObject(app, "connectedScenes") allObjects] ?: @[])
        if ([scene class] == objc_getClass("SBWindowScene") && vpSceneIsOnInnerDisplay(scene) == inner) return scene;
    return nil;
}

// MARK: - classification

// The inner panel is a built-in panel (CADisplay type 0) to everything that
// asks: BacklightServices gives a backlight host only to built-in displays,
// and every SpringBoard window scene needs one; SpringBoard's startup waits
// for a scene on every built-in display. Only FrontBoard's configuration
// classification sees type 4: in _FBSCADisplayToDisplayTypes that type is
// always-connected without being UIKit-main-like, so only the real Main
// claims the cloning source (claiming it twice is SpringBoard's "Cloning
// source already exists" assertion).
static IMP vpOriginalDisplayType, vpOriginalPointScale, vpOriginalExternal, vpOriginalConfigurationInit;
static _Thread_local BOOL vpClassifyingConfiguration;

static long long vpInnerDisplayType(id self, SEL selector) {
    if (!vpIsInnerDisplay(self)) return ((long long (*)(id, SEL))vpOriginalDisplayType)(self, selector);
    return vpClassifyingConfiguration ? 4 : 0;
}

static id vpInnerConfigurationInit(id self, SEL selector, id display, id original, BOOL isMain, BOOL assertIfInvalid) {
    vpClassifyingConfiguration = YES;
    id result = ((id (*)(id, SEL, id, id, BOOL, BOOL))vpOriginalConfigurationInit)(self, selector, display, original, isMain, assertIfInvalid);
    vpClassifyingConfiguration = NO;
    if (vpIsInnerDisplay(display) && !vpInnerIdentity) vpInnerIdentity = vpReadObject(result, "identity");
    return result;
}

static NSUInteger vpInnerPointScale(id self, SEL selector) {
    return vpIsInnerDisplay(self) ? 3 : ((NSUInteger (*)(id, SEL))vpOriginalPointScale)(self, selector);
}

static BOOL vpInnerExternal(id self, SEL selector) {
    return vpIsInnerDisplay(self) ? NO : ((BOOL (*)(id, SEL))vpOriginalExternal)(self, selector);
}

static IMP vpReplaceDisplayGetter(const char *name, const char *encoding, IMP replacement) {
    Method method = class_getInstanceMethod(objc_getClass("CADisplay"), sel_registerName(name));
    if (!method || strcmp(method_getTypeEncoding(method), encoding) != 0) {
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: -[CADisplay %s] %s, expected %s", name,
            method ? method_getTypeEncoding(method) : "missing", encoding]);
        return NULL;
    }
    return method_setImplementation(method, replacement);
}

// MARK: - idiom

// Applications take the scene's display identity from SpringBoard. UIKit
// gives a screen the device idiom only when that identity is UIKit-main-like
// and leaves it unspecified (-1) otherwise; UIKit's Swift idiom switches
// (sheet presentation, scroll edge effects) trap on -1. The identity
// SpringBoard keeps stays as classified, so only Main claims the cloning
// source; the copy an application decodes says main-like.
static IMP vpOriginalIdentityEncode;

static void vpInnerIdentityEncode(id self, SEL selector, xpc_object_t dictionary) {
    ((void (*)(id, SEL, xpc_object_t))vpOriginalIdentityEncode)(self, selector, dictionary);
    if (dictionary && vpInnerIdentity && [self isEqual:vpInnerIdentity])
        xpc_dictionary_set_bool(dictionary, "mainLike", true);
}

static void vpInstallInnerIdentityEncode(void) {
    Method encode = class_getInstanceMethod(objc_getClass("FBSDisplayIdentity"), sel_registerName("encodeWithXPCDictionary:"));
    if (!encode || strcmp(method_getTypeEncoding(encode), "v24@0:8@16") != 0) {
        vpFoldDisplayLog(@"inner display: identity encoding ABI unavailable");
        return;
    }
    vpOriginalIdentityEncode = method_setImplementation(encode, (IMP)vpInnerIdentityEncode);
}

// SpringBoard's own screens follow the same rule: UIScreen takes the device
// idiom only for a UIKit-main-like screen and leaves every other non-car
// screen unspecified (-1); UIKit's Swift idiom switch (ScrollEdgeEffectView)
// traps on -1 during posture changes. The inner panel is a built-in phone
// panel, so its screen takes the device idiom too.
static IMP vpOriginalUpdateScreenIdiom;

static void vpInnerUpdateScreenIdiom(id self, SEL selector) {
    ((void (*)(id, SEL))vpOriginalUpdateScreenIdiom)(self, selector);
    id identity = vpReadObject(vpReadObject(self, "displayConfiguration"), "identity");
    if (!vpIsInnerDisplayIdentity(identity)) return;
    if (((long long (*)(id, SEL))objc_msgSend)(self, sel_registerName("_userInterfaceIdiom")) != -1) return;
    long long idiom = ((long long (*)(id, SEL))objc_msgSend)(vpReadObject(objc_getClass("UIDevice"), "currentDevice"),
        sel_registerName("userInterfaceIdiom"));
    ((void (*)(id, SEL, long long))objc_msgSend)(self, sel_registerName("_setUserInterfaceIdiom:"), idiom);
}

static void vpInstallInnerScreenIdiom(void) {
    Class screen = objc_getClass("UIScreen");
    Method update = class_getInstanceMethod(screen, sel_registerName("_updateUserInterfaceIdiom"));
    Method set = class_getInstanceMethod(screen, sel_registerName("_setUserInterfaceIdiom:"));
    Method get = class_getInstanceMethod(screen, sel_registerName("_userInterfaceIdiom"));
    if (!update || !set || !get || strcmp(method_getTypeEncoding(update), "v16@0:8") != 0 ||
        strcmp(method_getTypeEncoding(set), "v24@0:8q16") != 0 || strcmp(method_getTypeEncoding(get), "q16@0:8") != 0) {
        vpFoldDisplayLog(@"inner display: screen idiom ABI unavailable");
        return;
    }
    vpOriginalUpdateScreenIdiom = method_setImplementation(update, (IMP)vpInnerUpdateScreenIdiom);
}

// MARK: - inner screen corners

// The synthetic inner display has no native corner metadata. UIKit therefore
// supplies zero for its screen, which leaves the expanded Now Playing aperture
// rectangular. Reuse the device's native main-screen metric only for this
// display and only when UIKit has no radius of its own. Do not change external
// screens or replace a future native inner-panel value.
static IMP vpOriginalScreenCornerRadius, vpOriginalScreenCornerRadiusIgnoringZoom;
static unsigned int vpCornerRadiusLogCount;

static double vpInnerScreenCornerRadius(id self, SEL selector) {
    IMP original = selector == sel_registerName("_displayCornerRadiusIgnoringZoom") ?
        vpOriginalScreenCornerRadiusIgnoringZoom : vpOriginalScreenCornerRadius;
    double radius = ((double (*)(id, SEL))original)(self, selector);
    id configuration = vpReadObject(self, "displayConfiguration");
    id identity = vpReadObject(configuration, "identity");
    if (!identity || !vpInnerIdentity || ![identity isEqual:vpInnerIdentity]) return radius;
    id main = vpReadObject(objc_getClass("UIScreen"), "mainScreen");
    double fallback = main && main != self ? ((double (*)(id, SEL))original)(main, selector) : 0;
    double result = radius > 0 ? radius : fallback;
    if (vpCornerRadiusLogCount++ < 4)
        vpFoldDisplayLog([NSString stringWithFormat:@"inner screen corners: %s native=%.2f main=%.2f effective=%.2f",
            sel_getName(selector), radius, fallback, result]);
    return result;
}

static void vpInstallInnerScreenCorners(void) {
    Class screen = objc_getClass("UIScreen");
    Method radius = class_getInstanceMethod(screen, sel_registerName("_displayCornerRadius"));
    Method unzoomed = class_getInstanceMethod(screen, sel_registerName("_displayCornerRadiusIgnoringZoom"));
    if (!radius || !unzoomed || strcmp(method_getTypeEncoding(radius), "d16@0:8") != 0 ||
        strcmp(method_getTypeEncoding(unzoomed), "d16@0:8") != 0) {
        vpFoldDisplayLog(@"inner screen corners: getter ABI unavailable");
        return;
    }
    vpOriginalScreenCornerRadius = method_setImplementation(radius, (IMP)vpInnerScreenCornerRadius);
    vpOriginalScreenCornerRadiusIgnoringZoom = method_setImplementation(unzoomed, (IMP)vpInnerScreenCornerRadius);
}

// MARK: - content mode resolution

// SpringBoard's display content mode coordinator starts resolving a window
// scene's display when the scene connects to it; the inner display's scene
// is never handed over, so the hinge could not move content to it. The
// resolver is recorded as it starts resolving Main, and the inner scene is
// handed over once it and the resolver both exist (the resolver keys its
// display proxies by hardware identifier, so this runs once per
// SpringBoard).
static IMP vpOriginalStartResolvingDisplay;
static __weak id vpContentModeResolver;

static void vpRecordContentModeResolver(id self, SEL selector, id proxy) {
    ((void (*)(id, SEL, id))vpOriginalStartResolvingDisplay)(self, selector, proxy);
    vpContentModeResolver = self;
}

// Whether the inner display is resolved, handing it over first if needed.
static BOOL vpHandOverInnerDisplay(void) {
    id app = vpReadObject(objc_getClass("UIApplication"), "sharedApplication");
    id coordinator = vpReadObject(app, "displayContentModeCoordinator");
    id innerScene = vpSpringBoardWindowScene(YES);
    id resolver = vpContentModeResolver;
    Method connect = class_getInstanceMethod(object_getClass(coordinator), sel_registerName("windowSceneDidConnect:"));
    if (!coordinator || !innerScene || !resolver || !connect || strcmp(method_getTypeEncoding(connect), "v24@0:8@16") != 0)
        return NO;
    id identifier = vpReadObject(vpReadObject(vpReadObject(vpReadObject(innerScene, "_FBSScene"), "settings"),
        "displayConfiguration"), "hardwareIdentifier");
    if ([[vpReadObjectIvar(resolver, "_displayProxies") allKeys] containsObject:identifier]) return YES;
    ((void (*)(id, SEL, id))objc_msgSend)(coordinator, sel_registerName("windowSceneDidConnect:"), innerScene);
    vpFoldDisplayLog([NSString stringWithFormat:@"inner display: handed %@ to the content mode resolver: %@",
        vpReadObject(vpReadObject(innerScene, "_FBSScene"), "identifier"), resolver]);
    return [[vpReadObjectIvar(resolver, "_displayProxies") allKeys] containsObject:identifier];
}

// From SpringBoard's start, until the inner display is resolved.
static void vpWatchInnerDisplayResolution(void) {
    static dispatch_source_t timer;
    static unsigned int attempts;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(timer, ^{
        BOOL resolved = NO;
        @try { resolved = vpHandOverInnerDisplay(); } @catch (__unused NSException *exception) {}
        if (resolved || ++attempts >= 600) {
            dispatch_source_cancel(timer);
            vpFoldDisplayLog([NSString stringWithFormat:@"inner display: resolution watch done resolved=%d after %u s", resolved, attempts]);
        }
    });
    dispatch_resume(timer);
}

static void vpInstallContentModeResolution(void) {
    Method start = class_getInstanceMethod(objc_getClass("SBFDisplayContentModeResolver"),
        sel_registerName("_startResolvingContentModeOfDisplay:"));
    if (!start || strcmp(method_getTypeEncoding(start), "v24@0:8@16") != 0) {
        vpFoldDisplayLog(@"inner display: content mode resolver ABI unavailable");
        return;
    }
    vpOriginalStartResolvingDisplay = method_setImplementation(start, (IMP)vpRecordContentModeResolver);
    vpWatchInnerDisplayResolution();
}

// MARK: - orientation

// Each panel's traits pipeline turns with its own device orientation, which
// SpringBoard reads from the device pose per panel
// (BSDeviceOrientationForSurfaceFromPose) and fills in from
// +[CMMagicPoseManager orientationForMagicPose:deviceSurface:]. That asks
// CoreMotion's shared magic pose manager to rebuild a device state event
// first, and this guest has no motion coprocessor, so there is no manager:
// the message goes to nil and every panel reads ambiguous, so neither turns.
// The answer is CMDeviceStateEvent's own mapping of the pose's orientation,
// hinge state and tabletop pose, asked directly.
static long long vpPanelOrientation(id self, SEL selector, id pose, long long surface) {
    long long (*read)(id, SEL) = (long long (*)(id, SEL))objc_msgSend;
    return ((long long (*)(id, SEL, long long, long long, long long, long long))objc_msgSend)(objc_getClass("CMDeviceStateEvent"),
        sel_registerName("propertyAForConfigType:propertyA:propertyB:propertyC:"), surface,
        read(pose, sel_registerName("deviceOrientation")), read(pose, sel_registerName("hingeState")),
        read(pose, sel_registerName("tabletopPose")));
}

static void vpInstallPanelOrientation(void) {
    Method orientation = class_getClassMethod(objc_getClass("CMMagicPoseManager"),
        sel_registerName("orientationForMagicPose:deviceSurface:"));
    Method mapping = class_getClassMethod(objc_getClass("CMDeviceStateEvent"),
        sel_registerName("propertyAForConfigType:propertyA:propertyB:propertyC:"));
    if (!orientation || !mapping || strcmp(method_getTypeEncoding(orientation), "q32@0:8@16q24") != 0 ||
        strcmp(method_getTypeEncoding(mapping), "q48@0:8q16q24q32q40") != 0) {
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: panel orientation ABI unavailable (%s, %s)",
            orientation ? method_getTypeEncoding(orientation) : "missing", mapping ? method_getTypeEncoding(mapping) : "missing"]);
        return;
    }
    method_setImplementation(orientation, (IMP)vpPanelOrientation);
}

// MARK: - installation

// Installed before SpringBoard's display monitor reads the render displays.
// CADisplay has no always-connected getter; FrontBoard derives that from
// the type.
void vpInstallInnerDisplayAdapter(void) {
    vpInstallInnerScreenIdiom();
    vpInstallInnerScreenCorners();
    vpInstallInnerIdentityEncode();
    vpInstallPanelOrientation();
    // Type 0 without the FrontBoard scope is a second UIKit-main-like
    // display, so no scope means no adapter.
    Method configurationInit = class_getInstanceMethod(objc_getClass("FBSDisplayConfiguration"),
        sel_registerName("_initWithImmutableDisplay:originalDisplay:isMainDisplay:assertIfInvalid:"));
    const char *encoding = configurationInit ? method_getTypeEncoding(configurationInit) : "missing";
    if (strcmp(encoding, "@40@0:8@16@24B32B36") != 0) {
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: configuration initializer %s, adapter off", encoding]);
        return;
    }
    vpOriginalConfigurationInit = method_setImplementation(configurationInit, (IMP)vpInnerConfigurationInit);
    vpOriginalDisplayType = vpReplaceDisplayGetter("displayType", "q16@0:8", (IMP)vpInnerDisplayType);
    vpOriginalPointScale = vpReplaceDisplayGetter("pointScale", "Q16@0:8", (IMP)vpInnerPointScale);
    vpOriginalExternal = vpReplaceDisplayGetter("isExternal", "B16@0:8", (IMP)vpInnerExternal);
    vpFoldDisplayLog([NSString stringWithFormat:@"inner display: adapter type=%d scale=%d external=%d",
        vpOriginalDisplayType != NULL, vpOriginalPointScale != NULL, vpOriginalExternal != NULL]);
    vpInstallContentModeResolution();
}
