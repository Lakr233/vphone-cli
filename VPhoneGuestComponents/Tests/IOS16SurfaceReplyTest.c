#include "VPhoneIOS16SurfaceReply.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void put64(uint8_t *buffer, size_t offset, uint64_t value) { memcpy(buffer + offset, &value, 8); }
static uint32_t get32(const uint8_t *buffer, size_t offset) { uint32_t value; memcpy(&value, buffer + offset, 4); return value; }

int main(void) {
    uint8_t modern[VP_MODERN_SURFACE_REPLY] = {0}, old[VP_IOS16_SURFACE_REPLY];
    put64(modern, 0, 0x12345678000); // mapped address must stay 64-bit
    put64(modern, 0x20, 12105216); put64(modern, 0x28, 1179);
    put64(modern, 0x30, 2556); put64(modern, 0x38, 4736);
    put64(modern, 0x88, 1179); put64(modern, 0x90, 2556);
    memset(modern + 0x88 + 0x98, 0xFF, sizeof(modern) - 0x88 - 0x98);
    assert(vpIOS16SurfaceReply(old, modern)); // unused planes must not overflow
    uint64_t address; memcpy(&address, old, 8); assert(address == 0x12345678000);
    assert(get32(old, 0x1C) == 12105216 && get32(old, 0x20) == 1179);
    assert(get32(old, 0x24) == 2556 && get32(old, 0x28) == 4736);
    assert(get32(old, 0x68) == 1179 && get32(old, 0x6C) == 2556);

    memset(modern, 0, sizeof(modern));
    uint32_t planes = 20; memcpy(modern + 0x58, &planes, 4);
    for (unsigned index = 0; index < planes; index++) {
        put64(modern, 0x88 + index * 0x98, 640 >> (index % 3));
        modern[0x88 + index * 0x98 + 0x97] = (uint8_t)(index + 1);
    }
    assert(vpIOS16SurfaceReply(old, modern));
    for (unsigned index = 0; index < planes; index++) {
        assert(get32(old, 0x68 + index * 0x80) == (640U >> (index % 3)));
        assert(old[0x68 + index * 0x80 + 0x7F] == index + 1);
    }
    put64(modern, 0x88 + 19 * 0x98 + 5 * 8, UINT64_C(1) << 32);
    assert(!vpIOS16SurfaceReply(old, modern));
    planes = 21; memcpy(modern + 0x58, &planes, 4); assert(!vpIOS16SurfaceReply(old, modern));
    memset(modern, 0, sizeof(modern)); put64(modern, 0x20, UINT64_C(1) << 32);
    assert(!vpIOS16SurfaceReply(old, modern));

    uint8_t info[0x28] = {0}, infoOld[0x18];
    put64(info, 16, 0x4000); put64(info, 24, 0x4000); info[32] = 1; info[34] = 1;
    assert(vpIOS16SurfaceInfo(infoOld, info));
    assert(get32(infoOld, 12) == 0x4000 && get32(infoOld, 16) == 0x4000);
    assert(infoOld[20] == 1 && infoOld[22] == 1);
    put64(info, 24, UINT64_C(1) << 32); assert(!vpIOS16SurfaceInfo(infoOld, info));
    uint8_t swapOld[0x46C] = {0}, swapNew[0x560];
    put64(swapOld, 0x38, 0x123456789); // unshifted parameter pointer
    uint32_t token = 3469, surface = 10, width = 1179, height = 2556;
    memcpy(swapOld + 0x50, &token, 4); memcpy(swapOld + 0x54, &surface, 4);
    memcpy(swapOld + 0x6C, &width, 4); memcpy(swapOld + 0x70, &height, 4);
    swapOld[0x2CB] = 1; swapOld[0x2E6] = 1; swapOld[0x30C] = 1; swapOld[0x467] = 1;
    vpIOS16FramebufferSwap(swapNew, swapOld);
    memcpy(&address, swapNew + 0x38, 8); assert(address == 0x123456789);
    assert(get32(swapNew, 0x98) == token && get32(swapNew, 0x9C) == surface);
    assert(get32(swapNew, 0xB4) == width && get32(swapNew, 0xB8) == height);
    assert(swapNew[0x337] == 1 && swapNew[0x353] == 1 && swapNew[0x384] == 1 && swapNew[0x503] == 1);
    for (unsigned index = 0x50; index < 0x98; index++) assert(swapNew[index] == 0);
    for (unsigned index = 0x2A8; index < 0x2CC; index++) assert(swapNew[index] == 0);
    for (unsigned index = 0x508; index < 0x560; index++) assert(swapNew[index] == 0);
    puts("IOSurface reply conversion: packed plane, 20 planes, metadata, overflow, capabilities passed");
    return 0;
}
