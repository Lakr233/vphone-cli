#include "VPhoneIOS18GPUTransport.h"
#include "../MISFix/MISFixDetour.h"
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// iOS 18's GPU userland on a cloudOS 26.1 kernel. `cfw install` writes the
// marker only for that pairing, with the iOS 18 paravirtual driver installed.
// The calls come from IOGPU.framework inside the shared cache and from the
// driver bundle, so IOKit's entry points are detoured rather than interposed;
// see MISFix/MISFixDetour.h.
#define VP_IOS18_GPU_MARKER "/usr/lib/vphone-ios18-gpu"

// MISFixDetour reports each install through these. SystemHook is in every
// process, so its success line is dropped; failures are reported below.
void MISFixNote(const char *format, ...) { (void)format; }
const char *MISFixCallerImage(const void *address) { (void)address; return "?"; }

// MARK: - Device connections

// Only IOGPU device clients are translated: every other user client in the
// process, including IOGPU's other client types, keeps its selectors.
enum { VP_DEVICE_SLOTS = 32 };
static io_connect_t vpDevices[VP_DEVICE_SLOTS];
static atomic_int vpDeviceCount;
static os_unfair_lock vpDeviceLock = OS_UNFAIR_LOCK_INIT;

// A closed name can come back from another IOServiceOpen, which always
// replaces whatever this table remembered about it.
static void vpForgetLocked(io_connect_t connection) {
    for (int index = 0; index < VP_DEVICE_SLOTS; index++) {
        if (vpDevices[index] != connection) continue;
        vpDevices[index] = MACH_PORT_NULL;
        atomic_fetch_sub(&vpDeviceCount, 1);
    }
}

static bool vpIsDevice(io_connect_t connection) {
    if (connection == MACH_PORT_NULL || atomic_load_explicit(&vpDeviceCount, memory_order_relaxed) == 0) return false;
    bool found = false;
    os_unfair_lock_lock(&vpDeviceLock);
    for (int index = 0; index < VP_DEVICE_SLOTS && !found; index++) found = vpDevices[index] == connection;
    os_unfair_lock_unlock(&vpDeviceLock);
    return found;
}

static void vpNoteFirstDevice(void) {
    static atomic_bool noted;
    if (atomic_exchange(&noted, true)) return;
    int fd = open("/var/mobile/Library/Caches/vphone-systemhook.log", O_WRONLY | O_APPEND | O_CLOEXEC);
    if (fd < 0) return;
    dprintf(fd, "pid=%d ios18-gpu=%s device opened\n", getpid(), getprogname());
    close(fd);
}

// MARK: - IOKit detours

static kern_return_t (*vpServiceOpen)(io_service_t, task_port_t, uint32_t, io_connect_t *);
static kern_return_t vpServiceOpenHook(io_service_t service, task_port_t task, uint32_t type, io_connect_t *connection) {
    kern_return_t result = vpServiceOpen(service, task, type, connection);
    if (result != KERN_SUCCESS || !connection) return result;
    bool device = (type & 0xffff) == VP_IOS18_GPU_DEVICE_CLIENT && IOObjectConformsTo(service, "IOGPU");
    bool added = false;
    os_unfair_lock_lock(&vpDeviceLock);
    vpForgetLocked(*connection);
    for (int index = 0; device && index < VP_DEVICE_SLOTS && !added; index++) {
        if (vpDevices[index] != MACH_PORT_NULL) continue;
        vpDevices[index] = *connection;
        atomic_fetch_add(&vpDeviceCount, 1);
        added = true;
    }
    os_unfair_lock_unlock(&vpDeviceLock);
    if (added) vpNoteFirstDevice();
    // Untranslated, this client would call the wrong methods.
    if (device && !added) {
        IOServiceClose(*connection);
        *connection = MACH_PORT_NULL;
        return kIOReturnNoResources;
    }
    return result;
}

static kern_return_t (*vpServiceClose)(io_connect_t);
static kern_return_t vpServiceCloseHook(io_connect_t connection) {
    os_unfair_lock_lock(&vpDeviceLock);
    vpForgetLocked(connection);
    os_unfair_lock_unlock(&vpDeviceLock);
    return vpServiceClose(connection);
}

static kern_return_t (*vpCallMethod)(mach_port_t, uint32_t, const uint64_t *, uint32_t, const void *, size_t,
    uint64_t *, uint32_t *, void *, size_t *);
static kern_return_t vpCallMethodHook(mach_port_t connection, uint32_t selector,
    const uint64_t *input, uint32_t inputCount, const void *inputStruct, size_t inputStructSize,
    uint64_t *output, uint32_t *outputCount, void *outputStruct, size_t *outputStructSize) {
    if (!vpIsDevice(connection))
        return vpCallMethod(connection, selector, input, inputCount, inputStruct, inputStructSize,
            output, outputCount, outputStruct, outputStructSize);
    uint32_t modern;
    VPIOS18GPUSelectorAction action = vpIOS18GPUSelector(selector, &modern);
    if (action == VPIOS18GPUAnswerLocally) return KERN_SUCCESS;

    if (selector == VP_IOS18_GPU_RESOURCE_CREATE && outputStruct && outputStructSize &&
        *outputStructSize >= VP_IOS18_GPU_RESOURCE_HEADER) {
        size_t legacySize = *outputStructSize, size = legacySize + VP_IOS18_GPU_RESOURCE_GROWTH;
        uint8_t *reply = calloc(1, size);
        if (!reply) return kIOReturnNoMemory;
        kern_return_t result = vpCallMethod(connection, modern, input, inputCount, inputStruct, inputStructSize,
            output, outputCount, reply, &size);
        if (result == KERN_SUCCESS && !vpIOS18GPUResourceReply(outputStruct, legacySize, reply, size))
            result = kIOReturnBadArgument;
        free(reply);
        if (result == KERN_SUCCESS) *outputStructSize = legacySize;
        return result;
    }
    if (selector == VP_IOS18_GPU_DEVICE_INFO && outputStruct && outputStructSize &&
        *outputStructSize == VP_IOS18_GPU_DEVICE_INFO_LEGACY) {
        uint8_t reply[VP_IOS18_GPU_DEVICE_INFO_MODERN] = {0};
        size_t size = sizeof(reply);
        kern_return_t result = vpCallMethod(connection, modern, input, inputCount, inputStruct, inputStructSize,
            output, outputCount, reply, &size);
        if (result != KERN_SUCCESS) return result;
        if (size != sizeof(reply)) return kIOReturnBadArgument;
        vpIOS18GPUDeviceInfoReply(outputStruct, reply);
        *outputStructSize = VP_IOS18_GPU_DEVICE_INFO_LEGACY;
        return KERN_SUCCESS;
    }
    return vpCallMethod(connection, modern, input, inputCount, inputStruct, inputStructSize,
        output, outputCount, outputStruct, outputStructSize);
}

static kern_return_t (*vpCallAsyncMethod)(mach_port_t, uint32_t, mach_port_t, uint64_t *, uint32_t,
    const uint64_t *, uint32_t, const void *, size_t, uint64_t *, uint32_t *, void *, size_t *);
static kern_return_t vpCallAsyncMethodHook(mach_port_t connection, uint32_t selector, mach_port_t wake,
    uint64_t *reference, uint32_t referenceCount, const uint64_t *input, uint32_t inputCount,
    const void *inputStruct, size_t inputStructSize, uint64_t *output, uint32_t *outputCount,
    void *outputStruct, size_t *outputStructSize) {
    uint32_t modern = selector;
    if (vpIsDevice(connection) && vpIOS18GPUSelector(selector, &modern) == VPIOS18GPUAnswerLocally)
        return KERN_SUCCESS;
    return vpCallAsyncMethod(connection, modern, wake, reference, referenceCount, input, inputCount,
        inputStruct, inputStructSize, output, outputCount, outputStruct, outputStructSize);
}

// MARK: - Install

void vpInstallIOS18GPUTransport(void) {
    if (getpid() == 1 || !strcmp(getprogname(), "xpcproxy") || access(VP_IOS18_GPU_MARKER, F_OK) != 0) return;
    // Device connections are only recorded once IOServiceOpen is detoured,
    // which happens last: until both call paths translate, none is.
    MISFixDetourResult call = MISFixDetour("IOConnectCallMethod", (void *)&IOConnectCallMethod,
        (void *)vpCallMethodHook, (void **)&vpCallMethod);
    MISFixDetourResult async = call ? call : MISFixDetour("IOConnectCallAsyncMethod",
        (void *)&IOConnectCallAsyncMethod, (void *)vpCallAsyncMethodHook, (void **)&vpCallAsyncMethod);
    MISFixDetourResult closing = async ? async : MISFixDetour("IOServiceClose", (void *)&IOServiceClose,
        (void *)vpServiceCloseHook, (void **)&vpServiceClose);
    MISFixDetourResult open = async ? async : MISFixDetour("IOServiceOpen", (void *)&IOServiceOpen,
        (void *)vpServiceOpenHook, (void **)&vpServiceOpen);
    if (call || async || closing || open)
        fprintf(stderr, "[ios18-gpu] %s transport: call=%s async=%s close=%s open=%s\n", getprogname(),
            MISFixDetourDescribe(call), MISFixDetourDescribe(async), MISFixDetourDescribe(closing),
            MISFixDetourDescribe(open));
}
