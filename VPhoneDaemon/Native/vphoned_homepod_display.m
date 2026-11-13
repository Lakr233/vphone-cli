#import "Include/VphonedNative.h"
#import "vphoned_homepod_report.h"
#import <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <pthread.h>

// IOHIDUserDevice is exported by iOS IOKit, but not declared by its SDK.
// Signatures follow Apple's IOHIDFamily/IOHIDLib/IOHIDUserDevice.h.
typedef struct __IOHIDUserDevice *VPHomePodHIDDeviceRef;
typedef IOReturn (*VPHomePodSetReportCallback)(void *, int, uint32_t, uint8_t *, CFIndex);
static VPHomePodHIDDeviceRef (*VPHomePodCreate)(CFAllocatorRef, CFDictionaryRef, IOOptionBits);
static void (*VPHomePodRegisterSetReport)(VPHomePodHIDDeviceRef, VPHomePodSetReportCallback, void *);
static void (*VPHomePodSchedule)(VPHomePodHIDDeviceRef, dispatch_queue_t);

static pthread_mutex_t VPHomePodLock = PTHREAD_MUTEX_INITIALIZER;
static VPHomePodHIDDeviceRef VPHomePodDevice;
static dispatch_queue_t VPHomePodQueue;
static NSDictionary *VPHomePodGeometry;
static NSData *VPHomePodFrame;
static NSString *VPHomePodState = @"unconfigured";
static NSString *VPHomePodError;
static NSUInteger VPHomePodLEDCount;
static NSUInteger VPHomePodDisplayCount;
static uint32_t VPHomePodBitDepth;
static uint32_t VPHomePodHardwareVersion;
static uint64_t VPHomePodFramesReceived;
static uint64_t VPHomePodRejectedReports;
static uint32_t VPHomePodLastReportID;
static CFIndex VPHomePodLastReportLength;
static BOOL VPHomePodConfigured;

static void VPHomePodSetFailure(NSString *message) {
    pthread_mutex_lock(&VPHomePodLock);
    VPHomePodState = @"failed";
    VPHomePodError = message;
    pthread_mutex_unlock(&VPHomePodLock);
    NSLog(@"vphoned: HomePod display: %@", message);
}

static uint32_t VPHomePodConfigurationWord(NSDictionary *configuration, NSString *key) {
    NSData *data = configuration[key];
    if (![data isKindOfClass:NSData.class] || data.length != 4) return 0;
    return VPHomePodRead32(data.bytes);
}

static NSArray *VPHomePodCoordinates(NSData *data, BOOL fixedPoint) {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:data.length / 4];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger index = 0; index < data.length; index += 4) {
        uint32_t word = VPHomePodRead32(bytes + index);
        [result addObject:fixedPoint ? @((double)word / 65536.0) : @(word)];
    }
    return result;
}

static IOReturn VPHomePodReceiveReport(void *context, int type, uint32_t reportID,
                                     uint8_t *report, CFIndex length) {
    (void)context;
    @autoreleasepool {
        pthread_mutex_lock(&VPHomePodLock);
        VPHomePodLastReportID = reportID;
        VPHomePodLastReportLength = length;
        // The output report includes its report ID in IOHIDDeviceSetReport.
        // Reject truncated or unexpected reports without disturbing the last frame.
        if (type != 1 || reportID != 2 || length < 0 ||
            !VPHomePodValidFrame(report, (size_t)length, VPHomePodLEDCount, VPHomePodDisplayCount)) {
            VPHomePodRejectedReports++;
            pthread_mutex_unlock(&VPHomePodLock);
            return kIOReturnBadArgument;
        }
        VPHomePodFrame = [NSData dataWithBytes:report length:(NSUInteger)length];
        VPHomePodFramesReceived++;
        VPHomePodState = @"receiving";
        pthread_mutex_unlock(&VPHomePodLock);
        return kIOReturnSuccess;
    }
}

void vp_homepod_display_start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = @"/usr/share/vphone/HomePodDisplay.plist";
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return;
        VPHomePodConfigured = YES;
        NSDictionary *configuration = [NSDictionary dictionaryWithContentsOfFile:path];
        NSData *x = configuration[@"MDXCoords"];
        NSData *y = configuration[@"MDYCoords"];
        NSData *rings = configuration[@"MDRingCoords"];
        uint32_t bitDepth = VPHomePodConfigurationWord(configuration, @"MDBitDepth");
        uint32_t hardwareVersion = VPHomePodConfigurationWord(configuration, @"MDHWVersion");
        if (![x isKindOfClass:NSData.class] || x.length == 0 || x.length % 4 != 0 ||
            ![y isKindOfClass:NSData.class] || y.length != x.length ||
            ![rings isKindOfClass:NSData.class] || rings.length != x.length ||
            !bitDepth || bitDepth > 16 || !hardwareVersion || x.length / 4 > 4096) {
            VPHomePodSetFailure(@"Invalid device tree display geometry");
            return;
        }
        VPHomePodLEDCount = x.length / 4;
        VPHomePodDisplayCount = hardwareVersion > 2 ? 2 : 1;
        VPHomePodBitDepth = bitDepth;
        VPHomePodHardwareVersion = hardwareVersion;
        VPHomePodGeometry = @{@"x": VPHomePodCoordinates(x, YES), @"y": VPHomePodCoordinates(y, YES),
                             @"rings": VPHomePodCoordinates(rings, NO)};
        VPHomePodFrame = [NSMutableData dataWithLength:VPHomePodFrameSize(VPHomePodLEDCount, VPHomePodDisplayCount)];
        void *ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (ioKit) {
            VPHomePodCreate = dlsym(ioKit, "IOHIDUserDeviceCreateWithOptions");
            VPHomePodRegisterSetReport = dlsym(ioKit, "IOHIDUserDeviceRegisterSetReportCallback");
            VPHomePodSchedule = dlsym(ioKit, "IOHIDUserDeviceScheduleWithDispatchQueue");
        }
        if (!VPHomePodCreate || !VPHomePodRegisterSetReport || !VPHomePodSchedule) {
            VPHomePodSetFailure(@"IOHIDUserDevice APIs are unavailable");
            return;
        }
        // Consumer Control (12, 1) is MiniDisplay's matching dictionary. Each
        // report's payload is opaque to HID; MiniDisplay owns the layout.
        NSUInteger payloadLength = VPHomePodFrameSize(VPHomePodLEDCount, VPHomePodDisplayCount) - 1;
        const uint8_t descriptor[] = {
            0x05, 0x0c, 0x09, 0x01, 0xa1, 0x01, 0x85, 0x02,
            0x06, 0x00, 0xff, 0x09, 0x01, 0x15, 0x00, 0x26, 0xff, 0x00,
            0x75, 0x08, 0x96, (uint8_t)payloadLength, (uint8_t)(payloadLength >> 8), 0x91, 0x02, 0xc0,
        };
        NSDictionary *properties = @{
            @"ReportDescriptor": [NSData dataWithBytes:descriptor length:sizeof(descriptor)],
            @"Product": @"VPhone HomePod mini Top Cap",
            @"Manufacturer": @"VPhone", @"Transport": @"Virtual", @"VendorID": @0x05ac,
            @"ProductID": @0x0001, @"PhysicalDeviceUniqueID": @"vphone-homepod-mini-display",
            @"DeviceUsagePage": @12, @"DeviceUsage": @1,
            @"MDHWVersion": @(hardwareVersion),
            @"MDXCoords": x, @"MDYCoords": y, @"MDRingCoords": rings, @"MDBitDepth": @(bitDepth),
        };
        VPHomePodQueue = dispatch_queue_create("vphoned.homepod-display.hid", DISPATCH_QUEUE_SERIAL);
        // StartWhenScheduled keeps clients from sending their first frame before
        // the set-report callback is registered and its queue is listening.
        VPHomePodDevice = VPHomePodCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)properties, 1 << 0);
        if (!VPHomePodDevice) {
            VPHomePodSetFailure(@"Could not create the virtual MiniDisplay HID device");
            return;
        }
        VPHomePodRegisterSetReport(VPHomePodDevice, VPHomePodReceiveReport, NULL);
        VPHomePodSchedule(VPHomePodDevice, VPHomePodQueue);
        pthread_mutex_lock(&VPHomePodLock);
        if (!VPHomePodFramesReceived) VPHomePodState = @"waiting_for_guest";
        pthread_mutex_unlock(&VPHomePodLock);
        NSLog(@"vphoned: HomePod mini display HID device ready (%lu LEDs, %u-bit, hardware %u)",
              (unsigned long)VPHomePodLEDCount, bitDepth, hardwareVersion);
    });
}

bool vp_homepod_display_is_configured(void) { return VPHomePodConfigured; }

char *vp_homepod_display_copy_json(void) {
    @autoreleasepool {
        pthread_mutex_lock(&VPHomePodLock);
        NSData *frame = VPHomePodFrame;
        NSMutableDictionary *result = [@{
            @"available": VPHomePodDevice ? @YES : @NO, @"configured": @(VPHomePodConfigured),
            @"state": VPHomePodState, @"message": VPHomePodError ?: (id)NSNull.null,
            @"error": VPHomePodError ?: (id)NSNull.null,
            @"hardware_version": @(VPHomePodHardwareVersion), @"bit_depth": @(VPHomePodBitDepth),
            @"report_bit_depth": @16,
            @"display_count": @(VPHomePodDisplayCount),
            @"generation": @(VPHomePodFramesReceived), @"frames_received": @(VPHomePodFramesReceived),
            @"rejected_reports": @(VPHomePodRejectedReports), @"last_report_id": @(VPHomePodLastReportID),
            @"last_report_length": @(VPHomePodLastReportLength),
            @"geometry": VPHomePodGeometry ?: @{},
        } mutableCopy];
        pthread_mutex_unlock(&VPHomePodLock);
        NSMutableArray *displays = [NSMutableArray arrayWithCapacity:VPHomePodDisplayCount];
        if (frame.length == VPHomePodFrameSize(VPHomePodLEDCount, VPHomePodDisplayCount)) {
            const uint8_t *bytes = frame.bytes;
            for (NSUInteger display = 0; display < VPHomePodDisplayCount; display++) {
                const uint8_t *channels = bytes + 9 + display * (4 + VPHomePodLEDCount * 6);
                NSMutableArray *pixels = [NSMutableArray arrayWithCapacity:VPHomePodLEDCount];
                for (NSUInteger index = 0; index < VPHomePodLEDCount; index++) {
                    const uint8_t *rgb = channels + 4 + index * 6;
                    [pixels addObject:@[@(VPHomePodReadChannel(rgb)),
                                        @(VPHomePodReadChannel(rgb + 2)),
                                        @(VPHomePodReadChannel(rgb + 4))]];
                }
                [displays addObject:@{@"pixels": pixels,
                                     @"plus": @(VPHomePodReadChannel(channels)),
                                     @"minus": @(VPHomePodReadChannel(channels + 2))}];
            }
            result[@"frame_timestamp"] = @(VPHomePodRead64(bytes + 1));
        }
        result[@"displays"] = displays;
        result[@"pixels"] = displays.firstObject[@"pixels"] ?: @[];
        result[@"plus"] = displays.firstObject[@"plus"] ?: @0;
        result[@"minus"] = displays.firstObject[@"minus"] ?: @0;
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
        if (!json) return NULL;
        return strndup(json.bytes, json.length);
    }
}
