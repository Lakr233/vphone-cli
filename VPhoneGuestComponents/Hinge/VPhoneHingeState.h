#pragma once
#import <Foundation/Foundation.h>
#include <math.h>

// One dictionary per update, as with the gyroscope: readers never combine an
// angle with a pose from a different request.
#define VP_HINGE_DOMAIN "com.apple.backboardd"
#define VP_HINGE_CONFIGURATION "VPhoneHingeAngle"
#define VP_HINGE_STATUS "VPhoneHingeStatus"
// The newest sample, written beside every HID dispatch (angle,
// mechanical_angle, velocity, state, event_phase, timestamp) so readers that
// cannot subscribe to the HID service still see the hinge move. Written
// without a disk sync: one entry per 10 ms sweep tick must not become one
// plist flush per tick; cfprefsd carries it and readers sync their own view.
#define VP_HINGE_LATEST "VPhoneHingeLatest"
#define VP_HINGE_NOTIFICATION "com.vphone.motion.hinge.changed"

// The foldable's hinge, degrees: 0 closed, 180 open flat. Apple's own
// positions (suiatool, shipped in SpringBoardFoundation's help text and the
// Duo simulator) are closed = 0, book = ~100, open = 180, and a change of
// state is a sweep from the current angle to the target, not a jump.
#define VP_HINGE_BOOK_ANGLE 100.0
#define VP_HINGE_SWEEP_MS 10.03
#define VP_HINGE_OPEN_DEFAULT_MS 600.0
#define VP_HINGE_CLOSE_DEFAULT_MS 800.0
#define VP_HINGE_REPUSH_SECONDS 5

typedef struct {
    BOOL enabled;
    BOOL sweep;
    double angle;
    double durationMs; // < 0: the per-direction default; 0: instant
    int32_t profile;   // 0 continuous, 1 fade
    // CoreMotion's device orientation, 1 portrait … 6 face down; 0 leaves
    // the orientation the relay holds.
    int32_t orientation;
    // Stored without a host-control event: the relay already has the angle
    // (DeviceHub sends it there itself), and the hinge only keeps it for its
    // periodic resend.
    BOOL quiet;
} VPhoneHingeState;

typedef enum {
    VPhoneHingeProfileContinuous = 0,
    VPhoneHingeProfileFade = 1,
} VPhoneHingeProfile;

// Reject malformed persisted state, booleans masquerading as angles, and
// angles outside the hinge's range.
static inline BOOL VPhoneHingeNumber(id value) {
    return [value isKindOfClass:NSNumber.class] &&
           CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID();
}

static inline BOOL VPhoneHingeDecode(id value, VPhoneHingeState *state) {
    *state = (VPhoneHingeState){0};
    if (![value isKindOfClass:NSDictionary.class])
        return NO;
    id enabled = value[@"enabled"];
    if (![enabled isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)enabled) != CFBooleanGetTypeID())
        return NO;
    id angle = value[@"angle"];
    if (!VPhoneHingeNumber(angle))
        return NO;
    double degrees = [angle doubleValue];
    if (!isfinite(degrees) || degrees < 0 || degrees > 180)
        return NO;
    double duration = -1;
    if (value[@"duration_ms"] != nil) {
        if (!VPhoneHingeNumber(value[@"duration_ms"]))
            return NO;
        duration = [value[@"duration_ms"] doubleValue];
        // -1 names the per-direction default; 0 is the instant swap.
        if (!isfinite(duration) || duration < -1 || duration > 10000)
            return NO;
    }
    int32_t profile = VPhoneHingeProfileContinuous;
    if (value[@"profile"] != nil) {
        if (!VPhoneHingeNumber(value[@"profile"]))
            return NO;
        profile = [value[@"profile"] intValue];
        if (profile != VPhoneHingeProfileContinuous && profile != VPhoneHingeProfileFade)
            return NO;
    }
    BOOL sweep = NO;
    if (value[@"sweep"] != nil) {
        id sweepValue = value[@"sweep"];
        if (![sweepValue isKindOfClass:NSNumber.class] ||
            CFGetTypeID((__bridge CFTypeRef)sweepValue) != CFBooleanGetTypeID())
            return NO;
        sweep = [sweepValue boolValue];
    }
    int32_t orientation = 0;
    if (value[@"orientation"] != nil) {
        if (!VPhoneHingeNumber(value[@"orientation"]))
            return NO;
        orientation = [value[@"orientation"] intValue];
        if (orientation < 0 || orientation > 6 || orientation != [value[@"orientation"] doubleValue])
            return NO;
    }
    id quietValue = value[@"quiet"];
    if (quietValue != nil && (![quietValue isKindOfClass:NSNumber.class] ||
                              CFGetTypeID((__bridge CFTypeRef)quietValue) != CFBooleanGetTypeID()))
        return NO;
    *state = (VPhoneHingeState){
        [enabled boolValue], sweep, degrees, duration, profile, orientation, [quietValue boolValue],
    };
    return YES;
}

static inline NSDictionary *VPhoneHingeEncode(VPhoneHingeState state) {
    NSMutableDictionary *encoded = [@{
        @"enabled": @(state.enabled),
        @"sweep": @(state.sweep),
        @"angle": @(state.angle),
        @"duration_ms": @(state.durationMs),
        @"profile": @(state.profile),
    } mutableCopy];
    if (state.orientation)
        encoded[@"orientation"] = @(state.orientation);
    if (state.quiet)
        encoded[@"quiet"] = @YES;
    return encoded;
}

// HID report interval, microseconds. Zero means there are no subscribers.
static inline uint64_t VPhoneHingeInterval(id value) {
    if (!VPhoneHingeNumber(value))
        return 0;
    double interval = [value doubleValue];
    if (!isfinite(interval) || interval <= 0)
        return 0;
    return (uint64_t)fmin(1000000, fmax(5000, interval));
}
