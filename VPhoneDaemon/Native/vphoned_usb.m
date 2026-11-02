// vphoned_usb.m — the serial number the guest shows the host over USB.
//
// The host's usbmuxd names a device after its USB serial string, and that is
// what `idevice_id` lists and what a usbmuxd client connects by. The guest
// kernel fills it with the UDID it builds from `chip-id` and `unique-chip-id`;
// IOUSBDeviceFamily takes a replacement from any process holding
// `com.apple.private.usbdevice.setdescription`, which vphoned does. Taking the
// device off the bus and back makes the host enumerate it again and read the
// new string.
//
// lockdownd and remoted answer with the override through libmisfix; this is
// the third place the host learns the UDID, and the only one in the kernel.

#import <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <stdlib.h>

#include "VphonedNative.h"

typedef struct __IOUSBDeviceController *VPUSBControllerRef;
typedef struct __IOUSBDeviceDescription *VPUSBDescriptionRef;

static IOReturn (*pControllerCreate)(CFAllocatorRef, VPUSBControllerRef *);
static VPUSBDescriptionRef (*pDescriptionFromController)(CFAllocatorRef, VPUSBControllerRef);
static CFStringRef (*pGetSerial)(VPUSBDescriptionRef);
static void (*pSetSerial)(VPUSBDescriptionRef, CFStringRef);
static CFMutableDictionaryRef (*pGetInfo)(VPUSBDescriptionRef); // exported with a leading underscore
static IOReturn (*pSetDescription)(VPUSBControllerRef, VPUSBDescriptionRef);
static IOReturn (*pGoOffAndOnBus)(VPUSBControllerRef, uint32_t);

static char *failure(NSString *message) {
    return strdup(message.UTF8String);
}

static bool load_symbols(void) {
    static bool loaded;
    if (loaded) return true;
    void *ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!ioKit) return false;
    pControllerCreate = dlsym(ioKit, "IOUSBDeviceControllerCreate");
    pDescriptionFromController = dlsym(ioKit, "IOUSBDeviceDescriptionCreateFromController");
    pGetSerial = dlsym(ioKit, "IOUSBDeviceDescriptionGetSerialString");
    pSetSerial = dlsym(ioKit, "IOUSBDeviceDescriptionSetSerialString");
    pGetInfo = dlsym(ioKit, "_IOUSBDeviceDescriptionGetInfo");
    pSetDescription = dlsym(ioKit, "IOUSBDeviceControllerSetDescription");
    pGoOffAndOnBus = dlsym(ioKit, "IOUSBDeviceControllerGoOffAndOnBus");
    loaded = pControllerCreate && pDescriptionFromController && pGetSerial && pSetSerial && pGetInfo
        && pSetDescription && pGoOffAndOnBus;
    return loaded;
}

char *vp_usb_set_serial(const char *serial, bool force, bool *changed) {
    *changed = false;
    if (!load_symbols()) return failure(@"IOUSBDeviceController symbols are missing");

    VPUSBControllerRef controller = NULL;
    IOReturn status = pControllerCreate(kCFAllocatorDefault, &controller);
    if (status != kIOReturnSuccess || !controller)
        return failure([NSString stringWithFormat:@"IOUSBDeviceControllerCreate: 0x%08x", status]);

    char *error = NULL;
    VPUSBDescriptionRef description = pDescriptionFromController(kCFAllocatorDefault, controller);
    if (!description) {
        error = failure(@"The USB controller has no description to change");
    } else {
        NSString *wanted = @(serial);
        NSString *current = (__bridge NSString *)pGetSerial(description);
        if (force || ![current isEqualToString:wanted]) {
            pSetSerial(description, (__bridge CFStringRef)wanted);
            // The device already exists; the controller refuses a second
            // description that does not say it may replace the first.
            CFMutableDictionaryRef info = pGetInfo(description);
            if (info) CFDictionarySetValue(info, CFSTR("AllowMultipleCreates"), kCFBooleanTrue);
            status = pSetDescription(controller, description);
            if (status != kIOReturnSuccess) {
                error = failure([NSString stringWithFormat:@"IOUSBDeviceControllerSetDescription: 0x%08x", status]);
            } else {
                // Long enough for the host to see a disconnect rather than a glitch.
                status = pGoOffAndOnBus(controller, 1000);
                if (status != kIOReturnSuccess)
                    error = failure([NSString stringWithFormat:@"IOUSBDeviceControllerGoOffAndOnBus: 0x%08x", status]);
                else
                    *changed = true;
            }
        }
        CFRelease(description);
    }
    CFRelease(controller);
    return error;
}

static bool read_chosen(io_registry_entry_t chosen, CFStringRef key, void *value, size_t size) {
    CFTypeRef data = IORegistryEntryCreateCFProperty(chosen, key, kCFAllocatorDefault, 0);
    bool ok = data && CFGetTypeID(data) == CFDataGetTypeID() && (size_t)CFDataGetLength(data) >= size;
    if (ok) CFDataGetBytes(data, CFRangeMake(0, (CFIndex)size), value);
    if (data) CFRelease(data);
    return ok;
}

char *vp_usb_own_serial(void) {
    // The same inputs, in the same format, as the kernel's own serial and the
    // host's `udid-prediction.txt`.
    io_registry_entry_t chosen = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen");
    if (chosen == MACH_PORT_NULL) return NULL;
    uint32_t chipID = 0;
    uint64_t ecid = 0;
    bool ok = read_chosen(chosen, CFSTR("chip-id"), &chipID, sizeof(chipID))
        && read_chosen(chosen, CFSTR("unique-chip-id"), &ecid, sizeof(ecid));
    IOObjectRelease(chosen);
    if (!ok) return NULL;
    char *serial = NULL;
    asprintf(&serial, "%08X%016llX", chipID, ecid);
    return serial;
}
