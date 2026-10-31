// SpringBoard: one physical panel for two displays. The cover and the inner
// display share this guest's only scanout, the primary; open, SpringBoard
// composites the inner display onto it.

#import "FoldDisplayPrivate.h"
#include <notify.h>

static void vpShowInnerDisplay(BOOL shown);
static void vpFollowInnerPages(void);

// MARK: - power

// SpringBoard powers each panel through its CADisplayStateControl (state 1
// on, 0 off): open, the cover (primary, display 1) goes off and the inner
// display on; closed, the reverse. On this guest the primary is the only
// scanout, and open it has to show the inner display, which SpringBoard
// composites onto it (vpShowInnerDisplay). Which panel the scanout shows
// follows the fold, not the power requests: the panel holding the primary
// content (SBDisplayContentModeCoordinator's primaryWindowScene) owns it, and
// the scanout is on while that panel wants to be. SpringBoard powers the
// panel facing away as it likes (closing does not turn the inner display off,
// and closing a sleeping device lights the inner display for a moment); on a
// real Duo that panel is folded away, so here it is not shown. The compositor
// and backboardd's touch routing follow the inner display's applied state.
static IMP vpOriginalTransitionDisplayState;
static id vpPrimaryStateControl, vpInnerStateControl;
static long long vpPrimaryWantedState = 1, vpPrimaryAppliedState = 1, vpInnerWantedState, vpInnerAppliedState = -1;

// The cover until the inner display is resolved and holds the primary content.
static BOOL vpInnerOwnsPanel(void) {
    id innerScene = vpSpringBoardWindowScene(YES);
    id coordinator = vpReadObject(vpReadObject(objc_getClass("UIApplication"), "sharedApplication"), "displayContentModeCoordinator");
    return innerScene && vpReadObject(coordinator, "primaryWindowScene") == innerScene;
}

static unsigned int vpStateControlDisplayId(id control) {
    Ivar ivar = class_getInstanceVariable(object_getClass(control), "_display_id");
    if (!ivar || strcmp(ivar_getTypeEncoding(ivar), "I") != 0) return 0;
    return *(unsigned int *)((uint8_t *)(__bridge void *)control + ivar_getOffset(ivar));
}

// When the panel last came on (system uptime), for vpFollowContentModeTransition.
static NSTimeInterval vpPanelOnAt;

static void vpApplyPanelState(id control, long long state, long long *applied, id completion) {
    if (!control || (state == *applied && !completion)) return;
    if (control == vpPrimaryStateControl && state && !*applied) vpPanelOnAt = NSProcessInfo.processInfo.systemUptime;
    *applied = state;
    ((void (*)(id, SEL, long long, id))vpOriginalTransitionDisplayState)(control,
        sel_registerName("transitionToDisplayState:withCompletion:"), state, completion);
}

static void vpApplyPanelStates(id primaryCompletion, id innerCompletion) {
    BOOL innerOwns = vpInnerOwnsPanel();
    vpApplyPanelState(vpPrimaryStateControl, (innerOwns ? vpInnerWantedState : vpPrimaryWantedState) ? 1 : 0,
        &vpPrimaryAppliedState, primaryCompletion);
    long long inner = innerOwns && vpInnerWantedState ? 1 : 0;
    BOOL changed = inner != vpInnerAppliedState;
    vpApplyPanelState(vpInnerStateControl, inner, &vpInnerAppliedState, innerCompletion);
    if (changed && vpInnerStateControl) {
        if (NSThread.isMainThread) vpShowInnerDisplay(inner != 0);
        else dispatch_async(dispatch_get_main_queue(), ^{ vpShowInnerDisplay(inner != 0); });
    }
}

// SpringBoard asks for a transition only when it wants a state the panel is
// not in; after a SpringBoard restart the inner display may already be lit and
// is never asked about. So until it is, its wanted state is the state it has.
static void vpAdoptInnerStateControl(void) {
    if (vpInnerStateControl) return;
    for (id display in vpReadObject(objc_getClass("CADisplay"), "displays") ?: @[]) {
        if (!vpIsInnerDisplay(display)) continue;
        id control = vpReadObject(display, "stateControl");
        Method current = class_getInstanceMethod(object_getClass(control), sel_registerName("displayState"));
        if (!current || strcmp(method_getTypeEncoding(current), "q16@0:8") != 0) return;
        vpInnerWantedState = vpInnerAppliedState =
            ((long long (*)(id, SEL))objc_msgSend)(control, sel_registerName("displayState")) != 0;
        vpInnerStateControl = control;
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: adopted state %lld", vpInnerWantedState]);
        if (vpInnerWantedState) dispatch_async(dispatch_get_main_queue(), ^{ vpShowInnerDisplay(YES); });
        return;
    }
}

static void vpSharedScanoutTransition(id self, SEL selector, long long state, id completion) {
    unsigned int displayId = vpStateControlDisplayId(self);
    vpFoldDisplayLog([NSString stringWithFormat:@"inner display: display %u wants state %lld", displayId, state]);
    if (displayId == 1) {
        vpAdoptInnerStateControl();
        vpPrimaryStateControl = self;
        vpPrimaryWantedState = state;
        vpApplyPanelStates(completion, nil);
        return;
    }
    id innerDisplay = nil;
    for (id display in vpReadObject(objc_getClass("CADisplay"), "displays") ?: @[])
        if ([[display valueForKey:@"displayId"] unsignedIntValue] == displayId && vpIsInnerDisplay(display)) innerDisplay = display;
    if (!innerDisplay) {
        ((void (*)(id, SEL, long long, id))vpOriginalTransitionDisplayState)(self, selector, state, completion);
        return;
    }
    vpInnerStateControl = self;
    vpInnerWantedState = state;
    vpApplyPanelStates(nil, completion);
}

// A fold moves the primary content to the other panel, which takes the
// scanout over even when no power request comes with it. An instant or fading
// transition has swapped the primary content by the time it is performed; an
// interactive one (the continuous fold of a hinge sweep) swaps it as it
// finishes, so the swap itself is followed too. SpringBoard keeps the panel it
// left lit for 3 s after a swap, and without this the scanout went on showing
// it (black) until then.
static IMP vpOriginalPerformContentModeTransition, vpOriginalHandlePrimarySwap;
static int vpInnerOwnedPanel = -1;

static void vpApplyPanelOwner(void) {
    BOOL innerOwns = vpInnerOwnsPanel();
    if (innerOwns == vpInnerOwnedPanel) return;
    vpInnerOwnedPanel = innerOwns;
    vpFoldDisplayLog([NSString stringWithFormat:@"inner display: panel owned by the %@", innerOwns ? @"inner display" : @"cover"]);
    vpApplyPanelStates(nil, nil);
}

static void vpFollowPanelOwner(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ vpApplyPanelOwner(); });
}

// SpringBoard's fold effect fades the panel being folded away to black and
// the arriving one in from black: two screens on hardware, about 0.12 s of
// black on this one panel each time it opens. Without the fade the cover dims
// and blurs and the inner display takes over at the swap. A fold made while
// the screen is dark runs only as it comes on (the pose provider commits on
// display frames), and there the fade hides what the effect carries over from
// the inner display (its Home Screen, sideways on the cover), so it stays for
// a fold that starts with the panel off or just lit.
static void vpSetFoldFadeToBlack(BOOL enabled) {
    id settings = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("SBDeviceContinuousFoldInteractionDomain"), sel_registerName("rootSettings"));
    SEL setFade = sel_registerName("setFadeToBlackEnabled:");
    if ([settings respondsToSelector:setFade]) ((void (*)(id, SEL, BOOL))objc_msgSend)(settings, setFade, enabled);
}

static void vpFollowContentModeTransition(id self, SEL selector, id transitionCoordinator) {
    vpSetFoldFadeToBlack(!vpPrimaryAppliedState || NSProcessInfo.processInfo.systemUptime - vpPanelOnAt < 1);
    ((void (*)(id, SEL, id))vpOriginalPerformContentModeTransition)(self, selector, transitionCoordinator);
    vpFollowPanelOwner();
}

// At once, in SpringBoard's own transaction: it hides the content leaving
// the panel here, and a later hop showed the panel empty in between.
static void vpFollowPrimarySwap(id self, SEL selector, id coordinator, id from, id to, id lockProvider) {
    ((void (*)(id, SEL, id, id, id, id))vpOriginalHandlePrimarySwap)(self, selector, coordinator, from, to, lockProvider);
    vpApplyPanelOwner();
}

static void vpInstallContentModeOwnership(void) {
    Method perform = class_getInstanceMethod(objc_getClass("SBDisplayContentModeCoordinator"),
        sel_registerName("performDisplayContentModeTransitionWithCoordinator:"));
    if (!perform || strcmp(method_getTypeEncoding(perform), "v24@0:8@16") != 0) {
        vpFoldDisplayLog(@"inner display: content mode transition ABI unavailable");
        return;
    }
    vpOriginalPerformContentModeTransition = method_setImplementation(perform, (IMP)vpFollowContentModeTransition);
    // SpringBoard (the application) observes every primary swap, once each.
    Method swap = class_getInstanceMethod(objc_getClass("SpringBoard"), sel_registerName(
        "displayContentModeCoordinator:handleSwapTransitionFromPrimaryWindowScene:toPrimaryWindowScene:withContinuationLockProvider:"));
    if (!swap || strcmp(method_getTypeEncoding(swap), "v48@0:8@16@24@32@40") != 0) {
        vpFoldDisplayLog(@"inner display: primary swap ABI unavailable");
        return;
    }
    vpOriginalHandlePrimarySwap = method_setImplementation(swap, (IMP)vpFollowPrimarySwap);
}

void vpInstallSharedPanel(void) {
    Method transition = class_getInstanceMethod(objc_getClass("CADisplayStateControl"),
        sel_registerName("transitionToDisplayState:withCompletion:"));
    const char *encoding = transition ? method_getTypeEncoding(transition) : "missing";
    Ivar displayId = class_getInstanceVariable(objc_getClass("CADisplayStateControl"), "_display_id");
    if (strcmp(encoding, "v32@0:8q16@?24") != 0 || !displayId || strcmp(ivar_getTypeEncoding(displayId), "I") != 0) {
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: shared scanout ABI unavailable (%s)", encoding]);
        return;
    }
    vpOriginalTransitionDisplayState = method_setImplementation(transition, (IMP)vpSharedScanoutTransition);
    vpInstallContentModeOwnership();
    vpFollowInnerPages();
    vpSetFoldFadeToBlack(NO);
    vpFoldDisplayLog(@"inner display: shared scanout installed");
}

// MARK: - compositing

// The render server's own clone of a display (addClone:options:) shows
// nothing on this guest's paravirtual panel (black with every option), so
// SpringBoard shows the inner display there itself, in a layer at the top of
// Main's root scene window (UIRootSceneWindow, the window Main's scenes
// are hosted in). It is not in a window of SB-main, because open,
// SpringBoard gives the cover (Main) auxiliary content and takes its scene's
// windows off screen. Like every window it works in points, so UIKit's
// screen capture sees it as it sees the rest of the screen. Touches never
// come here: the digitizer belongs to the inner display while it is lit
// (FoldDisplayBackboard.m).
//
// The render server draws the inner display as the inner display, so what
// the panel shows is that display's own frame: backdrops (Liquid Glass)
// sample the inner display, and SpringBoard's portals and scene hosts work
// as they do there. Drawing the inner display's layers on the primary
// display instead does not hold up. A CALayerHost of each inner window
// takes the window's context over (the render server keeps one host per
// context, and each window is already hosted in the inner display's root
// scene window), so the two hosts took the windows from each other on every
// commit and the panel lost windows for a frame or two at app launches and
// going home; a cross-display portal of the root scene window keeps the
// windows where they are, but SpringBoard's own portals inside it and every
// backdrop are drawn against the primary display: holes beside a launching
// app's icon, a black frame going home, and ghosting glass.
//
// The layer hosts backboardd's context that shows the page the inner display
// last finished (FoldDisplayInnerPages.m), so the panel shows each frame the
// inner display draws, and only those. Where backboardd publishes no context,
// SpringBoard has the render server draw the inner display into a surface of
// its own on every primary frame (CARenderServerRenderDisplay), a second full
// render each frame. Three surfaces take turns then, so the render server
// never draws into the one the panel shows or the one it showed last.
static id vpInnerPanelRoot, vpInnerPanelImage, vpInnerPanelRefresh;
static void *vpInnerPanelSurfaces[3];
static int vpInnerPanelShown;
// The hosted context, 0 while SpringBoard draws the inner display itself.
static uint32_t vpInnerPanelContextId;
static BOOL vpInnerPanelRendering; // main thread only
static dispatch_queue_t vpInnerPanelQueue;
static void (*vpRenderDisplay)(mach_port_t, CFStringRef, void *, int32_t, int32_t);
// CAFrameRateRange: minimum, maximum, preferred.
typedef struct { float minimum, maximum, preferred; } VPhoneFrameRateRange;

@interface VPhoneInnerPanelRefresh : NSObject
@end

@implementation VPhoneInnerPanelRefresh
- (void)refresh:(id)link {
    if (vpInnerPanelRendering) return;
    vpInnerPanelRendering = YES;
    int next = (vpInnerPanelShown + 1) % 3;
    void *surface = vpInnerPanelSurfaces[next];
    id image = vpInnerPanelImage;
    dispatch_async(vpInnerPanelQueue, ^{
        vpRenderDisplay(0, (__bridge CFStringRef)vpInnerDisplayName, surface, 0, 0);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (image == vpInnerPanelImage) {
                vpInnerPanelShown = next;
                Class transaction = objc_getClass("CATransaction");
                ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("begin"));
                ((void (*)(id, SEL, BOOL))objc_msgSend)(transaction, sel_registerName("setDisableActions:"), YES);
                ((void (*)(id, SEL, id))objc_msgSend)(image, sel_registerName("setContents:"), (__bridge id)surface);
                ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("commit"));
            }
            vpInnerPanelRendering = NO;
        });
    });
}
@end

static id vpMainRootSceneWindow(void) {
    NSArray *windows = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(objc_getClass("UIWindow"),
        sel_registerName("allWindowsIncludingInternalWindows:onlyVisibleWindows:"), YES, NO);
    for (id window in windows)
        if ([window isKindOfClass:objc_getClass("UIRootSceneWindow")] &&
            [[vpReadObject(vpReadObject(window, "screen"), "displayIdentity") description] isEqual:@"Main"]) return window;
    return nil;
}

// The inner display's pixels, from its CADisplay.
static CGSize vpInnerDisplayPixels(void) {
    for (id display in vpReadObject(objc_getClass("CADisplay"), "displays") ?: @[])
        if ([[display valueForKey:@"name"] isEqual:vpInnerDisplayName])
            return ((CGRect (*)(id, SEL))objc_msgSend)(display, sel_registerName("bounds")).size;
    return CGSizeZero;
}

// backboardd's context for the inner display's pages, 0 for none.
static uint32_t vpInnerPagesContext(void) {
    int token;
    uint64_t state = 0;
    if (notify_register_check(vpInnerPagesNotification, &token) != NOTIFY_STATUS_OK) return 0;
    notify_get_state(token, &state);
    notify_cancel(token);
    return (uint32_t)state;
}

static void vpReleaseInnerPanelSurfaces(void) {
    for (int index = 0; index < 3; index++) {
        if (vpInnerPanelSurfaces[index]) CFRelease(vpInnerPanelSurfaces[index]);
        vpInnerPanelSurfaces[index] = NULL;
    }
}

static void vpShowInnerDisplay(BOOL shown) {
    @try {
        if (!shown) {
            if (!vpInnerPanelRoot) return;
            ((void (*)(id, SEL))objc_msgSend)(vpInnerPanelRefresh, sel_registerName("invalidate"));
            vpInnerPanelRefresh = nil;
            ((void (*)(id, SEL))objc_msgSend)(vpInnerPanelRoot, sel_registerName("removeFromSuperlayer"));
            vpInnerPanelRoot = vpInnerPanelImage = nil;
            // A render still running finishes into its surface first.
            dispatch_async(vpInnerPanelQueue, ^{ dispatch_async(dispatch_get_main_queue(), ^{
                if (!vpInnerPanelRoot) vpReleaseInnerPanelSurfaces();
            }); });
            vpFoldDisplayLog(@"inner display: shown=0");
            return;
        }
        if (vpInnerPanelRoot) return;
        uint32_t hosted = vpInnerPagesContext();
        id rootWindow = vpMainRootSceneWindow();
        CGSize pixels = vpInnerDisplayPixels();
        void *(*createSurface)(CFDictionaryRef) =
            dlsym(dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW), "IOSurfaceCreate");
        if (!vpRenderDisplay) vpRenderDisplay = dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
        if (!rootWindow || pixels.width < 1 || (!hosted && (!createSurface || !vpRenderDisplay))) {
            vpFoldDisplayLog([NSString stringWithFormat:@"inner display: show unavailable root=%@ pixels={%.0f, %.0f}",
                rootWindow, pixels.width, pixels.height]);
            return;
        }
        if (!hosted && !vpInnerPanelSurfaces[0]) {
            NSDictionary *properties = @{@"IOSurfaceWidth": @(pixels.width), @"IOSurfaceHeight": @(pixels.height),
                @"IOSurfaceBytesPerElement": @4, @"IOSurfacePixelFormat": @((uint32_t)'BGRA')};
            for (int index = 0; index < 3; index++) vpInnerPanelSurfaces[index] = createSurface((__bridge CFDictionaryRef)properties);
            if (!vpInnerPanelSurfaces[0] || !vpInnerPanelSurfaces[1] || !vpInnerPanelSurfaces[2]) {
                vpReleaseInnerPanelSurfaces();
                vpFoldDisplayLog(@"inner display: surfaces unavailable");
                return;
            }
        }
        if (!vpInnerPanelQueue) vpInnerPanelQueue = dispatch_queue_create("com.vphone.folddisplay.inner-panel", DISPATCH_QUEUE_SERIAL);
        // The inner display is portrait like the panel and fills it as it is
        // (one that read landscape would be turned a quarter, -90 degrees).
        // The panel is the cover's, a little narrower than the inner display
        // (1398x2034 against 2007x2853), so the fill is about 2% tighter
        // across than along; it leaves no bars, and the digitizer, which
        // spans the panel, maps onto the whole inner display as it is.
        id rootLayer = vpReadObject(rootWindow, "layer");
        CGRect panel = ((CGRect (*)(id, SEL))objc_msgSend)(rootLayer, sel_registerName("bounds"));
        CGFloat pointScale = ((double (*)(id, SEL))objc_msgSend)(vpReadObject(rootWindow, "screen"), sel_registerName("scale"));
        CGSize inner = CGSizeMake(pixels.width / pointScale, pixels.height / pointScale);
        BOOL turned = inner.width > inner.height;
        CGSize upright = turned ? CGSizeMake(inner.height, inner.width) : inner;
        CGAffineTransform transform = CGAffineTransformConcat(
            turned ? CGAffineTransformMakeRotation(-M_PI_2) : CGAffineTransformIdentity,
            CGAffineTransformMakeScale(panel.size.width / upright.width, panel.size.height / upright.height));
        // backboardd's layer is in the inner display's pixels.
        if (hosted) transform = CGAffineTransformConcat(CGAffineTransformMakeScale(1 / pointScale, 1 / pointScale), transform);
        id root = [objc_getClass("CALayer") new];
        ((void (*)(id, SEL, CGRect))objc_msgSend)(root, sel_registerName("setFrame:"), panel);
        ((void (*)(id, SEL, CGColorRef))objc_msgSend)(root, sel_registerName("setBackgroundColor:"),
            ((CGColorRef (*)(id, SEL))objc_msgSend)(vpReadObject(objc_getClass("UIColor"), "blackColor"), sel_registerName("CGColor")));
        ((void (*)(id, SEL, double))objc_msgSend)(root, sel_registerName("setZPosition:"), 1.0e9);
        id image = [objc_getClass(hosted ? "CALayerHost" : "CALayer") new];
        if (hosted) ((void (*)(id, SEL, uint32_t))objc_msgSend)(image, sel_registerName("setContextId:"), hosted);
        ((void (*)(id, SEL, CGRect))objc_msgSend)(image, sel_registerName("setBounds:"), (CGRect){CGPointZero, hosted ? pixels : inner});
        ((void (*)(id, SEL, CGPoint))objc_msgSend)(image, sel_registerName("setPosition:"), CGPointMake(CGRectGetMidX(panel), CGRectGetMidY(panel)));
        ((void (*)(id, SEL, CGAffineTransform))objc_msgSend)(image, sel_registerName("setAffineTransform:"), transform);
        ((void (*)(id, SEL, id))objc_msgSend)(root, sel_registerName("addSublayer:"), image);
        ((void (*)(id, SEL, id))objc_msgSend)(rootLayer, sel_registerName("addSublayer:"), root);
        vpInnerPanelRoot = root;
        vpInnerPanelImage = image;
        vpInnerPanelContextId = hosted;
        NSInteger fps = ((NSInteger (*)(id, SEL))objc_msgSend)(vpReadObject(rootWindow, "screen"), sel_registerName("maximumFramesPerSecond"));
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: shown=1 panel={%.0f, %.0f} inner={%.0f, %.0f} turned=%d scale={%.3f, %.3f} fps=%ld context=%u",
            panel.size.width, panel.size.height, inner.width, inner.height, turned,
            panel.size.width / upright.width, panel.size.height / upright.height, (long)fps, hosted]);
        if (hosted) return;
        vpInnerPanelRefresh = ((id (*)(id, SEL, id, SEL))objc_msgSend)(objc_getClass("CADisplayLink"),
            sel_registerName("displayLinkWithTarget:selector:"), [VPhoneInnerPanelRefresh new], @selector(refresh:));
        // The panel shows the inner display at the panel's top rate, asked for
        // rather than left to the system's choice for a link with no range.
        SEL setRange = sel_registerName("setPreferredFrameRateRange:");
        if (fps > 60 && [vpInnerPanelRefresh respondsToSelector:setRange])
            ((void (*)(id, SEL, VPhoneFrameRateRange))objc_msgSend)(vpInnerPanelRefresh, setRange, (VPhoneFrameRateRange){fps, fps, fps});
        ((void (*)(id, SEL, id, id))objc_msgSend)(vpInnerPanelRefresh, sel_registerName("addToRunLoop:forMode:"),
            NSRunLoop.mainRunLoop, NSRunLoopCommonModes);
    } @catch (NSException *exception) {
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: show exception %@", exception.reason]);
    }
}

// backboardd publishes its context with the inner display's first page,
// which can come after the panel is shown, and takes it back if it cannot
// read a page.
static void vpFollowInnerPages(void) {
    int token;
    notify_register_dispatch(vpInnerPagesNotification, &token, dispatch_get_main_queue(), ^(int unused) {
        if (!vpInnerPanelRoot || vpInnerPagesContext() == vpInnerPanelContextId) return;
        vpShowInnerDisplay(NO);
        vpShowInnerDisplay(YES);
    });
}
