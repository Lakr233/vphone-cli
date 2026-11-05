#include "VPhoneIOS18GPUTransport.h"
#include <string.h>

VPIOS18GPUSelectorAction vpIOS18GPUSelector(uint32_t legacy, uint32_t *modern) {
    *modern = legacy;
    if (legacy == 6) return VPIOS18GPUAnswerLocally;
    if (legacy < 7 || legacy > 255) return VPIOS18GPUForward;
    *modern = legacy - 1;
    return VPIOS18GPURenumbered;
}

bool vpIOS18GPUResourceReply(uint8_t *legacy, size_t legacySize, const uint8_t *modern, size_t modernSize) {
    if (legacySize < VP_IOS18_GPU_RESOURCE_HEADER || modernSize != legacySize + VP_IOS18_GPU_RESOURCE_GROWTH)
        return false;
    memcpy(legacy, modern, 0x18);
    memcpy(legacy + 0x18, modern + 0x18 + VP_IOS18_GPU_RESOURCE_GROWTH, legacySize - 0x18);
    return true;
}

void vpIOS18GPUDeviceInfoReply(uint8_t legacy[VP_IOS18_GPU_DEVICE_INFO_LEGACY],
    const uint8_t modern[VP_IOS18_GPU_DEVICE_INFO_MODERN]) {
    memcpy(legacy, modern, 0xd8);
    memcpy(legacy + 0xd8, modern + 0xdc, 0x34);
}

bool vpIOS18GPUSubmitEntries(uint8_t *modern, const uint8_t *legacy, size_t legacySize,
    const uint64_t scalars[VP_IOS18_GPU_SUBMIT_SCALARS_IN]) {
    uint64_t count = scalars[2];
    if (scalars[3] != VP_IOS18_GPU_SUBMIT_ENTRY || count == 0 || count > VP_IOS18_GPU_SUBMIT_MAX_ENTRIES ||
        legacySize != count * VP_IOS18_GPU_SUBMIT_ENTRY)
        return false;
    memset(modern, 0, count * VP_IOS18_GPU_SUBMIT_ENTRY_MODERN);
    for (uint64_t index = 0; index < count; index++)
        memcpy(modern + index * VP_IOS18_GPU_SUBMIT_ENTRY_MODERN, legacy + index * VP_IOS18_GPU_SUBMIT_ENTRY,
            VP_IOS18_GPU_SUBMIT_ENTRY);
    return true;
}
