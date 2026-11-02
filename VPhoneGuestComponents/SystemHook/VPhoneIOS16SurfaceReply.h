#pragma once
#include <stdbool.h>
#include <stdint.h>

enum { VP_IOS16_SURFACE_REPLY = 0xA68, VP_MODERN_SURFACE_REPLY = 0xC68 };
bool vpIOS16SurfaceReply(uint8_t legacy[VP_IOS16_SURFACE_REPLY],
    const uint8_t modern[VP_MODERN_SURFACE_REPLY]);
bool vpIOS16SurfaceInfo(uint8_t legacy[0x18], const uint8_t modern[0x28]);
void vpIOS16FramebufferSwap(uint8_t modern[0x560], const uint8_t legacy[0x46C]);
