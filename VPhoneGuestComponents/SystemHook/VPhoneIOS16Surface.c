#include "VPhoneIOS16SurfaceReply.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach-o/loader.h>
#include <ptrauth.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern kern_return_t IOConnectCallMethod(mach_port_t, uint32_t,
    const uint64_t *, uint32_t, const void *, size_t, uint64_t *, uint32_t *, void *, size_t *);
extern kern_return_t IOConnectCallStructMethod(mach_port_t, uint32_t, const void *, size_t, void *, size_t *);

static kern_return_t vpFramebufferMethod(mach_port_t connection, uint32_t selector,
    const void *input, size_t inputSize, void *output, size_t *outputSize) {
    if (selector == 5 && input && (inputSize == 0x46C || inputSize == 0x560)) {
        uint8_t modern[0x560];
        vpIOS16FramebufferSwap(modern, input);
        return IOConnectCallStructMethod(connection, selector, modern, sizeof(modern), output, outputSize);
    }
    return IOConnectCallStructMethod(connection, selector, input, inputSize, output, outputSize);
}

static kern_return_t vpSurfaceMethod(mach_port_t connection, uint32_t selector,
    const uint64_t *scalarIn, uint32_t scalarCount, const void *input, size_t inputSize,
    uint64_t *scalarOut, uint32_t *outputCount, void *output, size_t *outputSize) {
    if (output && outputSize && *outputSize == VP_IOS16_SURFACE_REPLY) {
        uint8_t modern[VP_MODERN_SURFACE_REPLY] = {0};
        size_t size = sizeof(modern);
        kern_return_t result = IOConnectCallMethod(connection, selector, scalarIn, scalarCount,
            input, inputSize, scalarOut, outputCount, modern, &size);
        if (result != KERN_SUCCESS) return result;
        if (size != sizeof(modern) || !vpIOS16SurfaceReply(output, modern)) return 0xE00002C2;
        *outputSize = VP_IOS16_SURFACE_REPLY;
        return KERN_SUCCESS;
    }
    if (selector == 13 && output && outputSize && *outputSize == 0x18) {
        uint8_t modern[0x28] = {0};
        size_t size = sizeof(modern);
        kern_return_t result = IOConnectCallMethod(connection, selector, scalarIn, scalarCount,
            input, inputSize, scalarOut, outputCount, modern, &size);
        if (result != KERN_SUCCESS) return result;
        if (size != sizeof(modern) || !vpIOS16SurfaceInfo(output, modern)) return 0xE00002C2;
        *outputSize = 0x18;
        return KERN_SUCCESS;
    }
    return IOConnectCallMethod(connection, selector, scalarIn, scalarCount,
        input, inputSize, scalarOut, outputCount, output, outputSize);
}

typedef struct {
    char magic[8];
    int64_t displacement;
    uint8_t original[16];
    uint8_t prefix[8];
    uint8_t uuid[16];
} VPSurfaceMetadata;
_Static_assert(sizeof(VPSurfaceMetadata) == 56, "host metadata ABI");

static bool vpImageUUID(const struct mach_header_64 *header, const uint8_t uuid[16]) {
    if (!header || header->magic != MH_MAGIC_64 || header->sizeofcmds > 0x10000) return false;
    const uint8_t *cursor = (const uint8_t *)(header + 1), *end = cursor + header->sizeofcmds;
    for (uint32_t index = 0; index < header->ncmds; index++) {
        if ((size_t)(end - cursor) < sizeof(struct load_command)) return false;
        const struct load_command *command = (const void *)cursor;
        if (command->cmdsize < sizeof(*command) || command->cmdsize > (size_t)(end - cursor)) return false;
        if (command->cmd == LC_UUID && command->cmdsize == sizeof(struct uuid_command))
            return !memcmp(((const struct uuid_command *)command)->uuid, uuid, 16);
        cursor += command->cmdsize;
    }
    return false;
}

static void vpInstallAdapter(const char *marker, const char *imagePath,
    const char *anchorName, void *replacementMethod) {
    int file = open(marker, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (file < 0) return;
    VPSurfaceMetadata metadata;
    ssize_t size = read(file, &metadata, sizeof(metadata));
    uint8_t extra;
    bool complete = size == sizeof(metadata) && read(file, &extra, 1) == 0;
    close(file);
    if (!complete || memcmp(metadata.magic, "VPIS16\1\0", 8) ||
        metadata.displacement < 0 || metadata.displacement > 0x10000000) return;
    // Leave processes that do not use IOSurface alone. The framework is a
    // dependency of CoreAnimation and is mapped before their constructors run.
    void *image = dlopen(imagePath, RTLD_LAZY | RTLD_NOLOAD);
    if (!image) return;
    void *anchor = ptrauth_strip(dlsym(image, anchorName), ptrauth_key_function_pointer);
    Dl_info information = {0};
    if (!anchor || !dladdr(anchor, &information) || !vpImageUUID(information.dli_fbase, metadata.uuid)) {
        dlclose(image); return;
    }
    uint8_t *stub = (uint8_t *)anchor + metadata.displacement;
    if (memcmp(stub, metadata.original, sizeof(metadata.original))) { dlclose(image); return; }
    uint8_t replacement[16];
    memcpy(replacement, metadata.prefix, 8);
    uintptr_t method = (uintptr_t)ptrauth_strip(replacementMethod, ptrauth_key_function_pointer);
    memcpy(replacement + 8, &method, sizeof(method));
    vm_address_t page = (vm_address_t)stub & ~((vm_address_t)vm_page_size - 1);
    if ((vm_address_t)stub + sizeof(replacement) > page + vm_page_size) { dlclose(image); return; }

    // This is a process-private copy. Stop peer threads while execute is
    // removed; no shared-cache file or another process's code is modified.
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;
    bool ready = task_threads(mach_task_self(), &threads, &count) == KERN_SUCCESS;
    uint8_t *suspended = ready ? calloc(count, 1) : NULL;
    mach_port_t current = mach_thread_self();
    if (!suspended) ready = false;
    for (mach_msg_type_number_t index = 0; ready && index < count; index++) {
        if (threads[index] == current) continue;
        if (thread_suspend(threads[index]) != KERN_SUCCESS) ready = false;
        else suspended[index] = 1;
    }
    kern_return_t result = KERN_FAILURE;
    if (ready) {
        result = vm_protect(mach_task_self(), page, vm_page_size, false,
            VM_PROT_COPY | VM_PROT_READ | VM_PROT_WRITE);
        if (result == KERN_SUCCESS) {
            memcpy(stub, replacement, sizeof(replacement));
            sys_icache_invalidate(stub, sizeof(replacement));
            result = vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ | VM_PROT_EXECUTE);
            if (result != KERN_SUCCESS) {
                memcpy(stub, metadata.original, sizeof(metadata.original));
                sys_icache_invalidate(stub, sizeof(metadata.original));
                (void)vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ | VM_PROT_EXECUTE);
            }
        }
    }
    for (mach_msg_type_number_t index = 0; index < count; index++) {
        if (suspended && suspended[index]) (void)thread_resume(threads[index]);
        mach_port_deallocate(mach_task_self(), threads[index]);
    }
    mach_port_deallocate(mach_task_self(), current);
    if (threads) vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(*threads));
    free(suspended);
    dlclose(image);
    if (ready) fprintf(stderr, "[ios16-display] %s %s adapter: %d\n", getprogname(), anchorName, result);
}

void vpInstallSurfaceAdapter(void) {
    if (getpid() == 1 || !strcmp(getprogname(), "xpcproxy")) return;
    vpInstallAdapter("/usr/lib/vphone-ios16-surface",
        "/System/Library/Frameworks/IOSurface.framework/IOSurface", "IOSurfaceCreate", (void *)vpSurfaceMethod);
    vpInstallAdapter("/usr/lib/vphone-ios16-framebuffer",
        "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",
        "IOMobileFramebufferSwapEnd", (void *)vpFramebufferMethod);
}
