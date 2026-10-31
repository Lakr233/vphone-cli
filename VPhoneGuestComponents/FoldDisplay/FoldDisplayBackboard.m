// backboardd: the inner panel's render display, the surface types the device
// tree gives both panels, and the one digitizer routed to whichever is lit.

#import "FoldDisplayPrivate.h"

static id vpInnerRenderDisplay;

// MARK: - the render display

@protocol VPhoneInnerDisplayInitialization
- (instancetype)initWithOptions:(NSDictionary *)options;
@end

// Tags a render display with the BKS bit the guest itself describes as
// `unknown`. FrontBoard drops an untagged source unless it is always
// connected; this tag is what makes it publish one.
static void vpTagUnknownDisplay(id display) {
    NSString *(*describe)(NSUInteger) = dlsym(RTLD_DEFAULT, "NSStringFromBKSDisplayTags");
    SEL setter = sel_registerName("setTag:");
    Method method = class_getInstanceMethod(object_getClass(display), setter);
    if (!describe || !method || strcmp(method_getTypeEncoding(method), "v24@0:8q16") != 0) {
        vpFoldDisplayLog(@"inner display: tag unavailable");
        return;
    }
    NSUInteger unknown = 0;
    for (unsigned int bit = 0; bit < 24; bit++) {
        NSUInteger candidate = (NSUInteger)1 << bit;
        NSString *label = describe(candidate);
        if (!label || [label rangeOfString:@"unknown" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        if (unknown) { vpFoldDisplayLog(@"inner display: ambiguous unknown tag bit"); return; }
        unknown = candidate;
    }
    if (!unknown) { vpFoldDisplayLog(@"inner display: no unknown tag bit"); return; }
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(display, setter, (NSInteger)unknown);
    vpFoldDisplayLog([NSString stringWithFormat:@"inner display: tag %@ (%lu)", describe(unknown), (unsigned long)unknown]);
}

// The inner panel is a 120 Hz ProMotion panel. A virtual display's mode is
// 60 Hz whatever kCAVirtualDisplayUpdateRate says, and every client reads
// its refresh rate, heartbeat and UIScreen.maximumFramesPerSecond from that
// mode, so apps on the inner display drew at 60. The display takes digital
// modes in the framebuffer's timing format instead: one timing at the
// panel's size with a 16.16 PreciseSyncRate of 120, and one 8-bit RGB color
// mode (Colorimetry 1, as the primary's RGB_8bit). Only a mode scoring above
// 0 can be preferred, and plain RGB adds nothing, hence Score 1. A mode set
// replaces the current mode it does not contain, so this one becomes current.
static void vpSetInnerDisplayProMotionMode(id display) {
    SEL setModes = sel_registerName("setDigitalModes:withTimings:");
    Method method = class_getInstanceMethod(object_getClass(display), setModes);
    if (!method || strcmp(method_getTypeEncoding(method), "B32@0:8@16@24") != 0) {
        vpFoldDisplayLog(@"inner display: digital modes ABI unavailable, staying at 60 Hz");
        return;
    }
    NSArray *colors = @[@{@"ID": @1, @"PixelEncoding": @0, @"Depth": @8, @"Colorimetry": @1, @"EOTF": @0, @"DynamicRange": @0}];
    NSArray *timings = @[@{@"ID": @1, @"Score": @1, @"HorizontalAttributes": @{@"Active": @2007},
        @"VerticalAttributes": @{@"Active": @2853, @"PreciseSyncRate": @(120 << 16)}}];
    BOOL set = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(display, setModes, colors, timings);
    vpFoldDisplayLog([NSString stringWithFormat:@"inner display: 120 Hz mode %@", set ? @"set" : @"refused"]);
}

// A render display's point scale is what every client's CADisplay.pointScale,
// FBSDisplayMode and UIScreen.scale start from. A hardware display takes it
// from its panel; a virtual display is created at 1, and a process outside
// SpringBoard (XCTest, so WebDriverAgent; vphoned) saw the inner panel at 1x.
// Only a client holding com.apple.QuartzCore.displayable-context may change
// it, which backboardd does, through the render server once that runs: from
// inside _detectDisplays a CADisplay call never returns. A client keeps the
// scale it first read, so this runs as soon as the server answers, before
// any application starts. SpringBoard runs by then and has read 1, which is
// why its adapter still answers 3 for the inner display.
static void vpSetInnerDisplayPointScale(unsigned int attempt) {
    Method set = class_getInstanceMethod(objc_getClass("CADisplay"), sel_registerName("setDisplayProperties:"));
    Method scale = class_getInstanceMethod(objc_getClass("CADisplayProperties"), sel_registerName("setPointScale:"));
    if (!set || !scale || strcmp(method_getTypeEncoding(set), "B24@0:8@16") != 0 ||
        strcmp(method_getTypeEncoding(scale), "v24@0:8Q16") != 0) {
        vpFoldDisplayLog(@"inner display: point scale ABI unavailable, staying at 1x");
        return;
    }
    id inner = nil;
    for (id display in vpReadObject(objc_getClass("CADisplay"), "displays") ?: @[])
        if ([vpReadObject(display, "name") isEqual:vpInnerDisplayName]) inner = display;
    if (!inner) {
        if (attempt < 20)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(),
                ^{ vpSetInnerDisplayPointScale(attempt + 1); });
        else
            vpFoldDisplayLog(@"inner display: not among the render server's displays, staying at 1x");
        return;
    }
    id properties = [objc_getClass("CADisplayProperties") new];
    ((void (*)(id, SEL, unsigned long long))objc_msgSend)(properties, sel_registerName("setPointScale:"), 3);
    BOOL accepted = ((BOOL (*)(id, SEL, id))objc_msgSend)(inner, sel_registerName("setDisplayProperties:"), properties);
    vpFoldDisplayLog([NSString stringWithFormat:@"inner display: point scale 3 %@", accepted ? @"sent" : @"refused"]);
}

// Adds the inner panel's render display to a render server, once. It is
// never removed: FrontBoard keeps identities for the life of the monitor.
static BOOL vpAddInnerRenderDisplayToServer(id server) {
    if (vpInnerRenderDisplay || !server) return NO;
    @try {
        Class cls = objc_getClass("CAWindowServerVirtualDisplay");
        Method initializer = class_getInstanceMethod(cls, sel_registerName("initWithOptions:"));
        if (!initializer || strcmp(method_getTypeEncoding(initializer), "@24@0:8@16") != 0) {
            vpFoldDisplayLog(@"inner display: virtual display initializer ABI unavailable");
            return NO;
        }
        // The panel's native pixels, portrait as on hardware (669x951 points
        // at 3x); its extended properties mount it at 270 degrees, so the
        // landscape interface is drawn turned into it. Its physical size, in
        // inches, is what pixelsPerInch divides by; a virtual display has
        // none unless given one, and both panels share the cover's 460 ppi
        // pitch (MobileGestalt main-screen-pitch).
        id display = [(id<VPhoneInnerDisplayInitialization>)[cls alloc] initWithOptions:@{
            @"kCAVirtualDisplayWidth": @2007, @"kCAVirtualDisplayHeight": @2853,
            @"kCAVirtualDisplayPhysicalWidth": @(2007 / 460.0), @"kCAVirtualDisplayPhysicalHeight": @(2853 / 460.0),
            @"kCAVirtualDisplayUpdateRate": @60, @"kCAVirtualDisplayName": vpInnerDisplayName,
        }];
        if (!display) { vpFoldDisplayLog(@"inner display: initializer returned nil"); return NO; }
        vpSetInnerDisplayProMotionMode(display);
        ((void (*)(id, SEL, id))objc_msgSend)(server, sel_registerName("addDisplay:"), display);
        SEL setEnabled = sel_registerName("setEnabled:");
        Method enable = class_getInstanceMethod(object_getClass(display), setEnabled);
        if (enable && strcmp(method_getTypeEncoding(enable), "v20@0:8B16") == 0)
            ((void (*)(id, SEL, BOOL))objc_msgSend)(display, setEnabled, YES);
        vpTagUnknownDisplay(display);
        vpInnerRenderDisplay = display;
        dispatch_async(dispatch_get_main_queue(), ^{
            vpSetInnerDisplayPointScale(0);
            vpShareInnerDisplayPages(display);
        });
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: render display added %@ uniqueId=%@", display,
            [display respondsToSelector:sel_registerName("uniqueId")] ? [display valueForKey:@"uniqueId"] : @"-"]);
        return YES;
    } @catch (NSException *exception) {
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: render display exception %@", exception.reason]);
    }
    return NO;
}

// QuartzCore's shared_server_init creates the CAWindowServer (_init), finds
// the hardware displays (_detectDisplays), configures them, and only then
// registers the render server's name (CA::Render::Server::register_name),
// which is when SpringBoard and every other client can connect and read the
// display inventory. Adding the inner display after the server runs lands
// after that first read: FrontBoard's display monitor, BacklightServices'
// backlight hosts and SpringBoard's embedded-scene gate all missed it until
// SpringBoard restarted. Adding it from _detectDisplays puts it in the
// inventory before any client exists.
static IMP vpOriginalDetectDisplays;

static void vpDetectDisplaysWithInner(id self, SEL selector) {
    ((void (*)(id, SEL))vpOriginalDetectDisplays)(self, selector);
    if (vpAddInnerRenderDisplayToServer(self))
        vpFoldDisplayLog(@"inner display: added during render server display detection");
}

// The fallback for a render server that was already running when this
// library loaded: add the display once the server answers.
static void vpAddInnerRenderDisplay(unsigned int attempt) {
    if (vpInnerRenderDisplay) return;
    id server = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("CAWindowServer"), sel_registerName("serverIfRunning"));
    if (server)
        vpAddInnerRenderDisplayToServer(server);
    else if (attempt < 30)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(),
            ^{ vpAddInnerRenderDisplay(attempt + 1); });
    else
        vpFoldDisplayLog(@"inner display: render server never ran");
}

// MARK: - surface types

// backboardd's BKSDisplayTraits.surfaceType comes from DeviceSurfaceType in
// a render display's extendedProperties. The iPhone19,4 device tree gives
// display0 (the primary, the cover) surface type 1 and display1 (the inner
// panel) 2; SpringBoard's fold policies pick their panels by these.
//
// A hardware display takes its whole entry of MobileGestalt's
// DisplayExtendedProperties (rotation, scale, corner radii, chrome and
// framebuffer identifiers, read from the panel nodes the device tree repair
// adds) when QuartzCore builds it. A virtual display takes nothing, so the
// inner display is given the entry with its surface type here.
static IMP vpOriginalExtendedProperties;

static NSDictionary *vpGestaltDisplayProperties(NSNumber *surfaceType) {
    // Kept once MobileGestalt has an answer; asked again until then.
    static NSArray *entries;
    NSArray *known;
    @synchronized(NSNull.class) {
        if (!entries) {
            CFTypeRef (*copyAnswer)(CFStringRef, CFDictionaryRef) = dlsym(RTLD_DEFAULT, "MGCopyAnswer");
            id answer = copyAnswer ? CFBridgingRelease(copyAnswer(CFSTR("DisplayExtendedProperties"), NULL)) : nil;
            if ([answer isKindOfClass:NSArray.class] && [answer count]) {
                entries = answer;
                vpFoldDisplayLog([NSString stringWithFormat:@"inner display: %lu MobileGestalt display entries",
                    (unsigned long)entries.count]);
            }
        }
        known = entries;
    }
    for (NSDictionary *entry in known)
        if ([entry isKindOfClass:NSDictionary.class] && [entry[@"DeviceSurfaceType"] isEqual:surfaceType]) return entry;
    return nil;
}

static id vpSurfaceExtendedProperties(id self, SEL cmd) {
    id properties = ((id (*)(id, SEL))vpOriginalExtendedProperties)(self, cmd);
    id name = ((id (*)(id, SEL))objc_msgSend)(self, sel_registerName("deviceName"));
    BOOL inner = [name isEqual:vpInnerDisplayName];
    NSNumber *surfaceType = [name isEqual:@"primary"] ? @1 : inner ? @2 : nil;
    if (!surfaceType || (properties && ![properties isKindOfClass:NSDictionary.class])) return properties;
    NSMutableDictionary *derived = properties ? [properties mutableCopy] : [NSMutableDictionary dictionary];
    if (inner)
        [derived addEntriesFromDictionary:vpGestaltDisplayProperties(surfaceType) ?: @{}];
    derived[@"DeviceSurfaceType"] = surfaceType;
    derived[@"kMGQDeviceSurfaceType"] = surfaceType;
    // The inner panel as Xcode 27.1's iPhone Duo simulator describes its
    // second display.
    if (inner) [derived addEntriesFromDictionary:@{@"DisplayRotation": @270, @"DisplayScale": @3,
        @"ChromeIdentifier": @"com.apple.dt.devicekit.chrome.phone14", @"DeviceCornerRadius": @[@55, @55, @55, @55]}];
    return [derived copy];
}

// MARK: - one digitizer for two panels

// A real Duo has a digitizer per panel; this guest has one, bound to the
// primary display (an empty display UUID). While the inner display is lit
// (the device is open) that digitizer belongs to the inner display, so
// backboardd hit-tests touches on the inner display's own contexts.
// backboardd asks for a digitizer's display on every event and keeps
// digitizer state per display, so the state is created under the inner
// display the first time it is missing there. The inner display is portrait
// like the panel, and the panel shows it unturned, so positions carry over.
static IMP vpOriginalDigitizerDisplayUUID, vpOriginalDigitizerState;
static BOOL vpLoggedDigitizerSwitch;

static BOOL vpInnerPanelLit(void) {
    id inner = vpInnerRenderDisplay;
    return inner && [[inner valueForKey:@"enabled"] boolValue] && ![[inner valueForKey:@"isBlanked"] boolValue];
}

// Whether a render display of this backboardd has the UUID. A digitizer can
// come back from a backboardd restart still bound to an earlier run's inner
// display, a UUID no display has now: the CoreDevice touchscreen that icli and
// vphoned inject through did, and every injected touch then hit nothing.
static BOOL vpLiveDisplayUUID(id uuid) {
    id server = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("CAWindowServer"), sel_registerName("serverIfRunning"));
    for (id display in vpReadObject(server, "displays") ?: @[])
        if ([[display valueForKey:@"uniqueId"] isEqual:uuid]) return YES;
    return NO;
}

static id vpInnerDigitizerDisplayUUID(id self, SEL selector, id service) {
    id uuid = ((id (*)(id, SEL, id))vpOriginalDigitizerDisplayUUID)(self, selector, service);
    if ([uuid length] && !vpLiveDisplayUUID(uuid)) uuid = nil;
    if ([uuid length] || !vpInnerPanelLit()) return uuid;
    id inner = [vpInnerRenderDisplay valueForKey:@"uniqueId"];
    return [inner length] ? inner : uuid;
}

static id vpInnerDigitizerState(id self, SEL selector, id service) {
    id state = ((id (*)(id, SEL, id))vpOriginalDigitizerState)(self, selector, service);
    if (state || !vpInnerPanelLit()) return state;
    ((id (*)(id, SEL, id))objc_msgSend)(self, sel_registerName("_queue_addDigitizerStateForService:"), service);
    state = ((id (*)(id, SEL, id))vpOriginalDigitizerState)(self, selector, service);
    if (!vpLoggedDigitizerSwitch) {
        vpLoggedDigitizerSwitch = YES;
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: digitizer %@ now on %@ (state %@)",
            service, [vpInnerRenderDisplay valueForKey:@"uniqueId"], state]);
    }
    return state;
}

static void vpInstallInnerDigitizer(void) {
    Class processor = objc_getClass("BKHIDDirectTouchEventProcessor");
    Method uuid = class_getInstanceMethod(processor, sel_registerName("_queue_displayUUIDForDigitizerService:"));
    Method state = class_getInstanceMethod(processor, sel_registerName("_queue_digitizerStateForService:"));
    Method add = class_getInstanceMethod(processor, sel_registerName("_queue_addDigitizerStateForService:"));
    const char *encodings[] = {uuid ? method_getTypeEncoding(uuid) : "missing", state ? method_getTypeEncoding(state) : "missing",
        add ? method_getTypeEncoding(add) : "missing"};
    if (strcmp(encodings[0], "@24@0:8@16") != 0 || strcmp(encodings[1], "@24@0:8@16") != 0 || strcmp(encodings[2], "@24@0:8@16") != 0) {
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: digitizer ABI unavailable (%s, %s, %s)",
            encodings[0], encodings[1], encodings[2]]);
        return;
    }
    vpOriginalDigitizerDisplayUUID = method_setImplementation(uuid, (IMP)vpInnerDigitizerDisplayUUID);
    vpOriginalDigitizerState = method_setImplementation(state, (IMP)vpInnerDigitizerState);
    vpFoldDisplayLog(@"inner display: digitizer routing installed");
}

// MARK: - installation

void vpInstallInnerRenderDisplay(void) {
    vpInstallInnerDigitizer();
    Method extended = class_getInstanceMethod(objc_getClass("CAWindowServerDisplay"), sel_registerName("extendedProperties"));
    if (extended && strcmp(method_getTypeEncoding(extended), "@16@0:8") == 0)
        vpOriginalExtendedProperties = method_setImplementation(extended, (IMP)vpSurfaceExtendedProperties);
    else
        vpFoldDisplayLog(@"inner display: surface type ABI unavailable");
    Method detect = class_getInstanceMethod(objc_getClass("CAWindowServer"), sel_registerName("_detectDisplays"));
    if (detect && strcmp(method_getTypeEncoding(detect), "v16@0:8") == 0)
        vpOriginalDetectDisplays = method_setImplementation(detect, (IMP)vpDetectDisplaysWithInner);
    else
        vpFoldDisplayLog(@"inner display: render server display detection ABI unavailable");
    dispatch_async(dispatch_get_main_queue(), ^{ vpAddInnerRenderDisplay(0); });
}
