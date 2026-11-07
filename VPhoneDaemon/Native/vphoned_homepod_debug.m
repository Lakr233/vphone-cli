/* SoundBoardServices 27.0 SBSDebugInterface. The selector/argument inventory is
 * the complete SBSDebugInfoImplementer protocol in AudioAccessory5,1 24J361.
 * This bridge calls the framework's own XPC client; it does not inject code into
 * SoundBoard. See Research/Firmware/homepod_mini_support.md. */
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <math.h>
#include <unistd.h>

static NSDictionary *argument(NSString *name, NSString *type, id initial, NSString *help) {
    return @{ @"name": name, @"type": type, @"initial": initial, @"help": help };
}

static NSDictionary *operation(NSString *selector, NSString *title, NSString *group,
                               NSArray *arguments, NSString *reply, NSString *help) {
    return @{ @"id": selector, @"title": title, @"group": group,
              @"arguments": arguments, @"reply": reply, @"help": help };
}

static NSArray<NSDictionary *> *operations(void) {
    static NSArray *catalog;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *(^text)(NSString *, NSString *) = ^(NSString *name, NSString *help) {
            return argument(name, @"string", @"", help);
        };
        NSDictionary *(^array)(NSString *, NSString *) = ^(NSString *name, NSString *help) {
            return argument(name, @"array", @[], help);
        };
        catalog = @[
            operation(@"getAllDebugInfo:", @"Read All Debug Info", @"Diagnostics", @[], @"object", @"Read SoundBoard's complete diagnostic dictionary."),
            operation(@"getSelectDebugInfo:reply:", @"Read Selected Debug Info", @"Diagnostics", @[array(@"keys", @"Diagnostic key names from Read All Debug Info.")], @"object", @"Read a subset of SoundBoard diagnostics."),
            operation(@"getLEDInfo:", @"Read LED Info", @"Display", @[], @"object", @"Read SoundBoard's display, media and power state."),
            operation(@"sendLEDCommand:", @"Send LED Command", @"Display", @[text(@"command", @"VisualSource command, for example all 255 0 0. Separate commands with newlines; an empty string clears TestLEDDraw.")], @"none", @"TestLEDDraw requires an internal-content build. Retail guests may accept this command without drawing; use Set LED Contents for native frame replay."),
            operation(@"render:", @"Render Animation", @"Display", @[argument(@"options", @"dictionary", @{@"animation": @"setup", @"phase": @"On"}, @"Animation name and phase; both keys are required.")], @"none", @"Enable HomePodBuddyConnection with Set User Default (value 1), then restart SoundBoard before rendering animations."),
            operation(@"setLEDContents:", @"Set LED Contents", @"Display", @[argument(@"contents", @"replay", @[@{@"LedValuesTimestamp": @0, @"LedValuesData": @{@"fill": @[@0, @0, @0]}}], @"Nonempty frame array. Each frame has a UInt64 LedValuesTimestamp (mach ticks relative to the first frame) and LedValuesData: {\"base64\":\"…\"}, {\"fill\":[r,g,b]}, or {\"rgb\":[[r,g,b],…]}. HomePod mini uses 19 Siri, 2 icon, then 19 AOD Float RGB triples (480 bytes). A single black frame replaces and ends replay.")], @"none", @"Replay native display frames through SoundBoard's display service."),
            operation(@"setBootSpinner:", @"Set Boot Spinner", @"Display", @[argument(@"enabled", @"bool", @NO, @"Show or hide the boot spinner.")], @"none", @"Control SoundBoard's boot spinner."),
            operation(@"getVolume:", @"Read SoundBoard Volume", @"Audio", @[], @"float", @"Read SoundBoard's Audio/Video volume."),
            operation(@"setVolume:", @"Set SoundBoard Volume", @"Audio", @[argument(@"value", @"float", @0.5, @"Audio/Video volume, 0 to 1.")], @"none", @"Set volume through SoundBoard's volume manager."),
            operation(@"playTone:", @"Play Tone", @"Audio", @[argument(@"tone", @"uint32", @0, @"Native UInt32 tone identifier.")], @"none", @"Play a native SoundBoard UI tone."),
            operation(@"stopTone:", @"Stop Tone", @"Audio", @[argument(@"tone", @"uint32", @0, @"The tone identifier used by Play Tone.")], @"none", @"Stop a native SoundBoard UI tone."),
            operation(@"siriSay:", @"Speak with Siri", @"Audio", @[text(@"text", @"Text passed to SoundBoard's Siri manager.")], @"none", @"Ask SoundBoard's Siri manager to speak text."),
            operation(@"sendButtonCommand:", @"Send Button Event", @"Input", @[argument(@"event", @"button", @{@"button": @3, @"action": @2, @"numberOfTaps": @1, @"startMachTime": @0, @"deviceSideways": @NO, @"coalesced": @YES}, @"Buttons: 1 Minus, 2 Plus, 3 Center, 4 Cover. Actions: 1 TouchMightHaveBegun, 2 TapRegistered, 3 HoldBegan, 4 HoldEnded, 5 TouchCancelled. For TapRegistered, coalesced:true sends the final tap gesture; use false for raw, uncoalesced events. Use HPButtonEvent fields, or {\"base64\":\"…\"} for an existing secure archive.")], @"none", @"Create and securely archive an HPButtonEvent for SoundBoard."),
            operation(@"getTuningInfo:", @"Read Tuning Info", @"Tuning", @[], @"object", @"Read SoundBoard's exposed tuning boxes and parameters."),
            operation(@"setTuningInfoOnBox:at:withValue:", @"Set Tuning Value", @"Tuning", @[text(@"box", @"Box name from Read Tuning Info."), text(@"parameter", @"Parameter name from Read Tuning Info."), argument(@"value", @"float", @0, @"Native Float tuning value.")], @"none", @"Change an exposed tuning parameter."),
            operation(@"getUserDefaults:", @"Read User Defaults", @"Preferences", @[], @"object", @"Read SoundBoard's debug defaults and their metadata."),
            operation(@"setUserDefaults:withValue:", @"Set User Default", @"Preferences", @[text(@"name", @"Default name from Read User Defaults."), text(@"value", @"String parsed by SoundBoard according to the default's native type.")], @"none", @"Set one SoundBoard debug default."),
            operation(@"resetUserDefault:", @"Reset User Default", @"Preferences", @[text(@"name", @"Default name from Read User Defaults.")], @"none", @"Restore one SoundBoard debug default."),
            operation(@"resetAllUserDefaults", @"Reset All User Defaults", @"Preferences", @[], @"none", @"Restore every SoundBoard debug default."),
            operation(@"getFeatureFlags:", @"Read Feature Flags", @"Preferences", @[], @"object", @"Read SoundBoard's exposed feature flags."),
            operation(@"setFeatureFlags:", @"Set Feature Flags", @"Preferences", @[array(@"flags", @"Feature flag dictionary representations returned by Read Feature Flags.")], @"none", @"Submit feature flag dictionary representations."),
            operation(@"triggerWiFiCoreCapture:", @"Capture Wi-Fi Diagnostics", @"Network", @[text(@"reason", @"Reason included in the Wi-Fi CoreCapture request.")], @"none", @"Trigger SoundBoard's Wi-Fi CoreCapture facility."),
            operation(@"setWifiEnabled:", @"Set Wi-Fi Enabled", @"Network", @[argument(@"enabled", @"bool", @YES, @"Turn Wi-Fi on or off.")], @"none", @"Change SoundBoard's Wi-Fi state."),
            operation(@"disassociateCurrentNetwork", @"Disassociate Current Network", @"Network", @[], @"none", @"Disconnect SoundBoard from its current Wi-Fi network."),
            operation(@"disassociateNetworkWithName:", @"Disassociate Named Network", @"Network", @[text(@"name", @"Wi-Fi network name.")], @"none", @"Disassociate a Wi-Fi network by name."),
            operation(@"injectSWUpdateToHome:", @"Inject Home Software Update", @"Software Update", @[argument(@"options", @"dictionary", @{}, @"Native keys: serverAssetAlgorithm, serverAssetMeasurement, serverAssetURL, majorVer, minorVer, state, updateVer, productBuildVersion, downloadSize.")], @"none", @"Inject a software update description into the Home."),
            operation(@"setHomeUpdateState:", @"Set Home Update State", @"Software Update", @[argument(@"state", @"int64", @0, @"Native signed 64-bit Home update state.")], @"none", @"Change the Home's software update state."),
            operation(@"clearHomeSWUpdate", @"Clear Home Software Update", @"Software Update", @[], @"none", @"Clear the injected Home software update."),
            operation(@"suScanForSoftwareUpdate", @"Scan for Software Update", @"Software Update", @[], @"none", @"Ask SoundBoard to scan for a software update."),
        ];
    });
    return catalog;
}

static Class debugClass(void) {
#ifndef VP_HOMEPOD_DEBUG_TESTING
    if (access("/System/Library/CoreServices/SoundBoard.app/SoundBoard", F_OK) != 0) return Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/SoundBoardServices.framework/SoundBoardServices", RTLD_NOW);
    });
#endif
    return NSClassFromString(@"SBSDebugInterface");
}

bool vp_homepod_debug_available(void) { return debugClass() != Nil; }

static const char *argumentEncoding(NSString *type) {
    if ([type isEqual:@"bool"]) return @encode(BOOL);
    if ([type isEqual:@"float"]) return @encode(float);
    if ([type isEqual:@"uint32"]) return @encode(uint32_t);
    if ([type isEqual:@"int64"]) return @encode(int64_t);
    return @encode(id);
}

static BOOL matchesSignature(NSMethodSignature *signature, NSDictionary *spec) {
    NSArray *arguments = spec[@"arguments"];
    BOOL hasReply = ![spec[@"reply"] isEqual:@"none"];
    if (!signature || strcmp(signature.methodReturnType, @encode(void)) != 0 ||
        signature.numberOfArguments != 2 + arguments.count + (hasReply ? 1 : 0)) return NO;
    for (NSUInteger i = 0; i < arguments.count; i++) {
        if (strcmp([signature getArgumentTypeAtIndex:i + 2], argumentEncoding(arguments[i][@"type"])) != 0) return NO;
    }
    return !hasReply || strcmp([signature getArgumentTypeAtIndex:arguments.count + 2], @encode(void (^)(id))) == 0;
}

static id JSONValue(id value, NSUInteger depth) {
    if (!value || value == NSNull.null) return NSNull.null;
    if (depth > 24) return @{@"error": @"Reply exceeded nesting limit"};
    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) return value;
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *out = NSMutableDictionary.dictionary;
        for (id key in value) out[[key description]] = JSONValue(value[key], depth + 1);
        return out;
    }
    if ([value isKindOfClass:NSArray.class] || [value isKindOfClass:NSSet.class]) {
        NSMutableArray *out = NSMutableArray.array;
        for (id item in value) [out addObject:JSONValue(item, depth + 1)];
        return out;
    }
    if ([value isKindOfClass:NSData.class]) {
        NSMutableDictionary *out = [@{@"base64": [value base64EncodedStringWithOptions:0], @"length": @([value length])} mutableCopy];
        Class infoClass = NSClassFromString(@"SBSDefaultInfo");
        if (infoClass) {
            NSSet *classes = [NSSet setWithObjects:infoClass, NSDictionary.class, NSArray.class, NSString.class, NSNumber.class, NSData.class, NSNull.class, nil];
            id decoded = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:value error:NULL];
            if (decoded) out[@"decoded"] = JSONValue(decoded, depth + 1);
        }
        return out;
    }
    if ([value isKindOfClass:NSURL.class]) return [value absoluteString];
    if ([value isKindOfClass:NSDate.class]) return @([value timeIntervalSince1970]);
    NSString *name = NSStringFromClass([value class]);
    if ([name isEqual:@"SBSFeatureFlag"]) return JSONValue([value valueForKey:@"dictionaryRepresentation"], depth + 1);
    if ([name isEqual:@"SBSDefaultInfo"]) {
        NSMutableDictionary *out = NSMutableDictionary.dictionary;
        for (NSString *key in @[@"stringForUserDefault", @"userDescription", @"defaultValue", @"isBool", @"isDouble", @"rangeMin", @"rangeMax", @"requiresReinit", @"defaultType", @"valueType"]) {
            out[key] = JSONValue([value valueForKey:key], depth + 1);
        }
        return out;
    }
    return @{@"class": name, @"description": [value description]};
}

static BOOL nativeNumber(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID();
}
static BOOL nativeUnsigned(id value, uint64_t maximum) {
    if (!nativeNumber(value)) return NO;
    const char *type = [value objCType];
    if (strcmp(type, @encode(float)) == 0 || strcmp(type, @encode(double)) == 0) return NO;
    return [value compare:@0] != NSOrderedAscending && [value compare:@(maximum)] != NSOrderedDescending;
}
static BOOL nativeSigned(id value) {
    if (!nativeNumber(value)) return NO;
    const char *type = [value objCType];
    return strcmp(type, @encode(double)) != 0 && strcmp(type, @encode(float)) != 0 &&
        [value compare:@(INT64_MIN)] != NSOrderedAscending && [value compare:@(INT64_MAX)] != NSOrderedDescending;
}
static BOOL nativeBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static NSUInteger replayColorCount(void) {
#ifdef VP_HOMEPOD_DEBUG_TESTING
    return 40;
#else
    NSDictionary *configuration = [NSDictionary dictionaryWithContentsOfFile:@"/usr/share/vphone/HomePodDisplay.plist"];
    NSData *coordinates = configuration[@"MDXCoords"], *hardware = configuration[@"MDHWVersion"];
    if (![coordinates isKindOfClass:NSData.class] || !coordinates.length || coordinates.length % 4 ||
        ![hardware isKindOfClass:NSData.class] || hardware.length != 4) return 0;
    uint32_t version;
    memcpy(&version, hardware.bytes, sizeof(version));
    NSUInteger leds = coordinates.length / 4;
    if (leds > 4096) return 0;
    // Peppy animation buffers have one RGB triple per LED in each bank plus
    // the two volume icons. The replay buffer uses Float channels, unlike HID.
    return leds * (version > 2 ? 2 : 1) + 2;
#endif
}

static id replayContents(id value, NSString **error) {
    if (![value isKindOfClass:NSArray.class] || [value count] == 0) {
        *error = @"contents must be a nonempty array of replay frame dictionaries"; return nil;
    }
    NSUInteger count = replayColorCount();
    if (!count) { *error = @"Display geometry is unavailable; enable the HomePod top-cap patch before replaying frames"; return nil; }
    NSMutableArray *result = NSMutableArray.array;
    uint64_t previous = 0;
    for (id frame in value) {
        if (![frame isKindOfClass:NSDictionary.class] || !nativeUnsigned(frame[@"LedValuesTimestamp"], UINT64_MAX)) {
            *error = @"Every replay frame needs a UInt64 LedValuesTimestamp"; return nil;
        }
        uint64_t timestamp = [frame[@"LedValuesTimestamp"] unsignedLongLongValue];
        if (result.count && timestamp < previous) { *error = @"Replay timestamps must be in ascending order"; return nil; }
        previous = timestamp;
        id input = frame[@"LedValuesData"];
        if (![input isKindOfClass:NSDictionary.class]) { *error = @"LedValuesData must be a base64, fill, or rgb object"; return nil; }
        NSData *data;
        if ([input[@"base64"] isKindOfClass:NSString.class]) {
            data = [[NSData alloc] initWithBase64EncodedString:input[@"base64"] options:0];
        } else {
            NSArray *colors = input[@"rgb"];
            if (input[@"fill"]) {
                NSMutableArray *fill = NSMutableArray.array;
                for (NSUInteger i = 0; i < count; i++) [fill addObject:input[@"fill"]];
                colors = fill;
            }
            if (![colors isKindOfClass:NSArray.class] || colors.count != count) {
                *error = [NSString stringWithFormat:@"Replay rgb needs %lu RGB triples", (unsigned long)count]; return nil;
            }
            NSMutableData *encoded = [NSMutableData dataWithCapacity:count * 3 * sizeof(float)];
            for (id color in colors) {
                if (![color isKindOfClass:NSArray.class] || [color count] != 3) { *error = @"Replay RGB values must be three-element arrays"; return nil; }
                for (id channel in color) {
                    if (!nativeNumber(channel) || !isfinite([channel doubleValue]) || fabs([channel doubleValue]) > FLT_MAX) {
                        *error = @"Replay RGB channels must be finite Float numbers"; return nil;
                    }
                    float scalar = [channel floatValue];
                    [encoded appendBytes:&scalar length:sizeof(scalar)];
                }
            }
            data = encoded;
        }
        if (!data || data.length != count * 3 * sizeof(float)) {
            *error = [NSString stringWithFormat:@"Replay LedValuesData needs exactly %lu bytes", (unsigned long)(count * 3 * sizeof(float))]; return nil;
        }
        NSMutableDictionary *converted = [frame mutableCopy];
        converted[@"LedValuesData"] = data;
        [result addObject:converted];
    }
    return result;
}

static id buttonData(id value, NSString **error) {
    if (![value isKindOfClass:NSDictionary.class]) { *error = @"event must be an HPButtonEvent object or a base64 archive object"; return nil; }
    if (value[@"base64"]) {
        if (![value[@"base64"] isKindOfClass:NSString.class]) { *error = @"base64 must be a string"; return nil; }
        NSData *data = [[NSData alloc] initWithBase64EncodedString:value[@"base64"] options:0];
        if (!data) *error = @"event base64 is invalid";
        return data;
    }
#ifndef VP_HOMEPOD_DEBUG_TESTING
    dlopen("/System/Library/PrivateFrameworks/SoundBoardFramework.framework/SoundBoardFramework", RTLD_NOW);
#endif
    Class cls = NSClassFromString(@"HPButtonEvent");
    if (!cls) { *error = @"HPButtonEvent is unavailable"; return nil; }
    id event = [cls new];
    for (NSString *key in @[@"button", @"action", @"numberOfTaps", @"startMachTime", @"deviceSideways", @"coalesced"]) {
        id field = value[key];
        BOOL valid;
        if ([key isEqual:@"deviceSideways"] || [key isEqual:@"coalesced"]) valid = nativeBoolean(field);
        else if ([key isEqual:@"numberOfTaps"]) valid = nativeSigned(field) && [field longLongValue] >= 0;
        else valid = nativeUnsigned(field, UINT64_MAX);
        if (!valid) { *error = [NSString stringWithFormat:@"event.%@ has an invalid type or is outside its native integer range", key]; return nil; }
        [event setValue:field forKey:key];
    }
    id data = [event valueForKey:@"data"];
    if (![data isKindOfClass:NSData.class]) { *error = @"HPButtonEvent could not be securely archived"; return nil; }
    return data;
}

static id validatedArgument(id value, NSDictionary *spec, NSString **error) {
    NSString *type = spec[@"type"], *name = spec[@"name"];
    if ([type isEqual:@"button"]) return buttonData(value, error);
    if ([type isEqual:@"replay"]) return replayContents(value, error);
    Class cls = Nil;
    if ([type isEqual:@"string"]) cls = NSString.class;
    if ([type isEqual:@"array"]) cls = NSArray.class;
    if ([type isEqual:@"dictionary"]) cls = NSDictionary.class;
    if (cls) {
        if ([value isKindOfClass:cls]) return value;
    } else if ([value isKindOfClass:NSNumber.class]) {
        double number = [value doubleValue];
        if ([type isEqual:@"bool"] && nativeBoolean(value)) return value;
        if ([type isEqual:@"float"] && nativeNumber(value) && isfinite(number) && fabs(number) <= FLT_MAX) return value;
        if ([type isEqual:@"uint32"] && nativeUnsigned(value, UINT32_MAX)) return value;
        if ([type isEqual:@"int64"] && nativeSigned(value)) return value;
    }
    *error = [NSString stringWithFormat:@"%@ must be %@", name, type];
    return nil;
}

@interface VPHomePodDebugReply : NSObject
@property(nonatomic) id value;
@property(nonatomic) NSString *error;
@property(nonatomic) BOOL closed;
@end
@implementation VPHomePodDebugReply
@end

static NSDictionary *executeOperation(NSDictionary *spec, NSDictionary *arguments, id client, NSString **error) {
    SEL selector = NSSelectorFromString(spec[@"id"]);
    NSMethodSignature *signature = [client methodSignatureForSelector:selector];
    if (!matchesSignature(signature, spec)) { *error = @"SoundBoardServices method signature differs from the supported HomePod firmware"; return nil; }
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.selector = selector;
    invocation.target = client;
    // Transformed NSData arguments must stay alive until retainArguments takes
    // ownership, even when ARC shortens local lifetimes in an optimized build.
    __attribute__((objc_precise_lifetime)) NSMutableArray *objects = NSMutableArray.array;
    NSArray *parameters = spec[@"arguments"];
    for (NSUInteger i = 0; i < parameters.count; i++) {
        NSDictionary *parameter = parameters[i];
        id value = validatedArgument(arguments[parameter[@"name"]], parameter, error);
        if (!value) return nil;
        [objects addObject:value];
        NSString *type = parameter[@"type"];
        if ([type isEqual:@"float"]) { float scalar = [value floatValue]; [invocation setArgument:&scalar atIndex:i + 2]; }
        else if ([type isEqual:@"bool"]) { BOOL scalar = [value boolValue]; [invocation setArgument:&scalar atIndex:i + 2]; }
        else if ([type isEqual:@"uint32"]) { uint32_t scalar = [value unsignedIntValue]; [invocation setArgument:&scalar atIndex:i + 2]; }
        else if ([type isEqual:@"int64"]) { int64_t scalar = [value longLongValue]; [invocation setArgument:&scalar atIndex:i + 2]; }
        else { [invocation setArgument:&value atIndex:i + 2]; }
    }
    if ([spec[@"id"] isEqual:@"setVolume:"] && ([arguments[@"value"] doubleValue] < 0 || [arguments[@"value"] doubleValue] > 1)) {
        *error = @"Volume must be between 0 and 1"; return nil;
    }
    if ([spec[@"id"] isEqual:@"render:"]) {
        NSDictionary *options = arguments[@"options"];
        if (![options[@"animation"] isKindOfClass:NSString.class] || ![options[@"phase"] isKindOfClass:NSString.class]) {
            *error = @"Render options require animation and phase strings"; return nil;
        }
    }
    NSString *replyKind = spec[@"reply"];
    if ([replyKind isEqual:@"none"]) {
        [invocation retainArguments];
        [invocation invoke];
        // SBSDebugInterface has no completion for writes. Do not claim applied.
        return @{@"operation": spec[@"id"], @"submitted": @YES};
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    VPHomePodDebugReply *reply = [VPHomePodDebugReply new];
    void (^complete)(id) = ^(id value) {
        @synchronized (reply) {
            if (reply.closed) return;
            @try { reply.value = JSONValue(value, 0); }
            @catch (NSException *exception) { reply.error = exception.reason ?: exception.name; }
            reply.closed = YES;
        }
        dispatch_semaphore_signal(done);
    };
    id completion;
    if ([replyKind isEqual:@"float"]) completion = [^(float value) { complete(@(value)); } copy];
    else completion = [^(id value) { complete(value); } copy];
    [invocation setArgument:&completion atIndex:parameters.count + 2];
    [invocation retainArguments];
    [invocation invoke];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0) {
        @synchronized (reply) { reply.closed = YES; }
        *error = @"SoundBoard did not reply within 3 seconds. Check that it is running and vphoned has com.apple.debuginfo.soundboard.";
        return nil;
    }
    if (reply.error) { *error = reply.error; return nil; }
    return @{@"operation": spec[@"id"], @"value": reply.value ?: NSNull.null};
}

static NSDictionary *catalogResult(Class cls) {
    NSMutableArray *catalog = NSMutableArray.array;
    for (NSDictionary *spec in operations()) {
        NSMutableDictionary *entry = [spec mutableCopy];
        entry[@"available"] = @(matchesSignature([cls instanceMethodSignatureForSelector:NSSelectorFromString(spec[@"id"])], spec));
        [catalog addObject:entry];
    }
    // HomePodBuddyTypes.Feature / FeaturePhase raw-value switch
    // tables from SoundBoardFramework 24J361. The framework accepts
    // animation names as spaced words, then forms lowerCamelCase.
    return @{@"available": @YES, @"interface": @"SBSDebugInterface", @"operations": catalog,
        @"animations": @[@"none", @"lux thresholds", @"true tone", @"alarms", @"apple care", @"dropin", @"doorbell", @"factory reset", @"identify", @"intercom", @"now playing", @"proximity handoff", @"setup", @"siri", @"sae", @"siri sparkle", @"telephony", @"thermal overload", @"timers", @"bad boot args", @"crash blip", @"home kit sync", @"boot up", @"factory reset f w", @"low power"],
        @"phases": @[@"On", @"Off", @"AirDrop", @"Sysdiagnose", @"Reset Tone", @"Plus Tap", @"Minus Tap", @"Center Tap", @"Approach", @"Cancel", @"Complete", @"Audio Passcode", @"Manual Passcode", @"Post Passcode", @"Timed Out", @"Listening", @"Thinking", @"Presenting", @"Mute", @"Unmute"]};
}

char *vp_homepod_debug_copy_json(const char *operationName, const char *argumentsJSON) {
    @autoreleasepool {
        NSDictionary *result = nil;
        NSString *error = nil;
        @try {
            Class cls = debugClass();
            if (!cls) error = @"SoundBoard debugging is available only on a HomePod guest";
            else if (!operationName || strcmp(operationName, "catalog") == 0) {
                result = catalogResult(cls);
            } else {
                NSString *name = @(operationName);
                NSDictionary *spec = nil;
                for (NSDictionary *candidate in operations()) if ([candidate[@"id"] isEqual:name]) { spec = candidate; break; }
                if (!spec) error = @"Unknown SoundBoard debug operation";
                else {
                    NSData *data = [@(argumentsJSON ?: "{}") dataUsingEncoding:NSUTF8StringEncoding];
                    id arguments = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                    if (![arguments isKindOfClass:NSDictionary.class]) error = @"arguments must be a JSON object";
                    else {
                        // Keep the framework's XPC client alive after asynchronous writes.
                        static id client;
                        @synchronized (cls) {
                            if (!client) client = [cls new];
                            result = executeOperation(spec, arguments, client, &error);
                            if (error) client = nil; // Reopen after a dead SoundBoard connection.
                        }
                    }
                }
            }
        } @catch (NSException *exception) {
            error = [NSString stringWithFormat:@"SoundBoard debug operation failed: %@", exception.reason ?: exception.name];
        }
        NSDictionary *envelope = error ? @{@"ok": @NO, @"error": error} : @{@"ok": @YES, @"result": result ?: @{}};
        NSData *data = [NSJSONSerialization dataWithJSONObject:envelope options:NSJSONWritingSortedKeys error:NULL];
        return data ? strndup(data.bytes, data.length) : strdup("{\"ok\":false,\"error\":\"Could not encode SoundBoard reply\"}");
    }
}
