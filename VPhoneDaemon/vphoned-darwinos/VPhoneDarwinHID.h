#pragma once

#include <stdbool.h>
#include <stdint.h>

/// Resolves the existing system HID APIs and creates the event client.
bool vp_darwin_hid_available(void);

/// action: -1 = fixed-duration press, 0 = up, 1 = down.
/// Success means dispatch was submitted, not that a UI consumed the event.
/// On failure, error receives a malloc-owned explanation when nonnull.
bool vp_darwin_hid_submit(uint16_t page, uint16_t usage, int action, bool long_press,
                          char * _Nullable * _Nullable error);
