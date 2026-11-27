#pragma once
#import "vphoned_ax_hierarchy.h"
typedef struct {
 VPAxFunctions ax;
 int (*perform)(CFTypeRef,CFStringRef);
 int (*setValue)(CFTypeRef,CFStringRef,CFTypeRef);
} VPAxElementFunctions;
// Resolves one element from `root` by `selector` and performs `operation`. Injected functions let a
// test drive a fake tree; `switchesEnabled` is true when this invocation turned AX on.
NSDictionary *vp_ax_element_run(VPAxElementFunctions functions, CFTypeRef root, pid_t pid, NSDictionary *selector, NSDictionary *operation, BOOL switchesEnabled);
NSDictionary *vp_ax_element(int pid, NSDictionary *selector, NSDictionary *operation);
