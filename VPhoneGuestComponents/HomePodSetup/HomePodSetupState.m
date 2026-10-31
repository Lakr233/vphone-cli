#import "HomePodSetupState.h"

NSArray<NSString *> *VPHomePodSetupKeys(void) {
    return @[@"SetupDone", @"SetupFinishedAllSteps"];
}

NSArray<NSString *> *VPHomePodAirPlayKeys(void) {
    return @[@"useWiFiAndAWDLOnVirtualMachine"];
}

static BOOL VPSetupError(NSError **error, NSString *description) {
    if (error) *error = [NSError errorWithDomain:@"com.vphone.homepod-setup" code:1
                                      userInfo:@{NSLocalizedDescriptionKey: description}];
    return NO;
}

BOOL VPHomePodSetupUpdate(BOOL enabled, NSURL *journalURL, NSDictionary<NSString *, id> *current,
                         void (^setValue)(NSString *, id), BOOL (^synchronize)(void), NSError **error) {
    return VPSetupUpdateKeys(VPHomePodSetupKeys(), enabled, journalURL, current, setValue, synchronize, error);
}

BOOL VPSetupUpdateKeys(NSArray<NSString *> *keys, BOOL enabled, NSURL *journalURL,
                       NSDictionary<NSString *, id> *current, void (^setValue)(NSString *, id),
                       BOOL (^synchronize)(void), NSError **error) {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSString *key in keys) values[key] = @YES;
    return VPHomePodPreferenceUpdate(keys, values, enabled, journalURL, current, setValue, synchronize, error);
}

BOOL VPHomePodPreferenceUpdate(NSArray<NSString *> *keys, NSDictionary<NSString *, id> *enabledValues,
                              BOOL enabled, NSURL *journalURL, NSDictionary<NSString *, id> *current,
                              void (^setValue)(NSString *, id), BOOL (^synchronize)(void), NSError **error) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSDictionary *journal = nil;
    if ([files fileExistsAtPath:journalURL.path]) {
        NSData *data = [NSData dataWithContentsOfURL:journalURL options:0 error:error];
        if (!data) return NO;
        journal = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:error];
        if (![journal isKindOfClass:NSDictionary.class] || ![journal[@"Version"] isEqual:@1]
            || ![journal[@"Original"] isKindOfClass:NSDictionary.class]
            || ![journal[@"Absent"] isKindOfClass:NSArray.class]) {
            return VPSetupError(error, @"Refusing an invalid HomePod preference journal.");
        }
        NSMutableSet *recorded = [NSMutableSet setWithArray:[journal[@"Original"] allKeys]];
        [recorded addObjectsFromArray:journal[@"Absent"]];
        if (![recorded isEqualToSet:[NSSet setWithArray:keys]]
            || [[journal[@"Original"] allKeys] count] + [journal[@"Absent"] count] != recorded.count) {
            return VPSetupError(error, @"HomePod preference journal contains unexpected or duplicate keys.");
        }
    }
    if (!enabled && !journal) return YES;
    if (enabled && !journal) {
        NSMutableDictionary *original = [NSMutableDictionary dictionary];
        NSMutableArray *absent = [NSMutableArray array];
        for (NSString *key in keys) {
            if (current[key]) original[key] = current[key];
            else [absent addObject:key];
        }
        journal = @{@"Version": @1, @"Original": original, @"Absent": absent};
        if (![files createDirectoryAtURL:journalURL.URLByDeletingLastPathComponent
              withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:error]) return NO;
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:journal
                                                                 format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
        // Persist the inverse before touching preferences. A failed write must
        // never leave values whose originals cannot be restored.
        if (!data || ![data writeToURL:journalURL options:NSDataWritingAtomic error:error]) return NO;
        if (![files setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:journalURL.path error:error]) return NO;
    }
    for (NSString *key in keys) {
        setValue(key, enabled ? enabledValues[key] : journal[@"Original"][key]);
    }
    if (!synchronize()) return VPSetupError(error, @"Could not synchronize HomePod preferences; journal retained.");
    // For setup, the caller must prepare and verify the native launch sentinel before
    // deleting a restored journal. Preference synchronization alone is not
    // proof that SoundBoard sees the new setup state.
    return YES;
}

BOOL VPHomePodSetupPrepare(BOOL enabled, BOOL expectedNeedsSetup, BOOL expectedCompleted,
                          BOOL (^needsSetup)(void), BOOL (^completed)(void), void (^prepare)(void),
                          BOOL (^publishFinished)(void), NSError **error) {
    // Read the native gate before prepare changes its sentinel. Reading only
    // afterward would cause both prepare and our replay to initialize SoundBoard.
    BOOL neededBeforePrepare = needsSetup();
    prepare();
    if (needsSetup() != expectedNeedsSetup || completed() != expectedCompleted) {
        return VPSetupError(error, @"SetupAssistant did not accept the synchronized setup state; journal retained.");
    }
    if (enabled && !neededBeforePrepare && !publishFinished()) {
        return VPSetupError(error, @"Could not publish native HomePod setup completion; journal retained.");
    }
    return YES;
}
