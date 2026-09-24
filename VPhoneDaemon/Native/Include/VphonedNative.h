#pragma once
#import <Foundation/Foundation.h>

/// vphone-specific operations that IcliKit does not own.
NSDictionary *vp_native_api_command(NSDictionary *message);
void vp_native_bootstrap_cached_binary(void);
void vp_native_confirm_cached_binary(void);
void vp_vcam_start(void);
/// Returns 0 on acceptance, -1 when unavailable, -2 on timeout, or -3 on rejection.
int vp_low_power_mode_set_async(bool enabled);
/// A malloc-owned bundle ID only when one live app has RunningBoard's focal assertion.
char *vp_runningboard_focal_bundle_id(void);
