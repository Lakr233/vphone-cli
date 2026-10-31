#import <Foundation/Foundation.h>

// Only these local completion flags belong to the bypass. Account, activation,
// HomeKit and Wi-Fi state remain owned by their native services.
NSArray<NSString *> *VPHomePodSetupKeys(void);
// The journalled update below, with every key set to YES while enabled.
BOOL VPSetupUpdateKeys(NSArray<NSString *> *keys, BOOL enabled, NSURL *journalURL,
                       NSDictionary<NSString *, id> *current, void (^setValue)(NSString *, id),
                       BOOL (^synchronize)(void), NSError **error);
BOOL VPHomePodSetupUpdate(BOOL enabled, NSURL *journalURL, NSDictionary<NSString *, id> *current,
                         void (^setValue)(NSString *, id), BOOL (^synchronize)(void), NSError **error);

// AirPlay's own override for a virtual machine (AirPlaySupport reads it in
// APSIsVirtualMachine, domain com.apple.airplay): with it set, AirPlay keeps
// discovery and its own endpoint on a VM.
NSArray<NSString *> *VPHomePodAirPlayKeys(void);

// The journalled update both use: while enabled, each key gets its value from
// enabledValues; turning it off restores exactly the recorded originals,
// including which keys were absent. The journal is written before any value.
BOOL VPHomePodPreferenceUpdate(NSArray<NSString *> *keys, NSDictionary<NSString *, id> *enabledValues,
                              BOOL enabled, NSURL *journalURL, NSDictionary<NSString *, id> *current,
                              void (^setValue)(NSString *, id), BOOL (^synchronize)(void), NSError **error);

// Call after preferences synchronize. Native prepare publishes a new sentinel's
// completion itself; only an already-completed state needs an explicit replay.
BOOL VPHomePodSetupPrepare(BOOL enabled, BOOL expectedNeedsSetup, BOOL expectedCompleted,
                          BOOL (^needsSetup)(void), BOOL (^completed)(void), void (^prepare)(void),
                          BOOL (^publishFinished)(void), NSError **error);
