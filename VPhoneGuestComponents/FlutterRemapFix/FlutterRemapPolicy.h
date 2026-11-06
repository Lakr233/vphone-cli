#ifndef VP_FLUTTER_REMAP_POLICY_H
#define VP_FLUTTER_REMAP_POLICY_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

// Inputs are canonical paths (realpath at the runtime boundary). Only images
// inside the executable's own app bundle may participate in the fallback.
static inline bool vpFlutterBundleImages(const char *process, const char *source,
                                         const char *caller) {
    if (!process || !source || !caller) return false;
    const char *program = strrchr(process, '/');
    if (!program || !program[1]) return false;
    size_t root = (size_t)(program - process);
    if (root < 4 || memcmp(process + root - 4, ".app", 4) != 0) return false;
    const char *aot = "/Frameworks/App.framework/App";
    const char *engine = "/Frameworks/Flutter.framework/Flutter";
    return strlen(source) == root + strlen(aot) &&
        strlen(caller) == root + strlen(engine) &&
        memcmp(process, source, root) == 0 && memcmp(process, caller, root) == 0 &&
        strcmp(source + root, aot) == 0 && strcmp(caller + root, engine) == 0;
}

// Limited to the observed upstream and Shorebird 16 KiB-page callback layouts.
// Both copy 32 KiB; their source image offsets are 16 KiB and 32 KiB respectively.
// Unknown layouts, writable sources, cross-task remaps and shared mappings
// remain unsupported.
static inline bool vpFlutterRemapCandidate(const char *process, const char *source,
    const char *caller, uintptr_t offset, uint64_t size, int flags, int copy,
    bool sameTask) {
    return sameTask && copy == 1 && flags == 0x4000 && size == 32768 &&
        (offset == 16384 || offset == 32768) &&
        vpFlutterBundleImages(process, source, caller);
}
#endif
