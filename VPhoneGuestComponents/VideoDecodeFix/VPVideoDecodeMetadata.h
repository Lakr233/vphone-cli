#ifndef VP_VIDEO_DECODE_METADATA_H
#define VP_VIDEO_DECODE_METADATA_H

#include <stdint.h>

// Written by DyldSharedCacheVideoDecodeMetadata after semantic discovery.
// Offsets are relative to this exact framework's Mach-O header, never the
// global shared-cache slide. All fields are little endian.
enum {
    VPVideoInstallHandler,
    VPVideoRemoveHandler,
    VPVideoDecoderHandler,
    VPVideoDispatchBlock,
    VPVideoDispatchReturn,
    VPVideoOutputCallback,
    VPVideoCreateSession,
    VPVideoInvalidateDecoder,
    VPVideoSendSync,
    VPVideoReplyWaitReturn,
    VPVideoMessageInfo,
    VPVideoEntryCount
};

typedef struct {
    uint64_t offset;
    uint8_t original[16];
} VPVideoDecodeEntry;

typedef struct {
    char magic[8];
    uint8_t imageUUID[16];
    uint32_t lockOffset;
    uint32_t uuidOffset;
    uint32_t messageOffset;
    uint32_t entryCount;
    VPVideoDecodeEntry entries[VPVideoEntryCount];
} VPVideoDecodeMetadata;

_Static_assert(sizeof(VPVideoDecodeEntry) == 24, "video entry metadata ABI");
_Static_assert(sizeof(VPVideoDecodeMetadata) == 304, "video metadata ABI");

#endif
