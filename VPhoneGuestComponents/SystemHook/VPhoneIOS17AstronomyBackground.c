#include <dlfcn.h>
#include <objc/runtime.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/stat.h>

typedef void (*Backdrop)(id, SEL, id, uint64_t);
typedef void (*IndexedDraw)(id, SEL, uint64_t, uint64_t, uint64_t, id,
                            uint64_t, uint64_t, int64_t, uint64_t);

static Backdrop vpOriginalBackdrop;
static _Atomic(IndexedDraw) vpOriginalIndexedDraw;
static _Thread_local id vpBackdropEncoder;
static os_unfair_lock vpDrawLock = OS_UNFAIR_LOCK_INIT;
static Method vpDrawMethod;
static SEL vpIndexedDrawSelector;
static Class (*vpClassOf)(id);
static Method (*vpGetMethod)(Class, SEL);
static IMP (*vpGetImplementation)(Method);
static IMP (*vpReplaceImplementation)(Method, IMP);

static void vpDrawWithoutCorruptSkyMesh(id encoder, SEL command, uint64_t primitive,
                                       uint64_t count, uint64_t indexType, id indexBuffer,
                                       uint64_t offset, uint64_t instances,
                                       int64_t baseVertex, uint64_t baseInstance) {
    // Calliope draws the background mesh as one indexed triangle list. Its
    // separate non-indexed star sprites and the later planet passes stay live.
    if (encoder == vpBackdropEncoder && primitive == 3 && indexType == 0 &&
        count > UINT16_MAX && offset == 0 && instances == 1 &&
        baseVertex == 0 && baseInstance == 0)
        return;
    IndexedDraw original = atomic_load_explicit(&vpOriginalIndexedDraw, memory_order_acquire);
    original(encoder, command, primitive, count, indexType, indexBuffer, offset,
             instances, baseVertex, baseInstance);
}

static bool vpPrepareBackdropEncoder(id encoder) {
    Method method = vpGetMethod(vpClassOf(encoder), vpIndexedDrawSelector);
    if (!method) return false;
    os_unfair_lock_lock(&vpDrawLock);
    if (!vpDrawMethod) {
        atomic_store_explicit(&vpOriginalIndexedDraw, (IndexedDraw)vpGetImplementation(method), memory_order_release);
        vpReplaceImplementation(method, (IMP)vpDrawWithoutCorruptSkyMesh);
        vpDrawMethod = method;
    }
    bool supported = vpDrawMethod == method;
    os_unfair_lock_unlock(&vpDrawLock);
    return supported;
}

static void vpRenderBackdrop(id renderer, SEL command, id encoder, uint64_t frameIndex) {
    id previousEncoder = vpBackdropEncoder;
    vpBackdropEncoder = vpPrepareBackdropEncoder(encoder) ? encoder : nil;
    vpOriginalBackdrop(renderer, command, encoder, frameIndex);
    vpBackdropEncoder = previousEncoder;
}

void vpInstallIOS17AstronomyBackground(const char *marker) {
    struct stat markerInfo;
    if (stat(marker, &markerInfo) != 0) return;

    Class (*getClass)(const char *) = dlsym(RTLD_DEFAULT, "objc_getClass");
    SEL (*selector)(const char *) = dlsym(RTLD_DEFAULT, "sel_registerName");
    vpClassOf = dlsym(RTLD_DEFAULT, "object_getClass");
    vpGetMethod = dlsym(RTLD_DEFAULT, "class_getInstanceMethod");
    vpGetImplementation = dlsym(RTLD_DEFAULT, "method_getImplementation");
    vpReplaceImplementation = dlsym(RTLD_DEFAULT, "method_setImplementation");
    if (!getClass || !selector || !vpClassOf || !vpGetMethod ||
        !vpGetImplementation || !vpReplaceImplementation)
        return;

    Method backdrop = vpGetMethod(getClass("NUNICalliopeRenderer"),
                                 selector("_renderOffscreenBackgroundWithRenderEncoder:frameBufferIndex:"));
    if (!backdrop) return;

    vpIndexedDrawSelector = selector("drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:"
                                    "instanceCount:baseVertex:baseInstance:");
    vpOriginalBackdrop = (Backdrop)vpGetImplementation(backdrop);
    vpReplaceImplementation(backdrop, (IMP)vpRenderBackdrop);
}
