#ifndef VPHONE_IOS16_LAB_POLICY_H
#define VPHONE_IOS16_LAB_POLICY_H
#include <stdbool.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define VP_IOS16_KEYBAGLESS_SELECTION "/usr/lib/vphone-ios16-keybagless-ui"
#define VP_IOS16_KEYBAGLESS_ATTESTATION "/private/var/run/vphone-ios16-keybagless-ui"
#define VP_IOS16_KEYBAGLESS_MAGIC "VPKEYLESS1\n"

// Root refreshes this short lease only while it can verify that the ephemeral
// lab has no persistent system keybag. Mobile cannot inspect that directory.
static inline bool vp_ios16_lab_lease_valid(const struct stat *s, time_t now) {
    return S_ISREG(s->st_mode) && s->st_uid == 0 && s->st_nlink == 1 &&
        !(s->st_mode & 022) && s->st_size == sizeof(VP_IOS16_KEYBAGLESS_MAGIC) - 1 &&
        now >= s->st_mtime && now - s->st_mtime <= 3;
}

static inline bool vp_ios16_keybagless_ui_attested(void) {
    int fd = open(VP_IOS16_KEYBAGLESS_ATTESTATION, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return false;
    struct stat s;
    char bytes[sizeof(VP_IOS16_KEYBAGLESS_MAGIC) - 1];
    bool valid = fstat(fd, &s) == 0 && vp_ios16_lab_lease_valid(&s, time(NULL)) &&
        read(fd, bytes, sizeof(bytes)) == (ssize_t)sizeof(bytes) &&
        memcmp(bytes, VP_IOS16_KEYBAGLESS_MAGIC, sizeof(bytes)) == 0;
    close(fd);
    return valid;
}
#endif
