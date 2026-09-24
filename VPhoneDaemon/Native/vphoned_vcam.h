/*
 * vphoned_vcam — receive virtual-camera frames over vsock and publish
 * them into a shared-memory file that libvcamcaptured (inside
 * cameracaptured) maps for read access.
 *
 * vphoned runs as root and has AF_VSOCK access; the cameracaptured
 * sandbox does not, so libvcamcaptured can't open its own vsock socket.
 * Putting the listener here is the cleanest workaround.
 */

#ifndef VPHONED_VCAM_H
#define VPHONED_VCAM_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Path of the shared frame file (read by libvcamcaptured).
 * Lives under /var/jb so cameracaptured's sandbox allows reads.
 */
#ifndef VPHONED_VCAM_SHM_PATH
#define VPHONED_VCAM_SHM_PATH                                                  \
  "/var/jb/var/mobile/Library/vphone-vcam-frame.shm"
#endif
#ifndef VPHONED_VCAM_VSOCK_PORT
#define VPHONED_VCAM_VSOCK_PORT 1338
#endif
#ifndef VPHONED_VCAM_NOTIFY_NAME
#define VPHONED_VCAM_NOTIFY_NAME "com.vphone.vcam.frame"
#endif

/* Shared-memory layout. seq increments by 2 per frame; odd values mean
 * a write is in progress. Readers re-check seq after copying to detect
 * mid-write tearing. */
typedef struct __attribute__((packed)) {
  uint64_t seq;
  uint32_t width;
  uint32_t height;
  uint32_t bytes_per_row;
  uint32_t pixel_format;  /* 4cc */
  uint32_t _reserved;
  uint64_t timestamp_ns;
  uint64_t frame_index;
  uint32_t pixels_length;
  uint32_t _pad;
  /* pixels start at offset 64; capacity = total mmap size - 64. */
} vphoned_vcam_shm_header_t;

#define VPHONED_VCAM_SHM_HEADER_SIZE 64
#define VPHONED_VCAM_SHM_MAX_PIXELS (8 * 1024 * 1024)  /* 8 MiB */
#define VPHONED_VCAM_SHM_TOTAL_SIZE                                            \
  (VPHONED_VCAM_SHM_HEADER_SIZE + VPHONED_VCAM_SHM_MAX_PIXELS)

/* Starts the listener on a background thread. Idempotent. */
void vp_vcam_start(void);

#ifdef __cplusplus
}
#endif

#endif /* VPHONED_VCAM_H */
