#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>
#include <crt_externs.h>

extern bool os_variant_uses_ephemeral_storage(const char *subsystem);

// 20G81 keybagd has a native ephemeral-platform exit before provisioning the
// system bag. Use it only for --init on this explicitly selected VM pairing.
static bool vpKeybagEphemeral(const char *subsystem) {
    int argc = *_NSGetArgc();
    char **argv = *_NSGetArgv();
    if (argc == 2 && !strcmp(getprogname(), "keybagd") &&
        !strcmp(argv[1], "--init") && subsystem &&
        !strcmp(subsystem, "com.apple.mobile.keybagd") &&
        access("/usr/lib/vphone-ios16-keybag-ephemeral", F_OK) == 0) return true;
    return os_variant_uses_ephemeral_storage(subsystem);
}

__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *replacee;
} vpKeybagInterpose = {
    (const void *)vpKeybagEphemeral, (const void *)os_variant_uses_ephemeral_storage,
};
