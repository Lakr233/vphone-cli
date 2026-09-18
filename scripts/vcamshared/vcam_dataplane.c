/*
 * vcam_dataplane — see vcam_dataplane.h for the design contract.
 */

#include "vcam_dataplane.h"

#include <dlfcn.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

// MARK: - constants (private)

#define VCC_DUR_DEFAULT_NS 33333333ull  // 1/30 s
#define VCC_DUR_MIN_NS 4000000ull       // 4 ms — below this, treat as burst
#define VCC_DUR_MAX_NS 200000000ull     // 200 ms — above this, treat as stall
#define VCC_PARAM_ERR (-50)             // paramErr, avoids Carbon include

// kCGImagePropertyOrientation lives in ImageIO; the key string is stable.
// Resolve the public constant when available; the literal fallback keeps us
// independent of ImageIO link order.
static CFStringRef vcc_orientation_key(void) {
  CFStringRef *slot =
      (CFStringRef *)dlsym(RTLD_DEFAULT, "kCGImagePropertyOrientation");
  return (slot && *slot) ? *slot : CFSTR("Orientation");
}

// MARK: - timing

void vcc_timing_init(vcc_timing_state_t *st) {
  memset(st, 0, sizeof(*st));
}

void vcc_timing_advance(vcc_timing_state_t *st, uint64_t host_ts_ns,
                        CMTime *out_pts, CMTime *out_dur) {
  uint64_t pts;
  if (!st->have_last) {
    // First frame: anchor the stream-local timeline at zero.
    st->anchor_ns = host_ts_ns;
    st->last_host_ns = host_ts_ns;
    st->last_dur_ns = VCC_DUR_DEFAULT_NS;
    st->have_last = 1;
    pts = 0;
  } else {
    uint64_t delta = host_ts_ns - st->last_host_ns;  // wraps safely
    if (delta >= VCC_DUR_MIN_NS && delta <= VCC_DUR_MAX_NS) {
      st->last_dur_ns = delta;
    } else {
      st->last_dur_ns = VCC_DUR_DEFAULT_NS;
    }
    if (host_ts_ns > st->last_host_ns) {
      st->last_host_ns = host_ts_ns;
    }
    // Stream-local PTS: host epoch remapped by the anchor. Never go
    // backwards; a non-advancing host clock still produces an advancing
    // timeline (the viewfinder jitter buffer drops non-advancing PTS).
    pts = host_ts_ns - st->anchor_ns;
    if (pts <= st->last_pts_ns) {
      pts = st->last_pts_ns + st->last_dur_ns;
    }
  }
  st->last_pts_ns = pts;

  if (out_pts) {
    *out_pts = CMTimeMake((int64_t)pts, 1000000000);
  }
  if (out_dur) {
    *out_dur = CMTimeMake((int64_t)st->last_dur_ns, 1000000000);
  }
}

// MARK: - pixel conversion

int vcc_is_planar_yuv(uint32_t fourcc) {
  return fourcc == VCC_FMT_420V || fourcc == VCC_FMT_420F;
}

static inline uint8_t vcc_clamp8(int v) {
  if (v < 0) return 0;
  if (v > 255) return 255;
  return (uint8_t)v;
}

// BT.709 video-range encode of one pixel. Coefficients (scaled by 256):
//   Y  = 16  + (47R + 157G + 16B) >> 8     [16..235]
//   Cb = 128 + (-26R - 87G + 113B) >> 8    [16..240]
//   Cr = 128 + (112R - 94G - 18B) >> 8     [16..240]
static inline void vcc_rgb_to_yuv709v(uint8_t r, uint8_t g, uint8_t b,
                                      uint8_t *y, uint8_t *cb, uint8_t *cr) {
  int yy = 16 + (((47 * r + 157 * g + 16 * b) + 128) >> 8);
  int cu = 128 + (((-26 * r - 87 * g + 113 * b) + 128) >> 8);
  int cv = 128 + (((112 * r - 94 * g - 18 * b) + 128) >> 8);
  if (yy < 16) yy = 16; else if (yy > 235) yy = 235;
  if (cu < 16) cu = 16; else if (cu > 240) cu = 240;
  if (cv < 16) cv = 16; else if (cv > 240) cv = 240;
  *y = (uint8_t)yy;
  *cb = (uint8_t)cu;
  *cr = (uint8_t)cv;
}

// BT.709 video-range decode.
static inline void vcc_yuv709v_to_rgb(uint8_t y, uint8_t cb, uint8_t cr,
                                      uint8_t *r, uint8_t *g, uint8_t *b) {
  int yy = (int)y - 16;
  int u = (int)cb - 128;
  int v = (int)cr - 128;
  int rr = (298 * yy + 459 * v + 128) >> 8;
  int gg = (298 * yy - 55 * u - 136 * v + 128) >> 8;
  int bb = (298 * yy + 541 * u + 128) >> 8;
  *r = vcc_clamp8(rr);
  *g = vcc_clamp8(gg);
  *b = vcc_clamp8(bb);
}

// BGRA (stride src_bpr) → interleaved 420v planes. Y gets per-pixel stride
// dst_y_bpr; CbCr gets 2-byte macropixels at dst_c_bpr.
static void vcc_bgra_to_420v(const uint8_t *src, uint32_t src_bpr,
                             uint32_t w, uint32_t h,
                             uint8_t *dst_y, uint32_t dst_y_bpr,
                             uint8_t *dst_c, uint32_t dst_c_bpr) {
  uint32_t cw = w / 2;
  uint32_t ch = h / 2;
  for (uint32_t cy = 0; cy < ch; cy++) {
    const uint8_t *row0 = src + (size_t)(cy * 2) * src_bpr;
    const uint8_t *row1 = row0 + src_bpr;
    uint8_t *yrow0 = dst_y + (size_t)(cy * 2) * dst_y_bpr;
    uint8_t *yrow1 = yrow0 + dst_y_bpr;
    uint8_t *crow = dst_c + (size_t)cy * dst_c_bpr;
    for (uint32_t cx = 0; cx < cw; cx++) {
      uint32_t x0 = cx * 2;
      // 2x2 RGB average for chroma (rounding divide by 4).
      uint32_t b00 = row0[x0 * 4 + 0], g00 = row0[x0 * 4 + 1];
      uint32_t r00 = row0[x0 * 4 + 2];
      uint32_t b01 = row0[(x0 + 1) * 4 + 0], g01 = row0[(x0 + 1) * 4 + 1];
      uint32_t r01 = row0[(x0 + 1) * 4 + 2];
      uint32_t b10 = row1[x0 * 4 + 0], g10 = row1[x0 * 4 + 1];
      uint32_t r10 = row1[x0 * 4 + 2];
      uint32_t b11 = row1[(x0 + 1) * 4 + 0], g11 = row1[(x0 + 1) * 4 + 1];
      uint32_t r11 = row1[(x0 + 1) * 4 + 2];
      uint8_t y0, y1, y2, y3, cb, cr, ytmp;
      // Chroma from the 2x2 RGB average (chroma subsampling), luma per pixel.
      vcc_rgb_to_yuv709v((uint8_t)((r00 + r01 + r10 + r11 + 2) >> 2),
                         (uint8_t)((g00 + g01 + g10 + g11 + 2) >> 2),
                         (uint8_t)((b00 + b01 + b10 + b11 + 2) >> 2),
                         &ytmp, &cb, &cr);
      vcc_rgb_to_yuv709v(r00, g00, b00, &y0, &ytmp, &ytmp);
      vcc_rgb_to_yuv709v(r01, g01, b01, &y1, &ytmp, &ytmp);
      vcc_rgb_to_yuv709v(r10, g10, b10, &y2, &ytmp, &ytmp);
      vcc_rgb_to_yuv709v(r11, g11, b11, &y3, &ytmp, &ytmp);
      yrow0[x0] = y0;
      yrow0[x0 + 1] = y1;
      yrow1[x0] = y2;
      yrow1[x0 + 1] = y3;
      crow[cx * 2 + 0] = cb;   // Cb
      crow[cx * 2 + 1] = cr;   // Cr
    }
    // Odd width: last column is luma-only; leave chroma from column cw-1.
    if (w & 1u) {
      uint32_t x0 = w - 1;
      uint8_t y0, cb, cr;
      vcc_rgb_to_yuv709v(row0[x0 * 4 + 2], row0[x0 * 4 + 1], row0[x0 * 4 + 0],
                         &y0, &cb, &cr);
      yrow0[x0] = y0;
      vcc_rgb_to_yuv709v(row1[x0 * 4 + 2], row1[x0 * 4 + 1], row1[x0 * 4 + 0],
                         &y0, &cb, &cr);
      yrow1[x0] = y0;
    }
  }
  // Odd height: last row is luma-only.
  if (h & 1u) {
    const uint8_t *row = src + (size_t)(h - 1) * src_bpr;
    uint8_t *yrow = dst_y + (size_t)(h - 1) * dst_y_bpr;
    for (uint32_t x = 0; x < w; x++) {
      uint8_t y0, cb, cr;
      vcc_rgb_to_yuv709v(row[x * 4 + 2], row[x * 4 + 1], row[x * 4 + 0],
                         &y0, &cb, &cr);
      yrow[x] = y0;
    }
  }
}

// Interleaved 420v planes → BGRA (tight stride).
static void vcc_420v_to_bgra(const uint8_t *src_y, uint32_t src_y_bpr,
                             const uint8_t *src_c, uint32_t src_c_bpr,
                             uint32_t w, uint32_t h,
                             uint8_t *dst, uint32_t dst_bpr) {
  for (uint32_t y = 0; y < h; y++) {
    const uint8_t *yrow = src_y + (size_t)y * src_y_bpr;
    const uint8_t *crow = src_c + (size_t)(y / 2) * src_c_bpr;
    uint8_t *drow = dst + (size_t)y * dst_bpr;
    for (uint32_t x = 0; x < w; x++) {
      uint8_t cb = crow[(x / 2) * 2 + 0];
      uint8_t cr = crow[(x / 2) * 2 + 1];
      uint8_t r, g, b;
      vcc_yuv709v_to_rgb(yrow[x], cb, cr, &r, &g, &b);
      drow[x * 4 + 0] = b;
      drow[x * 4 + 1] = g;
      drow[x * 4 + 2] = r;
      drow[x * 4 + 3] = 255;
    }
  }
}

// MARK: - pixel buffers

static void vcc_release_malloc_bytes(void *refcon, const void *baseAddress) {
  (void)refcon;
  free((void *)baseAddress);
}

// Same free, CGDataProviderReleaseDataCallback shape.
static void vcc_cg_release_data(void *refcon, const void *data, size_t size) {
  (void)data;
  (void)size;
  free((void *)refcon);
}

/*
 * Camera image-buffer attachments. These are what makes the pixel buffer
 * (and, transitively, the CMVideoFormatDescription built from it via
 * CreateForImageBuffer) tell the same story as the pixels:
 *   - BT.709 primaries/transfer, plus YCbCr matrix for 4:2:0
 *   - clean aperture = full frame (no sensor-edge padding to crop away)
 *   - pixel aspect ratio 1:1 (square pixels)
 */
static void vcc_attach_camera_metadata(CVPixelBufferRef pb, int is_yuv) {
  CVBufferSetAttachment(
      pb, kCVImageBufferColorPrimariesKey,
      kCVImageBufferColorPrimaries_ITU_R_709_2,
      kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(
      pb, kCVImageBufferTransferFunctionKey,
      kCVImageBufferTransferFunction_ITU_R_709_2,
      kCVAttachmentMode_ShouldPropagate);
  if (is_yuv) {
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey,
                          kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
  }

  int32_t w = (int32_t)CVPixelBufferGetWidth(pb);
  int32_t h = (int32_t)CVPixelBufferGetHeight(pb);
  int32_t zero = 0, one = 1;
  CFNumberRef clean_w =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &w);
  CFNumberRef clean_h =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &h);
  CFNumberRef clean_x =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &zero);
  CFNumberRef clean_y =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &zero);
  const void *clean_keys[] = {
      kCVImageBufferCleanApertureWidthKey,
      kCVImageBufferCleanApertureHeightKey,
      kCVImageBufferCleanApertureHorizontalOffsetKey,
      kCVImageBufferCleanApertureVerticalOffsetKey,
  };
  const void *clean_vals[] = {clean_w, clean_h, clean_x, clean_y};
  CFDictionaryRef clean_aperture = CFDictionaryCreate(
      kCFAllocatorDefault, clean_keys, clean_vals, 4, NULL, NULL);
  CVBufferSetAttachment(pb, kCVImageBufferCleanApertureKey, clean_aperture,
                        kCVAttachmentMode_ShouldPropagate);
  CFRelease(clean_aperture);
  CFRelease(clean_w);
  CFRelease(clean_h);
  CFRelease(clean_x);
  CFRelease(clean_y);

  CFNumberRef par_h =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &one);
  CFNumberRef par_v =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &one);
  const void *par_keys[] = {
      kCVImageBufferPixelAspectRatioHorizontalSpacingKey,
      kCVImageBufferPixelAspectRatioVerticalSpacingKey,
  };
  const void *par_vals[] = {par_h, par_v};
  CFDictionaryRef par =
      CFDictionaryCreate(kCFAllocatorDefault, par_keys, par_vals, 2, NULL, NULL);
  CVBufferSetAttachment(pb, kCVImageBufferPixelAspectRatioKey, par,
                        kCVAttachmentMode_ShouldPropagate);
  CFRelease(par);
  CFRelease(par_h);
  CFRelease(par_v);
}

static CVPixelBufferRef vcc_pb_wrap_bgra(const vcc_frame_desc_t *frame) {
  size_t len = (size_t)frame->bytes_per_row * frame->height;
  uint8_t *copy = malloc(len);
  if (!copy) return NULL;
  memcpy(copy, frame->pixels, len);
  CVPixelBufferRef pb = NULL;
  CVReturn cvr = CVPixelBufferCreateWithBytes(
      kCFAllocatorDefault, frame->width, frame->height, VCC_FMT_BGRA, copy,
      frame->bytes_per_row, vcc_release_malloc_bytes, NULL, NULL, &pb);
  if (cvr != kCVReturnSuccess || !pb) {
    free(copy);
    return NULL;
  }
  vcc_attach_camera_metadata(pb, 0);
  return pb;
}

static CVPixelBufferRef vcc_pb_build_420v(const vcc_frame_desc_t *frame) {
  CVPixelBufferRef pb = NULL;
  CVReturn cvr = CVPixelBufferCreate(kCFAllocatorDefault, frame->width,
                                     frame->height, VCC_FMT_420V, NULL, &pb);
  if (cvr != kCVReturnSuccess || !pb) return NULL;

  cvr = CVPixelBufferLockBaseAddress(pb, 0);
  if (cvr != kCVReturnSuccess) {
    CVPixelBufferRelease(pb);
    return NULL;
  }
  uint8_t *y_base = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
  uint8_t *c_base = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
  size_t y_bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
  size_t c_bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
  if (!y_base || !c_base) {
    CVPixelBufferUnlockBaseAddress(pb, 0);
    CVPixelBufferRelease(pb);
    return NULL;
  }

  if (vcc_is_planar_yuv(frame->pixel_format)) {
    // 420v wire data → plane copy (Y then CbCr, per-frame strides).
    uint32_t bpr1 = frame->bytes_per_row1 ? frame->bytes_per_row1
                                          : 2u * (frame->width / 2);
    const uint8_t *src_c = frame->pixels +
                           (size_t)frame->bytes_per_row * frame->height;
    for (uint32_t y = 0; y < frame->height; y++) {
      memcpy(y_base + y * y_bpr, frame->pixels + (size_t)y * frame->bytes_per_row,
             frame->width);
    }
    for (uint32_t y = 0; y < frame->height / 2; y++) {
      memcpy(c_base + y * c_bpr, src_c + (size_t)y * bpr1, 2u * (frame->width / 2));
    }
  } else {
    vcc_bgra_to_420v(frame->pixels, frame->bytes_per_row, frame->width,
                     frame->height, y_base, (uint32_t)y_bpr, c_base,
                     (uint32_t)c_bpr);
  }
  CVPixelBufferUnlockBaseAddress(pb, 0);
  vcc_attach_camera_metadata(pb, 1);
  return pb;
}

CVPixelBufferRef vcc_pixel_buffer_from_frame(const vcc_frame_desc_t *frame,
                                             uint32_t fmt_out) {
  if (!frame || !frame->pixels || !frame->width || !frame->height ||
      !frame->bytes_per_row) {
    return NULL;
  }
  if (fmt_out == VCC_FMT_420V) return vcc_pb_build_420v(frame);
  if (fmt_out == VCC_FMT_BGRA) {
    if (frame->pixel_format == VCC_FMT_BGRA) return vcc_pb_wrap_bgra(frame);
    // 420v wire → BGRA via tight intermediate.
    uint32_t tight_bpr = frame->width * 4;
    uint8_t *tight = malloc((size_t)tight_bpr * frame->height);
    if (!tight) return NULL;
    uint32_t bpr1 =
        frame->bytes_per_row1 ? frame->bytes_per_row1 : 2u * (frame->width / 2);
    vcc_420v_to_bgra(frame->pixels, frame->bytes_per_row,
                     frame->pixels + (size_t)frame->bytes_per_row * frame->height,
                     bpr1, frame->width, frame->height, tight, tight_bpr);
    vcc_frame_desc_t tight_desc = *frame;
    tight_desc.pixel_format = VCC_FMT_BGRA;
    tight_desc.bytes_per_row = tight_bpr;
    tight_desc.pixels = tight;
    CVPixelBufferRef pb = vcc_pb_wrap_bgra(&tight_desc);
    free(tight);
    return pb;
  }
  return NULL;
}

int vcc_bgra_bytes_from_frame(const vcc_frame_desc_t *frame,
                              uint8_t **out_bytes, uint32_t *out_bpr) {
  if (!frame || !out_bytes || !out_bpr) return -1;
  uint32_t bpr = frame->width * 4;
  uint8_t *buf = malloc((size_t)bpr * frame->height);
  if (!buf) return -1;

  if (frame->pixel_format == VCC_FMT_BGRA) {
    for (uint32_t y = 0; y < frame->height; y++) {
      memcpy(buf + (size_t)y * bpr, frame->pixels + (size_t)y * frame->bytes_per_row,
             bpr);
    }
  } else if (vcc_is_planar_yuv(frame->pixel_format)) {
    uint32_t bpr1 =
        frame->bytes_per_row1 ? frame->bytes_per_row1 : 2u * (frame->width / 2);
    vcc_420v_to_bgra(frame->pixels, frame->bytes_per_row,
                     frame->pixels + (size_t)frame->bytes_per_row * frame->height,
                     bpr1, frame->width, frame->height, buf, bpr);
  } else {
    free(buf);
    return -1;
  }
  *out_bytes = buf;
  *out_bpr = bpr;
  return 0;
}

CGImageRef vcc_cgimage_from_pixel_buffer(CVPixelBufferRef pb) {
  if (!pb) return NULL;
  OSType fmt = CVPixelBufferGetPixelFormatType(pb);
  size_t w = CVPixelBufferGetWidth(pb);
  size_t h = CVPixelBufferGetHeight(pb);
  if (!w || !h) return NULL;

  if (fmt == VCC_FMT_BGRA) {
    if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) !=
        kCVReturnSuccess) {
      return NULL;
    }
    const void *base = CVPixelBufferGetBaseAddress(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    CGImageRef img = NULL;
    if (base) {
      CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
      CGDataProviderRef dp = CGDataProviderCreateWithData(
          NULL, base, bpr * h, NULL);  // borrowed; unlocked below
      img = CGImageCreate(w, h, 8, 32, bpr, cs,
                          kCGImageAlphaPremultipliedFirst |
                              kCGBitmapByteOrder32Little,
                          dp, NULL, false, kCGRenderingIntentDefault);
      if (dp) CGDataProviderRelease(dp);
      CGColorSpaceRelease(cs);
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    return img;
  }

  // 4:2:0 → BGRA → CGImage (copies; chroma decode is not cheap enough to
  // borrow buffer memory for).
  if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) !=
      kCVReturnSuccess) {
    return NULL;
  }
  vcc_frame_desc_t frame;
  memset(&frame, 0, sizeof(frame));
  frame.width = (uint32_t)w;
  frame.height = (uint32_t)h;
  frame.bytes_per_row = (uint32_t)CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
  frame.bytes_per_row1 =
      (uint32_t)CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
  frame.pixel_format = (uint32_t)fmt;
  frame.pixels = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
  frame.pixels_length = (size_t)frame.bytes_per_row * h;

  uint8_t *bgra = NULL;
  uint32_t bpr = 0;
  int rc = frame.pixels ? vcc_bgra_bytes_from_frame(&frame, &bgra, &bpr) : -1;
  CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  if (rc != 0 || !bgra) return NULL;

  size_t len = (size_t)bpr * h;
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGDataProviderRef dp =
      CGDataProviderCreateWithData(bgra, bgra, len, vcc_cg_release_data);
  CGImageRef img = CGImageCreate(w, h, 8, 32, bpr, cs,
                                 kCGImageAlphaPremultipliedFirst |
                                     kCGBitmapByteOrder32Little,
                                 dp, NULL, false, kCGRenderingIntentDefault);
  if (dp) CGDataProviderRelease(dp);  // owns bgra
  else free(bgra);
  CGColorSpaceRelease(cs);
  return img;
}

// MARK: - format description

OSStatus vcc_format_description_create_for_pb(
    CVPixelBufferRef pb, CMVideoFormatDescriptionRef *out_desc) {
  if (!pb || !out_desc) return VCC_PARAM_ERR;
  // Inherits the pixel buffer's camera attachments (colorimetry, clean
  // aperture, pixel aspect) as extensions and stays buffer-matched, which
  // hand-built extension dictionaries cannot be (CoreMedia rejects them in
  // CMVideoFormatDescriptionMatchesImageBuffer with -12743).
  return CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb,
                                                      out_desc);
}

// MARK: - sample buffer

CMSampleBufferRef vcc_cmsb_create(CVPixelBufferRef pb,
                                  CMVideoFormatDescriptionRef desc,
                                  CMTime pts, CMTime dur,
                                  uint32_t w, uint32_t h) {
  if (!pb || !desc) return NULL;

  CMSampleTimingInfo timing = {
      .duration = dur,
      .presentationTimeStamp = pts,
      .decodeTimeStamp = kCMTimeInvalid,
  };
  CMSampleBufferRef cmsb = NULL;
  OSStatus s = CMSampleBufferCreateForImageBuffer(
      kCFAllocatorDefault, pb, true, NULL, NULL, desc, &timing, &cmsb);
  if (s != noErr || !cmsb) {
    fprintf(stderr, "vcam_dataplane: CMSampleBufferCreateForImageBuffer "
                    "failed: %d\n", (int)s);
    return NULL;
  }

  // Camera intrinsic matrix, column-major matrix_float3x3 per the
  // CMSampleBuffer.h contract:
  //   column 0 = (fx, 0, 0), column 1 = (0, fy, 0), column 2 = (ox, oy, 1)
  // fx = fy = (w/2) / tan(HFOV/2) — square pixels, principal point at the
  // frame center (no crop/offset between sensor and delivered buffer).
  double fx = (0.5 * (double)w) / tan(VCC_VCAM_HFOV_DEG * M_PI / 360.0);
  float m[9] = {
      (float)fx, 0.0f, 0.0f,
      0.0f, (float)fx, 0.0f,
      (float)w / 2.0f, (float)h / 2.0f, 1.0f,
  };
  CFDataRef intr = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)m, sizeof(m));
  CMSetAttachment(cmsb, kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                  intr, kCMAttachmentMode_ShouldNotPropagate);
  CFRelease(intr);

  // Landscape-native frames: orientation 1 ("up") — the buffer really does
  // contain what it says, no rotation between sensor and consumer.
  int32_t orientation = 1;
  CFNumberRef orient_num =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &orientation);
  CMSetAttachment(cmsb, vcc_orientation_key(), orient_num,
                  kCMAttachmentMode_ShouldNotPropagate);
  CFRelease(orient_num);

  // Every frame is a self-contained I-frame — muxers and PhotoOutput
  // pipelines consult this.
  CMSetAttachment(cmsb, kCMSampleAttachmentKey_DependsOnOthers,
                  kCFBooleanFalse, kCMAttachmentMode_ShouldPropagate);

  return cmsb;
}

CMSampleBufferRef vcc_cmsb_from_frame(const vcc_frame_desc_t *frame,
                                      uint32_t fmt_out,
                                      vcc_timing_state_t *timing) {
  if (!frame || !frame->pixels || !timing) return NULL;
  if (fmt_out != VCC_FMT_BGRA && fmt_out != VCC_FMT_420V) return NULL;

  CVPixelBufferRef pb = vcc_pixel_buffer_from_frame(frame, fmt_out);
  if (!pb) return NULL;

  CMVideoFormatDescriptionRef desc = NULL;
  OSStatus s =
      vcc_format_description_create_for_pb(pb, &desc);
  if (s != noErr || !desc) {
    CVPixelBufferRelease(pb);
    return NULL;
  }

  CMTime pts, dur;
  vcc_timing_advance(timing, frame->timestamp_ns, &pts, &dur);

  CMSampleBufferRef cmsb =
      vcc_cmsb_create(pb, desc, pts, dur, frame->width, frame->height);
  CFRelease(desc);
  CVPixelBufferRelease(pb);
  if (!cmsb) return NULL;

  // Provenance (diagnostics only; harmless for consumers).
  CFStringRef provenance =
      CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("%llu"),
                               (unsigned long long)frame->frame_index);
  CMSetAttachment(cmsb, CFSTR("vphone.host_frame_index"), provenance,
                  kCMAttachmentMode_ShouldNotPropagate);
  CFRelease(provenance);
  return cmsb;
}
