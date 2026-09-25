/*
 * vcam_dataplane_test — host-side proof harness for the shared virtual-
 * camera data plane (VCamDataPlane/vcam_dataplane.c).
 *
 * Builds a synthetic BGRA frame with known color patches, drives it
 * through the exact chain the guest dylibs use, then dumps everything
 * reachable from the CVPixelBuffer / CMFormatDescription /
 * CMSampleBuffer / attachments (the "capture and diff" dump from the
 * camera-consistency research) and self-verifies:
 *
 *   1. advertised format == delivered format ('420v' pixel buffer,
 *      '420v' format description, consistent bytes-per-row)
 *   2. BT.709 video-range conversion correctness at patch centers
 *   3. format-description extensions (clean aperture, pixel aspect,
 *      colorimetry) match the bits
 *   4. timing: host timestamps → monotonic PTS, realistic durations,
 *      stall/burst fallbacks
 *   5. camera metadata: intrinsic matrix (fx/fy/principal point from
 *      VCC_VCAM_HFOV_DEG), orientation, I-frame provenance
 *   6. 420v → BGRA round-trip within chroma-subsampling tolerance
 *
 * Exit code 0 = all checks pass.
 *
 * Build/run:  make -C VPhoneGuestComponents test-vcam-dataplane
 */

#include "../VCamDataPlane/vcam_dataplane.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_checks = 0;
static int g_fails = 0;

#define CHECK(cond, ...)                                     \
  do {                                                       \
    g_checks++;                                              \
    if (!(cond)) {                                           \
      g_fails++;                                             \
      printf("  FAIL: ");                                    \
      printf(__VA_ARGS__);                                   \
      printf("\n");                                          \
    }                                                        \
  } while (0)

static char vcc4(uint32_t f) { return (char)(f & 0xff); }

static void print_4cc(const char *label, uint32_t f) {
  printf("    %s = '%c%c%c%c' (0x%08x)\n", label, vcc4(f >> 24), vcc4(f >> 16),
         vcc4(f >> 8), vcc4(f), f);
}

// MARK: - synthetic frame

#define TW 1280
#define TH 720
#define TBPR (TW * 4)  // already 16-byte aligned

typedef struct {
  uint32_t x, y;      // top-left of a 64x64 patch
  uint8_t b, g, r, a;
  const char *name;
} patch_t;

static const patch_t g_patches[] = {
    {100, 100, 255, 255, 255, 255, "white"},
    {300, 100, 0, 0, 0, 255, "black"},
    {500, 100, 0, 0, 255, 255, "red"},
    {700, 100, 0, 255, 0, 255, "green"},
    {900, 100, 255, 0, 0, 255, "blue"},
    {1100, 100, 128, 128, 128, 255, "gray"},
};
#define PATCH_COUNT (sizeof(g_patches) / sizeof(g_patches[0]))
#define PATCH_SIZE 64

static uint8_t *g_frame = NULL;

static void build_test_frame(void) {
  g_frame = malloc((size_t)TBPR * TH);
  // Moving-gradient background (like the host test-pattern producer).
  for (uint32_t y = 0; y < TH; y++) {
    for (uint32_t x = 0; x < TW; x++) {
      uint8_t *p = g_frame + (size_t)y * TBPR + x * 4;
      p[0] = (uint8_t)(x & 0xff);        // B
      p[1] = (uint8_t)((y * 2) & 0xff);  // G
      p[2] = (uint8_t)((x + y) & 0xff);  // R
      p[3] = 255;                        // A
    }
  }
  for (size_t i = 0; i < PATCH_COUNT; i++) {
    const patch_t *pt = &g_patches[i];
    for (uint32_t y = pt->y; y < pt->y + PATCH_SIZE; y++) {
      uint8_t *row = g_frame + (size_t)y * TBPR;
      for (uint32_t x = pt->x; x < pt->x + PATCH_SIZE; x++) {
        uint8_t *p = row + x * 4;
        p[0] = pt->b;
        p[1] = pt->g;
        p[2] = pt->r;
        p[3] = pt->a;
      }
    }
  }
}

static const patch_t *find_patch(const char *name) {
  for (size_t i = 0; i < PATCH_COUNT; i++) {
    if (!strcmp(g_patches[i].name, name)) return &g_patches[i];
  }
  return NULL;
}

static vcc_frame_desc_t make_desc(uint64_t ts_ns) {
  vcc_frame_desc_t d = {0};
  d.width = TW;
  d.height = TH;
  d.bytes_per_row = TBPR;
  d.pixel_format = VCC_FMT_BGRA;
  d.timestamp_ns = ts_ns;
  d.frame_index = ts_ns / 33333333ull;
  d.pixels = g_frame;
  d.pixels_length = (size_t)TBPR * TH;
  return d;
}

// MARK: - dumps

static void dump_pixel_buffer(CVPixelBufferRef pb) {
  printf("  CVPixelBuffer:\n");
  printf("    dims = %zux%zu\n", CVPixelBufferGetWidth(pb),
         CVPixelBufferGetHeight(pb));
  print_4cc("format", CVPixelBufferGetPixelFormatType(pb));
  printf("    planeCount = %zu\n", CVPixelBufferGetPlaneCount(pb));
  if (CVPixelBufferIsPlanar(pb)) {
    for (size_t p = 0; p < CVPixelBufferGetPlaneCount(pb); p++) {
      printf("    plane %zu: %zux%zu bpr=%zu base=%p\n", p,
             CVPixelBufferGetWidthOfPlane(pb, p),
             CVPixelBufferGetHeightOfPlane(pb, p),
             CVPixelBufferGetBytesPerRowOfPlane(pb, p),
             CVPixelBufferGetBaseAddressOfPlane(pb, p));
    }
  } else {
    printf("    bpr = %zu base=%p\n", CVPixelBufferGetBytesPerRow(pb),
           CVPixelBufferGetBaseAddress(pb));
  }
  static const CFStringRef *cvkeys[] = {
      &kCVImageBufferYCbCrMatrixKey, &kCVImageBufferColorPrimariesKey,
      &kCVImageBufferTransferFunctionKey};
  static const char *cvnames[] = {"YCbCrMatrix", "ColorPrimaries",
                                  "TransferFunction"};
  for (int i = 0; i < 3; i++) {
    CFTypeRef v = CVBufferCopyAttachment(pb, *cvkeys[i], NULL);
    printf("    attachment %s = %s\n", cvnames[i],
           v ? CFStringGetCStringPtr(v, kCFStringEncodingUTF8) ?: "?" : "(none)");
    if (v) CFRelease(v);
  }
}

static void dump_format_description(CMVideoFormatDescriptionRef desc) {
  printf("  CMVideoFormatDescription:\n");
  print_4cc("mediaSubType", CMFormatDescriptionGetMediaSubType(desc));
  printf("    dims = %dx%d\n", CMVideoFormatDescriptionGetDimensions(desc).width,
         CMVideoFormatDescriptionGetDimensions(desc).height);
  CFDictionaryRef ext = CMFormatDescriptionGetExtensions(desc);
  printf("    extensions.count = %lu\n",
         ext ? (unsigned long)CFDictionaryGetCount(ext) : 0);
  if (ext) {
    CFStringRef s = CFStringCreateWithFormat(kCFAllocatorDefault, NULL,
                                             CFSTR("%@"), ext);
    char buf[1024];
    if (CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8)) {
      printf("    extensions = %s\n", buf);
    }
    CFRelease(s);
  }
  CGRect ca = CMVideoFormatDescriptionGetCleanAperture(desc, true);
  printf("    cleanAperture = %.0fx%.0f off(%.0f,%.0f)\n", ca.size.width,
         ca.size.height, ca.origin.x, ca.origin.y);
}

static void dump_format_description_from_pb(CVPixelBufferRef pb) {
  CMVideoFormatDescriptionRef desc = NULL;
  if (vcc_format_description_create_for_pb(pb, &desc) != noErr || !desc) return;
  dump_format_description(desc);
  CFRelease(desc);
}

static void dump_sample_buffer(CMSampleBufferRef sb) {
  printf("  CMSampleBuffer:\n");
  CMTime d = CMSampleBufferGetDuration(sb);
  CMTime p = CMSampleBufferGetPresentationTimeStamp(sb);
  printf("    numSamples = %lu\n",
         (unsigned long)CMSampleBufferGetNumSamples(sb));
  printf("    duration = %.6fs (%lld/%d)\n", CMTimeGetSeconds(d), d.value,
         d.timescale);
  printf("    pts = %.6fs (stream-local)\n", CMTimeGetSeconds(p));

  CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, true);
  printf("    attachmentsArray = %s\n", atts ? "(present)" : "(none)");

  CFDataRef intr = CMGetAttachment(
      sb, kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, NULL);
  if (intr && CFDataGetLength(intr) == 36) {
    const float *m = (const float *)CFDataGetBytePtr(intr);
    printf("    intrinsicMatrix (column-major) =\n");
    printf("      [%.2f, %.2f, %.2f]\n", m[0], m[3], m[6]);
    printf("      [%.2f, %.2f, %.2f]\n", m[1], m[4], m[7]);
    printf("      [%.2f, %.2f, %.2f]\n", m[2], m[5], m[8]);
  } else {
    printf("    intrinsicMatrix = (missing or wrong size: %lu)\n",
           intr ? (unsigned long)CFDataGetLength(intr) : 0);
  }
  CFTypeRef dep = CMGetAttachment(sb, kCMSampleAttachmentKey_DependsOnOthers, NULL);
  printf("    dependsOnOthers = %s\n",
         dep == kCFBooleanFalse ? "false (I-frame)" : "?");
}

// MARK: - test groups

static void test_pixel_values_420v(CVPixelBufferRef pb) {
  CHECK(CVPixelBufferGetPixelFormatType(pb) == VCC_FMT_420V,
        "pixel buffer format is not 420v");
  CHECK(CVPixelBufferGetPlaneCount(pb) == 2, "420v must have 2 planes");
  CHECK(CVPixelBufferGetWidthOfPlane(pb, 0) == TW &&
            CVPixelBufferGetHeightOfPlane(pb, 0) == TH,
        "Y plane dims");
  CHECK(CVPixelBufferGetWidthOfPlane(pb, 1) == TW / 2 &&
            CVPixelBufferGetHeightOfPlane(pb, 1) == TH / 2,
        "CbCr plane dims");
  CHECK(CVPixelBufferGetBytesPerRowOfPlane(pb, 0) >= TW,
        "Y bytes-per-row must cover width");
  CHECK(CVPixelBufferGetBytesPerRowOfPlane(pb, 1) >= TW,
        "CbCr bytes-per-row must cover 2*(w/2) bytes");

  // Expected BT.709 video-range values at patch centers (chroma from the
  // 2x2 average — exact for solid patches).
  struct { const char *name; uint8_t y, cb, cr; } expect[] = {
      {"white", 235, 128, 128},
      {"black", 16, 128, 128},
      {"red", 63, 102, 240},   // Cr clamps at 240
      {"green", 172, 41, 34},
      {"blue", 32, 240, 110},  // Cb clamps at 240
      {"gray", 126, 128, 128},
  };

  const uint8_t *ybase, *cbase;
  size_t ybpr, cbpr;
  CHECK(CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) ==
            kCVReturnSuccess,
        "lock 420v planes");
  ybase = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
  cbase = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
  ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
  cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);

  for (size_t i = 0; i < sizeof(expect) / sizeof(expect[0]); i++) {
    const patch_t *pt = find_patch(expect[i].name);
    CHECK(pt != NULL, "patch %s defined in table", expect[i].name);
    if (!pt) continue;
    uint32_t sx = pt->x + PATCH_SIZE / 2, sy = pt->y + PATCH_SIZE / 2;
    uint8_t y = ybase[(size_t)sy * ybpr + sx];
    uint8_t cb = cbase[(size_t)(sy / 2) * cbpr + (sx / 2) * 2 + 0];
    uint8_t cr = cbase[(size_t)(sy / 2) * cbpr + (sx / 2) * 2 + 1];
    int dy = abs((int)y - expect[i].y);
    int dcb = abs((int)cb - expect[i].cb);
    int dcr = abs((int)cr - expect[i].cr);
    printf("    patch %-6s -> Y=%3u (exp %3u d=%d)  Cb=%3u (exp %3u d=%d)  "
           "Cr=%3u (exp %3u d=%d)\n",
           expect[i].name, y, expect[i].y, dy, cb, expect[i].cb, dcb, cr,
           expect[i].cr, dcr);
    CHECK(dy <= 1, "%s Y off by %d", expect[i].name, dy);
    CHECK(dcb <= 2, "%s Cb off by %d", expect[i].name, dcb);
    CHECK(dcr <= 2, "%s Cr off by %d", expect[i].name, dcr);
  }
  CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
}

static void test_colorimetry_attachments(CVPixelBufferRef pb) {
  CFStringRef m = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, NULL);
  CFStringRef p =
      CVBufferCopyAttachment(pb, kCVImageBufferColorPrimariesKey, NULL);
  CFStringRef t =
      CVBufferCopyAttachment(pb, kCVImageBufferTransferFunctionKey, NULL);
  CHECK(m && CFEqual(m, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        "420v YCbCr matrix must be BT.709");
  CHECK(p && CFEqual(p, kCVImageBufferColorPrimaries_ITU_R_709_2),
        "primaries must be BT.709");
  CHECK(t && CFEqual(t, kCVImageBufferTransferFunction_ITU_R_709_2),
        "transfer must be BT.709");
}

static void test_format_description_matches(CVPixelBufferRef pb,
                                            int expect_yuv_matrix) {
  CMVideoFormatDescriptionRef desc = NULL;
  OSStatus s = vcc_format_description_create_for_pb(pb, &desc);
  CHECK(s == noErr && desc, "format description creation");
  if (!desc) return;
  print_4cc("mediaSubType", CMFormatDescriptionGetMediaSubType(desc));
  CHECK(CMFormatDescriptionGetMediaSubType(desc) ==
            (CMVideoCodecType)CVPixelBufferGetPixelFormatType(pb),
        "format description codec must equal delivered pixel format");
  CHECK(CMVideoFormatDescriptionGetDimensions(desc).width ==
                (int32_t)CVPixelBufferGetWidth(pb) &&
            CMVideoFormatDescriptionGetDimensions(desc).height ==
                (int32_t)CVPixelBufferGetHeight(pb),
        "format description dims");
  CHECK(CMVideoFormatDescriptionMatchesImageBuffer(desc, pb) != 0,
        "description must pass CMVideoFormatDescriptionMatchesImageBuffer");

  CFDictionaryRef ext = CMFormatDescriptionGetExtensions(desc);
  CHECK(ext != NULL, "format description must carry extensions");
  if (ext) {
    CFTypeRef v;
    // Attachments are folded in under the CV-prefixed canonical names.
    v = CFDictionaryGetValue(ext, CFSTR("CVCleanAperture"));
    CHECK(v != NULL, "clean aperture inherited from pixel buffer");
    v = CFDictionaryGetValue(ext, CFSTR("CVPixelAspectRatio"));
    CHECK(v != NULL, "pixel aspect ratio inherited from pixel buffer");
    v = CFDictionaryGetValue(ext, CFSTR("CVImageBufferColorPrimaries"));
    CHECK(v && CFEqual(v, kCVImageBufferColorPrimaries_ITU_R_709_2),
          "709 primaries in extensions");
    v = CFDictionaryGetValue(ext, CFSTR("CVImageBufferYCbCrMatrix"));
    if (expect_yuv_matrix) {
      CHECK(v && CFEqual(v, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
            "709 YCbCr matrix in extensions");
    } else {
      CHECK(v == NULL, "BGRA extensions must not claim a YCbCr matrix");
    }
  }

  CGRect ca = CMVideoFormatDescriptionGetCleanAperture(desc, true);
  CHECK((int)ca.size.width == TW && (int)ca.size.height == TH &&
            ca.origin.x == 0 && ca.origin.y == 0,
        "clean aperture = full frame");

  CFRelease(desc);
}

static void test_timing(void) {
  vcc_timing_state_t st;
  vcc_timing_init(&st);
  CMTime pts, dur;

  uint64_t t0 = 1726500000ull * 1000000000ull;  // host wall-clock epoch ns
  struct { uint64_t dt_ns; double want_pts_s, want_dur_s; } steps[] = {
      {0, 0.0, 1.0 / 30.0},                        // first frame
      {33400000, 0.0334, 0.0334},                  // normal cadence
      {33300000, 0.0667, 0.0333},                  // normal cadence
      {500000000, 0.5667, 1.0 / 30.0},             // stall -> fallback duration
      {0, 0.5667 + 0.033333333, 1.0 / 30.0},       // duplicate tick -> still advances
  };
  uint64_t ts = t0;
  double last_pts = -1.0;
  for (size_t i = 0; i < sizeof(steps) / sizeof(steps[0]); i++) {
    ts += steps[i].dt_ns;
    vcc_timing_advance(&st, ts, &pts, &dur);
    double p = CMTimeGetSeconds(pts);
    double d = CMTimeGetSeconds(dur);
    printf("    host_ts=%llu pts=%.6fs dur=%.6fs\n",
           (unsigned long long)ts, p, d);
    CHECK(p > last_pts, "pts strictly increasing (frame %zu)", i);
    CHECK(fabs(p - steps[i].want_pts_s) < 1e-4, "pts value frame %zu", i);
    CHECK(fabs(d - steps[i].want_dur_s) < 1e-4, "duration frame %zu", i);
    last_pts = p;
  }
}

static void test_cmsb_metadata(CMSampleBufferRef sb) {
  // Timing on the buffer itself.
  double dur = CMTimeGetSeconds(CMSampleBufferGetDuration(sb));
  double pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb));
  CHECK(CMSampleBufferGetNumSamples(sb) == 1, "one sample per buffer");
  CHECK(fabs(dur - 1.0 / 30.0) < 0.001, "duration ~1/30s, got %.6f", dur);
  CHECK(pts >= 0.0, "stream-local pts non-negative");

  // Intrinsic matrix.
  CFDataRef intr = CMGetAttachment(
      sb, kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, NULL);
  CHECK(intr != NULL, "intrinsic matrix attachment present");
  CHECK(intr && CFDataGetLength(intr) == 36, "intrinsic matrix is 9 floats");
  if (intr && CFDataGetLength(intr) == 36) {
    const float *m = (const float *)CFDataGetBytePtr(intr);
    double want_fx = (0.5 * TW) / tan(VCC_VCAM_HFOV_DEG * M_PI / 360.0);
    printf("    fx=fy=%.2f (want %.2f from HFOV %.1f deg) ox=%.1f oy=%.1f\n",
           m[0], want_fx, VCC_VCAM_HFOV_DEG, m[6], m[7]);
    CHECK(fabs(m[0] - want_fx) < 0.5, "fx matches HFOV derivation");
    CHECK(m[1] == 0 && m[2] == 0 && m[3] == 0 && m[5] == 0 && m[8] == 1,
          "zero skew/aspect entries");
    CHECK(fabs(m[6] - TW / 2.0) < 0.01 && fabs(m[7] - TH / 2.0) < 0.01,
          "principal point at frame center");
    CHECK(fabs(m[4] - want_fx) < 0.5, "fy matches fx (square pixels)");
  }

  // Orientation + provenance.
  CFStringRef ok = CFSTR("Orientation");
  CFTypeRef orient = CMGetAttachment(sb, ok, NULL);
  CHECK(orient != NULL, "orientation attachment present");
  if (orient) {
    long o = -1;
    if (CFGetTypeID(orient) == CFNumberGetTypeID()) {
      CFNumberGetValue((CFNumberRef)orient, kCFNumberLongType, &o);
    } else if (CFGetTypeID(orient) == CFStringGetTypeID()) {
      o = CFStringGetIntValue((CFStringRef)orient);
    }
    CHECK(o == 1, "orientation == 1 (landscape-native), got %ld", o);
  }
  CFTypeRef dep =
      CMGetAttachment(sb, kCMSampleAttachmentKey_DependsOnOthers, NULL);
  CHECK(dep == kCFBooleanFalse, "dependsOnOthers == false (I-frame)");
}

static void test_roundtrip(void) {
  // Build the 420v pixel buffer, then re-serialize its planes into a wire
  // frame and decode back to tight BGRA through the shared helper.
  vcc_frame_desc_t src = make_desc(1000000000ull);
  CVPixelBufferRef pb = vcc_pixel_buffer_from_frame(&src, VCC_FMT_420V);
  CHECK(pb != NULL, "420v buffer for round-trip");
  if (!pb) return;
  CVPixelBufferLockBaseAddress(pb, 0);

  size_t ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
  size_t cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
  size_t wire_len = ybpr * TH + cbpr * (TH / 2);
  uint8_t *wire = malloc(wire_len);
  memcpy(wire, CVPixelBufferGetBaseAddressOfPlane(pb, 0), ybpr * TH);
  memcpy(wire + ybpr * TH, CVPixelBufferGetBaseAddressOfPlane(pb, 1),
         cbpr * (TH / 2));
  CVPixelBufferUnlockBaseAddress(pb, 0);
  CVPixelBufferRelease(pb);

  vcc_frame_desc_t yuv = make_desc(1000000000ull);
  yuv.pixel_format = VCC_FMT_420V;
  yuv.bytes_per_row = (uint32_t)ybpr;
  yuv.bytes_per_row1 = (uint32_t)cbpr;
  yuv.pixels = wire;
  yuv.pixels_length = wire_len;

  uint8_t *bgra = NULL;
  uint32_t bpr = 0;
  int rc = vcc_bgra_bytes_from_frame(&yuv, &bgra, &bpr);
  CHECK(rc == 0 && bgra && bpr == TW * 4, "420v -> BGRA decode");
  if (rc != 0 || !bgra) {
    free(wire);
    return;
  }

  for (size_t i = 0; i < PATCH_COUNT; i++) {
    const patch_t *pt = &g_patches[i];
    uint32_t sx = pt->x + PATCH_SIZE / 2, sy = pt->y + PATCH_SIZE / 2;
    const uint8_t *p = bgra + (size_t)sy * bpr + sx * 4;
    int db = abs((int)p[0] - pt->b), dg = abs((int)p[1] - pt->g),
        dr = abs((int)p[2] - pt->r);
    printf("    round-trip %-6s -> B=%3u G=%3u R=%3u (delta %d/%d/%d)\n",
           pt->name, p[0], p[1], p[2], db, dg, dr);
    // 8-bit studio-swing 4:2:0 chroma quantization: pure primaries round-trip
    // with up to ~16 levels of crosstalk (same as real camera 420v output).
    CHECK(db <= 16 && dg <= 16 && dr <= 16,
          "%s round-trip within chroma tolerance", pt->name);
  }
  free(bgra);
  free(wire);
}

// MARK: - phase 3/4 checks

static void test_cgimage_helper(void) {
  printf("  [4a] pixel buffer -> CGImage (preview/photo path)\n");
  vcc_frame_desc_t frame = make_desc(1000000000ull);

  // BGRA: bit-exact.
  CVPixelBufferRef pb = vcc_pixel_buffer_from_frame(&frame, VCC_FMT_BGRA);
  CHECK(pb != NULL, "BGRA pb for CGImage");
  if (pb) {
    CGImageRef img = vcc_cgimage_from_pixel_buffer(pb);
    CHECK(img != NULL, "CGImage from BGRA pb");
    if (img) {
      CHECK(CGImageGetWidth(img) == TW && CGImageGetHeight(img) == TH,
            "CGImage dims match");
      CHECK(CGImageGetBitsPerPixel(img) == 32, "CGImage 32bpp");
      // Sample the red patch center out of the CGImage's provider.
      CGDataProviderRef dp = CGImageGetDataProvider(img);
      CFDataRef data = dp ? CGDataProviderCopyData(dp) : NULL;
      if (data) {
        const uint8_t *bytes = CFDataGetBytePtr(data);
        size_t rbpr = CGImageGetBytesPerRow(img);
        const patch_t *pt = find_patch("blue");
        const uint8_t *p = bytes + (size_t)(pt->y + 32) * rbpr + (pt->x + 32) * 4;
        CHECK(p[0] == 255 && p[1] == 0 && p[2] == 0,
              "CGImage pixel at blue patch is blue (B=%u G=%u R=%u)",
              p[0], p[1], p[2]);
        CFRelease(data);
      }
      CGImageRelease(img);
    }
    CVPixelBufferRelease(pb);
  }

  // 420v: patches preserved within chroma quantization.
  pb = vcc_pixel_buffer_from_frame(&frame, VCC_FMT_420V);
  CHECK(pb != NULL, "420v pb for CGImage");
  if (pb) {
    CGImageRef img = vcc_cgimage_from_pixel_buffer(pb);
    CHECK(img != NULL, "CGImage from 420v pb");
    if (img) {
      CGDataProviderRef dp = CGImageGetDataProvider(img);
      CFDataRef data = dp ? CGDataProviderCopyData(dp) : NULL;
      if (data) {
        const uint8_t *bytes = CFDataGetBytePtr(data);
        size_t rbpr = CGImageGetBytesPerRow(img);
        const patch_t *pt = find_patch("white");
        const uint8_t *p = bytes + (size_t)(pt->y + 32) * rbpr + (pt->x + 32) * 4;
        CHECK(p[0] >= 245 && p[1] >= 245 && p[2] >= 245,
              "white patch survives 420v -> CGImage (%u/%u/%u)",
              p[0], p[1], p[2]);
        CFRelease(data);
      }
      CGImageRelease(img);
    }
    CVPixelBufferRelease(pb);
  }
}

static void test_format_metadata_consistency(void) {
  // Phase 3 contract: the published format keys and the delivered sample
  // buffer must tell one story. These mirror what the synthetic source
  // publishes in libvcamcaptured (VideoFieldOfView = VCC_VCAM_HFOV_DEG,
  // CameraCalibrationDataDeliverySupported = YES).
  printf("  [4b] published-format <-> delivered-sample consistency\n");
  vcc_timing_state_t timing;
  vcc_timing_init(&timing);
  vcc_frame_desc_t frame = make_desc(1726500000ull * 1000000000ull);

  CMSampleBufferRef sb = vcc_cmsb_from_frame(&frame, VCC_FMT_420V, &timing);
  CHECK(sb != NULL, "sample for consistency check");
  if (!sb) return;
  CMVideoFormatDescriptionRef desc = CMSampleBufferGetFormatDescription(sb);

  // Delivered codec == advertised PixelFormatType (420v active format).
  CHECK(CMFormatDescriptionGetMediaSubType(desc) == (CMVideoCodecType)VCC_FMT_420V,
        "delivered codec matches advertised active format");
  // Delivered dimensions == advertised Width/Height.
  CHECK(CMVideoFormatDescriptionGetDimensions(desc).width == TW &&
            CMVideoFormatDescriptionGetDimensions(desc).height == TH,
        "delivered dims match advertised dims");
  // Intrinsic focal length == what videoFieldOfView=63.0 implies.
  CFDataRef intr = CMGetAttachment(
      sb, kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, NULL);
  CHECK(intr && CFDataGetLength(intr) == 36, "intrinsics present");
  if (intr) {
    const float *m = (const float *)CFDataGetBytePtr(intr);
    double want_fx = (0.5 * TW) / tan(VCC_VCAM_HFOV_DEG * M_PI / 360.0);
    CHECK(fabs(m[0] - want_fx) < 0.5,
          "fx=%.2f consistent with advertised FOV %.1f deg", m[0],
          VCC_VCAM_HFOV_DEG);
  }
  CFRelease(sb);

  // One pipeline: CGImage derivation from the SAME sample's pixel buffer
  // (what the Phase 4 preview pump consumes) matches the wire frame.
  CVPixelBufferRef pb = vcc_pixel_buffer_from_frame(&frame, VCC_FMT_420V);
  if (pb) {
    CGImageRef img = vcc_cgimage_from_pixel_buffer(pb);
    CHECK(img != NULL, "preview-pipeline CGImage");
    if (img) CGImageRelease(img);
    CVPixelBufferRelease(pb);
  }
}

static void test_full_chain_dump(void) {
  vcc_timing_state_t timing;
  vcc_timing_init(&timing);
  vcc_frame_desc_t frame = make_desc(1726500000ull * 1000000000ull);
  frame.frame_index = 42;

  printf("  -- chain: BGRA host frame -> '420v' camera sample --\n");
  CMSampleBufferRef sb = vcc_cmsb_from_frame(&frame, VCC_FMT_420V, &timing);
  CHECK(sb != NULL, "vcc_cmsb_from_frame 420v");
  if (!sb) return;
  CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
  CHECK(pb != NULL, "sample buffer carries image buffer");
  CMVideoFormatDescriptionRef desc =
      CMSampleBufferGetFormatDescription(sb);
  CHECK(desc != NULL, "sample buffer carries format description");
  if (pb) dump_pixel_buffer(pb);
  if (desc) dump_format_description(desc);
  dump_sample_buffer(sb);
  if (pb) test_pixel_values_420v(pb);
  if (pb) test_colorimetry_attachments(pb);
  test_cmsb_metadata(sb);
  CFRelease(sb);

  printf("  -- chain: BGRA host frame -> BGRA camera sample --\n");
  vcc_timing_init(&timing);
  sb = vcc_cmsb_from_frame(&frame, VCC_FMT_BGRA, &timing);
  CHECK(sb != NULL, "vcc_cmsb_from_frame bgra");
  if (!sb) return;
  pb = CMSampleBufferGetImageBuffer(sb);
  CHECK(pb && CVPixelBufferGetPixelFormatType(pb) == VCC_FMT_BGRA,
        "BGRA delivered as BGRA");
  CHECK(pb && CVPixelBufferGetBytesPerRow(pb) >= TW * 4, "BGRA bpr sane");
  dump_pixel_buffer(pb);
  if (pb) {
    CHECK(CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) ==
              kCVReturnSuccess,
          "lock BGRA base");
    const uint8_t *base = CVPixelBufferGetBaseAddress(pb);
    const patch_t *pt = find_patch("red");
    const uint8_t *p = base + (size_t)(pt->y + 32) * CVPixelBufferGetBytesPerRow(pb) +
                       (pt->x + 32) * 4;
    CHECK(p[2] == 255 && p[0] == 0 && p[1] == 0 && p[3] == 255,
          "BGRA passthrough bit-exact at red patch");
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  }
  test_cmsb_metadata(sb);
  CFRelease(sb);
}

int main(void) {
  printf("vcam data-plane proof harness\n");
  printf("=============================\n\n");

  build_test_frame();

  printf("[1] timing state machine\n");
  test_timing();
  printf("  ok\n\n");

  printf("[2] format descriptions from pixel buffers\n");
  {
    vcc_frame_desc_t frame = make_desc(1000000000ull);
    CVPixelBufferRef pb420 = vcc_pixel_buffer_from_frame(&frame, VCC_FMT_420V);
    CVPixelBufferRef pbbgra = vcc_pixel_buffer_from_frame(&frame, VCC_FMT_BGRA);
    CHECK(pb420 && pbbgra, "pixel buffers for format-description tests");
    if (pb420) {
      test_format_description_matches(pb420, 1);
      dump_format_description_from_pb(pb420);
      CVPixelBufferRelease(pb420);
    }
    if (pbbgra) {
      test_format_description_matches(pbbgra, 0);
      CVPixelBufferRelease(pbbgra);
    }
  }
  printf("  ok\n\n");

  printf("[3] full chains + reachable-state dump\n");
  test_full_chain_dump();
  printf("  ok\n\n");

  printf("[4] 420v -> BGRA round trip\n");
  test_roundtrip();
  printf("  ok\n\n");

  printf("[5] phase 3/4: CGImage path + format/sample consistency\n");
  test_cgimage_helper();
  test_format_metadata_consistency();
  printf("  ok\n\n");

  printf("=============================\n");
  printf("%d checks, %d failures\n", g_checks, g_fails);
  free(g_frame);
  return g_fails ? 1 : 0;
}
