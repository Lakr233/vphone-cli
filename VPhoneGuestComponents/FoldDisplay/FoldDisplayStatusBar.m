// SpringBoard: each screen's status bar provider, chosen for its own panel.

#import "FoldDisplayPrivate.h"
#include "../MISFix/MISFixDetour.h"

static void *vpOriginalStatusClassLookup;
static unsigned int vpStatusLookupLogCount;

// Used only as an argument to the native, read-only provider factory. Never
// register this proxy with UIKit or publish its reference bounds to a scene.
@interface VPhoneStatusScreenPreview : NSProxy
@property(nonatomic, strong) id source;
@property(nonatomic, strong) id previewExclusion;
@property(nonatomic) CGRect referenceBounds;
@end
@implementation VPhoneStatusScreenPreview
- (CGRect)_nativeDisplayBounds { return self.referenceBounds; }
- (id)_exclusionArea { return self.previewExclusion ?: vpReadObject(self.source, "_exclusionArea"); }
- (BOOL)_isEmbeddedScreen { return NO; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector { return [self.source methodSignatureForSelector:selector]; }
- (void)forwardInvocation:(NSInvocation *)invocation { [invocation invokeWithTarget:self.source]; }
- (BOOL)respondsToSelector:(SEL)selector {
    return selector == @selector(_nativeDisplayBounds) || selector == @selector(_exclusionArea) ||
        selector == @selector(_isEmbeddedScreen) || [self.source respondsToSelector:selector];
}
@end

// Asks the native, read-only provider factory which provider the given
// Duo panel takes, by showing it a preview of the screen with that panel's
// native pixels and an exclusion area of the profile's notch. Every screen
// on this guest carries Main's MobileGestalt panel metrics, so the factory
// would otherwise pick a generic island provider. Nil unless the factory
// itself selects the profile.
static Class vpDuoPanelStatusClass(id screen, id info, BOOL inner) {
    Class (*original)(id, id) = vpOriginalStatusClassLookup;
    Class profile = objc_getClass(inner ? "STUIStatusBarVisualProvider_AxisAlignableSplit2007" :
        "STUIStatusBarVisualProvider_AxisAlignableSplitV68Cover");
    SEL notchSelector = sel_registerName("notchSize");
    NSMethodSignature *notchSignature = [profile methodSignatureForSelector:notchSelector];
    if (notchSignature.methodReturnLength != sizeof(CGSize)) return Nil;
    CGSize notch = ((CGSize (*)(id, SEL))objc_msgSend)(profile, notchSelector);
    Class shapeClass = objc_getClass("UISDisplaySingleRectShape");
    SEL initializer = sel_registerName("initWithRect:");
    NSMethodSignature *shapeSignature = [shapeClass instanceMethodSignatureForSelector:initializer];
    if (shapeSignature.numberOfArguments != 3 ||
        strcmp([shapeSignature getArgumentTypeAtIndex:2], "{CGRect={CGPoint=dd}{CGSize=dd}}") != 0) return Nil;
    VPhoneStatusScreenPreview *preview = [VPhoneStatusScreenPreview alloc];
    preview.source = screen;
    preview.referenceBounds = inner ? CGRectMake(0, 0, 2007, 2853) : CGRectMake(0, 0, 1398, 2034);
    preview.previewExclusion = ((id (*)(id, SEL, CGRect))objc_msgSend)([shapeClass alloc], initializer,
        CGRectMake(0, 0, notch.width, notch.height));
    Class selected = original(preview, info);
    return selected == profile ? selected : Nil;
}

// Each screen is one panel: the inner display's screen is the inner panel
// and Main's is the cover.
static Class vpDualStatusClassLookup(id screen, id info) {
    Class (*original)(id, id) = vpOriginalStatusClassLookup;
    if (![NSThread isMainThread]) return original(screen, info);
    id identity = vpReadObject(vpReadObject(screen, "displayConfiguration"), "identity");
    if (!identity) return original(screen, info);
    BOOL inner = vpIsInnerDisplayIdentity(identity);
    if (!inner && ![[identity description] isEqual:@"Main"]) return original(screen, info);
    Class selected = vpDuoPanelStatusClass(screen, info, inner);
    if (vpStatusLookupLogCount++ < 8)
        vpFoldDisplayLog([NSString stringWithFormat:@"status bar: %@ screen takes %@", inner ? @"inner" : @"cover",
            selected ? NSStringFromClass(selected) : @"the native provider"]);
    return selected ?: original(screen, info);
}

void vpInstallDualStatusLookup(void) {
    void *target = dlsym(RTLD_DEFAULT, "STUIStatusBarGetVisualProviderClassForScreen");
    MISFixDetourResult (*install)(const char *, void *, void *, void **) = dlsym(RTLD_DEFAULT, "MISFixDetour");
    if (!target || !install) { vpFoldDisplayLog(@"status bar: native lookup/detour API unavailable"); return; }
    MISFixDetourResult result = install("Duo per-panel status profile", target, (void *)vpDualStatusClassLookup,
        &vpOriginalStatusClassLookup);
    vpFoldDisplayLog([NSString stringWithFormat:@"status bar: per-panel lookup detour result=%d", result]);
}
