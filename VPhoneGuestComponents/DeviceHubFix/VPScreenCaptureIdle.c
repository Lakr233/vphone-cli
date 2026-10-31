// VPScreenCaptureIdle.c — avconferenced encodes a screen frame only when the
// screen drew.
//
// DeviceHub's stream is avconferenced screen capture: FigVirtualDisplay
// clones each lit display in backboardd, the clone writes frames back, and
// VCScreenCaptureFigCaptureController hands each one to VideoProcessing's
// real-time encoder. After the screen draws, the writeback keeps coming at the
// capture rate for about a second before it stops; a still screen sends
// nothing. The live Clock icon on the Home Screen draws about ten times a
// second, so it never stops: an idle Home Screen streamed about 42 fps per
// display, two streams on an iPhone Duo. Measured on iOS 27.1 (24A94425).
//
// On a guest the encode is the expensive part, and it runs on the host: the
// encoder is the host's AVE through VideoToolbox paravirtualization, and in
// the real-time encoder's user-DPB mode every frame carries reference-frame
// dictionaries the host serializes as binary property lists, then waits for
// the guest's reply. With a DeviceHub viewer open on the idle Home Screen the
// VM process used 91% of a core (macOS 27.0.1, M5 Pro), 14% without a viewer.
//
// So a frame reaches the encoder when the render server's frame counter for
// the main display (CARenderServerGetFrameCounterByIndex) moved since the last
// one, and otherwise once per keep-alive interval. A frame written back with a
// change can arrive after the counter it moved; the keep-alive frame, which
// also lets the encoder refine a still image, bounds that to 250 ms, and the
// writeback runs for about a second after the last draw. On an iPhone Duo the
// main display is the panel the inner display is shown on, so the counter
// covers both streams. Measured on the idle Home Screen: 10 fps per display,
// VM process 50%; scrolling Settings still streams 54–60 fps.

#include <dlfcn.h>
#include <fcntl.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>

#define VP_QUARTZ_CORE "/System/Library/Frameworks/QuartzCore.framework/QuartzCore"
#define VP_AV_CONFERENCE "/System/Library/PrivateFrameworks/AVConference.framework/AVConference"

// The interval of the frames that pass while the counter stands still.
#define VP_KEEP_ALIVE_NANOSECONDS 250000000ull
// Capture controllers followed at once: one per streamed display.
#define VP_CONTROLLERS 4

// MARK: - Log (same file the rest of the dylib writes)

static void vpIdleLog(const char *format, const char *a, const char *b) {
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

// MARK: - The capture callback

typedef void (*VPDidReceiveSampleBuffer)(id, SEL, id, CFTypeRef, uint64_t);

static int (*vpFrameCounter)(unsigned int server, unsigned int display);
static VPDidReceiveSampleBuffer vpOriginalDidReceiveSampleBuffer;

static struct {
    const void *controller;
    int counter;
    uint64_t passed;
} vpControllers[VP_CONTROLLERS];
static pthread_mutex_t vpControllersLock = PTHREAD_MUTEX_INITIALIZER;

static bool vpShouldPass(const void *controller) {
    int counter = vpFrameCounter(0, 0);
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    bool pass = true;
    pthread_mutex_lock(&vpControllersLock);
    int slot = -1;
    for (int index = 0; index < VP_CONTROLLERS && slot < 0; index++)
        if (vpControllers[index].controller == controller)
            slot = index;
    // A new stream takes the slot that passed a frame longest ago (an empty
    // one never did); a stream that ended leaves its slot behind.
    if (slot < 0) {
        slot = 0;
        for (int index = 1; index < VP_CONTROLLERS; index++)
            if (vpControllers[index].passed < vpControllers[slot].passed)
                slot = index;
    }
    if (vpControllers[slot].controller != controller || counter != vpControllers[slot].counter) {
        vpControllers[slot].controller = controller;
        vpControllers[slot].counter = counter;
    } else {
        pass = now - vpControllers[slot].passed >= VP_KEEP_ALIVE_NANOSECONDS;
    }
    if (pass)
        vpControllers[slot].passed = now;
    pthread_mutex_unlock(&vpControllersLock);
    return pass;
}

static void vpDidReceiveSampleBuffer(id self, SEL command, id capture, CFTypeRef sampleBuffer, uint64_t flags) {
    if (sampleBuffer && !vpShouldPass(self))
        return;
    vpOriginalDidReceiveSampleBuffer(self, command, capture, sampleBuffer, flags);
}

__attribute__((constructor)) static void vpInstallScreenCaptureIdle(void) {
    if (strcmp(getprogname(), "avconferenced") != 0)
        return;
    vpFrameCounter = dlsym(dlopen(VP_QUARTZ_CORE, RTLD_LAZY | RTLD_LOCAL), "CARenderServerGetFrameCounterByIndex");
    dlopen(VP_AV_CONFERENCE, RTLD_LAZY | RTLD_LOCAL);
    Class controller = objc_getClass("VCScreenCaptureFigCaptureController");
    Method receive = controller ? class_getInstanceMethod(controller, sel_registerName(
                                      "screenCaptureController:didReceiveSampleBuffer:transformFlags:"))
                                : NULL;
    if (!vpFrameCounter || !receive) {
        vpIdleLog("screen capture idle frames %s, %s", "not found", "every captured frame is encoded");
        return;
    }
    vpOriginalDidReceiveSampleBuffer =
        (VPDidReceiveSampleBuffer)method_setImplementation(receive, (IMP)vpDidReceiveSampleBuffer);
    vpIdleLog("screen capture idle frames %s, %s", "found", "frames pass when the screen drew");
}
