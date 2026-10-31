#import "HomePodSetupProcesses.h"
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <string.h>

// libproc.h / sys/proc_info.h: the tvOS SDK exports libproc.tbd but omits
// these declarations. PROC_UID_ONLY filters by effective uid (not real uid).
static const uint32_t VPProcUIDOnly = 4;
static const char *VPSetupExecutable = "/Applications/HPSetup.app/HPSetup";

static BOOL VPProcessError(NSError **error, NSString *description) {
    if (error) *error = [NSError errorWithDomain:@"com.vphone.homepod-setup" code:4
                                      userInfo:@{NSLocalizedDescriptionKey: description}];
    return NO;
}

static BOOL VPPathMatches(const char *path, NSArray<NSString *> *executables) {
    for (NSString *executable in executables) {
        if (strcmp(path, executable.fileSystemRepresentation) == 0) return YES;
    }
    return NO;
}

static NSArray<NSNumber *> *VPOwnedProcesses(VPHomePodSetupProcessAPI api, uid_t user, NSArray<NSString *> *executables,
                                             NSError **error) {
    int needed = api.listPIDs(VPProcUIDOnly, user, NULL, 0);
    if (needed <= 0) { VPProcessError(error, @"Could not enumerate mobile's processes."); return nil; }
    NSUInteger capacity = (NSUInteger)needed + 128 * sizeof(pid_t);
    for (NSUInteger attempt = 0; attempt < 3 && capacity <= 1024 * 1024; attempt++, capacity *= 2) {
        NSMutableData *data = [NSMutableData dataWithLength:capacity];
        int bytes = api.listPIDs(VPProcUIDOnly, user, data.mutableBytes, (int)data.length);
        if (bytes <= 0 || bytes % sizeof(pid_t)) {
            VPProcessError(error, @"Invalid mobile process enumeration."); return nil;
        }
        if ((NSUInteger)bytes >= capacity) continue;
        NSMutableArray *found = [NSMutableArray array];
        const pid_t *pids = data.bytes;
        for (NSUInteger index = 0; index < (NSUInteger)bytes / sizeof(pid_t); index++) {
            if (pids[index] <= 0) continue;
            char path[PATH_MAX] = {0};
            errno = 0;
            int length = api.processPath(pids[index], path, sizeof(path));
            if (length <= 0) {
                if (errno == EACCES || errno == EPERM) {
                    VPProcessError(error, @"Cannot verify an owned process's executable; refusing to claim setup teardown."); return nil;
                }
                continue; // Exited during enumeration, or no executable remains.
            }
            if ((size_t)length < sizeof(path) && VPPathMatches(path, executables)) [found addObject:@(pids[index])];
        }
        return found;
    }
    VPProcessError(error, @"Mobile process enumeration did not stabilize within its bounds.");
    return nil;
}

BOOL VPHomePodSetupStopProcesses(VPHomePodSetupProcessAPI api, uid_t user,
                                NSUInteger maximumPolls, void (^wait)(void), NSError **error) {
    if (user != 501 || !api.listPIDs || !api.processPath || !api.signalProcess || !wait) {
        return VPProcessError(error, @"HomePod setup teardown requires mobile and the native process APIs.");
    }
    NSMutableSet *signaled = [NSMutableSet set];
    NSUInteger quietPolls = 0;
    for (NSUInteger poll = 0; poll <= maximumPolls; poll++) {
        NSArray<NSNumber *> *pids = VPOwnedProcesses(api, user, @[@(VPSetupExecutable)], error);
        if (!pids) return NO;
        // Observe a short quiet interval too: an app launch requested before
        // completion may still have been in flight when the first scan ran.
        quietPolls = pids.count ? 0 : quietPolls + 1;
        if (quietPolls >= 5) return YES;
        for (NSNumber *pid in pids) {
            if ([signaled containsObject:pid]) continue;
            char path[PATH_MAX] = {0};
            int length = api.processPath(pid.intValue, path, sizeof(path));
            if (length <= 0) continue;
            if ((size_t)length >= sizeof(path) || strcmp(path, VPSetupExecutable)) continue;
            if (api.signalProcess(pid.intValue, SIGTERM) != 0 && errno != ESRCH) {
                return VPProcessError(error, @"Could not gracefully stop HomePod setup; no stronger signal was sent.");
            }
            [signaled addObject:pid];
        }
        if (poll < maximumPolls) wait();
    }
    return VPProcessError(error, @"HomePod setup is still running after its graceful completion deadline; journal retained.");
}

NSArray<NSString *> *VPHomePodAirPlayExecutables(void) {
    return @[@"/usr/libexec/airplayd", @"/usr/libexec/tvairplayd",
             @"/System/Library/PrivateFrameworks/MediaRemote.framework/Support/mediaremoted"];
}

BOOL VPHomePodRestartProcesses(VPHomePodSetupProcessAPI api, uid_t user, NSArray<NSString *> *executables,
                               NSUInteger *signaled, NSError **error) {
    if (signaled) *signaled = 0;
    if (user != 501 || !api.listPIDs || !api.processPath || !api.signalProcess || !executables.count) {
        return VPProcessError(error, @"Restarting AirPlay requires mobile and the native process APIs.");
    }
    NSArray<NSNumber *> *pids = VPOwnedProcesses(api, user, executables, error);
    if (!pids) return NO;
    for (NSNumber *pid in pids) {
        // The identity is checked again right before the signal, as for setup.
        char path[PATH_MAX] = {0};
        int length = api.processPath(pid.intValue, path, sizeof(path));
        if (length <= 0 || (size_t)length >= sizeof(path) || !VPPathMatches(path, executables)) continue;
        if (api.signalProcess(pid.intValue, SIGTERM) != 0) {
            if (errno == ESRCH) continue;
            return VPProcessError(error, @"Could not restart an AirPlay daemon.");
        }
        if (signaled) *signaled += 1;
    }
    return YES;
}
