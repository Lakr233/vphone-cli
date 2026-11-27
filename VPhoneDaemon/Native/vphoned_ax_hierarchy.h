#pragma once
#import <Foundation/Foundation.h>
typedef struct {
 CFTypeRef (*createApp)(pid_t);
 int (*copy)(CFTypeRef,CFStringRef,CFTypeRef *);
 int (*setTimeout)(CFTypeRef,float);
 CFTypeID (*elementTypeID)(void);
 CFTypeID (*valueTypeID)(void);
 Boolean (*getValue)(CFTypeRef,int,void *);
} VPAxFunctions;
NSDictionary *vp_ax_walk(VPAxFunctions functions, CFTypeRef root, pid_t pid, int maxElements, int maxDepth, int timeoutMS);
// switchesEnabled is true only when this invocation enabled a previously disabled AX switch.
NSDictionary *vp_ax_walk_with_readiness(VPAxFunctions functions, CFTypeRef root, pid_t pid, int maxElements, int maxDepth, int timeoutMS, BOOL switchesEnabled);
NSDictionary *vp_ax_hierarchy(int pid, int maxElements, int maxDepth, int timeoutMS);
// Loads the AXRuntime symbols the walker and the element operations share.
VPAxFunctions vp_ax_load_functions(void);
// Switches AX on for the duration of `body` and restores both switches afterwards. The returned
// dictionary carries requesting_client, requesting_client_override, switches_before and
// switches_after_restore. `enabledForInvocation` is true only when this call enabled a switch.
NSDictionary *vp_ax_with_enabled(void (^body)(BOOL enabledForInvocation));
