#import <Foundation/Foundation.h>
#include <sys/types.h>

typedef struct {
    int (*listPIDs)(uint32_t, uint32_t, void *, int);
    int (*processPath)(int, void *, uint32_t);
    int (*signalProcess)(pid_t, int);
} VPHomePodSetupProcessAPI;

// Called only after the persisted/native completion transition. Only mobile's
// exact Apple setup executable may receive SIGTERM. No escalation to SIGKILL.
BOOL VPHomePodSetupStopProcesses(VPHomePodSetupProcessAPI api, uid_t user,
                                NSUInteger maximumPolls, void (^wait)(void), NSError **error);

// AirPlay caches APSIsVirtualMachine once per process. After the VM setting
// changed, mobile's exact AirPlay daemons get one SIGTERM each, and launchd
// starts them again with the new value. Nothing else is signalled.
NSArray<NSString *> *VPHomePodAirPlayExecutables(void);
BOOL VPHomePodRestartProcesses(VPHomePodSetupProcessAPI api, uid_t user, NSArray<NSString *> *executables,
                               NSUInteger *signaled, NSError **error);
