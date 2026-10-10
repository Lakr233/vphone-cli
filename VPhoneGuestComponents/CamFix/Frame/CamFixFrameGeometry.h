// Where a data-output frame comes from in the shm frame, and what size it
// is delivered at. Pure arithmetic, so the host test can check it.

#ifndef CAMFIX_FRAME_GEOMETRY_H
#define CAMFIX_FRAME_GEOMETRY_H

#include <stdint.h>

typedef struct {
  uint32_t crop_x, crop_y, crop_w, crop_h;  // region of the shm frame
  uint32_t out_w, out_h;                    // delivered size, before rotation
  int turns;                                // clockwise quarter turns, 0...3
} cfx_frame_plan_t;

// frame_w x frame_h: the shm frame, upright as a viewer sees it.
// preset_w x preset_h: the landscape size the session preset delivers on a
//   real camera, 0 x 0 when the preset pins none (the crop is delivered as is).
// angle: the connection's clockwise rotation angle in degrees.
// zoom: >= 1 crops further into the centre; values below 1 count as 1.
// Returns 0 on success, -1 when the frame is empty.
int cfx_frame_plan(uint32_t frame_w, uint32_t frame_h, uint32_t preset_w,
                   uint32_t preset_h, int angle, double zoom,
                   cfx_frame_plan_t *plan);

#endif
