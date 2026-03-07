/**
 * liblaunch_compat.dylib — Stub for missing liblaunch symbols.
 *
 * The PCC/vResearch VM's libSystem.B.dylib is stripped and lacks
 * _launch_active_user_switch (used by procursus launchctl).
 * This dylib provides a no-op stub so procursus binaries can load.
 *
 * Deployed to /cores/ and loaded via DYLD_INSERT_LIBRARIES.
 *
 * Verify: DYLD_INSERT_LIBRARIES=/cores/liblaunch_compat.dylib launchctl version
 *         — should print version instead of "Symbol not found".
 */

#include <sys/types.h>
#include <stdio.h>

__attribute__((constructor))
static void liblaunch_compat_init(void) {
    fprintf(stderr, "[liblaunch_compat] loaded — providing launch_active_user_switch stub\n");
}

int launch_active_user_switch(uid_t uid) {
    fprintf(stderr, "[liblaunch_compat] launch_active_user_switch(%d) -> 0 (stub)\n", uid);
    return 0;
}
