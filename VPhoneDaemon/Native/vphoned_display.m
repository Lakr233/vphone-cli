/*
 * vphoned_display — enumerate the display pipeline as the guest sees it.
 *
 * The depth-capped registry walk `device.ioreg` offers stops above `gfx`,
 * where a paravirt display stack publishes its controllers, so whether the
 * guest bound one display or two has been unobservable right where the Duo
 * work needs it (SpringBoard's two-always-connected-displays gate). A flat
 * IOService match over the whole plane has no depth to stop at; this file
 * filters it to display-ish classes and reports each object's small
 * properties — the identity and geometry answers backboardd builds its
 * display set from.
 */

#import "Include/VphonedNative.h"

#include <IOKit/IOKitLib.h>
#include <CoreGraphics/CoreGraphics.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <math.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <string.h>
#include <time.h>

// Private headers are not an ABI guarantee. Check the live method before
// dispatch or KVC, retaining only failed capabilities in the response.
static NSMethodSignature *vpLayoutMethodSignature(Class cls, BOOL classMethod, NSString *name, const char *returnType,
                                                  NSArray<NSString *> *arguments, NSMutableDictionary *failures) {
    Method method = classMethod ? class_getClassMethod(cls, NSSelectorFromString(name))
                                : class_getInstanceMethod(cls, NSSelectorFromString(name));
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    NSMethodSignature *signature = encoding ? [NSMethodSignature signatureWithObjCTypes:encoding] : nil;
    BOOL valid = signature && signature.numberOfArguments == arguments.count + 2;
    if (valid) {
        valid = strcmp([signature getArgumentTypeAtIndex:0], @encode(id)) == 0
            && strcmp([signature getArgumentTypeAtIndex:1], @encode(SEL)) == 0;
    }
    if (valid && returnType) valid = strcmp(signature.methodReturnType, returnType) == 0;
    if (valid && !returnType) {
        const char *type = signature.methodReturnType;
        BOOL scalar = type[0] && !type[1] && strchr("cCsSiIlLqQfdB", type[0]) != NULL;
        valid = scalar || strcmp(type, @encode(id)) == 0 || strcmp(type, @encode(CGRect)) == 0;
    }
    for (NSUInteger i = 0; valid && i < arguments.count; i++) {
        valid = strcmp([signature getArgumentTypeAtIndex:i + 2], arguments[i].UTF8String) == 0;
    }
    if (valid) return signature;
    if (failures.count < 16) {
        NSString *identity = [NSString stringWithFormat:@"%c[%s %@]", classMethod ? '+' : '-',
                              cls ? class_getName(cls) : "unavailable", name];
        failures[identity] = @{@"encoding": encoding ? @(encoding) : NSNull.null,
                               @"reason": method ? @"Unsupported method ABI" : @"Method unavailable"};
    }
    return nil;
}

static NSMethodSignature *vpLayoutSignature(id object, NSString *name, const char *returnType,
                                            NSArray<NSString *> *arguments, NSMutableDictionary *failures) {
    BOOL classMethod = object_isClass(object);
    return vpLayoutMethodSignature(classMethod ? object : object_getClass(object), classMethod,
                                    name, returnType, arguments, failures);
}

static id vpLayoutObject(id object, NSString *name, NSMutableDictionary *failures) {
    if (!object || !vpLayoutSignature(object, name, @encode(id), @[], failures)) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(name));
}

static id vpLayoutValue(id object, NSString *key, NSMutableDictionary *failures) {
    if (!object || !vpLayoutSignature(object, key, NULL, @[], failures)) return nil;
    @try {
        id value = [object valueForKey:key];
        return value == NSNull.null ? nil : value;
    } @catch (NSException *exception) {
        (void)exception;
        return nil;
    }
}

static NSNumber *vpLayoutNumber(id object, NSString *key, NSMutableDictionary *failures) {
    id value = vpLayoutValue(object, key, failures);
    if (![value isKindOfClass:NSNumber.class]
        || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()
        || !isfinite([value doubleValue])) return nil;
    return value;
}

static NSString *vpLayoutString(id object, NSString *key, NSUInteger limit, NSMutableDictionary *failures) {
    id value = vpLayoutValue(object, key, failures);
    return [value isKindOfClass:NSString.class] && [value length] <= limit ? value : nil;
}

static NSString *vpLayoutUUID(id object, NSString *key, NSMutableDictionary *failures) {
    id value = vpLayoutValue(object, key, failures);
    if ([value isKindOfClass:NSUUID.class]) return [(NSUUID *)value UUIDString];
    if (![value isKindOfClass:NSString.class] || [value length] > 128) return nil;
    return [[NSUUID alloc] initWithUUIDString:value].UUIDString;
}

static NSDictionary *vpLayoutRect(id object, NSString *key, NSMutableDictionary *failures) {
    id value = vpLayoutValue(object, key, failures);
    if (![value isKindOfClass:NSValue.class] || strcmp([(NSValue *)value objCType], @encode(CGRect)) != 0) return nil;
    CGRect rect;
    [(NSValue *)value getValue:&rect size:sizeof(rect)];
    if (!isfinite(rect.origin.x) || !isfinite(rect.origin.y)
        || !isfinite(rect.size.width) || !isfinite(rect.size.height)
        || !isfinite(CGRectGetMaxX(rect)) || !isfinite(CGRectGetMaxY(rect))
        || rect.size.width <= 0 || rect.size.height <= 0) return nil;
    return @{@"x": @(rect.origin.x), @"y": @(rect.origin.y),
             @"width": @(rect.size.width), @"height": @(rect.size.height)};
}

static NSDictionary *vpLayoutRow(id monitor, NSMutableDictionary *failures) {
    NSMutableDictionary *row = [@{@"monitor_source": @"default_main", @"geometry_available": @NO} mutableCopy];
    id layout = vpLayoutObject(monitor, @"currentLayout", failures);
    row[@"available"] = @(layout != nil);
    if (!layout) {
        row[@"reason"] = @"Monitor or ABI unavailable, or FrontBoard returned no initial layout";
        return row;
    }
    NSDictionary *bounds = vpLayoutRect(layout, @"bounds", failures);
    NSDictionary *reference = vpLayoutRect(layout, @"referenceBounds", failures);
    NSNumber *orientation = vpLayoutNumber(layout, @"interfaceOrientation", failures);
    if (bounds) row[@"bounds"] = bounds;
    if (reference) row[@"reference_bounds"] = reference;
    if (orientation) row[@"interface_orientation"] = orientation;
    NSNumber *displayType = vpLayoutNumber(layout, @"displayType", failures);
    if (displayType) row[@"display_type"] = displayType;
    id configuration = vpLayoutValue(layout, @"displayConfiguration", failures);
    for (NSString *key in @[@"name", @"deviceName"]) {
        NSString *name = vpLayoutString(configuration, key, 128, failures);
        if (name) row[[key isEqual:@"name"] ? @"display_name" : @"device_name"] = name;
    }
    NSString *uuid = vpLayoutUUID(configuration, @"hardwareIdentifier", failures);
    if (uuid) row[@"hardware_identifier"] = uuid;
    NSNumber *scale = vpLayoutNumber(configuration, @"pointScale", failures);
    if (scale && scale.doubleValue > 0) row[@"point_scale"] = scale;
    id identity = vpLayoutValue(configuration, @"identity", failures);
    NSNumber *displayID = vpLayoutNumber(identity, @"displayID", failures)
        ?: vpLayoutNumber(configuration, @"displayID", failures);
    if (displayID) row[@"display_id"] = displayID;
    BOOL validID = displayID && displayID.doubleValue > 0 && displayID.doubleValue <= UINT32_MAX
        && floor(displayID.doubleValue) == displayID.doubleValue;
    BOOL validOrientation = orientation && orientation.doubleValue >= 1 && orientation.doubleValue <= 4
        && floor(orientation.doubleValue) == orientation.doubleValue;
    row[@"geometry_available"] = @(bounds && reference && scale.doubleValue > 0 && validID && validOrientation);
    if (![row[@"geometry_available"] boolValue]) row[@"reason"] = @"Active display geometry is incomplete or unsupported";
    return row;
}

static NSDictionary *vpLayoutUnavailable(NSString *reason, NSString *state) {
    return @{@"available": @NO, @"geometry_available": @NO, @"reason": reason,
             @"monitors": @[], @"cadisplays": @[],
             @"thread": @{@"caller_is_main": @(NSThread.isMainThread), @"capture_state": state}};
}

static NSDictionary *vpLayoutResponse(NSDictionary *report) {
    BOOL available = [report[@"available"] boolValue];
    BOOL geometryAvailable = [report[@"geometry_available"] boolValue];
    NSString *reason = report[@"reason"] ?: @"";
    NSArray *monitors = report[@"monitors"] ?: @[];
    NSArray *displays = report[@"cadisplays"] ?: @[];
    NSDictionary *thread = report[@"thread"] ?: @{};
    NSDictionary *observation = report[@"observation"] ?: @{};
    NSDictionary *failures = report[@"capability_failures"] ?: @{};
    return @{@"available": @(available), @"geometry_available": @(geometryAvailable), @"reason": reason,
             @"monitors": monitors, @"cadisplays": displays, @"thread": thread,
             @"observation": observation, @"capability_failures": failures};
}

static NSDictionary *vpLayoutCapture(NSMutableDictionary *capture) {
    // The worker runs RunLoop.main in main.swift; one-shot scripting sessions
    // exit before that startup and cannot safely observe an initial layout.
    CFStringRef mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain());
    BOOL safeThread = NSThread.isMainThread && mode != NULL;
    if (mode) CFRelease(mode);
    if (!safeThread) return vpLayoutUnavailable(@"An active main run loop is required", @"unsafe_thread");
    NSMutableDictionary *failures = capture[@"capability_failures"];
    @try {
        if (!failures) {
            dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY | RTLD_LOCAL);
            dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY | RTLD_LOCAL);
            failures = [NSMutableDictionary dictionary];
            capture[@"capability_failures"] = failures;
            id displays = vpLayoutObject(objc_lookUpClass("CADisplay"), @"displays", failures);
            NSMutableArray *inventory = [NSMutableArray array];
            if ([displays isKindOfClass:NSArray.class]) {
                for (id display in displays) {
                    NSMutableDictionary *item = [NSMutableDictionary dictionary];
                    for (NSString *key in @[@"displayId", @"displayType", @"pointScale"]) {
                        NSNumber *value = vpLayoutNumber(display, key, failures);
                        if (value) item[key] = value;
                    }
                    for (NSString *key in @[@"name", @"deviceName"]) {
                        NSString *value = vpLayoutString(display, key, 128, failures);
                        if (value) item[key] = value;
                    }
                    for (NSString *key in @[@"currentOrientation", @"nativeOrientation"]) {
                        id value = vpLayoutNumber(display, key, failures) ?: vpLayoutString(display, key, 32, failures);
                        if (value) item[key] = value;
                    }
                    NSDictionary *bounds = vpLayoutRect(display, @"bounds", failures);
                    NSString *uuid = vpLayoutUUID(display, @"uniqueId", failures);
                    if (bounds) item[@"bounds"] = bounds;
                    if (uuid) item[@"uniqueId"] = uuid;
                    [inventory addObject:item];
                    if (inventory.count == 16) break;
                }
            }
            capture[@"cadisplays"] = inventory;
            // The CADisplay and FrontBoard display-type enums differ. The
            // default-main monitor independently selects the active display.
            id configuration = vpLayoutObject(objc_lookUpClass("FBSDisplayLayoutMonitorConfiguration"),
                                               @"configurationForDefaultMainDisplayMonitor", failures);
            Class monitorClass = objc_lookUpClass("FBSDisplayLayoutMonitor");
            if (configuration
                && vpLayoutSignature(monitorClass, @"monitorWithConfiguration:", @encode(id), @[@(@encode(id))], failures)
                && vpLayoutMethodSignature(monitorClass, NO, @"invalidate", @encode(void), @[], failures)) {
                id monitor = ((id (*)(id, SEL, id))objc_msgSend)(monitorClass,
                    sel_registerName("monitorWithConfiguration:"), configuration);
                if (monitor) capture[@"owned_monitor"] = monitor;
            }
        }
        NSDictionary *row = vpLayoutRow(capture[@"owned_monitor"], failures);
        return @{@"available": row[@"available"], @"geometry_available": row[@"geometry_available"],
                 @"reason": row[@"reason"] ?: @"", @"monitors": @[row],
                 @"cadisplays": capture[@"cadisplays"] ?: @[], @"capability_failures": failures,
                 @"thread": @{@"capture_is_main": @YES, @"main_run_loop_active": @YES, @"capture_state": @"completed"}};
    } @catch (NSException *exception) {
        capture[@"failed"] = @YES;
        NSMutableDictionary *report = [vpLayoutUnavailable(exception.reason ?: @"FrontBoard layout query failed", @"exception") mutableCopy];
        report[@"capability_failures"] = failures ?: @{};
        return report;
    }
}

static double vpLayoutMonotonicTime(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec + now.tv_nsec / 1e9;
}

static void vpLayoutFinish(NSMutableDictionary *capture, NSMutableDictionary *report,
                           void (^completion)(NSDictionary *)) {
    id monitor = capture[@"owned_monitor"];
    @try {
        if (monitor) {
            if (!vpLayoutSignature(monitor, @"invalidate", @encode(void), @[], capture[@"capability_failures"])) {
                report[@"available"] = @NO;
                report[@"geometry_available"] = @NO;
                report[@"monitors"] = @[];
                report[@"reason"] = @"Owned monitor cleanup ABI is unavailable";
            } else {
                ((void (*)(id, SEL))objc_msgSend)(monitor, sel_registerName("invalidate"));
            }
        }
    } @catch (NSException *exception) {
        report[@"available"] = @NO;
        report[@"geometry_available"] = @NO;
        report[@"monitors"] = @[];
        report[@"reason"] = exception.reason ?: @"Owned monitor cleanup failed";
    } @finally {
        [capture removeObjectForKey:@"owned_monitor"];
        monitor = nil;
    }
    completion(report);
}

static void vpLayoutSample(NSMutableDictionary *capture, BOOL (^cancelled)(void),
                           void (^completion)(NSDictionary *)) {
    // Yield the main run loop between samples so FrontBoard can deliver its
    // initial state. Sampling and owned-monitor cleanup remain on main.
    if (cancelled()) {
        vpLayoutFinish(capture, [vpLayoutUnavailable(@"Layout observation cancelled", @"cancelled") mutableCopy], completion);
        return;
    }
    double elapsed = vpLayoutMonotonicTime() - [capture[@"started_at"] doubleValue];
    NSUInteger samples = [capture[@"sample_count"] unsignedIntegerValue];
    NSMutableDictionary *report;
    if (samples > 0 && elapsed >= 1.2) {
        report = [capture[@"last_report"] mutableCopy];
    } else {
        report = [vpLayoutCapture(capture) mutableCopy];
        capture[@"last_report"] = report;
        capture[@"sample_count"] = @(++samples);
        elapsed = vpLayoutMonotonicTime() - [capture[@"started_at"] doubleValue];
    }
    BOOL available = [report[@"available"] boolValue];
    BOOL canObserve = capture[@"owned_monitor"] && ![capture[@"failed"] boolValue];
    if (!available && canObserve && elapsed < 1.2 && !cancelled()) {
        int64_t delay = (int64_t)(fmin(0.05, 1.2 - elapsed) * NSEC_PER_SEC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), dispatch_get_main_queue(), ^{
            @autoreleasepool { vpLayoutSample(capture, cancelled, completion); }
        });
        return;
    }
    report[@"observation"] = @{@"state": available ? @"available" : canObserve ? @"initial_layout_deadline" : @"unavailable",
                               @"sample_count": @(samples), @"elapsed_ms": @(elapsed * 1000),
                               @"limit_ms": @1200, @"sample_interval_ms": @50};
    if (!available && canObserve) report[@"reason"] = @"No initial FrontBoard layout observed before the observation deadline";
    vpLayoutFinish(capture, report, completion);
}

NSDictionary<NSString *, id> *vp_display_layout(void) {
    dispatch_time_t entered = dispatch_time(DISPATCH_TIME_NOW, 0);
    dispatch_time_t deadline = dispatch_time(entered, 1500 * NSEC_PER_MSEC);
    if (NSThread.isMainThread) {
        return vpLayoutResponse(vpLayoutUnavailable(@"Asynchronous layout observation requires a background caller", @"main_thread_caller"));
    }
    static dispatch_semaphore_t slot;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ slot = dispatch_semaphore_create(1); });
    if (dispatch_semaphore_wait(slot, dispatch_time(entered, 300 * NSEC_PER_MSEC)) != 0) {
        return vpLayoutResponse(vpLayoutUnavailable(@"Layout capture admission deadline exceeded", @"busy"));
    }
    NSLock *lock = [NSLock new];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL started = NO;
    __block BOOL cancelled = NO;
    __block NSDictionary *result = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [lock lock];
        if (cancelled) {
            [lock unlock];
            dispatch_semaphore_signal(slot);
            return;
        }
        started = YES;
        [lock unlock];
        @autoreleasepool {
            NSMutableDictionary *capture = [NSMutableDictionary dictionaryWithObject:@(vpLayoutMonotonicTime()) forKey:@"started_at"];
            vpLayoutSample(capture, ^BOOL {
                [lock lock];
                BOOL value = cancelled;
                [lock unlock];
                return value;
            }, ^(NSDictionary *report) {
                [lock lock];
                result = report;
                [lock unlock];
                dispatch_semaphore_signal(done);
                dispatch_semaphore_signal(slot);
            });
        }
    });
    // Admission and completion share one background response deadline. Keep
    // queued cancellations admitted until main drains them, bounding pending
    // blocks. A running private call cannot be interrupted: retain its slot
    // and monitor until main-thread cleanup, even after caller timeout.
    if (dispatch_semaphore_wait(done, deadline) != 0) {
        [lock lock];
        cancelled = YES;
        BOOL running = started;
        [lock unlock];
        return vpLayoutResponse(vpLayoutUnavailable(running ? @"Layout capture exceeded the response deadline; private call may still be running"
                                                           : @"Main run loop did not accept the capture before the deadline; queued capture cancelled",
                                                     running ? @"timed_out_running" : @"cancelled_before_start"));
    }
    [lock lock];
    NSDictionary *report = result;
    [lock unlock];
    return vpLayoutResponse(report);
}

static NSDictionary *vpModeDescription(id mode) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"width", @"height", @"refreshRate", @"isVirtual", @"preferredUIScale", @"pointScale"]) {
        if (![mode respondsToSelector:NSSelectorFromString(key)]) continue;
        id value = [mode valueForKey:key];
        if ([value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class]) result[key] = value;
    }
    return result;
}

NSDictionary<NSString *, id> *vp_display_modes(void) {
    @try {
        dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY | RTLD_LOCAL);
        Class cls = objc_getClass("CADisplay");
        SEL enumerate = sel_registerName("displays");
        if (![cls respondsToSelector:enumerate]) return @{@"available": @NO, @"reason": @"CADisplay.displays unavailable"};
        SEL refresh = sel_registerName("updateDisplays");
        if ([cls respondsToSelector:refresh]) ((void (*)(id, SEL))objc_msgSend)(cls, refresh);
        id displays = ((id (*)(id, SEL))objc_msgSend)(cls, enumerate);
        if (![displays isKindOfClass:NSArray.class]) return @{@"available": @NO, @"reason": @"unexpected display collection"};
        NSMutableArray *rows = [NSMutableArray array];
        for (id display in displays) {
            NSMutableDictionary *row = [NSMutableDictionary dictionary];
            for (NSString *key in @[@"name", @"deviceName", @"displayId", @"displayType", @"allowsVirtualModes",
                                    @"isSupported", @"isExternal", @"isReference", @"isCloningSupported",
                                    @"isCloning", @"isCloned", @"pointScale", @"minimumLogicalScale",
                                    @"maximumLogicalScale", @"tag", @"seed", @"connectionSeed"]) {
                if (![display respondsToSelector:NSSelectorFromString(key)]) continue;
                id value = [display valueForKey:key];
                if ([value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class]) row[key] = value;
            }
            for (NSString *key in @[@"bounds", @"nativeSize", @"currentOrientation", @"nativeOrientation", @"logicalScale", @"uniqueId"]) {
                if ([display respondsToSelector:NSSelectorFromString(key)]) row[key] = [[display valueForKey:key] description] ?: @"";
            }
            if ([display respondsToSelector:sel_registerName("currentMode")]) row[@"current_mode"] = vpModeDescription([display valueForKey:@"currentMode"]);
            if ([display respondsToSelector:sel_registerName("availableModes")]) {
                NSMutableArray *modes = [NSMutableArray array];
                for (id mode in [display valueForKey:@"availableModes"]) {
                    [modes addObject:vpModeDescription(mode)];
                    if (modes.count == 64) break;
                }
                row[@"available_modes"] = modes;
            }
            row[@"can_set_mode"] = @([display respondsToSelector:sel_registerName("setCurrentMode:")]);
            row[@"can_allow_virtual_modes"] = @([display respondsToSelector:sel_registerName("setAllowsVirtualModes:")]);
            if ([display respondsToSelector:sel_registerName("stateControl")]) {
                id state = [display valueForKey:@"stateControl"];
                NSMutableDictionary *values = [NSMutableDictionary dictionary];
                for (NSString *key in @[@"displayState", @"powerState", @"cloningState", @"targetDisplayState", @"targetPowerState"])
                    if ([state respondsToSelector:NSSelectorFromString(key)]) values[key] = [state valueForKey:key] ?: NSNull.null;
                row[@"state"] = values;
            }
            [rows addObject:row];
            if (rows.count == 16) break;
        }
        return @{@"available": @YES, @"displays": rows};
    } @catch (NSException *exception) {
        return @{@"available": @NO, @"reason": exception.reason ?: exception.name};
    }
}

/// Property keys worth reporting whole; everything else of a printable
/// scalar kind is reported by kind, and blobs are skipped.
static id valueForReport(id value) {
    if ([value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class]) {
        if ([value isKindOfClass:NSString.class] && [(NSString *)value length] > 96) {
            return nil;
        }
        return value;
    }
    if ([value isKindOfClass:NSData.class] && [(NSData *)value length] <= 16) {
        return [value description];
    }
    return nil;
}

NSArray *vp_display_probe(void) {
    NSMutableArray *found = [NSMutableArray array];
    // First the boot display handoff iBoot left in the device tree's
    // /chosen: the geometry early userspace inherits before any driver
    // re-reports it, and the outer size a stale one would pin UI to.
    io_registry_entry_t chosen = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen");
    if (chosen != MACH_PORT_NULL) {
        io_name_t chosenName = {0};
        IORegistryEntryGetName(chosen, chosenName);
        NSMutableDictionary *chosenRow = [NSMutableDictionary dictionary];
        chosenRow[@"class"] = @"IODeviceTree:/chosen";
        chosenRow[@"name"] = [NSString stringWithUTF8String:chosenName] ?: @"chosen";
        CFMutableDictionaryRef chosenProps = NULL;
        if (IORegistryEntryCreateCFProperties(chosen, &chosenProps, kCFAllocatorDefault, kNilOptions)
            == KERN_SUCCESS && chosenProps) {
            NSMutableDictionary *reported = [NSMutableDictionary dictionary];
            NSDictionary *all = (__bridge NSDictionary *)chosenProps;
            for (NSString *key in all) {
                id value = valueForReport(all[key]);
                if (value) {
                    reported[key] = value;
                }
            }
            CFRelease(chosenProps);
            chosenRow[@"properties"] = reported;
        }
        IOObjectRelease(chosen);
        [found addObject:chosenRow];
    }
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOService"), &iterator)
        != KERN_SUCCESS) {
        return @[@{@"error": @"IOService enumeration failed"}];
    }
    io_object_t entry;
    while ((entry = IOIteratorNext(iterator))) {
        io_name_t cls = {0};
        if (IOObjectGetClass(entry, cls) != KERN_SUCCESS) {
            IOObjectRelease(entry);
            continue;
        }
        NSString *className = [NSString stringWithUTF8String:cls] ?: @"";
        NSString *lower = className.lowercaseString;
        bool displayish = [lower containsString:@"display"] || [lower containsString:@"framebuffer"]
            || [lower containsString:@"appleclcd"] || [lower containsString:@"gpu"];
        if (!displayish) {
            IOObjectRelease(entry);
            continue;
        }
        io_name_t name = {0};
        IORegistryEntryGetName(entry, name);
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        row[@"class"] = className;
        row[@"name"] = [NSString stringWithUTF8String:name] ?: @"";
        CFMutableDictionaryRef properties = NULL;
        if (IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, kNilOptions)
            == KERN_SUCCESS && properties) {
            NSMutableDictionary *reported = [NSMutableDictionary dictionary];
            NSDictionary *all = (__bridge NSDictionary *)properties;
            for (NSString *key in all) {
                id value = valueForReport(all[key]);
                if (value) {
                    reported[key] = value;
                }
            }
            CFRelease(properties);
            row[@"properties"] = reported;
        }
        [found addObject:row];
        IOObjectRelease(entry);
        if (found.count >= 64) {
            IOObjectRelease(iterator);
            return found;
        }
    }
    IOObjectRelease(iterator);
    return found;
}

bool vp_device_tree_has_property(const char *path, const char *name) {
    io_registry_entry_t entry = IORegistryEntryFromPath(kIOMainPortDefault, path);
    if (entry == MACH_PORT_NULL) return false;
    CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingUTF8);
    CFTypeRef value = key ? IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0) : NULL;
    if (key) CFRelease(key);
    IOObjectRelease(entry);
    if (value) CFRelease(value);
    return value != NULL;
}
