#include "VPhoneIOS16SurfaceReply.h"
#include <string.h>

void vpIOS16FramebufferSwap(uint8_t modern[0x560], const uint8_t legacy[0x46C]) {
    memset(modern, 0, 0x560);
    // Debug/parameter pointers keep their positions. Nine new event values
    // precede the frame token, and nine new event ports precede subtitle data.
    memcpy(modern, legacy, 0x50);
    memcpy(modern + 0x98, legacy + 0x50, 0x210);
    memcpy(modern + 0x2CC, legacy + 0x260, 0x86);
    // SwapSetLayer's video/EDR flags split in the newer packed suffix. Only
    // copy fields identified by the paired 20G81/21H16 setter implementations.
    modern[0x353] = legacy[0x2E6];
    memcpy(modern + 0x384, legacy + 0x30C, 0x57); // SwapSetParams types 1/2
    for (unsigned plane = 0; plane < 4; plane++) modern[0x503 + plane] = legacy[0x467 + plane];
}

static bool narrow(uint8_t *destination, const uint8_t *source) {
    uint64_t wide;
    memcpy(&wide, source, sizeof(wide));
    if (wide > UINT32_MAX) return false;
    uint32_t value = (uint32_t)wide;
    memcpy(destination, &value, sizeof(value));
    return true;
}

bool vpIOS16SurfaceInfo(uint8_t legacy[0x18], const uint8_t modern[0x28]) {
    memcpy(legacy, modern, 12);
    if (!narrow(legacy + 12, modern + 16) || !narrow(legacy + 16, modern + 24)) return false;
    memcpy(legacy + 20, modern + 32, 4);
    return true;
}

bool vpIOS16SurfaceReply(uint8_t legacy[VP_IOS16_SURFACE_REPLY],
    const uint8_t modern[VP_MODERN_SURFACE_REPLY]) {
    uint32_t planes;
    memcpy(&planes, modern + 0x58, sizeof(planes));
    if (planes > 20) return false;
    memset(legacy, 0, VP_IOS16_SURFACE_REPLY);
    // Mapped addresses and surface ID retain their layout. Six dimensions and
    // strides widen to uint64_t, increasing the header by 0x20 and each plane
    // by 0x18. Keep every other metadata byte, including component descriptions.
    memcpy(legacy, modern, 0x1C);
    for (unsigned field = 0; field < 5; field++)
        if (!narrow(legacy + 0x1C + field * 4, modern + 0x20 + field * 8)) return false;
    memcpy(legacy + 0x30, modern + 0x48, 4);
    if (!narrow(legacy + 0x34, modern + 0x50)) return false;
    memcpy(legacy + 0x38, modern + 0x58, 0x30);
    // Zero planes denotes the implicit packed plane. Unused records are not
    // initialized by the driver, and must not be inspected or narrowed.
    for (unsigned plane = 0; plane < (planes ? planes : 1); plane++) {
        uint8_t *out = legacy + 0x68 + plane * 0x80;
        const uint8_t *in = modern + 0x88 + plane * 0x98;
        for (unsigned field = 0; field < 6; field++)
            if (!narrow(out + field * 4, in + field * 8)) return false;
        memcpy(out + 0x18, in + 0x30, 0x68);
    }
    return true;
}
