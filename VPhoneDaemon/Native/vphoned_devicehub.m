/*
 * vphoned_devicehub — the controls Xcode's DeviceHub sends a virtual iPhone
 * Duo.
 *
 * DeviceHub's V68 controls (the closed / book / open buttons and their hinge
 * animation, and the orientation picker) send a vendor-defined HID report
 * (usage page 0xFF61, usage 0x5B) through CoreDevice. The DDI's dtuhidd
 * replays it from a virtual service it creates, "CoreDevice avpCustom", as a
 * vendor-defined event whose data is an IOKit binary-serialized dictionary:
 *
 *   provider = com.apple.Virtualization.VirtualMachines
 *   source   = hinge-slider-control,       type = range, value = degrees
 *   source   = orientation-picker-control, type = enum,  value = portrait, ...
 *
 * One button press is a run of hinge values as DeviceHub animates from the
 * current angle to the target. vphoned monitors the HID event system for
 * these events and hands each dictionary to Swift.
 */

#import "Include/VphonedNative.h"
#import "../../VPhoneGuestComponents/Hinge/VPhoneHingeState.h"

#include <dlfcn.h>
#include <string.h>
#include <sys/sysctl.h>

typedef struct __IOHIDEventSystemClient *VPHIDEventSystemClientRef;
typedef struct __IOHIDEvent *VPHIDEventRef;
typedef void (*VPHIDEventCallback)(void *target, void *refcon, void *sender, VPHIDEventRef event);

static uint32_t (*vpEventType)(VPHIDEventRef);
static CFIndex (*vpEventInteger)(VPHIDEventRef, uint32_t);
static uint8_t *(*vpEventData)(VPHIDEventRef, uint32_t);
static CFTypeRef (*vpUnserializeBinary)(const char *, size_t, CFAllocatorRef, CFOptionFlags, CFStringRef *);
static void (^vpControlHandler)(NSDictionary *);

static void vpDeviceHubEvent(void *target, void *refcon, void *sender, VPHIDEventRef event) {
    // kIOHIDEventTypeVendorDefined; its fields are the type << 16 plus usage
    // page 0, usage 1, version 2, data length 3, data 4.
    static const uint32_t vendorDefined = 1, field = vendorDefined << 16;
    if (!event || vpEventType(event) != vendorDefined || vpEventInteger(event, field) != 0xff61 ||
        vpEventInteger(event, field | 1) != 0x5b)
        return;
    CFIndex length = vpEventInteger(event, field | 3);
    uint8_t *data = vpEventData(event, field | 4);
    if (!data || length <= 0) return;
    @autoreleasepool {
        id control = CFBridgingRelease(vpUnserializeBinary((const char *)data, (size_t)length, kCFAllocatorDefault, 0, NULL));
        if ([control isKindOfClass:NSDictionary.class] &&
            [control[@"provider"] isEqual:@"com.apple.Virtualization.VirtualMachines"])
            vpControlHandler(control);
    }
}

bool vp_devicehub_controls_start(void (^handler)(NSDictionary *control)) {
    char product[64] = {0};
    size_t size = sizeof(product);
    if (sysctlbyname("hw.machine", product, &size, NULL, 0) != 0 || strcmp(product, "iPhone19,4") != 0) return false;
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    VPHIDEventSystemClientRef (*create)(CFAllocatorRef, int, CFDictionaryRef) =
        iokit ? dlsym(iokit, "IOHIDEventSystemClientCreateWithType") : NULL;
    void (*registerCallback)(VPHIDEventSystemClientRef, VPHIDEventCallback, void *, void *) =
        iokit ? dlsym(iokit, "IOHIDEventSystemClientRegisterEventCallback") : NULL;
    void (*schedule)(VPHIDEventSystemClientRef, dispatch_queue_t) =
        iokit ? dlsym(iokit, "IOHIDEventSystemClientScheduleWithDispatchQueue") : NULL;
    vpEventType = iokit ? dlsym(iokit, "IOHIDEventGetType") : NULL;
    vpEventInteger = iokit ? dlsym(iokit, "IOHIDEventGetIntegerValue") : NULL;
    vpEventData = iokit ? dlsym(iokit, "IOHIDEventGetDataValue") : NULL;
    vpUnserializeBinary = iokit ? dlsym(iokit, "IOCFUnserializeBinary") : NULL;
    if (!create || !registerCallback || !schedule || !vpEventType || !vpEventInteger || !vpEventData ||
        !vpUnserializeBinary)
        return false;
    // A monitor client (type 1), unmatched: dtuhidd creates the avpCustom
    // service only when the first report arrives, and a client matched by its
    // usage did not see that service's events.
    VPHIDEventSystemClientRef client = create(kCFAllocatorDefault, 1, NULL);
    if (!client) return false;
    vpControlHandler = [handler copy];
    registerCallback(client, vpDeviceHubEvent, NULL, NULL);
    schedule(client, dispatch_queue_create("vphoned.devicehub-controls", DISPATCH_QUEUE_SERIAL));
    return true;
}

void vp_device_orientation_publish(int deviceOrientation) {
    // Beside the virtual hinge's newest sample, where the device state
    // stand-in in dtdeviceinfod reads the hinge.
    CFPreferencesSetValue(CFSTR("VPhoneDeviceOrientation"), (__bridge CFNumberRef)@(deviceOrientation),
                          CFSTR("com.apple.backboardd"), CFSTR("mobile"), kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR("com.apple.backboardd"), CFSTR("mobile"), kCFPreferencesAnyHost);
}

void vp_hinge_reading_publish(double angleDegrees, int hingeState) {
    // The sample libvphonehinge writes as the hinge moves (phase 2, between
    // the ends of a sweep); the hinge itself and its configuration are left
    // alone.
    NSDictionary *latest = @{
        @"angle": @(angleDegrees), @"mechanical_angle": @(angleDegrees), @"velocity": @0,
        @"state": @(hingeState), @"event_phase": @2, @"timestamp": @(NSDate.date.timeIntervalSince1970),
    };
    CFPreferencesSetValue(CFSTR(VP_HINGE_LATEST), (__bridge CFDictionaryRef)latest, CFSTR(VP_HINGE_DOMAIN),
                          CFSTR("mobile"), kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR(VP_HINGE_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
}
