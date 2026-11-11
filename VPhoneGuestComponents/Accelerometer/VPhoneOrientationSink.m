#import "VPhoneOrientationSink.h"
#include <math.h>
#include <objc/message.h>
#include <objc/runtime.h>

@interface VPhoneDeviceOrientationSink : NSObject
@property (nonatomic, weak) id manager;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) dispatch_queue_t statusQueue;
@property (nonatomic, copy) dispatch_block_t statusChanged;
@property (nonatomic) NSInteger orientation;
@property (nonatomic) NSInteger deliveredOrientation;
@property (nonatomic) uint64_t deliveries;
@property (nonatomic, copy) NSString *error;
@property (nonatomic, copy) NSString *postSelector;
@property (nonatomic, copy) NSString *queueIvar;
@end
@implementation VPhoneDeviceOrientationSink
@end

static VPhoneDeviceOrientationSink *vpOrientationSink;
static void (*vpOriginalServicesMatched)(id, SEL, id, id);
static void (*vpOriginalSetupPipeline)(id, SEL, id);
static void (*vpOriginalAccelerometerChanged)(id, SEL, id, NSInteger);
static BOOL vpOrientationInstalled;

static NSString *vpIvarContaining(Class cls, NSString *needle) {
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        unsigned count = 0;
        Ivar *ivars = class_copyIvarList(current, &count);
        for (unsigned index = 0; index < count; index++) {
            NSString *name = [NSString stringWithUTF8String:ivar_getName(ivars[index]) ?: ""];
            if ([name containsString:needle]) {
                NSString *found = name;
                free(ivars);
                return found;
            }
        }
        free(ivars);
    }
    return nil;
}

static void vpOrientationDeliver(void) {
    VPhoneDeviceOrientationSink *sink = vpOrientationSink;
    id manager;
    dispatch_queue_t queue;
    @synchronized (sink) { manager = sink.manager; queue = sink.queue; }
    if (!manager || !queue)
        return;
    void (^deliver)(void) = ^{
        NSInteger orientation;
        @synchronized (sink) {
            orientation = sink.orientation;
            if (manager != sink.manager || orientation == sink.deliveredOrientation)
                return;
        }
        NSString *postSelector;
        @synchronized (sink) { postSelector = sink.postSelector; }
        SEL selector = sel_registerName(postSelector.UTF8String);
        if ([postSelector isEqualToString:@"orientationProvider:deviceOrientationMayHaveChanged:changeSource:isDeviceOrientationLocked:"]) {
            Class managerClass = NSClassFromString(@"BKOrientationManager");
            SEL shared = sel_registerName("sharedInstance");
            id provider = [managerClass respondsToSelector:shared]
                ? ((id (*)(id, SEL))objc_msgSend)(managerClass, shared) : nil;
            ((void (*)(id, SEL, id, NSInteger, NSInteger, BOOL))objc_msgSend)(
                manager, selector, provider, orientation, 1, NO);
        } else if ([postSelector isEqualToString:@"updateDeviceOrientation:changeSource:"]) {
            // 24A446's implementation tests bit 0 of changeSource before
            // accepting a raw device orientation. Source 1 is the accelerometer
            // path; source 0 is treated as a non-raw interface update.
            ((void (*)(id, SEL, NSInteger, NSInteger))objc_msgSend)(manager, selector, orientation, 1);
            // The high-level update already recomputes effective orientation.
            // On 24A94425, refreshEffectiveDeviceOrientation instead starts a
            // CMDeviceOrientationManager, performs deviceOrientationBlocking,
            // and posts that hardware sample back. A virtual guest has no
            // physical sample: that poll erased our injected direction with
            // Unknown (0). Do not replace virtual input with a hardware poll.
        } else
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(manager, selector, orientation);
        dispatch_queue_t statusQueue;
        dispatch_block_t changedHandler;
        @synchronized (sink) {
            sink.deliveredOrientation = orientation;
            sink.deliveries++;
            statusQueue = sink.statusQueue;
            changedHandler = sink.statusChanged;
        }
        if (statusQueue && changedHandler)
            dispatch_async(statusQueue, changedHandler);
    };
    // 24A446's updateDeviceOrientation:changeSource: synchronously dispatches
    // onto BKOrientationManager's own queue. Calling it from that queue causes
    // a self-dispatch deadlock and backboardd restart; the older raw-post
    // selector requires the manager queue instead.
    NSString *selector;
    @synchronized (sink) { selector = sink.postSelector; }
    if ([selector isEqualToString:@"updateDeviceOrientation:changeSource:"])
        deliver();
    else
        dispatch_async(queue, deliver);
}

static void vpOrientationServicesMatched(id manager, SEL selector, id matcher, id services) {
    vpOriginalServicesMatched(manager, selector, matcher, services);
    NSString *queueName;
    @synchronized (vpOrientationSink) { queueName = vpOrientationSink.queueIvar; }
    Ivar queueIvar = queueName.length ? class_getInstanceVariable(object_getClass(manager), queueName.UTF8String) : nil;
    dispatch_queue_t queue = queueIvar ? object_getIvar(manager, queueIvar) : dispatch_get_main_queue();
    if (!queue)
        return;
    @synchronized (vpOrientationSink) {
        if (manager != vpOrientationSink.manager)
            vpOrientationSink.deliveredOrientation = 0;
        vpOrientationSink.manager = manager;
        vpOrientationSink.queue = queue;
        vpOrientationSink.error = nil;
    }
    vpOrientationDeliver();
}

void VPhoneOrientationSinkInstall(dispatch_queue_t statusQueue, dispatch_block_t statusChanged) {
    @synchronized (VPhoneDeviceOrientationSink.class) {
        if (!vpOrientationSink) {
        vpOrientationSink = [VPhoneDeviceOrientationSink new];
        vpOrientationSink.orientation = 1;
        vpOrientationSink.statusQueue = statusQueue;
        vpOrientationSink.statusChanged = statusChanged;
        vpOrientationSink.error = @"Waiting for the built-in accelerometer match";
        }
        if (vpOrientationInstalled)
            return;
        Class cls = NSClassFromString(@"BKOrientationManager");
        SEL sharedSelector = sel_registerName("sharedInstance");
        SEL updateSelector = sel_registerName("updateDeviceOrientation:changeSource:");
        if (cls && [cls respondsToSelector:sharedSelector]) {
            id manager = ((id (*)(id, SEL))objc_msgSend)(cls, sharedSelector);
            if (manager && [manager respondsToSelector:updateSelector]) {
                NSString *queueName = vpIvarContaining(cls, @"queue");
                Ivar queueIvar = queueName.length ? class_getInstanceVariable(object_getClass(manager), queueName.UTF8String) : nil;
                dispatch_queue_t queue = queueIvar ? object_getIvar(manager, queueIvar) : dispatch_get_main_queue();
                @synchronized (vpOrientationSink) {
                    vpOrientationSink.manager = manager;
                    vpOrientationSink.queue = queue;
                    vpOrientationSink.postSelector = NSStringFromSelector(updateSelector);
                    vpOrientationSink.queueIvar = queueName;
                    vpOrientationSink.error = nil;
                }
                vpOrientationInstalled = YES;
                return;
            }
        }
        Class accelerometerClass = NSClassFromString(@"BKAccelerometerInterface");
        SEL accelerometerShared = sel_registerName("sharedInstance");
        SEL providerChanged = sel_registerName("orientationProvider:deviceOrientationMayHaveChanged:changeSource:isDeviceOrientationLocked:");
        if (accelerometerClass && [accelerometerClass respondsToSelector:accelerometerShared]) {
            id interface = ((id (*)(id, SEL))objc_msgSend)(accelerometerClass, accelerometerShared);
            if (interface && [interface respondsToSelector:providerChanged]) {
                @synchronized (vpOrientationSink) {
                    vpOrientationSink.manager = interface;
                    vpOrientationSink.queue = dispatch_get_main_queue();
                    vpOrientationSink.postSelector = NSStringFromSelector(providerChanged);
                    vpOrientationSink.queueIvar = nil;
                    vpOrientationSink.error = nil;
                }
                vpOrientationInstalled = YES;
                return;
            }
        }
        Method match = class_getInstanceMethod(cls, sel_registerName("matcher:servicesDidMatch:"));
        Method post = class_getInstanceMethod(cls, sel_registerName("_queue_postUpdatedRawAccelerometerDeviceOrientation:"));
        NSString *queueName = vpIvarContaining(cls, @"queue");
        if (!match || !post || method_getNumberOfArguments(match) != 4 || method_getNumberOfArguments(post) != 3) {
            vpOrientationSink.error = @"Native backboardd device-orientation sink unavailable";
            return;
        }
        vpOrientationSink.postSelector = @"_queue_postUpdatedRawAccelerometerDeviceOrientation:";
        vpOrientationSink.queueIvar = queueName;
        vpOriginalServicesMatched = (void (*)(id, SEL, id, id))method_setImplementation(
            match, (IMP)vpOrientationServicesMatched);
        vpOrientationInstalled = YES;
    }
}

void VPhoneOrientationSinkRetry(void) {
    if (!vpOrientationInstalled && vpOrientationSink)
        VPhoneOrientationSinkInstall(vpOrientationSink.statusQueue, vpOrientationSink.statusChanged);
}

void VPhoneOrientationSinkPublish(id<VPhoneAccelerometerHIDEvent> event) {
    // A dead band excludes flat/ambiguous samples. This BKS sink uses 4 for
    // the 90-degree interface and 3 for 270, unlike UIDevice's landscape
    // numbering. Confirmed with gravity-only guest readback (without AX).
    double x = event.accelerometerX, y = event.accelerometerY, z = event.accelerometerZ;
    NSInteger orientation = 0;
    if (fabs(z) < 0.5) {
        if (fabs(x) > 0.75 && fabs(y) < 0.5)
            orientation = x < 0 ? 4 : 3;
        else if (fabs(y) > 0.75 && fabs(x) < 0.5)
            orientation = y < 0 ? 1 : 2;
    }
    if (!orientation || !vpOrientationSink)
        return;
    @synchronized (vpOrientationSink) { vpOrientationSink.orientation = orientation; }
    vpOrientationDeliver();
}

NSDictionary *VPhoneOrientationSinkStatus(void) {
    VPhoneDeviceOrientationSink *sink = vpOrientationSink;
    if (!sink)
        return @{@"ready": @NO, @"error": @"Orientation bridge not installed"};
    @synchronized (sink) {
        return @{@"ready": @(sink.manager != nil && sink.queue != nil),
            @"device_orientation": @(sink.deliveredOrientation), @"deliveries": @(sink.deliveries),
            @"error": sink.error ?: @""};
    }
}

// MARK: - SpringBoard's backlight seed

static BOOL vpSpringBoardScreenIsOn(void) {
    Class cls = NSClassFromString(@"SBBacklightController");
    for (NSString *selectorName in @[@"sharedInstanceIfExists", @"sharedInstanceForMainDisplayIfExists"]) {
        SEL selector = sel_registerName(selectorName.UTF8String);
        if (![cls respondsToSelector:selector])
            continue;
        id controller = ((id (*)(id, SEL))objc_msgSend)(cls, selector);
        SEL screenIsOn = sel_registerName("screenIsOn");
        if (controller && [controller respondsToSelector:screenIsOn])
            return ((BOOL (*)(id, SEL))objc_msgSend)(controller, screenIsOn);
    }
    return YES;
}

static void vpSpringBoardRefreshOrientationGate(id manager) {
    Ivar backlight = class_getInstanceVariable(object_getClass(manager), "_backlightIsOn");
    if (backlight)
        *(BOOL *)((uint8_t *)(__bridge void *)manager + ivar_getOffset(backlight)) = vpSpringBoardScreenIsOn();
    SEL deferral = sel_registerName("_updateOrientationInputsDeferralAnimated:");
    if ([manager respondsToSelector:deferral])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(manager, deferral, NO);
    SEL updateInputs = sel_registerName("_updateInputs");
    if ([manager respondsToSelector:updateInputs])
        ((void (*)(id, SEL))objc_msgSend)(manager, updateInputs);
}

static void vpSpringBoardAccelerometerChanged(id manager, SEL selector, id accelerometer, NSInteger orientation) {
    vpSpringBoardRefreshOrientationGate(manager);
    vpOriginalAccelerometerChanged(manager, selector, accelerometer, orientation);
    vpSpringBoardRefreshOrientationGate(manager);
}

static void vpOrientationSetupPipeline(id manager, SEL selector, id arbiter) {
    vpOriginalSetupPipeline(manager, selector, arbiter);
    Class cls = NSClassFromString(@"SBBacklightController");
    SEL shared = sel_registerName("sharedInstanceIfExists");
    if (![cls respondsToSelector:shared])
        return;
    id controller = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
    SEL screenIsOn = sel_registerName("screenIsOn");
    if (![controller respondsToSelector:screenIsOn])
        return;
    BOOL on = ((BOOL (*)(id, SEL))objc_msgSend)(controller, screenIsOn);
    [manager setValue:@(on) forKey:@"_backlightIsOn"];
    ((void (*)(id, SEL))objc_msgSend)(manager, sel_registerName("_updateOrientationEventsEnabledState"));
    ((void (*)(id, SEL, BOOL))objc_msgSend)(manager,
        sel_registerName("_updateOrientationInputsDeferralAnimated:"), NO);
    NSLog(@"[vphone-accelerometer] Recomputed orientation gates after backlight seed: %d", on);
}

// MARK: - SpringBoard's wake

// SpringBoard stops listening for device orientation while the screen is off
// (_updateOrientationEventsEnabledState) and, turning it back on, does not ask
// where the device is. A real device sends a new orientation with the next
// gravity sample; this one holds still, so a turn made with the screen off
// stayed unapplied after it came on. Give the pipeline the accelerometer's
// current orientation each time the backlight animates on, as that sample
// would. An unchanged orientation changes nothing.
static void (*vpOriginalBacklightWillAnimateFloat)(id, SEL, id, float, NSInteger);
static void (*vpOriginalBacklightWillAnimateDouble)(id, SEL, id, double, NSInteger);

static void vpSpringBoardRedeliverOrientation(id manager) {
    Ivar ivar = class_getInstanceVariable(object_getClass(manager), "_accelerometer");
    id accelerometer = ivar ? object_getIvar(manager, ivar) : nil;
    SEL current = sel_registerName("currentDeviceOrientation");
    SEL changed = sel_registerName("accelerometer:didChangeDeviceOrientation:");
    if (![accelerometer respondsToSelector:current] || ![manager respondsToSelector:changed])
        return;
    // SpringBoard's own accelerometer answered 0 after a SpringBoard restart,
    // until its first delivery. An instance of our own, which never takes
    // delivery, reads where backboardd has the device now; SpringBoard's
    // answer stands in only when it cannot.
    static id fresh;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fresh = [[object_getClass(accelerometer) alloc] init]; });
    NSInteger orientation = [fresh respondsToSelector:current]
        ? ((NSInteger (*)(id, SEL))objc_msgSend)(fresh, current) : 0;
    if (orientation < 1 || orientation > 4)
        orientation = ((NSInteger (*)(id, SEL))objc_msgSend)(accelerometer, current);
    if (orientation < 1 || orientation > 4)
        return;
    ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(manager, changed, accelerometer, orientation);
}

static void vpSpringBoardBacklightAnimated(id manager, double factor) {
    if (factor <= 0)
        return;
    // After the original has turned orientation events back on.
    dispatch_async(dispatch_get_main_queue(), ^{ vpSpringBoardRedeliverOrientation(manager); });
}

static void vpSpringBoardBacklightWillAnimateFloat(id manager, SEL selector, id controller, float factor, NSInteger source) {
    vpOriginalBacklightWillAnimateFloat(manager, selector, controller, factor, source);
    vpSpringBoardBacklightAnimated(manager, factor);
}

static void vpSpringBoardBacklightWillAnimateDouble(id manager, SEL selector, id controller, double factor, NSInteger source) {
    vpOriginalBacklightWillAnimateDouble(manager, selector, controller, factor, source);
    vpSpringBoardBacklightAnimated(manager, factor);
}

static void VPhoneOrientationWakeInstall(void) {
    static BOOL installed;
    if (installed)
        return;
    Class cls = NSClassFromString(@"SBTraitsEmbeddedDisplayPipelineManager");
    Method method = class_getInstanceMethod(cls, sel_registerName("backlightController:willAnimateBacklightToFactor:source:"));
    if (!method || method_getNumberOfArguments(method) != 5 || !class_getInstanceVariable(cls, "_accelerometer")) {
        NSLog(@"[vphone-accelerometer] SpringBoard backlight wake API unavailable");
        return;
    }
    char factorType[16] = {0};
    method_getArgumentType(method, 3, factorType, sizeof factorType);
    if (factorType[0] == 'f')
        vpOriginalBacklightWillAnimateFloat = (void (*)(id, SEL, id, float, NSInteger))method_setImplementation(
            method, (IMP)vpSpringBoardBacklightWillAnimateFloat);
    else if (factorType[0] == 'd')
        vpOriginalBacklightWillAnimateDouble = (void (*)(id, SEL, id, double, NSInteger))method_setImplementation(
            method, (IMP)vpSpringBoardBacklightWillAnimateDouble);
    else {
        NSLog(@"[vphone-accelerometer] Unexpected backlight factor type %s", factorType);
        return;
    }
    installed = YES;
}

void VPhoneOrientationGateInstall(void) {
    VPhoneOrientationWakeInstall();
    Class cls = NSClassFromString(@"SBTraitsEmbeddedDisplayPipelineManager");
    Method method = class_getInstanceMethod(cls, sel_registerName("setupDefaultPipelineForArbiter:"));
    if (method && method_getNumberOfArguments(method) == 3 &&
        class_getInstanceVariable(cls, "_backlightIsOn") &&
        [cls instancesRespondToSelector:sel_registerName("_updateOrientationInputsDeferralAnimated:")]) {
        vpOriginalSetupPipeline = (void (*)(id, SEL, id))method_setImplementation(method, (IMP)vpOrientationSetupPipeline);
        return;
    }
    Method changed = class_getInstanceMethod(cls, sel_registerName("accelerometer:didChangeDeviceOrientation:"));
    if (changed && method_getNumberOfArguments(changed) == 4 && class_getInstanceVariable(cls, "_backlightIsOn") &&
        [cls instancesRespondToSelector:sel_registerName("_updateOrientationInputsDeferralAnimated:")]) {
        vpOriginalAccelerometerChanged = (void (*)(id, SEL, id, NSInteger))method_setImplementation(
            changed, (IMP)vpSpringBoardAccelerometerChanged);
        return;
    }
    NSLog(@"[vphone-accelerometer] SpringBoard orientation gate API unavailable");
}
