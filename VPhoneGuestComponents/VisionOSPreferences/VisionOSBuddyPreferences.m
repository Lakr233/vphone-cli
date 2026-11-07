#import "VisionOSBuddyPreferences.h"
#import <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *const VPBuddyKey = @"ForceNoBuddy";

static BOOL VPBuddyError(NSError **error, NSString *description) {
    if (error) *error = [NSError errorWithDomain:@"com.vphone.visionos-preferences" code:1
                                      userInfo:@{NSLocalizedDescriptionKey: description}];
    return NO;
}

static BOOL VPBuddyBoolean(id value) {
    return value && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL VPBuddySyncDirectory(NSURL *directory) {
    int fd = open(directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return NO;
    BOOL result = fsync(fd) == 0;
    close(fd);
    return result;
}

BOOL VPVisionOSBuddySaveJournal(NSDictionary *journal, NSURL *url, NSError **error) {
    NSURL *directory = url.URLByDeletingLastPathComponent;
    NSMutableArray<NSURL *> *missingDirectories = [NSMutableArray array];
    NSURL *ancestor = directory;
    struct stat metadata;
    while (lstat(ancestor.fileSystemRepresentation, &metadata) != 0) {
        if (errno != ENOENT) return VPBuddyError(error, @"Could not inspect the journal directory; preferences unchanged.");
        [missingDirectories addObject:ancestor];
        NSURL *parent = ancestor.URLByDeletingLastPathComponent;
        if ([parent.path isEqual:ancestor.path]) return VPBuddyError(error, @"Could not find an existing journal ancestor.");
        ancestor = parent;
    }
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES
          attributes:@{NSFilePosixPermissions: @0700} error:error]) return NO;
    // A durable file also needs the newly created directories' parent entries.
    // Persist the chain from the existing ancestor down before publishing it.
    for (NSURL *created in missingDirectories.reverseObjectEnumerator) {
        if (!VPBuddySyncDirectory(created.URLByDeletingLastPathComponent)) {
            return VPBuddyError(error, @"Could not durably create the journal directory; preferences unchanged.");
        }
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:journal
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data) return NO;
    char *temporary = strdup([[url.path stringByAppendingString:@".XXXXXX"] fileSystemRepresentation]);
    if (!temporary) return VPBuddyError(error, @"Could not allocate journal path.");
    int fd = mkstemp(temporary);
    BOOL success = fd >= 0;
    NSUInteger position = 0;
    while (success && position < data.length) {
        ssize_t count = write(fd, (const char *)data.bytes + position, data.length - position);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { success = NO; break; }
        position += (NSUInteger)count;
    }
    if (success) success = fchmod(fd, 0600) == 0 && fsync(fd) == 0;
    if (fd >= 0 && close(fd) != 0) success = NO;
    // A concurrent helper may have captured the original after our read.
    // link is an atomic no-replace publication; never overwrite its inverse.
    if (success) success = link(temporary, url.fileSystemRepresentation) == 0;
    if (success) success = unlink(temporary) == 0;
    if (success) success = VPBuddySyncDirectory(directory);
    if (!success) unlink(temporary);
    free(temporary);
    return success || VPBuddyError(error, @"Could not durably save the original ForceNoBuddy value; preferences unchanged.");
}

BOOL VPVisionOSBuddyUpdate(BOOL enabled, NSURL *journalURL, NSDictionary<NSString *, id> *current,
                          void (^setValue)(NSString *, id), BOOL (^synchronize)(void), NSError **error) {
    id existing = current[VPBuddyKey];
    if (existing && !VPBuddyBoolean(existing)) return VPBuddyError(error, @"ForceNoBuddy is not a Boolean.");
    struct stat metadata;
    NSDictionary *journal = nil;
    if (lstat(journalURL.fileSystemRepresentation, &metadata) == 0) {
        if (!S_ISREG(metadata.st_mode) || metadata.st_uid != geteuid() || metadata.st_gid != getegid() || metadata.st_nlink != 1
            || (metadata.st_mode & 0077) != 0 || metadata.st_size > 65536) {
            return VPBuddyError(error, @"Refusing an unsafe ForceNoBuddy journal.");
        }
        NSData *data = [NSData dataWithContentsOfURL:journalURL options:0 error:error];
        if (!data) return NO;
        id decoded = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:error];
        if (![decoded isKindOfClass:NSDictionary.class]) return VPBuddyError(error, @"Invalid ForceNoBuddy journal.");
        journal = decoded;
        id version = journal[@"Version"], original = journal[@"Original"], absent = journal[@"Absent"];
        if (journal.count != 3 || !version || CFGetTypeID((__bridge CFTypeRef)version) != CFNumberGetTypeID()
            || CFNumberIsFloatType((__bridge CFNumberRef)version) || ![version isEqual:@1]
            || ![original isKindOfClass:NSDictionary.class] || ![absent isKindOfClass:NSArray.class]) {
            return VPBuddyError(error, @"Invalid ForceNoBuddy journal schema.");
        }
        BOOL originallyAbsent = [original count] == 0 && [absent isEqual:@[VPBuddyKey]];
        BOOL originallyPresent = [original count] == 1 && VPBuddyBoolean(original[VPBuddyKey]) && [absent count] == 0;
        if (!originallyAbsent && !originallyPresent) return VPBuddyError(error, @"Journal must own only the original Boolean ForceNoBuddy key.");
    } else if (errno != ENOENT) {
        return VPBuddyError(error, @"Could not inspect the ForceNoBuddy journal.");
    }
    if (!enabled && !journal) return YES;
    if (enabled && !journal) {
        journal = @{@"Version": @1, @"Original": existing ? @{VPBuddyKey: existing} : @{},
                    @"Absent": existing ? @[] : @[VPBuddyKey]};
        // The inverse must reach disk before cfprefsd receives any mutation.
        if (!VPVisionOSBuddySaveJournal(journal, journalURL, error)) return NO;
    }
    id desired = enabled ? @YES : journal[@"Original"][VPBuddyKey];
    if (existing != desired && ![existing isEqual:desired]) setValue(VPBuddyKey, desired);
    if (!synchronize()) return VPBuddyError(error, @"Could not synchronize ForceNoBuddy; original-value journal retained.");
    if (!enabled && (unlink(journalURL.fileSystemRepresentation) != 0
                     || !VPBuddySyncDirectory(journalURL.URLByDeletingLastPathComponent))) {
        return VPBuddyError(error, @"Could not durably remove the restored ForceNoBuddy journal.");
    }
    return YES;
}
