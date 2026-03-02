// unlock — dispatch Consumer Menu (Home) IOHIDEvent from inside the VM
// Replicates TrollVNC STHIDEventGenerator._sendHIDEvent pattern:
//   - dispatch_once client creation
//   - dispatch_async on serial queue with setSenderID inside block

#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef const void *CFTypeRef;
typedef const void *CFAllocatorRef;

#define kHIDPage_Consumer       0x0C
#define kHIDUsage_Csmr_Menu     0x40
#define kIOHIDEventOptionNone   0

typedef CFTypeRef (*CreateClient_t)(CFAllocatorRef);
typedef CFTypeRef (*CreateKbEvent_t)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, int, uint32_t);
typedef void (*SetSenderID_t)(CFTypeRef, uint64_t);
typedef void (*DispatchEvent_t)(CFTypeRef, CFTypeRef);
typedef void (*CFRelease_t)(CFTypeRef);
typedef CFTypeRef (*CFRetain_t)(CFTypeRef);

static CreateClient_t   g_createClient;
static CreateKbEvent_t  g_createKbEvent;
static SetSenderID_t    g_setSenderID;
static DispatchEvent_t  g_dispatchEvent;
static CFRelease_t      g_cfRelease;
static CFRetain_t       g_cfRetain;
static CFAllocatorRef   g_alloc;

static CFTypeRef get_client(void) {
    static CFTypeRef client = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        client = g_createClient(g_alloc);
        printf("[unlock] client=%p\n", client);
    });
    return client;
}

static void send_hid_event(CFTypeRef event, dispatch_queue_t queue) {
    if (!event) return;
    CFTypeRef retained = g_cfRetain(event);
    dispatch_async(queue, ^{
        g_setSenderID(retained, 0x8000000817319372ULL);
        g_dispatchEvent(get_client(), retained);
        g_cfRelease(retained);
    });
}

int main(void) {
    void *cf = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW);
    if (!cf) { fprintf(stderr, "[unlock] dlopen CF: %s\n", dlerror()); return 1; }

    g_cfRelease = (CFRelease_t)dlsym(cf, "CFRelease");
    g_cfRetain = (CFRetain_t)dlsym(cf, "CFRetain");
    CFAllocatorRef *pAlloc = (CFAllocatorRef *)dlsym(cf, "kCFAllocatorDefault");
    if (!g_cfRelease || !g_cfRetain || !pAlloc) { fprintf(stderr, "[unlock] CF syms\n"); return 1; }
    g_alloc = *pAlloc;

    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!iokit) { fprintf(stderr, "[unlock] dlopen IOKit: %s\n", dlerror()); return 1; }

    g_createClient = (CreateClient_t)dlsym(iokit, "IOHIDEventSystemClientCreate");
    g_createKbEvent = (CreateKbEvent_t)dlsym(iokit, "IOHIDEventCreateKeyboardEvent");
    g_setSenderID = (SetSenderID_t)dlsym(iokit, "IOHIDEventSetSenderID");
    g_dispatchEvent = (DispatchEvent_t)dlsym(iokit, "IOHIDEventSystemClientDispatchEvent");

    if (!g_createClient || !g_createKbEvent || !g_setSenderID || !g_dispatchEvent) {
        fprintf(stderr, "[unlock] IOKit syms\n"); return 1;
    }

    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    dispatch_queue_t queue = dispatch_queue_create("com.unlock.hid-events", attr);

    printf("[unlock] sending Menu (Home) x2 (1.5s gap)...\n");

    // First press — wakes screen
    CFTypeRef d1 = g_createKbEvent(g_alloc, mach_absolute_time(),
        kHIDPage_Consumer, kHIDUsage_Csmr_Menu, 1, kIOHIDEventOptionNone);
    send_hid_event(d1, queue);
    g_cfRelease(d1);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), queue, ^{
        CFTypeRef u1 = g_createKbEvent(g_alloc, mach_absolute_time(),
            kHIDPage_Consumer, kHIDUsage_Csmr_Menu, 0, kIOHIDEventOptionNone);
        send_hid_event(u1, queue);
        g_cfRelease(u1);

        // Second press — unlocks (1.5s delay avoids App Switcher double-tap)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), queue, ^{
            CFTypeRef d2 = g_createKbEvent(g_alloc, mach_absolute_time(),
                kHIDPage_Consumer, kHIDUsage_Csmr_Menu, 1, kIOHIDEventOptionNone);
            send_hid_event(d2, queue);
            g_cfRelease(d2);

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), queue, ^{
                CFTypeRef u2 = g_createKbEvent(g_alloc, mach_absolute_time(),
                    kHIDPage_Consumer, kHIDUsage_Csmr_Menu, 0, kIOHIDEventOptionNone);
                send_hid_event(u2, queue);
                g_cfRelease(u2);

                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), queue, ^{
                    printf("[unlock] done\n");
                    exit(0);
                });
            });
        });
    });

    dispatch_main();
    return 0;
}
