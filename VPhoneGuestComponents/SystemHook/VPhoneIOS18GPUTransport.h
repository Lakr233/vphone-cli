#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// iOS 18's IOGPU.framework and paravirtual Metal driver against cloudOS
// 26.1's IOGPUFamily and AppleParavirtGPU user clients. Measured by diffing
// every IOConnectCall site of the 18.6.2 (22G100) and 26.1 (23B85) IOGPU
// builds; see Research/Guest/ios18_gpu_transport.md.

// The device user client, opened as `1 | (api << 16)`.
enum { VP_IOS18_GPU_DEVICE_CLIENT = 1 };

typedef enum {
    VPIOS18GPUForward,       // call the kernel with the selector as given
    VPIOS18GPURenumbered,    // call the kernel with the returned selector
    VPIOS18GPUAnswerLocally, // 26.1 has no such method; report success
} VPIOS18GPUSelectorAction;

// 26.1 removed method 6 (the client's API name, whose result IOGPU ignores)
// and moved methods 7..255 down by one. Driver methods from 256 are unchanged.
VPIOS18GPUSelectorAction vpIOS18GPUSelector(uint32_t legacy, uint32_t *modern);

// iOS 18's resource-create method (9, 8 on 26.1). Its reply gained eight
// bytes at 0x18; the 0x50-byte header and the driver's tail are otherwise
// unchanged.
enum {
    VP_IOS18_GPU_RESOURCE_CREATE = 9,
    VP_IOS18_GPU_RESOURCE_HEADER = 0x50,
    VP_IOS18_GPU_RESOURCE_GROWTH = 8,
};
bool vpIOS18GPUResourceReply(uint8_t *legacy, size_t legacySize, const uint8_t *modern, size_t modernSize);

// AppleParavirtGPU's device-info method. Each of its two blocks gained fields
// at its end: 0xd8 -> 0xdc and 0x34 -> 0x3c.
enum {
    VP_IOS18_GPU_DEVICE_INFO = 265,
    VP_IOS18_GPU_DEVICE_INFO_LEGACY = 0x10c,
    VP_IOS18_GPU_DEVICE_INFO_MODERN = 0x118,
};
void vpIOS18GPUDeviceInfoReply(uint8_t legacy[VP_IOS18_GPU_DEVICE_INFO_LEGACY],
    const uint8_t modern[VP_IOS18_GPU_DEVICE_INFO_MODERN]);
