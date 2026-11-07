// Two UXM lookups and independently gated native HMD graphics lookups.
// This library is loaded only into launchd; every other check is forwarded.
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef VP_VISIONOS_IPC_TESTING
typedef struct { unsigned int val[8]; } vp_audit_token_t;
#endif

#define VP_VISIONOS_IPC_MARKER "/usr/lib/vphone-visionos-uxm-ipc"
#define VP_VISIONOS_HMD_PROPERTIES_MARKER "/usr/lib/vphone-visionos-hmd-properties-ipc"
#define VP_BACKBOARD_PATH "/usr/libexec/backboardd"
#define VP_HMD_PROPERTIES_SERVICE "com.apple.wakeboard.hmdproperties"
#define VP_VISIONOS_HMD_PRESENTABLE_MARKER "/usr/lib/vphone-visionos-hmd-presentable-ipc"
#define VP_HMD_PRESENTABLE_SERVICE "com.apple.wakeboard.hmdpresentable.owner"
#define VP_VISIONOS_HMD_SYSTEM_SETTER_MARKER "/usr/lib/vphone-visionos-hmd-system-setter-ipc"
#define VP_HMD_SYSTEM_SETTER_SERVICE "com.apple.wakeboard.hmdsystemsetter"
#define VP_VISIONOS_WAKEBOARD_SYSTEM_MARKER "/usr/lib/vphone-visionos-wakeboard-system-ipc"
#define VP_WAKEBOARD_SYSTEM_SERVICE "com.apple.wakeboardd.system"
#define VP_UXM_PATH "/usr/libexec/userexperiencemanagerd"
#define VP_POLARIS_PATH "/System/Library/PrivateFrameworks/Polaris.framework/polarisd"
#define VP_PBS_SERVICE "com.apple.polaris.daemon_default"
#define VP_UXM_SESSION_SERVICE "com.apple.UXMSessionService"

extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
extern int csops_audittoken(pid_t pid, unsigned int operations, void *buffer,
                           size_t size, vp_audit_token_t *token);

static int vpVisionOSIPCLookupAllowed(const vp_audit_token_t *token,
                                     const char *operation, unsigned int filter,
                                     const void *name) {
    if (getpid() != 1 || !token || !operation || !name ||
        (filter != 2 && filter != 3 && filter != 12) ||
        strcmp(operation, "mach-lookup"))
        return 0;

    const char *path;
    const char *identifier;
    const char *extraMarker = NULL;
    if (!strcmp(name, VP_PBS_SERVICE)) {
        path = VP_UXM_PATH;
        identifier = "com.apple.userexperiencemanagerd";
    } else if (!strcmp(name, VP_UXM_SESSION_SERVICE)) {
        path = VP_POLARIS_PATH;
        identifier = "com.apple.polarisd";
    } else if (!strcmp(name, VP_HMD_PROPERTIES_SERVICE) ||
               !strcmp(name, VP_HMD_PRESENTABLE_SERVICE) ||
               !strcmp(name, VP_HMD_SYSTEM_SETTER_SERVICE) ||
               !strcmp(name, VP_WAKEBOARD_SYSTEM_SERVICE)) {
        path = VP_BACKBOARD_PATH;
        identifier = "com.apple.backboardd";
        extraMarker = !strcmp(name, VP_HMD_PROPERTIES_SERVICE) ? VP_VISIONOS_HMD_PROPERTIES_MARKER :
            !strcmp(name, VP_HMD_PRESENTABLE_SERVICE) ? VP_VISIONOS_HMD_PRESENTABLE_MARKER :
            !strcmp(name, VP_HMD_SYSTEM_SETTER_SERVICE) ? VP_VISIONOS_HMD_SYSTEM_SETTER_MARKER :
            VP_VISIONOS_WAKEBOARD_SYSTEM_MARKER;
    } else {
        return 0;
    }

    struct stat marker;
    if (lstat(VP_VISIONOS_IPC_MARKER, &marker) || !S_ISREG(marker.st_mode) ||
        marker.st_uid != 0 || (marker.st_mode & 022))
        return 0;
    if (extraMarker && (lstat(extraMarker, &marker) || !S_ISREG(marker.st_mode) ||
                        marker.st_uid != 0 || (marker.st_mode & 022)))
        return 0;

    pid_t pid = (pid_t)token->val[5];
    char processPath[PATH_MAX] = {0};
    if (pid <= 0 || proc_pidpath(pid, processPath, sizeof(processPath)) <= 0 ||
        strcmp(processPath, path))
        return 0;

    // The kernel validates both PID and PID version from this audit token.
    // CS_OPS_IDENTITY returns an eight-byte header and a NUL-terminated ID.
    unsigned char identity[256] = {0};
    vp_audit_token_t checkedToken = *token;
    if (csops_audittoken(pid, 11, identity, sizeof(identity), &checkedToken) ||
        !memchr(identity + 8, 0, sizeof(identity) - 8))
        return 0;
    return !strcmp((const char *)identity + 8, identifier);
}

__attribute__((used, noinline)) static int vpVisionOSIPCAllowed(
    const vp_audit_token_t *token, const char *operation, unsigned int filter,
    const void *name) {
    int saved = errno;
    int allowed = vpVisionOSIPCLookupAllowed(token, operation, filter, name);
    errno = saved;
    return allowed;
}

#ifdef VP_VISIONOS_IPC_TESTING
#define VP_VISIONOS_SANDBOX_SYMBOL "_vpTestSandboxCheck"
#else
#define VP_VISIONOS_SANDBOX_SYMBOL "_sandbox_check_by_audit_token"
extern int sandbox_check_by_audit_token(vp_audit_token_t token, const char *operation,
                                        unsigned int filter, ...);
#endif

// Apple's arm64 ABI passes the 32-byte token indirectly in x0, operation and
// filter in x1/x2, and all variadic arguments on the caller's stack. The helper
// inspects a name only for the three name filters. Rejected calls regain their
// original stack and fixed arguments before the tail branch, preserving zero,
// one, or any number of variadic arguments without reconstructing a va_list.
__attribute__((naked)) static int vpVisionOSSandboxCheck(vp_audit_token_t token,
                                                        const char *operation,
                                                        unsigned int filter, ...) {
    __asm__("stp x29, x30, [sp, #-48]!\n"
            "mov x29, sp\n"
            "stp x0, x1, [sp, #16]\n"
            "str x2, [sp, #32]\n"
            "ldr x3, [sp, #48]\n"
            "bl _vpVisionOSIPCAllowed\n"
            "cmp w0, #0\n"
            "ldp x0, x1, [sp, #16]\n"
            "ldr x2, [sp, #32]\n"
            "ldp x29, x30, [sp], #48\n"
            "b.eq 1f\n"
            "mov w0, #0\n"
            "ret\n"
            "1: b " VP_VISIONOS_SANDBOX_SYMBOL "\n");
}

#ifndef VP_VISIONOS_IPC_TESTING
__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *original;
} vpVisionOSIPCInterpose = {
    (const void *)&vpVisionOSSandboxCheck, (const void *)&sandbox_check_by_audit_token
};
#endif
