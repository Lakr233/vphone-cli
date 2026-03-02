/*
 * vphoned_hid — HID event injection via IOKit private API.
 *
 * Matches TrollVNC's STHIDEventGenerator approach: create an
 * IOHIDEventSystemClient, fabricate keyboard events, and dispatch.
 */

#pragma once
#import <Foundation/Foundation.h>

/// Load IOKit symbols and create HID event client. Returns NO on failure.
BOOL vp_hid_load(void);

/// Send a full key press (down + 100ms delay + up).
void vp_hid_press(uint32_t page, uint32_t usage);

/// Send a single key down or key up event.
void vp_hid_key(uint32_t page, uint32_t usage, BOOL down);
