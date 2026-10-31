/*
 * vphoned_pose — set a foldable guest's device pose, and the virtual hinge
 * angle behind it.
 *
 * A VM has no hinge, and SpringBoard only consumes CoreMotion's hinge angle
 * and magic pose on a board CoreMotion recognizes with two always-connected
 * displays. SpringBoardServices' test-automation client sets the pose
 * directly: SpringBoard builds a synthetic magic pose from the device
 * orientation, hinge state and tabletop pose, and derives the hinge angle
 * from the hinge state. The server checks the client for
 * com.apple.springboard.testautomation, which vphoned carries.
 *
 * A fold to a position goes through SpringBoardServices' display tool
 * client instead, the service behind Apple's suiatool swap: SpringBoard
 * sweeps its pose itself and swaps displays on the way, as on hardware. The
 * server checks for com.apple.springboard.sbdisplay.service.
 *
 * The classes are resolved at run time, so a base without them reports
 * false (or -1).
 */

#import "Include/VphonedNative.h"
#import "../../VPhoneGuestComponents/Hinge/VPhoneHingeState.h"

#include <dlfcn.h>
#include <errno.h>
#include <math.h>
#include <notify.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <signal.h>
#include <unistd.h>

/// The override `-[SBSTestAutomationService setDevicePoseOverride:]` takes, as
/// SpringBoard's handler reads it: a 64-bit orientation, then the device
/// orientation, hinge state and tabletop pose as 32-bit values.
typedef struct {
    int64_t orientation;
    int32_t deviceOrientation;
    int32_t hingeState;
    int32_t tabletopPose;
} VPDevicePoseOverride;

bool vp_device_pose_set(int deviceOrientation, int hingeState, int tabletopPose) {
    static Class service;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
        service = NSClassFromString(@"SBSTestAutomationService");
    });
    SEL selector = NSSelectorFromString(@"setDevicePoseOverride:");
    if (!service || ![service instancesRespondToSelector:selector]) return false;
    id client = [service new];
    VPDevicePoseOverride pose = {deviceOrientation, deviceOrientation, hingeState, tabletopPose};
    ((void (*)(id, SEL, VPDevicePoseOverride))objc_msgSend)(client, selector, pose);
    return true;
}

/// The settings `-[SBSDisplayToolService swapDisplayWithSettings:completion:]`
/// takes (iOS 27.1), the swap Apple's Duo tooling runs. The client sends the
/// duration (seconds, < 0 the per-direction default, 0 an instant swap),
/// device orientation (0 the current one), profile override (0 none, 1 fade,
/// 2 continuous), whether to reply only once the swap has finished, the
/// target mode (1 an absolute hinge position) and that position (0 closed, 1
/// open flat); the first and last fields stay on the client.
typedef struct {
    int64_t state;
    double duration;
    int64_t deviceOrientation;
    int64_t profileOverride;
    bool waitForCompletion;
    int64_t targetMode;
    double targetHingePosition;
    double reserved;
} VPDisplaySwapSettings;

int vp_display_swap(double position, double durationSeconds, int deviceOrientation, int profileOverride,
                    double timeoutSeconds) {
    static Class service;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
        service = NSClassFromString(@"SBSDisplayToolService");
    });
    SEL selector = NSSelectorFromString(@"swapDisplayWithSettings:completion:");
    Method method = class_getInstanceMethod(service, selector);
    if (!method || strcmp(method_getTypeEncoding(method), "v88@0:8{?=qdqqBqdd}16@?80") != 0) return -1;
    // SpringBoard sweeps its own hinge pose to the position, with the display
    // swap, transition style and lock screen handling of a real fold, and
    // ignores the hinge for 10 s so the sweep is not undone. The reply comes
    // on a BoardServices queue; its block arguments are not objects (reading
    // them as an NSError faults), so the block takes none.
    VPDisplaySwapSettings settings = {
        .duration = durationSeconds,
        .deviceOrientation = deviceOrientation,
        .profileOverride = profileOverride,
        .waitForCompletion = true,
        .targetMode = 1,
        .targetHingePosition = position,
    };
    dispatch_semaphore_t replied = dispatch_semaphore_create(0);
    id client = [service new];
    ((void (*)(id, SEL, VPDisplaySwapSettings, void (^)(void)))objc_msgSend)(client, selector, settings, ^{
        dispatch_semaphore_signal(replied);
    });
    long waited = dispatch_semaphore_wait(replied, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutSeconds * NSEC_PER_SEC)));
    ((void (*)(id, SEL))objc_msgSend)(client, NSSelectorFromString(@"invalidate"));
    return waited == 0 ? 1 : 0;
}

NSDictionary<NSString *, id> *vp_device_pose_get(void) {
    dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
    Class service = NSClassFromString(@"SBSTestAutomationService");
    SEL selector = NSSelectorFromString(@"getDevicePose");
    Method method = class_getInstanceMethod(service, selector);
    if (!method || strcmp(method_getTypeEncoding(method), "{?=qiii}16@0:8") != 0)
        return @{@"available": @NO, @"reason": @"device pose readback ABI unavailable"};
    // The client synchronously returns the 24-byte structure reconstructed
    // from SpringBoard's current pose snapshot. The completion selector is
    // on the server protocol, not this client class.
    id client = [service new];
    VPDevicePoseOverride pose = ((VPDevicePoseOverride (*)(id, SEL))objc_msgSend)(client, selector);
    return @{@"available": @YES, @"orientation": @(pose.orientation),
        @"device_orientation": @(pose.deviceOrientation), @"hinge": @(pose.hingeState),
        @"tabletop": @(pose.tabletopPose)};
}

/* The virtual hinge publishes one coherent preference dictionary per update. */
NSDictionary *vp_hinge_get(void) {
    CFPreferencesSynchronize(CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
    id configuration = CFBridgingRelease(CFPreferencesCopyValue(CFSTR(VP_HINGE_CONFIGURATION),
        CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost));
    VPhoneHingeState state;
    BOOL valid = VPhoneHingeDecode(configuration, &state);
    id status = CFBridgingRelease(CFPreferencesCopyValue(CFSTR(VP_HINGE_STATUS),
        CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost));
    BOOL running = NO;
    if ([status isKindOfClass:NSDictionary.class] &&
        [status[@"pid"] isKindOfClass:NSNumber.class] &&
        [status[@"updated_at"] isKindOfClass:NSNumber.class] &&
        [status[@"enumerated"] isKindOfClass:NSNumber.class] &&
        [status[@"report_interval_us"] isKindOfClass:NSNumber.class]) {
        pid_t pid = [status[@"pid"] intValue];
        BOOL alive = pid > 1 && (kill(pid, 0) == 0 || errno == EPERM);
        double age = NSDate.date.timeIntervalSince1970 - [status[@"updated_at"] doubleValue];
        BOOL flowing = [status[@"report_interval_us"] unsignedLongLongValue] > 0;
        running = [status[@"enumerated"] boolValue] && alive && age >= 0 && (age < 10 || !flowing);
    } else {
        status = NSNull.null;
    }
    return @{@"angle": @(valid && state.enabled ? state.angle : 0.0),
             @"enabled": @(valid && state.enabled),
             @"provider_running": @(running), @"provider": status};
}

static bool vp_hinge_publish(NSDictionary *configuration, double expectedAngle) {
    CFPreferencesSetValue(CFSTR(VP_HINGE_CONFIGURATION), (__bridge CFDictionaryRef)configuration,
                          CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
    if (!CFPreferencesSynchronize(CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost))
        return false;
    if (notify_post(VP_HINGE_NOTIFICATION) != NOTIFY_STATUS_OK)
        return false;
    for (int attempt = 0; attempt < 15; attempt++) {
        usleep(20000);
        CFPreferencesSynchronize(CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
        id status = CFBridgingRelease(CFPreferencesCopyValue(CFSTR(VP_HINGE_STATUS),
            CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost));
        id reported = [status isKindOfClass:NSDictionary.class] ? status[@"configuration"] : nil;
        if ([reported isKindOfClass:NSDictionary.class] &&
            [reported[@"angle"] isKindOfClass:NSNumber.class] &&
            fabs([reported[@"angle"] doubleValue] - expectedAngle) < 0.5)
            break;
    }
    return true;
}

/// The orientation to store: the requested one, or the stored one for 0, so
/// a later angle-only request does not drop it.
static int vp_hinge_orientation(int requested) {
    if (requested)
        return requested;
    CFPreferencesSynchronize(CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
    id stored = CFBridgingRelease(CFPreferencesCopyValue(CFSTR(VP_HINGE_CONFIGURATION),
        CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost));
    VPhoneHingeState state;
    return VPhoneHingeDecode(stored, &state) ? state.orientation : 0;
}

bool vp_hinge_set(double angleDegrees, int orientation) {
    if (!isfinite(angleDegrees) || angleDegrees < 0 || angleDegrees > 180 || orientation < 0 || orientation > 6)
        return false;
    VPhoneHingeState state = {true, false, angleDegrees, 0, 0, vp_hinge_orientation(orientation)};
    return vp_hinge_publish(VPhoneHingeEncode(state), angleDegrees);
}

bool vp_hinge_note(double angleDegrees) {
    if (!isfinite(angleDegrees) || angleDegrees < 0 || angleDegrees > 180)
        return false;
    VPhoneHingeState state = {true, false, angleDegrees, 0, 0, vp_hinge_orientation(0), true};
    CFPreferencesSetValue(CFSTR(VP_HINGE_CONFIGURATION), (__bridge CFDictionaryRef)VPhoneHingeEncode(state),
                          CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
    return CFPreferencesSynchronize(CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost) &&
           notify_post(VP_HINGE_NOTIFICATION) == NOTIFY_STATUS_OK;
}

bool vp_hinge_sweep(double targetDegrees, double durationMs, int profile, int orientation) {
    if (!isfinite(targetDegrees) || targetDegrees < 0 || targetDegrees > 180 ||
        !isfinite(durationMs) || durationMs < -1 || durationMs > 10000 ||
        (profile != VPhoneHingeProfileContinuous && profile != VPhoneHingeProfileFade) ||
        orientation < 0 || orientation > 6)
        return false;
    VPhoneHingeState state = {true, true, targetDegrees, durationMs, profile, vp_hinge_orientation(orientation)};
    return vp_hinge_publish(VPhoneHingeEncode(state), targetDegrees);
}

bool vp_core_motion_hinge(void) {
    static bool available;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/CoreMotion.framework/CoreMotion", RTLD_NOW);
        SEL selector = sel_registerName("isAvailable");
        Class angle = NSClassFromString(@"CMAngleManager"), deviceState = NSClassFromString(@"CMDeviceStateManager");
        available = angle && deviceState && [angle respondsToSelector:selector] && [deviceState respondsToSelector:selector] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(angle, selector) && ((BOOL (*)(id, SEL))objc_msgSend)(deviceState, selector);
    });
    return available;
}
