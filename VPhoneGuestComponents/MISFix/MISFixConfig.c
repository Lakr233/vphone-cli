#include "MISFixConfig.h"

#include <sys/stat.h>

// Two locations, first match wins.
//
// The override is a per-machine setting someone changes while the VM runs, so
// the preferred home is on the data volume, where vphoned's ordinary
// `files.plist_set` can write it with no remount and no new daemon code. The
// copy in /usr/lib is the one `cfw install` ships: it is the documented
// default, and it is the fallback if a daemon's sandbox turns out not to reach
// /var/db — /usr/lib is a directory installd and misagent certainly reach,
// since that is where they load this dylib from.
static const char *const kConfigPaths[] = {
    "/var/db/vphone/misfix.plist",
    "/usr/lib/libmisfix.plist",
};
static const size_t kConfigPathCount = sizeof(kConfigPaths) / sizeof(kConfigPaths[0]);

// Cached across calls. misagent is asked for the UDID once per profile, and
// installd validates every bundle in an install, so re-reading and re-parsing
// the file each time would be wasteful — but the file has to be allowed to
// change under a running daemon, or "apply the setting" would mean "reboot".
// Modification time plus size is enough to notice an edit: the plist is
// written by replacing it, never by editing bytes in place.
static CFStringRef gDeviceIdentifier;
static const char *gPath;
static struct timespec gStamp;
static off_t gSize;
static int gLoaded;

static CFPropertyListRef vpCopyConfigurationPlist(const char *path) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault,
        (const UInt8 *)path,
        (CFIndex)strlen(path),
        false
    );
    if (url == NULL)
        return NULL;

    CFReadStreamRef stream = CFReadStreamCreateWithFile(kCFAllocatorDefault, url);
    CFRelease(url);
    if (stream == NULL)
        return NULL;

    CFPropertyListRef plist = NULL;
    if (CFReadStreamOpen(stream)) {
        plist = CFPropertyListCreateWithStream(
            kCFAllocatorDefault,
            stream,
            0,
            kCFPropertyListImmutable,
            NULL,
            NULL
        );
        CFReadStreamClose(stream);
    }
    CFRelease(stream);

    if (plist != NULL && CFGetTypeID(plist) != CFDictionaryGetTypeID()) {
        CFRelease(plist);
        return NULL;
    }
    return plist;
}

static void vpReload(const char *path) {
    if (gDeviceIdentifier != NULL) {
        CFRelease(gDeviceIdentifier);
        gDeviceIdentifier = NULL;
    }

    CFPropertyListRef plist = vpCopyConfigurationPlist(path);
    if (plist == NULL)
        return;

    CFTypeRef value = CFDictionaryGetValue((CFDictionaryRef)plist, CFSTR("UniqueDeviceID"));
    if (value != NULL && CFGetTypeID(value) == CFStringGetTypeID()
        && CFStringGetLength((CFStringRef)value) > 0)
    {
        gDeviceIdentifier = CFStringCreateCopy(kCFAllocatorDefault, (CFStringRef)value);
    }
    CFRelease(plist);
}

CFStringRef MISFixCopyConfiguredDeviceIdentifier(void) {
    const char *path = NULL;
    struct stat info;
    for (size_t index = 0; index < kConfigPathCount; index += 1) {
        if (stat(kConfigPaths[index], &info) == 0) {
            path = kConfigPaths[index];
            break;
        }
    }

    if (path == NULL) {
        // Neither file is there. Forget anything cached from before one was
        // removed, so deleting the plist turns the override off.
        if (gDeviceIdentifier != NULL) {
            CFRelease(gDeviceIdentifier);
            gDeviceIdentifier = NULL;
        }
        gLoaded = 1;
        gPath = NULL;
        gStamp.tv_sec = 0;
        gStamp.tv_nsec = 0;
        gSize = 0;
        return NULL;
    }

    int unchanged = gLoaded
        && gPath == path
        && info.st_mtimespec.tv_sec == gStamp.tv_sec
        && info.st_mtimespec.tv_nsec == gStamp.tv_nsec
        && info.st_size == gSize;
    if (unchanged)
        return gDeviceIdentifier;

    gPath = path;
    gStamp = info.st_mtimespec;
    gSize = info.st_size;
    gLoaded = 1;
    vpReload(path);
    return gDeviceIdentifier;
}
