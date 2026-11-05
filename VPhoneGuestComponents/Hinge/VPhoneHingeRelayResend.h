#pragma once
#import <Foundation/Foundation.h>
#include <objc/runtime.h>

// MARK: - The relay's resend, in locationd
//
// iOS 27.2's device-state relay skips a slider value equal to the angle it
// last produced: `-[CMDeviceStateRelayManager _feedAngleUpdate:]` compares it
// with `effectiveAngle` and logs "Already at angle; skipping interpolation".
// On a VM, CoreMotion's angle notifier has no hinge device to copy an angle
// from (it skips the physical one), so a CMAngleManager started while the
// hinge rests (WebDriverAgent's GET /wda/device/hingeAngle starts one per
// request) waits for an event that never comes. 27.1's relay sent every
// value on, so the hinge's resend reached such a client within
// VP_HINGE_REPUSH_SECONDS. In locationd the hinge restores that: a value
// equal to the relay's angle goes to its interpolator with no duration, as
// the relay's own start snaps to its first angle, which produces one event
// at that angle. Any other value takes the relay's own path.

@protocol VPhoneHingeRelay
- (void)_feedAngleUpdate:(NSNumber *)angle;
- (NSNumber *)effectiveAngle;
- (id)interpolator;
@end

@protocol VPhoneHingeInterpolator
- (void)interpolateToAngle:(float)angle duration:(double)duration;
@end

static IMP VPhoneHingeRelayFeed;

static void VPhoneHingeRelayFeedResending(id<VPhoneHingeRelay> relay, SEL selector, NSNumber *angle) {
    if ([angle isKindOfClass:NSNumber.class] && [angle isEqual:relay.effectiveAngle]) {
        [(id<VPhoneHingeInterpolator>)relay.interpolator interpolateToAngle:angle.floatValue duration:0];
        return;
    }
    ((void (*)(id, SEL, NSNumber *))VPhoneHingeRelayFeed)(relay, selector, angle);
}

/// Whether `relay` is 27.2's relay, with its interpolator, and now resends an
/// unchanged angle. Any other class is left as it is.
static BOOL VPhoneHingeInstallRelayResend(Class relay, Class interpolator) {
    Method feed = relay ? class_getInstanceMethod(relay, @selector(_feedAngleUpdate:)) : NULL;
    if (!feed || VPhoneHingeRelayFeed || ![relay instancesRespondToSelector:@selector(effectiveAngle)] ||
        ![relay instancesRespondToSelector:@selector(interpolator)] ||
        ![interpolator instancesRespondToSelector:@selector(interpolateToAngle:duration:)])
        return NO;
    VPhoneHingeRelayFeed = method_setImplementation(feed, (IMP)VPhoneHingeRelayFeedResending);
    return YES;
}
