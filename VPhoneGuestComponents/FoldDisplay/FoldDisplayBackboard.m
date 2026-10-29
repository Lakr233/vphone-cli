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
void vpTagRenderDisplay(id display, NSString *tagName) {
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
        if (!label || [label rangeOfString:tagName options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
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
    NSArray *timings = @[@{@"ID": @1, @"Score": @1, @"HorizontalAttributes": @{@"Active": @2853},
        @"VerticalAttributes": @{@"Active": @2007, @"PreciseSyncRate": @(120 << 16)}}];
    BOOL set = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(display, setModes, colors, timings);
    vpFoldDisplayLog([NSString stringWithFormat:@"inner display: 120 Hz mode %@", set ? @"set" : @"refused"]);
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
        // The panel's native pixels, landscape: 951x669 points at 3x.
        id display = [(id<VPhoneInnerDisplayInitialization>)[cls alloc] initWithOptions:@{
            @"kCAVirtualDisplayWidth": @2853, @"kCAVirtualDisplayHeight": @2007,
            @"kCAVirtualDisplayUpdateRate": @60, @"kCAVirtualDisplayName": vpInnerDisplayName,
        }];
        if (!display) { vpFoldDisplayLog(@"inner display: initializer returned nil"); return NO; }
        vpSetInnerDisplayProMotionMode(display);
        ((void (*)(id, SEL, id))objc_msgSend)(server, sel_registerName("addDisplay:"), display);
        SEL setEnabled = sel_registerName("setEnabled:");
        Method enable = class_getInstanceMethod(object_getClass(display), setEnabled);
        if (enable && strcmp(method_getTypeEncoding(enable), "v20@0:8B16") == 0)
            ((void (*)(id, SEL, BOOL))objc_msgSend)(display, setEnabled, YES);
        vpTagRenderDisplay(display, @"unknown");
        vpInnerRenderDisplay = display;
        vpPrepareExternalRenderDisplays(server);
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
static IMP vpOriginalExtendedProperties;

static id vpSurfaceExtendedProperties(id self, SEL cmd) {
    id properties = ((id (*)(id, SEL))vpOriginalExtendedProperties)(self, cmd);
    id name = ((id (*)(id, SEL))objc_msgSend)(self, sel_registerName("deviceName"));
    NSNumber *surfaceType = [name isEqual:@"primary"] ? @1 : [name isEqual:vpInnerDisplayName] ? @2 : nil;
    if (!surfaceType || (properties && ![properties isKindOfClass:NSDictionary.class])) return properties;
    NSMutableDictionary *derived = properties ? [properties mutableCopy] : [NSMutableDictionary dictionary];
    derived[@"DeviceSurfaceType"] = surfaceType;
    return [derived copy];
}

// MARK: - one digitizer for two panels

// A real Duo has a digitizer per panel; this guest has one, bound to the
// primary display (an empty display UUID). While the inner display is lit
// (the device is open) that digitizer belongs to the inner display, so
// backboardd hit-tests touches on the inner display's own contexts.
// backboardd asks for a digitizer's display on every event and keeps
// digitizer state per display, so the state is created under the inner
// display the first time it is missing there.
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

// The inner panel is mounted at 270 degrees (device tree display1), so its
// digitizer reports positions in the panel's portrait frame, and the panel
// shows the inner display turned to match. This guest's single digitizer
// reports positions on the portrait cover panel, which backboardd would
// stretch onto the inner display's landscape space unturned; while the
// inner display has the digitizer, each finger's normalized position is
// turned by the mount first.
typedef struct __IOHIDEvent *VPHIDEventRef;
static IMP vpOriginalHandleDirectTouch;
static CFArrayRef (*vpHIDEventChildren)(VPHIDEventRef);
static uint32_t (*vpHIDEventType)(VPHIDEventRef);
static double (*vpHIDEventGetFloat)(VPHIDEventRef, uint32_t);
static void (*vpHIDEventSetFloat)(VPHIDEventRef, uint32_t, double);

static void vpTurnDigitizerPosition(VPHIDEventRef event) {
    static const uint32_t digitizer = 11, x = 11 << 16, y = (11 << 16) | 1;
    if (vpHIDEventType(event) == digitizer) {
        double nx = vpHIDEventGetFloat(event, x), ny = vpHIDEventGetFloat(event, y);
        vpHIDEventSetFloat(event, x, 1 - ny);
        vpHIDEventSetFloat(event, y, nx);
    }
    CFArrayRef children = vpHIDEventChildren(event);
    for (CFIndex index = 0; children && index < CFArrayGetCount(children); index++)
        vpTurnDigitizerPosition((VPHIDEventRef)CFArrayGetValueAtIndex(children, index));
}

static void vpInnerHandleDirectTouch(id self, SEL selector, void *event, id service) {
    // Only the built-in digitizer is repurposed for the inner panel. CarPlay
    // and other external displays already supply their own display UUID and
    // coordinate space. Ask the original resolver, before our routing hook
    // replaces the built-in digitizer's empty UUID with the inner display's.
    id originalDisplayUUID = ((id (*)(id, SEL, id))vpOriginalDigitizerDisplayUUID)(self,
        sel_registerName("_queue_displayUUIDForDigitizerService:"), service);
    if (event && ![originalDisplayUUID length] && vpInnerPanelLit())
        vpTurnDigitizerPosition((VPHIDEventRef)event);
    ((void (*)(id, SEL, void *, id))vpOriginalHandleDirectTouch)(self, selector, event, service);
}

static void vpInstallInnerDigitizerTurn(Class processor) {
    Method handle = class_getInstanceMethod(processor, sel_registerName("_handleDirectTouchEvent:service:"));
    const char *encoding = handle ? method_getTypeEncoding(handle) : "missing";
    vpHIDEventChildren = dlsym(RTLD_DEFAULT, "IOHIDEventGetChildren");
    vpHIDEventType = dlsym(RTLD_DEFAULT, "IOHIDEventGetType");
    vpHIDEventGetFloat = dlsym(RTLD_DEFAULT, "IOHIDEventGetFloatValue");
    vpHIDEventSetFloat = dlsym(RTLD_DEFAULT, "IOHIDEventSetFloatValue");
    size_t length = strlen(encoding);
    if (!vpHIDEventChildren || !vpHIDEventType || !vpHIDEventGetFloat || !vpHIDEventSetFloat ||
        strncmp(encoding, "v32@0:8", 7) != 0 || length < 3 || strcmp(encoding + length - 3, "@24") != 0) {
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: digitizer turn ABI unavailable (%s)", encoding]);
        return;
    }
    vpOriginalHandleDirectTouch = method_setImplementation(handle, (IMP)vpInnerHandleDirectTouch);
    vpFoldDisplayLog([NSString stringWithFormat:@"inner display: digitizer turn installed (%s)", encoding]);
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
    vpInstallInnerDigitizerTurn(processor);
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
