// A real camera delivers what the session preset and the connection ask for:
// 640x480 at angle 0, 480x640 for a portrait connection, upside down at 180.
// The shm frame is already the upright picture, so a portrait connection gets
// a portrait crop of it rather than a rotated landscape frame, and 180 / 270
// turn that picture over.

#include "CamFixFrameGeometry.h"

#include <stddef.h>

int cfx_frame_plan(uint32_t frame_w, uint32_t frame_h, uint32_t preset_w,
                   uint32_t preset_h, int angle, double zoom,
                   cfx_frame_plan_t *plan) {
  if (!plan || !frame_w || !frame_h) return -1;
  int a = ((angle % 360) + 360) % 360;
  int portrait = (a == 90 || a == 270);

  // Aspect of the delivered picture: the preset turned for the connection,
  // or the frame's own (turned for portrait) when the preset pins none.
  uint32_t aw = preset_w ? preset_w : frame_w;
  uint32_t ah = preset_h ? preset_h : frame_h;
  if (portrait) {
    uint32_t t = aw;
    aw = ah;
    ah = t;
  }

  // Largest aw:ah rectangle inside the frame, shrunk by zoom, kept even for
  // 4:2:0 output and centred.
  if (zoom < 1) zoom = 1;
  double sx = (double)frame_w / aw, sy = (double)frame_h / ah;
  double s = (sx < sy ? sx : sy) / zoom;
  uint32_t cw = (uint32_t)(aw * s) & ~1u;
  uint32_t ch = (uint32_t)(ah * s) & ~1u;
  if (cw < 2) cw = 2;
  if (ch < 2) ch = 2;
  if (cw > frame_w) cw = frame_w & ~1u;
  if (ch > frame_h) ch = frame_h & ~1u;

  plan->crop_w = cw;
  plan->crop_h = ch;
  plan->crop_x = ((frame_w - cw) / 2) & ~1u;
  plan->crop_y = ((frame_h - ch) / 2) & ~1u;
  plan->out_w = preset_w ? (portrait ? preset_h : preset_w) : cw;
  plan->out_h = preset_h ? (portrait ? preset_w : preset_h) : ch;
  plan->turns = (a >= 180) ? 2 : 0;
  return 0;
}
