#import <Foundation/Foundation.h>

// Only these local completion flags belong to the bypass. Account, activation,
// HomeKit and Wi-Fi state remain owned by their native services.
NSArray<NSString *> *VPHomePodSetupKeys(void);
BOOL VPSetupUpdateKeys(NSArray<NSString *> *keys, BOOL enabled, NSURL *journalURL,
                       NSDictionary<NSString *, id> *current, void (^setValue)(NSString *, id),
                       BOOL (^synchronize)(void), NSError **error);
BOOL VPHomePodSetupUpdate(BOOL enabled, NSURL *journalURL, NSDictionary<NSString *, id> *current,
                         void (^setValue)(NSString *, id), BOOL (^synchronize)(void), NSError **error);

// Call after preferences synchronize. Native prepare publishes a new sentinel's
// completion itself; only an already-completed state needs an explicit replay.
BOOL VPHomePodSetupPrepare(BOOL enabled, BOOL expectedNeedsSetup, BOOL expectedCompleted,
                          BOOL (^needsSetup)(void), BOOL (^completed)(void), void (^prepare)(void),
                          BOOL (^publishFinished)(void), NSError **error);
