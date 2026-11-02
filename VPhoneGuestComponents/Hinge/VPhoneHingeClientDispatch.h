#pragma once
#import "VPhoneHingeHID.h"
#import "VPhoneHingeState.h"
#include <mach/mach.h>
#include <math.h>

// MARK: - Hinge values a HID client dispatches
//
// WebDriverAgent's `POST /wda/device/hingeAngle` builds DeviceHub's slider
// dictionary itself, wraps it in a host-control vendor event and sends it with
// IOHIDEventSystemClientDispatchEvent. backboardd's HID server drops it:
// `_io_hideventsystem_dispatch_event` needs the client's
// com.apple.private.hid.client.event-dispatch entitlement, and a test runner
// has none. Even dispatched, no service would carry it to locationd's relay,
// which reads the host controls from their services. The hinge takes such a
// value and dispatches it on its own host-control service, where it reaches
// the relay and vphoned as a DeviceHub value does.

// The server function `io_hideventsystem_dispatch_event` lands in, exported by
// IOKit: the client's port, then the out-of-line buffer holding the event's
// data as a CFData in a binary property list (IOKit's _IOHIDCreateBinaryData).
// It frees the buffer as it reads it, and only then refuses an unentitled
// client.
typedef kern_return_t (*VPhoneHingeDispatchEventServer)(mach_port_t, vm_offset_t, mach_msg_type_number_t);

// An event's data is a few hundred bytes; a host-control payload at most 256.
#define VP_HINGE_CLIENT_EVENT_MAX_DATA 4096

// IOKit's readers, resolved by the caller. The vendor payload is IOKit
// binary-serialized, as DeviceHub's is. A client sends the event in
// IOHIDEventCreateDataInternal's form and the server reads it with
// IOHIDEventCreateWithDataInternal; the public pair passes another format
// flag.
typedef struct {
    CFTypeRef (*unserializeBinary)(const char *, size_t, CFAllocatorRef, CFOptionFlags, CFStringRef *);
    CFTypeRef (*createEventWithData)(CFAllocatorRef, CFDataRef);
    uint32_t (*eventType)(CFTypeRef);
    CFIndex (*eventInteger)(CFTypeRef, uint32_t);
    uint8_t *(*eventData)(CFTypeRef, uint32_t);
} VPhoneHingeEventReader;

/// The client's event when it is DeviceHub's hinge slider: a host-control
/// vendor event whose dictionary names the VM provider, the slider, and a
/// value of 0–180 degrees. Anything else is nil and left to the server.
static inline id VPhoneHingeClientSliderEvent(NSData *eventData, const VPhoneHingeEventReader *reader) {
    id serialized = [NSPropertyListSerialization propertyListWithData:eventData options:0 format:NULL error:NULL];
    if (![serialized isKindOfClass:NSData.class])
        return nil;
    id event = CFBridgingRelease(reader->createEventWithData(kCFAllocatorDefault, (__bridge CFDataRef)serialized));
    // kIOHIDEventTypeVendorDefined; its fields are the type << 16 plus usage
    // page 0, usage 1, version 2, data length 3, data 4.
    static const uint32_t vendorDefined = 1, field = vendorDefined << 16;
    CFTypeRef raw = (__bridge CFTypeRef)event;
    if (!event || reader->eventType(raw) != vendorDefined ||
        reader->eventInteger(raw, field) != VP_HOST_CONTROLS_USAGE_PAGE ||
        reader->eventInteger(raw, field | 1) != VP_HOST_CONTROLS_USAGE)
        return nil;
    CFIndex length = reader->eventInteger(raw, field | 3);
    uint8_t *data = reader->eventData(raw, field | 4);
    if (!data || length <= 0 || length > VP_HOST_CONTROLS_MAX_DATA)
        return nil;
    NSDictionary *control = CFBridgingRelease(reader->unserializeBinary((const char *)data, (size_t)length,
                                                                        kCFAllocatorDefault, 0, NULL));
    if (![control isKindOfClass:NSDictionary.class] ||
        ![control[@"provider"] isEqual:@"com.apple.Virtualization.VirtualMachines"] ||
        ![control[@"source"] isEqual:@"hinge-slider-control"] || ![control[@"type"] isEqual:@"range"] ||
        !VPhoneHingeNumber(control[@"value"]))
        return nil;
    double degrees = [control[@"value"] doubleValue];
    return isfinite(degrees) && degrees >= 0 && degrees <= 180 ? event : nil;
}
