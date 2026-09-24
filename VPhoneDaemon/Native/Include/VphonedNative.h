#pragma once
#import <Foundation/Foundation.h>

/// Sign all executable code in an extracted app. Returns a malloc-owned error or NULL.
char *vp_sign_app_for_install(const char *appPath, const char *certificatePath);
void vp_native_bootstrap_cached_binary(void);
void vp_native_confirm_cached_binary(void);
void vp_vcam_start(void);
