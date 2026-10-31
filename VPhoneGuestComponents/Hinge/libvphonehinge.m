#import "VPhoneHingeHID.h"
#import "VPhoneHingeState.h"
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <notify.h>
#include <objc/message.h>
#include <unistd.h>

// MARK: - HID provider in backboardd

@interface VPhoneHingeProvider : NSObject
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, strong) dispatch_source_t sweepTimer;
@property (nonatomic, strong) dispatch_source_t heartbeat;
@property (nonatomic, strong) id<VPhoneHingeHIDService> service;
@property (nonatomic) VPhoneHingeVendorEventFactory factory;
@property (nonatomic) VPhoneHingeSerializer serialize;
@property (nonatomic, strong) NSMutableDictionary *properties;
@property (nonatomic) VPhoneHingeState state;
@property (nonatomic) double currentAngle;
// The orientation the relay was last given; 0 before any.
@property (nonatomic) int32_t orientation;
// The sweep in flight: from currentAngle to state.angle over its duration.
@property (nonatomic) double sweepElapsed;
@property (nonatomic) double sweepDuration;
@property (nonatomic) double sweepStart;
@property (nonatomic) BOOL enumerated;
@property (nonatomic) BOOL cancelling;
@property (nonatomic) uint64_t interval;
@property (nonatomic) uint64_t dispatched;
@property (nonatomic) uint64_t failures;
@property (nonatomic) uint64_t sweeps;
@property (nonatomic) int notificationToken;
@property (nonatomic, copy) NSString *lastError;
- (void)start;
- (void)dispatchSample;
- (void)dispatchAngle:(double)angle velocity:(double)velocity state:(int32_t)state phase:(int32_t)phase;
@end

@implementation VPhoneHingeProvider

- (void)publishStatus {
    NSDictionary *status = @{
        @"enumerated": @(self.enumerated), @"service_id": @(self.service.serviceID),
        @"pid": @(getpid()), @"updated_at": @([NSDate date].timeIntervalSince1970),
        @"report_interval_us": @(self.interval), @"dispatched": @(self.dispatched),
        @"dispatch_failures": @(self.failures), @"sweeps": @(self.sweeps),
        @"sweeping": @(self.sweepTimer != nil), @"current_angle": @(self.currentAngle),
        @"error": self.lastError ?: @"",
        @"configuration": VPhoneHingeEncode(self.state),
    };
    CFPreferencesSetValue(CFSTR(VP_HINGE_STATUS), (__bridge CFDictionaryRef)status,
                          CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
}

- (void)readConfiguration {
    CFPreferencesSynchronize(CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
    id value = CFBridgingRelease(CFPreferencesCopyValue(CFSTR(VP_HINGE_CONFIGURATION),
                                  CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost));
    VPhoneHingeState state;
    if (VPhoneHingeDecode(value, &state)) {
        self.state = state;
        self.lastError = nil;
        if (state.enabled && state.sweep) {
            [self beginSweep];
        } else {
            [self endSweepTimer];
            if (state.enabled)
                self.currentAngle = state.angle;
            // The stand-in's sample exists from the first request, before the
            // HID service enumerates and on the rare tick it is down.
            [self publishLatestAngle:self.currentAngle velocity:0
                               state:VPhoneHingeStateForAngle(self.currentAngle) phase:0];
            if (self.enumerated && !state.quiet)
                [self dispatchSample];
        }
        if (state.orientation && state.orientation != self.orientation) {
            self.orientation = state.orientation;
            if (self.enumerated)
                [self dispatchOrientation];
        }
    } else {
        self.lastError = @"Stored hinge angle is malformed; keeping the last one";
    }
    [self publishStatus];
}

- (void)updateTimer {
    // locationd's relay keeps the last value it was sent and never asks for
    // one; when locationd restarts it reseeds 0° and portrait. Stationary
    // values are therefore sent again every few seconds.
    uint64_t period = self.enumerated ? VP_HINGE_REPUSH_SECONDS * NSEC_PER_SEC : DISPATCH_TIME_FOREVER;
    dispatch_source_set_timer(self.timer, period == DISPATCH_TIME_FOREVER ? DISPATCH_TIME_FOREVER : DISPATCH_TIME_NOW,
                              period, NSEC_PER_MSEC);
    // The status is republished every two seconds only while samples flow, as
    // with the accelerometer: cfprefsd need not carry a rewrite for the
    // guest's whole life, and vphoned judges the provider by its pid.
    if (self.heartbeat) {
        BOOL flowing = period != DISPATCH_TIME_FOREVER;
        dispatch_source_set_timer(self.heartbeat,
                                  flowing ? dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC) : DISPATCH_TIME_FOREVER,
                                  2 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    }
}

// MARK: - Apple's sweep model
//
// A foldable's screen state is not a jump: suiatool (whose help text ships in
// SpringBoardFoundation) and the Duo simulator's SBFHingeSamplePlayback both
// move the hinge from its current angle to a target over a profiled sweep on
// CoreMotion's 10.03 ms grid, reporting angle, velocity and hinge state on
// every sample. Opening is faster than closing; duration 0 is an instant
// swap. These methods reproduce that model with a synthetic ease, so no
// Apple-recorded sample data is shipped.

/// The hinge state (CoreMotion's 0–4 magic-pose hinge values) an angle in
/// motion or at rest reports.
static int32_t VPhoneHingeStateForAngle(double angle) {
    if (angle < 5.0)
        return 1; // closed
    if (angle >= 170.0)
        return 3; // open flat
    return 2; // partially open, the state a sweep holds throughout
}

/// Continuous fold: a smoothstep, close to a hand fold's constant feel.
/// Fade: a cosine ease with a dwell at each end, the crossfade feel the
/// fade-in-out profile names.
static double VPhoneHingeProgress(double t, int32_t profile) {
    if (profile == VPhoneHingeProfileFade) {
        if (t < 0.1)
            return 0;
        if (t > 0.9)
            return 1;
        return (1 - cos(M_PI * (t - 0.1) / 0.8)) / 2;
    }
    return t * t * (3 - 2 * t);
}

- (void)endSweepTimer {
    if (self.sweepTimer) {
        dispatch_source_cancel(self.sweepTimer);
        self.sweepTimer = nil;
    }
}

- (void)beginSweep {
    [self endSweepTimer];
    double target = self.state.angle;
    double duration = self.state.durationMs;
    if (duration < 0)
        duration = target > self.currentAngle ? VP_HINGE_OPEN_DEFAULT_MS : VP_HINGE_CLOSE_DEFAULT_MS;
    // An instant swap (the "yoinking path") and a no-op target are one sample.
    if (duration < VP_HINGE_SWEEP_MS || fabs(target - self.currentAngle) < 0.5) {
        double previous = self.currentAngle;
        self.currentAngle = target;
        self.sweeps++;
        [self dispatchAngle:target
                  velocity:duration > 0 ? (target - previous) / (duration / 1000.0) : 0
                     state:VPhoneHingeStateForAngle(target)
                      phase:3];
        [self publishStatus];
        return;
    }
    self.sweepStart = self.currentAngle;
    self.sweepElapsed = 0;
    self.sweepDuration = duration;
    self.sweeps++;
    self.sweepTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    dispatch_source_set_timer(self.sweepTimer, DISPATCH_TIME_NOW,
                              (uint64_t)(VP_HINGE_SWEEP_MS * NSEC_PER_MSEC), (uint64_t)(1 * NSEC_PER_MSEC));
    __weak VPhoneHingeProvider *weakSelf = self;
    dispatch_source_set_event_handler(self.sweepTimer, ^{
        @autoreleasepool {
            VPhoneHingeProvider *provider = weakSelf;
            if (!provider)
                return;
            provider.sweepElapsed += VP_HINGE_SWEEP_MS;
            double t = provider.sweepElapsed / provider.sweepDuration;
            if (t >= 1.0) {
                double previous = provider.currentAngle;
                provider.currentAngle = provider.state.angle;
                [provider endSweepTimer];
                [provider dispatchAngle:provider.currentAngle
                             velocity:(provider.currentAngle - previous) / (VP_HINGE_SWEEP_MS / 1000.0)
                                state:VPhoneHingeStateForAngle(provider.currentAngle)
                                 phase:3];
                [provider publishStatus];
                return;
            }
            double progress = VPhoneHingeProgress(t, provider.state.profile);
            double angle = provider.sweepStart + (provider.state.angle - provider.sweepStart) * progress;
            double previousAngle = provider.currentAngle;
            provider.currentAngle = angle;
            [provider dispatchAngle:angle
                         velocity:(angle - previousAngle) / (VP_HINGE_SWEEP_MS / 1000.0)
                            state:VPhoneHingeStateForAngle(angle)
                             phase:provider.sweepElapsed == VP_HINGE_SWEEP_MS ? 1 : 2];
        }
    });
    dispatch_resume(self.sweepTimer);
}

- (void)publishLatestAngle:(double)angle velocity:(double)velocity state:(int32_t)state phase:(int32_t)phase {
    // The same sample for the CoreMotion stand-in in dtdeviceinfod, which
    // reads this instead of driving CoreMotion's own machinery. Phase 0 is a
    // stationary report, 1 the first tick of a sweep, 2 the ticks between,
    // 3 the last.
    NSDictionary *latest = @{
        @"angle": @(angle),
        @"mechanical_angle": @(angle),
        @"velocity": @(velocity),
        @"state": @(state),
        @"event_phase": @(phase),
        @"timestamp": @([NSDate date].timeIntervalSince1970),
    };
    CFPreferencesSetValue(CFSTR(VP_HINGE_LATEST), (__bridge CFDictionaryRef)latest,
                          CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
}

/// One host-control dictionary as a vendor-defined event on the service.
- (BOOL)dispatchControl:(NSDictionary *)control {
    NSData *data = CFBridgingRelease(self.serialize((__bridge CFTypeRef)control, 0));
    if (!data.length || data.length > VP_HOST_CONTROLS_MAX_DATA) {
        self.failures++;
        self.lastError = @"Host-control dictionary did not serialize within 256 bytes";
        return NO;
    }
    id event = CFBridgingRelease(self.factory(NULL, mach_absolute_time(), VP_HOST_CONTROLS_USAGE_PAGE,
                                              VP_HOST_CONTROLS_USAGE, 0, data.bytes, (long)data.length, 0));
    if (event && [self.service dispatchEvent:event]) {
        self.dispatched++;
        self.lastError = nil;
        return YES;
    }
    self.failures++;
    self.lastError = @"HID event dispatch failed";
    return NO;
}

- (void)dispatchAngle:(double)angle velocity:(double)velocity state:(int32_t)state phase:(int32_t)phase {
    // The relay reads the slider's value as whole degrees and derives the
    // velocity, hinge state and event phase CoreMotion reports itself.
    [self dispatchControl:@{@"source": @"hinge-slider-control", @"type": @"range", @"value": @((long)lround(angle))}];
    [self publishLatestAngle:angle velocity:velocity state:state phase:phase];
}

- (void)dispatchOrientation {
    // The picker has no upside-down entry; that orientation stays with the
    // test-automation pose.
    NSDictionary *names = @{@1: @"portrait", @3: @"landscape-left", @4: @"landscape-right",
                            @5: @"faceup", @6: @"facedown"};
    NSString *name = names[@(self.orientation)];
    if (name)
        [self dispatchControl:@{@"source": @"orientation-picker-control", @"type": @"enum", @"value": name}];
}

- (void)createService {
    self.enumerated = NO;
    self.cancelling = NO;
    self.interval = 0;
    self.properties[@"ReportInterval"] = @0;
    self.service = (id<VPhoneHingeHIDService>)[NSClassFromString(@"HIDVirtualEventService") new];
    if (!self.service) {
        self.lastError = @"HIDVirtualEventService creation failed";
        [self publishStatus];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), self.queue, ^{ [self createService]; });
        return;
    }
    self.service.delegate = self;
    [self.service setDispatchQueue:self.queue];
    __weak VPhoneHingeProvider *weakSelf = self;
    [self.service setCancelHandler:^{
        VPhoneHingeProvider *provider = weakSelf;
        if (!provider)
            return;
        provider.service = nil;
        // A reset invalidates the old service. Cancel completely before
        // releasing it, then register a new one with the restarted HID server.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), provider.queue,
                       ^{ [provider createService]; });
    }];
    [self.service activate];
}

- (void)dispatchSample {
    // A stationary report: the angle the last sweep or request left, no
    // motion, phase 0. Same path as a sweep tick so the latest sample the
    // CoreMotion stand-in reads is written here too.
    [self dispatchAngle:self.currentAngle
                velocity:0
                  state:VPhoneHingeStateForAngle(self.currentAngle)
                   phase:0];
}

- (void)start {
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL);
    self.factory = (VPhoneHingeVendorEventFactory)dlsym(iokit, "IOHIDEventCreateVendorDefinedEvent");
    self.serialize = (VPhoneHingeSerializer)dlsym(iokit, "IOCFSerialize");
    dlopen("/System/Library/PrivateFrameworks/HID.framework/HID", RTLD_NOW | RTLD_LOCAL);
    Class serviceClass = NSClassFromString(@"HIDVirtualEventService");
    if (!iokit || !self.factory || !self.serialize || !serviceClass ||
        ![serviceClass instancesRespondToSelector:@selector(dispatchEvent:)]) {
        self.lastError = @"Required HID virtual-service API unavailable";
        NSLog(@"[vphone-hinge] %@", self.lastError);
        [self publishStatus];
        return;
    }
    // locationd's device-state relay subscribes to the host controls by
    // primary usage alone. It runs only when CoreMotion selects a foldable's
    // capabilities from the product-id — the foldable product identity
    // patch — so on any other guest the service sits unread.
    self.properties = [@{
        @"PrimaryUsagePage": @VP_HOST_CONTROLS_USAGE_PAGE, @"PrimaryUsage": @VP_HOST_CONTROLS_USAGE,
        @"DeviceUsagePairs": @[@{@"DeviceUsagePage": @VP_HOST_CONTROLS_USAGE_PAGE,
                                 @"DeviceUsage": @VP_HOST_CONTROLS_USAGE}],
        @"Product": @"VPhone Host Controls", @"Manufacturer": @"vphone",
        @"Transport": @"Virtual", @"Built-In": @YES,
        @"ReportInterval": @0, @"BatchInterval": @0,
    } mutableCopy];
    [self readConfiguration];
    int status = notify_register_dispatch(VP_HINGE_NOTIFICATION, &_notificationToken, self.queue,
                                          ^(int token) { [self readConfiguration]; });
    if (status != NOTIFY_STATUS_OK) {
        self.lastError = @"Hinge configuration notification registration failed";
        [self publishStatus];
        return;
    }
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    dispatch_source_set_event_handler(self.timer, ^{
        @autoreleasepool {
            [self dispatchSample];
        }
    });
    self.heartbeat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    dispatch_source_set_event_handler(self.heartbeat, ^{ [self publishStatus]; });
    [self updateTimer];
    dispatch_resume(self.timer);
    dispatch_resume(self.heartbeat);
    [self createService];
}

// MARK: - HIDVirtualEventServiceDelegate selectors

- (id)propertyForKey:(NSString *)key forService:(id)service {
    return self.properties[key];
}

- (BOOL)setProperty:(id)value forKey:(NSString *)key forService:(id)service {
    if (service != self.service)
        return NO;
    if ([key isEqualToString:@"ReportInterval"]) {
        self.interval = VPhoneHingeInterval(value);
        self.properties[key] = @(self.interval);
        [self publishStatus];
        return YES;
    }
    if ([key isEqualToString:@"BatchInterval"])
        return YES; // No FIFO: samples are delivered as they are made.
    return NO;
}

- (id)copyEventMatching:(NSDictionary *)matching forService:(id)service {
    return nil; // The relay only consumes events as they are dispatched.
}

- (BOOL)setOutputEvent:(id)event forService:(id)service {
    return NO;
}

- (void)notification:(NSInteger)type withProperty:(NSDictionary *)property forService:(id)service {
    if (service != self.service)
        return;
    if (type == 10) { // HIDVirtualServiceNotificationTypeEnumerated
        self.enumerated = YES;
        self.lastError = nil;
        NSLog(@"[vphone-hinge] HID service enumerated: %llu", self.service.serviceID);
        [self dispatchSample];
        [self dispatchOrientation];
    } else if (type == 11 && !self.cancelling) { // Terminated or reset
        self.enumerated = NO;
        self.cancelling = YES;
        self.lastError = @"HID service terminated; waiting to register again";
        [self.service cancel];
    }
    [self updateTimer];
    [self publishStatus];
}
@end

__attribute__((constructor)) static void VPhoneHingeStart(void) {
    // Only backboardd creates the HID service. Starting asynchronously avoids
    // calling the HID server while its daemon is still running image
    // constructors.
    if (strcmp(getprogname(), "backboardd") != 0)
        return;
    static VPhoneHingeProvider *provider;
    provider = [VPhoneHingeProvider new];
    provider.queue = dispatch_queue_create("com.vphone.motion.hinge", DISPATCH_QUEUE_SERIAL);
    dispatch_async(provider.queue, ^{ [provider start]; });
}
