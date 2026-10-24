/*
 * vphoned_pose — set a foldable guest's device pose.
 *
 * A VM has no hinge, and SpringBoard only consumes CoreMotion's hinge angle
 * and magic pose on a board CoreMotion recognizes with two always-connected
 * displays. SpringBoardServices' test-automation client sets the pose
 * directly: SpringBoard builds a synthetic magic pose from the device
 * orientation, hinge state and tabletop pose, and derives the hinge angle
 * from the hinge state. The server checks the client for
 * com.apple.springboard.testautomation, which vphoned carries.
 *
 * The class is resolved at run time, so a base without it reports false.
 */

#import "Include/VphonedNative.h"

#include <dlfcn.h>
#include <objc/message.h>

/// The override `-[SBSTestAutomationService setDevicePoseOverride:]` takes, as
/// SpringBoard's handler reads it: a 64-bit orientation, then the device
/// orientation, hinge state and tabletop pose as 32-bit values.
typedef struct {
    int64_t orientation;
    int32_t deviceOrientation;
    int32_t hingeState;
    int32_t tabletopPose;
} VPDevicePoseOverride;

bool vp_device_pose_set(int deviceOrientation, int hingeState, int tabletopPose) {
    static Class service;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
        service = NSClassFromString(@"SBSTestAutomationService");
    });
    SEL selector = NSSelectorFromString(@"setDevicePoseOverride:");
    if (!service || ![service instancesRespondToSelector:selector]) return false;
    id client = [service new];
    VPDevicePoseOverride pose = {deviceOrientation, deviceOrientation, hingeState, tabletopPose};
    ((void (*)(id, SEL, VPDevicePoseOverride))objc_msgSend)(client, selector, pose);
    return true;
}
