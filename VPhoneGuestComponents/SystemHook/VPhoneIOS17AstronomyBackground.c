#include <dirent.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <objc/runtime.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

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

static void vpRemoveStaleAstronomyPreviews(struct timespec cutoff) {
    const char *home = getenv("CFFIXED_USER_HOME");
    if (!home) home = getenv("HOME");
    if (!home) return;

    char cachePath[PATH_MAX];
    int length = snprintf(cachePath, sizeof(cachePath), "%s/Library/Caches", home);
    if (length < 0 || (size_t)length >= sizeof(cachePath)) return;
    DIR *directory = opendir(cachePath);
    if (!directory) return;

    // AegirPoster reuses these generated PNGs even after the graphics fix.
    int cache = dirfd(directory);
    const char prefix[] = "aegir-preview-";
    struct dirent *entry;
    while ((entry = readdir(directory))) {
        const char *name = entry->d_name;
        size_t size = strlen(name);
        if (size < sizeof(prefix) + 4 || strncmp(name, prefix, sizeof(prefix) - 1) != 0 ||
            strcmp(name + size - 4, ".png") != 0)
            continue;
        struct stat info;
        if (fstatat(cache, name, &info, AT_SYMLINK_NOFOLLOW) != 0 || !S_ISREG(info.st_mode))
            continue;
        struct timespec modified = info.st_mtimespec;
        if (modified.tv_sec < cutoff.tv_sec ||
            (modified.tv_sec == cutoff.tv_sec && modified.tv_nsec < cutoff.tv_nsec))
            unlinkat(cache, name, 0);
    }
    closedir(directory);
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
    vpRemoveStaleAstronomyPreviews(markerInfo.st_mtimespec);
}
