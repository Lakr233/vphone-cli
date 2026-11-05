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
