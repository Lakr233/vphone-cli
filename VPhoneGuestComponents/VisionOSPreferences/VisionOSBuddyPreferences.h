#import <Foundation/Foundation.h>

// Only ForceNoBuddy belongs to this repair. No completion, account, activation
// or enrollment flags are read or written.
BOOL VPVisionOSBuddyUpdate(BOOL enabled, NSURL *journalURL, NSDictionary<NSString *, id> *current,
                          void (^setValue)(NSString *, id), BOOL (^synchronize)(void), NSError **error);
// Publishes a new inverse durably and refuses to replace another writer's file.
BOOL VPVisionOSBuddySaveJournal(NSDictionary *journal, NSURL *url, NSError **error);
