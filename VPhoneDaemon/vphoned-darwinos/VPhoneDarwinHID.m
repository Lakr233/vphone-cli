#import "VPhoneDarwinHID.h"

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <string.h>

typedef void *VPhoneHIDClientRef;
typedef void *VPhoneHIDEventRef;

static VPhoneHIDClientRef (*pCreate)(CFAllocatorRef);
static VPhoneHIDEventRef (*pKeyboard)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, boolean_t, uint32_t);
static void (*pSetInteger)(VPhoneHIDEventRef, uint32_t, CFIndex);
static void (*pSetSender)(VPhoneHIDEventRef, uint64_t);
static void (*pDispatch)(VPhoneHIDClientRef, VPhoneHIDEventRef);

static VPhoneHIDClientRef gClient;
static dispatch_queue_t gQueue;
static dispatch_semaphore_t gAdmission;
static uint64_t gPressTicks;
static const char *gFailure = "HID bridge is unavailable";

bool vp_darwin_hid_available(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Keep this handle open: the resolved function pointers live for the process.
        void *ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL);
        if (!ioKit) {
            gFailure = "Could not load IOKit for HID dispatch";
            return;
        }
#define VP_HID_RESOLVE(pointer, name) \
        if (!(pointer = dlsym(ioKit, name))) { gFailure = "Missing HID symbol: " name; return; }
        VP_HID_RESOLVE(pCreate, "IOHIDEventSystemClientCreate")
        VP_HID_RESOLVE(pKeyboard, "IOHIDEventCreateKeyboardEvent")
        VP_HID_RESOLVE(pSetInteger, "IOHIDEventSetIntegerValue")
        VP_HID_RESOLVE(pSetSender, "IOHIDEventSetSenderID")
        VP_HID_RESOLVE(pDispatch, "IOHIDEventSystemClientDispatchEvent")
#undef VP_HID_RESOLVE
        mach_timebase_info_data_t timebase;
        if (mach_timebase_info(&timebase) != KERN_SUCCESS || !timebase.numer || !timebase.denom) {
            gFailure = "Could not determine the HID event clock";
            return;
        }
        gPressTicks = MAX(1ull, 50000000ull * timebase.denom / timebase.numer);
        gClient = pCreate(kCFAllocatorDefault);
        if (!gClient) {
            gFailure = "IOHIDEventSystemClientCreate returned NULL";
            return;
        }
        gQueue = dispatch_queue_create("com.vphone.vphoned.darwinos.hid", DISPATCH_QUEUE_SERIAL);
        // Bound concurrent RPC admission as well as the two-event press duration.
        gAdmission = dispatch_semaphore_create(8);
    });
    return gClient != NULL;
}

static bool fail(char **error, const char *message) {
    if (error) *error = strdup(message);
    return false;
}

static VPhoneHIDEventRef keyboard_event(uint16_t page, uint16_t usage, bool down,
                                      bool longPress, uint64_t timestamp) {
    VPhoneHIDEventRef event = pKeyboard(kCFAllocatorDefault, timestamp, page, usage, down, 0);
    if (event) {
        // Match Native/vphoned_touch.m and IcliKit's built-in keyboard sender.
        pSetInteger(event, 4, 1);
        pSetInteger(event, (3u << 16) | 5u, longPress ? 1 : 0);
        pSetSender(event, 0x8000000817319372);
    }
    return event;
}

bool vp_darwin_hid_submit(uint16_t page, uint16_t usage, int action, bool long_press, char **error) {
    if (error) *error = NULL;
    if (action < -1 || action > 1 || (action == -1 && long_press)) {
        return fail(error, "Invalid HID action; long_press requires explicit down or up");
    }
    if (!vp_darwin_hid_available()) return fail(error, gFailure);
    if (dispatch_semaphore_wait(gAdmission, DISPATCH_TIME_NOW) != 0) {
        return fail(error, "HID submission queue is full");
    }
    __block bool submitted = false;
    dispatch_sync(gQueue, ^{
        uint64_t timestamp = mach_absolute_time();
        VPhoneHIDEventRef first = keyboard_event(page, usage, action != 0, long_press, timestamp);
        VPhoneHIDEventRef release = action == -1
            ? keyboard_event(page, usage, false, false, timestamp + gPressTicks) : NULL;
        // Allocate both sides before a press so allocation failure never submits a lone down.
        if (first && (action != -1 || release)) {
            pDispatch(gClient, first);
            if (release) {
                uint64_t deadline = timestamp + gPressTicks;
                while (mach_absolute_time() < deadline) mach_wait_until(deadline);
                pDispatch(gClient, release);
            }
            submitted = true;
        }
        if (release) CFRelease(release);
        if (first) CFRelease(first);
    });
    dispatch_semaphore_signal(gAdmission);
    return submitted || fail(error, "IOHIDEventCreateKeyboardEvent returned NULL");
}
