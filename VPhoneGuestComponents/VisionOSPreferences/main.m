// One launch per boot as mobile. Data is unavailable to the offline installer.
#import "VisionOSBuddyPreferences.h"
#import <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>

int main(void) {
    @autoreleasepool {
        if (getuid() != 501 || geteuid() != 501 || getgid() != 501 || getegid() != 501) {
            NSLog(@"visionOS preferences repair requires mobile UID/GID 501.");
            return 1;
        }
        NSURL *journal = [NSURL fileURLWithPath:@"/var/mobile/Library/Application Support/vphone/VisionOSSkipBuddyOriginal.plist"];
        const char *marker = "/usr/share/vphone/VisionOSSkipBuddy.plist";
        struct stat metadata;
        BOOL enabled = NO;
        if (lstat(marker, &metadata) == 0) {
            if (!S_ISREG(metadata.st_mode) || metadata.st_uid != 0 || metadata.st_nlink != 1
                || (metadata.st_mode & 0022) != 0 || metadata.st_size > 4096) return 1;
            NSDictionary *policy = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithUTF8String:marker]];
            id value = policy[@"Enabled"];
            if (policy.count != 1 || !value || CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()
                || ![value boolValue]) return 1;
            enabled = YES;
        } else if (errno != ENOENT) return 1;
        if (!enabled && lstat(journal.fileSystemRepresentation, &metadata) != 0 && errno == ENOENT) return 0;
        CFStringRef domain = CFSTR("com.apple.purplebuddy");
        if (!CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)) return 1;
        id value = CFBridgingRelease(CFPreferencesCopyValue(CFSTR("ForceNoBuddy"), domain,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
        NSDictionary *current = value ? @{@"ForceNoBuddy": value} : @{};
        NSError *error = nil;
        BOOL success = VPVisionOSBuddyUpdate(enabled, journal, current, ^(NSString *key, id desired) {
            CFPreferencesSetValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)desired, domain,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        }, ^BOOL {
            return CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        }, &error);
        NSLog(@"visionOS ForceNoBuddy %@: %@%@", enabled ? @"apply" : @"restore",
              success ? @"synchronized" : @"failed", error ? [@": " stringByAppendingString:error.localizedDescription] : @"");
        return success ? 0 : 1;
    }
}
