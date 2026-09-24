#pragma once
#import <Foundation/Foundation.h>

/// vphone-specific operations that IcliKit does not own.
NSDictionary *vp_native_api_command(NSDictionary *message);
void vp_native_bootstrap_cached_binary(void);
void vp_vcam_start(void);
