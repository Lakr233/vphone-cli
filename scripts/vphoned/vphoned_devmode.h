/*
 * vphoned_devmode — Developer mode control via AMFI XPC.
 *
 * Talks to com.apple.amfi.xpc to query / arm developer mode.
 * Reference: TrollStore RootHelper/devmode.m
 * Requires entitlement: com.apple.private.amfi.developer-mode-control
 */

#pragma once
#import <Foundation/Foundation.h>

/// Load XPC/CoreFoundation symbols. Returns NO on failure (devmode disabled).
BOOL vp_devmode_load(void);

/// Whether devmode XPC is available (load succeeded).
BOOL vp_devmode_available(void);

/// Query current developer mode status.
BOOL vp_devmode_status(void);

/// Arm developer mode. Returns YES on success. Sets *alreadyEnabled if already on.
BOOL vp_devmode_arm(BOOL *alreadyEnabled);
