#import "Include/VphonedNative.h"

#include <dlfcn.h>
#include <unistd.h>

// 20G81 backboardd routes accessibility digitizer events through its main
// touchscreen. The VZ touchscreen's newer DriverKit driver cannot start on
// this base, leaving that service absent. Register a HID touchscreen so the
// normal, unchanged touch/edge/multi-finger injection has a native route.
// No reports are synthesized here; the device exists for vphoned's lifetime.
static CFTypeRef gIOS16Touchscreen;
static const uint8_t touchscreenDescriptor[] = {
    0x05, 0x0d, 0x09, 0x04, 0xa1, 0x01, 0x85, 0x01, // Touchscreen, report 1.
    0x09, 0x22, 0xa1, 0x02,                         // Finger.
    0x09, 0x42, 0x09, 0x32, 0x15, 0x00, 0x25, 0x01,
    0x75, 0x01, 0x95, 0x02, 0x81, 0x02,             // Tip switch and range.
    0x75, 0x06, 0x95, 0x01, 0x81, 0x03,             // Padding.
    0x09, 0x51, 0x15, 0x00, 0x25, 0x7f,
    0x75, 0x08, 0x95, 0x01, 0x81, 0x02,             // Contact identifier.
    0x05, 0x01, 0x09, 0x30, 0x09, 0x31,
    0x15, 0x00, 0x26, 0xff, 0x7f,
    0x75, 0x10, 0x95, 0x02, 0x81, 0x02, 0xc0,       // Absolute X and Y.
    0x05, 0x0d, 0x09, 0x54, 0x15, 0x00, 0x25, 0x01,
    0x75, 0x08, 0x95, 0x01, 0x81, 0x02, 0xc0,       // Contact count.
};

void vp_ios16_touchscreen_start(void) {
    NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
    if (version.majorVersion != 16 || version.minorVersion != 6 ||
        access("/usr/lib/vphone-ios16-touchscreen", F_OK) != 0) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        void *(*createDevice)(CFAllocatorRef, CFDictionaryRef) = ioKit ? dlsym(ioKit, "IOHIDUserDeviceCreate") : NULL;
        void *(*createClient)(CFAllocatorRef) = ioKit ? dlsym(ioKit, "IOHIDEventSystemClientCreate") : NULL;
        CFArrayRef (*copyServices)(const void *) = ioKit ? dlsym(ioKit, "IOHIDEventSystemClientCopyServices") : NULL;
        CFTypeRef (*copyProperty)(const void *, CFStringRef) = ioKit ? dlsym(ioKit, "IOHIDServiceClientCopyProperty") : NULL;
        if (!createDevice || !createClient || !copyServices || !copyProperty) return;
        void *client = createClient(kCFAllocatorDefault);
        if (!client) return;
        CFArrayRef services = copyServices(client);
        BOOL alreadyPresent = NO;
        for (CFIndex index = 0; services && index < CFArrayGetCount(services); index++) {
            const void *service = CFArrayGetValueAtIndex(services, index);
            NSNumber *page = CFBridgingRelease(copyProperty(service, CFSTR("PrimaryUsagePage")));
            NSNumber *usage = CFBridgingRelease(copyProperty(service, CFSTR("PrimaryUsage")));
            if ([page isKindOfClass:NSNumber.class] && [usage isKindOfClass:NSNumber.class] &&
                page.unsignedIntValue == 13 && usage.unsignedIntValue == 4) alreadyPresent = YES;
        }
        if (services) CFRelease(services);
        CFRelease(client);
        if (alreadyPresent) return;
        NSDictionary *properties = @{
            @"ReportDescriptor": [NSData dataWithBytes:touchscreenDescriptor length:sizeof(touchscreenDescriptor)],
            @"VendorID": @0x05ac, @"ProductID": @0x7651,
            @"Product": @"vphone iOS 16 lab touchscreen",
            @"SerialNumber": [NSString stringWithFormat:@"%d", getpid()],
            @"Transport": @"USB", @"PrimaryUsagePage": @13, @"PrimaryUsage": @4,
            @"Built-In": @YES, @"DisplayIntegrated": @YES,
        };
        gIOS16Touchscreen = createDevice(kCFAllocatorDefault, (__bridge CFDictionaryRef)properties);
        NSLog(@"vphoned: iOS 16 lab touchscreen %@", gIOS16Touchscreen ? @"registered" : @"unavailable");
    });
}
