#import "vphoned_hid.h"
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <unistd.h>

typedef void *IOHIDEventSystemClientRef;
typedef void *IOHIDEventRef;
typedef double IOHIDFloat;

static IOHIDEventSystemClientRef (*pCreate)(CFAllocatorRef);
static IOHIDEventRef (*pKeyboard)(CFAllocatorRef, uint64_t,
                                  uint32_t, uint32_t, int, int);
static void (*pSetSender)(IOHIDEventRef, uint64_t);
static void (*pDispatch)(IOHIDEventSystemClientRef, IOHIDEventRef);

// Digitizer (touch) event symbols — resolved lazily; touch is a no-op if absent.
static IOHIDEventRef (*pDigitizer)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                   uint32_t, uint32_t, uint32_t, IOHIDFloat,
                                   IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                   boolean_t, boolean_t, uint32_t);
static IOHIDEventRef (*pFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                IOHIDFloat, IOHIDFloat, boolean_t, boolean_t, uint32_t);
static void (*pAppend)(IOHIDEventRef, IOHIDEventRef, uint32_t);
static void (*pSetInt)(IOHIDEventRef, uint32_t, int);

static IOHIDEventSystemClientRef gClient;
static dispatch_queue_t gHIDQueue;

// Digitizer event-mask bits and transducer types (IOHIDEventTypes.h).
#define VP_DIG_RANGE     0x00000001u
#define VP_DIG_TOUCH     0x00000002u
#define VP_DIG_POSITION  0x00000004u
#define VP_DIG_IDENTITY  0x00000020u
#define VP_TRANSDUCER_HAND   1
#define VP_TRANSDUCER_FINGER 2
// kIOHIDEventFieldDigitizerIsDisplayIntegrated: (kIOHIDEventTypeDigitizer<<16)|offset.
#define VP_FIELD_IS_DISPLAY_INTEGRATED ((((uint32_t)11) << 16) | 25)

BOOL vp_hid_load(void) {
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!h) { NSLog(@"vphoned: dlopen IOKit failed"); return NO; }

    pCreate    = dlsym(h, "IOHIDEventSystemClientCreate");
    pKeyboard  = dlsym(h, "IOHIDEventCreateKeyboardEvent");
    pSetSender = dlsym(h, "IOHIDEventSetSenderID");
    pDispatch  = dlsym(h, "IOHIDEventSystemClientDispatchEvent");

    pDigitizer = dlsym(h, "IOHIDEventCreateDigitizerEvent");
    pFinger    = dlsym(h, "IOHIDEventCreateDigitizerFingerEvent");
    pAppend    = dlsym(h, "IOHIDEventAppendEvent");
    pSetInt    = dlsym(h, "IOHIDEventSetIntegerValue");

    if (!pCreate || !pKeyboard || !pSetSender || !pDispatch) {
        NSLog(@"vphoned: missing IOKit symbols");
        return NO;
    }
    if (!pDigitizer || !pFinger || !pAppend || !pSetInt)
        NSLog(@"vphoned: digitizer symbols missing, touch injection disabled");

    gClient = pCreate(kCFAllocatorDefault);
    if (!gClient) { NSLog(@"vphoned: IOHIDEventSystemClientCreate returned NULL"); return NO; }

    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    gHIDQueue = dispatch_queue_create("com.vphone.vphoned.hid", attr);

    NSLog(@"vphoned: IOKit loaded");
    return YES;
}

static void send_hid_event(IOHIDEventRef event) {
    IOHIDEventRef strong = (IOHIDEventRef)CFRetain(event);
    dispatch_async(gHIDQueue, ^{
        pSetSender(strong, 0x8000000817319372);
        pDispatch(gClient, strong);
        CFRelease(strong);
    });
}

void vp_hid_press(uint32_t page, uint32_t usage) {
    IOHIDEventRef down = pKeyboard(kCFAllocatorDefault, mach_absolute_time(),
                                   page, usage, 1, 0);
    if (!down) return;
    send_hid_event(down);
    CFRelease(down);

    usleep(100000);

    IOHIDEventRef up = pKeyboard(kCFAllocatorDefault, mach_absolute_time(),
                                 page, usage, 0, 0);
    if (!up) return;
    send_hid_event(up);
    CFRelease(up);
}

void vp_hid_key(uint32_t page, uint32_t usage, BOOL down) {
    IOHIDEventRef ev = pKeyboard(kCFAllocatorDefault, mach_absolute_time(),
                                 page, usage, down ? 1 : 0, 0);
    if (ev) { send_hid_event(ev); CFRelease(ev); }
}

// Build a display-integrated hand digitizer event carrying one finger and
// dispatch it. Mirrors WebKit's HIDEventGenerator single-touch path.
static void dispatch_digitizer(double x, double y, boolean_t range,
                               boolean_t touch, uint32_t mask) {
    if (!pDigitizer || !pFinger || !pAppend || !pSetInt) return;

    uint64_t ts = mach_absolute_time();
    IOHIDEventRef parent = pDigitizer(kCFAllocatorDefault, ts, VP_TRANSDUCER_HAND,
                                      0, 0, mask, 0, x, y, 0, 0, 0, range, touch, 0);
    if (!parent) return;
    pSetInt(parent, VP_FIELD_IS_DISPLAY_INTEGRATED, 1);

    IOHIDEventRef finger = pFinger(kCFAllocatorDefault, ts, 1, VP_TRANSDUCER_FINGER,
                                   mask, x, y, 0, 0, 0, range, touch, 0);
    if (finger) {
        pSetInt(finger, VP_FIELD_IS_DISPLAY_INTEGRATED, 1);
        pAppend(parent, finger, 0);
        CFRelease(finger);
    }

    IOHIDEventRef strong = (IOHIDEventRef)CFRetain(parent);
    dispatch_async(gHIDQueue, ^{
        pSetSender(strong, 0x8000000817319372);
        pDispatch(gClient, strong);
        CFRelease(strong);
    });
    CFRelease(parent);
}

void vp_hid_touch(int phase, double x, double y) {
    switch (phase) {
    case 0: // down
        dispatch_digitizer(x, y, 1, 1, VP_DIG_TOUCH | VP_DIG_IDENTITY);
        break;
    case 1: // move
        dispatch_digitizer(x, y, 1, 1, VP_DIG_POSITION);
        break;
    case 3: // up
    default:
        dispatch_digitizer(x, y, 0, 0, VP_DIG_TOUCH | VP_DIG_IDENTITY);
        break;
    }
}
