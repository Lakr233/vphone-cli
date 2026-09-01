/*
 * vphoned_display — Dynamic guest display/backlight state probe.
 *
 * The daemon intentionally does not link against a version-specific
 * SpringBoard private framework.  It only probes classes and selectors that
 * happen to be available in the current guest at runtime.  When a compatible
 * state cannot be identified, the result is `unknown` so the Host continues
 * publishing CMIO samples rather than inventing a disconnection.
 */

#pragma once
#import <Foundation/Foundation.h>

/// Returns a JSON-safe dictionary with:
///   display_on: NSNumber bool when known, NSNull when unavailable
///   locked: NSNumber bool when known, NSNull when unavailable
///   source / lock_source: dynamic selector diagnostics when known
NSDictionary *vp_display_state_query(void);

