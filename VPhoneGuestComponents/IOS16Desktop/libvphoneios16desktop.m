#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <string.h>
#import <unistd.h>
#include "VPhoneIOS16LabPolicy.h"

static BOOL (*originalHasPasscode)(id, SEL);
static BOOL (*originalEffectivelyLocked)(id, SEL);
static BOOL (*originalMCPasscode)(id, SEL);
static BOOL labHasPasscode(id self, SEL selector) {
    return vp_ios16_keybagless_ui_attested() ? NO : originalHasPasscode(self, selector);
}
static BOOL labEffectivelyLocked(id self, SEL selector) {
    return vp_ios16_keybagless_ui_attested() ? NO : originalEffectivelyLocked(self, selector);
}
static BOOL labMCPasscode(id self, SEL selector) {
    return vp_ios16_keybagless_ui_attested() ? NO : originalMCPasscode(self, selector);
}

static void (*originalBacklight)(id, SEL, NSInteger, NSInteger, BOOL, id);
static int (*setLegacyBacklight)(float, float, BOOL);
static void backlightWithLegacyHIDState(id self, SEL selector, NSInteger state,
                                      NSInteger source, BOOL animated, id completion) {
    originalBacklight(self, selector, state, source, animated, completion);
    float factor = ((float (*)(id, SEL, NSInteger))objc_msgSend)(self,
        sel_registerName("_factorToPublishForBacklightState:"), state);
    if (factor >= 0.f && factor <= 1.f) {
        int result = setLegacyBacklight(factor, 0.f, YES);
        NSLog(@"[ios16-desktop] legacy HID backlight state %ld factor %g: %d", (long)state, factor, result);
    }
}

static id unavailableController(id self, SEL selector) { return nil; }
static void skipWidgets(id self, SEL selector) {}
static BOOL noFlashlightCapability(id self, SEL selector) { return NO; }
static BOOL labSetupMode(id self, SEL selector) {
    // The fresh, keybag-less lab cannot persist purplebuddy preferences. Keep
    // this in SpringBoard's local state; do not claim setup or migration was
    // completed in the user's preferences or touch the keybag.
    return ((BOOL (*)(id, SEL, NSUInteger))objc_msgSend)(self, sel_registerName("_setSetupRequiredReason:"), 0);
}
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
    if (access(VP_IOS16_KEYBAGLESS_SELECTION, F_OK) == 0) {
        // UI model only. The MKB/AKS APIs and encrypted storage remain native.
        // Every query needs a fresh root-owned lease; it expires when vphoned
        // stops or notices any persistent/unknown keybag directory entry.
        dlopen("/System/Library/PrivateFrameworks/ManagedConfiguration.framework/ManagedConfiguration", RTLD_NOW);
        Class bag = objc_getClass("SBFMobileKeyBag");
        Method passcode = class_getInstanceMethod(bag, sel_registerName("hasPasscodeSet"));
        Class state = objc_getClass("SBFMobileKeyBagState");
        Method locked = class_getInstanceMethod(state, sel_registerName("isEffectivelyLocked"));
        Class managed = objc_getClass("MCPasscodeManager");
        Method mcPasscode = class_getInstanceMethod(managed, sel_registerName("isPasscodeSet"));
        if (passcode && locked && mcPasscode &&
            !strcmp(method_getTypeEncoding(passcode), "B16@0:8") &&
            !strcmp(method_getTypeEncoding(locked), "B16@0:8") &&
            !strcmp(method_getTypeEncoding(mcPasscode), "B16@0:8")) {
            originalHasPasscode = (void *)method_getImplementation(passcode);
            class_replaceMethod(bag, sel_registerName("hasPasscodeSet"), (IMP)labHasPasscode, method_getTypeEncoding(passcode));
            originalEffectivelyLocked = (void *)method_getImplementation(locked);
            class_replaceMethod(state, sel_registerName("isEffectivelyLocked"), (IMP)labEffectivelyLocked, method_getTypeEncoding(locked));
            originalMCPasscode = (void *)method_getImplementation(mcPasscode);
            class_replaceMethod(managed, sel_registerName("isPasscodeSet"), (IMP)labMCPasscode, method_getTypeEncoding(mcPasscode));
        }
    }
    if (access("/usr/lib/vphone-ios16-touchscreen", F_OK) == 0) {
        // The newer brightness backend does not publish the old HID backlight
        // factor. Even a visibly rendered Lock Screen is consequently rejected
        // as "backlight dim/off". Mirror each native requested state through
        // the legacy system-app API, including dim/off; do not force it awake.
        void *backboard = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
        setLegacyBacklight = backboard ? dlsym(backboard, "BKSHIDServicesSetBacklightFactorWithFadeDuration") : NULL;
        Class backlight = objc_getClass("SBBacklightController");
        SEL transition = sel_registerName("setBacklightState:source:animated:completion:");
        Method setter = class_getInstanceMethod(backlight, transition);
        Method factor = class_getInstanceMethod(backlight, sel_registerName("_factorToPublishForBacklightState:"));
        if (setLegacyBacklight && setter && factor &&
            !strcmp(method_getTypeEncoding(setter), "v44@0:8q16q24B32@?36") &&
            !strcmp(method_getTypeEncoding(factor), "f24@0:8q16")) {
            originalBacklight = (void *)method_getImplementation(setter);
            class_replaceMethod(backlight, transition, (IMP)backlightWithLegacyHIDState, method_getTypeEncoding(setter));
        }
    }
    Class setup = objc_getClass("SBSetupManager");
    SEL update = sel_registerName("updateInSetupMode");
    Method updater = class_getInstanceMethod(setup, update);
    Method reason = class_getInstanceMethod(setup, sel_registerName("_setSetupRequiredReason:"));
    if (updater && reason && !strcmp(method_getTypeEncoding(updater), "B16@0:8") &&
        (!strcmp(method_getTypeEncoding(reason), "B24@0:8Q16") ||
         !strcmp(method_getTypeEncoding(reason), "B24@0:8q16"))) {
        class_replaceMethod(setup, update, (IMP)labSetupMode, method_getTypeEncoding(updater));
        NSLog(@"[ios16-desktop] kept setup mode off for the fresh lab");
    }
    Class media = objc_getClass("SBMediaController");
    Method mediaInit = class_getInstanceMethod(media, @selector(init));
    if (mediaInit && !strcmp(method_getTypeEncoding(mediaInit), "@16@0:8")) {
        // First unlock lazily creates both video and music routing contexts
        // here. Neither service exists in this desktop-only lab. Leave the
        // optional singleton nil rather than manufacturing a partial object.
        class_replaceMethod(media, @selector(init), (IMP)unavailableController, method_getTypeEncoding(mediaInit));
        NSLog(@"[ios16-desktop] skipped unavailable media controller");
    }
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
