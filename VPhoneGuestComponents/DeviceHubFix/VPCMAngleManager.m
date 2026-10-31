// VPCMAngleManager.m — the hinge-angle manager stand-in for dtdeviceinfod,
// and beside it the device state manager stand-in (see "The device state
// stand-in" below).
//
// CoreDevice's hinge-angle stream (DeviceHub) ends, on the device, in the
// DDI's dtdeviceinfod: CMAngleManager_Bridge resolves CoreMotion's
// CMAngleManager and forwards the stream to it. On a guest the manager's
// capability answer is NO — CoreMotion picks its motion capabilities from the
// device tree's product-id, and the foldable token cannot be written without
// crash-looping SpringBoard.
//
// Opening that one gate is not enough, and that was v4's crash: with
// +[CMAngleManager isAvailable] answering YES, the bridge started the REAL
// manager, whose MotionThread asserts when its own capability bits
// (product-id) contradict the answer (dtdeviceinfod SIGABRT,
// com.apple.CoreMotion.MotionThread, eight times over a DeviceHub connect).
//
// So the manager's whole ObjC surface is taken over here, and CoreMotion's
// machinery never runs: isAvailable follows the vphone hinge provider, the
// angle range is the virtual hinge's 0–180, and the update methods deliver
// samples read from the provider's newest published sample
// (VPhoneHingeLatest, com.apple.backboardd/mobile) — the same values the HID
// service reports — wrapped in an object exposing the fields the bridge maps
// into DeviceHingeAngleSnapshot (angleDegrees, mechanicalAngleDegrees,
// velocityDegreesPerSeconds, the validity flags, state, eventPhase and
// timestamp). The sample class subclasses CoreMotion's own CMAngleData when
// that class exists, so a typed cast in the bridge still succeeds. The
// bridge's queue argument is an NSOperationQueue (CMAngleData itself never
// registered, measured on iOS 27.1), and samples are delivered onto it with
// addOperationWithBlock:.

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// MARK: - Log (same file the rest of the dylib writes)

static void vpMotionLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    if (!line)
        return;
    int fd = open("/var/mobile/Library/Caches/vphone-devicehubfix.log",
                  O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0666);
    if (fd < 0)
        return;
    fchmod(fd, 0666);
    dprintf(fd, "pid=%d %s\n", getpid(), line.UTF8String);
    close(fd);
}

// MARK: - The provider's newest sample

static NSDictionary *vpLatestSample(void) {
    CFPreferencesSynchronize(CFSTR("com.apple.backboardd"), CFSTR("mobile"), kCFPreferencesAnyHost);
    CFPropertyListRef value = CFPreferencesCopyValue(CFSTR("VPhoneHingeLatest"),
                                                     CFSTR("com.apple.backboardd"),
                                                     CFSTR("mobile"), kCFPreferencesAnyHost);
    id sample = CFBridgingRelease(value);
    return [sample isKindOfClass:NSDictionary.class] ? sample : nil;
}

// The provider republishes its status through cfprefsd. Freshness is NOT part
// of the test: the status heartbeat only runs while samples flow, so with no
// HID subscriber the stamp goes stale though the provider is alive. The pid is
// backboardd's, a launchd-critical process the guest reboots without — but
// dtdeviceinfod (mobile) cannot signal backboardd (root), so kill answers
// EPERM for a LIVE process; that counts as alive. Anything else that fails
// (ESRCH) really is gone.
static BOOL vpProviderIsRunning(void) {
    CFPreferencesSynchronize(CFSTR("com.apple.backboardd"), CFSTR("mobile"), kCFPreferencesAnyHost);
    CFPropertyListRef status = CFPreferencesCopyValue(CFSTR("VPhoneHingeStatus"),
                                                      CFSTR("com.apple.backboardd"),
                                                      CFSTR("mobile"), kCFPreferencesAnyHost);
    CFDictionaryRef dict = status && CFGetTypeID(status) == CFDictionaryGetTypeID()
                               ? (CFDictionaryRef)status : NULL;
    const void *enumerated = dict ? CFDictionaryGetValue(dict, CFSTR("enumerated")) : NULL;
    const void *pid = dict ? CFDictionaryGetValue(dict, CFSTR("pid")) : NULL;
    BOOL running = NO;
    if (enumerated && CFGetTypeID(enumerated) == CFBooleanGetTypeID() &&
        CFBooleanGetValue(enumerated) &&
        pid && CFGetTypeID(pid) == CFNumberGetTypeID()) {
        int value = 0;
        CFNumberGetValue(pid, kCFNumberIntType, &value);
        if (value > 1) {
            if (kill(value, 0) == 0)
                running = YES;
            else
                running = errno == EPERM;
        }
        // One diagnosis per process, so a closed gate explains itself in the log.
        static int logged = 0;
        if (!running && !logged++) {
            int reason = errno;
            vpMotionLog(@"hinge manager: gate closed — pid=%d kill_errno=%d (ESRCH=3 dead, EPERM=1 alive-but-unsignalable)",
                        value, reason);
        }
    }
    if (status)
        CFRelease(status);
    return running;
}

// MARK: - The sample object

// The angles are floats, as dtdeviceinfod's CMAngle_Bridge declares them
// (Tf,R,N,V_angleDegrees): it reads s0, the low half of a double's d0, so a
// double getter handed it 0° for every whole angle. Open and closed hid that
// (their hinge states pin 180° and 0°); in book DeviceHub took the stream's
// 0°, drew the device nearly closed and focused the cover.
typedef struct {
    float angle;
    float mechanical;
    float velocity;
    double timestamp;
    BOOL angleValid;
    BOOL velocityValid;
    long state;
    long phase;
} VPAngleSampleFields;

static Class VPAngleDataClass;
static ptrdiff_t VPAngleDataOffset;

#define VP_SAMPLE_GETTER(name, field, types)                                              \
    class_addMethod(VPAngleDataClass, sel_registerName(name),                             \
                    imp_implementationWithBlock(^(id self) {                              \
                        return ((VPAngleSampleFields *)((char *)(__bridge void *)self + VPAngleDataOffset))->field; \
                    }), types)

static void vpRegisterAngleDataClass(void) {
    // Subclass CoreMotion's own data class when it exists, so a typed cast in
    // the bridge still succeeds; the getters are replaced either way.
    Class base = objc_getClass("CMAngleData");
    if (!base)
        base = [NSObject class];
    VPAngleDataClass = objc_allocateClassPair(base, "VPCMAngleData", 0);
    if (!VPAngleDataClass)
        return;
    if (!class_addIvar(VPAngleDataClass, "fields", sizeof(VPAngleSampleFields),
                       0, @encode(VPAngleSampleFields))) {
        VPAngleDataClass = NULL;
        return;
    }
    objc_registerClassPair(VPAngleDataClass);
    VPAngleDataOffset = ivar_getOffset(class_getInstanceVariable(VPAngleDataClass, "fields"));
    // The fields CMAngleManager_Bridge maps into DeviceHingeAngleSnapshot,
    // with both spellings of the two flags.
    VP_SAMPLE_GETTER("angleDegrees", angle, "f16@0:8");
    VP_SAMPLE_GETTER("mechanicalAngleDegrees", mechanical, "f16@0:8");
    VP_SAMPLE_GETTER("velocityDegreesPerSeconds", velocity, "f16@0:8");
    VP_SAMPLE_GETTER("timestamp", timestamp, "d16@0:8");
    VP_SAMPLE_GETTER("isAngleValid", angleValid, "B16@0:8");
    VP_SAMPLE_GETTER("angleValid", angleValid, "B16@0:8");
    VP_SAMPLE_GETTER("isVelocityValid", velocityValid, "B16@0:8");
    VP_SAMPLE_GETTER("velocityValid", velocityValid, "B16@0:8");
    VP_SAMPLE_GETTER("state", state, "q16@0:8");
    VP_SAMPLE_GETTER("eventPhase", phase, "q16@0:8");
}

static id vpAngleDataFromSample(NSDictionary *latest) {
    if (!VPAngleDataClass)
        return nil;
    id data = [VPAngleDataClass new];
    VPAngleSampleFields *fields = (VPAngleSampleFields *)((char *)(__bridge void *)data + VPAngleDataOffset);
    fields->angle = [latest[@"angle"] floatValue];
    fields->mechanical = [latest[@"mechanical_angle"] floatValue];
    fields->velocity = [latest[@"velocity"] floatValue];
    fields->timestamp = [latest[@"timestamp"] doubleValue];
    fields->angleValid = latest[@"angle"] != nil;
    fields->velocityValid = latest[@"velocity"] != nil;
    fields->state = [latest[@"state"] longValue];
    fields->phase = [latest[@"event_phase"] longValue];
    return data;
}

// MARK: - The update session

@interface VPAngleSession : NSObject
// CoreMotion's queue argument is an NSOperationQueue, like CMMotionManager's
// start...UpdatesToQueue: (that was v5's crash — dispatch_async on an
// NSOperationQueue made libdispatch vtable-dispatch through a non-dispatch
// object and die with EXC_ARM_PAC_FAIL). Held as id and dispatched by kind.
@property (nonatomic, strong) id deliveryQueue;
@property (nonatomic, copy) void (^handler)(id data);
@property (nonatomic) NSTimeInterval interval;
@property (nonatomic, strong) dispatch_source_t timer;
@end

@implementation VPAngleSession
- (void)dealloc {
    if (_timer)
        dispatch_source_cancel(_timer);
}
@end

static char vpSessionKey;

static dispatch_queue_t vpTimerQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.vphone.devicehubfix.angle", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static NSTimeInterval vpClampInterval(NSTimeInterval interval) {
    if (!isfinite(interval) || interval <= 0)
        return 0;
    return MIN(10.0, MAX(0.01, interval));
}

static void vpDeliver(VPAngleSession *session) {
    if (!session.handler)
        return;
    id data = vpAngleDataFromSample(vpLatestSample());
    if (!data)
        return;
    void (^handler)(id) = session.handler;
    id queue = session.deliveryQueue;
    if ([queue isKindOfClass:[NSOperationQueue class]])
        [(NSOperationQueue *)queue addOperationWithBlock:^{ handler(data); }];
    else if (queue)
        dispatch_async((dispatch_queue_t)queue, ^{ handler(data); });
    else
        handler(data);
}

static void vpArmTimer(VPAngleSession *session) {
    if (session.timer) {
        dispatch_source_cancel(session.timer);
        session.timer = nil;
    }
    if (!session.handler)
        return;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, vpTimerQueue());
    NSTimeInterval interval = session.interval > 0 ? session.interval : 0.1;
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW,
                              (uint64_t)(interval * NSEC_PER_SEC), (uint64_t)(10 * NSEC_PER_MSEC));
    // Weak, so the session dies with the manager and cancels the timer.
    __weak VPAngleSession *weakSession = session;
    dispatch_source_set_event_handler(timer, ^{
        @autoreleasepool {
            VPAngleSession *alive = weakSession;
            if (alive)
                vpDeliver(alive);
        }
    });
    dispatch_resume(timer);
    session.timer = timer;
}

static VPAngleSession *vpSession(id manager) {
    VPAngleSession *session = objc_getAssociatedObject(manager, &vpSessionKey);
    if (!session) {
        session = [VPAngleSession new];
        objc_setAssociatedObject(manager, &vpSessionKey, session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return session;
}

// MARK: - The swapped CMAngleManager surface

static IMP vpOriginalIsAvailableIMP;
__attribute__((used)) static IMP vpOriginalStartIMP;
__attribute__((used)) static IMP vpOriginalSetHandlerIMP;
__attribute__((used)) static IMP vpOriginalStopIMP;
__attribute__((used)) static IMP vpOriginalActiveIMP;
__attribute__((used)) static IMP vpOriginalGetIntervalIMP;
__attribute__((used)) static IMP vpOriginalSetIntervalIMP;

static BOOL vpSwizzledIsAvailable(id self, SEL selector) {
    if (vpProviderIsRunning())
        return YES;
    return ((BOOL (*)(id, SEL))vpOriginalIsAvailableIMP)(self, selector);
}

// Floats, as CoreMotion declares them (`+ (float)minAngleDegrees`): a
// double in d0 reads back as 0 from s0, the trap the sample fields hit.
static float vpSwizzledMinAngle(id self, SEL selector) { return 0.0f; }
static float vpSwizzledMaxAngle(id self, SEL selector) { return 180.0f; }

// -[CMAngleManager dealloc] stops CoreMotion's own manager, and
// -[CMAngleManagerInternal stopAngleUpdatesPrivate] asserts that the real
// hinge notifier is available (CMAngleManager.mm line 214). Under the
// stand-in that manager never started, so its stop is skipped: dtdeviceinfod
// aborted every time it let a manager go, as when DeviceHub reconnected, and
// DeviceHub lost the device state until it was restarted.
static void vpSkippedInternalStop(id self, SEL selector) {}

static void vpSwizzledStartUpdates(id self, SEL selector, id queue, id handler) {
    VPAngleSession *session = vpSession(self);
    session.deliveryQueue = queue;
    session.handler = [handler copy];
    vpArmTimer(session);
}

static void vpSwizzledSetHandler(id self, SEL selector, id handler, double interval) {
    VPAngleSession *session = vpSession(self);
    session.deliveryQueue = nil;
    session.interval = vpClampInterval(interval);
    session.handler = [handler copy];
    vpArmTimer(session);
}

static void vpSwizzledStopUpdates(id self, SEL selector) {
    VPAngleSession *session = objc_getAssociatedObject(self, &vpSessionKey);
    session.handler = nil;
    if (session.timer) {
        dispatch_source_cancel(session.timer);
        session.timer = nil;
    }
}

static BOOL vpSwizzledIsAngleActive(id self, SEL selector) {
    VPAngleSession *session = objc_getAssociatedObject(self, &vpSessionKey);
    return session.handler != nil && session.timer != nil;
}

static double vpSwizzledAngleUpdateInterval(id self, SEL selector) {
    VPAngleSession *session = objc_getAssociatedObject(self, &vpSessionKey);
    return session.interval > 0 ? session.interval : 0.1;
}

static void vpSwizzledSetAngleUpdateInterval(id self, SEL selector, double interval) {
    VPAngleSession *session = vpSession(self);
    session.interval = vpClampInterval(interval);
    if (session.handler)
        vpArmTimer(session);
}

// MARK: - The device state stand-in
//
// DeviceHub (Xcode 27.1's CoreDevicePop plugin) draws a foldable from its
// device pose: which panel is active, the hinge state, the orientation and
// the tabletop pose. Without it the model stays closed on the cover whatever
// the hinge angle says. The pose is CoreDevice's device motion state stream,
// which dtdeviceinfod's DeviceMotionStateManager answers from CoreMotion's
// CMDeviceStateManager (isAvailable, startUpdatesToQueue:withHandler:,
// stopUpdates), reading each CMDeviceStateEvent's propertyA, propertyB and
// propertyC. Those are SpringBoard's magic pose: A the device orientation, B
// the hinge state (1 closed, 2 partially open, 3 open flat, as
// +propertyAForConfigType:… partitions them), C the tabletop pose. A guest's
// CoreMotion reads them from a hardware HID device it skips on a VM, so the
// manager answers unavailable. Here it answers from the provider's newest
// sample instead, like the angle stand-in, with real CMDeviceStateEvents,
// delivered once at start and then on every change.

static IMP vpOriginalStateIsAvailableIMP;

typedef struct {
    long long orientation, hinge, tabletop;
} VPDeviceState;

static VPDeviceState vpDeviceStateFromSample(NSDictionary *latest) {
    long long hinge = [latest[@"state"] longLongValue];
    // vphoned publishes the device orientation beside the sample (portrait
    // until a rotation or DeviceHub's orientation picker sets one); the
    // domain was just synchronized by vpLatestSample.
    id published = CFBridgingRelease(CFPreferencesCopyValue(CFSTR("VPhoneDeviceOrientation"),
        CFSTR("com.apple.backboardd"), CFSTR("mobile"), kCFPreferencesAnyHost));
    long long orientation = [published isKindOfClass:NSNumber.class] ? [published longLongValue] : 1;
    // The provider's state follows SpringBoard's table; open (4) is open
    // flat to CoreMotion, which has no wider state.
    return (VPDeviceState){MIN(MAX(orientation, 1), 6), MIN(MAX(hinge, 0), 3), 0};
}

static id vpDeviceStateEvent(VPDeviceState state) {
    Class event = objc_getClass("CMDeviceStateEvent");
    SEL init = sel_registerName(
        "initWithDeviceStatePropertyAType:deviceStatePropertyBType:deviceStatePropertyCType:timestamp:continuousTimestamp:");
    if (![event instancesRespondToSelector:init])
        return nil;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    return ((id (*)(id, SEL, long long, long long, long long, double, double))objc_msgSend)(
        [event alloc], init, state.orientation, state.hinge, state.tabletop, now, now);
}

@interface VPDeviceStateSession : NSObject
@property (nonatomic, strong) id deliveryQueue;
@property (nonatomic, copy) void (^handler)(id event, NSError *error);
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic) VPDeviceState delivered;
@property (nonatomic) BOOL hasDelivered;
@end

@implementation VPDeviceStateSession
- (void)dealloc {
    if (_timer)
        dispatch_source_cancel(_timer);
}
@end

static char vpStateSessionKey;

static void vpDeliverDeviceState(VPDeviceStateSession *session) {
    NSDictionary *latest = vpLatestSample();
    if (!session.handler || !latest)
        return;
    VPDeviceState state = vpDeviceStateFromSample(latest);
    VPDeviceState last = session.delivered;
    if (session.hasDelivered && state.orientation == last.orientation && state.hinge == last.hinge &&
        state.tabletop == last.tabletop)
        return;
    id event = vpDeviceStateEvent(state);
    if (!event)
        return;
    session.delivered = state;
    session.hasDelivered = YES;
    vpMotionLog(@"device state: hinge %lld orientation %lld tabletop %lld", state.hinge, state.orientation,
                state.tabletop);
    void (^handler)(id, NSError *) = session.handler;
    id queue = session.deliveryQueue;
    if ([queue isKindOfClass:[NSOperationQueue class]])
        [(NSOperationQueue *)queue addOperationWithBlock:^{ handler(event, nil); }];
    else if (queue)
        dispatch_async((dispatch_queue_t)queue, ^{ handler(event, nil); });
    else
        handler(event, nil);
}

static BOOL vpSwizzledStateIsAvailable(id self, SEL selector) {
    if (vpProviderIsRunning())
        return YES;
    return ((BOOL (*)(id, SEL))vpOriginalStateIsAvailableIMP)(self, selector);
}

static void vpSwizzledStartStateUpdates(id self, SEL selector, id queue, id handler) {
    VPDeviceStateSession *session = objc_getAssociatedObject(self, &vpStateSessionKey);
    if (!session) {
        session = [VPDeviceStateSession new];
        objc_setAssociatedObject(self, &vpStateSessionKey, session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (session.timer)
        dispatch_source_cancel(session.timer);
    session.deliveryQueue = queue;
    session.handler = handler;
    session.hasDelivered = NO;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, vpTimerQueue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    __weak VPDeviceStateSession *weakSession = session;
    dispatch_source_set_event_handler(timer, ^{
        @autoreleasepool {
            VPDeviceStateSession *alive = weakSession;
            if (alive)
                vpDeliverDeviceState(alive);
        }
    });
    dispatch_resume(timer);
    session.timer = timer;
}

static void vpSwizzledStopStateUpdates(id self, SEL selector) {
    VPDeviceStateSession *session = objc_getAssociatedObject(self, &vpStateSessionKey);
    session.handler = nil;
    if (session.timer) {
        dispatch_source_cancel(session.timer);
        session.timer = nil;
    }
}

static void vpInstallDeviceStateManagerStandIn(void) {
    Class manager = objc_getClass("CMDeviceStateManager");
    Method available = class_getClassMethod(manager, sel_registerName("isAvailable"));
    Method start = class_getInstanceMethod(manager, sel_registerName("startUpdatesToQueue:withHandler:"));
    Method stop = class_getInstanceMethod(manager, sel_registerName("stopUpdates"));
    if (!available || !start || !stop || !vpDeviceStateEvent((VPDeviceState){1, 1, 0})) {
        vpMotionLog(@"device state: CMDeviceStateManager surface not found, CoreDevice deviceMotionState stays off");
        return;
    }
    // As for the angle manager: with the foldable's product-id locationd
    // relays the virtual hinge into the real one.
    if (((BOOL (*)(id, SEL))objc_msgSend)(manager, sel_registerName("isAvailable"))) {
        vpMotionLog(@"device state: CoreMotion's own CMDeviceStateManager is available, no stand-in");
        return;
    }
    vpOriginalStateIsAvailableIMP = method_setImplementation(available, (IMP)vpSwizzledStateIsAvailable);
    method_setImplementation(start, (IMP)vpSwizzledStartStateUpdates);
    method_setImplementation(stop, (IMP)vpSwizzledStopStateUpdates);
    vpMotionLog(@"device state: stand-in installed");
}

// MARK: - The inner display, as DeviceHub sees it
//
// DeviceHub draws a Duo's inner panel, and offers its pose controls, only for
// an integrated display in DisplayInfo, which dtdeviceinfod builds from
// CADisplay. The Duo's inner render display (libvphonefolddisplay) is a
// virtual display at point scale 1 to every process but backboardd and
// SpringBoard, where FoldDisplay presents it as the built-in 3x panel it
// stands for; here it is presented the same way. DeviceHub then streams it
// by display ID (libdevicehubfix.c answers that feature).
static IMP vpOriginalDisplayType, vpOriginalPointScale;

static BOOL vpIsInnerDisplay(id display) {
    return [[display valueForKey:@"name"] isEqual:@"VPhone Duo Inner"];
}

static long long vpInnerDisplayType(id self, SEL selector) {
    return vpIsInnerDisplay(self) ? 0 : ((long long (*)(id, SEL))vpOriginalDisplayType)(self, selector);
}

static unsigned long vpInnerPointScale(id self, SEL selector) {
    return vpIsInnerDisplay(self) ? 3 : ((unsigned long (*)(id, SEL))vpOriginalPointScale)(self, selector);
}

static void vpInstallInnerDisplayPresentation(void) {
    dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY | RTLD_LOCAL);
    Class display = objc_getClass("CADisplay");
    Method type = class_getInstanceMethod(display, sel_registerName("displayType"));
    Method scale = class_getInstanceMethod(display, sel_registerName("pointScale"));
    if (!type || !scale || strcmp(method_getTypeEncoding(type), "q16@0:8") != 0 ||
        strcmp(method_getTypeEncoding(scale), "Q16@0:8") != 0) {
        vpMotionLog(@"inner display: CADisplay ABI unavailable, DeviceHub sees it as virtual");
        return;
    }
    vpOriginalDisplayType = method_setImplementation(type, (IMP)vpInnerDisplayType);
    vpOriginalPointScale = method_setImplementation(scale, (IMP)vpInnerPointScale);
}

// MARK: - Install

__attribute__((constructor)) static void vpInstallAngleManagerStandIn(void) {
    if (strcmp(getprogname(), "dtdeviceinfod") != 0)
        return;
    dlopen("/System/Library/Frameworks/CoreMotion.framework/CoreMotion", RTLD_LAZY | RTLD_LOCAL);
    vpInstallDeviceStateManagerStandIn();
    vpInstallInnerDisplayPresentation();
    Class manager = objc_getClass("CMAngleManager");
    if (!manager) {
        vpMotionLog(@"hinge manager: CMAngleManager not found, CoreDevice hingeAngle stays off");
        return;
    }
    // A guest with the foldable's product-id has CoreMotion's own capability
    // bits, and locationd relays the virtual hinge into the real manager.
    // The stand-in is only for a guest without them.
    if (((BOOL (*)(id, SEL))objc_msgSend)(manager, sel_registerName("isAvailable"))) {
        vpMotionLog(@"hinge manager: CoreMotion's own CMAngleManager is available, no stand-in");
        return;
    }
    vpRegisterAngleDataClass();

    Method available = class_getClassMethod(manager, sel_registerName("isAvailable"));
    if (available) {
        vpOriginalIsAvailableIMP = method_getImplementation(available);
        method_setImplementation(available, (IMP)vpSwizzledIsAvailable);
    }
    Method min = class_getClassMethod(manager, sel_registerName("minAngleDegrees"));
    if (min)
        method_setImplementation(min, (IMP)vpSwizzledMinAngle);
    Method max = class_getClassMethod(manager, sel_registerName("maxAngleDegrees"));
    if (max)
        method_setImplementation(max, (IMP)vpSwizzledMaxAngle);

    // The instance methods the bridge drives. Every one replaced means one
    // less path into CoreMotion's own MotionThread.
    Method start = class_getInstanceMethod(manager, sel_registerName("startAngleUpdatesToQueue:handler:"));
    if (start) {
        vpOriginalStartIMP = method_getImplementation(start);
        method_setImplementation(start, (IMP)vpSwizzledStartUpdates);
    }
    Method setHandler = class_getInstanceMethod(manager, sel_registerName("setAngleHandler:interval:"));
    if (setHandler) {
        vpOriginalSetHandlerIMP = method_getImplementation(setHandler);
        method_setImplementation(setHandler, (IMP)vpSwizzledSetHandler);
    }
    Method stop = class_getInstanceMethod(manager, sel_registerName("stopAngleUpdates"));
    if (stop) {
        vpOriginalStopIMP = method_getImplementation(stop);
        method_setImplementation(stop, (IMP)vpSwizzledStopUpdates);
    }
    Method internalStop = class_getInstanceMethod(objc_getClass("CMAngleManagerInternal"),
                                                  sel_registerName("stopAngleUpdatesPrivate"));
    if (internalStop && strcmp(method_getTypeEncoding(internalStop), "v16@0:8") == 0)
        method_setImplementation(internalStop, (IMP)vpSkippedInternalStop);
    Method active = class_getInstanceMethod(manager, sel_registerName("isAngleActive"));
    if (active) {
        vpOriginalActiveIMP = method_getImplementation(active);
        method_setImplementation(active, (IMP)vpSwizzledIsAngleActive);
    }
    Method getInterval = class_getInstanceMethod(manager, sel_registerName("angleUpdateInterval"));
    if (getInterval) {
        vpOriginalGetIntervalIMP = method_getImplementation(getInterval);
        method_setImplementation(getInterval, (IMP)vpSwizzledAngleUpdateInterval);
    }
    Method setInterval = class_getInstanceMethod(manager, sel_registerName("setAngleUpdateInterval:"));
    if (setInterval) {
        vpOriginalSetIntervalIMP = method_getImplementation(setInterval);
        method_setImplementation(setInterval, (IMP)vpSwizzledSetAngleUpdateInterval);
    }

    BOOL sampleReady = VPAngleDataClass != NULL;
    vpMotionLog(@"hinge manager: stand-in v7 installed (start=%@ setHandler=%@ stop=%@ internalStop=%@ active=%@ interval=%@ sample=%@ base=%@)",
                start ? @"yes" : @"MISSING", setHandler ? @"yes" : @"missing", stop ? @"yes" : @"missing",
                internalStop ? @"yes" : @"MISSING",
                active ? @"yes" : @"missing", getInterval ? @"yes" : @"missing",
                sampleReady ? @"ready" : @"MISSING",
                VPAngleDataClass ? class_getSuperclass(VPAngleDataClass) : nil);
}
