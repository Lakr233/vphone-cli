// The vphoned shared frame, read in this process and turned into the
// CoreMedia, CoreGraphics and IOSurface objects the hooks hand to clients.
// Every conversion goes through the shared data plane.

#import "CamFixPrivate.h"
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <Accelerate/Accelerate.h>
#include "CamFixFrameGeometry.h"

// MARK: - shm reader

// Mapped once, lazily, by whichever of the preview queue and the photo
// queues gets here first; the lock keeps a second caller from mapping the
// file again. The mapping outlives the descriptor.
static const uint8_t *cfx_shm_base = NULL;
static size_t cfx_shm_size = 0;
static pthread_mutex_t cfx_shm_lock = PTHREAD_MUTEX_INITIALIZER;

static BOOL cfx_shm_open(void) {
  pthread_mutex_lock(&cfx_shm_lock);
  BOOL mapped = cfx_shm_base != NULL;
  if (!mapped) {
    int fd = open(VPHONE_VCAM_SHM_PATH, O_RDONLY | O_CLOEXEC);
    struct stat st;
    if (fd < 0) {
      cfxlog(@"shm open failed: %s (errno=%d)", VPHONE_VCAM_SHM_PATH, errno);
    } else if (fstat(fd, &st) == 0) {
      void *p = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
      if (p != MAP_FAILED) {
        cfx_shm_size = (size_t)st.st_size;
        cfx_shm_base = (const uint8_t *)p;
        mapped = YES;
        cfxlog(@"shm mapped %s size=%zu", VPHONE_VCAM_SHM_PATH, cfx_shm_size);
      }
    }
    if (fd >= 0) close(fd);
  }
  pthread_mutex_unlock(&cfx_shm_lock);
  return mapped;
}

// One owner for "map the frame and check it is usable": opens the shm,
// rejects a zeroed header, and rejects pixel data that runs past the
// mapping. Planar 4:2:0 frames carry a chroma plane after luma, and the
// data plane reads it, so it counts toward the checked length. On success
// fills *frame with the header fields and a pointer into the mapping.
// Returns NO when the frame cannot be read.
static BOOL cfx_shm_frame(vcc_frame_desc_t *frame) {
  if (!cfx_shm_open()) return NO;
  const vphone_vcam_shm_header_t *hdr = (const vphone_vcam_shm_header_t *)cfx_shm_base;
  uint32_t w = hdr->width, h = hdr->height, bpr = hdr->bytes_per_row;
  uint32_t fmt = hdr->pixel_format;
  if (!w || !h || !bpr) {
    cfxlog(@"shm header zeros");
    return NO;
  }
  size_t len = (size_t)bpr * h;
  if (vcc_is_planar_yuv(fmt)) len += (size_t)(2u * (w / 2)) * (h / 2);
  if ((size_t)VPHONE_VCAM_SHM_HEADER_SIZE + len > cfx_shm_size) {
    cfxlog(@"shm: pixel range exceeds mapping");
    return NO;
  }
  memset(frame, 0, sizeof(*frame));
  frame->width = w;
  frame->height = h;
  frame->bytes_per_row = bpr;
  frame->pixel_format = fmt;
  frame->timestamp_ns = hdr->timestamp_ns;
  frame->frame_index = hdr->frame_index;
  frame->pixels = cfx_shm_base + VPHONE_VCAM_SHM_HEADER_SIZE;
  frame->pixels_length = len;
  return YES;
}

static void cfx_cg_release_data(void *info, const void *data, size_t size) {
  (void)info; (void)size;
  free((void *)data);
}

// Snapshot the shm frame and decode it to tightly packed BGRA. Every RGB
// consumer (CGImage, JPEG, IOSurface) goes through here, so the wire pixel
// format is honored instead of assumed. Returns a malloc'd buffer of
// w * 4 * h bytes; the caller frees it.
static uint8_t *cfx_bgra_from_shm(uint32_t *outW, uint32_t *outH) {
  vcc_frame_desc_t frame;
  if (!cfx_shm_frame(&frame)) return NULL;
  uint8_t *bgra = NULL;
  uint32_t bpr = 0;
  if (vcc_bgra_bytes_from_frame(&frame, &bgra, &bpr) != 0) return NULL;
  *outW = frame.width;
  *outH = frame.height;
  return bgra;
}

// MARK: - sample buffers

// Photo and video delivery are BGRA. The shared data plane builds the
// CVPixelBuffer, format description and camera attachments and converts
// the wire format when needed. Timing is stream-local (host epoch-ns PTS
// values lose precision past 2^53 in downstream float conversions) and
// advances per buffer, so builds from the preview queue and the photo
// paths serialize on one lock.
static pthread_mutex_t cfx_cmsb_lock = PTHREAD_MUTEX_INITIALIZER;
static vcc_timing_state_t cfx_cmsb_timing;
static BOOL cfx_cmsb_timing_ready = NO;

CMSampleBufferRef cfx_build_cmsb(void) {
  vcc_frame_desc_t frame;
  if (!cfx_shm_frame(&frame)) return NULL;
  uint8_t *pixels = malloc(frame.pixels_length);
  if (!pixels) return NULL;
  memcpy(pixels, frame.pixels, frame.pixels_length);
  frame.pixels = pixels;

  pthread_mutex_lock(&cfx_cmsb_lock);
  if (!cfx_cmsb_timing_ready) {
    vcc_timing_init(&cfx_cmsb_timing);
    cfx_cmsb_timing_ready = YES;
  }
  CMSampleBufferRef sb = vcc_cmsb_from_frame(&frame, VCC_FMT_BGRA, &cfx_cmsb_timing);
  pthread_mutex_unlock(&cfx_cmsb_lock);
  free(pixels);
  if (!sb) cfxlog(@"build_cmsb: shared data plane returned NULL");
  return sb;
}

// MARK: - data-output sample buffers

// The size of the current shm frame, from its header alone.
BOOL cfx_shm_frame_size(uint32_t *w, uint32_t *h) {
  vcc_frame_desc_t frame;
  if (!cfx_shm_frame(&frame)) return NO;
  *w = frame.width;
  *h = frame.height;
  return YES;
}

// Same format, size and attachments, in an IOSurface-backed buffer: camera
// buffers are IOSurfaces, and video encoders expect that, while the data
// plane's buffers are plain memory.
static CVPixelBufferRef cfx_iosurface_copy(CVPixelBufferRef src) {
  size_t w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src);
  OSType fmt = CVPixelBufferGetPixelFormatType(src);
  NSDictionary *attrs = @{(NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}};
  CVPixelBufferRef dst = NULL;
  if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt, (__bridge CFDictionaryRef)attrs,
                          &dst) != kCVReturnSuccess || !dst) {
    return NULL;
  }
  CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
  CVPixelBufferLockBaseAddress(dst, 0);
  BOOL planar = CVPixelBufferIsPlanar(src);
  size_t planes = planar ? CVPixelBufferGetPlaneCount(src) : 1;
  for (size_t p = 0; p < planes; p++) {
    const uint8_t *s = planar ? CVPixelBufferGetBaseAddressOfPlane(src, p)
                              : CVPixelBufferGetBaseAddress(src);
    uint8_t *d = planar ? CVPixelBufferGetBaseAddressOfPlane(dst, p)
                        : CVPixelBufferGetBaseAddress(dst);
    size_t sbpr = planar ? CVPixelBufferGetBytesPerRowOfPlane(src, p)
                         : CVPixelBufferGetBytesPerRow(src);
    size_t dbpr = planar ? CVPixelBufferGetBytesPerRowOfPlane(dst, p)
                         : CVPixelBufferGetBytesPerRow(dst);
    size_t rows = planar ? CVPixelBufferGetHeightOfPlane(src, p) : h;
    size_t n = MIN(sbpr, dbpr);
    for (size_t y = 0; y < rows; y++) memcpy(d + y * dbpr, s + y * sbpr, n);
  }
  CVPixelBufferUnlockBaseAddress(dst, 0);
  CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
  CVBufferPropagateAttachments(src, dst);
  return dst;
}

// Crop, scale, turn and mirror packed BGRA with vImage; returns a malloc'd
// buffer of *w x *h, or NULL. extra_turns adds clockwise quarter turns.
static uint8_t *cfx_bgra_shape(const uint8_t *src, uint32_t sw, const cfx_frame_plan_t *p,
                               int extra_turns, BOOL mirror, uint32_t *w, uint32_t *h) {
  uint32_t ow = p->out_w, oh = p->out_h;
  uint8_t *scaled = malloc((size_t)ow * 4 * oh);
  if (!scaled) return NULL;
  vImage_Buffer in = {(void *)(src + ((size_t)p->crop_y * sw + p->crop_x) * 4), p->crop_h,
                      p->crop_w, (size_t)sw * 4};
  vImage_Buffer out = {scaled, oh, ow, (size_t)ow * 4};
  if (vImageScale_ARGB8888(&in, &out, NULL, kvImageHighQualityResampling) != kvImageNoError) {
    free(scaled);
    return NULL;
  }
  int turns = ((p->turns + extra_turns) % 4 + 4) % 4;
  if (turns) {
    BOOL swap = turns & 1;
    uint32_t rw = swap ? oh : ow, rh = swap ? ow : oh;
    uint8_t *rotated = malloc((size_t)rw * 4 * rh);
    static const uint8_t clockwise[4] = {kRotate0DegreesClockwise, kRotate90DegreesClockwise,
                                         kRotate180DegreesClockwise,
                                         kRotate270DegreesClockwise};
    vImage_Buffer r = {rotated, rh, rw, (size_t)rw * 4};
    const Pixel_8888 black = {0, 0, 0, 0xff};
    if (!rotated ||
        vImageRotate90_ARGB8888(&out, &r, clockwise[turns], black, kvImageNoFlags) !=
            kvImageNoError) {
      free(rotated);
      free(scaled);
      return NULL;
    }
    free(scaled);
    scaled = rotated;
    out = r;
    ow = rw;
    oh = rh;
  }
  if (mirror) vImageHorizontalReflect_ARGB8888(&out, &out, kvImageNoFlags);
  *w = ow;
  *h = oh;
  return scaled;
}

// Mean luma over a sparse grid, for the {Exif} brightness value.
static double cfx_bgra_mean_luma(const uint8_t *px, uint32_t w, uint32_t h) {
  double sum = 0;
  uint32_t n = 0;
  for (uint32_t y = 0; y < h; y += 8) {
    for (uint32_t x = 0; x < w; x += 8) {
      const uint8_t *p = px + ((size_t)y * w + x) * 4;  // B, G, R, A
      sum += 0.0722 * p[0] + 0.7152 * p[1] + 0.2126 * p[2];
      n++;
    }
  }
  return n ? sum / n : 118;
}

CMSampleBufferRef cfx_build_oriented_cmsb(uint32_t fmt_out, uint32_t preset_w,
                                          uint32_t preset_h, int angle, double zoom,
                                          int extra_turns, BOOL mirror, uint32_t *outW,
                                          uint32_t *outH) {
  uint32_t fw = 0, fh = 0;
  uint8_t *frame_px = cfx_bgra_from_shm(&fw, &fh);
  if (!frame_px) return NULL;
  cfx_frame_plan_t plan;
  uint32_t w = 0, h = 0;
  uint8_t *px = NULL;
  if (cfx_frame_plan(fw, fh, preset_w, preset_h, angle, zoom, &plan) == 0) {
    px = cfx_bgra_shape(frame_px, fw, &plan, extra_turns, mirror, &w, &h);
  }
  free(frame_px);
  if (!px) return NULL;
  double luma = cfx_bgra_mean_luma(px, w, h);

  vcc_frame_desc_t frame;
  memset(&frame, 0, sizeof(frame));
  frame.width = w;
  frame.height = h;
  frame.bytes_per_row = w * 4;
  frame.pixel_format = VCC_FMT_BGRA;
  frame.timestamp_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  frame.pixels = px;
  frame.pixels_length = (size_t)w * 4 * h;
  CVPixelBufferRef plain = vcc_pixel_buffer_from_frame(&frame, fmt_out);
  free(px);
  if (!plain) return NULL;
  CVPixelBufferRef pb = cfx_iosurface_copy(plain);
  CVPixelBufferRelease(plain);
  if (!pb) return NULL;
  CMVideoFormatDescriptionRef desc = NULL;
  if (vcc_format_description_create_for_pb(pb, &desc) != noErr || !desc) {
    CVPixelBufferRelease(pb);
    return NULL;
  }
  pthread_mutex_lock(&cfx_cmsb_lock);
  if (!cfx_cmsb_timing_ready) {
    vcc_timing_init(&cfx_cmsb_timing);
    cfx_cmsb_timing_ready = YES;
  }
  CMTime pts, dur;
  vcc_timing_advance(&cfx_cmsb_timing, frame.timestamp_ns, &pts, &dur);
  pthread_mutex_unlock(&cfx_cmsb_lock);
  CMSampleBufferRef sb = vcc_cmsb_create(pb, desc, pts, dur, w, h);
  if (sb) cfx_stamp_exif(sb, luma);
  CFRelease(desc);
  CVPixelBufferRelease(pb);
  if (outW) *outW = w;
  if (outH) *outH = h;
  return sb;
}

// MARK: - JPEG + CGImage + IOSurface builders

NSData *cfx_jpeg_from_cgimage(CGImageRef img) {
  if (!img) return nil;
  NSMutableData *data = [NSMutableData data];
  CGImageDestinationRef dest = CGImageDestinationCreateWithData(
      (CFMutableDataRef)data,
      (CFStringRef)@"public.jpeg",
      1,
      NULL);
  if (!dest) return nil;
  CGImageDestinationAddImage(dest, img, NULL);
  BOOL ok = CGImageDestinationFinalize(dest);
  CFRelease(dest);
  return ok ? data : nil;
}

CGImageRef cfx_build_cgimage_from_shm(void) {
  uint32_t w = 0, h = 0;
  uint8_t *bgra = cfx_bgra_from_shm(&w, &h);
  if (!bgra) return NULL;
  size_t len = (size_t)w * 4 * h;
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGDataProviderRef dp = CGDataProviderCreateWithData(
      NULL,
      bgra,
      len,
      cfx_cg_release_data);
  CGImageRef img = CGImageCreate(
      w,
      h,
      8,
      32,
      w * 4,
      cs,
      (CGBitmapInfo)(kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst),
      dp,
      NULL,
      false,
      kCGRenderingIntentDefault);
  CGDataProviderRelease(dp);
  CGColorSpaceRelease(cs);
  return img;
}

IOSurfaceRef cfx_build_iosurface_from_shm(uint32_t *outW, uint32_t *outH) {
  uint32_t w = 0, h = 0;
  uint8_t *bgra = cfx_bgra_from_shm(&w, &h);
  if (!bgra) return NULL;
  size_t len = (size_t)w * 4 * h;
  NSDictionary *props = @{
    (NSString *)kIOSurfaceWidth: @(w),
    (NSString *)kIOSurfaceHeight: @(h),
    (NSString *)kIOSurfacePixelFormat: @(kCVPixelFormatType_32BGRA),
    (NSString *)kIOSurfaceBytesPerElement: @(4),
    (NSString *)kIOSurfaceBytesPerRow: @(w * 4),
    (NSString *)kIOSurfaceAllocSize: @(len),
  };
  IOSurfaceRef surf = IOSurfaceCreate((CFDictionaryRef)props);
  if (!surf) { free(bgra); return NULL; }
  IOSurfaceLock(surf, 0, NULL);
  void *base = IOSurfaceGetBaseAddress(surf);
  if (base) memcpy(base, bgra, len);
  IOSurfaceUnlock(surf, 0, NULL);
  free(bgra);
  if (outW) *outW = w;
  if (outH) *outH = h;
  return surf;
}
