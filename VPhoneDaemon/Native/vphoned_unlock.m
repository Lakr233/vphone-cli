/*
 * vphoned_unlock — turn the guest display on.
 *
 * SpringBoardServices' SBSUndimScreen lights the display without the toggle a
 * power-key press has. It is the same call icli's `wake` uses, and needs no
 * entitlement. Getting past the Lock Screen itself is a Home press, driven
 * from Swift (GuestScreenUnlock).
 *
 * The symbol is resolved at run time, so a base without it still starts and
 * the call reports false instead.
 */

#import "Include/VphonedNative.h"

#include <dlfcn.h>
#include <notify.h>

bool vp_screen_undim(void) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
    });
    void (*undim)(void) = handle ? dlsym(handle, "SBSUndimScreen") : NULL;
    if (!undim) return false;
    undim();
    return true;
}

// MARK: - Tap to wake

/*
 * A phone's touch controller reports a tap on a dark screen as a wake gesture,
 * and SpringBoard lights the Lock Screen for it. The VM's touchscreen has no
 * such gesture, so a tap there did nothing: backboardd drops touches while
 * the backlight is off. While SpringBoard reports the screen blanked, a
 * monitor client watches the HID event system for a digitizer touch and
 * reports it to `touched`, which lights the screen (GuestScreenUnlock).
 *
 * The client exists only while the screen is dark: SpringBoard posting that
 * the screen is lit again ends it. A canceled client cannot be scheduled
 * again, so each dark period gets its own.
 */

typedef void *VPHIDClientRef;
typedef void *VPHIDEventRef;
typedef void (*VPHIDEventCallback)(void *target, void *refcon, void *sender, VPHIDEventRef event);

// kIOHIDEventSystemClientTypeMonitor.
#define VP_HID_CLIENT_MONITOR 1
#define VP_HID_EVENT_DIGITIZER 11u
// kIOHIDEventFieldDigitizerTouch: (kIOHIDEventTypeDigitizer << 16) | 9.
#define VP_FIELD_DIGITIZER_TOUCH ((VP_HID_EVENT_DIGITIZER << 16) | 9u)

static VPHIDClientRef (*pCreateWithType)(CFAllocatorRef, int, CFDictionaryRef);
static void (*pRegisterCallback)(VPHIDClientRef, VPHIDEventCallback, void *, void *);
static void (*pSchedule)(VPHIDClientRef, dispatch_queue_t);
static void (*pUnschedule)(VPHIDClientRef, dispatch_queue_t);
static uint32_t (*pEventType)(VPHIDEventRef);
static long (*pEventInteger)(VPHIDEventRef, uint32_t);

static dispatch_queue_t gTapWakeQueue;
static int gBlankedToken;
// Owned by gTapWakeQueue.
static VPHIDClientRef gTapWakeMonitor;
static uint64_t gTapWakeLast;
static void (*gTapWakeTouched)(void);

static void stop_monitor(void) {
    if (!gTapWakeMonitor) return;
    pUnschedule(gTapWakeMonitor, gTapWakeQueue);
    CFRelease(gTapWakeMonitor);
    gTapWakeMonitor = NULL;
}

static void tap_wake_event(void *target, void *refcon, void *sender, VPHIDEventRef event) {
    (void)target;
    (void)refcon;
    (void)sender;
    if (pEventType(event) != VP_HID_EVENT_DIGITIZER || pEventInteger(event, VP_FIELD_DIGITIZER_TOUCH) == 0) return;
    // A finger that stays down reports touch on every move. One wake per half
    // second is enough, and a later tap tries again if the screen stayed dark.
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (now - gTapWakeLast < 500 * NSEC_PER_MSEC) return;
    gTapWakeLast = now;
    gTapWakeTouched();
}

static void update_monitor(void) {
    uint64_t blanked = 0;
    notify_get_state(gBlankedToken, &blanked);
    if (!blanked) {
        stop_monitor();
        return;
    }
    if (gTapWakeMonitor) return;
    gTapWakeMonitor = pCreateWithType(kCFAllocatorDefault, VP_HID_CLIENT_MONITOR, NULL);
    if (!gTapWakeMonitor) {
        NSLog(@"vphoned: tap to wake: no HID monitor client");
        return;
    }
    pRegisterCallback(gTapWakeMonitor, tap_wake_event, NULL, NULL);
    pSchedule(gTapWakeMonitor, gTapWakeQueue);
}

void vp_tap_to_wake_start(void (*touched)(void)) {
    gTapWakeTouched = touched;
    void *ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (ioKit) {
        pCreateWithType = dlsym(ioKit, "IOHIDEventSystemClientCreateWithType");
        pRegisterCallback = dlsym(ioKit, "IOHIDEventSystemClientRegisterEventCallback");
        pSchedule = dlsym(ioKit, "IOHIDEventSystemClientScheduleWithDispatchQueue");
        pUnschedule = dlsym(ioKit, "IOHIDEventSystemClientUnscheduleFromDispatchQueue");
        pEventType = dlsym(ioKit, "IOHIDEventGetType");
        pEventInteger = dlsym(ioKit, "IOHIDEventGetIntegerValue");
    }
    if (!pCreateWithType || !pRegisterCallback || !pSchedule || !pUnschedule || !pEventType || !pEventInteger) {
        NSLog(@"vphoned: tap to wake: HID monitor symbols missing");
        return;
    }
    gTapWakeQueue = dispatch_queue_create("com.vphone.vphoned.tap-wake", DISPATCH_QUEUE_SERIAL);
    uint32_t status = notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &gBlankedToken,
                                               gTapWakeQueue, ^(int token) {
        (void)token;
        update_monitor();
    });
    if (status != NOTIFY_STATUS_OK) {
        NSLog(@"vphoned: tap to wake: cannot observe the screen (notify status %u)", status);
        return;
    }
    dispatch_async(gTapWakeQueue, ^{ update_monitor(); });
}
