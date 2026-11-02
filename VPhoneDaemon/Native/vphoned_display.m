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
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>

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
