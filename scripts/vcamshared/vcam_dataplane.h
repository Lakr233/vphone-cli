/*
 * vcam_dataplane — shared CoreMedia data plane for the vphone virtual
 * camera. One implementation used by BOTH guest dylibs (libvcamcaptured
 * inside cameracaptured, libcamfix inside AVFoundation clients) and by
 * the host-side macOS test harness (tools/vcam_dataplane_test.c).
 *
 * The shared-memory frame is the single source of truth. Everything a
 * CoreMedia consumer can observe is derived from it:
 *
 *                 ┌── CVPixelBuffer (advertised pixel format)
 * shm frame ──────┼── CMVideoFormatDescription (codec 4cc == pixels,
 *                 │    clean aperture, pixel aspect, BT.709 colorimetry)
 *                 ├── CMSampleBuffer (host-frame timing, camera intrinsic
 *                 │    matrix, orientation, I-frame provenance)
 *                 └── RGB derivations (CGImage / JPEG / IOSurface)
 *
 * Pure C + CoreMedia/CoreVideo, no Foundation — compiles for iOS guest
 * (arm64e) and macOS host from the same source.
 */

#ifndef VCAM_DATAPLANE_H
#define VCAM_DATAPLANE_H

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <stdint.h>

// MARK: - constants

#define VCC_FMT_BGRA 0x42475241u  // 'BGRA' — 8-bit BGRA, 4 bytes/px
#define VCC_FMT_420V 0x34323076u  // '420v' — 8-bit 4:2:0, video range
#define VCC_FMT_420F 0x34323066u  // '420f' — 8-bit 4:2:0, full range

/*
 * Nominal horizontal field of view in degrees. Calibration knob: this one
 * constant drives BOTH the intrinsic matrix focal length attached to every
 * sample buffer AND the VideoFieldOfView key published on the
 * FigCaptureSourceVideoFormat, so the device story and the per-frame story
 * cannot drift apart. Calibrate against a physical device (capture + diff,
 * see the research doc) rather than trusting this default.
 */
#define VCC_VCAM_HFOV_DEG 63.0

/*
 * Colorimetry we produce for 4:2:0 output: BT.709 primaries / transfer /
 * matrix, video range (studio swing, Y [16,235], C [16,240]). Everything
 * tagged on the pixel buffer and format description matches what the
 * converter actually produces — no lies between tag and bits.
 */
#define VCC_VCAM_FRAMERATE_DEFAULT 30.0

// MARK: - frame descriptor (the shm frame, deserialized)

typedef struct {
  uint32_t width;
  uint32_t height;
  uint32_t bytes_per_row;   // plane-0 stride
  uint32_t bytes_per_row1;  // plane-1 stride (420v in); 0 → 2*(width/2)
  uint32_t pixel_format;    // VCC_FMT_* fourcc of `pixels`
  uint64_t timestamp_ns;    // host wall-clock ns for this frame
  uint64_t frame_index;     // host frame counter
  const uint8_t *pixels;    // plane 0 followed by plane 1 (planar formats)
  size_t pixels_length;
} vcc_frame_desc_t;

// MARK: - timing

/*
 * Converts host frame timestamps into a monotonic guest PTS timeline with
 * realistic per-frame durations. Host epoch-ns values are remapped to a
 * stream-local 0-based timeline (CMTime values must stay well below 2^53
 * for downstream float conversions to be lossless). Durations come from
 * the observed inter-frame delta and fall back to the nominal 30 fps when
 * deltas are implausible (bursts, stalls, duplicate ticks).
 */
typedef struct {
  int have_last;
  uint64_t anchor_ns;
  uint64_t last_host_ns;
  uint64_t last_pts_ns;
  uint64_t last_dur_ns;
} vcc_timing_state_t;

void vcc_timing_init(vcc_timing_state_t *st);

// Strictly-increasing by construction; safe to call from one thread only.
void vcc_timing_advance(vcc_timing_state_t *st, uint64_t host_ts_ns,
                        CMTime *out_pts, CMTime *out_dur);

// MARK: - pixel buffers

// Returns 1 for 4:2:0 planar formats we know how to produce/consume.
int vcc_is_planar_yuv(uint32_t fourcc);

/*
 * Build a CVPixelBuffer in `fmt_out` from the frame. Handles
 *   BGRA → BGRA  (row-stride copy)
 *   BGRA → 420v  (BT.709 video-range conversion, 2x2 chroma averaging)
 *   420v → 420v  (plane copy)
 *   420v → BGRA  (BT.709 video-range inverse)
 * The returned buffer carries the camera image-buffer attachments:
 * BT.709 YCbCr matrix (420v only) / primaries / transfer, clean aperture
 * (full frame), pixel aspect 1:1. Caller releases. Returns NULL on failure.
 */
CVPixelBufferRef vcc_pixel_buffer_from_frame(const vcc_frame_desc_t *frame,
                                             uint32_t fmt_out);

/*
 * Decode the frame to tightly-packed 8-bit BGRA (w*4 bytes per row, no
 * padding) for RGB consumers (CGImage, JPEG, IOSurface staging). Caller
 * frees *out_bytes. Accepts BGRA and 420v input frames.
 */
int vcc_bgra_bytes_from_frame(const vcc_frame_desc_t *frame,
                              uint8_t **out_bytes, uint32_t *out_bpr);

/*
 * One pixel buffer -> CGImage path for every RGB consumer (preview pump,
 * photo tagging). Handles BGRA (zero-copy provider over the locked base)
 * and 420v (converts via the BT.709 inverse). Returns a retained CGImage
 * or NULL.
 */
CGImageRef vcc_cgimage_from_pixel_buffer(CVPixelBufferRef pb);

// MARK: - format description

/*
 * CMVideoFormatDescription for the pixel buffer, carrying the same camera
 * story as the bits. Mechanism (verified against CoreMedia on macOS):
 *   - the pixel buffer's camera attachments (YCbCr matrix, primaries,
 *     transfer, clean aperture, pixel aspect) are folded into the
 *     description's extensions by CMVideoFormatDescriptionCreateForImageBuffer
 *   - the description still passes CMVideoFormatDescriptionMatchesImageBuffer
 *     (hand-built extension dictionaries do NOT — CoreMedia rejects any
 *     extension set that isn't the buffer-derived spec)
 * This replaces the naked CreateForImageBuffer shortcut the PR used, which
 * produced an extension-less description that carried no camera metadata.
 */
OSStatus vcc_format_description_create_for_pb(
    CVPixelBufferRef pb, CMVideoFormatDescriptionRef *out_desc);

// MARK: - sample buffer

/*
 * Wrap `pb` + `desc` in a CMSampleBuffer with the camera metadata layer:
 *   - timing (pts + duration, from vcc_timing_advance)
 *   - kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix (CFData,
 *     column-major matrix_float3x3, focal length derived from
 *     VCC_VCAM_HFOV_DEG and the frame dimensions)
 *   - kCGImagePropertyOrientation ("1" — landscape-native frames, exactly
 *     what the buffer contains)
 *   - kCMSampleAttachmentKey_DependsOnOthers = false (each frame is a
 *     self-contained I-frame, like real camera output)
 * Returns a retained buffer or NULL.
 */
CMSampleBufferRef vcc_cmsb_create(CVPixelBufferRef pb,
                                  CMVideoFormatDescriptionRef desc,
                                  CMTime pts, CMTime dur,
                                  uint32_t w, uint32_t h);

/*
 * Full chain: frame → pixel buffer (fmt_out) → format description →
 * sample buffer with metadata. This is the one call both dylibs use.
 * `timing` advances only on success. Returns a retained buffer or NULL.
 */
CMSampleBufferRef vcc_cmsb_from_frame(const vcc_frame_desc_t *frame,
                                      uint32_t fmt_out,
                                      vcc_timing_state_t *timing);

#endif /* VCAM_DATAPLANE_H */
