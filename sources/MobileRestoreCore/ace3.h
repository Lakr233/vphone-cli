#ifndef IDEVICERESTORE_ACE3_H
#define IDEVICERESTORE_ACE3_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>
#include <plist/plist.h>

int ace3_create_binary(const void* uarp_fw, size_t uarp_size, uint64_t bdid, unsigned int prev, plist_t tss, void** bin_out, size_t* bin_size);

#ifdef __cplusplus
}
#endif

#endif
