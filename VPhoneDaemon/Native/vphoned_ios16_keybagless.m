#import "Include/VphonedNative.h"
#import "Include/VPhoneIOS16LabPolicy.h"

#include <dirent.h>
#include <errno.h>
#include <sys/sysctl.h>

static dispatch_source_t gIOS16LabLease;

static bool lab_has_only_ephemeral_bags(void) {
    int ephemeral = 0;
    size_t size = sizeof(ephemeral);
    if (getuid() != 0 || access(VP_IOS16_KEYBAGLESS_SELECTION, F_OK) != 0 ||
        access("/usr/lib/vphone-ios16-keybag-ephemeral", F_OK) != 0 ||
        sysctlbyname("hw.ephemeral_storage", &ephemeral, &size, NULL, 0) != 0 || ephemeral != 1) return false;
    int fd = open("/private/var/keybags", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return false;
    struct stat directory;
    if (fstat(fd, &directory) != 0 || directory.st_uid != 0 || (directory.st_mode & 022)) {
        close(fd);
        return false;
    }
    DIR *entries = fdopendir(fd);
    if (!entries) { close(fd); return false; }
    bool fresh = true;
    struct dirent *entry;
    errno = 0;
    while ((entry = readdir(entries))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        // The measured ephemeral boot creates only these session/persona bags.
        // A system bag, backup, lockout file, symlink or unknown entry refuses
        // UI-only mode. Never read or modify any key material.
        struct stat file;
        if ((strcmp(entry->d_name, "persona.kb") && strcmp(entry->d_name, "usersession.kb")) ||
            fstatat(fd, entry->d_name, &file, AT_SYMLINK_NOFOLLOW) != 0 ||
            !S_ISREG(file.st_mode) || file.st_uid != 0 || (file.st_mode & 022)) { fresh = false; break; }
    }
    if (errno != 0) fresh = false;
    closedir(entries);
    return fresh;
}

static void refresh_lab_lease(void) {
    if (!lab_has_only_ephemeral_bags()) {
        unlink(VP_IOS16_KEYBAGLESS_ATTESTATION);
        return;
    }
    char temporary[] = VP_IOS16_KEYBAGLESS_ATTESTATION ".XXXXXX";
    int fd = mkstemp(temporary);
    if (fd < 0) return;
    const char magic[] = VP_IOS16_KEYBAGLESS_MAGIC;
    bool ready = write(fd, magic, sizeof(magic) - 1) == (ssize_t)sizeof(magic) - 1 && fchmod(fd, 0644) == 0;
    close(fd);
    if (ready) rename(temporary, VP_IOS16_KEYBAGLESS_ATTESTATION);
    unlink(temporary);
}

void vp_ios16_keybagless_ui_start(void) {
    NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
    if (version.majorVersion != 16 || version.minorVersion != 6 ||
        access(VP_IOS16_KEYBAGLESS_SELECTION, F_OK) != 0) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        refresh_lab_lease();
        dispatch_queue_t queue = dispatch_queue_create("com.vphone.vphoned.ios16-lab-lease", DISPATCH_QUEUE_SERIAL);
        gIOS16LabLease = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(gIOS16LabLease, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                                 NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(gIOS16LabLease, ^{ refresh_lab_lease(); });
        dispatch_resume(gIOS16LabLease);
    });
}
