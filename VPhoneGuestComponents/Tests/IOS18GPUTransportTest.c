#include "VPhoneIOS18GPUTransport.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    uint32_t modern;
    // Below the removed method, and the driver's own methods, pass through.
    for (uint32_t selector = 0; selector < 6; selector++) {
        assert(vpIOS18GPUSelector(selector, &modern) == VPIOS18GPUForward && modern == selector);
    }
    assert(vpIOS18GPUSelector(6, &modern) == VPIOS18GPUAnswerLocally);
    // Command queue create, resource create and the last base method measured.
    assert(vpIOS18GPUSelector(7, &modern) == VPIOS18GPURenumbered && modern == 6);
    assert(vpIOS18GPUSelector(9, &modern) == VPIOS18GPURenumbered && modern == 8);
    assert(vpIOS18GPUSelector(0x37, &modern) == VPIOS18GPURenumbered && modern == 0x36);
    assert(vpIOS18GPUSelector(255, &modern) == VPIOS18GPURenumbered && modern == 254);
    for (uint32_t selector = 256; selector < 270; selector++) {
        assert(vpIOS18GPUSelector(selector, &modern) == VPIOS18GPUForward && modern == selector);
    }

    // The new eight bytes at 0x18 are dropped; both sides of them are kept.
    uint8_t wide[0x60], narrow[0x58];
    for (size_t index = 0; index < sizeof(wide); index++) wide[index] = (uint8_t)index;
    memset(narrow, 0xEE, sizeof(narrow));
    assert(vpIOS18GPUResourceReply(narrow, sizeof(narrow), wide, sizeof(wide)));
    for (size_t index = 0; index < 0x18; index++) assert(narrow[index] == index);
    for (size_t index = 0x18; index < sizeof(narrow); index++) assert(narrow[index] == index + 8);
    assert(!vpIOS18GPUResourceReply(narrow, sizeof(narrow), wide, sizeof(wide) - 1));
    assert(!vpIOS18GPUResourceReply(narrow, 0x4F, wide, 0x4F + 8));

    uint8_t info[VP_IOS18_GPU_DEVICE_INFO_MODERN], legacy[VP_IOS18_GPU_DEVICE_INFO_LEGACY];
    for (size_t index = 0; index < sizeof(info); index++) info[index] = (uint8_t)(index * 7);
    vpIOS18GPUDeviceInfoReply(legacy, info);
    for (size_t index = 0; index < 0xd8; index++) assert(legacy[index] == info[index]);
    for (size_t index = 0; index < 0x34; index++) assert(legacy[0xd8 + index] == info[0xdc + index]);

    puts("IOS18GPUTransportTest: ok");
    return 0;
}
