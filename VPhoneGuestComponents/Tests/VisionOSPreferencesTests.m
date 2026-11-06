#import "VisionOSBuddyPreferences.h"
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

#define CHECK(...) do { if (!(__VA_ARGS__)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #__VA_ARGS__); return 1; } } while (0)

// Observe the real implementation's persistence order without production hooks.
static NSMutableArray<NSString *> *persistenceEvents;
static NSString *failDirectorySync;
int fsync(int fd) {
    static int (*realSync)(int);
    if (!realSync) realSync = dlsym(RTLD_NEXT, "fsync");
    if (!realSync) abort();
    char path[PATH_MAX];
    struct stat metadata;
    if (persistenceEvents && fstat(fd, &metadata) == 0 && S_ISDIR(metadata.st_mode)
        && fcntl(fd, F_GETPATH, path) == 0) {
        NSString *directory = [[NSString stringWithUTF8String:path] stringByResolvingSymlinksInPath];
        [persistenceEvents addObject:[@"sync:" stringByAppendingString:directory]];
        if ([directory isEqual:failDirectorySync]) { errno = EIO; return -1; }
    }
    return realSync(fd);
}
int link(const char *source, const char *destination) {
    static int (*realLink)(const char *, const char *);
    if (!realLink) realLink = dlsym(RTLD_NEXT, "link");
    if (!realLink) abort();
    if (persistenceEvents) [persistenceEvents addObject:@"publish"];
    return realLink(source, destination);
}

static BOOL Save(NSDictionary *value, NSURL *url) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    return [data writeToURL:url atomically:YES]
        && [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:url.path error:NULL];
}

int main(void) {
    @autoreleasepool {
        NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
        CHECK([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:NULL]);
        NSURL *journal = [directory URLByAppendingPathComponent:@"Original.plist"];
        // A first install may have neither Application Support nor vphone yet.
        // Both new parent entries must precede publication and preference writes.
        NSURL *nested = [directory URLByAppendingPathComponent:@"new-support/vphone/Original.plist"];
        NSString *rootPath = directory.URLByResolvingSymlinksInPath.path;
        NSString *supportPath = [rootPath stringByAppendingPathComponent:@"new-support"];
        __block BOOL nestedWrote = NO;
        persistenceEvents = [NSMutableArray array];
        CHECK(VPVisionOSBuddyUpdate(YES, nested, @{}, ^(NSString *key, id value) {
            (void)key; (void)value;
            nestedWrote = YES;
            [persistenceEvents addObject:@"preference"];
        }, ^BOOL { return YES; }, NULL));
        CHECK(nestedWrote);
        CHECK(persistenceEvents.count == 5);
        CHECK([persistenceEvents[0] isEqual:[@"sync:" stringByAppendingString:rootPath]]);
        CHECK([persistenceEvents[1] isEqual:[@"sync:" stringByAppendingString:supportPath]]);
        CHECK([persistenceEvents[2] isEqual:@"publish"]);
        CHECK([persistenceEvents[3] isEqual:[@"sync:" stringByAppendingString:[supportPath stringByAppendingPathComponent:@"vphone"]]]);
        CHECK([persistenceEvents[4] isEqual:@"preference"]);
        persistenceEvents = nil;
        CHECK([NSFileManager.defaultManager removeItemAtURL:[directory URLByAppendingPathComponent:@"new-support"] error:NULL]);
        // Failure to persist a new parent must prevent publication and mutation.
        persistenceEvents = [NSMutableArray array];
        failDirectorySync = supportPath;
        nestedWrote = NO;
        CHECK(!VPVisionOSBuddyUpdate(YES, nested, @{}, ^(NSString *key, id value) {
            (void)key; (void)value; nestedWrote = YES;
        }, ^BOOL { return YES; }, NULL));
        CHECK(!nestedWrote && ![persistenceEvents containsObject:@"publish"]);
        CHECK(![NSFileManager.defaultManager fileExistsAtPath:nested.path]);
        persistenceEvents = nil;
        failDirectorySync = nil;
        CHECK([NSFileManager.defaultManager removeItemAtURL:[directory URLByAppendingPathComponent:@"new-support"] error:NULL]);
        for (id original in @[NSNull.null, @NO, @YES]) {
            __block NSMutableDictionary *domain = [@{@"Unrelated": @[@"keep", @42]} mutableCopy];
            if (original != NSNull.null) domain[@"ForceNoBuddy"] = original;
            __block NSUInteger writes = 0;
            __block BOOL inverseWasDurableBeforeWrite = NO;
            void (^setter)(NSString *, id) = ^(NSString *key, id value) {
                if (![key isEqual:@"ForceNoBuddy"]) abort();
                struct stat metadata;
                inverseWasDurableBeforeWrite = lstat(journal.fileSystemRepresentation, &metadata) == 0
                    && (metadata.st_mode & 0777) == 0600
                    && [NSDictionary dictionaryWithContentsOfURL:journal] != nil;
                writes++;
                if (value) domain[key] = value; else [domain removeObjectForKey:key];
            };
            NSError *error = nil;
            CHECK(VPVisionOSBuddyUpdate(YES, journal, domain, setter, ^BOOL { return YES; }, &error));
            CHECK([domain[@"ForceNoBuddy"] isEqual:@YES]);
            CHECK([original isEqual:@YES] || inverseWasDurableBeforeWrite);
            NSDictionary *firstJournal = [NSDictionary dictionaryWithContentsOfURL:journal];
            CHECK([firstJournal isEqual:@{@"Version": @1, @"Original": original == NSNull.null ? @{} : @{@"ForceNoBuddy": original},
                                         @"Absent": original == NSNull.null ? @[@"ForceNoBuddy"] : @[]}]);
            NSUInteger appliedWrites = writes;
            CHECK(VPVisionOSBuddyUpdate(YES, journal, domain, setter, ^BOOL { return YES; }, &error));
            CHECK(writes == appliedWrites);
            CHECK([[NSDictionary dictionaryWithContentsOfURL:journal] isEqual:firstJournal]);
            domain[@"Later"] = @"preserve";
            CHECK(VPVisionOSBuddyUpdate(NO, journal, domain, setter, ^BOOL { return YES; }, &error));
            CHECK(original == NSNull.null ? domain[@"ForceNoBuddy"] == nil : [domain[@"ForceNoBuddy"] isEqual:original]);
            CHECK([domain[@"Unrelated"] isEqual:@[@"keep", @42]] && [domain[@"Later"] isEqual:@"preserve"]);
            CHECK(![NSFileManager.defaultManager fileExistsAtPath:journal.path]);
            NSUInteger restoredWrites = writes;
            CHECK(VPVisionOSBuddyUpdate(NO, journal, domain, setter, ^BOOL { return YES; }, &error));
            CHECK(writes == restoredWrites);
        }
        NSDictionary *firstInverse = @{@"Version": @1, @"Original": @{}, @"Absent": @[@"ForceNoBuddy"]};
        CHECK(VPVisionOSBuddySaveJournal(firstInverse, journal, NULL));
        CHECK(!VPVisionOSBuddySaveJournal(@{@"Version": @1, @"Original": @{@"ForceNoBuddy": @YES}, @"Absent": @[]}, journal, NULL));
        CHECK([[NSDictionary dictionaryWithContentsOfURL:journal] isEqual:firstInverse]);
        CHECK([NSFileManager.defaultManager removeItemAtURL:journal error:NULL]);
        for (id invalid in @[@1, @"true", NSNull.null, @[]]) {
            __block BOOL wrote = NO;
            CHECK(!VPVisionOSBuddyUpdate(YES, journal, @{@"ForceNoBuddy": invalid}, ^(NSString *key, id value) {
                (void)key; (void)value; wrote = YES;
            }, ^BOOL { return YES; }, NULL));
            CHECK(!wrote && ![NSFileManager.defaultManager fileExistsAtPath:journal.path]);
        }
        for (NSDictionary *invalid in @[
            @{@"Version": @YES, @"Original": @{}, @"Absent": @[@"ForceNoBuddy"]},
            @{@"Version": @2, @"Original": @{}, @"Absent": @[@"ForceNoBuddy"]},
            @{@"Version": @1.0, @"Original": @{}, @"Absent": @[@"ForceNoBuddy"]},
            @{@"Version": @1, @"Original": @{@"ForceNoBuddy": @1}, @"Absent": @[]},
            @{@"Version": @1, @"Original": @{@"Other": @YES}, @"Absent": @[]},
            @{@"Version": @1, @"Original": @{}, @"Absent": @[@"ForceNoBuddy", @"ForceNoBuddy"]},
        ]) {
            CHECK(Save(invalid, journal));
            for (NSNumber *enabled in @[@NO, @YES]) {
                __block BOOL wrote = NO;
                CHECK(!VPVisionOSBuddyUpdate(enabled.boolValue, journal, @{}, ^(NSString *key, id value) {
                    (void)key; (void)value; wrote = YES;
                }, ^BOOL { return YES; }, NULL));
                CHECK(!wrote && [[NSDictionary dictionaryWithContentsOfURL:journal] isEqual:invalid]);
            }
            CHECK([NSFileManager.defaultManager removeItemAtURL:journal error:NULL]);
        }
        // Persistence failure must precede every preference callback.
        NSURL *blocker = [directory URLByAppendingPathComponent:@"not-a-directory"];
        CHECK([[@"x" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:blocker atomically:YES]);
        __block BOOL wrote = NO;
        CHECK(!VPVisionOSBuddyUpdate(YES, [blocker URLByAppendingPathComponent:@"journal"], @{}, ^(NSString *key, id value) {
            (void)key; (void)value; wrote = YES;
        }, ^BOOL { return YES; }, NULL));
        CHECK(!wrote);
        // Synchronization failures retain the inverse for a later one-shot run.
        __block NSMutableDictionary *domain = [NSMutableDictionary dictionary];
        void (^setter)(NSString *, id) = ^(NSString *key, id value) {
            if (value) domain[key] = value; else [domain removeObjectForKey:key];
        };
        CHECK(!VPVisionOSBuddyUpdate(YES, journal, domain, setter, ^BOOL { return NO; }, NULL));
        CHECK([NSFileManager.defaultManager fileExistsAtPath:journal.path] && [domain[@"ForceNoBuddy"] isEqual:@YES]);
        CHECK(VPVisionOSBuddyUpdate(NO, journal, domain, setter, ^BOOL { return YES; }, NULL));
        CHECK(domain[@"ForceNoBuddy"] == nil && ![NSFileManager.defaultManager fileExistsAtPath:journal.path]);
        CHECK([NSFileManager.defaultManager removeItemAtURL:directory error:NULL]);
        puts("visionOS preference journal tests passed");
        return 0;
    }
}
