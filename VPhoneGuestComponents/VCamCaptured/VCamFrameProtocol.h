#ifndef VPHONE_VCAM_FRAME_PROTOCOL_H
#define VPHONE_VCAM_FRAME_PROTOCOL_H

#include <stdint.h>
#include <stddef.h>

// All guest camera runtime data lives in the mobile media area, regardless
// of how the VM was installed.
#define VPHONE_VCAM_DIRECTORY "/var/mobile/Media/SimulatedCamera"
#define VPHONE_VCAM_SHM_PATH VPHONE_VCAM_DIRECTORY "/vphone-vcam-frame.shm"
#define VPHONE_VCAM_DAEMON_LOG_PATH VPHONE_VCAM_DIRECTORY "/vphone-vcam.log"
#define VPHONE_VCAM_CAPTURE_LOG_PATH VPHONE_VCAM_DIRECTORY "/vcamcaptured.log"
#define VPHONE_VCAM_APP_LOG_PATH VPHONE_VCAM_DIRECTORY "/camfix.log"
#define VPHONE_VCAM_SYNTH_PHOTO_PATH VPHONE_VCAM_DIRECTORY "/vphone-synth-photo.bgra"
#define VPHONE_VCAM_NOTIFY_NAME "com.vphone.vcam.frame"
#define VPHONE_VCAM_SHM_HEADER_SIZE 64
#define VPHONE_VCAM_SHM_MAX_PIXELS (8 * 1024 * 1024)
#define VPHONE_VCAM_SHM_TOTAL_SIZE (VPHONE_VCAM_SHM_HEADER_SIZE + VPHONE_VCAM_SHM_MAX_PIXELS)

typedef struct __attribute__((packed)) {
  uint64_t seq __attribute__((aligned(8)));
  uint32_t width;
  uint32_t height;
  uint32_t bytes_per_row;
  uint32_t pixel_format;
  uint32_t _reserved;
  uint64_t timestamp_ns;
  uint64_t frame_index;
  uint32_t pixels_length;
  uint32_t _pad;
} vphone_vcam_shm_header_t;

_Static_assert(offsetof(vphone_vcam_shm_header_t, timestamp_ns) == 28, "camera frame timestamp offset");
_Static_assert(offsetof(vphone_vcam_shm_header_t, pixels_length) == 44, "camera frame length offset");
_Static_assert(sizeof(vphone_vcam_shm_header_t) <= VPHONE_VCAM_SHM_HEADER_SIZE, "camera frame header capacity");

#endif
