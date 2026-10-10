/*
 * Host proof harness for the crop / size / turn plan libcamfix uses when it
 * delivers frames to an AVCaptureVideoDataOutput
 * (CamFix/Frame/CamFixFrameGeometry.c).
 *
 * Build/run:  make -C VPhoneGuestComponents test-camfix-geometry
 */

#include "CamFixFrameGeometry.h"

#include <stdio.h>

static int g_checks = 0;
static int g_fails = 0;

#define CHECK(cond, ...)                          \
  do {                                            \
    g_checks++;                                   \
    if (!(cond)) {                                \
      g_fails++;                                  \
      printf("FAIL %s:%d: ", __FILE__, __LINE__); \
      printf(__VA_ARGS__);                        \
      printf("\n");                               \
    }                                             \
  } while (0)

static cfx_frame_plan_t plan(uint32_t fw, uint32_t fh, uint32_t pw, uint32_t ph, int angle,
                             double zoom) {
  cfx_frame_plan_t p = {0};
  CHECK(cfx_frame_plan(fw, fh, pw, ph, angle, zoom, &p) == 0, "plan failed");
  return p;
}

static void check_inside(cfx_frame_plan_t p, uint32_t fw, uint32_t fh) {
  CHECK(p.crop_x + p.crop_w <= fw && p.crop_y + p.crop_h <= fh,
        "crop %u,%u %ux%u outside %ux%u", p.crop_x, p.crop_y, p.crop_w, p.crop_h, fw, fh);
  CHECK(p.crop_w % 2 == 0 && p.crop_h % 2 == 0, "odd crop %ux%u", p.crop_w, p.crop_h);
  CHECK(p.crop_x % 2 == 0 && p.crop_y % 2 == 0, "odd origin %u,%u", p.crop_x, p.crop_y);
}

int main(void) {
  // Landscape connection, preset matching the frame aspect: whole frame.
  cfx_frame_plan_t p = plan(1280, 720, 1280, 720, 0, 1);
  CHECK(p.crop_w == 1280 && p.crop_h == 720 && p.crop_x == 0 && p.crop_y == 0,
        "1280x720 landscape crop %ux%u", p.crop_w, p.crop_h);
  CHECK(p.out_w == 1280 && p.out_h == 720 && p.turns == 0, "1280x720 landscape out");

  // 640x480 landscape: 4:3 centre of a 16:9 frame, scaled to the preset.
  p = plan(1280, 720, 640, 480, 0, 1);
  CHECK(p.crop_w == 960 && p.crop_h == 720 && p.crop_x == 160, "4:3 crop %ux%u@%u",
        p.crop_w, p.crop_h, p.crop_x);
  CHECK(p.out_w == 640 && p.out_h == 480, "640x480 out %ux%u", p.out_w, p.out_h);
  check_inside(p, 1280, 720);

  // Portrait connection: 3:4 crop, delivered at 480x640, not turned.
  p = plan(1280, 720, 640, 480, 90, 1);
  CHECK(p.crop_w == 540 && p.crop_h == 720 && p.crop_x == 370, "3:4 crop %ux%u@%u",
        p.crop_w, p.crop_h, p.crop_x);
  CHECK(p.out_w == 480 && p.out_h == 640 && p.turns == 0, "portrait out %ux%u turns %d",
        p.out_w, p.out_h, p.turns);
  check_inside(p, 1280, 720);

  // Upside down portrait and landscape-left turn the picture over.
  CHECK(plan(1280, 720, 640, 480, 270, 1).turns == 2, "270 turns");
  CHECK(plan(1280, 720, 640, 480, 180, 1).turns == 2, "180 turns");
  CHECK(plan(1280, 720, 640, 480, -90, 1).out_h == 640, "-90 is portrait");

  // No preset: deliver the crop at its own size, portrait aspect for portrait.
  p = plan(1280, 720, 0, 0, 90, 1);
  CHECK(p.out_w == p.crop_w && p.out_h == p.crop_h && p.crop_h == 720 && p.crop_w == 404,
        "no-preset portrait %ux%u", p.out_w, p.out_h);
  p = plan(1280, 720, 0, 0, 0, 1);
  CHECK(p.out_w == 1280 && p.out_h == 720, "no-preset landscape %ux%u", p.out_w, p.out_h);

  // Zoom crops further in around the centre; below 1 counts as 1.
  p = plan(1280, 720, 640, 480, 90, 2);
  CHECK(p.crop_w == 270 && p.crop_h == 360 && p.crop_x == 504 && p.crop_y == 180,
        "zoom 2 crop %ux%u@%u,%u", p.crop_w, p.crop_h, p.crop_x, p.crop_y);
  CHECK(p.out_w == 480 && p.out_h == 640, "zoom keeps the delivered size");
  CHECK(plan(1280, 720, 640, 480, 90, 0.5).crop_w == 540, "zoom below 1");

  // Odd frame sizes stay even and inside.
  for (uint32_t w = 101; w < 140; w += 7) {
    for (uint32_t h = 61; h < 120; h += 11) {
      for (int a = 0; a < 360; a += 90) {
        check_inside(plan(w, h, 640, 480, a, 1.3), w, h);
        check_inside(plan(w, h, 0, 0, a, 1), w, h);
      }
    }
  }

  cfx_frame_plan_t q;
  CHECK(cfx_frame_plan(0, 720, 640, 480, 0, 1, &q) == -1, "empty frame");

  printf("%d checks, %d failures\n", g_checks, g_fails);
  return g_fails ? 1 : 0;
}
