#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct { unsigned int val[8]; } vp_audit_token_t;
static int test_lstat(const char *, struct stat *);
static pid_t test_getpid(void);
#define lstat test_lstat
#define getpid test_getpid
#define proc_pidpath test_pidpath
#define csops_audittoken test_csops
#define VP_VISIONOS_IPC_TESTING
#include "../libvphonevisionosipc.c"

static pid_t currentPID = 1;
static int markerMissing, wrongPath, wrongIdentity, csopsFailure, unterminatedIdentity;
static mode_t markerMode = S_IFREG | 0644;
static uid_t markerOwner;
static int hmdMarkerMissing[4] = {1, 1, 1, 1};
static const char *hmdMarkers[] = {VP_VISIONOS_HMD_PROPERTIES_MARKER,
    VP_VISIONOS_HMD_PRESENTABLE_MARKER, VP_VISIONOS_HMD_SYSTEM_SETTER_MARKER,
    VP_VISIONOS_WAKEBOARD_SYSTEM_MARKER};
static const char *hmdServices[] = {VP_HMD_PROPERTIES_SERVICE,
    VP_HMD_PRESENTABLE_SERVICE, VP_HMD_SYSTEM_SETTER_SERVICE, VP_WAKEBOARD_SYSTEM_SERVICE};
static mode_t hmdMarkerMode = S_IFREG | 0644;
static uid_t hmdMarkerOwner;
static unsigned int expectedVersion = 42;
static unsigned int forwardCount;
static const char *expectedOperation;
static unsigned int expectedFilter;
static vp_audit_token_t expectedToken;
static int variadicCount;

static pid_t test_getpid(void) { errno = EIO; return currentPID; }
static int test_lstat(const char *path, struct stat *info) {
    int hmdIndex = -1;
    for (size_t i = 0; i < sizeof(hmdMarkers)/sizeof(*hmdMarkers); i++)
        if (!strcmp(path, hmdMarkers[i])) hmdIndex = (int)i;
    int isHMD = hmdIndex >= 0;
    assert(isHMD || !strcmp(path, VP_VISIONOS_IPC_MARKER));
    memset(info, 0, sizeof(*info));
    info->st_mode = isHMD ? hmdMarkerMode : markerMode;
    info->st_uid = isHMD ? hmdMarkerOwner : markerOwner;
    errno = ENOENT;
    return (isHMD ? hmdMarkerMissing[hmdIndex] : markerMissing) ? -1 : 0;
}
int test_pidpath(int pid, void *buffer, uint32_t size) {
    const char *path = pid == 401 ? VP_UXM_PATH : pid == 402 ? VP_POLARIS_PATH : pid == 404 ? VP_BACKBOARD_PATH : "/tmp/other";
    errno = ESRCH;
    return snprintf(buffer, size, "%s", wrongPath ? "/tmp/spoof" : path);
}
int test_csops(pid_t pid, unsigned int operation, void *buffer, size_t size,
               vp_audit_token_t *token) {
    assert(operation == 11 && token->val[5] == (unsigned int)pid);
    errno = EINVAL;
    if (csopsFailure || token->val[7] != expectedVersion)
        return -1;
    if (unterminatedIdentity) {
        memset(buffer, 'x', size);
        return 0;
    }
    const char *identity = pid == 401 ? "com.apple.userexperiencemanagerd" : pid == 404 ? "com.apple.backboardd" : "com.apple.polarisd";
    snprintf((char *)buffer + 8, size - 8, "%s", wrongIdentity ? "com.apple.other" : identity);
    return 0;
}

int vpTestSandboxCheck(vp_audit_token_t token, const char *operation, unsigned int filter, ...) {
    assert(!memcmp(&token, &expectedToken, sizeof(token)));
    assert(operation == expectedOperation && filter == expectedFilter);
    // The matcher must leave the incoming errno intact even when it rejects.
    assert(errno == EDOM);
    va_list args;
    va_start(args, filter);
    if (variadicCount >= 1) assert(va_arg(args, const char *) == expectedOperation);
    if (variadicCount >= 2) assert(va_arg(args, int) == 567);
    if (variadicCount >= 3) assert(va_arg(args, void *) == &markerMode);
    if (variadicCount >= 4) assert(va_arg(args, uint64_t) == UINT64_C(0x123456789abcdef0));
    va_end(args);
    forwardCount++;
    errno = EACCES;
    return 73;
}

static void expectAllowed(vp_audit_token_t token, const char *operation,
                          unsigned int filter, const void *name, int expected) {
    errno = EDOM;
    assert(vpVisionOSIPCAllowed(&token, operation, filter, name) == expected);
    assert(errno == EDOM);
}

int main(void) {
    vp_audit_token_t uxm = {{0}}, polaris = {{0}};
    uxm.val[5] = 401; uxm.val[7] = 42;
    polaris.val[5] = 402; polaris.val[7] = 42;
    for (unsigned int filter = 0; filter < 32; filter++) {
        int allowed = filter == 2 || filter == 3 || filter == 12;
        expectAllowed(uxm, "mach-lookup", filter, VP_PBS_SERVICE, allowed);
        expectAllowed(polaris, "mach-lookup", filter, VP_UXM_SESSION_SERVICE, allowed);
    }
    expectAllowed(uxm, NULL, 2, VP_PBS_SERVICE, 0);
    expectAllowed(uxm, "mach-register", 2, VP_PBS_SERVICE, 0);
    expectAllowed(uxm, "mach-lookup", 2, NULL, 0);
    expectAllowed(uxm, "mach-lookup", 2, "com.apple.other", 0);
    expectAllowed(uxm, "mach-lookup", 2, VP_UXM_SESSION_SERVICE, 0);
    expectAllowed(polaris, "mach-lookup", 2, VP_PBS_SERVICE, 0);
    assert(!vpVisionOSIPCAllowed(NULL, "mach-lookup", 2, VP_PBS_SERVICE));
    currentPID = 2;
    expectAllowed(uxm, "mach-lookup", 2, VP_PBS_SERVICE, 0);
    currentPID = 1;
    int *failures[] = {&markerMissing, &wrongPath, &wrongIdentity, &csopsFailure, &unterminatedIdentity};
    for (size_t i = 0; i < sizeof(failures) / sizeof(failures[0]); i++) {
        *failures[i] = 1;
        expectAllowed(uxm, "mach-lookup", 2, VP_PBS_SERVICE, 0);
        expectAllowed(polaris, "mach-lookup", 2, VP_UXM_SESSION_SERVICE, 0);
        *failures[i] = 0;
    }
    const mode_t rejectedModes[] = {S_IFLNK | 0644, S_IFDIR | 0755, S_IFREG | 0664, S_IFREG | 0646};
    for (size_t i = 0; i < sizeof(rejectedModes) / sizeof(rejectedModes[0]); i++) {
        markerMode = rejectedModes[i];
        expectAllowed(uxm, "mach-lookup", 2, VP_PBS_SERVICE, 0);
    }
    markerMode = S_IFREG | 0644;
    markerOwner = 501;
    expectAllowed(uxm, "mach-lookup", 2, VP_PBS_SERVICE, 0);
    markerOwner = 0;
    vp_audit_token_t bad = uxm;
    const unsigned int badPIDs[] = {0, 403, (unsigned int)-1};
    for (size_t i = 0; i < sizeof(badPIDs) / sizeof(badPIDs[0]); i++) {
        bad.val[5] = badPIDs[i];
        expectAllowed(bad, "mach-lookup", 2, VP_PBS_SERVICE, 0);
    }
    bad = uxm; bad.val[7]++;
    expectAllowed(bad, "mach-lookup", 2, VP_PBS_SERVICE, 0);

    errno = EDOM;
    assert(vpVisionOSSandboxCheck(uxm, "mach-lookup", 2, VP_PBS_SERVICE) == 0);
    assert(errno == EDOM && forwardCount == 0);
    errno = EDOM;
    assert(vpVisionOSSandboxCheck(polaris, "mach-lookup", 12, VP_UXM_SESSION_SERVICE) == 0);
    assert(errno == EDOM && forwardCount == 0);

    // An unknown check with zero arguments, one argument, and several differently
    // sized arguments must reach the original function with every value intact.
    expectedToken = uxm;
    expectedOperation = NULL; expectedFilter = 0; variadicCount = 0;
    errno = EDOM;
    assert(vpVisionOSSandboxCheck(uxm, expectedOperation, expectedFilter) == 73 && errno == EACCES);
    expectedOperation = "com.apple.other"; expectedFilter = 2; variadicCount = 1;
    errno = EDOM;
    assert(vpVisionOSSandboxCheck(uxm, expectedOperation, expectedFilter, expectedOperation) == 73 && errno == EACCES);
    expectedOperation = "other-operation"; expectedFilter = 99; variadicCount = 4;
    errno = EDOM;
    assert(vpVisionOSSandboxCheck(uxm, expectedOperation, expectedFilter,
        expectedOperation, 567, &markerMode, UINT64_C(0x123456789abcdef0)) == 73 && errno == EACCES);
    assert(forwardCount == 3);

    vp_audit_token_t backboard = {{0}};
    backboard.val[5] = 404; backboard.val[7] = 42;
    // Existing UXM marker alone never enables the new permission.
    expectAllowed(backboard, "mach-lookup", 2, VP_HMD_PROPERTIES_SERVICE, 0);
    hmdMarkerMissing[0] = 0;
    for (unsigned int filter = 0; filter < 32; filter++) {
        expectAllowed(backboard, "mach-lookup", filter, VP_HMD_PROPERTIES_SERVICE,
                      filter == 2 || filter == 3 || filter == 12);
    }
    expectAllowed(uxm, "mach-lookup", 2, VP_HMD_PROPERTIES_SERVICE, 0);
    expectAllowed(polaris, "mach-lookup", 2, VP_HMD_PROPERTIES_SERVICE, 0);
    expectAllowed(backboard, "mach-lookup", 2, VP_PBS_SERVICE, 0);
    expectAllowed(backboard, "mach-lookup", 2, VP_UXM_SESSION_SERVICE, 0);
    const char *excludedServices[] = {"com.apple.wakeboard.hmdrender", "com.apple.wakeboardd.system.extra",
        "com.apple.audio.AudioSession", "com.apple.arkit.service.worldTracking",
        "com.apple.wakeboard.hmdproperties.extra"};
    for (size_t i = 0; i < sizeof(excludedServices)/sizeof(*excludedServices); i++)
        expectAllowed(backboard, "mach-lookup", 2, excludedServices[i], 0);
    expectAllowed(backboard, "mach-register", 2, VP_HMD_PROPERTIES_SERVICE, 0);
    for (size_t i = 0; i < sizeof(failures)/sizeof(*failures); i++) {
        *failures[i] = 1;
        expectAllowed(backboard, "mach-lookup", 2, VP_HMD_PROPERTIES_SERVICE, 0);
        *failures[i] = 0;
    }
    for (size_t i = 0; i < sizeof(rejectedModes)/sizeof(*rejectedModes); i++) {
        hmdMarkerMode = rejectedModes[i];
        expectAllowed(backboard, "mach-lookup", 2, VP_HMD_PROPERTIES_SERVICE, 0);
    }
    hmdMarkerMode = S_IFREG | 0644;
    hmdMarkerOwner = 501;
    expectAllowed(backboard, "mach-lookup", 2, VP_HMD_PROPERTIES_SERVICE, 0);
    hmdMarkerOwner = 0;
    currentPID = 2;
    expectAllowed(backboard, "mach-lookup", 2, VP_HMD_PROPERTIES_SERVICE, 0);
    currentPID = 1;
    bad = backboard; bad.val[7]++;
    expectAllowed(bad, "mach-lookup", 2, VP_HMD_PROPERTIES_SERVICE, 0);
    hmdMarkerMissing[0] = 1;
    expectAllowed(backboard, "mach-lookup", 2, VP_HMD_PROPERTIES_SERVICE, 0);
    expectAllowed(uxm, "mach-lookup", 2, VP_PBS_SERVICE, 1);
    expectAllowed(polaris, "mach-lookup", 2, VP_UXM_SESSION_SERVICE, 1);
    // Each native graphics endpoint has its own gate; enabling one cannot
    // accidentally enable another service or change the two original rules.
    for (size_t selected = 0; selected < sizeof(hmdServices)/sizeof(*hmdServices); selected++) {
        hmdMarkerMissing[selected] = 0;
        for (size_t service = 0; service < sizeof(hmdServices)/sizeof(*hmdServices); service++)
            expectAllowed(backboard, "mach-lookup", 2, hmdServices[service], selected == service);
        for (unsigned int filter = 0; filter < 32; filter++)
            expectAllowed(backboard, "mach-lookup", filter, hmdServices[selected],
                          filter == 2 || filter == 3 || filter == 12);
        for (size_t i = 0; i < sizeof(failures)/sizeof(*failures); i++) {
            *failures[i] = 1;
            expectAllowed(backboard, "mach-lookup", 2, hmdServices[selected], 0);
            *failures[i] = 0;
        }
        for (size_t i = 0; i < sizeof(rejectedModes)/sizeof(*rejectedModes); i++) {
            hmdMarkerMode = rejectedModes[i];
            expectAllowed(backboard, "mach-lookup", 2, hmdServices[selected], 0);
        }
        hmdMarkerMode = S_IFREG | 0644;
        hmdMarkerOwner = 501;
        expectAllowed(backboard, "mach-lookup", 2, hmdServices[selected], 0);
        hmdMarkerOwner = 0;
        expectAllowed(uxm, "mach-lookup", 2, hmdServices[selected], 0);
        expectAllowed(polaris, "mach-lookup", 2, hmdServices[selected], 0);
        hmdMarkerMissing[selected] = 1;
    }
    puts("VisionOS IPC: existing scope/ABI and independent native graphics gates passed");
}
