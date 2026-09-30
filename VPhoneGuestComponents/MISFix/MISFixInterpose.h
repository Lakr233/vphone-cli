// MISFixInterpose.h — dyld interposition, in the one shape that works here.
//
// `MICodeSigningVerifier` lives in MobileInstallation and misagent's
// MobileGestalt call lands in libMobileGestalt, so in both cases the call this
// hook wants to replace is made by one shared-cache image into another. dyld
// covers that: an image loaded at launch with an `__interpose` section has its
// replacements applied to the cache's own uses of those symbols, not merely to
// the injected image's.
//
// On arm64e the section is emitted into `__AUTH_CONST` rather than `__DATA`,
// because its two pointers are signed. That is fine — verified by loading the
// built dylib into a guest process through a load command and watching an
// interposed call return the hooked result — but it is why the section name is
// written out here rather than trusted to a system macro.

#ifndef MISFIX_INTERPOSE_H
#define MISFIX_INTERPOSE_H

#define MISFIX_INTERPOSE(replacement, original)                          \
    __attribute__((used, section("__DATA,__interpose"))) static struct { \
        const void *replacement;                                         \
        const void *original;                                            \
    } misfixInterpose_##original = {                                     \
        (const void *)(unsigned long)&replacement,                       \
        (const void *)(unsigned long)&original,                          \
    }

#endif
