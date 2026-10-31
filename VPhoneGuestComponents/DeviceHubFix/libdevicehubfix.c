// libdevicehubfix.c — let Xcode's DeviceHub show a vphone guest's screen.
//
// DeviceHub (Xcode 27) views a device through the developer disk image's
// dtremotedisplayd. On a vphone guest it needs four fixes, one per process:
// cryptexd mounts the DDI, dtremotedisplayd reports media stream features,
// dtdeviceinfod supplies the framebuffer mask, and avconferenced keeps a
// banded stream from deadlocking the host GPU. avconferenced also encodes a
// frame only when the screen drew (VPScreenCaptureIdle.c in this folder).
//
// ## cryptexd: the DDI does not mount on iOS 27
//
// On iOS 27 the DDI is a cryptex, and cryptexd stages its assets before it
// grafts them. For each one it opens the staged copy and asks for data
// protection class D:
//
//     fd = open(path, O_RDWR);
//     if (fcntl(fd, F_SETPROTECTIONCLASS, 4) == -1 && errno != ENOTSUP)
//         fail;                  // "set protection class: %{darwin.errno}d"
//
// A guest answers EPERM, so staging fails ("copy asset: im4m: [1: Operation
// not permitted]", "system: staging failed") and CoreDevice reports the
// device as "connected (no DDI)" for good. Measured on iPhone17,3 27.0.1
// (24A446). iOS 26 guests mount the DDI without this.
//
// cryptexd already accepts a filesystem that does not do protection classes
// (ENOTSUP). An EPERM from F_SETPROTECTIONCLASS is reported as ENOTSUP, so it
// takes that path; every other fcntl, and every other failure, is untouched.
//
// ## dtremotedisplayd: no media stream features
//
// Before it starts a stream, DeviceHub asks the device which media stream
// features it has (MediaStreamGetSupportInfo) and keeps asking, with backoff,
// until the answer is non-empty. A guest always answers
//
//     SupportInfo: supportedFeatures: 0 (No supported features are available),
//         avcFrameworkVersion: "2215.5.1"
//
// so the viewer spins forever. dtremotedisplayd takes the answer from
// `MediaStreamSupportedFeatures.current` in the DDI's CoreDeviceUtilities
// (CoreDevice-642.16, Xcode 27A266a), whose policy refuses, among others:
//
//   "Remote control restricted. Device is customer-restricted (production
//    fused, customer OS, customer DDI) and running pre-27.0 OS" — every
//    26.x guest: `CurrentDevice.isCustomerRestricted` is
//    `isProductionFused && !hasInternalOSBuild && hasInternalDDI == false`.
//   "Remote control is only available on iOS 27.0, watchOS 27.0, or tvOS
//    27.0 or later … the device is not an iPhone, Apple Watch, or Apple TV"
//    — every iPad guest, whatever its version.
//
// Neither is a capability check. The stream itself is AVConference screen
// capture inside the guest, which does not ask either of them.
//
// The getter is interposed to answer with the features a Mac host offers
// (primary display mirrored video and display information, without system
// audio, which the VM window already plays) plus video by display ID, which an iPhone Duo's inner panel is streamed through,
// and `isCustomerRestricted`, which dtremotedisplayd also reads, answers no.
//
// ## dtdeviceinfod: missing framebuffer mask
//
// dtdeviceinfod answers DeviceHub's DisplayInfo from MobileGestalt. The 27.x
// iPhone guest reports `ChromeIdentifier` phone11 but no `FramebufferIdentifier`,
// so DeviceHub falls back to a rounded rectangle and draws the screen over the
// bezel corners. Only that missing answer is filled, with the phone11 mask from
// Xcode's /Library/Developer/DeviceKit/chrome_map.plist; existing answers and
// other chromes pass through, and the result keeps the Copy ownership rule.
//
// ## avconferenced: a banded stream deadlocks the host GPU
//
// A RemoteDesktop stream may split each frame into bands (tilesPerFrame 4).
// avconferenced then reads every captured frame on the GPU once per band, in
// VideoProcessing's VCPSideCarMetal: `temporalTransitionScore:previousFrame:
// forRegion:` and `copyFromFrame:toTile:origin:size:withFence:` each commit a
// command buffer that samples the frame's two 420f planes as two textures.
// The frame is written by backboardd's CoreAnimation display thread with the
// paravirtual M2 scaler (`IOSurfaceAcceleratorTransformSurface`), and reaches
// avconferenced while that transform is still in flight: IOSurface implicit
// synchronization is what orders the band reads after the write.
//
// On the host the two reach that synchronization by different paths. The
// VM process runs scaler requests one at a time and registers the write
// 0.25–0.8 ms after taking a request; the band command buffers come through
// ParavirtualizedGraphics' GPU task, which registers each texture's surface on
// its own, and can get there first. Once a writer waits, the host queues new
// readers behind it. When the scaler's write registers between the two plane
// registrations of one command buffer, the buffer holds the first plane and
// waits for the writer, which waits for that read: the scaler and the GPU
// FIFO both stop ("Timeout in timestamp wait"), the host restarts the GPU and
// the guest loses it for good. With on-screen activity this hit 3% of frames
// and deadlocked within 16–35 s (macOS 27.0.1 on M2, iOS 27.0.1 guest with
// cloudOS 26.4 paravirtual drivers). A single-band stream never reads the
// frame on the GPU.
//
// The request that produced a frame is already on the host's scaler queue
// when avconferenced gets the frame, and a synchronous transform returns only
// after the host finished it. So before the first band read of each frame one
// synchronous transform between two scratch surfaces is queued behind it;
// when it returns the frame's write is done and released, and no band read
// can meet it. That costs one scaler round trip per frame, 0.5–1 ms past the
// write the band reads used to wait for on the host anyway.
//
// ## dtdeviceinfod: the hinge-angle capability
//
// CoreDevice (DeviceHub) asks the DDI whether the device has a hinge; the
// DDI's dtdeviceinfod answers through CoreMotion's CMAngleManager, whose
// availability CoreMotion keys on the device-tree product-id a single-display
// guest cannot carry. Opening only the availability gate (v4) crash-looped
// dtdeviceinfod: the bridge then started the REAL manager, whose MotionThread
// asserts when its capability bits contradict the answer. The manager's whole
// ObjC surface is replaced instead — VPCMAngleManager.m in this folder — so
// CoreMotion's machinery never runs and the samples come from libvphonehinge's
// published latest sample. Only when that provider is live does the
// capability answer open; otherwise everything falls back to the original.
//
// ## Reach
//
// The interposes reach their callers because cryptexd, dtremotedisplayd,
// dtdeviceinfod and CoreDeviceUtilities are standalone images, not shared-cache
// ones: dyld binds their imports through the interposing table.
// CoreDeviceUtilities is on the DDI and not in the SDK, so its two symbols are
// weak flat-namespace imports; outside dtremotedisplayd they resolve to nothing
// and dyld skips those entries. VideoProcessing and AVConference are in the
// shared cache, so the band reads and the capture callback are replaced
// through the Objective-C runtime instead. The spawn hooks insert this into
// those four processes only — `vpIsDeviceHubFixTarget` in
// Shared/InjectionEnvironment.h.

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurfaceRef.h>

extern CFTypeRef MGCopyAnswer(CFStringRef key, CFDictionaryRef options);

// The features a Mac host reports for itself (raw 0x8c) but system audio
// output 0x8: primary display mirrored output 0x4 and display information
// 0x80; and video output by display ID 0x100, which an iPhone Duo's inner
// panel streams through (DeviceHub draws each integrated panel from its own
// display). The VM window plays the guest's audio already, and DeviceHub
// played it a second time, late. A video-only stream works (measured with
// 0x84).
#define VP_DEVICEHUB_FEATURES 0x184

#define VP_STRINGIFY_(value) #value
#define VP_STRINGIFY(value) VP_STRINGIFY_(value)

// MARK: - Log

// dtremotedisplayd runs as mobile and cryptexd as root; the mode keeps a root
// writer of the same log from silencing later ones, as in SystemHook.
static void vpLog(const char *format, const char *a, const char *b) {
    int fd = open("/var/mobile/Library/Caches/vphone-devicehubfix.log",
                  O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0666);
    if (fd < 0)
        return;
    fchmod(fd, 0666);
    dprintf(fd, "pid=%d ", getpid());
    dprintf(fd, format, a, b);
    dprintf(fd, "\n");
    close(fd);
}

// MARK: - cryptexd

static int vpFcntl(int fd, int command, ...) {
    va_list arguments;
    va_start(arguments, command);
    void *argument = va_arg(arguments, void *);
    va_end(arguments);
    int result = fcntl(fd, command, argument);
    if (result == -1 && command == F_SETPROTECTIONCLASS && errno == EPERM) {
        static atomic_int logged;
        if (!atomic_exchange(&logged, 1))
            vpLog("F_SETPROTECTIONCLASS %s, reported as %s", "EPERM", "ENOTSUP");
        errno = ENOTSUP;
    }
    return result;
}

// MARK: - dtremotedisplayd

// static MediaStreamSupportedFeatures.current.getter
// MediaStreamSupportedFeatures is a resilient struct (the framework is built
// for library evolution), so the getter returns it indirectly through x8.
extern void vpOriginalCurrentFeatures(void)
    __asm__("_$s19CoreDeviceUtilities28MediaStreamSupportedFeaturesV7currentACvgZ") __attribute__((weak_import));
// CurrentDevice.isCustomerRestricted.getter -> Bool
extern void vpOriginalIsCustomerRestricted(void)
    __asm__("_$s19CoreDeviceUtilities07CurrentB0V20isCustomerRestrictedSbvg") __attribute__((weak_import));

__attribute__((naked)) static void vpCurrentFeatures(void) {
    __asm__ volatile("mov x9, #" VP_STRINGIFY(VP_DEVICEHUB_FEATURES) "\n"
                     "str x9, [x8]\n"
                     "ret\n");
}

__attribute__((naked)) static void vpIsCustomerRestricted(void) {
    __asm__ volatile("mov w0, #0\n"
                     "ret\n");
}

__attribute__((constructor)) static void vpLogLoad(void) {
    if (vpOriginalCurrentFeatures || vpOriginalIsCustomerRestricted)
        vpLog("media stream features=" VP_STRINGIFY(VP_DEVICEHUB_FEATURES) " current=%s isCustomerRestricted=%s",
              vpOriginalCurrentFeatures ? "interposed" : "absent",
              vpOriginalIsCustomerRestricted ? "interposed" : "absent");
}

// Fill the missing mask and preserve Copy ownership. Bounded diagnostics log
// only the three identifiers consumed by the DDI DisplayInfoProvider.
static CFTypeRef vpDisplayAnswer(CFStringRef key, CFDictionaryRef options) {
    CFTypeRef result = MGCopyAnswer(key, options);
    // The virtual board advertises phone11 chrome but no framebuffer mask.
    // DDI metadata only: use the matching mask shipped in Xcode's
    // /Library/Developer/DeviceKit/chrome_map.plist. Keep real answers intact.
    if (!result && key && !strcmp(getprogname(), "dtdeviceinfod") &&
        CFEqual(key, CFSTR("FramebufferIdentifier"))) {
        CFTypeRef chrome = MGCopyAnswer(CFSTR("ChromeIdentifier"), NULL);
        if (chrome && CFEqual(chrome, CFSTR("com.apple.dt.devicekit.chrome.phone11")))
            result = CFRetain(CFSTR("4E5532ED-1470-47D1-BDF4-7AA90C26957A"));
        if (chrome) CFRelease(chrome);
    }
    if (key && (!strcmp(getprogname(), "dtdeviceinfod")) &&
        (CFEqual(key, CFSTR("FramebufferIdentifier")) ||
         CFEqual(key, CFSTR("ChromeIdentifier")) ||
         CFEqual(key, CFSTR("DisplayExtendedProperties")))) {
        static atomic_uint count;
        if (atomic_fetch_add(&count, 1) < 12) {
            char name[128] = {0}, value[4096] = {0};
            CFStringGetCString(key, name, sizeof(name), kCFStringEncodingUTF8);
            CFStringRef description = result ? CFCopyDescription(result) : NULL;
            if (description) {
                CFStringGetCString(description, value, sizeof(value), kCFStringEncodingUTF8);
                CFRelease(description);
            }
            vpLog("display %s = %s", name, result ? value : "<null>");
        }
    }
    return result;
}

// MARK: - avconferenced

#define VP_VIDEO_PROCESSING "/System/Library/PrivateFrameworks/VideoProcessing.framework/VideoProcessing"

extern int IOSurfaceAcceleratorCreate(CFAllocatorRef allocator, CFDictionaryRef properties, void **accelerator);
extern int IOSurfaceAcceleratorTransformSurface(void *accelerator, IOSurfaceRef source, IOSurfaceRef destination,
                                                CFDictionaryRef options, void *rectangles, void *completion,
                                                void *swap, void *command);

__attribute__((used)) static IMP vpOriginalTransitionScore;
__attribute__((used)) static IMP vpOriginalCopyFromFrame;

static void *vpScaler;
static CVPixelBufferRef vpScalerSource;
static CVPixelBufferRef vpScalerDestination;

static CVPixelBufferRef vpScratchBuffer(size_t width, size_t height) {
    CFDictionaryRef surface = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                 &kCFTypeDictionaryValueCallBacks);
    const void *keys[] = {kCVPixelBufferIOSurfacePropertiesKey};
    const void *values[] = {surface};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                                                    &kCFTypeDictionaryValueCallBacks);
    CVPixelBufferRef buffer = NULL;
    CVPixelBufferCreate(NULL, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer);
    CFRelease(attributes);
    CFRelease(surface);
    return buffer;
}

static void vpCreateScalerBarrier(void) {
    if (IOSurfaceAcceleratorCreate(NULL, NULL, &vpScaler) != 0)
        vpScaler = NULL;
    vpScalerSource = vpScratchBuffer(64, 64);
    vpScalerDestination = vpScratchBuffer(32, 32);
    if (!vpScaler || !vpScalerSource || !vpScalerDestination)
        vpLog("scaler barrier %s, %s", "unavailable", "a banded stream can deadlock");
}

__attribute__((used)) static void vpAwaitScaler(CVPixelBufferRef frame) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static _Atomic uint32_t awaited;
    IOSurfaceRef surface = frame ? CVPixelBufferGetIOSurface(frame) : NULL;
    if (!surface)
        return;
    uint32_t id = IOSurfaceGetID(surface);
    if (atomic_load(&awaited) == id)
        return;
    pthread_once(&once, vpCreateScalerBarrier);
    pthread_mutex_lock(&lock);
    if (atomic_load(&awaited) != id) {
        if (vpScaler && vpScalerSource && vpScalerDestination)
            IOSurfaceAcceleratorTransformSurface(vpScaler, CVPixelBufferGetIOSurface(vpScalerSource),
                                                 CVPixelBufferGetIOSurface(vpScalerDestination), NULL, NULL,
                                                 NULL, NULL, NULL);
        atomic_store(&awaited, id);
    }
    pthread_mutex_unlock(&lock);
}

// Calls vpAwaitScaler with the frame (x2) and continues into the original
// with x0–x8 intact. Neither method takes a floating-point argument (region,
// origin and size are passed by reference), and the score method returns a
// C++ future indirectly, through x8.
#define VP_AWAIT_SCALER_THEN(name, original)                                                             \
    __attribute__((naked)) static void name(void) {                                                     \
        __asm__ volatile("pacibsp\n"                                                                    \
                         "stp x29, x30, [sp, #-0x60]!\n"                                                \
                         "mov x29, sp\n"                                                                \
                         "stp x0, x1, [sp, #0x10]\n"                                                    \
                         "stp x2, x3, [sp, #0x20]\n"                                                    \
                         "stp x4, x5, [sp, #0x30]\n"                                                    \
                         "stp x6, x7, [sp, #0x40]\n"                                                    \
                         "str x8, [sp, #0x50]\n"                                                        \
                         "mov x0, x2\n"                                                                 \
                         "bl _vpAwaitScaler\n"                                                          \
                         "ldp x0, x1, [sp, #0x10]\n"                                                    \
                         "ldp x2, x3, [sp, #0x20]\n"                                                    \
                         "ldp x4, x5, [sp, #0x30]\n"                                                    \
                         "ldp x6, x7, [sp, #0x40]\n"                                                    \
                         "ldr x8, [sp, #0x50]\n"                                                        \
                         "ldp x29, x30, [sp], #0x60\n"                                                  \
                         "autibsp\n"                                                                    \
                         "adrp x16, _" #original "@PAGE\n"                                              \
                         "ldr x16, [x16, _" #original "@PAGEOFF]\n"                                     \
                         "braaz x16\n");                                                                \
    }

VP_AWAIT_SCALER_THEN(vpTransitionScore, vpOriginalTransitionScore)
VP_AWAIT_SCALER_THEN(vpCopyFromFrame, vpOriginalCopyFromFrame)

__attribute__((constructor)) static void vpInstallScalerBarrier(void) {
    if (strcmp(getprogname(), "avconferenced") != 0)
        return;
    dlopen(VP_VIDEO_PROCESSING, RTLD_LAZY | RTLD_LOCAL);
    Class sideCar = objc_getClass("VCPSideCarMetal");
    Method score = sideCar ? class_getInstanceMethod(sideCar, sel_registerName(
                                 "temporalTransitionScore:previousFrame:forRegion:"))
                           : NULL;
    Method copy = sideCar ? class_getInstanceMethod(sideCar, sel_registerName(
                                "copyFromFrame:toTile:origin:size:withFence:"))
                          : NULL;
    if (!score || !copy) {
        vpLog("VCPSideCarMetal band reads %s, %s", "not found", "a banded stream can deadlock");
        return;
    }
    vpOriginalTransitionScore = method_setImplementation(score, (IMP)vpTransitionScore);
    vpOriginalCopyFromFrame = method_setImplementation(copy, (IMP)vpCopyFromFrame);
    vpLog("VCPSideCarMetal band reads %s, %s", "found", "they wait for the scaler");
}

int vphone_devicehubfix_version(void) { return 7; }

// The CMAngleManager stand-in for dtdeviceinfod lives in VPCMAngleManager.m
// (same dylib): it swaps the manager's whole ObjC surface and feeds the
// bridge from the hinge provider's published samples.

__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *replacee;
} vpInterpose[] = {
    {(const void *)vpDisplayAnswer, (const void *)MGCopyAnswer},
    {(const void *)vpFcntl, (const void *)fcntl},
    {(const void *)vpCurrentFeatures, (const void *)vpOriginalCurrentFeatures},
    {(const void *)vpIsCustomerRestricted, (const void *)vpOriginalIsCustomerRestricted},
};
