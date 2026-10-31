#import "HomePodSetupState.h"
#import <sys/stat.h>

#define CHECK(condition) do { if (!(condition)) { NSLog(@"Failed at line %d: %s", __LINE__, #condition); abort(); } } while (0)

int main(void) {
    @autoreleasepool {
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSURL *journal = [NSURL fileURLWithPath:[path stringByAppendingPathComponent:@"state/original.plist"]];
        NSMutableDictionary *preferences = [@{@"SetupDone": @NO, @"Unrelated": @"unchanged"} mutableCopy];
        __block NSUInteger writes = 0;
        void (^set)(NSString *, id) = ^(NSString *key, id value) {
            writes++;
            if (value) preferences[key] = value;
            else [preferences removeObjectForKey:key];
        };
        NSError *error = nil;
        CHECK(VPHomePodSetupUpdate(NO, journal, preferences, set, ^BOOL { return YES; }, &error));
        CHECK(writes == 0);
        CHECK(VPHomePodSetupUpdate(YES, journal, preferences, set, ^BOOL { return YES; }, &error));
        CHECK([preferences[@"SetupDone"] isEqual:@YES]);
        CHECK([preferences[@"SetupFinishedAllSteps"] isEqual:@YES]);
        CHECK([preferences[@"Unrelated"] isEqual:@"unchanged"]);
        NSData *originalJournal = [NSData dataWithContentsOfURL:journal];
        struct stat metadata;
        CHECK(stat(journal.path.fileSystemRepresentation, &metadata) == 0 && (metadata.st_mode & 0777) == 0600);
        // Updating an enabled VM must retain the pre-bypass values rather than
        // snapshotting the values already written by an earlier boot.
        CHECK(VPHomePodSetupUpdate(YES, journal, preferences, set, ^BOOL { return YES; }, &error));
        CHECK([[NSData dataWithContentsOfURL:journal] isEqual:originalJournal]);
        preferences[@"Unrelated"] = @"edited after enable";
        CHECK(VPHomePodSetupUpdate(NO, journal, preferences, set, ^BOOL { return YES; }, &error));
        CHECK([preferences[@"SetupDone"] isEqual:@NO]);
        CHECK(preferences[@"SetupFinishedAllSteps"] == nil);
        CHECK([preferences[@"Unrelated"] isEqual:@"edited after enable"]);
        // A native sentinel failure after preference synchronization still
        // needs the journal on the next attempt. Only main removes it after
        // the stock framework reports the expected state.
        CHECK([NSFileManager.defaultManager fileExistsAtPath:journal.path]);
        CHECK(VPHomePodSetupUpdate(NO, journal, preferences, set, ^BOOL { return YES; }, &error));
        CHECK([preferences[@"SetupDone"] isEqual:@NO] && preferences[@"SetupFinishedAllSteps"] == nil);
        CHECK([NSFileManager.defaultManager removeItemAtURL:journal error:&error]);
        // Failed synchronization retains the inverse so a retry or disable can
        // still recover. The failure does not silently become an applied state.
        CHECK(!VPHomePodSetupUpdate(YES, journal, preferences, set, ^BOOL { return NO; }, &error));
        CHECK(error != nil && [NSFileManager.defaultManager fileExistsAtPath:journal.path]);
        CHECK(VPHomePodSetupUpdate(NO, journal, preferences, set, ^BOOL { return YES; }, &error));
        CHECK([preferences[@"SetupDone"] isEqual:@NO] && preferences[@"SetupFinishedAllSteps"] == nil);
        // Refuse a corrupted/expanded journal without writing any preferences.
        [@{@"Version": @1, @"Original": @{@"Unexpected": @YES}, @"Absent": @[]} writeToURL:journal atomically:YES];
        NSUInteger before = writes;
        CHECK(!VPHomePodSetupUpdate(NO, journal, preferences, set, ^BOOL { return YES; }, &error));
        CHECK(writes == before);
        // Both keys appearing in the union is insufficient: a duplicate in
        // Absent or overlap with Original must not be accepted as an inverse.
        for (NSDictionary *invalid in @[
            @{@"Version": @1, @"Original": @{@"SetupDone": @NO}, @"Absent": @[@"SetupFinishedAllSteps", @"SetupFinishedAllSteps"]},
            @{@"Version": @1, @"Original": @{@"SetupDone": @NO}, @"Absent": @[@"SetupDone", @"SetupFinishedAllSteps"]},
        ]) {
            CHECK([invalid writeToURL:journal atomically:YES]);
            CHECK(!VPHomePodSetupUpdate(NO, journal, preferences, set, ^BOOL { return YES; }, &error));
            CHECK(writes == before);
        }
        [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
        // Model the donor: needsSetup reads the semaphore, while prepare reads
        // synchronized completion flags and emits only on sentinel creation.
        __block BOOL sentinel = NO, persistedComplete = YES, prepareFails = NO;
        __block NSUInteger nativeEvents = 0, replayEvents = 0, prepared = 0;
        BOOL (^needs)(void) = ^BOOL { return !sentinel; };
        BOOL (^completed)(void) = ^BOOL { return persistedComplete; };
        void (^prepare)(void) = ^{
            prepared++;
            if (prepareFails) return;
            if (persistedComplete && !sentinel) nativeEvents++;
            sentinel = persistedComplete;
        };
        BOOL (^publish)(void) = ^BOOL {
            CHECK(prepared > 0 && sentinel && persistedComplete);
            replayEvents++;
            return YES;
        };
        CHECK(VPHomePodSetupPrepare(YES, NO, YES, needs, completed, prepare, publish, &error));
        CHECK(nativeEvents == 1 && replayEvents == 0); // First completion: exactly one native event.
        CHECK(VPHomePodSetupPrepare(YES, NO, YES, needs, completed, prepare, publish, &error));
        CHECK(nativeEvents == 1 && replayEvents == 1); // Existing sentinel: recover the event explicitly.
        persistedComplete = NO;
        CHECK(VPHomePodSetupPrepare(NO, YES, NO, needs, completed, prepare, publish, &error));
        CHECK(!sentinel && nativeEvents == 1 && replayEvents == 1); // Opt-out cannot publish completion.
        persistedComplete = YES; prepareFails = YES;
        CHECK(!VPHomePodSetupPrepare(YES, NO, YES, needs, completed, prepare, publish, &error));
        CHECK(!sentinel && nativeEvents == 1 && replayEvents == 1); // Verify before any explicit event.
        prepareFails = NO; sentinel = YES;
        CHECK(!VPHomePodSetupPrepare(YES, NO, YES, needs, completed, prepare, ^BOOL { return NO; }, &error));
        CHECK(error != nil); // Existing-state publication failure must remain retryable.
        // HomeView uses the native ForceNoBuddy override only. Preserve the
        // distinction between an absent preference and an explicit false/true,
        // and never overwrite setup choices or snapshot our own override.
        for (id original in @[NSNull.null, @NO, @YES]) {
            NSURL *homeJournal = [NSURL fileURLWithPath:[path stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
            NSMutableDictionary *homePreferences = [@{@"SetupDone": @NO, @"SetupFinishedAllSteps": @NO} mutableCopy];
            if (original != NSNull.null) homePreferences[@"ForceNoBuddy"] = original;
            void (^homeSet)(NSString *, id) = ^(NSString *key, id value) {
                CHECK([key isEqual:@"ForceNoBuddy"]);
                if (value) homePreferences[key] = value;
                else [homePreferences removeObjectForKey:key];
            };
            CHECK(VPSetupUpdateKeys(@[@"ForceNoBuddy"], YES, homeJournal, homePreferences, homeSet, ^BOOL { return YES; }, &error));
            CHECK([homePreferences[@"ForceNoBuddy"] isEqual:@YES]);
            CHECK(VPSetupUpdateKeys(@[@"ForceNoBuddy"], YES, homeJournal, homePreferences, homeSet, ^BOOL { return YES; }, &error));
            CHECK(VPSetupUpdateKeys(@[@"ForceNoBuddy"], NO, homeJournal, homePreferences, homeSet, ^BOOL { return YES; }, &error));
            CHECK(original == NSNull.null ? homePreferences[@"ForceNoBuddy"] == nil : [homePreferences[@"ForceNoBuddy"] isEqual:original]);
            CHECK([homePreferences[@"SetupDone"] isEqual:@NO] && [homePreferences[@"SetupFinishedAllSteps"] isEqual:@NO]);
            CHECK(!VPHomePodSetupUpdate(NO, homeJournal, homePreferences, homeSet, ^BOOL { return YES; }, &error));
        }
        [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
        NSLog(@"HomePod setup journal and native transition tests passed");
    }
    return 0;
}
