//
//  multicast_bytecopy.c
//  Dopamine
//
//  Created by Lars Fröder on 27.04.24.
//

#include <stdio.h>
#include "exploit/exploit.h"
#include "exploit/kernel_rw.h"
#import <libjailbreak/primitives_external.h>
#import <libjailbreak/info.h>

#define kread_from_method(type, method)                                             \
    do {                                                                            \
        volatile type* type_base = (volatile type*)(uaddr);                         \
        uint64_t type_size = ((size) / (sizeof(type)));                                  \
        for (uint64_t type_offset = 0; type_offset < type_size; type_offset++) {         \
            type type_value = method(kaddr + (type_offset * sizeof(type)));    \
            type_base[type_offset] = type_value;                                    \
        }                                                                           \
    } while (0)

#define kwrite_from_method(type, method)                                       \
    do {                                                                       \
        volatile type* type_base = (volatile type*)(uaddr);                    \
        uint64_t type_size = ((size) / (sizeof(type)));                             \
        for (uint64_t type_offset = 0; type_offset < type_size; type_offset++) {    \
            type type_value = type_base[type_offset];                          \
            method( kaddr + (type_offset * sizeof(type)), type_value);     \
        }                                                                      \
    } while (0)

int kreadbuf(uint64_t kaddr, void* uaddr, size_t size)
{
    switch (size) {
        case sizeof(uint8_t): {
            uint32_t r = kread32(kaddr);
            *(uint8_t *)uaddr = (uint8_t)r;
            break;
        }
        case sizeof(uint16_t): {
            uint32_t r = kread32(kaddr);
            *(uint16_t *)uaddr = (uint16_t)r;
            break;
        }
        default:
            kread_from_method(uint32_t, kread32);
            break;
    }
    return 0;
}

int kwritebuf(uint64_t kaddr, const void* uaddr, size_t size)
{
    switch (size) {
        case sizeof(uint8_t): {
            uint8_t r[8] = { 0 };
            kreadbuf(kaddr, r, sizeof(r));
            r[0] = *(uint8_t *)uaddr;
            kwrite64(kaddr, *(uint64_t *)r);
            break;
        }
        case sizeof(uint16_t): {
            uint16_t r[4] = { 0 };
            kreadbuf(kaddr, r, sizeof(r));
            r[0] = *(uint16_t *)uaddr;
            kwrite64(kaddr, *(uint64_t *)r);
            break;
        }
        default:
            kwrite_from_method(uint32_t, kwrite32);
            break;
    }
    return 0;
}

int exploit_init(const char *flavor)
{
    uint64_t kernelBase = 0;
    int r = exploit_get_krw_and_kernel_base(&kernelBase);
    if (r != 0) return r;
    
    gPrimitives.krwMinSafeReadSize = 0;
    gPrimitives.kreadbuf = kreadbuf;
    gPrimitives.kwritebuf = kwritebuf;
    gSystemInfo.kernelConstant.slide = kernelBase - kconstant(staticBase);
    
    return 0;
}


int exploit_deinit(void)
{
    if (gPrimitives.kreadbuf == kreadbuf) {
        gPrimitives.kreadbuf = NULL;
    }
    if (gPrimitives.kwritebuf == kwritebuf) {
        gPrimitives.kwritebuf = NULL;
    }

    exploitation_cleanup();
    return 0;
}
