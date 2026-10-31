// HingeTests.m — the hinge angle transport, and the host-control events.
//
// On a Mac, IOKit answers IOCFSerialize, IOCFUnserializeWithSize and
// IOHIDEventCreateVendorDefinedEvent as the guest's does, so a host-control
// dictionary is checked to fit locationd's 256-byte limit, to read back the
// way locationd parses it, and to land in a vendor-defined event on the
// host-control usage. Where a function is absent the event checks are
// skipped; the transport checks always run.
#import "../Hinge/VPhoneHingeHID.h"
#import "../Hinge/VPhoneHingeState.h"
#include <assert.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        VPhoneHingeState state;
        NSDictionary *sample = @{
            @"enabled": @YES, @"angle": @90.0,
            @"sweep": @YES, @"duration_ms": @-1.0, @"profile": @0,
        };
        // The transport is a property list, including a real Boolean. Test
        // after serialization, as cfprefsd crosses a process boundary.
        NSData *wire = [NSPropertyListSerialization dataWithPropertyList:sample
                                     format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        id decoded = [NSPropertyListSerialization propertyListWithData:wire options:0 format:nil error:nil];
        assert(VPhoneHingeDecode(decoded, &state));
        assert(state.enabled && state.sweep && state.angle == 90.0);
        assert(state.durationMs == -1.0 && state.profile == 0);
        assert([VPhoneHingeEncode(state) isEqual:sample]);

        // An instant set carries no sweep.
        NSDictionary *instant = @{@"enabled": @YES, @"angle": @180.0};
        NSData *instantWire = [NSPropertyListSerialization dataWithPropertyList:instant
                                     format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        id instantRead = [NSPropertyListSerialization propertyListWithData:instantWire options:0 format:nil error:nil];
        assert(VPhoneHingeDecode(instantRead, &state));
        assert(state.enabled && !state.sweep && state.angle == 180.0 && state.profile == 0);

        NSMutableDictionary *closed = [sample mutableCopy];
        closed[@"angle"] = @0.0;
        assert(VPhoneHingeDecode(closed, &state) && state.angle == 0.0);
        closed[@"angle"] = @180.0;
        assert(VPhoneHingeDecode(closed, &state) && state.angle == 180.0);
        closed[@"duration_ms"] = @0.0;
        assert(VPhoneHingeDecode(closed, &state) && state.durationMs == 0.0);
        closed[@"profile"] = @1;
        assert(VPhoneHingeDecode(closed, &state) && state.profile == 1);
        NSMutableDictionary *disabled = [sample mutableCopy];
        disabled[@"enabled"] = @NO;
        assert(VPhoneHingeDecode(disabled, &state) && !state.enabled && state.angle == 90.0);

        for (id invalid in @[@YES, @"90", NSNull.null, @(NAN), @(INFINITY), @-0.5, @180.5]) {
            NSMutableDictionary *bad = [sample mutableCopy];
            bad[@"angle"] = invalid;
            assert(!VPhoneHingeDecode(bad, &state));
            assert(!state.enabled && state.angle == 0);
        }
        for (NSString *key in @[@"enabled", @"angle"]) {
            NSMutableDictionary *bad = [sample mutableCopy];
            [bad removeObjectForKey:key];
            assert(!VPhoneHingeDecode(bad, &state));
        }
        // The optional sweep fields reject malformed values: a profile that
        // is not one of the two, a boolean duration, an out-of-range
        // duration.
        for (id invalid in @[@2, @YES]) {
            NSMutableDictionary *bad = [sample mutableCopy];
            bad[@"profile"] = invalid;
            assert(!VPhoneHingeDecode(bad, &state));
        }
        for (id invalid in @[@YES, @-2, @10001]) {
            NSMutableDictionary *bad = [sample mutableCopy];
            bad[@"duration_ms"] = invalid;
            assert(!VPhoneHingeDecode(bad, &state));
        }
        // The host controls' orientation: 1–6, 0 leaving it, absent as 0;
        // encoded only when given, so an angle-only request round-trips.
        NSMutableDictionary *oriented = [sample mutableCopy];
        oriented[@"orientation"] = @3;
        assert(VPhoneHingeDecode(oriented, &state) && state.orientation == 3);
        assert([VPhoneHingeEncode(state) isEqual:oriented]);
        assert(VPhoneHingeDecode(sample, &state) && state.orientation == 0);
        for (id invalid in @[@7, @-1, @1.5, @YES, @"portrait"]) {
            NSMutableDictionary *bad = [sample mutableCopy];
            bad[@"orientation"] = invalid;
            assert(!VPhoneHingeDecode(bad, &state));
        }
        // A quiet update: a boolean, absent as no, encoded only when set.
        NSMutableDictionary *quiet = [sample mutableCopy];
        quiet[@"quiet"] = @YES;
        assert(VPhoneHingeDecode(quiet, &state) && state.quiet);
        assert([VPhoneHingeEncode(state) isEqual:quiet]);
        assert(VPhoneHingeDecode(sample, &state) && !state.quiet);
        for (id invalid in @[@1, @"yes"]) {
            NSMutableDictionary *bad = [sample mutableCopy];
            bad[@"quiet"] = invalid;
            assert(!VPhoneHingeDecode(bad, &state));
        }
        assert(!VPhoneHingeDecode(@"flat", &state));
        assert(VPhoneHingeInterval(nil) == 0);
        assert(VPhoneHingeInterval(@YES) == 0);
        assert(VPhoneHingeInterval(@0) == 0);
        assert(VPhoneHingeInterval(@(-5)) == 0);
        assert(VPhoneHingeInterval(@(4000.5)) == 5000);
        assert(VPhoneHingeInterval(@(16000)) == 16000);
        assert(VPhoneHingeInterval(@(2e9)) == 1000000);

        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL);
        VPhoneHingeSerializer serialize = (VPhoneHingeSerializer)dlsym(iokit, "IOCFSerialize");
        CFTypeRef (*unserialize)(const char *, size_t, CFAllocatorRef, uint32_t, CFStringRef *) =
            dlsym(iokit, "IOCFUnserializeWithSize");
        VPhoneHingeVendorEventFactory factory =
            (VPhoneHingeVendorEventFactory)dlsym(iokit, "IOHIDEventCreateVendorDefinedEvent");
        if (!serialize || !unserialize || !factory) {
            printf("IOKit host-control functions unavailable here; transport checks only\n");
            printf("hinge tests passed\n");
            return 0;
        }
        // The longest dictionaries the provider sends.
        NSArray *controls = @[
            @{@"source": @"hinge-slider-control", @"type": @"range", @"value": @180L},
            @{@"source": @"orientation-picker-control", @"type": @"enum", @"value": @"landscape-right"},
        ];
        for (NSDictionary *control in controls) {
            NSData *data = CFBridgingRelease(serialize((__bridge CFTypeRef)control, 0));
            assert(data.length > 0 && data.length <= VP_HOST_CONTROLS_MAX_DATA);
            id read = CFBridgingRelease(unserialize(data.bytes, data.length, NULL, 0, NULL));
            assert([read isEqual:control]);
            id event = CFBridgingRelease(factory(NULL, mach_absolute_time(), VP_HOST_CONTROLS_USAGE_PAGE,
                                                 VP_HOST_CONTROLS_USAGE, 0, data.bytes, (long)data.length, 0));
            assert(event);
            // The description is column-formatted; collapse the runs of
            // spaces before matching, so a wider label column still passes.
            NSArray *fields = [[event description] componentsSeparatedByCharactersInSet:
                               [NSCharacterSet whitespaceCharacterSet]];
            NSString *flat = [[fields filteredArrayUsingPredicate:
                               [NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "];
            assert([flat localizedCaseInsensitiveContainsString:@"VendorDefined"]);
        }
        printf("hinge tests passed\n");
        return 0;
    }
}
